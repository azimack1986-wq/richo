<#
.SYNOPSIS
    Builds a vendor ESXi image from the ESXi bundle ZIP and vendor add-on ZIPs, in a
    window or from the command line.

.DESCRIPTION
    Follows the same steps as building the image in the vSphere Client under Auto Deploy
    > Software Depots.

    Run with no depot parameters and a window opens:

      1. Connect. Pick the environment and connect to vCenter. The Auto Deploy rules are
         read, and only read, to mark which ESXi images are already in use.

      2. Depot ZIPs. Choose the VMware ESXi bundle ZIP and one or more vendor add-on or
         driver ZIPs (Cisco, NetApp and so on), then load them. If a vendor download is
         a ZIP that contains the depot ZIP, use the inner one.

      3. ESXi image. The image profiles inside the ESXi bundle ZIP are listed, with any
         Auto Deploy rule that uses each one. Select the one to clone.

      4. Clone settings. The image name is filled in from the ESXi image and can be
         changed. The acceptance level defaults to VMwareAccepted. "Also remove" takes
         ESXi package names the vendor ships under a different name. The export ZIP
         defaults to output\<image name>.zip in this repository.

      5. Packages. Show packages lists every vendor package against the ESXi package of
         the same name:

           Replace  Vendor version is newer. The ESXi package is removed and the vendor
                    package is added.
           Add      No ESXi package of that name. The vendor package is added, unless
                    "only swap" is ticked.
           Keep     Same version. Nothing changes.
           Older    Vendor version is older. The ESXi package is kept.
           Remove   Named under "Also remove".

         Replace, Add and Remove rows are ticked; untick one to leave the ESXi image as
         it is for that package. Packages below the chosen acceptance level are shown in
         red, and the build refuses them.

         Build image clones the ESXi image, applies the ticked rows, checks every
         package in the result, exports the ZIP, then reloads the ZIP on its own and
         checks it again. A mismatch fails the build and the ZIP must not be imported.

    With -BaseDepot and -VendorDepot the same build runs from the command line: a
    numbered menu replaces the image list, a prompt replaces the name box, and every
    Replace, Add and Remove row is applied. -VendorVibName limits the vendor packages
    used. -WhatIf stops after the package list.

    WHAT IT CHANGES

      Nothing in vCenter. Auto Deploy rules, rule sets and depots are never created,
      changed or activated. The only output is the export ZIP (and an ISO when
      -ExportIsoPath is given). To place the image in the vCenter "Software" depot,
      import the ZIP under Auto Deploy > Software Depots, then clone the image into
      "Software" with no package changes; no documented PowerCLI or API method writes
      into a custom depot.

      The window works on the PowerShell session's Image Builder depots, which are
      unloaded and reloaded on each Load ZIPs. After a build, load the ZIPs again
      before building another image.

    PREREQUISITES

      - Windows PowerShell 5.1 for the window (single-threaded apartment, which is the
        default for powershell.exe). The command line also runs on PowerShell 7.
      - VMware PowerCLI 13.x with VMware.ImageBuilder and VMware.DeployAutomation.
      - Python 3.7 or later configured for PowerCLI (Set-PowerCLIConfiguration
        -PythonPath). Image Builder in PowerCLI 13 does not run without it.

.PARAMETER Environment
    Environment key from config/environments.json. Defaults to the file's "default"
    entry. In the window it is the environment selected when the window opens.

.PARAMETER BaseDepot
    Command line: path to the VMware ESXi bundle ZIP.

.PARAMETER VendorDepot
    Command line: one or more paths to vendor add-on or driver ZIPs.

.PARAMETER BaseImageProfile
    Command line: name of the ESXi image profile to clone, for example
    ESXi-8.0U3e-24677879-standard. When omitted, a numbered menu is shown.

.PARAMETER NewProfileName
    Command line: name for the new image. When omitted, the operator is prompted, with
    the ESXi image name ending "-custom-<yyyyMMdd>" offered as the default.

.PARAMETER AcceptanceLevel
    Acceptance level of the new image. Defaults to VMwareAccepted.

.PARAMETER ProfileVendor
    Vendor field written into the new image. Defaults to "Custom".

.PARAMETER Description
    Command line: description written into the new image. Defaults to a line naming the
    ESXi image and the vendor ZIPs.

.PARAMETER VendorVibName
    Command line: restricts the vendor packages used to these names. Every name given
    must exist in a vendor ZIP.

.PARAMETER RemoveVib
    Command line: ESXi package names to remove from the new image.

.PARAMETER ReplaceOnly
    Command line: only swap packages the ESXi image already has.

.PARAMETER ExportBundlePath
    Command line: ZIP to write. Defaults to output\<image name>.zip in this repository.
    The file must not exist.

.PARAMETER ExportIsoPath
    Command line: ISO to write. The file must not exist.

.PARAMETER Transcript
    Writes a transcript to logs/.

.EXAMPLE
    .\New-AutoDeployVendorImageProfile.ps1

    Opens the window.

.EXAMPLE
    .\New-AutoDeployVendorImageProfile.ps1 -Environment lab -WhatIf

    Opens the window on the lab environment. Build image runs every step up to the
    clone and then stops, so the whole flow can be tested without building anything.

.EXAMPLE
    .\New-AutoDeployVendorImageProfile.ps1 -Environment prod `
        -BaseDepot 'D:\Depots\VMware-ESXi-8.0U3e-24677879-depot.zip' `
        -VendorDepot 'D:\Depots\Cisco-addon-ESXi-8.0U3.zip', 'D:\Depots\NetAppNasPlugin.zip' `
        -BaseImageProfile 'ESXi-8.0U3e-24677879-standard' `
        -NewProfileName 'ESXi-8.0U3e-24677879-Cisco-NetApp'

    Command line: clones at VMwareAccepted, swaps every newer vendor package, and
    exports to output\ESXi-8.0U3e-24677879-Cisco-NetApp.zip.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Gui')]
param(
    [string]$Environment,

    [Parameter(Mandatory, ParameterSetName = 'Cli')]
    [ValidateScript({ (Test-Path -LiteralPath $_ -PathType Leaf) -and ([IO.Path]::GetExtension($_) -eq '.zip') })]
    [string]$BaseDepot,

    [Parameter(Mandatory, ParameterSetName = 'Cli')]
    [AllowEmptyCollection()]
    [ValidateScript({ (Test-Path -LiteralPath $_ -PathType Leaf) -and ([IO.Path]::GetExtension($_) -eq '.zip') })]
    [string[]]$VendorDepot,

    [Parameter(ParameterSetName = 'Cli')]
    [string]$BaseImageProfile,

    [Parameter(ParameterSetName = 'Cli')]
    [string]$NewProfileName,

    [ValidateSet('VMwareCertified', 'VMwareAccepted', 'PartnerSupported', 'CommunitySupported')]
    [string]$AcceptanceLevel = 'VMwareAccepted',

    [ValidateNotNullOrEmpty()]
    [string]$ProfileVendor = 'Custom',

    [Parameter(ParameterSetName = 'Cli')]
    [string]$Description,

    [Parameter(ParameterSetName = 'Cli')]
    [string[]]$VendorVibName,

    [Parameter(ParameterSetName = 'Cli')]
    [string[]]$RemoveVib,

    [Parameter(ParameterSetName = 'Cli')]
    [switch]$ReplaceOnly,

    [Parameter(ParameterSetName = 'Cli')]
    [string]$ExportBundlePath,

    [Parameter(ParameterSetName = 'Cli')]
    [string]$ExportIsoPath,

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.4.0'

# Set while the window is open, so log lines also reach its log box.
$script:LogSink = $null
# The vCenter this run connected to, disconnected at the end.
$script:ConnectedServer = $null

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

function Get-OptionalProperty {
    <#
    .SYNOPSIS
        A property's value as a string, or an empty string when the object lacks it.

    .PARAMETER InputObject
        The object to read.

    .PARAMETER Name
        Property name.

    .EXAMPLE
        Get-OptionalProperty -InputObject $vib -Name 'Acceptance'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $InputObject) { return '' }
    if ($InputObject.PSObject.Properties.Name -notcontains $Name) { return '' }
    return [string]$InputObject.$Name
}

function Get-AcceptanceRank {
    <#
    .SYNOPSIS
        Ranks an acceptance level: 4 certified, 3 accepted, 2 partner, 1 community, 0 unknown.

    .DESCRIPTION
        Accepts both the PowerCLI names (VMwareAccepted, PartnerSupported) and the short
        names used in VIB metadata (accepted, partner).

    .PARAMETER Level
        The acceptance level text.

    .EXAMPLE
        Get-AcceptanceRank -Level 'VMwareAccepted'
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyString()][string]$Level)

    if ($Level -match '(?i)certified') { return 4 }
    if ($Level -match '(?i)accepted') { return 3 }
    if ($Level -match '(?i)partner') { return 2 }
    if ($Level -match '(?i)community') { return 1 }
    return 0
}

function Get-AcceptanceShortfall {
    <#
    .SYNOPSIS
        Lists the packages that would be below the clone's acceptance level.

    .DESCRIPTION
        Checks every package the finished image would carry: the ESXi packages that stay,
        and the vendor packages being added. Image Builder refuses a package below the
        image's acceptance level, so finding them here stops the run before the clone is
        made rather than partway through the swaps. A package whose level cannot be read
        is reported separately rather than assumed to pass.

    .PARAMETER BaseVib
        The ESXi image's packages (Name, Version, AcceptanceLevel).

    .PARAMETER Plan
        Rows from Get-VibSwapPlan.

    .PARAMETER Level
        The clone's acceptance level.

    .EXAMPLE
        $shortfall = Get-AcceptanceShortfall -BaseVib $base.VibList -Plan $plan -Level VMwareAccepted
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$BaseVib,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Plan,

        [Parameter(Mandatory)][string]$Level
    )

    $required = Get-AcceptanceRank -Level $Level
    $leaving = @($Plan | Where-Object { $_.Action -in @('Replace', 'Remove') } | ForEach-Object { $_.Name })

    $kept = @($BaseVib | Where-Object { $leaving -notcontains $_.Name } | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Version = [string]$_.Version; Acceptance = (Get-OptionalProperty -InputObject $_ -Name 'AcceptanceLevel'); From = 'ESXi' }
        })
    $added = @($Plan | Where-Object { $_.Action -in @('Replace', 'Add') } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Version = $_.VendorVersion; Acceptance = [string]$_.Acceptance; From = 'vendor' }
        })

    $below = New-Object System.Collections.Generic.List[string]
    $unknown = New-Object System.Collections.Generic.List[string]
    foreach ($vib in ($kept + $added)) {
        $rank = Get-AcceptanceRank -Level $vib.Acceptance
        if ($rank -eq 0) { $unknown.Add("$($vib.Name) $($vib.Version) ($($vib.From))"); continue }
        if ($rank -lt $required) { $below.Add("$($vib.Name) $($vib.Version) ($($vib.From), $($vib.Acceptance))") }
    }
    return [pscustomobject]@{ Below = $below.ToArray(); Unknown = $unknown.ToArray() }
}

function Read-ProfileName {
    <#
    .SYNOPSIS
        Returns the clone's name: the one given, or one typed at a prompt that offers a default.

    .PARAMETER Name
        The name from -NewProfileName, if any.

    .PARAMETER Default
        The name offered at the prompt, and used when the session is not interactive.

    .EXAMPLE
        $NewProfileName = Read-ProfileName -Name $NewProfileName -Default 'ESXi-8.0U3e-custom'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Name, [Parameter(Mandatory)][string]$Default)

    if (-not [string]::IsNullOrWhiteSpace($Name)) { return $Name.Trim() }
    if (-not [Environment]::UserInteractive) { return $Default }

    $typed = Read-Host "Name for the cloned image profile [$Default]"
    if ([string]::IsNullOrWhiteSpace($typed)) { return $Default }
    return $typed.Trim()
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
                Acceptance = (Get-OptionalProperty -InputObject $best -Name 'Acceptance')
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
                Acceptance    = (Get-OptionalProperty -InputObject $vib -Name 'Acceptance')
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
                Acceptance    = ''
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
        Write-BuildLog "Auto Deploy rules could not be read: $($_.Exception.Message). Profiles will not be marked as in use." -Level WARN
        return $usage
    }

    $activeNames = @()
    try {
        $activeNames = @(Get-DeployRuleSet -ErrorAction Stop | ForEach-Object { [string]$_.Name })
    }
    catch {
        Write-BuildLog "The active rule set could not be read: $($_.Exception.Message)." -Level DEBUG
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
    Write-BuildLog "Read $($rules.Count) Auto Deploy rule(s); $($usage.Count) image profile(s) in use." -Level INFO
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
    Write-BuildLog 'Image profiles in the base depot:' -Level INFO
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $line = '  {0,2}. {1}' -f ($i + 1), $sorted[$i].Name
        if ($Usage.ContainsKey([string]$sorted[$i].Name)) {
            $line += '   [Auto Deploy: ' + (($Usage[[string]$sorted[$i].Name]) -join ', ') + ']'
        }
        Write-BuildLog $line -Level INFO
    }

    while ($true) {
        $answer = Read-Host "Select the profile to clone (1-$($sorted.Count), Q to quit)"
        if ($answer -match '^(?i)q$') { throw 'Stopped by the operator at base profile selection.' }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $sorted.Count) {
            return $sorted[$number - 1]
        }
        Write-BuildLog "'$answer' is not a number between 1 and $($sorted.Count)." -Level WARN
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
        Path to the depot ZIP.

    .EXAMPLE
        $vibs = Add-DepotToSession -Depot 'D:\Depots\Cisco-addon.zip'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Depot)

    if (-not (Test-Path -LiteralPath $Depot -PathType Leaf)) { throw "Depot ZIP not found: $Depot" }
    if ([IO.Path]::GetExtension($Depot) -ne '.zip') { throw "Depot must be a ZIP file: $Depot" }

    $before = @{}
    foreach ($vib in @(Get-EsxSoftwarePackage -ErrorAction SilentlyContinue)) { $before[(Get-SessionVibKey -Package $vib)] = $true }

    $source = (Resolve-Path -LiteralPath $Depot).ProviderPath

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
    Write-BuildLog "Loaded depot '$Depot': $($added.Count) new VIB(s)." -Level INFO
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

    Write-BuildLog ('{0,-8} {1,-34} {2,-40} {3}' -f 'Action', 'VIB', 'Base version', 'Vendor version (source)') -Level INFO
    foreach ($row in $Plan) {
        $vendorText = ''
        if ($row.VendorVersion) { $vendorText = "$($row.VendorVersion) ($(Split-Path -Path $row.Source -Leaf))" }
        elseif ($row.Source -eq '-RemoveVib') { $vendorText = '(removed by -RemoveVib)' }
        $baseText = $row.BaseVersion
        if (-not $baseText) { $baseText = '-' }

        $level = 'INFO'
        if ($row.Action -in @('Older', 'Absent')) { $level = 'WARN' }
        Write-BuildLog ('{0,-8} {1,-34} {2,-40} {3}' -f $row.Action, $row.Name, $baseText, $vendorText) -Level $level

        if ($row.Superseded) {
            Write-BuildLog "         $($row.Name): newest chosen; also offered $($row.Superseded)." -Level INFO
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
        absent. Keep and Older rows must still be at the base version. Excluded (unticked)
        rows must be as the base image had them.

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
            'Excluded' {
                if ($row.BaseVersion) {
                    if ($null -eq $vib) { $problems.Add("$($row.Name): unticked, expected $($row.BaseVersion) to be kept, not present") }
                    elseif ([string]$vib.Version -ne $row.BaseVersion) { $problems.Add("$($row.Name): unticked, expected $($row.BaseVersion) to be kept, found $($vib.Version)") }
                }
                elseif ($null -ne $vib) { $problems.Add("$($row.Name): unticked, expected not added, found $($vib.Version)") }
            }
            { $_ -in @('Keep', 'Older') } {
                if ($null -eq $vib) { $problems.Add("$($row.Name): expected $($row.BaseVersion) to be kept, not present") }
                elseif ([string]$vib.Version -ne $row.BaseVersion) { $problems.Add("$($row.Name): expected $($row.BaseVersion) to be kept, found $($vib.Version)") }
            }
        }
    }
    return , $problems.ToArray()
}

function Compare-VibSet {
    <#
    .SYNOPSIS
        Lists the differences between an expected VIB list and an image profile's VIB list.

    .PARAMETER Expected
        Expected VIBs as "Name|Version" strings.

    .PARAMETER ImageProfile
        The image profile to check.

    .EXAMPLE
        $problems = Compare-VibSet -Expected $expectedVibs -ImageProfile $reloaded
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Expected,

        [Parameter(Mandatory)]$ImageProfile
    )

    $actual = @($ImageProfile.VibList | ForEach-Object { "$($_.Name)|$($_.Version)" })
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($key in ($Expected | Sort-Object -Unique)) {
        if ($actual -notcontains $key) { $problems.Add("missing $($key -replace '\|', ' ')") }
    }
    foreach ($key in ($actual | Sort-Object -Unique)) {
        if ($Expected -notcontains $key) { $problems.Add("unexpected $($key -replace '\|', ' ')") }
    }
    return , $problems.ToArray()
}

function Assert-OutputPath {
    <#
    .SYNOPSIS
        Fails when an export file already exists. The folder is created at export time.

    .PARAMETER Path
        The output file path.

    .EXAMPLE
        Assert-OutputPath -Path 'D:\Depots\custom.zip'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) { throw "Output file already exists: $Path" }
}

function Write-BuildLog {
    <#
    .SYNOPSIS
        Logs through Write-RichoLog and, while the window is open, to its log box as well.

    .PARAMETER Message
        The text to log.

    .PARAMETER Level
        DEBUG, INFO, WARN or ERROR. ERROR is written without stopping the run; the caller
        decides whether to throw.

    .EXAMPLE
        Write-BuildLog "Loaded depot." -Level INFO
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

    if ($Level -eq 'ERROR') { Write-RichoLog $Message -Level ERROR -ErrorAction Continue }
    else { Write-RichoLog $Message -Level $Level }

    if ($null -ne $script:LogSink -and $Level -ne 'DEBUG') {
        try { & $script:LogSink ('{0} [{1,-5}] {2}' -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message) } catch { }
    }
}

function Set-PlanExclusion {
    <#
    .SYNOPSIS
        Marks the named Replace, Add and Remove rows of a plan as Excluded.

    .DESCRIPTION
        An excluded row changes nothing: the ESXi package stays as it is (or, for an Add,
        the vendor package is not added). This is the window's unticked row. Returns copies;
        the plan passed in is not changed.

    .PARAMETER Plan
        Rows from Get-VibSwapPlan.

    .PARAMETER Name
        Package names to exclude.

    .EXAMPLE
        $plan = Set-PlanExclusion -Plan $plan -Name 'nfnic'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Plan,

        [string[]]$Name
    )

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Plan) {
        $copy = $row.PSObject.Copy()
        if ($Name -contains $copy.Name -and $copy.Action -in @('Replace', 'Add', 'Remove')) { $copy.Action = 'Excluded' }
        $result.Add($copy)
    }
    return , $result.ToArray()
}

function Resolve-ExportPath {
    <#
    .SYNOPSIS
        The absolute path of an export file; output\<name>.zip in this repository when no
        path is given.

    .DESCRIPTION
        Image Builder resolves a relative path against the process directory, not the
        PowerShell location, so every export path is made absolute here.

    .PARAMETER Path
        The path given, or an empty string.

    .PARAMETER ProfileName
        The new image name, used for the default file name.

    .EXAMPLE
        Resolve-ExportPath -Path '' -ProfileName 'ESXi-8.0U3e-Cisco'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Path, [Parameter(Mandatory)][string]$ProfileName)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $outputFolder = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\output'))
        $Path = Join-Path $outputFolder "$ProfileName.zip"
    }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-DefaultDescription {
    <#
    .SYNOPSIS
        The description written into the new image when none is given.

    .PARAMETER BaseName
        The ESXi image name.

    .PARAMETER VendorDepot
        The vendor ZIP paths.

    .EXAMPLE
        Get-DefaultDescription -BaseName $base.Name -VendorDepot $VendorDepot
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$BaseName, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$VendorDepot)

    $sources = ($VendorDepot | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', '
    return "Clone of $BaseName with vendor VIBs from: $sources. Built $((Get-Date).ToString('yyyy-MM-dd'))."
}

function Get-RichoEnvironmentList {
    <#
    .SYNOPSIS
        The environment names in config/environments.json, and the default one.

    .DESCRIPTION
        Fills the window's environment list. Returns an empty list when the file cannot be
        read; connecting then reports the problem through Get-RichoConfig.

    .EXAMPLE
        $envs = Get-RichoEnvironmentList
    #>
    [CmdletBinding()]
    param()

    $path = $env:RICHO_CONFIG
    if (-not $path) { $path = Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))) 'config\environments.json' }

    $names = @()
    $default = ''
    try {
        $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        $names = @($json.environments.PSObject.Properties | ForEach-Object { $_.Name })
        if ($json.PSObject.Properties.Name -contains 'default') { $default = [string]$json.default }
    }
    catch {
        Write-BuildLog "Environment list not read from ${path}: $($_.Exception.Message)" -Level WARN
    }
    return [pscustomobject]@{ Names = $names; Default = $default }
}

function Connect-AutoDeployVCenter {
    <#
    .SYNOPSIS
        Connects to an environment's vCenter and reads which image profiles Auto Deploy
        rules use.

    .DESCRIPTION
        A connection already made by this script is closed first. The rules are only read.

    .PARAMETER Environment
        Environment key from config/environments.json; empty for the default.

    .EXAMPLE
        $conn = Connect-AutoDeployVCenter -Environment lab
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Environment)

    if ($script:ConnectedServer) {
        Disconnect-VIServer -Server $script:ConnectedServer -Confirm:$false -ErrorAction SilentlyContinue
        $script:ConnectedServer = $null
    }

    $config = Get-RichoConfig -Name $Environment
    $cred = Get-RichoCredential -Name $config.vcenter.credentialName
    Connect-VIServer -Server $config.vcenter.server -Credential $cred -ErrorAction Stop | Out-Null
    $script:ConnectedServer = $config.vcenter.server
    Write-BuildLog "Connected to vCenter $($config.vcenter.server) (environment '$($config.Name)')." -Level INFO

    $usage = Get-AutoDeployProfileUsage
    return [pscustomobject]@{ Server = $config.vcenter.server; Environment = $config.Name; Usage = $usage }
}

function Import-BuildDepot {
    <#
    .SYNOPSIS
        Loads the ESXi bundle ZIP and the vendor ZIPs, and returns the ESXi images and the
        newest vendor package of each name.

    .DESCRIPTION
        Everything already loaded in the session (depots and image profiles, including a
        clone left by an earlier build) is unloaded first, so the vendor package list is
        exactly what the vendor ZIPs add. VMware-signed packages in a vendor ZIP are set
        aside unless named in -VendorVibName.

    .PARAMETER BaseDepot
        The ESXi bundle ZIP.

    .PARAMETER VendorDepot
        The vendor ZIPs.

    .PARAMETER VendorVibName
        Limits the vendor packages to these names. Every name must exist in a vendor ZIP.

    .EXAMPLE
        $loaded = Import-BuildDepot -BaseDepot $esxZip -VendorDepot $vendorZips
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseDepot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$VendorDepot,
        [string[]]$VendorVibName
    )

    try {
        $loaded = @(Get-EsxSoftwareDepot -ErrorAction Stop)
    }
    catch {
        throw "Image Builder is not working in this session: $($_.Exception.Message). PowerCLI 13 Image Builder needs Python 3.7 or later, set with Set-PowerCLIConfiguration -PythonPath."
    }
    if ($loaded.Count -gt 0) {
        Write-BuildLog "Unloading $($loaded.Count) depot(s) already in this session." -Level INFO
        $loaded | Remove-EsxSoftwareDepot -ErrorAction Stop | Out-Null
    }
    foreach ($leftover in @(Get-EsxImageProfile -ErrorAction SilentlyContinue)) {
        Write-BuildLog "Removing image profile '$($leftover.Name)' left in this session." -Level INFO
        Remove-EsxImageProfile -ImageProfile $leftover -ErrorAction Stop | Out-Null
    }

    [void](Add-DepotToSession -Depot $BaseDepot)
    $profiles = @(Get-EsxImageProfile | Sort-Object -Property Name)
    Write-BuildLog "ESXi bundle holds $($profiles.Count) image profile(s)." -Level INFO
    if ($profiles.Count -eq 0) {
        throw 'The ESXi bundle ZIP contains no image profiles. Choose the VMware ESXi offline bundle, not a vendor add-on or driver ZIP.'
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($depot in $VendorDepot) {
        foreach ($vib in (Add-DepotToSession -Depot $depot)) {
            $candidates.Add([pscustomobject]@{
                    Name       = [string]$vib.Name
                    Version    = [string]$vib.Version
                    Vendor     = [string]$vib.Vendor
                    Acceptance = [string]$vib.AcceptanceLevel
                    Source     = $depot
                    Package    = $vib
                })
        }
    }
    if ($candidates.Count -eq 0) {
        throw 'The vendor ZIPs added no packages that are not already in the ESXi bundle. Check the vendor ZIPs.'
    }

    $vendorList = $candidates.ToArray()

    # A vendor custom-image ZIP carries a full ESXi build. Its VMware packages (esx-base and
    # the rest) belong to whatever patch level the vendor built on and must not be mixed into
    # the ESXi image, so they are set aside unless named in -VendorVibName.
    $vmwareVibs = @($vendorList | Where-Object { $_.Vendor -match '^(?i)(VMW|VMware.*)$' })
    if ($vmwareVibs.Count -gt 0) {
        $named = @($vmwareVibs | Where-Object { $VendorVibName -contains $_.Name })
        $dropped = @($vmwareVibs | Where-Object { $VendorVibName -notcontains $_.Name })
        if ($dropped.Count -gt 0) {
            $droppedNames = ($dropped | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
            Write-BuildLog "Ignoring $($dropped.Count) VMware-signed package(s) found in the vendor ZIPs: $droppedNames." -Level WARN
        }
        $vendorList = @($vendorList | Where-Object { $_.Vendor -notmatch '^(?i)(VMW|VMware.*)$' }) + $named
    }
    if ($vendorList.Count -eq 0) {
        throw 'After VMware-signed packages are set aside, the vendor ZIPs offer nothing to apply.'
    }

    if ($VendorVibName) {
        $missing = @($VendorVibName | Where-Object { $name = $_; -not ($vendorList | Where-Object { $_.Name -eq $name }) })
        if ($missing.Count -gt 0) {
            $offered = ($vendorList | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
            throw "-VendorVibName names packages not found in the vendor ZIPs: $($missing -join ', '). Vendor packages available: $offered"
        }
        $vendorList = @($vendorList | Where-Object { $VendorVibName -contains $_.Name })
    }

    return [pscustomobject]@{ Profiles = $profiles; Vendor = (Select-NewestVib -Candidate $vendorList) }
}

function Invoke-ImageBuild {
    <#
    .SYNOPSIS
        Clones the ESXi image, applies the plan, verifies the result, exports the ZIP and
        checks the exported ZIP.

    .DESCRIPTION
        Checks before anything is built: at least one change, every package at or above the
        acceptance level, the name not already used in this session or by an Auto Deploy
        rule, and the export files not already present.

        After the build every plan row is checked against the new image. After the export
        the session is cleared and the ZIP is loaded on its own; its image must carry
        exactly the verified package list. The ISO, when asked for, is written from that
        checked ZIP.

        Leaves the session holding only the exported ZIP, so the ZIPs must be loaded again
        before another build.

    .PARAMETER BaseProfile
        The ESXi image profile to clone.

    .PARAMETER Plan
        Rows from Get-VibSwapPlan, with any exclusions applied.

    .PARAMETER NewProfileName
        Name of the new image.

    .PARAMETER AcceptanceLevel
        Acceptance level of the new image.

    .PARAMETER ProfileVendor
        Vendor field of the new image.

    .PARAMETER Description
        Description of the new image.

    .PARAMETER ExportBundlePath
        Absolute path of the ZIP to write.

    .PARAMETER ExportIsoPath
        Absolute path of the ISO to write, or empty.

    .PARAMETER Usage
        Map of image profile name to the Auto Deploy rules that use it.

    .EXAMPLE
        $result = Invoke-ImageBuild -BaseProfile $base -Plan $plan -NewProfileName $name `
            -AcceptanceLevel VMwareAccepted -ProfileVendor Custom -Description $text `
            -ExportBundlePath $zip -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]$BaseProfile,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Plan,

        [Parameter(Mandatory)][string]$NewProfileName,
        [Parameter(Mandatory)][string]$AcceptanceLevel,
        [Parameter(Mandatory)][string]$ProfileVendor,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$ExportBundlePath,
        [string]$ExportIsoPath,
        [hashtable]$Usage = @{}
    )

    $result = [pscustomobject]@{ Built = $false; Exported = $false; ExportBundlePath = $ExportBundlePath; VibCount = 0 }

    $changes = @($Plan | Where-Object { $_.Action -in @('Replace', 'Add', 'Remove') })
    if ($changes.Count -eq 0) { throw 'No package changes are selected. Nothing to build.' }

    $shortfall = Get-AcceptanceShortfall -BaseVib @($BaseProfile.VibList) -Plan $Plan -Level $AcceptanceLevel
    if ($shortfall.Unknown.Count -gt 0) {
        Write-BuildLog "Acceptance level could not be read for: $($shortfall.Unknown -join ', '). Image Builder checks these when they are added." -Level WARN
    }
    if ($shortfall.Below.Count -gt 0) {
        foreach ($line in $shortfall.Below) { Write-BuildLog "Below $AcceptanceLevel`: $line" -Level WARN }
        throw "$($shortfall.Below.Count) package(s) are below $AcceptanceLevel and would be refused: $($shortfall.Below -join '; '). Untick them, or choose a lower acceptance level."
    }

    if (@(Get-EsxImageProfile | Where-Object { $_.Name -eq $NewProfileName }).Count -gt 0) {
        throw "An image profile named '$NewProfileName' is already loaded. Choose another name."
    }
    if ($Usage.ContainsKey($NewProfileName)) {
        throw "Auto Deploy already has an image profile named '$NewProfileName' (rule: $(($Usage[$NewProfileName]) -join ', ')). Choose another name."
    }
    Assert-OutputPath -Path $ExportBundlePath
    if ($ExportIsoPath) { Assert-OutputPath -Path $ExportIsoPath }

    $counts = ($changes | Group-Object -Property Action | ForEach-Object { "$($_.Count) $($_.Name.ToLower())" }) -join ', '
    Write-BuildLog "New image '$NewProfileName' from '$($BaseProfile.Name)' at $AcceptanceLevel`: $counts." -Level INFO

    # ---- Build ---------------------------------------------------------------
    if (-not $PSCmdlet.ShouldProcess($NewProfileName, "Clone image profile '$($BaseProfile.Name)' and apply $counts")) {
        Write-BuildLog 'Image not built. Nothing exported.' -Level INFO
        return $result
    }

    New-EsxImageProfile -CloneProfile $BaseProfile -Name $NewProfileName -Vendor $ProfileVendor -Description $Description -ErrorAction Stop | Out-Null
    $newProfile = Get-SessionImageProfile -Name $NewProfileName
    Write-BuildLog "Cloned '$($BaseProfile.Name)' to '$NewProfileName'." -Level INFO

    if ([string]$newProfile.AcceptanceLevel -ne $AcceptanceLevel) {
        Set-EsxImageProfile -ImageProfile $newProfile -AcceptanceLevel $AcceptanceLevel -ErrorAction Stop | Out-Null
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        Write-BuildLog "Acceptance level set to $AcceptanceLevel." -Level INFO
    }

    foreach ($row in @($Plan | Where-Object { $_.Action -eq 'Remove' })) {
        $old = Find-ProfileVib -ImageProfile $newProfile -Name $row.Name
        Remove-EsxSoftwarePackage -ImageProfile $newProfile -SoftwarePackage $old -ErrorAction Stop | Out-Null
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        Write-BuildLog "Removed $($row.Name) $($row.BaseVersion)." -Level INFO
    }

    foreach ($row in @($Plan | Where-Object { $_.Action -eq 'Replace' })) {
        $old = Find-ProfileVib -ImageProfile $newProfile -Name $row.Name
        $removedFirst = $false
        try {
            Remove-EsxSoftwarePackage -ImageProfile $newProfile -SoftwarePackage $old -ErrorAction Stop | Out-Null
            $removedFirst = $true
        }
        catch {
            # Image Builder refuses to remove a package another package depends on. Adding the
            # newer version over it keeps the dependency satisfied; the check below confirms
            # the old version is gone either way.
            Write-BuildLog "Could not remove $($row.Name) $($row.BaseVersion) first ($($_.Exception.Message)); adding the vendor version over it." -Level WARN
        }
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        Add-EsxSoftwarePackage -ImageProfile $newProfile -SoftwarePackage $row.Package -ErrorAction Stop | Out-Null
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        $how = 'added over'
        if ($removedFirst) { $how = 'removed, then added' }
        Write-BuildLog "Replaced $($row.Name) $($row.BaseVersion) with $($row.VendorVersion) ($how)." -Level INFO
    }

    foreach ($row in @($Plan | Where-Object { $_.Action -eq 'Add' })) {
        Add-EsxSoftwarePackage -ImageProfile $newProfile -SoftwarePackage $row.Package -ErrorAction Stop | Out-Null
        $newProfile = Get-SessionImageProfile -Name $NewProfileName
        Write-BuildLog "Added $($row.Name) $($row.VendorVersion)." -Level INFO
    }

    # ---- Verify --------------------------------------------------------------
    $newProfile = Get-SessionImageProfile -Name $NewProfileName
    $problems = Test-ProfileMatchesPlan -ImageProfile $newProfile -Plan $Plan
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) { Write-BuildLog "Verify: $problem" -Level WARN }
        throw "The new image does not match the package list ($($problems.Count) difference(s)). Nothing exported."
    }
    $result.Built = $true
    Write-BuildLog "Verified '$NewProfileName': $(@($newProfile.VibList).Count) packages, every change as listed." -Level INFO

    # ---- Export, then reload the ZIP and check it -------------------------------
    # The ZIP is what goes into vCenter (imported on the Software Depots page), so it is
    # checked on its own rather than trusted to match the session copy.
    if (-not $PSCmdlet.ShouldProcess($ExportBundlePath, "Export '$NewProfileName' as an offline bundle ZIP")) {
        Write-BuildLog 'ZIP not exported.' -Level INFO
        return $result
    }

    $expectedVibs = @($newProfile.VibList | ForEach-Object { "$($_.Name)|$($_.Version)" })

    $folder = Split-Path -Path $ExportBundlePath -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
    Export-EsxImageProfile -ImageProfile $newProfile -ExportToBundle -FilePath $ExportBundlePath -ErrorAction Stop | Out-Null
    Write-BuildLog "Exported ZIP to $ExportBundlePath." -Level INFO

    # The session copy must be gone before the reload, or the check could read it instead of
    # the image that came out of the ZIP.
    Get-EsxSoftwareDepot | Remove-EsxSoftwareDepot -ErrorAction Stop | Out-Null
    foreach ($leftover in @(Get-EsxImageProfile -ErrorAction SilentlyContinue)) {
        Remove-EsxImageProfile -ImageProfile $leftover -ErrorAction Stop | Out-Null
    }
    [void](Add-DepotToSession -Depot $ExportBundlePath)
    $reloaded = @(Get-EsxImageProfile | Where-Object { $_.Name -eq $NewProfileName })
    if ($reloaded.Count -ne 1) {
        throw "Expected one image profile named '$NewProfileName' in $ExportBundlePath, found $($reloaded.Count). Do not import the ZIP."
    }
    $newProfile = $reloaded[0]

    $zipProblems = @(Compare-VibSet -Expected $expectedVibs -ImageProfile $newProfile) + @(Test-ProfileMatchesPlan -ImageProfile $newProfile -Plan $Plan)
    if ($zipProblems.Count -gt 0) {
        foreach ($problem in ($zipProblems | Sort-Object -Unique)) { Write-BuildLog "ZIP check: $problem" -Level WARN }
        throw "The exported ZIP does not match the verified image. Do not import $ExportBundlePath."
    }
    $result.Exported = $true
    $result.VibCount = $expectedVibs.Count
    Write-BuildLog "Reloaded $($ExportBundlePath): '$NewProfileName' has the same $($expectedVibs.Count) packages as the verified image." -Level INFO

    if ($ExportIsoPath -and $PSCmdlet.ShouldProcess($ExportIsoPath, "Export '$NewProfileName' as an ISO")) {
        $folder = Split-Path -Path $ExportIsoPath -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
        Export-EsxImageProfile -ImageProfile $newProfile -ExportToIso -FilePath $ExportIsoPath -ErrorAction Stop | Out-Null
        Write-BuildLog "Exported ISO to $ExportIsoPath." -Level INFO
    }

    Write-BuildLog "To place the image in the vCenter 'Software' depot: import $ExportBundlePath under Auto Deploy > Software Depots, then clone '$NewProfileName' into 'Software' with no package changes." -Level INFO
    return $result
}

function Invoke-GuiAction {
    <#
    .SYNOPSIS
        Runs one window action with the window disabled, and shows any failure in a message box.

    .PARAMETER GuiForm
        The window.

    .PARAMETER Body
        The action.

    .EXAMPLE
        Invoke-GuiAction -GuiForm $form -Body { ... }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$GuiForm, [Parameter(Mandatory)][scriptblock]$Body)

    $GuiForm.UseWaitCursor = $true
    $GuiForm.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    try {
        & $Body
    }
    catch {
        $message = $_.Exception.Message
        Write-BuildLog $message -Level ERROR
        [void][System.Windows.Forms.MessageBox]::Show($message, 'Auto Deploy image builder', 'OK', 'Error')
    }
    finally {
        $GuiForm.Enabled = $true
        $GuiForm.UseWaitCursor = $false
    }
}

function Show-BuilderForm {
    <#
    .SYNOPSIS
        Opens the image builder window and returns when it is closed.

    .PARAMETER Environment
        Environment selected when the window opens.

    .PARAMETER AcceptanceLevel
        Acceptance level selected when the window opens.

    .PARAMETER ProfileVendor
        Vendor field written into images built from the window.

    .EXAMPLE
        Show-BuilderForm -Environment lab
    #>
    [CmdletBinding()]
    param(
        [string]$Environment,
        [string]$AcceptanceLevel = 'VMwareAccepted',
        [string]$ProfileVendor = 'Custom'
    )

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
        throw 'The window needs a single-threaded apartment. Start it from Windows PowerShell (powershell.exe -STA -File <this script>).'
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $state = @{
        Usage      = @{}
        Profiles   = @()
        Vendor     = @()
        VendorZips = @()
        Base       = $null
        Plan       = @()
        ExportAuto = $true
        Updating   = $false
    }

    $top = [System.Windows.Forms.AnchorStyles]::Top
    $left = [System.Windows.Forms.AnchorStyles]::Left
    $right = [System.Windows.Forms.AnchorStyles]::Right
    $bottom = [System.Windows.Forms.AnchorStyles]::Bottom
    $stretch = $top -bor $left -bor $right
    $pinRight = $top -bor $right

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Auto Deploy vendor image builder $ScriptVersion"
    $form.ClientSize = New-Object System.Drawing.Size(1105, 860)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 700)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # ---- 1. Connect ------------------------------------------------------------
    $grpConnect = New-Object System.Windows.Forms.GroupBox -Property @{ Text = '1. Connect to vCenter Auto Deploy'; Location = [System.Drawing.Point]::new(10, 10); Size = [System.Drawing.Size]::new(1085, 55); Anchor = $stretch }
    $lblEnv = New-Object System.Windows.Forms.Label -Property @{ Text = 'Environment:'; Location = [System.Drawing.Point]::new(12, 25); Size = [System.Drawing.Size]::new(85, 20) }
    $cmbEnv = New-Object System.Windows.Forms.ComboBox -Property @{ Location = [System.Drawing.Point]::new(100, 21); Size = [System.Drawing.Size]::new(160, 24); DropDownStyle = 'DropDown' }
    $btnConnect = New-Object System.Windows.Forms.Button -Property @{ Text = 'Connect'; Location = [System.Drawing.Point]::new(270, 20); Size = [System.Drawing.Size]::new(100, 26) }
    $lblConn = New-Object System.Windows.Forms.Label -Property @{ Text = 'Not connected.'; Location = [System.Drawing.Point]::new(380, 25); Size = [System.Drawing.Size]::new(690, 20); Anchor = $stretch }
    $grpConnect.Controls.AddRange(@($lblEnv, $cmbEnv, $btnConnect, $lblConn))

    $envList = Get-RichoEnvironmentList
    foreach ($name in $envList.Names) { [void]$cmbEnv.Items.Add($name) }
    if ($Environment) { $cmbEnv.Text = $Environment } elseif ($envList.Default) { $cmbEnv.Text = $envList.Default }

    # ---- 2. Depot ZIPs ---------------------------------------------------------
    $grpZip = New-Object System.Windows.Forms.GroupBox -Property @{ Text = '2. Depot ZIPs'; Location = [System.Drawing.Point]::new(10, 70); Size = [System.Drawing.Size]::new(1085, 135); Anchor = $stretch }
    $lblBase = New-Object System.Windows.Forms.Label -Property @{ Text = 'ESXi bundle ZIP:'; Location = [System.Drawing.Point]::new(12, 26); Size = [System.Drawing.Size]::new(110, 20) }
    $txtBase = New-Object System.Windows.Forms.TextBox -Property @{ Location = [System.Drawing.Point]::new(125, 22); Size = [System.Drawing.Size]::new(840, 24); ReadOnly = $true; Anchor = $stretch }
    $btnBase = New-Object System.Windows.Forms.Button -Property @{ Text = 'Browse...'; Location = [System.Drawing.Point]::new(975, 21); Size = [System.Drawing.Size]::new(95, 26); Anchor = $pinRight }
    $lblVendor = New-Object System.Windows.Forms.Label -Property @{ Text = 'Vendor ZIPs:'; Location = [System.Drawing.Point]::new(12, 56); Size = [System.Drawing.Size]::new(110, 20) }
    $lstVendor = New-Object System.Windows.Forms.ListBox -Property @{ Location = [System.Drawing.Point]::new(125, 52); Size = [System.Drawing.Size]::new(840, 72); SelectionMode = 'MultiExtended'; HorizontalScrollbar = $true; Anchor = $stretch }
    $btnVendorAdd = New-Object System.Windows.Forms.Button -Property @{ Text = 'Add...'; Location = [System.Drawing.Point]::new(975, 51); Size = [System.Drawing.Size]::new(95, 26); Anchor = $pinRight }
    $btnVendorRemove = New-Object System.Windows.Forms.Button -Property @{ Text = 'Remove'; Location = [System.Drawing.Point]::new(975, 79); Size = [System.Drawing.Size]::new(95, 26); Anchor = $pinRight }
    $btnLoad = New-Object System.Windows.Forms.Button -Property @{ Text = 'Load ZIPs'; Location = [System.Drawing.Point]::new(975, 105); Size = [System.Drawing.Size]::new(95, 26); Anchor = $pinRight }
    $grpZip.Controls.AddRange(@($lblBase, $txtBase, $btnBase, $lblVendor, $lstVendor, $btnVendorAdd, $btnVendorRemove, $btnLoad))

    # ---- 3. ESXi image ---------------------------------------------------------
    $grpImage = New-Object System.Windows.Forms.GroupBox -Property @{ Text = '3. ESXi image to clone (from the ESXi bundle ZIP)'; Location = [System.Drawing.Point]::new(10, 210); Size = [System.Drawing.Size]::new(1085, 180); Anchor = $stretch }
    $gridImage = New-Object System.Windows.Forms.DataGridView -Property @{
        Location = [System.Drawing.Point]::new(12, 22); Size = [System.Drawing.Size]::new(1060, 148); Anchor = $stretch; ReadOnly = $true
        AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; RowHeadersVisible = $false
        SelectionMode = 'FullRowSelect'; MultiSelect = $false; AutoSizeColumnsMode = 'Fill'
    }
    [void]$gridImage.Columns.Add('Name', 'Image profile')
    [void]$gridImage.Columns.Add('Vendor', 'Vendor')
    [void]$gridImage.Columns.Add('Acceptance', 'Acceptance level')
    [void]$gridImage.Columns.Add('Vibs', 'Packages')
    [void]$gridImage.Columns.Add('Rules', 'Used by Auto Deploy rule')
    $gridImage.Columns['Name'].FillWeight = 35
    $gridImage.Columns['Vendor'].FillWeight = 15
    $gridImage.Columns['Acceptance'].FillWeight = 15
    $gridImage.Columns['Vibs'].FillWeight = 8
    $gridImage.Columns['Rules'].FillWeight = 27
    $grpImage.Controls.Add($gridImage)

    # ---- 4. Clone settings -----------------------------------------------------
    $grpClone = New-Object System.Windows.Forms.GroupBox -Property @{ Text = '4. Clone settings'; Location = [System.Drawing.Point]::new(10, 395); Size = [System.Drawing.Size]::new(1085, 90); Anchor = $stretch }
    $lblName = New-Object System.Windows.Forms.Label -Property @{ Text = 'Image name:'; Location = [System.Drawing.Point]::new(12, 27); Size = [System.Drawing.Size]::new(80, 20) }
    $txtName = New-Object System.Windows.Forms.TextBox -Property @{ Location = [System.Drawing.Point]::new(95, 23); Size = [System.Drawing.Size]::new(420, 24) }
    $lblAcc = New-Object System.Windows.Forms.Label -Property @{ Text = 'Acceptance level:'; Location = [System.Drawing.Point]::new(530, 27); Size = [System.Drawing.Size]::new(105, 20) }
    $cmbAcc = New-Object System.Windows.Forms.ComboBox -Property @{ Location = [System.Drawing.Point]::new(640, 23); Size = [System.Drawing.Size]::new(150, 24); DropDownStyle = 'DropDownList' }
    foreach ($level in @('VMwareCertified', 'VMwareAccepted', 'PartnerSupported', 'CommunitySupported')) { [void]$cmbAcc.Items.Add($level) }
    $cmbAcc.SelectedItem = $AcceptanceLevel
    $chkReplaceOnly = New-Object System.Windows.Forms.CheckBox -Property @{ Text = 'Only swap packages the ESXi image already has'; Location = [System.Drawing.Point]::new(810, 24); Size = [System.Drawing.Size]::new(265, 22) }
    $lblRemove = New-Object System.Windows.Forms.Label -Property @{ Text = 'Also remove:'; Location = [System.Drawing.Point]::new(12, 59); Size = [System.Drawing.Size]::new(80, 20) }
    $txtRemove = New-Object System.Windows.Forms.TextBox -Property @{ Location = [System.Drawing.Point]::new(95, 55); Size = [System.Drawing.Size]::new(300, 24) }
    $lblExport = New-Object System.Windows.Forms.Label -Property @{ Text = 'Export ZIP:'; Location = [System.Drawing.Point]::new(410, 59); Size = [System.Drawing.Size]::new(70, 20) }
    $txtExport = New-Object System.Windows.Forms.TextBox -Property @{ Location = [System.Drawing.Point]::new(485, 55); Size = [System.Drawing.Size]::new(380, 24); Anchor = $stretch }
    $btnExport = New-Object System.Windows.Forms.Button -Property @{ Text = 'Browse...'; Location = [System.Drawing.Point]::new(870, 54); Size = [System.Drawing.Size]::new(80, 26); Anchor = $pinRight }
    $btnPlan = New-Object System.Windows.Forms.Button -Property @{ Text = 'Show packages'; Location = [System.Drawing.Point]::new(960, 54); Size = [System.Drawing.Size]::new(110, 26); Anchor = $pinRight }
    $grpClone.Controls.AddRange(@($lblName, $txtName, $lblAcc, $cmbAcc, $chkReplaceOnly, $lblRemove, $txtRemove, $lblExport, $txtExport, $btnExport, $btnPlan))

    # ---- 5. Packages -----------------------------------------------------------
    $grpPlan = New-Object System.Windows.Forms.GroupBox -Property @{ Text = '5. Packages - untick a row to leave the ESXi image as it is for that package'; Location = [System.Drawing.Point]::new(10, 490); Size = [System.Drawing.Size]::new(1085, 230); Anchor = $stretch }
    $gridPlan = New-Object System.Windows.Forms.DataGridView -Property @{
        Location = [System.Drawing.Point]::new(12, 22); Size = [System.Drawing.Size]::new(1060, 165); Anchor = $stretch
        AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; RowHeadersVisible = $false
        SelectionMode = 'FullRowSelect'; MultiSelect = $false; AutoSizeColumnsMode = 'Fill'
    }
    $applyColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn -Property @{ Name = 'Apply'; HeaderText = 'Apply'; FillWeight = 6 }
    [void]$gridPlan.Columns.Add($applyColumn)
    foreach ($column in @(
            @('Action', 'Action', 9), @('Vib', 'Package', 18), @('BaseVersion', 'ESXi version', 20),
            @('VendorVersion', 'Vendor version', 20), @('Acceptance', 'Vendor acceptance', 12), @('Source', 'From ZIP', 15))) {
        $index = $gridPlan.Columns.Add($column[0], $column[1])
        $gridPlan.Columns[$index].FillWeight = $column[2]
        $gridPlan.Columns[$index].ReadOnly = $true
    }
    $lblPlan = New-Object System.Windows.Forms.Label -Property @{ Text = 'Load the ZIPs, select an ESXi image, then click Show packages.'; Location = [System.Drawing.Point]::new(12, 198); Size = [System.Drawing.Size]::new(820, 20); Anchor = $stretch }
    $btnBuild = New-Object System.Windows.Forms.Button -Property @{ Text = 'Build image'; Location = [System.Drawing.Point]::new(950, 193); Size = [System.Drawing.Size]::new(120, 28); Anchor = $pinRight; Enabled = $false }
    $grpPlan.Controls.AddRange(@($gridPlan, $lblPlan, $btnBuild))

    # ---- Log -------------------------------------------------------------------
    $txtLog = New-Object System.Windows.Forms.TextBox -Property @{
        Location = [System.Drawing.Point]::new(10, 725); Size = [System.Drawing.Size]::new(1085, 125); Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'
        Anchor = ($top -bor $bottom -bor $left -bor $right); Font = (New-Object System.Drawing.Font('Consolas', 8.5))
    }

    $form.Controls.AddRange(@($grpConnect, $grpZip, $grpImage, $grpClone, $grpPlan, $txtLog))

    $script:LogSink = {
        param($Line)
        $txtLog.AppendText($Line + [Environment]::NewLine)
        [System.Windows.Forms.Application]::DoEvents()
    }.GetNewClosure()

    # ---- Shared steps ----------------------------------------------------------
    $clearPlan = {
        $gridPlan.Rows.Clear()
        $state.Plan = @()
        $btnBuild.Enabled = $false
        $lblPlan.Text = 'Select an ESXi image, then click Show packages.'
    }

    $clearImages = {
        $gridImage.Rows.Clear()
        $state.Profiles = @()
        $state.Vendor = @()
        $state.Base = $null
        & $clearPlan
    }

    $fillImages = {
        $gridImage.Rows.Clear()
        foreach ($imageProfile in $state.Profiles) {
            $rules = ''
            if ($state.Usage.ContainsKey([string]$imageProfile.Name)) { $rules = ($state.Usage[[string]$imageProfile.Name]) -join ', ' }
            $index = $gridImage.Rows.Add([string]$imageProfile.Name, [string]$imageProfile.Vendor, [string]$imageProfile.AcceptanceLevel, @($imageProfile.VibList).Count, $rules)
            $gridImage.Rows[$index].Tag = $imageProfile
        }
        $gridImage.ClearSelection()
        $state.Base = $null
        & $clearPlan
    }

    # ---- Events ----------------------------------------------------------------
    $btnConnect.Add_Click({
            Invoke-GuiAction -GuiForm $form -Body {
                $conn = Connect-AutoDeployVCenter -Environment $cmbEnv.Text.Trim()
                $state.Usage = $conn.Usage
                $lblConn.Text = "Connected to $($conn.Server) ($($conn.Environment)). $($conn.Usage.Count) image profile(s) in use by Auto Deploy rules."
                if ($state.Profiles.Count -gt 0) { & $fillImages }
            }
        })

    $btnBase.Add_Click({
            $dialog = New-Object System.Windows.Forms.OpenFileDialog -Property @{ Filter = 'ZIP files (*.zip)|*.zip'; Title = 'VMware ESXi bundle ZIP' }
            if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $txtBase.Text = $dialog.FileName
                & $clearImages
            }
        })

    $btnVendorAdd.Add_Click({
            $dialog = New-Object System.Windows.Forms.OpenFileDialog -Property @{ Filter = 'ZIP files (*.zip)|*.zip'; Title = 'Vendor add-on or driver ZIPs'; Multiselect = $true }
            if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                foreach ($file in $dialog.FileNames) {
                    if (-not $lstVendor.Items.Contains($file)) { [void]$lstVendor.Items.Add($file) }
                }
                & $clearImages
            }
        })

    $btnVendorRemove.Add_Click({
            foreach ($item in @($lstVendor.SelectedItems | ForEach-Object { $_ })) { $lstVendor.Items.Remove($item) }
            & $clearImages
        })

    $btnLoad.Add_Click({
            Invoke-GuiAction -GuiForm $form -Body {
                if ([string]::IsNullOrWhiteSpace($txtBase.Text)) { throw 'Choose the ESXi bundle ZIP.' }
                if ($lstVendor.Items.Count -eq 0) { throw 'Add at least one vendor ZIP.' }
                if (-not $script:ConnectedServer) { Write-BuildLog 'Not connected: the ESXi images will not show which Auto Deploy rules use them.' -Level WARN }

                & $clearImages
                $zips = @($lstVendor.Items | ForEach-Object { [string]$_ })
                $loaded = Import-BuildDepot -BaseDepot $txtBase.Text -VendorDepot $zips
                $state.Profiles = @($loaded.Profiles)
                $state.Vendor = @($loaded.Vendor)
                $state.VendorZips = $zips
                & $fillImages
                $lblPlan.Text = "Loaded $($state.Profiles.Count) ESXi image(s) and $($state.Vendor.Count) vendor package(s). Select an ESXi image."
            }
        })

    $gridImage.Add_SelectionChanged({
            if ($gridImage.SelectedRows.Count -eq 0) { return }
            $selected = $gridImage.SelectedRows[0].Tag
            if ($null -eq $selected) { return }
            $state.Base = $selected
            $state.ExportAuto = $true
            $txtName.Text = Get-DefaultProfileName -BaseName ([string]$selected.Name)
            & $clearPlan
        })

    $txtName.Add_TextChanged({
            if (-not $state.ExportAuto) { return }
            $name = $txtName.Text.Trim()
            if (-not $name) { return }
            try {
                $state.Updating = $true
                $txtExport.Text = Resolve-ExportPath -Path '' -ProfileName $name
            }
            catch { }
            finally { $state.Updating = $false }
        })

    $txtExport.Add_TextChanged({ if (-not $state.Updating) { $state.ExportAuto = $false } })

    $btnExport.Add_Click({
            $dialog = New-Object System.Windows.Forms.SaveFileDialog -Property @{ Filter = 'ZIP files (*.zip)|*.zip'; Title = 'Export ZIP'; FileName = "$($txtName.Text.Trim()).zip"; OverwritePrompt = $false }
            if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $txtExport.Text = $dialog.FileName }
        })

    $cmbAcc.Add_SelectedIndexChanged({ & $clearPlan })
    $chkReplaceOnly.Add_CheckedChanged({ & $clearPlan })
    $txtRemove.Add_TextChanged({ & $clearPlan })

    $gridPlan.Add_CurrentCellDirtyStateChanged({
            if ($gridPlan.IsCurrentCellDirty) { [void]$gridPlan.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
        })

    $btnPlan.Add_Click({
            Invoke-GuiAction -GuiForm $form -Body {
                if ($null -eq $state.Base) { throw 'Select the ESXi image to clone.' }
                & $clearPlan
                $removeNames = @($txtRemove.Text -split '[,;\s]+' | Where-Object { $_ })
                $plan = Get-VibSwapPlan -BaseVib @($state.Base.VibList) -VendorVib $state.Vendor -RemoveVib $removeNames -ReplaceOnly:$chkReplaceOnly.Checked
                $state.Plan = $plan
                Write-BuildLog "Packages for '$($state.Base.Name)':" -Level INFO
                Write-SwapPlan -Plan $plan

                $required = Get-AcceptanceRank -Level ([string]$cmbAcc.SelectedItem)
                $belowCount = 0
                foreach ($row in $plan) {
                    $applicable = $row.Action -in @('Replace', 'Add', 'Remove')
                    $source = 'Also remove'
                    if ($row.Source -ne '-RemoveVib') { $source = Split-Path -Path $row.Source -Leaf }
                    $index = $gridPlan.Rows.Add($applicable, $row.Action, $row.Name, $row.BaseVersion, $row.VendorVersion, $row.Acceptance, $source)
                    $gridRow = $gridPlan.Rows[$index]
                    $gridRow.Tag = $row.Name
                    $gridRow.Cells['Apply'].ReadOnly = (-not $applicable)

                    switch ($row.Action) {
                        'Replace' { $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(226, 239, 218) }
                        'Add' { $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(221, 235, 247) }
                        'Remove' { $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(252, 228, 214) }
                        'Older' { $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 242, 204) }
                        default { $gridRow.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray }
                    }

                    $rank = Get-AcceptanceRank -Level ([string]$row.Acceptance)
                    if ($row.Action -in @('Replace', 'Add') -and $rank -gt 0 -and $rank -lt $required) {
                        $gridRow.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick
                        $gridRow.Cells['Acceptance'].ToolTipText = "Below $($cmbAcc.SelectedItem)"
                        $belowCount++
                    }
                }
                $gridPlan.ClearSelection()

                $summary = ($plan | Group-Object -Property Action | Sort-Object -Property Name | ForEach-Object { "$($_.Count) $($_.Name.ToLower())" }) -join ', '
                if ($belowCount -gt 0) { $summary += " - $belowCount below $($cmbAcc.SelectedItem) (red): untick them or lower the acceptance level" }
                $lblPlan.Text = $summary
                $btnBuild.Enabled = (@($plan | Where-Object { $_.Action -in @('Replace', 'Add', 'Remove') }).Count -gt 0)
            }
        })

    $btnBuild.Add_Click({
            Invoke-GuiAction -GuiForm $form -Body {
                [void]$gridPlan.EndEdit()
                $excluded = @(foreach ($gridRow in $gridPlan.Rows) {
                        if (-not $gridRow.Cells['Apply'].ReadOnly -and -not [bool]$gridRow.Cells['Apply'].Value) { [string]$gridRow.Tag }
                    })
                $plan = Set-PlanExclusion -Plan $state.Plan -Name $excluded

                $name = $txtName.Text.Trim()
                if (-not $name) { throw 'Enter a name for the new image.' }
                $zipPath = Resolve-ExportPath -Path $txtExport.Text.Trim() -ProfileName $name
                $level = [string]$cmbAcc.SelectedItem

                $changes = @($plan | Where-Object { $_.Action -in @('Replace', 'Add', 'Remove') })
                if ($changes.Count -eq 0) { throw 'No package rows are ticked. Nothing to build.' }
                $counts = ($changes | Group-Object -Property Action | ForEach-Object { "$($_.Count) to $($_.Name.ToLower())" }) -join ', '
                if ($excluded.Count -gt 0) { Write-BuildLog "Unticked, ESXi image left as it is: $($excluded -join ', ')." -Level INFO }

                $question = "Build image '$name' from '$($state.Base.Name)'?`r`n`r`n$counts`r`nAcceptance level: $level`r`nExport ZIP: $zipPath`r`n`r`nNothing in vCenter or Auto Deploy is changed."
                $answer = [System.Windows.Forms.MessageBox]::Show($question, 'Build image', 'YesNo', 'Question')
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                    Write-BuildLog 'Build cancelled.' -Level INFO
                    return
                }

                $result = $null
                try {
                    $result = Invoke-ImageBuild -BaseProfile $state.Base -Plan $plan -NewProfileName $name -AcceptanceLevel $level `
                        -ProfileVendor $ProfileVendor -Description (Get-DefaultDescription -BaseName ([string]$state.Base.Name) -VendorDepot $state.VendorZips) `
                        -ExportBundlePath $zipPath -Usage $state.Usage -Confirm:$false
                }
                finally {
                    # Once the clone exists the session's depots have changed and the loaded lists
                    # no longer apply. A check that failed before the clone leaves them usable.
                    $cloned = @(Get-EsxImageProfile -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $name }).Count -gt 0
                    if ($cloned -or ($null -ne $result -and $result.Built)) {
                        & $clearImages
                        $lblPlan.Text = 'Click Load ZIPs to build another image.'
                    }
                }

                if ($result.Exported) {
                    $done = "Image '$name' created and checked ($($result.VibCount) packages).`r`n`r`nZIP: $($result.ExportBundlePath)`r`n`r`nTo put it in the 'Software' depot: import the ZIP under Auto Deploy > Software Depots, then clone '$name' into 'Software' with no package changes."
                    [void][System.Windows.Forms.MessageBox]::Show($done, 'Image created', 'OK', 'Information')
                }
                else {
                    [void][System.Windows.Forms.MessageBox]::Show('WhatIf: every check before the clone passed. Nothing was built or exported.', 'WhatIf', 'OK', 'Information')
                }
            }
        })

    Write-BuildLog "Image builder window open." -Level INFO
    try {
        [void]$form.ShowDialog()
    }
    finally {
        $script:LogSink = $null
        $form.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Import-RequiredModules

$transcriptPath = $null
if ($Transcript) { $transcriptPath = Start-RichoTranscript }

try {
    Write-BuildLog "New-AutoDeployVendorImageProfile $ScriptVersion ($($PSCmdlet.ParameterSetName))." -Level INFO

    # ---- Window -----------------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'Gui') {
        Show-BuilderForm -Environment $Environment -AcceptanceLevel $AcceptanceLevel -ProfileVendor $ProfileVendor
        return
    }

    # ---- Command line -----------------------------------------------------
    $conn = Connect-AutoDeployVCenter -Environment $Environment
    $loaded = Import-BuildDepot -BaseDepot $BaseDepot -VendorDepot $VendorDepot -VendorVibName $VendorVibName

    $base = Select-BaseImageProfile -ImageProfile $loaded.Profiles -Name $BaseImageProfile -Usage $conn.Usage
    Write-BuildLog "ESXi image: '$($base.Name)' ($(@($base.VibList).Count) packages, acceptance level $($base.AcceptanceLevel))." -Level INFO
    if ($conn.Usage.ContainsKey([string]$base.Name)) {
        Write-BuildLog "Used by Auto Deploy rule(s): $(($conn.Usage[[string]$base.Name]) -join ', ')." -Level INFO
    }

    $plan = Get-VibSwapPlan -BaseVib @($base.VibList) -VendorVib $loaded.Vendor -RemoveVib $RemoveVib -ReplaceOnly:$ReplaceOnly
    Write-BuildLog "Packages for '$($base.Name)':" -Level INFO
    Write-SwapPlan -Plan $plan

    if (@($plan | Where-Object { $_.Action -in @('Replace', 'Add', 'Remove') }).Count -eq 0) {
        Write-BuildLog 'The ESXi image already carries every vendor package at the same or a newer version. Nothing to build.' -Level WARN
        return
    }

    $NewProfileName = Read-ProfileName -Name $NewProfileName -Default (Get-DefaultProfileName -BaseName $base.Name)
    $zipPath = Resolve-ExportPath -Path $ExportBundlePath -ProfileName $NewProfileName
    $isoPath = ''
    if ($ExportIsoPath) { $isoPath = Resolve-ExportPath -Path $ExportIsoPath -ProfileName $NewProfileName }
    if (-not $Description) { $Description = Get-DefaultDescription -BaseName $base.Name -VendorDepot $VendorDepot }

    $result = Invoke-ImageBuild -BaseProfile $base -Plan $plan -NewProfileName $NewProfileName -AcceptanceLevel $AcceptanceLevel `
        -ProfileVendor $ProfileVendor -Description $Description -ExportBundlePath $zipPath -ExportIsoPath $isoPath -Usage $conn.Usage

    if ($result.Exported) { Write-BuildLog 'Completed successfully.' -Level INFO }
}
catch {
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    if ($script:ConnectedServer) {
        Disconnect-VIServer -Server $script:ConnectedServer -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}
