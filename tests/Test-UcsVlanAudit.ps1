<#
.SYNOPSIS
    Tests the UCS VLAN audit: name resolution, scope, usage, classification and the removal manifest.

.DESCRIPTION
    Extracts every function from scripts/ucs/Get-UcsVlanAudit.ps1 by AST and runs them against a
    synthetic UCS Manager domain and vCenter built from plain objects. PowerCLI type identity is
    simulated through PSObject.TypeNames, which is all the script inspects.

    The scenario is built so that exactly one VLAN (200) should be a cleanup candidate, and every
    other LAN Cloud VLAN is protected for a different, named reason. Each protection is then
    asserted individually, so a regression names the rule that broke.

    Also asserts the script is read-only: it calls no mutating UCS PowerTool or PowerCLI cmdlet.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsVlanAudit.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ucs/Get-UcsVlanAudit.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors in $scriptPath" }
$functions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
foreach ($f in $functions) { Invoke-Expression $f.Extent.Text }

$ScriptVersion = 'test'
$DefaultDomainSuffix = '.test'
$MasterUcsList = @('PD24000001SS101', 'PD84000001SS028', 'PD85000001SS003')

$script:Log = New-Object System.Collections.Generic.List[string]
function Write-RichoLog { param([string]$Message, [string]$Level = 'INFO') $script:Log.Add("[$Level] $Message") }
$script:Answers = New-Object System.Collections.Generic.Queue[string]
function Read-Host { param([string]$Prompt) if ($script:Answers.Count -eq 0) { throw "Read-Host called with no answer queued: $Prompt" }; $script:Answers.Dequeue() }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}
function Assert-True {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}
function Assert-Throws {
    param([string]$Name, [scriptblock]$Script, [string]$Like = '*')
    try { & $Script; $script:fail++; Write-Host "  FAIL  $Name (did not throw)" -ForegroundColor Red }
    catch {
        if ($_.Exception.Message -like $Like) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { $script:fail++; Write-Host "  FAIL  $Name (threw '$($_.Exception.Message)')" -ForegroundColor Red }
    }
}

. (Join-Path $PSScriptRoot 'UcsVlanFixture.ps1')

# ---- Helpers ---------------------------------------------------------------------------------
Write-Host "`n=== Helpers ===" -ForegroundColor Cyan
$o = [pscustomobject]@{ A = [pscustomobject]@{ B = 5 }; D = @{ K = 'v' } }
Assert-Equal 'Get-PropertyValue reads a nested path' 5 (Get-PropertyValue $o 'A.B')
Assert-True 'Get-PropertyValue returns $null for a missing property under StrictMode' ($null -eq (Get-PropertyValue $o 'A.Missing.Deeper'))
Assert-Equal 'Get-PropertyValue reads through a dictionary' 'v' (Get-PropertyValue $o 'D.K')
Assert-Equal 'Get-PropertyList of a missing property emits nothing' 0 @(Get-PropertyList $o 'Nope').Count
Assert-Equal 'MAC normalised to lower-case colon form' '00:25:b5:0a:00:1f' (ConvertTo-MacAddress '00-25-B5-0A-00-1F')
Assert-Equal "'derived' is not a MAC" '' (ConvertTo-MacAddress 'derived')
Assert-Equal 'all-zero MAC is not an identity' '' (ConvertTo-MacAddress '00:00:00:00:00:00')
Assert-Equal 'sorted unique ints, junk skipped' '3,5,10' ((@(ConvertTo-SortedIntArray @(10, '5', 3, 5, 'x', $null))) -join ',')
Assert-Equal 'ID list compressed to ranges' '1-3, 5, 7-8' (Format-IdList @(8, 1, 2, 3, 5, 7))
Assert-Equal 'empty ID list' '(none)' (Format-IdList @())
$parsed = ConvertTo-VlanIdList "10, 20-22;4095`n 7 abc 0"
Assert-Equal 'pasted VLANs parsed, range expanded' '7,10,20,21,22' ($parsed.VlanIds -join ',')
Assert-Equal 'invalid VLAN tokens reported, not dropped silently' '4095,abc,0' ($parsed.Invalid -join ',')
Assert-True 'TypeNames carry type identity' (Test-TypeName (Typed 'VMware.Vim.VirtualEthernetCard' @{ A = 1 }) 'VMware.Vim.VirtualEthernetCard')
Assert-True '$null is never a type' (-not (Test-TypeName $null 'X'))

# ---- CDP/LLDP name matching ------------------------------------------------------------------
Write-Host "`n=== CDP/LLDP domain names ===" -ForegroundColor Cyan
foreach ($form in @('PD84000001SS028-A(FD023360H8B)', 'PD84000001SS028-B.test', 'FI-A PD84000001SS028', 'pd84000001ss028', "PD84000001SS028`0")) {
    Assert-Equal "domain recognised in '$($form -replace "`0", '\0')'" 'PD84000001SS028' (ConvertTo-UcsDomainName $form $MasterUcsList)
}
Assert-Equal 'byte-array device ID decoded' 'PD24000001SS101' (ConvertTo-UcsDomainName ([Text.Encoding]::ASCII.GetBytes('PD24000001SS101-A')) $MasterUcsList)
Assert-Equal 'a name merely containing an allowlisted one is not a match' '' (ConvertTo-UcsDomainName 'XPD84000001SS028' $MasterUcsList)
Assert-Equal 'an unknown switch is ignored' '' (ConvertTo-UcsDomainName 'n9k-core-01' $MasterUcsList)
$lldp = [pscustomobject]@{ Parameter = @([pscustomobject]@{ Key = 'System Name'; Value = 'PD85000001SS003-A' }); ChassisId = '00:11:22:33:44:55' }
Assert-Equal 'LLDP system name read' 'PD85000001SS003-A' (Get-LldpSystemName $lldp)
Assert-Equal 'LLDP chassis MAC is not a name' '' (Get-LldpSystemName ([pscustomobject]@{ Parameter = @(); ChassisId = '00:11:22:33:44:55' }))

# ---- VLAN name resolution --------------------------------------------------------------------
Write-Host "`n=== VLAN name resolution ===" -ForegroundColor Cyan
$index = @{
    'dual|G'  = [pscustomobject]@{ Id = 10; Dn = 'fabric/lan/net-G' }
    'A|F'     = [pscustomobject]@{ Id = 20; Dn = 'fabric/lan/A/net-F' }
    'B|F'     = [pscustomobject]@{ Id = 21; Dn = 'fabric/lan/B/net-F' }
    'A|BOTH'  = [pscustomobject]@{ Id = 30; Dn = 'fabric/lan/A/net-BOTH' }
    'dual|BOTH' = [pscustomobject]@{ Id = 31; Dn = 'fabric/lan/net-BOTH' }
}
Assert-Equal 'global VLAN resolves on any fabric' '10' ((@(Resolve-UcsVlanReference 'G' 'B' $index) | ForEach-Object { $_.Id }) -join ',')
Assert-Equal 'fabric-specific VLAN resolves per fabric (A)' '20' ((@(Resolve-UcsVlanReference 'F' 'A' $index) | ForEach-Object { $_.Id }) -join ',')
Assert-Equal 'fabric-specific VLAN resolves per fabric (B)' '21' ((@(Resolve-UcsVlanReference 'F' 'B' $index) | ForEach-Object { $_.Id }) -join ',')
Assert-Equal 'failover vNIC resolves on both fabrics, primary first' '21,20' ((@(Resolve-UcsVlanReference 'F' 'B-A' $index) | ForEach-Object { $_.Id }) -join ',')
Assert-Equal 'name defined globally and per fabric: both returned, fabric first' '30,31' ((@(Resolve-UcsVlanReference 'BOTH' 'A' $index) | ForEach-Object { $_.Id }) -join ',')
Assert-Equal 'undefined name resolves to nothing' 0 @(Resolve-UcsVlanReference 'NOPE' 'A' $index).Count

# ---- UCS inventory ---------------------------------------------------------------------------
Write-Host "`n=== UCS inventory ===" -ForegroundColor Cyan
$fixture = New-UcsFixture
$inv = ConvertTo-UcsVlanInventory @fixture
Assert-Equal 'appliance-cloud VLAN excluded from the LAN Cloud' 1 $inv.OtherVlanCount
Assert-True 'appliance VLAN 999 not in LAN Cloud VLANs' (@($inv.Vlans | Where-Object { $_.Id -eq 999 }).Count -eq 0)
$vl300 = @($inv.Memberships | Where-Object { $_.VLANName -eq 'VL300' })
Assert-Equal 'VL300 on the fabric A template resolves to 300' '300' (@($vl300 | Where-Object { $_.Template -eq 'ESX-A0' })[0].VLANID)
Assert-Equal 'VL300 on the fabric B template resolves to 301' '301' (@($vl300 | Where-Object { $_.Template -eq 'ESX-B1' })[0].VLANID)
Assert-Equal 'template memberships counted' 13 $inv.Memberships.Count
Assert-True 'undefined template VLAN reported' (@($inv.Exceptions | Where-Object { $_.Category -eq 'UNDEFINED VLAN REFERENCE' -and $_.Target -like '*if-GHOST' }).Count -eq 1)
$bm = @($inv.ServiceProfiles | Where-Object { $_.Name -eq 'bm01' })[0]
Assert-Equal 'bare-metal profile carries its direct VLANs' '100,500' ($bm.VlanIds -join ',')
$esx = @($inv.ServiceProfiles | Where-Object { $_.Name -eq 'esx01' })[0]
Assert-True 'ESXi profile carries its templates VLANs' (($esx.VlanIds -contains 200) -and ($esx.VlanIds -contains 301) -and ($esx.VlanIds -contains 300))
Assert-Equal 'ESXi profile MACs collected' 2 $esx.Macs.Count
Assert-Equal 'service profile templates are not instances' 0 @($inv.ServiceProfiles | Where-Object { $_.Name -eq 'gold' }).Count
Assert-True 'template-bound SP vNIC reference flagged as via template' (@($inv.EtherIfs | Where-Object { $_.Dn -eq 'org-root/ls-esx01/ether-eth0/if-VL200' })[0].ViaTemplate)
Assert-True 'bare-metal direct reference is not via template' (-not @($inv.EtherIfs | Where-Object { $_.Dn -eq 'org-root/ls-bm01/ether-eth0/if-VL500' })[0].ViaTemplate)
Assert-Equal 'native VLANs from the LAN Cloud and vNICs' '10' ($inv.NativeVlanIds -join ',')
Assert-Equal 'in-band VLAN resolved' '700' ($inv.InbandVlanIds -join ',')
Assert-Equal 'VLAN group member resolved' '600' ((@($inv.VlanGroupMembers)[0].VlanIds) -join ',')
Assert-Equal 'template binding recorded for the spare profile' 3 $inv.TemplateBindings['org-root/lan-conn-templ-ESX-A0'].Count
$unread = New-UcsFixture; $unread.PooledVlan = $null
Assert-True 'unreadable VLAN groups are a warning, not silence' (@((ConvertTo-UcsVlanInventory @unread).Warnings | Where-Object { $_ -like '*VLAN group*' }).Count -eq 1)
$dupe = New-UcsFixture; $dupe.Vlan = @($dupe.Vlan) + @(UcsVlan 'vl100' 101)
Assert-True 'a VLAN name defined twice (case-insensitively) is a warning' (@((ConvertTo-UcsVlanInventory @dupe).Warnings | Where-Object { $_ -like "*'vl100'*" }).Count -eq 1)

# ---- vCenter evidence and scope --------------------------------------------------------------
Write-Host "`n=== vCenter evidence and scope ===" -ForegroundColor Cyan
$run = Invoke-Audit
$ev = $run.Evidence
Assert-Equal 'hosts collected' 4 $ev.Hosts.Count
Assert-True 'esx01 CDP names its domain' ((@($ev.Hosts | Where-Object { $_.ESXiHost -eq 'esx01' })[0].DiscoveredUcsm) -contains 'PD24000001SS101')
Assert-True 'VM template NIC collected and flagged' (@($ev.VmNics | Where-Object { $_.IsTemplate }).Count -eq 1)
Assert-True 'opaque backing is a failure, tagged with its cluster' (@($ev.Failures | Where-Object { $_.Category -eq 'UNRESOLVED NIC BACKING' -and $_.ClusterKey -eq 'vc1.test|ClusterComputeResource-domain-c2' }).Count -eq 1)
$sc = $run.Scope
$map = @{}; foreach ($r in $sc.ServiceProfileMapping) { $map[$r.ServiceProfile] = $r.Match }
Assert-Equal 'esx01 matched by MAC' 'MATCHED' $map['esx01']
Assert-Equal 'esx02 matched by MAC' 'MATCHED' $map['esx02']
Assert-Equal 'bare metal is unmatched' 'UNMATCHED' $map['bm01']
Assert-Equal 'spare profile is unassociated' 'UNASSOCIATED' $map['spare']
Assert-Equal 'only the unmatched associated profile is protected' 'bm01' ((@($sc.ProtectedServiceProfiles) | ForEach-Object { $_.Name }) -join ',')
Assert-Equal 'in-scope cluster derived from matched hosts' 'CL-PROD' ($sc.ClusterNames -join ',')
$coverage = @{}; foreach ($r in $sc.HostCoverage) { $coverage[$r.ESXiHost] = $r.Result }
Assert-Equal 'esx01: MAC and CDP agree' 'MATCHED - MAC AND CDP/LLDP' $coverage['esx01']
Assert-Equal 'esx02: MAC only' 'MATCHED - MAC ONLY (no CDP/LLDP neighbour)' $coverage['esx02']
Assert-Equal 'esx03: cluster also spans another allowlisted domain' 'OTHER UCS DOMAIN' $coverage['esx03']
Assert-True 'host outside the domain clusters is not in coverage' (-not $coverage.ContainsKey('esx99'))
Assert-Equal 'failures outside scope do not warn' 0 $sc.Warnings.Count
Assert-True 'out-of-scope failures kept for the record' ($sc.OutOfScopeFailures.Count -ge 2)

# ---- Usage and classification ----------------------------------------------------------------
Write-Host "`n=== Usage and classification ===" -ForegroundColor Cyan
$u = $run.Usage
Assert-True 'VLAN 100 used by a VM in scope' ($u.ClusterVmVlans -contains 100)
Assert-True 'VLAN 400 used by a VM elsewhere on the shared DV port group' ($u.ClusterVmVlans -contains 400)
Assert-True 'VLAN 800 used only by a VM template' ($u.ClusterVmVlans -contains 800)
Assert-True 'VLAN 4000 used by VMkernel' ($u.VmkernelVlans -contains 4000)
Assert-Equal 'trunk port group in use protects its range' '300,301' ($u.RangeProtected -join ',')
Assert-Equal 'unused DV port group reported zero-VM' 'pg-200' ((@($u.ZeroVmRows) | ForEach-Object { $_.PortGroup }) -join ',')
Assert-Equal 'VLAN 0 in use recorded as untagged' 1 @($u.UntaggedInUse | Where-Object { $_.Name -eq 'Mgmt' }).Count

$r = $run.Result
Assert-Equal 'exactly one candidate: VLAN 200' '200' ($r.CandidateIds -join ',')
Assert-Equal 'run is complete' 'COMPLETE' $r.Overall
Assert-Equal 'candidate classified' 'UCSM CLEANUP CANDIDATE' (Get-FinalRow $r 200).UCSMClassification
Assert-Equal 'VLAN 1 is never in the comparison' 0 @((Get-Sheet $r 'Final Comparison') | Where-Object { $_.VLANID -eq 1 }).Count
Assert-True 'VMkernel VLAN 4000 missing from the LAN Cloud' ($r.MissingIds -contains 4000)
foreach ($case in @(
        @{ Id = 10; Source = 'Native/untagged' }, @{ Id = 100; Source = 'Cluster VM' }, @{ Id = 300; Source = 'Trunk/PVLAN/guest-tagging port group' },
        @{ Id = 400; Source = 'Cluster VM' }, @{ Id = 500; Source = 'Unmatched service profile' }, @{ Id = 600; Source = 'VLAN group' },
        @{ Id = 700; Source = 'In-band management' }, @{ Id = 800; Source = 'Cluster VM' })) {
    $row = Get-FinalRow $r $case.Id
    Assert-True "VLAN $($case.Id) protected by '$($case.Source)'" (($row.UCSMClassification -eq 'REQUIRED / PROTECTED') -and ($row.RequirementSources -like "*$($case.Source)*"))
}
Assert-Equal 'direct bare-metal reference counted for VLAN 500' 1 (Get-FinalRow $r 500).DirectVnicReferences
Assert-Equal 'LAN Cloud validation separates direct use from absence' 'NOT IN ANY TEMPLATE - USED DIRECTLY ON A vNIC' (@((Get-Sheet $r 'LAN Cloud Validation') | Where-Object { $_.VLANID -eq 500 })[0].Validation)
Assert-Equal 'zero-VM port group and UCSM candidate reviewed together' 'REVIEW BOTH VCENTER AND UCSM' (Get-FinalRow $r 200).CombinedReview

$m = $r.Manifest
Assert-Equal 'manifest names the domain' 'PD24000001SS101' $m.UCSM
Assert-Equal 'manifest carries one candidate' 1 @($m.Candidates).Count
$c = @($m.Candidates)[0]
Assert-Equal 'manifest candidate LAN Cloud VLAN' 'fabric/lan/net-VL200' ((@($c.LanCloudVlans) | ForEach-Object { $_.Dn }) -join ',')
Assert-Equal 'manifest candidate template memberships' 'org-root/lan-conn-templ-ESX-A0,org-root/lan-conn-templ-ESX-B1' ((@($c.TemplateMemberships) | ForEach-Object { $_.TemplateDn } | Sort-Object) -join ',')
Assert-Equal 'matched service profiles recorded for the removal re-check' 'org-root/ls-esx01,org-root/ls-esx02' ($m.MatchedServiceProfileDns -join ',')
$json = ConvertTo-Json -InputObject $m -Depth 8 | ConvertFrom-Json
Assert-Equal 'manifest survives a JSON round trip' 200 @($json.Candidates)[0].VlanId
Assert-Equal 'resolved IDs survive the round trip as an array' 1 @(@(@($json.Candidates)[0].TemplateMemberships)[0].ResolvedVlanIds).Count

# ---- Things that must make the run preliminary, and things that must not ---------------------
Write-Host "`n=== Preliminary gates ===" -ForegroundColor Cyan
$r2 = (Invoke-Audit -Confirmation (Get-Confirmation -Scope $false)).Result
Assert-Equal 'unconfirmed scope makes the run preliminary' 'WARNING - DO NOT USE FOR DELETION' $r2.Overall
Assert-Equal 'and the candidate is labelled preliminary' 'PRELIMINARY UCSM CLEANUP CANDIDATE' (Get-FinalRow $r2 200).UCSMClassification
Assert-Equal 'and the manifest says so' 'PRELIMINARY UCSM CLEANUP CANDIDATE' @($r2.Manifest.Candidates)[0].Classification

$r3 = (Invoke-Audit -Confirmation (Get-Confirmation -Side 'DR' -Dr @(100, 2999))).Result
Assert-Equal 'a DR VLAN missing from the LAN Cloud is reported...' 1 @((Get-Sheet $r3 'DR Coverage') | Where-Object { $_.Result -eq 'DR MISSING FROM LAN CLOUD' }).Count
Assert-Equal '...but does not make the candidates preliminary' 'COMPLETE' $r3.Overall
$r4 = (Invoke-Audit -Confirmation (Get-Confirmation -Side 'DR' -Dr @())).Result
Assert-Equal 'DR side with no DR list is preliminary' 'WARNING - DO NOT USE FOR DELETION' $r4.Overall

$r5 = (Invoke-Audit -VCenter (New-VCenterFixture -VgtInUse)).Result
Assert-Equal 'a guest-tagging (4095) port group in use protects every VLAN' 0 $r5.CandidateIds.Count

$vcAmbiguous = New-VCenterFixture
$vcAmbiguous.HostView[3].Config.Network.Pnic = @(Pnic 'vmnic0' '00:25:b5:00:00:01')
$a = Invoke-Audit -VCenter $vcAmbiguous
Assert-Equal 'overlapping MAC pools make the profile ambiguous' 'AMBIGUOUS' (@($a.Scope.ServiceProfileMapping | Where-Object { $_.ServiceProfile -eq 'esx01' })[0].Match)
Assert-Equal 'and the run preliminary' 'WARNING - DO NOT USE FOR DELETION' $a.Result.Overall

$vcCdpOnly = New-VCenterFixture
$vcCdpOnly.DiscoveryHint['HostSystem-host-3'] = [pscustomobject]@{ Hints = @((Hint 'vmnic0' 'PD24000001SS101-A')); Error = '' }
$b = Invoke-Audit -VCenter $vcCdpOnly
Assert-Equal 'a host CDP ties to the domain but no profile MAC matches is flagged' 'CDP/LLDP ONLY - NO SERVICE PROFILE MAC MATCH' (@($b.Scope.HostCoverage | Where-Object { $_.ESXiHost -eq 'esx03' })[0].Result)
Assert-Equal 'and the run preliminary' 'WARNING - DO NOT USE FOR DELETION' $b.Result.Overall

$vcFail = New-VCenterFixture
$vcFail.DiscoveryHint['HostSystem-host-2'] = [pscustomobject]@{ Hints = @(); Error = 'timeout' }
Assert-Equal 'a collection failure on an in-scope host is preliminary' 'WARNING - DO NOT USE FOR DELETION' (Invoke-Audit -VCenter $vcFail).Result.Overall

$noHosts = Invoke-Audit -VCenter @{ VCenter = 'vc2.test'; ComputeView = @(); HostView = @(); DvsView = @(); PortgroupView = @(); VmView = @(); DiscoveryHint = @{}; AllowedUcsName = $MasterUcsList }
Assert-True 'no host on the domain found is a warning' (@($noHosts.Result.Warnings | Where-Object { $_ -like 'No ESXi host*' }).Count -eq 1)
Assert-True 'and with nothing matched, every associated profile protects its VLANs' (-not ($noHosts.Result.CandidateIds -contains 100))

# ---- Template pair audit ---------------------------------------------------------------------
Write-Host "`n=== Template pair audit ===" -ForegroundColor Cyan
$pairs = $run.Pairs
# Pairing is by base name and number (vNIC0 / vNIC1), exactly as v7.5 - ESX-A0 and ESX-B1 have
# different bases, so each is reported without a partner rather than silently compared.
Assert-Equal 'templates with different base names are not paired' 2 @($pairs | Where-Object { $_.Reason -eq 'Partner template missing' }).Count
$t = @(
    [pscustomobject]@{ Name = 'vNIC0'; Dn = 'org-root/lan-conn-templ-vNIC0' }, [pscustomobject]@{ Name = 'vNIC1'; Dn = 'org-root/lan-conn-templ-vNIC1' },
    [pscustomobject]@{ Name = 'vNIC2'; Dn = 'org-root/lan-conn-templ-vNIC2' }, [pscustomobject]@{ Name = 'vNIC5'; Dn = 'org-root/lan-conn-templ-vNIC5' },
    [pscustomobject]@{ Name = 'vNIC0'; Dn = 'org-root/org-T/lan-conn-templ-vNIC0' })
$mem = @(
    [pscustomobject]@{ TemplateDn = 'org-root/lan-conn-templ-vNIC0'; VLANID = '10'; VLANName = 'V10'; NativeVLAN = 'No' }
    [pscustomobject]@{ TemplateDn = 'org-root/lan-conn-templ-vNIC1'; VLANID = '10'; VLANName = 'V10'; NativeVLAN = 'Yes' }
    [pscustomobject]@{ TemplateDn = 'org-root/lan-conn-templ-vNIC1'; VLANID = '11'; VLANName = 'V11'; NativeVLAN = 'No' })
$p2 = @(Get-TemplatePairAudit -Template $t -Membership $mem)
Assert-Equal 'native difference found' 'Native status differs' (@($p2 | Where-Object { $_.VLANID -eq 10 })[0].Reason)
Assert-Equal 'missing VLAN found' 'VLAN 11 missing from vNIC0' (@($p2 | Where-Object { $_.VLANID -eq 11 })[0].Reason)
Assert-Equal 'even template without partner reported' 1 @($p2 | Where-Object { $_.Pair -eq 'vNIC2 / vNIC3' }).Count
Assert-Equal 'odd template without partner reported (v7.5 skipped it)' 1 @($p2 | Where-Object { $_.Pair -eq 'vNIC4 / vNIC5' }).Count
Assert-Equal 'same-named template in another org is its own group' 1 @($p2 | Where-Object { $_.Pair -eq 'vNIC0 / vNIC1' -and $_.Reason -eq 'Partner template missing' }).Count

# ---- Reports ---------------------------------------------------------------------------------
Write-Host "`n=== Reports ===" -ForegroundColor Cyan
$cells = ConvertTo-CellMatrix -Row @([pscustomobject]@{ A = 1; B = '100-110'; C = @(1, 2) }, [pscustomobject]@{ A = 2; B = 'x' }) -Header @('A', 'B', 'C')
Assert-Equal 'matrix has a header row plus one row per record' 3 $cells.Matrix.GetLength(0)
Assert-Equal 'numbers stay numbers' 2 $cells.Matrix[2, 0]
Assert-True 'numeric column is not forced to text' (-not $cells.TextColumn[0])
Assert-True "a column holding '100-110' is written as text, not turned into a date" $cells.TextColumn[1]
Assert-Equal 'collections joined' '1; 2' $cells.Matrix[1, 2]
Assert-Equal 'missing property is an empty cell, not a StrictMode error' '' $cells.Matrix[2, 2]
Assert-Equal 'empty sheet still has header and one blank row' 2 (ConvertTo-CellMatrix -Row @() -Header @('A')).Matrix.GetLength(0)
$csv = Join-Path ([IO.Path]::GetTempPath()) ("vlan-audit-" + [Guid]::NewGuid().ToString('N') + '.csv')
Export-ReportCsv -Path $csv -Row @() -Header @('A', 'B')
Assert-Equal 'empty CSV has the headers' '"A","B"' (Get-Content $csv)[0]
Export-ReportCsv -Path $csv -Row @([pscustomobject]@{ A = @(3, 4); B = $null }) -Header @('A', 'B')
Assert-Equal 'arrays joined in CSV' '3; 4' (Import-Csv $csv)[0].A
Remove-Item $csv -Force
$folder = Join-Path ([IO.Path]::GetTempPath()) ("vlan-audit-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder | Out-Null
Export-AuditReport -Folder $folder -BaseName 'T' -Result $r -ReportFormat 'CSV' -ExcelAvailable $false
Assert-Equal 'one CSV per sheet' $r.Sheets.Count @(Get-ChildItem $folder -Filter '*.csv').Count
Assert-True 'candidates.json always written' (Test-Path (Join-Path $folder 'candidates.json'))
Assert-Equal 'candidates.json reads back' 'COMPLETE' (Get-Content (Join-Path $folder 'candidates.json') -Raw | ConvertFrom-Json).Overall
Remove-Item $folder -Recurse -Force

# ---- Prompts ---------------------------------------------------------------------------------
Write-Host "`n=== Prompts ===" -ForegroundColor Cyan
$script:Answers.Enqueue('9'); $script:Answers.Enqueue('x'); $script:Answers.Enqueue('2')
Assert-Equal 'menu re-asks until a valid number' 2 (Read-MenuChoice -Title 'T' -Option @('a', 'b'))
Assert-True 'answer is logged' (@($script:Log | Where-Object { $_ -like '*T: 2. b*' }).Count -eq 1)
foreach ($a in @('2', '1', '3', '4,1')) { $script:Answers.Enqueue($a) }
Assert-Equal "'Select one' returns one" 'a' ((@(Read-TargetSelection -Item @('a', 'b', 'c', 'd') -Title 'S')) -join ',')
Assert-Equal "'Select multiple' returns several, in the order given" 'd,a' ((@(Read-TargetSelection -Item @('a', 'b', 'c', 'd') -Title 'S')) -join ',')

# ---- UCS login timeout -----------------------------------------------------------------------
Write-Host "`n=== UCS login timeout ===" -ForegroundColor Cyan
$moduleDir = Join-Path ([IO.Path]::GetTempPath()) ("FakeUcs-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $moduleDir | Out-Null
Set-Content -Path (Join-Path $moduleDir 'FakeUcs.psm1') -Value @'
function Connect-Ucs { param($Name, $Credential)
    if ($Name -eq 'slow') { Start-Sleep -Seconds 30 }
    if ($Name -eq 'bad') { throw 'Authentication failed' }
    [pscustomobject]@{ Name = $Name; Cookie = 'abc' }
}
'@
Import-Module (Join-Path $moduleDir 'FakeUcs.psm1') -Force
$cred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
Assert-Equal 'connects and returns the session' 'fast' (Connect-UcsWithTimeout -Server 'fast' -Credential $cred -TimeoutSeconds 20).Name
$sw = [Diagnostics.Stopwatch]::StartNew()
Assert-Throws 'a hung login times out' { Connect-UcsWithTimeout -Server 'slow' -Credential $cred -TimeoutSeconds 2 } '*timed out after 2 seconds*'
Assert-True 'and does not wait for the hung call' ($sw.Elapsed.TotalSeconds -lt 15)
Assert-Throws 'a failed login surfaces the error' { Connect-UcsWithTimeout -Server 'bad' -Credential $cred -TimeoutSeconds 20 } '*Authentication failed*'
Remove-Module FakeUcs -Force
Remove-Item $moduleDir -Recurse -Force

# ---- Read-only guarantee ---------------------------------------------------------------------
Write-Host "`n=== Read-only guarantee ===" -ForegroundColor Cyan
$mutating = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
    ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and ($functions.Name -notcontains $_) } |
    Where-Object { $_ -match '^(Set|Remove|Add|New|Update|Start|Stop|Restart|Move|Invoke|Sync|Reset|Mount|Dismount)-(Ucs|VM|VD|VirtualPortGroup|VirtualSwitch|VMHost|Cluster|Datacenter|Folder|Template|NetworkAdapter)' } |
    Sort-Object -Unique)
Assert-Equal 'no mutating UCS PowerTool or PowerCLI cmdlet is called' '' ($mutating -join ', ')
Assert-Equal 'no Write-Host (house rule)' 0 @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Host' }, $true)).Count
Assert-True 'StrictMode Latest is set' ($ast.Extent.Text -match "(?m)^Set-StrictMode -Version Latest")

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
