<#
.SYNOPSIS
    Read-only VLAN audit of UCS Manager domains against live vCenter usage.

.DESCRIPTION
    Monthly reconciliation of the VLANs defined on a UCS Manager domain - LAN Cloud and vNIC
    templates - against what the ESXi hosts on that domain actually use. Successor to
    UCSM-vCenter-Live-Monthly-VLAN-Audit v7.5; docs/ucs-vlan-cleanup.md records what changed and
    why.

    READ ONLY. Nothing on UCS Manager, vCenter, any host, VM, port group or switch is changed.
    Removal is a separate, change-controlled step: Remove-UcsUnusedVlan.ps1 reads the
    candidates.json this script writes, re-validates it against the live domain, and only then
    removes anything.

    A LAN Cloud VLAN is a cleanup candidate only when nothing below protects it:

      - A VM or VM template on a port group carrying it, in any cluster with at least one host on
        this domain. Cluster-wide, because DRS can move a VM onto this domain at any time.
      - A VM anywhere in the scanned vCenters on a distributed port group that is also present on
        those clusters' hosts.
      - A VMkernel adapter on such a port group.
      - A trunk, guest-tagging (4095) or PVLAN port group in use whose range includes it.
      - The vNICs of an associated service profile that is NOT matched to a scanned ESXi host -
        bare metal, or ESXi in a vCenter that was not scanned.
      - Native/untagged use on any vNIC, vNIC template or the LAN Cloud itself.
      - VLAN group membership, or the in-band management profile.
      - The DR list, and the operator-confirmed physical and special VLAN lists.

    Service profiles are matched to ESXi hosts by MAC address - a vmnic presents the MAC of the
    UCS vNIC behind it - so the match does not depend on naming. CDP/LLDP is still read and
    reported as a cross-check.

    Candidates are PRELIMINARY, and the removal script refuses them, whenever the run raised a
    warning: a vCenter collection failure in scope, an unconfirmed operator check, ambiguous MAC
    matching, or a host in scope that cannot be tied to a domain. The Warnings sheet lists them.

    Requires Cisco UCS PowerTool (Cisco.UcsManager) and VMware PowerCLI. Excel is optional.

.PARAMETER UcsDomain
    UCS Manager domain(s) to audit - an allowlisted name, or its FQDN. Prompted for when omitted.
    A domain outside the allowlist is refused before any login is attempted.

.PARAMETER VCenter
    vCenter server(s) to scan for every domain in this run. Prompted for per domain when omitted.
    Scan every vCenter with hosts on the domain: a service profile that cannot be matched to a
    scanned host has every VLAN on its vNICs protected, so a missed vCenter costs candidates, not
    safety.

.PARAMETER ReportFormat
    Excel, CSV, Both, or Auto (Excel and CSV when Excel is installed, otherwise CSV). Prompted for
    when omitted. candidates.json is always written.

.PARAMETER UcsCredential
    UCS Manager credential. When omitted it is resolved by Get-RichoCredential from
    -UcsCredentialName, which prompts if nothing is stored.

.PARAMETER VCenterCredential
    vCenter credential. When omitted it is resolved by Get-RichoCredential from
    -VCenterCredentialName.

.PARAMETER UcsCredentialName
    Get-RichoCredential name for UCS Manager. Defaults to 'ucsm'.

.PARAMETER VCenterCredentialName
    Get-RichoCredential name for vCenter. Defaults to 'vcenter'.

.PARAMETER OutputDirectory
    Where report folders are created. Defaults to output/ucs-vlan-audit at the repo root, which
    .gitignore excludes.

.PARAMETER ConnectionTimeoutSeconds
    How long to wait for a UCS Manager login before giving up. Defaults to 60.

.PARAMETER Transcript
    Write a transcript and log file to logs/.

.EXAMPLE
    .\Get-UcsVlanAudit.ps1

    Fully interactive: report format, domains and vCenters are chosen from menus.

.EXAMPLE
    .\Get-UcsVlanAudit.ps1 -UcsDomain PD24000001SS101 -VCenter siepd24vsp0001.test, siepd24vsp0002.test -ReportFormat Both -Transcript
#>
#Requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The *CredentialName parameters name a stored credential; they are not secrets.')]
[CmdletBinding()]
param(
    [string[]]$UcsDomain,

    [string[]]$VCenter,

    [ValidateSet('Excel', 'CSV', 'Both', 'Auto')]
    [string]$ReportFormat,

    [pscredential]$UcsCredential,

    [pscredential]$VCenterCredential,

    [string]$UcsCredentialName = 'ucsm',

    [string]$VCenterCredentialName = 'vcenter',

    [string]$OutputDirectory,

    [ValidateRange(5, 900)]
    [int]$ConnectionTimeoutSeconds = 60,

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '8.0.0'
$DefaultDomainSuffix = '.test'

$MasterUcsList = @(
    'DD31000010SS102', 'DPDC000001SS101', 'PD21000001SS004', 'PD23000001SS001',
    'PD24000001SS001', 'PD24000001SS002', 'PD24000001SS003', 'PD24000001SS004',
    'PD24000001SS101', 'PD84000001SS002', 'PD84000001SS028', 'PD84000001SS029',
    'PD85000001SS003', 'PD85000001SS004', 'PD85000001SS007', 'PD85000001SS028',
    'PD85000001SS029', 'PD85000001SS030', 'PDW1000001SS002'
)

$MasterVCenterList = @(
    'siepd24vsp0001.test', 'siepd24vsp0002.test',
    'siepd24vsp0003.test', 'siepd24vsp0004.test',
    'siepd31vsp0002.test',
    'siepd84vsp0003.test', 'siepd84vsp0004.test',
    'siepd84vsp0005.test', 'siepd84vsp0006.test',
    'siepd84vsp0007.test', 'siepd84vsp0008.test',
    'siepd84vsp0009.test',
    'siepd85vsp0001.test', 'siepd85vsp0002.test',
    'siepd85vsp0003.test', 'siepd85vsp0004.test',
    'siepd85vsp0005.test', 'siepd85vsp0006.test',
    'siepd85vsp0007.test', 'siepd85vsp0008.test',
    'siepd85vsp0009.test', 'siepd85vsp0010.test',
    'siepd85vsp0011.test'
)

# Approved DR VLAN list, carried over unchanged from v7.5.
$EmbeddedDrVlans = @(
    63, 76, 80, 83, 93, 110, 114, 165, 170, 199, 1093, 1106, 1167, 1725, 1727, 1761, 1809, 1817,
    1818, 1822, 1826, 1851, 1913, 1928, 1967, 1968, 1969, 1970, 2000, 2001, 2005, 2007, 2008, 2009,
    2013, 2016, 2017, 2032, 2033, 2035, 2037, 2038, 2039, 2045, 2048, 2049, 2054, 2061, 2062, 2086,
    2096, 2097, 2099, 2104, 2110, 2115, 2120, 2133, 2134, 2145, 2165, 2447, 2779, 2798, 2815, 2848,
    2860, 2867, 2873, 2880, 2881, 2917, 2918, 2926, 2927, 2928, 2930, 2932, 2944, 2948, 2957, 2971,
    2980, 2988, 2992, 2997
)

#region Module loading

function Import-RequiredModules {
    <#
    .SYNOPSIS
        Loads Richo.Common, PowerCLI and UCS PowerTool once, leaving anything already loaded alone.

    .DESCRIPTION
        Each load is guarded by Get-Module, so a module already in the session - including a pinned
        bundle from tools/Import-RichoModuleBundle.ps1 - is used as it is. Nothing is installed or
        updated. Alternatives are for UCS PowerTool, whose module name changed between releases;
        the first that loads wins.

    .EXAMPLE
        Import-RequiredModules
    #>
    $wanted = @(
        [pscustomobject]@{ Purpose = 'shared helpers'; Names = @('Richo.Common'); Path = (Join-Path $PSScriptRoot '../../modules/Richo.Common/Richo.Common.psd1') }
        [pscustomobject]@{ Purpose = 'vCenter (PowerCLI)'; Names = @('VMware.VimAutomation.Core'); Path = '' }
        [pscustomobject]@{ Purpose = 'UCS Manager (PowerTool)'; Names = @('Cisco.UcsManager', 'CiscoUcsPS'); Path = '' }
    )
    foreach ($module in $wanted) {
        $loaded = $false
        foreach ($name in $module.Names) {
            if (Get-Module -Name $name) {
                $loaded = $true
                break
            }
            $source = if ($module.Path) { $module.Path } else { $name }
            try {
                Import-Module -Name $source -ErrorAction Stop
                $loaded = $true
                break
            }
            catch {
                continue
            }
        }
        if (-not $loaded) {
            throw "The module for $($module.Purpose) could not be loaded ($($module.Names -join ' or ')). It is not installed on this host or not on PSModulePath - see README, First-time setup."
        }
    }
}

#endregion

#region Generic helpers

function Get-PropertyValue {
    <#
    .SYNOPSIS
        Reads a property, or a dotted path of properties, returning $null where any step is absent.

    .DESCRIPTION
        Under Set-StrictMode -Version Latest a missing property throws, and so does reading a
        property of $null. UCS PowerTool and PowerCLI objects differ between versions, and Get-View
        returns only the properties asked for, so every optional read goes through here.

    .PARAMETER InputObject
        Object to read. $null returns $null.

    .PARAMETER Path
        A property name, or a dotted path such as 'Config.Network.Pnic'.

    .EXAMPLE
        Get-PropertyValue -InputObject $hostView -Path 'Runtime.ConnectionState'
    #>
    param(
        [AllowNull()]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path
    )
    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            $current = $current[$segment]
            continue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    return $current
}

function Get-PropertyList {
    <#
    .SYNOPSIS
        Like Get-PropertyValue, but emits the non-null elements of a collection, and nothing for $null.

    .DESCRIPTION
        @(Get-PropertyValue ...) of a missing property is a one-element array holding $null, and the
        next member access on it throws under StrictMode. This emits nothing instead.

    .PARAMETER InputObject
        Object to read.

    .PARAMETER Path
        A property name or dotted path.

    .EXAMPLE
        @(Get-PropertyList -InputObject $hostView -Path 'Config.Network.Pnic')
    #>
    param(
        [AllowNull()]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path
    )
    $value = Get-PropertyValue -InputObject $InputObject -Path $Path
    if ($null -eq $value) { return }
    foreach ($item in @($value)) {
        if ($null -ne $item) { $item }
    }
}

function Test-TypeName {
    <#
    .SYNOPSIS
        True when an object is, or derives from, the named type.

    .DESCRIPTION
        PSObject.TypeNames carries the whole inheritance chain, so this answers "is a" without the
        VMware.Vim types being loaded - which keeps the classification testable without PowerCLI.

    .PARAMETER InputObject
        Object to test. $null is never any type.

    .PARAMETER TypeName
        Full type name, e.g. 'VMware.Vim.VirtualEthernetCard'.

    .EXAMPLE
        Test-TypeName -InputObject $device -TypeName 'VMware.Vim.VirtualEthernetCard'
    #>
    param(
        [AllowNull()]$InputObject,

        [Parameter(Mandatory)]
        [string]$TypeName
    )
    if ($null -eq $InputObject) { return $false }
    return ($InputObject.PSObject.TypeNames -contains $TypeName)
}

function Get-MoRefKey {
    <#
    .SYNOPSIS
        A string key for a vSphere managed object reference, e.g. 'HostSystem-host-42'.

    .PARAMETER MoRef
        The managed object reference. $null returns ''.

    .EXAMPLE
        Get-MoRefKey -MoRef $view.MoRef
    #>
    param([AllowNull()]$MoRef)
    if ($null -eq $MoRef) { return '' }
    return ('{0}-{1}' -f (Get-PropertyValue $MoRef 'Type'), (Get-PropertyValue $MoRef 'Value'))
}

function Test-UcsYes {
    <#
    .SYNOPSIS
        True for the yes/true spellings UCS Manager uses for boolean properties.

    .PARAMETER Value
        The property value.

    .EXAMPLE
        Test-UcsYes -Value $vnicEtherIf.DefaultNet
    #>
    param([AllowNull()]$Value)
    return ([string]$Value -match '^(?i)(yes|true)$')
}

function ConvertTo-MacAddress {
    <#
    .SYNOPSIS
        Normalises a MAC address to lower-case colon form, or returns '' when it is not one.

    .DESCRIPTION
        UCS Manager reports 'derived' for a vNIC address that is not assigned yet, and an all-zero
        MAC is never a real identity, so neither may take part in matching.

    .PARAMETER Value
        The address as reported.

    .EXAMPLE
        ConvertTo-MacAddress -Value '00:25:B5:A0:00:1F'
    #>
    param([AllowNull()]$Value)
    $text = ([string]$Value).Trim().ToLowerInvariant() -replace '-', ':'
    if ($text -match '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' -and $text -ne '00:00:00:00:00:00') { return $text }
    return ''
}

function ConvertTo-SortedIntArray {
    <#
    .SYNOPSIS
        Emits the distinct integer values of the input in ascending order, ignoring anything else.

    .PARAMETER InputObject
        Values to convert. Non-numeric values and $null are skipped.

    .EXAMPLE
        @(ConvertTo-SortedIntArray -InputObject @(5, '3', 5, 'x'))
    #>
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$InputObject
    )
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($item in @($InputObject)) {
        $number = 0
        if ($null -ne $item -and [int]::TryParse([string]$item, [ref]$number)) { [void]$set.Add($number) }
    }
    $set | Sort-Object
}

function Format-IdList {
    <#
    .SYNOPSIS
        Formats VLAN IDs compactly for logs and prompts, e.g. '10-14, 20, 300'.

    .PARAMETER Id
        The IDs.

    .EXAMPLE
        Format-IdList -Id @(10, 11, 12, 20)
    #>
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Id
    )
    $sorted = @(ConvertTo-SortedIntArray -InputObject $Id)
    if ($sorted.Count -eq 0) { return '(none)' }
    $parts = New-Object System.Collections.Generic.List[string]
    $start = $sorted[0]
    $previous = $start
    for ($i = 1; $i -le $sorted.Count; $i++) {
        if ($i -lt $sorted.Count -and $sorted[$i] -eq $previous + 1) {
            $previous = $sorted[$i]
            continue
        }
        if ($start -eq $previous) { $parts.Add([string]$start) } else { $parts.Add("$start-$previous") }
        if ($i -lt $sorted.Count) {
            $start = $sorted[$i]
            $previous = $start
        }
    }
    return ($parts -join ', ')
}

#endregion

#region Operator prompts

function Read-MenuChoice {
    <#
    .SYNOPSIS
        Shows a numbered menu as the prompt and returns the number chosen.

    .DESCRIPTION
        The menu is the Read-Host prompt rather than Write-Host output, and the answer is logged,
        so the transcript and log file record what was asked and what was chosen.

    .PARAMETER Title
        Menu heading.

    .PARAMETER Option
        The choices, numbered from 1 in order.

    .PARAMETER Context
        Lines of evidence shown between the heading and the choices.

    .EXAMPLE
        Read-MenuChoice -Title 'REPORT OUTPUT' -Option @('Excel', 'CSV')
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Option,

        [AllowEmptyCollection()]
        [string[]]$Context = @()
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('')
    $lines.Add($Title)
    foreach ($line in $Context) { $lines.Add("  $line") }
    for ($i = 0; $i -lt $Option.Count; $i++) { $lines.Add(('{0}. {1}' -f ($i + 1), $Option[$i])) }
    $lines.Add("Select 1-$($Option.Count)")
    $prompt = $lines -join [Environment]::NewLine

    while ($true) {
        $answer = ([string](Read-Host -Prompt $prompt)).Trim()
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Option.Count) {
            Write-RichoLog ('{0}: {1}. {2}' -f $Title, $number, $Option[$number - 1]) -Level INFO
            return $number
        }
        Write-RichoLog "Invalid selection '$answer' - enter a number from 1 to $($Option.Count)." -Level WARN
    }
}

function ConvertTo-VlanIdList {
    <#
    .SYNOPSIS
        Parses pasted VLAN IDs into sorted, unique IDs from 1 to 4094.

    .DESCRIPTION
        Accepts commas, semicolons, spaces and new lines as separators, and ranges such as
        100-110. Returns the valid IDs and the tokens that were rejected, so the caller can say
        what was ignored rather than silently dropping it.

    .PARAMETER Text
        The pasted text.

    .EXAMPLE
        ConvertTo-VlanIdList -Text '10, 20-22; 4095'
    #>
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )
    $valid = New-Object 'System.Collections.Generic.HashSet[int]'
    $invalid = New-Object System.Collections.Generic.List[string]
    foreach ($token in ([string]$Text -split '[,;\s]+')) {
        if (-not $token) { continue }
        $id = 0
        if ([int]::TryParse($token, [ref]$id) -and $id -ge 1 -and $id -le 4094) {
            [void]$valid.Add($id)
            continue
        }
        if ($token -match '^(\d+)-(\d+)$') {
            $first = [int]$Matches[1]
            $last = [int]$Matches[2]
            if ($first -ge 1 -and $last -le 4094 -and $first -le $last) {
                for ($n = $first; $n -le $last; $n++) { [void]$valid.Add($n) }
                continue
            }
        }
        $invalid.Add($token)
    }
    [pscustomobject]@{
        VlanIds = [int[]]@($valid | Sort-Object)
        Invalid = $invalid.ToArray()
    }
}

function Read-VlanIdList {
    <#
    .SYNOPSIS
        Collects pasted VLAN IDs, line by line, until the operator types DONE.

    .PARAMETER Heading
        What the list is for.

    .EXAMPLE
        @(Read-VlanIdList -Heading 'Confirmed physical-server VLAN IDs')
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Heading
    )
    Write-RichoLog $Heading -Level INFO
    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $line = [string](Read-Host -Prompt 'VLAN IDs - commas, spaces, ranges such as 100-110, or one per line. Type DONE to finish')
        if ($line.Trim().ToUpperInvariant() -eq 'DONE') { break }
        $lines.Add($line)
    }
    $parsed = ConvertTo-VlanIdList -Text ($lines -join ' ')
    foreach ($token in $parsed.Invalid) { Write-RichoLog "Ignored invalid VLAN value: $token" -Level WARN }
    Write-RichoLog "Accepted $($parsed.VlanIds.Count) VLAN ID(s): $(Format-IdList -Id $parsed.VlanIds)" -Level INFO
    $parsed.VlanIds
}

function Read-TargetSelection {
    <#
    .SYNOPSIS
        Lets the operator pick all, one, several, or a manually entered target from a list.

    .PARAMETER Item
        The list to choose from.

    .PARAMETER Title
        Menu heading.

    .PARAMETER AllowManual
        Offer manual entry of a target that is not in the list.

    .EXAMPLE
        @(Read-TargetSelection -Item $MasterVCenterList -Title 'Select vCenter(s)' -AllowManual)
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Item,

        [Parameter(Mandatory)]
        [string]$Title,

        [switch]$AllowManual
    )
    $options = New-Object System.Collections.Generic.List[string]
    $options.Add('All')
    $options.Add('Select one')
    $options.Add('Select multiple')
    if ($AllowManual) { $options.Add('Enter a target manually') }
    $options.Add('Back / exit')

    while ($true) {
        $label = $options[(Read-MenuChoice -Title $Title -Option $options.ToArray()) - 1]
        if ($label -eq 'All') { return $Item }
        if ($label -eq 'Back / exit') { return }
        if ($label -eq 'Enter a target manually') {
            $manual = ([string](Read-Host -Prompt 'Target name or FQDN')).Trim()
            if ($manual) { return $manual }
            continue
        }

        $listing = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $Item.Count; $i++) { $listing.Add(('{0,3}. {1}' -f ($i + 1), $Item[$i])) }
        $listing.Add($(if ($label -eq 'Select one') { 'Enter one number' } else { 'Enter comma-separated numbers, for example 1,3,5' }))
        $text = [string](Read-Host -Prompt ($listing -join [Environment]::NewLine))

        $selected = New-Object System.Collections.Generic.List[string]
        $valid = $true
        foreach ($part in ($text -split ',')) {
            $number = 0
            if (-not [int]::TryParse($part.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $Item.Count) {
                $valid = $false
                break
            }
            if (-not $selected.Contains($Item[$number - 1])) { $selected.Add($Item[$number - 1]) }
        }
        if ($valid -and $label -eq 'Select one' -and $selected.Count -ne 1) { $valid = $false }
        if ($valid -and $selected.Count -gt 0) {
            Write-RichoLog "Selected: $($selected -join ', ')" -Level INFO
            return $selected.ToArray()
        }
        Write-RichoLog 'Invalid selection.' -Level WARN
    }
}

function Read-DrConfiguration {
    <#
    .SYNOPSIS
        Asks which side of DR the domain is on, and which DR VLAN list protects it.

    .PARAMETER EmbeddedList
        The approved DR VLAN list carried in this script.

    .EXAMPLE
        Read-DrConfiguration -EmbeddedList $EmbeddedDrVlans
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [int[]]$EmbeddedList
    )
    $side = @('Protected', 'DR', 'Both', 'Unknown')[(Read-MenuChoice -Title 'UCSM ENVIRONMENT' -Option @(
            'Protected side',
            'DR side',
            'Both Protected and DR',
            'Unknown / report only')) - 1]
    $drVlans = @()
    $source = 'Not enabled'
    if ($side -in @('DR', 'Both')) {
        $choice = Read-MenuChoice -Title 'DR VLAN LIST' -Context @("The approved embedded DR list holds $(@(ConvertTo-SortedIntArray $EmbeddedList).Count) unique VLANs.") -Option @(
            'USE EMBEDDED LIST - recommended',
            'REPLACE - paste the complete current list',
            'CONTINUE WITHOUT DR PROTECTION - candidates stay preliminary')
        if ($choice -eq 1) {
            $drVlans = @(ConvertTo-SortedIntArray -InputObject $EmbeddedList)
            $source = 'Embedded approved list'
        }
        elseif ($choice -eq 2) {
            $drVlans = @(Read-VlanIdList -Heading 'Paste the complete current DR VLAN list')
            $source = 'Pasted replacement list'
        }
        else {
            Write-RichoLog 'DR protection is disabled for this run.' -Level WARN
        }
        Write-RichoLog "Accepted DR source: $source | unique VLANs: $($drVlans.Count)" -Level INFO
    }
    [pscustomobject]@{
        Side = $side
        DrVlans = [int[]]$drVlans
        DrSource = $source
    }
}

#endregion

#region UCS Manager

function ConvertTo-UcsDomainName {
    <#
    .SYNOPSIS
        Returns the allowlisted UCS domain named in a CDP/LLDP neighbour string, or ''.

    .DESCRIPTION
        Handles strings, byte arrays, embedded NULs, FQDNs, fabric suffixes and serial numbers,
        e.g. 'PD84000001SS028-A(FD023360H8B)', 'PD84000001SS028-B.test', 'FI-A PD84000001SS028'.
        Only an exact allowlisted token counts; nothing is inferred from a partial name.

    .PARAMETER SystemName
        The neighbour's device ID or system name.

    .PARAMETER AllowedName
        The UCS Manager allowlist.

    .EXAMPLE
        ConvertTo-UcsDomainName -SystemName 'PD84000001SS028-A(FD023360H8B)' -AllowedName $MasterUcsList
    #>
    param(
        [AllowNull()]
        [object]$SystemName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$AllowedName
    )
    if ($null -eq $SystemName) { return '' }
    $raw = if ($SystemName -is [byte[]]) { [Text.Encoding]::ASCII.GetString($SystemName) } else { [string]$SystemName }
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $raw = $raw.Replace([char]0, ' ').Trim().ToUpperInvariant()
    $compact = $raw -replace '\s', ''

    # Both forms: whitespace is a boundary in 'FI-A PD84000001SS028', but v7.5 only tested the
    # compacted 'FI-APD84000001SS028', where it is not - so that documented form never matched.
    foreach ($allowed in $AllowedName) {
        $token = [regex]::Escape($allowed.ToUpperInvariant())
        $pattern = "(^|[^A-Z0-9])$token(?=$|[^A-Z0-9])"
        if ($raw -match $pattern -or $compact -match $pattern) { return $allowed.ToUpperInvariant() }
    }

    $name = $raw -replace '\([^)]*\)', ''
    $name = $name -replace '\s+FI-[AB].*$', ''
    $name = ($name -split '\.')[0]
    $name = ($name -replace '-[AB]$', '').Trim()
    foreach ($allowed in $AllowedName) {
        if ($allowed.ToUpperInvariant() -eq $name) { return $name }
    }
    return ''
}

function Connect-UcsWithTimeout {
    <#
    .SYNOPSIS
        Logs in to UCS Manager, giving up after a fixed time instead of hanging the run.

    .DESCRIPTION
        Connect-Ucs has no timeout of its own, so it runs in a separate runspace that is abandoned
        if it does not return in time. The runspace loads the same PowerTool module file this
        session already has, so a pinned bundle is honoured there too.

    .PARAMETER Server
        UCS Manager name or FQDN.

    .PARAMETER Credential
        UCS Manager credential.

    .PARAMETER TimeoutSeconds
        How long to wait.

    .EXAMPLE
        $ucs = Connect-UcsWithTimeout -Server PD24000001SS101 -Credential $cred -TimeoutSeconds 60
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter(Mandatory)]
        [pscredential]$Credential,

        [ValidateRange(1, 900)]
        [int]$TimeoutSeconds = 60
    )
    $command = Get-Command -Name Connect-Ucs -ErrorAction Stop
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    if ($command.Module) {
        $sessionState.ImportPSModule([string[]]@($command.Module.Path))
    }
    $shell = [powershell]::Create($sessionState)
    try {
        [void]$shell.AddCommand('Connect-Ucs').AddParameter('Name', $Server).AddParameter('Credential', $Credential).AddParameter('ErrorAction', 'Stop')
        $async = $shell.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            $shell.Stop()
            throw [TimeoutException]::new("Connection to $Server timed out after $TimeoutSeconds seconds.")
        }
        $result = @($shell.EndInvoke($async) | Where-Object { $null -ne $_ })
        if ($shell.Streams.Error.Count -gt 0) { throw $shell.Streams.Error[0].Exception }
        if ($result.Count -eq 0) { throw "Connect-Ucs returned no session for $Server." }
        return $result[0]
    }
    finally {
        $shell.Dispose()
    }
}

function Get-UcsFabricList {
    <#
    .SYNOPSIS
        The fabrics a vNIC or template SwitchId resolves VLANs on, primary first.

    .PARAMETER SwitchId
        'A', 'B', 'A-B' or 'B-A'. Anything else resolves on no specific fabric.

    .EXAMPLE
        Get-UcsFabricList -SwitchId 'A-B'
    #>
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SwitchId
    )
    switch -Regex ([string]$SwitchId) {
        '^(?i)A-B$' { 'A'; 'B'; break }
        '^(?i)B-A$' { 'B'; 'A'; break }
        '^(?i)A$' { 'A'; break }
        '^(?i)B$' { 'B'; break }
    }
}

function Resolve-UcsVlanReference {
    <#
    .SYNOPSIS
        Every LAN Cloud VLAN that a vNIC's VLAN name can resolve to, preferred first.

    .DESCRIPTION
        vNICs and templates reference VLANs by NAME, and one name can be defined globally and per
        fabric with different IDs. The definition for the vNIC's own fabric comes first, then the
        global one; a failover vNIC (A-B or B-A) is resolved on both fabrics.

        Every possibility is returned, not just the preferred one, on purpose: protection protects
        all of them, and the removal script refuses to remove a membership unless every ID it
        could mean is approved. v7.5 took the first VLAN with a matching name, from either fabric.

    .PARAMETER Name
        The VLAN name the vNIC references.

    .PARAMETER SwitchId
        The vNIC's or template's fabric.

    .PARAMETER VlanIndex
        LAN Cloud VLANs keyed '<fabric>|<name>', where fabric is A, B or dual.

    .EXAMPLE
        @(Resolve-UcsVlanReference -Name 'VL100' -SwitchId 'A' -VlanIndex $index)
    #>
    param(
        [AllowEmptyString()]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$SwitchId,

        [Parameter(Mandatory)]
        [hashtable]$VlanIndex
    )
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($fabric in @(Get-UcsFabricList -SwitchId $SwitchId)) {
        $hit = $VlanIndex["$fabric|$Name"]
        if ($null -ne $hit -and -not $found.Contains($hit)) { $found.Add($hit) }
    }
    $globalHit = $VlanIndex["dual|$Name"]
    if ($null -ne $globalHit -and -not $found.Contains($globalHit)) { $found.Add($globalHit) }
    $found.ToArray()
}

function ConvertTo-UcsVlanInventory {
    <#
    .SYNOPSIS
        Resolves raw UCS Manager objects into the VLAN inventory the audit and removal work from.

    .DESCRIPTION
        Pure: takes the objects, touches nothing. Produces the LAN Cloud VLANs (appliance-cloud
        VLANs excluded), every vnicEtherIf classified by owner - vNIC template, service profile,
        service profile template or LAN connectivity policy - with its VLAN name resolved per
        fabric, the template memberships, each service profile instance with its vNIC MACs and
        every VLAN its vNICs carry, VLAN group and in-band members, and native VLANs.

        v7.5 read every vnicEtherIf but kept only the template ones, so a VLAN used directly on a
        bare-metal service profile looked unused.

    .PARAMETER Vlan
        fabricVlan objects.

    .PARAMETER VnicTemplate
        vnicLanConnTempl objects.

    .PARAMETER EtherIf
        vnicEtherIf objects.

    .PARAMETER Vnic
        vnicEther objects.

    .PARAMETER ServiceProfile
        lsServer objects.

    .PARAMETER PooledVlan
        fabricPooledVlan objects (VLAN group members). $null means they could not be read.

    .PARAMETER InbandProfile
        mgmtInbandProfile objects. $null means they could not be read.

    .EXAMPLE
        ConvertTo-UcsVlanInventory -Vlan $v -VnicTemplate $t -EtherIf $e -Vnic $n -ServiceProfile $s
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Vlan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$VnicTemplate,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EtherIf,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Vnic,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ServiceProfile,
        [AllowNull()][AllowEmptyCollection()][object[]]$PooledVlan = @(),
        [AllowNull()][AllowEmptyCollection()][object[]]$InbandProfile = @()
    )

    $exceptions = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $addException = {
        param($Target, $Category, $Details)
        $exceptions.Add([pscustomobject]@{ Target = $Target; Category = $Category; Details = $Details })
    }

    # ---- LAN Cloud VLANs -----------------------------------------------------------------
    $vlans = New-Object System.Collections.Generic.List[object]
    $otherVlanCount = 0
    foreach ($item in $Vlan) {
        $dn = [string](Get-PropertyValue $item 'Dn')
        if ($dn -notlike 'fabric/lan/*') {
            $otherVlanCount++
            continue
        }
        $id = 0
        if (-not [int]::TryParse([string](Get-PropertyValue $item 'Id'), [ref]$id)) {
            & $addException $dn 'UNREADABLE VLAN ID' "VLAN ID '$(Get-PropertyValue $item 'Id')' is not a number."
            continue
        }
        $vlans.Add([pscustomobject]@{
                Name = [string](Get-PropertyValue $item 'Name')
                Id = $id
                Fabric = $(if ($dn -match '^fabric/lan/([AB])/') { $Matches[1] } else { 'dual' })
                Native = (Test-UcsYes (Get-PropertyValue $item 'DefaultNet'))
                Sharing = [string](Get-PropertyValue $item 'Sharing')
                PubNwName = [string](Get-PropertyValue $item 'PubNwName')
                Dn = $dn
            })
    }

    $vlanIndex = @{}
    $idsByName = @{}
    foreach ($row in $vlans) {
        $key = "$($row.Fabric)|$($row.Name)"
        if ($vlanIndex.ContainsKey($key)) {
            & $addException $row.Dn 'DUPLICATE VLAN NAME' "Another VLAN named '$($row.Name)' exists on fabric $($row.Fabric) ($($vlanIndex[$key].Dn)); both IDs are treated as in use wherever the name is referenced."
            $warnings.Add("VLAN name '$($row.Name)' is defined twice on fabric $($row.Fabric) (case-insensitively); references to it cannot be resolved to one ID.")
        }
        else {
            $vlanIndex[$key] = $row
        }
        if (-not $idsByName.ContainsKey($row.Name)) { $idsByName[$row.Name] = New-Object 'System.Collections.Generic.HashSet[int]' }
        [void]$idsByName[$row.Name].Add($row.Id)
    }

    # ---- Templates, service profiles and vNICs ----------------------------------------------
    $templates = New-Object System.Collections.Generic.List[object]
    $templateByDn = @{}
    $templatesByName = @{}
    foreach ($item in $VnicTemplate) {
        $row = [pscustomobject]@{
            Name = [string](Get-PropertyValue $item 'Name')
            Dn = [string](Get-PropertyValue $item 'Dn')
            SwitchId = [string](Get-PropertyValue $item 'SwitchId')
            TemplateType = [string](Get-PropertyValue $item 'TemplType')
        }
        $templates.Add($row)
        $templateByDn[$row.Dn] = $row
        if (-not $templatesByName.ContainsKey($row.Name)) { $templatesByName[$row.Name] = New-Object System.Collections.Generic.List[object] }
        $templatesByName[$row.Name].Add($row)
    }

    $serverByDn = @{}
    foreach ($item in $ServiceProfile) {
        $row = [pscustomobject]@{
            Dn = [string](Get-PropertyValue $item 'Dn')
            Name = [string](Get-PropertyValue $item 'Name')
            Type = [string](Get-PropertyValue $item 'Type')
            AssocState = [string](Get-PropertyValue $item 'AssocState')
            PnDn = [string](Get-PropertyValue $item 'PnDn')
        }
        $serverByDn[$row.Dn] = $row
    }

    $vnicByDn = @{}
    $vnicsByOwner = @{}
    foreach ($item in $Vnic) {
        $dn = [string](Get-PropertyValue $item 'Dn')
        $ownerDn = if ($dn -match '^(?<owner>.+)/ether-[^/]+$') { $Matches['owner'] } else { '' }

        $templateDns = @()
        $operTemplate = [string](Get-PropertyValue $item 'OperNwTemplName')
        $templateName = [string](Get-PropertyValue $item 'NwTemplName')
        if ($operTemplate -and $templateByDn.ContainsKey($operTemplate)) {
            $templateDns = @($operTemplate)
        }
        elseif ($templateName -and $templatesByName.ContainsKey($templateName)) {
            $templateDns = @($templatesByName[$templateName] | ForEach-Object { $_.Dn })
            if ($templateDns.Count -gt 1) {
                & $addException $dn 'AMBIGUOUS TEMPLATE BINDING' "Bound to '$templateName', which exists in more than one org; every one of them is treated as bound."
            }
        }
        elseif ($templateName) {
            & $addException $dn 'UNRESOLVED TEMPLATE BINDING' "Bound to vNIC template '$templateName', which was not found."
            $warnings.Add("vNIC $dn is bound to template '$templateName', which was not found, so the VLANs it carries are unknown.")
        }

        $row = [pscustomobject]@{
            Dn = $dn
            Name = [string](Get-PropertyValue $item 'Name')
            OwnerDn = $ownerDn
            SwitchId = [string](Get-PropertyValue $item 'SwitchId')
            Mac = (ConvertTo-MacAddress (Get-PropertyValue $item 'Addr'))
            TemplateDns = [string[]]$templateDns
        }
        $vnicByDn[$dn] = $row
        if ($ownerDn) {
            if (-not $vnicsByOwner.ContainsKey($ownerDn)) { $vnicsByOwner[$ownerDn] = New-Object System.Collections.Generic.List[object] }
            $vnicsByOwner[$ownerDn].Add($row)
        }
    }

    # ---- Every VLAN reference --------------------------------------------------------------
    $etherIfs = New-Object System.Collections.Generic.List[object]
    $etherIfsByOwner = @{}
    $membershipsByTemplate = @{}
    foreach ($item in $EtherIf) {
        $dn = [string](Get-PropertyValue $item 'Dn')
        $name = [string](Get-PropertyValue $item 'Name')
        $slash = $dn.LastIndexOf('/')
        $parentDn = if ($slash -gt 0) { $dn.Substring(0, $slash) } else { '' }

        $ownerType = 'Other'
        $ownerDn = $parentDn
        $switchId = ''
        $viaTemplate = $false
        if ($templateByDn.ContainsKey($parentDn)) {
            $ownerType = 'VnicTemplate'
            $switchId = $templateByDn[$parentDn].SwitchId
        }
        elseif ($parentDn -match '^(?<owner>.+)/ether-[^/]+$') {
            $ownerDn = $Matches['owner']
            if ($vnicByDn.ContainsKey($parentDn)) {
                $switchId = $vnicByDn[$parentDn].SwitchId
                $viaTemplate = $vnicByDn[$parentDn].TemplateDns.Count -gt 0
            }
            if ($ownerDn -match '/ls-[^/]+$') {
                $ownerType = if ($serverByDn.ContainsKey($ownerDn) -and $serverByDn[$ownerDn].Type -ne 'instance') { 'ServiceProfileTemplate' } else { 'ServiceProfile' }
            }
            elseif ($ownerDn -match '/lan-conn-pol-[^/]+$') {
                $ownerType = 'LanConnPolicy'
            }
        }

        $resolved = @(Resolve-UcsVlanReference -Name $name -SwitchId $switchId -VlanIndex $vlanIndex)
        $ids = @(ConvertTo-SortedIntArray -InputObject @($resolved | ForEach-Object { $_.Id }))
        if ($resolved.Count -eq 0) {
            & $addException $dn 'UNDEFINED VLAN REFERENCE' "References VLAN '$name', which is not defined in the LAN Cloud$(if ($switchId) { " for fabric $switchId" })."
        }
        elseif ($ids.Count -gt 1) {
            & $addException $dn 'AMBIGUOUS VLAN NAME' "VLAN '$name' can resolve to IDs $($ids -join ', ') on fabric $switchId; all of them are treated as in use."
        }

        $row = [pscustomobject]@{
            Dn = $dn
            ParentDn = $parentDn
            OwnerType = $ownerType
            OwnerDn = $ownerDn
            SwitchId = $switchId
            ViaTemplate = $viaTemplate
            VlanName = $name
            Native = (Test-UcsYes (Get-PropertyValue $item 'DefaultNet'))
            VlanId = $(if ($resolved.Count -gt 0) { $resolved[0].Id } else { $null })
            VlanDn = $(if ($resolved.Count -gt 0) { $resolved[0].Dn } else { '' })
            ResolvedVlanIds = [int[]]$ids
            ResolvedVlanDns = [string[]]@($resolved | ForEach-Object { $_.Dn })
            TemplateDns = [string[]]@(if ($vnicByDn.ContainsKey($parentDn)) { $vnicByDn[$parentDn].TemplateDns })
        }
        $etherIfs.Add($row)
        if (-not $etherIfsByOwner.ContainsKey($ownerDn)) { $etherIfsByOwner[$ownerDn] = New-Object System.Collections.Generic.List[object] }
        $etherIfsByOwner[$ownerDn].Add($row)
        if ($ownerType -eq 'VnicTemplate') {
            if (-not $membershipsByTemplate.ContainsKey($parentDn)) { $membershipsByTemplate[$parentDn] = New-Object System.Collections.Generic.List[object] }
            $membershipsByTemplate[$parentDn].Add($row)
        }
    }

    $memberships = New-Object System.Collections.Generic.List[object]
    foreach ($row in $etherIfs) {
        if ($row.OwnerType -ne 'VnicTemplate') { continue }
        $template = $templateByDn[$row.ParentDn]
        $memberships.Add([pscustomobject]@{
                Template = $template.Name
                TemplateDn = $template.Dn
                TemplateType = $template.TemplateType
                Fabric = $template.SwitchId
                VLANName = $row.VlanName
                VLANID = $(if ($null -ne $row.VlanId) { [string]$row.VlanId } else { '' })
                NativeVLAN = $(if ($row.Native) { 'Yes' } else { 'No' })
                ResolvedVlanIds = $row.ResolvedVlanIds
                EtherIfDn = $row.Dn
            })
    }

    # ---- Service profile instances ---------------------------------------------------------
    $serviceProfiles = New-Object System.Collections.Generic.List[object]
    $templateBindings = @{}
    foreach ($server in @($serverByDn.Values | Where-Object { $_.Type -eq 'instance' } | Sort-Object Dn)) {
        $vnics = @(if ($vnicsByOwner.ContainsKey($server.Dn)) { $vnicsByOwner[$server.Dn].ToArray() })
        $macs = @($vnics | ForEach-Object { $_.Mac } | Where-Object { $_ } | Sort-Object -Unique)
        $bound = @($vnics | ForEach-Object { $_.TemplateDns } | Where-Object { $_ } | Sort-Object -Unique)

        $ids = New-Object 'System.Collections.Generic.HashSet[int]'
        if ($etherIfsByOwner.ContainsKey($server.Dn)) {
            foreach ($row in $etherIfsByOwner[$server.Dn]) { foreach ($id in $row.ResolvedVlanIds) { [void]$ids.Add($id) } }
        }
        foreach ($templateDn in $bound) {
            if (-not $templateBindings.ContainsKey($templateDn)) { $templateBindings[$templateDn] = New-Object System.Collections.Generic.List[string] }
            $templateBindings[$templateDn].Add($server.Dn)
            if ($membershipsByTemplate.ContainsKey($templateDn)) {
                foreach ($row in $membershipsByTemplate[$templateDn]) { foreach ($id in $row.ResolvedVlanIds) { [void]$ids.Add($id) } }
            }
        }

        $serviceProfiles.Add([pscustomobject]@{
                Dn = $server.Dn
                Name = $server.Name
                AssocState = $server.AssocState
                Associated = ($server.AssocState -eq 'associated')
                PnDn = $server.PnDn
                Macs = [string[]]$macs
                TemplateDns = [string[]]$bound
                VlanIds = [int[]]@($ids | Sort-Object)
            })
    }

    # ---- VLAN groups, in-band management, native -------------------------------------------
    $groupMembers = New-Object System.Collections.Generic.List[object]
    if ($null -eq $PooledVlan) {
        $warnings.Add('VLAN group membership could not be read, so VLAN group members are not protected.')
    }
    else {
        foreach ($item in $PooledVlan) {
            $dn = [string](Get-PropertyValue $item 'Dn')
            $name = [string](Get-PropertyValue $item 'Name')
            $groupMembers.Add([pscustomobject]@{
                    GroupName = $(if ($dn -match 'net-group-([^/]+)') { $Matches[1] } else { '' })
                    VlanName = $name
                    VlanIds = [int[]]@($(if ($idsByName.ContainsKey($name)) { $idsByName[$name] | Sort-Object }))
                    Dn = $dn
                })
        }
    }

    $inbandIds = New-Object 'System.Collections.Generic.HashSet[int]'
    if ($null -eq $InbandProfile) {
        $warnings.Add('The in-band management profile could not be read, so its VLAN is not protected.')
    }
    else {
        foreach ($item in $InbandProfile) {
            $name = [string](Get-PropertyValue $item 'DefaultVlanName')
            if ($name -and $idsByName.ContainsKey($name)) { foreach ($id in $idsByName[$name]) { [void]$inbandIds.Add($id) } }
        }
    }

    $nativeIds = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($row in $vlans) { if ($row.Native) { [void]$nativeIds.Add($row.Id) } }
    foreach ($row in $etherIfs) { if ($row.Native) { foreach ($id in $row.ResolvedVlanIds) { [void]$nativeIds.Add($id) } } }

    [pscustomobject]@{
        Vlans = $vlans.ToArray()
        OtherVlanCount = $otherVlanCount
        VlanIndex = $vlanIndex
        VlanIdsByName = $idsByName
        Templates = $templates.ToArray()
        EtherIfs = $etherIfs.ToArray()
        Memberships = $memberships.ToArray()
        ServiceProfiles = $serviceProfiles.ToArray()
        TemplateBindings = $templateBindings
        VlanGroupMembers = $groupMembers.ToArray()
        InbandVlanIds = [int[]]@($inbandIds | Sort-Object)
        NativeVlanIds = [int[]]@($nativeIds | Sort-Object)
        Exceptions = $exceptions.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function Get-UcsVlanInventory {
    <#
    .SYNOPSIS
        Reads everything the VLAN audit and removal need from a connected UCS Manager domain.

    .DESCRIPTION
        One class query per object type, then ConvertTo-UcsVlanInventory. VLAN groups and the
        in-band profile are read best-effort; if either cannot be read the inventory carries a
        warning, because their VLANs then cannot be protected.

    .PARAMETER Ucs
        UCS Manager session from Connect-UcsWithTimeout.

    .EXAMPLE
        $inventory = Get-UcsVlanInventory -Ucs $ucs
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Ucs
    )
    $optional = @{}
    foreach ($classId in @('fabricPooledVlan', 'mgmtInbandProfile')) {
        try {
            $optional[$classId] = @(Get-UcsManagedObject -ClassId $classId -Ucs $Ucs -ErrorAction Stop)
        }
        catch {
            Write-RichoLog "Could not read $classId from UCS Manager: $($_.Exception.Message)" -Level WARN
            $optional[$classId] = $null
        }
    }
    $converted = @{
        Vlan = @(Get-UcsManagedObject -ClassId fabricVlan -Ucs $Ucs -ErrorAction Stop)
        VnicTemplate = @(Get-UcsManagedObject -ClassId vnicLanConnTempl -Ucs $Ucs -ErrorAction Stop)
        EtherIf = @(Get-UcsManagedObject -ClassId vnicEtherIf -Ucs $Ucs -ErrorAction Stop)
        Vnic = @(Get-UcsManagedObject -ClassId vnicEther -Ucs $Ucs -ErrorAction Stop)
        ServiceProfile = @(Get-UcsManagedObject -ClassId lsServer -Ucs $Ucs -ErrorAction Stop)
        PooledVlan = $optional['fabricPooledVlan']
        InbandProfile = $optional['mgmtInbandProfile']
    }
    ConvertTo-UcsVlanInventory @converted
}

function Get-TemplatePairAudit {
    <#
    .SYNOPSIS
        Compares the VLANs of paired vNIC templates (even number n with n+1, same base and org).

    .DESCRIPTION
        Unchanged rule from v7.5 - a pair should carry the same VLANs, names and native flags -
        with two fixes: templates in different orgs are no longer merged because they share a
        name, and an odd-numbered template with no even partner is reported, not skipped.

    .PARAMETER Template
        Templates from the inventory.

    .PARAMETER Membership
        Template memberships from the inventory.

    .EXAMPLE
        Get-TemplatePairAudit -Template $inventory.Templates -Membership $inventory.Memberships
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Template,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Membership
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $byTemplate = @{}
    foreach ($row in $Membership) {
        if (-not $byTemplate.ContainsKey($row.TemplateDn)) { $byTemplate[$row.TemplateDn] = New-Object System.Collections.Generic.List[object] }
        $byTemplate[$row.TemplateDn].Add($row)
    }

    $groups = @{}
    foreach ($item in $Template) {
        if ($item.Name -notmatch '^(.*?)(\d+)$') { continue }
        $org = if ($item.Dn.LastIndexOf('/') -gt 0) { $item.Dn.Substring(0, $item.Dn.LastIndexOf('/')) } else { '' }
        $key = "$org|$($Matches[1])"
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @{} }
        $groups[$key][[int]$Matches[2]] = $item
    }

    $missingPartner = {
        param($NameA, $NameB, $APresent)
        [pscustomobject]@{
            Pair = "$NameA / $NameB"; VLANID = ''; VLANName = ''
            PresentA = $(if ($APresent) { 'Yes' } else { 'No' }); PresentB = $(if ($APresent) { 'No' } else { 'Yes' })
            NativeA = ''; NativeB = ''; Result = 'DISCREPANCY'; Reason = 'Partner template missing'
        }
    }

    foreach ($key in @($groups.Keys | Sort-Object)) {
        $map = $groups[$key]
        $base = $key.Substring($key.IndexOf('|') + 1)
        foreach ($number in @($map.Keys | Sort-Object)) {
            if ($number % 2 -ne 0) {
                if (-not $map.ContainsKey($number - 1)) { $rows.Add((& $missingPartner "$base$($number - 1)" $map[$number].Name $false)) }
                continue
            }
            $a = $map[$number]
            if (-not $map.ContainsKey($number + 1)) {
                $rows.Add((& $missingPartner $a.Name "$base$($number + 1)" $true))
                continue
            }
            $b = $map[$number + 1]
            $am = @(if ($byTemplate.ContainsKey($a.Dn)) { $byTemplate[$a.Dn].ToArray() })
            $bm = @(if ($byTemplate.ContainsKey($b.Dn)) { $byTemplate[$b.Dn].ToArray() })
            $ids = @(ConvertTo-SortedIntArray -InputObject @(@($am) + @($bm) | ForEach-Object { $_.VLANID } | Where-Object { $_ -match '^\d+$' }))
            foreach ($id in $ids) {
                $ar = @($am | Where-Object { $_.VLANID -eq [string]$id })
                $br = @($bm | Where-Object { $_.VLANID -eq [string]$id })
                $nativeA = (@($ar | ForEach-Object { $_.NativeVLAN } | Sort-Object -Unique)) -join ','
                $nativeB = (@($br | ForEach-Object { $_.NativeVLAN } | Sort-Object -Unique)) -join ','
                $nameA = (@($ar | ForEach-Object { $_.VLANName } | Sort-Object -Unique)) -join '; '
                $nameB = (@($br | ForEach-Object { $_.VLANName } | Sort-Object -Unique)) -join '; '
                $reason = ''
                if ($ar.Count -eq 0) { $reason = "VLAN $id missing from $($a.Name)" }
                elseif ($br.Count -eq 0) { $reason = "VLAN $id missing from $($b.Name)" }
                elseif ($nameA -ne $nameB) { $reason = 'VLAN name differs' }
                elseif ($nativeA -ne $nativeB) { $reason = 'Native status differs' }
                $rows.Add([pscustomobject]@{
                        Pair = "$($a.Name) / $($b.Name)"
                        VLANID = $id
                        VLANName = (@(@($nameA, $nameB) | Where-Object { $_ } | Sort-Object -Unique)) -join ' / '
                        PresentA = $(if ($ar.Count -gt 0) { 'Yes' } else { 'No' })
                        PresentB = $(if ($br.Count -gt 0) { 'Yes' } else { 'No' })
                        NativeA = $nativeA
                        NativeB = $nativeB
                        Result = $(if ($reason) { 'DISCREPANCY' } else { 'MATCH' })
                        Reason = $(if ($reason) { $reason } else { 'Same VLAN, name, and native status' })
                    })
            }
        }
    }
    $rows.ToArray()
}

#endregion

#region vCenter

function Get-LldpSystemName {
    <#
    .SYNOPSIS
        The neighbour's system name from an LLDP hint, or ''.

    .DESCRIPTION
        Same rule as the firmware controller: the parameter key is matched loosely ('System Name',
        'SystemName', 'sysName' are all seen), and ChassisId is a fallback only when it is not a
        MAC, which is what a fabric interconnect usually sends.

    .PARAMETER LldpInfo
        LinkLayerDiscoveryProtocolInfo from QueryNetworkHint.

    .EXAMPLE
        Get-LldpSystemName -LldpInfo $hint.LldpInfo
    #>
    param(
        [AllowNull()]
        $LldpInfo
    )
    foreach ($parameter in @(Get-PropertyList $LldpInfo 'Parameter')) {
        if ([string](Get-PropertyValue $parameter 'Key') -notmatch '(?i)^\s*(system[\s_-]*name|sysname)\s*$') { continue }
        $value = [string](Get-PropertyValue $parameter 'Value')
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    $chassis = [string](Get-PropertyValue $LldpInfo 'ChassisId')
    if ([string]::IsNullOrWhiteSpace($chassis)) { return '' }
    if ($chassis -match '^([0-9a-fA-F]{2}[:\-\.]){5}[0-9a-fA-F]{2}$' -or $chassis -match '^[0-9a-fA-F]{12}$') { return '' }
    return $chassis.Trim()
}

function ConvertTo-DiscoveryText {
    <#
    .SYNOPSIS
        A CDP/LLDP value as trimmed text, decoding byte arrays and dropping NULs.

    .PARAMETER Value
        The raw value.

    .EXAMPLE
        ConvertTo-DiscoveryText -Value $hint.ConnectedSwitchPort.DevId
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    $text = if ($Value -is [byte[]]) { [Text.Encoding]::ASCII.GetString($Value) } else { [string]$Value }
    return $text.Replace([char]0, ' ').Trim()
}

function ConvertFrom-StandardVlanId {
    <#
    .SYNOPSIS
        Describes a standard port group VLAN ID: untagged, single, or guest tagging (4095).

    .PARAMETER VlanId
        The port group's VLAN ID.

    .EXAMPLE
        ConvertFrom-StandardVlanId -VlanId 4095
    #>
    param([int]$VlanId)
    if ($VlanId -eq 0) {
        return [pscustomobject]@{ Type = 'Untagged (VLAN 0)'; Display = '0'; VlanId = 0; ProtectIds = [int[]]@(); Resolved = $true }
    }
    if ($VlanId -eq 4095) {
        # Guest tagging: the VM chooses its VLANs, so every VLAN is potentially in use. v7.5
        # treated 4095 as an ordinary VLAN ID and protected nothing.
        return [pscustomobject]@{ Type = 'Guest tagging (VLAN 4095)'; Display = '4095 (all)'; VlanId = $null; ProtectIds = [int[]](1..4094); Resolved = $true }
    }
    return [pscustomobject]@{ Type = 'Single VLAN'; Display = [string]$VlanId; VlanId = $VlanId; ProtectIds = [int[]]@($VlanId); Resolved = $true }
}

function ConvertFrom-DvsVlanSpec {
    <#
    .SYNOPSIS
        Describes a distributed port group VLAN spec: single, trunk range, or PVLAN.

    .DESCRIPTION
        A trunk range protects every ID in it when the port group is in use, and a PVLAN protects
        both its secondary and primary IDs. v7.5 could only mark these unresolved, which made the
        whole run preliminary.

    .PARAMETER Spec
        DefaultPortConfig.Vlan of the port group.

    .PARAMETER PvlanMap
        Secondary-to-primary PVLAN map of the port group's switch.

    .EXAMPLE
        ConvertFrom-DvsVlanSpec -Spec $pg.Config.DefaultPortConfig.Vlan -PvlanMap $map
    #>
    param(
        [AllowNull()]$Spec,

        [hashtable]$PvlanMap = @{}
    )
    if (Test-TypeName $Spec 'VMware.Vim.VmwareDistributedVirtualSwitchTrunkVlanSpec') {
        $ids = New-Object 'System.Collections.Generic.HashSet[int]'
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($range in @(Get-PropertyList $Spec 'VlanId')) {
            $start = [int](Get-PropertyValue $range 'Start')
            $end = [int](Get-PropertyValue $range 'End')
            if ($start -eq $end) { $parts.Add([string]$start) } else { $parts.Add("$start-$end") }
            for ($n = [Math]::Max(1, $start); $n -le [Math]::Min(4094, $end); $n++) { [void]$ids.Add($n) }
        }
        return [pscustomobject]@{ Type = 'Trunk Range'; Display = ($parts -join ','); VlanId = $null; ProtectIds = [int[]]@($ids | Sort-Object); Resolved = $true }
    }
    if (Test-TypeName $Spec 'VMware.Vim.VmwareDistributedVirtualSwitchPvlanSpec') {
        $secondary = [int](Get-PropertyValue $Spec 'PvlanId')
        $ids = @($secondary)
        $display = "PVLAN $secondary"
        if ($PvlanMap.ContainsKey($secondary)) {
            $ids += [int]$PvlanMap[$secondary]
            $display += " (primary $($PvlanMap[$secondary]))"
        }
        return [pscustomobject]@{ Type = 'PVLAN'; Display = $display; VlanId = $null; ProtectIds = [int[]]@(ConvertTo-SortedIntArray $ids); Resolved = $true }
    }
    if (Test-TypeName $Spec 'VMware.Vim.VmwareDistributedVirtualSwitchVlanIdSpec') {
        return (ConvertFrom-StandardVlanId -VlanId ([int](Get-PropertyValue $Spec 'VlanId')))
    }
    $typeName = if ($null -eq $Spec) { 'none' } else { $Spec.GetType().Name }
    return [pscustomobject]@{ Type = "Unknown ($typeName)"; Display = 'Unknown'; VlanId = $null; ProtectIds = [int[]]@(); Resolved = $false }
}

function ConvertTo-NetworkRow {
    <#
    .SYNOPSIS
        One port group as the audit tracks it: identity, VLAN description, hosts and VMs.

    .PARAMETER Key
        Unique key, prefixed with the vCenter.

    .PARAMETER VCenter
        vCenter name.

    .PARAMETER Kind
        'Distributed' or 'Standard'.

    .PARAMETER Name
        Port group name.

    .PARAMETER Switch
        Switch name.

    .PARAMETER Vlan
        Output of ConvertFrom-DvsVlanSpec or ConvertFrom-StandardVlanId.

    .PARAMETER DisplayKey
        Key as shown in reports, without the vCenter prefix.

    .EXAMPLE
        ConvertTo-NetworkRow -Key $key -VCenter $vc -Kind Distributed -Name $pg.Name -Switch 'dvs1' -Vlan $vlan -DisplayKey $pg.Key
    #>
    param(
        [string]$Key,
        [string]$VCenter,
        [string]$Kind,
        [string]$Name,
        [string]$Switch,
        $Vlan,
        [string]$DisplayKey
    )
    [pscustomobject]@{
        Key = $Key
        DisplayKey = $DisplayKey
        vCenter = $VCenter
        Kind = $Kind
        Name = $Name
        Switch = $Switch
        VlanType = $Vlan.Type
        VlanDisplay = $Vlan.Display
        VlanId = $Vlan.VlanId
        ProtectIds = $Vlan.ProtectIds
        Resolved = $Vlan.Resolved
        HostKeys = (New-Object 'System.Collections.Generic.HashSet[string]')
        VmKeys = (New-Object 'System.Collections.Generic.HashSet[string]')
    }
}

function ConvertTo-FailureRow {
    <#
    .SYNOPSIS
        A collection failure, tagged with where it happened so scope can decide whether it matters.

    .PARAMETER VCenter
        vCenter name.

    .PARAMETER Target
        What failed.

    .PARAMETER Category
        Failure category.

    .PARAMETER Details
        What went wrong.

    .PARAMETER ClusterKey
        Cluster it belongs to, when known.

    .PARAMETER HostKey
        Host it belongs to, when known.

    .EXAMPLE
        ConvertTo-FailureRow -VCenter $vc -Target $vm.Name -Category 'UNRESOLVED NIC BACKING' -Details '...' -ClusterKey $c -HostKey $h
    #>
    param(
        [string]$VCenter,
        [string]$Target,
        [string]$Category,
        [string]$Details,
        [string]$ClusterKey = '',
        [string]$HostKey = ''
    )
    [pscustomobject]@{ vCenter = $VCenter; Target = $Target; Category = $Category; Details = $Details; ClusterKey = $ClusterKey; HostKey = $HostKey }
}

function ConvertTo-VCenterEvidence {
    <#
    .SYNOPSIS
        Turns the raw vCenter views into hosts, port groups, VM NIC and VMkernel usage, and CDP/LLDP rows.

    .DESCRIPTION
        Pure: takes the views, touches nothing. Every key is prefixed with the vCenter name,
        because managed object IDs are only unique within one vCenter and a run can scan several.

        VM templates are included. v7.5 counted with Get-VM, which leaves templates out, so a VLAN
        used only by a template looked unused.

    .PARAMETER VCenter
        vCenter name.

    .PARAMETER ComputeView
        ComputeResource views (clusters and standalone hosts).

    .PARAMETER HostView
        HostSystem views.

    .PARAMETER DvsView
        VmwareDistributedVirtualSwitch views.

    .PARAMETER PortgroupView
        DistributedVirtualPortgroup views.

    .PARAMETER VmView
        VirtualMachine views.

    .PARAMETER DiscoveryHint
        Hashtable of host key to @{ Hints; Error } from Get-HostDiscoveryHint.

    .PARAMETER AllowedUcsName
        The UCS Manager allowlist.

    .EXAMPLE
        ConvertTo-VCenterEvidence -VCenter $vc -ComputeView $c -HostView $h -DvsView $d -PortgroupView $p -VmView $v -DiscoveryHint $hints -AllowedUcsName $MasterUcsList
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VCenter,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ComputeView,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$HostView,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$DvsView,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PortgroupView,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$VmView,
        [Parameter(Mandatory)][hashtable]$DiscoveryHint,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedUcsName
    )
    $prefix = "$VCenter|"
    $failures = New-Object System.Collections.Generic.List[object]
    $hosts = New-Object System.Collections.Generic.List[object]
    $vmNics = New-Object System.Collections.Generic.List[object]
    $vmks = New-Object System.Collections.Generic.List[object]
    $discovery = New-Object System.Collections.Generic.List[object]
    $networks = @{}
    $clusterNames = @{}
    $hostCluster = @{}
    $standardByHost = @{}

    foreach ($compute in $ComputeView) { $clusterNames[$prefix + (Get-MoRefKey $compute.MoRef)] = [string]$compute.Name }

    # ---- Hosts: NIC MACs, standard port groups, VMkernel adapters, CDP/LLDP ------------------
    foreach ($view in $HostView) {
        $rawKey = Get-MoRefKey $view.MoRef
        $hostKey = $prefix + $rawKey
        $clusterKey = $prefix + (Get-MoRefKey (Get-PropertyValue $view 'Parent'))
        $cluster = if ($clusterNames.ContainsKey($clusterKey)) { $clusterNames[$clusterKey] } else { '(unknown)' }
        $hostName = [string]$view.Name
        $state = [string](Get-PropertyValue $view 'Runtime.ConnectionState')
        $hostCluster[$hostKey] = $clusterKey
        $standardByHost[$hostKey] = @{}

        if ($null -eq (Get-PropertyValue $view 'Config.Network')) {
            $failures.Add((ConvertTo-FailureRow -VCenter $VCenter -Target $hostName -Category 'HOST CONFIGURATION UNAVAILABLE' -Details "Host is '$state'; its NICs, port groups and VMkernel adapters cannot be read." -ClusterKey $clusterKey -HostKey $hostKey))
        }
        $macs = @(@(Get-PropertyList $view 'Config.Network.Pnic') | ForEach-Object { ConvertTo-MacAddress (Get-PropertyValue $_ 'Mac') } | Where-Object { $_ } | Sort-Object -Unique)

        foreach ($portgroup in @(Get-PropertyList $view 'Config.Network.Portgroup')) {
            $name = [string](Get-PropertyValue $portgroup 'Spec.Name')
            $vlanId = [int](Get-PropertyValue $portgroup 'Spec.VlanId')
            $key = "${prefix}std:$name|$vlanId"
            if (-not $networks.ContainsKey($key)) {
                $networks[$key] = ConvertTo-NetworkRow -Key $key -VCenter $VCenter -Kind 'Standard' -Name $name -Switch ([string](Get-PropertyValue $portgroup 'Spec.VswitchName')) -Vlan (ConvertFrom-StandardVlanId -VlanId $vlanId) -DisplayKey "STANDARD:$name"
            }
            [void]$networks[$key].HostKeys.Add($hostKey)
            $standardByHost[$hostKey][$name] = $key
        }

        foreach ($vnic in @(Get-PropertyList $view 'Config.Network.Vnic')) {
            $device = [string](Get-PropertyValue $vnic 'Device')
            $dvKey = [string](Get-PropertyValue $vnic 'Spec.DistributedVirtualPort.PortgroupKey')
            $standardName = [string](Get-PropertyValue $vnic 'Portgroup')
            $networkKey = ''
            if ($dvKey) { $networkKey = "${prefix}dv:$dvKey" }
            elseif ($standardByHost[$hostKey].ContainsKey($standardName)) { $networkKey = $standardByHost[$hostKey][$standardName] }
            if (-not $networkKey) {
                $failures.Add((ConvertTo-FailureRow -VCenter $VCenter -Target "$hostName/$device" -Category 'UNRESOLVED VMKERNEL PORT GROUP' -Details "Port group '$standardName' not found on the host." -ClusterKey $clusterKey -HostKey $hostKey))
            }
            $vmks.Add([pscustomobject]@{ HostKey = $hostKey; ClusterKey = $clusterKey; ESXiHost = $hostName; Device = $device; NetworkKey = $networkKey })
        }

        $ucsNames = New-Object 'System.Collections.Generic.HashSet[string]'
        $hint = $DiscoveryHint[$rawKey]
        $newRow = {
            param($Nic, $Protocol, $Text, $Ucs, $Classification)
            [pscustomobject]@{
                vCenter = $VCenter; Cluster = $cluster; ESXiHost = $hostName; PhysicalNic = $Nic; Protocol = $Protocol
                DiscoveredSystemName = $Text; UCSM = $Ucs; Classification = $Classification
            }
        }
        if ($null -eq $hint) {
            $discovery.Add((& $newRow '' '' '' '' 'NOT QUERIED'))
        }
        elseif ($hint.Error) {
            $discovery.Add((& $newRow '' '' '' '' 'DISCOVERY FAILED'))
            $failures.Add((ConvertTo-FailureRow -VCenter $VCenter -Target $hostName -Category 'CDP/LLDP DISCOVERY' -Details $hint.Error -ClusterKey $clusterKey -HostKey $hostKey))
        }
        else {
            foreach ($nicHint in @($hint.Hints)) {
                if ($null -eq $nicHint) { continue }
                $nic = [string](Get-PropertyValue $nicHint 'Device')
                $candidates = @(
                    [pscustomobject]@{ Protocol = 'CDP'; Text = (ConvertTo-DiscoveryText (Get-PropertyValue $nicHint 'ConnectedSwitchPort.SystemName')) }
                    [pscustomobject]@{ Protocol = 'CDP'; Text = (ConvertTo-DiscoveryText (Get-PropertyValue $nicHint 'ConnectedSwitchPort.DevId')) }
                    [pscustomobject]@{ Protocol = 'LLDP'; Text = (Get-LldpSystemName -LldpInfo (Get-PropertyValue $nicHint 'LldpInfo')) }
                )
                $seen = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($candidate in $candidates) {
                    if (-not $candidate.Text -or -not $seen.Add($candidate.Text)) { continue }
                    $ucs = ConvertTo-UcsDomainName -SystemName $candidate.Text -AllowedName $AllowedUcsName
                    if ($ucs) { [void]$ucsNames.Add($ucs) }
                    $discovery.Add((& $newRow $nic $candidate.Protocol $candidate.Text $ucs $(if ($ucs) { 'DIRECT UCSM' } else { 'IGNORED - NOT ALLOWLISTED' })))
                }
                if ($seen.Count -eq 0) { $discovery.Add((& $newRow $nic '' '' '' 'NO CDP/LLDP NEIGHBOUR')) }
            }
        }

        $hosts.Add([pscustomobject]@{
                vCenter = $VCenter
                HostKey = $hostKey
                ClusterKey = $clusterKey
                Cluster = $cluster
                ESXiHost = $hostName
                ConnectionState = $state
                Macs = [string[]]$macs
                DiscoveredUcsm = [string[]]@($ucsNames | Sort-Object)
            })
    }

    # ---- Distributed switches and port groups -----------------------------------------------
    $switchByKey = @{}
    foreach ($view in $DvsView) {
        $pvlan = @{}
        foreach ($entry in @(Get-PropertyList $view 'Config.PvlanConfig')) {
            $pvlan[[int](Get-PropertyValue $entry 'SecondaryVlanId')] = [int](Get-PropertyValue $entry 'PrimaryVlanId')
        }
        $switchByKey[$prefix + (Get-MoRefKey $view.MoRef)] = [pscustomobject]@{ Name = [string]$view.Name; Pvlan = $pvlan }
    }

    foreach ($view in $PortgroupView) {
        if ([bool](Get-PropertyValue $view 'Config.Uplink')) { continue }
        $pgKey = [string]$view.Key
        $key = "${prefix}dv:$pgKey"
        $switch = $switchByKey[$prefix + (Get-MoRefKey (Get-PropertyValue $view 'Config.DistributedVirtualSwitch'))]
        $pvlanMap = if ($null -ne $switch) { $switch.Pvlan } else { @{} }
        $switchName = if ($null -ne $switch) { $switch.Name } else { '' }
        $row = ConvertTo-NetworkRow -Key $key -VCenter $VCenter -Kind 'Distributed' -Name ([string]$view.Name) -Switch $switchName -Vlan (ConvertFrom-DvsVlanSpec -Spec (Get-PropertyValue $view 'Config.DefaultPortConfig.Vlan') -PvlanMap $pvlanMap) -DisplayKey $pgKey
        foreach ($reference in @(Get-PropertyList $view 'Host')) { [void]$row.HostKeys.Add($prefix + (Get-MoRefKey $reference)) }
        foreach ($reference in @(Get-PropertyList $view 'Vm')) { [void]$row.VmKeys.Add($prefix + (Get-MoRefKey $reference)) }
        $networks[$key] = $row
    }

    # ---- VM and template NIC backing --------------------------------------------------------
    foreach ($view in $VmView) {
        $vmKey = $prefix + (Get-MoRefKey $view.MoRef)
        $vmName = [string]$view.Name
        $hostReference = Get-PropertyValue $view 'Runtime.Host'
        $hostKey = if ($null -ne $hostReference) { $prefix + (Get-MoRefKey $hostReference) } else { '' }
        $clusterKey = if ($hostKey -and $hostCluster.ContainsKey($hostKey)) { $hostCluster[$hostKey] } else { '' }
        if ($null -eq (Get-PropertyValue $view 'Config')) {
            $failures.Add((ConvertTo-FailureRow -VCenter $VCenter -Target $vmName -Category 'VM CONFIGURATION UNAVAILABLE' -Details 'The VM configuration could not be read (inaccessible or orphaned), so its networks are unknown.' -ClusterKey $clusterKey -HostKey $hostKey))
            continue
        }
        $isTemplate = [bool](Get-PropertyValue $view 'Config.Template')
        $power = [string](Get-PropertyValue $view 'Runtime.PowerState')
        foreach ($device in @(Get-PropertyList $view 'Config.Hardware.Device')) {
            if (-not (Test-TypeName $device 'VMware.Vim.VirtualEthernetCard')) { continue }
            $backing = Get-PropertyValue $device 'Backing'
            $networkKey = ''
            if (Test-TypeName $backing 'VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo') {
                $networkKey = "${prefix}dv:$([string](Get-PropertyValue $backing 'Port.PortgroupKey'))"
            }
            elseif (Test-TypeName $backing 'VMware.Vim.VirtualEthernetCardNetworkBackingInfo') {
                $name = [string](Get-PropertyValue $backing 'DeviceName')
                if ($hostKey -and $standardByHost.ContainsKey($hostKey) -and $standardByHost[$hostKey].ContainsKey($name)) { $networkKey = $standardByHost[$hostKey][$name] }
            }
            if (-not $networkKey -or -not $networks.ContainsKey($networkKey)) {
                $label = [string](Get-PropertyValue $device 'DeviceInfo.Label')
                $backingType = if ($null -eq $backing) { 'none' } else { $backing.GetType().Name }
                $failures.Add((ConvertTo-FailureRow -VCenter $VCenter -Target "$vmName/$label" -Category 'UNRESOLVED NIC BACKING' -Details "Backing '$backingType' cannot be mapped to a port group and VLAN." -ClusterKey $clusterKey -HostKey $hostKey))
                $networkKey = ''
            }
            $vmNics.Add([pscustomobject]@{
                    VmKey = $vmKey
                    VmName = $vmName
                    HostKey = $hostKey
                    ClusterKey = $clusterKey
                    NetworkKey = $networkKey
                    Power = $power
                    Connected = [bool](Get-PropertyValue $device 'Connectable.Connected')
                    IsTemplate = $isTemplate
                })
        }
    }

    [pscustomobject]@{
        VCenters = [string[]]@($VCenter)
        Hosts = $hosts.ToArray()
        Networks = $networks
        VmNics = $vmNics.ToArray()
        Vmks = $vmks.ToArray()
        Discovery = $discovery.ToArray()
        Failures = $failures.ToArray()
        ClusterNames = $clusterNames
    }
}

function Merge-VCenterEvidence {
    <#
    .SYNOPSIS
        Combines the evidence of several vCenters into one.

    .PARAMETER Evidence
        Evidence objects from Get-VCenterEvidence.

    .EXAMPLE
        Merge-VCenterEvidence -Evidence @($a, $b)
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Evidence
    )
    $merged = [pscustomobject]@{
        VCenters = [string[]]@(); Hosts = @(); Networks = @{}; VmNics = @(); Vmks = @()
        Discovery = @(); Failures = @(); ClusterNames = @{}
    }
    foreach ($item in $Evidence) {
        $merged.VCenters = [string[]]@(@($merged.VCenters) + @($item.VCenters))
        foreach ($name in @('Hosts', 'VmNics', 'Vmks', 'Discovery', 'Failures')) {
            $merged.$name = @(@($merged.$name) + @($item.$name))
        }
        foreach ($key in $item.Networks.Keys) { $merged.Networks[$key] = $item.Networks[$key] }
        foreach ($key in $item.ClusterNames.Keys) { $merged.ClusterNames[$key] = $item.ClusterNames[$key] }
    }
    $merged
}

function Get-HostDiscoveryHint {
    <#
    .SYNOPSIS
        Asks each connected host for its CDP/LLDP neighbours - one QueryNetworkHint call per host.

    .PARAMETER Server
        The vCenter connection.

    .PARAMETER HostView
        HostSystem views.

    .EXAMPLE
        $hints = Get-HostDiscoveryHint -Server $vi -HostView $hostViews
    #>
    param(
        [Parameter(Mandatory)]
        $Server,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$HostView
    )
    $result = @{}
    $connected = New-Object System.Collections.Generic.List[object]
    foreach ($view in $HostView) {
        $state = [string](Get-PropertyValue $view 'Runtime.ConnectionState')
        if ($state -eq 'connected' -and $null -ne (Get-PropertyValue $view 'ConfigManager.NetworkSystem')) {
            $connected.Add($view)
        }
        else {
            $result[(Get-MoRefKey $view.MoRef)] = [pscustomobject]@{ Hints = @(); Error = "Host is '$state'; CDP/LLDP not queried." }
        }
    }
    if ($connected.Count -eq 0) { return $result }

    $networkSystems = @{}
    $references = @($connected | ForEach-Object { $_.ConfigManager.NetworkSystem })
    foreach ($view in @(Get-View -Server $Server -Id $references -Property Capabilities -ErrorAction Stop)) {
        $networkSystems[(Get-MoRefKey $view.MoRef)] = $view
    }

    $index = 0
    foreach ($view in $connected) {
        $index++
        Write-Progress -Activity 'Reading CDP/LLDP neighbours' -Status "$index of $($connected.Count): $($view.Name)" -PercentComplete ([int](100 * $index / $connected.Count))
        $key = Get-MoRefKey $view.MoRef
        try {
            $networkSystem = $networkSystems[(Get-MoRefKey $view.ConfigManager.NetworkSystem)]
            $devices = [string[]]@(@(Get-PropertyList $view 'Config.Network.Pnic') | ForEach-Object { [string]$_.Device })
            $result[$key] = [pscustomobject]@{ Hints = @($networkSystem.QueryNetworkHint($devices)); Error = '' }
        }
        catch {
            $result[$key] = [pscustomobject]@{ Hints = @(); Error = $_.Exception.Message }
        }
    }
    Write-Progress -Activity 'Reading CDP/LLDP neighbours' -Completed
    return $result
}

function Get-VCenterEvidence {
    <#
    .SYNOPSIS
        Collects hosts, port groups, VM NIC backing and VMkernel usage from one vCenter.

    .DESCRIPTION
        One login, and one property-collector call per object type with only the properties
        needed. v7.5 logged in twice per vCenter and made one or more calls per host, per VM and
        per distributed port group (Get-VM -RelatedObject). The one per-host call left is
        QueryNetworkHint for the CDP/LLDP cross-check.

        A vCenter that cannot be collected returns empty evidence carrying the failure, which
        makes the run's candidates preliminary.

    .PARAMETER Server
        vCenter FQDN.

    .PARAMETER Credential
        vCenter credential.

    .PARAMETER AllowedUcsName
        The UCS Manager allowlist.

    .EXAMPLE
        Get-VCenterEvidence -Server siepd24vsp0001.test -Credential $cred -AllowedUcsName $MasterUcsList
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedUcsName
    )
    $vi = $null
    try {
        Write-RichoLog "Collecting from vCenter $Server." -Level INFO
        $vi = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
        $read = @{ Server = $vi; ErrorAction = 'Stop' }
        $computeViews = @(Get-View @read -ViewType ComputeResource -Property 'Name')
        $hostViews = @(Get-View @read -ViewType HostSystem -Property 'Name', 'Parent', 'Runtime.ConnectionState', 'Config.Network.Pnic', 'Config.Network.Vnic', 'Config.Network.Portgroup', 'ConfigManager.NetworkSystem')
        $switchViews = @(Get-View @read -ViewType VmwareDistributedVirtualSwitch -Property 'Name', 'Config.PvlanConfig')
        $portgroupViews = @(Get-View @read -ViewType DistributedVirtualPortgroup -Property 'Name', 'Key', 'Config.DefaultPortConfig', 'Config.DistributedVirtualSwitch', 'Config.Uplink', 'Host', 'Vm')
        $vmViews = @(Get-View @read -ViewType VirtualMachine -Property 'Name', 'Runtime.PowerState', 'Runtime.Host', 'Config.Template', 'Config.Hardware.Device')
        Write-RichoLog ('{0}: {1} hosts, {2} distributed port groups, {3} VMs and templates.' -f $Server, $hostViews.Count, $portgroupViews.Count, $vmViews.Count) -Level INFO
        $hints = Get-HostDiscoveryHint -Server $vi -HostView $hostViews
        ConvertTo-VCenterEvidence -VCenter $Server -ComputeView $computeViews -HostView $hostViews -DvsView $switchViews -PortgroupView $portgroupViews -VmView $vmViews -DiscoveryHint $hints -AllowedUcsName $AllowedUcsName
    }
    catch {
        Write-RichoLog "vCenter $Server could not be collected: $($_.Exception.Message)" -Level WARN
        [pscustomobject]@{
            VCenters = [string[]]@($Server); Hosts = @(); Networks = @{}; VmNics = @(); Vmks = @(); Discovery = @(); ClusterNames = @{}
            Failures = @(ConvertTo-FailureRow -VCenter $Server -Target $Server -Category 'VCENTER COLLECTION' -Details $_.Exception.Message)
        }
    }
    finally {
        if ($null -ne $vi) { Disconnect-VIServer -Server $vi -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    }
}

#endregion

#region Analysis

function Get-AuditScope {
    <#
    .SYNOPSIS
        Matches service profiles to ESXi hosts and works out which clusters the domain serves.

    .DESCRIPTION
        A service profile is MATCHED when its vNIC MACs belong to exactly one scanned ESXi host.
        An associated profile that matches no host is UNMATCHED - bare metal, or ESXi in a vCenter
        that was not scanned - and every VLAN on its vNICs is protected. One that matches several
        hosts is AMBIGUOUS (overlapping MAC pools), which is protected and also a warning.

        In-scope hosts are the matched hosts plus any host whose CDP/LLDP names this domain; the
        in-scope clusters are theirs. Every host in those clusters is then checked: one that
        cannot be tied to any UCS domain, or whose MAC and CDP/LLDP evidence disagree, is a
        warning. A host on another allowlisted domain is not - the cluster spans domains, and its
        VMs are still counted because DRS can move them here.

        Collection failures in scope are warnings; failures on hosts and VMs outside it are kept
        for the record but do not affect the candidates. v7.5 let a failure anywhere in the
        vCenter make every candidate preliminary.

    .PARAMETER Inventory
        From Get-UcsVlanInventory.

    .PARAMETER Evidence
        From Get-VCenterEvidence / Merge-VCenterEvidence.

    .PARAMETER UcsName
        The audited domain's allowlisted name.

    .EXAMPLE
        $scope = Get-AuditScope -Inventory $inventory -Evidence $evidence -UcsName 'PD24000001SS101'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$UcsName
    )
    $warnings = New-Object System.Collections.Generic.List[string]
    $hostByKey = @{}
    $hostsByMac = @{}
    foreach ($item in $Evidence.Hosts) {
        $hostByKey[$item.HostKey] = $item
        foreach ($mac in $item.Macs) {
            if (-not $hostsByMac.ContainsKey($mac)) { $hostsByMac[$mac] = New-Object 'System.Collections.Generic.HashSet[string]' }
            [void]$hostsByMac[$mac].Add($item.HostKey)
        }
    }

    $matchedProfiles = New-Object 'System.Collections.Generic.HashSet[string]'
    $matchedHosts = New-Object 'System.Collections.Generic.HashSet[string]'
    $profilesByHost = @{}
    $protectedProfiles = New-Object System.Collections.Generic.List[object]
    $profileRows = New-Object System.Collections.Generic.List[object]
    foreach ($serviceProfile in $Inventory.ServiceProfiles) {
        $hits = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($mac in $serviceProfile.Macs) {
            if ($hostsByMac.ContainsKey($mac)) { foreach ($key in $hostsByMac[$mac]) { [void]$hits.Add($key) } }
        }
        $status = if (-not $serviceProfile.Associated) { 'UNASSOCIATED' }
        elseif ($hits.Count -eq 1) { 'MATCHED' }
        elseif ($hits.Count -gt 1) { 'AMBIGUOUS' }
        else { 'UNMATCHED' }

        $matchedHost = $null
        if ($hits.Count -eq 1) { $matchedHost = $hostByKey[@($hits)[0]] }
        if ($status -eq 'MATCHED') {
            [void]$matchedProfiles.Add($serviceProfile.Dn)
            [void]$matchedHosts.Add($matchedHost.HostKey)
            if (-not $profilesByHost.ContainsKey($matchedHost.HostKey)) { $profilesByHost[$matchedHost.HostKey] = New-Object System.Collections.Generic.List[string] }
            $profilesByHost[$matchedHost.HostKey].Add($serviceProfile.Name)
        }
        if ($status -in @('UNMATCHED', 'AMBIGUOUS')) { $protectedProfiles.Add($serviceProfile) }
        if ($status -eq 'AMBIGUOUS') {
            $warnings.Add("Service profile $($serviceProfile.Name) matches $($hits.Count) ESXi hosts by MAC; MAC pools overlap, so this match cannot be trusted.")
        }
        $profileRows.Add([pscustomobject]@{
                ServiceProfile = $serviceProfile.Name
                Dn = $serviceProfile.Dn
                AssocState = $serviceProfile.AssocState
                Server = $serviceProfile.PnDn
                Match = $status
                ESXiHost = $(if ($null -ne $matchedHost) { $matchedHost.ESXiHost } else { '' })
                vCenter = $(if ($null -ne $matchedHost) { $matchedHost.vCenter } else { '' })
                Cluster = $(if ($null -ne $matchedHost) { $matchedHost.Cluster } else { '' })
                VnicMacs = ($serviceProfile.Macs -join ', ')
                VLANs = (Format-IdList -Id $serviceProfile.VlanIds)
                VlansProtected = $(if ($status -in @('UNMATCHED', 'AMBIGUOUS')) { 'Yes - every VLAN on its vNICs' } else { 'No' })
            })
    }
    foreach ($key in @($profilesByHost.Keys)) {
        if ($profilesByHost[$key].Count -gt 1) {
            $warnings.Add("ESXi host $($hostByKey[$key].ESXiHost) matches several service profiles by MAC ($($profilesByHost[$key] -join ', ')).")
        }
    }

    $cdpHosts = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $Evidence.Hosts) { if ($item.DiscoveredUcsm -contains $UcsName) { [void]$cdpHosts.Add($item.HostKey) } }

    $inScopeHosts = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($key in $matchedHosts) { [void]$inScopeHosts.Add($key) }
    foreach ($key in $cdpHosts) { [void]$inScopeHosts.Add($key) }
    $inScopeClusters = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($key in $inScopeHosts) { [void]$inScopeClusters.Add($hostByKey[$key].ClusterKey) }
    $clusterHosts = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $Evidence.Hosts) { if ($inScopeClusters.Contains($item.ClusterKey)) { [void]$clusterHosts.Add($item.HostKey) } }

    $coverage = New-Object System.Collections.Generic.List[object]
    $unresolvedHosts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Evidence.Hosts | Where-Object { $clusterHosts.Contains($_.HostKey) } | Sort-Object vCenter, Cluster, ESXiHost)) {
        $byMac = $matchedHosts.Contains($item.HostKey)
        $byCdp = $cdpHosts.Contains($item.HostKey)
        $others = @($item.DiscoveredUcsm | Where-Object { $_ -ne $UcsName })
        $result = if ($byMac -and $byCdp) { 'MATCHED - MAC AND CDP/LLDP' }
        elseif ($byMac -and $others.Count -gt 0) { 'MAC AND CDP/LLDP DISAGREE' }
        elseif ($byMac) { 'MATCHED - MAC ONLY (no CDP/LLDP neighbour)' }
        elseif ($byCdp) { 'CDP/LLDP ONLY - NO SERVICE PROFILE MAC MATCH' }
        elseif ($others.Count -gt 0) { 'OTHER UCS DOMAIN' }
        else { 'UNRESOLVED' }
        if ($result -in @('MAC AND CDP/LLDP DISAGREE', 'CDP/LLDP ONLY - NO SERVICE PROFILE MAC MATCH', 'UNRESOLVED')) {
            $unresolvedHosts.Add("$($item.ESXiHost) ($result)")
        }
        $coverage.Add([pscustomobject]@{
                vCenter = $item.vCenter
                Cluster = $item.Cluster
                ESXiHost = $item.ESXiHost
                State = $item.ConnectionState
                ServiceProfile = $(if ($profilesByHost.ContainsKey($item.HostKey)) { $profilesByHost[$item.HostKey] -join ', ' } else { '' })
                CdpLldpDomains = ($item.DiscoveredUcsm -join ', ')
                Result = $result
            })
    }
    if ($unresolvedHosts.Count -gt 0) {
        $warnings.Add("$($unresolvedHosts.Count) host(s) in scope could not be tied to a UCS domain consistently: $(@($unresolvedHosts | Select-Object -First 10) -join '; ')$(if ($unresolvedHosts.Count -gt 10) { '; ...' }).")
    }
    if ($inScopeHosts.Count -eq 0) {
        $warnings.Add("No ESXi host on $UcsName was found in the scanned vCenter(s), by MAC or by CDP/LLDP.")
    }

    $scoped = New-Object System.Collections.Generic.List[object]
    $outOfScope = New-Object System.Collections.Generic.List[object]
    foreach ($failure in $Evidence.Failures) {
        $vCenterWide = -not $failure.ClusterKey -and -not $failure.HostKey
        $relevant = $vCenterWide -or ($failure.ClusterKey -and $inScopeClusters.Contains($failure.ClusterKey)) -or ($failure.HostKey -and $clusterHosts.Contains($failure.HostKey))
        if ($relevant) { $scoped.Add($failure) } else { $outOfScope.Add($failure) }
    }
    if ($scoped.Count -gt 0) {
        $categories = @($scoped | Group-Object Category | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
        $warnings.Add("$($scoped.Count) collection failure(s) in scope ($categories). See the Exceptions sheet.")
    }

    [pscustomobject]@{
        UcsName = $UcsName
        InScopeHostKeys = $inScopeHosts
        InScopeClusterKeys = $inScopeClusters
        ClusterHostKeys = $clusterHosts
        ClusterNames = [string[]]@($inScopeClusters | ForEach-Object { $Evidence.ClusterNames[$_] } | Where-Object { $_ } | Sort-Object -Unique)
        MatchedServiceProfileDns = [string[]]@($matchedProfiles | Sort-Object)
        ProtectedServiceProfiles = $protectedProfiles.ToArray()
        AssociatedCount = @($Inventory.ServiceProfiles | Where-Object { $_.Associated }).Count
        MatchedCount = $matchedProfiles.Count
        HostCoverage = $coverage.ToArray()
        ServiceProfileMapping = $profileRows.ToArray()
        ScopedFailures = $scoped.ToArray()
        OutOfScopeFailures = $outOfScope.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function Get-NetworkUsage {
    <#
    .SYNOPSIS
        Works out which VLAN IDs the in-scope clusters use, and how.

    .DESCRIPTION
        Considers every port group present on a host in an in-scope cluster. Usage is:
          - VMs and VM templates in an in-scope cluster on the port group (CollectedVMCount);
          - for a distributed port group, VMs anywhere in the vCenter on it (vCenterReportedVMCount);
          - VMkernel adapters on it, on any scanned host.
        A single-VLAN port group in use puts its ID in ClusterVmVlans / VmkernelVlans. A trunk,
        guest-tagging or PVLAN port group in use protects every ID it covers.

    .PARAMETER Evidence
        Merged vCenter evidence.

    .PARAMETER Scope
        From Get-AuditScope.

    .EXAMPLE
        $usage = Get-NetworkUsage -Evidence $evidence -Scope $scope
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]$Scope
    )
    $warnings = New-Object System.Collections.Generic.List[string]
    $nicsByNetwork = @{}
    foreach ($nic in $Evidence.VmNics) {
        if (-not $nic.NetworkKey) { continue }
        if (-not $nicsByNetwork.ContainsKey($nic.NetworkKey)) { $nicsByNetwork[$nic.NetworkKey] = New-Object System.Collections.Generic.List[object] }
        $nicsByNetwork[$nic.NetworkKey].Add($nic)
    }
    $vmksByNetwork = @{}
    foreach ($vmk in $Evidence.Vmks) {
        if (-not $vmk.NetworkKey) { continue }
        if (-not $vmksByNetwork.ContainsKey($vmk.NetworkKey)) { $vmksByNetwork[$vmk.NetworkKey] = New-Object System.Collections.Generic.List[object] }
        $vmksByNetwork[$vmk.NetworkKey].Add($vmk)
    }
    $hostsByCluster = @{}
    foreach ($item in $Evidence.Hosts) {
        if (-not $Scope.InScopeClusterKeys.Contains($item.ClusterKey)) { continue }
        if (-not $hostsByCluster.ContainsKey($item.ClusterKey)) { $hostsByCluster[$item.ClusterKey] = New-Object 'System.Collections.Generic.HashSet[string]' }
        [void]$hostsByCluster[$item.ClusterKey].Add($item.HostKey)
    }

    $relevant = @(foreach ($network in $Evidence.Networks.Values) {
            foreach ($key in $network.HostKeys) {
                if ($Scope.ClusterHostKeys.Contains($key)) {
                    $network
                    break
                }
            }
        })
    $relevant = @($relevant | Sort-Object vCenter, Kind, Switch, Name)

    $clusterVm = New-Object 'System.Collections.Generic.HashSet[int]'
    $vmkernel = New-Object 'System.Collections.Generic.HashSet[int]'
    $range = New-Object 'System.Collections.Generic.HashSet[int]'
    $rangeSources = New-Object System.Collections.Generic.List[object]
    $zeroVm = New-Object System.Collections.Generic.List[object]
    $untagged = New-Object System.Collections.Generic.List[object]
    $usageByKey = @{}

    foreach ($network in $relevant) {
        $nics = @(if ($nicsByNetwork.ContainsKey($network.Key)) { $nicsByNetwork[$network.Key].ToArray() })
        $vmkCount = if ($vmksByNetwork.ContainsKey($network.Key)) { $vmksByNetwork[$network.Key].Count } else { 0 }
        $scopedVms = New-Object 'System.Collections.Generic.HashSet[string]'
        $globalVms = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($nic in $nics) {
            [void]$globalVms.Add($nic.VmKey)
            if ($Scope.InScopeClusterKeys.Contains($nic.ClusterKey)) { [void]$scopedVms.Add($nic.VmKey) }
        }
        if ($network.Kind -eq 'Distributed') { foreach ($vmKey in $network.VmKeys) { [void]$globalVms.Add($vmKey) } }
        $used = $scopedVms.Count -gt 0 -or $globalVms.Count -gt 0
        $usageByKey[$network.Key] = [pscustomobject]@{ Scoped = $scopedVms.Count; Global = $globalVms.Count; Vmk = $vmkCount }

        if ($null -ne $network.VlanId -and $network.VlanId -gt 0) {
            if ($used) { [void]$clusterVm.Add($network.VlanId) }
            if ($vmkCount -gt 0) { [void]$vmkernel.Add($network.VlanId) }
            if ($network.Kind -eq 'Distributed' -and -not $used) {
                $clusters = @($hostsByCluster.Keys | Where-Object { $set = $hostsByCluster[$_]; @($network.HostKeys | Where-Object { $set.Contains($_) }).Count -gt 0 } |
                        ForEach-Object { $Evidence.ClusterNames[$_] } | Sort-Object -Unique)
                $zeroVm.Add([pscustomobject]@{
                        vCenter = $network.vCenter
                        Cluster = ($clusters -join '; ')
                        Switch = $network.Switch
                        PortGroup = $network.Name
                        PortGroupKey = $network.DisplayKey
                        VLANID = $network.VlanId
                        vCenterReportedVMCount = $globalVms.Count
                        CollectedVMCount = $scopedVms.Count
                        VMkernelCount = $vmkCount
                    })
            }
        }
        elseif ($network.VlanId -eq 0) {
            if ($used -or $vmkCount -gt 0) { $untagged.Add($network) }
        }
        elseif ($used -or $vmkCount -gt 0) {
            foreach ($id in $network.ProtectIds) { [void]$range.Add($id) }
            $rangeSources.Add([pscustomobject]@{ PortGroup = $network.Name; Switch = $network.Switch; VLAN = $network.VlanDisplay; VLANType = $network.VlanType })
            if (-not $network.Resolved) {
                $warnings.Add("Port group '$($network.Name)' on '$($network.Switch)' is in use but its VLAN configuration ($($network.VlanType)) could not be read.")
            }
        }
    }

    # Per-cluster rows, as v7.5 reported them.
    $portGroupRows = New-Object System.Collections.Generic.List[object]
    foreach ($clusterKey in @($hostsByCluster.Keys | Sort-Object { $Evidence.ClusterNames[$_] })) {
        $clusterHostSet = $hostsByCluster[$clusterKey]
        foreach ($network in $relevant) {
            if (@($network.HostKeys | Where-Object { $clusterHostSet.Contains($_) }).Count -eq 0) { continue }
            $nics = @(if ($nicsByNetwork.ContainsKey($network.Key)) { $nicsByNetwork[$network.Key] | Where-Object { $_.ClusterKey -eq $clusterKey } })
            $distinct = { param($Rows) @($Rows | ForEach-Object { $_.VmKey } | Sort-Object -Unique).Count }
            $vmkHere = @(if ($vmksByNetwork.ContainsKey($network.Key)) { $vmksByNetwork[$network.Key] | Where-Object { $clusterHostSet.Contains($_.HostKey) } }).Count
            $status = if (-not $network.Resolved) { 'UNRESOLVED VLAN TYPE' }
            elseif ($network.VlanType -in @('Trunk Range', 'PVLAN', 'Guest tagging (VLAN 4095)')) { 'RANGE - EVERY ID PROTECTED WHEN IN USE' }
            else { 'MATCHED' }
            $portGroupRows.Add([pscustomobject]@{
                    vCenter = $network.vCenter
                    Cluster = $Evidence.ClusterNames[$clusterKey]
                    NetworkType = $network.Kind
                    Switch = $network.Switch
                    PortGroup = $network.Name
                    PortGroupKey = $network.DisplayKey
                    VLANID = $(if ($null -ne $network.VlanId) { [string]$network.VlanId } else { '' })
                    VLAN = $network.VlanDisplay
                    VLANType = $network.VlanType
                    vCenterReportedVMCount = $usageByKey[$network.Key].Global
                    CollectedVMCount = (& $distinct $nics)
                    PoweredOnConnected = (& $distinct @($nics | Where-Object { $_.Power -eq 'poweredOn' -and $_.Connected }))
                    PoweredOnDisconnected = (& $distinct @($nics | Where-Object { $_.Power -eq 'poweredOn' -and -not $_.Connected }))
                    PoweredOff = (& $distinct @($nics | Where-Object { $_.Power -eq 'poweredOff' -and -not $_.IsTemplate }))
                    Suspended = (& $distinct @($nics | Where-Object { $_.Power -eq 'suspended' }))
                    Templates = (& $distinct @($nics | Where-Object { $_.IsTemplate }))
                    VMkernelCount = $vmkHere
                    UsageMappingStatus = $status
                })
        }
    }

    [pscustomobject]@{
        Relevant = $relevant
        ClusterVmVlans = [int[]]@($clusterVm | Sort-Object)
        VmkernelVlans = [int[]]@($vmkernel | Sort-Object)
        RangeProtected = [int[]]@($range | Sort-Object)
        RangeSources = $rangeSources.ToArray()
        ZeroVmRows = $zeroVm.ToArray()
        UntaggedInUse = $untagged.ToArray()
        PortGroupRows = $portGroupRows.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function Get-VlanAuditResult {
    <#
    .SYNOPSIS
        Classifies every LAN Cloud VLAN and builds the report sheets and the removal manifest.

    .DESCRIPTION
        Pure: no prompts, no I/O. Same classifications and sheet names as v7.5 so existing
        reviews read the same, plus the protections and evidence described in the script help.

        A DR VLAN missing from the LAN Cloud is still reported (DR Coverage, Summary) but no longer
        makes the cleanup candidates preliminary: a missing VLAN cannot be deleted, so it says
        nothing about whether the candidates are safe.

    .PARAMETER Inventory
        From Get-UcsVlanInventory.

    .PARAMETER Evidence
        Merged vCenter evidence.

    .PARAMETER Scope
        From Get-AuditScope.

    .PARAMETER Usage
        From Get-NetworkUsage.

    .PARAMETER PairAudit
        From Get-TemplatePairAudit.

    .PARAMETER Confirmation
        Operator answers: DrConfig, PhysicalVlanIds, PhysicalConfirmed, NativeManualVlanIds,
        NativeConfirmed, SpecialVlanIds, ScopeConfirmed.

    .PARAMETER UcsServer
        The name UCS Manager was connected by.

    .PARAMETER GeneratedUtc
        Run time, for the manifest.

    .EXAMPLE
        Get-VlanAuditResult -Inventory $i -Evidence $e -Scope $s -Usage $u -PairAudit $p -Confirmation $c -UcsServer $t -GeneratedUtc (Get-Date).ToUniversalTime()
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]$Scope,
        [Parameter(Mandatory)]$Usage,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PairAudit,
        [Parameter(Mandatory)]$Confirmation,
        [Parameter(Mandatory)][string]$UcsServer,
        [Parameter(Mandatory)][datetime]$GeneratedUtc
    )
    $ucsName = $Scope.UcsName
    $dr = $Confirmation.DrConfig
    $toSet = {
        param($Values)
        $set = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($value in @($Values)) { if ($null -ne $value -and [int]$value -ge 2 -and [int]$value -le 4094) { [void]$set.Add([int]$value) } }
        , $set
    }

    $cloudSet = & $toSet @($Inventory.Vlans | ForEach-Object { $_.Id })
    $templateSet = & $toSet @($Inventory.Memberships | ForEach-Object { $_.ResolvedVlanIds })
    $clusterVmSet = & $toSet $Usage.ClusterVmVlans
    $vmkernelSet = & $toSet $Usage.VmkernelVlans
    $rangeSet = & $toSet $Usage.RangeProtected
    $drSet = & $toSet $dr.DrVlans
    $physicalSet = & $toSet $Confirmation.PhysicalVlanIds
    $specialSet = & $toSet $Confirmation.SpecialVlanIds
    $nativeSet = & $toSet @(@($Inventory.NativeVlanIds) + @($Confirmation.NativeManualVlanIds))
    $profileSet = & $toSet @($Scope.ProtectedServiceProfiles | ForEach-Object { $_.VlanIds })
    $groupSet = & $toSet @($Inventory.VlanGroupMembers | ForEach-Object { $_.VlanIds })
    $inbandSet = & $toSet $Inventory.InbandVlanIds

    $requiredSet = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($set in @($clusterVmSet, $vmkernelSet, $drSet, $physicalSet, $specialSet, $nativeSet)) { $requiredSet.UnionWith($set) }
    $protectedSet = New-Object 'System.Collections.Generic.HashSet[int]' -ArgumentList (, $requiredSet)
    foreach ($set in @($rangeSet, $profileSet, $groupSet, $inbandSet)) { $protectedSet.UnionWith($set) }

    $candidateIds = @($cloudSet | Where-Object { -not $protectedSet.Contains($_) } | Sort-Object)
    $missingIds = @($requiredSet | Where-Object { -not $cloudSet.Contains($_) } | Sort-Object)
    $drMissing = @($drSet | Where-Object { -not $cloudSet.Contains($_) } | Sort-Object)

    # ---- Warnings: anything here makes every candidate preliminary ---------------------------
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($text in @($Inventory.Warnings) + @($Scope.Warnings) + @($Usage.Warnings)) { if ($text) { $warnings.Add($text) } }
    if (-not $Confirmation.ScopeConfirmed) { $warnings.Add('The operator did not confirm that every ESXi host on the domain is in the scanned vCenter(s).') }
    if (-not $Confirmation.PhysicalConfirmed) { $warnings.Add('Non-VCP physical VLANs were not confirmed.') }
    if (-not $Confirmation.NativeConfirmed) { $warnings.Add('Native/untagged VLAN coverage was not confirmed.') }
    if ($dr.Side -in @('DR', 'Both') -and $drSet.Count -eq 0) { $warnings.Add('The domain is on the DR side but no DR VLAN list is protecting it.') }
    $preliminary = $warnings.Count -gt 0
    $candidateLabel = if ($preliminary) { 'PRELIMINARY UCSM CLEANUP CANDIDATE' } else { 'UCSM CLEANUP CANDIDATE' }

    # ---- Lookups ----------------------------------------------------------------------------
    $vlansById = @{}
    foreach ($row in $Inventory.Vlans) {
        if (-not $vlansById.ContainsKey($row.Id)) { $vlansById[$row.Id] = New-Object System.Collections.Generic.List[object] }
        $vlansById[$row.Id].Add($row)
    }
    $membershipsById = @{}
    foreach ($row in $Inventory.Memberships) {
        foreach ($id in $row.ResolvedVlanIds) {
            if (-not $membershipsById.ContainsKey($id)) { $membershipsById[$id] = New-Object System.Collections.Generic.List[object] }
            $membershipsById[$id].Add($row)
        }
    }
    $directById = @{}
    foreach ($row in $Inventory.EtherIfs) {
        if ($row.OwnerType -eq 'VnicTemplate' -or $row.ViaTemplate) { continue }
        foreach ($id in $row.ResolvedVlanIds) {
            if (-not $directById.ContainsKey($id)) { $directById[$id] = New-Object System.Collections.Generic.List[object] }
            $directById[$id].Add($row)
        }
    }
    $namesOf = { param($Id) if ($vlansById.ContainsKey($Id)) { (@($vlansById[$Id] | ForEach-Object { $_.Name } | Sort-Object -Unique)) -join '; ' } else { '' } }
    $countOf = { param($Table, $Id) if ($Table.ContainsKey($Id)) { $Table[$Id].Count } else { 0 } }

    # ---- vCenter zero-VM port groups ---------------------------------------------------------
    $zeroVmCandidates = @(foreach ($row in $Usage.ZeroVmRows) {
            $id = [int]$row.VLANID
            $reasons = New-Object System.Collections.Generic.List[string]
            if ($row.VMkernelCount -gt 0 -or $vmkernelSet.Contains($id)) { $reasons.Add('VMkernel') }
            if ($drSet.Contains($id)) { $reasons.Add('DR') }
            if ($specialSet.Contains($id)) { $reasons.Add('Build/DHCP/Reserved/Manual') }
            if ($nativeSet.Contains($id)) { $reasons.Add('Native/untagged') }
            if ($rangeSet.Contains($id)) { $reasons.Add('Trunk/PVLAN/guest-tagging port group in use') }
            if ($id -eq 1) { $reasons.Add('Default VLAN 1') }
            $isCandidate = $reasons.Count -eq 0
            [pscustomobject]@{
                vCenter = $row.vCenter
                Cluster = $row.Cluster
                Switch = $row.Switch
                PortGroup = $row.PortGroup
                VLANID = $id
                vCenterReportedVMCount = $row.vCenterReportedVMCount
                CollectedVMCount = $row.CollectedVMCount
                VMkernelCount = $row.VMkernelCount
                ProtectedReason = ($reasons -join '; ')
                vCenterClassification = $(if (-not $isCandidate) { 'PROTECTED / NOT CANDIDATE' } elseif ($preliminary) { 'PRELIMINARY VCENTER CLEANUP CANDIDATE' } else { 'VCENTER CLEANUP CANDIDATE' })
            }
        })
    $zeroVmById = @{}
    foreach ($row in $zeroVmCandidates) {
        if ($row.vCenterClassification -notlike '*CLEANUP CANDIDATE') { continue }
        if (-not $zeroVmById.ContainsKey($row.VLANID)) { $zeroVmById[$row.VLANID] = 0 }
        $zeroVmById[$row.VLANID]++
    }

    # ---- Final comparison --------------------------------------------------------------------
    $allIds = New-Object 'System.Collections.Generic.HashSet[int]' -ArgumentList (, $cloudSet)
    $allIds.UnionWith($requiredSet)
    $candidateSet = & $toSet $candidateIds
    $final = @(foreach ($id in @($allIds | Sort-Object)) {
            $sources = New-Object System.Collections.Generic.List[string]
            if ($clusterVmSet.Contains($id)) { $sources.Add('Cluster VM') }
            if ($vmkernelSet.Contains($id)) { $sources.Add('VMkernel') }
            if ($rangeSet.Contains($id)) { $sources.Add('Trunk/PVLAN/guest-tagging port group') }
            if ($profileSet.Contains($id)) { $sources.Add('Unmatched service profile') }
            if ($groupSet.Contains($id)) { $sources.Add('VLAN group') }
            if ($inbandSet.Contains($id)) { $sources.Add('In-band management') }
            if ($drSet.Contains($id)) { $sources.Add('DR') }
            if ($physicalSet.Contains($id)) { $sources.Add('Physical manual') }
            if ($specialSet.Contains($id)) { $sources.Add('Build/DHCP/Reserved/Manual') }
            if ($nativeSet.Contains($id)) { $sources.Add('Native/untagged') }
            $inCloud = $cloudSet.Contains($id)
            $isCandidate = $candidateSet.Contains($id)
            $zeroCount = if ($zeroVmById.ContainsKey($id)) { $zeroVmById[$id] } else { 0 }
            $prefix = if ($preliminary) { 'PRELIMINARY ' } else { '' }
            [pscustomobject]@{
                VLANID = $id
                VLANName = (& $namesOf $id)
                InLANCloud = $(if ($inCloud) { 'Yes' } else { 'No' })
                InAnyVnicTemplate = $(if ($templateSet.Contains($id)) { 'Yes' } else { 'No' })
                TemplateMemberships = (& $countOf $membershipsById $id)
                DirectVnicReferences = (& $countOf $directById $id)
                ClusterVMUsage = $(if ($clusterVmSet.Contains($id)) { 'Yes' } else { 'No' })
                VMkernelUsage = $(if ($vmkernelSet.Contains($id)) { 'Yes' } else { 'No' })
                RangeProtected = $(if ($rangeSet.Contains($id)) { 'Yes' } else { 'No' })
                UnmatchedProfile = $(if ($profileSet.Contains($id)) { 'Yes' } else { 'No' })
                DRProtected = $(if ($drSet.Contains($id)) { 'Yes' } else { 'No' })
                PhysicalProtected = $(if ($physicalSet.Contains($id)) { 'Yes' } else { 'No' })
                SpecialProtected = $(if ($specialSet.Contains($id)) { 'Yes' } else { 'No' })
                NativeProtected = $(if ($nativeSet.Contains($id)) { 'Yes' } else { 'No' })
                RequirementSources = ($sources -join '; ')
                UCSMClassification = $(if (-not $inCloud) { 'MISSING FROM UCSM LAN CLOUD' } elseif ($isCandidate) { $candidateLabel } else { 'REQUIRED / PROTECTED' })
                MatchingZeroVMPortGroups = $zeroCount
                CombinedReview = $(if ($isCandidate -and $zeroCount -gt 0) { "${prefix}REVIEW BOTH VCENTER AND UCSM" } elseif ($isCandidate) { "${prefix}REVIEW UCSM ONLY" } elseif ($zeroCount -gt 0) { "${prefix}REVIEW VCENTER PORT GROUP ONLY" } else { 'KEEP' })
            }
        })

    $lanCloudValidation = @(foreach ($id in @($cloudSet | Sort-Object)) {
            [pscustomobject]@{
                VLANID = $id
                VLANName = (& $namesOf $id)
                PresentInAnyVnicTemplate = $(if ($templateSet.Contains($id)) { 'Yes' } else { 'No' })
                DirectVnicReferences = (& $countOf $directById $id)
                Validation = $(if ($templateSet.Contains($id)) { 'PRESENT IN TEMPLATE' } elseif ((& $countOf $directById $id) -gt 0) { 'NOT IN ANY TEMPLATE - USED DIRECTLY ON A vNIC' } else { 'HIGHLIGHT - NOT PRESENT IN ANY TEMPLATE' })
            }
        })

    $drCoverage = @(foreach ($id in @($drSet | Sort-Object)) {
            [pscustomobject]@{ VLANID = $id; InLANCloud = $cloudSet.Contains($id); Result = $(if ($cloudSet.Contains($id)) { 'DR COVERED' } else { 'DR MISSING FROM LAN CLOUD' }) }
        })

    $clusterSummary = @($Usage.PortGroupRows | Where-Object { $_.VLANID -match '^\d+$' -and [int]$_.VLANID -ne 0 } | Group-Object Cluster, VLANID | ForEach-Object {
            $rows = @($_.Group)
            $sum = { param($Name) ($rows | Measure-Object -Property $Name -Sum).Sum }
            [pscustomobject]@{
                Cluster = $rows[0].Cluster
                VLANID = [int]$rows[0].VLANID
                PortGroups = (@($rows | ForEach-Object { $_.PortGroup } | Sort-Object -Unique)) -join '; '
                vCenterReportedVMCount = (& $sum 'vCenterReportedVMCount')
                CollectedVMCount = (& $sum 'CollectedVMCount')
                PoweredOnConnected = (& $sum 'PoweredOnConnected')
                PoweredOnDisconnected = (& $sum 'PoweredOnDisconnected')
                PoweredOff = (& $sum 'PoweredOff')
                Suspended = (& $sum 'Suspended')
                Templates = (& $sum 'Templates')
                VMkernel = (& $sum 'VMkernelCount')
                DRProtected = $(if ($drSet.Contains([int]$rows[0].VLANID)) { 'Yes' } else { 'No' })
            }
        } | Sort-Object Cluster, VLANID)

    $exceptions = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Inventory.Exceptions) { $exceptions.Add([pscustomobject]@{ Target = $row.Target; Category = "UCSM - $($row.Category)"; Details = $row.Details }) }
    foreach ($row in $Scope.ScopedFailures) { $exceptions.Add([pscustomobject]@{ Target = "$($row.vCenter): $($row.Target)"; Category = $row.Category; Details = $row.Details }) }
    foreach ($row in $Scope.OutOfScopeFailures) { $exceptions.Add([pscustomobject]@{ Target = "$($row.vCenter): $($row.Target)"; Category = "OUT OF SCOPE - $($row.Category)"; Details = "$($row.Details) Not on this domain's clusters; does not affect the candidates." }) }
    foreach ($network in $Usage.UntaggedInUse) { $exceptions.Add([pscustomobject]@{ Target = "$($network.vCenter): $($network.Switch)/$($network.Name)"; Category = 'VLAN 0 / UNTAGGED'; Details = 'In use untagged - covered only by the native VLAN confirmation.' }) }

    $confirmations = @(
        [pscustomobject]@{ Category = 'Cluster/UCSM coverage'; Confirmed = $Confirmation.ScopeConfirmed; VLANIDs = 'Not applicable'; Count = $Scope.MatchedCount }
        [pscustomobject]@{ Category = 'Non-VCP physical'; Confirmed = $Confirmation.PhysicalConfirmed; VLANIDs = (Format-IdList -Id $Confirmation.PhysicalVlanIds); Count = $physicalSet.Count }
        [pscustomobject]@{ Category = 'Native/untagged'; Confirmed = $Confirmation.NativeConfirmed; VLANIDs = (Format-IdList -Id @($nativeSet)); Count = $nativeSet.Count }
        [pscustomobject]@{ Category = 'Build/DHCP/reserved/manual'; Confirmed = $true; VLANIDs = (Format-IdList -Id $Confirmation.SpecialVlanIds); Count = $specialSet.Count }
    )

    $zeroVmCandidateCount = @($zeroVmCandidates | Where-Object { $_.vCenterClassification -like '*CLEANUP CANDIDATE' }).Count
    $candidateStatus = if ($preliminary) { "NOT VALIDATED - $($warnings.Count) WARNING(S)" } else { "$($candidateIds.Count) UCSM candidate(s)" }
    $overall = if ($preliminary) { 'WARNING - DO NOT USE FOR DELETION' } else { 'COMPLETE' }
    $summary = @([pscustomobject]@{
            UCSM = $ucsName
            Side = $dr.Side
            vCenters = ($Evidence.VCenters -join '; ')
            InScopeClusters = ($Scope.ClusterNames -join '; ')
            AssociatedServiceProfiles = $Scope.AssociatedCount
            MatchedToESXi = $Scope.MatchedCount
            UnmatchedProtected = $Scope.ProtectedServiceProfiles.Count
            ScopeConfirmed = $Confirmation.ScopeConfirmed
            DRSource = $dr.DrSource
            LANCloudVLANs = $cloudSet.Count
            LANCloudNotInAnyTemplate = @($lanCloudValidation | Where-Object { $_.PresentInAnyVnicTemplate -eq 'No' }).Count
            ClusterVMVLANs = $clusterVmSet.Count
            VMkernelVLANs = $vmkernelSet.Count
            RangeProtectedVLANs = $rangeSet.Count
            UnmatchedProfileVLANs = $profileSet.Count
            PhysicalVLANs = $physicalSet.Count
            SpecialProtectedVLANs = $specialSet.Count
            MissingRequiredFromLANCloud = $missingIds.Count
            DRMissingFromLANCloud = $drMissing.Count
            UCSMCleanupCandidates = $candidateIds.Count
            ZeroVMPortGroups = $Usage.ZeroVmRows.Count
            vCenterCleanupCandidates = $zeroVmCandidateCount
            Warnings = $warnings.Count
            CandidateStatus = $candidateStatus
            Overall = $overall
            ScriptVersion = $ScriptVersion
        })

    $finalHeaders = @('VLANID', 'VLANName', 'InLANCloud', 'InAnyVnicTemplate', 'TemplateMemberships', 'DirectVnicReferences', 'ClusterVMUsage', 'VMkernelUsage', 'RangeProtected', 'UnmatchedProfile', 'DRProtected', 'PhysicalProtected', 'SpecialProtected', 'NativeProtected', 'RequirementSources', 'UCSMClassification', 'MatchingZeroVMPortGroups', 'CombinedReview')
    $warningRows = @($warnings | ForEach-Object { [pscustomobject]@{ Warning = $_ } })
    $sheets = @(
        [pscustomobject]@{ Name = 'Executive Summary'; Rows = $summary; Headers = @($summary[0].PSObject.Properties | ForEach-Object { $_.Name }) }
        [pscustomobject]@{ Name = 'Warnings'; Rows = $warningRows; Headers = @('Warning') }
        [pscustomobject]@{ Name = 'LAN Cloud Validation'; Rows = $lanCloudValidation; Headers = @('VLANID', 'VLANName', 'PresentInAnyVnicTemplate', 'DirectVnicReferences', 'Validation') }
        [pscustomobject]@{ Name = 'Template Pair Audit'; Rows = $PairAudit; Headers = @('Pair', 'VLANID', 'VLANName', 'PresentA', 'PresentB', 'NativeA', 'NativeB', 'Result', 'Reason') }
        [pscustomobject]@{ Name = 'Template Memberships'; Rows = $Inventory.Memberships; Headers = @('Template', 'TemplateType', 'Fabric', 'VLANName', 'VLANID', 'NativeVLAN', 'TemplateDn') }
        [pscustomobject]@{ Name = 'Service Profile Mapping'; Rows = $Scope.ServiceProfileMapping; Headers = @('ServiceProfile', 'AssocState', 'Server', 'Match', 'ESXiHost', 'vCenter', 'Cluster', 'VnicMacs', 'VLANs', 'VlansProtected', 'Dn') }
        [pscustomobject]@{ Name = 'Host Coverage'; Rows = $Scope.HostCoverage; Headers = @('vCenter', 'Cluster', 'ESXiHost', 'State', 'ServiceProfile', 'CdpLldpDomains', 'Result') }
        [pscustomobject]@{ Name = 'Cluster VLAN Evidence'; Rows = $clusterSummary; Headers = @('Cluster', 'VLANID', 'PortGroups', 'vCenterReportedVMCount', 'CollectedVMCount', 'PoweredOnConnected', 'PoweredOnDisconnected', 'PoweredOff', 'Suspended', 'Templates', 'VMkernel', 'DRProtected') }
        [pscustomobject]@{ Name = 'Range Port Groups'; Rows = $Usage.RangeSources; Headers = @('PortGroup', 'Switch', 'VLAN', 'VLANType') }
        [pscustomobject]@{ Name = 'vCenter Zero VM'; Rows = $zeroVmCandidates; Headers = @('vCenter', 'Cluster', 'Switch', 'PortGroup', 'VLANID', 'vCenterReportedVMCount', 'CollectedVMCount', 'VMkernelCount', 'ProtectedReason', 'vCenterClassification') }
        [pscustomobject]@{ Name = 'Final Comparison'; Rows = $final; Headers = $finalHeaders }
        [pscustomobject]@{ Name = 'UCSM Candidates'; Rows = @($final | Where-Object { $_.UCSMClassification -like '*CLEANUP CANDIDATE' }); Headers = $finalHeaders }
        [pscustomobject]@{ Name = 'Combined Candidates'; Rows = @($final | Where-Object { $_.CombinedReview -like '*BOTH*' }); Headers = $finalHeaders }
        [pscustomobject]@{ Name = 'DR Coverage'; Rows = $drCoverage; Headers = @('VLANID', 'InLANCloud', 'Result') }
        [pscustomobject]@{ Name = 'Manual Confirmations'; Rows = $confirmations; Headers = @('Category', 'Confirmed', 'VLANIDs', 'Count') }
        [pscustomobject]@{ Name = 'Port Group Evidence'; Rows = $Usage.PortGroupRows; Headers = @('vCenter', 'Cluster', 'NetworkType', 'Switch', 'PortGroup', 'PortGroupKey', 'VLANID', 'VLAN', 'VLANType', 'vCenterReportedVMCount', 'CollectedVMCount', 'PoweredOnConnected', 'PoweredOnDisconnected', 'PoweredOff', 'Suspended', 'Templates', 'VMkernelCount', 'UsageMappingStatus') }
        [pscustomobject]@{ Name = 'CDP Evidence'; Rows = $Evidence.Discovery; Headers = @('vCenter', 'Cluster', 'ESXiHost', 'PhysicalNic', 'Protocol', 'DiscoveredSystemName', 'UCSM', 'Classification') }
        [pscustomobject]@{ Name = 'Exceptions'; Rows = $exceptions.ToArray(); Headers = @('Target', 'Category', 'Details') }
    )

    $manifest = [ordered]@{
        ManifestVersion = 1
        ScriptVersion = $ScriptVersion
        GeneratedUtc = $GeneratedUtc.ToUniversalTime().ToString('o')
        UCSM = $ucsName
        UcsServer = $UcsServer
        vCenters = [string[]]$Evidence.VCenters
        Overall = $overall
        Warnings = [string[]]$warnings.ToArray()
        MatchedServiceProfileDns = [string[]]$Scope.MatchedServiceProfileDns
        Candidates = @(foreach ($id in $candidateIds) {
                [ordered]@{
                    VlanId = $id
                    Classification = $candidateLabel
                    DirectVnicReferences = (& $countOf $directById $id)
                    LanCloudVlans = @(if ($vlansById.ContainsKey($id)) {
                            foreach ($row in $vlansById[$id]) { [ordered]@{ Dn = $row.Dn; Name = $row.Name; Fabric = $row.Fabric; Sharing = $row.Sharing } }
                        })
                    TemplateMemberships = @(if ($membershipsById.ContainsKey($id)) {
                            foreach ($row in $membershipsById[$id]) {
                                [ordered]@{
                                    TemplateDn = $row.TemplateDn
                                    TemplateName = $row.Template
                                    TemplateType = $row.TemplateType
                                    Fabric = $row.Fabric
                                    VlanName = $row.VLANName
                                    EtherIfDn = $row.EtherIfDn
                                    Native = ($row.NativeVLAN -eq 'Yes')
                                    ResolvedVlanIds = [int[]]$row.ResolvedVlanIds
                                }
                            }
                        })
                }
            })
    }

    [pscustomobject]@{
        Sheets = $sheets
        Manifest = $manifest
        Warnings = $warnings.ToArray()
        CandidateIds = [int[]]$candidateIds
        MissingIds = [int[]]$missingIds
        Overall = $overall
        CandidateStatus = $candidateStatus
    }
}

#endregion

#region Reports

function ConvertTo-CellValue {
    <#
    .SYNOPSIS
        A value as it should land in a report cell: numbers stay numbers, collections are joined.

    .PARAMETER Value
        The value.

    .EXAMPLE
        ConvertTo-CellValue -Value @(1, 2)
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $text = (@($Value | ForEach-Object { [string]$_ })) -join '; '
    }
    else {
        $text = [string]$Value
    }
    # Excel's cell limit is 32,767 characters.
    if ($text.Length -gt 32000) { $text = $text.Substring(0, 32000) + ' [truncated]' }
    return $text
}

function ConvertTo-CellMatrix {
    <#
    .SYNOPSIS
        Builds the two-dimensional array a worksheet is filled from in one call.

    .DESCRIPTION
        v7.5 set every cell with its own COM call, which on the evidence sheets ran to tens of
        thousands of calls. Assigning one array to Range.Value2 is a single call.

        TextColumn marks columns holding anything non-numeric. Those are formatted as text before
        the write, so Excel stores '100-110' or '1/2' as typed instead of turning it into a date.

    .PARAMETER Row
        Report rows.

    .PARAMETER Header
        Column order.

    .EXAMPLE
        $cells = ConvertTo-CellMatrix -Row $rows -Header $headers
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Header
    )
    $matrix = New-Object 'object[,]' ([Math]::Max(1, $Row.Count) + 1), $Header.Count
    $textColumn = New-Object 'bool[]' $Header.Count
    for ($c = 0; $c -lt $Header.Count; $c++) { $matrix[0, $c] = $Header[$c] }
    for ($r = 0; $r -lt $Row.Count; $r++) {
        for ($c = 0; $c -lt $Header.Count; $c++) {
            $value = ConvertTo-CellValue -Value (Get-PropertyValue -InputObject $Row[$r] -Path $Header[$c])
            if ($value -is [string] -and $value -ne '') { $textColumn[$c] = $true }
            $matrix[($r + 1), $c] = $value
        }
    }
    [pscustomobject]@{ Matrix = $matrix; TextColumn = $textColumn }
}

function Clear-ComReference {
    <#
    .SYNOPSIS
        Releases a COM object so Excel can exit.

    .PARAMETER InputObject
        The COM object. $null is ignored.

    .EXAMPLE
        Clear-ComReference -InputObject $range
    #>
    param([AllowNull()]$InputObject)
    if ($null -ne $InputObject) {
        try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($InputObject) } catch { Write-Verbose "COM release failed: $($_.Exception.Message)" }
    }
}

function Test-ExcelAvailable {
    <#
    .SYNOPSIS
        True when Excel is registered for COM on this host.

    .DESCRIPTION
        Looks the ProgID up. v7.5 started Excel and quit it just to find out.

    .EXAMPLE
        Test-ExcelAvailable
    #>
    try { return ($null -ne [type]::GetTypeFromProgID('Excel.Application')) } catch { return $false }
}

function Export-ExcelWorkbook {
    <#
    .SYNOPSIS
        Writes all report sheets into one workbook through Excel COM.

    .PARAMETER Path
        Workbook path (.xlsx).

    .PARAMETER Sheet
        Sheet definitions: Name, Rows, Headers.

    .EXAMPLE
        Export-ExcelWorkbook -Path $file -Sheet $result.Sheets
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sheet
    )
    $excel = $null
    $workbook = $null
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $excel.ScreenUpdating = $false
        $workbook = $excel.Workbooks.Add()
        while ($workbook.Worksheets.Count -lt $Sheet.Count) { [void]$workbook.Worksheets.Add() }
        while ($workbook.Worksheets.Count -gt $Sheet.Count) { $workbook.Worksheets.Item($workbook.Worksheets.Count).Delete() }

        for ($i = 0; $i -lt $Sheet.Count; $i++) {
            $worksheet = $workbook.Worksheets.Item($i + 1)
            $range = $null
            $headerRange = $null
            try {
                $worksheet.Name = $Sheet[$i].Name
                $cells = ConvertTo-CellMatrix -Row @($Sheet[$i].Rows) -Header $Sheet[$i].Headers
                $rowCount = $cells.Matrix.GetLength(0)
                $columnCount = $cells.Matrix.GetLength(1)
                for ($c = 0; $c -lt $columnCount; $c++) {
                    if (-not $cells.TextColumn[$c]) { continue }
                    $column = $worksheet.Columns.Item($c + 1)
                    $column.NumberFormat = '@'
                    Clear-ComReference $column
                }
                $range = $worksheet.Range($worksheet.Cells.Item(1, 1), $worksheet.Cells.Item($rowCount, $columnCount))
                $range.Value2 = $cells.Matrix
                $headerRange = $worksheet.Range($worksheet.Cells.Item(1, 1), $worksheet.Cells.Item(1, $columnCount))
                $headerRange.Font.Bold = $true
                $headerRange.Font.Color = 16777215
                $headerRange.Interior.Color = 10040064
                $range.AutoFilter() | Out-Null
                $worksheet.Columns.AutoFit() | Out-Null
            }
            finally {
                Clear-ComReference $headerRange
                Clear-ComReference $range
                Clear-ComReference $worksheet
            }
        }

        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        $workbook.SaveAs($Path, 51)
    }
    finally {
        if ($null -ne $workbook) {
            $workbook.Close($false)
            Clear-ComReference $workbook
        }
        if ($null -ne $excel) {
            $excel.Quit()
            Clear-ComReference $excel
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Export-ReportCsv {
    <#
    .SYNOPSIS
        Writes one report sheet as CSV, with a blank placeholder row when it is empty.

    .PARAMETER Path
        CSV path.

    .PARAMETER Row
        Report rows.

    .PARAMETER Header
        Column order.

    .EXAMPLE
        Export-ReportCsv -Path $file -Row $rows -Header $headers
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Header
    )
    $output = @(foreach ($item in $Row) {
            $record = [ordered]@{}
            foreach ($name in $Header) { $record[$name] = ConvertTo-CellValue -Value (Get-PropertyValue -InputObject $item -Path $name) }
            [pscustomobject]$record
        })
    if ($output.Count -eq 0) {
        $record = [ordered]@{}
        foreach ($name in $Header) { $record[$name] = '' }
        $output = @([pscustomobject]$record)
    }
    $output | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Force
}

function Export-AuditReport {
    <#
    .SYNOPSIS
        Writes the workbook and/or CSVs, and always the removal manifest.

    .PARAMETER Folder
        Output folder for this domain's run.

    .PARAMETER BaseName
        File name stem.

    .PARAMETER Result
        From Get-VlanAuditResult.

    .PARAMETER ReportFormat
        Excel, CSV, Both or Auto.

    .PARAMETER ExcelAvailable
        Whether Excel COM is usable.

    .EXAMPLE
        Export-AuditReport -Folder $folder -BaseName $base -Result $result -ReportFormat Auto -ExcelAvailable $true
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$ReportFormat,
        [Parameter(Mandatory)][bool]$ExcelAvailable
    )
    $wantCsv = $ReportFormat -in @('CSV', 'Both', 'Auto')
    $wantExcel = $ReportFormat -in @('Excel', 'Both') -or ($ReportFormat -eq 'Auto' -and $ExcelAvailable)
    if ($wantExcel) {
        if ($ExcelAvailable) {
            try {
                $workbookPath = Join-Path $Folder "$BaseName.xlsx"
                Export-ExcelWorkbook -Path $workbookPath -Sheet $Result.Sheets
                Write-RichoLog "Workbook written: $workbookPath" -Level INFO
            }
            catch {
                Write-RichoLog "Excel export failed ($($_.Exception.Message)); writing CSV instead." -Level WARN
                $wantCsv = $true
            }
        }
        else {
            Write-RichoLog 'Excel is not available on this host; writing CSV instead.' -Level WARN
            $wantCsv = $true
        }
    }
    if ($wantCsv) {
        $index = 0
        foreach ($definition in $Result.Sheets) {
            $index++
            Write-Progress -Activity 'Writing audit reports' -Status $definition.Name -PercentComplete ([int](100 * $index / $Result.Sheets.Count))
            Export-ReportCsv -Path (Join-Path $Folder ('{0:d2}_{1}.csv' -f $index, ($definition.Name -replace ' ', '-'))) -Row @($definition.Rows) -Header $definition.Headers
        }
        Write-Progress -Activity 'Writing audit reports' -Completed
        Write-RichoLog "CSV reports written to $Folder" -Level INFO
    }
    $manifestPath = Join-Path $Folder 'candidates.json'
    ConvertTo-Json -InputObject $Result.Manifest -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-RichoLog "Removal manifest written: $manifestPath" -Level INFO
}

#endregion

#region Orchestration

function Invoke-UcsVlanAudit {
    <#
    .SYNOPSIS
        Audits one UCS Manager domain end to end: read, ask, analyse, report.

    .PARAMETER Target
        Domain name or FQDN.

    .PARAMETER UcsCredential
        UCS Manager credential.

    .PARAMETER VCenterCredential
        vCenter credential.

    .PARAMETER VCenter
        vCenters to scan; prompted for when empty.

    .PARAMETER ReportFormat
        Excel, CSV, Both or Auto.

    .PARAMETER OutputRoot
        Parent folder for the report folder.

    .PARAMETER ExcelAvailable
        Whether Excel COM is usable.

    .PARAMETER TimeoutSeconds
        UCS Manager login timeout.

    .EXAMPLE
        Invoke-UcsVlanAudit -Target PD24000001SS101 -UcsCredential $u -VCenterCredential $v -ReportFormat Auto -OutputRoot $out -ExcelAvailable $true
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][pscredential]$UcsCredential,
        [Parameter(Mandatory)][pscredential]$VCenterCredential,
        [AllowEmptyCollection()][string[]]$VCenter = @(),
        [Parameter(Mandatory)][string]$ReportFormat,
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][bool]$ExcelAvailable,
        [int]$TimeoutSeconds = 60
    )
    $ucsName = (($Target -split '\.')[0]).ToUpperInvariant()
    if ($MasterUcsList -notcontains $ucsName) { throw "$Target is not in the UCS Manager allowlist. No login was attempted." }
    $generated = (Get-Date).ToUniversalTime()

    Write-RichoLog "[$ucsName] Reading UCS Manager $Target." -Level INFO
    $ucs = $null
    try {
        $ucs = Connect-UcsWithTimeout -Server $Target -Credential $UcsCredential -TimeoutSeconds $TimeoutSeconds
        $inventory = Get-UcsVlanInventory -Ucs $ucs
    }
    finally {
        if ($null -ne $ucs) { Disconnect-Ucs -Ucs $ucs -ErrorAction SilentlyContinue | Out-Null }
    }
    Write-RichoLog ('[{0}] LAN Cloud VLANs: {1} | vNIC templates: {2} | template memberships: {3} | service profiles: {4} ({5} associated)' -f $ucsName, $inventory.Vlans.Count, $inventory.Templates.Count, $inventory.Memberships.Count, $inventory.ServiceProfiles.Count, @($inventory.ServiceProfiles | Where-Object { $_.Associated }).Count) -Level INFO

    $drConfig = Read-DrConfiguration -EmbeddedList $EmbeddedDrVlans
    $pairAudit = @(Get-TemplatePairAudit -Template $inventory.Templates -Membership $inventory.Memberships)

    $vcenters = @($VCenter | Where-Object { $_ })
    if ($vcenters.Count -eq 0) {
        $vcenters = @(Read-TargetSelection -Item $MasterVCenterList -Title "Select the vCenter(s) with ESXi hosts on $ucsName - include every one" -AllowManual)
    }
    if ($vcenters.Count -eq 0) {
        Write-RichoLog "[$ucsName] No vCenter selected; audit of this domain abandoned." -Level WARN
        return
    }
    $vcenters = @($vcenters | ForEach-Object { if ($_ -notmatch '\.') { $_ + $DefaultDomainSuffix } else { $_ } } | Sort-Object -Unique)

    $evidence = Merge-VCenterEvidence -Evidence @(foreach ($server in $vcenters) { Get-VCenterEvidence -Server $server -Credential $VCenterCredential -AllowedUcsName $MasterUcsList })
    $scope = Get-AuditScope -Inventory $inventory -Evidence $evidence -UcsName $ucsName
    $usage = Get-NetworkUsage -Evidence $evidence -Scope $scope

    $unmatchedVlans = @($scope.ProtectedServiceProfiles | ForEach-Object { $_.VlanIds })
    $scopeChoice = Read-MenuChoice -Title 'SCOPE CONFIRMATION' -Context @(
        "vCenters scanned: $($vcenters -join ', ')",
        "Clusters with hosts on ${ucsName}: $(if ($scope.ClusterNames.Count) { $scope.ClusterNames -join ', ' } else { '(none)' })",
        "Associated service profiles: $($scope.AssociatedCount) | matched to scanned ESXi hosts by MAC: $($scope.MatchedCount) | unmatched, every VLAN protected: $($scope.ProtectedServiceProfiles.Count)",
        "Scope warnings so far: $($scope.Warnings.Count)") -Option @(
        'CONFIRMED - every ESXi host on this domain is in the scanned vCenter(s)',
        'UNKNOWN / INCOMPLETE - keep candidates preliminary')

    $physicalChoice = Read-MenuChoice -Title 'NON-VCP PHYSICAL VLAN CONFIRMATION' -Context @(
        "VLANs on the $($scope.ProtectedServiceProfiles.Count) unmatched service profile(s) are already protected: $(Format-IdList -Id $unmatchedVlans)",
        'Add any other physical-server VLANs that must stay on this domain.') -Option @(
        'ENTER additional confirmed physical VLAN IDs',
        'CONFIRM there are no other non-VCP physical VLANs',
        'UNKNOWN - keep candidates preliminary')
    $physicalIds = @()
    if ($physicalChoice -eq 1) { $physicalIds = @(Read-VlanIdList -Heading 'Confirmed physical-server VLAN IDs') }
    $physicalConfirmed = $physicalChoice -eq 2 -or ($physicalChoice -eq 1 -and $physicalIds.Count -gt 0)

    $nativeChoice = Read-MenuChoice -Title 'NATIVE / UNTAGGED VLAN CONFIRMATION' -Context @(
        "Native VLANs found on vNICs, templates and the LAN Cloud: $(Format-IdList -Id $inventory.NativeVlanIds)",
        "Port groups in use untagged (VLAN 0): $($usage.UntaggedInUse.Count). VLAN 0 is not an upstream VLAN ID.") -Option @(
        'CONFIRM the list covers ALL untagged/host networks',
        'ADD the actual upstream native/untagged VLAN IDs and confirm',
        'UNKNOWN - keep candidates preliminary')
    $nativeManual = @()
    if ($nativeChoice -eq 2) { $nativeManual = @(Read-VlanIdList -Heading 'Actual upstream VLAN IDs for untagged networks (not VLAN 0)') }

    $specialChoice = Read-MenuChoice -Title 'BUILD / DHCP / RESERVED VLANS' -Context @(
        "Zero-VM distributed port groups on this domain's clusters: $($usage.ZeroVmRows.Count) (listed in the report).",
        'Enter build, DHCP/PXE, reserved or other VLAN IDs that must be kept.') -Option @(
        'ADD protected VLAN IDs',
        'NO manual protection for this run')
    $specialIds = @()
    if ($specialChoice -eq 1) { $specialIds = @(Read-VlanIdList -Heading 'Build, DHCP/PXE, reserved or manually protected VLAN IDs') }

    $confirmation = [pscustomobject]@{
        DrConfig = $drConfig
        ScopeConfirmed = ($scopeChoice -eq 1)
        PhysicalVlanIds = [int[]]$physicalIds
        PhysicalConfirmed = $physicalConfirmed
        NativeManualVlanIds = [int[]]$nativeManual
        NativeConfirmed = ($nativeChoice -ne 3)
        SpecialVlanIds = [int[]]$specialIds
    }
    $result = Get-VlanAuditResult -Inventory $inventory -Evidence $evidence -Scope $scope -Usage $usage -PairAudit $pairAudit -Confirmation $confirmation -UcsServer $Target -GeneratedUtc $generated

    $stamp = $generated.ToLocalTime().ToString('yyyy-MM-dd_HHmmss')
    $baseName = "${ucsName}_VLAN-Audit_$stamp"
    $folder = Join-Path $OutputRoot $baseName
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
    Export-AuditReport -Folder $folder -BaseName $baseName -Result $result -ReportFormat $ReportFormat -ExcelAvailable $ExcelAvailable

    foreach ($text in $result.Warnings) { Write-RichoLog "[$ucsName] WARNING: $text" -Level WARN }
    Write-RichoLog "[$ucsName] Missing required VLANs: $($result.MissingIds.Count) | Candidates: $(Format-IdList -Id $result.CandidateIds) | $($result.CandidateStatus) | $($result.Overall)" -Level INFO
}

#endregion

#region Main

Import-RequiredModules
$transcriptPath = if ($Transcript) { Start-RichoTranscript } else { $null }

try {
    Write-RichoLog "Get-UcsVlanAudit $ScriptVersion - READ ONLY. Nothing on UCS Manager or vCenter is changed." -Level INFO
    foreach ($command in @('Connect-Ucs', 'Disconnect-Ucs', 'Get-UcsManagedObject', 'Connect-VIServer', 'Disconnect-VIServer', 'Get-View')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) { throw "Required command '$command' is not available in this session." }
    }

    if (-not $UcsCredential) { $UcsCredential = Get-RichoCredential -Name $UcsCredentialName }
    if (-not $VCenterCredential) { $VCenterCredential = Get-RichoCredential -Name $VCenterCredentialName }
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'output/ucs-vlan-audit' }

    $format = $ReportFormat
    if (-not $format) {
        $format = @('Excel', 'CSV', 'Both', 'Auto')[(Read-MenuChoice -Title 'REPORT OUTPUT' -Option @(
                'Consolidated Excel workbook only',
                'CSV reports only',
                'Consolidated Excel workbook and CSV reports',
                'Automatic: Excel and CSV when Excel is available, otherwise CSV')) - 1]
    }
    $excelAvailable = ($format -ne 'CSV') -and (Test-ExcelAvailable)

    $interactive = -not $UcsDomain
    do {
        # @() outside the if: an if-expression unrolls a one-element array to a bare string, and
        # StrictMode then rejects .Count on it - which ended a single -UcsDomain run in an error.
        $targets = @(if ($interactive) { Read-TargetSelection -Item $MasterUcsList -Title 'Select UCS Manager domain(s) to audit' -AllowManual } else { $UcsDomain })
        $failed = New-Object System.Collections.Generic.List[object]
        foreach ($target in $targets) {
            try {
                Invoke-UcsVlanAudit -Target $target -UcsCredential $UcsCredential -VCenterCredential $VCenterCredential -VCenter @($VCenter | Where-Object { $_ }) -ReportFormat $format -OutputRoot $OutputDirectory -ExcelAvailable $excelAvailable -TimeoutSeconds $ConnectionTimeoutSeconds
            }
            catch {
                $failed.Add([pscustomobject]@{ Target = $target; Error = $_.Exception.Message })
                Write-RichoLog "Audit of $target failed: $($_.Exception.Message)" -Level WARN
            }
        }
        Write-RichoLog "Run complete. Domains: $($targets.Count); failed: $($failed.Count)." -Level INFO
        $again = $interactive -and $targets.Count -gt 0 -and ((Read-MenuChoice -Title 'NEXT' -Option @('Audit another domain', 'Exit')) -eq 1)
    } while ($again)

    Write-RichoLog 'Finished. No infrastructure configuration was changed.' -Level INFO
}
catch {
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}

#endregion
