<#
.SYNOPSIS
    Reports vDS port groups that share a VLAN ID, and port groups with no VLAN, to CSV.

.DESCRIPTION
    Reads every distributed port group in the environment's vCenter and writes one CSV with
    a row per finding. Changes nothing in vCenter: the only thing written is the CSV, plus a
    transcript under logs/ with -Transcript. A read-only vCenter role is enough.

    Findings:

      DuplicateVlan      The same VLAN ID is set on more than one port group on the same vDS
                         (or anywhere in the vCenter, with -DuplicateScope vCenter). One row per
                         port group involved; SharedWith names the others.
      NoVlan             VLAN type None - the port group passes traffic untagged.
      TrunkRangeOverlap  A VLAN trunk port group whose ranges name the same VLAN more than
                         once, e.g. '100-200,150-160'. vCenter may normalise these on save, in
                         which case this never fires; it is checked rather than assumed.

    What counts as a port group's VLAN in the duplicate check:

      VLAN    The VLAN ID.
      PVLAN   The PVLAN ID set on the port group - the secondary, or the primary for a
              promiscuous port group - since that is the ID on the wire. VlanConfig names the
              PVLAN type and primary from the vDS PVLAN map.
      Trunk   Left out by default. A 0-4094 guest-tagging trunk carries every VLAN, and would
              be reported as a duplicate of every other port group on the switch. Opt in
              with -IncludeTrunk.

    Skipped, counted in the log, and never reported:

      - Uplink port groups. They are always trunks, and are not where VMs attach.
      - NSX-backed port groups (vSphere 7.0 and later). Their VLAN or overlay is owned by
        NSX, so the vCenter VLAN setting on them means nothing.

    Only the port group's own VLAN setting is read. Per-port VLAN overrides, on a port group
    that allows them, are not.

    Uses Get-View, so needs VMware.VimAutomation.Core only - not VMware.VimAutomation.Vds.

.PARAMETER Environment
    Environment key from config/environments.json. Defaults to the file's "default" entry.
    The vCenter and its credential name come from the environment's vcenter section.

.PARAMETER DuplicateScope
    Switch (default): a VLAN is a duplicate when two port groups on the SAME vDS carry it.
    vCenter: when any two port groups anywhere in the vCenter carry it. The same VLAN on
    different vDS is often by design - one vDS per cluster - which is why this is opt-in.

.PARAMETER IncludeTrunk
    Include trunk port groups in the duplicate check, counting every VLAN in their ranges.

.PARAMETER OutputPath
    CSV to write. Defaults to output/vds-vlan-report-<environment>-<UTC timestamp>.csv at
    the repo root; output/ is gitignored.

.PARAMETER PassThru
    Also write the report rows to the pipeline.

.PARAMETER Transcript
    Capture a transcript and log file under logs/.

.EXAMPLE
    .\Export-VdsVlanReport.ps1 -Environment prod

    VLANs on more than one port group of the same vDS, plus every untagged port group.

.EXAMPLE
    .\Export-VdsVlanReport.ps1 -Environment prod -DuplicateScope vCenter -IncludeTrunk

    Duplicates across every vDS in the vCenter, counting VLANs carried by trunk port groups.

.EXAMPLE
    .\Export-VdsVlanReport.ps1 -Environment lab -PassThru |
        Where-Object Finding -eq 'DuplicateVlan' |
        Format-Table VDSwitch, PortGroup, VlanId, SharedWith, VmCount
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Environment,

    [ValidateSet('Switch', 'vCenter')]
    [string]$DuplicateScope = 'Switch',

    [switch]$IncludeTrunk,

    [string]$OutputPath,

    [switch]$PassThru,

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

# ---------------------------------------------------------------------------
# Helpers. Pure functions over plain objects - no vCenter calls - so the rules
# can be tested without infrastructure (tests/Test-VdsVlanReport.ps1).
# ---------------------------------------------------------------------------

function Format-VlanRange {
    <#
    .SYNOPSIS
        Formats VLAN ranges the way vSphere shows them: '100', '100-200', comma-joined.

    .PARAMETER Range
        Objects with integer Start and End.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Range
    )

    $parts = @($Range | Where-Object { $null -ne $_ } | ForEach-Object {
            if ($_.Start -eq $_.End) { [string]$_.Start } else { '{0}-{1}' -f $_.Start, $_.End }
        })
    $parts -join ','
}

function Get-VlanRangeOverlap {
    <#
    .SYNOPSIS
        Returns the VLANs covered by more than one of the given ranges, as merged ranges.

    .DESCRIPTION
        '100-200,150-160' returns 150-160. '100,100' returns 100. Adjacent ranges such as
        '1-10,11-20' share nothing and return nothing.

    .PARAMETER Range
        Objects with integer Start and End, in any order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Range
    )

    $sorted = @($Range | Where-Object { $null -ne $_ } | Sort-Object -Property Start, End)
    $overlaps = New-Object System.Collections.Generic.List[object]
    $coveredTo = -1

    foreach ($r in $sorted) {
        # Every earlier range starts at or before this one, and the one that reaches
        # $coveredTo covers all of [this start, $coveredTo] - so that much is a repeat.
        if ($r.Start -le $coveredTo) {
            $end = [Math]::Min($r.End, $coveredTo)
            $last = if ($overlaps.Count -gt 0) { $overlaps[$overlaps.Count - 1] } else { $null }
            if ($null -ne $last -and $r.Start -le $last.End + 1) {
                $last.End = [Math]::Max($last.End, $end)
            }
            else {
                $overlaps.Add([pscustomobject]@{ Start = $r.Start; End = $end })
            }
        }
        $coveredTo = [Math]::Max($coveredTo, $r.End)
    }

    $overlaps.ToArray()
}

function ConvertTo-VdsVlanInfo {
    <#
    .SYNOPSIS
        Reads a port group's VLAN setting into a type, its VLAN ranges, and display text.

    .DESCRIPTION
        Takes the VmwareDistributedVirtualSwitchVlanSpec from the port group's default port
        config. VlanType is None, VLAN, Trunk, PVLAN or Unknown. Ranges holds the VLAN IDs
        it puts on the wire, and is empty for None and Unknown.

        VlanConfig always leads with a word ('VLAN 100', 'Trunk 1-12') so Excel does not read
        a bare range such as '1-12' as a date when the CSV is opened.

    .PARAMETER VlanSpec
        The port group's Config.DefaultPortConfig.Vlan.

    .PARAMETER PvlanMap
        The owning vDS's Config.PvlanConfig, used to name a PVLAN's type and primary.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object]$VlanSpec,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$PvlanMap
    )

    # @() outside the if: an if that yields an empty array assigns $null, not an empty array.
    $typeNames = @(if ($null -ne $VlanSpec) { $VlanSpec.PSObject.TypeNames })

    # Matched by type name, not -is, so the vSphere type need not be loaded to classify one.
    $kind = 'Unknown'
    foreach ($name in $typeNames) {
        if ($name -like '*VmwareDistributedVirtualSwitchVlanIdSpec') { $kind = 'VlanId'; break }
        if ($name -like '*VmwareDistributedVirtualSwitchTrunkVlanSpec') { $kind = 'Trunk'; break }
        if ($name -like '*VmwareDistributedVirtualSwitchPvlanSpec') { $kind = 'Pvlan'; break }
    }

    switch ($kind) {
        'VlanId' {
            # vSphere uses VLAN ID 0 to mean VLAN type None.
            $id = [int]$VlanSpec.VlanId
            if ($id -eq 0) {
                return [pscustomobject]@{ VlanType = 'None'; Ranges = @(); VlanConfig = 'None' }
            }
            return [pscustomobject]@{
                VlanType   = 'VLAN'
                Ranges     = @([pscustomobject]@{ Start = $id; End = $id })
                VlanConfig = "VLAN $id"
            }
        }
        'Trunk' {
            $ranges = @($VlanSpec.VlanId | Where-Object { $null -ne $_ } | ForEach-Object {
                    [pscustomobject]@{ Start = [int]$_.Start; End = [int]$_.End }
                })
            return [pscustomobject]@{
                VlanType   = 'Trunk'
                Ranges     = $ranges
                VlanConfig = "Trunk $(Format-VlanRange -Range $ranges)"
            }
        }
        'Pvlan' {
            $id = [int]$VlanSpec.PvlanId
            $entry = @($PvlanMap | Where-Object { $null -ne $_ -and [int]$_.SecondaryVlanId -eq $id }) |
                Select-Object -First 1
            $text = if ($null -ne $entry) {
                "PVLAN $id ($($entry.PvlanType), primary $($entry.PrimaryVlanId))"
            }
            else {
                "PVLAN $id (not in the vDS PVLAN map)"
            }
            return [pscustomobject]@{
                VlanType   = 'PVLAN'
                Ranges     = @([pscustomobject]@{ Start = $id; End = $id })
                VlanConfig = $text
            }
        }
    }

    $label = if ($typeNames.Count -gt 0) { $typeNames[0] } else { 'no VLAN setting' }
    [pscustomobject]@{ VlanType = 'Unknown'; Ranges = @(); VlanConfig = "Unknown ($label)" }
}

function ConvertTo-VdsVlanFinding {
    <#
    .SYNOPSIS
        Builds one report row for a port group record.

    .PARAMETER Finding
        DuplicateVlan, NoVlan or TrunkRangeOverlap.

    .PARAMETER Portgroup
        A port group record, as built by the collection loop.

    .PARAMETER VlanId
        The VLAN the finding is about, where there is a single one.

    .PARAMETER SharedWith
        For DuplicateVlan, the other port groups carrying the same VLAN.

    .PARAMETER Detail
        One line of explanation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Finding,

        [Parameter(Mandatory)]
        [object]$Portgroup,

        [object]$VlanId,

        [string]$SharedWith = '',

        [string]$Detail = ''
    )

    [pscustomobject]@{
        Finding      = $Finding
        vCenter      = $Portgroup.vCenter
        Datacenter   = $Portgroup.Datacenter
        VDSwitch     = $Portgroup.VDSwitch
        PortGroup    = $Portgroup.PortGroup
        VlanType     = $Portgroup.Vlan.VlanType
        VlanId       = $VlanId
        VlanConfig   = $Portgroup.Vlan.VlanConfig
        SharedWith   = $SharedWith
        VmCount      = $Portgroup.VmCount
        Detail       = $Detail
        PortGroupKey = $Portgroup.PortGroupKey
    }
}

function Find-VdsVlanFinding {
    <#
    .SYNOPSIS
        Finds VLANs on more than one port group, untagged port groups, and overlapping trunks.

    .DESCRIPTION
        Works only on the records passed in. Each record carries vCenter, Datacenter,
        VDSwitch, SwitchKey, PortGroup, PortGroupKey, VmCount, and Vlan (from
        ConvertTo-VdsVlanInfo). Uplink and NSX-backed port groups are expected to have been
        left out by the caller.

        VLAN 0 (untagged) and 4095 are never counted as duplicates. Untagged port groups are
        reported once each as NoVlan instead of as duplicates of one another.

    .PARAMETER Portgroup
        The port group records to check.

    .PARAMETER DuplicateScope
        Switch: duplicates are counted within each vDS. vCenter: across all of them.

    .PARAMETER IncludeTrunk
        Count every VLAN in a trunk port group's ranges in the duplicate check.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Portgroup,

        [ValidateSet('Switch', 'vCenter')]
        [string]$DuplicateScope = 'Switch',

        [switch]$IncludeTrunk
    )

    # '<scope>|<VLAN>' -> the VLAN and the port groups carrying it within that scope.
    $carriers = @{}

    foreach ($pg in $Portgroup) {
        $vlan = $pg.Vlan
        $ids = @()

        switch ($vlan.VlanType) {
            'None' {
                ConvertTo-VdsVlanFinding -Finding 'NoVlan' -Portgroup $pg -VlanId 0 `
                    -Detail 'VLAN type None - traffic leaves this port group untagged.'
            }
            'Trunk' {
                $overlap = @(Get-VlanRangeOverlap -Range $vlan.Ranges)
                if ($overlap.Count -gt 0) {
                    ConvertTo-VdsVlanFinding -Finding 'TrunkRangeOverlap' -Portgroup $pg -VlanId $null `
                        -Detail "VLANs $(Format-VlanRange -Range $overlap) are in more than one of this trunk's ranges."
                }
                if ($IncludeTrunk) {
                    # A set, so a VLAN this trunk itself lists twice still counts it once.
                    $set = New-Object 'System.Collections.Generic.HashSet[int]'
                    foreach ($r in $vlan.Ranges) {
                        for ($i = $r.Start; $i -le $r.End; $i++) { [void]$set.Add($i) }
                    }
                    $ids = @($set)
                }
            }
            'VLAN' { $ids = @($vlan.Ranges[0].Start) }
            'PVLAN' { $ids = @($vlan.Ranges[0].Start) }
        }

        $scope = if ($DuplicateScope -eq 'Switch') { $pg.SwitchKey } else { 'vCenter' }
        foreach ($id in $ids) {
            if ($id -lt 1 -or $id -gt 4094) { continue }
            $key = '{0}|{1}' -f $scope, $id
            if (-not $carriers.ContainsKey($key)) {
                $list = New-Object System.Collections.Generic.List[object]
                $carriers[$key] = [pscustomobject]@{ VlanId = $id; Portgroups = $list }
            }
            $carriers[$key].Portgroups.Add($pg)
        }
    }

    foreach ($entry in $carriers.Values) {
        if ($entry.Portgroups.Count -lt 2) { continue }

        $members = $entry.Portgroups.ToArray()
        $switchCount = @($members | ForEach-Object { $_.SwitchKey } | Sort-Object -Unique).Count
        $where = if ($switchCount -eq 1) { "vDS '$($members[0].VDSwitch)'" } else { "$switchCount vDS" }
        $detail = "VLAN $($entry.VlanId) is on $($members.Count) port groups on $where."

        foreach ($pg in $members) {
            $others = @($members | Where-Object { $_.PortGroupKey -ne $pg.PortGroupKey } | ForEach-Object {
                    if ($DuplicateScope -eq 'Switch') { $_.PortGroup } else { '{0}/{1}' -f $_.VDSwitch, $_.PortGroup }
                })
            ConvertTo-VdsVlanFinding -Finding 'DuplicateVlan' -Portgroup $pg -VlanId $entry.VlanId `
                -SharedWith ($others -join '; ') -Detail $detail
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Relative path assumes this script lives in scripts/<platform>/.
Import-Module (Join-Path $PSScriptRoot '..\..\modules\Richo.Common\Richo.Common.psd1') -Force

Assert-RichoModule -Name VMware.VimAutomation.Core

$transcriptPath = if ($Transcript) { Start-RichoTranscript } else { $null }
$viServer = $null
$collectedUtc = (Get-Date).ToUniversalTime()
$collected = $collectedUtc.ToString('yyyy-MM-dd HH:mm:ssZ')

# Report columns, in order. The last two are stamped on every row so any CSV traces back to
# the script revision and the run that produced it.
$columns = @(
    'Finding', 'vCenter', 'Datacenter', 'VDSwitch', 'PortGroup', 'VlanType', 'VlanId',
    'VlanConfig', 'SharedWith', 'VmCount', 'Detail', 'PortGroupKey',
    @{ Name = 'ScriptVersion'; Expression = { $ScriptVersion } },
    @{ Name = 'CollectedUtc'; Expression = { $collected } }
)
$columnNames = @($columns | ForEach-Object { if ($_ -is [hashtable]) { $_.Name } else { $_ } })

try {
    $config = Get-RichoConfig -Name $Environment
    if (-not $config.PSObject.Properties['vcenter']) {
        throw "Environment '$($config.Name)' has no vcenter section in its config."
    }
    $vCenterName = $config.vcenter.server

    Write-RichoLog "Export-VdsVlanReport $ScriptVersion - $vCenterName (environment '$($config.Name)')." -Level INFO
    $trunkNote = if ($IncludeTrunk) { 'included in' } else { 'left out of' }
    Write-RichoLog "Duplicate scope: $DuplicateScope. Trunk port groups are $trunkNote the duplicate check." -Level INFO

    # Settle the output path before connecting, so a bad path fails before any vCenter work.
    if (-not $OutputPath) {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $fileName = 'vds-vlan-report-{0}-{1}.csv' -f $config.Name, $collectedUtc.ToString('yyyyMMdd-HHmmss')
        $OutputPath = Join-Path (Join-Path $repoRoot 'output') $fileName
    }
    $outputDirectory = Split-Path -Path $OutputPath -Parent
    if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }

    # ---- Connect ----------------------------------------------------------
    $credential = Get-RichoCredential -Name $config.vcenter.credentialName
    Write-RichoLog "Connecting to $vCenterName." -Level INFO
    $viServer = Connect-VIServer -Server $vCenterName -Credential $credential -ErrorAction Stop

    # ---- Read current state ----------------------------------------------
    # One Get-View per datacenter per object type, fetching only the properties used. Config
    # is fetched whole rather than as Config.DefaultPortConfig.Vlan: those nested properties
    # are declared as base types, and the property collector can refuse a path into a
    # property only the subtype has.
    $records = New-Object System.Collections.Generic.List[object]
    $switchCount = 0
    $skippedUplink = 0
    $skippedNsx = New-Object System.Collections.Generic.List[string]
    $unknownVlan = New-Object System.Collections.Generic.List[string]

    $datacenters = @(Get-View -Server $viServer -ViewType Datacenter -Property Name)
    foreach ($datacenter in $datacenters) {
        $switches = @(Get-View -Server $viServer -ViewType VmwareDistributedVirtualSwitch -SearchRoot $datacenter.MoRef -Property Name, Config)
        if ($switches.Count -eq 0) { continue }
        $switchCount += $switches.Count

        $switchByKey = @{}
        $uplinkKeys = @{}
        foreach ($vds in $switches) {
            $switchByKey[$vds.MoRef.Value] = $vds
            foreach ($uplink in @($vds.Config.UplinkPortgroup | Where-Object { $null -ne $_ })) {
                $uplinkKeys[$uplink.Value] = $true
            }
        }

        $portgroups = @(Get-View -Server $viServer -ViewType DistributedVirtualPortgroup -SearchRoot $datacenter.MoRef -Property Name, Vm, Config)
        foreach ($portgroup in $portgroups) {
            $switchKey = $portgroup.Config.DistributedVirtualSwitch.Value

            # Not on a VMware vDS (e.g. a third-party switch), so there is no vDS VLAN setting.
            if (-not $switchByKey.ContainsKey($switchKey)) { continue }

            if ($uplinkKeys.ContainsKey($portgroup.MoRef.Value)) {
                $skippedUplink++
                continue
            }

            # BackingType exists from vSphere 7.0; absent or 'standard' is an ordinary port group.
            $backing = if ($portgroup.Config.PSObject.Properties['BackingType']) { $portgroup.Config.BackingType } else { $null }
            if ($backing -eq 'nsx') {
                $skippedNsx.Add($portgroup.Name)
                continue
            }

            $vds = $switchByKey[$switchKey]
            $portSetting = $portgroup.Config.DefaultPortConfig
            $vlanSpec = if ($null -ne $portSetting -and $portSetting.PSObject.Properties['Vlan']) { $portSetting.Vlan } else { $null }
            $vlan = ConvertTo-VdsVlanInfo -VlanSpec $vlanSpec -PvlanMap $vds.Config.PvlanConfig
            if ($vlan.VlanType -eq 'Unknown') {
                $unknownVlan.Add(('{0}/{1}: {2}' -f $vds.Name, $portgroup.Name, $vlan.VlanConfig))
            }

            # @($null).Count is 1, so an empty Vm list has to be tested for, not counted.
            $vmCount = if ($null -eq $portgroup.Vm) { 0 } else { @($portgroup.Vm).Count }

            $records.Add([pscustomobject]@{
                    vCenter      = $vCenterName
                    Datacenter   = $datacenter.Name
                    VDSwitch     = $vds.Name
                    SwitchKey    = $switchKey
                    PortGroup    = $portgroup.Name
                    PortGroupKey = $portgroup.MoRef.Value
                    VmCount      = $vmCount
                    Vlan         = $vlan
                })
        }
    }

    Write-RichoLog ('Read {0} port group(s) on {1} vDS across {2} datacenter(s). Skipped {3} uplink and {4} NSX-backed port group(s).' -f
        $records.Count, $switchCount, $datacenters.Count, $skippedUplink, $skippedNsx.Count) -Level INFO
    if ($skippedNsx.Count -gt 0) {
        Write-RichoLog "NSX-backed, not checked: $($skippedNsx -join ', ')" -Level DEBUG
    }
    foreach ($item in $unknownVlan) {
        Write-RichoLog "VLAN setting not recognised, port group not checked - $item" -Level WARN
    }

    # ---- Analyse and export ----------------------------------------------
    $rows = @(Find-VdsVlanFinding -Portgroup $records.ToArray() -DuplicateScope $DuplicateScope -IncludeTrunk:$IncludeTrunk |
            Sort-Object -Property Finding, Datacenter, VDSwitch, VlanId, PortGroup |
            Select-Object -Property $columns)

    if ($rows.Count -gt 0) {
        $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    }
    else {
        # Export-Csv writes no header for no rows. A header-only file still shows the run
        # happened and found nothing, which is what a change record wants as evidence.
        '"{0}"' -f ($columnNames -join '","') | Set-Content -Path $OutputPath -Encoding UTF8
    }

    $duplicates = @($rows | Where-Object { $_.Finding -eq 'DuplicateVlan' })
    $duplicateIds = @($duplicates | ForEach-Object { $_.VlanId } | Sort-Object -Unique)
    $noVlan = @($rows | Where-Object { $_.Finding -eq 'NoVlan' })
    $overlaps = @($rows | Where-Object { $_.Finding -eq 'TrunkRangeOverlap' })

    Write-RichoLog "DuplicateVlan: $($duplicateIds.Count) VLAN ID(s) on more than one port group ($($duplicates.Count) row(s))." -Level INFO
    Write-RichoLog "NoVlan: $($noVlan.Count) port group(s)." -Level INFO
    Write-RichoLog "TrunkRangeOverlap: $($overlaps.Count) port group(s)." -Level INFO
    Write-RichoLog "Report written: $OutputPath" -Level INFO

    if ($PassThru) { $rows }
}
catch {
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    # Only the session this run opened; any other vCenter session in this console is left alone.
    if ($null -ne $viServer) {
        Disconnect-VIServer -Server $viServer -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}
