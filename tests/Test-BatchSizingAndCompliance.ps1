<#
.SYNOPSIS
    Tests capacity-based batch sizing and host profile compliance parsing.

.DESCRIPTION
    Extracts Get-CapacityBasedBatchSize and Get-VMHostProfileComplianceState from the
    controller by AST and drives them with synthetic hosts and stubbed PowerCLI cmdlets.

    Standalone - no Pester, no PowerCLI, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-BatchSizingAndCompliance.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchControl.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$wanted = @('Get-CapacityBasedBatchSize','Get-VMHostProfileComplianceState',
            'Get-ComplianceCheckTime','Get-ComplianceStatusValue','ConvertTo-ComplianceStatus',
            'Get-ComplianceFailureDetail','Select-ComplianceResultForHost',
            'Get-ComplianceStatusFromComplianceManager','Wait-VMHostProfileComplianceTask',
            'Test-VMHostObjectInMaintenance')
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

# The settings the sizing function reads from script scope.
$MaxAbsoluteBatchSize = 0
$MaxConcurrentHostFraction = 0.5
$ResourceSafetyBuffer = 0.85
$MinimumCpuHeadroomPercentAfterBatch = 10
$MinimumMemoryHeadroomPercentAfterBatch = 10

# The setting the compliance scan reads. The scan behaviour itself is covered in Test-ComplianceGate;
# these cases are only about reading what vCenter returned.
$HostProfileComplianceScanTimeoutMinutes = 1

function Get-Task { param($Status,$Id,$ErrorAction) return @() }
# No vCenter connection, so the ProfileComplianceManager route is genuinely unavailable - these
# cases are about what the cmdlet itself returned.
function Get-View { param($VIObject,$Id,$ErrorAction) throw "not connected" }
function Start-Sleep { param($Seconds,$Milliseconds) }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name (got $Actual)" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected $Expected, got $Actual)" -ForegroundColor Red }
}

function New-TestHost {
    param([string]$Name,[double]$CpuTotal,[double]$CpuUsed,[double]$MemTotal,[double]$MemUsed,[string]$State="Connected")
    [pscustomobject]@{
        Name = $Name; ConnectionState = $State
        CpuTotalMhz = $CpuTotal; CpuUsageMhz = $CpuUsed
        MemoryTotalGB = $MemTotal; MemoryUsageGB = $MemUsed
    }
}

function New-Cluster { param([int]$Count,[double]$CpuUsedEach,[double]$MemUsedEach)
    1..$Count | ForEach-Object { New-TestHost -Name "esx$_" -CpuTotal 100000 -CpuUsed $CpuUsedEach -MemTotal 512 -MemUsed $MemUsedEach }
}

$cluster = [pscustomobject]@{ Name = 'TestCluster' }

Write-Host "`n=== Capacity-based batch sizing ===" -ForegroundColor Cyan

# 10 hosts x 100000 MHz / 512 GB. 30% used cluster-wide.
# n=6: remaining 400000 * 0.85 * 0.90 = 306000 >= 300000 used -> fits, and 6 is the cap.
$r = Get-CapacityBasedBatchSize -CandidateHosts (New-Cluster -Count 10 -CpuUsedEach 30000 -MemUsedEach 153.6) -Cluster $cluster
Assert-Equal "lightly loaded 10-host cluster is capped at half the cluster" 5 $r.SafeBatchSize

# Same cluster at 32% CPU: n=6 allows 306000 < 320000 -> fails; n=5 allows 382500 -> fits.
$r = Get-CapacityBasedBatchSize -CandidateHosts (New-Cluster -Count 10 -CpuUsedEach 32000 -MemUsedEach 153.6) -Cluster $cluster
Assert-Equal "busier cluster walks down to a smaller batch" 5 $r.SafeBatchSize

# 70% CPU: even n=1 allows 900000*0.85*0.9 = 688500 < 700000 -> nothing is safe.
$r = Get-CapacityBasedBatchSize -CandidateHosts (New-Cluster -Count 10 -CpuUsedEach 70000 -MemUsedEach 153.6) -Cluster $cluster
Assert-Equal "cluster too busy to remove even one host returns 0" 0 $r.SafeBatchSize

# Memory is the binding constraint while CPU is idle. CPU alone would allow the full 6;
# 3000 GB used against 5120 GB total only leaves room to remove 2 hosts.
$r = Get-CapacityBasedBatchSize -CandidateHosts (New-Cluster -Count 10 -CpuUsedEach 1000 -MemUsedEach 300) -Cluster $cluster
Assert-Equal "memory pressure limits the batch independently of CPU" 2 $r.SafeBatchSize

# 3550 GB used exceeds even the one-host-removed allowance of 3525.12 GB.
$r = Get-CapacityBasedBatchSize -CandidateHosts (New-Cluster -Count 10 -CpuUsedEach 1000 -MemUsedEach 355) -Cluster $cluster
Assert-Equal "memory too tight to remove even one host returns 0" 0 $r.SafeBatchSize

# Host count is still a ceiling: 4 hosts can never batch more than 3.
$r = Get-CapacityBasedBatchSize -CandidateHosts (New-Cluster -Count 4 -CpuUsedEach 1000 -MemUsedEach 10) -Cluster $cluster
Assert-Equal "a 4-host cluster never takes more than half of it" 2 $r.SafeBatchSize

$r = Get-CapacityBasedBatchSize -CandidateHosts (New-Cluster -Count 1 -CpuUsedEach 1000 -MemUsedEach 10) -Cluster $cluster
Assert-Equal "single connected host yields a batch of one" 1 $r.SafeBatchSize

$mixed = @((New-Cluster -Count 3 -CpuUsedEach 1000 -MemUsedEach 10)) + @((New-TestHost -Name "down1" -CpuTotal 100000 -CpuUsed 0 -MemTotal 512 -MemUsed 0 -State "NotResponding"))
$r = Get-CapacityBasedBatchSize -CandidateHosts $mixed -Cluster $cluster
Assert-Equal "disconnected hosts are excluded from sizing" 1 $r.SafeBatchSize

$r = Get-CapacityBasedBatchSize -CandidateHosts @() -Cluster $cluster
Assert-Equal "no connected hosts returns 0" 0 $r.SafeBatchSize

Write-Host "`n=== Hosts already in Maintenance mode are in scope, and cost no capacity ===" -ForegroundColor Cyan
# They were previously skipped for being not-Connected, which left them on old firmware while the
# run reported the cluster complete. They are already evacuated, so taking them frees nothing and
# costs nothing - their slots are added on top of what the connected hosts can afford.
function New-ParkedHost { param([string]$Name)
    New-TestHost -Name $Name -CpuTotal 100000 -CpuUsed 0 -MemTotal 512 -MemUsed 0 -State "Maintenance" }

# Nothing connected can be spared at 70% CPU, but the parked hosts still can be - and must be,
# or the very hosts this run was asked to capture are the ones it strands.
$busyPlusParked = @((New-Cluster -Count 10 -CpuUsedEach 70000 -MemUsedEach 153.6)) + @((New-ParkedHost -Name "parked1"), (New-ParkedHost -Name "parked2"))
$r = Get-CapacityBasedBatchSize -CandidateHosts $busyPlusParked -Cluster $cluster
Assert-Equal "a cluster too busy to spare a connected host still takes the parked ones" 2 $r.SafeBatchSize

# Every candidate parked: always safe, never a capacity stop.
$r = Get-CapacityBasedBatchSize -CandidateHosts @((New-ParkedHost -Name "p1"), (New-ParkedHost -Name "p2"), (New-ParkedHost -Name "p3")) -Cluster $cluster
Assert-Equal "a batch made up entirely of parked hosts is never refused" 1 $r.SafeBatchSize

# The free slots ride on top of the sized connected batch: 5 connected + 1 parked = 6.
$r = Get-CapacityBasedBatchSize -CandidateHosts (@((New-Cluster -Count 10 -CpuUsedEach 32000 -MemUsedEach 153.6)) + @((New-ParkedHost -Name "parked1"))) -Cluster $cluster
Assert-Equal "a parked host counts towards the ceiling, it does not raise it" 5 $r.SafeBatchSize

# Parked hosts COUNT TOWARDS the ceiling rather than raising it: 12 hosts, half is 6, and the
# 2 already parked are 2 of that 6.
$r = Get-CapacityBasedBatchSize -CandidateHosts (@((New-Cluster -Count 10 -CpuUsedEach 30000 -MemUsedEach 153.6)) + @((New-ParkedHost -Name "parked1"), (New-ParkedHost -Name "parked2"))) -Cluster $cluster
Assert-Equal "parked hosts count towards the ceiling, never past it" 6 $r.SafeBatchSize

# One connected host plus parked ones is still a valid batch.
$r = Get-CapacityBasedBatchSize -CandidateHosts (@((New-Cluster -Count 1 -CpuUsedEach 1000 -MemUsedEach 10)) + @((New-ParkedHost -Name "parked1"), (New-ParkedHost -Name "parked2"))) -Cluster $cluster
Assert-Equal "one connected plus two parked is still bounded by the ceiling" 1 $r.SafeBatchSize

# NotResponding and Disconnected are still out. There is nothing to drive through vCenter on a
# host it cannot reach, and this is the distinction the change had to preserve.
$unreachable = @((New-Cluster -Count 3 -CpuUsedEach 1000 -MemUsedEach 10)) + @((New-TestHost -Name "down1" -CpuTotal 100000 -CpuUsed 0 -MemTotal 512 -MemUsed 0 -State "NotResponding"))
$r = Get-CapacityBasedBatchSize -CandidateHosts $unreachable -Cluster $cluster
Assert-Equal "NotResponding is still excluded, not treated as free" 1 $r.SafeBatchSize

Write-Host "`n=== The workflow puts parked hosts in scope, and takes them first ===" -ForegroundColor Cyan
$workflowText = [System.IO.File]::ReadAllText($scriptPath)
# Parked is asked of inMaintenanceMode, never of ConnectionState. In the vSphere API the two are
# independent, and a parked host whose heartbeat is missed reads NotResponding - which under the
# old ConnectionState test fell out of both the candidate list and the parked list at once.
Assert-Equal "the firmware candidate filter admits Maintenance" $true ($workflowText -match '\$patchCandidateHosts = @\(\$allClusterHosts \| Where-Object \{ \$_\.ConnectionState -eq "Connected" -or \(Test-VMHostObjectInMaintenance -VMHostObject \$_\) \}\)')
Assert-Equal "the ESXi-only filter admits Maintenance too" $true ($workflowText -match 'ConnectionState -eq "Connected" -or \(Test-VMHostObjectInMaintenance -VMHostObject \$_\)\) -and \(\$alreadyTargetHosts')
Assert-Equal "parked hosts are queued ahead of the rest" $true ($workflowText -match '(?s)Where-Object \{ Test-VMHostObjectInMaintenance -VMHostObject \$_ \}\)\) \{ \[void\]\$pendingHosts\.Add.*Where-Object \{ -not \(Test-VMHostObjectInMaintenance -VMHostObject \$_\) \}\)\) \{ \[void\]\$pendingHosts\.Add')
# ConnectionState may still be asked "can this host be reached at all" - Connected OR Maintenance -
# because on a host that genuinely is NotResponding there is nothing to read either way. What it
# must never do again is decide maintenance mode on its own.
$maintenanceDecisions = @(($workflowText -split "`n") | Where-Object {
    $_ -match 'ConnectionState -(eq|ne) "Maintenance"' -and
    $_.TrimStart() -notmatch '^#' -and
    $_ -notmatch 'ConnectionState -(eq|ne) "Connected"' -and
    $_ -notmatch '\[string\]\$VMHostObject\.ConnectionState' })
Assert-Equal "ConnectionState no longer decides Maintenance mode on its own" 0 $maintenanceDecisions.Count
Assert-Equal "and they are recorded as in scope, not excluded" $true ($workflowText -match '-Action "Pre-existing Maintenance mode" -Result "InScope"')

Write-Host "`n=== The ceiling is a TOTAL, and hosts in flight count against it ===" -ForegroundColor Cyan
# THE LIVE FAULT, from a 21-host cluster. Exempting parked hosts from the ceiling broke the
# rolling engine completely: the hosts it already had in flight ARE parked, so the limit grew by
# exactly the number in flight and the room to admit more never shrank. The run reported
#   "Ceiling: 10 of 21 host(s) may be out at once"
# and then
#   "Capacity allows 17 host(s) out at once; 10 already in flight"
# and started a second wave of 7 while the first 10 were still rebooting.
$twentyOne = @(1..21 | ForEach-Object { New-TestHost -Name "esx$_" -CpuTotal 100000 -CpuUsed 3400 -MemTotal 767 -MemUsed 100 })
$r = Get-CapacityBasedBatchSize -CandidateHosts $twentyOne -Cluster $cluster
Assert-Equal "an idle 21-host cluster takes half of it" 10 $r.SafeBatchSize

# Now ten of them are in flight - exactly the state the live run was in when it admitted more.
$tenOut = @(1..10 | ForEach-Object { New-TestHost -Name "esx$_" -CpuTotal 100000 -CpuUsed 0 -MemTotal 767 -MemUsed 0 -State "Maintenance" }) +
          @(11..21 | ForEach-Object { New-TestHost -Name "esx$_" -CpuTotal 100000 -CpuUsed 7500 -MemTotal 767 -MemUsed 187 })
$r = Get-CapacityBasedBatchSize -CandidateHosts $tenOut -Cluster $cluster
Assert-Equal "with ten already out, the total is still ten - not seventeen" 10 $r.SafeBatchSize
# The rolling engine subtracts what is in flight, so this leaves no room at all.
Assert-Equal "so nothing more may be admitted while those ten are out" 0 ($r.SafeBatchSize - 10)

# Three come back. Room opens by exactly three, and no more.
$sevenOut = @(1..7 | ForEach-Object { New-TestHost -Name "esx$_" -CpuTotal 100000 -CpuUsed 0 -MemTotal 767 -MemUsed 0 -State "Maintenance" }) +
            @(8..21 | ForEach-Object { New-TestHost -Name "esx$_" -CpuTotal 100000 -CpuUsed 5900 -MemTotal 767 -MemUsed 147 })
$r = Get-CapacityBasedBatchSize -CandidateHosts $sevenOut -Cluster $cluster
Assert-Equal "as hosts return, the total stays at the ceiling" 10 $r.SafeBatchSize
Assert-Equal "and exactly the freed slots open up" 3 ($r.SafeBatchSize - 7)

Write-Host "`n=== Host profile compliance parsing ===" -ForegroundColor Cyan
$testHost = New-TestHost -Name "esx1" -CpuTotal 1 -CpuUsed 0 -MemTotal 1 -MemUsed 0

function Get-VMHostProfile { param($Entity) return $null }
function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache) return $null }
Assert-Equal "no attached profile reports NoProfile" "NoProfile" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

function Get-VMHostProfile { param($Entity) [pscustomobject]@{ Name = 'HP-Prod' } }
function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache) [pscustomobject]@{ ComplianceStatus = 'Compliant' } }
$s = Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null
Assert-Equal "ComplianceStatus Compliant is recognised" "Compliant" $s.Status
Assert-Equal "profile name is carried through" "HP-Prod" $s.ProfileName

function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache) [pscustomobject]@{ ComplianceStatus = 'NonCompliant' } }
Assert-Equal "ComplianceStatus NonCompliant is recognised" "NonCompliant" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

# Older PowerCLI surfaces the value as Status rather than ComplianceStatus.
function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache) [pscustomobject]@{ Status = 'compliant' } }
Assert-Equal "legacy Status property is read, case-insensitively" "Compliant" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache) throw "vCenter unavailable" }
Assert-Equal "a failed compliance test is Unknown, never a pass" "Unknown" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

function Test-VMHostProfileCompliance { param($VMHost,[switch]$UseCache) return $null }
Assert-Equal "an empty compliance result is Unknown, never a pass" "Unknown" (Get-VMHostProfileComplianceState -VMHostObject $testHost 6>$null).Status

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
