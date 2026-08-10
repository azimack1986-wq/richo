<#
.SYNOPSIS
    Tests the pre-flight module presence check.

.DESCRIPTION
    Extracts Get-ModulePresenceReport from the controller by AST and drives it with stubbed
    Get-Module / Get-Command, covering the three states that decide what the pre-flight warns
    about: OK, MISSING, and MULTIPLE (side-by-side versions, the documented cause of Intersight
    authentication failures with a valid key).

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-ModulePresence.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchControl.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'Get-ModulePresenceReport' } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# Stubs standing in for the real cmdlets inside the extracted function.
$script:StubVersions = @()
$script:StubCmdletPresent = $false
function Get-Module { param([switch]$ListAvailable,[string]$Name,$ErrorAction)
    $script:StubVersions | ForEach-Object { [pscustomobject]@{ Version = [version]$_ } } }
function Get-Command { param([string]$Name,$ErrorAction)
    if ($script:StubCmdletPresent) { [pscustomobject]@{ Name = $Name } } else { $null } }

function Invoke-Report {
    param([string[]]$Versions,[bool]$CmdletPresent)
    $script:StubVersions = $Versions
    $script:StubCmdletPresent = $CmdletPresent
    return Get-ModulePresenceReport -Label "Cisco Intersight" -ModuleName "Intersight.PowerShell" -ProbeCmdlet "Set-IntersightConfiguration"
}

Write-Host "`n=== Module presence states ===" -ForegroundColor Cyan

$r = Invoke-Report -Versions @('1.0.11.17') -CmdletPresent $true
Assert-Equal "single installed version reports OK" "OK" $r.Status
Assert-Equal "single version is listed" "1.0.11.17" $r.Versions

$r = Invoke-Report -Versions @('1.0.11.17','1.0.9.5') -CmdletPresent $true
Assert-Equal "side-by-side versions report MULTIPLE" "MULTIPLE" $r.Status
Assert-Equal "both versions are listed" "1.0.11.17, 1.0.9.5" $r.Versions

$r = Invoke-Report -Versions @() -CmdletPresent $false
Assert-Equal "nothing installed reports MISSING" "MISSING" $r.Status
Assert-Equal "missing module shows no versions" "-" $r.Versions

# Vendor bundles can register cmdlets under a differently-named module, so a working cmdlet
# still counts as present rather than being reported as missing.
$r = Invoke-Report -Versions @() -CmdletPresent $true
Assert-Equal "cmdlet present under another module name still counts as installed" "OK" $r.Status
Assert-Equal "unknown version is stated rather than implied" "present (version not reported)" $r.Versions

$r = Invoke-Report -Versions @('1.0.11.17','1.0.9.5','1.0.7.1') -CmdletPresent $true
Assert-Equal "three versions still report MULTIPLE" "MULTIPLE" $r.Status

$r = Invoke-Report -Versions @('1.0.11.17') -CmdletPresent $true
Assert-Equal "component label is carried through" "Cisco Intersight" $r.Component
Assert-Equal "module name is carried through" "Intersight.PowerShell" $r.Module

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
