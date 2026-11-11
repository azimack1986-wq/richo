<#
.SYNOPSIS
    Finds Windows VMs with zero CPU usage and no VMware Tools IP address, and exports them to CSV.

.DESCRIPTION
    Opens a small window to pick one or more sites (the vCenter entries in
    config/environments.json), then for every VM in each selected vCenter checks:

      1. Windows    - the configured guest OS (Config.GuestId starts with "win", or
                      Config.GuestFullName contains "Windows"). The configured value is used
                      because a VM with no Tools heartbeat reports no guest family at all. The
                      Tools-reported family (windowsGuest) also counts when it is present.
      2. CPU zero   - Summary.QuickStats.OverallCpuUsage (MHz) is at or below -CpuThresholdMhz,
                      which defaults to 0. This is CPU *usage*, not the vCPU count.
      3. No IP      - VMware Tools reports no IP address, neither Guest.IpAddress nor any
                      address on Guest.Net.

    A VM is reported only when all three are true. Templates are skipped. Powered-off and
    suspended VMs are skipped unless -IncludePoweredOff is given (or ticked in the window),
    because they always have zero CPU and no IP and would bury the VMs worth looking at.

    The CSV holds Server (VM name), Datastore, and VM Folder, plus the datacenter, cluster,
    host, guest OS, vCPU count, CPU usage and Tools status, so each row can be judged
    without going back to vCenter.

    READ ONLY against vCenter. The only thing written is the CSV (and, with -Transcript, a
    transcript under logs/). Each vCenter connection this script opens is closed again at the
    end; existing PowerCLI sessions in the same console are left alone.

    Requires VMware.VimAutomation.Core (PowerCLI). The site picker needs Windows; pass -Site to
    run without it, for example from a scheduled task.

.PARAMETER Site
    One or more environment keys from config/environments.json. When given, the window is not
    shown and the script runs unattended with the other parameters as passed.

.PARAMETER OutputPath
    CSV to write. Defaults to output/WindowsVmNoCpuNoIp_<timestamp>.csv at the repo root
    (output/ is gitignored).

.PARAMETER IncludePoweredOff
    Also report powered-off and suspended Windows VMs. Off by default.

.PARAMETER CpuThresholdMhz
    Treat CPU usage at or below this many MHz as zero. Defaults to 0, meaning exactly zero.

.PARAMETER ConfigPath
    Override the environments file. Defaults to $env:RICHO_CONFIG when set, otherwise
    config/environments.json at the repo root.

.PARAMETER PassThru
    Also write the report rows to the pipeline.

.PARAMETER Transcript
    Record a transcript under logs/.

.EXAMPLE
    .\Export-WindowsVmNoCpuNoIpReport.ps1

    Opens the site picker, runs the report against the chosen sites, writes the CSV and offers
    to open it.

.EXAMPLE
    .\Export-WindowsVmNoCpuNoIpReport.ps1 -Site prod, dr -OutputPath D:\Reports\win-no-ip.csv

    No window. Queries the prod and dr vCenters and writes the CSV to the given path.

.EXAMPLE
    .\Export-WindowsVmNoCpuNoIpReport.ps1 -Site lab -CpuThresholdMhz 20 -PassThru | Format-Table Server, Host, CpuUsageMhz

    Treats anything at or below 20 MHz as zero and shows the matches in the console too.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
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

$ScriptVersion = '1.0.0'
$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

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

    .EXAMPLE
        Get-SiteList -Path .\config\environments.json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path. Copy config/environments.example.json to config/environments.json and fill it in."
    }

    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $environments = Get-SafeProperty -InputObject $raw -Path 'environments'
    if ($null -eq $environments) { throw "'$Path' has no 'environments' section." }
    $default = [string](Get-SafeProperty -InputObject $raw -Path 'default')

    foreach ($entry in $environments.PSObject.Properties) {
        $server = [string](Get-SafeProperty -InputObject $entry.Value -Path 'vcenter.server')
        if ([string]::IsNullOrWhiteSpace($server)) { continue }
        [pscustomobject]@{
            Name        = $entry.Name
            Server      = $server
            Description = [string](Get-SafeProperty -InputObject $entry.Value -Path 'description')
            IsDefault   = ($entry.Name -eq $default)
        }
    }
}

function Show-SiteSelectionForm {
    <#
    .SYNOPSIS
        Shows the site picker. Returns the choices, or $null when cancelled.

    .PARAMETER SiteList
        Sites from Get-SiteList.

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
        $form.ClientSize = New-Object System.Drawing.Size(540, 440)
        $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

        $lblSites = New-Object System.Windows.Forms.Label
        $lblSites.Text = 'Select one or more sites (vCenter):'
        $lblSites.Location = New-Object System.Drawing.Point(12, 12)
        $lblSites.AutoSize = $true
        $form.Controls.Add($lblSites)

        $clbSites = New-Object System.Windows.Forms.CheckedListBox
        $clbSites.Location = New-Object System.Drawing.Point(12, 34)
        $clbSites.Size = New-Object System.Drawing.Size(516, 160)
        $clbSites.CheckOnClick = $true
        $clbSites.IntegralHeight = $false
        foreach ($entry in $SiteList) {
            $label = '{0}  -  {1}' -f $entry.Name, $entry.Server
            if (-not [string]::IsNullOrWhiteSpace($entry.Description)) { $label += "  ($($entry.Description))" }
            $index = $clbSites.Items.Add($label)
            if ($entry.IsDefault) { $clbSites.SetItemChecked($index, $true) }
        }
        $form.Controls.Add($clbSites)

        $chkAll = New-Object System.Windows.Forms.CheckBox
        $chkAll.Text = 'Select all sites'
        $chkAll.Location = New-Object System.Drawing.Point(12, 200)
        $chkAll.AutoSize = $true
        $chkAll.Add_CheckedChanged({
                for ($i = 0; $i -lt $clbSites.Items.Count; $i++) { $clbSites.SetItemChecked($i, $chkAll.Checked) }
            })
        $form.Controls.Add($chkAll)

        $chkPoweredOff = New-Object System.Windows.Forms.CheckBox
        $chkPoweredOff.Text = 'Include powered-off / suspended VMs (they always have no CPU and no IP)'
        $chkPoweredOff.Location = New-Object System.Drawing.Point(12, 230)
        $chkPoweredOff.AutoSize = $true
        $chkPoweredOff.Checked = $IncludePoweredOff
        $form.Controls.Add($chkPoweredOff)

        $lblCpu = New-Object System.Windows.Forms.Label
        $lblCpu.Text = 'Treat CPU usage at or below this many MHz as zero:'
        $lblCpu.Location = New-Object System.Drawing.Point(12, 264)
        $lblCpu.AutoSize = $true
        $form.Controls.Add($lblCpu)

        $numCpu = New-Object System.Windows.Forms.NumericUpDown
        $numCpu.Location = New-Object System.Drawing.Point(340, 261)
        $numCpu.Size = New-Object System.Drawing.Size(90, 24)
        $numCpu.Minimum = 0
        $numCpu.Maximum = 1000000
        $numCpu.Value = $CpuThresholdMhz
        $form.Controls.Add($numCpu)

        $lblOut = New-Object System.Windows.Forms.Label
        $lblOut.Text = 'Save CSV to:'
        $lblOut.Location = New-Object System.Drawing.Point(12, 298)
        $lblOut.AutoSize = $true
        $form.Controls.Add($lblOut)

        $txtOut = New-Object System.Windows.Forms.TextBox
        $txtOut.Location = New-Object System.Drawing.Point(12, 318)
        $txtOut.Size = New-Object System.Drawing.Size(420, 24)
        $txtOut.Text = $DefaultOutputPath
        $form.Controls.Add($txtOut)

        $btnBrowse = New-Object System.Windows.Forms.Button
        $btnBrowse.Text = 'Browse...'
        $btnBrowse.Location = New-Object System.Drawing.Point(440, 316)
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
        $lblCriteria.Text = 'Reports VMs that are Windows (configured guest OS) AND show CPU usage at or below the threshold AND have no IP address reported by VMware Tools. Read only - nothing in vCenter is changed.'
        $lblCriteria.Location = New-Object System.Drawing.Point(12, 352)
        $lblCriteria.Size = New-Object System.Drawing.Size(516, 40)
        $lblCriteria.ForeColor = [System.Drawing.SystemColors]::GrayText
        $form.Controls.Add($lblCriteria)

        $btnRun = New-Object System.Windows.Forms.Button
        $btnRun.Text = 'Run report'
        $btnRun.Location = New-Object System.Drawing.Point(340, 400)
        $btnRun.Size = New-Object System.Drawing.Size(90, 28)
        $btnRun.Add_Click({
                if ($clbSites.CheckedIndices.Count -eq 0) {
                    [void][System.Windows.Forms.MessageBox]::Show($form, 'Select at least one site.', $form.Text,
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
        $btnCancel.Location = New-Object System.Drawing.Point(438, 400)
        $btnCancel.Size = New-Object System.Drawing.Size(90, 28)
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($btnCancel)

        $form.AcceptButton = $btnRun
        $form.CancelButton = $btnCancel

        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

        $selected = New-Object System.Collections.Generic.List[object]
        foreach ($index in $clbSites.CheckedIndices) { $selected.Add($SiteList[$index]) }

        return [pscustomobject]@{
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

function Show-MessageBox {
    <#
    .SYNOPSIS
        Shows a message box and returns the button pressed. Used only when the window was shown.

    .PARAMETER Text
        Message body.

    .PARAMETER Buttons
        MessageBoxButtons name, e.g. 'OK' or 'YesNo'.

    .PARAMETER Icon
        MessageBoxIcon name, e.g. 'Information', 'Warning', 'Error'.

    .EXAMPLE
        Show-MessageBox -Text 'Done' -Buttons OK -Icon Information
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [ValidateSet('OK', 'YesNo')]
        [string]$Buttons = 'OK',

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Icon = 'Information'
    )

    return [System.Windows.Forms.MessageBox]::Show($Text, 'Windows VMs - no CPU / no IP report',
        [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

#endregion Helpers

Import-RequiredModules -Module ([ordered]@{
        'Richo.Common' = (Join-Path -Path $repoRoot -ChildPath 'modules/Richo.Common/Richo.Common.psd1')
    })

if (-not $ConfigPath) {
    $ConfigPath = if ($env:RICHO_CONFIG) { $env:RICHO_CONFIG } else { Join-Path -Path $repoRoot -ChildPath 'config/environments.json' }
}
$defaultOutputPath = Join-Path -Path $repoRoot -ChildPath ('output/WindowsVmNoCpuNoIp_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$interactive = -not $PSBoundParameters.ContainsKey('Site')
$transcriptPath = $null
$connected = New-Object System.Collections.Generic.List[object]

try {
    # ---- Choose sites -------------------------------------------------------
    if ($interactive) {
        if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
            throw 'The site picker needs Windows. Pass -Site to run without it.'
        }
        $siteList = @(Get-SiteList -Path $ConfigPath)
        if ($siteList.Count -eq 0) { throw "No environment in '$ConfigPath' has a vcenter.server entry." }

        $formArgs = @{
            SiteList          = $siteList
            DefaultOutputPath = $defaultOutputPath
            IncludePoweredOff = $IncludePoweredOff.IsPresent
            CpuThresholdMhz   = $CpuThresholdMhz
        }
        $choice = Show-SiteSelectionForm @formArgs
        if ($null -eq $choice) {
            Write-RichoLog 'Cancelled at the site picker. Nothing was queried.'
            return
        }

        $selectedSites = @($choice.Sites | ForEach-Object { $_.Name })
        $outputFile = $choice.OutputPath
        $includeOff = [bool]$choice.IncludePoweredOff
        $threshold = [int]$choice.CpuThresholdMhz
    }
    else {
        # 'pwsh -File' / 'powershell.exe -File' (e.g. a scheduled task) passes "-Site a,b" as one
        # string, so split on commas as well as accepting a real array.
        $selectedSites = @($Site | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($selectedSites.Count -eq 0) { throw '-Site was given but names no environment.' }
        $outputFile = if ($OutputPath) { $OutputPath } else { $defaultOutputPath }
        $includeOff = $IncludePoweredOff.IsPresent
        $threshold = $CpuThresholdMhz
    }

    $outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outputFile)

    if ($Transcript) { $transcriptPath = Start-RichoTranscript }

    $offText = if ($includeOff) { 'included' } else { 'excluded' }
    Write-RichoLog ('Export-WindowsVmNoCpuNoIpReport {0}: sites {1}; CPU <= {2} MHz; powered-off VMs {3}.' -f $ScriptVersion, ($selectedSites -join ', '), $threshold, $offText)

    # Loaded after the window so the picker opens straight away; PowerCLI is slow to load.
    Import-RequiredModules -Module ([ordered]@{ 'VMware.VimAutomation.Core' = 'VMware.VimAutomation.Core' })

    # ---- Query each site ----------------------------------------------------
    $report = New-Object System.Collections.Generic.List[object]
    $failedSites = New-Object System.Collections.Generic.List[string]
    $credentialCache = @{}

    foreach ($siteName in $selectedSites) {
        try {
            $siteConfig = Get-RichoConfig -Name $siteName -Path $ConfigPath
            $vcServer = [string]$siteConfig.vcenter.server
            $credentialName = [string]$siteConfig.vcenter.credentialName

            # Sites that share a credential name are only asked for it once.
            if (-not $credentialCache.ContainsKey($credentialName)) {
                $credentialCache[$credentialName] = Get-RichoCredential -Name $credentialName
            }

            Write-RichoLog "[$siteName] Connecting to $vcServer."
            $vc = Connect-VIServer -Server $vcServer -Credential $credentialCache[$credentialName] -ErrorAction Stop
            $connected.Add($vc)

            $rows = @(Get-WindowsVmNoCpuNoIp -Server $vc -SiteName $siteName -IncludePoweredOff:$includeOff -CpuThresholdMhz $threshold)
            foreach ($row in $rows) { $report.Add($row) }
        }
        catch {
            # One unreachable vCenter should not cost the other sites their results.
            $failedSites.Add($siteName)
            Write-RichoLog "[$siteName] Skipped: $($_.Exception.Message)" -Level WARN
        }
    }

    if ($failedSites.Count -eq $selectedSites.Count) {
        throw "No site could be queried ($($failedSites -join ', ')). No CSV was written."
    }

    # ---- Export -------------------------------------------------------------
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
    if ($failedSites.Count -gt 0) {
        Write-RichoLog "Not included - could not be queried: $($failedSites -join ', ')." -Level WARN
    }

    if ($interactive) {
        $message = "$($sorted.Count) Windows VM(s) with no CPU and no VMware Tools IP.`n`nSaved to:`n$outputFile"
        if ($failedSites.Count -gt 0) { $message += "`n`nNOT included - could not be queried: $($failedSites -join ', ')" }
        $message += "`n`nOpen the CSV now?"
        $icon = if ($failedSites.Count -gt 0) { 'Warning' } else { 'Information' }
        if ((Show-MessageBox -Text $message -Buttons YesNo -Icon $icon) -eq [System.Windows.Forms.DialogResult]::Yes) {
            Invoke-Item -LiteralPath $outputFile
        }
    }

    if ($PassThru) { $sorted }
}
catch {
    if ($interactive) {
        # Best effort: the window may never have loaded (e.g. failure before the picker opened).
        try { [void](Show-MessageBox -Text "Failed: $($_.Exception.Message)" -Icon Error) } catch { Write-RichoLog "Could not show the error dialog: $($_.Exception.Message)" -Level DEBUG }
    }
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    # Only the sessions this run opened; anything else connected in this console is left alone.
    foreach ($vc in $connected) {
        Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}
