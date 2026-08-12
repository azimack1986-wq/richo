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
                                 'Invoke-IntersightActivationPowerCycle','Wait-IntersightActivationCheckIn',
                                 'Get-IntersightProfileDeployState','Get-IntersightResultList','Read-PendingConsoleKey') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$Global:IntersightActionableConfigStates = @('Pending-changes','Inconsistent','Out-of-sync','Not-deployed')
$Global:IntersightActivationPowerAction = 'PowerCycle'
$Global:IntersightActivationWaitMinutes = 0
$Global:IntersightActivationMaxCheckIns = 2
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
function Set-IntersightComputeServerSetting { param($Moid,$AdminPowerState,$ErrorAction)
    $script:PowerCalls.Add("$Moid=$AdminPowerState")
    if ($script:PowerThrows) { throw "server is not reachable" } }
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
Assert-Equal "the action is sent" $true (Invoke-IntersightServerPowerAction -ServerMoid 'server-abc' -PowerState 'PowerCycle' 6>$null)
Assert-Equal "to the server's own setting Moid" "server-abc=PowerCycle" $script:PowerCalls[0]

Write-Host "`n=== A declined power action does not end the run ===" -ForegroundColor Cyan
$script:PowerThrows = $true
$script:PowerCalls.Clear()
$threw = $false
$result = $null
try { $result = Invoke-IntersightServerPowerAction -ServerMoid 'server-abc' -PowerState 'PowerCycle' 6>$null } catch { $threw = $true }
Assert-Equal "it does not throw" $false $threw
Assert-Equal "it reports not-sent" $false $result
$script:PowerThrows = $false

Write-Host "`n=== The activation stands off and checks in, and never ends the run ===" -ForegroundColor Cyan
# Activation finishes between check-ins.
$script:States = @('Pending-changes','Associated'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:PowerCalls.Clear()
Invoke-IntersightActivationPowerCycle -Row $row -BatchNumber '1' 6>$null
Assert-Equal "the power action was sent" 1 $script:PowerCalls.Count
Assert-Equal "and the activation is recorded as complete" "Activated" (@($Global:RunSummary | Where-Object { $_.Action -eq 'Confirm activation' })[0].Result)

Write-Host "`n=== An activation still running when the check-ins run out is handed on, not failed ===" -ForegroundColor Cyan
$script:States = @('Pending-changes'); $script:Reads = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$threw = $false
try { Invoke-IntersightActivationPowerCycle -Row $row -BatchNumber '1' 6>$null } catch { $threw = $true }
Assert-Equal "the run does not end" $false $threw
Assert-Equal "it is recorded as still staged" "StillStaged" (@($Global:RunSummary | Where-Object { $_.Action -eq 'Confirm activation' })[0].Result)

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

Write-Host "`n=== The default is PowerCycle, not Reboot ===" -ForegroundColor Cyan
$scriptText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the configured action resets the server" $true ($scriptText -match "\`$Global:IntersightActivationPowerAction = 'PowerCycle'")
Assert-Equal "the stand-off is 40 minutes" $true ($scriptText -match '\$Global:IntersightActivationWaitMinutes = 40')
Assert-Equal "'Reboot' is called out as IMC-only" $true ($scriptText -match 'reboots the IMC, NOT the server')

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
