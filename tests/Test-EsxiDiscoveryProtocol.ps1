<#
.SYNOPSIS
    Tests that BOTH CDP and LLDP are read from a host, and that every name a host reports is tried.

.DESCRIPTION
    THE LIVE FAULT. Five hosts reported NO_CDP_LLDP for neighbours plainly visible in ESXi, and the
    whole cluster fell through to the manual UCSM prompt. The reader looked at
    PhysicalNicHintInfo.ConnectedSwitchPort - CDP - and never at LldpInfo, while every message about
    it said "CDP/LLDP". On a domain running LLDP with CDP disabled, which is ordinary on
    6400-series fabric interconnects, ConnectedSwitchPort is null and there was nothing to find.

    Two further things this pins down:

      - PhysicalNicCdpInfo carries devId AND systemName, and they are not always the same string.
        Only devId was read.
      - LLDP has no system name field. LinkLayerDiscoveryProtocolInfo carries ChassisId, PortId and
        a Parameter[] of key/value pairs, and the system name arrives in there with whatever
        spelling the sender chose. ChassisId is the fallback - but on a fabric interconnect it is
        usually a MAC, which is no use as a name and must not be offered as one.

    Standalone - no Pester, no PowerCLI, no vCenter.

.EXAMPLE
    pwsh -File ./tests/Test-EsxiDiscoveryProtocol.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-EsxiDiscoveryProtocolInfo','Get-LldpSystemName','Get-EsxiDiscoveryCandidate',
                                 'Get-EsxiPreferredDiscovery','Resolve-IntersightCsvMatchFromHost',
                                 'Get-IntersightMatchKeyList','Resolve-IntersightCsvMatch','Get-ShortHostName',
                                 'Remove-UcsTargetDecoration') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

$Global:EsxiDiscoveryCache = @{}
$Global:IntersightServerList = @{}

# --- A host, and what its NICs report ------------------------------------------------------------
$script:Hints = @{}
function New-Cdp { param($DevId,$SystemName,$PortId = 'Eth1/1')
    [pscustomobject]@{ DevId = $DevId; SystemName = $SystemName; PortId = $PortId } }
function New-Lldp { param($SystemName,$ChassisId = '',$PortId = 'Eth1/1',$Key = 'System Name')
    $parameters = @()
    if (-not [string]::IsNullOrWhiteSpace($SystemName)) { $parameters = @([pscustomobject]@{ Key = $Key; Value = $SystemName }) }
    [pscustomobject]@{ ChassisId = $ChassisId; PortId = $PortId; TimeToLive = 120; Parameter = $parameters } }

function Get-View {
    param($Id,$ErrorAction)
    if ("$Id" -like 'network-*') {
        return [pscustomobject]@{ } | Add-Member -MemberType ScriptMethod -Name QueryNetworkHint -Value {
            param($device)
            if (-not $script:Hints.ContainsKey($device)) { return @() }
            return @($script:Hints[$device])
        } -PassThru
    }
    return [pscustomobject]@{
        ConfigManager = [pscustomobject]@{ NetworkSystem = 'network-1' }
        Config = [pscustomobject]@{ Network = [pscustomobject]@{
            Pnic = @($script:Hints.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Device = $_ } }) } }
    }
}

$vmhost = [pscustomobject]@{ Name = 'siepd24vcp0457.dpe.protected.mil.au'; Id = 'HostSystem-host-1' }
function Reset-Host { $script:Hints = @{}; $Global:EsxiDiscoveryCache = @{} }

Write-Host "`n=== LLDP alone is enough - this is the fault that was reported ===" -ForegroundColor Cyan
# CDP disabled on the fabric interconnects, LLDP on. ConnectedSwitchPort is null, and the old
# reader found nothing at all.
Reset-Host
$script:Hints['vmnic0'] = [pscustomobject]@{ Device='vmnic0'; ConnectedSwitchPort=$null; LldpInfo=(New-Lldp -SystemName 'PD24000001SS004-A') }
$rows = @(Get-EsxiDiscoveryProtocolInfo -VMHostObject $vmhost)
Assert-Equal "the neighbour is found" 1 $rows.Count
Assert-Equal "with the LLDP system name" "PD24000001SS004-A" $rows[0].SystemName
Assert-Equal "tagged as LLDP" "LLDP" $rows[0].Source
Assert-Equal "and the vmnic it came from" "vmnic0" $rows[0].Vmnic

Write-Host "`n=== CDP alone still works, and both its name fields are read ===" -ForegroundColor Cyan
# devId and systemName are not always the same string, and only devId used to be read.
Reset-Host
$script:Hints['vmnic0'] = [pscustomobject]@{ Device='vmnic0'
    ConnectedSwitchPort=(New-Cdp -DevId 'SS004-A(SSI12345678)' -SystemName 'PD24000001SS004-A'); LldpInfo=$null }
$rows = @(Get-EsxiDiscoveryProtocolInfo -VMHostObject $vmhost)
Assert-Equal "both CDP names are offered" 2 $rows.Count
Assert-Equal "systemName first - it is the one the export is keyed on" "PD24000001SS004-A" $rows[0].SystemName
Assert-Equal "devId second" "SS004-A(SSI12345678)" $rows[1].SystemName
Assert-Equal "both tagged CDP" 2 (@($rows | Where-Object { $_.Source -eq 'CDP' }).Count)

Write-Host "`n=== Both protocols on one NIC, with no duplicates ===" -ForegroundColor Cyan
Reset-Host
$script:Hints['vmnic0'] = [pscustomobject]@{ Device='vmnic0'
    ConnectedSwitchPort=(New-Cdp -DevId 'PD24000001SS004-A' -SystemName 'PD24000001SS004-A')
    LldpInfo=(New-Lldp -SystemName 'PD24000001SS004-A') }
$rows = @(Get-EsxiDiscoveryProtocolInfo -VMHostObject $vmhost)
Assert-Equal "the same name is not offered three times" 1 $rows.Count
Assert-Equal "and CDP won, being read first" "CDP" $rows[0].Source

Write-Host "`n=== LLDP system names arrive under whatever key the sender chose ===" -ForegroundColor Cyan
foreach ($key in @('System Name','SystemName','system name','sysName','  System Name  ')) {
    Assert-Equal "'$($key.Trim())' is recognised" "FI-A" (Get-LldpSystemName -LldpInfo (New-Lldp -SystemName 'FI-A' -Key $key))
}
Assert-Equal "an unrelated parameter is not mistaken for it" "" (Get-LldpSystemName -LldpInfo (New-Lldp -SystemName 'a description' -Key 'System Description'))

Write-Host "`n=== A MAC chassis id is not a name ===" -ForegroundColor Cyan
# On a fabric interconnect the chassis id is usually the MAC. Offering it would send the run off to
# build a UCSM FQDN out of hex.
foreach ($mac in @('00:2a:6a:11:22:33','00-2a-6a-11-22-33','002a6a112233')) {
    Assert-Equal "'$mac' is rejected" "" (Get-LldpSystemName -LldpInfo (New-Lldp -SystemName '' -ChassisId $mac))
}
Assert-Equal "a real name in the chassis id IS used" "PD24000001SS004-A" (Get-LldpSystemName -LldpInfo (New-Lldp -SystemName '' -ChassisId 'PD24000001SS004-A'))
Assert-Equal "and nothing at all yields nothing" "" (Get-LldpSystemName -LldpInfo (New-Lldp -SystemName '' -ChassisId ''))

Write-Host "`n=== Low-numbered uplinks come first, but nothing is discarded ===" -ForegroundColor Cyan
Reset-Host
$script:Hints['vmnic7'] = [pscustomobject]@{ Device='vmnic7'; ConnectedSwitchPort=$null; LldpInfo=(New-Lldp -SystemName 'SPINE-99') }
$script:Hints['vmnic1'] = [pscustomobject]@{ Device='vmnic1'; ConnectedSwitchPort=$null; LldpInfo=(New-Lldp -SystemName 'PD24000001SS004-B') }
$candidates = @(Get-EsxiDiscoveryCandidate -VMHostObject $vmhost)
Assert-Equal "both are kept" 2 $candidates.Count
Assert-Equal "the fabric uplink is first" "PD24000001SS004-B" $candidates[0].SystemName
Assert-Equal "and the preferred row is that one" "PD24000001SS004-B" (Get-EsxiPreferredDiscovery -VMHostObject $vmhost).SystemName

Write-Host "`n=== The query is made once per host ===" -ForegroundColor Cyan
# QueryNetworkHint is the slowest call in the discovery phase, and two passes need the same answer.
$script:Queries = 0
function Get-View {
    param($Id,$ErrorAction)
    if ("$Id" -like 'network-*') {
        return [pscustomobject]@{ } | Add-Member -MemberType ScriptMethod -Name QueryNetworkHint -Value {
            param($device)
            $script:Queries++
            if (-not $script:Hints.ContainsKey($device)) { return @() }
            return @($script:Hints[$device])
        } -PassThru
    }
    return [pscustomobject]@{
        ConfigManager = [pscustomobject]@{ NetworkSystem = 'network-1' }
        Config = [pscustomobject]@{ Network = [pscustomobject]@{
            Pnic = @($script:Hints.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Device = $_ } }) } }
    }
}
$Global:EsxiDiscoveryCache = @{}
$script:Queries = 0
[void](Get-EsxiDiscoveryCandidate -VMHostObject $vmhost)
$first = $script:Queries
[void](Get-EsxiDiscoveryCandidate -VMHostObject $vmhost)
[void](Get-EsxiPreferredDiscovery -VMHostObject $vmhost)
Assert-Equal "the second and third reads cost nothing" $first $script:Queries

Write-Host "`n=== Every reported name is tried against the Intersight CSV ===" -ForegroundColor Cyan
# A blade can report a CDP devId that is not in the export alongside an LLDP system name that is.
# Testing only the first would route an Intersight-managed blade to UCS Manager, where it has no
# service profile at all.
$Global:IntersightServerList = @{}
foreach ($key in (Get-IntersightMatchKeyList -Value 'PD24000001SS004-A')) {
    $Global:IntersightServerList[$key] = [pscustomobject]@{ Name = 'PD24000001SS004-A' }
}
Reset-Host
$script:Hints['vmnic0'] = [pscustomobject]@{ Device='vmnic0'
    ConnectedSwitchPort=(New-Cdp -DevId 'something-not-in-the-export' -SystemName 'also-not-in-it')
    LldpInfo=(New-Lldp -SystemName 'PD24000001SS004-A') }
$hit = Resolve-IntersightCsvMatchFromHost -VMHostObject $vmhost
Assert-Equal "the host is matched" $true ($null -ne $hit)
Assert-Equal "on the LLDP name, not the first one tried" "PD24000001SS004-A" $hit.Discovery.SystemName
Assert-Equal "and the row that matched is carried back" "PD24000001SS004-A" $hit.Match.Row.Name

Reset-Host
$script:Hints['vmnic0'] = [pscustomobject]@{ Device='vmnic0'
    ConnectedSwitchPort=(New-Cdp -DevId 'nothing' -SystemName 'nothing either'); LldpInfo=$null }
Assert-Equal "a host in no export row is not matched" $true ($null -eq (Resolve-IntersightCsvMatchFromHost -VMHostObject $vmhost))

Write-Host "`n=== A host that genuinely reports nothing still reports nothing ===" -ForegroundColor Cyan
Reset-Host
$script:Hints['vmnic0'] = [pscustomobject]@{ Device='vmnic0'; ConnectedSwitchPort=$null; LldpInfo=$null }
Assert-Equal "no candidates" 0 (@(Get-EsxiDiscoveryCandidate -VMHostObject $vmhost)).Count
Assert-Equal "and no preferred row" $true ($null -eq (Get-EsxiPreferredDiscovery -VMHostObject $vmhost))

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
