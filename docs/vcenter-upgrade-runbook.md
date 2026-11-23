# vCenter Upgrade Runbook -- Invoke-VvfVCenterUpgrade.ps1

A step-by-step guide to upgrading (patching) the vCenters of a VMware vSphere Foundation
(VVF) Enhanced Linked Mode group with **`Invoke-VvfVCenterUpgrade.ps1`**: one self-contained
script, run from your script-runner / automation front end (or a PowerShell console). Follow
it top to bottom and tick each box as you go. If anything does not match what this guide
says, **stop and ask a senior engineer** before going on.

Written for: `Invoke-VvfVCenterUpgrade.ps1` **3.0.1** or later
(`scripts/vsphere/Invoke-VvfVCenterUpgrade.ps1`). The window (`Start-VvfUpgradeGui.ps1`) and
the signing helper (`Set-VvfUpgradeToolSignature.ps1`) are retired. **This one file is the whole
process** -- no other scripts, modules from this repo, or sample files are needed.
The full reference is the script's own help: `Get-Help .\Invoke-VvfVCenterUpgrade.ps1 -Full`.

---

## What the script does, in plain words

For every vCenter in your list, one at a time (one "round" each):

1. Shuts **all** the vCenters in the group down together and takes an **offline snapshot** of
   each (one rollback point for the whole SSO domain).
2. Powers them all back on and waits until every vCenter has **SSH on**, **every service
   started** and **replication** between them is healthy.
3. Upgrades **one** vCenter from the patch ISO, reboots it, and waits again until the whole
   group is healthy.
4. Checks that vCenter after the upgrade, then moves on to the next round.

At the end it unmounts the ISO from every vCenter, **turns SSH off**, and leaves the snapshots
for Aria Operations to clean up (after 7 days). If anything fails it **stops** -- nothing
further is upgraded -- and you run it again with **`-Resume`** once the cause is fixed.

**The script never asks a question.** Everything it needs is a parameter (or a stored
credential). If something is missing or a decision is needed, it stops with exit code 1 and
says which parameter to set. It never sits waiting for an answer.

> **Outage:** while the vCenters are shut down for each round's snapshot, the whole SSO domain
> is unavailable -- nobody can log in to any vCenter in the group. Expect this once per vCenter.

**How long it takes:** roughly 45-90 minutes per vCenter. Five vCenters: allow 5-8 hours. Make
sure your front end's job timeout is longer than that.

### SSH -- fully automatic

| When | What the script does |
|---|---|
| Start of **every** run (dry run too) | Turns SSH on, through the appliance API, on every vCenter where it is off. |
| After every power-on and reboot | Checks SSH is still on; turns it on again if not. |
| End of a **dry run** | Turns SSH off again where the dry run turned it on. |
| End of a **completed upgrade** (last vCenter done, ISO unmounted) | Turns SSH off on every vCenter where the run turned it on. With `-SshFinalState Disable`: on **every** vCenter, also those where it was on before. |
| Run **stops part way** (failure or STOP file) | Leaves SSH **on** (the resume and the person investigating need it), says so, and records which vCenters it turned it on for in the state file -- the `-Resume` run that finishes turns those off. |
| Run **refused before anything changed** (e.g. a failed pre-check) | Puts SSH back as it found it. |

You do not need to touch SSH in the VAMI at any point.

---

## Stage 0 -- Before the change window (the day before)

### 0.1 Approvals and people

- [ ] The change is approved, and the window allows for one SSO outage per vCenter.
- [ ] You know which **senior engineer** is on call during the window.
- [ ] Users and teams that use these vCenters (backup, Aria, Horizon, automation) have been
      told about the outages.

### 0.2 Backups

- [ ] A **file-based backup** has been taken from each vCenter's VAMI
      (`https://<vcenter>:5480` -> Backup). The snapshots are a rollback point, not a backup.
- [ ] vCenter HA is **not** configured on any of the vCenters (the script warns if it is).

### 0.3 The patch ISO

- [ ] Download the **patch** ISO for the target version from Broadcom. Its name ends in
      `-patch-FP.iso`, e.g. `VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso`.
      **Not** the full installer (`VMware-VCSA-all-...iso`) -- the script refuses that one.
- [ ] Upload it to a datastore that **every ESXi host running one of the vCenters** can see.
- [ ] Write down its **datastore path** exactly as the datastore browser shows it
      (case-sensitive) -- this is the `IsoPath` parameter:

      ```
      [SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso
      ```

      It is **not** a Windows path (`C:\...`, `\\server\share\...`) and not a browser URL.

### 0.4 The vCenter list (CSV)

- [ ] Find **every** vCenter in the SSO domain and, for each, the **ESXi host its VM runs on
      now** (vSphere Client -> the vCenter VM -> Summary -> Host).
- [ ] Write the list, **in the order you want them upgraded** (in Notepad, or straight into the
      front end's text field; the same template is in the script's help):

      ```csv
      VCenter,EsxiHost,VmName
      vcenter1.corp.local,esx01.corp.local,vcenter1
      vcenter2.corp.local,esx02.corp.local,
      ```

      | Column | What to put in it |
      |---|---|
      | `VCenter` | The vCenter's full name (FQDN). |
      | `EsxiHost` | The ESXi host its VM runs on **now**. |
      | `VmName` | Optional: the VM's inventory name, if it differs from the vCenter name. If the script says it *"could not tell which VM is the vCenter"*, fill this in. |

      Rules: the header line exactly as above; lines starting with `#` are ignored; **every**
      vCenter in the SSO domain must be listed, even ones you do not plan to change.
- [ ] Give it to the script **either** as a file the runner can read (`VCenterCsv`, e.g.
      `D:\Upgrades\vcenters.csv`) **or** pasted into a text field (`VCenterCsvText`). Both work
      the same; the dry-run check compares the contents.
- [ ] Ask for DRS to be set to manual (or the VMs pinned) for the window. If a vCenter VM moves
      host before the window, update `EsxiHost`.

### 0.5 Credentials

The script needs three credentials. It **never prompts** for them; it takes each from, in
order:

1. a per-host / per-vCenter **stored secret** (only needed when passwords differ),
2. the **parameter** (`EsxiCredential`, `VCenterRootCredential`, `SsoCredential`) -- usually a
   credential field in your front end,
3. a shared **stored secret**: a SecretManagement vault secret, or the environment variables
   `RICHO_<NAME>_USER` / `RICHO_<NAME>_PASSWORD`.

| Credential | Parameter | Shared secret name | Per-target secret name (if passwords differ) |
|---|---|---|---|
| ESXi root | `EsxiCredential` | `vvf-esxi` | `vvf-esxi-<host fqdn>` |
| vCenter appliance root | `VCenterRootCredential` | `vvf-vcenter` | `vvf-vcenter-<vcenter fqdn>` |
| SSO administrator | `SsoCredential` | `vvf-sso` | -- |

Environment-variable names replace every non-alphanumeric with `_` and are upper case, e.g.
`RICHO_VVF_ESXI_USER`, or for one host with its own password
`RICHO_VVF_ESXI_ESX02_CORP_LOCAL_USER` / `..._PASSWORD`. Never put passwords in the CSV or in
plain-text parameters.

Check **before** the window:

- [ ] **ESXi root** works on each host's Host Client (`https://<esxi-host>/ui`). A host in
      **lockdown mode** refuses this -- ask for lockdown to be disabled for the window.
- [ ] **vCenter appliance root** works on each VAMI (`https://<vcenter>:5480`). If it says the
      password has **expired**, change it now.
- [ ] **SSO administrator** (usually `administrator@vsphere.local`) and its password.

### 0.6 The machine that runs the script

- [ ] It can reach every ESXi host (port 443) and every vCenter (ports 443, 5480 and 22).
- [ ] **VMware PowerCLI** and **Posh-SSH 4 or later** are installed **for the account the
      front end runs scripts as**. A module installed with `-Scope CurrentUser` under your own
      login is invisible to a service account -- install with `-Scope AllUsers`, or as that
      account. Check, as that account:

      ```powershell
      Get-Module VMware.PowerCLI, Posh-SSH -ListAvailable | Select-Object Name, Version
      ```

      Where antivirus blocks Posh-SSH, install PuTTY 0.77+ and set `SshClient` to `Plink`.
- [ ] Upload **`Invoke-VvfVCenterUpgrade.ps1`** (3.0.1 or later) to the front end. It is the
      only file. Its first output line shows the version -- check it on the first run.
- [ ] **Execution policy.** If the runner enforces `AllSigned`, the file must be signed once
      after every change (a senior engineer, at a PowerShell prompt):

      ```powershell
      $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Sort-Object NotAfter -Descending | Select-Object -First 1
      Set-AuthenticodeSignature -FilePath .\Invoke-VvfVCenterUpgrade.ps1 -Certificate $cert -HashAlgorithm SHA256 -TimestampServer http://timestamp.digicert.com
      ```

      A file downloaded with a browser is blocked under `RemoteSigned`: `Unblock-File` it before
      uploading. Do not bypass the execution policy.
- [ ] **Log folder.** Default `%ProgramData%\VvfVCenterUpgrade` on the machine that runs it.
      The dry run, the real run and any resume **must use the same log folder** (the dry-run
      record and the resume state live there). Only set `LogFolder` if told to -- and then use
      the same value every time.

---

## Stage 1 -- Dry run (always first)

The dry run checks everything and changes nothing except SSH, which it turns on for its
checks and off again at its end. **A real run is refused unless a dry run of the same CSV and
ISO passed, in the same log folder, in the last 24 hours.**

Parameters for the dry run:

| Parameter | Value |
|---|---|
| `VCenterCsv` *or* `VCenterCsvText` | your list (Stage 0.4) |
| `IsoPath` | the datastore path (Stage 0.3) |
| credentials | Stage 0.5 |
| `DryRun` | **on** |

Console equivalent:

```powershell
.\Invoke-VvfVCenterUpgrade.ps1 -VCenterCsv D:\Upgrades\vcenters.csv -IsoPath '[SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso' -DryRun
```

1. The phases run in order: `1. vCenters, and whether this run may go ahead` ->
   `2. Credentials and connections` -> `3. Enhanced Linked Mode` -> `4. Upgrade ISO` ->
   `5. Pre-upgrade checks` -> `6. Dry run result`. It takes a few minutes.
2. Read the end of the output:
   - **`RESULT: DryRunPassed (exit code 0)`** -> go on.
   - **`RESULT: DryRunFailed (exit code 1)`** -> read every `ERROR` line and every `[Error  ]`
     finding, fix the cause (see [Troubleshooting](#troubleshooting)), run the dry run again.
3. Read the **Pre-upgrade findings** list even when it passed:
   - [ ] **No `[Error  ]` rows.**
   - [ ] Every `[Warning]` row understood -- tell the senior engineer about any you do not
         understand (disk space, a password or certificate about to expire, vCenter HA).
   - [ ] `vcenterN: turning SSH on for the run` lines are normal; at the end, `SSH turned off
         (the dry run had turned it on)` for the same vCenters.
   - [ ] "The ISO is not mounted yet on ..." is normal: the real run mounts it.
4. The output ends with the line to use for the real run: same CSV, `IsoPath` and log folder,
   with `ConfirmVCenter` set to the **first** vCenter's short name, within 24 hours.

> If you edit the CSV (even a comment) or change the ISO path after the dry run, the real run
> is refused again -- run the dry run again.

---

## Stage 2 -- The real run

Only inside the approved change window, with the senior engineer reachable.

| Parameter | Value |
|---|---|
| `VCenterCsv` / `VCenterCsvText`, `IsoPath`, credentials | **exactly** as the dry run |
| `ConfirmVCenter` | the short name of the **first** vCenter in the CSV, e.g. `vcenter1` |
| `DryRun` | **off** |
| `AllowHardPowerOff` | off (only with a senior engineer's agreement -- see below) |
| `ProceedOverPreCheckErrors` | off (only with a senior engineer's agreement) |
| `RemoveSnapshots` | off (Aria removes them after 7 days; they are your rollback point) |
| `SshFinalState` | `Restore` (default), or `Disable` if your standard is SSH off on every vCenter |

Console equivalent:

```powershell
.\Invoke-VvfVCenterUpgrade.ps1 -VCenterCsv D:\Upgrades\vcenters.csv -IsoPath '[SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso' -ConfirmVCenter vcenter1
```

1. The run repeats the checks, **mounts the ISO** on every vCenter and has each validate it.
   Nothing is shut down yet.
2. If the pre-upgrade checks find errors, it **stops** (nothing shut down). Fix them and
   dry-run again. `ProceedOverPreCheckErrors` carries on over them -- **only with a senior
   engineer's agreement**. Installer precheck errors and CSV/VM/access errors always stop it.
3. `Start confirmed by -ConfirmVCenter vcenter1` -- from here on the vCenters are shut down.

**Do not** stop the front end's job, log off, or let the machine sleep during the run. To pause,
see Stage 5.

---

## Stage 3 -- Watch the rounds

Each vCenter gets one round, headed `7.1 Round 1 of N: vcenter1 -> <target version>`. Each
shows, in order: shutdown of all vCenters -> snapshot of each -> power on -> service checks
(and `SSH was off after the power cycle -- turning it on again` if needed) -> precheck,
validate -> `stage-and-install` with progress -> reboot -> service and replication checks ->
post-upgrade findings -> `Round N complete`.

| You see | Normal? |
|---|---|
| All vCenters shutting down, then snapshots taken | Yes -- the SSO domain is down now. |
| `check N: 34/41 automatic services started` for 10-20 minutes after a power-on or reboot | Yes -- checked every 60 seconds, up to 60 minutes. |
| `appliance API not answering (expected while services restart ...)` during the install | Yes. |
| `a partner is behind -- re-reading in 30s` a few times after a reboot | Yes -- replication catches up. |
| `SSH was off after the power cycle -- turning it on again` | Yes -- handled automatically. |
| `FAILED on <vcenter>` | No -- see Stage 4. |
| No new output for over 30 minutes | Ask the senior engineer to check the vCenter consoles. Do not stop the job. |

**A vCenter that does not shut down by itself within 20 minutes:** without `AllowHardPowerOff`
the round fails there (Stage 4). With a senior engineer, after checking its console, you can
resume with `AllowHardPowerOff` on.

---

## Stage 4 -- If a vCenter fails

The output shows `FAILED on <vcenter> (<stage>): <reason>`, the power state of every vCenter VM,
`Still to do: ...`, `SSH is left ON on ...`, and ends with `RESULT: Failed (exit code 1)`.
**Nothing else is upgraded.**

1. **Read the error** and keep the output.
2. **Tell the senior engineer.** Together, check the vCenter in its VAMI and console (SSH is
   still on, so you can log in), and fix the cause.
3. Run again with **`Resume`** on (same CSV, same log folder, `ConfirmVCenter` set):

   ```powershell
   .\Invoke-VvfVCenterUpgrade.ps1 -VCenterCsv D:\Upgrades\vcenters.csv -Resume -ConfirmVCenter vcenter1
   ```

   The vCenters already upgraded are checked and skipped. The failed one carries on from the
   stage it reached: a fresh group snapshot first if its install had not started; otherwise
   on from the reboot or the checks. No dry run is needed for a resume, and the ISO path is
   taken from the stopped run. When that run completes it turns SSH off, including where the
   stopped run turned it on.

A real run started **without** `Resume` while an unfinished run exists is refused (nothing
changed). Use `Resume` -- or, only if you deliberately abandon the earlier run, `StartFresh`
(the old state file is renamed `.abandoned-<time>` and the run starts from the beginning;
it then needs a passing dry run like any first run).

---

## Stage 5 -- Pausing: stop safely

To pause (the window is ending, something needs changing):

1. Create an empty file named **`STOP`** in the log folder (default
   `%ProgramData%\VvfVCenterUpgrade\STOP`):

   ```powershell
   New-Item "$env:ProgramData\VvfVCenterUpgrade\STOP" -ItemType File
   ```

2. The run **finishes the step it is on** and stops at the next safe point: before the ISO is
   mounted, before the start, or between rounds. It never stops in the middle of a group
   shutdown/snapshot/power-on or an install. This can take a while.
3. It ends with `STOPPED SAFELY`, `Upgraded:` / `Still to do:`, and
   `RESULT: StoppedSafely (exit code 2)`. Progress is saved, the ISO and SSH are left as they
   are for the resume.
4. Continue later with `Resume` (Stage 4, step 3).

Cancelling the front end's job instead stops the script **mid-step** -- emergencies only, with
a senior engineer. It can leave vCenters powered off, a snapshot half taken or an install
running, and SSH on. Every vCenter must then be checked by hand before resuming.

---

## Stage 6 -- The end of the run

In phase **8. Wrap-up**:

1. **The ISO is unmounted** from every vCenter (`ISO unmounted`). `ejected /dev/sr0 inside
   the appliance` and `answered the CD-ROM lock question -- Yes, disconnect anyway` are normal.
   - Any **`ISO NOT unmounted -- <reason>`**: the upgrade is still complete. The senior
     engineer disconnects that CD-ROM by hand (ESXi Host Client -> the VM -> Edit settings ->
     CD/DVD drive -> untick Connected).
2. **SSH is turned off** -- `SSH turned off (the run had turned it on)` per vCenter. Any
   `Could not turn SSH off on <vcenter>`: turn it off in that VAMI (Access) by hand.
3. **Snapshots** are kept (listed) unless `RemoveSnapshots` was on.
4. The run ends with **`RESULT: Upgraded (exit code 0)`** and a table:

   ```
   VCenter             Stage LastStep               From        Target      Now         Ssh
   -------             ----- --------               ----        ------      ---         ---
   vcenter1.corp.local Done  IsoUnmounted           8.0.3.00500 8.0.3.01000 8.0.3.01000 Off
   vcenter2.corp.local Done  IsoUnmounted           8.0.3.00500 8.0.3.01000 8.0.3.01000 On (was on before the run)
   ```

---

## Stage 7 -- Check and hand over

- [ ] No `[Error  ]` rows in the post-upgrade findings. Note any new warnings.
- [ ] Each vCenter's **VAMI** -> **Summary**: the target version, **Health** Good.
- [ ] **VAMI -> Access**: SSH is in the state your standard requires.
- [ ] **vSphere Client** on one vCenter: all linked vCenters appear, hosts and VMs connected.
- [ ] Keep these files from the log folder with the change record:
  - `vcenter-upgrade-<time>.log` -- everything the run printed (one per run, dry run included)
  - `findings-<vcenter>-<time>.csv` -- every check, before and after
  - `upgrade-log-lines-<vcenter>-<time>.txt` -- installer log excerpts, if any
- [ ] Tell the senior engineer the run is complete, and close the change.
- [ ] Ask for DRS / lockdown settings changed for the window to be set back.

### Rolling back (senior engineer only)

If a vCenter is broken after its upgrade: in ELM, **revert ALL vCenters in the group to the same
round's snapshot, together -- never one alone** (the snapshot description says which round).
Power them all off, revert each, power them all on.

---

## Parameter reference (for setting up the front end's form)

| Parameter | Type | Required | Notes |
|---|---|---|---|
| `VCenterCsv` | text (path) | one of these two | CSV file as the runner's account sees it |
| `VCenterCsvText` | multi-line text | one of these two | the CSV contents |
| `IsoPath` | text | yes (not for `Resume`) | datastore path |
| `EsxiCredential` | credential | see Stage 0.5 | ESXi root |
| `VCenterRootCredential` | credential | see Stage 0.5 | appliance root |
| `SsoCredential` | credential | see Stage 0.5 | SSO administrator |
| `DryRun` | switch | -- | always first |
| `ConfirmVCenter` | text | real run / resume | first vCenter's short name |
| `Resume` | switch | -- | carry on a stopped run |
| `StartFresh` | switch | -- | abandon a stopped run and start again |
| `ProceedOverPreCheckErrors` | switch | -- | senior engineer only |
| `AllowHardPowerOff` | switch | -- | senior engineer only |
| `RemoveSnapshots` | switch | -- | default keep |
| `SshFinalState` | `Restore` / `Disable` | -- | default `Restore` |
| `SkipDryRunCheck` | switch | -- | senior engineer only; logged loudly |
| `InstallerAnswers` | hashtable | -- | only if the installer asks a question with no default |
| `LogFolder` | text | -- | default `%ProgramData%\VvfVCenterUpgrade`; keep it the same |
| `SshClient` / `PlinkPath` | `Auto`/`PoshSSH`/`Plink`, path | -- | `Plink` where Posh-SSH is blocked |

The script's **exit code** is `0` (upgraded / dry run would proceed), `1` (stopped on a failure,
or refused) or `2` (stopped safely by a STOP file). The last item on its output stream is a
result object (`Result`, `ExitCode`, `Nodes`, `Transcript`, `FindingsCsv`, `StateFile`) for a
front end that reads objects. Progress text goes to the information stream (`Write-Host`) and
the transcript.

---

## Troubleshooting

| Message | What it means / what to do |
|---|---|
| *"No vCenter list: pass -VCenterCsv ... or -VCenterCsvText"* | Fill in one of the two. |
| *"There is no CSV at '...' (as the account running this script sees it)"* | The path is on another machine, or the runner's account cannot read it. Use `VCenterCsvText`, or a path that account can read. |
| *"A real run needs -ConfirmVCenter vcenter1"* | Set `ConfirmVCenter` to the first vCenter's short name. |
| *"The real run is locked: no dry run has passed for this CSV yet"* / *"the CSV has changed"* / *"another ISO"* / *"N hours old"* | Run the dry run (Stage 1) with the same CSV, ISO **and log folder**, then the real run within 24 hours. |
| *"A previous run stopped at ... Run again with -Resume ... or -StartFresh"* | Stage 4. |
| *"No credential given: pass -EsxiCredential, or set one of: ..."* | Stage 0.5. The message lists every name it looked for. |
| *"VMware.VimAutomation.Core is not installed for the account running this script"* / *"No SSH client"* | Stage 0.6 -- install for that account (`-Scope AllUsers`). |
| *"... is not digitally signed"* | Stage 0.6, execution policy. |
| *"Cannot log in to ESXi host ... as root"* | Wrong ESXi root password, or the host is in lockdown mode. |
| *"The appliance at ... refused the root credentials (401)"* | Wrong vCenter root password, or it has expired -- check the VAMI. |
| *"could not turn SSH on on <vcenter>"* | The appliance API refused the change. Check the root account in the VAMI; a senior engineer turns SSH on in VAMI -> Access, then run again. |
| *"SSH to <vcenter> as root failed ... aborted by the server"* | Root password expired or locked after failed logins. Check in the VAMI and with PuTTY. |
| *"Nothing answered SSH on port 22"* | A firewall blocks port 22 from the runner, or the name does not resolve. (SSH itself is turned on by the script.) |
| *"could not tell which VM is the vCenter ... put its inventory name in the CSV's VmName column"* | Fill in `VmName` for that row. |
| *"<vcenter> is in the SSO domain but not in the CSV"* | Every vCenter in the group must be in the CSV. |
| *"the host does not see datastore ..."* / *"... is not on datastore ..."* | Wrong ISO path, or that host cannot see the datastore (Stage 0.3). |
| *"... is the full installer ISO"* | Use the `-patch-FP.iso`. |
| *"N pre-upgrade error(s) ... add -ProceedOverPreCheckErrors"* | Fix the errors and dry-run again. Proceed only with a senior engineer's agreement. |
| *"the installer asks '...' (data item '...') and offers no default"* | A senior engineer decides the answer; re-run with `InstallerAnswers @{ '<item>' = '<answer>' }`. |
| *"Stopped waiting for the shutdown ... (-AllowHardPowerOff would have ...)"* | A vCenter did not shut down in 20 minutes. Senior engineer checks its console; resume, with `AllowHardPowerOff` only if agreed. |
| *"... is waiting on a question on its ESXi host"* | Senior engineer answers it in the ESXi Host Client. |
| *"services were not all started after 60 minute(s)"* | Senior engineer checks VAMI -> Services, then `Resume`. |
| *"SSH is left ON on ..."* | Expected after a failure or STOP: `Resume` turns it off when it completes. If the upgrade is abandoned, turn it off in each VAMI (Access). |
