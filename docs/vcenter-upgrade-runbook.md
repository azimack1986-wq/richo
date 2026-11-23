# vCenter Upgrade Runbook -- Midrange vCenter Upgrade Tool

A step-by-step guide to upgrading (patching) the vCenters of a VMware vSphere Foundation
(VVF) Enhanced Linked Mode group with the **Midrange vCenter Upgrade Tool**. Follow it top to
bottom and tick each box as you go. Do not skip a step. If anything on screen does not match
what this guide says, **stop and ask a senior engineer** before going on.

Written for: `Start-VvfUpgradeGui.ps1` 1.3.0, `Invoke-VvfVCenterUpgrade.ps1` 2.4.0 and
`Set-VvfUpgradeToolSignature.ps1` 1.0.0, or later.
The reference for everything the scripts do is [`tools/README.md`](../tools/README.md).

---

## What the tool does, in plain words

For every vCenter in your list, one at a time (one "round" each):

1. Shuts **all** the vCenters in the group down together and takes an **offline snapshot** of
   each (one rollback point for the whole SSO domain).
2. Powers them all back on and waits until every vCenter has **every service started** and
   **replication** between them is healthy.
3. Upgrades **one** vCenter from the patch ISO, reboots it, and waits again until the whole
   group is healthy.
4. Checks that vCenter after the upgrade, then moves on to the next round.

At the end it unmounts the ISO from every vCenter and leaves the snapshots for Aria Operations
to clean up (after 7 days). If anything fails, it stops and lets you **Retry** that vCenter, or
stop and **Resume** later -- nothing further is upgraded until the failure is dealt with.

> **Outage:** while the vCenters are shut down for each round's snapshot, the whole SSO domain
> is unavailable -- nobody can log in to any vCenter in the group. Expect this once per vCenter.
> Plan the change window for it.

**How long it takes:** roughly 45-90 minutes per vCenter (shutdown, snapshot, boot, install,
reboot, checks). Five vCenters: allow 5-8 hours. Keep the jumpbox session open the whole time.

---

## Stage 0 -- Before the change window (the day before)

### 0.1 Approvals and people

- [ ] The change is approved, and the window allows for one SSO outage per vCenter.
- [ ] You know which **senior engineer** is on call during the window.
- [ ] Users and teams that use these vCenters (and anything that depends on them, such as
      backup, Aria, Horizon or automation) have been told about the outages.

### 0.2 Backups

- [ ] A **file-based backup** has been taken from each vCenter's VAMI
      (`https://<vcenter>:5480` -> Backup). The snapshots are a rollback point, not a backup.
- [ ] vCenter HA is **not** configured on any of the vCenters (it must be removed before
      patching; the tool warns if it finds it).

### 0.3 The patch ISO

- [ ] Download the **patch** ISO for the target version from Broadcom. Its name ends in
      `-patch-FP.iso`, for example
      `VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso`.
      **Not** the full installer (`VMware-VCSA-all-...iso`) -- the tool refuses that one.
- [ ] Upload it to the **software repository datastore** -- a datastore that **every ESXi host
      running one of the vCenters** can see.
- [ ] Write down its **datastore path**: the datastore name in square brackets, then the folder
      and file name inside it, exactly as the datastore browser shows them (names are
      case-sensitive):

      ```
      [SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso
      ```

      To find it: ESXi Host Client or vSphere Client -> **Storage** -> the datastore ->
      **Datastore browser** -> open the folder -> note the folder and file names.
      It is **not** a Windows path (`C:\...`, `\\server\share\...`) and not a browser URL.

### 0.4 The vCenter CSV

- [ ] Find out **every** vCenter in the SSO domain (Enhanced Linked Mode group), and for each
      one the **ESXi host its VM is running on right now** (vSphere Client -> the vCenter VM ->
      Summary -> Host).
- [ ] Create a CSV file in Notepad (or start from
      [`docs/vcenter-upgrade.sample.csv`](vcenter-upgrade.sample.csv)) -- one line per vCenter,
      **in the order you want them upgraded**:

      ```csv
      VCenter,EsxiHost,VmName
      vcenter1.corp.local,esx01.corp.local,vcenter1
      vcenter2.corp.local,esx02.corp.local,vcenter2
      vcenter3.corp.local,esx03.corp.local,
      ```

      | Column | What to put in it |
      |---|---|
      | `VCenter` | The vCenter's full name (FQDN). |
      | `EsxiHost` | The ESXi host its VM runs on **now**. |
      | `VmName` | Optional: the VM's name in the inventory, if it is different from the vCenter name. Leave empty otherwise. |

      Rules: the first line must be the header exactly as above. Lines starting with `#` are
      ignored. **Every** vCenter in the SSO domain must be in the file, even ones you do not
      plan to change -- the tool checks the list against the domain and stops if one is
      missing. Save it as e.g. `D:\Upgrades\vcenters.csv`.
- [ ] If any vCenter VM is moved to another host (vMotion/DRS) before the window, update
      `EsxiHost`. Ask for DRS to be set to manual (or the VMs pinned) for the window.

### 0.5 Accounts and passwords

You will need, and should check **before** the window:

- [ ] **ESXi root** password for the hosts in the CSV. Try logging in to each host's Host
      Client (`https://<esxi-host>/ui`) as root. A host in **lockdown mode** refuses this --
      ask for lockdown to be disabled for the window.
- [ ] **vCenter appliance root** password. Log in to each VAMI (`https://<vcenter>:5480`) as
      root. If it says the password has **expired**, change it now.
- [ ] **SSO administrator** (usually `administrator@vsphere.local`) and its password.
- [ ] Do all hosts share one root password? Do all vCenters? If not, you will tick
      **"different root passwords"** in the tool and be asked for each one.

### 0.6 The jumpbox

- [ ] A Windows jumpbox that can reach every ESXi host (port 443) and every vCenter (ports
      443, 5480 and 22).
- [ ] **VMware PowerCLI** and **Posh-SSH 4 or later** are installed. In PowerShell:

      ```powershell
      Get-Module VMware.PowerCLI, Posh-SSH -ListAvailable | Select-Object Name, Version
      ```

      If either is missing:

      ```powershell
      Install-Module VMware.PowerCLI -Scope CurrentUser
      Install-Module Posh-SSH -Scope CurrentUser
      ```

      (On a jumpbox with no internet access, ask a senior engineer -- the modules are copied
      in by hand.)
- [ ] Copy these files from `main` into **one** folder, e.g. `D:\Upgrades\tool`:
  - `tools/Invoke-VvfVCenterUpgrade.ps1` -- the upgrade script
  - `tools/Start-VvfUpgradeGui.ps1` -- the window
  - `tools/Set-VvfUpgradeToolSignature.ps1` -- the signing helper
  - optional: your organisation's approved vSphere icon as `vsphere-icon.png`
- [ ] **Unblock and check the files** (otherwise PowerShell says *"not digitally signed"*).
      Every new copy needs this again. Files copied in from an internal file share are not
      blocked; files downloaded with a browser (e.g. from GitHub) are.

      1. Open **Windows PowerShell** (Start -> Windows PowerShell). The prompt must start with
         **`PS`**, e.g. `PS C:\Users\you>`. If it starts with just `C:\...>`, you are in Command
         Prompt -- type `powershell` and press Enter first.
      2. Go to the tool folder and unblock the files. Type it exactly -- `Unblock-File`, not
         "Unlock":

         ```powershell
         cd D:\Upgrades\tool
         Unblock-File .\*.ps1
         ```

      3. Check them with the signing helper -- it reports and changes nothing:

         ```powershell
         .\Set-VvfUpgradeToolSignature.ps1 -CheckOnly
         ```

         - **"RESULT: every file of the tool will run"** -> done, go to Stage 1.
         - A file **"is not signed"** under **AllSigned** -> this jumpbox needs the files
           *signed*, not just unblocked. Run `.\Set-VvfUpgradeToolSignature.ps1 -TrustPublisher`:
           it signs them with your code-signing certificate and trusts it for your account.
         - The helper itself will not start (*"not digitally signed"*, even after step 2) -> the
           jumpbox is **AllSigned**. A senior engineer signs the helper once (see
           *First time on an AllSigned jumpbox* below); after that it keeps itself signed.
         - **"ask a senior engineer"** (no code-signing certificate on your account, or policy
           `Restricted`) -> do so.

      Never run the tool with `-ExecutionPolicy Bypass` or from a batch file that does: the
      signature is how the jumpbox knows these are the reviewed copies.

  - *First time on an AllSigned jumpbox* (senior engineer, at the PowerShell prompt -- commands
    typed at the prompt are not blocked by the policy, only script files are):

    ```powershell
    cd D:\Upgrades\tool
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Sort-Object NotAfter -Descending | Select-Object -First 1
    $cert | Format-List Subject, NotAfter, Thumbprint     # check it is the organisation's code-signing certificate
    Set-AuthenticodeSignature -FilePath .\Set-VvfUpgradeToolSignature.ps1 -Certificate $cert -HashAlgorithm SHA256 -TimestampServer http://timestamp.digicert.com
    .\Set-VvfUpgradeToolSignature.ps1 -TrustPublisher
    ```

    Leave out `-TimestampServer ...` (or use an internal one) if the jumpbox cannot reach it.

---

## Stage 1 -- Open the tool

1. Open **Windows PowerShell 5.1** (Start -> Windows PowerShell) and run:

   ```powershell
   D:\Upgrades\tool\Start-VvfUpgradeGui.ps1
   ```

   Or, with PowerShell 7:

   ```powershell
   pwsh -STA -File D:\Upgrades\tool\Start-VvfUpgradeGui.ps1
   ```

2. The **Midrange vCenter Upgrade Tool** window opens.
   - [ ] Check the banner and title bar show **window v1.3.0** (or later) and **upgrade script
         v2.4.0** (or later). If not, you have an old copy -- stop and get the current files.
   - [ ] Under the buttons, the **Signing:** line is green (*"... will run under the ...
         policy"*). If the window instead offers to unblock, sign, or trust the publisher of the
         upgrade script, read the question and answer **Yes** -- or ask a senior engineer if you
         are not sure. If the line stays red, see [Troubleshooting](#troubleshooting).

> Do not close the PowerShell window behind the tool -- the tool runs inside it.

---

## Stage 2 -- Fill in the Setup section

1. **vCenter CSV** -> **Browse...** -> choose your CSV.
   - [ ] The preview table underneath lists every vCenter, in your upgrade order, with its
         ESXi host. If you see an error instead, fix the CSV (Stage 0.4) and choose it again.
2. **Patch ISO** -> type the datastore path from Stage 0.3. The grey text under the box shows
   the format.
3. **ESXi root password** and **vCenter root password** -> type them.
   - If the hosts or vCenters do **not** share one password, tick **"The ESXi hosts or vCenters
     have different root passwords"** instead -- you will be asked for each one during the run.
4. **SSO administrator** -> usually `administrator@vsphere.local` (filled in for you).
   **SSO password** -> type it.
5. **Log folder** -> leave the default unless told otherwise. Everything the run writes goes
   here; you will need it at the end.

The CSV path, ISO path, SSO user and log folder are remembered next time. Passwords never are.

---

## Stage 3 -- Dry run (always first)

The dry run checks everything and **changes nothing**. The **Upgrade** button stays locked until
a dry run of the same CSV and ISO has passed in the last 24 hours.

1. Click **Dry run**.
2. Watch the **Progress** tab: the phases run in order:
   `1. vCenters and their ESXi hosts` -> `2. Credentials and connections` ->
   `3. Enhanced Linked Mode` -> `4. Upgrade ISO` -> `5. Pre-upgrade checks` -> `6. Dry run result`.
   It takes a few minutes.
3. When it finishes, read the status line at the bottom:
   - **"Dry run PASSED"** -> go to step 4.
   - **"Dry run FAILED"** -> open the **Findings** tab, read every **Error** row (red), fix the
     cause (see [Troubleshooting](#troubleshooting)), and run the dry run again. Do not go on
     until it passes.
4. Open the **Findings** tab and read it all, even when it passed:
   - [ ] **No Error rows.**
   - [ ] Read every **Warning** row (yellow) and tell the senior engineer about any you do not
         understand -- for example disk space, a root password or certificate about to expire,
         or "vCenter HA is running".
   - [ ] The **Upgrade ISO** rows show each vCenter sees the update (a target version), or say the
         ISO will be mounted by the real run.
   - [ ] A **"Checks skipped -- SSH is off"** warning is normal in a dry run when SSH is turned
         off on a vCenter: the dry run does not turn it on, the real run does (and turns it off
         again at the end).
5. Under the buttons, the line now reads **"Dry run passed at ... Upgrade is allowed."** and the
   **Upgrade** button is enabled.

> If you edit the CSV (even a comment) or change the ISO path after the dry run, **Upgrade locks
> again** -- run the dry run again.

---

## Stage 4 -- Start the upgrade

Only inside the approved change window, with the senior engineer reachable.

1. Click **Upgrade**.
2. The run repeats the checks (phases 1-5), **mounts the ISO** on every vCenter and has each
   one validate it. Nothing is shut down yet.
3. A dialog asks you to **type the first vCenter's short name** (for example `vcenter1`) to
   start. Read what it says it will do.
   - Type the name exactly -> **Continue**. From here on the vCenters will be shut down.
   - Not sure? **Cancel** -- nothing has been shut down or changed (apart from the ISO being
     mounted, which the next run reuses).
4. If the pre-upgrade checks found errors, a dialog asks you to type **PROCEED** instead.
   **Do not type PROCEED without a senior engineer's agreement.** Cancel, fix the errors, dry
   run again.

---

## Stage 5 -- Watch the rounds

Each vCenter gets one round. On the **Progress** tab:

- The heading shows `7.1 Round 1 of N: vcenter1 -> <target version>`.
- Each vCenter has a row. Its **Stage** moves through, in order:
  `Shutting down` -> `Snapshot taken` -> `Powering on` -> `Waiting for services` ->
  `Services started` -> (for the vCenter being upgraded) `Installing NN%` -> `Installed` ->
  `Rebooting` -> `Rebooted` -> `Post-upgrade checks` -> **`Upgraded`** (green).
- The **Log** tab shows every step with times. Lines like
  `service check 1 of 5 vCenter(s) at the same time took 00:01:12` are normal.

What is normal, and what is not:

| You see | Normal? |
|---|---|
| All vCenters "Shutting down", then "Snapshot taken" | Yes -- the group is snapshotted together each round. The SSO domain is down now. |
| "Waiting for services ... 34/41 automatic services started" for 10-20 minutes after a power-on or reboot | Yes -- vCenter takes time to start. It is checked every 60 seconds, up to 60 minutes. |
| "Installing 0%" for a while, then rising | Yes -- the installer stages the packages first. |
| "a partner is behind -- re-reading in 30s" | Yes, a few times after a reboot -- replication catches up. |
| A row turns **red (FAILED)** | No -- see Stage 6. |
| Nothing new in the Log for over 30 minutes | Ask the senior engineer to check the vCenter consoles. Do not close the window. |

**Do not** close the window, log off the jumpbox, or let it sleep during the run. The window
refuses to close while a run is going.

### Questions the run may ask

A dialog appears and the run waits for your answer:

| Dialog | What to do |
|---|---|
| **Hard power-off** -- *"Type POWEROFF to hard power them off"* | A vCenter did not shut down by itself within 20 minutes. **Ask the senior engineer** before typing POWEROFF. Cancel fails the round instead, and you get the Retry / Stop dialog (Stage 6). |
| **Which VM is the vCenter?** | The tool could not tell which VM is the vCenter. Type the number from the list of the vCenter's VM; blank stops. Then fix `VmName` in the CSV for next time. |
| **The installer asks** | The patch installer wants an answer. The default shown is normally right; if unsure, ask. |
| **ESXi root / vCenter appliance root** (only with "different root passwords" ticked) | Enter the root password for the host or vCenter named in the dialog. |

---

## Stage 6 -- If a vCenter fails

The row turns red, the Log shows `FAILED on <vcenter> (<stage>): <reason>`, and a dialog
**"A vCenter failed"** shows the vCenter, the stage it reached and the error. **Nothing else is
upgraded until this is dealt with.**

1. **Read the error** and take a screenshot of the dialog.
2. **Tell the senior engineer.** Together, check the vCenter in its VAMI and console, and fix
   the cause (the Log and Findings tabs help).
3. Then choose:
   - **Retry** -- carries on with that vCenter **from the stage it reached** (it does not start
     again from the beginning). If the install had not started yet, you are asked whether to
     take a fresh snapshot first -- **Yes** (the default) is the safe answer.
   - **Stop** -- ends the run here. Progress is saved. Fix things at your own pace, then go to
     [Stage 8 -- Resume](#stage-8----resume-after-a-stop-or-failure).

---

## Stage 7 -- Pausing: Stop safely

If you have to pause (the window is ending, something needs changing, you are asked to stop):

1. Click **Stop safely** -> **Yes**.
2. The run **finishes the step it is on** and then stops. It never stops in the middle of a
   group shutdown/snapshot/power-on (it waits until every vCenter is back) or in the middle of
   an install (it finishes the install, the reboot and that vCenter's checks). This can take
   a while -- the status line says what it is finishing.
3. When it has stopped, the status line reads **"Run STOPPED SAFELY"** and the Log lists
   **Upgraded:** and **Still to do:**. Progress is saved and the ISO is left mounted.
4. Continue later with [Stage 8](#stage-8----resume-after-a-stop-or-failure).

**Stop NOW** (pressing the button a second time) is for **emergencies only**, and only with a
senior engineer: it stops in the middle of whatever is happening and can leave vCenters
powered off, a snapshot half taken or an install running. Every vCenter must then be checked
by hand before resuming.

---

## Stage 8 -- Resume after a stop or failure

1. Open the tool (Stage 1). Use the **same CSV** and the **same log folder**.
2. Under the buttons, a line reads **"A previous run stopped at <vcenter> (<stage>) ... Resume
   carries on from there."**
3. Enter the passwords (Stage 2). The ISO box can be left as it was.
4. Click **Resume**. Type the first vCenter's name when asked. The vCenters already upgraded are
   checked and skipped; the run carries on with the one that stopped. If its install had not
   started yet, a fresh group snapshot is taken first; if it had, it carries on from the reboot
   or the checks.

---

## Stage 9 -- The end of the run

In phase **8. Wrap-up**:

1. **The ISO is unmounted** from every vCenter. Each should show **"ISO unmounted"**. The log may
   say `ejected /dev/sr0 inside the appliance` or `answered the CD-ROM lock question -- Yes,
   disconnect anyway` -- both are normal.
   - Any **"ISO NOT unmounted -- <reason>"**: the upgrade is still complete. Note the reason and
     the vCenter; the senior engineer disconnects that CD-ROM by hand (ESXi Host Client -> the
     VM -> Edit settings -> CD/DVD drive -> untick Connected, set to Client device).
2. **Snapshots**: a dialog asks **"Remove all N pre-upgrade snapshot(s) now instead?"** Answer
   **No** (the default) -- Aria Operations removes them after 7 days, and they are your rollback
   point until then. Only answer Yes if the senior engineer tells you to.
3. The status line reads **"Upgrade FINISHED: every vCenter is upgraded."**

---

## Stage 10 -- Check and hand over

- [ ] **Findings** tab: no **Error** rows in the post-upgrade findings. Note any new Warnings.
- [ ] Log in to each vCenter's **VAMI** (`https://<vcenter>:5480`) -> **Summary**: the version is
      the target version, and **Health** is Good.
- [ ] Log in to the **vSphere Client** on one vCenter: all the linked vCenters appear, and hosts
      and VMs are shown as connected.
- [ ] Click **Open log folder** and keep these files with the change record:
  - `vcenter-upgrade-gui-<time>.log` -- everything the run printed
  - `findings-<vcenter>-<time>.csv` -- every check, before and after
  - `upgrade-log-lines-<vcenter>-<time>.txt` -- installer log excerpts, if any
- [ ] Tell the senior engineer the run is complete, and close the change.
- [ ] Ask for DRS / lockdown settings changed for the window to be set back.

### Rolling back (senior engineer only)

If a vCenter is broken after its upgrade: in ELM, **revert ALL vCenters in the group to the same
round's snapshot, together -- never one alone** (the snapshot description says which round).
Power them all off, revert each, power them all on. Never do this without a senior engineer.

---

## Troubleshooting

| Message or symptom | What it means / what to do |
|---|---|
| *"...is not digitally signed. You cannot run this script..."* | The files are blocked (downloaded) or unsigned. At the PowerShell prompt in the tool folder: `Unblock-File .\*.ps1`, then `.\Set-VvfUpgradeToolSignature.ps1 -CheckOnly` (Stage 0.6). |
| *"The term '...' is not recognized as the name of a cmdlet, function, script file, or operable program"* | Check the spelling (`Unblock-File`, not "Unlock-File"), and that the prompt starts with **`PS`** -- in Command Prompt (`C:\...>`) PowerShell commands do not exist; type `powershell` first. |
| *"Signing: ... will NOT run ..."* (red, under the buttons) | The upgrade script would not run. Answer Yes to the window's offer, or run `.\Set-VvfUpgradeToolSignature.ps1` (with `-TrustPublisher` if it names an untrusted publisher). *"Ask a senior engineer"*: you have no code-signing certificate, or the signer's root is not trusted. |
| *"Do you want to run software from this untrusted publisher?"* at the console | Answer **[A] Always run** only if the publisher shown is your organisation's code-signing certificate; otherwise stop and ask. `-TrustPublisher` on the helper does the same. |
| *"The window needs PowerShell in STA mode"* | Start it with `pwsh -STA -File ...`, or use Windows PowerShell 5.1. |
| *"The upgrade script was not found"* / *"needs Invoke-VvfVCenterUpgrade.ps1 2.3.0 or later"* | Both files must be in the same folder and current. Copy both from `main` again. |
| *"Posh-SSH is not installed"* / *"VMware.PowerCLI is not installed"* | Stage 0.6: install the module, or ask a senior engineer. |
| **Upgrade** button greyed out | Read the red line under the buttons: no dry run yet, the CSV or ISO changed since it, or it is over 24 hours old. Run the dry run again. |
| *"Cannot log in to ESXi host ... as root"* | Wrong ESXi root password, or the host is in lockdown mode. |
| *"The appliance at ... refused the root credentials (401)"* | Wrong vCenter root password, or it has expired -- check the VAMI. |
| *"SSH to <vcenter> as root failed while connecting and logging in: An established connection was aborted by the server"* | The vCenter dropped the SSH login: usually the root password has **expired** or is **locked** after failed logins. Log in to the VAMI and with PuTTY as root to see; change or wait, then dry run again. |
| *"Nothing answered SSH on port 22"* | SSH is off on the vCenter (VAMI -> Access) or a firewall blocks the jumpbox. |
| *"<vcenter> is in the SSO domain but not in the CSV"* | Every vCenter in the group must be in the CSV. Add the missing line, dry run again. |
| *"the host does not see datastore 'SoftwareRepo'"* / *"File ... was not found"* | The ISO path is wrong, or that host cannot see the datastore. Check the path in the datastore browser (Stage 0.3). |
| *"... is the full installer ISO"* | Wrong ISO -- use the `-patch-FP.iso`. |
| *"... is waiting on a question on its ESXi host"* | A question is pending on the VM in the ESXi Host Client. Ask a senior engineer to look at it and answer it. |
| *"vCenter HA ... remove vCenter HA before patching"* | vCenter HA must be removed first. Senior engineer task. |
| *"services were not all started after 60 minute(s)"* | A vCenter did not finish starting. Senior engineer checks its VAMI -> Services, then **Retry**. |
| Window says *"A run is going..."* when you try to close it | Use **Stop safely** first (Stage 7), then close. |

---

## Appendix -- running without the window (console)

For engineers comfortable at the console, the same script runs on its own and asks the same
questions in the PowerShell window:

```powershell
cd D:\Upgrades\tool
.\Invoke-VvfVCenterUpgrade.ps1 -VCenterCsv D:\Upgrades\vcenters.csv -IsoPath '[SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso' -DryRun
.\Invoke-VvfVCenterUpgrade.ps1 -VCenterCsv D:\Upgrades\vcenters.csv -IsoPath '[SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso'
.\Invoke-VvfVCenterUpgrade.ps1 -VCenterCsv D:\Upgrades\vcenters.csv -Resume
```

- At a failure, type **RETRY** to carry on with that vCenter, or press Enter to stop.
- To **stop safely** from the console, create an empty file named `STOP` in the log folder
  (`New-Item .\vcenter-upgrade-logs\STOP`); the run stops at the next safe point.
- Exit codes: `0` all upgraded (dry run: would proceed), `1` stopped on a failure (dry run:
  would stop), `2` stopped safely because you asked.
