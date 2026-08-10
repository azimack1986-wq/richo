<#
.SYNOPSIS
    Loads the repo's bundled PowerShell modules, ahead of anything installed on the machine.

.DESCRIPTION
    Dot-source this on the jump host before running the firmware controller:

        . .\tools\Import-RichoModuleBundle.ps1

    It puts modules/vendor at the FRONT of $env:PSModulePath for the current session only, so the
    pinned versions win over anything installed machine-wide. Nothing is installed, no admin
    rights are needed, and the machine's own modules are left untouched - close the session and
    everything is as it was.

    This is what makes the version pinning real. A machine-wide Intersight.PowerShell that
    disagrees with the appliance stays on disk but is no longer what loads, so the run behaves the
    same on every jump host.

    Reports what it found, what actually loaded, and any machine-wide copy it is shadowing.

.PARAMETER Name
    Load only these modules. Defaults to every module present in the bundle.

.PARAMETER RequirementsPath
    Requirements file. Defaults to config/module-requirements.psd1 at the repo root.

.PARAMETER BundlePath
    Bundle location. Defaults to the BundlePath in the requirements file.

.PARAMETER PassThru
    Return the result table instead of only printing it.

.EXAMPLE
    . .\tools\Import-RichoModuleBundle.ps1

.EXAMPLE
    . .\tools\Import-RichoModuleBundle.ps1 -Name Intersight.PowerShell
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$Name,
    [string]$RequirementsPath,
    [string]$BundlePath,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($RequirementsPath)) { $RequirementsPath = Join-Path $repoRoot 'config/module-requirements.psd1' }
if (-not (Test-Path $RequirementsPath)) { throw "Requirements file not found: $RequirementsPath" }

$requirements = Import-PowerShellDataFile -Path $RequirementsPath
if ([string]::IsNullOrWhiteSpace($BundlePath)) { $BundlePath = Join-Path $repoRoot $requirements.BundlePath }

if (-not (Test-Path $BundlePath)) {
    Write-Host "No module bundle at '$BundlePath'." -ForegroundColor Yellow
    Write-Host "Run tools\Save-RichoModuleBundle.ps1 on a machine with PowerShell Gallery access, then bring the repo across." -ForegroundColor Yellow
    return
}

$bundled = @(Get-ChildItem -Path $BundlePath -Directory -ErrorAction SilentlyContinue)
if ($Name) { $bundled = @($bundled | Where-Object { $Name -contains $_.Name }) }

if ($bundled.Count -eq 0) {
    Write-Host "Bundle directory '$BundlePath' contains no modules." -ForegroundColor Yellow
    return
}

# Front of the path, current session only. Prepending is the point: a machine-wide copy of a
# different version must not win.
$resolvedBundle = (Resolve-Path $BundlePath).Path
$currentPaths = @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ -ne $resolvedBundle })
$env:PSModulePath = (@($resolvedBundle) + $currentPaths) -join [IO.Path]::PathSeparator

Write-Host "Bundle added to the front of PSModulePath for this session:" -ForegroundColor Cyan
Write-Host "  $resolvedBundle" -ForegroundColor Gray

$results = New-Object System.Collections.Generic.List[object]

foreach ($dir in $bundled) {
    $moduleName = $dir.Name

    # Note what is being shadowed, so a surprise later is not a mystery.
    $machineWide = @(
        Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue |
            Where-Object { -not $_.ModuleBase.StartsWith($resolvedBundle, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -ExpandProperty Version -Unique
    )

    $bundledVersion = $null
    try {
        $bundledVersion = @(
            Get-Module -ListAvailable -Name $moduleName |
                Where-Object { $_.ModuleBase.StartsWith($resolvedBundle, [StringComparison]::OrdinalIgnoreCase) } |
                Sort-Object Version -Descending | Select-Object -First 1
        )[0]
    } catch {}

    $loaded = $null
    $status = 'NotLoaded'
    try {
        if ($null -ne $bundledVersion) {
            Import-Module -Name $bundledVersion.Path -Force -Global -ErrorAction Stop
            $loaded = (Get-Module -Name $moduleName | Select-Object -First 1)
            $status = 'Loaded'
        }
        else {
            $status = 'NotFoundInBundle'
        }
    }
    catch {
        $status = "Failed: $($_.Exception.Message)"
    }

    $results.Add([pscustomobject]@{
        Module          = $moduleName
        BundledVersion  = if ($bundledVersion) { $bundledVersion.Version.ToString() } else { '-' }
        LoadedVersion   = if ($loaded) { $loaded.Version.ToString() } else { '-' }
        Status          = $status
        ShadowedMachine = if ($machineWide.Count -gt 0) { ($machineWide | ForEach-Object { $_.ToString() }) -join ', ' } else { 'none' }
    })
}

Write-Host ""
# Out-Host, not bare Format-Table: this script is dot-sourced, so anything left on the success
# stream is returned to the caller. Without this, -PassThru hands back Format-Table's internal
# rendering records instead of the result objects.
$results | Format-Table -AutoSize | Out-Host

$shadowing = @($results | Where-Object { $_.ShadowedMachine -ne 'none' })
if ($shadowing.Count -gt 0) {
    Write-Host "The bundled versions above are shadowing machine-wide installs for this session only." -ForegroundColor Yellow
    Write-Host "Nothing on the machine has been changed or removed." -ForegroundColor Yellow
}

$failed = @($results | Where-Object { $_.Status -notlike 'Loaded*' })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) module(s) did not load. Check the bundle is complete for this PowerShell edition." -ForegroundColor Red
}
else {
    Write-Host "All bundled modules loaded. Run the firmware controller from this same session." -ForegroundColor Green
}

if ($PassThru) { $results }
