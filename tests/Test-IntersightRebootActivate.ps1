<#
.SYNOPSIS
    Tests the Reboot Immediately to Activate acknowledgement and the check that it was accepted.

.DESCRIPTION
    Intersight stages a firmware change against the server profile and does not activate it until
    the server reboots. The acknowledgement that authorises that reboot is ProceedOnReboot on a
    PolicyScheduledAction - "ProceedOnReboot can be used to acknowledge server reboot while
    triggering deploy/activate", in the SDK's own words - sent through -ScheduledActions.

    Two earlier builds got this wrong in ways that both looked like success. One sent it as a
    PolicyActionParam named RebootImmediatelyToActivate - free-form strings, silently ignored. The
    other sent Action=Deploy on the scheduled action, which stages the firmware and waits for a
    restart that never comes. A HAR capture of the GUI settled it: Action=Activate. Hence the
    assertions here on how the request is composed, not just that one was sent.

    The deploy is also not trusted on the strength of the call returning - that is what caught the
    wrong mechanism. A profile still sitting in its staged state afterwards stops the run.

    Standalone - no Pester, no Intersight module, no appliance.

.EXAMPLE
    pwsh -File ./tests/Test-IntersightRebootActivate.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Confirm-IntersightDeployAcceptedForBatch','Get-IntersightProfileDeployState','Get-IntersightResultList','Get-IntersightServerProfileByName','Get-IntersightAssignedServerMoid','Get-IntersightRelationshipMoid') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$Global:IntersightActionableConfigStates = @('Pending-changes','Inconsistent','Out-of-sync','Not-deployed')
# Two seconds, not the production 180. Start-Sleep is stubbed here, so the wait loop spins at full
# speed and a realistic timeout would make the stuck cases take minutes of wall clock each.
$Global:IntersightDeployAcceptedTimeoutSeconds = 2
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
function Start-Sleep { param($Seconds,$Milliseconds) }

# The script has ONE implementation of "did the appliance pick the deploy up", and it is the batch
# one. The single-row wrapper that used to sit in front of it was never called by the script and
# has been removed, so the test asks the batch API directly through this local shim.
function Confirm-IntersightDeployAccepted { param($Row,$BatchNumber)
    $outcome = Confirm-IntersightDeployAcceptedForBatch -Rows @($Row) -BatchNumber $BatchNumber
    return [bool]$outcome[$Row.Host] }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# --- Stubs -------------------------------------------------------------------------------------
# The appliance's answer, read by read. A list lets a profile change state partway through, which
# is what a real deploy looks like.
$script:States = @()
$script:Reads = 0
$script:Paged = $false

function Get-IntersightServerProfile {
    param($Moid,$Filter,$ErrorAction)
    $index = [Math]::Min($script:Reads, $script:States.Count - 1)
    $script:Reads++
    $state = $script:States[$index]
    $profileObj = [pscustomobject]@{
        Name = 'sp-esx01'; Moid = 'moid-1'
        ConfigContext = [pscustomobject]@{ ConfigState = $state }
    }
    if ($script:Paged) { return [pscustomobject]@{ Results = @($profileObj) } }
    return $profileObj
}

$row = [pscustomobject]@{ Host = 'esx01.example'; ServerProfile = 'sp-esx01'; ProfileMoid = 'moid-1'; ConfigState = 'Pending-changes' }

Write-Host "`n=== A deploy the appliance picks up is accepted ===" -ForegroundColor Cyan
$script:States = @('Configuring'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
Assert-Equal "it reports accepted" $true (Confirm-IntersightDeployAccepted -Row $row -BatchNumber '1' 6>$null)
Assert-Equal "it is recorded as accepted" "Accepted" $Global:RunSummary[0].Result
Assert-Equal "and the state it moved to is named" $true ($Global:RunSummary[0].Details -match 'Configuring')

Write-Host "`n=== A profile that takes a moment to move is still accepted ===" -ForegroundColor Cyan
# The appliance does not always change state on the first read.
$script:States = @('Pending-changes','Pending-changes','Associated'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
[void](Confirm-IntersightDeployAccepted -Row $row -BatchNumber '1' 6>$null)
Assert-Equal "the later read is what counts" "Accepted" $Global:RunSummary[0].Result

Write-Host "`n=== A silently ignored acknowledgement stops the run ===" -ForegroundColor Cyan
# The dangerous case: the Deploy returns cleanly, the firmware stages, and nothing reboots. Left
# unchecked the run waits out its whole post-reboot window and then reports the batch complete.
$script:States = @('Pending-changes'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$accepted = Confirm-IntersightDeployAccepted -Row $row -BatchNumber '1' 6>$null
Assert-Equal "the deploy is reported as not accepted" $false $accepted
Assert-Equal "it is recorded as awaiting a reboot" "AwaitingReboot" $Global:RunSummary[0].Result
Assert-Equal "with the state it was stuck in" $true ($Global:RunSummary[0].Details -match 'Pending-changes')

Write-Host "`n=== Every actionable state is treated as 'not picked up' ===" -ForegroundColor Cyan
foreach ($stuck in @('Pending-changes','Inconsistent','Out-of-sync','Not-deployed')) {
    $script:States = @($stuck); $script:Reads = 0
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
    Assert-Equal "still $stuck is reported as not accepted" $false (Confirm-IntersightDeployAccepted -Row $row -BatchNumber '1' 6>$null)
}

Write-Host "`n=== A paged response is unwrapped, not read as a profile ===" -ForegroundColor Cyan
# A page object has no ConfigContext, so reading it directly would report the state as unknown and
# time out on a deploy that had in fact been accepted.
$script:Paged = $true
$script:States = @('Associated'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
[void](Confirm-IntersightDeployAccepted -Row $row -BatchNumber '1' 6>$null)
Assert-Equal "the profile inside the page is read" "Accepted" $Global:RunSummary[0].Result
$script:Paged = $false

Write-Host "`n=== The check can be turned off, but not by accident ===" -ForegroundColor Cyan
$Global:IntersightDeployAcceptedTimeoutSeconds = 0
$script:States = @('Pending-changes'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
[void](Confirm-IntersightDeployAccepted -Row $row -BatchNumber '1' 6>$null)
Assert-Equal "a zero timeout skips the check entirely" 0 $Global:RunSummary.Count
Assert-Equal "and reads nothing" 0 $script:Reads
$Global:IntersightDeployAcceptedTimeoutSeconds = 2

Write-Host "`n=== The acknowledgement is on by default ===" -ForegroundColor Cyan
# If this ever defaults to off, firmware stages across a whole cluster and nothing activates.
$scriptText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "reboot-immediately defaults to enabled" $true ($scriptText -match '\$Global:IntersightRebootImmediatelyToActivate\s*=\s*\$true')
# The mechanism, not just the intent. The previous build passed "reboot-immediately is enabled"
# while sending it in a form the appliance ignored.
Assert-Equal "and sent through -ScheduledActions" $true ($scriptText -match "\`$deployParams\['ScheduledActions'\]")
# Activate carries the action itself, so no top-level -Action rides alongside it - that was the
# old stage-then-activate shape, and it is exactly what the captured GUI request does not send.
Assert-Equal "the acknowledgement rides on Activate" $true ($scriptText -match "Initialize-IntersightPolicyScheduledAction -Action 'Activate' -ProceedOnReboot \`$true")
# The Deploy scheduled action still exists, but only on the fallback path: Activate is refused
# from Pending-changes, and the appliance requires Deploy first. It must never be the FIRST thing
# tried - that was the two-step form, and it is what made the firmware stage and never activate.
Assert-Equal "Activate is what the deploy reaches for first" $true ($scriptText -match "\`$scheduledAction = Initialize-IntersightPolicyScheduledAction -Action 'Activate'")
Assert-Equal "Deploy appears only as the fallback when Activate is refused" $true ($scriptText -match "gershwin_user_action_is_not_allowed")
Assert-Equal "-Action Deploy is only used when the reboot acknowledgement is turned off" $true ($scriptText -match "\`$deployParams\['Action'\] = 'Deploy'")
# The scheduled action carries the action. Sending -Action as well instructs the profile twice.
# The QUOTED form only: $Global:IntersightRebootImmediatelyToActivate is the switch that turns the
# acknowledgement on and legitimately contains the same words, as does the comment recording why
# the old mechanism was wrong.
Assert-Equal "no string literal is passed as an action parameter name" $true (-not ($scriptText -match "'RebootImmediatelyToActivate'"))
Assert-Equal "the acknowledgement is not built from an ActionParam" $true (-not ($scriptText -match 'Initialize-IntersightPolicyActionParam[^\r\n]*Reboot'))

Write-Host "`n=== The batch is confirmed in ONE window, not one per host ===" -ForegroundColor Cyan
# The live symptom: six hosts resolved and all six showed Pending-changes, then the deploys crawled
# out one at a time. Confirming inside the deploy loop meant host 2's deploy was not even SENT
# until host 1's confirmation window had closed - up to 180 seconds each, so six hosts serialised
# into six windows before the last blade had been touched.
$script:ConfirmReads = New-Object System.Collections.Generic.List[string]
$script:SettleAfter = @{}
$script:ConfirmRound = 0
function Get-IntersightServerProfile { param($Moid,$Filter,$Top,$Skip,$Expand,$ErrorAction)
    $name = if ($Moid) { "$Moid" } else { 'unknown' }
    $script:ConfirmReads.Add($name)
    # Each profile settles after its own number of rounds, so they finish out of order.
    $rounds = if ($script:SettleAfter.ContainsKey($name)) { $script:SettleAfter[$name] } else { 1 }
    $seen = @($script:ConfirmReads | Where-Object { $_ -eq $name }).Count
    $state = if ($seen -ge $rounds) { 'Associated' } else { 'Pending-changes' }
    return [pscustomobject]@{ Results = @([pscustomobject]@{ Name = $name; Moid = $name
        ConfigContext = [pscustomobject]@{ ConfigState = $state } }) } }

$Global:IntersightDeployAcceptedTimeoutSeconds = 180
$script:SettleAfter = @{ 'moid-a' = 3; 'moid-b' = 1; 'moid-c' = 2 }
$rows = @(
    [pscustomobject]@{ Host='esx-a'; ServerProfile='sp-a'; ProfileMoid='moid-a'; ConfigState='Pending-changes' }
    [pscustomobject]@{ Host='esx-b'; ServerProfile='sp-b'; ProfileMoid='moid-b'; ConfigState='Pending-changes' }
    [pscustomobject]@{ Host='esx-c'; ServerProfile='sp-c'; ProfileMoid='moid-c'; ConfigState='Pending-changes' }
)
$script:ConfirmReads.Clear()
$outcome = Confirm-IntersightDeployAcceptedForBatch -Rows $rows -BatchNumber '1' 6>$null
Assert-Equal "all three were confirmed" 3 (@($outcome.Keys).Count)
foreach ($h in @('esx-a','esx-b','esx-c')) { Assert-Equal "$h was accepted" $true $outcome[$h] }
# Every profile is read on the FIRST round - that is what proves they share one window rather than
# each waiting for the one before it.
$firstThree = @($script:ConfirmReads | Select-Object -First 3 | Sort-Object)
Assert-Equal "every profile is polled in the first round" "moid-a,moid-b,moid-c" ($firstThree -join ',')
# The fastest drops out first and is not polled again.
Assert-Equal "a profile that settled early stops being polled" 1 (@($script:ConfirmReads | Where-Object { $_ -eq 'moid-b' }).Count)

# One that never settles is reported as awaiting a reboot, and does not hold up the others.
$script:NeverSettles = @('moid-b')
function Get-IntersightServerProfile { param($Moid,$Filter,$Top,$Skip,$Expand,$ErrorAction)
    $name = "$Moid"
    $script:ConfirmReads.Add($name)
    $state = if ($script:NeverSettles -contains $name) { 'Pending-changes' } else { 'Associated' }
    return [pscustomobject]@{ Results = @([pscustomobject]@{ Name = $name; Moid = $name
        ConfigContext = [pscustomobject]@{ ConfigState = $state } }) } }
$script:ConfirmReads.Clear()
$Global:IntersightDeployAcceptedTimeoutSeconds = 20
$outcome2 = Confirm-IntersightDeployAcceptedForBatch -BatchNumber '1' -Rows @(
    [pscustomobject]@{ Host='esx-a'; ServerProfile='sp-a'; ProfileMoid='moid-a'; ConfigState='Pending-changes' },
    [pscustomobject]@{ Host='esx-b'; ServerProfile='sp-b'; ProfileMoid='moid-b'; ConfigState='Pending-changes' }) 6>$null
Assert-Equal "the one that settled is accepted" $true $outcome2['esx-a']
Assert-Equal "the one that did not is awaiting a reboot, not a failure" $false $outcome2['esx-b']
Assert-Equal "and the stuck one is recorded as awaiting a reboot" $true (@($Global:RunSummary | Where-Object { $_.Host -eq 'esx-b' -and $_.Result -eq 'AwaitingReboot' }).Count -ge 1)

# And the deploy loop must SEND everything before it confirms anything.
$deployText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the deploy loop collects rows rather than confirming inline" $true ($deployText -match '\[void\]\$sentRows\.Add\(\$row\)')
Assert-Equal "and confirms the whole batch after the loop" $true ($deployText -match 'Confirm-IntersightDeployAcceptedForBatch -Rows \$sentRows\.ToArray\(\)')
Assert-Equal "no per-row confirm remains inside the deploy loop" $true (-not ($deployText -match 'if \(-not \(Confirm-IntersightDeployAccepted -Row \$row'))

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
