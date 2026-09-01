<#
.SYNOPSIS
    Runs scripts/ucs/Test-UcsVnicVlanConsistency.ps1 end to end against a fake
    estate that is deliberately misconfigured, and checks it finds the faults.

.DESCRIPTION
    The unit tests beside this one cover the comparison functions in isolation.
    They cannot cover the part that has historically broken on live runs: the
    glue. Reading a property this build of PowerCLI does not expose, mapping a
    vmnic to the wrong vNIC, unrolling an array so a single pair group arrives as
    loose integers - none of that shows up until the script is pointed at
    something, by which time it is pointed at production.

    So the whole script is executed here. vCenter, the distributed switches, the
    hosts and a UCS domain are stubbed as ordinary functions in this scope, which
    the script finds through the scope chain, and the fake estate carries one
    instance of each fault class the script exists to find:

      - a VLAN id defined under two names
      - an Ethernet VLAN colliding with a VSAN's FCoE VLAN
      - vNIC 1 missing a VLAN that vNIC 0 carries
      - vNICs 2 and 3 both on fabric A
      - a port group on a VLAN that UCS does not trunk
      - a vDS set to CDP in front of a network control policy with CDP disabled

    Standalone - no Pester, no PowerCLI, no UCS PowerTool, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsVnicVlanConsistencyRun.ps1
#>

Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot 'scripts/ucs/Test-UcsVnicVlanConsistency.ps1'

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# --- Assert-RichoModule really does enumerate the module path, so the VMware
#     modules are stubbed as manifests rather than by neutering the check.
$stubRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('richo-stub-modules-' + [guid]::NewGuid().ToString('N'))
foreach ($moduleName in @('VMware.VimAutomation.Core', 'VMware.VimAutomation.Vds')) {
    $moduleDir = Join-Path $stubRoot $moduleName
    New-Item -Path $moduleDir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $moduleDir "$moduleName.psd1") -Encoding UTF8 -Value @"
@{ ModuleVersion = '13.0.0'; GUID = '$([guid]::NewGuid())'; FunctionsToExport = @() }
"@
}
$env:PSModulePath = $stubRoot + [System.IO.Path]::PathSeparator + $env:PSModulePath

# ============================================================================
# The fake estate
# ============================================================================

# $global:, not $script:. In a plain script (not a module) $script: resolves
# against the script scope on the CALL STACK, and these stubs are called from
# inside the script under test - so $script:Switches would look for a variable
# in that script and throw under StrictMode.
function New-VlanSpec { param($VlanId) [pscustomobject]@{ VlanId = $VlanId } }

# --- vSphere ----------------------------------------------------------------
$global:PortGroups = @{
    'dvs-mgmt' = @(
        [pscustomobject]@{ Name = 'PG-MGMT'; ExtensionData = [pscustomobject]@{
            Tag = @(); Config = [pscustomobject]@{ Type = 'earlyBinding'
                DefaultPortConfig = [pscustomobject]@{ Vlan = (New-VlanSpec 10) } } } }
        # The uplink port group trunks everything; it must be excluded or every
        # VLAN in the estate is reported as missing.
        [pscustomobject]@{ Name = 'dvs-mgmt-uplinks'; ExtensionData = [pscustomobject]@{
            Tag = @([pscustomobject]@{ Key = 'SYSTEM/DVS.UPLINKPG' })
            Config = [pscustomobject]@{ Type = 'uplinkPortgroup'
                DefaultPortConfig = [pscustomobject]@{ Vlan = (New-VlanSpec 0) } } } }
    )
    'dvs-prod' = @(
        # IP-hash teaming in front of UCS: it needs a port channel to the host,
        # and a blade's two vNICs land on two independent fabric interconnects.
        [pscustomobject]@{ Name = 'PG-PROD'; ExtensionData = [pscustomobject]@{
            Tag = @(); Config = [pscustomobject]@{ Type = 'earlyBinding'
                DefaultPortConfig = [pscustomobject]@{ Vlan = (New-VlanSpec 250)
                    UplinkTeamingPolicy = [pscustomobject]@{
                        Policy = [pscustomobject]@{ Value = 'loadbalance_ip' }
                        NotifySwitches = [pscustomobject]@{ Value = $true }
                        FailureCriteria = [pscustomobject]@{ CheckBeacon = [pscustomobject]@{ Value = $false } } } } } } }
        # VLAN 999 exists in vCenter and is trunked nowhere in UCS.
        [pscustomobject]@{ Name = 'PG-ORPHAN'; ExtensionData = [pscustomobject]@{
            Tag = @(); Config = [pscustomobject]@{ Type = 'earlyBinding'
                DefaultPortConfig = [pscustomobject]@{ Vlan = (New-VlanSpec 999) } } } }
    )
}

function New-VdsView { param($Mtu, $Protocol)
    [pscustomobject]@{ Config = [pscustomobject]@{ MaxMtu = $Mtu
        LinkDiscoveryProtocolConfig = [pscustomobject]@{ Protocol = $Protocol; Operation = 'both' } } } }

$global:Switches = @(
    [pscustomobject]@{ Name = 'dvs-mgmt'; ExtensionData = (New-VdsView 1500 'cdp') }
    [pscustomobject]@{ Name = 'dvs-prod'; ExtensionData = (New-VdsView 9000 'cdp') }
)

function Connect-VIServer { param($Server, $Credential, $ErrorAction) [pscustomobject]@{ Name = $Server } }
function Disconnect-VIServer { param($Server, $Confirm, $ErrorAction) }
function Get-VDSwitch { param($ErrorAction) return $global:Switches }
function Get-VDPortgroup { param($VDSwitch, $ErrorAction) return $global:PortGroups[$VDSwitch.Name] }
function Get-VMHost {
    @(
        [pscustomobject]@{ Name = 'esx01.example.com'; Id = 'HostSystem-host-1'; ConnectionState = 'Connected'; Parent = 'PRD-CL01' }
        # Same cluster as this domain's blade, no service profile here, and its
        # CDP names a different fabric. A cluster split across two UCS domains
        # is invisible from either one.
        [pscustomobject]@{ Name = 'esx50.example.com'; Id = 'HostSystem-host-50'; ConnectionState = 'Connected'; Parent = 'PRD-CL01' }
    )
}

# CDP on vmnic0 only, reporting fabric A. The script must reduce that to the
# UCS Manager cluster name on its own.
$global:Hints = @{
    'vmnic0' = [pscustomobject]@{
        ConnectedSwitchPort = [pscustomobject]@{ SystemName = 'ucs01-A.example.com(FD0261301D1)'; DevId = 'ucs01-A'; PortId = 'Eth1/1' }
        LldpInfo = $null
    }
}

function Get-View {
    param($Id, $ErrorAction)
    if ("$Id" -eq 'network-50') {
        return ([pscustomobject]@{ } | Add-Member -MemberType ScriptMethod -Name QueryNetworkHint -Value {
            param($device)
            return @([pscustomobject]@{
                ConnectedSwitchPort = [pscustomobject]@{ SystemName = 'ucs02-A.example.com'; DevId = 'ucs02-A'; PortId = 'Eth1/1' }
                LldpInfo = $null })
        } -PassThru)
    }
    if ("$Id" -like 'network-*') {
        return ([pscustomobject]@{ } | Add-Member -MemberType ScriptMethod -Name QueryNetworkHint -Value {
            param($device)
            if (-not $global:Hints.ContainsKey($device)) { return @() }
            return @($global:Hints[$device])
        } -PassThru)
    }
    if ("$Id" -eq 'HostSystem-host-50') {
        return [pscustomobject]@{
            ConfigManager = [pscustomobject]@{ NetworkSystem = 'network-50' }
            Hardware = [pscustomobject]@{ SystemInfo = [pscustomobject]@{ Uuid = 'bbbbbbbb-0000-0000-0000-000000000050' } }
            Config = [pscustomobject]@{ Network = [pscustomobject]@{
                Pnic = @([pscustomobject]@{ Device = 'vmnic0' }); ProxySwitch = @() } }
        }
    }
    return [pscustomobject]@{
        ConfigManager = [pscustomobject]@{ NetworkSystem = 'network-1' }
        Hardware = [pscustomobject]@{ SystemInfo = [pscustomobject]@{ Uuid = 'aaaaaaaa-0000-0000-0000-000000000001' } }
        Config = [pscustomobject]@{ Network = [pscustomobject]@{
            Pnic = @('vmnic0', 'vmnic1', 'vmnic2', 'vmnic3' | ForEach-Object { [pscustomobject]@{ Device = $_ } })
            ProxySwitch = @(
                [pscustomobject]@{ DvsName = 'dvs-mgmt'; Pnic = @('key-vim.host.PhysicalNic-vmnic0', 'key-vim.host.PhysicalNic-vmnic1') }
                [pscustomobject]@{ DvsName = 'dvs-prod'; Pnic = @('key-vim.host.PhysicalNic-vmnic2', 'key-vim.host.PhysicalNic-vmnic3') }
            )
        } }
    }
}

# --- UCS Manager -------------------------------------------------------------
function Connect-Ucs { param($Name, $Credential, $ErrorAction) [pscustomobject]@{ Ucs = $Name } }
function Disconnect-Ucs { param($Ucs, $ErrorAction) }

function Get-UcsVlan { param($Ucs, $ErrorAction) @(
    [pscustomobject]@{ Name = 'MGMT-10';  Id = 10;   SwitchId = 'dual' }
    [pscustomobject]@{ Name = 'PROD-250'; Id = 250;  SwitchId = 'dual' }
    # The same id under a second name. Both resolve; which one a template got is
    # invisible in UCS Manager.
    [pscustomobject]@{ Name = 'PROD_250'; Id = 250;  SwitchId = 'dual' }
    # And an id that is also a VSAN's FCoE VLAN.
    [pscustomobject]@{ Name = 'STORAGE';  Id = 4048; SwitchId = 'dual' }
    # Created on the fabric and never added to a template: the network half of a
    # change that was never finished on the server side.
    [pscustomobject]@{ Name = 'SPARE-777'; Id = 777; SwitchId = 'dual' }
) }
function Get-UcsVsan { param($Ucs, $ErrorAction) @([pscustomobject]@{ Name = 'VSAN-A'; Id = 100; FcoeVlan = 4048 }) }

function New-Template { param($Name, $SwitchId, $Mtu, $Ncp, $TemplType = 'updating-template', $Qos = 'BestEffort')
    [pscustomobject]@{ Dn = "org-root/lan-conn-templ-$Name"; Name = $Name; SwitchId = $SwitchId
        Mtu = $Mtu; TemplType = $TemplType; NwCtrlPolicyName = $Ncp
        QosPolicyName = $Qos; AdaptorProfileName = 'VMWare' } }

# The QoS side of the MTU question: eth2/eth3 are 9000 but BestEffort lands in a
# system class still at 1500, so their jumbo frames are dropped silently.
function Get-UcsQosPolicy { param($Ucs, $ErrorAction) @(
    [pscustomobject]@{ Name = 'BestEffort'; Dn = 'org-root/ep-qos-BestEffort' }
) }
function Get-UcsVnicEgressPolicy { param($Ucs, $ErrorAction) @(
    [pscustomobject]@{ Dn = 'org-root/ep-qos-BestEffort/egress'; Prio = 'best-effort' }
) }
function Get-UcsQosClass { param($Ucs, $ErrorAction) @(
    [pscustomobject]@{ Priority = 'best-effort'; Mtu = 'normal'; AdminState = 'enabled' }
) }

function Get-UcsVnicTemplate { param($Ucs, $ErrorAction) @(
    (New-Template 'eth0-tmpl' 'A' '1500' 'CDP-OFF')
    (New-Template 'eth1-tmpl' 'B' '1500' 'CDP-OFF')
    (New-Template 'eth2-tmpl' 'A' '9000' 'CDP-ON')
    # Fabric A again: the pair is not a pair, and nothing in vCenter shows it.
    (New-Template 'eth3-tmpl' 'A' '9000' 'CDP-ON')
    # A pair with nothing wrong with it, so there is something for the clean
    # path to record. Not in the ProxySwitch map, so no vDS cross-check.
    (New-Template 'eth4-tmpl' 'A' '9000' 'CDP-ON')
    (New-Template 'eth5-tmpl' 'B' '9000' 'CDP-ON')
) }

function New-Vnic { param($Name, $Order, $Template)
    [pscustomobject]@{ Dn = "org-root/ls-esx01/ether-$Name"; Name = $Name; Order = $Order
        NwTemplName = $Template; Mtu = '0'; SwitchId = '' } }

function Get-UcsVnic { param($Ucs, $ErrorAction) @(
    (New-Vnic 'eth0' '1' 'eth0-tmpl')
    (New-Vnic 'eth1' '2' 'eth1-tmpl')
    (New-Vnic 'eth2' '3' 'eth2-tmpl')
    (New-Vnic 'eth3' '4' 'eth3-tmpl')
    (New-Vnic 'eth4' '5' 'eth4-tmpl')
    (New-Vnic 'eth5' '6' 'eth5-tmpl')
) }

function New-Interface { param($Parent, $Name, $Vnet, $Native = 'no')
    [pscustomobject]@{ Dn = "$Parent/if-$Name"; Name = $Name; Vnet = $Vnet; DefaultNet = $Native } }

# The real cmdlet returns every vnicEtherIf in the domain - the rows below the
# templates AND the rows below each service profile's vNICs - so both are here.
function Get-UcsVnicInterface { param($Ucs, $ErrorAction) @(
    # --- below the templates ---
    (New-Interface 'org-root/lan-conn-templ-eth0-tmpl' 'MGMT-10' 10 'yes')
    (New-Interface 'org-root/lan-conn-templ-eth0-tmpl' 'PROD-250' 250)
    (New-Interface 'org-root/lan-conn-templ-eth1-tmpl' 'MGMT-10' 10 'yes')
    (New-Interface 'org-root/lan-conn-templ-eth2-tmpl' 'PROD-250' 250)
    # eth2's template has a VLAN the blade does not: an initial-template edited
    # after the profile was stamped looks right in UCS Manager and is not right
    # on the blade.
    (New-Interface 'org-root/lan-conn-templ-eth2-tmpl' 'MGMT-10' 10)
    (New-Interface 'org-root/lan-conn-templ-eth3-tmpl' 'PROD-250' 250)
    (New-Interface 'org-root/lan-conn-templ-eth4-tmpl' 'PROD-250' 250)
    (New-Interface 'org-root/lan-conn-templ-eth5-tmpl' 'PROD-250' 250)

    # --- below the service profile's vNICs ---
    # eth0 carries MGMT and PROD; eth1, its partner, is missing PROD.
    (New-Interface 'org-root/ls-esx01/ether-eth0' 'MGMT-10' 10 'yes')
    (New-Interface 'org-root/ls-esx01/ether-eth0' 'PROD-250' 250)
    (New-Interface 'org-root/ls-esx01/ether-eth1' 'MGMT-10' 10 'yes')
    (New-Interface 'org-root/ls-esx01/ether-eth2' 'PROD-250' 250)
    (New-Interface 'org-root/ls-esx01/ether-eth3' 'PROD-250' 250)
    (New-Interface 'org-root/ls-esx01/ether-eth4' 'PROD-250' 250)
    (New-Interface 'org-root/ls-esx01/ether-eth5' 'PROD-250' 250)
) }

function Get-UcsNetworkControlPolicy { param($Ucs, $ErrorAction) @(
    # dvs-mgmt is set to CDP and this is what sits behind it.
    # Uplink fail set to 'warning': the vNIC stays up when the fabric loses its
    # uplinks and ESXi never fails over. The worst thing in this estate.
    [pscustomobject]@{ Name = 'CDP-OFF'; Cdp = 'disabled'; LldpTransmit = 'disabled'; LldpReceive = 'disabled'
        UplinkFailAction = 'warning'; MacRegisterMode = 'only-native-vlan' }
    [pscustomobject]@{ Name = 'CDP-ON';  Cdp = 'enabled';  LldpTransmit = 'enabled';  LldpReceive = 'enabled'
        UplinkFailAction = 'link-down'; MacRegisterMode = 'all-host-vlans' }
) }

function Get-UcsServiceProfile { param($Ucs, $ErrorAction) @(
    [pscustomobject]@{ Name = 'esx01'; Dn = 'org-root/ls-esx01'; Uuid = 'aaaaaaaa-0000-0000-0000-000000000001'
        AssocState = 'associated'; OperSrcTemplName = 'org-root/ls-PRD-TMPL' }
    # Associated, so it is a real blade - but nothing in this vCenter runs it.
    # Starting from vCenter, this profile would simply never be looked at.
    [pscustomobject]@{ Name = 'esx99'; Dn = 'org-root/ls-esx99'; Uuid = 'aaaaaaaa-0000-0000-0000-000000000099'
        AssocState = 'associated'; OperSrcTemplName = '' }
    [pscustomobject]@{ Name = 'spare01'; Dn = 'org-root/ls-spare01'; Uuid = ''
        AssocState = 'unassociated'; OperSrcTemplName = 'org-root/ls-PRD-TMPL' }
) }

# ============================================================================
# Run it
# ============================================================================

$credential = [pscredential]::new('EXAMPLE\svc-automation', (ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force))

Write-Host "`n=== Running the script against the fake estate ===" -ForegroundColor Cyan
$findings = @()
try {
    $findings = @(& $scriptPath -UcsManager 'ucs01.example.com' -VIServer 'vcenter01.example.com' `
        -Credential $credential -IncludeInformational 6>$null 3>$null)
}
catch {
    Write-Host "  The script threw: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    $script:fail++
}

function Get-Check { param($Check) ,@($findings | Where-Object { $_.Check -eq $Check }) }

Write-Host "`n=== It reached the fabric at all ===" -ForegroundColor Cyan
Assert-Equal 'findings were returned'          $true ($findings.Count -gt 0)
# If discovery or the sign-in had failed, these would be the only findings and
# every assertion below would pass vacuously.
Assert-Equal 'the UCS domain was identified'   0 (Get-Check 'DomainUnreachable').Count
Assert-Equal 'CDP identified the domain'       0 (Get-Check 'NoDiscoveryNeighbour').Count
Assert-Equal 'the host matched its profile'    0 (Get-Check 'NoServiceProfile').Count
Assert-Equal 'the domain name was normalised'  'ucs01.example.com' @($findings | Where-Object { $_.Domain })[0].Domain

Write-Host "`n=== VLAN definitions ===" -ForegroundColor Cyan
Assert-Equal 'the duplicated VLAN id is found'  1 (Get-Check 'VlanIdDefinedTwice').Count
Assert-Equal 'the FCoE collision is found'      1 (Get-Check 'VlanFcoeCollision').Count

Write-Host "`n=== vNIC pairs ===" -ForegroundColor Cyan
Assert-Equal 'eth1 is reported as missing a VLAN' 1 (Get-Check 'VnicPairVlanMismatch').Count
Assert-Equal 'and it names eth1'                  $true ((Get-Check 'VnicPairVlanMismatch')[0].Detail -match 'eth1')
Assert-Equal 'and VLAN 250'                       $true ((Get-Check 'VnicPairVlanMismatch')[0].Detail -match '250')
Assert-Equal 'eth2/eth3 on one fabric is found'   1 (Get-Check 'VnicPairSameFabric').Count
Assert-Equal 'and it names the pair'              'eth2/eth3' (Get-Check 'VnicPairSameFabric')[0].Subject

Write-Host "`n=== Drift from a vNIC's own template ===" -ForegroundColor Cyan
# Exactly one vNIC has been given a template that no longer matches it. Reporting
# more than one would mean the check is measuring "the template rows were not
# read" rather than drift.
Assert-Equal 'exactly one vNIC is reported as drifted' 1 (Get-Check 'VnicDivergedFromTemplate').Count
Assert-Equal 'and it is eth2'                          'eth2' (Get-Check 'VnicDivergedFromTemplate')[0].Subject

Write-Host "`n=== The vCenter cross-check ===" -ForegroundColor Cyan
Assert-Equal 'PG-ORPHAN is reported'            1 (Get-Check 'PortGroupVlanNotTrunked').Count
Assert-Equal 'against dvs-prod'                 'dvs-prod / PG-ORPHAN' (Get-Check 'PortGroupVlanNotTrunked')[0].Subject
# dvs-mgmt is MTU 1500 over vNICs at 1500, and dvs-prod is 9000 over vNICs at
# 9000. Neither should be reported, or the check is measuring the wrong pair.
Assert-Equal 'no false MTU finding'             0 (Get-Check 'VdsMtuExceedsVnicMtu').Count
# The uplink port group trunks nothing in particular and must not be measured.
Assert-Equal 'the uplink port group was skipped' $false ([bool]@($findings | Where-Object { $_.Subject -match 'uplinks' }).Count)

Write-Host "`n=== The UCS-first pivot: the profiles are the inventory ===" -ForegroundColor Cyan
# esx99 is an associated blade whose host is in no vCenter this run can see.
# Starting from vCenter, it would simply never have been looked at.
Assert-Equal 'a profile with no host is reported'   1 (Get-Check 'ProfileHasNoHost').Count
Assert-Equal 'and it names the profile'             'esx99' (Get-Check 'ProfileHasNoHost')[0].Subject
# An unassociated profile has no blade to check, which is context, not a fault.
Assert-Equal 'an unassociated profile is only INFO' 'INFO' (Get-Check 'ProfileUnassociated')[0].Severity
Assert-Equal 'and it names that profile'            'spare01' (Get-Check 'ProfileUnassociated')[0].Subject
# esx50 shares a cluster with this domain's blade but is cabled to another
# fabric. Neither domain shows the other half of a cluster split this way.
Assert-Equal 'a host of another domain in the same cluster' 1 (Get-Check 'HostInAnotherDomain').Count
Assert-Equal 'and it names the other fabric'        $true ((Get-Check 'HostInAnotherDomain')[0].Actual -match 'ucs02')

Write-Host "`n=== Best practice, and kept apart from the mismatches ===" -ForegroundColor Cyan
# The worst thing in the estate: the vNIC stays up when the fabric loses its
# uplinks, so ESXi never fails over and nothing alarms.
Assert-Equal 'the uplink fail action is reported'  1 (Get-Check 'NcpUplinkFailAction').Count
Assert-Equal 'as an error'                         'ERROR' (Get-Check 'NcpUplinkFailAction')[0].Severity
Assert-Equal 'and categorised as best practice'    'BestPractice' (Get-Check 'NcpUplinkFailAction')[0].Category
Assert-Equal 'MAC register mode is reported'       1 (Get-Check 'NcpMacRegisterMode').Count
# 9000 on the vNIC, 1500 on the class its QoS policy lands in.
Assert-Equal 'the QoS class MTU trap is reported'  4 (Get-Check 'VnicMtuExceedsQosClass').Count
Assert-Equal 'and not for the 1500 vNICs'          $false ([bool]@((Get-Check 'VnicMtuExceedsQosClass') | Where-Object { $_.Subject -in @('eth0', 'eth1') }).Count)
Assert-Equal 'IP-hash teaming is reported'         1 (Get-Check 'PortGroupIpHashTeaming').Count
Assert-Equal 'a hand-built profile is reported'    1 (Get-Check 'ProfileNotFromTemplate').Count
# The two kinds must be separable, or the report cannot be triaged.
Assert-Equal 'mismatches are categorised apart'    $true (@($findings | Where-Object { $_.Category -eq 'Consistency' }).Count -gt 0)
Assert-Equal 'and so are the recommendations'      $true (@($findings | Where-Object { $_.Category -eq 'BestPractice' }).Count -gt 0)

Write-Host "`n=== VLANs the fabric carries that no vNIC template uses ===" -ForegroundColor Cyan
# Three VLANs exist on this fabric that no template carries: the deliberate
# SPARE-777, the STORAGE VLAN that also collides with FCoE, and PROD_250 - the
# second name for id 250, which is exactly the signal that says which of the two
# duplicate names is the one nothing is actually using.
$unassigned = @((Get-Check 'VlanNotOnAnyVnicTemplate') | ForEach-Object { $_.Subject } | Sort-Object)
Assert-Equal 'every unused fabric VLAN is reported' 3 $unassigned.Count
Assert-Equal 'and they are the right three'         'PROD_250 (250); SPARE-777 (777); STORAGE (4048)' ($unassigned -join '; ')
# STORAGE is on no template either, but it is the FCoE collision VLAN and is
# already reported as an error; both are true and both are reported.
Assert-Equal 'a VLAN that IS on a template is not' $false ([bool]@((Get-Check 'VlanNotOnAnyVnicTemplate') | Where-Object { $_.Subject -match 'PROD-250' }).Count)

Write-Host "`n=== Checks that ran clean are recorded, not just omitted ===" -ForegroundColor Cyan
Assert-Equal 'the clean vNIC pair is recorded'  1     (Get-Check 'VnicPair').Count
Assert-Equal 'and it is eth4/eth5'              'eth4/eth5' (Get-Check 'VnicPair')[0].Subject
Assert-Equal 'and it is an OK row'              'OK'  (Get-Check 'VnicPair')[0].Severity
# eth0/eth1 has a VLAN mismatch and eth2/eth3 is on one fabric, so neither may
# be recorded as clean - an OK row on a pair that failed would be worse than no
# row at all.
Assert-Equal 'no OK row for the mismatched pair' $false ([bool]@((Get-Check 'VnicPair') | Where-Object { $_.Subject -eq 'eth0/eth1' }).Count)
Assert-Equal 'no OK row for the same-fabric pair' $false ([bool]@((Get-Check 'VnicPair') | Where-Object { $_.Subject -eq 'eth2/eth3' }).Count)
# dvs-prod has an untrunked port group; dvs-mgmt does not.
Assert-Equal 'dvs-mgmt coverage is recorded clean' $true ([bool]@((Get-Check 'VdsVlanCoverage') | Where-Object { $_.Subject -eq 'dvs-mgmt' }).Count)
Assert-Equal 'dvs-prod coverage is not'            $false ([bool]@((Get-Check 'VdsVlanCoverage') | Where-Object { $_.Subject -eq 'dvs-prod' }).Count)
# The VLAN table has a duplicate id and an FCoE collision, so it is not clean.
Assert-Equal 'the VLAN table is not recorded clean' 0 (Get-Check 'VlanDefinitions').Count

Write-Host "`n=== Discovery protocol ===" -ForegroundColor Cyan
# dvs-mgmt is set to CDP; eth0 and eth1 sit behind CDP-OFF. This is the fault
# that hides every other fault.
Assert-Equal 'CDP disabled under a CDP vDS is found' 2 (Get-Check 'CdpDisabledOnUcs').Count
Assert-Equal 'and not for the vDS whose policy has CDP on' $false ([bool]@((Get-Check 'CdpDisabledOnUcs') | Where-Object { $_.Subject -match 'dvs-prod' }).Count)

Write-Host "`n=== The report itself ===" -ForegroundColor Cyan
# A cross-check row is about a host and must name it - except the one that
# exists precisely because there is no host to name.
Assert-Equal 'every cross-check row names its host' $true (-not [bool]@($findings | Where-Object { $_.Scope -eq 'CrossCheck' -and $_.Check -ne 'ProfileHasNoHost' -and $_.HostCount -eq 0 }).Count)
Assert-Equal 'every row carries a PASS/REVIEW status'  $true (-not [bool]@($findings | Where-Object { $_.Status -notin @('PASS', 'REVIEW', 'NOTE') }).Count)
Assert-Equal 'severities are the expected set' $true (-not [bool]@($findings | Where-Object { $_.Severity -notin @('ERROR', 'WARN', 'INFO', 'OK') }).Count)

Write-Host "`n=== The -ServiceProfile and -CsvPath paths ===" -ForegroundColor Cyan
# Neither is exercised by the run above, and both are the sort of thing that only
# fails once someone is actually using it: the profile filter has to survive
# wildcards, and the CSV export has to flatten the per-finding host list.
$csvPath = Join-Path ([System.IO.Path]::GetTempPath()) ('richo-vlan-' + [guid]::NewGuid().ToString('N') + '.csv')
$filtered = @()
try {
    $filtered = @(& $scriptPath -UcsManager 'ucs01.example.com' -VIServer 'vcenter01.example.com' `
        -Credential $credential -ServiceProfile 'esx*' -CsvPath $csvPath 6>$null 3>$null)
    Assert-Equal 'the profile filter still finds the faults' $true ($filtered.Count -gt 0)
    # -IncludeInformational was not passed this time.
    Assert-Equal 'INFO findings are withheld by default'     0 @($filtered | Where-Object { $_.Severity -eq 'INFO' }).Count
    # The clean rows are the point of the CSV: a fault list alone cannot be told
    # apart from a run where the check never happened.
    Assert-Equal 'clean checks are still reported'           $true (@($filtered | Where-Object { $_.Severity -eq 'OK' }).Count -gt 0)
    Assert-Equal 'the CSV was written'                       $true (Test-Path $csvPath)
    $fromCsv = @(Import-Csv -Path $csvPath)
    Assert-Equal 'and holds every returned finding'          $filtered.Count $fromCsv.Count
    $withHosts = @($fromCsv | Where-Object { [int]$_.HostCount -gt 0 })
    Assert-Equal 'per-host rows survive the round trip'      $true ($withHosts.Count -gt 0)
    Assert-Equal 'with the host list flattened to text'      'esx01.example.com' $withHosts[0].Hosts
    Assert-Equal 'and the category column is populated'      $true (-not [bool]@($fromCsv | Where-Object { $_.Category -notin @('Consistency', 'BestPractice') }).Count)
}
catch {
    Write-Host "  The -Cluster/-CsvPath run threw: $($_.Exception.Message)" -ForegroundColor Red
    $script:fail++
}
finally {
    Remove-Item -Path $csvPath -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=== -SkipBestPractice ===" -ForegroundColor Cyan
try {
    $consistencyOnly = @(& $scriptPath -UcsManager 'ucs01.example.com' -VIServer 'vcenter01.example.com' `
        -Credential $credential -SkipBestPractice 6>$null 3>$null)
    Assert-Equal 'the mismatches are still found' $true (@($consistencyOnly | Where-Object { $_.Category -eq 'Consistency' }).Count -gt 0)
    Assert-Equal 'and no best-practice row is emitted' 0 @($consistencyOnly | Where-Object { $_.Category -eq 'BestPractice' }).Count
}
catch {
    Write-Host "  The -SkipBestPractice run threw: $($_.Exception.Message)" -ForegroundColor Red
    $script:fail++
}

Remove-Item -Path $stubRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
