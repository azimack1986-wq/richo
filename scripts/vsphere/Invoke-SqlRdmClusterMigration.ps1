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

.PARAMETER VerifyLunPresentation
    Read the destination hosts' storage and confirm every LUN in the CSV is presented
    before anything is changed. Off by default: presentation and rescanning are the
    engineer's prerequisite, and the read costs one storage enumeration per host.

.PARAMETER SkipDeviceCheck
    Skip even the quick "can the destination host see this device" check. That check is
    one storage read per destination host and it runs before anything is powered off;
    skipping it means a device that is not presented is found at the attach instead,
    with the VMs already down and moved.

.PARAMETER PowerOnAfterMigration
    Power the VMs on at the destination once every migration group has been relocated,
    re-attached and verified - a workload type at a time, groups in CSV order and VMs in
    power-on order within each group. Without it the VMs are left powered off.

.PARAMETER OutputFolder
    Where the manifest, plan, results and verification files are written.

.PARAMETER IgnoreInvalidCertificate
    Accept an untrusted vCenter certificate for this session only.

.EXAMPLE
    .\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01.example.com -CsvPath .\SqlRdmClusterMigration.csv -DryRun -PowerAction ShutdownGuest

    Validates the CSV against live inventory and writes the plan without changing anything.

.EXAMPLE
    .\Invoke-SqlRdmClusterMigration.ps1 -VCenter vcenter01.example.com -CsvPath .\SqlRdmClusterMigration.csv -Execute -PowerAction ShutdownGuest -ShutdownTimeoutMinutes 20 -PowerOnAfterMigration

    Migrates every row in the CSV and powers the VMs on at the destination, a workload
    type at a time.

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
    [switch]$PowerOnAfterMigration,

    [Parameter()]
    [switch]$VerifyLunPresentation,

    [Parameter()]
    [switch]$SkipDeviceCheck,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputFolder = (Join-Path (Get-Location) 'SqlRdmClusterMigrationOutput'),

    [Parameter()]
    [switch]$IgnoreInvalidCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '2.11.0'
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

    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) {
        throw 'CSV contains no data rows.'
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
        $capacityBytes = [double]$device.CapacityInBytes
        if ($capacityBytes -le 0) {
            $capacityBytes = [double]$device.CapacityInKB * 1024
        }

        $rdms.Add([pscustomobject]@{
            Label          = [string]$device.DeviceInfo.Label
            CanonicalName  = $canonicalName
            DeviceName     = [string]$backing.DeviceName
            CapacityGB     = [math]::Round($capacityBytes / 1GB, 3)
            ControllerBus  = [int]$controller.BusNumber
            UnitNumber     = [int]$device.UnitNumber
            BusSharing     = [string]$controller.SharedBus
            ControllerKey  = [int]$device.ControllerKey
            ControllerType = $controller.GetType().FullName
            LunUuid        = [string]$backing.LunUuid
            BackingFile    = [string]$backing.FileName
        })
    }

    return [pscustomobject]@{
        View = $view
        Rdms = $rdms.ToArray()
    }
}

function Get-HostStorageMap {
    <#
    .SYNOPSIS
        Reads a host's iSCSI paths and disk devices once, for repeated LUN lookups.

    .DESCRIPTION
        Resolving a LUN used to run one esxcli path enumeration and one Get-ScsiLun per
        LUN per host. A three-controller cluster of twelve LUNs across eight hosts is
        ~200 round trips to answer a question that takes two per host.

    .PARAMETER VMHost
        The host to read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VMHost
    )

    $esxcli = Get-EsxCli -VMHost $VMHost -V2
    $paths = @($esxcli.storage.core.path.list.Invoke())
    $scsiLuns = @(Get-ScsiLun -VMHost $VMHost -LunType Disk)

    $lunsByCanonicalName = @{}
    foreach ($scsiLun in $scsiLuns) {
        $lunsByCanonicalName[([string]$scsiLun.CanonicalName).ToLowerInvariant()] = $scsiLun
    }

    return [pscustomobject]@{
        VMHost              = $VMHost
        Paths               = $paths
        LunsByCanonicalName = $lunsByCanonicalName
    }
}

function Resolve-DestinationLun {
    <#
    .SYNOPSIS
        Resolves an SVM plus LUN ID to exactly one device on one host.

    .DESCRIPTION
        The operator supplies the SVM and the LUN ID because those are what the storage
        team hands over. The canonical name is derived here and then verified to be the
        same device on every eligible host, so a typo cannot quietly become a different
        LUN on a different node of the same cluster.

    .PARAMETER StorageMap
        The host storage map from Get-HostStorageMap.

    .PARAMETER Svm
        SVM name, matched against the path target identifier.

    .PARAMETER LunId
        The LUN ID as presented by the array.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $StorageMap,

        [Parameter(Mandatory)]
        [string]$Svm,

        [Parameter(Mandatory)]
        [int]$LunId
    )

    $hostName = $StorageMap.VMHost.Name
    $paths = @(
        $StorageMap.Paths |
            Where-Object {
                ([int]$_.LUN -eq $LunId) -and ([string]$_.TargetIdentifier -like "*$Svm*")
            }
    )

    if ($paths.Count -eq 0) {
        throw "Host '$hostName' has no path for SVM '$Svm', LUN $LunId."
    }

    $deviceNames = @(
        $paths |
            ForEach-Object { [string]$_.Device } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    if ($deviceNames.Count -ne 1) {
        throw "Host '$hostName' resolves SVM '$Svm', LUN $LunId to $($deviceNames.Count) devices; expected one."
    }

    $canonicalName = $deviceNames[0].ToLowerInvariant()
    if (-not $StorageMap.LunsByCanonicalName.ContainsKey($canonicalName)) {
        throw "Host '$hostName' has a path to '$($deviceNames[0])' but no matching disk device; rescan the HBAs."
    }

    $scsiLun = $StorageMap.LunsByCanonicalName[$canonicalName]

    return [pscustomobject]@{
        LunId             = $LunId
        CanonicalName     = $canonicalName
        ConsoleDeviceName = [string]$scsiLun.ConsoleDeviceName
        CapacityGB        = [math]::Round([double]$scsiLun.CapacityGB, 3)
        PathCount         = $paths.Count
    }
}

function Assert-DeviceVisible {
    <#
    .SYNOPSIS
        Confirms the destination hosts can see the devices the RDMs will be re-attached to.

    .DESCRIPTION
        One Get-ScsiLun per destination host - the hosts actually chosen, not every host
        in the cluster, and no per-LUN path enumeration. It exists because the alternative
        is finding out at the attach, which happens after the VMs are powered off, their
        RDMs detached and the machines relocated: the worst possible moment and the
        hardest state to unpick.

        This is not the presentation check; -VerifyLunPresentation is. This only asks
        whether the device the VM already has is visible where the VM is going.

    .PARAMETER DestinationHosts
        The hosts the VMs will be placed on.

    .PARAMETER Disks
        The resolved destination disks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$DestinationHosts,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Disks
    )

    foreach ($destinationHost in $DestinationHosts) {
        $visible = @{}
        foreach ($scsiLun in @(Get-ScsiLun -VMHost $destinationHost -LunType Disk)) {
            $visible[([string]$scsiLun.CanonicalName).ToLowerInvariant()] = $true
        }

        $missing = @($Disks | Where-Object { -not $visible.ContainsKey($_.CanonicalName) })
        if ($missing.Count -gt 0) {
            $names = @($missing | ForEach-Object { "LUN $($_.LunId) ($($_.CanonicalName))" }) -join ', '
            throw "Host '$($destinationHost.Name)' cannot see $names. Present the LUNs to it and rescan the HBAs, then run again."
        }

        Write-RichoLog "    $($destinationHost.Name): all $($Disks.Count) device(s) visible." -Level INFO
    }
}

function Confirm-LunPresentation {
    <#
    .SYNOPSIS
        Reads the destination hosts back and confirms every LUN is presented.

    .DESCRIPTION
        Only ever run on request. Presenting the LUNs and rescanning is the engineer's
        prerequisite, and confirming it costs a full storage enumeration per host - the
        slowest thing this script used to do, on every run, whether anyone doubted the
        presentation or not.

    .PARAMETER DestinationHosts
        The eligible destination host records.

    .PARAMETER Svm
        SVM presenting the LUNs.

    .PARAMETER Disks
        The resolved destination disks, carrying the LUN IDs and the device identities
        taken from the source RDMs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$DestinationHosts,

        [Parameter(Mandatory)]
        [string]$Svm,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Disks
    )

    foreach ($record in $DestinationHosts) {
        $hostName = $record.VMHost.Name
        Write-RichoLog "    $hostName : reading storage paths and devices..." -Level INFO
        $hostStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $storageMap = Get-HostStorageMap -VMHost $record.VMHost

        foreach ($disk in $Disks) {
            $resolved = Resolve-DestinationLun -StorageMap $storageMap -Svm $Svm -LunId $disk.LunId
            if ($resolved.CanonicalName -ne $disk.CanonicalName) {
                throw "On '$hostName', SVM '$Svm' LUN $($disk.LunId) is device '$($resolved.CanonicalName)', but the RDM being moved is '$($disk.CanonicalName)'."
            }
            if ([math]::Abs($resolved.CapacityGB - $disk.CapacityGB) -gt $script:CapacityToleranceGB) {
                throw "On '$hostName', LUN $($disk.LunId) is $($resolved.CapacityGB) GB but the RDM being moved is $($disk.CapacityGB) GB."
            }
        }

        $hostStopwatch.Stop()
        Write-RichoLog "      all $($Disks.Count) LUN(s) present and matching ($(Format-Elapsed -Elapsed $hostStopwatch.Elapsed))." -Level INFO
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
        presented is printed instead, and -VerifyLunPresentation reads it back on request.

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

function Get-PciControllerKey {
    <#
    .SYNOPSIS
        Returns the key of a VM's PCI controller, the parent of its SCSI controllers.

    .DESCRIPTION
        It is 100 on every VM anyone has seen, but a new SCSI controller has to name a
        real parent key and reading it costs nothing next to guessing it.

    .PARAMETER DeviceList
        The VM's Config.Hardware.Device list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$DeviceList
    )

    $pci = @($DeviceList | Where-Object { $_ -is [VMware.Vim.VirtualPCIController] })
    if ($pci.Count -ne 1) {
        throw "Expected exactly one PCI controller on the VM; found $($pci.Count)."
    }

    return [int]$pci[0].Key
}

function New-SharedScsiController {
    <#
    .SYNOPSIS
        Adds a SCSI controller of the source's own type and bus-sharing mode.

    .DESCRIPTION
        The controller type is not a free choice. A WSFC node built on LSI Logic SAS that
        comes back as PVSCSI needs a driver it may not have, and the guest sees its shared
        disks arrive on different hardware - which is exactly the condition SQL FCI is
        least able to absorb. The type therefore comes from the source device.

        UnitNumber is deliberately left unset so vCenter chooses the PCI slot. Setting it
        to the SCSI bus number, as this script used to, puts the controller in whichever
        slot happens to share that number and collides with whatever already holds it.

    .PARAMETER VM
        The VM to add the controller to.

    .PARAMETER BusNumber
        SCSI bus number for the new controller.

    .PARAMETER ControllerTypeName
        Full VMware.Vim type name of the source controller.

    .PARAMETER SharedBus
        Bus-sharing mode taken from the source controller, normally physicalSharing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VM,

        [Parameter(Mandatory)]
        [int]$BusNumber,

        [Parameter(Mandatory)]
        [string]$ControllerTypeName,

        [Parameter(Mandatory)]
        [string]$SharedBus
    )

    if ($ControllerTypeName -notlike 'VMware.Vim.*') {
        throw "Refusing to create a controller of type '$ControllerTypeName'."
    }

    $vmView = Get-View -Id $VM.Id -Property Config.Hardware.Device
    $devices = @($vmView.Config.Hardware.Device)

    $existing = @(
        $devices |
            Where-Object { ($_ -is [VMware.Vim.VirtualSCSIController]) -and ([int]$_.BusNumber -eq $BusNumber) }
    )
    if ($existing.Count -gt 0) {
        throw "VM '$($VM.Name)' already has a SCSI controller on bus $BusNumber."
    }

    $controller = New-Object -TypeName $ControllerTypeName
    if ($controller -isnot [VMware.Vim.VirtualSCSIController]) {
        throw "Type '$ControllerTypeName' is not a SCSI controller."
    }

    $controller.Key = -1000 - $BusNumber
    $controller.BusNumber = $BusNumber
    $controller.SharedBus = $SharedBus
    $controller.ControllerKey = Get-PciControllerKey -DeviceList $devices

    $change = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $change.Operation = 'add'
    $change.Device = $controller

    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.DeviceChange = @($change)

    Wait-VMReconfigureTask -TaskReference $vmView.ReconfigVM_Task($spec) -Description "Adding SCSI controller $BusNumber to '$($VM.Name)'"
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

function Add-RdmDevice {
    <#
    .SYNOPSIS
        Attaches one physical-mode RDM at an exact SCSI address.

    .DESCRIPTION
        The device is built as a VirtualDeviceConfigSpec rather than handed to
        New-HardDisk because New-HardDisk takes the next free unit on the controller and
        offers no way to ask for a specific one. The old code compensated by editing the
        unit number afterwards, which vSphere does not support for an attached disk: it
        either fails the reconfigure or leaves the disk where it was. For a SQL FCI the
        SCSI address is what the guest matches its shared disks on, so it has to be right
        the first time.

        When ExistingMappingFile is supplied the mapping file created for the first node
        is attached rather than a new one created - VMware's documented arrangement for a
        cluster across boxes.

    .PARAMETER VM
        The VM to attach to.

    .PARAMETER ControllerBus
        SCSI bus of the target controller.

    .PARAMETER UnitNumber
        SCSI unit the disk must occupy.

    .PARAMETER ConsoleDeviceName
        The /vmfs/devices/disks/... path of the destination LUN.

    .PARAMETER RdmDatastoreName
        Datastore the new mapping file is created on. Ignored when attaching an existing
        mapping file.

    .PARAMETER ExistingMappingFile
        Datastore path of a mapping file to attach instead of creating one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $VM,

        [Parameter(Mandatory)]
        [int]$ControllerBus,

        [Parameter(Mandatory)]
        [int]$UnitNumber,

        [Parameter(Mandatory)]
        [string]$ConsoleDeviceName,

        [Parameter(Mandatory)]
        [string]$RdmDatastoreName,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ExistingMappingFile
    )

    $vmView = Get-View -Id $VM.Id -Property Config.Hardware.Device
    $controllers = @(
        $vmView.Config.Hardware.Device |
            Where-Object { ($_ -is [VMware.Vim.VirtualSCSIController]) -and ([int]$_.BusNumber -eq $ControllerBus) }
    )
    if ($controllers.Count -ne 1) {
        throw "VM '$($VM.Name)' has $($controllers.Count) SCSI controllers on bus $ControllerBus; expected one."
    }
    $controllerKey = [int]$controllers[0].Key

    $occupied = @(
        $vmView.Config.Hardware.Device |
            Where-Object {
                ($_ -is [VMware.Vim.VirtualDisk]) -and
                ([int]$_.ControllerKey -eq $controllerKey) -and
                ([int]$_.UnitNumber -eq $UnitNumber)
            }
    )
    if ($occupied.Count -gt 0) {
        throw "SCSI $ControllerBus`:$UnitNumber on '$($VM.Name)' is already occupied."
    }

    $backing = New-Object VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo
    $backing.CompatibilityMode = 'physicalMode'
    $backing.DeviceName = $ConsoleDeviceName

    # SHIPPED AND HIT ON A LIVE RUN: with diskMode left unset, vCenter rejected the add
    # with "Incompatible device backing specified for device '0'". A physical-mode RDM is
    # independent-persistent by nature and that is what the client itself sends; saying so
    # explicitly is what the server will accept.
    $backing.DiskMode = 'independent_persistent'

    $disk = New-Object VMware.Vim.VirtualDisk
    $disk.Key = -100 - $UnitNumber
    $disk.ControllerKey = $controllerKey
    $disk.UnitNumber = $UnitNumber
    $disk.Backing = $backing

    $change = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $change.Operation = 'add'
    if ([string]::IsNullOrWhiteSpace($ExistingMappingFile)) {
        # An empty datastore path asks vCenter to name the mapping file itself, in the
        # VM's folder on that datastore.
        $backing.FileName = "[$RdmDatastoreName]"
        $change.FileOperation = 'create'
    }
    else {
        $backing.FileName = $ExistingMappingFile
    }
    $change.Device = $disk

    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.DeviceChange = @($change)

    # The whole backing, in the log, before it is sent: when vCenter refuses a device the
    # message names neither the device nor the file, and this is the difference between a
    # five-minute diagnosis and an afternoon.
    Write-RichoLog "        device: $($backing.DeviceName), mode: $($backing.CompatibilityMode)/$($backing.DiskMode), file: '$($backing.FileName)', fileOperation: '$($change.FileOperation)'" -Level INFO

    $attachDescription = "Attaching RDM at SCSI $ControllerBus`:$UnitNumber on '$($VM.Name)' (device $($backing.DeviceName), file '$($backing.FileName)')"
    Wait-VMReconfigureTask -TaskReference $vmView.ReconfigVM_Task($spec) -Description $attachDescription

    $afterView = Get-View -Id $VM.Id -Property Config.Hardware.Device
    $attached = @(
        $afterView.Config.Hardware.Device |
            Where-Object {
                ($_ -is [VMware.Vim.VirtualDisk]) -and
                ([int]$_.ControllerKey -eq $controllerKey) -and
                ([int]$_.UnitNumber -eq $UnitNumber)
            }
    )
    if ($attached.Count -ne 1) {
        throw "Expected one disk at SCSI $ControllerBus`:$UnitNumber on '$($VM.Name)' after the attach; found $($attached.Count)."
    }

    $attachedCanonical = ([string]$attached[0].Backing.DeviceName -replace '^.*/', '').ToLowerInvariant()
    $expectedCanonical = ($ConsoleDeviceName -replace '^.*/', '').ToLowerInvariant()
    if ($attachedCanonical -ne $expectedCanonical) {
        throw "SCSI $ControllerBus`:$UnitNumber on '$($VM.Name)' resolved to device '$attachedCanonical', expected '$expectedCanonical'."
    }

    return [string]$attached[0].Backing.FileName
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

function Add-DestinationRdms {
    <#
    .SYNOPSIS
        Recreates a VM's shared-bus controllers and re-attaches its RDMs at the
        destination.

    .PARAMETER VMItem
        The planned VM record.

    .PARAMETER GroupPlan
        The migration group plan, whose MappingFiles table carries the mapping files
        created for the first VM when the group shares them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VMItem,

        [Parameter(Mandatory)]
        $GroupPlan
    )

    $vmName = $VMItem.VM.Name

    foreach ($bus in @($GroupPlan.Disks | ForEach-Object { $_.ControllerBus } | Select-Object -Unique | Sort-Object)) {
        $controllerMatches = @($GroupPlan.Controllers | Where-Object { $_.ControllerBus -eq $bus })
        if ($controllerMatches.Count -ne 1) {
            throw "No source controller was recorded for SCSI bus $bus in group '$($GroupPlan.Name)'."
        }
        $controllerType = $controllerMatches[0]
        $addControllerDetail = "Create $($controllerType.ShortType) controller on bus $bus with $($controllerType.SharedBus)."
        Invoke-PlannedChange $GroupPlan.Name $vmName 'AddController' "SCSI $bus" $addControllerDetail {
            $newControllerParameters = @{
                VM                 = Get-VM -Id $VMItem.VM.Id
                BusNumber          = $bus
                ControllerTypeName = $controllerType.ControllerType
                SharedBus          = $controllerType.SharedBus
            }
            New-SharedScsiController @newControllerParameters
        }
    }

    foreach ($disk in @($GroupPlan.Disks | Sort-Object ControllerBus, UnitNumber)) {
        $addressKey = "$($disk.ControllerBus):$($disk.UnitNumber)"
        $existingMappingFile = ''
        if (($GroupPlan.MappingMode -eq 'Shared') -and $GroupPlan.MappingFiles.ContainsKey($addressKey)) {
            $existingMappingFile = [string]$GroupPlan.MappingFiles[$addressKey]
        }

        $mappingDetail = if ($GroupPlan.MappingMode -eq 'Shared' -and $VMItem.PowerOnOrder -gt 1) {
            "attaching the mapping file created for '$($GroupPlan.VMItems[0].VM.Name)'"
        }
        else {
            "creating a mapping file on '$($GroupPlan.RdmDatastore.Name)'"
        }
        $addRdmDetail = "Attach SVM '$($GroupPlan.Svm)' LUN $($disk.LunId) ($($disk.CapacityGB) GB) at SCSI $addressKey, $mappingDetail."

        Invoke-PlannedChange $GroupPlan.Name $vmName 'AddRdm' "LUN $($disk.LunId)" $addRdmDetail {
            $addParameters = @{
                VM                  = Get-VM -Id $VMItem.VM.Id
                ControllerBus       = $disk.ControllerBus
                UnitNumber          = $disk.UnitNumber
                ConsoleDeviceName   = $disk.ConsoleDeviceName
                RdmDatastoreName    = $GroupPlan.RdmDatastore.Name
                ExistingMappingFile = $existingMappingFile
            }
            $mappingFile = Add-RdmDevice @addParameters
            if (-not $GroupPlan.MappingFiles.ContainsKey($addressKey)) {
                $GroupPlan.MappingFiles[$addressKey] = $mappingFile
            }
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
            foreach ($rdm in $layout.Rdms) {
                if ($rdm.BusSharing -ne 'physicalSharing') {
                    throw "VM '$vmName' RDM '$($rdm.Label)' is on a controller with bus sharing '$($rdm.BusSharing)', not physicalSharing."
                }
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
                    ([math]::Abs($current.CapacityGB - $reference.CapacityGB) -gt $script:CapacityToleranceGB)) {
                    throw "VM '$($vmItem.VM.Name)' RDM topology differs from '$($referenceItem.VM.Name)' at index $index."
                }
            }
        }

        # VMware's documented cluster-across-boxes build gives the group one mapping file
        # per LUN, created for the first node and attached by the rest. Some estates have
        # one per VM instead. Whichever this group uses is reproduced, not assumed.
        $mappingMode = 'PerVm'
        if ($vmItems.Count -gt 1) {
            $sharedCount = 0
            for ($index = 0; $index -lt $referenceRdms.Count; $index++) {
                $files = @(
                    $vmItems |
                        ForEach-Object { @($_.Layout.Rdms | Sort-Object ControllerBus, UnitNumber)[$index].BackingFile } |
                        Select-Object -Unique
                )
                if ($files.Count -eq 1) { $sharedCount++ }
            }
            if ($sharedCount -eq $referenceRdms.Count) {
                $mappingMode = 'Shared'
            }
            elseif ($sharedCount -ne 0) {
                throw "Migration group '$groupName' mixes shared and per-VM RDM mapping files; resolve that by hand before migrating."
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

        $resolvedDisks = [System.Collections.Generic.List[object]]::new()
        $diskIndex = 0
        foreach ($diskGroup in $diskGroups) {
            for ($position = 0; $position -lt $diskGroup.LunIds.Count; $position++) {
                $lunId = $diskGroup.LunIds[$position]
                $unitNumber = $diskGroup.UnitNumbers[$position]
                $reference = $referenceRdms[$diskIndex]

                if (($reference.ControllerBus -ne $diskGroup.ControllerBus) -or ($reference.UnitNumber -ne $unitNumber)) {
                    throw "Source topology differs from CSV order at LUN $lunId : the CSV places it at SCSI $($diskGroup.ControllerBus):$unitNumber, the source has SCSI $($reference.ControllerBus):$($reference.UnitNumber)."
                }

                # The device is the one the VM already has. These are the same LUNs,
                # re-presented to the destination cluster, so the mapping the source RDM
                # carries is the mapping to put back - which is why nothing here has to
                # scan a host to find it, and why the operator never types an NAA.
                if ([string]::IsNullOrWhiteSpace($reference.DeviceName)) {
                    throw "The RDM at SCSI $($diskGroup.ControllerBus):$unitNumber on '$($referenceItem.VM.Name)' has no device path to re-attach."
                }

                $resolvedDisks.Add([pscustomobject]@{
                    LunId             = $lunId
                    CanonicalName     = $reference.CanonicalName
                    ConsoleDeviceName = $reference.DeviceName
                    CapacityGB        = $reference.CapacityGB
                    ControllerBus     = $diskGroup.ControllerBus
                    UnitNumber        = $unitNumber
                    SourceLabel       = $reference.Label
                })
                $diskIndex++
            }
        }

        Write-RichoLog "  Plan resolved: $($resolvedDisks.Count) LUN(s) across $($controllers.Count) controller(s), $mappingMode mapping files." -Level INFO

        # Presentation is the engineer's prerequisite, so it is stated rather than
        # checked: these devices, on these hosts, before this group runs.
        $destinationHostNames = @($eligibleHosts | ForEach-Object { $_.VMHost.Name })
        $prerequisite = [System.Collections.Generic.List[string]]::new()
        $prerequisite.Add("Present these LUNs from SVM '$svm' to $($destinationHostNames -join ', ') and rescan the HBAs before running group '$groupName':")
        foreach ($disk in $resolvedDisks) {
            $prerequisite.Add("  LUN $($disk.LunId)  $($disk.CanonicalName)  $($disk.CapacityGB) GB  -> SCSI $($disk.ControllerBus):$($disk.UnitNumber)")
        }

        Write-RichoLog '  ---- PREREQUISITE, not checked by this script ----' -Level INFO
        foreach ($line in $prerequisite) { Write-RichoLog "  $line" -Level INFO }

        if ($VerifyLunPresentation) {
            Write-RichoLog '  -VerifyLunPresentation was supplied; reading the destination hosts back.' -Level INFO
            Confirm-LunPresentation -DestinationHosts $eligibleHosts -Svm $svm -Disks $resolvedDisks.ToArray()
        }
        elseif ($SkipDeviceCheck) {
            Write-RichoLog '  -SkipDeviceCheck was supplied; the devices are not checked at all before the VMs come down.' -Level WARN
        }
        else {
            # Only the hosts these VMs are actually going to, and only "is the device
            # there" - a second or two, against a failure that lands mid-migration.
            $placementHosts = @($vmItems | ForEach-Object { $_.DestinationHost } | Sort-Object -Property Name -Unique)
            Write-RichoLog "  Confirming the $($resolvedDisks.Count) device(s) are visible on $($placementHosts.Count) destination host(s)." -Level INFO
            Assert-DeviceVisible -DestinationHosts $placementHosts -Disks $resolvedDisks.ToArray()
        }
        Write-RichoLog '  -------------------------------------------------' -Level INFO

        $duplicateDevices = @(
            $resolvedDisks |
                Group-Object CanonicalName |
                Where-Object { $_.Count -gt 1 } |
                ForEach-Object { $_.Name }
        )
        if ($duplicateDevices.Count -gt 0) {
            throw "Two or more CSV LUN IDs resolve to the same device in '$groupName': $($duplicateDevices -join ', ')."
        }

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
            Disks               = $resolvedDisks.ToArray()
            Controllers         = $controllers.ToArray()
            MappingMode         = $mappingMode
            MappingFiles        = @{}
            Prerequisite        = $prerequisite.ToArray()
            LunPresentationVerified = [bool]$VerifyLunPresentation
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
        RdmMappingMode              = $GroupPlan.MappingMode
        PresentationPrerequisite    = $GroupPlan.Prerequisite
        LunPresentationVerified     = $GroupPlan.LunPresentationVerified
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
        Re-reads each VM after the migration and compares it to the plan.

    .DESCRIPTION
        Evidence, not decoration. Every disk is checked back against the address, device
        and capacity it was supposed to land on, so the change record shows the state that
        was actually reached rather than the state that was intended.

    .PARAMETER GroupPlan
        The resolved group plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $GroupPlan
    )

    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($vmItem in $GroupPlan.VMItems) {
        $currentVM = Get-VM -Id $vmItem.VM.Id
        $layout = Get-VMRdmLayout -VM $currentVM

        # Read the pool rather than a property of the VM object: which of ResourcePool and
        # ResourcePoolId a VirtualMachine carries has changed between PowerCLI releases,
        # and under StrictMode reading the wrong one is a terminating error.
        $pools = @(Get-ResourcePool -VM $currentVM -ErrorAction SilentlyContinue)
        $poolName = if ($pools.Count -gt 0) { [string]$pools[0].Name } else { '' }

        foreach ($disk in $GroupPlan.Disks) {
            $actual = @(
                $layout.Rdms |
                    Where-Object { ($_.ControllerBus -eq $disk.ControllerBus) -and ($_.UnitNumber -eq $disk.UnitNumber) }
            )

            $status = 'Failed'
            $detail = ''
            if ($actual.Count -ne 1) {
                $detail = "Expected one RDM at SCSI $($disk.ControllerBus):$($disk.UnitNumber); found $($actual.Count)."
            }
            elseif ($actual[0].CanonicalName -ne $disk.CanonicalName) {
                $detail = "Device is '$($actual[0].CanonicalName)', expected '$($disk.CanonicalName)'."
            }
            elseif ([math]::Abs($actual[0].CapacityGB - $disk.CapacityGB) -gt $script:CapacityToleranceGB) {
                $detail = "Capacity is $($actual[0].CapacityGB) GB, expected $($disk.CapacityGB) GB."
            }
            elseif ($actual[0].BusSharing -ne 'physicalSharing') {
                $detail = "Bus sharing is '$($actual[0].BusSharing)', expected physicalSharing."
            }
            else {
                $status = 'Passed'
                $detail = "SCSI $($disk.ControllerBus):$($disk.UnitNumber) carries LUN $($disk.LunId) at $($actual[0].CapacityGB) GB."
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
                ScsiAddress    = "$($disk.ControllerBus):$($disk.UnitNumber)"
                LunId          = $disk.LunId
                Status         = $status
                Detail         = $detail
            })
        }
    }

    return $records.ToArray()
}

function Invoke-WorkloadPowerOn {
    <#
    .SYNOPSIS
        Powers the migrated VMs on, a workload type at a time.

    .DESCRIPTION
        Nothing is powered on until every LUN in every group of that workload type is
        mapped back at the destination and verified. A SQL FCI node that boots while a
        sibling group is still mid-migration can bring shared disks online against a
        half-assembled cluster, so the wait is the point.

        Within a workload type the groups run in CSV order and the VMs in each group in
        power-on order - first_vm, then the rest as listed. A group that fails throws and
        the run stops before this is reached, so nothing here powers on after a failure.

    .PARAMETER Plans
        Every resolved migration group in the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Plans
    )

    $workloadTypes = @($Plans | ForEach-Object { $_.WorkloadType } | Select-Object -Unique)

    foreach ($workloadType in $workloadTypes) {
        $groups = @($Plans | Where-Object { $_.WorkloadType -eq $workloadType })
        $vmCount = @($groups | ForEach-Object { $_.VMItems } | Measure-Object).Count
        Write-RichoLog "===== Powering on $workloadType workloads: $vmCount VM(s) across $($groups.Count) group(s) =====" -Level INFO

        foreach ($groupPlan in $groups) {
            foreach ($vmItem in @($groupPlan.VMItems | Sort-Object PowerOnOrder)) {
                $powerOnDetail = "Power on $workloadType VM '$($vmItem.VM.Name)' in sequence position $($vmItem.PowerOnOrder) of group '$($groupPlan.Name)'."
                Invoke-PlannedChange $groupPlan.Name $vmItem.VM.Name 'PowerOn' $vmItem.VM.Name $powerOnDetail {
                    Start-VM -VM (Get-VM -Id $vmItem.VM.Id) -Confirm:$false | Out-Null
                }
            }
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
        Write-RichoLog "$($groupPlan.VMItems.Count) VM(s), $($groupPlan.Disks.Count) RDM(s), $($groupPlan.MappingMode) mapping files, $($groupPlan.SourceClusterLabel) -> $($groupPlan.Cluster.Name)/$($groupPlan.ResourcePool.Name), RDM pointers on $($groupPlan.RdmDatastore.Name)." -Level INFO

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
        Write-RichoLog "  Phase 1 of 3: powering down $($groupPlan.VMItems.Count) VM(s) and detaching their RDMs." -Level INFO
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

        Write-RichoLog "  Phase 2 of 3: relocating and re-attaching. A cold move of a large VM takes minutes." -Level INFO
        $vmIndex = 0
        foreach ($vmItem in $groupPlan.VMItems) {
            $vmIndex++
            Write-RichoLog "    [$vmIndex/$($groupPlan.VMItems.Count)] $($vmItem.VM.Name) -> $($vmItem.DestinationHost.Name)" -Level INFO
            Write-Progress -Activity "Group $($groupPlan.Name): relocate and re-attach" -Status $vmItem.VM.Name -PercentComplete ([int](($vmIndex / [math]::Max(1, $groupPlan.VMItems.Count)) * 100))
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

            Add-DestinationRdms -VMItem $vmItem -GroupPlan $groupPlan
        }
        Write-Progress -Activity "Group $($groupPlan.Name): relocate and re-attach" -Completed

        Write-RichoLog "  Phase 3 of 3: verifying." -Level INFO
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

        $groupStatus = if ($DryRun) { 'DryRunPassed' } else { 'Succeeded' }
        Add-Result $groupPlan.Name '' 'Group' $groupStatus 'Migration group processing completed.'
        Write-RichoLog "Migration group $($groupPlan.Name): $groupStatus." -Level INFO
    }

    $succeeded = @($script:Results | Where-Object { $_.Status -eq 'Succeeded' }).Count
    $planned = @($script:Results | Where-Object { $_.Status -eq 'DryRun' }).Count
    Write-RichoLog "All $($plans.Count) group(s) processed in $(Format-Elapsed -Elapsed $script:RunStopwatch.Elapsed): $succeeded change(s) made, $planned planned." -Level INFO

    # Every group is migrated and verified before anything boots, then the VMs come up a
    # workload type at a time.
    if ($PowerOnAfterMigration) {
        Invoke-WorkloadPowerOn -Plans $plans
    }
    else {
        Write-RichoLog 'PowerOnAfterMigration was not requested; the VMs have been left powered off.' -Level INFO
    }
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
