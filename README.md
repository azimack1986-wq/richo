# richo

PowerShell automation for VMware and Cisco infrastructure — vSphere/vCenter,
Cisco UCS Manager, Intersight (SaaS and PVA), and Site Recovery Manager.

## Layout

```
config/     Environment definitions. environments.json is gitignored;
            start from environments.example.json.
docs/       Runbooks and notes.
modules/    Richo.Common — shared logging, config, credential, and
            dependency helpers used by every script.
scripts/    The actual automation, one folder per platform.
            _template.ps1 is the starting point for a new script.
tests/      Pester tests for the shared module.
```

## First-time setup

Requires PowerShell 5.1 or later (7.4+ preferred).

```powershell
# 1. Environment definitions -- endpoints and key IDs, never secrets.
Copy-Item config/environments.example.json config/environments.json
#    then edit it for your estate.

# 2. Vendor modules, as needed. These are large; install only what you use.
Install-Module VMware.PowerCLI        -Scope CurrentUser
Install-Module Intersight.PowerShell  -Scope CurrentUser
Install-Module VMware.Sdk.Srm         -Scope CurrentUser

# 3. Tooling for linting and tests.
Install-Module PSScriptAnalyzer -Scope CurrentUser
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser

# 4. Credentials. SecretManagement is the preferred store.
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
Register-SecretVault -Name richo -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
Set-Secret -Name 'vcenter-lab' -Secret (Get-Credential)
```

Verify it works:

```powershell
Import-Module ./modules/Richo.Common/Richo.Common.psd1 -Force
Get-RichoConfig -Name lab
Invoke-Pester -Path ./tests
```

## Writing a script

Copy `scripts/_template.ps1` into the right platform folder and rename it
`Verb-Noun.ps1` using an approved verb (`Get-Verb`). The template already wires
up the conventions below.

## Conventions

- **`ShouldProcess` on anything that mutates.** Every script declares
  `[CmdletBinding(SupportsShouldProcess)]` and guards mutating calls, so
  `-WhatIf` is always a safe dry run.
- **`Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`** at
  the top of every script.
- **Log through `Write-RichoLog`**, not `Write-Host`. Output stays timestamped
  and greppable, and `-Transcript` captures a run artifact in `logs/`.
- **No secrets in the repo.** Passwords come from `Get-RichoCredential`;
  Intersight `.pem` keys live outside the working tree and are referenced by
  path from `config/environments.json`. `.gitignore` blocks the usual
  offenders, but it is a safety net, not a substitute for care.
- **Check dependencies up front** with `Assert-RichoModule` so a missing module
  fails immediately with the install command.

## Before committing

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./tests
```
