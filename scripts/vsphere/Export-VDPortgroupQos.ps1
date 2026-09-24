<#
.SYNOPSIS
    Audits, and optionally changes, the QoS / CoS marking on every distributed port group in a vCenter SSO domain.

.DESCRIPTION
    Inventory of traffic marking on vSphere Distributed Switches (VDS), with optional bulk changes to
    the marking rules, always written to a CSV that records the value read or the fault hit for
    every port group.

    Connects to one vCenter, follows Enhanced Linked Mode to every other vCenter in the same SSO
    domain (unless -NoLinked), and walks every VDS on each of them. Every distributed port group,
    uplink port groups included, is written to the CSV with:

      - Traffic filtering and marking rules. One row per rule, carrying the CoS (802.1p, 0-7)
        and DSCP (0-63) values its Tag action applies, plus the rule's direction, qualifiers
        and other actions (Allow, Drop, ...). This is where QoS / CoS is configured.
      - The port group's legacy 802.1p QoS tag (VMwareDVSPortSetting.qosTag), deprecated as of
        vSphere API 5.0 but still present on older switch versions.
      - Network I/O Control: whether it is enabled on the switch, which version, the network
        resource pool the port group is assigned to and, on NIOC version 2, that pool's
        802.1p priority tag.
      - Ingress and egress traffic shaping, and the effective VLAN, for context.
      - Whether individual ports may override the port group's traffic filter and, with
        -IncludePortOverrides, the ports that actually do.
      - Action, Outcome and Detail: what was attempted on the row and how it ended. Outcome is
        one of Read, ReadFailed, Planned, Changed, Skipped or Failed; Detail carries the value
        change (for example "CoS 4 -> 5") or the error message.

    A port group with no traffic rules still produces one row, and a port group that could not
    be read produces a ReadFailed row with the error, so the CSV lists every port group in the
    domain whatever happened to it.

    CHANGE ACTIONS. -Action selects what to do to the marking (Tag) rules of the port groups
    matched by -SwitchName and -PortGroupName, on rules whose description matches -RuleName:

      Audit       Read only (default).
      SetTag      Set the CoS (-CosTag) and/or DSCP (-DscpTag) value of the rule's Tag action.
      ClearTag    Remove the CoS (-ClearCos) and/or DSCP (-ClearDscp) value from the Tag action.
                  A rule whose Tag action would be left with no value at all is skipped and
                  reported; remove the rule instead.
      RemoveRule  Delete the rule. -RuleName is required for this action.

    Only rules with a Tag action are ever changed: Allow and Drop rules are left alone, as are
    port-level overrides (those are reported, never edited) and the switch default port
    configuration. Each port group is reconfigured once, through ReconfigureDVPortgroup with
    the port group's current config version, so a port group changed by someone else between
    the read and the write fails safely instead of being overwritten. After a successful
    change the port group is read back from vCenter and the CSV row shows what vCenter now
    reports; a failed change is reported against the values read before it.

    -WhatIf performs no change on any vCenter but still writes the CSV, with Outcome = Planned
    on every rule that would have been changed: that CSV is the dry-run report. Without
    -WhatIf every port group change asks for confirmation (ConfirmImpact is High); pass
    -Confirm:$false for an unattended run.

    Self-contained: no repo module and no config file. VMware PowerCLI must already be installed
    on the host. The VMware.VimAutomation.Core and VMware.VimAutomation.Vds modules are loaded
    only if they are not already in the session, so a pinned bundle is left alone, and nothing
    is ever installed.

    If the session's PowerCLI DefaultVIServerMode is not Multiple it is set to Multiple for this
    session only, because linked-mode connections need it. Only the vCenter sessions this script
    opened are closed at the end.

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
    current directory. Missing directories are created. Written on -WhatIf as well.

.PARAMETER IncludePortOverrides
    Also fetch every port on every VDS and add a row (Scope = Port) for each port whose traffic
    filter or legacy QoS tag overrides its port group. This is one extra call per switch that
    returns every port, so it is slower on large switches. Off by default. Port rows are read
    only; change actions never touch them.

.PARAMETER PassThru
    Also emit the rows to the pipeline after the CSV is written.

.PARAMETER Action
    Audit (default), SetTag, ClearTag or RemoveRule. See DESCRIPTION.

.PARAMETER SwitchName
    Wildcard pattern(s) for the distributed switches whose port groups a change action may
    touch. Defaults to every switch. Audit rows are still produced for the rest.

.PARAMETER PortGroupName
    Wildcard pattern(s) for the port groups a change action may touch. Defaults to every port
    group on the matched switches.

.PARAMETER RuleName
    Wildcard pattern(s) matched against the rule description (the name shown in the vSphere
    Client). Defaults to every rule for SetTag and ClearTag. Required for RemoveRule; pass '*'
    deliberately to remove every marking rule on the matched port groups.

.PARAMETER CosTag
    SetTag: the CoS (802.1p) value to set, 0 to 7. Per the vSphere API a value of 0 makes the
    rule clear the CoS tag on matching packets.

.PARAMETER DscpTag
    SetTag: the DSCP value to set, 0 to 63. A value of 0 makes the rule clear the DSCP tag on
    matching packets.

.PARAMETER ClearCos
    ClearTag: remove the CoS value from the Tag action, so the rule no longer marks CoS.

.PARAMETER ClearDscp
    ClearTag: remove the DSCP value from the Tag action, so the rule no longer marks DSCP.

.EXAMPLE
    .\Export-VDPortgroupQos.ps1 -Server vcenter01.example.com

    Read-only audit of vcenter01 and every vCenter linked to it, written to
    .\output\VDPortgroupQos-<timestamp>.csv.

.EXAMPLE
    .\Export-VDPortgroupQos.ps1 -Server vcenter01.example.com -Action SetTag -PortGroupName 'PG-vMotion*' -RuleName 'Mark vMotion' -CosTag 4 -DscpTag 34 -WhatIf

    Dry run: reports every port group, and marks the rows of the rules that would change as
    Planned with the before and after values. Nothing is changed on vCenter.

.EXAMPLE
    .\Export-VDPortgroupQos.ps1 -Server vcenter01.example.com -Action ClearTag -PortGroupName 'PG-App*' -ClearCos -Confirm:$false

    Removes the CoS value from every marking rule on the PG-App* port groups without prompting.
    Rules that also mark DSCP keep marking DSCP.

.EXAMPLE
    .\Export-VDPortgroupQos.ps1 -Server vcenter01.example.com -Action RemoveRule -SwitchName dvs-legacy -RuleName 'Mark *' -OutputPath C:\Temp\remove-marking.csv

    Deletes the marking rules named "Mark ..." from every port group on dvs-legacy, asking for
    confirmation per port group, and records the outcome of each in the CSV.

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
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [pscredential]$Credential,

    [switch]$NoLinked,

    [string]$OutputPath,

    [switch]$IncludePortOverrides,

    [switch]$PassThru,

    [ValidateSet('Audit', 'SetTag', 'ClearTag', 'RemoveRule')]
    [string]$Action = 'Audit',

    [string[]]$SwitchName = @('*'),

    [string[]]$PortGroupName = @('*'),

    [string[]]$RuleName,

    [Nullable[int]]$CosTag,

    [Nullable[int]]$DscpTag,

    [switch]$ClearCos,

    [switch]$ClearDscp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.1.0'

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
        'IngressShaping', 'EgressShaping', 'Action', 'Outcome', 'Detail', 'ScriptVersion', 'CollectedUtc'
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

    .PARAMETER RuleOutcome
        Outcome and Detail per rule identity (see Get-RuleIdentity), for rules a change action
        touched. Rules not in the table, and the no-rule row, get Outcome = Read.

    .PARAMETER OnlyRuleId
        When given, only the rules with these identities produce rows, and a port group with no
        matching rule produces nothing. Used to report rules that a change removed.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [object[]]$SettingChain,

        [hashtable]$RuleOutcome = @{},

        [string[]]$OnlyRuleId
    )

    $base = Merge-Hashtable -Table @($Context)
    if (-not $base.ContainsKey('Outcome')) { $base['Outcome'] = 'Read' }
    $base['Vlan'] = Format-VlanSetting (Resolve-EffectivePolicy -Name 'Vlan' -SettingChain $SettingChain)
    $legacyTag = Get-PolicyValue (Resolve-EffectivePolicy -Name 'QosTag' -SettingChain $SettingChain)
    $base['LegacyQosTag'] = if (($null -ne $legacyTag) -and ([int]$legacyTag -ge 0)) { [int]$legacyTag } else { $null }
    $base['IngressShaping'] = Format-ShapingPolicy (Resolve-EffectivePolicy -Name 'InShapingPolicy' -SettingChain $SettingChain)
    $base['EgressShaping'] = Format-ShapingPolicy (Resolve-EffectivePolicy -Name 'OutShapingPolicy' -SettingChain $SettingChain)

    $ruleset = Get-TrafficRuleset (Resolve-EffectivePolicy -Name 'FilterPolicy' -SettingChain $SettingChain)
    $base['TrafficFilteringEnabled'] = Get-PropertyValue $ruleset 'Enabled'
    $rules = @(Get-PropertyArray $ruleset 'Rules' | Sort-Object -Property { Get-PropertyValue $_ 'Sequence' })
    $base['RuleCount'] = $rules.Count
    if ($null -ne $OnlyRuleId) {
        $rules = @($rules | Where-Object { $OnlyRuleId -contains (Get-RuleIdentity $_) })
        if ($rules.Count -eq 0) { return }
    }

    if ($rules.Count -eq 0) {
        return (ConvertTo-QosRow -Values $base)
    }

    foreach ($rule in $rules) {
        $values = Merge-Hashtable -Table @($base)
        $ruleId = Get-RuleIdentity $rule
        if ($RuleOutcome.ContainsKey($ruleId)) {
            $values['Outcome'] = $RuleOutcome[$ruleId]['Outcome']
            $values['Detail'] = $RuleOutcome[$ruleId]['Detail']
        }
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

function Get-RuleIdentity {
    # Stable identity of a traffic rule across reads: its API key, or sequence plus description
    # when the key is missing. Used to line up plan, outcome and re-read.
    param(
        [Parameter(Position = 0)]
        $Rule
    )

    $key = [string](Get-PropertyValue $Rule 'Key')
    if ($key) { return $key }
    return ('seq:{0}:{1}' -f (Get-PropertyValue $Rule 'Sequence'), (Get-PropertyValue $Rule 'Description'))
}

function Test-NameMatch {
    # True when the name matches any of the wildcard patterns.
    param(
        [string]$Name,

        [string[]]$Pattern
    )

    foreach ($p in $Pattern) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Format-TagValue {
    # "CoS=5 DSCP=46", "CoS=5", or "none" for a Tag action's current values.
    param(
        $Cos,

        $Dscp
    )

    $parts = @()
    if ($null -ne $Cos) { $parts += "CoS=$Cos" }
    if ($null -ne $Dscp) { $parts += "DSCP=$Dscp" }
    if ($parts.Count -eq 0) { return 'none' }
    return ($parts -join ' ')
}

function Get-PortgroupTagPlan {
    <#
    .SYNOPSIS
        Works out what a change action would do to the marking rules of one port group, without
        touching anything.

    .DESCRIPTION
        Every rule in the ruleset gets a record: Outcome Read (not targeted), Skipped (targeted but
        nothing to do, with the reason) or Planned (with the new values, or Remove). Only rules
        whose action is DvsUpdateTagNetworkRuleAction can be Planned. The Summary is the text shown
        at the confirmation prompt and by -WhatIf.

    .PARAMETER Ruleset
        The port group's own DvsTrafficRuleset, or $null when it has none of its own.
    #>
    param(
        $Ruleset,

        [Parameter(Mandatory)]
        [ValidateSet('SetTag', 'ClearTag', 'RemoveRule')]
        [string]$Action,

        [string[]]$RuleName = @('*'),

        [Nullable[int]]$CosTag,

        [Nullable[int]]$DscpTag,

        [bool]$ClearCos,

        [bool]$ClearDscp
    )

    $changes = New-Object System.Collections.Generic.List[object]
    $summary = New-Object System.Collections.Generic.List[string]
    foreach ($rule in @(Get-PropertyArray $Ruleset 'Rules')) {
        $name = [string](Get-PropertyValue $rule 'Description')
        $record = [pscustomobject]@{
            Id      = Get-RuleIdentity $rule
            Rule    = $rule
            Name    = $name
            Outcome = 'Read'
            Detail  = $null
            Remove  = $false
            SetCos  = $false
            SetDscp = $false
            NewCos  = $null
            NewDscp = $null
        }
        $changes.Add($record)
        if (-not (Test-NameMatch -Name $name -Pattern $RuleName)) { continue }

        $ruleAction = Get-PropertyValue $rule 'Action'
        if ((Get-TypeName $ruleAction) -ne 'DvsUpdateTagNetworkRuleAction') {
            $record.Outcome = 'Skipped'
            $record.Detail = "rule action is $((Format-RuleAction $ruleAction).Summary), not Tag; only marking rules are changed"
            continue
        }
        $cos = Get-PropertyValue $ruleAction 'QosTag'
        if (($null -ne $cos) -and ([int]$cos -lt 0)) { $cos = $null }
        $dscp = Get-PropertyValue $ruleAction 'DscpTag'
        if (($null -ne $dscp) -and ([int]$dscp -lt 0)) { $dscp = $null }
        $before = Format-TagValue -Cos $cos -Dscp $dscp

        switch ($Action) {
            'RemoveRule' {
                $record.Outcome = 'Planned'
                $record.Remove = $true
                $record.Detail = "remove rule '$name' ($before)"
                $summary.Add("remove '$name' ($before)")
            }
            'SetTag' {
                $newCos = if ($null -ne $CosTag) { [int]$CosTag } else { $cos }
                $newDscp = if ($null -ne $DscpTag) { [int]$DscpTag } else { $dscp }
                $after = Format-TagValue -Cos $newCos -Dscp $newDscp
                if ($after -eq $before) {
                    $record.Outcome = 'Skipped'
                    $record.Detail = "already $before"
                }
                else {
                    $record.Outcome = 'Planned'
                    $record.SetCos = ($null -ne $CosTag)
                    $record.SetDscp = ($null -ne $DscpTag)
                    $record.NewCos = $newCos
                    $record.NewDscp = $newDscp
                    $record.Detail = "$before -> $after"
                    $summary.Add("'$name' $before -> $after")
                }
            }
            'ClearTag' {
                $newCos = if ($ClearCos) { $null } else { $cos }
                $newDscp = if ($ClearDscp) { $null } else { $dscp }
                $after = Format-TagValue -Cos $newCos -Dscp $newDscp
                if ($after -eq $before) {
                    $record.Outcome = 'Skipped'
                    $record.Detail = "nothing to clear, already $before"
                }
                elseif (($null -eq $newCos) -and ($null -eq $newDscp)) {
                    $record.Outcome = 'Skipped'
                    $record.Detail = "clearing would leave the Tag action with no value ($before); use -Action RemoveRule"
                }
                else {
                    $record.Outcome = 'Planned'
                    $record.SetCos = [bool]$ClearCos
                    $record.SetDscp = [bool]$ClearDscp
                    $record.NewCos = $newCos
                    $record.NewDscp = $newDscp
                    $record.Detail = "$before -> $after"
                    $summary.Add("'$name' $before -> $after")
                }
            }
        }
    }

    $planned = @($changes.ToArray() | Where-Object { $_.Outcome -eq 'Planned' })
    return [pscustomobject]@{
        Changes      = $changes.ToArray()
        PlannedCount = $planned.Count
        RemovedIds   = @($planned | Where-Object { $_.Remove } | ForEach-Object { $_.Id })
        Summary      = ('{0}: {1}' -f $Action, ($summary -join '; '))
    }
}

function Invoke-PortgroupTagPlan {
    <#
    .SYNOPSIS
        Applies a plan from Get-PortgroupTagPlan to one port group. THE ONLY WRITE IN THIS SCRIPT.

    .DESCRIPTION
        Must be called inside $PSCmdlet.ShouldProcess. Re-reads the port group first, so the edit is
        made on a fresh copy of its configuration (the audit copy is left untouched for reporting)
        with the current config version, then finds each planned rule by identity, sets or clears
        its tag values or drops it, marks the filter policy as the port group's own, and sends the
        filter policy back through ReconfigureDVPortgroup. Nothing else in the port group is sent.
        Throws with vCenter's own message when the reconfigure is rejected.
    #>
    param(
        [Parameter(Mandatory)]
        $PortgroupView,

        [Parameter(Mandatory)]
        $Server,

        [Parameter(Mandatory)]
        $Plan
    )

    $fresh = Get-View -Id $PortgroupView.MoRef -Server $Server -Property Config
    $config = Get-PropertyValue $fresh 'Config'
    $policy = Get-PropertyValue (Get-PropertyValue $config 'DefaultPortConfig') 'FilterPolicy'
    $ruleset = Get-TrafficRuleset $policy
    if ($null -eq $ruleset) { throw 'the port group no longer has a traffic ruleset of its own; it was changed since it was read' }

    $byId = @{}
    foreach ($rule in @(Get-PropertyArray $ruleset 'Rules')) { $byId[(Get-RuleIdentity $rule)] = $rule }

    $removedIds = @()
    foreach ($change in @($Plan.Changes | Where-Object { $_.Outcome -eq 'Planned' })) {
        if (-not $byId.ContainsKey($change.Id)) {
            throw "rule '$($change.Name)' no longer exists on the port group; it was changed since it was read"
        }
        if ($change.Remove) {
            $removedIds += $change.Id
            continue
        }
        $ruleAction = Get-PropertyValue $byId[$change.Id] 'Action'
        if ($change.SetCos) { $ruleAction.QosTag = $change.NewCos }
        if ($change.SetDscp) { $ruleAction.DscpTag = $change.NewDscp }
    }
    if ($removedIds.Count -gt 0) {
        $ruleset.Rules = @(Get-PropertyArray $ruleset 'Rules' | Where-Object { $removedIds -notcontains (Get-RuleIdentity $_) })
    }

    # Sent back as the port group's own policy: per the API, only entries with inherited = false
    # are applied, and the array replaces the port group's filter settings.
    $policy.Inherited = $false
    foreach ($filterConfig in @(Get-PropertyArray $policy 'FilterConfig')) { $filterConfig.Inherited = $false }

    $portSetting = New-Object -TypeName 'VMware.Vim.VMwareDVSPortSetting'
    $portSetting.FilterPolicy = $policy
    $spec = New-Object -TypeName 'VMware.Vim.DVPortgroupConfigSpec'
    $spec.ConfigVersion = [string](Get-PropertyValue $config 'ConfigVersion')
    $spec.DefaultPortConfig = $portSetting
    $fresh.ReconfigureDVPortgroup($spec)
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

    # ---- Validate the change request before touching anything ---------------
    $changeParameterGiven = ($null -ne $CosTag) -or ($null -ne $DscpTag) -or $ClearCos -or $ClearDscp -or ($null -ne $RuleName)
    switch ($Action) {
        'Audit' {
            if ($changeParameterGiven) { throw '-CosTag, -DscpTag, -ClearCos, -ClearDscp and -RuleName only apply with -Action SetTag, ClearTag or RemoveRule.' }
        }
        'SetTag' {
            if (($null -eq $CosTag) -and ($null -eq $DscpTag)) { throw '-Action SetTag needs -CosTag and/or -DscpTag.' }
            if (($null -ne $CosTag) -and (($CosTag -lt 0) -or ($CosTag -gt 7))) { throw "-CosTag must be 0 to 7 (802.1p), not $CosTag." }
            if (($null -ne $DscpTag) -and (($DscpTag -lt 0) -or ($DscpTag -gt 63))) { throw "-DscpTag must be 0 to 63, not $DscpTag." }
            if ($ClearCos -or $ClearDscp) { throw '-ClearCos and -ClearDscp apply to -Action ClearTag, not SetTag.' }
        }
        'ClearTag' {
            if (-not ($ClearCos -or $ClearDscp)) { throw '-Action ClearTag needs -ClearCos and/or -ClearDscp.' }
            if (($null -ne $CosTag) -or ($null -ne $DscpTag)) { throw '-CosTag and -DscpTag apply to -Action SetTag, not ClearTag.' }
        }
        'RemoveRule' {
            if ($null -eq $RuleName) { throw "-Action RemoveRule needs -RuleName; pass -RuleName '*' to remove every marking rule on the matched port groups." }
            if (($null -ne $CosTag) -or ($null -ne $DscpTag) -or $ClearCos -or $ClearDscp) { throw '-CosTag, -DscpTag, -ClearCos and -ClearDscp do not apply to -Action RemoveRule.' }
        }
    }
    if ($null -eq $RuleName) { $RuleName = @('*') }
    if ($Action -ne 'Audit') {
        $valueText = switch ($Action) {
            'SetTag' { (Format-TagValue -Cos $CosTag -Dscp $DscpTag) }
            'ClearTag' { ('clear ' + (@(@('CoS')[0..0] | Where-Object { $ClearCos }) + @(@('DSCP')[0..0] | Where-Object { $ClearDscp }) -join ' and ')) }
            default { 'delete' }
        }
        Write-Log ("Action {0} ({1}) on switches '{2}', port groups '{3}', rules '{4}'." -f $Action, $valueText, ($SwitchName -join "', '"), ($PortGroupName -join "', '"), ($RuleName -join "', '"))
        if ($WhatIfPreference) { Write-Log '-WhatIf: nothing will be changed on any vCenter; the CSV is the plan.' -Level WARN }
    }

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
                Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Scope Session -Confirm:$false -WhatIf:$false | Out-Null
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
    $readFailedCount = 0
    $plannedRuleCount = 0
    $changedPortgroupCount = 0
    $failedPortgroupCount = 0

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
                Action        = $Action
                ScriptVersion = $ScriptVersion
                CollectedUtc  = $collectedUtc
            }

            $portgroups = @(Get-VDPortgroup -VDSwitch $vds -ErrorAction Stop | Sort-Object -Property Name)
            $niocText = if ($niocEnabled) { "enabled ($niocVersion)" } else { 'disabled' }
            Write-Log ('  {0}: {1} port group(s), NIOC {2}, {3} NIOC v2 pool(s), {4} NIOC v3 pool(s).' -f $vds.Name, $portgroups.Count, $niocText, $poolsV2.Count, $poolsV3.Count)

            $portgroupByKey = @{}
            foreach ($pg in $portgroups) {
                $portgroupCount++
                $pgName = [string]$pg.Name
                try {
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
                        PortGroup                    = $pgName
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
                    $chain = @($pgSetting, $switchDefaultSetting)

                    $targeted = ($Action -ne 'Audit') -and (Test-NameMatch -Name $vds.Name -Pattern $SwitchName) -and (Test-NameMatch -Name $pgName -Pattern $PortGroupName)
                    if (-not $targeted) {
                        foreach ($row in @(Get-PortSettingQosRow -Context $context -SettingChain $chain)) { $rows.Add($row) }
                        continue
                    }

                    # ---- Change ----------------------------------------------------------
                    # Only the port group's OWN filter policy is edited. An inherited policy has no
                    # rules of its own to change, so the port group is reported and left alone.
                    $ownPolicy = Get-PropertyValue $pgSetting 'FilterPolicy'
                    $ownRuleset = $null
                    if (($null -ne $ownPolicy) -and ((Get-PropertyValue $ownPolicy 'Inherited') -ne $true)) {
                        $ownRuleset = Get-TrafficRuleset $ownPolicy
                    }
                    $plan = Get-PortgroupTagPlan -Ruleset $ownRuleset -Action $Action -RuleName $RuleName -CosTag $CosTag -DscpTag $DscpTag -ClearCos $ClearCos -ClearDscp $ClearDscp
                    $outcomes = @{}
                    foreach ($change in $plan.Changes) {
                        $outcomes[$change.Id] = @{ Outcome = $change.Outcome; Detail = $change.Detail }
                    }
                    $plannedChanges = @($plan.Changes | Where-Object { $_.Outcome -eq 'Planned' })

                    if ($plannedChanges.Count -eq 0) {
                        if ($plan.Changes.Count -eq 0) {
                            $context['Outcome'] = 'Skipped'
                            $context['Detail'] = 'no marking rules of its own on this port group'
                        }
                        foreach ($row in @(Get-PortSettingQosRow -Context $context -SettingChain $chain -RuleOutcome $outcomes)) { $rows.Add($row) }
                        continue
                    }

                    $plannedRuleCount += $plannedChanges.Count
                    $target = '{0} / {1} / {2}' -f $vc.Name, $vds.Name, $pgName
                    if ($PSCmdlet.ShouldProcess($target, $plan.Summary)) {
                        try {
                            Invoke-PortgroupTagPlan -PortgroupView $pgView -Server $vc -Plan $plan
                            foreach ($change in $plannedChanges) { $outcomes[$change.Id]['Outcome'] = 'Changed' }

                            # Report what vCenter holds now, not what was sent.
                            $afterView = Get-View -Id $pgView.MoRef -Server $vc -Property Config
                            $afterSetting = Get-PropertyValue (Get-PropertyValue $afterView 'Config') 'DefaultPortConfig'
                            foreach ($row in @(Get-PortSettingQosRow -Context $context -SettingChain @($afterSetting, $switchDefaultSetting) -RuleOutcome $outcomes)) { $rows.Add($row) }
                            if ($plan.RemovedIds.Count -gt 0) {
                                foreach ($row in @(Get-PortSettingQosRow -Context $context -SettingChain $chain -RuleOutcome $outcomes -OnlyRuleId $plan.RemovedIds)) {
                                    # The rule is gone: the row records the removal, not the old values.
                                    $row.RuleQualifiers = $null
                                    $row.RuleActions = $null
                                    $row.CosTag = $null
                                    $row.DscpTag = $null
                                    $rows.Add($row)
                                }
                            }
                            $changedPortgroupCount++
                            Write-Log "  ${target}: changed. $($plan.Summary)"
                        }
                        catch {
                            $message = $_.Exception.Message
                            foreach ($change in $plannedChanges) {
                                $outcomes[$change.Id] = @{ Outcome = 'Failed'; Detail = "$($change.Detail): $message" }
                            }
                            foreach ($row in @(Get-PortSettingQosRow -Context $context -SettingChain $chain -RuleOutcome $outcomes)) { $rows.Add($row) }
                            $failedPortgroupCount++
                            Write-Log "  ${target}: change failed, port group left as read. $message" -Level ERROR
                        }
                    }
                    else {
                        # -WhatIf keeps Outcome = Planned; a "no" at the confirmation prompt is a skip.
                        if (-not $WhatIfPreference) {
                            foreach ($change in $plannedChanges) {
                                $outcomes[$change.Id] = @{ Outcome = 'Skipped'; Detail = "declined at the confirmation prompt: $($change.Detail)" }
                            }
                        }
                        foreach ($row in @(Get-PortSettingQosRow -Context $context -SettingChain $chain -RuleOutcome $outcomes)) { $rows.Add($row) }
                    }
                }
                catch {
                    $message = $_.Exception.Message
                    $readFailedCount++
                    Write-Log "  $($vds.Name) / ${pgName}: could not be read. $message" -Level WARN
                    $failContext = @{ PortGroup = $pgName; Scope = 'PortGroup'; Outcome = 'ReadFailed'; Detail = $message }
                    $rows.Add((ConvertTo-QosRow -Values (Merge-Hashtable -Table @($switchContext, $failContext))))
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
    if ($readFailedCount -gt 0) { Write-Log "$readFailedCount port group(s) could not be read; see the ReadFailed rows." -Level WARN }
    if ($Action -ne 'Audit') {
        $verb = if ($WhatIfPreference) { 'would change' } else { 'changed' }
        Write-Log ('{0}: {1} rule change(s) planned; {2} port group(s) {3}, {4} failed. Outcome per rule is in the CSV.' -f $Action, $plannedRuleCount, $changedPortgroupCount, $verb, $failedPortgroupCount)
        if ($failedPortgroupCount -gt 0) { Write-Log "$failedPortgroupCount port group change(s) failed; see the Failed rows." -Level ERROR }
    }

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
            New-Item -Path $outputDirectory -ItemType Directory -Force -WhatIf:$false | Out-Null
        }
        # Written on -WhatIf too: the dry-run report is the point of a dry run.
        $sorted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
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
            Disconnect-VIServer -Server $session -Confirm:$false -WhatIf:$false -ErrorAction Stop
            Write-Log "Disconnected from $name." -Level DEBUG
        }
        catch {
            Write-Log "Could not disconnect from ${name}: $($_.Exception.Message)" -Level WARN
        }
    }
}
