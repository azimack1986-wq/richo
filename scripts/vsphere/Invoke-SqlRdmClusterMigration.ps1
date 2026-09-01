<#
.SYNOPSIS
    Plans or performs a cold migration of clustered SQL VMs that use physical-mode RDMs.

.DESCRIPTION
    Consumes the grouped-LUN CSV format. Destination devices are selected using SVM plus
    LUN ID and are then verified internally by canonical device identity and capacity, so
    the operator never types an NAA value.

    Source and destination clusters are separate: 'vsphere_cluster' is where the VMs are
    now, 'destination_cluster' is where they are going, and each VM must actually be in
    the source cluster or the run stops.

    Per migration group the script:

      1. Resolves the source cluster, then the destination cluster, resource pool,
         datastore cluster and RDM pointer datastore, and the eligible destination hosts
         that can see all of them plus every LUN in the CSV.
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
    FQDN of the vCenter Server that holds both the source VMs and the destination cluster.

.PARAMETER CsvPath
    Path to the migration CSV. See docs/sql-rdm-cluster-migration.md for the columns.

.PARAMETER DryRun
    Discovery, validation and evidence only. No VMware object is modified.

.PARAMETER Execute
    Perform the migration.

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

    Migrates the groups in the CSV and powers the VMs on at the destination in CSV order.
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
    [ValidateNotNullOrEmpty()]
    [string]$OutputFolder = (Join-Path (Get-Location) 'SqlRdmClusterMigrationOutput'),

    [Parameter()]
    [switch]$IgnoreInvalidCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '2.4.0'
$connection = $null

# There are exactly two modes and one gate between them: -DryRun records what would
# happen, -Execute does it. Nothing else in the script decides whether to change a VM.
$script:RunMode = if ($DryRun) { 'DryRun' } else { 'Execute' }

# Workload type is per migration group, and stamping it on every plan, result and
# verification row is what lets a change record be filtered to PROD alone. Held here so
# the row builders can reach it without every call site passing it along.
$script:WorkloadTypeByGroup = @{}
$script:ValidWorkloadTypes = @('PROD', 'SIT', 'DEV')

$script:Plan = [System.Collections.Generic.List[object]]::new()
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:Verification = [System.Collections.Generic.List[object]]::new()

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

    if ($MigrationGroup -and $script:WorkloadTypeByGroup.ContainsKey($MigrationGroup)) {
        return [string]$script:WorkloadTypeByGroup[$MigrationGroup]
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

function Get-DefaultRdmDatastoreName {
    <#
    .SYNOPSIS
        Builds the conventional RDM pointer datastore name for a cluster.

    .DESCRIPTION
        The estate names the RDM pointer datastore after the cluster that mounts it, with
        an '_i_rdm' suffix - d85sql01 has d85sql01_i_rdm, d85sql01sit has
        d85sql01sit_i_rdm, d85sql01dev has d85sql01dev_i_rdm. The environment is already
        in the cluster name, so there is no environment logic here and none is wanted.

        It is only ever a default. A CSV that names the datastore is obeyed as written.

    .PARAMETER ClusterName
        The cluster the datastore belongs to.

    .EXAMPLE
        Get-DefaultRdmDatastoreName -ClusterName 'd85sql01sit'   # d85sql01sit_i_rdm
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterName
    )

    return "${ClusterName}_i_rdm"
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
        'vsphere_cluster',
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
            'vsphere_cluster',
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

        $workloadType = ([string]$row.workload_type).ToUpperInvariant()
        if ($workloadType -notin $script:ValidWorkloadTypes) {
            throw "CSV line $lineNumber has workload_type '$($row.workload_type)'; expected one of $($script:ValidWorkloadTypes -join ', ')."
        }
        $row.workload_type = $workloadType

        if (([string]$row.vsphere_cluster) -ieq ([string]$row.destination_cluster)) {
            throw "CSV line $lineNumber has the same source and destination cluster '$($row.vsphere_cluster)'."
        }

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

    if (@($rows | Group-Object vsphere_cluster | Where-Object { $_.Count -gt 1 }).Count -gt 0) {
        throw 'CSV contains duplicate vsphere_cluster rows.'
    }

    return $rows
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

function Get-EligibleDestinationHosts {
    <#
    .SYNOPSIS
        Returns the destination hosts that can run the migrated VMs.

    .DESCRIPTION
        A host qualifies only if it is connected, out of maintenance mode, mounts the
        destination datastore cluster and the RDM pointer datastore, and resolves every
        LUN in the group. Hosts that fail are reported with the reason - "no eligible
        host" on its own tells the operator nothing about which prerequisite is missing.

    .PARAMETER Cluster
        The destination cluster.

    .PARAMETER DatastoreCluster
        Destination datastore cluster for the VM home files.

    .PARAMETER RdmDatastore
        Datastore that holds the RDM mapping files.

    .PARAMETER Svm
        SVM presenting the LUNs.

    .PARAMETER LunIds
        Every LUN ID in the migration group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Cluster,

        [Parameter(Mandatory)]
        $DatastoreCluster,

        [Parameter(Mandatory)]
        $RdmDatastore,

        [Parameter(Mandatory)]
        [string]$Svm,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [int[]]$LunIds
    )

    $datastoreClusterIds = @(Get-Datastore -Location $DatastoreCluster | ForEach-Object { [string]$_.Id })
    $eligible = [System.Collections.Generic.List[object]]::new()
    $exclusions = [System.Collections.Generic.List[string]]::new()

    foreach ($candidateHost in @(Get-VMHost -Location $Cluster)) {
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

        $hostDatastoreIds = @(Get-Datastore -VMHost $candidateHost | ForEach-Object { [string]$_.Id })
        if (@($datastoreClusterIds | Where-Object { $_ -in $hostDatastoreIds }).Count -eq 0) {
            $exclusions.Add("$($candidateHost.Name): mounts no datastore from '$($DatastoreCluster.Name)'")
            continue
        }
        if ($RdmDatastore.Id -notin $hostDatastoreIds) {
            $exclusions.Add("$($candidateHost.Name): does not mount RDM datastore '$($RdmDatastore.Name)'")
            continue
        }

        try {
            $storageMap = Get-HostStorageMap -VMHost $candidateHost
            $resolvedLuns = [System.Collections.Generic.List[object]]::new()
            foreach ($lunId in $LunIds) {
                $resolvedLuns.Add((Resolve-DestinationLun -StorageMap $storageMap -Svm $Svm -LunId $lunId))
            }
            $eligible.Add([pscustomobject]@{
                VMHost = $candidateHost
                Luns   = $resolvedLuns.ToArray()
            })
        }
        catch {
            $exclusions.Add("$($candidateHost.Name): $($_.Exception.Message)")
            Write-RichoLog "  Host excluded: $($candidateHost.Name) - $($_.Exception.Message)" -Level WARN
        }
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

    $task = Get-Task -Id "Task-$($TaskReference.Value)"
    $completed = Wait-Task -Task $task
    if ($completed.State -ne 'Success') {
        throw "$Description failed: task state is $($completed.State)."
    }
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
    # DiskMode is deliberately left unset: it does not apply to a physical-mode RDM, and
    # sending an empty one is rejected as an invalid device configuration.

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

    Wait-VMReconfigureTask -TaskReference $vmView.ReconfigVM_Task($spec) -Description "Attaching RDM at SCSI $ControllerBus`:$UnitNumber on '$($VM.Name)'"

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

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $currentVM = Get-VM -Id $VM.Id
    while (($currentVM.PowerState -ne 'PoweredOff') -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Seconds 5
        $currentVM = Get-VM -Id $VM.Id
    }

    if ($currentVM.PowerState -ne 'PoweredOff') {
        throw "VM '$($VM.Name)' did not power off within $TimeoutMinutes minutes."
    }
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $VMItem,

        [Parameter(Mandatory)]
        [string]$MigrationGroup
    )

    $currentVM = Get-VM -Id $VMItem.VM.Id
    foreach ($rdm in @($VMItem.Layout.Rdms | Sort-Object ControllerBus, UnitNumber)) {
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

    foreach ($bus in @($VMItem.Layout.Rdms | ForEach-Object { $_.ControllerBus } | Select-Object -Unique | Sort-Object)) {
        # Bus 0 carries the boot disk on every VM this tool is meant for. If an RDM was
        # found there the source topology is not what the CSV describes, and removing that
        # controller would take the operating system with it.
        if ($bus -eq 0) {
            throw "VM '$($currentVM.Name)' has a physical RDM on SCSI bus 0; this tool will not remove the bus 0 controller."
        }

        $controller = Get-ScsiController -VM $currentVM |
            Where-Object { $_.ExtensionData.BusNumber -eq $bus } |
            Select-Object -First 1
        if ($null -eq $controller) {
            throw "SCSI controller bus $bus is no longer attached to '$($currentVM.Name)'."
        }

        $attachedDisks = @(
            Get-HardDisk -VM $currentVM |
                Where-Object { $_.ExtensionData.ControllerKey -eq $controller.ExtensionData.Key }
        )
        if ($DryRun) {
            $plannedLabels = @(
                $VMItem.Layout.Rdms |
                    Where-Object { $_.ControllerBus -eq $bus } |
                    ForEach-Object { $_.Label }
            )
            $unexpected = @($attachedDisks | Where-Object { $_.Name -notin $plannedLabels })
            if ($unexpected.Count -gt 0) {
                throw "Controller bus $bus contains unplanned disks: $($unexpected.Name -join ', ')."
            }
        }
        elseif ($attachedDisks.Count -gt 0) {
            throw "Controller bus $bus is not empty after RDM removal."
        }

        $removeControllerDetail = "Remove empty shared-bus SCSI controller on bus $bus."
        Invoke-PlannedChange $MigrationGroup $currentVM.Name 'RemoveController' "SCSI $bus" $removeControllerDetail {
            Remove-ScsiController -ScsiController $controller -Confirm:$false | Out-Null
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
        $groupName = [string]$row.vsphere_cluster
        $sourceClusterName = [string]$row.vsphere_cluster
        $destinationClusterName = [string]$row.destination_cluster
        $workloadType = [string]$row.workload_type
        $resourcePoolName = [string]$row.destination_resource_pool
        $datastoreClusterName = [string]$row.destination_datastore_cluster
        $svm = [string]$row.svm

        $script:WorkloadTypeByGroup[$groupName] = $workloadType
        Write-RichoLog "Resolving $workloadType migration group '$groupName' -> '$destinationClusterName'." -Level INFO

        $sourceCluster = Get-ExactObject -Name $sourceClusterName -ObjectType 'source cluster' -Lookup {
            Get-Cluster -Name $sourceClusterName -ErrorAction SilentlyContinue
        }
        $cluster = Get-ExactObject -Name $destinationClusterName -ObjectType 'destination cluster' -Lookup {
            Get-Cluster -Name $destinationClusterName -ErrorAction SilentlyContinue
        }
        if ($sourceCluster.Id -eq $cluster.Id) {
            throw "Source and destination cluster both resolve to '$($cluster.Name)'; there is nothing to migrate."
        }

        # The environment lives in the cluster name - d85sql01, d85sql01sit, d85sql01dev -
        # so the CSV's workload type and the destination it names should agree. A row that
        # sends PROD VMs at a dev cluster is a copy-paste away, and is worth saying out
        # loud rather than stopping a run that may well be deliberate.
        $destinationSuffix = ''
        if ($destinationClusterName -imatch '(sit|dev)$') { $destinationSuffix = $Matches[1].ToUpperInvariant() }
        $expectedSuffix = if ($workloadType -eq 'PROD') { '' } else { $workloadType }
        if ($destinationSuffix -ne $expectedSuffix) {
            $namingWarning = "Migration group '$groupName' is marked $workloadType but its destination cluster '$destinationClusterName' does not follow that naming. Check the row."
            Write-RichoLog $namingWarning -Level WARN
            Add-Result $groupName '' 'Preflight' 'Warning' $namingWarning
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
            $rdmDatastoreName = Get-DefaultRdmDatastoreName -ClusterName $destinationClusterName
            Write-RichoLog "No RDM pointer datastore in the CSV for '$groupName'; using the conventional name '$rdmDatastoreName'." -Level INFO
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
            Svm              = $svm
            LunIds           = [int[]]$allLunIds.ToArray()
        }
        $eligibility = Get-EligibleDestinationHosts @eligibleHostParameters
        $eligibleHosts = $eligibility.Hosts
        if ($eligibleHosts.Count -eq 0) {
            $reasons = if ($eligibility.Exclusions.Count -gt 0) { " Hosts were excluded because - $($eligibility.Exclusions -join '; ')" } else { '' }
            throw "No eligible destination host in '$groupName' can access all required datastores and LUNs.$reasons"
        }
        if (($eligibleHosts.Count -eq 1) -and ($vmNames.Count -gt 1)) {
            Write-RichoLog "Only one eligible host in '$groupName'; every node of this cluster will land on $($eligibleHosts[0].VMHost.Name). Separate them before the guests are brought back into service." -Level WARN
        }

        foreach ($lunId in $allLunIds) {
            $identities = @(
                $eligibleHosts |
                    ForEach-Object {
                        $_.Luns |
                            Where-Object { $_.LunId -eq $lunId } |
                            ForEach-Object { $_.CanonicalName }
                    } |
                    Select-Object -Unique
            )
            if ($identities.Count -ne 1) {
                throw "LUN $lunId resolves to inconsistent device identities across eligible hosts: $($identities -join ', ')."
            }
        }

        $vmItems = [System.Collections.Generic.List[object]]::new()
        $placementIndex = 0
        foreach ($vmName in $vmNames) {
            # Scoped to the source cluster, so a VM that is not there is not found, and a
            # name that also exists in another cluster cannot be picked up by mistake.
            $vm = Get-ExactObject -Name $vmName -ObjectType "VM in source cluster '$sourceClusterName'" -Lookup {
                Get-VM -Name $vmName -Location $sourceCluster -ErrorAction SilentlyContinue
            }
            $layout = Get-VMRdmLayout -VM $vm
            if ($layout.View.Snapshot) { throw "VM '$vmName' has a snapshot." }
            if ($layout.Rdms.Count -ne $allLunIds.Count) {
                throw "VM '$vmName' has $($layout.Rdms.Count) physical RDMs but the CSV specifies $($allLunIds.Count)."
            }
            foreach ($rdm in $layout.Rdms) {
                if ($rdm.BusSharing -ne 'physicalSharing') {
                    throw "VM '$vmName' RDM '$($rdm.Label)' is on a controller with bus sharing '$($rdm.BusSharing)', not physicalSharing."
                }
            }

            $destinationRecord = $eligibleHosts[$placementIndex % $eligibleHosts.Count]
            $placementIndex++
            $vmItems.Add([pscustomobject]@{
                VM              = $vm
                Layout          = $layout
                DestinationHost = $destinationRecord.VMHost
                PowerOnOrder    = $placementIndex
            })
        }

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

                $destinationCandidates = @($eligibleHosts[0].Luns | Where-Object { $_.LunId -eq $lunId })
                if ($destinationCandidates.Count -ne 1) {
                    throw "LUN $lunId resolved to $($destinationCandidates.Count) devices on '$($eligibleHosts[0].VMHost.Name)'; expected one."
                }
                $destinationLun = $destinationCandidates[0]

                # A mistyped LUN ID that happens to exist on the array is the failure this
                # catches: same SVM, wrong disk, and nothing else in the run would notice
                # until SQL failed to bring the disk online.
                if ([math]::Abs($destinationLun.CapacityGB - $reference.CapacityGB) -gt $script:CapacityToleranceGB) {
                    throw "LUN $lunId is $($destinationLun.CapacityGB) GB but the RDM it replaces at SCSI $($diskGroup.ControllerBus):$unitNumber is $($reference.CapacityGB) GB."
                }

                $resolvedDisks.Add([pscustomobject]@{
                    LunId                = $lunId
                    CanonicalName        = $destinationLun.CanonicalName
                    ConsoleDeviceName    = $destinationLun.ConsoleDeviceName
                    CapacityGB           = $destinationLun.CapacityGB
                    ControllerBus        = $diskGroup.ControllerBus
                    UnitNumber           = $unitNumber
                    SourceCanonicalName  = $reference.CanonicalName
                    SourceCapacityGB     = $reference.CapacityGB
                    SameDeviceAsSource   = ($destinationLun.CanonicalName -eq $reference.CanonicalName)
                    SourceLabel          = $reference.Label
                })
                $diskIndex++
            }
        }

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
            Svm                 = $svm
            SourceCluster       = $sourceCluster
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
        Generated                   = (Get-Date).ToString('o')
        VCenter                     = $VCenter
        MigrationGroup              = $GroupPlan.Name
        WorkloadType                = $GroupPlan.WorkloadType
        Svm                         = $GroupPlan.Svm
        SourceCluster               = $GroupPlan.SourceCluster.Name
        DestinationCluster          = $GroupPlan.Cluster.Name
        DestinationResourcePool     = $GroupPlan.ResourcePool.Name
        DestinationDatastoreCluster = $GroupPlan.DatastoreCluster.Name
        RdmDatastore                = $GroupPlan.RdmDatastore.Name
        RdmDatastoreDerived         = $GroupPlan.RdmDatastoreDerived
        RdmMappingMode              = $GroupPlan.MappingMode
        ExcludedHosts               = $GroupPlan.HostExclusions
        Controllers                 = $GroupPlan.Controllers
        VMs = @($GroupPlan.VMItems | ForEach-Object {
            [ordered]@{
                Name               = $_.VM.Name
                Id                 = $_.VM.Id
                OriginalPowerState = [string]$_.VM.PowerState
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
# on is guaranteed to exist by the time either can run.
Import-RequiredModules

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

    $connection = Connect-VIServer -Server $VCenter -Credential $Credential
    Write-RichoLog "Connected to $($connection.Name) as $($connection.User)." -Level INFO

    $rows = @(Import-MigrationCsv -Path $CsvPath)
    Write-RichoLog "Loaded $($rows.Count) migration group(s) from $CsvPath." -Level INFO

    $plans = @(Resolve-MigrationPlan -Rows $rows)

    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }

    foreach ($groupPlan in $plans) {
        Write-RichoLog "===== Migration group $($groupPlan.Name) [$($groupPlan.WorkloadType)] =====" -Level INFO
        Write-RichoLog "$($groupPlan.VMItems.Count) VM(s), $($groupPlan.Disks.Count) RDM(s), $($groupPlan.MappingMode) mapping files, $($groupPlan.SourceCluster.Name) -> $($groupPlan.Cluster.Name)/$($groupPlan.ResourcePool.Name), RDM pointers on $($groupPlan.RdmDatastore.Name)." -Level INFO

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
        foreach ($vmItem in $groupPlan.VMItems) {
            Stop-VMForMigration -VMItem $vmItem -MigrationGroup $groupPlan.Name
            Remove-RdmsAndControllers -VMItem $vmItem -MigrationGroup $groupPlan.Name
        }

        foreach ($vmItem in $groupPlan.VMItems) {
            $relocateDetail = "Cold-relocate '$($vmItem.VM.Name)' to host '$($vmItem.DestinationHost.Name)', datastore cluster '$($groupPlan.DatastoreCluster.Name)' and resource pool '$($groupPlan.ResourcePool.Name)'."
            Invoke-PlannedChange $groupPlan.Name $vmItem.VM.Name 'ColdRelocate' $vmItem.DestinationHost.Name $relocateDetail {
                $moveParameters = @{
                    VM          = Get-VM -Id $vmItem.VM.Id
                    Destination = $vmItem.DestinationHost
                    Datastore   = $groupPlan.DatastoreCluster
                    Confirm     = $false
                }
                Move-VM @moveParameters | Out-Null

                $currentView = Get-View -Id $vmItem.VM.Id
                $poolView = Get-View -Id $groupPlan.ResourcePool.Id
                $poolView.MoveIntoResourcePool([VMware.Vim.ManagedObjectReference[]]@($currentView.MoRef))
            }

            Add-DestinationRdms -VMItem $vmItem -GroupPlan $groupPlan
        }

        if ($DryRun) {
            Add-Result $groupPlan.Name '' 'Verify' 'DryRun' 'Post-migration verification runs only in an execution run.'
        }
        else {
            $verification = @(Confirm-MigrationOutcome -GroupPlan $groupPlan)
            $script:Verification.AddRange($verification)
            $failures = @($verification | Where-Object { $_.Status -ne 'Passed' })
            foreach ($failure in $failures) {
                Add-Result $groupPlan.Name $failure.VM 'Verify' 'Failed' "SCSI $($failure.ScsiAddress): $($failure.Detail)"
            }
            if ($failures.Count -gt 0) {
                throw "Post-migration verification failed for $($failures.Count) disk(s) in '$($groupPlan.Name)'. See the verification CSV."
            }
            Add-Result $groupPlan.Name '' 'Verify' 'Passed' "All $($verification.Count) disk placements match the plan."
        }

        $groupStatus = if ($DryRun) { 'DryRunPassed' } else { 'Succeeded' }
        Add-Result $groupPlan.Name '' 'Group' $groupStatus 'Migration group processing completed.'
        Write-RichoLog "Migration group $($groupPlan.Name): $groupStatus." -Level INFO
    }

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
    Add-Result '' '' 'Fatal' 'Failed' $_.Exception.Message
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (Test-Path -LiteralPath $OutputFolder) {
        Export-RunArtifact -Records $script:Plan.ToArray() -Name 'change-plan' -Folder $OutputFolder
        Export-RunArtifact -Records $script:Results.ToArray() -Name 'results' -Folder $OutputFolder
        Export-RunArtifact -Records $script:Verification.ToArray() -Name 'verification' -Folder $OutputFolder
    }
    if ($connection) {
        Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue
    }
}
