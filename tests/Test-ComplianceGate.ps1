<#
.SYNOPSIS
    Tests the host profile compliance gate that decides whether a host goes back into service.

.DESCRIPTION
    This gate is the last thing standing between a freshly upgraded host and production workloads,
    so its failure modes matter more than most:

      - Scanning too early. A host that has just re-registered is still starting; the differences it
        reports resolve themselves. The settle wait exists to stop that reading as a real failure.
      - Reading a stale answer. vCenter can return the result of a check that ran BEFORE the reboot.
        A pre-reboot "Compliant" is the worst possible answer to act on, because it takes the host
        out of Maintenance mode on the strength of its old configuration. Stale must become Unknown.
      - Cached answers. -UseCache is what makes Test-VMHostProfileCompliance hand back the stored
        result instead of checking, so it must never be passed.
      - The override. O returns a non-compliant host to service on purpose. It has to work, and it
        has to leave a record saying what was accepted.

    Standalone - no Pester, no PowerCLI, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-ComplianceGate.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$wanted = @(
    'Get-VMHostProfileComplianceState'
    'Get-ComplianceCheckTime'
    'Wait-VMHostProfileComplianceTask'
    'Wait-HostProfileComplianceSettle'
    'Confirm-HostProfileComplianceAndExitMaintenance'
    'Read-ChoiceExit'
    'Read-PendingConsoleKey'
    'Test-DryRun'
    'Test-StageNoAck'
)
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

# Settings the gate reads from script scope. The settle is zeroed so the test does not sit for two
# minutes; its behaviour is asserted separately against a non-zero value.
$HostProfileComplianceSettleMinutes      = 0
$HostProfileComplianceScanTimeoutMinutes = 1
$HostProfileComplianceScanRetries        = 3

$Global:RunMode = 'LIVE'
$Global:AutoExitMaintenanceMode = $true
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
function Stop-SafeExit { param($Message) throw "EXIT: $Message" }
function Start-Sleep { param($Seconds,$Milliseconds) }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# --- Stubs -------------------------------------------------------------------------------------
$script:UseCacheRequested = $false
$script:ScanCount = 0
$script:RunningTasks = 0
$script:HostConnectionState = 'Maintenance'

function Get-Task {
    param($Status,$Id,$ErrorAction)
    if ($script:RunningTasks -le 0) { return @() }
    $script:RunningTasks--
    return @([pscustomobject]@{ Name = 'CheckCompliance_Task'; Description = 'Check compliance' })
}
function Get-VMHostProfile { param($Entity,$ErrorAction) return [pscustomobject]@{ Name = 'HP-Prod' } }
function Get-VMHost { param($Name,$Location,$ErrorAction)
    return [pscustomobject]@{ Name = $Name; ConnectionState = $script:HostConnectionState } }
function Set-VMHost { param($VMHost,$State,[switch]$Evacuate,[switch]$RunAsync,$Confirm,$ErrorAction)
    $script:HostConnectionState = if ($State -eq 'Maintenance') { 'Maintenance' } else { 'Connected' } }

$testHost = [pscustomobject]@{ Name = 'esx1.example'; ConnectionState = 'Maintenance' }

Write-Host "`n=== The scan is a real check, not a cached answer ===" -ForegroundColor Cyan
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    $script:ScanCount++
    if ($UseCache) { $script:UseCacheRequested = $true }
    return [pscustomobject]@{ ComplianceStatus = 'Compliant'; CheckTime = (Get-Date) }
}
$script:ScanCount = 0; $script:UseCacheRequested = $false
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "a fresh Compliant result is accepted" "Compliant" $state.Status
Assert-Equal "-UseCache was never passed" $false $script:UseCacheRequested
Assert-Equal "exactly one scan was issued" 1 $script:ScanCount
Assert-Equal "the check time is carried back to the caller" $true ($null -ne $state.CheckTime)

Write-Host "`n=== A check already running in vCenter is drained first ===" -ForegroundColor Cyan
$script:RunningTasks = 2; $script:ScanCount = 0
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "the scan still completed" "Compliant" $state.Status
Assert-Equal "in-flight tasks were drained before scanning" 0 $script:RunningTasks

Write-Host "`n=== A pre-reboot result is never accepted as a pass ===" -ForegroundColor Cyan
# vCenter answers from a check taken an hour ago - i.e. before the host rebooted.
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    $script:ScanCount++
    return [pscustomobject]@{ ComplianceStatus = 'Compliant'; CheckTime = (Get-Date).AddHours(-1) }
}
$script:ScanCount = 0
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "a stale Compliant becomes Unknown, not Compliant" "Unknown" $state.Status
Assert-Equal "the scan was retried before giving up" 3 $script:ScanCount
Assert-Equal "the reason names the staleness" $true ($state.Details -match 'older than the scan request')

Write-Host "`n=== A stale result that goes fresh is accepted ===" -ForegroundColor Cyan
$script:ScanCount = 0
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    $script:ScanCount++
    $when = if ($script:ScanCount -eq 1) { (Get-Date).AddHours(-1) } else { (Get-Date) }
    return [pscustomobject]@{ ComplianceStatus = 'Compliant'; CheckTime = $when }
}
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "the second scan's fresh result is used" "Compliant" $state.Status
Assert-Equal "it stopped retrying as soon as the result was fresh" 2 $script:ScanCount

Write-Host "`n=== A build that reports no check time is taken at face value ===" -ForegroundColor Cyan
# Older PowerCLI does not project checkTime. The synchronous scan is its own guarantee there, and
# refusing every result would make the gate unusable on those builds.
$script:ScanCount = 0
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    $script:ScanCount++
    return [pscustomobject]@{ ComplianceStatus = 'Compliant' }
}
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "no check time still yields Compliant" "Compliant" $state.Status
Assert-Equal "and does not retry pointlessly" 1 $script:ScanCount
Assert-Equal "the missing check time is reported as absent, not invented" $true ($null -eq $state.CheckTime)

Write-Host "`n=== Check time is read from ExtensionData when it is only there ===" -ForegroundColor Cyan
$stamp = (Get-Date).AddMinutes(-1)
$fromExtension = [pscustomobject]@{ ComplianceStatus = 'Compliant'; ExtensionData = [pscustomobject]@{ CheckTime = $stamp } }
Assert-Equal "ExtensionData.CheckTime is found" $stamp (Get-ComplianceCheckTime -ComplianceResult $fromExtension)
Assert-Equal "an object with neither reports null" $true ($null -eq (Get-ComplianceCheckTime -ComplianceResult ([pscustomobject]@{ ComplianceStatus = 'Compliant' })))

Write-Host "`n=== A compliant host is taken out of Maintenance mode ===" -ForegroundColor Cyan
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    return [pscustomobject]@{ ComplianceStatus = 'Compliant'; CheckTime = (Get-Date) }
}
$script:HostConnectionState = 'Maintenance'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt) throw "no prompt should be needed for a compliant host: $Prompt" }
Confirm-HostProfileComplianceAndExitMaintenance -HostNames @('esx1.example') -BatchNumber '1' 6>$null
Assert-Equal "the host was returned to service" "Connected" $script:HostConnectionState
Assert-Equal "compliance was recorded as Compliant" "Compliant" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' })[0].Result)
Assert-Equal "the exit was recorded" "Sent" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ExitMaintenance' })[0].Result)

Write-Host "`n=== C re-checks and keeps the host in Maintenance mode until it passes ===" -ForegroundColor Cyan
$script:ComplianceAttempt = 0
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    $script:ComplianceAttempt++
    $status = if ($script:ComplianceAttempt -lt 3) { 'NonCompliant' } else { 'Compliant' }
    return [pscustomobject]@{ ComplianceStatus = $status; CheckTime = (Get-Date) }
}
$script:HostConnectionState = 'Maintenance'
$script:StateAtPrompt = @()
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt)
    $script:StateAtPrompt += $script:HostConnectionState
    return 'C' }
Confirm-HostProfileComplianceAndExitMaintenance -HostNames @('esx1.example') -BatchNumber '1' 6>$null
Assert-Equal "the host stayed in Maintenance mode at every re-check prompt" $true (@($script:StateAtPrompt | Where-Object { $_ -ne 'Maintenance' }).Count -eq 0)
Assert-Equal "it was prompted twice before passing" 2 $script:StateAtPrompt.Count
Assert-Equal "the host was released only after it passed" "Connected" $script:HostConnectionState
Assert-Equal "the re-checks are on the record" 2 (@($Global:RunSummary | Where-Object { $_.Result -eq 'NonCompliant' }).Count)

Write-Host "`n=== O overrides, releases the host and says so ===" -ForegroundColor Cyan
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    return [pscustomobject]@{ ComplianceStatus = 'NonCompliant'; CheckTime = (Get-Date) }
}
$script:HostConnectionState = 'Maintenance'
$script:PromptCount = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt) $script:PromptCount++; if ($script:PromptCount -gt 5) { throw "override did not break the loop" }; return 'O' }
Confirm-HostProfileComplianceAndExitMaintenance -HostNames @('esx1.example') -BatchNumber '1' 6>$null
Assert-Equal "one prompt was enough - the override broke the loop" 1 $script:PromptCount
Assert-Equal "the non-compliant host was returned to service" "Connected" $script:HostConnectionState
$override = @($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' })[0]
Assert-Equal "the summary records it as Overridden, not Compliant" "Overridden" $override.Result
Assert-Equal "the accepted status is named in the record" $true ($override.Details -match 'NonCompliant')
Assert-Equal "maintenance mode was still exited on the record" "Sent" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'ExitMaintenance' })[0].Result)

Write-Host "`n=== E exits from the compliance prompt ===" -ForegroundColor Cyan
$script:HostConnectionState = 'Maintenance'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt) return 'E' }
$exited = $false
try { Confirm-HostProfileComplianceAndExitMaintenance -HostNames @('esx1.example') -BatchNumber '1' 6>$null }
catch { $exited = "$_" -match 'EXIT:' }
Assert-Equal "E stops the run" $true $exited
Assert-Equal "and leaves the host in Maintenance mode" "Maintenance" $script:HostConnectionState

Write-Host "`n=== The settle wait runs before the first scan ===" -ForegroundColor Cyan
$HostProfileComplianceSettleMinutes = 0.001
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt) throw "no prompt expected: $Prompt" }
Wait-HostProfileComplianceSettle -HostNames @('esx1.example') -BatchNumber '1' 6>$null
$settle = @($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileComplianceSettle' })
Assert-Equal "the settle is recorded under its own stage" 1 $settle.Count
Assert-Equal "and recorded as completed" "Completed" $settle[0].Result
Assert-Equal "the settle does not masquerade as a compliance result" 0 (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' }).Count)

$HostProfileComplianceSettleMinutes = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
Wait-HostProfileComplianceSettle -HostNames @('esx1.example') -BatchNumber '1' 6>$null
Assert-Equal "a zero settle is a genuine no-op" 0 $Global:RunSummary.Count

Write-Host "`n=== DRY RUN neither waits nor scans ===" -ForegroundColor Cyan
$Global:RunMode = 'DRYRUN'
$script:HostConnectionState = 'Maintenance'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache,$ErrorAction) throw "DRY RUN must not scan" }
Confirm-HostProfileComplianceAndExitMaintenance -HostNames @('esx1.example') -BatchNumber '1' 6>$null
Assert-Equal "DRY RUN recorded the intent only" "DryRun" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' })[0].Result)
Assert-Equal "DRY RUN left the host in Maintenance mode" "Maintenance" $script:HostConnectionState
$Global:RunMode = 'LIVE'

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
