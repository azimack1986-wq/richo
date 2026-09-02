<#
.SYNOPSIS
    Runs Invoke-SqlRdmClusterMigration.ps1 end to end against a simulated vCenter.

.DESCRIPTION
    The unit suite proves the pieces. This proves the workflow: a whole migration group
    is taken through shutdown, RDM removal, controller removal, cold relocate, controller
    recreation and RDM re-attachment, and the resulting virtual hardware is compared with
    what went in.

    Nothing here touches infrastructure. The VMware.Vim device types are compiled as
    stand-ins so the script's type tests behave as they do against the real SDK, and the
    PowerCLI cmdlets are functions over an in-memory inventory that a reconfigure really
    does mutate - so an ordering mistake in the script shows up as wrong hardware at the
    end, exactly as it would on a live run.

    The simulated group is deliberately awkward:

      * two nodes sharing their RDM mapping files, VMware's cluster-across-boxes build;
      * LSI Logic SAS controllers, not PVSCSI, so a hardcoded controller type is caught;
      * a host-attached CD-ROM whose backing has a DeviceName and no CompatibilityMode,
        the device that used to crash discovery under Set-StrictMode;
      * an extra empty SCSI controller on a bus the CSV never mentions, which must be
        left alone;
      * a host in the destination cluster that cannot see the LUNs, which must be
        excluded rather than used.

.PARAMETER ScriptPath
    The migration script under test.

.EXAMPLE
    pwsh -File ./tests/Test-SqlRdmMigrationSimulation.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$script:Passed = 0
$script:Failed = 0
$script:Completed = $false
$script:WorkFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("SqlRdmSim-{0}" -f [guid]::NewGuid())

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', actual '$Actual'." }
}

function Invoke-SimTest {
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

# --------------------------------------------------------------- VMware.Vim stand-ins ----
# Only the members the script actually touches. VirtualCdromAtapiBackingInfo deliberately
# has a DeviceName and no CompatibilityMode: that combination is what made the old
# duck-typed RDM discovery throw under Set-StrictMode.
if (-not ('VMware.Vim.VirtualDisk' -as [type])) {
    Add-Type -TypeDefinition @'
namespace VMware.Vim {
    public class Description { public string Label; public string Summary; }
    public class VirtualDeviceBackingInfo { }
    public class VirtualDeviceFileBackingInfo : VirtualDeviceBackingInfo { public string FileName; }
    public class VirtualDiskFlatVer2BackingInfo : VirtualDeviceFileBackingInfo { public string DiskMode; }
    public class VirtualDiskRawDiskMappingVer1BackingInfo : VirtualDeviceFileBackingInfo {
        public string CompatibilityMode;
        public string DeviceName;
        public string LunUuid;
        public string DiskMode;
    }
    public class VirtualCdromAtapiBackingInfo : VirtualDeviceBackingInfo { public string DeviceName; }
    public class VirtualDevice {
        public int Key;
        public Description DeviceInfo;
        public VirtualDeviceBackingInfo Backing;
        public int ControllerKey;
        public System.Nullable<int> UnitNumber;
    }
    public class VirtualController : VirtualDevice { }
    public class VirtualPCIController : VirtualController { }
    public class VirtualSCSIController : VirtualController { public int BusNumber; public string SharedBus; }
    public class ParaVirtualSCSIController : VirtualSCSIController { }
    public class VirtualLsiLogicSASController : VirtualSCSIController { }
    public class VirtualDisk : VirtualDevice { public long CapacityInKB; public long CapacityInBytes; public string Sharing; }
    public class VirtualCdrom : VirtualDevice { }
    public class VirtualDeviceConfigSpec {
        public string Operation;
        public string FileOperation;
        public VirtualDevice Device;
    }
    public class VirtualMachineConfigSpec { public VirtualDeviceConfigSpec[] DeviceChange; }
    public class ManagedObjectReference { public string Type; public string Value; }
    public class VirtualMachineRelocateSpec {
        public ManagedObjectReference Pool;
        public ManagedObjectReference Host;
        public ManagedObjectReference Datastore;
    }
    public enum VirtualMachineMovePriority { lowPriority, highPriority, defaultPriority }
    public class StorageDrsPodSelectionSpec { public ManagedObjectReference StoragePod; }
    public class StoragePlacementSpec {
        public string Type;
        public ManagedObjectReference Vm;
        public ManagedObjectReference ResourcePool;
        public StorageDrsPodSelectionSpec PodSelectionSpec;
        public string Priority;
    }
}
'@
}

# ------------------------------------------------------------------ simulated estate ----

$global:Sim = @{
    VMs               = [ordered]@{}
    Hosts             = [ordered]@{}
    Clusters          = [ordered]@{}
    Pools             = [ordered]@{}
    DatastoreClusters = [ordered]@{}
    Datastores        = [ordered]@{}
    HostDatastores    = @{}
    HostPaths         = @{}
    HostLuns          = @{}
    Tasks             = @{}
    PromptAnswers     = [System.Collections.Generic.List[string]]::new()
    NextDeviceKey     = 5000
    NextTask          = 0
    Events            = [System.Collections.Generic.List[string]]::new()
}

function Add-SimEvent {
    param([string]$Text)
    $global:Sim.Events.Add($Text)
}

function New-SimDescription {
    param([string]$Label)
    $description = New-Object VMware.Vim.Description
    $description.Label = $Label
    return $description
}

function New-SimScsiController {
    param([string]$TypeName, [int]$Key, [int]$BusNumber, [string]$SharedBus, [string]$Label)
    $controller = New-Object -TypeName $TypeName
    $controller.Key = $Key
    $controller.BusNumber = $BusNumber
    $controller.SharedBus = $SharedBus
    $controller.ControllerKey = 100
    $controller.UnitNumber = $BusNumber + 3
    $controller.DeviceInfo = New-SimDescription -Label $Label
    return $controller
}

function New-SimRdm {
    param([int]$Key, [int]$ControllerKey, [int]$UnitNumber, [string]$Label, [string]$Naa, [double]$CapacityGB, [string]$MappingFile)
    $backing = New-Object VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo
    $backing.CompatibilityMode = 'physicalMode'
    $backing.DiskMode = 'independent_persistent'
    $backing.DeviceName = "/vmfs/devices/disks/$Naa"
    $backing.FileName = $MappingFile
    $backing.LunUuid = "uuid-$Naa"

    $disk = New-Object VMware.Vim.VirtualDisk
    $disk.Key = $Key
    $disk.ControllerKey = $ControllerKey
    $disk.UnitNumber = $UnitNumber
    $disk.DeviceInfo = New-SimDescription -Label $Label
    $disk.Backing = $backing
    $disk.CapacityInBytes = [long]($CapacityGB * 1GB)
    $disk.CapacityInKB = [long]($CapacityGB * 1MB)
    $disk.Sharing = 'sharingNone'
    return $disk
}

function New-SimVM {
    param([string]$Name, [int]$Index, [string[]]$Naas, [string]$MappingOwner)

    $devices = [System.Collections.Generic.List[object]]::new()

    $pci = New-Object VMware.Vim.VirtualPCIController
    $pci.Key = 100
    $pci.DeviceInfo = New-SimDescription -Label 'PCI controller 0'
    $devices.Add($pci)

    # SCSI 0: the operating system, on a plain VMDK. Never to be touched.
    $bootController = New-SimScsiController -TypeName 'VMware.Vim.ParaVirtualSCSIController' -Key (1000 + $Index * 10) -BusNumber 0 -SharedBus 'noSharing' -Label 'SCSI controller 0'
    $devices.Add($bootController)

    $osBacking = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo
    $osBacking.FileName = "[sim-ds-01] $Name/$Name.vmdk"
    $osBacking.DiskMode = 'persistent'
    $osDisk = New-Object VMware.Vim.VirtualDisk
    $osDisk.Key = 2000 + $Index * 10
    $osDisk.ControllerKey = $bootController.Key
    $osDisk.UnitNumber = 0
    $osDisk.DeviceInfo = New-SimDescription -Label 'Hard disk 1'
    $osDisk.Backing = $osBacking
    $osDisk.CapacityInBytes = 80GB
    $devices.Add($osDisk)

    # The device that used to crash discovery: a DeviceName on a backing with no
    # CompatibilityMode property at all.
    $cdromBacking = New-Object VMware.Vim.VirtualCdromAtapiBackingInfo
    $cdromBacking.DeviceName = '/vmfs/devices/cdrom/mpx.vmhba0:C0:T0:L0'
    $cdrom = New-Object VMware.Vim.VirtualCdrom
    $cdrom.Key = 3000 + $Index * 10
    $cdrom.ControllerKey = 200
    $cdrom.UnitNumber = 0
    $cdrom.DeviceInfo = New-SimDescription -Label 'CD/DVD drive 1'
    $cdrom.Backing = $cdromBacking
    $devices.Add($cdrom)

    # SCSI 1: LSI Logic SAS carrying the cluster's RDMs, with NO bus sharing - which is
    # how this estate builds them, and which the script must reproduce rather than
    # correct. The mapping files belong to the first node and are attached by the rest.
    $sharedController = New-SimScsiController -TypeName 'VMware.Vim.VirtualLsiLogicSASController' -Key (1001 + $Index * 10) -BusNumber 1 -SharedBus 'noSharing' -Label 'SCSI controller 1'
    $devices.Add($sharedController)

    $capacities = @(100, 250, 500)
    for ($i = 0; $i -lt $Naas.Count; $i++) {
        $devices.Add((New-SimRdm -Key (4000 + $Index * 10 + $i) -ControllerKey $sharedController.Key -UnitNumber $i -Label "Hard disk $($i + 2)" -Naa $Naas[$i] -CapacityGB $capacities[$i] -MappingFile "[simsql02sit_i_rdm] $MappingOwner/$MappingOwner`_$($i + 1).vmdk"))
    }

    # SCSI 2: empty, on a bus the CSV never mentions. Must survive the migration.
    $strayController = New-SimScsiController -TypeName 'VMware.Vim.ParaVirtualSCSIController' -Key (1002 + $Index * 10) -BusNumber 2 -SharedBus 'noSharing' -Label 'SCSI controller 2'
    $devices.Add($strayController)

    return [pscustomobject]@{
        Name                 = $Name
        Id                   = "VirtualMachine-vm-$Index"
        PowerState           = 'PoweredOn'
        VMHostName           = 'sim-esx01'
        ClusterName          = 'simsql01'
        ResourcePoolName     = 'SIM-SOURCE-RP'
        DatastoreName        = 'sim-ds-src'
        DatastoreClusterName = 'SIM-SOURCE-DSC'
        ToolsRunningStatus   = 'guestToolsRunning'
        VmxPath              = "[sim-ds-src] $Name/$Name.vmx"
        ChangeVersion        = '2026-09-01T00:00:00.000000Z'
        Devices              = $devices
    }
}

function Reset-SimInventory {
    $global:Sim.VMs = [ordered]@{}
    $global:Sim.Tasks = @{}
    $global:Sim.PromptAnswers = [System.Collections.Generic.List[string]]::new()
    $global:Sim.NextDeviceKey = 5000
    $global:Sim.NextTask = 0
    $global:Sim.Events = [System.Collections.Generic.List[string]]::new()
    # When set, Stop-VMGuest is accepted and ignored - the guest that takes the request
    # and keeps running, which is exactly what the hard power-off exists for.
    $global:Sim.IgnoreGuestShutdown = $false

    $naas = @('naa.6000000000000040', 'naa.6000000000000041', 'naa.6000000000000042')
    $global:Sim.VMs['SIMSQLA'] = New-SimVM -Name 'SIMSQLA' -Index 1 -Naas $naas -MappingOwner 'SIMSQLA'
    $global:Sim.VMs['SIMSQLB'] = New-SimVM -Name 'SIMSQLB' -Index 2 -Naas $naas -MappingOwner 'SIMSQLA'

    # One-LUN VMs for the PROD and DEV rows: the same shared cluster, different mapping
    # directories.
    $global:Sim.VMs['SIMSQLPRD'] = New-SimVM -Name 'SIMSQLPRD' -Index 3 -Naas @('naa.6000000000000043') -MappingOwner 'SIMSQLPRD'
    $global:Sim.VMs['SIMSQLDEV'] = New-SimVM -Name 'SIMSQLDEV' -Index 4 -Naas @('naa.6000000000000044') -MappingOwner 'SIMSQLDEV'

    $global:Sim.Clusters = [ordered]@{
        'simsql01' = [pscustomobject]@{ Name = 'simsql01'; Id = 'ClusterComputeResource-domain-c1'; DrsEnabled = $true }
        'simsql02' = [pscustomobject]@{ Name = 'simsql02'; Id = 'ClusterComputeResource-domain-c2'; DrsEnabled = $true }
    }
    $global:Sim.Pools = [ordered]@{
        'SIM-SQL-RP' = [pscustomobject]@{ Name = 'SIM-SQL-RP'; Id = 'ResourcePool-resgroup-1'; ClusterName = 'simsql02' }
    }
    $global:Sim.DatastoreClusters = [ordered]@{
        'SIM-VM-DSC' = [pscustomobject]@{ Name = 'SIM-VM-DSC'; Id = 'StoragePod-group-p1' }
    }
    # One shared cluster, one mapping directory per workload type - which is the whole
    # reason the workload type exists in the CSV.
    $global:Sim.Datastores = [ordered]@{
        'sim-ds-01'          = [pscustomobject]@{ Name = 'sim-ds-01'; Id = 'Datastore-datastore-1'; PodName = 'SIM-VM-DSC'; FreeSpaceGB = 400; Accessible = $true }
        'sim-ds-02'          = [pscustomobject]@{ Name = 'sim-ds-02'; Id = 'Datastore-datastore-5'; PodName = 'SIM-VM-DSC'; FreeSpaceGB = 900; Accessible = $true }
        'simsql02sit_i_rdm'  = [pscustomobject]@{ Name = 'simsql02sit_i_rdm'; Id = 'Datastore-datastore-2'; PodName = ''; FreeSpaceGB = 50; Accessible = $true }
        'simsql02_i_rdm'     = [pscustomobject]@{ Name = 'simsql02_i_rdm'; Id = 'Datastore-datastore-3'; PodName = ''; FreeSpaceGB = 50; Accessible = $true }
        'simsql02dev_i_rdm'  = [pscustomobject]@{ Name = 'simsql02dev_i_rdm'; Id = 'Datastore-datastore-4'; PodName = ''; FreeSpaceGB = 50; Accessible = $true }
    }

    $global:Sim.Hosts = [ordered]@{}
    foreach ($hostName in @('sim-esx01', 'sim-esx02', 'sim-esx03')) {
        $global:Sim.Hosts[$hostName] = [pscustomobject]@{
            Name            = $hostName
            Id              = "HostSystem-host-$hostName"
            ClusterName     = if ($hostName -eq 'sim-esx01') { 'simsql01' } else { 'simsql02' }
            ConnectionState = 'Connected'
            PowerState      = 'PoweredOn'
            ExtensionData   = [pscustomobject]@{ Runtime = [pscustomobject]@{ InMaintenanceMode = $false } }
        }
    }
    # sim-esx01 is the source host and lives in the source cluster; the destination
    # cluster holds esx02 (sees the LUNs) and esx03 (does not).
    # esx03 sits in the destination cluster but does not mount the RDM datastore, and it
    # has no paths to the LUNs either - so it is excluded whether or not the run verifies
    # presentation.
    $global:Sim.HostDatastores = @{
        'sim-esx01' = @('sim-ds-01', 'sim-ds-02', 'simsql02sit_i_rdm', 'simsql02_i_rdm', 'simsql02dev_i_rdm')
        'sim-esx02' = @('sim-ds-01', 'sim-ds-02', 'simsql02sit_i_rdm', 'simsql02_i_rdm', 'simsql02dev_i_rdm')
        'sim-esx03' = @('sim-ds-01')
    }

    $paths = @()
    $luns = @()
    for ($i = 0; $i -lt $naas.Count; $i++) {
        $paths += [pscustomobject]@{
            LUN              = 40 + $i
            TargetIdentifier = "iqn.1992-08.com.netapp:sn.sim-svm01:vs.1"
            Device           = $naas[$i]
        }
        $luns += [pscustomobject]@{
            CanonicalName     = $naas[$i]
            ConsoleDeviceName = "/vmfs/devices/disks/$($naas[$i])"
            CapacityGB        = @(100, 250, 500)[$i]
        }
    }
    $global:Sim.HostPaths = @{ 'sim-esx01' = $paths; 'sim-esx02' = $paths; 'sim-esx03' = @() }
    $global:Sim.HostLuns = @{ 'sim-esx01' = $luns; 'sim-esx02' = $luns; 'sim-esx03' = @() }
}

# --------------------------------------------------------------- PowerCLI stand-ins ----
# Functions, so they take precedence over anything of the same name, and so the migration
# script needs no knowledge that it is being simulated.

function Resolve-SimVM {
    param($VM)
    if ($VM -is [string]) {
        if ($global:Sim.VMs.Contains($VM)) { return $global:Sim.VMs[$VM] }
        foreach ($candidate in $global:Sim.VMs.Values) { if ($candidate.Id -eq $VM) { return $candidate } }
        throw "Simulated VM '$VM' not found."
    }
    return Resolve-SimVM -VM ([string]$VM.Id)
}

function New-SimTask {
    param([string]$Description)
    $global:Sim.NextTask++
    $value = "task-$($global:Sim.NextTask)"
    $task = [pscustomobject]@{
        Id              = "Task-$value"
        Value           = $value
        Name            = $Description
        State           = 'Success'
        PercentComplete = 100
        ExtensionData   = [pscustomobject]@{ Info = [pscustomobject]@{ Error = $null } }
    }
    $global:Sim.Tasks[$task.Id] = $task
    return $task
}

function Copy-SimDevice {
    # vCenter creates a NEW device on the target VM when a spec carries one from another.
    # Sharing the instance would let a key assignment on one VM corrupt the other.
    param($Device)

    $copy = New-Object -TypeName $Device.GetType().FullName
    foreach ($property in $Device.GetType().GetFields()) {
        $property.SetValue($copy, $property.GetValue($Device))
    }
    if ($Device -is [VMware.Vim.VirtualDisk]) {
        $backing = New-Object -TypeName $Device.Backing.GetType().FullName
        foreach ($property in $Device.Backing.GetType().GetFields()) {
            $property.SetValue($backing, $property.GetValue($Device.Backing))
        }
        $copy.Backing = $backing
    }
    return $copy
}

function Invoke-SimReconfigure {
    param([string]$VMName, $Spec)

    $vm = $global:Sim.VMs[$VMName]
    $keyMap = @{}
    foreach ($change in @($Spec.DeviceChange)) {
        $device = $change.Device
        switch ($change.Operation) {
            'edit' {
                $existing = @($vm.Devices | Where-Object { $_.Key -eq $device.Key })
                if ($existing.Count -ne 1) { throw "Simulated edit: device key $($device.Key) not found on $VMName." }
                $existing[0].UnitNumber = $device.UnitNumber
                Add-SimEvent "edit-unit $VMName key=$($device.Key) unit=$($device.UnitNumber)"
            }
            'add' {
                if (@($vm.Devices | Where-Object { [object]::ReferenceEquals($_, $device) }).Count -eq 0) {
                    $device = Copy-SimDevice -Device $device
                }
                $originalKey = [int]$device.Key
                $global:Sim.NextDeviceKey++
                $device.Key = $global:Sim.NextDeviceKey
                $keyMap[$originalKey] = [int]$device.Key
                if (($device -is [VMware.Vim.VirtualDisk]) -and $keyMap.ContainsKey([int]$device.ControllerKey)) {
                    $device.ControllerKey = $keyMap[[int]$device.ControllerKey]
                }

                if ($device -is [VMware.Vim.VirtualDisk]) {
                    $diskCount = @($vm.Devices | Where-Object { $_ -is [VMware.Vim.VirtualDisk] }).Count
                    $device.DeviceInfo = New-SimDescription -Label "Hard disk $($diskCount + 1)"

                    # An RDM is added with no capacity in the spec; vCenter fills it in
                    # from the LUN. The simulation has to do the same or the script's own
                    # verification has nothing to check against.
                    if ($device.Backing -is [VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo]) {
                        # vCenter refused a physical-mode RDM with no disk mode:
                        # "Incompatible device backing specified for device '0'".
                        if ([string]::IsNullOrWhiteSpace($device.Backing.DiskMode)) {
                            throw "Incompatible device backing specified for device '0'."
                        }

                        $canonical = ([string]$device.Backing.DeviceName) -replace '^.*/', ''
                        $lun = @($global:Sim.HostLuns['sim-esx02'] | Where-Object { $_.CanonicalName -eq $canonical })
                        if ($lun.Count -ne 1) { throw "Simulated attach of unknown device '$canonical'." }
                        $device.CapacityInBytes = [long]($lun[0].CapacityGB * 1GB)
                        $device.CapacityInKB = [long]($lun[0].CapacityGB * 1MB)
                    }
                    if ($change.FileOperation -eq 'create') {
                        # vCenter generates the mapping file name when handed a bare
                        # "[datastore]" path.
                        $datastoreName = ([string]$device.Backing.FileName).Trim('[', ']')
                        $device.Backing.FileName = "[$datastoreName] $VMName/$VMName" + "_rdm$($device.UnitNumber).vmdk"
                        Add-SimEvent "create-mapping $VMName $($device.Backing.FileName)"
                    }
                    else {
                        Add-SimEvent "attach-mapping $VMName $($device.Backing.FileName)"
                    }
                }
                elseif ($device -is [VMware.Vim.VirtualSCSIController]) {
                    $device.DeviceInfo = New-SimDescription -Label "SCSI controller $($device.BusNumber)"
                    Add-SimEvent "add-controller $VMName bus=$($device.BusNumber) type=$($device.GetType().Name) sharing=$($device.SharedBus)"
                }

                $vm.Devices.Add($device)
            }
            'remove' {
                $existing = @($vm.Devices | Where-Object { $_.Key -eq $device.Key })
                if ($existing.Count -ne 1) { throw "Simulated reconfigure: device key $($device.Key) not found on $VMName." }
                [void]$vm.Devices.Remove($existing[0])
                Add-SimEvent "remove-device $VMName key=$($device.Key) type=$($existing[0].GetType().Name)"
            }
            default { throw "Simulated reconfigure does not implement operation '$($change.Operation)'." }
        }
    }

    $task = New-SimTask -Description "reconfigure $VMName"
    return ([pscustomobject]@{ Type = 'Task'; Value = $task.Value })
}

function ConvertTo-SimViewId {
    # Get-View takes either an id string or a managed object reference, and the real one
    # resolves both. A reference whose value already carries its type prefix is a sim id
    # as it stands; anything else is qualified with its type.
    param($Reference)

    if ($Reference -is [VMware.Vim.ManagedObjectReference]) {
        if ([string]$Reference.Value -like "$($Reference.Type)-*") { return [string]$Reference.Value }
        return "$($Reference.Type)-$($Reference.Value)"
    }
    return [string]$Reference
}

function Get-View {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Id, $Property)

    $Id = @($Id | ForEach-Object { ConvertTo-SimViewId -Reference $_ })
    if ($Id.Count -eq 1) { $Id = $Id[0] }

    # A datastore's mount table, the way eligibility reads it now: one query for all of
    # them, each entry naming a host by managed object reference.
    $datastoreIds = @(@($Id) | Where-Object { [string]$_ -like 'Datastore-*' })
    if ($datastoreIds.Count -gt 0) {
        return @(
            $datastoreIds | ForEach-Object {
                $datastoreId = [string]$_
                $datastore = @($global:Sim.Datastores.Values | Where-Object { $_.Id -eq $datastoreId })[0]
                $mounts = @(
                    $global:Sim.Hosts.Values |
                        Where-Object { $datastore.Name -in $global:Sim.HostDatastores[[string]$_.Name] } |
                        ForEach-Object {
                            [pscustomobject]@{
                                Key       = [pscustomobject]@{ Type = 'HostSystem'; Value = ([string]$_.Id -replace '^HostSystem-', '') }
                                MountInfo = [pscustomobject]@{ Mounted = $true; Accessible = $true }
                            }
                        }
                )
                $datastoreRef = New-Object VMware.Vim.ManagedObjectReference
                $datastoreRef.Type = 'Datastore'
                $datastoreRef.Value = ($datastoreId -replace '^Datastore-', '')
                [pscustomobject]@{ Id = $datastoreId; Name = $datastore.Name; MoRef = $datastoreRef; Host = $mounts }
            }
        )
    }

    $identifier = [string]$Id

    if ($identifier -like 'ResourcePool-*') {
        $pool = @($global:Sim.Pools.Values | Where-Object { $_.Id -eq $identifier })[0]
        $poolRef = New-Object VMware.Vim.ManagedObjectReference
        $poolRef.Type = 'ResourcePool'
        $poolRef.Value = $identifier
        return [pscustomobject]@{ Name = $pool.Name; Id = $identifier; MoRef = $poolRef }
    }

    if ($identifier -like 'StoragePod-*') {
        $pod = @($global:Sim.DatastoreClusters.Values | Where-Object { $_.Id -eq $identifier })[0]
        $podRef = New-Object VMware.Vim.ManagedObjectReference
        $podRef.Type = 'StoragePod'
        $podRef.Value = $identifier
        return [pscustomobject]@{ Name = $pod.Name; Id = $identifier; MoRef = $podRef }
    }

    if ($identifier -like 'ClusterComputeResource-*') {
        $cluster = @($global:Sim.Clusters.Values | Where-Object { $_.Id -eq $identifier })[0]
        $view = [pscustomobject]@{ Name = $cluster.Name; Id = $identifier; SimClusterName = $cluster.Name }
        # DRS initial placement: every connected host in the cluster is a candidate, and
        # the one that mounts the most of the estate's storage is rated highest.
        Add-Member -InputObject $view -MemberType ScriptMethod -Name RecommendHostsForVm -Value {
            param($VmRef, $PoolRef)
            Add-SimEvent "recommend-hosts $($this.SimClusterName)"
            return @(
                $global:Sim.Hosts.Values |
                    Where-Object {
                        ($_.ClusterName -eq $this.SimClusterName) -and
                        ($_.ConnectionState -eq 'Connected') -and
                        ($_.PowerState -eq 'PoweredOn')
                    } |
                    ForEach-Object {
                        $hostRef = New-Object VMware.Vim.ManagedObjectReference
                        $hostRef.Type = 'HostSystem'
                        $hostRef.Value = [string]$_.Id
                        [pscustomobject]@{
                            Host   = $hostRef
                            Rating = @($global:Sim.HostDatastores[[string]$_.Name]).Count
                        }
                    } |
                    Sort-Object -Property Rating -Descending
            )
        }
        return $view
    }

    if ($identifier -like 'HostSystem-*') {
        $simHost = @($global:Sim.Hosts.Values | Where-Object { $_.Id -eq $identifier })[0]
        return [pscustomobject]@{ Name = $simHost.Name; Id = $identifier }
    }

    if ($identifier -eq 'ServiceInstance') {
        return [pscustomobject]@{
            Content = [pscustomobject]@{ StorageResourceManager = 'StorageResourceManager-srm' }
        }
    }

    if ($identifier -like 'StorageResourceManager-*') {
        $view = [pscustomobject]@{ Id = $identifier }
        # Storage DRS: the emptiest datastore in the pod, which is what the real thing
        # tends to answer for an initial placement on a balanced pod.
        Add-Member -InputObject $view -MemberType ScriptMethod -Name RecommendDatastores -Value {
            param($Spec)
            Add-SimEvent 'recommend-datastores'
            $pod = @($global:Sim.DatastoreClusters.Values | Where-Object { $_.Id -eq [string]$Spec.PodSelectionSpec.StoragePod.Value })[0]
            $candidates = @(
                $global:Sim.Datastores.Values |
                    Where-Object { $_.PodName -eq $pod.Name } |
                    Sort-Object -Property FreeSpaceGB -Descending
            )
            $rating = 100
            return [pscustomobject]@{
                Recommendations = @(
                    $candidates | ForEach-Object {
                        $destination = New-Object VMware.Vim.ManagedObjectReference
                        $destination.Type = 'Datastore'
                        $destination.Value = ([string]$_.Id -replace '^Datastore-', '')
                        $recommendation = [pscustomobject]@{
                            Rating = $rating
                            Action = @([pscustomobject]@{ Destination = $destination })
                        }
                        $rating -= 10
                        $recommendation
                    }
                )
            }
        }
        return $view
    }

    $vm = Resolve-SimVM -VM $identifier
    $moRef = New-Object VMware.Vim.ManagedObjectReference
    $moRef.Type = 'VirtualMachine'
    $moRef.Value = $vm.Id

    $view = [pscustomobject]@{
        SimVMName = $vm.Name
        Name      = $vm.Name
        MoRef     = $moRef
        Snapshot  = $null
        Config    = [pscustomobject]@{
            ChangeVersion = $vm.ChangeVersion
            Files         = [pscustomobject]@{ VmPathName = $vm.VmxPath }
            Hardware      = [pscustomobject]@{ Device = $vm.Devices.ToArray() }
        }
    }
    Add-Member -InputObject $view -MemberType ScriptMethod -Name ReconfigVM_Task -Value {
        param($Spec)
        Invoke-SimReconfigure -VMName $this.SimVMName -Spec $Spec
    }
    Add-Member -InputObject $view -MemberType ScriptMethod -Name ReconfigVM -Value {
        param($Spec)
        [void](Invoke-SimReconfigure -VMName $this.SimVMName -Spec $Spec)
    }
    Add-Member -InputObject $view -MemberType ScriptMethod -Name RelocateVM_Task -Value {
        param($Spec, $Priority)
        return (Invoke-SimRelocate -VMName $this.SimVMName -Spec $Spec)
    }
    return $view
}

function Get-VM {
    [CmdletBinding()]
    param([string]$Name, [string]$Id, $Location)

    $matches = @($global:Sim.VMs.Values)
    if ($Name) { $matches = @($matches | Where-Object { $_.Name -eq $Name }) }
    if ($Id) { $matches = @($matches | Where-Object { $_.Id -eq $Id }) }

    return @($matches | ForEach-Object {
        $vm = $_
        [pscustomobject]@{
            Name          = $vm.Name
            Id            = $vm.Id
            PowerState    = $vm.PowerState
            VMHost        = [pscustomobject]@{ Name = $vm.VMHostName }
            ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ ToolsRunningStatus = $vm.ToolsRunningStatus } }
        }
    })
}

function Get-Cluster {
    [CmdletBinding()]
    param([string]$Name, $VM)

    if ($VM) {
        $simVM = Resolve-SimVM -VM $VM
        return @($global:Sim.Clusters.Values | Where-Object { $_.Name -eq $simVM.ClusterName })
    }
    return @($global:Sim.Clusters.Values | Where-Object { $_.Name -eq $Name })
}

function Get-ResourcePool {
    [CmdletBinding()]
    param([string]$Name, $Location, $VM)

    if ($VM) {
        $simVM = Resolve-SimVM -VM $VM
        return @($global:Sim.Pools.Values | Where-Object { $_.Name -eq $simVM.ResourcePoolName })
    }
    return @($global:Sim.Pools.Values | Where-Object { $_.Name -eq $Name })
}

function Get-DatastoreCluster {
    [CmdletBinding()]
    param([string]$Name)
    return @($global:Sim.DatastoreClusters.Values | Where-Object { $_.Name -eq $Name })
}

function Get-Datastore {
    [CmdletBinding()]
    param([string]$Name, [string]$Id, $Location, $VMHost)

    if ($Id) {
        return @($global:Sim.Datastores.Values | Where-Object { $_.Id -eq $Id })
    }
    if ($VMHost) {
        $names = $global:Sim.HostDatastores[[string]$VMHost.Name]
        return @($global:Sim.Datastores.Values | Where-Object { $_.Name -in $names })
    }
    if ($Location) {
        return @($global:Sim.Datastores.Values | Where-Object { $_.PodName -eq [string]$Location.Name })
    }
    return @($global:Sim.Datastores.Values | Where-Object { $_.Name -eq $Name })
}

function Get-VMHost {
    [CmdletBinding()]
    param([string]$Name, $Location)
    if ($Location) {
        return @($global:Sim.Hosts.Values | Where-Object { $_.ClusterName -eq [string]$Location.Name })
    }
    return @($global:Sim.Hosts.Values)
}

function Get-EsxCli {
    [CmdletBinding()]
    param($VMHost, [switch]$V2)

    $list = [pscustomobject]@{ SimHostName = [string]$VMHost.Name }
    Add-Member -InputObject $list -MemberType ScriptMethod -Name Invoke -Value {
        return $global:Sim.HostPaths[$this.SimHostName]
    }

    return [pscustomobject]@{
        storage = [pscustomobject]@{
            core = [pscustomobject]@{
                path = [pscustomobject]@{ list = $list }
            }
        }
    }
}

function Get-ScsiLun {
    [CmdletBinding()]
    param($VMHost, [string]$LunType, [string]$CanonicalName)

    $luns = @($global:Sim.HostLuns[[string]$VMHost.Name])
    if ($CanonicalName) { $luns = @($luns | Where-Object { $_.CanonicalName -eq $CanonicalName }) }
    return $luns
}

function Get-HardDisk {
    [CmdletBinding()]
    param($VM, [string]$Name)

    $vm = Resolve-SimVM -VM $VM
    $disks = @(
        $vm.Devices |
            Where-Object { $_ -is [VMware.Vim.VirtualDisk] } |
            ForEach-Object {
                [pscustomobject]@{
                    Name              = [string]$_.DeviceInfo.Label
                    SimVMName         = $vm.Name
                    DiskType          = $(if ($_.Backing -is [VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo]) { 'RawPhysical' } else { 'Flat' })
                    ScsiCanonicalName = $(if ($_.Backing -is [VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo]) { ([string]$_.Backing.DeviceName -replace '^.*/', '') } else { '' })
                    ExtensionData     = $_
                }
            }
    )
    if ($Name) { $disks = @($disks | Where-Object { $_.Name -eq $Name }) }
    return $disks
}

function New-HardDisk {
    [CmdletBinding()]
    param($VM, [string]$DeviceName, [string]$DiskType, $Datastore, $Controller)

    if ($DiskType -ne 'RawPhysical') { throw "Simulated New-HardDisk only makes RawPhysical disks; asked for '$DiskType'." }

    $vm = Resolve-SimVM -VM $VM
    $canonical = $DeviceName -replace '^.*/', ''
    $lun = @($global:Sim.HostLuns[[string]$vm.VMHostName] | Where-Object { $_.CanonicalName -eq $canonical })
    if ($lun.Count -ne 1) { throw "Simulated New-HardDisk: host $($vm.VMHostName) cannot see '$canonical'." }

    # No -Controller means PowerCLI picks an existing one, which is why the estate's
    # sequence creates the controller FROM the first disk and moves it.
    $controllers = @($vm.Devices | Where-Object { $_ -is [VMware.Vim.VirtualSCSIController] } | Sort-Object BusNumber)
    if ($Controller) {
        $controllers = @($controllers | Where-Object { $_.Key -eq $Controller.SimKey })
        if ($controllers.Count -ne 1) { throw 'Simulated New-HardDisk: the named controller is not on this VM.' }
    }
    if ($controllers.Count -eq 0) { throw 'Simulated New-HardDisk: the VM has no SCSI controller.' }
    $target = $controllers[0]

    $used = @($vm.Devices | Where-Object { ($_ -is [VMware.Vim.VirtualDisk]) -and ([int]$_.ControllerKey -eq [int]$target.Key) } | ForEach-Object { [int]$_.UnitNumber })
    $unit = 0
    while (($unit -eq 7) -or ($used -contains $unit)) { $unit++ }

    $global:Sim.NextDeviceKey++
    $diskCount = @($vm.Devices | Where-Object { $_ -is [VMware.Vim.VirtualDisk] }).Count
    $disk = New-SimRdm -Key $global:Sim.NextDeviceKey -ControllerKey ([int]$target.Key) -UnitNumber $unit `
        -Label "Hard disk $($diskCount + 1)" -Naa $canonical -CapacityGB ([double]$lun[0].CapacityGB) `
        -MappingFile "[$($Datastore.Name)] $($vm.Name)/$($vm.Name)_$($global:Sim.NextDeviceKey).vmdk"
    $vm.Devices.Add($disk)
    Add-SimEvent "new-harddisk $($vm.Name) $canonical -> bus $($target.BusNumber) unit $unit"

    return (Get-HardDisk -VM $vm -Name $disk.DeviceInfo.Label)[0]
}

function New-ScsiController {
    [CmdletBinding(SupportsShouldProcess)]
    param($HardDisk, [string]$BusSharingMode, [string]$Type)

    $vm = $global:Sim.VMs[[string]$HardDisk.SimVMName]
    $typeName = switch ($Type) {
        'ParaVirtual'        { 'VMware.Vim.ParaVirtualSCSIController' }
        'VirtualLsiLogicSAS' { 'VMware.Vim.VirtualLsiLogicSASController' }
        default              { throw "Simulated New-ScsiController does not know type '$Type'." }
    }
    $sharedBus = switch ($BusSharingMode) {
        'Physical'  { 'physicalSharing' }
        'Virtual'   { 'virtualSharing' }
        'NoSharing' { 'noSharing' }
        default     { throw "Simulated New-ScsiController does not know bus sharing '$BusSharingMode'." }
    }

    # vCenter takes the lowest free bus, which is how a removed SCSI 1 comes back as 1.
    $usedBuses = @($vm.Devices | Where-Object { $_ -is [VMware.Vim.VirtualSCSIController] } | ForEach-Object { [int]$_.BusNumber })
    $bus = 0
    while ($usedBuses -contains $bus) { $bus++ }

    $global:Sim.NextDeviceKey++
    $controller = New-SimScsiController -TypeName $typeName -Key $global:Sim.NextDeviceKey -BusNumber $bus -SharedBus $sharedBus -Label "SCSI controller $bus"
    $vm.Devices.Add($controller)

    # PowerCLI moves the disk onto the controller it just made.
    $device = @($vm.Devices | Where-Object { $_.Key -eq $HardDisk.ExtensionData.Key })[0]
    $device.ControllerKey = $controller.Key
    $device.UnitNumber = 0
    Add-SimEvent "new-controller $($vm.Name) bus $bus $Type/$BusSharingMode, moved $($HardDisk.Name) onto it"

    return (Get-ScsiController -HardDisk (Get-HardDisk -VM $vm -Name $HardDisk.Name)[0])
}

function Get-ScsiController {
    [CmdletBinding()]
    param($VM, $HardDisk)

    if ($HardDisk) {
        $vm = $global:Sim.VMs[[string]$HardDisk.SimVMName]
        $controllers = @($vm.Devices | Where-Object { ($_ -is [VMware.Vim.VirtualSCSIController]) -and ([int]$_.Key -eq [int]$HardDisk.ExtensionData.ControllerKey) })
    }
    else {
        $vm = Resolve-SimVM -VM $VM
        $controllers = @($vm.Devices | Where-Object { $_ -is [VMware.Vim.VirtualSCSIController] })
    }

    return @($controllers | ForEach-Object {
        [pscustomobject]@{
            Name          = [string]$_.DeviceInfo.Label
            Type          = $_.GetType().Name
            SimKey        = [int]$_.Key
            SimVMName     = $vm.Name
            ExtensionData = $_
        }
    })
}

function Remove-HardDisk {
    [CmdletBinding(SupportsShouldProcess)]
    param($HardDisk, [switch]$DeletePermanently)

    if ($DeletePermanently) { throw 'Simulated estate refuses a permanent RDM deletion.' }
    $vm = $global:Sim.VMs[[string]$HardDisk.SimVMName]
    $device = @($vm.Devices | Where-Object { $_.Key -eq $HardDisk.ExtensionData.Key })[0]
    [void]$vm.Devices.Remove($device)
    Add-SimEvent "remove-disk $($vm.Name) $($HardDisk.Name)"
}

function Invoke-SimRelocate {
    # RelocateVM_Task: everything the spec asks for, and nothing it does not. A pod
    # reference in Spec.Datastore is what the real vCenter rejects, so it is rejected
    # here too - that failure is the reason this path exists at all.
    param([string]$VMName, $Spec)

    $vm = $global:Sim.VMs[$VMName]

    # The spec is validated first, exactly as vCenter does: a malformed one is refused
    # before the VM's own state is looked at.
    if ([string]$Spec.Datastore.Type -ne 'Datastore') {
        throw "A specified parameter was not correct: RelocateSpec"
    }
    $datastore = @($global:Sim.Datastores.Values | Where-Object { $_.Id -eq "Datastore-$($Spec.Datastore.Value)" })[0]
    if (-not $datastore) { throw "A specified parameter was not correct: RelocateSpec" }

    $pool = @($global:Sim.Pools.Values | Where-Object { $_.Id -eq [string]$Spec.Pool.Value })[0]
    if (-not $pool) { throw "A specified parameter was not correct: RelocateSpec" }

    if ($vm.PowerState -ne 'PoweredOff') { throw "Simulated cold relocate of '$($vm.Name)' while it is $($vm.PowerState)." }

    $rdms = @($vm.Devices | Where-Object { $_.Backing -is [VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo] })
    if ($rdms.Count -gt 0) { throw "Simulated cold relocate of '$($vm.Name)' with $($rdms.Count) RDM(s) still attached." }

    if ($Spec.Host) {
        $placedHost = @($global:Sim.Hosts.Values | Where-Object { $_.Id -eq [string]$Spec.Host.Value })[0]
        if (-not $placedHost) { throw "A specified parameter was not correct: RelocateSpec" }
    }
    else {
        # No host in the spec: DRS places it within the cluster that owns the pool.
        $placedHost = @(
            $global:Sim.Hosts.Values |
                Where-Object {
                    ($_.ClusterName -eq $pool.ClusterName) -and
                    ($_.ConnectionState -eq 'Connected') -and
                    ($_.PowerState -eq 'PoweredOn')
                } |
                Sort-Object Name
        )[0]
        if (-not $placedHost) { throw "Simulated DRS placement found no host in '$($pool.ClusterName)'." }
    }

    $vm.VMHostName = [string]$placedHost.Name
    $vm.ClusterName = [string]$pool.ClusterName
    $vm.ResourcePoolName = [string]$pool.Name
    $vm.DatastoreName = [string]$datastore.Name
    $vm.DatastoreClusterName = [string]$datastore.PodName
    Add-SimEvent "relocate $($vm.Name) -> $($vm.VMHostName)"

    $task = New-SimTask -Description "relocate $($vm.Name)"
    return ([pscustomobject]@{ Type = 'Task'; Value = $task.Value })
}

function Get-Task {
    [CmdletBinding()]
    param([string]$Id)
    if (-not $global:Sim.Tasks.ContainsKey($Id)) { throw "Simulated task '$Id' not found." }
    return $global:Sim.Tasks[$Id]
}

function Stop-VMGuest {
    [CmdletBinding(SupportsShouldProcess)]
    param($VM)
    $vm = Resolve-SimVM -VM $VM
    Add-SimEvent "guest-shutdown $($vm.Name)"
    if ($global:Sim.IgnoreGuestShutdown) { return }
    $vm.PowerState = 'PoweredOff'
}

function Stop-VM {
    [CmdletBinding(SupportsShouldProcess)]
    param($VM, [switch]$Kill)
    $vm = Resolve-SimVM -VM $VM
    $vm.PowerState = 'PoweredOff'
    Add-SimEvent "force-off $($vm.Name)"
}

function Start-VM {
    [CmdletBinding(SupportsShouldProcess)]
    param($VM)
    $vm = Resolve-SimVM -VM $VM
    $vm.PowerState = 'PoweredOn'
    Add-SimEvent "power-on $($vm.Name)"
}

function Read-Host {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Prompt)

    $answer = ''
    if ($global:Sim.PromptAnswers.Count -gt 0) {
        $answer = [string]$global:Sim.PromptAnswers[0]
        $global:Sim.PromptAnswers.RemoveAt(0)
    }
    Add-SimEvent "prompt '$answer'"
    return $answer
}

function Connect-VIServer {
    [CmdletBinding()]
    param([string]$Server, $Credential)
    return [pscustomobject]@{
        Name          = $Server
        User          = 'SIM\operator'
        ExtensionData = [pscustomobject]@{
            Content = [pscustomobject]@{ StorageResourceManager = 'StorageResourceManager-srm' }
        }
    }
}

function Disconnect-VIServer {
    [CmdletBinding(SupportsShouldProcess)]
    param($Server)
}

function Set-PowerCLIConfiguration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$InvalidCertificateAction,
        [string]$DefaultVIServerMode,
        [switch]$ParticipateInCeip,
        [string]$Scope
    )
}

function Import-Module {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$Name)
}

# ------------------------------------------------------------------------- the runs ----

function Get-SimDeviceSignature {
    param([string]$VMName)
    $vm = $global:Sim.VMs[$VMName]
    return (@(
        $vm.Devices |
            Sort-Object Key |
            ForEach-Object { "$($_.GetType().Name):$($_.Key):$($_.ControllerKey):$($_.UnitNumber)" }
    ) -join '|')
}

function Get-SimRdms {
    param([string]$VMName)
    $vm = $global:Sim.VMs[$VMName]
    $controllers = @{}
    foreach ($device in $vm.Devices) {
        if ($device -is [VMware.Vim.VirtualSCSIController]) { $controllers[[int]$device.Key] = $device }
    }
    return @(
        $vm.Devices |
            Where-Object { $_.Backing -is [VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo] } |
            ForEach-Object {
                [pscustomobject]@{
                    Bus               = [int]$controllers[[int]$_.ControllerKey].BusNumber
                    Unit              = [int]$_.UnitNumber
                    Naa               = ([string]$_.Backing.DeviceName -replace '^.*/', '')
                    MappingFile       = [string]$_.Backing.FileName
                    ControllerType    = $controllers[[int]$_.ControllerKey].GetType().Name
                    SharedBus         = [string]$controllers[[int]$_.ControllerKey].SharedBus
                    Sharing           = [string]$_.Sharing
                    CompatibilityMode = [string]$_.Backing.CompatibilityMode
                    DiskMode          = [string]$_.Backing.DiskMode
                }
            } |
            Sort-Object Bus, Unit
    )
}

try {
    New-Item -Path $script:WorkFolder -ItemType Directory -Force | Out-Null

    $csvPath = Join-Path $script:WorkFolder 'simulation.csv'
    @(
        'batch,destination_cluster,workload_type,first_vm,other_vms_space_separated,svm,iSCSI_Data_Store,group_1_lun_IDs_ordered_space_separated,group_2_lun_IDs_ordered_space_separated,group_3_lun_IDs_ordered_space_separated,destination_resource_pool,destination_datastore_cluster',
        '1,simsql02,SIT,SIMSQLA,SIMSQLB,sim-svm01,,40 41 42,,,SIM-SQL-RP,SIM-VM-DSC'
    ) | Set-Content -LiteralPath $csvPath -Encoding UTF8

    $credential = [pscredential]::new('sim', (ConvertTo-SecureString 'sim' -AsPlainText -Force))

    # ------------------------------------------------------------------- dry run ------
    Reset-SimInventory
    $beforeA = Get-SimDeviceSignature -VMName 'SIMSQLA'
    $beforeB = Get-SimDeviceSignature -VMName 'SIMSQLB'
    $dryRunFolder = Join-Path $script:WorkFolder 'dryrun'
    $dryRunLog = Join-Path $script:WorkFolder 'dryrun.log'

    try {
        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -DryRun -Credential $credential `
            -OutputFolder $dryRunFolder *> $dryRunLog
    }
    catch {
        $script:Failed++
        Write-Host '[FAIL] The dry run threw' -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }

    Invoke-SimTest 'Dry run changes no virtual hardware' {
        Assert-Equal (Get-SimDeviceSignature -VMName 'SIMSQLA') $beforeA 'SIMSQLA hardware changed during a dry run.'
        Assert-Equal (Get-SimDeviceSignature -VMName 'SIMSQLB') $beforeB 'SIMSQLB hardware changed during a dry run.'
        Assert-Equal $global:Sim.Events.Count 0 "A dry run performed $($global:Sim.Events.Count) operation(s): $($global:Sim.Events -join '; ')"
        Assert-Equal $global:Sim.VMs['SIMSQLA'].PowerState 'PoweredOn' 'A dry run powered a VM off.'
    }

    Invoke-SimTest 'Dry run writes a full change plan' {
        $plan = @(Import-Csv -LiteralPath (Get-ChildItem -Path $dryRunFolder -Filter 'change-plan-*.csv' | Select-Object -First 1).FullName)
        Assert-True ($plan.Count -ge 11) "The dry-run plan has only $($plan.Count) rows."
        Assert-Equal (@($plan | Where-Object { $_.Mode -ne 'DryRun' }).Count) 0 'A dry-run plan row is not marked DryRun.'
        Assert-Equal (@($plan | Where-Object { $_.Action -eq 'RemoveRdm' }).Count) 6 'Both nodes should give up three RDMs each.'
        # Mapping is now one planned change per LUN group, applied to the first node and
        # copied to the rest, so it is one row rather than one per disk per VM.
        Assert-Equal (@($plan | Where-Object { $_.Action -eq 'MapLunGroup' }).Count) 1 'The single LUN group should be one planned change.'
        Assert-Equal (@($plan | Where-Object { $_.Action -eq 'ColdRelocate' }).Count) 2 'Both nodes should be relocated.'
        Assert-Equal (@($plan | Where-Object { $_.Action -eq 'RemoveController' }).Count) 2 'Only SCSI 1 should be removed, on each node.'
        Assert-Equal (@($plan | Where-Object { $_.WorkloadType -ne 'SIT' }).Count) 0 'A plan row is missing its workload type.'
    }

    Invoke-SimTest 'A clean dry run ends on a verdict and the command that follows it' {
        $log = Get-Content -LiteralPath $dryRunLog -Raw
        Assert-True ($log -match 'DRY RUN COMPLETE') 'The dry run did not announce that it completed.'
        Assert-True ($log -match 'DRY RUN COMPLETED SUCCESSFULLY - nothing flagged\. Ready to execute\.') 'A clean dry run did not give a verdict.'
        Assert-True ($log -match 'Nothing was changed\.') 'The dry run did not say that nothing was changed.'
        Assert-True ($log -match 'none could be: a dry run maps no LUNs') 'The dry run did not explain why nothing was powered on.'
        Assert-True ($log -match 'expected, not a failure') 'The dry run did not say the absent power-on is expected.'
        Assert-True ($log -match [regex]::Escape('-CsvPath')) 'The follow-on -Execute command was not printed.'
        Assert-True ($log -match '-Execute') 'The follow-on command does not say -Execute.'
        Assert-True ($log -notmatch '\[ERROR\]') 'A clean dry run logged an error.'
        Assert-True ($log -notmatch '\[WARN \]') 'A clean dry run raised a warning.'
    }

    # ------------------------------------- dry run against a VM with no VMware Tools --
    Reset-SimInventory
    $global:Sim.VMs['SIMSQLB'].ToolsRunningStatus = 'guestToolsNotRunning'
    $noticeFolder = Join-Path $script:WorkFolder 'notice'
    $noticeLog = Join-Path $script:WorkFolder 'notice.log'
    $noticeThrew = $false

    try {
        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -DryRun -Credential $credential `
            -OutputFolder $noticeFolder *> $noticeLog
    }
    catch {
        $noticeThrew = $true
    }

    Invoke-SimTest 'A VM with no VMware Tools is flagged in the dry run, not refused' {
        Assert-True (-not $noticeThrew) 'The dry run threw over a VM with no VMware Tools.'
        $log = Get-Content -LiteralPath $noticeLog -Raw
        Assert-True ($log -match 'NOTE FOR THE LIVE RUN') 'The hard power-off was not called out where it was found.'
        Assert-True ($log -match "VM 'SIMSQLB' is powered on but VMware Tools is not running") 'The notice did not name the VM.'
        Assert-True ($log -match 'powered off hard') 'The notice did not say what will happen to it.'
        Assert-True ($log -match 'DRY RUN COMPLETED SUCCESSFULLY - 1 thing\(s\) flagged') 'The verdict did not carry the flagged item.'
        Assert-True ($log -notmatch '\[ERROR\]') 'A flagged item was reported as a failure of the run.'
        Assert-Equal $global:Sim.Events.Count 0 'A dry run that flagged something still changed something.'

        $results = @(Import-Csv -LiteralPath (Get-ChildItem -Path $noticeFolder -Filter 'results-*.csv' | Select-Object -First 1).FullName)
        Assert-Equal (@($results | Where-Object { $_.Status -eq 'Noticed' }).Count) 1 'The notice was not recorded in the results.'
        Assert-Equal (@($results | Where-Object { $_.Phase -eq 'Fatal' }).Count) 0 'The dry run recorded a fatal row.'
    }

    # ------------------------------------------------------------------- execution ----
    Reset-SimInventory
    $global:Sim.PromptAnswers.Add('y')
    $executeFolder = Join-Path $script:WorkFolder 'execute'
    $executeLog = Join-Path $script:WorkFolder 'execute.log'

    try {
        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -Execute -Credential $credential `
            -OutputFolder $executeFolder *> $executeLog
    }
    catch {
        # Recorded rather than rethrown: the assertions below then report what state the
        # simulated estate was left in, which is the useful part of a failed run.
        $script:Failed++
        Write-Host '[FAIL] The execution run threw' -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "       $($_.ScriptStackTrace)" -ForegroundColor DarkYellow
    }

    Invoke-SimTest 'Both nodes end up on the one destination host that can see the LUNs' {
        foreach ($name in @('SIMSQLA', 'SIMSQLB')) {
            Assert-Equal $global:Sim.VMs[$name].VMHostName 'sim-esx02' "$name is on the wrong host."
            Assert-Equal $global:Sim.VMs[$name].ClusterName 'simsql02' "$name is in the wrong cluster."
            Assert-Equal $global:Sim.VMs[$name].ResourcePoolName 'SIM-SQL-RP' "$name is in the wrong resource pool."
            Assert-Equal $global:Sim.VMs[$name].DatastoreClusterName 'SIM-VM-DSC' "$name is on the wrong datastore cluster."
        }
    }

    Invoke-SimTest 'Placement is asked for, and the spec carries a datastore not a pod' {
        # SHIPPED AND HIT ON A LIVE RUN: the relocate used to hand vCenter a StoragePod
        # in RelocateSpec.datastore, which only accepts a Datastore, and the whole spec
        # was rejected with "A specified parameter was not correct: RelocateSpec".
        $events = @($global:Sim.Events)
        Assert-True ($events -contains 'recommend-datastores') 'Storage DRS was never asked where the VMs should land.'
        Assert-True ($events -contains 'recommend-hosts simsql02') 'DRS was never asked which host should run them.'
        $log = Get-Content -LiteralPath $executeLog -Raw
        Assert-True ($log -match "DRS chose host 'sim-esx02'") 'The host DRS recommended was not used.'

        foreach ($name in @('SIMSQLA', 'SIMSQLB')) {
            # sim-ds-02 is the emptiest datastore in the pod, which is what this
            # simulation's Storage DRS recommends.
            Assert-Equal $global:Sim.VMs[$name].DatastoreName 'sim-ds-02' "$name did not land on the datastore Storage DRS chose."
        }
    }

    Invoke-SimTest 'A pod reference in the relocate spec is rejected, as vCenter rejects it' {
        # The harness reproduces the live failure, so a regression here fails a test
        # rather than an outage window.
        $podSpec = New-Object VMware.Vim.VirtualMachineRelocateSpec
        $podSpec.Pool = (Get-View -Id $global:Sim.Pools['SIM-SQL-RP'].Id).MoRef
        $podSpec.Datastore = (Get-View -Id $global:Sim.DatastoreClusters['SIM-VM-DSC'].Id).MoRef

        $message = ''
        try { Invoke-SimRelocate -VMName 'SIMSQLA' -Spec $podSpec }
        catch { $message = $_.Exception.Message }
        Assert-True ($message -match 'A specified parameter was not correct: RelocateSpec') "A datastore cluster was accepted in the relocate spec. Got: $message"
    }

    Invoke-SimTest 'Every RDM is back at the SCSI address it came from' {
        foreach ($name in @('SIMSQLA', 'SIMSQLB')) {
            $rdms = @(Get-SimRdms -VMName $name)
            Assert-Equal $rdms.Count 3 "$name has the wrong number of RDMs."
            Assert-Equal (@($rdms | ForEach-Object { "$($_.Bus):$($_.Unit)" }) -join ',') '1:0,1:1,1:2' "$name RDMs are at the wrong SCSI addresses."
            Assert-Equal (@($rdms | ForEach-Object { $_.Naa }) -join ',') 'naa.6000000000000040,naa.6000000000000041,naa.6000000000000042' "$name has the wrong devices, or in the wrong order."
        }
    }

    Invoke-SimTest 'Every device setting comes back exactly as the source had it' {
        foreach ($name in @('SIMSQLA', 'SIMSQLB')) {
            $rdms = @(Get-SimRdms -VMName $name)
            Assert-Equal (@($rdms | ForEach-Object { $_.ControllerType } | Select-Object -Unique) -join ',') 'VirtualLsiLogicSASController' "$name came back on the wrong controller type."

            # The source has no bus sharing and no disk sharing. The tool must reproduce
            # that, not impose the arrangement it expects to see.
            Assert-Equal (@($rdms | ForEach-Object { $_.SharedBus } | Select-Object -Unique) -join ',') 'noSharing' "$name came back with the wrong bus sharing."
            Assert-Equal (@($rdms | ForEach-Object { $_.Sharing } | Select-Object -Unique) -join ',') 'sharingNone' "$name came back with the wrong disk sharing."
            Assert-Equal (@($rdms | ForEach-Object { $_.CompatibilityMode } | Select-Object -Unique) -join ',') 'physicalMode' "$name came back with the wrong compatibility mode."
        }
    }

    Invoke-SimTest 'SCSI 0 and its VMDK are untouched, and the stray SCSI 2 survives' {
        foreach ($name in @('SIMSQLA', 'SIMSQLB')) {
            $vm = $global:Sim.VMs[$name]
            $buses = @($vm.Devices | Where-Object { $_ -is [VMware.Vim.VirtualSCSIController] } | ForEach-Object { [int]$_.BusNumber } | Sort-Object)
            Assert-Equal ($buses -join ',') '0,1,2' "$name has the wrong set of SCSI controllers."

            $bootController = @($vm.Devices | Where-Object { ($_ -is [VMware.Vim.VirtualSCSIController]) -and ([int]$_.BusNumber -eq 0) })[0]
            $osDisks = @($vm.Devices | Where-Object { ($_ -is [VMware.Vim.VirtualDisk]) -and ([int]$_.ControllerKey -eq [int]$bootController.Key) })
            Assert-Equal $osDisks.Count 1 "$name lost its operating system disk."
            Assert-Equal ([string]$osDisks[0].DeviceInfo.Label) 'Hard disk 1' "$name boot disk was renamed."

            $cdroms = @($vm.Devices | Where-Object { $_ -is [VMware.Vim.VirtualCdrom] })
            Assert-Equal $cdroms.Count 1 "$name lost its CD-ROM."
        }
    }

    Invoke-SimTest 'The first node owns the mapping files and the rest attach the same ones' {
        # Only the first VM creates disks; the others receive a copy spec.
        $created = @($global:Sim.Events | Where-Object { $_ -like 'new-harddisk *' })
        Assert-Equal $created.Count 3 'Three disks should be created, all on the first node.'
        Assert-Equal (@($created | Where-Object { $_ -notlike 'new-harddisk SIMSQLA *' }).Count) 0 'A disk was created on a node other than the first.'

        $mappingA = @(Get-SimRdms -VMName 'SIMSQLA' | ForEach-Object { $_.MappingFile })
        $mappingB = @(Get-SimRdms -VMName 'SIMSQLB' | ForEach-Object { $_.MappingFile })
        Assert-Equal ($mappingB -join ',') ($mappingA -join ',') 'The nodes are not sharing one mapping file per LUN.'
    }

    Invoke-SimTest 'Nothing moves until every node has given up its disks' {
        $events = @($global:Sim.Events)
        $lastRemoval = -1
        $firstRelocate = -1
        for ($index = 0; $index -lt $events.Count; $index++) {
            if ($events[$index] -like 'remove-disk *') { $lastRemoval = $index }
            if (($events[$index] -like 'relocate *') -and ($firstRelocate -lt 0)) { $firstRelocate = $index }
        }
        Assert-True ($lastRemoval -ge 0) 'No RDM was ever removed.'
        Assert-True ($firstRelocate -gt $lastRemoval) 'A VM was relocated before every node had given up its RDMs.'
    }

    Invoke-SimTest 'The mapping is printed before the operator is asked' {
        $log = Get-Content -LiteralPath $executeLog -Raw
        Assert-True ($log -match '===== Mapped LUNs for') 'The mapping summary was not printed.'
        Assert-True ($log -match 'SCSI 1\s+VirtualLsiLogicSASController, bus sharing noSharing') 'The summary does not name the controller and its sharing.'
        foreach ($naa in @('naa.6000000000000040', 'naa.6000000000000041', 'naa.6000000000000042')) {
            Assert-True ($log -match [regex]::Escape($naa)) "The summary does not list device $naa."
        }

        $events = @($global:Sim.Events)
        $promptIndex = [array]::FindIndex($events, [Predicate[string]] { param($e) $e -like 'prompt *' })
        $firstPowerOn = [array]::FindIndex($events, [Predicate[string]] { param($e) $e -like 'power-on *' })
        Assert-True ($promptIndex -ge 0) 'The operator was never asked.'
        Assert-True (($firstPowerOn -lt 0) -or ($firstPowerOn -gt $promptIndex)) 'A VM was powered on before the operator was asked.'
    }

    Invoke-SimTest 'Power-on happens last, in CSV order' {
        $powerOns = @($global:Sim.Events | Where-Object { $_ -like 'power-on *' })
        Assert-Equal ($powerOns -join ',') 'power-on SIMSQLA,power-on SIMSQLB' 'The nodes were powered on in the wrong order.'

        $events = @($global:Sim.Events)
        $firstPowerOn = [array]::IndexOf($events, $powerOns[0])
        $lastAttach = -1
        for ($index = 0; $index -lt $events.Count; $index++) {
            if (($events[$index] -like 'create-mapping *') -or ($events[$index] -like 'attach-mapping *')) { $lastAttach = $index }
        }
        Assert-True ($firstPowerOn -gt $lastAttach) 'A VM was powered on before every LUN was mapped back.'
    }

    Invoke-SimTest 'The run reports success for every step it took' {
        $results = @(Import-Csv -LiteralPath (Get-ChildItem -Path $executeFolder -Filter 'results-*.csv' | Select-Object -First 1).FullName)
        Assert-Equal (@($results | Where-Object { $_.Status -eq 'Failed' }).Count) 0 'A step failed during the simulated migration.'
        Assert-True ((@($results | Where-Object { $_.Status -eq 'Succeeded' }).Count) -ge 14) 'Too few steps were recorded as succeeded.'
        Assert-Equal (@($results | Where-Object { ($_.Phase -eq 'RemoveController') -and ($_.Status -eq 'Skipped') }).Count) 2 'The stray SCSI 2 controller should be recorded as kept on each node.'
    }

    Invoke-SimTest 'Verification confirms every disk placement' {
        $verification = @(Import-Csv -LiteralPath (Get-ChildItem -Path $executeFolder -Filter 'verification-*.csv' | Select-Object -First 1).FullName)
        Assert-Equal $verification.Count 6 'Verification should cover three disks on each of two nodes.'
        Assert-Equal (@($verification | Where-Object { $_.Status -ne 'Passed' }).Count) 0 'A disk placement did not verify.'
        Assert-Equal (@($verification | Where-Object { $_.WorkloadType -ne 'SIT' }).Count) 0 'A verification row is missing its workload type.'
    }

    Invoke-SimTest 'The destination is the cluster, and no host is interrogated' {
        $manifest = Get-Content -LiteralPath (Get-ChildItem -Path $executeFolder -Filter '*-execution-manifest-*.json' | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
        Assert-Equal $manifest.RdmDatastore 'simsql02sit_i_rdm' 'The RDM datastore was not derived from the cluster and workload type.'
        Assert-True ([bool]$manifest.RdmDatastoreDerived) 'The manifest does not record that the datastore name was derived.'
        Assert-True ($manifest.DestinationPlacement -like '*placed by DRS*') "Placement was not left to DRS: $($manifest.DestinationPlacement)"

        # The 25 seconds this used to cost on a 42-host cluster was one question asked of
        # every host, to conclude what a working cluster always concludes.
        $log = Get-Content -LiteralPath $executeLog -Raw
        Assert-True ($log -notmatch 'mount tables of') 'The datastore mount tables are still being read.'
        Assert-True ($log -notmatch 'host\(s\) can take these VMs') 'Host eligibility is still being computed.'
        Assert-True ($log -match "Destination is cluster 'simsql02': DRS places each VM") 'The run does not say where it is placing the VMs.'
        Assert-True ($log -match 'Storage DRS places its files') 'The run does not say who places the files.'
    }

    Invoke-SimTest 'The presentation prerequisite is stated by LUN group, and never checked' {
        $manifest = Get-Content -LiteralPath (Get-ChildItem -Path $executeFolder -Filter '*-execution-manifest-*.json' | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
        $prerequisite = @($manifest.PresentationPrerequisite)
        Assert-Equal $prerequisite.Count 2 'The prerequisite should be a heading plus one line per LUN group.'
        Assert-True ($prerequisite[0] -like "*sim-svm01*cluster 'simsql02'*") 'The prerequisite does not name the SVM and the destination cluster.'
        Assert-True ($prerequisite[1] -like '*40, 41, 42*') 'The prerequisite does not name the LUN IDs.'

        $log = Get-Content -LiteralPath $executeLog -Raw
        Assert-True ($log -match 'PREREQUISITE, assumed and not checked') 'The prerequisite was not printed for the engineer.'
    }

    # ------------------------------------------- an unpresented device, caught early ----
    Reset-SimInventory
    $global:Sim.HostPaths['sim-esx02'] = @($global:Sim.HostPaths['sim-esx02'] | Where-Object { [int]$_.LUN -ne 41 })
    $global:Sim.HostLuns['sim-esx02'] = @($global:Sim.HostLuns['sim-esx02'] | Where-Object { $_.CanonicalName -ne 'naa.6000000000000041' })
    $missingFolder = Join-Path $script:WorkFolder 'missing'
    $missingLog = Join-Path $script:WorkFolder 'missing.log'
    $missingError = ''
    try {
        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -Execute -Credential $credential `
            -OutputFolder $missingFolder *> $missingLog
    }
    catch {
        $missingError = $_.Exception.Message
    }

    Invoke-SimTest 'A LUN the host has no path to is named, at the point it is mapped' {
        Assert-True ($missingError -like '*no path to SVM*LUN 41*') "The run did not name the unreachable LUN. It said: $missingError"
    }

    # ------------------------------------- PROD, SIT and DEV on one shared cluster ----
    Reset-SimInventory
    $workloadCsv = Join-Path $script:WorkFolder 'workloads.csv'
    @(
        'batch,destination_cluster,workload_type,first_vm,other_vms_space_separated,svm,iSCSI_Data_Store,group_1_lun_IDs_ordered_space_separated,group_2_lun_IDs_ordered_space_separated,group_3_lun_IDs_ordered_space_separated,destination_resource_pool,destination_datastore_cluster',
        '2,simsql02,PROD,SIMSQLPRD,,sim-svm01,,43,,,SIM-SQL-RP,SIM-VM-DSC',
        '1,simsql02,SIT,SIMSQLA,SIMSQLB,sim-svm01,,40 41 42,,,SIM-SQL-RP,SIM-VM-DSC',
        '1,simsql02,DEV,SIMSQLDEV,,sim-svm01,,44,,,SIM-SQL-RP,SIM-VM-DSC'
    ) | Set-Content -LiteralPath $workloadCsv -Encoding UTF8

    $workloadFolder = Join-Path $script:WorkFolder 'workloads'
    $workloadLog = Join-Path $script:WorkFolder 'workloads.log'
    try {
        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $workloadCsv -DryRun -Credential $credential `
            -OutputFolder $workloadFolder *> $workloadLog
    }
    catch {
        $script:Failed++
        Write-Host '[FAIL] The PROD/SIT/DEV dry run threw' -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }

    Invoke-SimTest 'One shared cluster, three workload types, three mapping directories' {
        $manifests = @(
            Get-ChildItem -Path $workloadFolder -Filter '*-dryrun-manifest-*.json' |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }
        )
        Assert-Equal $manifests.Count 3 'A manifest should be written for each of the three groups.'

        $expected = @{
            'SIMSQLPRD' = @{ Workload = 'PROD'; Datastore = 'simsql02_i_rdm' }
            'SIMSQLA'   = @{ Workload = 'SIT';  Datastore = 'simsql02sit_i_rdm' }
            'SIMSQLDEV' = @{ Workload = 'DEV';  Datastore = 'simsql02dev_i_rdm' }
        }
        foreach ($manifest in $manifests) {
            $want = $expected[[string]$manifest.MigrationGroup]
            Assert-True ($null -ne $want) "Unexpected migration group '$($manifest.MigrationGroup)'."
            Assert-Equal $manifest.WorkloadType $want.Workload "Wrong workload type for $($manifest.MigrationGroup)."
            Assert-Equal $manifest.DestinationCluster 'simsql02' "All three groups target the one shared cluster."
            Assert-Equal $manifest.RdmDatastore $want.Datastore "$($manifest.MigrationGroup) derived the wrong mapping directory."
            Assert-True ([bool]$manifest.RdmDatastoreDerived) "$($manifest.MigrationGroup) did not derive its datastore name."
        }
    }

    Invoke-SimTest 'The three groups run in batch order, and change nothing on a dry run' {
        $log = Get-Content -LiteralPath $workloadLog -Raw
        $order = @([regex]::Matches($log, 'Resolving batch (\d+) (\w+) migration group') | ForEach-Object { "$($_.Groups[1].Value)$($_.Groups[2].Value)" })
        Assert-Equal ($order -join ',') '1SIT,1DEV,2PROD' "Groups were resolved in the wrong order: $($order -join ',')"
        Assert-Equal $global:Sim.Events.Count 0 "The dry run changed $($global:Sim.Events.Count) thing(s)."
    }

    # ------------------------------------------- answering no, and hashed-out rows ----
    Reset-SimInventory
    $global:Sim.PromptAnswers.Add('n')
    $declineFolder = Join-Path $script:WorkFolder 'decline'
    $declineLog = Join-Path $script:WorkFolder 'decline.log'
    try {
        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -Execute -Credential $credential `
            -OutputFolder $declineFolder *> $declineLog
    }
    catch {
        $script:Failed++
        Write-Host '[FAIL] The declined-power-on run threw' -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }

    Invoke-SimTest 'Answering no leaves the VMs migrated, mapped and off' {
        Assert-Equal (@($global:Sim.Events | Where-Object { $_ -like 'power-on *' }).Count) 0 'A VM was powered on after the operator declined.'
        foreach ($name in @('SIMSQLA', 'SIMSQLB')) {
            Assert-Equal $global:Sim.VMs[$name].PowerState 'PoweredOff' "$name should still be off."
            Assert-Equal $global:Sim.VMs[$name].VMHostName 'sim-esx02' "$name should still have been migrated."
            Assert-Equal (@(Get-SimRdms -VMName $name)).Count 3 "$name should still have its RDMs mapped."
        }
        $results = @(Import-Csv -LiteralPath (Get-ChildItem -Path $declineFolder -Filter 'results-*.csv' | Select-Object -First 1).FullName)
        Assert-Equal (@($results | Where-Object { ($_.Phase -eq 'PowerOn') -and ($_.Status -eq 'Skipped') }).Count) 1 'The declined power-on was not recorded.'
    }

    Invoke-SimTest 'A cluster without DRS stops the run during planning' {
        Reset-SimInventory
        $global:Sim.Clusters['simsql02'].DrsEnabled = $false
        $drsFolder = Join-Path $script:WorkFolder 'nodrs'
        $drsLog = Join-Path $script:WorkFolder 'nodrs.log'
        $drsError = ''
        try {
            & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -Execute -Credential $credential `
                -OutputFolder $drsFolder *> $drsLog
        }
        catch {
            $drsError = $_.Exception.Message
        }

        Assert-True ($drsError -like '*DRS is disabled on destination cluster*') "The run did not name the DRS problem. It said: $drsError"
        Assert-Equal $global:Sim.Events.Count 0 'The run changed something before finding DRS was off.'
        Assert-Equal $global:Sim.VMs['SIMSQLA'].PowerState 'PoweredOn' 'A VM was powered off before planning failed.'
    }

    Invoke-SimTest 'A row commented out with # is skipped entirely' {
        $hashedCsv = Join-Path $script:WorkFolder 'hashed.csv'
        @(
            'batch,destination_cluster,workload_type,first_vm,other_vms_space_separated,svm,iSCSI_Data_Store,group_1_lun_IDs_ordered_space_separated,group_2_lun_IDs_ordered_space_separated,group_3_lun_IDs_ordered_space_separated,destination_resource_pool,destination_datastore_cluster',
            '#2,simsql02,PROD,SIMSQLPRD,,sim-svm01,,43,,,SIM-SQL-RP,SIM-VM-DSC',
            '1,simsql02,SIT,SIMSQLA,SIMSQLB,sim-svm01,,40 41 42,,,SIM-SQL-RP,SIM-VM-DSC',
            '# this row is nonsense and must never be validated,,,,,,,,,,,'
        ) | Set-Content -LiteralPath $hashedCsv -Encoding UTF8

        Reset-SimInventory
        $hashedFolder = Join-Path $script:WorkFolder 'hashed'
        $hashedLog = Join-Path $script:WorkFolder 'hashed.log'
        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $hashedCsv -DryRun -Credential $credential `
            -OutputFolder $hashedFolder *> $hashedLog

        $log = Get-Content -LiteralPath $hashedLog -Raw
        Assert-True ($log -match '2 of 3 CSV row\(s\) are commented out') 'The commented rows were not reported.'
        Assert-True ($log -match "Resolving batch 1 SIT migration group 'SIMSQLA'") 'The live row did not run.'
        Assert-True ($log -notmatch 'SIMSQLPRD') 'A commented-out row was processed.'
    }

    # ------------------------------------------------ power-down policy, live run -----
    Invoke-SimTest 'A guest that ignores the request is powered off hard, then migrated' {
        Reset-SimInventory
        $global:Sim.IgnoreGuestShutdown = $true
        $global:Sim.PromptAnswers.Add('y')
        $stubbornFolder = Join-Path $script:WorkFolder 'stubborn'
        $stubbornLog = Join-Path $script:WorkFolder 'stubborn.log'

        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -Execute -Credential $credential `
            -GuestShutdownTimeoutSeconds 1 -OutputFolder $stubbornFolder *> $stubbornLog

        $log = Get-Content -LiteralPath $stubbornLog -Raw
        Assert-True ($log -match 'did not shut down within 1 seconds\. Powering it off hard\.') 'The guest was never given up on.'

        # Asked first, killed second, on both nodes - and only after being asked.
        $events = @($global:Sim.Events)
        foreach ($node in @('SIMSQLA', 'SIMSQLB')) {
            $askIndex = $events.IndexOf("guest-shutdown $node")
            $killIndex = $events.IndexOf("force-off $node")
            Assert-True ($askIndex -ge 0) "$node was never asked to shut down."
            Assert-True ($killIndex -gt $askIndex) "$node was killed without being asked first."
        }

        Assert-Equal $global:Sim.VMs['SIMSQLA'].ClusterName 'simsql02' 'SIMSQLA did not reach the destination.'
        Assert-Equal (Get-SimRdms -VMName 'SIMSQLA').Count 3 'SIMSQLA did not get its RDMs back.'
        Assert-Equal $global:Sim.VMs['SIMSQLA'].PowerState 'PoweredOn' 'SIMSQLA was not powered back on.'
    }

    Invoke-SimTest 'A VM with no VMware Tools is powered off hard without being asked' {
        Reset-SimInventory
        $global:Sim.VMs['SIMSQLB'].ToolsRunningStatus = 'guestToolsNotRunning'
        $global:Sim.PromptAnswers.Add('y')
        $noToolsFolder = Join-Path $script:WorkFolder 'notools'
        $noToolsLog = Join-Path $script:WorkFolder 'notools.log'

        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -Execute -Credential $credential `
            -OutputFolder $noToolsFolder *> $noToolsLog

        $events = @($global:Sim.Events)
        Assert-True ($events -contains 'force-off SIMSQLB') 'SIMSQLB was not powered off hard.'
        Assert-True (-not ($events -contains 'guest-shutdown SIMSQLB')) 'SIMSQLB was asked to shut down through Tools it does not have.'
        Assert-True ($events -contains 'guest-shutdown SIMSQLA') 'SIMSQLA was not asked politely.'
        Assert-True (-not ($events -contains 'force-off SIMSQLA')) 'SIMSQLA was killed despite shutting down cleanly.'

        Assert-Equal (Get-SimRdms -VMName 'SIMSQLB').Count 3 'SIMSQLB did not get its RDMs back.'
        Assert-Equal $global:Sim.VMs['SIMSQLB'].PowerState 'PoweredOn' 'SIMSQLB was not powered back on.'
    }

    Write-Host ''
    Write-Host 'Simulation summary' -ForegroundColor Cyan
    Write-Host "  Passed: $script:Passed"
    Write-Host "  Failed: $script:Failed"
    Write-Host "  Logs:   $script:WorkFolder"

    $script:Completed = $true
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    # Keep the evidence when anything went wrong, including a run that threw.
    if ($script:Completed -and ($script:Failed -eq 0)) {
        Remove-Item -LiteralPath $script:WorkFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
