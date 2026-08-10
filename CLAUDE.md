# CLAUDE.md

Context for Claude Code sessions in this repo.

## What this is

PowerShell automation against production VMware and Cisco infrastructure:
vSphere/vCenter, Cisco UCS Manager, Intersight (SaaS and on-prem PVA), and Site
Recovery Manager. Scripts here can change real systems, so correctness and dry
runs matter more than brevity.

## Relevant skills

Use them rather than working from memory — they carry verified auth patterns and
known gotchas:

- `intersight-powershell` — anything touching Intersight, `Intersight.PowerShell`,
  server profiles, or IMM.
- `srm-powercli` — anything touching SRM, `VMware.Sdk.Srm`, protection groups,
  recovery plans, or network mappings.
- `change-document` — writing a change request or implementation plan.

## Layout

- `modules/Richo.Common/` — shared helpers. Public functions are one per file
  under `Public/`, and must also be listed in `FunctionsToExport` in the `.psd1`
  or they will not be exported.
- `scripts/<platform>/` — the automation. `scripts/_template.ps1` is the
  starting point and reflects the house style.
- `config/environments.json` — gitignored; `environments.example.json` is the
  committed template.
- `tests/` — Pester 5 tests. They must not touch live infrastructure.

## House rules

- Name scripts `Verb-Noun.ps1` with an approved verb (`Get-Verb`).
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` at the
  top of every script.
- `[CmdletBinding(SupportsShouldProcess)]` on anything that mutates, with every
  mutating call wrapped in `$PSCmdlet.ShouldProcess(...)`. `-WhatIf` must be a
  genuine no-op.
- Log via `Write-RichoLog`; never `Write-Host`.
- Comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`) on
  every script and public function.
- Target PowerShell 5.1 compatibility unless a script says otherwise — some
  jump hosts are still Windows PowerShell.

## Never commit

Credentials, `.pem`/`.key` files, `config/environments.json`, exported
`.clixml` credential blobs, or anything under `logs/` and `output/`. Secrets
resolve at runtime through `Get-RichoCredential` (SecretManagement, then
`RICHO_*` environment variables, then an interactive prompt).

## Checks

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./tests
```

PowerShell is not installed in the Claude Code web sandbox, so changes made
there cannot be executed or linted — say so plainly rather than implying a
script was verified.
