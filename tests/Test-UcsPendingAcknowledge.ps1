<#
.SYNOPSIS
    Tests that a UCS Manager pending activity is waited for, acknowledged, and confirmed cleared.

.DESCRIPTION
    Reported from a live run: "firmware policy updated on blades but hasn't acknowledged".

    UCSM raises the pending activity ASYNCHRONOUSLY after the service profile's firmware package
    changes. Asking for it the instant the policy write returns is a race - on a busy domain the
    object is not there yet, every host reads PendingAckFound=$false, the loop acknowledges
    nothing, and the run reports a batch sent while the blades sit staged and waiting. There was
    no test over this path at all, which is why a silent no-op could ship.

    Three things are asserted, and the third is the one that was missing entirely: that the
    acknowledgement is CONFIRMED by re-reading rather than assumed from the write returning.

    Standalone - no Pester, no UCS PowerTool, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsPendingAcknowledge.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Invoke-UcsPendingAckForBatch','Get-UcsPendingRebootObjectsForBatch','Test-DryRun') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

$UcsPendingAckWaitMinutes = 5
$Global:RunMode = 'LIVE'
$Global:BatchActionsSent = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:UcsHostMap = @{}
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Add-ManualAttentionHost { param($HostName,$Reason,$Detail,[switch]$ExcludeFromRun)
    $Global:ManualAttentionHosts.Add([pscustomobject]@{ Host=$HostName; Reason=$Reason; Detail=$Detail }) }
function Get-UcsSessionForTarget { param($UcsTarget) return 'session' }

# --- Fake clock, so a five minute wait is testable in milliseconds -------------------------------
$script:Now = [datetime]'2026-08-18T16:50:00'
function Get-Date { param($Format,$Date,$UFormat) if ($Format) { return $script:Now.ToString($Format) }; return $script:Now }
function Start-Sleep { param($Seconds,$Milliseconds) $script:Now = $script:Now.AddSeconds([double]$Seconds) }

# --- The domain -----------------------------------------------------------------------------
# $script:AckAppearsAfter is how many reads pass before UCSM raises the activity - the race the
# wait exists for. $script:AckClearsOnTrigger models a domain that accepts the acknowledgement.
$script:Hosts = @('esx01','esx02')
$script:AckAppearsAfter = 0
$script:AckReads = 0
$script:AckPresent = @{}
$script:Triggers = New-Object System.Collections.Generic.List[string]
$script:AckClearsOnTrigger = $true

function Reset-Domain {
    param([int]$AppearsAfter = 0,[bool]$ClearsOnTrigger = $true,[string[]]$NeverRaise = @())
    $script:AckReads = 0
    $script:AckAppearsAfter = $AppearsAfter
    $script:AckClearsOnTrigger = $ClearsOnTrigger
    $script:NeverRaise = $NeverRaise
    $script:AckPresent = @{}
    foreach ($h in $script:Hosts) { $script:AckPresent[$h] = $true }
    $script:Triggers = New-Object System.Collections.Generic.List[string]
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
    $Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
    $Global:BatchActionsSent = 0
    $script:Now = [datetime]'2026-08-18T16:50:00'
    $Global:UcsHostMap = @{}
    foreach ($h in $script:Hosts) {
        $Global:UcsHostMap[$h] = [pscustomobject]@{ UcsTarget='PD85000001SS003'; ServiceProfileDn="org-root/ls-$h" }
    }
}
$script:NeverRaise = @()

function Get-UcsLsmaintAck { param($Ucs,$ErrorAction)
    $script:AckReads++
    # One read covers the whole batch, so the appearance delay is counted in reads of the domain.
    if ($script:AckReads -le $script:AckAppearsAfter) { return @() }
    return @($script:Hosts |
        Where-Object { $script:AckPresent[$_] -and ($script:NeverRaise -notcontains $_) } |
        ForEach-Object { [pscustomobject]@{ Dn = "org-root/ls-$_/ack" } })
}
function Set-UcsLsmaintAck { param($Ucs,$LsmaintAck,$AdminState,[switch]$Force,$ErrorAction)
    $script:Triggers.Add("$($LsmaintAck.Dn)=$AdminState")
    if ($script:AckClearsOnTrigger) {
        foreach ($h in $script:Hosts) { if ($LsmaintAck.Dn -eq "org-root/ls-$h/ack") { $script:AckPresent[$h] = $false } }
    } }

Write-Host "`n=== A pending activity already raised is acknowledged straight away ===" -ForegroundColor Cyan
Reset-Domain
Invoke-UcsPendingAckForBatch -HostNames $script:Hosts -BatchNumber '1' 6>$null
Assert-Equal "both hosts were triggered" 2 $script:Triggers.Count
Assert-Equal "with trigger-immediate" "org-root/ls-esx01/ack=trigger-immediate" $script:Triggers[0]
Assert-Equal "and the actions are counted" 2 $Global:BatchActionsSent
Assert-Equal "both confirmed cleared" 2 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'Cleared' }).Count)
Assert-Equal "nothing left for manual rectification" 0 $Global:ManualAttentionHosts.Count

Write-Host "`n=== An activity UCSM has not raised yet is WAITED for, not skipped ===" -ForegroundColor Cyan
# The live symptom: the policy lands on the blade, the activity has not appeared yet, and a batch
# that asks once acknowledges nothing and leaves the blade staged.
Reset-Domain -AppearsAfter 3
Invoke-UcsPendingAckForBatch -HostNames $script:Hosts -BatchNumber '1' 6>$null
Assert-Equal "the domain was polled until it appeared" $true ($script:AckReads -gt 3)
Assert-Equal "and both hosts were then acknowledged" 2 $script:Triggers.Count
Assert-Equal "nothing was skipped" 0 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'NoneRaised' }).Count)

Write-Host "`n=== The wait is bounded, and gives up saying what it saw ===" -ForegroundColor Cyan
# A profile whose maintenance policy is immediate rather than user-ack reboots on its own and
# raises nothing, so this must not spin forever or fail the run.
Reset-Domain -NeverRaise @('esx02')
Invoke-UcsPendingAckForBatch -HostNames $script:Hosts -BatchNumber '1' 6>$null
Assert-Equal "the host that did raise one was acknowledged" 1 $script:Triggers.Count
Assert-Equal "and it was esx01" "org-root/ls-esx01/ack=trigger-immediate" $script:Triggers[0]
Assert-Equal "the one that never did is recorded, not retried forever" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'NoneRaised' -and $_.Host -eq 'esx02' }).Count)
Assert-Equal "the wait stopped at its ceiling" $true (($script:Now - [datetime]'2026-08-18T16:50:00').TotalMinutes -ge 5)
Assert-Equal "and it did not run away past it" $true (($script:Now - [datetime]'2026-08-18T16:50:00').TotalMinutes -lt 7)

Write-Host "`n=== An acknowledgement that does not take is caught, not assumed ===" -ForegroundColor Cyan
# The write returning is not proof the domain accepted it. Assumed, this leaves the blade staged
# with nothing on screen to say so - which is the complaint this whole path exists to answer.
Reset-Domain -ClearsOnTrigger $false
Invoke-UcsPendingAckForBatch -HostNames $script:Hosts -BatchNumber '1' 6>$null
Assert-Equal "the trigger was still sent" 2 $script:Triggers.Count
Assert-Equal "both are reported as still pending" 2 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'StillPending' }).Count)
Assert-Equal "and both are listed for manual rectification" 2 (@($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Reason -eq 'Pending activity not acknowledged' }).Count)
Assert-Equal "naming Pending Activities as where to clear it" $true ($Global:ManualAttentionHosts[0].Detail -match 'Pending Activities')

Write-Host "`n=== DRY RUN acknowledges nothing ===" -ForegroundColor Cyan
Reset-Domain
$Global:RunMode = 'DRYRUN'
Invoke-UcsPendingAckForBatch -HostNames $script:Hosts -BatchNumber '1' 6>$null
Assert-Equal "no trigger was sent" 0 $script:Triggers.Count
Assert-Equal "and no action was counted" 0 $Global:BatchActionsSent
$Global:RunMode = 'LIVE'

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
