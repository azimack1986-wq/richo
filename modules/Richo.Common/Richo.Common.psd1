@{
    RootModule        = 'Richo.Common.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a3f1c7d2-5b48-4e91-9c30-6d2e8f7b1a04'
    Author            = 'richo maintainers'
    Description       = 'Shared helpers for the richo infrastructure automation scripts: logging, config loading, and dependency checks.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Write-RichoLog',
        'Get-RichoConfig',
        'Get-RichoCredential',
        'Assert-RichoModule',
        'Start-RichoTranscript'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('VMware', 'Intersight', 'UCS', 'SRM', 'Automation')
        }
    }
}
