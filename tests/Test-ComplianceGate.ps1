<#
.SYNOPSIS
    Tests the host profile compliance gate that decides whether a host goes back into service.

.DESCRIPTION
    This gate is the last thing standing between a freshly upgraded host and production workloads,
    so its failure modes matter more than most:

      - Scanning too early. A host that has just re-registered is still starting; the differences it
        reports resolve themselves. The settle wait exists to stop that reading as a real failure.
      - Not reading the status vCenter actually holds. PowerCLI puts it on ComplianceStatus or
        Status, on the result object or only on its ExtensionData. Reading too few of those is what
        made a genuinely compliant host report Unknown on a live run.
      - Scanning from the cache. The first call must never pass -UseCache, or nothing is checked.
        The stored result is a legitimate SECOND read once the scan has completed - the same value
        the vSphere Client shows - but never a substitute for the scan.
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
    'Get-ComplianceStatusValue'
    'ConvertTo-ComplianceStatus'
    'Get-ComplianceFailureDetail'
    'Select-ComplianceResultForHost'
    'Get-ComplianceStatusFromComplianceManager'
    'Wait-VMHostOutOfMaintenance'
    'Get-VMHostMaintenanceState'
    'Test-VMHostObjectInMaintenance'
    'Wait-VMHostProfileComplianceTask'
    'Confirm-SingleHostComplianceAndExit'
    'Read-ChoiceExit'
    'Read-PendingConsoleKey'
    'Test-DryRun'
)
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

# Settings the gate reads from script scope. The settle is zeroed so the test does not sit for two
# minutes; its behaviour is asserted separately against a non-zero value.
$HostProfileComplianceSettleMinutes      = 0
$HostProfileComplianceScanTimeoutMinutes = 1
$ExitMaintenanceTimeoutMinutes           = 1

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
# The ProfileComplianceManager route. $script:ManagerResults is what QueryComplianceStatus returns;
# $null makes Get-View unavailable, as it is on a session with no vCenter connection.
$script:ManagerResults = $null
# No [Parameter()] attributes: they make this an advanced function, which adds the common
# parameters and then collides with the explicit $ErrorAction the script passes.
function Get-View {
    param($VIObject,$Id,$ErrorAction)
    if ($null -eq $script:ManagerResults) { throw "Get-View is not available" }
    if ($Id) {
        return [pscustomobject]@{ } | Add-Member -MemberType ScriptMethod -Name QueryComplianceStatus -Value {
            param($profileRefs,$entityRefs) return $script:ManagerResults } -PassThru
    }
    return [pscustomobject]@{ Content = [pscustomobject]@{ ComplianceManager = 'compliance-manager-1' } }
}
function Get-VMHost { param($Name,$Location,$ErrorAction)
    return [pscustomobject]@{ Name = $Name; ConnectionState = $script:HostConnectionState } }
function Set-VMHost { param($VMHost,$State,[switch]$Evacuate,[switch]$RunAsync,$Confirm,$ErrorAction)
    $script:HostConnectionState = if ($State -eq 'Maintenance') { 'Maintenance' } else { 'Connected' } }

$testHost = [pscustomobject]@{
    Name = 'esx1.example'; ConnectionState = 'Maintenance'; Id = 'HostSystem-host-1'
    ExtensionData = [pscustomobject]@{ MoRef = [pscustomobject]@{ Value = 'host-1'; Type = 'HostSystem' } }
}

Write-Host "`n=== The scan is a real check, and the status is read from it ===" -ForegroundColor Cyan
$script:CacheCalls = New-Object System.Collections.Generic.List[bool]
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    $script:CacheCalls.Add([bool]$UseCache)
    return [pscustomobject]@{ ComplianceStatus = 'Compliant'; CheckTime = (Get-Date) }
}
$script:CacheCalls.Clear()
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "a Compliant result is reported as Compliant" "Compliant" $state.Status
Assert-Equal "exactly one call was made" 1 $script:CacheCalls.Count
Assert-Equal "the scan did not read from the cache" $false $script:CacheCalls[0]
Assert-Equal "the check time is carried back for display" $true ($null -ne $state.CheckTime)

Write-Host "`n=== A check already running in vCenter is drained first ===" -ForegroundColor Cyan
$script:RunningTasks = 2
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "the scan still completed" "Compliant" $state.Status
Assert-Equal "in-flight tasks were drained before scanning" 0 $script:RunningTasks

Write-Host "`n=== The status is found wherever this PowerCLI build put it ===" -ForegroundColor Cyan
# This is the live-run defect: the status was on ExtensionData, only ComplianceStatus and Status on
# the result object were read, and a compliant host reported Unknown.
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    $script:CacheCalls.Add([bool]$UseCache)
    return [pscustomobject]@{ ExtensionData = [pscustomobject]@{ ComplianceStatus = 'compliant' } }
}
$script:CacheCalls.Clear()
Assert-Equal "a status on ExtensionData is found" "Compliant" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status
Assert-Equal "and no cache read was needed" 1 $script:CacheCalls.Count

function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    return [pscustomobject]@{ Status = 'nonCompliant' }
}
Assert-Equal "the legacy Status property is found" "NonCompliant" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

Write-Host "`n=== Status strings normalise to three values ===" -ForegroundColor Cyan
foreach ($case in @(
    @{ Raw='compliant';     Expect='Compliant' },
    @{ Raw='Compliant';     Expect='Compliant' },
    @{ Raw='COMPLIANT';     Expect='Compliant' },
    @{ Raw='nonCompliant';  Expect='NonCompliant' },
    @{ Raw='Non-Compliant'; Expect='NonCompliant' },
    @{ Raw='NON COMPLIANT'; Expect='NonCompliant' },
    @{ Raw='non_compliant'; Expect='NonCompliant' },
    @{ Raw='unknown';       Expect='Unknown' },
    @{ Raw='';              Expect='Unknown' }
)) {
    Assert-Equal "'$($case.Raw)' normalises to $($case.Expect)" $case.Expect (ConvertTo-ComplianceStatus -Raw $case.Raw)
}
# An unfamiliar status must never be rounded down to a pass.
Assert-Equal "an unrecognised status is returned as-is, not as Compliant" "somethingElse" (ConvertTo-ComplianceStatus -Raw 'somethingElse')

Write-Host "`n=== An unreadable scan falls back to the status vCenter stored ===" -ForegroundColor Cyan
# The scan has completed by this point, so the stored result IS this scan's result - the same value
# the vSphere Client shows on the host's Host Profile tab.
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    $script:CacheCalls.Add([bool]$UseCache)
    if ($UseCache) { return [pscustomobject]@{ ComplianceStatus = 'compliant' } }
    return [pscustomobject]@{ ComplianceStatus = '' }
}
$script:CacheCalls.Clear()
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "the stored status is used" "Compliant" $state.Status
Assert-Equal "the scan ran before the cache was read" $false $script:CacheCalls[0]
Assert-Equal "then, and only then, the cache was read" $true $script:CacheCalls[1]
Assert-Equal "the fallback is stated in the detail" $true ($state.Details -match 'stored')

Write-Host "`n=== When vCenter gives nothing, Unknown is reported - never a pass ===" -ForegroundColor Cyan
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    return [pscustomobject]@{ ComplianceStatus = 'unknown' }
}
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "an unknown status stays Unknown" "Unknown" $state.Status
Assert-Equal "and says vCenter gave no usable status" $true ($state.Details -match 'no usable compliance status')

function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache,$ErrorAction) throw "vCenter unavailable" }
Assert-Equal "a failed scan is Unknown, never a pass" "Unknown" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache,$ErrorAction) return $null }
Assert-Equal "an empty scan result is Unknown, never a pass" "Unknown" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

Write-Host "`n=== Check time is read from ExtensionData when it is only there ===" -ForegroundColor Cyan
$stamp = (Get-Date).AddMinutes(-1)
$fromExtension = [pscustomobject]@{ ComplianceStatus = 'Compliant'; ExtensionData = [pscustomobject]@{ CheckTime = $stamp } }
Assert-Equal "ExtensionData.CheckTime is found" $stamp (Get-ComplianceCheckTime -ComplianceResult $fromExtension)
Assert-Equal "an object with neither reports null" $true ($null -eq (Get-ComplianceCheckTime -ComplianceResult ([pscustomobject]@{ ComplianceStatus = 'Compliant' })))
# Display only. An hour-old check time must not turn a compliant host into Unknown - that comparison
# was tried, and DateTimeKind made every host east of UTC fail it.
function Test-VMHostProfileCompliance {
    param($VMHost,[switch]$UseCache,$ErrorAction)
    return [pscustomobject]@{ ComplianceStatus = 'Compliant'; CheckTime = (Get-Date).AddHours(-1) }
}
Assert-Equal "an old check time does not override the status" "Compliant" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

Write-Host "`n=== The ProfileComplianceManager answers when the scan returns nothing ===" -ForegroundColor Cyan
# This is the live failure: Test-VMHostProfileCompliance -VMHost returned no result at all - no
# error, no rows - while the vSphere Client showed the host compliant. The manager is the source
# the client reads, so it is what settles it.
function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache,$ErrorAction) return @() }
$script:ManagerResults = @([pscustomobject]@{
    Entity = [pscustomobject]@{ Value = 'host-1' }; ComplianceStatus = 'compliant'; CheckTime = (Get-Date) })
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "the manager's status is used" "Compliant" $state.Status
Assert-Equal "the detail names the route that answered" $true ($state.Details -match 'compliance manager')

Write-Host "`n=== A result for a different host is never used for this one ===" -ForegroundColor Cyan
$script:ManagerResults = @([pscustomobject]@{
    Entity = [pscustomobject]@{ Value = 'host-99' }; ComplianceStatus = 'compliant' },
    [pscustomobject]@{ Entity = [pscustomobject]@{ Value = 'host-42' }; ComplianceStatus = 'compliant' })
Assert-Equal "two results, neither for this host, is not a pass" "Unknown" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status
$script:ManagerResults = @([pscustomobject]@{
    Entity = [pscustomobject]@{ Value = 'host-99' }; ComplianceStatus = 'nonCompliant' },
    [pscustomobject]@{ Entity = [pscustomobject]@{ Value = 'host-1' }; ComplianceStatus = 'compliant' })
Assert-Equal "the row matching this host is picked out of several" "Compliant" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

Write-Host "`n=== The profile-wide scan is the last resort, and is filtered ===" -ForegroundColor Cyan
$script:ManagerResults = $null      # manager unavailable
$script:ProfileScanCalled = $false
function Test-VMHostProfileCompliance {
    param($VMHost,$Profile,[switch]$UseCache,$ErrorAction)
    if ($Profile) {
        $script:ProfileScanCalled = $true
        return @(
            [pscustomobject]@{ VMHost = [pscustomobject]@{ Name = 'esx9.example' }; ComplianceStatus = 'nonCompliant' },
            [pscustomobject]@{ VMHost = [pscustomobject]@{ Name = 'esx1.example' }; ComplianceStatus = 'compliant' })
    }
    return @()
}
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "the profile-wide scan ran once everything else was exhausted" $true $script:ProfileScanCalled
Assert-Equal "and only this host's row was used" "Compliant" $state.Status

Write-Host "`n=== When every route declines, the detail says which ===" -ForegroundColor Cyan
function Test-VMHostProfileCompliance { param($VMHost,$Profile,[switch]$UseCache,$ErrorAction) return @() }
$state = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "no route answering is Unknown" "Unknown" $state.Status
foreach ($route in @('scan by host','compliance manager','stored result','scan by profile')) {
    Assert-Equal "the detail records the '$route' route" $true ($state.Details -match [regex]::Escape($route))
}

Write-Host "`n=== The exit from Maintenance mode is confirmed, not assumed ===" -ForegroundColor Cyan
# vCenter reports the old state for a moment. Returning before the transition lands stops the very
# next cluster health check, which is what made an override look like it had ended the run.
$script:HostConnectionState = 'Maintenance'
Assert-Equal "a host that never leaves Maintenance mode times out" $false (Wait-VMHostOutOfMaintenance -HostName 'esx1.example' -TimeoutMinutes 0.001 6>$null)
$script:HostConnectionState = 'Connected'
Assert-Equal "a host that has left is confirmed" $true (Wait-VMHostOutOfMaintenance -HostName 'esx1.example' -TimeoutMinutes 1 6>$null)

Write-Host "`n=== A compliant host is taken out of Maintenance mode ===" -ForegroundColor Cyan
function Test-VMHostProfileCompliance {
    param($VMHost,$Profile,[switch]$UseCache,$ErrorAction)
    return [pscustomobject]@{ ComplianceStatus = 'Compliant'; CheckTime = (Get-Date) }
}
$script:HostConnectionState = 'Maintenance'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt) throw "no prompt should be needed for a compliant host: $Prompt" }
Confirm-SingleHostComplianceAndExit -HostName 'esx1.example' -BatchNumber '1' 6>$null
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
Confirm-SingleHostComplianceAndExit -HostName 'esx1.example' -BatchNumber '1' 6>$null
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
Confirm-SingleHostComplianceAndExit -HostName 'esx1.example' -BatchNumber '1' 6>$null
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
try { Confirm-SingleHostComplianceAndExit -HostName 'esx1.example' -BatchNumber '1' 6>$null }
catch { $exited = "$_" -match 'EXIT:' }
Assert-Equal "E stops the run" $true $exited
Assert-Equal "and leaves the host in Maintenance mode" "Maintenance" $script:HostConnectionState

Write-Host "`n=== Anything other than Compliant halts, including NoProfile ===" -ForegroundColor Cyan
# NoProfile used to take a SKIP prompt of its own. It halts on the same C/O/E gate now, because
# "no profile attached" is no more evidence the profile applied than NonCompliant is - and the
# engineer may simply need to attach it, which C then re-checks.
function Get-VMHostProfile { param($Entity,$ErrorAction) return $null }
$script:HostConnectionState = 'Maintenance'
$script:PromptCount = 0
$script:StateAtPrompt = @()
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt)
    $script:PromptCount++
    if ($script:PromptCount -gt 5) { throw "the NoProfile halt did not settle" }
    $script:StateAtPrompt += $script:HostConnectionState
    return 'O' }
Confirm-SingleHostComplianceAndExit -HostName 'esx1.example' -BatchNumber '1' 6>$null
Assert-Equal "NoProfile stops to ask rather than carrying on" 1 $script:PromptCount
Assert-Equal "and the host was still in Maintenance mode when it asked" "Maintenance" $script:StateAtPrompt[0]
Assert-Equal "the override releases it" "Connected" $script:HostConnectionState
Assert-Equal "and it is recorded as an override, not a pass" "Overridden" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' })[0].Result)
function Get-VMHostProfile { param($Entity,$ErrorAction) return [pscustomobject]@{ Name = 'HP-Prod' } }

Write-Host "`n=== Unknown halts too - an unreadable result is not a pass ===" -ForegroundColor Cyan
$script:ManagerResults = $null
function Test-VMHostProfileCompliance { param($VMHost,$Profile,[switch]$UseCache,$ErrorAction) return $null }
$script:HostConnectionState = 'Maintenance'
$script:PromptCount = 0
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Read-Host { param($Prompt)
    $script:PromptCount++
    if ($script:PromptCount -gt 5) { throw "the Unknown halt did not settle" }
    return 'O' }
Confirm-SingleHostComplianceAndExit -HostName 'esx1.example' -BatchNumber '1' 6>$null
Assert-Equal "Unknown stops to ask" 1 $script:PromptCount
Assert-Equal "the accepted status is named as Unknown, not Compliant" $true ((@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' })[0].Details) -match 'Unknown')

Write-Host "`n=== The halt names the AD settings the pre-requisites ask to untick ===" -ForegroundColor Cyan
# A profile that will not apply on a rebooted host is nearly always these two, so the halt says so
# rather than leaving the engineer to remember the pre-requisite from the start of the run.
$gateText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the halt points at Authentication Configuration" $true ($gateText -match 'Authentication Configuration')
Assert-Equal "and at Active Directory Permission" $true ($gateText -match 'Active Directory Permission')
Assert-Equal "the requirements say to re-enable them afterwards" $true ($gateText -match '(?i)RE-ENABLE BOTH AFTER THE UPGRADE')

Write-Host "`n=== The settle is 8 minutes, and the activation waits are 60 ===" -ForegroundColor Cyan
Assert-Equal "the compliance settle is 8 minutes" $true ($gateText -match '\$HostProfileComplianceSettleMinutes = 8')
Assert-Equal "the activation stand-off is 60 minutes" $true ($gateText -match '\$Global:IntersightActivationWaitMinutes = 60')
Assert-Equal "the activation hold is 60 minutes" $true ($gateText -match '\$Global:IntersightActivationHoldMinutes = 60')

# Restore the compliant stub the remaining cases assume.
function Test-VMHostProfileCompliance {
    param($VMHost,$Profile,[switch]$UseCache,$ErrorAction)
    return [pscustomobject]@{ ComplianceStatus = 'Compliant'; CheckTime = (Get-Date) }
}

# The settle before the first scan is no longer a function of its own - it is the rolling engine's
# Settling stage, held per host from ITS OWN return, and asserted in Test-RollingUpgrade.ps1.
function Read-Host { param($Prompt) throw "no prompt expected: $Prompt" }

Write-Host "`n=== DRY RUN neither waits nor scans ===" -ForegroundColor Cyan
$Global:RunMode = 'DRYRUN'
$script:HostConnectionState = 'Maintenance'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache,$ErrorAction) throw "DRY RUN must not scan" }
Confirm-SingleHostComplianceAndExit -HostName 'esx1.example' -BatchNumber '1' 6>$null
# The guard used to live in the batch function the rolling engine replaced; losing it left DRY RUN
# running a real scan and a real Set-VMHost -State Connected.
Assert-Equal "DRY RUN recorded the intent only" "DryRun" (@($Global:RunSummary | Where-Object { $_.Stage -eq 'HostProfileCompliance' })[0].Result)
Assert-Equal "DRY RUN left the host in Maintenance mode" "Maintenance" $script:HostConnectionState
$Global:RunMode = 'LIVE'

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
