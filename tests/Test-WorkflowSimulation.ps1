<#
.SYNOPSIS
    Runs the whole cluster workflow end to end against a simulated environment.

.DESCRIPTION
    Every failure in this script so far has been found by an operator, in a change window, on live
    kit. This runs the real control flow - detection, mapping, batching, deploy, compliance,
    cluster health, the batch loop - against stubbed vCenter, UCS Manager and Intersight cmdlets,
    so control-flow faults, bad parameters, null references and broken assumptions surface here
    instead.

    What it does prove: the workflow completes, routes hosts to the right platform, batches every
    host exactly once, and records what it did.

    What it cannot prove: that the vendor cmdlets behave as stubbed. Timeouts, appliance schemas
    and real evacuation behaviour still need a live dry run. A stub returns instantly and always
    succeeds, so nothing here says anything about how long a real operation takes.

    Standalone - no Pester, no vendor modules, no infrastructure. Nothing leaves this process.

.EXAMPLE
    pwsh -File ./tests/Test-WorkflowSimulation.ps1
#>

$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'

$script:pass = 0; $script:fail = 0
function Assert-True {
    param([string]$Name,[bool]$Condition,[string]$Detail = "")
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name$(if($Detail){" - $Detail"})" -ForegroundColor Red }
}

# ---------------------------------------------------------------------------
# Load the script's functions WITHOUT running its top-level code - that would
# apply the real Intersight configuration and start the interactive main loop.
# ---------------------------------------------------------------------------
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors in $scriptPath" }
$functionCount = 0
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    Invoke-Expression $f.Extent.Text
    $functionCount++
}

# ---------------------------------------------------------------------------
# Settings the functions expect, mirroring the script's User Settings block.
# ---------------------------------------------------------------------------
$ScriptVersion                          = 'simulation'
$TargetEsxiVersion                      = 'ESXi-8.0U3j-25429389'
$TargetEsxiBuild                        = '25429389'
$TargetUcsFirmwarePolicyName            = ''
$ResourceSafetyBuffer                   = 0.85
$MinimumCpuHeadroomPercentAfterBatch    = 10
$MinimumMemoryHeadroomPercentAfterBatch = 10
$MinimumDatastoreFreePercent            = 10
$MaxAbsoluteBatchSize                   = 6
$MaintenanceValidationTimeoutMinutes    = 60
$EsxiOnlyReconnectInitialWaitMinutes    = 1
$FirmwareReconnectInitialWaitMinutes    = 1
$PowerCliWebOperationTimeoutSeconds     = 3600
# 0.01 minutes rather than 0: the settle wait must actually run so its summary row is produced and
# the batch loop is proven to go through it, but Start-Sleep is stubbed here, so the real two
# minutes would be two minutes of busy-waiting per batch.
$HostProfileComplianceSettleMinutes     = 0.01
$HostProfileComplianceScanTimeoutMinutes = 1
$ExitMaintenanceTimeoutMinutes          = 1
$RunDirectory                           = [IO.Path]::GetTempPath()
$SummaryPath                            = Join-Path $RunDirectory "simulation-summary.csv"

$Global:RunSummary                      = New-Object System.Collections.Generic.List[object]
$Global:RunMode                         = 'DRYRUN'
$Global:UpgradeMode                     = 'ESXI_UCS_FIRMWARE'
$Global:UcsCredential                   = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
$Global:UcsSessions                     = @{}
$Global:UcsHostMap                      = @{}
$Global:UcsCandidateCache               = @{}
$Global:UcsServiceProfileCache          = @{}
$Global:AutoExitMaintenanceMode         = $true
$Global:PreExistingMaintenanceHosts     = @()
$Global:PrerequisitesConfirmed          = $true
$Global:BatchActionsSent                = 0
$Global:IntersightBaseUrl               = 'https://pva.example.com'
$Global:IntersightSession               = $null
$Global:IntersightReadyChecked          = $false
$Global:IntersightUnusable              = $false
$Global:IntersightUnusableReason        = ''
$Global:IntersightSkippedHosts          = @{}
$Global:IntersightServerList            = @{}
$Global:IntersightHostMap               = @{}
$Global:IntersightProfileCache          = @{}
$Global:IntersightUpgradeSurfaceChecked = $false
$Global:IntersightDeployActionParams    = @()
$Global:IntersightActionableConfigStates = @('Pending-changes','Inconsistent','Out-of-sync','Not-deployed')
$Global:IntersightRebootImmediatelyToActivate = $true
$Global:IntersightRebootActionParamName       = 'RebootImmediatelyToActivate'
$Global:IntersightRebootActionParamValue      = 'true'
$Global:IntersightDeployAcceptedTimeoutSeconds = 5
$Global:EsxiDiscoveryCache              = @{}
$Global:UcsFirmwarePolicyByTarget       = @{}
$Global:AllowUcsFirmwarePolicyCreation  = $true
$Global:UcsFirmwarePolicyByFabricFamily = @{
    '6400' = 'global-602d'
    '6300' = 'global-436h'
}

# Intersight CSV: esx01 is behind fabric SS101 and esx02 behind SS102; esx03/esx04 do not appear at
# all. One row per host, because a shared row would give both hosts the same server profile - and a
# deploy for the first would then look like "nothing staged" for the second.
$csvDir = Join-Path ([IO.Path]::GetTempPath()) ("wfsim-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $csvDir | Out-Null
$IntersightCsvPath = Join-Path $csvDir 'intersightfabric.csv'
"Name`nPD24000001SS101-A.dpe.example`nPD24000001SS102-A.dpe.example" | Set-Content -Path $IntersightCsvPath -Encoding UTF8

# ---------------------------------------------------------------------------
# Simulated estate
# ---------------------------------------------------------------------------
$script:HostState = @{}
foreach ($n in 1..4) {
    $name = "esx0$n.dpe.example"
    $script:HostState[$name] = [pscustomobject]@{
        Name = $name; ConnectionState = 'Connected'; PowerState = 'PoweredOn'
        Build = '20000000'; Id = "HostSystem-host-$n"
        CpuTotalMhz = 100000; CpuUsageMhz = 20000
        MemoryTotalGB = 512;  MemoryUsageGB = 100
    }
}
$script:Cluster = [pscustomobject]@{ Name = 'TestCluster'; ExtensionData = [pscustomobject]@{ TriggeredAlarmState = @() } }
$script:Calls = @{}
function Note-Call { param([string]$Name) if (-not $script:Calls.ContainsKey($Name)) { $script:Calls[$Name] = 0 }; $script:Calls[$Name]++ }

# ---------------------------------------------------------------------------
# Stubs. Vendor cmdlets only - the script's own logic is exercised for real.
# ---------------------------------------------------------------------------
function Start-Sleep { param($Seconds,$Milliseconds) }
function Out-GridView { param([Parameter(ValueFromPipeline=$true)]$InputObject,$Title,[switch]$PassThru) begin{} process{} end{ return $null } }
function Get-Credential { param($Message) return $Global:UcsCredential }

function Connect-VIServer { param($Server,$ErrorAction) Note-Call 'Connect-VIServer'; return [pscustomobject]@{ Name = $Server } }
function Disconnect-VIServer { param($Server,$Confirm) Note-Call 'Disconnect-VIServer' }
function Set-PowerCLIConfiguration { param($Scope,$WebOperationTimeoutSeconds,$Confirm,$ErrorAction) Note-Call 'Set-PowerCLIConfiguration' }
function Get-Cluster { param($Name,$ErrorAction) return $script:Cluster }
function Get-VMHost {
    param($Name,$Location,$ErrorAction)
    if ($Name) { return $script:HostState[$Name] }
    return @($script:HostState.Values | Sort-Object Name)
}
function Set-VMHost {
    param($VMHost,$State,[switch]$Evacuate,[switch]$RunAsync,$Confirm,$ErrorAction)
    Note-Call 'Set-VMHost'
    if ($Evacuate -and -not $RunAsync) { throw "Blocking evacuate would exceed WebOperationTimeoutSeconds - must use -RunAsync" }
    $script:HostState[$VMHost.Name].ConnectionState = if ($State -eq 'Maintenance') { 'Maintenance' } else { 'Connected' }
}
function Get-Datastore { param($Location,$ErrorAction) return @([pscustomobject]@{ Name='ds1'; CapacityGB=1000; FreeSpaceGB=500 }) }
function Get-VM { param($ErrorAction) return @() }
function Move-VM { param($VM,$Destination,$Confirm,$ErrorAction) Note-Call 'Move-VM' }
function Restart-VMHost { param($VMHost,$Confirm,$ErrorAction) Note-Call 'Restart-VMHost' }
function Get-VMHostProfile { param($Entity,$ErrorAction) return [pscustomobject]@{ Name = 'HP-Prod' } }
function Get-Task { param($Status,$Id,$ErrorAction) return @() }
# The scan itself must never read the cache. The stored result is only a legitimate second read
# when the scan produced no usable status, which is not the case here - so a -UseCache call in this
# simulation means the script skipped the check.
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    Note-Call 'Test-VMHostProfileCompliance'
    if ($UseCache) { throw "the scan must perform the check, not read vCenter's stored result" }
    return [pscustomobject]@{ ComplianceStatus = 'Compliant'; CheckTime = (Get-Date) }
}

function Connect-Ucs { param($Name,$Credential,$ErrorAction) Note-Call 'Connect-Ucs'; return [pscustomobject]@{ Ucs = $Name } }
function Disconnect-Ucs { param($Ucs,$ErrorAction) }
function Get-UcsPSSession { param($ErrorAction) return @() }
# Service profile firmware policy is stateful, so the script's set-then-verify round trip is
# genuinely exercised. A stub that always returned the old policy would make verification fail
# forever and the RECHECK prompt loop.
$script:UcsPolicyState = @{}
function Get-UcsServiceProfile {
    param($Ucs,$Name,$Dn,$ErrorAction)
    $spName = if ($Name) { $Name } elseif ($Dn) { ($Dn -split '/')[-1] -replace '^ls-','' } else { $null }
    if (-not $spName) { return @() }
    if (-not $script:UcsPolicyState.ContainsKey($spName)) { $script:UcsPolicyState[$spName] = 'fw-old' }
    return [pscustomobject]@{ Name = $spName; Dn = "org-root/ls-$spName"; PnDn = 'sys/chassis-1/blade-1'; HostFwPolicyName = $script:UcsPolicyState[$spName] }
}
function Set-UcsServiceProfile {
    param($Ucs,$ServiceProfile,$HostFwPolicyName,[switch]$Force,$ErrorAction)
    Note-Call 'Set-UcsServiceProfile'
    $script:UcsPolicyState[$ServiceProfile.Name] = $HostFwPolicyName
}
# Fabric family drives the firmware policy, so the simulated domain reports a 6400-series FI and
# the run must land on global-602d without asking anyone.
$script:FabricModel = 'UCS-FI-6454'
$script:HostPacks = @('global-602d')
function Get-UcsNetworkElement { param($Ucs,$ErrorAction)
    return @(
        [pscustomobject]@{ Dn='sys/switch-A'; Model=$script:FabricModel; Vendor='Cisco Systems, Inc.' },
        [pscustomobject]@{ Dn='sys/switch-B'; Model=$script:FabricModel; Vendor='Cisco Systems, Inc.' }
    )
}
function Get-UcsFirmwareComputeHostPack { param($Ucs,$ErrorAction)
    return @($script:HostPacks | ForEach-Object { [pscustomobject]@{ Name=$_; Dn="org-root/fw-host-pack-$_"; Descr='' } })
}
function Add-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$BladeBundleVersion,$RackBundleVersion,$Descr,$ErrorAction)
    Note-Call 'Add-UcsFirmwareComputeHostPack'
    if ($BladeBundleVersion -or $RackBundleVersion) { throw "bundle versions must come from the global setting, not from the script" }
    $script:HostPacks += $Name
}
# UCSM raises a maintenance acknowledgement against a service profile once its firmware policy
# changes, so the stub does too. Returning an empty list unconditionally made every UCS-only batch
# look like it had nothing staged, which is a different code path entirely.
# The version each server reports running. global-602d means 6.0(2d), so a server on that version
# verifies clean and a server left behind is caught by the comparison.
$script:UcsRunningVersion = '6.0(2d)'
function Get-UcsFirmwareRunning { param($Ucs,$ErrorAction)
    return @([pscustomobject]@{ Dn='sys/chassis-1/blade-1/mgmt/fw-system'; Deployment='system'; Type='blade-controller'; Version=$script:UcsRunningVersion }) }
function Get-UcsLsmaintAck { param($Ucs,$ErrorAction)
    return @($script:UcsPolicyState.Keys |
        Where-Object { $script:UcsPolicyState[$_] -ne 'fw-old' -and -not $script:UcsAcked.Contains($_) } |
        ForEach-Object { [pscustomobject]@{ Dn = "org-root/ls-$_/ack"; ServiceProfile = $_ } })
}
$script:UcsAcked = New-Object System.Collections.Generic.HashSet[string]
function Set-UcsLsmaintAck { param($Ucs,$LsmaintAck,$AdminState,[switch]$Force,$ErrorAction)
    Note-Call 'Set-UcsLsmaintAck'
    if ($LsmaintAck -and $LsmaintAck.ServiceProfile) { [void]$script:UcsAcked.Add($LsmaintAck.ServiceProfile) }
}

# Present but never called by the pre-auth build - Assert-IntersightPowerShellAvailable probes for
# it as a module-presence check. If the simulation ever records a call to this, the pre-auth build
# has started configuring Intersight, which it must not.
function Set-IntersightConfiguration { param($BasePath,$ApiKeyId,$ApiKeyFilePath,$HttpSigningHeader,$ErrorAction) Note-Call 'Set-IntersightConfiguration' }
function Get-IntersightConfiguration { return [pscustomobject]@{ BasePath = $Global:IntersightBaseUrl; ApiKeyId = 'a/b/c' } }
# ConfigState is stateful: a profile starts with staged changes and reaches Associated once it has
# been deployed. A stub frozen on Pending-changes would make the closing verification report every
# Intersight host as still outstanding, which is the opposite of what a completed run should show.
$script:IntersightDeployed = New-Object System.Collections.Generic.HashSet[string]
function Get-IntersightServerProfile {
    param($Moid,$Filter,$Top,$Skip,$ErrorAction)
    # Paged shape, as the real cmdlet returns - exercises Get-IntersightResultList.
    # Lookups arrive by filter on the first pass and by Moid once the profile is cached, so both
    # have to resolve back to the same profile. Collapsing a Moid lookup to one generic profile made
    # every host share it, and one host's deploy then looked like every host's.
    $name = 'sp-generic'
    if ($Filter -and $Filter -match "Name eq '([^']+)'") { $name = $Matches[1] }
    elseif ($Moid -and "$Moid" -match '^moid-(.+)$') { $name = $Matches[1] }
    $state = if ($script:IntersightDeployed.Contains("moid-$name")) { 'Associated' } else { 'Pending-changes' }
    return [pscustomobject]@{
        Results = @([pscustomobject]@{
            Name = $name; Moid = "moid-$name"
            ConfigContext = [pscustomobject]@{ ConfigState = $state }
        })
    }
}
$script:DeployActionParams = New-Object System.Collections.Generic.List[string]
function Set-IntersightServerProfile { param($Moid,$Action,$ActionParams,$ErrorAction)
    Note-Call 'Set-IntersightServerProfile'
    foreach ($ap in @($ActionParams)) { if ($ap) { $script:DeployActionParams.Add("$($ap.Name)=$($ap.Value)") } }
    if ($Moid) { [void]$script:IntersightDeployed.Add([string]$Moid) }
}
function Initialize-IntersightPolicyActionParam { param($Name,$Value) return [pscustomobject]@{ Name=$Name; Value=$Value } }

# CDP/LLDP: the one place the script talks to vCenter through Get-View, replaced wholesale so the
# simulation controls which fabric each host reports.
function Get-EsxiDiscoveryProtocolInfo {
    param($VMHostObject)
    $fabric = switch -Regex ($VMHostObject.Name) {
        'esx01' { 'PD24000001SS101-A.dpe.example'; break }
        'esx02' { 'PD24000001SS102-B.dpe.example'; break }   # -B form, so suffix matching is exercised
        default { 'PD24000002SS201-A.dpe.example' }
    }
    return @([pscustomobject]@{ Host=$VMHostObject.Name; Vmnic='vmnic0'; SystemName=$fabric; PortId='1' })
}

# Scripted operator. Answers are matched on the prompt text so the test does not depend on the
# exact order of questions.
$script:PromptLog = New-Object System.Collections.Generic.List[string]
$script:MaxPrompts = 400
function Read-Host {
    param([string]$Prompt)
    $script:PromptLog.Add($Prompt)
    if ($script:PromptLog.Count -gt $script:MaxPrompts) {
        throw "Prompt limit exceeded - the scripted operator cannot answer '$Prompt', so Read-ChoiceExit is looping. Add a matching answer."
    }
    switch -Regex ($Prompt) {
        'Select run mode'            { return '2' }    # DRY RUN
        'Select upgrade mode'        { return '2' }    # ESXi + firmware
        'Select batch mode'          { return '1' }    # AUTO
        'Create host firmware package' { return 'CREATE' }
        'Intersight FQDN'            { return 'pva.example.com' }
        'Nothing to reboot'          { return 'CONTINUE' }
        'O to override'              { return 'C' }
        'No host profile attached'   { return 'SKIP' }
        'Choose SKIP'                { return 'SKIP' }
        'Reconnect incomplete'       { return 'OVERRIDE' }
        default                      { return 'YES' }
    }
}

function Reset-Simulation {
    param([string]$Mode)
    foreach ($h in @($script:HostState.Keys)) { $script:HostState[$h].ConnectionState = 'Connected' }
    $script:Calls = @{}
    $script:PromptLog = New-Object System.Collections.Generic.List[string]
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
    $Global:RunMode = $Mode
    $Global:IntersightServerList = @{}
    $Global:IntersightHostMap = @{}
    $Global:IntersightSession = $null
    $Global:IntersightReadyChecked = $false
    $Global:IntersightUnusable = $false
    $Global:IntersightUpgradeSurfaceChecked = $false
    $Global:UcsSessions = @{}
    $Global:UcsFirmwarePolicyByTarget = @{}
    # The simulated UCSM remembers the policy each service profile was last set to. Left over from a
    # previous run it would make the next one find nothing to stage, and the run would legitimately
    # stop to ask - a stale fixture masquerading as a behaviour change.
    $script:UcsPolicyState = @{}
    $script:UcsAcked = New-Object System.Collections.Generic.HashSet[string]
    $script:IntersightDeployed = New-Object System.Collections.Generic.HashSet[string]
    $script:DeployActionParams = New-Object System.Collections.Generic.List[string]
}

Write-Host "`n=== The script loads ===" -ForegroundColor Cyan
Assert-True "functions extracted from the script" ($functionCount -gt 40) "found $functionCount"

Write-Host "`n=== A full DRY RUN cluster workflow completes ===" -ForegroundColor Cyan
$workflowError = $null
try {
    Invoke-ClusterUpgradeWorkflow -Cluster $script:Cluster 6>$null
}
catch {
    $workflowError = $_
}
Assert-True "the workflow ran to completion without an unhandled error" ($null -eq $workflowError) "$($workflowError)"

Write-Host "`n=== Hosts were routed to the right platform ===" -ForegroundColor Cyan
$detection = @($Global:RunSummary | Where-Object { $_.Stage -eq 'InfrastructureDetection' })
$intersightHosts = @($detection | Where-Object { $_.Result -eq 'Intersight' } | Select-Object -ExpandProperty Host | Sort-Object)
$ucsHosts        = @($detection | Where-Object { $_.Result -eq 'UCSManager' }  | Select-Object -ExpandProperty Host | Sort-Object)
Assert-True "esx01 and esx02 detected as Intersight-managed" (($intersightHosts -join ',') -eq 'esx01.dpe.example,esx02.dpe.example') "got: $($intersightHosts -join ',')"
Assert-True "esx03 and esx04 detected as UCS Manager-managed" (($ucsHosts -join ',') -eq 'esx03.dpe.example,esx04.dpe.example') "got: $($ucsHosts -join ',')"

Write-Host "`n=== Every host was batched exactly once ===" -ForegroundColor Cyan
$batched = @($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' } | Select-Object -ExpandProperty Host | Sort-Object -Unique)
Assert-True "all four hosts reached the compliance stage" ($batched.Count -eq 4) "got $($batched.Count): $($batched -join ', ')"
$complianceRows = @($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' })
Assert-True "no host was processed twice" ($complianceRows.Count -eq 4) "got $($complianceRows.Count) rows"

Write-Host "`n=== The cluster finished ===" -ForegroundColor Cyan
Assert-True "a ClusterComplete record was written" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ClusterComplete' }).Count -eq 1)

Write-Host "`n=== DRY RUN changed nothing ===" -ForegroundColor Cyan
Assert-True "the pre-auth build never configured Intersight" (-not $script:Calls.ContainsKey('Set-IntersightConfiguration'))
foreach ($mutator in @('Set-VMHost','Set-UcsServiceProfile','Set-UcsLsmaintAck','Set-IntersightServerProfile','Restart-VMHost','Move-VM')) {
    Assert-True "$mutator was never called" (-not $script:Calls.ContainsKey($mutator)) "called $($script:Calls[$mutator]) time(s)"
}
Assert-True "every host is still Connected" (@($script:HostState.Values | Where-Object { $_.ConnectionState -ne 'Connected' }).Count -eq 0)

Write-Host "`n=== The fabric family chose the firmware policy ===" -ForegroundColor Cyan
$fabricRows = @($Global:RunSummary | Where-Object { $_.Stage -eq 'UCSMFabricDetection' })
Assert-True "the fabric family was detected" ($fabricRows.Count -ge 1)
Assert-True "a 6454 was read as the 6400 family" (@($fabricRows | Where-Object { $_.Result -eq '6400' }).Count -ge 1) "got: $(($fabricRows.Result) -join ', ')"
$policyRows = @($Global:RunSummary | Where-Object { $_.Stage -eq 'UCSMFirmwarePolicySelection' })
Assert-True "the 6400 mapping resolved to global-602d" (@($policyRows | Where-Object { $_.Details -match 'global-602d' }).Count -ge 1) "got: $(($policyRows.Details) -join ' | ')"
Assert-True "an existing package was reused, not recreated" (@($policyRows | Where-Object { $_.Result -eq 'Existing' }).Count -ge 1)
Assert-True "no host firmware package was created when one already existed" (-not $script:Calls.ContainsKey('Add-UcsFirmwareComputeHostPack'))

Write-Host "`n=== The run summary is usable evidence ===" -ForegroundColor Cyan
Assert-True "summary rows were recorded" ($Global:RunSummary.Count -gt 10) "got $($Global:RunSummary.Count)"
Assert-True "every row carries the script version" (@($Global:RunSummary | Where-Object { $_.ScriptVersion -ne 'simulation' }).Count -eq 0)
Assert-True "no row has a blank stage" (@($Global:RunSummary | Where-Object { [string]::IsNullOrWhiteSpace($_.Stage) }).Count -eq 0)

# ---------------------------------------------------------------------------
# LIVE RUN - the mutating path, which is where the risk actually is.
# ---------------------------------------------------------------------------
# Two waits are human-timing gates rather than logic under test, and with Start-Sleep stubbed they
# would spin for their full duration. Replaced so the batch loop runs at full speed.
function Invoke-RebootSafetyWindow { param($TimeoutSeconds,$HostNames,$BatchNumber) Note-Call 'RebootSafetyWindow'; return $true }
$EsxiOnlyReconnectInitialWaitMinutes = 0
$FirmwareReconnectInitialWaitMinutes = 0

Write-Host "`n=== A full LIVE RUN cluster workflow completes ===" -ForegroundColor Cyan
Reset-Simulation -Mode 'LIVE'
function Read-Host { param([string]$Prompt)
    $script:PromptLog.Add($Prompt)
    if ($script:PromptLog.Count -gt $script:MaxPrompts) {
        throw "Prompt limit exceeded - the scripted operator cannot answer '$Prompt', so Read-ChoiceExit is looping. Add a matching answer."
    }
    switch -Regex ($Prompt) {
        'Select run mode'          { return '1' }    # LIVE
        'Select upgrade mode'      { return '2' }
        'Select batch mode'        { return '1' }
        'Create host firmware package' { return 'CREATE' }
        'Nothing to reboot'        { return 'CONTINUE' }
        'O to override'            { return 'C' }
        'No host profile attached' { return 'SKIP' }
        'Choose SKIP'              { return 'SKIP' }
        'Reconnect incomplete'     { return 'OVERRIDE' }
        default                    { return 'YES' }
    }
}

$liveError = $null
try { Invoke-ClusterUpgradeWorkflow -Cluster $script:Cluster 6>$null } catch { $liveError = $_ }
Assert-True "the LIVE workflow ran to completion" ($null -eq $liveError) "$($liveError)"

Write-Host "`n=== Maintenance mode was requested safely ===" -ForegroundColor Cyan
# The Set-VMHost stub throws on a blocking evacuate, because PowerCLI's 300-second web operation
# timeout is shorter than a real evacuation and tears the request down mid-flight.
Assert-True "Set-VMHost was called" ($script:Calls.ContainsKey('Set-VMHost'))
Assert-True "no blocking evacuate was attempted" ($null -eq $liveError -or "$liveError" -notmatch 'RunAsync')

Write-Host "`n=== The firmware actions actually fired ===" -ForegroundColor Cyan
Assert-True "UCS service profiles were updated" ($script:Calls.ContainsKey('Set-UcsServiceProfile'))
Assert-True "Intersight profiles were deployed" ($script:Calls.ContainsKey('Set-IntersightServerProfile'))
Assert-True "the deploy ran for both Intersight hosts" ($script:Calls['Set-IntersightServerProfile'] -eq 2) "got $($script:Calls['Set-IntersightServerProfile'])"
# Without the reboot acknowledgement the firmware stages and nothing restarts, and the run then
# waits out its whole post-reboot window for a reboot that was never scheduled.
Assert-True "every deploy carried the reboot acknowledgement" (@($script:DeployActionParams | Where-Object { $_ -eq 'RebootImmediatelyToActivate=true' }).Count -eq 2) "sent: $($script:DeployActionParams -join ' | ')"
Assert-True "the deploy was confirmed as accepted, not assumed" (@($Global:RunSummary | Where-Object { $_.Action -eq 'Confirm deploy accepted' -and $_.Result -eq 'Accepted' }).Count -eq 2)
Assert-True "the pre-reboot safety window was honoured" ($script:Calls.ContainsKey('RebootSafetyWindow'))

Write-Host "`n=== Hosts were returned to service ===" -ForegroundColor Cyan
Assert-True "every host ended Connected, not left in Maintenance" (@($script:HostState.Values | Where-Object { $_.ConnectionState -ne 'Connected' }).Count -eq 0) "still in maintenance: $(($script:HostState.Values | Where-Object { $_.ConnectionState -ne 'Connected' } | Select-Object -ExpandProperty Name) -join ', ')"
Assert-True "compliance was checked for all four hosts" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' } | Select-Object -ExpandProperty Host -Unique).Count -eq 4)
Assert-True "maintenance mode was exited for all four hosts" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ExitMaintenance' -and $_.Result -eq 'Sent' }).Count -eq 4)
Assert-True "the cluster completed" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ClusterComplete' }).Count -eq 1)
# Host profile compliance is the only health gate. The cluster-wide checks were removed after
# repeatedly failing a cluster with nothing wrong with it, so nothing may reintroduce one quietly.
Assert-True "no cluster health gate runs" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ClusterHealth' }).Count -eq 0) "found: $(($Global:RunSummary | Where-Object { $_.Stage -eq 'ClusterHealth' } | ForEach-Object { $_.Details }) -join ' | ')"

Write-Host "`n=== Compliance was scanned, not read from cache ===" -ForegroundColor Cyan
# The settle wait sits between the reconnect gate and the first scan of each batch. If it stops
# running, a batch scans a host that is still starting up and reports differences that are not real.
$settleRows = @($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileComplianceSettle' })
$batchesWithCompliance = @($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' } | Select-Object -ExpandProperty Batch -Unique)
Assert-True "the settle wait ran before every batch's compliance scan" ($settleRows.Count -eq $batchesWithCompliance.Count) "settles: $($settleRows.Count), batches: $($batchesWithCompliance.Count)"
Assert-True "every settle ran to completion" (@($settleRows | Where-Object { $_.Result -eq 'Completed' }).Count -eq $settleRows.Count)
# The stub throws on -UseCache, so reaching here at all proves a real scan was requested each time.
Assert-True "a compliance scan was issued for every host" ($script:Calls['Test-VMHostProfileCompliance'] -ge 4) "got $($script:Calls['Test-VMHostProfileCompliance'])"
Assert-True "the settle wait does not add per-host compliance rows" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' }).Count -eq 4)

# ---------------------------------------------------------------------------
# SINGLE mode - one host at a time, and nothing may stop to ask between them.
# ---------------------------------------------------------------------------
Write-Host "`n=== SINGLE mode runs the whole cluster with no prompts between hosts ===" -ForegroundColor Cyan
Reset-Simulation -Mode 'LIVE'

# Only the questions the operator agreed to answer. Anything else is a regression: the run is meant
# to walk the cluster on its own once it has started, and a stray prompt strands it mid-change.
$AgreedPrompts = @(
    'Select run mode'
    'Select upgrade mode'
    'Select batch mode'
    'Create host firmware package'
)
# The manual health check / change gate question is deliberately NOT here. It moved into the
# requirements printed at the start of the run: it asks about a change record the script cannot
# see, so asking again mid-run gates nothing and only interrupts an unattended cluster.
$RemovedPrompts = @('manual health checks', 'change gates')
$script:UnexpectedPrompts = New-Object System.Collections.Generic.List[string]
function Read-Host {
    param([string]$Prompt)
    $script:PromptLog.Add($Prompt)
    if ($script:PromptLog.Count -gt $script:MaxPrompts) { throw "Prompt limit exceeded: '$Prompt'" }
    if (-not (@($AgreedPrompts | Where-Object { $Prompt -match $_ }).Count)) {
        [void]$script:UnexpectedPrompts.Add($Prompt)
    }
    switch -Regex ($Prompt) {
        'Select run mode'              { return '1' }    # LIVE
        'Select upgrade mode'          { return '2' }
        'Select batch mode'            { return '2' }    # SINGLE
        'Create host firmware package' { return 'CREATE' }
        default                        { return 'YES' }
    }
}

$singleError = $null
try { Invoke-ClusterUpgradeWorkflow -Cluster $script:Cluster 6>$null } catch { $singleError = $_ }
Assert-True "the SINGLE-mode workflow ran to completion" ($null -eq $singleError) "$($singleError)"
Assert-True "nothing was asked outside the agreed menu items" ($script:UnexpectedPrompts.Count -eq 0) "asked: $(($script:UnexpectedPrompts | Select-Object -Unique) -join ' | ')"
foreach ($gone in $RemovedPrompts) {
    Assert-True "the '$gone' prompt stayed removed" (-not (@($script:PromptLog | Where-Object { $_ -match $gone }).Count))
}
Assert-True "every host was processed one at a time" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' }).Count -eq 4)
Assert-True "each host was its own batch" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' } | Select-Object -ExpandProperty Batch -Unique).Count -eq 4)
Assert-True "every host ended Connected" (@($script:HostState.Values | Where-Object { $_.ConnectionState -ne 'Connected' }).Count -eq 0)
Assert-True "the cluster completed without intervention" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ClusterComplete' }).Count -eq 1)

Write-Host "`n=== The cluster closes with a verification read from the platforms ===" -ForegroundColor Cyan
# Read back from Intersight, UCS Manager and vCenter after the fact - a completed run has to be able
# to show what the infrastructure now reports, not just that the script hit no errors.
$verification = @($Global:RunSummary | Where-Object { $_.Stage -eq 'PostChangeVerification' })
Assert-True "every host was verified after the change" ($verification.Count -eq 4) "got $($verification.Count)"
Assert-True "nothing was left outstanding" (@($verification | Where-Object { $_.Result -ne 'Clean' }).Count -eq 0) "not clean: $(($verification | Where-Object { $_.Result -ne 'Clean' } | ForEach-Object { "$($_.Host): $($_.Details)" }) -join ' | ')"
Assert-True "Intersight hosts report no staged changes" (@($verification | Where-Object { $_.Details -match 'Intersight' -and $_.Details -match 'outstanding: None' }).Count -eq 2)
Assert-True "UCS hosts report the resolved firmware policy" (@($verification | Where-Object { $_.Details -match 'Policy: global-602d' }).Count -eq 2)
Assert-True "UCS hosts are compared against the version the policy name refers to" (@($verification | Where-Object { $_.Details -match 'running: 6\.0\(2d\); target: 6\.0\(2d\)' }).Count -eq 2) "got: $(($verification | Where-Object { $_.Details -match 'Policy:' } | ForEach-Object { $_.Details }) -join ' | ')"

# ---------------------------------------------------------------------------
# A second pass over a cluster that is already current. Nothing is staged, so
# nothing reboots - and that is a result, not a question.
# ---------------------------------------------------------------------------
Write-Host "`n=== An already-current cluster runs through without stopping to ask ===" -ForegroundColor Cyan
# Intersight reporting RequiresDeploy=false is the state the run is trying to reach. Stopping to ask
# about it strands an unattended cluster on a host that needed nothing doing. The prompt is reserved
# for a state that could not be READ - which is not the same thing and must never be treated as one.
$carriedPolicy    = $script:UcsPolicyState
$carriedAcked     = $script:UcsAcked
$carriedDeployed  = $script:IntersightDeployed
Reset-Simulation -Mode 'LIVE'
$script:UcsPolicyState     = $carriedPolicy
$script:UcsAcked           = $carriedAcked
$script:IntersightDeployed = $carriedDeployed

$script:UnexpectedPrompts = New-Object System.Collections.Generic.List[string]
$secondPassError = $null
try { Invoke-ClusterUpgradeWorkflow -Cluster $script:Cluster 6>$null } catch { $secondPassError = $_ }
Assert-True "the second pass ran to completion" ($null -eq $secondPassError) "$($secondPassError)"
Assert-True "nothing was asked outside the agreed menu items" ($script:UnexpectedPrompts.Count -eq 0) "asked: $(($script:UnexpectedPrompts | Select-Object -Unique) -join ' | ')"
Assert-True "and the cluster still completed" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ClusterComplete' }).Count -eq 1)

# The Intersight profiles are Associated by now, so those hosts are dropped before anything is
# evacuated. Batching them would take a host out of service, find nothing to send, and put it back.
$excluded = @($Global:RunSummary | Where-Object { $_.Stage -eq 'Scope' -and $_.Result -eq 'AlreadyDeployed' })
Assert-True "both already-deployed Intersight hosts were dropped from scope" ($excluded.Count -eq 2) "got $($excluded.Count)"
Assert-True "the reason names the ConfigState" (@($excluded | Where-Object { $_.Details -match 'Associated' }).Count -eq 2)
Assert-True "neither was put into Maintenance mode" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' -and $excluded.Host -contains $_.Host }).Count -eq 0)

Write-Host "`n=== A server left on the old firmware is caught, not passed ===" -ForegroundColor Cyan
# The policy can be right and acknowledged and the server still be on the old image if the
# activation did not take. Only the end-state version comparison shows that.
$script:UcsRunningVersion = '4.3(6h)'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
Show-ClusterFirmwareVerification -Cluster $script:Cluster -HostNames @('esx03.dpe.example') 6>$null
$stale = @($Global:RunSummary | Where-Object { $_.Stage -eq 'PostChangeVerification' })
Assert-True "the mismatch is flagged" ($stale[0].Result -eq 'Attention') "got $($stale[0].Result)"
Assert-True "and names both versions" ($stale[0].Details -match 'VERSION MISMATCH - running 4\.3\(6h\), expected 6\.0\(2d\)') "got: $($stale[0].Details)"
$script:UcsRunningVersion = '6.0(2d)'

Write-Host "`n=== A state that cannot be read still stops to ask ===" -ForegroundColor Cyan
# "Nothing staged" and "could not tell" look identical from the outside - no action gets sent either
# way - and must not be conflated. RequiresDeploy=false is a result and is carried on through;
# a ConfigState the appliance would not report is a question, and the run asks it.
#
# Note this is the narrow case: a reachable appliance that will not report one profile's state. An
# appliance that cannot be driven at all is caught earlier, before any host is batched.
function Get-IntersightServerProfile {
    param($Moid,$Filter,$Top,$Skip,$ErrorAction)
    $name = 'sp-generic'
    if ($Filter -and $Filter -match "Name eq '([^']+)'") { $name = $Matches[1] }
    elseif ($Moid -and "$Moid" -match '^moid-(.+)$') { $name = $Matches[1] }
    # No ConfigContext: the profile is there, its state is not.
    return [pscustomobject]@{ Results = @([pscustomobject]@{ Name = $name; Moid = "moid-$name" }) }
}
$script:AskedAboutState = $false
function Read-Host {
    param([string]$Prompt)
    $script:PromptLog.Add($Prompt)
    if ($script:PromptLog.Count -gt $script:MaxPrompts) { throw "Prompt limit exceeded: '$Prompt'" }
    if ($Prompt -match 'could not be confirmed as current|ConfigState|state could not be read') { $script:AskedAboutState = $true }
    switch -Regex ($Prompt) {
        'Select run mode'              { return '1' }
        'Select upgrade mode'          { return '2' }
        'Select batch mode'            { return '2' }
        'Create host firmware package' { return 'CREATE' }
        'Reconnect incomplete'         { return 'OVERRIDE' }
        'STOP'                         { return 'CONTINUE' }
        default                        { return 'YES' }
    }
}
$carriedPolicy = $script:UcsPolicyState; $carriedAcked = $script:UcsAcked; $carriedDeployed = $script:IntersightDeployed
Reset-Simulation -Mode 'LIVE'
$script:UcsPolicyState = $carriedPolicy; $script:UcsAcked = $carriedAcked; $script:IntersightDeployed = $carriedDeployed
try { Invoke-ClusterUpgradeWorkflow -Cluster $script:Cluster 6>$null } catch {}
Assert-True "an unreadable ConfigState is raised with the operator, not carried on through" $script:AskedAboutState

Remove-Item -Path $csvDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
