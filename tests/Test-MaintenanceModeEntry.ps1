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
    Where-Object { $_.Name -in @('Request-MaintenanceModeForBatch','Wait-VMHostInMaintenance','Test-DryRun','Test-StageNoAck') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$MaintenanceValidationTimeoutMinutes = 1
$Global:RunMode = 'LIVE'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
function Start-Sleep { param($Seconds,$Milliseconds) }

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
}

function Get-VMHost {
    param($Name,$Location,$ErrorAction)
    if ($Name -and $script:State.ContainsKey($Name)) {
        # An "entering" host settles after a couple of polls, unless it is one of the stuck ones.
        if ($script:State[$Name] -eq 'Entering') {
            if ($script:StuckHosts -notcontains $Name) {
                $script:PollsRemaining[$Name] = $script:PollsRemaining[$Name] - 1
                if ($script:PollsRemaining[$Name] -le 0) { $script:State[$Name] = 'Maintenance' }
            }
        }
        return [pscustomobject]@{ Name = $Name; ConnectionState = $script:State[$Name] }
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

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
