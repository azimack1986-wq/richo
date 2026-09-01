<#
.SYNOPSIS
    Checks one UCS Manager domain and its vCenter against each other and against
    the recommended configuration, and reports every difference.

.DESCRIPTION
    READ ONLY. Nothing here writes to UCS Manager or to vCenter. The output is a
    list of findings for someone else - or a later change - to act on.

    SELF-CONTAINED. One file, no repo, no config file, no helper module - copy it
    to a jump host and run it. The only things it needs are VMware PowerCLI and
    the Cisco UCS PowerTool already being present, and it checks for the cmdlets
    it actually calls before it does anything else. It imports nothing: a jump
    host with a pinned module bundle already loaded should not have this script
    fighting it.

    THE DESIGN IT ASSUMES

      Each vNIC trunks the VLANs its host needs, and exactly one of them is
      native. That is what several of the checks measure against, so it is stated
      here rather than buried: a vNIC with two VLANs marked native is a
      misconfiguration, one with none is a deviation, and many VLANs on a vNIC is
      normal and is never itself a finding.

      It is also why MAC register mode is held to 'all-host-vlans'. With many
      VLANs per vNIC, 'only-native-vlan' leaves every VM outside the native VLAN
      reachable only by flooding.

      -SkipBestPractice drops the parts of this that are convention - a vNIC with
      no native VLAN - and keeps the parts that are wrong on any design.

    WHERE IT STARTS

      At UCS Manager, and at the service profiles. They are the inventory: they
      name the blades that exist, and each one carries the vNICs to be checked.
      Each profile is then matched to its host in the vCenter you name.

      Starting at vCenter instead answers a different question - it checks
      whatever happens to be registered there, and says nothing at all about a
      blade whose host is disconnected, was never added, or is in some other
      vCenter. Those are exactly the blades worth knowing about, so they are
      findings here rather than silence.

      Matching is by hardware UUID first: UCS writes the service profile's UUID
      into the blade's SMBIOS and ESXi reports it back, so a hit there is proof
      rather than a naming convention. Where only the name matches, CDP and LLDP
      are asked which fabric the host is really cabled to before its vNICs are
      compared against this domain - two domains with a profile and a host of the
      same name is otherwise a silent way to report against the wrong fabric.

    HOW IT SIGNS IN

      One credential, typed once, used for both. In these estates it is the same
      domain account, and a question whose answer is always the same is just a
      keystroke between the operator and the answer. -UcsCredential and
      -VICredential override it for one side where they differ.

      Nothing is stored and nothing outlives the run. A rejected credential is
      discarded rather than sent again, attempts are counted, and after
      -MaxCredentialAttempt failures no further sign-in is attempted at all.

    WHAT IT REPORTS

      Every check that runs writes a row, whether or not it found anything: ERROR
      and WARN for a discrepancy, OK for a check that ran clean. That is the
      difference between a report you can review and one you can only scan - a
      list of faults alone cannot be told apart from a run where the check never
      happened, and here a domain that could not be signed in to, a profile with
      no host and a perfectly configured blade all produce no fault lines.

      Findings carry a Category. CONSISTENCY is something that does not match
      something else it has to match. BEST PRACTICE is something that works but
      is not how it should be built. They are kept apart because they are read by
      different people at different times: one is an outage waiting for a fabric
      failover, the other is a conversation.

    CONSISTENCY - THINGS THAT DO NOT MATCH

      1. VLAN definitions in the domain. The same VLAN id defined under two
         names, the same name carrying two ids, ids in the UCS Manager reserved
         range, and an Ethernet VLAN colliding with a VSAN's FCoE VLAN.

      2. VLANs on the fabric that no vNIC template uses. A VLAN created in the
         domain and never added to a template is a half-finished change: the
         network side was done, the server side was not, and nothing in UCS
         Manager marks it. Reported separately from a VLAN that reaches a blade
         through a vNIC configured off-template, which is a different problem.

      3. The native VLAN on each vNIC. Two VLANs marked native means only one
         of them actually takes untagged frames and the other is not what the
         configuration says it is; none at all means untagged frames on that
         uplink have nowhere to land.

      4. vNIC pair symmetry. The two legs of a pair are the same connection over
         two fabrics, so everything about them must match except the fabric. By
         default vNICs 0/1, 2/3 and 4/5 are compared as pairs (-VnicPairGroup);
         the VLAN set, the native VLAN, the MTU, the network control, QoS and
         adapter policies and the template type must agree, and the two legs must
         sit on different fabric interconnects.

      5. A vNIC that has drifted from its own template, which an initial-template
         edited after the profile was stamped produces silently.

      6. The vSphere cross-check. For each host, the physical NICs are mapped to
         the distributed switch that owns them, and the VLANs the vDS port groups
         actually need are checked against the VLANs UCS trunks to those same
         vmnics. A port group VLAN that UCS does not trunk is a black hole; the
         reverse is only noise, so it is reported as INFO. The vDS MTU is checked
         against the vNIC MTU behind it.

      7. Discovery protocol agreement. A vDS set to CDP in front of a network
         control policy with CDP disabled is why hosts report no neighbour.

      8. What neither side accounts for. A service profile with no host in this
         vCenter, a host that is registered but disconnected, a profile with no
         vNICs, an uplink with no vNIC behind it, and a host sharing a cluster
         with this domain's blades while cabled to a different fabric.

    BEST PRACTICE - THINGS THAT WORK BUT SHOULD NOT BE BUILT THAT WAY

      Skipped entirely with -SkipBestPractice.

      9. Network control policy. Action on Uplink Fail must be link-down: set to
         'warning' the vNIC stays up when the fabric loses its uplinks, so ESXi
         keeps the uplink in the team and keeps sending traffic into a hole, and
         nothing fails over or alarms. MAC register mode should be all-host-vlans
         wherever a blade trunks more than its native VLAN. CDP or LLDP should be
         advertising something.

     10. vNIC settings. Fabric failover should be OFF on a vNIC presented to
         ESXi - the host's teaming already handles a failed uplink, and with both
         in play the fabric moves the MAC while the host still believes its
         uplink is healthy. Templates should be updating, not initial. A vNIC's
         MTU must fit the QoS system class its policy maps to, or jumbo frames
         are dropped with no error anywhere.

     11. Service profiles should come from a service profile template; one built
         by hand has nothing holding it to its peers.

     12. Port group teaming. IP hash is not supported in front of UCS - it needs
         a port channel to the host, and a blade's two vNICs terminate on two
         independent fabric interconnects. Beacon probing cannot attribute a
         failure across only two uplinks. Notify Switches should be on.

     13. Each vDS should have two uplinks on the host, one per fabric, and should
         be listening for CDP or LLDP.

.PARAMETER UcsManager
    UCS Manager to check - the cluster name, not an individual fabric
    interconnect. Prompted for when omitted.

.PARAMETER VIServer
    The vCenter that manages the blades in that domain. Prompted for when
    omitted.

.PARAMETER Credential
    The credential for both. Prompted for once when omitted.

.PARAMETER UcsCredential
    Use this for UCS Manager instead of -Credential.

.PARAMETER VICredential
    Use this for vCenter instead of -Credential.

.PARAMETER HostDomainSuffix
    DNS suffix to append to a service profile name when matching it to a host by
    name, e.g. '.example.com'. Only used where the hardware UUID did not match.

.PARAMETER ServiceProfile
    Limit the run to these service profiles. Accepts wildcards.

.PARAMETER SkipBestPractice
    Report only the things that do not match each other, and skip the
    recommended-configuration checks entirely.

.PARAMETER VnicPairGroup
    Groups of vNIC ordinals that must be identical to each other. Defaults to
    '0,1', '2,3', '4,5'.

.PARAMETER ExpectedMtu
    When set, every vNIC in a compared group must carry this MTU. Left at 0 the
    MTU is only compared between the legs of a pair.

.PARAMETER LargeTrunkThreshold
    A port group trunking more VLANs than this is reported as INFO with a count
    rather than as a missing-VLAN error. Defaults to 64. Uplink port groups trunk
    everything by design and demanding UCS carry all of it is pure noise.

.PARAMETER MaxUnassignedVlanDetail
    How many fabric VLANs that no vNIC template uses to report one by one before
    rolling them into a single finding. Defaults to 25. A domain commonly defines
    far more VLANs than any one set of templates carries.

.PARAMETER MaxCredentialAttempt
    Failed UCS sign-ins tolerated before no further UCS login is attempted this
    run. Defaults to 2.

.PARAMETER CsvPath
    Write the findings to this CSV as well as returning them. One row per check,
    faults first and the clean rows after, with Status (REVIEW, NOTE, PASS) and
    Category (Consistency, BestPractice) columns so a reviewer can filter or
    colour it in a spreadsheet without reading every line.

.PARAMETER IncludeInformational
    Return INFO findings too. By default the report carries the faults (ERROR and
    WARN) and the checks that came back clean (OK), but not the INFO context.

.PARAMETER Transcript
    Record the run to a timestamped .log in the current directory, for change
    evidence.

.EXAMPLE
    .\Test-UcsVnicVlanConsistency.ps1

    Prompts for the UCS Manager, the vCenter and one credential, then checks
    every associated service profile in that domain.

.EXAMPLE
    .\Test-UcsVnicVlanConsistency.ps1 -UcsManager ucs01.example.com -VIServer vcenter01.example.com -CsvPath .\vlan-review.csv

    The same, with the full report written to CSV for review.

.EXAMPLE
    .\Test-UcsVnicVlanConsistency.ps1 -UcsManager ucs01.example.com -VIServer vcenter01.example.com -ServiceProfile 'PRD-*' -ExpectedMtu 9000 -Transcript

    Only the production profiles, requiring 9000 everywhere, with the run
    recorded.

.EXAMPLE
    .\Test-UcsVnicVlanConsistency.ps1 -UcsManager ucs01.example.com -VIServer vcenter01.example.com -SkipBestPractice | Where-Object Severity -eq 'ERROR'

    Only the things that do not match, and only the ones that break traffic.

.NOTES
    Read-only, so there is no -WhatIf: there is nothing to suppress.

    Nothing is written to disk except the CSV and the transcript you ask for, and
    no credential is stored, cached beyond the run, or logged. Passwords are held
    as the SecureString inside a PSCredential and dropped when the script ends,
    however it ends.

    One domain per run, deliberately. Checking several means several vCenters,
    several credentials and a report in which "this VLAN is missing" no longer
    says where - run it once per domain and keep the CSVs apart.
#>
#Requires -Version 5.1
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$UcsManager,

    [Parameter(Mandatory, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$VIServer,

    [pscredential]$Credential,

    [pscredential]$UcsCredential,

    [pscredential]$VICredential,

    [string]$HostDomainSuffix,

    [string[]]$ServiceProfile,

    [switch]$SkipBestPractice,

    [ValidateNotNullOrEmpty()]
    [string[]]$VnicPairGroup = @('0,1', '2,3', '4,5'),

    [ValidateRange(0, 9216)]
    [int]$ExpectedMtu = 0,

    [ValidateRange(1, 4094)]
    [int]$LargeTrunkThreshold = 64,

    [ValidateRange(1, 4094)]
    [int]$MaxUnassignedVlanDetail = 25,

    [ValidateRange(1, 10)]
    [int]$MaxCredentialAttempt = 2,

    [string]$CsvPath,

    [switch]$IncludeInformational,

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NOTHING IS IMPORTED. This runs on a prepared jump host where PowerCLI and the
# UCS PowerTool are already loaded or auto-loading, and an import here would
# either duplicate the host build's job or fight a pinned bundle already in the
# session. What the script needs is checked by cmdlet, once, before any work.

function Write-Log {
    <#
    .SYNOPSIS
        A timestamped, levelled progress line, written to the host only.

    .DESCRIPTION
        To the HOST, deliberately, not to the success stream. The findings are
        this script's return value and anything else written to the pipeline ends
        up mixed into them, so a caller doing 'Export-Csv' or '| Format-Table'
        gets progress chatter in the report.

        DEBUG lines appear only under -Verbose. ERROR goes to the host like the
        rest rather than to the error stream: with $ErrorActionPreference = 'Stop'
        a Write-Error would terminate the run at the point it was trying to
        explain, which is how one unreachable domain would abandon every other.

    .PARAMETER Message
        The text to log.

    .PARAMETER Level
        DEBUG, INFO, WARN or ERROR. Defaults to INFO.

    .EXAMPLE
        Write-Log "Connected to UCS Manager 'ucs01'." -Level INFO
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if ($Level -eq 'DEBUG' -and -not $script:VerboseLogging) { return }

    $colour = switch ($Level) {
        'DEBUG' { 'DarkGray' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    Write-Host ('{0} [{1,-5}] {2}' -f $stamp, $Level, $Message) -ForegroundColor $colour
}

# ---- Run state -------------------------------------------------------------
# Script scope, initialised here. Under Set-StrictMode a first read of an unset
# variable throws, and these are read from helpers before they are ever written.
$script:Findings                 = New-Object System.Collections.Generic.List[object]
$script:FindingIndex             = @{}
$script:UcsCredentialCache       = $null
$script:UcsCredentialAttempt     = 0
$script:UcsCredentialBlocked     = $false
$script:UcsSessions              = @{}
$script:DiscoveryCache           = @{}
$script:VerboseLogging           = ($VerbosePreference -ne 'SilentlyContinue')

# UCS Manager reserves this band for its own use; a VLAN created inside it is
# rejected or silently unusable depending on the release.
$script:UcsReservedVlanFirst = 4030
$script:UcsReservedVlanLast  = 4047

# ============================================================================
# Generic helpers
# ============================================================================

function Get-MoProperty {
    <#
    .SYNOPSIS
        A property of a managed object, or a default when it is absent.

    .DESCRIPTION
        Every object read here comes from a vendor module whose shape changes
        between releases - LldpTransmit on a network control policy, Vnet on a
        vNIC interface, MaxMtu on a vDS config. Under Set-StrictMode reading a
        property that this UCSM or PowerCLI build does not have is a terminating
        error, so nothing reads one directly.

    .PARAMETER InputObject
        The object to read. $null is allowed and yields the default.

    .PARAMETER Name
        Property name.

    .PARAMETER Default
        Returned when the object is $null, has no such property, or the property
        itself is $null.

    .EXAMPLE
        $lldp = Get-MoProperty -InputObject $policy -Name 'LldpTransmit' -Default 'unknown'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Position = 2)]
        [AllowNull()]
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    $property = $null
    try { $property = $InputObject.PSObject.Properties[$Name] } catch { return $Default }
    if ($null -eq $property) { return $Default }

    $value = $property.Value
    if ($null -eq $value) { return $Default }
    return $value
}

function Format-IdList {
    <#
    .SYNOPSIS
        Renders a list of ids compactly, collapsing consecutive runs into ranges.

    .DESCRIPTION
        A finding that reads "missing 100-131" is actionable; the same finding
        spelling out thirty-two numbers is not read at all. Output is capped so a
        trunk-everything port group cannot produce a finding nobody can scroll.

    .PARAMETER Id
        The ids. Duplicates and ordering do not matter.

    .PARAMETER MaxItem
        How many comma-separated items to show before summarising the remainder.

    .EXAMPLE
        Format-IdList -Id @(100,101,102,250)   # '100-102, 250'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyCollection()]
        [int[]]$Id = @(),

        [ValidateRange(1, 200)]
        [int]$MaxItem = 12
    )

    $sorted = @($Id | Sort-Object -Unique)
    if ($sorted.Count -eq 0) { return '(none)' }

    $parts = New-Object System.Collections.Generic.List[string]
    $runStart = $sorted[0]
    $runEnd = $sorted[0]

    foreach ($value in @($sorted | Select-Object -Skip 1)) {
        if ($value -eq ($runEnd + 1)) { $runEnd = $value; continue }
        if ($runStart -eq $runEnd) { [void]$parts.Add("$runStart") } else { [void]$parts.Add("$runStart-$runEnd") }
        $runStart = $value
        $runEnd = $value
    }
    if ($runStart -eq $runEnd) { [void]$parts.Add("$runStart") } else { [void]$parts.Add("$runStart-$runEnd") }

    $rendered = $parts.ToArray()
    if ($rendered.Count -le $MaxItem) { return ($rendered -join ', ') }

    $shown = @($rendered | Select-Object -First $MaxItem)
    return ('{0} and {1} more' -f ($shown -join ', '), ($rendered.Count - $MaxItem))
}

function Add-Finding {
    <#
    .SYNOPSIS
        Records one finding, folding an identical one from another host into it.

    .DESCRIPTION
        A service profile template stamps the same vNIC configuration onto every
        blade in a cluster, so a single mistake surfaces once per host. Reported
        that way, forty hosts produce forty copies of one line and the report
        stops being read.

        Findings are therefore keyed on what is actually wrong - domain, scope,
        check, subject and text - and a repeat only adds its host to the existing
        finding's Hosts list. The count of affected hosts is the useful part; the
        line is the same line.

    .PARAMETER Severity
        ERROR for something that breaks or will break traffic, WARN for drift
        that should be corrected, INFO for context, OK for a check that ran and
        found nothing wrong.

        OK rows are the point of reading the report rather than scanning it. A
        report that lists only faults cannot be told apart from a report where
        the check never ran, and 'no findings' is exactly what a broken discovery
        step also looks like.

    .PARAMETER Scope
        Where it was found: UCS, vCenter, or CrossCheck.

    .PARAMETER Category
        Consistency for something that does not match something else it must
        match; BestPractice for something that works but deviates from the
        recommended configuration. Kept apart because they are read by different
        people at different times - one is an outage waiting to happen, the other
        is a conversation.

    .PARAMETER Check
        Short stable code for the rule, e.g. VnicPairVlanMismatch.

    .PARAMETER Detail
        The sentence an operator reads.

    .PARAMETER Domain
        UCS Manager address, or the vCenter, this finding belongs to.

    .PARAMETER Subject
        What it is about - a VLAN name, vNIC template, port group or vDS.

    .PARAMETER Expected
        What the value should have been.

    .PARAMETER Actual
        What it is.

    .PARAMETER HostName
        The host this was seen on, folded into an existing identical finding.

    .EXAMPLE
        Add-Finding -Severity ERROR -Scope UCS -Check VnicPairVlanMismatch `
            -Subject 'eth0/eth1' -Detail 'eth0 is missing VLAN 250.' -HostName $esx
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ERROR', 'WARN', 'INFO', 'OK')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [ValidateSet('UCS', 'vCenter', 'CrossCheck')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Check,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Detail,

        [ValidateSet('Consistency', 'BestPractice')]
        [string]$Category = 'Consistency',

        [string]$Domain = '',
        [string]$Subject = '',
        [string]$Expected = '',
        [string]$Actual = '',
        [string]$HostName = ''
    )

    $key = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $Domain, $Scope, $Check, $Subject, $Expected, $Actual, $Detail

    if ($script:FindingIndex.ContainsKey($key)) {
        $existing = $script:FindingIndex[$key]
        if ($HostName -and -not $existing.Hosts.Contains($HostName)) { [void]$existing.Hosts.Add($HostName) }
        return
    }

    $affected = New-Object System.Collections.Generic.List[string]
    if ($HostName) { [void]$affected.Add($HostName) }

    $finding = [pscustomobject]@{
        Severity = $Severity
        Category = $Category
        Scope    = $Scope
        Domain   = $Domain
        Check    = $Check
        Subject  = $Subject
        Expected = $Expected
        Actual   = $Actual
        Detail   = $Detail
        Hosts    = $affected
    }

    $script:FindingIndex[$key] = $finding
    [void]$script:Findings.Add($finding)
}

function Add-CheckResult {
    <#
    .SYNOPSIS
        Records what a check found - or, when it found nothing, that it ran clean.

    .DESCRIPTION
        Every check goes through here so that a clean result is written down
        rather than merely absent. A report listing only faults cannot be
        distinguished from a report where the check never ran, and on this script
        that distinction matters: a domain that could not be signed in to, a host
        with no CDP neighbour and a host that is perfectly configured all produce
        no fault lines.

        A check is clean when it produced no ERROR and no WARN. INFO does not
        spoil it - INFO is context, not a discrepancy.

        The OK line is deliberately written without host-specific text, so
        Add-Finding folds the identical result from every host in a cluster into
        one row naming them all rather than forty copies.

    .PARAMETER Finding
        What the check returned: objects with Severity, Check, Subject, Expected,
        Actual and Detail.

    .PARAMETER Scope
        UCS, vCenter or CrossCheck.

    .PARAMETER Check
        The check name to record when it is clean.

    .PARAMETER Detail
        The sentence to record when it is clean - what was verified.

    .PARAMETER Subject
        What was checked: a vNIC pair, a vDS, a domain.

    .PARAMETER Domain
        The UCS domain this belongs to.

    .PARAMETER HostName
        The host it was checked on, folded into an identical result from another.

    .EXAMPLE
        Add-CheckResult -Finding $found -Scope UCS -Check VnicPair -Subject 'eth0/eth1' `
            -Detail 'VLANs, native VLAN, MTU and policies match across both fabrics.'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyCollection()]
        [array]$Finding = @(),

        [Parameter(Mandatory)]
        [ValidateSet('UCS', 'vCenter', 'CrossCheck')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Check,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Detail,

        [ValidateSet('Consistency', 'BestPractice')]
        [string]$Category = 'Consistency',

        [string]$Subject = '',
        [string]$Domain = '',
        [string]$HostName = ''
    )

    foreach ($entry in $Finding) {
        # A check may return both kinds - a vNIC pair that does not match AND a
        # pair that matches but sits on an initial-template - so the entry's own
        # category wins where it has one.
        Add-Finding -Severity $entry.Severity -Scope $Scope -Check $entry.Check -Domain $Domain -HostName $HostName `
            -Category ([string](Get-MoProperty $entry 'Category' $Category)) `
            -Subject $entry.Subject -Expected $entry.Expected -Actual $entry.Actual -Detail $entry.Detail
    }

    $faults = @($Finding | Where-Object { ($_.Severity -eq 'ERROR') -or ($_.Severity -eq 'WARN') })
    if ($faults.Count -gt 0) { return }

    Add-Finding -Severity 'OK' -Scope $Scope -Check $Check -Domain $Domain -HostName $HostName -Category $Category `
        -Subject $Subject -Expected '' -Actual 'checked, no discrepancy' -Detail $Detail
}

# ============================================================================
# VLAN values and UCS VLAN inventory
# ============================================================================

function Get-VlanIdReservation {
    <#
    .SYNOPSIS
        Why a VLAN id is not usable, or an empty string when it is fine.

    .DESCRIPTION
        Only the bands that are documented and stable are reported. Reserved
        ranges do vary between fabric interconnect generations, and a check that
        invents a range for the generation in front of it produces findings
        nobody can act on - so this reports what is true everywhere and says
        nothing about the rest.

          - outside 1-4094      : not a VLAN id at all
          - 4030-4047           : reserved by UCS Manager
          - 1002-1005           : legacy FDDI/Token Ring ids, reserved on Cisco
                                  switching and best left unused
          - 1                   : the default VLAN, carried as INFO by the caller

    .PARAMETER VlanId
        The id to judge.

    .EXAMPLE
        Get-VlanIdReservation -VlanId 4040   # 'reserved by UCS Manager (4030-4047)'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [int]$VlanId
    )

    if ($VlanId -lt 1 -or $VlanId -gt 4094) { return 'outside the valid VLAN range 1-4094' }
    if ($VlanId -ge $script:UcsReservedVlanFirst -and $VlanId -le $script:UcsReservedVlanLast) {
        return ('reserved by UCS Manager ({0}-{1})' -f $script:UcsReservedVlanFirst, $script:UcsReservedVlanLast)
    }
    if ($VlanId -ge 1002 -and $VlanId -le 1005) { return 'a legacy reserved id (1002-1005) on Cisco switching' }
    return ''
}

function Test-UcsVlanInventory {
    <#
    .SYNOPSIS
        Findings for the VLAN definitions in one UCS domain.

    .DESCRIPTION
        Four faults, all of which are invisible until traffic lands on them:

          - one id defined under two names. Both resolve, one is trunked, and
            which one you get depends on which name the vNIC template was built
            with.
          - one name carrying two ids. Usually a fabric-scoped pair (A and B
            with different ids), which is legitimate, so it is only a finding
            when the two are not simply the two fabrics.
          - an id in a reserved band.
          - an Ethernet VLAN with the same id as a VSAN's FCoE VLAN. UCS will
            let both exist and the FCoE traffic wins.

        Pure - the caller supplies the objects, so this is testable without a
        fabric.

    .PARAMETER Vlan
        fabricVlan objects: Name, Id, SwitchId.

    .PARAMETER Vsan
        fabricVsan objects: Name, Id, FcoeVlan. May be empty.

    .EXAMPLE
        Test-UcsVlanInventory -Vlan $vlans -Vsan $vsans
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyCollection()]
        [array]$Vlan = @(),

        [Parameter(Position = 1)]
        [AllowEmptyCollection()]
        [array]$Vsan = @()
    )

    $results = New-Object System.Collections.Generic.List[object]

    $rows = @($Vlan | ForEach-Object {
        [pscustomobject]@{
            Name     = [string](Get-MoProperty $_ 'Name' '')
            Id       = [int](Get-MoProperty $_ 'Id' 0)
            SwitchId = [string](Get-MoProperty $_ 'SwitchId' '')
        }
    })

    # --- one id, several names ----------------------------------------------
    foreach ($group in @($rows | Group-Object -Property Id | Where-Object { $_.Count -gt 1 })) {
        $names = @($group.Group | Select-Object -ExpandProperty Name | Sort-Object -Unique)
        if ($names.Count -lt 2) { continue }
        [void]$results.Add([pscustomobject]@{
            Severity = 'ERROR'; Check = 'VlanIdDefinedTwice'
            Subject  = "VLAN $($group.Name)"
            Expected = 'one name per VLAN id'
            Actual   = ($names -join ', ')
            Detail   = ("VLAN id {0} is defined under {1} names ({2}). A vNIC template built with one name and a port group expecting the other look identical and are not." -f $group.Name, $names.Count, ($names -join ', '))
        })
    }

    # --- one name, several ids ----------------------------------------------
    # A name appearing once per fabric with a different id on each is a normal
    # fabric-scoped VLAN, not a fault, so only same-fabric or dual-scope
    # collisions are reported.
    foreach ($group in @($rows | Group-Object -Property Name | Where-Object { $_.Count -gt 1 })) {
        $ids = @($group.Group | Select-Object -ExpandProperty Id | Sort-Object -Unique)
        if ($ids.Count -lt 2) { continue }
        $switches = @($group.Group | Select-Object -ExpandProperty SwitchId | Sort-Object -Unique)
        $fabricScoped = ($ids.Count -eq 2 -and $switches.Count -eq 2 -and $switches -notcontains 'dual')
        if ($fabricScoped) { continue }
        [void]$results.Add([pscustomobject]@{
            Severity = 'ERROR'; Check = 'VlanNameDefinedTwice'
            Subject  = $group.Name
            Expected = 'one id per VLAN name'
            Actual   = (Format-IdList -Id $ids)
            Detail   = ("VLAN name '{0}' carries {1} different ids ({2}) on fabric(s) {3}. Anything referring to it by name gets whichever the fabric resolves." -f $group.Name, $ids.Count, (Format-IdList -Id $ids), ($switches -join '/'))
        })
    }

    # --- reserved and default ids -------------------------------------------
    foreach ($row in @($rows | Sort-Object Id, Name -Unique)) {
        $reason = Get-VlanIdReservation -VlanId $row.Id
        if ($reason) {
            [void]$results.Add([pscustomobject]@{
                Severity = 'ERROR'; Check = 'VlanIdReserved'
                Subject  = "$($row.Name) ($($row.Id))"
                Expected = 'a usable VLAN id'
                Actual   = "$($row.Id)"
                Detail   = ("VLAN '{0}' uses id {1}, which is {2}." -f $row.Name, $row.Id, $reason)
            })
            continue
        }
        if ($row.Id -eq 1) {
            [void]$results.Add([pscustomobject]@{
                Severity = 'INFO'; Check = 'VlanIdDefault'
                Subject  = "$($row.Name) (1)"
                Expected = 'a dedicated data VLAN'
                Actual   = '1'
                Detail   = ("VLAN '{0}' is the default VLAN 1. Worth confirming it is deliberate rather than left over." -f $row.Name)
            })
        }
    }

    # --- Ethernet VLAN colliding with an FCoE VLAN ---------------------------
    foreach ($vsanObject in @($Vsan)) {
        $fcoeId = [int](Get-MoProperty $vsanObject 'FcoeVlan' 0)
        if ($fcoeId -le 0) { continue }
        $vsanName = [string](Get-MoProperty $vsanObject 'Name' '')
        foreach ($clash in @($rows | Where-Object { $_.Id -eq $fcoeId } | Sort-Object Name -Unique)) {
            [void]$results.Add([pscustomobject]@{
                Severity = 'ERROR'; Check = 'VlanFcoeCollision'
                Subject  = "$($clash.Name) ($fcoeId)"
                Expected = "an id other than the FCoE VLAN of VSAN '$vsanName'"
                Actual   = "$fcoeId"
                Detail   = ("Ethernet VLAN '{0}' uses id {1}, which is also the FCoE VLAN of VSAN '{2}'. UCS allows both to exist and the storage traffic wins." -f $clash.Name, $fcoeId, $vsanName)
            })
        }
    }

    return $results.ToArray()
}

function Test-UcsVlanAssignment {
    <#
    .SYNOPSIS
        Findings for VLANs the fabric carries that no vNIC template uses.

    .DESCRIPTION
        A VLAN created in the domain and never added to a vNIC template is a
        half-finished change. The network side was done - the VLAN exists, the
        uplinks carry it - and the server side was not, so no blade can ever see
        it. Nothing in UCS Manager marks the difference between that and a VLAN
        deliberately held in reserve, which is why it has to be looked for.

        Two outcomes, because they have different fixes:

          - on no template and on no vNIC at all: nothing in this domain can use
            it. Either finish the change or delete the VLAN.
          - on a service profile's vNIC but on no template: a blade does have it,
            but it was put there by hand. The next template push does not know
            about it and rebuilding that profile loses it.

        VLAN 1 is skipped. It always exists, it is almost never on a template on
        purpose, and reporting it on every run is how the rest of this list stops
        being read. Test-UcsVlanInventory already notes it separately.

        A domain commonly defines far more VLANs than any one set of templates
        carries, so past -MaxIndividual the finding is rolled up into one line
        naming them rather than hundreds of lines saying the same thing.

    .PARAMETER Vlan
        fabricVlan objects: Name, Id.

    .PARAMETER TemplateVlanName
        VLAN names referenced by a vNIC template in this domain.

    .PARAMETER ProfileVlanName
        VLAN names referenced directly by a service profile's vNICs.

    .PARAMETER MaxIndividual
        Above this many unused VLANs, report one rolled-up finding instead of one
        per VLAN.

    .EXAMPLE
        Test-UcsVlanAssignment -Vlan $vlans -TemplateVlanName $onTemplates -ProfileVlanName $onVnics
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyCollection()]
        [array]$Vlan = @(),

        [Parameter(Position = 1)]
        [AllowEmptyCollection()]
        [string[]]$TemplateVlanName = @(),

        [Parameter(Position = 2)]
        [AllowEmptyCollection()]
        [string[]]$ProfileVlanName = @(),

        [ValidateRange(1, 4094)]
        [int]$MaxIndividual = 25
    )

    $results = New-Object System.Collections.Generic.List[object]

    $onTemplate = @{}
    foreach ($name in $TemplateVlanName) { if ($name) { $onTemplate[$name] = $true } }
    $onVnic = @{}
    foreach ($name in $ProfileVlanName) { if ($name) { $onVnic[$name] = $true } }

    $orphans = New-Object System.Collections.Generic.List[object]
    $offTemplate = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($row in $Vlan) {
        $name = [string](Get-MoProperty $row 'Name' '')
        $id = [int](Get-MoProperty $row 'Id' 0)
        if (-not $name -or $id -eq 1) { continue }
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true

        if ($onTemplate.ContainsKey($name)) { continue }
        $entry = [pscustomobject]@{ Name = $name; Id = $id }
        if ($onVnic.ContainsKey($name)) { [void]$offTemplate.Add($entry) } else { [void]$orphans.Add($entry) }
    }

    if ($orphans.Count -gt $MaxIndividual) {
        $ids = @($orphans.ToArray() | ForEach-Object { [int]$_.Id })
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Check = 'VlanNotOnAnyVnicTemplate'
            Subject  = "$($orphans.Count) VLANs"
            Expected = 'every VLAN on the fabric carried by a vNIC template'
            Actual   = (Format-IdList -Id $ids -MaxItem 30)
            Detail   = ("{0} VLANs are defined on this fabric and are on no vNIC template and no service profile vNIC: {1}. No blade in this domain can use any of them - either the change that created them was never finished on the server side, or they are left over." -f $orphans.Count, (Format-IdList -Id $ids -MaxItem 30))
        })
    }
    else {
        foreach ($entry in $orphans.ToArray()) {
            [void]$results.Add([pscustomobject]@{
                Severity = 'WARN'; Check = 'VlanNotOnAnyVnicTemplate'
                Subject  = "$($entry.Name) ($($entry.Id))"
                Expected = 'a vNIC template carrying it'
                Actual   = 'on no vNIC template and no service profile vNIC'
                Detail   = ("VLAN '{0}' (id {1}) is defined on this fabric but is on no vNIC template and no service profile vNIC, so no blade in this domain can use it. Either the change that created it was never finished on the server side, or it is left over." -f $entry.Name, $entry.Id)
            })
        }
    }

    foreach ($entry in $offTemplate.ToArray()) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'INFO'; Check = 'VlanOnVnicButNoTemplate'
            Subject  = "$($entry.Name) ($($entry.Id))"
            Expected = 'a vNIC template carrying it'
            Actual   = 'added directly to a service profile vNIC'
            Detail   = ("VLAN '{0}' (id {1}) reaches a blade through a vNIC configured directly on a service profile rather than through a template. It survives until that profile is rebuilt, and no template push will restore it." -f $entry.Name, $entry.Id)
        })
    }

    # No leading comma. The elements are finding objects, not arrays, so there is
    # nothing to protect from unrolling - and ',@()' would hand the caller a
    # one-element array wrapping an empty one, which reads as a finding.
    return $results.ToArray()
}

function Get-VlanSummary {
    <#
    .SYNOPSIS
        The VLANs carried by one vNIC template or one vNIC, from its interface rows.

    .DESCRIPTION
        Both a vNIC template and a vNIC below a service profile hold their VLANs
        the same way - as vnicEtherIf children whose Dn is the parent's Dn plus
        one segment - so one function answers for both and the caller passes
        whichever parent it has.

        Vnet is the id, but it is not always populated: on some releases the
        interface row carries only the VLAN name and the id has to come from the
        domain's VLAN table. Both routes are used, name first when Vnet is empty,
        so a template does not silently report an empty VLAN set.

        Natives are returned as a set with a count, not as a single value. The
        design here is many VLANs trunked per vNIC with exactly one of them
        native, so both "none" and "more than one" are things to find - and
        keeping only the last row marked native would report the second case as
        if it were correct.

    .PARAMETER ParentDn
        Dn of the vNIC template or vNIC.

    .PARAMETER InterfaceIndex
        Hashtable of parent Dn to that parent's vnicEtherIf rows.

    .PARAMETER VlanIdByName
        Hashtable of VLAN name to id, used when a row carries no Vnet.

    .EXAMPLE
        Get-VlanSummary -ParentDn $template.Dn -InterfaceIndex $index -VlanIdByName $byName
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$ParentDn,

        [Parameter(Mandatory, Position = 1)]
        [hashtable]$InterfaceIndex,

        [Parameter(Position = 2)]
        [hashtable]$VlanIdByName = @{}
    )

    $ids = New-Object System.Collections.Generic.List[int]
    $names = New-Object System.Collections.Generic.List[string]
    $unresolved = New-Object System.Collections.Generic.List[string]
    # EVERY row marked native, not the last one seen. This estate trunks many
    # VLANs per vNIC with exactly one of them native, so "how many are native"
    # is a thing to check rather than an assumption - and taking only the last
    # would silently reduce two natives to one and report the misconfiguration
    # as correct.
    $nativeIds = New-Object System.Collections.Generic.List[int]
    $nativeNames = New-Object System.Collections.Generic.List[string]

    # NOT @($InterfaceIndex[$ParentDn]). The caller indexes the interface rows
    # into Generic.List[object] as it reads them, and an array subexpression
    # around one of those throws "Argument types do not match" on this
    # PowerShell build - a throw that lands here, deep in the VLAN read, rather
    # than where the list was made. .ToArray() is the portable form.
    $rows = @()
    if ($ParentDn -and $InterfaceIndex.ContainsKey($ParentDn)) {
        $stored = $InterfaceIndex[$ParentDn]
        if ($null -ne $stored -and $stored -is [System.Collections.IList] -and $stored -isnot [array]) { $rows = $stored.ToArray() }
        else { $rows = @($stored) }
    }

    foreach ($row in $rows) {
        $name = [string](Get-MoProperty $row 'Name' '')
        $id = [int](Get-MoProperty $row 'Vnet' 0)
        if ($id -le 0 -and $name -and $VlanIdByName.ContainsKey($name)) { $id = [int]$VlanIdByName[$name] }

        if ($name -and -not $names.Contains($name)) { [void]$names.Add($name) }
        if ($id -gt 0) {
            if (-not $ids.Contains($id)) { [void]$ids.Add($id) }
        }
        elseif ($name) {
            if (-not $unresolved.Contains($name)) { [void]$unresolved.Add($name) }
        }

        if ([string](Get-MoProperty $row 'DefaultNet' 'no') -eq 'yes') {
            if ($name -and -not $nativeNames.Contains($name)) { [void]$nativeNames.Add($name) }
            if ($id -gt 0 -and -not $nativeIds.Contains($id)) { [void]$nativeIds.Add($id) }
        }
    }

    # NativeId and NativeName are the first of them, for the comparisons that
    # want one value; NativeCount is what says whether that is the whole truth.
    $sortedNativeIds = @($nativeIds.ToArray() | Sort-Object)
    $sortedNativeNames = @($nativeNames.ToArray() | Sort-Object)

    return [pscustomobject]@{
        ParentDn    = $ParentDn
        VlanIds     = @($ids.ToArray() | Sort-Object)
        VlanNames   = @($names.ToArray() | Sort-Object)
        Unresolved  = @($unresolved.ToArray() | Sort-Object)
        NativeIds   = $sortedNativeIds
        NativeNames = $sortedNativeNames
        NativeCount = $sortedNativeNames.Count
        NativeId    = $(if ($sortedNativeIds.Count -gt 0) { $sortedNativeIds[0] } else { 0 })
        NativeName  = $(if ($sortedNativeNames.Count -gt 0) { $sortedNativeNames[0] } else { '' })
        Count       = $ids.Count
    }
}

# ============================================================================
# vNIC ordinals and pair comparison
# ============================================================================

function Get-VnicOrdinal {
    <#
    .SYNOPSIS
        The trailing number in a vNIC name, or -1 when it has none.

    .PARAMETER Name
        vNIC name, e.g. 'eth0' or 'vmnic3' or 'MGMT-A'.

    .EXAMPLE
        Get-VnicOrdinal -Name 'eth10'   # 10
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ($Name -match '(\d+)\s*$') { return [int]$Matches[1] }
    return -1
}

function Get-VnicOrdinalMap {
    <#
    .SYNOPSIS
        Maps each vNIC to the ordinal ESXi will enumerate it as.

    .DESCRIPTION
        The pair checks and the whole vDS cross-check hang off getting this
        right, so it is derived rather than assumed, and it says which way it
        decided.

        Names first. Where every vNIC ends in a number and those numbers are
        distinct, they are the ordinals - eth0..eth5 is what these estates use
        and it is the operator's own numbering, not a guess.

        Otherwise the UCS Order field, ascending, assigned 0..n-1. Order is what
        drives PCI enumeration and therefore vmnic numbering, so it is the right
        fallback, but a service profile with gaps or duplicate orders makes it a
        derived answer rather than a stated one - hence the Source field, which
        the caller reports so nobody has to guess how the mapping was reached.

    .PARAMETER Vnic
        vnicEther objects for one service profile.

    .EXAMPLE
        $map = Get-VnicOrdinalMap -Vnic $vnics
        $map.Map[0].Name
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyCollection()]
        [array]$Vnic = @()
    )

    $map = @{}
    if ($Vnic.Count -eq 0) { return [pscustomobject]@{ Map = $map; Source = 'none' } }

    $named = @($Vnic | ForEach-Object {
        [pscustomobject]@{ Vnic = $_; Ordinal = (Get-VnicOrdinal -Name ([string](Get-MoProperty $_ 'Name' ''))) }
    })

    $allNamed = -not [bool](@($named | Where-Object { $_.Ordinal -lt 0 }).Count)
    $distinct = (@($named | Select-Object -ExpandProperty Ordinal | Sort-Object -Unique).Count -eq $named.Count)

    if ($allNamed -and $distinct) {
        foreach ($entry in $named) { $map[$entry.Ordinal] = $entry.Vnic }
        return [pscustomobject]@{ Map = $map; Source = 'name' }
    }

    $ordered = @($Vnic | Sort-Object -Property @{ Expression = { [int](Get-MoProperty $_ 'Order' 0) } }, @{ Expression = { [string](Get-MoProperty $_ 'Name' '') } })
    for ($index = 0; $index -lt $ordered.Count; $index++) { $map[$index] = $ordered[$index] }
    return [pscustomobject]@{ Map = $map; Source = 'order' }
}

function ConvertTo-OrdinalGroup {
    <#
    .SYNOPSIS
        Turns '0,1' style pair-group strings into arrays of ordinals.

    .DESCRIPTION
        Rejects anything that is not a comma-separated list of non-negative
        integers rather than silently comparing an empty group, and drops
        duplicates within a group so '0,0' cannot pass a comparison by having
        only itself to compare against.

    .PARAMETER Group
        The raw -VnicPairGroup strings.

    .EXAMPLE
        ConvertTo-OrdinalGroup -Group @('0,1','2,3')
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [string[]]$Group
    )

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($raw in $Group) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $parts = @($raw -split '[,;/\s]+' | Where-Object { $_ -ne '' })
        $ordinals = New-Object System.Collections.Generic.List[int]
        foreach ($part in $parts) {
            if ($part -notmatch '^\d+$') { throw "Invalid -VnicPairGroup entry '$raw': '$part' is not a vNIC ordinal." }
            $value = [int]$part
            if (-not $ordinals.Contains($value)) { [void]$ordinals.Add($value) }
        }
        if ($ordinals.Count -lt 2) { throw "Invalid -VnicPairGroup entry '$raw': a group needs at least two distinct ordinals." }
        [void]$result.Add($ordinals.ToArray())
    }
    # The comma matters. Returning the bare array lets PowerShell unroll it, and
    # a single configured group then arrives at the caller as loose integers -
    # so 'foreach ($group in $pairGroups)' iterates 0 and 1 instead of [0,1] and
    # every vNIC is compared against nothing.
    return ,$result.ToArray()
}

function Compare-VnicGroup {
    <#
    .SYNOPSIS
        Findings for one group of vNICs that are supposed to be identical.

    .DESCRIPTION
        The two legs of a pair are one connection carried over two fabric
        interconnects. Everything about them must therefore match - VLANs, native
        VLAN, MTU, the network control, QoS and adapter policies, and the
        template they come from - and the one thing that must NOT match is the
        fabric, because two legs on the same FI is a single point of failure
        wearing a redundant pair's name.

        The VLAN comparison is against the union of the group, so a member
        missing a VLAN and a member carrying a stray one are two different
        findings with two different fixes, rather than one "they differ".

        Pure. Members are plain objects, so this is testable without a fabric.

    .PARAMETER Member
        One object per vNIC in the group, each with Ordinal, VnicName,
        TemplateName, TemplateType, SwitchId, Mtu, VlanIds, NativeId,
        NativeName, NetworkControlPolicy, QosPolicy and AdapterPolicy.

    .PARAMETER ExpectedMtu
        When greater than zero, every member must carry this MTU.

    .EXAMPLE
        Compare-VnicGroup -Member $members -ExpectedMtu 9000
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyCollection()]
        [array]$Member,

        [int]$ExpectedMtu = 0
    )

    $results = New-Object System.Collections.Generic.List[object]
    if ($Member.Count -eq 0) { return $results.ToArray() }

    $label = (@($Member | ForEach-Object { $_.VnicName }) -join '/')

    if ($Member.Count -lt 2) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Check = 'VnicGroupIncomplete'
            Subject  = $label
            Expected = 'both legs of the pair present'
            Actual   = "only $($Member[0].VnicName)"
            Detail   = ("vNIC {0} has no partner in its group. Either the service profile is short a vNIC or the ordinals do not line up with -VnicPairGroup." -f $Member[0].VnicName)
        })
        return $results.ToArray()
    }

    # --- VLAN set ------------------------------------------------------------
    $union = @(@($Member | ForEach-Object { $_.VlanIds }) | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    foreach ($entry in $Member) {
        $missing = @($union | Where-Object { @($entry.VlanIds) -notcontains $_ })
        if ($missing.Count -eq 0) { continue }
        $carriers = @($Member | Where-Object { $_.VnicName -ne $entry.VnicName -and @(@($_.VlanIds) | Where-Object { $missing -contains $_ }).Count -gt 0 } | ForEach-Object { $_.VnicName })
        [void]$results.Add([pscustomobject]@{
            Severity = 'ERROR'; Check = 'VnicPairVlanMismatch'
            Subject  = $label
            Expected = ('VLANs {0}' -f (Format-IdList -Id $union))
            Actual   = ('{0} carries {1}' -f $entry.VnicName, (Format-IdList -Id @($entry.VlanIds)))
            Detail   = ("{0} (template '{1}') is missing VLAN(s) {2} that {3} carries. Traffic on those VLANs survives only while the other fabric is up." -f $entry.VnicName, $entry.TemplateName, (Format-IdList -Id $missing), ($carriers -join ', '))
        })
    }

    # --- everything else that must agree -------------------------------------
    $scalarChecks = @(
        [pscustomobject]@{ Property = 'NativeId';             Check = 'VnicPairNativeVlanMismatch'; Severity = 'ERROR'; Label = 'native VLAN' }
        [pscustomobject]@{ Property = 'Mtu';                  Check = 'VnicPairMtuMismatch';        Severity = 'ERROR'; Label = 'MTU' }
        [pscustomobject]@{ Property = 'NetworkControlPolicy'; Check = 'VnicPairPolicyMismatch';      Severity = 'WARN';  Label = 'network control policy' }
        [pscustomobject]@{ Property = 'QosPolicy';            Check = 'VnicPairPolicyMismatch';      Severity = 'WARN';  Label = 'QoS policy' }
        [pscustomobject]@{ Property = 'AdapterPolicy';        Check = 'VnicPairPolicyMismatch';      Severity = 'WARN';  Label = 'adapter policy' }
        [pscustomobject]@{ Property = 'TemplateType';         Check = 'VnicPairTemplateTypeMismatch'; Severity = 'WARN'; Label = 'template type' }
    )

    foreach ($check in $scalarChecks) {
        $values = @($Member | ForEach-Object { "$($_.($check.Property))" })
        if (@($values | Sort-Object -Unique).Count -le 1) { continue }
        $rendered = @($Member | ForEach-Object { '{0}={1}' -f $_.VnicName, $_.($check.Property) })
        [void]$results.Add([pscustomobject]@{
            Severity = $check.Severity; Check = $check.Check
            Subject  = $label
            Expected = ('the same {0} on both legs' -f $check.Label)
            Actual   = ($rendered -join ', ')
            Detail   = ("The {0} differs across {1}: {2}. The two legs are one connection over two fabrics and must be configured identically." -f $check.Label, $label, ($rendered -join ', '))
        })
    }

    # --- the fabric, which must NOT agree ------------------------------------
    $switches = @($Member | ForEach-Object { "$($_.SwitchId)" } | Where-Object { $_ -ne '' })
    if ($switches.Count -eq $Member.Count -and @($switches | Sort-Object -Unique).Count -lt $Member.Count) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'ERROR'; Check = 'VnicPairSameFabric'
            Subject  = $label
            Expected = 'one leg per fabric interconnect'
            Actual   = (@($Member | ForEach-Object { '{0}={1}' -f $_.VnicName, $_.SwitchId }) -join ', ')
            Detail   = ("{0} do not sit on separate fabric interconnects. A pair on one fabric is a single point of failure that looks redundant." -f $label)
        })
    }

    # --- an explicit MTU expectation -----------------------------------------
    if ($ExpectedMtu -gt 0) {
        foreach ($entry in $Member) {
            if ([int]$entry.Mtu -eq $ExpectedMtu) { continue }
            [void]$results.Add([pscustomobject]@{
                Severity = 'ERROR'; Check = 'VnicMtuUnexpected'
                Subject  = $entry.VnicName
                Expected = "$ExpectedMtu"
                Actual   = "$($entry.Mtu)"
                Detail   = ("{0} (template '{1}') has MTU {2}, not the expected {3}." -f $entry.VnicName, $entry.TemplateName, $entry.Mtu, $ExpectedMtu)
            })
        }
    }

    # --- a vNIC with no template behind it -----------------------------------
    $templated = @($Member | Where-Object { "$($_.TemplateName)" -ne '' })
    if ($templated.Count -gt 0 -and $templated.Count -lt $Member.Count) {
        foreach ($entry in @($Member | Where-Object { "$($_.TemplateName)" -eq '' })) {
            [void]$results.Add([pscustomobject]@{
                Severity = 'WARN'; Check = 'VnicNotTemplated'
                Subject  = $entry.VnicName
                Expected = 'a vNIC template, as its partner has'
                Actual   = 'configured directly on the service profile'
                Detail   = ("{0} is configured on the service profile itself while its partner comes from a template. Its VLANs will not follow a template change." -f $entry.VnicName)
            })
        }
    }

    return $results.ToArray()
}

# ============================================================================
# vSphere: port group VLANs, uplink mapping, discovery protocol
# ============================================================================

function ConvertTo-VlanIdList {
    <#
    .SYNOPSIS
        The VLAN ids a distributed port group actually needs, from its VLAN spec.

    .DESCRIPTION
        A port group's VLAN arrives as one of three unrelated shapes and only the
        type name tells them apart:

          VmwareDistributedVirtualSwitchVlanIdSpec    - VlanId is a single int,
                                                        and 0 means untagged.
          VmwareDistributedVirtualSwitchTrunkVlanSpec - VlanId is an array of
                                                        NumericRange, Start/End.
          VmwareDistributedVirtualSwitchPvlanSpec     - PvlanId, a secondary
                                                        private VLAN.

        Read the wrong one and a trunk port group looks like VLAN 0. Ranges are
        expanded because the caller needs set arithmetic against the UCS trunk,
        and the widest possible expansion is 4094 integers - not worth being
        clever about. Count is returned so the caller can decline to demand UCS
        trunk a range that spans the whole space.

    .PARAMETER VlanSpec
        The port group's Config.DefaultPortConfig.Vlan.

    .EXAMPLE
        ConvertTo-VlanIdList -VlanSpec $pg.ExtensionData.Config.DefaultPortConfig.Vlan
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $VlanSpec
    )

    $empty = [pscustomobject]@{ Kind = 'None'; VlanIds = @(); Count = 0; Description = 'untagged' }
    if ($null -eq $VlanSpec) { return $empty }

    $typeName = ''
    try { $typeName = $VlanSpec.GetType().Name } catch { $typeName = '' }

    # The type name settles it when the vendor object arrives with the name this
    # build gives it. Shape settles it otherwise: a trunk spec's VlanId is an
    # array of NumericRange, an id spec's is a bare int, and only the pvlan spec
    # carries PvlanId. Judging on shape as well means a renamed type on some
    # future PowerCLI does not silently turn a trunk port group into VLAN 0.
    $rawVlanId = Get-MoProperty $VlanSpec 'VlanId' $null
    $pvlanId = [int](Get-MoProperty $VlanSpec 'PvlanId' 0)

    $isTrunk = [bool]($typeName -match 'TrunkVlanSpec')
    if (-not $isTrunk -and $null -ne $rawVlanId) {
        $isTrunk = ($rawVlanId -is [array]) -or ($null -ne (Get-MoProperty $rawVlanId 'Start' $null))
    }
    $isPvlan = [bool]($typeName -match 'PvlanSpec') -or ($pvlanId -gt 0 -and $null -eq $rawVlanId)

    if ($isPvlan) {
        if ($pvlanId -le 0) { return $empty }
        return [pscustomobject]@{
            Kind = 'Pvlan'; VlanIds = @($pvlanId); Count = 1
            Description = ("private VLAN $pvlanId")
        }
    }

    if ($isTrunk) {
        $ids = New-Object System.Collections.Generic.List[int]
        foreach ($range in @($rawVlanId)) {
            $start = [int](Get-MoProperty $range 'Start' 0)
            $end = [int](Get-MoProperty $range 'End' $start)
            if ($end -lt $start) { $end = $start }
            for ($id = $start; $id -le $end; $id++) {
                if ($id -lt 1 -or $id -gt 4094) { continue }
                if (-not $ids.Contains($id)) { [void]$ids.Add($id) }
            }
        }
        $sorted = @($ids.ToArray() | Sort-Object)
        return [pscustomobject]@{
            Kind = 'Trunk'; VlanIds = $sorted; Count = $sorted.Count
            Description = ('trunk {0}' -f (Format-IdList -Id $sorted -MaxItem 6))
        }
    }

    # The plain id spec, and anything unrecognised that still carries a VlanId.
    $single = [int](Get-MoProperty $VlanSpec 'VlanId' 0)
    if ($single -le 0) { return $empty }
    return [pscustomobject]@{
        Kind = 'Access'; VlanIds = @($single); Count = 1
        Description = ("VLAN $single")
    }
}

function Test-UplinkPortGroup {
    <#
    .SYNOPSIS
        Whether a distributed port group is the vDS's own uplink port group.

    .DESCRIPTION
        The uplink port group trunks everything by design, so measuring UCS
        against it would report every VLAN in the estate as missing. vCenter
        marks it with the SYSTEM/DVS.UPLINKPG tag; some builds also expose an
        IsUplink property, which is checked as a fallback rather than relied on.

    .PARAMETER PortGroupView
        The port group's ExtensionData.

    .EXAMPLE
        Test-UplinkPortGroup -PortGroupView $pg.ExtensionData
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $PortGroupView
    )

    if ($null -eq $PortGroupView) { return $false }

    foreach ($tag in @(Get-MoProperty $PortGroupView 'Tag' @())) {
        if ([string](Get-MoProperty $tag 'Key' '') -match '(?i)UPLINKPG') { return $true }
    }

    $config = Get-MoProperty $PortGroupView 'Config' $null
    if ([string](Get-MoProperty $config 'Type' '') -match '(?i)uplink') { return $true }
    if ([bool](Get-MoProperty $PortGroupView 'IsUplink' $false)) { return $true }

    return $false
}

function Get-HostUplinkMap {
    <#
    .SYNOPSIS
        Which distributed switch owns each of a host's physical NICs.

    .DESCRIPTION
        This is the join between the two halves of the check. Without it there is
        no way to say which UCS vNIC feeds which vDS, and the cross-check reduces
        to comparing every VLAN in the domain against every VLAN in vCenter,
        which finds nothing.

        Config.Network.ProxySwitch holds it exactly: one entry per vDS present on
        the host, each naming the vDS and listing the pnic keys assigned to it.
        The keys look like 'key-vim.host.PhysicalNic-vmnic2', so the device name
        is the last segment.

    .PARAMETER HostView
        The host's HostSystem view.

    .EXAMPLE
        $map = Get-HostUplinkMap -HostView $view
        $map['vmnic2']   # 'dvs-prod-01'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        $HostView
    )

    $map = @{}
    if ($null -eq $HostView) { return $map }

    $config = Get-MoProperty $HostView 'Config' $null
    $network = Get-MoProperty $config 'Network' $null

    foreach ($proxy in @(Get-MoProperty $network 'ProxySwitch' @())) {
        $dvsName = [string](Get-MoProperty $proxy 'DvsName' '')
        if (-not $dvsName) { continue }
        foreach ($key in @(Get-MoProperty $proxy 'Pnic' @())) {
            $device = ([string]$key -split '-')[-1]
            if ($device) { $map[$device] = $dvsName }
        }
    }

    return $map
}

function Get-VdsDiscoveryProtocol {
    <#
    .SYNOPSIS
        The link discovery protocol a vDS is configured for.

    .DESCRIPTION
        Returned as protocol and operation - 'cdp' with 'listen', 'both',
        'advertise' or 'none'. A vDS listening for CDP in front of a UCS network
        control policy with CDP disabled is precisely the fault that makes hosts
        report no neighbour, and it is the reason the discovery step of this
        script can fail on a fabric that is otherwise healthy.

    .PARAMETER VdsView
        The vDS ExtensionData.

    .EXAMPLE
        Get-VdsDiscoveryProtocol -VdsView $vds.ExtensionData
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $VdsView
    )

    $config = Get-MoProperty $VdsView 'Config' $null
    $discovery = Get-MoProperty $config 'LinkDiscoveryProtocolConfig' $null

    return [pscustomobject]@{
        Protocol  = ([string](Get-MoProperty $discovery 'Protocol' '')).ToLowerInvariant()
        Operation = ([string](Get-MoProperty $discovery 'Operation' '')).ToLowerInvariant()
    }
}

function Compare-VdsVlanCoverage {
    <#
    .SYNOPSIS
        Findings for the VLANs a vDS needs against the VLANs UCS trunks to it.

    .DESCRIPTION
        The direction that matters is one way. A VLAN a port group needs and UCS
        does not trunk is a black hole - the port group exists, VMs attach to it,
        and the frames are dropped at the fabric interconnect. The reverse, a
        VLAN trunked to the blade that no port group uses, costs nothing and is
        usually deliberate headroom, so it is INFO.

        A port group trunking more than -LargeTrunkThreshold VLANs is not held to
        the same standard. Those are the transit and uplink-style port groups
        that trunk a wide range on purpose, and demanding UCS carry the whole
        range would bury the real findings.

        Pure - no vCenter and no fabric needed to exercise it.

    .PARAMETER VdsName
        For the finding text.

    .PARAMETER PortGroup
        One object per port group with Name, Kind, VlanIds and Count, as
        ConvertTo-VlanIdList returns, plus the name.

    .PARAMETER TrunkedVlanId
        VLAN ids UCS carries on the vNICs feeding this vDS.

    .PARAMETER NativeVlanId
        The UCS native VLAN on those vNICs, 0 when none is set.

    .PARAMETER LargeTrunkThreshold
        Port groups wider than this are reported by count instead.

    .EXAMPLE
        Compare-VdsVlanCoverage -VdsName dvs01 -PortGroup $groups -TrunkedVlanId $ids -NativeVlanId 0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$VdsName,

        [Parameter(Position = 1)]
        [AllowEmptyCollection()]
        [array]$PortGroup = @(),

        [Parameter(Position = 2)]
        [AllowEmptyCollection()]
        [int[]]$TrunkedVlanId = @(),

        [int]$NativeVlanId = 0,

        [ValidateRange(1, 4094)]
        [int]$LargeTrunkThreshold = 64
    )

    $results = New-Object System.Collections.Generic.List[object]
    $trunked = @($TrunkedVlanId | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    $used = New-Object System.Collections.Generic.List[int]

    foreach ($group in $PortGroup) {
        $ids = @(@($group.VlanIds) | Where-Object { $_ -gt 0 })
        foreach ($id in $ids) { if (-not $used.Contains([int]$id)) { [void]$used.Add([int]$id) } }

        if ($group.Kind -eq 'None') {
            # Untagged frames arrive on the uplink's native VLAN. With no native
            # VLAN set on the UCS side there is nothing for them to land on.
            if ($NativeVlanId -le 0) {
                [void]$results.Add([pscustomobject]@{
                    Severity = 'WARN'; Check = 'PortGroupUntaggedNoNativeVlan'
                    Subject  = "$VdsName / $($group.Name)"
                    Expected = 'a native VLAN on the UCS vNICs feeding this vDS'
                    Actual   = 'no native VLAN configured'
                    Detail   = ("Port group '{0}' on '{1}' is untagged, but the UCS vNICs feeding that vDS have no native VLAN. Untagged frames have nowhere to land." -f $group.Name, $VdsName)
                })
            }
            continue
        }

        if ($group.Count -gt $LargeTrunkThreshold) {
            $covered = @($ids | Where-Object { $trunked -contains $_ })
            [void]$results.Add([pscustomobject]@{
                Severity = 'INFO'; Check = 'PortGroupWideTrunk'
                Subject  = "$VdsName / $($group.Name)"
                Expected = "coverage of $($group.Count) VLANs"
                Actual   = "$($covered.Count) trunked by UCS"
                Detail   = ("Port group '{0}' on '{1}' trunks {2} VLANs; UCS carries {3} of them. Too wide to treat the remainder as missing - check it deliberately if this port group is in use." -f $group.Name, $VdsName, $group.Count, $covered.Count)
            })
            continue
        }

        $missing = @($ids | Where-Object { $trunked -notcontains $_ })
        if ($missing.Count -eq 0) { continue }

        [void]$results.Add([pscustomobject]@{
            Severity = 'ERROR'; Check = 'PortGroupVlanNotTrunked'
            Subject  = "$VdsName / $($group.Name)"
            Expected = ('VLAN(s) {0} trunked on the UCS vNICs' -f (Format-IdList -Id $missing))
            Actual   = 'not present on the vNIC templates'
            Detail   = ("Port group '{0}' on '{1}' uses VLAN(s) {2}, which UCS does not trunk to those vmnics. Anything attached to it is black-holed at the fabric interconnect." -f $group.Name, $VdsName, (Format-IdList -Id $missing))
        })
    }

    $unused = @($trunked | Where-Object { -not $used.Contains($_) })
    if ($unused.Count -gt 0) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'INFO'; Check = 'TrunkedVlanUnused'
            Subject  = $VdsName
            Expected = ''
            Actual   = (Format-IdList -Id $unused)
            Detail   = ("UCS trunks VLAN(s) {0} to the vmnics behind '{1}' that no port group uses. Harmless, but it is either headroom or a leftover." -f (Format-IdList -Id $unused), $VdsName)
        })
    }

    return $results.ToArray()
}

# ============================================================================
# Best practice - the recommended configuration, as opposed to a mismatch
# ============================================================================
#
# Everything in this region answers "is this how it should be built", not "does
# this match the thing next to it". They are kept apart in the report because
# they are read by different people at different times: a mismatch is an outage
# waiting for a fabric failover, a best-practice deviation is a conversation.

function Get-QosClassMtu {
    <#
    .SYNOPSIS
        The MTU each QoS policy actually gets, by policy name.

    .DESCRIPTION
        A vNIC's MTU is not the whole story. The frame also has to fit the QoS
        system class its priority maps to, and UCS lets you set a vNIC to 9000
        while the class it lands in is still at 1500. Nothing warns; jumbo frames
        are simply dropped, and the symptom - vMotion stalling, NFS timing out on
        large reads - looks nothing like an MTU problem.

        Three objects to walk: the QoS policy (epqosDefinition) names a priority
        through its egress child (epqosEgress.Prio), and the system class
        (fabricQosClass) holds the MTU for that priority. Class MTU is a string
        that may be a number or a keyword.

    .PARAMETER Policy
        epqosDefinition objects: Name, Dn.

    .PARAMETER Egress
        epqosEgress objects: Dn (below the policy), Prio.

    .PARAMETER QosClass
        fabricQosClass objects: Priority, Mtu, AdminState.

    .EXAMPLE
        $mtuByPolicy = Get-QosClassMtu -Policy $p -Egress $e -QosClass $c
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyCollection()]
        [array]$Policy = @(),

        [Parameter(Position = 1)]
        [AllowEmptyCollection()]
        [array]$Egress = @(),

        [Parameter(Position = 2)]
        [AllowEmptyCollection()]
        [array]$QosClass = @()
    )

    $mtuByPriority = @{}
    foreach ($class in $QosClass) {
        $priority = [string](Get-MoProperty $class 'Priority' '')
        if (-not $priority) { continue }
        # 'normal' is the keyword for 1500 and 'fc' for the 2240-byte FCoE class.
        # Anything else that is not a number is not something to guess at.
        $raw = [string](Get-MoProperty $class 'Mtu' '')
        $mtu = 0
        if ($raw -match '^\d+$') { $mtu = [int]$raw }
        elseif ($raw -eq 'normal') { $mtu = 1500 }
        elseif ($raw -eq 'fc') { $mtu = 2240 }
        if ($mtu -gt 0) { $mtuByPriority[$priority] = $mtu }
    }

    $priorityByPolicyDn = @{}
    foreach ($row in $Egress) {
        $parent = Get-ParentDn -Dn ([string](Get-MoProperty $row 'Dn' ''))
        $priority = [string](Get-MoProperty $row 'Prio' '')
        if ($parent -and $priority) { $priorityByPolicyDn[$parent] = $priority }
    }

    $result = @{}
    foreach ($definition in $Policy) {
        $name = [string](Get-MoProperty $definition 'Name' '')
        $dn = [string](Get-MoProperty $definition 'Dn' '')
        if (-not $name -or -not $priorityByPolicyDn.ContainsKey($dn)) { continue }
        $priority = $priorityByPolicyDn[$dn]
        if ($mtuByPriority.ContainsKey($priority)) { $result[$name] = $mtuByPriority[$priority] }
    }
    return $result
}

function Test-NetworkControlPolicyBestPractice {
    <#
    .SYNOPSIS
        Best-practice findings for one network control policy.

    .DESCRIPTION
        THE UPLINK FAIL ACTION IS THE ONE THAT MATTERS. Set to 'warning' instead
        of 'link-down', a vNIC stays up when its fabric interconnect loses every
        northbound uplink. ESXi sees a healthy link, keeps the uplink in the team,
        and keeps handing it traffic that goes nowhere. Nothing fails over,
        nothing alarms in vCenter, and the outage is invisible from the host. This
        is reported as an ERROR rather than a recommendation because there is no
        design in which a vSwitch-teamed blade wants it.

        MAC REGISTER MODE IS NOT A JUDGEMENT CALL HERE. This deployment trunks
        many VLANs per vNIC with one of them native, so on 'only-native-vlan' the
        fabric interconnect installs each MAC on the native VLAN only and every
        VM on any other VLAN - which is most of them - relies on flooding to be
        reached. It works, quietly and badly, until the flood domain gets large
        enough to notice.

        Discovery is judged on the pair. CDP off is unremarkable where LLDP is on;
        both off means nothing downstream can identify the fabric, which is a
        troubleshooting dead end and breaks discovery-based tooling.

    .PARAMETER Policy
        An nwctrlDefinition object.

    .EXAMPLE
        Test-NetworkControlPolicyBestPractice -Policy $ncp
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        $Policy
    )

    $results = New-Object System.Collections.Generic.List[object]
    $name = [string](Get-MoProperty $Policy 'Name' '')

    $uplinkFail = [string](Get-MoProperty $Policy 'UplinkFailAction' '')
    if ($uplinkFail -and $uplinkFail -ne 'link-down') {
        [void]$results.Add([pscustomobject]@{
            Severity = 'ERROR'; Category = 'BestPractice'; Check = 'NcpUplinkFailAction'
            Subject  = $name
            Expected = 'link-down'
            Actual   = $uplinkFail
            Detail   = ("Network control policy '{0}' has Action on Uplink Fail set to '{1}'. The vNIC stays up when the fabric interconnect loses its northbound uplinks, so ESXi keeps the uplink in the team and keeps sending traffic into a hole. Nothing fails over and nothing alarms." -f $name, $uplinkFail)
        })
    }

    $macMode = [string](Get-MoProperty $Policy 'MacRegisterMode' '')
    if ($macMode -and $macMode -ne 'all-host-vlans') {
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Category = 'BestPractice'; Check = 'NcpMacRegisterMode'
            Subject  = $name
            Expected = 'all-host-vlans'
            Actual   = $macMode
            Detail   = ("Network control policy '{0}' registers MACs on the native VLAN only ('{1}'). Every vNIC here trunks several VLANs with one native, so each VM outside the native VLAN is reached by flooding rather than by a learned MAC." -f $name, $macMode)
        })
    }

    $cdp = [string](Get-MoProperty $Policy 'Cdp' 'disabled')
    $lldpTransmit = [string](Get-MoProperty $Policy 'LldpTransmit' 'unknown')
    if ($cdp -ne 'enabled') {
        if ($lldpTransmit -eq 'enabled') {
            [void]$results.Add([pscustomobject]@{
                Severity = 'INFO'; Category = 'BestPractice'; Check = 'NcpCdpDisabled'
                Subject  = $name
                Expected = 'CDP enabled'
                Actual   = "CDP $cdp, LLDP transmit enabled"
                Detail   = ("Network control policy '{0}' has CDP disabled, but LLDP is transmitting, so the fabric is still identifiable from the host." -f $name)
            })
        }
        else {
            [void]$results.Add([pscustomobject]@{
                Severity = 'WARN'; Category = 'BestPractice'; Check = 'NcpNoDiscoveryProtocol'
                Subject  = $name
                Expected = 'CDP or LLDP enabled'
                Actual   = "CDP $cdp, LLDP transmit $lldpTransmit"
                Detail   = ("Network control policy '{0}' has neither CDP nor LLDP transmitting. Nothing downstream can identify which fabric interconnect a blade is cabled to - which is a dead end when troubleshooting, and breaks any tooling that maps hosts to their domain." -f $name)
            })
        }
    }

    return $results.ToArray()
}

function Test-VnicBestPractice {
    <#
    .SYNOPSIS
        Best-practice findings for one resolved vNIC.

    .DESCRIPTION
        FABRIC FAILOVER IS THE ONE PEOPLE ARGUE ABOUT. On a vNIC presented to
        ESXi it should be off: the host's own teaming already handles a failed
        uplink, and hardware failover on top of it means the fabric moves the MAC
        while the host still believes the original uplink is fine. The failure
        then looks like intermittent loss rather than a failed link, and the host
        never reports the event. Fabric failover is for operating systems with no
        teaming of their own, which ESXi is not.

        An initial-template is a template that stops being one the moment the
        profile is stamped. Edits to it never reach the blades already built from
        it, which is exactly the drift this script exists to find, so a vNIC that
        comes from one is flagged whether or not it has drifted yet.

        The QoS class MTU is the silent one. A vNIC at 9000 whose priority lands
        in a class still at 1500 drops jumbo frames with no error anywhere.

    .PARAMETER Member
        A resolved vNIC: VnicName, TemplateName, TemplateType, SwitchId, Mtu,
        VlanIds, QosPolicy.

    .PARAMETER QosClassMtu
        Hashtable of QoS policy name to the MTU of the class it maps to. An
        absent entry means the class could not be resolved and is not guessed at.

    .EXAMPLE
        Test-VnicBestPractice -Member $member -QosClassMtu $mtuByPolicy
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        $Member,

        [Parameter(Position = 1)]
        [hashtable]$QosClassMtu = @{}
    )

    $results = New-Object System.Collections.Generic.List[object]
    $name = [string]$Member.VnicName

    # 'A-B' or 'B-A' is UCS fabric failover; a bare 'A' or 'B' is not.
    $switchId = [string]$Member.SwitchId
    if ($switchId -match '-') {
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Category = 'BestPractice'; Check = 'VnicFabricFailoverEnabled'
            Subject  = $name
            Expected = 'fabric failover disabled, teaming left to ESXi'
            Actual   = $switchId
            Detail   = ("{0} has UCS fabric failover enabled ('{1}'). ESXi already handles a failed uplink through its own teaming; with both in play the fabric moves the MAC while the host still believes its uplink is healthy, so a failure reads as intermittent loss and the host never reports it." -f $name, $switchId)
        })
    }

    if ([string]$Member.TemplateType -eq 'initial-template') {
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Category = 'BestPractice'; Check = 'VnicTemplateNotUpdating'
            Subject  = $name
            Expected = 'updating-template'
            Actual   = 'initial-template'
            Detail   = ("{0} comes from vNIC template '{1}', which is an initial-template. Edits to it never reach a blade already built from it, so the template and the blade drift apart silently from the moment the profile is stamped." -f $name, $Member.TemplateName)
        })
    }

    $qosPolicy = [string]$Member.QosPolicy
    $mtu = [int]$Member.Mtu
    if ($qosPolicy -and $mtu -gt 0 -and $QosClassMtu.ContainsKey($qosPolicy)) {
        $classMtu = [int]$QosClassMtu[$qosPolicy]
        if ($mtu -gt $classMtu) {
            [void]$results.Add([pscustomobject]@{
                Severity = 'ERROR'; Category = 'BestPractice'; Check = 'VnicMtuExceedsQosClass'
                Subject  = $name
                Expected = "a QoS class MTU of at least $mtu"
                Actual   = "QoS policy '$qosPolicy' lands in a class with MTU $classMtu"
                Detail   = ("{0} is set to MTU {1} but its QoS policy '{2}' maps to a system class with MTU {3}. Frames above {3} are dropped with no error anywhere - the symptom is vMotion stalling or NFS timing out on large reads, which looks nothing like an MTU problem." -f $name, $mtu, $qosPolicy, $classMtu)
            })
        }
    }

    if (@($Member.VlanIds) -contains 1) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'INFO'; Category = 'BestPractice'; Check = 'VnicCarriesDefaultVlan'
            Subject  = $name
            Expected = 'no VLAN 1 on a data vNIC'
            Actual   = 'VLAN 1 trunked'
            Detail   = ("{0} trunks VLAN 1. The default VLAN carries whatever anything untagged puts on it, and is conventionally kept off data uplinks." -f $name)
        })
    }

    return $results.ToArray()
}

function Test-VnicNativeVlan {
    <#
    .SYNOPSIS
        Findings for the native VLAN on one vNIC, against a trunked design.

    .DESCRIPTION
        THE DESIGN THIS CHECKS. Each vNIC trunks the VLANs its host needs and
        exactly one of them is native. That is what makes both of the cases here
        findings rather than opinions.

        MORE THAN ONE NATIVE is a misconfiguration, not a preference. Only one
        VLAN can receive untagged frames on a trunk, so with two marked native
        the fabric picks one and the other silently is not what the configuration
        says it is. It is worth looking for even though UCS Manager will normally
        refuse it: a profile assembled by API or copied between orgs can carry it,
        and nothing downstream shows it.

        NONE AT ALL means untagged frames arriving on that uplink have nowhere to
        land. On a host that is exactly the traffic you cannot afford to lose -
        it is what a port group left at VLAN 0 uses, and what some appliances and
        PXE clients send. It is reported against the stated design rather than as
        a universal truth, so -SkipBestPractice suppresses it while the
        two-natives error stays.

        A NATIVE OUTSIDE THE TRUNK cannot happen through the UCS model - the
        native VLAN is one of the vNIC's own VLAN rows - but it can survive a
        name that resolves to no id, which leaves the trunk list and the native
        disagreeing. That is worth saying plainly rather than leaving as an
        unresolved-name finding somewhere else in the report.

        Pure. A member object in, findings out.

    .PARAMETER Member
        A resolved vNIC: VnicName, TemplateName, VlanIds, NativeIds, NativeNames,
        NativeCount.

    .PARAMETER RequireNative
        Report a vNIC with no native VLAN. On by default; the caller turns it off
        with -SkipBestPractice, because "every vNIC has a native" is this
        estate's design rather than a rule of the platform.

    .EXAMPLE
        Test-VnicNativeVlan -Member $member

    .EXAMPLE
        Test-VnicNativeVlan -Member $member -RequireNative:$false
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        $Member,

        [bool]$RequireNative = $true
    )

    $results = New-Object System.Collections.Generic.List[object]
    $name = [string]$Member.VnicName
    $nativeIds = @(Get-MoProperty $Member 'NativeIds' @())
    $nativeNames = @(Get-MoProperty $Member 'NativeNames' @())
    $nativeCount = [int](Get-MoProperty $Member 'NativeCount' 0)
    $vlanIds = @($Member.VlanIds)

    if ($nativeCount -gt 1) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'ERROR'; Category = 'Consistency'; Check = 'VnicMultipleNativeVlans'
            Subject  = $name
            Expected = 'exactly one native VLAN'
            Actual   = ("{0} marked native: {1}" -f $nativeCount, ($nativeNames -join ', '))
            Detail   = ("{0} has {1} VLANs marked native ({2}). Only one VLAN can take untagged frames on a trunk, so the fabric uses one of them and the rest are not what the configuration says they are." -f $name, $nativeCount, ($nativeNames -join ', '))
        })
    }
    elseif ($nativeCount -eq 0) {
        if ($RequireNative) {
            [void]$results.Add([pscustomobject]@{
                Severity = 'WARN'; Category = 'BestPractice'; Check = 'VnicNoNativeVlan'
                Subject  = $name
                Expected = 'one native VLAN, as every other vNIC here has'
                Actual   = ("{0} VLAN(s) trunked, none native" -f @($vlanIds).Count)
                Detail   = ("{0} (template '{1}') trunks {2} VLAN(s) with none of them native. Untagged frames arriving on that uplink have nowhere to land - a port group left at VLAN 0, an appliance that does not tag, a PXE client." -f $name, $Member.TemplateName, @($vlanIds).Count)
            })
        }
    }
    elseif (@($vlanIds).Count -gt 0 -and $nativeIds.Count -gt 0 -and $vlanIds -notcontains $nativeIds[0]) {
        # Only reachable when the native row's VLAN name resolved to no id, which
        # leaves the trunk list and the native disagreeing about what is on it.
        [void]$results.Add([pscustomobject]@{
            Severity = 'ERROR'; Category = 'Consistency'; Check = 'VnicNativeVlanNotTrunked'
            Subject  = $name
            Expected = ('the native VLAN among the trunked VLANs {0}' -f (Format-IdList -Id $vlanIds))
            Actual   = ("native {0} ({1})" -f $nativeIds[0], ($nativeNames -join ', '))
            Detail   = ("{0} is marked native on VLAN {1} but that VLAN is not among the ones it trunks ({2}). Untagged frames are placed on a VLAN the vNIC does not carry." -f $name, $nativeIds[0], (Format-IdList -Id $vlanIds))
        })
    }

    return $results.ToArray()
}

function Test-PortGroupBestPractice {
    <#
    .SYNOPSIS
        Best-practice findings for one distributed port group's teaming.

    .DESCRIPTION
        IP HASH IS NOT SUPPORTED IN FRONT OF UCS. It requires a port channel to
        the host, and a blade's two vNICs terminate on two independent fabric
        interconnects that are not a port-channel pair. The result is not a
        performance question - MACs flap between fabrics and traffic is lost.

        Beacon probing needs three or more uplinks to tell which one is at fault.
        With the two a blade has, a beacon failure cannot be attributed, so the
        host guesses; on top of UCS's own link-down behaviour it is redundant as
        well as wrong.

        Notify Switches is what makes a failover fast. With it off, the fabric
        keeps sending to the failed uplink until its MAC table ages out.

    .PARAMETER PortGroup
        A port group row: Name, Teaming, BeaconProbing, NotifySwitches.

    .PARAMETER VdsName
        The switch it belongs to, for the finding text.

    .EXAMPLE
        Test-PortGroupBestPractice -PortGroup $row -VdsName 'dvs-prod'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        $PortGroup,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$VdsName
    )

    $results = New-Object System.Collections.Generic.List[object]
    $name = [string](Get-MoProperty $PortGroup 'Name' '')
    $subject = "$VdsName / $name"

    $teaming = [string](Get-MoProperty $PortGroup 'Teaming' '')
    if ($teaming -eq 'loadbalance_ip') {
        [void]$results.Add([pscustomobject]@{
            Severity = 'ERROR'; Category = 'BestPractice'; Check = 'PortGroupIpHashTeaming'
            Subject  = $subject
            Expected = 'originating virtual port, or explicit failover'
            Actual   = 'route based on IP hash'
            Detail   = ("Port group '{0}' on '{1}' uses IP-hash teaming. That needs a port channel to the host, and a blade's two vNICs terminate on two independent fabric interconnects which are not one. MACs flap between fabrics and traffic is lost." -f $name, $VdsName)
        })
    }

    if ([bool](Get-MoProperty $PortGroup 'BeaconProbing' $false)) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Category = 'BestPractice'; Check = 'PortGroupBeaconProbing'
            Subject  = $subject
            Expected = 'link status only'
            Actual   = 'beacon probing enabled'
            Detail   = ("Port group '{0}' on '{1}' has beacon probing enabled. It needs three or more uplinks to attribute a failure; with the two a blade has, the host cannot tell which uplink is at fault and guesses." -f $name, $VdsName)
        })
    }

    $notify = Get-MoProperty $PortGroup 'NotifySwitches' $null
    if ($null -ne $notify -and -not [bool]$notify) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Category = 'BestPractice'; Check = 'PortGroupNotifySwitchesOff'
            Subject  = $subject
            Expected = 'notify switches enabled'
            Actual   = 'disabled'
            Detail   = ("Port group '{0}' on '{1}' has Notify Switches off. After a failover the fabric keeps sending to the failed uplink until its MAC table ages out, so the outage lasts seconds longer than it needs to." -f $name, $VdsName)
        })
    }

    return $results.ToArray()
}

function Test-VdsBestPractice {
    <#
    .SYNOPSIS
        Best-practice findings for one distributed switch as a host sees it.

    .PARAMETER VdsName
        The switch.

    .PARAMETER UplinkCount
        How many of this host's physical NICs are assigned to it.

    .PARAMETER DiscoveryOperation
        The switch's link discovery operation - listen, advertise, both or none.

    .EXAMPLE
        Test-VdsBestPractice -VdsName dvs-prod -UplinkCount 2 -DiscoveryOperation both
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$VdsName,

        [Parameter(Mandatory, Position = 1)]
        [int]$UplinkCount,

        [Parameter(Position = 2)]
        [AllowEmptyString()]
        [string]$DiscoveryOperation = ''
    )

    $results = New-Object System.Collections.Generic.List[object]

    if ($UplinkCount -lt 2) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Category = 'BestPractice'; Check = 'VdsSingleUplink'
            Subject  = $VdsName
            Expected = 'two uplinks, one per fabric'
            Actual   = "$UplinkCount uplink(s) on this host"
            Detail   = ("'{0}' has {1} uplink(s) on this host. Everything on it is lost with a single fabric interconnect, a single vNIC or a single cable." -f $VdsName, $UplinkCount)
        })
    }

    if ($DiscoveryOperation -eq 'none' -or $DiscoveryOperation -eq '') {
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Category = 'BestPractice'; Check = 'VdsDiscoveryDisabled'
            Subject  = $VdsName
            Expected = 'CDP or LLDP, listening at least'
            Actual   = $(if ($DiscoveryOperation) { $DiscoveryOperation } else { 'not configured' })
            Detail   = ("'{0}' has link discovery off, so no host on it can report which fabric interconnect and which port an uplink is cabled to. That is the first question asked in every network fault, and the answer is not available." -f $VdsName)
        })
    }

    return $results.ToArray()
}

function Test-ServiceProfileBestPractice {
    <#
    .SYNOPSIS
        Best-practice findings for one service profile.

    .DESCRIPTION
        A profile built by hand rather than from a service profile template has
        nothing holding it to its peers. Every check in this script that compares
        one blade to another is looking for the drift that this permits, so it is
        worth knowing which blades are exposed to it before reading the rest.

    .PARAMETER ServiceProfile
        An lsServer object.

    .EXAMPLE
        Test-ServiceProfileBestPractice -ServiceProfile $sp
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        $ServiceProfile
    )

    $results = New-Object System.Collections.Generic.List[object]
    $name = [string](Get-MoProperty $ServiceProfile 'Name' '')

    $source = [string](Get-MoProperty $ServiceProfile 'OperSrcTemplName' '')
    if (-not $source) { $source = [string](Get-MoProperty $ServiceProfile 'SrcTemplName' '') }
    if (-not $source) {
        [void]$results.Add([pscustomobject]@{
            Severity = 'WARN'; Category = 'BestPractice'; Check = 'ProfileNotFromTemplate'
            Subject  = $name
            Expected = 'a service profile template'
            Actual   = 'built directly'
            Detail   = ("Service profile '{0}' was not created from a service profile template, so nothing holds its vNICs, policies and VLANs to those of its peers. Every drift this report looks for is permitted here by design." -f $name)
        })
    }

    return $results.ToArray()
}

# ============================================================================
# CDP/LLDP discovery of the UCS domain in front of a host
# ============================================================================

function Get-LldpSystemName {
    <#
    .SYNOPSIS
        The neighbour's system name out of an LLDP hint, or '' when it carries none.

    .DESCRIPTION
        LLDP has no system name field of its own. LinkLayerDiscoveryProtocolInfo
        carries ChassisId, PortId and a Parameter[] of key/value pairs, and the
        system name arrives in there with whatever spelling the sender chose -
        'System Name', 'SystemName', 'sysName' have all been seen - so the key is
        matched loosely rather than exactly.

        ChassisId is the fallback, but only when it is not a MAC address. On a
        fabric interconnect the chassis id usually is the MAC, which is no use as
        a UCS Manager name and would send the run off to resolve hex.

    .PARAMETER LldpInfo
        The hint's LldpInfo.

    .EXAMPLE
        Get-LldpSystemName -LldpInfo $hint.LldpInfo
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        $LldpInfo
    )

    if ($null -eq $LldpInfo) { return '' }

    foreach ($parameter in @(Get-MoProperty $LldpInfo 'Parameter' @())) {
        $key = [string](Get-MoProperty $parameter 'Key' '')
        if ($key -notmatch '(?i)^\s*(system[\s_-]*name|sysname)\s*$') { continue }
        $value = [string](Get-MoProperty $parameter 'Value' '')
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }

    $chassis = [string](Get-MoProperty $LldpInfo 'ChassisId' '')
    if ([string]::IsNullOrWhiteSpace($chassis)) { return '' }
    if ($chassis -match '^([0-9a-fA-F]{2}[:\-\.]){5}[0-9a-fA-F]{2}$') { return '' }
    if ($chassis -match '^[0-9a-fA-F]{12}$') { return '' }
    return $chassis.Trim()
}

function Remove-UcsTargetDecoration {
    <#
    .SYNOPSIS
        Strips the bracketed suffix CDP and LLDP append to a fabric name.

    .DESCRIPTION
        A neighbour name arrives as, for example,
        'PD24000001SS101-A.example.com(FD0261301D1)'. The bracketed serial is not
        part of the hostname and makes Connect-Ucs fail with 'Invalid URI'.

    .PARAMETER Value
        The raw neighbour name.

    .EXAMPLE
        Remove-UcsTargetDecoration -Value 'fi-a.example.com(FD0261301D1)'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Value
    )

    return (($Value.Trim()) -replace '\s*\([^)]*\)\s*$', '').Trim()
}

function Convert-FiSystemNameToUcsCandidate {
    <#
    .SYNOPSIS
        Reduces a fabric interconnect system name to the UCS Manager cluster name.

    .DESCRIPTION
        CDP and LLDP report the individual FI - 'PD24000001SS101-A.example.com' -
        while UCS Manager answers on the cluster name,
        'PD24000001SS101.example.com'. The -A/-B suffix is removed, and the FQDN
        form is tested before the short form or the domain would be eaten with it.

    .PARAMETER SystemName
        The neighbour name reported by the host.

    .EXAMPLE
        Convert-FiSystemNameToUcsCandidate -SystemName 'ucs01-B.example.com'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$SystemName
    )

    $candidate = Remove-UcsTargetDecoration -Value $SystemName
    if ($candidate -match '^(.+)-[AaBb](\..+)$') { return "$($Matches[1])$($Matches[2])" }
    if ($candidate -match '^(.*)-[AaBb]$') { return $Matches[1] }
    return $candidate
}

function Get-EsxiDiscoveryCandidate {
    <#
    .SYNOPSIS
        Every CDP and LLDP neighbour name a host's physical NICs report, best first.

    .DESCRIPTION
        BOTH PROTOCOLS. Reading only ConnectedSwitchPort - CDP - finds nothing on
        a domain running LLDP with CDP disabled, which is ordinary on 6400-series
        fabric interconnects, and every host then falls through to needing
        -UcsManager by hand.

        BOTH CDP NAME FIELDS. PhysicalNicCdpInfo carries DevId and SystemName and
        they are not always the same string, so both are returned as separate
        candidates and whichever resolves, resolves.

        QueryNetworkHint is issued per physical NIC and is the slowest call in
        the run, so the answer is cached per host. The low-numbered uplinks come
        first because those are the ones cabled to the fabric.

    .PARAMETER VMHostObject
        The host.

    .EXAMPLE
        Get-EsxiDiscoveryCandidate -VMHostObject $esx
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        $VMHostObject
    )

    $hostName = [string]$VMHostObject.Name
    if ($script:DiscoveryCache.ContainsKey($hostName)) { return @($script:DiscoveryCache[$hostName]) }

    $found = New-Object System.Collections.Generic.List[object]
    try {
        $hostView = Get-View -Id $VMHostObject.Id -ErrorAction Stop
        $networkSystem = Get-View -Id $hostView.ConfigManager.NetworkSystem -ErrorAction Stop

        foreach ($pnic in @($hostView.Config.Network.Pnic | Sort-Object Device)) {
            try {
                foreach ($hint in @($networkSystem.QueryNetworkHint($pnic.Device))) {
                    if ($null -eq $hint) { continue }
                    $seen = New-Object System.Collections.Generic.List[string]

                    $cdp = Get-MoProperty $hint 'ConnectedSwitchPort' $null
                    if ($null -ne $cdp) {
                        # SystemName first: on a fabric interconnect it is the
                        # name the domain is known by, where DevId can be
                        # something else entirely.
                        foreach ($value in @([string](Get-MoProperty $cdp 'SystemName' ''), [string](Get-MoProperty $cdp 'DevId' ''))) {
                            if ([string]::IsNullOrWhiteSpace($value)) { continue }
                            $trimmed = $value.Trim()
                            if ($seen.Contains($trimmed)) { continue }
                            [void]$seen.Add($trimmed)
                            [void]$found.Add([pscustomobject]@{
                                HostName = $hostName; Vmnic = $pnic.Device
                                SystemName = $trimmed; Source = 'CDP'
                            })
                        }
                    }

                    $lldp = Get-MoProperty $hint 'LldpInfo' $null
                    if ($null -ne $lldp) {
                        $value = Get-LldpSystemName -LldpInfo $lldp
                        if (-not [string]::IsNullOrWhiteSpace($value) -and -not $seen.Contains($value)) {
                            [void]$seen.Add($value)
                            [void]$found.Add([pscustomobject]@{
                                HostName = $hostName; Vmnic = $pnic.Device
                                SystemName = $value; Source = 'LLDP'
                            })
                        }
                    }
                }
            }
            catch {
                Write-Log "QueryNetworkHint failed for $hostName/$($pnic.Device): $($_.Exception.Message)" -Level DEBUG
            }
        }
    }
    catch {
        Write-Log "Could not read CDP/LLDP for ${hostName}: $($_.Exception.Message)" -Level WARN
    }

    $rows = $found.ToArray()
    $front = @($rows | Where-Object { $_.Vmnic -in @('vmnic0', 'vmnic1', 'vmnic2', 'vmnic3') })
    $rest = @($rows | Where-Object { $_.Vmnic -notin @('vmnic0', 'vmnic1', 'vmnic2', 'vmnic3') })
    $ordered = @($front) + @($rest)

    $script:DiscoveryCache[$hostName] = $ordered
    return @($ordered)
}

function Get-UcsTargetForHost {
    <#
    .SYNOPSIS
        The UCS Manager address in front of a host, from its CDP/LLDP neighbours.

    .DESCRIPTION
        Every neighbour name the host reports is normalised to a UCS Manager
        cluster name and the distinct results returned, most likely first. More
        than one is possible and not an error - a host reporting a CDP DevId and
        an LLDP system name that differ gives two candidates, and only trying
        them settles which answers.

    .PARAMETER VMHostObject
        The host.

    .EXAMPLE
        Get-UcsTargetForHost -VMHostObject $esx
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        $VMHostObject
    )

    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(Get-EsxiDiscoveryCandidate -VMHostObject $VMHostObject)) {
        $target = Convert-FiSystemNameToUcsCandidate -SystemName $candidate.SystemName
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        if (-not $targets.Contains($target)) { [void]$targets.Add($target) }
    }
    return $targets.ToArray()
}

# ============================================================================
# UCS Manager sign-in, with the vCenter credential passed through
# ============================================================================

function Get-UcsRunCredential {
    <#
    .SYNOPSIS
        The credential to send to UCS Manager.

    .DESCRIPTION
        The run's credential, typed once and used for UCS Manager and vCenter
        both, unless -UcsCredential named a different one. Asked for again only
        if there is none held - which happens when a first attempt was rejected
        and discarded.

        The account name is logged every time it is used, so which account was
        sent where is visible when something 401s. The safety is not a prompt,
        it is what happens on failure: Register-UcsCredentialResult discards it,
        counts the attempt, and stops trying at -MaxCredentialAttempt rather than
        sending the same wrong password until the account locks.

    .EXAMPLE
        $cred = Get-UcsRunCredential
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param()

    if ($script:UcsCredentialBlocked) { return $null }

    if ($null -ne $script:UcsCredentialCache) {
        Write-Log "UCS Manager: using '$($script:UcsCredentialCache.UserName)'." -Level DEBUG
        return $script:UcsCredentialCache
    }

    Write-Log 'UCS Manager: no usable credential held; asking for one.' -Level INFO
    $resolved = $null
    try { $resolved = Get-Credential -Message 'Credentials for UCS Manager' } catch { $resolved = $null }
    if ($null -eq $resolved -or [string]::IsNullOrWhiteSpace($resolved.GetNetworkCredential().Password)) { return $null }
    $script:UcsCredentialCache = $resolved
    return $resolved
}

function Register-UcsCredentialResult {
    <#
    .SYNOPSIS
        Records whether a UCS sign-in worked, and stops replaying one that does not.

    .DESCRIPTION
        LOCKOUT IS THE THING THIS EXISTS TO PREVENT. A wrong password replayed at
        every domain in turn is how an account gets locked, and this script walks
        every domain a cluster touches.

        So a failure that looks like authentication - as opposed to a name that
        does not resolve or a port that is closed - discards the held credential,
        stops the vCenter one being offered to UCS again, and counts against
        -MaxCredentialAttempt. At the limit UCS is given up on for the rest of the
        run and nothing further is sent.

    .PARAMETER Succeeded
        Whether the sign-in worked.

    .PARAMETER Message
        The failure message, used to tell an auth failure from a network one.

    .EXAMPLE
        Register-UcsCredentialResult -Succeeded $false -Message $_.Exception.Message
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [string]$Message = ''
    )

    if ($Succeeded) {
        $script:UcsCredentialAttempt = 0
        return
    }

    # A name that does not resolve or a blocked port says nothing about the
    # password, and counting it would block UCS over a firewall rule.
    if ($Message -notmatch '(?i)auth|credential|password|denied|unauthori[sz]ed|login|401') { return }

    $script:UcsCredentialCache = $null
    $script:UcsCredentialAttempt++

    if ($script:UcsCredentialAttempt -ge $MaxCredentialAttempt) {
        $script:UcsCredentialBlocked = $true
        # WARN, not ERROR. The run continues past a domain it cannot sign in to -
        # abandoning every other domain over one domain's bad password helps
        # nobody - and the domains it could not check become findings of their own.
        Write-Log "UCS Manager sign-in has failed $($script:UcsCredentialAttempt) time(s). No further UCS login will be attempted this run, to avoid locking the account." -Level WARN
        return
    }

    Write-Log "The held UCS credential has been discarded - attempt $($script:UcsCredentialAttempt) of $MaxCredentialAttempt." -Level WARN
}

function Connect-UcsForTarget {
    <#
    .SYNOPSIS
        A UCS Manager session for one domain, reusing one already open.

    .DESCRIPTION
        Sessions are cached per target because a cluster's hosts all point at the
        same handful of domains and each sign-in is a round trip plus an audit
        entry.

        Connect-Ucs is tried as -Name first and positionally second: PowerTool
        builds differ over which binds reliably, and the positional form is what
        works by hand.

    .PARAMETER Target
        UCS Manager address.

    .EXAMPLE
        $session = Connect-UcsForTarget -Target ucsm01.example.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    $clean = Remove-UcsTargetDecoration -Value $Target
    if ($script:UcsSessions.ContainsKey($clean)) { return $script:UcsSessions[$clean] }

    if ($script:UcsCredentialBlocked) {
        Write-Log "Skipping UCS Manager '$clean' - UCS sign-in is blocked for this run." -Level WARN
        return $null
    }

    $credential = Get-UcsRunCredential
    if ($null -eq $credential) {
        Write-Log "No credential available for UCS Manager '$clean'." -Level WARN
        return $null
    }

    Write-Log "Connecting to UCS Manager '$clean' as '$($credential.UserName)'." -Level INFO
    $session = $null
    try {
        $session = Connect-Ucs -Name $clean -Credential $credential -ErrorAction Stop
    }
    catch {
        try {
            $session = Connect-Ucs $clean -Credential $credential -ErrorAction Stop
        }
        catch {
            $failure = $_.Exception.Message
            Write-Log "UCS Manager '$clean' sign-in failed: $failure" -Level WARN
            Register-UcsCredentialResult -Succeeded $false -Message $failure
            return $null
        }
    }

    Register-UcsCredentialResult -Succeeded $true
    $script:UcsSessions[$clean] = $session
    Write-Log "Connected to UCS Manager '$clean'." -Level INFO
    return $session
}

function Get-UcsInventory {
    <#
    .SYNOPSIS
        One class of managed object from a UCS domain, whichever way this
        PowerTool build exposes it.

    .DESCRIPTION
        The typed cmdlets are preferred - they are what the rest of the estate's
        scripts use - but their names and parameter sets have moved between
        PowerTool releases. Get-UcsManagedObject -ClassId is the stable route and
        answers for every class, so it is the fallback rather than the first
        choice: same objects, no dependency on a cmdlet existing.

    .PARAMETER Session
        The UCS handle.

    .PARAMETER Cmdlet
        Preferred typed cmdlet, e.g. Get-UcsVnicTemplate.

    .PARAMETER ClassId
        Managed object class to fall back to, e.g. vnicLanConnTempl.

    .EXAMPLE
        Get-UcsInventory -Session $s -Cmdlet Get-UcsVlan -ClassId fabricVlan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        $Session,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Cmdlet,

        [Parameter(Mandatory, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string]$ClassId
    )

    if (Get-Command -Name $Cmdlet -ErrorAction SilentlyContinue) {
        try { return @(& $Cmdlet -Ucs $Session -ErrorAction Stop) }
        catch { Write-Log "$Cmdlet failed ($($_.Exception.Message)); falling back to class $ClassId." -Level DEBUG }
    }

    try { return @(Get-UcsManagedObject -Ucs $Session -ClassId $ClassId -ErrorAction Stop) }
    catch {
        Write-Log "Could not read $ClassId from UCS: $($_.Exception.Message)" -Level WARN
        return @()
    }
}

function Get-ParentDn {
    <#
    .SYNOPSIS
        A managed object's parent Dn - everything before the last '/'.

    .PARAMETER Dn
        The object's distinguished name.

    .EXAMPLE
        Get-ParentDn -Dn 'org-root/lan-conn-templ-eth0/if-VL250'   # 'org-root/lan-conn-templ-eth0'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Dn
    )

    $index = $Dn.LastIndexOf('/')
    if ($index -lt 1) { return '' }
    return $Dn.Substring(0, $index)
}

function ConvertTo-PolicyName {
    <#
    .SYNOPSIS
        A policy's bare name, whether it arrives as a name or as a distinguished name.

    .DESCRIPTION
        UCS exposes the same policy reference twice: NwCtrlPolicyName is the
        plain name a human typed, OperNwCtrlPolicyName is the resolved Dn
        ('org-root/nwctrl-CDP-ON'). Comparing one leg's name against the other
        leg's Dn reports a mismatch on two vNICs that are configured identically,
        so both forms are reduced to the name before anything is compared.

    .PARAMETER Value
        The name or Dn.

    .PARAMETER Prefix
        The Dn segment prefix to strip, e.g. 'nwctrl-'.

    .EXAMPLE
        ConvertTo-PolicyName -Value 'org-root/nwctrl-CDP-ON' -Prefix 'nwctrl-'   # 'CDP-ON'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string]$Prefix = ''
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $leaf = ($Value.Trim() -split '/')[-1]
    if ($Prefix -and $leaf.StartsWith($Prefix)) { $leaf = $leaf.Substring($Prefix.Length) }
    return $leaf
}

function Get-VnicMemberDetail {
    <#
    .SYNOPSIS
        One vNIC resolved into the flat view the comparisons work on.

    .DESCRIPTION
        The comparisons need one settled answer per attribute, and UCS offers
        several for each: a value on the vNIC, a value on the template behind it,
        and an Oper* form of both. Resolving that here means Compare-VnicGroup
        stays pure and the resolution rules live in one place.

        VLANs come from the vNIC's own interface rows first. Those are the
        operational truth - what this blade is actually trunked - where the
        template is only what it was meant to inherit. The template's rows are
        the fallback, and where both exist and disagree the difference is
        returned as TemplateDriftIds: an initial-template that has been edited
        since the profile was stamped looks correct in the template and is not
        correct on the blade.

    .PARAMETER Ordinal
        The vNIC's ordinal, as Get-VnicOrdinalMap derived it.

    .PARAMETER Vnic
        The vnicEther object below the service profile.

    .PARAMETER TemplateByName
        Hashtable of vNIC template name to template object.

    .PARAMETER InterfaceIndex
        Hashtable of parent Dn to vnicEtherIf rows.

    .PARAMETER VlanIdByName
        Hashtable of VLAN name to id, for rows carrying no Vnet.

    .EXAMPLE
        Get-VnicMemberDetail -Ordinal 0 -Vnic $vnic -TemplateByName $t -InterfaceIndex $i -VlanIdByName $v
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [int]$Ordinal,

        [Parameter(Mandatory, Position = 1)]
        $Vnic,

        [Parameter(Mandatory, Position = 2)]
        [hashtable]$TemplateByName,

        [Parameter(Mandatory, Position = 3)]
        [hashtable]$InterfaceIndex,

        [Parameter(Position = 4)]
        [hashtable]$VlanIdByName = @{}
    )

    $vnicDn = [string](Get-MoProperty $Vnic 'Dn' '')
    $vnicName = [string](Get-MoProperty $Vnic 'Name' '')

    $templateName = [string](Get-MoProperty $Vnic 'NwTemplName' '')
    if (-not $templateName) {
        $templateName = ConvertTo-PolicyName -Value ([string](Get-MoProperty $Vnic 'OperNwTemplName' '')) -Prefix 'lan-conn-templ-'
    }

    $template = $null
    if ($templateName -and $TemplateByName.ContainsKey($templateName)) { $template = $TemplateByName[$templateName] }

    $operSummary = Get-VlanSummary -ParentDn $vnicDn -InterfaceIndex $InterfaceIndex -VlanIdByName $VlanIdByName
    $templateSummary = $null
    if ($null -ne $template) {
        $templateSummary = Get-VlanSummary -ParentDn ([string](Get-MoProperty $template 'Dn' '')) -InterfaceIndex $InterfaceIndex -VlanIdByName $VlanIdByName
    }

    # A flag, not a comparison of the two objects: -eq on two PSCustomObjects
    # does not mean "is the same object" and the drift check below depends on
    # knowing which one was taken.
    $usedOperational = $true
    $effective = $operSummary
    if ($operSummary.Count -eq 0 -and @($operSummary.Unresolved).Count -eq 0 -and $null -ne $templateSummary) {
        $effective = $templateSummary
        $usedOperational = $false
    }

    # BOTH sides must actually carry VLANs before a difference means anything.
    # A template with no interface rows read is indistinguishable from a template
    # with no VLANs, and treating it as the latter reports every vNIC in the
    # domain as drifted - which is how a report stops being read. A template that
    # genuinely has VLANs the vNIC does not is caught by the pair comparison and
    # by the vDS cross-check anyway.
    $drift = @()
    if ($usedOperational -and $null -ne $templateSummary -and $operSummary.Count -gt 0 -and $templateSummary.Count -gt 0) {
        $difference = @(Compare-Object -ReferenceObject @($templateSummary.VlanIds) -DifferenceObject @($operSummary.VlanIds) -ErrorAction SilentlyContinue)
        $drift = @($difference | ForEach-Object { [int]$_.InputObject } | Sort-Object -Unique)
    }

    # Values from the vNIC win; the template answers where the vNIC is silent.
    $mtu = [int](Get-MoProperty $Vnic 'Mtu' 0)
    if ($mtu -le 0) { $mtu = [int](Get-MoProperty $template 'Mtu' 0) }

    $switchId = [string](Get-MoProperty $Vnic 'SwitchId' '')
    if (-not $switchId) { $switchId = [string](Get-MoProperty $template 'SwitchId' '') }

    $controlPolicy = [string](Get-MoProperty $Vnic 'NwCtrlPolicyName' '')
    if (-not $controlPolicy) { $controlPolicy = [string](Get-MoProperty $template 'NwCtrlPolicyName' '') }
    if (-not $controlPolicy) { $controlPolicy = ConvertTo-PolicyName -Value ([string](Get-MoProperty $Vnic 'OperNwCtrlPolicyName' '')) -Prefix 'nwctrl-' }

    $qosPolicy = [string](Get-MoProperty $Vnic 'QosPolicyName' '')
    if (-not $qosPolicy) { $qosPolicy = [string](Get-MoProperty $template 'QosPolicyName' '') }
    if (-not $qosPolicy) { $qosPolicy = ConvertTo-PolicyName -Value ([string](Get-MoProperty $Vnic 'OperQosPolicyName' '')) -Prefix 'ep-qos-' }

    $adapterPolicy = [string](Get-MoProperty $Vnic 'AdaptorProfileName' '')
    if (-not $adapterPolicy) { $adapterPolicy = [string](Get-MoProperty $template 'AdaptorProfileName' '') }
    if (-not $adapterPolicy) { $adapterPolicy = ConvertTo-PolicyName -Value ([string](Get-MoProperty $Vnic 'OperAdaptorProfileName' '')) -Prefix 'eth-profile-' }

    return [pscustomobject]@{
        Ordinal              = $Ordinal
        VnicName             = $vnicName
        VnicDn               = $vnicDn
        TemplateName         = $templateName
        TemplateType         = [string](Get-MoProperty $template 'TemplType' 'none')
        SwitchId             = $switchId
        Mtu                  = $mtu
        VlanIds              = @($effective.VlanIds)
        VlanNames            = @($effective.VlanNames)
        Unresolved           = @($effective.Unresolved)
        NativeId             = [int]$effective.NativeId
        NativeName           = [string]$effective.NativeName
        NativeIds            = @($effective.NativeIds)
        NativeNames          = @($effective.NativeNames)
        NativeCount          = [int]$effective.NativeCount
        NetworkControlPolicy = $controlPolicy
        QosPolicy            = $qosPolicy
        AdapterPolicy        = $adapterPolicy
        TemplateVlanIds      = if ($null -ne $templateSummary) { @($templateSummary.VlanIds) } else { @() }
        TemplateDriftIds     = $drift
    }
}

# ============================================================================
# Main
# ============================================================================

$transcriptPath = $null
if ($Transcript) {
    $transcriptPath = Join-Path (Get-Location).Path ('Test-UcsVnicVlanConsistency-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    Start-Transcript -Path $transcriptPath | Out-Null
}

try {
    $pairGroups = ConvertTo-OrdinalGroup -Group $VnicPairGroup
    Write-Log ("Comparing vNIC groups: {0}." -f (@($pairGroups | ForEach-Object { '[' + ($_ -join '/') + ']' }) -join ' ')) -Level INFO

    # By CMDLET, not by module name. PowerCLI has been split and renamed across
    # releases and the UCS PowerTool ships under more than one module name, so a
    # name check fails on hosts where the cmdlets are right there. This also
    # avoids enumerating the module path, which on a host with PowerCLI installed
    # is slow enough to look like a hang.
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($requirement in @(
        [pscustomobject]@{ Cmdlet = 'Connect-VIServer'; From = 'VMware PowerCLI (Install-Module VMware.PowerCLI)' }
        [pscustomobject]@{ Cmdlet = 'Get-VMHost';       From = 'VMware PowerCLI (Install-Module VMware.PowerCLI)' }
        [pscustomobject]@{ Cmdlet = 'Get-VDSwitch';     From = 'VMware PowerCLI (Install-Module VMware.PowerCLI)' }
        [pscustomobject]@{ Cmdlet = 'Connect-Ucs';      From = 'Cisco UCS PowerTool (Install-Module Cisco.UCSManager)' }
    )) {
        if (-not (Get-Command -Name $requirement.Cmdlet -ErrorAction SilentlyContinue)) {
            [void]$missing.Add(('{0} - from {1}' -f $requirement.Cmdlet, $requirement.From))
        }
    }
    if ($missing.Count -gt 0) {
        throw ("This script needs cmdlets that are not available in this session:`n  " + ($missing.ToArray() -join "`n  "))
    }

    # ---- One credential, asked for once ------------------------------------
    # In these estates the same domain account signs in to both, so it is typed
    # once and used for both. -UcsCredential or -VICredential override it for
    # one side where they differ. Nothing is stored and nothing outlives the run.
    $runCredential = $Credential
    if ($null -eq $runCredential -and ($null -eq $UcsCredential -or $null -eq $VICredential)) {
        $runCredential = Get-Credential -Message "Credentials for UCS Manager '$UcsManager' and vCenter '$VIServer'"
    }
    if ($null -ne $UcsCredential) { $script:UcsCredentialCache = $UcsCredential }
    elseif ($null -ne $runCredential) { $script:UcsCredentialCache = $runCredential }

    $viCredential = $VICredential
    if ($null -eq $viCredential) { $viCredential = $runCredential }
    if ($null -eq $viCredential) { throw "No credential available for vCenter '$VIServer'." }
    if ($null -eq $script:UcsCredentialCache) { throw "No credential available for UCS Manager '$UcsManager'." }

    # ---- UCS Manager first -------------------------------------------------
    # THIS IS THE PIVOT. The service profiles are the inventory: they name the
    # blades that exist, and each one carries the vNICs to be checked. Starting
    # at vCenter instead means starting from whatever happens to be registered
    # there, which answers a different question - and quietly skips a blade whose
    # host is disconnected or was never added.
    $target = Remove-UcsTargetDecoration -Value $UcsManager
    $session = Connect-UcsForTarget -Target $target
    if ($null -eq $session) { throw "Could not sign in to UCS Manager '$target'. Nothing was checked." }

    Write-Log "Reading the VLAN and vNIC configuration of '$target'." -Level INFO
    $vlans = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsVlan' -ClassId 'fabricVlan')
    $vsans = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsVsan' -ClassId 'fabricVsan')
    $templates = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsVnicTemplate' -ClassId 'vnicLanConnTempl')
    $vnics = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsVnic' -ClassId 'vnicEther')
    $interfaces = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsVnicInterface' -ClassId 'vnicEtherIf')
    $controlPolicies = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsNetworkControlPolicy' -ClassId 'nwctrlDefinition')
    $profiles = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsServiceProfile' -ClassId 'lsServer')
    $qosPolicies = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsQosPolicy' -ClassId 'epqosDefinition')
    $qosEgress = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsVnicEgressPolicy' -ClassId 'epqosEgress')
    $qosClasses = @(Get-UcsInventory -Session $session -Cmdlet 'Get-UcsQosClass' -ClassId 'fabricQosClass')

    # ---- Indexes -----------------------------------------------------------
    $vlanIdByName = @{}
    foreach ($vlan in $vlans) {
        $name = [string](Get-MoProperty $vlan 'Name' '')
        $id = [int](Get-MoProperty $vlan 'Id' 0)
        if ($name -and $id -gt 0 -and -not $vlanIdByName.ContainsKey($name)) { $vlanIdByName[$name] = $id }
    }

    $interfaceIndex = @{}
    foreach ($interface in $interfaces) {
        $parent = Get-ParentDn -Dn ([string](Get-MoProperty $interface 'Dn' ''))
        if (-not $parent) { continue }
        if (-not $interfaceIndex.ContainsKey($parent)) { $interfaceIndex[$parent] = New-Object System.Collections.Generic.List[object] }
        [void]$interfaceIndex[$parent].Add($interface)
    }

    $templateByName = @{}
    $templateDn = @{}
    foreach ($template in $templates) {
        $name = [string](Get-MoProperty $template 'Name' '')
        if ($name -and -not $templateByName.ContainsKey($name)) { $templateByName[$name] = $template }
        $dn = [string](Get-MoProperty $template 'Dn' '')
        if ($dn) { $templateDn[$dn] = $true }
    }

    # Every VLAN name reached from a template, and every one reached only from a
    # service profile's own vNIC. The parent Dn of an interface row separates
    # them - templates and vNICs hold their VLANs the same way.
    $vlanOnTemplate = New-Object System.Collections.Generic.List[string]
    $vlanOnVnic = New-Object System.Collections.Generic.List[string]
    foreach ($interface in $interfaces) {
        $name = [string](Get-MoProperty $interface 'Name' '')
        if (-not $name) { continue }
        $parent = Get-ParentDn -Dn ([string](Get-MoProperty $interface 'Dn' ''))
        if ($templateDn.ContainsKey($parent)) {
            if (-not $vlanOnTemplate.Contains($name)) { [void]$vlanOnTemplate.Add($name) }
        }
        elseif (-not $vlanOnVnic.Contains($name)) { [void]$vlanOnVnic.Add($name) }
    }

    $controlPolicyByName = @{}
    foreach ($policy in $controlPolicies) {
        $name = [string](Get-MoProperty $policy 'Name' '')
        if ($name -and -not $controlPolicyByName.ContainsKey($name)) { $controlPolicyByName[$name] = $policy }
    }

    $vnicsByProfile = @{}
    foreach ($vnic in $vnics) {
        $parent = Get-ParentDn -Dn ([string](Get-MoProperty $vnic 'Dn' ''))
        if (-not $parent) { continue }
        if (-not $vnicsByProfile.ContainsKey($parent)) { $vnicsByProfile[$parent] = New-Object System.Collections.Generic.List[object] }
        [void]$vnicsByProfile[$parent].Add($vnic)
    }

    $qosClassMtu = Get-QosClassMtu -Policy $qosPolicies -Egress $qosEgress -QosClass $qosClasses

    Write-Log ("'{0}': {1} VLAN(s), {2} vNIC template(s), {3} service profile(s)." -f $target, $vlans.Count, $templates.Count, $profiles.Count) -Level INFO

    # ---- Domain-wide checks ------------------------------------------------
    Add-CheckResult -Finding @(Test-UcsVlanInventory -Vlan $vlans -Vsan $vsans) `
        -Scope 'UCS' -Domain $target -Check 'VlanDefinitions' -Subject "$target VLAN table" `
        -Detail ("All {0} VLAN definitions in this domain are unique by id and by name, inside the usable range, and none collide with a VSAN's FCoE VLAN." -f $vlans.Count)

    Add-CheckResult -Finding @(Test-UcsVlanAssignment -Vlan $vlans -TemplateVlanName $vlanOnTemplate.ToArray() `
                -ProfileVlanName $vlanOnVnic.ToArray() -MaxIndividual $MaxUnassignedVlanDetail) `
        -Scope 'UCS' -Domain $target -Check 'VlanAssignment' -Subject "$target vNIC templates" `
        -Detail ("Every VLAN defined on this fabric is carried by at least one vNIC template - {0} VLAN(s) across {1} template(s)." -f $vlanOnTemplate.Count, $templates.Count)

    if (-not $SkipBestPractice) {
        foreach ($policy in $controlPolicies) {
            Add-CheckResult -Finding @(Test-NetworkControlPolicyBestPractice -Policy $policy) `
                -Scope 'UCS' -Domain $target -Category 'BestPractice' -Check 'NetworkControlPolicy' `
                -Subject ([string](Get-MoProperty $policy 'Name' '')) `
                -Detail ("Network control policy '{0}' drops the link on uplink failure, registers MACs on all host VLANs, and advertises a discovery protocol." -f (Get-MoProperty $policy 'Name' ''))
        }
    }

    # ---- The blades, from the service profiles ------------------------------
    $associated = @($profiles | Where-Object { [string](Get-MoProperty $_ 'AssocState' '') -ne 'unassociated' })
    if ($ServiceProfile) {
        $associated = @($associated | Where-Object {
            $candidate = [string](Get-MoProperty $_ 'Name' '')
            [bool](@($ServiceProfile | Where-Object { $candidate -like $_ }).Count)
        })
    }

    foreach ($idle in @($profiles | Where-Object { [string](Get-MoProperty $_ 'AssocState' '') -eq 'unassociated' })) {
        Add-Finding -Severity 'INFO' -Scope 'UCS' -Check 'ProfileUnassociated' -Domain $target `
            -Subject ([string](Get-MoProperty $idle 'Name' '')) -Expected '' -Actual 'not associated with a blade' `
            -Detail ("Service profile '{0}' is not associated with a blade, so there is no host to check it against. Its vNICs were not compared." -f (Get-MoProperty $idle 'Name' ''))
    }

    if ($associated.Count -eq 0) { throw "No associated service profiles in '$target' matched the filter. Nothing to check." }
    Write-Log "$($associated.Count) associated service profile(s) to check." -Level INFO

    # ---- vCenter ------------------------------------------------------------
    Write-Log "Connecting to vCenter '$VIServer' as '$($viCredential.UserName)'." -Level INFO
    $viConnection = Connect-VIServer -Server $VIServer -Credential $viCredential -ErrorAction Stop
    Write-Log "Connected to vCenter '$($viConnection.Name)'." -Level INFO

    $vdsByName = @{}
    $portGroupsByVds = @{}
    foreach ($vds in @(Get-VDSwitch -ErrorAction SilentlyContinue)) { $vdsByName[[string]$vds.Name] = $vds }
    Write-Log "$($vdsByName.Count) distributed switch(es) visible in this vCenter." -Level DEBUG

    # Every host in the vCenter, indexed the two ways a service profile can be
    # matched to one. The UUID index is the authoritative one: UCS writes the
    # profile's UUID into the blade's SMBIOS and ESXi reports it back, so a hit
    # there is proof rather than a naming convention.
    $allHosts = @(Get-VMHost)
    $hostByUuid = @{}
    $hostByShortName = @{}
    $hostViewByName = @{}
    foreach ($esx in $allHosts) {
        $shortName = ([string]$esx.Name).Split('.')[0].ToLowerInvariant()
        if (-not $hostByShortName.ContainsKey($shortName)) { $hostByShortName[$shortName] = $esx }
        try {
            $view = Get-View -Id $esx.Id -ErrorAction Stop
            $hostViewByName[[string]$esx.Name] = $view
            $uuid = [string](Get-MoProperty (Get-MoProperty (Get-MoProperty $view 'Hardware' $null) 'SystemInfo' $null) 'Uuid' '')
            if ($uuid -and -not $hostByUuid.ContainsKey($uuid)) { $hostByUuid[$uuid] = $esx }
        }
        catch {
            Write-Log "Could not read the host view for $($esx.Name): $($_.Exception.Message)" -Level WARN
        }
    }
    Write-Log "$($allHosts.Count) host(s) registered in this vCenter." -Level DEBUG

    $matchedHostName = @{}

    # ---- Per service profile ------------------------------------------------
    foreach ($profileMo in @($associated | Sort-Object { [string](Get-MoProperty $_ 'Name' '') })) {
        $profileName = [string](Get-MoProperty $profileMo 'Name' '')
        $profileDn = [string](Get-MoProperty $profileMo 'Dn' '')
        $profileUuid = [string](Get-MoProperty $profileMo 'Uuid' '')

        if (-not $SkipBestPractice) {
            Add-CheckResult -Finding @(Test-ServiceProfileBestPractice -ServiceProfile $profileMo) `
                -Scope 'UCS' -Domain $target -Category 'BestPractice' -Check 'ServiceProfileSource' -Subject $profileName `
                -Detail ("Service profile '{0}' comes from a service profile template, so its vNICs and policies are held to its peers'." -f $profileName)
        }

        # --- which host is this blade? ---------------------------------------
        $esx = $null
        $matchedBy = ''
        if ($profileUuid -and $hostByUuid.ContainsKey($profileUuid)) {
            $esx = $hostByUuid[$profileUuid]
            $matchedBy = 'hardware UUID'
        }
        else {
            foreach ($candidate in @($profileName, ($profileName + $HostDomainSuffix))) {
                $shortName = ([string]$candidate).Split('.')[0].ToLowerInvariant()
                if ($shortName -and $hostByShortName.ContainsKey($shortName)) {
                    $esx = $hostByShortName[$shortName]
                    $matchedBy = 'name'
                    break
                }
            }
        }

        if ($null -eq $esx) {
            Add-Finding -Severity 'WARN' -Scope 'CrossCheck' -Check 'ProfileHasNoHost' -Domain $target `
                -Subject $profileName -Expected "a host in '$($viConnection.Name)'" -Actual 'no match by UUID or name' `
                -Detail ("Service profile '{0}' is associated with a blade, but no host in '{1}' matches it by hardware UUID or by name. Either the blade runs something other than ESXi, its host is registered in a different vCenter, or it was never added." -f $profileName, $viConnection.Name)
            continue
        }

        $hostName = [string]$esx.Name
        $matchedHostName[$hostName] = $true
        Write-Log ("{0} -> {1}, matched by {2}." -f $profileName, $hostName, $matchedBy) -Level DEBUG

        if ([string]$esx.ConnectionState -notin @('Connected', 'Maintenance')) {
            Add-Finding -Severity 'WARN' -Scope 'vCenter' -Check 'HostNotConnected' -Domain $target -HostName $hostName `
                -Subject $hostName -Expected 'a connected host' -Actual ([string]$esx.ConnectionState) `
                -Detail ("{0} is {1} in vCenter, so its vDS and port group configuration could not be read. The UCS side was still checked." -f $hostName, $esx.ConnectionState)
        }

        $hostView = $null
        if ($hostViewByName.ContainsKey($hostName)) { $hostView = $hostViewByName[$hostName] }

        # A name match is a convention, not proof. CDP and LLDP say which fabric
        # the blade is actually cabled to, so a name-matched host is verified
        # against the domain being checked before its vNICs are compared to it.
        # A UUID match needs no such confirmation - it already is the proof.
        if ($matchedBy -eq 'name') {
            $neighbours = @(Get-UcsTargetForHost -VMHostObject $esx)
            if ($neighbours.Count -eq 0) {
                Add-Finding -Severity 'INFO' -Scope 'CrossCheck' -Check 'HostDomainUnverified' -Domain $target -HostName $hostName `
                    -Subject $hostName -Expected "confirmation that $hostName is behind '$target'" -Actual 'no CDP or LLDP neighbour' `
                    -Detail ("{0} was matched to service profile '{1}' by name alone and reports no CDP or LLDP neighbour, so it could not be confirmed as a blade of '{2}'." -f $hostName, $profileName, $target)
            }
            elseif ($neighbours -notcontains $target) {
                Add-Finding -Severity 'ERROR' -Scope 'CrossCheck' -Check 'HostInDifferentDomain' -Domain $target -HostName $hostName `
                    -Subject $hostName -Expected $target -Actual ($neighbours -join ', ') `
                    -Detail ("{0} was matched to service profile '{1}' by name, but its CDP/LLDP neighbour is {2}, not '{3}'. Two domains have a profile and a host of the same name, and the findings for this host would be against the wrong fabric - so it was skipped." -f $hostName, $profileName, ($neighbours -join ', '), $target)
                continue
            }
        }

        # --- the vNICs --------------------------------------------------------
        $profileVnics = @()
        if ($vnicsByProfile.ContainsKey($profileDn)) { $profileVnics = @($vnicsByProfile[$profileDn].ToArray()) }

        if ($profileVnics.Count -eq 0) {
            Add-Finding -Severity 'WARN' -Scope 'UCS' -Check 'NoVnics' -Domain $target -HostName $hostName `
                -Subject $profileName -Expected 'vNICs on the service profile' -Actual 'none' `
                -Detail "Service profile '$profileName' in '$target' has no vNICs."
            continue
        }

        $ordinalMap = Get-VnicOrdinalMap -Vnic $profileVnics
        Write-Log ("{0}: {1} vNIC(s), ordinals derived from {2}." -f $profileName, $profileVnics.Count, $ordinalMap.Source) -Level DEBUG

        if ($ordinalMap.Source -eq 'order') {
            Add-Finding -Severity 'INFO' -Scope 'UCS' -Check 'VnicOrdinalDerived' -Domain $target -HostName $hostName `
                -Subject $profileName -Expected 'vNIC names ending in their ordinal' -Actual 'ordinals taken from the UCS order field' `
                -Detail "The vNICs on '$profileName' are not named with distinct trailing numbers, so their ordinals were derived from the UCS order field. Confirm the pairing before acting on the findings for this profile."
        }

        $memberByOrdinal = @{}
        foreach ($ordinal in @($ordinalMap.Map.Keys)) {
            $memberByOrdinal[$ordinal] = Get-VnicMemberDetail -Ordinal $ordinal -Vnic $ordinalMap.Map[$ordinal] `
                -TemplateByName $templateByName -InterfaceIndex $interfaceIndex -VlanIdByName $vlanIdByName
        }

        foreach ($member in @($memberByOrdinal.Values | Sort-Object Ordinal)) {
            if (@($member.Unresolved).Count -gt 0) {
                Add-Finding -Severity 'ERROR' -Scope 'UCS' -Check 'VlanNotDefined' -Domain $target -HostName $hostName `
                    -Subject $member.VnicName -Expected 'every VLAN on the vNIC defined in this domain' -Actual (@($member.Unresolved) -join ', ') `
                    -Detail "$($member.VnicName) references VLAN(s) $((@($member.Unresolved)) -join ', ') that resolve to no id in '$target'."
            }
            if (@($member.TemplateDriftIds).Count -gt 0) {
                Add-Finding -Severity 'WARN' -Scope 'UCS' -Check 'VnicDivergedFromTemplate' -Domain $target -HostName $hostName `
                    -Subject $member.VnicName -Expected ('the VLANs of template ''{0}'': {1}' -f $member.TemplateName, (Format-IdList -Id @($member.TemplateVlanIds))) `
                    -Actual (Format-IdList -Id @($member.VlanIds)) `
                    -Detail "$($member.VnicName) does not carry the same VLANs as its template '$($member.TemplateName)' - they differ by $(Format-IdList -Id @($member.TemplateDriftIds)). An initial-template edited after the profile was stamped shows the change in UCS Manager without applying it to the blade."
            }
            # Always run, best practice or not: two natives is a misconfiguration
            # whatever the design, and only the missing-native finding is the
            # part that rests on this estate's own convention.
            Add-CheckResult -Finding @(Test-VnicNativeVlan -Member $member -RequireNative (-not $SkipBestPractice)) `
                -Scope 'UCS' -Domain $target -HostName $hostName -Check 'VnicNativeVlan' -Subject $member.VnicName `
                -Detail ("{0} trunks {1} VLAN(s) ({2}) with exactly one of them native - {3}." -f $member.VnicName, @($member.VlanIds).Count, (Format-IdList -Id @($member.VlanIds)), $(if ($member.NativeName) { "$($member.NativeName) ($($member.NativeId))" } else { 'none set' }))

            if (-not $SkipBestPractice) {
                Add-CheckResult -Finding @(Test-VnicBestPractice -Member $member -QosClassMtu $qosClassMtu) `
                    -Scope 'UCS' -Domain $target -HostName $hostName -Category 'BestPractice' -Check 'VnicSettings' -Subject $member.VnicName `
                    -Detail ("{0} has fabric failover off, comes from an updating template, and its MTU {1} fits the QoS class it maps to." -f $member.VnicName, $member.Mtu)
            }
        }

        foreach ($group in $pairGroups) {
            $members = @($group | Where-Object { $memberByOrdinal.ContainsKey($_) } | ForEach-Object { $memberByOrdinal[$_] })
            if ($members.Count -eq 0) { continue }
            $label = (@($members | ForEach-Object { $_.VnicName }) -join '/')
            Add-CheckResult -Finding @(Compare-VnicGroup -Member $members -ExpectedMtu $ExpectedMtu) `
                -Scope 'UCS' -Domain $target -HostName $hostName -Check 'VnicPair' -Subject $label `
                -Detail ("{0} match on VLANs ({1}), native VLAN, MTU {2} and their network control, QoS and adapter policies, and sit on separate fabric interconnects." -f $label, (Format-IdList -Id @($members[0].VlanIds)), $members[0].Mtu)
        }

        # --- the vSphere cross-check ------------------------------------------
        $uplinkMap = Get-HostUplinkMap -HostView $hostView
        if ($uplinkMap.Count -eq 0) {
            Add-Finding -Severity 'INFO' -Scope 'CrossCheck' -Check 'NoDistributedSwitch' -Domain $target -HostName $hostName `
                -Subject $hostName -Expected '' -Actual 'no distributed switch uplinks' `
                -Detail ("{0} has no distributed switch uplinks, so its UCS VLANs could not be cross-checked against vCenter. Standard switches are not read by this script." -f $hostName)
            continue
        }

        foreach ($vdsName in @($uplinkMap.Values | Sort-Object -Unique)) {
            $vmnics = @($uplinkMap.Keys | Where-Object { $uplinkMap[$_] -eq $vdsName } | Sort-Object)
            $ordinals = @($vmnics | ForEach-Object { Get-VnicOrdinal -Name $_ } | Where-Object { $_ -ge 0 })
            $backing = @($ordinals | Where-Object { $memberByOrdinal.ContainsKey($_) } | ForEach-Object { $memberByOrdinal[$_] })

            if ($backing.Count -eq 0) {
                Add-Finding -Severity 'WARN' -Scope 'CrossCheck' -Check 'UplinkNotMappedToVnic' -Domain $target -HostName $hostName `
                    -Subject $vdsName -Expected 'a UCS vNIC behind each vDS uplink' -Actual ($vmnics -join ', ') `
                    -Detail "The uplinks $($vmnics -join ', ') on '$vdsName' could not be matched to a vNIC on service profile '$profileName', so their VLANs were not cross-checked."
                continue
            }

            if ($backing.Count -lt $vmnics.Count) {
                Add-Finding -Severity 'WARN' -Scope 'CrossCheck' -Check 'UplinkPartiallyMapped' -Domain $target -HostName $hostName `
                    -Subject $vdsName -Expected "a vNIC for each of $($vmnics -join ', ')" -Actual "$($backing.Count) matched" `
                    -Detail "Only $($backing.Count) of the $($vmnics.Count) uplinks on '$vdsName' matched a UCS vNIC. The cross-check below covers the matched ones only."
            }

            $trunked = @(@($backing | ForEach-Object { $_.VlanIds }) | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
            $natives = @($backing | ForEach-Object { [int]$_.NativeId } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
            $nativeId = if ($natives.Count -ge 1) { $natives[0] } else { 0 }

            if (-not $vdsByName.ContainsKey($vdsName)) {
                Write-Log "vDS '$vdsName' is on $hostName but was not returned by Get-VDSwitch; skipping its port groups." -Level WARN
                continue
            }
            $vds = $vdsByName[$vdsName]
            $discovery = Get-VdsDiscoveryProtocol -VdsView $vds.ExtensionData

            if (-not $portGroupsByVds.ContainsKey($vdsName)) {
                $rows = New-Object System.Collections.Generic.List[object]
                foreach ($portGroup in @(Get-VDPortgroup -VDSwitch $vds -ErrorAction SilentlyContinue)) {
                    $view = $portGroup.ExtensionData
                    if (Test-UplinkPortGroup -PortGroupView $view) { continue }
                    $defaultConfig = Get-MoProperty (Get-MoProperty $view 'Config' $null) 'DefaultPortConfig' $null
                    $parsed = ConvertTo-VlanIdList -VlanSpec (Get-MoProperty $defaultConfig 'Vlan' $null)
                    $teamingPolicy = Get-MoProperty $defaultConfig 'UplinkTeamingPolicy' $null
                    [void]$rows.Add([pscustomobject]@{
                        Name           = [string]$portGroup.Name
                        Kind           = $parsed.Kind
                        VlanIds        = $parsed.VlanIds
                        Count          = $parsed.Count
                        Teaming        = [string](Get-MoProperty (Get-MoProperty $teamingPolicy 'Policy' $null) 'Value' '')
                        BeaconProbing  = [bool](Get-MoProperty (Get-MoProperty (Get-MoProperty $teamingPolicy 'FailureCriteria' $null) 'CheckBeacon' $null) 'Value' $false)
                        NotifySwitches = Get-MoProperty (Get-MoProperty $teamingPolicy 'NotifySwitches' $null) 'Value' $null
                    })
                }
                $portGroupsByVds[$vdsName] = $rows.ToArray()
            }

            Add-CheckResult -Finding @(Compare-VdsVlanCoverage -VdsName $vdsName -PortGroup $portGroupsByVds[$vdsName] `
                    -TrunkedVlanId $trunked -NativeVlanId $nativeId -LargeTrunkThreshold $LargeTrunkThreshold) `
                -Scope 'CrossCheck' -Domain $target -HostName $hostName -Check 'VdsVlanCoverage' -Subject $vdsName `
                -Detail ("Every VLAN the {0} port group(s) on '{1}' need is trunked to the vmnics behind it ({2})." -f @($portGroupsByVds[$vdsName]).Count, $vdsName, (Format-IdList -Id $trunked))

            if (-not $SkipBestPractice) {
                Add-CheckResult -Finding @(Test-VdsBestPractice -VdsName $vdsName -UplinkCount $vmnics.Count -DiscoveryOperation $discovery.Operation) `
                    -Scope 'vCenter' -Domain $target -HostName $hostName -Category 'BestPractice' -Check 'VdsSettings' -Subject $vdsName `
                    -Detail ("'{0}' has {1} uplinks on this host and link discovery is {2}." -f $vdsName, $vmnics.Count, $discovery.Operation)

                $teamingFindings = New-Object System.Collections.Generic.List[object]
                foreach ($row in @($portGroupsByVds[$vdsName])) {
                    foreach ($entry in @(Test-PortGroupBestPractice -PortGroup $row -VdsName $vdsName)) { [void]$teamingFindings.Add($entry) }
                }
                Add-CheckResult -Finding $teamingFindings.ToArray() `
                    -Scope 'vCenter' -Domain $target -HostName $hostName -Category 'BestPractice' -Check 'PortGroupTeaming' -Subject $vdsName `
                    -Detail ("All {0} port group(s) on '{1}' use a teaming mode that works in front of UCS, with beacon probing off and notify switches on." -f @($portGroupsByVds[$vdsName]).Count, $vdsName)
            }

            # --- MTU: the vDS cannot carry more than the vNIC does -------------
            $vdsMtu = [int](Get-MoProperty (Get-MoProperty $vds.ExtensionData 'Config' $null) 'MaxMtu' 0)
            if ($vdsMtu -gt 0) {
                $mtuFindings = New-Object System.Collections.Generic.List[object]
                foreach ($member in @($backing | Where-Object { [int]$_.Mtu -gt 0 -and [int]$_.Mtu -lt $vdsMtu })) {
                    [void]$mtuFindings.Add([pscustomobject]@{
                        Severity = 'ERROR'; Check = 'VdsMtuExceedsVnicMtu'
                        Subject  = "$vdsName / $($member.VnicName)"
                        Expected = "a vNIC MTU of at least $vdsMtu"
                        Actual   = "$($member.Mtu)"
                        Detail   = "'$vdsName' is set to MTU $vdsMtu but $($member.VnicName) (template '$($member.TemplateName)') is MTU $($member.Mtu). Frames above $($member.Mtu) are dropped at the fabric interconnect."
                    })
                }
                Add-CheckResult -Finding $mtuFindings.ToArray() `
                    -Scope 'CrossCheck' -Domain $target -HostName $hostName -Check 'VdsMtu' -Subject $vdsName `
                    -Detail ("'{0}' is set to MTU {1} and every UCS vNIC behind it carries at least that." -f $vdsName, $vdsMtu)
            }

            # --- discovery protocol -------------------------------------------
            # The fault that hides every other fault: with CDP off in UCS and the
            # vDS listening for CDP, the host reports no neighbour at all.
            if ($discovery.Protocol -and $discovery.Operation -notmatch '^(none|)$') {
                $discoveryFindings = New-Object System.Collections.Generic.List[object]
                foreach ($member in $backing) {
                    $policy = $null
                    if ($member.NetworkControlPolicy -and $controlPolicyByName.ContainsKey($member.NetworkControlPolicy)) {
                        $policy = $controlPolicyByName[$member.NetworkControlPolicy]
                    }
                    if ($null -eq $policy) { continue }

                    if ($discovery.Protocol -eq 'cdp') {
                        $cdp = [string](Get-MoProperty $policy 'Cdp' 'disabled')
                        if ($cdp -ne 'enabled') {
                            [void]$discoveryFindings.Add([pscustomobject]@{
                                Severity = 'WARN'; Check = 'CdpDisabledOnUcs'
                                Subject  = "$vdsName / $($member.VnicName)"
                                Expected = 'CDP enabled on the network control policy'
                                Actual   = $cdp
                                Detail   = "'$vdsName' is set to CDP ($($discovery.Operation)) but network control policy '$($member.NetworkControlPolicy)' behind $($member.VnicName) has CDP $cdp. The host will report no neighbour on that uplink."
                            })
                        }
                    }
                    elseif ($discovery.Protocol -eq 'lldp') {
                        $transmit = [string](Get-MoProperty $policy 'LldpTransmit' 'unknown')
                        if ($transmit -eq 'disabled') {
                            [void]$discoveryFindings.Add([pscustomobject]@{
                                Severity = 'WARN'; Check = 'LldpDisabledOnUcs'
                                Subject  = "$vdsName / $($member.VnicName)"
                                Expected = 'LLDP transmit enabled on the network control policy'
                                Actual   = $transmit
                                Detail   = "'$vdsName' is set to LLDP ($($discovery.Operation)) but network control policy '$($member.NetworkControlPolicy)' behind $($member.VnicName) has LLDP transmit disabled. The host will report no neighbour on that uplink."
                            })
                        }
                    }
                }
                Add-CheckResult -Finding $discoveryFindings.ToArray() `
                    -Scope 'CrossCheck' -Domain $target -HostName $hostName -Check 'DiscoveryProtocol' -Subject $vdsName `
                    -Detail ("'{0}' is set to {1} ({2}) and the UCS network control policies behind it have {1} enabled, so the blades report their neighbour." -f $vdsName, $discovery.Protocol.ToUpperInvariant(), $discovery.Operation)
            }
        }
    }

    # ---- Hosts in the same clusters that this domain does not account for ----
    # Bounded to the clusters the matched blades are in, deliberately. Scanning
    # every host in the vCenter would ask CDP of hundreds of hosts that have
    # nothing to do with this domain; a host sitting in the same cluster as this
    # domain's blades and claiming a different fabric is the case worth catching,
    # because a cluster split across two UCS domains is invisible from either.
    $matchedClusters = @($allHosts | Where-Object { $matchedHostName.ContainsKey([string]$_.Name) } |
        ForEach-Object { [string](Get-MoProperty $_ 'Parent' '') } | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($esx in @($allHosts | Where-Object { -not $matchedHostName.ContainsKey([string]$_.Name) })) {
        $parent = [string](Get-MoProperty $esx 'Parent' '')
        if (-not $parent -or $matchedClusters -notcontains $parent) { continue }
        $neighbours = @(Get-UcsTargetForHost -VMHostObject $esx)
        if ($neighbours.Count -eq 0) {
            Add-Finding -Severity 'INFO' -Scope 'CrossCheck' -Check 'HostNotInDomain' -Domain $target -HostName ([string]$esx.Name) `
                -Subject ([string]$esx.Name) -Expected '' -Actual 'no CDP or LLDP neighbour' `
                -Detail ("{0} sits in cluster '{1}' alongside blades of '{2}' but has no service profile there and reports no neighbour, so which fabric it belongs to is unknown." -f $esx.Name, $parent, $target)
            continue
        }
        Add-Finding -Severity 'WARN' -Scope 'CrossCheck' -Check 'HostInAnotherDomain' -Domain $target -HostName ([string]$esx.Name) `
            -Subject ([string]$esx.Name) -Expected "a blade of '$target', like the rest of its cluster" -Actual ($neighbours -join ', ') `
            -Detail ("{0} shares cluster '{1}' with blades of '{2}' but is cabled to {3}. A cluster split across two UCS domains has two sets of VLANs and two sets of vNIC templates to keep in step, and neither domain shows the other half." -f $esx.Name, $parent, $target, ($neighbours -join ', '))
    }

    # ---- Report ------------------------------------------------------------
    $all = @($script:Findings.ToArray())
    $errorCount = @($all | Where-Object { $_.Severity -eq 'ERROR' }).Count
    $warnCount = @($all | Where-Object { $_.Severity -eq 'WARN' }).Count
    $infoCount = @($all | Where-Object { $_.Severity -eq 'INFO' }).Count
    $okCount = @($all | Where-Object { $_.Severity -eq 'OK' }).Count
    Write-Log "$errorCount error(s), $warnCount warning(s), $infoCount informational, $okCount clean." -Level INFO

    # OK rows stay in by default - they are what makes the report reviewable
    # rather than merely scannable. INFO is context and stays behind the switch.
    $selected = if ($IncludeInformational) { $all } else { @($all | Where-Object { $_.Severity -ne 'INFO' }) }

    # Faults first, then context, then the clean rows. Column order is for
    # reading left to right in a spreadsheet: how bad, what was checked, what it
    # was checked on, then what should have been true and what is.
    $order = @{ 'ERROR' = 0; 'WARN' = 1; 'INFO' = 2; 'OK' = 3 }
    $output = @($selected |
        Sort-Object -Property @{ Expression = { $order[$_.Severity] } }, Category, Scope, Check, Subject |
        ForEach-Object {
            [pscustomobject]@{
                Severity  = $_.Severity
                Status    = $(if ($_.Severity -eq 'OK') { 'PASS' } elseif ($_.Severity -eq 'INFO') { 'NOTE' } else { 'REVIEW' })
                Category  = $_.Category
                Scope     = $_.Scope
                Check     = $_.Check
                Subject   = $_.Subject
                Domain    = $_.Domain
                HostCount = $_.Hosts.Count
                Hosts     = ($_.Hosts.ToArray() -join '; ')
                Expected  = $_.Expected
                Actual    = $_.Actual
                Detail    = $_.Detail
            }
        })

    if ($CsvPath) {
        $directory = Split-Path -Path $CsvPath -Parent
        if ($directory -and -not (Test-Path $directory)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
        $output | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        Write-Log "Wrote $($output.Count) row(s) to $CsvPath - $errorCount error(s), $warnCount warning(s), $okCount clean." -Level INFO
    }

    # ---- On screen ---------------------------------------------------------
    # Printed as well as returned. Someone who has downloaded one file and run it
    # should not have to know to pipe it into Format-Table to see the answer, and
    # this goes to the host, so '| Export-Csv' still gets the objects and nothing
    # else. Findings stay on the success stream as objects for anyone who wants
    # to sort or filter them.
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Cyan
    Write-Host ' VLAN AND vNIC CONSISTENCY' -ForegroundColor Cyan
    Write-Host '=====================================================================' -ForegroundColor Cyan

    if ($all.Count -eq 0) {
        Write-Host ' Nothing was checked. No host reached a UCS domain - see the log above.' -ForegroundColor Yellow
    }
    else {
        foreach ($finding in $output) {
            $colour = switch ($finding.Severity) {
                'ERROR' { 'Red' }
                'WARN'  { 'Yellow' }
                'OK'    { 'Green' }
                default { 'Gray' }
            }
            Write-Host (' [{0,-5}] {1,-26} {2}' -f $finding.Severity, $finding.Check, $finding.Subject) -ForegroundColor $colour
            Write-Host ("         $($finding.Detail)") -ForegroundColor DarkGray
            if ($finding.HostCount -gt 0) {
                Write-Host ("         on $($finding.HostCount) host(s): $($finding.Hosts)") -ForegroundColor DarkGray
            }
        }
        if (-not $IncludeInformational -and $infoCount -gt 0) {
            Write-Host ''
            Write-Host " $infoCount informational finding(s) withheld. Re-run with -IncludeInformational to see them." -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    if ($errorCount -eq 0 -and $warnCount -eq 0 -and $okCount -gt 0) {
        Write-Host (' CLEAN - {0} check(s) ran and none found a discrepancy.' -f $okCount) -ForegroundColor Green
    }
    else {
        Write-Host (' {0} error(s), {1} warning(s) to review. {2} check(s) clean, {3} informational.' -f $errorCount, $warnCount, $okCount, $infoCount) -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Yellow' })
    }
    Write-Host '=====================================================================' -ForegroundColor Cyan

    $output
}
catch {
    Write-Log "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    foreach ($openSession in @($script:UcsSessions.Values)) {
        try { Disconnect-Ucs -Ucs $openSession -ErrorAction SilentlyContinue | Out-Null } catch { }
    }
    $script:UcsSessions = @{}

    # Nothing survives the run. A credential left held is one the next thing in
    # this session can replay.
    $script:UcsCredentialCache = $null

    try { Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}
