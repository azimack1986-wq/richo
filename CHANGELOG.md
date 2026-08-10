# Changelog

Notable changes to the automation in this repo. Versions are tagged in git
(`git tag -l`), and each script carries its own `$ScriptVersion`, which is
stamped onto every row of the run summary and verification CSVs — so a change
record can always be traced back to the revision that produced it.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [semantic](https://semver.org/) per script.

---

## Invoke-AutoDeployFirmwareBatchControl.ps1

### [16.0.0] — 2026-08-10

Reviewed and reworked from the supplied v15. Breaking changes to the operator
flow are listed under *Changed* — read those before the first live run.

#### Fixed

- **Intersight CSV name matching missed most rows.** Both the CSV `Name` column
  and the CDP/LLDP system name were collapsed to a single suffix-stripped key,
  so a host only matched when both sides happened to share the same FQDN/short
  shape. A row named `PD24000001SS101-A` never matched a host reporting
  `PD24000001SS101-B.dpe.example`, and that host was silently routed down the
  UCS Manager path instead. Each row is now indexed under all eight equivalent
  forms of its name and each CDP name tested against the same set.
- **`-A` and `-B` rows overwrote each other.** Both collapsed onto one key, so
  the later row won and the earlier was reported as a duplicate. Fabric pairs
  now coexist; only rows disagreeing on which server profile to act on are
  flagged as ambiguous.
- **Intersight authentication called cmdlets that do not exist.**
  `Connect-IntersightApi` / `Disconnect-IntersightApi` are not part of
  `Intersight.PowerShell`. Replaced with `Set-IntersightConfiguration` and the
  required signing headers. `BasePath` no longer carries the `/api/v1` suffix
  that breaks signature validation.
- **Paged API results were mistaken for objects.** `Get-IntersightServerProfile`
  returns a page carrying `Results`; piping it to `Select-Object -First 1`
  yielded the page, whose `Moid` is null, so the accept/reboot targeted nothing.
- **`if (Test-DryRun -or Test-StageNoAck)` never evaluated the second call** —
  it parses as a call to `Test-DryRun` with `-or` as an argument. Parenthesised
  at all four sites.
- **Unbounded recursion** on RECHECK after failed firmware policy verification.
- **An unreadable `ConfigState` was treated as "nothing to do"**, silently
  skipping a host that may still have needed the firmware change.
- **`$host` used as a local variable** in URL normalisation. It is a read-only
  automatic variable; assigning to it throws.
- **Mandatory `[array]` without `AllowEmptyCollection`** in batch sizing failed
  parameter binding on an empty candidate list instead of returning cleanly.
- **A cached UCSM credential that failed authentication** was reused against
  every remaining domain. It is now discarded on an auth-shaped failure.
- **`[Console]::KeyAvailable` was unguarded** and throws under redirected stdin,
  turning a timed wait into an unhandled error mid-change.

#### Added

- Pre-flight gate confirming the Intersight API Key ID and matching `.pem` are
  in hand, before vCenter is contacted.
- File browser for selecting the `.pem` private key, marshalled onto an STA
  runspace on PowerShell 7, falling back to a typed path where there is no GUI.
- Prompt for the Intersight appliance FQDN as soon as an Intersight fabric is
  detected; the answer becomes the API `BasePath` for the run. Input is
  normalised (bare FQDN, full URL, trailing slash, pasted `/api/v1`) and
  validated. Certificate checking follows from the answer — skipped for on-prem
  PVA, enforced for `intersight.com`.
- Host profile compliance gate. After reboot, each host is tested against its
  attached profile while still in Maintenance mode. Compliant hosts exit
  Maintenance mode and the run continues; non-compliant hosts stay in
  Maintenance mode until remediated and re-tested. An unreadable result is
  never treated as a pass.
- Real capacity-based batch sizing. `ResourceSafetyBuffer`,
  `MinimumCpuHeadroomPercentAfterBatch`, `MinimumMemoryHeadroomPercentAfterBatch`
  and `MinimumDatastoreFreePercent` were previously accepted and ignored; they
  are now enforced.
- Cluster health checks before and after every batch — host connection state,
  unexpected Maintenance mode, datastore free space, red cluster alarms.
- Run-time validation of the Intersight upgrade cmdlet parameter surface before
  the first blade is touched, stopping rather than substituting a different
  destructive call.
- `$ScriptVersion`, stamped onto every summary and verification CSV row.
- Test suites: `Test-IntersightNameMatching.ps1`,
  `Test-BatchSizingAndCompliance.ps1`, `Test-IntersightBaseUrl.ps1` — 75
  assertions, standalone (no Pester or vendor modules), touching no
  infrastructure.

#### Changed

- **Per-batch typed gates removed.** `ACK-BATCH-N` and `SAVE-BATCH-N` are gone;
  the run advances through the cluster automatically. Each batch is instead
  gated by a pre-batch health check, the timed pre-reboot safety window (press
  `E` to abort), the host profile compliance check, and a post-batch health
  check. Any failure stops the run.
- **Batch size is no longer free text.** The only options are AUTO (sized from
  live capacity and health) and SINGLE (one host at a time).
- **Maintenance mode execution method prompt removed.** It only chose whether
  `Set-VMHost` used `-RunAsync`, which follows from the batch size. Beyond
  removing a question, this fixes SEQUENTIAL on a multi-host batch, where
  evacuating one host at a time lets DRS place VMs onto a host later in the
  same batch.
- Intersight server profile lookup tries the ESXi short hostname before the CSV
  `Name`, since a Fabrics export `Name` is a fabric interconnect, never a
  profile name.
- `$IntersightBaseUrl` in User Settings is now only the default offered at the
  FQDN prompt.

#### Performance

- CDP/LLDP discovery cached per host, removing a second `QueryNetworkHint` pass
  over every host in the cluster.
- UCS service profile enumeration cached per UCSM domain instead of re-fetched
  per host.
- Pending-ack objects fetched once per domain per batch instead of once per
  host.

#### Known limitations

- The Intersight accept/reboot call
  (`New-IntersightFirmwareUpgrade -RebootImmediately -DisruptionAcknowledged`)
  is validated at run time but has not been confirmed against a live appliance.
- Nothing in this version has been executed against production vCenter, UCS
  Manager or Intersight. Verification is limited to the PowerShell parser, AST
  checks and the test suites above.

### [15] — supplied

Baseline as received, imported unchanged in commit `8c2f849` so subsequent work
reads as a diff. Versioned by filename
(`AutoDeployUCSMIntersightFirmwareBatchControlv15`); superseded by git history
and `$ScriptVersion` from 16.0.0.
