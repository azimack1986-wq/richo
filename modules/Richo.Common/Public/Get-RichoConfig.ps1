function Get-RichoConfig {
    <#
    .SYNOPSIS
        Loads an environment definition from config/environments.json.

    .DESCRIPTION
        Environment definitions live in config/environments.json, which is
        gitignored. Copy config/environments.example.json to get started.

        The file holds no secrets -- only endpoints, key IDs, and paths to key
        files that live outside the repo. Use Get-RichoCredential for anything
        that would be a password.

    .PARAMETER Name
        Environment key to return, e.g. 'lab' or 'prod'. When omitted, the
        environment named by the file's "default" property is returned.

    .PARAMETER Path
        Override the config file location. Defaults to $env:RICHO_CONFIG when
        set, otherwise config/environments.json at the repo root.

    .EXAMPLE
        $env = Get-RichoConfig -Name lab
        Connect-VIServer -Server $env.vcenter.server
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [string]$Path
    )

    if (-not $Path) {
        $Path = if ($env:RICHO_CONFIG) {
            $env:RICHO_CONFIG
        }
        else {
            Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent | Split-Path -Parent) 'config/environments.json'
        }
    }

    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path. Copy config/environments.example.json to config/environments.json and fill it in."
    }

    $config = Get-Content -Path $Path -Raw | ConvertFrom-Json

    if (-not $Name) {
        if (-not $config.PSObject.Properties.Name.Contains('default')) {
            throw "No -Name given and '$Path' has no 'default' property."
        }
        $Name = $config.default
    }

    if (-not $config.environments.PSObject.Properties.Name.Contains($Name)) {
        $known = ($config.environments.PSObject.Properties.Name) -join ', '
        throw "Environment '$Name' not found in $Path. Known environments: $known"
    }

    $selected = $config.environments.$Name
    $selected | Add-Member -NotePropertyName 'Name' -NotePropertyValue $Name -Force
    $selected
}
