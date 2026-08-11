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
            'Get-ComplianceStatusFromComplianceManager','Wait-VMHostProfileComplianceTask')
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

# The settings the sizing function reads from script scope.
$MaxAbsoluteBatchSize = 6
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
Assert-Equal "lightly loaded 10-host cluster hits the MaxAbsoluteBatchSize cap" 6 $r.SafeBatchSize

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
Assert-Equal "batch never exceeds connected hosts minus one" 3 $r.SafeBatchSize

$r = Get-CapacityBasedBatchSize -CandidateHosts (New-Cluster -Count 1 -CpuUsedEach 1000 -MemUsedEach 10) -Cluster $cluster
Assert-Equal "single connected host yields a batch of one" 1 $r.SafeBatchSize

$mixed = @((New-Cluster -Count 3 -CpuUsedEach 1000 -MemUsedEach 10)) + @((New-TestHost -Name "down1" -CpuTotal 100000 -CpuUsed 0 -MemTotal 512 -MemUsed 0 -State "NotResponding"))
$r = Get-CapacityBasedBatchSize -CandidateHosts $mixed -Cluster $cluster
Assert-Equal "disconnected hosts are excluded from sizing" 2 $r.SafeBatchSize

$r = Get-CapacityBasedBatchSize -CandidateHosts @() -Cluster $cluster
Assert-Equal "no connected hosts returns 0" 0 $r.SafeBatchSize

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
