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
    public class VirtualDisk : VirtualDevice { public long CapacityInKB; public long CapacityInBytes; }
    public class VirtualCdrom : VirtualDevice { }
    public class VirtualDeviceConfigSpec {
        public string Operation;
        public string FileOperation;
        public VirtualDevice Device;
    }
    public class VirtualMachineConfigSpec { public VirtualDeviceConfigSpec[] DeviceChange; }
    public class ManagedObjectReference { public string Type; public string Value; }
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

    # SCSI 1: LSI Logic SAS with physical bus sharing, carrying the cluster's RDMs. The
    # mapping files belong to the first node and are attached by the rest.
    $sharedController = New-SimScsiController -TypeName 'VMware.Vim.VirtualLsiLogicSASController' -Key (1001 + $Index * 10) -BusNumber 1 -SharedBus 'physicalSharing' -Label 'SCSI controller 1'
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
    $global:Sim.NextDeviceKey = 5000
    $global:Sim.NextTask = 0
    $global:Sim.Events = [System.Collections.Generic.List[string]]::new()

    $naas = @('naa.6000000000000040', 'naa.6000000000000041', 'naa.6000000000000042')
    $global:Sim.VMs['SIMSQLA'] = New-SimVM -Name 'SIMSQLA' -Index 1 -Naas $naas -MappingOwner 'SIMSQLA'
    $global:Sim.VMs['SIMSQLB'] = New-SimVM -Name 'SIMSQLB' -Index 2 -Naas $naas -MappingOwner 'SIMSQLA'

    $global:Sim.Clusters = [ordered]@{
        'simsql01' = [pscustomobject]@{ Name = 'simsql01'; Id = 'ClusterComputeResource-domain-c1' }
        'simsql02' = [pscustomobject]@{ Name = 'simsql02'; Id = 'ClusterComputeResource-domain-c2' }
    }
    $global:Sim.Pools = [ordered]@{
        'SIM-SQL-RP' = [pscustomobject]@{ Name = 'SIM-SQL-RP'; Id = 'ResourcePool-resgroup-1'; ClusterName = 'simsql02' }
    }
    $global:Sim.DatastoreClusters = [ordered]@{
        'SIM-VM-DSC' = [pscustomobject]@{ Name = 'SIM-VM-DSC'; Id = 'StoragePod-group-p1' }
    }
    $global:Sim.Datastores = [ordered]@{
        'sim-ds-01'          = [pscustomobject]@{ Name = 'sim-ds-01'; Id = 'Datastore-datastore-1'; PodName = 'SIM-VM-DSC' }
        'simsql02sit_i_rdm'  = [pscustomobject]@{ Name = 'simsql02sit_i_rdm'; Id = 'Datastore-datastore-2'; PodName = '' }
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
        'sim-esx01' = @('sim-ds-01', 'simsql02sit_i_rdm')
        'sim-esx02' = @('sim-ds-01', 'simsql02sit_i_rdm')
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

function Invoke-SimReconfigure {
    param([string]$VMName, $Spec)

    $vm = $global:Sim.VMs[$VMName]
    foreach ($change in @($Spec.DeviceChange)) {
        $device = $change.Device
        switch ($change.Operation) {
            'add' {
                $global:Sim.NextDeviceKey++
                $device.Key = $global:Sim.NextDeviceKey

                if ($device -is [VMware.Vim.VirtualDisk]) {
                    $diskCount = @($vm.Devices | Where-Object { $_ -is [VMware.Vim.VirtualDisk] }).Count
                    $device.DeviceInfo = New-SimDescription -Label "Hard disk $($diskCount + 1)"

                    # An RDM is added with no capacity in the spec; vCenter fills it in
                    # from the LUN. The simulation has to do the same or the script's own
                    # verification has nothing to check against.
                    if ($device.Backing -is [VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo]) {
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

function Get-View {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Id, $Property)

    $identifier = [string]$Id

    if ($identifier -like 'ResourcePool-*') {
        $view = [pscustomobject]@{ Name = 'pool'; Id = $identifier }
        Add-Member -InputObject $view -MemberType ScriptMethod -Name MoveIntoResourcePool -Value {
            param($MoRefs)
            foreach ($moRef in @($MoRefs)) {
                $vm = Resolve-SimVM -VM ([string]$moRef.Value)
                $pool = @($global:Sim.Pools.Values | Where-Object { $_.Id -eq $this.Id })[0]
                $vm.ResourcePoolName = $pool.Name
                Add-SimEvent "move-pool $($vm.Name) -> $($pool.Name)"
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
    param([string]$Name, $Location, $VMHost)

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
    param($VMHost, [string]$LunType)
    return @($global:Sim.HostLuns[[string]$VMHost.Name])
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
                    Name          = [string]$_.DeviceInfo.Label
                    SimVMName     = $vm.Name
                    ExtensionData = $_
                }
            }
    )
    if ($Name) { $disks = @($disks | Where-Object { $_.Name -eq $Name }) }
    return $disks
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

function Move-VM {
    [CmdletBinding(SupportsShouldProcess)]
    param($VM, $Destination, $Datastore, [switch]$RunAsync)

    $vm = Resolve-SimVM -VM $VM
    if ($vm.PowerState -ne 'PoweredOff') { throw "Simulated cold relocate of '$($vm.Name)' while it is $($vm.PowerState)." }

    $rdms = @($vm.Devices | Where-Object { $_.Backing -is [VMware.Vim.VirtualDiskRawDiskMappingVer1BackingInfo] })
    if ($rdms.Count -gt 0) { throw "Simulated cold relocate of '$($vm.Name)' with $($rdms.Count) RDM(s) still attached." }

    $vm.VMHostName = [string]$Destination.Name
    $vm.ClusterName = [string]$global:Sim.Hosts[[string]$Destination.Name].ClusterName
    $vm.DatastoreClusterName = [string]$Datastore.Name
    Add-SimEvent "relocate $($vm.Name) -> $($vm.VMHostName)"

    return (New-SimTask -Description "relocate $($vm.Name)")
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
    $vm.PowerState = 'PoweredOff'
    Add-SimEvent "guest-shutdown $($vm.Name)"
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

function Connect-VIServer {
    [CmdletBinding()]
    param([string]$Server, $Credential)
    return [pscustomobject]@{ Name = $Server; User = 'SIM\operator' }
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
                    Bus            = [int]$controllers[[int]$_.ControllerKey].BusNumber
                    Unit           = [int]$_.UnitNumber
                    Naa            = ([string]$_.Backing.DeviceName -replace '^.*/', '')
                    MappingFile    = [string]$_.Backing.FileName
                    ControllerType = $controllers[[int]$_.ControllerKey].GetType().Name
                    SharedBus      = [string]$controllers[[int]$_.ControllerKey].SharedBus
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
            -PowerAction ShutdownGuest -PowerOnAfterMigration -OutputFolder $dryRunFolder *> $dryRunLog
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
        Assert-True ($plan.Count -ge 14) "The dry-run plan has only $($plan.Count) rows."
        Assert-Equal (@($plan | Where-Object { $_.Mode -ne 'DryRun' }).Count) 0 'A dry-run plan row is not marked DryRun.'
        Assert-Equal (@($plan | Where-Object { $_.Action -eq 'RemoveRdm' }).Count) 6 'Both nodes should give up three RDMs each.'
        Assert-Equal (@($plan | Where-Object { $_.Action -eq 'AddRdm' }).Count) 6 'Both nodes should get three RDMs back.'
        Assert-Equal (@($plan | Where-Object { $_.Action -eq 'RemoveController' }).Count) 2 'Only SCSI 1 should be removed, on each node.'
        Assert-Equal (@($plan | Where-Object { $_.WorkloadType -ne 'SIT' }).Count) 0 'A plan row is missing its workload type.'
    }

    # ------------------------------------------------------------------- execution ----
    Reset-SimInventory
    $executeFolder = Join-Path $script:WorkFolder 'execute'
    $executeLog = Join-Path $script:WorkFolder 'execute.log'

    try {
        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -Execute -Credential $credential `
            -PowerAction ShutdownGuest -PowerOnAfterMigration -OutputFolder $executeFolder *> $executeLog
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

    Invoke-SimTest 'Every RDM is back at the SCSI address it came from' {
        foreach ($name in @('SIMSQLA', 'SIMSQLB')) {
            $rdms = @(Get-SimRdms -VMName $name)
            Assert-Equal $rdms.Count 3 "$name has the wrong number of RDMs."
            Assert-Equal (@($rdms | ForEach-Object { "$($_.Bus):$($_.Unit)" }) -join ',') '1:0,1:1,1:2' "$name RDMs are at the wrong SCSI addresses."
            Assert-Equal (@($rdms | ForEach-Object { $_.Naa }) -join ',') 'naa.6000000000000040,naa.6000000000000041,naa.6000000000000042' "$name has the wrong devices, or in the wrong order."
        }
    }

    Invoke-SimTest 'The controller type and bus sharing come back as they were' {
        foreach ($name in @('SIMSQLA', 'SIMSQLB')) {
            $rdms = @(Get-SimRdms -VMName $name)
            Assert-Equal (@($rdms | ForEach-Object { $_.ControllerType } | Select-Object -Unique) -join ',') 'VirtualLsiLogicSASController' "$name came back on the wrong controller type."
            Assert-Equal (@($rdms | ForEach-Object { $_.SharedBus } | Select-Object -Unique) -join ',') 'physicalSharing' "$name came back without physical bus sharing."
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

    Invoke-SimTest 'The second node attaches the first node''s mapping files, not its own' {
        $created = @($global:Sim.Events | Where-Object { $_ -like 'create-mapping *' })
        $attached = @($global:Sim.Events | Where-Object { $_ -like 'attach-mapping *' })
        Assert-Equal $created.Count 3 'The first node should create three mapping files.'
        Assert-Equal $attached.Count 3 'The second node should attach three existing mapping files.'
        Assert-Equal (@($created | Where-Object { $_ -notlike '*SIMSQLA*' }).Count) 0 'A mapping file was created for the wrong VM.'

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

    Invoke-SimTest 'The host missing the RDM datastore is excluded, with a reason' {
        $manifest = Get-Content -LiteralPath (Get-ChildItem -Path $executeFolder -Filter '*-execution-manifest-*.json' | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
        Assert-Equal $manifest.RdmDatastore 'simsql02sit_i_rdm' 'The RDM datastore was not derived from the cluster and workload type.'
        Assert-True ([bool]$manifest.RdmDatastoreDerived) 'The manifest does not record that the datastore name was derived.'
        Assert-True (($manifest.ExcludedHosts -join ' ') -like '*sim-esx03*') 'The host that does not mount the RDM datastore was not reported as excluded.'
    }

    Invoke-SimTest 'The presentation prerequisite is stated, device by device' {
        $manifest = Get-Content -LiteralPath (Get-ChildItem -Path $executeFolder -Filter '*-execution-manifest-*.json' | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
        $prerequisite = @($manifest.PresentationPrerequisite)
        Assert-Equal $prerequisite.Count 4 'The prerequisite should be a heading plus one line per LUN.'
        Assert-True ($prerequisite[0] -like "*sim-svm01*sim-esx02*") 'The prerequisite does not name the SVM and the destination hosts.'
        foreach ($naa in @('naa.6000000000000040', 'naa.6000000000000041', 'naa.6000000000000042')) {
            Assert-True ((($prerequisite -join ' ') -like "*$naa*")) "The prerequisite does not name device $naa."
        }
        Assert-True (-not [bool]$manifest.LunPresentationVerified) 'The run claims to have verified presentation without being asked to.'
    }

    Invoke-SimTest 'No host storage is read unless verification is asked for' {
        $log = Get-Content -LiteralPath $executeLog -Raw
        Assert-True ($log -notmatch 'reading storage paths and devices') 'The run read host storage without -VerifyLunPresentation.'
        Assert-True ($log -match 'PREREQUISITE, not checked by this script') 'The prerequisite was not printed for the engineer.'
    }

    # ------------------------------------------------- opt-in presentation check ------
    Reset-SimInventory
    $verifyFolder = Join-Path $script:WorkFolder 'verify'
    $verifyLog = Join-Path $script:WorkFolder 'verify.log'
    try {
        & $ScriptPath -VCenter 'sim-vcenter' -CsvPath $csvPath -DryRun -Credential $credential `
            -PowerAction ShutdownGuest -VerifyLunPresentation -OutputFolder $verifyFolder *> $verifyLog
    }
    catch {
        $script:Failed++
        Write-Host '[FAIL] The verification dry run threw' -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }

    Invoke-SimTest '-VerifyLunPresentation reads the destination hosts and matches every LUN' {
        $log = Get-Content -LiteralPath $verifyLog -Raw
        Assert-True ($log -match 'reading storage paths and devices') 'Verification did not read host storage.'
        Assert-True ($log -match 'all 3 LUN\(s\) present and matching') 'Verification did not confirm the LUNs.'
        $manifest = Get-Content -LiteralPath (Get-ChildItem -Path $verifyFolder -Filter '*-dryrun-manifest-*.json' | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
        Assert-True ([bool]$manifest.LunPresentationVerified) 'The manifest does not record that presentation was verified.'
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
