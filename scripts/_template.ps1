<#
.SYNOPSIS
    One-line description of what this script does.

.DESCRIPTION
    Longer description. State what it changes, what it only reads, and any
    prerequisites (module versions, network access, required privileges).

    Copy this file to the right scripts/ subfolder and rename it Verb-Noun.ps1
    using an approved PowerShell verb (Get-Verb).

.PARAMETER Environment
    Environment key from config/environments.json. Defaults to the file's
    "default" entry.

.EXAMPLE
    .\Verb-Noun.ps1 -Environment lab -WhatIf

.EXAMPLE
    .\Verb-Noun.ps1 -Environment prod -Confirm
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Environment,

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Relative path assumes this script lives in scripts/<platform>/. Adjust if it
# sits at another depth.
Import-Module (Join-Path $PSScriptRoot '..\..\modules\Richo.Common\Richo.Common.psd1') -Force

# Fail fast on missing dependencies rather than midway through the run.
# Assert-RichoModule -Name VMware.VimAutomation.Core

$transcriptPath = if ($Transcript) { Start-RichoTranscript } else { $null }

try {
    $config = Get-RichoConfig -Name $Environment
    Write-RichoLog "Targeting environment '$($config.Name)'." -Level INFO

    # ---- Connect ----------------------------------------------------------
    # $cred = Get-RichoCredential -Name $config.vcenter.credentialName
    # Connect-VIServer -Server $config.vcenter.server -Credential $cred | Out-Null

    # ---- Read current state ----------------------------------------------
    # Gather and log what you are about to act on, before acting on it.

    # ---- Change ----------------------------------------------------------
    # Guard every mutating call with ShouldProcess so -WhatIf works for free.
    #
    # foreach ($vm in $targets) {
    #     if ($PSCmdlet.ShouldProcess($vm.Name, 'Set memory to 16 GB')) {
    #         Set-VM -VM $vm -MemoryGB 16 -Confirm:$false
    #         Write-RichoLog "Resized $($vm.Name) to 16 GB." -Level INFO
    #     }
    # }

    Write-RichoLog 'Completed successfully.' -Level INFO
}
catch {
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    # Disconnect-VIServer -Server * -Confirm:$false -ErrorAction SilentlyContinue
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}
