<#
.SYNOPSIS
    ESXi/UCSM/Intersight PVA accepted-batch firmware upgrade controller with hardened login handling.

.DESCRIPTION
    New consolidated script based on the supplied workflow. The main correction is the UCSM
    discovery/login path. It normalises FI CDP/LLDP names, tries the exact same positional
    Connect-Ucs style that works manually, supports credential and interactive fallback, and
    validates UCSM cmdlet availability before continuing.

    No management platform is assumed up front. CDP/LLDP is the single identity source for every host,
    and supporting infrastructure is detected per host, before any UCSM or Intersight login: each host's
    CDP/LLDP system name is checked against the Name column in $IntersightCsvPath (default
    C:\temp\intersightfabric.csv). A match detects that host as Intersight-managed: the script finds the
    server profile, checks for staged changes (normally "Pending-changes") caused by a firmware policy update, accepts them
    (including the compulsory disruption tick box), and reboots the blade immediately - scoped to the
    current batch only, same as the existing UCSM acknowledgement. Any host with no CSV match is detected
    as UCS Manager-managed and falls through to the existing UCS Manager (classic) logic unchanged. UCS
    PowerTool is only required/loaded if at least one host in the cluster is detected as UCS-managed.

    CSV name matching is form-independent. The Fabrics export and the CDP/LLDP system name may each
    carry a -A or -B fabric suffix or none at all, and may each be an FQDN or a short name. Every CSV
    row is indexed under all eight equivalent forms of its Name, and each CDP name is tested against the
    same set, so a row named PD24000001SS101-A matches a host reporting PD24000001SS101-B.dpe.example
    and vice versa. The detection table shows which form produced each match.

.NOTES
    REQUIREMENTS - assumed present, NOT verified at run time.

    1. POWERSHELL MODULES - present and importable. This script contains no Import-Module;
       loading is the jump host build's job and PowerShell auto-loads on first use.
       PowerShell 7 (Core) - Intersight.PowerShell is a binary module built for it and can
         appear installed under Windows PowerShell 5.1 while failing at the first signed request.
       VMware PowerCLI 12.3.0 or newer - hosts, clusters, Maintenance mode, host profiles.
       Intersight.PowerShell - EXACTLY ONE version, matching the appliance's Intersight release.
         Side-by-side versions, or a build that disagrees with the appliance, produce an error
         that blames BasePath and the API key while the credentials are in fact correct.
       Cisco UCS PowerTool (Cisco.UCSManager) - only if a host is UCS Manager-managed.

    2. INTERSIGHT API KEY - required only if a host in scope is Intersight-managed.
       API Key ID - three segments, e.g. aaaa/bbbb/cccc.
       The matching private key (.pem) file on this machine. Both are issued together under
         Settings > API Keys and the secret is downloadable only at creation.
       You are prompted for these and for the appliance FQDN when a fabric is first detected.

    3. INTERSIGHT INPUT FILE - required only if a host in scope is Intersight-managed.
       Path is set by $IntersightCsvPath in User Settings.
       Column "Name" holds the fabric name, matched against each host's CDP/LLDP neighbour.
       Optional columns: ServerProfileName, Moid.
       A host whose CDP/LLDP name matches a row is driven through Intersight; every other host
       falls through to UCS Manager. Matching allows for -A, -B and suffix-less forms, and for
       FQDN or short name on either side.

    4. CREDENTIALS - vCenter and UCS Manager, for the prompts during the run.

    None of the above is verified at start-up: probing for it was slow enough on a domain jump
    host to read as a hang. Failures surface where they matter instead - a missing module at its
    first cmdlet, a bad Intersight connection before any host is touched, a missing CSV at import.
    Verify the environment out of band with scripts\intersight\Test-IntersightApiKey.ps1.

    - Version 21.3.0. Set in $ScriptVersion below and stamped onto every row of the run summary
      and firmware verification CSVs. History is in git and CHANGELOG.md - do not version by
      filename.
    - Credentials/API keys are kept in memory only.
    - Intersight only supports API-key + HTTP-signature auth, not username/password - see the
      $Global:IntersightApiKeyId / $Global:IntersightApiKeyFilePath notes in User Settings.
      Authentication is applied with Set-IntersightConfiguration; Intersight.PowerShell has no
      Connect-*/Disconnect-* cmdlet pair. $Global:IntersightBaseUrl is the appliance root only, with
      no /api/v1 suffix and no trailing slash.
    - The Intersight API endpoint is not fixed in the script. As soon as a host is detected as
      Intersight-managed, the operator is prompted for the appliance FQDN (or intersight.com for
      SaaS) and that becomes the BasePath for the run. A bare FQDN, a full URL, a trailing slash or
      a pasted /api/v1 are all accepted and normalised. Certificate checking follows from the
      answer: skipped for an on-prem PVA, enforced for intersight.com.
    - DRYRUN is the default.
    - UCSM acknowledgement and Intersight accept/reboot are each scoped to their own batch hosts only.
    - REBOOT IMMEDIATELY TO ACTIVATE is sent with every Intersight deploy
      ($Global:IntersightRebootImmediatelyToActivate, on by default). Without it the firmware
      stages against the profile and nothing restarts.
      It is ProceedOnReboot on a PolicyScheduledAction - "ProceedOnReboot can be used to
      acknowledge server reboot while triggering deploy/activate", in the SDK's own words - and it
      rides on ACTIVATE, sent as ONE call that both deploys and activates:
          $a = Initialize-IntersightPolicyScheduledAction -Action 'Activate' -ProceedOnReboot $true
          Set-IntersightServerProfile -Moid <moid> -ScheduledActions @($a)
      No top-level -Action goes with it, and there is no separate staging call. Deploy stages and
      stops; Activate stages and restarts, so one action does the work of the two-step form.
      The cmdlet surface for this is checked before any host is evacuated, and the result is not
      trusted either: Confirm-IntersightDeployAccepted re-reads the profile afterwards and stops
      the run if it is still sitting in its staged state, rather than waiting out a post-reboot
      window for a restart that was never scheduled.
      THE REBOOT COMES FROM INTERSIGHT. Staging the firmware works; the restart is what the
      appliance does not always do on its own. Where it does not, the run reads back which server
      the profile is assigned to and power-cycles THAT server through Intersight - vCenter is not
      involved, and no host is rebooted from the vSphere side:
          Set-IntersightComputeServerSetting -Moid <server moid> -AdminPowerState PowerCycle
      which is POST /api/v1/compute/ServerSettings/<server moid>.
      AdminPowerState 'Reboot' is a trap: the SDK defines it as "Power state of IMC is rebooted",
      so it restarts the management controller and leaves the server running with the firmware
      still staged. 'PowerCycle' resets the server. The run warns loudly if it is ever configured
      with 'Reboot'.
      THE ORDER, and nothing in vCenter happens until it has finished:
        0. ACTIVATE IS TRIED FIRST, AND THE APPLIANCE DECIDES. Activate is only valid once the
           profile's CONFIGURATION is already deployed; from Pending-changes it is refused with
           "Action 'Activate' is not allowed in the current state"
           (gershwin_user_action_is_not_allowed). When that happens the run falls back to
           Deploy WITH the reboot acknowledgement, which is the form the appliance requires:
             -Action Deploy + ScheduledActions @{Action='Deploy'; ProceedOnReboot=$true}
           Reacting to the appliance's own answer beats predicting which states permit which
           action - that is not published, and guessing at it has been wrong twice.
        1. ACTIVATE FROM THE START where the state allows it - one call, what the GUI sends:
             POST /api/v1/server/Profiles/<moid>
             {"ScheduledActions":[{"Action":"Activate","ProceedOnReboot":true}]}
           Activate, not Deploy. Deploy stages the firmware and leaves the profile waiting for a
           restart; Activate stages AND restarts, so there is no stage-then-activate split and no
           wait wedged between two halves of one operation. Set
           $Global:IntersightRebootImmediatelyToActivate to $false to stage only and restart the
           blades by hand - that path still sends -Action Deploy.
        2. Watch the upgrade, starting immediately. The check is the GUI's own query:
             GET /api/v1/firmware/Upgrades
                 ?$filter=(Server.Moid in ('<moid>')) and (Status eq 'IN_PROGRESS')&$select=Server
           One call, one field, and the appliance does the deciding - rows means running, none
           means finished. Nothing here interprets a free-text state string.
        3. Still running -> stand off $Global:IntersightActivationWaitMinutes (default 60) and
           check again, then prompt RETRY / CONTINUE / EXIT. No cap on retries.
           Finished but the profile is still staged -> send Activate again, with a server power
           cycle as the fallback if it is refused.
        4. Once the activation lands, hold up to $Global:IntersightActivationHoldMinutes
           (default 40), POLLING every minute and returning as soon as the profile has settled and
           no upgrade is running.
        5. Only then does the run go back to vCenter, and the FIRST thing it does there is wait for
           the host to reappear in inventory. Nothing is scanned, exited from Maintenance mode or
           acted on until it has. "Back" means Connected or Maintenance in vCenter AND a boot time
           that has changed since before the activation - connection state alone cannot tell "came
           back" from "never left", and on a firmware run the difference is whether the compliance
           scan runs against the new firmware or the old. The baseline is taken before ANY action
           in the batch, because a UCS acknowledgement restarts a host just as an activation does.
           A batch where nothing was staged clears the baseline: no reboot was asked for, so none
           is waited on.
      After the power action the run STANDS OFF for $Global:IntersightActivationWaitMinutes
      (default 40) and looks again, rather than polling on a timeout - an activation takes as long
      as it takes. Each stand-off ends with a choice: RECHECK to wait another window, CONTINUE to
      move on to the post-reboot wait, or EXIT. There is no cap: the run waits exactly as long as
      the operator wants and never decides on its own that an activation has failed.
      "Cannot perform power action when a firmware upgrade is in progress" is treated as a NOT YET,
      not a failure - it means the upgrade this deploy started is still running, so the power
      action is retried after each stand-off until it lands.
      NONE OF THIS ENDS THE RUN. Not a server that cannot be identified, not a refused power
      action, not an activation that is still going. Each is announced and recorded.
    - THIS SCRIPT MIGRATES NOTHING. The batch is sized from live cluster capacity and its hosts go
      straight into Maintenance mode; DRS moves the running VMs, once, as part of that. Two things
      that used to happen first have been removed: a cold migration of every powered-off and
      suspended VM off each host, and the -Evacuate switch on Set-VMHost (which IS
      evacuatePoweredOffVms, and forces the same thing). On a large cluster that took longer than
      the upgrade, moved data with no reason to move, and was undone by DRS the moment the host
      came back. Powered-off and suspended VMs do not block Maintenance mode.
    - Maintenance mode is entered ONE HOST AT A TIME, in cluster list order - first hosts in the
      cluster first, working through. Each host is requested and then waited for before the next is
      asked. Requesting a whole batch at once was tried and does not work: the capacity available to
      receive the VMs shrinks at the same time as the VMs need placing, so migrations run
      continuously and no host arrives. A host that does not reach Maintenance mode within
      $MaintenanceValidationTimeoutMinutes stops the run, naming it, with the rest of the batch
      untouched. SINGLE mode is a batch of one, so its behaviour is unchanged.
    - Batch mode is AUTO (sized from live cluster capacity, capped at half the cluster) or
      SINGLE (one host at a time). There is no free-text batch size.
    - ONLY BLADES WITH CHANGES STAGED ARE IN SCOPE. Before anything is evacuated, every
      Intersight-managed host's server profile is read once and those with nothing to deploy - an
      Associated profile, or any state outside $Global:IntersightActionableConfigStates - are
      dropped from the run. Batching one of those would evacuate a host, wait, find nothing to
      send, bring it back and report success, having achieved nothing and spent a window slot. A
      profile whose ConfigState cannot be READ stays in scope: "nothing staged" and "could not
      tell" are different answers.
    - HOST PROFILE COMPLIANCE IS THE ONLY HEALTH GATE. A host that passes it and comes out of
      Maintenance mode is back in service, and the run moves to the next host. The cluster-wide
      checks - datastore free space, triggered alarms, hosts in Maintenance mode elsewhere - have
      been REMOVED at the operator's direction, after repeatedly failing a cluster with nothing
      wrong with it and stopping the run mid-change. Cluster-level assurance is now the operator's
      responsibility, in the manual health checks stated in the requirements above.
    - The run advances through the cluster automatically. The per-batch typed gates (ACK-BATCH-N and
      SAVE-BATCH-N) have been REMOVED in favour of automatic progression. What gates each batch is
      the timed pre-reboot safety window (press E to abort) and the host profile compliance check on
      every rebooted host.
    - After each reboot, once the batch is confirmed back in vCenter, the run waits
      $HostProfileComplianceSettleMinutes (default 8) and then scans every host against its attached
      host profile while it is still in Maintenance mode. The wait is there because a host that has
      just re-registered reports differences that clear themselves; scanning through that window
      produces failures that are not real.
      Getting the status is not one call. Test-VMHostProfileCompliance -VMHost has been seen to
      return nothing at all against an Auto Deploy host in Maintenance mode - no error, no result -
      so four routes are tried in order, stopping at the first that gives a usable status:
        1. Test-VMHostProfileCompliance -VMHost, without -UseCache, so it performs the check and
           blocks until vCenter finishes it. Any check already running is drained first.
        2. The ProfileComplianceManager's QueryComplianceStatus, via Get-View. This is the source
           the vSphere Client reads, so it is the authority on what vCenter holds.
        3. Test-VMHostProfileCompliance -UseCache, PowerCLI's own read of the stored result.
        4. Test-VMHostProfileCompliance -Profile, a real check across every host on the profile,
           filtered back to this host. Last, because it is the expensive one.
      The status is read from all four places PowerCLI puts it - ComplianceStatus or Status, on the
      result or on its ExtensionData - and results covering several hosts are matched to this one
      rather than taken first.
      Unknown means every route declined, and is handled like NonCompliant. It is never inferred
      from anything this script works out for itself, and the detail names each route and what it
      returned so the next run says which one to fix.
    - COMPLIANT IS THE ONLY STATUS THAT CONTINUES ON ITS OWN. Anything else - NonCompliant,
      Unknown, or NoProfile - halts the run with the host still in Maintenance mode and the batch
      not advancing, and tells the operator to resolve the host profile issue manually in vCenter.
      C continues (the host is re-checked, and once it reports Compliant it comes out of
      Maintenance mode and the run carries on by itself), O overrides and returns the host to
      service as it is, E exits safely. Identical in SINGLE and AUTO: SINGLE is a batch of one
      through the same loop, so an Intersight host is gated the same way in both.
    - BEFORE STARTING, untick 'Authentication Configuration' and 'Active Directory Permission'
      under Security in the host profile. Left ticked, the profile does not apply cleanly to a host
      that has just rebooted and rejoined, and the compliance gate above halts on it.
      RE-ENABLE BOTH AFTER THE UPGRADE. This run does not change them and does not put them back.
    - Exiting Maintenance mode is confirmed, not assumed. vCenter reports the old state briefly
      after accepting the change, and the cluster health check that follows fails on any host still
      in Maintenance - which stopped the run one host in, having actually succeeded. The run now
      waits up to $ExitMaintenanceTimeoutMinutes for the transition to land.
    - EVERY PROMPT IS A SINGLE KEY: C continue, R retry/recheck, S skip, X stop, O override,
      Y/N yes-no, E exit. The full words are still accepted as aliases so old habits are not
      punished mid-change, but the screen only ever asks for one letter.
    - THE CLUSTER IS UPGRADED AS A ROLLING WINDOW, NOT IN DISCRETE BATCHES. Each host is tracked
      on its own through AwaitingReturn -> Settling -> Compliance -> Done, and the moment one is
      back in service its slot is refilled from the front of the remaining hosts. The old shape did
      not start host N+1 until the SLOWEST of the first N had finished, so a host back in twenty
      minutes sat idle while its neighbour took fifty.
      How many may be out AT ONCE is re-read from live capacity on every pass - the same
      capacity arithmetic as before, now used as a concurrency limit rather than a batch size.
      Each host settles from ITS OWN return time, so the settle windows overlap instead of costing
      $HostProfileComplianceSettleMinutes once per host in series.
      The firmware phase does NOT block: the deploy and activation are sent and the loop moves on,
      because the signal the vCenter work actually waits on is the host reappearing in vCenter.
      SINGLE mode is the same engine with the limit fixed at one, so the two modes cannot drift.
    - THE WHOLE BATCH IS ACTIVATED AT ONCE. The hosts are evacuated together, so they are upgraded
      together: every deploy in the batch is sent, then every activation, then all of them are
      watched in ONE polling loop. A batch takes as long as its SLOWEST host, not the sum of them.
      Doing it host by host meant a batch of six gave up six hosts' capacity up front and then got
      them back one at a time. Whatever has not finished at the ceiling is put to the operator ONCE
      for the batch, not once per host. SINGLE mode is a batch of one through the same code.
    - THE ACTIVATION IS DRIVEN BY WHAT INTERSIGHT REPORTS, NOT BY A CLOCK. After the deploy is
      sent, the run polls three signals every $Global:IntersightPollIntervalSeconds and moves on the
      moment all three are clear - five minutes or fifty:
        1. server.Profile.RunningWorkflows, expanded. Per the Intersight SDK this is "the
           WorkflowInfos in the workflow engine that are running for this server Profile", so the
           deploy and activation are watched as they happen, by name and percentage complete.
           Both status enums are read - Status (RUNNING/WAITING/COMPLETED/TIME_OUT/FAILED) and
           WorkflowStatus (NotStarted/InProgress/Waiting/Completed/Failed/Terminated/Canceled/
           Paused) - because which one an appliance populates depends on its release.
        2. firmware/Upgrades for the server with Status eq 'IN_PROGRESS', the GUI's own query.
        3. The profile's ConfigState no longer requiring a deploy.
      WHERE INTERSIGHT WILL NOT REPORT A ConfigState AT ALL, vCENTER IS ASKED INSTEAD: if the host
      has restarted and rejoined - present in inventory, Connected or in Maintenance, and with a
      boot time DIFFERENT from the baseline captured before any action - the activation plainly
      happened, and the run moves on. That is a read, and the only vCenter call in the activation
      path; nothing is changed there. Without it a run sat out its whole ceiling on a host that was
      already back and healthy.
      A workflow that ends Failed, Terminated or TimedOut stops the wait at once - there is nothing
      to gain from holding an hour for something the engine has given up on. An unreadable signal
      is never read as completion.
      $Global:IntersightActivationWaitMinutes and $Global:IntersightActivationHoldMinutes are now
      CEILINGS on how long it keeps asking before handing the decision back to the operator, not
      fixed sleeps. Reaching one is not a failure.
      vCenter is then polled for the host's return, starting immediately, because Intersight has
      already said the reboot completed - the fixed post-reboot wait is skipped for these hosts.
    - THE ESXi ROOT PASSWORD IS ASKED FOR WHEN THE CLUSTER IS SELECTED, and used for one thing: a
      host that reboots and comes back DISCONNECTED in vCenter because the password vCenter holds
      for it no longer works. vCenter cannot recover that on its own, so the run would otherwise
      wait out its whole window for something that never resolves.
      A host seen Disconnected or NotResponding for $HostReconnectAfterDisconnectMinutes (5) is
      reconnected: first with vCenter's own stored credentials, then - if that fails, which is the
      stale-password case - with ReconnectHost_Task carrying the root credential. NOT a remove and
      re-add, which would take the host's VMs out of inventory with it.
      Once reconnected the host goes through the SAME return check as every other host, so it earns
      its way through settle and compliance rather than being waved past them.
      Declining the prompt is allowed; a disconnected host is then reported for manual
      rectification instead. The credential is held in memory only, cleared per cluster, and never
      written to the log or the run summary.
    - A UCS MANAGER HOST WHOSE FIRMWARE POLICY IS ALREADY THE TARGET IS NOT BATCHED. CurrentPolicy
      equals TargetPolicy means this run has nothing to set, so the host is left alone - the same
      test the Intersight path makes on ConfigState.
      The running firmware version and any pending acknowledgement are still READ, but they no
      longer decide: a host whose package is set yet has not rebooted onto it is excluded on the
      policy AND named in the closing manual rectification report, so it is visible rather than
      either silently skipped or needlessly re-evacuated.
    - WHILE A UCS MANAGER HOST IS UPGRADING, the run reports what UCSM is doing on every poll -
      whether the reboot acknowledgement is still outstanding, and the running firmware against the
      target - alongside the vCenter state, exactly as an Intersight host reports its workflow and
      upgrade phase. The rolling loop's R/O/E prompt is the manual check for both.
    - HOSTS ALREADY IN MAINTENANCE MODE ARE IN SCOPE, for both the Intersight and the UCS Manager
      paths. They were previously skipped for being not-Connected, which quietly left them on old
      firmware while the run reported the cluster complete. They are now taken FIRST - being already
      evacuated they cost no capacity, so the batch sizing treats their slots as free and a batch
      made up entirely of them is never refused on capacity grounds.
      The consequence, stated on screen at the start of the run rather than buried: at the end of
      their batch they go through the same host profile compliance gate as every other host and,
      once it passes, they are taken OUT of Maintenance mode. A host parked deliberately for an
      unrelated reason will be returned to service by this run.
      NotResponding and Disconnected hosts remain out of scope - there is nothing to drive through
      vCenter on a host it cannot reach. They are SET ASIDE, NOT STOPPED ON: the rest of the
      cluster is still upgraded and the host is named in the closing report. Previously such a host
      fell through to the manual-UCSM-target prompt and then to a hard stop on the unresolvable
      service profile, taking every other host in the cluster with it.
    - NOTHING THAT CANNOT BE DRIVEN ENDS THE RUN ANY MORE. A host that is unreachable, returns no
      CDP/LLDP identity, or has no UCS service profile is set aside and the cluster carries on. The
      manual UCSM target prompt takes SKIP as well as an address and EXIT.
    - WHEN THE CLUSTER COMPLETES, a HOSTS REQUIRING MANUAL RECTIFICATION report is printed, listing
      every host the run could not finish and why - set aside during discovery, compliance
      overridden, left in Maintenance mode, firmware activation unconfirmed, still outstanding on
      the platforms at verification, or not back in service. Hosts that were never batched are
      called out separately as NOT UPGRADED. The report prints even when it is empty, because
      "nothing outstanding" is a result worth stating, and every row is written to the run summary
      CSV under the ManualAttention stage. It closes with the reminder to re-enable the two host
      profile Security settings.
    - An Intersight profile reporting RequiresDeploy=false is the state the run is trying to reach,
      so it is carried on through rather than asked about. The run only stops for a state it could
      not READ - "nothing staged" and "could not tell" produce the same silence and must not be
      treated as the same answer.
    - When the cluster completes, a post-change verification is read back from the platforms
      themselves and written to Post-Change-Verification-<cluster>-<timestamp>.csv:
        ESXi        - build against $TargetEsxiBuild.
        Intersight  - ConfigState, and whether anything is still staged.
        UCS Manager - the host firmware package now on the service profile, AND the version the
                      server reports running compared against the version that package name refers
                      to (global-602d is 6.0(2d), global-436h is 4.3(6h)). The version is read back
                      out of the name, so no bundle version is written anywhere by this script -
                      but a server whose activation did not take is still caught, which the policy
                      name alone would not show.
      "Outstanding: None" on every row is what a completed run should look like.
      Compliant hosts are taken out of Maintenance mode and the run continues. For anything else the
      operator chooses C to re-scan after remediating, O to override and return the host to service
      as it is, or E to exit. On C the host stays in Maintenance mode and the batch does not advance.
      An override is announced on screen and recorded in the run summary as Overridden, naming the
      status that was accepted.
    - The UCSM host firmware package is derived from the fabric interconnect family, not chosen by
      an operator: 6400 -> global-602d, 6300 -> global-436h. An existing package is used as-is. A
      missing one is created, after an explicit confirmation, by NAME ONLY - no blade or rack bundle
      version is written from this script, so the package follows the global firmware setting its
      name refers to. DRY RUN never creates anything.
    - Batch sizing enforces $ResourceSafetyBuffer, $MinimumCpuHeadroomPercentAfterBatch and
      $MinimumMemoryHeadroomPercentAfterBatch.
    - Validate Cisco UCS PowerTool cmdlet names in your installed module version before LIVE RUN. The
      Intersight accept/reboot parameter surface is checked at run time by
      Assert-IntersightUpgradeCmdletSurface, which stops the run rather than guessing if it differs.
#>

# -----------------------------
# User Settings
# -----------------------------

# Script version. Recorded in the console banner and stamped onto every row of the run summary
# and firmware verification CSVs, so any change record can be traced back to the exact revision
# that produced it. Bump this in the same commit as the change, and tag the commit to match
# (see CHANGELOG.md). Do not version by filename - git holds the history.
$ScriptVersion = "23.11.0"

$DefaultVCenter = "siepd24vsp0002.dpe.protected.mil.au"
$TargetEsxiVersion = "ESXi-8.0U3j-25429389"
$TargetEsxiBuild = if ($TargetEsxiVersion -match "(\d{7,})$") { $Matches[1] } else { "" }
$TargetUcsFirmwarePolicyName = ""

# Fabric-derived firmware policy. The FI family is read from the connected UCSM domain and mapped
# straight to a host firmware package, replacing the interactive policy picker.
#
# The value is the host firmware package name the service profiles are pointed at. Bundle versions
# are deliberately NOT held here. Where the package is missing it is created by NAME ONLY and left
# to use the global firmware setting that name refers to - the blade and rack bundles come from
# that setting, not from anything hard-coded in this script. Pinning versions here would let the
# script and the global setting disagree silently, and the script would win.
$Global:UcsFirmwarePolicyByFabricFamily = @{
    '6400' = 'global-602d'
    '6300' = 'global-436h'
}

# Resolved policy per UCSM domain, so a cluster spanning a 6300 and a 6400 domain gets the right
# one in each rather than a single cluster-wide choice.
$Global:UcsFirmwarePolicyByTarget = @{}

# Whether the run may CREATE a missing host firmware package. When false, a missing policy stops
# the run instead. Creation is always gated by an explicit confirmation and never happens in DRY RUN.

# Intersight PVA routing.
# CDP/LLDP remains the identity source for every host (same as the UCSM path below). A host whose
# normalised CDP/LLDP system name matches a row in this CSV is routed through Intersight PVA;
# everything else falls through unchanged to the existing UCS Manager logic.
# Expected CSV columns: Name (the Intersight Fabrics export column matched against CDP/LLDP system
# name), ServerProfileName (optional - defaults to Name if omitted), Moid (optional, speeds up lookup).
$IntersightCsvPath = "C:\temp\intersightfabric.csv"
# Default offered at the Intersight FQDN prompt. When an Intersight-managed fabric is detected the
# operator is asked for the appliance address, and their answer replaces this for the rest of the
# run - so this only needs changing if you want a different default in the prompt.
# BasePath is the appliance root only - no /api/v1 suffix and no trailing slash. The module
# appends the API path itself, and a trailing slash breaks HTTP signature validation.
$Global:IntersightBaseUrl = "https://intersight.com"           # PVA example: https://<pva-fqdn>
# Set automatically from the entered address: on for an on-prem PVA, off for intersight.com.
# Both default OFF, to match the minimal Set-IntersightConfiguration call proven to work against
# this PVA. -SkipCertificateCheck in particular changes the HTTP handler the module uses, and is a
# credible cause of the mangled response bodies that surface as "cannot be deserialized into any
# schema defined" - so it is no longer switched on automatically for on-prem appliances.
# Turn either on only if your appliance actually needs it.
$Global:IntersightSkipCertificateCheck = $false
$Global:IntersightHashAlgorithm = ""            # blank = omit; the module already defaults to SHA256
$Global:IntersightApiKeyPassPhrase = ""         # only for an encrypted key; the SDK errors without it
$Global:IntersightConfigurationApplied = $false # one-shot guard - see Connect-IntersightTarget

# REBOOT IMMEDIATELY TO ACTIVATE.
# Intersight stages a firmware change against the server profile and does not activate it until the
# server reboots. Without this acknowledgement the deploy is accepted, nothing restarts, and the run
# then waits out its post-reboot window for a reboot that was never going to happen.
$Global:IntersightRebootImmediatelyToActivate = $true

# It is carried by ProceedOnReboot on a PolicyScheduledAction, NOT by an action parameter. The
# SDK documents it in as many words: "ProceedOnReboot can be used to acknowledge server reboot
# while triggering deploy/activate."
#
#     $action = Initialize-IntersightPolicyScheduledAction -Action 'Activate' -ProceedOnReboot $true
#     Set-IntersightServerProfile -Moid <moid> -ScheduledActions @($action)
#
# ONE call - deploy and activate together. Captured from the GUI, which sends exactly this:
#     POST /api/v1/server/Profiles/<moid>
#     {"ScheduledActions":[{"Action":"Activate","ProceedOnReboot":true}]}
#
# Two earlier builds got this wrong in ways that both looked like success. One sent a
# PolicyActionParam named RebootImmediatelyToActivate - free-form strings, silently ignored. The
# other sent Action=Deploy on the scheduled action, which stages the firmware and then waits for a
# restart that never comes. Activate is the one that stages AND restarts.

# Any PolicyActionParam name/value pairs to send alongside, as @{ Name = '...'; Value = '...' }
# entries. Empty by default and not needed for the reboot acknowledgement.
$Global:IntersightDeployActionParams = @()

# How long to wait for a deployed profile to leave its staged state before deciding the appliance
# is going to wait for a reboot instead. Seconds, because this is an acceptance check and not the
# upgrade itself.
$Global:IntersightDeployAcceptedTimeoutSeconds = 180

# ACTIVATION POWER ACTION - INTERSIGHT ONLY.
# Staging the firmware works. When the appliance does not then restart the blade on its own, the
# run finds the server the profile is assigned to and power-cycles it through Intersight. vCenter
# is not involved: the reboot comes from the same place the firmware did.
#
# AdminPowerState values, from the SDK: Policy, PowerOn, PowerOff, PowerCycle (reset the server),
# HardReset, Shutdown, Reboot (reboots the IMC, NOT the server).
# PowerCycle is the one that activates staged firmware. Reboot is the trap - it restarts the
# management controller and leaves the server running, so it looks like something happened.
$Global:IntersightActivationPowerAction = 'PowerCycle'

# CEILINGS, NOT TIMERS. Progress through the activation is driven by what Intersight reports -
# the deploy workflow, then the firmware upgrade, then the profile state - and the run moves on the
# moment all three are clear, whether that is five minutes or fifty. These values only bound how
# long it will keep asking before handing the decision back to the operator. A firmware activation
# takes as long as it takes, and a run that treats a closed window as a failure is wrong more often
# than it is right.
$Global:IntersightActivationWaitMinutes = 60
# The ceiling on following an activation that has been accepted, through to the profile settling.
# The batch skips its own post-reboot wait once this has run, so a host is not held twice.
$Global:IntersightActivationHoldMinutes = 60
# How often to ask Intersight during those windows. The appliance is being asked for three small
# objects per poll, so this is cheap - but not free, and a whole batch polls in series.
$Global:IntersightPollIntervalSeconds = 30

# There is no cap on the number of retries. After each check the operator is asked RETRY or
# CONTINUE, so the run waits exactly as long as they want it to and never decides on its own that
# an activation has failed. See Invoke-IntersightActivationPowerCycle.

$Global:IntersightBaseUrlConfirmed = $false
# NOTE: Intersight's API only supports API-key + HTTP-signature auth (key ID + private key file) -
# there is no username/password endpoint. Get-IntersightCredentialIfNeeded below still prompts
# interactively and holds the material in memory only, matching the hardened UCSM pattern, but what
# it collects is an API Key ID and the path to the associated private key (.pem), not a password.
$Global:IntersightApiKeyId = ""
$Global:IntersightApiKeyFilePath = ""
$Global:IntersightSession = $null
$Global:IntersightServerList = @{}
$Global:IntersightHostMap = @{}
$Global:IntersightProfileCache = @{}
$Global:IntersightUpgradeSurfaceChecked = $false
# ConfigState values that mean the profile has staged changes not yet on the server, and so needs
# a deploy. A firmware policy update normally lands in Pending-changes, NOT Inconsistent.
# Matching ignores case, spaces, hyphens and underscores.
$Global:IntersightActionableConfigStates = @(
    'Pending-changes',
    'Inconsistent',
    'Out-of-sync',
    'Not-deployed'
)
$Global:BatchActionsSent = 0
# Boot time per host, captured before the reboot is requested. The reconnect gate compares against
# it so that "the host is Connected" cannot be mistaken for "the host came back".
$Global:PreRebootBootTimes = @{}
$Global:ModuleVersionCache = @{}
$Global:SlowModulePathReported = $false
$Global:IntersightUnusable = $false
$Global:IntersightUnusableReason = ""
$Global:IntersightSkippedHosts = @{}
$Global:EsxiDiscoveryCache = @{}

# Hosts this run could not finish by itself, and why. Nothing here stops the run - a host that
# cannot be driven is set aside so the REST OF THE CLUSTER STILL GETS DONE, and named at the end
# so it is handed over rather than lost. A run that stops on the first unreachable host leaves an
# operator with one broken host and a cluster's worth of un-upgraded ones.
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:CurrentClusterName = ""
# The subset that must not be batched at all - no service profile, no Intersight route, or not
# reachable from vCenter. Filtered out of the candidate list alongside IntersightSkippedHosts.
$Global:ExcludedFromRunHosts = @{}

$ResourceSafetyBuffer = 0.85
$MinimumCpuHeadroomPercentAfterBatch = 10
$MinimumMemoryHeadroomPercentAfterBatch = 10
# Hard ceiling on how many hosts may be out of service at once, as a FRACTION of the cluster.
# 0.5 = never more than half. Capacity, DRS headroom and the resource buffer remain the PRIMARY
# constraint and normally bind first; this only stops a large, idle cluster being emptied faster
# than DRS and storage can keep up with.
# Replaces a fixed cap of 6 at the operator's direction: on a 24-host cluster that was an arbitrary
# throttle well below what the cluster could carry.
$MaxConcurrentHostFraction = 0.5
# Optional absolute ceiling on top of the fraction. 0 means no fixed cap - the fraction and the
# capacity arithmetic decide.
$MaxAbsoluteBatchSize = 0
$MaintenanceValidationTimeoutMinutes = 60
$EsxiOnlyReconnectInitialWaitMinutes = 15
# Raised from 40 to 60 minutes at the operator's direction, to cover the firmware activity itself.
$FirmwareReconnectInitialWaitMinutes = 60
$ReconnectRetryWindowMinutes = 5
$ReconnectCheckIntervalSeconds = 60

# A host that has just re-registered with vCenter is not settled. hostd and the profile engine are
# still starting and Auto Deploy may still be applying the answer file, so a compliance scan run in
# that window reports differences that clear themselves a few minutes later. Read as real they stop
# the batch and send an operator hunting a fault that is not there. Waited once per batch, after the
# reconnect gate confirms every host is back, before the first scan.
#
# Raised from 2 to 8 minutes at the operator's direction: two minutes was not covering the profile
# engine's own work on a freshly rebooted host, so the first scan was answering too early.
$HostProfileComplianceSettleMinutes = 8
# Bound on waiting for a compliance check vCenter or Auto Deploy started itself to finish before
# this run starts its own, so the scan that answers is the one whose result is acted on.
$HostProfileComplianceScanTimeoutMinutes = 10
# Bound on waiting for a host to actually leave Maintenance mode after being told to. vCenter
# reports the old state briefly, and the cluster health check that follows fails on any host still
# in Maintenance - so the run must see the transition land before it moves on.
$ExitMaintenanceTimeoutMinutes = 10

# PowerCLI holds one HTTP request open per blocking task and defaults to a 300-second ceiling,
# which is shorter than a host evacuation. Raised for the session at vCenter connect time.
$PowerCliWebOperationTimeoutSeconds = 3600

$RunDirectory = (Get-Location).Path
$RunTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$SummaryPath = Join-Path $RunDirectory "AutoDeploy-UCSM-Firmware-Batch-Summary-$RunTimestamp.csv"
$Global:RunSummary = New-Object System.Collections.Generic.List[object]

# DRYRUN or LIVE. Those are the only two - see Select-RunMode.
$Global:RunMode = "DRYRUN"
$Global:UpgradeMode = "ESXI_UCS_FIRMWARE" # ESXI_ONLY or ESXI_UCS_FIRMWARE
$Global:UcsCredential = $null
$Global:UcsSessions = @{}
$Global:UcsHostMap = @{}
$Global:UcsServiceProfileCache = @{}
# ESXi root credential for the cluster being worked on. Collected once when the cluster is
# selected, held only in memory for the run, and cleared per cluster.
#
# It exists for one job: a host that reboots but comes back DISCONNECTED in vCenter because
# vCenter's stored password for it no longer works. vCenter cannot reconnect it on its own, the
# host sits there disconnected, and the run waits out its whole window for something that will
# never resolve itself. With the root password to hand the run reconnects it and carries on.
$Global:EsxiRootCredential = $null
# How long a host must be seen DISCONNECTED before the root credential is used to reconnect it.
# Short enough not to waste the change window, long enough not to fight a host that is simply
# still coming up - vCenter reports Disconnected briefly during a normal boot.
$HostReconnectAfterDisconnectMinutes = 5
# How many times the ESXi root credential is used on a host vCenter has dropped, and how long to
# wait between those attempts. One attempt was not enough: a host that has just rebooted onto new
# firmware can refuse the reconnect while hostd is still coming up, and the run then wrote it off
# as unrecoverable when a second attempt two minutes later would have taken it. After the last
# attempt the operator is asked, rather than the host being silently abandoned.
# How long to wait for UCS Manager to raise the pending activity after a firmware package change.
# It is raised asynchronously, so asking the instant the policy write returns finds nothing on a
# busy domain - and a batch that acknowledges nothing leaves its blades staged and waiting.
$UcsPendingAckWaitMinutes = 5
$HostReconnectMaxAttempts = 3
$HostReconnectRetryPauseMinutes = 2
# How long to spend proving a management endpoint answers at all before deciding the path is
# blocked. Applies to UCS Manager and to Intersight. A blocked port does not refuse a connection,
# it drops the packet - so the client sits there until ITS timeout, which is minutes, with nothing
# on screen. Sixty seconds is long enough for a slow appliance and short enough to be told about.
$ManagementEndpointProbeTimeoutSeconds = 60
$Global:AutoExitMaintenanceMode = $true
$Global:RequiredModulesLoaded = $false
$Global:PrerequisitesConfirmed = $false

# -----------------------------
# Generic helpers
# -----------------------------

function Add-SummaryRecord {
    param([string]$Stage,[string]$Batch,[string]$HostName,[string]$Action,[string]$Result,[string]$Details="")
    $Global:RunSummary.Add([pscustomobject]@{ TimeStamp=Get-Date; ScriptVersion=$ScriptVersion; Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details })
}

function Export-RunSummary {
    try {
        if ($Global:RunSummary.Count -gt 0) {
            $Global:RunSummary | Export-Csv -Path $SummaryPath -NoTypeInformation -Encoding UTF8
            Write-Host "Run summary exported to: $SummaryPath" -ForegroundColor Green
        }
    } catch { Write-Host "Failed to export summary CSV: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function Stop-SafeExit {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host "`nSAFE EXIT REQUESTED" -ForegroundColor Yellow
    Write-Host $Message -ForegroundColor Yellow
    Write-Host "If any host is already in Maintenance mode, manually exit Maintenance mode in vCenter before leaving the change window." -ForegroundColor Yellow
    Add-SummaryRecord -Stage "SafeExit" -Batch "" -HostName "" -Action "Safe exit" -Result "Stopped" -Details $Message
    Export-RunSummary
    throw "SAFE_EXIT"
}

function Stop-WithMessage {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host "`n$Message" -ForegroundColor Red
    # Same warning Stop-SafeExit gives. A stop can land mid-batch with hosts already evacuated,
    # and leaving them in Maintenance mode without saying so costs cluster capacity silently.
    Write-Host "If any host is already in Maintenance mode, exit Maintenance mode in vCenter before leaving the change window." -ForegroundColor Yellow
    Add-SummaryRecord -Stage "Stop" -Batch "" -HostName "" -Action "Stop workflow" -Result "Stopped" -Details $Message
    Export-RunSummary
    throw "STOP_WORKFLOW"
}

function Read-ChoiceExit {
    <#
    .SYNOPSIS
        Asks for one of a fixed set of answers, with EXIT always available.

    .DESCRIPTION
        E is accepted as EXIT so that the single-letter prompts read the same way as the timed
        waits, where E has always meant exit. No prompt in this script offers E as a choice of its
        own, so the alias cannot shadow a real answer.
    #>
    param([Parameter(Mandatory=$true)][string]$Message,[Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$AllowedChoices,[string]$ExitMessage="Script stopped at a safe checkpoint by implementor.")
    # Every choice in this script is a SINGLE KEY. The words are still accepted as aliases so an
    # operator who types CONTINUE out of habit is not told they are wrong, but the prompt asks for
    # one letter and that is what the screen offers.
    $wordAliases = @{
        CONTINUE = "C"; RETRY = "R"; RECHECK = "R"; SKIP = "S"; STOP = "X"
        OVERRIDE = "O"; CREATE = "C"; YES = "Y"; NO = "N"
    }

    $normalizedAllowed = @($AllowedChoices | ForEach-Object { $_.ToString().ToUpper() })
    do {
        $answer = (Read-Host "$Message [$($normalizedAllowed -join '/') or E to exit]").Trim().ToUpper()
        if ($wordAliases.ContainsKey($answer) -and $normalizedAllowed -contains $wordAliases[$answer]) {
            $answer = $wordAliases[$answer]
        }
        if ($answer -eq "E" -and $normalizedAllowed -notcontains "E") { $answer = "EXIT" }
        if ($answer -eq "EXIT") { Stop-SafeExit -Message $ExitMessage }
    } until ($normalizedAllowed -contains $answer)
    return $answer
}

function Test-DryRun { return ($Global:RunMode -eq "DRYRUN") }

function Show-OpenFileDialog {
    <#
    .SYNOPSIS
        Opens a Windows file picker and returns the selected path, or "" if unavailable/cancelled.

    .DESCRIPTION
        OpenFileDialog requires an STA thread. The Windows PowerShell 5.1 console is STA, but
        PowerShell 7 runs MTA, so on 7 the dialog is marshalled onto a dedicated STA runspace.
        Any failure - no GUI, no Windows Forms, remote session - returns "" so the caller can
        fall back to a typed path rather than breaking an otherwise headless run.

    .PARAMETER Title
        Dialog window title.

    .PARAMETER Filter
        Win32 filter string, e.g. "PEM files (*.pem)|*.pem|All files (*.*)|*.*".

    .PARAMETER InitialDirectory
        Folder to open at, when it exists.
    #>
    param(
        [string]$Title = "Select a file",
        [string]$Filter = "All files (*.*)|*.*",
        [string]$InitialDirectory = ""
    )

    $dialogScript = {
        param($Title, $Filter, $InitialDirectory)
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Title = $Title
            $dialog.Filter = $Filter
            $dialog.Multiselect = $false
            $dialog.CheckFileExists = $true
            if (-not [string]::IsNullOrWhiteSpace($InitialDirectory) -and (Test-Path -Path $InitialDirectory)) {
                $dialog.InitialDirectory = $InitialDirectory
            }
            # Parent the dialog to a topmost form, otherwise it can open behind the console.
            $anchor = New-Object System.Windows.Forms.Form
            $anchor.TopMost = $true
            $anchor.ShowInTaskbar = $false
            if ($dialog.ShowDialog($anchor) -eq [System.Windows.Forms.DialogResult]::OK) {
                $anchor.Dispose()
                return $dialog.FileName
            }
            $anchor.Dispose()
            return ""
        }
        catch { return "" }
    }

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
        return [string](& $dialogScript $Title $Filter $InitialDirectory)
    }

    $ps = $null
    $runspace = $null
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()

        $ps = [PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($dialogScript.ToString()).AddArgument($Title).AddArgument($Filter).AddArgument($InitialDirectory)
        $output = $ps.Invoke()
        return [string](@($output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    }
    catch { return "" }
    finally {
        if ($ps) { $ps.Dispose() }
        if ($runspace) { $runspace.Close(); $runspace.Dispose() }
    }
}

function Get-AvailableModuleVersion {
    <#
    .SYNOPSIS
        Cached Get-Module -ListAvailable for one module, with progress and slow-path diagnosis.

    .DESCRIPTION
        Get-Module -ListAvailable walks every entry in $env:PSModulePath and parses each manifest
        it finds. For Intersight.PowerShell, whose manifest exports several thousand cmdlets, that
        is slow - and it was being repeated at five separate points in this script, with no output
        in between, which reads exactly like a hang.

        Each module is enumerated once and the result reused. The first lookup is timed, and if it
        is slow the likely reason is reported: a network or mapped-drive entry in PSModulePath,
        where enumeration can take minutes.

    .PARAMETER Name
        Module name.

    .PARAMETER Refresh
        Ignore the cache and re-enumerate.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [switch]$Refresh
    )

    if (-not $Refresh -and $Global:ModuleVersionCache.ContainsKey($Name)) {
        return $Global:ModuleVersionCache[$Name]
    }

    Write-Host "  Looking for $Name..." -ForegroundColor DarkGray -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $found = @()
    try { $found = @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue | Sort-Object Version -Descending) } catch {}
    $sw.Stop()

    $seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-Host " $($found.Count) found in ${seconds}s" -ForegroundColor DarkGray

    if ($sw.Elapsed.TotalSeconds -gt 15 -and -not $Global:SlowModulePathReported) {
        $Global:SlowModulePathReported = $true
        Write-Host "  NOTE: module discovery is slow (${seconds}s). PSModulePath entries:" -ForegroundColor Yellow
        foreach ($entry in ($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })) {
            $remote = ($entry -like '\\\\*') -or ($entry -match '^[A-Za-z]:\\' -and (Test-Path $entry -ErrorAction SilentlyContinue) -eq $false)
            $marker = if ($remote) { "  <- network or unavailable path, likely the cause" } else { "" }
            Write-Host "    $entry$marker" -ForegroundColor Yellow
        }
        Write-Host "  Removing unreachable or network entries from PSModulePath speeds this up considerably." -ForegroundColor Yellow
    }

    $Global:ModuleVersionCache[$Name] = $found
    return $found
}

function Import-RequiredModules {
    <#
    .SYNOPSIS
        Loads the modules this run needs, once, and only where they are not already loaded.

    .DESCRIPTION
        This script relied on PowerShell auto-loading every module on first use. On a prepared jump
        host that is fine. In a VS Code / PowerShell Integrated Console session it is not, and the
        reported symptom was exactly that: on random servers the modules were not loading into the
        Visual Studio Code session, and cmdlets came back "not recognized".

        Auto-loading depends on the command discovery cache, and building it means walking every
        path in $env:PSModulePath. Intersight.PowerShell exports several thousand cmdlets and
        PowerCLI is dozens of modules, so on a cold cache - a new session, a network module path, a
        roaming profile share - a reference can be resolved before the scan has reached the module.
        The scan then finishes, which is why the SECOND run in the same session works.

        Loading here is safe against the thing the no-imports rule was protecting: each load is
        guarded by Get-Module, so a module already present - including a deliberately pinned
        bundle - is left exactly as it is. Nothing is installed, nothing is updated, and no version
        is chosen.

        Nothing here is fatal. A module that will not load is reported with what was tried, and the
        run continues to the checks that can say precisely what is missing and why it matters:
        Assert-IntersightPowerShellAvailable, Assert-UcsPowerToolAvailable and Connect-VCenterServer.

    .EXAMPLE
        Import-RequiredModules
    #>
    if ($Global:RequiredModulesLoaded) { return }
    $Global:RequiredModulesLoaded = $true

    # Name, and what it is for. Alternatives are for products whose module was renamed between
    # releases - the first one present wins and the rest are not looked at.
    $wanted = @(
        [pscustomobject]@{ Purpose = "vCenter (PowerCLI)"; Names = @("VMware.VimAutomation.Core") }
        [pscustomobject]@{ Purpose = "Intersight";         Names = @("Intersight.PowerShell") }
        [pscustomobject]@{ Purpose = "UCS Manager";        Names = @("Cisco.UCSManager", "Cisco.UCS.Core", "CiscoUcsPS") }
    )

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Loading the modules this run needs (already-loaded modules are left untouched)..." -ForegroundColor Cyan

    foreach ($entry in $wanted) {
        $loaded = $false
        $tried = New-Object System.Collections.Generic.List[string]

        foreach ($name in $entry.Names) {
            if (Get-Module -Name $name) {
                Write-Host "  $($entry.Purpose): $name already loaded." -ForegroundColor DarkGray
                $loaded = $true
                break
            }
        }
        if ($loaded) { continue }

        foreach ($name in $entry.Names) {
            # Straight to the import. No availability probe in front of it: Get-Module
            # -ListAvailable walks every entry in $env:PSModulePath and parses each manifest it
            # finds, which for Intersight.PowerShell is slow enough on a network module path to
            # read as a hang - and it answers a question the import itself already answers. A
            # module that is not installed throws here and is recorded by the catch below.
            try {
                Import-Module -Name $name -ErrorAction Stop
                Write-Host "  $($entry.Purpose): loaded $name." -ForegroundColor Green
                Add-SummaryRecord -Stage "ModuleLoad" -Batch "" -HostName "" -Action "Load module" -Result "Loaded" -Details "$($entry.Purpose) - $name."
                $loaded = $true
                break
            }
            catch {
                [void]$tried.Add("$name ($($_.Exception.Message))")
            }
        }

        if (-not $loaded) {
            Write-Host "  $($entry.Purpose): not loaded. Tried: $($tried.ToArray() -join '; ')" -ForegroundColor Yellow
            Write-Host "    Not fatal here - the check for this product will say what is missing when it is needed." -ForegroundColor DarkGray
            Add-SummaryRecord -Stage "ModuleLoad" -Batch "" -HostName "" -Action "Load module" -Result "NotLoaded" -Details "$($entry.Purpose) - tried: $($tried.ToArray() -join '; ')"
        }
    }
}

function Confirm-RunPrerequisites {
    <#
    .SYNOPSIS
        Prints the run requirements. Asks nothing and verifies nothing.

    .DESCRIPTION
        Informational only - there is no prompt here. The environment is assumed to meet the
        requirements listed, which are also in the script header.

        Nothing is probed either. Enumerating Intersight.PowerShell, whose manifest exports several
        thousand cmdlets, took long enough on a domain jump host to read as a hang.

        Failures still surface, just later and where they matter: a missing module fails at its
        first cmdlet, the Intersight login happens before any host is touched, and a missing CSV
        stops the run at Import-IntersightServerCsv.
    #>
    if ($Global:PrerequisitesConfirmed) { return }

    # First, before anything reads a cmdlet name. See Import-RequiredModules for why leaving this
    # to auto-loading failed on some sessions and not others.
    Import-RequiredModules

    Write-Host "" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host " REQUIREMENTS - assumed present, not verified here" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan

    Write-Host "1. PowerShell modules" -ForegroundColor Yellow
    Write-Host "     PowerShell 7 (Core) - Intersight.PowerShell is a binary module built for it." -ForegroundColor Gray
    Write-Host "     VMware PowerCLI 12.3.0 or newer." -ForegroundColor Gray
    Write-Host "     Intersight.PowerShell - ONE version, matching the appliance release." -ForegroundColor Gray
    Write-Host "     Cisco UCS PowerTool - only if a host in scope is UCS Manager-managed." -ForegroundColor Gray
    Write-Host "     Loaded above where they were not already in the session; nothing is installed" -ForegroundColor Gray
    Write-Host "     or upgraded, and a module already loaded is left exactly as it is." -ForegroundColor Gray

    Write-Host "2. Intersight API key" -ForegroundColor Yellow
    Write-Host "     API Key ID - three segments, e.g. aaaa/bbbb/cccc." -ForegroundColor Gray
    Write-Host "     The matching private key (.pem) file, on this machine." -ForegroundColor Gray
    Write-Host "     Both are issued together under Settings > API Keys, and the secret key can" -ForegroundColor Gray
    Write-Host "     only be downloaded when the key is created. If you no longer have that file," -ForegroundColor Gray
    Write-Host "     generate a new API key before starting." -ForegroundColor Gray
    Write-Host "     You are prompted for these, and for the appliance FQDN, when an Intersight" -ForegroundColor Gray
    Write-Host "     fabric is first detected. Required only if a host in scope is Intersight-managed." -ForegroundColor Gray

    Write-Host "3. Intersight input file" -ForegroundColor Yellow
    Write-Host "     $IntersightCsvPath" -ForegroundColor Gray
    Write-Host "     Column: Name - the fabric name matched against each host's CDP/LLDP neighbour." -ForegroundColor Gray
    Write-Host "     Optional columns: ServerProfileName, Moid." -ForegroundColor Gray
    Write-Host "     A host matching a row is driven through Intersight; anything else through UCS" -ForegroundColor Gray
    Write-Host "     Manager. Required only if any host in scope is Intersight-managed." -ForegroundColor Gray
    Write-Host "     $(if (Test-Path $IntersightCsvPath) { 'Present.' } else { 'NOT FOUND at that path.' })" -ForegroundColor $(if (Test-Path $IntersightCsvPath) { 'Gray' } else { 'Red' })

    Write-Host "4. Credentials to hand" -ForegroundColor Yellow
    Write-Host "     vCenter and UCS Manager, for the prompts that follow." -ForegroundColor Gray

    Write-Host "5. Host profile - Security settings to untick BEFORE starting" -ForegroundColor Yellow
    Write-Host "     In the host profile attached to the hosts in scope, under Security, UNTICK:" -ForegroundColor Gray
    Write-Host "       - Authentication Configuration" -ForegroundColor Gray
    Write-Host "       - Active Directory Permission" -ForegroundColor Gray
    Write-Host "     Left ticked, the profile will not apply cleanly to a host that has just" -ForegroundColor Gray
    Write-Host "     rebooted and rejoined, and the compliance gate in this run will halt on it." -ForegroundColor Gray
    Write-Host "     RE-ENABLE BOTH AFTER THE UPGRADE IS COMPLETE. This run does not change them" -ForegroundColor Red
    Write-Host "     and does not put them back - that is a manual step at the end of the change." -ForegroundColor Red

    Write-Host "6. Manual health checks and change gates" -ForegroundColor Yellow
    Write-Host "     Completed and accepted BEFORE starting. The run does not ask again." -ForegroundColor Gray
    Write-Host "     Everything it can check itself it checks per batch - cluster health, capacity," -ForegroundColor Gray
    Write-Host "     datastore free space, host profile compliance - and stops if any of them fail." -ForegroundColor Gray
    Write-Host "     What it cannot see is the change record: approval, window, and whatever your" -ForegroundColor Gray
    Write-Host "     process requires signed off. That is yours to have done by this point." -ForegroundColor Gray

    Write-Host "=====================================================================" -ForegroundColor Cyan

    Add-SummaryRecord -Stage "PreFlight" -Batch "" -HostName "" -Action "State requirements" -Result "Displayed" -Details "CSV=$IntersightCsvPath; CsvPresent=$(Test-Path $IntersightCsvPath); Intersight configured by the caller."
    $Global:PrerequisitesConfirmed = $true
}

function Add-ManualAttentionHost {
    <#
    .SYNOPSIS
        Records a host this run could not finish, for the report printed when the cluster completes.

    .DESCRIPTION
        Called instead of stopping. The run carries on with every other host in the cluster and the
        entry is printed at the end, so the operator leaves with a list to work through rather than
        a run that halted on the first problem.

        -ExcludeFromRun additionally keeps the host out of the batches. Use it when there is
        genuinely nothing that can be driven - no CDP/LLDP identity, no service profile, or the
        host is not reachable from vCenter. Without it, the host is still processed and the entry
        is a note against it (an accepted override, firmware left staged, and so on).

        Repeat calls for the same host and reason are collapsed, so a per-batch condition does not
        print the same line five times.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [Parameter(Mandatory=$true)][string]$Reason,
        [string]$Detail = "",
        [string]$ClusterName = "",
        [switch]$ExcludeFromRun
    )

    # Defaults to the cluster being worked on, so no caller has to thread it through.
    if ([string]::IsNullOrWhiteSpace($ClusterName)) { $ClusterName = [string]$Global:CurrentClusterName }

    if ($ExcludeFromRun) { $Global:ExcludedFromRunHosts[$HostName] = $Reason }

    $existing = @($Global:ManualAttentionHosts | Where-Object { $_.Host -eq $HostName -and $_.Reason -eq $Reason })
    if ($existing.Count -gt 0) {
        # Keep the latest detail - a second occurrence usually carries the more useful message.
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { $existing[0].Detail = $Detail }
        return
    }

    $Global:ManualAttentionHosts.Add([pscustomobject]@{
        Cluster = $ClusterName
        Host    = $HostName
        Reason  = $Reason
        Detail  = $Detail
        Excluded = [bool]$ExcludeFromRun
    })
}

function Show-ManualAttentionReport {
    <#
    .SYNOPSIS
        Prints the hosts that need a human, once the cluster is complete.

    .DESCRIPTION
        The closing hand-over. Everything the run set aside rather than stopped for is listed here
        with the reason, so the change record does not rest on someone having watched the scroll.

        Printed even when the list is empty - "nothing outstanding" is a result worth stating, and
        a report that only appears on failure is one nobody trusts is running.
    #>
    param([string]$ClusterName = "")

    # .ToArray(), not @(...). Wrapping a Generic.List[object] in an array subexpression throws
    # "Argument types do not match" on this PowerShell build - and it throws AFTER the cluster has
    # completed, which is the worst possible place to learn it. Caught by the workflow simulation.
    $rows = $Global:ManualAttentionHosts.ToArray()
    if (-not [string]::IsNullOrWhiteSpace($ClusterName)) {
        $rows = @($rows | Where-Object { $_.Cluster -eq $ClusterName -or [string]::IsNullOrWhiteSpace($_.Cluster) })
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host " HOSTS REQUIRING MANUAL RECTIFICATION$(if ($ClusterName) { " - $ClusterName" })" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan

    if ($rows.Count -eq 0) {
        Write-Host "None. Every host in scope was completed by this run." -ForegroundColor Green
    }
    else {
        $rows | Sort-Object Host | Select-Object Host,Reason,Detail | Format-Table -AutoSize -Wrap | Out-Host
        Write-Host "$($rows.Count) host(s) above need attention before this change can be called complete." -ForegroundColor Yellow
        $excluded = @($rows | Where-Object { $_.Excluded })
        if ($excluded.Count -gt 0) {
            Write-Host "Of those, $($excluded.Count) were never batched and have NOT been upgraded: $(($excluded | Select-Object -ExpandProperty Host | Sort-Object) -join ', ')" -ForegroundColor Yellow
        }
        foreach ($row in $rows) {
            Add-SummaryRecord -Stage "ManualAttention" -Batch "" -HostName $row.Host -Action "Manual rectification required" -Result $(if ($row.Excluded) { "NotUpgraded" } else { "Outstanding" }) -Details "$($row.Reason). $($row.Detail)"
        }
    }

    Write-Host "" -ForegroundColor Yellow
    Write-Host "REMINDER: re-enable 'Authentication Configuration' and 'Active Directory Permission'" -ForegroundColor Yellow
    Write-Host "under Security in the host profile now the upgrade is done. This run did not change" -ForegroundColor Yellow
    Write-Host "them and has not put them back." -ForegroundColor Yellow
    Write-Host "=====================================================================" -ForegroundColor Cyan
}

function Read-PendingConsoleKey {
    <#
    .SYNOPSIS
        Returns the pending keypress as an upper-case string, or "" if none is waiting.

    .DESCRIPTION
        [Console]::KeyAvailable throws when the host has no interactive console - a redirected
        stdin, the ISE, or a scheduled task. Left unguarded that turns a timed wait into an
        unhandled error mid-change. Here it degrades to "no key pressed", so the wait simply
        runs to its timeout.
    #>
    try {
        if ([Console]::KeyAvailable) {
            return [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
        }
    } catch {}
    return ""
}

function Test-TcpPortOpen {
    <#
    .SYNOPSIS
        Can a TCP connection be opened to this host and port within the timeout? Never throws.

    .DESCRIPTION
        BeginConnect plus a bounded WaitOne, because a synchronous connect cannot be given a
        timeout - and the case this exists for is precisely the one that hangs. A firewall that
        DENIES a port sends a reset and the connect fails immediately; a firewall that DROPS it
        sends nothing, and the client waits out its own timeout with no output at all.

        Name resolution failures land in the catch and read as "not open", which is correct for
        the question being asked: the endpoint cannot be reached from this jump box.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { if ($null -ne $client) { try { $client.Close() } catch { } } }
}

function Get-EndpointHostName {
    <#
    .SYNOPSIS
        Strips a URL or a decorated target down to the bare host name the socket needs.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Target)
    $value = [string]$Target
    $value = $value -replace '^\s*https?://', ''
    $value = $value.Split('/')[0]
    # Bare IPv6 is left alone; a host:port form is not, because the port is supplied separately.
    if ($value -notmatch ':.*:' -and $value.Contains(':')) { $value = $value.Split(':')[0] }
    return $value.Trim()
}

function Test-ManagementEndpointReachable {
    <#
    .SYNOPSIS
        Proves a management endpoint answers on HTTPS or HTTP within the probe budget.

    .DESCRIPTION
        Asked before the expensive login, for UCS Manager and for Intersight alike. Both speak
        HTTPS, so 443 is tried first and gets the larger share of the budget; 80 is tried after,
        only to tell "nothing at all gets through" apart from "TLS is the problem", because those
        two point at different teams.

        Returns a result rather than throwing. Whether an unreachable endpoint stops the run is the
        caller's decision, not this function's.
    #>
    param(
        # AllowEmptyString because "there is no endpoint configured" is one of the answers this is
        # meant to give, not a parameter-binding error thrown from underneath the caller.
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Target,
        [int]$TimeoutSeconds = 60
    )

    $hostName = Get-EndpointHostName -Target $Target
    $started = Get-Date

    if ([string]::IsNullOrWhiteSpace($hostName)) {
        return [pscustomobject]@{ Reachable = $false; Port = 0; HostName = ""; ElapsedSeconds = 0; Detail = "No host name could be taken from '$Target'." }
    }

    # Two thirds to HTTPS, the rest to HTTP, so the whole probe stays inside the budget.
    $httpsBudget = [int][Math]::Max(5, [Math]::Floor($TimeoutSeconds * 2 / 3))
    $httpBudget  = [int][Math]::Max(5, $TimeoutSeconds - $httpsBudget)

    if (Test-TcpPortOpen -ComputerName $hostName -Port 443 -TimeoutSeconds $httpsBudget) {
        return [pscustomobject]@{ Reachable = $true; Port = 443; HostName = $hostName
            ElapsedSeconds = [int]((Get-Date) - $started).TotalSeconds; Detail = "TCP 443 answered." }
    }

    if (Test-TcpPortOpen -ComputerName $hostName -Port 80 -TimeoutSeconds $httpBudget) {
        return [pscustomobject]@{ Reachable = $true; Port = 80; HostName = $hostName
            ElapsedSeconds = [int]((Get-Date) - $started).TotalSeconds; Detail = "TCP 443 did not answer, but TCP 80 did." }
    }

    return [pscustomobject]@{ Reachable = $false; Port = 0; HostName = $hostName
        ElapsedSeconds = [int]((Get-Date) - $started).TotalSeconds
        Detail = "Neither TCP 443 nor TCP 80 answered within $TimeoutSeconds second(s)." }
}

function Confirm-ManagementEndpointReachable {
    <#
    .SYNOPSIS
        Probes an endpoint and, if nothing answers, says so plainly and asks what to do.

    .DESCRIPTION
        Put in front of the UCS Manager and Intersight logins because the failure they produce on
        their own is useless. A dropped packet gives the PowerTool or the Intersight client no
        error to report until its own timeout expires, minutes later, and what it prints then talks
        about credentials - which sends the operator to the wrong team.

        The message names the jump box, the endpoint and both ports, so the request that follows
        is a firewall request with the detail already in it.

        R re-probes, for the common case where the rule is being raised while the run waits.
        C continues anyway - the probe is evidence, not proof, and an endpoint reachable only
        through a proxy would fail it while the client still works. E exits.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Target,
        [Parameter(Mandatory=$true)][string]$DeviceKind,
        [int]$TimeoutSeconds = 60
    )

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        Write-Host "Checking that $DeviceKind '$Target' is reachable from this jump box (up to $TimeoutSeconds second(s))..." -ForegroundColor Cyan
        $probe = Test-ManagementEndpointReachable -Target $Target -TimeoutSeconds $TimeoutSeconds

        if ($probe.Reachable) {
            Write-Host "  Reachable on TCP $($probe.Port) after $($probe.ElapsedSeconds) second(s)." -ForegroundColor Green
            Add-SummaryRecord -Stage "EndpointReachability" -Batch "" -HostName "" -Action "Probe $DeviceKind" -Result "Reachable" -Details "$Target - $($probe.Detail)"
            return $true
        }

        Write-Host "" -ForegroundColor Red
        Write-Host "=====================================================================" -ForegroundColor Red
        Write-Host " $($DeviceKind.ToUpper()) IS NOT ACCESSIBLE FROM THIS JUMP BOX" -ForegroundColor Red
        Write-Host "=====================================================================" -ForegroundColor Red
        Write-Host "  Endpoint : $($probe.HostName)" -ForegroundColor Yellow
        Write-Host "  From     : $env:COMPUTERNAME as $env:USERNAME" -ForegroundColor Yellow
        Write-Host "  Result   : $($probe.Detail)" -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        Write-Host "  Nothing answered on HTTPS (443) or HTTP (80), so this is a network path" -ForegroundColor Yellow
        Write-Host "  problem, not a credential problem. A FIREWALL RULE MAY NEED TO BE RAISED" -ForegroundColor Yellow
        Write-Host "  to allow this jump box to reach $($probe.HostName) on TCP 443." -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        Write-Host "  Worth confirming before raising it:" -ForegroundColor Yellow
        Write-Host "    - the name resolves from here      : Resolve-DnsName $($probe.HostName)" -ForegroundColor Gray
        Write-Host "    - the port is what is blocked       : Test-NetConnection $($probe.HostName) -Port 443" -ForegroundColor Gray
        Write-Host "    - you are on the right jump box for this environment" -ForegroundColor Gray
        Write-Host "=====================================================================" -ForegroundColor Red

        Add-SummaryRecord -Stage "EndpointReachability" -Batch "" -HostName "" -Action "Probe $DeviceKind" -Result "Unreachable" -Details "$Target - $($probe.Detail) Probed from $env:COMPUTERNAME."

        $choice = Read-ChoiceExit `
            -Message "$DeviceKind '$Target' did not answer. R to probe again, C to continue anyway, E to exit" `
            -AllowedChoices @("R","C") `
            -ExitMessage "Stopped because $DeviceKind '$Target' is not reachable from this jump box."
        if ($choice -eq "C") {
            Write-Host "  Continuing anyway - the login will be attempted and may still fail." -ForegroundColor Yellow
            Add-SummaryRecord -Stage "EndpointReachability" -Batch "" -HostName "" -Action "Probe $DeviceKind" -Result "Overridden" -Details "$Target - operator continued past an unreachable endpoint."
            return $false
        }
    }

    return $false
}

# -----------------------------
# Hardened UCSM login and discovery
# -----------------------------

function Assert-UcsPowerToolAvailable {
    if ($Global:UpgradeMode -ne "ESXI_UCS_FIRMWARE") { return }
    if ($null -eq (Get-Command -Name Connect-Ucs -ErrorAction SilentlyContinue)) {
        Stop-WithMessage "Cisco UCS PowerTool cmdlet Connect-Ucs was not found. Import Cisco UCS PowerTool before firmware mode."
    }
}

function Clear-ExistingUcsSessions {
    param([string]$Reason = "Preparing for scripted UCSM login")

    if ($Global:UpgradeMode -ne "ESXI_UCS_FIRMWARE") { return }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "UCSM session cleanup: $Reason" -ForegroundColor Cyan

    # Clear any UCS PowerTool sessions already open in this PowerShell process.
    # This prevents "multiple DefaultUcs not allowed" and stale UCS handle issues.
    try {
        Get-UcsPSSession -ErrorAction SilentlyContinue | ForEach-Object {
            Disconnect-Ucs -Ucs $_ -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {
        Write-Host "Could not disconnect existing UCS PowerTool sessions. Continuing. $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Clear DefaultUcs exactly as tested manually.
    try {
        Remove-Variable -Name DefaultUcs -Scope Global -ErrorAction SilentlyContinue
    }
    catch {}

    # Reset script-local UCS session caches after UCS cleanup. The service profile cache is keyed
    # by UCSM target and is only valid for a live session, so it goes with them.
    $Global:UcsSessions = @{}
    $Global:UcsServiceProfileCache = @{}

    try {
        $remainingSessions = @(Get-UcsPSSession -ErrorAction SilentlyContinue)
        if ($remainingSessions.Count -eq 0) {
            Write-Host "Existing UCS PowerTool sessions cleared." -ForegroundColor Green
        }
        else {
            Write-Host "Warning: $($remainingSessions.Count) UCS PowerTool session(s) still appear to be active after cleanup." -ForegroundColor Yellow
        }
    }
    catch {}
}

function Remove-UcsTargetDecoration {
    param([Parameter(Mandatory=$true)][string]$Value)

    # CDP/LLDP can append UCS domain/context in brackets, for example:
    #   PD24000001SS101-A.dpe.protected.mil.au(FD0261301D1)
    # That bracket suffix is not part of the UCSM hostname and makes Connect-Ucs fail with Invalid URI.
    return (($Value.Trim()) -replace '\s*\([^)]*\)\s*$', '').Trim()
}

function Set-ActiveUcsSession {
    param([Parameter(Mandatory=$true)]$UcsSession)

    # Some Cisco UCS PowerTool cmdlets still depend on DefaultUcs unless -Ucs is passed.
    # Keep the current intended session as DefaultUcs to avoid:
    # "No UcsHandle specified and the Default Ucs list is empty."
    try { $global:DefaultUcs = $UcsSession } catch {}
}

function Convert-FiSystemNameToUcsCandidate {
    param([Parameter(Mandatory=$true)][string]$SystemName)
    $candidate = Remove-UcsTargetDecoration -Value $SystemName
    # FQDN must be evaluated before short-name matching.
    if ($candidate -match "^(.+)-[AaBb](\..+)$") { return "$($Matches[1])$($Matches[2])" }
    if ($candidate -match "^(.*)-[AaBb]$") { return $Matches[1] }
    return $candidate
}

function Get-UcsCandidateListFromSystemName {
    param([Parameter(Mandatory=$true)][string]$SystemName)

    # Only return the UCSM cluster name, not the individual Fabric Interconnect name.
    # Example CDP/LLDP value from Fabric A:
    #   PD24000001SS101-A.dpe.protected.mil.au
    # becomes UCSM target:
    #   PD24000001SS101.dpe.protected.mil.au
    # The script will not automatically try the raw -A/-B FI name. Manual override is offered separately.
    $normalised = Convert-FiSystemNameToUcsCandidate -SystemName $SystemName
    if ([string]::IsNullOrWhiteSpace($normalised)) { return @() }
    return @($normalised)
}

function Get-UcsCredentialIfNeeded {
    if ($null -ne $Global:UcsCredential) { return }
    Write-Host "Enter UCSM credential. Stored in memory only. If your manual Connect-Ucs works only with interactive prompt, choose MANUAL when asked after a failed credential attempt." -ForegroundColor Cyan
    $Global:UcsCredential = Get-Credential -Message "Enter UCSM credential"
}

function Connect-UcsOneAttempt {
    param([Parameter(Mandatory=$true)][string]$UcsTarget,[switch]$Interactive)
    if ($Interactive) {
        # This intentionally mirrors the working manual syntax: Connect-Ucs "ucsmname"
        return Connect-Ucs $UcsTarget -ErrorAction Stop
    }
    Get-UcsCredentialIfNeeded
    try {
        # First try the documented named parameter form.
        return Connect-Ucs -Name $UcsTarget -Credential $Global:UcsCredential -ErrorAction Stop
    } catch {
        # Some PowerTool builds behave more reliably with positional target.
        return Connect-Ucs $UcsTarget -Credential $Global:UcsCredential -ErrorAction Stop
    }
}

function Connect-UcsCached {
    param([Parameter(Mandatory=$true)][string]$UcsTarget)
    $target = Remove-UcsTargetDecoration -Value $UcsTarget
    if ($Global:UcsSessions.ContainsKey($target)) {
        Set-ActiveUcsSession -UcsSession $Global:UcsSessions[$target]
        return $Global:UcsSessions[$target]
    }

    # Before the login, not after it. Connect-Ucs against a blocked address sits on its own
    # timeout with nothing on screen and then blames the credentials.
    [void](Confirm-ManagementEndpointReachable -Target $target -DeviceKind "UCS Manager" -TimeoutSeconds $ManagementEndpointProbeTimeoutSeconds)

    Write-Host "Connecting to UCSM: $target" -ForegroundColor Cyan
    try {
        $session = Connect-UcsOneAttempt -UcsTarget $target
        $Global:UcsSessions[$target] = $session
        Set-ActiveUcsSession -UcsSession $session
        Write-Host "Connected to UCSM: $target" -ForegroundColor Green
        return $session
    } catch {
        $failureMessage = $_.Exception.Message
        Write-Host "Credential-based UCSM login failed for '$target': $failureMessage" -ForegroundColor Yellow

        # A wrong password would otherwise stay cached for the rest of the run and fail every
        # remaining UCSM domain in turn. Drop it so the next attempt prompts again. Connectivity
        # and name-resolution failures leave the credential alone.
        if ($failureMessage -match 'auth|credential|password|denied|unauthori[sz]ed|login') {
            $Global:UcsCredential = $null
            Write-Host "Cached UCSM credential discarded - you will be prompted again on the next attempt." -ForegroundColor Yellow
        }

        Write-Host "Because manual 'Connect-Ucs '$target'' works in your environment, you can try an interactive UCS login now." -ForegroundColor Yellow
        $choice = Read-ChoiceExit -Message "Try interactive Connect-Ucs '$target'? Y for yes, N for no, E to exit" -AllowedChoices @("Y","N") -ExitMessage "Stopped during UCSM login."
        if ($choice -eq "Y") {
            try {
                $session = Connect-UcsOneAttempt -UcsTarget $target -Interactive
                $Global:UcsSessions[$target] = $session
                Set-ActiveUcsSession -UcsSession $session
                Write-Host "Connected to UCSM interactively: $target" -ForegroundColor Green
                return $session
            } catch {
                Write-Host "Interactive UCSM login also failed for '$target': $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        return $null
    }
}

function Get-UcsSessionForTarget {
    param([Parameter(Mandatory=$true)][string]$UcsTarget)

    $session = Connect-UcsCached -UcsTarget $UcsTarget
    if ($null -eq $session) {
        Stop-WithMessage "UCSM session is not available for $UcsTarget."
    }
    Set-ActiveUcsSession -UcsSession $session
    return $session
}

function Get-EsxiDiscoveryProtocolInfo {
    param([Parameter(Mandatory=$true)]$VMHostObject)
    $results = New-Object System.Collections.ArrayList
    try {
        $hostView = Get-View -Id $VMHostObject.Id -ErrorAction Stop
        $networkSystem = Get-View -Id $hostView.ConfigManager.NetworkSystem -ErrorAction Stop
        foreach ($pnic in $hostView.Config.Network.Pnic | Sort-Object Device) {
            try {
                $hints = $networkSystem.QueryNetworkHint($pnic.Device)
                foreach ($hint in $hints) {
                    if ($null -ne $hint.ConnectedSwitchPort -and -not [string]::IsNullOrWhiteSpace($hint.ConnectedSwitchPort.DevId)) {
                        [void]$results.Add([pscustomobject]@{ Host=$VMHostObject.Name; Vmnic=$pnic.Device; SystemName=$hint.ConnectedSwitchPort.DevId; PortId=$hint.ConnectedSwitchPort.PortId })
                    }
                }
            } catch {}
        }
    } catch { Write-Host "Could not query CDP/LLDP for $($VMHostObject.Name): $($_.Exception.Message)" -ForegroundColor Yellow }
    return @($results)
}

function Get-EsxiPreferredDiscovery {
    <#
    .SYNOPSIS
        Returns the preferred CDP/LLDP row for a host, querying vCenter at most once per host.

    .DESCRIPTION
        QueryNetworkHint is issued per physical NIC and is the slowest step in the whole
        discovery phase. The infrastructure detection pass and the UCSM mapping pass both
        need the same answer, so the result is cached per host for the life of the run.
        Returns $null when the host reports no usable CDP/LLDP neighbour.
    #>
    param([Parameter(Mandatory=$true)]$VMHostObject)

    if ($Global:EsxiDiscoveryCache.ContainsKey($VMHostObject.Name)) {
        return $Global:EsxiDiscoveryCache[$VMHostObject.Name]
    }

    $discovery = @(Get-EsxiDiscoveryProtocolInfo -VMHostObject $VMHostObject)
    $preferred = @($discovery | Where-Object { $_.Vmnic -in @("vmnic0","vmnic1","vmnic2","vmnic3") } | Sort-Object Vmnic | Select-Object -First 1)
    if ($preferred.Count -eq 0 -and $discovery.Count -gt 0) { $preferred = @($discovery | Select-Object -First 1) }

    $result = if ($preferred.Count -gt 0) { $preferred[0] } else { $null }
    $Global:EsxiDiscoveryCache[$VMHostObject.Name] = $result
    return $result
}

function Get-ShortHostName { param([Parameter(Mandatory=$true)][string]$HostName) return ($HostName.Trim().Split('.')[0]) }

function Resolve-UcsServiceProfileForHost {
    param([Parameter(Mandatory=$true)][string]$HostName,[Parameter(Mandatory=$true)][string]$UcsTarget)
    $ucsSession = Get-UcsSessionForTarget -UcsTarget $UcsTarget
    $short = Get-ShortHostName -HostName $HostName
    Write-Host "Looking up UCS service profile for host '$HostName' as '$short' in '$UcsTarget'." -ForegroundColor Cyan
    try {
        $sp = Get-UcsServiceProfile -Ucs $ucsSession -Name $short -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $sp) { return $sp }

        # Fallback scan over every service profile in the domain. Enumerated once per UCSM target
        # and reused, rather than re-fetched for each host in the cluster.
        if (-not $Global:UcsServiceProfileCache.ContainsKey($UcsTarget)) {
            Write-Host "Enumerating all service profiles in '$UcsTarget' for fallback matching..." -ForegroundColor Cyan
            $Global:UcsServiceProfileCache[$UcsTarget] = @(Get-UcsServiceProfile -Ucs $ucsSession -ErrorAction SilentlyContinue)
        }
        $sp = $Global:UcsServiceProfileCache[$UcsTarget] | Where-Object { $_.Name -eq $short -or $_.Dn -like "*/ls-$short" -or $_.Dn -like "*/$short" } | Select-Object -First 1
        if ($null -ne $sp) { return $sp }
    } catch { Write-Host "Service profile lookup failed for '$HostName': $($_.Exception.Message)" -ForegroundColor Yellow }
    $manualSp = Read-Host "Enter UCS service profile name or DN manually for host $HostName, or type EXIT"
    if ($manualSp.Trim().ToUpper() -eq "EXIT") { Stop-SafeExit -Message "Stopped during manual UCS service profile mapping." }
    if ($manualSp.Trim() -like "org-*") { return (Get-UcsServiceProfile -Ucs $ucsSession -Dn $manualSp.Trim() -ErrorAction SilentlyContinue | Select-Object -First 1) }
    return (Get-UcsServiceProfile -Ucs $ucsSession -Name $manualSp.Trim() -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function ConvertTo-UcsFirmwarePolicyName {
    <#
    .SYNOPSIS
        Reduces a host firmware package reference to its bare name, whether it arrives as a name
        or as a distinguished name.

    .DESCRIPTION
        UCSM reports the same policy two ways depending on which property is read:

            hostFwPolicyName      global-436h
            operHostFwPolicyName  org-root/fw-host-pack-global-436h

        and a sub-organisation deepens the DN further - org-root/org-prod/fw-host-pack-global-436h.
        Comparing one form against the other never matches, which is exactly what happened when the
        resolved property started being preferred without normalising it.

        A value with no "/" is already a name and is returned untouched, so a package genuinely
        named with a hyphen is not mangled.

    .PARAMETER Value
        Either form, or empty.

    .EXAMPLE
        ConvertTo-UcsFirmwarePolicyName -Value "org-root/fw-host-pack-global-436h"   # global-436h
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    $trimmed = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return "" }
    if ($trimmed -notmatch '/') { return $trimmed }

    $leaf = @($trimmed -split '/')[-1]
    return ($leaf -replace '^fw-host-pack-', '')
}

function Get-UcsServiceProfileFirmwarePolicyName {
    <#
    .SYNOPSIS
        The host firmware package a service profile or template is actually using.

    .DESCRIPTION
        Two properties, in this order, and they are not interchangeable. From Cisco's own lsServer
        metadata:

          operHostFwPolicyName  READ_ONLY, up to 256 characters. The RESOLVED policy - what the
                                profile is really using once the template it is bound to and the
                                global policy have been applied - and it is a DISTINGUISHED NAME:
                                org-root/fw-host-pack-global-436h.
          hostFwPolicyName      READ_WRITE, at most 16 characters. The bare NAME that was SET on
                                this object: global-436h.

        Oper first, because a profile bound to an updating template usually carries nothing in
        hostFwPolicyName - the template supplies it - and reading only the writable field reports
        such a profile as having no policy at all.

        BUT THE TWO ARE NOT THE SAME SHAPE, and that is what the field widths were saying: 16
        characters holds a name, 256 holds a DN. Returning oper raw compared a DN against a name in
        every caller, so nothing ever matched:

            CurrentPolicy org-root/fw-host-pack-global-436h   TargetPolicy global-436h   NotVerified

        On a live run that produced four service profile templates reported as "could NOT be set"
        when every one of them was already correct, a service profile that re-verified as
        NotVerified for as many attempts as the operator was willing to give it, and a batch that
        never reached its reboot acknowledgement because it never got past that loop.

        So both are normalised to the bare name through ConvertTo-UcsFirmwarePolicyName, and every
        caller compares names to names.

        Two properties were dropped from an earlier list. HostFirmwarePackageName is not an
        lsServer property and never matched anything. SrcTemplName is the TEMPLATE'S NAME, not a
        firmware policy: returning it here meant a profile with no policy reported its template
        name as its policy, and the "already on target" comparison then compared a template name
        against a package name.
    #>
    param([Parameter(Mandatory=$true)]$ServiceProfile)

    foreach ($prop in @("OperHostFwPolicyName","HostFwPolicyName")) {
        if ($ServiceProfile.PSObject.Properties.Name -contains $prop) {
            $val = ConvertTo-UcsFirmwarePolicyName -Value ([string]$ServiceProfile.$prop)
            if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
        }
    }
    return "UNKNOWN"
}

function Get-UcsFirmwarePolicyRows {
    param([Parameter(Mandatory=$true)]$UcsSession)

    # NOT SilentlyContinue. A failed query returned an empty list that read as "the policy does not
    # exist in this domain", and the run then tried to CREATE a package that was already there -
    # which UCSM refused with "resolved from remote policy server". A query that cannot be answered
    # is not evidence of absence, so it is allowed to throw and the caller decides.
    $policies = @(Get-UcsFirmwareComputeHostPack -Ucs $UcsSession -ErrorAction Stop)
    $rows = foreach ($policy in $policies) {
        $policyName = [string]$policy.Name
        if ([string]::IsNullOrWhiteSpace($policyName) -and $policy.PSObject.Properties.Name -contains "Dn") {
            # UCSM Dn is usually like org-root/fw-host-pack-global-434a.
            $policyName = ([string]$policy.Dn) -replace '^.*fw-host-pack-', ''
        }
        if (-not [string]::IsNullOrWhiteSpace($policyName)) {
            [pscustomobject]@{
                Name        = $policyName
                Dn          = [string]$policy.Dn
                Description = if ($policy.PSObject.Properties.Name -contains "Descr") { [string]$policy.Descr } else { "" }
                RawObject    = $policy
            }
        }
    }
    return @($rows | Sort-Object Name -Unique)
}

function Get-UcsFabricFamily {
    <#
    .SYNOPSIS
        Reads the fabric interconnect model from a connected UCSM domain and returns its family.

    .DESCRIPTION
        Get-UcsNetworkElement returns one object per fabric interconnect, whose Model looks like
        UCS-FI-6332, UCS-FI-6454 or UCS-FI-64108. The first two digits of the model number give the
        family - 6200, 6300, 6400, 6500 - which is what selects the firmware policy.

        Both fabric interconnects in a domain are read. They should always match; if they do not,
        the family is reported as Mixed and the caller stops rather than guessing which firmware
        policy applies.

    .PARAMETER UcsSession
        A connected UCSM session.
    #>
    param([Parameter(Mandatory=$true)]$UcsSession)

    $elements = @()
    try { $elements = @(Get-UcsNetworkElement -Ucs $UcsSession -ErrorAction Stop) }
    catch {
        return [pscustomobject]@{ Family='Unknown'; Models=@(); Detail="Get-UcsNetworkElement failed: $($_.Exception.Message)" }
    }

    if ($elements.Count -eq 0) {
        return [pscustomobject]@{ Family='Unknown'; Models=@(); Detail='Get-UcsNetworkElement returned no fabric interconnects.' }
    }

    $models = @($elements | ForEach-Object { [string]$_.Model } | Where-Object { $_ })
    $families = @(
        $models | ForEach-Object {
            if ($_ -match '(?i)FI-?(\d{2})\d') { "$($Matches[1])00" } else { $null }
        } | Where-Object { $_ } | Select-Object -Unique
    )

    if ($families.Count -eq 0) {
        return [pscustomobject]@{ Family='Unknown'; Models=$models; Detail="No family could be derived from model(s): $($models -join ', ')" }
    }
    if ($families.Count -gt 1) {
        return [pscustomobject]@{ Family='Mixed'; Models=$models; Detail="Fabric interconnects report different families: $($models -join ', ')" }
    }

    return [pscustomobject]@{ Family=$families[0]; Models=$models; Detail="Model(s): $($models -join ', ')" }
}

function Resolve-UcsFirmwarePolicyForTarget {
    <#
    .SYNOPSIS
        Returns the host firmware package for a UCSM domain, derived from its fabric family.

    .DESCRIPTION
        Replaces the interactive firmware policy picker. The fabric interconnect family decides the
        policy, per $Global:UcsFirmwarePolicyByFabricFamily - so a 6400 domain gets one policy and a
        6300 domain another, with no operator choice to get wrong.

        Where the package already resolves in the domain it is used as-is, whoever owns it.

        Where it does not, it is CREATED ONCE IN UCSM AND HANDED STRAIGHT TO UCS CENTRAL - a single
        managed-object write carrying policyOwner="pending-policy", which is what the GUI sends for
        "create, Use Global". The package has to exist in the domain before Central can take it
        over, and doing the create and the handover as two separate operations is what failed: by
        the time the second one went out the object was resolved from the policy server and UCSM
        refused it, leaving a local, empty package behind. See New-UcsGlobalFirmwarePolicy.

        No bundle version is ever written. That is the point of the handover - the versions come
        from the global policy, and a version pinned here would quietly disagree with it.

        Once the package is confirmed or created, the domain's service profile templates are
        aligned to it, so a template does not put the old package back on the next push or rebind.

    .PARAMETER UcsTarget
        UCSM name, for messages and caching.

    .PARAMETER UcsSession
        A connected UCSM session for that domain.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$UcsTarget,
        [Parameter(Mandatory=$true)]$UcsSession
    )

    if ($Global:UcsFirmwarePolicyByTarget.ContainsKey($UcsTarget)) { return $Global:UcsFirmwarePolicyByTarget[$UcsTarget] }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Determining the fabric interconnect family for $UcsTarget..." -ForegroundColor Cyan
    $fabric = Get-UcsFabricFamily -UcsSession $UcsSession
    Write-Host "  $($fabric.Detail)" -ForegroundColor Gray
    Write-Host "  Fabric family: $($fabric.Family)" -ForegroundColor Cyan
    Add-SummaryRecord -Stage "UCSMFabricDetection" -Batch "" -HostName "" -Action "Detect fabric family" -Result $fabric.Family -Details "$UcsTarget - $($fabric.Detail)"

    if (-not $Global:UcsFirmwarePolicyByFabricFamily.ContainsKey($fabric.Family)) {
        $known = ($Global:UcsFirmwarePolicyByFabricFamily.Keys | Sort-Object) -join ', '
        Stop-WithMessage "No firmware policy is mapped for fabric family '$($fabric.Family)' on $UcsTarget ($($fabric.Detail)). Mapped families: $known. Add an entry to `$Global:UcsFirmwarePolicyByFabricFamily before running against this domain."
    }

    $policyName = [string]$Global:UcsFirmwarePolicyByFabricFamily[$fabric.Family]
    Write-Host "  Target host firmware package: $policyName" -ForegroundColor Green

    # lsServer.hostFwPolicyName is capped at 16 characters by the UCSM schema
    # (r"""[\-\.:_a-zA-Z0-9]{0,16}"""). A longer name cannot be written to a service profile at
    # all, and the failure that produces is a binding error a long way from the mapping table that
    # actually caused it.
    if ($policyName.Length -gt 16) {
        Stop-WithMessage "Host firmware package name '$policyName' is $($policyName.Length) characters. UCSM allows at most 16 on a service profile, so this name can never be applied. Correct the entry for fabric family '$($fabric.Family)' in `$Global:UcsFirmwarePolicyByFabricFamily."
    }

    $lookup = Get-UcsFirmwarePolicyLookup -PolicyName $policyName -UcsSession $UcsSession

    if (-not $lookup.Known) {
        # Every probe errored. Absence has NOT been established, and acting on a guess about a
        # package UCS Central owns is what produced "does NOT exist" for one that plainly did.
        Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Resolve firmware policy" -Result "Unreadable" -Details "$UcsTarget - $policyName - $($lookup.Detail)"
        Stop-WithMessage "Whether host firmware package '$policyName' exists in $UcsTarget could not be established: $($lookup.Detail) Check the UCSM session before continuing."
    }

    if ($lookup.Exists) {
        Write-Host "  '$policyName' resolves in $UcsTarget ($($lookup.Detail)) - owner $(if ($lookup.Owner) { $lookup.Owner } else { 'unreported' })." -ForegroundColor Green
        Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Resolve firmware policy" -Result "Resolved" -Details "$UcsTarget - $policyName for fabric family $($fabric.Family). Owner=$(if ($lookup.Owner) { $lookup.Owner } else { 'unreported' }). $($lookup.Detail)"
    }
    elseif (Test-DryRun) {
        Write-Host "  '$policyName' is not in $UcsTarget. DRY RUN: would create it at org-root with policyOwner=pending-policy and hand it to UCS Central." -ForegroundColor Green
        Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Create global firmware policy" -Result "DryRun" -Details "$UcsTarget - would create org-root/fw-host-pack-$policyName with policyOwner=pending-policy; no bundle versions written."
    }
    else {
        # The package has to exist in the domain before Central can take it over. Created here in
        # ONE write that carries the ownership with it - see New-UcsGlobalFirmwarePolicy for why
        # create-then-modify is the order that failed.
        Write-Host "  '$policyName' is not present in $UcsTarget." -ForegroundColor Yellow
        $made = New-UcsGlobalFirmwarePolicy -PolicyName $policyName -UcsTarget $UcsTarget -UcsSession $UcsSession
        if (-not $made.Created) {
            Stop-WithMessage "Host firmware package '$policyName' is missing from $UcsTarget and could not be created: $($made.Detail) Nothing has been changed on any service profile."
        }
        # Created - the run carries on into the templates and the blades, as it would have if the
        # package had already been there.
    }

    $Global:UcsFirmwarePolicyByTarget[$UcsTarget] = $policyName
    Set-UcsServiceProfileTemplateFirmwarePolicy -UcsTarget $UcsTarget -UcsSession $UcsSession -PolicyName $policyName
    return $policyName
}

function Get-UcsFirmwarePolicyLookup {
    <#
    .SYNOPSIS
        Does this host firmware package exist in the domain? Answers Yes, No, or Unknown.

    .DESCRIPTION
        Three probes, cheapest and most specific first, because ONE of them silently returning
        nothing is what caused a run to try to create a package that already existed:

          1. By org and name.
          2. By distinguished name - org-root/fw-host-pack-<name> - which is the form UCSM reports
             in its own error messages, and the form a package resolved from UCS Central carries.
          3. The full package list.

        A hit on any of them is Exists. Every probe failing to ANSWER - not returning nothing, but
        erroring - is Unknown, and Unknown is never treated as absent. That distinction is the
        whole point: a swallowed query previously read as "not there", the run created a package
        UCS Central already owned, and UCSM refused the follow-up modify with "resolved from remote
        policy server. Create/Delete/Modify operations are not allowed."

    .PARAMETER PolicyName
        Host firmware package name, for example global-436h.

    .PARAMETER UcsSession
        A connected UCSM session.

    .EXAMPLE
        $lookup = Get-UcsFirmwarePolicyLookup -PolicyName "global-436h" -UcsSession $s
        if ($lookup.Exists) { ... }
    #>
    param(
        [Parameter(Mandatory=$true)][string]$PolicyName,
        [Parameter(Mandatory=$true)]$UcsSession
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $answered = $false

    try {
        $byName = @(Get-UcsFirmwareComputeHostPack -Ucs $UcsSession -Org "org-root" -Name $PolicyName -ErrorAction Stop)
        $answered = $true
        if ($byName.Count -gt 0) {
            return [pscustomobject]@{ Exists = $true; Known = $true; Policy = $byName[0]
                Owner = [string]$byName[0].PolicyOwner; Detail = "Found by org and name." }
        }
    }
    catch { [void]$errors.Add("by name: $($_.Exception.Message)") }

    try {
        $byDn = @(Get-UcsFirmwareComputeHostPack -Ucs $UcsSession -Dn "org-root/fw-host-pack-$PolicyName" -ErrorAction Stop)
        $answered = $true
        if ($byDn.Count -gt 0) {
            return [pscustomobject]@{ Exists = $true; Known = $true; Policy = $byDn[0]
                Owner = [string]$byDn[0].PolicyOwner; Detail = "Found by distinguished name." }
        }
    }
    catch { [void]$errors.Add("by Dn: $($_.Exception.Message)") }

    try {
        $rows = @(Get-UcsFirmwarePolicyRows -UcsSession $UcsSession | Where-Object { $_.Name -eq $PolicyName })
        $answered = $true
        if ($rows.Count -gt 0) {
            return [pscustomobject]@{ Exists = $true; Known = $true; Policy = $rows[0].RawObject
                Owner = [string]$rows[0].RawObject.PolicyOwner; Detail = "Found in the package list." }
        }
    }
    catch { [void]$errors.Add("full list: $($_.Exception.Message)") }

    if ($answered) {
        return [pscustomobject]@{ Exists = $false; Known = $true; Policy = $null; Owner = ""
            Detail = "Not present - the domain answered and does not have it." }
    }

    return [pscustomobject]@{ Exists = $false; Known = $false; Policy = $null; Owner = ""
        Detail = "The domain could not be asked. $($errors.ToArray() -join '; ')" }
}

function Test-UcsFirmwarePolicyExists {
    param(
        [Parameter(Mandatory=$true)][string]$PolicyName,
        [Parameter(Mandatory=$true)]$UcsSession
    )
    return (Get-UcsFirmwarePolicyLookup -PolicyName $PolicyName -UcsSession $UcsSession).Exists
}

function Test-UcsRemotePolicyMessage {
    <#
    .SYNOPSIS
        Is this UCSM error the one that means "UCS Central already owns this policy"?

    .DESCRIPTION
        UCSM refuses a local write to a globally resolved object with:

            Policy org-root/fw-host-pack-<name> is resolved from remote policy server.
            Create/Delete/Modify operations are not allowed.

        That is not a failure to make the package Global. It is UCSM saying the package ALREADY IS
        Global - Central owns it, so the domain will not let this script touch it. Treating it as an
        error is what put "could not be made Global and would upgrade nothing" on screen for a
        package that was in exactly the state the run wanted.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return ($Message -match '(?i)resolved from remote policy server')
}

function New-UcsGlobalFirmwarePolicy {
    <#
    .SYNOPSIS
        Creates a missing host firmware package in UCSM and hands it to UCS Central in ONE write.

    .DESCRIPTION
        The package has to exist in the domain before Central can take it over, so a domain that is
        registered but has never had this package still needs it made once. This is that step, and
        it is deliberately a SINGLE managed-object write rather than create-then-modify.

        WHY ONE WRITE. An earlier build created the package LOCAL, committed, and then issued a
        second call to change policyOwner. By then the object was resolved from the policy server
        and UCSM refused the modify:

            Policy org-root/fw-host-pack-global-436h is resolved from remote policy server.
            Create/Delete/Modify operations are not allowed.

        which left a local, empty package attached to service profiles - it applies cleanly and
        upgrades nothing. Sending the ownership WITH the create closes that window.

        WHAT GOES ON THE WIRE. Exactly the pair the UCSM GUI sends for "create, Use Global":

            <configEstimateImpact>
              <inConfigs><pair key="org-root/fw-host-pack-<name>">
                <firmwareComputeHostPack name="<name>" policyOwner="pending-policy"
                    dn="org-root/fw-host-pack-<name>" status="created,modified"/>
              </pair></inConfigs>
            </configEstimateImpact>

            <configConfMos> ...the same inConfigs... </configConfMos>

        and the PowerTool that produces it:

            Start-UcsTransaction                              opens the configConfMos batch
            Add-Ucs... -ModifyPresent                         status="created,modified"
                       -PolicyOwner "pending-policy"          the handover, in the same MO
            Get-UcsTransactionImpact                          configEstimateImpact
            Complete-UcsTransaction                           configConfMos

        No Descr and no bundle versions are sent, because the payload carries neither. The versions
        are the whole point of handing it to Central: they come from the global policy, not from
        anything written here.

        POLICY OWNER IS "pending-policy", NOT "policy". Per Cisco's firmwareComputeHostPack
        metadata the value is one of local / pending-policy / policy, and pending-policy is what
        the domain sets when it offers the object up - UCSM shows "Pending Global". Central then
        claims it and it becomes "policy". Both are success here; only "local" means the handover
        did not take.

        Never throws. A package that cannot be created is reported and the caller decides.

    .PARAMETER PolicyName
        The package name for this domain's fabric family - global-436h on a 6300, global-602d on a
        6400, and so on. Nothing here is specific to any one of them.

    .PARAMETER UcsTarget
        UCSM name, for messages and the run summary.

    .PARAMETER UcsSession
        A connected UCSM session for that domain.

    .EXAMPLE
        $made = New-UcsGlobalFirmwarePolicy -PolicyName 'global-602d' -UcsTarget 'ucsm-a' -UcsSession $s
        if ($made.Created) { ... }
    #>
    param(
        [Parameter(Mandatory=$true)][string]$PolicyName,
        [Parameter(Mandatory=$true)][string]$UcsTarget,
        [Parameter(Mandatory=$true)]$UcsSession
    )

    $dn = "org-root/fw-host-pack-$PolicyName"

    Write-Host "  Creating '$PolicyName' in $UcsTarget and handing it to UCS Central in one write." -ForegroundColor Yellow
    Write-Host "    dn          : $dn" -ForegroundColor Gray
    Write-Host "    policyOwner : pending-policy (UCSM shows this as Pending Global)" -ForegroundColor Gray
    Write-Host "    status      : created,modified" -ForegroundColor Gray

    # Does this PowerTool build expose policyOwner on the Add cmdlet? Asked rather than assumed:
    # where it is missing the single write is impossible and the two-step below is the only route.
    $ownerAtCreate = $false
    try { $ownerAtCreate = [bool](Get-Command -Name Add-UcsFirmwareComputeHostPack -ErrorAction Stop).Parameters.ContainsKey('PolicyOwner') }
    catch { $ownerAtCreate = $false }

    $inTransaction = $false
    try {
        Start-UcsTransaction -Ucs $UcsSession -ErrorAction Stop | Out-Null
        $inTransaction = $true

        if ($ownerAtCreate) {
            Add-UcsFirmwareComputeHostPack -Ucs $UcsSession -Org "org-root" -Name $PolicyName `
                -PolicyOwner "pending-policy" -ModifyPresent -ErrorAction Stop | Out-Null
        }
        else {
            Add-UcsFirmwareComputeHostPack -Ucs $UcsSession -Org "org-root" -Name $PolicyName `
                -ModifyPresent -ErrorAction Stop | Out-Null
        }

        # configEstimateImpact, before the commit, the same question the GUI asks. Informational:
        # it is reported and never acted on, because the operator has already approved this change.
        try {
            $impact = Get-UcsTransactionImpact -Ucs $UcsSession -ErrorAction Stop
            foreach ($line in @($impact)) {
                $text = if ($line.PSObject.Properties.Name -contains 'Message') { [string]$line.Message } else { [string]$line }
                if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Host "    Impact: $text" -ForegroundColor Gray }
            }
        }
        catch { Write-Host "    (no impact estimate available from this domain: $($_.Exception.Message))" -ForegroundColor DarkGray }

        Complete-UcsTransaction -Ucs $UcsSession -ErrorAction Stop | Out-Null
        $inTransaction = $false
    }
    catch {
        $message = $_.Exception.Message
        if ($inTransaction) {
            # Leave no half-built batch on the session for the next call to commit by accident.
            try { if (Get-Command -Name Undo-UcsTransaction -ErrorAction SilentlyContinue) { Undo-UcsTransaction -Ucs $UcsSession -ErrorAction SilentlyContinue | Out-Null } } catch { }
        }

        if (Test-UcsRemotePolicyMessage -Message $message) {
            # Central already owns it. Nothing to create and nothing to hand over - the end state
            # this was working towards, reached from the other direction.
            Write-Host "  '$PolicyName' is resolved from UCS Central - it already exists and Central owns it." -ForegroundColor Green
            Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Create global firmware policy" -Result "RemoteOwned" -Details "$UcsTarget - $dn is resolved from UCS Central; no local create is permitted or needed."
            return [pscustomobject]@{ Created = $true; Owner = "policy"; Detail = "Resolved from UCS Central." }
        }

        Write-Host "  Could not create '$PolicyName' in ${UcsTarget}: $message" -ForegroundColor Red
        Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Create global firmware policy" -Result "Failed" -Details "$UcsTarget - $dn - $message"
        return [pscustomobject]@{ Created = $false; Owner = ""; Detail = $message }
    }

    # Where the Add cmdlet could not carry it, the handover is a second write. This is the order
    # that failed before, so it is only reached when the single write was not available at all.
    if (-not $ownerAtCreate) {
        Write-Host "    This PowerTool build cannot set policyOwner at create, so the handover is a second write." -ForegroundColor Yellow
        try {
            Get-UcsFirmwareComputeHostPack -Ucs $UcsSession -Org "org-root" -Name $PolicyName -ErrorAction Stop |
                Set-UcsFirmwareComputeHostPack -PolicyOwner "pending-policy" -Force -ErrorAction Stop | Out-Null
        }
        catch {
            if (Test-UcsRemotePolicyMessage -Message $_.Exception.Message) {
                Write-Host "  '$PolicyName' is now resolved from UCS Central." -ForegroundColor Green
            }
            else {
                Write-Host "    The handover write failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    # READ THE OWNER BACK. The write returning is not proof the domain accepted the handover, and a
    # package left local carries no bundle versions - it would apply cleanly and upgrade nothing.
    $lookup = Get-UcsFirmwarePolicyLookup -PolicyName $PolicyName -UcsSession $UcsSession
    $owner = [string]$lookup.Owner

    if (-not $lookup.Exists) {
        Write-Host "  '$PolicyName' cannot be read back from $UcsTarget after the write." -ForegroundColor Red
        Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Create global firmware policy" -Result "NotReadBack" -Details "$UcsTarget - $dn was written but does not read back. $($lookup.Detail)"
        return [pscustomobject]@{ Created = $false; Owner = ""; Detail = "Written but not readable afterwards. $($lookup.Detail)" }
    }

    if ($owner -eq "policy" -or $owner -eq "pending-policy") {
        $label = if ($owner -eq "policy") { "Global - UCS Central has taken it" } else { "Pending Global - offered to UCS Central, not yet claimed" }
        Write-Host "  '$PolicyName' created in $UcsTarget and is $label." -ForegroundColor Green
        Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Create global firmware policy" -Result "Created" -Details "$UcsTarget - $dn created with policyOwner=$owner; bundle versions come from the global policy."
        return [pscustomobject]@{ Created = $true; Owner = $owner; Detail = $label }
    }

    # Created, but still local. It exists, so the run can continue and the blades will get a
    # package - but an empty one, so this is called out rather than passed over.
    Write-Host "  '$PolicyName' was created in $UcsTarget but is still owned locally (policyOwner=$(if ($owner) { $owner } else { 'unreported' }))." -ForegroundColor Yellow
    Write-Host "  A local package carries no bundle versions of its own, so it will apply cleanly and change no firmware." -ForegroundColor Yellow
    Write-Host "  Check that $UcsTarget is registered with UCS Central and that policy resolution for host firmware packages is Global." -ForegroundColor Yellow
    Add-ManualAttentionHost -HostName $UcsTarget -Reason "Host firmware package is not Global" -Detail "'$PolicyName' was created in $UcsTarget but policyOwner is '$(if ($owner) { $owner } else { 'unreported' })'. A local package has no bundle versions of its own and will not change any firmware. Set it to Use Global in UCSM, or confirm the domain is registered with UCS Central."
    Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Create global firmware policy" -Result "StillLocal" -Details "$UcsTarget - $dn created but policyOwner=$owner; the package has no bundle versions of its own."
    return [pscustomobject]@{ Created = $true; Owner = $owner; Detail = "Created but still local." }
}

function Set-UcsServiceProfileTemplateFirmwarePolicy {
    <#
    .SYNOPSIS
        Points every service profile TEMPLATE in the domain at the target host firmware package.

    .DESCRIPTION
        The service profiles this run touches are almost always bound to a template, and a template
        that still names the old package puts it back. Setting only the profiles therefore fixes
        the blades in this cluster and leaves the domain to undo it - on the next template push, on
        a rebind, or on the next profile created from that template.

        So the templates are checked once per domain, when the policy for that domain is resolved,
        and any that already carry the target package are left alone and reported as compliant.
        Nothing is prompted: the package being set is the same one the blades are getting anyway.

        WHAT THIS DOES NOT DO: it does not reboot anything. A host firmware package change on a
        service profile raises a PENDING ACTIVITY that waits for the maintenance-policy
        acknowledgement, and this run acknowledges only the blades in its own batches. Templates
        outside this cluster will show a pending activity for someone to action deliberately -
        which is called out on screen rather than left to be discovered.

    .PARAMETER UcsTarget
        UCSM name, for messages and the run summary.

    .PARAMETER UcsSession
        A connected UCSM session for that domain.

    .PARAMETER PolicyName
        The host firmware package the templates should name.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$UcsTarget,
        [Parameter(Mandatory=$true)]$UcsSession,
        [Parameter(Mandatory=$true)][string]$PolicyName
    )

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Checking service profile templates in $UcsTarget against '$PolicyName'..." -ForegroundColor Cyan

    $templates = @()
    try {
        # lsServer carries instances and templates alike; the type tells them apart. Asked for
        # explicitly so a domain with thousands of profiles is not enumerated to find a handful
        # of templates.
        $templates = @(Get-UcsServiceProfile -Ucs $UcsSession -Type "initial-template" -ErrorAction Stop) +
                     @(Get-UcsServiceProfile -Ucs $UcsSession -Type "updating-template" -ErrorAction Stop)
    }
    catch {
        # Older PowerTool builds do not take -Type here. Fall back to filtering, which costs more.
        try {
            $templates = @(Get-UcsServiceProfile -Ucs $UcsSession -ErrorAction Stop |
                Where-Object { [string]$_.Type -match '(?i)template' })
        }
        catch {
            Write-Host "  Service profile templates could not be read from ${UcsTarget}: $($_.Exception.Message)" -ForegroundColor Yellow
            Add-SummaryRecord -Stage "UCSMTemplateFirmwarePolicy" -Batch "" -HostName "" -Action "Check templates" -Result "Unreadable" -Details "$UcsTarget - $($_.Exception.Message)"
            return
        }
    }

    if ($templates.Count -eq 0) {
        Write-Host "  No service profile templates in $UcsTarget - nothing to align." -ForegroundColor Gray
        Add-SummaryRecord -Stage "UCSMTemplateFirmwarePolicy" -Batch "" -HostName "" -Action "Check templates" -Result "None" -Details "$UcsTarget - no service profile templates found."
        return
    }

    $compliant = New-Object System.Collections.Generic.List[string]
    $changed   = New-Object System.Collections.Generic.List[string]
    $failed    = New-Object System.Collections.Generic.List[string]

    foreach ($template in $templates) {
        $name = [string]$template.Name
        $dn = [string]$template.Dn
        $current = Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $template

        if ($current -eq $PolicyName) {
            [void]$compliant.Add($name)
            Add-SummaryRecord -Stage "UCSMTemplateFirmwarePolicy" -Batch "" -HostName "" -Action "Check template" -Result "Compliant" -Details "$UcsTarget - $dn already names '$PolicyName'."
            continue
        }

        if (Test-DryRun) {
            [void]$changed.Add("$name ($current -> $PolicyName, DRY RUN)")
            Add-SummaryRecord -Stage "UCSMTemplateFirmwarePolicy" -Batch "" -HostName "" -Action "Set template policy" -Result "DryRun" -Details "$UcsTarget - would set $dn from '$current' to '$PolicyName'."
            continue
        }

        try {
            Set-UcsServiceProfile -Ucs $UcsSession -ServiceProfile $template -HostFwPolicyName $PolicyName -Force -ErrorAction Stop | Out-Null

            # Read back. The set returning is not proof the domain took it.
            $after = $current
            try {
                $reread = Get-UcsServiceProfile -Ucs $UcsSession -Dn $dn -ErrorAction Stop
                if ($null -ne $reread) { $after = Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $reread }
            }
            catch { }

            if ($after -eq $PolicyName) {
                [void]$changed.Add("$name ($current -> $PolicyName)")
                Add-SummaryRecord -Stage "UCSMTemplateFirmwarePolicy" -Batch "" -HostName "" -Action "Set template policy" -Result "Updated" -Details "$UcsTarget - $dn set from '$current' to '$PolicyName' and read back."
            }
            else {
                [void]$failed.Add("$name (still '$after')")
                Add-SummaryRecord -Stage "UCSMTemplateFirmwarePolicy" -Batch "" -HostName "" -Action "Set template policy" -Result "NotVerified" -Details "$UcsTarget - $dn still names '$after' after the set."
            }
        }
        catch {
            $message = $_.Exception.Message
            if (Test-UcsRemotePolicyMessage -Message $message) {
                # The template itself is owned by UCS Central. Nothing for this run to do, and
                # nothing wrong - Central manages it.
                [void]$compliant.Add("$name (owned by UCS Central)")
                Add-SummaryRecord -Stage "UCSMTemplateFirmwarePolicy" -Batch "" -HostName "" -Action "Set template policy" -Result "RemoteOwned" -Details "$UcsTarget - $dn is resolved from UCS Central and is managed there."
                continue
            }
            [void]$failed.Add("$name ($message)")
            Add-SummaryRecord -Stage "UCSMTemplateFirmwarePolicy" -Batch "" -HostName "" -Action "Set template policy" -Result "Failed" -Details "$UcsTarget - $dn - $message"
        }
    }

    if ($compliant.Count -gt 0) {
        Write-Host "  $($compliant.Count) template(s) already on '$PolicyName' - compliant, nothing to do: $($compliant.ToArray() -join ', ')" -ForegroundColor Green
    }
    if ($changed.Count -gt 0) {
        Write-Host "  $($changed.Count) template(s) updated to '$PolicyName': $($changed.ToArray() -join ', ')" -ForegroundColor Yellow
        Write-Host "  A template change raises a PENDING ACTIVITY on the profiles bound to it. This run" -ForegroundColor Yellow
        Write-Host "  acknowledges only the blades in its own batches; any others are left pending for you." -ForegroundColor Yellow
    }
    if ($failed.Count -gt 0) {
        Write-Host "  $($failed.Count) template(s) could NOT be set: $($failed.ToArray() -join ', ')" -ForegroundColor Red
        Add-ManualAttentionHost -HostName $UcsTarget -Reason "Service profile template not on the target firmware package" -Detail "In $UcsTarget these templates do not name '$PolicyName': $($failed.ToArray() -join ', '). A profile rebound or recreated from them will go back to the old package."
    }
}

function Build-InfrastructureHostMapping {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Hosts)

    Import-IntersightServerCsv
    $Global:IntersightHostMap = @{}
    $ucsOnlyHosts = New-Object System.Collections.ArrayList

    Write-Host "" -ForegroundColor Cyan
    Write-Host "STEP: Detecting supporting infrastructure per host (Intersight vs UCS Manager)." -ForegroundColor Cyan
    Write-Host "No management platform is assumed up front - CDP/LLDP identity is checked against the Intersight CSV ($IntersightCsvPath, Name column) first for every host." -ForegroundColor Cyan

    # A host vCenter cannot reach has no CDP/LLDP to read, no service profile to resolve, and
    # nothing that can be driven through it. It is SET ASIDE, not stopped on: the rest of the
    # cluster is still upgraded and the host is named in the manual rectification report at the end.
    # Previously it fell through to the manual-UCSM-target prompt and then to a Stop-WithMessage on
    # the unresolvable service profile, taking every other host in the cluster down with it.
    $reachable = New-Object System.Collections.ArrayList
    foreach ($hostObj in $Hosts) {
        if ($hostObj.ConnectionState -eq "Connected" -or $hostObj.ConnectionState -eq "Maintenance") {
            [void]$reachable.Add($hostObj)
            continue
        }
        Write-Host "  '$($hostObj.Name)' is $($hostObj.ConnectionState) - no CDP/LLDP can be read, so it is set aside for manual rectification. The rest of the cluster continues." -ForegroundColor Yellow
        Add-ManualAttentionHost -HostName $hostObj.Name -Reason "Not reachable from vCenter" -Detail "ConnectionState is $($hostObj.ConnectionState). No CDP/LLDP identity could be read, so neither Intersight nor UCS Manager could be resolved. Bring the host back into vCenter and upgrade it separately." -ExcludeFromRun
        Add-SummaryRecord -Stage "InfrastructureDetection" -Batch "" -HostName $hostObj.Name -Action "Detect infrastructure" -Result "Unreachable" -Details "ConnectionState=$($hostObj.ConnectionState); excluded from the run and listed for manual rectification."
    }

    $intersightRoutedRows = New-Object System.Collections.ArrayList
    foreach ($hostObj in $reachable) {
        $preferred = Get-EsxiPreferredDiscovery -VMHostObject $hostObj
        $systemName = if ($null -ne $preferred) { $preferred.SystemName } else { "" }
        $match = Resolve-IntersightCsvMatch -CdpSystemName $systemName

        if ($null -ne $match) {
            $csvRow = $match.Row
            $Global:IntersightHostMap[$hostObj.Name] = [pscustomobject]@{
                Host            = $hostObj.Name
                Vmnic           = $preferred.Vmnic
                CdpSystemName   = $systemName
                IntersightCsvRow = $csvRow
                MatchedKey      = $match.MatchedKey
                HostObject      = $hostObj
            }
            [void]$intersightRoutedRows.Add([pscustomobject]@{ Host=$hostObj.Name; CdpSystemName=$systemName; MatchedOn=$match.MatchedKey; IntersightCsvName=$csvRow.Name; Infrastructure="Intersight" })
        }
        else {
            [void]$ucsOnlyHosts.Add($hostObj)
        }
    }

    if ($intersightRoutedRows.Count -gt 0) {
        Write-Host "Detected as Intersight-managed (CDP/LLDP name matched the Name column in $IntersightCsvPath, allowing for -A, -B and suffix-less forms):" -ForegroundColor Green
        $intersightRoutedRows | Format-Table -AutoSize | Out-Host
        foreach ($row in $intersightRoutedRows) {
            Add-SummaryRecord -Stage "InfrastructureDetection" -Batch "" -HostName $row.Host -Action "Detect infrastructure" -Result "Intersight" -Details "CdpSystemName=$($row.CdpSystemName); MatchedOn=$($row.MatchedOn); CsvName=$($row.IntersightCsvName)."
        }

        # A fabric has been detected, so ask for the appliance address now rather than at first
        # API call. Getting the endpoint wrong is cheap to fix here and expensive to fix mid-batch.
        [void](Get-IntersightBaseUrlIfNeeded -DetectedFabricNames @($intersightRoutedRows | Select-Object -ExpandProperty IntersightCsvName))

        # Authenticate and resolve every server profile NOW, while no host has been touched.
        # Leaving this until the accept/reboot step meant the first Intersight credential prompt
        # appeared after the batch was already in Maintenance mode and past the safety window, so
        # a bad key stranded the batch instead of stopping the run harmlessly.
        Initialize-IntersightRoutedHosts
    }

    if ($ucsOnlyHosts.Count -eq 0) {
        Write-Host "Every selected host was detected as Intersight-managed. No UCS Manager login is required for this cluster." -ForegroundColor Green
        return
    }

    Write-Host "Detected as UCS Manager-managed (no CDP/LLDP match in the Intersight CSV): $(($ucsOnlyHosts | Select-Object -ExpandProperty Name) -join ', ')" -ForegroundColor Green
    foreach ($hostObj in $ucsOnlyHosts) {
        Add-SummaryRecord -Stage "InfrastructureDetection" -Batch "" -HostName $hostObj.Name -Action "Detect infrastructure" -Result "UCSManager" -Details "No CDP/LLDP match in Intersight CSV."
    }

    Assert-UcsPowerToolAvailable
    Clear-ExistingUcsSessions -Reason "Starting UCSM discovery/mapping for hosts detected as UCS Manager-managed"

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Scanning UCS Manager-detected cluster hosts for UCSM discovery information before login..." -ForegroundColor Cyan

    $discoveryRows = New-Object System.Collections.ArrayList

    foreach ($hostObj in $ucsOnlyHosts) {
        # Cached from the detection pass above - no second QueryNetworkHint round trip.
        $preferred = Get-EsxiPreferredDiscovery -VMHostObject $hostObj

        if ($null -ne $preferred) {
            $systemName = $preferred.SystemName
            $candidate = (Get-UcsCandidateListFromSystemName -SystemName $systemName | Select-Object -First 1)
            [void]$discoveryRows.Add([pscustomobject]@{
                Host          = $hostObj.Name
                Vmnic         = $preferred.Vmnic
                CdpSystemName = $systemName
                UcsTarget     = $candidate
                Discovery     = "AUTO_DISCOVERED"
                HostObject     = $hostObj
            })
        }
        else {
            [void]$discoveryRows.Add([pscustomobject]@{
                Host          = $hostObj.Name
                Vmnic         = ""
                CdpSystemName = ""
                UcsTarget     = ""
                Discovery     = "NO_CDP_LLDP"
                HostObject     = $hostObj
            })
        }
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "UCSM discovery summary for cluster hosts:" -ForegroundColor Cyan
    $discoveryRows | Select-Object Host,Vmnic,CdpSystemName,UcsTarget,Discovery | Format-Table -AutoSize | Out-Host

    $missingTargets = @($discoveryRows | Where-Object { [string]::IsNullOrWhiteSpace($_.UcsTarget) })
    if ($missingTargets.Count -gt 0) {
        Write-Host "One or more hosts did not return a UCSM target from CDP/LLDP. Enter one manually, or SKIP to set the host aside and carry on with the rest of the cluster." -ForegroundColor Yellow
        foreach ($row in $missingTargets) {
            $manual = Read-Host "Enter UCSM FQDN/IP for host $($row.Host), or S to leave it out of this run, or E to exit"
            $answer = $manual.Trim().ToUpper()
            if ($answer -in @("E","EXIT")) { Stop-SafeExit -Message "Stopped during manual UCSM mapping." }
            # SKIP sets the host aside without ending the run. One host with no CDP must not cost
            # the operator the whole cluster.
            if ($answer -in @("S","SKIP") -or $answer -eq "") {
                Write-Host "  '$($row.Host)' set aside - it will not be batched, and is listed for manual rectification at the end." -ForegroundColor Yellow
                Add-ManualAttentionHost -HostName $row.Host -Reason "No CDP/LLDP, no UCSM target given" -Detail "Neither CDP/LLDP nor the operator supplied a UCS Manager target, so the service profile could not be resolved. Upgrade this host separately." -ExcludeFromRun
                Add-SummaryRecord -Stage "InfrastructureDetection" -Batch "" -HostName $row.Host -Action "Detect infrastructure" -Result "NoTarget" -Details "No CDP/LLDP and no manual UCSM target; excluded from the run."
                continue
            }
            $row.UcsTarget = Remove-UcsTargetDecoration -Value $manual
            $row.Discovery = "MANUAL_NO_CDP"
        }
        # Rebuilt rather than filtered in place: New-Object ArrayList with a piped ArgumentList
        # binds to the wrong constructor overload and throws "Argument types do not match".
        $keptRows = New-Object System.Collections.ArrayList
        foreach ($discoveryRow in @($discoveryRows)) {
            if (-not [string]::IsNullOrWhiteSpace($discoveryRow.UcsTarget)) { [void]$keptRows.Add($discoveryRow) }
        }
        $discoveryRows = $keptRows
        if ($discoveryRows.Count -eq 0) {
            Write-Host "No UCS Manager-managed host in this cluster could be resolved to a UCSM target. Continuing with the Intersight-managed hosts only." -ForegroundColor Yellow
            return
        }
    }

    $uniqueTargets = @($discoveryRows | Select-Object -ExpandProperty UcsTarget -Unique | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($uniqueTargets.Count -eq 1) {
        Write-Host "All discovered cluster hosts are mapped to single UCSM target: $($uniqueTargets[0])" -ForegroundColor Green
    }
    else {
        Write-Host "Multiple UCSM targets discovered for this cluster:" -ForegroundColor Yellow
        $uniqueTargets | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
    }

    foreach ($targetName in $uniqueTargets) {
        $session = Connect-UcsCached -UcsTarget $targetName
        if ($null -eq $session) {
            Write-Host "Auto UCSM login failed for discovered target '$targetName'. Manual UCSM target is required for hosts mapped to this target." -ForegroundColor Yellow
            $manualTarget = Read-Host "Enter replacement UCSM FQDN/IP for discovered target '$targetName', or E to exit"
            if ($manualTarget.Trim().ToUpper() -in @("E","EXIT")) { Stop-SafeExit -Message "Stopped during manual UCSM mapping." }
            $manualTarget = Remove-UcsTargetDecoration -Value $manualTarget
            $session = Connect-UcsCached -UcsTarget $manualTarget
            if ($null -eq $session) { Stop-WithMessage "Manual UCSM login failed for $manualTarget." }
            foreach ($row in @($discoveryRows | Where-Object { $_.UcsTarget -eq $targetName })) {
                $row.UcsTarget = $manualTarget
                $row.Discovery = "MANUAL_TARGET_REPLACEMENT"
            }
        }
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Resolving service profiles and current firmware policy for all hosts..." -ForegroundColor Cyan

    $mappingRows = New-Object System.Collections.ArrayList
    foreach ($row in $discoveryRows) {
        $sp = Resolve-UcsServiceProfileForHost -HostName $row.Host -UcsTarget $row.UcsTarget
        # Set aside, not stopped on. One host UCSM cannot account for must not cost the cluster.
        if ($null -eq $sp) {
            Write-Host "  Could not resolve a UCS service profile for '$($row.Host)' in UCSM $($row.UcsTarget) - set aside for manual rectification." -ForegroundColor Yellow
            Add-ManualAttentionHost -HostName $row.Host -Reason "No UCS service profile" -Detail "UCSM $($row.UcsTarget) returned no service profile for this host, so no firmware policy could be applied. Check the blade's service profile association in UCS Manager." -ExcludeFromRun
            Add-SummaryRecord -Stage "UcsMapping" -Batch "" -HostName $row.Host -Action "Resolve service profile" -Result "NotFound" -Details "UCSM $($row.UcsTarget) returned no service profile; excluded from the run."
            continue
        }
        $currentPolicy = Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $sp
        $mapRow = [pscustomobject]@{
            Host               = $row.Host
            Vmnic              = $row.Vmnic
            CdpSystemName      = $row.CdpSystemName
            UcsTarget          = $row.UcsTarget
            Discovery          = $row.Discovery
            ServiceProfileDn   = $sp.Dn
            ServiceProfileName = $sp.Name
            CurrentPolicy      = $currentPolicy
            TargetPolicy       = ""
        }
        $Global:UcsHostMap[$row.Host] = $mapRow
        [void]$mappingRows.Add($mapRow)
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "UCSM host mapping and current firmware policy:" -ForegroundColor Cyan
    $mappingRows | Select-Object Host,Vmnic,UcsTarget,ServiceProfileDn,CurrentPolicy | Format-Table -AutoSize | Out-Host

    $uniqueTargets = @($mappingRows | Select-Object -ExpandProperty UcsTarget -Unique)
    if ($uniqueTargets.Count -eq 0) { Stop-WithMessage "No UCSM targets were discovered for firmware policy selection." }

    # Derived per UCSM domain from its fabric interconnect family, not chosen once for the whole
    # cluster - a cluster spanning a 6300 and a 6400 domain needs a different package in each.
    foreach ($targetName in $uniqueTargets) {
        $targetSession = Get-UcsSessionForTarget -UcsTarget $targetName
        [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget $targetName -UcsSession $targetSession)
    }

    foreach ($row in $mappingRows) {
        $row.TargetPolicy = $Global:UcsFirmwarePolicyByTarget[$row.UcsTarget]
        $Global:UcsHostMap[$row.Host] = $row
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Final UCSM host mapping with selected target firmware policy:" -ForegroundColor Cyan
    $mappingRows | Select-Object Host,Vmnic,UcsTarget,ServiceProfileDn,CurrentPolicy,TargetPolicy | Format-Table -AutoSize | Out-Host

    foreach ($targetName in $uniqueTargets) {
        $ucsSession = Get-UcsSessionForTarget -UcsTarget $targetName
        $targetPolicy = $Global:UcsFirmwarePolicyByTarget[$targetName]
        if (-not (Test-UcsFirmwarePolicyExists -PolicyName $targetPolicy -UcsSession $ucsSession)) {
            Write-Host "WARNING: Target UCS firmware policy '$targetPolicy' was not returned by PowerTool from UCSM $targetName after resolution." -ForegroundColor Yellow
            Write-Host "If this was a manual policy selection, the later Set-UcsServiceProfile step will still attempt to apply it directly." -ForegroundColor Yellow
            Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Validate selected policy" -Result "Warning" -Details "Policy $targetPolicy not returned by PowerTool on $targetName."
        }
    }

    Add-SummaryRecord -Stage "UCSMMapping" -Batch "" -HostName "" -Action "Map hosts" -Result "Completed" -Details "$($mappingRows.Count) hosts mapped. Policies by domain: $((($Global:UcsFirmwarePolicyByTarget.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '))."
}

function Set-UcsFirmwarePolicyForBatch {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,
        [Parameter(Mandatory=$true)][string]$BatchNumber,
        # RECHECK re-enters this function. Bounded so a policy that never converges ends in a
        # clean stop instead of recursing until the call stack gives out.
        [int]$Attempt = 1,
        [int]$MaxAttempts = 5
    )

    $rows = foreach ($hostName in $HostNames) { $Global:UcsHostMap[$hostName] }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "UCS firmware policy change preview for Batch ${BatchNumber}:" -ForegroundColor Cyan
    $rows | Select-Object Host,UcsTarget,ServiceProfileDn,CurrentPolicy,TargetPolicy | Format-Table -AutoSize | Out-Host

    if (Test-DryRun) {
        Write-Host "DRY RUN: Would apply target UCS firmware policy to current batch service profiles only." -ForegroundColor Green
        foreach ($row in $rows) {
            Add-SummaryRecord -Stage "UCSMFirmwarePolicy" -Batch $BatchNumber -HostName $row.Host -Action "Apply firmware policy" -Result "DryRun" -Details "Would set $($row.ServiceProfileDn) to $($row.TargetPolicy)."
        }
        return
    }

    $verificationRows = New-Object System.Collections.ArrayList

    foreach ($row in $rows) {
        $ucsSession = Get-UcsSessionForTarget -UcsTarget $row.UcsTarget
        $spBefore = Get-UcsServiceProfile -Ucs $ucsSession -Dn $row.ServiceProfileDn -ErrorAction Stop
        $beforePolicy = Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $spBefore

        $setResult = "Skipped"
        $setDetails = "Already target policy before change."

        # Each host's policy comes from its own UCSM domain's fabric family.
        $wantedPolicy = [string]$row.TargetPolicy
        if ([string]::IsNullOrWhiteSpace($wantedPolicy)) {
            Stop-WithMessage "No firmware policy was resolved for host $($row.Host) in domain $($row.UcsTarget)."
        }
        if ($beforePolicy -ne $wantedPolicy) {
            Set-UcsServiceProfile -Ucs $ucsSession -ServiceProfile $spBefore -HostFwPolicyName $wantedPolicy -Force -ErrorAction Stop | Out-Null
            $setResult = "SetSent"
            $setDetails = "Set command sent from $beforePolicy to $wantedPolicy."
        }

        Start-Sleep -Seconds 2

        $spAfter = Get-UcsServiceProfile -Ucs $ucsSession -Dn $row.ServiceProfileDn -ErrorAction Stop
        $afterPolicy = Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $spAfter
        $verified = ($afterPolicy -eq $wantedPolicy)
        $verifyResult = if ($verified) { "Verified" } else { "NotVerified" }

        $row.CurrentPolicy = $afterPolicy
        $row.TargetPolicy = $wantedPolicy
        $Global:UcsHostMap[$row.Host] = $row

        [void]$verificationRows.Add([pscustomobject]@{
            ScriptVersion    = $ScriptVersion
            Batch            = $BatchNumber
            Host             = $row.Host
            UcsTarget        = $row.UcsTarget
            ServiceProfileDn = $row.ServiceProfileDn
            BeforePolicy     = $beforePolicy
            RequestedPolicy  = $wantedPolicy
            AfterPolicy      = $afterPolicy
            Result           = $verifyResult
            Action           = $setResult
        })

        Add-SummaryRecord -Stage "UCSMFirmwarePolicy" -Batch $BatchNumber -HostName $row.Host -Action "Apply firmware policy" -Result $verifyResult -Details "$setDetails AfterPolicy=$afterPolicy."
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "UCS firmware policy verification after change for Batch ${BatchNumber}:" -ForegroundColor Cyan
    $verificationRows | Select-Object Host,ServiceProfileDn,BeforePolicy,RequestedPolicy,AfterPolicy,Result | Format-Table -AutoSize | Out-Host

    $proofTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $proofPath = Join-Path $RunDirectory "UCSM-Firmware-Policy-Verification-Batch-$BatchNumber-$proofTimestamp.csv"
    try {
        $verificationRows | Export-Csv -Path $proofPath -NoTypeInformation -Encoding UTF8
        Write-Host "Firmware policy verification proof exported to: $proofPath" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to export firmware policy verification proof CSV: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $failedVerification = @($verificationRows | Where-Object { $_.Result -ne "Verified" })
    if ($failedVerification.Count -gt 0) {
        Write-Host "WARNING: One or more service profiles did not verify with the requested target policy after the set command." -ForegroundColor Yellow
        $failedVerification | Select-Object Host,ServiceProfileDn,BeforePolicy,RequestedPolicy,AfterPolicy,Result | Format-Table -AutoSize | Out-Host
        if ($Attempt -ge $MaxAttempts) {
            Stop-WithMessage "Firmware policy verification still failing after $MaxAttempts attempts for Batch $BatchNumber. Resolve in UCSM before continuing."
        }
        $choice = Read-ChoiceExit -Message "Firmware policy verification failed for one or more hosts (attempt $Attempt of $MaxAttempts). R to recheck, X to stop, E to exit" -AllowedChoices @("R","X")
        if ($choice -eq "X") { Stop-WithMessage "Firmware policy verification failed after set command." }
        if ($choice -eq "R") { return Set-UcsFirmwarePolicyForBatch -HostNames $HostNames -BatchNumber $BatchNumber -Attempt ($Attempt + 1) -MaxAttempts $MaxAttempts }
    }
}

function Get-UcsPendingRebootObjectsForBatch {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames)
    $pendingRows = New-Object System.Collections.ArrayList

    # Pending-ack objects are fetched once per UCSM domain for the whole batch instead of once per
    # host. The cache is local to this call so each batch still reads current state.
    $ackCache = @{}

    foreach ($hostName in $HostNames) {
        $map = $Global:UcsHostMap[$hostName]
        $ucsSession = Get-UcsSessionForTarget -UcsTarget $map.UcsTarget

        if (-not $ackCache.ContainsKey($map.UcsTarget)) {
            $ackCache[$map.UcsTarget] = @()
            try { $ackCache[$map.UcsTarget] = @(Get-UcsLsmaintAck -Ucs $ucsSession -ErrorAction SilentlyContinue) } catch {}
        }

        $ackObject = $ackCache[$map.UcsTarget] |
            Where-Object { $_.Dn -like "$($map.ServiceProfileDn)/*" -or $_.Dn -eq "$($map.ServiceProfileDn)/ack" } |
            Select-Object -First 1

        [void]$pendingRows.Add([pscustomobject]@{ Host=$hostName; UcsTarget=$map.UcsTarget; ServiceProfileDn=$map.ServiceProfileDn; PendingAckFound=($null -ne $ackObject); AckDn=if($ackObject){$ackObject.Dn}else{""}; AckObject=$ackObject })
    }
    return @($pendingRows)
}

function Invoke-UcsPendingAckForBatch {
    <#
    .SYNOPSIS
        Waits for UCS Manager to raise the pending activity for each host in the batch, acknowledges
        it, and confirms the acknowledgement cleared.

    .DESCRIPTION
        UCSM raises the pending activity ASYNCHRONOUSLY after the service profile's firmware package
        changes. Asking for it the moment the policy write returns is a race: on a busy domain the
        object is not there yet, every host reads PendingAckFound=$false, the loop acknowledges
        nothing, and the run reports a batch sent while the blades sit staged and waiting. The
        symptom is exactly "the firmware policy updated on the blades but has not acknowledged".

        So it is WAITED for, up to $UcsPendingAckWaitMinutes, and the acknowledgement is then
        CONFIRMED by re-reading rather than assumed from the write returning.

        A host that never raises one is reported rather than retried forever. That is not always
        wrong - a service profile whose maintenance policy is immediate rather than user-ack
        reboots on its own and raises nothing - so it is stated as what it is, and the reboot
        detection downstream, which compares boot times, remains the authority on whether the host
        actually restarted.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)

    if (Test-DryRun) {
        $preview = @(Get-UcsPendingRebootObjectsForBatch -HostNames $HostNames)
        $preview | Select-Object Host,UcsTarget,ServiceProfileDn,PendingAckFound,AckDn | Format-Table -AutoSize | Out-Host
        Write-Host "DRY RUN: Would acknowledge only listed current-batch UCSM pending objects." -ForegroundColor Green
        return
    }

    # 1. WAIT for the pending activity to appear. Polled, not slept: on a quiet domain it is there
    #    on the first look and this costs nothing.
    $deadline = (Get-Date).AddMinutes([double]$UcsPendingAckWaitMinutes)
    $pendingRows = @()
    $announced = $false
    while ($true) {
        $pendingRows = @(Get-UcsPendingRebootObjectsForBatch -HostNames $HostNames)
        $waitingFor = @($pendingRows | Where-Object { -not $_.PendingAckFound })
        if ($waitingFor.Count -eq 0) { break }
        if ((Get-Date) -ge $deadline) { break }
        if (-not $announced) {
            Write-Host "Waiting up to $UcsPendingAckWaitMinutes minute(s) for UCS Manager to raise the pending activity for: $(($waitingFor | Select-Object -ExpandProperty Host) -join ', ')" -ForegroundColor Yellow
            $announced = $true
        }
        Start-Sleep -Seconds 15
    }

    $pendingRows | Select-Object Host,UcsTarget,ServiceProfileDn,PendingAckFound,AckDn | Format-Table -AutoSize | Out-Host

    # The typed ACK-BATCH-N gate that used to sit here has been removed so the run advances
    # through the cluster on its own. The abort point is now the pre-reboot safety window
    # immediately before this call, which covers the whole batch and accepts E to exit.
    $withPending = @($pendingRows | Where-Object { $_.PendingAckFound })
    Write-Host "Acknowledging UCSM pending reboot for Batch $BatchNumber ($($withPending.Count) host(s) with a pending activity)." -ForegroundColor Yellow

    foreach ($row in $withPending) {
        $ucsSession = Get-UcsSessionForTarget -UcsTarget $row.UcsTarget
        Set-UcsLsmaintAck -Ucs $ucsSession -LsmaintAck $row.AckObject -AdminState "trigger-immediate" -Force -ErrorAction Stop | Out-Null
        $Global:BatchActionsSent++
        Add-SummaryRecord -Stage "UCSMAcknowledge" -Batch $BatchNumber -HostName $row.Host -Action "Acknowledge pending activity" -Result "Sent" -Details $row.AckDn
    }

    # 2. CONFIRM. The write returning is not proof the domain took it - and an acknowledgement that
    #    did not take leaves the blade staged with nothing on screen to say so.
    if ($withPending.Count -gt 0) {
        Start-Sleep -Seconds 10
        $after = @(Get-UcsPendingRebootObjectsForBatch -HostNames @($withPending | Select-Object -ExpandProperty Host))
        foreach ($row in $after) {
            if (-not $row.PendingAckFound) {
                Write-Host "  '$($row.Host)': acknowledged - the pending activity has cleared." -ForegroundColor Green
                Add-SummaryRecord -Stage "UCSMAcknowledge" -Batch $BatchNumber -HostName $row.Host -Action "Confirm acknowledgement" -Result "Cleared" -Details "The pending activity is no longer present, so UCS Manager accepted the trigger."
                continue
            }
            Write-Host "  '$($row.Host)': the pending activity is STILL present after the acknowledgement." -ForegroundColor Yellow
            Write-Host "    The blade is staged and waiting. Acknowledge it in UCSM under Pending Activities if it does not clear." -ForegroundColor Yellow
            Add-ManualAttentionHost -HostName $row.Host -Reason "Pending activity not acknowledged" -Detail "The firmware package was set and trigger-immediate was sent, but $($row.AckDn) is still present. The blade is staged and will not reboot until it is acknowledged in UCSM under Pending Activities."
            Add-SummaryRecord -Stage "UCSMAcknowledge" -Batch $BatchNumber -HostName $row.Host -Action "Confirm acknowledgement" -Result "StillPending" -Details "$($row.AckDn) is still present after trigger-immediate."
        }
    }

    # 3. Hosts that never raised one at all.
    foreach ($row in @($pendingRows | Where-Object { -not $_.PendingAckFound })) {
        Write-Host "  '$($row.Host)': no pending activity was raised within $UcsPendingAckWaitMinutes minute(s)." -ForegroundColor Yellow
        Write-Host "    Either the firmware package change did not take, or this profile's maintenance policy is not user-ack and it will reboot on its own." -ForegroundColor Yellow
        Add-SummaryRecord -Stage "UCSMAcknowledge" -Batch $BatchNumber -HostName $row.Host -Action "Acknowledge pending activity" -Result "NoneRaised" -Details "No lsmaintAck appeared under $($row.ServiceProfileDn) within $UcsPendingAckWaitMinutes minute(s). Either the package change did not take, or the maintenance policy is not user-ack."
    }
}

# -----------------------------
# Intersight PVA hardened login, discovery, and inconsistency remediation
#
# NOTE: cmdlet names below follow the CiscoDevNet Intersight.PowerShell naming convention
# (Get-Intersight<Mo>, New-Intersight<Mo>, Initialize-Intersight<ComplexType>) but the exact
# parameter surface for triggering an immediate-reboot firmware upgrade shifts between module
# releases. As with the UCSM cmdlets in this script: validate against
# `Get-Help New-IntersightFirmwareUpgrade -Full` (or the current equivalent) in your installed
# module version before LIVE RUN, and adjust the marked TODO-VALIDATE lines if needed.
# -----------------------------

function Assert-IntersightPowerShellAvailable {
    <#
    .SYNOPSIS
        Confirms the Intersight cmdlets this script calls are actually available.

    .DESCRIPTION
        A cmdlet-existence check only. No module enumeration and no version comparison - listing
        versions of a module exporting several thousand cmdlets is slow enough on a domain jump
        host to look like a hang, and the environment is assumed to meet the requirements stated
        in the script header.

        Version information is still gathered when it is actually worth the wait: on the failure
        path, by Write-IntersightLoginDiagnostics.
    #>
    foreach ($cmdletName in @("Set-IntersightConfiguration","Get-IntersightServerProfile")) {
        if ($null -eq (Get-Command -Name $cmdletName -ErrorAction SilentlyContinue)) {
            Stop-WithMessage "Intersight.PowerShell module was not found ($cmdletName is missing). Import Intersight.PowerShell before running against hosts mapped to Intersight. If more than one version is installed, load the pinned one with: . .\tools\Import-RichoModuleBundle.ps1"
        }
    }
}

function Get-IntersightDeployRefusalReason {
    <#
    .SYNOPSIS
        Turns an Intersight deploy refusal into something an operator can act on.

    .DESCRIPTION
        The appliance is specific about why it will not deploy, and that detail is worth keeping
        rather than flattening into "deploy failed". Each one is a different job for a different
        person, and the manual rectification report is only useful if it says which.

        Recognised, from live runs and the appliance's own messageIds:

          gershwin_server_is_not_connected      The blade is not talking to Intersight. Nothing
                                                about the profile or the firmware policy is wrong -
                                                the device connector, the FI, or the server itself
                                                is unreachable. No amount of retrying from here
                                                helps.
          gershwin_user_action_is_not_allowed   The action is not valid from the profile's current
                                                state. Handled earlier by the Activate/Deploy
                                                fallback; if it reaches here, both forms were
                                                refused.
          action_not_allowed_firmware_upgrade   Something is already running against this server.

        Anything unrecognised keeps the appliance's own words. Never invent a cause.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
        # What the pre-flight found. $true means a server really was assigned to this profile, so a
        # disconnect message is about connectivity. $false means none could be read, which makes the
        # wrong-profile explanation far more likely - and that changes where the operator looks.
        [bool]$ProfileHasServer = $true
    )

    if ($Message -match '(?i)gershwin_server_is_not_connected|server is disconnected|the server is not connected') {
        if (-not $ProfileHasServer) {
            return [pscustomobject]@{
                Reason  = "Deployed against a profile with no server on it"
                Summary = "the profile has no server assigned, which the appliance reports as 'the server is disconnected'"
                Advice  = "The blade is probably fine - this run resolved to the wrong profile. Profile names are NOT unique in Intersight, so a duplicate name can resolve to an unassigned or decommissioned copy. Confirm the profile in Intersight and pin the correct one by putting its Moid in the Moid column of $IntersightCsvPath for this host."
            }
        }
        return [pscustomobject]@{
            Reason  = "Server disconnected from Intersight"
            Summary = "the appliance says the server is disconnected, so the profile cannot be deployed"
            Advice  = "A server WAS assigned to this profile, so this is connectivity - check the blade's device connector and its Fabric Interconnect. If Intersight and vCenter both show the server healthy, re-check that this is the right profile: names are not unique, and the Moid column of $IntersightCsvPath pins it."
        }
    }
    if ($Message -match '(?i)gershwin_user_action_is_not_allowed|not allowed in the current state') {
        return [pscustomobject]@{
            Reason  = "Deploy not allowed from the profile's current state"
            Summary = "the appliance refused both Activate and Deploy from this profile's state"
            Advice  = "Check the profile in Intersight - it may already have an action running, or be in a state that has to be cleared by hand."
        }
    }
    if ($Message -match '(?i)firmware_upgrade_in_progress|firmware upgrade is in progress') {
        return [pscustomobject]@{
            Reason  = "A firmware upgrade is already running"
            Summary = "Intersight already has a firmware upgrade running against this server"
            Advice  = "Let the running upgrade finish, then re-run for this host."
        }
    }

    return [pscustomobject]@{
        Reason  = "Intersight refused the deploy"
        Summary = $Message
        Advice  = "See the appliance message for the reason."
    }
}

function Get-IntersightFailureKind {
    <#
    .SYNOPSIS
        Separates a rejected key from a key that worked but whose reply could not be parsed.

    .DESCRIPTION
        Intersight.PowerShell reports both as "Error performing this operation. Check that
        BasePath and API Key identifier are configured correctly", which points at credentials
        in both cases. Only one of them is about credentials.

        A deserialization failure is proof of success at the protocol level: the appliance only
        returns a populated Results payload to a request whose HTTP signature it has already
        verified. Reaching the deserializer means authentication passed and the module version
        does not match the appliance's API schema.
    #>
    param([Parameter(Mandatory=$true)]$ErrorRecord)

    $ex = $ErrorRecord.Exception
    $depth = 0
    while ($null -ne $ex -and $depth -lt 6) {
        if ($ex.Message -match 'cannot be deserialized into any schema') {
            return [pscustomobject]@{ Kind='Deserialization'; Authenticated=$true }
        }
        if ($ex.Message -match 'iam_api_key_is_invalid|AuthenticationFailure|401|Unauthorized|signature|cannot sign http request|invalid.{0,20}key') {
            return [pscustomobject]@{ Kind='Authentication'; Authenticated=$false }
        }
        $ex = $ex.InnerException
        $depth++
    }
    return [pscustomobject]@{ Kind='Unknown'; Authenticated=$false }
}

function Get-ExceptionDetail {
    <#
    .SYNOPSIS
        Flattens an exception chain, surfacing any HTTP status and response body.

    .DESCRIPTION
        Intersight.PowerShell wraps API failures in a generic "check that BasePath and API Key
        identifier are configured correctly" message. The useful part - the HTTP status code and
        the response body, which distinguish a signature rejection from a wrong endpoint - is in
        the inner exception. Reporting only $_.Exception.Message throws that away.
    #>
    param([Parameter(Mandatory=$true)]$ErrorRecord)

    $lines = New-Object System.Collections.Generic.List[string]
    $ex = $ErrorRecord.Exception
    $depth = 0

    while ($null -ne $ex -and $depth -lt 6) {
        # Truncated: a deserialization failure embeds the whole API response in its message,
        # which runs to thousands of lines and buries every other clue.
        $flat = ($ex.Message -replace '\s+', ' ').Trim()
        if ($flat.Length -gt 400) { $flat = $flat.Substring(0, 400) + "... [truncated, $($flat.Length) chars total]" }
        [void]$lines.Add("  [$($ex.GetType().Name)] $flat")

        foreach ($prop in @("StatusCode","ErrorCode")) {
            try {
                if ($ex.PSObject.Properties.Name -contains $prop -and $null -ne $ex.$prop) {
                    $value = [string]$ex.$prop
                    if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$lines.Add("      ${prop}: $value") }
                }
            } catch {}
        }
        $ex = $ex.InnerException
        $depth++
    }

    return ($lines -join [Environment]::NewLine)
}

function Test-IntersightEndpointReachable {
    <#
    .SYNOPSIS
        Checks the appliance answers HTTPS at all, separately from whether the key is accepted.

    .DESCRIPTION
        Distinguishes "wrong or unreachable FQDN" from "endpoint fine, key rejected" - the module's
        error message covers both and names neither. Any HTTP response, including 401/403, proves
        reachability. Only DNS failure, TLS failure or timeout mean unreachable.
    #>
    param([Parameter(Mandatory=$true)][string]$BaseUrl)

    $params = @{
        Uri             = "$BaseUrl/"
        Method          = 'Get'
        TimeoutSec      = 20
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }

    $supportsSkip = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')
    if ($supportsSkip -and $Global:IntersightSkipCertificateCheck) { $params['SkipCertificateCheck'] = $true }

    # Windows PowerShell 5.1 has no -SkipCertificateCheck, so the validation callback is relaxed
    # for this one probe and restored immediately afterwards.
    $previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        if (-not $supportsSkip -and $Global:IntersightSkipCertificateCheck) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
        $response = Invoke-WebRequest @params
        return [pscustomobject]@{ Reachable=$true; StatusCode=[int]$response.StatusCode; Detail="HTTP $([int]$response.StatusCode) from $BaseUrl/" }
    }
    catch [System.Net.WebException] {
        $status = $null
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch {}
        if ($status) { return [pscustomobject]@{ Reachable=$true; StatusCode=$status; Detail="HTTP $status from $BaseUrl/ - endpoint answered." } }
        return [pscustomobject]@{ Reachable=$false; StatusCode=$null; Detail=$_.Exception.Message }
    }
    catch {
        $status = $null
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch {}
        if ($status) { return [pscustomobject]@{ Reachable=$true; StatusCode=$status; Detail="HTTP $status from $BaseUrl/ - endpoint answered." } }
        return [pscustomobject]@{ Reachable=$false; StatusCode=$null; Detail=$_.Exception.Message }
    }
    finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
    }
}

function Write-IntersightLoginDiagnostics {
    <#
    .SYNOPSIS
        Prints everything needed to tell apart the causes of an Intersight login failure.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$BasePath,
        [Parameter(Mandatory=$true)]$ErrorRecord
    )

    Write-Host "" -ForegroundColor Yellow
    Write-Host "--------------------- Intersight login diagnostics ---------------------" -ForegroundColor Yellow

    Write-Host "Full error chain:" -ForegroundColor Yellow
    Write-Host (Get-ExceptionDetail -ErrorRecord $ErrorRecord) -ForegroundColor Gray

    Write-Host "Endpoint reachability:" -ForegroundColor Yellow
    $reach = Test-IntersightEndpointReachable -BaseUrl $BasePath
    if ($reach.Reachable) {
        Write-Host "  $($reach.Detail)" -ForegroundColor Gray
        Write-Host "  The appliance is answering, so this is about the key or the signature, not the address." -ForegroundColor Gray
    }
    else {
        Write-Host "  UNREACHABLE: $($reach.Detail)" -ForegroundColor Red
        Write-Host "  Fix name resolution, routing or the certificate before looking at the API key." -ForegroundColor Red
    }

    Write-Host "Installed module versions:" -ForegroundColor Yellow
    $installed = @(Get-AvailableModuleVersion -Name Intersight.PowerShell | Select-Object -ExpandProperty Version -Unique)
    Write-Host "  $((($installed | ForEach-Object { $_.ToString() }) -join ', '))" -ForegroundColor Gray
    if ($installed.Count -gt 1) {
        Write-Host "  MORE THAN ONE VERSION INSTALLED - this is the most common cause of this exact failure." -ForegroundColor Red
        Write-Host "  Remove the older versions, restart PowerShell, and retry." -ForegroundColor Red
    }

    Write-Host "Active configuration:" -ForegroundColor Yellow
    try {
        $cfg = Get-IntersightConfiguration -ErrorAction Stop
        Write-Host "  BasePath          : $($cfg.BasePath)" -ForegroundColor Gray
        Write-Host "  ApiKeyId          : $($cfg.ApiKeyId)" -ForegroundColor Gray
        Write-Host "  ApiKeyFilePath    : $($cfg.ApiKeyFilePath)" -ForegroundColor Gray
        Write-Host "  HttpSigningHeader : $(($cfg.HttpSigningHeader) -join ', ')" -ForegroundColor Gray
        Write-Host "  HashAlgorithm     : $($cfg.HashAlgorithm)" -ForegroundColor Gray
    }
    catch { Write-Host "  Get-IntersightConfiguration failed: $($_.Exception.Message)" -ForegroundColor Gray }

    Write-Host "API key material:" -ForegroundColor Yellow
    $segments = @($Global:IntersightApiKeyId -split '/')
    Write-Host "  Key ID segments   : $($segments.Count) (must be 3)" -ForegroundColor Gray
    try {
        $firstLine = (Get-Content -Path $Global:IntersightApiKeyFilePath -TotalCount 1 -ErrorAction Stop)
        Write-Host "  Private key header: $firstLine" -ForegroundColor Gray
        if ($firstLine -match 'EC PRIVATE KEY') {
            Write-Host "  This is an EC key, which Intersight issues for API key v3." -ForegroundColor Gray
        }
        elseif ($firstLine -match 'RSA PRIVATE KEY') {
            Write-Host "  This is an RSA key, which Intersight issues for API key v2." -ForegroundColor Gray
        }
        elseif ($firstLine -match 'BEGIN PRIVATE KEY') {
            Write-Host "  PKCS#8 wrapper. Intersight expects a PEM in EC or RSA form - if the login keeps failing, re-download the secret key rather than converting it." -ForegroundColor Yellow
        }
    }
    catch { Write-Host "  Could not read the private key file: $($_.Exception.Message)" -ForegroundColor Gray }

    Write-Host "" -ForegroundColor Yellow
    Write-Host "Most likely causes, in order:" -ForegroundColor Yellow
    Write-Host "  1. More than one Intersight.PowerShell version installed." -ForegroundColor Yellow
    Write-Host "  2. Key ID and .pem are not a matched pair - they are only valid together, and the" -ForegroundColor Yellow
    Write-Host "     secret is downloadable only at creation. Generate a fresh key pair and retry." -ForegroundColor Yellow
    Write-Host "  3. The API key was created on a different appliance or account than $BasePath." -ForegroundColor Yellow
    Write-Host "  4. The key has been deleted or disabled in Settings > API Keys." -ForegroundColor Yellow
    Write-Host "  5. $BasePath is reachable but is not an Intersight PVA appliance." -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------------------" -ForegroundColor Yellow
}

function ConvertTo-IntersightBaseUrl {
    <#
    .SYNOPSIS
        Normalises an operator-entered Intersight address into a usable BasePath, or "" if invalid.

    .DESCRIPTION
        Accepts what people actually type - a bare FQDN, a full URL, a trailing slash, a pasted
        /api/v1 suffix, an IP, an optional port - and returns "https://<host>[:port]".

        The suffix and trailing slash matter: the module appends the API path itself, and either
        one left in place breaks HTTP signature validation with an error that does not mention the
        URL. Anything with an unexpected path, whitespace or an invalid hostname returns "" so the
        caller can re-prompt rather than fail later at the signing stage.

    .PARAMETER Value
        Raw operator input.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }

    # Not $host - that is a read-only automatic variable and assigning to it throws.
    $hostPart = $Value.Trim().Trim('"').Trim("'")
    $hostPart = $hostPart -replace '^\s*[A-Za-z][A-Za-z0-9+.-]*://', ''   # drop any scheme
    $hostPart = $hostPart -replace '/+$', ''                              # drop trailing slashes
    $hostPart = $hostPart -replace '(?i)/api/v\d+$', ''                   # drop a pasted API path
    $hostPart = $hostPart -replace '/+$', ''
    $hostPart = $hostPart.Trim()

    if ([string]::IsNullOrWhiteSpace($hostPart)) { return "" }

    # Hostname, FQDN or IPv4, with an optional port. Anything else - a remaining path segment,
    # embedded whitespace, a stray credential - is rejected rather than guessed at.
    $pattern = '^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*(:\d{1,5})?$'
    if ($hostPart -notmatch $pattern) { return "" }

    return "https://$hostPart"
}

function Test-IntersightSaaSUrl {
    param([Parameter(Mandatory=$true)][string]$BaseUrl)
    return ($BaseUrl -match '(?i)^https://([A-Za-z0-9-]+\.)*intersight\.com(:\d+)?$')
}

function Get-IntersightBaseUrlIfNeeded {
    <#
    .SYNOPSIS
        Prompts once for the Intersight appliance FQDN and sets it as the API BasePath.

    .DESCRIPTION
        Called as soon as an Intersight-managed fabric is detected, so the operator supplies the
        appliance address at detection time rather than discovering a wrong endpoint later. The
        entered value replaces $Global:IntersightBaseUrl for the rest of the run; the value in
        User Settings is only the default offered at the prompt.

        Certificate checking follows from the address: an on-prem PVA gets -SkipCertificateCheck,
        intersight.com does not.

    .PARAMETER DetectedFabricNames
        Fabric names matched from the CSV, shown for context so the operator can tell which
        appliance is being asked about.
    #>
    param([string[]]$DetectedFabricNames = @())

    if ($Global:IntersightBaseUrlConfirmed) { return $Global:IntersightBaseUrl }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Intersight-managed fabric detected." -ForegroundColor Cyan
    if ($DetectedFabricNames.Count -gt 0) {
        Write-Host "Matched fabric name(s) from $($IntersightCsvPath): $(($DetectedFabricNames | Select-Object -Unique) -join ', ')" -ForegroundColor Cyan
    }
    Write-Host "Enter the Intersight address to authenticate against - the PVA appliance FQDN for" -ForegroundColor Yellow
    Write-Host "on-prem, or intersight.com for SaaS. A bare FQDN is fine; scheme, trailing slash" -ForegroundColor Yellow
    Write-Host "and any /api/v1 suffix are handled for you." -ForegroundColor Yellow

    $default = $Global:IntersightBaseUrl
    do {
        $entry = (Read-Host "Intersight FQDN (press Enter for $default, or type EXIT)").Trim()
        if ($entry.ToUpper() -eq "EXIT") { Stop-SafeExit -Message "Stopped at the Intersight FQDN prompt." }
        if ([string]::IsNullOrWhiteSpace($entry)) { $entry = $default }

        $normalised = ConvertTo-IntersightBaseUrl -Value $entry
        if ([string]::IsNullOrWhiteSpace($normalised)) {
            Write-Host "'$entry' is not a valid hostname, FQDN or IP address. Example: siepd24pva0001.dpe.protected.mil.au" -ForegroundColor Yellow
        }
    } until (-not [string]::IsNullOrWhiteSpace($normalised))

    $Global:IntersightBaseUrl = $normalised
    $Global:IntersightBaseUrlConfirmed = $true

    # Certificate checking is NOT derived from the address any more. -SkipCertificateCheck swaps
    # the module's HTTP handler, which is a credible cause of the corrupted response bodies seen
    # against this PVA, and the minimal call that works there omits it entirely.
    $kind = if (Test-IntersightSaaSUrl -BaseUrl $normalised) { "SaaS" } else { "on-prem PVA" }
    Write-Host "Intersight API BasePath set to $normalised ($kind; certificate check $(if($Global:IntersightSkipCertificateCheck){'skipped'}else{'enforced'}))." -ForegroundColor Green
    Add-SummaryRecord -Stage "IntersightLogin" -Batch "" -HostName "" -Action "Set API BasePath" -Result "Confirmed" -Details "BasePath=$normalised; Kind=$kind; SkipCertificateCheck=$Global:IntersightSkipCertificateCheck."

    return $Global:IntersightBaseUrl
}

function Assert-IntersightUpgradeCmdletSurface {
    <#
    .SYNOPSIS
        Confirms the accept + reboot-immediately call exists with the parameters this script passes.

    .DESCRIPTION
        The firmware upgrade parameter surface moves between Intersight.PowerShell releases. This
        checks it once, before the first blade in the run is touched, so a mismatch surfaces as a
        clean stop rather than as a half-completed batch.

        Deliberately does not fall back to Set-IntersightServerProfile -Action Deploy. Deploy pushes
        the pending profile configuration but is not the same operation as accepting the disruption
        and rebooting immediately, and silently substituting one disruptive action for another is
        not a decision this script should make on its own.
    #>
    if ($Global:IntersightUpgradeSurfaceChecked) { return }

    if ($null -eq (Get-Command -Name Set-IntersightServerProfile -ErrorAction SilentlyContinue)) {
        Stop-WithMessage "Set-IntersightServerProfile is not available in the installed Intersight.PowerShell version, so a server profile cannot be deployed. Check the module install before a LIVE RUN."
    }

    $deployCmd = Get-Command -Name Set-IntersightServerProfile
    $missingParams = @("Moid","Action") | Where-Object { -not $deployCmd.Parameters.ContainsKey($_) }
    if ($missingParams.Count -gt 0) {
        Stop-WithMessage "Set-IntersightServerProfile in the installed Intersight.PowerShell version does not accept: $($missingParams -join ', '). Run 'Get-Help Set-IntersightServerProfile -Full' and update this script's deploy call before a LIVE RUN."
    }

    # The reboot acknowledgement is the whole point of the run - without it the firmware stages and
    # nothing restarts - so its surface is checked here, before any host is evacuated, rather than
    # discovered on the first deploy with a blade already in Maintenance mode.
    if ($Global:IntersightRebootImmediatelyToActivate) {
        if (-not $deployCmd.Parameters.ContainsKey("ScheduledActions")) {
            Stop-WithMessage "Set-IntersightServerProfile in the installed Intersight.PowerShell version does not accept -ScheduledActions, which is how the reboot acknowledgement is sent. Update the module, or set `$Global:IntersightRebootImmediatelyToActivate to `$false and reboot the blades by hand."
        }
        $scheduledCmd = Get-Command -Name Initialize-IntersightPolicyScheduledAction -ErrorAction SilentlyContinue
        if ($null -eq $scheduledCmd) {
            Stop-WithMessage "Initialize-IntersightPolicyScheduledAction is not available in the installed Intersight.PowerShell version, so the reboot acknowledgement cannot be built. Update the module before a LIVE RUN."
        }
        foreach ($needed in @("Action","ProceedOnReboot")) {
            if (-not $scheduledCmd.Parameters.ContainsKey($needed)) {
                Stop-WithMessage "Initialize-IntersightPolicyScheduledAction does not accept -$needed in this module version. Run 'Get-Help Initialize-IntersightPolicyScheduledAction -Full' and update this script's deploy call before a LIVE RUN."
            }
        }
    }

    if ($Global:IntersightDeployActionParams.Count -gt 0) {
        if ($null -eq (Get-Command -Name Initialize-IntersightPolicyActionParam -ErrorAction SilentlyContinue)) {
            Stop-WithMessage "IntersightDeployActionParams is populated but Initialize-IntersightPolicyActionParam is not available in this module version. Clear the setting or install a module version that provides it."
        }
        if (-not $deployCmd.Parameters.ContainsKey("ActionParams")) {
            Stop-WithMessage "IntersightDeployActionParams is populated but Set-IntersightServerProfile does not accept -ActionParams in this module version. Clear the setting before a LIVE RUN."
        }
    }

    $Global:IntersightUpgradeSurfaceChecked = $true
    Write-Host "Intersight deploy cmdlet surface validated (Set-IntersightServerProfile -Action Deploy)." -ForegroundColor Green
}

function Get-IntersightCredentialIfNeeded {
    if ($Global:IntersightSession) { return }
    if ([string]::IsNullOrWhiteSpace($Global:IntersightApiKeyId)) {
        $Global:IntersightApiKeyId = (Read-Host "Enter Intersight API Key ID").Trim()
    }
    if ([string]::IsNullOrWhiteSpace($Global:IntersightApiKeyFilePath)) {
        Write-Host "Opening a file browser to select the Intersight API private key (.pem)..." -ForegroundColor Cyan
        $picked = Show-OpenFileDialog `
            -Title "Select the Intersight API private key (.pem)" `
            -Filter "Intersight private key (*.pem;*.key;*.txt)|*.pem;*.key;*.txt|All files (*.*)|*.*" `
            -InitialDirectory ([Environment]::GetFolderPath('UserProfile'))

        if (-not [string]::IsNullOrWhiteSpace($picked)) {
            $Global:IntersightApiKeyFilePath = $picked.Trim()
            Write-Host "Selected private key: $Global:IntersightApiKeyFilePath" -ForegroundColor Green
        }
        else {
            # Cancelled, or no GUI available (remote session, headless host).
            Write-Host "No file selected from the browser. Enter the path manually instead." -ForegroundColor Yellow
            $Global:IntersightApiKeyFilePath = (Read-Host "Enter path to the Intersight API private key (.pem) file").Trim().Trim('"')
        }
    }
    if (-not (Test-Path -Path $Global:IntersightApiKeyFilePath)) {
        Stop-WithMessage "Intersight private key file not found at '$Global:IntersightApiKeyFilePath'."
    }

    # Catch the two malformed-credential cases here rather than as an opaque
    # iam_api_key_is_invalid several calls later.
    if (($Global:IntersightApiKeyId -split '/').Count -ne 3) {
        Stop-WithMessage "Intersight API Key ID must be three segments separated by '/' (aaa/bbb/ccc). Got '$Global:IntersightApiKeyId'."
    }
    $firstKeyLine = (Get-Content -Path $Global:IntersightApiKeyFilePath -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($firstKeyLine -notmatch '^-----BEGIN .*PRIVATE KEY-----') {
        Stop-WithMessage "Intersight private key file '$Global:IntersightApiKeyFilePath' does not start with a PEM private key header. Re-download the secret key that was generated with this Key ID."
    }
}

function Connect-IntersightTarget {

    # ---- One configuration call per PowerShell session, full stop -------------------------------
    # Cisco's own getting-started guidance is that Set-IntersightConfiguration is called once per
    # session. It is process-wide state, and a second call after a failure does not reliably reset
    # the client - which is why the same credentials fail repeatedly in a session that has already
    # tried, and succeed immediately in a fresh one.
    #
    # So: succeeded once -> reuse it for the rest of the run, across every cluster.
    #     failed once    -> never call again in this session; a fresh session is the only fix.
    if ($null -ne $Global:IntersightSession) { return $Global:IntersightSession }

    if ($Global:IntersightConfigurationApplied) {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Intersight was already configured in this PowerShell session and the attempt failed." -ForegroundColor Yellow
        Write-Host "Set-IntersightConfiguration is process-wide state that does not reliably reset, so" -ForegroundColor Yellow
        Write-Host "trying again in this session would test a stale client rather than your credentials." -ForegroundColor Yellow
        Write-Host "Close PowerShell, open a fresh session, and run again." -ForegroundColor Yellow
        Add-SummaryRecord -Stage "IntersightLogin" -Batch "" -HostName "" -Action "Authenticate" -Result "Skipped" -Details "Configuration already applied and failed in this session; a fresh session is required."
        $Global:IntersightUnusable = $true
        $Global:IntersightUnusableReason = "Intersight configuration already attempted and failed in this PowerShell session. A fresh session is required."
        return $null
    }

    Assert-IntersightPowerShellAvailable

    # Normally already answered during fabric detection; this covers any path that reaches an
    # Intersight call without having gone through detection.
    [void](Get-IntersightBaseUrlIfNeeded)
    Get-IntersightCredentialIfNeeded

    $basePath = $Global:IntersightBaseUrl.Trim().TrimEnd('/')
    Write-Host "Configuring Intersight connection: $basePath" -ForegroundColor Cyan

    # Intersight.PowerShell has no Connect-* cmdlet - authentication is process-wide configuration
    # applied by Set-IntersightConfiguration, and every subsequent Get-Intersight*/Set-Intersight*
    # call signs against it.
    #
    # The four signing headers must be exactly these, in this order and capitalisation; anything
    # else produces "cannot sign http request, request does not contain date header".
    $signingHeaders = @("(request-target)", "Host", "Date", "Digest")

    # ONE Set-IntersightConfiguration call per session, and nothing in the splat that is not
    # required.
    #
    # Set-IntersightConfiguration is process-wide state, and calling it repeatedly in a session
    # after a failure does not reliably reset the module - which is why the same credentials fail
    # in a session that has already attempted a connection, and succeed immediately in a fresh
    # one. The previous key-file-then-key-string fallback issued a second call and made that worse.
    # The failure path below therefore asks for a fresh session rather than retrying in place.
    #
    # The splat below matches the minimal call proven to work against this appliance. Anything
    # optional is omitted unless explicitly switched on in User Settings: HashAlgorithm is left to
    # the module default, and SkipCertificateCheck is off, since it changes the HTTP handler and is
    # a credible cause of corrupted response bodies.
    $lastError = $null
    $singleAttempt = @('KeyFile')
    foreach ($method in $singleAttempt) {
        try {
            $configParams = @{
                BasePath          = $basePath
                ApiKeyId          = $Global:IntersightApiKeyId
                ApiKeyFilePath    = $Global:IntersightApiKeyFilePath
                HttpSigningHeader = $signingHeaders
                ErrorAction       = "Stop"
            }
            if (-not [string]::IsNullOrWhiteSpace($Global:IntersightHashAlgorithm)) { $configParams["HashAlgorithm"] = $Global:IntersightHashAlgorithm }
            if (-not [string]::IsNullOrWhiteSpace($Global:IntersightApiKeyPassPhrase)) { $configParams["ApiKeyPassPhrase"] = $Global:IntersightApiKeyPassPhrase }
            if ($Global:IntersightSkipCertificateCheck) { $configParams["SkipCertificateCheck"] = $true }

            # Set before the call, not after: once it has been issued the session is committed,
            # whether it succeeds or throws.
            $Global:IntersightConfigurationApplied = $true

            Write-Host "  Set-IntersightConfiguration -BasePath $basePath -ApiKeyId <id> -ApiKeyFilePath <pem> -HttpSigningHeader (4 headers)$(if($Global:IntersightHashAlgorithm){" -HashAlgorithm $Global:IntersightHashAlgorithm"})$(if($Global:IntersightSkipCertificateCheck){' -SkipCertificateCheck'})" -ForegroundColor DarkGray

            # Before the call that first crosses the network. Against a blocked appliance the
            # Intersight client sits on its own timeout and then reports a signing/credential
            # error, which sends the operator to the wrong team.
            [void](Confirm-ManagementEndpointReachable -Target $basePath -DeviceKind "Intersight" -TimeoutSeconds $ManagementEndpointProbeTimeoutSeconds)

            Set-IntersightConfiguration @configParams | Out-Null

            # Prove the configuration took and that the key actually authenticates, before any
            # host is routed down the Intersight path.
            $activeConfig = Get-IntersightConfiguration -ErrorAction Stop
            if ($null -eq $activeConfig -or [string]::IsNullOrWhiteSpace([string]$activeConfig.BasePath)) {
                throw "Set-IntersightConfiguration did not take effect - Get-IntersightConfiguration returned no BasePath."
            }

            [void](Get-IntersightServerProfile -Top 1 -Skip 0 -ErrorAction Stop)

            $Global:IntersightSession = $activeConfig
            Write-Host "Intersight authenticated against $basePath." -ForegroundColor Green
            Add-SummaryRecord -Stage "IntersightLogin" -Batch "" -HostName "" -Action "Authenticate" -Result "Connected" -Details "BasePath=$basePath; Method=$method."
            return $Global:IntersightSession
        }
        catch {
            $lastError = $_
        }
    }

    # Distinguish a rejected key from a key that was accepted but whose response the module could
    # not parse - the module reports both identically, and only one of them is about credentials.
    $failureKind = Get-IntersightFailureKind -ErrorRecord $lastError
    if ($failureKind.Kind -eq 'Deserialization') {
        $installedVersions = (@(Get-AvailableModuleVersion -Name Intersight.PowerShell | Select-Object -ExpandProperty Version -Unique | ForEach-Object { $_.ToString() }) -join ', ')
        Add-SummaryRecord -Stage "IntersightLogin" -Batch "" -HostName "" -Action "Authenticate" -Result "ResponseUnreadable" -Details "Signed request accepted; response could not be deserialized. Installed: $installedVersions."
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Intersight AUTHENTICATION SUCCEEDED - the appliance accepted the signed request and" -ForegroundColor Green
        Write-Host "returned data. The API Key ID and .pem are correct; do NOT regenerate them." -ForegroundColor Green
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Intersight.PowerShell could not deserialize the reply. Try these in order:" -ForegroundColor Yellow
        Write-Host "  1. START A FRESH POWERSHELL SESSION and run again. Set-IntersightConfiguration is" -ForegroundColor Yellow
        Write-Host "     process-wide state that does not reliably reset after a failed attempt, so the" -ForegroundColor Yellow
        Write-Host "     same credentials often work first time in a clean session and never in this one." -ForegroundColor Yellow
        Write-Host "  2. Leave `$Global:IntersightSkipCertificateCheck = `$false (the default). It swaps" -ForegroundColor Yellow
        Write-Host "     the module's HTTP handler and can corrupt response bodies." -ForegroundColor Yellow
        Write-Host "  3. Only then consider the module version. Installed: $installedVersions" -ForegroundColor Yellow
        Write-Host "     Install-Module Intersight.PowerShell -RequiredVersion 1.0.11.17 -Scope CurrentUser -Force" -ForegroundColor Yellow
        Write-Host "Verify in isolation with scripts/intersight/Test-IntersightApiKey.ps1 from a fresh session." -ForegroundColor Yellow

        # No code change here can make the module parse the response, so the run cannot drive
        # Intersight. It can still drive the UCS Manager-managed hosts, which are usually the
        # majority - the caller decides whether losing the change window is worse than deferring
        # the Intersight subset.
        $Global:IntersightUnusable = $true
        $Global:IntersightUnusableReason = "Intersight.PowerShell $installedVersions cannot deserialize responses from $basePath. Credentials are valid."
        return $null
    }

    Add-SummaryRecord -Stage "IntersightLogin" -Batch "" -HostName "" -Action "Authenticate" -Result "Failed" -Details $lastError.Exception.Message
    Write-Host "`nIntersight login failed against '$basePath'." -ForegroundColor Red
    Write-IntersightLoginDiagnostics -BasePath $basePath -ErrorRecord $lastError

    # No in-session retry. Re-issuing Set-IntersightConfiguration after a failure tests a stale
    # client, not the credentials, and was itself a source of "mismatch" confusion.
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Not retrying in this session. Set-IntersightConfiguration is process-wide state and" -ForegroundColor Yellow
    Write-Host "has already been applied here, so a second attempt would test a stale client rather" -ForegroundColor Yellow
    Write-Host "than your credentials. Correct whatever the diagnostics above point at, then close" -ForegroundColor Yellow
    Write-Host "PowerShell and run again from a fresh session." -ForegroundColor Yellow

    $Global:IntersightUnusable = $true
    $Global:IntersightUnusableReason = "Intersight login failed against $basePath. A fresh PowerShell session is required before another attempt."
    return $null
}

function Get-IntersightMatchKeyList {
    <#
    .SYNOPSIS
        Expands a fabric/system name into every equivalent form used for CSV matching.

    .DESCRIPTION
        The Intersight Fabrics export and the ESXi CDP/LLDP system name do not agree on
        shape. Either side may carry a fabric suffix or not, and either side may be an
        FQDN or a short name. A row named "PD24000001SS101-A" and a CDP name of
        "PD24000001SS101-B.dpe.protected.mil.au" describe the same UCS domain, and both
        must match.

        The previous implementation collapsed each name to a single suffix-stripped key,
        so it only matched when both sides happened to share the same FQDN/short shape.
        This returns the full equivalence set instead, most specific first:

            PD24000001SS101-A.dpe.protected.mil.au   (as supplied, FQDN)
            PD24000001SS101-A                        (as supplied, short)
            PD24000001SS101.dpe.protected.mil.au     (fabric suffix removed, FQDN)
            PD24000001SS101                          (fabric suffix removed, short)
            PD24000001SS101-A.dpe.protected.mil.au   (fabric A, FQDN)
            PD24000001SS101-A                        (fabric A, short)
            PD24000001SS101-B.dpe.protected.mil.au   (fabric B, FQDN)
            PD24000001SS101-B                        (fabric B, short)

        Indexing every CSV row under all of these, and testing a CDP name against all of
        these, means the two sides match whichever form each one happens to use.

    .PARAMETER Value
        A fabric interconnect name, CDP/LLDP system name, or CSV Name value.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Value)

    $clean = (Remove-UcsTargetDecoration -Value $Value).Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($clean)) { return @() }

    # Split off the DNS domain so the fabric suffix is handled identically for short
    # names and FQDNs. $domainPart keeps its leading dot, or is empty for a short name.
    $firstLabel = $clean
    $domainPart = ""
    $dotIndex = $clean.IndexOf('.')
    if ($dotIndex -gt 0) {
        $firstLabel = $clean.Substring(0, $dotIndex)
        $domainPart = $clean.Substring($dotIndex)
    }

    # Remove a trailing -A/-B fabric suffix from the first label only, so a domain
    # component that happens to end in -a or -b is never touched.
    $core = $firstLabel
    if ($firstLabel -match '^(.*[^-])-[AaBb]$') { $core = $Matches[1] }

    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($label in @($firstLabel, $core, "$core-A", "$core-B")) {
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($domainPart)) { [void]$keys.Add("$label$domainPart") }
        [void]$keys.Add($label)
    }

    # Select-Object -Unique is case-insensitive and keeps first occurrence, which
    # preserves the most-specific-first ordering above.
    return @($keys | Select-Object -Unique)
}

function Import-IntersightServerCsv {
    if ($Global:IntersightServerList.Count -gt 0) { return }
    if ([string]::IsNullOrWhiteSpace($IntersightCsvPath)) { return }
    if (-not (Test-Path -Path $IntersightCsvPath)) { Stop-WithMessage "Intersight server CSV not found at '$IntersightCsvPath'." }

    Write-Host "Loading Intersight server list from: $IntersightCsvPath" -ForegroundColor Cyan
    $rows = @(Import-Csv -Path $IntersightCsvPath)
    Write-Host "Raw CSV rows read from file: $($rows.Count)" -ForegroundColor Cyan

    $skippedBlankName = 0
    $loadedRows = 0

    # Each row is indexed under every equivalent form of its Name, so a -A row, a -B row
    # and a suffix-less row all resolve for any host in that domain. One key can therefore
    # legitimately hold several rows (the A and B sides of the same fabric pair) - that is
    # expected and is not reported as a duplicate. Only rows that disagree about which
    # server profile to act on are a real ambiguity, and those are reported below.
    foreach ($row in $rows) {
        if (-not ($row.PSObject.Properties.Name -contains "Name") -or [string]::IsNullOrWhiteSpace($row.Name)) { $skippedBlankName++; continue }
        $keys = @(Get-IntersightMatchKeyList -Value $row.Name)
        if ($keys.Count -eq 0) { $skippedBlankName++; continue }

        $loadedRows++
        foreach ($key in $keys) {
            if (-not $Global:IntersightServerList.ContainsKey($key)) {
                $Global:IntersightServerList[$key] = New-Object System.Collections.Generic.List[object]
            }
            [void]$Global:IntersightServerList[$key].Add($row)
        }
    }

    Write-Host "Intersight server list loaded: $loadedRows row(s) indexed under $($Global:IntersightServerList.Count) match key(s), from $($rows.Count) raw CSV row(s)." -ForegroundColor Green
    if ($skippedBlankName -gt 0) {
        Write-Host "WARNING: $skippedBlankName row(s) were skipped because the Name column was blank or normalised to an empty value." -ForegroundColor Yellow
    }

    $ambiguousKeys = @(
        $Global:IntersightServerList.Keys | Where-Object {
            $identities = @(
                $Global:IntersightServerList[$_] |
                    ForEach-Object { "$(Get-IntersightCsvRowIdentity -CsvRow $_)" } |
                    Select-Object -Unique
            )
            $identities.Count -gt 1
        }
    )
    if ($ambiguousKeys.Count -gt 0) {
        Write-Host "WARNING: $($ambiguousKeys.Count) match key(s) resolve to CSV rows that name different server profiles. The first matching row wins - confirm these are correct before a LIVE RUN:" -ForegroundColor Yellow
        foreach ($key in $ambiguousKeys) {
            $names = @($Global:IntersightServerList[$key] | ForEach-Object { Get-IntersightCsvRowIdentity -CsvRow $_ }) -join ' | '
            Write-Host " - $key => $names" -ForegroundColor Yellow
        }
    }

    Add-SummaryRecord -Stage "IntersightCsvImport" -Batch "" -HostName "" -Action "Import CSV" -Result "Completed" -Details "RawRows=$($rows.Count); IndexedRows=$loadedRows; MatchKeys=$($Global:IntersightServerList.Count); SkippedBlank=$skippedBlankName; AmbiguousKeys=$($ambiguousKeys.Count)."
}

function Get-IntersightCsvRowIdentity {
    # Which server profile a row points at. Rows that agree on this are interchangeable
    # for routing purposes even when their Name values differ by fabric suffix.
    param([Parameter(Mandatory=$true)]$CsvRow)
    foreach ($prop in @("Moid","ServerProfileName")) {
        if ($CsvRow.PSObject.Properties.Name -contains $prop -and -not [string]::IsNullOrWhiteSpace($CsvRow.$prop)) {
            return [string]$CsvRow.$prop
        }
    }
    return ""
}

function Initialize-IntersightRoutedHosts {
    <#
    .SYNOPSIS
        Proves Intersight authentication and server profile resolution before any host is touched.

    .DESCRIPTION
        Runs during infrastructure detection, alongside the UCS Manager login that already happens
        there. Authenticates once, resolves the server profile for every Intersight-routed host,
        and prints the mapping.

        This is deliberately eager. Resolving lazily at the accept/reboot step put the first
        credential prompt after the batch had entered Maintenance mode and passed the pre-reboot
        safety window - so a wrong key or unreachable appliance left hosts stranded in Maintenance
        mode rather than failing before any disruption.
    #>
    if ($Global:IntersightHostMap.Count -eq 0) { return }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Validating Intersight access for $($Global:IntersightHostMap.Count) detected host(s) before any host is touched..." -ForegroundColor Cyan

    $session = Connect-IntersightTarget

    if ($null -eq $session -and $Global:IntersightUnusable) {
        # Authentication is fine but the module cannot read the appliance. Nothing in this script
        # can fix that, and it is caught here - before any host has been touched - so the UCS
        # Manager side of the cluster can still proceed if the operator wants it to.
        $affected = @($Global:IntersightHostMap.Keys | Sort-Object)
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Intersight cannot be driven in this session: $Global:IntersightUnusableReason" -ForegroundColor Yellow
        Write-Host "Affected host(s), all Intersight-managed: $($affected -join ', ')" -ForegroundColor Yellow
        Write-Host "Nothing has been touched yet. You can either stop and fix the module version, or" -ForegroundColor Yellow
        Write-Host "exclude these hosts and continue with the UCS Manager-managed hosts only." -ForegroundColor Yellow

        $choice = Read-ChoiceExit `
            -Message "S to skip the Intersight-managed hosts and continue with the rest, X to stop, E to exit" `
            -AllowedChoices @("S","X") `
            -ExitMessage "Stopped because Intersight is unusable in this session."

        if ($choice -eq "X") {
            Stop-WithMessage "Intersight module cannot parse responses. Credentials are valid - align the Intersight.PowerShell version with the appliance before re-running."
        }

        foreach ($hostName in $affected) {
            $Global:IntersightSkippedHosts[$hostName] = $Global:IntersightUnusableReason
            Add-ManualAttentionHost -HostName $hostName -Reason "Intersight unusable in this session" -Detail $Global:IntersightUnusableReason
            Add-SummaryRecord -Stage "IntersightMapping" -Batch "" -HostName $hostName -Action "Exclude from run" -Result "Skipped" -Details $Global:IntersightUnusableReason
        }
        $Global:IntersightHostMap = @{}
        Write-Host "Excluded $($affected.Count) Intersight-managed host(s). They will not be batched, entered into Maintenance mode, or rebooted." -ForegroundColor Yellow
        return
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($hostName in @($Global:IntersightHostMap.Keys)) {
        $map = $Global:IntersightHostMap[$hostName]
        $sp = Resolve-IntersightServerProfileForHost -HostName $hostName -IntersightCsvRow $map.IntersightCsvRow
        [void]$rows.Add([pscustomobject]@{
            Host          = $hostName
            ServerProfile = $sp.Name
            ProfileMoid   = $sp.Moid
            ConfigState   = (Get-IntersightProfileComplianceStateSafe -ServerProfile $sp)
        })
    }

    Write-Host "Intersight server profile mapping:" -ForegroundColor Cyan
    $rows | Format-Table -AutoSize | Out-Host
    Add-SummaryRecord -Stage "IntersightMapping" -Batch "" -HostName "" -Action "Resolve server profiles" -Result "Completed" -Details "$($rows.Count) host(s) resolved and Intersight authenticated before any batch work."
}

function Get-IntersightProfileComplianceStateSafe {
    param([Parameter(Mandatory=$true)]$ServerProfile)
    try { return (Get-IntersightProfileDeployState -ServerProfile $ServerProfile).ConfigState } catch { return "UNKNOWN" }
}

function Resolve-IntersightCsvMatch {
    <#
    .SYNOPSIS
        Finds the Intersight CSV row for a CDP/LLDP system name, trying every name form.

    .DESCRIPTION
        Returns $null when the host is not Intersight-managed. On a match, returns the
        winning CSV row plus the key that matched, so the detection table can show which
        form of the name was responsible.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$CdpSystemName)

    if ($Global:IntersightServerList.Count -eq 0) { return $null }
    if ([string]::IsNullOrWhiteSpace($CdpSystemName)) { return $null }

    foreach ($key in (Get-IntersightMatchKeyList -Value $CdpSystemName)) {
        if ($Global:IntersightServerList.ContainsKey($key)) {
            $candidates = @($Global:IntersightServerList[$key])
            return [pscustomobject]@{
                Row        = $candidates[0]
                MatchedKey = $key
                Candidates = $candidates
            }
        }
    }
    return $null
}

function Get-IntersightResultList {
    <#
    .SYNOPSIS
        Unwraps an Intersight paged response into a plain array of managed objects.

    .DESCRIPTION
        Get-Intersight* returns a page object carrying a Results collection, not the objects
        themselves. Piping the page straight into Select-Object -First 1 yields the page,
        whose Moid is $null - which then silently targets nothing downstream. Everything
        that consumes a query result goes through here.
    #>
    param($Response)
    if ($null -eq $Response) { return @() }
    if ($Response.PSObject.Properties.Name -contains "Results") { return @($Response.Results | Where-Object { $null -ne $_ }) }
    return @($Response)
}

function Get-IntersightServerProfileByName {
    <#
    .SYNOPSIS
        Finds a server profile by name, and does not silently guess when the name is not unique.

    .DESCRIPTION
        A profile name is NOT unique in Intersight. The same name can exist in more than one
        organization, and a decommissioned or template-derived copy commonly sits alongside the
        live one. This used to take Select-Object -First 1 of whatever the appliance returned.

        That is how a run ends up deploying against the wrong object. The live symptom was
        deceptive: the appliance answered

            "Cannot deploy the server profile. The server is disconnected."
            messageId: gershwin_server_is_not_connected

        while BOTH Intersight and vCenter showed the server perfectly healthy - because the healthy
        server belonged to the OTHER profile of the same name. The one the script picked had no
        server on it at all, and "no server" and "server disconnected" are the same refusal from
        the appliance's point of view.

        So when several profiles share a name, the one ASSOCIATED WITH A SERVER wins - that is the
        one an operator means. If exactly one qualifies it is used and the choice is announced. If
        several do, or none do, nothing is guessed: the caller is told, with the Moids, so the
        ambiguity can be resolved by putting a Moid in the CSV.
    #>
    param([Parameter(Mandatory=$true)][string]$Name)

    # OData string literals escape a single quote by doubling it.
    $escaped = $Name -replace "'", "''"
    $page = Get-IntersightServerProfile -Filter "Name eq '$escaped'" -ErrorAction Stop
    $profileMatches = @(Get-IntersightResultList -Response $page)

    if ($profileMatches.Count -eq 0) { return $null }
    if ($profileMatches.Count -eq 1) { return $profileMatches[0] }

    Write-Host "  Intersight returned $($profileMatches.Count) server profiles named '$Name'. A profile name is not unique across organizations." -ForegroundColor Yellow

    $assigned = @($profileMatches | Where-Object {
        -not [string]::IsNullOrWhiteSpace((Get-IntersightAssignedServerMoid -ServerProfile $_ -Quiet))
    })

    foreach ($candidate in $profileMatches) {
        $serverMoid = Get-IntersightAssignedServerMoid -ServerProfile $candidate -Quiet
        $has = if ([string]::IsNullOrWhiteSpace($serverMoid)) { "no server assigned" } else { "server $serverMoid" }
        Write-Host "    Moid $($candidate.Moid) - $has." -ForegroundColor Yellow
    }

    if ($assigned.Count -eq 1) {
        Write-Host "  Using Moid $($assigned[0].Moid) - the only one of them with a server assigned." -ForegroundColor Green
        return $assigned[0]
    }

    # Several assigned, or none. Either way this script must not pick one.
    $detail = if ($assigned.Count -eq 0) { "none of them has a server assigned" } else { "$($assigned.Count) of them have a server assigned" }
    Write-Host "  Cannot tell which profile named '$Name' is the right one - $detail." -ForegroundColor Red
    Write-Host "  Put the correct Moid in the Moid column of $IntersightCsvPath for this host." -ForegroundColor Red
    return $null
}

function Resolve-IntersightServerProfileForHost {
    param([Parameter(Mandatory=$true)][string]$HostName,[Parameter(Mandatory=$true)]$IntersightCsvRow)

    Connect-IntersightTarget | Out-Null
    $short = Get-ShortHostName -HostName $HostName

    # Only the resolved Moid is cached, never the profile object. ConfigState is read again on
    # every call, because the accept/reboot decision must act on live state rather than on
    # whatever the profile looked like during the discovery pass.
    if ($Global:IntersightProfileCache.ContainsKey($HostName)) {
        $cachedMoid = $Global:IntersightProfileCache[$HostName]
        try {
            $fresh = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $cachedMoid -ErrorAction Stop) | Select-Object -First 1
            if ($null -ne $fresh) { return $fresh }
        } catch {
            Write-Host "Could not refresh cached Intersight profile for '$HostName' (Moid $cachedMoid): $($_.Exception.Message). Re-resolving." -ForegroundColor Yellow
        }
        [void]$Global:IntersightProfileCache.Remove($HostName)
    }

    $sp = $null
    $resolvedBy = ""

    try {
        if ($IntersightCsvRow.PSObject.Properties.Name -contains "Moid" -and -not [string]::IsNullOrWhiteSpace($IntersightCsvRow.Moid)) {
            $sp = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $IntersightCsvRow.Moid -ErrorAction Stop) | Select-Object -First 1
            if ($null -ne $sp) { $resolvedBy = "CSV Moid '$($IntersightCsvRow.Moid)'" }
        }

        if ($null -eq $sp) {
            # Ordered candidates. An explicit ServerProfileName always wins. Otherwise the ESXi
            # short hostname is tried before the CSV Name, because in a Fabrics export the Name
            # column holds the fabric interconnect name, which is never a server profile name.
            # Falling back to Name still covers a CSV that is genuinely a per-server list.
            $candidates = New-Object System.Collections.Generic.List[object]
            foreach ($candidate in @(
                @{ Value = $IntersightCsvRow.ServerProfileName; Source = "CSV ServerProfileName" },
                @{ Value = $short;                              Source = "ESXi short hostname" },
                @{ Value = $IntersightCsvRow.Name;              Source = "CSV Name" }
            )) {
                $value = [string]$candidate.Value
                if ([string]::IsNullOrWhiteSpace($value)) { continue }
                if ($candidates.Value -contains $value) { continue }
                [void]$candidates.Add([pscustomobject]@{ Value = $value; Source = $candidate.Source })
            }

            foreach ($candidate in $candidates) {
                $sp = Get-IntersightServerProfileByName -Name $candidate.Value
                if ($null -ne $sp) { $resolvedBy = "$($candidate.Source) '$($candidate.Value)'"; break }
            }
        }
    } catch {
        Stop-WithMessage "Intersight server profile lookup failed for host '$HostName': $($_.Exception.Message)"
    }

    if ($null -eq $sp) {
        Stop-WithMessage "No Intersight server profile found for host '$HostName'. Tried: CSV Moid, CSV ServerProfileName, short hostname '$short', CSV Name '$($IntersightCsvRow.Name)'. Add a ServerProfileName or Moid column to $IntersightCsvPath for this row."
    }

    # The Moid, not just the name. A name is not unique in Intersight, so without the Moid a run
    # that resolved to the WRONG profile of the right name looks identical to one that got it right.
    Write-Host "Host '$HostName' resolved to Intersight server profile '$($sp.Name)' (Moid $($sp.Moid)) via $resolvedBy." -ForegroundColor Cyan
    $Global:IntersightProfileCache[$HostName] = $sp.Moid
    return $sp
}

function Get-IntersightProfileDeployState {
    <#
    .SYNOPSIS
        Reads a server profile's ConfigState and decides whether it has changes to deploy.

    .DESCRIPTION
        A firmware policy change does NOT usually leave the profile "Inconsistent". In practice it
        lands in "Pending-changes" - the policy has been edited but not pushed to the server. An
        earlier version of this script matched only "Inconsistent", so a profile sitting in
        Pending-changes was reported as nothing to do, no deploy was sent, and the run then waited
        out the full post-reboot window for a reboot that was never triggered.

        Every state that means "there is something staged that has not reached the server" is now
        actionable - see $Global:IntersightActionableConfigStates. Matching is case-insensitive
        and tolerates the hyphenated and unhyphenated spellings the API has used.
    #>
    param([Parameter(Mandatory=$true)]$ServerProfile)

    $configState = $null
    if ($ServerProfile.PSObject.Properties.Name -contains "ConfigContext" -and $null -ne $ServerProfile.ConfigContext) {
        $configState = $ServerProfile.ConfigContext.ConfigState
    }

    # An absent or blank ConfigState is not the same as "nothing to do". Treating the two alike
    # silently skips a host that may still need the firmware change, so the caller is given
    # enough to tell them apart and stop.
    $stateKnown = -not [string]::IsNullOrWhiteSpace([string]$configState)

    $normalised = ([string]$configState) -replace '[\s_-]', ''
    $requiresDeploy = $false
    foreach ($actionable in $Global:IntersightActionableConfigStates) {
        if ($normalised -eq (($actionable -replace '[\s_-]', ''))) { $requiresDeploy = $true; break }
    }

    return [pscustomobject]@{
        ConfigState    = if ($stateKnown) { [string]$configState } else { "UNKNOWN" }
        StateKnown     = $stateKnown
        RequiresDeploy = $requiresDeploy
    }
}

function Get-IntersightPendingInconsistencyForBatch {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames)
    $rows = New-Object System.Collections.ArrayList
    foreach ($hostName in $HostNames) {
        $map = $Global:IntersightHostMap[$hostName]
        $sp = Resolve-IntersightServerProfileForHost -HostName $hostName -IntersightCsvRow $map.IntersightCsvRow
        $state = Get-IntersightProfileDeployState -ServerProfile $sp
        [void]$rows.Add([pscustomobject]@{
            Host            = $hostName
            ServerProfile   = $sp.Name
            ProfileMoid     = $sp.Moid
            ConfigState     = $state.ConfigState
            StateKnown      = $state.StateKnown
            RequiresDeploy  = $state.RequiresDeploy
            ServerProfileObj = $sp
        })
    }
    return @($rows)
}

function Confirm-IntersightDeployAcceptedForBatch {
    <#
    .SYNOPSIS
        Re-reads EVERY profile in the batch after their deploys, in one shared window.

    .DESCRIPTION
        The reboot acknowledgement is sent as a PolicyActionParam whose identifier Cisco does not
        publish. A wrong identifier has two possible outcomes and only one of them is loud: the
        appliance either rejects the call - which throws, and the caller stops - or it ignores the
        parameter, accepts the Deploy, and leaves the firmware staged with nothing rebooting. The
        second is the dangerous one, so a deploy is never trusted on the strength of the call
        returning: each profile is re-read until it leaves the state it was staged in.

        ONE WINDOW FOR THE WHOLE BATCH. Doing this per host inside the deploy loop meant host 2's
        deploy was not even SENT until host 1's confirmation window had closed - up to
        $Global:IntersightDeployAcceptedTimeoutSeconds each, so six hosts serialised into six
        windows before the last blade had been touched. Every deploy now goes out first and they
        are confirmed together, so the batch costs one window regardless of its size.

        Returns a hashtable keyed by host name: $true where the appliance visibly picked the change
        up, $false where it is still sitting in the staged state when the window closes. $false is
        not a failure - it means the firmware is staged and waiting for a restart, which is what
        the activation then supplies.

        Deliberately a SHORT window. It checks that the deploy was ACCEPTED, not that the upgrade
        finished; the rolling return check covers the upgrade.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Rows,
        [Parameter(Mandatory=$true)][string]$BatchNumber
    )

    $result = @{}
    foreach ($row in $Rows) { $result[$row.Host] = $false }
    if ($Rows.Count -eq 0) { return $result }

    $timeoutSeconds = [int]$Global:IntersightDeployAcceptedTimeoutSeconds
    if ($timeoutSeconds -le 0) {
        foreach ($row in $Rows) { $result[$row.Host] = $true }
        return $result
    }

    Write-Host "  Confirming the appliance accepted $($Rows.Count) deploy(s), up to $timeoutSeconds second(s) for the batch..." -ForegroundColor Gray

    $endTime = (Get-Date).AddSeconds($timeoutSeconds)
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Rows) { [void]$pending.Add($row) }
    $lastState = @{}
    foreach ($row in $Rows) { $lastState[$row.Host] = $row.ConfigState }

    while ((Get-Date) -lt $endTime -and $pending.Count -gt 0) {
        Start-Sleep -Seconds 15

        foreach ($row in $pending.ToArray()) {
            # By Moid where there is one - it identifies the profile exactly - falling back to the
            # name so a profile the mapping resolved without a Moid is still re-read rather than
            # skipped.
            $current = $null
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$row.ProfileMoid)) {
                    $current = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $row.ProfileMoid -ErrorAction Stop) | Select-Object -First 1
                }
                else {
                    $current = Get-IntersightServerProfileByName -Name $row.ServerProfile
                }
            }
            catch { }
            if ($null -eq $current) { continue }

            $state = Get-IntersightProfileDeployState -ServerProfile $current
            if (-not $state.StateKnown) { continue }
            $lastState[$row.Host] = $state.ConfigState

            if (-not $state.RequiresDeploy) {
                Write-Host "    Accepted - '$($row.ServerProfile)' is now $($state.ConfigState)." -ForegroundColor Green
                Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Confirm deploy accepted" -Result "Accepted" -Details "ConfigState moved from $($row.ConfigState) to $($state.ConfigState)."
                $result[$row.Host] = $true
                [void]$pending.Remove($row)
            }
        }
    }

    foreach ($row in $pending.ToArray()) {
        Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Confirm deploy accepted" -Result "AwaitingReboot" -Details "Still $($lastState[$row.Host]) after $timeoutSeconds second(s); the firmware is staged and waiting for a restart."
        Write-Host "    '$($row.ServerProfile)' is still $($lastState[$row.Host]). The firmware is staged and waiting for a reboot." -ForegroundColor Yellow
    }

    return $result
}

function Get-IntersightRelationshipMoid {
    <#
    .SYNOPSIS
        Pulls the Moid out of an Intersight relationship property, whatever shape it arrived in.

    .DESCRIPTION
        Relationship properties in this SDK are not plain objects. They are generated oneOf
        wrappers, so the Moid can be on the object itself, on an ActualInstance the wrapper holds,
        or in the AdditionalProperties bag when the model did not recognise the concrete type. On a
        live run AssignedServer.Moid read as empty on every profile, which is what stopped any
        power action being sent - the same class of problem as a paged response whose Moid is null
        because the page, not the object, was being read.

        All the shapes are tried, plus the case where the relationship serialises to nothing but
        the Moid string itself. Returns "" rather than guessing.
    #>
    param($Relationship)

    if ($null -eq $Relationship) { return "" }

    # A bare Moid string.
    if ($Relationship -is [string]) {
        if ($Relationship -match '^[0-9a-fA-F]{24}$') { return $Relationship }
        return ""
    }

    foreach ($candidate in @(
        { [string]$Relationship.Moid }
        { [string]$Relationship.ActualInstance.Moid }
        { [string]$Relationship.ActualInstance.ActualInstance.Moid }
        { [string]$Relationship.AdditionalProperties['Moid'] }
        { [string]$Relationship.AdditionalProperties.Moid }
    )) {
        $value = ""
        try { $value = & $candidate } catch { continue }
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }

    return ""
}

function Write-IntersightRelationshipShape {
    <#
    .SYNOPSIS
        Describes a relationship object that yielded no Moid, so the next run says what to read.

    .DESCRIPTION
        Purely diagnostic. Two live runs have now been lost to a property that was present and
        unreadable, and "could not be identified" on its own does not tell anyone which property to
        reach for. This prints the type and the property names actually on the object.
    #>
    param([string]$Label, $Relationship)

    if ($null -eq $Relationship) { Write-Host "    $Label : null" -ForegroundColor DarkGray; return }
    try {
        $typeName = $Relationship.GetType().FullName
        $names = @($Relationship.PSObject.Properties.Name) -join ', '
        Write-Host "    $Label : type $typeName" -ForegroundColor DarkGray
        Write-Host "      properties: $names" -ForegroundColor DarkGray
        if ($Relationship.PSObject.Properties.Name -contains 'ActualInstance' -and $null -ne $Relationship.ActualInstance) {
            Write-Host "      ActualInstance type: $($Relationship.ActualInstance.GetType().FullName)" -ForegroundColor DarkGray
            Write-Host "      ActualInstance properties: $((@($Relationship.ActualInstance.PSObject.Properties.Name)) -join ', ')" -ForegroundColor DarkGray
        }
    }
    catch { Write-Host "    $Label : could not be described - $($_.Exception.Message)" -ForegroundColor DarkGray }
}

function Get-IntersightAssignedServerMoid {
    <#
    .SYNOPSIS
        Returns the Moid of the server a profile is assigned to, or "" if it cannot be read.

    .DESCRIPTION
        Reads AssignedServer, then AssociatedServer - which of the two carries the relationship
        differs by how the profile was created and by appliance release - and gets the Moid out of
        each through Get-IntersightRelationshipMoid, because the relationship is a typed wrapper
        rather than a plain object.

        If neither yields anything, the profile is re-read with the relationships expanded. An
        unexpanded relationship can serialise with nothing useful on it at all, and $expand is
        exactly what the Intersight GUI does on this page for this reason.

        Never throws. This runs after the firmware is already staged, and a lookup that fails is a
        reason to say so and leave the blade alone, not a reason to end the run.
    #>
    param(
        [Parameter(Mandatory=$true)]$ServerProfile,
        [string]$ProfileMoid = "",
        [switch]$Quiet
    )

    foreach ($property in @('AssignedServer','AssociatedServer')) {
        try {
            if ($ServerProfile.PSObject.Properties.Name -notcontains $property) { continue }
            $moid = Get-IntersightRelationshipMoid -Relationship $ServerProfile.$property
            if (-not [string]::IsNullOrWhiteSpace($moid)) { return $moid }
        }
        catch {}
    }

    # Second attempt: ask the appliance to expand the relationships. Only worth doing once, and
    # only when there is a Moid to ask about.
    if (-not [string]::IsNullOrWhiteSpace($ProfileMoid)) {
        foreach ($expandValue in @('AssignedServer', 'AssociatedServer')) {
            try {
                $expanded = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $ProfileMoid -Expand $expandValue -ErrorAction Stop) | Select-Object -First 1
                if ($null -eq $expanded) { continue }
                foreach ($property in @('AssignedServer','AssociatedServer')) {
                    if ($expanded.PSObject.Properties.Name -notcontains $property) { continue }
                    $moid = Get-IntersightRelationshipMoid -Relationship $expanded.$property
                    if (-not [string]::IsNullOrWhiteSpace($moid)) { return $moid }
                }
            }
            catch {}
        }
    }

    if (-not $Quiet) {
        Write-Host "  No server Moid could be read from the profile. What the relationships look like:" -ForegroundColor DarkGray
        foreach ($property in @('AssignedServer','AssociatedServer')) {
            $value = $null
            try { if ($ServerProfile.PSObject.Properties.Name -contains $property) { $value = $ServerProfile.$property } } catch {}
            Write-IntersightRelationshipShape -Label $property -Relationship $value
        }
    }

    return ""
}

function Invoke-IntersightServerPowerAction {
    <#
    .SYNOPSIS
        Issues a power action against a server through Intersight. Returns Sent/UpgradeInProgress/Failed.

    .DESCRIPTION
        The action goes to compute.ServerSetting, whose AdminPowerState the SDK documents as:

            Policy      - the default from the power policy
            PowerOn     - power the server on
            PowerOff    - power the server off
            PowerCycle  - reset the server          <-- what activates staged firmware
            HardReset   - hard reset the server
            Shutdown    - shut the operating system down
            Reboot      - reboot the IMC, NOT the server

        Reboot is the trap in that list. It restarts the management controller and leaves the server
        running, so it would look like an action was taken while the firmware stayed staged.

        The ServerSetting object is found by filtering on the server's Moid. Some releases give it
        the same Moid as the server, so that is tried as a fallback rather than giving up.

        Returns "Sent", "UpgradeInProgress", or "Failed". The middle one matters: the appliance
        refuses a power action while a firmware upgrade is running
        (action_not_allowed_firmware_upgrade_in_progress), and that is not a failure - it is the
        upgrade this deploy started, still going. The caller stands off and asks again.

        NOTHING HERE THROWS. By this point the firmware is already staged, so ending the run would
        leave the operator worse off than telling them plainly.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ServerMoid,
        [Parameter(Mandatory=$true)][string]$PowerState
    )

    if ($null -eq (Get-Command -Name Set-IntersightComputeServerSetting -ErrorAction SilentlyContinue)) {
        Write-Host "  Set-IntersightComputeServerSetting is not available in this Intersight.PowerShell version, so no power action can be sent." -ForegroundColor Yellow
        return "Failed"
    }

    # The GUI addresses /api/v1/compute/ServerSettings/<server moid> directly, so the setting
    # carries the server's own Moid. That is tried first because it is what the appliance is
    # observed to accept; the filtered lookup is the fallback for a release that separates them.
    $settingMoid = $ServerMoid
    try {
        $setting = Get-IntersightResultList -Response (Get-IntersightComputeServerSetting -Moid $ServerMoid -ErrorAction Stop) | Select-Object -First 1
        if ($null -eq $setting) {
            $setting = Get-IntersightResultList -Response (Get-IntersightComputeServerSetting -Filter "Server.Moid eq '$ServerMoid'" -ErrorAction Stop) | Select-Object -First 1
            if ($null -ne $setting -and -not [string]::IsNullOrWhiteSpace([string]$setting.Moid)) { $settingMoid = [string]$setting.Moid }
        }
    }
    catch {
        # Not fatal - the server Moid is still the best address to try.
        Write-Host "  Server setting lookup for $ServerMoid did not return an object: $($_.Exception.Message)" -ForegroundColor DarkGray
    }

    if ($PowerState -eq 'Reboot') {
        Write-Host "  WARNING: AdminPowerState 'Reboot' restarts the IMC, not the server. Staged firmware will NOT activate." -ForegroundColor Red
        Write-Host "  Set `$Global:IntersightActivationPowerAction to 'PowerCycle' to reset the server." -ForegroundColor Red
    }

    Write-Host "  Sending $PowerState to server $ServerMoid (setting $settingMoid)." -ForegroundColor Cyan
    try {
        Set-IntersightComputeServerSetting -Moid $settingMoid -AdminPowerState $PowerState -ErrorAction Stop | Out-Null
        return "Sent"
    }
    catch {
        $message = [string]$_.Exception.Message

        # "Cannot perform power action when a firmware upgrade is in progress" is not a failure.
        # It means the upgrade this run started is still running, and the appliance is refusing to
        # power-cycle underneath it - which is exactly right. The answer is to wait and ask again,
        # not to give up.
        if ($message -match '(?i)action_not_allowed_firmware_upgrade_in_progress|firmware upgrade is in progress') {
            Write-Host "  A firmware upgrade is already in progress on this server, so the power action was refused." -ForegroundColor Cyan
            Write-Host "  That is the upgrade this deploy started. Standing off and asking again." -ForegroundColor Cyan
            return "UpgradeInProgress"
        }

        Write-Host "  The power action was not accepted: $message" -ForegroundColor Yellow
        return "Failed"
    }
}

function ConvertTo-IntersightWorkflowStatus {
    <#
    .SYNOPSIS
        Normalises an Intersight workflow status string to Running, Completed, Failed or Unknown.

    .DESCRIPTION
        There are TWO enum families in the field, and which one an appliance reports depends on its
        release. Per the Intersight SDK models:

          workflow.WorkflowInfo.Status          RUNNING, WAITING, COMPLETED, TIME_OUT, FAILED
          workflow.WorkflowInfo.WorkflowStatus  NotStarted, InProgress, Waiting, Completed, Failed,
                                                Terminated, Canceled, Paused

        Reading only one of them is how a run ends up treating a finished workflow as never having
        started. Both are accepted here, matched case-insensitively with separators stripped, so
        TIME_OUT and TimedOut land in the same place.

        WAITING and PAUSED are Running, not Failed. A workflow waiting on a reboot acknowledgement
        is exactly the state this run creates on purpose - calling it a failure would abandon a
        perfectly healthy activation.

        Anything unrecognised is Unknown, never a pass. A status this script cannot read must not
        be allowed to look like completion.
    #>
    param($Value)

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return "Unknown" }

    # Strip anything that is not a letter so TIME_OUT, Time-Out and TimedOut all collapse together.
    $key = ($text.ToUpper() -replace '[^A-Z]', '')

    switch ($key) {
        'RUNNING'    { return "Running" }
        'INPROGRESS' { return "Running" }
        'WAITING'    { return "Running" }
        'PAUSED'     { return "Running" }
        'NOTSTARTED' { return "Running" }
        'SCHEDULED'  { return "Running" }
        'COMPLETED'  { return "Completed" }
        'SUCCESS'    { return "Completed" }
        'SUCCESSFUL' { return "Completed" }
        'OK'         { return "Completed" }
        'FAILED'     { return "Failed" }
        'TIMEOUT'    { return "Failed" }
        'TIMEDOUT'   { return "Failed" }
        'TERMINATED' { return "Failed" }
        'CANCELED'   { return "Failed" }
        'CANCELLED'  { return "Failed" }
        default      { return "Unknown" }
    }
}

function Resolve-IntersightRelationshipObject {
    <#
    .SYNOPSIS
        Returns the object inside a relationship wrapper, or the object itself if it is not wrapped.

    .DESCRIPTION
        The same generated oneOf wrapper that hides Moids behind ActualInstance hides whole objects
        the same way. An expanded RunningWorkflows entry is a WorkflowWorkflowInfoRelationship, and
        its Status lives on ActualInstance - reading $_.Status straight off the wrapper returns
        nothing at all, which is indistinguishable from "no workflow is running".
    #>
    param($Relationship)

    $current = $Relationship
    for ($depth = 0; $depth -lt 3; $depth++) {
        if ($null -eq $current) { return $null }
        $hasActual = $false
        try { $hasActual = ($current.PSObject.Properties.Name -contains 'ActualInstance') -and ($null -ne $current.ActualInstance) } catch {}
        if (-not $hasActual) { return $current }
        $current = $current.ActualInstance
    }
    return $current
}

function Get-IntersightProfileWorkflowActivity {
    <#
    .SYNOPSIS
        What the workflow engine is currently doing for a server profile.

    .DESCRIPTION
        This is the signal that lets the run wait on ACTIONS rather than on a clock. Per the
        Intersight SDK, server.Profile carries RunningWorkflows - "The WorkflowInfos in the workflow
        engine that are running for this server Profile" - so the deploy and the activation can be
        watched as they happen instead of being guessed at from a timer.

        Two routes, in order:

          1. The profile re-read with -Expand RunningWorkflows. Gives the workflow's name, status
             and percentage complete, so the operator sees "Deploy 45%" rather than "still waiting".
          2. The profile re-read without -Expand. The relationship is then just a MoRef, but its
             PRESENCE is still the answer: the field is named RunningWorkflows, so a non-empty list
             means the engine is busy. Status is reported as Running with no detail.

        Returns Known=$false when neither route answered. That is NOT "nothing is running" - the
        caller must fall back to the firmware task and ConfigState rather than treating an
        unreadable engine as an idle one.

        A workflow that ended Failed or TimedOut is surfaced as Failed so the run can stop waiting
        for something that is never going to finish.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$ProfileMoid)

    $result = [pscustomobject]@{
        Known = $false; Running = $false; Failed = $false
        Status = "Unknown"; Name = ""; Progress = $null; Count = 0; Detail = ""
        # The profile object this read returned. The caller needs ConfigState from the same poll,
        # and it is already here - re-fetching it would be a third round trip per poll, every poll,
        # for every host in the batch.
        Profile = $null
    }

    if ([string]::IsNullOrWhiteSpace($ProfileMoid)) {
        $result.Detail = "No profile Moid to read."
        return $result
    }

    $entries = @()
    $expanded = $false

    foreach ($useExpand in @($true, $false)) {
        try {
            $response = if ($useExpand) { Get-IntersightServerProfile -Moid $ProfileMoid -Expand 'RunningWorkflows' -ErrorAction Stop }
                        else            { Get-IntersightServerProfile -Moid $ProfileMoid -ErrorAction Stop }
            $profileNow = Get-IntersightResultList -Response $response | Select-Object -First 1
            if ($null -eq $profileNow) { continue }
            if ($profileNow.PSObject.Properties.Name -notcontains 'RunningWorkflows') { continue }

            $result.Known = $true
            $result.Profile = $profileNow
            $expanded = $useExpand
            $entries = @($profileNow.RunningWorkflows | Where-Object { $null -ne $_ })
            break
        }
        catch {
            $result.Detail = $_.Exception.Message
        }
    }

    if (-not $result.Known) {
        if ([string]::IsNullOrWhiteSpace($result.Detail)) { $result.Detail = "The profile did not report RunningWorkflows." }
        return $result
    }

    $result.Count = $entries.Count
    if ($entries.Count -eq 0) {
        $result.Status = "Completed"
        $result.Detail = "No workflow is running for this profile."
        return $result
    }

    # Unexpanded: the list is MoRefs only. Its presence is the answer.
    if (-not $expanded) {
        $result.Running = $true
        $result.Status = "Running"
        $result.Detail = "$($entries.Count) workflow(s) running (status not expanded)."
        return $result
    }

    $statuses = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $entries) {
        $workflow = Resolve-IntersightRelationshipObject -Relationship $entry
        if ($null -eq $workflow) { continue }

        $raw = ""
        foreach ($property in @('Status','WorkflowStatus')) {
            try {
                if ($workflow.PSObject.Properties.Name -contains $property -and -not [string]::IsNullOrWhiteSpace([string]$workflow.$property)) {
                    $raw = [string]$workflow.$property
                    break
                }
            } catch {}
        }

        $normalised = ConvertTo-IntersightWorkflowStatus -Value $raw
        # An expanded entry with no readable status is still a running workflow - it is in the
        # RunningWorkflows list. Reading it as Unknown and moving on would end the wait early.
        if ($normalised -eq "Unknown") { $normalised = "Running" }
        [void]$statuses.Add($normalised)

        if ([string]::IsNullOrWhiteSpace($result.Name)) {
            try { $result.Name = [string]$workflow.Name } catch {}
        }
        try {
            if ($workflow.PSObject.Properties.Name -contains 'Progress' -and $null -ne $workflow.Progress) {
                $result.Progress = [double]$workflow.Progress
            }
        } catch {}
    }

    if ($statuses -contains "Failed")  { $result.Failed = $true;  $result.Status = "Failed" }
    elseif ($statuses -contains "Running") { $result.Running = $true; $result.Status = "Running" }
    else { $result.Status = "Completed" }

    $result.Detail = "$($entries.Count) workflow(s): $(($statuses | Sort-Object -Unique) -join ', ')."
    return $result
}

function Get-IntersightFirmwareTaskState {
    <#
    .SYNOPSIS
        Says whether Intersight still has a firmware task running for a server.

    .DESCRIPTION
        Returns Running, Finished or Unknown.

        Asks firmware/Upgrades for this server with Status eq 'IN_PROGRESS' - the same query the
        GUI issues while it watches an upgrade. Rows means running, none means finished. The
        appliance decides; nothing here interprets a state string.

        Unknown is a real answer and is not treated as Finished. Where the status cannot be read,
        the caller falls back to the definitive test: attempt the power action and let the appliance
        say. Its refusal - action_not_allowed_firmware_upgrade_in_progress - is authoritative in a
        way no status read is.

        Never throws.
    #>
    param([Parameter(Mandatory=$true)][string]$ServerMoid)

    # The exact query the Intersight GUI issues while it watches an upgrade, taken from a HAR
    # capture of that page:
    #
    #   GET /api/v1/firmware/Upgrades
    #       ?$filter=(Server.Moid in ('<moid>')) and (Status eq 'IN_PROGRESS')&$select=Server
    #
    # One call, one field, and the appliance does the deciding. Rows returned means an upgrade is
    # running; none means it is not. An earlier version read firmware/UpgradeStatuses and pattern-
    # matched free-text state strings, which was guesswork against a field that already has a
    # filterable status.
    if ($null -eq (Get-Command -Name Get-IntersightFirmwareUpgrade -ErrorAction SilentlyContinue)) { return "Unknown" }

    try {
        $rows = @(Get-IntersightResultList -Response (Get-IntersightFirmwareUpgrade -Filter "(Server.Moid in ('$ServerMoid')) and (Status eq 'IN_PROGRESS')" -ErrorAction Stop))
    }
    catch { return "Unknown" }

    if ($rows.Count -gt 0) {
        Write-Host "    Intersight reports $($rows.Count) firmware upgrade(s) IN_PROGRESS for this server." -ForegroundColor DarkGray
        return "Running"
    }

    return "Finished"
}

function New-VMHostConnectSpec {
    <#
    .SYNOPSIS
        Builds the HostConnectSpec used to reconnect a host with explicit credentials.

    .DESCRIPTION
        Separated so the reconnect can be tested without PowerCLI's types being present. The
        password is taken out of the PSCredential only here, at the moment it is handed to the API,
        and is never stored, logged or written to the run summary.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [Parameter(Mandatory=$true)][pscredential]$Credential
    )

    $spec = New-Object VMware.Vim.HostConnectSpec
    $spec.HostName = $HostName
    $spec.UserName = $Credential.UserName
    $spec.Password = $Credential.GetNetworkCredential().Password
    $spec.Force    = $true
    return $spec
}

function Test-VMHostDisconnected {
    <#
    .SYNOPSIS
        Is this host in vCenter's inventory but not usable? Disconnected or NotResponding.

    .DESCRIPTION
        Told apart from "not back yet" deliberately. A host still rebooting is absent or briefly
        NotResponding and will resolve itself; a host vCenter has DISCONNECTED because it cannot
        authenticate to it will sit there indefinitely. Only the second is worth spending a root
        password on, and the caller waits $HostReconnectAfterDisconnectMinutes before deciding
        which it is looking at.
    #>
    param([Parameter(Mandatory=$true)][string]$HostName)

    try {
        $hostObj = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
        if ($null -eq $hostObj) { return $false }
        $state = [string]$hostObj.ConnectionState
        return ($state -eq "Disconnected" -or $state -eq "NotResponding")
    }
    catch { return $false }
}

function Restore-DisconnectedVMHost {
    <#
    .SYNOPSIS
        Reconnects a host that vCenter has dropped, using the ESXi root credential.

    .DESCRIPTION
        The failure this exists for: the host reboots, comes back, and vCenter cannot re-establish
        its connection because the password it holds for the host no longer works. vCenter shows it
        Disconnected and will not recover on its own, so the run waits out its whole window for
        something that is never going to resolve itself.

        Two attempts, cheapest first:

          1. Set-VMHost -State Connected. Reconnects using the credentials vCenter already holds,
             which is enough for a transient drop and costs nothing to try.
          2. ReconnectHost_Task with an explicit HostConnectSpec carrying the root credential. This
             is the one that fixes a stale password, and it is the vSphere API's own operation for
             it - NOT a remove-and-re-add, which would take the host's VMs out of inventory with it.

        Returns $true only when vCenter reports the host Connected or in Maintenance afterwards.
        Never throws: a host that cannot be reconnected is the caller's decision, not a reason to
        end a run that has other hosts in flight.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [int]$TimeoutMinutes = 10
    )

    if ($null -eq $Global:EsxiRootCredential) {
        Write-Host "  '$HostName' is disconnected, but no ESXi root credential was provided for this cluster - cannot reconnect it automatically." -ForegroundColor Yellow
        return $false
    }

    Write-Host "  Reconnecting '$HostName' with the ESXi root credential." -ForegroundColor Yellow

    try {
        $hostObj = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
        if ($null -eq $hostObj) {
            Write-Host "  '$HostName' is not in vCenter's inventory at all - it has to be added back by hand." -ForegroundColor Yellow
            return $false
        }

        # 1. The cheap attempt: vCenter's own stored credentials.
        try { Set-VMHost -VMHost $hostObj -State Connected -Confirm:$false -ErrorAction Stop | Out-Null }
        catch { Write-Host "  Reconnect with vCenter's stored credentials failed: $($_.Exception.Message)" -ForegroundColor DarkGray }

        $hostObj = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
        if ($null -ne $hostObj -and ($hostObj.ConnectionState -eq "Connected" -or $hostObj.ConnectionState -eq "Maintenance")) {
            Write-Host "  '$HostName' reconnected without needing the root password." -ForegroundColor Green
            return $true
        }

        # 2. The one that fixes a stale password.
        $spec = New-VMHostConnectSpec -HostName $HostName -Credential $Global:EsxiRootCredential
        [void]$hostObj.ExtensionData.ReconnectHost_Task($spec, $null, $null)
    }
    catch {
        Write-Host "  Reconnecting '$HostName' failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }

    # vCenter accepts the task and reports the old state for a while, so wait for the transition.
    $endTime = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $endTime) {
        Start-Sleep -Seconds 15
        try {
            $current = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
            if ($null -ne $current -and ($current.ConnectionState -eq "Connected" -or $current.ConnectionState -eq "Maintenance")) {
                Write-Host "  '$HostName' is reconnected (ConnectionState: $($current.ConnectionState))." -ForegroundColor Green
                return $true
            }
        }
        catch { }
    }

    Write-Host "  '$HostName' is still not connected $TimeoutMinutes minute(s) after the reconnect was sent." -ForegroundColor Yellow
    return $false
}

function Test-VMHostRejoinedAfterReboot {
    <#
    .SYNOPSIS
        Has vCenter got this host back? Used only when Intersight cannot answer.

    .DESCRIPTION
        The fallback for an unreadable ConfigState. Intersight not reporting a profile's state is
        not evidence of anything - but the HOST being back in vCenter is. If the blade has restarted
        and rejoined, the activation plainly happened, whatever the appliance will or will not say
        about it.

        This is a READ, and the only vCenter call anywhere in the activation path. Nothing is
        changed here: no Maintenance mode transition, no reboot, no migration. Those all stay
        behind the reconnect gate that runs after the activation returns.

        Evidence required:
          - the host is in vCenter's inventory, and
          - its ConnectionState is Connected or Maintenance, and
          - its boot time has CHANGED from the baseline this run captured before it acted.

        The boot time is the part that matters. "The host is Connected" cannot tell "came back"
        from "never left", and on a firmware run the difference is whether the host was upgraded.
        Where no baseline exists - nothing was ever sent for this host - presence is accepted,
        because there is no restart to prove.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$HostName)

    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }

    try {
        $hostObj = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
        if ($null -eq $hostObj) { return $false }
        $state = [string]$hostObj.ConnectionState
        if ($state -ne "Connected" -and $state -ne "Maintenance") { return $false }

        # A null map is "no baseline", not an error. Swallowed into $false by the catch below it
        # turns a missing global into a host that can never be seen to return - an infinite wait
        # from a one-line omission, which is exactly how it was found.
        if ($null -eq $Global:PreRebootBootTimes -or -not $Global:PreRebootBootTimes.ContainsKey($HostName)) { return $true }
        $before = [string]$Global:PreRebootBootTimes[$HostName]
        $now = Get-VMHostBootTime -VMHostObject $hostObj
        if ([string]::IsNullOrWhiteSpace($before) -or [string]::IsNullOrWhiteSpace($now)) { return $true }
        return ($now -ne $before)
    }
    catch { return $false }
}

function Get-IntersightActivationProgress {
    <#
    .SYNOPSIS
        One round of the three activation signals for one server profile.

    .DESCRIPTION
        Factored out so a whole batch can be watched in a single polling loop rather than one host
        after another. Reads, in the order the appliance does the work:

          1. server.Profile.RunningWorkflows, expanded - the deploy/activate workflow by name,
             status and percentage complete.
          2. firmware/Upgrades for the server with Status eq 'IN_PROGRESS'.
          3. The profile's ConfigState.

        Complete means ALL THREE are clear. Any one still busy names the phase.

        Two Intersight calls per profile per round: the expanded profile read serves both the
        workflow and the ConfigState, and the firmware upgrade query is the second.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ProfileMoid,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$ServerMoid,
        # Only used for the unreadable-ConfigState fallback below. Empty disables it.
        [string]$HostName = ""
    )

    $workflow = Get-IntersightProfileWorkflowActivity -ProfileMoid $ProfileMoid

    if ($workflow.Failed) {
        $failedName = if ($workflow.Name) { "'$($workflow.Name)'" } else { "the deploy workflow" }
        return [pscustomobject]@{
            Complete = $false; Failed = $true; ConfigState = "unknown"
            Phase = "workflow $failedName ended $($workflow.Status)"
        }
    }

    $taskState = if ([string]::IsNullOrWhiteSpace($ServerMoid)) { "Unknown" } else { Get-IntersightFirmwareTaskState -ServerMoid $ServerMoid }

    # Reuse the profile the workflow read already returned - it is the same GET.
    $stillStaged = $false
    $stateKnown = $false
    $configState = "unreadable"
    try {
        $profileNow = $workflow.Profile
        if ($null -eq $profileNow) {
            $profileNow = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $ProfileMoid -ErrorAction Stop) | Select-Object -First 1
        }
        if ($null -ne $profileNow) {
            $state = Get-IntersightProfileDeployState -ServerProfile $profileNow
            $stateKnown = $state.StateKnown
            $configState = [string]$state.ConfigState
            $stillStaged = $state.RequiresDeploy
        }
    }
    catch {}

    $phase = ""
    if ($workflow.Running) {
        $progress = if ($null -ne $workflow.Progress) { " - $([int]$workflow.Progress)% complete" } else { "" }
        $name = if ($workflow.Name) { "'$($workflow.Name)'" } else { "a deploy workflow" }
        $phase = "workflow $name is running$progress"
    }
    elseif ($taskState -eq "Running") { $phase = "the firmware upgrade is in progress" }
    elseif ($stillStaged)             { $phase = "the profile is still $configState" }
    elseif (-not $stateKnown) {
        # INTERSIGHT CANNOT ANSWER. Ask vCenter instead: if the host has restarted and rejoined,
        # the activation happened, whatever the appliance will say about it. Without this the run
        # sat out the whole ceiling on a host that was already back and healthy - which is exactly
        # what it did on a live run, for twenty minutes, before the operator gave up on it.
        if (Test-VMHostRejoinedAfterReboot -HostName $HostName) {
            return [pscustomobject]@{
                Complete    = $true
                Failed      = $false
                ConfigState = $configState
                Phase       = "complete; ConfigState unreadable, but the host is back in vCenter with a new boot time"
            }
        }
        $phase = "the profile ConfigState could not be read, and the host is not back in vCenter yet"
    }

    return [pscustomobject]@{
        Complete    = [string]::IsNullOrWhiteSpace($phase)
        Failed      = $false
        ConfigState = $configState
        Phase       = if ([string]::IsNullOrWhiteSpace($phase)) { "complete; profile $configState" } else { $phase }
    }
}

function Wait-IntersightActivationCompleteForBatch {
    <#
    .SYNOPSIS
        Watches EVERY profile in the batch at once, and returns as each one finishes.

    .DESCRIPTION
        THIS IS WHY THE BATCH IS CONCURRENT. Watching one host through to completion before even
        looking at the next made a batch of six take six activation windows end to end - the hosts
        were evacuated together and then upgraded one at a time, which is the worst of both. Every
        profile is now polled in the same loop, so the batch takes as long as its SLOWEST host, not
        the sum of all of them.

        Targets are objects carrying Host, ProfileMoid, ServerMoid and Label. Returns a hashtable
        keyed by Host, each entry { Completed; Phase }, so the caller can tell which hosts finished
        and which need a decision.

        A profile whose workflow FAILS is dropped from the poll immediately - there is nothing to
        wait for - but the rest of the batch carries on being watched.

        $MaxMinutes is the ceiling for the WHOLE batch, not per host, because they run at the same
        time. Press C to stop polling and move on, E to exit.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Targets,
        [Parameter(Mandatory=$true)][int]$MaxMinutes
    )

    $result = @{}
    foreach ($target in $Targets) { $result[$target.Host] = [pscustomobject]@{ Completed = $false; Phase = "not started" } }
    if ($Targets.Count -eq 0 -or $MaxMinutes -le 0) { return $result }

    $intervalSeconds = [int]$Global:IntersightPollIntervalSeconds
    if ($intervalSeconds -lt 5) { $intervalSeconds = 5 }

    Write-Host "  Polling Intersight for $($Targets.Count) profile(s) at once, every $intervalSeconds second(s), up to $MaxMinutes minute(s). Press C to move on, E to exit." -ForegroundColor Cyan
    $endTime = (Get-Date).AddMinutes($MaxMinutes)
    $nextPoll = Get-Date
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($target in $Targets) { [void]$pending.Add($target) }
    $lastPhase = @{}
    $lastRemaining = -1

    while ((Get-Date) -lt $endTime -and $pending.Count -gt 0) {
        $key = Read-PendingConsoleKey
        if ($key -eq "E") { Stop-SafeExit -Message "Stopped while polling for the firmware activation." }
        if ($key -eq "C") {
            Write-Host "    Moving on at the operator's request. $($pending.Count) profile(s) not confirmed." -ForegroundColor Yellow
            foreach ($target in $pending) { $result[$target.Host].Phase = "operator moved on during: $($result[$target.Host].Phase)" }
            return $result
        }

        if ((Get-Date) -ge $nextPoll) {
            $nextPoll = (Get-Date).AddSeconds($intervalSeconds)

            # .ToArray(), not @($pending). Wrapping a Generic.List[object] in an array
            # subexpression throws "Argument types do not match" on this PowerShell build - the
            # same trap as the closing report in 21.7.0. A snapshot is still required, because the
            # loop removes from $pending as hosts finish. Test-ScriptLint now enforces this.
            foreach ($target in $pending.ToArray()) {
                $progress = Get-IntersightActivationProgress -ProfileMoid ([string]$target.ProfileMoid) -ServerMoid ([string]$target.ServerMoid) -HostName ([string]$target.Host)
                $result[$target.Host].Phase = $progress.Phase

                if ($progress.Failed) {
                    Write-Host "    $($target.Label): $($progress.Phase). Not waiting any longer." -ForegroundColor Red
                    [void]$pending.Remove($target)
                    continue
                }
                if ($progress.Complete) {
                    $result[$target.Host].Completed = $true
                    Write-Host "    $($target.Label): activation complete - profile is $($progress.ConfigState)." -ForegroundColor Green
                    [void]$pending.Remove($target)
                    continue
                }
                # Announce only a CHANGE of phase per host, so a batch of six does not print six
                # identical lines every poll for an hour.
                if ($lastPhase[$target.Host] -ne $progress.Phase) {
                    Write-Host "    $($target.Label): $($progress.Phase)." -ForegroundColor Cyan
                    $lastPhase[$target.Host] = $progress.Phase
                }
            }

            # Heartbeat only when the minute actually ticks over. At a 30-second interval this
            # printed the same line twice a minute for the length of the ceiling.
            if ($pending.Count -gt 0) {
                $remaining = [int][math]::Ceiling(($endTime - (Get-Date)).TotalMinutes)
                if ($remaining -ne $lastRemaining) {
                    Write-Host "      $($pending.Count) of $($Targets.Count) still going - $remaining minute(s) of the ceiling remaining." -ForegroundColor DarkGray
                    $lastRemaining = $remaining
                }
            }
        }

        Start-Sleep -Seconds 5
    }

    foreach ($target in $pending) {
        Write-Host "    Ceiling of $MaxMinutes minute(s) reached for $($target.Label) while $($result[$target.Host].Phase)." -ForegroundColor Yellow
        $result[$target.Host].Phase = "ceiling reached while $($result[$target.Host].Phase)"
    }
    return $result
}

function Invoke-IntersightProfileActivate {
    <#
    .SYNOPSIS
        Sends the Activate scheduled action - what the GUI sends to reboot and activate.

    .DESCRIPTION
        Captured from the Intersight GUI, deploying a profile with Reboot Immediately to Activate
        ticked. The request is:

            POST /api/v1/server/Profiles/<moid>
            {"ScheduledActions":[{"Action":"Activate","ProceedOnReboot":true}]}

        which is 67 bytes and matches the captured content-length exactly. Two things in it were
        wrong in this script until now:

          - The action is "Activate", not "Deploy". Deploy stages; Activate is what restarts the
            blade and brings the staged firmware into service. GitHub issue #141 - "no longer
            allows Activate" - is about the profile's own -Action parameter, which accepts only
            Deploy and Unassign. The SCHEDULED ACTION's Action field is a different field and does
            accept Activate. Conflating the two cost several runs.
          - The body carries ONLY ScheduledActions. No top-level Action is sent with it.

        Returns Sent, UpgradeInProgress or Failed, on the same terms as the power action, and never
        throws.
    #>
    param([Parameter(Mandatory=$true)][string]$ProfileMoid)

    if ($null -eq (Get-Command -Name Initialize-IntersightPolicyScheduledAction -ErrorAction SilentlyContinue)) {
        Write-Host "  Initialize-IntersightPolicyScheduledAction is not available, so Activate cannot be sent." -ForegroundColor Yellow
        return "Failed"
    }

    Write-Host "  Sending ScheduledActions: Action=Activate, ProceedOnReboot=true to profile $ProfileMoid." -ForegroundColor Cyan
    try {
        $action = Initialize-IntersightPolicyScheduledAction -Action 'Activate' -ProceedOnReboot $true
        Set-IntersightServerProfile -Moid $ProfileMoid -ScheduledActions @($action) -ErrorAction Stop | Out-Null
        return "Sent"
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -match '(?i)action_not_allowed_firmware_upgrade_in_progress|firmware upgrade is in progress') {
            Write-Host "  Activate was refused because a firmware upgrade is still in progress." -ForegroundColor Cyan
            return "UpgradeInProgress"
        }
        Write-Host "  Activate was not accepted: $message" -ForegroundColor Yellow
        return "Failed"
    }
}

function Invoke-IntersightActivationForBatch {
    <#
    .SYNOPSIS
        Activates EVERY profile in the batch at the same time, then watches them all together.

    .DESCRIPTION
        CONCURRENT BY DESIGN. The hosts were evacuated together, so they are upgraded together.
        Doing this one host at a time meant a batch of six took six activation windows end to end -
        the cluster gave up six hosts' capacity up front and then got them back one at a time,
        which is the worst of both arrangements. A batch now takes as long as its SLOWEST host.

        Three phases, each across the whole batch before the next begins:

          1. RESOLVE. Find the server each profile is assigned to. A profile with no server cannot
             be activated; it is recorded and dropped, and the others carry on.
          2. SEND. Activate every profile - ScheduledActions Action=Activate, ProceedOnReboot=true.
             These are quick API calls, so they all go out within seconds of each other and the
             blades restart together. Where Activate is refused and no firmware upgrade is running,
             the power-cycle fallback is tried for that profile only.
          3. WATCH. One polling loop over every profile at once, each finishing when its workflow,
             firmware upgrade and ConfigState are all clear.

        Whatever has not finished when the ceiling is reached is put to the operator ONCE for the
        batch - RETRY re-sends Activate to only those profiles and watches again, CONTINUE moves to
        the vCenter checks, EXIT stops safely. Not once per host: six prompts for one decision is
        how an operator ends up answering without reading.

        NOTHING HERE ENDS THE RUN except an explicit EXIT.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Rows,
        [Parameter(Mandatory=$true)][string]$BatchNumber,
        # Send and return. The caller watches for the result some other way - the rolling upgrade
        # watches vCenter for the host's return, which is what its next step needs anyway.
        [switch]$NoWait
    )

    if ($Rows.Count -eq 0) { return }

    # --- 1. Resolve the server behind each profile ------------------------------------------------
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Rows) {
        $serverMoid = ""
        try {
            $current = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$row.ProfileMoid)) {
                $current = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $row.ProfileMoid -ErrorAction Stop) | Select-Object -First 1
            }
            if ($null -eq $current) { $current = $row.ServerProfileObj }
            if ($null -ne $current) { $serverMoid = Get-IntersightAssignedServerMoid -ServerProfile $current -ProfileMoid ([string]$row.ProfileMoid) }
        }
        catch {
            Write-Host "  Could not re-read '$($row.ServerProfile)' to find its server: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        if ([string]::IsNullOrWhiteSpace($serverMoid)) {
            Write-Host "  '$($row.ServerProfile)' has firmware staged, but the server it is assigned to could not be identified." -ForegroundColor Yellow
            Write-Host "  No power action has been sent. Power-cycle the blade from Intersight to activate it." -ForegroundColor Yellow
            Add-ManualAttentionHost -HostName $row.Host -Reason "Profile not associated with a server" -Detail "Server profile '$($row.ServerProfile)' reported no assigned server, so the staged firmware could not be activated. Check the profile association in Intersight."
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Power action" -Result "NoServer" -Details "AssignedServer/AssociatedServer carried no Moid; firmware staged on '$($row.ServerProfile)' remains inactive."
            continue
        }

        [void]$targets.Add([pscustomobject]@{
            Host        = $row.Host
            Row         = $row
            ProfileMoid = [string]$row.ProfileMoid
            ServerMoid  = $serverMoid
            Label       = "'$($row.ServerProfile)'"
        })
    }

    if ($targets.Count -eq 0) { return }

    $powerState = [string]$Global:IntersightActivationPowerAction
    $round = 0
    # Whether anything was actually accepted. The batch loop skips its own fixed post-reboot wait
    # when this activation has held for it - but only if something really was sent or completed.
    # Claiming the wait after a refused activation would have vCenter checked for a host that never
    # restarted.
    $anySent = $false

    while ($true) {
        $round++

        # --- 2. Send to everything that still needs it --------------------------------------------
        $outstanding = New-Object System.Collections.Generic.List[object]
        foreach ($target in $targets.ToArray()) {
            # Has it settled on its own? The appliance may have completed the work already.
            $settled = $false
            try {
                $profileNow = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $target.ProfileMoid -ErrorAction Stop) | Select-Object -First 1
                if ($null -ne $profileNow) {
                    $state = Get-IntersightProfileDeployState -ServerProfile $profileNow
                    if ($state.StateKnown -and -not $state.RequiresDeploy) {
                        Write-Host "  $($target.Label) is $($state.ConfigState) - Intersight completed the activation itself." -ForegroundColor Green
                        Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $target.Host -Action "Confirm activation" -Result "Activated" -Details "ConfigState is $($state.ConfigState) on round $round; no action was needed."
                        $settled = $true
                    }
                }
            }
            catch {
                Write-Host "  Round $round : could not read $($target.Label) - $($_.Exception.Message)" -ForegroundColor Yellow
            }
            if ($settled) { continue }

            # ACTIVATE. Never gated on the firmware task finishing - the upgrade sits at
            # IN_PROGRESS precisely BECAUSE it is waiting for this acknowledgement.
            $taskState = Get-IntersightFirmwareTaskState -ServerMoid $target.ServerMoid
            $outcome = Invoke-IntersightProfileActivate -ProfileMoid $target.ProfileMoid
            Write-Host "  $($target.Label): Activate $outcome (firmware task $taskState)." -ForegroundColor Cyan
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $target.Host -Action "Activate" -Result $outcome -Details "ScheduledActions Action=Activate ProceedOnReboot=true on round $round (task state $taskState)."

            # A power action is genuinely refused mid-upgrade, so it is only worth trying when no
            # upgrade is running.
            if ($outcome -eq "Failed" -and $taskState -ne "Running") {
                $outcome = Invoke-IntersightServerPowerAction -ServerMoid $target.ServerMoid -PowerState $powerState
                Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $target.Host -Action "Power action" -Result $outcome -Details "Fallback $powerState to server $($target.ServerMoid) on round $round."
            }

            if ($outcome -eq "Sent") { $anySent = $true }
            [void]$outstanding.Add($target)
        }

        if ($outstanding.Count -eq 0) { return }

        if ($NoWait) {
            Write-Host "  Sent for $($outstanding.Count) profile(s). Not waiting - the rolling upgrade watches for each host's return." -ForegroundColor Green
            foreach ($target in $outstanding.ToArray()) {
                Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $target.Host -Action "Confirm activation" -Result "Sent" -Details "Activation sent for server $($target.ServerMoid); the host's return to vCenter is the completion signal."
            }
            return
        }

        # --- 3. Watch them all at once ------------------------------------------------------------
        Write-Host "  Sent for $($outstanding.Count) profile(s). Watching them together." -ForegroundColor Green
        $ceiling = if ($round -eq 1) { $Global:IntersightActivationHoldMinutes } else { $Global:IntersightActivationWaitMinutes }
        $progress = Wait-IntersightActivationCompleteForBatch -Targets $outstanding.ToArray() -MaxMinutes $ceiling

        $stillGoing = New-Object System.Collections.Generic.List[object]
        foreach ($target in $outstanding.ToArray()) {
            $entry = $progress[$target.Host]
            if ($entry.Completed) {
                $anySent = $true
                Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $target.Host -Action "Confirm activation" -Result "Activated" -Details "Activation confirmed for server $($target.ServerMoid) on round $round. $($entry.Phase)."
            }
            else {
                # Deliberately NO record here. This host has not reached an outcome yet - the
                # operator is about to decide, and whichever way they go writes the single record
                # that describes what actually happened to it. Writing one now would put a
                # speculative result ahead of the real one for the same host.
                [void]$stillGoing.Add($target)
            }
        }

        if ($stillGoing.Count -eq 0) { return }

        # --- One decision for the batch, not one per host -----------------------------------------
        Write-Host "" -ForegroundColor Yellow
        Write-Host "$($stillGoing.Count) profile(s) have not activated yet:" -ForegroundColor Yellow
        foreach ($target in $stillGoing.ToArray()) {
            Write-Host "    $($target.Label) - $($progress[$target.Host].Phase)" -ForegroundColor Yellow
        }
        Write-Host "  R - retry: send Activate again to those profiles and keep watching." -ForegroundColor Yellow
        Write-Host "  C - continue: stop waiting and move on to the vCenter checks." -ForegroundColor Yellow
        Write-Host "  E - exit the run here." -ForegroundColor Yellow

        $choice = Read-ChoiceExit `
            -Message "$($stillGoing.Count) profile(s) have not activated yet. R to retry, C to continue, E to exit" `
            -AllowedChoices @("R","C") `
            -ExitMessage "Stopped while waiting for the activation of $($stillGoing.Count) profile(s)."

        # Anything that is not an explicit RETRY moves on. A loop whose only exit is a successful
        # prompt is a hang, and this one runs on a jump host that may have no console at all.
        if ($choice -ne "R") {
            Write-Host "  Moving on to the vCenter checks." -ForegroundColor Yellow
            foreach ($target in $stillGoing.ToArray()) {
                Add-ManualAttentionHost -HostName $target.Host -Reason "Firmware activation not confirmed" -Detail "Server profile '$($target.Row.ServerProfile)' still had changes staged when the operator chose to continue: $($progress[$target.Host].Phase). Activate it from Intersight."
                Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $target.Host -Action "Confirm activation" -Result "StillStaged" -Details "Continued after $round round(s). $($progress[$target.Host].Phase)."
            }
            return
        }

        $targets = $stillGoing
    }
}

function Invoke-IntersightAcceptAndRebootImmediateForBatch {
    <#
    .SYNOPSIS
        Deploys and activates every Intersight-routed profile in the set.

    .DESCRIPTION
        -NoWait sends the deploy and the activation and returns WITHOUT watching them finish. The
        rolling upgrade needs that: blocking here is what would stop the next host being admitted,
        and the signal it actually waits on is the host reappearing in vCenter. Without -NoWait the
        activation is watched through to completion, which is what the single-shot path wants.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,
        [Parameter(Mandatory=$true)][string]$BatchNumber,
        [switch]$NoWait
    )

    if ($HostNames.Count -eq 0) { return }

    $pendingRows = @(Get-IntersightPendingInconsistencyForBatch -HostNames $HostNames)
    Write-Host "" -ForegroundColor Cyan
    Write-Host "Intersight server profile inconsistency check for Batch ${BatchNumber}:" -ForegroundColor Cyan
    $pendingRows | Select-Object Host,ServerProfile,ConfigState,RequiresDeploy | Format-Table -AutoSize | Out-Host

    # A profile whose ConfigState could not be read is not evidence that there is nothing to do.
    # Continuing past it would quietly leave the host un-upgraded while the batch reports success.
    $unknownStateRows = @($pendingRows | Where-Object { -not $_.StateKnown })
    if ($unknownStateRows.Count -gt 0) {
        Write-Host "WARNING: ConfigState could not be read for $($unknownStateRows.Count) Intersight profile(s) in this batch: $(($unknownStateRows | Select-Object -ExpandProperty Host) -join ', ')" -ForegroundColor Yellow
        Write-Host "These hosts cannot be confirmed as either already-consistent or pending, so skipping them silently is not safe." -ForegroundColor Yellow
        foreach ($row in $unknownStateRows) {
            Add-ManualAttentionHost -HostName $row.Host -Reason "Intersight ConfigState unreadable" -Detail "ConfigState could not be read on profile '$($row.ServerProfile)', so this host cannot be confirmed as either upgraded or pending."
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "Warning" -Details "ConfigState unreadable on profile '$($row.ServerProfile)'."
        }
        if (-not (Test-DryRun)) {
            $choice = Read-ChoiceExit -Message "Intersight ConfigState unreadable for one or more hosts. S to skip them and continue, X to stop, E to exit" -AllowedChoices @("S","X") -ExitMessage "Stopped on unreadable Intersight ConfigState."
            if ($choice -eq "X") { Stop-WithMessage "Intersight ConfigState could not be read for: $(($unknownStateRows | Select-Object -ExpandProperty Host) -join ', ')." }
        }
    }

    if (Test-DryRun) {
        foreach ($row in $pendingRows) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "DryRun" -Details "ConfigState=$($row.ConfigState)."
        }
        Write-Host "DRY RUN: Would accept the firmware-policy inconsistency and reboot immediately for this batch's Intersight-routed hosts only." -ForegroundColor Green
        return
    }


    if (@($pendingRows | Where-Object { $_.RequiresDeploy }).Count -gt 0) {
        Assert-IntersightUpgradeCmdletSurface
    }

    # Rows whose deploy was sent, and then those still needing an explicit activation. Both are
    # actioned CONCURRENTLY once every deploy in the batch has gone out.
    $sentRows = New-Object System.Collections.Generic.List[object]
    $needActivation = New-Object System.Collections.Generic.List[object]

    foreach ($row in $pendingRows) {
        if (-not $row.RequiresDeploy) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "Skipped" -Details "ConfigState=$($row.ConfigState) - no staged changes to deploy."
            continue
        }

        # PRE-FLIGHT: is this profile actually on a server? A profile with nothing assigned is
        # refused by the appliance with "The server is disconnected"
        # (gershwin_server_is_not_connected) - which reads as a connectivity fault and sends the
        # operator to check a blade that is perfectly healthy. The real cause is usually that the
        # run resolved to the wrong profile of a duplicated name. Catch it here and say so.
        $preflightServerMoid = ""
        try {
            $preflightProfile = $row.ServerProfileObj
            if ($null -eq $preflightProfile -and -not [string]::IsNullOrWhiteSpace([string]$row.ProfileMoid)) {
                $preflightProfile = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $row.ProfileMoid -ErrorAction Stop) | Select-Object -First 1
            }
            if ($null -ne $preflightProfile) {
                $preflightServerMoid = Get-IntersightAssignedServerMoid -ServerProfile $preflightProfile -ProfileMoid ([string]$row.ProfileMoid) -Quiet
            }
        }
        catch {
            # Unreadable is not the same as unassigned. Fall through and let the deploy answer.
            $preflightServerMoid = "unreadable"
        }

        # DIAGNOSTIC, NOT BLOCKING. An unreadable AssignedServer relationship is not proof the
        # profile is unassigned - this SDK has hidden that Moid behind wrapper shapes before - and
        # skipping a healthy host on that basis would trade one silent fault for another. So the
        # deploy is still attempted; the finding is carried forward and only used to explain a
        # refusal, where it turns a misleading appliance message into the actual cause.
        $preflightHasServer = -not [string]::IsNullOrWhiteSpace($preflightServerMoid)
        if (-not $preflightHasServer) {
            Write-Host "  NOTE: no assigned server could be read on profile '$($row.ServerProfile)' (Moid $($row.ProfileMoid)). Attempting the deploy anyway." -ForegroundColor Yellow
        }

        $serverText = if ($preflightHasServer) { ", server $preflightServerMoid" } else { ", no assigned server readable" }
        Write-Host "Intersight: deploying server profile for '$($row.Host)' (profile '$($row.ServerProfile)', Moid $($row.ProfileMoid)$serverText, ConfigState $($row.ConfigState))." -ForegroundColor Yellow
        try {
            # Deploying the server profile is what pushes a staged firmware policy change to the
            # server - the API equivalent of Deploy in the UI, and the action that clears
            # Pending-changes.
            #
            # This replaces an earlier call to New-IntersightFirmwareUpgrade with -RebootImmediately
            # and -DisruptionAcknowledged. Per the SDK reference, that cmdlet has neither parameter,
            # and its -Server takes a ComputePhysicalRelationship (compute.Blade / compute.RackUnit),
            # not the server.Profile that was being passed. It would never have worked as written.
            #
            # ACTIVATE FROM THE START. One call, exactly what the GUI sends:
            #
            #     POST /api/v1/server/Profiles/<moid>
            #     {"ScheduledActions":[{"Action":"Activate","ProceedOnReboot":true}]}
            #
            # Not Deploy-then-wait-then-Activate. Deploy stages the firmware and leaves the profile
            # waiting for a restart; Activate does the same staging AND restarts the blade, so
            # splitting it in two only adds a wait between two halves of one operation. The body
            # carries ScheduledActions alone - no top-level -Action goes with it.
            $deployParams = @{
                Moid        = $row.ProfileMoid
                ErrorAction = 'Stop'
            }

            if ($Global:IntersightRebootImmediatelyToActivate) {
                $scheduledAction = Initialize-IntersightPolicyScheduledAction -Action 'Activate' -ProceedOnReboot $true
                $deployParams['ScheduledActions'] = @($scheduledAction)
                $sentDescription = "ScheduledActions: Action=Activate, ProceedOnReboot=true"
            }
            else {
                # Staging only, for an operator who wants to restart the blades by hand.
                $deployParams['Action'] = 'Deploy'
                $sentDescription = "Action=Deploy (staging only - no reboot acknowledgement)"
            }

            if ($Global:IntersightDeployActionParams.Count -gt 0) {
                $deployParams['ActionParams'] = @($Global:IntersightDeployActionParams | ForEach-Object { Initialize-IntersightPolicyActionParam -Name $_.Name -Value $_.Value })
                $sentDescription += "; ActionParams: $((($Global:IntersightDeployActionParams | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))"
            }

            Write-Host "  $sentDescription" -ForegroundColor DarkGray
            try {
                Set-IntersightServerProfile @deployParams | Out-Null
            }
            catch {
                # "Action 'Activate' is not allowed in the current state."
                #
                # Activate is only valid once the profile's CONFIGURATION is already deployed and
                # all that remains is to activate the firmware. From Pending-changes - the
                # configuration not yet pushed - the appliance requires Deploy first, and says so
                # plainly. The GUI capture that showed a bare Activate was taken against a profile
                # already past that point, which is why it looked like the whole story.
                #
                # So: ask for the one-call form, and let the appliance say when it needs the
                # two-step. Reacting to its answer beats predicting which states permit which
                # action - that is not published, and guessing at it has been wrong twice already.
                $message = [string]$_.Exception.Message
                if (-not ($message -match "(?i)gershwin_user_action_is_not_allowed|not allowed in the current state")) { throw }

                Write-Host "  Activate is not allowed from ConfigState '$($row.ConfigState)'. Deploying first, with the reboot acknowledgement." -ForegroundColor Yellow
                Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Activate" -Result "NotAllowed" -Details "Activate refused from ConfigState $($row.ConfigState); falling back to Deploy with ProceedOnReboot."

                $deployParams = @{
                    Moid             = $row.ProfileMoid
                    Action           = 'Deploy'
                    ScheduledActions = @(Initialize-IntersightPolicyScheduledAction -Action 'Deploy' -ProceedOnReboot $true)
                    ErrorAction      = 'Stop'
                }
                $sentDescription = "Action=Deploy; ScheduledActions: Action=Deploy, ProceedOnReboot=true (Activate refused from $($row.ConfigState))"
                Write-Host "  $sentDescription" -ForegroundColor DarkGray
                Set-IntersightServerProfile @deployParams | Out-Null
            }

            $Global:BatchActionsSent++
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "Sent" -Details "ServerProfile=$($row.ServerProfile); ConfigState was $($row.ConfigState); $sentDescription."

            # A profile still sitting in Pending-changes is not a failed deploy. A firmware policy in
            # IMM installs on next reboot, so the firmware is staged and waiting for a restart -
            # which this run then supplies, because the host is already evacuated and in
            # Maintenance mode with nothing on it.
            #
            # COLLECTED, NOT CONFIRMED HERE. Confirming inside the loop meant host 2's deploy was
            # not even SENT until host 1's confirmation window had closed - up to
            # $Global:IntersightDeployAcceptedTimeoutSeconds each. Every deploy goes out first and
            # they are confirmed together after the loop, so the batch costs one window.
            [void]$sentRows.Add($row)
        } catch {
            # SET ASIDE, NOT STOPPED ON. A deploy the appliance refuses is one host's problem, and
            # ending the run here strands every other host in the batch - already evacuated, already
            # in Maintenance mode, and now un-upgraded with no report. The rest of the batch
            # continues; this host is named in the manual rectification report at the end.
            $message = [string]$_.Exception.Message
            $reason = Get-IntersightDeployRefusalReason -Message $message -ProfileHasServer $preflightHasServer

            Write-Host "" -ForegroundColor Yellow
            Write-Host "  Intersight refused the deploy for '$($row.Host)': $($reason.Summary)" -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($reason.Advice)) {
                Write-Host "  $($reason.Advice)" -ForegroundColor Yellow
            }
            Write-Host "  Setting this host aside and continuing with the rest of the batch." -ForegroundColor Yellow

            # Nothing was sent, so nothing is going to reboot. Leaving a boot-time baseline behind
            # would have the reconnect gate wait out its whole window for a restart that was never
            # requested, and then report the host as having failed to come back.
            if ($Global:PreRebootBootTimes.ContainsKey($row.Host)) { [void]$Global:PreRebootBootTimes.Remove($row.Host) }

            Add-ManualAttentionHost -HostName $row.Host -Reason $reason.Reason -Detail "$($reason.Advice) Profile '$($row.ServerProfile)' was $($row.ConfigState) and remains un-upgraded. Appliance said: $message"
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "Failed" -Details "$($reason.Reason). $message"
            continue
        }
    }

    # EVERY deploy in the batch has now been sent, back to back. Confirm them in ONE shared window
    # rather than one window each.
    if ($sentRows.Count -gt 0) {
        $accepted = Confirm-IntersightDeployAcceptedForBatch -Rows $sentRows.ToArray() -BatchNumber $BatchNumber
        foreach ($row in $sentRows.ToArray()) {
            if (-not $accepted[$row.Host]) { [void]$needActivation.Add($row) }
        }
    }

    # Activate what is left together, so the blades restart within seconds of each other and the
    # batch takes as long as its slowest host rather than the sum of all of them.
    if ($needActivation.Count -gt 0) {
        Write-Host "" -ForegroundColor Cyan
        Write-Host "Activating $($needActivation.Count) server profile(s) concurrently for Batch ${BatchNumber}." -ForegroundColor Cyan
        if ($NoWait) {
            Invoke-IntersightActivationForBatch -Rows $needActivation.ToArray() -BatchNumber $BatchNumber -NoWait
        }
        else {
            Invoke-IntersightActivationForBatch -Rows $needActivation.ToArray() -BatchNumber $BatchNumber
        }
    }
}

# -----------------------------
# vCenter workflow helpers
# -----------------------------

function Connect-VCenterServer {
    <#
    .SYNOPSIS
        Loads PowerCLI and connects to vCenter, reporting a module load failure usefully.

    .DESCRIPTION
        Connect-VIServer auto-loads VMware.VimAutomation.Core, and when that load fails PowerShell
        reports only "the command was found in the module ... but the module could not be loaded",
        which names neither the reason nor the fix. The import is done explicitly here so the real
        inner exception can be shown, along with the causes that actually produce it.

        Also sets $global:vCenterConnected only after the connection succeeds. Recording the name
        before connecting meant a failed connect left the cleanup trying to disconnect a session
        that was never established.

    .PARAMETER Server
        vCenter FQDN or IP.
    #>
    param([Parameter(Mandatory=$true)][string]$Server)

    # No Import-Module anywhere in this script - PowerCLI is assumed present and PowerShell
    # auto-loads it on the first Connect-VIServer. When that auto-load fails, PowerShell reports
    # only "the command was found in the module ... but the module could not be loaded", which
    # names neither cause nor fix, so the catch below recognises that message and supplies both.

    # Long-running vSphere tasks outlive the 300-second default and are torn down mid-flight with
    # "An error occurred while sending the request". Session scope only - nothing persists.
    try {
        Set-PowerCLIConfiguration -Scope Session -WebOperationTimeoutSeconds $PowerCliWebOperationTimeoutSeconds -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Host "PowerCLI web operation timeout set to $PowerCliWebOperationTimeoutSeconds seconds for this session." -ForegroundColor DarkGray
    }
    catch {
        Write-Host "Could not raise the PowerCLI web operation timeout: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Long operations may fail with 'An error occurred while sending the request'." -ForegroundColor Yellow
    }

    Write-Host "Connecting to vCenter: $Server" -ForegroundColor Cyan
    try {
        Connect-VIServer -Server $Server -ErrorAction Stop | Out-Null
    }
    catch {
        Add-SummaryRecord -Stage "vCenterConnect" -Batch "" -HostName "" -Action "Connect" -Result "Failed" -Details $_.Exception.Message

        if ($_.Exception.Message -match 'could not be loaded|was found in the module') {
            Write-Host "" -ForegroundColor Red
            Write-Host "VMware PowerCLI (VMware.VimAutomation.Core) is present but failed to load." -ForegroundColor Red
            Write-Host "Underlying error:" -ForegroundColor Red
            Write-Host (Get-ExceptionDetail -ErrorRecord $_) -ForegroundColor Gray
            Write-Host "" -ForegroundColor Yellow
            Write-Host "Usual causes, most common first:" -ForegroundColor Yellow
            Write-Host "  1. Module files still carry the blocked flag, typical after an offline or" -ForegroundColor Yellow
            Write-Host "     share-based install. Unblock them:" -ForegroundColor Yellow
            Write-Host "       Get-ChildItem `"`$env:ProgramFiles\WindowsPowerShell\Modules\VMware*`" -Recurse | Unblock-File" -ForegroundColor Gray
            Write-Host "  2. PowerCLI version too old for this PowerShell. 12.3.0 and newer support" -ForegroundColor Yellow
            Write-Host "     PowerShell 7.x; older builds are Windows PowerShell only. You are on" -ForegroundColor Yellow
            Write-Host "     $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)." -ForegroundColor Yellow
            Write-Host "  3. Read-only or restrictive permissions on the module folder." -ForegroundColor Yellow
            Write-Host "  4. Group Policy requiring signed modules." -ForegroundColor Yellow
            Write-Host "" -ForegroundColor Yellow
            Write-Host "To see what this host actually has, outside this script:" -ForegroundColor Yellow
            Write-Host "  Get-Module -ListAvailable VMware.VimAutomation.Core | Select-Object Version,Path" -ForegroundColor Gray
            Write-Host "  (no version listed means it is not installed for this PowerShell edition)" -ForegroundColor Gray
            Stop-WithMessage "VMware PowerCLI could not be loaded, so vCenter cannot be contacted."
        }

        Write-Host "Could not connect to vCenter '$Server': $($_.Exception.Message)" -ForegroundColor Red
        Stop-WithMessage "vCenter connection failed."
    }

    # Only now is there something to disconnect.
    $global:vCenterConnected = $true
    Write-Host "Connected to vCenter." -ForegroundColor Green
}

function Select-ClusterInteractive {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Clusters)
    try {
        $selectedCluster = $Clusters | Select-Object Name | Out-GridView -Title "Select vCenter Cluster" -PassThru
        if ($null -ne $selectedCluster -and $selectedCluster.Name) { return ($Clusters | Where-Object { $_.Name -eq $selectedCluster.Name } | Select-Object -First 1) }
        Stop-SafeExit -Message "No cluster selected from GUI."
    } catch { Stop-WithMessage "Cluster GUI selection failed. Run from interactive Windows PowerShell with Out-GridView support." }
}

function Select-RunMode {
    <#
    .SYNOPSIS
        LIVE or DRY RUN. Those are the only two.

    .DESCRIPTION
        SAVE ONLY / NO ACKNOWLEDGEMENT was removed at the operator's direction. It staged firmware
        without ever restarting anything, which left every host in the cluster carrying a pending
        change for someone else to finish by hand - a half-done state this run had no way to
        report on afterwards. If staging without rebooting is genuinely wanted, it is a change of
        its own, made deliberately in the platform.

        The guards that used to test for it have gone with it. A mode nothing can select is a
        branch nothing can reach, and reading them cost more than they protected.
    #>
    Write-Host "`nSelect run mode:`n  1. LIVE RUN`n  2. DRY RUN / VALIDATION ONLY`n  3. Exit" -ForegroundColor Cyan
    $choice = Read-ChoiceExit -Message "Select run mode" -AllowedChoices @("1","2","3")
    if ($choice -eq "3") { Stop-SafeExit -Message "Stopped during run mode selection." }
    if ($choice -eq "1") { $Global:RunMode = "LIVE" }
    if ($choice -eq "2") { $Global:RunMode = "DRYRUN" }
}

function Select-UpgradeMode {
    Write-Host "`nSelect upgrade mode:`n  1. ESXi upgrade only`n  2. Firmware upgrade for accepted batch (infrastructure auto-detected per host via CDP/LLDP: UCS Manager or Intersight)`n  3. Exit" -ForegroundColor Cyan
    $choice = Read-ChoiceExit -Message "Select upgrade mode" -AllowedChoices @("1","2","3")
    if ($choice -eq "3") { Stop-SafeExit -Message "Stopped during upgrade mode selection." }
    if ($choice -eq "1") { $Global:UpgradeMode = "ESXI_ONLY" }
    if ($choice -eq "2") { $Global:UpgradeMode = "ESXI_UCS_FIRMWARE" }
}

function Test-VMHostOnTargetBuild { param([Parameter(Mandatory=$true)]$VMHostObject) if ([string]::IsNullOrWhiteSpace($TargetEsxiBuild)) { return $false } return ([string]$VMHostObject.Build -eq $TargetEsxiBuild) }

function Get-CapacityBasedBatchSize {
    <#
    .SYNOPSIS
        Largest batch that still leaves the required CPU and memory headroom.

    .DESCRIPTION
        Models the worst case: the batch removes the highest-capacity hosts, and every VM they
        were running has to fit on what remains. Starting from the host-count cap it walks down
        until both of these hold, where remaining capacity is first discounted by
        $ResourceSafetyBuffer:

            current cluster CPU usage    <= remaining CPU * (1 - $MinimumCpuHeadroomPercentAfterBatch/100)
            current cluster memory usage <= remaining RAM * (1 - $MinimumMemoryHeadroomPercentAfterBatch/100)

        Returns SafeBatchSize 0 when even a single host cannot be removed within those limits,
        which the caller treats as a stop rather than as a batch of one.

        A candidate ALREADY in Maintenance mode is free. It is carrying no load and its capacity is
        already out of the cluster, so removing it costs nothing that is not already spent - it is
        added to the batch on top of whatever the connected hosts can afford. That also means a
        batch made up entirely of already-parked hosts is always safe, and must never be refused
        for want of capacity: refusing it would strand the very hosts this run was asked to capture.
    #>
    param(
        # AllowEmptyCollection so an empty candidate list returns a clean "no capacity" result
        # instead of failing parameter binding partway through the run.
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$CandidateHosts,
        [Parameter(Mandatory=$true)]$Cluster
    )

    # Parked is decided by inMaintenanceMode, not by ConnectionState - a parked host whose heartbeat
    # is blipping reads NotResponding and would otherwise be counted in neither list, shrinking the
    # cluster size the ceiling is derived from. See Test-VMHostObjectInMaintenance.
    $parked    = @($CandidateHosts | Where-Object { Test-VMHostObjectInMaintenance -VMHostObject $_ })
    $connected = @($CandidateHosts | Where-Object { $_.ConnectionState -eq "Connected" -and -not (Test-VMHostObjectInMaintenance -VMHostObject $_) })
    $diagnostics = New-Object System.Collections.Generic.List[string]

    # The ceiling is HALF THE CLUSTER, not a fixed number. Capacity is still the primary constraint
    # and usually binds first; this only stops a large, idle cluster being emptied faster than DRS
    # and storage can keep up with.
    $clusterSize = $connected.Count + $parked.Count
    $hardCap = [int][Math]::Floor($clusterSize * [double]$MaxConcurrentHostFraction)
    if ($hardCap -lt 1) { $hardCap = 1 }
    if ([int]$MaxAbsoluteBatchSize -gt 0 -and $hardCap -gt [int]$MaxAbsoluteBatchSize) { $hardCap = [int]$MaxAbsoluteBatchSize }
    [void]$diagnostics.Add(("Ceiling: {0} of {1} host(s) may be out at once ({2:P0} of the cluster)." -f $hardCap, $clusterSize, $MaxConcurrentHostFraction))

    # Free slots, capped so a large pool of parked hosts cannot blow past MaxAbsoluteBatchSize.
    # Parked hosts COUNT TOWARDS THE CEILING. They are out of service, and the ceiling is a limit
    # on how much of the cluster may be out AT ONCE - not on how many the run last asked for.
    #
    # Exempting them, as an earlier build did, breaks the rolling engine completely: the hosts it
    # already has in flight ARE parked, so the limit grew by exactly the number in flight and the
    # room to admit more never shrank. A live 21-host run reported "Ceiling: 10 of 21" and then
    # "Capacity allows 17 host(s) out at once; 10 already in flight", and started a second wave of
    # 7 while the first 10 were still rebooting.
    $freeSlots = [Math]::Min($parked.Count, $hardCap)
    if ($freeSlots -gt 0) {
        [void]$diagnostics.Add(("{0} candidate host(s) are already in Maintenance mode and cost no capacity to take." -f $parked.Count))
    }

    if ($connected.Count -eq 0) {
        if ($freeSlots -gt 0) {
            return [pscustomobject]@{ SafeBatchSize=$freeSlots; Reason="$freeSlots candidate host(s) already in Maintenance mode - already out of service, so no capacity needs freeing."; Diagnostics=@($diagnostics) }
        }
        return [pscustomobject]@{ SafeBatchSize=0; Reason="No connected candidate hosts."; Diagnostics=@($diagnostics) }
    }
    if ($connected.Count -eq 1) {
        $only = [Math]::Min(1 + $freeSlots, $hardCap)
        return [pscustomobject]@{ SafeBatchSize=$only; Reason="Only one connected candidate host - batch of one$(if ($freeSlots -gt 0) { ", plus $freeSlots already in Maintenance mode" })."; Diagnostics=@($diagnostics) }
    }

    $totalCpuMhz = [double](($connected | Measure-Object -Property CpuTotalMhz -Sum).Sum)
    $usedCpuMhz  = [double](($connected | Measure-Object -Property CpuUsageMhz -Sum).Sum)
    $totalMemGB  = [double](($connected | Measure-Object -Property MemoryTotalGB -Sum).Sum)
    $usedMemGB   = [double](($connected | Measure-Object -Property MemoryUsageGB -Sum).Sum)

    [void]$diagnostics.Add(("Cluster candidates: {0} connected host(s), CPU {1:N0}/{2:N0} MHz used, memory {3:N1}/{4:N1} GB used." -f $connected.Count, $usedCpuMhz, $totalCpuMhz, $usedMemGB, $totalMemGB))

    $cpuByCapacity = @($connected | Sort-Object CpuTotalMhz -Descending)
    $memByCapacity = @($connected | Sort-Object MemoryTotalGB -Descending)

    $maxByHostCount = [Math]::Min($connected.Count - 1, $hardCap)

    for ($n = $maxByHostCount; $n -ge 1; $n--) {
        $removedCpu = [double](($cpuByCapacity | Select-Object -First $n | Measure-Object -Property CpuTotalMhz -Sum).Sum)
        $removedMem = [double](($memByCapacity | Select-Object -First $n | Measure-Object -Property MemoryTotalGB -Sum).Sum)

        $remainingCpu = ($totalCpuMhz - $removedCpu) * $ResourceSafetyBuffer
        $remainingMem = ($totalMemGB - $removedMem) * $ResourceSafetyBuffer

        $cpuLimit = $remainingCpu * (1 - ([double]$MinimumCpuHeadroomPercentAfterBatch / 100))
        $memLimit = $remainingMem * (1 - ([double]$MinimumMemoryHeadroomPercentAfterBatch / 100))

        $cpuOk = ($usedCpuMhz -le $cpuLimit)
        $memOk = ($usedMemGB -le $memLimit)

        [void]$diagnostics.Add(("Batch of {0}: CPU need {1:N0} vs allowed {2:N0} MHz [{3}]; memory need {4:N1} vs allowed {5:N1} GB [{6}]." -f $n, $usedCpuMhz, $cpuLimit, $(if($cpuOk){"OK"}else{"FAIL"}), $usedMemGB, $memLimit, $(if($memOk){"OK"}else{"FAIL"})))

        if ($cpuOk -and $memOk) {
            # The TOTAL that may be out at once: what capacity allows removing now, plus what is
            # already out, never more than the ceiling.
            $total = [Math]::Min($n + $freeSlots, $hardCap)
            return [pscustomobject]@{
                SafeBatchSize = $total
                Reason        = "Largest batch leaving $MinimumCpuHeadroomPercentAfterBatch% CPU and $MinimumMemoryHeadroomPercentAfterBatch% memory headroom after a $ResourceSafetyBuffer safety buffer, capped at $hardCap (half the cluster).$(if ($freeSlots -gt 0) { " $n connected host(s) plus $freeSlots already in Maintenance mode." })"
                Diagnostics   = @($diagnostics)
            }
        }
    }

    # No connected host can be spared. Hosts already in Maintenance mode still can be - they are
    # out of service either way - so the run takes those rather than stopping on capacity.
    if ($freeSlots -gt 0) {
        return [pscustomobject]@{
            SafeBatchSize = $freeSlots
            Reason        = "No connected host can be removed within the configured headroom, but $freeSlots candidate host(s) are already in Maintenance mode and cost nothing to take."
            Diagnostics   = @($diagnostics)
        }
    }

    return [pscustomobject]@{
        SafeBatchSize = 0
        Reason        = "Even removing one host breaches the configured CPU or memory headroom."
        Diagnostics   = @($diagnostics)
    }
}

function Select-BatchMode {
    <#
    .SYNOPSIS
        Chooses between capacity-sized batches and one host at a time.

    .DESCRIPTION
        These are the only two options. In both, the run advances through the cluster
        automatically once a batch completes and the cluster reports healthy - there is no
        per-batch typed confirmation. The pre-reboot safety window remains the abort point.
    #>
    Write-Host "" -ForegroundColor Cyan
    Write-Host "Select batch mode:" -ForegroundColor Cyan
    Write-Host "  1. AUTO   - size each batch from live cluster capacity and health (never more than half the cluster)" -ForegroundColor Cyan
    Write-Host "  2. SINGLE - one host at a time" -ForegroundColor Cyan
    Write-Host "  3. Exit" -ForegroundColor Cyan
    Write-Host "Both modes then run through the whole cluster automatically, batch after batch," -ForegroundColor Yellow
    Write-Host "pausing only for the pre-reboot safety window, or a host profile that is not" -ForegroundColor Yellow
    Write-Host "compliant. Host profile compliance is the only health gate." -ForegroundColor Yellow

    $choice = Read-ChoiceExit -Message "Select batch mode" -AllowedChoices @("1","2","3") -ExitMessage "Stopped during batch mode selection."
    if ($choice -eq "3") { Stop-SafeExit -Message "Stopped during batch mode selection." }

    $mode = if ($choice -eq "2") { "SINGLE" } else { "AUTO" }
    Add-SummaryRecord -Stage "BatchMode" -Batch "" -HostName "" -Action "Select batch mode" -Result $mode -Details "Automatic progression through cluster after each healthy batch."
    return $mode
}

function Wait-VMHostProfileComplianceTask {
    <#
    .SYNOPSIS
        Waits for a host profile compliance check already running in vCenter to finish.

    .DESCRIPTION
        vCenter starts its own compliance check when a host reconnects, and Auto Deploy triggers one
        after a stateless boot. Starting a scan on top of one of those is how a pre-reboot answer
        gets read as the post-reboot one, so any in-flight check is drained first.

        Best effort by design. Get-Task is not available in every configuration and the task name
        differs across vCenter versions, so a failure here returns quietly and the run continues -
        the check-time comparison in Get-VMHostProfileComplianceState is the actual guarantee that
        the scan completed, and this only removes the most common way of provoking it.
    #>
    param([int]$TimeoutMinutes = 10)

    $endTime = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $endTime) {
        $running = @()
        try {
            $running = @(Get-Task -Status Running -ErrorAction SilentlyContinue |
                Where-Object { "$($_.Name)$($_.Description)" -match '(?i)compliance' })
        }
        catch { return }

        if ($running.Count -eq 0) { return }
        Write-Host "  Waiting for a compliance check already running in vCenter to finish ($($running.Count) task(s))..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
    }

    Write-Host "  A compliance check was still running after $TimeoutMinutes minute(s) - scanning anyway." -ForegroundColor Yellow
}

function Get-ComplianceCheckTime {
    <#
    .SYNOPSIS
        Returns when a compliance result was produced, or $null when the build does not say.

    .DESCRIPTION
        The vSphere API's ComplianceResult carries checkTime, but PowerCLI surfaces it
        inconsistently: some builds project it onto the result object, some leave it on
        ExtensionData only, and older ones do not expose it at all. Both are read, and
        "not exposed" is reported as $null rather than guessed.

        DISPLAY ONLY. This value must not gate whether a result is accepted. It was tried as a
        freshness check and it fails on DateTimeKind: a UTC timestamp handed back as
        Kind=Unspecified, converted again, lands hours in the past in any zone east of UTC, so
        every result looked stale and every host reported Unknown. Whether the scan ran is already
        settled by Test-VMHostProfileCompliance blocking on the check.
    #>
    param($ComplianceResult)

    if ($null -eq $ComplianceResult) { return $null }

    # Built defensively rather than as a literal list: Set-StrictMode -Version Latest turns a
    # reference to an absent ExtensionData property into a terminating error, and PowerCLI builds
    # that do not project it are exactly the case this function exists to handle.
    $candidates = @($ComplianceResult)
    try {
        if ($ComplianceResult.PSObject.Properties.Name -contains 'ExtensionData' -and $null -ne $ComplianceResult.ExtensionData) {
            $candidates += $ComplianceResult.ExtensionData
        }
    }
    catch {}

    foreach ($candidate in $candidates) {
        if ($null -eq $candidate) { continue }
        foreach ($prop in @('CheckTime','checkTime')) {
            try {
                if ($candidate.PSObject.Properties.Name -contains $prop -and $null -ne $candidate.$prop) {
                    return [datetime]$candidate.$prop
                }
            }
            catch {}
        }
    }
    return $null
}

function Get-ComplianceStatusValue {
    <#
    .SYNOPSIS
        Pulls the compliance status string out of whatever shape the result came back in.

    .DESCRIPTION
        PowerCLI does not put the status in one place. Depending on the build it is
        ComplianceStatus or Status, on the result object itself or only on its ExtensionData, and
        typed as an enum on some builds and a plain string on others. Reading only the first two
        was what made a genuinely compliant host report Unknown.

        All four are read in order and the first non-empty one wins. Empty is returned rather than
        a guess, so the caller can decide what to do about it.
    #>
    param($ComplianceResult)

    if ($null -eq $ComplianceResult) { return "" }

    # Built defensively: Set-StrictMode -Version Latest makes a reference to an absent property a
    # terminating error, and absent properties are the normal case here.
    $candidates = @($ComplianceResult)
    try {
        if ($ComplianceResult.PSObject.Properties.Name -contains 'ExtensionData' -and $null -ne $ComplianceResult.ExtensionData) {
            $candidates += $ComplianceResult.ExtensionData
        }
    }
    catch {}

    foreach ($candidate in $candidates) {
        if ($null -eq $candidate) { continue }
        foreach ($prop in @('ComplianceStatus','Status')) {
            try {
                if ($candidate.PSObject.Properties.Name -contains $prop -and $null -ne $candidate.$prop) {
                    $value = [string]$candidate.$prop
                    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
                }
            }
            catch {}
        }
    }
    return ""
}

function ConvertTo-ComplianceStatus {
    <#
    .SYNOPSIS
        Normalises a raw compliance status to Compliant, NonCompliant or Unknown.

    .DESCRIPTION
        The vSphere API defines exactly three values - compliant, nonCompliant, unknown - but they
        arrive with different casing and, from an enum, sometimes with separators. Casing, spaces,
        hyphens and underscores are all ignored so that "nonCompliant", "Non-Compliant" and
        "NON COMPLIANT" are one status rather than three.

        Anything unrecognised is returned as-is rather than mapped to Compliant. An unfamiliar
        status must never become a pass by accident.
    #>
    param([string]$Raw)

    $normalised = ($Raw -replace '[\s_-]', '')
    switch -Regex ($normalised) {
        '^(?i)compliant$'    { return "Compliant" }
        '^(?i)noncompliant$' { return "NonCompliant" }
        '^(?i)unknown$'      { return "Unknown" }
        default              { if ([string]::IsNullOrWhiteSpace($Raw)) { return "Unknown" } else { return $Raw } }
    }
}

function Select-ComplianceResultForHost {
    <#
    .SYNOPSIS
        Picks the compliance result belonging to one host out of a set covering several.

    .DESCRIPTION
        Two of the routes below return results for every host attached to the profile, not just the
        one being processed. Taking the first of those would report another host's status against
        this one, so the match is explicit.

        The identifying property differs by route and PowerCLI build - VMHost, VMHostId, or an
        Entity managed object reference on ExtensionData - so all of them are tried. A single result
        with nothing to match on is accepted, because a route that returns exactly one row for a
        query scoped to one host is answering about that host.
    #>
    param(
        [AllowEmptyCollection()][array]$Results,
        [Parameter(Mandatory=$true)]$VMHostObject
    )

    $rows = @($Results | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { return $null }

    $hostName = [string]$VMHostObject.Name
    $hostId = ""
    try { $hostId = [string]$VMHostObject.Id } catch {}
    $hostMoRef = ""
    try { $hostMoRef = [string]$VMHostObject.ExtensionData.MoRef.Value } catch {}

    foreach ($row in $rows) {
        foreach ($candidate in @(
            { [string]$row.VMHost.Name }
            { [string]$row.VMHost }
            { [string]$row.VMHostId }
            { [string]$row.Entity.Value }
            { [string]$row.ExtensionData.Entity.Value }
        )) {
            $value = ""
            try { $value = & $candidate } catch { continue }
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if ($value -eq $hostName -or $value -eq $hostId -or ($hostMoRef -and $value -eq $hostMoRef)) { return $row }
            # An FQDN on one side and a short name on the other still identify the same host.
            if ($hostName -and ($value.Split('.')[0] -eq $hostName.Split('.')[0]) -and $value -match '^[A-Za-z]') { return $row }
        }
    }

    if ($rows.Count -eq 1) { return $rows[0] }
    return $null
}

function Get-ComplianceStatusFromComplianceManager {
    <#
    .SYNOPSIS
        Reads the compliance status vCenter holds, straight from the ProfileComplianceManager.

    .DESCRIPTION
        This is the same source the vSphere Client reads for the host's Host Profile tab, so when
        the client shows Compliant and the cmdlet shows nothing, this is what settles it.
        QueryComplianceStatus returns the stored result rather than starting a check - which is
        exactly what is wanted here, because a real scan has already been issued by the time this
        route is reached.

        Everything is probed before it is used. Get-View, the ComplianceManager reference, the
        method itself and the managed object references can all be absent or shaped differently
        across versions, and this is a fallback: it must return empty and let the next route try,
        never take the run down with it.
    #>
    param(
        [Parameter(Mandatory=$true)]$VMHostObject,
        $ProfileObject
    )

    $entityRefs = @()
    try { if ($null -ne $VMHostObject.ExtensionData.MoRef) { $entityRefs = @($VMHostObject.ExtensionData.MoRef) } } catch {}
    if ($entityRefs.Count -eq 0) { return @() }

    $profileRefs = $null
    try { if ($null -ne $ProfileObject -and $null -ne $ProfileObject.ExtensionData.MoRef) { $profileRefs = @($ProfileObject.ExtensionData.MoRef) } } catch {}

    $manager = $null
    try {
        $serviceInstance = Get-View ServiceInstance -ErrorAction Stop
        $managerRef = $serviceInstance.Content.ComplianceManager
        if ($null -eq $managerRef) { return @() }
        $manager = Get-View -Id $managerRef -ErrorAction Stop
    }
    catch { return @() }

    if ($null -eq $manager) { return @() }
    if (-not (@($manager | Get-Member -Name 'QueryComplianceStatus' -MemberType Method,ScriptMethod -ErrorAction SilentlyContinue).Count)) { return @() }

    try { return @($manager.QueryComplianceStatus($profileRefs, $entityRefs)) } catch { return @() }
}

function Get-VMHostProfileComplianceState {
    <#
    .SYNOPSIS
        Establishes a host's profile compliance status, trying every route vCenter offers.

    .DESCRIPTION
        Status is one of Compliant, NonCompliant, NoProfile or Unknown.

        Test-VMHostProfileCompliance -VMHost is the obvious call and usually the right one, but on
        a live run against an Auto Deploy host in Maintenance mode it returned NOTHING - no error,
        no result - and every host reported Unknown while the vSphere Client showed them compliant.
        So it is no longer the only route. Four are tried, in this order, stopping at the first that
        yields a usable status:

          1. Test-VMHostProfileCompliance -VMHost. A real check: -UseCache is not passed, so the
             cmdlet performs the scan and blocks until vCenter finishes it.
          2. The ProfileComplianceManager's QueryComplianceStatus, via Get-View. This is the source
             the vSphere Client reads, so it is the authority on what vCenter actually holds. It
             reads rather than scans, which is correct here - route 1 has already asked for a scan.
          3. Test-VMHostProfileCompliance -UseCache, PowerCLI's own read of the stored result.
          4. Test-VMHostProfileCompliance -Profile. A real check, across every host attached to the
             profile. Last because it is the expensive one, and its results are filtered back down
             to this host.

        Any check vCenter or Auto Deploy already had running is drained before route 1, so route 1
        is the scan that answers rather than colliding with one already in flight.

        Unknown means every route declined to give a status. It is handled like NonCompliant, and
        the detail names each route and what it returned, so the next run says which one to fix
        rather than repeating "no result".
    #>
    param([Parameter(Mandatory=$true)]$VMHostObject)

    $profileObj = $null
    try { $profileObj = Get-VMHostProfile -Entity $VMHostObject -ErrorAction SilentlyContinue | Select-Object -First 1 } catch {}

    if ($null -eq $profileObj) {
        return [pscustomobject]@{ Status="NoProfile"; ProfileName=""; Details="No host profile is attached to this host."; CheckTime=$null }
    }

    # Drain anything vCenter or Auto Deploy started, so route 1 is the scan that answers.
    Wait-VMHostProfileComplianceTask -TimeoutMinutes $HostProfileComplianceScanTimeoutMinutes

    $routes = @(
        [pscustomobject]@{
            Name   = "scan by host"
            Note   = "Running host profile compliance scan..."
            Script = { Test-VMHostProfileCompliance -VMHost $VMHostObject -ErrorAction Stop }
        }
        [pscustomobject]@{
            Name   = "compliance manager"
            Note   = "No status from the scan. Reading the status vCenter holds (ProfileComplianceManager)..."
            Script = { Get-ComplianceStatusFromComplianceManager -VMHostObject $VMHostObject -ProfileObject $profileObj }
        }
        [pscustomobject]@{
            Name   = "stored result"
            Note   = "Still no status. Reading vCenter's stored compliance result..."
            Script = { Test-VMHostProfileCompliance -VMHost $VMHostObject -UseCache -ErrorAction Stop }
        }
        [pscustomobject]@{
            Name   = "scan by profile"
            Note   = "Still no status. Scanning host profile '$($profileObj.Name)' across every host attached to it..."
            Script = { Test-VMHostProfileCompliance -Profile $profileObj -ErrorAction Stop }
        }
    )

    $result = $null
    $statusRaw = ""
    $answeredBy = ""
    $routeNotes = New-Object System.Collections.Generic.List[string]

    foreach ($route in $routes) {
        Write-Host "  $($route.Note)" -ForegroundColor Gray

        $rows = @()
        try { $rows = @(& $route.Script) }
        catch {
            [void]$routeNotes.Add("$($route.Name): failed - $($_.Exception.Message)")
            continue
        }

        $rows = @($rows | Where-Object { $null -ne $_ })
        if ($rows.Count -eq 0) {
            [void]$routeNotes.Add("$($route.Name): no result")
            continue
        }

        $row = Select-ComplianceResultForHost -Results $rows -VMHostObject $VMHostObject
        if ($null -eq $row) {
            [void]$routeNotes.Add("$($route.Name): $($rows.Count) result(s), none for this host")
            continue
        }

        $raw = Get-ComplianceStatusValue -ComplianceResult $row
        if ([string]::IsNullOrWhiteSpace($raw)) {
            [void]$routeNotes.Add("$($route.Name): result carried no status property")
            if ($null -eq $result) { $result = $row }
            continue
        }
        if ((ConvertTo-ComplianceStatus -Raw $raw) -eq "Unknown") {
            [void]$routeNotes.Add("$($route.Name): reported '$raw'")
            if ($null -eq $result) { $result = $row }
            continue
        }

        $result = $row
        $statusRaw = $raw
        $answeredBy = $route.Name
        break
    }

    $details = Get-ComplianceFailureDetail -ComplianceResult $result

    $status = ConvertTo-ComplianceStatus -Raw $statusRaw
    if ($status -eq "Unknown") {
        $details = ("vCenter gave no usable compliance status. Routes tried - $($routeNotes -join '; '). $details").Trim()
    }
    elseif ($answeredBy -ne "scan by host") {
        $details = ("Status obtained via the '$answeredBy' route; the direct scan gave nothing. $details").Trim()
    }

    return [pscustomobject]@{ Status=$status; ProfileName=$profileObj.Name; Details=$details; CheckTime=(Get-ComplianceCheckTime -ComplianceResult $result) }
}

function Get-ComplianceFailureDetail {
    <#
    .SYNOPSIS
        Summarises why a host is non-compliant, in a line an operator can act on.

    .DESCRIPTION
        The differences arrive as IncomplianceElementList on a PowerCLI result and as Failure on a
        raw ComplianceResult from the API, so both are read. Capped at five entries: the point is to
        say which setting drifted, not to reproduce the whole compliance report on the console.
    #>
    param($ComplianceResult)

    if ($null -eq $ComplianceResult) { return "" }

    try {
        if ($ComplianceResult.PSObject.Properties.Name -contains 'IncomplianceElementList' -and $null -ne $ComplianceResult.IncomplianceElementList) {
            $elements = @($ComplianceResult.IncomplianceElementList)
            if ($elements.Count -gt 0) {
                return (($elements | ForEach-Object { [string]$_ } | Select-Object -First 5) -join ' | ')
            }
        }
    }
    catch {}

    foreach ($source in @($ComplianceResult, $ComplianceResult.ExtensionData)) {
        try {
            if ($null -eq $source) { continue }
            if ($source.PSObject.Properties.Name -notcontains 'Failure' -or $null -eq $source.Failure) { continue }
            $failures = @($source.Failure)
            if ($failures.Count -eq 0) { continue }
            return (($failures | ForEach-Object {
                $text = ""
                try { if ($_.PSObject.Properties.Name -contains 'Message' -and $null -ne $_.Message) { $text = [string]$_.Message.Message } } catch {}
                if ([string]::IsNullOrWhiteSpace($text)) { try { $text = [string]$_.Expression } catch {} }
                if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$_ }
                $text
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 5) -join ' | ')
        }
        catch {}
    }

    return ""
}
function Confirm-SingleHostComplianceAndExit {
    <#
    .SYNOPSIS
        One host: verify host profile compliance, then take it out of Maintenance mode.

    .DESCRIPTION
        The per-host half of the compliance gate, split out so the rolling upgrade can advance
        hosts INDIVIDUALLY as each one comes back rather than waiting for a whole batch.

        DOES NOT SETTLE. The caller owns the settle wait, because in a rolling run each host
        settles from its own return time and those windows overlap - serialising them would cost
        the settle period once per host instead of once. Confirm-HostProfileComplianceAndExitMaintenance
        still settles once for its batch and then calls this per host, so the batch path is
        unchanged.

        Everything else is as it was: Compliant is the only status that continues on its own,
        anything else halts with C to continue, O to override, E to exit, and the exit from
        Maintenance mode is confirmed rather than assumed.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [Parameter(Mandatory=$true)][string]$BatchNumber
    )

    $hostName = $HostName

    # DRY RUN CHANGES NOTHING. This guard used to live one level up, in the batch function that
    # called this one for every host in turn. When the rolling engine replaced that function the
    # guard went with it, and DRY RUN was left running a real compliance scan and then issuing a
    # real Set-VMHost -State Connected against any host it found in Maintenance mode. Nothing else
    # in a DRY RUN touches the estate; this did.
    if (Test-DryRun) {
        Write-Host "DRY RUN: would scan '$hostName' against its host profile, then take it out of Maintenance mode if it passed." -ForegroundColor Green
        Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result "DryRun" -Details "No compliance scan issued and no Maintenance mode change made."
        return
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Host profile compliance check for '$hostName' (Batch $BatchNumber)..." -ForegroundColor Cyan

    $attempt = 0
    while ($true) {
        $attempt++
        $hostObj = Get-VMHost -Name $hostName -ErrorAction Stop
        $state = Get-VMHostProfileComplianceState -VMHostObject $hostObj

        $checkedAt = if ($state.CheckTime) { $state.CheckTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "<not reported>" }
        Write-Host ("  Host: {0}  ConnectionState: {1}  Profile: {2}  Compliance: {3}  Checked: {4}" -f $hostObj.Name, $hostObj.ConnectionState, $(if($state.ProfileName){$state.ProfileName}else{"<none>"}), $state.Status, $checkedAt) -ForegroundColor Cyan
        if (-not [string]::IsNullOrWhiteSpace($state.Details)) {
            Write-Host "  Detail: $($state.Details)" -ForegroundColor Yellow
        }

        # ANYTHING other than Compliant halts. Compliant is the only status that lets the run
        # carry on by itself - NonCompliant, Unknown and NoProfile are all "stop and have the
        # engineer look at it", because none of them is evidence that the profile applied.
        if ($state.Status -eq "Compliant") {
            if ($attempt -gt 1) {
                Write-Host "  RESOLVED: '$hostName' is now compliant with host profile '$($state.ProfileName)'." -ForegroundColor Green
            }
            Write-Host "  Compliant - continuing automatically." -ForegroundColor Green
            Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result "Compliant" -Details "Profile '$($state.ProfileName)' compliant after $attempt scan(s); checked $checkedAt. Continued automatically."
            break
        }

        # The halt. The host stays in Maintenance mode and the batch does not advance while the
        # engineer works on it - so nothing takes load against a profile that has not applied.
        Write-Host "" -ForegroundColor Red
        Write-Host "  HOST PROFILE NOT COMPLIANT - THE RUN IS PAUSED." -ForegroundColor Red
        if ($state.Status -eq "NoProfile") {
            Write-Host "  No host profile is attached to '$hostName', so compliance cannot be confirmed." -ForegroundColor Yellow
            Write-Host "  Attach the host profile in vCenter and remediate the host." -ForegroundColor Yellow
        }
        else {
            Write-Host "  '$hostName' reports '$($state.Status)' against host profile '$($state.ProfileName)'." -ForegroundColor Yellow
            Write-Host "  RESOLVE THE HOST PROFILE ISSUE MANUALLY IN vCENTER BEFORE CONTINUING:" -ForegroundColor Yellow
            Write-Host "    - Remediate the host against its profile, or re-provision it via Auto Deploy." -ForegroundColor Yellow
            Write-Host "    - Check the Security settings the pre-requisites asked you to untick -" -ForegroundColor Yellow
            Write-Host "      Authentication Configuration and Active Directory Permission are the" -ForegroundColor Yellow
            Write-Host "      usual reason a profile will not apply cleanly on a rebooted host." -ForegroundColor Yellow
        }
        Write-Host "  '$hostName' stays in Maintenance mode and this batch does not advance until you answer." -ForegroundColor Yellow
        Write-Host "    C - continue: you have resolved it. The host is re-checked, and once it reports" -ForegroundColor Yellow
        Write-Host "        Compliant it comes out of Maintenance mode and the run carries on by itself." -ForegroundColor Yellow
        Write-Host "    O - override: accept the host as it is, take it out of Maintenance mode and carry" -ForegroundColor Yellow
        Write-Host "        on. Recorded in the run summary as an override." -ForegroundColor Yellow
        Write-Host "    E - exit the run safely, leaving the host in Maintenance mode." -ForegroundColor Yellow
        $complianceChoice = Read-ChoiceExit -Message "'$hostName' is not compliant. Resolve the host profile issue, then C to continue, O to override, E to exit" -AllowedChoices @("C","O") -ExitMessage "Stopped at host profile compliance for '$hostName'."

        if ($complianceChoice -eq "O") {
            Write-Host "  OVERRIDE: '$hostName' is being returned to service without passing its host profile check." -ForegroundColor Red
            Add-ManualAttentionHost -HostName $hostName -Reason "Host profile compliance overridden" -Detail "Returned to service reporting '$($state.Status)' against profile '$($state.ProfileName)'. $($state.Details)"
            Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result "Overridden" -Details "Operator accepted '$($state.Status)' against profile '$($state.ProfileName)' after $attempt scan(s) and continued. Checked $checkedAt. $($state.Details)"
            break
        }

        Write-Host "  Re-checking '$hostName' against its host profile." -ForegroundColor Cyan
        Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result $state.Status -Details "Attempt $attempt reported '$($state.Status)'; run paused for the engineer, who chose C to continue. Re-checking."
    }

    # Only reached once the host is compliant, explicitly accepted with no profile attached, or
    # explicitly overridden by the operator.
    $hostObj = Get-VMHost -Name $hostName -ErrorAction Stop
    if (Test-VMHostObjectInMaintenance -VMHostObject $hostObj) {
        if ($Global:AutoExitMaintenanceMode) {
            Write-Host "  Taking '$hostName' out of Maintenance mode." -ForegroundColor Green
            Set-VMHost -VMHost $hostObj -State Connected -Confirm:$false -ErrorAction Stop | Out-Null

            # vCenter reports the old state for a moment after the exit is accepted. The very
            # next thing the batch loop does is a cluster health check that fails on any host in
            # Maintenance mode, so returning before the transition lands stops the run one host
            # in - which reads as "the override didn't continue".
            if (-not (Wait-VMHostOutOfMaintenance -HostName $hostName -TimeoutMinutes $ExitMaintenanceTimeoutMinutes)) {
                Add-SummaryRecord -Stage "ExitMaintenance" -Batch $BatchNumber -HostName $hostName -Action "Exit Maintenance mode" -Result "Timeout" -Details "Still in Maintenance mode $ExitMaintenanceTimeoutMinutes minute(s) after the exit was sent."
                Stop-WithMessage "'$hostName' is still in Maintenance mode $ExitMaintenanceTimeoutMinutes minute(s) after being told to exit. Check for a stuck task or a DRS/vMotion problem in vCenter before continuing."
            }
            Add-SummaryRecord -Stage "ExitMaintenance" -Batch $BatchNumber -HostName $hostName -Action "Exit Maintenance mode" -Result "Sent" -Details "Confirmed Connected after host profile compliance was accepted."
        }
        else {
            Write-Host "  AutoExitMaintenanceMode is disabled - leaving '$hostName' in Maintenance mode." -ForegroundColor Yellow
            Add-ManualAttentionHost -HostName $hostName -Reason "Left in Maintenance mode" -Detail "AutoExitMaintenanceMode is disabled, so this run did not return the host to service. Exit Maintenance mode in vCenter."
            Add-SummaryRecord -Stage "ExitMaintenance" -Batch $BatchNumber -HostName $hostName -Action "Exit Maintenance mode" -Result "Skipped" -Details "AutoExitMaintenanceMode disabled."
        }
    }

}

function Test-VMHostObjectInMaintenance {
    <#
    .SYNOPSIS
        Is this already-fetched host object in Maintenance mode? Reads the vSphere API's own flag.

    .DESCRIPTION
        ConnectionState alone is NOT the answer, and reading it alone is what made a host that was
        sitting in Maintenance mode in vCenter poll as "still evacuating" until its timeout ran out.

        In the vSphere API these are two independent properties of HostRuntimeInfo:

          runtime.connectionState   - connected, disconnected or notResponding. There is no
                                      "maintenance" member: maintenance is not a connection state.
          runtime.inMaintenanceMode - a boolean, set once the host has ENTERED Maintenance mode and
                                      not while it is entering, and it stays set regardless of what
                                      the connection state does.

        PowerCLI folds the two into one ConnectionState property that can read Maintenance - but the
        connection value wins. vCenter calls a host NotResponding after roughly ten seconds without a
        heartbeat on UDP 902, and a host evacuating a few hundred VMs is exactly where that heartbeat
        gets missed. The host is in Maintenance mode, the vCenter UI says Maintenance Mode,
        runtime.inMaintenanceMode is $true - and PowerCLI's ConnectionState reads NotResponding, so
        an equality test against "Maintenance" is false and stays false for as long as the blip
        lasts. The same reading is wrong in both directions: it also declares a host that is still
        parked to be out of Maintenance mode.

        So the boolean is the authority. ConnectionState is only the fallback for when ExtensionData
        cannot be read at all.
    #>
    param($VMHostObject)

    if ($null -eq $VMHostObject) { return $false }

    try {
        $flag = $VMHostObject.ExtensionData.Runtime.InMaintenanceMode
        if ($null -ne $flag) { return [bool]$flag }
    }
    catch { }

    return ([string]$VMHostObject.ConnectionState -eq "Maintenance")
}

function Get-VMHostMaintenanceState {
    <#
    .SYNOPSIS
        Reads one host's Maintenance mode state, telling "not in it" apart from "could not read it".

    .DESCRIPTION
        The second half is the point. Get-VMHost -ErrorAction SilentlyContinue inside a try/catch
        returns $null both when the host is genuinely not in Maintenance mode and when the vCenter
        session has dropped, the name has stopped resolving, or the call simply failed. A poll loop
        that reads $null as "not there yet" then waits out its whole timeout without once saying it
        has been blind the entire time.

        Readable=$false is that case, kept separate so a caller can report it rather than count it
        as progress. VMHost carries the object through so a caller that needs to act on the host
        does not have to fetch it a second time.
    #>
    param([Parameter(Mandatory=$true)][string]$HostName)

    $hostObj = $null
    $detail = ""
    try { $hostObj = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue }
    catch { $detail = $_.Exception.Message }

    if ($null -eq $hostObj) {
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "vCenter returned no host for this name" }
        return [pscustomobject]@{ Readable = $false; InMaintenance = $false; ConnectionState = "Unreadable"; Detail = $detail; VMHost = $null }
    }

    return [pscustomobject]@{
        Readable        = $true
        InMaintenance   = (Test-VMHostObjectInMaintenance -VMHostObject $hostObj)
        ConnectionState = [string]$hostObj.ConnectionState
        Detail          = ""
        VMHost          = $hostObj
    }
}

function Wait-VMHostOutOfMaintenance {
    <#
    .SYNOPSIS
        Waits until vCenter reports a host as out of Maintenance mode. Returns $true if it does.

    .DESCRIPTION
        Set-VMHost -State Connected returns once vCenter has accepted the change, which is not the
        same as the host having left Maintenance mode. For a short window afterwards Get-VMHost
        still reports Maintenance, and the cluster health check that runs immediately after treats
        any host in Maintenance mode as a failure - so the run stops one host in, having actually
        succeeded.

        Returns $false on timeout rather than throwing, so the caller decides what a host that will
        not come out of Maintenance mode means.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [int]$TimeoutMinutes = 10
    )

    if (Test-DryRun) { return $true }

    $endTime = (Get-Date).AddMinutes($TimeoutMinutes)
    $announced = $false
    while ((Get-Date) -lt $endTime) {
        # Readable AND out. An unreadable host is not evidence it has left Maintenance mode, and the
        # old test - ConnectionState -ne "Maintenance" - called a host out the moment its heartbeat
        # blipped to NotResponding while it was still parked. See Test-VMHostObjectInMaintenance.
        $state = Get-VMHostMaintenanceState -HostName $HostName
        if ($state.Readable -and -not $state.InMaintenance) {
            Write-Host "  '$HostName' is out of Maintenance mode (ConnectionState: $($state.ConnectionState))." -ForegroundColor Green
            return $true
        }
        if (-not $announced) {
            Write-Host "  Waiting for '$HostName' to leave Maintenance mode..." -ForegroundColor Gray
            $announced = $true
        }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Invoke-RebootSafetyWindow {
    param([int]$TimeoutSeconds=90,[Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)
    Write-Host "`nBATCH REBOOT SAFETY CHECK: Batch $BatchNumber reboot/action starts in $TimeoutSeconds seconds." -ForegroundColor Yellow
    Write-Host "Press C to continue immediately, E to exit safely, or wait for auto-continue." -ForegroundColor Cyan
    $endTime = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $endTime) {
        $key = Read-PendingConsoleKey
        if ($key -eq "C") { return $true }
        if ($key -eq "E") { Stop-SafeExit -Message "Exited during pre-reboot safety window." }
        Start-Sleep -Milliseconds 250
    }
    return $true
}

function Wait-VMHostInMaintenance {
    <#
    .SYNOPSIS
        Waits for one host to reach Maintenance mode. Returns Entered, Overridden or Timeout.

    .DESCRIPTION
        Polls rather than holding a request open. A blocking Set-VMHost keeps one HTTP request
        alive for the whole evacuation, and PowerCLI's WebOperationTimeoutSeconds ceiling is
        shorter than a production host takes, so the request is torn down mid-evacuation and
        surfaces as "An error occurred while sending the request" with the host left partway in.

        The poll asks Test-VMHostObjectInMaintenance, not ConnectionState. Reading ConnectionState
        was the fault behind a host that WAS in Maintenance mode in vCenter reporting "still
        evacuating" for the full hour: while it evacuates it is also the busiest it will ever be on
        the management network, its heartbeat is missed, PowerCLI reports NotResponding rather than
        Maintenance, and an equality test against "Maintenance" can never come true.

        Every line of the wait now says what it is actually looking at - the connection state and
        the minutes elapsed - and a host that cannot be READ is called out as unreadable rather than
        reported as still evacuating, because those are not the same thing and only one of them is
        about the host. Waiting out a timeout blind, with the operator told the evacuation was
        progressing, is the outcome this exists to prevent.

        The operator can force past a hanging evacuation with O, and the wait watches for the key
        the whole time rather than only between polls. That exists because the alternative, when an
        evacuation will not finish, is an hour of watching a counter and then a stopped run - and
        the engineer standing in front of vCenter usually knows within a minute whether the host is
        going to arrive. It is deliberately NOT automatic: overriding leaves running VMs on a host
        that is about to be rebooted for firmware, so it is recorded as an override, the host is
        listed for manual attention, and the warning says plainly what is being accepted.

        Returns Timeout rather than throwing, so the caller decides what a host that will not
        evacuate means.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [int]$TimeoutMinutes = 60
    )

    $startTime = Get-Date
    $endTime = $startTime.AddMinutes($TimeoutMinutes)
    $blindChecks = 0
    $announced = $false
    while ((Get-Date) -lt $endTime) {
        $state = Get-VMHostMaintenanceState -HostName $HostName
        if ($state.InMaintenance) { return "Entered" }

        $elapsed = [int]((Get-Date) - $startTime).TotalMinutes
        if (-not $state.Readable) {
            $blindChecks++
            Write-Host "    cannot read '$HostName' from vCenter - $($state.Detail) - $elapsed of $TimeoutMinutes min. This is not evidence that it is still evacuating." -ForegroundColor Yellow
        }
        else {
            Write-Host "    still evacuating '$HostName' - vCenter reports $($state.ConnectionState) and inMaintenanceMode is not set - $elapsed of $TimeoutMinutes min." -ForegroundColor Gray
        }

        if (-not $announced) {
            Write-Host "    O - force past this host and carry on. Its running VMs are NOT evacuated and it is about to be rebooted." -ForegroundColor Yellow
            Write-Host "    E - exit the run safely, leaving the cluster as it is." -ForegroundColor Yellow
            $announced = $true
        }

        # The 30 second gap between polls is spent watching for the key, in quarter-second slices,
        # rather than asleep. An override the operator has to hold a key down for is not an override.
        # Counted slices, not wall-clock, so the loop is bounded even where Start-Sleep is stubbed.
        for ($slice = 0; $slice -lt 120; $slice++) {
            $key = Read-PendingConsoleKey
            if ($key -eq "O") {
                Write-Host "    OVERRIDE: continuing with '$HostName' still evacuating, at the operator's instruction." -ForegroundColor Red
                return "Overridden"
            }
            if ($key -eq "E") { Stop-SafeExit -Message "Exited while waiting for '$HostName' to enter Maintenance mode." }
            Start-Sleep -Milliseconds 250
            if ((Get-Date) -ge $endTime) { break }
        }
    }

    if ($blindChecks -gt 0) {
        Write-Host "    '$HostName' could not be read from vCenter on $blindChecks check(s) in that window, so this timeout may be a vCenter session problem rather than a host that would not evacuate." -ForegroundColor Yellow
    }
    return "Timeout"
}

function Request-EsxiRootCredential {
    <#
    .SYNOPSIS
        Asks for the ESXi root password for the cluster being worked on.

    .DESCRIPTION
        Collected when the cluster is selected, not when it is first needed - by the time it is
        needed a host is already down, already evacuated, and stopping to hunt for a password is
        the worst moment to do it.

        Used for exactly one thing: reconnecting a host that reboots and comes back DISCONNECTED
        because the password vCenter holds for it no longer works. Nothing else in the run touches
        it, it is held only in memory, and it is cleared when the cluster changes.

        Declining is allowed. The run continues without it and a disconnected host is reported for
        manual rectification instead of being reconnected automatically - which is what happened
        before this existed, so it is no worse than the old behaviour.
    #>
    param([Parameter(Mandatory=$true)][string]$ClusterName)

    if ($null -ne $Global:EsxiRootCredential) { return }
    if (Test-DryRun) {
        Write-Host "DRY RUN: would ask for the ESXi root password for '$ClusterName'." -ForegroundColor Green
        return
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "ESXi root password for '$ClusterName'" -ForegroundColor Cyan
    Write-Host "  Used only to reconnect a host that reboots and comes back Disconnected in vCenter" -ForegroundColor Gray
    Write-Host "  because the password vCenter holds for it no longer works. Held in memory for this" -ForegroundColor Gray
    Write-Host "  run only, never written to the summary or the log." -ForegroundColor Gray

    # Straight to the credential prompt - no "do you want to provide it?" step in front of it. The
    # answer is always yes, and asking first only adds a keystroke to every run. Cancelling the
    # credential dialog is the way out, and is handled below.
    try {
        $credential = Get-Credential -UserName "root" -Message "ESXi root password for hosts in cluster '$ClusterName'"
    }
    catch { $credential = $null }

    if ($null -eq $credential -or [string]::IsNullOrWhiteSpace($credential.GetNetworkCredential().Password)) {
        Write-Host "  No password entered. A host that comes back disconnected will be reported, not reconnected." -ForegroundColor Yellow
        Add-SummaryRecord -Stage "PreFlight" -Batch "" -HostName "" -Action "ESXi root credential" -Result "NotProvided" -Details "No password entered; automatic reconnect is unavailable for '$ClusterName'."
        return
    }

    $Global:EsxiRootCredential = $credential
    Write-Host "  Captured for this run." -ForegroundColor Green
    Add-SummaryRecord -Stage "PreFlight" -Batch "" -HostName "" -Action "ESXi root credential" -Result "Captured" -Details "Held in memory for '$ClusterName'; used only to reconnect a disconnected host."
}

function Request-MaintenanceModeForBatch {
    <#
    .SYNOPSIS
        Puts the batch into Maintenance mode ONE HOST AT A TIME, in cluster order.

    .DESCRIPTION
        Nothing is migrated by this script. The batch is sized from live cluster capacity and its
        hosts are then put straight into Maintenance mode; DRS moves the running VMs, once, in the
        course of doing that. An earlier version cold-migrated every powered-off and suspended VM
        off each host first - which on a large cluster took longer than the upgrade, moved data
        that had no need to move, and was undone by DRS as soon as the host came back.

        Each host is requested, then waited for, before the next is asked. Only when it has
        actually reached Maintenance mode does the run move to the host after it.

        This reverses an earlier design that requested the whole batch at once on the theory that
        DRS would exclude every one of them from placement and each VM would move once. On a live
        cluster it did not behave that way: with several hosts entering maintenance together, the
        capacity available to receive their VMs was shrinking at the same time as the VMs needed
        placing. The result was continuous migration and no host ever arriving - exactly what a
        multi-host batch is supposed to avoid. One at a time, every VM has the whole rest of the
        cluster to land on, and the host completes.

        Order is the cluster list order the batch was built in - the first hosts in the cluster
        first, working through - so the sequence is predictable and repeatable rather than
        whichever host DRS happened to finish first.

        SINGLE mode is a batch of one, so this is exactly what it already did: one request, then
        poll. Its behaviour is unchanged.

        A host that will not reach Maintenance mode within $MaintenanceValidationTimeoutMinutes
        stops the run, naming that host. The rest of the batch is left untouched rather than
        stacking a second stuck evacuation on top of the first.

    .PARAMETER HostNames
        The hosts making up the current batch, in the order they should be evacuated.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames)

    if (Test-DryRun) { Write-Host "DRY RUN: would request Maintenance mode, one at a time, for $($HostNames -join ', ')." -ForegroundColor Green; return }

    Write-Host "Entering Maintenance mode one host at a time, in cluster order: $($HostNames -join ', ')" -ForegroundColor Cyan

    $position = 0
    foreach ($hostName in $HostNames) {
        $position++
        # inMaintenanceMode, not ConnectionState. A host already parked but momentarily NotResponding
        # used to fail the "already in" test and then fail the "is it Connected" test straight after,
        # stopping the whole run over a missed heartbeat. See Test-VMHostObjectInMaintenance.
        $entry = Get-VMHostMaintenanceState -HostName $hostName
        if (-not $entry.Readable) {
            Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "Failed" -Details "vCenter could not be asked about this host: $($entry.Detail)"
            Stop-WithMessage "'$hostName' could not be read from vCenter ($($entry.Detail)), so this run cannot tell what state it is in. Check the vCenter connection and the host's presence in inventory before continuing."
        }
        $hostObj = $entry.VMHost

        if ($entry.InMaintenance) {
            Write-Host "  [$position of $($HostNames.Count)] '$hostName' is already in Maintenance mode." -ForegroundColor Green
            Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "AlreadyIn" -Details "Host was already in Maintenance mode (ConnectionState $($entry.ConnectionState))."
            continue
        }

        if ($entry.ConnectionState -ne "Connected") {
            Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "Failed" -Details "ConnectionState was $($entry.ConnectionState)."
            Stop-WithMessage "'$hostName' is $($entry.ConnectionState), not Connected, so it cannot be evacuated. Resolve in vCenter before continuing."
        }

        Write-Host "  [$position of $($HostNames.Count)] Requesting Maintenance mode for '$hostName'." -ForegroundColor Cyan
        # NO -Evacuate. That switch is evacuatePoweredOffVms: it cold-migrates every powered-off and
        # suspended VM off the host before it will enter Maintenance mode, which on a large cluster
        # is slow, moves data for no reason, and is undone by DRS the moment the host returns.
        # Powered-off and suspended VMs do not block Maintenance mode - only running ones do, and
        # DRS moves those itself in a fully automated cluster.
        #
        # -RunAsync and then poll: see Wait-VMHostInMaintenance for why a blocking call fails.
        Set-VMHost -VMHost $hostObj -State Maintenance -RunAsync -Confirm:$false -ErrorAction Stop | Out-Null

        $arrival = Wait-VMHostInMaintenance -HostName $hostName -TimeoutMinutes $MaintenanceValidationTimeoutMinutes
        if ($arrival -eq "Timeout") {
            Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "Timeout" -Details "Did not reach Maintenance mode within $MaintenanceValidationTimeoutMinutes minute(s)."
            Stop-WithMessage "'$hostName' did not reach Maintenance mode within $MaintenanceValidationTimeoutMinutes minute(s). The rest of this batch has not been touched. Check DRS, VM affinity rules, and VMs that cannot be migrated (attached media, no shared storage) in vCenter."
        }

        if ($arrival -eq "Overridden") {
            Write-Host "  [$position of $($HostNames.Count)] '$hostName' was FORCED PAST while still evacuating." -ForegroundColor Red
            Write-Host "  Anything still running on it will go down when it reboots. Move or shut those VMs down now if that is not intended." -ForegroundColor Red
            Add-ManualAttentionHost -HostName $hostName -Reason "Evacuation overridden" -Detail "The operator forced the run past this host's evacuation, so it was not confirmed empty before firmware work began. Check its VMs."
            Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "Overridden" -Details "Operator pressed O to continue with the host still evacuating."
            continue
        }

        Write-Host "  [$position of $($HostNames.Count)] '$hostName' is in Maintenance mode." -ForegroundColor Green
        Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "Entered" -Details "Evacuated and in Maintenance mode."
    }

    Write-Host "All $($HostNames.Count) host(s) in this batch are in Maintenance mode." -ForegroundColor Green
}

function Wait-BatchMaintenanceMode {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,[int]$TimeoutMinutes=60)
    if (Test-DryRun) { return @(foreach ($name in $HostNames) { Get-VMHost -Name $name -ErrorAction SilentlyContinue }) }
    $timeout = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $notReady = @($HostNames | Where-Object { -not (Get-VMHostMaintenanceState -HostName $_).InMaintenance })
        if ($notReady.Count -eq 0) { return @(foreach ($name in $HostNames) { Get-VMHost -Name $name }) }
        Write-Host "Waiting for Maintenance mode. Not ready: $($notReady -join ', ')" -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    } until ((Get-Date) -gt $timeout)
    return $null
}

function Get-VMHostBootTime {
    <#
    .SYNOPSIS
        Returns a host's boot time as a string, or "" if it cannot be read.

    .DESCRIPTION
        The only honest evidence that a host actually restarted. A host that never went down still
        reports Connected, and reading connection state alone cannot tell "came back" from "never
        left" - which on a firmware run means the compliance scan and the return to service happen
        against a host still on the old firmware.
    #>
    param([Parameter(Mandatory=$true)]$VMHostObject)
    try { return [string]$VMHostObject.ExtensionData.Runtime.BootTime } catch { return "" }
}

function Get-RollingConcurrencyLimit {
    <#
    .SYNOPSIS
        How many hosts may be out of service AT ONCE, from live cluster capacity.

    .DESCRIPTION
        The rolling upgrade's admission control. Get-CapacityBasedBatchSize already answers exactly
        this question: it sizes from the CONNECTED hosts' live CPU and memory - which already carry
        the load of anything evacuated - and adds the hosts already in Maintenance mode on top,
        because those cost nothing further to have out. The number it returns is therefore the total
        that may be out simultaneously, not an increment.

        Read against the WHOLE cluster, not just the hosts still waiting. Sizing from the remaining
        candidates alone understates capacity as the run progresses: a host finished an hour ago is
        carrying load and contributing capacity, and leaving it out of the arithmetic makes the
        cluster look smaller and busier than it is.

        SINGLE mode is a limit of one. That is the same thing the old batch-of-one path did, so the
        two modes are one code path with one number changed.
    #>
    param(
        [Parameter(Mandatory=$true)]$Cluster,
        [Parameter(Mandatory=$true)][string]$BatchMode
    )

    if ($BatchMode -ne "AUTO") {
        return [pscustomobject]@{ Limit = 1; Reason = "SINGLE mode - one host at a time."; Diagnostics = @() }
    }

    $live = @(Get-VMHost -Location $Cluster -ErrorAction SilentlyContinue)
    $sizing = Get-CapacityBasedBatchSize -CandidateHosts $live -Cluster $Cluster
    return [pscustomobject]@{
        Limit       = [int]$sizing.SafeBatchSize
        Reason      = $sizing.Reason
        Diagnostics = $sizing.Diagnostics
    }
}

function Invoke-RollingClusterUpgrade {
    <#
    .SYNOPSIS
        Upgrades the cluster as a ROLLING WINDOW: as each host returns healthy, the next one starts.

    .DESCRIPTION
        Replaces the discrete-batch loop. The old shape took N hosts, put them all through, and did
        not start host N+1 until the SLOWEST of the first N had finished - so a host that came back
        in twenty minutes sat idle while its neighbour took fifty. This keeps the cluster working
        the whole time instead.

        Every host is tracked independently through four stages:

          AwaitingReturn - firmware sent, waiting for it to come back into vCenter with a boot time
                           different from the baseline captured before anything was sent.
          Settling       - back in vCenter. Held for $HostProfileComplianceSettleMinutes from ITS
                           OWN return, so hosts settle in parallel rather than one after another.
          Compliance     - the host profile gate, then out of Maintenance mode. This is the only
                           stage that can prompt, and a halt here deliberately pauses everything:
                           a profile that will not apply is a reason to stop admitting more hosts.
          Done           - back in service. Its slot is released immediately.

        ADMISSION is re-evaluated on every pass against live capacity. Get-RollingConcurrencyLimit
        returns the total that may be out at once; any spare slots are filled from the front of the
        pending list, so cluster order is preserved. A slot freed by a host finishing is refilled on
        the next pass - which is the whole point.

        THE FIRMWARE PHASE DOES NOT BLOCK. The deploy and activation are sent and this loop moves
        on; the readiness signal is the host being back in vCenter, which is what the vCenter work
        actually waits on. Intersight progress is still read each pass, for the log and to catch a
        workflow that has failed rather than waiting out a ceiling for it.

        NOTHING HERE ENDS THE RUN except an explicit E, a host that cannot be evacuated, or a
        cluster with no capacity to take even one host.
    #>
    param(
        [Parameter(Mandatory=$true)]$Cluster,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$OrderedHostNames,
        [Parameter(Mandatory=$true)][string]$BatchMode
    )

    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($name in $OrderedHostNames) { [void]$pending.Add($name) }
    $inFlight = New-Object System.Collections.Generic.List[object]
    $total = $pending.Count
    $completed = 0
    $wave = 0

    $intervalSeconds = [int]$Global:IntersightPollIntervalSeconds
    if ($intervalSeconds -lt 5) { $intervalSeconds = 5 }
    # How long a single host may sit in AwaitingReturn before the operator is asked about it.
    # Floored: an unset or zeroed setting would otherwise make the ceiling 0 and put the question
    # on screen before the host has had any chance at all to come back.
    $returnCeilingMinutes = [int]$FirmwareReconnectInitialWaitMinutes + [int]$Global:IntersightActivationHoldMinutes
    if ($returnCeilingMinutes -lt 5) { $returnCeilingMinutes = 5 }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "ROLLING UPGRADE of '$($Cluster.Name)': $total host(s), $BatchMode mode." -ForegroundColor Cyan
    Write-Host "As each host comes back healthy its slot is refilled from the remaining hosts, within live capacity." -ForegroundColor Cyan

    $nextPoll = Get-Date

    while ($pending.Count -gt 0 -or $inFlight.Count -gt 0) {

        # ------------------------------------------------------------------ ADMIT
        if ($pending.Count -gt 0) {
            $sizing = Get-RollingConcurrencyLimit -Cluster $Cluster -BatchMode $BatchMode
            $room = $sizing.Limit - $inFlight.Count

            if ($sizing.Limit -lt 1 -and $inFlight.Count -eq 0) {
                $sizing.Diagnostics | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
                Add-SummaryRecord -Stage "ClusterHealth" -Batch "" -HostName "" -Action "Capacity sizing" -Result "Failed" -Details $sizing.Reason
                Stop-WithMessage "Cluster '$($Cluster.Name)' has insufficient capacity to remove even one host: $($sizing.Reason)"
            }

            if ($room -gt 0) {
                $wave++
                $admit = @($pending | Select-Object -First $room)
                foreach ($name in $admit) { [void]$pending.Remove($name) }

                $sizing.Diagnostics | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
                Write-Host "" -ForegroundColor Cyan
                Write-Host "WAVE ${wave}: starting $($admit.Count) host(s) - $($admit -join ', ')" -ForegroundColor Cyan
                Write-Host "  Capacity allows $($sizing.Limit) host(s) out at once; $($inFlight.Count) already in flight. $($sizing.Reason)" -ForegroundColor DarkGray
                Add-SummaryRecord -Stage "BatchSizing" -Batch "$wave" -HostName "" -Action "Admit hosts" -Result "$($admit.Count)" -Details "Limit $($sizing.Limit), in flight $($inFlight.Count), waiting $($pending.Count). $($sizing.Reason)"

                Start-RollingHostWave -HostNames $admit -Wave $wave

                foreach ($name in $admit) {
                    [void]$inFlight.Add([pscustomobject]@{
                        Host = $name; Wave = "$wave"; Stage = "AwaitingReturn"
                        StartedAt = Get-Date; ReturnedAt = $null; Announced = ""
                        DisconnectedSince = $null; ReconnectAttempts = 0; NextReconnectAt = $null
                        ReconnectGiveUpAsked = $false
                    })
                }

                # DRY RUN never reboots anything, so nothing will ever "come back". Take these
                # straight to the gate, which reports its own intent and changes nothing.
                if (Test-DryRun) {
                    foreach ($tracker in $inFlight.ToArray()) { $tracker.Stage = "Compliance" }
                }
            }
        }

        # ---------------------------------------------------------------- ADVANCE
        foreach ($tracker in $inFlight.ToArray()) {

            if ($tracker.Stage -eq "AwaitingReturn") {
                if (Test-VMHostRejoinedAfterReboot -HostName $tracker.Host) {
                    $tracker.Stage = "Settling"
                    $tracker.ReturnedAt = Get-Date
                    Write-Host "  '$($tracker.Host)' is back in vCenter. Settling $HostProfileComplianceSettleMinutes minute(s) before its compliance scan." -ForegroundColor Green
                    Add-SummaryRecord -Stage "Reconnect" -Batch $tracker.Wave -HostName $tracker.Host -Action "Confirm host returned" -Result "Returned" -Details "Back in vCenter with a changed boot time."
                }
                elseif (Test-VMHostDisconnected -HostName $tracker.Host) {
                    # The host is in inventory but vCenter has dropped it. Left alone this never
                    # resolves - vCenter cannot reconnect a host whose password it no longer knows -
                    # so the run would wait out its whole window for nothing.
                    if ($null -eq $tracker.DisconnectedSince) {
                        $tracker.DisconnectedSince = Get-Date
                        Write-Host "  '$($tracker.Host)' is Disconnected in vCenter. Allowing $HostReconnectAfterDisconnectMinutes minute(s) for it to settle before reconnecting it." -ForegroundColor Yellow
                        Add-SummaryRecord -Stage "Reconnect" -Batch $tracker.Wave -HostName $tracker.Host -Action "Confirm host returned" -Result "Disconnected" -Details "vCenter reports the host disconnected; waiting $HostReconnectAfterDisconnectMinutes minute(s) before using the root credential."
                    }
                    elseif ($tracker.ReconnectAttempts -lt [int]$HostReconnectMaxAttempts -and
                            ((Get-Date) - $tracker.DisconnectedSince).TotalMinutes -ge [double]$HostReconnectAfterDisconnectMinutes -and
                            ($null -eq $tracker.NextReconnectAt -or (Get-Date) -ge $tracker.NextReconnectAt)) {
                        # THREE attempts, $HostReconnectRetryPauseMinutes apart, not one. A host that
                        # has just rebooted onto new firmware routinely refuses the first reconnect -
                        # hostd is still starting, the vmk is not up yet, the certificate is being
                        # regenerated - and one attempt wrote those off as unrecoverable when the
                        # next would have taken them.
                        $tracker.ReconnectAttempts = $tracker.ReconnectAttempts + 1
                        $attemptLabel = "$($tracker.ReconnectAttempts) of $HostReconnectMaxAttempts"
                        Write-Host "  Reconnect attempt $attemptLabel for '$($tracker.Host)'." -ForegroundColor Yellow

                        $reconnected = Restore-DisconnectedVMHost -HostName $tracker.Host
                        if ($reconnected) {
                            Add-SummaryRecord -Stage "Reconnect" -Batch $tracker.Wave -HostName $tracker.Host -Action "Reconnect host" -Result "Reconnected" -Details "Reconnected with the ESXi root credential on attempt $attemptLabel. The normal checks continue from here."
                            # Deliberately not advanced by hand - the next pass runs the SAME return
                            # check as every other host, so a reconnected host earns its way through
                            # settle and compliance exactly like one that never dropped.
                            $tracker.DisconnectedSince = $null
                            $tracker.ReconnectAttempts = 0
                            $tracker.NextReconnectAt = $null
                        }
                        else {
                            $tracker.NextReconnectAt = (Get-Date).AddMinutes([double]$HostReconnectRetryPauseMinutes)
                            Add-SummaryRecord -Stage "Reconnect" -Batch $tracker.Wave -HostName $tracker.Host -Action "Reconnect host" -Result "Retrying" -Details "Attempt $attemptLabel did not bring the host back; next attempt in $HostReconnectRetryPauseMinutes minute(s)."
                            if ($tracker.ReconnectAttempts -lt [int]$HostReconnectMaxAttempts) {
                                Write-Host "  '$($tracker.Host)' did not reconnect. Trying again in $HostReconnectRetryPauseMinutes minute(s)." -ForegroundColor Yellow
                            }
                        }
                    }
                    elseif ($tracker.ReconnectAttempts -ge [int]$HostReconnectMaxAttempts -and -not $tracker.ReconnectGiveUpAsked) {
                        # Out of attempts. The operator is asked rather than the host being written
                        # off silently, because at this point somebody has to look at it.
                        $tracker.ReconnectGiveUpAsked = $true
                        Write-Host "" -ForegroundColor Red
                        Write-Host "'$($tracker.Host)' is still Disconnected in vCenter after $HostReconnectMaxAttempts reconnect attempt(s) with the ESXi root credential." -ForegroundColor Red
                        Write-Host "  MANUAL INTERVENTION IS NEEDED. Worth checking on the host, in order:" -ForegroundColor Yellow
                        Write-Host "    - it is powered on and has finished booting (KVM or CIMC console)" -ForegroundColor Gray
                        Write-Host "    - its management vmk has an address and the gateway answers" -ForegroundColor Gray
                        Write-Host "    - the root password matches the one given for this cluster" -ForegroundColor Gray
                        Write-Host "    - hostd and vpxa are running: /etc/init.d/hostd status" -ForegroundColor Gray
                        Write-Host "" -ForegroundColor Yellow
                        Write-Host "  R - retry: reconnect it again from here, once you have made a change." -ForegroundColor Yellow
                        Write-Host "  S - set aside: leave it for manual rectification and carry on with the rest." -ForegroundColor Yellow
                        Write-Host "  E - exit the run here." -ForegroundColor Yellow
                        $choice = Read-ChoiceExit -Message "'$($tracker.Host)' will not reconnect. R to retry, S to set aside and continue, E to exit" -AllowedChoices @("R","S") -ExitMessage "Stopped because '$($tracker.Host)' could not be reconnected."

                        if ($choice -eq "R") {
                            $tracker.ReconnectAttempts = 0
                            $tracker.NextReconnectAt = $null
                            $tracker.ReconnectGiveUpAsked = $false
                            $tracker.DisconnectedSince = Get-Date
                            Add-SummaryRecord -Stage "Reconnect" -Batch $tracker.Wave -HostName $tracker.Host -Action "Reconnect host" -Result "OperatorRetry" -Details "Operator asked for another $HostReconnectMaxAttempts attempt(s) after manual intervention."
                        }
                        else {
                            Add-ManualAttentionHost -HostName $tracker.Host -Reason "Disconnected in vCenter and could not be reconnected" -Detail "$HostReconnectMaxAttempts reconnect attempt(s) with the ESXi root credential, $HostReconnectRetryPauseMinutes minute(s) apart, did not bring it back. Set aside by the operator so the rest of the cluster could continue. Check the host's management network, its root password, and hostd."
                            Add-SummaryRecord -Stage "Reconnect" -Batch $tracker.Wave -HostName $tracker.Host -Action "Reconnect host" -Result "SetAside" -Details "Not reconnected after $HostReconnectMaxAttempts attempt(s); set aside by the operator and left for manual rectification."
                            [void]$inFlight.Remove($tracker)
                            $completed++
                            Write-Host "  '$($tracker.Host)' set aside. Its slot is released so the rest of the cluster continues." -ForegroundColor Yellow
                        }
                    }
                }
                elseif (((Get-Date) - $tracker.StartedAt).TotalMinutes -ge $returnCeilingMinutes) {
                    $progress = Get-RollingHostDiagnostic -HostName $tracker.Host
                    Write-Host "" -ForegroundColor Yellow
                    Write-Host "'$($tracker.Host)' has not come back after $returnCeilingMinutes minute(s). $progress" -ForegroundColor Yellow
                    Write-Host "  R - recheck: keep waiting for it." -ForegroundColor Yellow
                    Write-Host "  O - override: treat it as returned and run its host profile check now." -ForegroundColor Yellow
                    Write-Host "  E - exit the run here." -ForegroundColor Yellow
                    $choice = Read-ChoiceExit -Message "'$($tracker.Host)' has not returned. R to recheck, O to override, E to exit" -AllowedChoices @("R","O") -ExitMessage "Stopped waiting for '$($tracker.Host)' to return."
                    if ($choice -eq "O") {
                        Add-ManualAttentionHost -HostName $tracker.Host -Reason "Did not return within the expected window" -Detail "Operator overrode the return check after $returnCeilingMinutes minute(s). $progress"
                        $tracker.Stage = "Settling"; $tracker.ReturnedAt = Get-Date
                    }
                    else { $tracker.StartedAt = Get-Date }
                }
                continue
            }

            if ($tracker.Stage -eq "Settling") {
                $waited = if ($null -eq $tracker.ReturnedAt) { [double]$HostProfileComplianceSettleMinutes } else { ((Get-Date) - $tracker.ReturnedAt).TotalMinutes }
                if ($waited -ge [double]$HostProfileComplianceSettleMinutes) {
                    $tracker.Stage = "Compliance"
                    Add-SummaryRecord -Stage "HostProfileComplianceSettle" -Batch $tracker.Wave -HostName $tracker.Host -Action "Settle before compliance scan" -Result "Completed" -Details "Waited $([int]$waited) minute(s) from this host's own return before scanning."
                }
                continue
            }

            if ($tracker.Stage -eq "Compliance") {
                Confirm-SingleHostComplianceAndExit -HostName $tracker.Host -BatchNumber $tracker.Wave
                [void]$inFlight.Remove($tracker)
                $completed++
                Write-Host "  '$($tracker.Host)' complete. $completed of $total done, $($inFlight.Count) in flight, $($pending.Count) waiting." -ForegroundColor Green
                Add-SummaryRecord -Stage "RollingProgress" -Batch $tracker.Wave -HostName $tracker.Host -Action "Host complete" -Result "Completed" -Details "$completed of $total complete; $($inFlight.Count) in flight; $($pending.Count) waiting."
            }
        }

        if ($pending.Count -eq 0 -and $inFlight.Count -eq 0) { break }

        # Nothing advanced this pass. Wait, watching for E, then look again.
        $key = Read-PendingConsoleKey
        if ($key -eq "E") { Stop-SafeExit -Message "Stopped during the rolling upgrade." }

        if ((Get-Date) -ge $nextPoll) {
            $nextPoll = (Get-Date).AddSeconds($intervalSeconds)
            $awaiting = @($inFlight.ToArray() | Where-Object { $_.Stage -eq "AwaitingReturn" })
            foreach ($tracker in $awaiting) {
                $note = Get-RollingHostDiagnostic -HostName $tracker.Host
                if ($note -ne $tracker.Announced) {
                    Write-Host "    '$($tracker.Host)': $note" -ForegroundColor DarkGray
                    $tracker.Announced = $note
                }
            }
        }

        Start-Sleep -Seconds 5
    }

    Write-Host "" -ForegroundColor Green
    Write-Host "Rolling upgrade of '$($Cluster.Name)' finished: $completed of $total host(s) completed." -ForegroundColor Green
}

function Get-RollingHostDiagnostic {
    <#
    .SYNOPSIS
        A short line describing what a host in flight is currently doing. Log only.

    .DESCRIPTION
        Best effort and never throws. For an Intersight-routed host it reports the activation phase
        so a stalled workflow is visible while the run is still waiting on vCenter; for anything
        else it reports the connection state. Purely informational - no decision is made from it.
    #>
    param([Parameter(Mandatory=$true)][string]$HostName)

    try {
        if ($Global:IntersightHostMap.ContainsKey($HostName)) {
            $map = $Global:IntersightHostMap[$HostName]
            $sp = Resolve-IntersightServerProfileForHost -HostName $HostName -IntersightCsvRow $map.IntersightCsvRow
            $serverMoid = Get-IntersightAssignedServerMoid -ServerProfile $sp -ProfileMoid ([string]$sp.Moid) -Quiet
            $progress = Get-IntersightActivationProgress -ProfileMoid ([string]$sp.Moid) -ServerMoid $serverMoid -HostName $HostName
            return $progress.Phase
        }
    }
    catch { return "state not readable - $($_.Exception.Message)" }

    # UCS Manager-routed: report what UCSM is doing, so a stalled acknowledgement or an activation
    # that has not taken is visible while the run is still waiting on vCenter - the same visibility
    # an Intersight host gets.
    try {
        if ($Global:UcsHostMap.ContainsKey($HostName)) {
            $progress = Get-UcsUpgradeProgress -HostName $HostName
            $vcState = "not in vCenter inventory yet"
            try {
                $hostObj = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
                if ($null -ne $hostObj) { $vcState = "vCenter reports $($hostObj.ConnectionState)" }
            } catch {}
            return "$($progress.Phase); $vcState"
        }
    }
    catch { }

    try {
        $hostObj = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
        if ($null -eq $hostObj) { return "not in vCenter inventory yet" }
        return "vCenter reports $($hostObj.ConnectionState)"
    }
    catch { return "state not readable" }
}

function Start-RollingHostWave {
    <#
    .SYNOPSIS
        Puts a set of hosts into Maintenance mode and sends their firmware action. Does not wait.

    .DESCRIPTION
        Everything up to and including "the reboot has been asked for". The rolling loop takes it
        from there, so this must not block on the activation completing - blocking here is what
        would stop the next host being admitted, which is the entire point of the rolling shape.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,
        [Parameter(Mandatory=$true)][int]$Wave
    )

    if ($HostNames.Count -eq 0) { return }

    $Global:BatchActionsSent = 0

    # Baselines BEFORE any action, and APPENDED - earlier waves are still in flight and their
    # baselines must survive, or their return check has nothing to compare against.
    Save-BatchBootTimes -HostNames $HostNames -Append

    Request-MaintenanceModeForBatch -HostNames $HostNames
    $inMaintenance = Wait-BatchMaintenanceMode -HostNames $HostNames -TimeoutMinutes $MaintenanceValidationTimeoutMinutes
    if ($null -eq $inMaintenance) { Stop-WithMessage "Wave $Wave is not fully in Maintenance mode within timeout." }

    if ($Global:UpgradeMode -ne "ESXI_UCS_FIRMWARE") {
        # ESXi-only: the reboot comes from vCenter and nothing else is involved.
        if (-not (Test-DryRun)) {
            Invoke-RebootSafetyWindow -TimeoutSeconds 90 -HostNames $HostNames -BatchNumber "$Wave" | Out-Null
            foreach ($hostName in $HostNames) {
                $hostObj = Get-VMHost -Name $hostName -ErrorAction Stop
                Restart-VMHost -VMHost $hostObj -Confirm:$false -ErrorAction Stop | Out-Null
                $Global:BatchActionsSent++
            }
        }
        return
    }

    $ucsNames = @($HostNames | Where-Object { -not $Global:IntersightHostMap.ContainsKey($_) })
    $intersightNames = @($HostNames | Where-Object { $Global:IntersightHostMap.ContainsKey($_) })

    if ($ucsNames.Count -gt 0) { Set-UcsFirmwarePolicyForBatch -HostNames $ucsNames -BatchNumber "$Wave" }
    if (-not (Test-DryRun)) { Invoke-RebootSafetyWindow -TimeoutSeconds 90 -HostNames $HostNames -BatchNumber "$Wave" | Out-Null }
    if ($ucsNames.Count -gt 0) { Invoke-UcsPendingAckForBatch -HostNames $ucsNames -BatchNumber "$Wave" }
    if ($intersightNames.Count -gt 0) { Invoke-IntersightAcceptAndRebootImmediateForBatch -HostNames $intersightNames -BatchNumber "$Wave" -NoWait }

    if ($Global:BatchActionsSent -eq 0 -and -not (Test-DryRun)) {
        Write-Host "  No firmware action was sent for wave $Wave - nothing in it is rebooting." -ForegroundColor Yellow
        Write-Host "  Those hosts will be checked against their host profile and returned to service." -ForegroundColor Yellow
        foreach ($hostName in $HostNames) {
            if ($Global:PreRebootBootTimes.ContainsKey($hostName)) { [void]$Global:PreRebootBootTimes.Remove($hostName) }
        }
        Add-SummaryRecord -Stage "BatchAction" -Batch "$Wave" -HostName "" -Action "Send firmware action" -Result "NoneNeeded" -Details "Nothing staged for $($HostNames -join ', '); continued without prompting."
    }
}

function Save-BatchBootTimes {
    <#
    .SYNOPSIS
        Records each host's boot time before anything is asked to reboot it.

    .DESCRIPTION
        Taken immediately before the Intersight activation, so the reconnect gate afterwards has
        something to compare against and can require the host to have genuinely restarted.

        -Append keeps the baselines already recorded. The rolling upgrade needs it: earlier waves
        are still in flight, and clearing the map would leave their return checks with nothing to
        compare against - so they would read as "no baseline" and pass on presence alone, which is
        exactly the mistake the boot time exists to prevent.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,[switch]$Append)

    if (-not $Append -or $null -eq $Global:PreRebootBootTimes) { $Global:PreRebootBootTimes = @{} }
    foreach ($hostName in $HostNames) {
        try {
            $hostObj = Get-VMHost -Name $hostName -ErrorAction SilentlyContinue
            if ($null -ne $hostObj) { $Global:PreRebootBootTimes[$hostName] = Get-VMHostBootTime -VMHostObject $hostObj }
        }
        catch {}
    }
}

function Reset-ClusterScopedState {
    <#
    .SYNOPSIS
        Clears per-cluster state before starting a cluster, keeping session-level logins.

    .DESCRIPTION
        The Step 27 menu allows a second cluster in the same run. Everything keyed to hosts,
        service profiles or firmware policy belongs to the cluster just finished and must not carry
        over - a stale UcsHostMap or profile cache would map the new cluster's hosts to the previous
        cluster's service profiles.

        Deliberately NOT cleared, because they are session-level and re-establishing them is either
        impossible or the thing that breaks:

          - Intersight configuration and session. Set-IntersightConfiguration is once per process;
            re-running it for a second cluster is exactly the fault this script now avoids.
          - The Intersight BasePath, API key ID and private key path.
          - UCSM credentials and open UCSM sessions.
          - The operator's pre-flight confirmation.
    #>
    Write-Host "Clearing per-cluster state (Intersight and UCSM logins are kept for the session)." -ForegroundColor DarkGray

    $Global:UcsHostMap = @{}
    $Global:UcsServiceProfileCache = @{}
    $Global:IntersightHostMap = @{}
    $Global:IntersightProfileCache = @{}
    $Global:IntersightSkippedHosts = @{}
    $Global:ExcludedFromRunHosts = @{}
    $Global:EsxiDiscoveryCache = @{}
    $Global:BatchActionsSent = 0

    # Firmware policy is derived per UCSM domain, so the resolved map is cluster-scoped.
    $Global:UcsFirmwarePolicyByTarget = @{}
    Set-Variable -Name TargetUcsFirmwarePolicyName -Scope Script -Value ""
}

function ConvertTo-UcsBundleVersionFromPolicyName {
    <#
    .SYNOPSIS
        Derives the firmware version a host firmware package name refers to, or "" if it does not.

    .DESCRIPTION
        The package names encode the version they point at - global-602d is 6.0(2d), global-436h is
        4.3(6h) - which is the whole reason those names exist. Reading the version back out of the
        name keeps the end-state comparison honest without reintroducing a version table: the script
        still writes no bundle version anywhere, it only reads what the name already says.

        A name that does not follow the convention returns empty. Half-decoding an unfamiliar name
        would produce a comparison against a version nobody chose, which is worse than no comparison.
    #>
    param([string]$PolicyName)

    if ([string]::IsNullOrWhiteSpace($PolicyName)) { return "" }
    if ($PolicyName -match '(?i)(\d)(\d)(\d+)([a-z])$') {
        return "$($Matches[1]).$($Matches[2])($($Matches[3])$($Matches[4]))"
    }
    return ""
}

function Get-UcsRunningFirmwareVersion {
    <#
    .SYNOPSIS
        Returns the firmware version a UCS server is actually running, or "" if it cannot be read.

    .DESCRIPTION
        Read from Get-UcsFirmwareRunning under the physical server the service profile is associated
        with (PnDn), preferring the system deployment - the running image rather than the backup or
        boot-loader entries, which report different versions and would make a current server look
        wrong.

        Best effort. This is a report on work already done, so an unreadable version is reported as
        unreadable and never fails a completed cluster.
    #>
    param(
        [Parameter(Mandatory=$true)]$UcsSession,
        [Parameter(Mandatory=$true)]$ServiceProfile
    )

    $pnDn = ""
    try { $pnDn = [string]$ServiceProfile.PnDn } catch {}
    if ([string]::IsNullOrWhiteSpace($pnDn)) { return "" }

    $running = @()
    try { $running = @(Get-UcsFirmwareRunning -Ucs $UcsSession -ErrorAction SilentlyContinue | Where-Object { $_.Dn -like "$pnDn/*" }) } catch { return "" }
    if ($running.Count -eq 0) { return "" }

    foreach ($filter in @(
        { $_.Deployment -eq 'system' -and $_.Type -eq 'blade-controller' }
        { $_.Deployment -eq 'system' }
        { $true }
    )) {
        $match = @($running | Where-Object $filter | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Version) } | Select-Object -First 1)
        if ($match.Count -gt 0) { return [string]$match[0].Version }
    }
    return ""
}

function Show-ClusterFirmwareVerification {
    <#
    .SYNOPSIS
        Closing report: what each host ended up on, and whether anything is still outstanding.

    .DESCRIPTION
        Printed once the cluster is complete, before the run returns to the menu, so the change
        record does not rest on "no errors were shown". Read straight from the platforms rather
        than from the run summary - the summary says what the script did, this says what the
        infrastructure now reports.

        Per host:
          ESXi build     - against $TargetEsxiBuild.
          Intersight     - the server profile's ConfigState, and whether anything is still staged.
                           "None" in the Outstanding column is the result being looked for: the
                           deploy landed and nothing is waiting.
          UCS Manager    - the host firmware package now on the service profile, against the one
                           this run resolved for that domain, plus any acknowledgement still
                           pending against the profile.

        Every read is best effort. This runs after the work is done, so a platform that will not
        answer is reported as unreadable rather than being allowed to fail a completed cluster.
    #>
    param(
        [Parameter(Mandatory=$true)]$Cluster,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames
    )

    if ($HostNames.Count -eq 0) { return }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "=== Post-change verification: $($Cluster.Name) ===" -ForegroundColor Cyan

    if (Test-DryRun) {
        Write-Host "DRY RUN: no verification read - nothing was changed." -ForegroundColor Green
        return
    }

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($hostName in ($HostNames | Sort-Object)) {
        $esxiBuild = ""
        $connection = ""
        try {
            $hostObj = Get-VMHost -Name $hostName -ErrorAction SilentlyContinue
            if ($null -ne $hostObj) { $esxiBuild = [string]$hostObj.Build; $connection = [string]$hostObj.ConnectionState }
        }
        catch {}

        $buildResult = if ([string]::IsNullOrWhiteSpace($TargetEsxiBuild)) { "n/a" }
                       elseif ($esxiBuild -eq $TargetEsxiBuild) { "On target" }
                       else { "NOT on target" }

        $platform = "ESXi only"
        $firmware = ""
        $outstanding = ""

        if ($Global:IntersightHostMap.ContainsKey($hostName)) {
            $platform = "Intersight"
            try {
                $serverProfile = Resolve-IntersightServerProfileForHost -HostName $hostName -IntersightCsvRow $Global:IntersightHostMap[$hostName].IntersightCsvRow
                $deployState = Get-IntersightProfileDeployState -ServerProfile $serverProfile
                $firmware = "ConfigState: $($deployState.ConfigState)"
                $outstanding = if ($deployState.RequiresDeploy) { "PENDING - $($deployState.ConfigState) still staged" }
                               elseif (-not $deployState.StateKnown) { "Unreadable - ConfigState not reported" }
                               else { "None" }
            }
            catch {
                $firmware = "Unreadable"
                $outstanding = "Unreadable - $($_.Exception.Message)"
            }
        }
        elseif ($Global:UcsHostMap.ContainsKey($hostName)) {
            $platform = "UCS Manager"
            try {
                $map = $Global:UcsHostMap[$hostName]
                $ucsSession = Get-UcsSessionForTarget -UcsTarget $map.UcsTarget
                $serviceProfile = Get-UcsServiceProfile -Ucs $ucsSession -Dn $map.ServiceProfileDn -ErrorAction Stop | Select-Object -First 1
                if ($null -eq $serviceProfile) { throw "Service profile $($map.ServiceProfileDn) could not be read back." }
                $currentPolicy = Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $serviceProfile
                $expectedPolicy = if ($Global:UcsFirmwarePolicyByTarget.ContainsKey($map.UcsTarget)) { [string]$Global:UcsFirmwarePolicyByTarget[$map.UcsTarget] } else { "" }

                # End-state comparison: the version the package name refers to, against the version
                # the server reports running. Derived from the name, not from a version table - the
                # script still writes no bundle version, it only reads what the name already says.
                $expectedVersion = ConvertTo-UcsBundleVersionFromPolicyName -PolicyName $(if ($expectedPolicy) { $expectedPolicy } else { $currentPolicy })
                $runningVersion = Get-UcsRunningFirmwareVersion -UcsSession $ucsSession -ServiceProfile $serviceProfile

                $firmware = "Policy: $(if($currentPolicy){$currentPolicy}else{'<none>'}); running: $(if($runningVersion){$runningVersion}else{'unreadable'}); target: $(if($expectedVersion){$expectedVersion}else{'n/a'})"

                $stillPending = @()
                try {
                    $stillPending = @(Get-UcsLsmaintAck -Ucs $ucsSession -ErrorAction SilentlyContinue |
                        Where-Object { $_.Dn -like "$($map.ServiceProfileDn)/*" -or $_.Dn -eq "$($map.ServiceProfileDn)/ack" })
                }
                catch {}

                if ($expectedPolicy -and $currentPolicy -ne $expectedPolicy) {
                    $outstanding = "POLICY MISMATCH - expected '$expectedPolicy'"
                }
                elseif ($stillPending.Count -gt 0) {
                    $outstanding = "PENDING - acknowledgement still open"
                }
                elseif ($expectedVersion -and $runningVersion -and ($runningVersion -notlike "$expectedVersion*")) {
                    # The running version is the end state that matters. The policy can be right and
                    # acknowledged and the server still be on the old image if the activation did not
                    # take, and only this comparison would show it.
                    $outstanding = "VERSION MISMATCH - running $runningVersion, expected $expectedVersion"
                }
                elseif ($expectedVersion -and -not $runningVersion) {
                    $outstanding = "Unverified - running firmware version could not be read"
                }
                else {
                    $outstanding = "None"
                }
            }
            catch {
                $firmware = "Unreadable"
                $outstanding = "Unreadable - $($_.Exception.Message)"
            }
        }

        [void]$rows.Add([pscustomobject]@{
            Host        = $hostName
            Platform    = $platform
            Connection  = $connection
            EsxiBuild   = $esxiBuild
            EsxiResult  = $buildResult
            Firmware    = $firmware
            Outstanding = $outstanding
        })
    }

    $rows | Select-Object Host,Platform,Connection,EsxiBuild,EsxiResult,Firmware,Outstanding | Format-Table -AutoSize | Out-Host

    foreach ($row in $rows) {
        Add-SummaryRecord -Stage "PostChangeVerification" -Batch "" -HostName $row.Host -Action "Verify after change" -Result $(if ($row.Outstanding -eq "None") { "Clean" } else { "Attention" }) -Details "$($row.Platform); ESXi $($row.EsxiBuild) ($($row.EsxiResult)); $($row.Firmware); outstanding: $($row.Outstanding)"
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $path = Join-Path $RunDirectory "Post-Change-Verification-$($Cluster.Name)-$timestamp.csv"
    try {
        $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
        Write-Host "Verification exported to: $path" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to export the verification CSV: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $attention = @($rows | Where-Object { $_.Outstanding -ne "None" })
    if ($attention.Count -eq 0) {
        Write-Host "All $($rows.Count) host(s) verified: nothing outstanding on Intersight or UCS Manager." -ForegroundColor Green
    }
    else {
        Write-Host "$($attention.Count) of $($rows.Count) host(s) need attention - see the Outstanding column above." -ForegroundColor Yellow
        # Anything the platforms still report as outstanding is a manual job, so it joins the
        # rectification list rather than living only in a table that has scrolled past.
        foreach ($row in $attention) {
            Add-ManualAttentionHost -HostName $row.Host -Reason "Outstanding after the change" -Detail "$($row.Platform): $($row.Outstanding). ESXi $($row.EsxiBuild) ($($row.EsxiResult))."
        }
    }
    # ESXi build is checked per host above, but a host that never came back is worth its own line.
    foreach ($row in @($rows | Where-Object { $_.Connection -ne "Connected" -and $_.Connection -ne "" })) {
        Add-ManualAttentionHost -HostName $row.Host -Reason "Not back in service" -Detail "vCenter reports ConnectionState $($row.Connection) at the end of the run."
    }
}

function Get-UcsUpgradeProgress {
    <#
    .SYNOPSIS
        What UCS Manager is currently doing for one host. The UCSM twin of
        Get-IntersightActivationProgress.

    .DESCRIPTION
        THE PENDING ACKNOWLEDGEMENT IS THE SIGNAL. While an lsmaintAck is outstanding against the
        service profile the reboot has been asked for but not taken, and UCSM will not touch the
        blade until it clears. Once it clears, UCSM has done its part - whether the HOST is back is
        vCenter's answer, and the rolling loop already waits for that separately.

        The running firmware version is reported alongside as INFORMATION ONLY. An earlier build
        gated completion on it, comparing what the server reports against the version the policy
        name encodes. On a live domain that read 5.4(0.260050) against a policy-derived 4.3(6h) -
        different numbering schemes entirely - so the comparison could never match and every UCS
        host would have reported "activating" forever. It is shown, not trusted.

        Purely a read. Nothing here changes anything, and it never throws - it runs on the rolling
        loop's critical path, where an exception would stall every host in flight, not just this one.
    #>
    param([Parameter(Mandatory=$true)][string]$HostName)

    $result = [pscustomobject]@{ Complete = $false; Phase = "no UCS mapping for this host" }
    if (-not $Global:UcsHostMap.ContainsKey($HostName)) { return $result }

    try {
        $map = $Global:UcsHostMap[$HostName]
        $session = Get-UcsSessionForTarget -UcsTarget $map.UcsTarget
        if ($null -eq $session) { $result.Phase = "no UCS Manager session for $($map.UcsTarget)"; return $result }

        # 1. Is the acknowledgement still outstanding?
        $pendingAck = @()
        try { $pendingAck = @(Get-UcsLsmaintAck -Ucs $session -ErrorAction SilentlyContinue | Where-Object { [string]$_.Dn -like "$($map.ServiceProfileDn)/*" }) } catch {}
        if ($pendingAck.Count -gt 0) {
            $result.Phase = "UCS Manager still has a pending reboot acknowledgement on $($map.ServiceProfileDn)"
            return $result
        }

        # 2. What is it running? Reported, not used to decide - see the description above.
        $running = ""
        try {
            $sp = Resolve-UcsServiceProfileForHost -HostName $HostName -UcsTarget $map.UcsTarget
            if ($null -ne $sp) { $running = Get-UcsRunningFirmwareVersion -UcsSession $session -ServiceProfile $sp }
        }
        catch { }

        $result.Complete = $true
        $result.Phase = if ([string]::IsNullOrWhiteSpace($running)) {
            "UCS Manager has no pending acknowledgement for this profile"
        } else {
            "UCS Manager has no pending acknowledgement; the server reports firmware $running"
        }
        return $result
    }
    catch {
        $result.Phase = "UCS Manager state not readable - $($_.Exception.Message)"
        return $result
    }
}

function Remove-UcsHostsAlreadyOnTargetFirmware {
    <#
    .SYNOPSIS
        Drops UCSM-routed hosts that are already on the target firmware. The UCSM twin of
        Remove-IntersightHostsAlreadyDeployed.

    .DESCRIPTION
        A host whose service profile already carries the target host firmware package AND is already
        running the version that package name encodes has nothing to do. Batching it evacuates it,
        puts it into Maintenance mode, sets a policy that is already set, finds no pending
        acknowledgement, and eventually returns it to service - a full maintenance window spent on
        a host that was finished before the run started.

        BOTH conditions are required. The policy matching alone is not enough: a profile can carry
        the new package and still be running the old firmware, waiting for a reboot that has not
        happened. That host has real work to do and must stay in scope.

        UNREADABLE IS NEVER A SKIP. A running version that cannot be read, a service profile that
        will not resolve, a policy name that encodes no version - all of them keep the host in
        scope. Skipping on a state this script could not read is how a host silently misses an
        upgrade while the run reports the cluster complete.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$CandidateHosts)

    if ($CandidateHosts.Count -eq 0) { return @($CandidateHosts) }

    $done = New-Object System.Collections.Generic.List[object]

    foreach ($hostObj in $CandidateHosts) {
        $hostName = [string]$hostObj.Name
        # Intersight-routed hosts are not this function's business.
        if ($Global:IntersightHostMap.ContainsKey($hostName)) { continue }
        if (-not $Global:UcsHostMap.ContainsKey($hostName)) { continue }

        try {
            $map = $Global:UcsHostMap[$hostName]
            $session = Get-UcsSessionForTarget -UcsTarget $map.UcsTarget
            if ($null -eq $session) { continue }

            $targetPolicy = [string]$map.TargetPolicy
            if ([string]::IsNullOrWhiteSpace($targetPolicy)) { continue }

            $sp = Resolve-UcsServiceProfileForHost -HostName $hostName -UcsTarget $map.UcsTarget
            if ($null -eq $sp) { continue }

            # THE POLICY IS THE DECISION. Current equals target means this run has nothing to set,
            # so the host is not batched - at the operator's direction, and it is the same test the
            # Intersight path makes on ConfigState.
            $currentPolicy = Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $sp
            if ($currentPolicy -ne $targetPolicy) { continue }

            # NOTHING ELSE IS CONSULTED. The policy carries the version, so a profile already on the
            # target policy is compliant and the run moves past it.
            #
            # An earlier build also compared the RUNNING firmware version against the version the
            # policy name encodes, and warned when they differed. On a live domain that read
            # 5.4(0.260050) against a policy-derived 4.3(6h) - different numbering schemes entirely,
            # so the comparison could never match and warned on every compliant host. A check that
            # is wrong on every host is worse than no check, so it is gone rather than softened.
            [void]$done.Add([pscustomobject]@{ Host = $hostName; Policy = $currentPolicy })
        }
        catch { continue }
    }

    if ($done.Count -eq 0) { return @($CandidateHosts) }

    Write-Host "" -ForegroundColor Green
    Write-Host "$($done.Count) UCS Manager host(s) are already on the target firmware policy - compliant, nothing to do:" -ForegroundColor Green
    foreach ($row in $done.ToArray()) {
        Write-Host "  $($row.Host) - policy '$($row.Policy)' - compliant." -ForegroundColor Green
        Add-SummaryRecord -Stage "Scope" -Batch "" -HostName $row.Host -Action "Exclude from run" -Result "Compliant" -Details "Service profile already carries the target host firmware package '$($row.Policy)'."
    }
    Write-Host "They are already where this run would put them, so there is nothing to do to them." -ForegroundColor Yellow

    $doneNames = @($done.ToArray() | Select-Object -ExpandProperty Host)
    return @($CandidateHosts | Where-Object { $doneNames -notcontains $_.Name })
}

function Remove-IntersightHostsAlreadyDeployed {
    <#
    .SYNOPSIS
        Drops Intersight-managed hosts whose server profile has nothing staged.

    .DESCRIPTION
        A profile in Associated - or any state that is not one of
        $Global:IntersightActionableConfigStates - has no changes waiting to be deployed. Batching
        such a host evacuates it, puts it into Maintenance mode, waits, finds nothing to send,
        brings it back and reports success, having achieved nothing and cost a maintenance window
        slot. Only the profiles with changes pending are worth touching.

        Read once, here, before anything is evacuated - not per batch - so the operator sees the
        real scope of the run up front.

        A profile whose ConfigState cannot be READ is kept in scope. "Nothing staged" and "could
        not tell" are different answers, and dropping a host on the second one would silently leave
        it un-upgraded while the run reported a clean sweep.

    .PARAMETER CandidateHosts
        The hosts currently in scope.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$CandidateHosts)

    $intersightNames = @($CandidateHosts | Where-Object { $Global:IntersightHostMap.ContainsKey($_.Name) } | Select-Object -ExpandProperty Name)
    if ($intersightNames.Count -eq 0) { return @($CandidateHosts) }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Checking which Intersight server profiles actually have changes staged..." -ForegroundColor Cyan

    $rows = @(Get-IntersightPendingInconsistencyForBatch -HostNames $intersightNames)
    $rows | Select-Object Host,ServerProfile,ConfigState,RequiresDeploy | Format-Table -AutoSize | Out-Host

    $settled = @($rows | Where-Object { $_.StateKnown -and -not $_.RequiresDeploy })
    if ($settled.Count -eq 0) {
        Write-Host "Every Intersight-managed host has changes staged. All remain in scope." -ForegroundColor Green
        return @($CandidateHosts)
    }

    foreach ($row in $settled) {
        Add-SummaryRecord -Stage "Scope" -Batch "" -HostName $row.Host -Action "Exclude from run" -Result "AlreadyDeployed" -Details "Server profile '$($row.ServerProfile)' is $($row.ConfigState) - nothing staged to deploy."
    }

    $settledNames = @($settled | Select-Object -ExpandProperty Host)
    Write-Host "Excluding $($settled.Count) host(s) with nothing staged: $(($settledNames | Sort-Object) -join ', ')" -ForegroundColor Yellow
    Write-Host "They are already where this run would put them, so there is nothing to do to them." -ForegroundColor Yellow

    return @($CandidateHosts | Where-Object { $settledNames -notcontains $_.Name })
}

function Invoke-ClusterUpgradeWorkflow {
    param([Parameter(Mandatory=$true)]$Cluster)
    Write-Host "Selected cluster: $($Cluster.Name)" -ForegroundColor Green
    $Global:CurrentClusterName = [string]$Cluster.Name
    # Per cluster: the root password belongs to the hosts in THIS cluster, not the last one.
    $Global:EsxiRootCredential = $null
    Reset-ClusterScopedState
    Select-RunMode
    Select-UpgradeMode
    # Asked for now, while nothing is down. By the time it is needed a host is already offline and
    # evacuated, and that is the worst moment to go looking for a password.
    Request-EsxiRootCredential -ClusterName $Cluster.Name

    $allClusterHosts = @(Get-VMHost -Location $Cluster | Sort-Object Name)
    if ($allClusterHosts.Count -eq 0) { Stop-WithMessage "No hosts found in selected cluster." }

    # Hosts already in Maintenance mode are IN SCOPE, at the operator's direction, for both the
    # Intersight and the UCS Manager paths. They were previously skipped for being not-Connected,
    # which quietly left them on old firmware while the run reported the cluster complete.
    #
    # They cost no capacity to take - they are already out of service - so they are processed
    # FIRST, ahead of the connected hosts, and the batch sizing treats their slots as free.
    #
    # The consequence to be aware of: at the end of the batch they go through the same host profile
    # compliance gate as every other host and, once it passes, they are taken OUT of Maintenance
    # mode. A host parked deliberately for something unrelated will be returned to service by this
    # run. It is called out here rather than buried, so it can be stopped now if that is wrong.
    $parkedHosts = @($allClusterHosts | Where-Object { Test-VMHostObjectInMaintenance -VMHostObject $_ } | Select-Object -ExpandProperty Name)
    if ($parkedHosts.Count -gt 0) {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Host(s) already in Maintenance mode, IN SCOPE and taken first: $($parkedHosts -join ', ')" -ForegroundColor Yellow
        Write-Host "They cost no capacity to take, and they will be returned to service once they pass the" -ForegroundColor Yellow
        Write-Host "host profile compliance check - including any parked for an unrelated reason." -ForegroundColor Yellow
        Add-SummaryRecord -Stage "PreFlight" -Batch "" -HostName "" -Action "Pre-existing Maintenance mode" -Result "InScope" -Details "Taken first, no capacity cost: $($parkedHosts -join ', ')"
    }

    if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") { Build-InfrastructureHostMapping -Hosts $allClusterHosts }

    $alreadyTargetHosts = @($allClusterHosts | Where-Object { Test-VMHostOnTargetBuild -VMHostObject $_ })

    if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") {
        # Firmware-only mode must not exclude hosts just because the ESXi build is already current.
        # These hosts still need to be eligible for UCSM firmware policy staging/acknowledgement.
        # Maintenance counts as in scope - see the note above. NotResponding and Disconnected do
        # not: there is nothing to drive through vCenter on a host it cannot reach.
        $patchCandidateHosts = @($allClusterHosts | Where-Object { $_.ConnectionState -eq "Connected" -or (Test-VMHostObjectInMaintenance -VMHostObject $_) })
    }
    else {
        # ESXi-only mode should skip hosts already on the target ESXi build.
        $patchCandidateHosts = @($allClusterHosts | Where-Object { ($_.ConnectionState -eq "Connected" -or (Test-VMHostObjectInMaintenance -VMHostObject $_)) -and ($alreadyTargetHosts.Name -notcontains $_.Name) })
    }

    # Hosts set aside during discovery - unreachable, no CDP/LLDP target, or no service profile.
    # They are already recorded for the manual rectification report; here they simply leave the
    # batches, so the rest of the cluster runs.
    if ($Global:ExcludedFromRunHosts.Count -gt 0) {
        $before = $patchCandidateHosts.Count
        $patchCandidateHosts = @($patchCandidateHosts | Where-Object { -not $Global:ExcludedFromRunHosts.ContainsKey($_.Name) })
        $removed = $before - $patchCandidateHosts.Count
        if ($removed -gt 0) {
            Write-Host "Set aside $removed host(s) that could not be driven by this run: $(($Global:ExcludedFromRunHosts.Keys | Sort-Object) -join ', ')" -ForegroundColor Yellow
            Write-Host "They are listed for manual rectification when the cluster completes. Every other host continues." -ForegroundColor Yellow
        }
    }

    # Hosts excluded because Intersight is unusable must not fall through to the UCS Manager path -
    # they are Intersight-managed and have no service profile in UCSM.
    if ($Global:IntersightSkippedHosts.Count -gt 0) {
        $before = $patchCandidateHosts.Count
        $patchCandidateHosts = @($patchCandidateHosts | Where-Object { -not $Global:IntersightSkippedHosts.ContainsKey($_.Name) })
        $removed = $before - $patchCandidateHosts.Count
        if ($removed -gt 0) {
            Write-Host "Excluded $removed Intersight-managed host(s) from this run: $(($Global:IntersightSkippedHosts.Keys | Sort-Object) -join ', ')" -ForegroundColor Yellow
        }
    }

    # Only the blades with changes pending are worth a maintenance window slot.
    if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") {
        $patchCandidateHosts = @(Remove-IntersightHostsAlreadyDeployed -CandidateHosts $patchCandidateHosts)
        # Same question for the UCS Manager-routed hosts: a host already carrying the target package
        # AND already running the version it encodes has nothing to do, and batching it spends a
        # maintenance window on a host that was finished before the run started.
        $patchCandidateHosts = @(Remove-UcsHostsAlreadyOnTargetFirmware -CandidateHosts $patchCandidateHosts)
    }

    if ($patchCandidateHosts.Count -eq 0) {
        if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") {
            Stop-WithMessage "Nothing to do: every host in this cluster is already deployed, or was excluded above. No Intersight server profile has changes staged."
        }
        else {
            Stop-WithMessage "No ESXi patch candidate hosts available. Every host is either already on the target ESXi build, or is neither Connected nor in Maintenance mode."
        }
    }

    $batchMode = Select-BatchMode

    # Hosts already in Maintenance mode go first. They are already evacuated, so they consume no
    # capacity and there is nothing to wait for before acting on them. Everything after them keeps
    # the cluster order the operator asked for.
    $pendingHosts = New-Object System.Collections.ArrayList
    foreach ($hostObj in @($patchCandidateHosts | Where-Object { Test-VMHostObjectInMaintenance -VMHostObject $_ })) { [void]$pendingHosts.Add($hostObj.Name) }
    foreach ($hostObj in @($patchCandidateHosts | Where-Object { -not (Test-VMHostObjectInMaintenance -VMHostObject $_) })) { [void]$pendingHosts.Add($hostObj.Name) }
    # ROLLING, NOT BATCHED. The old loop took N hosts, put them all through, and did not start
    # host N+1 until the SLOWEST of the first N had finished - so a host back in twenty minutes sat
    # idle while its neighbour took fifty. Invoke-RollingClusterUpgrade tracks each host on its own
    # and refills its slot the moment it is back in service, within whatever live capacity allows.
    # SINGLE mode is the same engine with the limit fixed at one.
    Invoke-RollingClusterUpgrade -Cluster $Cluster -OrderedHostNames @($pendingHosts) -BatchMode $batchMode

    Show-ClusterFirmwareVerification -Cluster $Cluster -HostNames @($patchCandidateHosts | Select-Object -ExpandProperty Name)
    Show-ManualAttentionReport -ClusterName $Cluster.Name
    Add-SummaryRecord -Stage "ClusterComplete" -Batch "" -HostName "" -Action "Complete cluster" -Result "Completed" -Details $Cluster.Name
}

# -----------------------------
# Main loop including Step 27
# -----------------------------

$global:vCenter = $null
$global:vCenterConnected = $false
$continueScript = $true
try {
    Write-Host "" -ForegroundColor Cyan
    Write-Host "AutoDeploy UCSM/Intersight firmware batch controller - version $ScriptVersion" -ForegroundColor Cyan
    Write-Host "Run started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $env:COMPUTERNAME by $env:USERNAME" -ForegroundColor Cyan
    Add-SummaryRecord -Stage "RunStart" -Batch "" -HostName "" -Action "Start run" -Result "Started" -Details "Version $ScriptVersion; host $env:COMPUTERNAME; user $env:USERNAME."

    Confirm-RunPrerequisites

    while ($continueScript) {
        if (-not $global:vCenter) {
            $vCenterInput = Read-Host "Enter vCenter FQDN or IP, or press Enter to use $DefaultVCenter"
            if ($vCenterInput -eq "") { $global:vCenter = $DefaultVCenter } else { $global:vCenter = $vCenterInput }
            Connect-VCenterServer -Server $global:vCenter
        }
        $clusters = @(Get-Cluster | Sort-Object Name)
        if ($clusters.Count -eq 0) { Stop-WithMessage "No clusters found in vCenter." }
        $cluster = Select-ClusterInteractive -Clusters $clusters
        try { Invoke-ClusterUpgradeWorkflow -Cluster $cluster } catch { if ($_.Exception.Message -notin @("SAFE_EXIT","STOP_WORKFLOW")) { throw } } finally { Export-RunSummary }

        Write-Host "`nSTEP 27 - COMPLETE SCRIPT / NEXT ACTION" -ForegroundColor Cyan
        Write-Host "  1. Select another cluster in the same vCenter`n  2. Connect to a different vCenter`n  3. Exit script" -ForegroundColor Yellow
        $next = Read-ChoiceExit -Message "Select next action" -AllowedChoices @("1","2","3") -ExitMessage "Stopped at Step 27."
        if ($next -eq "1") { continue }
        if ($next -eq "2") {
            if ($global:vCenterConnected) { try { Disconnect-VIServer -Server $global:vCenter -Confirm:$false | Out-Null } catch {} }
            $global:vCenter = $null; $global:vCenterConnected = $false; continue
        }
        if ($next -eq "3") { $continueScript = $false }
    }
} catch {
    if ($_.Exception.Message -in @("SAFE_EXIT","STOP_WORKFLOW")) {
        # Already reported and recorded by Stop-SafeExit / Stop-WithMessage.
        Write-Host "`nScript stopped at a controlled checkpoint. See the messages above and the run summary." -ForegroundColor Yellow
    }
    else {
        Write-Host "`nUnhandled script error: $($_.Exception.Message)" -ForegroundColor Red
        Add-SummaryRecord -Stage "UnhandledError" -Batch "" -HostName "" -Action "Script error" -Result "Failed" -Details $_.Exception.Message
    }
} finally {
    Export-RunSummary
    try { foreach ($key in @($Global:UcsSessions.Keys)) { try { Disconnect-Ucs -Ucs $Global:UcsSessions[$key] -ErrorAction SilentlyContinue | Out-Null } catch {} } } catch {}
    # Intersight.PowerShell holds process-wide configuration rather than a session object, so there
    # is nothing to disconnect. Clear the in-memory key material instead.
    $Global:IntersightSession = $null
    $Global:IntersightApiKeyId = ""
    $Global:IntersightApiKeyFilePath = ""
    # Only if a connection was actually established - otherwise this reports a confusing
    # "Could not find VIServer" on top of whatever really went wrong.
    try { if ($global:vCenterConnected) { Disconnect-VIServer -Server $global:vCenter -Confirm:$false | Out-Null; Write-Host "Disconnected from vCenter." -ForegroundColor Green } } catch { Write-Host "Could not disconnect cleanly from vCenter." -ForegroundColor Yellow }
}
