<#
.SYNOPSIS
    Tests the vDS VLAN report: duplicate, untagged and overlapping-trunk detection.

.DESCRIPTION
    Two parts.

      1. The rules, called directly: how each vSphere VLAN spec is classified, how trunk
         range overlaps are found, and which port groups are reported as what.
      2. The whole script, run end to end with Connect-VIServer, Get-View and
         Disconnect-VIServer stubbed as global functions. A function takes precedence over a
         cmdlet of the same name, so the real PowerCLI cmdlets are never reached even on a
         host where PowerCLI is installed. Config and credential come from a temp file and
         environment variables, both removed afterwards.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-VdsVlanReport.ps1
#>

# The same strictness the script runs under. Without Stop, an error inside a helper is printed
# and the assertion after it still passes - which is how a StrictMode crash on a port group with
# no VLAN setting nearly shipped past this suite.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot 'scripts/vsphere/Export-VdsVlanReport.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors in $scriptPath" }

$helpers = 'Format-VlanRange', 'Get-VlanRangeOverlap', 'ConvertTo-VdsVlanInfo', 'ConvertTo-VdsVlanFinding', 'Find-VdsVlanFinding'
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object { $helpers -contains $_.Name } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# ---- Stand-ins for the vSphere objects, carrying the real type names ----------------------
function New-VlanIdSpec { param([int]$Id) [pscustomobject]@{ PSTypeName = 'VMware.Vim.VmwareDistributedVirtualSwitchVlanIdSpec'; VlanId = $Id } }
function New-PvlanSpec { param([int]$Id) [pscustomobject]@{ PSTypeName = 'VMware.Vim.VmwareDistributedVirtualSwitchPvlanSpec'; PvlanId = $Id } }
function New-TrunkSpec {
    param([string[]]$Range)
    $numeric = @($Range | ForEach-Object {
        $p = $_ -split '-'
        [pscustomobject]@{ PSTypeName = 'VMware.Vim.NumericRange'; Start = [int]$p[0]; End = [int]$p[-1] }
    })
    [pscustomobject]@{ PSTypeName = 'VMware.Vim.VmwareDistributedVirtualSwitchTrunkVlanSpec'; VlanId = $numeric }
}
function New-Range { param([int]$Start, [int]$End) [pscustomobject]@{ Start = $Start; End = $End } }

$pvlanMap = @(
    [pscustomobject]@{ PrimaryVlanId = 100; SecondaryVlanId = 100; PvlanType = 'promiscuous' }
    [pscustomobject]@{ PrimaryVlanId = 100; SecondaryVlanId = 101; PvlanType = 'isolated' }
)

Write-Host "`n=== VLAN spec classification ===" -ForegroundColor Cyan
$v = ConvertTo-VdsVlanInfo -VlanSpec (New-VlanIdSpec 0)
Assert-Equal "VLAN ID 0 is type None" 'None' $v.VlanType
Assert-Equal "None carries no VLAN ranges" 0 @($v.Ranges).Count
Assert-Equal "None reads 'None'" 'None' $v.VlanConfig

$v = ConvertTo-VdsVlanInfo -VlanSpec (New-VlanIdSpec 100)
Assert-Equal "VLAN ID 100 is type VLAN" 'VLAN' $v.VlanType
Assert-Equal "VLAN 100 reads 'VLAN 100'" 'VLAN 100' $v.VlanConfig
Assert-Equal "VLAN 100 carries 100" 100 $v.Ranges[0].Start

$v = ConvertTo-VdsVlanInfo -VlanSpec (New-TrunkSpec '0-4094')
Assert-Equal "a trunk is type Trunk" 'Trunk' $v.VlanType
Assert-Equal "a full trunk reads 'Trunk 0-4094'" 'Trunk 0-4094' $v.VlanConfig

$v = ConvertTo-VdsVlanInfo -VlanSpec (New-TrunkSpec '1-12', '300')
Assert-Equal "single VLANs in a trunk print without a dash" 'Trunk 1-12,300' $v.VlanConfig
Assert-Equal "a two-range trunk keeps both ranges" 2 @($v.Ranges).Count

$v = ConvertTo-VdsVlanInfo -VlanSpec (New-PvlanSpec 101) -PvlanMap $pvlanMap
Assert-Equal "a PVLAN is type PVLAN" 'PVLAN' $v.VlanType
Assert-Equal "a PVLAN names its type and primary" 'PVLAN 101 (isolated, primary 100)' $v.VlanConfig
Assert-Equal "a PVLAN carries its own ID" 101 $v.Ranges[0].Start

$v = ConvertTo-VdsVlanInfo -VlanSpec (New-PvlanSpec 102) -PvlanMap $pvlanMap
Assert-Equal "a PVLAN missing from the map says so" 'PVLAN 102 (not in the vDS PVLAN map)' $v.VlanConfig

$v = ConvertTo-VdsVlanInfo -VlanSpec (New-PvlanSpec 101) -PvlanMap $null
Assert-Equal "a switch with no PVLAN map does not throw" 'PVLAN' $v.VlanType

$v = ConvertTo-VdsVlanInfo -VlanSpec $null
Assert-Equal "no VLAN spec is Unknown, not None" 'Unknown' $v.VlanType

$v = ConvertTo-VdsVlanInfo -VlanSpec ([pscustomobject]@{ PSTypeName = 'VMware.Vim.SomethingElse'; VlanId = 5 })
Assert-Equal "an unrecognised spec type is Unknown" 'Unknown' $v.VlanType
Assert-Equal "an unrecognised spec names its type" 'Unknown (VMware.Vim.SomethingElse)' $v.VlanConfig

Write-Host "`n=== Trunk range overlap ===" -ForegroundColor Cyan
Assert-Equal "disjoint ranges do not overlap" '' (Format-VlanRange -Range @(Get-VlanRangeOverlap -Range @((New-Range 100 200), (New-Range 300 400))))
Assert-Equal "adjacent ranges do not overlap" '' (Format-VlanRange -Range @(Get-VlanRangeOverlap -Range @((New-Range 1 10), (New-Range 11 20))))
Assert-Equal "a nested range overlaps by itself" '150-160' (Format-VlanRange -Range @(Get-VlanRangeOverlap -Range @((New-Range 100 200), (New-Range 150 160))))
Assert-Equal "the same single VLAN twice overlaps" '100' (Format-VlanRange -Range @(Get-VlanRangeOverlap -Range @((New-Range 100 100), (New-Range 100 100))))
Assert-Equal "input order does not matter" '150-160' (Format-VlanRange -Range @(Get-VlanRangeOverlap -Range @((New-Range 150 160), (New-Range 100 200))))
Assert-Equal "touching overlaps merge into one" '150-170' (Format-VlanRange -Range @(Get-VlanRangeOverlap -Range @((New-Range 100 200), (New-Range 150 160), (New-Range 155 170))))
Assert-Equal "separate overlaps stay separate" '10,50-60' (Format-VlanRange -Range @(Get-VlanRangeOverlap -Range @((New-Range 1 20), (New-Range 10 10), (New-Range 50 70), (New-Range 40 60))))
Assert-Equal "a partial overlap returns only the shared part" '15-20' (Format-VlanRange -Range @(Get-VlanRangeOverlap -Range @((New-Range 1 20), (New-Range 15 30))))
Assert-Equal "no ranges returns nothing" 0 @(Get-VlanRangeOverlap -Range @()).Count

Write-Host "`n=== Findings ===" -ForegroundColor Cyan
function New-PortgroupRecord {
    param([string]$Name, [string]$Switch, $Spec, [int]$VmCount = 0)
    [pscustomobject]@{
        vCenter      = 'vc.test'
        Datacenter   = 'DC1'
        VDSwitch     = $Switch
        SwitchKey    = "key-$Switch"
        PortGroup    = $Name
        PortGroupKey = "pg-$Switch-$Name"
        VmCount      = $VmCount
        Vlan         = ConvertTo-VdsVlanInfo -VlanSpec $Spec -PvlanMap $pvlanMap
    }
}

$records = @(
    New-PortgroupRecord 'Prod-100' 'vDS-A' (New-VlanIdSpec 100) 3
    New-PortgroupRecord 'Prod-100-old' 'vDS-A' (New-VlanIdSpec 100)
    New-PortgroupRecord 'Web-200' 'vDS-A' (New-VlanIdSpec 200)
    New-PortgroupRecord 'Untagged-1' 'vDS-A' (New-VlanIdSpec 0)
    New-PortgroupRecord 'Untagged-2' 'vDS-A' (New-VlanIdSpec 0)
    New-PortgroupRecord 'Isolated-101' 'vDS-A' (New-PvlanSpec 101)
    New-PortgroupRecord 'Guest-Trunk' 'vDS-A' (New-TrunkSpec '0-4094')
    New-PortgroupRecord 'Odd-Trunk' 'vDS-A' (New-TrunkSpec '300-400', '350')
    New-PortgroupRecord 'B-100' 'vDS-B' (New-VlanIdSpec 100)
    New-PortgroupRecord 'B-101' 'vDS-B' (New-VlanIdSpec 101)
)

$f = @(Find-VdsVlanFinding -Portgroup $records)
$dup = @($f | Where-Object { $_.Finding -eq 'DuplicateVlan' })
Assert-Equal "same VLAN twice on one vDS gives one row per port group" 2 $dup.Count
Assert-Equal "both duplicate rows are VLAN 100" '100,100' (($dup | ForEach-Object { $_.VlanId }) -join ',')
Assert-Equal "each duplicate names the other port group" 'Prod-100-old' ($dup | Where-Object { $_.PortGroup -eq 'Prod-100' }).SharedWith
Assert-Equal "the VM count is carried onto the row" 3 ($dup | Where-Object { $_.PortGroup -eq 'Prod-100' }).VmCount
Assert-Equal "the same VLAN on another vDS is not a duplicate by default" 0 @($dup | Where-Object { $_.VDSwitch -eq 'vDS-B' }).Count
Assert-Equal "a 0-4094 trunk is not a duplicate of everything by default" 0 @($dup | Where-Object { $_.PortGroup -eq 'Guest-Trunk' }).Count

$none = @($f | Where-Object { $_.Finding -eq 'NoVlan' })
Assert-Equal "every untagged port group is reported" 'Untagged-1,Untagged-2' ((@($none | ForEach-Object { $_.PortGroup }) | Sort-Object) -join ',')
Assert-Equal "untagged port groups are not duplicates of each other" 0 @($dup | Where-Object { $_.VlanId -eq 0 }).Count
Assert-Equal "NoVlan rows carry VLAN ID 0" 0 $none[0].VlanId

$ovl = @($f | Where-Object { $_.Finding -eq 'TrunkRangeOverlap' })
Assert-Equal "a trunk naming a VLAN twice is reported" 'Odd-Trunk' (@($ovl | ForEach-Object { $_.PortGroup }) -join ',')
Assert-Equal "the overlap names the repeated VLAN" "VLANs 350 are in more than one of this trunk's ranges." $ovl[0].Detail
Assert-Equal "the overlap row has no single VLAN ID" $true ($null -eq $ovl[0].VlanId)
Assert-Equal "nothing else is reported" 5 $f.Count

$f = @(Find-VdsVlanFinding -Portgroup $records -DuplicateScope vCenter)
$dup = @($f | Where-Object { $_.Finding -eq 'DuplicateVlan' })
Assert-Equal "vCenter scope: VLAN 100 on two vDS gives three rows" 3 @($dup | Where-Object { $_.VlanId -eq 100 }).Count
Assert-Equal "vCenter scope: a PVLAN ID clashing with a VLAN ID is a duplicate" 'B-101,Isolated-101' ((@($dup | Where-Object { $_.VlanId -eq 101 } | ForEach-Object { $_.PortGroup }) | Sort-Object) -join ',')
Assert-Equal "vCenter scope: SharedWith is qualified with the vDS" 'vDS-A/Prod-100; vDS-A/Prod-100-old' ($dup | Where-Object { $_.PortGroup -eq 'B-100' }).SharedWith
Assert-Equal "vCenter scope: the detail counts the vDS" 'VLAN 100 is on 3 port groups on 2 vDS.' ($dup | Where-Object { $_.PortGroup -eq 'B-100' }).Detail

$f = @(Find-VdsVlanFinding -Portgroup $records -IncludeTrunk)
$dup = @($f | Where-Object { $_.Finding -eq 'DuplicateVlan' })
$trunkVlans = @($dup | Where-Object { $_.PortGroup -eq 'Guest-Trunk' } | ForEach-Object { $_.VlanId } | Sort-Object)
Assert-Equal "with trunks: the guest trunk duplicates only VLANs something else carries" '100,101,200,300,301' (($trunkVlans | Select-Object -First 5) -join ',')
Assert-Equal "with trunks: the guest trunk duplicates 100, 101, 200 and 300-400 - 104 VLANs" 104 $trunkVlans.Count
Assert-Equal "with trunks: a trunk listing VLAN 350 twice is still one carrier of it" 2 @($dup | Where-Object { $_.VlanId -eq 350 }).Count
Assert-Equal "with trunks: VLAN 0 in a trunk is never a duplicate" 0 @($dup | Where-Object { $_.VlanId -eq 0 }).Count

Assert-Equal "no port groups gives no findings" 0 @(Find-VdsVlanFinding -Portgroup @()).Count
$unknown = @(New-PortgroupRecord 'Mystery' 'vDS-A' $null; New-PortgroupRecord 'Mystery-2' 'vDS-A' $null)
Assert-Equal "Unknown port groups are neither NoVlan nor duplicates" 0 @(Find-VdsVlanFinding -Portgroup $unknown).Count

# ==========================================================================================
Write-Host "`n=== End to end, against stubs ===" -ForegroundColor Cyan

function New-MoRef { param([string]$Value) [pscustomobject]@{ Value = $Value } }
function New-StubPortgroup {
    param([string]$Key, [string]$Name, [string]$Switch, $Spec, [object[]]$Vm, [string]$Backing)
    $config = [pscustomobject]@{
        DistributedVirtualSwitch = New-MoRef $Switch
        DefaultPortConfig        = [pscustomobject]@{ Vlan = $Spec }
    }
    # Leaving BackingType off entirely is what a pre-7.0 API binding looks like.
    if ($Backing) { $config | Add-Member -NotePropertyName BackingType -NotePropertyValue $Backing }
    [pscustomobject]@{ Name = $Name; MoRef = New-MoRef $Key; Vm = $Vm; Config = $config }
}
function New-StubSwitch {
    param([string]$Key, [string]$Name, [string[]]$Uplink, [object[]]$PvlanConfig)
    [pscustomobject]@{
        Name   = $Name
        MoRef  = New-MoRef $Key
        Config = [pscustomobject]@{ UplinkPortgroup = @($Uplink | ForEach-Object { New-MoRef $_ }); PvlanConfig = $PvlanConfig }
    }
}

$fullFixture = @{
    Datacenter                     = @(
        [pscustomobject]@{ Name = 'DC1'; MoRef = New-MoRef 'datacenter-1' }
        [pscustomobject]@{ Name = 'DC2'; MoRef = New-MoRef 'datacenter-2' }
    )
    VmwareDistributedVirtualSwitch = @{
        'datacenter-1' = @(
            New-StubSwitch 'dvs-1' 'vDS-A' 'dvportgroup-1' $pvlanMap
            New-StubSwitch 'dvs-2' 'vDS-B' 'dvportgroup-2' $null
        )
    }
    DistributedVirtualPortgroup    = @{
        'datacenter-1' = @(
            New-StubPortgroup 'dvportgroup-1' 'vDS-A-Uplinks' 'dvs-1' (New-TrunkSpec '0-4094')
            New-StubPortgroup 'dvportgroup-10' 'Prod-100' 'dvs-1' (New-VlanIdSpec 100) @((New-MoRef 'vm-1'), (New-MoRef 'vm-2'), (New-MoRef 'vm-3')) 'standard'
            New-StubPortgroup 'dvportgroup-11' 'Prod-100-old' 'dvs-1' (New-VlanIdSpec 100) $null 'standard'
            New-StubPortgroup 'dvportgroup-12' 'Mgmt-Untagged' 'dvs-1' (New-VlanIdSpec 0) @((New-MoRef 'vm-4'))
            New-StubPortgroup 'dvportgroup-13' 'Odd-Trunk' 'dvs-1' (New-TrunkSpec '100-200', '150-160')
            New-StubPortgroup 'dvportgroup-14' 'Isolated-101' 'dvs-1' (New-PvlanSpec 101)
            New-StubPortgroup 'dvportgroup-15' 'NSX-Segment' 'dvs-1' (New-VlanIdSpec 0) $null 'nsx'
            New-StubPortgroup 'dvportgroup-2' 'vDS-B-Uplinks' 'dvs-2' (New-TrunkSpec '0-4094')
            New-StubPortgroup 'dvportgroup-20' 'B-100' 'dvs-2' (New-VlanIdSpec 100)
            New-StubPortgroup 'dvportgroup-21' 'B-101' 'dvs-2' (New-VlanIdSpec 101)
            New-StubPortgroup 'dvportgroup-90' 'On-Other-Switch' 'dvs-99' (New-VlanIdSpec 100)
        )
    }
}
$cleanFixture = @{
    Datacenter                     = @([pscustomobject]@{ Name = 'DC1'; MoRef = New-MoRef 'datacenter-1' })
    VmwareDistributedVirtualSwitch = @{ 'datacenter-1' = @(New-StubSwitch 'dvs-1' 'vDS-A' 'dvportgroup-1' $null) }
    DistributedVirtualPortgroup    = @{
        'datacenter-1' = @(
            New-StubPortgroup 'dvportgroup-1' 'vDS-A-Uplinks' 'dvs-1' (New-TrunkSpec '0-4094')
            New-StubPortgroup 'dvportgroup-10' 'Prod-100' 'dvs-1' (New-VlanIdSpec 100)
        )
    }
}

$global:VdsStub = @{ Fixture = $fullFixture; Calls = New-Object System.Collections.Generic.List[object]; Disconnected = @(); ConnectedAs = $null; Throw = $false }
$global:VdsStubServer = [pscustomobject]@{ Name = 'vc.test.invalid' }

function global:Connect-VIServer {
    param($Server, $Credential, $ErrorAction)
    $global:VdsStub.ConnectedAs = $Credential.UserName
    $global:VdsStubServer
}
function global:Disconnect-VIServer {
    param($Server, $Confirm, $ErrorAction)
    $global:VdsStub.Disconnected += , $Server
}
function global:Get-View {
    param($Server, [string]$ViewType, $SearchRoot, [string[]]$Property)
    $global:VdsStub.Calls.Add([pscustomobject]@{ Server = $Server; ViewType = $ViewType; Property = $Property })
    if ($global:VdsStub.Throw) { throw 'stub: property collector failed' }
    $set = $global:VdsStub.Fixture[$ViewType]
    if ($null -eq $SearchRoot) { return $set }
    if ($set.ContainsKey($SearchRoot.Value)) { return $set[$SearchRoot.Value] }
}

# Get-Module -ListAvailable has to find VMware.VimAutomation.Core for the dependency check.
# An empty manifest is enough - the stubs above are what gets called.
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("richo-vds-test-" + [guid]::NewGuid().ToString('N'))
$fakeModule = Join-Path $tempRoot 'modules/VMware.VimAutomation.Core'
New-Item -Path $fakeModule -ItemType Directory -Force | Out-Null
Set-Content -Path (Join-Path $fakeModule 'VMware.VimAutomation.Core.psd1') -Value "@{ ModuleVersion = '0.0.1'; FunctionsToExport = @() }"

$configPath = Join-Path $tempRoot 'environments.json'
@{ default = 'test'; environments = @{ test = @{ vcenter = @{ server = 'vc.test.invalid'; credentialName = 'richo-vds-test' } } } } |
    ConvertTo-Json -Depth 5 | Set-Content -Path $configPath

$saved = @{
    PSModulePath = $env:PSModulePath; RICHO_CONFIG = $env:RICHO_CONFIG
    User = $env:RICHO_RICHO_VDS_TEST_USER; Password = $env:RICHO_RICHO_VDS_TEST_PASSWORD; LogFile = $env:RICHO_LOG_FILE
}
$env:PSModulePath = (Join-Path $tempRoot 'modules') + [IO.Path]::PathSeparator + $env:PSModulePath
$env:RICHO_CONFIG = $configPath
$env:RICHO_RICHO_VDS_TEST_USER = 'svc-readonly'
$env:RICHO_RICHO_VDS_TEST_PASSWORD = 'not-a-real-password'
$env:RICHO_LOG_FILE = $null

try {
    # ---- Default run --------------------------------------------------------------------
    $csv = Join-Path $tempRoot 'out/report.csv'
    $rows = @(& $scriptPath -Environment test -OutputPath $csv -PassThru 6>$null 3>$null)
    $fromCsv = @(Import-Csv -Path $csv)

    Assert-Equal "connects with the resolved credential" 'svc-readonly' $global:VdsStub.ConnectedAs
    Assert-Equal "creates the output folder and writes the CSV" $true (Test-Path $csv)
    Assert-Equal "the CSV and -PassThru carry the same rows" $rows.Count $fromCsv.Count
    Assert-Equal "column order is fixed" 'Finding,vCenter,Datacenter,VDSwitch,PortGroup,VlanType,VlanId,VlanConfig,SharedWith,VmCount,Detail,PortGroupKey,ScriptVersion,CollectedUtc' ($fromCsv[0].PSObject.Properties.Name -join ',')
    Assert-Equal "every row is stamped with the script version" 1 @($fromCsv | ForEach-Object { $_.ScriptVersion } | Sort-Object -Unique).Count
    Assert-Equal "the script version is the one the script declares" $true ($fromCsv[0].ScriptVersion -match '^\d+\.\d+\.\d+$')

    $found = ($fromCsv | ForEach-Object { '{0}:{1}' -f $_.Finding, $_.PortGroup }) -join ' | '
    Assert-Equal "findings, sorted" 'DuplicateVlan:Prod-100 | DuplicateVlan:Prod-100-old | NoVlan:Mgmt-Untagged | TrunkRangeOverlap:Odd-Trunk' $found
    Assert-Equal "uplink port groups are never reported" 0 @($fromCsv | Where-Object { $_.PortGroup -like '*Uplinks' }).Count
    Assert-Equal "NSX-backed port groups are never reported" 0 @($fromCsv | Where-Object { $_.PortGroup -eq 'NSX-Segment' }).Count
    Assert-Equal "port groups on a switch that is not a VMware vDS are not read" 0 @($fromCsv | Where-Object { $_.PortGroup -eq 'On-Other-Switch' }).Count
    Assert-Equal "a port group with no VMs counts 0, not 1" '0' ($fromCsv | Where-Object { $_.PortGroup -eq 'Prod-100-old' }).VmCount
    Assert-Equal "a port group with three VMs counts 3" '3' ($fromCsv | Where-Object { $_.PortGroup -eq 'Prod-100' }).VmCount
    Assert-Equal "the datacenter is named on the row" 'DC1' $fromCsv[0].Datacenter
    Assert-Equal "the vCenter is named on the row" 'vc.test.invalid' $fromCsv[0].vCenter
    Assert-Equal "the port group key is on the row" 'dvportgroup-10' ($fromCsv | Where-Object { $_.PortGroup -eq 'Prod-100' }).PortGroupKey

    Assert-Equal "every Get-View is aimed at the connection this run opened" 0 @($global:VdsStub.Calls | Where-Object { -not [object]::ReferenceEquals($_.Server, $global:VdsStubServer) }).Count
    Assert-Equal "every Get-View limits the properties it fetches" 0 @($global:VdsStub.Calls | Where-Object { @($_.Property).Count -eq 0 }).Count
    Assert-Equal "disconnects the session it opened, once" 1 @($global:VdsStub.Disconnected).Count

    # ---- vCenter scope with trunks --------------------------------------------------------
    $csv = Join-Path $tempRoot 'out/report-wide.csv'
    $rows = @(& $scriptPath -Environment test -OutputPath $csv -DuplicateScope vCenter -IncludeTrunk -PassThru 6>$null 3>$null)
    $v100 = @($rows | Where-Object { $_.Finding -eq 'DuplicateVlan' -and $_.VlanId -eq 100 } | ForEach-Object { $_.PortGroup } | Sort-Object)
    Assert-Equal "wide run: VLAN 100 on both vDS and the trunk" 'B-100,Odd-Trunk,Prod-100,Prod-100-old' ($v100 -join ',')
    $v101 = @($rows | Where-Object { $_.Finding -eq 'DuplicateVlan' -and $_.VlanId -eq 101 } | ForEach-Object { $_.PortGroup } | Sort-Object)
    Assert-Equal "wide run: the PVLAN, the VLAN and the trunk that all carry 101" 'B-101,Isolated-101,Odd-Trunk' ($v101 -join ',')
    Assert-Equal "wide run: uplink trunks still do not make everything a duplicate" 0 @($rows | Where-Object { $_.PortGroup -like '*Uplinks' }).Count

    # ---- Nothing to report ----------------------------------------------------------------
    $global:VdsStub.Fixture = $cleanFixture
    $csv = Join-Path $tempRoot 'out/report-clean.csv'
    $rows = @(& $scriptPath -Environment test -OutputPath $csv -PassThru 6>$null 3>$null)
    $lines = @(Get-Content -Path $csv)
    Assert-Equal "a clean run returns no rows" 0 $rows.Count
    Assert-Equal "a clean run still writes the CSV, header only" 1 $lines.Count
    Assert-Equal "the header-only CSV has the same columns" '"Finding","vCenter","Datacenter","VDSwitch","PortGroup","VlanType","VlanId","VlanConfig","SharedWith","VmCount","Detail","PortGroupKey","ScriptVersion","CollectedUtc"' $lines[0]

    # ---- A failure part-way still disconnects ----------------------------------------------
    $global:VdsStub.Throw = $true
    $global:VdsStub.Disconnected = @()
    $threw = $false
    try { & $scriptPath -Environment test -OutputPath (Join-Path $tempRoot 'out/never.csv') 6>$null 3>$null 2>$null } catch { $threw = $true }
    Assert-Equal "a vCenter failure is not swallowed" $true $threw
    Assert-Equal "a vCenter failure still disconnects" 1 @($global:VdsStub.Disconnected).Count
    Assert-Equal "a vCenter failure leaves no partial CSV" $false (Test-Path (Join-Path $tempRoot 'out/never.csv'))
}
finally {
    # Function:\Name, not function:global:Name - the scoped form is accepted and removes nothing.
    Remove-Item -Path Function:\Connect-VIServer, Function:\Disconnect-VIServer, Function:\Get-View -ErrorAction SilentlyContinue
    Remove-Variable -Name VdsStub, VdsStubServer -Scope Global -ErrorAction SilentlyContinue
    $env:PSModulePath = $saved.PSModulePath
    $env:RICHO_CONFIG = $saved.RICHO_CONFIG
    $env:RICHO_RICHO_VDS_TEST_USER = $saved.User
    $env:RICHO_RICHO_VDS_TEST_PASSWORD = $saved.Password
    $env:RICHO_LOG_FILE = $saved.LogFile
    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$leftover = @(Get-ChildItem -Path Function:\ | Where-Object { $_.Name -in 'Connect-VIServer', 'Disconnect-VIServer', 'Get-View' })
Assert-Equal "the PowerCLI stubs are removed afterwards" 0 $leftover.Count

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
