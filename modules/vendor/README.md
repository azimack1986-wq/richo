# Vendored PowerShell modules

Pinned third-party modules, so a Windows jump host can run the automation
end-to-end without reaching the PowerShell Gallery — and so every jump host runs
the *same* version.

This folder is empty in git until someone runs the fetch step below.

## Why this exists

Version drift caused a real failure: `Intersight.PowerShell` 1.0.11.2025021903
authenticated correctly against the PVA and then could not deserialize its
responses — a client/appliance schema mismatch that the module reports as a
credential error. Pinning the version proven against your appliance removes that
whole class of problem.

Versions are declared in [`config/module-requirements.psd1`](../../config/module-requirements.psd1).

## Fetch (once, on a machine with gallery access)

```powershell
.\tools\Save-RichoModuleBundle.ps1
```

Uses `Save-Module`, so nothing is installed and no admin rights are needed. It
reports the size of everything it saves and warns if Git LFS is required.

To pull just the version-sensitive one:

```powershell
.\tools\Save-RichoModuleBundle.ps1 -Name Intersight.PowerShell
```

## Use (on the jump host)

Dot-source before running the controller, in the same session:

```powershell
. .\tools\Import-RichoModuleBundle.ps1
.\scripts\firmware\Invoke-AutoDeployFirmwareBatchControl.ps1
```

That puts this folder at the front of `$env:PSModulePath` **for the current
session only**. The pinned versions win over anything installed machine-wide,
nothing is installed, and nothing on the machine is changed or removed — close
the session and it is exactly as it was.

This is also the cleanest way out of a side-by-side version conflict without
needing rights to uninstall the machine-wide copy.

## Before committing binaries — read this

These modules are large, and git keeps every version you ever commit, forever.

- GitHub **rejects** any single file over **100 MB** and warns over 50 MB.
- A large bundle slows every future clone for everyone, permanently.

`Save-RichoModuleBundle.ps1` reports total size and flags oversized files so you
can decide *before* committing.

**Recommended:** commit only `Intersight.PowerShell` — the version-sensitive one
— and install PowerCLI and UCS PowerTool normally on each jump host. That gets
the reproducibility where it matters without the bulk.

### If you do commit large files, use Git LFS

```powershell
git lfs install
git lfs track "modules/vendor/**/*.dll"
git lfs track "modules/vendor/**/*.zip"
git lfs track "modules/vendor/**/*.nupkg"
git add .gitattributes
```

Track them **before** the first commit of those files. Retrofitting LFS means
rewriting history.

### If you would rather not commit them at all

Add to `.gitignore`:

```gitignore
modules/vendor/*
!modules/vendor/README.md
```

and distribute the bundle as a zip through your normal software channel. The
import script works the same either way — it only cares that the folder exists.
