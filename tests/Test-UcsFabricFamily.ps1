<#
.SYNOPSIS
    Tests fabric interconnect family detection and the firmware policy it selects.

.DESCRIPTION
    The firmware policy is no longer chosen by an operator - it is derived from the fabric
    interconnect model reported by the connected UCSM domain. That makes the derivation
    load-bearing: get the family wrong and a 6300 domain is pointed at 6400 firmware.

    Covers the model strings Cisco actually ships, the mapping to a host firmware package, reuse of
    an existing package, creation of a missing one by name alone, and the cases that must stop the
    run rather than guess.

    Creation by name alone is the point of the last group: no blade or rack bundle version may be
    written by this script. The package takes its versions from the global firmware setting its name
    refers to, and a bundle string sent from here would override that setting silently.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsFabricFamily.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-UcsFabricFamily','Resolve-UcsFirmwarePolicyForTarget','Set-UcsFirmwarePolicyGlobal','Remove-UcsHostsAlreadyOnTargetFirmware','ConvertTo-UcsBundleVersionFromPolicyName','Get-UcsFirmwarePolicyRows','Test-UcsFirmwarePolicyExists','Test-DryRun') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$Global:RunMode = 'LIVE'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$ScriptVersion = 'test'
$Global:UcsFirmwarePolicyByTarget = @{}
$Global:AllowUcsFirmwarePolicyCreation = $true
$Global:UcsFirmwarePolicyByFabricFamily = @{
    '6400' = 'global-602d'
    '6300' = 'global-436h'
}

function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:ExcludedFromRunHosts = @{}
$Global:CurrentClusterName = 'TestCluster'
function Add-ManualAttentionHost { param($HostName,$Reason,$Detail,$ClusterName,[switch]$ExcludeFromRun)
    $Global:ManualAttentionHosts.Add([pscustomobject]@{ Host=$HostName; Reason=$Reason; Detail=$Detail; Excluded=[bool]$ExcludeFromRun }) }
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
# Single-key answers, as the real prompts now offer: C to create, X to stop.
$script:Answer = 'C'
function Get-UcsNetworkElement { param($Ucs,$ErrorAction)
    if ($script:Models -eq 'THROW') { throw "connection lost" }
    return @($script:Models | ForEach-Object { [pscustomobject]@{ Dn='sys/switch'; Model=$_ } }) }
function Get-UcsFirmwareComputeHostPack { param($Ucs,$ErrorAction)
    return @($script:Packs | ForEach-Object { [pscustomobject]@{ Name=$_; Dn="org-root/fw-host-pack-$_"; Descr='' } }) }
# Bundle parameters are still declared, so that passing one is recorded rather than silently
# swallowed by parameter binding - the assertions below require that they arrive empty.
function Add-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$BladeBundleVersion,$RackBundleVersion,$Descr,$ErrorAction)
    $script:Created += [pscustomobject]@{ Org=$Org; Name=$Name; Blade=$BladeBundleVersion; Rack=$RackBundleVersion; Descr=$Descr }
    $script:Packs += $Name }
function Read-ChoiceExit { param($Message,$AllowedChoices,$ExitMessage) $script:LastPrompt = $Message; return $script:Answer }

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

Write-Host "`n=== A missing package is created by name only ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6332'); $script:Packs = @(); $script:Created = @()
$Global:UcsFirmwarePolicyByTarget = @{}
Assert-Equal "6300 domain resolves to global-436h" "global-436h" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-b' -UcsSession 'x' 6>$null)
Assert-Equal "exactly one package was created" 1 $script:Created.Count
Assert-Equal "created at org-root so any org can reference it" "org-root" $script:Created[0].Org
Assert-Equal "created with the mapped name" "global-436h" $script:Created[0].Name
Assert-Equal "no blade bundle version was written - it comes from the global setting" $true ([string]::IsNullOrEmpty($script:Created[0].Blade))
Assert-Equal "no rack bundle version was written - it comes from the global setting" $true ([string]::IsNullOrEmpty($script:Created[0].Rack))
Assert-Equal "the package is attributed to this script" $true ($script:Created[0].Descr -match 'firmware batch controller')

Write-Host "`n=== The resolution is cached per domain ===" -ForegroundColor Cyan
$script:Created = @()
Assert-Equal "a second call reuses the resolved policy" "global-436h" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-b' -UcsSession 'x' 6>$null)
Assert-Equal "and creates nothing further" 0 $script:Created.Count

Write-Host "`n=== Declining creation stops the run ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6332'); $script:Packs = @(); $script:Created = @(); $script:Answer = 'X'
$Global:UcsFirmwarePolicyByTarget = @{}
$stopped = $false
try { [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-c' -UcsSession 'x' 6>$null) } catch { $stopped = "$_" -match 'creation was declined' }
Assert-Equal "STOP prevents creation and stops" $true $stopped
Assert-Equal "nothing was created after declining" 0 $script:Created.Count
$script:Answer = 'C'

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

Write-Host "`n=== The target version is read back out of the policy name ===" -ForegroundColor Cyan
# The end-state comparison needs a version to compare against, and the package names already encode
# one. Reading it back from the name keeps the script free of a version table while still being able
# to say whether a server actually landed on the right firmware.
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'ConvertTo-UcsBundleVersionFromPolicyName' } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

Assert-Equal "global-602d means 6.0(2d)" "6.0(2d)" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName 'global-602d')
Assert-Equal "global-436h means 4.3(6h)" "4.3(6h)" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName 'global-436h')
Assert-Equal "casing does not matter" "6.0(2d)" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName 'GLOBAL-602D')
# A name nobody can decode must produce no comparison at all, rather than a comparison against a
# version nobody chose.
Assert-Equal "a name off the convention yields nothing" "" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName 'site-standard-fw')
Assert-Equal "an empty name yields nothing" "" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName '')

Write-Host "`n=== The script contains no hard-coded bundle versions ===" -ForegroundColor Cyan
# A stub can only prove what was passed on the paths the test walks. This proves it for the whole
# file: the moment someone reintroduces -BladeBundleVersion, the policy stops following the global
# setting, and no runtime assertion would necessarily walk that line.
$scriptText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "no -BladeBundleVersion anywhere in the script" $true (-not ($scriptText -match '-BladeBundleVersion'))
Assert-Equal "no -RackBundleVersion anywhere in the script"  $true (-not ($scriptText -match '-RackBundleVersion'))

Write-Host "`n=== A created policy is handed to UCS Central, not left local ===" -ForegroundColor Cyan
# The live miss: UCSM created the package and left Owner "local". The package is created by NAME
# ONLY, with no bundle versions - they are meant to come from the global policy - so a local
# package applies cleanly and upgrades nothing while the run reports success.
#
# Per Cisco's ucsmsdk metadata, firmwareComputeHostPack.policyOwner is READ_WRITE with exactly
# three values: "local", "pending-policy", "policy".
$script:OwnerState = 'local'
$script:OwnerWrites = New-Object System.Collections.Generic.List[string]
function Get-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$ErrorAction)
    return [pscustomobject]@{ Name = $Name; PolicyOwner = $script:OwnerState } }
# No [Parameter()] attributes: they make this an advanced function, which adds the common
# parameters and then collides with the explicit $ErrorAction the script passes. Pipeline input is
# taken through $input instead, which a simple function supports.
function Set-UcsFirmwareComputeHostPack { param($PolicyOwner,[switch]$Force,$ErrorAction)
    $null = @($input)
    $script:OwnerWrites.Add("$PolicyOwner|Force=$Force")
    if ($script:AcceptOwnerWrite) { $script:OwnerState = $PolicyOwner } }

$script:AcceptOwnerWrite = $true
$script:OwnerState = 'local'; $script:OwnerWrites.Clear()
Set-UcsFirmwarePolicyGlobal -PolicyName 'global-436h' -UcsTarget 'ucsm-a' -UcsSession 'x' 6>$null
Assert-Equal "policyOwner is written once" 1 $script:OwnerWrites.Count
Assert-Equal "to 'policy' - controlled by UCS Central - with -Force" "policy|Force=True" $script:OwnerWrites[0]
Assert-Equal "and the owner is read back as global" "policy" $script:OwnerState

# Pending Global is the normal intermediate state, not a failure: the handover was made and the
# domain is waiting on UCS Central to take it.
$script:AcceptOwnerWrite = $false
$script:OwnerState = 'pending-policy'; $script:OwnerWrites.Clear(); $script:Answer = 'X'
$stoppedPending = $false
try { Set-UcsFirmwarePolicyGlobal -PolicyName 'global-436h' -UcsTarget 'ucsm-a' -UcsSession 'x' 6>$null } catch { $stoppedPending = $true }
Assert-Equal "'pending-policy' is accepted, not treated as a failure" $false $stoppedPending

# Still local afterwards means an empty package is about to be attached - that is put to the
# operator rather than carried on through.
$script:OwnerState = 'local'; $script:OwnerWrites.Clear(); $script:Answer = 'X'
$stoppedLocal = $false
try { Set-UcsFirmwarePolicyGlobal -PolicyName 'global-436h' -UcsTarget 'ucsm-a' -UcsSession 'x' 6>$null }
catch { $stoppedLocal = "$_" -match 'not Global' }
Assert-Equal "a policy still local stops the run when the operator says so" $true $stoppedLocal
Assert-Equal "and the operator is told it would upgrade nothing" $true ($script:LastPrompt -match 'upgrade nothing')

# C continues, deliberately, with the host flagged for manual rectification.
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$script:OwnerState = 'local'; $script:Answer = 'C'
$continued = $true
try { Set-UcsFirmwarePolicyGlobal -PolicyName 'global-436h' -UcsTarget 'ucsm-a' -UcsSession 'x' 6>$null } catch { $continued = $false }
Assert-Equal "C carries on rather than ending the run" $true $continued
Assert-Equal "and it is recorded for manual rectification" $true (@($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Reason -eq 'Host firmware package is not Global' }).Count -ge 1)

# DRY RUN changes no ownership.
$Global:RunMode = 'DRYRUN'
$script:OwnerWrites.Clear()
Set-UcsFirmwarePolicyGlobal -PolicyName 'global-436h' -UcsTarget 'ucsm-a' -UcsSession 'x' 6>$null
Assert-Equal "DRY RUN writes no policyOwner" 0 $script:OwnerWrites.Count
$Global:RunMode = 'LIVE'

# It runs as part of creating the policy, not as a separate thing to remember.
$policyText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "creation hands the policy straight to UCS Central" $true ($policyText -match 'Set-UcsFirmwarePolicyGlobal -PolicyName \$policyName')
Assert-Equal "and the only owner value written is 'policy'" $true ($policyText -match '-PolicyOwner "policy"')

Write-Host "`n=== A policy already on target is compliant, and nothing else is consulted ===" -ForegroundColor Cyan
# Straight from a live run: eleven hosts showed CurrentPolicy global-436h against TargetPolicy
# global-436h and were batched anyway - evacuated, put into Maintenance mode, given a policy they
# already had, and returned to service. A maintenance window each, for nothing.
#
# CurrentPolicy equal to TargetPolicy is the whole test. The policy carries the version, so a
# profile already on it is compliant.
$Global:IntersightHostMap = @{}
$Global:UcsHostMap = @{}
$script:SpPolicy = @{}
$script:SpAcks = @{}
$script:RunningReads = 0
function Get-UcsSessionForTarget { param($UcsTarget) return 'session' }
function Resolve-UcsServiceProfileForHost { param($HostName,$UcsTarget) return [pscustomobject]@{ Name = $HostName } }
function Get-UcsServiceProfileFirmwarePolicyName { param($ServiceProfile) return $script:SpPolicy[$ServiceProfile.Name] }
function Get-UcsRunningFirmwareVersion { param($UcsSession,$ServiceProfile) $script:RunningReads++; return '5.4(0.260050)' }
function Get-UcsLsmaintAck { param($Ucs,$ErrorAction)
    return @($script:SpAcks.Keys | ForEach-Object { [pscustomobject]@{ Dn = "org-root/ls-$_/ack" } }) }
function New-UcsCandidate { param([string]$Name) [pscustomobject]@{ Name = $Name } }
function Register-UcsHost { param([string]$Name,[string]$Current,[string]$Target)
    $Global:UcsHostMap[$Name] = [pscustomobject]@{ UcsTarget='ucsm-a'; ServiceProfileDn="org-root/ls-$Name"; TargetPolicy=$Target }
    $script:SpPolicy[$Name] = $Current }

Register-UcsHost -Name 'esx21' -Current 'global-436h' -Target 'global-436h'
Register-UcsHost -Name 'esx32' -Current 'global-435c' -Target 'global-436h'
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:RunningReads = 0
$kept = @(Remove-UcsHostsAlreadyOnTargetFirmware -CandidateHosts @((New-UcsCandidate 'esx21'), (New-UcsCandidate 'esx32')) 6>$null)
Assert-Equal "the host already on target is excluded" $true ($kept.Name -notcontains 'esx21')
Assert-Equal "and the one that needs the change is kept" $true ($kept.Name -contains 'esx32')
Assert-Equal "it is recorded as Compliant" "Compliant" (@($Global:RunSummary | Where-Object { $_.Host -eq 'esx21' })[0].Result)

# THE FIX. A live domain reported running 5.4(0.260050) against a policy-derived 4.3(6h) - different
# numbering schemes entirely - so the old version comparison could never match and warned on every
# compliant host. The version is no longer read here at all, and nothing is flagged.
Assert-Equal "the running version is not consulted" 0 $script:RunningReads
Assert-Equal "and no host is flagged for manual rectification" 0 $Global:ManualAttentionHosts.Count

# A pending acknowledgement does not change the answer either - the policy decides, quietly.
$script:SpAcks = @{ 'esx21' = $true }
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$kept = @(Remove-UcsHostsAlreadyOnTargetFirmware -CandidateHosts @((New-UcsCandidate 'esx21')) 6>$null)
Assert-Equal "a pending acknowledgement does not re-batch a compliant host" 0 $kept.Count
Assert-Equal "and it raises no note" 0 $Global:ManualAttentionHosts.Count
$script:SpAcks = @{}

# An Intersight-routed host is not this filter's business.
$Global:IntersightHostMap = @{ 'esx50' = $true }
$Global:UcsHostMap = @{}; $script:SpPolicy = @{}
$kept = @(Remove-UcsHostsAlreadyOnTargetFirmware -CandidateHosts @((New-UcsCandidate 'esx50')) 6>$null)
Assert-Equal "an Intersight-routed host is left alone by the UCS filter" $true ($kept.Name -contains 'esx50')
$Global:IntersightHostMap = @{}

# The progress read must not gate on the version either, or every UCS host reports "activating"
# forever on a domain whose running version does not resemble the policy name.
$progressText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'Get-UcsUpgradeProgress' } | ForEach-Object { $_.Extent.Text }) -join "`n"
Assert-Equal "progress is decided by the acknowledgement, not the version" $true ($progressText -match 'no pending acknowledgement')
Assert-Equal "and the version is not compared to the policy name there" $true (-not ($progressText -match 'ConvertTo-UcsBundleVersionFromPolicyName'))

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
