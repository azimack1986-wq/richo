# Changelog

Notable changes to the automation in this repo. Versions are tagged in git
(`git tag -l`), and each script carries its own `$ScriptVersion`, which is
stamped onto every row of the run summary and verification CSVs — so a change
record can always be traced back to the revision that produced it.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [semantic](https://semver.org/) per script.

---

## Invoke-AutoDeployFirmwareBatchControl.ps1

### [19.4.0] — 2026-08-11

The post-batch health check stopped a live run on a cluster with nothing wrong
with it, and the stop message did not say what had failed.

#### Fixed

- **Non-shared datastores no longer count.** `Get-Datastore -Location <cluster>`
  returns local, boot and scratch datastores, which routinely sit under
  `$MinimumDatastoreFreePercent` free by design and have no bearing on whether a
  host can be evacuated. Only shared datastores
  (`Summary.MultipleHostAccess`) are assessed; the rest are listed as a note. A
  datastore whose sharing cannot be determined is still checked, so the mistake
  is toward caution.
- **Acknowledged alarms no longer count.** An acknowledged red alarm is one
  somebody has already looked at and accepted; treating it as a fresh fault
  blocks every batch indefinitely, with no way through short of clearing an
  alarm that was deliberately kept. Unacknowledged red alarms still stop the run
  — and are now **named** rather than counted, because "3 red alarm(s)" sends
  someone hunting through vCenter for them.
- **The stop message carries the reasons.** They were printed above it and
  scrolled away with the batch output, so the record showed that something
  failed but not what. They are now in the message, in the run summary row, and
  in the exported CSV.

#### Added

- `Confirm-ClusterHealthOrChoose` replaces the dead stop on both the pre-batch
  and post-batch checks:
  - **RECHECK** — evaluate again. HA, vSAN and DRS raise alarms while a host
    rejoins and clear them shortly after, so a check run in that window fails a
    cluster that is already recovering. This is usually all that is needed.
  - **OVERRIDE** — accept and continue, recorded as `Overridden` naming exactly
    what was accepted.
  - **STOP** — stop, as before. `E` still exits.
  A healthy check prompts for nothing.

#### Added — tests

- `tests/Test-ClusterHealthGate.ps1` — 22 assertions: a nearly full *local*
  datastore does not fail the cluster while a shared one does, a datastore of
  unknown sharing is still checked, an acknowledged red alarm passes and an
  unacknowledged one fails by name, yellow is not a stop, RECHECK re-evaluates
  and records both the failure and the recovery, OVERRIDE names what was
  accepted, and STOP carries the reason into the stop message.

### [19.3.1] — 2026-08-11

#### Removed

- **The last `Import-Module` reference.** Not a call — the PowerCLI load
  diagnostic *printed* `Import-Module VMware.VimAutomation.Core -Verbose` as a
  suggested command. The script telling an operator to run one is the same
  instruction by another route, on a build whose whole premise is that modules
  are already present. Replaced with a read-only check that answers the same
  question without importing anything:
  `Get-Module -ListAvailable VMware.VimAutomation.Core | Select-Object Version,Path`.

#### Fixed — tests

- **The lint rule could not have caught it.** It searched for `Import-Module`
  as a `CommandAst` only, so a string containing one passed cleanly — which is
  how this survived several releases while the rule reported green. It now also
  checks string and expandable-string literals. Comments stay exempt: describing
  the rule is not breaking it.

### [19.3.0] — 2026-08-11

#### Removed

- **The "Have all manual health checks/change gates been completed and accepted?"
  prompt.** It asked about a change record the script cannot see, so answering it
  gated nothing — it only interrupted a run that is meant to walk the cluster
  unattended. It is now requirement 5 in the pre-flight, stated before anything
  starts. Everything the script *can* check it still checks per batch — cluster
  health, capacity, datastore free space, host profile compliance — and still
  stops if any of them fail.

#### Changed

- **An Intersight profile reporting `RequiresDeploy=false` is no longer asked
  about.** That is the state the run is trying to reach; stopping to confirm it
  strands an unattended cluster on a host that needed nothing doing. The prompt
  is now reserved for a state that could not be *read* — "nothing staged" and
  "could not tell" produce the same silence and must not be treated as the same
  answer. An unreadable `ConfigState` still stops the run to ask.
- **The post-change verification now compares the UCS end state, not just the
  policy.** The version each server reports running (`Get-UcsFirmwareRunning`,
  system deployment, under the service profile's `PnDn`) is compared against the
  version the package name refers to — `global-602d` is 6.0(2d), `global-436h`
  is 4.3(6h). The version is read back *out of the name*, so this script still
  writes no bundle version anywhere; but a server where the activation did not
  take is now caught, which a matching policy name alone would not show. A name
  off that convention yields no comparison rather than a comparison against a
  version nobody chose.

#### Added — tests

- The workflow simulation runs a **second pass over an already-current cluster**
  and fails if anything is asked: nothing is staged, so nothing reboots, and
  that is a result rather than a question. A separate pass asserts that an
  unreadable `ConfigState` *is* still raised with the operator.
- The end-state version comparison is covered both ways — a server on the right
  version verifies clean, a server left on the old one reports
  `VERSION MISMATCH` naming both versions.
- `ConvertTo-UcsBundleVersionFromPolicyName` has its own assertions, including
  that an unrecognised name yields nothing.
- The simulation now fails if the removed health-check prompt reappears.

### [19.2.0] — 2026-08-11

`Test-VMHostProfileCompliance -VMHost` returned *nothing at all* on a live run —
no error, no result — against an Auto Deploy host in Maintenance mode, while the
vSphere Client showed the host compliant. 19.1.0 read the result from more
places, which does not help when there is no result to read.

#### Added

- **Four routes to the compliance status**, tried in order, stopping at the
  first that gives a usable answer:
  1. `Test-VMHostProfileCompliance -VMHost` — a real check, no `-UseCache`.
  2. **`ProfileComplianceManager.QueryComplianceStatus` via `Get-View`** — the
     source the vSphere Client reads, so it is the authority on what vCenter
     holds. It reads rather than scans, which is correct at this point: route 1
     has already asked for a scan.
  3. `Test-VMHostProfileCompliance -UseCache`.
  4. `Test-VMHostProfileCompliance -Profile`, filtered back to this host. Last,
     because it checks every host attached to the profile.
  When every route declines, the detail names each one and what it returned, so
  the next run says which to fix rather than repeating "no result".
- `Select-ComplianceResultForHost` matches a result to its host on `VMHost`,
  `VMHostId` or an `Entity` managed object reference. Routes 2 and 4 return rows
  for several hosts, and taking the first would report another host's status.
- `Get-ComplianceFailureDetail` reads the differences from
  `IncomplianceElementList` (PowerCLI) or `Failure` (raw API), so a
  non-compliant host says which setting drifted.
- **Post-change verification at cluster completion**, read back from the
  platforms and written to `Post-Change-Verification-<cluster>-<timestamp>.csv`:
  ESXi build against the target, Intersight `ConfigState` with whether anything
  is still staged, and the UCS host firmware package now on each service profile
  with any acknowledgement still open. `Outstanding: None` on every row is the
  result a completed run should show.

#### Fixed

- **Exiting Maintenance mode is confirmed, not assumed.** `Set-VMHost -State
  Connected` returns when vCenter accepts the change, not when the host has
  left Maintenance mode. The cluster health check immediately after fails on any
  host still in Maintenance, so the run stopped one host in — which is what made
  an override look like it had ended the run and gone back to the menu. The run
  now waits up to `$ExitMaintenanceTimeoutMinutes` (default 10) for the
  transition to land, and stops with a clear message only if it never does.
- **Hosts already in Maintenance mode when the run started no longer fail every
  health check.** They are out of scope either way — only Connected hosts enter
  the run — and they are a pre-existing condition rather than something this run
  caused. Recorded at cluster start, excluded from the assessment, and named on
  screen each time so they cannot be forgotten.
- `Get-ComplianceCheckTime` no longer takes a mandatory parameter. When every
  route declined there was no result to pass it, and the binding failure threw
  out of the whole function — precisely the case it needed to survive.

#### Added — tests

- `tests/Test-ComplianceGate.ps1` at 63 assertions: the manager route answers
  when the scan returns nothing, a result for a different host is never used for
  this one, the profile-wide scan runs only once everything else is exhausted,
  every declining route is named in the detail, and a host that will not leave
  Maintenance mode times out rather than being assumed out.
- The workflow simulation now asserts the closing verification covers every
  host with nothing outstanding, and its Intersight stub is stateful — a profile
  reaches `Associated` once deployed, so a completed run can actually come back
  clean.

### [19.1.0] — 2026-08-11

Fixes a defect introduced in 19.0.0: every host reported
`Compliance: Unknown` on a live run even where vCenter showed it compliant
after the scan.

#### Fixed

- **The compliance status is read from wherever PowerCLI put it.** It lands on
  `ComplianceStatus` or `Status`, on the result object or only on its
  `ExtensionData`, depending on the build. Only the first two were read, so a
  build that projects it elsewhere yielded no status at all. All four are now
  read in order, via `Get-ComplianceStatusValue`.
- **The check-time freshness gate is removed.** 19.0.0 compared the result's
  check time against the moment the scan was requested and re-scanned, then
  reported `Unknown`, if it looked older. That comparison fails on
  `DateTimeKind`: a UTC timestamp surfaced as `Kind=Unspecified` and then run
  through `ToUniversalTime()` lands hours in the past in any zone east of UTC,
  so in AEST every result looked stale and every host reported `Unknown`.
  Whether the scan ran is already settled by `Test-VMHostProfileCompliance`
  blocking on the check; the timestamp is now display-only.
  `$HostProfileComplianceScanRetries` is removed with it.

#### Added

- **A second read of the same answer.** If the scan produces no usable status,
  the run fetches the stored result with `-UseCache`. The scan has completed by
  then, so that is this scan's result — the same value the vSphere Client shows
  on the host's Host Profile tab. It is a fallback for reading, never a
  substitute for scanning: the first call still never passes `-UseCache`.
- `ConvertTo-ComplianceStatus` normalises to the three values the vSphere API
  defines — `compliant`, `nonCompliant`, `unknown` — ignoring casing, spaces,
  hyphens and underscores. An unrecognised status is returned as-is rather than
  mapped to `Compliant`, so an unfamiliar value can never become a pass.

#### Notes — SINGLE mode

- No change was needed: SINGLE mode already advances host to host on its own.
  The prompts operators were hitting between hosts were the `C`/`O`/`E`
  compliance prompt, firing on every host because of the `Unknown` defect above.
  `tests/Test-WorkflowSimulation.ps1` now runs a four-host cluster in SINGLE
  mode and fails on any prompt outside the agreed menu items (run mode, upgrade
  mode, batch mode, manual health checks, firmware package creation), so a stray
  gate cannot reappear unnoticed.

#### Added — tests

- `tests/Test-ComplianceGate.ps1` grew to 50 assertions: the status is found on
  `ExtensionData`, the first call never reads the cache, the `-UseCache`
  fallback runs only after the scan, status strings normalise across casing and
  separators, an unrecognised status is not a pass, and an hour-old check time
  no longer overrides a `Compliant` result.
- The workflow simulation's `Get-UcsLsmaintAck` stub is now stateful — it raises
  an acknowledgement once a service profile's firmware policy changes, as UCSM
  does. Returning an empty list unconditionally made every UCS-only batch take
  the "nothing was staged" path, which is what SINGLE mode exposed.

### [19.0.0] — 2026-08-11

Two changes to what returns a host to production, plus the firmware package is
no longer created with versions this script invents. Both change behaviour an
operator relies on, hence the major bump.

#### Added

- **A settle wait before the first compliance scan of each batch.**
  `$HostProfileComplianceSettleMinutes` (default 2) is waited once per batch,
  after the reconnect gate confirms every host is back. A host that has just
  re-registered is still starting — hostd, the profile engine, and on a
  stateless host the Auto Deploy answer file — and a scan run through that
  window reports differences that clear themselves a minute later. Press `C` to
  scan immediately or `E` to exit. Recorded under its own
  `HostProfileComplianceSettle` stage, so it never inflates the per-host
  compliance rows.
- **An override at the compliance prompt.** A non-compliant host now offers
  `C` to re-scan after remediating, `O` to accept the host as it is and return
  it to service, or `E` to exit. `O` is announced on screen and recorded in the
  run summary as `Overridden`, naming the status that was accepted — it is a
  decision with a record, not a silent pass.
- `Wait-VMHostProfileComplianceTask` drains a compliance check vCenter or Auto
  Deploy started itself before this run starts its own, so the scan that answers
  is the one whose result is acted on. Best effort; the freshness check below is
  the actual guarantee.
- `Get-ComplianceCheckTime` reads the result's check time from the object or
  from `ExtensionData`, and reports `$null` rather than guessing where the
  PowerCLI build exposes neither.

#### Changed

- **The compliance scan must complete, and must be fresh.** `-UseCache` is never
  passed — that switch is what makes `Test-VMHostProfileCompliance` return the
  stored result instead of checking. The result's check time is then compared
  against the moment the scan was requested; a result older than the request is
  re-scanned up to `$HostProfileComplianceScanRetries` (default 3) times and, if
  it stays stale, reported as `Unknown`. A pre-reboot `Compliant` would release
  a host on the strength of its old configuration, so it is never accepted.
- **A missing host firmware package is created by name only.**
  `$Global:UcsFirmwarePolicyByFabricFamily` is now family → package name, with no
  bundle versions, and `Add-UcsFirmwareComputeHostPack` is called without
  `-BladeBundleVersion` or `-RackBundleVersion`. The package takes its versions
  from the global firmware setting its name refers to; versions written from here
  would pin it to whatever was current when this script was last edited and then
  disagree with that setting silently. The `Get-UcsFirmwareDistributable`
  bundle-availability warning goes with them — there is no longer a bundle string
  to check.
- `Read-ChoiceExit` accepts `E` as `EXIT`, so the single-letter prompts read the
  same way as the timed waits. No prompt offers `E` as a choice of its own, so
  the alias cannot shadow a real answer.
- The compliance status object now carries `CheckTime`, and the per-host line
  shows when the result was actually produced.

#### Added — tests

- `tests/Test-ComplianceGate.ps1` — 36 assertions: `-UseCache` is never passed,
  in-flight checks are drained, a stale `Compliant` becomes `Unknown` after
  retrying, a stale result that goes fresh is accepted, a build reporting no
  check time is taken at face value, `C` keeps the host in Maintenance mode
  until it passes, `O` releases it and records `Overridden`, `E` exits leaving it
  in Maintenance mode, and DRY RUN neither waits nor scans.
- `tests/Test-UcsFabricFamily.ps1` asserts creation writes no bundle version, and
  greps the whole script for `-BladeBundleVersion`/`-RackBundleVersion` so a
  reintroduction fails even on a path no test walks.
- `tests/Test-WorkflowSimulation.ps1` throws if `-UseCache` is bound or if a
  bundle version reaches `Add-UcsFirmwareComputeHostPack`, and asserts the settle
  ran before every batch's scan.

#### Notes

- 302 assertions across 12 standalone suites, all passing. PowerShell is not
  installed in the Claude Code web sandbox where the edits were made, so the
  suites were run under `pwsh` 7.4.6 there but nothing was linted with
  `Invoke-ScriptAnalyzer` and nothing ran against live infrastructure.

### [18.0.0] — 2026-08-11

The UCS firmware policy is no longer chosen by the operator. It is derived from
the fabric interconnect family, which removes a decision that could be made
wrong — hence the major bump.

#### Added

- `Get-UcsFabricFamily` reads the fabric interconnect model from the connected
  UCSM domain via `Get-UcsNetworkElement` and derives the family from it:
  `UCS-FI-6454` and `UCS-FI-64108` to 6400, `UCS-FI-6332` and `UCS-FI-6332-16UP`
  to 6300, `UCS-FI-6248UP` to 6200, `UCS-FI-6536` to 6500. Both fabric
  interconnects are read; if they disagree the family is `Mixed` and the run
  stops rather than guessing.
- `$Global:UcsFirmwarePolicyByFabricFamily` maps family to host firmware package
  and, for creation only, to bundle versions:
  - **6400** → `global-602d` (blade `6.0(2d)B`, rack `6.0(2d)C`)
  - **6300** → `global-436h` (blade `4.3(6h)B`, rack `4.3(6h)C`)
- `Resolve-UcsFirmwarePolicyForTarget` resolves the package per UCSM domain,
  reusing it if present. If missing, it warns when the bundle is not among the
  firmware downloaded to the fabric, shows exactly what it will create, requires
  a typed `CREATE`, creates the package at `org-root` so any organisation can
  reference it, and reads it back before continuing. DRY RUN never creates.

#### Changed

- **The interactive firmware policy picker is removed.** No `Out-GridView`, no
  numbered list, no manual policy name.
- **The policy is per UCSM domain, not per cluster.** A cluster spanning a 6300
  and a 6400 domain now gets the correct package in each; previously one policy
  was chosen from the first domain and applied to all of them.
- `$FirmwareReconnectInitialWaitMinutes` raised from 25 to 40.

#### Added — tests

- `tests/Test-UcsFabricFamily.ps1` — 25 assertions covering the model strings
  Cisco ships, mixed and unreadable fabrics, reuse of an existing package,
  creation with the right org and bundle versions, per-domain caching, declining
  creation, an unmapped family, and DRY RUN creating nothing.
- The workflow simulation now asserts the fabric family was detected and drove
  the policy.

#### Notes

- The bundle versions are only used when creating a missing package, and are
  assumed to follow the `<version>B` / `<version>C` convention. They must already
  be downloaded to the fabric interconnect — a package referencing absent
  firmware applies cleanly and upgrades nothing. Verify with
  `Get-UcsFirmwareDistributable`.

### [17.4.0] — 2026-08-11

#### Removed

- **The pre-flight confirmation prompt.** It asked whether Intersight was in
  scope and gated the run on the answer, which the detection phase already
  determines from CDP/LLDP without being told. The pre-flight is now purely
  informational and asks nothing.

#### Changed

- Requirements are stated as four numbered items, in the script header and
  printed at the start of a run:
  1. **PowerShell modules** — PowerShell 7 Core, PowerCLI 12.3.0+, exactly one
     `Intersight.PowerShell` matching the appliance, UCS PowerTool if any host is
     UCSM-managed. Nothing is imported.
  2. **Intersight API key** — for the pre-authenticated build, already applied in
     the session; for the main build, the Key ID and `.pem` it prompts for.
  3. **Intersight input file** — the CSV path, its `Name` column, the optional
     `ServerProfileName` and `Moid` columns, and what a match means. The printed
     version reports whether the file is actually present at that path.
  4. **Credentials** — vCenter and UCS Manager.

#### Notes

- Still nothing is verified at start-up. Failures surface where they matter: a
  missing module at its first cmdlet, a bad Intersight connection before any host
  is touched, a missing CSV at import.

### [17.3.0] — 2026-08-11

#### Removed

- **Every `Import-Module` call.** The scripts assume a prepared jump host:
  loading modules is the host build's job, PowerShell auto-loads what it needs on
  first use, and an import here either duplicates that or fights a pinned bundle
  already loaded into the session.

#### Changed

- The PowerCLI load diagnostics survive the removal. Auto-loading still happens
  on the first `Connect-VIServer`, so the catch there recognises the "command was
  found in the module ... but the module could not be loaded" message and reports
  the same causes and fixes it did before: blocked module files, a PowerCLI
  version predating PowerShell 7 support, folder permissions, and Group Policy
  signing requirements.
- The `REQUIREMENTS` header now states that modules must be present *and already
  importable*, and that nothing is imported at run time.

#### Added

- A lint rule forbidding `Import-Module` in the controllers and the API key
  checker, so it cannot creep back. `tools/Import-RichoModuleBundle.ps1` is
  exempt — importing a pinned bundle is its entire purpose.

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

### [19.4.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 19.4.0 — the cluster health
gate no longer counts local datastores or acknowledged alarms, names what
failed, and offers RECHECK/OVERRIDE/STOP. This is the build to run.

### [19.3.1-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 19.3.1 — the printed
`Import-Module` suggestion is gone. This is the build to run.

### [19.3.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 19.3.0 — the manual health
check prompt moves into the requirements, `RequiresDeploy=false` is carried on
through, and the closing verification compares the UCS end-state firmware
version. This is the build to run.

### [19.2.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 19.2.0 — four routes to the
compliance status, a confirmed exit from Maintenance mode, and the post-change
verification at cluster completion. This is the build to run.

### [19.1.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 19.1.0 — the compliance
status read is fixed and the check-time freshness gate is gone. This is the
build to run.

### [19.0.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 19.0.0 — the compliance
settle wait, the completed-and-fresh scan guarantee, the `C`/`O`/`E` prompt, and
host firmware packages created by name only. The two builds differ only in the
five functions listed in `tests/Test-PreAuthVariantParity.ps1`, which is
enforced on every run of that suite.

This is still the build to run. It does not authenticate to Intersight; it
assumes `Set-IntersightConfiguration` has already been applied in the session,
and verifies the resulting connection before any host is touched.

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
