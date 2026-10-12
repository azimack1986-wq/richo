<#
.SYNOPSIS
    Shared fixtures for the UCS VLAN audit and removal tests: a synthetic UCS Manager domain and vCenter.

.DESCRIPTION
    Dot-sourced by Test-UcsVlanAudit.ps1 and Test-UcsVlanRemoval.ps1, so the removal tests run
    against a manifest produced by the real audit code from the same domain. Not a test itself.

    The domain: VLAN 200 is the only cleanup candidate. Every other LAN Cloud VLAN is protected
    for a different reason - VM (100), VM elsewhere on a shared DV port group (400), VM template
    (800), trunk port group (300/301, fabric-specific), bare-metal direct use (500), VLAN group
    (600), in-band (700), native (10). VLAN 1 and an appliance-cloud VLAN are never candidates.

    Callers must have loaded the audit script's functions and defined $MasterUcsList.
#>

# ---- Fixture builders ------------------------------------------------------------------------
function MoRef { param($Type, $Value) [pscustomobject]@{ Type = $Type; Value = $Value } }
function Typed {
    param([string]$TypeName, [hashtable]$Property)
    $o = [pscustomobject]$Property
    $o.PSObject.TypeNames.Insert(0, $TypeName)
    $o
}
function UcsVlan { param($Name, $Id, $Fabric = '', [switch]$Native, $Parent = 'fabric/lan')
    $dn = if ($Fabric) { "$Parent/$Fabric/net-$Name" } else { "$Parent/net-$Name" }
    [pscustomobject]@{ Name = $Name; Id = [string]$Id; Dn = $dn; DefaultNet = $(if ($Native) { 'yes' } else { 'no' }); Sharing = 'none'; PubNwName = ''; SwitchId = $(if ($Fabric) { $Fabric } else { 'dual' }) }
}
function EtherIf { param($ParentDn, $Name, [switch]$Native) [pscustomobject]@{ Dn = "$ParentDn/if-$Name"; Name = $Name; DefaultNet = $(if ($Native) { 'yes' } else { 'no' }) } }
function Vnic { param($OwnerDn, $Name, $SwitchId, $Mac, $TemplateDn = '') [pscustomobject]@{ Dn = "$OwnerDn/ether-$Name"; Name = $Name; SwitchId = $SwitchId; Addr = $Mac; NwTemplName = ($TemplateDn -replace '^.*/lan-conn-templ-', ''); OperNwTemplName = $TemplateDn } }
function Server { param($Name, $AssocState = 'associated', $Type = 'instance') [pscustomobject]@{ Dn = "org-root/ls-$Name"; Name = $Name; Type = $Type; AssocState = $AssocState; PnDn = "sys/chassis-1/blade-$Name" } }

function New-UcsFixture {
    $tA = 'org-root/lan-conn-templ-ESX-A0'
    $tB = 'org-root/lan-conn-templ-ESX-B1'
    $vlans = @(
        (UcsVlan 'default' 1)
        (UcsVlan 'NATIVE' 10 -Native)
        (UcsVlan 'VL100' 100)
        (UcsVlan 'VL200' 200)
        (UcsVlan 'VL300' 300 -Fabric A)
        (UcsVlan 'VL300' 301 -Fabric B)
        (UcsVlan 'VL400' 400)
        (UcsVlan 'VL500' 500)
        (UcsVlan 'GRP' 600)
        (UcsVlan 'INB' 700)
        (UcsVlan 'VL800' 800)
        (UcsVlan 'APPLIANCE' 999 -Parent 'fabric/eth-estc')
    )
    $templates = @(
        [pscustomobject]@{ Name = 'ESX-A0'; Dn = $tA; SwitchId = 'A'; TemplType = 'updating-template' }
        [pscustomobject]@{ Name = 'ESX-B1'; Dn = $tB; SwitchId = 'B'; TemplType = 'updating-template' }
    )
    $etherIfs = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($tA, $tB)) {
        $etherIfs.Add((EtherIf $t 'NATIVE' -Native))
        foreach ($n in @('VL100', 'VL200', 'VL300', 'VL400', 'VL800')) { $etherIfs.Add((EtherIf $t $n)) }
    }
    $etherIfs.Add((EtherIf $tA 'GHOST'))
    # A template-bound SP vNIC carries materialised copies of the template's VLANs.
    $etherIfs.Add((EtherIf 'org-root/ls-esx01/ether-eth0' 'VL200'))
    # Bare metal: VLANs configured directly on the vNIC.
    $etherIfs.Add((EtherIf 'org-root/ls-bm01/ether-eth0' 'VL500'))
    $etherIfs.Add((EtherIf 'org-root/ls-bm01/ether-eth0' 'VL100'))

    $vnics = @(
        (Vnic 'org-root/ls-esx01' 'eth0' 'A' '00:25:B5:00:00:01' $tA)
        (Vnic 'org-root/ls-esx01' 'eth1' 'B' '00:25:B5:00:00:02' $tB)
        (Vnic 'org-root/ls-esx02' 'eth0' 'A' '00:25:B5:00:00:03' $tA)
        (Vnic 'org-root/ls-esx02' 'eth1' 'B' '00:25:B5:00:00:04' $tB)
        (Vnic 'org-root/ls-bm01' 'eth0' 'A' '00:25:B5:00:00:05')
        (Vnic 'org-root/ls-spare' 'eth0' 'A' 'derived' $tA)
    )
    $servers = @((Server 'esx01'), (Server 'esx02'), (Server 'bm01'), (Server 'spare' 'unassociated'), (Server 'gold' 'unassociated' 'updating-template'))
    @{
        Vlan           = $vlans
        VnicTemplate   = $templates
        EtherIf        = $etherIfs.ToArray()
        Vnic           = $vnics
        ServiceProfile = $servers
        PooledVlan     = @([pscustomobject]@{ Dn = 'fabric/lan/net-group-G1/net-GRP'; Name = 'GRP' })
        InbandProfile  = @([pscustomobject]@{ DefaultVlanName = 'INB' })
    }
}

function Pnic { param($Device, $Mac) [pscustomobject]@{ Device = $Device; Mac = $Mac } }
function StdPg { param($Name, $VlanId, $Switch = 'vSwitch0') [pscustomobject]@{ Spec = [pscustomobject]@{ Name = $Name; VlanId = $VlanId; VswitchName = $Switch } } }
function Vmk { param($Device, $Portgroup = '', $DvKey = '')
    $spec = if ($DvKey) { [pscustomobject]@{ DistributedVirtualPort = [pscustomobject]@{ PortgroupKey = $DvKey } } } else { [pscustomobject]@{ DistributedVirtualPort = $null } }
    [pscustomobject]@{ Device = $Device; Portgroup = $Portgroup; Spec = $spec }
}
function HostView { param($Id, $Name, $Cluster, $Pnics, $Portgroups = @(), $Vmks = @(), $State = 'connected')
    [pscustomobject]@{
        MoRef = (MoRef 'HostSystem' $Id); Name = $Name; Parent = (MoRef 'ClusterComputeResource' $Cluster)
        Runtime = [pscustomobject]@{ ConnectionState = $State }
        Config = [pscustomobject]@{ Network = [pscustomobject]@{ Pnic = $Pnics; Vnic = $Vmks; Portgroup = $Portgroups } }
        ConfigManager = [pscustomobject]@{ NetworkSystem = (MoRef 'HostNetworkSystem' "ns-$Id") }
    }
}
function VlanSpec { param($Id) Typed 'VMware.Vim.VmwareDistributedVirtualSwitchVlanIdSpec' @{ VlanId = $Id } }
function TrunkSpec { param($Ranges) Typed 'VMware.Vim.VmwareDistributedVirtualSwitchTrunkVlanSpec' @{ VlanId = @($Ranges | ForEach-Object { [pscustomobject]@{ Start = $_[0]; End = $_[1] } }) } }
function DvPg { param($Key, $Name, $Vlan, $HostIds, $VmIds = @())
    [pscustomobject]@{
        MoRef = (MoRef 'DistributedVirtualPortgroup' $Key); Name = $Name; Key = $Key
        Config = [pscustomobject]@{ DefaultPortConfig = [pscustomobject]@{ Vlan = $Vlan }; DistributedVirtualSwitch = (MoRef 'VmwareDistributedVirtualSwitch' 'dvs-1'); Uplink = $false }
        Host = @($HostIds | ForEach-Object { MoRef 'HostSystem' $_ }); Vm = @($VmIds | ForEach-Object { MoRef 'VirtualMachine' $_ })
    }
}
function Nic { param($DvKey = '', $StdName = '', [switch]$Opaque, [bool]$Connected = $true)
    $backing = if ($Opaque) { Typed 'VMware.Vim.VirtualEthernetCardOpaqueNetworkBackingInfo' @{ OpaqueNetworkId = 'x' } }
    elseif ($DvKey) { Typed 'VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo' @{ Port = [pscustomobject]@{ PortgroupKey = $DvKey } } }
    else { Typed 'VMware.Vim.VirtualEthernetCardNetworkBackingInfo' @{ DeviceName = $StdName } }
    Typed 'VMware.Vim.VirtualEthernetCard' @{ Backing = $backing; Connectable = [pscustomobject]@{ Connected = $Connected }; DeviceInfo = [pscustomobject]@{ Label = 'Network adapter 1' } }
}
function VmView { param($Id, $Name, $HostId, $Nics, $Power = 'poweredOn', [switch]$Template)
    [pscustomobject]@{
        MoRef = (MoRef 'VirtualMachine' $Id); Name = $Name
        Runtime = [pscustomobject]@{ PowerState = $Power; Host = (MoRef 'HostSystem' $HostId) }
        Config = [pscustomobject]@{ Template = [bool]$Template; Hardware = [pscustomobject]@{ Device = @(@([pscustomobject]@{ Key = 1 }) + @($Nics)) } }
    }
}
function Hint { param($Device, $DevId = '', $SystemName = '') [pscustomobject]@{ Device = $Device; ConnectedSwitchPort = [pscustomobject]@{ DevId = $DevId; SystemName = $SystemName }; LldpInfo = $null } }

function New-VCenterFixture {
    param([switch]$VgtInUse)
    $hosts = @(
        (HostView 'host-1' 'esx01' 'domain-c1' @((Pnic 'vmnic0' '00:25:b5:00:00:01'), (Pnic 'vmnic1' '00:25:b5:00:00:02')) @((StdPg 'Mgmt' 0), (StdPg 'vMotion' 4000), (StdPg 'VGT' 4095)) @((Vmk 'vmk0' 'Mgmt'), (Vmk 'vmk1' 'vMotion')))
        (HostView 'host-2' 'esx02' 'domain-c1' @((Pnic 'vmnic0' '00:25:b5:00:00:03'), (Pnic 'vmnic1' '00:25:b5:00:00:04')) @((StdPg 'Mgmt' 0)) @((Vmk 'vmk0' 'Mgmt')))
        (HostView 'host-3' 'esx03' 'domain-c1' @((Pnic 'vmnic0' '00:25:b5:aa:00:01')) @() @())
        (HostView 'host-9' 'esx99' 'domain-c2' @((Pnic 'vmnic0' '00:50:56:00:00:99')) @() @())
    )
    $compute = @(
        [pscustomobject]@{ MoRef = (MoRef 'ClusterComputeResource' 'domain-c1'); Name = 'CL-PROD' }
        [pscustomobject]@{ MoRef = (MoRef 'ClusterComputeResource' 'domain-c2'); Name = 'CL-OTHER' }
    )
    $switches = @([pscustomobject]@{ MoRef = (MoRef 'VmwareDistributedVirtualSwitch' 'dvs-1'); Name = 'dvs-prod'; Config = [pscustomobject]@{ PvlanConfig = @() } })
    $all = @('host-1', 'host-2', 'host-3', 'host-9')
    $portgroups = @(
        (DvPg 'dvportgroup-100' 'pg-100' (VlanSpec 100) $all @('vm-1'))
        (DvPg 'dvportgroup-200' 'pg-200' (VlanSpec 200) $all)
        (DvPg 'dvportgroup-300' 'pg-trunk' (TrunkSpec @(, @(300, 301))) $all @('vm-2'))
        (DvPg 'dvportgroup-400' 'pg-400' (VlanSpec 400) $all @('vm-9'))
        (DvPg 'dvportgroup-800' 'pg-800' (VlanSpec 800) $all @('vm-t'))
    )
    $vms = @(
        (VmView 'vm-1' 'app01' 'host-1' @(Nic -DvKey 'dvportgroup-100'))
        (VmView 'vm-2' 'trunk01' 'host-2' @(Nic -DvKey 'dvportgroup-300') 'poweredOff')
        (VmView 'vm-9' 'other01' 'host-9' @((Nic -DvKey 'dvportgroup-400'), (Nic -Opaque)))
        (VmView 'vm-t' 'tmpl-win' 'host-1' @(Nic -DvKey 'dvportgroup-800') 'poweredOff' -Template)
    )
    if ($VgtInUse) { $vms += (VmView 'vm-g' 'vgt01' 'host-1' @(Nic -StdName 'VGT')) }
    $hints = @{
        'HostSystem-host-1' = [pscustomobject]@{ Hints = @((Hint 'vmnic0' 'PD24000001SS101-A(FDO1234)'), (Hint 'vmnic1' '' 'PD24000001SS101-B.test')); Error = '' }
        'HostSystem-host-2' = [pscustomobject]@{ Hints = @((Hint 'vmnic0')); Error = '' }
        'HostSystem-host-3' = [pscustomobject]@{ Hints = @((Hint 'vmnic0' 'PD84000001SS028-A(FDO9)')); Error = '' }
        'HostSystem-host-9' = [pscustomobject]@{ Hints = @(); Error = 'host not responding' }
    }
    @{ VCenter = 'vc1.test'; ComputeView = $compute; HostView = $hosts; DvsView = $switches; PortgroupView = $portgroups; VmView = $vms; DiscoveryHint = $hints; AllowedUcsName = $MasterUcsList }
}

function Get-Confirmation {
    param([bool]$Scope = $true, [string]$Side = 'Protected', [int[]]$Dr = @())
    [pscustomobject]@{
        DrConfig            = [pscustomobject]@{ Side = $Side; DrVlans = $Dr; DrSource = 'test' }
        ScopeConfirmed      = $Scope
        PhysicalVlanIds     = [int[]]@()
        PhysicalConfirmed   = $true
        NativeManualVlanIds = [int[]]@()
        NativeConfirmed     = $true
        SpecialVlanIds      = [int[]]@()
    }
}

function Invoke-Audit {
    param($Ucs = (New-UcsFixture), $VCenter = (New-VCenterFixture), $Confirmation = (Get-Confirmation), [datetime]$GeneratedUtc = [datetime]'2026-10-12T00:00:00Z')
    $inventory = ConvertTo-UcsVlanInventory @Ucs
    $evidence = Merge-VCenterEvidence -Evidence @(ConvertTo-VCenterEvidence @VCenter)
    $scope = Get-AuditScope -Inventory $inventory -Evidence $evidence -UcsName 'PD24000001SS101'
    $usage = Get-NetworkUsage -Evidence $evidence -Scope $scope
    $pairs = @(Get-TemplatePairAudit -Template $inventory.Templates -Membership $inventory.Memberships)
    $result = Get-VlanAuditResult -Inventory $inventory -Evidence $evidence -Scope $scope -Usage $usage -PairAudit $pairs -Confirmation $Confirmation -UcsServer 'PD24000001SS101' -GeneratedUtc $GeneratedUtc
    [pscustomobject]@{ Inventory = $inventory; Evidence = $evidence; Scope = $scope; Usage = $usage; Pairs = $pairs; Result = $result }
}
function Get-Sheet { param($Result, $Name) @($Result.Sheets | Where-Object { $_.Name -eq $Name })[0].Rows }
function Get-FinalRow { param($Result, $Id) @((Get-Sheet $Result 'Final Comparison') | Where-Object { $_.VLANID -eq $Id })[0] }
