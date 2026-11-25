<#
.SYNOPSIS
    Clones a VMware ESXi image profile and swaps the inbox VIBs for newer vendor VIBs
    (Cisco, NetApp and others), ready for Auto Deploy.

.DESCRIPTION
    Builds a vendor image profile for Auto Deploy from two inputs:

      1. The VMware ESXi offline bundle (the base depot). The image profile to clone is
         chosen from the profiles in this depot, either by -BaseImageProfile or from a
         numbered menu. Profiles that an Auto Deploy rule in vCenter already uses are
         marked in the menu with the rule name.
      2. One or more vendor depots (Cisco UCS add-on, Cisco nenic/nfnic driver bundles,
         NetApp NFS plug-in and so on).

    For every VIB in the vendor depots, the script compares it with the VIB of the same
    name in the base profile:

      Replace  The base profile has an older version. The old VIB is removed and the
               vendor VIB is added.
      Add      The base profile has no VIB of that name. The vendor VIB is added, unless
               -ReplaceOnly is set.
      Keep     The base profile already has the same version. Nothing changes.
      Older    The vendor VIB is older than the one in the base profile. The base VIB is
               kept and a warning is logged.

    When a vendor depot carries several versions of one VIB, the newest is used.
    VMware-signed VIBs found in a vendor depot (a vendor custom image carries a full
    ESXi build) are ignored unless named in -VendorVibName.

    VIB names listed in -RemoveVib are removed from the clone whether or not a vendor
    VIB replaces them. Use this for an inbox driver that the vendor ships under a
    different name.

    The full plan is logged before anything is changed. After the changes, the new
    profile is read back and every planned change is verified; the run fails if any
    VIB is not at the expected version.

    WHAT IT CHANGES

      - The cloned image profile exists only in this PowerShell session until it is
        exported or staged.
      - -ExportBundlePath writes an offline bundle ZIP. Import it in the vSphere Client
        under Auto Deploy > Software Depots.
      - -ExportIsoPath writes an installer ISO.
      - -StageInAutoDeploy creates a new deploy rule that holds the profile, which
        uploads the profile and its VIBs to the Auto Deploy server. The rule is created
        with a pattern that matches no host and is NOT added to the active or working
        rule set, so no host boots from it. Edit the pattern and activate the rule
        when the change is approved.

    WHAT IT READS

      - Auto Deploy rules in vCenter, to mark which profiles are in use.
      - The base and vendor depots, loaded into this session only. Any depots already
        loaded in the session are unloaded first so the vendor VIB list is exact.

    Image profiles and depots imported into the vCenter Auto Deploy Software Depots
    page are not exposed to PowerCLI as a depot URL. Point -BaseDepot at the same ESXi
    offline bundle ZIP that was imported there, or at a ZIP exported from it.

    PREREQUISITES

      - VMware PowerCLI 13.x with VMware.ImageBuilder and VMware.DeployAutomation.
      - Python 3.7 or later configured for PowerCLI (Set-PowerCLIConfiguration
        -PythonPath). Image Builder in PowerCLI 13 does not run without it.
      - vCenter with the Auto Deploy and Image Builder services running.
      - Vendor driver downloads are often a ZIP that contains the real depot ZIP plus
        release notes. Extract it and pass the inner ZIP.

.PARAMETER Environment
    Environment key from config/environments.json. Defaults to the file's "default"
    entry.

.PARAMETER BaseDepot
    Path to the VMware ESXi offline bundle ZIP, or an online depot URL.

.PARAMETER VendorDepot
    One or more paths (or URLs) to vendor depot ZIPs.

.PARAMETER BaseImageProfile
    Name of the image profile in the base depot to clone, for example
    ESXi-8.0U3e-24677879-standard. When omitted, a numbered menu is shown.

.PARAMETER NewProfileName
    Name for the new image profile. Defaults to the base name with "-standard" or
    "-no-tools" replaced by "-custom-<yyyyMMdd>".

.PARAMETER ProfileVendor
    Vendor field written into the new image profile. Defaults to "Custom".

.PARAMETER Description
    Description written into the new image profile. Defaults to a generated line that
    names the base profile and the vendor depots.

.PARAMETER VendorVibName
    Restricts the vendor VIBs that are applied to these names. Every name given must
    exist in a vendor depot. When omitted, every VIB in the vendor depots is
    considered.

.PARAMETER RemoveVib
    VIB names to remove from the clone. A name here must not also be a vendor VIB that
    is being applied.

.PARAMETER ReplaceOnly
    Only replace VIBs that already exist in the base profile. Vendor VIBs with no
    counterpart in the base profile are skipped.

.PARAMETER AcceptanceLevel
    Sets the acceptance level of the new profile. Only needed when a vendor VIB is at a
    lower level than the base profile, for example CommunitySupported.

.PARAMETER ExportBundlePath
    Writes the new profile to this offline bundle ZIP. The file must not exist.

.PARAMETER ExportIsoPath
    Writes the new profile to this ISO. The file must not exist.

.PARAMETER StageInAutoDeploy
    Creates an inactive deploy rule holding the new profile, which uploads it to Auto
    Deploy. The rule is not activated.

.PARAMETER DeployRuleName
    Name of the staging deploy rule. Defaults to "Staged-<NewProfileName>".

.PARAMETER DeployRulePattern
    Pattern for the staging deploy rule. Defaults to a vendor pattern that matches no
    host.

.PARAMETER Transcript
    Writes a transcript to logs/.

.EXAMPLE
    .\New-AutoDeployVendorImageProfile.ps1 -Environment lab `
        -BaseDepot 'D:\Depots\VMware-ESXi-8.0U3e-24677879-depot.zip' `
        -VendorDepot 'D:\Depots\Cisco-addon-ESXi-8.0U3.zip', 'D:\Depots\NetAppNasPlugin.v23.zip' `
        -WhatIf

    Shows the menu of base profiles, then logs the swap plan. Nothing is cloned,
    exported or staged.

.EXAMPLE
    .\New-AutoDeployVendorImageProfile.ps1 -Environment prod `
        -BaseDepot 'D:\Depots\VMware-ESXi-8.0U3e-24677879-depot.zip' `
        -VendorDepot 'D:\Depots\Cisco-nenic-2.0.15.0.zip', 'D:\Depots\Cisco-nfnic-5.0.0.43.zip' `
        -BaseImageProfile 'ESXi-8.0U3e-24677879-standard' `
        -NewProfileName 'ESXi-8.0U3e-24677879-Cisco-NetApp' `
        -ExportBundlePath 'D:\Depots\ESXi-8.0U3e-24677879-Cisco-NetApp.zip' `
        -StageInAutoDeploy

    Clones the standard profile, swaps in the Cisco drivers, exports an offline bundle
    and uploads the profile to Auto Deploy in an inactive rule.

.EXAMPLE
    .\New-AutoDeployVendorImageProfile.ps1 -Environment lab `
        -BaseDepot 'D:\Depots\VMware-ESXi-8.0U3e-24677879-depot.zip' `
        -VendorDepot 'D:\Depots\Cisco-addon-ESXi-8.0U3.zip' `
        -VendorVibName nenic, nfnic -ReplaceOnly `
        -ExportBundlePath 'D:\Depots\ESXi-8.0U3e-nenic-nfnic.zip'

    Applies only the nenic and nfnic VIBs from the Cisco add-on, and only where the
    base profile already carries them.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Environment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BaseDepot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$VendorDepot,

    [string]$BaseImageProfile,

    [string]$NewProfileName,

    [ValidateNotNullOrEmpty()]
    [string]$ProfileVendor = 'Custom',

    [string]$Description,

    [string[]]$VendorVibName,

    [string[]]$RemoveVib,

    [switch]$ReplaceOnly,

    [ValidateSet('VMwareCertified', 'VMwareAccepted', 'PartnerSupported', 'CommunitySupported')]
    [string]$AcceptanceLevel,

    [string]$ExportBundlePath,

    [string]$ExportIsoPath,

    [switch]$StageInAutoDeploy,

    [string]$DeployRuleName,

    [string[]]$DeployRulePattern = @('vendor=RICHO-STAGED-NO-MATCH'),

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Import-RequiredModules {
    <#
    .SYNOPSIS
        Loads Richo.Common and the PowerCLI modules this script uses, where not already loaded.

    .DESCRIPTION
        Each load is guarded by Get-Module, so a module already in the session (including a
        pinned bundle) is left as it is. Nothing is installed or updated.

    .EXAMPLE
        Import-RequiredModules
    #>
    [CmdletBinding()]
    param()

    $wanted = @(
        [pscustomobject]@{ Name = 'Richo.Common'; Source = (Join-Path $PSScriptRoot '..\..\modules\Richo.Common\Richo.Common.psd1') }
        [pscustomobject]@{ Name = 'VMware.VimAutomation.Core'; Source = 'VMware.VimAutomation.Core' }
        [pscustomobject]@{ Name = 'VMware.ImageBuilder'; Source = 'VMware.ImageBuilder' }
        [pscustomobject]@{ Name = 'VMware.DeployAutomation'; Source = 'VMware.DeployAutomation' }
    )

    foreach ($module in $wanted) {
        $name = $module.Name
        if (Get-Module -Name $name) { continue }
        try {
            Import-Module -Name $module.Source -ErrorAction Stop
        }
        catch {
            throw "Module '$name' could not be loaded: $($_.Exception.Message). VMware PowerCLI 13.x provides the VMware modules."
        }
    }
}

function ConvertTo-VibVersionSegment {
    <#
    .SYNOPSIS
        Splits one dotted version string into comparable segments.

    .DESCRIPTION
        Each segment becomes an object with a numeric part (leading digits, or -1 when there
        are none) and the remaining text, so "4" sorts below "10" and "0a" sorts above "0".

    .PARAMETER Text
        The dotted version text, for example "2.0.15.0".

    .EXAMPLE
        ConvertTo-VibVersionSegment -Text '2.0.15.0'
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $segments = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return , $segments.ToArray() }

    foreach ($part in ($Text -split '\.')) {
        $number = [long]-1
        $rest = $part
        if ($part -match '^(\d+)(.*)$') {
            $number = [long]$Matches[1]
            $rest = $Matches[2]
        }
        $segments.Add([pscustomobject]@{ Number = $number; Rest = $rest })
    }
    return , $segments.ToArray()
}

function Compare-VibVersionText {
    <#
    .SYNOPSIS
        Compares two dotted version strings segment by segment. Returns -1, 0 or 1.

    .PARAMETER Left
        First version text.

    .PARAMETER Right
        Second version text.

    .EXAMPLE
        Compare-VibVersionText -Left '2.0.15.0' -Right '2.0.4.0'
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyString()][string]$Left, [AllowEmptyString()][string]$Right)

    $a = ConvertTo-VibVersionSegment -Text $Left
    $b = ConvertTo-VibVersionSegment -Text $Right
    $count = [Math]::Max($a.Count, $b.Count)

    for ($i = 0; $i -lt $count; $i++) {
        $x = if ($i -lt $a.Count) { $a[$i] } else { [pscustomobject]@{ Number = [long]0; Rest = '' } }
        $y = if ($i -lt $b.Count) { $b[$i] } else { [pscustomobject]@{ Number = [long]0; Rest = '' } }

        if ($x.Number -lt $y.Number) { return -1 }
        if ($x.Number -gt $y.Number) { return 1 }

        $text = [string]::Compare([string]$x.Rest, [string]$y.Rest, [StringComparison]::OrdinalIgnoreCase)
        if ($text -lt 0) { return -1 }
        if ($text -gt 0) { return 1 }
    }
    return 0
}

function Compare-VibVersion {
    <#
    .SYNOPSIS
        Compares two ESXi VIB versions. Returns -1 when Left is older, 0 when equal, 1 when newer.

    .DESCRIPTION
        A VIB version is "<version>-<release>", for example "2.0.15.0-1OEM.800.1.0.20613240"
        or "1.0.45.0-1vmw.800.1.0.20513097". The version part decides. When the version parts
        are equal, the leading number of the release part decides ("2OEM" is newer than
        "1OEM"). The rest of the release part names the ESXi build the VIB was compiled
        against and the packager (vmw, OEM), which do not order one VIB against another, so
        they are not compared.

    .PARAMETER Left
        First VIB version.

    .PARAMETER Right
        Second VIB version.

    .EXAMPLE
        Compare-VibVersion -Left '2.0.15.0-1OEM.800.1.0.20613240' -Right '1.0.45.0-1vmw.800.1.0.20513097'
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyString()][string]$Left, [AllowEmptyString()][string]$Right)

    $leftVersion, $leftRelease = ([string]$Left).Trim() -split '-', 2
    $rightVersion, $rightRelease = ([string]$Right).Trim() -split '-', 2

    $result = Compare-VibVersionText -Left $leftVersion -Right $rightVersion
    if ($result -ne 0) { return $result }

    $leftBuild = [long]0
    $rightBuild = [long]0
    if ([string]$leftRelease -match '^(\d+)') { $leftBuild = [long]$Matches[1] }
    if ([string]$rightRelease -match '^(\d+)') { $rightBuild = [long]$Matches[1] }

    if ($leftBuild -lt $rightBuild) { return -1 }
    if ($leftBuild -gt $rightBuild) { return 1 }
    return 0
}

function Select-NewestVib {
    <#
    .SYNOPSIS
        Reduces a list of vendor VIB candidates to the newest version of each name.

    .DESCRIPTION
        A vendor depot can carry several versions of one VIB, and two vendor depots can carry
        the same VIB. Only the newest is applied. Every name that had more than one version
        is reported in the Superseded property so the choice is visible in the plan.

    .PARAMETER Candidate
        Objects with Name, Version and Source properties.

    .EXAMPLE
        $newest = Select-NewestVib -Candidate $vendorCandidates
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Candidate
    )

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($group in ($Candidate | Group-Object -Property Name)) {
        $best = $null
        foreach ($vib in $group.Group) {
            if ($null -eq $best) { $best = $vib; continue }
            if ((Compare-VibVersion -Left $vib.Version -Right $best.Version) -gt 0) { $best = $vib }
        }
        $others = @($group.Group | Where-Object { $_.Version -ne $best.Version } | ForEach-Object { "$($_.Version) ($($_.Source))" })
        $result.Add([pscustomobject]@{
                Name       = $best.Name
                Version    = $best.Version
                Source     = $best.Source
                Package    = $best.Package
                Superseded = ($others -join '; ')
            })
    }
    return , $result.ToArray()
}

function Get-VibSwapPlan {
    <#
    .SYNOPSIS
        Works out what has to change in the base profile to carry the vendor VIBs.

    .DESCRIPTION
        Returns one row per VIB that is touched or deliberately left alone:

          Replace  base has an older version; remove it and add the vendor VIB
          Add      base has no VIB of that name; add the vendor VIB
          Keep     base already has this version
          Older    vendor VIB is older than base; base kept
          Skip     not in base and -ReplaceOnly is set
          Remove   named in -RemoveVib and present in base
          Absent   named in -RemoveVib but not in base

        Only Replace, Add and Remove rows lead to a change.

    .PARAMETER BaseVib
        The base profile's VIBs (objects with Name and Version).

    .PARAMETER VendorVib
        The newest vendor VIB per name, as returned by Select-NewestVib.

    .PARAMETER RemoveVib
        VIB names to remove from the clone.

    .PARAMETER ReplaceOnly
        Skip vendor VIBs that have no counterpart in the base profile.

    .EXAMPLE
        $plan = Get-VibSwapPlan -BaseVib $base.VibList -VendorVib $newest -RemoveVib 'nmlx4-en'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$BaseVib,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$VendorVib,

        [string[]]$RemoveVib,

        [switch]$ReplaceOnly
    )

    $removeNames = @($RemoveVib | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $clash = @($VendorVib | Where-Object { $removeNames -contains $_.Name } | ForEach-Object { $_.Name })
    if ($clash.Count -gt 0) {
        throw "These VIBs are both applied from a vendor depot and listed in -RemoveVib: $($clash -join ', '). Remove them from -RemoveVib, or exclude them with -VendorVibName."
    }

    $baseByName = @{}
    foreach ($vib in $BaseVib) { $baseByName[[string]$vib.Name] = $vib }

    $plan = New-Object System.Collections.Generic.List[object]

    foreach ($vib in ($VendorVib | Sort-Object -Property Name)) {
        $baseVersion = ''
        $action = ''
        if ($baseByName.ContainsKey([string]$vib.Name)) {
            $baseVersion = [string]$baseByName[[string]$vib.Name].Version
            switch (Compare-VibVersion -Left $vib.Version -Right $baseVersion) {
                1 { $action = 'Replace' }
                0 { $action = 'Keep' }
                default { $action = 'Older' }
            }
        }
        elseif ($ReplaceOnly) {
            $action = 'Skip'
        }
        else {
            $action = 'Add'
        }

        $plan.Add([pscustomobject]@{
                Action        = $action
                Name          = [string]$vib.Name
                BaseVersion   = $baseVersion
                VendorVersion = [string]$vib.Version
                Source        = [string]$vib.Source
                Superseded    = [string]$vib.Superseded
                Package       = $vib.Package
            })
    }

    foreach ($name in ($removeNames | Sort-Object -Unique)) {
        $action = 'Absent'
        $baseVersion = ''
        if ($baseByName.ContainsKey($name)) {
            $action = 'Remove'
            $baseVersion = [string]$baseByName[$name].Version
        }
        $plan.Add([pscustomobject]@{
                Action        = $action
                Name          = $name
                BaseVersion   = $baseVersion
                VendorVersion = ''
                Source        = '-RemoveVib'
                Superseded    = ''
                Package       = $null
            })
    }

    return , $plan.ToArray()
}

function Get-DefaultProfileName {
    <#
    .SYNOPSIS
        Derives a name for the new image profile from the base profile name.

    .PARAMETER BaseName
        The base image profile name.

    .PARAMETER Date
        Date stamped into the name. Defaults to today.

    .EXAMPLE
        Get-DefaultProfileName -BaseName 'ESXi-8.0U3e-24677879-standard'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseName,
        [datetime]$Date = (Get-Date)
    )

    $suffix = 'custom-' + $Date.ToString('yyyyMMdd')
    if ($BaseName -match '(?i)-(standard|no-tools)$') {
        return ($BaseName -replace '(?i)-(standard|no-tools)$', "-$suffix")
    }
    return "$BaseName-$suffix"
}

function Get-RuleImageProfileName {
    <#
    .SYNOPSIS
        The image profile name in one deploy rule item, or an empty string when the item is
        a host profile, cluster, folder or script bundle.

    .DESCRIPTION
        An image profile is identified by type first, then by carrying a VIB list, which no
        other rule item has. A plain string item counts only when it has the shape of an
        ESXi image profile name.

    .PARAMETER Item
        One entry from a deploy rule's ItemList.

    .EXAMPLE
        Get-RuleImageProfileName -Item $rule.ItemList[0]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Item)

    if ($null -eq $Item) { return '' }
    if ($Item -is [string]) {
        if ($Item -match '(?i)^ESXi-.*\d{6,}') { return [string]$Item }
        return ''
    }
    $typeName = ''
    try { $typeName = [string]$Item.GetType().FullName } catch { $typeName = '' }
    if ($typeName -match '(?i)ImageProfile') { return [string]$Item.Name }
    if ($Item.PSObject.Properties.Name -contains 'VibList') { return [string]$Item.Name }
    return ''
}

function Get-AutoDeployProfileUsage {
    <#
    .SYNOPSIS
        Maps each image profile name used by an Auto Deploy rule to the rules that use it.

    .DESCRIPTION
        Rules in the active rule set are marked "(active)". When the active rule set cannot
        be read, rules are listed without the marker. Returns an empty map when Auto Deploy
        cannot be queried, after logging why.

    .EXAMPLE
        $usage = Get-AutoDeployProfileUsage
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $usage = @{}
    $rules = @()
    try {
        $rules = @(Get-DeployRule -ErrorAction Stop)
    }
    catch {
        Write-RichoLog "Auto Deploy rules could not be read: $($_.Exception.Message). Profiles will not be marked as in use." -Level WARN
        return $usage
    }

    $activeNames = @()
    try {
        $activeNames = @(Get-DeployRuleSet -ErrorAction Stop | ForEach-Object { [string]$_.Name })
    }
    catch {
        Write-RichoLog "The active rule set could not be read: $($_.Exception.Message)." -Level DEBUG
    }

    foreach ($rule in $rules) {
        foreach ($item in @($rule.ItemList)) {
            $name = Get-RuleImageProfileName -Item $item
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $label = [string]$rule.Name
            if ($activeNames -contains $label) { $label = "$label (active)" }
            if (-not $usage.ContainsKey($name)) { $usage[$name] = New-Object System.Collections.Generic.List[string] }
            [void]$usage[$name].Add($label)
        }
    }
    Write-RichoLog "Read $($rules.Count) Auto Deploy rule(s); $($usage.Count) image profile(s) in use." -Level INFO
    return $usage
}

function Select-BaseImageProfile {
    <#
    .SYNOPSIS
        Returns the base image profile, by name or from a numbered menu.

    .PARAMETER ImageProfile
        The image profiles available in the base depot.

    .PARAMETER Name
        Profile name given on the command line. When set, no menu is shown.

    .PARAMETER Usage
        Map of profile name to the Auto Deploy rules that use it.

    .EXAMPLE
        $base = Select-BaseImageProfile -ImageProfile $profiles -Usage $usage
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ImageProfile,

        [string]$Name,

        [hashtable]$Usage = @{}
    )

    if ($ImageProfile.Count -eq 0) {
        throw 'The base depot contains no image profiles. -BaseDepot must be the VMware ESXi offline bundle, not a vendor add-on or driver ZIP.'
    }

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $match = @($ImageProfile | Where-Object { $_.Name -eq $Name })
        if ($match.Count -eq 0) {
            $known = ($ImageProfile | ForEach-Object { $_.Name } | Sort-Object) -join ', '
            throw "Image profile '$Name' is not in the base depot. Profiles in the depot: $known"
        }
        return $match[0]
    }

    if (-not [Environment]::UserInteractive) {
        throw 'No -BaseImageProfile given and the session is not interactive, so the profile cannot be chosen from a menu.'
    }

    $sorted = @($ImageProfile | Sort-Object -Property Name)
    Write-RichoLog 'Image profiles in the base depot:' -Level INFO
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $line = '  {0,2}. {1}' -f ($i + 1), $sorted[$i].Name
        if ($Usage.ContainsKey([string]$sorted[$i].Name)) {
            $line += '   [Auto Deploy: ' + (($Usage[[string]$sorted[$i].Name]) -join ', ') + ']'
        }
        Write-RichoLog $line -Level INFO
    }

    while ($true) {
        $answer = Read-Host "Select the profile to clone (1-$($sorted.Count), Q to quit)"
        if ($answer -match '^(?i)q$') { throw 'Stopped by the operator at base profile selection.' }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $sorted.Count) {
            return $sorted[$number - 1]
        }
        Write-RichoLog "'$answer' is not a number between 1 and $($sorted.Count)." -Level WARN
    }
}

function Get-SessionVibKey {
    <#
    .SYNOPSIS
        Identity of a software package as Name|Version|Vendor, for set differences.

    .PARAMETER Package
        A software package object.

    .EXAMPLE
        Get-SessionVibKey -Package $vib
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Package)

    return ('{0}|{1}|{2}' -f $Package.Name, $Package.Version, $Package.Vendor)
}

function Add-DepotToSession {
    <#
    .SYNOPSIS
        Loads one software depot into the session and returns the VIBs it added.

    .DESCRIPTION
        The VIBs a depot contributes are the packages present after the load that were not
        present before it. A VIB identical to one already loaded is not returned, which is
        correct here: an identical VIB is never a change.

    .PARAMETER Depot
        Path or URL of the depot.

    .EXAMPLE
        $vibs = Add-DepotToSession -Depot 'D:\Depots\Cisco-addon.zip'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Depot)

    $isUrl = $Depot -match '^(?i)https?://'
    if (-not $isUrl -and -not (Test-Path -LiteralPath $Depot -PathType Leaf)) {
        throw "Depot file not found: $Depot"
    }

    $before = @{}
    foreach ($vib in @(Get-EsxSoftwarePackage -ErrorAction SilentlyContinue)) { $before[(Get-SessionVibKey -Package $vib)] = $true }

    $source = $Depot
    if (-not $isUrl) { $source = (Resolve-Path -LiteralPath $Depot).ProviderPath }

    try {
        Add-EsxSoftwareDepot -DepotUrl $source -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Depot '$Depot' could not be loaded: $($_.Exception.Message). A vendor download is often a ZIP that contains the depot ZIP; extract it and pass the inner file."
    }

    $added = New-Object System.Collections.Generic.List[object]
    foreach ($vib in @(Get-EsxSoftwarePackage)) {
        if (-not $before.ContainsKey((Get-SessionVibKey -Package $vib))) { $added.Add($vib) }
    }
    Write-RichoLog "Loaded depot '$Depot': $($added.Count) new VIB(s)." -Level INFO
    return , $added.ToArray()
}

function Write-SwapPlan {
    <#
    .SYNOPSIS
        Logs the swap plan, one line per VIB.

    .PARAMETER Plan
        Rows from Get-VibSwapPlan.

    .EXAMPLE
        Write-SwapPlan -Plan $plan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Plan
    )

    Write-RichoLog ('{0,-8} {1,-34} {2,-40} {3}' -f 'Action', 'VIB', 'Base version', 'Vendor version (source)') -Level INFO
    foreach ($row in $Plan) {
        $vendorText = ''
        if ($row.VendorVersion) { $vendorText = "$($row.VendorVersion) ($(Split-Path -Path $row.Source -Leaf))" }
        elseif ($row.Source -eq '-RemoveVib') { $vendorText = '(removed by -RemoveVib)' }
        $baseText = $row.BaseVersion
        if (-not $baseText) { $baseText = '-' }

        $level = 'INFO'
        if ($row.Action -in @('Older', 'Absent')) { $level = 'WARN' }
        Write-RichoLog ('{0,-8} {1,-34} {2,-40} {3}' -f $row.Action, $row.Name, $baseText, $vendorText) -Level $level

        if ($row.Superseded) {
            Write-RichoLog "         $($row.Name): newest chosen; also offered $($row.Superseded)." -Level INFO
        }
    }
}

function Get-SessionImageProfile {
    <#
    .SYNOPSIS
        The image profile of an exact name loaded in this session. Throws when it is not there.

    .DESCRIPTION
        Used after every Image Builder change so the script always works on the profile as the
        session holds it, rather than relying on what each cmdlet returns.

    .PARAMETER Name
        Image profile name.

    .EXAMPLE
        $newProfile = Get-SessionImageProfile -Name 'ESXi-8.0U3e-24677879-custom-20261125'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $found = @(Get-EsxImageProfile | Where-Object { $_.Name -eq $Name })
    if ($found.Count -eq 0) { throw "Image profile '$Name' is not loaded in this session." }
    return $found[0]
}

function Find-ProfileVib {
    <#
    .SYNOPSIS
        The VIB of a given name in an image profile, or $null.

    .PARAMETER ImageProfile
        The image profile to search.

    .PARAMETER Name
        VIB name.

    .EXAMPLE
        Find-ProfileVib -ImageProfile $new -Name 'nenic'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ImageProfile, [Parameter(Mandatory)][string]$Name)

    $found = @($ImageProfile.VibList | Where-Object { $_.Name -eq $Name })
    if ($found.Count -eq 0) { return $null }
    return $found[0]
}

function Test-ProfileMatchesPlan {
    <#
    .SYNOPSIS
        Checks the finished profile against the plan. Returns the list of discrepancies.

    .DESCRIPTION
        Replace and Add rows must be present at the vendor version. Remove rows must be
        absent. Keep and Older rows must still be at the base version.

    .PARAMETER ImageProfile
        The finished image profile.

    .PARAMETER Plan
        Rows from Get-VibSwapPlan.

    .EXAMPLE
        $problems = Test-ProfileMatchesPlan -ImageProfile $new -Plan $plan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ImageProfile,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Plan
    )

    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($row in $Plan) {
        $vib = Find-ProfileVib -ImageProfile $ImageProfile -Name $row.Name
        switch ($row.Action) {
            { $_ -in @('Replace', 'Add') } {
                if ($null -eq $vib) { $problems.Add("$($row.Name): expected $($row.VendorVersion), not present") }
                elseif ([string]$vib.Version -ne $row.VendorVersion) { $problems.Add("$($row.Name): expected $($row.VendorVersion), found $($vib.Version)") }
            }
            'Remove' {
                if ($null -ne $vib) { $problems.Add("$($row.Name): expected removed, found $($vib.Version)") }
            }
            { $_ -in @('Keep', 'Older') } {
                if ($null -eq $vib) { $problems.Add("$($row.Name): expected $($row.BaseVersion) to be kept, not present") }
                elseif ([string]$vib.Version -ne $row.BaseVersion) { $problems.Add("$($row.Name): expected $($row.BaseVersion) to be kept, found $($vib.Version)") }
            }
        }
    }
    return , $problems.ToArray()
}

function Assert-OutputPath {
    <#
    .SYNOPSIS
        Fails when an export path already exists or its folder does not.

    .PARAMETER Path
        The output file path.

    .EXAMPLE
        Assert-OutputPath -Path 'D:\Depots\custom.zip'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) { throw "Output file already exists: $Path" }
    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw "Output folder does not exist: $folder"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Import-RequiredModules

$transcriptPath = $null
if ($Transcript) { $transcriptPath = Start-RichoTranscript }

$connected = $false

try {
    $config = Get-RichoConfig -Name $Environment
    Write-RichoLog "New-AutoDeployVendorImageProfile $ScriptVersion targeting environment '$($config.Name)'." -Level INFO

    # ---- Pre-flight on outputs, before any slow work ----------------------
    if ($ExportBundlePath) { Assert-OutputPath -Path $ExportBundlePath }
    if ($ExportIsoPath) { Assert-OutputPath -Path $ExportIsoPath }

    # ---- Connect ----------------------------------------------------------
    $cred = Get-RichoCredential -Name $config.vcenter.credentialName
    Connect-VIServer -Server $config.vcenter.server -Credential $cred -ErrorAction Stop | Out-Null
    $connected = $true
    Write-RichoLog "Connected to vCenter $($config.vcenter.server)." -Level INFO

    $usage = Get-AutoDeployProfileUsage

    # ---- Load depots ------------------------------------------------------
    # Depots already in the session would hide which VIBs the vendor depots contribute.
    try {
        $loaded = @(Get-EsxSoftwareDepot -ErrorAction Stop)
    }
    catch {
        throw "Image Builder is not working in this session: $($_.Exception.Message). PowerCLI 13 Image Builder needs Python 3.7 or later, set with Set-PowerCLIConfiguration -PythonPath."
    }
    if ($loaded.Count -gt 0) {
        Write-RichoLog "Unloading $($loaded.Count) depot(s) already in this session." -Level INFO
        $loaded | Remove-EsxSoftwareDepot -ErrorAction Stop
    }

    [void](Add-DepotToSession -Depot $BaseDepot)
    $baseProfiles = @(Get-EsxImageProfile)
    Write-RichoLog "Base depot holds $($baseProfiles.Count) image profile(s)." -Level INFO

    $base = Select-BaseImageProfile -ImageProfile $baseProfiles -Name $BaseImageProfile -Usage $usage
    Write-RichoLog "Base profile: '$($base.Name)' ($(@($base.VibList).Count) VIBs, acceptance level $($base.AcceptanceLevel))." -Level INFO
    if ($usage.ContainsKey([string]$base.Name)) {
        Write-RichoLog "Used by Auto Deploy rule(s): $(($usage[[string]$base.Name]) -join ', ')." -Level INFO
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($depot in $VendorDepot) {
        foreach ($vib in (Add-DepotToSession -Depot $depot)) {
            $candidates.Add([pscustomobject]@{
                    Name    = [string]$vib.Name
                    Version = [string]$vib.Version
                    Vendor  = [string]$vib.Vendor
                    Source  = $depot
                    Package = $vib
                })
        }
    }
    if ($candidates.Count -eq 0) {
        throw 'The vendor depots added no VIBs that are not already in the base depot. Check -VendorDepot.'
    }

    $vendorList = $candidates.ToArray()

    # A vendor custom-image depot carries a full ESXi build. Its VMware VIBs (esx-base and the
    # rest) belong to whatever patch level the vendor built on and must not be mixed into the
    # base profile, so they are dropped unless named in -VendorVibName.
    $vmwareVibs = @($vendorList | Where-Object { $_.Vendor -match '^(?i)(VMW|VMware.*)$' })
    if ($vmwareVibs.Count -gt 0) {
        $named = @($vmwareVibs | Where-Object { $VendorVibName -contains $_.Name })
        $dropped = @($vmwareVibs | Where-Object { $VendorVibName -notcontains $_.Name })
        if ($dropped.Count -gt 0) {
            $droppedNames = ($dropped | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
            Write-RichoLog "Ignoring $($dropped.Count) VMware-signed VIB(s) found in the vendor depots: $droppedNames. Name one in -VendorVibName to apply it." -Level WARN
        }
        $vendorList = @($vendorList | Where-Object { $_.Vendor -notmatch '^(?i)(VMW|VMware.*)$' }) + $named
    }
    if ($vendorList.Count -eq 0) {
        throw 'After VMware-signed VIBs are set aside, the vendor depots offer no VIBs to apply. Check -VendorDepot, or name the VIBs in -VendorVibName.'
    }

    if ($VendorVibName) {
        $missing = @($VendorVibName | Where-Object { $name = $_; -not ($vendorList | Where-Object { $_.Name -eq $name }) })
        if ($missing.Count -gt 0) {
            $offered = ($vendorList | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
            throw "-VendorVibName names VIBs not found in the vendor depots: $($missing -join ', '). Vendor VIBs available: $offered"
        }
        $vendorList = @($vendorList | Where-Object { $VendorVibName -contains $_.Name })
    }

    $newest = Select-NewestVib -Candidate $vendorList
    $plan = Get-VibSwapPlan -BaseVib @($base.VibList) -VendorVib $newest -RemoveVib $RemoveVib -ReplaceOnly:$ReplaceOnly

    Write-RichoLog "Swap plan for '$($base.Name)':" -Level INFO
    Write-SwapPlan -Plan $plan

    $changes = @($plan | Where-Object { $_.Action -in @('Replace', 'Add', 'Remove') })
    if ($changes.Count -eq 0) {
        Write-RichoLog 'The base profile already carries every vendor VIB at the same or a newer version. Nothing to build.' -Level WARN
        return
    }

    if (-not $NewProfileName) { $NewProfileName = Get-DefaultProfileName -BaseName $base.Name }
    if (@(Get-EsxImageProfile | Where-Object { $_.Name -eq $NewProfileName }).Count -gt 0) {
        throw "An image profile named '$NewProfileName' is already loaded. Choose another -NewProfileName."
    }
    if ($usage.ContainsKey($NewProfileName)) {
        throw "Auto Deploy already has an image profile named '$NewProfileName' (rule: $(($usage[$NewProfileName]) -join ', ')). Choose another -NewProfileName."
    }
    if ($StageInAutoDeploy) {
        if (-not $DeployRuleName) { $DeployRuleName = "Staged-$NewProfileName" }
        if (@(Get-DeployRule -ErrorAction Stop | Where-Object { $_.Name -eq $DeployRuleName }).Count -gt 0) {
            throw "A deploy rule named '$DeployRuleName' already exists. Choose another -DeployRuleName."
        }
    }

    if (-not $Description) {
        $sources = ($VendorDepot | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', '
        $Description = "Clone of $($base.Name) with vendor VIBs from: $sources. Built $((Get-Date).ToString('yyyy-MM-dd'))."
    }

    $counts = ($changes | Group-Object -Property Action | ForEach-Object { "$($_.Count) $($_.Name.ToLower())" }) -join ', '
    Write-RichoLog "New profile '$NewProfileName': $counts." -Level INFO

    # ---- Build the profile ------------------------------------------------
    if (-not $PSCmdlet.ShouldProcess($NewProfileName, "Clone image profile '$($base.Name)' and apply $counts")) {
        Write-RichoLog 'Profile not built. No export or Auto Deploy change made.' -Level INFO
        return
    }

    New-EsxImageProfile -CloneProfile $base -Name $NewProfileName -Vendor $ProfileVendor -Description $Description -ErrorAction Stop | Out-Null
    $newProfile = Get-SessionImageProfile -Name $NewProfileName
    Write-RichoLog "Cloned '$($base.Name)' to '$NewProfileName'." -Level INFO

    if ($AcceptanceLevel) {
        Set-EsxImageProfile -ImageProfile $newProfile -AcceptanceLevel $AcceptanceLevel -ErrorAction Stop | Out-Null
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        Write-RichoLog "Acceptance level set to $AcceptanceLevel." -Level INFO
    }

    foreach ($row in @($plan | Where-Object { $_.Action -eq 'Remove' })) {
        $old = Find-ProfileVib -ImageProfile $newProfile -Name $row.Name
        Remove-EsxSoftwarePackage -ImageProfile $newProfile -SoftwarePackage $old -ErrorAction Stop | Out-Null
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        Write-RichoLog "Removed $($row.Name) $($row.BaseVersion)." -Level INFO
    }

    foreach ($row in @($plan | Where-Object { $_.Action -eq 'Replace' })) {
        $old = Find-ProfileVib -ImageProfile $newProfile -Name $row.Name
        $removedFirst = $false
        try {
            Remove-EsxSoftwarePackage -ImageProfile $newProfile -SoftwarePackage $old -ErrorAction Stop | Out-Null
            $removedFirst = $true
        }
        catch {
            # Image Builder refuses to remove a VIB another VIB in the profile depends on. Adding
            # the newer version over it keeps the dependency satisfied; the read-back below
            # confirms the old version is gone either way.
            Write-RichoLog "Could not remove $($row.Name) $($row.BaseVersion) first ($($_.Exception.Message)); adding the vendor version over it." -Level WARN
        }
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        Add-EsxSoftwarePackage -ImageProfile $newProfile -SoftwarePackage $row.Package -ErrorAction Stop | Out-Null
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        $how = 'added over'
        if ($removedFirst) { $how = 'removed, then added' }
        Write-RichoLog "Replaced $($row.Name) $($row.BaseVersion) with $($row.VendorVersion) ($how)." -Level INFO
    }

    foreach ($row in @($plan | Where-Object { $_.Action -eq 'Add' })) {
        Add-EsxSoftwarePackage -ImageProfile $newProfile -SoftwarePackage $row.Package -ErrorAction Stop | Out-Null
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        Write-RichoLog "Added $($row.Name) $($row.VendorVersion)." -Level INFO
    }

    # ---- Verify -----------------------------------------------------------
    $newProfile = Get-SessionImageProfile -Name $NewProfileName
    $problems = Test-ProfileMatchesPlan -ImageProfile $newProfile -Plan $plan
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) { Write-RichoLog "Verify: $problem" -Level WARN }
        throw "The new profile does not match the plan ($($problems.Count) discrepancy/ies). Nothing exported or staged."
    }

    $baseKeys = @{}
    foreach ($vib in @($base.VibList)) { $baseKeys["$($vib.Name)|$($vib.Version)"] = $true }
    $newKeys = @{}
    foreach ($vib in @($newProfile.VibList)) { $newKeys["$($vib.Name)|$($vib.Version)"] = $true }
    $added = @($newKeys.Keys | Where-Object { -not $baseKeys.ContainsKey($_) }).Count
    $dropped = @($baseKeys.Keys | Where-Object { -not $newKeys.ContainsKey($_) }).Count
    Write-RichoLog "Verified '$NewProfileName': $(@($newProfile.VibList).Count) VIBs; $added VIB version(s) not in the base, $dropped base VIB version(s) gone. Matches the plan." -Level INFO

    # ---- Export -----------------------------------------------------------
    if ($ExportBundlePath -and $PSCmdlet.ShouldProcess($ExportBundlePath, "Export '$NewProfileName' as an offline bundle")) {
        Export-EsxImageProfile -ImageProfile $newProfile -ExportToBundle -FilePath $ExportBundlePath -ErrorAction Stop
        Write-RichoLog "Exported offline bundle to $ExportBundlePath." -Level INFO
    }

    if ($ExportIsoPath -and $PSCmdlet.ShouldProcess($ExportIsoPath, "Export '$NewProfileName' as an ISO")) {
        Export-EsxImageProfile -ImageProfile $newProfile -ExportToIso -FilePath $ExportIsoPath -ErrorAction Stop
        Write-RichoLog "Exported ISO to $ExportIsoPath." -Level INFO
    }

    # ---- Stage in Auto Deploy ---------------------------------------------
    if ($StageInAutoDeploy) {
        $patternText = $DeployRulePattern -join ', '
        if ($PSCmdlet.ShouldProcess($config.vcenter.server, "Create inactive deploy rule '$DeployRuleName' holding '$NewProfileName' (pattern: $patternText); uploads the VIBs to Auto Deploy")) {
            Write-RichoLog "Creating deploy rule '$DeployRuleName'. Uploading the image profile can take several minutes." -Level INFO
            New-DeployRule -Name $DeployRuleName -Item $newProfile -Pattern $DeployRulePattern -ErrorAction Stop | Out-Null
            Write-RichoLog "Deploy rule '$DeployRuleName' created with pattern '$patternText'. It is not in the active or working rule set; no host boots from it until the pattern is set and the rule is activated." -Level INFO
        }
    }

    Write-RichoLog 'Completed successfully.' -Level INFO
}
catch {
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    if ($connected) {
        Disconnect-VIServer -Server $config.vcenter.server -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}
