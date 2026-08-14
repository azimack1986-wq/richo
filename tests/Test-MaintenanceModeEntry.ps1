<#
.SYNOPSIS
    Tests that a batch enters Maintenance mode one host at a time, in cluster order.

.DESCRIPTION
    An earlier design requested every host in the batch at once, on the theory that DRS would
    exclude all of them from placement so each VM moved once. On a live AUTO run it did the
    opposite: the capacity available to receive VMs was shrinking at the same time as the VMs
    needed placing, so migrations ran continuously and no host ever reached Maintenance mode.

    The behaviour that matters is therefore not "did every host end up in Maintenance mode" - the
    old code would pass that against a stub too - but the ORDERING: host N+1 must not be asked
    until host N has arrived. These assertions record the state of the whole batch at the moment
    each request is issued, which is the only way to tell the two designs apart.

    SINGLE mode is a batch of one and must be untouched by this.

    Standalone - no Pester, no PowerCLI, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-MaintenanceModeEntry.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Request-MaintenanceModeForBatch','Wait-VMHostInMaintenance','Wait-VMHostOutOfMaintenance','Get-VMHostMaintenanceState','Test-VMHostObjectInMaintenance','Test-DryRun','Test-StageNoAck') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$MaintenanceValidationTimeoutMinutes = 1
$Global:RunMode = 'LIVE'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
function Stop-SafeExit { param($Message) throw "EXIT: $Message" }
function Start-Sleep { param($Seconds,$Milliseconds) }

$script:ManualAttention = New-Object System.Collections.Generic.List[object]
function Add-ManualAttentionHost { param($HostName,$Reason,$Detail,[switch]$ExcludeFromRun)
    $script:ManualAttention.Add([pscustomobject]@{ Host=$HostName; Reason=$Reason; Detail=$Detail }) }

# The operator's keyboard. Each entry is consumed by one Read-PendingConsoleKey call, so a queue of
# @('','','O') presses O on the third look - which is how a real override arrives mid-wait.
$script:KeyQueue = New-Object System.Collections.Generic.Queue[string]
function Read-PendingConsoleKey {
    if ($script:KeyQueue.Count -eq 0) { return "" }
    return $script:KeyQueue.Dequeue()
}

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# --- Simulated cluster ------------------------------------------------------------------------
# Evacuation takes a few polls, so a design that fired every request up front would be visible as
# more than one host in "entering" at the same moment.
$script:State = @{}
$script:PollsRemaining = @{}
$script:RequestOrder = New-Object System.Collections.Generic.List[string]
$script:StateAtRequest = New-Object System.Collections.Generic.List[string]
$script:AsyncUsed = New-Object System.Collections.Generic.List[bool]
$script:StuckHosts = @()

function Reset-Cluster {
    param([string[]]$Names)
    $script:State = @{}
    $script:PollsRemaining = @{}
    foreach ($n in $Names) { $script:State[$n] = 'Connected'; $script:PollsRemaining[$n] = 2 }
    $script:RequestOrder = New-Object System.Collections.Generic.List[string]
    $script:StateAtRequest = New-Object System.Collections.Generic.List[string]
    $script:AsyncUsed = New-Object System.Collections.Generic.List[bool]
    $script:EvacuateUsed = New-Object System.Collections.Generic.List[bool]
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
    $script:InMaintFlag = @{}
    $script:UnreadableHosts = @()
    $script:ManualAttention = New-Object System.Collections.Generic.List[object]
    $script:KeyQueue = New-Object System.Collections.Generic.Queue[string]
}

$script:InMaintFlag = @{}
$script:UnreadableHosts = @()
function Get-VMHost {
    param($Name,$Location,$ErrorAction)
    if ($Name -and $script:UnreadableHosts -contains $Name) { return $null }
    if ($Name -and $script:State.ContainsKey($Name)) {
        # An "entering" host settles after a couple of polls, unless it is one of the stuck ones.
        if ($script:State[$Name] -eq 'Entering') {
            if ($script:StuckHosts -notcontains $Name) {
                $script:PollsRemaining[$Name] = $script:PollsRemaining[$Name] - 1
                if ($script:PollsRemaining[$Name] -le 0) { $script:State[$Name] = 'Maintenance' }
            }
        }
        # Both properties, because the whole point is that they can disagree. runtime.connectionState
        # and runtime.inMaintenanceMode are independent in the vSphere API: a parked host whose
        # heartbeat is missed reads NotResponding with inMaintenanceMode still true.
        $flag = if ($script:InMaintFlag.ContainsKey($Name)) { [bool]$script:InMaintFlag[$Name] } else { $script:State[$Name] -eq 'Maintenance' }
        return [pscustomobject]@{
            Name            = $Name
            ConnectionState = $script:State[$Name]
            ExtensionData   = [pscustomobject]@{ Runtime = [pscustomobject]@{ InMaintenanceMode = $flag } }
        }
    }
    return $null
}

$script:EvacuateUsed = New-Object System.Collections.Generic.List[bool]
function Set-VMHost {
    param($VMHost,$State,[switch]$Evacuate,[switch]$RunAsync,$Confirm,$ErrorAction)
    $script:RequestOrder.Add($VMHost.Name)
    $script:AsyncUsed.Add([bool]$RunAsync)
    $script:EvacuateUsed.Add([bool]$Evacuate)
    # The state of every OTHER host at the moment this request goes out. Under the old
    # request-everything-at-once design, hosts later in the batch would already be 'Entering'.
    $others = @($script:State.Keys | Where-Object { $_ -ne $VMHost.Name } | Sort-Object | ForEach-Object { "$_=$($script:State[$_])" })
    $script:StateAtRequest.Add($others -join ',')
    $script:State[$VMHost.Name] = 'Entering'
}

$batch = @('esx01','esx02','esx03','esx04')

Write-Host "`n=== Hosts are evacuated one at a time, in cluster order ===" -ForegroundColor Cyan
Reset-Cluster -Names $batch
Request-MaintenanceModeForBatch -HostNames $batch 6>$null
Assert-Equal "every host was requested" 4 $script:RequestOrder.Count
Assert-Equal "in the order the batch was given" "esx01,esx02,esx03,esx04" ($script:RequestOrder -join ',')
Assert-Equal "every host ended in Maintenance mode" 4 (@($batch | Where-Object { $script:State[$_] -eq 'Maintenance' }).Count)

Write-Host "`n=== No host is asked while another is still evacuating ===" -ForegroundColor Cyan
# This is the assertion the old design fails. Requesting the whole batch up front means that when
# esx02 is asked, esx01 is still 'Entering' - and DRS is placing VMs onto a shrinking cluster.
$overlaps = @($script:StateAtRequest | Where-Object { $_ -match 'Entering' })
Assert-Equal "no request went out while another host was still entering" 0 $overlaps.Count "overlapping: $($overlaps -join ' | ')"
Assert-Equal "each request saw the previous hosts already in Maintenance" "esx02=Connected,esx03=Connected,esx04=Connected" $script:StateAtRequest[0]
Assert-Equal "and the last saw the first three settled" "esx01=Maintenance,esx02=Maintenance,esx03=Maintenance" $script:StateAtRequest[3]

Write-Host "`n=== The evacuation is polled, never held open ===" -ForegroundColor Cyan
# A blocking Set-VMHost holds one HTTP request open past PowerCLI's timeout ceiling and is torn
# down mid-evacuation, leaving the host partway in.
Assert-Equal "every request used -RunAsync" 4 (@($script:AsyncUsed | Where-Object { $_ }).Count)

Write-Host "`n=== Nothing is migrated to make room ===" -ForegroundColor Cyan
# -Evacuate is evacuatePoweredOffVms: it cold-migrates every powered-off and suspended VM off the
# host before it will enter Maintenance mode. On a large cluster that takes longer than the upgrade
# and DRS undoes it the moment the host returns. Powered-off VMs do not block Maintenance mode.
Assert-Equal "no request passed -Evacuate" 0 (@($script:EvacuateUsed | Where-Object { $_ }).Count)
$scriptText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the script never calls Move-VM" $true (-not ($scriptText -match '(?m)^\s*Move-VM\b'))
Assert-Equal "and no powered-off VM sweep survives" $true (-not ($scriptText -match 'Move-PoweredOffAndSuspendedVMsForBatch'))

Write-Host "`n=== SINGLE mode is a batch of one and behaves exactly as before ===" -ForegroundColor Cyan
Reset-Cluster -Names @('esx01')
Request-MaintenanceModeForBatch -HostNames @('esx01') 6>$null
Assert-Equal "one request" 1 $script:RequestOrder.Count
Assert-Equal "asynchronous" $true $script:AsyncUsed[0]
Assert-Equal "and the host arrives" "Maintenance" $script:State['esx01']

Write-Host "`n=== A host already in Maintenance mode is not asked again ===" -ForegroundColor Cyan
Reset-Cluster -Names $batch
$script:State['esx02'] = 'Maintenance'
Request-MaintenanceModeForBatch -HostNames $batch 6>$null
Assert-Equal "esx02 was skipped" "esx01,esx03,esx04" ($script:RequestOrder -join ',')
Assert-Equal "and recorded as already in" "AlreadyIn" (@($Global:RunSummary | Where-Object { $_.Host -eq 'esx02' })[0].Result)

Write-Host "`n=== A host that will not evacuate stops the run, and the rest are untouched ===" -ForegroundColor Cyan
# Stacking a second stuck evacuation on top of the first only makes the cluster harder to recover.
Reset-Cluster -Names $batch
$script:StuckHosts = @('esx02')
$stopMessage = ""
try { Request-MaintenanceModeForBatch -HostNames $batch 6>$null } catch { $stopMessage = "$_" }
$script:StuckHosts = @()
Assert-Equal "the run stops" $true ($stopMessage -match 'STOP:')
Assert-Equal "naming the host that would not evacuate" $true ($stopMessage -match 'esx02')
Assert-Equal "esx03 and esx04 were never asked" "esx01,esx02" ($script:RequestOrder -join ',')
Assert-Equal "the timeout is on the record" "Timeout" (@($Global:RunSummary | Where-Object { $_.Host -eq 'esx02' })[0].Result)

Write-Host "`n=== A host that is not Connected is not evacuated ===" -ForegroundColor Cyan
Reset-Cluster -Names $batch
$script:State['esx01'] = 'NotResponding'
$stopMessage = ""
try { Request-MaintenanceModeForBatch -HostNames $batch 6>$null } catch { $stopMessage = "$_" }
Assert-Equal "the run stops rather than trying" $true ($stopMessage -match 'NotResponding')
Assert-Equal "and nothing was requested" 0 $script:RequestOrder.Count

Write-Host "`n=== DRY RUN evacuates nothing ===" -ForegroundColor Cyan
Reset-Cluster -Names $batch
$Global:RunMode = 'DRYRUN'
Request-MaintenanceModeForBatch -HostNames $batch 6>$null
Assert-Equal "no request was issued" 0 $script:RequestOrder.Count
Assert-Equal "and every host is still Connected" 4 (@($batch | Where-Object { $script:State[$_] -eq 'Connected' }).Count)
$Global:RunMode = 'LIVE'

Write-Host "`n=== Maintenance mode is read from inMaintenanceMode, not ConnectionState ===" -ForegroundColor Cyan
# The live fault this covers: a host sat in Maintenance mode in vCenter while the run reported
# "still evacuating" until its timeout ran out. In the vSphere API runtime.connectionState is only
# connected/disconnected/notResponding - there is no maintenance member - and inMaintenanceMode is a
# separate boolean. Evacuating a busy host is exactly when its heartbeat is missed, so PowerCLI's
# folded ConnectionState reads NotResponding and an equality test against "Maintenance" never comes
# true. The boolean is the authority.
$parkedButBlipping = [pscustomobject]@{ Name='esx09'; ConnectionState='NotResponding'
    ExtensionData = [pscustomobject]@{ Runtime = [pscustomobject]@{ InMaintenanceMode = $true } } }
Assert-Equal "a parked host reading NotResponding is still in Maintenance mode" $true (Test-VMHostObjectInMaintenance -VMHostObject $parkedButBlipping)

$enteringNotArrived = [pscustomobject]@{ Name='esx10'; ConnectionState='Connected'
    ExtensionData = [pscustomobject]@{ Runtime = [pscustomobject]@{ InMaintenanceMode = $false } } }
Assert-Equal "a host still entering is not in Maintenance mode" $false (Test-VMHostObjectInMaintenance -VMHostObject $enteringNotArrived)

# The flag beats ConnectionState in BOTH directions. Trusting ConnectionState also declared a host
# that was still parked to be out of Maintenance mode, which is the more dangerous half.
$staleComposite = [pscustomobject]@{ Name='esx11'; ConnectionState='Maintenance'
    ExtensionData = [pscustomobject]@{ Runtime = [pscustomobject]@{ InMaintenanceMode = $false } } }
Assert-Equal "the boolean wins over a ConnectionState of Maintenance" $false (Test-VMHostObjectInMaintenance -VMHostObject $staleComposite)

# ExtensionData unreadable is the only case ConnectionState is consulted.
$noExtensionData = [pscustomobject]@{ Name='esx12'; ConnectionState='Maintenance' }
Assert-Equal "ConnectionState is the fallback when the flag cannot be read" $true (Test-VMHostObjectInMaintenance -VMHostObject $noExtensionData)
Assert-Equal "a null host is not in Maintenance mode" $false (Test-VMHostObjectInMaintenance -VMHostObject $null)

Write-Host "`n=== A parked host whose heartbeat blips is not waited on, and does not stop the run ===" -ForegroundColor Cyan
Reset-Cluster -Names $batch
$script:State['esx02'] = 'NotResponding'
$script:InMaintFlag['esx02'] = $true
Request-MaintenanceModeForBatch -HostNames $batch 6>$null
Assert-Equal "esx02 was recognised as already parked and skipped" "esx01,esx03,esx04" ($script:RequestOrder -join ',')
Assert-Equal "and recorded as already in, not as a failure" "AlreadyIn" (@($Global:RunSummary | Where-Object { $_.Host -eq 'esx02' })[0].Result)
$script:InMaintFlag = @{}

Write-Host "`n=== 'Could not read the host' is not 'the host is still evacuating' ===" -ForegroundColor Cyan
# Get-VMHost -ErrorAction SilentlyContinue inside a try/catch returns $null for a dropped vCenter
# session just as it does for a host that is simply not there yet. Reading the two as the same thing
# is how a run waits out its whole window blind.
$unreadable = Get-VMHostMaintenanceState -HostName 'esx-nosuch'
Assert-Equal "an unreadable host is flagged unreadable" $false $unreadable.Readable
Assert-Equal "and is not claimed to be in Maintenance mode" $false $unreadable.InMaintenance
Reset-Cluster -Names $batch
$readable = Get-VMHostMaintenanceState -HostName 'esx01'
Assert-Equal "a host that answers is readable" $true $readable.Readable
Assert-Equal "and carries its object through for the caller" "esx01" $readable.VMHost.Name

Write-Host "`n=== An unreadable host stops the run rather than being evacuated blind ===" -ForegroundColor Cyan
Reset-Cluster -Names $batch
$script:UnreadableHosts = @('esx01')
$stopMessage = ""
try { Request-MaintenanceModeForBatch -HostNames $batch 6>$null } catch { $stopMessage = "$_" }
$script:UnreadableHosts = @()
Assert-Equal "the run stops" $true ($stopMessage -match 'STOP:')
Assert-Equal "saying the host could not be read" $true ($stopMessage -match 'could not be read from vCenter')
Assert-Equal "and nothing was requested" 0 $script:RequestOrder.Count

Write-Host "`n=== O forces past a hanging evacuation ===" -ForegroundColor Cyan
# An hour of watching a counter and then a stopped run is the wrong answer when the engineer in
# front of vCenter already knows the host is not going to arrive.
Reset-Cluster -Names $batch
$script:StuckHosts = @('esx01')
$script:KeyQueue.Enqueue('')
$script:KeyQueue.Enqueue('O')
Request-MaintenanceModeForBatch -HostNames $batch 6>$null
$script:StuckHosts = @()
Assert-Equal "the run carried on to the rest of the batch" "esx01,esx02,esx03,esx04" ($script:RequestOrder -join ',')
Assert-Equal "the override is on the record" "Overridden" (@($Global:RunSummary | Where-Object { $_.Host -eq 'esx01' })[0].Result)
Assert-Equal "and the host is listed for manual attention" 1 (@($script:ManualAttention | Where-Object { $_.Host -eq 'esx01' }).Count)
Assert-Equal "with the reason recorded" "Evacuation overridden" (@($script:ManualAttention | Where-Object { $_.Host -eq 'esx01' })[0].Reason)

Write-Host "`n=== E exits safely from the wait ===" -ForegroundColor Cyan
Reset-Cluster -Names $batch
$script:StuckHosts = @('esx01')
$script:KeyQueue.Enqueue('E')
$exitMessage = ""
try { Request-MaintenanceModeForBatch -HostNames $batch 6>$null } catch { $exitMessage = "$_" }
$script:StuckHosts = @()
Assert-Equal "the run exits rather than stopping with an error" $true ($exitMessage -match 'EXIT:')
Assert-Equal "naming the host it was waiting on" $true ($exitMessage -match 'esx01')
Assert-Equal "and no further host was asked" "esx01" ($script:RequestOrder -join ',')

Write-Host "`n=== Leaving Maintenance mode is read from the same flag ===" -ForegroundColor Cyan
# The mirror image, and the more dangerous one: ConnectionState -ne "Maintenance" called a host out
# of Maintenance mode the moment its heartbeat blipped, while it was still parked.
Reset-Cluster -Names $batch
$script:State['esx01'] = 'NotResponding'
$script:InMaintFlag['esx01'] = $true
$stillParked = Get-VMHostMaintenanceState -HostName 'esx01'
Assert-Equal "a still-parked host reading NotResponding is in Maintenance mode" $true $stillParked.InMaintenance
Assert-Equal "so the leave-Maintenance test does not fire" $false ($stillParked.Readable -and -not $stillParked.InMaintenance)
$script:InMaintFlag['esx01'] = $false
$script:State['esx01'] = 'Connected'
Assert-Equal "and once the flag clears it is" $true (Wait-VMHostOutOfMaintenance -HostName 'esx01' -TimeoutMinutes 1 6>$null)
$script:InMaintFlag = @{}

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
