<#
.SYNOPSIS
    Guards the pre-authenticated variant against drifting from the main controller.

.DESCRIPTION
    Invoke-AutoDeployFirmwareBatchPreAuth.ps1 is derived from
    Invoke-AutoDeployFirmwareBatchControl.ps1 with the Intersight authentication removed. Two
    near-identical scripts of this size will diverge: a fix lands in one and not the other, and
    nobody notices until a change window.

    This compares every function the two share and fails if any body differs, other than the small
    set listed in $ExpectedDifferences. It also asserts the properties that define the variant:
    no authentication functions, and no Set-IntersightConfiguration call anywhere.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-PreAuthVariantParity.ps1
#>

$repoRoot   = Split-Path $PSScriptRoot -Parent
$mainPath   = Join-Path $repoRoot 'scripts/firmware/Invoke-AutoDeployFirmwareBatchControl.ps1'
$preAuthPath = Join-Path $repoRoot 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'

# Functions that are deliberately different between the two builds. Each entry is a decision, not
# a licence to drift - anything not listed here must stay byte-identical, and the final section
# fails if a listed function stops differing, so stale exceptions cannot mask a regression.
$ExpectedDifferences = @(
    'Confirm-RunPrerequisites',              # pre-auth asks for no credentials
    'Assert-IntersightPowerShellAvailable',  # points at the readiness probe, not login diagnostics
    'Build-InfrastructureHostMapping',       # no appliance FQDN prompt on fabric detection
    'Initialize-IntersightRoutedHosts',      # verifies the caller's connection instead of logging in
    'Resolve-IntersightServerProfileForHost' # same, at its point of use
)

# Functions that exist only to establish Intersight authentication, and must not appear in the
# pre-authenticated build.
$AuthOnlyFunctions = @(
    'Connect-IntersightTarget',
    'Get-IntersightCredentialIfNeeded',
    'Get-IntersightBaseUrlIfNeeded',
    'ConvertTo-IntersightBaseUrl',
    'Test-IntersightSaaSUrl',
    'Show-OpenFileDialog',
    'Write-IntersightLoginDiagnostics',
    'Test-IntersightEndpointReachable'
)

function Get-ScriptFunctions {
    param([string]$Path)
    $errors = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "parse errors in $Path" }
    $map = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $map[$f.Name] = $f.Extent.Text
    }
    return @{
        Ast       = $ast
        Functions = $map
        Calls     = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
    }
}

function Get-ConfigurationCallSites {
    <#
        Every Set-IntersightConfiguration call, with whether it sits inside the operator's
        AUTHENTICATION region and whether it is inside a function.
    #>
    param([string]$Path, $Ast)

    $text = [System.IO.File]::ReadAllText($Path)
    $start = $text.IndexOf('# >>> BEGIN INTERSIGHT AUTHENTICATION >>>')
    $end   = $text.IndexOf('# <<< END INTERSIGHT AUTHENTICATION <<<')

    $functions = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))

    return @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object { $_.GetCommandName() -eq 'Set-IntersightConfiguration' } |
        ForEach-Object {
            $offset = $_.Extent.StartOffset
            [pscustomobject]@{
                Line       = $_.Extent.StartLineNumber
                InRegion   = ($start -ge 0 -and $end -gt $start -and $offset -gt $start -and $offset -lt $end)
                InFunction = [bool](@($functions | Where-Object { $offset -ge $_.Extent.StartOffset -and $offset -lt $_.Extent.EndOffset }).Count)
            }
        })
}

$script:pass = 0; $script:fail = 0
function Assert-True {
    param([string]$Name,[bool]$Condition,[string]$Detail = "")
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name$(if($Detail){" - $Detail"})" -ForegroundColor Red }
}

$main    = Get-ScriptFunctions -Path $mainPath
$preAuth = Get-ScriptFunctions -Path $preAuthPath

Write-Host "`n=== The variant is defined by what it does NOT do ===" -ForegroundColor Cyan
foreach ($fn in $AuthOnlyFunctions) {
    Assert-True "pre-auth build does not define $fn" (-not $preAuth.Functions.ContainsKey($fn))
    Assert-True "pre-auth build does not call $fn"   ($preAuth.Calls -notcontains $fn)
}
Assert-True "pre-auth build verifies the connection instead" ($preAuth.Calls -contains 'Assert-IntersightReady')
Assert-True "main build still authenticates"                 ($main.Calls -contains 'Set-IntersightConfiguration')

# The script's own code must never configure Intersight. The operator's block inside the
# AUTHENTICATION markers may, and is guarded to run once per session - which is the whole point of
# this build, so the invariant is "only there", not "nowhere".
$configCalls = @(Get-ConfigurationCallSites -Path $preAuthPath -Ast $preAuth.Ast)
Assert-True "at most one Set-IntersightConfiguration call exists" ($configCalls.Count -le 1) "found $($configCalls.Count) at line(s) $(($configCalls.Line) -join ', ')"
foreach ($call in $configCalls) {
    Assert-True "the call at line $($call.Line) is inside the AUTHENTICATION region" $call.InRegion
    Assert-True "the call at line $($call.Line) is not inside a function"            (-not $call.InFunction)
}

# Guarded, so re-running the script in one session cannot re-apply it.
$preAuthText = [System.IO.File]::ReadAllText($preAuthPath)
Assert-True "the configuration call is guarded by IntersightConfigurationApplied" ($preAuthText -match 'if \(-not \$Global:IntersightConfigurationApplied\)')

Write-Host "`n=== Shared functions must stay identical ===" -ForegroundColor Cyan
$shared = @($main.Functions.Keys | Where-Object { $preAuth.Functions.ContainsKey($_) } | Sort-Object)
Assert-True "the two builds share a substantial body of code" ($shared.Count -gt 30) "shared: $($shared.Count)"

$drifted = New-Object System.Collections.Generic.List[string]
foreach ($fn in $shared) {
    if ($ExpectedDifferences -contains $fn) { continue }
    if ($main.Functions[$fn] -ne $preAuth.Functions[$fn]) { [void]$drifted.Add($fn) }
}
Assert-True "no shared function has drifted" ($drifted.Count -eq 0) "drifted: $($drifted -join ', ')"

if ($drifted.Count -gt 0) {
    Write-Host "`n  These functions differ between the two builds. Port the change across, or add the" -ForegroundColor Yellow
    Write-Host "  function to `$ExpectedDifferences in this test if the difference is intended:" -ForegroundColor Yellow
    $drifted | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}

Write-Host "`n=== Each expected difference must actually still differ ===" -ForegroundColor Cyan
# A stale exception is as bad as undetected drift - it would hide a real regression.
foreach ($fn in $ExpectedDifferences) {
    if (-not ($main.Functions.ContainsKey($fn) -and $preAuth.Functions.ContainsKey($fn))) {
        Assert-True "$fn exists in both builds" $false "listed as an expected difference but missing from one build"
        continue
    }
    Assert-True "$fn genuinely differs, so the exception is still earned" ($main.Functions[$fn] -ne $preAuth.Functions[$fn])
}

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
