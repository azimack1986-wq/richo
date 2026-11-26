<#
.SYNOPSIS
    Tests the VIB version comparison and the swap plan in New-AutoDeployVendorImageProfile.ps1.

.DESCRIPTION
    The plan decides which inbox VIBs are removed and which vendor VIBs replace them. A wrong
    comparison either downgrades a driver or leaves the old one in place, and neither shows
    until a host boots the image. The properties asserted here:

      - the version part of a VIB version decides, numerically per segment (2.0.15 > 2.0.4);
      - the packager tag in the release part (vmw, OEM) does not decide;
      - a newer vendor VIB replaces, an equal one is kept, an older one is never applied;
      - a vendor VIB with no counterpart is added, or skipped under -ReplaceOnly;
      - -RemoveVib removes, and cannot name a VIB that is also being applied;
      - when several versions are offered, the newest is chosen and the others are reported;
      - the finished-profile check catches a VIB left at the old version;
      - a package below the clone's acceptance level is found before the clone is made;
      - an unticked row changes nothing, and the check expects the ESXi image as it was.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-VendorImageProfilePlan.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vsphere/New-AutoDeployVendorImageProfile.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors in ${scriptPath}: $($errors | ForEach-Object { $_.Message })" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('ConvertTo-VibVersionSegment', 'Compare-VibVersionText', 'Compare-VibVersion',
            'Select-NewestVib', 'Get-VibSwapPlan', 'Get-DefaultProfileName', 'Find-ProfileVib',
            'Test-ProfileMatchesPlan', 'Get-OptionalProperty',
            'Get-AcceptanceRank', 'Get-AcceptanceShortfall', 'Read-ProfileName', 'Compare-VibSet', 'Set-PlanExclusion') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}
function Assert-Throws {
    param([string]$Name, [scriptblock]$Block)
    try { & $Block; $script:fail++; Write-Host "  FAIL  $Name (did not throw)" -ForegroundColor Red }
    catch { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
}
function New-Vib { param($Name, $Version, $Source = 'vendor.zip')
    [pscustomobject]@{ Name = $Name; Version = $Version; Source = $Source; Package = "pkg:${Name}:${Version}"; Superseded = '' } }
function Get-Row { param($Plan, $Name) @($Plan | Where-Object { $_.Name -eq $Name })[0] }

Write-Host "`n=== Compare-VibVersion ===" -ForegroundColor Cyan
Assert-Equal 'numeric per segment: 2.0.15 newer than 2.0.4' 1 (Compare-VibVersion '2.0.15.0-1OEM.800.1.0.20613240' '2.0.4.0-1OEM.800.1.0.20613240')
Assert-Equal 'vendor major version newer than inbox' 1 (Compare-VibVersion '2.0.15.0-1OEM.800.1.0.20613240' '1.0.45.0-1vmw.800.1.0.20513097')
Assert-Equal 'older vendor VIB reads as older' -1 (Compare-VibVersion '1.0.33.0-1OEM.700.1.0.15843807' '1.0.45.0-1vmw.800.1.0.20513097')
Assert-Equal 'same version, vmw vs OEM tag is equal' 0 (Compare-VibVersion '5.0.0.37-1OEM.800.1.0.20613240' '5.0.0.37-1vmw.800.1.0.20513097')
Assert-Equal 'same version, release 2 newer than release 1' 1 (Compare-VibVersion '5.0.0.37-2OEM.800.1.0.20613240' '5.0.0.37-1OEM.800.1.0.20613240')
Assert-Equal 'identical strings are equal' 0 (Compare-VibVersion '4.1.0.0-1OEM.700.1.0.15525992' '4.1.0.0-1OEM.700.1.0.15525992')
Assert-Equal 'missing segment counts as zero' 0 (Compare-VibVersion '2.0-1OEM' '2.0.0.0-1OEM')
Assert-Equal 'letter suffix sorts above bare number' 1 (Compare-VibVersion '4.0a-1OEM' '4.0-1OEM')
Assert-Equal 'no release part still compares' 1 (Compare-VibVersion '3.1' '3.0.9')

Write-Host "`n=== Select-NewestVib ===" -ForegroundColor Cyan
$offered = @(
    New-Vib 'nenic' '2.0.11.0-1OEM.800.1.0.20613240' 'cisco-addon.zip'
    New-Vib 'nenic' '2.0.15.0-1OEM.800.1.0.20613240' 'cisco-nenic.zip'
    New-Vib 'nfnic' '5.0.0.43-1OEM.800.1.0.20613240' 'cisco-addon.zip'
)
$newest = Select-NewestVib -Candidate $offered
Assert-Equal 'one row per name' 2 $newest.Count
Assert-Equal 'newest nenic chosen' '2.0.15.0-1OEM.800.1.0.20613240' (Get-Row $newest 'nenic').Version
Assert-Equal 'source of the chosen VIB kept' 'cisco-nenic.zip' (Get-Row $newest 'nenic').Source
Assert-Equal 'superseded version reported' $true ((Get-Row $newest 'nenic').Superseded -like '*2.0.11.0*cisco-addon.zip*')
Assert-Equal 'single offer has nothing superseded' '' (Get-Row $newest 'nfnic').Superseded
Assert-Equal 'empty input gives empty output' 0 (Select-NewestVib -Candidate @()).Count

Write-Host "`n=== Get-VibSwapPlan ===" -ForegroundColor Cyan
$base = @(
    [pscustomobject]@{ Name = 'esx-base'; Version = '8.0.3-0.55.24677879' }
    [pscustomobject]@{ Name = 'nenic'; Version = '1.0.45.0-1vmw.800.1.0.20513097' }
    [pscustomobject]@{ Name = 'nfnic'; Version = '5.0.0.43-1vmw.800.1.0.20513097' }
    [pscustomobject]@{ Name = 'lsi-mr3'; Version = '7.727.02.00-1vmw.800.1.0.20513097' }
    [pscustomobject]@{ Name = 'nmlx4-en'; Version = '3.19.70.1-1vmw.800.1.0.20513097' }
)
$vendor = @(
    New-Vib 'nenic' '2.0.15.0-1OEM.800.1.0.20613240'
    New-Vib 'nfnic' '5.0.0.43-1OEM.800.1.0.20613240'
    New-Vib 'lsi-mr3' '7.700.01.00-1OEM.700.1.0.15843807'
    New-Vib 'NetAppNasPlugin' '2.0.1-16' 'netapp.zip'
)
$plan = Get-VibSwapPlan -BaseVib $base -VendorVib $vendor -RemoveVib 'nmlx4-en', 'not-there'
Assert-Equal 'newer vendor nenic replaces inbox' 'Replace' (Get-Row $plan 'nenic').Action
Assert-Equal 'replace row carries the base version' '1.0.45.0-1vmw.800.1.0.20513097' (Get-Row $plan 'nenic').BaseVersion
Assert-Equal 'replace row carries the package to add' 'pkg:nenic:2.0.15.0-1OEM.800.1.0.20613240' (Get-Row $plan 'nenic').Package
Assert-Equal 'same version nfnic kept' 'Keep' (Get-Row $plan 'nfnic').Action
Assert-Equal 'older vendor lsi-mr3 never applied' 'Older' (Get-Row $plan 'lsi-mr3').Action
Assert-Equal 'new vendor VIB added' 'Add' (Get-Row $plan 'NetAppNasPlugin').Action
Assert-Equal '-RemoveVib present in base is removed' 'Remove' (Get-Row $plan 'nmlx4-en').Action
Assert-Equal '-RemoveVib not in base is reported absent' 'Absent' (Get-Row $plan 'not-there').Action
Assert-Equal 'untouched base VIB is not in the plan' $null (Get-Row $plan 'esx-base')

$replaceOnly = Get-VibSwapPlan -BaseVib $base -VendorVib $vendor -ReplaceOnly
Assert-Equal '-ReplaceOnly skips VIBs not in base' 'Skip' (Get-Row $replaceOnly 'NetAppNasPlugin').Action
Assert-Equal '-ReplaceOnly still replaces' 'Replace' (Get-Row $replaceOnly 'nenic').Action

Assert-Throws '-RemoveVib naming a VIB that is being applied is refused' {
    Get-VibSwapPlan -BaseVib $base -VendorVib $vendor -RemoveVib 'nenic' | Out-Null
}
Assert-Equal 'empty vendor list gives an empty plan' 0 (Get-VibSwapPlan -BaseVib $base -VendorVib @()).Count

Write-Host "`n=== Test-ProfileMatchesPlan ===" -ForegroundColor Cyan
$good = [pscustomobject]@{ VibList = @(
        [pscustomobject]@{ Name = 'esx-base'; Version = '8.0.3-0.55.24677879' }
        [pscustomobject]@{ Name = 'nenic'; Version = '2.0.15.0-1OEM.800.1.0.20613240' }
        [pscustomobject]@{ Name = 'nfnic'; Version = '5.0.0.43-1vmw.800.1.0.20513097' }
        [pscustomobject]@{ Name = 'lsi-mr3'; Version = '7.727.02.00-1vmw.800.1.0.20513097' }
        [pscustomobject]@{ Name = 'NetAppNasPlugin'; Version = '2.0.1-16' }
    ) }
Assert-Equal 'profile built to plan has no discrepancies' 0 (Test-ProfileMatchesPlan -ImageProfile $good -Plan $plan).Count

$stale = [pscustomobject]@{ VibList = @(
        [pscustomobject]@{ Name = 'nenic'; Version = '1.0.45.0-1vmw.800.1.0.20513097' }
        [pscustomobject]@{ Name = 'nfnic'; Version = '5.0.0.43-1vmw.800.1.0.20513097' }
        [pscustomobject]@{ Name = 'lsi-mr3'; Version = '7.727.02.00-1vmw.800.1.0.20513097' }
        [pscustomobject]@{ Name = 'nmlx4-en'; Version = '3.19.70.1-1vmw.800.1.0.20513097' }
    ) }
$problems = Test-ProfileMatchesPlan -ImageProfile $stale -Plan $plan
Assert-Equal 'old nenic left in place is caught' $true (@($problems | Where-Object { $_ -like 'nenic:*found 1.0.45.0*' }).Count -eq 1)
Assert-Equal 'missing added VIB is caught' $true (@($problems | Where-Object { $_ -like 'NetAppNasPlugin:*not present' }).Count -eq 1)
Assert-Equal 'VIB that should be removed is caught' $true (@($problems | Where-Object { $_ -like 'nmlx4-en:*expected removed*' }).Count -eq 1)

Write-Host "`n=== Acceptance level ===" -ForegroundColor Cyan
Assert-Equal 'VMwareAccepted ranks 3' 3 (Get-AcceptanceRank 'VMwareAccepted')
Assert-Equal 'short metadata name ranks the same' 3 (Get-AcceptanceRank 'accepted')
Assert-Equal 'PartnerSupported ranks 2' 2 (Get-AcceptanceRank 'PartnerSupported')
Assert-Equal 'CommunitySupported ranks 1' 1 (Get-AcceptanceRank 'CommunitySupported')
Assert-Equal 'certified outranks accepted' 4 (Get-AcceptanceRank 'VMwareCertified')
Assert-Equal 'unknown ranks 0' 0 (Get-AcceptanceRank '')

$accBase = @(
    [pscustomobject]@{ Name = 'esx-base'; Version = '8.0.3-0.55'; AcceptanceLevel = 'VMwareCertified' }
    [pscustomobject]@{ Name = 'nenic'; Version = '1.0.45.0-1vmw'; AcceptanceLevel = 'PartnerSupported' }
)
$accPlan = @(
    [pscustomobject]@{ Action = 'Replace'; Name = 'nenic'; VendorVersion = '2.0.15.0-1OEM'; Acceptance = 'VMwareAccepted' }
    [pscustomobject]@{ Action = 'Add'; Name = 'NetAppNasPlugin'; VendorVersion = '2.0.1-16'; Acceptance = 'PartnerSupported' }
    [pscustomobject]@{ Action = 'Add'; Name = 'mystery'; VendorVersion = '1.0'; Acceptance = '' }
    [pscustomobject]@{ Action = 'Older'; Name = 'lsi-mr3'; VendorVersion = '7.0'; Acceptance = 'CommunitySupported' }
)
$short = Get-AcceptanceShortfall -BaseVib $accBase -Plan $accPlan -Level 'VMwareAccepted'
Assert-Equal 'partner vendor package is below VMwareAccepted' $true (@($short.Below | Where-Object { $_ -like 'NetAppNasPlugin*' }).Count -eq 1)
Assert-Equal 'replaced ESXi package is not checked' 0 @($short.Below | Where-Object { $_ -like 'nenic*ESXi*' }).Count
Assert-Equal 'vendor package that is not applied is not checked' 0 @($short.Below | Where-Object { $_ -like 'lsi-mr3*' }).Count
Assert-Equal 'only one package is below' 1 @($short.Below).Count
Assert-Equal 'unreadable level is reported, not passed' $true (@($short.Unknown | Where-Object { $_ -like 'mystery*' }).Count -eq 1)
$partner = Get-AcceptanceShortfall -BaseVib $accBase -Plan $accPlan -Level 'PartnerSupported'
Assert-Equal 'nothing below PartnerSupported' 0 @($partner.Below).Count

Write-Host "`n=== Read-ProfileName ===" -ForegroundColor Cyan
Assert-Equal 'given name is used and trimmed' 'ESXi-Cisco' (Read-ProfileName -Name '  ESXi-Cisco ' -Default 'ESXi-default')

Write-Host "`n=== Set-PlanExclusion (unticked rows) ===" -ForegroundColor Cyan
$excludedPlan = Set-PlanExclusion -Plan $plan -Name 'nenic', 'NetAppNasPlugin', 'nmlx4-en', 'nfnic'
Assert-Equal 'unticked Replace becomes Excluded' 'Excluded' (Get-Row $excludedPlan 'nenic').Action
Assert-Equal 'unticked Add becomes Excluded' 'Excluded' (Get-Row $excludedPlan 'NetAppNasPlugin').Action
Assert-Equal 'unticked Remove becomes Excluded' 'Excluded' (Get-Row $excludedPlan 'nmlx4-en').Action
Assert-Equal 'Keep row is not changed by unticking' 'Keep' (Get-Row $excludedPlan 'nfnic').Action
Assert-Equal 'the plan passed in is not changed' 'Replace' (Get-Row $plan 'nenic').Action
Assert-Equal 'nothing unticked leaves the plan as it is' 'Replace' (Get-Row (Set-PlanExclusion -Plan $plan -Name @()) 'nenic').Action

$untouched = [pscustomobject]@{ VibList = @(
        [pscustomobject]@{ Name = 'esx-base'; Version = '8.0.3-0.55.24677879' }
        [pscustomobject]@{ Name = 'nenic'; Version = '1.0.45.0-1vmw.800.1.0.20513097' }
        [pscustomobject]@{ Name = 'nfnic'; Version = '5.0.0.43-1vmw.800.1.0.20513097' }
        [pscustomobject]@{ Name = 'lsi-mr3'; Version = '7.727.02.00-1vmw.800.1.0.20513097' }
        [pscustomobject]@{ Name = 'nmlx4-en'; Version = '3.19.70.1-1vmw.800.1.0.20513097' }
    ) }
Assert-Equal 'image left as ESXi had it matches an all-unticked plan' 0 (Test-ProfileMatchesPlan -ImageProfile $untouched -Plan $excludedPlan).Count
$swappedAnyway = Test-ProfileMatchesPlan -ImageProfile $good -Plan $excludedPlan
Assert-Equal 'unticked package swapped anyway is caught' $true (@($swappedAnyway | Where-Object { $_ -like 'nenic: unticked*' }).Count -eq 1)
Assert-Equal 'unticked package added anyway is caught' $true (@($swappedAnyway | Where-Object { $_ -like 'NetAppNasPlugin: unticked*' }).Count -eq 1)

Write-Host "`n=== Compare-VibSet ===" -ForegroundColor Cyan
$expected = @('nenic|2.0.15.0-1OEM', 'esx-base|8.0.3-0.55')
$same = [pscustomobject]@{ VibList = @(
        [pscustomobject]@{ Name = 'esx-base'; Version = '8.0.3-0.55' }
        [pscustomobject]@{ Name = 'nenic'; Version = '2.0.15.0-1OEM' }
    ) }
Assert-Equal 'identical VIB lists match, order ignored' 0 (Compare-VibSet -Expected $expected -ImageProfile $same).Count
$drift = [pscustomobject]@{ VibList = @(
        [pscustomobject]@{ Name = 'esx-base'; Version = '8.0.3-0.55' }
        [pscustomobject]@{ Name = 'nenic'; Version = '1.0.45.0-1vmw' }
    ) }
$diff = Compare-VibSet -Expected $expected -ImageProfile $drift
Assert-Equal 'removed VIB back in the bundle is reported' $true (@($diff | Where-Object { $_ -eq 'unexpected nenic 1.0.45.0-1vmw' }).Count -eq 1)
Assert-Equal 'vendor VIB missing from the bundle is reported' $true (@($diff | Where-Object { $_ -eq 'missing nenic 2.0.15.0-1OEM' }).Count -eq 1)

Write-Host "`n=== Get-DefaultProfileName ===" -ForegroundColor Cyan
$date = [datetime]'2026-11-25'
Assert-Equal 'standard suffix replaced' 'ESXi-8.0U3e-24677879-custom-20261125' (Get-DefaultProfileName -BaseName 'ESXi-8.0U3e-24677879-standard' -Date $date)
Assert-Equal 'no-tools suffix replaced' 'ESXi-8.0U3e-24677879-custom-20261125' (Get-DefaultProfileName -BaseName 'ESXi-8.0U3e-24677879-no-tools' -Date $date)
Assert-Equal 'other names get the suffix appended' 'MyProfile-custom-20261125' (Get-DefaultProfileName -BaseName 'MyProfile' -Date $date)

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
