<#
.SYNOPSIS
    Tests fabric interconnect family detection and the firmware policy it selects.

.DESCRIPTION
    The firmware policy is no longer chosen by an operator - it is derived from the fabric
    interconnect model reported by the connected UCSM domain. That makes the derivation
    load-bearing: get the family wrong and a 6300 domain is pointed at 6400 firmware.

    Covers the model strings Cisco actually ships, the mapping to a host firmware package, reuse of
    an existing package, creation of a missing one with the right bundle versions, and the cases
    that must stop the run rather than guess.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsFabricFamily.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-UcsFabricFamily','Resolve-UcsFirmwarePolicyForTarget','Get-UcsFirmwarePolicyRows','Test-UcsFirmwarePolicyExists','Test-DryRun') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$Global:RunMode = 'LIVE'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$ScriptVersion = 'test'
$Global:UcsFirmwarePolicyByTarget = @{}
$Global:AllowUcsFirmwarePolicyCreation = $true
$Global:UcsFirmwarePolicyByFabricFamily = @{
    '6400' = @{ PolicyName = 'global-602d'; BladeBundleVersion = '6.0(2d)B'; RackBundleVersion = '6.0(2d)C' }
    '6300' = @{ PolicyName = 'global-436h'; BladeBundleVersion = '4.3(6h)B'; RackBundleVersion = '4.3(6h)C' }
}

function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
function Stop-SafeExit { param($Message) throw "EXIT: $Message" }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# --- Stubs -----------------------------------------------------------------------------------
$script:Models = @('UCS-FI-6454','UCS-FI-6454')
$script:Packs = @()
$script:Created = @()
$script:Answer = 'CREATE'
function Get-UcsNetworkElement { param($Ucs,$ErrorAction)
    if ($script:Models -eq 'THROW') { throw "connection lost" }
    return @($script:Models | ForEach-Object { [pscustomobject]@{ Dn='sys/switch'; Model=$_ } }) }
function Get-UcsFirmwareComputeHostPack { param($Ucs,$ErrorAction)
    return @($script:Packs | ForEach-Object { [pscustomobject]@{ Name=$_; Dn="org-root/fw-host-pack-$_"; Descr='' } }) }
function Get-UcsFirmwareDistributable { param($Ucs,$ErrorAction) return @([pscustomobject]@{ Version='6.0(2d)' }) }
function Add-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$BladeBundleVersion,$RackBundleVersion,$Descr,$ErrorAction)
    $script:Created += [pscustomobject]@{ Org=$Org; Name=$Name; Blade=$BladeBundleVersion; Rack=$RackBundleVersion }
    $script:Packs += $Name }
function Read-ChoiceExit { param($Message,$AllowedChoices,$ExitMessage) return $script:Answer }

Write-Host "`n=== Model strings map to the right family ===" -ForegroundColor Cyan
foreach ($case in @(
    @{ Models=@('UCS-FI-6454','UCS-FI-6454');   Expect='6400'; Label='6454 (6400 series)' },
    @{ Models=@('UCS-FI-64108','UCS-FI-64108'); Expect='6400'; Label='64108 (6400 series, five digits)' },
    @{ Models=@('UCS-FI-6332','UCS-FI-6332');   Expect='6300'; Label='6332 (6300 series)' },
    @{ Models=@('UCS-FI-6332-16UP');            Expect='6300'; Label='6332-16UP (6300 series, suffixed)' },
    @{ Models=@('UCS-FI-6248UP','UCS-FI-6248UP'); Expect='6200'; Label='6248UP (6200 series)' },
    @{ Models=@('UCS-FI-6536','UCS-FI-6536');   Expect='6500'; Label='6536 (6500 series)' }
)) {
    $script:Models = $case.Models
    Assert-Equal $case.Label $case.Expect (Get-UcsFabricFamily -UcsSession 'x').Family
}

Write-Host "`n=== Ambiguous or unreadable fabrics are never guessed ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6332','UCS-FI-6454')
Assert-Equal "mismatched fabric interconnects report Mixed" "Mixed" (Get-UcsFabricFamily -UcsSession 'x').Family
$script:Models = @('SOMETHING-ELSE')
Assert-Equal "an unrecognised model reports Unknown" "Unknown" (Get-UcsFabricFamily -UcsSession 'x').Family
$script:Models = @()
Assert-Equal "no fabric interconnects reports Unknown" "Unknown" (Get-UcsFabricFamily -UcsSession 'x').Family
$script:Models = 'THROW'
Assert-Equal "a failed query reports Unknown rather than throwing" "Unknown" (Get-UcsFabricFamily -UcsSession 'x').Family

Write-Host "`n=== An existing package is reused, never recreated ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6454'); $script:Packs = @('global-602d'); $script:Created = @()
$Global:UcsFirmwarePolicyByTarget = @{}
Assert-Equal "6400 domain resolves to global-602d" "global-602d" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-a' -UcsSession 'x' 6>$null)
Assert-Equal "nothing was created" 0 $script:Created.Count

Write-Host "`n=== A missing package is created with the mapped bundles ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6332'); $script:Packs = @(); $script:Created = @()
$Global:UcsFirmwarePolicyByTarget = @{}
Assert-Equal "6300 domain resolves to global-436h" "global-436h" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-b' -UcsSession 'x' 6>$null)
Assert-Equal "exactly one package was created" 1 $script:Created.Count
Assert-Equal "created at org-root so any org can reference it" "org-root" $script:Created[0].Org
Assert-Equal "created with the mapped name" "global-436h" $script:Created[0].Name
Assert-Equal "created with the mapped blade bundle" "4.3(6h)B" $script:Created[0].Blade
Assert-Equal "created with the mapped rack bundle" "4.3(6h)C" $script:Created[0].Rack

Write-Host "`n=== The resolution is cached per domain ===" -ForegroundColor Cyan
$script:Created = @()
Assert-Equal "a second call reuses the resolved policy" "global-436h" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-b' -UcsSession 'x' 6>$null)
Assert-Equal "and creates nothing further" 0 $script:Created.Count

Write-Host "`n=== Declining creation stops the run ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6332'); $script:Packs = @(); $script:Created = @(); $script:Answer = 'STOP'
$Global:UcsFirmwarePolicyByTarget = @{}
$stopped = $false
try { [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-c' -UcsSession 'x' 6>$null) } catch { $stopped = "$_" -match 'creation was declined' }
Assert-Equal "STOP prevents creation and stops" $true $stopped
Assert-Equal "nothing was created after declining" 0 $script:Created.Count
$script:Answer = 'CREATE'

Write-Host "`n=== An unmapped family stops rather than picking something ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6248UP'); $script:Packs = @(); $Global:UcsFirmwarePolicyByTarget = @{}
$stopped = $false
try { [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-d' -UcsSession 'x' 6>$null) } catch { $stopped = "$_" -match 'No firmware policy is mapped' }
Assert-Equal "an unmapped 6200 domain stops the run" $true $stopped

Write-Host "`n=== DRY RUN never creates anything ===" -ForegroundColor Cyan
$Global:RunMode = 'DRYRUN'
$script:Models = @('UCS-FI-6332'); $script:Packs = @(); $script:Created = @(); $Global:UcsFirmwarePolicyByTarget = @{}
Assert-Equal "DRY RUN still reports the policy it would use" "global-436h" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-e' -UcsSession 'x' 6>$null)
Assert-Equal "DRY RUN created nothing" 0 $script:Created.Count
$Global:RunMode = 'LIVE'

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
