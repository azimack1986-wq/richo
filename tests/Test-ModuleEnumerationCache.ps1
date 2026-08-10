<#
.SYNOPSIS
    Tests that module enumeration is cached.

.DESCRIPTION
    Get-Module -ListAvailable walks every PSModulePath entry and parses each manifest it finds.
    For Intersight.PowerShell, whose manifest exports several thousand cmdlets, that is slow
    enough on a domain jump host to read as a hang when repeated.

    The pre-flight no longer probes for modules at all - requirements are stated in the script
    header and assumed - but Get-AvailableModuleVersion survives on the failure path, where the
    Intersight login diagnostics report installed versions. These cases keep it honest: enumerate
    once per module, never again unless explicitly refreshed.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-ModulePresence.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchControl.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'Get-AvailableModuleVersion' } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$Global:ModuleVersionCache = @{}
$Global:SlowModulePathReported = $false

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# Stub standing in for the real cmdlet inside the extracted function, counting enumerations.
$script:EnumerationCount = 0
$script:StubVersions = @('1.0.11.17')
function Get-Module { param([switch]$ListAvailable,[string]$Name,$ErrorAction)
    $script:EnumerationCount++
    $script:StubVersions | ForEach-Object { [pscustomobject]@{ Version = [version]$_ } } }

Write-Host "`n=== Enumeration happens once per module ===" -ForegroundColor Cyan

[void](Get-AvailableModuleVersion -Name 'Intersight.PowerShell')
Assert-Equal "first lookup enumerates once" 1 $script:EnumerationCount

[void](Get-AvailableModuleVersion -Name 'Intersight.PowerShell')
[void](Get-AvailableModuleVersion -Name 'Intersight.PowerShell')
[void](Get-AvailableModuleVersion -Name 'Intersight.PowerShell')
Assert-Equal "three further lookups add no enumerations" 1 $script:EnumerationCount

[void](Get-AvailableModuleVersion -Name 'VMware.VimAutomation.Core')
Assert-Equal "a different module enumerates on its own" 2 $script:EnumerationCount

[void](Get-AvailableModuleVersion -Name 'VMware.VimAutomation.Core')
Assert-Equal "the second module is cached too" 2 $script:EnumerationCount

[void](Get-AvailableModuleVersion -Name 'Intersight.PowerShell' -Refresh)
Assert-Equal "-Refresh forces a re-enumeration" 3 $script:EnumerationCount

[void](Get-AvailableModuleVersion -Name 'Intersight.PowerShell')
Assert-Equal "the refreshed result is cached again" 3 $script:EnumerationCount

Write-Host "`n=== Results are returned, not just counted ===" -ForegroundColor Cyan
$Global:ModuleVersionCache = @{}
$script:StubVersions = @('1.0.11.17','1.0.9.5')
$found = @(Get-AvailableModuleVersion -Name 'Intersight.PowerShell')
Assert-Equal "both versions returned" 2 $found.Count
Assert-Equal "newest version first" "1.0.11.17" $found[0].Version.ToString()

$Global:ModuleVersionCache = @{}
$script:StubVersions = @()
$found = @(Get-AvailableModuleVersion -Name 'No.Such.Module')
Assert-Equal "a module with no versions returns empty" 0 $found.Count

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
