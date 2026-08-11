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
      5. Get-Module -ListAvailable outside the caching helper. Repeated enumeration of a module
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
    Join-Path $repoRoot 'tools/Save-RichoModuleBundle.ps1'
    Join-Path $repoRoot 'tools/Import-RichoModuleBundle.ps1'
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

    # --- 5. Uncached module enumeration -------------------------------------------------------
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
}

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
