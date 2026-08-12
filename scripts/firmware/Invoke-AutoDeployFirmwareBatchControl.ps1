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

    - Version 20.5.1. Set in $ScriptVersion below and stamped onto every row of the run summary
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
      acknowledge server reboot while triggering deploy/activate", in the SDK's own words - sent
      ALONGSIDE -Action Deploy, not instead of it:
          $a = Initialize-IntersightPolicyScheduledAction -Action 'Deploy' -ProceedOnReboot $true
          Set-IntersightServerProfile -Moid <moid> -Action Deploy -ScheduledActions @($a)
      -Action Deploy is what demonstrably starts the Deploy Firmware Policy workflow; a live run
      with only ScheduledActions produced no workflow at all.
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
      After the power action the run STANDS OFF for $Global:IntersightActivationWaitMinutes
      (default 40) and looks again, up to $Global:IntersightActivationMaxCheckIns times, rather
      than polling on a timeout - an activation takes as long as it takes.
      NONE OF THIS ENDS THE RUN. Not a server that cannot be identified, not a declined power
      action, not an activation still going when the check-ins run out. Each is announced and
      recorded and the batch carries on to the reconnect wait, which is better placed to say
      whether the host came back.
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
    - Batch mode is AUTO (sized from live cluster capacity, capped at $MaxAbsoluteBatchSize) or
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
      $HostProfileComplianceSettleMinutes (default 2) and then scans every host against its attached
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
    - Exiting Maintenance mode is confirmed, not assumed. vCenter reports the old state briefly
      after accepting the change, and the cluster health check that follows fails on any host still
      in Maintenance - which stopped the run one host in, having actually succeeded. The run now
      waits up to $ExitMaintenanceTimeoutMinutes for the transition to land.
    - Hosts already in Maintenance mode when the run started are out of scope AND excluded from the
      health assessment. They are a pre-existing condition, not something this run caused, and
      counting them would fail every batch. They are named on screen each time instead.
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
$ScriptVersion = "20.5.1"

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
$Global:AllowUcsFirmwarePolicyCreation = $true

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
#     $action = Initialize-IntersightPolicyScheduledAction -Action 'Deploy' -ProceedOnReboot $true
#     Set-IntersightServerProfile -Moid <moid> -ScheduledActions @($action)
#
# An earlier build sent this as a PolicyActionParam named RebootImmediatelyToActivate. That was the
# wrong mechanism: PolicyActionParam takes free-form strings, so the appliance accepted the Deploy,
# ignored the parameter, staged the firmware and rebooted nothing.

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

# After the power action the run stands off for this long and then looks again, rather than
# polling on a timeout. A firmware activation takes as long as it takes, and a run that treats a
# closed window as a failure is wrong more often than it is right.
$Global:IntersightActivationWaitMinutes = 40
# How many of those stand-offs before the run stops watching and carries on to the reconnect wait.
# It never ends the run - see Invoke-IntersightActivationPowerCycle.
$Global:IntersightActivationMaxCheckIns = 3
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
$Global:ModuleVersionCache = @{}
$Global:SlowModulePathReported = $false
$Global:IntersightUnusable = $false
$Global:IntersightUnusableReason = ""
$Global:IntersightSkippedHosts = @{}
$Global:EsxiDiscoveryCache = @{}

$ResourceSafetyBuffer = 0.85
$MinimumCpuHeadroomPercentAfterBatch = 10
$MinimumMemoryHeadroomPercentAfterBatch = 10
$MaxAbsoluteBatchSize = 6
$MaintenanceValidationTimeoutMinutes = 60
$EsxiOnlyReconnectInitialWaitMinutes = 15
$FirmwareReconnectInitialWaitMinutes = 40
$ReconnectRetryWindowMinutes = 5
$ReconnectCheckIntervalSeconds = 60

# A host that has just re-registered with vCenter is not settled. hostd and the profile engine are
# still starting and Auto Deploy may still be applying the answer file, so a compliance scan run in
# that window reports differences that clear themselves a minute later. Read as real they stop the
# batch and send an operator hunting a fault that is not there. Waited once per batch, after the
# reconnect gate confirms every host is back, before the first scan.
$HostProfileComplianceSettleMinutes = 2
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

$Global:RunMode = "DRYRUN"              # DRYRUN, LIVE, or STAGE_NO_ACK
$Global:UpgradeMode = "ESXI_UCS_FIRMWARE" # ESXI_ONLY or ESXI_UCS_FIRMWARE
$Global:UcsCredential = $null
$Global:UcsSessions = @{}
$Global:UcsHostMap = @{}
$Global:UcsCandidateCache = @{}
$Global:UcsServiceProfileCache = @{}
$Global:ReconnectCredential = $null
$Global:PromptForReconnectPasswordWhenNeeded = $false
$Global:AutoExitMaintenanceMode = $true
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
    $normalizedAllowed = @($AllowedChoices | ForEach-Object { $_.ToString().ToUpper() })
    do {
        $answer = (Read-Host "$Message Type one of: $($AllowedChoices -join ', '), or EXIT").Trim().ToUpper()
        if ($answer -eq "E" -and $normalizedAllowed -notcontains "E") { $answer = "EXIT" }
        if ($answer -eq "EXIT") { Stop-SafeExit -Message $ExitMessage }
    } until ($normalizedAllowed -contains $answer)
    return $answer
}

function Read-YesNoExit {
    param([Parameter(Mandatory=$true)][string]$Message,[string]$ExitMessage="Script stopped at a safe checkpoint by implementor.")
    do {
        $answer = (Read-Host "$Message Type YES, NO, or EXIT").Trim().ToUpper()
        if ($answer -eq "Y") { $answer = "YES" }
        if ($answer -eq "N") { $answer = "NO" }
        if ($answer -eq "EXIT") { Stop-SafeExit -Message $ExitMessage }
    } until ($answer -eq "YES" -or $answer -eq "NO")
    return $answer
}

function Test-DryRun { return ($Global:RunMode -eq "DRYRUN") }
function Test-StageNoAck { return ($Global:RunMode -eq "STAGE_NO_ACK") }

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

    Write-Host "" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host " REQUIREMENTS - assumed present, not verified here" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan

    Write-Host "1. PowerShell modules" -ForegroundColor Yellow
    Write-Host "     PowerShell 7 (Core) - Intersight.PowerShell is a binary module built for it." -ForegroundColor Gray
    Write-Host "     VMware PowerCLI 12.3.0 or newer." -ForegroundColor Gray
    Write-Host "     Intersight.PowerShell - ONE version, matching the appliance release." -ForegroundColor Gray
    Write-Host "     Cisco UCS PowerTool - only if a host in scope is UCS Manager-managed." -ForegroundColor Gray
    Write-Host "     Nothing is imported by this script; PowerShell auto-loads on first use." -ForegroundColor Gray

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

    Write-Host "5. Manual health checks and change gates" -ForegroundColor Yellow
    Write-Host "     Completed and accepted BEFORE starting. The run does not ask again." -ForegroundColor Gray
    Write-Host "     Everything it can check itself it checks per batch - cluster health, capacity," -ForegroundColor Gray
    Write-Host "     datastore free space, host profile compliance - and stops if any of them fail." -ForegroundColor Gray
    Write-Host "     What it cannot see is the change record: approval, window, and whatever your" -ForegroundColor Gray
    Write-Host "     process requires signed off. That is yours to have done by this point." -ForegroundColor Gray

    Write-Host "=====================================================================" -ForegroundColor Cyan

    Add-SummaryRecord -Stage "PreFlight" -Batch "" -HostName "" -Action "State requirements" -Result "Displayed" -Details "CSV=$IntersightCsvPath; CsvPresent=$(Test-Path $IntersightCsvPath); Intersight configured by the caller."
    $Global:PrerequisitesConfirmed = $true
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
    $Global:UcsCandidateCache = @{}
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

function Read-ManualUcsTargetForHost {
    param(
        [Parameter(Mandatory=$true)]$VMHostObject,
        [string]$DetectedSystemName = "",
        [string]$SuggestedUcsTarget = ""
    )

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Manual UCSM target entry selected." -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($DetectedSystemName)) {
        Write-Host "Detected FI/CDP system name: $DetectedSystemName" -ForegroundColor Yellow
    }
    if (-not [string]::IsNullOrWhiteSpace($SuggestedUcsTarget)) {
        Write-Host "Suggested UCSM target without Fabric suffix: $SuggestedUcsTarget" -ForegroundColor Yellow
    }

    $manual = Read-Host "Enter UCSM FQDN/IP for host $($VMHostObject.Name), or type EXIT"
    if ($manual.Trim().ToUpper() -eq "EXIT") { Stop-SafeExit -Message "Stopped during manual UCSM mapping." }
    $manualTarget = Remove-UcsTargetDecoration -Value $manual
    $session = Connect-UcsCached -UcsTarget $manualTarget
    if ($null -eq $session) { Stop-WithMessage "Manual UCSM login failed for $manualTarget." }

    return [pscustomobject]@{
        Host          = $VMHostObject.Name
        Vmnic         = ""
        CdpSystemName = $DetectedSystemName
        UcsTarget     = $manualTarget
        Discovery     = "MANUAL"
    }
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
        $choice = Read-ChoiceExit -Message "Try interactive Connect-Ucs '$target'?" -AllowedChoices @("YES","NO") -ExitMessage "Stopped during UCSM login."
        if ($choice -eq "YES") {
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

function Resolve-UcsTargetForHost {
    param([Parameter(Mandatory=$true)]$VMHostObject)

    $preferredRow = Get-EsxiPreferredDiscovery -VMHostObject $VMHostObject
    $preferred = @($preferredRow | Where-Object { $null -ne $_ })

    if ($preferred.Count -gt 0) {
        $systemName = $preferred[0].SystemName
        $candidate = (Get-UcsCandidateListFromSystemName -SystemName $systemName | Select-Object -First 1)
        Write-Host "Host $($VMHostObject.Name) VMNIC $($preferred[0].Vmnic) UCSM target to use is: $candidate" -ForegroundColor Cyan

        if ($Global:UcsCandidateCache.ContainsKey($candidate)) {
            return [pscustomobject]@{ Host=$VMHostObject.Name; Vmnic=$preferred[0].Vmnic; CdpSystemName=$systemName; UcsTarget=$Global:UcsCandidateCache[$candidate]; Discovery="CACHE" }
        }

        $session = Connect-UcsCached -UcsTarget $candidate
        if ($null -ne $session) {
            $Global:UcsCandidateCache[$candidate] = $candidate
            return [pscustomobject]@{ Host=$VMHostObject.Name; Vmnic=$preferred[0].Vmnic; CdpSystemName=$systemName; UcsTarget=$candidate; Discovery="AUTO" }
        }

        Write-Host "Auto UCSM login failed for discovered target '$candidate'. Manual UCSM target is required." -ForegroundColor Yellow
        $manualRow = Read-ManualUcsTargetForHost -VMHostObject $VMHostObject -DetectedSystemName $systemName -SuggestedUcsTarget $candidate
        $manualRow.Vmnic = $preferred[0].Vmnic
        return $manualRow
    }

    return (Read-ManualUcsTargetForHost -VMHostObject $VMHostObject)
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

function Get-UcsServiceProfileFirmwarePolicyName {
    param([Parameter(Mandatory=$true)]$ServiceProfile)
    foreach ($prop in @("HostFwPolicyName","HostFirmwarePackageName","OperHostFwPolicyName","SrcTemplName")) {
        if ($ServiceProfile.PSObject.Properties.Name -contains $prop) {
            $val = [string]$ServiceProfile.$prop
            if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
        }
    }
    return "UNKNOWN"
}

function Get-UcsFirmwarePolicyRows {
    param([Parameter(Mandatory=$true)]$UcsSession)

    $policies = @(Get-UcsFirmwareComputeHostPack -Ucs $UcsSession -ErrorAction SilentlyContinue)
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

        If the policy is already present in the domain it is used as-is. If it is missing and
        creation is permitted, the operator is shown exactly what would be created and must confirm;
        the package is then created at org-root so service profiles in any organisation can
        reference it. DRY RUN never creates anything.

        A created package is created by NAME ONLY. No blade or rack bundle version is set on it, so
        it takes its versions from the global firmware setting the name refers to - which is where
        they are managed. Writing bundle strings from this script would pin the package to whatever
        was current when the script was last edited, and it would then quietly disagree with that
        setting rather than follow it.

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

    $existing = @(Get-UcsFirmwarePolicyRows -UcsSession $UcsSession | Where-Object { $_.Name -eq $policyName })
    if ($existing.Count -gt 0) {
        Write-Host "  '$policyName' already exists in $UcsTarget - using it as-is." -ForegroundColor Green
        Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Resolve firmware policy" -Result "Existing" -Details "$UcsTarget - $policyName for fabric family $($fabric.Family)."
        $Global:UcsFirmwarePolicyByTarget[$UcsTarget] = $policyName
        return $policyName
    }

    Write-Host "  '$policyName' does NOT exist in $UcsTarget." -ForegroundColor Yellow

    if (Test-DryRun) {
        Write-Host "  DRY RUN: would create it as a host firmware package at org-root, by name only, using the global firmware setting for its bundle versions." -ForegroundColor Green
        Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Create firmware policy" -Result "DryRun" -Details "$UcsTarget - would create $policyName by name only; bundle versions come from the global setting."
        $Global:UcsFirmwarePolicyByTarget[$UcsTarget] = $policyName
        return $policyName
    }

    if (-not $Global:AllowUcsFirmwarePolicyCreation) {
        Stop-WithMessage "Host firmware package '$policyName' is missing from $UcsTarget and policy creation is disabled. Create it in UCSM, or set `$Global:AllowUcsFirmwarePolicyCreation to `$true."
    }

    Write-Host "  About to CREATE a host firmware package in ${UcsTarget}:" -ForegroundColor Yellow
    Write-Host "    Name          : $policyName" -ForegroundColor Yellow
    Write-Host "    Organisation  : org-root (global, referencable from any org)" -ForegroundColor Yellow
    Write-Host "    Bundle version: not set here - taken from the global firmware setting '$policyName'." -ForegroundColor Yellow
    Write-Host "  The service profiles are then pointed at this package, and everything else follows from that setting." -ForegroundColor Yellow

    $choice = Read-ChoiceExit `
        -Message "Create host firmware package '$policyName' in $UcsTarget?" `
        -AllowedChoices @("CREATE","STOP") `
        -ExitMessage "Stopped before creating a UCS host firmware package."
    if ($choice -eq "STOP") {
        Stop-WithMessage "Host firmware package '$policyName' is missing from $UcsTarget and creation was declined."
    }

    try {
        # Name and description only. Bundle versions are left unset so the package uses the global
        # firmware setting rather than a version pinned by this script.
        Add-UcsFirmwareComputeHostPack -Ucs $UcsSession -Org "org-root" -Name $policyName `
            -Descr "Created by the firmware batch controller for fabric family $($fabric.Family)." `
            -ErrorAction Stop | Out-Null
    }
    catch {
        Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Create firmware policy" -Result "Failed" -Details "$UcsTarget - $policyName - $($_.Exception.Message)"
        Stop-WithMessage "Could not create host firmware package '$policyName' in ${UcsTarget}: $($_.Exception.Message)"
    }

    # Read it back rather than trusting the create call.
    if (-not (Test-UcsFirmwarePolicyExists -PolicyName $policyName -UcsSession $UcsSession)) {
        Stop-WithMessage "Host firmware package '$policyName' was created in $UcsTarget but cannot be read back. Check it in UCSM before continuing."
    }

    Write-Host "  Created and verified '$policyName' in $UcsTarget." -ForegroundColor Green
    Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Create firmware policy" -Result "Created" -Details "$UcsTarget - $policyName created by name only for fabric family $($fabric.Family); bundle versions come from the global setting."
    $Global:UcsFirmwarePolicyByTarget[$UcsTarget] = $policyName
    return $policyName
}

function Test-UcsFirmwarePolicyExists {
    param(
        [Parameter(Mandatory=$true)][string]$PolicyName,
        [Parameter(Mandatory=$true)]$UcsSession
    )
    try {
        $policyRows = @(Get-UcsFirmwarePolicyRows -UcsSession $UcsSession)
        return (($policyRows | Where-Object { $_.Name -eq $PolicyName }).Count -gt 0)
    }
    catch {
        return $false
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

    $intersightRoutedRows = New-Object System.Collections.ArrayList
    foreach ($hostObj in $Hosts) {
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
        Write-Host "One or more hosts did not return a UCSM target from CDP/LLDP. Manual UCSM target is required for those hosts." -ForegroundColor Yellow
        foreach ($row in $missingTargets) {
            $manual = Read-Host "Enter UCSM FQDN/IP for host $($row.Host), or type EXIT"
            if ($manual.Trim().ToUpper() -eq "EXIT") { Stop-SafeExit -Message "Stopped during manual UCSM mapping." }
            $row.UcsTarget = Remove-UcsTargetDecoration -Value $manual
            $row.Discovery = "MANUAL_NO_CDP"
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
            $manualTarget = Read-Host "Enter replacement UCSM FQDN/IP for discovered target '$targetName', or type EXIT"
            if ($manualTarget.Trim().ToUpper() -eq "EXIT") { Stop-SafeExit -Message "Stopped during manual UCSM mapping." }
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
        if ($null -eq $sp) { Stop-WithMessage "Could not resolve UCS service profile for host $($row.Host) in UCSM $($row.UcsTarget)." }
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
        if (-not (Test-StageNoAck)) {
            if ($Attempt -ge $MaxAttempts) {
                Stop-WithMessage "Firmware policy verification still failing after $MaxAttempts attempts for Batch $BatchNumber. Resolve in UCSM before continuing."
            }
            $choice = Read-ChoiceExit -Message "Firmware policy verification failed for one or more hosts (attempt $Attempt of $MaxAttempts). Choose RECHECK or STOP" -AllowedChoices @("RECHECK","STOP")
            if ($choice -eq "STOP") { Stop-WithMessage "Firmware policy verification failed after set command." }
            if ($choice -eq "RECHECK") { return Set-UcsFirmwarePolicyForBatch -HostNames $HostNames -BatchNumber $BatchNumber -Attempt ($Attempt + 1) -MaxAttempts $MaxAttempts }
        }
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
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)
    $pendingRows = @(Get-UcsPendingRebootObjectsForBatch -HostNames $HostNames)
    $pendingRows | Select-Object Host,UcsTarget,ServiceProfileDn,PendingAckFound,AckDn | Format-Table -AutoSize | Out-Host
    if (Test-DryRun) { Write-Host "DRY RUN: Would acknowledge only listed current-batch UCSM pending objects." -ForegroundColor Green; return }

    # The typed ACK-BATCH-N gate that used to sit here has been removed so the run advances
    # through the cluster on its own. The abort point is now the pre-reboot safety window
    # immediately before this call, which covers the whole batch and accepts E to exit.
    Write-Host "Acknowledging UCSM pending reboot for Batch $BatchNumber ($(@($pendingRows | Where-Object { $_.PendingAckFound }).Count) host(s) with a pending activity)." -ForegroundColor Yellow
    foreach ($row in $pendingRows) {
        if (-not $row.PendingAckFound) { continue }
        $ucsSession = Get-UcsSessionForTarget -UcsTarget $row.UcsTarget
        Set-UcsLsmaintAck -Ucs $ucsSession -LsmaintAck $row.AckObject -AdminState "trigger-immediate" -Force -ErrorAction Stop | Out-Null
        $Global:BatchActionsSent++
        Add-SummaryRecord -Stage "UCSMAcknowledge" -Batch $BatchNumber -HostName $row.Host -Action "Acknowledge pending activity" -Result "Sent" -Details $row.AckDn
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
            -Message "Choose SKIP to exclude the Intersight-managed hosts and continue with the rest, or STOP" `
            -AllowedChoices @("SKIP","STOP") `
            -ExitMessage "Stopped because Intersight is unusable in this session."

        if ($choice -eq "STOP") {
            Stop-WithMessage "Intersight module cannot parse responses. Credentials are valid - align the Intersight.PowerShell version with the appliance before re-running."
        }

        foreach ($hostName in $affected) {
            $Global:IntersightSkippedHosts[$hostName] = $Global:IntersightUnusableReason
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
    param([Parameter(Mandatory=$true)][string]$Name)
    # OData string literals escape a single quote by doubling it.
    $escaped = $Name -replace "'", "''"
    $page = Get-IntersightServerProfile -Filter "Name eq '$escaped'" -ErrorAction Stop
    return (Get-IntersightResultList -Response $page | Select-Object -First 1)
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

    Write-Host "Host '$HostName' resolved to Intersight server profile '$($sp.Name)' via $resolvedBy." -ForegroundColor Cyan
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

function Confirm-IntersightDeployAccepted {
    <#
    .SYNOPSIS
        Re-reads a server profile after a Deploy. Returns $true if the appliance picked it up.

    .DESCRIPTION
        The reboot acknowledgement is sent as a PolicyActionParam whose identifier Cisco does not
        publish. A wrong identifier has two possible outcomes and only one of them is loud: the
        appliance either rejects the call - which throws, and the caller stops - or it ignores the
        parameter, accepts the Deploy, and leaves the firmware staged with nothing rebooting. The
        second is the dangerous one. The run would then sit out its whole post-reboot window
        waiting for a restart that was never scheduled, and report the batch as done.

        So the deploy is not trusted on the strength of the call returning. The profile is re-read
        until it leaves the state it was staged in - Pending-changes, Inconsistent and the rest of
        $Global:IntersightActionableConfigStates - which is the appliance confirming it has picked
        the change up. If it is still sitting there when the window closes, the run stops and names
        the setting to correct.

        This is deliberately a short window. It is checking that the deploy was ACCEPTED, not that
        the upgrade finished - the reconnect wait covers the upgrade.

    .PARAMETER Row
        The row for this host from Get-IntersightPendingInconsistencyForBatch.

    .PARAMETER BatchNumber
        The batch, for the summary record.
    #>
    param(
        [Parameter(Mandatory=$true)]$Row,
        [Parameter(Mandatory=$true)][string]$BatchNumber
    )

    $timeoutSeconds = [int]$Global:IntersightDeployAcceptedTimeoutSeconds
    if ($timeoutSeconds -le 0) { return $true }

    Write-Host "  Confirming the appliance accepted the deploy for '$($Row.ServerProfile)'..." -ForegroundColor Gray

    $endTime = (Get-Date).AddSeconds($timeoutSeconds)
    $lastState = $Row.ConfigState

    while ((Get-Date) -lt $endTime) {
        Start-Sleep -Seconds 15

        # By Moid where there is one - it identifies the profile exactly - falling back to the name
        # so a profile the mapping resolved without a Moid is still re-read rather than skipped.
        $current = $null
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$Row.ProfileMoid)) {
                # Through Get-IntersightResultList like every other query. A Moid lookup usually
                # returns the object itself rather than a page, but "usually" is what produced the
                # null-Moid bug this helper exists to prevent, and it handles both shapes.
                $current = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $Row.ProfileMoid -ErrorAction Stop) | Select-Object -First 1
            }
            else {
                $current = Get-IntersightServerProfileByName -Name $Row.ServerProfile
            }
        }
        catch { }
        if ($null -eq $current) { continue }

        $state = Get-IntersightProfileDeployState -ServerProfile $current
        if (-not $state.StateKnown) { continue }
        $lastState = $state.ConfigState

        if (-not $state.RequiresDeploy) {
            Write-Host "  Accepted - '$($Row.ServerProfile)' is now $($state.ConfigState)." -ForegroundColor Green
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $Row.Host -Action "Confirm deploy accepted" -Result "Accepted" -Details "ConfigState moved from $($Row.ConfigState) to $($state.ConfigState)."
            return $true
        }
    }

    Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $Row.Host -Action "Confirm deploy accepted" -Result "AwaitingReboot" -Details "Still $lastState after $timeoutSeconds second(s); the firmware is staged and waiting for a restart."

    Write-Host "  '$($Row.ServerProfile)' is still $lastState. The firmware is staged and waiting for a reboot." -ForegroundColor Yellow
    return $false
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
        Issues a power action against a server through Intersight. Returns $true if it was sent.

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

        NOTHING HERE THROWS. A power action that cannot be sent is reported and returns $false; the
        caller decides what to do, and by this point the firmware is already staged, so ending the
        run would leave the operator worse off than telling them plainly.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ServerMoid,
        [Parameter(Mandatory=$true)][string]$PowerState
    )

    if ($null -eq (Get-Command -Name Set-IntersightComputeServerSetting -ErrorAction SilentlyContinue)) {
        Write-Host "  Set-IntersightComputeServerSetting is not available in this Intersight.PowerShell version, so no power action can be sent." -ForegroundColor Yellow
        return $false
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
        return $true
    }
    catch {
        Write-Host "  The power action was not accepted: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Wait-IntersightActivationCheckIn {
    <#
    .SYNOPSIS
        Pauses for a fixed period, then returns so the caller can check in again.

    .DESCRIPTION
        A firmware activation takes as long as it takes. Rather than poll on a timeout and then
        declare failure, the run simply stands off for $Minutes and looks again - which is what an
        operator does, and it cannot mistake "still going" for "broken".

        Press C to check in immediately, or E to exit the run safely.
    #>
    param(
        [Parameter(Mandatory=$true)][int]$Minutes,
        [Parameter(Mandatory=$true)][string]$Label
    )

    if ($Minutes -le 0) { return }

    Write-Host "  Standing off for $Minutes minute(s) before checking $Label again. Press C to check now, E to exit." -ForegroundColor Cyan
    $endTime = (Get-Date).AddMinutes($Minutes)
    $lastAnnounced = -1
    while ((Get-Date) -lt $endTime) {
        $key = Read-PendingConsoleKey
        if ($key -eq "E") { Stop-SafeExit -Message "Stopped while waiting for firmware activation." }
        if ($key -eq "C") { Write-Host "  Checking now." -ForegroundColor Yellow; return }
        $remaining = [int][math]::Ceiling(($endTime - (Get-Date)).TotalMinutes)
        if ($remaining -ne $lastAnnounced) {
            Write-Host "    $remaining minute(s) remaining..." -ForegroundColor DarkGray
            $lastAnnounced = $remaining
        }
        Start-Sleep -Seconds 10
    }
}

function Invoke-IntersightActivationPowerCycle {
    <#
    .SYNOPSIS
        Power-cycles the blade through Intersight so staged firmware activates, then checks in.

    .DESCRIPTION
        Reached when the firmware has been staged - which works - and the appliance has not
        restarted the blade on its own. Everything here is Intersight-side: the profile says which
        server it is assigned to, and the power action goes to that server. vCenter is not involved.

        After the action the run stands off for $Global:IntersightActivationWaitMinutes and looks
        again, up to $Global:IntersightActivationMaxCheckIns times. It does not poll on a timeout
        and it does not declare failure when the window closes - a firmware activation takes as
        long as it takes, and "still going" is not "broken".

        NOTHING HERE ENDS THE RUN. Not a server that cannot be identified, not a power action the
        appliance declines, not an activation that is still running when the check-ins run out.
        Every one of those is announced and recorded, and the batch carries on to the reconnect
        wait - where the host either comes back or does not, which is the honest signal. The
        firmware is already staged by this point; ending the run would leave the operator with a
        blade in Maintenance mode and less information than they started with.
    #>
    param(
        [Parameter(Mandatory=$true)]$Row,
        [Parameter(Mandatory=$true)][string]$BatchNumber
    )

    $serverMoid = ""
    try {
        $current = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$Row.ProfileMoid)) {
            $current = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $Row.ProfileMoid -ErrorAction Stop) | Select-Object -First 1
        }
        if ($null -eq $current) { $current = $Row.ServerProfileObj }
        if ($null -ne $current) { $serverMoid = Get-IntersightAssignedServerMoid -ServerProfile $current -ProfileMoid ([string]$Row.ProfileMoid) }
    }
    catch {
        Write-Host "  Could not re-read '$($Row.ServerProfile)' to find its server: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ([string]::IsNullOrWhiteSpace($serverMoid)) {
        Write-Host "  '$($Row.ServerProfile)' has firmware staged, but the server it is assigned to could not be identified." -ForegroundColor Yellow
        Write-Host "  No power action has been sent. Reboot the blade from Intersight to activate it." -ForegroundColor Yellow
        Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $Row.Host -Action "Power action" -Result "NoServer" -Details "AssignedServer/AssociatedServer carried no Moid; firmware staged on '$($Row.ServerProfile)' remains inactive."
        return
    }

    $powerState = [string]$Global:IntersightActivationPowerAction
    $sent = Invoke-IntersightServerPowerAction -ServerMoid $serverMoid -PowerState $powerState

    if (-not $sent) {
        Write-Host "  '$($Row.ServerProfile)' still has its firmware staged and no power action was accepted." -ForegroundColor Yellow
        Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $Row.Host -Action "Power action" -Result "NotSent" -Details "$powerState was declined for server $serverMoid; firmware staged on '$($Row.ServerProfile)' remains inactive."
        return
    }

    Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $Row.Host -Action "Power action" -Result "Sent" -Details "$powerState sent to server $serverMoid to activate firmware staged on '$($Row.ServerProfile)'."

    $maxCheckIns = [math]::Max(1, [int]$Global:IntersightActivationMaxCheckIns)
    for ($checkIn = 1; $checkIn -le $maxCheckIns; $checkIn++) {
        Wait-IntersightActivationCheckIn -Minutes $Global:IntersightActivationWaitMinutes -Label "'$($Row.ServerProfile)'"

        $state = $null
        try {
            $profileNow = Get-IntersightResultList -Response (Get-IntersightServerProfile -Moid $Row.ProfileMoid -ErrorAction Stop) | Select-Object -First 1
            if ($null -ne $profileNow) { $state = Get-IntersightProfileDeployState -ServerProfile $profileNow }
        }
        catch {
            Write-Host "  Check-in $checkIn of ${maxCheckIns}: could not read the profile - $($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }

        if ($null -eq $state -or -not $state.StateKnown) {
            Write-Host "  Check-in $checkIn of ${maxCheckIns}: ConfigState not readable yet." -ForegroundColor Yellow
            continue
        }

        Write-Host "  Check-in $checkIn of ${maxCheckIns}: '$($Row.ServerProfile)' is $($state.ConfigState)." -ForegroundColor Cyan
        if (-not $state.RequiresDeploy) {
            Write-Host "  Activation complete - nothing is staged against '$($Row.ServerProfile)' any more." -ForegroundColor Green
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $Row.Host -Action "Confirm activation" -Result "Activated" -Details "ConfigState is $($state.ConfigState) after $checkIn check-in(s)."
            return
        }
    }

    # Still going, or stuck - and this run is not in a position to tell which. Say so and carry on;
    # the reconnect wait is the next thing that will find out, and it is better placed to.
    Write-Host "  '$($Row.ServerProfile)' is still staged after $maxCheckIns check-in(s)." -ForegroundColor Yellow
    Write-Host "  The power action was sent, so the activation may simply still be running. Continuing" -ForegroundColor Yellow
    Write-Host "  to the reconnect wait, which will show whether the host comes back." -ForegroundColor Yellow
    Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $Row.Host -Action "Confirm activation" -Result "StillStaged" -Details "$powerState was sent to server $serverMoid; profile still staged after $maxCheckIns check-in(s) of $($Global:IntersightActivationWaitMinutes) minute(s)."
}

function Invoke-IntersightAcceptAndRebootImmediateForBatch {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)

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
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "Warning" -Details "ConfigState unreadable on profile '$($row.ServerProfile)'."
        }
        if (-not (Test-DryRun)) {
            $choice = Read-ChoiceExit -Message "Intersight ConfigState unreadable for one or more hosts. Choose SKIP to leave them untouched and continue, or STOP" -AllowedChoices @("SKIP","STOP") -ExitMessage "Stopped on unreadable Intersight ConfigState."
            if ($choice -eq "STOP") { Stop-WithMessage "Intersight ConfigState could not be read for: $(($unknownStateRows | Select-Object -ExpandProperty Host) -join ', ')." }
        }
    }

    if (Test-DryRun) {
        foreach ($row in $pendingRows) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "DryRun" -Details "ConfigState=$($row.ConfigState)."
        }
        Write-Host "DRY RUN: Would accept the firmware-policy inconsistency and reboot immediately for this batch's Intersight-routed hosts only." -ForegroundColor Green
        return
    }

    if (Test-StageNoAck) {
        foreach ($row in $pendingRows) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "Skipped" -Details "STAGE_NO_ACK mode - no acknowledgement sent."
        }
        Write-Host "SAVE ONLY / NO ACKNOWLEDGEMENT mode selected: skipping Intersight accept/reboot for this batch." -ForegroundColor Green
        return
    }

    if (@($pendingRows | Where-Object { $_.RequiresDeploy }).Count -gt 0) {
        Assert-IntersightUpgradeCmdletSurface
    }

    foreach ($row in $pendingRows) {
        if (-not $row.RequiresDeploy) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "Skipped" -Details "ConfigState=$($row.ConfigState) - no staged changes to deploy."
            continue
        }

        Write-Host "Intersight: deploying server profile for '$($row.Host)' (profile '$($row.ServerProfile)', ConfigState $($row.ConfigState))." -ForegroundColor Yellow
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
            # -Action Deploy AND the scheduled action, together.
            #
            # -Action Deploy is what demonstrably starts the Deploy Firmware Policy workflow on the
            # appliance - a live run with it produced that workflow, and a live run with only
            # ScheduledActions did not. ProceedOnReboot is the documented acknowledgement that the
            # server may be restarted to activate. Neither has been observed to be sufficient on
            # its own against this appliance, so both are sent, and the run does not depend on
            # either: if the profile is still staged afterwards, the host is rebooted from vCenter,
            # which is the "install on next reboot" the staged firmware is waiting for.
            $deployParams = @{
                Moid        = $row.ProfileMoid
                Action      = 'Deploy'
                ErrorAction = 'Stop'
            }

            $sentDescription = "Action=Deploy"
            if ($Global:IntersightRebootImmediatelyToActivate) {
                $scheduledAction = Initialize-IntersightPolicyScheduledAction -Action 'Deploy' -ProceedOnReboot $true
                $deployParams['ScheduledActions'] = @($scheduledAction)
                $sentDescription += "; ScheduledActions: Action=Deploy, ProceedOnReboot=true"
            }
            else {
                $sentDescription += "; no reboot acknowledgement"
            }

            if ($Global:IntersightDeployActionParams.Count -gt 0) {
                $deployParams['ActionParams'] = @($Global:IntersightDeployActionParams | ForEach-Object { Initialize-IntersightPolicyActionParam -Name $_.Name -Value $_.Value })
                $sentDescription += "; ActionParams: $((($Global:IntersightDeployActionParams | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))"
            }

            Write-Host "  $sentDescription" -ForegroundColor DarkGray
            Set-IntersightServerProfile @deployParams | Out-Null

            $Global:BatchActionsSent++
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "Sent" -Details "ServerProfile=$($row.ServerProfile); ConfigState was $($row.ConfigState); $sentDescription."

            # A profile still sitting in Pending-changes is not a failed deploy. A firmware policy in
            # IMM installs on next reboot, so the firmware is staged and waiting for a restart -
            # which this run then supplies, because the host is already evacuated and in
            # Maintenance mode with nothing on it.
            if (-not (Confirm-IntersightDeployAccepted -Row $row -BatchNumber $BatchNumber)) {
                Invoke-IntersightActivationPowerCycle -Row $row -BatchNumber $BatchNumber
            }
        } catch {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Deploy server profile" -Result "Failed" -Details $_.Exception.Message
            Stop-WithMessage "Intersight server profile deploy failed for '$($row.Host)': $($_.Exception.Message)"
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
    Write-Host "`nSelect run mode:`n  1. LIVE RUN`n  2. DRY RUN / VALIDATION ONLY`n  3. SAVE ONLY / NO ACKNOWLEDGEMENT (UCSM policy save or Intersight staging - no reboot)`n  4. Exit" -ForegroundColor Cyan
    $choice = Read-ChoiceExit -Message "Select run mode" -AllowedChoices @("1","2","3","4")
    if ($choice -eq "4") { Stop-SafeExit -Message "Stopped during run mode selection." }
    if ($choice -eq "1") { $Global:RunMode = "LIVE" }
    if ($choice -eq "2") { $Global:RunMode = "DRYRUN" }
    if ($choice -eq "3") { $Global:RunMode = "STAGE_NO_ACK" }
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
    #>
    param(
        # AllowEmptyCollection so an empty candidate list returns a clean "no capacity" result
        # instead of failing parameter binding partway through the run.
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$CandidateHosts,
        [Parameter(Mandatory=$true)]$Cluster
    )

    $connected = @($CandidateHosts | Where-Object { $_.ConnectionState -eq "Connected" })
    $diagnostics = New-Object System.Collections.Generic.List[string]

    if ($connected.Count -eq 0) {
        return [pscustomobject]@{ SafeBatchSize=0; Reason="No connected candidate hosts."; Diagnostics=@($diagnostics) }
    }
    if ($connected.Count -eq 1) {
        return [pscustomobject]@{ SafeBatchSize=1; Reason="Only one connected candidate host - batch of one."; Diagnostics=@($diagnostics) }
    }

    $totalCpuMhz = [double](($connected | Measure-Object -Property CpuTotalMhz -Sum).Sum)
    $usedCpuMhz  = [double](($connected | Measure-Object -Property CpuUsageMhz -Sum).Sum)
    $totalMemGB  = [double](($connected | Measure-Object -Property MemoryTotalGB -Sum).Sum)
    $usedMemGB   = [double](($connected | Measure-Object -Property MemoryUsageGB -Sum).Sum)

    [void]$diagnostics.Add(("Cluster candidates: {0} connected host(s), CPU {1:N0}/{2:N0} MHz used, memory {3:N1}/{4:N1} GB used." -f $connected.Count, $usedCpuMhz, $totalCpuMhz, $usedMemGB, $totalMemGB))

    $cpuByCapacity = @($connected | Sort-Object CpuTotalMhz -Descending)
    $memByCapacity = @($connected | Sort-Object MemoryTotalGB -Descending)

    $maxByHostCount = [Math]::Min($connected.Count - 1, [int]$MaxAbsoluteBatchSize)

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
            return [pscustomobject]@{
                SafeBatchSize = $n
                Reason        = "Largest batch leaving $MinimumCpuHeadroomPercentAfterBatch% CPU and $MinimumMemoryHeadroomPercentAfterBatch% memory headroom after a $ResourceSafetyBuffer safety buffer, capped at $MaxAbsoluteBatchSize."
                Diagnostics   = @($diagnostics)
            }
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
    Write-Host "  1. AUTO   - size each batch from live cluster capacity and health (never more than $MaxAbsoluteBatchSize hosts)" -ForegroundColor Cyan
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

function Wait-HostProfileComplianceSettle {
    <#
    .SYNOPSIS
        Pauses after a batch is confirmed back in vCenter, before the first host profile compliance scan.

    .DESCRIPTION
        A host that has just re-registered is not settled. hostd and the profile engine are still
        starting, and on a stateless host Auto Deploy may still be applying the answer file. A scan
        run in that window reports differences that resolve themselves shortly after; taken as real
        they stop the batch and send an operator looking for a fault that is not there.

        Waited once per batch rather than once per host - every host in the batch came back through
        the same reconnect gate, so one settle covers all of them and a per-host wait would add
        dead time per host for nothing. Press C to scan now, E to exit.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,
        [Parameter(Mandatory=$true)][string]$BatchNumber
    )

    $minutes = $HostProfileComplianceSettleMinutes
    if ($minutes -le 0) { return }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Batch $BatchNumber is back in vCenter. Waiting $minutes minute(s) for the host(s) to settle before the compliance scan." -ForegroundColor Cyan
    Write-Host "  Hosts: $($HostNames -join ', ')" -ForegroundColor Gray
    Write-Host "  Press C to scan now, E to exit." -ForegroundColor Cyan

    $endTime = (Get-Date).AddMinutes($minutes)
    $lastAnnounced = -1
    while ((Get-Date) -lt $endTime) {
        $key = Read-PendingConsoleKey
        if ($key -eq "E") { Stop-SafeExit -Message "Stopped during the host profile compliance settle wait." }
        if ($key -eq "C") {
            Write-Host "  Settle wait ended early by the operator." -ForegroundColor Yellow
            Add-SummaryRecord -Stage "HostProfileComplianceSettle" -Batch $BatchNumber -HostName "" -Action "Settle wait" -Result "Skipped" -Details "Operator scanned before the $minutes minute settle elapsed."
            return
        }
        $remaining = [int][math]::Ceiling(($endTime - (Get-Date)).TotalSeconds)
        if ($remaining -ne $lastAnnounced -and ($remaining % 30) -eq 0) {
            Write-Host "  $remaining second(s) remaining..." -ForegroundColor Gray
            $lastAnnounced = $remaining
        }
        Start-Sleep -Seconds 1
    }

    Add-SummaryRecord -Stage "HostProfileComplianceSettle" -Batch $BatchNumber -HostName "" -Action "Settle wait" -Result "Completed" -Details "Waited $minutes minute(s) after reconnect before scanning compliance."
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
function Confirm-HostProfileComplianceAndExitMaintenance {
    <#
    .SYNOPSIS
        Per host: verify host profile compliance, then take the host out of Maintenance mode.

    .DESCRIPTION
        Runs once the batch is confirmed back in vCenter, and waits
        $HostProfileComplianceSettleMinutes first so the hosts are past the noisy window straight
        after re-registration. Then, for each host in turn while it is still in Maintenance mode, a
        compliance scan is run to completion - not read from vCenter's cache - and the resulting
        status decides what happens:

          Compliant    - the host is taken out of Maintenance mode and the run moves on.
          NonCompliant - the operator is told to remediate (Auto Deploy or vCenter host profile
                         remediation) and chooses C to re-scan, O to override, or E to exit.
                         On C the host stays in Maintenance mode and the batch does not advance.
          NoProfile    - nothing to test; the operator chooses SKIP or exits.
          Unknown      - treated like NonCompliant, because an unreadable result is not a pass.
                         A scan that could not be completed lands here too, so it can never be
                         mistaken for a pass.

        The override exists because a host can be held back by a difference the operator has already
        assessed and accepted, and stalling a change window on it helps nobody. It is a deliberate
        decision, not a shortcut: the host is returned to service against a profile it does not
        match, so it is announced on screen and recorded in the run summary as Overridden, naming
        the status that was accepted.

        Applies to every reboot path - UCS Manager, Intersight, and ESXi-only - since all three
        return the host through the same Maintenance mode cycle.
    #>
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,
        [Parameter(Mandatory=$true)][string]$BatchNumber
    )

    if ((Test-DryRun) -or (Test-StageNoAck)) {
        Write-Host "DRY/STAGE: Would wait $HostProfileComplianceSettleMinutes minute(s), scan host profile compliance for $($HostNames -join ', '), then exit Maintenance mode for each compliant host." -ForegroundColor Green
        foreach ($hostName in $HostNames) {
            Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result "DryRun" -Details "No settle wait and no compliance scan issued."
        }
        return
    }

    Wait-HostProfileComplianceSettle -HostNames $HostNames -BatchNumber $BatchNumber

    foreach ($hostName in $HostNames) {
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

            if ($state.Status -eq "Compliant") {
                Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result "Compliant" -Details "Profile '$($state.ProfileName)' compliant after $attempt scan(s); checked $checkedAt."
                break
            }

            if ($state.Status -eq "NoProfile") {
                Write-Host "  No host profile is attached, so compliance cannot be confirmed for this host." -ForegroundColor Yellow
                $choice = Read-ChoiceExit -Message "No host profile attached to '$hostName'. Choose SKIP to accept and continue, or EXIT" -AllowedChoices @("SKIP") -ExitMessage "Stopped at host profile compliance - no profile attached to '$hostName'."
                if ($choice -eq "SKIP") {
                    Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result "Skipped" -Details "No host profile attached; operator chose to continue."
                    break
                }
            }

            Write-Host "  '$hostName' is NOT compliant with host profile '$($state.ProfileName)'." -ForegroundColor Yellow
            Write-Host "  Remediate the host now (vCenter host profile remediation, or re-provision via Auto Deploy)." -ForegroundColor Yellow
            Write-Host "    C - re-scan compliance once the host has been remediated. It stays in Maintenance" -ForegroundColor Yellow
            Write-Host "        mode and this batch does not advance." -ForegroundColor Yellow
            Write-Host "    O - override: accept the host as it is, take it out of Maintenance mode and carry" -ForegroundColor Yellow
            Write-Host "        on. Recorded in the run summary as an override." -ForegroundColor Yellow
            Write-Host "    E - exit the run safely, leaving the host in Maintenance mode." -ForegroundColor Yellow
            $complianceChoice = Read-ChoiceExit -Message "'$hostName' is not compliant. C to re-check, O to override and continue, E to exit" -AllowedChoices @("C","O") -ExitMessage "Stopped at host profile compliance for '$hostName'."

            if ($complianceChoice -eq "O") {
                Write-Host "  OVERRIDE: '$hostName' is being returned to service without passing its host profile check." -ForegroundColor Red
                Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result "Overridden" -Details "Operator accepted '$($state.Status)' against profile '$($state.ProfileName)' after $attempt scan(s) and continued. Checked $checkedAt. $($state.Details)"
                break
            }

            Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result $state.Status -Details "Attempt $attempt not compliant; operator chose to re-check."
        }

        # Only reached once the host is compliant, explicitly accepted with no profile attached, or
        # explicitly overridden by the operator.
        $hostObj = Get-VMHost -Name $hostName -ErrorAction Stop
        if ($hostObj.ConnectionState -eq "Maintenance") {
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
                Add-SummaryRecord -Stage "ExitMaintenance" -Batch $BatchNumber -HostName $hostName -Action "Exit Maintenance mode" -Result "Skipped" -Details "AutoExitMaintenanceMode disabled."
            }
        }
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

    if ((Test-DryRun) -or (Test-StageNoAck)) { return $true }

    $endTime = (Get-Date).AddMinutes($TimeoutMinutes)
    $announced = $false
    while ((Get-Date) -lt $endTime) {
        $current = $null
        try { $current = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue } catch {}
        if ($null -ne $current -and $current.ConnectionState -ne "Maintenance") {
            Write-Host "  '$HostName' is out of Maintenance mode (ConnectionState: $($current.ConnectionState))." -ForegroundColor Green
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
        Waits for one host to reach Maintenance mode. Returns $true if it does.

    .DESCRIPTION
        Polls rather than holding a request open. A blocking Set-VMHost keeps one HTTP request
        alive for the whole evacuation, and PowerCLI's WebOperationTimeoutSeconds ceiling is
        shorter than a production host takes, so the request is torn down mid-evacuation and
        surfaces as "An error occurred while sending the request" with the host left partway in.

        Returns $false on timeout rather than throwing, so the caller decides what a host that will
        not evacuate means.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$HostName,
        [int]$TimeoutMinutes = 60
    )

    $endTime = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $endTime) {
        $current = $null
        try { $current = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue } catch {}
        if ($null -ne $current -and $current.ConnectionState -eq "Maintenance") { return $true }
        Write-Host "    still evacuating '$HostName'..." -ForegroundColor Gray
        Start-Sleep -Seconds 30
    }
    return $false
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

    if ((Test-DryRun) -or (Test-StageNoAck)) { Write-Host "DRY/STAGE: Would request Maintenance mode, one at a time, for $($HostNames -join ', ')." -ForegroundColor Green; return }

    Write-Host "Entering Maintenance mode one host at a time, in cluster order: $($HostNames -join ', ')" -ForegroundColor Cyan

    $position = 0
    foreach ($hostName in $HostNames) {
        $position++
        $hostObj = Get-VMHost -Name $hostName -ErrorAction Stop

        if ($hostObj.ConnectionState -eq "Maintenance") {
            Write-Host "  [$position of $($HostNames.Count)] '$hostName' is already in Maintenance mode." -ForegroundColor Green
            Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "AlreadyIn" -Details "Host was already in Maintenance mode."
            continue
        }

        if ($hostObj.ConnectionState -ne "Connected") {
            Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "Failed" -Details "ConnectionState was $($hostObj.ConnectionState)."
            Stop-WithMessage "'$hostName' is $($hostObj.ConnectionState), not Connected, so it cannot be evacuated. Resolve in vCenter before continuing."
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

        if (-not (Wait-VMHostInMaintenance -HostName $hostName -TimeoutMinutes $MaintenanceValidationTimeoutMinutes)) {
            Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "Timeout" -Details "Did not reach Maintenance mode within $MaintenanceValidationTimeoutMinutes minute(s)."
            Stop-WithMessage "'$hostName' did not reach Maintenance mode within $MaintenanceValidationTimeoutMinutes minute(s). The rest of this batch has not been touched. Check DRS, VM affinity rules, and VMs that cannot be migrated (attached media, no shared storage) in vCenter."
        }

        Write-Host "  [$position of $($HostNames.Count)] '$hostName' is in Maintenance mode." -ForegroundColor Green
        Add-SummaryRecord -Stage "EnterMaintenance" -Batch "" -HostName $hostName -Action "Enter Maintenance mode" -Result "Entered" -Details "Evacuated and in Maintenance mode."
    }

    Write-Host "All $($HostNames.Count) host(s) in this batch are in Maintenance mode." -ForegroundColor Green
}

function Wait-BatchMaintenanceMode {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,[int]$TimeoutMinutes=60)
    if ((Test-DryRun) -or (Test-StageNoAck)) { return @(foreach ($name in $HostNames) { Get-VMHost -Name $name -ErrorAction SilentlyContinue }) }
    $timeout = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $notReady = @($HostNames | Where-Object { (Get-VMHost -Name $_ -ErrorAction SilentlyContinue).ConnectionState -ne "Maintenance" })
        if ($notReady.Count -eq 0) { return @(foreach ($name in $HostNames) { Get-VMHost -Name $name }) }
        Write-Host "Waiting for Maintenance mode. Not ready: $($notReady -join ', ')" -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    } until ((Get-Date) -gt $timeout)
    return $null
}

function Get-BatchConnectionStateSummary {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames)
    return @(foreach ($hostName in $HostNames) { $h = Get-VMHost -Name $hostName -ErrorAction SilentlyContinue; if($h){[pscustomobject]@{Host=$h.Name;Found=$true;ConnectionState=[string]$h.ConnectionState;PowerState=[string]$h.PowerState;Build=$h.Build}}else{[pscustomobject]@{Host=$hostName;Found=$false;ConnectionState="NotFound";PowerState="Unknown";Build=""}} })
}

function Wait-BatchReconnectAfterReboot {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$HostNames,[int]$InitialWaitMinutes,[string]$ModeLabel)
    if ((Test-DryRun) -or (Test-StageNoAck)) { return (Get-BatchConnectionStateSummary -HostNames $HostNames) }
    Write-Host "$ModeLabel initial wait: $InitialWaitMinutes minutes. Press R to recheck early, E to exit." -ForegroundColor Yellow
    $endTime = (Get-Date).AddMinutes($InitialWaitMinutes)
    while ((Get-Date) -lt $endTime) {
        $key = Read-PendingConsoleKey
        if ($key -eq "E") { Stop-SafeExit -Message "Stopped during post-reboot wait." }
        if ($key -eq "R") { break }
        Start-Sleep -Seconds 1
    }
    do {
        $summary = Get-BatchConnectionStateSummary -HostNames $HostNames
        $summary | Format-Table -AutoSize | Out-Host
        $bad = @($summary | Where-Object { $_.ConnectionState -ne "Connected" -and $_.ConnectionState -ne "Maintenance" })
        if ($bad.Count -eq 0) { return $summary }
        $choice = Read-ChoiceExit -Message "Reconnect incomplete. Choose RECHECK, OVERRIDE, or STOP" -AllowedChoices @("RECHECK","OVERRIDE","STOP")
        if ($choice -eq "STOP") { return $null }
        if ($choice -eq "OVERRIDE") { return $summary }
    } while ($true)
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
    $Global:UcsCandidateCache = @{}
    $Global:IntersightHostMap = @{}
    $Global:IntersightProfileCache = @{}
    $Global:IntersightSkippedHosts = @{}
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

    if ((Test-DryRun) -or (Test-StageNoAck)) {
        Write-Host "DRY/STAGE: no verification read - nothing was changed." -ForegroundColor Green
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
    }
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
    Reset-ClusterScopedState
    Select-RunMode
    Select-UpgradeMode
    if ((Test-StageNoAck) -and $Global:UpgradeMode -ne "ESXI_UCS_FIRMWARE") { Stop-WithMessage "STAGE_NO_ACK is only valid with UCSM firmware mode." }

    $allClusterHosts = @(Get-VMHost -Location $Cluster | Sort-Object Name)
    if ($allClusterHosts.Count -eq 0) { Stop-WithMessage "No hosts found in selected cluster." }

    # Informational only. These hosts are not Connected, so they never enter scope - but saying so
    # is better than an operator wondering later why they were left out.
    $parkedHosts = @($allClusterHosts | Where-Object { $_.ConnectionState -eq "Maintenance" } | Select-Object -ExpandProperty Name)
    if ($parkedHosts.Count -gt 0) {
        Write-Host "Host(s) already in Maintenance mode and out of scope for this run: $($parkedHosts -join ', ')" -ForegroundColor Yellow
        Add-SummaryRecord -Stage "PreFlight" -Batch "" -HostName "" -Action "Pre-existing Maintenance mode" -Result "Excluded" -Details ($parkedHosts -join ', ')
    }

    if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") { Build-InfrastructureHostMapping -Hosts $allClusterHosts }

    $alreadyTargetHosts = @($allClusterHosts | Where-Object { Test-VMHostOnTargetBuild -VMHostObject $_ })

    if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") {
        # Firmware-only mode must not exclude hosts just because the ESXi build is already current.
        # These hosts still need to be eligible for UCSM firmware policy staging/acknowledgement.
        $patchCandidateHosts = @($allClusterHosts | Where-Object { $_.ConnectionState -eq "Connected" })
    }
    else {
        # ESXi-only mode should skip hosts already on the target ESXi build.
        $patchCandidateHosts = @($allClusterHosts | Where-Object { $_.ConnectionState -eq "Connected" -and ($alreadyTargetHosts.Name -notcontains $_.Name) })
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
    if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE" -and -not (Test-StageNoAck)) {
        $patchCandidateHosts = @(Remove-IntersightHostsAlreadyDeployed -CandidateHosts $patchCandidateHosts)
    }

    if ($patchCandidateHosts.Count -eq 0) {
        if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") {
            Stop-WithMessage "Nothing to do: every host in this cluster is already deployed, or was excluded above. No Intersight server profile has changes staged."
        }
        else {
            Stop-WithMessage "No Connected ESXi patch candidate hosts available after excluding hosts already on the target ESXi build."
        }
    }

    $batchMode = Select-BatchMode

    $pendingHosts = New-Object System.Collections.ArrayList
    foreach ($hostObj in $patchCandidateHosts) { [void]$pendingHosts.Add($hostObj.Name) }
    $batchNumber = 0

    while ($pendingHosts.Count -gt 0) {
        $batchNumber++

        # Capacity is re-evaluated for every batch, not once up front, so hosts returning to
        # service are reflected in the next batch's size.
        $batchSize = 1
        if ($batchMode -eq "AUTO" -and -not (Test-StageNoAck)) {
            $remainingCandidates = @($pendingHosts | ForEach-Object { Get-VMHost -Name $_ -ErrorAction SilentlyContinue } | Where-Object { $null -ne $_ })
            $sizing = Get-CapacityBasedBatchSize -CandidateHosts $remainingCandidates -Cluster $Cluster
            $sizing.Diagnostics | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

            if ($sizing.SafeBatchSize -lt 1) {
                Add-SummaryRecord -Stage "ClusterHealth" -Batch $batchNumber -HostName "" -Action "Capacity sizing" -Result "Failed" -Details $sizing.Reason
                Stop-WithMessage "Cluster '$($Cluster.Name)' has insufficient capacity to remove even one host: $($sizing.Reason)"
            }
            $batchSize = [int]$sizing.SafeBatchSize
            Write-Host "Batch ${batchNumber} sized at $batchSize host(s) from live capacity. $($sizing.Reason)" -ForegroundColor Green
            Add-SummaryRecord -Stage "BatchSizing" -Batch $batchNumber -HostName "" -Action "Calculate batch size" -Result "$batchSize" -Details $sizing.Reason
        }
        elseif ($batchMode -eq "AUTO") {
            # STAGE_NO_ACK never reboots, so capacity is not a constraint there.
            $batchSize = [Math]::Min($pendingHosts.Count, [int]$MaxAbsoluteBatchSize)
        }

        # Cluster list order, first hosts first. $pendingHosts was built from the cluster's hosts
        # sorted by name, and taking from the front keeps each batch - and the order hosts are
        # evacuated within it - predictable and repeatable rather than whatever DRS finishes first.
        $currentBatchNames = @($pendingHosts | Select-Object -First $batchSize)
        $Global:BatchActionsSent = 0
        Write-Host "`nBATCH ${batchNumber} ($batchMode, $($currentBatchNames.Count) host(s)): $($currentBatchNames -join ', ')" -ForegroundColor Cyan

        if (Test-StageNoAck) {
            $currentBatchUcsNames = @($currentBatchNames | Where-Object { -not $Global:IntersightHostMap.ContainsKey($_) })
            $currentBatchIntersightNames = @($currentBatchNames | Where-Object { $Global:IntersightHostMap.ContainsKey($_) })
            if ($currentBatchUcsNames.Count -gt 0) {
                Set-UcsFirmwarePolicyForBatch -HostNames $currentBatchUcsNames -BatchNumber $batchNumber
                Get-UcsPendingRebootObjectsForBatch -HostNames $currentBatchUcsNames | Select-Object Host,UcsTarget,ServiceProfileDn,PendingAckFound,AckDn | Format-Table -AutoSize | Out-Host
            }
            if ($currentBatchIntersightNames.Count -gt 0) {
                # STAGE_NO_ACK never acknowledges/reboots - see the Test-StageNoAck branch inside
                # Invoke-IntersightAcceptAndRebootImmediateForBatch.
                Invoke-IntersightAcceptAndRebootImmediateForBatch -HostNames $currentBatchIntersightNames -BatchNumber $batchNumber
            }
            foreach ($hostName in $currentBatchNames) { [void]$pendingHosts.Remove($hostName) }
            continue
        }

        # Straight into Maintenance mode. Nothing is migrated by this script first - see
        # Request-MaintenanceModeForBatch.
        Request-MaintenanceModeForBatch -HostNames $currentBatchNames
        $batchMaintenanceHosts = Wait-BatchMaintenanceMode -HostNames $currentBatchNames -TimeoutMinutes $MaintenanceValidationTimeoutMinutes
        if ($null -eq $batchMaintenanceHosts) { Stop-WithMessage "Batch is not fully in Maintenance mode within timeout." }

        if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") {
            $currentBatchUcsNames = @($currentBatchNames | Where-Object { -not $Global:IntersightHostMap.ContainsKey($_) })
            $currentBatchIntersightNames = @($currentBatchNames | Where-Object { $Global:IntersightHostMap.ContainsKey($_) })

            if ($currentBatchUcsNames.Count -gt 0) { Set-UcsFirmwarePolicyForBatch -HostNames $currentBatchUcsNames -BatchNumber $batchNumber }
            if (-not (Test-DryRun)) { Invoke-RebootSafetyWindow -TimeoutSeconds 90 -HostNames $currentBatchNames -BatchNumber $batchNumber | Out-Null }
            if ($currentBatchUcsNames.Count -gt 0) { Invoke-UcsPendingAckForBatch -HostNames $currentBatchUcsNames -BatchNumber $batchNumber }

            # Intersight-routed hosts: detect the "Inconsistent" server profile caused by the firmware
            # policy update, accept it, tick the compulsory disruption acknowledgement, and reboot the
            # blade immediately - no separate typed confirmation gate for this subset, per how this
            # batch was requested. The pre-reboot safety window above still applies to the whole batch.
            if ($currentBatchIntersightNames.Count -gt 0) { Invoke-IntersightAcceptAndRebootImmediateForBatch -HostNames $currentBatchIntersightNames -BatchNumber $batchNumber }

            $initialWait = $FirmwareReconnectInitialWaitMinutes
            $modeLabel = "Firmware mode"

            # Nothing was actually sent, so nothing is rebooting. Waiting out the post-reboot
            # window here would burn the change window and then check compliance on a host that
            # never restarted. Surface it and let the operator decide instead.
            if ($Global:BatchActionsSent -eq 0 -and -not (Test-DryRun)) {
                Write-Host "" -ForegroundColor Yellow
                Write-Host "No firmware action was sent for Batch ${batchNumber}. Nothing is rebooting." -ForegroundColor Yellow

                # A host that reports RequiresDeploy=false is already where the run is trying to put
                # it. That is a result, not a problem, and stopping to ask about it strands an
                # unattended cluster on a host that needed nothing doing. So the ask is reserved for
                # the case that genuinely warrants it: a state the run could not read. An unreadable
                # state is not the same as "nothing to do" and must never be treated as one.
                $unresolved = New-Object System.Collections.Generic.List[string]
                Write-Host "Batch state:" -ForegroundColor Yellow
                foreach ($hostName in $currentBatchNames) {
                    $stateText = "unknown"
                    if ($Global:IntersightHostMap.ContainsKey($hostName)) {
                        try {
                            $sp = Resolve-IntersightServerProfileForHost -HostName $hostName -IntersightCsvRow $Global:IntersightHostMap[$hostName].IntersightCsvRow
                            $deployState = Get-IntersightProfileDeployState -ServerProfile $sp
                            $stateText = "Intersight ConfigState=$($deployState.ConfigState), RequiresDeploy=$($deployState.RequiresDeploy)"
                            if (-not $deployState.StateKnown) { [void]$unresolved.Add("$hostName (Intersight state not readable)") }
                            elseif ($deployState.RequiresDeploy) { [void]$unresolved.Add("$hostName (Intersight still has changes staged)") }
                        }
                        catch {
                            $stateText = "Intersight state unreadable - $($_.Exception.Message)"
                            [void]$unresolved.Add("$hostName (Intersight state unreadable)")
                        }
                    }
                    else {
                        $stateText = "UCSM - no pending activity found on the service profile"
                    }
                    Write-Host "  $hostName - $stateText" -ForegroundColor Yellow
                }

                if ($unresolved.Count -eq 0) {
                    Write-Host "Nothing is staged anywhere in this batch, so there is nothing to reboot. Continuing." -ForegroundColor Green
                    Add-SummaryRecord -Stage "BatchAction" -Batch $batchNumber -HostName "" -Action "Send firmware action" -Result "NoneNeeded" -Details "Every host reported no staged changes (Intersight RequiresDeploy=false, no UCSM pending activity); continued without prompting."
                }
                else {
                    Write-Host "These host(s) could not be confirmed as already current:" -ForegroundColor Yellow
                    $unresolved | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
                    Write-Host "The policy change may not have been staged against those profiles." -ForegroundColor Yellow
                    Add-SummaryRecord -Stage "BatchAction" -Batch $batchNumber -HostName "" -Action "Send firmware action" -Result "None" -Details "No action sent and $($unresolved.Count) host(s) unconfirmed: $($unresolved -join '; ')"

                    $choice = Read-ChoiceExit `
                        -Message "Nothing to reboot for Batch $batchNumber, and $($unresolved.Count) host(s) could not be confirmed as current. Choose CONTINUE to move on, or STOP" `
                        -AllowedChoices @("CONTINUE","STOP") `
                        -ExitMessage "Stopped because Batch $batchNumber had no firmware action to send."
                    if ($choice -eq "STOP") {
                        Stop-WithMessage "Batch $batchNumber had no firmware action to send. Confirm the firmware policy is staged against these profiles before re-running."
                    }
                }

                # Skip the reboot wait entirely, then let the normal compliance and health path run.
                $initialWait = 0
                $modeLabel = "Firmware mode (no reboot triggered)"
            }
        } else {
            Invoke-RebootSafetyWindow -TimeoutSeconds 90 -HostNames $currentBatchNames -BatchNumber $batchNumber | Out-Null
            foreach ($hostObj in $batchMaintenanceHosts) { if (-not (Test-DryRun)) { Restart-VMHost -VMHost $hostObj -Confirm:$false -ErrorAction Stop | Out-Null } }
            $initialWait = $EsxiOnlyReconnectInitialWaitMinutes
            $modeLabel = "ESXi-only mode"
        }

        $connectedBatchHosts = Wait-BatchReconnectAfterReboot -HostNames $currentBatchNames -InitialWaitMinutes $initialWait -ModeLabel $modeLabel
        if ($null -eq $connectedBatchHosts) { Stop-WithMessage "Batch is not confirmed back in vCenter. Stopping before next batch." }

        # The host is back in vCenter and still in Maintenance mode. Check it against its host
        # profile before it is allowed to take load again, and do not advance while any host in
        # the batch is non-compliant.
        Confirm-HostProfileComplianceAndExitMaintenance -HostNames $currentBatchNames -BatchNumber $batchNumber

        foreach ($hostName in $currentBatchNames) { [void]$pendingHosts.Remove($hostName) }

        # No post-batch cluster health gate. Host profile compliance is the gate: a host that
        # passes it and comes out of Maintenance mode is back in service, and the run moves on.
        # The cluster-wide checks that used to sit here - datastore free space, triggered alarms,
        # hosts in Maintenance mode elsewhere - were removed at the operator's direction after
        # they repeatedly failed a cluster with nothing wrong with it and stopped the run.

        Write-Host "Batch $batchNumber completed. Remaining hosts: $($pendingHosts.Count)" -ForegroundColor Green
        if ($pendingHosts.Count -gt 0) {
            Write-Host "Continuing automatically to Batch $($batchNumber + 1)." -ForegroundColor Green
        }
    }
    Show-ClusterFirmwareVerification -Cluster $Cluster -HostNames @($patchCandidateHosts | Select-Object -ExpandProperty Name)
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
