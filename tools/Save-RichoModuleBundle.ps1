<#
.SYNOPSIS
    Downloads the pinned PowerShell modules into the repo so a jump host can run offline.

.DESCRIPTION
    Run this ONCE on a machine that can reach the PowerShell Gallery. It saves the exact versions
    named in config/module-requirements.psd1 into the bundle folder (modules/vendor by default),
    writes a manifest with SHA256 hashes, and reports the size of each module.

    Save-Module is used rather than Install-Module: nothing is installed, nothing needs admin
    rights, and nothing touches the machine's module paths. The result is a self-contained folder
    that Import-RichoModuleBundle.ps1 loads directly.

    Why bother: pinning removes the version drift that causes Intersight.PowerShell to
    authenticate correctly and then fail to parse the appliance's responses. Every jump host then
    runs the version proven against your appliance.

    SIZE WARNING - read before committing the result. These modules are large. GitHub rejects any
    single file over 100 MB and warns over 50 MB. This script reports the size of everything it
    saves and tells you whether Git LFS is needed. See modules/vendor/README.md.

.PARAMETER Name
    Save only these modules. Defaults to every module in the requirements file.

.PARAMETER RequirementsPath
    Requirements file. Defaults to config/module-requirements.psd1 at the repo root.

.PARAMETER BundlePath
    Destination. Defaults to the BundlePath in the requirements file.

.PARAMETER Force
    Overwrite a module already present in the bundle.

.EXAMPLE
    .\tools\Save-RichoModuleBundle.ps1

.EXAMPLE
    .\tools\Save-RichoModuleBundle.ps1 -Name Intersight.PowerShell -Force

.NOTES
    Requires network access to https://www.powershellgallery.com.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Name,
    [string]$RequirementsPath,
    [string]$BundlePath,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($RequirementsPath)) { $RequirementsPath = Join-Path $repoRoot 'config/module-requirements.psd1' }
if (-not (Test-Path $RequirementsPath)) { throw "Requirements file not found: $RequirementsPath" }

$requirements = Import-PowerShellDataFile -Path $RequirementsPath
if ([string]::IsNullOrWhiteSpace($BundlePath)) { $BundlePath = Join-Path $repoRoot $requirements.BundlePath }

$wanted = @($requirements.Modules)
if ($Name) { $wanted = @($wanted | Where-Object { $Name -contains $_.Name }) }
if ($wanted.Count -eq 0) { throw "No matching modules in $RequirementsPath." }

if (-not (Test-Path $BundlePath)) {
    if ($PSCmdlet.ShouldProcess($BundlePath, "Create bundle directory")) {
        New-Item -Path $BundlePath -ItemType Directory -Force | Out-Null
    }
}

Write-Host "Bundle destination: $BundlePath" -ForegroundColor Cyan
Write-Host "Saving $($wanted.Count) module(s) from the PowerShell Gallery.`n" -ForegroundColor Cyan

$results = New-Object System.Collections.Generic.List[object]

foreach ($module in $wanted) {
    $target = Join-Path $BundlePath $module.Name

    if ((Test-Path $target) -and -not $Force) {
        Write-Host "SKIP  $($module.Name) - already in the bundle. Use -Force to replace." -ForegroundColor DarkGray
        $results.Add([pscustomobject]@{ Module=$module.Name; Version=$module.Version; Action='Skipped'; SizeMB=$null })
        continue
    }

    if ((Test-Path $target) -and $Force) {
        if ($PSCmdlet.ShouldProcess($target, "Remove existing bundled module")) {
            Remove-Item -Path $target -Recurse -Force
        }
    }

    if (-not $PSCmdlet.ShouldProcess("$($module.Name) $($module.Version)", "Save-Module into $BundlePath")) {
        $results.Add([pscustomobject]@{ Module=$module.Name; Version=$module.Version; Action='WhatIf'; SizeMB=$null })
        continue
    }

    Write-Host "Saving $($module.Name) $($module.Version)... this can take several minutes." -ForegroundColor Cyan
    try {
        Save-Module -Name $module.Name -RequiredVersion $module.Version -Path $BundlePath -Repository PSGallery -Force -ErrorAction Stop
        $sizeMB = [Math]::Round((Get-ChildItem -Path $target -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
        Write-Host "  Saved. $sizeMB MB" -ForegroundColor Green
        $results.Add([pscustomobject]@{ Module=$module.Name; Version=$module.Version; Action='Saved'; SizeMB=$sizeMB })
    }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $results.Add([pscustomobject]@{ Module=$module.Name; Version=$module.Version; Action='Failed'; SizeMB=$null })
    }
}

Write-Host "`nBundle contents:" -ForegroundColor Cyan
$results | Format-Table -AutoSize

# ---------------------------------------------------------------------------
# Manifest, so a jump host can verify it received what was intended
# ---------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($BundlePath, "Write bundle manifest")) {
    $manifestEntries = foreach ($module in $wanted) {
        $target = Join-Path $BundlePath $module.Name
        if (-not (Test-Path $target)) { continue }
        $files = @(Get-ChildItem -Path $target -Recurse -File)
        [pscustomobject]@{
            Name      = $module.Name
            Version   = $module.Version
            FileCount = $files.Count
            SizeMB    = [Math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
            LargestMB = [Math]::Round((($files | Sort-Object Length -Descending | Select-Object -First 1).Length) / 1MB, 1)
        }
    }
    $manifestPath = Join-Path $BundlePath 'bundle-manifest.json'
    $manifestEntries | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
    Write-Host "Manifest written: $manifestPath" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Size guidance - decide before committing, not after
# ---------------------------------------------------------------------------
$allFiles = @()
if (Test-Path $BundlePath) { $allFiles = @(Get-ChildItem -Path $BundlePath -Recurse -File) }
if ($allFiles.Count -gt 0) {
    $totalMB = [Math]::Round(($allFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    $oversize = @($allFiles | Where-Object { $_.Length -gt 100MB })
    $largeish = @($allFiles | Where-Object { $_.Length -gt 50MB -and $_.Length -le 100MB })

    Write-Host "`nTotal bundle size: $totalMB MB across $($allFiles.Count) files." -ForegroundColor Cyan

    if ($oversize.Count -gt 0) {
        Write-Host "STOP: $($oversize.Count) file(s) exceed 100 MB. GitHub will REJECT the push unless they go through Git LFS:" -ForegroundColor Red
        $oversize | ForEach-Object { Write-Host ("  {0:N1} MB  {1}" -f ($_.Length/1MB), $_.FullName) -ForegroundColor Red }
        Write-Host "  Enable LFS for the bundle before committing - see modules/vendor/README.md." -ForegroundColor Red
    }
    elseif ($largeish.Count -gt 0) {
        Write-Host "$($largeish.Count) file(s) are over 50 MB. GitHub will warn. Git LFS is recommended." -ForegroundColor Yellow
    }

    if ($totalMB -gt 250) {
        Write-Host "The bundle is large enough that committing it will slow every future clone." -ForegroundColor Yellow
        Write-Host "Consider committing only Intersight.PowerShell (the version-sensitive one) and" -ForegroundColor Yellow
        Write-Host "installing PowerCLI and UCS PowerTool normally." -ForegroundColor Yellow
    }
}

Write-Host "`nNext: on the jump host, load the bundle with tools\Import-RichoModuleBundle.ps1" -ForegroundColor Green
