<#
.SYNOPSIS
    Tests the cluster health gate that decides whether the run may start or continue a batch.

.DESCRIPTION
    This gate stopped a live run after Batch 1 on a cluster with nothing wrong with it, and the
    stop message did not say why. Three things were wrong, and each has assertions here:

      - Local datastores were counted. Boot, scratch and local datastores routinely sit under 10%
        free by design; only shared datastores bear on whether a host can be evacuated.
      - Acknowledged alarms were counted. An acknowledged alarm is one somebody has already looked
        at and accepted, so treating it as a fresh fault blocks every batch indefinitely.
      - A failure was a dead end. Health raised while a host rejoins usually clears on its own, so
        RECHECK is the answer most of the time and there was no way to ask for it.

    Standalone - no Pester, no PowerCLI, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-ClusterHealthGate.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-ClusterHealthReport','Confirm-ClusterHealthOrChoose','Read-ChoiceExit') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$MinimumDatastoreFreePercent = 10
$Global:PreExistingMaintenanceHosts = @()
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
function Stop-SafeExit { param($Message) throw "EXIT: $Message" }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# --- Stubs -----------------------------------------------------------------------------------
$cluster = [pscustomobject]@{ Name = 'd85oob01' }

$script:Hosts = @(
    [pscustomobject]@{ Name = 'esx01'; ConnectionState = 'Connected' }
    [pscustomobject]@{ Name = 'esx02'; ConnectionState = 'Connected' }
)
$script:Datastores = @()
$script:Alarms = @()

function New-Datastore {
    param([string]$Name,[double]$Capacity,[double]$Free,[bool]$Shared)
    [pscustomobject]@{
        Name = $Name; CapacityGB = $Capacity; FreeSpaceGB = $Free
        ExtensionData = [pscustomobject]@{ Summary = [pscustomobject]@{ MultipleHostAccess = $Shared } }
    }
}

function Get-VMHost { param($Name,$Location,$ErrorAction) return $script:Hosts }
function Get-Datastore { param($Location,$ErrorAction) return $script:Datastores }
function Get-Cluster { param($Name,$ErrorAction)
    return [pscustomobject]@{ Name = $Name; ExtensionData = [pscustomobject]@{ TriggeredAlarmState = $script:Alarms } } }
function Get-View { param($VIObject,$Id,$ErrorAction)
    return [pscustomobject]@{ Info = [pscustomobject]@{ Name = "Alarm-$Id" } } }

Write-Host "`n=== A healthy cluster is healthy ===" -ForegroundColor Cyan
$script:Datastores = @((New-Datastore -Name 'vsanDatastore' -Capacity 1000 -Free 500 -Shared $true))
Assert-Equal "no reasons means healthy" $true (Get-ClusterHealthReport -Cluster $cluster 6>$null).IsHealthy

Write-Host "`n=== Local datastores do not fail the cluster ===" -ForegroundColor Cyan
# This is the live failure: a boot or scratch datastore below 10% free, which is how they ship, was
# stopping the run every batch on a cluster nobody could find anything wrong with.
$script:Datastores = @(
    (New-Datastore -Name 'vsanDatastore'  -Capacity 1000 -Free 500 -Shared $true)
    (New-Datastore -Name 'esx01-local'    -Capacity 100  -Free 2   -Shared $false)
    (New-Datastore -Name 'esx02-boot'     -Capacity 100  -Free 1   -Shared $false)
)
$report = Get-ClusterHealthReport -Cluster $cluster 6>$null
Assert-Equal "a nearly full LOCAL datastore does not fail the cluster" $true $report.IsHealthy

$script:Datastores = @((New-Datastore -Name 'vsanDatastore' -Capacity 1000 -Free 50 -Shared $true))
$report = Get-ClusterHealthReport -Cluster $cluster 6>$null
Assert-Equal "a nearly full SHARED datastore still fails the cluster" $false $report.IsHealthy
Assert-Equal "and the datastore is named" $true (($report.Reasons -join ' ') -match 'vsanDatastore')

# A datastore that will not say whether it is shared is checked anyway - the mistake has to be
# toward caution, not away from it.
$script:Datastores = @([pscustomobject]@{ Name = 'mystery'; CapacityGB = 100; FreeSpaceGB = 1 })
Assert-Equal "a datastore of unknown sharing is still checked" $false (Get-ClusterHealthReport -Cluster $cluster 6>$null).IsHealthy

Write-Host "`n=== Acknowledged alarms are not a fresh fault ===" -ForegroundColor Cyan
$script:Datastores = @((New-Datastore -Name 'vsanDatastore' -Capacity 1000 -Free 500 -Shared $true))
$script:Alarms = @([pscustomobject]@{ OverallStatus = 'red'; Acknowledged = $true; Alarm = [pscustomobject]@{ Value = 'alarm-7' } })
Assert-Equal "an acknowledged red alarm does not fail the cluster" $true (Get-ClusterHealthReport -Cluster $cluster 6>$null).IsHealthy

$script:Alarms = @([pscustomobject]@{ OverallStatus = 'red'; Acknowledged = $false; Alarm = [pscustomobject]@{ Value = 'alarm-9' } })
$report = Get-ClusterHealthReport -Cluster $cluster 6>$null
Assert-Equal "an unacknowledged red alarm still fails the cluster" $false $report.IsHealthy
Assert-Equal "and the alarm is named, not just counted" $true (($report.Reasons -join ' ') -match 'Alarm-')

$script:Alarms = @([pscustomobject]@{ OverallStatus = 'yellow'; Acknowledged = $false; Alarm = [pscustomobject]@{ Value = 'alarm-3' } })
Assert-Equal "a yellow alarm is not a stop" $true (Get-ClusterHealthReport -Cluster $cluster 6>$null).IsHealthy
$script:Alarms = @()

Write-Host "`n=== Hosts in Maintenance mode ===" -ForegroundColor Cyan
$script:Hosts = @(
    [pscustomobject]@{ Name = 'esx01'; ConnectionState = 'Connected' }
    [pscustomobject]@{ Name = 'esx02'; ConnectionState = 'Maintenance' }
)
Assert-Equal "a host in Maintenance mode fails the cluster" $false (Get-ClusterHealthReport -Cluster $cluster 6>$null).IsHealthy
$Global:PreExistingMaintenanceHosts = @('esx02')
Assert-Equal "unless it was already there before the run started" $true (Get-ClusterHealthReport -Cluster $cluster 6>$null).IsHealthy
$Global:PreExistingMaintenanceHosts = @()
$script:Hosts = @([pscustomobject]@{ Name = 'esx01'; ConnectionState = 'Connected' })

Write-Host "`n=== A healthy check asks nothing ===" -ForegroundColor Cyan
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt) throw "a healthy cluster must not prompt: $Prompt" }
[void](Confirm-ClusterHealthOrChoose -Cluster $cluster -Stage "after" -BatchNumber "1" 6>$null)
Assert-Equal "healthy is recorded" "Healthy" $Global:RunSummary[0].Result

Write-Host "`n=== RECHECK re-evaluates rather than ending the run ===" -ForegroundColor Cyan
# Alarms raised while a host rejoins clear on their own. Without a re-check the run ends on a
# cluster that was already recovering by the time anyone read the message.
$script:Alarms = @([pscustomobject]@{ OverallStatus = 'red'; Acknowledged = $false; Alarm = [pscustomobject]@{ Value = 'alarm-transient' } })
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:Asked = 0
function Read-Host { param($Prompt)
    $script:Asked++
    if ($script:Asked -gt 3) { throw "RECHECK is looping" }
    $script:Alarms = @()          # the alarm clears, as a transient one does
    return 'RECHECK' }
$report = Confirm-ClusterHealthOrChoose -Cluster $cluster -Stage "after" -BatchNumber "1" 6>$null
Assert-Equal "it was asked once" 1 $script:Asked
Assert-Equal "the re-check found the cluster healthy" $true $report.IsHealthy
Assert-Equal "both the failure and the recovery are on the record" "Failed" $Global:RunSummary[0].Result
Assert-Equal "and the run continued" "Healthy" $Global:RunSummary[1].Result

Write-Host "`n=== OVERRIDE continues and says what was accepted ===" -ForegroundColor Cyan
$script:Alarms = @([pscustomobject]@{ OverallStatus = 'red'; Acknowledged = $false; Alarm = [pscustomobject]@{ Value = 'alarm-real' } })
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt) return 'OVERRIDE' }
$report = Confirm-ClusterHealthOrChoose -Cluster $cluster -Stage "after" -BatchNumber "2" 6>$null
Assert-Equal "the run continues" $true ($null -ne $report)
$override = @($Global:RunSummary | Where-Object { $_.Result -eq 'Overridden' })
Assert-Equal "the override is recorded" 1 $override.Count
Assert-Equal "naming what was accepted" $true ($override[0].Details -match 'Alarm-')

Write-Host "`n=== STOP stops, and the reason travels with it ===" -ForegroundColor Cyan
# The old stop message said "Resolve before continuing" and nothing else. The reasons were printed
# above it and scrolled away, so the record showed that something failed but not what.
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt) return 'STOP' }
$stopMessage = ""
try { [void](Confirm-ClusterHealthOrChoose -Cluster $cluster -Stage "after" -BatchNumber "3" 6>$null) } catch { $stopMessage = "$_" }
Assert-Equal "the run stops" $true ($stopMessage -match 'STOP:')
Assert-Equal "and the stop message carries the reason" $true ($stopMessage -match 'Alarm-')

Write-Host "`n=== EXIT is still available at the prompt ===" -ForegroundColor Cyan
function Read-Host { param($Prompt) return 'E' }
$exited = $false
try { [void](Confirm-ClusterHealthOrChoose -Cluster $cluster -Stage "after" -BatchNumber "4" 6>$null) } catch { $exited = "$_" -match 'EXIT:' }
Assert-Equal "E exits safely" $true $exited

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
