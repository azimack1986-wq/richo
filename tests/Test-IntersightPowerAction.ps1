<#
.SYNOPSIS
    Tests the Intersight power action that activates staged firmware.

.DESCRIPTION
    Staging the firmware works; what was missing was the restart. This covers the restart, and the
    two ways it can quietly do nothing:

      - AdminPowerState 'Reboot' reboots the IMC, NOT the server. The SDK says so in as many words:
        "Reboot - Power state of IMC is rebooted." A run using it would report an action sent while
        the blade kept running and the firmware stayed staged. 'PowerCycle' is the server reset.
      - The wrong server. The power action goes to whatever server the PROFILE is assigned to, read
        back from the appliance, not to anything inferred from vCenter.

    The other property under test is that none of this ends the run. By the time it executes the
    firmware is already staged and the host is in Maintenance mode, so a failure here has to be
    reported and handed on - ending the run would leave the operator with less than they started
    with.

    Standalone - no Pester, no Intersight module, no appliance.

.EXAMPLE
    pwsh -File ./tests/Test-IntersightPowerAction.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-IntersightAssignedServerMoid','Invoke-IntersightServerPowerAction',
                                 'Get-IntersightRelationshipMoid','Write-IntersightRelationshipShape',
                                 'Invoke-IntersightActivationPowerCycle',
                                 'Get-IntersightFirmwareTaskState','Wait-IntersightActivationComplete',
                                 'Invoke-IntersightProfileActivate',
                                 'ConvertTo-IntersightWorkflowStatus','Resolve-IntersightRelationshipObject',
                                 'Get-IntersightProfileWorkflowActivity',
                                 'Get-IntersightProfileDeployState','Get-IntersightResultList',
                                 'Get-IntersightServerProfileByName',
                                 'Add-ManualAttentionHost',
                                 'Read-ChoiceExit','Read-PendingConsoleKey') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$Global:IntersightActionableConfigStates = @('Pending-changes','Inconsistent','Out-of-sync','Not-deployed')
$Global:IntersightActivationPowerAction = 'PowerCycle'
$Global:IntersightActivationWaitMinutes = 0
$Global:IntersightActivationHoldMinutes = 0
$Global:IntersightPollIntervalSeconds = 5
$Global:IntersightActivationLastPhase = ''
$Global:IntersightActivationHeldForBatch = $false
# The manual rectification register the activation records into. Real function, real globals - a
# host whose profile has no server must land on that list, not just fail quietly.
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:ExcludedFromRunHosts = @{}
$Global:CurrentClusterName = 'TestCluster'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-SafeExit { param($Message) throw "EXIT: $Message" }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
function Start-Sleep { param($Seconds,$Milliseconds) }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# --- Stubs -------------------------------------------------------------------------------------
$script:PowerCalls = New-Object System.Collections.Generic.List[string]
$script:PowerThrows = $false
$script:States = @('Pending-changes')
$script:Reads = 0
$script:ServerMoid = 'server-abc'

function Get-IntersightComputeServerSetting { param($Moid,$Filter,$ErrorAction)
    return [pscustomobject]@{ Moid = $Moid } }
# The firmware task Intersight reports for the server. 'skip' removes the cmdlet entirely, which is
# how an older module behaves and must fall back to letting the appliance answer.
$script:TaskStates = @('Completed')
$script:TaskReads = 0
# The GUI's query: firmware/Upgrades filtered to this server with Status eq 'IN_PROGRESS'. Rows
# means running; none means finished. The appliance decides, so the stub just returns rows or not.
function Get-IntersightFirmwareUpgrade { param($Filter,$ErrorAction)
    $index = [Math]::Min($script:TaskReads, $script:TaskStates.Count - 1)
    $script:TaskReads++
    if ($script:TaskStates[$index] -eq 'InProgress') { return [pscustomobject]@{ Moid = 'upgrade-1' } }
    return @() }
$script:PowerError = ""
$script:ActivateCalls = New-Object System.Collections.Generic.List[string]
$script:ActivateThrows = $false
function Initialize-IntersightPolicyScheduledAction { param($Action,$ProceedOnReboot)
    return [pscustomobject]@{ Action = $Action; ProceedOnReboot = [bool]$ProceedOnReboot } }
$script:ActivateThrowsFirst = 0
function Set-IntersightServerProfile { param($Moid,$Action,$ScheduledActions,$ErrorAction)
    foreach ($sa in @($ScheduledActions)) { $script:ActivateCalls.Add("${Moid}:$($sa.Action):ProceedOnReboot=$($sa.ProceedOnReboot)") }
    if ($script:ActivateThrows) { throw "Activate refused" }
    if ($script:ActivateThrowsFirst -gt 0) { $script:ActivateThrowsFirst--; throw "Activate refused" } }
function Set-IntersightComputeServerSetting { param($Moid,$AdminPowerState,$ErrorAction)
    $script:PowerCalls.Add("$Moid=$AdminPowerState")
    if ($script:PowerThrows) { throw $(if ($script:PowerError) { $script:PowerError } else { "server is not reachable" }) } }
function Get-IntersightServerProfile { param($Moid,$Filter,$Expand,$ErrorAction)
    $index = [Math]::Min($script:Reads, $script:States.Count - 1)
    $script:Reads++
    return [pscustomobject]@{
        Name = 'sp-esx01'; Moid = 'moid-1'
        AssignedServer = if ($script:ServerMoid) { [pscustomobject]@{ Moid = $script:ServerMoid } } else { $null }
        ConfigContext = [pscustomobject]@{ ConfigState = $script:States[$index] }
    } }

$row = [pscustomobject]@{ Host='esx01.example'; ServerProfile='sp-esx01'; ProfileMoid='moid-1'; ConfigState='Pending-changes'; ServerProfileObj=$null }

Write-Host "`n=== The Moid is found whatever shape the relationship arrived in ===" -ForegroundColor Cyan
# This is the live defect. AssignedServer was present on every profile and .Moid read as empty,
# because relationships in this SDK are generated oneOf wrappers, not plain objects - the same
# class of problem as reading a paged response instead of the object inside it.
Assert-Equal "a plain object" "m1" (Get-IntersightRelationshipMoid -Relationship ([pscustomobject]@{ Moid = 'm1' }))
Assert-Equal "a wrapper with ActualInstance" "m2" (Get-IntersightRelationshipMoid -Relationship ([pscustomobject]@{ Moid = ''; ActualInstance = [pscustomobject]@{ Moid = 'm2' } }))
Assert-Equal "a doubly-wrapped instance" "m3" (Get-IntersightRelationshipMoid -Relationship ([pscustomobject]@{ ActualInstance = [pscustomobject]@{ ActualInstance = [pscustomobject]@{ Moid = 'm3' } } }))
Assert-Equal "an unmapped type in AdditionalProperties" "m4" (Get-IntersightRelationshipMoid -Relationship ([pscustomobject]@{ AdditionalProperties = @{ Moid = 'm4' } }))
Assert-Equal "a bare Moid string" "67ca67ad617675301f7bb5a1" (Get-IntersightRelationshipMoid -Relationship '67ca67ad617675301f7bb5a1')
# Never a guess: a string that is not a Moid, and an object with nothing on it, both yield nothing.
Assert-Equal "an arbitrary string is not treated as a Moid" "" (Get-IntersightRelationshipMoid -Relationship 'siepd85vcp0007')
Assert-Equal "an empty relationship yields nothing" "" (Get-IntersightRelationshipMoid -Relationship ([pscustomobject]@{ Name = 'x' }))
Assert-Equal "null yields nothing" "" (Get-IntersightRelationshipMoid -Relationship $null)

Write-Host "`n=== The server comes from the profile ===" -ForegroundColor Cyan
Assert-Equal "AssignedServer is used" "server-abc" (Get-IntersightAssignedServerMoid -ServerProfile ([pscustomobject]@{ AssignedServer = [pscustomobject]@{ Moid = 'server-abc' } }) -Quiet)
Assert-Equal "AssociatedServer is the fallback" "server-xyz" (Get-IntersightAssignedServerMoid -ServerProfile ([pscustomobject]@{ AssociatedServer = [pscustomobject]@{ Moid = 'server-xyz' } }) -Quiet)
Assert-Equal "a wrapped AssignedServer is still read" "server-wrapped" (Get-IntersightAssignedServerMoid -ServerProfile ([pscustomobject]@{ AssignedServer = [pscustomobject]@{ ActualInstance = [pscustomobject]@{ Moid = 'server-wrapped' } } }) -Quiet)
Assert-Equal "a profile with neither reports nothing, rather than guessing" "" (Get-IntersightAssignedServerMoid -ServerProfile ([pscustomobject]@{ Name = 'sp' }) -Quiet)

Write-Host "`n=== An unreadable relationship is re-read with the server expanded ===" -ForegroundColor Cyan
# An unexpanded relationship can carry nothing useful at all, which is why the GUI expands it.
$script:ExpandCalls = New-Object System.Collections.Generic.List[string]
function Get-IntersightServerProfile { param($Moid,$Filter,$Expand,$ErrorAction)
    if ($Expand) {
        $script:ExpandCalls.Add([string]$Expand)
        return [pscustomobject]@{ Name='sp-esx01'; Moid='moid-1'; AssignedServer = [pscustomobject]@{ Moid = 'server-expanded' } }
    }
    return [pscustomobject]@{ Name='sp-esx01'; Moid='moid-1'; AssignedServer = [pscustomobject]@{ Name = 'blade' } } }
$flat = [pscustomobject]@{ Name='sp-esx01'; AssignedServer = [pscustomobject]@{ Name = 'blade' } }
Assert-Equal "the expanded read supplies the Moid" "server-expanded" (Get-IntersightAssignedServerMoid -ServerProfile $flat -ProfileMoid 'moid-1' -Quiet)
Assert-Equal "and it asked for AssignedServer" "AssignedServer" $script:ExpandCalls[0]

# Restore the profile stub the rest of the suite drives.
function Get-IntersightServerProfile { param($Moid,$Filter,$Expand,$ErrorAction)
    $index = [Math]::Min($script:Reads, $script:States.Count - 1)
    $script:Reads++
    return [pscustomobject]@{
        Name = 'sp-esx01'; Moid = 'moid-1'
        AssignedServer = if ($script:ServerMoid) { [pscustomobject]@{ Moid = $script:ServerMoid } } else { $null }
        ConfigContext = [pscustomobject]@{ ConfigState = $script:States[$index] }
    } }

Write-Host "`n=== PowerCycle resets the server ===" -ForegroundColor Cyan
# 'Reboot' would restart the IMC and leave the blade running - see the notes above.
$script:PowerCalls.Clear()
Assert-Equal "the action is sent" "Sent" (Invoke-IntersightServerPowerAction -ServerMoid 'server-abc' -PowerState 'PowerCycle' 6>$null)
Assert-Equal "to the server's own setting Moid" "server-abc=PowerCycle" $script:PowerCalls[0]

Write-Host "`n=== A declined power action does not end the run ===" -ForegroundColor Cyan
$script:PowerThrows = $true
$script:PowerCalls.Clear()
$threw = $false
$result = $null
try { $result = Invoke-IntersightServerPowerAction -ServerMoid 'server-abc' -PowerState 'PowerCycle' 6>$null } catch { $threw = $true }
Assert-Equal "it does not throw" $false $threw
Assert-Equal "it reports Failed" "Failed" $result

Write-Host "`n=== An upgrade already running is a 'not yet', not a failure ===" -ForegroundColor Cyan
# The appliance refuses to power-cycle underneath the upgrade this deploy started. That is correct
# behaviour, and it clears when the upgrade does - so it must be retried, not given up on.
$script:PowerError = 'Error calling UpdateComputeServerSetting: {"code":"InvalidRequest","message":"Cannot perform power action when a firmware upgrade is in progress.","messageId":"action_not_allowed_firmware_upgrade_in_progress"}'
Assert-Equal "it is told apart from a real failure" "UpgradeInProgress" (Invoke-IntersightServerPowerAction -ServerMoid 'server-abc' -PowerState 'PowerCycle' 6>$null)
$script:PowerError = ""
$script:PowerThrows = $false

function Read-Host { param($Prompt) return 'CONTINUE' }
function Read-Host { param($Prompt)
    $script:PromptCount++
    if ($script:PromptCount -gt 20) { throw "the activation loop is not settling" }
    return 'CONTINUE' }

Write-Host "`n=== The Activate scheduled action is what the GUI sends ===" -ForegroundColor Cyan
# Captured from the GUI: POST /api/v1/server/Profiles/<moid> with a 67-byte body of
# {"ScheduledActions":[{"Action":"Activate","ProceedOnReboot":true}]} - Activate, not Deploy.
$script:ActivateCalls.Clear()
Assert-Equal "Activate is sent" "Sent" (Invoke-IntersightProfileActivate -ProfileMoid 'moid-1' 6>$null)
Assert-Equal "with Action=Activate and ProceedOnReboot" "moid-1:Activate:ProceedOnReboot=True" $script:ActivateCalls[0]
$scriptTextEarly = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the scheduled action for activation says Activate" $true ($scriptTextEarly -match "Initialize-IntersightPolicyScheduledAction -Action 'Activate' -ProceedOnReboot \`$true")

Write-Host "`n=== Firmware task finished: the blade is activated ===" -ForegroundColor Cyan
$script:TaskStates = @('Completed'); $script:TaskReads = 0
$script:States = @('Pending-changes'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:PowerCalls.Clear(); $script:ActivateCalls.Clear()
$Global:IntersightActivationHeldForBatch = $false
Invoke-IntersightActivationPowerCycle -Row $row -BatchNumber '1' 6>$null
Assert-Equal "Activate was sent, not a power action" $true ($script:ActivateCalls.Count -ge 1 -and $script:PowerCalls.Count -eq 0)
Assert-Equal "and it held for the activation" $true (@('PowerCycled','Activated') -contains (@($Global:RunSummary | Where-Object { $_.Action -eq 'Confirm activation' })[0].Result))
Assert-Equal "the batch is told not to hold again on top" $true $Global:IntersightActivationHeldForBatch

Write-Host "`n=== Firmware task still running: Activate is sent anyway, because it IS the acknowledgement ===" -ForegroundColor Cyan
# The deadlock this replaced. The firmware.Upgrade sits at IN_PROGRESS precisely BECAUSE it is
# waiting for the reboot acknowledgement, so gating Activate on the upgrade finishing meant it
# could never finish. A live run looped on "1 firmware upgrade(s) IN_PROGRESS" on every check
# while the deploy had in fact completed and was waiting to be acknowledged.
$script:TaskStates = @('InProgress'); $script:TaskReads = 0
$script:States = @('Pending-changes'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:PowerCalls.Clear(); $script:ActivateCalls.Clear()
$Global:IntersightActivationHeldForBatch = $false
Invoke-IntersightActivationPowerCycle -Row $row -BatchNumber '1' 6>$null
Assert-Equal "Activate goes out while the upgrade is in progress" $true ($script:ActivateCalls.Count -ge 1)
Assert-Equal "it is the GUI's Activate, not a Deploy" "moid-1:Activate:ProceedOnReboot=True" $script:ActivateCalls[0]
# A power action genuinely is refused mid-upgrade, so it is not worth attempting there.
Assert-Equal "no power cycle is attempted underneath a running upgrade" 0 $script:PowerCalls.Count
Assert-Equal "and it holds for the activation instead of looping" $true (@('PowerCycled','Activated') -contains (@($Global:RunSummary | Where-Object { $_.Action -eq 'Confirm activation' })[0].Result))
Assert-Equal "the batch is told not to hold again on top" $true $Global:IntersightActivationHeldForBatch

Write-Host "`n=== Activate refused mid-upgrade: no power cycle, the operator is asked ===" -ForegroundColor Cyan
# Refused AND an upgrade running is the only case that reaches the prompt. The power-cycle fallback
# stays holstered - the appliance would decline it for the same reason.
$script:ActivateThrows = $true
$script:TaskStates = @('InProgress'); $script:TaskReads = 0
$script:States = @('Pending-changes'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:PowerCalls.Clear(); $script:ActivateCalls.Clear()
$Global:IntersightActivationHeldForBatch = $false
Invoke-IntersightActivationPowerCycle -Row $row -BatchNumber '1' 6>$null
Assert-Equal "nothing was power-cycled underneath the upgrade" 0 $script:PowerCalls.Count
Assert-Equal "and it is recorded as still staged" "StillStaged" (@($Global:RunSummary | Where-Object { $_.Action -eq 'Confirm activation' })[0].Result)
Assert-Equal "the batch is not told it held" $false $Global:IntersightActivationHeldForBatch
$script:ActivateThrows = $false

Write-Host "`n=== RETRY sends Activate again, and settles once it is accepted ===" -ForegroundColor Cyan
# The retry re-sends Activate against Intersight - not a vCenter check, which is the whole point.
$script:ActivateThrowsFirst = 2
$script:TaskStates = @('InProgress'); $script:TaskReads = 0
$script:States = @('Pending-changes'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:PowerCalls.Clear(); $script:ActivateCalls.Clear()
$Global:IntersightActivationHeldForBatch = $false
$script:Answers = @('RETRY','RETRY','CONTINUE'); $script:AnswerIndex = 0
function Read-Host { param($Prompt)
    $script:PromptCount++
    if ($script:PromptCount -gt 20) { throw "the activation loop is not settling" }
    $answer = $script:Answers[[Math]::Min($script:AnswerIndex, $script:Answers.Count - 1)]
    $script:AnswerIndex++
    return $answer }
Invoke-IntersightActivationPowerCycle -Row $row -BatchNumber '1' 6>$null
Assert-Equal "Activate was re-sent on each retry" 3 $script:ActivateCalls.Count
Assert-Equal "and the activation is recorded once it lands" $true (@('PowerCycled','Activated') -contains (@($Global:RunSummary | Where-Object { $_.Action -eq 'Confirm activation' })[0].Result))
$script:ActivateThrowsFirst = 0
function Read-Host { param($Prompt)
    $script:PromptCount++
    if ($script:PromptCount -gt 20) { throw "the activation loop is not settling" }
    return 'CONTINUE' }

Write-Host "`n=== A profile that settled on its own needs no power cycle ===" -ForegroundColor Cyan
$script:TaskStates = @('Completed'); $script:TaskReads = 0
$script:States = @('Associated'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:PowerCalls.Clear(); $script:ActivateCalls.Clear()
Invoke-IntersightActivationPowerCycle -Row $row -BatchNumber '1' 6>$null
Assert-Equal "nothing was activated or power-cycled" $true ($script:PowerCalls.Count -eq 0)
Assert-Equal "and it is recorded as activated" "Activated" (@($Global:RunSummary | Where-Object { $_.Action -eq 'Confirm activation' })[0].Result)

Write-Host "`n=== The firmware task check is the GUI's own query ===" -ForegroundColor Cyan
# firmware/Upgrades with Status eq 'IN_PROGRESS' for the server. One call, and the appliance
# decides - no free-text state string is interpreted here.
$script:TaskStates = @('InProgress'); $script:TaskReads = 0
Assert-Equal "an upgrade in progress reads as Running" "Running" (Get-IntersightFirmwareTaskState -ServerMoid 'server-abc' 6>$null)
$script:TaskStates = @('Completed'); $script:TaskReads = 0
Assert-Equal "no rows reads as Finished" "Finished" (Get-IntersightFirmwareTaskState -ServerMoid 'server-abc' 6>$null)
$scriptTextTask = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "it filters on Status eq 'IN_PROGRESS'" $true ($scriptTextTask -match "Status eq 'IN_PROGRESS'")
Assert-Equal "and queries firmware/Upgrades, not UpgradeStatuses" $true ($scriptTextTask -match 'Get-IntersightFirmwareUpgrade -Filter')

Write-Host "`n=== A profile with no assigned server is reported, not guessed at ===" -ForegroundColor Cyan
$script:ServerMoid = ''
$script:States = @('Pending-changes'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:PowerCalls.Clear()
$threw = $false
try { Invoke-IntersightActivationPowerCycle -Row $row -BatchNumber '1' 6>$null } catch { $threw = $true }
Assert-Equal "the run does not end" $false $threw
Assert-Equal "no power action was sent to anything" 0 $script:PowerCalls.Count
Assert-Equal "and it says why" "NoServer" (@($Global:RunSummary | Where-Object { $_.Action -eq 'Power action' })[0].Result)
$script:ServerMoid = 'server-abc'

Write-Host "`n=== The hold polls Intersight and returns as soon as the task completes ===" -ForegroundColor Cyan
# A fixed sleep would hold the full window even when the blade is back in five minutes.
$Global:IntersightActivationHoldMinutes = 1
$script:States = @('Associated'); $script:Reads = 0
$script:TaskStates = @('Completed'); $script:TaskReads = 0
Assert-Equal "it returns complete rather than waiting out the window" $true (Wait-IntersightActivationComplete -ProfileMoid 'moid-1' -ServerMoid 'server-abc' -Label 'test' -MaxMinutes 1 6>$null)
$script:States = @('Pending-changes'); $script:Reads = 0
$script:TaskStates = @('InProgress'); $script:TaskReads = 0
Assert-Equal "a window that elapses is not a failure, just not complete" $false (Wait-IntersightActivationComplete -ProfileMoid 'moid-1' -ServerMoid 'server-abc' -Label 'test' -MaxMinutes 0 6>$null)
$Global:IntersightActivationHoldMinutes = 0

Write-Host "`n=== Nothing in the activation path touches vCenter ===" -ForegroundColor Cyan
# The whole point of this stage is that it is Intersight-only. The retry re-checks the Intersight
# firmware task for the profile's server - not the host's state in vCenter - and no vCenter action
# happens until the activation has finished and the function has returned.
$activationAst = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Invoke-IntersightActivationPowerCycle','Get-IntersightFirmwareTaskState','Invoke-IntersightServerPowerAction','Wait-IntersightActivationComplete','Invoke-IntersightProfileActivate') }
$activationText = ($activationAst | ForEach-Object { $_.Extent.Text }) -join "`n"
foreach ($viCmdlet in @('Get-VMHost','Set-VMHost','Restart-VMHost','Get-Cluster','Get-Datastore','Move-VM','Test-VMHostProfileCompliance','Get-VMHostProfile')) {
    Assert-Equal "the activation never calls $viCmdlet" $true (-not ($activationText -match "\b$([regex]::Escape($viCmdlet))\b"))
}
Assert-Equal "it reads the Intersight firmware task instead" $true ($activationText -match 'Get-IntersightFirmwareUpgrade')

Write-Host "`n=== The default is PowerCycle, not Reboot ===" -ForegroundColor Cyan
$scriptText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the configured action resets the server" $true ($scriptText -match "\`$Global:IntersightActivationPowerAction = 'PowerCycle'")
Assert-Equal "the stand-off is 60 minutes" $true ($scriptText -match '\$Global:IntersightActivationWaitMinutes = 60')
Assert-Equal "and the post-activation hold is 60 minutes" $true ($scriptText -match '\$Global:IntersightActivationHoldMinutes = 60')
# Raised from 40 at the operator's direction, to cover the firmware activity itself.
Assert-Equal "and the post-reboot reconnect wait matches at 60" $true ($scriptText -match '\$FirmwareReconnectInitialWaitMinutes = 60')
Assert-Equal "'Reboot' is called out as IMC-only" $true ($scriptText -match 'reboots the IMC, NOT the server')

Write-Host "`n=== Workflow status: both of Intersight's enum families are read ===" -ForegroundColor Cyan
# workflow.WorkflowInfo carries Status (RUNNING, WAITING, COMPLETED, TIME_OUT, FAILED) on some
# releases and WorkflowStatus (NotStarted, InProgress, Waiting, Completed, Failed, Terminated,
# Canceled, Paused) on others. Reading only one family is how a finished workflow reads as never
# having started.
foreach ($pair in @(@('RUNNING','Running'), @('WAITING','Running'), @('COMPLETED','Completed'),
                    @('TIME_OUT','Failed'), @('FAILED','Failed'),
                    @('NotStarted','Running'), @('InProgress','Running'), @('Paused','Running'),
                    @('Terminated','Failed'), @('Canceled','Failed'))) {
    Assert-Equal "'$($pair[0])' normalises to $($pair[1])" $pair[1] (ConvertTo-IntersightWorkflowStatus -Value $pair[0])
}
# WAITING is the state this run creates on purpose - a workflow waiting on the reboot
# acknowledgement. Calling it a failure would abandon a healthy activation.
Assert-Equal "WAITING is never read as a failure" $true ((ConvertTo-IntersightWorkflowStatus -Value 'WAITING') -ne 'Failed')
Assert-Equal "an unrecognised status is Unknown, never a pass" "Unknown" (ConvertTo-IntersightWorkflowStatus -Value 'Wibble')
Assert-Equal "an empty status is Unknown" "Unknown" (ConvertTo-IntersightWorkflowStatus -Value '')

Write-Host "`n=== RunningWorkflows is read through the relationship wrapper ===" -ForegroundColor Cyan
# Same generated oneOf wrapper that hid the Moids hides the whole WorkflowInfo behind
# ActualInstance. Reading .Status off the wrapper returns nothing, which is indistinguishable
# from "no workflow is running" - and that is the failure mode this guards.
$script:Workflows = @()
$script:ExpandSupported = $true
$script:HasWorkflowProperty = $true
function Get-IntersightServerProfile {
    param($Moid,$Filter,$Expand,$ErrorAction)
    $index = [Math]::Min($script:Reads, $script:States.Count - 1)
    $script:Reads++
    $obj = [pscustomobject]@{
        Name = 'sp-esx01'; Moid = 'moid-1'
        AssignedServer = [pscustomobject]@{ Moid = $script:ServerMoid }
        ConfigContext = [pscustomobject]@{ ConfigState = $script:States[$index] }
    }
    if ($Expand -and -not $script:ExpandSupported) { throw "\$expand is not supported on this release" }
    if ($script:HasWorkflowProperty) {
        $value = if ($Expand) { $script:Workflows } else { @($script:Workflows | ForEach-Object { [pscustomobject]@{ Moid = 'wf-1' } }) }
        $obj | Add-Member -NotePropertyName RunningWorkflows -NotePropertyValue $value -Force
    }
    return $obj
}
function New-Wf { param($Status,$WorkflowStatus,$Name,$Progress)
    $inner = [pscustomobject]@{ Name = $Name; Progress = $Progress }
    if ($null -ne $Status) { $inner | Add-Member -NotePropertyName Status -NotePropertyValue $Status -Force }
    if ($null -ne $WorkflowStatus) { $inner | Add-Member -NotePropertyName WorkflowStatus -NotePropertyValue $WorkflowStatus -Force }
    return [pscustomobject]@{ ActualInstance = $inner } }

$script:Workflows = @((New-Wf -Status 'RUNNING' -Name 'Deploy Server Profile' -Progress 45))
$a = Get-IntersightProfileWorkflowActivity -ProfileMoid 'moid-1'
Assert-Equal "a running workflow is seen through the wrapper" $true $a.Running
Assert-Equal "its name is read" "Deploy Server Profile" $a.Name
Assert-Equal "and its progress" 45 $a.Progress

$script:Workflows = @((New-Wf -WorkflowStatus 'InProgress' -Name 'Activate' -Progress 10))
Assert-Equal "the WorkflowStatus family is read too" $true (Get-IntersightProfileWorkflowActivity -ProfileMoid 'moid-1').Running

$script:Workflows = @()
$b = Get-IntersightProfileWorkflowActivity -ProfileMoid 'moid-1'
Assert-Equal "an empty RunningWorkflows means nothing is running" $false $b.Running
Assert-Equal "and that is a known answer, not a guess" $true $b.Known
Assert-Equal "reported as Completed" "Completed" $b.Status

$script:Workflows = @((New-Wf -Status 'FAILED' -Name 'Deploy Server Profile' -Progress 60))
$c = Get-IntersightProfileWorkflowActivity -ProfileMoid 'moid-1'
Assert-Equal "a failed workflow is surfaced as Failed" $true $c.Failed
Assert-Equal "not as still-running" $false $c.Running

# An expanded entry whose status will not read is still IN the RunningWorkflows list, so it is
# running. Reading it as Unknown and moving on would end the wait early.
$script:Workflows = @([pscustomobject]@{ ActualInstance = [pscustomobject]@{ Name = 'Mystery' } })
Assert-Equal "an unreadable status on a listed workflow still counts as running" $true (Get-IntersightProfileWorkflowActivity -ProfileMoid 'moid-1').Running

# Older appliance: no $expand. The MoRefs carry no status, but their presence is the answer.
$script:ExpandSupported = $false
$script:Workflows = @((New-Wf -Status 'RUNNING' -Name 'Deploy' -Progress 5))
$d = Get-IntersightProfileWorkflowActivity -ProfileMoid 'moid-1'
Assert-Equal "without expand, a non-empty RunningWorkflows still means running" $true $d.Running
Assert-Equal "and it says the status was not expanded" $true ($d.Detail -match 'not expanded')
$script:ExpandSupported = $true

# A profile that does not report the property at all is UNKNOWN - never "nothing is running".
$script:HasWorkflowProperty = $false
$e = Get-IntersightProfileWorkflowActivity -ProfileMoid 'moid-1'
Assert-Equal "a profile with no RunningWorkflows property is Unknown, not idle" $false $e.Known
Assert-Equal "and is not reported as running either" $false $e.Running
$script:HasWorkflowProperty = $true

Assert-Equal "no profile Moid yields a known-nothing result" $false (Get-IntersightProfileWorkflowActivity -ProfileMoid '').Known

Write-Host "`n=== The wait follows the work, and the timer is only a ceiling ===" -ForegroundColor Cyan
# A fake clock so the ceiling cases do not sit here for real minutes. Start-Sleep advances it.
$script:FakeNow = [datetime]'2026-08-12T00:00:00'
function Get-Date { param($Format,$Date,$UFormat) if ($Format) { return $script:FakeNow.ToString($Format) }; return $script:FakeNow }
function Start-Sleep { param($Seconds,$Milliseconds) $script:FakeNow = $script:FakeNow.AddSeconds([double]$Seconds) }
$Global:IntersightPollIntervalSeconds = 30

# THE KEY NEW BEHAVIOUR. The firmware task is finished and the profile has settled - the old logic
# would have called that complete. A workflow still running means it is not.
$script:Workflows = @((New-Wf -Status 'RUNNING' -Name 'Deploy Server Profile' -Progress 70))
$script:States = @('Associated'); $script:Reads = 0
$script:TaskStates = @('Completed'); $script:TaskReads = 0
Assert-Equal "a running workflow keeps the wait alive even when everything else is clear" $false (Wait-IntersightActivationComplete -ProfileMoid 'moid-1' -ServerMoid 'server-abc' -Label 'test' -MaxMinutes 2 6>$null)
Assert-Equal "and the phase names the workflow, not a countdown" $true ($Global:IntersightActivationLastPhase -match "Deploy Server Profile")

# A failed workflow stops the wait at once - there is nothing to be gained from holding an hour
# for something the engine has given up on.
$script:Workflows = @((New-Wf -Status 'FAILED' -Name 'Deploy Server Profile' -Progress 70))
$script:FakeNow = [datetime]'2026-08-12T00:00:00'
$before = $script:FakeNow
Assert-Equal "a failed workflow ends the wait immediately" $false (Wait-IntersightActivationComplete -ProfileMoid 'moid-1' -ServerMoid 'server-abc' -Label 'test' -MaxMinutes 60 6>$null)
Assert-Equal "without burning the ceiling" $true (($script:FakeNow - $before).TotalMinutes -lt 2)
Assert-Equal "and it says which workflow failed" $true ($Global:IntersightActivationLastPhase -match 'Deploy Server Profile')

# All three clear: complete, straight away, however large the ceiling.
$script:Workflows = @()
$script:States = @('Associated'); $script:Reads = 0
$script:TaskStates = @('Completed'); $script:TaskReads = 0
$script:FakeNow = [datetime]'2026-08-12T00:00:00'
$before = $script:FakeNow
Assert-Equal "all three signals clear means complete" $true (Wait-IntersightActivationComplete -ProfileMoid 'moid-1' -ServerMoid 'server-abc' -Label 'test' -MaxMinutes 60 6>$null)
Assert-Equal "and it returns without waiting out the ceiling" $true (($script:FakeNow - $before).TotalMinutes -lt 2)

# The firmware upgrade alone is enough to keep waiting.
$script:Workflows = @()
$script:States = @('Associated'); $script:Reads = 0
$script:TaskStates = @('InProgress'); $script:TaskReads = 0
Assert-Equal "an upgrade in progress keeps the wait alive" $false (Wait-IntersightActivationComplete -ProfileMoid 'moid-1' -ServerMoid 'server-abc' -Label 'test' -MaxMinutes 2 6>$null)
Assert-Equal "and the phase says so" $true ($Global:IntersightActivationLastPhase -match 'firmware upgrade')

# So is the profile still being staged.
$script:TaskStates = @('Completed'); $script:TaskReads = 0
$script:States = @('Pending-changes'); $script:Reads = 0
Assert-Equal "a profile still pending keeps the wait alive" $false (Wait-IntersightActivationComplete -ProfileMoid 'moid-1' -ServerMoid 'server-abc' -Label 'test' -MaxMinutes 2 6>$null)
Assert-Equal "and the phase names the ConfigState" $true ($Global:IntersightActivationLastPhase -match 'Pending-changes')

Write-Host "`n=== The settings are ceilings and a poll interval, not a fixed sleep ===" -ForegroundColor Cyan
$pollText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "a poll interval is configured" $true ($pollText -match '\$Global:IntersightPollIntervalSeconds = \d+')
Assert-Equal "the timers are documented as ceilings" $true ($pollText -match 'CEILINGS, NOT TIMERS')
# The fixed stand-off is gone. Its whole purpose was to sleep instead of asking.
Assert-Equal "the fixed stand-off function no longer exists" $true (-not ($pollText -match 'function Wait-IntersightActivationCheckIn'))
Assert-Equal "the wait reads the workflow engine" $true ($pollText -match 'Get-IntersightProfileWorkflowActivity')
Assert-Equal "through the profile's RunningWorkflows" $true ($pollText -match "Expand 'RunningWorkflows'")

Write-Host "`n=== A duplicated profile name is not silently guessed at ===" -ForegroundColor Cyan
# THE LIVE FAULT. A profile name is not unique in Intersight - the same name exists across
# organizations, and decommissioned or template-derived copies sit alongside the live one. This
# lookup used to take Select-Object -First 1, so a run could deploy against the copy with no server
# on it. The appliance then answered "the server is disconnected", and BOTH Intersight and vCenter
# showed the real blade perfectly healthy - because the healthy blade was on the other profile.
$IntersightCsvPath = 'C:\fixtures\intersight.csv'
$script:NamedProfiles = @()
function Get-IntersightServerProfile { param($Moid,$Filter,$Expand,$Top,$Skip,$ErrorAction)
    return [pscustomobject]@{ Results = $script:NamedProfiles } }
function New-Profile { param([string]$Moid,[string]$ServerMoid)
    $p = [pscustomobject]@{ Name = 'siepd24vcp0205'; Moid = $Moid }
    if ($ServerMoid) { $p | Add-Member -NotePropertyName AssignedServer -NotePropertyValue ([pscustomobject]@{ ActualInstance = [pscustomobject]@{ Moid = $ServerMoid } }) -Force }
    return $p }

$script:NamedProfiles = @()
Assert-Equal "no match returns nothing" $true ($null -eq (Get-IntersightServerProfileByName -Name 'siepd24vcp0205' 6>$null))

$script:NamedProfiles = @((New-Profile -Moid 'moid-live' -ServerMoid 'server-1'))
Assert-Equal "a single match is used as-is" "moid-live" (Get-IntersightServerProfileByName -Name 'siepd24vcp0205' 6>$null).Moid

# The live shape: one real profile on a blade, one leftover with nothing on it.
$script:NamedProfiles = @((New-Profile -Moid 'moid-stale'), (New-Profile -Moid 'moid-live' -ServerMoid 'server-1'))
Assert-Equal "with duplicates, the one with a server assigned wins" "moid-live" (Get-IntersightServerProfileByName -Name 'siepd24vcp0205' 6>$null).Moid
# Order must not decide it - the appliance does not promise one.
$script:NamedProfiles = @((New-Profile -Moid 'moid-live' -ServerMoid 'server-1'), (New-Profile -Moid 'moid-stale'))
Assert-Equal "and order does not change the answer" "moid-live" (Get-IntersightServerProfileByName -Name 'siepd24vcp0205' 6>$null).Moid

# Two live candidates is a genuine ambiguity. Guessing here is how the wrong blade gets rebooted.
$script:NamedProfiles = @((New-Profile -Moid 'moid-a' -ServerMoid 'server-1'), (New-Profile -Moid 'moid-b' -ServerMoid 'server-2'))
Assert-Equal "two assigned profiles is refused, not guessed" $true ($null -eq (Get-IntersightServerProfileByName -Name 'siepd24vcp0205' 6>$null))

# Neither assigned: also refused. Picking one would reproduce the original fault exactly.
$script:NamedProfiles = @((New-Profile -Moid 'moid-a'), (New-Profile -Moid 'moid-b'))
Assert-Equal "no assigned profile among duplicates is refused too" $true ($null -eq (Get-IntersightServerProfileByName -Name 'siepd24vcp0205' 6>$null))

$lookupText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the lookup no longer takes the first of several" $true (-not ($lookupText -match "Get-IntersightResultList -Response \`$page \| Select-Object -First 1"))
# Without the Moid on screen, resolving to the wrong profile of the right name is invisible.
Assert-Equal "the resolved Moid is printed, not just the name" $true ($lookupText -match "resolved to Intersight server profile '\`$\(\`$sp\.Name\)' \(Moid \`$\(\`$sp\.Moid\)\)")

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
