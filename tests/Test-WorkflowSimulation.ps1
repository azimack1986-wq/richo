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
$Global:ManualAttentionHosts            = New-Object System.Collections.Generic.List[object]
$Global:ExcludedFromRunHosts            = @{}
$Global:CurrentClusterName              = 'TestCluster'
$Global:IntersightServerList            = @{}
$Global:IntersightHostMap               = @{}
$Global:IntersightProfileCache          = @{}
$Global:IntersightUpgradeSurfaceChecked = $false
$Global:IntersightDeployActionParams    = @()
$Global:IntersightActionableConfigStates = @('Pending-changes','Inconsistent','Out-of-sync','Not-deployed')
$Global:IntersightRebootImmediatelyToActivate = $true
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
# Each host object carries a boot time, and the Intersight activation moves it - which is what the
# reconnect gate now requires before any vCenter work happens. A stub whose boot time never changed
# would let the gate through on a host that never restarted, proving nothing.
foreach ($h in $script:HostState.Values) {
    $h | Add-Member -NotePropertyName ExtensionData -NotePropertyValue ([pscustomobject]@{
        Runtime = [pscustomobject]@{ BootTime = '2026-08-01T00:00:00Z' } }) -Force
}
function Set-VMHost {
    param($VMHost,$State,[switch]$Evacuate,[switch]$RunAsync,$Confirm,$ErrorAction)
    Note-Call 'Set-VMHost'
    # Only ENTERING is long enough to blow PowerCLI's request ceiling; exiting is immediate.
    if ($State -eq 'Maintenance' -and -not $RunAsync) { throw "A blocking Set-VMHost exceeds WebOperationTimeoutSeconds mid-evacuation - must use -RunAsync" }
    # -Evacuate is evacuatePoweredOffVms: it cold-migrates every powered-off and suspended VM off
    # the host first, which DRS then undoes. Nothing in this run should be asking for that.
    if ($Evacuate) { throw "-Evacuate cold-migrates powered-off VMs; the run must not ask for it" }
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
    $script:BootCounter++
    foreach ($h in $script:HostState.Values) { $h.ExtensionData.Runtime.BootTime = "2026-08-12T1$($script:BootCounter):00:00Z" }
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
    # A real profile is associated with a server, and the wrapper shape is the generated oneOf the
    # SDK actually returns - ActualInstance, not a plain object. $script:ProfilesUnassigned strips
    # it, which is the wrong-profile case the pre-flight exists to tell apart.
    $obj = [pscustomobject]@{
        Name = $name; Moid = "moid-$name"
        ConfigContext = [pscustomobject]@{ ConfigState = $state }
    }
    if (-not $script:ProfilesUnassigned) {
        $obj | Add-Member -NotePropertyName AssignedServer -NotePropertyValue ([pscustomobject]@{
            ActualInstance = [pscustomobject]@{ Moid = "server-$name" } }) -Force
    }
    return [pscustomobject]@{ Results = @($obj) }
}
$script:ProfilesUnassigned = $false
$script:DeployActionParams = New-Object System.Collections.Generic.List[string]
function Initialize-IntersightPolicyScheduledAction { param($Action,$ProceedOnReboot)
    return [pscustomobject]@{ Action = $Action; ProceedOnReboot = [bool]$ProceedOnReboot } }
$script:BootCounter = 0
$script:DeployRefusalMoid = ''
$script:DeployRefusalMessage = ''
function Set-IntersightServerProfile { param($Moid,$Action,$ActionParams,$ScheduledActions,$ErrorAction)
    Note-Call 'Set-IntersightServerProfile'
    # The appliance refusing one profile. Thrown before anything else happens, as it is server-side.
    if ($script:DeployRefusalMoid -and "$Moid" -match [regex]::Escape($script:DeployRefusalMoid)) {
        throw $script:DeployRefusalMessage
    }
    # Activate restarts the blade: every host in the batch comes back with a new boot time.
    $script:BootCounter++
    foreach ($h in $script:HostState.Values) {
        $h.ExtensionData.Runtime.BootTime = "2026-08-12T0$($script:BootCounter):00:00Z"
    }
    foreach ($ap in @($ActionParams)) { if ($ap) { $script:DeployActionParams.Add("$($ap.Name)=$($ap.Value)") } }
    foreach ($sa in @($ScheduledActions)) { if ($sa) { $script:DeployActionParams.Add("$($sa.Action):ProceedOnReboot=$($sa.ProceedOnReboot)") } }
    # Both are required: -Action Deploy is what starts the deploy workflow, ProceedOnReboot is the
    # acknowledgement that the server may be restarted to activate.
    # Activate goes on its own. Deploy carries a top-level -Action alongside it, which is the form
    # the appliance requires from Pending-changes.
    foreach ($sa in @($ScheduledActions)) {
        if ($sa.Action -eq 'Activate' -and $Action) { throw "-Action must not be sent alongside the Activate scheduled action" }
    }
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
    $Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
    $Global:ExcludedFromRunHosts = @{}
    $script:DeployRefusalMoid = ''
    $script:DeployRefusalMessage = ''
    $script:ProfilesUnassigned = $false
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
Assert-True "every deploy activated from the start" (@($script:DeployActionParams | Where-Object { $_ -eq 'Activate:ProceedOnReboot=True' }).Count -eq 2) "sent: $($script:DeployActionParams -join ' | ')"
Assert-True "the deploy was confirmed as accepted, not assumed" (@($Global:RunSummary | Where-Object { $_.Action -eq 'Confirm deploy accepted' -and $_.Result -eq 'Accepted' }).Count -eq 2)
Assert-True "the pre-reboot safety window was honoured" ($script:Calls.ContainsKey('RebootSafetyWindow'))

Write-Host "`n=== Hosts were returned to service ===" -ForegroundColor Cyan
# The reconnect gate must have seen a genuine restart, not just a reachable host.
Assert-True "the reconnect gate required a real reboot" ($script:BootCounter -gt 0)
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

Write-Host "`n=== ESXi-only mode touches neither UCS Manager nor Intersight ===" -ForegroundColor Cyan
# "ESXi upgrade only" has to mean exactly that: evacuate, reboot from vCenter, check the host
# profile, put it back. Any UCSM login or Intersight call in that path is a prompt, a credential,
# or a change the operator did not ask for.
Reset-Simulation -Mode 'LIVE'
$script:Calls = @{}
function Read-Host {
    param([string]$Prompt)
    $script:PromptLog.Add($Prompt)
    if ($script:PromptLog.Count -gt $script:MaxPrompts) { throw "Prompt limit exceeded: '$Prompt'" }
    # A UCSM or Intersight prompt in ESXi-only mode is itself the failure.
    if ($Prompt -match '(?i)ucs|intersight|firmware package|api key') { throw "ESXi-only mode must not ask about firmware infrastructure: '$Prompt'" }
    switch -Regex ($Prompt) {
        'Select run mode'      { return '1' }
        'Select upgrade mode'  { return '1' }   # ESXi upgrade only
        'Select batch mode'    { return '1' }
        'Reconnect incomplete' { return 'OVERRIDE' }
        default                { return 'CONTINUE' }
    }
}
$esxiOnlyError = $null
try { Invoke-ClusterUpgradeWorkflow -Cluster $script:Cluster 6>$null } catch { $esxiOnlyError = $_ }
Assert-True "the ESXi-only workflow ran to completion" ($null -eq $esxiOnlyError) "$esxiOnlyError"

foreach ($forbidden in @('Connect-Ucs','Set-UcsServiceProfile','Set-UcsLsmaintAck','Get-UcsServiceProfile',
                         'Add-UcsFirmwareComputeHostPack','Set-IntersightServerProfile',
                         'Set-IntersightComputeServerSetting','Set-IntersightConfiguration')) {
    Assert-True "ESXi-only mode never called $forbidden" (-not $script:Calls.ContainsKey($forbidden)) "called $($script:Calls[$forbidden]) time(s)"
}
# And it DOES do the ESXi work: evacuate, reboot from vCenter, then the compliance gate.
Assert-True "the hosts were put into Maintenance mode" ($script:Calls.ContainsKey('Set-VMHost'))
Assert-True "and rebooted from vCenter, not from the fabric" ($script:Calls.ContainsKey('Restart-VMHost'))
Assert-True "every host still went through the host profile gate" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' } | Select-Object -ExpandProperty Host -Unique).Count -eq 4)
Assert-True "and the cluster completed" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ClusterComplete' }).Count -eq 1)

Write-Host "`n=== SAVE ONLY / NO ACKNOWLEDGEMENT is no longer selectable ===" -ForegroundColor Cyan
$menuText = [System.IO.File]::ReadAllText($scriptPath)
Assert-True "the run mode menu offers only LIVE, DRY RUN and Exit" ($menuText -match "Select run mode:``n  1\. LIVE RUN``n  2\. DRY RUN / VALIDATION ONLY``n  3\. Exit")
Assert-True "nothing can set RunMode to STAGE_NO_ACK" (-not ($menuText -match '\$Global:RunMode = "STAGE_NO_ACK"'))

Write-Host "`n=== A deploy the appliance refuses does not cost the cluster either ===" -ForegroundColor Cyan
# Live failure: the blade had dropped off Intersight, and the refusal ended the whole run with the
# rest of the batch already evacuated and sitting in Maintenance mode, un-upgraded and unreported.
Reset-Simulation -Mode 'LIVE'
$script:DeployRefusalMoid = 'esx01'
$script:DeployRefusalMessage = 'Error calling UpdateServerProfile: {"code":"InvalidRequest","message":"Cannot deploy the server profile. The server is disconnected. Check connectivity and try again.","messageId":"gershwin_server_is_not_connected","traceId":"NBfe8772878ef9cb88ded0a76c00ac8e97"}'
function Read-Host {
    param([string]$Prompt)
    $script:PromptLog.Add($Prompt)
    if ($script:PromptLog.Count -gt $script:MaxPrompts) { throw "Prompt limit exceeded: '$Prompt'" }
    switch -Regex ($Prompt) {
        'Select run mode'              { return '1' }
        'Select upgrade mode'          { return '2' }
        'Select batch mode'            { return '1' }
        'Create host firmware package' { return 'CREATE' }
        'Reconnect incomplete'         { return 'OVERRIDE' }
        default                        { return 'CONTINUE' }
    }
}
$refusalError = $null
try { Invoke-ClusterUpgradeWorkflow -Cluster $script:Cluster 6>$null } catch { $refusalError = $_ }
Assert-True "the run completes despite a refused deploy" ($null -eq $refusalError) "$refusalError"
Assert-True "the cluster still completed" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ClusterComplete' }).Count -eq 1)

# The whole point: the OTHER hosts still get done.
$reached = @($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' } | Select-Object -ExpandProperty Host -Unique)
foreach ($other in @('esx02.dpe.example','esx03.dpe.example','esx04.dpe.example')) {
    Assert-True "$other was still processed" ($reached -contains $other) "reached: $($reached -join ',')"
}
# And the refused host is not abandoned in Maintenance mode - it never rebooted, so it passes
# compliance and is returned to service, un-upgraded but back in the cluster.
Assert-True "the refused host was returned to service" ($script:HostState['esx01.dpe.example'].ConnectionState -eq 'Connected') "got $($script:HostState['esx01.dpe.example'].ConnectionState)"

$flagged = $Global:ManualAttentionHosts.ToArray()
$entry = @($flagged | Where-Object { $_.Host -eq 'esx01.dpe.example' })
Assert-True "the refused host is on the manual rectification list" ($entry.Count -ge 1) "list: $(($flagged | Select-Object -ExpandProperty Host) -join ',')"
Assert-True "named as a connectivity problem, not a firmware one" ($entry[0].Reason -eq 'Server disconnected from Intersight') "got: $($entry[0].Reason)"
Assert-True "the appliance's own message is kept" ($entry[0].Detail -match 'gershwin_server_is_not_connected')
Assert-True "the failure is on the run summary" (@($Global:RunSummary | Where-Object { $_.Host -eq 'esx01.dpe.example' -and $_.Result -eq 'Failed' }).Count -ge 1)
$script:DeployRefusalMoid = ''

Write-Host "`n=== The same refusal against an unassigned profile is diagnosed differently ===" -ForegroundColor Cyan
# This is the live fault. The appliance says "the server is disconnected" for BOTH a genuinely
# disconnected blade AND a profile with no server on it - and the second is what happens when a
# duplicated profile name resolves to the wrong object. Reporting connectivity in that case sends
# the operator to check a blade that is perfectly healthy, which is exactly what happened.
Reset-Simulation -Mode 'LIVE'
$script:ProfilesUnassigned = $true
$script:DeployRefusalMoid = 'esx01'
$script:DeployRefusalMessage = 'Error calling UpdateServerProfile: {"code":"InvalidRequest","message":"Cannot deploy the server profile. The server is disconnected. Check connectivity and try again.","messageId":"gershwin_server_is_not_connected"}'
try { Invoke-ClusterUpgradeWorkflow -Cluster $script:Cluster 6>$null } catch {}
$entry = @($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Host -eq 'esx01.dpe.example' })
Assert-True "the unassigned profile is diagnosed as the wrong profile" ($entry.Count -ge 1 -and $entry[0].Reason -eq 'Deployed against a profile with no server on it') "got: $($entry[0].Reason)"
Assert-True "and the advice points at the Moid column, not the device connector" ($entry[0].Detail -match 'Moid column')
$script:ProfilesUnassigned = $false
$script:DeployRefusalMoid = ''

Write-Host "`n=== An unreachable host does not cost the cluster ===" -ForegroundColor Cyan
# The live shape of this: a host is NotResponding, so it returns no CDP/LLDP. It used to fall
# through to the manual-UCSM-target prompt and then to a Stop-WithMessage on the unresolvable
# service profile - taking every other host in the cluster down with it. It must now be set aside,
# with the rest of the cluster still upgraded, and named at the end.
$script:HostState['esx05.dpe.example'] = [pscustomobject]@{
    Name = 'esx05.dpe.example'; ConnectionState = 'NotResponding'; PowerState = 'PoweredOn'
    Build = '20000000'; Id = "HostSystem-host-5"
    CpuTotalMhz = 100000; CpuUsageMhz = 20000
    MemoryTotalGB = 512;  MemoryUsageGB = 100
}
$script:HostState['esx05.dpe.example'] | Add-Member -NotePropertyName ExtensionData -NotePropertyValue ([pscustomobject]@{
    Runtime = [pscustomobject]@{ BootTime = '2026-08-01T00:00:00Z' } }) -Force

function Read-Host {
    param([string]$Prompt)
    $script:PromptLog.Add($Prompt)
    if ($script:PromptLog.Count -gt $script:MaxPrompts) { throw "Prompt limit exceeded: '$Prompt'" }
    # A prompt for a manual UCSM target for the unreachable host would mean it reached discovery at
    # all, which is the defect. Fail loudly rather than answering it.
    if ($Prompt -match 'esx05') { throw "esx05 is unreachable and must never be asked about: '$Prompt'" }
    switch -Regex ($Prompt) {
        'Select run mode'              { return '1' }
        'Select upgrade mode'          { return '2' }
        'Select batch mode'            { return '1' }
        'Create host firmware package' { return 'CREATE' }
        'Reconnect incomplete'         { return 'OVERRIDE' }
        default                        { return 'CONTINUE' }
    }
}
Reset-Simulation -Mode 'LIVE'
# NotResponding must survive the reset that returns every other host to Connected.
$script:HostState['esx05.dpe.example'].ConnectionState = 'NotResponding'
$unreachableError = $null
try { Invoke-ClusterUpgradeWorkflow -Cluster $script:Cluster 6>$null } catch { $unreachableError = $_ }
Assert-True "the run completes despite an unreachable host" ($null -eq $unreachableError) "$unreachableError"
Assert-True "the cluster still completed" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ClusterComplete' }).Count -eq 1)

$otherHosts = @('esx01.dpe.example','esx02.dpe.example','esx03.dpe.example','esx04.dpe.example')
$compliance = @($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' } | Select-Object -ExpandProperty Host -Unique)
Assert-True "every other host in the cluster was still processed" (@($otherHosts | Where-Object { $compliance -notcontains $_ }).Count -eq 0) "reached: $($compliance -join ',')"
Assert-True "the unreachable host was never batched" ($compliance -notcontains 'esx05.dpe.example')

$flagged = $Global:ManualAttentionHosts.ToArray()
Assert-True "the unreachable host is on the manual rectification list" (@($flagged | Where-Object { $_.Host -eq 'esx05.dpe.example' }).Count -ge 1) "list: $(($flagged | Select-Object -ExpandProperty Host) -join ',')"
Assert-True "and it is marked as never upgraded, not merely noted" (@($flagged | Where-Object { $_.Host -eq 'esx05.dpe.example' -and $_.Excluded }).Count -ge 1)
Assert-True "the reason names the connection state" (@($flagged | Where-Object { $_.Host -eq 'esx05.dpe.example' })[0].Detail -match 'NotResponding')
Assert-True "it reached the run summary as an exclusion" (@($Global:RunSummary | Where-Object { $_.Host -eq 'esx05.dpe.example' -and $_.Result -eq 'Unreachable' }).Count -ge 1)

Write-Host "`n=== The closing report lists them, and records them ===" -ForegroundColor Cyan
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
Show-ManualAttentionReport -ClusterName 'TestCluster' 6>$null
$recorded = @($Global:RunSummary | Where-Object { $_.Stage -eq 'ManualAttention' })
Assert-True "the report writes a summary row per host" ($recorded.Count -ge 1) "got $($recorded.Count)"
Assert-True "an excluded host is recorded as NotUpgraded" (@($recorded | Where-Object { $_.Host -eq 'esx05.dpe.example' -and $_.Result -eq 'NotUpgraded' }).Count -eq 1)

# An empty register still prints, and still says so - a report that only appears on failure is one
# nobody trusts is running.
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$emptyError = $null
try { Show-ManualAttentionReport -ClusterName 'TestCluster' 6>$null } catch { $emptyError = $_ }
Assert-True "an empty report is not an error" ($null -eq $emptyError) "$emptyError"
Assert-True "and it writes no ManualAttention rows" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ManualAttention' }).Count -eq 0)

$script:HostState.Remove('esx05.dpe.example')

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
