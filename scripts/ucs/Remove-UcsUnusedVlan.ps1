<#
.SYNOPSIS
    Removes audited, approved, unused VLANs from UCS Manager vNIC templates and then the LAN Cloud.

.DESCRIPTION
    CHANGES UCS MANAGER. The removal half of the monthly VLAN review: Get-UcsVlanAudit.ps1 finds
    the candidates and writes candidates.json; a person reviews the report and approves specific
    VLAN IDs; this script removes exactly those, and nothing it cannot re-prove is safe.

    Refused outright, before any login:
      - an audit whose result was not COMPLETE, or that carried any warning (preliminary
        candidates are never removed);
      - an audit older than -MaxManifestAgeDays;
      - any requested VLAN ID that is not a cleanup candidate in that audit.

    Then re-checked against the live domain, per VLAN, before anything is touched:
      - the LAN Cloud definitions and template memberships are still the ones the audit saw;
      - it is not native anywhere, not in-band management;
      - each template it is removed from is used only by service profiles the audit matched to an
        ESXi host, none of which has a pending reboot acknowledgement;
      - a VLAN name on a template that could also mean a VLAN not approved is left alone.

    Order, which matters (Cisco's guidance, and the reason for the faults F0933 raises): vNIC
    templates first; then, for an updating template, wait for the change to reach every bound
    service profile; then delete the LAN Cloud VLAN only if nothing - no template, service
    profile vNIC, LAN connectivity policy or VLAN group - still references it.

    The run stops before the LAN Cloud stage if UCS Manager raises a pending reboot
    acknowledgement for any bound service profile. It never acknowledges one.

    -WhatIf changes nothing and still writes the plan, so it is the dry run. Without -Confirm:$false
    every removal is confirmed individually (Yes to All is offered). Before any change the run
    writes plan.csv, snapshot.json (the live objects it is about to remove) and rollback.ps1.

.PARAMETER ManifestPath
    The audit's candidates.json, or the audit folder that contains it.

.PARAMETER VlanId
    The VLAN IDs approved for removal. Each must be a cleanup candidate in the manifest.

.PARAMETER Stage
    Both (default): templates, then the LAN Cloud. Templates: vNIC templates only, so the LAN
    Cloud can follow in a later window. LanCloud: the LAN Cloud only, for VLANs whose template
    memberships are already gone.

.PARAMETER MaxManifestAgeDays
    How old the audit may be. Defaults to 3. Usage can change after an audit; re-run it rather
    than raise this.

.PARAMETER UcsCredential
    UCS Manager credential. When omitted it is resolved by Get-RichoCredential from
    -UcsCredentialName.

.PARAMETER UcsCredentialName
    Get-RichoCredential name for UCS Manager. Defaults to 'ucsm'.

.PARAMETER OutputDirectory
    Where run folders are created. Defaults to output/ucs-vlan-removal at the repo root.

.PARAMETER ConnectionTimeoutSeconds
    How long to wait for the UCS Manager login. Defaults to 60.

.PARAMETER PropagationTimeoutSeconds
    How long to wait for updating-template changes to reach every bound service profile before
    the LAN Cloud stage is abandoned. Defaults to 180.

.PARAMETER Transcript
    Write a transcript and log file to logs/.

.EXAMPLE
    .\Remove-UcsUnusedVlan.ps1 -ManifestPath ..\..\output\ucs-vlan-audit\PD24000001SS101_VLAN-Audit_2026-10-12_091500 -VlanId 2210, 2214 -WhatIf

    Dry run: shows every removal it would make and writes the plan, changing nothing.

.EXAMPLE
    .\Remove-UcsUnusedVlan.ps1 -ManifestPath .\candidates.json -VlanId 2210, 2214 -Transcript

    Removes VLANs 2210 and 2214 from their vNIC templates and then the LAN Cloud, confirming each.

.EXAMPLE
    .\Remove-UcsUnusedVlan.ps1 -ManifestPath .\candidates.json -VlanId 2210 -Stage Templates

    Removes the VLAN from vNIC templates only; the LAN Cloud is left for a later change.
#>
#Requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'UcsCredentialName names a stored credential; it is not a secret.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [ValidateCount(1, 4093)]
    [ValidateRange(2, 4094)]
    [int[]]$VlanId,

    [ValidateSet('Both', 'Templates', 'LanCloud')]
    [string]$Stage = 'Both',

    [ValidateRange(1, 30)]
    [int]$MaxManifestAgeDays = 3,

    [pscredential]$UcsCredential,

    [string]$UcsCredentialName = 'ucsm',

    [string]$OutputDirectory,

    [ValidateRange(5, 900)]
    [int]$ConnectionTimeoutSeconds = 60,

    [ValidateRange(0, 3600)]
    [int]$PropagationTimeoutSeconds = 180,

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

#region Module loading

function Import-RequiredModules {
    <#
    .SYNOPSIS
        Loads Richo.Common and UCS PowerTool once, leaving anything already loaded alone.

    .DESCRIPTION
        Each load is guarded by Get-Module, so a module already in the session - including a pinned
        bundle - is used as it is. Nothing is installed or updated.

    .EXAMPLE
        Import-RequiredModules
    #>
    $wanted = @(
        [pscustomobject]@{ Purpose = 'shared helpers'; Names = @('Richo.Common'); Path = (Join-Path $PSScriptRoot '../../modules/Richo.Common/Richo.Common.psd1') }
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

#region Shared with Get-UcsVlanAudit.ps1 - keep identical (tests/Test-UcsVlanRemoval.ps1 checks)
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
#endregion

#region Manifest

function Read-RemovalManifest {
    <#
    .SYNOPSIS
        Reads an audit's candidates.json, given the file or the audit folder.

    .PARAMETER Path
        candidates.json or the folder holding it.

    .EXAMPLE
        $manifest = Read-RemovalManifest -Path .\output\ucs-vlan-audit\PD24000001SS101_VLAN-Audit_2026-10-12_091500
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $file = if (Test-Path -LiteralPath $Path -PathType Container) { Join-Path $Path 'candidates.json' } else { $Path }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "No audit manifest at '$file'. Point -ManifestPath at the audit's candidates.json or the folder that holds it."
    }
    Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
}

function Test-RemovalManifest {
    <#
    .SYNOPSIS
        Refuses an audit that is preliminary, stale or does not list the requested VLANs; else returns them.

    .DESCRIPTION
        Every problem is collected and reported together, so the operator fixes them in one pass
        rather than one rejection at a time.

    .PARAMETER Manifest
        From Read-RemovalManifest.

    .PARAMETER VlanId
        The VLAN IDs approved for removal.

    .PARAMETER NowUtc
        The current time, UTC.

    .PARAMETER MaxAgeDays
        How old the audit may be.

    .EXAMPLE
        $approved = @(Test-RemovalManifest -Manifest $m -VlanId 2210 -NowUtc (Get-Date).ToUniversalTime() -MaxAgeDays 3)
    #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$VlanId,
        [Parameter(Mandatory)][datetime]$NowUtc,
        [Parameter(Mandatory)][int]$MaxAgeDays
    )
    $problems = New-Object System.Collections.Generic.List[string]
    if ($VlanId.Count -eq 0) { $problems.Add('No VLAN IDs were given.') }
    if ([string](Get-PropertyValue $Manifest 'ManifestVersion') -ne '1') {
        $problems.Add("Unsupported manifest version '$(Get-PropertyValue $Manifest 'ManifestVersion')'; produce it with Get-UcsVlanAudit.ps1 8.x.")
    }
    $overall = [string](Get-PropertyValue $Manifest 'Overall')
    if ($overall -ne 'COMPLETE') {
        $problems.Add("The audit ended '$overall'. Preliminary candidates are never removed - resolve the audit's warnings and run it again.")
    }
    $warnings = @(Get-PropertyList $Manifest 'Warnings')
    if ($warnings.Count -gt 0) {
        $problems.Add("The audit carries $($warnings.Count) warning(s), first: $($warnings[0])")
    }

    $raw = Get-PropertyValue $Manifest 'GeneratedUtc'
    $generated = $null
    if ($raw -is [datetime]) {
        $generated = $raw.ToUniversalTime()
    }
    else {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { $generated = $parsed.ToUniversalTime() }
    }
    if ($null -eq $generated) {
        $problems.Add("The audit time '$raw' cannot be read.")
    }
    else {
        $age = $NowUtc.ToUniversalTime() - $generated
        if ($age.TotalHours -lt -1) { $problems.Add("The audit is dated in the future ($($generated.ToString('u'))).") }
        elseif ($age.TotalDays -gt $MaxAgeDays) { $problems.Add(('The audit is {0:N1} days old; the limit is {1}. Usage can change - run the audit again.' -f $age.TotalDays, $MaxAgeDays)) }
    }

    $byId = @{}
    foreach ($candidate in @(Get-PropertyList $Manifest 'Candidates')) { $byId[[int](Get-PropertyValue $candidate 'VlanId')] = $candidate }
    $approved = New-Object System.Collections.Generic.List[object]
    foreach ($id in @(ConvertTo-SortedIntArray -InputObject $VlanId)) {
        if (-not $byId.ContainsKey($id)) {
            $problems.Add("VLAN $id is not a cleanup candidate in this audit.")
            continue
        }
        $classification = [string](Get-PropertyValue $byId[$id] 'Classification')
        if ($classification -ne 'UCSM CLEANUP CANDIDATE') {
            $problems.Add("VLAN $id is '$classification' in this audit, not a validated cleanup candidate.")
            continue
        }
        $approved.Add($byId[$id])
    }
    if (-not (Get-PropertyValue $Manifest 'UcsServer')) { $problems.Add('The manifest does not name the UCS Manager it was taken from.') }

    if ($problems.Count -gt 0) {
        throw ("Removal refused:{0} - {1}" -f [Environment]::NewLine, ($problems -join "$([Environment]::NewLine) - "))
    }
    $approved.ToArray()
}

#endregion

#region Planning

function ConvertTo-PendingAckProfileDn {
    <#
    .SYNOPSIS
        The service profiles that have a pending reboot acknowledgement (lsmaintAck objects).

    .PARAMETER Ack
        lsmaintAck objects.

    .EXAMPLE
        @(ConvertTo-PendingAckProfileDn -Ack $acks)
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Ack
    )
    foreach ($item in $Ack) {
        if ([string](Get-PropertyValue $item 'Dn') -match '^(?<profile>.+/ls-[^/]+)/') { $Matches['profile'] }
    }
}

function Get-VlanRemovalPlan {
    <#
    .SYNOPSIS
        Builds the ordered list of removals for the approved VLANs, re-checked against the live domain.

    .DESCRIPTION
        Pure. One row per template membership and one per LAN Cloud VLAN, each PLANNED or BLOCKED
        with the reason. Anything about a VLAN that differs from the audit blocks every row for it:
        the review approved what the audit showed, not what the domain looks like now.

        A LAN Cloud row that is PLANNED is still only provisional; Get-LanCloudBlocker re-checks it
        live immediately before the delete.

    .PARAMETER Candidate
        Approved candidates from Test-RemovalManifest.

    .PARAMETER Inventory
        Live inventory from Get-UcsVlanInventory.

    .PARAMETER MatchedServiceProfileDn
        Service profiles the audit matched to ESXi hosts.

    .PARAMETER PendingAckProfileDn
        Service profiles with a pending reboot acknowledgement now.

    .PARAMETER Stage
        Both, Templates or LanCloud.

    .EXAMPLE
        $plan = @(Get-VlanRemovalPlan -Candidate $approved -Inventory $inventory -MatchedServiceProfileDn $m -PendingAckProfileDn $p -Stage Both)
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidate,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MatchedServiceProfileDn,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PendingAckProfileDn,
        [Parameter(Mandatory)][ValidateSet('Both', 'Templates', 'LanCloud')][string]$Stage
    )
    $approved = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($item in $Candidate) { [void]$approved.Add([int](Get-PropertyValue $item 'VlanId')) }
    $matched = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($dn in $MatchedServiceProfileDn) { [void]$matched.Add($dn) }
    $pending = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($dn in $PendingAckProfileDn) { [void]$pending.Add($dn) }
    $profileByDn = @{}
    foreach ($item in $Inventory.ServiceProfiles) { $profileByDn[$item.Dn] = $item }

    $rows = New-Object System.Collections.Generic.List[object]
    $newRow = {
        param($StageName, $Id, $Name, $TargetDn, $TargetName, $TemplateType, $EtherIfDn, $Status, $Reason)
        [pscustomobject]@{
            Order = $rows.Count + 1; Stage = $StageName; VlanId = $Id; VlanName = $Name; TargetDn = $TargetDn; TargetName = $TargetName
            TemplateType = $TemplateType; EtherIfDn = $EtherIfDn; Status = $Status; Reason = $Reason; Result = ''; Details = ''
        }
    }

    foreach ($item in $Candidate) {
        $id = [int](Get-PropertyValue $item 'VlanId')
        $blockers = New-Object System.Collections.Generic.List[string]

        $live = @($Inventory.Vlans | Where-Object { $_.Id -eq $id })
        $auditDns = @(@(Get-PropertyList $item 'LanCloudVlans') | ForEach-Object { [string](Get-PropertyValue $_ 'Dn') } | Sort-Object)
        $liveDns = @($live | ForEach-Object { $_.Dn } | Sort-Object)
        if ($liveDns.Count -gt 0 -and ($liveDns -join '|') -ne ($auditDns -join '|')) {
            $blockers.Add("LAN Cloud definitions changed since the audit (audit: $($auditDns -join ', '); now: $($liveDns -join ', ')).")
        }
        if (@($live | Where-Object { $_.Native }).Count -gt 0) { $blockers.Add('It is the LAN Cloud native VLAN.') }
        if ($Inventory.InbandVlanIds -contains $id) { $blockers.Add('It is the in-band management VLAN.') }
        $nativeRefs = @($Inventory.EtherIfs | Where-Object { $_.Native -and $_.ResolvedVlanIds -contains $id })
        if ($nativeRefs.Count -gt 0) { $blockers.Add("It is native on $($nativeRefs.Count) vNIC/template(s), e.g. $($nativeRefs[0].Dn).") }

        $auditKeys = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($membership in @(Get-PropertyList $item 'TemplateMemberships')) {
            [void]$auditKeys.Add(('{0}|{1}' -f (Get-PropertyValue $membership 'TemplateDn'), (Get-PropertyValue $membership 'VlanName')))
        }
        $liveMemberships = @($Inventory.Memberships | Where-Object { $_.ResolvedVlanIds -contains $id })
        $added = @($liveMemberships | Where-Object { -not $auditKeys.Contains(('{0}|{1}' -f $_.TemplateDn, $_.VLANName)) })
        if ($added.Count -gt 0) { $blockers.Add("Added to template(s) since the audit: $(@($added | ForEach-Object { $_.Template }) -join ', ').") }

        $vlanBlocked = $blockers.Count -gt 0
        $templateBlocked = $false
        $templateRows = New-Object System.Collections.Generic.List[object]
        foreach ($membership in $liveMemberships) {
            $reasons = New-Object System.Collections.Generic.List[string]
            foreach ($text in $blockers) { $reasons.Add($text) }
            $outside = @($membership.ResolvedVlanIds | Where-Object { -not $approved.Contains($_) })
            if ($outside.Count -gt 0) {
                $reasons.Add("On this template the name '$($membership.VLANName)' can also mean VLAN $($outside -join ', '), which is not approved.")
            }
            $bound = @(if ($Inventory.TemplateBindings.ContainsKey($membership.TemplateDn)) { $Inventory.TemplateBindings[$membership.TemplateDn] })
            $unaudited = @($bound | Where-Object { $profileByDn.ContainsKey($_) -and $profileByDn[$_].Associated -and -not $matched.Contains($_) })
            if ($unaudited.Count -gt 0) {
                $reasons.Add("Now used by service profile(s) the audit did not match to an ESXi host: $(@($unaudited | Select-Object -First 5) -join ', ').")
            }
            $waiting = @($bound | Where-Object { $pending.Contains($_) })
            if ($waiting.Count -gt 0) {
                $reasons.Add("Bound service profile(s) already have a pending reboot acknowledgement: $(@($waiting | Select-Object -First 5) -join ', ').")
            }
            $note = if ($membership.TemplateType -eq 'initial-template') { 'Initial template: service profiles created from it keep the VLAN, which will then block the LAN Cloud delete.' } else { '' }
            $status = if ($reasons.Count -gt 0) { 'BLOCKED' } elseif ($Stage -eq 'LanCloud') { 'SKIPPED - STAGE' } else { 'PLANNED' }
            if ($status -eq 'BLOCKED') { $templateBlocked = $true }
            $text = (@($reasons) + @($note) | Where-Object { $_ }) -join ' '
            $templateRows.Add((& $newRow 'Template' $id $membership.VLANName $membership.TemplateDn $membership.Template $membership.TemplateType $membership.EtherIfDn $status $text))
        }
        # All or nothing per VLAN: removing it from one template of a pair and not the other leaves
        # the fabrics inconsistent, which next month's pair audit would then report.
        foreach ($row in $templateRows) {
            if ($templateBlocked -and $row.Status -ne 'BLOCKED') {
                $row.Status = 'BLOCKED'
                $row.Reason = (@('Another template membership of this VLAN is blocked, so it is left on every template.', $row.Reason) | Where-Object { $_ }) -join ' '
            }
            $row.Order = $rows.Count + 1
            $rows.Add($row)
        }

        if ($live.Count -eq 0) {
            $rows.Add((& $newRow 'LanCloud' $id '' '' '' '' '' 'ALREADY ABSENT' 'Not in the LAN Cloud any more.'))
            continue
        }
        foreach ($vlan in $live) {
            $status = if ($vlanBlocked) { 'BLOCKED' }
            elseif ($templateBlocked) { 'BLOCKED' }
            elseif ($Stage -eq 'Templates') { 'SKIPPED - STAGE' }
            else { 'PLANNED' }
            $reason = if ($vlanBlocked) { $blockers -join ' ' } elseif ($templateBlocked) { 'A template membership of this VLAN is blocked, so it will still be referenced.' } else { 'Re-checked live for remaining references immediately before the delete.' }
            $rows.Add((& $newRow 'LanCloud' $id $vlan.Name $vlan.Dn ('{0} (ID {1}, fabric {2})' -f $vlan.Name, $id, $vlan.Fabric) '' '' $status $reason))
        }
    }
    $rows.ToArray()
}

function Get-LanCloudBlocker {
    <#
    .SYNOPSIS
        Why a LAN Cloud VLAN cannot be deleted right now, if anything stops it.

    .DESCRIPTION
        Deleting a VLAN that a vNIC still names raises F0933 ("the named VLAN cannot be resolved")
        and has been reported to drop traffic on the blades concerned. So any reference blocks:
        a vNIC template, a service profile or service profile template vNIC, or a LAN
        connectivity policy - matched by name, unless that reference can only mean a different
        VLAN. VLAN group membership, the native flag, in-band use and being a PVLAN primary block
        too.

    .PARAMETER Vlan
        The live LAN Cloud VLAN row.

    .PARAMETER Inventory
        Live inventory.

    .PARAMETER AssumeRemovedEtherIfDn
        References to treat as already gone. Used only by -WhatIf, where the template stage did
        not really run, so the preview can show what the delete would then do.

    .EXAMPLE
        @(Get-LanCloudBlocker -Vlan $vlan -Inventory $inventory)
    #>
    param(
        [Parameter(Mandatory)]$Vlan,
        [Parameter(Mandatory)]$Inventory,
        [AllowEmptyCollection()][string[]]$AssumeRemovedEtherIfDn = @()
    )
    $ignore = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($dn in $AssumeRemovedEtherIfDn) { [void]$ignore.Add($dn) }

    if ($Vlan.Native) { 'It is the LAN Cloud native VLAN.' }
    if ($Inventory.InbandVlanIds -contains $Vlan.Id) { 'It is the in-band management VLAN.' }
    $references = @($Inventory.EtherIfs | Where-Object {
            $_.VlanName -eq $Vlan.Name -and -not $ignore.Contains($_.Dn) -and
            ($_.ResolvedVlanDns.Count -eq 0 -or $_.ResolvedVlanDns -contains $Vlan.Dn)
        })
    if ($references.Count -gt 0) {
        $byType = @($references | Group-Object OwnerType | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
        "Still referenced by $($references.Count) vNIC VLAN entr$(if ($references.Count -eq 1) { 'y' } else { 'ies' }) ($byType), e.g. $(@($references | Select-Object -First 3 | ForEach-Object { $_.Dn }) -join '; ')."
    }
    $groups = @($Inventory.VlanGroupMembers | Where-Object { $_.VlanName -eq $Vlan.Name })
    if ($groups.Count -gt 0) { "Member of VLAN group(s) $(@($groups | ForEach-Object { $_.GroupName }) -join ', '); remove it from the group first." }
    $secondaries = @($Inventory.Vlans | Where-Object { $_.PubNwName -eq $Vlan.Name -and $_.Dn -ne $Vlan.Dn })
    if ($secondaries.Count -gt 0) { "It is the primary of private VLAN(s) $(@($secondaries | ForEach-Object { $_.Name }) -join ', ')." }
}

function Get-PropagationPending {
    <#
    .SYNOPSIS
        Template removals that have not yet reached the template or its bound service profiles.

    .DESCRIPTION
        Pure. A removed membership is pending while the template still holds it, or while a
        service profile vNIC bound to an UPDATING template still carries that VLAN name. Initial
        templates never propagate, so their profiles are not waited for.

    .PARAMETER Inventory
        Live inventory, re-read.

    .PARAMETER Removed
        Template plan rows whose removal was made.

    .EXAMPLE
        @(Get-PropagationPending -Inventory $inventory -Removed $done)
    #>
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Removed
    )
    $removedDn = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in $Removed) { [void]$removedDn.Add($row.EtherIfDn) }
    $updating = @($Removed | Where-Object { $_.TemplateType -eq 'updating-template' })
    foreach ($etherIf in $Inventory.EtherIfs) {
        if ($removedDn.Contains($etherIf.Dn)) {
            $etherIf
            continue
        }
        if ($etherIf.OwnerType -eq 'VnicTemplate') { continue }
        foreach ($row in $updating) {
            if ($etherIf.VlanName -eq $row.VlanName -and $etherIf.TemplateDns -contains $row.TargetDn) {
                $etherIf
                break
            }
        }
    }
}

function Get-SimulatedRemoval {
    <#
    .SYNOPSIS
        Under -WhatIf, the references the template stage would have removed.

    .DESCRIPTION
        The template memberships themselves, plus the copies on service profile vNICs bound to the
        updating templates concerned. Lets the dry run preview the LAN Cloud stage as it would run.

    .PARAMETER Inventory
        Live inventory.

    .PARAMETER Simulated
        Template plan rows that -WhatIf skipped.

    .EXAMPLE
        @(Get-SimulatedRemoval -Inventory $inventory -Simulated $whatIfRows)
    #>
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Simulated
    )
    @(Get-PropagationPending -Inventory $Inventory -Removed $Simulated) | ForEach-Object { $_.Dn }
}

#endregion

#region Changes

function Remove-TemplateVlanMembership {
    <#
    .SYNOPSIS
        Removes one VLAN from one vNIC template.

    .DESCRIPTION
        Finds the template by Dn and the VLAN by name among its interfaces, then removes that
        interface. Returns REMOVED, ALREADY ABSENT, or NOT PERFORMED when ShouldProcess declined.

    .PARAMETER Ucs
        UCS Manager session.

    .PARAMETER TemplateDn
        vNIC template Dn.

    .PARAMETER VlanName
        VLAN name on the template.

    .PARAMETER VlanId
        VLAN ID, for the confirmation message.

    .EXAMPLE
        Remove-TemplateVlanMembership -Ucs $ucs -TemplateDn 'org-root/lan-conn-templ-ESX-A' -VlanName 'VL2210' -VlanId 2210
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]$Ucs,
        [Parameter(Mandatory)][string]$TemplateDn,
        [Parameter(Mandatory)][string]$VlanName,
        [int]$VlanId
    )
    if (-not $PSCmdlet.ShouldProcess("vNIC template $TemplateDn", "Remove VLAN '$VlanName' (ID $VlanId)")) { return 'NOT PERFORMED' }
    $template = @(Get-UcsVnicTemplate -Ucs $Ucs -ErrorAction Stop | Where-Object { $_.Dn -eq $TemplateDn })
    if ($template.Count -ne 1) { throw "vNIC template $TemplateDn was not found." }
    $member = @($template[0] | Get-UcsVnicInterface -ErrorAction Stop | Where-Object { $_.Name -eq $VlanName })
    if ($member.Count -eq 0) { return 'ALREADY ABSENT' }
    $member | Remove-UcsVnicInterface -Force -ErrorAction Stop | Out-Null
    return 'REMOVED'
}

function Remove-LanCloudVlan {
    <#
    .SYNOPSIS
        Deletes one VLAN from the LAN Cloud.

    .DESCRIPTION
        Finds the VLAN by Dn and removes it. Returns REMOVED, ALREADY ABSENT, or NOT PERFORMED when
        ShouldProcess declined. The caller is responsible for Get-LanCloudBlocker first.

    .PARAMETER Ucs
        UCS Manager session.

    .PARAMETER VlanDn
        VLAN Dn, e.g. fabric/lan/net-VL2210.

    .PARAMETER VlanName
        VLAN name, for the confirmation message.

    .PARAMETER VlanId
        VLAN ID, for the confirmation message.

    .EXAMPLE
        Remove-LanCloudVlan -Ucs $ucs -VlanDn 'fabric/lan/net-VL2210' -VlanName 'VL2210' -VlanId 2210
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]$Ucs,
        [Parameter(Mandatory)][string]$VlanDn,
        [string]$VlanName,
        [int]$VlanId
    )
    if (-not $PSCmdlet.ShouldProcess("LAN Cloud $VlanDn", "Delete VLAN '$VlanName' (ID $VlanId)")) { return 'NOT PERFORMED' }
    $vlan = @(Get-UcsVlan -Ucs $Ucs -ErrorAction Stop | Where-Object { $_.Dn -eq $VlanDn })
    if ($vlan.Count -eq 0) { return 'ALREADY ABSENT' }
    $vlan | Remove-UcsVlan -Force -ErrorAction Stop | Out-Null
    return 'REMOVED'
}

#endregion

#region Evidence

function ConvertTo-RollbackScript {
    <#
    .SYNOPSIS
        Text of a script that re-creates what the plan removes: LAN Cloud VLANs, then template memberships.

    .DESCRIPTION
        Written before any change, so it exists even if the run dies part-way. Each step is
        independent - one that fails, for instance because the object was never removed, is
        reported and the rest still run.

    .PARAMETER Plan
        Plan rows.

    .PARAMETER Inventory
        Live inventory, for the LAN Cloud VLAN details.

    .PARAMETER UcsName
        Domain name, for the header.

    .EXAMPLE
        ConvertTo-RollbackScript -Plan $plan -Inventory $inventory -UcsName 'PD24000001SS101'
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][string]$UcsName
    )
    $quote = { param($Text) "'" + ([string]$Text).Replace("'", "''") + "'" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<#')
    $lines.Add('.SYNOPSIS')
    $lines.Add("    Re-creates what Remove-UcsUnusedVlan.ps1 planned to remove from $UcsName.")
    $lines.Add('.DESCRIPTION')
    $lines.Add('    Generated before the change. Covers everything the run PLANNED; a step for something that')
    $lines.Add('    was not removed fails with "already exists" and is reported, and the other steps still run.')
    $lines.Add('    Review before use. Generated text - it has not been run against UCS Manager by its tests.')
    $lines.Add('.PARAMETER Ucs')
    $lines.Add('    An open UCS Manager session, e.g. (Connect-Ucs -Name <server> -Credential (Get-Credential)).')
    $lines.Add('#>')
    $lines.Add('param([Parameter(Mandatory)]$Ucs)')
    $lines.Add('$failed = 0')
    $lines.Add('function Invoke-Step { param([string]$Label, [scriptblock]$Step) try { & $Step | Out-Null; Write-Output "OK      $Label" } catch { $script:failed++; Write-Output "FAILED  $Label - $($_.Exception.Message)" } }')
    $lines.Add('')
    $lines.Add('# LAN Cloud VLANs first, so the template memberships below can resolve.')
    $vlanByDn = @{}
    foreach ($row in $Inventory.Vlans) { $vlanByDn[$row.Dn] = $row }
    foreach ($row in @($Plan | Where-Object { $_.Stage -eq 'LanCloud' -and $_.Status -eq 'PLANNED' })) {
        $vlan = $vlanByDn[$row.TargetDn]
        if ($null -eq $vlan) { continue }
        $label = & $quote ("VLAN {0} '{1}' ({2})" -f $vlan.Id, $vlan.Name, $vlan.Dn)
        if ($vlan.Fabric -eq 'dual') {
            $lines.Add("Invoke-Step $label { Get-UcsLanCloud -Ucs `$Ucs | Add-UcsVlan -Name $(& $quote $vlan.Name) -Id $($vlan.Id) -ErrorAction Stop }")
        }
        else {
            $lines.Add("# Fabric-specific. If Get-UcsFiLanCloud is not in this PowerTool version, re-create it in UCS Manager: LAN > LAN Cloud > Fabric $($vlan.Fabric) > VLANs, name $($vlan.Name), ID $($vlan.Id).")
            $lines.Add("Invoke-Step $label { Get-UcsFiLanCloud -Ucs `$Ucs -Id $($vlan.Fabric) | Add-UcsVlan -Name $(& $quote $vlan.Name) -Id $($vlan.Id) -ErrorAction Stop }")
        }
        if ($vlan.Sharing -and $vlan.Sharing -ne 'none') { $lines.Add("# NOTE: $($vlan.Name) was a private VLAN (sharing '$($vlan.Sharing)', primary '$($vlan.PubNwName)'); set that again by hand.") }
    }
    $lines.Add('')
    $lines.Add('# vNIC template memberships.')
    foreach ($row in @($Plan | Where-Object { $_.Stage -eq 'Template' -and $_.Status -eq 'PLANNED' })) {
        $label = & $quote ("VLAN '{0}' on template {1}" -f $row.VlanName, $row.TargetDn)
        $lines.Add("Invoke-Step $label { Get-UcsVnicTemplate -Ucs `$Ucs | Where-Object { `$_.Dn -eq $(& $quote $row.TargetDn) } | Add-UcsVnicInterface -Name $(& $quote $row.VlanName) -ErrorAction Stop }")
    }
    $lines.Add('')
    $lines.Add('if ($failed) { Write-Output "$failed step(s) failed - review the output above." } else { Write-Output "All steps succeeded." }')
    $lines -join [Environment]::NewLine
}

function Export-RemovalEvidence {
    <#
    .SYNOPSIS
        Writes plan.csv, snapshot.json and rollback.ps1 before any change.

    .DESCRIPTION
        Writes even under -WhatIf: a dry run's plan is its output. -WhatIf:$false on each write
        stops the run's own -WhatIf from silently skipping the files.

    .PARAMETER Folder
        Run folder.

    .PARAMETER Plan
        Plan rows.

    .PARAMETER Inventory
        Live inventory.

    .PARAMETER UcsName
        Domain name.

    .PARAMETER UcsServer
        Server connected to.

    .EXAMPLE
        Export-RemovalEvidence -Folder $folder -Plan $plan -Inventory $inventory -UcsName $name -UcsServer $server
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][string]$UcsName,
        [Parameter(Mandatory)][string]$UcsServer
    )
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($row in $Plan) { [void]$ids.Add([int]$row.VlanId) }
    $snapshot = [ordered]@{
        ScriptVersion = $ScriptVersion
        TakenUtc = (Get-Date).ToUniversalTime().ToString('o')
        UCSM = $UcsName
        UcsServer = $UcsServer
        LanCloudVlans = @($Inventory.Vlans | Where-Object { $ids.Contains($_.Id) } | ForEach-Object { [ordered]@{ Dn = $_.Dn; Name = $_.Name; Id = $_.Id; Fabric = $_.Fabric; Sharing = $_.Sharing; PubNwName = $_.PubNwName; Native = $_.Native } })
        VlanReferences = @($Inventory.EtherIfs | Where-Object { $r = $_; @($r.ResolvedVlanIds | Where-Object { $ids.Contains($_) }).Count -gt 0 } | ForEach-Object { [ordered]@{ Dn = $_.Dn; OwnerType = $_.OwnerType; OwnerDn = $_.OwnerDn; VlanName = $_.VlanName; Native = $_.Native; TemplateDns = [string[]]$_.TemplateDns } })
        TemplateBinding = @($Plan | Where-Object { $_.Stage -eq 'Template' } | ForEach-Object { $_.TargetDn } | Sort-Object -Unique | ForEach-Object {
                [ordered]@{ TemplateDn = $_; ServiceProfiles = [string[]]@(if ($Inventory.TemplateBindings.ContainsKey($_)) { $Inventory.TemplateBindings[$_] }) }
            })
    }
    $Plan | Select-Object Order, Stage, VlanId, VlanName, TargetName, TargetDn, TemplateType, Status, Reason, @{ Name = 'ScriptVersion'; Expression = { $ScriptVersion } } | Export-Csv -LiteralPath (Join-Path $Folder 'plan.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    ConvertTo-Json -InputObject $snapshot -Depth 6 | Set-Content -LiteralPath (Join-Path $Folder 'snapshot.json') -Encoding UTF8 -WhatIf:$false
    ConvertTo-RollbackScript -Plan $Plan -Inventory $Inventory -UcsName $UcsName | Set-Content -LiteralPath (Join-Path $Folder 'rollback.ps1') -Encoding UTF8 -WhatIf:$false
}

#endregion

#region Orchestration

function Get-PendingAckProfileDn {
    <#
    .SYNOPSIS
        Reads the service profiles with a pending reboot acknowledgement from UCS Manager.

    .PARAMETER Ucs
        UCS Manager session.

    .EXAMPLE
        @(Get-PendingAckProfileDn -Ucs $ucs)
    #>
    param([Parameter(Mandatory)]$Ucs)
    ConvertTo-PendingAckProfileDn -Ack @(Get-UcsManagedObject -ClassId lsmaintAck -Ucs $Ucs -ErrorAction Stop)
}

function Get-VlanFaultDn {
    <#
    .SYNOPSIS
        Reads the Dns of the F0933 faults ("the named VLAN cannot be resolved") currently raised.

    .PARAMETER Ucs
        UCS Manager session.

    .EXAMPLE
        @(Get-VlanFaultDn -Ucs $ucs)
    #>
    param([Parameter(Mandatory)]$Ucs)
    foreach ($fault in @(Get-UcsManagedObject -ClassId faultInst -Ucs $Ucs -ErrorAction Stop)) {
        if ([string](Get-PropertyValue $fault 'Code') -eq 'F0933') { [string](Get-PropertyValue $fault 'Dn') }
    }
}

function Write-PlanLog {
    <#
    .SYNOPSIS
        Logs each plan row on one line.

    .PARAMETER Plan
        Plan rows.

    .PARAMETER Field
        'Status' to log the plan, 'Result' to log the outcome.

    .EXAMPLE
        Write-PlanLog -Plan $plan -Field Status
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [ValidateSet('Status', 'Result')][string]$Field = 'Status'
    )
    foreach ($row in $Plan) {
        $value = $row.$Field
        $level = if ($value -like 'BLOCKED*' -or $value -like 'FAILED*') { 'WARN' } else { 'INFO' }
        $detail = if ($Field -eq 'Status') { $row.Reason } else { $row.Details }
        Write-RichoLog ('{0,-8} VLAN {1,-4} {2,-40} {3}{4}' -f $row.Stage, $row.VlanId, $row.TargetName, $value, $(if ($detail) { " - $detail" } else { '' })) -Level $level
    }
}

function Invoke-UcsVlanRemoval {
    <#
    .SYNOPSIS
        Validates, plans and runs the removal against one UCS Manager domain.

    .DESCRIPTION
        ShouldProcess is asked here, once per removal, so the operator's "Yes to All" covers the
        run; the Remove-* helpers are then called with -Confirm:$false.

    .PARAMETER Manifest
        From Read-RemovalManifest.

    .PARAMETER VlanId
        Approved VLAN IDs.

    .PARAMETER Stage
        Both, Templates or LanCloud.

    .PARAMETER MaxManifestAgeDays
        How old the audit may be.

    .PARAMETER Credential
        UCS Manager credential.

    .PARAMETER OutputRoot
        Parent folder for the run folder.

    .PARAMETER TimeoutSeconds
        UCS Manager login timeout.

    .PARAMETER PropagationTimeoutSeconds
        How long to wait for updating templates to reach their service profiles.

    .PARAMETER PollSeconds
        Interval between propagation checks.

    .EXAMPLE
        Invoke-UcsVlanRemoval -Manifest $m -VlanId 2210 -Stage Both -MaxManifestAgeDays 3 -Credential $c -OutputRoot $out -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$VlanId,
        [Parameter(Mandatory)][ValidateSet('Both', 'Templates', 'LanCloud')][string]$Stage,
        [Parameter(Mandatory)][int]$MaxManifestAgeDays,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$OutputRoot,
        [int]$TimeoutSeconds = 60,
        [int]$PropagationTimeoutSeconds = 180,
        [int]$PollSeconds = 10
    )
    $approved = @(Test-RemovalManifest -Manifest $Manifest -VlanId $VlanId -NowUtc (Get-Date).ToUniversalTime() -MaxAgeDays $MaxManifestAgeDays)
    $ucsName = [string]$Manifest.UCSM
    $server = [string]$Manifest.UcsServer
    $whatIf = [bool]$WhatIfPreference
    Write-RichoLog "[$ucsName] Approved for removal: $(Format-IdList -Id $VlanId). Stage: $Stage.$(if ($whatIf) { ' WhatIf - nothing will be changed.' })" -Level INFO

    $folder = Join-Path $OutputRoot ('{0}_VLAN-Removal_{1}' -f $ucsName, (Get-Date).ToString('yyyy-MM-dd_HHmmss'))
    New-Item -Path $folder -ItemType Directory -Force -WhatIf:$false | Out-Null

    $plan = @()
    $ucs = $null
    try {
        $ucs = Connect-UcsWithTimeout -Server $server -Credential $Credential -TimeoutSeconds $TimeoutSeconds
        $inventory = Get-UcsVlanInventory -Ucs $ucs
        $acksBefore = @(Get-PendingAckProfileDn -Ucs $ucs)
        $faultsBefore = @(Get-VlanFaultDn -Ucs $ucs)

        $plan = @(Get-VlanRemovalPlan -Candidate $approved -Inventory $inventory -MatchedServiceProfileDn @($Manifest.MatchedServiceProfileDns) -PendingAckProfileDn $acksBefore -Stage $Stage)
        Export-RemovalEvidence -Folder $folder -Plan $plan -Inventory $inventory -UcsName $ucsName -UcsServer $server
        Write-RichoLog "[$ucsName] Plan, snapshot and rollback script written to $folder" -Level INFO
        Write-PlanLog -Plan $plan -Field Status
        if (@($plan | Where-Object { $_.Status -eq 'PLANNED' }).Count -eq 0) {
            Write-RichoLog "[$ucsName] Nothing is cleared for removal." -Level WARN
            return $plan
        }

        # ---- Stage 1: vNIC templates ------------------------------------------------------------
        $removed = New-Object System.Collections.Generic.List[object]
        foreach ($row in @($plan | Where-Object { $_.Stage -eq 'Template' -and $_.Status -eq 'PLANNED' })) {
            if (-not $PSCmdlet.ShouldProcess("vNIC template $($row.TargetDn)", "Remove VLAN '$($row.VlanName)' (ID $($row.VlanId))")) {
                $row.Result = if ($whatIf) { 'WHATIF' } else { 'DECLINED' }
                continue
            }
            try {
                $row.Result = Remove-TemplateVlanMembership -Ucs $ucs -TemplateDn $row.TargetDn -VlanName $row.VlanName -VlanId $row.VlanId -Confirm:$false
                if ($row.Result -eq 'REMOVED') { $removed.Add($row) }
                Write-RichoLog "Template $($row.TargetName): VLAN $($row.VlanId) $($row.Result)." -Level INFO
            }
            catch {
                $row.Result = 'FAILED'
                $row.Details = $_.Exception.Message
                Write-RichoLog "Template $($row.TargetName): removing VLAN $($row.VlanId) failed: $($_.Exception.Message)" -Level WARN
            }
        }

        $halt = ''
        if ($removed.Count -gt 0) {
            Write-RichoLog "Waiting up to $PropagationTimeoutSeconds s for the template changes to reach their service profiles." -Level INFO
            $deadline = (Get-Date).AddSeconds($PropagationTimeoutSeconds)
            while ($true) {
                $inventory = Get-UcsVlanInventory -Ucs $ucs
                $pendingRefs = @(Get-PropagationPending -Inventory $inventory -Removed $removed.ToArray())
                if ($pendingRefs.Count -eq 0 -or (Get-Date) -ge $deadline) { break }
                Start-Sleep -Seconds $PollSeconds
            }
            if ($pendingRefs.Count -gt 0) {
                $halt = "the template changes had not reached $($pendingRefs.Count) vNIC(s) after $PropagationTimeoutSeconds s, e.g. $($pendingRefs[0].Dn)"
            }

            $bound = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($row in $removed) { if ($inventory.TemplateBindings.ContainsKey($row.TargetDn)) { foreach ($dn in $inventory.TemplateBindings[$row.TargetDn]) { [void]$bound.Add($dn) } } }
            $newAcks = @(@(Get-PendingAckProfileDn -Ucs $ucs) | Where-Object { $bound.Contains($_) -and $acksBefore -notcontains $_ } | Sort-Object -Unique)
            if ($newAcks.Count -gt 0) {
                $halt = "UCS Manager raised a pending reboot acknowledgement on $($newAcks.Count) bound service profile(s): $(@($newAcks | Select-Object -First 5) -join ', '). Nothing was acknowledged - review Pending Activities in UCS Manager"
                Write-RichoLog "STOPPED: $halt." -Level ERROR
            }
        }

        # ---- Stage 2: LAN Cloud -----------------------------------------------------------------
        $lanRows = @($plan | Where-Object { $_.Stage -eq 'LanCloud' -and $_.Status -eq 'PLANNED' })
        if ($halt) {
            foreach ($row in $lanRows) { $row.Result = 'NOT ATTEMPTED'; $row.Details = "Stopped: $halt." }
            if ($halt -notlike 'UCS Manager raised*') { Write-RichoLog "LAN Cloud stage not run: $halt." -Level WARN }
        }
        elseif ($lanRows.Count -gt 0) {
            if ($removed.Count -eq 0) { $inventory = Get-UcsVlanInventory -Ucs $ucs }
            $assumed = @()
            if ($whatIf) { $assumed = @(Get-SimulatedRemoval -Inventory $inventory -Simulated @($plan | Where-Object { $_.Result -eq 'WHATIF' })) }
            foreach ($row in $lanRows) {
                $templateRows = @($plan | Where-Object { $_.Stage -eq 'Template' -and $_.VlanId -eq $row.VlanId -and $_.Status -eq 'PLANNED' })
                $notDone = @($templateRows | Where-Object { $_.Result -notin @('REMOVED', 'ALREADY ABSENT', 'WHATIF') })
                if ($notDone.Count -gt 0) {
                    $row.Result = 'BLOCKED'
                    $row.Details = "Template membership not removed ($(@($notDone | ForEach-Object { "$($_.TargetName): $($_.Result)" }) -join '; '))."
                    continue
                }
                $vlan = @($inventory.Vlans | Where-Object { $_.Dn -eq $row.TargetDn })
                if ($vlan.Count -eq 0) {
                    $row.Result = 'ALREADY ABSENT'
                    continue
                }
                $blockers = @(Get-LanCloudBlocker -Vlan $vlan[0] -Inventory $inventory -AssumeRemovedEtherIfDn $assumed)
                if ($blockers.Count -gt 0) {
                    $row.Result = 'BLOCKED - LIVE CHECK'
                    $row.Details = $blockers -join ' '
                    continue
                }
                if (-not $PSCmdlet.ShouldProcess("LAN Cloud $($row.TargetDn)", "Delete VLAN '$($row.VlanName)' (ID $($row.VlanId))")) {
                    $row.Result = if ($whatIf) { 'WHATIF' } else { 'DECLINED' }
                    continue
                }
                try {
                    $row.Result = Remove-LanCloudVlan -Ucs $ucs -VlanDn $row.TargetDn -VlanName $row.VlanName -VlanId $row.VlanId -Confirm:$false
                    Write-RichoLog "LAN Cloud $($row.TargetDn): $($row.Result)." -Level INFO
                }
                catch {
                    $row.Result = 'FAILED'
                    $row.Details = $_.Exception.Message
                    Write-RichoLog "LAN Cloud $($row.TargetDn): delete failed: $($_.Exception.Message)" -Level WARN
                }
            }

            if (@($lanRows | Where-Object { $_.Result -eq 'REMOVED' }).Count -gt 0) {
                $after = Get-UcsVlanInventory -Ucs $ucs
                foreach ($row in @($lanRows | Where-Object { $_.Result -eq 'REMOVED' })) {
                    if (@($after.Vlans | Where-Object { $_.Dn -eq $row.TargetDn }).Count -gt 0) {
                        $row.Result = 'FAILED - STILL PRESENT'
                        $row.Details = 'UCS Manager accepted the delete but the VLAN is still defined.'
                    }
                }
            }
        }

        if (-not $whatIf) {
            $newFaults = @(@(Get-VlanFaultDn -Ucs $ucs) | Where-Object { $faultsBefore -notcontains $_ })
            if ($newFaults.Count -gt 0) {
                Write-RichoLog "UCS Manager raised $($newFaults.Count) new F0933 fault(s) (named VLAN cannot be resolved), e.g. $($newFaults[0]). Review them now; rollback.ps1 in $folder re-creates what was removed." -Level ERROR
            }
        }
    }
    finally {
        if ($null -ne $ucs) { Disconnect-Ucs -Ucs $ucs -ErrorAction SilentlyContinue | Out-Null }
        if ($plan.Count -gt 0) {
            $plan | Select-Object Order, Stage, VlanId, VlanName, TargetName, TargetDn, TemplateType, Status, Reason, Result, Details, @{ Name = 'ScriptVersion'; Expression = { $ScriptVersion } } |
                Export-Csv -LiteralPath (Join-Path $folder 'results.csv') -NoTypeInformation -Encoding UTF8 -WhatIf:$false
            Write-PlanLog -Plan @($plan | Where-Object { $_.Result }) -Field Result
            Write-RichoLog "[$ucsName] Results written to $(Join-Path $folder 'results.csv')" -Level INFO
        }
    }
    $plan
}

#endregion

#region Main

Import-RequiredModules
$transcriptPath = if ($Transcript) { Start-RichoTranscript } else { $null }

try {
    Write-RichoLog "Remove-UcsUnusedVlan $ScriptVersion - removes approved VLANs from UCS Manager vNIC templates and the LAN Cloud." -Level INFO
    foreach ($command in @('Connect-Ucs', 'Disconnect-Ucs', 'Get-UcsManagedObject', 'Get-UcsVnicTemplate', 'Get-UcsVnicInterface', 'Remove-UcsVnicInterface', 'Get-UcsVlan', 'Remove-UcsVlan')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) { throw "Required command '$command' is not available in this session; nothing was changed." }
    }
    $manifest = Read-RemovalManifest -Path $ManifestPath
    if (-not $UcsCredential) { $UcsCredential = Get-RichoCredential -Name $UcsCredentialName }
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'output/ucs-vlan-removal' }

    $results = @(Invoke-UcsVlanRemoval -Manifest $manifest -VlanId $VlanId -Stage $Stage -MaxManifestAgeDays $MaxManifestAgeDays -Credential $UcsCredential -OutputRoot $OutputDirectory -TimeoutSeconds $ConnectionTimeoutSeconds -PropagationTimeoutSeconds $PropagationTimeoutSeconds)
    $removedCount = @($results | Where-Object { $_.Result -eq 'REMOVED' }).Count
    $problemCount = @($results | Where-Object { $_.Result -like 'FAILED*' -or $_.Result -like 'BLOCKED*' -or $_.Status -eq 'BLOCKED' }).Count
    Write-RichoLog "Finished. Removed: $removedCount. Blocked or failed: $problemCount." -Level INFO
}
catch {
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}

#endregion
