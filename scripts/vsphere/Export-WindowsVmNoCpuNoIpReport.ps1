<#
.SYNOPSIS
    Finds Windows VMs with zero CPU usage and no VMware Tools IP address, shows them in a window,
    and exports them to CSV.

.DESCRIPTION
    Run it with no parameters and a window asks which vCenter to query: type one or more vCenter
    names, tick sites from config/environments.json, or both. Credentials come from
    Get-RichoCredential (SecretManagement, then RICHO_* environment variables, then a prompt).

    Every check uses what vCenter already holds for each VM - nothing logs into the guest:

      1. Windows    - the configured guest OS (Config.GuestId starts with "win", or
                      Config.GuestFullName contains "Windows"). The configured value is used
                      because a VM with no Tools heartbeat reports no guest family at all. The
                      Tools-reported family (windowsGuest) also counts when it is present.
      2. CPU zero   - Summary.QuickStats.OverallCpuUsage (MHz) is at or below -CpuThresholdMhz,
                      which defaults to 0. This is CPU *usage*, not the vCPU count, and it is a
                      single ~20-second sample.
      3. No IP      - VMware Tools reports no IP address, neither Guest.IpAddress nor any
                      address on Guest.Net.

    A VM is reported only when all three are true. Templates are skipped. Powered-off and
    suspended VMs are skipped unless -IncludePoweredOff is given (or ticked in the window),
    because they always have zero CPU and no IP and would bury the VMs worth looking at.

    Results open in a second window: a sortable grid with a filter box, the CSV path, and
    buttons to open the CSV or save a copy. The CSV holds Server (VM name), Datastore and VM
    Folder, plus datacenter, cluster, host, guest OS, vCPU count, CPU usage and Tools status.

    READ ONLY against vCenter. The only thing written is the CSV (and, with -Transcript, a
    transcript under logs/). The vCenter connections this script opens are closed before the
    results window appears; other PowerCLI sessions in the same console are left alone.

    SINGLE FILE. Inside the repo it uses Richo.Common; copied anywhere on its own it uses
    built-in fallbacks and keeps output/, logs/ and an optional environments.json next to itself.

    Requires VMware.VimAutomation.Core (PowerCLI). The windows need Windows; pass -VCenter or
    -Site to run without them, for example from a scheduled task.

.PARAMETER VCenter
    One or more vCenter server names to query without showing the window. Credentials are
    looked up under the server name, or under the matching site's credentialName when the
    server is also in config/environments.json.

.PARAMETER Site
    One or more environment keys from config/environments.json to query without showing the
    window. Can be combined with -VCenter.

.PARAMETER OutputPath
    CSV to write. Defaults to output/WindowsVmNoCpuNoIp_<timestamp>.csv at the repo root
    (output/ is gitignored), or in output/ next to the script when it runs on its own.

.PARAMETER IncludePoweredOff
    Also report powered-off and suspended Windows VMs. Off by default.

.PARAMETER CpuThresholdMhz
    Treat CPU usage at or below this many MHz as zero. Defaults to 0, meaning exactly zero.

.PARAMETER ConfigPath
    Override the environments file. Defaults to $env:RICHO_CONFIG when set, otherwise
    config/environments.json at the repo root - or environments.json next to the script when it
    runs on its own. Optional: a typed vCenter needs no config.

.PARAMETER PassThru
    Also write the report rows to the pipeline.

.PARAMETER Transcript
    Record a transcript under logs/.

.EXAMPLE
    .\Export-WindowsVmNoCpuNoIpReport.ps1

    Asks for the vCenter, runs the checks, shows the results window and writes the CSV.

.EXAMPLE
    .\Export-WindowsVmNoCpuNoIpReport.ps1 -VCenter vcenter01.example.com -OutputPath D:\Reports\win-no-ip.csv

    No window. Queries one vCenter by name and writes the CSV to the given path.

.EXAMPLE
    .\Export-WindowsVmNoCpuNoIpReport.ps1 -Site prod, dr -CpuThresholdMhz 20 -PassThru | Format-Table Server, Host, CpuUsageMhz

    No window. Queries two configured sites, treats anything at or below 20 MHz as zero, and
    shows the matches in the console as well.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string[]]$VCenter,

    [string[]]$Site,

    [string]$OutputPath,

    [switch]$IncludePoweredOff,

    [ValidateRange(0, 1000000)]
    [int]$CpuThresholdMhz = 0,

    [string]$ConfigPath,

    [switch]$PassThru,

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.1.0'
$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

# Works in two places. Inside the repo it uses Richo.Common and the repo's config/ and output/.
# Copied anywhere on its own it uses the built-in fallbacks below and keeps environments.json,
# output/ and logs/ next to itself - one file, nothing else to copy.
$richoCommonPath = Join-Path -Path $repoRoot -ChildPath 'modules/Richo.Common/Richo.Common.psd1'
$standalone = -not (Test-Path -LiteralPath $richoCommonPath)
$baseDir = if ($standalone) { $PSScriptRoot } else { $repoRoot }

# Column order of the CSV. The three asked-for columns come straight after the site.
$reportColumns = @(
    'Site', 'vCenter', 'Server', 'Datastore', 'VMFolder', 'Datacenter', 'Cluster', 'Host',
    'PowerState', 'GuestOS', 'GuestId', 'vCPU', 'CpuUsageMhz',
    'ToolsRunningStatus', 'ToolsVersionStatus', 'ReportedAtUtc', 'ScriptVersion'
)

#region Helpers

function Import-RequiredModules {
    <#
    .SYNOPSIS
        Loads the named modules, skipping any that are already loaded.

    .DESCRIPTION
        Each load is guarded by Get-Module, so a module already in the session - including a
        pinned bundle - is left exactly as it is. Nothing is installed or updated.

    .PARAMETER Module
        Ordered map of module name to what Import-Module should be given for it (the same name,
        or a path to a .psd1 for modules that are not on PSModulePath).

    .EXAMPLE
        Import-RequiredModules -Module ([ordered]@{ 'VMware.VimAutomation.Core' = 'VMware.VimAutomation.Core' })
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Module
    )

    foreach ($name in @($Module.Keys)) {
        if (Get-Module -Name $name) { continue }
        Import-Module -Name $Module[$name] -ErrorAction Stop
    }
}

function Get-SafeProperty {
    <#
    .SYNOPSIS
        Reads a dotted property path, returning $null instead of throwing when any step is missing.

    .DESCRIPTION
        Under Set-StrictMode -Version Latest, reading a property of $null, or a property that
        does not exist, throws. vSphere views fetched with Get-View -Property leave every
        unrequested property null, and an inaccessible VM has no Config at all, so every read of
        a view goes through here.

    .PARAMETER InputObject
        The object to read from.

    .PARAMETER Path
        Dotted path, e.g. 'Summary.QuickStats.OverallCpuUsage'.

    .EXAMPLE
        Get-SafeProperty -InputObject $vmView -Path 'Config.GuestId'
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $current = $InputObject
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    return $current
}

function Get-MoRefKey {
    <#
    .SYNOPSIS
        Turns a ManagedObjectReference into a 'Type-Value' lookup key.

    .PARAMETER Ref
        The ManagedObjectReference, or $null.

    .EXAMPLE
        Get-MoRefKey -Ref $vmView.Parent
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Ref
    )

    if ($null -eq $Ref) { return '' }
    $type = Get-SafeProperty -InputObject $Ref -Path 'Type'
    $value = Get-SafeProperty -InputObject $Ref -Path 'Value'
    if ($null -eq $type) { return '' }
    return ('{0}-{1}' -f $type, $value)
}

function Test-WindowsGuest {
    <#
    .SYNOPSIS
        True when a VM's guest OS is Windows.

    .DESCRIPTION
        Uses the configured guest OS first, because a VM without a Tools heartbeat - exactly
        the VMs this report is after - reports no guest family. The Tools-reported family is
        accepted as well when present.

    .PARAMETER VmView
        A VirtualMachine view from Get-View.

    .EXAMPLE
        Test-WindowsGuest -VmView $vmView
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        $VmView
    )

    $guestId = [string](Get-SafeProperty -InputObject $VmView -Path 'Config.GuestId')
    $fullName = [string](Get-SafeProperty -InputObject $VmView -Path 'Config.GuestFullName')
    $family = [string](Get-SafeProperty -InputObject $VmView -Path 'Guest.GuestFamily')

    return (($guestId -like 'win*') -or ($fullName -match 'Windows') -or ($family -eq 'windowsGuest'))
}

function Get-ToolsIpAddress {
    <#
    .SYNOPSIS
        Every IP address VMware Tools reports for a VM, de-duplicated. Empty when there are none.

    .PARAMETER VmView
        A VirtualMachine view from Get-View.

    .EXAMPLE
        @(Get-ToolsIpAddress -VmView $vmView).Count -eq 0
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $VmView
    )

    $addresses = New-Object System.Collections.Generic.List[string]

    $primary = [string](Get-SafeProperty -InputObject $VmView -Path 'Guest.IpAddress')
    if (-not [string]::IsNullOrWhiteSpace($primary)) { $addresses.Add($primary.Trim()) }

    foreach ($nic in @(Get-SafeProperty -InputObject $VmView -Path 'Guest.Net')) {
        if ($null -eq $nic) { continue }
        foreach ($ip in @(Get-SafeProperty -InputObject $nic -Path 'IpAddress')) {
            $text = [string]$ip
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if (-not $addresses.Contains($text.Trim())) { $addresses.Add($text.Trim()) }
        }
    }

    return $addresses.ToArray()
}

function Get-VmEvaluation {
    <#
    .SYNOPSIS
        Decides whether one VM belongs in the report, and records why.

    .PARAMETER VmView
        A VirtualMachine view from Get-View.

    .PARAMETER IncludePoweredOff
        Let powered-off and suspended VMs match.

    .PARAMETER CpuThresholdMhz
        CPU usage at or below this counts as zero.

    .EXAMPLE
        (Get-VmEvaluation -VmView $vmView -CpuThresholdMhz 0).IsMatch
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $VmView,

        [switch]$IncludePoweredOff,

        [int]$CpuThresholdMhz = 0
    )

    $powerState = [string](Get-SafeProperty -InputObject $VmView -Path 'Runtime.PowerState')
    $isTemplate = [bool](Get-SafeProperty -InputObject $VmView -Path 'Config.Template')
    $isWindowsGuest = Test-WindowsGuest -VmView $VmView

    $cpuValue = Get-SafeProperty -InputObject $VmView -Path 'Summary.QuickStats.OverallCpuUsage'
    $cpuMhz = if ($null -eq $cpuValue) { 0 } else { [int]$cpuValue }

    $ipAddresses = @(Get-ToolsIpAddress -VmView $VmView)

    $powerAllowed = ($powerState -eq 'poweredOn') -or $IncludePoweredOff.IsPresent
    $cpuIsZero = $cpuMhz -le $CpuThresholdMhz
    $hasNoIp = $ipAddresses.Count -eq 0

    [pscustomobject]@{
        IsMatch     = ((-not $isTemplate) -and $isWindowsGuest -and $powerAllowed -and $cpuIsZero -and $hasNoIp)
        IsTemplate  = $isTemplate
        IsWindows   = $isWindowsGuest
        PowerState  = $powerState
        CpuMhz      = $cpuMhz
        CpuIsZero   = $cpuIsZero
        HasNoIp     = $hasNoIp
        IpAddresses = $ipAddresses
    }
}

function Get-VmFolderPath {
    <#
    .SYNOPSIS
        Builds a VM's folder path, e.g. '/Prod/App', and finds its datacenter.

    .DESCRIPTION
        Walks up from the VM's parent through the lookup built by Get-InventoryLookup. The
        hidden 'vm' folder directly under each datacenter is left out, so a VM at the top of
        the VMs and Templates view reports '/'. A VM inside a vApp has the vApp name in its
        path, followed by the folder the vApp sits in.

    .PARAMETER Lookup
        Hashtable of 'Type-Value' key to view, from Get-InventoryLookup.

    .PARAMETER StartRef
        The VM's Parent (or ParentVApp when Parent is empty).

    .EXAMPLE
        Get-VmFolderPath -Lookup $lookup -StartRef $vmView.Parent
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Lookup,

        [AllowNull()]
        $StartRef
    )

    $names = New-Object System.Collections.Generic.List[string]
    $datacenter = ''
    $complete = $false
    $ref = $StartRef

    # Bounded so a malformed or partial lookup can never loop forever.
    for ($depth = 0; ($null -ne $ref) -and ($depth -lt 64); $depth++) {
        $refType = [string](Get-SafeProperty -InputObject $ref -Path 'Type')
        $node = $Lookup[(Get-MoRefKey -Ref $ref)]
        if ($null -eq $node) { break }

        $nodeName = [string](Get-SafeProperty -InputObject $node -Path 'Name')

        if ($refType -eq 'Datacenter') {
            $datacenter = $nodeName
            $complete = $true
            break
        }

        if ($refType -eq 'VirtualApp') {
            $names.Add($nodeName)
            $next = Get-SafeProperty -InputObject $node -Path 'ParentFolder'
            if ($null -eq $next) { $next = Get-SafeProperty -InputObject $node -Path 'ParentVApp' }
            $ref = $next
            continue
        }

        $parentRef = Get-SafeProperty -InputObject $node -Path 'Parent'
        $parentType = [string](Get-SafeProperty -InputObject $parentRef -Path 'Type')
        if ($parentType -ne 'Datacenter') { $names.Add($nodeName) }
        $ref = $parentRef
    }

    $names.Reverse()
    $path = '/' + ($names -join '/')
    if (-not $complete) { $path = "(incomplete) $path" }

    [pscustomobject]@{
        Datacenter = $datacenter
        Path       = $path
    }
}

function Get-InventoryLookup {
    <#
    .SYNOPSIS
        Fetches folders, datacenters, vApps, datastores, hosts and clusters once, keyed by MoRef.

    .DESCRIPTION
        One Get-View per type with only the properties needed, instead of a round trip per VM.
        A type that cannot be read is logged and skipped; its names then show blank in the
        report rather than stopping the run.

    .PARAMETER Server
        The connected vCenter (from Connect-VIServer).

    .EXAMPLE
        $lookup = Get-InventoryLookup -Server $vc
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        $Server
    )

    $lookup = @{}
    $specs = @(
        @{ ViewType = 'Folder'; Property = @('Name', 'Parent') }
        @{ ViewType = 'Datacenter'; Property = @('Name', 'Parent') }
        @{ ViewType = 'VirtualApp'; Property = @('Name', 'Parent', 'ParentFolder', 'ParentVApp') }
        @{ ViewType = 'Datastore'; Property = @('Name') }
        @{ ViewType = 'HostSystem'; Property = @('Name', 'Parent') }
        @{ ViewType = 'ComputeResource'; Property = @('Name') }
    )

    foreach ($spec in $specs) {
        try {
            foreach ($view in @(Get-View -Server $Server -ViewType $spec.ViewType -Property $spec.Property)) {
                if ($null -eq $view) { continue }
                $lookup[(Get-MoRefKey -Ref $view.MoRef)] = $view
            }
        }
        catch {
            Write-RichoLog "Could not read $($spec.ViewType) objects ($($_.Exception.Message)); those names will be blank." -Level WARN
        }
    }

    return $lookup
}

function ConvertTo-ReportRow {
    <#
    .SYNOPSIS
        Builds one CSV row for a matching VM.

    .PARAMETER VmView
        The VirtualMachine view.

    .PARAMETER Evaluation
        Its result from Get-VmEvaluation.

    .PARAMETER Lookup
        Inventory lookup from Get-InventoryLookup.

    .PARAMETER SiteName
        Environment key the VM was found under.

    .PARAMETER ServerName
        vCenter the VM was found in.

    .PARAMETER ReportedAtUtc
        Timestamp to stamp on the row.

    .EXAMPLE
        ConvertTo-ReportRow -VmView $vm -Evaluation $eval -Lookup $lookup -SiteName prod -ServerName vc01 -ReportedAtUtc $now
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $VmView,

        [Parameter(Mandatory)]
        $Evaluation,

        [Parameter(Mandatory)]
        [hashtable]$Lookup,

        [Parameter(Mandatory)]
        [string]$SiteName,

        [Parameter(Mandatory)]
        [string]$ServerName,

        [Parameter(Mandatory)]
        [string]$ReportedAtUtc
    )

    $datastoreNames = New-Object System.Collections.Generic.List[string]
    foreach ($dsRef in @(Get-SafeProperty -InputObject $VmView -Path 'Datastore')) {
        if ($null -eq $dsRef) { continue }
        $dsView = $Lookup[(Get-MoRefKey -Ref $dsRef)]
        $dsName = [string](Get-SafeProperty -InputObject $dsView -Path 'Name')
        if ([string]::IsNullOrEmpty($dsName)) { $dsName = Get-MoRefKey -Ref $dsRef }
        $datastoreNames.Add($dsName)
    }

    $hostRef = Get-SafeProperty -InputObject $VmView -Path 'Runtime.Host'
    $hostView = if ($null -ne $hostRef) { $Lookup[(Get-MoRefKey -Ref $hostRef)] } else { $null }
    $hostName = [string](Get-SafeProperty -InputObject $hostView -Path 'Name')

    $clusterName = ''
    $clusterRef = Get-SafeProperty -InputObject $hostView -Path 'Parent'
    if ([string](Get-SafeProperty -InputObject $clusterRef -Path 'Type') -eq 'ClusterComputeResource') {
        $clusterView = $Lookup[(Get-MoRefKey -Ref $clusterRef)]
        $clusterName = [string](Get-SafeProperty -InputObject $clusterView -Path 'Name')
    }

    $startRef = Get-SafeProperty -InputObject $VmView -Path 'Parent'
    if ($null -eq $startRef) { $startRef = Get-SafeProperty -InputObject $VmView -Path 'ParentVApp' }
    $folder = Get-VmFolderPath -Lookup $Lookup -StartRef $startRef

    [pscustomobject]@{
        Site               = $SiteName
        vCenter            = $ServerName
        Server             = [string](Get-SafeProperty -InputObject $VmView -Path 'Name')
        Datastore          = ($datastoreNames -join '; ')
        VMFolder           = $folder.Path
        Datacenter         = $folder.Datacenter
        Cluster            = $clusterName
        Host               = $hostName
        PowerState         = $Evaluation.PowerState
        GuestOS            = [string](Get-SafeProperty -InputObject $VmView -Path 'Config.GuestFullName')
        GuestId            = [string](Get-SafeProperty -InputObject $VmView -Path 'Config.GuestId')
        vCPU               = Get-SafeProperty -InputObject $VmView -Path 'Config.Hardware.NumCPU'
        CpuUsageMhz        = $Evaluation.CpuMhz
        ToolsRunningStatus = [string](Get-SafeProperty -InputObject $VmView -Path 'Guest.ToolsRunningStatus')
        ToolsVersionStatus = [string](Get-SafeProperty -InputObject $VmView -Path 'Guest.ToolsVersionStatus2')
        ReportedAtUtc      = $ReportedAtUtc
        ScriptVersion      = $ScriptVersion
    }
}

function Get-WindowsVmNoCpuNoIp {
    <#
    .SYNOPSIS
        Queries one vCenter and returns a report row for every matching VM.

    .PARAMETER Server
        The connected vCenter (from Connect-VIServer).

    .PARAMETER SiteName
        Environment key, stamped on each row.

    .PARAMETER IncludePoweredOff
        Let powered-off and suspended VMs match.

    .PARAMETER CpuThresholdMhz
        CPU usage at or below this counts as zero.

    .EXAMPLE
        Get-WindowsVmNoCpuNoIp -Server $vc -SiteName prod
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Server,

        [Parameter(Mandatory)]
        [string]$SiteName,

        [switch]$IncludePoweredOff,

        [int]$CpuThresholdMhz = 0
    )

    $vmProperties = @(
        'Name', 'Parent', 'ParentVApp', 'Datastore',
        'Config.Template', 'Config.GuestId', 'Config.GuestFullName', 'Config.Hardware.NumCPU',
        'Guest.GuestFamily', 'Guest.IpAddress', 'Guest.Net', 'Guest.ToolsRunningStatus', 'Guest.ToolsVersionStatus2',
        'Summary.QuickStats.OverallCpuUsage', 'Runtime.PowerState', 'Runtime.Host'
    )

    Write-RichoLog "[$SiteName] Reading inventory (folders, datastores, hosts, clusters)."
    $lookup = Get-InventoryLookup -Server $Server

    Write-RichoLog "[$SiteName] Reading virtual machines."
    $vmViews = @(Get-View -Server $Server -ViewType VirtualMachine -Property $vmProperties)

    $reportedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    $windowsCount = 0
    $matchCount = 0

    foreach ($vmView in $vmViews) {
        if ($null -eq $vmView) { continue }
        $evaluation = Get-VmEvaluation -VmView $vmView -IncludePoweredOff:$IncludePoweredOff -CpuThresholdMhz $CpuThresholdMhz
        if ($evaluation.IsWindows -and (-not $evaluation.IsTemplate)) { $windowsCount++ }
        if (-not $evaluation.IsMatch) { continue }

        $matchCount++
        $rowArgs = @{
            VmView        = $vmView
            Evaluation    = $evaluation
            Lookup        = $lookup
            SiteName      = $SiteName
            ServerName    = [string]$Server.Name
            ReportedAtUtc = $reportedAt
        }
        ConvertTo-ReportRow @rowArgs
    }

    $summary = '[{0}] {1} VM(s) scanned, {2} Windows, {3} with CPU <= {4} MHz and no Tools IP.' -f $SiteName, $vmViews.Count, $windowsCount, $matchCount, $CpuThresholdMhz
    Write-RichoLog $summary
}

function Get-SiteList {
    <#
    .SYNOPSIS
        Lists the environments in the config file that have a vCenter server.

    .PARAMETER Path
        The environments JSON file.

    .PARAMETER AllowMissing
        Return nothing, instead of throwing, when the file does not exist. The window can still
        run on a typed vCenter name without any config file.

    .EXAMPLE
        Get-SiteList -Path .\config\environments.json -AllowMissing
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowMissing
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($AllowMissing) { return }
        throw "Config file not found: $Path. Copy config/environments.example.json to config/environments.json and fill it in."
    }

    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $environments = Get-SafeProperty -InputObject $raw -Path 'environments'
    if ($null -eq $environments) { throw "'$Path' has no 'environments' section." }
    $default = [string](Get-SafeProperty -InputObject $raw -Path 'default')

    foreach ($entry in $environments.PSObject.Properties) {
        $vcServer = [string](Get-SafeProperty -InputObject $entry.Value -Path 'vcenter.server')
        if ([string]::IsNullOrWhiteSpace($vcServer)) { continue }
        $credentialName = [string](Get-SafeProperty -InputObject $entry.Value -Path 'vcenter.credentialName')
        if ([string]::IsNullOrWhiteSpace($credentialName)) { $credentialName = $vcServer }
        [pscustomobject]@{
            Name           = $entry.Name
            Server         = $vcServer
            CredentialName = $credentialName
            Description    = [string](Get-SafeProperty -InputObject $entry.Value -Path 'description')
            IsDefault      = ($entry.Name -eq $default)
        }
    }
}

function ConvertTo-NameList {
    <#
    .SYNOPSIS
        Splits typed or passed names on commas, semicolons and whitespace; trims and de-duplicates.

    .DESCRIPTION
        Handles both a real array and the single "a,b" string that 'pwsh -File' and
        'powershell.exe -File' (a scheduled task, for instance) pass for "-Site a,b". Order is
        kept; duplicates are dropped case-insensitively.

    .PARAMETER Value
        Names, or strings holding several names.

    .EXAMPLE
        ConvertTo-NameList -Value 'vc01, vc02;vc03'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Value
    )

    $seen = @{}
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        foreach ($part in ($item -split '[,;\s]+')) {
            $name = $part.Trim()
            if (-not $name) { continue }
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            $names.Add($name)
        }
    }
    return $names.ToArray()
}

function Resolve-ReportTarget {
    <#
    .SYNOPSIS
        Turns chosen site names and typed vCenter names into a list of vCenters to query.

    .DESCRIPTION
        A configured site brings its own server and credential name. A typed vCenter that matches
        a configured site's server uses that site's name and credential; any other typed vCenter
        is labelled with its own name and its credential is looked up (and prompted for) under that
        name. Each vCenter appears once however it was chosen. A site name that is not in the
        config comes back with Problem set, so the run can report it and carry on.

    .PARAMETER SiteList
        Sites from Get-SiteList.

    .PARAMETER SiteName
        Environment keys that were chosen.

    .PARAMETER VCenter
        vCenter names that were typed.

    .EXAMPLE
        Resolve-ReportTarget -SiteList $sites -SiteName prod -VCenter vc-test01.example.com
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [object[]]$SiteList = @(),

        [AllowEmptyCollection()]
        [string[]]$SiteName = @(),

        [AllowEmptyCollection()]
        [string[]]$VCenter = @()
    )

    $seenServers = @{}
    $known = (@($SiteList | ForEach-Object { $_.Name }) -join ', ')
    if (-not $known) { $known = '(none)' }

    foreach ($name in @($SiteName)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $match = @($SiteList | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
        if ($match.Count -eq 0) {
            [pscustomobject]@{ Label = $name; Server = ''; CredentialName = ''; Problem = "Site '$name' is not in the config. Known sites: $known" }
            continue
        }
        if ($seenServers.ContainsKey($match[0].Server)) { continue }
        $seenServers[$match[0].Server] = $true
        [pscustomobject]@{ Label = $match[0].Name; Server = $match[0].Server; CredentialName = $match[0].CredentialName; Problem = '' }
    }

    foreach ($vcName in @($VCenter)) {
        if ([string]::IsNullOrWhiteSpace($vcName)) { continue }
        if ($seenServers.ContainsKey($vcName)) { continue }
        $seenServers[$vcName] = $true
        $match = @($SiteList | Where-Object { $_.Server -eq $vcName } | Select-Object -First 1)
        if ($match.Count -gt 0) {
            [pscustomobject]@{ Label = $match[0].Name; Server = $vcName; CredentialName = $match[0].CredentialName; Problem = '' }
        }
        else {
            [pscustomobject]@{ Label = $vcName; Server = $vcName; CredentialName = $vcName; Problem = '' }
        }
    }
}

function ConvertTo-RowFilterLiteral {
    <#
    .SYNOPSIS
        Escapes text for use inside a DataView RowFilter LIKE '%...%' pattern.

    .DESCRIPTION
        Wildcard and bracket characters are wrapped in brackets and single quotes are doubled,
        so typing a VM name such as "app[1]" or "50%" filters literally instead of throwing or
        matching everything.

    .PARAMETER Value
        The text typed in the filter box.

    .EXAMPLE
        ConvertTo-RowFilterLiteral -Value "o'brien*"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    return (($Value -replace '([\[\]\*%])', '[$1]') -replace "'", "''")
}

function Get-ReportRowFilter {
    <#
    .SYNOPSIS
        Builds the RowFilter expression for the results filter box.

    .PARAMETER Text
        The text typed in the filter box. Empty clears the filter.

    .PARAMETER Column
        The text columns to search.

    .EXAMPLE
        $table.DefaultView.RowFilter = Get-ReportRowFilter -Text 'DS_GOLD' -Column Server, Datastore
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Column
    )

    $trimmed = ([string]$Text).Trim()
    if (-not $trimmed) { return '' }
    $literal = ConvertTo-RowFilterLiteral -Value $trimmed
    return ((@($Column) | ForEach-Object { "[{0}] LIKE '%{1}%'" -f $_, $literal }) -join ' OR ')
}

function ConvertTo-ReportDataTable {
    <#
    .SYNOPSIS
        Loads report rows into a DataTable for the results grid.

    .DESCRIPTION
        A DataTable gives the grid click-to-sort columns and a filterable view. vCPU and CPU MHz
        are typed as numbers so they sort as numbers; empty values become DBNull.

    .PARAMETER Row
        Report rows from ConvertTo-ReportRow.

    .PARAMETER Column
        Column names, in display order.

    .EXAMPLE
        $table = ConvertTo-ReportDataTable -Row $rows -Column $reportColumns
    #>
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Column
    )

    $numericColumns = @('vCPU', 'CpuUsageMhz')
    $table = New-Object System.Data.DataTable 'Report'
    foreach ($name in $Column) {
        $type = if ($numericColumns -contains $name) { [int] } else { [string] }
        [void]$table.Columns.Add($name, $type)
    }

    foreach ($item in $Row) {
        if ($null -eq $item) { continue }
        $dataRow = $table.NewRow()
        foreach ($name in $Column) {
            $value = Get-SafeProperty -InputObject $item -Path $name
            if (($null -eq $value) -or ([string]$value -eq '')) { $dataRow[$name] = [System.DBNull]::Value }
            elseif ($numericColumns -contains $name) { $dataRow[$name] = [int]$value }
            else { $dataRow[$name] = [string]$value }
        }
        $table.Rows.Add($dataRow)
    }

    # The comma stops PowerShell unrolling the table into its rows on the way out.
    return , $table
}

function Show-SiteSelectionForm {
    <#
    .SYNOPSIS
        Asks which vCenter(s) to query. Returns the choices, or $null when cancelled.

    .DESCRIPTION
        Type one or more vCenter names, tick configured sites, or both. The configured list is
        optional; with no config file the window still works from typed names.

    .PARAMETER SiteList
        Sites from Get-SiteList. May be empty.

    .PARAMETER DefaultOutputPath
        CSV path to pre-fill.

    .PARAMETER IncludePoweredOff
        Initial state of the powered-off tick box.

    .PARAMETER CpuThresholdMhz
        Initial CPU threshold.

    .EXAMPLE
        $choice = Show-SiteSelectionForm -SiteList $sites -DefaultOutputPath $csv
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$SiteList,

        [Parameter(Mandatory)]
        [string]$DefaultOutputPath,

        [bool]$IncludePoweredOff = $false,

        [int]$CpuThresholdMhz = 0
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    try {
        $form.Text = 'Windows VMs - no CPU / no IP report'
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ClientSize = New-Object System.Drawing.Size(560, 520)
        $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $lblServer = New-Object System.Windows.Forms.Label
        $lblServer.Text = 'vCenter server - type one or more, separated by commas:'
        $lblServer.Location = New-Object System.Drawing.Point(12, 12)
        $lblServer.AutoSize = $true
        $form.Controls.Add($lblServer)

        $txtServer = New-Object System.Windows.Forms.TextBox
        $txtServer.Location = New-Object System.Drawing.Point(12, 34)
        $txtServer.Size = New-Object System.Drawing.Size(536, 24)
        $form.Controls.Add($txtServer)

        $lblSites = New-Object System.Windows.Forms.Label
        $lblSites.Location = New-Object System.Drawing.Point(12, 70)
        $lblSites.AutoSize = $true
        $lblSites.Text = if ($SiteList.Count -gt 0) { '...and/or tick configured sites (environments.json):' } else { 'No configured sites found - type a vCenter above.' }
        $form.Controls.Add($lblSites)

        $clbSites = New-Object System.Windows.Forms.CheckedListBox
        $clbSites.Location = New-Object System.Drawing.Point(12, 92)
        $clbSites.Size = New-Object System.Drawing.Size(536, 140)
        $clbSites.CheckOnClick = $true
        $clbSites.IntegralHeight = $false
        foreach ($entry in $SiteList) {
            $label = '{0}  -  {1}' -f $entry.Name, $entry.Server
            if (-not [string]::IsNullOrWhiteSpace($entry.Description)) { $label += "  ($($entry.Description))" }
            [void]$clbSites.Items.Add($label)
        }
        $clbSites.Enabled = ($SiteList.Count -gt 0)
        $form.Controls.Add($clbSites)

        $chkAll = New-Object System.Windows.Forms.CheckBox
        $chkAll.Text = 'Select all configured sites'
        $chkAll.Location = New-Object System.Drawing.Point(12, 238)
        $chkAll.AutoSize = $true
        $chkAll.Enabled = ($SiteList.Count -gt 0)
        $chkAll.Add_CheckedChanged({
                for ($i = 0; $i -lt $clbSites.Items.Count; $i++) { $clbSites.SetItemChecked($i, $chkAll.Checked) }
            })
        $form.Controls.Add($chkAll)

        $chkPoweredOff = New-Object System.Windows.Forms.CheckBox
        $chkPoweredOff.Text = 'Include powered-off / suspended VMs (they always have no CPU and no IP)'
        $chkPoweredOff.Location = New-Object System.Drawing.Point(12, 268)
        $chkPoweredOff.AutoSize = $true
        $chkPoweredOff.Checked = $IncludePoweredOff
        $form.Controls.Add($chkPoweredOff)

        $lblCpu = New-Object System.Windows.Forms.Label
        $lblCpu.Text = 'Treat CPU usage at or below this many MHz as zero:'
        $lblCpu.Location = New-Object System.Drawing.Point(12, 302)
        $lblCpu.AutoSize = $true
        $form.Controls.Add($lblCpu)

        $numCpu = New-Object System.Windows.Forms.NumericUpDown
        $numCpu.Location = New-Object System.Drawing.Point(340, 299)
        $numCpu.Size = New-Object System.Drawing.Size(90, 24)
        $numCpu.Minimum = 0
        $numCpu.Maximum = 1000000
        $numCpu.Value = $CpuThresholdMhz
        $form.Controls.Add($numCpu)

        $lblOut = New-Object System.Windows.Forms.Label
        $lblOut.Text = 'Save CSV to:'
        $lblOut.Location = New-Object System.Drawing.Point(12, 336)
        $lblOut.AutoSize = $true
        $form.Controls.Add($lblOut)

        $txtOut = New-Object System.Windows.Forms.TextBox
        $txtOut.Location = New-Object System.Drawing.Point(12, 356)
        $txtOut.Size = New-Object System.Drawing.Size(440, 24)
        $txtOut.Text = $DefaultOutputPath
        $form.Controls.Add($txtOut)

        $btnBrowse = New-Object System.Windows.Forms.Button
        $btnBrowse.Text = 'Browse...'
        $btnBrowse.Location = New-Object System.Drawing.Point(460, 354)
        $btnBrowse.Size = New-Object System.Drawing.Size(88, 26)
        # File dialogs need a single-threaded apartment. Rather than guess how this host was
        # started, check, and fall back to typing the path.
        if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
            $btnBrowse.Enabled = $false
            $tip = New-Object System.Windows.Forms.ToolTip
            $tip.SetToolTip($txtOut, 'Type the path. Browse needs PowerShell started with -STA.')
        }
        $btnBrowse.Add_Click({
                $dialog = New-Object System.Windows.Forms.SaveFileDialog
                try {
                    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
                    $dialog.DefaultExt = 'csv'
                    $current = $txtOut.Text.Trim()
                    if ($current) {
                        $dialog.FileName = [System.IO.Path]::GetFileName($current)
                        $dir = [System.IO.Path]::GetDirectoryName($current)
                        if ($dir -and (Test-Path -LiteralPath $dir)) { $dialog.InitialDirectory = $dir }
                    }
                    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $txtOut.Text = $dialog.FileName }
                }
                finally {
                    $dialog.Dispose()
                }
            })
        $form.Controls.Add($btnBrowse)

        $lblCriteria = New-Object System.Windows.Forms.Label
        $lblCriteria.Text = 'Finds VMs that are Windows (configured guest OS) AND show CPU usage at or below the threshold AND have no IP address reported by VMware Tools. Read only - nothing in vCenter is changed. You will be asked for credentials for each vCenter that has none stored.'
        $lblCriteria.Location = New-Object System.Drawing.Point(12, 392)
        $lblCriteria.Size = New-Object System.Drawing.Size(536, 64)
        $lblCriteria.ForeColor = [System.Drawing.SystemColors]::GrayText
        $form.Controls.Add($lblCriteria)

        $btnRun = New-Object System.Windows.Forms.Button
        $btnRun.Text = 'Run report'
        $btnRun.Location = New-Object System.Drawing.Point(360, 480)
        $btnRun.Size = New-Object System.Drawing.Size(90, 28)
        $btnRun.Add_Click({
                $typed = @(ConvertTo-NameList -Value $txtServer.Text)
                if (($typed.Count -eq 0) -and ($clbSites.CheckedIndices.Count -eq 0)) {
                    [void][System.Windows.Forms.MessageBox]::Show($form, 'Type a vCenter server or tick at least one site.', $form.Text,
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    return
                }
                if ([string]::IsNullOrWhiteSpace($txtOut.Text)) {
                    [void][System.Windows.Forms.MessageBox]::Show($form, 'Choose where to save the CSV.', $form.Text,
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    return
                }
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            })
        $form.Controls.Add($btnRun)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = 'Cancel'
        $btnCancel.Location = New-Object System.Drawing.Point(458, 480)
        $btnCancel.Size = New-Object System.Drawing.Size(90, 28)
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($btnCancel)

        $form.AcceptButton = $btnRun
        $form.CancelButton = $btnCancel
        $form.ActiveControl = $txtServer

        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

        $selected = New-Object System.Collections.Generic.List[object]
        foreach ($index in $clbSites.CheckedIndices) { $selected.Add($SiteList[$index]) }

        return [pscustomobject]@{
            VCenters          = @(ConvertTo-NameList -Value $txtServer.Text)
            Sites             = $selected.ToArray()
            OutputPath        = $txtOut.Text.Trim()
            IncludePoweredOff = $chkPoweredOff.Checked
            CpuThresholdMhz   = [int]$numCpu.Value
        }
    }
    finally {
        $form.Dispose()
    }
}

function Show-ResultsForm {
    <#
    .SYNOPSIS
        Shows the report in a sortable, filterable grid, with buttons to open or copy the CSV.

    .PARAMETER Row
        Report rows.

    .PARAMETER Column
        Column names, in display order.

    .PARAMETER CsvPath
        The CSV this run wrote.

    .PARAMETER Summary
        One line describing what was queried and with which settings.

    .PARAMETER FailedTarget
        vCenters that could not be queried, shown in red so a short list is not mistaken for a
        complete one.

    .EXAMPLE
        Show-ResultsForm -Row $rows -Column $reportColumns -CsvPath $csv -Summary 'lab; CPU <= 0 MHz'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Row,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Column,

        [Parameter(Mandatory)]
        [string]$CsvPath,

        [string]$Summary = '',

        [AllowEmptyCollection()]
        [string[]]$FailedTarget = @()
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Data
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $table = ConvertTo-ReportDataTable -Row $Row -Column $Column
    $textColumns = @($Column | Where-Object { $table.Columns[$_].DataType -eq [string] })
    $total = $table.Rows.Count

    $form = New-Object System.Windows.Forms.Form
    try {
        $form.Text = 'Windows VMs - no CPU / no IP - results'
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.Size = New-Object System.Drawing.Size(1280, 700)
        $form.MinimumSize = New-Object System.Drawing.Size(800, 400)
        $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        # Fill control first: WinForms docks the last-added control first, so the panels added
        # after this take their edges and the grid gets what is left.
        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
        $grid.ReadOnly = $true
        $grid.AllowUserToAddRows = $false
        $grid.AllowUserToDeleteRows = $false
        $grid.AllowUserToResizeRows = $false
        $grid.RowHeadersVisible = $false
        $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
        $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells
        $grid.ClipboardCopyMode = [System.Windows.Forms.DataGridViewClipboardCopyMode]::EnableWithAutoHeaderText
        $grid.DataSource = $table
        $form.Controls.Add($grid)

        $top = New-Object System.Windows.Forms.Panel
        $top.Dock = [System.Windows.Forms.DockStyle]::Top
        $top.Height = 84
        $form.Controls.Add($top)

        $lblSummary = New-Object System.Windows.Forms.Label
        $lblSummary.Location = New-Object System.Drawing.Point(10, 8)
        $lblSummary.AutoSize = $true
        $lblSummary.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
        $lblSummary.Text = "$total Windows VM(s) with no CPU usage and no VMware Tools IP"
        $top.Controls.Add($lblSummary)

        $lblDetail = New-Object System.Windows.Forms.Label
        $lblDetail.Location = New-Object System.Drawing.Point(10, 32)
        $lblDetail.AutoSize = $true
        $lblDetail.Text = $Summary
        if ($FailedTarget.Count -gt 0) {
            $lblDetail.Text = "$Summary    NOT INCLUDED - could not be queried: $($FailedTarget -join ', ')"
            $lblDetail.ForeColor = [System.Drawing.Color]::Firebrick
        }
        $top.Controls.Add($lblDetail)

        $lblFilter = New-Object System.Windows.Forms.Label
        $lblFilter.Text = 'Filter:'
        $lblFilter.Location = New-Object System.Drawing.Point(10, 58)
        $lblFilter.AutoSize = $true
        $top.Controls.Add($lblFilter)

        $txtFilter = New-Object System.Windows.Forms.TextBox
        $txtFilter.Location = New-Object System.Drawing.Point(56, 55)
        $txtFilter.Size = New-Object System.Drawing.Size(300, 24)
        $top.Controls.Add($txtFilter)

        $lblCount = New-Object System.Windows.Forms.Label
        $lblCount.Location = New-Object System.Drawing.Point(366, 58)
        $lblCount.AutoSize = $true
        $lblCount.Text = "Showing $total of $total. Click a column header to sort; Ctrl+C copies selected rows."
        $top.Controls.Add($lblCount)

        $txtFilter.Add_TextChanged({
                $table.DefaultView.RowFilter = Get-ReportRowFilter -Text $txtFilter.Text -Column $textColumns
                $lblCount.Text = "Showing $($table.DefaultView.Count) of $total. Click a column header to sort; Ctrl+C copies selected rows."
            })

        $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
        $bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
        $bottom.Height = 44
        $bottom.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
        $bottom.Padding = New-Object System.Windows.Forms.Padding(6)
        $form.Controls.Add($bottom)

        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = 'Close'
        $btnClose.Size = New-Object System.Drawing.Size(100, 28)
        $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $bottom.Controls.Add($btnClose)

        $btnSaveAs = New-Object System.Windows.Forms.Button
        $btnSaveAs.Text = 'Save copy as...'
        $btnSaveAs.Size = New-Object System.Drawing.Size(120, 28)
        $btnSaveAs.Enabled = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)
        $btnSaveAs.Add_Click({
                $dialog = New-Object System.Windows.Forms.SaveFileDialog
                try {
                    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
                    $dialog.DefaultExt = 'csv'
                    $dialog.FileName = [System.IO.Path]::GetFileName($CsvPath)
                    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                        Copy-Item -LiteralPath $CsvPath -Destination $dialog.FileName -Force
                    }
                }
                catch {
                    [void][System.Windows.Forms.MessageBox]::Show($form, "Could not save the copy: $($_.Exception.Message)", $form.Text,
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                }
                finally {
                    $dialog.Dispose()
                }
            })
        $bottom.Controls.Add($btnSaveAs)

        $btnOpen = New-Object System.Windows.Forms.Button
        $btnOpen.Text = 'Open CSV'
        $btnOpen.Size = New-Object System.Drawing.Size(100, 28)
        $btnOpen.Add_Click({
                try { Invoke-Item -LiteralPath $CsvPath }
                catch {
                    [void][System.Windows.Forms.MessageBox]::Show($form, "Could not open the CSV: $($_.Exception.Message)", $form.Text,
                        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                }
            })
        $bottom.Controls.Add($btnOpen)

        $lblCsv = New-Object System.Windows.Forms.Label
        $lblCsv.AutoSize = $true
        $lblCsv.Margin = New-Object System.Windows.Forms.Padding(3, 9, 12, 3)
        $lblCsv.Text = "CSV saved to: $CsvPath"
        $bottom.Controls.Add($lblCsv)

        $form.CancelButton = $btnClose
        $form.ActiveControl = $txtFilter
        [void]$form.ShowDialog()
    }
    finally {
        $form.Dispose()
        $table.Dispose()
    }
}

function Show-MessageBox {
    <#
    .SYNOPSIS
        Shows a message box. Used only when the window was shown.

    .PARAMETER Text
        Message body.

    .PARAMETER Icon
        MessageBoxIcon name, e.g. 'Information', 'Warning', 'Error'.

    .EXAMPLE
        Show-MessageBox -Text 'Failed' -Icon Error
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Icon = 'Information'
    )

    [void][System.Windows.Forms.MessageBox]::Show($Text, 'Windows VMs - no CPU / no IP report',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

#endregion Helpers

if ($standalone) {
    #region Standalone fallbacks - used only when this file runs outside the repo.
    # Same behaviour as the Richo.Common functions of the same names, cut down to what this
    # script uses. Inside the repo the module's versions are loaded instead.

    function Write-RichoLog {
        <#
        .SYNOPSIS
            Writes a timestamped, levelled log line (standalone copy of the Richo.Common function).

        .PARAMETER Message
            The text to log.

        .PARAMETER Level
            DEBUG, INFO, WARN or ERROR.

        .PARAMETER Path
            Optional log file to append to. Defaults to $env:RICHO_LOG_FILE when set.

        .EXAMPLE
            Write-RichoLog 'Connecting' -Level INFO
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
            [AllowEmptyString()]
            [string]$Message,

            [Parameter(Position = 1)]
            [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
            [string]$Level = 'INFO',

            [string]$Path = $env:RICHO_LOG_FILE
        )

        process {
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
            $line = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message
            switch ($Level) {
                'DEBUG' { Write-Verbose $line }
                'INFO' { Write-Information $line -InformationAction Continue }
                'WARN' { Write-Warning $line }
                'ERROR' { Write-Error $line }
            }
            if ($Path) {
                $dir = Split-Path -Path $Path -Parent
                if ($dir -and (-not (Test-Path $dir))) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
                Add-Content -Path $Path -Value $line -Encoding UTF8
            }
        }
    }

    function Get-RichoCredential {
        <#
        .SYNOPSIS
            Resolves a credential without hardcoding secrets (standalone copy of the Richo.Common function).

        .DESCRIPTION
            SecretManagement (Get-Secret -Name), then RICHO_<NAME>_USER / RICHO_<NAME>_PASSWORD
            environment variables, then an interactive prompt.

        .PARAMETER Name
            Credential name - a site's credentialName, or the vCenter name for a typed vCenter.

        .EXAMPLE
            $cred = Get-RichoCredential -Name 'vcenter01.example.com'
        #>
        [CmdletBinding()]
        [OutputType([pscredential])]
        param(
            [Parameter(Mandatory, Position = 0)]
            [ValidateNotNullOrEmpty()]
            [string]$Name
        )

        if (Get-Command -Name 'Get-Secret' -ErrorAction SilentlyContinue) {
            $secret = Get-Secret -Name $Name -ErrorAction SilentlyContinue
            if ($secret -is [pscredential]) { return $secret }
        }

        $slug = ($Name -replace '[^A-Za-z0-9]', '_').ToUpperInvariant()
        $user = [Environment]::GetEnvironmentVariable("RICHO_${slug}_USER")
        $pass = [Environment]::GetEnvironmentVariable("RICHO_${slug}_PASSWORD")
        if ($user -and $pass) {
            return [pscredential]::new($user, (ConvertTo-SecureString $pass -AsPlainText -Force))
        }

        Get-Credential -Message "Credentials for '$Name'"
    }

    function Start-RichoTranscript {
        <#
        .SYNOPSIS
            Starts a transcript in logs/ next to this script and returns its path (standalone version).

        .EXAMPLE
            $transcript = Start-RichoTranscript
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param()

        $logDir = Join-Path -Path $baseDir -ChildPath 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
        $stem = 'Export-WindowsVmNoCpuNoIpReport_{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
        $path = Join-Path -Path $logDir -ChildPath "$stem.transcript"
        $env:RICHO_LOG_FILE = Join-Path -Path $logDir -ChildPath "$stem.log"
        Start-Transcript -Path $path | Out-Null
        return $path
    }

    #endregion Standalone fallbacks
}
else {
    Import-RequiredModules -Module ([ordered]@{ 'Richo.Common' = $richoCommonPath })
}

if (-not $ConfigPath) {
    $ConfigPath = if ($env:RICHO_CONFIG) {
        $env:RICHO_CONFIG
    }
    elseif ($standalone) {
        Join-Path -Path $baseDir -ChildPath 'environments.json'
    }
    else {
        Join-Path -Path $baseDir -ChildPath 'config/environments.json'
    }
}
$defaultOutputPath = Join-Path -Path $baseDir -ChildPath ('output/WindowsVmNoCpuNoIp_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$interactive = -not ($PSBoundParameters.ContainsKey('Site') -or $PSBoundParameters.ContainsKey('VCenter'))
$transcriptPath = $null
$connected = New-Object System.Collections.Generic.List[object]

try {
    # ---- Choose vCenters ------------------------------------------------------
    # The config file is optional: a typed vCenter needs no entry in it.
    $siteList = @(Get-SiteList -Path $ConfigPath -AllowMissing)

    if ($interactive) {
        if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
            throw 'The window needs Windows. Pass -VCenter or -Site to run without it.'
        }

        $formArgs = @{
            SiteList          = $siteList
            DefaultOutputPath = $defaultOutputPath
            IncludePoweredOff = $IncludePoweredOff.IsPresent
            CpuThresholdMhz   = $CpuThresholdMhz
        }
        $choice = Show-SiteSelectionForm @formArgs
        if ($null -eq $choice) {
            Write-RichoLog 'Cancelled. Nothing was queried.'
            return
        }

        $siteNames = @($choice.Sites | ForEach-Object { $_.Name })
        $vcNames = @($choice.VCenters)
        $outputFile = $choice.OutputPath
        $includeOff = [bool]$choice.IncludePoweredOff
        $threshold = [int]$choice.CpuThresholdMhz
    }
    else {
        $siteNames = @(ConvertTo-NameList -Value $Site)
        $vcNames = @(ConvertTo-NameList -Value $VCenter)
        if (($siteNames.Count -eq 0) -and ($vcNames.Count -eq 0)) { throw '-Site / -VCenter was given but names nothing to query.' }
        $outputFile = if ($OutputPath) { $OutputPath } else { $defaultOutputPath }
        $includeOff = $IncludePoweredOff.IsPresent
        $threshold = $CpuThresholdMhz
    }

    $targets = @(Resolve-ReportTarget -SiteList $siteList -SiteName $siteNames -VCenter $vcNames)
    $outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outputFile)

    if ($Transcript) { $transcriptPath = Start-RichoTranscript }

    $offText = if ($includeOff) { 'included' } else { 'excluded' }
    $settingsText = 'CPU <= {0} MHz; powered-off VMs {1}' -f $threshold, $offText
    $targetText = (@($targets | ForEach-Object { if ($_.Server -and ($_.Label -ne $_.Server)) { '{0} ({1})' -f $_.Label, $_.Server } else { $_.Label } }) -join ', ')
    Write-RichoLog ('Export-WindowsVmNoCpuNoIpReport {0}: {1}; {2}.' -f $ScriptVersion, $targetText, $settingsText)

    # Loaded after the window so it opens straight away; PowerCLI is slow to load.
    Import-RequiredModules -Module ([ordered]@{ 'VMware.VimAutomation.Core' = 'VMware.VimAutomation.Core' })

    # ---- Query each vCenter ---------------------------------------------------
    $report = New-Object System.Collections.Generic.List[object]
    $failedTargets = New-Object System.Collections.Generic.List[string]
    $credentialCache = @{}

    foreach ($target in $targets) {
        if ($target.Problem) {
            $failedTargets.Add($target.Label)
            Write-RichoLog "[$($target.Label)] Skipped: $($target.Problem)" -Level WARN
            continue
        }
        try {
            # vCenters that share a credential name are only asked for it once.
            if (-not $credentialCache.ContainsKey($target.CredentialName)) {
                $credentialCache[$target.CredentialName] = Get-RichoCredential -Name $target.CredentialName
            }

            Write-RichoLog "[$($target.Label)] Connecting to $($target.Server)."
            $vc = Connect-VIServer -Server $target.Server -Credential $credentialCache[$target.CredentialName] -ErrorAction Stop
            $connected.Add($vc)

            $rows = @(Get-WindowsVmNoCpuNoIp -Server $vc -SiteName $target.Label -IncludePoweredOff:$includeOff -CpuThresholdMhz $threshold)
            foreach ($row in $rows) { $report.Add($row) }
        }
        catch {
            # One unreachable vCenter should not cost the others their results.
            $failedTargets.Add($target.Label)
            Write-RichoLog "[$($target.Label)] Skipped: $($_.Exception.Message)" -Level WARN
        }
    }

    # Everything needed is in memory now. Disconnect before the results window opens, so no
    # vCenter session sits open for as long as someone keeps that window up.
    foreach ($vc in $connected) {
        Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
    }
    $connected.Clear()

    if ($failedTargets.Count -eq $targets.Count) {
        throw "No vCenter could be queried ($($failedTargets -join ', ')). No CSV was written."
    }

    # ---- Export ---------------------------------------------------------------
    $outputDir = Split-Path -Path $outputFile -Parent
    if ($outputDir -and (-not (Test-Path -LiteralPath $outputDir))) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }

    $sorted = @($report.ToArray() | Sort-Object -Property Site, Server)
    if ($sorted.Count -gt 0) {
        $sorted | Select-Object -Property $reportColumns |
            Export-Csv -LiteralPath $outputFile -NoTypeInformation -Encoding UTF8
    }
    else {
        # Export-Csv writes nothing for an empty set; keep a header-only file so the run still
        # leaves a record that it happened and found nothing.
        Set-Content -LiteralPath $outputFile -Encoding UTF8 -Value (($reportColumns | ForEach-Object { '"{0}"' -f $_ }) -join ',')
    }

    Write-RichoLog "$($sorted.Count) VM(s) written to $outputFile."
    if ($failedTargets.Count -gt 0) {
        Write-RichoLog "Not included - could not be queried: $($failedTargets -join ', ')." -Level WARN
    }

    # ---- Show -----------------------------------------------------------------
    if ($interactive) {
        $resultArgs = @{
            Row          = $sorted
            Column       = $reportColumns
            CsvPath      = $outputFile
            Summary      = "vCenter: $targetText    |    $settingsText"
            FailedTarget = $failedTargets.ToArray()
        }
        Show-ResultsForm @resultArgs
    }

    if ($PassThru) { $sorted }
}
catch {
    if ($interactive) {
        # Best effort: the window may never have loaded (e.g. failure before it opened).
        try { Show-MessageBox -Text "Failed: $($_.Exception.Message)" -Icon Error } catch { Write-RichoLog "Could not show the error dialog: $($_.Exception.Message)" -Level DEBUG }
    }
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    # Safety net for an early exit: only the sessions this run opened, anything else connected in
    # this console is left alone.
    foreach ($vc in $connected) {
        Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}
