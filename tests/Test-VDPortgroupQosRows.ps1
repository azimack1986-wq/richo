<#
.SYNOPSIS
    Tests the row rendering in Export-VDPortgroupQos.ps1 against stub API objects.

.DESCRIPTION
    Extracts the helper functions from the script by AST and feeds them objects shaped like the
    vSphere API types they read - a PSTypeName stands in for the .NET type - so the rendering of
    traffic rules, tag actions, VLANs, shaping, inherited policies and the CSV row shape can be
    checked without PowerCLI or a vCenter. Runs under Set-StrictMode -Version Latest, as the
    script does, so a property the script assumes and a stub does not carry fails here.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-VDPortgroupQosRows.ps1
#>

Set-StrictMode -Version Latest

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vsphere/Export-VDPortgroupQos.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors: $(($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')" }

# Every function in the script, so a helper calling another helper resolves. The main body is
# never executed here.
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}
function Assert-Null {
    param([string]$Name, $Actual)
    if ($null -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected null, got '$Actual')" -ForegroundColor Red }
}

# A stub for a vSphere API object: the PSTypeName carries the type the script switches on.
function ConvertTo-ApiStub {
    param([string]$TypeName, [hashtable]$Property = @{})
    $stub = [ordered]@{ PSTypeName = "VMware.Vim.$TypeName" }
    foreach ($key in $Property.Keys) { $stub[$key] = $Property[$key] }
    return [pscustomobject]$stub
}
function ConvertTo-Policy {
    param([string]$TypeName, $Value, [bool]$Inherited = $false)
    return (ConvertTo-ApiStub $TypeName @{ Inherited = $Inherited; Value = $Value })
}
function ConvertTo-Expression {
    param([string]$TypeName, $Value, [bool]$Negate = $false)
    return (ConvertTo-ApiStub $TypeName @{ Value = $Value; Negate = $Negate })
}

$expectedColumns = @(
    'vCenter', 'Datacenter', 'VDSwitch', 'VDSVersion', 'NiocEnabled', 'NiocVersion',
    'PortGroup', 'PortGroupKey', 'Scope', 'PortKey', 'PortConnectee', 'IsUplink', 'PortBinding', 'Vlan',
    'NetworkResourcePool', 'NrpPriorityTag', 'LegacyQosTag',
    'TrafficFilterOverrideAllowed', 'TrafficFilteringEnabled', 'RuleCount',
    'RuleSequence', 'RuleName', 'RuleDirection', 'RuleQualifiers', 'RuleActions', 'CosTag', 'DscpTag',
    'IngressShaping', 'EgressShaping', 'Action', 'Outcome', 'Detail', 'ScriptVersion', 'CollectedUtc'
)

$context = @{
    vCenter = 'vc01'; Datacenter = 'DC1'; VDSwitch = 'dvs-prod'; VDSVersion = '7.0.3'
    NiocEnabled = $true; NiocVersion = 'version3'
    PortGroup = 'PG-App'; PortGroupKey = 'dvportgroup-100'; Scope = 'PortGroup'
    IsUplink = $false; PortBinding = 'Static'; TrafficFilterOverrideAllowed = $false
    NetworkResourcePool = $null; NrpPriorityTag = $null
    ScriptVersion = 'test'; CollectedUtc = '2026-09-17 00:00:00Z'
}

Write-Host "`n=== Property access under strict mode ===" -ForegroundColor Cyan
$stub = ConvertTo-ApiStub 'Anything' @{ Present = 'yes' }
Assert-Equal 'present property is read'          'yes' (Get-PropertyValue $stub 'Present')
Assert-Null  'missing property is null, no throw'       (Get-PropertyValue $stub 'Missing')
Assert-Null  'null object is null'                      (Get-PropertyValue $null 'Present')
Assert-Equal 'type name is the last segment'  'Anything' (Get-TypeName $stub)
Assert-Equal 'policy unwraps to Value'              5    (Get-PolicyValue (ConvertTo-Policy 'IntPolicy' 5))
Assert-Equal 'bare value passes through'            7    (Get-PolicyValue 7)
Assert-Equal 'array property enumerates'            2    (@(Get-PropertyArray (ConvertTo-ApiStub 'X' @{ Items = @('a', 'b') }) 'Items').Count)
Assert-Equal 'missing array property is empty'      0    (@(Get-PropertyArray $stub 'Items').Count)
Assert-Equal 'single-valued property is one item'   1    (@(Get-PropertyArray (ConvertTo-ApiStub 'X' @{ Items = 'only' }) 'Items').Count)

Write-Host "`n=== Inherited policies resolve along the chain ===" -ForegroundColor Cyan
$portSetting = ConvertTo-ApiStub 'VMwareDVSPortSetting' @{ Vlan = (ConvertTo-Policy -TypeName 'VmwareDistributedVirtualSwitchVlanIdSpec' -Value $null -Inherited $true) }
$pgSetting = ConvertTo-ApiStub 'VMwareDVSPortSetting' @{ Vlan = (ConvertTo-ApiStub 'VmwareDistributedVirtualSwitchVlanIdSpec' @{ Inherited = $false; VlanId = 100 }) }
$switchSetting = ConvertTo-ApiStub 'VMwareDVSPortSetting' @{ Vlan = (ConvertTo-ApiStub 'VmwareDistributedVirtualSwitchVlanIdSpec' @{ Inherited = $true; VlanId = 0 }) }
Assert-Equal 'port inherits the port group VLAN'   100 (Get-PropertyValue (Resolve-EffectivePolicy -Name 'Vlan' -SettingChain @($portSetting, $pgSetting, $switchSetting)) 'VlanId')
Assert-Equal 'port group value is its own'          100 (Get-PropertyValue (Resolve-EffectivePolicy -Name 'Vlan' -SettingChain @($pgSetting, $switchSetting)) 'VlanId')
Assert-Equal 'all inherited falls to the outermost'   0 (Get-PropertyValue (Resolve-EffectivePolicy -Name 'Vlan' -SettingChain @($portSetting, $switchSetting)) 'VlanId')
Assert-Null  'missing everywhere is null'               (Resolve-EffectivePolicy -Name 'QosTag' -SettingChain @($portSetting, $pgSetting))
Assert-Null  'null chain is null'                       (Resolve-EffectivePolicy -Name 'Vlan' -SettingChain $null)

Write-Host "`n=== VLAN rendering ===" -ForegroundColor Cyan
Assert-Equal 'untagged'      'None'          (Format-VlanSetting (ConvertTo-ApiStub 'VmwareDistributedVirtualSwitchVlanIdSpec' @{ VlanId = 0 }))
Assert-Equal 'access VLAN'   'VLAN 100'      (Format-VlanSetting (ConvertTo-ApiStub 'VmwareDistributedVirtualSwitchVlanIdSpec' @{ VlanId = 100 }))
Assert-Equal 'trunk ranges'  'Trunk 10-20,30' (Format-VlanSetting (ConvertTo-ApiStub 'VmwareDistributedVirtualSwitchTrunkVlanSpec' @{ VlanId = @(
    (ConvertTo-ApiStub 'NumericRange' @{ Start = 10; End = 20 }),
    (ConvertTo-ApiStub 'NumericRange' @{ Start = 30; End = 30 })) }))
Assert-Equal 'private VLAN'  'PVLAN 101'     (Format-VlanSetting (ConvertTo-ApiStub 'VmwareDistributedVirtualSwitchPvlanSpec' @{ PvlanId = 101 }))
Assert-Equal 'unknown spec reports its type' 'SomeOtherVlanSpec' (Format-VlanSetting (ConvertTo-ApiStub 'SomeOtherVlanSpec'))
Assert-Null  'no VLAN spec is null'                  (Format-VlanSetting $null)

Write-Host "`n=== Traffic shaping rendering ===" -ForegroundColor Cyan
$shapingOff = ConvertTo-ApiStub 'DVSTrafficShapingPolicy' @{ Enabled = (ConvertTo-Policy 'BoolPolicy' $false) }
$shapingOn = ConvertTo-ApiStub 'DVSTrafficShapingPolicy' @{
    Enabled          = (ConvertTo-Policy 'BoolPolicy' $true)
    AverageBandwidth = (ConvertTo-Policy 'LongPolicy' 100000000)
    PeakBandwidth    = (ConvertTo-Policy 'LongPolicy' 200000000)
    BurstSize        = (ConvertTo-Policy 'LongPolicy' 104857600)
}
Assert-Equal 'disabled'  'Disabled' (Format-ShapingPolicy $shapingOff)
Assert-Equal 'enabled, bits to Kbps and bytes to KB' 'Enabled avg=100000Kbps peak=200000Kbps burst=102400KB' (Format-ShapingPolicy $shapingOn)
Assert-Equal 'enabled with a value the API left unset' 'Enabled avg=?Kbps peak=?Kbps burst=?KB' (Format-ShapingPolicy (ConvertTo-ApiStub 'DVSTrafficShapingPolicy' @{ Enabled = (ConvertTo-Policy 'BoolPolicy' $true) }))
Assert-Null  'no policy is null' (Format-ShapingPolicy $null)

Write-Host "`n=== Qualifier rendering ===" -ForegroundColor Cyan
Assert-Equal 'system traffic' 'SystemTraffic=vmotion' (Format-RuleQualifier (ConvertTo-ApiStub 'DvsSystemTrafficNetworkRuleQualifier' @{ TypeOfSystemTraffic = (ConvertTo-Expression 'StringExpression' 'vmotion') }))
Assert-Equal 'negated system traffic' 'SystemTraffic=!vmotion' (Format-RuleQualifier (ConvertTo-ApiStub 'DvsSystemTrafficNetworkRuleQualifier' @{ TypeOfSystemTraffic = (ConvertTo-Expression -TypeName 'StringExpression' -Value 'vmotion' -Negate $true) }))
$ipQualifier = ConvertTo-ApiStub 'DvsIpNetworkRuleQualifier' @{
    SourceAddress      = (ConvertTo-ApiStub 'IpRange' @{ AddressPrefix = '10.1.0.0'; PrefixLength = 16; Negate = $false })
    DestinationAddress = (ConvertTo-ApiStub 'SingleIp' @{ Address = '10.2.3.4'; Negate = $true })
    Protocol           = (ConvertTo-Expression 'IntExpression' 6)
    DestinationIpPort  = (ConvertTo-ApiStub 'DvsIpPortRange' @{ StartPortNumber = 8000; EndPortNumber = 8080; Negate = $false })
}
Assert-Equal 'IP qualifier' 'IP src=10.1.0.0/16 dst=!10.2.3.4 proto=6 dport=8000-8080' (Format-RuleQualifier $ipQualifier)
Assert-Equal 'IP qualifier with nothing set' 'IP any' (Format-RuleQualifier (ConvertTo-ApiStub 'DvsIpNetworkRuleQualifier'))
$macQualifier = ConvertTo-ApiStub 'DvsMacNetworkRuleQualifier' @{
    SourceAddress = (ConvertTo-ApiStub 'SingleMac' @{ Address = '00:50:56:aa:bb:cc'; Negate = $false })
    Protocol      = (ConvertTo-Expression 'IntExpression' 2048)
    VlanId        = (ConvertTo-Expression 'IntExpression' 100)
}
Assert-Equal 'MAC qualifier' 'MAC src=00:50:56:aa:bb:cc ethertype=2048 vlan=100' (Format-RuleQualifier $macQualifier)
Assert-Equal 'unknown qualifier reports its type' 'DvsFutureQualifier' (Format-RuleQualifier (ConvertTo-ApiStub 'DvsFutureQualifier'))

Write-Host "`n=== Action rendering and tag extraction ===" -ForegroundColor Cyan
$tag = Format-RuleAction (ConvertTo-ApiStub 'DvsUpdateTagNetworkRuleAction' @{ QosTag = 5; DscpTag = 46 })
Assert-Equal 'tag summary'  'Tag CoS=5 DSCP=46' $tag.Summary
Assert-Equal 'CoS from QosTag'  5  $tag.CosTag
Assert-Equal 'DSCP from DscpTag' 46 $tag.DscpTag
$cosOnly = Format-RuleAction (ConvertTo-ApiStub 'DvsUpdateTagNetworkRuleAction' @{ QosTag = 3; DscpTag = $null })
Assert-Equal 'CoS only summary' 'Tag CoS=3' $cosOnly.Summary
Assert-Null  'DSCP unset is null' $cosOnly.DscpTag
$negative = Format-RuleAction (ConvertTo-ApiStub 'DvsUpdateTagNetworkRuleAction' @{ QosTag = -1; DscpTag = 0 })
Assert-Null  'negative CoS is unset' $negative.CosTag
Assert-Equal 'DSCP 0 is a real value' 0 $negative.DscpTag
Assert-Equal 'allow'  'Allow' (Format-RuleAction (ConvertTo-ApiStub 'DvsAcceptNetworkRuleAction')).Summary
Assert-Equal 'drop'   'Drop'  (Format-RuleAction (ConvertTo-ApiStub 'DvsDropNetworkRuleAction')).Summary
Assert-Equal 'rate limit' 'RateLimit 1000pps' (Format-RuleAction (ConvertTo-ApiStub 'DvsRateLimitNetworkRuleAction' @{ PacketsPerSecond = 1000 })).Summary
Assert-Equal 'unknown action is trimmed to its middle' 'Future' (Format-RuleAction (ConvertTo-ApiStub 'DvsFutureNetworkRuleAction')).Summary
Assert-Equal 'several actions join' 'Tag CoS=4; Allow' (Format-RuleAction @(
    (ConvertTo-ApiStub 'DvsUpdateTagNetworkRuleAction' @{ QosTag = 4; DscpTag = $null }),
    (ConvertTo-ApiStub 'DvsAcceptNetworkRuleAction'))).Summary
Assert-Equal 'no action is an empty summary' '' (Format-RuleAction $null).Summary

Write-Host "`n=== Ruleset lookup skips other dvfilter agents ===" -ForegroundColor Cyan
$ruleset = ConvertTo-ApiStub 'DvsTrafficRuleset' @{ Enabled = $true; Rules = @() }
$filterPolicy = ConvertTo-ApiStub 'DvsFilterPolicy' @{ Inherited = $false; FilterConfig = @(
    (ConvertTo-ApiStub 'DvsFilterConfig' @{ AgentName = 'some-other-agent' }),
    (ConvertTo-ApiStub 'DvsTrafficFilterConfig' @{ AgentName = 'dvfilter-generic-vmware'; TrafficRuleset = $ruleset })) }
Assert-Equal 'finds the traffic ruleset behind a foreign agent' $true (Get-PropertyValue (Get-TrafficRuleset $filterPolicy) 'Enabled')
Assert-Null  'no filter config is null' (Get-TrafficRuleset (ConvertTo-ApiStub 'DvsFilterPolicy' @{ Inherited = $true }))
Assert-Null  'null policy is null'      (Get-TrafficRuleset $null)

Write-Host "`n=== Row shape ===" -ForegroundColor Cyan
$row = ConvertTo-QosRow -Values @{ vCenter = 'vc01' }
Assert-Equal 'every column present, in order' ($expectedColumns -join ',') (@($row.PSObject.Properties.Name) -join ',')
Assert-Equal 'given value lands'   'vc01' $row.vCenter
Assert-Null  'missing value is null'      $row.CosTag
$threw = $false
try { ConvertTo-QosRow -Values @{ vCenter = 'vc01'; Typo = 1 } | Out-Null } catch { $threw = $true }
Assert-Equal 'an unknown column is a thrown bug, not a silent drop' $true $threw

Write-Host "`n=== Port group with no rules: one row ===" -ForegroundColor Cyan
$plainSetting = ConvertTo-ApiStub 'VMwareDVSPortSetting' @{
    Vlan             = (ConvertTo-ApiStub 'VmwareDistributedVirtualSwitchVlanIdSpec' @{ Inherited = $false; VlanId = 200 })
    QosTag           = (ConvertTo-Policy -TypeName 'IntPolicy' -Value -1)
    InShapingPolicy  = $shapingOff
    OutShapingPolicy = $shapingOn
    FilterPolicy     = (ConvertTo-ApiStub 'DvsFilterPolicy' @{ Inherited = $true })
}
$rows = @(Get-PortSettingQosRow -Context $context -SettingChain @($plainSetting, $switchSetting))
Assert-Equal 'one row'                 1        $rows.Count
Assert-Equal 'port group carried'      'PG-App' $rows[0].PortGroup
Assert-Equal 'VLAN'                    'VLAN 200' $rows[0].Vlan
Assert-Null  'legacy tag -1 is blank'           $rows[0].LegacyQosTag
Assert-Equal 'rule count 0'            0        $rows[0].RuleCount
Assert-Null  'no filtering state'               $rows[0].TrafficFilteringEnabled
Assert-Null  'no rule sequence'                 $rows[0].RuleSequence
Assert-Null  'no CoS'                           $rows[0].CosTag
Assert-Equal 'ingress shaping'         'Disabled' $rows[0].IngressShaping
Assert-Equal 'egress shaping'          'Enabled avg=100000Kbps peak=200000Kbps burst=102400KB' $rows[0].EgressShaping
Assert-Equal 'script version stamped'  'test'   $rows[0].ScriptVersion

Write-Host "`n=== Port group with rules: one row per rule, ordered by sequence ===" -ForegroundColor Cyan
$rules = @(
    (ConvertTo-ApiStub 'DvsTrafficRule' @{
        Sequence    = 20
        Description = 'Drop telnet'
        Direction   = 'both'
        Qualifier   = @((ConvertTo-ApiStub 'DvsIpNetworkRuleQualifier' @{ Protocol = (ConvertTo-Expression 'IntExpression' 6); DestinationIpPort = (ConvertTo-ApiStub 'DvsSingleIpPort' @{ PortNumber = 23; Negate = $false }) }))
        Action      = (ConvertTo-ApiStub 'DvsDropNetworkRuleAction')
    }),
    (ConvertTo-ApiStub 'DvsTrafficRule' @{
        Sequence    = 10
        Description = 'Mark vMotion'
        Direction   = 'outgoingPackets'
        Qualifier   = @((ConvertTo-ApiStub 'DvsSystemTrafficNetworkRuleQualifier' @{ TypeOfSystemTraffic = (ConvertTo-Expression 'StringExpression' 'vmotion') }))
        Action      = (ConvertTo-ApiStub 'DvsUpdateTagNetworkRuleAction' @{ QosTag = 4; DscpTag = 34 })
    }),
    (ConvertTo-ApiStub 'DvsTrafficRule' @{
        Sequence    = 30
        Description = 'Catch all'
        Direction   = 'incomingPackets'
        Qualifier   = $null
        Action      = (ConvertTo-ApiStub 'DvsAcceptNetworkRuleAction')
    })
)
$ruledSetting = ConvertTo-ApiStub 'VMwareDVSPortSetting' @{
    Vlan         = (ConvertTo-ApiStub 'VmwareDistributedVirtualSwitchVlanIdSpec' @{ Inherited = $false; VlanId = 300 })
    QosTag       = (ConvertTo-Policy 'IntPolicy' 2)
    FilterPolicy = (ConvertTo-ApiStub 'DvsFilterPolicy' @{ Inherited = $false; FilterConfig = @(
        (ConvertTo-ApiStub 'DvsTrafficFilterConfig' @{ AgentName = 'dvfilter-generic-vmware'; TrafficRuleset = (ConvertTo-ApiStub 'DvsTrafficRuleset' @{ Enabled = $true; Rules = $rules }) })) })
}
$rows = @(Get-PortSettingQosRow -Context $context -SettingChain @($ruledSetting, $switchSetting))
Assert-Equal 'three rows'                3   $rows.Count
Assert-Equal 'sorted by sequence'        '10,20,30' (@($rows | ForEach-Object { $_.RuleSequence }) -join ',')
Assert-Equal 'rule count on every row'   '3,3,3' (@($rows | ForEach-Object { $_.RuleCount }) -join ',')
Assert-Equal 'filtering enabled'         $true $rows[0].TrafficFilteringEnabled
Assert-Equal 'legacy tag carried'        2     $rows[0].LegacyQosTag
Assert-Equal 'tag rule name'             'Mark vMotion' $rows[0].RuleName
Assert-Equal 'tag rule direction is the raw API value' 'outgoingPackets' $rows[0].RuleDirection
Assert-Equal 'tag rule qualifier'        'SystemTraffic=vmotion' $rows[0].RuleQualifiers
Assert-Equal 'tag rule action'           'Tag CoS=4 DSCP=34' $rows[0].RuleActions
Assert-Equal 'tag rule CoS'              4  $rows[0].CosTag
Assert-Equal 'tag rule DSCP'             34 $rows[0].DscpTag
Assert-Equal 'drop rule qualifier'       'IP proto=6 dport=23' $rows[1].RuleQualifiers
Assert-Equal 'drop rule action'          'Drop' $rows[1].RuleActions
Assert-Null  'drop rule has no CoS'      $rows[1].CosTag
Assert-Equal 'no qualifier is Any'       'Any' $rows[2].RuleQualifiers
Assert-Equal 'VLAN on every row'         'VLAN 300,VLAN 300,VLAN 300' (@($rows | ForEach-Object { $_.Vlan }) -join ',')
Assert-Null  'no shaping anywhere in the chain is blank' $rows[0].IngressShaping

Write-Host "`n=== Port row inherits the port group's rules and VLAN ===" -ForegroundColor Cyan
$portOwnSetting = ConvertTo-ApiStub 'VMwareDVSPortSetting' @{
    Vlan         = (ConvertTo-ApiStub 'VmwareDistributedVirtualSwitchVlanIdSpec' @{ Inherited = $true; VlanId = 0 })
    FilterPolicy = (ConvertTo-ApiStub 'DvsFilterPolicy' @{ Inherited = $true })
}
$portContext = @{} + $context
$portContext['Scope'] = 'Port'
$portContext['PortKey'] = '42'
$rows = @(Get-PortSettingQosRow -Context $portContext -SettingChain @($portOwnSetting, $ruledSetting, $switchSetting))
Assert-Equal 'port shows the port group rules' 3 $rows.Count
Assert-Equal 'port shows the port group VLAN'  'VLAN 300' $rows[0].Vlan
Assert-Equal 'port scope'                      'Port' $rows[0].Scope
Assert-Equal 'port key'                        '42' $rows[0].PortKey

$portOverride = ConvertTo-ApiStub 'VMwareDVSPortSetting' @{
    FilterPolicy = (ConvertTo-ApiStub 'DvsFilterPolicy' @{ Inherited = $false; FilterConfig = @(
        (ConvertTo-ApiStub 'DvsTrafficFilterConfig' @{ TrafficRuleset = (ConvertTo-ApiStub 'DvsTrafficRuleset' @{ Enabled = $false; Rules = @(
            (ConvertTo-ApiStub 'DvsTrafficRule' @{ Sequence = 10; Description = 'Port only'; Direction = 'both'; Qualifier = @(); Action = (ConvertTo-ApiStub 'DvsUpdateTagNetworkRuleAction' @{ QosTag = 7; DscpTag = $null }) })) }) })) })
}
$rows = @(Get-PortSettingQosRow -Context $portContext -SettingChain @($portOverride, $ruledSetting, $switchSetting))
Assert-Equal 'port override replaces the port group rules' 1 $rows.Count
Assert-Equal 'port override rule'  'Port only' $rows[0].RuleName
Assert-Equal 'port override CoS'   7 $rows[0].CosTag
Assert-Equal 'port override filtering state' $false $rows[0].TrafficFilteringEnabled
Assert-Equal 'port still inherits the VLAN'  'VLAN 300' $rows[0].Vlan

Write-Host "`n=== Name matching and tag text ===" -ForegroundColor Cyan
Assert-Equal 'wildcard match'            $true  (Test-NameMatch -Name 'PG-vMotion-A' -Pattern @('PG-vMotion*'))
Assert-Equal 'any of several patterns'   $true  (Test-NameMatch -Name 'PG-App' -Pattern @('PG-vMotion*', 'PG-App'))
Assert-Equal 'no match'                  $false (Test-NameMatch -Name 'PG-App' -Pattern @('PG-vMotion*'))
Assert-Equal 'both values'  'CoS=5 DSCP=46' (Format-TagValue -Cos 5 -Dscp 46)
Assert-Equal 'CoS only'     'CoS=0'         (Format-TagValue -Cos 0 -Dscp $null)
Assert-Equal 'no value'     'none'          (Format-TagValue -Cos $null -Dscp $null)

Write-Host "`n=== Change plan: SetTag ===" -ForegroundColor Cyan
function ConvertTo-PlanRuleset {
    # Three rules: a marking rule with both values, a Drop rule, a marking rule with CoS only.
    $r = @(
        (ConvertTo-ApiStub 'DvsTrafficRule' @{ Key = 'r1'; Sequence = 10; Description = 'Mark vMotion'; Direction = 'both'; Qualifier = @(); Action = (ConvertTo-ApiStub 'DvsUpdateTagNetworkRuleAction' @{ QosTag = 4; DscpTag = 34 }) }),
        (ConvertTo-ApiStub 'DvsTrafficRule' @{ Key = 'r2'; Sequence = 20; Description = 'Drop telnet'; Direction = 'both'; Qualifier = @(); Action = (ConvertTo-ApiStub 'DvsDropNetworkRuleAction') }),
        (ConvertTo-ApiStub 'DvsTrafficRule' @{ Key = 'r3'; Sequence = 30; Description = 'Mark mgmt'; Direction = 'both'; Qualifier = @(); Action = (ConvertTo-ApiStub 'DvsUpdateTagNetworkRuleAction' @{ QosTag = 5; DscpTag = $null }) })
    )
    return (ConvertTo-ApiStub 'DvsTrafficRuleset' @{ Enabled = $true; Rules = $r })
}
$plan = Get-PortgroupTagPlan -Ruleset (ConvertTo-PlanRuleset) -Action SetTag -CosTag 5
$byId = @{}
foreach ($c in $plan.Changes) { $byId[$c.Id] = $c }
Assert-Equal 'one change planned'                 1 $plan.PlannedCount
Assert-Equal 'vMotion rule planned'               'Planned' $byId['r1'].Outcome
Assert-Equal 'vMotion detail before -> after'     'CoS=4 DSCP=34 -> CoS=5 DSCP=34' $byId['r1'].Detail
Assert-Equal 'only CoS is set'                    $true $byId['r1'].SetCos
Assert-Equal 'DSCP is not touched'                $false $byId['r1'].SetDscp
Assert-Equal 'Drop rule skipped'                  'Skipped' $byId['r2'].Outcome
Assert-Equal 'Drop rule reason names the action'  $true ($byId['r2'].Detail -like 'rule action is Drop, not Tag*')
Assert-Equal 'already-set rule skipped'           'Skipped' $byId['r3'].Outcome
Assert-Equal 'already-set reason'                 'already CoS=5' $byId['r3'].Detail
Assert-Equal 'summary names the change'           $true ($plan.Summary -like "SetTag: 'Mark vMotion' CoS=4 DSCP=34 -> CoS=5 DSCP=34")
Assert-Equal 'nothing removed'                    0 $plan.RemovedIds.Count
$plan = Get-PortgroupTagPlan -Ruleset (ConvertTo-PlanRuleset) -Action SetTag -CosTag 5 -DscpTag 46 -RuleName 'Mark m*'
$byId = @{}
foreach ($c in $plan.Changes) { $byId[$c.Id] = $c }
Assert-Equal 'name filter leaves vMotion as Read'  'Read' $byId['r1'].Outcome
Assert-Equal 'mgmt gains DSCP'                     'CoS=5 -> CoS=5 DSCP=46' $byId['r3'].Detail
Assert-Equal 'null ruleset plans nothing'          0 (Get-PortgroupTagPlan -Ruleset $null -Action SetTag -CosTag 1).Changes.Count

Write-Host "`n=== Change plan: ClearTag and RemoveRule ===" -ForegroundColor Cyan
$plan = Get-PortgroupTagPlan -Ruleset (ConvertTo-PlanRuleset) -Action ClearTag -ClearCos $true
$byId = @{}
foreach ($c in $plan.Changes) { $byId[$c.Id] = $c }
Assert-Equal 'vMotion keeps DSCP'                  'CoS=4 DSCP=34 -> DSCP=34' $byId['r1'].Detail
Assert-Null  'cleared CoS is null'                 $byId['r1'].NewCos
Assert-Equal 'mgmt would be left empty: skipped'   'Skipped' $byId['r3'].Outcome
Assert-Equal 'skip reason points at RemoveRule'    $true ($byId['r3'].Detail -like '*use -Action RemoveRule')
$plan = Get-PortgroupTagPlan -Ruleset (ConvertTo-PlanRuleset) -Action ClearTag -ClearDscp $true -RuleName 'Mark mgmt'
Assert-Equal 'nothing to clear is skipped'         'Skipped' (@($plan.Changes | Where-Object { $_.Id -eq 'r3' })[0].Outcome)
$plan = Get-PortgroupTagPlan -Ruleset (ConvertTo-PlanRuleset) -Action RemoveRule -RuleName '*'
$byId = @{}
foreach ($c in $plan.Changes) { $byId[$c.Id] = $c }
Assert-Equal 'both marking rules removed'          2 $plan.PlannedCount
Assert-Equal 'removed ids'                         'r1,r3' ($plan.RemovedIds -join ',')
Assert-Equal 'Drop rule never removed'             'Skipped' $byId['r2'].Outcome
Assert-Equal 'remove flag set'                     $true $byId['r1'].Remove
Assert-Equal 'remove detail carries old values'    "remove rule 'Mark vMotion' (CoS=4 DSCP=34)" $byId['r1'].Detail

Write-Host "`n=== Outcomes on rows ===" -ForegroundColor Cyan
$ruleSetting = ConvertTo-ApiStub 'VMwareDVSPortSetting' @{
    FilterPolicy = (ConvertTo-ApiStub 'DvsFilterPolicy' @{ Inherited = $false; FilterConfig = @(
        (ConvertTo-ApiStub 'DvsTrafficFilterConfig' @{ TrafficRuleset = (ConvertTo-PlanRuleset) })) })
}
$outcomes = @{ r1 = @{ Outcome = 'Changed'; Detail = 'CoS=4 -> 5' }; r2 = @{ Outcome = 'Skipped'; Detail = 'not Tag' } }
$rows = @(Get-PortSettingQosRow -Context ($context + @{ Action = 'SetTag' }) -SettingChain @($ruleSetting) -RuleOutcome $outcomes)
Assert-Equal 'outcome per rule'        'Changed,Skipped,Read' (@($rows | ForEach-Object { $_.Outcome }) -join ',')
Assert-Equal 'detail per rule'         'CoS=4 -> 5,not Tag,' (@($rows | ForEach-Object { $_.Detail }) -join ',')
Assert-Equal 'action stamped'          'SetTag' $rows[0].Action
$rows = @(Get-PortSettingQosRow -Context $context -SettingChain @($ruleSetting) -RuleOutcome $outcomes -OnlyRuleId @('r3'))
Assert-Equal 'OnlyRuleId filters'      1 $rows.Count
Assert-Equal 'filtered rule'           'Mark mgmt' $rows[0].RuleName
Assert-Equal 'no matching id: no rows' 0 @(Get-PortSettingQosRow -Context $context -SettingChain @($ruleSetting) -OnlyRuleId @('nope')).Count
$rows = @(Get-PortSettingQosRow -Context ($context + @{ Outcome = 'ReadFailed'; Detail = 'boom' }) -SettingChain @($plainSetting))
Assert-Equal 'context outcome wins on the no-rule row' 'ReadFailed' $rows[0].Outcome
Assert-Equal 'default outcome is Read'  'Read' (@(Get-PortSettingQosRow -Context $context -SettingChain @($plainSetting)))[0].Outcome

Write-Host "`n=== Applying a plan (the only write) ===" -ForegroundColor Cyan
$vimTypesAreReal = [bool]('VMware.Vim.DVPortgroupConfigSpec' -as [type])
if ($vimTypesAreReal) {
    Write-Host '  SKIP  real VMware.Vim types are loaded in this session; the apply test uses stubs' -ForegroundColor Yellow
}
else {
    Add-Type -TypeDefinition @'
namespace VMware.Vim {
    public class VMwareDVSPortSetting { public object FilterPolicy; }
    public class DVPortgroupConfigSpec { public string ConfigVersion; public object DefaultPortConfig; }
}
'@
    $script:sentSpec = $null
    $view = ConvertTo-ApiStub 'DistributedVirtualPortgroup' @{
        MoRef  = [pscustomobject]@{ Type = 'DistributedVirtualPortgroup'; Value = 'dvportgroup-1' }
        Config = (ConvertTo-ApiStub 'DVPortgroupConfigInfo' @{ ConfigVersion = '7'; DefaultPortConfig = $ruleSetting })
    }
    $view | Add-Member -MemberType ScriptMethod -Name ReconfigureDVPortgroup -Value { param($spec) $script:sentSpec = $spec } -Force
    function Get-View { param($Id, $Server, $Property) $view }

    $plan = Get-PortgroupTagPlan -Ruleset (Get-TrafficRuleset $ruleSetting.FilterPolicy) -Action SetTag -CosTag 6 -RuleName 'Mark vMotion'
    Invoke-PortgroupTagPlan -PortgroupView $view -Server 'vc' -Plan $plan
    Assert-Equal 'spec sent'                           $true ($null -ne $script:sentSpec)
    Assert-Equal 'config version carried'              '7' $script:sentSpec.ConfigVersion
    Assert-Equal 'port setting type'                   'VMwareDVSPortSetting' $script:sentSpec.DefaultPortConfig.GetType().Name
    Assert-Equal 'policy marked as the port group own' $false $script:sentSpec.DefaultPortConfig.FilterPolicy.Inherited
    Assert-Equal 'filter config marked own'            $false $script:sentSpec.DefaultPortConfig.FilterPolicy.FilterConfig[0].Inherited
    $sentRules = @($script:sentSpec.DefaultPortConfig.FilterPolicy.FilterConfig[0].TrafficRuleset.Rules)
    Assert-Equal 'CoS updated on the rule'             6 (@($sentRules | Where-Object { $_.Key -eq 'r1' })[0].Action.QosTag)
    Assert-Equal 'DSCP untouched'                      34 (@($sentRules | Where-Object { $_.Key -eq 'r1' })[0].Action.DscpTag)
    Assert-Equal 'other rules untouched'               5 (@($sentRules | Where-Object { $_.Key -eq 'r3' })[0].Action.QosTag)

    $script:sentSpec = $null
    $plan = Get-PortgroupTagPlan -Ruleset (Get-TrafficRuleset $ruleSetting.FilterPolicy) -Action RemoveRule -RuleName 'Mark mgmt'
    Invoke-PortgroupTagPlan -PortgroupView $view -Server 'vc' -Plan $plan
    $sentRules = @($script:sentSpec.DefaultPortConfig.FilterPolicy.FilterConfig[0].TrafficRuleset.Rules)
    Assert-Equal 'removed rule gone'                   'r1,r2' (@($sentRules | ForEach-Object { $_.Key }) -join ',')

    $script:sentSpec = $null
    $plan = Get-PortgroupTagPlan -Ruleset (ConvertTo-PlanRuleset) -Action SetTag -CosTag 1 -RuleName 'Mark mgmt'
    $threw = ''
    try { Invoke-PortgroupTagPlan -PortgroupView $view -Server 'vc' -Plan $plan } catch { $threw = $_.Exception.Message }
    Assert-Equal 'rule missing on re-read throws'      $true ($threw -like "rule 'Mark mgmt' no longer exists*")
    Assert-Null  'nothing sent when a rule is missing' $script:sentSpec
}

Write-Host "`n=== Merge-Hashtable ===" -ForegroundColor Cyan
$merged = Merge-Hashtable -Table @(@{ a = 1; b = 1 }, $null, @{ b = 2 })
Assert-Equal 'later table wins' 2 $merged['b']
Assert-Equal 'earlier keys kept' 1 $merged['a']
Assert-Equal 'null table ignored' 2 $merged.Count

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
