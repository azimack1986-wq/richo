<#
.SYNOPSIS
    Static checks for the bug classes this codebase has actually shipped.

.DESCRIPTION
    Each rule here corresponds to a real defect found in these scripts, not a generic style
    preference. Left unchecked they recur, and every one of them is silent at parse time.

      1. Bare command calls joined with -and/-or/-not. PowerShell parses `if (Test-A -or Test-B)`
         as a call to Test-A with "-or" as an argument, so the second call never runs and the
         condition is silently wrong. Operands must be parenthesised.
      2. Assignment to a read-only automatic variable. $host is the trap; assigning to it throws
         at run time, not at parse time.
      3. Mandatory [array] parameters without [AllowEmptyCollection()]. Parameter binding fails on
         an empty collection, so a legitimately empty list becomes a mid-run crash.
      4. Format-Table left on the success stream inside a function that also returns a value. The
         caller receives formatting records mixed with data.
      5. Import-Module anywhere - called OR suggested in a message. These scripts assume a
         prepared host; importing either duplicates the host build's job or fights a pinned bundle
         already loaded. A remediation line printing "Import-Module ..." is the script telling the
         operator to do it by hand, which is the same instruction by another route, and one sat in
         the PowerCLI load diagnostic while this rule passed on command syntax alone.
      6. Get-Module -ListAvailable outside the caching helper. Repeated enumeration of a module
         exporting thousands of cmdlets is what made the pre-flight look like it had hung.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-ScriptLint.ps1
#>

$repoRoot = Split-Path $PSScriptRoot -Parent
$targets = @(
    Join-Path $repoRoot 'scripts/firmware/Invoke-AutoDeployFirmwareBatchControl.ps1'
    Join-Path $repoRoot 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
    Join-Path $repoRoot 'scripts/intersight/Test-IntersightApiKey.ps1'
    Join-Path $repoRoot 'scripts/vsphere/Invoke-SqlRdmClusterMigration.ps1'
    Join-Path $repoRoot 'tools/Save-RichoModuleBundle.ps1'
)

$script:pass = 0; $script:fail = 0
function Assert-NoFindings {
    param([string]$Name,[array]$Findings)
    if ($Findings.Count -eq 0) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else {
        $script:fail++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        $Findings | ForEach-Object { Write-Host "          $_" -ForegroundColor Red }
    }
}

$readOnlyAutomatics = @('host','true','false','null','pid','pshome','psculture','psuiculture','psversiontable','myinvocation','executioncontext')

# Every function defined anywhere in the scripts being linted, and where it lives. Used by rule 8
# to catch a script calling a helper that only exists in a SIBLING script - see there for why.
$definedAnywhere = @{}
foreach ($path in $targets) {
    $e = $null; $tk = $null
    $a = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tk, [ref]$e)
    if ($e) { continue }
    foreach ($f in $a.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if (-not $definedAnywhere.ContainsKey($f.Name)) { $definedAnywhere[$f.Name] = New-Object System.Collections.Generic.List[string] }
        [void]$definedAnywhere[$f.Name].Add((Split-Path $path -Leaf))
    }
}

foreach ($path in $targets) {
    $name = Split-Path $path -Leaf
    Write-Host "`n=== $name ===" -ForegroundColor Cyan

    $errors = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-NoFindings "parses without syntax errors" @($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" })
    if ($errors) { continue }

    # --- 1. Bare commands joined with logical operators -------------------------------------
    $logicalTraps = @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object {
                $cmd = $_
                $bad = @($cmd.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    Where-Object { $_.ParameterName -in @('or','and','not','band','bor') })
                if ($bad.Count -gt 0) {
                    "line $($cmd.Extent.StartLineNumber): $($cmd.GetCommandName()) receives -$($bad[0].ParameterName) as an argument - parenthesise the operands"
                }
            }
    )
    Assert-NoFindings "no bare commands joined with -and/-or" $logicalTraps

    # --- 2. Assignment to read-only automatic variables --------------------------------------
    $automaticAssignments = @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
            Where-Object { $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] } |
            Where-Object { $readOnlyAutomatics -contains $_.Left.VariablePath.UserPath.ToLower() } |
            ForEach-Object { "line $($_.Extent.StartLineNumber): assigns to `$$($_.Left.VariablePath.UserPath)" }
    )
    Assert-NoFindings "no assignment to read-only automatic variables" $automaticAssignments

    # --- 3. Mandatory [array] without AllowEmptyCollection -----------------------------------
    $emptyCollectionRisks = @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true) |
            ForEach-Object {
                $p = $_
                $attrs = @($p.Attributes | ForEach-Object { $_.TypeName.Name })
                $isArray = ($p.StaticType -and $p.StaticType.IsArray) -or ($attrs -contains 'array')
                $isMandatory = [bool](@($p.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'Parameter' } |
                    Where-Object { $_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' } }).Count)
                if ($isArray -and $isMandatory -and ($attrs -notcontains 'AllowEmptyCollection')) {
                    "line $($p.Extent.StartLineNumber): `$$($p.Name.VariablePath.UserPath) is a mandatory array without [AllowEmptyCollection()]"
                }
            }
    )
    Assert-NoFindings "mandatory array parameters accept an empty collection" $emptyCollectionRisks

    # --- 4. Format-Table on the success stream inside a value-returning function --------------
    $formatLeaks = @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object {
                $fn = $_
                $returnsValue = [bool](@($fn.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.ReturnStatementAst] -and $null -ne $n.Pipeline }, $true)).Count)
                if (-not $returnsValue) { return }
                $leaks = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true) |
                    Where-Object { $_.Extent.Text -match 'Format-Table' -and $_.Extent.Text -notmatch 'Out-Host|Out-String|Out-Null' })
                if ($leaks.Count -gt 0) {
                    "line $($leaks[0].Extent.StartLineNumber): $($fn.Name) returns a value and pipes to Format-Table without Out-Host"
                }
            }
    )
    Assert-NoFindings "no Format-Table leaking into a function's return value" $formatLeaks

    # --- 5. No module imports; modules are assumed present ------------------------------------
    # These scripts run on a prepared jump host. Importing is the host build's job, and an
    # Import-Module here either duplicates it or fights a pinned bundle already loaded.
    #
    # Strings count, not just calls. A remediation message telling the operator to run
    # Import-Module reads as an instruction from the script, and one sat in the PowerCLI load
    # diagnostic through several releases while this rule passed - it was only looking for a
    # CommandAst. Comments are exempt: describing the rule is not breaking it.
    # TWO exceptions, both guarded, and nowhere else. Auto-loading from a cold command-discovery
    # cache failed on the FIRST run of a new session and worked on the second - reproducibly, on
    # more than one machine, and again inside VS Code's integrated console where modules were
    # reported not loading on random servers.
    #
    #   1. The guarded Intersight.PowerShell load in the AUTHENTICATION region, which has to run
    #      before Set-IntersightConfiguration is referenced.
    #   2. Import-RequiredModules, which loads the run's modules once, each behind Get-Module.
    #
    # The rule this preserves is "do not fight the host build". A Get-Module guard means a module
    # already in the session - including a pinned bundle - is untouched, and nothing is installed
    # or upgraded. Everywhere else an Import-Module is still a finding.
    $importFunction = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $_.Name -eq 'Import-RequiredModules' })
    $imports = @()
    $allImportCalls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object { $_.GetCommandName() -eq 'Import-Module' })
    # Only scripts that actually load something need the function; the rule for the rest is
    # simply that they load nothing, which the finding list below already enforces.
    if ($allImportCalls.Count -gt 0 -and $importFunction.Count -ne 1) {
        $imports += "this script imports modules but has no single Import-RequiredModules to hold the guarded loads"
    }

    $inImportFunction = {
        param($node)
        foreach ($fn in $importFunction) {
            if ($node.Extent.StartOffset -ge $fn.Extent.StartOffset -and $node.Extent.EndOffset -le $fn.Extent.EndOffset) { return $true }
        }
        return $false
    }

    $importAllowed = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object { $_.GetCommandName() -eq 'Import-Module' } |
        Where-Object { ($_.Extent.Text -match '(?i)Import-Module\s+-Name\s+Intersight\.PowerShell') -or (& $inImportFunction $_) })
    $imports += @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { $_.GetCommandName() -eq 'Import-Module' } |
            Where-Object { $importAllowed -notcontains $_ } |
            ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" }
    )
    # Inside Import-RequiredModules the guard is the Get-Module -ListAvailable probe plus the
    # already-loaded check above it, both in the same function, so the per-call If guard below
    # applies only to the AUTHENTICATION region load.
    foreach ($allowed in $importAllowed) {
        if (& $inImportFunction $allowed) { continue }
        $guard = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true) |
            Where-Object { $allowed.Extent.StartOffset -ge $_.Extent.StartOffset -and $allowed.Extent.EndOffset -le $_.Extent.EndOffset -and $_.Extent.Text -match 'Get-Module -Name Intersight\.PowerShell' })
        if ($guard.Count -eq 0) { $imports += "line $($allowed.Extent.StartLineNumber): the Intersight.PowerShell load is no longer guarded by Get-Module" }
    }
    foreach ($fn in $importFunction) {
        if ($fn.Extent.Text -notmatch 'Get-Module -Name \$name') { $imports += "Import-RequiredModules no longer checks Get-Module before importing" }
        # Deliberately NO availability probe: Get-Module -ListAvailable answers a question the
        # import itself answers, and pays for walking every PSModulePath entry to do it.
        if ($fn.Extent.Text -match 'Get-Module -ListAvailable') { $imports += "Import-RequiredModules probes availability instead of just importing" }
        if ($fn.Extent.Text -match '(?i)Install-Module|Update-Module') { $imports += "Import-RequiredModules must never install or update a module" }
    }
    $imports += @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            Where-Object { $_.Value -match '(?i)\bImport-Module\b' } |
            Where-Object { $node = $_; -not [bool](@($importAllowed | Where-Object { $node.Extent.StartOffset -ge $_.Extent.StartOffset -and $node.Extent.EndOffset -le $_.Extent.EndOffset }).Count) } |
            ForEach-Object { "line $($_.Extent.StartLineNumber): a string tells the operator to run Import-Module - $($_.Extent.Text.Trim())" }
    )
    $imports += @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) |
            Where-Object { $_.Value -match '(?i)\bImport-Module\b' } |
            ForEach-Object { "line $($_.Extent.StartLineNumber): a string tells the operator to run Import-Module - $($_.Extent.Text.Trim())" }
    )
    Assert-NoFindings "no Import-Module - not called, and not suggested in a message" $imports

    # --- 6. @() around a Generic.List[object] variable ------------------------------------------
    # Wrapping a System.Collections.Generic.List[object] in an array subexpression throws
    # "Argument types do not match" on this PowerShell build. Nothing warns at parse time, and the
    # throw lands wherever the list is read - which twice has been AFTER the work was done: once in
    # the closing manual-rectification report, once in the batch activation poll.
    #
    # ONLY List[object] is affected. List[string] and List[int] wrap fine, verified directly, so
    # flagging those would be a false alarm on working code - and a lint rule that cries wolf gets
    # switched off. $list.ToArray() is the portable form and also makes a snapshot that is safe to
    # enumerate while the list is modified.
    #
    # Each @(...) is judged against its OWN enclosing function. The same variable name is commonly
    # an ArrayList in one function and a List[object] in another, so anything wider than the
    # innermost scope reports the innocent one.
    $allFunctions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))

    function Get-EnclosingScope {
        param($Node, $Functions, $Root)
        $inner = $null
        foreach ($fn in $Functions) {
            if ($Node.Extent.StartOffset -ge $fn.Extent.StartOffset -and $Node.Extent.EndOffset -le $fn.Extent.EndOffset) {
                if ($null -eq $inner -or $fn.Extent.StartOffset -gt $inner.Extent.StartOffset) { $inner = $fn }
            }
        }
        if ($null -eq $inner) { return $Root }
        return $inner
    }

    $listWraps = @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true) |
            ForEach-Object {
                $wrap = $_
                $inner = $wrap.SubExpression.Statements
                if ($inner.Count -ne 1) { return }
                $pipeline = $inner[0] -as [System.Management.Automation.Language.PipelineAst]
                if ($null -eq $pipeline -or $pipeline.PipelineElements.Count -ne 1) { return }
                $expression = $pipeline.PipelineElements[0] -as [System.Management.Automation.Language.CommandExpressionAst]
                if ($null -eq $expression) { return }
                $variable = $expression.Expression -as [System.Management.Automation.Language.VariableExpressionAst]
                if ($null -eq $variable) { return }

                $scope = Get-EnclosingScope -Node $wrap -Functions $allFunctions -Root $ast
                $name = $variable.VariablePath.UserPath.ToLower()
                $declared = @($scope.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
                    Where-Object {
                        $target = $_.Left -as [System.Management.Automation.Language.VariableExpressionAst]
                        $null -ne $target -and $target.VariablePath.UserPath.ToLower() -eq $name -and
                        $_.Right.Extent.Text -match '(?i)Collections\.Generic\.List\s*\[\s*(System\.)?Object\s*\]'
                    })
                if ($declared.Count -eq 0) { return }
                "line $($wrap.Extent.StartLineNumber): @(`$$($variable.VariablePath.UserPath)) wraps a Generic.List[object] - use .ToArray()"
            }
    )
    Assert-NoFindings "no array subexpression wrapping a Generic.List[object]" @($listWraps | Select-Object -Unique)

    # --- 7. Uncached module enumeration -------------------------------------------------------
    $cacheFunction = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AvailableModuleVersion' }, $true))
    $enumerations = @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { $_.GetCommandName() -eq 'Get-Module' } |
            Where-Object { @($_.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ListAvailable' }).Count -gt 0 } |
            Where-Object {
                $offset = $_.Extent.StartOffset
                -not [bool](@($cacheFunction | Where-Object { $offset -ge $_.Extent.StartOffset -and $offset -lt $_.Extent.EndOffset }).Count)
            } |
            ForEach-Object { "line $($_.Extent.StartLineNumber): Get-Module -ListAvailable outside Get-AvailableModuleVersion" }
    )
    # Only enforced where the caching helper exists; the smaller scripts enumerate once by design.
    if ($cacheFunction.Count -gt 0) {
        Assert-NoFindings "module enumeration goes through the cache" $enumerations
    }
    else {
        Assert-NoFindings "module enumeration is bounded" @($enumerations | Select-Object -Skip 3)
    }

    # --- 8. A helper that only exists in a SIBLING script ---------------------------------------
    # SHIPPED AND HIT ON A LIVE RUN. A change routed Import-RequiredModules through
    # Get-AvailableModuleVersion in both variants, but that helper is a declared parity exception
    # and exists only in the Control build. The PreAuth build - the one that gets run - died on its
    # first line of work with "The term 'Get-AvailableModuleVersion' is not recognized".
    #
    # Nothing caught it. The tests import functions by name into a scope where the stubs already
    # exist, so a missing definition never surfaces; the parity test allows the two files to differ
    # in declared places; and the dead-code scan looks for functions DEFINED and never called, not
    # for functions CALLED and never defined.
    #
    # Only names that are functions somewhere in this repo are considered, so vendor cmdlets and
    # PowerShell built-ins cannot produce a false finding.
    $definedHere = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $definedHere[$f.Name] = $true
    }
    $foreignCalls = @(
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object {
                $called = $_.GetCommandName()
                $called -and $definedAnywhere.ContainsKey($called) -and -not $definedHere.ContainsKey($called)
            } |
            ForEach-Object {
                $called = $_.GetCommandName()
                "line $($_.Extent.StartLineNumber): calls '$called', which is only defined in $(($definedAnywhere[$called] | Sort-Object -Unique) -join ', ')"
            }
    )
    Assert-NoFindings "every helper it calls is defined in this script" $foreignCalls
}

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
