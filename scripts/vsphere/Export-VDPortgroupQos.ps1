<#
.SYNOPSIS
    Exports every distributed port group in a vCenter SSO domain with its QoS / CoS settings to CSV.

.DESCRIPTION
    Read-only inventory of traffic marking on vSphere Distributed Switches (VDS).

    Connects to one vCenter, follows Enhanced Linked Mode to every other vCenter in the same SSO
    domain (unless -NoLinked), and walks every VDS on each of them. Every distributed port group,
    uplink port groups included, is written to the CSV with:

      - Traffic filtering and marking rules. One row per rule, carrying the CoS (802.1p, 0-7)
        and DSCP (0-63) values its Tag action applies, plus the rule's direction, qualifiers
        and other actions (Allow, Drop, ...). This is where QoS / CoS is configured on
        vSphere 6.0 and later.
      - The port group's legacy 802.1p QoS tag (VMwareDVSPortSetting.qosTag). Deprecated since
        vSphere 6.0 but still present on older switch versions.
      - Network I/O Control: whether it is enabled on the switch, which version, the network
        resource pool the port group is assigned to and, on NIOC version 2, that pool's
        802.1p priority tag.
      - Ingress and egress traffic shaping.
      - The effective VLAN configuration, for context.
      - Whether individual ports may override the port group's traffic filter and, with
        -IncludePortOverrides, the ports that actually do.

    A port group with no traffic rules still produces one row, so the CSV lists every port group
    in the domain. Filter on CosTag or DscpTag for the ones that mark traffic, and on Scope for
    port-level overrides.

    Self-contained: no repo module and no config file. VMware PowerCLI must already be installed
    on the host. The VMware.VimAutomation.Core and VMware.VimAutomation.Vds modules are loaded
    only if they are not already in the session, so a pinned bundle is left alone, and nothing
    is ever installed.

    Changes nothing on any vCenter. If the session's PowerCLI DefaultVIServerMode is not
    Multiple it is set to Multiple for this session only, because linked-mode connections need
    it. Only the vCenter sessions this script opened are closed at the end.

.PARAMETER Server
    vCenter to connect to. With Enhanced Linked Mode, every other vCenter in its SSO domain is
    connected as well and included in the output.

.PARAMETER Credential
    Credential for the vCenter(s). When omitted PowerCLI uses its own defaults, which on a
    domain-joined Windows host means the current user's session (SSPI) and otherwise a prompt.

.PARAMETER NoLinked
    Connect only to -Server and ignore the other vCenters in its SSO domain.

.PARAMETER OutputPath
    Path of the CSV to write. Defaults to .\output\VDPortgroupQos-<UTC timestamp>.csv under the
    current directory. Missing directories are created.

.PARAMETER IncludePortOverrides
    Also fetch every port on every VDS and add a row (Scope = Port) for each port whose traffic
    filter or legacy QoS tag overrides its port group. This is one extra call per switch that
    returns every port, so it is slower on large switches. Off by default.

.PARAMETER PassThru
    Also emit the rows to the pipeline after the CSV is written.

.EXAMPLE
    .\Export-VDPortgroupQos.ps1 -Server vcenter01.example.com

    Connects to vcenter01 and every vCenter linked to it, and writes
    .\output\VDPortgroupQos-<timestamp>.csv.

.EXAMPLE
    .\Export-VDPortgroupQos.ps1 -Server vcenter01.example.com -Credential (Get-Credential) -OutputPath C:\Temp\pg-qos.csv -IncludePortOverrides

.EXAMPLE
    .\Export-VDPortgroupQos.ps1 -Server vcenter01.example.com -PassThru |
        Where-Object { ($null -ne $_.CosTag) -or ($null -ne $_.DscpTag) } |
        Format-Table vCenter, VDSwitch, PortGroup, RuleName, CosTag, DscpTag

    Only the rules that actually mark traffic, on screen as well as in the CSV.

.NOTES
    CosTag and DscpTag are the QosTag (802.1p CoS, 0-7) and DscpTag (0-63) of a rule's Tag
    action. RuleDirection is the raw API value (incomingPackets, outgoingPackets, both).
    Shaping is reported as the API stores it, converted to Kbps (bits / 1000) and KB
    (bytes / 1024). A blank cell means the API did not report the value.

    Certificate errors on connect are a PowerCLI setting, not this script:
    Set-PowerCLIConfiguration -InvalidCertificateAction Warn -Scope Session
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [pscredential]$Credential,

    [switch]$NoLinked,

    [string]$OutputPath,

    [switch]$IncludePortOverrides,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

# ---- Helpers ----------------------------------------------------------------

function Write-Log {
    <#
    .SYNOPSIS
        Timestamped, levelled log line in the same format as Write-RichoLog, without the module.
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    $line = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message
    switch ($Level) {
        'DEBUG' { Write-Verbose $line }
        'INFO' { Write-Information $line -InformationAction Continue }
        'WARN' { Write-Warning $line }
        # Non-terminating on purpose: the caller decides whether an error ends the run.
        'ERROR' { Write-Error $line -ErrorAction Continue }
    }
}

function Import-RequiredModules {
    <#
    .SYNOPSIS
        Loads the PowerCLI modules this script uses, once, and only if they are not already loaded.

    .DESCRIPTION
        A module already in the session - including a pinned bundle loaded by the host build - is
        left untouched. Nothing is installed or updated. A module that is not present fails here,
        before any connection is attempted, with PowerShell's own message naming it.
    #>
    param(
        [string[]]$ModuleName = @('VMware.VimAutomation.Core', 'VMware.VimAutomation.Vds')
    )

    foreach ($name in $ModuleName) {
        if (Get-Module -Name $name) {
            Write-Log "Module $name is already loaded." -Level DEBUG
            continue
        }
        Write-Log "Loading module $name." -Level DEBUG
        Import-Module -Name $name -ErrorAction Stop
    }
}

function Get-PropertyValue {
    # Value of a property that may not exist on this object type (API versions and vendor switches
    # differ), or $null. Direct access under Set-StrictMode would throw instead.
    param(
        [Parameter(Position = 0)]
        $InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-PropertyArray {
    # The elements of an array-valued property, one at a time, skipping nulls. Wrap the call in
    # @() to get an array; a missing or empty property yields nothing.
    param(
        [Parameter(Position = 0)]
        $InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    $value = Get-PropertyValue $InputObject $Name
    if ($null -eq $value) { return }
    foreach ($item in @($value)) {
        if ($null -ne $item) { $item }
    }
}

function Get-TypeName {
    # Short type name (DvsUpdateTagNetworkRuleAction, IntPolicy, ...) from the object's first
    # PSTypeName, so a stub object carrying a PSTypeName renders the same way as the real thing.
    param(
        [Parameter(Position = 0)]
        $InputObject
    )

    if ($null -eq $InputObject) { return '' }
    $typeName = [string]$InputObject.PSObject.TypeNames[0]
    if ($typeName.StartsWith('Deserialized.')) { $typeName = $typeName.Substring('Deserialized.'.Length) }
    return ($typeName -split '\.')[-1]
}

function Get-PolicyValue {
    # Unwraps an inheritable policy (BoolPolicy, IntPolicy, LongPolicy, StringPolicy) to its Value.
    # Anything without a Value property is returned as it is.
    param(
        [Parameter(Position = 0)]
        $Policy
    )

    if ($null -eq $Policy) { return $null }
    $property = $Policy.PSObject.Properties['Value']
    if ($null -eq $property) { return $Policy }
    return $property.Value
}

function Resolve-EffectivePolicy {
    <#
    .SYNOPSIS
        Picks the policy that actually applies from a chain of port settings, nearest first.

    .DESCRIPTION
        A port setting's policies (Vlan, FilterPolicy, InShapingPolicy, ...) carry an Inherited
        flag. Inherited = $true means "whatever the level above says": the port group's value for
        a port, the switch default port configuration for a port group. The first policy in the
        chain that is not inherited wins; if every level inherits, the outermost one is used.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [object[]]$SettingChain
    )

    $outermost = $null
    foreach ($setting in $SettingChain) {
        $policy = Get-PropertyValue $setting $Name
        if ($null -eq $policy) { continue }
        $outermost = $policy
        if ((Get-PropertyValue $policy 'Inherited') -ne $true) { return $policy }
    }
    return $outermost
}

function Merge-Hashtable {
    # One hashtable from several. Later tables win on duplicate keys.
    param(
        [hashtable[]]$Table
    )

    $merged = @{}
    foreach ($t in $Table) {
        if ($null -eq $t) { continue }
        foreach ($key in $t.Keys) { $merged[$key] = $t[$key] }
    }
    return $merged
}

function Format-VlanSetting {
    # "None", "VLAN 100", "Trunk 10-20,30" or "PVLAN 101" from a VmwareDistributedVirtualSwitch*Spec.
    param(
        [Parameter(Position = 0)]
        $Vlan
    )

    if ($null -eq $Vlan) { return $null }
    switch (Get-TypeName $Vlan) {
        'VmwareDistributedVirtualSwitchVlanIdSpec' {
            $id = Get-PropertyValue $Vlan 'VlanId'
            if (($null -eq $id) -or ([int]$id -eq 0)) { return 'None' }
            return "VLAN $id"
        }
        'VmwareDistributedVirtualSwitchTrunkVlanSpec' {
            $ranges = foreach ($range in @(Get-PropertyArray $Vlan 'VlanId')) {
                $start = Get-PropertyValue $range 'Start'
                $end = Get-PropertyValue $range 'End'
                if ($start -eq $end) { "$start" } else { "${start}-${end}" }
            }
            return 'Trunk ' + (@($ranges) -join ',')
        }
        'VmwareDistributedVirtualSwitchPvlanSpec' {
            return "PVLAN $(Get-PropertyValue $Vlan 'PvlanId')"
        }
        default { return (Get-TypeName $Vlan) }
    }
}

function ConvertTo-KiloString {
    # bits -> Kbit (divide by 1000) or bytes -> KB (divide by 1024); '?' when the API left it unset.
    param(
        $Value,

        [Parameter(Mandatory)]
        [int]$Divisor
    )

    if ($null -eq $Value) { return '?' }
    return [string][math]::Round([double]$Value / $Divisor)
}

function Format-ShapingPolicy {
    # "Disabled" or "Enabled avg=<Kbps> peak=<Kbps> burst=<KB>" from a DVSTrafficShapingPolicy.
    param(
        [Parameter(Position = 0)]
        $Policy
    )

    if ($null -eq $Policy) { return $null }
    if (-not (Get-PolicyValue (Get-PropertyValue $Policy 'Enabled'))) { return 'Disabled' }
    $average = ConvertTo-KiloString -Value (Get-PolicyValue (Get-PropertyValue $Policy 'AverageBandwidth')) -Divisor 1000
    $peak = ConvertTo-KiloString -Value (Get-PolicyValue (Get-PropertyValue $Policy 'PeakBandwidth')) -Divisor 1000
    $burst = ConvertTo-KiloString -Value (Get-PolicyValue (Get-PropertyValue $Policy 'BurstSize')) -Divisor 1024
    return "Enabled avg=${average}Kbps peak=${peak}Kbps burst=${burst}KB"
}

function Format-RuleExpression {
    # IntExpression / StringExpression: the value, with a leading '!' when negated.
    param(
        [Parameter(Position = 0)]
        $Expression
    )

    if ($null -eq $Expression) { return $null }
    $value = Get-PropertyValue $Expression 'Value'
    if ($null -eq $value) { return $null }
    if (Get-PropertyValue $Expression 'Negate') { return "!$value" }
    return "$value"
}

function Format-RuleIpAddress {
    # SingleIp -> "10.1.2.3", IpRange -> "10.1.0.0/16", '!' prefix when negated.
    param(
        [Parameter(Position = 0)]
        $Address
    )

    if ($null -eq $Address) { return $null }
    $text = switch (Get-TypeName $Address) {
        'SingleIp' { Get-PropertyValue $Address 'Address' }
        'IpRange' { "$(Get-PropertyValue $Address 'AddressPrefix')/$(Get-PropertyValue $Address 'PrefixLength')" }
        default { Get-TypeName $Address }
    }
    if (Get-PropertyValue $Address 'Negate') { return "!$text" }
    return "$text"
}

function Format-RuleMacAddress {
    # SingleMac -> "00:50:56:aa:bb:cc", MacRange -> "<address>/<mask>", '!' prefix when negated.
    param(
        [Parameter(Position = 0)]
        $Address
    )

    if ($null -eq $Address) { return $null }
    $text = switch (Get-TypeName $Address) {
        'SingleMac' { Get-PropertyValue $Address 'Address' }
        'MacRange' { "$(Get-PropertyValue $Address 'Address')/$(Get-PropertyValue $Address 'Mask')" }
        default { Get-TypeName $Address }
    }
    if (Get-PropertyValue $Address 'Negate') { return "!$text" }
    return "$text"
}

function Format-RuleIpPort {
    # DvsSingleIpPort -> "443", DvsIpPortRange -> "8000-8080", '!' prefix when negated.
    param(
        [Parameter(Position = 0)]
        $Port
    )

    if ($null -eq $Port) { return $null }
    $text = switch (Get-TypeName $Port) {
        'DvsSingleIpPort' { Get-PropertyValue $Port 'PortNumber' }
        'DvsIpPortRange' { "$(Get-PropertyValue $Port 'StartPortNumber')-$(Get-PropertyValue $Port 'EndPortNumber')" }
        default { Get-TypeName $Port }
    }
    if (Get-PropertyValue $Port 'Negate') { return "!$text" }
    return "$text"
}

function Format-RuleQualifier {
    <#
    .SYNOPSIS
        One qualifier of a traffic rule as a short string: what the rule matches on.

    .DESCRIPTION
        System traffic qualifiers render as "SystemTraffic=vmotion", IP qualifiers as
        "IP src=... dst=... proto=... sport=... dport=... tcpflags=..." with only the parts that
        are set, and MAC qualifiers as "MAC src=... dst=... ethertype=... vlan=...". A qualifier
        type this script does not know is reported by its type name rather than dropped.
    #>
    param(
        [Parameter(Position = 0)]
        $Qualifier
    )

    if ($null -eq $Qualifier) { return $null }
    $typeName = Get-TypeName $Qualifier
    try {
        switch ($typeName) {
            'DvsSystemTrafficNetworkRuleQualifier' {
                return "SystemTraffic=$(Format-RuleExpression (Get-PropertyValue $Qualifier 'TypeOfSystemTraffic'))"
            }
            'DvsIpNetworkRuleQualifier' {
                $parts = New-Object System.Collections.Generic.List[string]
                $source = Format-RuleIpAddress (Get-PropertyValue $Qualifier 'SourceAddress')
                if ($source) { $parts.Add("src=$source") }
                $destination = Format-RuleIpAddress (Get-PropertyValue $Qualifier 'DestinationAddress')
                if ($destination) { $parts.Add("dst=$destination") }
                $protocol = Format-RuleExpression (Get-PropertyValue $Qualifier 'Protocol')
                if ($protocol) { $parts.Add("proto=$protocol") }
                $sourcePort = Format-RuleIpPort (Get-PropertyValue $Qualifier 'SourceIpPort')
                if ($sourcePort) { $parts.Add("sport=$sourcePort") }
                $destinationPort = Format-RuleIpPort (Get-PropertyValue $Qualifier 'DestinationIpPort')
                if ($destinationPort) { $parts.Add("dport=$destinationPort") }
                $tcpFlags = Format-RuleExpression (Get-PropertyValue $Qualifier 'TcpFlags')
                if ($tcpFlags) { $parts.Add("tcpflags=$tcpFlags") }
                if ($parts.Count -eq 0) { return 'IP any' }
                return 'IP ' + ($parts -join ' ')
            }
            'DvsMacNetworkRuleQualifier' {
                $parts = New-Object System.Collections.Generic.List[string]
                $source = Format-RuleMacAddress (Get-PropertyValue $Qualifier 'SourceAddress')
                if ($source) { $parts.Add("src=$source") }
                $destination = Format-RuleMacAddress (Get-PropertyValue $Qualifier 'DestinationAddress')
                if ($destination) { $parts.Add("dst=$destination") }
                $etherType = Format-RuleExpression (Get-PropertyValue $Qualifier 'Protocol')
                if ($etherType) { $parts.Add("ethertype=$etherType") }
                $vlan = Format-RuleExpression (Get-PropertyValue $Qualifier 'VlanId')
                if ($vlan) { $parts.Add("vlan=$vlan") }
                if ($parts.Count -eq 0) { return 'MAC any' }
                return 'MAC ' + ($parts -join ' ')
            }
            default { return $typeName }
        }
    }
    catch {
        Write-Log "Could not render a $typeName qualifier: $($_.Exception.Message)" -Level DEBUG
        return $typeName
    }
}

function Format-RuleAction {
    <#
    .SYNOPSIS
        A rule's action(s) as a summary string, plus the CoS and DSCP values a Tag action applies.

    .DESCRIPTION
        Returns an object with Summary ("Tag CoS=5 DSCP=46", "Allow", "Drop", "RateLimit 1000pps",
        several joined with "; "), CosTag and DscpTag. The tags are $null unless a
        DvsUpdateTagNetworkRuleAction sets them; a negative value is treated as unset.
    #>
    param(
        [Parameter(Position = 0)]
        $Action
    )

    $summaries = New-Object System.Collections.Generic.List[string]
    $cos = $null
    $dscp = $null
    foreach ($item in @($Action)) {
        if ($null -eq $item) { continue }
        $typeName = Get-TypeName $item
        switch ($typeName) {
            'DvsAcceptNetworkRuleAction' { $summaries.Add('Allow') }
            'DvsDropNetworkRuleAction' { $summaries.Add('Drop') }
            'DvsUpdateTagNetworkRuleAction' {
                $text = 'Tag'
                $qosTag = Get-PropertyValue $item 'QosTag'
                if (($null -ne $qosTag) -and ([int]$qosTag -ge 0)) {
                    $cos = [int]$qosTag
                    $text += " CoS=$cos"
                }
                $dscpTag = Get-PropertyValue $item 'DscpTag'
                if (($null -ne $dscpTag) -and ([int]$dscpTag -ge 0)) {
                    $dscp = [int]$dscpTag
                    $text += " DSCP=$dscp"
                }
                $summaries.Add($text)
            }
            'DvsRateLimitNetworkRuleAction' { $summaries.Add("RateLimit $(Get-PropertyValue $item 'PacketsPerSecond')pps") }
            'DvsLogNetworkRuleAction' { $summaries.Add('Log') }
            'DvsCopyNetworkRuleAction' { $summaries.Add('Copy') }
            'DvsPuntNetworkRuleAction' { $summaries.Add('Punt') }
            'DvsGreEncapNetworkRuleAction' { $summaries.Add('GreEncap') }
            'DvsMacRewriteNetworkRuleAction' { $summaries.Add('MacRewrite') }
            default { $summaries.Add(($typeName -replace '^Dvs', '' -replace 'NetworkRuleAction$', '')) }
        }
    }
    return [pscustomobject]@{
        Summary = ($summaries -join '; ')
        CosTag  = $cos
        DscpTag = $dscp
    }
}

function Get-TrafficRuleset {
    # The traffic filtering and marking ruleset behind a FilterPolicy, or $null. Other dvfilter
    # agents (NSX, third party) sit in the same FilterConfig list without a ruleset and are skipped.
    param(
        [Parameter(Position = 0)]
        $FilterPolicy
    )

    foreach ($config in @(Get-PropertyArray $FilterPolicy 'FilterConfig')) {
        $ruleset = Get-PropertyValue $config 'TrafficRuleset'
        if ($null -ne $ruleset) { return $ruleset }
    }
    return $null
}

function ConvertTo-QosRow {
    # Every row goes through here so Export-Csv sees the same columns in the same order whichever
    # row comes first. Missing keys become empty cells; an unknown key is a bug in this script.
    param(
        [Parameter(Mandatory)]
        [hashtable]$Values
    )

    $columns = @(
        'vCenter', 'Datacenter', 'VDSwitch', 'VDSVersion', 'NiocEnabled', 'NiocVersion',
        'PortGroup', 'PortGroupKey', 'Scope', 'PortKey', 'PortConnectee', 'IsUplink', 'PortBinding', 'Vlan',
        'NetworkResourcePool', 'NrpPriorityTag', 'LegacyQosTag',
        'TrafficFilterOverrideAllowed', 'TrafficFilteringEnabled', 'RuleCount',
        'RuleSequence', 'RuleName', 'RuleDirection', 'RuleQualifiers', 'RuleActions', 'CosTag', 'DscpTag',
        'IngressShaping', 'EgressShaping', 'ScriptVersion', 'CollectedUtc'
    )
    $unknown = @($Values.Keys | Where-Object { $columns -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw "ConvertTo-QosRow: unknown column(s) $($unknown -join ', ')."
    }
    $row = [ordered]@{}
    foreach ($column in $columns) {
        if ($Values.ContainsKey($column)) { $row[$column] = $Values[$column] } else { $row[$column] = $null }
    }
    return [pscustomobject]$row
}

function Get-PortSettingQosRow {
    <#
    .SYNOPSIS
        The CSV rows for one port group or one port: one per traffic rule, or a single row with none.

    .PARAMETER Context
        Identity columns already known: vCenter, switch, port group, scope, and so on.

    .PARAMETER SettingChain
        Port settings nearest first: the port's own setting (if any), its port group's default port
        configuration, then the switch default port configuration. Inherited policies are resolved
        along it, so a port row shows the VLAN and shaping it actually runs with.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [object[]]$SettingChain
    )

    $base = Merge-Hashtable -Table @($Context)
    $base['Vlan'] = Format-VlanSetting (Resolve-EffectivePolicy -Name 'Vlan' -SettingChain $SettingChain)
    $legacyTag = Get-PolicyValue (Resolve-EffectivePolicy -Name 'QosTag' -SettingChain $SettingChain)
    $base['LegacyQosTag'] = if (($null -ne $legacyTag) -and ([int]$legacyTag -ge 0)) { [int]$legacyTag } else { $null }
    $base['IngressShaping'] = Format-ShapingPolicy (Resolve-EffectivePolicy -Name 'InShapingPolicy' -SettingChain $SettingChain)
    $base['EgressShaping'] = Format-ShapingPolicy (Resolve-EffectivePolicy -Name 'OutShapingPolicy' -SettingChain $SettingChain)

    $ruleset = Get-TrafficRuleset (Resolve-EffectivePolicy -Name 'FilterPolicy' -SettingChain $SettingChain)
    $base['TrafficFilteringEnabled'] = Get-PropertyValue $ruleset 'Enabled'
    $rules = @(Get-PropertyArray $ruleset 'Rules' | Sort-Object -Property { Get-PropertyValue $_ 'Sequence' })
    $base['RuleCount'] = $rules.Count

    if ($rules.Count -eq 0) {
        return (ConvertTo-QosRow -Values $base)
    }

    foreach ($rule in $rules) {
        $values = Merge-Hashtable -Table @($base)
        $values['RuleSequence'] = Get-PropertyValue $rule 'Sequence'
        $values['RuleName'] = Get-PropertyValue $rule 'Description'
        $values['RuleDirection'] = [string](Get-PropertyValue $rule 'Direction')
        $qualifiers = @(Get-PropertyArray $rule 'Qualifier' | ForEach-Object { Format-RuleQualifier $_ })
        $values['RuleQualifiers'] = if ($qualifiers.Count -gt 0) { $qualifiers -join '; ' } else { 'Any' }
        $action = Format-RuleAction (Get-PropertyValue $rule 'Action')
        $values['RuleActions'] = $action.Summary
        $values['CosTag'] = $action.CosTag
        $values['DscpTag'] = $action.DscpTag
        ConvertTo-QosRow -Values $values
    }
}

function Resolve-DatacenterName {
    <#
    .SYNOPSIS
        Name of the datacenter a VDS lives in.

    .DESCRIPTION
        Taken from the PowerCLI switch object when it carries one, otherwise found by walking the
        folder chain upwards from the switch. Datacenter lookups are cached per run. Never fatal:
        an unresolved datacenter is an empty cell, not a failed export.
    #>
    param(
        [Parameter(Mandatory)]
        $VDSwitch,

        [Parameter(Mandatory)]
        $Server,

        [Parameter(Mandatory)]
        [hashtable]$Cache
    )

    $datacenter = Get-PropertyValue $VDSwitch 'Datacenter'
    if ($datacenter -is [string]) { return $datacenter }
    $name = [string](Get-PropertyValue $datacenter 'Name')
    if ($name) { return $name }

    try {
        $parent = Get-PropertyValue (Get-PropertyValue $VDSwitch 'ExtensionData') 'Parent'
        $hops = 0
        while (($null -ne $parent) -and ($hops -lt 16)) {
            $key = "$($parent.Type)-$($parent.Value)"
            if ($parent.Type -eq 'Datacenter') {
                if (-not $Cache.ContainsKey($key)) {
                    $Cache[$key] = [string](Get-View -Id $parent -Server $Server -Property Name).Name
                }
                return $Cache[$key]
            }
            $parent = Get-PropertyValue (Get-View -Id $parent -Server $Server -Property Parent) 'Parent'
            $hops++
        }
    }
    catch {
        Write-Log "Could not resolve the datacenter of $($VDSwitch.Name): $($_.Exception.Message)" -Level DEBUG
    }
    return ''
}

function Get-PortOverrideRow {
    <#
    .SYNOPSIS
        Rows for the ports on one VDS whose traffic filter or legacy QoS tag overrides their port group.

    .DESCRIPTION
        Fetches every port on the switch in one call, keeps the ones whose FilterPolicy or QosTag is
        not inherited, resolves what they connect to (VM or host, by name) in one more call, and
        renders each through the same rows as a port group, with Scope = Port. Ports that inherit
        everything are not listed: the port group row already describes them.
    #>
    param(
        [Parameter(Mandatory)]
        $VDSwitch,

        [Parameter(Mandatory)]
        $Server,

        [Parameter(Mandatory)]
        [hashtable]$SwitchContext,

        $SwitchDefaultSetting,

        [Parameter(Mandatory)]
        [hashtable]$PortgroupByKey
    )

    $switchView = Get-PropertyValue $VDSwitch 'ExtensionData'
    # A $null criteria returns every port on the switch, standalone ports included.
    $ports = @($switchView.FetchDVPorts($null) | Where-Object { $null -ne $_ })

    $overriding = New-Object System.Collections.Generic.List[object]
    foreach ($port in $ports) {
        $setting = Get-PropertyValue (Get-PropertyValue $port 'Config') 'Setting'
        if ($null -eq $setting) { continue }
        $filterOwn = ((Get-PropertyValue (Get-PropertyValue $setting 'FilterPolicy') 'Inherited') -eq $false)
        $qosOwn = ((Get-PropertyValue (Get-PropertyValue $setting 'QosTag') 'Inherited') -eq $false)
        if ($filterOwn -or $qosOwn) { $overriding.Add($port) }
    }
    Write-Log "  $($VDSwitch.Name): $($ports.Count) port(s) fetched, $($overriding.Count) with a filter or QoS tag override." -Level DEBUG
    if ($overriding.Count -eq 0) { return }

    # Resolve what the overriding ports connect to (VM, host vmkernel, ...) in one call.
    $entityNames = @{}
    $entityRefs = New-Object System.Collections.Generic.List[object]
    foreach ($port in $overriding.ToArray()) {
        $entity = Get-PropertyValue (Get-PropertyValue $port 'Connectee') 'ConnectedEntity'
        if ($null -eq $entity) { continue }
        $key = "$($entity.Type)-$($entity.Value)"
        if (-not $entityNames.ContainsKey($key)) {
            $entityNames[$key] = $null
            $entityRefs.Add($entity)
        }
    }
    if ($entityRefs.Count -gt 0) {
        try {
            foreach ($view in @(Get-View -Id $entityRefs.ToArray() -Server $Server -Property Name)) {
                $entityNames["$($view.MoRef.Type)-$($view.MoRef.Value)"] = [string]$view.Name
            }
        }
        catch {
            Write-Log "Could not resolve connectee names on $($VDSwitch.Name): $($_.Exception.Message)" -Level DEBUG
        }
    }

    foreach ($port in $overriding.ToArray()) {
        $setting = Get-PropertyValue (Get-PropertyValue $port 'Config') 'Setting'
        $portgroupKey = [string](Get-PropertyValue $port 'PortgroupKey')
        $portgroupContext = @{ PortGroup = $null; PortGroupKey = $portgroupKey }
        $portgroupSetting = $null
        if ($portgroupKey -and $PortgroupByKey.ContainsKey($portgroupKey)) {
            $portgroupContext = $PortgroupByKey[$portgroupKey]['Context']
            $portgroupSetting = $PortgroupByKey[$portgroupKey]['Setting']
        }

        $connecteeText = $null
        $connectee = Get-PropertyValue $port 'Connectee'
        if ($null -ne $connectee) {
            $parts = New-Object System.Collections.Generic.List[string]
            $connecteeType = [string](Get-PropertyValue $connectee 'Type')
            if ($connecteeType) { $parts.Add($connecteeType) }
            $entity = Get-PropertyValue $connectee 'ConnectedEntity'
            if ($null -ne $entity) {
                $key = "$($entity.Type)-$($entity.Value)"
                if ($entityNames[$key]) { $parts.Add([string]$entityNames[$key]) } else { $parts.Add($key) }
            }
            $nicKey = [string](Get-PropertyValue $connectee 'NicKey')
            if ($nicKey) { $parts.Add("nic=$nicKey") }
            $connecteeText = $parts -join ' '
        }

        $portContext = @{
            Scope         = 'Port'
            PortKey       = [string](Get-PropertyValue $port 'Key')
            PortConnectee = $connecteeText
        }
        $context = Merge-Hashtable -Table @($SwitchContext, $portgroupContext, $portContext)
        Get-PortSettingQosRow -Context $context -SettingChain @($setting, $portgroupSetting, $SwitchDefaultSetting)
    }
}

# ---- Main -------------------------------------------------------------------

$collectedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
$openedSessions = New-Object System.Collections.Generic.List[object]
$preExisting = @{}
$rows = New-Object System.Collections.Generic.List[object]
$progressActivity = 'Reading distributed port groups'

try {
    Write-Log "Export-VDPortgroupQos $ScriptVersion starting on $([Environment]::MachineName)."

    try {
        Import-RequiredModules
    }
    catch {
        throw "VMware PowerCLI is required and could not be loaded: $($_.Exception.Message) Install it with: Install-Module -Name VMware.PowerCLI -Scope CurrentUser"
    }

    # ---- Connect ----------------------------------------------------------
    # Sessions that were open before this run are not ours to close.
    $existing = Get-Variable -Name DefaultVIServers -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    foreach ($session in @($existing)) {
        if ($null -eq $session) { continue }
        $sessionName = [string]$session.Name
        $preExisting[$sessionName] = $true
    }

    if (-not $NoLinked) {
        try {
            $mode = [string](Get-PropertyValue (Get-PowerCLIConfiguration -Scope Session) 'DefaultVIServerMode')
            if ($mode -ne 'Multiple') {
                Write-Log "PowerCLI DefaultVIServerMode is '$mode'. Setting it to Multiple for this session so the linked vCenters can be connected together." -Level WARN
                Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Scope Session -Confirm:$false | Out-Null
            }
        }
        catch {
            Write-Log "Could not check or set PowerCLI DefaultVIServerMode: $($_.Exception.Message)" -Level WARN
        }
    }

    $connectParams = @{ Server = $Server; ErrorAction = 'Stop' }
    if ($null -ne $Credential) { $connectParams['Credential'] = $Credential }
    if (-not $NoLinked) { $connectParams['AllLinked'] = $true }

    Write-Log ('Connecting to {0}{1}.' -f $Server, $(if ($NoLinked) { '' } else { ' and the other vCenters in its SSO domain' }))
    foreach ($session in @(Connect-VIServer @connectParams)) {
        if ($null -ne $session) { $openedSessions.Add($session) }
    }
    $targets = @($openedSessions.ToArray() | Sort-Object -Property Name -Unique)
    if ($targets.Count -eq 0) { throw "No vCenter session was established to '$Server'." }
    Write-Log ('Connected to {0} vCenter(s): {1}.' -f $targets.Count, (@($targets | ForEach-Object { $_.Name }) -join ', '))

    # ---- Read ---------------------------------------------------------------
    $datacenterCache = @{}
    $switchCount = 0
    $portgroupCount = 0

    foreach ($vc in $targets) {
        Write-Log ('vCenter {0} (version {1} build {2}).' -f $vc.Name, (Get-PropertyValue $vc 'Version'), (Get-PropertyValue $vc 'Build'))
        $switches = @(Get-VDSwitch -Server $vc -ErrorAction Stop | Sort-Object -Property Name)
        if ($switches.Count -eq 0) {
            Write-Log "  No distributed switches on $($vc.Name)." -Level WARN
            continue
        }

        $switchIndex = 0
        foreach ($vds in $switches) {
            $switchIndex++
            $switchCount++
            Write-Progress -Activity $progressActivity -Status "$($vc.Name) / $($vds.Name)" -PercentComplete ([int](100 * $switchIndex / $switches.Count))

            $switchView = Get-PropertyValue $vds 'ExtensionData'
            $switchConfig = Get-PropertyValue $switchView 'Config'
            $switchDefaultSetting = Get-PropertyValue $switchConfig 'DefaultPortConfig'
            $datacenterName = Resolve-DatacenterName -VDSwitch $vds -Server $vc -Cache $datacenterCache

            # NIOC version 2 pools hang off the switch object; version 3 pools live in its config.
            $poolsV2 = @{}
            foreach ($pool in @(Get-PropertyArray $switchView 'NetworkResourcePool')) {
                $poolKey = [string](Get-PropertyValue $pool 'Key')
                $poolsV2[$poolKey] = $pool
            }
            $poolsV3 = @{}
            foreach ($pool in @(Get-PropertyArray $switchConfig 'VmVnicNetworkResourcePool')) {
                $poolKey = [string](Get-PropertyValue $pool 'Key')
                $poolsV3[$poolKey] = $pool
            }

            $niocEnabled = Get-PropertyValue $switchConfig 'NetworkResourceManagementEnabled'
            $niocVersion = [string](Get-PropertyValue $switchConfig 'NetworkResourceControlVersion')
            $switchContext = @{
                vCenter       = [string]$vc.Name
                Datacenter    = $datacenterName
                VDSwitch      = [string]$vds.Name
                VDSVersion    = [string](Get-PropertyValue $vds 'Version')
                NiocEnabled   = $niocEnabled
                NiocVersion   = $niocVersion
                ScriptVersion = $ScriptVersion
                CollectedUtc  = $collectedUtc
            }

            $portgroups = @(Get-VDPortgroup -VDSwitch $vds -ErrorAction Stop | Sort-Object -Property Name)
            $niocText = if ($niocEnabled) { "enabled ($niocVersion)" } else { 'disabled' }
            Write-Log ('  {0}: {1} port group(s), NIOC {2}, {3} NIOC v2 pool(s), {4} NIOC v3 pool(s).' -f $vds.Name, $portgroups.Count, $niocText, $poolsV2.Count, $poolsV3.Count)

            $portgroupByKey = @{}
            foreach ($pg in $portgroups) {
                $portgroupCount++
                $pgView = Get-PropertyValue $pg 'ExtensionData'
                $pgConfig = Get-PropertyValue $pgView 'Config'
                $pgSetting = Get-PropertyValue $pgConfig 'DefaultPortConfig'
                $pgKey = [string](Get-PropertyValue $pgView 'Key')

                $binding = Get-PropertyValue $pg 'PortBinding'
                if ($null -eq $binding) { $binding = Get-PropertyValue $pgConfig 'Type' }
                $isUplink = Get-PropertyValue $pgConfig 'Uplink'
                if ($null -eq $isUplink) { $isUplink = Get-PropertyValue $pg 'IsUplink' }

                # Resource pool: NIOC v3 assigns by VmVnicNetworkResourcePoolKey on the port group,
                # NIOC v2 by NetworkResourcePoolKey in the port setting ("-1" = none). Only v2 pools
                # carry an 802.1p priority tag.
                $poolName = $null
                $poolTag = $null
                $v3Key = [string](Get-PropertyValue $pgConfig 'VmVnicNetworkResourcePoolKey')
                if ($v3Key) {
                    $poolName = if ($poolsV3.ContainsKey($v3Key)) { [string](Get-PropertyValue $poolsV3[$v3Key] 'Name') } else { $v3Key }
                }
                $v2Key = [string](Get-PolicyValue (Get-PropertyValue $pgSetting 'NetworkResourcePoolKey'))
                if ($v2Key -and ($v2Key -ne '-1')) {
                    if ($poolsV2.ContainsKey($v2Key)) {
                        $poolName = [string](Get-PropertyValue $poolsV2[$v2Key] 'Name')
                        $poolTag = Get-PropertyValue (Get-PropertyValue $poolsV2[$v2Key] 'AllocationInfo') 'PriorityTag'
                        if (($null -ne $poolTag) -and ([int]$poolTag -lt 0)) { $poolTag = $null }
                    }
                    else {
                        $poolName = $v2Key
                    }
                }

                $pgContext = @{
                    PortGroup                    = [string]$pg.Name
                    PortGroupKey                 = $pgKey
                    IsUplink                     = $isUplink
                    PortBinding                  = [string]$binding
                    TrafficFilterOverrideAllowed = Get-PropertyValue (Get-PropertyValue $pgConfig 'Policy') 'TrafficFilterOverrideAllowed'
                    NetworkResourcePool          = $poolName
                    NrpPriorityTag               = $poolTag
                }
                $portgroupByKey[$pgKey] = @{ Context = $pgContext; Setting = $pgSetting }

                $scopeContext = @{ Scope = 'PortGroup' }
                $context = Merge-Hashtable -Table @($switchContext, $pgContext, $scopeContext)
                foreach ($row in @(Get-PortSettingQosRow -Context $context -SettingChain @($pgSetting, $switchDefaultSetting))) {
                    $rows.Add($row)
                }
            }

            if ($IncludePortOverrides) {
                try {
                    $overrideRows = @(Get-PortOverrideRow -VDSwitch $vds -Server $vc -SwitchContext $switchContext -SwitchDefaultSetting $switchDefaultSetting -PortgroupByKey $portgroupByKey)
                    foreach ($row in $overrideRows) { $rows.Add($row) }
                    Write-Log "  $($vds.Name): $($overrideRows.Count) port-level override row(s)."
                }
                catch {
                    Write-Log "  $($vds.Name): could not read port-level overrides: $($_.Exception.Message)" -Level WARN
                }
            }
        }
        Write-Progress -Activity $progressActivity -Completed
    }

    # ---- Write ------------------------------------------------------------
    # Scope descending puts a port group's own row before the rows of ports that override it.
    $sortOrder = @('vCenter', 'Datacenter', 'VDSwitch', 'PortGroup', @{ Expression = 'Scope'; Descending = $true }, 'PortKey', 'RuleSequence')
    $sorted = @($rows.ToArray() | Sort-Object -Property $sortOrder)
    $ruleRows = @($sorted | Where-Object { $null -ne $_.RuleSequence })
    $taggedRows = @($sorted | Where-Object { ($null -ne $_.CosTag) -or ($null -ne $_.DscpTag) })
    Write-Log ('Read {0} vCenter(s), {1} switch(es), {2} port group(s): {3} row(s), {4} traffic rule(s), {5} of them tagging CoS or DSCP.' -f $targets.Count, $switchCount, $portgroupCount, $sorted.Count, $ruleRows.Count, $taggedRows.Count)

    if ($sorted.Count -eq 0) {
        Write-Log 'Nothing to write: no distributed port groups were found.' -Level WARN
    }
    else {
        if (-not $OutputPath) {
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
            $OutputPath = Join-Path (Join-Path (Get-Location).Path 'output') "VDPortgroupQos-$stamp.csv"
        }
        $outputDirectory = Split-Path -Path $OutputPath -Parent
        if ($outputDirectory -and (-not (Test-Path -LiteralPath $outputDirectory))) {
            New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
        }
        $sorted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Log "Wrote $($sorted.Count) row(s) to $OutputPath."
    }

    if ($PassThru) { $sorted }
    Write-Log 'Completed successfully.'
}
catch {
    Write-Log "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    Write-Progress -Activity $progressActivity -Completed
    $disconnected = @{}
    foreach ($session in $openedSessions.ToArray()) {
        $name = [string]$session.Name
        if ($preExisting.ContainsKey($name) -or $disconnected.ContainsKey($name)) { continue }
        $disconnected[$name] = $true
        try {
            Disconnect-VIServer -Server $session -Confirm:$false -ErrorAction Stop
            Write-Log "Disconnected from $name." -Level DEBUG
        }
        catch {
            Write-Log "Could not disconnect from ${name}: $($_.Exception.Message)" -Level WARN
        }
    }
}
