# Changelog

Notable changes to the automation in this repo. Versions are tagged in git
(`git tag -l`), and each script carries its own `$ScriptVersion`, which is
stamped onto every row of the run summary and verification CSVs — so a change
record can always be traced back to the revision that produced it.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [semantic](https://semver.org/) per script.

---

## Invoke-AutoDeployFirmwareBatchControl.ps1

### [23.4.1] — 2026-08-13

#### Fixed

- **23.2.0's preflight turned a working run into a failing one on every start.**
  Reported live as:

  ```
  Set-IntersightConfiguration failed: Error performing this operation. Check that
  BasePath and API Key identifier are configured correctly...
  ```

  My fault, and a plain regression. `Set-IntersightConfiguration` writes a
  **non-terminating** error in some paths and applies the configuration anyway.
  Before the preflight the call had no `-ErrorAction` at all, so that error went
  past unnoticed and the run worked. Adding `-ErrorAction Stop` promoted it to
  terminating and aborted every run.

  The rule this block already followed cuts both ways, and I only implemented
  half of it: *the call returning is not proof it took* — and equally **the call
  erroring is not proof it did not**. The **read-back is the authority**:

  - configuration active → the run continues, and the error is shown as a
    warning rather than being hidden;
  - configuration not active → the run stops, with the reported error included as
    the explanation.

  The failure message now also names the three distinct faults that generic
  message actually covers: a key file that is not a usable PEM, an API Key ID that
  does not match the secret it was issued with, and more than one installed
  version of `Intersight.PowerShell`.

### [23.4.0] — 2026-08-13

#### Fixed

- **A host firmware package created by the run is now handed to UCS Central
  instead of being left local.** UCSM created the package correctly and left
  `Owner: local`. That matters more than it looks: the package is created **by
  name only, with no bundle versions**, because the versions are meant to come
  from the global policy. Left local it is an empty package — it applies cleanly,
  changes no firmware, and the run reports success having upgraded nothing.

  Verified against Cisco's own `ucsmsdk` metadata for `firmwareComputeHostPack`:

  ```
  "policy_owner": MoPropertyMeta(..., MoPropertyMeta.READ_WRITE, ...,
                                 ["local", "pending-policy", "policy"], [])
  ```

  So `policyOwner` is a read-write property with exactly three values — `local`
  (owned by the domain), `pending-policy` (handed over, UCS Central has not taken
  it yet — UCSM's *"Pending Global"*), and `policy` (controlled by UCS Central).
  **"Use Global" is a write of that property**, and the GUI's *"Do you want to make
  this policy controlled by UCS Central?"* confirmation is the write itself; there
  is no separate acknowledgement object to set afterwards.

  The run now writes `policyOwner = "policy"` immediately after creating the
  package, then **reads the owner back**. `policy` and `pending-policy` are both
  accepted — pending is the normal intermediate state, not a failure. Still
  `local` means an empty package is about to be attached to service profiles, so
  that is put to the operator (`C` to continue anyway, `X` to stop) and recorded
  for manual rectification rather than carried on through silently.

#### Changed

- **The ESXi root password prompt is no longer gated behind a review step.** It
  went straight to a `Y`/`S` question before the credential dialog; the answer is
  always yes, so it only added a keystroke to every run. The credential dialog
  appears directly, and cancelling it is the way out.

### [23.3.0] — 2026-08-13

#### Added

- **A host that comes back Disconnected is reconnected with the ESXi root
  password.** The reported failure: the host reboots, returns, and vCenter cannot
  re-establish its connection because the password it holds for that host no
  longer works. vCenter will not recover it on its own, so the run waited out its
  entire window for something that was never going to resolve.

  - **The password is asked for when the cluster is selected**, not when it is
    first needed — by then a host is already down and evacuated, which is the
    worst moment to go hunting for a credential.
  - A host seen `Disconnected` or `NotResponding` for
    `$HostReconnectAfterDisconnectMinutes` (**5**) is reconnected: first with
    vCenter's own stored credentials (free, and enough for a transient drop), then
    with `ReconnectHost_Task` carrying the root credential — the vSphere API's own
    operation for a stale password.
  - **Never a remove-and-re-add.** That would take the host's VMs out of inventory
    with it. A test asserts `Remove-VMHost` and `Add-VMHost` appear nowhere in the
    reconnect path.
  - Once reconnected the host goes through the **same return check as every other
    host** — it earns its way through settle and compliance rather than being
    waved past them.
  - Declining the prompt is allowed: a disconnected host is then reported for
    manual rectification, which is exactly the old behaviour, so skipping costs
    nothing that was not already the case.
  - The credential is held **in memory only**, cleared when the cluster changes,
    and never written to the log or the run summary. The password leaves the
    `PSCredential` only at the point it is handed to the API.

### [23.2.0] — 2026-08-13

#### Fixed

- **The first run of every new session failed; the second worked.** The script
  imports nothing, relying on PowerShell to auto-load on first use — but
  auto-loading depends on the command discovery cache, and building that cache
  means scanning every path in `$env:PSModulePath`. `Intersight.PowerShell` is a
  large binary module, so from a cold cache (new session, network module path,
  slow profile share) the first reference resolves *before* the scan finds it and
  the cmdlet reads as **"not recognized"**. The scan completes afterwards, which
  is why a re-run in the same session works.

  The module is now loaded once in the AUTHENTICATION region, **guarded by
  `Get-Module`** so it does nothing when already present and cannot duplicate or
  fight a pinned bundle. This is the only permitted load in the script, and
  `Test-ScriptLint` now enforces both that it stays the only one and that it stays
  guarded.

- **The authentication block announced success whatever happened.** It called
  `Set-IntersightConfiguration` with no error handling, set the once-per-session
  flag, and printed *"configuration applied"* unconditionally — so a session
  without the module reported success, failed much later with *"Intersight
  environment is not configured"*, and then told the operator on retry that it was
  *"already applied, start a fresh session"*. Three misleading messages from one
  unchecked call. Now:
  - a **preflight** checks the PowerShell edition, that the cmdlet resolved, and
    that the API key file is reachable **from this account** — the key lives on a
    network share, so a different user is exactly the case that breaks;
  - failures are listed with the fix for each, and the run stops;
  - the configuration is **read back** and compared to what was asked for, which
    catches the `Active BasePath: https://intersight.com` case directly;
  - the session is **not** marked configured unless it genuinely worked, so a
    retry in the same session can try again.

#### Changed

- **AUTO is capped at half the cluster, not a fixed 6.** `$MaxConcurrentHostFraction`
  (default `0.5`) replaces the hard cap; `$MaxAbsoluteBatchSize` remains as an
  optional absolute ceiling and defaults to `0` (none). On a 24-host cluster the
  old 6 was an arbitrary throttle well below what the cluster could carry.

  Capacity, DRS headroom and the resource safety buffer are **unchanged and still
  the primary constraint** — they normally bind first. The fraction only stops a
  large, idle cluster being emptied faster than DRS and storage can keep up with.

  Hosts already in Maintenance mode are **exempt** from the ceiling: they are
  already out of service, so capping them would only strand them un-upgraded.
  They are added on top of the connected half-cap.

### [23.1.0] — 2026-08-12

#### Fixed

- **The deploys were still going out one host at a time.** 22.0.0 made the
  *activation* concurrent, but the deploy loop still called
  `Confirm-IntersightDeployAccepted` per host **inside** the loop — a blocking
  poll of up to `IntersightDeployAcceptedTimeoutSeconds` (180 by default). So
  host 2's deploy was not even *sent* until host 1's confirmation window had
  closed. Six hosts serialised into six windows — up to 18 minutes — before the
  last blade had been touched.

  Now the loop **sends every deploy back to back**, and the whole batch is
  confirmed afterwards in **one shared window** by
  `Confirm-IntersightDeployAcceptedForBatch`. Each profile drops out of the poll
  as it settles, so a fast one is not re-read while a slow one finishes, and the
  batch costs one window regardless of its size.

  `Confirm-IntersightDeployAccepted` is retained as a single-row wrapper over the
  batch version, so there is one implementation of "did the appliance pick the
  deploy up".

### [23.0.0] — 2026-08-12

#### Changed

- **The cluster is upgraded as a ROLLING WINDOW, not in discrete batches.** As
  each host comes back healthy, its slot is refilled from the remaining hosts —
  within whatever live capacity allows.

  The batch loop did not start host N+1 until the **slowest** of the first N had
  finished, so a host back in twenty minutes sat idle while its neighbour took
  fifty. Every host is now tracked on its own through
  `AwaitingReturn → Settling → Compliance → Done`, and a freed slot is refilled
  on the next pass.

  - **Admission is re-read from live capacity every pass.** The same arithmetic
    as before — `Get-CapacityBasedBatchSize` already counts hosts in Maintenance
    as free and sizes from the connected hosts' live load — now used as a
    *concurrency limit* rather than a batch size. It reads the **whole cluster**,
    not just the hosts still waiting: sizing from the remainder understates
    capacity as the run progresses, because a host finished an hour ago is
    carrying load and contributing capacity again.
  - **Each host settles from its own return time**, so the settle windows overlap
    instead of costing `HostProfileComplianceSettleMinutes` once per host in
    series.
  - **The firmware phase no longer blocks.** The deploy and activation are sent
    (`-NoWait`) and the loop moves on; the readiness signal is the host
    reappearing in vCenter, which is what the vCenter work waits on anyway.
    Blocking there is precisely what would stop the next host being admitted.
  - **A halt still halts everything.** A host profile that will not apply pauses
    admission as well — that is a reason to stop feeding hosts in, not to carry
    on regardless.
  - **SINGLE mode is the same engine with the limit fixed at one**, so the two
    modes cannot drift. Its behaviour is unchanged: one host, complete, next.

- `Confirm-HostProfileComplianceAndExitMaintenance` split: the per-host half is
  now `Confirm-SingleHostComplianceAndExit`, which does **not** settle (its caller
  owns that). The batch entry point still settles once and then calls it per host,
  so that path is unchanged.

#### Fixed

- **A null `PreRebootBootTimes` map was swallowed into "the host has not
  returned".** `.ContainsKey` on `$null` threw inside a `try`, the `catch`
  returned `$false`, and the host could never be seen to come back — an infinite
  wait from a one-line omission. A null map now reads as "no baseline", which is
  what it means. Found by the rolling engine hitting it.
- **The return ceiling is floored at 5 minutes.** Built from
  `FirmwareReconnectInitialWaitMinutes + IntersightActivationHoldMinutes`, it
  would be `0` if either were unset — putting "this host has not returned" on
  screen before the host had any chance to.

### [22.1.0] — 2026-08-12

#### Added

- **When Intersight will not report a ConfigState, vCenter is asked instead.** A
  live run sat out twenty minutes of its ceiling on `the profile ConfigState
  could not be read` for a host that was already back and healthy, then had to be
  moved on by hand. Intersight staying silent is not evidence of anything — but
  the **host being back** is. If it is in inventory, `Connected` or in
  `Maintenance`, and its **boot time differs from the baseline** captured before
  any action, the activation plainly happened and the run moves on.

  The boot time is the part that matters: "the host is Connected" cannot tell
  *came back* from *never left*, and on a firmware run that is the difference
  between upgraded and not. Where no baseline exists — nothing was ever sent for
  that host — presence is accepted, because there is no restart to prove.

  This is a **read**, and the only vCenter call anywhere in the activation path.
  Nothing is changed there: no Maintenance mode transition, no reboot, no
  migration. A test asserts that `Set-VMHost`, `Restart-VMHost` and `Move-VM`
  appear nowhere in it.

#### Changed

- **Every prompt is now a single key.** `C` continue, `R` retry/recheck, `S`
  skip, `X` stop, `O` override, `Y`/`N`, `E` exit — consistently, everywhere,
  replacing `RETRY`/`CONTINUE`/`RECHECK`/`OVERRIDE`/`SKIP`/`STOP`/`CREATE`/`YES`/
  `NO`. Prompts read `[R/C or E to exit]`.

  The full words are still accepted as aliases, so an operator typing `CONTINUE`
  out of habit is not told they are wrong halfway through a change window — but
  the screen only ever asks for one letter. The free-text prompts (UCSM FQDN,
  service profile name) keep taking a value, with `E` and `S` as their escapes.
- **The heartbeat only prints when the minute changes.** At a 30-second poll
  interval it printed the same `still going - 20 minute(s) remaining` line twice
  a minute for the length of the ceiling.

### [22.0.0] — 2026-08-12

#### Changed

- **The whole batch is now activated at once.** The hosts are evacuated together,
  so they are upgraded together: every deploy in the batch is sent, then every
  activation, then all of them are watched in **one** polling loop. A batch takes
  as long as its **slowest** host instead of the sum of them.

  Host-by-host meant a batch of six gave up six hosts' capacity up front and then
  got them back one at a time — the worst of both arrangements, and up to six
  activation windows end to end.

  Whatever has not finished at the ceiling is put to the operator **once for the
  batch**, listing each outstanding profile and its phase. Not once per host: six
  prompts for one decision is how an operator ends up answering without reading.
  `RETRY` re-sends `Activate` to only the profiles still outstanding.

  SINGLE mode is a batch of one through the same function, so the two modes cannot
  drift.
- **`SAVE ONLY / NO ACKNOWLEDGEMENT` removed from the run mode menu.** LIVE and
  DRY RUN only. It staged firmware without ever restarting anything, leaving every
  host carrying a pending change for someone to finish by hand — a half-done state
  this run had no way to report on afterwards. `Test-StageNoAck` is retained and
  returns `$false` everywhere, so the branches that guarded against it stay
  harmless; nothing can select the mode.

#### Fixed

- **`@($list)` on a `Generic.List[object]` again**, this time in the batch
  activation poll — the same trap as 21.7.0's closing report, and it would have
  thrown on the first poll of every Intersight batch. **A lint rule now enforces
  it.** Only `List[object]` is affected (`List[string]` and `List[int]` wrap
  fine — verified directly), so the rule targets that type only, scoped to each
  variable's own enclosing function; a file-wide match flagged an unrelated
  `ArrayList` of the same name. Verified to bite by reintroducing the fault.
- **No speculative outcome record.** A host that had not finished when the ceiling
  was reached was recorded as `PowerCycled` *before* the operator decided, putting
  a guess ahead of the real outcome for the same host. The decision now writes the
  single record.
- **`IntersightActivationHeldForBatch` is only claimed when something was actually
  sent or completed.** Setting it after a refused activation would have vCenter
  polled for a host that never restarted.

#### Verified

- **ESXi-only mode touches neither UCS Manager nor Intersight.** It was already
  gated correctly; there was no test saying so. The simulation now runs a full
  ESXi-only cluster and asserts that `Connect-Ucs`, `Set-UcsServiceProfile`,
  `Set-UcsLsmaintAck`, `Add-UcsFirmwareComputeHostPack`,
  `Set-IntersightServerProfile`, `Set-IntersightComputeServerSetting` and
  `Set-IntersightConfiguration` are never called, that any UCSM/Intersight prompt
  fails the test outright, and that the hosts are still evacuated, rebooted from
  vCenter, and taken through the host profile gate.

### [21.9.0] — 2026-08-12

A live run ended with:

```
Cannot deploy the server profile. The server is disconnected.
messageId: gershwin_server_is_not_connected
```

The server was **not** disconnected. Intersight and vCenter both showed it
healthy. This was a fault in this script.

#### Fixed

- **A server profile name is not unique in Intersight, and the lookup was taking
  the first match.** `Get-IntersightServerProfileByName` did
  `Name eq '<name>'` then `Select-Object -First 1`. The same name exists across
  organizations, and a decommissioned or template-derived copy commonly sits
  alongside the live one — so the run could resolve to a profile with **no server
  on it**. Deploying that is refused with the message above, because "no server"
  and "server disconnected" are the same refusal from the appliance's side. The
  healthy blade the operator then goes looking at belongs to the *other* profile.

  Now: one match is used; several, and the one **associated with a server** wins,
  announced with its Moid. If several qualify, or none do, nothing is guessed —
  the Moids are listed and the caller is told to pin the right one via the `Moid`
  column of the Intersight CSV. Guessing there is how the wrong blade gets
  rebooted.
- **The resolved Moid is now printed, not just the name.** Without it, resolving
  to the wrong profile of the right name is invisible in the log — which is why
  this took a live failure to find.
- **A refused deploy no longer ends the run.** It called `Stop-WithMessage`, so
  one host killed the whole batch with every other host already evacuated, in
  Maintenance mode, un-upgraded and unreported. Now the host is set aside, the
  rest of the batch continues, and it lands in the manual rectification report —
  the same treatment 21.7.0 gave unreachable hosts. Its boot-time baseline is
  cleared too, so the reconnect gate does not wait out its window for a restart
  that was never requested.

#### Added

- **Refusals are classified rather than flattened to "deploy failed".** Each is a
  different job for a different person: `gershwin_server_is_not_connected`,
  `gershwin_user_action_is_not_allowed`, and an upgrade already in progress.
  Anything unrecognised keeps the appliance's own words — no cause is invented.
- **A pre-flight reads whether the profile has a server before deploying**, and
  that finding decides how a disconnect refusal is reported: no server found →
  *"deployed against a profile with no server on it"*, pointing at the CSV `Moid`
  column; server found → genuine connectivity, pointing at the device connector
  and Fabric Interconnect.

  The pre-flight is **diagnostic, not blocking**. An unreadable `AssignedServer`
  relationship is not proof a profile is unassigned — this SDK has hidden that
  Moid behind wrapper shapes before — so the deploy is still attempted. Skipping
  a healthy host on that basis would trade one silent fault for another. The
  workflow simulation caught the first, stricter version doing exactly that.

### [21.8.1] — 2026-08-12

Housekeeping after an audit of the script's size and hot paths.

#### Fixed

- **One redundant Intersight round trip per poll, per host.** 21.8.0's activation
  poll read the server profile twice: once with `-Expand RunningWorkflows` for the
  workflow, then again for `ConfigState`. The expanded read already carries
  `ConfigContext`, so the second GET was pure waste — 3 calls per poll where 2 do.
  At a 30-second interval against the 60-minute ceiling that is up to 120 fewer
  calls per host. The unexpanded fetch remains as the fallback for when the
  workflow read does not answer.

#### Removed

- `Read-YesNoExit` and `Resolve-UcsTargetForHost` — defined, never called. Both
  were superseded (by `Read-ChoiceExit` and by the CDP/LLDP discovery in
  `Build-InfrastructureHostMapping`) and had been carried since.

### [21.8.0] — 2026-08-12

The 60-minute waits are gone as a *mechanism*. Progress through the activation is
now driven by what Intersight reports, phase by phase, and the run moves on the
moment the work is done — five minutes or fifty.

#### Added

- **The workflow engine is polled.** Per the Intersight SDK, `server.Profile`
  carries `RunningWorkflows` — *"the WorkflowInfos in the workflow engine that are
  running for this server Profile"*. Read with `-Expand RunningWorkflows`, that
  gives the deploy/activate workflow by **name, status and percentage complete**,
  so the console shows `workflow 'Deploy Server Profile' is running - 45%
  complete` instead of a countdown.
- **Both of Cisco's status enum families are read.** `workflow.WorkflowInfo`
  exposes `Status` (`RUNNING`, `WAITING`, `COMPLETED`, `TIME_OUT`, `FAILED`) on
  some releases and `WorkflowStatus` (`NotStarted`, `InProgress`, `Waiting`,
  `Completed`, `Failed`, `Terminated`, `Canceled`, `Paused`) on others. Reading
  one family only is how a finished workflow reads as never having started, so
  both are normalised, separators stripped — `TIME_OUT` and `TimedOut` land in
  the same place.
  `WAITING` and `Paused` normalise to **Running, not Failed**: a workflow waiting
  on a reboot acknowledgement is the state this run creates on purpose.
- **A failed workflow stops the wait immediately.** `Failed`, `Terminated` and
  `TimedOut` end it there and then, naming the workflow. There is nothing to gain
  from holding another hour for something the engine has given up on.
- `$Global:IntersightPollIntervalSeconds` (default 30).

#### Changed

- **`Wait-IntersightActivationComplete` now checks three signals**, and names the
  phase from the first one still busy:
  1. the workflow engine (`RunningWorkflows`);
  2. the firmware upgrade (`firmware/Upgrades` with `Status eq 'IN_PROGRESS'`, the
     GUI's own query);
  3. the profile's `ConfigState`.

  Complete means **all three** agree. Any one still busy keeps the wait alive —
  which is the substantive fix: a finished firmware task and a settled profile
  used to be enough, so a still-running deploy workflow could be walked past.
- **`IntersightActivationWaitMinutes` and `IntersightActivationHoldMinutes` are
  ceilings, not sleeps.** Reaching one is not a failure; it hands the decision
  back to the operator, and the summary records the phase it gave up in rather
  than a bare "not activated".
- **The fixed stand-off between retries is gone.** `Wait-IntersightActivationCheckIn`
  slept 60 minutes and then looked once. It has been deleted; the retry path polls
  instead. A round where `Activate` is refused now polls anyway — the appliance may
  already be doing the work, in which case there is nothing to re-send and
  everything to wait for.
- **vCenter is polled straight after**, with no fixed pre-wait, because Intersight
  has already reported the reboot complete. That path already existed
  (`IntersightActivationHeldForBatch`); it now triggers off a confirmed completion
  rather than an elapsed timer.

#### Unchanged

An unreadable signal is still never read as completion. If the workflow engine
will not answer, the firmware task and `ConfigState` must still both agree before
the wait returns true — and a profile that does not report `RunningWorkflows` at
all is `Known=$false`, not "nothing is running".

### [21.7.0] — 2026-08-12

#### Fixed

- **One host that cannot be driven no longer costs the whole cluster.** A
  `NotResponding` or `Disconnected` host returns no CDP/LLDP, so it fell through
  to the manual-UCSM-target prompt and then to a hard stop on the unresolvable
  service profile — taking every other host in the cluster with it. Such a host
  is now **set aside**, not stopped on: the rest of the cluster is upgraded and
  the host is named at the end.
  The same now applies to the two other dead ends: the manual UCSM target prompt
  accepts **SKIP** alongside an address and EXIT, and a host UCS Manager returns
  no service profile for is set aside instead of ending the run.

#### Added

- **A `HOSTS REQUIRING MANUAL RECTIFICATION` report, printed when the cluster
  completes.** Every host the run could not finish, with the reason:
  - set aside during discovery — unreachable, no CDP/LLDP target, or no service
    profile;
  - host profile compliance overridden;
  - left in Maintenance mode;
  - firmware activation not confirmed, or the profile had no associated server;
  - Intersight `ConfigState` unreadable;
  - still outstanding on the platforms at post-change verification, or not back
    in service.

  Hosts that were **never batched** are called out separately as NOT UPGRADED —
  the distinction between "needs a look" and "did not happen at all". Every row
  is also written to the run summary CSV under a `ManualAttention` stage, so the
  change record does not depend on someone having watched the console.

  It prints even when empty — "nothing outstanding" is a result worth stating,
  and a report that only appears on failure is one nobody trusts is running — and
  closes with the reminder to re-enable the two host profile Security settings.

#### Fixed (found by the workflow simulation, not by reasoning)

- `@($list)` on a `Generic.List[object]` throws *"Argument types do not match"*
  on this PowerShell build. The closing report used it, so it would have thrown
  **after the cluster had completed** — the worst place to learn it. Now
  `.ToArray()`.
- `New-Object System.Collections.ArrayList` with a piped `ArgumentList` binds to
  the wrong constructor overload and throws the same error. The discovery-row
  rebuild is now an explicit loop.

### [21.6.0] — 2026-08-12

#### Fixed

- **Hosts already in Maintenance mode are in scope**, for both the Intersight
  and the UCS Manager paths. They were filtered out by
  `ConnectionState -eq "Connected"` and reported as "out of scope for this run",
  which quietly left them on old firmware while the run reported the cluster
  complete — the worst kind of miss, because it looked like a success.

#### Changed

- **They are taken first.** Already evacuated means nothing to wait for and no
  capacity to free, so they head the queue and everything after them keeps the
  cluster order.
- **Batch sizing treats their slots as free.** `Get-CapacityBasedBatchSize` now
  splits candidates into connected and parked: parked hosts are added on top of
  whatever the connected hosts can afford, still capped at
  `MaxAbsoluteBatchSize`. Three consequences, all deliberate:
  - a cluster too busy to spare a single connected host still processes its
    parked ones instead of stopping on capacity;
  - a batch made up entirely of parked hosts is always safe and is never
    refused — refusing it would strand exactly the hosts this change was asked
    to capture;
  - `NotResponding` and `Disconnected` stay out of scope. There is nothing to
    drive through vCenter on a host it cannot reach, and that is the distinction
    the previous filter was conflating with Maintenance.

#### Note

At the end of its batch a previously-parked host goes through the same host
profile compliance gate as every other host and, once it passes, **is taken out
of Maintenance mode**. A host parked deliberately for an unrelated reason will
be returned to service by this run. That is stated on screen at the start of the
run, naming the hosts, rather than left to be discovered afterwards.

### [21.5.0] — 2026-08-12

Operator-directed changes after a clean 21.4.0 run.

#### Changed

- **The 40-minute waits are now 60 minutes**, to cover the firmware activity
  itself: `IntersightActivationWaitMinutes` (the stand-off between activation
  checks), `IntersightActivationHoldMinutes` (the hold after the activation
  lands) and `FirmwareReconnectInitialWaitMinutes` (the post-reboot wait before
  vCenter is asked). The third was not named in the request but is the same
  40-minute wait on the same firmware activity, and leaving it behind would have
  had the run start looking for a host 20 minutes before the activation window
  it was just told to allow.
- **The host profile compliance settle is 8 minutes, up from 2.** Two minutes
  was not covering the profile engine's own work on a freshly rebooted host, so
  the first scan was answering too early.

#### Added

- **Compliant is now the only status that continues on its own.** Anything else
  — `NonCompliant`, `Unknown`, or `NoProfile` — halts the run with the host still
  in Maintenance mode and the batch not advancing, and tells the operator to
  resolve the host profile issue manually in vCenter before continuing. `C`
  continues: the host is re-checked, and **once it reports Compliant it comes
  out of Maintenance mode and the run carries on by itself**, with no further
  prompts. `O` overrides and returns the host to service as it is. `E` exits
  safely.
  `NoProfile` previously took a `SKIP` prompt of its own; it is on the same gate
  now, since "no profile attached" is no more evidence the profile applied than
  `NonCompliant` is — and the engineer may simply need to attach it, which `C`
  then re-checks.
  Identical in SINGLE and AUTO. SINGLE is a batch of one through the same loop,
  so an Intersight host is gated the same way whichever mode selected it — no
  separate code path, and none needed.
- **A pre-requisite to untick two host profile Security settings** before
  starting: **Authentication Configuration** and **Active Directory
  Permission**. Left ticked, the profile does not apply cleanly to a host that
  has just rebooted and rejoined, and the compliance gate halts on it. Stated in
  the script header and in the on-screen requirements, both of which say in as
  many words that **both must be re-enabled after the upgrade** — the run does
  not change them and does not put them back.
  The compliance halt itself names the same two settings, so the engineer is not
  left to remember a pre-requisite from the start of the run while looking at a
  profile that will not apply.

### [21.4.0] — 2026-08-12

21.3.0 deployed but never activated. A live run sat in this loop indefinitely,
with the deploy long since finished:

```
Intersight reports 1 firmware upgrade(s) IN_PROGRESS for this server.
Check 2 : the firmware task on server 67a3ff8f617675301fa27ff6 is still running.
Standing off for 40 minute(s) ...
```

#### Fixed

- **The activation is no longer gated on the firmware task finishing.** That
  gate was a deadlock of the script's own making. The `firmware.Upgrade` sits at
  `IN_PROGRESS` *because* it is waiting for the reboot acknowledgement — and
  `Activate` **is** that acknowledgement. Waiting for the upgrade to finish
  before sending it meant the only thing that could end the upgrade was being
  withheld. Every round now re-reads the profile, and if it is still pending,
  sends `Activate` immediately.
- **The power cycle stays as the fallback, and keeps its guard.** A power action
  genuinely is refused mid-upgrade
  (`action_not_allowed_firmware_upgrade_in_progress`), so it is attempted only
  when `Activate` was refused *and* no upgrade is running. That refusal was the
  observation the 21.3.0 gate was wrongly generalised from: it is true of power
  actions, and false of `Activate`.
- **The prompt now describes what it is waiting on.** "the firmware task has not
  finished" became "'<profile>' has not activated yet", and `RETRY` re-sends
  `Activate` rather than re-reading a task that will not move on its own. There
  is still no cap and no timeout, and `CONTINUE` still moves to the vCenter
  checks without ending the run.

#### Fixed (structural)

- A stray brace closed the activation `while` loop one statement early, so the
  stand-off, the prompt and the retry sat outside the loop they belong to.
  `RETRY` could never have looped back.

### [21.3.0] — 2026-08-12

21.2.0 sent a bare `Activate` from `Pending-changes` and the appliance refused it:

```
"message":"Action 'Activate' is not allowed in the current state.",
"messageId":"gershwin_user_action_is_not_allowed"
```

#### Fixed

- **`Activate` is only valid once the profile's configuration is already
  deployed.** From `Pending-changes` — configuration not yet pushed — the
  appliance requires `Deploy` first. The GUI capture that showed a bare
  `Activate` was taken against a profile already past that point, which is why
  it looked like the whole story. It reconciles the two live results exactly:
  21.0.0 worked because it deployed first and activated later; 21.2.0 failed
  because it skipped straight to `Activate`.
- **The appliance now decides, not the script.** `Activate` is still tried
  first — one call, the fast path, and it is what runs when the state allows it.
  If the appliance answers `gershwin_user_action_is_not_allowed`, the run falls
  back to the form it requires:
  `-Action Deploy` + `ScheduledActions @{Action='Deploy'; ProceedOnReboot=$true}`.
  Any other error still propagates.
  Reacting to the appliance's own answer beats predicting which states permit
  which action — that mapping is not published, and guessing at it has now been
  wrong twice.
- The fallback is recorded as `Activate / NotAllowed` in the run summary with
  the `ConfigState` that refused it, so the pattern across a cluster is visible
  afterwards rather than scrolling past.

#### Changed — tests

- The simulation's `Set-IntersightServerProfile` stub now enforces the
  distinction rather than a blanket rule: `Activate` must go on its own, while
  `Deploy` carries a top-level `-Action` alongside it.
- `Test-IntersightRebootActivate.ps1` asserts `Activate` is what the deploy
  reaches for **first**, and that `Deploy` appears only behind the
  not-allowed check — the two-step form must never become the default again.

### [21.2.0] — 2026-08-12

#### Added

- **No vCenter action until the host is genuinely back.** "Back" now means
  vCenter has it in inventory as Connected or Maintenance **and** its boot time
  has changed since before the activation. Connection state alone cannot tell
  *came back* from *never left*, and on a firmware run that is the difference
  between the compliance scan reading the new firmware or the old one and the
  host being returned to service un-upgraded.
  The reconnect table now carries a `Rebooted` column, and the gate names any
  host still reporting its pre-activation boot time.
- The baseline is captured **before any action in the batch**, not just before
  the Intersight activation — a UCS acknowledgement restarts a host too, and a
  baseline taken after it is the post-reboot value, which would make the gate
  wait forever for a restart that had already happened. That ordering bug was
  caught by the simulation, not by reasoning.
- A batch where nothing was staged clears the baseline, so `Rebooted` reports
  `Unknown` and the gate passes. No reboot was asked for, so none is waited on.
- `Rebooted=Unknown` is always accepted. It means there was no baseline to
  compare against, not that the host failed to restart.

#### Notes — deploy and activate in one action

- Already the case since 21.1.0 and verified in the code this release: one call,
  `{"ScheduledActions":[{"Action":"Activate","ProceedOnReboot":true}]}`, with no
  separate staging step. Two header comments still described the old
  `Action='Deploy'` shape and have been corrected — a comment that contradicts
  the call is worse than no comment — and the test suite now fails if any
  example anywhere in the script shows the `Deploy` scheduled action again.

### [21.1.0] — 2026-08-12

A HAR capture of the GUI watching an activation. It contained no POST — but its
GETs were worth more than the POST would have been.

#### Changed

- **Activate from the start.** One call, at the point the run used to send
  `Deploy`. There is no longer a stage-then-activate split, and no 40-minute
  wait wedged between two halves of one operation: `Activate` stages the
  firmware *and* restarts the blade. Setting
  `$Global:IntersightRebootImmediatelyToActivate` to `$false` still stages only,
  via `-Action Deploy`, for restarting blades by hand.
- **The upgrade check is now the GUI's own query**, lifted from the HAR:
  ```
  GET /api/v1/firmware/Upgrades
      ?$filter=(Server.Moid in ('<moid>')) and (Status eq 'IN_PROGRESS')&$select=Server
  ```
  One call, one field, and the appliance decides — rows means running, none
  means finished. It replaces a read of `firmware/UpgradeStatuses` that
  pattern-matched free-text state strings (`progress|pending|scheduled|…`)
  against a field that has had a filterable status all along. That was guesswork
  where an exact answer was available.
- **No pre-wait before the first check.** The activation is already under way by
  the time the watcher starts, so the first check runs immediately and the
  stand-off happens *between* checks. On a blade that activates quickly this
  removes 40 minutes of dead time per host.

#### Notes

- The HAR also shows the GUI polling `workflow/WorkflowInfos` filtered on
  `WorkflowCtx.TargetCtxList.TargetMoid` for the profile, and
  `firmware.UpgradeStatus` carrying `DownloadPercentage` / `DownloadProgress`.
  Neither is needed for the decision the run makes, but both are there if
  per-stage progress is ever wanted on screen.

### [21.0.0] — 2026-08-12

**The captured request settles it.** Deploying from the GUI with *Reboot
immediately to activate* ticked sends:

```
POST /api/v1/server/Profiles/<moid>
{"ScheduledActions":[{"Action":"Activate","ProceedOnReboot":true}]}
```

67 bytes — matching the captured `content-length` exactly.

#### Fixed

- **The action is `Activate`, not `Deploy`.** `Deploy` stages the firmware;
  `Activate` restarts the blade and brings it into service. Every attempt so far
  sent `Deploy` on the scheduled action, which is why the firmware staged
  perfectly and nothing ever rebooted.
  GitHub issue #141 — *"Set-IntersightServerProfile no longer allows Activate"* —
  is about the **profile's own `-Action` parameter**, which accepts only `Deploy`
  and `Unassign`. The **scheduled action's** `Action` field is a different field
  and does accept `Activate`. I conflated the two, and that cost several runs.
- **The body carries only `ScheduledActions`.** No top-level `Action` goes with
  the activate.

#### Added

- `Invoke-IntersightProfileActivate` sends exactly that request. It is now the
  first thing tried once the firmware task reports finished; the server power
  cycle remains as the fallback if `Activate` is refused.

#### Added — tests

- The activate request is asserted on its shape, not its intent:
  `Action=Activate`, `ProceedOnReboot=true`, against the profile Moid — plus a
  static check that the script builds the scheduled action with `'Activate'`.
  56 assertions in that suite.
- The suite caught a `"$Moid:"` drive-qualified variable in its own stub — the
  same PowerShell trap this codebase hit once before.

### [20.7.0] — 2026-08-12

The activation now runs in the order the appliance imposes, and **nothing in
vCenter happens until it has finished**.

1. Check the host, stage the firmware (deploy the profile).
2. **Pause 40 minutes.** 20.6.0 power-cycled immediately and was refused —
   `action_not_allowed_firmware_upgrade_in_progress` — because the deploy's own
   firmware task was still running. Waiting first is what the appliance requires.
3. **Ask Intersight** whether that task has finished for this profile's server
   (`firmware/UpgradeStatuses`). Finished → power-cycle the blade. Still going →
   prompt **RETRY**, which re-checks the **Intersight task**, not vCenter, and
   power-cycles the moment it reports finished. No cap on retries.
4. **Hold up to 40 minutes, polling.** Every minute it asks whether the profile
   has stopped requiring a deploy and no firmware task is running, and returns
   the moment both are true rather than sleeping out the window.
5. Only then back to vCenter — and the batch **skips its own post-reboot wait**,
   because this one already served it. A host is not held for 80 minutes.

#### Changed

- `Invoke-IntersightActivationPowerCycle` rewritten to that sequence. The
  power action is no longer attempted before the wait.
- `RETRY` re-checks the Intersight firmware task. Previously the retry loop
  fell through to vCenter's reconnect wait, which checked the wrong system.
- `$Global:IntersightActivationHeldForBatch` tells the batch loop the wait has
  been served, so `$initialWait` drops to 0 for that batch. The reconnect check
  still polls until the host is actually back — only the fixed wait in front of
  it is skipped.

#### Added

- `Get-IntersightFirmwareTaskState` — Running / Finished / Unknown from
  `firmware/UpgradeStatuses`. **Unknown is not treated as Finished**: where the
  status cannot be read the power action is attempted and the appliance's
  refusal is taken as authoritative, because it is.
- `Wait-IntersightActivationComplete` — the polling hold. `C` moves on, `E`
  exits. Reaching the ceiling is not a failure.
- `$Global:IntersightActivationHoldMinutes` (default 40).

#### Added — tests

- `tests/Test-IntersightPowerAction.ps1` at 53 assertions, including a static
  check that **no vCenter cmdlet appears anywhere in the activation path** —
  `Get-VMHost`, `Set-VMHost`, `Restart-VMHost`, `Test-VMHostProfileCompliance`
  and the rest — and that it reads `Get-IntersightFirmwareUpgradeStatus`
  instead. A running task means no power action is attempted at all; `RETRY`
  power-cycles once the task reports finished; the hold returns early when the
  profile settles.

### [20.6.0] — 2026-08-12

The server is now found and the power action reaches it. Intersight's reply told
us the rest:

```
"message":"Cannot perform power action when a firmware upgrade is in progress.",
"messageId":"action_not_allowed_firmware_upgrade_in_progress"
```

That is not a failure. It is the appliance declining to power-cycle underneath
the upgrade this deploy started — correct behaviour, and it clears when the
upgrade does.

#### Changed

- **`action_not_allowed_firmware_upgrade_in_progress` is treated as "not yet".**
  `Invoke-IntersightServerPowerAction` now returns `Sent` /
  `UpgradeInProgress` / `Failed` instead of a bare boolean, so the caller can
  tell "refused because it is busy" from "refused because something is wrong".
- **The run stands off 40 minutes, then offers RECHECK.** After each window the
  profile is re-read; if it is still staged and the power action never landed,
  the action is **retried** — the upgrade blocking it may have finished. Then
  the operator chooses:
  - **RECHECK** — wait another window and look again
  - **CONTINUE** — stop watching and move on to the post-reboot wait
  - **EXIT** — stop the run
- **There is no cap on the number of stand-offs.** `$Global:IntersightActivationMaxCheckIns`
  is removed. The run waits exactly as long as the operator wants and never
  decides on its own that an activation has failed.

#### Fixed

- **A loop whose only exit was a successful prompt.** Anything that is not an
  explicit `RECHECK` now moves on, so a prompt that cannot be answered — a lost
  console, a missing helper — ends the wait instead of spinning on it. Found by
  the test suite hanging: `Read-ChoiceExit` was not extracted into the test, the
  choice came back null, and the `while ($true)` never returned. The same thing
  would have happened on a jump host with no interactive console.

#### Added — tests

- `tests/Test-IntersightPowerAction.ps1` at 32 assertions: the
  upgrade-in-progress refusal is told apart from a real failure, a refused
  action is retried after the stand-off, `RECHECK` keeps waiting until the
  profile settles, and a prompt counter fails the suite if the loop ever stops
  converging.

### [20.5.1] — 2026-08-12

#### Fixed

- **`AssignedServer.Moid` read as empty on every profile**, so no power action
  was ever sent — "the server it is assigned to could not be identified".
  Relationship properties in this SDK are not plain objects: they are generated
  `<Type>Relationship` wrappers holding a `MoMoRef` on **`ActualInstance`**, and
  the Moid lives there. Cisco's `GettingStarted.md` prints the shape verbatim
  (`IamAccountRelationship { ActualInstance: class MoMoRef { ... } }`), and the
  SDK's own `GetCmdletBase.cs` reaches through it the same way:
  ```csharp
  if (item.Value.GetType().Name.EndsWith("Relationship"))
      var actualInstance = item.Value.GetType().GetProperty("ActualInstance").GetValue(item.Value);
  ```
  This is the same class of defect as reading a paged response instead of the
  object inside it — the property is present, populated, and unreadable the
  obvious way.

#### Added

- `Get-IntersightRelationshipMoid` probes every shape the Moid can arrive in:
  the object itself, `ActualInstance`, a doubly-wrapped instance, the
  `AdditionalProperties` bag when the model did not recognise the concrete type,
  and a bare 24-hex-character Moid string. Anything else yields `""` — a string
  that is not a Moid is never treated as one.
- **A second read with the relationship expanded.** If neither property yields a
  Moid, the profile is re-read with `-Expand AssignedServer`. An unexpanded
  relationship can carry nothing useful at all, which is why the Intersight GUI
  expands it on this very page.
- **A diagnostic that names the shape.** If it still comes back empty, the run
  prints the relationship's .NET type, its property names, and its
  `ActualInstance` type and properties. Two live runs have now been lost to a
  property that was present and unreadable; "could not be identified" on its own
  does not tell anyone which property to reach for.

#### Added — tests

- `tests/Test-IntersightPowerAction.ps1` grew to 28 assertions, covering each
  wrapper shape, the expand fallback (and that it asks for `AssignedServer`),
  and that an arbitrary string is never mistaken for a Moid.

### [20.5.0] — 2026-08-12

Staging the firmware works. The restart is what the appliance does not reliably
do on its own, so the run now performs it — through Intersight.

#### Added

- **`Invoke-IntersightActivationPowerCycle`.** Where a deploy leaves the profile
  staged, the run reads back which server the profile is assigned to
  (`AssignedServer`, falling back to `AssociatedServer`) and power-cycles **that
  server** through Intersight:
  `Set-IntersightComputeServerSetting -Moid <server moid> -AdminPowerState PowerCycle`,
  which is `POST /api/v1/compute/ServerSettings/<server moid>`. vCenter is not
  involved and no host is rebooted from the vSphere side.
- **It stands off rather than polling on a timeout.** After the power action the
  run waits `$Global:IntersightActivationWaitMinutes` (default **40**) and looks
  again, up to `$Global:IntersightActivationMaxCheckIns` times (default 3).
  `C` checks in immediately, `E` exits. An activation takes as long as it takes,
  and a closed window is not evidence of failure.
- **Nothing in this path ends the run.** Not a server that cannot be identified,
  not a power action the appliance declines, not an activation still running
  when the check-ins run out. Each is announced and written to the run summary,
  and the batch carries on to the reconnect wait — which is better placed to say
  whether the host came back. By this point the firmware is staged and the host
  is in Maintenance mode; ending the run would leave the operator with less than
  they started with.

#### Notes — `AdminPowerState`

The SDK's own definitions, and one of them is a trap:

| Value | Effect |
| --- | --- |
| `PowerCycle` | **Resets the server** — activates staged firmware |
| `HardReset` | Hard resets the server |
| `PowerOn` / `PowerOff` | Power on / off |
| `Shutdown` | Shuts the operating system down |
| `Reboot` | **Reboots the IMC, not the server** |

`Reboot` is the one that reads correctly and does the wrong thing: it restarts
the management controller and leaves the blade running with the firmware still
staged — indistinguishable from the failure this release fixes. The default is
`PowerCycle`, and the run warns in red if it is ever configured with `Reboot`.

#### Removed

- `$Global:IntersightRebootHostToActivate` and the vCenter-side `Restart-VMHost`
  activation path. The reboot comes from Intersight.

#### Added — tests

- `tests/Test-IntersightPowerAction.ps1` — 17 assertions: the server is taken
  from the profile and never inferred, `PowerCycle` goes to the server's own
  setting Moid, a declined action returns rather than throwing, an activation
  still running after the check-ins is handed on rather than failed, a profile
  with no assigned server sends nothing at all, and the configured default is
  asserted to be `PowerCycle` with the 40-minute stand-off.

### [20.4.0] — 2026-08-11

#### Fixed

- **`-Action Deploy` is sent again, alongside the scheduled action.** Removing
  it in 20.3.0 was a guess and it was wrong: a live run with `-Action Deploy`
  produced the *Deploy Firmware Policy* workflow on the appliance, and a run
  with only `-ScheduledActions` produced no workflow at all. Both now go in one
  call — `-Action Deploy` starts the deploy, `ProceedOnReboot` acknowledges the
  restart.

#### Changed

- **The reboot must come from Intersight.** `$Global:IntersightRebootHostToActivate`
  can activate staged firmware with a vCenter-side `Restart-VMHost` instead —
  "install on next reboot" is the documented behaviour and the host is already
  evacuated — but it is **off by default**. It is a different thing from what
  the operator asked for, and leaving it on would hide an appliance that is not
  acting on the acknowledgement.
- When Intersight stages the firmware and does not restart the blade, the run
  stops with the three checkboxes the GUI's Deploy dialog ticks, and how to
  capture what it actually sends: deploy one profile from the GUI with developer
  tools open and read the `PATCH` to `/api/v1/server/Profiles/<moid>`. That
  request body names the fields Cisco does not publish. The blade is left
  running and untouched.
- `Confirm-IntersightDeployAccepted` returns a verdict instead of stopping
  inside itself, so the caller decides what an un-actioned deploy means.

#### Notes

- The API names behind the Deploy dialog's three checkboxes — *Reboot
  immediately to activate*, *Deploy all associated policies whether modified or
  not*, and the mandatory disruption acknowledgement — are **not published**.
  `ProceedOnReboot` is documented and is sent; the other two have no documented
  equivalent I could verify. Two attempts at guessing an identifier for this
  have now failed, so the script no longer guesses.

### [20.3.0] — 2026-08-11

20.2.0 sent the reboot acknowledgement by the wrong mechanism entirely, and the
acceptance check added alongside it is what caught that.

#### Fixed

- **Reboot Immediately to Activate is `ProceedOnReboot` on a
  `PolicyScheduledAction`, not a `PolicyActionParam`.** The SDK documents it in
  as many words — *"ProceedOnReboot can be used to acknowledge server reboot
  while triggering deploy/activate"* — on
  `Initialize-IntersightPolicyScheduledAction`, sent through
  `Set-IntersightServerProfile -ScheduledActions`.

  ```powershell
  $a = Initialize-IntersightPolicyScheduledAction -Action 'Deploy' -ProceedOnReboot $true
  Set-IntersightServerProfile -Moid <moid> -ScheduledActions @($a)
  ```

  20.2.0 sent a `PolicyActionParam` named `RebootImmediatelyToActivate`, which
  I could not find documented and guessed at. `PolicyActionParam` takes
  free-form `Name`/`Value` strings, so the appliance accepted the Deploy,
  ignored the parameter, staged the firmware and rebooted nothing — the profile
  sat in `Pending-changes` and the run stopped.
- **`-Action Deploy` is no longer sent alongside.** The scheduled action carries
  the action; sending both instructs the profile twice in two different forms.
  `-Action Deploy` on its own is the deploy-and-wait-for-a-manual-reboot form,
  which is exactly what was happening.
- The surface for `-ScheduledActions`, `Initialize-IntersightPolicyScheduledAction`
  and its `-Action`/`-ProceedOnReboot` parameters is now checked **before any
  host is evacuated**, rather than discovered on the first deploy with a blade
  already in Maintenance mode.
- `Confirm-IntersightDeployAccepted`'s failure message no longer points at
  settings that have been removed; it lists what to check on the appliance
  instead.

#### Changed — tests

- `tests/Test-IntersightRebootActivate.ps1` asserts on **how the deploy is
  composed**, not just that one was sent: the acknowledgement is built with
  `Initialize-IntersightPolicyScheduledAction -Action 'Deploy' -ProceedOnReboot
  $true`, goes through `-ScheduledActions`, and no string literal is passed as
  an action parameter name. The previous suite passed "reboot-immediately is
  enabled" while the script sent it in a form the appliance ignored.
- The workflow simulation's `Set-IntersightServerProfile` stub **throws** if
  `-Action` arrives alongside `-ScheduledActions`.

### [20.2.0] — 2026-08-11

AUTO still never reached Maintenance mode. 20.1.0 fixed the ordering, but the
run was stalling *before* that, in a step neither of us had looked at.

#### Removed

- **`Move-PoweredOffAndSuspendedVMsForBatch`.** Before requesting Maintenance
  mode it cold-migrated every powered-off and suspended VM off each host in the
  batch, one at a time, to a randomly chosen destination. On a 21-host cluster
  with a batch of 6 that is a very long queue of cold migrations — which is what
  the run was doing when it appeared to hang — and DRS undoes the placement as
  soon as the host comes back. In SINGLE mode the batch is one host, so it was
  short enough never to look like a problem.
- **`-Evacuate` on `Set-VMHost`.** That switch *is* `evacuatePoweredOffVms`: it
  forces the same cold migration inside vCenter instead of in the script.
  Powered-off and suspended VMs do not block Maintenance mode — only running
  ones do, and in a fully automated DRS cluster DRS moves those itself, once,
  as part of entering.

  **This script now migrates nothing.** The batch is sized from live cluster
  capacity and its hosts go straight into Maintenance mode.

#### Added — tests

- `tests/Test-MaintenanceModeEntry.ps1` asserts no request passes `-Evacuate`,
  the script contains no `Move-VM` call, and no powered-off VM sweep survives
  anywhere in the file.
- The workflow simulation's `Set-VMHost` stub now **throws** on `-Evacuate`, and
  on a blocking enter-Maintenance call. Exiting Maintenance mode is still
  allowed to block — it returns immediately, and requiring async there was wrong.

### [20.1.0] — 2026-08-11

#### Fixed

- **AUTO mode never got its hosts into Maintenance mode.** Every host in the
  batch was requested at once, on the theory that DRS would exclude all of them
  from placement so each VM moved once. On a live cluster it did the opposite:
  the capacity available to receive the VMs was shrinking at the same time as
  the VMs needed placing, so migrations ran continuously and no host arrived.
  Hosts now enter **one at a time, in cluster list order** — each requested,
  then waited for, before the next is asked. A host that will not evacuate
  within `$MaintenanceValidationTimeoutMinutes` stops the run naming it, with
  the rest of the batch untouched rather than stacking a second stuck
  evacuation on the first. SINGLE mode is a batch of one, so it is byte-for-byte
  the behaviour it already had.

#### Added

- **Reboot Immediately to Activate on every Intersight deploy**
  (`$Global:IntersightRebootImmediatelyToActivate`, on by default). Without it
  the firmware stages against the profile and nothing restarts.
  Cisco does not publish the identifier that carries it — `PolicyActionParam`
  takes free-form `Name`/`Value` strings and neither the SDK reference nor the
  API schema enumerates them — so it is set in one place
  (`$Global:IntersightRebootActionParamName` / `...Value`) and printed in full
  with every deploy.
- `Confirm-IntersightDeployAccepted`, because that identifier is **not trusted**.
  A wrong one is either rejected — which throws, and the run stops — or silently
  ignored, in which case the Deploy is accepted, the firmware stages, nothing
  reboots, and the run waits out its whole post-reboot window before reporting
  the batch complete. The profile is now re-read after each deploy and the run
  stops if it is still sitting in a staged state, naming the setting to correct.

#### Added — tests

- `tests/Test-MaintenanceModeEntry.ps1` — 20 assertions. The one that matters
  records the state of the whole batch at the moment each request is issued: no
  request may go out while another host is still entering. The old design passes
  "every host ended in Maintenance mode" against a stub, so that assertion alone
  proves nothing.
- `tests/Test-IntersightRebootActivate.ps1` — 18 assertions, centred on the
  silently-ignored case: a profile still staged after the deploy stops the run,
  for every actionable `ConfigState`, and the acknowledgement is asserted to be
  on by default.
- The workflow simulation asserts every deploy carried the acknowledgement and
  that each was confirmed accepted rather than assumed.

### [20.0.0] — 2026-08-11

Two changes to what the run touches and what stops it. Both narrow the script's
remit, hence the major bump.

#### Added

- **Only blades with changes staged are in scope.** Before anything is
  evacuated, every Intersight-managed host's server profile is read once, and
  those with nothing to deploy — `Associated`, or any state outside
  `$Global:IntersightActionableConfigStates` — are dropped from the run
  (`Remove-IntersightHostsAlreadyDeployed`). Batching one of those evacuated a
  host, put it into Maintenance mode, waited, found nothing to send, brought it
  back and reported success — achieving nothing and spending a maintenance
  window slot. The table is printed up front so the real scope is visible before
  the first host moves.
  A profile whose `ConfigState` cannot be **read** stays in scope. "Nothing
  staged" and "could not tell" are different answers, and dropping a host on the
  second would silently leave it un-upgraded while the run reported a clean
  sweep.

#### Removed

- **The cluster health gate, entirely** — `Get-ClusterHealthReport`,
  `Confirm-ClusterHealthOrChoose`, the pre-batch and post-batch checks, and
  `$MinimumDatastoreFreePercent`. Removed at the operator's direction after it
  repeatedly failed a cluster with nothing wrong with it and stopped the run
  mid-change. **Host profile compliance is now the only health gate**: a host
  that passes it and comes out of Maintenance mode is back in service, and the
  run moves on.
  Cluster-level assurance is now the operator's responsibility, stated in
  requirement 5 of the pre-flight. Nothing in the run will now notice a
  datastore filling up, a triggered alarm, or a host dropping out elsewhere in
  the cluster.
- `tests/Test-ClusterHealthGate.ps1`, with the code it covered.

#### Fixed

- `Get-Datastore -Location $Cluster` was invalid — the parameter accepts only
  Datacenter, Folder and DatastoreCluster objects, so passing a cluster threw
  and the health check failed with *"Datastore free space could not be
  evaluated"*. That call is gone with the rest of the gate. It never worked, on
  any release that had it.

#### Changed — tests

- The workflow simulation asserts that **no** `ClusterHealth` stage row is ever
  written, so a cluster-wide gate cannot reappear quietly.
- The already-current second pass now proves the exclusion: both deployed
  Intersight hosts are dropped from scope, the reason names their `ConfigState`,
  and neither is put into Maintenance mode.

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

### [23.4.1-preauth] — 2026-08-13

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 23.4.1 — a non-fatal error
from `Set-IntersightConfiguration` no longer aborts the run; the read-back
decides. This is the build to run.

### [23.4.0-preauth] — 2026-08-13

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 23.4.0 — a created host
firmware package is set to Global, and the root password prompt goes straight to
the credential dialog. This is the build to run.

### [23.3.0-preauth] — 2026-08-13

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 23.3.0 — the ESXi root password
is collected at cluster selection and used to reconnect a host vCenter has
dropped. This is the build to run.

### [23.2.0-preauth] — 2026-08-13

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 23.2.0 — the first run of a
session no longer fails on a cold module cache, the authentication block stops
claiming success it did not have, and AUTO scales to half the cluster. This is the
build to run.

### [23.1.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 23.1.0 — every deploy in the
batch goes out back to back, and they are confirmed in one shared window. This is
the build to run.

### [23.0.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 23.0.0 — the cluster rolls
through host by host, refilling each slot as it frees, within live capacity. This
is the build to run.

### [22.1.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 22.1.0 — an unreadable
ConfigState falls back to checking vCenter for the host's return, and every
prompt is a single key. This is the build to run.

### [22.0.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 22.0.0 — the batch is activated
and watched concurrently, and the run mode menu is LIVE or DRY RUN only. This is
the build to run.

### [21.9.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.9.0 — duplicate profile
names are no longer resolved by guessing, and a refused deploy does not end the
run. This is the build to run.

### [21.8.1-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.8.1 — one fewer Intersight
call per poll, and two dead functions removed. This is the build to run.

### [21.8.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.8.0 — the activation is
driven by polled Intersight workflow, upgrade and profile state; the 60-minute
values are ceilings, not sleeps. This is the build to run.

### [21.7.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.7.0 — an undrivable host is
set aside rather than stopping the cluster, and the run closes with a list of
hosts requiring manual rectification. This is the build to run.

### [21.6.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.6.0 — hosts already in
Maintenance mode are in scope for both Intersight and UCS Manager, taken first,
and cost no capacity. This is the build to run.

### [21.5.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.5.0 — 60-minute firmware
waits, an 8-minute compliance settle, and a halt on any host profile status
other than Compliant. This is the build to run.

### [21.4.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.4.0 — `Activate` is never
gated on the firmware upgrade finishing, because the upgrade is waiting on the
activation. This is the build to run.

### [21.3.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.3.0 — Activate is tried
first, and the appliance's refusal drives the fallback to Deploy with the reboot
acknowledgement. This is the build to run.

### [21.2.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.2.0 — no vCenter action
until the host is back in inventory with a changed boot time. This is the build
to run.

### [21.1.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.1.0 — activate from the
start, and watch the upgrade with the GUI's own `Status eq 'IN_PROGRESS'` query.
This is the build to run.

### [21.0.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 21.0.0 — the activation sends
`{"ScheduledActions":[{"Action":"Activate","ProceedOnReboot":true}]}`, captured
from the GUI. This is the build to run.

### [20.7.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 20.7.0 — stage, pause 40
minutes, check the Intersight task, power-cycle, hold and poll, then vCenter.
This is the build to run.

### [20.6.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 20.6.0 — a power action
refused because the upgrade is still running is retried after a 40-minute
stand-off, then the operator is offered RECHECK. This is the build to run.

### [20.5.1-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 20.5.1 — the assigned server
is read through `ActualInstance`, so the power cycle actually reaches a server.
This is the build to run.

### [20.5.0-preauth] — 2026-08-12

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 20.5.0 — the run power-cycles
the assigned server through Intersight to activate staged firmware, stands off
40 minutes between check-ins, and never ends the run over it. This is the build
to run.

### [20.4.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 20.4.0 — `-Action Deploy` is
sent alongside `ProceedOnReboot`, and the reboot must come from Intersight.
This is the build to run.

### [20.3.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 20.3.0 — the reboot
acknowledgement is `ProceedOnReboot` on a scheduled action, which is what
actually triggers the activation reboot. This is the build to run.

### [20.2.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 20.2.0 — the script migrates
nothing; hosts go straight into Maintenance mode and DRS handles the running
VMs. This is the build to run.

### [20.1.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 20.1.0 — hosts enter
Maintenance mode one at a time in cluster order, and every Intersight deploy
carries Reboot Immediately to Activate. This is the build to run.

### [20.0.0-preauth] — 2026-08-11

Tracks `Invoke-AutoDeployFirmwareBatchControl.ps1` 20.0.0 — only blades with
changes staged are in scope, and host profile compliance is the only health
gate. This is the build to run.

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
