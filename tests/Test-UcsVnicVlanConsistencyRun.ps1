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
        [pscustomobject]@{ Name = 'PG-PROD'; ExtensionData = [pscustomobject]@{
            Tag = @(); Config = [pscustomobject]@{ Type = 'earlyBinding'
                DefaultPortConfig = [pscustomobject]@{ Vlan = (New-VlanSpec 250) } } } }
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
function Get-Cluster { param($Name, $ErrorAction) [pscustomobject]@{ Name = 'PRD-CL01' } }
# Takes pipeline input because the -Cluster path is 'Get-Cluster | Get-VMHost'.
function Get-VMHost {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$Cluster)
    process { [pscustomobject]@{ Name = 'esx01.example.com'; Id = 'HostSystem-host-1'; ConnectionState = 'Connected' } }
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
    if ("$Id" -like 'network-*') {
        return ([pscustomobject]@{ } | Add-Member -MemberType ScriptMethod -Name QueryNetworkHint -Value {
            param($device)
            if (-not $global:Hints.ContainsKey($device)) { return @() }
            return @($global:Hints[$device])
        } -PassThru)
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
) }
function Get-UcsVsan { param($Ucs, $ErrorAction) @([pscustomobject]@{ Name = 'VSAN-A'; Id = 100; FcoeVlan = 4048 }) }

function New-Template { param($Name, $SwitchId, $Mtu, $Ncp)
    [pscustomobject]@{ Dn = "org-root/lan-conn-templ-$Name"; Name = $Name; SwitchId = $SwitchId
        Mtu = $Mtu; TemplType = 'updating-template'; NwCtrlPolicyName = $Ncp
        QosPolicyName = 'best-effort'; AdaptorProfileName = 'VMWare' } }

function Get-UcsVnicTemplate { param($Ucs, $ErrorAction) @(
    (New-Template 'eth0-tmpl' 'A' '1500' 'CDP-OFF')
    (New-Template 'eth1-tmpl' 'B' '1500' 'CDP-OFF')
    (New-Template 'eth2-tmpl' 'A' '9000' 'CDP-ON')
    # Fabric A again: the pair is not a pair, and nothing in vCenter shows it.
    (New-Template 'eth3-tmpl' 'A' '9000' 'CDP-ON')
) }

function New-Vnic { param($Name, $Order, $Template)
    [pscustomobject]@{ Dn = "org-root/ls-esx01/ether-$Name"; Name = $Name; Order = $Order
        NwTemplName = $Template; Mtu = '0'; SwitchId = '' } }

function Get-UcsVnic { param($Ucs, $ErrorAction) @(
    (New-Vnic 'eth0' '1' 'eth0-tmpl')
    (New-Vnic 'eth1' '2' 'eth1-tmpl')
    (New-Vnic 'eth2' '3' 'eth2-tmpl')
    (New-Vnic 'eth3' '4' 'eth3-tmpl')
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

    # --- below the service profile's vNICs ---
    # eth0 carries MGMT and PROD; eth1, its partner, is missing PROD.
    (New-Interface 'org-root/ls-esx01/ether-eth0' 'MGMT-10' 10 'yes')
    (New-Interface 'org-root/ls-esx01/ether-eth0' 'PROD-250' 250)
    (New-Interface 'org-root/ls-esx01/ether-eth1' 'MGMT-10' 10 'yes')
    (New-Interface 'org-root/ls-esx01/ether-eth2' 'PROD-250' 250)
    (New-Interface 'org-root/ls-esx01/ether-eth3' 'PROD-250' 250)
) }

function Get-UcsNetworkControlPolicy { param($Ucs, $ErrorAction) @(
    # dvs-mgmt is set to CDP and this is what sits behind it.
    [pscustomobject]@{ Name = 'CDP-OFF'; Cdp = 'disabled'; LldpTransmit = 'disabled'; LldpReceive = 'disabled' }
    [pscustomobject]@{ Name = 'CDP-ON';  Cdp = 'enabled';  LldpTransmit = 'enabled';  LldpReceive = 'enabled' }
) }

function Get-UcsServiceProfile { param($Ucs, $ErrorAction) @(
    [pscustomobject]@{ Name = 'esx01'; Dn = 'org-root/ls-esx01'; Uuid = 'aaaaaaaa-0000-0000-0000-000000000001' }
) }

# ============================================================================
# Run it
# ============================================================================

$credential = [pscredential]::new('EXAMPLE\svc-automation', (ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force))

Write-Host "`n=== Running the script against the fake estate ===" -ForegroundColor Cyan
$findings = @()
try {
    $findings = @(& $scriptPath -VIServer 'vcenter01.example.com' -Credential $credential -IncludeInformational 6>$null 3>$null)
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

Write-Host "`n=== Discovery protocol ===" -ForegroundColor Cyan
# dvs-mgmt is set to CDP; eth0 and eth1 sit behind CDP-OFF. This is the fault
# that hides every other fault.
Assert-Equal 'CDP disabled under a CDP vDS is found' 2 (Get-Check 'CdpDisabledOnUcs').Count
Assert-Equal 'and not for the vDS whose policy has CDP on' $false ([bool]@((Get-Check 'CdpDisabledOnUcs') | Where-Object { $_.Subject -match 'dvs-prod' }).Count)

Write-Host "`n=== The report itself ===" -ForegroundColor Cyan
Assert-Equal 'every finding names the host' $true (-not [bool]@($findings | Where-Object { $_.Scope -ne 'UCS' -and $_.HostCount -eq 0 }).Count)
Assert-Equal 'severities are the expected set' $true (-not [bool]@($findings | Where-Object { $_.Severity -notin @('ERROR', 'WARN', 'INFO') }).Count)

Write-Host "`n=== The -Cluster and -CsvPath paths ===" -ForegroundColor Cyan
# Neither is exercised by the run above, and both are the sort of thing that only
# fails once someone is actually using it: the cluster filter pipes Get-Cluster
# into Get-VMHost, and the CSV export has to flatten the per-finding host list.
$csvPath = Join-Path ([System.IO.Path]::GetTempPath()) ('richo-vlan-' + [guid]::NewGuid().ToString('N') + '.csv')
$filtered = @()
try {
    $filtered = @(& $scriptPath -VIServer 'vcenter01.example.com' -Credential $credential -Cluster 'PRD-CL01' -CsvPath $csvPath 6>$null 3>$null)
    Assert-Equal 'the cluster filter still finds the faults' $true ($filtered.Count -gt 0)
    # -IncludeInformational was not passed this time.
    Assert-Equal 'INFO findings are withheld by default'     0 @($filtered | Where-Object { $_.Severity -eq 'INFO' }).Count
    Assert-Equal 'the CSV was written'                       $true (Test-Path $csvPath)
    $fromCsv = @(Import-Csv -Path $csvPath)
    Assert-Equal 'and holds every returned finding'          $filtered.Count $fromCsv.Count
    Assert-Equal 'with the host list flattened to text'      'esx01.example.com' $fromCsv[0].Hosts
}
catch {
    Write-Host "  The -Cluster/-CsvPath run threw: $($_.Exception.Message)" -ForegroundColor Red
    $script:fail++
}
finally {
    Remove-Item -Path $csvPath -Force -ErrorAction SilentlyContinue
}

Remove-Item -Path $stubRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
