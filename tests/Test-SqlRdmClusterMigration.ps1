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
        'Get-OptionalProperty',
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

    Invoke-NativeTest 'Rows commented out with # are skipped, and never validated' {
        # The junk row must not be validated: hashing a row out is how one line of a
        # sheet is taken out of a night's work, and it has to work on a row that would
        # otherwise fail validation.
        $rows = @(Import-MigrationCsv -Path (New-TestCsv @($header, "#$valid", $valid, '#nonsense,,,,,,,,,,,')))
        Assert-Equal $rows.Count 1 'Exactly one row should have survived the hashes.'
        Assert-Equal $rows[0].first_vm 'LABSQL01' 'The wrong row survived.'

        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, "#$valid"))
        } '*Every row in the CSV is commented out*' 'An all-commented CSV was accepted.'
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
        Assert-Equal (Format-Elapsed -Elapsed ([timespan]::FromSeconds(4.26))) '4.3s' 'Seconds are wrong.'
        Assert-Equal (Format-Elapsed -Elapsed ([timespan]::FromSeconds(0.5))) '0.5s' 'Sub-second is wrong.'
        Assert-Equal (Format-Elapsed -Elapsed ([timespan]::FromSeconds(90))) '1m 30s' 'Minutes are wrong.'
        Assert-Equal (Format-Elapsed -Elapsed ([timespan]::FromSeconds(150))) '2m 30s' 'Minutes are wrong just past the half.'
        Assert-Equal (Format-Elapsed -Elapsed ([timespan]::FromMinutes(75))) '1h 15m' 'Hours are wrong.'
        Assert-Equal (Format-Elapsed -Elapsed ([timespan]::FromMinutes(90))) '1h 30m' 'Hours are wrong on the half hour.'
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

        # Helpers that exist only to be the body of a planned change. Their own extents
        # count as guarded, and every call to one has to sit inside a planned block -
        # checked below, so this does not become a hole in the gate.
        $plannedHelpers = @('Stop-VMForMigrationHard')
        $guardedRegions = [System.Collections.Generic.List[object]]::new()
        foreach ($block in $plannedBlocks) { $guardedRegions.Add($block) }
        foreach ($helperName in $plannedHelpers) {
            $helper = @($functionAsts | Where-Object { $_.Name -eq $helperName })
            Assert-Equal $helper.Count 1 "$helperName is missing."
            $guardedRegions.Add($helper[0])

            $helperCalls = @(Get-CommandAst -Ast $ast -Name $helperName)
            Assert-True ($helperCalls.Count -gt 0) "$helperName is defined but never called."
            foreach ($helperCall in $helperCalls) {
                $enclosing = @(
                    $plannedBlocks |
                        Where-Object {
                            ($helperCall.Extent.StartOffset -ge $_.Extent.StartOffset) -and
                            ($helperCall.Extent.EndOffset -le $_.Extent.EndOffset)
                        }
                )
                Assert-True ($enclosing.Count -gt 0) "$helperName is called outside a planned change at line $($helperCall.Extent.StartLineNumber)."
            }
        }

        $mutating = @(
            'Remove-HardDisk',
            'Remove-SharedScsiController',
            'New-RdmDiskGroup',
            'Move-VM',
            'Start-VM',
            'Stop-VM',
            'Stop-VMGuest'
        )
        $unguarded = @(
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                Where-Object { $mutating -contains $_.GetCommandName() } |
                Where-Object {
                    $call = $_
                    $inside = @(
                        $guardedRegions |
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

    Invoke-NativeTest 'Power-on is the operator''s call, not a switch' {
        Assert-True ($text -notmatch 'PowerOnAfterMigration') 'The power-on switch is back.'
        Assert-True ($text -match '(?m)^function Show-RdmMapping') 'The mapping summary is missing.'
        Assert-True ($text -match '(?m)^function Request-PowerOnConfirmation') 'The confirmation prompt is missing.'
        Assert-True ($text -match "-match '\^\(y\|yes\)\$'") 'Anything but an explicit yes should mean no.'

        # The mapping has to be on screen before the question is asked.
        $showIndex = $text.IndexOf('Show-RdmMapping -GroupPlan $groupPlan')
        $askIndex = $text.IndexOf('Request-PowerOnConfirmation -GroupPlan $groupPlan')
        Assert-True ($showIndex -ge 0) 'The mapping is never shown in the run.'
        Assert-True (($askIndex -gt $showIndex)) 'The operator is asked before the mapping is shown.'
    }

    Invoke-NativeTest 'A dry run ends with a verdict, and the command that follows it' {
        Assert-True ($text -match '(?m)^function Add-DryRunNotice') 'Notices have nowhere to go.'
        Assert-True ($text -match '(?m)^function Format-ExecuteCommand') 'The follow-on command is never built.'
        Assert-True ($text -match 'DRY RUN COMPLETE') 'A finished dry run never says it finished.'
        Assert-True ($text -match 'DRY RUN COMPLETED SUCCESSFULLY - nothing flagged\. Ready to execute\.') 'A clean dry run never gives a verdict.'
        Assert-True ($text -match 'thing\(s\) flagged\. Read them before you execute') 'Flagged items are not called out.'
        Assert-True ($text -match 'none could be: a dry run maps no LUNs') 'A dry run never explains why nothing was powered on.'
        Assert-True ($text -match 'expected, not a failure') 'A dry run never says the absent power-on is expected.'
        Assert-True ($text -notmatch 'Add-DryRunBlocker') 'The old blocker mechanism is still here.'
    }

    Invoke-NativeTest 'Power-on happens once per line item, after it is verified' {
        $powerOnFunction = @($functionAsts | Where-Object { $_.Name -eq 'Invoke-GroupPowerOn' })
        Assert-Equal $powerOnFunction.Count 1 'Invoke-GroupPowerOn is missing.'
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

    Invoke-NativeTest 'Removal finds controllers in the device list, not via Get-ScsiController' {
        # Get-ScsiController returns the controllers of a VM's HARD DISKS. Emptying a
        # controller therefore removes it from that cmdlet's output, and a live run died
        # with "SCSI controller bus 1 is no longer attached" one line after detaching the
        # only RDM on it. It is still the right cmdlet for asking which controller a disk
        # is on, which is all the mapping sequence uses it for.
        $byVM = @(
            Get-CommandAst -Ast $ast -Name 'Get-ScsiController' |
                Where-Object { $_.Extent.Text -notmatch '-HardDisk' } |
                ForEach-Object { "line $($_.Extent.StartLineNumber)" }
        )
        Assert-Equal $byVM.Count 0 "Get-ScsiController is being asked for a VM's controllers: $($byVM -join ', ')."
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

    Invoke-NativeTest 'No local in the main body shadows a script-scope variable' {
        # SHIPPED. PowerShell variable names are case-insensitive, so at script scope
        # $verification IS $script:Verification - a local of that name in the main body
        # replaced the results list with an array, and every execution run died writing
        # its evidence. Assignments inside functions are safe; only the main body shares
        # the script scope.
        $functions = @($functionAsts)
        $scriptScoped = @(
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                Where-Object { $_.VariablePath.IsScript } |
                ForEach-Object { ($_.VariablePath.UserPath -replace '^script:', '').ToLower() } |
                Select-Object -Unique
        )
        $shadowed = @(
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
                Where-Object { $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] } |
                Where-Object { -not $_.Left.VariablePath.IsScript } |
                Where-Object {
                    $node = $_
                    $inside = @($functions | Where-Object {
                        ($node.Extent.StartOffset -ge $_.Extent.StartOffset) -and ($node.Extent.EndOffset -le $_.Extent.EndOffset)
                    })
                    $inside.Count -eq 0
                } |
                Where-Object { $scriptScoped -contains $_.Left.VariablePath.UserPath.ToLower() } |
                ForEach-Object { "line $($_.Extent.StartLineNumber): `$$($_.Left.VariablePath.UserPath)" }
        )
        Assert-Equal $shadowed.Count 0 "Locals in the main body shadow script-scope state: $($shadowed -join '; ')."
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
        Assert-True ($text -match 'RelocateVM_Task') 'The cold relocate does not run as a task, so its percentage cannot be reported.'
        Assert-True ($text -match 'still waiting for') 'The guest shutdown wait has no heartbeat.'

        Assert-True ($text -match 'Resolving \$\(\$LunIds\.Count\) LUN\(s\)') 'The LUN resolution says nothing before it reads the host.'
        Assert-True ($text -match '(?m)^function Assert-DrsPlacement') 'The DRS placement assumption is not asserted anywhere.'
        Assert-True ($text -notmatch 'Get-EligibleDestinationHosts') 'The per-host datastore eligibility scan is back.'

        # Placement is vCenter's job, both halves of it. Nothing here should be asking
        # about hosts at all.
        $hostCalls = @(Get-CommandAst -Ast $ast -Name 'Get-VMHost')
        Assert-Equal $hostCalls.Count 0 'Get-VMHost is back; DRS decides where these VMs land.'
    }

    Invoke-NativeTest 'The relocate hands vCenter a spec it can accept' {
        # SHIPPED AND HIT ON A LIVE RUN: Move-VM with a cluster destination and a
        # datastore cluster put a StoragePod reference in RelocateSpec.datastore, which
        # only accepts a Datastore, and vCenter rejected the spec outright.
        $moveCalls = @(Get-CommandAst -Ast $ast -Name 'Move-VM')
        Assert-Equal $moveCalls.Count 0 'Move-VM is back; it cannot be handed a datastore cluster with a cluster destination.'
        Assert-True ($text -match '(?m)^function Get-StorageDrsDatastore') 'Nothing resolves the datastore cluster to a datastore.'
        Assert-True ($text -match '(?m)^function Get-DrsRecommendedHost') 'Nothing asks DRS for a host.'
        Assert-True ($text -match '(?m)^function Move-VMToDestination') 'The relocate has no implementation.'

        $relocate = @($functionAsts | Where-Object { $_.Name -eq 'Move-VMToDestination' })
        Assert-Equal $relocate.Count 1 'Move-VMToDestination is missing.'
        $relocateText = $relocate[0].Extent.Text
        Assert-True ($relocateText -match 'VirtualMachineRelocateSpec') 'The relocate spec is not built explicitly.'
        Assert-True ($relocateText -match '\$relocateSpec\.Datastore = ') 'The relocate spec names no datastore.'
        Assert-True ($relocateText -match '\$relocateSpec\.Pool = ') 'The relocate spec names no resource pool.'
        Assert-True ($relocateText -match 'Get-StorageDrsDatastore') 'The datastore is not the one Storage DRS chose.'
        Assert-True ($relocateText -match 'RelocateVM_Task') 'The relocate is not run as a task.'

        # The pool comes from the CSV, so the VM lands where it belongs in one step.
        $poolMoves = @(
            $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
            }, $true) |
                Where-Object { "$($_.Member)" -eq 'MoveIntoResourcePool' }
        )
        Assert-Equal $poolMoves.Count 0 'The VM is still being moved into its pool as a second step.'

        # Storage DRS is asked for a real datastore, and a pod reference never reaches
        # the spec.
        $storage = @($functionAsts | Where-Object { $_.Name -eq 'Get-StorageDrsDatastore' })
        $storageText = $storage[0].Extent.Text
        Assert-True ($storageText -match 'RecommendDatastores') 'Storage DRS is never asked.'
        Assert-True ($storageText -match 'StoragePlacementSpec') 'No placement spec is built.'
        Assert-True ($storageText -match 'FreeSpaceGB') 'There is no fallback when Storage DRS declines.'
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

    Invoke-NativeTest 'A VM in the list goes down: politely if it can, hard if it will not' {
        Assert-True ($text -notmatch 'PowerAction') 'The power-action switch is back.'
        Assert-True ($text -notmatch 'ForcePowerOffIfGuestShutdownUnavailable') 'The hard power-off opt-in is back.'
        Assert-True ($text -notmatch 'ShutdownTimeoutMinutes') 'The old minute-based timeout is still here.'
        Assert-True ($text -match '\[int\]\$GuestShutdownTimeoutSeconds = 30') 'The guest gets something other than 30 seconds by default.'

        $stopFunction = @($functionAsts | Where-Object { $_.Name -eq 'Stop-VMForMigration' })
        Assert-Equal $stopFunction.Count 1 'Stop-VMForMigration is missing.'
        $stopText = $stopFunction[0].Extent.Text

        # No Tools is a hard power-off, not a stop.
        Assert-True ($stopText -match 'if \(-not \$toolsRunning\)') 'The no-Tools case is not handled first.'
        Assert-True ($stopText -notmatch '(?m)^\s*throw ') 'A powered-on VM can still stop the run instead of going down.'
        Assert-True ($stopText -match 'Add-DryRunNotice') 'A hard power-off is not flagged in a dry run.'

        # Tools running means ask, wait, then kill - in that order.
        $askIndex = $stopText.IndexOf('Stop-VMGuest')
        $waitIndex = $stopText.IndexOf('Wait-VMPowerOff')
        $killIndex = $stopText.LastIndexOf('Stop-VMForMigrationHard')
        Assert-True ($askIndex -ge 0) 'Nothing ever asks the guest to shut down.'
        Assert-True (($waitIndex -gt $askIndex)) 'The wait does not follow the request.'
        Assert-True (($killIndex -gt $waitIndex)) 'The hard power-off does not follow the wait.'

        # The kill is confirmed, not assumed: an RDM will not detach from a VM vCenter
        # still believes is running.
        $hardFunction = @($functionAsts | Where-Object { $_.Name -eq 'Stop-VMForMigrationHard' })
        Assert-Equal $hardFunction.Count 1 'Stop-VMForMigrationHard is missing.'
        $hardText = $hardFunction[0].Extent.Text
        Assert-True ($hardText -match 'Stop-VM .*-Kill') 'The hard power-off does not kill the VM.'
        Assert-True ($hardText -match 'Wait-VMPowerOff') 'The hard power-off is not confirmed.'
        Assert-True ($hardText -match '(?m)^\s*throw ') 'A VM that never powers off does not stop the run.'
    }

    Invoke-NativeTest 'Mapping follows the estate''s proven sequence, in order' {
        # Disk first, controller created FROM that disk, unit forced to 0 by an edit spec,
        # then the rest of the group onto the same controller. Hand-built device specs
        # replaced this once and vCenter refused them.
        $mapFunction = @($functionAsts | Where-Object { $_.Name -eq 'New-RdmDiskGroup' })
        Assert-Equal $mapFunction.Count 1 'New-RdmDiskGroup is missing.'
        $mapText = $mapFunction[0].Extent.Text

        $steps = @(
            'New-HardDisk -VM \$currentFirstVM -DeviceName \$deviceNames\[0\]',
            'New-ScsiController -HardDisk \$firstDisk',
            '\$unitSpec\.DeviceChange\[0\]\.Operation = ''edit''',
            '\$unitSpec\.DeviceChange\[0\]\.Device\.UnitNumber = 0',
            'New-HardDisk .* -Controller \$controller'
        )
        $position = 0
        foreach ($step in $steps) {
            $match = [regex]::Match($mapText.Substring($position), $step)
            Assert-True $match.Success "The mapping sequence is missing, or out of order at: $step"
            $position += $match.Index + 1
        }

        Assert-True ($mapText -match 'ReconfigVM\(\$copySpec\)') 'The other nodes do not receive the copy spec.'
    }

    Invoke-NativeTest 'Controller type and bus sharing are mapped from the source' {
        Assert-True ($text -match '(?m)^function ConvertTo-PowerCliControllerType') 'The controller type mapping is missing.'
        Assert-True ($text -match '(?m)^function ConvertTo-PowerCliBusSharing') 'The bus sharing mapping is missing.'
        Assert-True ($text -match 'ControllerType = \$controller\.GetType\(\)\.FullName') 'The source controller type is not recorded.'
        Assert-True ($text -match 'ConvertTo-PowerCliControllerType -ControllerTypeName \$controllerRecord\[0\]\.ControllerType') 'The mapping is not fed from the source controller.'
    }

    Invoke-NativeTest 'Optional SDK properties are read without assuming they exist' {
        # SHIPPED. VirtualDisk.Sharing is newer than some bindings in the field, and under
        # Set-StrictMode reading a property the object does not have is a terminating
        # error - discovery died on the first VM it looked at.
        $withSharing = [pscustomobject]@{ Sharing = 'sharingMultiWriter' }
        $withoutSharing = [pscustomobject]@{ Label = 'Hard disk 2' }

        Assert-Equal (Get-OptionalProperty -InputObject $withSharing -Name 'Sharing' -Default '') 'sharingMultiWriter' 'A present property was not returned.'
        Assert-Equal (Get-OptionalProperty -InputObject $withoutSharing -Name 'Sharing' -Default '') '' 'An absent property did not fall back to the default.'
        Assert-Equal (Get-OptionalProperty -InputObject $null -Name 'Sharing' -Default 'none') 'none' 'A null object did not fall back to the default.'

        # Scoped to the function that reads devices back from vCenter. Properties the
        # script sets on a backing it built itself are its own and cannot be missing.
        $layoutFunction = @($functionAsts | Where-Object { $_.Name -eq 'Get-VMRdmLayout' })
        Assert-Equal $layoutFunction.Count 1 'Get-VMRdmLayout is missing.'
        $layoutText = $layoutFunction[0].Extent.Text
        foreach ($direct in @('\$device\.Sharing', '\$device\.CapacityInBytes', '\$backing\.LunUuid', '\$backing\.DiskMode')) {
            Assert-True ($layoutText -notmatch $direct) "An optional property is read directly from a device vCenter returned: $direct"
        }
    }

    Invoke-NativeTest 'Verification checks what can be known after the mapping' {
        Assert-True ($text -match 'CapacityToleranceGB') 'No capacity tolerance is defined.'
        Assert-True ($text -match 'the RDMs it replaces were') 'Verification does not compare capacity against the source.'
        Assert-True ($text -match 'is not the same device on every node') 'Verification does not compare devices across the nodes.'
    }

    Invoke-NativeTest 'Host storage is read once, to resolve LUN IDs at mapping time' {
        # The LUNs are assumed present. The host is read to answer "which device is LUN
        # 40", never to check that it is there - and only on the VM's own host.
        $mapFunction = @($functionAsts | Where-Object { $_.Name -eq 'New-RdmDiskGroup' })
        Assert-Equal $mapFunction.Count 1 'New-RdmDiskGroup is missing.'

        foreach ($name in @('Get-EsxCli', 'Get-ScsiLun')) {
            $calls = @(Get-CommandAst -Ast $ast -Name $name)
            Assert-True ($calls.Count -gt 0) "$name is not called at all; LUN IDs cannot be resolved."
            $outside = @(
                $calls |
                    Where-Object {
                        ($_.Extent.StartOffset -lt $mapFunction[0].Extent.StartOffset) -or
                        ($_.Extent.EndOffset -gt $mapFunction[0].Extent.EndOffset)
                    } |
                    ForEach-Object { "line $($_.Extent.StartLineNumber)" }
            )
            Assert-Equal $outside.Count 0 "$name is called outside the mapping sequence: $($outside -join ', ')."
        }

        Assert-True ($text -match 'PREREQUISITE, assumed and not checked') 'The prerequisite is not printed for the engineer.'
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
        # The device comes from the LUN ID and the SVM, resolved on the host - never from
        # the RDM that was detached, whose backing carries a vml identifier that does not
        # compare with the naa the host reports.
        Assert-True ($text -match 'TargetIdentifier -like') 'LUN IDs are not resolved against the SVM path list.'
        Assert-True ($text -match 'ConsoleDeviceName') 'The console device name is not used for the attach.'
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
