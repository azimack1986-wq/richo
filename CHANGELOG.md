# Changelog

Notable changes to the automation in this repo. Versions are tagged in git
(`git tag -l`), and each script carries its own `$ScriptVersion`, which is
stamped onto every row of the run summary and verification CSVs — so a change
record can always be traced back to the revision that produced it.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [semantic](https://semver.org/) per script.

---

## Invoke-AutoDeployFirmwareBatchControl.ps1

### [17.2.0] — 2026-08-11

`Set-VMHost` failed a live run with "An error occurred while sending the
request". That is a transport timeout, and it was caused by a change I made in
16.x.

#### Fixed

- **Entering Maintenance mode always uses `-RunAsync`, including for a single
  host.** Deriving async from batch size meant a SINGLE-mode batch used the
  blocking form, which holds one HTTP request open for the entire evacuation.
  PowerCLI's `WebOperationTimeoutSeconds` defaults to 300, and evacuating a
  production host takes longer than five minutes, so the request was torn down
  mid-evacuation — leaving the host partway into maintenance with only "An error
  occurred while sending the request" to show for it. Issuing the task and
  polling has no such ceiling, and `Wait-BatchMaintenanceMode` already did
  exactly that.
- The PowerCLI web operation timeout is raised to
  `$PowerCliWebOperationTimeoutSeconds` (3600) for the session at vCenter connect
  time, as defence for every other long-running task.

#### Added

- `tests/Test-WorkflowSimulation.ps1` — runs the entire cluster workflow against
  stubbed vCenter, UCS Manager and Intersight cmdlets, in both DRY RUN and LIVE
  modes, with a scripted operator answering prompts. 30 assertions covering
  platform routing, every host batched exactly once, firmware actions firing,
  hosts returned to service, and DRY RUN mutating nothing.
  - The `Set-VMHost` stub **refuses a blocking evacuate**, so the defect fixed
    above cannot return silently.
  - A prompt the scripted operator cannot answer throws rather than hanging, so a
    `Read-ChoiceExit` loop fails fast.

#### Notes

- The simulation proves control flow, not vendor behaviour. Stubs return
  instantly and always succeed, so nothing in it speaks to real timeouts,
  appliance schemas or evacuation duration. A live DRY RUN is still the only
  thing that tests those.

### [17.1.0] — 2026-08-11

Triggered by a live run failing at PowerCLI load, then reviewed with a static
lint written around the bug classes this script has actually shipped.

#### Fixed

- **A failed vCenter connection left the cleanup trying to disconnect a session
  that never existed**, reporting "Could not find VIServer with name ..." on top
  of the real error. `$global:vCenter` was recorded before `Connect-VIServer`
  succeeded; a separate `$global:vCenterConnected` is now set only after a
  successful connect, and both disconnect sites honour it.
- **A PowerCLI module load failure was unactionable.** `Connect-VIServer`
  auto-loads `VMware.VimAutomation.Core`, and PowerShell reports only "the
  command was found in the module ... but the module could not be loaded" — which
  names neither cause nor fix. The import is now explicit, so the real inner
  exception is shown along with the causes that produce it: blocked module files
  after an offline or share-based install, a PowerCLI version predating
  PowerShell 7 support, restrictive folder permissions, and Group Policy
  requiring signed modules.
- **`Format-Table` was leaking rendering records into three functions' return
  values**, including `Wait-BatchReconnectAfterReboot`, whose result the caller
  actually inspects. Every display table now goes through `Out-Host`.
- **Fifteen mandatory `[array]` parameters lacked `[AllowEmptyCollection()]`.**
  Parameter binding fails outright on an empty collection, turning a legitimately
  empty list into a mid-run crash — the same defect already fixed once in
  `Get-CapacityBasedBatchSize`.

#### Added

- `tests/Test-ScriptLint.ps1` — static checks across all five scripts for the bug
  classes shipped in this codebase, each of which is silent at parse time: bare
  commands joined with `-and`/`-or`, assignment to read-only automatic variables,
  mandatory arrays without `[AllowEmptyCollection()]`, `Format-Table` on a
  function's success stream, and uncached module enumeration. 30 assertions.

### [17.0.0] — 2026-08-10

Checked against Cisco's published SDK reference and issue tracker. One finding
is a genuine defect that would never have worked, hence the major bump.

#### Fixed

- **The Intersight deploy call was wrong.** It called
  `New-IntersightFirmwareUpgrade -Server <server.Profile> -RebootImmediately
  -DisruptionAcknowledged`. Per the SDK reference that cmdlet has neither
  `-RebootImmediately` nor `-DisruptionAcknowledged`, and its `-Server` takes a
  `ComputePhysicalRelationship` (`compute.Blade` / `compute.RackUnit`), not a
  server profile. Deploying a staged firmware policy is
  `Set-IntersightServerProfile -Moid <profile> -Action Deploy`, which is what the
  script now sends. `-Action` accepts only `Deploy` and `Unassign`; `Activate`
  was withdrawn from the SDK.
- **Intersight authenticates once per PowerShell session and never again.**
  Cisco's getting-started guidance is explicit that
  `Set-IntersightConfiguration` is called once per session. The one-shot guard is
  set the moment the call is issued, whether it succeeds or throws, so a failed
  attempt can no longer be followed by another in the same session — that tested
  a stale client rather than the credentials and produced the repeated
  mismatches. A successful login is reused for every cluster in the run.
- **In-session retry removed.** RETRY re-issued `Set-IntersightConfiguration`,
  which is the thing that does not work. The failure path now says plainly that a
  fresh session is required.
- **Per-cluster state is cleared** when a new cluster is selected from the Step 27
  menu: host maps, service profile caches, discovery cache, skipped hosts, batch
  action count and the target firmware policy. Previously a second cluster
  inherited the first cluster's `UcsHostMap` and profile caches, which could map
  its hosts onto the wrong service profiles. Session logins are deliberately
  kept.

#### Added

- `$Global:IntersightApiKeyPassPhrase` for encrypted private keys — the SDK
  errors without it when the key is encrypted.
- `$Global:IntersightDeployActionParams`, sent as `PolicyActionParam` objects
  with the deploy. Empty by default: the parameter names carrying a reboot
  acknowledgement are not published in the SDK reference, and guessing at the
  name of a parameter whose job is to authorise a disruptive reboot is not a safe
  default.

#### Notes

- The error "Error performing this operation. Check that BasePath and API Key
  identifier are configured correctly" is a known module regression, not
  necessarily a configuration fault — reported broken in 1.0.11.13236 and working
  in 1.0.11.12738 (CiscoDevNet/intersight-powershell issue #106).
- `HashAlgorithm` already defaults to SHA256 and `HttpSigningHeader` already
  defaults to the four signing headers, so passing them was redundant rather than
  harmful.
- Get cmdlets return at most 10,000 objects per invocation.

### [16.9.0] — 2026-08-10

Aligned with a minimal `Set-IntersightConfiguration` call the operator confirmed
works against this PVA, where the script's richer call kept faulting. Three
differences, each now removed or defaulted off.

#### Fixed

- **Only one `Set-IntersightConfiguration` call per session.** The key-file then
  key-string fallback issued a second call after a failure.
  `Set-IntersightConfiguration` is process-wide state that does not reliably
  reset, so the second call tested a poisoned client rather than the
  credentials — which is exactly why the same inputs succeed first time in a
  fresh session. The failure path now says to start a fresh PowerShell session
  rather than quietly retrying in a session that has already failed.
- **`-SkipCertificateCheck` is off by default**, including for on-prem
  appliances, and is no longer derived from the address. It swaps the module's
  HTTP handler, which is a credible cause of the corrupted response bodies —
  JSON turning to percent-encoded JSON partway through — that surface as
  "cannot be deserialized into any schema defined".
- **`-HashAlgorithm` is omitted** unless `$Global:IntersightHashAlgorithm` is
  set, leaving the module default rather than forcing SHA256.

#### Changed

- The exact `Set-IntersightConfiguration` call is echoed before it runs, with
  the key ID and PEM path elided, so what the script sends can be compared
  against a known-good call at a glance.
- Remedies for an unreadable response are reordered to match likelihood: fresh
  session first, certificate handler second, module version last. Previously it
  led with the module version, which is the most disruptive and least likely.

### [16.8.0] — 2026-08-10

#### Removed

- **All module and PowerShell version probing from the pre-flight.** Enumerating
  `Intersight.PowerShell`, whose manifest exports several thousand cmdlets, was
  slow enough on a domain jump host to read as a hang, and it ran before every
  single run. The environment is now assumed to meet the requirements.
- `Get-ModulePresenceReport`, along with the module table, the PowerShell
  edition check, the pinned-version comparison and the UCS PowerTool check.

#### Changed

- Requirements moved into the script header as a REQUIREMENTS block, and printed
  as a short notice at the start of a run. They say what must be present and why
  each matters, without checking anything.
- `Assert-IntersightPowerShellAvailable` is a cmdlet-existence check only. No
  enumeration, no version listing.

#### Notes

- Nothing is lost on the failure path. A missing module still fails clearly at
  the point of use, and the Intersight login diagnostics still report every
  installed version when a login actually fails — which is when the wait is
  worth paying for. `scripts/intersight/Test-IntersightApiKey.ps1` remains the
  way to verify the environment out of band.
- `tests/Test-ModulePresence.ps1` is now
  `tests/Test-ModuleEnumerationCache.ps1`, covering the caching that survives on
  the failure path.

### [16.7.1] — 2026-08-10

#### Fixed

- **The pre-flight appeared to hang after the PowerShell edition check.** The
  next statement was another `Get-Module -ListAvailable` for
  `Intersight.PowerShell`, and that module's manifest exports several thousand
  cmdlets, so each enumeration is slow — and the script was doing it at five
  separate points with no output in between. Module enumeration is now cached
  per module and reused, and each lookup prints what it is doing and how long it
  took, so a slow environment reads as slow rather than as stuck.
- The `Get-Command` probe in the module check is only used as a fallback when
  the module is not found by name. It triggers command discovery across every
  module on the machine, which for a module of this size costs more than the
  enumeration it was backing up.
- A first lookup taking over 15 seconds now prints the `PSModulePath` entries
  and flags network or unreachable paths, which is the usual cause.

#### Added

- Progress output through the pre-flight, including an explicit
  "Pre-flight checks complete" before the first prompt.
- Caching assertions in `tests/Test-ModulePresence.ps1`: a module is enumerated
  at most once per run, distinct modules enumerate independently, and `-Refresh`
  forces a re-read.

### [16.7.0] — 2026-08-10

Found on the first successful authenticated run: the blade had a pending profile
update and the deploy was never sent.

#### Fixed

- **A firmware policy change leaves the profile in `Pending-changes`, not
  `Inconsistent`.** Only `Inconsistent` was matched, so a profile sitting in
  `Pending-changes` was reported as `IsInconsistent False`, no deploy was sent,
  and the host never rebooted. Every state meaning "changes are staged but not
  on the server" is now actionable — `Pending-changes`, `Inconsistent`,
  `Out-of-sync`, `Not-deployed` — listed in
  `$Global:IntersightActionableConfigStates` and matched ignoring case, spaces,
  hyphens and underscores.
- **The batch then waited out the full 25-minute post-reboot window for a reboot
  that was never triggered**, and would have run the host profile compliance
  check against a host that never restarted. Each batch now counts the
  disruptive actions it actually sends. If that count is zero, the reboot wait is
  skipped and the operator is shown each host with its current ConfigState, then
  chooses CONTINUE (these hosts already run the target firmware) or STOP (the
  policy was not staged against these profiles).
- `Format-Table` inside the inconsistency check wrote to the success stream,
  which would have leaked rendering records into any caller's pipeline.

#### Changed

- `Get-IntersightProfileInconsistencyState` is now
  `Get-IntersightProfileDeployState`, returning `RequiresDeploy` in place of
  `IsInconsistent`. The batch table column changes to match.

#### Added

- `tests/Test-IntersightDeployState.ps1` — 26 assertions covering the state from
  the live run, the other actionable states, seven spelling and casing variants,
  six states that must never trigger a reboot, and the unreadable cases that
  must not be silently treated as "nothing to do".

### [16.6.0] — 2026-08-10

#### Added

- Pinned module versions in `config/module-requirements.psd1`, plus
  `tools/Save-RichoModuleBundle.ps1` to fetch them into `modules/vendor/` on a
  machine with gallery access and `tools/Import-RichoModuleBundle.ps1` to load
  them on a jump host. `Save-Module` is used, so nothing is installed and no
  admin rights are needed; the import prepends the bundle to `$env:PSModulePath`
  for the current session only, so pinned versions shadow machine-wide installs
  without changing anything on the machine.
- The pre-flight compares the loaded `Intersight.PowerShell` against the pinned
  version and points at the bundle when they differ. A mismatched build
  authenticates correctly and then fails to read the appliance's responses, so
  catching it here saves a change window.

#### Notes

- `modules/vendor/README.md` covers the size question before committing
  binaries: GitHub rejects files over 100 MB, git keeps every version forever,
  and the recommendation is to vendor only `Intersight.PowerShell` — the
  version-sensitive one — and install PowerCLI and UCS PowerTool normally.

### [16.5.0] — 2026-08-10

Follow-up to the PVA diagnosis: no code change can make the module parse a
schema it does not know, so the controller now fails usefully instead of
failing totally.

#### Added

- When Intersight authenticates but its responses cannot be read, the run offers
  to exclude the Intersight-managed hosts and continue with the UCS Manager
  hosts, rather than abandoning the whole cluster. This is decided during
  detection, before any host has been touched, so nothing is left half-done.
  Excluded hosts are removed from batching entirely — they are never treated as
  UCS Manager-managed, which they are not — and each exclusion is recorded in
  the run summary.
- The API key checker probes several endpoints when a deserialization failure is
  seen, naming the schema that actually failed for each. If every endpoint
  reports the same failing schema, the module resolves that object internally on
  every call and no endpoint is usable until the versions match; if only some
  fail, a workaround may exist.

### [16.4.0] — 2026-08-10

Diagnosed from a live PVA run: the "authentication failure" was not one. The
appliance accepted the signed request and returned a populated payload; the
module then failed to deserialize it. Reporting that as a credential problem
would have sent an operator to regenerate a perfectly good API key mid-change.

#### Fixed

- A response the module cannot deserialize is no longer reported as a login
  failure. `Get-IntersightFailureKind` separates a rejected key from a key that
  worked but whose reply could not be parsed — the module reports both with the
  same catch-all message, and only one is about credentials. The deserialization
  case now states plainly that authentication succeeded, that the credentials
  are correct, and that the fix is to align the `Intersight.PowerShell` version
  with the appliance release.
- Exception messages are truncated to 400 characters in diagnostics. A
  deserialization failure embeds the entire API response in its message, which
  ran to thousands of lines and buried every other clue on screen.

#### Added

- `tests/Test-IntersightFailureKind.ps1` — classification tested against the
  real error shapes, including the abridged payload from the live run, four
  genuine credential rejections, and cases that must stay Unknown rather than
  being guessed at. 16 assertions.

### [16.3.0] — 2026-08-10

#### Added

- `scripts/intersight/Test-IntersightApiKey.ps1` — a standalone, read-only
  checker for an Intersight API Key ID and `.pem` against an appliance. Works
  through the causes of the module's catch-all "check that BasePath and API Key
  identifier are configured correctly" and gives a verdict for each: PowerShell
  edition, installed module versions, PEM header/footer/BOM/whitespace, key ID
  segment shape, proxy interception, reachability, clock skew against the
  appliance's own `Date` header, and finally the authentication itself.
- PowerShell edition check in the pre-flight. `Intersight.PowerShell` is a
  binary module built for PowerShell 7 (Core); it can appear installed under
  Windows PowerShell 5.1 and then fail at the first signed request with an error
  that blames BasePath and the key.
- Automatic fallback from `ApiKeyFilePath` to `ApiKeyString`. A byte-order mark
  or stray leading whitespace in the `.pem` makes the file form fail while the
  string form succeeds; the run now recovers by itself and says the file needs
  correcting.

#### Notes

- Clock skew is worth calling out: HTTP signature authentication signs the
  `Date` header, so a jump host more than a few minutes out of sync is rejected
  with an error that never mentions time.

### [16.2.0] — 2026-08-10

#### Added

- The pre-flight check now verifies the required PowerShell modules before
  vCenter is contacted, reporting each as OK, MISSING or MULTIPLE with the
  versions found:
  - **VMware PowerCLI** — missing stops the run, since everything depends on it.
  - **Intersight.PowerShell** — missing warns with the install command and notes
    the run will stop at Intersight fabric detection. More than one version
    installed warns loudly, because that is the most common cause of an
    authentication failure with a valid API key.
  - **Cisco UCS PowerTool** — missing warns when running in firmware mode.
- A module registering its cmdlets under a different module name still counts as
  present, so a working install is never reported as missing.

#### Fixed

- A controlled stop (`SAFE_EXIT` / `STOP_WORKFLOW`) reaching the outer handler
  printed "Unhandled script error: STOP_WORKFLOW". It now reports a controlled
  checkpoint, and no longer records a duplicate error row in the summary.

### [16.1.0] — 2026-08-10

Found during the first live run against a PVA appliance.

#### Fixed

- **Intersight credentials were requested too late.** The API Key ID and `.pem`
  prompt lived in `Get-IntersightCredentialIfNeeded`, reached only from the
  accept/reboot step *inside* a batch. In practice the first prompt appeared
  after the batch had entered Maintenance mode and passed the pre-reboot safety
  window, so a wrong key or unreachable appliance stranded the batch with hosts
  evacuated instead of stopping the run before any disruption. Authentication
  and server profile resolution for every Intersight-routed host now happen
  during infrastructure detection, alongside the UCS Manager login that was
  already there.
- **`Stop-WithMessage` did not warn about Maintenance mode.** `Stop-SafeExit`
  did. A stop landing mid-batch left hosts evacuated without saying so.

#### Added

- Intersight login failure diagnostics. The module reports every API failure as
  a generic "check that BasePath and API Key identifier are configured
  correctly", which names neither the real cause nor the useful detail. On
  failure the script now reports: the full inner exception chain including HTTP
  status and response body; whether the appliance answers HTTPS at all
  (separating a wrong or unreachable FQDN from a rejected key); all installed
  `Intersight.PowerShell` versions; the active `Get-IntersightConfiguration`;
  the key ID segment count; and the private key type from its PEM header.
- RETRY on Intersight login failure, re-prompting for FQDN, key ID and private
  key without losing the run. Bounded to three attempts.
- Installed module versions are always printed, not only when several are found.

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

---

## Invoke-AutoDeployFirmwareBatchPreAuth.ps1

### [17.0.1-preauth] — 2026-08-10

#### Added

- The operator's own `Set-IntersightConfiguration` block, populated in the
  `AUTHENTICATION` region: appliance FQDN, API Key ID and the key file path on
  the Depot share.
- The block is **guarded to apply once per PowerShell session**. Re-running the
  script in the same session reports that the configuration is already applied
  and does not re-send it — re-applying is unreliable and is the fault behind the
  repeated authentication mismatches. A fresh session starts clean because the
  guard variable does not exist yet.
- `$Global:IntersightBaseUrl` is derived from `$IntersightServer`, so the
  appliance is set in one place and reflected wherever the script reports or logs
  it. `Assert-IntersightReady` still overwrites it with whatever
  `Get-IntersightConfiguration` actually holds, so the summary records the value
  in force rather than the value intended.
- `tests/Test-PreAuthSessionGuard.ps1` — 16 assertions: the configuration is sent
  exactly once however many times the region is entered, an undefined guard is
  treated as not-yet-applied, the values reach the call, `BasePath` carries no
  `/api` path or trailing slash, the four signing headers arrive in order, and
  `HashAlgorithm` and `SkipCertificateCheck` stay unset.

#### Changed

- `tests/Test-PreAuthVariantParity.ps1` previously asserted the pre-auth build
  never calls `Set-IntersightConfiguration`. Now that it carries the operator's
  block, the invariant is narrower and stronger: at most one call, inside the
  `AUTHENTICATION` markers, never inside a function, and guarded.

#### Notes

- `APIKeyFile` in the block binds to the module's `ApiKeyFilePath` as an
  unambiguous abbreviation. The session guard test models the real parameter
  surface, so that binding is proven rather than assumed.
- The key file is on a UNC path. If the jump host cannot reach the Depot share,
  or reaches it slowly, authentication fails or stalls there.

### [17.0.0-preauth] — 2026-08-10

Derived from `Invoke-AutoDeployFirmwareBatchControl.ps1` 17.0.0 with Intersight
authentication removed, for operators who apply their own
`Set-IntersightConfiguration` and want the controller to leave it alone.

#### Removed

- Every function whose job was to establish an Intersight connection:
  `Connect-IntersightTarget`, `Get-IntersightCredentialIfNeeded`,
  `Get-IntersightBaseUrlIfNeeded`, `ConvertTo-IntersightBaseUrl`,
  `Test-IntersightSaaSUrl`, `Show-OpenFileDialog`,
  `Write-IntersightLoginDiagnostics`, `Test-IntersightEndpointReachable`.
- All prompts for an API Key ID, private key file and appliance FQDN, and the
  settings that held them.
- `Set-IntersightConfiguration` is never called. The caller's session
  configuration is left exactly as found, including at script exit.

#### Added

- An `AUTHENTICATION` region at the top, between explicit markers, for the
  operator's own configuration call — or leave it empty and run the call in the
  same session beforehand.
- `Assert-IntersightReady`, which does not authenticate. Once per run, before any
  host is touched, it reads back `Get-IntersightConfiguration`, confirms a
  BasePath is set, and issues one small read to prove the connection works. A
  failure is reported and never retried, and still routes into the existing offer
  to skip the Intersight-managed hosts and continue with the rest.
- `tests/Test-PreAuthVariantParity.ps1` — compares every function the two builds
  share and fails on any drift outside a declared exception list, asserts the
  auth functions are absent and `Set-IntersightConfiguration` is never called,
  and fails if a declared exception stops differing so stale entries cannot mask
  a regression. 26 assertions.

#### Notes

- Everything else — CDP/LLDP detection, CSV name matching, UCS Manager, batching,
  host profile compliance, cluster health, the Step 27 menu — is byte-identical
  to the main controller and verified so by the parity test.
