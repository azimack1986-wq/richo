<#
.SYNOPSIS
    Standalone tests for Invoke-SqlRdmClusterMigration.ps1.

.DESCRIPTION
    No Pester, no PowerCLI, no vCenter. Helper functions are lifted out of the script by
    the PowerShell parser and defined in this session, so what is tested is the code that
    ships rather than a copy of it.

    Two kinds of check:

      * Behaviour - CSV validation, SCSI unit allocation, the change gate, and exact-name
        inventory resolution, all exercised in memory.
      * Structure - the guarantees the script makes about itself: that no mutating VMware
        call sits outside a planned-change block, that a hard power-off is gated, that RDM
        removal never deletes backing storage, and that the operator CSV never has to
        carry an NAA.

    Temporary CSVs are written to the temporary directory and removed in the finally
    block.

.PARAMETER ScriptPath
    The migration script under test.

.PARAMETER SampleCsvPath
    The sample CSV shipped alongside the script.

.EXAMPLE
    pwsh -File ./tests/Test-SqlRdmClusterMigration.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ScriptPath,

    [Parameter()]
    [string]$SampleCsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The script and its sample CSV are found either beside this file - the layout when the
# pair has been copied to a jump host - or in the repository, from tests/.
function Resolve-PackageFile {
    param([string]$FileName)
    $candidates = @(
        (Join-Path $PSScriptRoot $FileName),
        (Join-Path (Split-Path $PSScriptRoot -Parent) "scripts/vsphere/$FileName")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $candidates[-1]
}

if (-not $ScriptPath) { $ScriptPath = Resolve-PackageFile 'Invoke-SqlRdmClusterMigration.ps1' }
if (-not $SampleCsvPath) { $SampleCsvPath = Resolve-PackageFile 'SqlRdmClusterMigration.Sample.csv' }

$script:Passed = 0
$script:Failed = 0
$script:TempFiles = [System.Collections.Generic.List[string]]::new()

# Scope the loaded helpers expect to find. In the script these come from the parameters;
# here each test sets them.
$ScriptVersion = 'test'
$DryRun = $true
$script:RunMode = 'DryRun'
$script:GroupInfoByName = @{}
$script:ValidWorkloadTypes = @('PROD', 'SIT', 'DEV')
$script:MaxScsiUnitNumber = 15
$script:ReservedScsiUnitNumber = 7
$script:CapacityToleranceGB = 1
$script:Plan = [System.Collections.Generic.List[object]]::new()
$script:Results = [System.Collections.Generic.List[object]]::new()

function Write-RichoLog {
    # Quiet stub. The script carries its own copy of this function; loading it here would
    # scatter log lines through the test output, so its presence is asserted structurally
    # instead.
    param([string]$Message, [string]$Level = 'INFO', [string]$Path)
    Write-Verbose "$Level $Message"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', actual '$Actual'."
    }
}

function Assert-ThrowsLike {
    param([scriptblock]$Operation, [string]$Pattern, [string]$Message)
    try { & $Operation }
    catch {
        if ($_.Exception.Message -like $Pattern) { return }
        throw "$Message Wrong exception: $($_.Exception.Message)"
    }
    throw "$Message No exception was thrown."
}

function Invoke-NativeTest {
    param([string]$Name, [scriptblock]$Test)
    try {
        & $Test
        $script:Passed++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-TestCsv {
    param([string[]]$Lines)
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("SqlRdmClusterMigration-test-{0}.csv" -f [guid]::NewGuid())
    $Lines | Set-Content -LiteralPath $path -Encoding UTF8
    $script:TempFiles.Add($path)
    return $path
}

function Get-CommandAst {
    param($Ast, [string]$Name)
    return @(
        $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { $_.GetCommandName() -eq $Name }
    )
}

try {
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Migration script not found: $ScriptPath"
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $ScriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $text = Get-Content -LiteralPath $ScriptPath -Raw

    Invoke-NativeTest 'Migration script has no parser errors' {
        $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
        Assert-Equal @($parseErrors).Count 0 $messages
    }

    $requiredFunctions = @(
        'ConvertTo-ValueList',
        'Get-WorkloadType',
        'Get-GroupBatch',
        'Add-Result',
        'Invoke-PlannedChange',
        'Get-ExactObject',
        'Get-DefaultRdmDatastoreName',
        'Format-Elapsed',
        'Get-ScsiUnitNumberSequence',
        'Import-MigrationCsv',
        'Select-MigrationRows'
    )
    $functionAsts = @(
        $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
    )

    foreach ($name in $requiredFunctions) {
        $functionAst = @($functionAsts | Where-Object { $_.Name -eq $name })
        if ($functionAst.Count -ne 1) {
            throw "Expected one function '$name'; found $($functionAst.Count)."
        }
        Invoke-Expression $functionAst[0].Extent.Text
    }

    $header = 'batch,destination_cluster,workload_type,first_vm,other_vms_space_separated,svm,iSCSI_Data_Store,group_1_lun_IDs_ordered_space_separated,group_2_lun_IDs_ordered_space_separated,group_3_lun_IDs_ordered_space_separated,destination_resource_pool,destination_datastore_cluster'
    $valid = '1,labsql02,PROD,LABSQL01,LABSQL02 LABSQL03,lab-storage-svm01,LAB-RDM-POINTERS,40 41 42,50 51,,LAB-SQL-RP,LAB-VM-DATASTORES'

    # ---------------------------------------------------------------- CSV validation ----

    Invoke-NativeTest 'Grouped-LUN CSV is accepted' {
        $rows = @(Import-MigrationCsv -Path (New-TestCsv @($header, $valid)))
        Assert-Equal $rows.Count 1 'Unexpected row count.'
        Assert-Equal $rows[0].first_vm 'LABSQL01' 'Unexpected first VM.'
        Assert-Equal $rows[0].destination_cluster 'labsql02' 'Unexpected destination cluster.'
    }

    Invoke-NativeTest 'Missing destination cluster is rejected' {
        $badHeader = $header -replace ',destination_cluster,', ','
        $badRow = $valid -replace ',labsql02,', ','
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($badHeader, $badRow))
        } '*destination_cluster*' 'A CSV with no destination cluster was accepted.'
    }

    Invoke-NativeTest 'No source cluster column is required' {
        Assert-True ($header -notmatch 'vsphere_cluster') 'The sample header still carries a source cluster column.'
        Assert-True ($text -notmatch "'vsphere_cluster'") 'The script still requires a source cluster column.'
        Assert-True ($text -match '\$groupName = \[string\]\$row\.first_vm') 'The migration group is not named after its first VM.'
    }

    Invoke-NativeTest 'Batch must be a whole number of 1 or more' {
        $rows = @(Import-MigrationCsv -Path (New-TestCsv @($header, $valid)))
        Assert-Equal $rows[0].batch 1 'The batch number was not read as a number.'
        foreach ($bad in @('0', '-1', 'one', '')) {
            $badRow = $valid -replace '^1,', "$bad,"
            Assert-ThrowsLike {
                Import-MigrationCsv -Path (New-TestCsv @($header, $badRow))
            } '*batch*' "Batch '$bad' was accepted."
        }
    }

    Invoke-NativeTest 'Workload type is limited to PROD, SIT and DEV' {
        foreach ($accepted in @('PROD', 'sit', 'Dev')) {
            $row = $valid -replace ',PROD,', ",$accepted,"
            $rows = @(Import-MigrationCsv -Path (New-TestCsv @($header, $row)))
            Assert-Equal $rows[0].workload_type $accepted.ToUpperInvariant() 'Workload type was not normalised to upper case.'
        }
        $bad = $valid -replace ',PROD,', ',UAT,'
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, $bad))
        } '*expected one of PROD, SIT, DEV*' 'An unknown workload type was accepted.'
    }

    Invoke-NativeTest 'A blank RDM pointer datastore is allowed, to be derived later' {
        $blank = $valid -replace ',LAB-RDM-POINTERS,', ',,'
        $rows = @(Import-MigrationCsv -Path (New-TestCsv @($header, $blank)))
        Assert-Equal $rows[0].iSCSI_Data_Store '' 'A blank RDM datastore cell was not accepted.'
    }

    Invoke-NativeTest 'Derived RDM datastore name is the cluster plus the workload suffix' {
        # Clusters are shared, so one cluster has all three mapping directories.
        Assert-Equal (Get-DefaultRdmDatastoreName -ClusterName 'd24sql02' -WorkloadType 'PROD') 'd24sql02_i_rdm' 'PROD name is wrong.'
        Assert-Equal (Get-DefaultRdmDatastoreName -ClusterName 'd24sql02' -WorkloadType 'SIT') 'd24sql02sit_i_rdm' 'SIT name is wrong.'
        Assert-Equal (Get-DefaultRdmDatastoreName -ClusterName 'd24sql02' -WorkloadType 'DEV') 'd24sql02dev_i_rdm' 'DEV name is wrong.'
    }

    Invoke-NativeTest 'The workload type never judges the cluster name' {
        # Clusters carry PROD, SIT and DEV together, so a SIT row on a cluster whose name
        # says nothing about SIT is normal and must not warn.
        Assert-True ($text -notmatch 'does not follow that naming') 'The cluster-naming warning is back.'
    }

    Invoke-NativeTest 'Elapsed times are rendered for an operator, not a debugger' {
        Assert-Equal (Format-Elapsed -Elapsed ([timespan]::FromSeconds(4.25))) '4.3s' 'Seconds are wrong.'
        Assert-Equal (Format-Elapsed -Elapsed ([timespan]::FromSeconds(90))) '1m 30s' 'Minutes are wrong.'
        Assert-Equal (Format-Elapsed -Elapsed ([timespan]::FromMinutes(75))) '1h 15m' 'Hours are wrong.'
    }

    Invoke-NativeTest 'Shipped sample CSV is accepted and matches the required header' {
        Assert-True (Test-Path -LiteralPath $SampleCsvPath -PathType Leaf) "Sample CSV not found: $SampleCsvPath"
        $sampleHeader = (Get-Content -LiteralPath $SampleCsvPath -TotalCount 1).Trim()
        Assert-Equal $sampleHeader $header 'Sample CSV header has drifted from the columns the script requires.'
        $rows = @(Import-MigrationCsv -Path $SampleCsvPath)
        Assert-True ($rows.Count -ge 1) 'Sample CSV has no data rows.'
    }

    Invoke-NativeTest 'Missing destination column is rejected' {
        $badHeader = $header -replace ',destination_datastore_cluster$', ''
        $badRow = $valid -replace ',LAB-VM-DATASTORES$', ''
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($badHeader, $badRow))
        } '*destination_datastore_cluster*' 'Missing-column validation failed.'
    }

    Invoke-NativeTest 'Empty required cell is rejected' {
        $bad = $valid -replace ',lab-storage-svm01,', ',,'
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, $bad))
        } "*empty 'svm'*" 'Empty-cell validation failed.'
    }

    Invoke-NativeTest 'Invalid LUN ID is rejected' {
        $bad = $valid -replace '40 41 42', '40 BAD 42'
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, $bad))
        } '*invalid LUN ID*' 'Invalid-LUN validation failed.'
    }

    Invoke-NativeTest 'Duplicate LUN IDs are rejected' {
        $bad = $valid -replace '40 41 42', '40 41 40'
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, $bad))
        } '*duplicate LUN IDs*' 'Duplicate-LUN validation failed.'
    }

    Invoke-NativeTest 'A LUN group larger than one controller is rejected' {
        $tooMany = (0..15 | ForEach-Object { 100 + $_ }) -join ' '
        $bad = $valid -replace '40 41 42', $tooMany
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, $bad))
        } '*SCSI controller carries at most*' 'Controller-capacity validation failed.'
    }

    Invoke-NativeTest 'The same VM in two migration groups is rejected' {
        $second = $valid -replace ',labsql02,', ',labsql02b,'
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, $valid, $second))
        } '*repeats VM*' 'Cross-row duplicate VM validation failed.'
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, $valid, $valid))
        } '*repeats VM*' 'An identical row twice was accepted.'
    }

    Invoke-NativeTest 'Value lists tolerate padding and empty cells' {
        Assert-Equal (@(ConvertTo-ValueList '  A   B  ') -join '|') 'A|B' 'Padding was not collapsed.'
        Assert-Equal @(ConvertTo-ValueList '').Count 0 'An empty cell did not produce an empty list.'
        Assert-Equal @(ConvertTo-ValueList '   ').Count 0 'A whitespace cell did not produce an empty list.'
    }

    # -------------------------------------------------------------- run selection ----

    $selectionRows = @(
        $header,
        '2,labsql02,PROD,LABSQL01,LABSQL02 LABSQL03,lab-storage-svm01,,40 41,,,LAB-SQL-RP,LAB-VM-DATASTORES',
        '1,labsql02sit,SIT,LABSQLSIT01,LABSQLSIT02,lab-storage-svm01,,60 61,,,LAB-SIT-RP,LAB-SIT-DATASTORES',
        '1,labsql02dev,DEV,LABSQLDEV01,LABSQLDEV02,lab-storage-svm01,,70 71,,,LAB-DEV-RP,LAB-DEV-DATASTORES'
    )

    Invoke-NativeTest 'With no selector every row runs, in batch order' {
        $rows = @(Import-MigrationCsv -Path (New-TestCsv $selectionRows))
        $selection = Select-MigrationRows -Rows $rows
        Assert-Equal $selection.Rows.Count 3 'Not every row was selected.'
        Assert-Equal (@($selection.Rows | ForEach-Object { $_.first_vm }) -join ',') 'LABSQLSIT01,LABSQLDEV01,LABSQL01' 'Rows were not ordered by batch, then by CSV order.'
        Assert-True ($selection.Scope -like '*3 row*') "Unexpected scope '$($selection.Scope)'."
    }

    Invoke-NativeTest 'A batch selects only its own rows' {
        $rows = @(Import-MigrationCsv -Path (New-TestCsv $selectionRows))
        $selection = Select-MigrationRows -Rows $rows -Batch 1
        Assert-Equal $selection.Rows.Count 2 'Batch 1 did not select two rows.'
        Assert-Equal (@($selection.Rows | ForEach-Object { $_.workload_type }) -join ',') 'SIT,DEV' 'Batch 1 selected the wrong rows.'
        Assert-Equal (Select-MigrationRows -Rows $rows -Batch 1, 2).Rows.Count 3 'Two batches did not select every row.'
    }

    Invoke-NativeTest 'An unknown batch is rejected and says which exist' {
        $rows = @(Import-MigrationCsv -Path (New-TestCsv $selectionRows))
        Assert-ThrowsLike {
            Select-MigrationRows -Rows $rows -Batch 9
        } '*The file has batch 1, 2*' 'An empty batch was accepted.'
    }

    Invoke-NativeTest 'A VM name selects the one row it appears in' {
        $rows = @(Import-MigrationCsv -Path (New-TestCsv $selectionRows))
        $selection = Select-MigrationRows -Rows $rows -VMName 'LABSQL01'
        Assert-Equal $selection.Rows.Count 1 'Selecting by first VM did not return one row.'
        Assert-Equal $selection.Rows[0].first_vm 'LABSQL01' 'The wrong row was selected.'

        # A name from other_vms picks the same row - the whole cluster, not one node.
        $bySecondNode = Select-MigrationRows -Rows $rows -VMName 'labsql03'
        Assert-Equal $bySecondNode.Rows.Count 1 'Selecting by a non-first VM did not return one row.'
        Assert-Equal $bySecondNode.Rows[0].first_vm 'LABSQL01' 'A non-first VM name selected the wrong row.'
    }

    Invoke-NativeTest 'An unknown VM name is rejected' {
        $rows = @(Import-MigrationCsv -Path (New-TestCsv $selectionRows))
        Assert-ThrowsLike {
            Select-MigrationRows -Rows $rows -VMName 'NOSUCHVM'
        } "*No CSV row names VM 'NOSUCHVM'*" 'An unknown VM name was accepted.'
    }

    Invoke-NativeTest 'Selecting by VM and by batch at once is rejected' {
        $rows = @(Import-MigrationCsv -Path (New-TestCsv $selectionRows))
        Assert-ThrowsLike {
            Select-MigrationRows -Rows $rows -VMName 'LABSQL01' -Batch 1
        } '*not both*' 'Two selectors at once were accepted.'
    }

    # ------------------------------------------------------------- SCSI unit numbers ----

    Invoke-NativeTest 'SCSI unit allocation skips the reserved unit 7' {
        $units = @(Get-ScsiUnitNumberSequence -Count 9)
        Assert-Equal ($units -join ',') '0,1,2,3,4,5,6,8,9' 'Unit 7 was not skipped.'
    }

    Invoke-NativeTest 'SCSI unit allocation fills a controller exactly' {
        $units = @(Get-ScsiUnitNumberSequence -Count 15)
        Assert-Equal $units[-1] 15 'The last unit on a full controller is wrong.'
    }

    Invoke-NativeTest 'SCSI unit allocation refuses to overflow a controller' {
        Assert-ThrowsLike {
            Get-ScsiUnitNumberSequence -Count 16
        } '*cannot carry 16 disks*' 'Overflow was not rejected.'
    }

    # ------------------------------------------------------------------- change gate ----

    Invoke-NativeTest 'Dry run records the plan but does not invoke the operation' {
        $script:Plan = [System.Collections.Generic.List[object]]::new()
        $script:Results = [System.Collections.Generic.List[object]]::new()
        $script:OperationRan = $false
        $script:RunMode = 'DryRun'
        $DryRun = $true
        Invoke-PlannedChange 'G1' 'VM1' 'Test' 'Memory' 'dry-run test' {
            $script:OperationRan = $true
        }
        Assert-True (-not $script:OperationRan) 'The operation block ran during a dry run.'
        Assert-Equal $script:Plan.Count 1 'The plan item was not recorded.'
        Assert-Equal $script:Results[0].Status 'DryRun' 'Unexpected dry-run status.'
    }

    Invoke-NativeTest 'Execution invokes the operation and records it' {
        $script:Plan = [System.Collections.Generic.List[object]]::new()
        $script:Results = [System.Collections.Generic.List[object]]::new()
        $script:OperationRan = $false
        $script:RunMode = 'Execute'
        $DryRun = $false
        Invoke-PlannedChange 'G1' 'VM1' 'Test' 'Memory' 'execution test' {
            $script:OperationRan = $true
        }
        Assert-True $script:OperationRan 'The operation block did not run.'
        Assert-Equal $script:Results[0].Status 'Succeeded' 'Unexpected execution status.'
        Assert-Equal $script:Plan[0].ScriptVersion 'test' 'The plan row is not stamped with the script version.'
    }

    # ------------------------------------------------------- exact-name object lookup ----

    Invoke-NativeTest 'Result rows carry the workload type and batch of their migration group' {
        $script:Plan = [System.Collections.Generic.List[object]]::new()
        $script:Results = [System.Collections.Generic.List[object]]::new()
        $script:GroupInfoByName = @{ 'LABSQL01' = [pscustomobject]@{ WorkloadType = 'PROD'; Batch = 2 } }
        Add-Result 'LABSQL01' 'LABSQL01' 'Test' 'Passed' 'workload stamping'
        Add-Result 'unknown-group' '' 'Test' 'Passed' 'no workload type known'
        Assert-Equal $script:Results[0].WorkloadType 'PROD' 'The result row was not stamped with the workload type.'
        Assert-Equal $script:Results[0].Batch '2' 'The result row was not stamped with the batch.'
        Assert-Equal $script:Results[1].WorkloadType '' 'An unknown group produced something other than an empty workload type.'
        Assert-Equal $script:Results[1].Batch '' 'An unknown group produced something other than an empty batch.'
        $script:GroupInfoByName = @{}
    }

    Invoke-NativeTest 'Exact-name lookup returns the single match' {
        $found = Get-ExactObject -Name 'LABSQL01' -ObjectType 'VM' -Lookup {
            @([pscustomobject]@{ Name = 'LABSQL01' }, [pscustomobject]@{ Name = 'LABSQL02' })
        }
        Assert-Equal $found.Name 'LABSQL01' 'The wrong object was returned.'
    }

    Invoke-NativeTest 'Exact-name lookup is case-sensitive' {
        Assert-ThrowsLike {
            Get-ExactObject -Name 'LABSQL01' -ObjectType 'VM' -Lookup {
                @([pscustomobject]@{ Name = 'labsql01' })
            }
        } '*found 0*' 'A case-different name was accepted.'
    }

    Invoke-NativeTest 'Exact-name lookup can be case-insensitive for a derived name' {
        $found = Get-ExactObject -Name 'labsql02_i_rdm' -ObjectType 'datastore' -CaseInsensitive -Lookup {
            @([pscustomobject]@{ Name = 'LABSQL02_I_RDM' })
        }
        Assert-Equal $found.Name 'LABSQL02_I_RDM' 'A derived name did not match without case.'
    }

    Invoke-NativeTest 'Exact-name lookup refuses an ambiguous match' {
        Assert-ThrowsLike {
            Get-ExactObject -Name 'LABSQL01' -ObjectType 'VM' -Lookup {
                @([pscustomobject]@{ Name = 'LABSQL01' }, [pscustomobject]@{ Name = 'LABSQL01' })
            }
        } '*found 2*' 'An ambiguous name was accepted.'
    }

    # -------------------------------------------------------------- structural guards ----

    Invoke-NativeTest 'Every mutating VMware call sits inside a planned change' {
        $plannedBlocks = @(
            Get-CommandAst -Ast $ast -Name 'Invoke-PlannedChange' |
                ForEach-Object {
                    $_.CommandElements |
                        Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }
                }
        )
        Assert-True ($plannedBlocks.Count -gt 0) 'No planned-change operation blocks were found at all.'

        $mutating = @(
            'Remove-HardDisk',
            'Remove-SharedScsiController',
            'Move-VM',
            'Start-VM',
            'Stop-VM',
            'Stop-VMGuest',
            'New-SharedScsiController',
            'Add-RdmDevice'
        )
        $unguarded = @(
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                Where-Object { $mutating -contains $_.GetCommandName() } |
                Where-Object {
                    $call = $_
                    $inside = @(
                        $plannedBlocks |
                            Where-Object {
                                ($call.Extent.StartOffset -ge $_.Extent.StartOffset) -and
                                ($call.Extent.EndOffset -le $_.Extent.EndOffset)
                            }
                    )
                    $inside.Count -eq 0
                } |
                ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.GetCommandName())" }
        )
        Assert-Equal $unguarded.Count 0 "Unguarded mutating calls: $($unguarded -join '; ')."
    }

    Invoke-NativeTest 'Power-on happens once, batched by workload type' {
        $powerOnFunction = @($functionAsts | Where-Object { $_.Name -eq 'Invoke-WorkloadPowerOn' })
        Assert-Equal $powerOnFunction.Count 1 'Invoke-WorkloadPowerOn is missing.'
        $startCalls = @(Get-CommandAst -Ast $ast -Name 'Start-VM')
        Assert-True ($startCalls.Count -gt 0) 'Nothing powers a VM on at all.'
        $outside = @(
            $startCalls |
                Where-Object {
                    ($_.Extent.StartOffset -lt $powerOnFunction[0].Extent.StartOffset) -or
                    ($_.Extent.EndOffset -gt $powerOnFunction[0].Extent.EndOffset)
                } |
                ForEach-Object { "line $($_.Extent.StartLineNumber)" }
        )
        Assert-Equal $outside.Count 0 "Start-VM is called outside the workload power-on phase: $($outside -join ', ')."
    }

    Invoke-NativeTest 'Controllers are found in the device list, never via Get-ScsiController' {
        # Get-ScsiController returns the controllers of a VM's HARD DISKS. Emptying a
        # controller therefore removes it from that cmdlet's output, and a live run died
        # with "SCSI controller bus 1 is no longer attached" one line after detaching the
        # only RDM on it.
        $scsiControllerCalls = @(Get-CommandAst -Ast $ast -Name 'Get-ScsiController')
        Assert-Equal $scsiControllerCalls.Count 0 'Get-ScsiController is back; it cannot see an empty controller.'
        Assert-True ($text -match '(?m)^function Remove-SharedScsiController') 'The device-spec controller removal is missing.'
        Assert-True ($text -match '\[VMware\.Vim\.VirtualSCSIController\]') 'Controllers are not matched by device type.'
    }

    Invoke-NativeTest 'SCSI 0 is kept, every other SCSI controller goes with the LUNs' {
        Assert-True ($text -match '\[int\]\$_\.BusNumber -ne 0') 'Controller removal is not scoped to the non-zero buses.'
        Assert-True ($text -match 'this tool will not touch the bus 0 controller') 'The SCSI 0 guard is missing.'

        # A controller that carried a LUN goes with it; one that carried none is left
        # alone, empty or not, because removing it would detach whatever is on it.
        Assert-True ($text -match 'carries no LUN from this migration') 'The leave-it-alone rule for LUN-less controllers is missing.'
    }

    Invoke-NativeTest 'A failure is reported against the line that failed' {
        # Write-RichoLog ERROR calls Write-Error, which under $ErrorActionPreference =
        # 'Stop' becomes the terminating error itself - so the rethrow never ran and the
        # console blamed the logging line.
        Assert-True ($text -match '-Level ERROR -ErrorAction Continue') 'The fatal log line can still swallow the real error.'
        Assert-True ($text -match '(?m)^\s*throw \$failure') 'The original error is not rethrown.'
    }

    Invoke-NativeTest 'Long operations report progress instead of going quiet' {
        Assert-True ($text -match '(?m)^function Wait-VMLongTask') 'The task progress helper is missing.'
        Assert-True ($text -match 'Write-Progress') 'Nothing drives a progress bar.'
        Assert-True ($text -match 'RunAsync    = \$true') 'The cold relocate does not run as a task, so its percentage cannot be reported.'
        Assert-True ($text -match 'still waiting for') 'The guest shutdown wait has no heartbeat.'

        # The host storage scan is the slowest phase of a dry run; it has to name the host
        # before the read, not only after it.
        Assert-True ($text -match 'reading storage paths and devices') 'The host storage scan says nothing before it reads.'
    }

    Invoke-NativeTest 'There are two modes and one gate between them' {
        Assert-True ($text -match "ParameterSetName = 'DryRun'") 'The DryRun parameter set is missing.'
        Assert-True ($text -match "ParameterSetName = 'Execute'") 'The Execute parameter set is missing.'
        Assert-True ($text -notmatch '\[CmdletBinding\(SupportsShouldProcess') 'SupportsShouldProcess is back; the gate is meant to be -DryRun alone.'
        Assert-True ($text -notmatch '\.ShouldProcess\(') 'A ShouldProcess call is back; the gate is meant to be -DryRun alone.'
        $gates = @([regex]::Matches($text, '(?m)^\s*if \(\$DryRun\) \{\s*$'))
        Assert-True ($gates.Count -ge 1) 'The dry-run gate was not found.'
    }

    Invoke-NativeTest 'Script is self-contained enough to run from a jump host' {
        Assert-True ($text -notmatch 'Richo\.Common\.psd1') 'The script still imports the shared module by path.'
        Assert-True ($text -notmatch '(?m)^\s*Import-Module(?!\s+-Name \$name)') 'An unguarded module import was found.'
        Assert-True ($text -match 'VMware\.VimAutomation\.Core') 'PowerCLI Core is not the declared dependency.'
        Assert-True ($text -match '(?m)^function Write-RichoLog') 'The script does not carry its own logging function.'
        Assert-True ($text -match '(?m)^function Get-RichoCredential') 'The script does not carry its own credential helper.'
        Assert-True ($text -notmatch '(?i)environments\.json') 'The script reads an environment configuration file.'
        Assert-True ($text -notmatch '(?i)Install-Module|Update-Module') 'The script installs or updates a module.'
    }

    Invoke-NativeTest 'Output goes through Write-RichoLog, never Write-Host' {
        Assert-True ($text -notmatch '(?m)^\s*Write-Host') 'A Write-Host call was found.'
        Assert-True ($text -match 'Write-RichoLog') 'No Write-RichoLog call was found.'
    }

    Invoke-NativeTest 'Reserved automatic Host variable is not assigned' {
        Assert-True ($text -notmatch '(?im)^\s*\$host\s*=') 'An assignment to $Host was found.'
    }

    Invoke-NativeTest 'RDM removal never requests permanent deletion' {
        Assert-True ($text -notmatch 'DeletePermanently:\$true') 'Permanent RDM deletion was found.'
        Assert-True ($text -match 'DeletePermanently:\$false') 'Safe RDM removal flag was not found.'
    }

    Invoke-NativeTest 'Hard power-off requires explicit opt-in guard' {
        Assert-True ($text -match '\$ForcePowerOffIfGuestShutdownUnavailable') 'Opt-in switch is missing.'
        Assert-True ($text -match 'if \(-not \$ForcePowerOffIfGuestShutdownUnavailable\)') 'Opt-in guard is missing.'
        Assert-True ($text -match 'Stop-VM[\s\S]*?-Kill') 'Guarded hard power-off action is missing.'
    }

    Invoke-NativeTest 'RDM attach sets the SCSI unit in the device spec, not afterwards' {
        Assert-True ($text -match '\$disk\.UnitNumber = \$UnitNumber') 'The add spec does not set the unit number.'
        Assert-True ($text -notmatch 'function Set-HardDiskUnitNumber') 'The unsupported post-attach unit-number edit is back.'
        Assert-True ($text -notmatch '(?m)^\s*New-HardDisk') 'RDMs are being added with New-HardDisk, which cannot pick the unit.'
    }

    Invoke-NativeTest 'Destination controller type comes from the source, not a hardcoded PVSCSI' {
        Assert-True ($text -notmatch 'New-Object VMware\.Vim\.ParaVirtualSCSIController') 'The controller type is hardcoded to PVSCSI.'
        Assert-True ($text -match 'New-Object -TypeName \$ControllerTypeName') 'The controller is not built from the source type.'
        Assert-True ($text -match 'ControllerType = \$controller\.GetType\(\)\.FullName') 'The source controller type is not recorded.'
    }

    Invoke-NativeTest 'Destination LUN capacity is checked against the RDM it replaces' {
        Assert-True ($text -match 'CapacityToleranceGB') 'No capacity tolerance is defined.'
        Assert-True ($text -match 'but the RDM it replaces at SCSI') 'No capacity comparison against the source RDM was found.'
    }

    Invoke-NativeTest 'RDM discovery matches device types rather than duck-typing a backing' {
        Assert-True ($text -match '\[VMware\.Vim\.VirtualDiskRawDiskMappingVer1BackingInfo\]') 'RDM backings are not matched by type.'
        Assert-True ($text -match '\$device -isnot \[VMware\.Vim\.VirtualDisk\]') 'Non-disk devices are not filtered out before the backing is read.'
    }

    Invoke-NativeTest 'Power-order CSV column is not required' {
        Assert-True ($header -notmatch 'power_on_order') 'Sample header still contains a power-order column.'
        Assert-True ($text -notmatch "'power_on_order_space_separated'") 'Script still requires a power-order column.'
    }

    Invoke-NativeTest 'Operator CSV does not require NAA values' {
        Assert-True ($header -notmatch '(?i)naa') 'Operator CSV unexpectedly contains an NAA column.'
        Assert-True ($text -match 'Resolve-DestinationLun') 'Internal device resolution function is missing.'
    }

    Write-Host ''
    Write-Host 'Native test summary' -ForegroundColor Cyan
    Write-Host "  Passed: $script:Passed"
    Write-Host "  Failed: $script:Failed"

    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    foreach ($path in $script:TempFiles) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}
