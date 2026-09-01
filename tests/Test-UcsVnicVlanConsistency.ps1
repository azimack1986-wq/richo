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
    'Test-UcsVlanAssignment',
    'Get-VlanSummary', 'Get-VnicOrdinal', 'Get-VnicOrdinalMap', 'ConvertTo-OrdinalGroup',
    'Compare-VnicGroup', 'ConvertTo-VlanIdList', 'Test-UplinkPortGroup', 'Get-HostUplinkMap',
    'Get-VdsDiscoveryProtocol', 'Compare-VdsVlanCoverage', 'Get-LldpSystemName',
    'Remove-UcsTargetDecoration', 'Convert-FiSystemNameToUcsCandidate', 'Get-ParentDn',
    'ConvertTo-PolicyName', 'Get-VnicMemberDetail', 'Get-QosClassMtu',
    'Test-NetworkControlPolicyBestPractice', 'Test-VnicBestPractice',
    'Test-PortGroupBestPractice', 'Test-VdsBestPractice', 'Test-ServiceProfileBestPractice',
    'Test-VnicNativeVlan', 'Compare-VdsObservedVlan', 'Test-VnicTemplateBinding',
    'Test-VnicFabricAssignment'
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
          $Ncp = 'CDP-ON', $Qos = 'best-effort', $Adapter = 'VMWare', $NativeIds = $null)
    # NativeIds defaults to whatever NativeId says, so the existing pair tests
    # keep meaning what they meant; the native-VLAN tests set it explicitly.
    if ($null -eq $NativeIds) { $NativeIds = @(if ($NativeId -gt 0) { $NativeId } else { }) }
    [pscustomobject]@{
        Ordinal = $Ordinal; VnicName = $VnicName; TemplateName = $TemplateName
        TemplateType = $TemplateType; SwitchId = $SwitchId; Mtu = $Mtu
        VlanIds = @($VlanIds); NativeId = $NativeId; NativeName = ''
        NativeIds = @($NativeIds); NativeNames = @(@($NativeIds) | ForEach-Object { "VL$_" })
        NativeCount = @($NativeIds).Count
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

Write-Host "`n=== VLANs the fabric carries that no vNIC template uses ===" -ForegroundColor Cyan
$fabric = @((New-Vlan 'MGMT-10' 10), (New-Vlan 'PROD-250' 250), (New-Vlan 'ORPHAN-900' 900))

# The half-finished change: the VLAN exists on the fabric and no blade can use it.
$findings = Test-UcsVlanAssignment -Vlan $fabric -TemplateVlanName @('MGMT-10', 'PROD-250') -ProfileVlanName @()
Assert-Equal 'an unused VLAN is reported'      1 (Get-Check $findings 'VlanNotOnAnyVnicTemplate').Count
Assert-Equal 'and it names the VLAN'           'ORPHAN-900 (900)' (Get-Check $findings 'VlanNotOnAnyVnicTemplate')[0].Subject
Assert-Equal 'a VLAN on a template is not'     0 @((Get-Check $findings 'VlanNotOnAnyVnicTemplate') | Where-Object { $_.Subject -match 'MGMT' }).Count

# A VLAN reaching a blade only through a hand-edited service profile is a
# different problem with a different fix, so it is a different finding.
$findings = Test-UcsVlanAssignment -Vlan $fabric -TemplateVlanName @('MGMT-10') -ProfileVlanName @('PROD-250')
Assert-Equal 'a VLAN on a vNIC but no template' 1 (Get-Check $findings 'VlanOnVnicButNoTemplate').Count
Assert-Equal 'and it is INFO, not a warning'    'INFO' (Get-Check $findings 'VlanOnVnicButNoTemplate')[0].Severity
Assert-Equal 'and is not double-reported'       1 (Get-Check $findings 'VlanNotOnAnyVnicTemplate').Count

# VLAN 1 always exists and is almost never on a template on purpose. Reporting it
# every run is how the rest of the list stops being read.
Assert-Equal 'VLAN 1 is skipped' 0 (Get-Check (Test-UcsVlanAssignment -Vlan @((New-Vlan 'default' 1)) -TemplateVlanName @() -ProfileVlanName @()) 'VlanNotOnAnyVnicTemplate').Count

# A domain commonly defines far more VLANs than one set of templates carries.
$many = @(1..40 | ForEach-Object { New-Vlan "VL$_" (100 + $_) })
$findings = Test-UcsVlanAssignment -Vlan $many -TemplateVlanName @() -ProfileVlanName @() -MaxIndividual 25
Assert-Equal 'past the threshold they roll up into one' 1 (Get-Check $findings 'VlanNotOnAnyVnicTemplate').Count
Assert-Equal 'and the one names the count'              '40 VLANs' (Get-Check $findings 'VlanNotOnAnyVnicTemplate')[0].Subject
Assert-Equal 'below it they are listed individually'    40 (Get-Check (Test-UcsVlanAssignment -Vlan $many -TemplateVlanName @() -ProfileVlanName @() -MaxIndividual 100) 'VlanNotOnAnyVnicTemplate').Count

Assert-Equal 'a fully used fabric is clean' 0 @(Test-UcsVlanAssignment -Vlan $fabric -TemplateVlanName @('MGMT-10', 'PROD-250', 'ORPHAN-900') -ProfileVlanName @()).Count

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
Assert-Equal 'and exactly one is native'   1         $summary.NativeCount

# Keeping only the last row marked native would reduce two natives to one and
# report the misconfiguration as correct.
$twoNative = @{ 'p' = @(
    [pscustomobject]@{ Name = 'MGMT-10'; Vnet = 10; DefaultNet = 'yes' }
    [pscustomobject]@{ Name = 'PROD-250'; Vnet = 250; DefaultNet = 'yes' }
) }
$summary = Get-VlanSummary -ParentDn 'p' -InterfaceIndex $twoNative -VlanIdByName @{}
Assert-Equal 'both natives are kept'       2 $summary.NativeCount
Assert-Equal 'and both ids are returned'   '10, 250' ($summary.NativeIds -join ', ')

$noNative = @{ 'p' = @([pscustomobject]@{ Name = 'PROD-250'; Vnet = 250; DefaultNet = 'no' }) }
Assert-Equal 'no native is a count of zero' 0 (Get-VlanSummary -ParentDn 'p' -InterfaceIndex $noNative -VlanIdByName @{}).NativeCount

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

# Template binding moved out of the pair comparison: there it only fired when
# one leg had a template and the other did not, and said nothing at all about a
# profile whose vNICs were ALL built by hand - the worst case.
$untemplated = @(
    (New-Member 0 'eth0' @(10) 'A' 9000 0 'tmpl-a')
    (New-Member 1 'eth1' @(10) 'B' 9000 0 '')
)
Assert-Equal 'the pair check no longer claims this' 0 (Get-Check (Compare-VnicGroup -Member $untemplated) 'VnicNotTemplated').Count

Write-Host "`n=== Even vNICs on fabric A, odd on fabric B ===" -ForegroundColor Cyan
Assert-Equal 'eth0 on A is correct' 0 @(Test-VnicFabricAssignment -Member (New-Member 0 'eth0' @(10) 'A')).Count
Assert-Equal 'eth1 on B is correct' 0 @(Test-VnicFabricAssignment -Member (New-Member 1 'eth1' @(10) 'B')).Count
Assert-Equal 'eth4 on A is correct' 0 @(Test-VnicFabricAssignment -Member (New-Member 4 'eth4' @(10) 'A')).Count
Assert-Equal 'eth5 on B is correct' 0 @(Test-VnicFabricAssignment -Member (New-Member 5 'eth5' @(10) 'B')).Count

$findings = @(Test-VnicFabricAssignment -Member (New-Member 0 'eth0' @(10) 'B'))
Assert-Equal 'an even vNIC on B is reported' 1 (Get-Check $findings 'VnicWrongFabric').Count
Assert-Equal 'and it says which is expected' 'fabric A' (Get-Check $findings 'VnicWrongFabric')[0].Expected
Assert-Equal 'as a mismatch'                 'Consistency' (Get-Check $findings 'VnicWrongFabric')[0].Category
Assert-Equal 'an odd vNIC on A is reported'  1 (Get-Check (Test-VnicFabricAssignment -Member (New-Member 3 'eth3' @(10) 'A')) 'VnicWrongFabric').Count

# THE CASE THE PAIR CHECK CANNOT SEE. Reversed but still split across both
# fabrics: redundant, breaks nothing, and every "vmnic0 is fabric A" runbook is
# wrong on this blade.
$reversed = @(
    (New-Member 0 'eth0' @(10) 'B')
    (New-Member 1 'eth1' @(10) 'A')
)
Assert-Equal 'the pair check passes a reversed pair' 0 (Get-Check (Compare-VnicGroup -Member $reversed) 'VnicPairSameFabric').Count
Assert-Equal 'and this one catches both legs'        2 @(
    @(Test-VnicFabricAssignment -Member $reversed[0]) + @(Test-VnicFabricAssignment -Member $reversed[1])).Count

# Fabric failover ids are judged on their primary fabric; whether failover
# should be on at all is a separate finding.
Assert-Equal "'A-B' on an even vNIC is correct"  0 @(Test-VnicFabricAssignment -Member (New-Member 0 'eth0' @(10) 'A-B')).Count
Assert-Equal "'B-A' on an even vNIC is not"      1 (Get-Check (Test-VnicFabricAssignment -Member (New-Member 0 'eth0' @(10) 'B-A')) 'VnicWrongFabric').Count

Assert-Equal 'the convention can be flipped' 0 @(Test-VnicFabricAssignment -Member (New-Member 0 'eth0' @(10) 'B') -EvenFabric 'B').Count
Assert-Equal 'and turned off entirely'       0 @(Test-VnicFabricAssignment -Member (New-Member 0 'eth0' @(10) 'B') -EvenFabric 'None').Count
# Nothing to judge against is not a finding.
Assert-Equal 'a vNIC with no fabric id is skipped' 0 @(Test-VnicFabricAssignment -Member (New-Member 0 'eth0' @(10) '')).Count

Write-Host "`n=== Every vNIC must be bound to a template ===" -ForegroundColor Cyan
Assert-Equal 'a templated vNIC is clean' 0 @(Test-VnicTemplateBinding -Member (New-Member 0 'eth0' @(10) 'A' 9000 0 'eth0-tmpl')).Count

$findings = @(Test-VnicTemplateBinding -Member (New-Member 0 'eth0' @(10) 'A' 9000 0 ''))
Assert-Equal 'an untemplated vNIC is reported'  1 (Get-Check $findings 'VnicNotTemplated').Count
Assert-Equal 'and it names the vNIC'            'eth0' (Get-Check $findings 'VnicNotTemplated')[0].Subject
# It is the mechanism behind most of the drift the rest of the report finds, so
# it is a mismatch rather than a recommendation - and must survive
# -SkipBestPractice, which only drops the BestPractice category.
Assert-Equal 'as a consistency finding'         'Consistency' (Get-Check $findings 'VnicNotTemplated')[0].Category
# Both legs built by hand: the case the old pair-relative check stayed silent on.
Assert-Equal 'both legs untemplated are both reported' 2 @(
    @(Test-VnicTemplateBinding -Member (New-Member 0 'eth0' @(10) 'A' 9000 0 '')) +
    @(Test-VnicTemplateBinding -Member (New-Member 1 'eth1' @(10) 'B' 9000 0 ''))).Count

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

Write-Host "`n=== What the host actually sees arriving - the only runtime evidence ===" -ForegroundColor Cyan
# Configured, trunked and seen: nothing to say.
Assert-Equal 'everything lines up, nothing reported' 0 @(Compare-VdsObservedVlan -VdsName 'dvs-prod' -ObservedVlanId @(10, 250) -RequiredVlanId @(10, 250) -TrunkedVlanId @(10, 250) -Vmnic @('vmnic2', 'vmnic3')).Count

# ARRIVING AND UNUSED. Strong evidence: the frames are on the wire.
$findings = @(Compare-VdsObservedVlan -VdsName 'dvs-prod' -ObservedVlanId @(10, 250, 300) -RequiredVlanId @(10, 250) -TrunkedVlanId @(10, 250, 300))
Assert-Equal 'a VLAN arriving that no port group uses' 1 (Get-Check $findings 'VlanObservedNotOnVds').Count
Assert-Equal 'and it is a warning, not a hint'         'WARN' (Get-Check $findings 'VlanObservedNotOnVds')[0].Severity
Assert-Equal 'and it names the VLAN'                   'dvs-prod / VLAN 300' (Get-Check $findings 'VlanObservedNotOnVds')[0].Subject
# Per VLAN, not per host, so forty hosts seeing the same stray VLAN fold into
# one row rather than forty.
$many = @(Compare-VdsObservedVlan -VdsName 'dvs-prod' -ObservedVlanId @(300, 301) -RequiredVlanId @() -TrunkedVlanId @(300, 301))
Assert-Equal 'one row per VLAN'                        2 (Get-Check $many 'VlanObservedNotOnVds').Count

# ARRIVING BUT NOT IN THE UCS CONFIG: the two readings of the same vNIC
# disagree, and the wire is the one that is not a reading.
$findings = @(Compare-VdsObservedVlan -VdsName 'dvs-prod' -ObservedVlanId @(10, 900) -RequiredVlanId @(10, 900) -TrunkedVlanId @(10))
Assert-Equal 'a VLAN arriving outside the trunk list' 1 (Get-Check $findings 'VlanObservedNotTrunked').Count
# With no UCS side to compare against, that check has nothing to say.
Assert-Equal 'and not claimed when UCS was not read'  0 (Get-Check (Compare-VdsObservedVlan -VdsName 'dvs' -ObservedVlanId @(10, 900) -RequiredVlanId @(10, 900) -TrunkedVlanId @()) 'VlanObservedNotTrunked').Count

# CONFIGURED AND NEVER SEEN. Weak: a quiet VLAN and an undelivered one look
# identical to ESXi, so this must never be an error.
$findings = @(Compare-VdsObservedVlan -VdsName 'dvs-prod' -ObservedVlanId @(10) -RequiredVlanId @(10, 250) -TrunkedVlanId @(10, 250))
Assert-Equal 'a configured VLAN never seen is noted'   1 (Get-Check $findings 'VlanOnVdsNotObserved').Count
Assert-Equal 'as INFO only'                            'INFO' (Get-Check $findings 'VlanOnVdsNotObserved')[0].Severity
Assert-Equal 'and it says why it is weak'              $true ((Get-Check $findings 'VlanOnVdsNotObserved')[0].Detail -match 'quiet VLAN')

# A host with nothing running on it observes nothing. Reporting every VLAN as
# missing there would be worse than useless.
$findings = @(Compare-VdsObservedVlan -VdsName 'dvs-prod' -ObservedVlanId @() -RequiredVlanId @(10, 250) -TrunkedVlanId @(10, 250))
Assert-Equal 'nothing observed says so, once'          1 (Get-Check $findings 'NoVlanObserved').Count
Assert-Equal 'and claims nothing else'                 1 $findings.Count
Assert-Equal 'as INFO'                                 'INFO' (Get-Check $findings 'NoVlanObserved')[0].Severity

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

# A couple of spare VLANs is headroom, not a gap.
Assert-Equal 'a VLAN nobody uses is only INFO' 'INFO' (Get-Check $findings 'TrunkedVlanUnused')[0].Severity

Write-Host "`n=== The gap: what the blade is given against what the vDS uses ===" -ForegroundColor Cyan
# The case nobody sees, because everything works. A vDS using two of the
# twenty-two VLANs its uplinks carry costs broadcast and flood traffic on the
# other twenty, and widens the blast radius of every VLAN change to all of them.
$wide = @(200..220)
$findings = @(Compare-VdsVlanCoverage -VdsName 'dvs-prod' -PortGroup @((New-PortGroup 'PG-250' 'Access' @(250))) -TrunkedVlanId (@(250) + $wide))
Assert-Equal 'a large gap is a warning, not a note' 1 (Get-Check $findings 'VdsVlanGap').Count
Assert-Equal 'and it is a WARN'                     'WARN' (Get-Check $findings 'VdsVlanGap')[0].Severity
Assert-Equal 'and not also reported as headroom'    0 (Get-Check $findings 'TrunkedVlanUnused').Count
# The counts and the proportion are the point - a list of ids alone does not say
# how lopsided it is.
Assert-Equal 'it names the counts'      $true ((Get-Check $findings 'VdsVlanGap')[0].Actual -match '1 of 22 used \(5%\)')
Assert-Equal 'and lists the unused'     $true ((Get-Check $findings 'VdsVlanGap')[0].Actual -match '200-220')

# Below the threshold it stays one informational line.
$small = @(Compare-VdsVlanCoverage -VdsName 'dvs' -PortGroup @((New-PortGroup 'PG-250' 'Access' @(250))) -TrunkedVlanId @(250, 300, 301))
Assert-Equal 'a small gap is headroom'  1 (Get-Check $small 'TrunkedVlanUnused').Count
Assert-Equal 'and not a gap finding'    0 (Get-Check $small 'VdsVlanGap').Count
# The line between them is a parameter, not a hardcoded opinion.
Assert-Equal 'the threshold moves it'   1 (Get-Check (Compare-VdsVlanCoverage -VdsName 'dvs' -PortGroup @((New-PortGroup 'PG-250' 'Access' @(250))) -TrunkedVlanId @(250, 300, 301) -GapThreshold 2) 'VdsVlanGap').Count

# Unused AND arriving is worse than unused and quiet: the flooding is real.
$arriving = @(Compare-VdsVlanCoverage -VdsName 'dvs-prod' -PortGroup @((New-PortGroup 'PG-250' 'Access' @(250))) `
    -TrunkedVlanId (@(250) + $wide) -ObservedVlanId @(250, 205, 206))
Assert-Equal 'it says how much is real traffic' $true ((Get-Check $arriving 'VdsVlanGap')[0].Detail -match '2 of them are not merely permitted')
# And says nothing about it when the runtime read was skipped.
Assert-Equal 'and stays silent without it'      $false ((Get-Check $findings 'VdsVlanGap')[0].Detail -match 'not merely permitted')

# A vDS with no port groups at all is the extreme of the same thing.
Assert-Equal 'an empty vDS is a gap' 1 (Get-Check (Compare-VdsVlanCoverage -VdsName 'dvs' -PortGroup @() -TrunkedVlanId $wide) 'VdsVlanGap').Count

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

Write-Host "`n=== The native VLAN: many trunked, exactly one native ===" -ForegroundColor Cyan
# The design here is a trunk of several VLANs per vNIC with one of them native.
# Many VLANs on a vNIC is normal and must never be a finding in itself.
$normal = New-Member 0 'eth0' @(10, 250, 300, 400) 'A' 9000 10
Assert-Equal 'a trunk with one native is clean' 0 @(Test-VnicNativeVlan -Member $normal).Count

# Only one VLAN can take untagged frames on a trunk. With two marked native the
# fabric uses one and the other is not what the configuration says it is.
$twoNatives = New-Member 0 'eth0' @(10, 250) 'A' 9000 10 'tmpl' 'updating-template' 'CDP-ON' 'best-effort' 'VMWare' @(10, 250)
$findings = @(Test-VnicNativeVlan -Member $twoNatives)
Assert-Equal 'two natives is reported'          1 (Get-Check $findings 'VnicMultipleNativeVlans').Count
Assert-Equal 'as an error'                      'ERROR' (Get-Check $findings 'VnicMultipleNativeVlans')[0].Severity
# Wrong on any design, so it is a mismatch rather than a recommendation - and it
# must survive -SkipBestPractice.
Assert-Equal 'and as a consistency finding'     'Consistency' (Get-Check $findings 'VnicMultipleNativeVlans')[0].Category
Assert-Equal 'and is not suppressed by -RequireNative:$false' 1 (Get-Check (Test-VnicNativeVlan -Member $twoNatives -RequireNative $false) 'VnicMultipleNativeVlans').Count

# None at all: untagged frames on that uplink have nowhere to land.
$noNative = New-Member 0 'eth0' @(10, 250) 'A' 9000 0
$findings = @(Test-VnicNativeVlan -Member $noNative)
Assert-Equal 'no native VLAN is reported'       1 (Get-Check $findings 'VnicNoNativeVlan').Count
# This one rests on the estate's own convention, so it is the part that
# -SkipBestPractice drops.
Assert-Equal 'as a best-practice finding'       'BestPractice' (Get-Check $findings 'VnicNoNativeVlan')[0].Category
Assert-Equal 'and it IS suppressible'           0 (Get-Check (Test-VnicNativeVlan -Member $noNative -RequireNative $false) 'VnicNoNativeVlan').Count

# A native that resolved to an id the trunk list does not carry.
$orphanNative = New-Member 0 'eth0' @(10, 250) 'A' 9000 999 'tmpl' 'updating-template' 'CDP-ON' 'best-effort' 'VMWare' @(999)
Assert-Equal 'a native outside the trunk is reported' 1 (Get-Check (Test-VnicNativeVlan -Member $orphanNative) 'VnicNativeVlanNotTrunked').Count
# A vNIC with no VLANs at all is a different finding elsewhere; not this one.
Assert-Equal 'an empty vNIC is not reported here'     0 (Get-Check (Test-VnicNativeVlan -Member (New-Member 0 'eth0' @() 'A' 9000 10) -RequireNative $false) 'VnicNativeVlanNotTrunked').Count

Write-Host "`n=== Best practice: the QoS class a vNIC's MTU actually has to fit ===" -ForegroundColor Cyan
# A vNIC at 9000 whose priority lands in a class still at 1500 drops jumbo
# frames with no error anywhere. Three objects have to line up to see it.
$policies = @(
    [pscustomobject]@{ Name = 'Platinum'; Dn = 'org-root/ep-qos-Platinum' }
    [pscustomobject]@{ Name = 'BestEffort'; Dn = 'org-root/ep-qos-BestEffort' }
)
$egress = @(
    [pscustomobject]@{ Dn = 'org-root/ep-qos-Platinum/egress'; Prio = 'platinum' }
    [pscustomobject]@{ Dn = 'org-root/ep-qos-BestEffort/egress'; Prio = 'best-effort' }
)
$classes = @(
    [pscustomobject]@{ Priority = 'platinum'; Mtu = '9216'; AdminState = 'enabled' }
    [pscustomobject]@{ Priority = 'best-effort'; Mtu = 'normal'; AdminState = 'enabled' }
    [pscustomobject]@{ Priority = 'fc'; Mtu = 'fc'; AdminState = 'enabled' }
)
$mtuByPolicy = Get-QosClassMtu -Policy $policies -Egress $egress -QosClass $classes
Assert-Equal 'a numeric class MTU is read'   9216 $mtuByPolicy['Platinum']
Assert-Equal "'normal' means 1500"           1500 $mtuByPolicy['BestEffort']
Assert-Equal 'a policy with no class is absent, not guessed' $false $mtuByPolicy.ContainsKey('Gold')

Write-Host "`n=== Best practice: network control policy ===" -ForegroundColor Cyan
function New-Ncp { param($Name = 'NCP', $Cdp = 'enabled', $Uplink = 'link-down', $Mac = 'all-host-vlans', $Lldp = 'enabled')
    [pscustomobject]@{ Name = $Name; Cdp = $Cdp; UplinkFailAction = $Uplink; MacRegisterMode = $Mac
        LldpTransmit = $Lldp; LldpReceive = $Lldp } }

Assert-Equal 'a correct policy is clean' 0 @(Test-NetworkControlPolicyBestPractice -Policy (New-Ncp)).Count

# THE ONE THAT MATTERS. On 'warning' the vNIC stays up when the fabric loses its
# uplinks, ESXi keeps the uplink in the team, and nothing fails over or alarms.
$findings = @(Test-NetworkControlPolicyBestPractice -Policy (New-Ncp -Uplink 'warning'))
Assert-Equal 'uplink-fail warning is reported' 1 (Get-Check $findings 'NcpUplinkFailAction').Count
Assert-Equal 'and as an error, not advice'     'ERROR' (Get-Check $findings 'NcpUplinkFailAction')[0].Severity
Assert-Equal 'and it is a best-practice finding' 'BestPractice' (Get-Check $findings 'NcpUplinkFailAction')[0].Category

$findings = @(Test-NetworkControlPolicyBestPractice -Policy (New-Ncp -Mac 'only-native-vlan'))
Assert-Equal 'native-only MAC registration is reported' 1 (Get-Check $findings 'NcpMacRegisterMode').Count

# CDP off with LLDP on is unremarkable; both off is a troubleshooting dead end.
$findings = @(Test-NetworkControlPolicyBestPractice -Policy (New-Ncp -Cdp 'disabled'))
Assert-Equal 'CDP off with LLDP on is only INFO' 'INFO' (Get-Check $findings 'NcpCdpDisabled')[0].Severity
Assert-Equal 'and is not escalated'              0 (Get-Check $findings 'NcpNoDiscoveryProtocol').Count

$findings = @(Test-NetworkControlPolicyBestPractice -Policy (New-Ncp -Cdp 'disabled' -Lldp 'disabled'))
Assert-Equal 'both off is a warning'  1 (Get-Check $findings 'NcpNoDiscoveryProtocol').Count
Assert-Equal 'and not double-reported' 0 (Get-Check $findings 'NcpCdpDisabled').Count

Write-Host "`n=== Best practice: vNIC settings ===" -ForegroundColor Cyan
Assert-Equal 'a correct vNIC is clean' 0 @(Test-VnicBestPractice -Member (New-Member 0 'eth0' @(10, 250) 'A') -QosClassMtu @{}).Count

# Fabric failover on a vNIC presented to ESXi: the fabric moves the MAC while
# the host still believes its uplink is healthy.
$findings = @(Test-VnicBestPractice -Member (New-Member 0 'eth0' @(10) 'A-B') -QosClassMtu @{})
Assert-Equal 'fabric failover is reported'      1 (Get-Check $findings 'VnicFabricFailoverEnabled').Count
Assert-Equal 'a plain fabric id is not'         0 (Get-Check (Test-VnicBestPractice -Member (New-Member 0 'eth0' @(10) 'B') -QosClassMtu @{}) 'VnicFabricFailoverEnabled').Count

$initial = New-Member 0 'eth0' @(10) 'A' 9000 0 'tmpl' 'initial-template'
Assert-Equal 'an initial-template is reported' 1 (Get-Check (Test-VnicBestPractice -Member $initial -QosClassMtu @{}) 'VnicTemplateNotUpdating').Count

# MTU 9000 into a 1500 class.
$jumbo = New-Member 0 'eth0' @(10) 'A' 9000
$findings = @(Test-VnicBestPractice -Member $jumbo -QosClassMtu @{ 'best-effort' = 1500 })
Assert-Equal 'an MTU above its QoS class is reported' 1 (Get-Check $findings 'VnicMtuExceedsQosClass').Count
Assert-Equal 'and as an error'                        'ERROR' (Get-Check $findings 'VnicMtuExceedsQosClass')[0].Severity
Assert-Equal 'a class that fits is clean'             0 (Get-Check (Test-VnicBestPractice -Member $jumbo -QosClassMtu @{ 'best-effort' = 9216 }) 'VnicMtuExceedsQosClass').Count
# An unresolvable class must not be guessed at in either direction.
Assert-Equal 'an unknown QoS class is not reported'   0 (Get-Check (Test-VnicBestPractice -Member $jumbo -QosClassMtu @{}) 'VnicMtuExceedsQosClass').Count

Assert-Equal 'VLAN 1 on a data vNIC is noted' 1 (Get-Check (Test-VnicBestPractice -Member (New-Member 0 'eth0' @(1, 250) 'A') -QosClassMtu @{}) 'VnicCarriesDefaultVlan').Count

Write-Host "`n=== Best practice: port group teaming ===" -ForegroundColor Cyan
function New-Teaming { param($Name = 'PG', $Teaming = 'loadbalance_srcid', $Beacon = $false, $Notify = $true)
    [pscustomobject]@{ Name = $Name; Teaming = $Teaming; BeaconProbing = $Beacon; NotifySwitches = $Notify } }

Assert-Equal 'a correct port group is clean' 0 @(Test-PortGroupBestPractice -PortGroup (New-Teaming) -VdsName 'dvs').Count

# IP hash needs a port channel to the host; a blade's two vNICs land on two
# independent fabric interconnects, which are not one.
$findings = @(Test-PortGroupBestPractice -PortGroup (New-Teaming -Teaming 'loadbalance_ip') -VdsName 'dvs')
Assert-Equal 'IP-hash teaming is reported' 1 (Get-Check $findings 'PortGroupIpHashTeaming').Count
Assert-Equal 'and as an error'             'ERROR' (Get-Check $findings 'PortGroupIpHashTeaming')[0].Severity

Assert-Equal 'beacon probing is reported'  1 (Get-Check (Test-PortGroupBestPractice -PortGroup (New-Teaming -Beacon $true) -VdsName 'dvs') 'PortGroupBeaconProbing').Count
Assert-Equal 'notify switches off is reported' 1 (Get-Check (Test-PortGroupBestPractice -PortGroup (New-Teaming -Notify $false) -VdsName 'dvs') 'PortGroupNotifySwitchesOff').Count
# An absent property is not a disabled one.
Assert-Equal 'an unreadable notify setting is not reported' 0 (Get-Check (Test-PortGroupBestPractice -PortGroup ([pscustomobject]@{ Name = 'PG'; Teaming = 'loadbalance_srcid' }) -VdsName 'dvs') 'PortGroupNotifySwitchesOff').Count

Write-Host "`n=== Best practice: the vDS and the service profile ===" -ForegroundColor Cyan
Assert-Equal 'two uplinks and CDP is clean' 0 @(Test-VdsBestPractice -VdsName 'dvs' -UplinkCount 2 -DiscoveryOperation 'both').Count
Assert-Equal 'a single uplink is reported'  1 (Get-Check (Test-VdsBestPractice -VdsName 'dvs' -UplinkCount 1 -DiscoveryOperation 'both') 'VdsSingleUplink').Count
Assert-Equal 'discovery off is reported'    1 (Get-Check (Test-VdsBestPractice -VdsName 'dvs' -UplinkCount 2 -DiscoveryOperation 'none') 'VdsDiscoveryDisabled').Count
Assert-Equal 'and so is discovery unset'    1 (Get-Check (Test-VdsBestPractice -VdsName 'dvs' -UplinkCount 2 -DiscoveryOperation '') 'VdsDiscoveryDisabled').Count

Assert-Equal 'a templated profile is clean' 0 @(Test-ServiceProfileBestPractice -ServiceProfile ([pscustomobject]@{ Name = 'esx01'; OperSrcTemplName = 'org-root/ls-PRD-TMPL' })).Count
Assert-Equal 'a hand-built profile is reported' 1 (Get-Check (Test-ServiceProfileBestPractice -ServiceProfile ([pscustomobject]@{ Name = 'esx01' })) 'ProfileNotFromTemplate').Count

Write-Host "`n=== vDS discovery protocol ===" -ForegroundColor Cyan
$vdsView = [pscustomobject]@{ Config = [pscustomobject]@{ LinkDiscoveryProtocolConfig = [pscustomobject]@{ Protocol = 'CDP'; Operation = 'Both' } } }
$discovery = Get-VdsDiscoveryProtocol -VdsView $vdsView
Assert-Equal 'the protocol is normalised'  'cdp'  $discovery.Protocol
Assert-Equal 'and the operation'           'both' $discovery.Operation
Assert-Equal 'a vDS with no config is empty, not an error' '' (Get-VdsDiscoveryProtocol -VdsView ([pscustomobject]@{})).Protocol

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
