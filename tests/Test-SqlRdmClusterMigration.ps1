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
    [string]$ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vsphere/Invoke-SqlRdmClusterMigration.ps1'),

    [Parameter()]
    [string]$SampleCsvPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vsphere/SqlRdmClusterMigration.Sample.csv')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:TempFiles = [System.Collections.Generic.List[string]]::new()

# Scope the loaded helpers expect to find. In the script these are set from the parameters
# and from $PSCmdlet; here they are set by each test.
$ScriptVersion = 'test'
$DryRun = $true
$script:Cmdlet = $null
$script:RunMode = 'DryRun'
$script:NoOpRun = $true
$script:MaxScsiUnitNumber = 15
$script:ReservedScsiUnitNumber = 7
$script:CapacityToleranceGB = 1
$script:Plan = [System.Collections.Generic.List[object]]::new()
$script:Results = [System.Collections.Generic.List[object]]::new()

function Write-RichoLog {
    # Stub. The real one lives in Richo.Common, which these tests deliberately do not load.
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
        'Add-Result',
        'Confirm-Change',
        'Invoke-PlannedChange',
        'Get-ExactObject',
        'Get-ScsiUnitNumberSequence',
        'Import-MigrationCsv'
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

    $header = 'vsphere_cluster,first_vm,other_vms_space_separated,svm,iSCSI_Data_Store,group_1_lun_IDs_ordered_space_separated,group_2_lun_IDs_ordered_space_separated,group_3_lun_IDs_ordered_space_separated,destination_resource_pool,destination_datastore_cluster'
    $valid = 'LAB-SQL-CLUSTER,LABSQL01,LABSQL02 LABSQL03,lab-storage-svm01,LAB-RDM-POINTERS,40 41 42,50 51,,LAB-SQL-RP,LAB-VM-DATASTORES'

    # ---------------------------------------------------------------- CSV validation ----

    Invoke-NativeTest 'Grouped-LUN CSV is accepted' {
        $rows = @(Import-MigrationCsv -Path (New-TestCsv @($header, $valid)))
        Assert-Equal $rows.Count 1 'Unexpected row count.'
        Assert-Equal $rows[0].first_vm 'LABSQL01' 'Unexpected first VM.'
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

    Invoke-NativeTest 'Duplicate migration-group rows are rejected' {
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, $valid, $valid))
        } '*duplicate vsphere_cluster*' 'Duplicate-group validation failed.'
    }

    Invoke-NativeTest 'The same VM in two migration groups is rejected' {
        $second = $valid -replace '^LAB-SQL-CLUSTER', 'LAB-SQL-CLUSTER-2'
        Assert-ThrowsLike {
            Import-MigrationCsv -Path (New-TestCsv @($header, $valid, $second))
        } '*repeats VM*' 'Cross-row duplicate VM validation failed.'
    }

    Invoke-NativeTest 'Value lists tolerate padding and empty cells' {
        Assert-Equal (@(ConvertTo-ValueList '  A   B  ') -join '|') 'A|B' 'Padding was not collapsed.'
        Assert-Equal @(ConvertTo-ValueList '').Count 0 'An empty cell did not produce an empty list.'
        Assert-Equal @(ConvertTo-ValueList '   ').Count 0 'A whitespace cell did not produce an empty list.'
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
        $script:Cmdlet = $null
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
        $script:Cmdlet = $null
        $script:RunMode = 'Execute'
        $DryRun = $false
        Invoke-PlannedChange 'G1' 'VM1' 'Test' 'Memory' 'execution test' {
            $script:OperationRan = $true
        }
        Assert-True $script:OperationRan 'The operation block did not run.'
        Assert-Equal $script:Results[0].Status 'Succeeded' 'Unexpected execution status.'
        Assert-Equal $script:Plan[0].ScriptVersion 'test' 'The plan row is not stamped with the script version.'
    }

    Invoke-NativeTest 'A refused ShouldProcess skips the operation but keeps the plan' {
        $script:Plan = [System.Collections.Generic.List[object]]::new()
        $script:Results = [System.Collections.Generic.List[object]]::new()
        $script:OperationRan = $false
        $script:RunMode = 'WhatIf'
        $DryRun = $false
        $script:Cmdlet = New-Object psobject
        Add-Member -InputObject $script:Cmdlet -MemberType ScriptMethod -Name ShouldProcess -Value {
            param($Target, $Action)
            return $false
        }
        Invoke-PlannedChange 'G1' 'VM1' 'Test' 'Memory' 'whatif test' {
            $script:OperationRan = $true
        }
        $script:Cmdlet = $null
        Assert-True (-not $script:OperationRan) 'The operation ran even though ShouldProcess said no.'
        Assert-Equal $script:Plan.Count 1 'The plan item was not recorded.'
        Assert-Equal $script:Results[0].Status 'Skipped' 'Unexpected skipped status.'
    }

    # ------------------------------------------------------- exact-name object lookup ----

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
            'Remove-ScsiController',
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

    Invoke-NativeTest 'Script supports ShouldProcess, so -WhatIf is a real no-op' {
        Assert-True ($text -match '(?i)\[CmdletBinding\(SupportsShouldProcess') 'SupportsShouldProcess is not declared.'
        Assert-True ($text -match '\$script:Cmdlet\.ShouldProcess\(') 'The change gate never asks ShouldProcess.'
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
