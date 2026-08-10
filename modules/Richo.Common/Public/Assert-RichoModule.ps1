function Assert-RichoModule {
    <#
    .SYNOPSIS
        Verifies required modules are installed, and fails with an actionable message.

    .DESCRIPTION
        Scripts here depend on large vendor modules (VMware.PowerCLI,
        Intersight.PowerShell, Cisco.UCS.Core, VMware.Sdk.Srm) that are not
        installed by default. Call this at the top of a script so a missing
        dependency fails immediately with the install command, rather than
        halfway through as a confusing "term not recognized" error.

    .PARAMETER Name
        One or more module names to require.

    .PARAMETER MinimumVersion
        Optional minimum version. Only meaningful with a single -Name.

    .PARAMETER Import
        Import each module after the check. Off by default -- importing
        VMware.PowerCLI is slow, and most callers only need a submodule.

    .EXAMPLE
        Assert-RichoModule -Name Intersight.PowerShell -MinimumVersion 1.0.11

    .EXAMPLE
        Assert-RichoModule -Name VMware.VimAutomation.Core, VMware.Sdk.Srm -Import
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name,

        [version]$MinimumVersion,

        [switch]$Import
    )

    if ($MinimumVersion -and $Name.Count -gt 1) {
        throw '-MinimumVersion applies to a single module; call Assert-RichoModule once per module instead.'
    }

    foreach ($moduleName in $Name) {
        $found = Get-Module -Name $moduleName -ListAvailable |
            Sort-Object Version -Descending |
            Select-Object -First 1

        if (-not $found) {
            throw "Required module '$moduleName' is not installed. Install it with: Install-Module -Name $moduleName -Scope CurrentUser"
        }

        if ($MinimumVersion -and $found.Version -lt $MinimumVersion) {
            throw "Module '$moduleName' is version $($found.Version) but $MinimumVersion or newer is required. Update it with: Update-Module -Name $moduleName"
        }

        Write-RichoLog "Module '$moduleName' $($found.Version) available." -Level DEBUG

        if ($Import) {
            Import-Module -Name $moduleName -ErrorAction Stop
        }
    }
}
