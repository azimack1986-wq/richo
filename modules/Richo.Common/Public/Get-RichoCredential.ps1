function Get-RichoCredential {
    <#
    .SYNOPSIS
        Resolves a PSCredential for a named target without hardcoding secrets.

    .DESCRIPTION
        Resolution order:

          1. SecretManagement -- Get-Secret -Name $Name, if the module is present.
          2. Environment variables -- RICHO_<NAME>_USER / RICHO_<NAME>_PASSWORD,
             with the name upper-cased and non-alphanumerics replaced by '_'.
             Suits CI and scheduled runs.
          3. Interactive prompt, unless -NoPrompt is given.

        Nothing here reads a plaintext file, and nothing is ever written back to
        disk. If you need unattended auth, prefer SecretManagement.

    .PARAMETER Name
        Logical credential name, e.g. 'vcenter-prod' or 'ucsm-lab'.

    .PARAMETER NoPrompt
        Throw instead of prompting when no stored credential is found. Use this
        in scheduled or CI runs so they fail loudly rather than hanging.

    .EXAMPLE
        $cred = Get-RichoCredential -Name 'vcenter-prod'
        Connect-VIServer -Server $vc -Credential $cred
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [switch]$NoPrompt
    )

    if (Get-Command -Name 'Get-Secret' -ErrorAction SilentlyContinue) {
        $secret = Get-Secret -Name $Name -ErrorAction SilentlyContinue
        if ($secret -is [pscredential]) {
            Write-RichoLog "Resolved credential '$Name' from SecretManagement." -Level DEBUG
            return $secret
        }
    }

    $slug = ($Name -replace '[^A-Za-z0-9]', '_').ToUpperInvariant()
    $user = [Environment]::GetEnvironmentVariable("RICHO_${slug}_USER")
    $pass = [Environment]::GetEnvironmentVariable("RICHO_${slug}_PASSWORD")

    if ($user -and $pass) {
        Write-RichoLog "Resolved credential '$Name' from environment variables." -Level DEBUG
        return [pscredential]::new($user, (ConvertTo-SecureString $pass -AsPlainText -Force))
    }

    if ($NoPrompt) {
        throw "No credential found for '$Name'. Store it with Set-Secret -Name '$Name', or set RICHO_${slug}_USER and RICHO_${slug}_PASSWORD."
    }

    Write-RichoLog "Prompting for credential '$Name'." -Level DEBUG
    Get-Credential -Message "Credentials for '$Name'"
}
