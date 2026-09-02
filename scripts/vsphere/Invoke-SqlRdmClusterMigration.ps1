<#
.SYNOPSIS
    Plans or performs a cold migration of clustered SQL VMs that use physical-mode RDMs.

.DESCRIPTION
    Consumes the grouped-LUN CSV format. Destination devices are selected using SVM plus
    LUN ID and are then verified internally by canonical device identity and capacity, so
    the operator never types an NAA value.

    The CSV names only where the VMs are going. The VMs themselves are found by name
    across the vCenter - each name must match exactly one VM - and where they are now is
    read off them and recorded as evidence rather than asserted in the CSV. A migration
    group is named after its first VM.

    Per migration group the script:

      1. Resolves the destination cluster, resource pool, datastore cluster and RDM
         pointer datastore, and the eligible destination hosts that can see all of them
         plus every LUN in the CSV.
      2. Reads the source RDM topology from the first VM and proves every other VM in the
         group matches it - same controller bus, unit number, capacity and controller type.
      3. Shuts the VMs down (guest shutdown; hard power-off only with the explicit opt-in
         switch), detaches the RDMs and their shared-bus controllers, cold-relocates each
         VM, then recreates the controllers and re-attaches the RDMs at exactly the same
         SCSI addresses.
      4. Re-reads the resulting topology and writes it out as evidence.

    RDMs are attached through an explicit VirtualDeviceConfigSpec rather than New-HardDisk
    so the SCSI address is deterministic: a WSFC/SQL FCI node cares which unit a LUN lands
    on, and New-HardDisk only ever takes the next free unit. The controller type is
    recreated from the source device type rather than forced to PVSCSI, and the RDM
    mapping-file topology (one shared mapping file for the group, or one per VM) is
    reproduced from the source rather than assumed.

    -DryRun performs discovery and produces local evidence files without invoking any
    VMware modification. -Execute performs the migration. There is no third mode: the
    dry run is the no-op.

    The script is self-contained. It reads no configuration file, imports nothing from
    this repository, and needs only PowerCLI on the host, so it can be copied to a jump
    host on its own and run there. Its logging and credential helpers are the
    Richo.Common ones, carried here rather than imported, so the call sites and the log
    format are the same as everything else in the repo.

    The script does not present LUNs on the array and does not rescan HBAs. Both are
    prerequisites - see docs/sql-rdm-cluster-migration.md.

.PARAMETER VCenter
    FQDN of the vCenter Server that holds both the VMs and the destination cluster.

.PARAMETER CsvPath
    Path to the migration CSV. See docs/sql-rdm-cluster-migration.md for the columns.

.PARAMETER DryRun
    Discovery, validation and evidence only. No VMware object is modified.

.PARAMETER Execute
    Perform the migration.

.PARAMETER VMName
    Run only the CSV rows that name these VMs - one line at a time. The whole row runs:
    a row is one SQL cluster, and moving one node while its siblings keep the shared
    RDMs is not something this tool will do.

.PARAMETER Batch
    Run only the rows carrying these batch numbers. Accepts more than one.

.PARAMETER Credential
    vCenter credential. When omitted it is resolved by the credential helper below,
    which tries SecretManagement, then the RICHO_* environment variables, then a prompt.

.PARAMETER CredentialName
    Logical credential name for the credential helper. Defaults to the vCenter FQDN.

.PARAMETER PowerAction
    What to do with a VM that is still powered on. 'None' fails the run; 'ShutdownGuest'
    requests a graceful guest shutdown and waits for it.

.PARAMETER ShutdownTimeoutMinutes
    How long to wait for a guest shutdown before failing the run.

.PARAMETER ForcePowerOffIfGuestShutdownUnavailable
    Allow a hard power-off, and only when VMware Tools is not running. Without it a
    powered-on VM whose Tools are unavailable stops the migration.

.PARAMETER OutputFolder
    Where the manifest, plan, results and verification files are written.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted vCenter certificate for this session only.

.EXAMPLE
    .\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01.example.com -CsvPath .\SqlRdmClusterMigration.csv -DryRun -PowerAction ShutdownGuest

    Validates the CSV against live inventory and writes the plan without changing anything.

.EXAMPLE
    .\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01.example.com -CsvPath .\SqlRdmClusterMigration.csv -Execute -PowerAction ShutdownGuest -ShutdownTimeoutMinutes 20

    Migrates every row in the CSV. After each row is mapped and verified it prints what
    landed where and asks whether to power that row's VMs on.

.EXAMPLE
    .\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01.example.com -CsvPath .\SqlRdmClusterMigration.csv -Execute -VMName LABSQL01 -PowerAction ShutdownGuest

    Runs the single CSV row that names LABSQL01 - that VM and the rest of its cluster.

.EXAMPLE
    .\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01.example.com -CsvPath .\SqlRdmClusterMigration.csv -Execute -Batch 1 -PowerAction ShutdownGuest

    Runs every row marked batch 1, in CSV order.
#>
#Requires -Version 5.1
# Deliberately no SupportsShouldProcess, and so a departure from the repo convention:
# -DryRun and -Execute are the two modes, and a single gate in Invoke-PlannedChange
# decides between them. A second way to say "change nothing" is one too many for a tool
# run under an outage window.
[CmdletBinding(DefaultParameterSetName = 'DryRun')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VCenter,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory, ParameterSetName = 'DryRun')]
    [switch]$DryRun,

    [Parameter(Mandatory, ParameterSetName = 'Execute')]
    [switch]$Execute,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$VMName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [int[]]$Batch,

    [Parameter()]
    [pscredential]$Credential,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialName,

    [Parameter()]
    [ValidateSet('None', 'ShutdownGuest')]
    [string]$PowerAction = 'None',

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$ShutdownTimeoutMinutes = 20,

    [Parameter()]
    [switch]$ForcePowerOffIfGuestShutdownUnavailable,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputFolder = (Join-Path (Get-Location) 'SqlRdmClusterMigrationOutput'),

    [Parameter()]
    [switch]$IgnoreInvalidCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '3.2.0'
$connection = $null

# There are exactly two modes and one gate between them: -DryRun records what would
# happen, -Execute does it. Nothing else in the script decides whether to change a VM.
$script:RunMode = if ($DryRun) { 'DryRun' } else { 'Execute' }

# Workload type and batch are per migration group, and stamping them on every plan,
# result and verification row is what lets a change record be filtered to one batch of
# PROD. Held here so the row builders can reach them without every call site passing
# them along.
$script:GroupInfoByName = @{}
$script:RunScope = 'all rows in the CSV'
$script:ValidWorkloadTypes = @('PROD', 'SIT', 'DEV')

$script:Plan = [System.Collections.Generic.List[object]]::new()
$script:Results = [System.Collections.Generic.List[object]]::new()
# Named Rows, not Verification: at script scope $verification would be the same variable
# as $script:Verification - PowerShell does not distinguish case - and a local of that
# name in the main body replaced this list with an array, which broke every execution run
# at the point it wrote its evidence.
$script:VerificationRows = [System.Collections.Generic.List[object]]::new()

# Highest SCSI unit number on a controller. Unit 7 is reserved for the controller itself.
$script:MaxScsiUnitNumber = 15
$script:ReservedScsiUnitNumber = 7

# Two RDMs are treated as the same disk when their sizes agree to within this much. vCenter
# rounds, and an array reports usable rather than raw capacity, so an exact match is wrong.
$script:CapacityToleranceGB = 1

function Write-RichoLog {
    <#
    .SYNOPSIS
        Writes a timestamped, levelled log line to the host and optionally to a file.

    .DESCRIPTION
        The Richo.Common implementation, carried here so this script runs on a jump host
        with nothing but PowerCLI. The format is deliberately identical:

            2026-09-01 14:32:07Z [INFO ] Connecting to vcenter01.example.com

        INFO and DEBUG go to the information and verbose streams, WARN to the warning
        stream and ERROR to the error stream, so redirection and -ErrorAction behave the
        way callers expect.

    .PARAMETER Message
        The text to log.

    .PARAMETER Level
        Severity: DEBUG, INFO, WARN or ERROR. Defaults to INFO.

    .PARAMETER Path
        Optional log file to append to. Defaults to $env:RICHO_LOG_FILE when set.

    .EXAMPLE
        Write-RichoLog 'Connected to vCenter.' -Level INFO
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter()]
        [AllowEmptyString()]
        [string]$Path = $env:RICHO_LOG_FILE
    )

    process {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
        $line = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message

        switch ($Level) {
            'DEBUG' { Write-Verbose $line }
            'INFO'  { Write-Information $line -InformationAction Continue }
            'WARN'  { Write-Warning $line }
            'ERROR' { Write-Error $line }
        }

        if ($Path) {
            $directory = Split-Path -Path $Path -Parent
            if ($directory -and -not (Test-Path -LiteralPath $directory)) {
                New-Item -Path $directory -ItemType Directory -Force | Out-Null
            }
            Add-Content -Path $Path -Value $line -Encoding UTF8
        }
    }
}

function Get-RichoCredential {
    <#
    .SYNOPSIS
        Resolves a PSCredential for a named target without hardcoding a secret.

    .DESCRIPTION
        The Richo.Common implementation, carried here for the same reason as the logger.
        Resolution order:

          1. SecretManagement - Get-Secret -Name $Name, when the module is present.
          2. Environment variables - RICHO_<NAME>_USER and RICHO_<NAME>_PASSWORD, with
             the name upper-cased and non-alphanumerics replaced by '_'. Suits a
             scheduled or unattended run.
          3. An interactive prompt.

        Nothing is read from a plaintext file and nothing is written back to disk.

    .PARAMETER Name
        Logical credential name, e.g. the vCenter FQDN.

    .EXAMPLE
        $credential = Get-RichoCredential -Name 'vcenter01.example.com'
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    if (Get-Command -Name 'Get-Secret' -ErrorAction SilentlyContinue) {
        $secret = Get-Secret -Name $Name -ErrorAction SilentlyContinue
        if ($secret -is [pscredential]) {
            Write-RichoLog "Resolved credential '$Name' from SecretManagement." -Level DEBUG
            return $secret
        }
    }

    $slug = ($Name -replace '[^A-Za-z0-9]', '_').ToUpperInvariant()
    $user = [Environment]::GetEnvironmentVariable("RICHO_${slug}_USER")
    $password = [Environment]::GetEnvironmentVariable("RICHO_${slug}_PASSWORD")

    if ($user -and $password) {
        Write-RichoLog "Resolved credential '$Name' from environment variables." -Level DEBUG
        return [pscredential]::new($user, (ConvertTo-SecureString $password -AsPlainText -Force))
    }

    return (Get-Credential -Message "Credentials for '$Name'")
}

function Import-RequiredModules {
    <#
    .SYNOPSIS
        Loads the modules this script needs, once, and never installs anything.

    .DESCRIPTION
        PowerCLI is the script's only dependency, and the load is behind a Get-Module
        check so a module already in the session - a pinned vendor bundle included - is
        left exactly as it is. Nothing is installed or updated.

        Only VMware.VimAutomation.Core is needed; the VMware.PowerCLI meta-module pulls
        in dozens of unrelated modules and costs a minute of load time to do it. The load
        is explicit rather than left to auto-loading, which has been seen to fail on the
        first use in a new session against a cold command-discovery cache.
    #>
    [CmdletBinding()]
    param()

    $required = @('VMware.VimAutomation.Core')

    foreach ($name in $required) {
        if (Get-Module -Name $name) { continue }
        try {
            Import-Module -Name $name -ErrorAction Stop
        }
        catch {
            throw "PowerCLI module '$name' is not available on this host: $($_.Exception.Message)"
        }
    }
}

function ConvertTo-ValueList {
    <#
    .SYNOPSIS
        Splits a space-separated CSV cell into a trimmed array, empty cell included.

    .PARAMETER Value
        The raw cell text.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value -split '\s+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

function Get-WorkloadType {
    <#
    .SYNOPSIS
        Returns the workload type recorded for a migration group.

    .PARAMETER MigrationGroup
        The group name, or an empty string for rows that belong to no group yet.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$MigrationGroup
    )

    if ($MigrationGroup -and $script:GroupInfoByName.ContainsKey($MigrationGroup)) {
        return [string]$script:GroupInfoByName[$MigrationGroup].WorkloadType
    }

    return ''
}

function Get-GroupBatch {
    <#
    .SYNOPSIS
        Returns the batch number recorded for a migration group.

    .PARAMETER MigrationGroup
        The group name, or an empty string for rows that belong to no group yet.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$MigrationGroup
    )

    if ($MigrationGroup -and $script:GroupInfoByName.ContainsKey($MigrationGroup)) {
        return [string]$script:GroupInfoByName[$MigrationGroup].Batch
    }

    return ''
}

function Add-Result {
    <#
    .SYNOPSIS
        Appends one row to the run results, stamped with the script version.

    .PARAMETER MigrationGroup
        The migration group the row belongs to.

    .PARAMETER VM
        The VM the row concerns, or an empty string for group-level rows.

    .PARAMETER Phase
        The phase or action the row records.

    .PARAMETER Status
        Outcome: Passed, DryRun, Succeeded, Skipped or Failed.

    .PARAMETER Detail
        Free text describing what happened.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$MigrationGroup,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string]$VM,

        [Parameter(Position = 2)]
        [string]$Phase,

        [Parameter(Position = 3)]
        [string]$Status,

        [Parameter(Position = 4)]
        [AllowEmptyString()]
        [string]$Detail
    )

    $script:Results.Add([pscustomobject]@{
        Timestamp      = (Get-Date).ToString('o')
        ScriptVersion  = $ScriptVersion
        MigrationGroup = $MigrationGroup
        WorkloadType   = (Get-WorkloadType -MigrationGroup $MigrationGroup)
        Batch          = (Get-GroupBatch -MigrationGroup $MigrationGroup)
        VM             = $VM
        Phase          = $Phase
        Status         = $Status
        Detail         = $Detail
    })
}

function Invoke-PlannedChange {
    <#
    .SYNOPSIS
        Records an intended change, then performs it unless this is a dry run.

    .DESCRIPTION
        Every mutation in this script goes through here, so the change plan written at the
        end of the run is the same list of operations in both modes - a dry run and a live
        run differ only in whether the operation block was invoked.

    .PARAMETER MigrationGroup
        The migration group the change belongs to.

    .PARAMETER VM
        The VM being changed.

    .PARAMETER Action
        Short action name, used in the plan and results files.

    .PARAMETER Target
        The object the action is applied to.

    .PARAMETER Detail
        Operator-readable description of the change.

    .PARAMETER Operation
        The block that performs the change. Never invoked during a dry run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$MigrationGroup,

        [Parameter(Mandatory, Position = 1)]
        [AllowEmptyString()]
        [string]$VM,

        [Parameter(Mandatory, Position = 2)]
        [string]$Action,

        [Parameter(Mandatory, Position = 3)]
        [string]$Target,

        [Parameter(Mandatory, Position = 4)]
        [string]$Detail,

        [Parameter(Mandatory, Position = 5)]
        [scriptblock]$Operation
    )

    $script:Plan.Add([pscustomobject]@{
        ScriptVersion  = $ScriptVersion
        Mode           = $script:RunMode
        MigrationGroup = $MigrationGroup
        WorkloadType   = (Get-WorkloadType -MigrationGroup $MigrationGroup)
        Batch          = (Get-GroupBatch -MigrationGroup $MigrationGroup)
        VM             = $VM
        Action         = $Action
        Target         = $Target
        Detail         = $Detail
    })

    if ($DryRun) {
        Write-RichoLog "  DRY RUN: $Detail" -Level INFO
        Add-Result $MigrationGroup $VM $Action 'DryRun' $Detail
        return
    }

    Write-RichoLog "  EXECUTE: $Detail" -Level INFO
    & $Operation
    Add-Result $MigrationGroup $VM $Action 'Succeeded' $Detail
}

function Get-ExactObject {
    <#
    .SYNOPSIS
        Resolves a name to exactly one inventory object, or throws.

    .DESCRIPTION
        Matching is case-sensitive and the count must be one. vCenter happily holds two
        objects whose names differ only in case, and a migration that picks the wrong one
        of those is not recoverable by re-running the script.

    .PARAMETER Name
        The name to match.

    .PARAMETER ObjectType
        What is being looked up, for the error message.

    .PARAMETER Lookup
        Block that returns the candidates.

    .PARAMETER CaseInsensitive
        Match without regard to case. Used only for a name the script derived itself,
        where holding the operator to a case they never typed helps nobody. A name from
        the CSV is always matched exactly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ObjectType,

        [Parameter(Mandatory)]
        [scriptblock]$Lookup,

        [Parameter()]
        [switch]$CaseInsensitive
    )

    $candidates = @(& $Lookup | Where-Object {
        if ($CaseInsensitive) { $_.Name -ieq $Name } else { $_.Name -ceq $Name }
    })
    if ($candidates.Count -ne 1) {
        throw "Expected exactly one $ObjectType named '$Name'; found $($candidates.Count)."
    }

    return $candidates[0]
}

function Format-Elapsed {
    <#
    .SYNOPSIS
        Renders a duration the way an operator reads one.

    .PARAMETER Elapsed
        The duration.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [timespan]$Elapsed
    )

    # [int] rounds in PowerShell - [int]1.5 is 2 - so 90 seconds came out as "2m 30s".
    # Floor is what a clock does.
    if ($Elapsed.TotalMinutes -lt 1) { return "$([math]::Round($Elapsed.TotalSeconds, 1))s" }
    if ($Elapsed.TotalHours -lt 1) { return "$([int][math]::Floor($Elapsed.TotalMinutes))m $($Elapsed.Seconds)s" }

    return "$([int][math]::Floor($Elapsed.TotalHours))h $($Elapsed.Minutes)m"
}

function Wait-VMLongTask {
    <#
    .SYNOPSIS
        Waits for a vCenter task, saying where it is up to while it runs.

    .DESCRIPTION
        A cold relocate of a large VM is minutes of nothing on screen, which reads as a
        hung script. This polls the task, drives a progress bar, and prints a percentage
        and an elapsed time at intervals so the run is visibly alive.

    .PARAMETER Task
        The PowerCLI task to wait for.

    .PARAMETER Activity
        What the task is doing, for the log and the progress bar.

    .PARAMETER ReportEverySeconds
        How often to print a progress line. The progress bar updates far more often.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        [string]$Activity,

        [Parameter()]
        [ValidateRange(5, 300)]
        [int]$ReportEverySeconds = 15
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastReport = 0
    $current = $Task

    while (($current.State -eq 'Running') -or ($current.State -eq 'Queued')) {
        Start-Sleep -Seconds 2
        $current = Get-Task -Id $Task.Id

        $percent = 0
        if ($null -ne $current.PercentComplete) { $percent = [int]$current.PercentComplete }
        Write-Progress -Activity $Activity -Status "$percent% after $(Format-Elapsed -Elapsed $stopwatch.Elapsed)" -PercentComplete $percent

        if (($stopwatch.Elapsed.TotalSeconds - $lastReport) -ge $ReportEverySeconds) {
            $lastReport = $stopwatch.Elapsed.TotalSeconds
            Write-RichoLog "      $Activity - $percent% ($(Format-Elapsed -Elapsed $stopwatch.Elapsed) elapsed)" -Level INFO
        }
    }

    Write-Progress -Activity $Activity -Completed
    $stopwatch.Stop()

    if ($current.State -ne 'Success') {
        $reason = ''
        if ($current.ExtensionData.Info.Error) { $reason = " $($current.ExtensionData.Info.Error.LocalizedMessage)" }
        throw "$Activity failed: task state is $($current.State).$reason"
    }

    Write-RichoLog "      $Activity finished in $(Format-Elapsed -Elapsed $stopwatch.Elapsed)." -Level INFO
}

function Get-DefaultRdmDatastoreName {
    <#
    .SYNOPSIS
        Builds the conventional RDM pointer datastore name for a cluster and workload type.

    .DESCRIPTION
        Clusters are shared: one cluster carries PROD, SIT and DEV workloads side by side.
        What the workload type separates is the mapping-file directory, so the name is the
        cluster plus the environment's own suffix plus '_i_rdm':

            PROD  d24sql02      -> d24sql02_i_rdm
            SIT   d24sql02      -> d24sql02sit_i_rdm
            DEV   d24sql02      -> d24sql02dev_i_rdm

        PROD adds nothing, which is why it is the one that looks like the cluster name.

        It is only ever a default. A CSV that names the datastore is obeyed as written.

    .PARAMETER ClusterName
        The destination cluster, whose hosts must mount the datastore.

    .PARAMETER WorkloadType
        PROD, SIT or DEV.

    .EXAMPLE
        Get-DefaultRdmDatastoreName -ClusterName 'd24sql02' -WorkloadType SIT   # d24sql02sit_i_rdm
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterName,

        [Parameter(Mandatory)]
        [ValidateSet('PROD', 'SIT', 'DEV')]
        [string]$WorkloadType
    )

    $suffix = switch ($WorkloadType) {
        'SIT'   { 'sit' }
        'DEV'   { 'dev' }
        default { '' }
    }

    return "${ClusterName}${suffix}_i_rdm"
}

function Get-ScsiUnitNumberSequence {
    <#
    .SYNOPSIS
        Returns the SCSI unit numbers a group of disks occupies on one controller.

    .DESCRIPTION
        Units run 0-15 and unit 7 belongs to the controller, so a fourteenth disk is not
        "unit 14 plus one" - it is the point at which the controller is full. The original
        allocation kept counting past 15, which produces a spec vCenter rejects halfway
        through re-attaching a cluster's disks.

    .PARAMETER Count
        How many disks the controller must carry.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 64)]
        [int]$Count
    )

    $units = [System.Collections.Generic.List[int]]::new()
    $candidate = 0
    while ($units.Count -lt $Count) {
        if ($candidate -gt $script:MaxScsiUnitNumber) {
            throw "A SCSI controller cannot carry $Count disks; the maximum is $($script:MaxScsiUnitNumber)."
        }
        if ($candidate -ne $script:ReservedScsiUnitNumber) {
            $units.Add($candidate)
        }
        $candidate++
    }

    return $units.ToArray()
}

function Import-MigrationCsv {
    <#
    .SYNOPSIS
        Loads and validates the migration CSV.

    .DESCRIPTION
        Everything that can be checked without vCenter is checked here, because a CSV
        defect found after the first VM has been powered off is a defect found too late.

    .PARAMETER Path
        Path to the CSV.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $allRows = @(Import-Csv -LiteralPath $Path)
    if ($allRows.Count -eq 0) {
        throw 'CSV contains no data rows.'
    }

    # A row whose first cell starts with # is commented out and never looked at again -
    # not validated, not counted, not run. It is how one row of a sheet is taken out of a
    # night's work without editing anything else, and how a sheet of twenty rows is run
    # one row at a time.
    $firstColumn = @($allRows[0].PSObject.Properties.Name)[0]
    $rows = @($allRows | Where-Object { -not ([string]$_.$firstColumn).Trim().StartsWith('#') })
    $commentedOut = $allRows.Count - $rows.Count
    if ($commentedOut -gt 0) {
        Write-RichoLog "$commentedOut of $($allRows.Count) CSV row(s) are commented out with # and will be skipped." -Level INFO
    }
    if ($rows.Count -eq 0) {
        throw "Every row in the CSV is commented out with #; there is nothing to do."
    }

    $requiredColumns = @(
        'batch',
        'destination_cluster',
        'workload_type',
        'first_vm',
        'other_vms_space_separated',
        'svm',
        'iSCSI_Data_Store',
        'group_1_lun_IDs_ordered_space_separated',
        'group_2_lun_IDs_ordered_space_separated',
        'group_3_lun_IDs_ordered_space_separated',
        'destination_resource_pool',
        'destination_datastore_cluster'
    )

    $actualColumns = @($rows[0].PSObject.Properties.Name)
    foreach ($column in $requiredColumns) {
        if ($column -notin $actualColumns) {
            throw "CSV is missing required column '$column'."
        }
    }

    $groupColumns = @(
        'group_1_lun_IDs_ordered_space_separated',
        'group_2_lun_IDs_ordered_space_separated',
        'group_3_lun_IDs_ordered_space_separated'
    )
    $seenVmNames = @{}
    $lineNumber = 1

    foreach ($row in $rows) {
        $lineNumber++

        foreach ($column in @(
            'batch',
            'destination_cluster',
            'workload_type',
            'first_vm',
            'svm',
            'destination_resource_pool',
            'destination_datastore_cluster'
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$row.$column)) {
                throw "CSV line $lineNumber has an empty '$column'."
            }
            $row.$column = ([string]$row.$column).Trim()
        }

        # The RDM pointer datastore is the one cell allowed to be blank: left empty it is
        # derived from the destination cluster name at resolution time.
        $row.iSCSI_Data_Store = ([string]$row.iSCSI_Data_Store).Trim()

        $batchNumber = 0
        if (-not [int]::TryParse([string]$row.batch, [ref]$batchNumber) -or $batchNumber -lt 1) {
            throw "CSV line $lineNumber has batch '$($row.batch)'; expected a whole number of 1 or more."
        }
        $row.batch = $batchNumber

        # The line number rides along so a batch can be ordered without losing CSV order
        # inside it - Sort-Object is not a stable sort on Windows PowerShell.
        Add-Member -InputObject $row -NotePropertyName 'csv_line' -NotePropertyValue $lineNumber -Force

        $workloadType = ([string]$row.workload_type).ToUpperInvariant()
        if ($workloadType -notin $script:ValidWorkloadTypes) {
            throw "CSV line $lineNumber has workload_type '$($row.workload_type)'; expected one of $($script:ValidWorkloadTypes -join ', ')."
        }
        $row.workload_type = $workloadType

        $vmNames = @([string]$row.first_vm) + @(ConvertTo-ValueList ([string]$row.other_vms_space_separated))
        if (@($vmNames | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
            throw "CSV line $lineNumber contains duplicate VM names."
        }

        # A VM in two groups would be shut down twice and relocated twice, the second time
        # from a plan built before the first migration touched it.
        foreach ($vmName in $vmNames) {
            $key = $vmName.ToLowerInvariant()
            if ($seenVmNames.ContainsKey($key)) {
                throw "CSV line $lineNumber repeats VM '$vmName', already listed on line $($seenVmNames[$key])."
            }
            $seenVmNames[$key] = $lineNumber
        }

        $lunIds = [System.Collections.Generic.List[int]]::new()
        foreach ($groupColumn in $groupColumns) {
            $groupIds = @(ConvertTo-ValueList ([string]$row.$groupColumn))
            foreach ($value in $groupIds) {
                $lunId = 0
                if (-not [int]::TryParse($value, [ref]$lunId) -or $lunId -lt 0) {
                    throw "CSV line $lineNumber contains invalid LUN ID '$value'."
                }
                $lunIds.Add($lunId)
            }

            # Each group becomes one controller, so a group that overflows a controller is
            # a CSV problem, not a vCenter problem. Fail before anything is powered off.
            if ($groupIds.Count -gt $script:MaxScsiUnitNumber) {
                throw "CSV line $lineNumber puts $($groupIds.Count) LUNs in '$groupColumn'; a SCSI controller carries at most $($script:MaxScsiUnitNumber)."
            }
        }

        if ($lunIds.Count -eq 0) {
            throw "CSV line $lineNumber contains no LUN IDs."
        }
        if (@($lunIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
            throw "CSV line $lineNumber contains duplicate LUN IDs."
        }
    }

    return $rows
}

function Select-MigrationRows {
    <#
    .SYNOPSIS
        Picks the CSV rows this run will migrate, and says what was picked.

    .DESCRIPTION
        Three scopes, all driven from the CSV itself:

          * one line, by naming a VM that appears in it - the whole row runs, because a
            row is one SQL cluster and moving one node while its siblings still hold the
            shared RDMs is not something this tool will do;
          * one or more batches, by the batch column;
          * everything in the file, which is what happens when neither is given.

        Rows come back in batch order, and in CSV order inside a batch, so batch 1 is
        finished before batch 2 begins whatever order the file happens to be in.

    .PARAMETER Rows
        Every row from the CSV.

    .PARAMETER VMName
        VM names to select rows by.

    .PARAMETER Batch
        Batch numbers to select rows by.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Rows,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$VMName,

        [Parameter()]
        [AllowEmptyCollection()]
        [int[]]$Batch
    )

    $namesGiven = @($VMName | Where-Object { $_ })
    $batchesGiven = @($Batch | Where-Object { $_ })

    if (($namesGiven.Count -gt 0) -and ($batchesGiven.Count -gt 0)) {
        throw 'Choose either -VMName or -Batch, not both.'
    }

    $selected = $Rows
    $scope = "all $($Rows.Count) row(s) in the CSV"

    if ($namesGiven.Count -gt 0) {
        $matched = [System.Collections.Generic.List[object]]::new()
        foreach ($name in $namesGiven) {
            $rowsForName = @(
                $Rows |
                    Where-Object {
                        $rowVMNames = @([string]$_.first_vm) + @(ConvertTo-ValueList ([string]$_.other_vms_space_separated))
                        @($rowVMNames | Where-Object { $_ -ieq $name }).Count -gt 0
                    }
            )
            if ($rowsForName.Count -eq 0) {
                throw "No CSV row names VM '$name'."
            }
            foreach ($row in $rowsForName) {
                if ($matched -notcontains $row) { $matched.Add($row) }
            }
        }
        $selected = $matched.ToArray()
        $scope = "the row(s) naming $($namesGiven -join ', ')"
    }
    elseif ($batchesGiven.Count -gt 0) {
        $selected = @($Rows | Where-Object { [int]$_.batch -in $batchesGiven })
        if ($selected.Count -eq 0) {
            $available = @($Rows | ForEach-Object { [int]$_.batch } | Sort-Object -Unique)
            throw "No CSV row is in batch $($batchesGiven -join ', '). The file has batch $($available -join ', ')."
        }
        $scope = "batch $($batchesGiven -join ', ')"
    }

    $ordered = @(
        $selected |
            Sort-Object -Property @{ Expression = { [int]$_.batch } }, @{ Expression = { [int]$_.csv_line } }
    )

    return [pscustomobject]@{
        Rows  = $ordered
        Scope = $scope
    }
}

function Get-OptionalProperty {
    <#
    .SYNOPSIS
        Reads a property that may not exist on this build of the VMware SDK.

    .DESCRIPTION
        SHIPPED AND HIT ON A DRY RUN. VirtualDisk.Sharing arrived in a later vSphere API
        than some of the bindings in the field, and under Set-StrictMode reading a
        property the object does not have is a terminating error - so discovery died on
        the first VM it looked at.

        Anything optional, or newer than the oldest PowerCLI this has to run against, is
        read through here. The property bag answers "is it there" without throwing.

    .PARAMETER InputObject
        The object to read from.

    .PARAMETER Name
        The property name.

    .PARAMETER Default
        What to return when the property is absent or null.

    .EXAMPLE
        Get-OptionalProperty -InputObject $device -Name 'Sharing' -Default ''
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    if ($null -eq $property.Value) { return $Default }

    return $property.Value
}

function Get-VMRdmLayout {
    <#
    .SYNOPSIS
        Reads a VM's physical-mode RDM topology.

    .DESCRIPTION
        Devices are matched by type, not by looking for a DeviceName on the backing. A
        host-attached CD-ROM also carries a DeviceName and has no CompatibilityMode
        property at all, so under Set-StrictMode the duck-typed form throws on any VM with
        one - a crash in discovery, before the operator has seen a plan.

    .PARAMETER VM
        The VM to read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VM
    )

    $view = Get-View -Id $VM.Id -Property @(
        'Config.Hardware.Device',
        'Config.Files.VmPathName',
        'Config.ChangeVersion',
        'Snapshot'
    )

    $controllers = @{}
    foreach ($device in @($view.Config.Hardware.Device)) {
        if ($device -is [VMware.Vim.VirtualSCSIController]) {
            $controllers[[int]$device.Key] = $device
        }
    }

    $rdms = [System.Collections.Generic.List[object]]::new()
    foreach ($device in @($view.Config.Hardware.Device)) {
        if ($device -isnot [VMware.Vim.VirtualDisk]) { continue }

        $backing = $device.Backing
        if ($backing -isnot [VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo]) { continue }

        if ([string]$backing.CompatibilityMode -ne 'physicalMode') {
            throw "VM '$($VM.Name)' disk '$($device.DeviceInfo.Label)' is a virtual-mode RDM. This tool reconstructs physical-mode RDMs only."
        }

        $controller = $null
        if ($controllers.ContainsKey([int]$device.ControllerKey)) {
            $controller = $controllers[[int]$device.ControllerKey]
        }
        if ($null -eq $controller) {
            throw "VM '$($VM.Name)' RDM '$($device.DeviceInfo.Label)' has no resolvable SCSI controller."
        }

        $canonicalName = ([string]$backing.DeviceName -replace '^.*/', '').ToLowerInvariant()
        $capacityBytes = [double](Get-OptionalProperty -InputObject $device -Name 'CapacityInBytes' -Default 0)
        if ($capacityBytes -le 0) {
            $capacityBytes = [double]$device.CapacityInKB * 1024
        }

        $rdms.Add([pscustomobject]@{
            Label          = [string]$device.DeviceInfo.Label
            CanonicalName  = $canonicalName
            DeviceName     = [string]$backing.DeviceName
            CompatibilityMode = [string]$backing.CompatibilityMode
            DiskMode       = [string](Get-OptionalProperty -InputObject $backing -Name 'DiskMode' -Default '')
            Sharing        = [string](Get-OptionalProperty -InputObject $device -Name 'Sharing' -Default '')
            CapacityGB     = [math]::Round($capacityBytes / 1GB, 3)
            CapacityInKB   = [long]($capacityBytes / 1KB)
            ControllerBus  = [int]$controller.BusNumber
            UnitNumber     = [int]$device.UnitNumber
            BusSharing     = [string]$controller.SharedBus
            ControllerKey  = [int]$device.ControllerKey
            ControllerType = $controller.GetType().FullName
            LunUuid        = [string](Get-OptionalProperty -InputObject $backing -Name 'LunUuid' -Default '')
            BackingFile    = [string]$backing.FileName
        })
    }

    return [pscustomobject]@{
        View = $view
        Rdms = $rdms.ToArray()
    }
}

function Get-EligibleDestinationHosts {
    <#
    .SYNOPSIS
        Returns the destination hosts that can run the migrated VMs.

    .DESCRIPTION
        A host qualifies if it is connected, powered on, out of maintenance mode, and
        mounts both the destination datastore cluster and the RDM pointer datastore.
        Hosts that fail are reported with the reason - "no eligible host" on its own tells
        the operator nothing about which prerequisite is missing.

        Storage presentation is NOT checked here. Presenting the LUNs to the destination
        hosts and rescanning is the engineer's prerequisite, and reading every path on
        every host to re-confirm it was the slowest thing this script did. What must be
        presented is stated instead, once, and taken on trust.

        The mounts are read from the datastores, not from the hosts. Asking each host what
        it mounts is one round trip per host - a minute of them on a 42-host cluster - and
        answers a question two queries already answer: a datastore knows which hosts have
        it mounted.

    .PARAMETER Cluster
        The destination cluster.

    .PARAMETER DatastoreCluster
        Destination datastore cluster for the VM home files.

    .PARAMETER RdmDatastore
        Datastore that holds the RDM mapping files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Cluster,

        [Parameter(Mandatory)]
        $DatastoreCluster,

        [Parameter(Mandatory)]
        $RdmDatastore
    )

    $eligible = [System.Collections.Generic.List[object]]::new()
    $exclusions = [System.Collections.Generic.List[string]]::new()
    $scanStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $candidateHosts = @(Get-VMHost -Location $Cluster)
    $podDatastores = @(Get-Datastore -Location $DatastoreCluster)
    Write-RichoLog "  Checking $($candidateHosts.Count) host(s) in '$($Cluster.Name)' against the mount tables of $($podDatastores.Count + 1) datastore(s)." -Level INFO

    # Two reads, whatever the cluster size: a datastore's own mount table names every host
    # that has it. MoRef values are prefixed with the type so they compare directly with
    # the Id PowerCLI puts on a VMHost.
    $podHostIds = @(
        Get-View -Id @($podDatastores | ForEach-Object { $_.Id }) -Property Host |
            ForEach-Object { $_.Host } |
            Where-Object { $_.MountInfo.Mounted -and $_.MountInfo.Accessible } |
            ForEach-Object { "$($_.Key.Type)-$($_.Key.Value)" } |
            Select-Object -Unique
    )
    $rdmHostIds = @(
        Get-View -Id $RdmDatastore.Id -Property Host |
            ForEach-Object { $_.Host } |
            Where-Object { $_.MountInfo.Mounted -and $_.MountInfo.Accessible } |
            ForEach-Object { "$($_.Key.Type)-$($_.Key.Value)" } |
            Select-Object -Unique
    )

    foreach ($candidateHost in $candidateHosts) {
        if ($candidateHost.ConnectionState -ne 'Connected') {
            $exclusions.Add("$($candidateHost.Name): connection state is $($candidateHost.ConnectionState)")
            continue
        }
        if ($candidateHost.PowerState -ne 'PoweredOn') {
            $exclusions.Add("$($candidateHost.Name): power state is $($candidateHost.PowerState)")
            continue
        }
        if ($candidateHost.ExtensionData.Runtime.InMaintenanceMode) {
            $exclusions.Add("$($candidateHost.Name): in maintenance mode")
            continue
        }
        if ([string]$candidateHost.Id -notin $podHostIds) {
            $exclusions.Add("$($candidateHost.Name): mounts no datastore from '$($DatastoreCluster.Name)'")
            continue
        }
        if ([string]$candidateHost.Id -notin $rdmHostIds) {
            $exclusions.Add("$($candidateHost.Name): does not mount RDM datastore '$($RdmDatastore.Name)'")
            continue
        }

        $eligible.Add([pscustomobject]@{ VMHost = $candidateHost })
    }

    $scanStopwatch.Stop()
    Write-RichoLog "  $($eligible.Count) of $($candidateHosts.Count) host(s) can take these VMs ($(Format-Elapsed -Elapsed $scanStopwatch.Elapsed)). $($exclusions.Count) excluded." -Level INFO

    # Named, not listed one per line: on a large cluster the exclusions are the noise and
    # the reason is the signal.
    foreach ($reason in @($exclusions | ForEach-Object { ($_ -split ': ', 2)[1] } | Select-Object -Unique)) {
        $affected = @($exclusions | Where-Object { $_ -like "*: $reason" } | ForEach-Object { ($_ -split ': ', 2)[0] })
        Write-RichoLog "    $($affected.Count) host(s) excluded - $reason : $($affected -join ', ')" -Level WARN
    }

    return [pscustomobject]@{
        Hosts      = $eligible.ToArray()
        Exclusions = $exclusions.ToArray()
    }
}

function Wait-VMReconfigureTask {
    <#
    .SYNOPSIS
        Waits for a ReconfigVM_Task and fails the run if it did not succeed.

    .PARAMETER TaskReference
        The managed object reference returned by ReconfigVM_Task.

    .PARAMETER Description
        What the task was doing, for the error message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $TaskReference,

        [Parameter(Mandatory)]
        [string]$Description
    )

    Wait-VMLongTask -Task (Get-Task -Id "Task-$($TaskReference.Value)") -Activity $Description -ReportEverySeconds 10
}

function Remove-SharedScsiController {
    <#
    .SYNOPSIS
        Removes an empty SCSI controller from a VM.

    .DESCRIPTION
        SHIPPED AND HIT ON A LIVE RUN. This used to find the controller with
        Get-ScsiController, which returns the controllers of a VM's *hard disks* - so the
        moment the last RDM came off bus 1, the controller stopped being returned and the
        run died with "SCSI controller bus 1 is no longer attached", having already
        detached the disk. The device list says what is really on the VM, and an empty
        controller is exactly what this function exists to remove.

        The removal is an explicit device spec, matching how the controller is put back
        at the destination.

    .PARAMETER VM
        The VM to remove the controller from.

    .PARAMETER BusNumber
        SCSI bus number of the controller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VM,

        [Parameter(Mandatory)]
        [int]$BusNumber
    )

    $vmView = Get-View -Id $VM.Id -Property Config.Hardware.Device
    $controllers = @(
        $vmView.Config.Hardware.Device |
            Where-Object { ($_ -is [VMware.Vim.VirtualSCSIController]) -and ([int]$_.BusNumber -eq $BusNumber) }
    )
    if ($controllers.Count -ne 1) {
        throw "VM '$($VM.Name)' has $($controllers.Count) SCSI controllers on bus $BusNumber; expected one."
    }

    $attached = @(
        $vmView.Config.Hardware.Device |
            Where-Object { ($_ -is [VMware.Vim.VirtualDisk]) -and ([int]$_.ControllerKey -eq [int]$controllers[0].Key) }
    )
    if ($attached.Count -gt 0) {
        throw "SCSI bus $BusNumber on '$($VM.Name)' still carries $($attached.Count) disk(s); refusing to remove the controller."
    }

    $change = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $change.Operation = 'remove'
    $change.Device = $controllers[0]

    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.DeviceChange = @($change)

    Wait-VMReconfigureTask -TaskReference $vmView.ReconfigVM_Task($spec) -Description "Removing SCSI controller $BusNumber from '$($VM.Name)'"
}

function Wait-VMGuestShutdown {
    <#
    .SYNOPSIS
        Waits for a VM to reach PoweredOff, or fails the run.

    .PARAMETER VM
        The VM being shut down.

    .PARAMETER TimeoutMinutes
        How long to wait before giving up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VM,

        [Parameter(Mandatory)]
        [int]$TimeoutMinutes
    )

    $activity = "Waiting for '$($VM.Name)' to power off"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastReport = 0
    $currentVM = Get-VM -Id $VM.Id

    while (($currentVM.PowerState -ne 'PoweredOff') -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Seconds 5
        $currentVM = Get-VM -Id $VM.Id

        $percent = [math]::Min(100, [int](($stopwatch.Elapsed.TotalMinutes / $TimeoutMinutes) * 100))
        Write-Progress -Activity $activity -Status "$(Format-Elapsed -Elapsed $stopwatch.Elapsed) of $TimeoutMinutes minutes" -PercentComplete $percent

        # Twenty minutes of an unresponsive guest should not look like twenty minutes of
        # a hung script.
        if (($stopwatch.Elapsed.TotalSeconds - $lastReport) -ge 30) {
            $lastReport = $stopwatch.Elapsed.TotalSeconds
            Write-RichoLog "      still waiting for '$($VM.Name)' to power off - $(Format-Elapsed -Elapsed $stopwatch.Elapsed) of $TimeoutMinutes minutes, state is $($currentVM.PowerState)." -Level INFO
        }
    }

    Write-Progress -Activity $activity -Completed
    $stopwatch.Stop()

    if ($currentVM.PowerState -ne 'PoweredOff') {
        throw "VM '$($VM.Name)' did not power off within $TimeoutMinutes minutes."
    }

    Write-RichoLog "      '$($VM.Name)' powered off after $(Format-Elapsed -Elapsed $stopwatch.Elapsed)." -Level INFO
}

function Stop-VMForMigration {
    <#
    .SYNOPSIS
        Brings one VM to a powered-off state before it is relocated.

    .DESCRIPTION
        The power state is re-read here rather than taken from the plan. Building the plan
        walks every host's storage and can take minutes, and a VM that was powered off
        when the plan was built may not be by the time this runs.

    .PARAMETER VMItem
        The planned VM record.

    .PARAMETER MigrationGroup
        Group name, for the plan and results files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VMItem,

        [Parameter(Mandatory)]
        [string]$MigrationGroup
    )

    $currentVM = Get-VM -Id $VMItem.VM.Id
    if ($currentVM.PowerState -eq 'PoweredOff') {
        Add-Result $MigrationGroup $currentVM.Name 'PowerOff' 'Passed' 'VM was already powered off.'
        return
    }

    if ($PowerAction -eq 'None') {
        throw "VM '$($currentVM.Name)' is powered on and PowerAction is None."
    }

    $toolsRunning = ([string]$currentVM.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning')
    if ($toolsRunning) {
        $shutdownDetail = "Request graceful guest shutdown for '$($currentVM.Name)' and wait up to $ShutdownTimeoutMinutes minutes."
        Invoke-PlannedChange $MigrationGroup $currentVM.Name 'ShutdownGuest' $currentVM.Name $shutdownDetail {
            Stop-VMGuest -VM (Get-VM -Id $VMItem.VM.Id) -Confirm:$false | Out-Null
            Wait-VMGuestShutdown -VM $VMItem.VM -TimeoutMinutes $ShutdownTimeoutMinutes
        }
        return
    }

    if (-not $ForcePowerOffIfGuestShutdownUnavailable) {
        throw "VM '$($currentVM.Name)' is powered on but VMware Tools is not running. Use -ForcePowerOffIfGuestShutdownUnavailable only when hard power-off is explicitly approved."
    }

    $forcePowerOffDetail = "Force power off '$($currentVM.Name)' because VMware Tools is unavailable and the explicit opt-in switch was supplied."
    Invoke-PlannedChange $MigrationGroup $currentVM.Name 'ForcePowerOff' $currentVM.Name $forcePowerOffDetail {
        Stop-VM -VM (Get-VM -Id $VMItem.VM.Id) -Kill -Confirm:$false | Out-Null
    }
}

function Remove-RdmsAndControllers {
    <#
    .SYNOPSIS
        Detaches a VM's physical RDMs and then their now-empty shared-bus controllers.

    .DESCRIPTION
        Removal never deletes backing storage - the LUN is the whole point of the exercise
        and is re-attached at the destination minutes later.

    .PARAMETER VMItem
        The planned VM record.

    .PARAMETER MigrationGroup
        Group name, for the plan and results files.

    .PARAMETER PlannedBuses
        The SCSI buses the plan will recreate at the destination. A controller left
        behind on one of those is a conflict; on any other bus it is somebody else's
        business.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VMItem,

        [Parameter(Mandatory)]
        [string]$MigrationGroup,

        [Parameter()]
        [AllowEmptyCollection()]
        [int[]]$PlannedBuses = @()
    )

    $currentVM = Get-VM -Id $VMItem.VM.Id
    foreach ($rdm in @($VMItem.Layout.Rdms | Sort-Object ControllerBus, UnitNumber)) {
        # Re-read the VM each time: a device removed a moment ago is still present on a
        # VM object fetched before it.
        $currentVM = Get-VM -Id $VMItem.VM.Id
        $hardDisk = Get-HardDisk -VM $currentVM |
            Where-Object { $_.Name -ceq $rdm.Label } |
            Select-Object -First 1
        if ($null -eq $hardDisk) {
            throw "RDM '$($rdm.Label)' is no longer attached to '$($currentVM.Name)'."
        }

        $removeRdmDetail = "Remove physical RDM '$($rdm.Label)' (SCSI $($rdm.ControllerBus):$($rdm.UnitNumber)) without deleting backing storage."
        Invoke-PlannedChange $MigrationGroup $currentVM.Name 'RemoveRdm' $rdm.Label $removeRdmDetail {
            Remove-HardDisk -HardDisk $hardDisk -DeletePermanently:$false -Confirm:$false | Out-Null
        }
    }

    # SCSI 0 keeps the operating system and any plain VMDKs and is never touched. If a
    # physical RDM turns up there the source is not what the CSV describes, and removing
    # that controller would take the OS disk with it.
    $rdmOnBusZero = @($VMItem.Layout.Rdms | Where-Object { $_.ControllerBus -eq 0 })
    if ($rdmOnBusZero.Count -gt 0) {
        throw "VM '$($currentVM.Name)' has a physical RDM on SCSI 0; this tool will not touch the bus 0 controller."
    }

    # The rule for every OTHER controller is the LUN: a controller that carried one goes
    # with it, and a controller that carried none is left exactly where it is, empty or
    # not. Removing a controller detaches whatever is on it, so "leave it" is the only
    # safe default for anything this migration does not describe.
    #
    # The device list is read rather than Get-ScsiController, which returns the
    # controllers of a VM's hard disks - so a controller emptied moments ago by the loop
    # above is simply absent from its output.
    $vmView = Get-View -Id $currentVM.Id -Property Config.Hardware.Device
    $sharedControllers = @(
        $vmView.Config.Hardware.Device |
            Where-Object { ($_ -is [VMware.Vim.VirtualSCSIController]) -and ([int]$_.BusNumber -ne 0) } |
            Sort-Object { [int]$_.BusNumber }
    )

    if ($sharedControllers.Count -gt 0) {
        Write-RichoLog "      Reviewing $($sharedControllers.Count) SCSI controller(s) on '$($currentVM.Name)' above bus 0; SCSI 0 stays for the VMDK disks." -Level INFO
    }

    foreach ($controller in $sharedControllers) {
        $bus = [int]$controller.BusNumber

        $attachedDisks = @(
            $vmView.Config.Hardware.Device |
                Where-Object { ($_ -is [VMware.Vim.VirtualDisk]) -and ([int]$_.ControllerKey -eq [int]$controller.Key) }
        )

        # In a dry run the RDMs are all still attached, so a controller carrying exactly
        # its planned RDMs is what "empty after removal" looks like from here.
        $plannedLabels = @(
            $VMItem.Layout.Rdms |
                Where-Object { $_.ControllerBus -eq $bus } |
                ForEach-Object { $_.Label }
        )
        $otherLabels = @($attachedDisks | ForEach-Object { [string]$_.DeviceInfo.Label }) -join ', '

        # No LUN of this migration on it, so it is not this migration's controller.
        if ($plannedLabels.Count -eq 0) {
            if ($bus -in $PlannedBuses) {
                $conflict = if ($attachedDisks.Count -gt 0) { " It holds $otherLabels." } else { ' It is empty.' }
                throw "SCSI $bus on '$($currentVM.Name)' carries no LUN from this migration, but the plan puts LUNs on SCSI $bus at the destination.$conflict Resolve that by hand before running this VM."
            }

            $reason = if ($attachedDisks.Count -gt 0) { "it holds $otherLabels" } else { 'it is empty' }
            $level = if ($attachedDisks.Count -gt 0) { 'WARN' } else { 'INFO' }
            Write-RichoLog "      SCSI $bus on '$($currentVM.Name)' carries no LUN from this migration ($reason); leaving it in place." -Level $level
            Add-Result $MigrationGroup $currentVM.Name 'RemoveController' 'Skipped' "SCSI $bus kept: no LUN from this migration is on it ($reason)."
            continue
        }

        # It carried LUNs, so it goes - unless something else is sharing it, which this
        # tool will not detach on anyone's behalf.
        $unexpected = @($attachedDisks | Where-Object { [string]$_.DeviceInfo.Label -notin $plannedLabels })
        if ($unexpected.Count -gt 0) {
            $unexpectedLabels = @($unexpected | ForEach-Object { $_.DeviceInfo.Label }) -join ', '
            throw "SCSI $bus on '$($currentVM.Name)' carries this migration's LUNs alongside disks the CSV does not describe ($unexpectedLabels). Move those to SCSI 0, or take this VM out of the migration."
        }
        if ((-not $DryRun) -and ($attachedDisks.Count -gt 0)) {
            throw "SCSI $bus on '$($currentVM.Name)' is not empty after RDM removal."
        }

        $removeControllerDetail = "Remove SCSI controller $bus (bus sharing $($controller.SharedBus)) - it carried this migration's LUNs. SCSI 0 is left in place."
        Invoke-PlannedChange $MigrationGroup $currentVM.Name 'RemoveController' "SCSI $bus" $removeControllerDetail {
            Remove-SharedScsiController -VM (Get-VM -Id $VMItem.VM.Id) -BusNumber $bus
        }
    }
}

function ConvertTo-PowerCliControllerType {
    <#
    .SYNOPSIS
        Maps a VMware.Vim controller type to the name New-ScsiController takes.

    .PARAMETER ControllerTypeName
        Full type name read from the source controller.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$ControllerTypeName
    )

    switch -Wildcard ($ControllerTypeName) {
        '*ParaVirtualSCSIController'      { return 'ParaVirtual' }
        '*VirtualLsiLogicSASController'   { return 'VirtualLsiLogicSAS' }
        '*VirtualLsiLogicController'      { return 'VirtualLsiLogic' }
        '*VirtualBusLogicController'      { return 'VirtualBusLogic' }
        default                           { return 'ParaVirtual' }
    }
}

function ConvertTo-PowerCliBusSharing {
    <#
    .SYNOPSIS
        Maps a SharedBus value to the name New-ScsiController takes.

    .PARAMETER SharedBus
        Bus sharing read from the source controller.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$SharedBus
    )

    switch ($SharedBus) {
        'physicalSharing' { return 'Physical' }
        'virtualSharing'  { return 'Virtual' }
        'noSharing'       { return 'NoSharing' }
        default           { return 'Physical' }
    }
}

function New-RdmDiskGroup {
    <#
    .SYNOPSIS
        Maps one group of LUNs onto the cluster: a controller, its disks, and the same
        devices attached to every other node.

    .DESCRIPTION
        This is the estate's own proven mapping sequence, kept deliberately close to the
        script it came from, because it works and the hand-built device specs that
        replaced it did not:

          1. Resolve each LUN ID to a device on the VM's own host - the iSCSI path list
             filtered by LUN and SVM, then Get-ScsiLun for the console device name. The
             device identity comes from the LUN ID, never from the RDM that was detached:
             an RDM's backing carries a vml identifier, and the same LUN is a naa on the
             host, so the two do not compare.
          2. Create the first disk of the group with New-HardDisk, then create the
             controller from that disk. PowerCLI moves the disk onto the new controller.
          3. Force that first disk to unit 0 with an edit spec.
          4. Add the rest of the group's disks to the same controller, in CSV order.
          5. Copy the controller and those disks onto every other VM in the group with a
             single add spec, so the nodes share one mapping file per LUN.

        Nothing here checks whether the LUNs are presented: they are, by the time this
        runs, and confirming it was the slowest and least useful thing this script did.

    .PARAMETER FirstVM
        The VM that owns the mapping files.

    .PARAMETER OtherVMs
        The remaining VMs in the group.

    .PARAMETER LunIds
        The group's LUN IDs, in the order they are to be attached.

    .PARAMETER Svm
        SVM whose paths the LUN IDs are looked up on.

    .PARAMETER RdmDatastore
        Datastore that holds the mapping files.

    .PARAMETER ControllerType
        Controller type to create, as New-ScsiController names them.

    .PARAMETER BusSharingMode
        Bus sharing to create the controller with.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $FirstVM,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$OtherVMs,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [int[]]$LunIds,

        [Parameter(Mandatory)]
        [string]$Svm,

        [Parameter(Mandatory)]
        $RdmDatastore,

        [Parameter()]
        [string]$ControllerType = 'ParaVirtual',

        [Parameter()]
        [string]$BusSharingMode = 'Physical'
    )

    $currentFirstVM = Get-VM -Id $FirstVM.Id
    $vmHost = $currentFirstVM.VMHost
    Write-RichoLog "      Resolving $($LunIds.Count) LUN(s) from SVM '$Svm' on $($vmHost.Name)." -Level INFO

    $esxcli = Get-EsxCli -VMHost $vmHost -V2
    $paths = @($esxcli.storage.core.path.list.Invoke())

    $deviceNames = [System.Collections.Generic.List[string]]::new()
    $canonicalNames = [System.Collections.Generic.List[string]]::new()

    foreach ($lunId in $LunIds) {
        $lunPath = @(
            $paths |
                Where-Object { ([int]$_.LUN -eq $lunId) -and ([string]$_.TargetIdentifier -like "*$Svm*") } |
                Select-Object -First 1
        )
        if ($lunPath.Count -eq 0) {
            throw "Host '$($vmHost.Name)' has no path to SVM '$Svm', LUN $lunId. Present it and rescan, then run this group again."
        }

        $scsiLun = @(Get-ScsiLun -VMHost $vmHost -CanonicalName ([string]$lunPath[0].Device))
        if ($scsiLun.Count -ne 1) {
            throw "Host '$($vmHost.Name)' returned $($scsiLun.Count) devices for '$($lunPath[0].Device)'; expected one."
        }

        $deviceNames.Add([string]$scsiLun[0].ConsoleDeviceName)
        $canonicalNames.Add([string]$scsiLun[0].CanonicalName)
        Write-RichoLog "        LUN $lunId -> $($scsiLun[0].CanonicalName) ($($scsiLun[0].ConsoleDeviceName))" -Level INFO
    }

    # The first disk lands wherever PowerCLI puts it, then the controller is created FROM
    # it, which moves it across. That order is the part that works.
    Write-RichoLog "      Creating the first disk and its $ControllerType controller ($BusSharingMode bus sharing)." -Level INFO
    $firstDisk = New-HardDisk -VM $currentFirstVM -DeviceName $deviceNames[0] -DiskType RawPhysical -Datastore $RdmDatastore
    $controller = New-ScsiController -HardDisk $firstDisk -BusSharingMode $BusSharingMode -Type $ControllerType

    # Re-read both: the objects above predate the reconfigure that moved the disk.
    $firstDisk = Get-HardDisk -VM $currentFirstVM -Name $firstDisk.Name
    $controller = Get-ScsiController -HardDisk $firstDisk

    $unitSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $unitSpec.DeviceChange = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $unitSpec.DeviceChange[0].Operation = 'edit'
    $unitSpec.DeviceChange[0].Device = $firstDisk.ExtensionData
    $unitSpec.DeviceChange[0].Device.UnitNumber = 0

    $unitTask = (Get-View -Id $currentFirstVM.Id).ReconfigVM_Task($unitSpec)
    Wait-VMReconfigureTask -TaskReference $unitTask -Description "Setting '$($firstDisk.Name)' on '$($currentFirstVM.Name)' to unit 0"

    for ($index = 1; $index -lt $deviceNames.Count; $index++) {
        $addedDisk = New-HardDisk -VM $currentFirstVM -DeviceName $deviceNames[$index] -DiskType RawPhysical -Datastore $RdmDatastore -Controller $controller
        Write-RichoLog "        added $($addedDisk.Name) - $($canonicalNames[$index])" -Level INFO
    }

    if ($OtherVMs.Count -eq 0) { return }

    # Every other node gets the controller and the very same mapping files, in one spec.
    $rdmDisks = @(
        Get-HardDisk -VM $currentFirstVM |
            Where-Object { ($_.DiskType -eq 'RawPhysical') -and ($canonicalNames -contains [string]$_.ScsiCanonicalName) }
    )
    if ($rdmDisks.Count -ne $deviceNames.Count) {
        throw "Expected $($deviceNames.Count) RDM(s) on '$($currentFirstVM.Name)' after mapping; found $($rdmDisks.Count)."
    }

    $copySpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $copySpec.DeviceChange = @()

    $controllerChange = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $controllerChange.Operation = 'add'
    $controllerChange.Device = $controller.ExtensionData
    $copySpec.DeviceChange += $controllerChange

    foreach ($rdmDisk in $rdmDisks) {
        $diskChange = New-Object VMware.Vim.VirtualDeviceConfigSpec
        $diskChange.Operation = 'add'
        $diskChange.Device = $rdmDisk.ExtensionData
        $copySpec.DeviceChange += $diskChange
    }

    foreach ($otherVM in $OtherVMs) {
        $currentOtherVM = Get-VM -Id $otherVM.Id
        Write-RichoLog "      Applying the same controller and $($rdmDisks.Count) disk(s) to '$($currentOtherVM.Name)'." -Level INFO
        (Get-View -Id $currentOtherVM.Id).ReconfigVM($copySpec)
    }
}

function Add-DestinationRdmGroups {
    <#
    .SYNOPSIS
        Maps every LUN group in a migration group back onto its VMs.

    .DESCRIPTION
        Runs once per group, after every VM in it has been relocated - the first VM owns
        the mapping files and the rest attach them, so they all have to be at the
        destination before any of it starts.

    .PARAMETER GroupPlan
        The resolved migration group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $GroupPlan
    )

    $firstVMItem = @($GroupPlan.VMItems | Sort-Object PowerOnOrder)[0]
    $otherVMs = @($GroupPlan.VMItems | Sort-Object PowerOnOrder | Select-Object -Skip 1 | ForEach-Object { $_.VM })

    foreach ($diskGroup in $GroupPlan.DiskGroups) {
        $controllerRecord = @($GroupPlan.Controllers | Where-Object { $_.ControllerBus -eq $diskGroup.ControllerBus })
        $controllerType = 'ParaVirtual'
        $busSharing = 'Physical'
        if ($controllerRecord.Count -eq 1) {
            $controllerType = ConvertTo-PowerCliControllerType -ControllerTypeName $controllerRecord[0].ControllerType
            $busSharing = ConvertTo-PowerCliBusSharing -SharedBus $controllerRecord[0].SharedBus
        }

        $detail = "Map LUN(s) $($diskGroup.LunIds -join ', ') from SVM '$($GroupPlan.Svm)' onto a new $controllerType controller ($busSharing bus sharing) for '$($firstVMItem.VM.Name)', then attach the same disks to $($otherVMs.Count) other VM(s)."
        Invoke-PlannedChange $GroupPlan.Name $firstVMItem.VM.Name 'MapLunGroup' "group $($diskGroup.ControllerBus)" $detail {
            $groupParameters = @{
                FirstVM        = $firstVMItem.VM
                OtherVMs       = $otherVMs
                LunIds         = [int[]]$diskGroup.LunIds
                Svm            = $GroupPlan.Svm
                RdmDatastore   = $GroupPlan.RdmDatastore
                ControllerType = $controllerType
                BusSharingMode = $busSharing
            }
            New-RdmDiskGroup @groupParameters
        }
    }
}

function Resolve-MigrationPlan {
    <#
    .SYNOPSIS
        Turns validated CSV rows into a fully resolved, verified migration plan.

    .DESCRIPTION
        Nothing is changed here. Every destination object is resolved, every LUN is
        resolved to a canonical device on every eligible host, and the source topology is
        proved to match both the CSV and the other VMs in the group. If any of that is
        wrong the run stops while the cluster is still up.

    .PARAMETER Rows
        Rows returned by Import-MigrationCsv.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Rows
    )

    $plans = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $Rows) {
        # The first VM names the group. It is unique across the CSV - a VM may appear in
        # only one row - so it identifies the row without a column of its own.
        $groupName = [string]$row.first_vm
        $destinationClusterName = [string]$row.destination_cluster
        $workloadType = [string]$row.workload_type
        $resourcePoolName = [string]$row.destination_resource_pool
        $datastoreClusterName = [string]$row.destination_datastore_cluster
        $svm = [string]$row.svm

        $batchNumber = [int]$row.batch
        $script:GroupInfoByName[$groupName] = [pscustomobject]@{
            WorkloadType = $workloadType
            Batch        = $batchNumber
        }
        Write-RichoLog "Resolving batch $batchNumber $workloadType migration group '$groupName' -> '$destinationClusterName'." -Level INFO

        Write-RichoLog "  Resolving destination objects in vCenter." -Level INFO
        $cluster = Get-ExactObject -Name $destinationClusterName -ObjectType 'destination cluster' -Lookup {
            Get-Cluster -Name $destinationClusterName -ErrorAction SilentlyContinue
        }

        $resourcePool = Get-ExactObject -Name $resourcePoolName -ObjectType 'resource pool' -Lookup {
            Get-ResourcePool -Location $cluster -Name $resourcePoolName -ErrorAction SilentlyContinue
        }
        $datastoreCluster = Get-ExactObject -Name $datastoreClusterName -ObjectType 'datastore cluster' -Lookup {
            Get-DatastoreCluster -Name $datastoreClusterName -ErrorAction SilentlyContinue
        }

        # An empty cell means "the conventional name for the destination cluster". A
        # derived name is matched without case, because the operator never typed it; a
        # name from the CSV is still held to the letter.
        $rdmDatastoreName = [string]$row.iSCSI_Data_Store
        $rdmDatastoreDerived = [string]::IsNullOrWhiteSpace($rdmDatastoreName)
        if ($rdmDatastoreDerived) {
            $rdmDatastoreName = Get-DefaultRdmDatastoreName -ClusterName $destinationClusterName -WorkloadType $workloadType
            Write-RichoLog "No RDM pointer datastore in the CSV for '$groupName'; using the conventional $workloadType name '$rdmDatastoreName'." -Level INFO
        }
        $rdmDatastore = Get-ExactObject -Name $rdmDatastoreName -ObjectType 'RDM pointer datastore' -CaseInsensitive:$rdmDatastoreDerived -Lookup {
            Get-Datastore -Name $rdmDatastoreName -ErrorAction SilentlyContinue
        }

        $vmNames = @([string]$row.first_vm) + @(ConvertTo-ValueList ([string]$row.other_vms_space_separated))

        # Group N becomes SCSI bus N. Bus 0 stays where it is - it carries the OS disk.
        $diskGroups = [System.Collections.Generic.List[object]]::new()
        $allLunIds = [System.Collections.Generic.List[int]]::new()
        $groupNumber = 0
        foreach ($column in @(
            'group_1_lun_IDs_ordered_space_separated',
            'group_2_lun_IDs_ordered_space_separated',
            'group_3_lun_IDs_ordered_space_separated'
        )) {
            $groupNumber++
            $ids = @(ConvertTo-ValueList ([string]$row.$column) | ForEach-Object { [int]$_ })
            if ($ids.Count -eq 0) { continue }
            foreach ($id in $ids) { $allLunIds.Add($id) }
            $diskGroups.Add([pscustomobject]@{
                ControllerBus = $groupNumber
                LunIds        = $ids
                UnitNumbers   = @(Get-ScsiUnitNumberSequence -Count $ids.Count)
            })
        }

        $eligibleHostParameters = @{
            Cluster          = $cluster
            DatastoreCluster = $datastoreCluster
            RdmDatastore     = $rdmDatastore
        }
        $eligibility = Get-EligibleDestinationHosts @eligibleHostParameters
        $eligibleHosts = $eligibility.Hosts
        if ($eligibleHosts.Count -eq 0) {
            $reasons = if ($eligibility.Exclusions.Count -gt 0) { " Hosts were excluded because - $($eligibility.Exclusions -join '; ')" } else { '' }
            throw "No eligible destination host in '$groupName' can mount both the destination datastore cluster and the RDM datastore.$reasons"
        }
        if (($eligibleHosts.Count -eq 1) -and ($vmNames.Count -gt 1)) {
            Write-RichoLog "Only one eligible host in '$groupName'; every node of this cluster will land on $($eligibleHosts[0].VMHost.Name). Separate them before the guests are brought back into service." -Level WARN
        }

        Write-RichoLog "  Reading the RDM topology of $($vmNames.Count) VM(s)." -Level INFO
        $vmItems = [System.Collections.Generic.List[object]]::new()
        $placementIndex = 0
        foreach ($vmName in $vmNames) {
            # Found by name across the vCenter, and the name must be unique: two VMs of the
            # same name is the one case where guessing which was meant is unacceptable.
            $vm = Get-ExactObject -Name $vmName -ObjectType 'VM' -Lookup {
                Get-VM -Name $vmName -ErrorAction SilentlyContinue
            }
            $layout = Get-VMRdmLayout -VM $vm
            Write-RichoLog "  $vmName : $($layout.Rdms.Count) physical RDM(s), powered $($vm.PowerState), on host $($vm.VMHost.Name)." -Level INFO
            if ($layout.View.Snapshot) { throw "VM '$vmName' has a snapshot." }
            if ($layout.Rdms.Count -ne $allLunIds.Count) {
                throw "VM '$vmName' has $($layout.Rdms.Count) physical RDMs but the CSV specifies $($allLunIds.Count)."
            }
            # Bus sharing is read, not required. These LUNs are physical-mode RDMs; whether
            # their controller shares its bus, and whether the disk itself is marked
            # shared, is the source's business and is put back exactly as found.
            foreach ($rdm in $layout.Rdms) {
                $sharingNote = if ($rdm.Sharing) { $rdm.Sharing } else { 'sharingNone' }
                Write-RichoLog "    $($rdm.Label): $($rdm.CompatibilityMode) RDM, bus sharing $($rdm.BusSharing), disk sharing $sharingNote." -Level INFO
            }

            # Where the VM is now is read off it, not asserted in the CSV, and travels
            # into the manifest so the change record says where it came from.
            $vmClusters = @(Get-Cluster -VM $vm -ErrorAction SilentlyContinue)
            $vmClusterName = if ($vmClusters.Count -eq 1) { [string]$vmClusters[0].Name } else { '' }
            if ($vmClusterName -ieq $destinationClusterName) {
                Write-RichoLog "VM '$vmName' is already in destination cluster '$destinationClusterName'. Check the row before running this live." -Level WARN
            }

            $destinationRecord = $eligibleHosts[$placementIndex % $eligibleHosts.Count]
            $placementIndex++
            $vmItems.Add([pscustomobject]@{
                VM              = $vm
                Layout          = $layout
                SourceCluster   = $vmClusterName
                DestinationHost = $destinationRecord.VMHost
                PowerOnOrder    = $placementIndex
            })
        }

        # Nodes of one SQL cluster normally live together. Coming from more than one
        # place is not fatal, but it is not what the row describes either.
        $sourceClusterNames = @($vmItems | ForEach-Object { $_.SourceCluster } | Where-Object { $_ } | Select-Object -Unique)
        if ($sourceClusterNames.Count -gt 1) {
            Write-RichoLog "Migration group '$groupName' draws VMs from more than one cluster: $($sourceClusterNames -join ', ')." -Level WARN
        }
        $sourceClusterLabel = if ($sourceClusterNames.Count -gt 0) { $sourceClusterNames -join ', ' } else { 'unknown' }

        $referenceItem = $vmItems[0]
        $referenceRdms = @($referenceItem.Layout.Rdms | Sort-Object ControllerBus, UnitNumber)

        # Every node must present the same disks at the same addresses on the same kind of
        # controller. If they do not, the CSV is describing a cluster this tool cannot put
        # back together identically.
        foreach ($vmItem in $vmItems) {
            $actual = @($vmItem.Layout.Rdms | Sort-Object ControllerBus, UnitNumber)
            for ($index = 0; $index -lt $actual.Count; $index++) {
                $reference = $referenceRdms[$index]
                $current = $actual[$index]
                if (($current.ControllerBus -ne $reference.ControllerBus) -or
                    ($current.UnitNumber -ne $reference.UnitNumber) -or
                    ($current.ControllerType -ne $reference.ControllerType) -or
                    ($current.BusSharing -ne $reference.BusSharing) -or
                    ($current.Sharing -ne $reference.Sharing) -or
                    ($current.CompatibilityMode -ne $reference.CompatibilityMode) -or
                    ([math]::Abs($current.CapacityGB - $reference.CapacityGB) -gt $script:CapacityToleranceGB)) {
                    throw "VM '$($vmItem.VM.Name)' RDM topology differs from '$($referenceItem.VM.Name)' at index $index."
                }
            }
        }

        $controllers = [System.Collections.Generic.List[object]]::new()
        foreach ($bus in @($referenceRdms | ForEach-Object { $_.ControllerBus } | Select-Object -Unique | Sort-Object)) {
            $sample = @($referenceRdms | Where-Object { $_.ControllerBus -eq $bus })[0]
            $controllers.Add([pscustomobject]@{
                ControllerBus  = $bus
                ControllerType = $sample.ControllerType
                ShortType      = ($sample.ControllerType -split '\.')[-1]
                SharedBus      = $sample.BusSharing
            })
        }

        # The plan records what the CSV asks for, address by address, and the source
        # topology it must match. It does NOT resolve devices: the LUN ID is resolved to a
        # device on the VM's own host at attach time, which is where the estate's proven
        # mapping sequence does it, and the only place the answer is guaranteed right.
        $plannedDisks = [System.Collections.Generic.List[object]]::new()
        $diskIndex = 0
        foreach ($diskGroup in $diskGroups) {
            for ($position = 0; $position -lt $diskGroup.LunIds.Count; $position++) {
                $lunId = $diskGroup.LunIds[$position]
                $unitNumber = $diskGroup.UnitNumbers[$position]
                $reference = $referenceRdms[$diskIndex]

                if (($reference.ControllerBus -ne $diskGroup.ControllerBus) -or ($reference.UnitNumber -ne $unitNumber)) {
                    throw "Source topology differs from CSV order at LUN $lunId : the CSV places it at SCSI $($diskGroup.ControllerBus):$unitNumber, the source has SCSI $($reference.ControllerBus):$($reference.UnitNumber)."
                }

                $plannedDisks.Add([pscustomobject]@{
                    LunId         = $lunId
                    ControllerBus = $diskGroup.ControllerBus
                    UnitNumber    = $unitNumber
                    CapacityGB    = $reference.CapacityGB
                    SourceLabel   = $reference.Label
                    SourceDevice  = $reference.CanonicalName
                })
                $diskIndex++
            }
        }

        Write-RichoLog "  Plan resolved: $($plannedDisks.Count) LUN(s) across $($diskGroups.Count) group(s)." -Level INFO
        foreach ($plannedDisk in $plannedDisks) {
            Write-RichoLog "    LUN $($plannedDisk.LunId) -> SCSI $($plannedDisk.ControllerBus):$($plannedDisk.UnitNumber), replacing '$($plannedDisk.SourceLabel)' ($($plannedDisk.CapacityGB) GB, $($plannedDisk.SourceDevice))" -Level INFO
        }

        # Presentation is the engineer's prerequisite. It is stated, never checked - the
        # LUNs are assumed present, and every check of that was slow, and one of them
        # compared a vml identifier against a naa and stopped a good run.
        $destinationHostNames = @($eligibleHosts | ForEach-Object { $_.VMHost.Name })
        $prerequisite = [System.Collections.Generic.List[string]]::new()
        $prerequisite.Add("These LUNs from SVM '$svm' must already be presented to $($destinationHostNames -join ', ') and the HBAs rescanned:")
        foreach ($diskGroup in $diskGroups) {
            $prerequisite.Add("  group $($diskGroup.ControllerBus): LUN $($diskGroup.LunIds -join ', ')")
        }

        Write-RichoLog '  ---- PREREQUISITE, assumed and not checked ----' -Level INFO
        foreach ($line in $prerequisite) { Write-RichoLog "  $line" -Level INFO }
        Write-RichoLog '  -----------------------------------------------' -Level INFO

        $plans.Add([pscustomobject]@{
            Name                = $groupName
            WorkloadType        = $workloadType
            Batch               = $batchNumber
            Svm                 = $svm
            SourceClusters      = $sourceClusterNames
            SourceClusterLabel  = $sourceClusterLabel
            Cluster             = $cluster
            ResourcePool        = $resourcePool
            DatastoreCluster    = $datastoreCluster
            RdmDatastore        = $rdmDatastore
            RdmDatastoreDerived = $rdmDatastoreDerived
            VMItems             = $vmItems.ToArray()
            Disks               = $plannedDisks.ToArray()
            DiskGroups          = $diskGroups.ToArray()
            Controllers         = $controllers.ToArray()
            Prerequisite        = $prerequisite.ToArray()
            HostExclusions      = $eligibility.Exclusions
        })
    }

    return $plans.ToArray()
}

function New-MigrationManifest {
    <#
    .SYNOPSIS
        Builds the pre-change evidence record for one migration group.

    .PARAMETER GroupPlan
        The resolved group plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $GroupPlan
    )

    return [ordered]@{
        ScriptVersion               = $ScriptVersion
        Mode                        = $script:RunMode
        RunScope                    = $script:RunScope
        Generated                   = (Get-Date).ToString('o')
        VCenter                     = $VCenter
        MigrationGroup              = $GroupPlan.Name
        WorkloadType                = $GroupPlan.WorkloadType
        Batch                       = $GroupPlan.Batch
        Svm                         = $GroupPlan.Svm
        SourceClusters              = $GroupPlan.SourceClusters
        DestinationCluster          = $GroupPlan.Cluster.Name
        DestinationResourcePool     = $GroupPlan.ResourcePool.Name
        DestinationDatastoreCluster = $GroupPlan.DatastoreCluster.Name
        RdmDatastore                = $GroupPlan.RdmDatastore.Name
        RdmDatastoreDerived         = $GroupPlan.RdmDatastoreDerived
        PresentationPrerequisite    = $GroupPlan.Prerequisite
        DiskGroups                  = @($GroupPlan.DiskGroups | ForEach-Object {
            [ordered]@{ ControllerBus = $_.ControllerBus; LunIds = $_.LunIds }
        })
        ExcludedHosts               = $GroupPlan.HostExclusions
        Controllers                 = $GroupPlan.Controllers
        VMs = @($GroupPlan.VMItems | ForEach-Object {
            [ordered]@{
                Name               = $_.VM.Name
                Id                 = $_.VM.Id
                OriginalPowerState = [string]$_.VM.PowerState
                SourceCluster      = [string]$_.SourceCluster
                SourceHost         = [string]$_.VM.VMHost.Name
                DestinationHost    = [string]$_.DestinationHost.Name
                PowerOnOrder       = $_.PowerOnOrder
                ChangeVersion      = [string]$_.Layout.View.Config.ChangeVersion
                VmxPath            = [string]$_.Layout.View.Config.Files.VmPathName
                Rdms               = $_.Layout.Rdms
            }
        })
        DestinationLuns = $GroupPlan.Disks
    }
}

function Confirm-MigrationOutcome {
    <#
    .SYNOPSIS
        Re-reads each VM after the mapping and checks what it actually got.

    .DESCRIPTION
        Evidence, not decoration. What can be known is checked, and nothing else is
        pretended: the bus numbers are vCenter's to assign when the controllers are
        created, so they are reported rather than demanded. What must hold is that every
        node ended up with the same number of physical RDMs, in the same group shapes the
        CSV asked for, at contiguous units from zero, and - the one that matters for a
        cluster - that every node sees the same device at the same address.

    .PARAMETER GroupPlan
        The resolved group plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $GroupPlan
    )

    $records = [System.Collections.Generic.List[object]]::new()
    $expectedTotal = @($GroupPlan.Disks).Count
    $expectedGroupSizes = @($GroupPlan.DiskGroups | ForEach-Object { @($_.LunIds).Count } | Sort-Object)

    foreach ($vmItem in $GroupPlan.VMItems) {
        $currentVM = Get-VM -Id $vmItem.VM.Id
        $layout = Get-VMRdmLayout -VM $currentVM

        # Read the pool rather than a property of the VM object: which of ResourcePool and
        # ResourcePoolId a VirtualMachine carries has changed between PowerCLI releases,
        # and under StrictMode reading the wrong one is a terminating error.
        $pools = @(Get-ResourcePool -VM $currentVM -ErrorAction SilentlyContinue)
        $poolName = if ($pools.Count -gt 0) { [string]$pools[0].Name } else { '' }

        $rdms = @($layout.Rdms | Sort-Object ControllerBus, UnitNumber)
        $groupSizes = @($rdms | Group-Object ControllerBus | ForEach-Object { $_.Count } | Sort-Object)

        $vmFindings = [System.Collections.Generic.List[string]]::new()
        if ($rdms.Count -ne $expectedTotal) {
            $vmFindings.Add("has $($rdms.Count) physical RDM(s); the CSV asks for $expectedTotal")
        }
        if (($groupSizes -join ',') -ne ($expectedGroupSizes -join ',')) {
            $vmFindings.Add("groups its RDMs as $($groupSizes -join '+') across controllers; the CSV asks for $($expectedGroupSizes -join '+')")
        }

        # Sizes, as a set: the addresses can legitimately land on a different bus number
        # than the source used, but the disks themselves cannot change size.
        $actualCapacities = @($rdms | ForEach-Object { [math]::Round($_.CapacityGB, 0) } | Sort-Object)
        $expectedCapacities = @($GroupPlan.Disks | ForEach-Object { [math]::Round($_.CapacityGB, 0) } | Sort-Object)
        if (($actualCapacities -join ',') -ne ($expectedCapacities -join ',')) {
            $vmFindings.Add("carries $($actualCapacities -join ', ') GB; the RDMs it replaces were $($expectedCapacities -join ', ') GB")
        }

        foreach ($busGroup in @($rdms | Group-Object ControllerBus)) {
            $units = @($busGroup.Group | ForEach-Object { [int]$_.UnitNumber } | Sort-Object)
            $expectedUnits = @(Get-ScsiUnitNumberSequence -Count $units.Count)
            if (($units -join ',') -ne ($expectedUnits -join ',')) {
                $vmFindings.Add("SCSI $($busGroup.Name) carries units $($units -join ',') rather than $($expectedUnits -join ',')")
            }
        }

        foreach ($rdm in $rdms) {
            $status = 'Passed'
            $detail = "SCSI $($rdm.ControllerBus):$($rdm.UnitNumber) carries $($rdm.CanonicalName) at $($rdm.CapacityGB) GB, $($rdm.CompatibilityMode) on a $($rdm.BusSharing) bus."
            if ($rdm.CompatibilityMode -ne 'physicalMode') {
                $status = 'Failed'
                $detail = "SCSI $($rdm.ControllerBus):$($rdm.UnitNumber) is '$($rdm.CompatibilityMode)', expected physicalMode."
            }
            elseif ($vmFindings.Count -gt 0) {
                $status = 'Failed'
                $detail = "$($currentVM.Name) $($vmFindings -join '; ')."
            }

            $records.Add([pscustomobject]@{
                ScriptVersion  = $ScriptVersion
                MigrationGroup = $GroupPlan.Name
                WorkloadType   = $GroupPlan.WorkloadType
                Batch          = $GroupPlan.Batch
                VM             = $currentVM.Name
                VMHost         = [string]$currentVM.VMHost.Name
                ResourcePool   = $poolName
                PowerState     = [string]$currentVM.PowerState
                ScsiAddress    = "$($rdm.ControllerBus):$($rdm.UnitNumber)"
                Device         = $rdm.CanonicalName
                CapacityGB     = $rdm.CapacityGB
                Status         = $status
                Detail         = $detail
            })
        }

        if ($rdms.Count -eq 0) {
            $records.Add([pscustomobject]@{
                ScriptVersion  = $ScriptVersion
                MigrationGroup = $GroupPlan.Name
                WorkloadType   = $GroupPlan.WorkloadType
                Batch          = $GroupPlan.Batch
                VM             = $currentVM.Name
                VMHost         = [string]$currentVM.VMHost.Name
                ResourcePool   = $poolName
                PowerState     = [string]$currentVM.PowerState
                ScsiAddress    = ''
                Device         = ''
                CapacityGB     = 0
                Status         = 'Failed'
                Detail         = "$($currentVM.Name) has no physical RDMs; the CSV asks for $expectedTotal."
            })
        }
    }

    # A cluster whose nodes do not see the same device at the same address is not a
    # cluster. This catches a copy spec that went astray, or a node that missed a disk.
    foreach ($addressGroup in @($records | Where-Object { $_.ScsiAddress } | Group-Object ScsiAddress)) {
        $devices = @($addressGroup.Group | ForEach-Object { $_.Device } | Select-Object -Unique)
        if ($devices.Count -le 1) { continue }
        foreach ($record in $addressGroup.Group) {
            $record.Status = 'Failed'
            $record.Detail = "SCSI $($addressGroup.Name) is not the same device on every node: $($devices -join ', ')."
        }
    }

    return $records.ToArray()
}

function Show-RdmMapping {
    <#
    .SYNOPSIS
        Prints what each VM in the group ended up with, controller by controller.

    .DESCRIPTION
        Read back off the VMs, not recited from the plan: this is the last thing an
        operator sees before deciding whether to boot a SQL cluster, so it has to be what
        is actually there.

    .PARAMETER GroupPlan
        The resolved migration group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $GroupPlan
    )

    Write-RichoLog "  ===== Mapped LUNs for '$($GroupPlan.Name)' =====" -Level INFO

    foreach ($vmItem in @($GroupPlan.VMItems | Sort-Object PowerOnOrder)) {
        $currentVM = Get-VM -Id $vmItem.VM.Id
        $layout = Get-VMRdmLayout -VM $currentVM
        $rdms = @($layout.Rdms | Sort-Object ControllerBus, UnitNumber)

        Write-RichoLog "    $($currentVM.Name) on $($currentVM.VMHost.Name) - $($rdms.Count) RDM(s), powered $($currentVM.PowerState)" -Level INFO

        foreach ($busGroup in @($rdms | Group-Object ControllerBus)) {
            $sample = $busGroup.Group[0]
            $shortType = ($sample.ControllerType -split '\.')[-1]
            Write-RichoLog "      SCSI $($busGroup.Name)  $shortType, bus sharing $($sample.BusSharing)" -Level INFO
            foreach ($rdm in $busGroup.Group) {
                Write-RichoLog ("        {0,-6} {1,-40} {2,10} GB  {3}" -f "$($rdm.ControllerBus):$($rdm.UnitNumber)", $rdm.CanonicalName, $rdm.CapacityGB, $rdm.CompatibilityMode) -Level INFO
            }
        }

        if ($rdms.Count -eq 0) {
            Write-RichoLog '      no RDMs are attached' -Level WARN
        }
    }

    Write-RichoLog "  ================================================" -Level INFO
}

function Request-PowerOnConfirmation {
    <#
    .SYNOPSIS
        Asks the operator whether to power the group on.

    .DESCRIPTION
        Anything but an explicit yes means no. A run with nothing on the other end of the
        console - a scheduled task, a redirected session - reads an empty line and leaves
        the VMs off, which is the safe way round for a SQL cluster.

    .PARAMETER GroupPlan
        The resolved migration group.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        $GroupPlan
    )

    $answer = Read-Host "  Mapping above looks right - power on the $($GroupPlan.VMItems.Count) VM(s) of '$($GroupPlan.Name)' now? [y/N]"
    return ([string]$answer).Trim() -match '^(y|yes)$'
}

function Invoke-GroupPowerOn {
    <#
    .SYNOPSIS
        Powers on the VMs of one migration group, once that group is complete.

    .DESCRIPTION
        A line item in the CSV is one SQL cluster, and it comes back up as one: every VM
        in the row relocated, every LUN mapped on every node, and the placement verified,
        before the first of them is started. A node that boots while a sibling is still
        being mapped can bring shared disks online against a half-assembled cluster.

        Order within the group is first_vm, then the rest as the CSV lists them.

    .PARAMETER GroupPlan
        The resolved migration group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $GroupPlan
    )

    Write-RichoLog "  Powering on $($GroupPlan.VMItems.Count) VM(s) of $($GroupPlan.WorkloadType) group '$($GroupPlan.Name)', in CSV order." -Level INFO

    foreach ($vmItem in @($GroupPlan.VMItems | Sort-Object PowerOnOrder)) {
        $powerOnDetail = "Power on $($GroupPlan.WorkloadType) VM '$($vmItem.VM.Name)' in sequence position $($vmItem.PowerOnOrder) of group '$($GroupPlan.Name)'."
        Invoke-PlannedChange $GroupPlan.Name $vmItem.VM.Name 'PowerOn' $vmItem.VM.Name $powerOnDetail {
            Start-VM -VM (Get-VM -Id $vmItem.VM.Id) -Confirm:$false | Out-Null
        }
    }
}

function Export-RunArtifact {
    <#
    .SYNOPSIS
        Writes one collection to a timestamped CSV in the output folder.

    .PARAMETER Records
        The rows to write. An empty collection writes nothing.

    .PARAMETER Name
        File name stem, e.g. 'results'.

    .PARAMETER Folder
        Destination folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Records,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Folder
    )

    if ($Records.Count -eq 0) { return }

    $path = Join-Path $Folder ("{0}-{1}.csv" -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $Records | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    Write-RichoLog "Wrote $($Records.Count) $Name rows to $path" -Level INFO
}

# Loaded before the try block so the logging function the catch and finally blocks rely
# on is guaranteed to exist by the time either can run. PowerCLI takes tens of seconds
# to load on a cold session, so say so first - through the host, since the logger this
# script carries is not usable until its own definition has been reached, which it has.
Write-RichoLog 'Loading PowerCLI. On a cold session this can take a minute.' -Level INFO
$moduleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Import-RequiredModules
$moduleStopwatch.Stop()
Write-RichoLog "PowerCLI ready ($(Format-Elapsed -Elapsed $moduleStopwatch.Elapsed))." -Level INFO

$script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $bannerMode = if ($Execute) { 'EXECUTE' } else { 'DRY RUN - nothing will be changed' }
    Write-RichoLog "Invoke-SqlRdmClusterMigration v$ScriptVersion - $bannerMode against $VCenter" -Level INFO

    # Which file actually ran, and when it was last written. These scripts are run from a
    # versioned folder on a share, and a stale copy there reports failures that were fixed
    # releases ago - a whole afternoon was spent on two of them.
    if ($PSCommandPath) {
        $scriptFile = Get-Item -LiteralPath $PSCommandPath
        Write-RichoLog "Running $($scriptFile.FullName), last written $($scriptFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm')), $([math]::Round($scriptFile.Length / 1KB)) KB." -Level INFO
    }

    if ($IgnoreInvalidCertificate) {
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
    }
    Set-PowerCLIConfiguration -DefaultVIServerMode Single -ParticipateInCeip:$false -Scope Session -Confirm:$false | Out-Null

    if ($null -eq $Credential) {
        $credentialTarget = if ($CredentialName) { $CredentialName } else { $VCenter }
        $Credential = Get-RichoCredential -Name $credentialTarget
    }

    Write-RichoLog "Connecting to $VCenter." -Level INFO
    $connectStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $connection = Connect-VIServer -Server $VCenter -Credential $Credential
    $connectStopwatch.Stop()
    Write-RichoLog "Connected to $($connection.Name) as $($connection.User) ($(Format-Elapsed -Elapsed $connectStopwatch.Elapsed))." -Level INFO

    $rows = @(Import-MigrationCsv -Path $CsvPath)
    Write-RichoLog "Loaded $($rows.Count) migration group(s) from $CsvPath." -Level INFO

    $selection = Select-MigrationRows -Rows $rows -VMName $VMName -Batch $Batch
    $script:RunScope = $selection.Scope
    Write-RichoLog "Running $($selection.Scope): $($selection.Rows.Count) migration group(s), in batch order." -Level INFO

    Write-RichoLog 'Resolving the migration plan against live inventory. No changes are made in this phase.' -Level INFO
    $planStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $plans = @(Resolve-MigrationPlan -Rows $selection.Rows)
    $planStopwatch.Stop()
    Write-RichoLog "Plan resolved for $($plans.Count) group(s) in $(Format-Elapsed -Elapsed $planStopwatch.Elapsed)." -Level INFO

    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }

    foreach ($groupPlan in $plans) {
        Write-RichoLog "===== Migration group $($groupPlan.Name) [batch $($groupPlan.Batch), $($groupPlan.WorkloadType)] =====" -Level INFO
        Write-RichoLog "$($groupPlan.VMItems.Count) VM(s), $($groupPlan.Disks.Count) LUN(s) in $($groupPlan.DiskGroups.Count) group(s), $($groupPlan.SourceClusterLabel) -> $($groupPlan.Cluster.Name)/$($groupPlan.ResourcePool.Name), mapping files on $($groupPlan.RdmDatastore.Name)." -Level INFO

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $modeLabel = if ($DryRun) { 'dryrun' } else { 'execution' }
        $safeGroupName = $groupPlan.Name -replace '[^\w.-]', '_'
        $manifestPath = Join-Path $OutputFolder "$safeGroupName-$modeLabel-manifest-$stamp.json"
        New-MigrationManifest -GroupPlan $groupPlan |
            ConvertTo-Json -Depth 12 |
            Set-Content -LiteralPath $manifestPath -Encoding UTF8
        Add-Result $groupPlan.Name '' 'Preflight' 'Passed' "Manifest written to $manifestPath"

        # Every VM in the group comes down and gives up its shared disks before any of them
        # moves. A half-migrated WSFC with one node still holding the RDMs is the state
        # this ordering exists to prevent.
        Write-RichoLog "  Phase 1 of 4: powering down $($groupPlan.VMItems.Count) VM(s) and detaching their RDMs." -Level INFO
        $vmIndex = 0
        foreach ($vmItem in $groupPlan.VMItems) {
            $vmIndex++
            Write-RichoLog "    [$vmIndex/$($groupPlan.VMItems.Count)] $($vmItem.VM.Name)" -Level INFO
            Write-Progress -Activity "Group $($groupPlan.Name): shutdown and detach" -Status $vmItem.VM.Name -PercentComplete ([int](($vmIndex / [math]::Max(1, $groupPlan.VMItems.Count)) * 100))
            Stop-VMForMigration -VMItem $vmItem -MigrationGroup $groupPlan.Name
            $removalParameters = @{
                VMItem         = $vmItem
                MigrationGroup = $groupPlan.Name
                PlannedBuses   = [int[]]@($groupPlan.Disks | ForEach-Object { $_.ControllerBus } | Select-Object -Unique)
            }
            Remove-RdmsAndControllers @removalParameters
        }
        Write-Progress -Activity "Group $($groupPlan.Name): shutdown and detach" -Completed

        Write-RichoLog "  Phase 2 of 4: relocating. A cold move of a large VM takes minutes." -Level INFO
        $vmIndex = 0
        foreach ($vmItem in $groupPlan.VMItems) {
            $vmIndex++
            Write-RichoLog "    [$vmIndex/$($groupPlan.VMItems.Count)] $($vmItem.VM.Name) -> $($vmItem.DestinationHost.Name)" -Level INFO
            Write-Progress -Activity "Group $($groupPlan.Name): relocate" -Status $vmItem.VM.Name -PercentComplete ([int](($vmIndex / [math]::Max(1, $groupPlan.VMItems.Count)) * 100))
            $relocateDetail = "Cold-relocate '$($vmItem.VM.Name)' to host '$($vmItem.DestinationHost.Name)', datastore cluster '$($groupPlan.DatastoreCluster.Name)' and resource pool '$($groupPlan.ResourcePool.Name)'."
            Invoke-PlannedChange $groupPlan.Name $vmItem.VM.Name 'ColdRelocate' $vmItem.DestinationHost.Name $relocateDetail {
                # Run the relocate as a task so its percentage can be reported. A cold
                # move of a large VM is otherwise several minutes of silence.
                $moveParameters = @{
                    VM          = Get-VM -Id $vmItem.VM.Id
                    Destination = $vmItem.DestinationHost
                    Datastore   = $groupPlan.DatastoreCluster
                    RunAsync    = $true
                    Confirm     = $false
                }
                $moveTask = Move-VM @moveParameters
                Wait-VMLongTask -Task $moveTask -Activity "Relocating '$($vmItem.VM.Name)' to $($vmItem.DestinationHost.Name)"

                Write-RichoLog "      Moving '$($vmItem.VM.Name)' into resource pool '$($groupPlan.ResourcePool.Name)'." -Level INFO
                $currentView = Get-View -Id $vmItem.VM.Id
                $poolView = Get-View -Id $groupPlan.ResourcePool.Id
                $poolView.MoveIntoResourcePool([VMware.Vim.ManagedObjectReference[]]@($currentView.MoRef))
            }
        }
        Write-Progress -Activity "Group $($groupPlan.Name): relocate" -Completed

        # Every VM has to be at the destination before any mapping starts: the first VM
        # owns the mapping files and the rest attach the very same ones.
        Write-RichoLog "  Phase 3 of 4: mapping $($groupPlan.Disks.Count) LUN(s) back, group by group." -Level INFO
        Add-DestinationRdmGroups -GroupPlan $groupPlan

        Write-RichoLog "  Phase 4 of 4: verifying." -Level INFO
        if ($DryRun) {
            Add-Result $groupPlan.Name '' 'Verify' 'DryRun' 'Post-migration verification runs only in an execution run.'
        }
        else {
            $groupVerification = @(Confirm-MigrationOutcome -GroupPlan $groupPlan)
            $script:VerificationRows.AddRange($groupVerification)
            $failures = @($groupVerification | Where-Object { $_.Status -ne 'Passed' })
            foreach ($failure in $failures) {
                Add-Result $groupPlan.Name $failure.VM 'Verify' 'Failed' "SCSI $($failure.ScsiAddress): $($failure.Detail)"
            }
            if ($failures.Count -gt 0) {
                throw "Post-migration verification failed for $($failures.Count) disk(s) in '$($groupPlan.Name)'. See the verification CSV."
            }
            Add-Result $groupPlan.Name '' 'Verify' 'Passed' "All $($groupVerification.Count) disk placements match the plan."
        }

        # The line item is complete: relocated, mapped and verified. What landed where is
        # printed, and then it is the operator's call.
        if ($DryRun) {
            Add-Result $groupPlan.Name '' 'PowerOn' 'DryRun' 'An execution run prints the mapping and asks before powering anything on.'
        }
        else {
            Show-RdmMapping -GroupPlan $groupPlan
            if (Request-PowerOnConfirmation -GroupPlan $groupPlan) {
                Invoke-GroupPowerOn -GroupPlan $groupPlan
            }
            else {
                Write-RichoLog "  Left powered off at your request. '$($groupPlan.Name)' is migrated and mapped; start the VMs when you are ready." -Level INFO
                Add-Result $groupPlan.Name '' 'PowerOn' 'Skipped' 'The operator chose not to power the group on.'
            }
        }

        $groupStatus = if ($DryRun) { 'DryRunPassed' } else { 'Succeeded' }
        Add-Result $groupPlan.Name '' 'Group' $groupStatus 'Migration group processing completed.'
        Write-RichoLog "Migration group $($groupPlan.Name): $groupStatus." -Level INFO
    }

    $succeeded = @($script:Results | Where-Object { $_.Status -eq 'Succeeded' }).Count
    $planned = @($script:Results | Where-Object { $_.Status -eq 'DryRun' }).Count
    Write-RichoLog "All $($plans.Count) group(s) processed in $(Format-Elapsed -Elapsed $script:RunStopwatch.Elapsed): $succeeded change(s) made, $planned planned." -Level INFO
}
catch {
    # -ErrorAction Continue so the logger's own Write-Error does not become the
    # terminating error: without it the rethrow below never runs and the failure is
    # reported against the logging line instead of the line that actually failed.
    $failure = $_
    Add-Result '' '' 'Fatal' 'Failed' $failure.Exception.Message
    Write-RichoLog "Failed: $($failure.Exception.Message)" -Level ERROR -ErrorAction Continue
    throw $failure
}
finally {
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (Test-Path -LiteralPath $OutputFolder) {
        Export-RunArtifact -Records $script:Plan.ToArray() -Name 'change-plan' -Folder $OutputFolder
        Export-RunArtifact -Records $script:Results.ToArray() -Name 'results' -Folder $OutputFolder
        Export-RunArtifact -Records $script:VerificationRows.ToArray() -Name 'verification' -Folder $OutputFolder
    }
    if ($connection) {
        Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($script:RunStopwatch) {
        $script:RunStopwatch.Stop()
        Write-RichoLog "Run finished in $(Format-Elapsed -Elapsed $script:RunStopwatch.Elapsed)." -Level INFO
    }
}
