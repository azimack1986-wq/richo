<#
.SYNOPSIS
    Tests the rolling upgrade engine: a host's slot is refilled as soon as it is back and healthy.

.DESCRIPTION
    The batch shape this replaced did not start host N+1 until the SLOWEST of the first N had
    finished, so a host back in twenty minutes sat idle while its neighbour took fifty. What has to
    be true of the replacement:

      - admission is bounded by live capacity, re-read every pass, never by a fixed batch;
      - a slot freed by a host completing is refilled on the next pass, without waiting for its
        wave-mates;
      - each host settles from ITS OWN return time, so the settle windows overlap;
      - SINGLE mode is the same engine with the limit fixed at one, and still serialises;
      - nothing ends the run except an explicit exit.

    A fake clock drives the waits, so the whole thing runs in milliseconds.

    Standalone - no Pester, no PowerCLI, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-RollingUpgrade.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Invoke-RollingClusterUpgrade','Get-RollingConcurrencyLimit',
                                 'Start-RollingHostWave','Get-RollingHostDiagnostic',
                                 'Test-VMHostDisconnected','Restore-DisconnectedVMHost',
                                 'Get-CapacityBasedBatchSize','Test-VMHostRejoinedAfterReboot',
                                 'Get-VMHostBootTime','Read-ChoiceExit','Read-PendingConsoleKey',
                                 'Test-VMHostObjectInMaintenance','Get-VMHostMaintenanceState',
                                 'Test-DryRun','Test-StageNoAck') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal { param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

# --- Settings the engine reads ------------------------------------------------------------------
$ResourceSafetyBuffer = 0.85
$MinimumCpuHeadroomPercentAfterBatch = 10
$MinimumMemoryHeadroomPercentAfterBatch = 10
$MaxAbsoluteBatchSize = 0
$MaxConcurrentHostFraction = 0.5
$MaintenanceValidationTimeoutMinutes = 60
$FirmwareReconnectInitialWaitMinutes = 30
$HostProfileComplianceSettleMinutes = 8
$Global:IntersightActivationHoldMinutes = 30
$Global:IntersightPollIntervalSeconds = 30
$Global:RunMode = 'LIVE'
$Global:UpgradeMode = 'ESXI_ONLY'
$Global:IntersightHostMap = @{}
$Global:PreRebootBootTimes = @{}
# No root credential in these runs: the disconnect and reconnect path has its own test, and here a
# host either comes back or it does not.
$Global:EsxiRootCredential = $null
$HostReconnectAfterDisconnectMinutes = 5
$HostReconnectMaxAttempts = 3
$HostReconnectRetryPauseMinutes = 2
$Global:BatchActionsSent = 0
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:ExcludedFromRunHosts = @{}
$Global:CurrentClusterName = 'TestCluster'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-SafeExit { param($Message) throw "EXIT: $Message" }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
function Add-ManualAttentionHost { param($HostName,$Reason,$Detail,$ClusterName,[switch]$ExcludeFromRun)
    $Global:ManualAttentionHosts.Add([pscustomobject]@{ Host=$HostName; Reason=$Reason; Detail=$Detail; Excluded=[bool]$ExcludeFromRun }) }

# --- Fake clock ---------------------------------------------------------------------------------
$script:Now = [datetime]'2026-08-12T00:00:00'
function Get-Date { param($Format,$Date,$UFormat) if ($Format) { return $script:Now.ToString($Format) }; return $script:Now }
function Start-Sleep { param($Seconds,$Milliseconds) $script:Now = $script:Now.AddSeconds([double]$Seconds) }

# --- Simulated cluster --------------------------------------------------------------------------
# Each host takes its own time to come back, which is the whole point: a fast host must not wait
# for a slow one.
$script:Hosts = @{}
$script:ReturnAfter = @{}
$script:Log = New-Object System.Collections.Generic.List[string]

function New-SimHost { param([string]$Name)
    [pscustomobject]@{ Name=$Name; ConnectionState='Connected'; CpuTotalMhz=100000; CpuUsageMhz=10000
        MemoryTotalGB=512; MemoryUsageGB=50
        ExtensionData=[pscustomobject]@{ Runtime=[pscustomobject]@{ BootTime='2026-08-01T00:00:00Z' } } } }

function Reset-Cluster { param([int]$Count,[hashtable]$Returns)
    $script:Hosts = @{}
    1..$Count | ForEach-Object { $script:Hosts["esx0$_"] = New-SimHost -Name "esx0$_" }
    $script:ReturnAfter = $Returns
    $script:Log = New-Object System.Collections.Generic.List[string]
    $Global:PreRebootBootTimes = @{}
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
    $script:Now = [datetime]'2026-08-12T00:00:00' }

function Get-VMHost { param($Name,$Location,$ErrorAction)
    if ($Name) { return $script:Hosts[$Name] }
    return @($script:Hosts.Values | Sort-Object Name) }
function Get-Cluster { param($Name,$ErrorAction) return [pscustomobject]@{ Name='TestCluster' } }

# Entering Maintenance mode, and the reboot, are what the wave does. The host comes back on its
# own schedule afterwards - modelled by stamping a due time and flipping the boot time when it
# passes, which is exactly what the engine has to detect.
$script:DueBack = @{}
function Request-MaintenanceModeForBatch { param($HostNames)
    foreach ($n in $HostNames) { $script:Hosts[$n].ConnectionState = 'Maintenance'; $script:Log.Add("maint:$n") } }
function Wait-BatchMaintenanceMode { param($HostNames,$TimeoutMinutes) return @($HostNames) }
function Invoke-RebootSafetyWindow { param($TimeoutSeconds,$HostNames,$BatchNumber) return $true }
function Restart-VMHost { param($VMHost,$Confirm,$ErrorAction)
    $script:Log.Add("reboot:$($VMHost.Name)")
    $script:DueBack[$VMHost.Name] = $script:Now.AddMinutes([double]$script:ReturnAfter[$VMHost.Name])
    $Global:BatchActionsSent++ }
function Save-BatchBootTimes { param($HostNames,[switch]$Append)
    if (-not $Append) { $Global:PreRebootBootTimes = @{} }
    foreach ($n in $HostNames) { $Global:PreRebootBootTimes[$n] = $script:Hosts[$n].ExtensionData.Runtime.BootTime } }

# The clock advancing is what brings hosts back.
function Update-Returns {
    foreach ($n in @($script:DueBack.Keys)) {
        if ($script:Now -ge $script:DueBack[$n]) {
            $script:Hosts[$n].ExtensionData.Runtime.BootTime = '2026-08-12T09:00:00Z'
            [void]$script:DueBack.Remove($n)
        }
    }
}
# Hook the return simulation onto the clock.
function Start-Sleep { param($Seconds,$Milliseconds) $script:Now = $script:Now.AddSeconds([double]$Seconds); Update-Returns }

function Confirm-SingleHostComplianceAndExit { param($HostName,$BatchNumber)
    $script:Log.Add("complete:$HostName")
    $script:Hosts[$HostName].ConnectionState = 'Connected'
    # Back in service means its capacity returns to the cluster too.
    $script:Hosts[$HostName].CpuUsageMhz = 10000 }
function Read-Host { param($Prompt) throw "no prompt expected: $Prompt" }

$cluster = [pscustomobject]@{ Name = 'TestCluster' }

Write-Host "`n=== A fast host does not wait for a slow one ===" -ForegroundColor Cyan
# esx01 comes back in 10 minutes, esx02 in 50. Batched, esx03 could not start until 50 minutes had
# passed. Rolling, esx01's slot is refilled as soon as it is back.
Reset-Cluster -Count 4 -Returns @{ esx01=10; esx02=50; esx03=10; esx04=10 }
Invoke-RollingClusterUpgrade -Cluster $cluster -OrderedHostNames @('esx01','esx02','esx03','esx04') -BatchMode 'AUTO' 6>$null
$order = @($script:Log | Where-Object { $_ -like 'complete:*' } | ForEach-Object { $_.Split(':')[1] })
Assert-Equal "every host completed" 4 $order.Count
Assert-Equal "the slow host finished last, not in wave order" "esx02" $order[-1]
Assert-Equal "and the fast hosts went first" $true ($order[0] -ne 'esx02')

Write-Host "`n=== A freed slot is refilled before the wave finishes ===" -ForegroundColor Cyan
# esx03 must have been STARTED while esx02 was still out - that is the whole behaviour.
$startOrder = @($script:Log | Where-Object { $_ -like 'maint:*' } | ForEach-Object { $_.Split(':')[1] })
$esx02Done = $script:Log.IndexOf('complete:esx02')
$esx03Start = $script:Log.IndexOf('maint:esx03')
Assert-Equal "esx03 started before the slow host had finished" $true ($esx03Start -lt $esx02Done)
Assert-Equal "hosts were admitted in cluster order" "esx01,esx02,esx03,esx04" ($startOrder -join ',')

Write-Host "`n=== SINGLE mode is the same engine, serialised ===" -ForegroundColor Cyan
Reset-Cluster -Count 3 -Returns @{ esx01=10; esx02=10; esx03=10 }
Invoke-RollingClusterUpgrade -Cluster $cluster -OrderedHostNames @('esx01','esx02','esx03') -BatchMode 'SINGLE' 6>$null
$seq = @($script:Log | Where-Object { $_ -like 'maint:*' -or $_ -like 'complete:*' })
Assert-Equal "one host is in flight at a time" "maint:esx01,complete:esx01,maint:esx02,complete:esx02,maint:esx03,complete:esx03" ($seq -join ',')

Write-Host "`n=== Capacity, not a fixed number, decides how many are out ===" -ForegroundColor Cyan
# A busy cluster: 10 hosts at 70% CPU cannot spare even one.
Reset-Cluster -Count 10 -Returns @{}
foreach ($h in $script:Hosts.Values) { $h.CpuUsageMhz = 70000 }
$stopped = $false
try { Invoke-RollingClusterUpgrade -Cluster $cluster -OrderedHostNames @('esx01') -BatchMode 'AUTO' 6>$null }
catch { $stopped = "$_" -match 'insufficient capacity' }
Assert-Equal "a cluster with no headroom stops rather than evacuating anyway" $true $stopped

Write-Host "`n=== DRY RUN starts nothing and still completes ===" -ForegroundColor Cyan
$Global:RunMode = 'DRYRUN'
Reset-Cluster -Count 3 -Returns @{}
Invoke-RollingClusterUpgrade -Cluster $cluster -OrderedHostNames @('esx01','esx02','esx03') -BatchMode 'AUTO' 6>$null
Assert-Equal "DRY RUN rebooted nothing" 0 (@($script:Log | Where-Object { $_ -like 'reboot:*' }).Count)
Assert-Equal "and still reached every host" 3 (@($script:Log | Where-Object { $_ -like 'complete:*' }).Count)
$Global:RunMode = 'LIVE'

Write-Host "`n=== A disconnected host gets three reconnect attempts, two minutes apart ===" -ForegroundColor Cyan
# One attempt was not enough. A host that has just rebooted onto new firmware routinely refuses the
# first reconnect - hostd still starting, the vmk not up, the certificate being regenerated - and a
# single try wrote those off as unrecoverable when the next would have taken them.
Reset-Cluster -Count 2 -Returns @{ esx01 = 9999; esx02 = 10 }
$script:ReconnectCalls = New-Object System.Collections.Generic.List[string]
$script:ReconnectSucceedsOn = 0        # 0 = never
$script:Answers = New-Object System.Collections.Generic.Queue[string]

function Test-VMHostDisconnected { param($HostName) return ($HostName -eq 'esx01') }
function Restore-DisconnectedVMHost { param($HostName,$TimeoutMinutes)
    $script:ReconnectCalls.Add("$HostName@$($script:Now.ToString('HH:mm'))")
    if ($script:ReconnectSucceedsOn -gt 0 -and $script:ReconnectCalls.Count -ge $script:ReconnectSucceedsOn) {
        $script:Hosts[$HostName].ConnectionState = 'Connected'
        $script:Hosts[$HostName].ExtensionData.Runtime.BootTime = '2026-08-12T01:00:00Z'
        return $true
    }
    return $false }
function Read-ChoiceExit { param($Message,$AllowedChoices,$ExitMessage)
    if ($script:Answers.Count -eq 0) { throw "EXIT: $ExitMessage" }
    return $script:Answers.Dequeue() }

$script:Answers.Enqueue('S')   # set aside once the attempts run out
Invoke-RollingClusterUpgrade -Cluster $cluster -OrderedHostNames @('esx01','esx02') -BatchMode 'AUTO' 6>$null

Assert-Equal "exactly three attempts were made" 3 $script:ReconnectCalls.Count
$times = @($script:ReconnectCalls.ToArray() | ForEach-Object { [datetime]::ParseExact(($_ -split '@')[1], 'HH:mm', $null) })
Assert-Equal "the second is two minutes after the first" 2 ([int](($times[1] - $times[0]).TotalMinutes))
Assert-Equal "and the third two minutes after that" 2 ([int](($times[2] - $times[1]).TotalMinutes))
Assert-Equal "each attempt is recorded" 3 (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -eq 'Reconnect host' -and $_.Result -eq 'Retrying' }).Count)

Write-Host "`n=== Out of attempts, the operator is asked - not the host abandoned ===" -ForegroundColor Cyan
Assert-Equal "set aside on the record" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'SetAside' }).Count)
Assert-Equal "and listed for manual rectification" 1 (@($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Host -eq 'esx01' -and $_.Reason -match 'could not be reconnected' }).Count)
Assert-Equal "the rest of the cluster still completed" $true (@($script:Log | Where-Object { $_ -eq 'complete:esx02' }).Count -ge 1)

Write-Host "`n=== A reconnect that works stops the retries and rejoins the normal flow ===" -ForegroundColor Cyan
Reset-Cluster -Count 1 -Returns @{ esx01 = 9999 }
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$script:ReconnectCalls = New-Object System.Collections.Generic.List[string]
$script:ReconnectSucceedsOn = 2
$script:Answers.Clear()
Invoke-RollingClusterUpgrade -Cluster $cluster -OrderedHostNames @('esx01') -BatchMode 'AUTO' 6>$null
Assert-Equal "it stopped at the attempt that worked" 2 $script:ReconnectCalls.Count
Assert-Equal "recorded as reconnected" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'Reconnected' }).Count)
Assert-Equal "nothing was left for manual rectification" 0 $Global:ManualAttentionHosts.Count
Assert-Equal "and the host completed" 1 (@($script:Log | Where-Object { $_ -eq 'complete:esx01' }).Count)

Write-Host "`n=== R gives it another three attempts after manual intervention ===" -ForegroundColor Cyan
Reset-Cluster -Count 1 -Returns @{ esx01 = 9999 }
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$script:ReconnectCalls = New-Object System.Collections.Generic.List[string]
$script:ReconnectSucceedsOn = 5        # works on the 5th, which is the 2nd of the second round
$script:Answers.Clear(); $script:Answers.Enqueue('R')
Invoke-RollingClusterUpgrade -Cluster $cluster -OrderedHostNames @('esx01') -BatchMode 'AUTO' 6>$null
Assert-Equal "the retries resume rather than stopping at three" 5 $script:ReconnectCalls.Count
Assert-Equal "the operator retry is on the record" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'OperatorRetry' }).Count)
Assert-Equal "and the host came back" 1 (@($script:Log | Where-Object { $_ -eq 'complete:esx01' }).Count)

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
