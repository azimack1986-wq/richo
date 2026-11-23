# =============================================================================
#  Invoke-VvfVCenterUpgrade.ps1
#
#  VERSION : 3.0.1
#  OUTPUT  : progress text, a transcript, a findings CSV, a resume state file
#            and a summary object -- offline snapshots and ISO-based upgrades of
#            the vCenters listed in a CSV (an Enhanced Linked Mode group), one per
#            round. One file, no prompts: built to be run by a job/automation
#            front end (or at a console) with every input given as a parameter.
#  Check VERSION above before running. If it is not what you expect, this is an
#  old copy of the file. The run also prints the version as its first output
#  line.
# =============================================================================
#
#  HISTORY : every change to this file gets a new version, newest first. The
#            top entry must match VERSION and $ScriptVersion below.
#    3.0.1  The whole process is this one file: no companion scripts, test
#           harnesses or sample files are needed. The CSV template is in the
#           help (.PARAMETER VCenterCsv). No change to what a run does.
#    3.0.0  ONE SCRIPT, NO PROMPTS. Start-VvfUpgradeGui.ps1 and
#           Set-VvfUpgradeToolSignature.ps1 are retired: this file is the whole
#           tool, for uploading into a script-runner / automation front end. The
#           run never waits for an answer -- a front end that cannot answer would
#           hang on it -- so every question is now a parameter:
#             confirm-start      -> -ConfirmVCenter <first vCenter's short name>
#             proceed-over-errors-> -ProceedOverPreCheckErrors
#             hard-poweroff      -> -AllowHardPowerOff
#             remove-snapshots   -> -RemoveSnapshots
#             resume             -> -Resume, or -StartFresh (moves the state aside)
#             retry              -> gone: a failure stops the run (exit 1);
#                                   fix it, then run again with -Resume
#             vm-pick            -> set VmName in the CSV
#             installer-question -> its default, or -InstallerAnswers
#             credentials        -> parameters, else SecretManagement, else
#                                   RICHO_* environment variables (per host or
#                                   per vCenter first, for different passwords)
#           -Prompter, -OnEvent and -StopSignal (GUI hooks) are removed; a STOP
#           file in -LogFolder still stops the run safely. The CSV can be given
#           as text (-VCenterCsvText) for a front end with a text box. The rule
#           the window enforced is now the script's own: a real run (not a
#           resume) needs a passing dry run of the same CSV and ISO in the same
#           -LogFolder in the last 24 hours (-SkipDryRunCheck overrides, loudly).
#           -LogFolder defaults to %ProgramData%\VvfVCenterUpgrade, not the
#           current folder, which a front end may change from run to run.
#           SSH, ALL AUTOMATIC: it is turned on on every vCenter at the start --
#           now in a dry run too, so no check is skipped; the dry run turns it
#           back off at its end -- confirmed on again after every power-on and
#           reboot, and turned off on every vCenter once the LAST vCenter is
#           upgraded and the ISO unmounted (the guest-side unmount needs it).
#           Which vCenters the run turned it on for is kept in the state file, so
#           a stopped run that is resumed still turns them off at its end. A run
#           that stops part way leaves SSH on (the resume, and whoever looks at
#           the failure, need it) and says so. -SshFinalState Disable turns it off
#           at the end on every vCenter, also those where it was on before.
#           Ends with a per-vCenter summary table and a result object.
#    2.5.2  plink sends each command as an SSH exec request (-m <file>), the way
#           Posh-SSH always has, instead of over a login shell's input. Seen live:
#           on a production vCenter the service read over plink returned no
#           output at all with exit status 0 -- even its first 'echo' never ran
#           -- while short commands worked: something in that login took the
#           input before bash ran it. The command file sits beside the password
#           file (the current user's temp folder) and goes when the command ends,
#           so neither the command nor any password is ever on a command line.
#           plink's own notices (the username line, the login banner) are left
#           out of the error text a finding quotes.
#    2.5.1  Seen live (production, over plink): the service check came back empty --
#           "vmon is not answering yet", "service-control is not answering yet" --
#           on a vCenter whose other SSH checks worked. When the parallel service
#           read (2.2.0) returns nothing, it is now read again one service after
#           another, the 2.1 way, and the run says so; and when even that returns
#           nothing, the finding quotes what the command did return -- its first
#           lines, its error output and its exit status -- instead of guessing.
#           The parallel read no longer depends on a temporary folder: without one
#           it reads one after another. /storage/archive (vPostgres' archive
#           partition, which the patch does not use) is reported as a warning,
#           never an error, however full -- seen live at 95%, which locked a
#           production run.
#    2.5.0  SSH through PuTTY's plink.exe where Posh-SSH cannot be used (seen live:
#           corporate antivirus blocks Posh-SSH's Renci.SshNet.dll). -SshClient
#           Auto (default) uses Posh-SSH when it loads, else plink; PoshSSH or
#           Plink forces one; -PlinkPath names plink.exe (else the PATH, then
#           Program Files\PuTTY). plink 0.77 or later is required: the password
#           goes in a temporary file read with -pwfile (only the current user's
#           temp folder, deleted when the command ends), never on a command line,
#           and each command -- the replication check carries the SSO password --
#           goes over plink's input, not its arguments. A vCenter whose SSH host
#           key PuTTY has not seen is trusted for the run on first use, its
#           fingerprint logged and pinned (-hostkey); one whose key differs from
#           PuTTY's cache is refused. Root must log in to bash for plink (the
#           appliance shell is reported with how to change it). Commands still
#           run on every vCenter at the same time, one plink process each.
#    2.4.0  The ISO is unmounted without anyone answering the CD-ROM lock question.
#           Seen live: on all five vCenters of a group the ISO stayed mounted at
#           the end -- the appliance (Photon OS) keeps the virtual CD-ROM door
#           locked even with nothing mounted, so ESXi holds the eject on "The
#           guest operating system has locked the CD-ROM door ... Disconnect
#           anyway?", which until now needed answering by hand in the host
#           client. Now: inside the appliance the ISO is unmounted and then
#           ejected (which unlocks the door); the host-side disconnect runs as
#           a task that is watched rather than a call that blocks; and if the
#           lock question still appears, it is answered Yes -- that question
#           only, and only once the appliance has released the ISO. A lock
#           question already pending is answered the same way. Any other
#           question is reported, never answered. A disconnect that does not
#           finish in 3 minutes is reported, not waited on forever.
#    2.3.0  Stop safely. A stop can be asked for at any time -- a file named STOP in
#           -LogFolder, or -StopSignal (a script block, for a front end) -- and
#           the run stops at the next safe point: before the ISO is mounted,
#           before the start is confirmed, or between rounds. A group shutdown,
#           snapshot and power-on, or an install, reboot and its checks, is
#           finished first: stopping with the SSO domain down or mid-install is
#           the worst place to stop. A stop saves the progress, turns SSH back
#           off where the run turned it on, leaves the ISO mounted for -Resume,
#           says which vCenters are done and which are still to go, and exits
#           with code 2 (Result event: Stopped). A STOP file left from an
#           earlier run is removed at the start.
#    2.2.0  The group checks run on every vCenter at the same time. Seen live: with
#           five vCenters, each wait for "every service started" and each
#           replication check ran one vCenter after another, about 10 minutes
#           each, so every round spent close to an hour checking -- twice (after
#           the snapshot and after the upgrade). Now the service status command
#           is started on all of them together and collected together, each poll;
#           replication (vdcrepadmin) likewise, with one 30s wait for all that
#           are behind; and the pre-upgrade service checks likewise. On each
#           appliance, service-control and the vmon-cli reads now run alongside
#           each other instead of one after another. Each check logs how long it
#           took. The order of the steps, and what must be true before the next
#           one starts, is unchanged.
#    2.1.1  SSH failures say which vCenter, as which user, and at which step
#           (connecting, logging in, switching to bash), with the likely causes:
#           a dropped login ("connection aborted by the server") points at an
#           expired or locked root password or an SSH algorithm mismatch; a
#           refused password at a wrong or different root password; no answer
#           at SSH being off or blocked. Seen live: three of five vCenters showed
#           only the library's bare "An established connection was aborted by
#           the server."
#    2.1.0  Hooks for a front end (the GUI to come); the console run is unchanged.
#           -Prompter: every question goes through one function with a fixed id
#           and kind (Text, Typed, YesNo, Credential), to the given script block
#           instead of the console. -OnEvent: what happens is sent as objects --
#           Phase, Log (with level), Findings, Prompt, Plan (every vCenter with
#           VM, host and versions), Round, Node (one vCenter's stage: ShuttingDown,
#           Snapshotted, Installing with a percentage, Rebooting, Upgraded,
#           Failed, IsoUnmounted, ...) and Result. A listener that throws is
#           ignored, never stops a run. A passing dry run writes
#           dryrun-<vcenter>.json (time, CSV SHA-256, ISO path) and a failing
#           one removes it, so a front end can hold back a real run until a
#           matching dry run has passed recently.
#    2.0.0  Driven by a CSV and a datastore ISO. -VCenterCsv (VCenter,EsxiHost
#           [,VmName], in upgrade order) replaces -EsxiHost, -VCenter,
#           -VCenterVmName, -LinkedVCenter and the per-vCenter host prompts; the
#           CSV is checked against the SSO domain's own list (vdcrepadmin
#           showservers), and a member left out is an error. -IsoPath takes the
#           patch ISO pre-positioned on a datastore; every ESXi host in the CSV
#           must see the file. The run mounts it on every vCenter (connected,
#           and at power on) and has each appliance validate it before anything
#           else changes. At the end the ISO is unmounted from every vCenter
#           automatically -- released inside the appliance first, so the eject
#           does not hang on the CD-ROM lock -- and when it cannot be, the run
#           says why: the processes still using it, a question pending on the
#           VM, or the host's error. Snapshot removal still defaults to no;
#           the prompt says Aria Operations normally removes them after 7 days.
#           A failure leaves the ISO mounted for -Resume, which reuses its path.
#    1.3.1  Reboot after the install, hardened. Seen live: the instant the
#           installer reported "complete", the API gateway answered 500
#           (badGateway) while the services behind it restarted, the reboot
#           request was sent into that and its connection was cut ("response
#           ended prematurely"), and the round failed with vCenter fine. Now:
#           the API must answer again (500s and dropped connections are waited
#           out, up to 10 minutes) before the reboot is decided on; a reboot
#           request that gets no clean answer is taken as possibly started and
#           watched; a request that was not acted on (vCenter still answering
#           with its old uptime 5 minutes later) is sent once more. A 4xx still
#           fails at once. A version read that fails just as the install ends
#           is read again instead of ending the install as "wrong version".
#    1.3.0  Enhanced Linked Mode, reworked: every vCenter in the group is
#           upgraded, one per round. Each round shuts down ALL of them together,
#           snapshots them while all are off (one consistent rollback point),
#           powers them on and waits until every one has every service started
#           and replication is healthy; then upgrades that round's vCenter,
#           reboots it, and waits for the whole group and replication again.
#           Every vCenter to be upgraded needs its own ISO mounted, checked and
#           prechecked up front. A failure stops the progression: type RETRY to
#           carry on with the failed vCenter from the stage it reached (fresh
#           group snapshot first, by default), or stop and run again later with
#           -Resume -- a state file in -LogFolder records each vCenter's stage.
#           Snapshot names are unique per round and attempt.
#    1.2.0  Enhanced Linked Mode: every vCenter in the group gets an offline
#           snapshot before anything is patched, one vCenter at a time so the
#           SSO domain is never down: shut down, snapshot, power on, wait until
#           every service is started, then the next. Replication is checked once
#           all are back, and the upgrade starts only after that. Asks which ESXi
#           host runs each linked vCenter (default: the same host) and finds its
#           VM there; a dry run does the same lookups.
#    1.1.1  Services: vmon-cli output is parsed in PowerShell by exact field name.
#           The old in-shell match on "RunState" also caught the later
#           "CurrentRunStateDuration(ms)" line, so every service read as not
#           started. No vmon output at all is now an error, not silence.
#           API: a login is kept only if it is authorized for the appliance
#           calls (probed with a read of the SSH setting). Tried in order: root on
#           5480, the SSO administrator on 443, root on 443 -- root can log in to
#           443 on some builds and then get 403 on every appliance call. The
#           login in use is printed. The SSO credential is asked for earlier.
#    1.1.0  -DryRun: every read-only step (host, VM, ISO, pre-upgrade checks,
#           installer precheck and validate, ELM replication), then a verdict on
#           whether a real run would proceed. Changes nothing: SSH is not turned
#           on (the checks that need it are skipped and say so) and the CD-ROM is
#           not touched (what a real run would set is reported instead).
#    1.0.0  First version: offline snapshot through the ESXi host, ISO check,
#           pre/post health, stage-and-install with monitoring, reboot and
#           service start-up polling, Enhanced Linked Mode replication checks.
#
#  NOTE: the blank line below is load-bearing. A comment block touching the
#  help block below suppresses comment-based help entirely.

<#
.SYNOPSIS
    Upgrades (patches) every vCenter Server appliance of a VMware vSphere Foundation (VVF)
    Enhanced Linked Mode group from a patch ISO on a datastore, one vCenter per round, with an
    offline snapshot of the whole group before each round and health, service and replication
    checks before and after. One self-contained script that never prompts.

.DESCRIPTION
    Built to be uploaded into a script-runner / automation front end (or run at a console):
    every input is a parameter and the run never waits for an answer. Anything it would have
    asked is either a parameter (below) or a stop with the reason (exit code 1).

    The run, in order:

      1. Reads the vCenter list -- -VCenterCsv (a file) or -VCenterCsvText (its contents) --
         one row per vCenter in upgrade order: VCenter,EsxiHost[,VmName]. Lines starting with
         # are comments. A real run (not -Resume) is refused unless a dry run of the same CSV
         and ISO passed in the same -LogFolder in the last 24 hours, and unless
         -ConfirmVCenter names the first vCenter. Both are checked before anything is touched.
      2. Resolves the credentials (see CREDENTIALS), connects to every ESXi host directly
         (vCenter is about to be shut down), finds each vCenter's VM, opens an appliance API
         session and TURNS SSH ON on every vCenter where it is off (see SSH).
      3. Checks the CSV against the SSO domain's own list of vCenters: every member must be
         in the CSV (each round snapshots all of them together), and nothing else may be.
      4. Checks every ESXi host sees the ISO (-IsoPath), mounts it on every vCenter still to be
         upgraded -- connected, and connected at power on -- and has each appliance confirm it
         sees a newer update on it.
      5. Pre-upgrade checks on every vCenter, recorded as findings: every automatic service
         started, appliance health, disk usage, root password and Machine SSL certificate
         expiry, any earlier failed update, vCenter HA, the installer's own precheck, and
         replication from every vCenter in the group. Errors stop the run before any vCenter
         is shut down (-ProceedOverPreCheckErrors overrides those that can be overridden).
      6. One ROUND per vCenter, in CSV order:
           a. Offline snapshot of the WHOLE group at once: every vCenter shut down
              together, polled until all are off, a snapshot of each (no memory, no quiesce)
              while all are off, all powered on together.
           b. Waits until every vCenter answers, has SSH on, has every service started
              (checked every 60 seconds) and replication is healthy from all of them.
           c. Upgrades that round's vCenter: ISO re-checked, validate, stage-and-install,
              progress every 60 seconds through the installer's service restarts.
           d. Reboots it (unless the installer did), then waits again as in b.
           e. Post-upgrade checks on it, and what is new since its pre-upgrade checks.
      7. Wrap-up, once the LAST vCenter is upgraded: unmounts the ISO from every vCenter
         (released inside the appliance first, over SSH), then turns SSH OFF on every vCenter,
         removes the snapshots only with -RemoveSnapshots (default: kept -- Aria Operations
         normally removes snapshots older than 7 days), and writes the findings CSV.

    SSH. Turned on through the appliance API on every vCenter where it is off, at the start
    of every run -- dry runs included, so no check is skipped. It is confirmed on again after
    every power-on and reboot. It is turned off on every vCenter only once the whole run has
    completed: after the last vCenter's upgrade and the ISO unmount. A dry run turns it off
    again at its end. A real run that stops part way (failure or STOP file) leaves it on --
    -Resume and the person looking at the failure need it -- and records in the state file
    which vCenters it turned it on for, so the run that completes the upgrade turns those off
    too. A run refused before anything was changed (e.g. a failed check before the start)
    puts SSH back as it found it. By default only the vCenters where the run turned SSH on are
    turned off; -SshFinalState Disable turns it off on all of them.

    CREDENTIALS. Never prompted for. Each is taken from, in order: the parameter; a
    SecretManagement secret (Get-Secret, a PSCredential) when that module is loaded; the
    environment variables RICHO_<NAME>_USER and RICHO_<NAME>_PASSWORD (the repo-wide
    convention). Names, most specific first:
        ESXi root          vvf-esxi-<host>        then vvf-esxi
        appliance root     vvf-vcenter-<vcenter>  then vvf-vcenter
        SSO administrator  vvf-sso
    e.g. RICHO_VVF_ESXI_USER / RICHO_VVF_ESXI_PASSWORD, or for one host with a different
    password RICHO_VVF_ESXI_ESX01_CORP_LOCAL_USER / ..._PASSWORD (non-alphanumerics become _).
    A parameter applies to every host / vCenter that has no more specific secret.

    FAILURES. Any failure in a round stops the run (exit code 1): no further vCenter is
    upgraded, the power state of every vCenter VM is shown, and the progress is saved in
    upgrade-state-<vcenter>.json in -LogFolder. Fix the problem and run again with -Resume:
    the failed vCenter carries on from the stage it reached (a fresh group snapshot first if
    its install had not started), and those already done are checked and skipped.

    STOPPING. Create a file named STOP in -LogFolder; the run stops at the next safe point
    (before the ISO is mounted, before the start, or between rounds -- never mid snapshot or
    mid install), exit code 2. -Resume carries on.

    -DryRun runs steps 1 to 5 and stops with a verdict. It mounts nothing and shuts nothing
    down; the only change it makes is SSH, turned on for the checks and off again at the end.

    ENHANCED LINKED MODE AND SNAPSHOTS. Every round's snapshots are taken with ALL vCenters
    in the group powered off together -- Broadcom's guidance for a consistent ELM rollback
    point -- so the SSO domain is down for the length of each round's snapshot. To roll
    back, revert EVERY vCenter to the SAME round's snapshot, never one alone.

    EXIT CODES. 0 all upgraded (dry run: a real run would proceed), 1 stopped on a failure or
    refused (dry run: would stop), 2 stopped safely by a STOP file. The last thing written to
    the output stream is a summary object (ExitCode, Result, Nodes, log paths).

.PARAMETER VCenterCsv
    Path of the CSV of the vCenters to upgrade, one row each, in upgrade order, with the
    columns VCenter (FQDN), EsxiHost (the ESXi host its VM runs on) and optionally VmName (the
    VM's inventory name, when it is not the vCenter name). Lines starting with # are comments.
    Give this or -VCenterCsvText. Every vCenter in the SSO domain must be listed. Template:

        VCenter,EsxiHost,VmName
        vcenter1.corp.local,esx01.corp.local,vcenter1
        vcenter2.corp.local,esx02.corp.local,
        vcenter3.corp.local,esx03.corp.local,

.PARAMETER VCenterCsvText
    The same CSV as text (header line first), for a front end that offers a text box rather
    than a file. The dry-run check compares the contents, so a file and the same text pasted
    match.

.PARAMETER IsoPath
    Datastore path of the patch ISO, e.g. "[SoftwareRepo] ISO/VMware-vCenter-Server-
    Appliance-8.0.3.01000-24305161-patch-FP.iso", on a datastore every ESXi host in the CSV
    can reach. Required, except with -Resume, which reuses the stopped run's.

.PARAMETER EsxiCredential
    ESXi root. See CREDENTIALS. A host in lockdown mode refuses a direct root login.

.PARAMETER VCenterRootCredential
    Appliance root. See CREDENTIALS.

.PARAMETER SsoCredential
    SSO administrator, e.g. administrator@vsphere.local. See CREDENTIALS.

.PARAMETER ConfirmVCenter
    Required for a real run (and a resume): the short name of the FIRST vCenter in the CSV,
    e.g. vcenter1. The stand-in for typing it at the old confirmation: a run whose form was
    filled in for another group does not start. Not needed for -DryRun.

.PARAMETER ProceedOverPreCheckErrors
    Carry on although the pre-upgrade checks found errors (not recommended). Installer
    precheck errors and errors with the CSV, the VMs or vCenter access still stop the run.

.PARAMETER AllowHardPowerOff
    When a vCenter has not shut down by itself within -ShutdownTimeoutMinutes, power it off
    hard. Without it the round fails there instead (and -Resume carries on later).

.PARAMETER RemoveSnapshots
    At the end, remove the snapshots this run took. Default: kept (Aria Operations normally
    removes snapshots older than 7 days; they are the rollback point until then).

.PARAMETER Resume
    Continue a run that stopped (failure or STOP file), from the vCenter it stopped at, using
    the state file in -LogFolder. Use the same CSV.

.PARAMETER StartFresh
    A previous run left an unfinished state file and you do NOT want to resume it: it is
    renamed aside (.abandoned-<time>) and this run starts from the beginning. Without -Resume
    or -StartFresh an unfinished state file stops a real run.

.PARAMETER SkipDryRunCheck
    Allow a real run without a matching passing dry run in the last 24 hours. Logged loudly.

.PARAMETER InstallerAnswers
    Answers to the installer's questions, by data item (e.g. @{ 'some.item' = 'value' }).
    Questions not listed take the installer's default; one with no default stops the run
    before anything is shut down, naming the item. The vmdir/SSO password is answered from
    the SSO credential.

.PARAMETER SshFinalState
    Restore (default): at the end, turn SSH off on every vCenter where this run (or the
    stopped run it resumes) turned it on. Disable: turn it off on every vCenter in the CSV.
    Applies when the whole upgrade completes; a dry run always restores.

.PARAMETER ShutdownPauseSeconds
    Pause after the guest shutdown is requested, before the power state is polled. Default 60.

.PARAMETER ShutdownTimeoutMinutes
    How long to wait for the appliance to power off. Default 20.

.PARAMETER PowerOnPauseSeconds
    Pause after a power-on or reboot before service checks begin. Default 180.

.PARAMETER ServicePollSeconds
    Interval between service checks while waiting for vCenter to start. Default 60.

.PARAMETER ServiceTimeoutMinutes
    How long to wait for every service to start. Default 60.

.PARAMETER UpgradePollSeconds
    Interval between upgrade progress checks. Default 60.

.PARAMETER UpgradeTimeoutMinutes
    How long the upgrade may run before the script gives up watching. Default 240.

.PARAMETER LogFolder
    Folder for the transcript, findings CSV, log excerpts, the dry-run record and the resume
    state. Default %ProgramData%\VvfVCenterUpgrade. The dry run, the real run and any resume
    must use the same folder.

.PARAMETER DryRun
    Every read-only step, then a verdict on whether a real run would proceed. Nothing is
    mounted, shut down, snapshotted or installed; SSH is turned on for the checks and off again
    at the end. Exit code 0 = a real run would proceed, 1 = it would stop. A passing dry run
    writes dryrun-<vcenter>.json in -LogFolder, which a real run requires.

.PARAMETER SshClient
    How the run reaches the appliances over SSH. Auto (default): Posh-SSH when it loads,
    otherwise PuTTY's plink.exe. PoshSSH or Plink: that one only.

.PARAMETER PlinkPath
    The plink.exe to use. Default: plink on the PATH, else Program Files\PuTTY\plink.exe.

.PARAMETER StrictCertificates
    Validate the ESXi and appliance TLS certificates. By default both are accepted
    unvalidated for this session only, because a jumpbox rarely trusts the VMCA root.

.EXAMPLE
    .\Invoke-VvfVCenterUpgrade.ps1 -VCenterCsv D:\Upgrades\vcenters.csv -IsoPath '[SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso' -DryRun

    Every check, then a verdict. Credentials from SecretManagement or RICHO_VVF_* variables.

.EXAMPLE
    $esx = Get-Credential root; $vc = Get-Credential root; $sso = Get-Credential administrator@vsphere.local
    .\Invoke-VvfVCenterUpgrade.ps1 -VCenterCsv D:\Upgrades\vcenters.csv -IsoPath '[SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso' -EsxiCredential $esx -VCenterRootCredential $vc -SsoCredential $sso -ConfirmVCenter vcenter1

    The real run, after a passing dry run of the same CSV and ISO.

.EXAMPLE
    .\Invoke-VvfVCenterUpgrade.ps1 -VCenterCsv D:\Upgrades\vcenters.csv -Resume -ConfirmVCenter vcenter1

    Continues a run that stopped, from the vCenter it stopped at, with the same ISO.

.NOTES
    Requires VMware PowerCLI (VMware.PowerCLI, VCF.PowerCLI, or VMware.VimAutomation.Core)
    and an SSH client: Posh-SSH 4 or later, or PuTTY's plink.exe 0.77 or later where Posh-SSH
    cannot be used (-SshClient). Modules must be visible to the account the front end runs
    the script as (install them -Scope AllUsers, or as that account). Written for Windows
    PowerShell 5.1 and PowerShell 7. Progress is written with Write-Host (the information
    stream in PowerShell 5+) and to the transcript in -LogFolder.
#>
[CmdletBinding()]
param(
    [string]$VCenterCsv,
    [string]$VCenterCsvText,
    [string]$IsoPath,
    [System.Management.Automation.PSCredential]$EsxiCredential,
    [System.Management.Automation.PSCredential]$VCenterRootCredential,
    [System.Management.Automation.PSCredential]$SsoCredential,
    [string]$ConfirmVCenter,
    [switch]$ProceedOverPreCheckErrors,
    [switch]$AllowHardPowerOff,
    [switch]$RemoveSnapshots,
    [switch]$Resume,
    [switch]$StartFresh,
    [switch]$SkipDryRunCheck,
    [hashtable]$InstallerAnswers = @{},
    [ValidateSet('Restore', 'Disable')] [string]$SshFinalState = 'Restore',
    [ValidateRange(0, 3600)] [int]$ShutdownPauseSeconds = 60,
    [ValidateRange(1, 240)]  [int]$ShutdownTimeoutMinutes = 20,
    [ValidateRange(0, 3600)] [int]$PowerOnPauseSeconds = 180,
    [ValidateRange(5, 3600)] [int]$ServicePollSeconds = 60,
    [ValidateRange(1, 480)]  [int]$ServiceTimeoutMinutes = 60,
    [ValidateRange(5, 3600)] [int]$UpgradePollSeconds = 60,
    [ValidateRange(10, 1440)][int]$UpgradeTimeoutMinutes = 240,
    [string]$LogFolder = $(if ($env:ProgramData) { Join-Path $env:ProgramData 'VvfVCenterUpgrade' } else { Join-Path (Get-Location).Path 'vcenter-upgrade-logs' }),
    [switch]$StrictCertificates,
    [switch]$DryRun,
    [ValidateSet('Auto', 'PoshSSH', 'Plink')] [string]$SshClient = 'Auto',
    [string]$PlinkPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '3.0.1'

# ---------------------------------------------------------------------------- helpers --

# ---------------------------------------------------------------------- output, inputs --
# No front-end hooks and no prompts: progress goes to the host (and the transcript), and every
# input comes from a parameter, a SecretManagement secret or an environment variable. A run
# never waits for an answer -- a job runner that cannot give one would hang on it.

function Set-NodeStage {
    # Where one vCenter has got to (ShuttingDown, Snapshotted, Installing, Rebooting, Upgraded,
    # Failed, ...), kept on the node for the summary table at the end.
    param($Node, [string]$Stage, [string]$Detail = '', $Percent = $null)
    $Node.Board = [pscustomobject]@{ Stage = $Stage; Detail = $Detail; Percent = $Percent; Time = Get-Date }
}

function Write-Step { param([string]$Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Note { param([string]$Message) Write-Host "  $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Message) Write-Host "  WARNING: $Message" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Message) Write-Host "  ERROR: $Message" -ForegroundColor Red }
function Write-Good { param([string]$Message) Write-Host "  $Message" -ForegroundColor Green }

function Write-Phase {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor White
    Write-Host " $Title" -ForegroundColor White
    Write-Host ('=' * 78) -ForegroundColor White
}

function Get-Prop {
    # Safe, optional property read under StrictMode. REST replies omit fields freely and a
    # missing one must read as absent, not throw.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-PropPath {
    param($Object, [string]$Path, $Default = $null)
    $current = $Object
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }
        $current = Get-Prop $current $segment
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Get-MessageText {
    # A vAPI LocalizableMessage, a list of them, or a plain string -> one line of text.
    param($Message)
    if ($null -eq $Message) { return '' }
    if ($Message -is [string]) { return $Message }
    $parts = foreach ($m in @($Message)) {
        if ($m -is [string]) { $m; continue }
        $text = [string](Get-Prop $m 'default_message' '')
        if (-not $text) { $text = [string](Get-Prop $m 'id' '') }
        $text
    }
    return ((@($parts) | Where-Object { $_ }) -join ' ')
}

function Get-ShortName {
    param([string]$Name)
    if ($Name -match '^\d{1,3}(\.\d{1,3}){3}$') { return $Name }
    return ($Name -split '\.')[0]
}

function ConvertTo-ShellLiteral {
    # Single-quoted for bash, with embedded single quotes closed, escaped and reopened.
    param([string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Test-TypedConfirmation {
    param([string]$Typed, [string]$Expected)
    if ($null -eq $Typed) { return $false }
    return ([string]$Typed).Trim() -ieq $Expected
}

function ConvertTo-SecretSlug {
    # A credential name -> the part of its environment variable names: 'vvf-esxi-esx01.corp'
    # -> 'VVF_ESXI_ESX01_CORP' (RICHO_<slug>_USER / RICHO_<slug>_PASSWORD), the repo convention.
    param([string]$Name)
    return (($Name -replace '[^A-Za-z0-9]', '_').ToUpperInvariant())
}

function Get-CredentialNames {
    # The secret names to look for, most specific first: per host / per vCenter, then shared.
    param([ValidateSet('Esxi', 'VCenter', 'Sso')][string]$Kind, [string]$Target = '')
    $t = ([string]$Target).Trim().ToLowerInvariant()
    switch ($Kind) {
        'Esxi'    { return @($(if ($t) { "vvf-esxi-$t" }), 'vvf-esxi' | Where-Object { $_ }) }
        'VCenter' { return @($(if ($t) { "vvf-vcenter-$t" }), 'vvf-vcenter' | Where-Object { $_ }) }
        default   { return @('vvf-sso') }
    }
}

function Resolve-VvfCredential {
    # A credential without a prompt. For each name, most specific first: a SecretManagement
    # secret (when Get-Secret is available), then RICHO_<NAME>_USER / _PASSWORD. The parameter
    # value ($Given) is used after any per-target secret but before the shared one, so a
    # front end's credential field applies to every host that has no secret of its own.
    # Throws, naming every place it looked, when there is none. Returns Credential and Source.
    param([string[]]$Names, [System.Management.Automation.PSCredential]$Given, [string]$ParameterName,
          [scriptblock]$GetSecret = $null, [scriptblock]$GetEnv = { param($n) [Environment]::GetEnvironmentVariable($n) })
    if (-not $GetSecret -and (Get-Command -Name 'Get-Secret' -ErrorAction SilentlyContinue)) { $GetSecret = { param($n) Get-Secret -Name $n -ErrorAction SilentlyContinue } }
    $looked = [System.Collections.Generic.List[string]]::new()
    $names = @($Names)
    for ($i = 0; $i -lt $names.Count; $i++) {
        $name = $names[$i]
        # The parameter outranks only the shared (last) name; a per-target secret outranks it.
        if ($Given -and $i -eq $names.Count - 1) { return [pscustomobject]@{ Credential = $Given; Source = "-$ParameterName" } }
        if ($GetSecret) {
            $s = $null
            try { $s = & $GetSecret $name } catch { }
            if ($s -is [System.Management.Automation.PSCredential]) { return [pscustomobject]@{ Credential = $s; Source = "secret '$name'" } }
            $looked.Add("secret '$name'")
        }
        $slug = ConvertTo-SecretSlug $name
        $u = & $GetEnv "RICHO_${slug}_USER"
        $p = & $GetEnv "RICHO_${slug}_PASSWORD"
        if ($u -and $p) {
            return [pscustomobject]@{ Credential = [System.Management.Automation.PSCredential]::new($u, (ConvertTo-SecureString $p -AsPlainText -Force)); Source = "RICHO_${slug}_USER/_PASSWORD" }
        }
        $looked.Add("RICHO_${slug}_USER/_PASSWORD")
    }
    throw "No credential given: pass -$ParameterName, or set one of: $($looked -join ', ')."
}

function Get-InstallerAnswer {
    # The answer to one installer question, without asking: -InstallerAnswers by data item, else
    # the installer's default. Returns Answer and Source; throws when there is neither.
    param([string]$DataItem, [string]$Text, $Default, [hashtable]$Answers = @{})
    if ($Answers -and $Answers.ContainsKey($DataItem)) { return [pscustomobject]@{ Answer = [string]$Answers[$DataItem]; Source = '-InstallerAnswers' } }
    if ($null -ne $Default -and [string]$Default -ne '') { return [pscustomobject]@{ Answer = [string]$Default; Source = 'the installer default' } }
    throw "the installer asks '$Text' (data item '$DataItem') and offers no default -- run again with -InstallerAnswers @{ '$DataItem' = '<answer>' }"
}

# ------------------------------------------------------------------------- stopping --
# A stop is asked for with a file named STOP in -LogFolder, and acted on only at the safe
# points (Assert-NotStopped): never in the middle of a group shutdown, snapshot and power-on,
# or of an install and its reboot.

function Test-StopRequested {
    # Whether a stop has been asked for: 'file' or ''.
    param([string]$StopFile)
    if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { return 'file' }
    return ''
}

function Assert-NotStopped {
    # At a safe point: stops the run here when a stop has been asked for.
    param([string]$Where)
    $how = Test-StopRequested (Get-Variable -Name StopFile -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if (-not $how) { return }
    if ($how -eq 'file') { try { Remove-Item -LiteralPath $script:StopFile -Force -ErrorAction Stop } catch { } }
    # Its own error id: a real timeout can surface as an OperationCanceledException too, and must
    # never be mistaken for a stop the operator asked for.
    $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new("Stopped by the operator $Where$(if ($how -eq 'file') { ' (STOP file)' })."), 'VvfStopRequested', 'OperationStopped', $null)
    throw $e
}

function Format-Elapsed {
    param([TimeSpan]$Span)
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
}

function Wait-Pause {
    param([int]$Seconds, [string]$Reason)
    if ($Seconds -le 0) { return }
    Write-Note ("Pausing {0}s -- {1}" -f $Seconds, $Reason)
    Start-Sleep -Seconds $Seconds
}

# ------------------------------------------------------------------------- findings --

$script:Findings = [System.Collections.Generic.List[object]]::new()

function New-Finding {
    param([string]$Phase, [string]$Node, [ValidateSet('Error', 'Warning', 'Info')][string]$Severity, [string]$Check, [string]$Detail)
    return [pscustomobject]@{ Phase = $Phase; Node = $Node; Severity = $Severity; Check = $Check; Detail = $Detail }
}

function Add-Finding {
    param([string]$Phase, [string]$Node, [string]$Severity, [string]$Check, [string]$Detail)
    $f = New-Finding -Phase $Phase -Node $Node -Severity $Severity -Check $Check -Detail $Detail
    $script:Findings.Add($f)
    return $f
}

function Write-Findings {
    param($Findings, [string]$Title)
    $list = @($Findings)
    $errors = @($list | Where-Object { $_.Severity -eq 'Error' }).Count
    $warns  = @($list | Where-Object { $_.Severity -eq 'Warning' }).Count
    Write-Host ''
    Write-Host "  $Title -- $errors error(s), $warns warning(s)" -ForegroundColor $(if ($errors) { 'Red' } elseif ($warns) { 'Yellow' } else { 'Green' })
    foreach ($f in $list) {
        $line = '    [{0,-7}] {1,-28} {2}  ({3})' -f $f.Severity, $f.Check, $f.Detail, $f.Node
        switch ($f.Severity) {
            'Error'   { Write-Host $line -ForegroundColor Red }
            'Warning' { Write-Host $line -ForegroundColor Yellow }
            default   { Write-Host $line -ForegroundColor DarkGray }
        }
    }
}

function Get-FindingKey {
    # What makes two findings "the same problem" across phases: node, check and detail.
    param($Finding)
    return ('{0}|{1}|{2}' -f ([string]$Finding.Node).ToLowerInvariant(), $Finding.Check, $Finding.Detail)
}

function Compare-Findings {
    # Post-upgrade findings (Error/Warning) that were not there before the upgrade.
    param($Before, $After)
    $seen = @{}
    foreach ($f in @($Before)) { $seen[(Get-FindingKey $f)] = $true }
    return @(@($After) | Where-Object { $_.Severity -ne 'Info' -and -not $seen.ContainsKey((Get-FindingKey $_)) })
}

# ------------------------------------------------------------------ output parsers --
# Pure functions over command output: no calls to the hosts or appliances.

function ConvertFrom-ServiceStatusOutput {
    # The output of Get-ServiceStatusCommand: a service-control --status --all section
    # (headers "Running:", "Stopped:", "StartPending:" ... each followed by a line of
    # names) and a vmon section: "##SVC <name>", then that service's vmon-cli --status
    # lines. Fields are matched by exact name at the start of a line --
    # "CurrentRunStateDuration(ms):" follows "RunState:" and must not be taken for it.
    param([string[]]$Lines)
    $control = @{}
    $vmon = [System.Collections.Generic.List[object]]::new()
    $section = ''
    $state = ''
    $cur = $null
    foreach ($raw in @($Lines)) {
        $line = ([string]$raw).TrimEnd()
        if ($line -eq '##SC')   { $section = 'sc'; $state = ''; continue }
        if ($line -eq '##VMON') { $section = 'vmon'; continue }
        if ($section -eq 'sc') {
            if ($line -match '^\s*([A-Za-z]+):\s*(.*)$' -and $Matches[1] -match '^(Running|Stopped|StartPending|StopPending|Starting|Stopping)$') {
                $state = $Matches[1]
                $rest = $Matches[2]
                foreach ($n in ($rest -split '\s+' | Where-Object { $_ })) { $control[$n] = $state }
                continue
            }
            if ($state -and $line.Trim()) {
                foreach ($n in ($line.Trim() -split '\s+' | Where-Object { $_ })) { $control[$n] = $state }
            }
            continue
        }
        if ($section -eq 'vmon') {
            if ($line -match '^##SVC\s+(\S+)') {
                $cur = [pscustomobject]@{ Name = $Matches[1]; StartType = ''; RunState = ''; Health = '' }
                $vmon.Add($cur)
                continue
            }
            if ($null -eq $cur) { continue }
            if ($line -match '^\s*Starttype:\s*(\S+)')   { $cur.StartType = $Matches[1].ToUpperInvariant(); continue }
            if ($line -match '^\s*RunState:\s*(\S+)')    { $cur.RunState = $Matches[1].ToUpperInvariant(); continue }
            if ($line -match '^\s*HealthState:\s*(\S+)') { $cur.Health = $Matches[1].ToUpperInvariant(); continue }
        }
    }
    return [pscustomobject]@{ Control = $control; Vmon = $vmon.ToArray() }
}

# Services outside vmon that vCenter cannot work without. vmon does not report on these,
# so service-control is the only source for them.
$script:RequiredNonVmonServices = @('vmware-vmon', 'lwsmd', 'vmafdd', 'vmdird')

function Get-ServiceReadiness {
    # Ready = nothing starting or stopping, every vmon service set to start automatically
    # is STARTED, and the core non-vmon services are running. Unhealthy services do not
    # hold the gate (they are reported as findings) -- started is the test.
    param($Status)
    $control = Get-Prop $Status 'Control' @{}
    $vmon = @(Get-Prop $Status 'Vmon' @())
    $reasons = [System.Collections.Generic.List[string]]::new()

    $pending = @($control.Keys | Where-Object { $control[$_] -match 'Pending|Starting|Stopping' } | Sort-Object)
    $auto = @($vmon | Where-Object { $_.StartType -eq 'AUTOMATIC' })
    $notStarted = @($auto | Where-Object { $_.RunState -ne 'STARTED' } | ForEach-Object { $_.Name } | Sort-Object)
    $unhealthy = @($vmon | Where-Object { $_.RunState -eq 'STARTED' -and $_.Health -match '^(UNHEALTHY|DEGRADED)$' } | ForEach-Object { "$($_.Name) ($($_.Health))" } | Sort-Object)
    $coreDown = @($script:RequiredNonVmonServices | Where-Object { $control.ContainsKey($_) -and $control[$_] -ne 'Running' } | Sort-Object)
    $stoppedManual = @($vmon | Where-Object { $_.StartType -ne 'AUTOMATIC' -and $_.RunState -ne 'STARTED' } | ForEach-Object { $_.Name } | Sort-Object)

    if ($vmon.Count -eq 0) { $reasons.Add('vmon is not answering yet') }
    if ($control.Count -eq 0) { $reasons.Add('service-control is not answering yet') }
    if ($pending.Count) { $reasons.Add("starting/stopping: $($pending -join ', ')") }
    if ($notStarted.Count) { $reasons.Add("automatic services not started: $($notStarted -join ', ')") }
    if ($coreDown.Count) { $reasons.Add("core services not running: $($coreDown -join ', ')") }

    return [pscustomobject]@{
        Ready         = ($reasons.Count -eq 0)
        AutoTotal     = $auto.Count
        AutoStarted   = $auto.Count - $notStarted.Count
        NotStarted    = $notStarted
        Pending       = $pending
        CoreDown      = $coreDown
        Unhealthy     = $unhealthy
        StoppedManual = $stoppedManual
        Reasons       = $reasons.ToArray()
    }
}

function ConvertFrom-DfOutput {
    # df -P output -> mount, use%. The header line and anything unparseable are skipped.
    param([string[]]$Lines)
    $rows = foreach ($line in @($Lines)) {
        if ($line -match '^\S+\s+\d+\s+\d+\s+\d+\s+(\d+)%\s+(\S+)\s*$') {
            [pscustomobject]@{ Mount = $Matches[2]; UsePercent = [int]$Matches[1] }
        }
    }
    return @($rows)
}

function Get-DiskFindings {
    # A partition at $ErrorAt% or more is an error, at $WarnAt% a warning. Those in $WarnOnly are
    # only ever a warning: /storage/archive holds vPostgres' archived logs, which it manages
    # itself, and the patch does not use it.
    param($Rows, [string]$Phase, [string]$Node, [int]$WarnAt = 85, [int]$ErrorAt = 95, [string[]]$WarnOnly = @('/storage/archive'))
    $out = foreach ($r in @($Rows)) {
        if ($WarnOnly -contains $r.Mount -and $r.UsePercent -ge $WarnAt) { New-Finding $Phase $Node 'Warning' 'Disk space' "$($r.Mount) is $($r.UsePercent)% used (the database archive partition -- a warning only: vPostgres manages it and the patch does not use it)" }
        elseif ($r.UsePercent -ge $ErrorAt) { New-Finding $Phase $Node 'Error'   'Disk space' "$($r.Mount) is $($r.UsePercent)% used" }
        elseif ($r.UsePercent -ge $WarnAt) { New-Finding $Phase $Node 'Warning' 'Disk space' "$($r.Mount) is $($r.UsePercent)% used" }
    }
    return @($out)
}

function ConvertFrom-ChageOutput {
    # chage -l root -> the "Password expires" value: 'never', a [datetime], or $null.
    param([string[]]$Lines)
    foreach ($line in @($Lines)) {
        if ($line -match '^\s*Password expires\s*:\s*(.+?)\s*$') {
            $v = $Matches[1]
            if ($v -match '^never$') { return 'never' }
            $d = [datetime]::MinValue
            $formats = [string[]]@('MMM dd, yyyy', 'MMM d, yyyy', 'yyyy-MM-dd')
            if ([datetime]::TryParseExact($v, $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
            return $null
        }
    }
    return $null
}

function Get-ExpiryFinding {
    # One finding for a password or certificate expiry date, or none when it is far off.
    param($Expires, [datetime]$Now, [string]$Phase, [string]$Node, [string]$Check, [int]$WarnDays, [int]$ErrorDays = 0)
    if ($null -eq $Expires -or $Expires -is [string]) { return $null }
    $days = [math]::Floor(([datetime]$Expires - $Now).TotalDays)
    $when = ([datetime]$Expires).ToString('yyyy-MM-dd')
    if ($days -lt 0)          { return (New-Finding $Phase $Node 'Error' $Check "expired on $when") }
    if ($days -le $ErrorDays) { return (New-Finding $Phase $Node 'Error' $Check "expires on $when ($days day(s))") }
    if ($days -le $WarnDays)  { return (New-Finding $Phase $Node 'Warning' $Check "expires on $when ($days day(s))") }
    return $null
}

function ConvertFrom-OpenSslEndDate {
    # "notAfter=Jan  1 00:00:00 2027 GMT" -> [datetime] (UTC), or $null.
    param([string[]]$Lines)
    foreach ($line in @($Lines)) {
        if ($line -match 'notAfter=\s*(\w{3})\s+(\d{1,2})\s+(\d{2}:\d{2}:\d{2})\s+(\d{4})') {
            $text = '{0} {1} {2} {3}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4]
            $d = [datetime]::MinValue
            if ([datetime]::TryParseExact($text, 'MMM d HH:mm:ss yyyy', [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$d)) { return $d }
        }
    }
    return $null
}

function ConvertFrom-VmdirServerList {
    # vdcrepadmin -f showservers -> the vCenter (domain controller) names in the SSO domain.
    param([string[]]$Lines)
    $names = foreach ($line in @($Lines)) {
        if ($line -match '(?i)cn=([^,]+),cn=Servers') { $Matches[1].Trim().ToLowerInvariant() }
    }
    return @($names | Where-Object { $_ } | Select-Object -Unique)
}

function ConvertFrom-PartnerStatus {
    # vdcrepadmin -f showpartnerstatus -> one row per replication partner.
    param([string[]]$Lines)
    $rows = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($raw in @($Lines)) {
        $line = ([string]$raw).Trim()
        if ($line -match '^Partner:\s*(\S+)') {
            $cur = [pscustomobject]@{ Partner = ($Matches[1] -replace '^ldaps?://', '' -replace ':\d+$', '').ToLowerInvariant(); HostAvailable = $null; StatusAvailable = $null; ChangesBehind = $null }
            $rows.Add($cur)
            continue
        }
        if ($null -eq $cur) { continue }
        if ($line -match '^Host available:\s*(\w+)')   { $cur.HostAvailable = ($Matches[1] -ieq 'Yes'); continue }
        if ($line -match '^Status available:\s*(\w+)') { $cur.StatusAvailable = ($Matches[1] -ieq 'Yes'); continue }
        if ($line -match '^Partner is\s+(\d+)\s+changes?\s+behind') { $cur.ChangesBehind = [int]$Matches[1]; continue }
    }
    return $rows.ToArray()
}

function Get-ReplicationFindings {
    # Findings for one node's partner status. ChangesBehind > 0 is a warning -- replication
    # is asynchronous and a small lag right after a change is normal; the caller re-reads
    # before reporting it.
    param($Rows, [string]$Phase, [string]$Node)
    $out = [System.Collections.Generic.List[object]]::new()
    if (@($Rows).Count -eq 0) {
        $out.Add((New-Finding $Phase $Node 'Error' 'ELM replication' 'no replication partners reported'))
        return $out.ToArray()
    }
    foreach ($r in @($Rows)) {
        if ($r.HostAvailable -ne $true)       { $out.Add((New-Finding $Phase $Node 'Error' 'ELM replication' "partner $($r.Partner) host not available")); continue }
        if ($r.StatusAvailable -ne $true)     { $out.Add((New-Finding $Phase $Node 'Error' 'ELM replication' "partner $($r.Partner) status not available")); continue }
        if ($null -eq $r.ChangesBehind)       { $out.Add((New-Finding $Phase $Node 'Warning' 'ELM replication' "partner $($r.Partner) did not report how far behind it is")); continue }
        if ($r.ChangesBehind -gt 0)           { $out.Add((New-Finding $Phase $Node 'Warning' 'ELM replication' "partner $($r.Partner) is $($r.ChangesBehind) change(s) behind")) }
        else                                  { $out.Add((New-Finding $Phase $Node 'Info' 'ELM replication' "partner $($r.Partner) in sync")) }
    }
    return $out.ToArray()
}

function Get-HealthFinding {
    # One appliance health indicator (green / yellow / orange / red / gray) -> a finding.
    param([string]$Indicator, [string]$Value, [string]$Phase, [string]$Node)
    switch -Regex ($Value) {
        '^red$'           { return (New-Finding $Phase $Node 'Error'   'Appliance health' "$Indicator is red") }
        '^(orange|yellow)$' { return (New-Finding $Phase $Node 'Warning' 'Appliance health' "$Indicator is $Value") }
        '^green$'         { return $null }
        default           { return (New-Finding $Phase $Node 'Info'    'Appliance health' "$Indicator is $(if ($Value) { $Value } else { 'unknown' })") }
    }
}

function Get-NotificationFindings {
    # A vAPI Notifications structure ({errors, warnings, info}) -> findings.
    param($Notifications, [string]$Phase, [string]$Node, [string]$Check)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($pair in @(@('errors', 'Error'), @('warnings', 'Warning'), @('info', 'Info'))) {
        foreach ($n in @(Get-Prop $Notifications $pair[0] @())) {
            $text = Get-MessageText (Get-Prop $n 'message')
            $fix = Get-MessageText (Get-Prop $n 'resolution')
            if ($fix) { $text = "$text -- $fix" }
            if (-not $text) { $text = [string](Get-Prop $n 'id' 'unspecified') }
            $out.Add((New-Finding $Phase $Node $pair[1] $Check $text))
        }
    }
    return $out.ToArray()
}

function Select-PendingUpdate {
    # The newest update offered by the ISO, or $null.
    param($Pending)
    $list = @($Pending | Where-Object { $_ -and (Get-Prop $_ 'version') })
    if ($list.Count -eq 0) { return $null }
    return ($list | Sort-Object { ConvertTo-VersionKey (Get-Prop $_ 'version') } -Descending | Select-Object -First 1)
}

function ConvertTo-VersionKey {
    # "8.0.3.00500" -> [version] for comparison; non-numeric parts fall back to 0.
    param([string]$Version)
    $parts = @(([string]$Version -split '[^\d]+' | Where-Object { $_ -ne '' }) | Select-Object -First 4 | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 2) { $parts += 0 }
    return [version]($parts -join '.')
}

function Get-UpdateTaskSummary {
    # GET /appliance/update -> state, percent, message, task status and error text.
    param($Info)
    $task = Get-Prop $Info 'task'
    $completed = [double](Get-PropPath $task 'progress.completed' 0)
    $total = [double](Get-PropPath $task 'progress.total' 0)
    $percent = $null
    if ($total -gt 0) { $percent = [int][math]::Floor(100 * $completed / $total) }
    $err = Get-Prop $task 'error'
    $errText = ''
    if ($err) {
        $errText = Get-MessageText (Get-Prop $err 'messages')
        if (-not $errText) { $errText = Get-MessageText $err }
    }
    return [pscustomobject]@{
        State      = [string](Get-Prop $Info 'state' '')
        Version    = [string](Get-Prop $Info 'version' '')
        Percent    = $percent
        Message    = Get-MessageText (Get-PropPath $task 'progress.message')
        TaskStatus = [string](Get-Prop $task 'status' '')
        Error      = $errText
    }
}

function Get-UpgradeVerdict {
    # Decides, from one poll, whether the upgrade is still running, succeeded or failed.
    #   $Summary      Get-UpdateTaskSummary of the poll
    #   $Current      the appliance version now (may be empty if the call failed)
    #   $Target       the version being installed
    #   $SeenActivity true once a STAGE/INSTALL state or a RUNNING task has been seen
    param($Summary, [string]$Current, [string]$Target, [bool]$SeenActivity)
    if ($Summary.State -eq 'INSTALL_FAILED') { return 'Failed' }
    if ($Summary.TaskStatus -eq 'FAILED')    { return 'Failed' }
    if ($Summary.State -eq 'ROLLBACK_IN_PROGRESS') { return 'RollingBack' }
    if ($Summary.State -match 'IN_PROGRESS$') { return 'Running' }
    if ($Current -and $Target -and $Current -eq $Target) { return 'Succeeded' }
    # No version read (the API is restarting as the install ends): ask again, do not conclude.
    if (-not $Current) { return 'Waiting' }
    if ($SeenActivity -and $Summary.State -match '^(UP_TO_DATE|UPDATES_PENDING)$' -and $Summary.TaskStatus -ne 'RUNNING') { return 'EndedWrongVersion' }
    return 'Waiting'
}

function Test-RebootObserved {
    # The appliance has booted since a moment $SecondsSinceMark ago when its uptime is
    # shorter than that (with a margin for clock and polling slack).
    param([double]$UptimeSeconds, [double]$SecondsSinceMark, [double]$MarginSeconds = 30)
    return ($UptimeSeconds -ge 0 -and ($UptimeSeconds + $MarginSeconds) -lt $SecondsSinceMark)
}

function Test-TransientApiError {
    # True when an appliance API failure means "busy, ask again": no HTTP answer at all (a
    # refused, reset or cut-off connection, a timeout) or a 5xx from the API gateway while the
    # services behind it restart. False for a real answer refusing the call (4xx) or rejected
    # credentials -- those do not get better by waiting.
    param([string]$Message)
    if ($Message -match 'status code does not indicate success: (\d{3})') { return ([int]$Matches[1] -ge 500) }
    if ($Message -match 'refused the root credentials') { return $false }
    return $true
}

function Get-RebootWatchVerdict {
    # One poll of a vCenter after a reboot request. Returns Rebooted (it has booted since the
    # request), NotActedOn (it answered with its old uptime for $QuietPolls polls in a row --
    # the request was never acted on), or Watching. $State carries the count between polls;
    # an outage (no answer) resets it, since a vCenter going down is what a reboot looks like.
    param($State, $UptimeSeconds, [double]$SecondsSinceRequest, [int]$QuietPolls)
    if ($null -eq $UptimeSeconds) { $State.Quiet = 0; $State.SawOutage = $true; return 'Watching' }
    if (Test-RebootObserved ([double]$UptimeSeconds) $SecondsSinceRequest 0) { return 'Rebooted' }
    $State.Quiet++
    if ($State.Quiet -ge $QuietPolls) { return 'NotActedOn' }
    return 'Watching'
}

function Get-MarkedOutput {
    # Shell-stream output between "VVFB_<id>" and "VVFE_<id>_<rc>" markers. The command
    # line itself is echoed with the marker split by quotes, so only the real output
    # matches.
    param([string]$Text, [string]$Id)
    $esc = [string][char]27
    $clean = ($Text -replace ($esc + '\[[0-9;?]*[A-Za-z]'), '') -replace "`r", ''
    $begin = [regex]::Match($clean, "(?m)^VVFB_$Id\s*$")
    $end = [regex]::Match($clean, "(?m)^VVFE_$($Id)_(\d+)\s*$")
    if (-not $begin.Success -or -not $end.Success -or $end.Index -lt $begin.Index) { return $null }
    $body = $clean.Substring($begin.Index + $begin.Length, $end.Index - ($begin.Index + $begin.Length))
    $lines = @($body -split "`n" | ForEach-Object { $_.TrimEnd() })
    while ($lines.Count -and $lines[0] -eq '') { $lines = @($lines | Select-Object -Skip 1) }
    while ($lines.Count -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    return [pscustomobject]@{ Output = [string[]]$lines; ExitStatus = [int]$end.Groups[1].Value }
}

function Get-IsoNameFinding {
    # The full installer ISO (VMware-VCSA-all-...) is for the external installer; a patch
    # mounted to the appliance is VMware-vCenter-Server-Appliance-...-patch-FP.iso.
    param([string]$IsoPath, [string]$Phase, [string]$Node)
    $leaf = ($IsoPath -split '[/\\\]]')[-1].Trim()
    if ($leaf -match '(?i)VCSA-all') {
        return (New-Finding $Phase $Node 'Error' 'Upgrade ISO' "$leaf is the full installer ISO; mount the appliance patch ISO (VMware-vCenter-Server-Appliance-*-patch-FP.iso)")
    }
    if ($leaf -notmatch '(?i)patch') {
        return (New-Finding $Phase $Node 'Warning' 'Upgrade ISO' "$leaf does not look like a vCenter patch ISO")
    }
    return $null
}

function ConvertFrom-VCenterCsv {
    # The vCenter list: one row per vCenter, in upgrade order, with the ESXi host its VM runs on
    # and, optionally, the VM's inventory name. Lines starting with # are comments. Throws, naming
    # the row, on anything a run could not act on.
    param([string[]]$Lines)
    $body = @($Lines | Where-Object { $_ -and $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
    if ($body.Count -lt 2) { throw 'the CSV has no rows -- expected a header line (VCenter,EsxiHost[,VmName]) and one row per vCenter' }
    $raw = @($body | ConvertFrom-Csv)
    $cols = @($raw[0].PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($c in @('VCenter', 'EsxiHost')) { if ($cols -notcontains $c) { throw "the CSV has no '$c' column (columns found: $($cols -join ', ')) -- expected VCenter,EsxiHost[,VmName]" } }
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $n = 1
    foreach ($r in $raw) {
        $n++
        $vc = ([string]$r.VCenter).Trim().ToLowerInvariant()
        $h = ([string]$r.EsxiHost).Trim()
        $vmName = $(if ($cols -contains 'VmName') { ([string]$r.VmName).Trim() } else { '' })
        if (-not $vc) { throw "CSV line ${n}: VCenter is empty" }
        if (-not $h) { throw "CSV line ${n}: EsxiHost is empty for $vc" }
        if ($seen.ContainsKey($vc)) { throw "CSV line ${n}: $vc is listed twice" }
        $seen[$vc] = $true
        $rows.Add([pscustomobject]@{ VCenter = $vc; EsxiHost = $h; VmName = $vmName })
    }
    return $rows.ToArray()
}

function Compare-VCenterSets {
    # The CSV against the SSO domain's own list of vCenters (vdcrepadmin showservers). Names
    # match on the FQDN, or on the short name when one side has no domain part.
    param([string[]]$Csv, [string[]]$Domain)
    $same = { param($a, $b) ($a -ieq $b) -or ((Get-ShortName $a) -ieq (Get-ShortName $b) -and (($a -notmatch '\.') -or ($b -notmatch '\.'))) }
    $missing = @($Domain | Where-Object { $d = $_; -not @($Csv | Where-Object { & $same $_ $d }).Count })
    $extra = @($Csv | Where-Object { $c = $_; -not @($Domain | Where-Object { & $same $c $_ }).Count })
    return [pscustomobject]@{ MissingFromCsv = $missing; NotInDomain = $extra }
}

function ConvertFrom-DatastorePath {
    # "[SoftwareRepo] ISO/VMware-...-patch-FP.iso" -> datastore, path inside it, file name.
    param([string]$Path)
    $p = ([string]$Path).Trim().Trim('"').Trim("'")
    if ($p -notmatch '^\[(?<ds>[^\]]+)\]\s*(?<rel>.+)$') { throw "'$Path' is not a datastore path -- expected [DatastoreName] folder/file.iso" }
    $ds = $Matches['ds'].Trim()
    $rel = $Matches['rel'].Trim().TrimStart('/') -replace '\\', '/'
    if ($rel -notmatch '(?i)\.iso$') { throw "'$Path' does not name an .iso file" }
    return [pscustomobject]@{ Datastore = $ds; Path = $rel; Leaf = ($rel -split '/')[-1]; Full = "[$ds] $rel" }
}

function Get-GuestUnmountCommand {
    # Inside the appliance: unmount anything mounted from the CD-ROM, then eject each CD-ROM
    # device -- the guest keeps the drive door locked even with nothing mounted, and ejecting
    # from inside unlocks it, so the host-side disconnect does not stop on "the guest has locked
    # the CD-ROM door". What cannot be unmounted is reported with the processes holding it, and
    # nothing is ejected then.
    return @'
busy=0; for m in $(awk '$1 ~ /^\/dev\/(sr[0-9]+|cdrom)$/ {print $2}' /proc/mounts); do if umount "$m" 2>/dev/null; then echo "UNMOUNTED|$m"; else busy=1; echo "BUSY|$m"; (fuser -vm "$m" 2>&1 || lsof "$m" 2>&1) | sed 's/^/USER|/' | head -n 20; fi; done; if [ "$busy" = 0 ]; then for d in /dev/sr[0-9]*; do [ -b "$d" ] || continue; if eject "$d" >/dev/null 2>&1; then echo "EJECTED|$d"; else echo "NOEJECT|$d"; fi; done; fi; echo 'END|'
'@.Trim()
}

function ConvertFrom-GuestUnmountOutput {
    # The output of Get-GuestUnmountCommand -> what was unmounted, and what is still in use by whom.
    param([string[]]$Lines)
    $unmounted = [System.Collections.Generic.List[string]]::new()
    $ejected = [System.Collections.Generic.List[string]]::new()
    $notEjected = [System.Collections.Generic.List[string]]::new()
    $busy = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    $ended = $false
    foreach ($line in @($Lines)) {
        $l = ([string]$line).TrimEnd()
        if ($l -match '^UNMOUNTED\|(.+)$') { $unmounted.Add($Matches[1]); $cur = $null; continue }
        if ($l -match '^BUSY\|(.+)$') { $cur = [pscustomobject]@{ Mount = $Matches[1]; Users = [System.Collections.Generic.List[string]]::new() }; $busy.Add($cur); continue }
        if ($l -match '^USER\|(.*)$') { if ($cur -and $Matches[1].Trim()) { $cur.Users.Add($Matches[1].Trim()) }; continue }
        if ($l -match '^EJECTED\|(.+)$') { $ejected.Add($Matches[1]); $cur = $null; continue }
        if ($l -match '^NOEJECT\|(.+)$') { $notEjected.Add($Matches[1]); $cur = $null; continue }
        if ($l -match '^END\|') { $ended = $true }
    }
    return [pscustomobject]@{ Unmounted = $unmounted.ToArray(); Ejected = $ejected.ToArray(); NotEjected = $notEjected.ToArray(); Busy = $busy.ToArray(); Complete = $ended }
}

function ConvertTo-DryRunRecordJson {
    # What a passing dry run leaves behind: when, for which CSV (by its SHA-256, so an edited CSV
    # does not count) and which ISO, by which version of this script. A front end uses it to
    # hold back a real run until a matching dry run has passed recently.
    param([string]$CsvSha256, [string]$IsoPath, [string[]]$VCenters, [datetime]$Time, [string]$ScriptVersion)
    return ([ordered]@{
        Script = 'Invoke-VvfVCenterUpgrade'; Record = 'DryRunPassed'; ScriptVersion = $ScriptVersion
        Time = $Time.ToUniversalTime().ToString('o'); CsvSha256 = $CsvSha256.ToUpperInvariant(); IsoPath = $IsoPath; VCenters = @($VCenters)
    } | ConvertTo-Json -Depth 4)
}

function Test-DryRunRecord {
    # Whether a dry-run record covers a real run of this CSV and ISO now: same CSV contents,
    # same ISO, not older than $MaxAgeHours, and not from the future. Returns Valid and, when
    # not, the reason in words.
    param([string]$Json, [string]$CsvSha256, [string]$IsoPath, [datetime]$Now, [double]$MaxAgeHours = 24)
    $no = { param($why) [pscustomobject]@{ Valid = $false; Reason = $why; Time = $null } }
    if ([string]::IsNullOrWhiteSpace($Json)) { return (& $no 'no dry run has passed for this CSV yet') }
    try { $r = $Json | ConvertFrom-Json } catch { return (& $no 'the dry-run record cannot be read') }
    if ((Get-Prop $r 'Script') -ne 'Invoke-VvfVCenterUpgrade' -or (Get-Prop $r 'Record') -ne 'DryRunPassed') { return (& $no 'the dry-run record is not one this script wrote') }
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse([string](Get-Prop $r 'Time' ''), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { return (& $no 'the dry-run record has no readable time') }
    if (([string](Get-Prop $r 'CsvSha256' '')) -ne $CsvSha256.ToUpperInvariant()) { return (& $no 'the CSV has changed since the last passing dry run') }
    if (([string](Get-Prop $r 'IsoPath' '')).Trim() -ine $IsoPath.Trim()) { return (& $no "the last passing dry run was for another ISO ($(Get-Prop $r 'IsoPath' ''))") }
    $age = ($Now.ToUniversalTime() - $t.ToUniversalTime()).TotalHours
    if ($age -lt -0.1) { return (& $no 'the dry-run record is dated in the future') }
    if ($age -gt $MaxAgeHours) { return (& $no ("the last passing dry run is {0:N0} hours old (the limit is {1})" -f $age, $MaxAgeHours)) }
    return [pscustomobject]@{ Valid = $true; Reason = ''; Time = $t }
}

# --------------------------------------------------------------- command builders --

function Get-ServiceStatusCommand {
    # service-control and one vmon-cli read per service, all run alongside each other into a
    # temporary folder, then printed in a fixed layout for ConvertFrom-ServiceStatusOutput. One
    # after another they took minutes on a busy appliance. In a subshell, so an interactive
    # shell prints no job notices into the output. Without a temporary folder, or with
    # -Sequential, the same layout is printed one service after another.
    param([switch]$Sequential)
    $oneByOne = @'
echo '##SC'; service-control --status --all 2>&1; echo '##VMON'; for s in $(vmon-cli --list 2>/dev/null); do echo "##SVC $s"; vmon-cli --status "$s" 2>/dev/null; done
'@.Trim()
    if ($Sequential) { return $oneByOne }
    return (@'
( d=$(mktemp -d /tmp/vvfsvc.XXXXXX 2>/dev/null) || d=''; if [ -n "$d" ] && [ -d "$d" ]; then service-control --status --all >"$d/sc" 2>&1 & for s in $(vmon-cli --list 2>/dev/null); do vmon-cli --status "$s" >"$d/svc.$s" 2>/dev/null & done; wait; echo '##SC'; cat "$d/sc"; echo '##VMON'; for f in "$d"/svc.*; do [ -e "$f" ] || continue; echo "##SVC ${f##*/svc.}"; cat "$f"; done; rm -rf "$d"; else ONEBYONE; fi )
'@.Trim() -replace 'ONEBYONE', $oneByOne)
}

function Get-VdcrepadminCommand {
    param([string]$Operation, [System.Management.Automation.PSCredential]$Sso)
    $user = ($Sso.UserName -split '@')[0]
    if ($user -match '\\') { $user = ($user -split '\\')[-1] }
    $pw = $Sso.GetNetworkCredential().Password
    return ('/usr/lib/vmware-vmdir/bin/vdcrepadmin -f {0} -h localhost -u {1} -w {2} 2>&1' -f $Operation, (ConvertTo-ShellLiteral $user), (ConvertTo-ShellLiteral $pw))
}

$script:UpgradeLogCommand = @'
for f in /var/log/vmware/applmgmt/software-packages.log /var/log/vmware/applmgmt/PatchRunner.log /var/log/vmware/applmgmt/update_microservice.log; do if [ -f "$f" ]; then echo "== $f"; grep -iE 'error|fail|exception' "$f" | tail -n 30; fi; done
'@.Trim()

# ===================================================================== appliance API ==
# A node is one vCenter appliance: its name, root credential, API session and SSH session.

function New-Node {
    param([string]$Name, [System.Management.Automation.PSCredential]$Credential, [System.Management.Automation.PSCredential]$SsoCredential)
    return [pscustomobject]@{
        Name = $Name; Credential = $Credential; SsoCredential = $SsoCredential
        ApiBase = $null; Token = $null; ApiLabel = $null
        Vm = $null; Esxi = $null; EsxiHost = $null
        CurrentVersion = $null; FromVersion = $null; CurrentBuild = $null; TargetVersion = $null; IsoPath = $null; UserData = @{}
        Stage = 'Pending'; InstallMark = $null; LastError = $null; PreFindings = @(); Attempts = 0; IsoPending = $false
        Ssh = $null; ShellMode = $null; Stream = $null; Seq = 0
        SshEnabledByScript = $false; SshOff = $false; SshWasOn = $null; SshFinal = ''
        LastReady = $null; HostKey = ''; StatusOneByOne = $false; Board = $null
    }
}

function Initialize-Tls {
    param([bool]$Strict)
    $script:RestExtra = @{}
    if ($Strict) { return }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $script:RestExtra = @{ SkipCertificateCheck = $true }; return }
    # Windows PowerShell 5.1: no -SkipCertificateCheck, so trust-all for this process only.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not ('VvfTrustAllPolicy' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net; using System.Security.Cryptography.X509Certificates;
public class VvfTrustAllPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object VvfTrustAllPolicy
}

function Invoke-Rest {
    param([string]$Method, [string]$Uri, [hashtable]$Headers, $Body, [int]$TimeoutSec = 60)
    $args2 = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = $TimeoutSec; ContentType = 'application/json'; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $args2['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    foreach ($k in $script:RestExtra.Keys) { $args2[$k] = $script:RestExtra[$k] }
    return Invoke-RestMethod @args2
}

function Get-HttpStatus {
    param($ErrorRecord)
    $resp = Get-Prop $ErrorRecord.Exception 'Response'
    if ($resp) { try { return [int]$resp.StatusCode } catch { return $null } }
    return $null
}

function Connect-NodeApi {
    # Tries, in order: root on 5480 (appliance management -- it stays up while the installer
    # stops the vCenter services), the SSO administrator on 443, root on 443. A login is
    # kept only if it is also authorized: on some builds root logs in to 443 and is then
    # refused (403, "Unable to authorize user") on every appliance call. So each login is
    # probed with a read of the SSH setting, which needs the appliance privileges, and a 403
    # moves on to the next. Other probe errors do not prove a login useless and are let by.
    param($Node)
    $tries = @(@{ Base = "https://$($Node.Name):5480/api"; Cred = $Node.Credential; Label = 'root on port 5480' })
    if ($Node.SsoCredential) { $tries += @{ Base = "https://$($Node.Name)/api"; Cred = $Node.SsoCredential; Label = "$($Node.SsoCredential.UserName) on port 443" } }
    $tries += @{ Base = "https://$($Node.Name)/api"; Cred = $Node.Credential; Label = 'root on port 443' }
    $notes = [System.Collections.Generic.List[string]]::new()
    $unauthorized = $null
    foreach ($t in $tries) {
        $pair = '{0}:{1}' -f $t.Cred.UserName, $t.Cred.GetNetworkCredential().Password
        $basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
        $token = $null
        try {
            $token = Invoke-Rest -Method Post -Uri "$($t.Base)/session" -Headers @{ Authorization = $basic } -Body $null -TimeoutSec 30
            if ($token -and -not ($token -is [string])) { $token = [string](Get-Prop $token 'value' $token) }
        } catch {
            if ((Get-HttpStatus $_) -eq 401 -and $t.Label -eq 'root on port 5480') { throw "The appliance at $($Node.Name) refused the root credentials (401)." }
            $notes.Add("$($t.Label): $($_.Exception.Message)")
            continue
        }
        if (-not $token) { $notes.Add("$($t.Label): no session token"); continue }
        try {
            $null = Invoke-Rest -Method Get -Uri "$($t.Base)/appliance/access/ssh" -Headers @{ 'vmware-api-session-id' = [string]$token } -Body $null -TimeoutSec 30
        } catch {
            if ((Get-HttpStatus $_) -eq 403) {
                $notes.Add("$($t.Label): logged in, but not authorized for the appliance calls (403)")
                if (-not $unauthorized) { $unauthorized = @{ Base = $t.Base; Token = [string]$token; Label = $t.Label } }
                continue
            }
        }
        $Node.ApiBase = $t.Base; $Node.Token = [string]$token; $Node.ApiLabel = $t.Label
        return
    }
    if ($unauthorized) {
        # Better than nothing: some reads may still work. The 403s will show up as findings.
        $Node.ApiBase = $unauthorized.Base; $Node.Token = $unauthorized.Token; $Node.ApiLabel = "$($unauthorized.Label) (NOT authorized for appliance calls)"
        return
    }
    $Node.Token = $null
    throw "Cannot open an API session on $($Node.Name): $($notes -join '; ')"
}

function Invoke-NodeApi {
    # One appliance API call; logs in when there is no session and once more on a 401.
    param($Node, [string]$Method, [string]$Path, $Body = $null, [int]$TimeoutSec = 60)
    if (-not $Node.Token) { Connect-NodeApi $Node }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            return Invoke-Rest -Method $Method -Uri ($Node.ApiBase + $Path) -Headers @{ 'vmware-api-session-id' = $Node.Token } -Body $Body -TimeoutSec $TimeoutSec
        } catch {
            if ($attempt -eq 1 -and (Get-HttpStatus $_) -eq 401) { Connect-NodeApi $Node; continue }
            $detail = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = " -- $($_.ErrorDetails.Message)" }
            throw "$Method $Path on $($Node.Name) failed: $($_.Exception.Message)$detail"
        }
    }
}

function Reset-NodeApi { param($Node) $Node.Token = $null; $Node.ApiBase = $null; $Node.ApiLabel = $null }

# ==================================================================== appliance SSH ==

# --------------------------------------------------------------- SSH through plink --
# Where Posh-SSH cannot be used, every appliance command runs through PuTTY's plink.exe instead:
# one plink process per command, the password in a -pwfile, the command over plink's input.

function ConvertFrom-PlinkVersion {
    # "plink: Release 0.83" -> 0.83, or $null.
    param([string]$Text)
    $m = [regex]::Match([string]$Text, '(?i)Release\s+(\d+)\.(\d+)')
    if ($m.Success) { return [version]"$($m.Groups[1].Value).$($m.Groups[2].Value)" }
    return $null
}

function Find-PlinkPath {
    # The plink.exe to use: the one given (or '' when it is not there), else the first candidate
    # that exists.
    param([string]$Given, [string[]]$Candidates)
    if ($Given) { return $(if (Test-Path -LiteralPath $Given -PathType Leaf) { (Resolve-Path -LiteralPath $Given).Path } else { '' }) }
    foreach ($c in @($Candidates)) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c } }
    return ''
}

function ConvertTo-ProcessArgument {
    # One argument quoted for a Windows command line (the rules plink's C runtime parses by).
    param([string]$Value)
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { $null = $sb.Append('\' * ($slashes * 2 + 1)).Append('"'); $slashes = 0; continue }
        $null = $sb.Append('\' * $slashes).Append($ch); $slashes = 0
    }
    $null = $sb.Append('\' * ($slashes * 2)).Append('"')
    return $sb.ToString()
}

function Get-PlinkArguments {
    # plink's command line: batch mode (never a prompt), no terminal, no agent, no anti-spoofing
    # pause; the password from a file; the command from a file (-m: an SSH exec request, run as
    # bash -c, the way Posh-SSH runs it -- not typed into a login shell); the host key pinned
    # when one was given. No password and no command on the command line itself.
    param([string]$HostName, [string]$User, [string]$PasswordFile, [string]$HostKey = '', [string]$CommandFile = '')
    $a = @('-ssh', '-batch', '-T', '-noagent', '-no-antispoof', '-l', $User, '-pwfile', $PasswordFile)
    if ($CommandFile) { $a += @('-m', $CommandFile) }
    if ($HostKey) { $a += @('-hostkey', $HostKey) }
    $a += $HostName
    return ((@($a) | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
}

function Get-PlinkHostKeyFingerprint {
    # The host key fingerprint plink prints for a server it has not seen: SHA256:..., or the
    # older MD5 aa:bb:... form; '' when there is none.
    param([string]$Text)
    $m = [regex]::Match([string]$Text, 'SHA256:[A-Za-z0-9+/=]+')
    if ($m.Success) { return $m.Value }
    $m = [regex]::Match([string]$Text, '(?i)\b[0-9a-f]{2}(?::[0-9a-f]{2}){15}\b')
    if ($m.Success) { return $m.Value }
    return ''
}

function Remove-PlinkNotices {
    # plink's own notices on its error output -- "Using username ...", the server's login banner
    # between its "Pre-authentication banner" and "End of banner" lines, "Access granted" -- are
    # not the command's errors.
    param([string]$Text)
    $keep = [System.Collections.Generic.List[string]]::new()
    $inBanner = $false
    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        if ($line -match '^\s*Pre-authentication banner message from server') { $inBanner = $true; continue }
        if ($inBanner) { if ($line -match '^\s*End of banner message from server') { $inBanner = $false }; continue }
        if ($line -match '^\s*(Using username "|Access granted|Keyboard-interactive authentication)') { continue }
        if ($line.Trim()) { $keep.Add($line) }
    }
    return ($keep -join "`n")
}

function Get-PlinkOutcome {
    # What a finished plink run means. Kind: Done (Output, ExitStatus), HostKeyUnknown
    # (Fingerprint), HostKeyChanged, or Failed (Message).
    param([string]$StdOut, [string]$StdErr, [int]$ExitCode)
    $err = [string]$StdErr
    if ($err -match '(?i)POTENTIAL SECURITY BREACH|does not match the one PuTTY has cached|host key does not match') {
        return [pscustomobject]@{ Kind = 'HostKeyChanged'; Message = 'its SSH host key is not the one PuTTY on this machine has cached'; Fingerprint = (Get-PlinkHostKeyFingerprint $err); Output = @(); ExitStatus = $ExitCode }
    }
    if ($err -match '(?i)host key is not cached|not cached in the registry|not cached for this server|Cannot confirm a host key') {
        return [pscustomobject]@{ Kind = 'HostKeyUnknown'; Message = 'PuTTY on this machine has not seen its SSH host key'; Fingerprint = (Get-PlinkHostKeyFingerprint $err); Output = @(); ExitStatus = $ExitCode }
    }
    $fatal = [regex]::Match($err, '(?im)^FATAL ERROR:\s*(.+?)\s*$')
    if ($fatal.Success -or $err -match '(?i)^\s*Access denied') {
        $msg = $(if ($fatal.Success) { $fatal.Groups[1].Value } else { 'Access denied' })
        if ($err -match '(?i)Access denied' -and $msg -notmatch '(?i)access denied') { $msg = "Access denied ($msg)" }
        return [pscustomobject]@{ Kind = 'Failed'; Message = $msg; Fingerprint = ''; Output = @(); ExitStatus = $ExitCode }
    }
    return [pscustomobject]@{ Kind = 'Done'; Message = ''; Fingerprint = ''; Output = (ConvertFrom-CommandText $StdOut); ExitStatus = $ExitCode; ErrorText = (Remove-PlinkNotices $err) }
}

function Start-PlinkCommand {
    # Starts plink for one command and returns at once. The password (-pwfile) and the command
    # (-m) are written to files in the current user's temp folder and removed when the command
    # is collected (or at the end of the run), so neither appears on a command line.
    param($Node, [string]$Script, [int]$TimeoutSec = 300, [string]$HostKey = '')
    $user = [string](Get-Prop $Node.Credential 'UserName' 'root')
    $noBom = New-Object System.Text.UTF8Encoding($false)
    $pwFile = Join-Path ([IO.Path]::GetTempPath()) ('vvf-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $cmdFile = Join-Path ([IO.Path]::GetTempPath()) ('vvf-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($pwFile, $Node.Credential.GetNetworkCredential().Password, $noBom)
    $script:PlinkPasswordFiles.Add($pwFile)
    [IO.File]::WriteAllText($cmdFile, (([string]$Script) -replace "`r", ''), $noBom)
    $script:PlinkPasswordFiles.Add($cmdFile)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:PlinkExe
        $psi.Arguments = Get-PlinkArguments $Node.Name $user $pwFile $HostKey $cmdFile
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        # Nothing goes over plink's input: the command is in its -m file.
        $p.StandardInput.Close()
    } catch {
        Remove-Item -LiteralPath $pwFile, $cmdFile -Force -ErrorAction SilentlyContinue
        throw "could not start plink ($($script:PlinkExe)): $($_.Exception.Message)"
    }
    return [pscustomobject]@{ Process = $p; Out = $out; Err = $err; PwFile = $pwFile; CmdFile = $cmdFile; TimeoutSec = $TimeoutSec; Clock = [Diagnostics.Stopwatch]::StartNew() }
}

function Receive-PlinkCommand {
    # Waits for a plink command (within its timeout, from its start) and returns its outcome.
    param($Handle)
    try {
        $left = [math]::Max(1, $Handle.TimeoutSec - [int]$Handle.Clock.Elapsed.TotalSeconds)
        if (-not $Handle.Process.WaitForExit([int]($left * 1000))) {
            try { $Handle.Process.Kill() } catch { }
            throw "Timed out after $($Handle.TimeoutSec)s waiting for the command."
        }
        $Handle.Process.WaitForExit()
        return (Get-PlinkOutcome $Handle.Out.Result $Handle.Err.Result $Handle.Process.ExitCode)
    } finally {
        Remove-Item -LiteralPath $Handle.PwFile, $Handle.CmdFile -Force -ErrorAction SilentlyContinue
        try { $Handle.Process.Dispose() } catch { }
    }
}

function Open-NodePlink {
    # The first plink connection to a vCenter: a probe that also settles its host key. A key
    # PuTTY has not seen is trusted for this run (first use), logged and pinned; a key that
    # differs from PuTTY's cache is refused. Root must log in to bash.
    param($Node)
    $user = [string](Get-Prop $Node.Credential 'UserName' 'root')
    $probe = 'echo VVF_PROBE_$((40+2))'
    $r = Receive-PlinkCommand (Start-PlinkCommand $Node $probe 60 $Node.HostKey)
    if ($r.Kind -eq 'HostKeyUnknown') {
        if (-not $r.Fingerprint) { throw "SSH to $($Node.Name) as ${user}: PuTTY has not seen its SSH host key and plink did not show its fingerprint -- connect once with PuTTY and accept the key, then run again." }
        $Node.HostKey = $r.Fingerprint
        Write-Note "$($Node.Name): PuTTY on this machine has not seen its SSH host key -- trusting $($r.Fingerprint) for this run (first use)."
        $r = Receive-PlinkCommand (Start-PlinkCommand $Node $probe 60 $Node.HostKey)
    }
    if ($r.Kind -eq 'HostKeyChanged') {
        throw "SSH to $($Node.Name) as $user refused: $($r.Message)$(if ($r.Fingerprint) { " (it now offers $($r.Fingerprint))" }). That is what a different machine answering in its place looks like. Check with a senior engineer; if the vCenter's SSH key was regenerated (rebuild, restore), connect once with PuTTY and accept the new key, then run again."
    }
    if ($r.Kind -ne 'Done') { throw (Get-SshFailureText $Node.Name $user 'connecting and logging in' $r.Message) }
    if ((@($r.Output) -join "`n") -notmatch 'VVF_PROBE_42') {
        throw "SSH to $($Node.Name) as ${user}: root logs in to the appliance shell, not bash, and with plink the script needs bash. On the appliance as root: 'shell', then 'chsh -s /bin/bash root' (VMware's documented step for SCP/WinSCP); or use Posh-SSH."
    }
    $Node.Ssh = [pscustomobject]@{ Client = 'Plink'; Connected = $true }
    $Node.ShellMode = 'Plink'
}

function Resolve-SshClient {
    # Which SSH client this run uses: Posh-SSH when it loads (unless Plink is asked for), else
    # plink 0.77 or later. Throws, saying what to install, when neither is usable.
    param([string]$Wanted, [string]$PlinkPath)
    $why = ''
    if ($Wanted -ne 'Plink') {
        if (Get-Command New-SSHSession -ErrorAction SilentlyContinue) { return [pscustomobject]@{ Client = 'PoshSSH'; PlinkExe = ''; Version = $null; Note = 'Posh-SSH' } }
        try { Import-Module Posh-SSH -ErrorAction Stop | Out-Null; return [pscustomobject]@{ Client = 'PoshSSH'; PlinkExe = ''; Version = $null; Note = 'Posh-SSH' } }
        catch { $why = $_.Exception.Message }
        if ($Wanted -eq 'PoshSSH') { throw "Posh-SSH cannot be loaded: $why. Install-Module Posh-SSH -Scope CurrentUser -- or, where it is blocked (e.g. by antivirus), use PuTTY's plink: -SshClient Plink." }
    }
    $cands = @()
    $onPath = Get-Command plink.exe, plink -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $cands += $onPath.Source }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) { if ($pf) { $cands += (Join-Path $pf 'PuTTY\plink.exe') } }
    $exe = Find-PlinkPath $PlinkPath $cands
    if (-not $exe) {
        if ($PlinkPath) { throw "There is no plink at '$PlinkPath'." }
        throw "No SSH client: Posh-SSH $(if ($why) { "cannot be loaded ($why)" } else { 'was not asked for' }), and PuTTY's plink.exe was not found on the PATH or in Program Files\PuTTY. Install Posh-SSH or PuTTY 0.77 or later, or pass -PlinkPath."
    }
    $ver = $null
    try { $ver = ConvertFrom-PlinkVersion ((& $exe -V 2>&1 | ForEach-Object { "$_" }) -join "`n") } catch { }
    if (-not $ver -or $ver -lt [version]'0.77') {
        throw "plink at $exe is $(if ($ver) { "version $ver" } else { 'of an unknown version' }); the script needs 0.77 or later (its -pwfile keeps the password off the command line). Update PuTTY."
    }
    return [pscustomobject]@{ Client = 'Plink'; PlinkExe = $exe; Version = $ver; Note = "PuTTY plink $ver ($exe)$(if ($why) { " -- Posh-SSH cannot be loaded: $why" })" }
}

function Close-NodeSsh {
    param($Node)
    if ($Node.Ssh -and (Get-Prop $Node.Ssh 'Client' '') -ne 'Plink') { try { Remove-SSHSession -SSHSession $Node.Ssh | Out-Null } catch { } }
    $Node.Ssh = $null; $Node.Stream = $null; $Node.ShellMode = $null
}

function Read-StreamUntil {
    param($Stream, [string]$Pattern, [int]$TimeoutSec)
    $buffer = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $chunk = $Stream.Read()
        if ($chunk) { $buffer += $chunk; if ($buffer -match $Pattern) { return $buffer } }
        else { Start-Sleep -Milliseconds 250 }
    }
    throw "Timed out after ${TimeoutSec}s waiting for the appliance shell."
}

function Get-SshFailureText {
    # An SSH failure -> one line saying which vCenter, as whom, at which step, and what usually
    # causes it. The library's own text alone ("An established connection was aborted by the
    # server") says none of that.
    param([string]$Name, [string]$User, [string]$Step, [string]$Message)
    $m = ([string]$Message) -replace '^.*preference variable "ErrorActionPreference" or common parameter is set to Stop:\s*', ''
    $hint = ''
    if ($m -match '(?i)aborted by the server|forcibly closed|connection was closed|connection lost|reset by peer|unexpectedly closed') {
        $hint = "The appliance dropped the login. Usual causes: the root password has expired (log in to https://${Name}:5480 as root to see), root is locked after failed logins (it unlocks after a while), or the appliance only offers SSH algorithms this Posh-SSH does not support (use Posh-SSH 4 or later). Check with PuTTY as $User."
    } elseif ($m -match '(?i)permission denied|access denied|authentication|auth fail|password') {
        $hint = "The password for $User was refused. If the vCenters do not all share one root password, give that host or vCenter its own credential (secret vvf-vcenter-<name> / vvf-esxi-<name>, or RICHO_VVF_VCENTER_<NAME>_USER/_PASSWORD) -- see CREDENTIALS in the help."
    } elseif ($m -match '(?i)timed? ?out|refused|no such host|not known|unreachable|could not resolve|does not exist') {
        $hint = "Nothing answered SSH on port 22. Check SSH is enabled in the VAMI (Access), the name resolves, and no firewall blocks port 22 from this machine."
    }
    return ("SSH to $Name as $User failed while ${Step}: $m" + $(if ($hint) { " -- $hint" } else { '' }))
}

function Open-NodeSsh {
    # Root on the appliance logs in to bash or to the appliance shell (appliancesh). Bash
    # takes commands directly; appliancesh needs an interactive stream and the "shell"
    # command first. Which one is detected here, once per session.
    param($Node)
    if ($Node.Ssh -and (Get-Prop $Node.Ssh 'Connected' $true)) { return }
    Close-NodeSsh $Node
    if ((Get-Variable -Name SshClientInUse -Scope Script -ValueOnly -ErrorAction SilentlyContinue) -eq 'Plink') { Open-NodePlink $Node; return }
    $user = [string](Get-Prop $Node.Credential 'UserName' 'root')
    try { $Node.Ssh = New-SSHSession -ComputerName $Node.Name -Credential $Node.Credential -AcceptKey -ConnectionTimeout 30 -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { $Node.Ssh = $null; throw (Get-SshFailureText $Node.Name $user 'connecting and logging in' $_.Exception.Message) }
    $probe = $null
    try { $probe = Invoke-SSHCommand -SSHSession $Node.Ssh -Command 'echo VVF_PROBE_$((40+2))' -TimeOut 30 -ErrorAction Stop } catch { }
    if ($probe -and ((@(Get-Prop $probe 'Output' @()) -join "`n") -match 'VVF_PROBE_42')) { $Node.ShellMode = 'Exec'; return }

    try {
        $Node.Stream = New-SSHShellStream -SSHSession $Node.Ssh -TerminalName 'dumb' -Columns 4096 -Rows 200
        $null = Read-StreamUntil $Node.Stream '(Command>|#|\$)\s*$' 30
        $Node.Stream.WriteLine('shell')
        Start-Sleep -Milliseconds 500
        # No history (the replication checks carry a password) and no echo.
        $Node.Stream.WriteLine('unset HISTFILE; export TERM=dumb; stty -echo 2>/dev/null; echo VVF_READY_$((40+2))')
        $null = Read-StreamUntil $Node.Stream 'VVF_READY_42' 30
    } catch { throw (Get-SshFailureText $Node.Name $user 'switching from the appliance shell to bash' $_.Exception.Message) }
    $Node.ShellMode = 'Stream'
}

function ConvertFrom-CommandText {
    # The text of a finished command -> its lines, as Invoke-SSHCommand gives them.
    param([string]$Text)
    $lines = @(([string]$Text -replace "`r", '') -split "`n")
    if ($lines.Count -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    return [string[]]$lines
}

function Start-NodeShell {
    # Starts one bash command on the appliance and returns at once; Receive-NodeShell collects
    # the result. Starting the same command on several appliances before collecting any is
    # what lets the group checks run on all of them at the same time.
    param($Node, [string]$Command, [int]$TimeoutSec = 300)
    if ($Node.SshOff) { throw "SSH is off on $($Node.Name) (it could not be turned on)." }
    Open-NodeSsh $Node
    $h = [pscustomobject]@{
        Node = $Node; TimeoutSec = $TimeoutSec; Clock = [Diagnostics.Stopwatch]::StartNew()
        Command = $null; Async = $null; Id = $null; Result = $null; Plink = $null
    }
    if ($Node.ShellMode -eq 'Plink') { $h.Plink = Start-PlinkCommand $Node $Command $TimeoutSec $Node.HostKey; return $h }
    if ($Node.ShellMode -eq 'Exec') {
        # Posh-SSH's session wraps an SSH.NET client, which can run a command asynchronously.
        $client = Get-Prop $Node.Ssh 'Session'
        if ($client -and @($client.PSObject.Methods | Where-Object { $_.Name -eq 'CreateCommand' }).Count) {
            $cmd = $client.CreateCommand($Command)
            $cmd.CommandTimeout = [TimeSpan]::FromSeconds($TimeoutSec)
            $h.Command = $cmd
            $h.Async = $cmd.BeginExecute()
        } else {
            $r = Invoke-SSHCommand -SSHSession $Node.Ssh -Command $Command -TimeOut $TimeoutSec -ErrorAction Stop
            $h.Result = [pscustomobject]@{ Output = [string[]]@(Get-Prop $r 'Output' @()); ExitStatus = [int](Get-Prop $r 'ExitStatus' 0); ErrorText = [string](Get-Prop $r 'Error' '') }
        }
        return $h
    }
    $Node.Seq++
    $h.Id = '{0}{1}' -f $Node.Seq, (Get-Random -Minimum 1000 -Maximum 9999)
    $null = $Node.Stream.Read()
    $Node.Stream.WriteLine(('echo VVFB_""{0}; {1}; echo VVFE_""{0}_$?' -f $h.Id, $Command))
    return $h
}

function Receive-NodeShell {
    # Waits for a command started with Start-NodeShell (within its timeout, counted from the
    # start) and returns Output and ExitStatus.
    param($Handle)
    if ($Handle.Result) { return $Handle.Result }
    if ($Handle.Plink) {
        $r = Receive-PlinkCommand $Handle.Plink
        if ($r.Kind -ne 'Done') { throw $(if ($r.Kind -eq 'Failed') { $r.Message } else { "$($r.Message) -- the host key changed during the run" }) }
        return [pscustomobject]@{ Output = [string[]]@($r.Output); ExitStatus = [int]$r.ExitStatus; ErrorText = [string](Get-Prop $r 'ErrorText' '') }
    }
    $left = [math]::Max(1, $Handle.TimeoutSec - [int]$Handle.Clock.Elapsed.TotalSeconds)
    if ($Handle.Async) {
        if (-not $Handle.Async.AsyncWaitHandle.WaitOne([int]($left * 1000))) {
            try { $Handle.Command.CancelAsync() } catch { }
            throw "Timed out after $($Handle.TimeoutSec)s waiting for the command."
        }
        $text = $Handle.Command.EndExecute($Handle.Async)
        $status = 0
        try { $status = [int]$Handle.Command.ExitStatus } catch { }
        $errText = ''
        try { $errText = [string]$Handle.Command.Error } catch { }
        return [pscustomobject]@{ Output = (ConvertFrom-CommandText $text); ExitStatus = $status; ErrorText = $errText }
    }
    $text = Read-StreamUntil $Handle.Node.Stream "(?m)^VVFE_$($Handle.Id)_\d+" $left
    $r = Get-MarkedOutput $text $Handle.Id
    if ($null -eq $r) { throw 'Could not read the command output from the appliance shell.' }
    return $r
}

function Get-NodeShellError {
    # A failed command -> the error to report (the SSH step, the user and the usual causes).
    param($Node, $ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    if ($msg -match '^SSH (to|is off)') { return $msg }
    return (Get-SshFailureText $Node.Name ([string](Get-Prop $Node.Credential 'UserName' 'root')) 'running a command' $msg)
}

function Invoke-NodeShell {
    # Runs one bash command on the appliance; reconnects once if the session has gone.
    param($Node, [string]$Command, [int]$TimeoutSec = 300)
    if ($Node.SshOff) { throw "SSH is off on $($Node.Name) (it could not be turned on)." }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            return (Receive-NodeShell (Start-NodeShell $Node $Command $TimeoutSec))
        } catch {
            Close-NodeSsh $Node
            if ($attempt -eq 2) { throw (Get-NodeShellError $Node $_) }
        }
    }
}

function Invoke-GroupShell {
    # One bash command on every node at the same time: started on all, then collected from
    # all. A node whose session had gone is retried once on its own, reconnected. Returns, by
    # node name, Result (Output, ExitStatus) or Error (text).
    param($Nodes, [string]$Command, [int]$TimeoutSec = 300)
    $out = @{}
    $handles = [ordered]@{}
    $again = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($Nodes)) {
        if ($n.SshOff) { $out[$n.Name] = [pscustomobject]@{ Result = $null; Error = "SSH is off on $($n.Name) (it could not be turned on)." }; continue }
        try { $handles[$n.Name] = Start-NodeShell $n $Command $TimeoutSec } catch { Close-NodeSsh $n; $again.Add($n) }
    }
    foreach ($n in @($Nodes)) {
        if (-not $handles.Contains($n.Name)) { continue }
        try { $out[$n.Name] = [pscustomobject]@{ Result = (Receive-NodeShell $handles[$n.Name]); Error = '' } }
        catch { Close-NodeSsh $n; $again.Add($n) }
    }
    foreach ($n in $again) {
        try { $out[$n.Name] = [pscustomobject]@{ Result = (Invoke-NodeShell $n $Command $TimeoutSec); Error = '' } }
        catch { $out[$n.Name] = [pscustomobject]@{ Result = $null; Error = $_.Exception.Message } }
    }
    return $out
}

function Get-SshEndAction {
    # What to do with SSH on one vCenter when a run ends. Disable or Leave.
    #   $EnabledByRun   this run, or the stopped run it resumes, turned SSH on there
    #   $Completed      the whole upgrade completed (every vCenter done, ISO unmounted)
    #   $Unfinished     a real run left an unfinished state file (it will be resumed)
    #   $FinalState     -SshFinalState: Restore or Disable
    # A run part way through leaves SSH on: the resume and the person looking need it. A
    # completed upgrade (or a dry run, or a run refused before it started) turns it off where
    # the run turned it on -- and with Disable, after a completed upgrade, everywhere.
    param([bool]$EnabledByRun, [bool]$Completed, [bool]$Unfinished, [bool]$DryRun, [string]$FinalState = 'Restore')
    if (-not $DryRun -and $Unfinished) { return 'Leave' }
    if ($EnabledByRun) { return 'Disable' }
    if ($Completed -and -not $DryRun -and $FinalState -eq 'Disable') { return 'Disable' }
    return 'Leave'
}

function Enable-NodeSsh {
    # SSH is needed for the service, disk, expiry and replication checks and for releasing the
    # ISO inside the appliance. Turned on through the API when it is off -- in a dry run too,
    # which turns it off again at its end -- and remembered so it is turned off again once the
    # whole upgrade has completed. When it cannot be turned on in a dry run, the node is marked
    # and the checks that need SSH are skipped and listed; in a real run that is an error.
    param($Node, [bool]$DryRun = $false)
    $enabled = $true
    try { $enabled = [bool](Invoke-NodeApi $Node 'Get' '/appliance/access/ssh') }
    catch { Write-Warn "Could not read the SSH setting on $($Node.Name): $($_.Exception.Message)"; return }
    if ($null -eq $Node.SshWasOn) { $Node.SshWasOn = $enabled }
    if ($enabled) { Write-Note "$($Node.Name): SSH is already on."; return }
    Write-Step "$($Node.Name): turning SSH on for the run$(if ($DryRun) { ' (the dry run turns it off again at its end)' }) ..."
    try { Invoke-NodeApi $Node 'Put' '/appliance/access/ssh' @{ enabled = $true } | Out-Null }
    catch {
        if (-not $DryRun) { throw "could not turn SSH on on $($Node.Name): $($_.Exception.Message)" }
        Write-Warn "Could not turn SSH on on $($Node.Name) ($($_.Exception.Message)): the checks that need it are skipped."
        $Node.SshOff = $true
        return
    }
    $Node.SshEnabledByScript = $true
}

function Wait-NodeSshReady {
    # Opens SSH to a vCenter, retrying for a while: sshd takes a few seconds to start after it
    # is turned on, and longer while the appliance boots.
    param($Node, [int]$Tries = 6, [int]$PauseSeconds = 10)
    for ($t = 1; ; $t++) {
        try { Open-NodeSsh $Node; return }
        catch {
            if ($t -ge $Tries) { throw }
            Write-Note "$($Node.Name): SSH not answering yet ($(($_.Exception.Message -split "`n")[0])) -- trying again in ${PauseSeconds}s ($t/$Tries)."
            Close-NodeSsh $Node
            Start-Sleep -Seconds $PauseSeconds
        }
    }
}

function Confirm-NodeSshEnabled {
    # After a power-on or reboot: SSH must still be on (the checks that follow need it). Turned
    # on again when it is off -- and then counted as turned on by this run, so it is turned off
    # at the end. Returns '' or why it could not be confirmed.
    param($Node)
    $on = $null
    try { $on = [bool](Invoke-NodeApi $Node 'Get' '/appliance/access/ssh') } catch { return "could not read the SSH setting: $($_.Exception.Message)" }
    if ($on) { return '' }
    Write-Warn "$($Node.Name): SSH was off after the power cycle -- turning it on again."
    try { Invoke-NodeApi $Node 'Put' '/appliance/access/ssh' @{ enabled = $true } | Out-Null }
    catch { return "could not turn SSH on again: $($_.Exception.Message)" }
    $Node.SshEnabledByScript = $true
    Close-NodeSsh $Node
    Save-UpgradeState
    return ''
}

function Disable-NodeSsh {
    # Turns SSH off on one vCenter through the appliance API. Never throws: returns '' or why
    # not, and records the result on the node for the summary.
    param($Node, [string]$Why = '')
    Close-NodeSsh $Node
    try {
        Invoke-NodeApi $Node 'Put' '/appliance/access/ssh' @{ enabled = $false } | Out-Null
        $Node.SshEnabledByScript = $false
        $Node.SshFinal = 'Off'
        Write-Note "$($Node.Name): SSH turned off$(if ($Why) { " ($Why)" })."
        return ''
    } catch {
        $Node.SshFinal = 'STILL ON (could not turn off)'
        Write-Warn "Could not turn SSH off on $($Node.Name) -- do it in the VAMI (https://$($Node.Name):5480, Access): $($_.Exception.Message)"
        return $_.Exception.Message
    }
}

# =============================================================== checks over a node ==

function Get-CommandDiagnostic {
    # What a command returned, in one line, for a finding: its first output lines, its error
    # output and its exit status -- or that it returned nothing at all.
    param($Result)
    $lines = @(@(Get-Prop $Result 'Output' @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $err = @(([string](Get-Prop $Result 'ErrorText' '')) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $cut = { param($t) if ($t.Length -gt 120) { $t.Substring(0, 117) + '...' } else { $t } }
    $parts = @()
    $parts += $(if ($lines.Count) { 'output: ' + ((@($lines | Select-Object -First 3) | ForEach-Object { "'$(& $cut $_)'" }) -join ' / ') + $(if ($lines.Count -gt 3) { " (+$($lines.Count - 3) more lines)" }) } else { 'no output' })
    if ($err.Count) { $parts += 'errors: ' + ((@($err | Select-Object -First 2) | ForEach-Object { "'$(& $cut $_)'" }) -join ' / ') }
    $parts += "exit status $([int](Get-Prop $Result 'ExitStatus' 0))"
    return ($parts -join '; ')
}

function Test-ServiceStatusEmpty {
    # Whether a parsed service status has nothing in it at all -- neither section answered.
    param($Status)
    return (@((Get-Prop $Status 'Control' @{}).Keys).Count -eq 0 -and @(Get-Prop $Status 'Vmon' @()).Count -eq 0)
}

function Get-StatusReadiness {
    # A service-status command's result -> readiness. When the parallel read returned nothing,
    # it is read again one service after another; when that too returns nothing, the readiness
    # carries what the command did return, for the finding.
    # A vCenter where the one-by-one read answers and the parallel one does not is read one by
    # one from then on (said once). Both empty is also what a booting vCenter gives, so that
    # alone changes nothing.
    param($Node, $Result)
    $status = ConvertFrom-ServiceStatusOutput $Result.Output
    $diag = ''
    if (Test-ServiceStatusEmpty $status) {
        $diag = Get-CommandDiagnostic $Result
        if (-not $Node.StatusOneByOne) {
            try {
                $again = Invoke-NodeShell $Node (Get-ServiceStatusCommand -Sequential) 600
                $second = ConvertFrom-ServiceStatusOutput $again.Output
                if (Test-ServiceStatusEmpty $second) { $diag = "parallel read -- $diag; one-by-one read -- $(Get-CommandDiagnostic $again)" }
                else {
                    $Node.StatusOneByOne = $true
                    Write-Note "$($Node.Name): the parallel service read returned nothing here ($diag) -- reading its services one after another from now on."
                    $status = $second; $diag = ''
                }
            } catch { $diag = "$diag; one-by-one read failed: $($_.Exception.Message)" }
        }
    }
    $ready = Get-ServiceReadiness $status
    $ready | Add-Member -NotePropertyName Diagnostic -NotePropertyValue $diag -Force
    return $ready
}

function Get-NodeServiceReadiness {
    param($Node)
    $r = Invoke-NodeShell $Node (Get-ServiceStatusCommand -Sequential:([bool]$Node.StatusOneByOne)) 600
    return (Get-StatusReadiness $Node $r)
}

function Get-GroupServiceReadiness {
    # Service readiness of every node, read on all of them at the same time. Returns, by node
    # name, Ready (the readiness) or Error (text).
    param($Nodes)
    $out = @{}
    $res = @{}
    foreach ($oneByOne in @($false, $true)) {
        $some = @(@($Nodes) | Where-Object { [bool]$_.StatusOneByOne -eq $oneByOne })
        if ($some.Count) { $part = Invoke-GroupShell $some (Get-ServiceStatusCommand -Sequential:$oneByOne) 600; foreach ($k in $part.Keys) { $res[$k] = $part[$k] } }
    }
    foreach ($n in @($Nodes)) {
        $r = $res[$n.Name]
        if ($r.Error) { $out[$n.Name] = [pscustomobject]@{ Ready = $null; Error = $r.Error }; continue }
        $ready = Get-StatusReadiness $n $r.Result
        $n.LastReady = $ready
        $out[$n.Name] = [pscustomobject]@{ Ready = $ready; Error = '' }
    }
    return $out
}

function Wait-GroupServices {
    # Polls every node at the same time until each has every automatic service started. The
    # first check runs straight away (after the caller's pause); then every $PollSeconds, for
    # the nodes not yet ready. One timeout for the group.
    param($Nodes, [int]$PollSeconds, [int]$TimeoutMinutes, [string]$Label)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($node in @($Nodes)) { $pending.Add($node) }
    $n = 0
    # SSH is confirmed on once per vCenter per wait, as soon as its API answers: these waits
    # follow a power-on or a reboot, and the service checks need SSH.
    $sshConfirmed = @{}
    while ($true) {
        $n++
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $check = [Diagnostics.Stopwatch]::StartNew()
        $apiDown = @{}
        foreach ($node in $pending) {
            try { Reset-NodeApi $node; Connect-NodeApi $node } catch { $apiDown[$node.Name] = $_.Exception.Message; continue }
            if (-not $sshConfirmed.ContainsKey($node.Name)) {
                $why = Confirm-NodeSshEnabled $node
                if ($why) { $apiDown[$node.Name] = "SSH: $why" } else { $sshConfirmed[$node.Name] = $true }
            }
        }
        $asked = @($pending | Where-Object { -not $apiDown.ContainsKey($_.Name) })
        $res = $(if ($asked.Count) { Get-GroupServiceReadiness $asked } else { @{} })
        $took = Format-Elapsed $check.Elapsed
        foreach ($node in @($pending)) {
            $what = "$($node.Name) $Label"
            if ($apiDown.ContainsKey($node.Name)) {
                Write-Note ("[{0}] {1}: check {2}: not answering yet -- {3}" -f $stamp, $what, $n, $apiDown[$node.Name])
                Set-NodeStage $node 'WaitingForServices' 'not answering yet'
                continue
            }
            $r = $res[$node.Name]
            if ($r.Error) {
                Write-Note ("[{0}] {1}: check {2}: not answering yet -- {3}" -f $stamp, $what, $n, $r.Error)
                Set-NodeStage $node 'WaitingForServices' 'not answering yet'
                continue
            }
            $ready = $r.Ready
            if ($ready.Ready) {
                Write-Good ("[{0}] {1}: all {2} automatic services started (after {3})" -f $stamp, $what, $ready.AutoTotal, (Format-Elapsed $sw.Elapsed))
                Set-NodeStage $node 'ServicesStarted' "all $($ready.AutoTotal) automatic services started"
                $null = $pending.Remove($node)
            } else {
                Write-Note ("[{0}] {1}: check {2}: {3}/{4} automatic services started -- {5}" -f $stamp, $what, $n, $ready.AutoStarted, $ready.AutoTotal, ($ready.Reasons -join '; '))
                Set-NodeStage $node 'WaitingForServices' ("{0}/{1} automatic services started" -f $ready.AutoStarted, $ready.AutoTotal)
            }
        }
        if (@($Nodes).Count -gt 1) { Write-Note ("[{0}] service check {1} of {2} vCenter(s) at the same time took {3}" -f $stamp, $n, @($asked).Count, $took) }
        if ($pending.Count -eq 0) { return }
        if ($sw.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
            throw "$(($pending | ForEach-Object { $_.Name }) -join ', ') $Label`: services were not all started after $TimeoutMinutes minute(s)."
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-NodeHealthFindings {
    # The pre- and post-upgrade checks for one appliance. Returns findings; never throws for
    # a single failed check (that becomes a finding of its own).
    # $Ready: the service readiness when it has just been read (for the whole group at once),
    # so the slowest command is not run a second time.
    param($Node, [string]$Phase, [datetime]$Now, $Ready = $null)
    $out = [System.Collections.Generic.List[object]]::new()
    $name = $Node.Name
    $ssh = -not $Node.SshOff
    if (-not $ssh) { $out.Add((New-Finding $Phase $name 'Warning' 'Checks skipped' 'SSH is off: services, vCenter HA, disk, root password and certificate expiry not checked')) }

    if ($ssh) { try {
        $ready = $(if ($Ready) { $Ready } else { Get-NodeServiceReadiness $Node })
        $diag = [string](Get-Prop $ready 'Diagnostic' '')
        foreach ($why in @($ready.Reasons | Where-Object { $_ -match 'not answering' })) { $out.Add((New-Finding $Phase $name 'Error' 'Service status' "could not read: $why$(if ($diag) { " -- the command returned $diag" })")) }
        foreach ($s in $ready.NotStarted) { $out.Add((New-Finding $Phase $name 'Error' 'Service not started' "$s (automatic)")) }
        foreach ($s in $ready.CoreDown)   { $out.Add((New-Finding $Phase $name 'Error' 'Service not started' "$s (core)")) }
        foreach ($s in $ready.Pending)    { $out.Add((New-Finding $Phase $name 'Warning' 'Service transitioning' $s)) }
        foreach ($s in $ready.Unhealthy)  { $out.Add((New-Finding $Phase $name 'Warning' 'Service health' $s)) }
        if ($ready.StoppedManual.Count)   { $out.Add((New-Finding $Phase $name 'Info' 'Manual services stopped' ($ready.StoppedManual -join ', '))) }
        if ($Phase -eq 'Pre') {
            $vcha = $false
            try { $r = Invoke-NodeShell $Node "vmon-cli --status vcha 2>/dev/null | grep -E '^ *RunState:'" 60; $vcha = ((@($r.Output) -join ' ') -match 'RunState:\s*STARTED') } catch { }
            if ($vcha) { $out.Add((New-Finding $Phase $name 'Warning' 'vCenter HA' 'the vcha service is running -- remove vCenter HA before patching')) }
        }
    } catch { $out.Add((New-Finding $Phase $name 'Error' 'Service status' "could not read: $($_.Exception.Message)")) } }

    foreach ($indicator in @('system', 'applmgmt', 'database-storage', 'load', 'mem', 'software-packages', 'storage', 'swap')) {
        try {
            $v = [string](Invoke-NodeApi $Node 'Get' "/appliance/health/$indicator")
            $f = Get-HealthFinding $indicator $v $Phase $name
            if ($f) { $out.Add($f) }
        } catch {
            if ($indicator -eq 'system') { $out.Add((New-Finding $Phase $name 'Warning' 'Appliance health' "system health unreadable: $($_.Exception.Message)")) }
        }
    }

    if ($ssh) { try {
        $r = Invoke-NodeShell $Node 'df -P -x tmpfs -x devtmpfs -x iso9660 -x squashfs 2>/dev/null' 60
        foreach ($f in (Get-DiskFindings (ConvertFrom-DfOutput $r.Output) $Phase $name)) { $out.Add($f) }
    } catch { $out.Add((New-Finding $Phase $name 'Warning' 'Disk space' "could not read: $($_.Exception.Message)")) } }

    if ($ssh) { try {
        $r = Invoke-NodeShell $Node 'chage -l root 2>/dev/null' 60
        $f = Get-ExpiryFinding (ConvertFrom-ChageOutput $r.Output) $Now $Phase $name 'Root password' 14 1
        if ($f) { $out.Add($f) }
    } catch { $out.Add((New-Finding $Phase $name 'Warning' 'Root password' "could not read expiry: $($_.Exception.Message)")) } }

    if ($ssh) { try {
        $r = Invoke-NodeShell $Node '/usr/lib/vmware-vmafd/bin/vecs-cli entry getcert --store MACHINE_SSL_CERT --alias __MACHINE_CERT 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null' 60
        $f = Get-ExpiryFinding (ConvertFrom-OpenSslEndDate $r.Output) $Now.ToUniversalTime() $Phase $name 'Machine SSL certificate' 30 0
        if ($f) { $out.Add($f) }
    } catch { $out.Add((New-Finding $Phase $name 'Warning' 'Machine SSL certificate' "could not read expiry: $($_.Exception.Message)")) } }

    try {
        $s = Get-UpdateTaskSummary (Invoke-NodeApi $Node 'Get' '/appliance/update')
        if ($s.State -eq 'INSTALL_FAILED') { $out.Add((New-Finding $Phase $name 'Error' 'Update state' "an earlier update failed$(if ($s.Error) { ": $($s.Error)" })")) }
        elseif ($s.State -match 'IN_PROGRESS$') { $out.Add((New-Finding $Phase $name 'Error' 'Update state' "$($s.State) -- an update is already running")) }
    } catch { $out.Add((New-Finding $Phase $name 'Warning' 'Update state' "could not read: $($_.Exception.Message)")) }

    return $out.ToArray()
}

function Get-GroupReplicationFindings {
    # showpartnerstatus from every node in the ELM group. A partner that is behind is
    # re-read (up to three times, 30s apart) before it is reported: right after a reboot or
    # a change, a lag of a few changes is normal and clears on its own.
    # Read on every node at the same time; those behind are re-read together after one wait.
    param($Nodes, [System.Management.Automation.PSCredential]$Sso, [string]$Phase)
    $out = [System.Collections.Generic.List[object]]::new()
    $byNode = @{}
    $ask = @()
    foreach ($node in @($Nodes)) {
        if ($node.SshOff) { $byNode[$node.Name] = @(New-Finding $Phase $node.Name 'Warning' 'ELM replication' 'not checked: SSH is off') }
        else { $ask += $node }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    for ($try = 1; $try -le 3 -and $ask.Count; $try++) {
        $res = Invoke-GroupShell $ask (Get-VdcrepadminCommand 'showpartnerstatus' $Sso) 120
        $behind = @()
        foreach ($node in $ask) {
            $r = $res[$node.Name]
            if ($r.Error) { $byNode[$node.Name] = @(New-Finding $Phase $node.Name 'Error' 'ELM replication' "could not check: $($r.Error)"); continue }
            $text = (@($r.Result.Output) -join ' ')
            if ($r.Result.ExitStatus -ne 0 -or $text -match '(?i)invalid credentials|failed|error') {
                $byNode[$node.Name] = @(New-Finding $Phase $node.Name 'Error' 'ELM replication' "vdcrepadmin failed: $($text.Trim())")
                continue
            }
            $findings = @(Get-ReplicationFindings (ConvertFrom-PartnerStatus $r.Result.Output) $Phase $node.Name)
            $byNode[$node.Name] = $findings
            if (@($findings | Where-Object { $_.Severity -ne 'Info' -and $_.Detail -match 'behind' }).Count) { $behind += $node }
        }
        $ask = $behind
        if ($ask.Count -and $try -lt 3) {
            Write-Note "$(($ask | ForEach-Object { $_.Name }) -join ', '): a partner is behind -- re-reading in 30s ($try/3)"
            Start-Sleep -Seconds 30
        } else { break }
    }
    if (@($Nodes).Count -gt 1) { Write-Note ("Replication read from {0} vCenter(s) at the same time in {1}" -f @($Nodes).Count, (Format-Elapsed $clock.Elapsed)) }
    foreach ($node in @($Nodes)) { foreach ($f in @($byNode[$node.Name])) { if ($f) { $out.Add($f) } } }
    return $out.ToArray()
}

# ====================================================================== ESXi side ==

function Find-ApplianceVm {
    param($EsxiServer, [string]$VCenterName, [string]$VmName)
    $vms = @(Get-VM -Server $EsxiServer -ErrorAction Stop)
    if ($VmName) {
        $hit = @($vms | Where-Object { $_.Name -eq $VmName })
        if ($hit.Count -eq 1) { return $hit[0] }
        Write-Warn "No VM named '$VmName' on this host."
    }
    $short = Get-ShortName $VCenterName
    $hit = @($vms | Where-Object { $_.Name -ieq $VCenterName -or $_.Name -ieq $short })
    if ($hit.Count -eq 1) { return $hit[0] }
    $hit = @($vms | Where-Object {
        $g = [string](Get-PropPath $_ 'ExtensionData.Guest.HostName' '')
        $ip = [string](Get-PropPath $_ 'ExtensionData.Guest.IpAddress' '')
        ($g -and ($g -ieq $VCenterName -or (Get-ShortName $g) -ieq $short)) -or ($ip -and $ip -eq $VCenterName)
    })
    if ($hit.Count -eq 1) { return $hit[0] }

    # No prompt: the VM's inventory name goes in the CSV's VmName column.
    $names = @($vms | ForEach-Object { "$($_.Name) [$($_.PowerState)]" })
    throw "could not tell which VM is the vCenter by name or guest host name -- put its inventory name in the CSV's VmName column. VMs on this host: $(if ($names.Count) { $names -join ', ' } else { 'none' })"
}

function Get-IsoDrive {
    # The CD-ROM drive with an ISO on it, or $null.
    param($Vm)
    $drives = @(Get-CDDrive -VM $Vm -ErrorAction Stop)
    $withIso = @($drives | Where-Object { [string](Get-Prop $_ 'IsoPath' '') })
    if ($withIso.Count -eq 0) { return $null }
    return $withIso[0]
}

function Test-IsoDrive {
    # Checks (and where safe, fixes) the CD-ROM: ISO attached, connected, and set to connect
    # at power on -- without that last one the ISO falls off when the VM is power cycled for
    # the snapshot. A dry run reports what it would set instead of setting it.
    param($Vm, [string]$Phase, [string]$Node, [bool]$DryRun = $false)
    $out = [System.Collections.Generic.List[object]]::new()
    $drive = Get-IsoDrive $Vm
    if ($null -eq $drive) {
        $out.Add((New-Finding $Phase $Node 'Error' 'Upgrade ISO' 'no ISO is mounted on the appliance VM CD-ROM'))
        return [pscustomobject]@{ Drive = $null; IsoPath = $null; Connected = $false; Findings = $out.ToArray() }
    }
    $iso = [string]$drive.IsoPath
    $connected = [bool](Get-PropPath $drive 'ConnectionState.Connected' $false)
    $startConnected = [bool](Get-PropPath $drive 'ConnectionState.StartConnected' $false)
    if (-not $startConnected -and $DryRun) {
        Write-Note 'Dry run: a real run would set the CD-ROM to connect at power on, so the ISO survives the power cycle.'
        $out.Add((New-Finding $Phase $Node 'Info' 'Upgrade ISO' 'CD-ROM not set to connect at power on (a real run sets it)'))
    }
    elseif (-not $startConnected) {
        Write-Step 'Setting the CD-ROM to connect at power on, so the ISO survives the power cycle ...'
        $drive = Set-CDDrive -CD $drive -StartConnected:$true -Confirm:$false -ErrorAction Stop
    }
    if (-not $connected -and $DryRun) {
        $out.Add((New-Finding $Phase $Node 'Warning' 'Upgrade ISO' "$iso is attached but not connected (a real run connects it)"))
    }
    elseif (-not $connected) {
        Write-Step 'The ISO is attached but not connected -- connecting it ...'
        $drive = Set-CDDrive -CD $drive -Connected:$true -Confirm:$false -ErrorAction Stop
        $connected = [bool](Get-PropPath $drive 'ConnectionState.Connected' $false)
        if (-not $connected) { $out.Add((New-Finding $Phase $Node 'Error' 'Upgrade ISO' "$iso is attached but the CD-ROM will not connect")) }
    }
    $nameFinding = Get-IsoNameFinding $iso $Phase $Node
    if ($nameFinding) { $out.Add($nameFinding) }
    return [pscustomobject]@{ Drive = $drive; IsoPath = $iso; Connected = $connected; Findings = $out.ToArray() }
}

function Get-IsoUpdate {
    # What the appliance itself sees on the CD-ROM. $null when it sees nothing.
    param($Node)
    $pending = $null
    try { $pending = Invoke-NodeApi $Node 'Get' '/appliance/update/pending?source_type=LOCAL' -TimeoutSec 180 }
    catch { Write-Note "The appliance reports no update on the ISO: $($_.Exception.Message)"; return $null }
    return (Select-PendingUpdate @($pending))
}

# ================================================================== upgrade state ==
# A small JSON file in -LogFolder records where a run got to, vCenter by vCenter, so a
# run that stopped on a failure can be continued (-Resume) from the vCenter that failed
# instead of from the beginning. Stages: Pending -> Installed (running the new version,
# reboot not yet confirmed) -> Rebooted (back up, post checks not yet passed) -> Done.

function ConvertTo-UpgradeStateJson {
    param([string]$Primary, $Nodes, [string]$IsoPath = '')
    $rows = foreach ($n in @($Nodes)) {
        [ordered]@{
            Name = $n.Name; EsxiHost = $n.EsxiHost; VmName = $(if ($n.Vm) { [string]$n.Vm.Name } else { '' })
            Stage = $n.Stage; TargetVersion = [string]$n.TargetVersion
            InstallMark = $(if ($n.InstallMark) { ([datetime]$n.InstallMark).ToUniversalTime().ToString('o') } else { '' })
            LastError = [string]$n.LastError
            SshEnabledByRun = [bool]$n.SshEnabledByScript
        }
    }
    $doc = [ordered]@{ Script = 'Invoke-VvfVCenterUpgrade'; StateVersion = 1; Primary = $Primary; IsoPath = $IsoPath; Updated = (Get-Date).ToUniversalTime().ToString('o'); Nodes = @($rows) }
    return ($doc | ConvertTo-Json -Depth 5)
}

function ConvertFrom-UpgradeStateJson {
    # The state file -> an object with Primary and Nodes, or a throw that says what is wrong.
    param([string]$Json)
    $doc = $Json | ConvertFrom-Json
    if ((Get-Prop $doc 'Script') -ne 'Invoke-VvfVCenterUpgrade' -or (Get-Prop $doc 'StateVersion') -ne 1) { throw 'not an upgrade state file from this script' }
    $nodes = foreach ($n in @(Get-Prop $doc 'Nodes' @())) {
        $stage = [string](Get-Prop $n 'Stage' 'Pending')
        if ($stage -notin @('Pending', 'Installed', 'Rebooted', 'Done')) { throw "unknown stage '$stage' for $(Get-Prop $n 'Name')" }
        $mark = $null
        $m = [string](Get-Prop $n 'InstallMark' '')
        if ($m) { $mark = [datetime]::Parse($m, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        [pscustomobject]@{
            Name = [string](Get-Prop $n 'Name'); EsxiHost = [string](Get-Prop $n 'EsxiHost' ''); VmName = [string](Get-Prop $n 'VmName' '')
            Stage = $stage; TargetVersion = [string](Get-Prop $n 'TargetVersion' ''); InstallMark = $mark; LastError = [string](Get-Prop $n 'LastError' '')
            # Added in 3.0.0; a state file from 2.x has none, which reads as "not turned on by us".
            SshEnabledByRun = [bool](Get-Prop $n 'SshEnabledByRun' $false)
        }
    }
    return [pscustomobject]@{ Primary = [string](Get-Prop $doc 'Primary'); IsoPath = [string](Get-Prop $doc 'IsoPath' ''); Nodes = @($nodes) }
}

function Merge-StateSshFlags {
    # Adds "this run turned SSH on here" to the vCenters of an existing state file, without
    # touching anything else in it -- for a run that ends before it has loaded the file's stages
    # (so saving its own view would overwrite the progress). A flag already set stays set.
    param([string]$Json, [hashtable]$EnabledByRun)
    $doc = $Json | ConvertFrom-Json
    foreach ($n in @(Get-Prop $doc 'Nodes' @())) {
        $name = [string](Get-Prop $n 'Name' '')
        $was = [bool](Get-Prop $n 'SshEnabledByRun' $false)
        $now = ($was -or ($EnabledByRun.ContainsKey($name) -and [bool]$EnabledByRun[$name]))
        if ($n.PSObject.Properties['SshEnabledByRun']) { $n.SshEnabledByRun = $now } else { $n | Add-Member -NotePropertyName SshEnabledByRun -NotePropertyValue $now }
    }
    return ($doc | ConvertTo-Json -Depth 5)
}

function Get-TextSha256 {
    # SHA-256 of a CSV's text, line endings and trailing blank space evened out, so the same CSV
    # given as a file or pasted as text (-VCenterCsvText) matches its dry-run record.
    param([string]$Text)
    $norm = (([string]$Text -replace "`r`n", "`n" -replace "`r", "`n") -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
    $norm = $norm.Trim("`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm)) } finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Get-RoundPlan {
    # What a round for $Node does, from its stage: the snapshot and install only happen for
    # a vCenter not yet installed; a retry after the install resumes from the reboot or the
    # checks. $FreshSnapshot is the operator's answer (always true on a first attempt).
    param([string]$Stage, [bool]$FreshSnapshot)
    return [pscustomobject]@{
        Snapshot = ($Stage -eq 'Pending' -and $FreshSnapshot)
        Install  = ($Stage -eq 'Pending')
        Reboot   = ($Stage -in @('Pending', 'Installed'))
        Checks   = ($Stage -ne 'Done')
    }
}

function Save-UpgradeState {
    if (-not $script:StatePath -or $DryRun) { return }
    try { ConvertTo-UpgradeStateJson $VCenter $groupNodes $(if ($script:Iso) { $script:Iso.Full } else { '' }) | Set-Content -LiteralPath $script:StatePath -Encoding UTF8 }
    catch { Write-Warn "Could not write the state file $($script:StatePath): $($_.Exception.Message)" }
}

# =========================================================== per-vCenter operations ==

function Update-NodeVersion {
    param($Node)
    $v = Invoke-NodeApi $Node 'Get' '/appliance/system/version'
    $Node.CurrentVersion = [string](Get-Prop $v 'version' '')
    $Node.CurrentBuild = [string](Get-Prop $v 'build' '')
    return $Node.CurrentVersion
}

function Test-NodeIso {
    # The upgrade ISO on one vCenter's CD-ROM, as the ESXi host and the appliance both see
    # it. Sets $Node.TargetVersion when the appliance sees a newer update; returns findings.
    param($Node, [bool]$DryRun)
    $out = [System.Collections.Generic.List[object]]::new()
    $Node.TargetVersion = $null
    $iso = Test-IsoDrive $Node.Vm 'Pre' $Node.Name $DryRun
    $Node.IsoPath = $iso.IsoPath
    foreach ($f in $iso.Findings) { $out.Add($f) }
    if (@($iso.Findings | Where-Object { $_.Severity -eq 'Error' }).Count) { return $out.ToArray() }
    if (-not $iso.Connected) {
        Write-Warn "$($Node.Name): ISO $($iso.IsoPath) -- not connected, so the appliance cannot be asked what it offers."
        return $out.ToArray()
    }
    Write-Note "$($Node.Name): ISO $($iso.IsoPath)"
    $update = Get-IsoUpdate $Node
    if ($null -eq $update) {
        $out.Add((New-Finding 'Pre' $Node.Name 'Error' 'Upgrade ISO' 'the appliance sees no update on the mounted ISO'))
        return $out.ToArray()
    }
    $offered = [string](Get-Prop $update 'version')
    if ((ConvertTo-VersionKey $offered) -le (ConvertTo-VersionKey $Node.CurrentVersion)) {
        $out.Add((New-Finding 'Pre' $Node.Name 'Error' 'Upgrade ISO' "the ISO offers $offered, which is not newer than the running $($Node.CurrentVersion)"))
        return $out.ToArray()
    }
    $Node.TargetVersion = $offered
    Set-NodeStage $Node 'IsoValid' "$($Node.CurrentVersion) -> $offered"
    Write-Good "$($Node.Name): $($Node.CurrentVersion) -> $offered ($(Get-Prop $update 'name' 'update on the ISO'))"
    return $out.ToArray()
}

function Invoke-NodePrecheck {
    # The installer's own precheck (and, with -Validate, validate) for one vCenter. Fills
    # $Node.UserData with the answers the installer asks for; returns findings.
    param($Node, [bool]$Validate)
    $out = [System.Collections.Generic.List[object]]::new()
    $Node.UserData = @{}
    if (-not $Node.TargetVersion) {
        $out.Add((New-Finding 'Pre' $Node.Name 'Warning' 'Installer precheck' 'not run: there is no update on the ISO to check against'))
        return $out.ToArray()
    }
    $ok = $true
    try {
        Write-Step "$($Node.Name): running the installer precheck ..."
        $precheck = Invoke-NodeApi $Node 'Post' "/appliance/update/pending/$($Node.TargetVersion)`?action=precheck" -TimeoutSec 600
        foreach ($f in (Get-NotificationFindings (Get-Prop $precheck 'issues') 'Pre' $Node.Name 'Installer precheck')) { $out.Add($f); if ($f.Severity -eq 'Error') { $ok = $false } }
        $estimate = Get-Prop $precheck 'estimated_time_to_install'
        if ($estimate) { Write-Note "$($Node.Name): installer estimate $estimate minute(s)" }
        foreach ($q in @(Get-Prop $precheck 'questions' @())) {
            $item = [string](Get-Prop $q 'data_item' '')
            if (-not $item) { continue }
            if ($item -match '(?i)vmdir\.password|sso.*password') { $Node.UserData[$item] = $Node.SsoCredential.GetNetworkCredential().Password; continue }
            $text = Get-MessageText (Get-Prop $q 'text')
            $a = Get-InstallerAnswer $item $text (Get-Prop $q 'default_answer') $InstallerAnswers
            Write-Note "$($Node.Name): the installer asks '$text' ($item) -- answered '$($a.Answer)' from $($a.Source)."
            $Node.UserData[$item] = $a.Answer
        }
    } catch {
        $out.Add((New-Finding 'Pre' $Node.Name 'Error' 'Installer precheck' $_.Exception.Message)); $ok = $false
    }
    if ($Validate -and $ok) {
        Write-Step "$($Node.Name): validating the update ..."
        try {
            $validation = Invoke-NodeApi $Node 'Post' "/appliance/update/pending/$($Node.TargetVersion)`?action=validate" @{ user_data = $Node.UserData } -TimeoutSec 600
            foreach ($f in (Get-NotificationFindings $validation 'Pre' $Node.Name 'Installer validation')) { $out.Add($f) }
        } catch { $out.Add((New-Finding 'Pre' $Node.Name 'Error' 'Installer validation' $_.Exception.Message)) }
    }
    return $out.ToArray()
}

function Wait-GroupReady {
    # Every vCenter up with every automatic service started (polled every
    # $ServicePollSeconds), then -- in ELM -- replication healthy from every one of them.
    # Throws when either is not so: nothing moves on until the whole group is sound.
    param($Nodes, [string]$Label, [string]$Phase)
    $list = @($Nodes)
    Wait-GroupServices $list $ServicePollSeconds $ServiceTimeoutMinutes $Label
    if ($list.Count -gt 1) {
        Write-Step "Checking replication from every vCenter in the group ($Label) ..."
        $repl = @(Get-GroupReplicationFindings $list $SsoCredential $Phase)
        foreach ($f in $repl) { $script:Findings.Add($f) }
        $bad = @($repl | Where-Object { $_.Severity -ne 'Info' })
        if ($bad.Count) { Write-Findings $bad "Replication $Label" }
        if (@($repl | Where-Object { $_.Severity -eq 'Error' }).Count) { throw "Replication is not healthy $Label." }
    }
    Write-Good "All $($list.Count) vCenter$(if ($list.Count -gt 1) { 's are' } else { ' is' }) up with every service started$(if ($list.Count -gt 1) { ' and replication healthy' }) ($Label)."
}

function Invoke-GroupSnapshot {
    # Every vCenter in the group shut down together, snapshotted while ALL of them are off --
    # one consistent rollback point for the SSO domain -- then powered on together, and only
    # returns once every one is back with every service started and replication healthy.
    param($Nodes, [string]$SnapName, [string]$Description)
    $list = @($Nodes)
    $many = ($list.Count -gt 1)
    foreach ($n in $list) { Close-NodeSsh $n; Reset-NodeApi $n }
    if ($many) { Write-Warn "All $($list.Count) vCenters are about to be shut down together: the SSO domain is unavailable until they are back." }
    foreach ($n in $list) {
        $v = Get-VM -Id $n.Vm.Id -Server $n.Esxi -ErrorAction Stop
        $n.Vm = $v
        if ([string]$v.PowerState -eq 'PoweredOff') { Write-Note "$($n.Name): $($v.Name) is already powered off."; continue }
        Write-Step "$($n.Name): requesting a graceful guest shutdown of $($v.Name) on $($n.EsxiHost) ..."
        Set-NodeStage $n 'ShuttingDown'
        Shutdown-VMGuest -VM $v -Confirm:$false -ErrorAction Stop | Out-Null
    }
    Wait-Pause $ShutdownPauseSeconds 'letting the appliances stop their services and shut down'

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $stillOn = @()
    while ($true) {
        $stillOn = @()
        foreach ($n in $list) {
            $v = Get-VM -Id $n.Vm.Id -Server $n.Esxi -ErrorAction Stop
            $n.Vm = $v
            if ([string]$v.PowerState -ne 'PoweredOff') { $stillOn += $n }
        }
        if ($stillOn.Count -eq 0) { break }
        if ($sw.Elapsed.TotalMinutes -ge $ShutdownTimeoutMinutes) { break }
        Write-Note ("[{0}] still powered on: {1} ({2})" -f (Get-Date).ToString('HH:mm:ss'), (($stillOn | ForEach-Object { $_.Vm.Name }) -join ', '), (Format-Elapsed $sw.Elapsed))
        Start-Sleep -Seconds 15
    }
    if ($stillOn.Count) {
        Write-Bad "Still not powered off after $ShutdownTimeoutMinutes minute(s): $(($stillOn | ForEach-Object { $_.Vm.Name }) -join ', ')"
        if (-not $AllowHardPowerOff) {
            throw "Stopped waiting for the shutdown. Still shutting down: $(($stillOn | ForEach-Object { $_.Vm.Name }) -join ', ') -- check their consoles. (-AllowHardPowerOff would have powered them off hard.)"
        }
        Write-Warn "-AllowHardPowerOff: powering off $(($stillOn | ForEach-Object { $_.Vm.Name }) -join ', ') hard."
        foreach ($n in $stillOn) { Stop-VM -VM $n.Vm -Confirm:$false -ErrorAction Stop | Out-Null }
        foreach ($n in $stillOn) {
            $v = Get-VM -Id $n.Vm.Id -Server $n.Esxi -ErrorAction Stop
            if ([string]$v.PowerState -ne 'PoweredOff') { throw "$($v.Name) did not power off." }
            $n.Vm = $v
        }
    }
    Write-Good "$(if ($many) { "All $($list.Count) vCenters are" } else { "$($list[0].Vm.Name) is" }) powered off."
    Wait-Pause 30 'letting the hosts release the VM files before the snapshots'

    foreach ($n in $list) {
        $v = $n.Vm
        Write-Step "Taking snapshot '$SnapName' of $($v.Name) ..."
        $null = New-Snapshot -VM $v -Name $SnapName -Description $Description -Memory:$false -Quiesce:$false -Confirm:$false -ErrorAction Stop
        $check = @(Get-Snapshot -VM $v -ErrorAction Stop | Where-Object { $_.Name -eq $SnapName })
        if ($check.Count -ne 1) { throw "The snapshot '$SnapName' was not found on $($v.Name) after it was taken." }
        $script:SnapshotsTaken.Add([pscustomobject]@{ Node = $n; VmName = $v.Name; EsxiHost = $n.EsxiHost; Name = $SnapName })
        Set-NodeStage $n 'Snapshotted' $SnapName
        Add-Finding 'Snapshot' $n.Name 'Info' 'Offline snapshot' "$SnapName ($($v.Name) on $($n.EsxiHost))" | Out-Null
    }
    Write-Good "Snapshot '$SnapName' taken of $(if ($many) { "all $($list.Count) vCenters while all were powered off" } else { $list[0].Vm.Name })."

    Write-Step "Powering $(if ($many) { "all $($list.Count) vCenters" } else { $list[0].Vm.Name }) back on ..."
    foreach ($n in $list) { Start-VM -VM $n.Vm -Confirm:$false -ErrorAction Stop | Out-Null; Set-NodeStage $n 'PoweringOn' }
    Wait-Pause $PowerOnPauseSeconds 'letting the appliances boot before checking their services'
    Wait-GroupReady $list 'after the snapshot' 'Snapshot'
}

function Invoke-NodeInstall {
    # ISO re-check after the power cycle, validate, stage-and-install, and progress every
    # $UpgradePollSeconds through the installer's service restarts. Leaves $Node.Stage at
    # 'Installed'. A vCenter already running its target version (a retry after the install
    # finished) skips straight to that.
    param($Node)
    Update-NodeVersion $Node | Out-Null
    if ($Node.TargetVersion -and $Node.CurrentVersion -eq $Node.TargetVersion) {
        Write-Note "$($Node.Name) already runs $($Node.TargetVersion) -- the install has been done; going on to the reboot."
        $Node.Stage = 'Installed'
        return
    }
    $Node.Vm = Get-VM -Id $Node.Vm.Id -Server $Node.Esxi -ErrorAction Stop
    $wanted = $Node.TargetVersion
    $isoFindings = @(Test-NodeIso $Node $false)
    if (@($isoFindings | Where-Object { $_.Severity -eq 'Error' }).Count -or $Node.TargetVersion -ne $wanted) {
        foreach ($f in $isoFindings) { $script:Findings.Add($f) }
        $Node.TargetVersion = $wanted
        throw "The appliance no longer sees $wanted on its ISO after the power cycle -- check the ISO is still connected."
    }
    $val = @(Invoke-NodePrecheck $Node $true)
    foreach ($f in $val) { $script:Findings.Add($f) }
    $valErrors = @($val | Where-Object { $_.Severity -eq 'Error' })
    if ($valErrors.Count) { Write-Findings $valErrors "$($Node.Name) precheck and validation"; throw 'The installer precheck or validation reported errors.' }

    $target = $Node.TargetVersion
    $Node.InstallMark = Get-Date
    Save-UpgradeState
    Write-Step "$($Node.Name): starting stage-and-install of $target ..."
    Set-NodeStage $Node 'Installing' "starting $target" 0
    Invoke-NodeApi $Node 'Post' "/appliance/update/pending/$target`?action=stage-and-install" @{ user_data = $Node.UserData } -TimeoutSec 300 | Out-Null

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $seenActivity = $false; $verdict = 'Waiting'; $lastLine = ''; $rollback = $false; $summary = $null; $nowVersion = ''
    while ($true) {
        Start-Sleep -Seconds $UpgradePollSeconds
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $elapsed = Format-Elapsed $sw.Elapsed
        try { $summary = Get-UpdateTaskSummary (Invoke-NodeApi $Node 'Get' '/appliance/update') }
        catch {
            Write-Note "[$stamp] $elapsed  appliance API not answering (expected while services restart or the appliance reboots)"
            Reset-NodeApi $Node
            if ($sw.Elapsed.TotalMinutes -ge $UpgradeTimeoutMinutes) { $verdict = 'TimedOut'; break }
            continue
        }
        try { $nowVersion = [string](Get-Prop (Invoke-NodeApi $Node 'Get' '/appliance/system/version') 'version' '') } catch { }
        if ($summary.State -match 'IN_PROGRESS$' -or $summary.TaskStatus -eq 'RUNNING') { $seenActivity = $true }
        $line = '{0,-22} {1,4}  {2}' -f $summary.State, $(if ($null -ne $summary.Percent) { "$($summary.Percent)%" } else { '' }), $summary.Message
        if ($line -ne $lastLine) { Write-Host "  [$stamp] $elapsed  $line" } else { Write-Note "[$stamp] $elapsed  (no change)" }
        Set-NodeStage $Node 'Installing' ("{0} {1}" -f $summary.State, $summary.Message).Trim() $summary.Percent
        $lastLine = $line
        $verdict = Get-UpgradeVerdict $summary $nowVersion $target $seenActivity
        if ($verdict -eq 'RollingBack') {
            if (-not $rollback) { Write-Bad 'The installer is rolling the update back.' }
            $rollback = $true
        }
        elseif ($rollback -and $verdict -ne 'Running') { $verdict = 'Failed'; break }
        if ($verdict -in @('Succeeded', 'Failed', 'EndedWrongVersion')) { break }
        if (-not $seenActivity -and $sw.Elapsed.TotalMinutes -ge 15) { $verdict = 'NeverStarted'; break }
        if ($sw.Elapsed.TotalMinutes -ge $UpgradeTimeoutMinutes) { $verdict = 'TimedOut'; break }
    }
    if ($verdict -ne 'Succeeded') {
        $why = switch ($verdict) {
            'Failed'            { "the install failed$(if ($summary -and $summary.Error) { ": $($summary.Error)" })" }
            'EndedWrongVersion' { "the install ended but the appliance reports version '$nowVersion', not $target" }
            'NeverStarted'      { 'the install did not start within 15 minutes' }
            default             { "the install did not finish within $UpgradeTimeoutMinutes minute(s)" }
        }
        try {
            $logs = Invoke-NodeShell $Node $script:UpgradeLogCommand 120
            $logFile = Join-Path $LogFolder "upgrade-errors-$(Get-ShortName $Node.Name)-$((Get-Date).ToString('yyyyMMdd-HHmmss')).txt"
            $logs.Output | Set-Content -LiteralPath $logFile -Encoding UTF8
            Write-Warn "Error lines from the installer logs (saved to $logFile):"
            $logs.Output | Select-Object -Last 40 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
        } catch { Write-Warn "Could not read the installer logs: $($_.Exception.Message)" }
        throw "Upgrade not completed: $why."
    }
    Write-Good "$($Node.Name): install complete, reports $target (after $(Format-Elapsed $sw.Elapsed))."
    Set-NodeStage $Node 'Installed' $target 100
    $Node.Stage = 'Installed'
}

function Wait-NodeApiSettled {
    # After an install the appliance API can answer 500 (badGateway) or drop connections for a
    # while as the services behind it restart. Polls the uptime every 15 seconds until it
    # answers, up to $MaxPolls (40 = 10 minutes); returns it. A real refusal (4xx) throws at once.
    param($Node, [int]$MaxPolls = 40, [string]$Why = 'after the install')
    for ($n = 1; $n -le $MaxPolls; $n++) {
        try { return [double](Invoke-NodeApi $Node 'Get' '/appliance/system/uptime' -TimeoutSec 30) }
        catch {
            if (-not (Test-TransientApiError $_.Exception.Message)) { throw }
            Write-Note ("[{0}] {1} API not answering yet ({2}) -- waiting for it to settle {3}" -f (Get-Date).ToString('HH:mm:ss'), $Node.Name, ($_.Exception.Message -split "`n")[0], $Why)
            Reset-NodeApi $Node
        }
        Start-Sleep -Seconds 15
    }
    throw "$($Node.Name)'s appliance API did not answer for $([int]($MaxPolls / 4)) minutes $Why."
}

function Invoke-NodeReboot {
    # Reboots the vCenter to complete its upgrade unless it already rebooted after the install
    # started. Waits for the API to settle first, so the decision rests on a real uptime and the
    # request does not land in the post-install service restart. A request that gets no clean
    # answer may still have started the reboot, so it is watched; one that was not acted on is
    # sent once more. Leaves $Node.Stage at 'Rebooted' once the vCenter has booted.
    param($Node)
    Set-NodeStage $Node 'Rebooting' 'waiting for the appliance to settle after the install'
    $upNow = Wait-NodeApiSettled $Node
    $booted = ($Node.InstallMark -and (Test-RebootObserved $upNow ((Get-Date) - [datetime]$Node.InstallMark).TotalSeconds))
    if ($booted) {
        Write-Note "$($Node.Name) already rebooted during the install."
        Set-NodeStage $Node 'Rebooted' 'during the install'
        $Node.Stage = 'Rebooted'
        return
    }
    $result = 'NotActedOn'
    for ($attempt = 1; $attempt -le 2 -and $result -ne 'Rebooted'; $attempt++) {
        if ($attempt -eq 2) {
            Write-Warn "$($Node.Name) is still up with its old uptime 5 minutes after the reboot request -- it was not acted on. Asking once more."
            $null = Wait-NodeApiSettled $Node -Why 'before the second reboot request'
        }
        $mark = Get-Date
        Write-Step "Rebooting $($Node.Name) to complete the upgrade$(if ($attempt -eq 2) { ' (second request)' }) ..."
        try {
            Invoke-NodeApi $Node 'Post' '/appliance/shutdown?action=reboot' @{ delay = 0; reason = "Completing upgrade to $($Node.TargetVersion)" } | Out-Null
        } catch {
            if (-not (Test-TransientApiError $_.Exception.Message)) { throw }
            Write-Note "The reboot request got no clean answer ($(($_.Exception.Message -split "`n")[0])) -- expected if $($Node.Name) went down at once. Watching for the reboot."
        }
        Close-NodeSsh $Node
        Reset-NodeApi $Node
        # Every 15 seconds: up to 20 polls (5 minutes) of the old uptime before the request is
        # taken as not acted on; up to 120 polls (30 minutes) in all for the reboot to show.
        $watch = @{ Quiet = 0; SawOutage = $false }
        $result = 'Watching'
        for ($p = 1; $p -le 120 -and $result -eq 'Watching'; $p++) {
            Start-Sleep -Seconds 15
            $u = $null
            try { $u = [double](Invoke-NodeApi $Node 'Get' '/appliance/system/uptime' -TimeoutSec 20) }
            catch {
                if (-not (Test-TransientApiError $_.Exception.Message)) { throw }
                Reset-NodeApi $Node
            }
            $result = Get-RebootWatchVerdict $watch $u ((Get-Date) - $mark).TotalSeconds 20
            if ($p % 4 -eq 0 -and $result -eq 'Watching') { Write-Note ("[{0}] {1}: {2}" -f (Get-Date).ToString('HH:mm:ss'), $Node.Name, $(if ($null -eq $u) { 'down (rebooting)' } else { 'still up, waiting for the reboot' })) }
        }
        if ($result -eq 'Watching') { throw "$($Node.Name) did not come back from the reboot within 30 minutes." }
    }
    if ($result -ne 'Rebooted') { throw "$($Node.Name) did not reboot after two reboot requests." }
    Write-Good "$($Node.Name) has rebooted."
    Set-NodeStage $Node 'Rebooted'
    $Node.Stage = 'Rebooted'
}

function Get-NodePostFindings {
    # Version, the same health checks as before the upgrade, and the installer log lines.
    param($Node)
    $out = [System.Collections.Generic.List[object]]::new()
    try {
        Update-NodeVersion $Node | Out-Null
        if ($Node.CurrentVersion -ne $Node.TargetVersion) { $out.Add((New-Finding 'Post' $Node.Name 'Error' 'Version' "running $($Node.CurrentVersion), expected $($Node.TargetVersion)")) }
        else { $out.Add((New-Finding 'Post' $Node.Name 'Info' 'Version' "$($Node.CurrentVersion) build $($Node.CurrentBuild)")) }
    } catch { $out.Add((New-Finding 'Post' $Node.Name 'Error' 'Version' "could not read: $($_.Exception.Message)")) }
    # The services were read moments ago, when the group was confirmed ready.
    foreach ($f in (Get-NodeHealthFindings $Node 'Post' (Get-Date) $Node.LastReady)) { $out.Add($f) }
    try {
        $logs = Invoke-NodeShell $Node $script:UpgradeLogCommand 120
        $logFile = Join-Path $LogFolder "upgrade-log-lines-$(Get-ShortName $Node.Name)-$((Get-Date).ToString('yyyyMMdd-HHmmss')).txt"
        $logs.Output | Set-Content -LiteralPath $logFile -Encoding UTF8
        $count = @($logs.Output | Where-Object { $_ -notmatch '^== ' }).Count
        if ($count) { $out.Add((New-Finding 'Post' $Node.Name 'Info' 'Installer log' "$count error/fail line(s) for review in $logFile")) }
    } catch { }
    return $out.ToArray()
}

# ========================================================== ISO on the datastore ==

function Test-IsoOnHost {
    # The ISO as one ESXi host sees it: the datastore mounted on the host, and the file on it.
    # Returns a finding when either is not so, otherwise $null.
    param($Server, [string]$HostName, $Iso, [int]$Index)
    $ds = $null
    try { $ds = Get-Datastore -Server $Server -Name $Iso.Datastore -ErrorAction Stop }
    catch { return (New-Finding 'Pre' $HostName 'Error' 'Upgrade ISO' "the host does not see datastore '$($Iso.Datastore)' -- the ISO must be on a datastore every ESXi host in the CSV can reach") }
    $drive = "vvfiso$Index"
    $found = $false
    try {
        New-PSDrive -Name $drive -PSProvider VimDatastore -Root '\' -Location $ds -ErrorAction Stop | Out-Null
        $found = [bool](Test-Path -LiteralPath ("${drive}:\" + ($Iso.Path -replace '/', '\')))
    } catch {
        return (New-Finding 'Pre' $HostName 'Warning' 'Upgrade ISO' "could not browse datastore '$($Iso.Datastore)' to confirm the ISO is there: $($_.Exception.Message)")
    } finally { try { Remove-PSDrive -Name $drive -Force -ErrorAction SilentlyContinue } catch { } }
    if (-not $found) { return (New-Finding 'Pre' $HostName 'Error' 'Upgrade ISO' "$($Iso.Path) is not on datastore '$($Iso.Datastore)' as this host sees it -- check the path and that the upload finished") }
    return $null
}

function Get-VmQuestionObject {
    # The question the VM is waiting on, or $null. While one is pending, CD-ROM changes wait on it.
    param($Vm)
    try {
        $q = @(Get-VMQuestion -VM $Vm -ErrorAction Stop)
        if ($q.Count) { return $q[0] }
    } catch { }
    return $null
}

function Get-VmQuestionText {
    # A question the VM is waiting on (e.g. "The guest operating system has locked the CD-ROM
    # door"), or '' when none.
    param($Vm)
    $q = Get-VmQuestionObject $Vm
    if ($null -eq $q) { return '' }
    return (([string](Get-Prop $q 'Text' 'a question')) -replace '\s+', ' ').Trim()
}

function Test-CdromLockQuestion {
    # Whether a VM question is the CD-ROM lock one ESXi asks on a disconnect: "The guest operating
    # system has locked the CD-ROM door and is probably using the CD-ROM ... Disconnect anyway and
    # override the lock?" (msg.cdromdisconnect.locked). The only question this script answers.
    param([string]$Text)
    return ([string]$Text -match '(?i)locked the CD-ROM door|cdromdisconnect\.locked')
}

function Select-QuestionYesOption {
    # The "Yes" choice of a VM question (label button.yes, or summary Yes), or $null.
    param($Question)
    foreach ($o in @(Get-Prop $Question 'Options' @())) {
        if ([string](Get-Prop $o 'Label' '') -match '(?i)^button\.yes$' -or [string](Get-Prop $o 'Summary' '') -match '(?i)^yes$') { return $o }
    }
    return $null
}

function Confirm-CdromLockQuestion {
    # Answers the CD-ROM lock question Yes ("disconnect anyway"). Only called once the appliance
    # has released the ISO, so nothing inside it is using the drive. Returns '' or why not.
    param($Question, [string]$VmName)
    $yes = Select-QuestionYesOption $Question
    if ($null -eq $yes) { return "$VmName is waiting on the CD-ROM lock question, which offers no Yes to answer -- answer it in the host client" }
    # By its label (button.yes), the form Set-VMQuestion documents; the summary if there is none.
    $choice = $(if ([string](Get-Prop $yes 'Label' '')) { [string]$yes.Label } else { [string](Get-Prop $yes 'Summary' 'Yes') })
    try { $null = Set-VMQuestion -VMQuestion $Question -Option $choice -Confirm:$false -ErrorAction Stop }
    catch { return "could not answer the CD-ROM lock question on ${VmName}: $($_.Exception.Message) -- answer it in the host client" }
    return ''
}

function New-CdDisconnectSpec {
    # A reconfigure that leaves the CD-ROM device as it is but disconnected, now and at power on.
    param($Device)
    $Device.Connectable.Connected = $false
    $Device.Connectable.StartConnected = $false
    if ('VMware.Vim.VirtualMachineConfigSpec' -as [type]) {
        $change = New-Object VMware.Vim.VirtualDeviceConfigSpec
        $change.Operation = [VMware.Vim.VirtualDeviceConfigSpecOperation]::edit
        $change.Device = $Device
        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $spec.DeviceChange = [VMware.Vim.VirtualDeviceConfigSpec[]]@($change)
        return $spec
    }
    return [pscustomobject]@{ DeviceChange = @([pscustomobject]@{ Operation = 'edit'; Device = $Device }) }
}

function Wait-CdDisconnect {
    # Disconnects the VM's CD-ROM as a vSphere task and watches it, instead of a call that blocks
    # until someone answers the VM's question. The CD-ROM lock question is answered Yes; any
    # other question is reported and left. Returns '' when disconnected, or why not.
    param($Node, $Vm, $Drive, [int]$TimeoutSec = 180, [int]$PollSec = 3)
    $dev = Get-Prop $Drive 'ExtensionData'
    if ($null -eq $dev) { return 'the CD-ROM device could not be read from the ESXi host' }
    try {
        $view = Get-View -Id $Vm.Id -Server $Node.Esxi -ErrorAction Stop
        $task = $view.ReconfigVM_Task((New-CdDisconnectSpec $dev))
    } catch { return "the ESXi host did not start the disconnect: $($_.Exception.Message)" }
    $answered = $false
    $polls = [math]::Max(1, [math]::Ceiling($TimeoutSec / [math]::Max(1, $PollSec)))
    for ($k = 1; ; $k++) {
        $state = ''; $err = ''
        try {
            $t = Get-View -Id $task -Server $Node.Esxi -ErrorAction Stop
            $state = [string](Get-PropPath $t 'Info.State' '')
            $err = [string](Get-PropPath $t 'Info.Error.LocalizedMessage' '')
        } catch { $state = 'unknown' }
        if ($state -eq 'success') { return '' }
        if ($state -eq 'error') { return "the ESXi host did not disconnect it: $(if ($err) { $err } else { 'the task failed' })" }
        $q = Get-VmQuestionObject $Vm
        if ($q) {
            $text = (([string](Get-Prop $q 'Text' '')) -replace '\s+', ' ').Trim()
            if (-not (Test-CdromLockQuestion $text)) { return "$($Vm.Name) is waiting on a question on its ESXi host ('$text') -- answer it in the host client, then disconnect the CD-ROM" }
            if (-not $answered) {
                $why = Confirm-CdromLockQuestion $q $Vm.Name
                if ($why) { return $why }
                $answered = $true
                Write-Note "$($Node.Name): answered the CD-ROM lock question on $($Vm.Name) -- Yes, disconnect anyway (the appliance had already released the ISO)."
            }
        }
        if ($k -ge $polls) { return "the disconnect had not finished after ${TimeoutSec}s$(if ($q) { " -- the VM is waiting on: '$text'" })" }
        Start-Sleep -Seconds $PollSec
    }
}

function Invoke-GuestIsoRelease {
    # Unmounts the CD-ROM inside the appliance. Returns $null when nothing holds it any more, or
    # the reason it is still held (with the processes using it).
    param($Node)
    $r = Invoke-NodeShell $Node (Get-GuestUnmountCommand) 120
    $g = ConvertFrom-GuestUnmountOutput $r.Output
    foreach ($m in $g.Unmounted) { Write-Note "$($Node.Name): unmounted the ISO inside the appliance ($m)." }
    foreach ($m in $g.Ejected) { Write-Note "$($Node.Name): ejected $m inside the appliance (unlocks the CD-ROM door)." }
    if ($g.Busy.Count) {
        $b = $g.Busy[0]
        $who = $(if ($b.Users.Count) { ($b.Users | Select-Object -First 5) -join '; ' } else { 'no process listed (fuser/lsof gave nothing)' })
        return "the appliance still has the ISO mounted at $($b.Mount) and cannot unmount it -- in use by: $who"
    }
    if (-not $g.Complete) { return 'the unmount command inside the appliance did not finish' }
    return $null
}

function Mount-NodeIso {
    # Mounts the ISO from the datastore on the vCenter VM's CD-ROM: connected, and connected at
    # power on so it survives the snapshot power cycles. Returns findings; an Error means it is
    # not mounted.
    param($Node, $Iso)
    $out = [System.Collections.Generic.List[object]]::new()
    $vm = Get-VM -Id $Node.Vm.Id -Server $Node.Esxi -ErrorAction Stop
    $Node.Vm = $vm
    $drives = @(Get-CDDrive -VM $vm -ErrorAction Stop)
    if ($drives.Count -eq 0) {
        $out.Add((New-Finding 'Pre' $Node.Name 'Error' 'Upgrade ISO' "$($vm.Name) has no CD-ROM drive -- add one (the VM has to be powered off for that)"))
        return $out.ToArray()
    }
    $d = $drives[0]
    $cur = ([string](Get-Prop $d 'IsoPath' '')).Trim()
    $connected = [bool](Get-PropPath $d 'ConnectionState.Connected' $false)
    if ($cur -ieq $Iso.Full -and $connected) {
        Write-Note "$($Node.Name): the ISO is already mounted on $($vm.Name)."
        if (-not [bool](Get-PropPath $d 'ConnectionState.StartConnected' $false)) { $null = Set-CDDrive -CD $d -StartConnected:$true -Confirm:$false -ErrorAction Stop }
        return $out.ToArray()
    }
    if ($cur -and $connected) {
        Write-Warn "$($Node.Name): $($vm.Name) has another ISO on its CD-ROM ($cur) -- replacing it."
        $why = Invoke-GuestIsoRelease $Node
        if ($why) { $out.Add((New-Finding 'Pre' $Node.Name 'Error' 'Upgrade ISO' "cannot replace $cur`: $why")); return $out.ToArray() }
    }
    $q = Get-VmQuestionText $vm
    if ($q) { $out.Add((New-Finding 'Pre' $Node.Name 'Error' 'Upgrade ISO' "$($vm.Name) is waiting on a question on its ESXi host ('$q') -- answer it in the host client first")); return $out.ToArray() }
    try { $d = Set-CDDrive -CD $d -IsoPath $Iso.Full -StartConnected:$true -Connected:$true -Confirm:$false -ErrorAction Stop }
    catch { $out.Add((New-Finding 'Pre' $Node.Name 'Error' 'Upgrade ISO' "could not mount $($Iso.Full) on $($vm.Name): $($_.Exception.Message)")); return $out.ToArray() }
    $now = ([string](Get-Prop $d 'IsoPath' '')).Trim()
    if ($now -ine $Iso.Full -or -not [bool](Get-PropPath $d 'ConnectionState.Connected' $false)) {
        $out.Add((New-Finding 'Pre' $Node.Name 'Error' 'Upgrade ISO' "after mounting, the CD-ROM of $($vm.Name) shows '$now' $(if (-not [bool](Get-PropPath $d 'ConnectionState.Connected' $false)) { '(not connected)' })"))
        return $out.ToArray()
    }
    Write-Good "$($Node.Name): ISO mounted on $($vm.Name)."
    Set-NodeStage $Node 'IsoMounted' $Iso.Full
    return $out.ToArray()
}

function Dismount-NodeIso {
    # Takes the ISO off the vCenter VM's CD-ROM. Releases it inside the appliance first -- a CD-ROM
    # the guest still has mounted is locked, and ejecting it would leave the VM waiting on a
    # question. Never throws: returns the result and, when it could not, why.
    param($Node)
    $res = [pscustomobject]@{ Node = $Node.Name; Result = 'Failed'; Reason = '' }
    $vm = $null
    try { $vm = Get-VM -Id $Node.Vm.Id -Server $Node.Esxi -ErrorAction Stop }
    catch { $res.Reason = "cannot read the VM from ESXi host $($Node.EsxiHost): $($_.Exception.Message)"; return $res }
    $d = Get-IsoDrive $vm
    if ($null -eq $d) { $res.Result = 'NotMounted'; return $res }
    # A question already pending: the CD-ROM lock one (an earlier disconnect left waiting) is
    # answered once the appliance has released the ISO; any other is for a person.
    $pending = Get-VmQuestionObject $vm
    $q = $(if ($pending) { (([string](Get-Prop $pending 'Text' 'a question')) -replace '\s+', ' ').Trim() } else { '' })
    if ($q -and -not (Test-CdromLockQuestion $q)) { $res.Reason = "$($vm.Name) is waiting on a question on its ESXi host ('$q') -- answer it in the host client, then disconnect the CD-ROM"; return $res }
    if ($Node.SshOff) {
        $res.Reason = 'SSH to the appliance is off, so the ISO could not be released inside it first; not ejected (it could hang on the CD-ROM lock question)'
        return $res
    }
    $why = $null
    try { $why = Invoke-GuestIsoRelease $Node }
    catch { $why = "could not reach the appliance over SSH to release the ISO first ($($_.Exception.Message)); not ejected, as a CD-ROM the guest still has mounted is locked" }
    if ($why) { $res.Reason = $why; return $res }
    if ($pending) {
        $why = Confirm-CdromLockQuestion $pending $vm.Name
        if ($why) { $res.Reason = $why; return $res }
        Write-Note "$($Node.Name): answered the CD-ROM lock question already pending on $($vm.Name) -- Yes, disconnect anyway (the appliance had released the ISO)."
    }
    # Disconnected first, watched as a task (the lock question is answered if it comes), then
    # the ISO taken off -- which no longer asks anything once the drive is disconnected.
    try { $d = Get-IsoDrive (Get-VM -Id $Node.Vm.Id -Server $Node.Esxi -ErrorAction Stop) } catch { }
    if ($d -and [bool](Get-PropPath $d 'ConnectionState.Connected' $false)) {
        $why = Wait-CdDisconnect $Node $vm $d
        if ($why) { $res.Reason = $why; return $res }
    }
    if ($d) {
        try { $null = Set-CDDrive -CD $d -NoMedia -StartConnected:$false -Confirm:$false -ErrorAction Stop }
        catch {
            $q = Get-VmQuestionText $vm
            $res.Reason = "the ESXi host did not eject it: $($_.Exception.Message)$(if ($q) { " -- the VM is waiting on: '$q'" })"
            return $res
        }
    }
    try {
        $after = Get-IsoDrive (Get-VM -Id $Node.Vm.Id -Server $Node.Esxi -ErrorAction Stop)
        if ($after) { $res.Reason = "the CD-ROM still shows $($after.IsoPath) after the eject"; return $res }
    } catch { $res.Reason = "ejected, but the result could not be read back: $($_.Exception.Message)"; return $res }
    $res.Result = 'Dismounted'
    return $res
}

function Write-GroupPowerState {
    # After a failure: which appliance VMs are off, so nobody has to go and look.
    param($Nodes)
    foreach ($n in @($Nodes)) {
        if (-not $n.Vm) { continue }
        try {
            $v = Get-VM -Id $n.Vm.Id -Server $n.Esxi -ErrorAction Stop
            $line = "    $($n.Name): VM $($v.Name) is $($v.PowerState)"
            if ([string]$v.PowerState -eq 'PoweredOn') { Write-Note $line } else { Write-Bad $line }
        } catch { Write-Warn "    $($n.Name): power state unreadable -- $($_.Exception.Message)" }
    }
}

# ======================================================================== main body ==
# Everything above is functions. Everything
# below talks to the ESXi hosts and the appliances. Nothing is asked: every input is a
# parameter, a secret or an environment variable. Nothing changes state before the start is
# confirmed (-ConfirmVCenter), apart from turning SSH on and mounting the ISO -- and with
# -DryRun, nothing but SSH, which the dry run turns off again at its end.

$runStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not (Test-Path -LiteralPath $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }
$transcript = Join-Path $LogFolder "vcenter-upgrade-$runStamp.log"
$transcriptOn = $false
try { Start-Transcript -Path $transcript -Force | Out-Null; $transcriptOn = $true } catch { }

Write-Host ''
Write-Host "Invoke-VvfVCenterUpgrade.ps1  v$ScriptVersion$(if ($DryRun) { '  (DRY RUN -- nothing is changed apart from SSH, which is turned back off at the end)' })" -ForegroundColor White
Write-Host "  Log folder: $LogFolder"
Write-Host ''

$exitCode = 1
$script:StopFile = Join-Path $LogFolder 'STOP'
if (Test-Path -LiteralPath $script:StopFile) {
    try { Remove-Item -LiteralPath $script:StopFile -Force -ErrorAction Stop; Write-Note "A STOP file left from an earlier run was removed: $($script:StopFile)" } catch { }
}
$stopped = $false
$confirmed = $false          # the start was confirmed: from here on vCenters are shut down
$completed = $false          # every vCenter upgraded, the ISO unmounted and SSH turned off
$script:Esxi = $null
$primary = $null
$VCenter = $null
$groupNodes = @()
$script:StatePath = $null
$script:Iso = $null
$script:SnapshotsTaken = [System.Collections.Generic.List[object]]::new()
$script:EsxiServers = [ordered]@{}
$script:SshClientInUse = ''
$script:PlinkExe = ''
$script:PlinkPasswordFiles = [System.Collections.Generic.List[string]]::new()
$carrySsh = @{}              # vCenters an abandoned run (-StartFresh) had turned SSH on for
$moveStateAside = $false
$vm = $null
$findingsCsv = $null

try {
    # --- 1. the vCenter list, and whether this run may go ahead -----------------------
    # Everything that can refuse the run is checked here, before anything is connected to.
    Write-Phase '1. vCenters, and whether this run may go ahead'
    if ($Resume -and $StartFresh) { throw 'Give -Resume (carry on) or -StartFresh (start again), not both.' }
    if (-not [string]::IsNullOrWhiteSpace($VCenterCsvText) -and -not [string]::IsNullOrWhiteSpace($VCenterCsv)) { throw 'Give -VCenterCsv (a file) or -VCenterCsvText (its contents), not both.' }
    if (-not [string]::IsNullOrWhiteSpace($VCenterCsvText)) { $csvText = $VCenterCsvText; $csvLabel = '-VCenterCsvText' }
    elseif (-not [string]::IsNullOrWhiteSpace($VCenterCsv)) {
        if (-not (Test-Path -LiteralPath $VCenterCsv -PathType Leaf)) { throw "There is no CSV at '$VCenterCsv' (as the account running this script sees it). It needs the columns VCenter,EsxiHost (and optionally VmName), one row per vCenter in the order to upgrade them -- see Get-Help -Parameter VCenterCsv for a template." }
        $csvText = [string](Get-Content -LiteralPath $VCenterCsv -Raw)
        $csvLabel = $VCenterCsv
    } else { throw 'No vCenter list: pass -VCenterCsv (a file) or -VCenterCsvText (its contents) -- columns VCenter,EsxiHost[,VmName], one row per vCenter, in upgrade order.' }
    try { $rows = @(ConvertFrom-VCenterCsv (([string]$csvText) -split "`r?`n")) }
    catch { throw "$csvLabel`: $($_.Exception.Message)" }
    $csvSha = Get-TextSha256 $csvText
    $VCenter = $rows[0].VCenter
    $short = Get-ShortName $VCenter
    $k = 0
    foreach ($r in $rows) { $k++; Write-Note ("{0}. {1}  on ESXi host {2}{3}" -f $k, $r.VCenter, $r.EsxiHost, $(if ($r.VmName) { "  (VM $($r.VmName))" })) }
    $esxiHosts = @($rows | ForEach-Object { $_.EsxiHost } | Select-Object -Unique)

    # A previous run that stopped part way left a state file: -Resume carries on from it,
    # -StartFresh moves it aside. With neither, a real run stops rather than guess.
    $script:StatePath = Join-Path $LogFolder "upgrade-state-$short.json"
    $state = $null
    if (Test-Path -LiteralPath $script:StatePath) {
        $stateError = ''
        try { $state = ConvertFrom-UpgradeStateJson (Get-Content -LiteralPath $script:StatePath -Raw) } catch { $stateError = $_.Exception.Message }
        if ($state -and $state.Primary -ne $VCenter) { $stateError = "it is for $($state.Primary), not $VCenter"; $state = $null }
        $unfinished = @($(if ($state) { $state.Nodes | Where-Object { $_.Stage -ne 'Done' } }))
        if ($StartFresh) {
            if ($DryRun) { Write-Note "-StartFresh: the dry run ignores the state file $($script:StatePath) (a real run with -StartFresh moves it aside)." }
            else {
                # Moved aside once the run is allowed to go ahead (below), not before: a run
                # refused here must leave the file -- and where it says SSH was turned on -- as is.
                if ($state) { foreach ($sn in $state.Nodes) { if ($sn.SshEnabledByRun) { $carrySsh[$sn.Name] = $true } } }
                $moveStateAside = $true
            }
            $state = $null
        }
        elseif ($stateError) { throw "The state file $($script:StatePath) cannot be used ($stateError). Run with -StartFresh to move it aside and start from the beginning." }
        elseif ($unfinished.Count -and -not $Resume) {
            $why = "A previous run stopped at $($unfinished[0].Name) ($($unfinished[0].Stage)$(if ($unfinished[0].LastError) { ": $($unfinished[0].LastError)" }))"
            if (-not $DryRun) { throw "$why. Run again with -Resume to carry on from there, or with -StartFresh to start from the beginning. Nothing has been changed." }
            Write-Warn "$why. This dry run checks from the beginning (add -Resume to check the resume)."
        }
        if ($state -and $Resume) {
            $was = @($state.Nodes | ForEach-Object { $_.Name }) -join ','
            $now = @($rows | ForEach-Object { $_.VCenter }) -join ','
            if ($was -ne $now) { throw "The CSV lists $now, but the stopped run was for $was. Use the same CSV to resume, or -StartFresh to start from the beginning." }
            Write-Note "Resuming: $((@($state.Nodes) | ForEach-Object { "$($_.Name)=$($_.Stage)" }) -join ', ')"
        } else { $state = $null }
    } elseif ($Resume) {
        throw "-Resume: there is no state file for $VCenter in $LogFolder (use the same -LogFolder as the run that stopped)."
    }

    if ([string]::IsNullOrWhiteSpace($IsoPath) -and $state -and $state.IsoPath) { $IsoPath = $state.IsoPath; Write-Note "ISO: the stopped run's, $IsoPath" }
    if ([string]::IsNullOrWhiteSpace($IsoPath)) { throw 'No ISO: pass -IsoPath, the datastore path of the patch ISO, e.g. [SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso' }
    try { $script:Iso = ConvertFrom-DatastorePath $IsoPath } catch { throw $_.Exception.Message }

    if (-not $DryRun) {
        # The two things a person did in the old window before a real run: typed the first
        # vCenter's name, and ran a dry run of this CSV and ISO that passed.
        if (-not (Test-TypedConfirmation $ConfirmVCenter $short)) {
            throw "A real run needs -ConfirmVCenter $short (the short name of the first vCenter in the CSV)$(if ($ConfirmVCenter) { " -- '$ConfirmVCenter' was given" }). Nothing has been changed."
        }
        if (-not $Resume) {
            $record = Join-Path $LogFolder "dryrun-$short.json"
            $json = $(if (Test-Path -LiteralPath $record) { Get-Content -LiteralPath $record -Raw } else { '' })
            $verdict = Test-DryRunRecord -Json $json -CsvSha256 $csvSha -IsoPath $script:Iso.Full -Now (Get-Date)
            if ($verdict.Valid) { Write-Good "A dry run of this CSV and ISO passed at $($verdict.Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm')): the real run may go ahead." }
            elseif ($SkipDryRunCheck) { Write-Warn "-SkipDryRunCheck: going ahead WITHOUT a matching passing dry run ($($verdict.Reason))." }
            else { throw "The real run is locked: $($verdict.Reason). Run with -DryRun first (same CSV, same -IsoPath, same -LogFolder $LogFolder), then again without it. Nothing has been changed." }
        }
        if ($moveStateAside) {
            $aside = "$($script:StatePath).abandoned-$runStamp"
            Move-Item -LiteralPath $script:StatePath -Destination $aside -Force
            Write-Warn "-StartFresh: the previous run's state file was moved aside to $aside; this run starts from the beginning."
        }
    }

    if (-not (Get-Command Connect-VIServer -ErrorAction SilentlyContinue)) {
        try { Import-Module VMware.VimAutomation.Core -ErrorAction Stop | Out-Null }
        catch { throw 'VMware.VimAutomation.Core is not installed for the account running this script. Install-Module VMware.PowerCLI -Scope AllUsers (or as that account).' }
    }
    $ssh = Resolve-SshClient $SshClient $PlinkPath
    $script:SshClientInUse = $ssh.Client
    $script:PlinkExe = $ssh.PlinkExe
    Write-Note "SSH client: $($ssh.Note)"

    Initialize-Tls ([bool]$StrictCertificates)
    if (-not $StrictCertificates) {
        try { Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null } catch { }
    }

    # --- 2. credentials and connections --------------------------------------------
    # Every credential is found before anything is connected to, so a missing one changes
    # nothing. Most specific first: per host / per vCenter, then the parameter, then shared.
    Write-Phase '2. Credentials and connections'
    $c = Resolve-VvfCredential (Get-CredentialNames 'Sso') $SsoCredential 'SsoCredential'
    $SsoCredential = $c.Credential
    Write-Note "SSO administrator: $($SsoCredential.UserName) (from $($c.Source))"
    $esxiCred = @{}
    foreach ($h in $esxiHosts) {
        $c = Resolve-VvfCredential (Get-CredentialNames 'Esxi' $h) $EsxiCredential 'EsxiCredential'
        $esxiCred[$h.ToLowerInvariant()] = $c.Credential
        Write-Note "ESXi host $h`: $($c.Credential.UserName) (from $($c.Source))"
    }
    $vcCred = @{}
    foreach ($r in $rows) {
        $c = Resolve-VvfCredential (Get-CredentialNames 'VCenter' $r.VCenter) $VCenterRootCredential 'VCenterRootCredential'
        $vcCred[$r.VCenter] = $c.Credential
        Write-Note "vCenter $($r.VCenter): $($c.Credential.UserName) (from $($c.Source))"
    }

    $pre = @()
    foreach ($h in $esxiHosts) {
        $cred = $esxiCred[$h.ToLowerInvariant()]
        Write-Step "Connecting to ESXi host $h ..."
        try {
            $srv = Connect-VIServer -Server $h -Credential $cred -ErrorAction Stop
            $script:EsxiServers[$h.ToLowerInvariant()] = $srv
            if (-not $script:Esxi) { $script:Esxi = $srv }
            Write-Note "$h -- ESXi $(Get-Prop $srv 'Version' '?') build $(Get-Prop $srv 'Build' '?')"
        } catch {
            throw "Cannot log in to ESXi host $h as $($cred.UserName): $($_.Exception.Message). A host in lockdown mode refuses direct root logins."
        }
    }

    $groupNodes = @()
    foreach ($r in $rows) {
        $node = New-Node $r.VCenter $vcCred[$r.VCenter] $SsoCredential
        $node.EsxiHost = $r.EsxiHost
        $node.Esxi = $script:EsxiServers[$r.EsxiHost.ToLowerInvariant()]
        if ($carrySsh.ContainsKey($node.Name)) { $node.SshEnabledByScript = $true }
        $groupNodes += $node
        try {
            $vmFound = Find-ApplianceVm $node.Esxi $r.VCenter $r.VmName
            $node.Vm = $vmFound
            Write-Note "$($r.VCenter): VM $($vmFound.Name) on $($r.EsxiHost)  [$($vmFound.PowerState)]"
            if ([string]$vmFound.PowerState -ne 'PoweredOn') { $pre += @(New-Finding 'Pre' $r.VCenter 'Error' 'Appliance VM' "VM $($vmFound.Name) is $($vmFound.PowerState); it must be running") }
            $ts = [string](Get-PropPath $vmFound 'ExtensionData.Guest.ToolsRunningStatus' '')
            if ($ts -and $ts -ne 'guestToolsRunning') { $pre += @(New-Finding 'Pre' $r.VCenter 'Error' 'Appliance VM' "VMware Tools is not running in $($vmFound.Name) ($ts); a graceful shutdown needs it") }
        } catch {
            $pre += @(New-Finding 'Pre' $r.VCenter 'Error' 'Appliance VM' "cannot find its appliance VM on $($r.EsxiHost): $($_.Exception.Message)")
            continue
        }
        try {
            Write-Step "Opening an appliance API session on $($r.VCenter) ..."
            Connect-NodeApi $node
            if ($node.ApiLabel -match 'NOT authorized') { Write-Warn "$($r.VCenter) appliance API: $($node.ApiLabel) -- expect the API checks to fail." }
            else { Write-Note "$($r.VCenter) appliance API: logged in as $($node.ApiLabel)" }
            Update-NodeVersion $node | Out-Null
            $node.FromVersion = $node.CurrentVersion
            Write-Note "$($r.VCenter) runs vCenter Server $($node.CurrentVersion) build $($node.CurrentBuild)"
            $wasOff = ($null -ne $node.SshWasOn -and -not $node.SshWasOn)
            Enable-NodeSsh $node ([bool]$DryRun)
            if (-not $node.SshOff) {
                # sshd needs a few seconds after it is turned on.
                Wait-NodeSshReady $node $(if ($node.SshEnabledByScript -or $wasOff) { 6 } else { 1 })
                Write-Note "$($r.VCenter) SSH ready (root shell: $(switch ($node.ShellMode) { 'Exec' { 'bash' } 'Plink' { 'bash, through plink' } default { 'appliance shell, switched to bash' } }))"
            }
        } catch {
            $pre += @(New-Finding 'Pre' $r.VCenter 'Error' 'vCenter access' $_.Exception.Message)
        }
    }
    $primary = $groupNodes[0]
    $many = ($groupNodes.Count -gt 1)
    $sshOnNow = @($groupNodes | Where-Object { $_.SshEnabledByScript } | ForEach-Object { $_.Name })
    if ($sshOnNow.Count) { Write-Note "SSH turned on by this run on: $($sshOnNow -join ', ') -- turned off again $(if ($DryRun) { 'at the end of the dry run' } else { 'once every vCenter is upgraded' })." }

    $stateOf = @{}
    if ($state) { foreach ($sn in $state.Nodes) { $stateOf[$sn.Name] = $sn } }

    # --- 3. the CSV against the SSO domain -----------------------------------------
    # Every vCenter in the SSO domain has to be in the CSV: each round snapshots all of them
    # together, and a member left out would make that snapshot set no rollback point.
    Write-Phase '3. Enhanced Linked Mode'
    if ($primary.SshOff -or -not $primary.Token) {
        $pre += @(New-Finding 'Pre' $VCenter 'Warning' 'ELM group' "not checked against the SSO domain: $(if ($primary.SshOff) { 'SSH is off' } else { 'no access to the appliance' })")
    } else { try {
        $r = Invoke-NodeShell $primary (Get-VdcrepadminCommand 'showservers' $SsoCredential) 120
        if ($r.ExitStatus -ne 0) { throw ((@($r.Output) -join ' ').Trim()) }
        $servers = @(ConvertFrom-VmdirServerList $r.Output)
        $cmp = Compare-VCenterSets @($groupNodes | ForEach-Object { $_.Name }) $servers
        foreach ($m in $cmp.MissingFromCsv) { $pre += @(New-Finding 'Pre' $m 'Error' 'ELM group' "is in the SSO domain but not in the CSV -- every member must be listed, so all are snapshotted together") }
        foreach ($x in $cmp.NotInDomain) { $pre += @(New-Finding 'Pre' $x 'Error' 'ELM group' "is in the CSV but not in the SSO domain of $VCenter") }
        if (-not $cmp.MissingFromCsv.Count -and -not $cmp.NotInDomain.Count) {
            if ($servers.Count -gt 1) { Write-Good "The CSV matches the SSO domain: $($servers.Count) vCenters in Enhanced Linked Mode." }
            else { Write-Note 'Not in Enhanced Linked Mode (one vCenter in the SSO domain).' }
        }
    } catch {
        $pre += @(New-Finding 'Pre' $VCenter 'Error' 'ELM group' "vdcrepadmin showservers failed (check the SSO credentials): $($_.Exception.Message)")
    } }

    # Stages from the state file. A vCenter recorded Done must still run the version it was
    # upgraded to; one that does not is upgraded again rather than trusted. Where the stopped
    # run turned SSH on, this run counts it as its own, so it is turned off at the end.
    foreach ($n in $groupNodes) {
        if (-not $stateOf.ContainsKey($n.Name)) { continue }
        $sn = $stateOf[$n.Name]
        if ($sn.SshEnabledByRun) { $n.SshEnabledByScript = $true }
        $n.Stage = $sn.Stage; $n.TargetVersion = $sn.TargetVersion; $n.InstallMark = $sn.InstallMark; $n.LastError = $sn.LastError
        if ($n.Stage -ne 'Pending' -and $n.CurrentVersion -and $sn.TargetVersion -and $n.CurrentVersion -ne $sn.TargetVersion) {
            Write-Warn "$($n.Name) was recorded $($n.Stage) at $($sn.TargetVersion) but runs $($n.CurrentVersion) -- it will be upgraded again."
            $n.Stage = 'Pending'; $n.TargetVersion = $null; $n.InstallMark = $null
        }
    }
    $todo = @($groupNodes | Where-Object { $_.Stage -ne 'Done' })
    if ($todo.Count -eq 0) { throw 'Every vCenter in the state file is already upgraded. Nothing to do -- run with -StartFresh to start afresh.' }

    # The CSV, the VMs and the appliances have to be right before anything is mounted.
    $early = @($pre | Where-Object { $_.Severity -eq 'Error' -and $_.Check -in @('Appliance VM', 'vCenter access', 'ELM group') })
    if ($early.Count -and -not $DryRun) {
        foreach ($f in $pre) { $script:Findings.Add($f) }
        Write-Findings $early 'vCenters in the CSV'
        throw 'Fix the CSV or the vCenters above, then run again. Nothing has been mounted or changed.'
    }

    # --- 4. the ISO --------------------------------------------------------------------
    # Pre-positioned on a datastore every ESXi host in the CSV can reach. Checked from every
    # host, mounted on every vCenter still to be upgraded, and only then validated by each
    # appliance (it must see a newer update on it). A dry run mounts nothing: it validates only
    # where the ISO is already mounted.
    Assert-NotStopped 'before the ISO was mounted. Nothing has been changed apart from SSH'
    Write-Phase '4. Upgrade ISO'
    Write-Note "ISO: $($script:Iso.Full)"
    $isoName = Get-IsoNameFinding $script:Iso.Full 'Pre' $VCenter
    if ($isoName) { $pre += @($isoName) }
    $k = 0
    foreach ($h in $esxiHosts) {
        $k++
        $f = Test-IsoOnHost $script:EsxiServers[$h.ToLowerInvariant()] $h $script:Iso $k
        if ($f) { $pre += @($f) } else { Write-Note "$h sees $($script:Iso.Full)" }
    }
    $isoBlockers = @($pre | Where-Object { $_.Check -eq 'Upgrade ISO' -and $_.Severity -eq 'Error' })
    if ($isoBlockers.Count -and -not $DryRun) {
        foreach ($f in $pre) { $script:Findings.Add($f) }
        Write-Findings $isoBlockers 'ISO check'
        throw 'The ISO cannot be used as given (see above). Nothing has been mounted or changed.'
    }
    foreach ($n in $groupNodes) {
        if ($n.Stage -ne 'Pending') { Write-Note "$($n.Name): $($n.Stage) at $($n.TargetVersion) in the previous run -- no ISO needed."; continue }
        if (-not $n.Vm -or -not $n.Token) { continue }
        if ($DryRun) {
            $d = Get-IsoDrive $n.Vm
            if ($d -and ([string]$d.IsoPath).Trim() -ieq $script:Iso.Full) { $pre += @(Test-NodeIso $n $true) }
            else {
                $n.IsoPending = $true
                Write-Note "$($n.Name): a real run mounts the ISO on $($n.Vm.Name)$(if ($d) { " (it now has $($d.IsoPath))" }) and validates it there."
            }
            continue
        }
        $m = @(Mount-NodeIso $n $script:Iso)
        $pre += $m
        if (@($m | Where-Object { $_.Severity -eq 'Error' }).Count) { continue }
        $pre += @(Test-NodeIso $n $false)
    }
    $isoErrors = @($pre | Where-Object { $_.Check -eq 'Upgrade ISO' -and $_.Severity -eq 'Error' })
    if ($isoErrors.Count -and -not $DryRun) {
        foreach ($f in $pre) { $script:Findings.Add($f) }
        Write-Findings $isoErrors 'ISO check'
        throw 'The ISO is not mounted and valid on every vCenter to be upgraded (see above). No vCenter has been shut down or changed apart from the ISO.'
    }

    # --- pre-upgrade checks ----------------------------------------------------------
    Write-Phase '5. Pre-upgrade checks'
    # The slowest check -- every service's status -- is read on all of them at the same time.
    $withSsh = @($groupNodes | Where-Object { $_.Token -and -not $_.SshOff })
    $preReady = $(if ($withSsh.Count) { Write-Step "Reading the service status of $($withSsh.Count) vCenter(s) at the same time ..."; Get-GroupServiceReadiness $withSsh } else { @{} })
    foreach ($n in $groupNodes) {
        if (-not $n.Token) { continue }
        $given = $(if ($preReady.ContainsKey($n.Name) -and -not $preReady[$n.Name].Error) { $preReady[$n.Name].Ready } else { $null })
        $n.PreFindings = @(Get-NodeHealthFindings $n 'Pre' (Get-Date) $given)
        if ($Resume -and $n.LastError) {
            # The failed update this run resumes from is expected here, not a new blocker.
            $n.PreFindings = @($n.PreFindings | ForEach-Object {
                if ($_.Check -eq 'Update state' -and $_.Detail -match 'earlier update failed') { New-Finding $_.Phase $_.Node 'Warning' $_.Check "$($_.Detail) (the failure this run resumes from)" } else { $_ }
            })
        }
        $pre += $n.PreFindings
        if ($n.Stage -eq 'Pending' -and $n.TargetVersion) { $pre += @(Invoke-NodePrecheck $n ([bool]$DryRun)) }
        elseif ($n.Stage -eq 'Pending') { $pre += @(New-Finding 'Pre' $n.Name 'Warning' 'Installer precheck' 'not run: there is no update on the ISO to check against') }
    }
    if ($many) {
        Write-Step 'Checking replication from every vCenter in the group ...'
        $pre += @(Get-GroupReplicationFindings $groupNodes $SsoCredential 'Pre')
    }
    foreach ($f in $pre) { $script:Findings.Add($f) }
    Write-Findings $pre 'Pre-upgrade findings'

    $preErrors = @($pre | Where-Object { $_.Severity -eq 'Error' })
    $precheckErrors = @($preErrors | Where-Object { $_.Check -match '^Installer (precheck|validation)$' })
    $structural = @($preErrors | Where-Object { $_.Check -in @('Appliance VM', 'vCenter access', 'ELM group') })
    if (-not $DryRun) {
        if ($precheckErrors.Count) { throw 'The installer precheck reported errors; the upgrade would fail. No vCenter has been shut down or changed apart from the ISO.' }
        if ($structural.Count) { throw "$($structural.Count) error(s) with the vCenters in the CSV or their VMs (see above) -- these cannot be overridden. No vCenter has been shut down or changed apart from the ISO." }
        if ($preErrors.Count) {
            if (-not $ProceedOverPreCheckErrors) { throw "$($preErrors.Count) pre-upgrade error(s) (see above). Fix them and run again -- or, only with a senior engineer's agreement, add -ProceedOverPreCheckErrors. No vCenter has been shut down or changed apart from the ISO." }
            Write-Bad "-ProceedOverPreCheckErrors: carrying on over $($preErrors.Count) pre-upgrade error(s)."
        }
    }

    # --- confirmation ----------------------------------------------------------------
    Write-Phase $(if ($DryRun) { '6. Dry run result' } else { '6. Ready to start' })
    Write-Host "    Upgrade order : one vCenter per round$(if ($Resume) { ' (resuming)' }):"
    $k = 0
    foreach ($n in $groupNodes) {
        $k++
        $what = $(if ($n.Stage -eq 'Done') { "done in a previous run ($($n.TargetVersion))" }
                 elseif ($n.Stage -ne 'Pending') { "$($n.Stage) at $($n.TargetVersion) -- resumes from there" }
                 else { "$($n.CurrentVersion) -> $(if ($n.TargetVersion) { $n.TargetVersion } else { '?' })" })
        Write-Host ("                    {0}. {1}  (VM {2} on {3})  {4}" -f $k, $n.Name, $(if ($n.Vm) { $n.Vm.Name } else { '?' }), $(if ($n.EsxiHost) { $n.EsxiHost } else { '?' }), $what)
    }
    if ($many) {
        Write-Host "    Each round    : shut down ALL $($groupNodes.Count) vCenters together -> snapshot all of them while all are off ->"
        Write-Host "                    power all on -> wait until every vCenter has SSH on, every service started and replication healthy ->"
        Write-Host "                    upgrade that round's vCenter -> reboot -> wait again for every vCenter and replication -> post checks"
        Write-Warn "The SSO domain is DOWN during each round's snapshot (all vCenters powered off together)."
        Write-Warn "Each round adds a snapshot to every vCenter: after $($todo.Count) round(s) each one has $($todo.Count) more. They are kept"
        Write-Warn 'until removed -- remove all of them together once the whole group is validated (or -RemoveSnapshots).'
    } else {
        Write-Host "    Plan          : guest shutdown -> offline snapshot -> power on -> wait for services -> stage and install -> reboot -> post checks"
    }
    $sshOffAtEnd = @($groupNodes | Where-Object { $_.SshEnabledByScript -or ($SshFinalState -eq 'Disable') } | ForEach-Object { $_.Name })
    Write-Host "    SSH           : on for the run; turned off at the end on $(if ($sshOffAtEnd.Count) { $sshOffAtEnd -join ', ' } else { 'none (it was on before the run on every vCenter; -SshFinalState Disable turns it off)' })"
    Write-Host "    On a failure  : no further vCenter is upgraded and the run stops (exit 1), SSH left on. Fix the problem,"
    Write-Host "                    then run again with -Resume to carry on from the vCenter that failed."
    if ($DryRun) {
        $skipped = @($pre | Where-Object { $_.Check -match 'skipped|not run' -or $_.Detail -match '^not (checked|run)' })
        $noTarget = @($todo | Where-Object { $_.Stage -eq 'Pending' -and -not $_.TargetVersion -and -not $_.IsoPending })
        $toMount = @($todo | Where-Object { $_.IsoPending })
        if ($preErrors.Count) {
            Write-Bad "A real run would stop here: $($preErrors.Count) pre-upgrade error(s) above$(if ($precheckErrors.Count) { ', including installer precheck errors' })."
            $exitCode = 1
        } elseif ($noTarget.Count) {
            Write-Bad "Cannot tell whether a real run would proceed: $(($noTarget | ForEach-Object { $_.Name }) -join ', ') could not be asked what its ISO offers, so the installer precheck did not run."
            $exitCode = 1
        } else {
            Write-Good "A real run would proceed: mount the ISO, validate it, then upgrade $($todo.Count) vCenter(s) as planned above."
            if ($toMount.Count) { Write-Warn "The ISO is not mounted yet on $(($toMount | ForEach-Object { $_.Name }) -join ', '): a real run mounts it, and each appliance must see the update on it and pass the installer precheck before anything else changes -- it stops there if not." }
            Write-Note "For the real run: the same CSV, -IsoPath and -LogFolder, without -DryRun, with -ConfirmVCenter $short, within 24 hours."
            $exitCode = 0
        }
        if ($skipped.Count) { Write-Warn "$($skipped.Count) check(s) were skipped in this dry run -- see the findings above." }
        # The record a real run checks before it goes ahead: written on a pass, removed on a
        # fail so an older pass cannot stand in for it.
        $record = Join-Path $LogFolder "dryrun-$short.json"
        try {
            if ($exitCode -eq 0) {
                ConvertTo-DryRunRecordJson $csvSha $script:Iso.Full @($groupNodes | ForEach-Object { $_.Name }) (Get-Date) $ScriptVersion | Set-Content -LiteralPath $record -Encoding UTF8
            } elseif (Test-Path -LiteralPath $record) { Remove-Item -LiteralPath $record -Force }
        } catch { Write-Warn "Could not write the dry-run record ${record}: $($_.Exception.Message)" }
        return
    }
    Assert-NotStopped 'before the start. No vCenter has been shut down or changed apart from the ISO and SSH'
    Write-Good "Start confirmed by -ConfirmVCenter $ConfirmVCenter. From here on the vCenters are shut down for each round's snapshot."
    $confirmed = $true
    Save-UpgradeState

    # --- rounds ------------------------------------------------------------------------
    # One round per vCenter: (group snapshot) -> install -> reboot -> group ready -> post
    # checks. A failure stops the run: the operator fixes it and runs again with -Resume,
    # which carries on with the same vCenter from the stage it reached.
    $i = 0
    while ($i -lt $groupNodes.Count) {
        $n = $groupNodes[$i]
        if ($n.Stage -eq 'Done') { $i++; continue }
        Assert-NotStopped "before round $($i + 1) of $($groupNodes.Count) ($($n.Name))"
        $plan = Get-RoundPlan $n.Stage $true
        Write-Phase "7.$($i + 1) Round $($i + 1) of $($groupNodes.Count): $($n.Name)$(if ($n.TargetVersion) { " -> $($n.TargetVersion)" })$(if ($n.Stage -ne 'Pending') { " (resuming at $($n.Stage))" })"
        try {
            $n.Attempts++
            if ($plan.Snapshot) {
                # Unique per round and per run: a resumed round's snapshot must never share a
                # name with an earlier one, or the check that it was taken (and its removal)
                # could pick the wrong one.
                $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
                $snapName = "Pre-upgrade $(Get-ShortName $n.Name) $($n.TargetVersion) $stamp"
                $existing = @($groupNodes | ForEach-Object { try { @(Get-Snapshot -VM $_.Vm -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { } })
                $k2 = 1
                while ($existing -contains $snapName) { $k2++; $snapName = "Pre-upgrade $(Get-ShortName $n.Name) $($n.TargetVersion) $stamp-$k2" }
                $desc = "Offline snapshot before upgrading $($n.Name) to $($n.TargetVersion) ($stamp)"
                if ($many) { $desc += " -- taken with ALL $($groupNodes.Count) vCenters of the ELM group powered off together ($(($groupNodes | ForEach-Object { $_.Name }) -join ', ')); revert all of them together, never one alone" }
                Invoke-GroupSnapshot $groupNodes $snapName $desc
            } else {
                Wait-GroupReady $groupNodes 'before the round' 'Pre'
            }
            if ($plan.Install) { Invoke-NodeInstall $n; Save-UpgradeState }
            if ($plan.Reboot)  { Invoke-NodeReboot $n; Save-UpgradeState }
            Wait-GroupReady $groupNodes "after the upgrade of $($n.Name)" 'Post'
            Set-NodeStage $n 'Checking' 'post-upgrade checks'
            $post = @(Get-NodePostFindings $n)
            foreach ($f in $post) { $script:Findings.Add($f) }
            Write-Findings $post "$($n.Name) post-upgrade findings"
            $new = @(Compare-Findings $n.PreFindings $post)
            if ($new.Count) { Write-Findings $new "$($n.Name): new since the upgrade" } else { Write-Good "$($n.Name): nothing new since the upgrade." }
            $postErrors = @($post | Where-Object { $_.Severity -eq 'Error' })
            if ($postErrors.Count) { throw "$($postErrors.Count) post-upgrade error(s) on $($n.Name)." }
            $n.Stage = 'Done'; $n.LastError = $null
            Save-UpgradeState
            Set-NodeStage $n 'Upgraded' $n.TargetVersion 100
            Write-Good "Round $($i + 1) complete: $($n.Name) is upgraded to $($n.TargetVersion)."
            $i++
        } catch {
            if ($_.FullyQualifiedErrorId -like 'VvfStopRequested*') { throw }
            $err = $_.Exception.Message
            $n.LastError = $err
            Save-UpgradeState
            Set-NodeStage $n 'Failed' $err
            Add-Finding 'Upgrade' $n.Name 'Error' 'Round failed' "$($n.Stage): $err" | Out-Null
            Write-Host ''
            Write-Bad "FAILED on $($n.Name) ($($n.Stage)): $err"
            Write-Bad 'No further vCenters will be upgraded until this is resolved.'
            Write-GroupPowerState $groupNodes
            $remaining = @($groupNodes | Where-Object { $_.Stage -ne 'Done' } | ForEach-Object { $_.Name })
            Write-Note "Still to do: $($remaining -join ', ')"
            throw "Stopped at $($n.Name): $err Fix the problem, then run again with -Resume to carry on from $($n.Name)$(if ($n.Stage -eq 'Pending') { ' (a fresh group snapshot is taken first)' } else { " (from $($n.Stage))" })."
        }
    }

    # --- wrap up ---------------------------------------------------------------------
    # Every vCenter is upgraded: the ISO comes off (released inside each appliance over SSH
    # first), and only then is SSH turned off -- the end of the whole upgrade.
    Write-Phase '8. Wrap-up'
    Write-Step "Unmounting the upgrade ISO from $(if ($many) { "all $($groupNodes.Count) vCenters" } else { $VCenter }) ..."
    $unmountFailed = @()
    foreach ($n in $groupNodes) {
        $u = Dismount-NodeIso $n
        switch ($u.Result) {
            'Dismounted' { Write-Good "$($n.Name): ISO unmounted."; Set-NodeStage $n 'IsoUnmounted' }
            'NotMounted' { Write-Note "$($n.Name): no ISO mounted."; Set-NodeStage $n 'IsoUnmounted' 'none was mounted' }
            default {
                Write-Bad "$($n.Name): ISO NOT unmounted -- $($u.Reason)"
                Set-NodeStage $n 'IsoUnmountFailed' $u.Reason
                Add-Finding 'Post' $n.Name 'Warning' 'ISO unmount' $u.Reason | Out-Null
                $unmountFailed += $u
            }
        }
    }
    if ($unmountFailed.Count) { Write-Warn "Disconnect the ISO from $(($unmountFailed | ForEach-Object { $_.Node }) -join ', ') by hand once the cause above is dealt with. The upgrades themselves are complete." }

    Write-Step "Turning SSH off -- every vCenter is upgraded and the ISO is off$(if ($SshFinalState -eq 'Disable') { ' (-SshFinalState Disable: on every vCenter)' }) ..."
    $sshFailed = @()
    foreach ($n in $groupNodes) {
        $act = Get-SshEndAction ([bool]$n.SshEnabledByScript) $true $false $false $SshFinalState
        if ($act -eq 'Disable') {
            if (Disable-NodeSsh $n $(if ($n.SshEnabledByScript) { 'the run had turned it on' } else { '-SshFinalState Disable' })) { $sshFailed += $n.Name }
        } else {
            Close-NodeSsh $n
            $n.SshFinal = 'On (was on before the run)'
            Write-Note "$($n.Name): SSH left on -- it was on before the run (-SshFinalState Disable turns it off)."
        }
    }
    if ($sshFailed.Count) { Add-Finding 'Post' ($sshFailed -join ', ') 'Warning' 'SSH' 'could not be turned off -- turn it off in the VAMI (Access)' | Out-Null }

    $snapCount = $script:SnapshotsTaken.Count
    if ($snapCount) {
        if ($RemoveSnapshots) {
            Write-Step "-RemoveSnapshots: removing the $snapCount pre-upgrade snapshot(s) this run took ..."
            foreach ($t in $script:SnapshotsTaken) {
                try {
                    $s = @(Get-Snapshot -VM $t.Node.Vm -ErrorAction Stop | Where-Object { $_.Name -eq $t.Name })
                    if ($s.Count -eq 1) { Remove-Snapshot -Snapshot $s[0] -Confirm:$false -ErrorAction Stop | Out-Null; Write-Note "Snapshot '$($t.Name)' removed from $($t.VmName)." }
                } catch { Write-Warn "Could not remove '$($t.Name)' from $($t.VmName): $($_.Exception.Message)" }
            }
        } else {
            Write-Note "$snapCount pre-upgrade snapshot(s) taken by this run are kept: Aria Operations normally removes snapshots older than 7 days, and they are the rollback point until then."
            if ($many) { Write-Note 'If you remove them yourself, remove them all together: a rollback needs the same round''s snapshot on every vCenter.' }
            foreach ($t in $script:SnapshotsTaken) { Write-Note "  '$($t.Name)' on $($t.VmName) ($($t.EsxiHost))" }
        }
    }
    try { Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction Stop } catch { }
    $completed = $true
    Write-Good "All $($groupNodes.Count) vCenter(s) upgraded: $(($groupNodes | ForEach-Object { "$($_.Name) $($_.TargetVersion)" }) -join ', ')."
    $exitCode = 0
}
catch {
  if ($_.FullyQualifiedErrorId -like 'VvfStopRequested*') {
    # A stop the operator asked for, at a safe point: not a failure.
    $stopped = $true
    Write-Host ''
    Write-Warn "STOPPED SAFELY: $($_.Exception.Message)"
    $done = @($groupNodes | Where-Object { $_.Stage -eq 'Done' } | ForEach-Object { $_.Name })
    $left = @($groupNodes | Where-Object { $_.Stage -ne 'Done' } | ForEach-Object { $_.Name })
    if ($done.Count) { Write-Note "Upgraded: $($done -join ', ')" }
    if ($left.Count) { Write-Note "Still to do: $($left -join ', ')" }
    Write-GroupPowerState $groupNodes
    if ($script:SnapshotsTaken.Count) {
        Write-Note "Offline snapshot(s) taken by this run$(if (@($groupNodes).Count -gt 1) { ' (in ELM revert ALL vCenters to the same round''s snapshot, never one alone)' }):"
        foreach ($t in $script:SnapshotsTaken) { Write-Note "  '$($t.Name)' on $($t.VmName) ($($t.Node.Name)) on $($t.EsxiHost)" }
    }
    if ($script:StatePath -and (Test-Path -LiteralPath $script:StatePath)) { Write-Note "Progress saved to $($script:StatePath) -- run again with -Resume to carry on. The ISO is left mounted for that." }
    $exitCode = 2
  } else {
    Write-Host ''
    Write-Bad "STOPPED: $($_.Exception.Message)"
    if ($env:VVF_DEBUG) { Write-Note $_.ScriptStackTrace }
    if ($script:SnapshotsTaken.Count) {
        Write-Warn "Offline snapshot(s) taken by this run$(if (@($groupNodes).Count -gt 1) { ' (in ELM revert ALL vCenters to the same round''s snapshot, never one alone)' }):"
        foreach ($t in $script:SnapshotsTaken) { Write-Warn "  '$($t.Name)' on $($t.VmName) ($($t.Node.Name)) on $($t.EsxiHost)" }
    }
    if ($script:StatePath -and (Test-Path -LiteralPath $script:StatePath) -and -not $DryRun) { Write-Note "Progress saved to $($script:StatePath) -- run again with -Resume to continue. The ISO is left mounted for that." }
    $exitCode = 1
  }
}
finally {
    # --- SSH at the end of the run ---
    # Completed: the wrap-up has already turned it off. Otherwise: a real run that is part way
    # through (it will be resumed) leaves it on and records where it turned it on; a dry run,
    # or a real run refused before it started, puts it back as it found it.
    $unfinished = $false
    if (-not $DryRun -and -not $completed) {
        if ($confirmed) { $unfinished = $true }
        elseif ($script:StatePath -and (Test-Path -LiteralPath $script:StatePath)) {
            try { $unfinished = [bool]@((ConvertFrom-UpgradeStateJson (Get-Content -LiteralPath $script:StatePath -Raw)).Nodes | Where-Object { $_.Stage -ne 'Done' }).Count } catch { $unfinished = $true }
        }
    }
    $nodesToRestore = @($groupNodes)
    if ($primary -and $nodesToRestore -notcontains $primary) { $nodesToRestore += $primary }
    $leftOn = @()
    foreach ($n in $nodesToRestore) {
        if ($completed) { Close-NodeSsh $n; continue }
        $act = Get-SshEndAction ([bool]$n.SshEnabledByScript) $false $unfinished ([bool]$DryRun) $SshFinalState
        if ($act -eq 'Disable') {
            $null = Disable-NodeSsh $n $(if ($DryRun) { 'the dry run had turned it on' } else { 'the run had turned it on, and ended before any vCenter was shut down' })
            continue
        }
        Close-NodeSsh $n
        if ($n.SshEnabledByScript) { $leftOn += $n.Name; $n.SshFinal = 'On (left on for -Resume)' }
        elseif (-not $n.SshFinal) { $n.SshFinal = $(if ($n.SshOff) { 'Off (could not be turned on)' } elseif ($n.SshWasOn) { 'On (was on before the run)' } else { 'unchanged' }) }
    }
    if ($leftOn.Count) {
        Write-Warn "SSH is left ON on $($leftOn -join ', '): the upgrade is not finished. The run that finishes it (-Resume) turns it off at its end; if the upgrade is abandoned, turn it off in each VAMI (Access)."
        if ($script:StatePath -and (Test-Path -LiteralPath $script:StatePath)) {
            $flags = @{}
            foreach ($n in $groupNodes) { $flags[$n.Name] = [bool]$n.SshEnabledByScript }
            try { Merge-StateSshFlags (Get-Content -LiteralPath $script:StatePath -Raw) $flags | Set-Content -LiteralPath $script:StatePath -Encoding UTF8 }
            catch { Write-Warn "Could not record in $($script:StatePath) where SSH was turned on: $($_.Exception.Message)" }
        }
    }

    if ($script:Findings.Count) {
        $findingsCsv = Join-Path $LogFolder "findings-$(if ($VCenter) { Get-ShortName $VCenter } else { 'vcenter' })-$runStamp.csv"
        try { $script:Findings | Export-Csv -LiteralPath $findingsCsv -NoTypeInformation -Encoding UTF8; Write-Note "Findings: $findingsCsv" } catch { }
    }
    foreach ($srv in @($script:EsxiServers.Values)) { try { Disconnect-VIServer -Server $srv -Confirm:$false | Out-Null } catch { } }
    # A plink password file whose command was never collected (a stop, a failure) goes too.
    foreach ($f in $script:PlinkPasswordFiles) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

    # --- summary ---
    $resultText = $(if ($DryRun) { $(if ($exitCode -eq 0) { 'DryRunPassed' } else { 'DryRunFailed' }) }
                    elseif ($exitCode -eq 0) { 'Upgraded' } elseif ($stopped) { 'StoppedSafely' } else { 'Failed' })
    $summaryRows = @($groupNodes | ForEach-Object {
        [pscustomobject]@{
            VCenter   = $_.Name
            Stage     = $_.Stage
            LastStep  = $(if ($_.Board) { (("{0} {1}" -f $_.Board.Stage, $_.Board.Detail).Trim()) } else { '' })
            From      = [string]$_.FromVersion
            Target    = [string]$_.TargetVersion
            Now       = [string]$_.CurrentVersion
            Ssh       = [string]$_.SshFinal
            LastError = [string]$_.LastError
        }
    })
    Write-Host ''
    Write-Host "RESULT: $resultText (exit code $exitCode)" -ForegroundColor $(if ($exitCode -eq 0) { 'Green' } elseif ($stopped) { 'Yellow' } else { 'Red' })
    if ($summaryRows.Count) { Write-Host (($summaryRows | Format-Table VCenter, Stage, LastStep, From, Target, Now, Ssh -AutoSize | Out-String -Width 250).TrimEnd()) }
    $stateLeft = $(if (-not $DryRun -and $script:StatePath -and (Test-Path -LiteralPath $script:StatePath)) { $script:StatePath } else { '' })
    if ($transcriptOn) { try { Stop-Transcript | Out-Null; Write-Host "  Transcript: $transcript" -ForegroundColor DarkGray } catch { } }
    # The result object, last on the output stream, for a front end to read.
    [pscustomobject]@{
        Script      = 'Invoke-VvfVCenterUpgrade'
        Version     = $ScriptVersion
        Result      = $resultText
        ExitCode    = $exitCode
        DryRun      = [bool]$DryRun
        Nodes       = $summaryRows
        Transcript  = $(if ($transcriptOn) { $transcript } else { '' })
        FindingsCsv = [string]$findingsCsv
        StateFile   = $stateLeft
        LogFolder   = $LogFolder
    }
    # Here rather than after the block: the dry run returns from inside it.
    exit $exitCode
}
