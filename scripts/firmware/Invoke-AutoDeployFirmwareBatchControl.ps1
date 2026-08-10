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
    normalised CDP/LLDP system name is checked against the Name column in $IntersightCsvPath (default
    C:\temp\intersightfabric.csv). A match detects that host as Intersight-managed: the script finds the
    server profile, checks for the "Inconsistent" state caused by a firmware policy update, accepts it
    (including the compulsory disruption tick box), and reboots the blade immediately - scoped to the
    current batch only, same as the existing UCSM acknowledgement. Any host with no CSV match is detected
    as UCS Manager-managed and falls through to the existing UCS Manager (classic) logic unchanged. UCS
    PowerTool is only required/loaded if at least one host in the cluster is detected as UCS-managed.

.NOTES
    - Credentials/API keys are kept in memory only.
    - Intersight only supports API-key + HTTP-signature auth, not username/password - see the
      $Global:IntersightApiKeyId / $Global:IntersightApiKeyFilePath notes in User Settings.
    - DRYRUN is the default.
    - UCSM acknowledgement and Intersight accept/reboot are each scoped to their own batch hosts only.
    - The Intersight accept + reboot-immediately step has no interactive confirmation gate by design
      (it runs whenever DRYRUN/STAGE_NO_ACK are not active) - the pre-reboot safety window still covers
      the whole batch. Consider that against the typed ACK-BATCH-N gate still used on the UCSM side.
    - Validate Cisco UCS PowerTool cmdlet names, and Intersight.PowerShell cmdlet/parameter names
      (marked TODO-VALIDATE), in your installed module versions before LIVE RUN.
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
$Global:IntersightBaseUrl = "https://intersight.com/api/v1"   # override for a PVA appliance, e.g. https://<pva-fqdn>/api/v1
# NOTE: Intersight's API only supports API-key + HTTP-signature auth (key ID + private key file) -
# there is no username/password endpoint. Get-IntersightCredentialIfNeeded below still prompts
# interactively and holds the material in memory only, matching the hardened UCSM pattern, but what
# it collects is an API Key ID and the path to the associated private key (.pem), not a password.
$Global:IntersightApiKeyId = ""
$Global:IntersightApiKeyFilePath = ""
$Global:IntersightSession = $null
$Global:IntersightServerList = @{}
$Global:IntersightHostMap = @{}

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
$Global:ReconnectCredential = $null
$Global:PromptForReconnectPasswordWhenNeeded = $false
$Global:AutoExitMaintenanceMode = $true

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

    # Reset script-local UCS session caches after UCS cleanup.
    $Global:UcsSessions = @{}
    $Global:UcsCandidateCache = @{}

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
        Write-Host "Credential-based UCSM login failed for '$target': $($_.Exception.Message)" -ForegroundColor Yellow
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

function Resolve-UcsTargetForHost {
    param([Parameter(Mandatory=$true)]$VMHostObject)

    $discovery = @(Get-EsxiDiscoveryProtocolInfo -VMHostObject $VMHostObject)
    $preferred = @($discovery | Where-Object { $_.Vmnic -in @("vmnic0","vmnic1","vmnic2","vmnic3") } | Sort-Object Vmnic | Select-Object -First 1)
    if ($preferred.Count -eq 0 -and $discovery.Count -gt 0) { $preferred = @($discovery | Select-Object -First 1) }

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
        $sp = Get-UcsServiceProfile -Ucs $ucsSession -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $short -or $_.Dn -like "*/ls-$short" -or $_.Dn -like "*/$short" } | Select-Object -First 1
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
        $discovery = @(Get-EsxiDiscoveryProtocolInfo -VMHostObject $hostObj)
        $preferred = @($discovery | Where-Object { $_.Vmnic -in @("vmnic0","vmnic1","vmnic2","vmnic3") } | Sort-Object Vmnic | Select-Object -First 1)
        if ($preferred.Count -eq 0 -and $discovery.Count -gt 0) { $preferred = @($discovery | Select-Object -First 1) }
        $systemName = if ($preferred.Count -gt 0) { $preferred[0].SystemName } else { "" }

        if (-not [string]::IsNullOrWhiteSpace($systemName) -and (Test-HostInIntersightList -CdpSystemName $systemName)) {
            $key = Convert-FiSystemNameToUcsCandidate -SystemName $systemName
            $csvRow = $Global:IntersightServerList[$key]
            $Global:IntersightHostMap[$hostObj.Name] = [pscustomobject]@{
                Host            = $hostObj.Name
                Vmnic           = $preferred[0].Vmnic
                CdpSystemName   = $systemName
                IntersightCsvRow = $csvRow
                HostObject      = $hostObj
            }
            [void]$intersightRoutedRows.Add([pscustomobject]@{ Host=$hostObj.Name; CdpSystemName=$systemName; IntersightCsvName=$csvRow.Name; Infrastructure="Intersight" })
        }
        else {
            [void]$ucsOnlyHosts.Add($hostObj)
        }
    }

    if ($intersightRoutedRows.Count -gt 0) {
        Write-Host "Detected as Intersight-managed (CDP/LLDP name matched the Name column in $IntersightCsvPath):" -ForegroundColor Green
        $intersightRoutedRows | Format-Table -AutoSize
        foreach ($row in $intersightRoutedRows) {
            Add-SummaryRecord -Stage "InfrastructureDetection" -Batch "" -HostName $row.Host -Action "Detect infrastructure" -Result "Intersight" -Details "CdpSystemName=$($row.CdpSystemName)."
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
        $discovery = @(Get-EsxiDiscoveryProtocolInfo -VMHostObject $hostObj)
        $preferred = @($discovery | Where-Object { $_.Vmnic -in @("vmnic0","vmnic1","vmnic2","vmnic3") } | Sort-Object Vmnic | Select-Object -First 1)
        if ($preferred.Count -eq 0 -and $discovery.Count -gt 0) { $preferred = @($discovery | Select-Object -First 1) }

        if ($preferred.Count -gt 0) {
            $systemName = $preferred[0].SystemName
            $candidate = (Get-UcsCandidateListFromSystemName -SystemName $systemName | Select-Object -First 1)
            [void]$discoveryRows.Add([pscustomobject]@{
                Host          = $hostObj.Name
                Vmnic         = $preferred[0].Vmnic
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
    param([Parameter(Mandatory=$true)][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)

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
            $choice = Read-ChoiceExit -Message "Firmware policy verification failed for one or more hosts. Choose RECHECK or STOP" -AllowedChoices @("RECHECK","STOP")
            if ($choice -eq "STOP") { Stop-WithMessage "Firmware policy verification failed after set command." }
            if ($choice -eq "RECHECK") { return Set-UcsFirmwarePolicyForBatch -HostNames $HostNames -BatchNumber $BatchNumber }
        }
    }
}

function Get-UcsPendingRebootObjectsForBatch {
    param([Parameter(Mandatory=$true)][array]$HostNames)
    $pendingRows = New-Object System.Collections.ArrayList
    foreach ($hostName in $HostNames) {
        $map = $Global:UcsHostMap[$hostName]
        $ucsSession = Get-UcsSessionForTarget -UcsTarget $map.UcsTarget
        $ackObject = $null
        try { $ackObject = Get-UcsLsmaintAck -Ucs $ucsSession -ErrorAction SilentlyContinue | Where-Object { $_.Dn -like "$($map.ServiceProfileDn)/*" -or $_.Dn -eq "$($map.ServiceProfileDn)/ack" } | Select-Object -First 1 } catch {}
        [void]$pendingRows.Add([pscustomobject]@{ Host=$hostName; UcsTarget=$map.UcsTarget; ServiceProfileDn=$map.ServiceProfileDn; PendingAckFound=($null -ne $ackObject); AckDn=if($ackObject){$ackObject.Dn}else{""}; AckObject=$ackObject })
    }
    return @($pendingRows)
}

function Invoke-UcsPendingAckForBatch {
    param([Parameter(Mandatory=$true)][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)
    $pendingRows = @(Get-UcsPendingRebootObjectsForBatch -HostNames $HostNames)
    $pendingRows | Select-Object Host,UcsTarget,ServiceProfileDn,PendingAckFound,AckDn | Format-Table -AutoSize
    if (Test-DryRun) { Write-Host "DRY RUN: Would acknowledge only listed current-batch UCSM pending objects." -ForegroundColor Green; return }
    $requiredText = "ACK-BATCH-$BatchNumber"
    $confirm = (Read-Host "Type $requiredText to acknowledge UCSM reboot for Batch $BatchNumber only, or type EXIT").Trim().ToUpper()
    if ($confirm -eq "EXIT") { Stop-SafeExit -Message "Exited before UCSM pending reboot acknowledgement." }
    if ($confirm -ne $requiredText) { Stop-WithMessage "UCSM acknowledgement was not confirmed. Expected '$requiredText'." }
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
    if ($null -eq (Get-Command -Name Connect-IntersightApi -ErrorAction SilentlyContinue) -and
        $null -eq (Get-Command -Name Get-IntersightServerProfile -ErrorAction SilentlyContinue)) {
        Stop-WithMessage "Intersight.PowerShell module was not found (Connect-IntersightApi / Get-IntersightServerProfile). Import Intersight.PowerShell before running against hosts mapped to Intersight."
    }
}

function Get-IntersightCredentialIfNeeded {
    if ($Global:IntersightSession) { return }
    if ([string]::IsNullOrWhiteSpace($Global:IntersightApiKeyId)) {
        $Global:IntersightApiKeyId = (Read-Host "Enter Intersight API Key ID").Trim()
    }
    if ([string]::IsNullOrWhiteSpace($Global:IntersightApiKeyFilePath)) {
        $Global:IntersightApiKeyFilePath = (Read-Host "Enter path to the Intersight API private key (.pem) file").Trim()
    }
    if (-not (Test-Path -Path $Global:IntersightApiKeyFilePath)) {
        Stop-WithMessage "Intersight private key file not found at '$Global:IntersightApiKeyFilePath'."
    }
}

function Connect-IntersightTarget {
    if ($null -ne $Global:IntersightSession) { return $Global:IntersightSession }
    Assert-IntersightPowerShellAvailable
    Get-IntersightCredentialIfNeeded
    Write-Host "Connecting to Intersight: $Global:IntersightBaseUrl" -ForegroundColor Cyan
    try {
        # TODO-VALIDATE: confirm exact parameter names for your installed Intersight.PowerShell version.
        $Global:IntersightSession = Connect-IntersightApi -BasePath $Global:IntersightBaseUrl -ApiKeyId $Global:IntersightApiKeyId -ApiKeyFilePath $Global:IntersightApiKeyFilePath -ErrorAction Stop
        Write-Host "Connected to Intersight." -ForegroundColor Green
        return $Global:IntersightSession
    } catch {
        Stop-WithMessage "Intersight login failed: $($_.Exception.Message)"
    }
}

function Import-IntersightServerCsv {
    if ($Global:IntersightServerList.Count -gt 0) { return }
    if ([string]::IsNullOrWhiteSpace($IntersightCsvPath)) { return }
    if (-not (Test-Path -Path $IntersightCsvPath)) { Stop-WithMessage "Intersight server CSV not found at '$IntersightCsvPath'." }

    Write-Host "Loading Intersight server list from: $IntersightCsvPath" -ForegroundColor Cyan
    $rows = @(Import-Csv -Path $IntersightCsvPath)
    Write-Host "Raw CSV rows read from file: $($rows.Count)" -ForegroundColor Cyan

    $skippedBlankName = 0
    $duplicateKeys = New-Object System.Collections.Generic.List[string]

    foreach ($row in $rows) {
        if (-not ($row.PSObject.Properties.Name -contains "Name") -or [string]::IsNullOrWhiteSpace($row.Name)) { $skippedBlankName++; continue }
        # Same normalisation as the UCSM CDP/LLDP path, so both routes key off the same identity.
        # The Intersight Fabrics export uses "Name" for the discovered/CDP-LLDP-matching system name.
        $key = Convert-FiSystemNameToUcsCandidate -SystemName $row.Name
        if ([string]::IsNullOrWhiteSpace($key)) { $skippedBlankName++; continue }
        if ($Global:IntersightServerList.ContainsKey($key)) { $duplicateKeys.Add($row.Name) }
        $Global:IntersightServerList[$key] = $row
    }

    Write-Host "Intersight server list loaded: $($Global:IntersightServerList.Count) unique row(s) out of $($rows.Count) raw CSV row(s)." -ForegroundColor Green
    if ($skippedBlankName -gt 0) {
        Write-Host "WARNING: $skippedBlankName row(s) were skipped because the Name column was blank or normalised to an empty value." -ForegroundColor Yellow
    }
    if ($duplicateKeys.Count -gt 0) {
        Write-Host "WARNING: $($duplicateKeys.Count) row(s) normalised to a Name already seen earlier in the CSV - the later row overwrote the earlier one for that key:" -ForegroundColor Yellow
        $duplicateKeys | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
    }
    if ($rows.Count -gt 0 -and $Global:IntersightServerList.Count -lt $rows.Count -and $skippedBlankName -eq 0 -and $duplicateKeys.Count -eq 0) {
        Write-Host "NOTE: loaded row count is lower than raw row count with no blank/duplicate rows detected - re-check the CSV encoding/delimiter if this looks wrong." -ForegroundColor Yellow
    }
    Add-SummaryRecord -Stage "IntersightCsvImport" -Batch "" -HostName "" -Action "Import CSV" -Result "Completed" -Details "RawRows=$($rows.Count); Loaded=$($Global:IntersightServerList.Count); SkippedBlank=$skippedBlankName; Duplicates=$($duplicateKeys.Count)."
}

function Test-HostInIntersightList {
    param([Parameter(Mandatory=$true)][string]$CdpSystemName)
    if ($Global:IntersightServerList.Count -eq 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($CdpSystemName)) { return $false }
    $key = Convert-FiSystemNameToUcsCandidate -SystemName $CdpSystemName
    return $Global:IntersightServerList.ContainsKey($key)
}

function Resolve-IntersightServerProfileForHost {
    param([Parameter(Mandatory=$true)][string]$HostName,[Parameter(Mandatory=$true)]$IntersightCsvRow)

    Connect-IntersightTarget | Out-Null
    $short = Get-ShortHostName -HostName $HostName
    # ServerProfileName is optional in the CSV - if the export only has the Name column, the same
    # value is used as both the match key and the Intersight server profile name to look up.
    $profileName = if (-not [string]::IsNullOrWhiteSpace($IntersightCsvRow.ServerProfileName)) { $IntersightCsvRow.ServerProfileName }
                   elseif (-not [string]::IsNullOrWhiteSpace($IntersightCsvRow.Name)) { $IntersightCsvRow.Name }
                   else { $short }

    try {
        if ($IntersightCsvRow.PSObject.Properties.Name -contains "Moid" -and -not [string]::IsNullOrWhiteSpace($IntersightCsvRow.Moid)) {
            $sp = Get-IntersightServerProfile -Moid $IntersightCsvRow.Moid -ErrorAction Stop
        } else {
            $sp = Get-IntersightServerProfile -Filter "Name eq '$profileName'" -ErrorAction Stop | Select-Object -First 1
        }
    } catch {
        Stop-WithMessage "Intersight server profile lookup failed for host '$HostName' (profile '$profileName'): $($_.Exception.Message)"
    }

    if ($null -eq $sp) { Stop-WithMessage "No Intersight server profile found for host '$HostName' (profile '$profileName')." }
    return $sp
}

function Get-IntersightProfileInconsistencyState {
    param([Parameter(Mandatory=$true)]$ServerProfile)

    # PolicyConfigContext.ConfigState surfaces "Inconsistent" when the deployed config (including a
    # firmware/host-firmware-package policy) no longer matches what is actually running on the server.
    $configState = $null
    if ($ServerProfile.PSObject.Properties.Name -contains "ConfigContext" -and $null -ne $ServerProfile.ConfigContext) {
        $configState = $ServerProfile.ConfigContext.ConfigState
    }
    $isInconsistent = ($configState -eq "Inconsistent")
    return [pscustomobject]@{
        ConfigState    = $configState
        IsInconsistent = $isInconsistent
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

    foreach ($row in $pendingRows) {
        if (-not $row.IsInconsistent) {
            Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch $BatchNumber -HostName $row.Host -Action "Accept + reboot immediately" -Result "Skipped" -Details "ConfigState=$($row.ConfigState) - not Inconsistent, nothing to accept."
            continue
        }

        Write-Host "Intersight: accepting inconsistency and rebooting immediately for '$($row.Host)' (profile '$($row.ServerProfile)')." -ForegroundColor Yellow
        try {
            # TODO-VALIDATE against your Intersight.PowerShell version:
            #   - New-IntersightFirmwareUpgrade (or Set-IntersightServerProfile -Action Deploy) is the
            #     call that actually triggers the upgrade/deploy.
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

function Get-ClusterSafeBatchSizeStrict {
    param([Parameter(Mandatory=$true)][array]$Hosts,[Parameter(Mandatory=$true)]$Cluster,[double]$SafetyBuffer=0.85)
    $connectedHosts = @($Hosts | Where-Object { $_.ConnectionState -eq "Connected" })
    if ($connectedHosts.Count -le 1) { return [pscustomobject]@{ SafeBatchSize=1; Reason="Only one connected candidate host available."; Diagnostics=@() } }
    $maxByRemainingHosts = [int]($connectedHosts.Count - 1)
    $safeBatch = [int](@($maxByRemainingHosts,[int]$MaxAbsoluteBatchSize) | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum)
    if ($safeBatch -lt 1) { $safeBatch = 1 }
    return [pscustomobject]@{ SafeBatchSize=$safeBatch; Reason="Conservative maximum based on connected hosts and max batch cap."; Diagnostics=@() }
}

function Confirm-BatchSize {
    param([Parameter(Mandatory=$true)][int]$CalculatedSize,[Parameter(Mandatory=$true)][int]$CandidateCount)
    do {
        $manualBatch = (Read-Host "Press Enter to accept $CalculatedSize, enter LOWER batch size, or EXIT").Trim().ToUpper()
        if ($manualBatch -eq "EXIT") { Stop-SafeExit -Message "Stopped before accepting batch size." }
        if ($manualBatch -eq "") { return $CalculatedSize }
        if ($manualBatch -match '^\d+$' -and [int]$manualBatch -ge 1 -and [int]$manualBatch -le $CalculatedSize) { return [int]$manualBatch }
        Write-Host "Invalid value." -ForegroundColor Yellow
    } while ($true)
}

function Invoke-RebootSafetyWindow {
    param([int]$TimeoutSeconds=90,[Parameter(Mandatory=$true)][array]$HostNames,[Parameter(Mandatory=$true)][string]$BatchNumber)
    Write-Host "`nBATCH REBOOT SAFETY CHECK: Batch $BatchNumber reboot/action starts in $TimeoutSeconds seconds." -ForegroundColor Yellow
    Write-Host "Press C to continue immediately, E to exit safely, or wait for auto-continue." -ForegroundColor Cyan
    $endTime = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $endTime) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
            if ($key -eq "C") { return $true }
            if ($key -eq "E") { Stop-SafeExit -Message "Exited during pre-reboot safety window." }
        }
        Start-Sleep -Milliseconds 250
    }
    return $true
}

function Move-PoweredOffAndSuspendedVMsForBatch {
    param([Parameter(Mandatory=$true)][array]$CurrentBatchNames,[Parameter(Mandatory=$true)]$Cluster)
    if (Test-DryRun -or Test-StageNoAck) { Write-Host "DRY/STAGE: Would move powered-off/suspended VMs from batch hosts where applicable." -ForegroundColor Green; return $true }
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
    if (Test-DryRun -or Test-StageNoAck) { Write-Host "DRY/STAGE: Would request Maintenance mode for $($HostNames -join ', ')." -ForegroundColor Green; return }
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
    if (Test-DryRun -or Test-StageNoAck) { return @(foreach ($name in $HostNames) { Get-VMHost -Name $name -ErrorAction SilentlyContinue }) }
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
    if (Test-DryRun -or Test-StageNoAck) { return (Get-BatchConnectionStateSummary -HostNames $HostNames) }
    Write-Host "$ModeLabel initial wait: $InitialWaitMinutes minutes. Press R to recheck early, E to exit." -ForegroundColor Yellow
    $endTime = (Get-Date).AddMinutes($InitialWaitMinutes)
    while ((Get-Date) -lt $endTime) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
            if ($key -eq "E") { Stop-SafeExit -Message "Stopped during post-reboot wait." }
            if ($key -eq "R") { break }
        }
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

    $safeInfo = Get-ClusterSafeBatchSizeStrict -Hosts $patchCandidateHosts -Cluster $Cluster -SafetyBuffer $ResourceSafetyBuffer
    $safeBatchSize = Confirm-BatchSize -CalculatedSize ([int]$safeInfo.SafeBatchSize) -CandidateCount $patchCandidateHosts.Count

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
        $currentBatchNames = @($pendingHosts | Select-Object -First $safeBatchSize)
        Write-Host "`nBATCH ${batchNumber}: $($currentBatchNames -join ', ')" -ForegroundColor Cyan

        if (Test-StageNoAck) {
            $requiredText = "SAVE-BATCH-$batchNumber"
            $confirm = (Read-Host "Type $requiredText to save UCSM firmware policy for this batch only without acknowledgement, or type EXIT").Trim().ToUpper()
            if ($confirm -eq "EXIT") { Stop-SafeExit -Message "Exited before UCSM save-only change." }
            if ($confirm -ne $requiredText) { Stop-WithMessage "Save-only confirmation failed." }
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

        if ($Global:AutoExitMaintenanceMode -and -not (Test-DryRun) -and -not (Test-StageNoAck)) {
            foreach ($hostName in $currentBatchNames) {
                $hostObj = Get-VMHost -Name $hostName -ErrorAction SilentlyContinue
                if ($null -ne $hostObj -and $hostObj.ConnectionState -eq "Maintenance") { Set-VMHost -VMHost $hostObj -State Connected -Confirm:$false -ErrorAction Stop | Out-Null }
            }
        }

        foreach ($hostName in $currentBatchNames) { [void]$pendingHosts.Remove($hostName) }
        Write-Host "Batch $batchNumber completed. Remaining hosts: $($pendingHosts.Count)" -ForegroundColor Green
    }
    Add-SummaryRecord -Stage "ClusterComplete" -Batch "" -HostName "" -Action "Complete cluster" -Result "Completed" -Details $Cluster.Name
}

# -----------------------------
# Main loop including Step 27
# -----------------------------

$global:vCenter = $null
$continueScript = $true
try {
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
    try { if ($Global:IntersightSession) { Disconnect-IntersightApi -ErrorAction SilentlyContinue | Out-Null } } catch {}
    try { if ($global:vCenter) { Disconnect-VIServer -Server $global:vCenter -Confirm:$false | Out-Null; Write-Host "Disconnected from vCenter." -ForegroundColor Green } } catch { Write-Host "Could not disconnect cleanly from vCenter." -ForegroundColor Yellow }
}
