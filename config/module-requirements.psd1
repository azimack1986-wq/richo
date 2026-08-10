@{
    # Single source of truth for the PowerShell modules this repo depends on, and the exact
    # versions it is known to work with.
    #
    # Pinning matters here. Intersight.PowerShell 1.0.11.2025021903 authenticates correctly
    # against the PVA at siepd85csp1000 but cannot deserialize its responses - a client/appliance
    # schema mismatch that presents as a credential error. Whichever version is proven against
    # your appliance, record it here so every jump host runs the same one.
    #
    # Fetch with:   tools/Save-RichoModuleBundle.ps1   (on a machine with gallery access)
    # Load with:    tools/Import-RichoModuleBundle.ps1 (on the jump host, no admin rights needed)

    BundlePath = 'modules/vendor'

    Modules = @(
        @{
            Name        = 'Intersight.PowerShell'
            Version     = '1.0.11.17'
            Required    = 'Intersight'
            Notes       = 'Binary module, PowerShell 7 (Core) only. Version must match the appliance Intersight release - see the PVA release notes. Large: check the size before committing.'
        },
        @{
            Name        = 'VMware.PowerCLI'
            Version     = '13.3.0.24145081'
            Required    = 'Always'
            Notes       = 'Meta-module pulling in VMware.VimAutomation.*. Very large. Only VimAutomation.Core and VimAutomation.Vds are actually used, so consider saving those instead if size is a problem.'
        },
        @{
            Name        = 'Cisco.UCSManager'
            Version     = '3.0.1.2'
            Required    = 'UCSM'
            Notes       = 'UCS PowerTool for UCS Manager (classic). Only needed when a host is UCSM-managed.'
        }
    )
}
