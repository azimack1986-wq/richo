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

## Auditing a UCS domain against Cisco's recommendations

[`scripts/ucs/Test-UcsBestPractice.ps1`](scripts/ucs/Test-UcsBestPractice.ps1)
walks every readable setting on one UCS Manager domain, compares it against
Cisco's published guidance, and writes the result to CSV — one row per setting,
each carrying the value found, the value Cisco recommends, and a verdict.

```powershell
# Prompts for the fabric address, then for a username and password.
.\scripts\ucs\Test-UcsBestPractice.ps1

# Or unattended, against a stored credential.
.\scripts\ucs\Test-UcsBestPractice.ps1 -Fabric ucsm-prod-01 -CredentialName ucsm-prod -Transcript
```

One domain per run — point it at the cluster VIP, not an individual fabric
interconnect. It reads and nothing else; the only thing it creates is the CSV,
which is what `-WhatIf` skips.

### Running it away from the repo

`dist/Test-UcsBestPractice-Standalone.ps1` is the same audit as one file — the Richo.Common
helpers are carried inline, so there is nothing to install beside it and nothing to import. Copy
it to a jump host or a share and run it.

```powershell
# Windows blocks scripts copied from a network location.
Unblock-File .\Test-UcsBestPractice-Standalone.ps1
.\Test-UcsBestPractice-Standalone.ps1
```

Output goes to the directory you run it **from**, not the directory the script sits in — a copy on
a read-only or shared location is not where audit CSVs should accumulate.

It is generated, not maintained by hand:

```powershell
.\tools\Build-UcsBestPracticeStandalone.ps1
```

`tests/Test-UcsBestPracticeStandalone.ps1` regenerates it in memory and compares it against the
committed file, so the copy on the share cannot quietly stop being the copy that was reviewed.

### The one Cisco module it needs

Cisco UCS PowerTool — the `Cisco.UCSManager` module, which brings `Cisco.UCS.Core` with it:

```powershell
Install-Module -Name Cisco.UCSManager -Scope CurrentUser
```

That is the only Cisco module involved. There is no Intersight or UCS Central module in the
picture, because a registered domain still answers for its own configuration over the UCSM XML API.

Nothing is imported explicitly — PowerShell auto-loads on the first `Connect-Ucs` — and the check
is whether `Connect-Ucs` resolves, not whether a particular module name is installed, so an
existing PowerTool (including the older `CiscoUcsPS`, or a vendored bundle already on
`$env:PSModulePath`) satisfies it. The run logs which module actually provided the cmdlet, and its
version, so there is no need to guess whether anything needs installing.

Two columns are worth knowing about before reading the output:

- **Basis** separates advice by weight. `Best Practice` is something Cisco
  recommends explicitly and the row's `Reference` says where. `Cisco Default` is
  a value Cisco ships — a deviation there means somebody changed it, not that it
  is wrong. `Site Policy` is a local design decision, reported for confirmation.
- **Owner** is the object's `PolicyOwner`. These domains are registered with UCS
  Central, so a setting may be owned centrally; where it is, the remediation says
  to change it in UCS Central, because a change made in UCS Manager is refused or
  reverted at the next policy push. The `UCS Central` category reports each
  Policy Resolution Control, which is what decides that ownership.

A setting the connected UCS Manager or PowerTool version does not expose is
reported as `Unknown`, never as a pass — an absent row reads as "nothing to see"
to whoever reviews the CSV, and a confident verdict on a setting that was never
read is worse than no verdict at all.

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

## Vendored modules (offline / pinned)

Third-party module versions are pinned in
[`config/module-requirements.psd1`](config/module-requirements.psd1) and can be
vendored into `modules/vendor/` so a jump host runs end-to-end without gallery
access — and so every jump host runs the same version.

```powershell
# Once, on a machine with PowerShell Gallery access:
.\tools\Save-RichoModuleBundle.ps1

# On the jump host, in the session you will run the automation from:
. .\tools\Import-RichoModuleBundle.ps1
```

`Save-Module` is used, so nothing is installed and no admin rights are needed.
The import puts the bundle at the front of `$env:PSModulePath` for the current
session only, so pinned versions win over machine-wide installs without changing
or removing anything on the machine.

This is not cosmetic. `Intersight.PowerShell` 1.0.11.2025021903 authenticates
correctly against a PVA and then cannot deserialize its responses — a schema
mismatch the module reports as a credential error. Pinning removes that class of
failure.

See [`modules/vendor/README.md`](modules/vendor/README.md) before committing the
binaries — they are large, GitHub rejects files over 100 MB, and git keeps every
version forever.

## Versioning

Git holds the history — **do not version by filename** (no `-v15`, `-final`,
`-new` suffixes). Instead:

- Each script carries a `$ScriptVersion` near the top, semantic per script.
- That version is stamped onto every row of the run summary and verification
  CSVs, so any change record traces back to the exact revision that produced it.
- Bump `$ScriptVersion` in the same commit as the change, record it in
  [CHANGELOG.md](CHANGELOG.md), and tag the commit to match:

```powershell
git tag -a firmware-batch-v16.0.0 -m "Firmware batch controller 16.0.0"
git push origin firmware-batch-v16.0.0
```

Tags are prefixed with the script name because scripts version independently.

Before a live run, check the banner the script prints against the tag you
intended to run — that is the cheapest way to catch a stale copy on a jump host.

## Before committing

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./tests
```

The firmware controller also ships standalone suites that need no Pester and no
vendor modules, so they run anywhere including a locked-down jump host:

```powershell
Get-ChildItem ./tests/Test-*.ps1 | ForEach-Object { pwsh -File $_.FullName }
```

They are independent, so any one can be run on its own:

| Suite | Covers |
| --- | --- |
| `Test-ScriptLint.ps1` | Static rules for bug classes these scripts have actually shipped |
| `Test-WorkflowSimulation.ps1` | The whole cluster workflow, DRY RUN and LIVE, against stubs |
| `Test-PreAuthVariantParity.ps1` | The two builds have not drifted apart |
| `Test-PreAuthSessionGuard.ps1` | Intersight is configured exactly once per session |
| `Test-ComplianceGate.ps1` | The host profile gate: settle, the four status routes, C/O/E |
| `Test-MaintenanceModeEntry.ps1` | Hosts evacuate one at a time, in cluster order |
| `Test-IntersightRebootActivate.ps1` | Reboot-to-activate is sent, and confirmed accepted |
| `Test-IntersightPowerAction.ps1` | The activation power-cycle: right server, right state, never fatal |
| `Test-UcsFabricFamily.ps1` | FI family detection and the firmware package it selects |
| `Test-BatchSizingAndCompliance.ps1` | Capacity-based batch sizing, compliance result parsing |
| `Test-IntersightNameMatching.ps1` | CSV name matching across -A/-B, FQDN and short forms |
| `Test-IntersightBaseUrl.ps1` | Appliance URL normalisation and SaaS classification |
| `Test-IntersightDeployState.ps1` | Which `ConfigState` values mean a deploy is needed |
| `Test-IntersightFailureKind.ps1` | Auth failure vs. a response the client cannot parse |
| `Test-ModuleEnumerationCache.ps1` | Module enumeration happens once, not per lookup |
