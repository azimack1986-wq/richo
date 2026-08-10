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
    server profile, checks for the "Inconsistent" state caused by a firmware policy update, accepts it
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
    - Credentials/API keys are kept in memory only.
    - Intersight only supports API-key + HTTP-signature auth, not username/password - see the
      $Global:IntersightApiKeyId / $Global:IntersightApiKeyFilePath notes in User Settings.
      Authentication is applied with Set-IntersightConfiguration; Intersight.PowerShell has no
      Connect-*/Disconnect-* cmdlet pair. $Global:IntersightBaseUrl is the appliance root only, with
      no /api/v1 suffix and no trailing slash.
    - DRYRUN is the default.
    - UCSM acknowledgement and Intersight accept/reboot are each scoped to their own batch hosts only.
    - Batch mode is AUTO (sized from live cluster capacity and health, capped at $MaxAbsoluteBatchSize)
      or SINGLE (one host at a time). There is no free-text batch size.
    - The run advances through the cluster automatically. The per-batch typed gates (ACK-BATCH-N and
      SAVE-BATCH-N) have been REMOVED in favour of automatic progression. What now gates each batch is:
      a pre-batch cluster health check, the timed pre-reboot safety window (press E to abort), a host
      profile compliance check on every rebooted host, and a post-batch cluster health check. Any of
      those failing stops the run.
    - After each reboot, every host is tested against its attached host profile while still in
      Maintenance mode. Compliant hosts are taken out of Maintenance mode and the run continues;
      non-compliant hosts stay in Maintenance mode and the operator is prompted to remediate and
      re-check. The run does not advance until the host passes.
    - Batch sizing now enforces $ResourceSafetyBuffer, $MinimumCpuHeadroomPercentAfterBatch,
      $MinimumMemoryHeadroomPercentAfterBatch and $MinimumDatastoreFreePercent.
    - Validate Cisco UCS PowerTool cmdlet names in your installed module version before LIVE RUN. The
      Intersight accept/reboot parameter surface is checked at run time by
      Assert-IntersightUpgradeCmdletSurface, which stops the run rather than guessing if it differs.
#>

# -----------------------------
# User Settings
# -----------------------------

$DefaultVCenter = "siepd24vsp0002.dpe.protected.mil.au"
$TargetEsxiVersion = "ESXi-8.0U3j-25429389"
$TargetEsxiBuild = if ($TargetEsxiVersion -match "(\d{7,})$") { $Matches[1] } else { "" }
$TargetUcsFirmwarePolicyName = ""

# Intersight PVA routing.
# CDP/LLDP remains the identity source for every host (same as the UCSM path below). A host whose
# normalised CDP/LLDP system name matches a row in this CSV is routed through Intersight PVA;
# everything else falls through unchanged to the existing UCS Manager logic.
# Expected CSV columns: Name (the Intersight Fabrics export column matched against CDP/LLDP system
# name), ServerProfileName (optional - defaults to Name if omitted), Moid (optional, speeds up lookup).
$IntersightCsvPath = "C:\temp\intersightfabric.csv"
# BasePath is the appliance root only - no /api/v1 suffix and no trailing slash. The module
# appends the API path itself, and a trailing slash breaks HTTP signature validation.
$Global:IntersightBaseUrl = "https://intersight.com"           # PVA example: https://<pva-fqdn>
$Global:IntersightSkipCertificateCheck = $true                 # required for PVA on-prem; harmless for SaaS
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
$Global:EsxiDiscoveryCache = @{}

$ResourceSafetyBuffer = 0.85
$MinimumCpuHeadroomPercentAfterBatch = 10
$MinimumMemoryHeadroomPercentAfterBatch = 10
$MinimumDatastoreFreePercent = 10
$MaxAbsoluteBatchSize = 6
$MaintenanceValidationTimeoutMinutes = 60
$EsxiOnlyReconnectInitialWaitMinutes = 15
$FirmwareReconnectInitialWaitMinutes = 25
$ReconnectRetryWindowMinutes = 5
$ReconnectCheckIntervalSeconds = 60

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
    $Global:RunSummary.Add([pscustomobject]@{ TimeStamp=Get-Date; Stage=$Stage; Batch=$Batch; Host=$HostName; Action=$Action; Result=$Result; Details=$Details })
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
    Add-SummaryRecord -Stage "Stop" -Batch "" -HostName "" -Action "Stop workflow" -Result "Stopped" -Details $Message
    Export-RunSummary
    throw "STOP_WORKFLOW"
}

function Read-ChoiceExit {
    param([Parameter(Mandatory=$true)][string]$Message,[Parameter(Mandatory=$true)][array]$AllowedChoices,[string]$ExitMessage="Script stopped at a safe checkpoint by implementor.")
    $normalizedAllowed = @($AllowedChoices | ForEach-Object { $_.ToString().ToUpper() })
    do {
        $answer = (Read-Host "$Message Type one of: $($AllowedChoices -join ', '), or EXIT").Trim().ToUpper()
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

function Confirm-RunPrerequisites {
    <#
    .SYNOPSIS
        Pre-flight gate confirming the Intersight API key ID and .pem private key are in hand.

    .DESCRIPTION
        Both are generated together in Intersight (Settings > API Keys) and cannot be recovered
        afterwards - the secret key is only downloadable at creation. Finding that out partway
        through a change window is expensive, so it is asked before vCenter is even contacted.
    #>
    if ($Global:PrerequisitesConfirmed) { return }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host " PRE-FLIGHT CHECK" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host "If any host in scope is Intersight-managed, this run needs BOTH of:" -ForegroundColor Yellow
    Write-Host "  1. An Intersight API Key ID - three segments, e.g. aaaa/bbbb/cccc" -ForegroundColor Yellow
    Write-Host "  2. The matching private key (.pem) file saved to this machine" -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Both are issued together in Intersight under Settings > API Keys. The" -ForegroundColor Yellow
    Write-Host "secret key can only be downloaded at the moment the key is created - if" -ForegroundColor Yellow
    Write-Host "you no longer have that file, generate a new API key before continuing." -ForegroundColor Yellow
    Write-Host "You will be asked to browse to the .pem file when it is first needed." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Also confirm: UCSM credentials to hand, and $IntersightCsvPath present" -ForegroundColor Yellow
    Write-Host "if any host is Intersight-managed." -ForegroundColor Yellow
    Write-Host "=====================================================================" -ForegroundColor Cyan

    $answer = Read-ChoiceExit -Message "Do you have the Intersight API Key ID and matching .pem file available? Answer SKIP if no Intersight-managed hosts are in scope." -AllowedChoices @("YES","SKIP") -ExitMessage "Stopped at the pre-flight prerequisites check."

    Add-SummaryRecord -Stage "PreFlight" -Batch "" -HostName "" -Action "Confirm Intersight prerequisites" -Result $answer -Details "Operator confirmation of API Key ID and .pem availability."
    if ($answer -eq "SKIP") {
        Write-Host "Continuing without confirmed Intersight credentials. If an Intersight-managed host is detected, you will still be prompted for the key ID and .pem file at that point." -ForegroundColor Yellow
    }
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

function Select-UcsFirmwarePolicyFromUcs {
    param(
        [Parameter(Mandatory=$true)][string]$UcsTarget,
        [Parameter(Mandatory=$true)]$UcsSession
    )

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Retrieving available UCSM host firmware packages from $UcsTarget..." -ForegroundColor Cyan

    $policyRows = @(Get-UcsFirmwarePolicyRows -UcsSession $UcsSession)
    if ($policyRows.Count -eq 0) {
        Stop-WithMessage "No UCSM host firmware packages were returned from $UcsTarget. Check UCS PowerTool access and permissions."
    }

    Write-Host "Available UCSM host firmware packages returned by UCS PowerTool for this UCSM target:" -ForegroundColor Cyan
    $policyRows | Select-Object Name,Dn | Format-Table -AutoSize

    $manualSelectionName = "<MANUAL - enter firmware policy name>"
    $selectionRows = @($policyRows | Select-Object Name,Dn,Description)
    $selectionRows += [pscustomobject]@{
        Name        = $manualSelectionName
        Dn          = "Manual entry. Use only if the policy is visible in UCSM GUI but not returned by PowerTool."
        Description = "Manual override"
    }

    $selectedPolicy = $null

    try {
        $selectedPolicy = $selectionRows |
            Out-GridView -Title "Select target UCS Host Firmware Package for UCSM $UcsTarget" -PassThru
    }
    catch {
        $selectedPolicy = $null
    }

    if ($null -eq $selectedPolicy) {
        Write-Host "" -ForegroundColor Cyan
        Write-Host "GUI drop-down/list selection was not available or no item was selected. Using numbered console selection." -ForegroundColor Yellow
        for ($i = 0; $i -lt $selectionRows.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $selectionRows[$i].Name) -ForegroundColor Cyan
        }
        do {
            $choice = (Read-Host "Enter target firmware policy number, type policy name manually, or type EXIT").Trim()
            if ($choice.ToUpper() -eq "EXIT") { Stop-SafeExit -Message "Stopped during UCS firmware policy selection." }
            if ($choice -match '^\d+$') {
                $index = [int]$choice - 1
                if ($index -ge 0 -and $index -lt $selectionRows.Count) {
                    $selectedPolicy = $selectionRows[$index]
                    break
                }
            }
            else {
                $matched = @($policyRows | Where-Object { $_.Name -eq $choice })
                if ($matched.Count -eq 1) {
                    $selectedPolicy = $matched[0]
                    break
                }
                if (-not [string]::IsNullOrWhiteSpace($choice)) {
                    $selectedPolicy = [pscustomobject]@{ Name=$choice; Dn="Manual entry"; Description="Manual override" }
                    break
                }
            }
            Write-Host "Invalid firmware policy selection." -ForegroundColor Yellow
        } while ($true)
    }

    if ($selectedPolicy.Name -eq $manualSelectionName) {
        $manualPolicy = (Read-Host "Enter target UCS Host Firmware Package name exactly as shown in UCSM GUI, or type EXIT").Trim()
        if ($manualPolicy.ToUpper() -eq "EXIT") { Stop-SafeExit -Message "Stopped during manual UCS firmware policy selection." }
        if ([string]::IsNullOrWhiteSpace($manualPolicy)) { Stop-WithMessage "Manual UCS firmware policy name cannot be blank." }
        $selectedPolicy = [pscustomobject]@{ Name=$manualPolicy; Dn="Manual entry"; Description="Manual override" }
    }

    if ($null -eq $selectedPolicy -or [string]::IsNullOrWhiteSpace($selectedPolicy.Name)) {
        Stop-WithMessage "No UCS firmware policy was selected."
    }

    $selectedPolicyFound = (($policyRows | Where-Object { $_.Name -eq $selectedPolicy.Name }).Count -gt 0)
    if (-not $selectedPolicyFound) {
        Write-Host "WARNING: Firmware policy '$($selectedPolicy.Name)' was entered manually and was not returned by Get-UcsFirmwareComputeHostPack for UCSM $UcsTarget." -ForegroundColor Yellow
        Write-Host "Only continue if the policy is visible in the UCSM GUI for this same UCSM domain and you have confirmed the exact spelling." -ForegroundColor Yellow
        $confirmManual = Read-ChoiceExit -Message "Continue with manually entered firmware policy '$($selectedPolicy.Name)'?" -AllowedChoices @("YES","NO") -ExitMessage "Stopped during manual firmware policy confirmation."
        if ($confirmManual -ne "YES") { Stop-SafeExit -Message "Manual UCS firmware policy was not accepted." }
    }

    Set-Variable -Name TargetUcsFirmwarePolicyName -Scope Script -Value ([string]$selectedPolicy.Name)
    Write-Host "Selected target UCS firmware policy: $TargetUcsFirmwarePolicyName" -ForegroundColor Green
    Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Select target firmware policy" -Result "Selected" -Details $TargetUcsFirmwarePolicyName
    return [string]$selectedPolicy.Name
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
    param([Parameter(Mandatory=$true)][array]$Hosts)

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
        $intersightRoutedRows | Format-Table -AutoSize
        foreach ($row in $intersightRoutedRows) {
            Add-SummaryRecord -Stage "InfrastructureDetection" -Batch "" -HostName $row.Host -Action "Detect infrastructure" -Result "Intersight" -Details "CdpSystemName=$($row.CdpSystemName); MatchedOn=$($row.MatchedOn); CsvName=$($row.IntersightCsvName)."
        }
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
    $discoveryRows | Select-Object Host,Vmnic,CdpSystemName,UcsTarget,Discovery | Format-Table -AutoSize

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
            TargetPolicy       = $TargetUcsFirmwarePolicyName
        }
        $Global:UcsHostMap[$row.Host] = $mapRow
        [void]$mappingRows.Add($mapRow)
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "UCSM host mapping and current firmware policy:" -ForegroundColor Cyan
    $mappingRows | Select-Object Host,Vmnic,UcsTarget,ServiceProfileDn,CurrentPolicy | Format-Table -AutoSize

    $uniqueTargets = @($mappingRows | Select-Object -ExpandProperty UcsTarget -Unique)
    if ($uniqueTargets.Count -eq 0) { Stop-WithMessage "No UCSM targets were discovered for firmware policy selection." }

    $firstTarget = $uniqueTargets[0]
    $firstSession = Get-UcsSessionForTarget -UcsTarget $firstTarget
    [void](Select-UcsFirmwarePolicyFromUcs -UcsTarget $firstTarget -UcsSession $firstSession)

    foreach ($row in $mappingRows) {
        $row.TargetPolicy = $TargetUcsFirmwarePolicyName
        $Global:UcsHostMap[$row.Host] = $row
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "Final UCSM host mapping with selected target firmware policy:" -ForegroundColor Cyan
    $mappingRows | Select-Object Host,Vmnic,UcsTarget,ServiceProfileDn,CurrentPolicy,TargetPolicy | Format-Table -AutoSize

    foreach ($targetName in $uniqueTargets) {
        $ucsSession = Get-UcsSessionForTarget -UcsTarget $targetName
        if (-not (Test-UcsFirmwarePolicyExists -PolicyName $TargetUcsFirmwarePolicyName -UcsSession $ucsSession)) {
            Write-Host "WARNING: Target UCS firmware policy '$TargetUcsFirmwarePolicyName' was not returned by PowerTool from UCSM $targetName after selection." -ForegroundColor Yellow
            Write-Host "If this was a manual policy selection, the later Set-UcsServiceProfile step will still attempt to apply it directly." -ForegroundColor Yellow
            Add-SummaryRecord -Stage "UCSMFirmwarePolicySelection" -Batch "" -HostName "" -Action "Validate selected policy" -Result "Warning" -Details "Policy not returned by PowerTool on $targetName."
        }
    }

    Add-SummaryRecord -Stage "UCSMMapping" -Batch "" -HostName "" -Action "Map hosts" -Result "Completed" -Details "$($mappingRows.Count) hosts mapped. Target policy: $TargetUcsFirmwarePolicyName."
}

function Set-UcsFirmwarePolicyForBatch {
    param(
        [Parameter(Mandatory=$true)][array]$HostNames,
        [Parameter(Mandatory=$true)][string]$BatchNumber,
        # RECHECK re-enters this function. Bounded so a policy that never converges ends in a
        # clean stop instead of recursing until the call stack gives out.
        [int]$Attempt = 1,
        [int]$MaxAttempts = 5
    )

    $rows = foreach ($hostName in $HostNames) { $Global:UcsHostMap[$hostName] }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "UCS firmware policy change preview for Batch ${BatchNumber}:" -ForegroundColor Cyan
    $rows | Select-Object Host,UcsTarget,ServiceProfileDn,CurrentPolicy,TargetPolicy | Format-Table -AutoSize

    if (Test-DryRun) {
        Write-Host "DRY RUN: Would apply target UCS firmware policy to current batch service profiles only." -ForegroundColor Green
        foreach ($row in $rows) {
            Add-SummaryRecord -Stage "UCSMFirmwarePolicy" -Batch $BatchNumber -HostName $row.Host -Action "Apply firmware policy" -Result "DryRun" -Details "Would set $($row.ServiceProfileDn) to $TargetUcsFirmwarePolicyName."
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

        if ($beforePolicy -ne $TargetUcsFirmwarePolicyName) {
            Set-UcsServiceProfile -Ucs $ucsSession -ServiceProfile $spBefore -HostFwPolicyName $TargetUcsFirmwarePolicyName -Force -ErrorAction Stop | Out-Null
            $setResult = "SetSent"
            $setDetails = "Set command sent from $beforePolicy to $TargetUcsFirmwarePolicyName."
        }

        Start-Sleep -Seconds 2

        $spAfter = Get-UcsServiceProfile -Ucs $ucsSession -Dn $row.ServiceProfileDn -ErrorAction Stop
        $afterPolicy = Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $spAfter
        $verified = ($afterPolicy -eq $TargetUcsFirmwarePolicyName)
        $verifyResult = if ($verified) { "Verified" } else { "NotVerified" }

        $row.CurrentPolicy = $afterPolicy
        $row.TargetPolicy = $TargetUcsFirmwarePolicyName
        $Global:UcsHostMap[$row.Host] = $row

        [void]$verificationRows.Add([pscustomobject]@{
            Batch            = $BatchNumber
            Host             = $row.Host
            UcsTarget        = $row.UcsTarget
            ServiceProfileDn = $row.ServiceProfileDn
            BeforePolicy     = $beforePolicy
            RequestedPolicy  = $TargetUcsFirmwarePolicyName
            AfterPolicy      = $afterPolicy
            Result           = $verifyResult
            Action           = $setResult
        })

        Add-SummaryRecord -Stage "UCSMFirmwarePolicy" -Batch $BatchNumber -HostName $row.Host -Action "Apply firmware policy" -Result $verifyResult -Details "$setDetails AfterPolicy=$afterPolicy."
    }

    Write-Host "" -ForegroundColor Cyan
    Write-Host "UCS firmware policy verification after change for Batch ${BatchNumber}:" -ForegroundColor Cyan
    $verificationRows | Select-Object Host,ServiceProfileDn,BeforePolicy,RequestedPolicy,AfterPolicy,Result | Format-Table -AutoSize

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
        $failedVerification | Select-Object Host,ServiceProfileDn,BeforePolicy,RequestedPolicy,AfterPolicy,Result | Format-Table -AutoSize
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
    param([Parameter(Mandatory=$true)][array]$HostNames)
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
    param([Parameter(Mandatory=$true)][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)
    $pendingRows = @(Get-UcsPendingRebootObjectsForBatch -HostNames $HostNames)
    $pendingRows | Select-Object Host,UcsTarget,ServiceProfileDn,PendingAckFound,AckDn | Format-Table -AutoSize
    if (Test-DryRun) { Write-Host "DRY RUN: Would acknowledge only listed current-batch UCSM pending objects." -ForegroundColor Green; return }

    # The typed ACK-BATCH-N gate that used to sit here has been removed so the run advances
    # through the cluster on its own. The abort point is now the pre-reboot safety window
    # immediately before this call, which covers the whole batch and accepts E to exit.
    Write-Host "Acknowledging UCSM pending reboot for Batch $BatchNumber ($(@($pendingRows | Where-Object { $_.PendingAckFound }).Count) host(s) with a pending activity)." -ForegroundColor Yellow
    foreach ($row in $pendingRows) {
        if (-not $row.PendingAckFound) { continue }
        $ucsSession = Get-UcsSessionForTarget -UcsTarget $row.UcsTarget
        Set-UcsLsmaintAck -Ucs $ucsSession -LsmaintAck $row.AckObject -AdminState "trigger-immediate" -Force -ErrorAction Stop | Out-Null
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
    foreach ($cmdletName in @("Set-IntersightConfiguration","Get-IntersightServerProfile")) {
        if ($null -eq (Get-Command -Name $cmdletName -ErrorAction SilentlyContinue)) {
            Stop-WithMessage "Intersight.PowerShell module was not found ($cmdletName is missing). Import Intersight.PowerShell before running against hosts mapped to Intersight."
        }
    }

    # Side-by-side module versions are the most common cause of AuthenticationFailure with
    # otherwise correct credentials, and the failure message never points at the real cause.
    $installed = @(Get-Module -ListAvailable -Name Intersight.PowerShell | Select-Object -ExpandProperty Version -Unique)
    if ($installed.Count -gt 1) {
        Write-Host "WARNING: $($installed.Count) versions of Intersight.PowerShell are installed: $(($installed | ForEach-Object { $_.ToString() }) -join ', ')." -ForegroundColor Yellow
        Write-Host "Side-by-side versions are a known cause of AuthenticationFailure even with a valid key. Remove the older versions if the login below fails." -ForegroundColor Yellow
        Add-SummaryRecord -Stage "IntersightLogin" -Batch "" -HostName "" -Action "Check module versions" -Result "Warning" -Details "Multiple Intersight.PowerShell versions installed: $(($installed | ForEach-Object { $_.ToString() }) -join ', ')."
    }
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

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($cmdletName in @("New-IntersightFirmwareUpgrade","Initialize-IntersightMoMoRef")) {
        if ($null -eq (Get-Command -Name $cmdletName -ErrorAction SilentlyContinue)) { [void]$missing.Add($cmdletName) }
    }
    if ($missing.Count -gt 0) {
        Stop-WithMessage "Intersight accept/reboot requires $($missing -join ' and '), which the installed Intersight.PowerShell version does not provide. Confirm the correct call for your version with 'Get-Command -Module Intersight.PowerShell -Noun Intersight*Upgrade*' and update this script before a LIVE RUN."
    }

    $upgradeCmd = Get-Command -Name New-IntersightFirmwareUpgrade
    $missingParams = @("Server","RebootImmediately","DisruptionAcknowledged") | Where-Object { -not $upgradeCmd.Parameters.ContainsKey($_) }
    if ($missingParams.Count -gt 0) {
        Stop-WithMessage "New-IntersightFirmwareUpgrade in the installed Intersight.PowerShell version does not accept: $($missingParams -join ', '). Run 'Get-Help New-IntersightFirmwareUpgrade -Full' and update this script's accept/reboot call before a LIVE RUN."
    }

    $Global:IntersightUpgradeSurfaceChecked = $true
    Write-Host "Intersight accept/reboot cmdlet surface validated (New-IntersightFirmwareUpgrade)." -ForegroundColor Green
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
    if ($null -ne $Global:IntersightSession) { return $Global:IntersightSession }
    Assert-IntersightPowerShellAvailable
    Get-IntersightCredentialIfNeeded

    $basePath = $Global:IntersightBaseUrl.Trim().TrimEnd('/')
    Write-Host "Configuring Intersight connection: $basePath" -ForegroundColor Cyan

    try {
        # Intersight.PowerShell has no Connect-* cmdlet - authentication is process-wide
        # configuration applied by Set-IntersightConfiguration, and every subsequent
        # Get-Intersight*/Set-Intersight* call signs against it.
        #
        # The four signing headers must be exactly these, in this order and capitalisation;
        # anything else produces "cannot sign http request, request does not contain date header".
        $signingHeaders = @("(request-target)", "Host", "Date", "Digest")

        $configParams = @{
            BasePath          = $basePath
            ApiKeyId          = $Global:IntersightApiKeyId
            ApiKeyFilePath    = $Global:IntersightApiKeyFilePath
            HttpSigningHeader = $signingHeaders
            HashAlgorithm     = "SHA256"
            ErrorAction       = "Stop"
        }
        if ($Global:IntersightSkipCertificateCheck) { $configParams["SkipCertificateCheck"] = $true }

        Set-IntersightConfiguration @configParams | Out-Null

        # Prove the configuration took and that the key actually authenticates, before any
        # host is routed down the Intersight path.
        $activeConfig = Get-IntersightConfiguration -ErrorAction Stop
        if ($null -eq $activeConfig -or [string]::IsNullOrWhiteSpace([string]$activeConfig.BasePath)) {
            Stop-WithMessage "Set-IntersightConfiguration did not take effect - Get-IntersightConfiguration returned no BasePath."
        }

        [void](Get-IntersightServerProfile -Top 1 -Skip 0 -ErrorAction Stop)

        $Global:IntersightSession = $activeConfig
        Write-Host "Intersight authenticated against $basePath." -ForegroundColor Green
        Add-SummaryRecord -Stage "IntersightLogin" -Batch "" -HostName "" -Action "Authenticate" -Result "Connected" -Details "BasePath=$basePath."
        return $Global:IntersightSession
    } catch {
        Add-SummaryRecord -Stage "IntersightLogin" -Batch "" -HostName "" -Action "Authenticate" -Result "Failed" -Details $_.Exception.Message
        Stop-WithMessage "Intersight login failed against '$basePath': $($_.Exception.Message)`nCheck: single Intersight.PowerShell version installed, three-segment API Key ID, matching .pem secret key, BasePath without /api/v1 or trailing slash."
    }
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

function Get-IntersightProfileInconsistencyState {
    param([Parameter(Mandatory=$true)]$ServerProfile)

    # ConfigContext.ConfigState surfaces "Inconsistent" when the deployed config (including a
    # firmware/host-firmware-package policy) no longer matches what is actually running on the server.
    $configState = $null
    if ($ServerProfile.PSObject.Properties.Name -contains "ConfigContext" -and $null -ne $ServerProfile.ConfigContext) {
        $configState = $ServerProfile.ConfigContext.ConfigState
    }

    # An absent or blank ConfigState is not the same as "consistent, nothing to do". Treating the
    # two alike silently skips a host that may still need the firmware change, so the caller is
    # given enough to tell them apart and stop.
    $stateKnown = -not [string]::IsNullOrWhiteSpace([string]$configState)
    return [pscustomobject]@{
        ConfigState    = if ($stateKnown) { [string]$configState } else { "UNKNOWN" }
        StateKnown     = $stateKnown
        IsInconsistent = ($configState -eq "Inconsistent")
    }
}

function Get-IntersightPendingInconsistencyForBatch {
    param([Parameter(Mandatory=$true)][array]$HostNames)
    $rows = New-Object System.Collections.ArrayList
    foreach ($hostName in $HostNames) {
        $map = $Global:IntersightHostMap[$hostName]
        $sp = Resolve-IntersightServerProfileForHost -HostName $hostName -IntersightCsvRow $map.IntersightCsvRow
        $state = Get-IntersightProfileInconsistencyState -ServerProfile $sp
        [void]$rows.Add([pscustomobject]@{
            Host            = $hostName
            ServerProfile   = $sp.Name
            ProfileMoid     = $sp.Moid
            ConfigState     = $state.ConfigState
            StateKnown      = $state.StateKnown
            IsInconsistent  = $state.IsInconsistent
            ServerProfileObj = $sp
        })
    }
    return @($rows)
}

function Invoke-IntersightAcceptAndRebootImmediateForBatch {
    param([Parameter(Mandatory=$true)][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)

    if ($HostNames.Count -eq 0) { return }

    $pendingRows = @(Get-IntersightPendingInconsistencyForBatch -HostNames $HostNames)
    Write-Host "" -ForegroundColor Cyan
    Write-Host "Intersight server profile inconsistency check for Batch ${BatchNumber}:" -ForegroundColor Cyan
    $pendingRows | Select-Object Host,ServerProfile,ConfigState,IsInconsistent | Format-Table -AutoSize

    # A profile whose ConfigState could not be read is not evidence that there is nothing to do.
    # Continuing past it would quietly leave the host un-upgraded while the batch reports success.
    $unknownStateRows = @($pendingRows | Where-Object { -not $_.StateKnown })
    if ($unknownStateRows.Count -gt 0) {
        Write-Host "WARNING: ConfigState could not be read for $($unknownStateRows.Count) Intersight profile(s) in this batch: $(($unknownStateRows | Select-Object -ExpandProperty Host) -join ', ')" -ForegroundColor Yellow
        Write-Host "These hosts cannot be confirmed as either already-consistent or pending, so skipping them silently is not safe." -ForegroundColor Yellow
        foreach ($row in $unknownStateRows) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Accept + reboot immediately" -Result "Warning" -Details "ConfigState unreadable on profile '$($row.ServerProfile)'."
        }
        if (-not (Test-DryRun)) {
            $choice = Read-ChoiceExit -Message "Intersight ConfigState unreadable for one or more hosts. Choose SKIP to leave them untouched and continue, or STOP" -AllowedChoices @("SKIP","STOP") -ExitMessage "Stopped on unreadable Intersight ConfigState."
            if ($choice -eq "STOP") { Stop-WithMessage "Intersight ConfigState could not be read for: $(($unknownStateRows | Select-Object -ExpandProperty Host) -join ', ')." }
        }
    }

    if (Test-DryRun) {
        foreach ($row in $pendingRows) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Accept + reboot immediately" -Result "DryRun" -Details "ConfigState=$($row.ConfigState)."
        }
        Write-Host "DRY RUN: Would accept the firmware-policy inconsistency and reboot immediately for this batch's Intersight-routed hosts only." -ForegroundColor Green
        return
    }

    if (Test-StageNoAck) {
        foreach ($row in $pendingRows) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Accept + reboot immediately" -Result "Skipped" -Details "STAGE_NO_ACK mode - no acknowledgement sent."
        }
        Write-Host "SAVE ONLY / NO ACKNOWLEDGEMENT mode selected: skipping Intersight accept/reboot for this batch." -ForegroundColor Green
        return
    }

    if (@($pendingRows | Where-Object { $_.IsInconsistent }).Count -gt 0) {
        Assert-IntersightUpgradeCmdletSurface
    }

    foreach ($row in $pendingRows) {
        if (-not $row.IsInconsistent) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Accept + reboot immediately" -Result "Skipped" -Details "ConfigState=$($row.ConfigState) - not Inconsistent, nothing to accept."
            continue
        }

        Write-Host "Intersight: accepting inconsistency and rebooting immediately for '$($row.Host)' (profile '$($row.ServerProfile)')." -ForegroundColor Yellow
        try {
            # Parameter surface confirmed once per run by Assert-IntersightUpgradeCmdletSurface before
            # anything is sent, rather than discovered mid-batch on the first blade.
            #   - RebootImmediately corresponds to choosing "Reboot Immediately" instead of scheduling.
            #   - DisruptionAcknowledged corresponds to the UI's compulsory "I understand this will be
            #     disruptive" tick box - there is no separate confirmation step once this is set, so
            #     the script itself is the record of acceptance (captured in the summary CSV below).
            New-IntersightFirmwareUpgrade `
                -Server (Initialize-IntersightMoMoRef -Moid $row.ServerProfileObj.Moid -ObjectType "server.Profile") `
                -RebootImmediately $true `
                -DisruptionAcknowledged $true `
                -ErrorAction Stop | Out-Null

            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Accept + reboot immediately" -Result "Sent" -Details "ServerProfile=$($row.ServerProfile); ConfigState was Inconsistent; disruption tick box accepted."
        } catch {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Accept + reboot immediately" -Result "Failed" -Details $_.Exception.Message
            Stop-WithMessage "Intersight accept/reboot failed for '$($row.Host)': $($_.Exception.Message)"
        }
    }
}

# -----------------------------
# vCenter workflow helpers
# -----------------------------

function Select-ClusterInteractive {
    param([Parameter(Mandatory=$true)][array]$Clusters)
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

function Get-ClusterHealthReport {
    <#
    .SYNOPSIS
        Evaluates whether the cluster is healthy enough to start or continue batching.

    .DESCRIPTION
        Checked before every batch and again after each batch completes, so the run only
        advances through the cluster while the cluster is actually well. Covers host
        connection state, hosts unexpectedly in Maintenance mode, datastore free space
        against $MinimumDatastoreFreePercent, and red alarms triggered on the cluster.

    .PARAMETER Cluster
        The cluster being worked on.

    .PARAMETER IgnoreHostNames
        Hosts excluded from the assessment - the current batch, which is expected to be
        in Maintenance mode or rebooting.
    #>
    param(
        [Parameter(Mandatory=$true)]$Cluster,
        [array]$IgnoreHostNames = @()
    )

    $reasons = New-Object System.Collections.Generic.List[string]

    $allHosts = @(Get-VMHost -Location $Cluster -ErrorAction Stop)
    $relevant = @($allHosts | Where-Object { $IgnoreHostNames -notcontains $_.Name })

    $badState = @($relevant | Where-Object { $_.ConnectionState -eq "NotResponding" -or $_.ConnectionState -eq "Disconnected" })
    if ($badState.Count -gt 0) {
        [void]$reasons.Add("Host(s) not responding or disconnected: $(($badState | Select-Object -ExpandProperty Name) -join ', ')")
    }

    $inMaintenance = @($relevant | Where-Object { $_.ConnectionState -eq "Maintenance" })
    if ($inMaintenance.Count -gt 0) {
        [void]$reasons.Add("Host(s) in Maintenance mode outside the current batch: $(($inMaintenance | Select-Object -ExpandProperty Name) -join ', ')")
    }

    try {
        $lowDatastores = @(
            Get-Datastore -Location $Cluster -ErrorAction Stop |
                Where-Object { $_.CapacityGB -gt 0 -and ((($_.FreeSpaceGB / $_.CapacityGB) * 100) -lt $MinimumDatastoreFreePercent) }
        )
        if ($lowDatastores.Count -gt 0) {
            $names = @($lowDatastores | ForEach-Object { "{0} ({1:N1}% free)" -f $_.Name, (($_.FreeSpaceGB / $_.CapacityGB) * 100) })
            [void]$reasons.Add("Datastore(s) below $MinimumDatastoreFreePercent% free: $($names -join ', ')")
        }
    }
    catch {
        [void]$reasons.Add("Datastore free space could not be evaluated: $($_.Exception.Message)")
    }

    try {
        $freshCluster = Get-Cluster -Name $Cluster.Name -ErrorAction Stop
        $redAlarms = @($freshCluster.ExtensionData.TriggeredAlarmState | Where-Object { $_.OverallStatus -eq 'red' })
        if ($redAlarms.Count -gt 0) {
            [void]$reasons.Add("$($redAlarms.Count) red alarm(s) triggered on cluster '$($Cluster.Name)'")
        }
    }
    catch {}

    return [pscustomobject]@{
        IsHealthy      = ($reasons.Count -eq 0)
        Reasons        = @($reasons)
        ConnectedHosts = @($relevant | Where-Object { $_.ConnectionState -eq "Connected" })
    }
}

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
    Write-Host "pausing only for the pre-reboot safety window, a host profile that is not" -ForegroundColor Yellow
    Write-Host "compliant, or a failed cluster health check." -ForegroundColor Yellow

    $choice = Read-ChoiceExit -Message "Select batch mode" -AllowedChoices @("1","2","3") -ExitMessage "Stopped during batch mode selection."
    if ($choice -eq "3") { Stop-SafeExit -Message "Stopped during batch mode selection." }

    $mode = if ($choice -eq "2") { "SINGLE" } else { "AUTO" }
    Add-SummaryRecord -Stage "BatchMode" -Batch "" -HostName "" -Action "Select batch mode" -Result $mode -Details "Automatic progression through cluster after each healthy batch."
    return $mode
}

function Get-VMHostProfileComplianceState {
    <#
    .SYNOPSIS
        Tests a host against its attached host profile.

    .DESCRIPTION
        Status is one of Compliant, NonCompliant, NoProfile or Unknown. The compliance result
        property name differs across PowerCLI versions, so both ComplianceStatus and Status are
        read before giving up.
    #>
    param([Parameter(Mandatory=$true)]$VMHostObject)

    $profileObj = $null
    try { $profileObj = Get-VMHostProfile -Entity $VMHostObject -ErrorAction SilentlyContinue | Select-Object -First 1 } catch {}

    if ($null -eq $profileObj) {
        return [pscustomobject]@{ Status="NoProfile"; ProfileName=""; Details="No host profile is attached to this host." }
    }

    try {
        $result = @(Test-VMHostProfileCompliance -VMHost $VMHostObject -ErrorAction Stop) | Select-Object -First 1
    }
    catch {
        return [pscustomobject]@{ Status="Unknown"; ProfileName=$profileObj.Name; Details="Compliance test failed: $($_.Exception.Message)" }
    }

    if ($null -eq $result) {
        return [pscustomobject]@{ Status="Unknown"; ProfileName=$profileObj.Name; Details="Compliance test returned no result." }
    }

    $statusRaw = ""
    foreach ($prop in @("ComplianceStatus","Status")) {
        if ($result.PSObject.Properties.Name -contains $prop -and -not [string]::IsNullOrWhiteSpace([string]$result.$prop)) {
            $statusRaw = [string]$result.$prop
            break
        }
    }

    $details = ""
    foreach ($prop in @("IncomplianceElementList","ExtensionData")) {
        if ($result.PSObject.Properties.Name -contains $prop -and $null -ne $result.$prop) {
            try {
                $elements = @($result.IncomplianceElementList)
                if ($elements.Count -gt 0) {
                    $details = ($elements | ForEach-Object { [string]$_ } | Select-Object -First 5) -join ' | '
                }
            } catch {}
            break
        }
    }

    $status = switch -Regex ($statusRaw) {
        '^(?i)compliant$'    { "Compliant";    break }
        '^(?i)nonCompliant$' { "NonCompliant"; break }
        default              { if ([string]::IsNullOrWhiteSpace($statusRaw)) { "Unknown" } else { $statusRaw } }
    }

    return [pscustomobject]@{ Status=$status; ProfileName=$profileObj.Name; Details=$details }
}

function Confirm-HostProfileComplianceAndExitMaintenance {
    <#
    .SYNOPSIS
        Per host: verify host profile compliance, then take the host out of Maintenance mode.

    .DESCRIPTION
        Runs once the batch is confirmed back in vCenter. For each host in turn, while it is
        still in Maintenance mode, the attached host profile is tested:

          Compliant    - the host is taken out of Maintenance mode and the run moves on.
          NonCompliant - the operator is told to remediate (Auto Deploy or vCenter host profile
                         remediation) and presses CONTINUE to re-test. The host is never taken
                         out of Maintenance mode, and the run never advances, until it passes.
          NoProfile    - nothing to test; the operator chooses SKIP or exits.
          Unknown      - treated like NonCompliant, because an unreadable result is not a pass.

        Applies to every reboot path - UCS Manager, Intersight, and ESXi-only - since all three
        return the host through the same Maintenance mode cycle.
    #>
    param(
        [Parameter(Mandatory=$true)][array]$HostNames,
        [Parameter(Mandatory=$true)][string]$BatchNumber
    )

    if ((Test-DryRun) -or (Test-StageNoAck)) {
        Write-Host "DRY/STAGE: Would check host profile compliance for $($HostNames -join ', '), then exit Maintenance mode for each compliant host." -ForegroundColor Green
        foreach ($hostName in $HostNames) {
            Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result "DryRun" -Details "No compliance test issued."
        }
        return
    }

    foreach ($hostName in $HostNames) {
        Write-Host "" -ForegroundColor Cyan
        Write-Host "Host profile compliance check for '$hostName' (Batch $BatchNumber)..." -ForegroundColor Cyan

        $attempt = 0
        while ($true) {
            $attempt++
            $hostObj = Get-VMHost -Name $hostName -ErrorAction Stop
            $state = Get-VMHostProfileComplianceState -VMHostObject $hostObj

            Write-Host ("  Host: {0}  ConnectionState: {1}  Profile: {2}  Compliance: {3}" -f $hostObj.Name, $hostObj.ConnectionState, $(if($state.ProfileName){$state.ProfileName}else{"<none>"}), $state.Status) -ForegroundColor Cyan
            if (-not [string]::IsNullOrWhiteSpace($state.Details)) {
                Write-Host "  Detail: $($state.Details)" -ForegroundColor Yellow
            }

            if ($state.Status -eq "Compliant") {
                Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result "Compliant" -Details "Profile '$($state.ProfileName)' compliant after $attempt check(s)."
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
            Write-Host "  The host stays in Maintenance mode and this batch will not advance until it passes." -ForegroundColor Yellow
            [void](Read-ChoiceExit -Message "Type CONTINUE once '$hostName' has been remediated to re-check compliance, or EXIT" -AllowedChoices @("CONTINUE") -ExitMessage "Stopped at host profile compliance for '$hostName'.")
            Add-SummaryRecord -Stage "HostProfileCompliance" -Batch $BatchNumber -HostName $hostName -Action "Check compliance" -Result $state.Status -Details "Attempt $attempt not compliant; operator requested re-check."
        }

        # Only reached once the host is compliant, or explicitly accepted with no profile attached.
        $hostObj = Get-VMHost -Name $hostName -ErrorAction Stop
        if ($hostObj.ConnectionState -eq "Maintenance") {
            if ($Global:AutoExitMaintenanceMode) {
                Write-Host "  Taking '$hostName' out of Maintenance mode." -ForegroundColor Green
                Set-VMHost -VMHost $hostObj -State Connected -Confirm:$false -ErrorAction Stop | Out-Null
                Add-SummaryRecord -Stage "ExitMaintenance" -Batch $BatchNumber -HostName $hostName -Action "Exit Maintenance mode" -Result "Sent" -Details "Exited after host profile compliance passed."
            }
            else {
                Write-Host "  AutoExitMaintenanceMode is disabled - leaving '$hostName' in Maintenance mode." -ForegroundColor Yellow
                Add-SummaryRecord -Stage "ExitMaintenance" -Batch $BatchNumber -HostName $hostName -Action "Exit Maintenance mode" -Result "Skipped" -Details "AutoExitMaintenanceMode disabled."
            }
        }
    }
}

function Invoke-RebootSafetyWindow {
    param([int]$TimeoutSeconds=90,[Parameter(Mandatory=$true)][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)
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

function Move-PoweredOffAndSuspendedVMsForBatch {
    param([Parameter(Mandatory=$true)][array]$CurrentBatchNames,[Parameter(Mandatory=$true)]$Cluster)
    if ((Test-DryRun) -or (Test-StageNoAck)) { Write-Host "DRY/STAGE: Would move powered-off/suspended VMs from batch hosts where applicable." -ForegroundColor Green; return $true }
    $destinationHosts = @(Get-VMHost -Location $Cluster | Where-Object { $_.ConnectionState -eq "Connected" -and ($CurrentBatchNames -notcontains $_.Name) })
    if ($destinationHosts.Count -eq 0) { Stop-WithMessage "No connected non-batch destination hosts available for powered-off/suspended VM movement." }
    foreach ($hostName in $CurrentBatchNames) {
        $vms = @(Get-VMHost -Name $hostName | Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.PowerState -eq "PoweredOff" -or $_.PowerState -eq "Suspended" })
        foreach ($vm in $vms) {
            $dest = $destinationHosts | Get-Random
            Move-VM -VM $vm -Destination $dest -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
    return $true
}

function Request-MaintenanceModeForBatch {
    param([Parameter(Mandatory=$true)][array]$HostNames,[Parameter(Mandatory=$true)][string]$Mode)
    if ((Test-DryRun) -or (Test-StageNoAck)) { Write-Host "DRY/STAGE: Would request Maintenance mode for $($HostNames -join ', ')." -ForegroundColor Green; return }
    foreach ($hostName in $HostNames) {
        $hostObj = Get-VMHost -Name $hostName -ErrorAction Stop
        if ($hostObj.ConnectionState -eq "Connected") {
            if ($Mode -eq "PARALLEL") { Set-VMHost -VMHost $hostObj -State Maintenance -Evacuate -RunAsync -Confirm:$false -ErrorAction Stop | Out-Null }
            else { Set-VMHost -VMHost $hostObj -State Maintenance -Evacuate -Confirm:$false -ErrorAction Stop | Out-Null }
        }
    }
}

function Wait-BatchMaintenanceMode {
    param([Parameter(Mandatory=$true)][array]$HostNames,[int]$TimeoutMinutes=60)
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
    param([Parameter(Mandatory=$true)][array]$HostNames)
    return @(foreach ($hostName in $HostNames) { $h = Get-VMHost -Name $hostName -ErrorAction SilentlyContinue; if($h){[pscustomobject]@{Host=$h.Name;Found=$true;ConnectionState=[string]$h.ConnectionState;PowerState=[string]$h.PowerState;Build=$h.Build}}else{[pscustomobject]@{Host=$hostName;Found=$false;ConnectionState="NotFound";PowerState="Unknown";Build=""}} })
}

function Wait-BatchReconnectAfterReboot {
    param([Parameter(Mandatory=$true)][array]$HostNames,[int]$InitialWaitMinutes,[string]$ModeLabel)
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
        $summary | Format-Table -AutoSize
        $bad = @($summary | Where-Object { $_.ConnectionState -ne "Connected" -and $_.ConnectionState -ne "Maintenance" })
        if ($bad.Count -eq 0) { return $summary }
        $choice = Read-ChoiceExit -Message "Reconnect incomplete. Choose RECHECK, OVERRIDE, or STOP" -AllowedChoices @("RECHECK","OVERRIDE","STOP")
        if ($choice -eq "STOP") { return $null }
        if ($choice -eq "OVERRIDE") { return $summary }
    } while ($true)
}

function Invoke-ClusterUpgradeWorkflow {
    param([Parameter(Mandatory=$true)]$Cluster)
    Write-Host "Selected cluster: $($Cluster.Name)" -ForegroundColor Green
    Select-RunMode
    Select-UpgradeMode
    if ((Test-StageNoAck) -and $Global:UpgradeMode -ne "ESXI_UCS_FIRMWARE") { Stop-WithMessage "STAGE_NO_ACK is only valid with UCSM firmware mode." }

    $allClusterHosts = @(Get-VMHost -Location $Cluster | Sort-Object Name)
    if ($allClusterHosts.Count -eq 0) { Stop-WithMessage "No hosts found in selected cluster." }

    if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") { Build-InfrastructureHostMapping -Hosts $allClusterHosts }

    if ((Read-YesNoExit -Message "Have all manual health checks/change gates been completed and accepted?") -ne "YES") { Stop-WithMessage "Manual health checks were not confirmed." }

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

    if ($patchCandidateHosts.Count -eq 0) {
        if ($Global:UpgradeMode -eq "ESXI_UCS_FIRMWARE") {
            Stop-WithMessage "No Connected firmware candidate hosts available. Firmware mode only requires hosts to be Connected; it does not exclude hosts already on the target ESXi build."
        }
        else {
            Stop-WithMessage "No Connected ESXi patch candidate hosts available after excluding hosts already on the target ESXi build."
        }
    }

    $batchMode = Select-BatchMode

    if (Test-StageNoAck) {
        # Save-only mode does not enter Maintenance mode, does not move VMs, does not acknowledge UCSM reboot, and does not reboot hosts.
        # Skip the maintenance method prompt to keep the flow simple and avoid confusion.
        $maintenanceModeMethod = "NOT_USED_STAGE_NO_ACK"
        Write-Host "SAVE ONLY / NO ACKNOWLEDGEMENT selected: skipping Maintenance mode method selection." -ForegroundColor Green
    }
    else {
        $maintenanceModeChoice = Read-ChoiceExit -Message "Select Maintenance mode execution method" -AllowedChoices @("SEQUENTIAL","PARALLEL","1","2")
        $maintenanceModeMethod = if ($maintenanceModeChoice -eq "1") { "SEQUENTIAL" } elseif ($maintenanceModeChoice -eq "2") { "PARALLEL" } else { $maintenanceModeChoice }
    }

    $pendingHosts = New-Object System.Collections.ArrayList
    foreach ($hostObj in $patchCandidateHosts) { [void]$pendingHosts.Add($hostObj.Name) }
    $batchNumber = 0

    while ($pendingHosts.Count -gt 0) {
        $batchNumber++

        # Health and capacity are re-evaluated for every batch, not once up front, so hosts
        # returning to service and any drift in cluster state are both reflected.
        $batchSize = 1
        if ($batchMode -eq "AUTO" -and -not (Test-StageNoAck)) {
            $healthBefore = Get-ClusterHealthReport -Cluster $Cluster
            if (-not $healthBefore.IsHealthy) {
                Write-Host "`nCluster health check failed before Batch ${batchNumber}:" -ForegroundColor Yellow
                $healthBefore.Reasons | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
                Add-SummaryRecord -Stage "ClusterHealth" -Batch $batchNumber -HostName "" -Action "Pre-batch health check" -Result "Failed" -Details ($healthBefore.Reasons -join ' | ')
                Stop-WithMessage "Cluster '$($Cluster.Name)' is not healthy enough to start Batch $batchNumber."
            }

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

        $currentBatchNames = @($pendingHosts | Select-Object -First $batchSize)
        Write-Host "`nBATCH ${batchNumber} ($batchMode, $($currentBatchNames.Count) host(s)): $($currentBatchNames -join ', ')" -ForegroundColor Cyan

        if (Test-StageNoAck) {
            $currentBatchUcsNames = @($currentBatchNames | Where-Object { -not $Global:IntersightHostMap.ContainsKey($_) })
            $currentBatchIntersightNames = @($currentBatchNames | Where-Object { $Global:IntersightHostMap.ContainsKey($_) })
            if ($currentBatchUcsNames.Count -gt 0) {
                Set-UcsFirmwarePolicyForBatch -HostNames $currentBatchUcsNames -BatchNumber $batchNumber
                Get-UcsPendingRebootObjectsForBatch -HostNames $currentBatchUcsNames | Select-Object Host,UcsTarget,ServiceProfileDn,PendingAckFound,AckDn | Format-Table -AutoSize
            }
            if ($currentBatchIntersightNames.Count -gt 0) {
                # STAGE_NO_ACK never acknowledges/reboots - see the Test-StageNoAck branch inside
                # Invoke-IntersightAcceptAndRebootImmediateForBatch.
                Invoke-IntersightAcceptAndRebootImmediateForBatch -HostNames $currentBatchIntersightNames -BatchNumber $batchNumber
            }
            foreach ($hostName in $currentBatchNames) { [void]$pendingHosts.Remove($hostName) }
            continue
        }

        Move-PoweredOffAndSuspendedVMsForBatch -CurrentBatchNames $currentBatchNames -Cluster $Cluster | Out-Null
        Request-MaintenanceModeForBatch -HostNames $currentBatchNames -Mode $maintenanceModeMethod
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

        # Post-batch health gate. Passing it is what allows the run to move to the next batch
        # on its own; failing it stops the run rather than compounding a problem.
        if (-not (Test-DryRun) -and -not (Test-StageNoAck)) {
            # Every host should now be back in service, so nothing is excluded - unless the
            # operator has turned off automatic Maintenance mode exit, in which case the hosts
            # just completed are expected to still be in Maintenance and are not a fault.
            $ignoreForHealth = if ($Global:AutoExitMaintenanceMode) { @() } else { @($currentBatchNames) }
            $healthAfter = Get-ClusterHealthReport -Cluster $Cluster -IgnoreHostNames $ignoreForHealth
            if ($healthAfter.IsHealthy) {
                Write-Host "Cluster health confirmed after Batch $batchNumber." -ForegroundColor Green
                Add-SummaryRecord -Stage "ClusterHealth" -Batch $batchNumber -HostName "" -Action "Post-batch health check" -Result "Healthy" -Details "Continuing automatically to the next batch."
            }
            else {
                Write-Host "`nCluster health check failed after Batch ${batchNumber}:" -ForegroundColor Yellow
                $healthAfter.Reasons | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
                Add-SummaryRecord -Stage "ClusterHealth" -Batch $batchNumber -HostName "" -Action "Post-batch health check" -Result "Failed" -Details ($healthAfter.Reasons -join ' | ')
                Stop-WithMessage "Cluster '$($Cluster.Name)' is not healthy after Batch $batchNumber. Resolve before continuing."
            }
        }

        Write-Host "Batch $batchNumber completed. Remaining hosts: $($pendingHosts.Count)" -ForegroundColor Green
        if ($pendingHosts.Count -gt 0) {
            Write-Host "Continuing automatically to Batch $($batchNumber + 1)." -ForegroundColor Green
        }
    }
    Add-SummaryRecord -Stage "ClusterComplete" -Batch "" -HostName "" -Action "Complete cluster" -Result "Completed" -Details $Cluster.Name
}

# -----------------------------
# Main loop including Step 27
# -----------------------------

$global:vCenter = $null
$continueScript = $true
try {
    Confirm-RunPrerequisites

    while ($continueScript) {
        if (-not $global:vCenter) {
            $vCenterInput = Read-Host "Enter vCenter FQDN or IP, or press Enter to use $DefaultVCenter"
            if ($vCenterInput -eq "") { $global:vCenter = $DefaultVCenter } else { $global:vCenter = $vCenterInput }
            Write-Host "Connecting to vCenter: $global:vCenter" -ForegroundColor Cyan
            Connect-VIServer -Server $global:vCenter -ErrorAction Stop | Out-Null
            Write-Host "Connected to vCenter." -ForegroundColor Green
        }
        $clusters = @(Get-Cluster | Sort-Object Name)
        if ($clusters.Count -eq 0) { Stop-WithMessage "No clusters found in vCenter." }
        $cluster = Select-ClusterInteractive -Clusters $clusters
        try { Invoke-ClusterUpgradeWorkflow -Cluster $cluster } catch { if ($_.Exception.Message -notin @("SAFE_EXIT","STOP_WORKFLOW")) { throw } } finally { Export-RunSummary }

        Write-Host "`nSTEP 27 - COMPLETE SCRIPT / NEXT ACTION" -ForegroundColor Cyan
        Write-Host "  1. Select another cluster in the same vCenter`n  2. Connect to a different vCenter`n  3. Exit script" -ForegroundColor Yellow
        $next = Read-ChoiceExit -Message "Select next action" -AllowedChoices @("1","2","3") -ExitMessage "Stopped at Step 27."
        if ($next -eq "1") { continue }
        if ($next -eq "2") { try { Disconnect-VIServer -Server $global:vCenter -Confirm:$false | Out-Null } catch {}; $global:vCenter = $null; continue }
        if ($next -eq "3") { $continueScript = $false }
    }
} catch {
    Write-Host "`nUnhandled script error: $($_.Exception.Message)" -ForegroundColor Red
    Add-SummaryRecord -Stage "UnhandledError" -Batch "" -HostName "" -Action "Script error" -Result "Failed" -Details $_.Exception.Message
} finally {
    Export-RunSummary
    try { foreach ($key in @($Global:UcsSessions.Keys)) { try { Disconnect-Ucs -Ucs $Global:UcsSessions[$key] -ErrorAction SilentlyContinue | Out-Null } catch {} } } catch {}
    # Intersight.PowerShell holds process-wide configuration rather than a session object, so there
    # is nothing to disconnect. Clear the in-memory key material instead.
    $Global:IntersightSession = $null
    $Global:IntersightApiKeyId = ""
    $Global:IntersightApiKeyFilePath = ""
    try { if ($global:vCenter) { Disconnect-VIServer -Server $global:vCenter -Confirm:$false | Out-Null; Write-Host "Disconnected from vCenter." -ForegroundColor Green } } catch { Write-Host "Could not disconnect cleanly from vCenter." -ForegroundColor Yellow }
}
