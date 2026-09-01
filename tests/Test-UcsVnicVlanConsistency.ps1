<#
.SYNOPSIS
    Tests the VLAN, vNIC pair and vDS cross-check logic of
    scripts/ucs/Test-UcsVnicVlanConsistency.ps1.

.DESCRIPTION
    Every function under test is pure - objects in, findings out - so the whole
    check runs here with no vCenter, no fabric interconnect and no vendor module.
    What that buys is the ability to assert on the cases that matter and are hard
    to produce on purpose in production: a VLAN id defined under two names, a
    pair split across one fabric, a port group whose VLAN nobody trunks.

    Set-StrictMode is on for the same reason it is on in the script. Most of what
    is read here comes out of a vendor object whose shape moves between releases,
    and a property this build does not have must produce a default, not a
    terminating error halfway through a run.

    Standalone - no Pester, no PowerCLI, no UCS PowerTool.

.EXAMPLE
    pwsh -File ./tests/Test-UcsVnicVlanConsistency.ps1
#>

Set-StrictMode -Version Latest

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ucs/Test-UcsVnicVlanConsistency.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw ("parse errors in $scriptPath : " + (($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')) }

$underTest = @(
    'Get-MoProperty', 'Format-IdList', 'Get-VlanIdReservation', 'Test-UcsVlanInventory',
    'Get-VlanSummary', 'Get-VnicOrdinal', 'Get-VnicOrdinalMap', 'ConvertTo-OrdinalGroup',
    'Compare-VnicGroup', 'ConvertTo-VlanIdList', 'Test-UplinkPortGroup', 'Get-HostUplinkMap',
    'Get-VdsDiscoveryProtocol', 'Compare-VdsVlanCoverage', 'Get-LldpSystemName',
    'Remove-UcsTargetDecoration', 'Convert-FiSystemNameToUcsCandidate', 'Get-ParentDn',
    'ConvertTo-PolicyName', 'Get-VnicMemberDetail', 'Resolve-UcsServiceProfile'
)

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in $underTest } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

# Set by the script's own state block, which is not executed here.
$script:UcsReservedVlanFirst = 4030
$script:UcsReservedVlanLast = 4047

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}
function Assert-True {
    param([string]$Name, $Condition)
    Assert-Equal -Name $Name -Expected $true -Actual ([bool]$Condition)
}

# --- builders --------------------------------------------------------------
function New-Vlan { param($Name, $Id, $SwitchId = 'dual')
    [pscustomobject]@{ Name = $Name; Id = $Id; SwitchId = $SwitchId } }
function New-Vsan { param($Name, $FcoeVlan)
    [pscustomobject]@{ Name = $Name; Id = 100; FcoeVlan = $FcoeVlan } }
function New-Member {
    param($Ordinal, $VnicName, $VlanIds, $SwitchId = 'A', $Mtu = 9000, $NativeId = 0,
          $TemplateName = 'tmpl', $TemplateType = 'updating-template',
          $Ncp = 'CDP-ON', $Qos = 'best-effort', $Adapter = 'VMWare')
    [pscustomobject]@{
        Ordinal = $Ordinal; VnicName = $VnicName; TemplateName = $TemplateName
        TemplateType = $TemplateType; SwitchId = $SwitchId; Mtu = $Mtu
        VlanIds = @($VlanIds); NativeId = $NativeId; NativeName = ''
        NetworkControlPolicy = $Ncp; QosPolicy = $Qos; AdapterPolicy = $Adapter
    } }
function New-PortGroup { param($Name, $Kind, $VlanIds)
    [pscustomobject]@{ Name = $Name; Kind = $Kind; VlanIds = @($VlanIds); Count = @($VlanIds).Count } }
# The leading comma keeps an empty result an empty ARRAY. Without it PowerShell
# unrolls it to nothing, the caller gets $null, and .Count throws under
# StrictMode - which reads as a broken test rather than a passing check.
function Get-Check { param($Findings, $Check) ,@($Findings | Where-Object { $_.Check -eq $Check }) }

Write-Host "`n=== Reading vendor objects that may not have the property ===" -ForegroundColor Cyan
# Under StrictMode a direct read of a property this UCSM or PowerCLI build does
# not expose is a terminating error, mid-run, on live infrastructure.
Assert-Equal 'a missing property yields the default' 'unknown' (Get-MoProperty ([pscustomobject]@{ Cdp = 'enabled' }) 'LldpTransmit' 'unknown')
Assert-Equal 'a present property is returned'        'enabled' (Get-MoProperty ([pscustomobject]@{ Cdp = 'enabled' }) 'Cdp' 'unknown')
Assert-Equal 'a null object yields the default'      ''        (Get-MoProperty $null 'Cdp' '')
Assert-Equal 'a null value yields the default'       '0'       (Get-MoProperty ([pscustomobject]@{ Mtu = $null }) 'Mtu' '0')

Write-Host "`n=== Rendering id lists ===" -ForegroundColor Cyan
Assert-Equal 'consecutive ids collapse'  '100-102, 250' (Format-IdList -Id @(100, 101, 102, 250))
Assert-Equal 'unsorted input is sorted'  '10, 20'       (Format-IdList -Id @(20, 10))
Assert-Equal 'duplicates are dropped'    '10'           (Format-IdList -Id @(10, 10, 10))
Assert-Equal 'an empty list says so'     '(none)'       (Format-IdList -Id @())
Assert-Equal 'a long list is truncated'  '1, 3, 5 and 2 more' (Format-IdList -Id @(1, 3, 5, 7, 9) -MaxItem 3)

Write-Host "`n=== VLAN ids that are not usable ===" -ForegroundColor Cyan
Assert-Equal 'a normal id is fine'    '' (Get-VlanIdReservation -VlanId 250)
Assert-True  'id 0 is rejected'          ((Get-VlanIdReservation -VlanId 0) -ne '')
Assert-True  'id 4095 is rejected'       ((Get-VlanIdReservation -VlanId 4095) -ne '')
Assert-True  '4040 is UCS reserved'      ((Get-VlanIdReservation -VlanId 4040) -match 'reserved by UCS Manager')
Assert-True  '4029 is below the band'    ((Get-VlanIdReservation -VlanId 4029) -eq '')
Assert-True  '4048 is above the band'    ((Get-VlanIdReservation -VlanId 4048) -eq '')
Assert-True  '1003 is legacy reserved'   ((Get-VlanIdReservation -VlanId 1003) -match 'legacy')

Write-Host "`n=== VLAN definitions in a domain ===" -ForegroundColor Cyan
# One id under two names. Both resolve, one gets trunked, and which one you get
# depends on the name the vNIC template was built with.
$findings = Test-UcsVlanInventory -Vlan @((New-Vlan 'PROD-250' 250), (New-Vlan 'Prod_250' 250)) -Vsan @()
Assert-Equal 'one id under two names is reported' 1 (Get-Check $findings 'VlanIdDefinedTwice').Count
Assert-Equal 'and it is an error'                 'ERROR' (Get-Check $findings 'VlanIdDefinedTwice')[0].Severity

$findings = Test-UcsVlanInventory -Vlan @((New-Vlan 'PROD-250' 250), (New-Vlan 'PROD-260' 260)) -Vsan @()
Assert-Equal 'distinct VLANs are clean' 0 @($findings | Where-Object { $_.Severity -ne 'INFO' }).Count

# A name appearing once per fabric with a different id on each is a normal
# fabric-scoped VLAN, and reporting it would be crying wolf.
$findings = Test-UcsVlanInventory -Vlan @((New-Vlan 'VMOTION' 300 'A'), (New-Vlan 'VMOTION' 301 'B')) -Vsan @()
Assert-Equal 'a fabric-scoped pair is not a finding' 0 (Get-Check $findings 'VlanNameDefinedTwice').Count

$findings = Test-UcsVlanInventory -Vlan @((New-Vlan 'VMOTION' 300 'A'), (New-Vlan 'VMOTION' 301 'A')) -Vsan @()
Assert-Equal 'the same name twice on ONE fabric is' 1 (Get-Check $findings 'VlanNameDefinedTwice').Count

$findings = Test-UcsVlanInventory -Vlan @((New-Vlan 'BAD' 4040)) -Vsan @()
Assert-Equal 'a reserved id is reported' 1 (Get-Check $findings 'VlanIdReserved').Count

$findings = Test-UcsVlanInventory -Vlan @((New-Vlan 'DEFAULT' 1)) -Vsan @()
Assert-Equal 'VLAN 1 is INFO, not an error' 'INFO' (Get-Check $findings 'VlanIdDefault')[0].Severity

# UCS lets an Ethernet VLAN and a VSAN's FCoE VLAN share an id, and the storage
# traffic wins. Nothing warns until the Ethernet VLAN is put into service.
$findings = Test-UcsVlanInventory -Vlan @((New-Vlan 'DATA' 4048)) -Vsan @((New-Vsan 'VSAN-A' 4048))
Assert-Equal 'an FCoE collision is reported' 1 (Get-Check $findings 'VlanFcoeCollision').Count
$findings = Test-UcsVlanInventory -Vlan @((New-Vlan 'DATA' 250)) -Vsan @((New-Vsan 'VSAN-A' 4048))
Assert-Equal 'no collision when the ids differ' 0 (Get-Check $findings 'VlanFcoeCollision').Count

Write-Host "`n=== VLANs on a template or a vNIC ===" -ForegroundColor Cyan
$index = @{
    'org-root/lan-conn-templ-eth0' = @(
        [pscustomobject]@{ Name = 'PROD-250'; Vnet = 250; DefaultNet = 'no' }
        [pscustomobject]@{ Name = 'MGMT-10';  Vnet = 10;  DefaultNet = 'yes' }
    )
    # Vnet absent, which some releases do: the id has to come from the domain's
    # VLAN table or the template reports an empty VLAN set.
    'org-root/lan-conn-templ-eth1' = @(
        [pscustomobject]@{ Name = 'PROD-250'; DefaultNet = 'no' }
        [pscustomobject]@{ Name = 'NOT-DEFINED'; DefaultNet = 'no' }
    )
}
$byName = @{ 'PROD-250' = 250; 'MGMT-10' = 10 }

$summary = Get-VlanSummary -ParentDn 'org-root/lan-conn-templ-eth0' -InterfaceIndex $index -VlanIdByName $byName
Assert-Equal 'ids are read from Vnet'      '10, 250' (($summary.VlanIds | Sort-Object) -join ', ')
Assert-Equal 'the native VLAN is found'    10        $summary.NativeId
Assert-Equal 'the native name is found'    'MGMT-10' $summary.NativeName

$summary = Get-VlanSummary -ParentDn 'org-root/lan-conn-templ-eth1' -InterfaceIndex $index -VlanIdByName $byName
Assert-Equal 'a missing Vnet is resolved by name' '250' ($summary.VlanIds -join ', ')
Assert-Equal 'a name with no id is flagged'       'NOT-DEFINED' ($summary.Unresolved -join ', ')

$summary = Get-VlanSummary -ParentDn 'org-root/lan-conn-templ-nothing' -InterfaceIndex $index -VlanIdByName $byName
Assert-Equal 'an unknown parent is empty, not an error' 0 $summary.Count

Write-Host "`n=== vNIC ordinals ===" -ForegroundColor Cyan
Assert-Equal 'a trailing digit is the ordinal'  0  (Get-VnicOrdinal -Name 'eth0')
Assert-Equal 'two digits are read as one number' 10 (Get-VnicOrdinal -Name 'eth10')
Assert-Equal 'vmnic names work too'             3  (Get-VnicOrdinal -Name 'vmnic3')
Assert-Equal 'a name with no number is -1'      -1 (Get-VnicOrdinal -Name 'MGMT-A')

$named = @(
    [pscustomobject]@{ Name = 'eth1'; Order = '2' }
    [pscustomobject]@{ Name = 'eth0'; Order = '1' }
)
$map = Get-VnicOrdinalMap -Vnic $named
Assert-Equal 'names win when they are distinct' 'name' $map.Source
Assert-Equal 'eth0 is ordinal 0'                'eth0' $map.Map[0].Name

# Names that carry no ordinal, or repeat one, cannot decide the mapping. The UCS
# order field does, and the caller is told the answer was derived.
$unnamed = @(
    [pscustomobject]@{ Name = 'MGMT-B'; Order = '2' }
    [pscustomobject]@{ Name = 'MGMT-A'; Order = '1' }
)
$map = Get-VnicOrdinalMap -Vnic $unnamed
Assert-Equal 'order is the fallback'        'order'  $map.Source
Assert-Equal 'the lowest order is ordinal 0' 'MGMT-A' $map.Map[0].Name

$duplicate = @(
    [pscustomobject]@{ Name = 'A-eth0'; Order = '2' }
    [pscustomobject]@{ Name = 'B-eth0'; Order = '1' }
)
Assert-Equal 'a repeated trailing digit falls back' 'order' (Get-VnicOrdinalMap -Vnic $duplicate).Source
Assert-Equal 'no vNICs is not an error'             'none'  (Get-VnicOrdinalMap -Vnic @()).Source

Write-Host "`n=== Pair group parsing ===" -ForegroundColor Cyan
$groups = ConvertTo-OrdinalGroup -Group @('0,1', '2,3')
Assert-Equal 'two groups parsed'      2       $groups.Count
Assert-Equal 'the first group is 0,1' '0, 1'  ($groups[0] -join ', ')
Assert-Equal 'separators are flexible' '4, 5' ((ConvertTo-OrdinalGroup -Group @('4 5'))[0] -join ', ')

$threw = $false
try { [void](ConvertTo-OrdinalGroup -Group @('0')) } catch { $threw = $true }
Assert-True 'a one-member group is rejected' $threw
$threw = $false
try { [void](ConvertTo-OrdinalGroup -Group @('0,0')) } catch { $threw = $true }
Assert-True 'a group that repeats an ordinal is rejected' $threw
$threw = $false
try { [void](ConvertTo-OrdinalGroup -Group @('0,eth1')) } catch { $threw = $true }
Assert-True 'a non-numeric ordinal is rejected' $threw

Write-Host "`n=== The pair comparison - this is the check that was asked for ===" -ForegroundColor Cyan
$matched = @(
    (New-Member 0 'eth0' @(10, 250) 'A')
    (New-Member 1 'eth1' @(10, 250) 'B')
)
Assert-Equal 'an identical pair produces nothing' 0 @(Compare-VnicGroup -Member $matched).Count

# The fault this exists to find: one leg missing a VLAN. Traffic on it survives
# only while the other fabric is up, so it looks healthy until a failover.
$drifted = @(
    (New-Member 0 'eth0' @(10, 250) 'A')
    (New-Member 1 'eth1' @(10) 'B')
)
$findings = @(Compare-VnicGroup -Member $drifted)
Assert-Equal 'a missing VLAN is reported once'  1 (Get-Check $findings 'VnicPairVlanMismatch').Count
Assert-Equal 'against the leg that is missing it' $true ((Get-Check $findings 'VnicPairVlanMismatch')[0].Detail -match 'eth1.*missing VLAN\(s\) 250')
Assert-Equal 'and it is an error'               'ERROR' (Get-Check $findings 'VnicPairVlanMismatch')[0].Severity

# A stray VLAN on one leg is the same fault seen from the other side, and it is
# reported against the leg that lacks it, not as "they differ".
$stray = @(
    (New-Member 0 'eth0' @(10) 'A')
    (New-Member 1 'eth1' @(10, 999) 'B')
)
Assert-Equal 'a stray VLAN is attributed to eth0' $true ((Get-Check (Compare-VnicGroup -Member $stray) 'VnicPairVlanMismatch')[0].Detail -match '^eth0')

$mtu = @(
    (New-Member 0 'eth0' @(10) 'A' 9000)
    (New-Member 1 'eth1' @(10) 'B' 1500)
)
Assert-Equal 'an MTU mismatch is reported' 1 (Get-Check (Compare-VnicGroup -Member $mtu) 'VnicPairMtuMismatch').Count

$native = @(
    (New-Member 0 'eth0' @(10, 250) 'A' 9000 10)
    (New-Member 1 'eth1' @(10, 250) 'B' 9000 250)
)
Assert-Equal 'a native VLAN mismatch is reported' 1 (Get-Check (Compare-VnicGroup -Member $native) 'VnicPairNativeVlanMismatch').Count

$policy = @(
    (New-Member 0 'eth0' @(10) 'A' 9000 0 'tmpl-a' 'updating-template' 'CDP-ON')
    (New-Member 1 'eth1' @(10) 'B' 9000 0 'tmpl-b' 'updating-template' 'CDP-OFF')
)
Assert-Equal 'a network control policy mismatch is a warning' 'WARN' (Get-Check (Compare-VnicGroup -Member $policy) 'VnicPairPolicyMismatch')[0].Severity

# Two legs on one fabric is a single point of failure wearing a redundant pair's
# name, and nothing in vCenter shows it.
$sameFabric = @(
    (New-Member 0 'eth0' @(10) 'A')
    (New-Member 1 'eth1' @(10) 'A')
)
Assert-Equal 'a pair on one fabric is reported' 1 (Get-Check (Compare-VnicGroup -Member $sameFabric) 'VnicPairSameFabric').Count

Assert-Equal 'a lone vNIC is reported as incomplete' 1 (Get-Check (Compare-VnicGroup -Member @((New-Member 0 'eth0' @(10) 'A'))) 'VnicGroupIncomplete').Count
Assert-Equal 'an empty group is not an error'        0 @(Compare-VnicGroup -Member @()).Count

$expected = @(
    (New-Member 0 'eth0' @(10) 'A' 1500)
    (New-Member 1 'eth1' @(10) 'B' 1500)
)
Assert-Equal 'a matched pair still fails an explicit MTU' 2 (Get-Check (Compare-VnicGroup -Member $expected -ExpectedMtu 9000) 'VnicMtuUnexpected').Count
Assert-Equal 'and passes when it matches'                 0 (Get-Check (Compare-VnicGroup -Member $expected -ExpectedMtu 1500) 'VnicMtuUnexpected').Count

$untemplated = @(
    (New-Member 0 'eth0' @(10) 'A' 9000 0 'tmpl-a')
    (New-Member 1 'eth1' @(10) 'B' 9000 0 '')
)
Assert-Equal 'a vNIC configured off-template is reported' 1 (Get-Check (Compare-VnicGroup -Member $untemplated) 'VnicNotTemplated').Count

Write-Host "`n=== Port group VLAN specs ===" -ForegroundColor Cyan
# Three unrelated shapes. Read the wrong one and a trunk port group looks like
# VLAN 0, which would then be reported as untagged on every host.
$access = ConvertTo-VlanIdList -VlanSpec ([pscustomobject]@{ VlanId = 250 })
Assert-Equal 'an access port group is one VLAN' 'Access' $access.Kind
Assert-Equal 'and carries its id'               '250'    ($access.VlanIds -join ', ')

$trunk = ConvertTo-VlanIdList -VlanSpec ([pscustomobject]@{ VlanId = @(
    [pscustomobject]@{ Start = 100; End = 102 }
    [pscustomobject]@{ Start = 250; End = 250 }
) })
Assert-Equal 'a trunk is recognised by shape' 'Trunk' $trunk.Kind
Assert-Equal 'and its ranges are expanded'    '100, 101, 102, 250' ($trunk.VlanIds -join ', ')
Assert-Equal 'with a usable count'            4 $trunk.Count

$wide = ConvertTo-VlanIdList -VlanSpec ([pscustomobject]@{ VlanId = @([pscustomobject]@{ Start = 0; End = 4094 }) })
Assert-Equal 'a trunk-everything range drops the invalid ids' 4094 $wide.Count

Assert-Equal 'VLAN 0 is untagged, not VLAN 0' 'None'  (ConvertTo-VlanIdList -VlanSpec ([pscustomobject]@{ VlanId = 0 })).Kind
Assert-Equal 'a null spec is untagged'        'None'  (ConvertTo-VlanIdList -VlanSpec $null).Kind
Assert-Equal 'a pvlan is recognised'          'Pvlan' (ConvertTo-VlanIdList -VlanSpec ([pscustomobject]@{ PvlanId = 501 })).Kind

Write-Host "`n=== Uplink port groups are excluded ===" -ForegroundColor Cyan
# The uplink port group trunks everything by design. Measured against UCS it
# would report every VLAN in the estate as missing.
Assert-True  'the SYSTEM tag is recognised' (Test-UplinkPortGroup -PortGroupView ([pscustomobject]@{ Tag = @([pscustomobject]@{ Key = 'SYSTEM/DVS.UPLINKPG' }) }))
Assert-True  'an uplink config type is too'  (Test-UplinkPortGroup -PortGroupView ([pscustomobject]@{ Config = [pscustomobject]@{ Type = 'uplinkPortgroup' } }))
Assert-Equal 'an ordinary port group is not' $false (Test-UplinkPortGroup -PortGroupView ([pscustomobject]@{ Tag = @(); Config = [pscustomobject]@{ Type = 'earlyBinding' } }))
Assert-Equal 'a null view is not'            $false (Test-UplinkPortGroup -PortGroupView $null)

Write-Host "`n=== Which vDS owns which vmnic - the join the cross-check needs ===" -ForegroundColor Cyan
$hostView = [pscustomobject]@{ Config = [pscustomobject]@{ Network = [pscustomobject]@{ ProxySwitch = @(
    [pscustomobject]@{ DvsName = 'dvs-mgmt'; Pnic = @('key-vim.host.PhysicalNic-vmnic0', 'key-vim.host.PhysicalNic-vmnic1') }
    [pscustomobject]@{ DvsName = 'dvs-prod'; Pnic = @('key-vim.host.PhysicalNic-vmnic2', 'key-vim.host.PhysicalNic-vmnic3') }
) } } }
$uplinks = Get-HostUplinkMap -HostView $hostView
Assert-Equal 'four uplinks mapped'      4          $uplinks.Count
Assert-Equal 'vmnic0 is on dvs-mgmt'    'dvs-mgmt' $uplinks['vmnic0']
Assert-Equal 'vmnic3 is on dvs-prod'    'dvs-prod' $uplinks['vmnic3']
Assert-Equal 'a host with no vDS is empty' 0 (Get-HostUplinkMap -HostView ([pscustomobject]@{ Config = [pscustomobject]@{ Network = [pscustomobject]@{} } })).Count
Assert-Equal 'a null view is empty'        0 (Get-HostUplinkMap -HostView $null).Count

Write-Host "`n=== The vCenter cross-check ===" -ForegroundColor Cyan
# The direction that matters: a port group VLAN UCS does not trunk is a black
# hole. VMs attach to it and the frames die at the fabric interconnect.
$groups = @(
    (New-PortGroup 'PG-250' 'Access' @(250))
    (New-PortGroup 'PG-999' 'Access' @(999))
)
$findings = @(Compare-VdsVlanCoverage -VdsName 'dvs-prod' -PortGroup $groups -TrunkedVlanId @(10, 250))
Assert-Equal 'an untrunked port group VLAN is an error' 1 (Get-Check $findings 'PortGroupVlanNotTrunked').Count
Assert-True  'and it names the VLAN'  ((Get-Check $findings 'PortGroupVlanNotTrunked')[0].Detail -match '999')

# The reverse costs nothing and is usually deliberate headroom.
Assert-Equal 'a VLAN nobody uses is only INFO' 'INFO' (Get-Check $findings 'TrunkedVlanUnused')[0].Severity

$findings = @(Compare-VdsVlanCoverage -VdsName 'dvs-prod' -PortGroup @((New-PortGroup 'PG-250' 'Access' @(250))) -TrunkedVlanId @(250))
Assert-Equal 'full coverage produces no error' 0 @($findings | Where-Object { $_.Severity -eq 'ERROR' }).Count

# A transit port group trunking a wide range is deliberate. Demanding UCS carry
# all of it would bury every real finding under one wall of numbers.
$wideGroup = @((New-PortGroup 'PG-TRANSIT' 'Trunk' @(1..200)))
$findings = @(Compare-VdsVlanCoverage -VdsName 'dvs-prod' -PortGroup $wideGroup -TrunkedVlanId @(10) -LargeTrunkThreshold 64)
Assert-Equal 'a wide trunk is INFO, not 199 errors' 0 (Get-Check $findings 'PortGroupVlanNotTrunked').Count
Assert-Equal 'and is reported by count'             1 (Get-Check $findings 'PortGroupWideTrunk').Count

# Untagged frames arrive on the uplink's native VLAN. With none set there is
# nothing for them to land on.
$untagged = @((New-PortGroup 'PG-NATIVE' 'None' @()))
Assert-Equal 'untagged with no native VLAN is a warning' 1 (Get-Check (Compare-VdsVlanCoverage -VdsName 'dvs' -PortGroup $untagged -TrunkedVlanId @(10) -NativeVlanId 0) 'PortGroupUntaggedNoNativeVlan').Count
Assert-Equal 'untagged with a native VLAN is fine'       0 (Get-Check (Compare-VdsVlanCoverage -VdsName 'dvs' -PortGroup $untagged -TrunkedVlanId @(10) -NativeVlanId 10) 'PortGroupUntaggedNoNativeVlan').Count

Write-Host "`n=== CDP and LLDP identity ===" -ForegroundColor Cyan
# LLDP has no system name field; it arrives as a key/value pair with whatever
# spelling the sender chose.
Assert-Equal 'System Name is read' 'fi-a.example.com' (Get-LldpSystemName -LldpInfo ([pscustomobject]@{ ChassisId = ''; Parameter = @([pscustomobject]@{ Key = 'System Name'; Value = 'fi-a.example.com' }) }))
Assert-Equal 'sysName is read too'  'fi-a.example.com' (Get-LldpSystemName -LldpInfo ([pscustomobject]@{ ChassisId = ''; Parameter = @([pscustomobject]@{ Key = 'sysName'; Value = 'fi-a.example.com' }) }))
# On a fabric interconnect the chassis id is usually the MAC, which is no use as
# a name and must not be offered as one.
Assert-Equal 'a MAC chassis id is not a name' '' (Get-LldpSystemName -LldpInfo ([pscustomobject]@{ ChassisId = '00:2a:6a:11:22:33'; Parameter = @() }))
Assert-Equal 'a bare-hex chassis id is not either' '' (Get-LldpSystemName -LldpInfo ([pscustomobject]@{ ChassisId = '002a6a112233'; Parameter = @() }))
Assert-Equal 'a real chassis name is used' 'switch-1' (Get-LldpSystemName -LldpInfo ([pscustomobject]@{ ChassisId = 'switch-1'; Parameter = @() }))
Assert-Equal 'no LldpInfo is empty, not an error' '' (Get-LldpSystemName -LldpInfo $null)

Write-Host "`n=== Fabric name to UCS Manager name ===" -ForegroundColor Cyan
# CDP reports the individual FI; UCS Manager answers on the cluster name.
Assert-Equal 'the -A suffix is removed from an FQDN' 'ucs01.example.com' (Convert-FiSystemNameToUcsCandidate -SystemName 'ucs01-A.example.com')
Assert-Equal 'the -B suffix too'                      'ucs01.example.com' (Convert-FiSystemNameToUcsCandidate -SystemName 'ucs01-B.example.com')
Assert-Equal 'a short name works'                     'ucs01'             (Convert-FiSystemNameToUcsCandidate -SystemName 'ucs01-a')
# The bracketed serial is not part of the hostname and makes Connect-Ucs fail
# with 'Invalid URI'.
Assert-Equal 'the bracketed serial is stripped' 'ucs01.example.com' (Convert-FiSystemNameToUcsCandidate -SystemName 'ucs01-A.example.com(FD0261301D1)')
Assert-Equal 'a name with no suffix is untouched' 'ucs01.example.com' (Convert-FiSystemNameToUcsCandidate -SystemName 'ucs01.example.com')

Write-Host "`n=== Dn handling ===" -ForegroundColor Cyan
Assert-Equal 'a parent Dn is everything before the last slash' 'org-root/lan-conn-templ-eth0' (Get-ParentDn -Dn 'org-root/lan-conn-templ-eth0/if-VL250')
Assert-Equal 'a top-level Dn has no parent' '' (Get-ParentDn -Dn 'org-root')
Assert-Equal 'a policy Dn reduces to its name' 'CDP-ON' (ConvertTo-PolicyName -Value 'org-root/nwctrl-CDP-ON' -Prefix 'nwctrl-')
Assert-Equal 'a plain name is left alone'      'CDP-ON' (ConvertTo-PolicyName -Value 'CDP-ON' -Prefix 'nwctrl-')
Assert-Equal 'a name containing the prefix text survives' 'nwctrl-ish' (ConvertTo-PolicyName -Value 'nwctrl-nwctrl-ish' -Prefix 'nwctrl-')

Write-Host "`n=== Resolving one vNIC into the view the checks work on ===" -ForegroundColor Cyan
$templates = @{ 'eth0-tmpl' = [pscustomobject]@{
    Dn = 'org-root/lan-conn-templ-eth0-tmpl'; Name = 'eth0-tmpl'; Mtu = '9000'
    SwitchId = 'A'; TemplType = 'updating-template'; NwCtrlPolicyName = 'CDP-ON'
    QosPolicyName = 'best-effort'; AdaptorProfileName = 'VMWare' } }
$interfaces = @{
    'org-root/lan-conn-templ-eth0-tmpl' = @(
        [pscustomobject]@{ Name = 'MGMT-10'; Vnet = 10; DefaultNet = 'yes' }
        [pscustomobject]@{ Name = 'PROD-250'; Vnet = 250; DefaultNet = 'no' }
    )
    'org-root/ls-esx01/ether-eth0' = @(
        [pscustomobject]@{ Name = 'MGMT-10'; Vnet = 10; DefaultNet = 'yes' }
    )
}
$vnic = [pscustomobject]@{
    Dn = 'org-root/ls-esx01/ether-eth0'; Name = 'eth0'; Order = '1'
    NwTemplName = 'eth0-tmpl'; Mtu = '0'; SwitchId = ''
}
$member = Get-VnicMemberDetail -Ordinal 0 -Vnic $vnic -TemplateByName $templates -InterfaceIndex $interfaces -VlanIdByName @{}
Assert-Equal 'the vNIC''s own VLANs win over the template''s' '10' ($member.VlanIds -join ', ')
Assert-Equal 'the template fills in a missing MTU'   9000 $member.Mtu
Assert-Equal 'and a missing fabric'                  'A'  $member.SwitchId
Assert-Equal 'and the policies'                      'CDP-ON' $member.NetworkControlPolicy
# An initial-template edited after the profile was stamped looks correct in UCS
# Manager and is not correct on the blade.
Assert-Equal 'drift from the template is reported'   '250' ($member.TemplateDriftIds -join ', ')

# No template bound at all: everything has to come off the vNIC itself.
$standalone = [pscustomobject]@{
    Dn = 'org-root/ls-esx01/ether-eth0'; Name = 'eth0'; Order = '1'
    Mtu = '1500'; SwitchId = 'B'; NwCtrlPolicyName = 'default'
}
$member = Get-VnicMemberDetail -Ordinal 0 -Vnic $standalone -TemplateByName @{} -InterfaceIndex $interfaces -VlanIdByName @{}
Assert-Equal 'an untemplated vNIC has no template name' '' $member.TemplateName
Assert-Equal 'and reads its own MTU'                    1500 $member.Mtu
Assert-Equal 'and reports no drift'                     0 @($member.TemplateDriftIds).Count

# A Dn-only reference, which is what Oper* properties carry.
$operOnly = [pscustomobject]@{
    Dn = 'org-root/ls-esx01/ether-eth0'; Name = 'eth0'; Order = '1'
    OperNwTemplName = 'org-root/lan-conn-templ-eth0-tmpl'; Mtu = '0'; SwitchId = ''
}
Assert-Equal 'a template Dn resolves to its name' 'eth0-tmpl' (Get-VnicMemberDetail -Ordinal 0 -Vnic $operOnly -TemplateByName $templates -InterfaceIndex $interfaces -VlanIdByName @{}).TemplateName

Write-Host "`n=== Matching a host to its service profile ===" -ForegroundColor Cyan
# UUID first: UCS writes the profile's UUID into the blade's SMBIOS, so it is an
# identity rather than a naming convention, and it holds when the profile is
# named nothing like the host.
$profiles = @(
    [pscustomobject]@{ Name = 'sp-blade-7'; Dn = 'org-root/ls-sp-blade-7'; Uuid = '1b4e28ba-2fa1-11d2-883f-0016d3cca427' }
    [pscustomobject]@{ Name = 'esx02';      Dn = 'org-root/ls-esx02';      Uuid = '00000000-0000-0000-0000-000000000000' }
)
Assert-Equal 'matched by hardware UUID' 'sp-blade-7' (Resolve-UcsServiceProfile -HostName 'esx01.example.com' -HostUuid '1b4e28ba-2fa1-11d2-883f-0016d3cca427' -Profile $profiles).Name
Assert-Equal 'matched by short name'    'esx02'      (Resolve-UcsServiceProfile -HostName 'esx02.example.com' -HostUuid '' -Profile $profiles).Name
Assert-Equal 'no match is $null, not a guess' $true ($null -eq (Resolve-UcsServiceProfile -HostName 'esx99.example.com' -HostUuid '' -Profile $profiles))

Write-Host "`n=== vDS discovery protocol ===" -ForegroundColor Cyan
$vdsView = [pscustomobject]@{ Config = [pscustomobject]@{ LinkDiscoveryProtocolConfig = [pscustomobject]@{ Protocol = 'CDP'; Operation = 'Both' } } }
$discovery = Get-VdsDiscoveryProtocol -VdsView $vdsView
Assert-Equal 'the protocol is normalised'  'cdp'  $discovery.Protocol
Assert-Equal 'and the operation'           'both' $discovery.Operation
Assert-Equal 'a vDS with no config is empty, not an error' '' (Get-VdsDiscoveryProtocol -VdsView ([pscustomobject]@{})).Protocol

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
