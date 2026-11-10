<#
.SYNOPSIS
    Reads MECM (SCCM) OSD failure log bundles (.zip) and reports, per device, the hostname,
    build duration, the step that failed, and the most likely root cause.

.DESCRIPTION
    Read-only. Opens each failure bundle on the share in place with shared read access - nothing is
    extracted to disk, renamed, moved or deleted - and reviews EVERY text log inside it, not just
    smsts.log, so a failure that only explains itself in another log (NetSetup.log for a domain
    join, AppEnforce.log for an application exit code, setupact.log for an unattend problem) is
    still found and tied back to the step that failed.

    For each bundle it works out:

      Hostname      From the logs first (MDT/ZTIGather OSDComputerName, Panther unattend.xml,
                    NetSetup.log, smsts.log), then the bundle file name. The source is reported in
                    HostnameSource, and a WinPE-only MININT-* name is flagged.
      Duration      From the first to the last relevant smsts.log entry of the LAST task sequence
                    run in the log: run start to the failure line. Timestamps are taken as the wall
                    clock written in the log (see NOTES on WinPE time zones).
      FailedStep    From "Failed to run the action: <step>" and the related engine lines, falling
                    back to the last instruction started before the failure.
      ErrorCode     Normalised to 0x######## and decoded.
      RootCause     The most specific known failure signature found anywhere in the bundle, ranked
                    by specificity and by how close it sits to the failure. KnownIssues lists every
                    signature that matched.
      Evidence      The log lines that support the verdict, with file, line and time, plus the last
                    smsts.log error lines before the failure.

    Bundles can be narrowed by age (-LastHours / -Since, judged on the file's LastWriteTime on the
    share, which is when the failure was uploaded) and by computer name.

    One object is written to the pipeline per bundle. -OutputPath additionally writes a CSV
    summary, a CSV of evidence lines, a JSON copy and a self-contained HTML report for the engineer.

    Lines matching password/credential patterns are masked before they are reported, and the body of
    unattend.xml is never reported (it can hold the domain join account's password); only the
    ComputerName element is read from it.

.PARAMETER Path
    One or more folders holding failure bundles, or individual .zip files. Defaults to the Windows
    11 workstation failure share.

.PARAMETER LastHours
    Only bundles written to the share in the last N hours (for example 12, 24 or 48).

.PARAMETER Since
    Only bundles written to the share at or after this local date/time. Cannot be combined with
    -LastHours.

.PARAMETER ComputerName
    Only report these devices. Wildcards allowed. Matched against the bundle file name first (cheap,
    nothing opened); bundles whose name does not match are still opened when nothing at all matched
    by file name, and filtered on the hostname resolved from the logs.

.PARAMETER Recurse
    Search sub-folders of -Path as well.

.PARAMETER Filter
    File name filter for bundles. Default *.zip.

.PARAMETER HostnamePattern
    Regular expression with a named group 'Host', applied to the bundle file name (without
    extension) to derive the hostname when the logs do not name the device. The default takes
    everything up to the first underscore, space, dot, or a hyphen followed by six or more digits
    (a date stamp), so PC0123.2026-11-09_034325.zip, PC0123_20261109.zip, PC0123-20261109-1022.zip
    and PC0123.zip all give PC0123.

.PARAMETER IgnoreStepPattern
    Regular expression for steps whose failure is NOT the real fault - a failure-handling group's
    log copy, or a step that deliberately fails the task sequence after the logs are saved. When
    another failure exists in the run it is reported instead. Defaults cover common names such as
    "Force Failure", "Fail Task Sequence", "Copy Logs" and "Capture Logs"; set it to match your
    task sequence's own step names, or to '' to disable.

.PARAMETER MaxLogSizeMB
    Logs larger than this (uncompressed) inside a bundle are skipped and listed in Notes. Default 100.

.PARAMETER EvidenceLines
    How many smsts.log error lines before the failure to keep as evidence. Default 10.

.PARAMETER OutputPath
    Folder to write the CSV, JSON and HTML reports to. Created if missing. Nothing is written to disk
    when omitted.

.PARAMETER SelectBundle
    List the bundles on the share (after any -LastHours / -Since / -ComputerName narrowing) in a
    grid view, newest first, and analyse only the ones you pick. Nothing is opened until you
    choose. Hold Ctrl or Shift to pick several; Cancel analyses nothing. Where Out-GridView is not
    available (Server Core, no desktop) a numbered list is shown in the console instead. The fault
    details for each picked bundle, including the evidence lines, are written to the console.

.PARAMETER GridView
    Also show the results in Out-GridView (Windows desktop sessions only).

.EXAMPLE
    .\Get-OsdFailureReport.ps1 -SelectBundle

    Pick one or more bundles from the share in a grid view and see the fault details for them.

.EXAMPLE
    .\Get-OsdFailureReport.ps1 -SelectBundle -LastHours 48

    The same, listing only bundles uploaded in the last 48 hours.

.EXAMPLE
    .\Get-OsdFailureReport.ps1 -LastHours 24

    Every Windows 11 failure uploaded in the last 24 hours, one object per device.

.EXAMPLE
    .\Get-OsdFailureReport.ps1 -LastHours 48 -OutputPath C:\Temp\OsdFailures

    The last 48 hours, plus CSV/JSON/HTML reports in C:\Temp\OsdFailures.

.EXAMPLE
    .\Get-OsdFailureReport.ps1 -ComputerName PC0123 | Select-Object -ExpandProperty Evidence

    Every bundle for one device, showing the supporting log lines.

.EXAMPLE
    .\Get-OsdFailureReport.ps1 -LastHours 12 | Group-Object RootCause | Sort-Object Count -Descending

    What is failing most in the last 12 hours.

.NOTES
    Timestamps. ConfigMgr logs record local wall-clock time plus a time-zone bias. WinPE runs in its
    default time zone (Pacific) while the full OS runs in the build's configured zone, so the bias
    changes part-way through a build while the wall clock stays continuous. Durations are therefore
    calculated on the wall clock, and a bias change is reported in Notes so an odd-looking duration
    can be explained rather than trusted blindly.

    Start time. smsts.log rolls over (SMSTSLogMaxSize / SMSTSMaxHistory). When no task sequence
    start marker is found, the earliest surviving entry is used and StartConfidence says so - the
    real build may have started earlier.
#>
#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(Position = 0)]
    [string[]]$Path = @('\\sccmstore\osdlogs\Workstation\WIN11\Failure'),

    [Parameter(ParameterSetName = 'Hours')]
    [ValidateRange(1, 8760)]
    [int]$LastHours,

    [Parameter(ParameterSetName = 'Since')]
    [datetime]$Since,

    [string[]]$ComputerName,

    [switch]$Recurse,

    [string]$Filter = '*.zip',

    [string]$HostnamePattern = '^(?<Host>.+?)(?=[_ .]|-\d{6,}|$)',

    [string]$IgnoreStepPattern = '(?i)force[ds]?\s*-?\s*fail|fail(ing)?\s+(the\s+)?(task\s*sequence|ts|build)|(copy|capture|gather|collect|zip|upload|save|archive)\b[^\r\n]*?\blogs?\b|^exit\b',

    [ValidateRange(1, 4096)]
    [int]$MaxLogSizeMB = 100,

    [ValidateRange(1, 200)]
    [int]$EvidenceLines = 10,

    [string]$OutputPath,

    [Alias('Pick')]
    [switch]$SelectBundle,

    [switch]$GridView
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.3.0'

# Run options read by the helper functions, captured once so their inputs are explicit.
$script:Options = @{
    HostnamePattern = $HostnamePattern
    IgnoreStepPattern = $IgnoreStepPattern
    MaxLogBytes = [long]$MaxLogSizeMB * 1MB
    MaxLogSizeMB = $MaxLogSizeMB
    EvidenceLines = $EvidenceLines
}

# ---------------------------------------------------------------------------------------------
# region LOGGING
# ---------------------------------------------------------------------------------------------
# Uses Write-RichoLog when Richo.Common is already loaded on the host; otherwise an identical
# local format, so the script also runs when copied on its own to an MECM jump host.
$script:UseRichoLog = [bool](Get-Command -Name Write-RichoLog -ErrorAction SilentlyContinue)

function Write-OsdLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if ($script:UseRichoLog) { Write-RichoLog -Message $Message -Level $Level; return }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    $line = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message
    switch ($Level) {
        'DEBUG' { Write-Verbose $line }
        'INFO' { Write-Information $line -InformationAction Continue }
        'WARN' { Write-Warning $line }
        # Non-terminating on purpose: a bad bundle is reported, it does not stop the run.
        'ERROR' { Write-Information $line -InformationAction Continue }
    }
}
# endregion

# ---------------------------------------------------------------------------------------------
# region KNOWLEDGE BASE
# ---------------------------------------------------------------------------------------------
# Common HRESULTs seen in OSD. Win32 exit codes (1603, 2, 5 ...) are looked up as
# HRESULT_FROM_WIN32, i.e. 0x8007xxxx.
$script:ErrorCodeTable = @{
    '0x80004004' = 'Operation aborted - the engine aborting the group after an earlier step failed. Look at the step that failed, not this code.'
    '0x80004005' = 'Unspecified error - generic; the real cause is in the evidence lines or another log.'
    '0x80070002' = 'The system cannot find the file specified - content not on a DP / not downloaded, or a wrong file or script path in the step.'
    '0x80070003' = 'The system cannot find the path specified - wrong path in the step, or content/drive not available.'
    '0x80070005' = 'Access is denied - Network Access Account / run-as account rights, or file/OU permissions.'
    '0x80070008' = 'Not enough storage to process this command - in WinPE usually boot image scratch space too small.'
    '0x8007000D' = 'The data is invalid - corrupt content or malformed input file.'
    '0x8007000E' = 'Not enough memory resources.'
    '0x80070015' = 'The device is not ready - disk or controller not ready.'
    '0x80070017' = 'Data error (cyclic redundancy check) - disk/media fault or corrupt content.'
    '0x80070020' = 'File in use by another process (sharing violation).'
    '0x80070032' = 'The request is not supported.'
    '0x80070035' = 'The network path was not found - share/DP name, DNS or connectivity.'
    '0x8007003B' = 'An unexpected network error occurred.'
    '0x80070040' = 'The specified network name is no longer available - connection dropped mid-transfer.'
    '0x80070057' = 'The parameter is incorrect - often disk/partition layout or BIOS/UEFI mismatch, or a bad variable in the step.'
    '0x80070070' = 'There is not enough space on the disk.'
    '0x80070079' = 'The semaphore timeout period has expired - network or storage timeout.'
    '0x8007007E' = 'The specified module could not be found - missing DLL/driver dependency.'
    '0x800700C1' = 'Not a valid Win32 application - wrong architecture (x86/x64/ARM64) for the boot image or OS.'
    '0x8007041D' = 'The service did not respond in a timely fashion.'
    '0x80070422' = 'The service is disabled.'
    '0x8007045D' = 'I/O device error - disk, controller or cable fault, or storage driver problem.'
    '0x80070490' = 'Element not found - often the image index, a driver, or a referenced object does not exist.'
    '0x800704CF' = 'The network location cannot be reached.'
    '0x8007052E' = 'Logon failure: unknown user name or bad password - check the Network Access / run-as / join account.'
    '0x80070570' = 'The file or directory is corrupted and unreadable - disk fault or corrupt content.'
    '0x800705B4' = 'This operation returned because the timeout period expired.'
    '0x80070643' = 'Fatal error during installation (MSI 1603) - see the installer log for the action that returned 3.'
    '0x80070652' = 'Another installation is already in progress (MSI 1618).'
    '0x80070653' = 'This installation package could not be opened (MSI 1619) - wrong path or unreadable package.'
    '0x80070BC2' = 'Reboot required (3010) - succeeded, but the step was not set to allow a reboot.'
    '0x80072EE2' = 'The operation timed out (WinHTTP) - MP/DP unreachable or slow.'
    '0x80072EE7' = 'The server name could not be resolved (WinHTTP) - DNS.'
    '0x80072EFD' = 'A connection with the server could not be established (WinHTTP) - MP/DP down, firewall, or wrong boundary.'
    '0x80072EFE' = 'The connection with the server was terminated abnormally (WinHTTP).'
    '0x80072F8F' = 'A security error occurred (WinHTTP) - almost always the device clock (BIOS time) or a certificate/CRL problem.'
    '0x80091007' = 'The hash value is not correct - content on the DP does not match the source; redistribute/validate the package.'
    '0x80040104' = 'Content location request failed - package not distributed to a DP in the device''s boundary group.'
    '0x87D00213' = 'Timeout - the program/application exceeded its maximum run time.'
    '0x87D00324' = 'The application was not detected after installation completed - detection method or silent install failure.'
    '0x87D00607' = 'Content could not be located/downloaded - content not on a DP in the boundary group, or boundary misconfigured.'
    '0x87D01106' = 'Failed to verify the executable file is valid or to construct the command line - check the program command line/content.'
    '0x800F081F' = 'The source files could not be found (DISM/CBS) - feature/update payload missing.'
}

# Domain join status codes (NetSetup.log / setupact.log "Unattended Join").
$script:DomainJoinCodes = @{
    '0x5' = 'Access denied - the join account lacks rights on the target OU or on an existing computer object.'
    '0x35' = 'Network path not found - domain controller unreachable.'
    '0x40' = 'Network name no longer available - connectivity dropped during the join.'
    '0x4cf' = 'Network location cannot be reached.'
    '0x52e' = 'Logon failure - wrong user name or password for the domain join account.'
    '0x52f' = 'Account restriction on the domain join account.'
    '0x532' = 'Domain join account password has expired.'
    '0x533' = 'Domain join account is disabled.'
    '0x534' = 'No mapping between account names and security IDs - the join account name is wrong.'
    '0x54b' = 'The specified domain does not exist or could not be contacted - DNS / DC reachability / domain name.'
    '0x6ba' = 'The RPC server is unavailable - firewall or DC reachability.'
    '0x6d9' = 'No more endpoints available from the endpoint mapper - firewall or DC reachability.'
    '0x775' = 'The domain join account is locked out.'
    '0x8b0' = 'The computer account already exists and could not be reused.'
    '0xaac' = 'An account with the same name exists in AD and re-using it was blocked by security policy (Oct 2022 domain join hardening). Delete the stale object or grant the join account ownership.'
    '0x2030' = 'There is no such object on the server - the MachineObjectOU path does not exist.'
    '0x232b' = 'DNS name does not exist - DNS cannot resolve the domain.'
}

# Known failure signatures, checked against every line of every log in the bundle.
#   Files     regex on the log's file name (leaf, lower case). Use '.' for any log.
#   Pattern   case-insensitive regex. Named groups are copied into the finding's detail.
#   Weight    specificity, 1-100. Higher wins. Generic "something failed" lines stay low so a
#             specific cause found in another log is preferred over them.
#   ErrorOnly when set, only lines the log itself marks as an error (CMTrace type 3, Panther
#             "Error") count - for patterns that also turn up in harmless information lines.
#   Exclude   optional regex; a matching line is ignored (e.g. a status of 0x0 means success).
#   StepHint  optional regex on the failed step's name; a match makes this cause more likely.
#   Explains  signature IDs this one is the underlying cause of. When the step-level symptom is one
#             of them and this signature is found during the failing step, this one is reported as
#             the root cause and the step-level signature as the symptom.
$script:SignatureDefinitions = @(
    # ---- Content / distribution -------------------------------------------------------------
    @{ Id = 'CONTENT_NOT_ON_DP'; StepHint = 'download|package|driver|apply|install'; Category = 'Content'; Weight = 90; Files = '.'
        Title = 'Content not available on a distribution point'
        Pattern = 'Failed to resolve PackageID=|failed to (get|find) content locations?|content location request.*fail|no distribution points? (were |was )?found|hr=0x80040104|0x87d00607|Failed to find (a )?(valid )?(dp|distribution point)'
        Cause = 'The package referenced by the step is not distributed to a DP in the device''s boundary group, or the boundary group has no site-system reference.'
        Action = 'Check the package ID in the evidence is distributed (and successful) on the DP for the build location; confirm the device''s IP/subnet is in a boundary group with that DP.'
    }
    @{ Id = 'CONTENT_HASH'; StepHint = 'download|package|driver|apply|install'; Category = 'Content'; Weight = 90; Files = '.'
        Title = 'Content hash mismatch'
        Pattern = 'hash (value )?(is not correct|mismatch|could not be (matched|verified))|0x80091007|Failed to verify (the )?hash'
        Cause = 'The content on the DP does not match the source version (partial/corrupt distribution or source changed without update).'
        Action = 'Validate/redistribute the package in the evidence; if the source changed, run Update Distribution Points.'
    }
    @{ Id = 'CONTENT_DOWNLOAD'; StepHint = 'download|package|driver|apply|install'; Category = 'Content'; Weight = 70; Files = '.'
        Title = 'Content download failed'
        Pattern = 'Failed to download (pkg|package|content)|Download(ing)? (of )?content.*fail|DownloadContent.*fail|OSDDownloadContent.*fail|Failed to copy .* from (the )?(dp|distribution point)'
        Cause = 'Content could not be downloaded from the DP (network, access account, or DP health).'
        Action = 'Check DP health and IIS logs for the package; verify the Network Access Account and the device''s network path to the DP.'
    }
    @{ Id = 'NETWORK_ACCESS_ACCOUNT'; Category = 'Content'; Weight = 80; Files = '.'
        Title = 'Access to DP/share denied'
        Pattern = 'network access account.*(fail|invalid|not (set|configured))|failed to connect to "?\\\\\S+.*(0x80070005|0x8007052e|0x80070035|0x80070043)'
        Cause = 'The Network Access Account (or the account in the step) cannot authenticate to the DP or share.'
        Action = 'Verify the Network Access Account password and that it is not locked or expired; check share permissions.'
    }

    # ---- Network / management point / PKI ------------------------------------------------------
    @{ Id = 'NO_NIC'; Category = 'Network'; Weight = 95; Files = '.'
        Title = 'No network adapter in WinPE'
        Pattern = 'no (valid |active )?network adapters?|network adapter.*not (found|detected)|unable to find (a |an active )?network adapter|failed to find an? (active )?network adapter|There are no active network adapters'
        Cause = 'The boot image has no driver for this model''s NIC (common with new USB-C docks and new Intel/Realtek NICs).'
        Action = 'Add the model''s WinPE NIC driver to the boot image and update the DPs; confirm the dock/adapter in use is supported for PXE/WinPE.'
    }
    @{ Id = 'NO_IP'; Category = 'Network'; Weight = 60; Files = '.'; ErrorOnly = $true
        Title = 'No IP address / DHCP failure'
        Pattern = 'no ip address|unable to obtain (an )?ip|dhcp.*(fail|time ?out)|169\.254\.\d+\.\d+'
        Cause = 'The device did not get a DHCP lease (APIPA 169.254.x.x) - driver, VLAN, port security or DHCP scope.'
        Action = 'Check the switch port VLAN, 802.1X/port security and DHCP scope for the build location.'
    }
    @{ Id = 'MP_UNREACHABLE'; Category = 'Network'; Weight = 75; Files = '.'
        Title = 'Management point unreachable / policy request failed'
        Pattern = 'Failed to get client identity|Failed to read client identity|Failed to request policy assignments|Failed to download policy|failed to get (mp|management point) (list|location|information)|WinHttpSendRequest.*fail|(0x)?80072ee2|(0x)?80072efd|(0x)?80072efe'
        Cause = 'WinPE/the TS could not talk to the management point (network, firewall, MP health, or boundary).'
        Action = 'Check MP health (mpcontrol.log) and that the device''s subnet reaches the MP over HTTP/HTTPS.'
    }
    @{ Id = 'CERT_OR_CLOCK'; Category = 'Network'; Weight = 85; Files = '.'
        Title = 'Certificate or device clock problem'
        Pattern = '0x80072f8f|certificate.*(expired|not (yet )?valid|revoked|untrusted|chain)|\bCRL\b.*(fail|offline|unable)|clock skew|Failed to (verify|validate) (the )?certificate|0x80092013|0x800b0101|0x800b010f'
        Cause = 'The device clock (BIOS/RTC) is wrong, or a certificate/CRL could not be validated, so HTTPS/PKI communication with the site fails.'
        Action = 'Check and correct the BIOS date/time on the device first; then check the PKI certificate chain and CRL reachability from WinPE.'
    }
    @{ Id = 'DNS'; Category = 'Network'; Weight = 75; Files = '.'
        Title = 'DNS resolution failure'
        Pattern = '(name|host) (could not be|not) resolved|DNS (lookup|resolution|query) fail|(0x)?80072ee7|DNS_ERROR|unknown host|gethostbyname failed'
        Cause = 'A site system (MP/DP) or domain name could not be resolved, so the client could not reach it.'
        Action = 'Check the DNS servers handed out by DHCP for the build subnet and the record for the MP/DP/domain.'
    }

    # ---- Disk ----------------------------------------------------------------------------------
    @{ Id = 'NO_DISK'; StepHint = 'partition|format|disk'; Category = 'Disk'; Weight = 95; Files = '.'
        Title = 'No disk found'
        Pattern = 'no (fixed |hard |internal )?dis[kc]s? (were |was )?(found|detected|available)|Unable to (find|locate) (a |any )?(suitable |valid |fixed )?(hard )?disk|disk \d+ (does not exist|was not found|not found)|There are no fixed disks|OSDDiskIndex.*(invalid|not found)|Failed to find disk'
        Cause = 'WinPE cannot see the internal disk - on Windows 11 era hardware this is usually Intel VMD/RST being enabled without its storage driver in the boot image.'
        Action = 'Add the Intel RST/VMD (or the model''s NVMe/RAID) driver to the boot image, or set the SATA/NVMe mode to AHCI in BIOS per your hardware standard.'
    }
    @{ Id = 'PARTITION'; StepHint = 'partition|format|disk'; Category = 'Disk'; Weight = 80; Files = '.'
        Title = 'Format and Partition Disk failed'
        Pattern = 'Failed to (format|partition|clean) (the )?(disk|drive|volume)|Failed to create (the )?partition|diskpart.*(fail|error)|OSDDiskPart.*fail|Failed to (prepare|configure) (the )?disk'
        Cause = 'The disk could not be cleaned/partitioned - BIOS vs UEFI layout mismatch, BitLocker-locked disk, or a failing disk.'
        Action = 'Confirm the device boots UEFI and the partition step matches; clear/suspend BitLocker or run diskpart clean on the disk; check SMART/health.'
    }
    @{ Id = 'DISK_SPACE'; Category = 'Disk'; Weight = 85; Files = '.'
        Title = 'Not enough disk space'
        Pattern = 'not enough (free )?space|insufficient (disk |free )?space|disk (is )?full|0x80070070|0x80070027'
        Cause = 'A volume (OS disk, TS cache, or WinPE RAM disk) ran out of space.'
        Action = 'Check disk size vs image/content size and that the TS cache is on the OS volume; for WinPE, increase boot image scratch space.'
    }
    @{ Id = 'DISK_IO'; Category = 'Hardware'; Weight = 80; Files = '.'
        Title = 'Disk I/O or corruption error'
        Pattern = '0x8007045d|0x80070017|I/O device error|cyclic redundancy check|0x80070570|file or directory is corrupted'
        Cause = 'A read/write failed at the device level - failing disk, controller/driver problem, or corrupt content.'
        Action = 'Run the vendor disk diagnostics (e.g. Dell ePSA); if hardware passes, validate the content in the evidence.'
    }

    # ---- OS image / Windows setup --------------------------------------------------------------
    @{ Id = 'APPLY_OS'; StepHint = 'apply (operating system|os)|image'; Category = 'OS Image'; Weight = 85; Files = '.'
        Title = 'Apply Operating System Image failed'
        Pattern = 'Failed to apply (the )?(os |operating system )?image|ApplyImage.*fail|wim(gapi)?\b.*(fail|error|corrupt)|Failed to (open|mount) (the )?(wim|image)|image index.*(not found|invalid|does not exist)|Invalid image index'
        Cause = 'The OS image could not be applied - wrong/missing image index, corrupt WIM on the DP, or disk problem.'
        Action = 'Check the image index in the Apply OS step matches the WIM; validate/redistribute the OS image package.'
    }
    @{ Id = 'UNATTEND'; StepHint = 'setup windows|windows settings'; Category = 'Windows Setup'; Weight = 80; Files = '.'
        Title = 'Unattend / Windows setup configuration failed'
        Pattern = 'Windows could not parse or process (the )?unattend|failed to (process|apply|parse) .*unattend|unattend.*(invalid|could not be (processed|parsed))|\[Shell Unattend\].*(fail|error)'
        Cause = 'An unattend setting (from Apply Windows Settings / Apply Network Settings or a custom unattend.xml) is invalid for this Windows 11 build.'
        Action = 'Review the setting named in the evidence; validate the unattend against the Windows 11 ADK/SIM; check computer name length/characters and product key.'
    }
    @{ Id = 'SPECIALIZE'; StepHint = 'setup windows'; Category = 'Windows Setup'; Weight = 70; Files = '.'; ErrorOnly = $true
        Title = 'Windows setup specialize phase failed'
        Pattern = 'specialize.*(fail|error)|computer restarted unexpectedly|encountered an unexpected error'
        Cause = 'Windows setup failed in the specialize pass (often unattend, driver, or domain join related).'
        Action = 'Check Panther setupact.log/setuperr.log around the evidence time for the failing component.'
    }

    # ---- Drivers -------------------------------------------------------------------------------
    @{ Id = 'DRIVER_APPLY'; StepHint = 'driver'; Category = 'Drivers'; Weight = 80; Files = '.'
        Title = 'Driver package failed to apply'
        Pattern = 'Failed to (apply|install|stage|add|inject) (the )?drivers?|Apply ?Driver ?Package.*fail|OSDDriverClient.*fail|add-driver.*(fail|error)|Failed to (find|locate) (the )?driver package|driver catalog.*(fail|error)'
        Cause = 'The driver package for this model failed to download or inject (missing content, wrong architecture, or bad INF).'
        Action = 'Check the driver package for this model is distributed and matches Windows 11 x64; check the WMI model query on the step.'
    }
    @{ Id = 'DISM'; Category = 'Drivers'; Weight = 40; Files = 'dism|cbs'; ErrorOnly = $true
        Title = 'DISM/CBS servicing error'
        Pattern = '(fail|error).*hr:?\s*0x8[0-9a-f]{7}'
        Cause = 'An offline servicing operation (driver, update or feature) failed.'
        Action = 'Read the DISM.log lines in the evidence for the package or INF that failed.'
    }

    # ---- Domain join ---------------------------------------------------------------------------
    @{ Id = 'DOMAIN_JOIN'; StepHint = 'domain|join|setup windows|network settings'; Category = 'Domain Join'; Weight = 90; Files = 'netsetup|setupact|setuperr|smsts|ztidomainjoin'
        Title = 'Domain join failed'
        # A join status line is only a failure when its code is non-zero; 0x0 lines are success and
        # are dropped in Find-LogSignature (NetSetup.log writes dozens of them on a good join).
        Pattern = '(NetJoinDomain attempt failed|NetpDoDomainJoin: status|NetpJoinDomain\w*:[^\r\n]*status)[^\r\n]*?(?<JoinCode>0x[0-9a-f]+)|NetpProvisionComputerAccount[^\r\n]*fail|Unattended Join:[^\r\n]*fail|Failed to join (the )?domain|djoin[^\r\n]*fail'
        Cause = 'The device did not join the domain; the code identifies why.'
        Action = 'Use the decoded join code below; check the join account, the MachineObjectOU and any stale computer object for this hostname.'
    }

    # ---- ConfigMgr client ----------------------------------------------------------------------
    @{ Id = 'CLIENT_INSTALL'; StepHint = 'setup windows|configmgr|client'; Category = 'ConfigMgr Client'; Weight = 85; Files = 'ccmsetup|client\.msi|smsts'
        Title = 'ConfigMgr client installation failed'
        Pattern = 'CcmSetup failed with error code (?<ClientCode>0x[0-9a-f]+)|Failed to install (the )?(sms |configmgr |configuration manager )?client|ccmsetup.*exit(ed)? with (return )?code (?<ClientExit>[1-9]\d*)'
        Cause = 'Setup Windows and ConfigMgr could not install the client.'
        Action = 'Read ccmsetup.log and client.msi.log ("Return value 3") in the bundle; check the client package is distributed and the MP is reachable from the new OS.'
    }
    @{ Id = 'MSI_RETURN_3'; Category = 'ConfigMgr Client'; Weight = 50; Files = 'msi'; ContextBefore = 3
        Title = 'MSI custom action failed (Return value 3)'
        Pattern = 'Return value 3'
        Cause = 'An MSI action failed; the lines directly above "Return value 3" name it.'
        Action = 'Read the evidence context lines for the failing action.'
    }

    # ---- Applications / packages ---------------------------------------------------------------
    @{ Id = 'APP_EXIT_CODE'; StepHint = 'application|install'; Category = 'Applications'; Weight = 85; Files = 'appenforce'
        Title = 'Application installer returned a failure exit code'
        Pattern = 'Unmatched exit code \((?<ExitCode>-?\d+)\) is considered an execution failure'
        ContextPattern = 'App DT "(?<Application>[^"]+)"'
        Cause = 'An application installed during the TS exited with a code not defined as success.'
        Action = 'Test the application deployment type silently on a Windows 11 device; check its own install log for the exit code.'
    }
    @{ Id = 'APP_NOT_DETECTED'; StepHint = 'application|install'; Category = 'Applications'; Weight = 85; Files = '.'
        Title = 'Application not detected after install'
        Pattern = '0x87d00324|(application )?was not detected after (the )?install'
        ContextPattern = 'App DT "(?<Application>[^"]+)"'
        Cause = 'The installer finished but the detection method did not find the app - silent install failed quietly, or the detection rule is wrong for Windows 11.'
        Action = 'Check the detection method for the application in the evidence and its install log.'
    }
    @{ Id = 'APP_POLICY_EVAL'; StepHint = 'install|application'; Category = 'Applications'; Weight = 92; Files = 'smsts|dcmagent|appintenteval'
        Title = 'Application policy evaluation failed (Install Application)'
        Pattern = 'Application failed to evaluate|Marking CIs state as EvaluationFailed|Not found in CI state store|Exhausted retry attempts'
        Cause = 'The client never finished evaluating the application''s policy ("Application failed to evaluate" / CI not found in the CI state store), so the Install Application step waited, retried and gave up. The installer itself never ran. Usual causes: the client could not download or compile the application''s policy (MP/DNS reachability, CIDownloader errors), the current application/deployment type revision is not available to the client, or the application or one of its dependencies does not allow installation from the Install Application task sequence action.'
        Action = 'Check the contributing factors and CIDownloader.log/DCMAgent.log/CIAgent.log for this application around the step time; confirm the application and every dependency have "Allow this application to be installed from the Install Application task sequence action without being deployed" ticked and the current revision''s content is on a DP in the boundary group.'
    }
    @{ Id = 'BITS_NETWORK_DISCONNECTED'; StepHint = 'install|application|download|package'; Category = 'Network'; Weight = 95
        Files = 'datatransferservice|filebits|ciagent|cidownloader|contenttransfer|cas|smsts'
        # The CI/content download job is parked by BITS, so whatever needed it fails: the
        # application policy evaluation, a content download, or a CI download.
        Explains = @('APP_POLICY_EVAL', 'CI_DOWNLOAD', 'CONTENT_DOWNLOAD', 'APP_INSTALL', 'TIMEOUT')
        Title = 'BITS reported no active network connection - download stalled'
        Pattern = '0x80200010|There are currently no active network connections'
        Cause = 'BITS (which the ConfigMgr client uses to download application CI documents and content) put the download on hold with BG_E_NETWORK_DISCONNECTED: Windows did not consider the network connected, although the task sequence''s own HTTP traffic to the MP was working. BITS waits for Windows to report the network connected again; that did not happen before the step''s 3 x 5 minute evaluation retries ran out. The installer never ran.'
        Action = 'Look at how soon after a restart the step ran (see detail). If it is the first Install Application step after a restart, add a step before it that waits until Windows reports the network connected (e.g. Get-NetConnectionProfile shows IPv4Connectivity other than NoTraffic/Disconnected, or the profile is DomainAuthenticated), and check what delays it after a reboot on the build network (802.1X/NAC re-authentication, NLA/NCSI probing). Re-running the build usually succeeds.'
    }
    @{ Id = 'BITS_ERROR'; StepHint = 'install|application|download|package'; Category = 'Network'; Weight = 80; Files = 'datatransferservice|filebits'
        Explains = @('APP_POLICY_EVAL', 'CI_DOWNLOAD', 'CONTENT_DOWNLOAD')
        Title = 'BITS download job error'
        Pattern = 'HandleErrors[^\r\n]*ErrorCode=(?<BitsCode>0x8[0-9a-f]{7})'
        Exclude = '0x80200010'
        Cause = 'A BITS job carrying ConfigMgr policy or content failed; the code says why (0x8019xxxx = the HTTP status returned by the MP/DP).'
        Action = 'Decode the BitsCode (e.g. 0x80190194 = HTTP 404 not found, 0x80190193 = 403 forbidden, 0x80190191 = 401 unauthorised) and check the MP/DP IIS logs for the request.'
    }
    @{ Id = 'CI_DOWNLOAD'; StepHint = 'install|application'; Category = 'Applications'; Weight = 50; Files = 'cidownloader|ciagent'; ErrorOnly = $true
        Title = 'Configuration item (policy) download errors'
        Pattern = 'fail|error'
        # Routine client noise: WMI "not found" (0x80041002) on the Lantern store, and no logged-on
        # user token (1008) - nobody is logged on during OSD.
        Exclude = '0x80041002|GetLoggedOnUserToken'
        Cause = 'The client logged errors downloading or processing configuration items (application/compliance policy).'
        Action = 'Read the CIDownloader.log/CIAgent.log evidence for the CI and the error; check MP reachability.'
    }
    @{ Id = 'APP_INSTALL'; StepHint = 'application'; Category = 'Applications'; Weight = 70; Files = 'smsts'
        Title = 'Install Application step failed'
        Pattern = 'failed to install application:? ''(?<Application>[^'']+)''|Install(ing)? (static |dynamic )?applications?.*(fail|error)|Application .{1,120} failed to install|Failed to install application|InstallApplication.*fail'
        Cause = 'An application in an Install Application step failed (download, install or detection).'
        Action = 'AppEnforce.log/AppDiscovery.log in the bundle identify which application and why.'
    }
    @{ Id = 'PACKAGE_PROGRAM'; StepHint = 'package|install'; Category = 'Applications'; Weight = 80; Files = 'execmgr|smsts'
        Title = 'Package program returned a failure exit code'
        Pattern = 'Script for Package:? ?(?<PackageID>\w+), Program: (?<Program>.+?) failed with exit code (?<ExitCode>-?\d+)|Program exit code (?<ExitCode2>[1-9]\d*)|Install Package action failed'
        Cause = 'A legacy package/program in an Install Package step returned a failure code.'
        Action = 'Test the program silently; check the exit code meaning for that installer.'
    }
    @{ Id = 'MSI_1618'; Category = 'Applications'; Weight = 70; Files = '.'
        Title = 'Another installation already in progress (1618)'
        Pattern = '0x80070652|exit code 1618\b|another installation is already in progress'
        Cause = 'An installer ran while another MSI (often Windows Update or a background app install) was running.'
        Action = 'Add a retry or a wait for msiexec before the step; check for an app/update installing in parallel.'
    }
    @{ Id = 'MSI_1603'; Category = 'Applications'; Weight = 60; Files = '.'
        Title = 'Installer fatal error (1603)'
        Pattern = '0x80070643|exit code 1603\b|fatal error during installation'
        Cause = 'An MSI-based installer failed; 1603 is generic.'
        Action = 'Read the installer''s verbose log for "Return value 3".'
    }
    # Usually informational: deployment types commonly map 3010 to a soft reboot.
    @{ Id = 'REBOOT_REQUIRED'; Category = 'Applications'; Weight = 30; Files = '.'
        Title = 'Step returned reboot-required (3010)'
        Pattern = '0x80070bc2|exit code 3010\b'
        Cause = 'An installer asked for a reboot that the step was not configured to allow.'
        Action = 'Map 3010 to soft reboot in the deployment type / program, or add a restart after the step.'
    }
    @{ Id = 'TIMEOUT'; Category = 'Applications'; Weight = 70; Files = '.'
        Title = 'Step timed out'
        Pattern = '0x87d00213|max(imum)? (allowed )?run ?time|exceeded (the )?(maximum|max) run ?time|0x800705b4|timed out waiting'
        Cause = 'An installer/step ran past its maximum run time - often an interactive prompt waiting on a silent install.'
        Action = 'Run the installer silently on a test device to find the prompt; raise the maximum run time only if it is genuinely slow.'
    }

    # ---- Scripts -------------------------------------------------------------------------------
    @{ Id = 'SCRIPT'; StepHint = 'script|powershell|command'; Category = 'Scripts'; Weight = 75; Files = '.'
        Title = 'Task sequence script failed'
        # "is not digitally signed" alone is not used: MSI logs print it as an informational
        # SOFTWARE RESTRICTION POLICY line on every unsigned package.
        Pattern = 'Run PowerShell Script.*fail|PowerShell script.*(fail|exit code [1-9])|execution of scripts is disabled|\.ps1[^\r\n]*(cannot be loaded|is not digitally signed)|\.ps1.*(exit code|returned) [1-9]\d*'
        Cause = 'A script step failed or was blocked by execution policy/signing.'
        Action = 'Check the step''s execution policy setting and run the script manually in WinPE/Windows 11 with the same parameters.'
    }

    # ---- Updates -------------------------------------------------------------------------------
    @{ Id = 'SOFTWARE_UPDATES'; StepHint = 'update'; Category = 'Updates'; Weight = 65; Files = 'smsts|wuahandler|updatesdeployment|updateshandler'
        Title = 'Install Software Updates failed'
        Pattern = 'Install Software Updates.*fail|Failed to (scan|install|download) (software )?updates?|0x8024[0-9a-f]{4}'
        Cause = 'The update scan or install during the build failed.'
        Action = 'Check WUAHandler.log and the SUP/WSUS reachability from the build subnet; consider an offline-serviced image.'
    }

    # ---- BitLocker / TPM / Windows 11 readiness ------------------------------------------------
    @{ Id = 'BITLOCKER'; StepHint = 'bitlocker'; Category = 'BitLocker/TPM'; Weight = 80; Files = '.'; ErrorOnly = $true
        Title = 'BitLocker step failed'
        Pattern = 'bitlocker|0x8031[0-9a-f]{4}|FVE_E_|manage-bde'
        Cause = 'Pre-provision/Enable BitLocker failed - TPM state, policy, or an already-encrypted disk.'
        Action = 'Check TPM is enabled/owned in BIOS and the disk is not already encrypted; review the BitLocker step options.'
    }
    @{ Id = 'TPM'; StepHint = 'bitlocker|tpm'; Category = 'BitLocker/TPM'; Weight = 85; Files = '.'
        Title = 'TPM not ready'
        Pattern = 'TPM (is )?(not (found|present|ready|owned|enabled|activated)|disabled|locked ?out)|0x8028[0-9a-f]{4}|0x8029[0-9a-f]{4}|TBS_E_|Failed to (take ownership|initialize) (of )?(the )?TPM'
        Cause = 'The TPM is disabled, not ready, or locked out - Windows 11 and BitLocker both need TPM 2.0.'
        Action = 'Enable/clear the TPM in BIOS (PTT/fTPM), confirm TPM 2.0 firmware, and retry.'
    }
    @{ Id = 'WIN11_READINESS'; StepHint = 'readiness|check'; Category = 'BitLocker/TPM'; Weight = 75; Files = '.'; ErrorOnly = $true
        Title = 'Windows 11 hardware readiness check failed'
        Pattern = 'Check Readiness|does not meet (the )?(minimum )?(hardware )?requirements|Secure ?Boot (is )?(not enabled|disabled|off)|TPM 2\.0 (is )?(not|required)|UEFI (is )?required'
        Cause = 'The device does not meet the Windows 11 or TS readiness requirements (UEFI, Secure Boot, TPM 2.0, RAM, disk).'
        Action = 'Check BIOS: UEFI boot, Secure Boot on, TPM 2.0 enabled; check RAM/disk against the readiness step.'
    }

    # ---- Task sequence / policy ----------------------------------------------------------------
    @{ Id = 'TS_POLICY'; Category = 'Task Sequence'; Weight = 75; Files = '.'
        Title = 'Task sequence policy could not be retrieved'
        Pattern = 'Failed to (get|download|read|load) (the )?(task sequence|ts) (policy|environment)|no task sequences? (deployments? )?(is |are )?available|There are no task sequences available|TS policy.*fail'
        Cause = 'The device has no task sequence deployment or its policy could not be downloaded.'
        Action = 'Check the device/unknown-computer collection membership and the deployment; confirm MP reachability.'
    }
    @{ Id = 'GROUP_ABORT'; Category = 'Task Sequence'; Weight = 10; Files = 'smsts'
        Title = 'Task sequence group aborted'
        Pattern = 'execution of the group \((?<Group>[^)]+)\) has failed and the execution has been aborted'
        Cause = 'Secondary - the group stopped because a step inside it failed.'
        Action = 'Look at the failed step and its error code.'
    }
)

$script:Signatures = foreach ($def in $script:SignatureDefinitions) {
    $opts = [Text.RegularExpressions.RegexOptions]'IgnoreCase, Compiled, CultureInvariant'
    $exclude = $null
    if ($def.ContainsKey('Exclude')) { $exclude = New-Object Text.RegularExpressions.Regex($def.Exclude, $opts) }
    $context = $null
    if ($def.ContainsKey('ContextPattern')) { $context = New-Object Text.RegularExpressions.Regex($def.ContextPattern, $opts) }
    [pscustomobject]@{
        Id = $def.Id
        Title = $def.Title
        Category = $def.Category
        Weight = $def.Weight
        Cause = $def.Cause
        Action = $def.Action
        ErrorOnly = ($def.ContainsKey('ErrorOnly') -and $def.ErrorOnly)
        ContextBefore = $(if ($def.ContainsKey('ContextBefore')) { [int]$def.ContextBefore } else { 0 })
        Explains = $(if ($def.ContainsKey('Explains')) { @($def.Explains) } else { @() })
        StepHint = $(if ($def.ContainsKey('StepHint')) { New-Object Text.RegularExpressions.Regex($def.StepHint, $opts) } else { $null })
        Files = New-Object Text.RegularExpressions.Regex($def.Files, $opts)
        Regex = New-Object Text.RegularExpressions.Regex($def.Pattern, $opts)
        Exclude = $exclude
        Context = $context
    }
}

# endregion

# ---------------------------------------------------------------------------------------------
# region LOG PARSING
# ---------------------------------------------------------------------------------------------
# Whole-entry CMTrace pattern, run over the full text of a log. Singleline so a multi-line message
# ("Failed to run the action: X.<newline>... (Error: ...)") stays one entry.
$script:RxCmTrace = New-Object Text.RegularExpressions.Regex(
    '<!\[LOG\[(?<msg>.*?)\]LOG\]!><time="(?<time>\d{1,2}:\d{2}:\d{2})(?:\.(?<frac>\d+))?(?<bias>[+-]\d+)?"\s+date="(?<date>\d{1,2}-\d{1,2}-\d{4})"\s+component="(?<comp>[^"]*)"(?:\s+context="[^"]*")?\s+type="(?<type>\d)"\s+thread="(?<thread>\d+)"[^>]*>',
    [Text.RegularExpressions.RegexOptions]'Singleline, Compiled, CultureInvariant')
# Pre-2012 ConfigMgr format: "message  $$<Component><11-09-2026 10:20:30.123+480><thread=1 (0x1)>"
$script:RxLegacy = New-Object Text.RegularExpressions.Regex(
    '^(?<msg>.*?)\s*\$\$<(?<comp>[^>]*)><(?<date>\d{1,2}-\d{1,2}-\d{4}) (?<time>\d{1,2}:\d{2}:\d{2})(?:\.(?<frac>\d+))?(?<bias>[+-]\d+)?><thread=(?<thread>\d+)',
    [Text.RegularExpressions.RegexOptions]'Compiled, CultureInvariant')
# Panther setupact/setuperr, DISM.log and CBS.log: "2026-11-09 10:20:30, Error   DISM   message"
$script:RxPanther = New-Object Text.RegularExpressions.Regex(
    '^(?<dt>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\s+(?<lvl>Error|Warning|Info|Perf)\s+(?<msg>.*)$',
    [Text.RegularExpressions.RegexOptions]'Compiled, CultureInvariant')
$script:RxPantherError = New-Object Text.RegularExpressions.Regex('(?m)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\s+Error\b', 'Compiled')
$script:RxPantherWarning = New-Object Text.RegularExpressions.Regex('(?m)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\s+Warning\b', 'Compiled')
# NetSetup.LOG: "11/09/2026 10:20:30:123 message"
$script:RxNetSetup = New-Object Text.RegularExpressions.Regex(
    '^(?<dt>\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}):\d{3}\s(?<msg>.*)$',
    [Text.RegularExpressions.RegexOptions]'Compiled, CultureInvariant')
$script:RxCmError = New-Object Text.RegularExpressions.Regex('\]LOG\]!><time="[^"]*"\s+date="[^"]*"\s+component="[^"]*"(?:\s+context="[^"]*")?\s+type="3"', 'Compiled')
$script:RxCmWarning = New-Object Text.RegularExpressions.Regex('\]LOG\]!><time="[^"]*"\s+date="[^"]*"\s+component="[^"]*"(?:\s+context="[^"]*")?\s+type="2"', 'Compiled')

$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
$script:SeverityByType = @{ '1' = 'Info'; '2' = 'Warning'; '3' = 'Error' }

$script:RxRedact = New-Object Text.RegularExpressions.Regex(
    '(?<k>(password|passwd|pwd|secret|DomainAdminPassword|OSDJoinPassword)\s*[:=]\s*)("[^"]*"|''[^'']*''|\S+)|(?<k>\s/p(ass(word)?)?:)\S+',
    [Text.RegularExpressions.RegexOptions]'IgnoreCase, Compiled')

function Protect-LogText {
    <#
    .SYNOPSIS
        Masks credentials and shortens a log line for reporting.
    .PARAMETER Text
        The raw line.
    .PARAMETER MaxLength
        Truncate to this many characters.
    .EXAMPLE
        Protect-LogText 'net use \\dp\share /user:x Password=abc'
    #>
    param([AllowEmptyString()][string]$Text, [int]$MaxLength = 400)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $flat = ($script:RxRedact.Replace($Text, '${k}********') -replace '\s+', ' ').Trim()
    if ($flat.Length -gt $MaxLength) { $flat = $flat.Substring(0, $MaxLength) + '...' }
    return $flat
}

function ConvertTo-LogTime {
    <#
    .SYNOPSIS
        Builds a wall-clock DateTime from a CMTrace date ("M-d-yyyy"), time ("H:mm:ss") and
        fraction of a second (any number of digits). Returns $null when unparseable.
    .PARAMETER Date
        CMTrace date string.
    .PARAMETER Time
        CMTrace time string without the fraction.
    .PARAMETER Fraction
        Digits after the decimal point, if any.
    .EXAMPLE
        ConvertTo-LogTime -Date '11-09-2026' -Time '10:20:30' -Fraction '123'
    #>
    param([string]$Date, [string]$Time, [string]$Fraction)
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact("$Date $Time", 'M-d-yyyy H:mm:ss', $script:Invariant, 'None', [ref]$dt)) { return $null }
    if ($Fraction) { $dt = $dt.AddMilliseconds([int](($Fraction + '000').Substring(0, 3))) }
    return $dt
}

function ConvertFrom-BundleEntryByte {
    <#
    .SYNOPSIS
        Decodes a log's bytes to text, detecting UTF-16/UTF-8 by BOM or by NUL bytes.
    .PARAMETER Bytes
        The entry's bytes.
    .EXAMPLE
        $text = ConvertFrom-BundleEntryByte -Bytes $bytes
    #>
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3) }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2) }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2) }
    # UTF-16LE without a BOM: ASCII text with every second byte zero.
    $sample = [Math]::Min($Bytes.Length, 512)
    $zeros = 0
    for ($i = 1; $i -lt $sample; $i += 2) { if ($Bytes[$i] -eq 0) { $zeros++ } }
    if ($sample -ge 4 -and $zeros -gt ($sample / 4)) { return [Text.Encoding]::Unicode.GetString($Bytes) }
    return [Text.Encoding]::UTF8.GetString($Bytes)
}

function Get-LogFormat {
    <#
    .SYNOPSIS
        Identifies a log's format from its first 4 KB: CmTrace, Legacy, Panther, NetSetup or Text.
    .PARAMETER Text
        Full text of the log.
    .EXAMPLE
        Get-LogFormat -Text $text
    #>
    param([string]$Text)
    $head = $Text.Substring(0, [Math]::Min($Text.Length, 4096))
    if ($head.Contains('<![LOG[')) { return 'CmTrace' }
    if ($head.Contains('$$<')) { return 'Legacy' }
    if ($head -match '(?m)^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},') { return 'Panther' }
    if ($head -match '(?m)^\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}:\d{3}') { return 'NetSetup' }
    return 'Text'
}

function Get-NewlineCount {
    <#
    .SYNOPSIS
        Counts line feeds in a span of text without a PowerShell loop per character.
    .PARAMETER Text
        The text.
    .PARAMETER Start
        Offset of the span.
    .PARAMETER Length
        Length of the span.
    .EXAMPLE
        Get-NewlineCount -Text $t -Start 0 -Length 100
    #>
    param([string]$Text, [int]$Start, [int]$Length)
    if ($Length -le 0) { return 0 }
    $span = $Text.Substring($Start, $Length)
    return $span.Length - $span.Replace("`n", '').Length
}

function Get-TaskSequenceRecord {
    <#
    .SYNOPSIS
        Parses smsts.log text into timeline records (Log, Line, Time, Bias, Severity, Component,
        Message).
    .DESCRIPTION
        CMTrace entries are matched over the whole text in one native pass; line numbers are
        carried forward from entry to entry. Legacy "$$<" format is handled line by line.
    .PARAMETER Text
        Full text of the log.
    .PARAMETER Log
        Path of the log inside the bundle.
    .PARAMETER Format
        Output of Get-LogFormat.
    .EXAMPLE
        Get-TaskSequenceRecord -Text $text -Log 'smsts.log' -Format CmTrace
    #>
    param([string]$Text, [string]$Log, [string]$Format)
    $records = New-Object System.Collections.Generic.List[object]
    if ($Format -eq 'CmTrace') {
        $line = 1; $pos = 0
        foreach ($m in $script:RxCmTrace.Matches($Text)) {
            if ($m.Index -gt $pos) {
                $gap = $Text.Substring($pos, $m.Index - $pos)
                $line += $gap.Length - $gap.Replace("`n", '').Length
            }
            $g = $m.Groups
            $dt = [datetime]::MinValue
            $time = $null
            if ([datetime]::TryParseExact($g['date'].Value + ' ' + $g['time'].Value, 'M-d-yyyy H:mm:ss', $script:Invariant, 'None', [ref]$dt)) {
                if ($g['frac'].Success) { $dt = $dt.AddMilliseconds([int](($g['frac'].Value + '000').Substring(0, 3))) }
                $time = $dt
            }
            $sev = $script:SeverityByType[$g['type'].Value]
            if (-not $sev) { $sev = 'Unknown' }
            $msg = $g['msg'].Value
            $records.Add([pscustomobject]@{ Log = $Log; Line = $line; Time = $time; Bias = $g['bias'].Value; Severity = $sev; Component = $g['comp'].Value; Message = $msg })
            if ($m.Value.IndexOf("`n") -ge 0) { $line += $m.Value.Length - $m.Value.Replace("`n", '').Length }
            $pos = $m.Index + $m.Length
        }
    }
    elseif ($Format -eq 'Legacy') {
        $n = 0
        foreach ($raw in $Text.Split("`n")) {
            $n++
            $m = $script:RxLegacy.Match($raw.TrimEnd("`r"))
            if (-not $m.Success) { continue }
            $records.Add([pscustomobject]@{
                    Log = $Log; Line = $n; Severity = 'Unknown'; Component = $m.Groups['comp'].Value; Message = $m.Groups['msg'].Value; Bias = $m.Groups['bias'].Value
                    Time = ConvertTo-LogTime -Date $m.Groups['date'].Value -Time $m.Groups['time'].Value -Fraction $m.Groups['frac'].Value
                })
        }
    }
    return , $records
}

function Find-LogSignature {
    <#
    .SYNOPSIS
        Scans one log for known failure signatures and adds a finding per match.
    .DESCRIPTION
        Each applicable signature runs over the whole text natively (one pass per signature is ~10x
        faster than a single alternation of all of them, which defeats .NET's literal-prefix search).
        Only the entries hit are then located (CMTrace entry or physical line), parsed for time and
        severity, and checked against the individual signatures in PowerShell.
    .PARAMETER Text
        Full text of the log.
    .PARAMETER Log
        Path of the log inside the bundle.
    .PARAMETER Format
        Output of Get-LogFormat.
    .PARAMETER Applicable
        Signatures whose Files pattern matches this log.
    .PARAMETER Findings
        List to add findings to.
    .PARAMETER Written
        The log file's last-write time inside the zip, used to place undated lines in time.
    .EXAMPLE
        Find-LogSignature -Text $text -Log 'smsts.log' -Format CmTrace -Applicable $sigs -Findings $list
    #>
    param([string]$Text, [string]$Log, [string]$Format, [object[]]$Applicable, $Findings, $Written = $null)
    if ($null -eq $Applicable -or $Applicable.Count -eq 0) { return }

    $contexts = @{}
    foreach ($sig in $Applicable) {
        if ($null -ne $sig.Context) { $contexts[$sig.Id] = @($sig.Context.Matches($Text)) }
    }

    $hits = New-Object System.Collections.Generic.List[int]
    foreach ($sig in $Applicable) {
        foreach ($m in $sig.Regex.Matches($Text)) { $hits.Add($m.Index) }
    }
    if ($hits.Count -eq 0) { return }
    $hits.Sort()

    $lastStart = -1
    $cursorIdx = 0; $cursorLine = 1
    foreach ($hitIndex in $hits) {
        # ---- The entry or line the hit sits in ----------------------------------------------
        $start = -1; $end = -1
        if ($Format -eq 'CmTrace') {
            $start = $Text.LastIndexOf('<![LOG[', $hitIndex)
            $close = $Text.IndexOf(']LOG]!>', $hitIndex)
            if ($close -ge 0) { $end = $Text.IndexOf('>', $close + 8) }
        }
        if ($start -lt 0 -or $end -lt 0) {
            $start = 0
            if ($hitIndex -gt 0) { $start = $Text.LastIndexOf("`n", $hitIndex - 1) + 1 }
            $end = $Text.IndexOf("`n", $hitIndex)
            if ($end -lt 0) { $end = $Text.Length - 1 }
        }
        if ($start -eq $lastStart) { continue }
        $lastStart = $start
        $entry = $Text.Substring($start, $end - $start + 1).TrimEnd("`r", "`n")

        $msg = $entry; $time = $null; $sev = 'Unknown'
        $m = $script:RxCmTrace.Match($entry)
        if ($m.Success) {
            $msg = $m.Groups['msg'].Value
            $time = ConvertTo-LogTime -Date $m.Groups['date'].Value -Time $m.Groups['time'].Value -Fraction $m.Groups['frac'].Value
            $sev = $script:SeverityByType[$m.Groups['type'].Value]
            if (-not $sev) { $sev = 'Unknown' }
        }
        else {
            $m = $script:RxPanther.Match($entry)
            if ($m.Success) {
                $msg = $m.Groups['msg'].Value
                $sev = switch ($m.Groups['lvl'].Value) { 'Error' { 'Error' } 'Warning' { 'Warning' } default { 'Info' } }
                $dt = [datetime]::MinValue
                if ([datetime]::TryParseExact($m.Groups['dt'].Value, 'yyyy-MM-dd HH:mm:ss', $script:Invariant, 'None', [ref]$dt)) { $time = $dt }
            }
            else {
                $m = $script:RxNetSetup.Match($entry)
                if ($m.Success) {
                    $msg = $m.Groups['msg'].Value
                    $dt = [datetime]::MinValue
                    if ([datetime]::TryParseExact($m.Groups['dt'].Value, 'MM/dd/yyyy HH:mm:ss', $script:Invariant, 'None', [ref]$dt)) { $time = $dt }
                }
                else {
                    $m = $script:RxLegacy.Match($entry)
                    if ($m.Success) {
                        $msg = $m.Groups['msg'].Value
                        $time = ConvertTo-LogTime -Date $m.Groups['date'].Value -Time $m.Groups['time'].Value -Fraction $m.Groups['frac'].Value
                    }
                }
            }
        }

        # Line number, counted forward from the previous hit.
        $cursorLine += Get-NewlineCount -Text $Text -Start $cursorIdx -Length ($start - $cursorIdx)
        $cursorIdx = $start

        foreach ($sig in $Applicable) {
            if ($sig.ErrorOnly) {
                if ($sev -ne 'Error' -and $sev -ne 'Unknown') { continue }
                # Plain-text lines carry no severity; for ErrorOnly signatures the line must say so.
                if ($sev -eq 'Unknown' -and $msg -notmatch '(?i)error|fail') { continue }
            }
            $sm = $sig.Regex.Match($msg)
            if (-not $sm.Success) { continue }
            if ($null -ne $sig.Exclude -and $sig.Exclude.IsMatch($msg)) { continue }

            $detail = [ordered]@{}
            foreach ($gName in $sig.Regex.GetGroupNames()) {
                if ($gName -match '^\d+$') { continue }
                $g = $sm.Groups[$gName]
                if ($g.Success -and $g.Value) { $detail[($gName -replace '\d+$', '')] = $g.Value }
            }
            if ($sig.Id -eq 'DOMAIN_JOIN') {
                if (-not $detail.Contains('JoinCode')) {
                    $jm = [regex]::Match($msg, '(?i)(failed|status)[^\r\n]*?(?<c>0x[0-9a-f]+)')
                    if ($jm.Success) { $detail['JoinCode'] = $jm.Groups['c'].Value }
                }
                # 0x0 is success.
                if ($detail.Contains('JoinCode') -and $detail['JoinCode'] -match '^0x0+$') { continue }
            }
            if ($contexts.ContainsKey($sig.Id)) {
                $cm = $null
                foreach ($c in $contexts[$sig.Id]) { if ($c.Index -lt $hitIndex) { $cm = $c } else { break } }
                if ($null -ne $cm) {
                    foreach ($gName in $sig.Context.GetGroupNames()) {
                        if ($gName -match '^\d+$') { continue }
                        if ($cm.Groups[$gName].Success) { $detail[$gName] = $cm.Groups[$gName].Value }
                    }
                }
            }
            # A CM package ID (site code + 5 hex) on the line is worth surfacing.
            $pkg = [regex]::Match($msg, '\b(?<p>[A-Z0-9]{3}[0-9A-F]{5})\b')
            if ($pkg.Success -and -not $detail.Contains('PackageID') -and $sig.Category -in @('Content', 'Drivers', 'OS Image', 'Applications')) {
                $detail['PackageID'] = $pkg.Groups['p'].Value
            }
            $context = @()
            if ($sig.ContextBefore -gt 0 -and $start -gt 0) {
                $from = $start - 1
                $lines = New-Object System.Collections.Generic.List[string]
                for ($k = 0; $k -lt $sig.ContextBefore -and $from -gt 0; $k++) {
                    $prev = $Text.LastIndexOf("`n", $from - 1) + 1
                    $lines.Insert(0, (Protect-LogText ($Text.Substring($prev, $from - $prev)) 200))
                    $from = $prev - 1
                }
                $context = $lines.ToArray()
            }

            $Findings.Add([pscustomobject]@{
                    Signature = $sig
                    Log = $Log
                    Line = $cursorLine
                    Time = $time
                    Text = Protect-LogText $msg
                    Detail = $detail
                    Context = $context
                    FileWritten = $Written
                })
        }
    }
}
# endregion

# ---------------------------------------------------------------------------------------------
# region ERROR CODES
# ---------------------------------------------------------------------------------------------
function ConvertTo-ErrorCode {
    <#
    .SYNOPSIS
        Normalises an error/exit code (hex, signed or unsigned decimal) to "0x########".
    .DESCRIPTION
        Small decimal values are treated as Win32/installer exit codes and returned as the code
        itself plus the matching HRESULT_FROM_WIN32 for lookup.
    .PARAMETER Value
        The code as written in the log.
    .EXAMPLE
        ConvertTo-ErrorCode '2147942402'   # 0x80070002
    #>
    param([string]$Value)
    $v = "$Value".Trim()
    if ($v -eq '') { return $null }
    [long]$n = 0
    if ($v -match '^(0x)?(?<hex>[0-9a-fA-F]{8})$' -and ($v.StartsWith('0x') -or $v -match '[a-fA-F]' -or $v.StartsWith('8'))) {
        $n = [Convert]::ToInt64($Matches['hex'], 16)
    }
    elseif ($v -match '^0x(?<hex>[0-9a-fA-F]{1,8})$') {
        $n = [Convert]::ToInt64($Matches['hex'], 16)
    }
    elseif ($v -match '^-?\d+$') {
        $n = [long]$v
        if ($n -lt 0) { $n = $n + 4294967296 }
    }
    else { return $null }

    if ($n -eq 0) { return [pscustomobject]@{ Code = '0x00000000'; Lookup = '0x00000000'; Display = '0' } }
    if ($n -gt 0 -and $n -lt 65536) {
        # Win32 / installer exit code.
        $lookup = '0x{0:X8}' -f (0x80070000 -bor $n)
        return [pscustomobject]@{ Code = $lookup; Lookup = $lookup; Display = ('{0} ({1})' -f $n, $lookup) }
    }
    $hex = '0x{0:X8}' -f $n
    return [pscustomobject]@{ Code = $hex; Lookup = $hex; Display = $hex }
}

function Get-ErrorCodeDescription {
    <#
    .SYNOPSIS
        Describes an HRESULT from the OSD table, or from Windows itself when running on Windows.
    .PARAMETER Code
        "0x########".
    .EXAMPLE
        Get-ErrorCodeDescription '0x80070002'
    #>
    param([string]$Code)
    if (-not $Code) { return '' }
    $key = $Code.ToUpper().Replace('0X', '0x')
    if ($script:ErrorCodeTable.ContainsKey($key)) { return $script:ErrorCodeTable[$key] }
    if ($key -like '0x8024*') { return 'Windows Update Agent error.' }
    if ($key -like '0x8031*') { return 'BitLocker (FVE) error.' }
    if ($key -like '0x8028*' -or $key -like '0x8029*') { return 'TPM error.' }
    if ($key -like '0x87D*') { return 'Configuration Manager error.' }
    # On Windows the OS can describe any Win32-derived HRESULT; elsewhere its text is unreliable.
    if ([Environment]::OSVersion.Platform -eq 'Win32NT' -and $key -like '0x8007*') {
        try {
            $win32 = [Convert]::ToInt32($key.Substring(6), 16)
            return (New-Object ComponentModel.Win32Exception $win32).Message
        }
        catch { return '' }
    }
    return ''
}
# endregion

# ---------------------------------------------------------------------------------------------
# region BUNDLE ANALYSIS
# ---------------------------------------------------------------------------------------------
$script:TextExtensions = @('.log', '.lo_', '.txt', '.xml', '.ini', '.csv', '.json', '.out', '.err')
$script:RxSmsts = New-Object Text.RegularExpressions.Regex('^smsts(-\d{8}-\d{6})?\.log$|^smsts.*\.lo_$', 'IgnoreCase')
$script:RxRunStart = New-Object Text.RegularExpressions.Regex(
    '={5,}\[ ?(TSBootShell|TSMBootstrap|TsmBootstrap|TSManager|TSPxe)\.exe ?\]={5,}|Booted from network \(PXE\)|Starting Task Sequence Manager|Executing task sequence|Task Sequence Manager started|Started TSManager',
    'IgnoreCase')
$script:RxFailAction = New-Object Text.RegularExpressions.Regex(
    'Failed to run the (?:last )?action: (?<step>[^\r\n]+?)\.?\s*(?:Execution of task sequence failed\.)?\s*(?:[\r\n]+(?<detail>.*?))?\(Error: (?<code>[0-9A-Fa-f]{8}); Source: (?<src>[^)]+)\)',
    'IgnoreCase, Singleline')
# Current builds write the code as a signed decimal: "Failed to run the action: X. Error -2147467259"
$script:RxFailActionDecimal = New-Object Text.RegularExpressions.Regex(
    'Failed to run the (?:last )?action: (?<step>[^\r\n]+?)\.\s+Error (?<code>-?\d+)', 'IgnoreCase')
$script:RxFailActionNoCode = New-Object Text.RegularExpressions.Regex('Failed to run the (?:last )?action: (?<step>[^\r\n.]+)', 'IgnoreCase')
$script:RxEngineFail = New-Object Text.RegularExpressions.Regex(
    'task sequence execution engine failed executing the action \((?<step>[^)]+)\) in the group \((?<group>[^)]+)\) with the error code (?<code>-?\d+)',
    'IgnoreCase')
$script:RxTsFail = New-Object Text.RegularExpressions.Regex(
    'Task Sequence Engine failed!?\s*Code:\s*(?<code>\w+)|Execution of task sequence failed|Task sequence execution failed with error code (?<code>\w+)',
    'IgnoreCase')
# Two forms: "Instruction name: 'X'.  Pointer: 297. Type: 'SMS_TaskSequence_...'. Disabled: 0"
# (current builds) and "Instruction name: X. Instruction pointer: 12" (older).
$script:RxInstruction = New-Object Text.RegularExpressions.Regex(
    'Start executing an instruction\. Instruction name: (?:''(?<step>[^'']+)''\.\s+Pointer: \d+\.(?:\s+Type: ''(?<type>[^'']*)'')?|(?<step>[^\r\n]+?)\. Instruction pointer)|Running action: (?<step>[^\r\n]+)',
    'IgnoreCase')
$script:RxRebootStep = New-Object Text.RegularExpressions.Regex('RebootAction|^(restart|reboot)\b|\b(restart|reboot) (computer|system)', 'IgnoreCase')
$script:RxExitCode = New-Object Text.RegularExpressions.Regex('Process completed with exit code (?<code>-?\d+)', 'IgnoreCase')
# "ContinueOnErrorFlag is set to false" must NOT count, so only an affirmative form matches.
$script:RxContinue = New-Object Text.RegularExpressions.Regex('continue ?on ?error(flag)?\s*(is\s*)?(set\s*)?(to\s*)?(true|enabled)|continue on error is set|ignor(e|ing) (the )?(error|failure)|failure is ignored', 'IgnoreCase')
# Benign smsts.log lines that are logged as errors or repeat constantly; kept out of evidence.
$script:RxSmstsNoise = New-Object Text.RegularExpressions.Regex('Task Sequence environment is not initialized|CCMGetGlobalService\(&spService\), HRESULT=87d00219', 'IgnoreCase')
# Lines worth showing from the failing step's own smsts.log block.
$script:RxStepKey = New-Object Text.RegularExpressions.Regex(
    'fail|error|retry|exhausted|giving up|time ?out|timed out|not found|NotifyProgress|denied|unable|cannot|could not|HRESULT=8|exit code|Installing application|Install(ing)? (static |dynamic )?application|Executing command line|Start executing an instruction|Waiting for (job|installation)',
    'IgnoreCase')
$script:RxStepApplication = New-Object Text.RegularExpressions.Regex('failed to install application:? ''(?<a>[^'']+)''|Installing application ''(?<a>[^'']+)''', 'IgnoreCase')
$script:RxTsSuccess = New-Object Text.RegularExpressions.Regex('Task sequence completed 0x00000000|Execution of task sequence completed successfully|Task Sequence Manager ended successfully', 'IgnoreCase')
$script:RxGroupAbort = New-Object Text.RegularExpressions.Regex('execution of the group \((?<g>[^)]+)\) has failed', 'IgnoreCase')
$script:RxErrorInMsg = New-Object Text.RegularExpressions.Regex('\(Error: (?<code>[0-9A-Fa-f]{8}); Source: (?<src>[^)]+)\)', 'IgnoreCase')

# Hostname sources, best first. MININT-* names are WinPE placeholders and rank below everything.
# Each runs over the whole text of the logs its Files pattern names.
$script:HostnameExtractors = @(
    @{ Source = 'ZTIGather/BDD OSDComputerName'; Files = 'ztigather|bdd|ztiutility|smsts'; Rank = 1
        Regex = New-Object Text.RegularExpressions.Regex('Property OSDComputerName is now = (?<h>[A-Za-z0-9-]{1,63})', 'IgnoreCase')
    }
    @{ Source = 'unattend.xml ComputerName'; Files = 'unattend'; Rank = 2
        Regex = New-Object Text.RegularExpressions.Regex('<ComputerName>\s*(?<h>[A-Za-z0-9-]{1,63})\s*</ComputerName>', 'IgnoreCase')
    }
    @{ Source = 'NetSetup.log'; Files = 'netsetup'; Rank = 3
        Regex = New-Object Text.RegularExpressions.Regex('(?m)\b(HostName|NetbiosName|Machine Name):[ \t]*(?<h>[A-Za-z0-9-]{1,63})[ \t]*\r?$', 'IgnoreCase')
    }
    @{ Source = 'smsts.log OSDComputerName'; Files = 'smsts'; Rank = 4
        Regex = New-Object Text.RegularExpressions.Regex('\bOSDComputerName\b\s*(=|:|to)\s*[''"]?(?<h>[A-Za-z0-9-]{1,63})', 'IgnoreCase')
    }
)
$script:RxGatherProperty = New-Object Text.RegularExpressions.Regex(
    'Property (?<k>Make|Model|SerialNumber|Product) is now = (?<v>[^\]\r\n]+)', 'IgnoreCase')
$script:RxJoinDetail = New-Object Text.RegularExpressions.Regex(
    '(?m)^[^\r\n]*?\s(?<k>Domain|MachineAccountOU|Account|Options):[ \t]+(?<v>[^\r\n]*\S)', 'None')

function Get-BundleTextEntry {
    <#
    .SYNOPSIS
        Lists the text logs in a zip, descending one level into nested zips.
    .PARAMETER Archive
        Open ZipArchive.
    .PARAMETER Prefix
        Path prefix for entries of a nested zip.
    .PARAMETER Notes
        List to record skipped entries in.
    .PARAMETER Depth
        Nesting depth; nested zips are followed one level only.
    .EXAMPLE
        Get-BundleTextEntry -Archive $zip -Notes $notes
    #>
    param($Archive, [string]$Prefix = '', $Notes, [int]$Depth = 0)
    $maxBytes = $script:Options.MaxLogBytes
    foreach ($entry in $Archive.Entries) {
        if ([string]::IsNullOrEmpty($entry.Name)) { continue }
        $full = $Prefix + ($entry.FullName -replace '\\', '/')
        $ext = [IO.Path]::GetExtension($entry.Name).ToLowerInvariant()

        if ($ext -eq '.zip' -and $Depth -lt 1) {
            if ($entry.Length -gt $maxBytes) { [void]$Notes.Add("Skipped nested zip $full ($([Math]::Round($entry.Length / 1MB)) MB)"); continue }
            try {
                $ms = New-Object IO.MemoryStream
                $s = $entry.Open(); try { $s.CopyTo($ms) } finally { $s.Dispose() }
                $ms.Position = 0
                $inner = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Read)
                Get-BundleTextEntry -Archive $inner -Prefix ($full + '/') -Notes $Notes -Depth ($Depth + 1)
            }
            catch { [void]$Notes.Add("Could not open nested zip ${full}: $($_.Exception.Message)") }
            continue
        }
        if ($script:TextExtensions -notcontains $ext) { continue }
        if ($entry.Length -gt $maxBytes) {
            [void]$Notes.Add("Skipped $full ($([Math]::Round($entry.Length / 1MB)) MB > -MaxLogSizeMB $($script:Options.MaxLogSizeMB))")
            continue
        }
        $written = $null
        try { $written = $entry.LastWriteTime.DateTime } catch { $written = $null }
        [pscustomobject]@{ Path = $full; Name = $entry.Name; Entry = $entry; Written = $written }
    }
}

function Invoke-BundleAnalysis {
    <#
    .SYNOPSIS
        Analyses one failure bundle and returns the report object.
    .PARAMETER File
        FileInfo of the .zip.
    .EXAMPLE
        Invoke-BundleAnalysis -File (Get-Item .\PC0123.zip)
    #>
    param([IO.FileInfo]$File)

    $notes = New-Object System.Collections.Generic.List[string]
    $inventory = New-Object System.Collections.Generic.List[string]
    $findings = New-Object System.Collections.Generic.List[object]
    $smsts = New-Object System.Collections.Generic.List[object]
    $hostCandidates = New-Object System.Collections.Generic.List[object]
    $device = @{ Make = ''; Model = ''; SerialNumber = '' }
    $joinDetail = [ordered]@{}

    $fileHost = ''
    $hm = [regex]::Match($File.BaseName, $script:Options.HostnamePattern)
    if ($hm.Success -and $hm.Groups['Host'].Success) { $fileHost = $hm.Groups['Host'].Value }

    $status = 'Analysed'
    $stream = $null
    $zip = $null
    try {
        # FileShare.ReadWrite: never lock a bundle a device may still be uploading.
        $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        return ConvertTo-OsdReportObject -File $File -Status 'Unreadable' -FileHost $fileHost -Notes @("Could not open the bundle: $($_.Exception.Message) (incomplete upload or not a zip).")
    }

    try {
        $entries = @(Get-BundleTextEntry -Archive $zip -Notes $notes)
        if ($entries.Count -eq 0) {
            return ConvertTo-OsdReportObject -File $File -Status 'Empty' -FileHost $fileHost -Notes (@('No text logs found in the bundle.') + $notes.ToArray())
        }

        foreach ($e in $entries) {
            $leaf = $e.Name.ToLowerInvariant()
            try {
                $ms = New-Object IO.MemoryStream
                $s = $e.Entry.Open(); try { $s.CopyTo($ms) } finally { $s.Dispose() }
                $text = ConvertFrom-BundleEntryByte -Bytes $ms.ToArray()
                $ms.Dispose()
            }
            catch {
                [void]$notes.Add("Could not read $($e.Path): $($_.Exception.Message)")
                continue
            }
            $format = Get-LogFormat -Text $text

            foreach ($rule in $script:HostnameExtractors) {
                if ($leaf -notmatch $rule.Files) { continue }
                foreach ($m in $rule.Regex.Matches($text)) {
                    $hostCandidates.Add([pscustomobject]@{ Name = $m.Groups['h'].Value.ToUpperInvariant(); Source = $rule.Source; Rank = $rule.Rank; Log = $e.Path })
                }
            }
            if ($leaf -match 'ztigather|bdd') {
                foreach ($m in $script:RxGatherProperty.Matches($text)) {
                    $k = $m.Groups['k'].Value
                    if ($k -eq 'Product') { if (-not $device['Model']) { $device['Model'] = $m.Groups['v'].Value.Trim() }; continue }
                    $device[$k] = $m.Groups['v'].Value.Trim()
                }
            }
            if ($leaf -match 'netsetup') {
                foreach ($m in $script:RxJoinDetail.Matches($text)) { $joinDetail[$m.Groups['k'].Value] = $m.Groups['v'].Value.Trim() }
            }

            if ($script:RxSmsts.IsMatch($leaf)) {
                $records = Get-TaskSequenceRecord -Text $text -Log $e.Path -Format $format
                if ($records.Count -gt 0) { $smsts.AddRange($records) }
            }

            # The body of unattend.xml is never scanned for evidence: it can hold credentials.
            if (-not ($leaf -like 'unattend*.xml' -or $leaf -like 'autounattend*.xml')) {
                $applicable = @($script:Signatures | Where-Object { $_.Files.IsMatch($leaf) })
                Find-LogSignature -Text $text -Log $e.Path -Format $format -Applicable $applicable -Findings $findings -Written $e.Written
            }

            $lines = $text.Length - $text.Replace("`n", '').Length
            if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $lines++ }
            switch ($format) {
                'CmTrace' { $inventory.Add(('{0} ({1} lines, {2} errors, {3} warnings)' -f $e.Path, $lines, $script:RxCmError.Matches($text).Count, $script:RxCmWarning.Matches($text).Count)) }
                'Panther' { $inventory.Add(('{0} ({1} lines, {2} errors, {3} warnings)' -f $e.Path, $lines, $script:RxPantherError.Matches($text).Count, $script:RxPantherWarning.Matches($text).Count)) }
                default { $inventory.Add(('{0} ({1} lines)' -f $e.Path, $lines)) }
            }
        }

        if ($smsts.Count -eq 0) {
            $status = 'NoTaskSequenceLog'
            [void]$notes.Add('No smsts.log in the bundle - duration and failed step cannot be determined; root cause is from the other logs only.')
        }

        # ---- Task sequence timeline -------------------------------------------------------------
        $tl = Get-TaskSequenceTimeline -Records $smsts -Notes $notes

        # ---- Hostname -------------------------------------------------------------------------------
        $hostname = ''; $hostSource = ''
        $real = @($hostCandidates | Where-Object { $_.Name -notlike 'MININT-*' -and $_.Name -ne 'LOCALHOST' -and $_.Name -ne '*' } | Sort-Object Rank)
        if ($real.Count -gt 0) {
            $hostname = $real[0].Name; $hostSource = $real[0].Source
        }
        elseif ($fileHost -and $fileHost -notlike 'MININT-*') {
            $hostname = $fileHost.ToUpperInvariant(); $hostSource = 'Bundle file name'
        }
        elseif ($hostCandidates.Count -gt 0) {
            $best = @($hostCandidates.ToArray() | Sort-Object Rank)[0]
            $hostname = $best.Name; $hostSource = "$($best.Source) (WinPE placeholder name)"
            [void]$notes.Add('Only a WinPE MININT-* name was found; the intended OSDComputerName was not in the logs.')
        }
        elseif ($fileHost) {
            $hostname = $fileHost.ToUpperInvariant(); $hostSource = 'Bundle file name'
        }
        if ($hostname -and $fileHost -and $hostSource -ne 'Bundle file name' -and $hostname -ne $fileHost.ToUpperInvariant()) {
            [void]$notes.Add("Bundle file name suggests '$fileHost' but the logs name the device '$hostname'.")
        }
        if ($hostname.Length -gt 15) { [void]$notes.Add("Hostname '$hostname' is longer than 15 characters (NetBIOS limit) - this alone breaks the domain join.") }

        # ---- Root cause -----------------------------------------------------------------------------
        $verdict = Select-RootCause -Findings $findings -Timeline $tl
        $root = $verdict.Primary

        $codeInfo = $null
        if ($tl.ErrorCode) { $codeInfo = ConvertTo-ErrorCode $tl.ErrorCode }
        $codeText = ''; $codeDesc = ''
        if ($null -ne $codeInfo) { $codeText = $codeInfo.Display; $codeDesc = Get-ErrorCodeDescription $codeInfo.Lookup }

        $rootTitle = ''; $rootDetail = ''; $action = ''; $category = ''
        if ($null -ne $root) {
            $rootTitle = $root.Signature.Title
            $category = $root.Signature.Category
            $action = $root.Signature.Action
            $parts = New-Object System.Collections.Generic.List[string]
            [void]$parts.Add($root.Signature.Cause)
            foreach ($k in $root.Detail.Keys) { [void]$parts.Add("$k=$($root.Detail[$k])") }
            if ($root.Signature.Id -eq 'DOMAIN_JOIN') {
                $jc = ''
                if ($root.Detail.Contains('JoinCode')) { $jc = $root.Detail['JoinCode'].ToLowerInvariant() -replace '^0x0*', '0x' }
                if ($jc -and $script:DomainJoinCodes.ContainsKey($jc)) { [void]$parts.Add("Join code ${jc}: $($script:DomainJoinCodes[$jc])") }
                foreach ($k in $joinDetail.Keys) { [void]$parts.Add("$k=$($joinDetail[$k])") }
            }
            if ($root.Signature.Id -in @('APP_EXIT_CODE', 'PACKAGE_PROGRAM') -and $root.Detail.Contains('ExitCode')) {
                $ec = ConvertTo-ErrorCode $root.Detail['ExitCode']
                if ($null -ne $ec) {
                    $d = Get-ErrorCodeDescription $ec.Lookup
                    if ($d) { [void]$parts.Add("Exit code $($ec.Display): $d") }
                }
            }
            if ($root.Signature.Id -eq 'BITS_ERROR' -and $root.Detail.Contains('BitsCode') -and $root.Detail['BitsCode'] -match '^0x8019(?<http>[0-9a-f]{4})$') {
                [void]$parts.Add("HTTP status $([Convert]::ToInt32($Matches['http'], 16)) from the server")
            }
            if ($null -ne $tl.StepStart -and @($tl.RebootTimes).Count -gt 0) {
                $before = @($tl.RebootTimes | Where-Object { $_ -le $tl.StepStart } | Sort-Object)
                if ($before.Count -gt 0) {
                    $gap = $tl.StepStart - $before[$before.Count - 1]
                    $gapText = if ($gap.TotalMinutes -lt 2) { "$([Math]::Round($gap.TotalSeconds)) seconds" } else { "$([Math]::Round($gap.TotalMinutes, 1)) minutes" }
                    [void]$parts.Add("The failing step started $gapText after the task sequence restarted the computer (restart step at $($before[$before.Count - 1].ToString('HH:mm:ss')))")
                }
            }
            if ($null -ne $verdict.Symptom) { [void]$parts.Add("Symptom in smsts.log: $($verdict.Symptom.Signature.Title)") }
            $rootDetail = $parts.ToArray() -join ' | '
        }
        elseif ($codeDesc) {
            $rootTitle = 'Unmatched failure - see error code'
            $rootDetail = $codeDesc
            $action = 'No known signature matched. Review the evidence lines and the failing step; add a signature to this script once the cause is known.'
        }
        elseif ($status -eq 'Analysed') {
            $rootTitle = 'Unknown'
            $action = 'No known signature matched and no error code was found. Review the evidence lines.'
        }

        # ---- One-line summary for the engineer -------------------------------------------------------
        $summary = New-Object System.Collections.Generic.List[string]
        if ($tl.FailedStep) {
            $s = "Failed at step '$($tl.FailedStep)'"
            if ($tl.Application) { $s += " installing '$($tl.Application)'" }
            [void]$summary.Add($s)
        }
        elseif ($status -eq 'NoTaskSequenceLog') { [void]$summary.Add('No smsts.log, so no failed step') }
        else { [void]$summary.Add('No failing step recorded (failed before the task sequence engine ran a step - PXE/WinPE/policy stage - or smsts.log is incomplete)') }
        if ($codeText) {
            $s = "with $codeText"
            if ($codeDesc) { $s += " ($($codeDesc.Split('-')[0].Trim().TrimEnd('.')))" }
            [void]$summary.Add($s)
        }
        if ($rootTitle -and $null -ne $root) {
            if ($null -ne $verdict.Symptom) { [void]$summary.Add("- $($verdict.Symptom.Signature.Title.ToLowerInvariant()); likely cause: $rootTitle") }
            else { [void]$summary.Add("- likely cause: $rootTitle") }
        }
        $summaryText = ($summary.ToArray() -join ' ').Trim() + '.'

        # ---- Evidence -------------------------------------------------------------------------------
        $evidence = New-Object System.Collections.Generic.List[object]
        if ($tl.FailureRecord) {
            $evidence.Add((ConvertTo-EvidenceLine -Kind 'Failure' -Log $tl.FailureRecord.Log -Line $tl.FailureRecord.Line -Time $tl.FailureRecord.Time -Text $tl.FailureRecord.Message))
        }
        foreach ($f in $verdict.Ranked) {
            foreach ($c in $f.Context) { $evidence.Add((ConvertTo-EvidenceLine -Kind "Context:$($f.Signature.Id)" -Log $f.Log -Line 0 -Time $null -Text $c)) }
            $evidence.Add((ConvertTo-EvidenceLine -Kind $f.Signature.Id -Log $f.Log -Line $f.Line -Time $f.Time -Text $f.Text))
        }
        $shown = @{}
        foreach ($ev in $evidence) { $shown["$($ev.Log)|$($ev.Line)"] = $true }
        foreach ($r in $tl.ErrorsBefore) {
            if ($shown.ContainsKey("$($r.Log)|$($r.Line)")) { continue }
            $evidence.Add((ConvertTo-EvidenceLine -Kind 'smsts error' -Log $r.Log -Line $r.Line -Time $r.Time -Text $r.Message))
        }

        $known = @($findings | Group-Object { $_.Signature.Id } | ForEach-Object {
                $first = $_.Group[0]
                $inWindow = @($_.Group | Where-Object { Test-InBuildWindow -Finding $_ -Timeline $tl }).Count
                $afterRestart = @($_.Group | Where-Object { Test-PostRebootNoise -Finding $_ -Timeline $tl }).Count
                $suffix = ''
                if ($inWindow -eq 0) { $suffix = ' (outside this build - older run or reference image logs)' }
                elseif ($inWindow -lt $_.Count) { $suffix = " ($($_.Count - $inWindow) outside this build)" }
                if ($afterRestart -gt 0) { $suffix += " ($afterRestart just after a restart - normal while the network comes up)" }
                '{0} [{1}] x{2}{3}' -f $first.Signature.Title, $first.Signature.Category, $_.Count, $suffix
            })

        return ConvertTo-OsdReportObject -File $File -Status $status -FileHost $fileHost -Hostname $hostname -HostnameSource $hostSource `
            -Timeline $tl -ErrorCode $codeText -ErrorDescription $codeDesc -Summary $summaryText -RootCause $rootTitle `
            -Category $category -RootCauseDetail $rootDetail -Action $action -KnownIssues $known -Evidence $evidence.ToArray() `
            -Inventory $inventory.ToArray() -Notes $notes.ToArray() -Device $device -Contributing $verdict.Contributing `
            -Symptom $(if ($null -ne $verdict.Symptom) { $verdict.Symptom.Signature.Title } else { '' })
    }
    finally {
        if ($null -ne $zip) { $zip.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-TaskSequenceTimeline {
    <#
    .SYNOPSIS
        From smsts.log records: run start, failure time, failed step, error code and the errors
        leading up to the failure.
    .DESCRIPTION
        smsts.log copies from several locations (X:\, C:\_SMSTaskSequence, C:\Windows\CCM\Logs)
        overlap, so records are de-duplicated before sorting.

        Every "Failed to run the action" in the run is collected. The step reported as the failure
        is the LAST one that was neither continued past (continue on error) nor matched by
        -IgnoreStepPattern - so a task sequence built with a failure-handling group that copies the
        logs and then forces a failure reports the step that actually broke, not the forced exit.
        The others are listed in OtherFailures.

        Only the LAST run in the log is reported when a device has retried: a run boundary is a
        task sequence end line followed by a fresh start banner.
    .PARAMETER Records
        smsts.log records from every copy in the bundle.
    .PARAMETER Notes
        List for observations about the timeline.
    .EXAMPLE
        Get-TaskSequenceTimeline -Records $smsts -Notes $notes
    #>
    param($Records, $Notes)
    $result = [ordered]@{
        Start = $null; End = $null; Duration = $null; StartConfidence = ''
        FailedStep = ''; Group = ''; ErrorCode = ''; ErrorSource = ''; FailureDetail = ''
        FailureRecord = $null; ErrorsBefore = @(); OtherFailures = @()
        StepStart = $null; Application = ''; StepLog = @(); StepType = ''; RebootTimes = @(); RebootWindows = @()
    }
    if ($null -eq $Records -or $Records.Count -eq 0) { return [pscustomobject]$result }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Records) {
        if ($null -eq $r.Time) { continue }
        $key = '{0:o}|{1}' -f $r.Time, $r.Message
        if ($seen.Add($key)) { $unique.Add($r) }
    }
    if ($unique.Count -eq 0) { return [pscustomobject]$result }
    # Secondary keys keep same-millisecond entries in log order (Sort-Object has no -Stable in 5.1).
    $sorted = @($unique.ToArray() | Sort-Object -Property Time, Log, Line)
    $n = $sorted.Count

    # ---- Every failure line ------------------------------------------------------------------
    $failures = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $n; $i++) {
        $msg = $sorted[$i].Message
        $f = $null
        $m = $script:RxFailAction.Match($msg)
        if ($m.Success) {
            $f = @{ Index = $i; Step = $m.Groups['step'].Value.Trim(); Code = $m.Groups['code'].Value; Source = $m.Groups['src'].Value.Trim()
                Detail = ($m.Groups['detail'].Value -replace '\s+', ' ').Trim(); Group = ''
            }
        }
        else {
            $m = $script:RxEngineFail.Match($msg)
            $md = $script:RxFailActionDecimal.Match($msg)
            if ($m.Success) {
                $f = @{ Index = $i; Step = $m.Groups['step'].Value.Trim(); Code = $m.Groups['code'].Value; Source = ''; Detail = ''; Group = $m.Groups['group'].Value.Trim() }
            }
            elseif ($md.Success) {
                $f = @{ Index = $i; Step = $md.Groups['step'].Value.Trim(); Code = $md.Groups['code'].Value; Source = ''; Detail = ''; Group = '' }
            }
            else {
                $m = $script:RxFailActionNoCode.Match($msg)
                if ($m.Success) { $f = @{ Index = $i; Step = $m.Groups['step'].Value.Trim(); Code = ''; Source = ''; Detail = ''; Group = '' } }
            }
        }
        if ($null -eq $f) { continue }

        # The engine reports one failure several ways within a few lines; merge them.
        if ($failures.Count -gt 0) {
            $prev = $failures[$failures.Count - 1]
            if ($prev.Step -eq $f.Step -and ($i - $prev.Index) -le 60) {
                foreach ($k in 'Code', 'Source', 'Detail', 'Group') { if (-not $prev[$k] -and $f[$k]) { $prev[$k] = $f[$k] } }
                continue
            }
        }
        $continued = $false
        for ($j = $i + 1; $j -lt [Math]::Min($n, $i + 8); $j++) {
            if ($script:RxContinue.IsMatch($sorted[$j].Message)) { $continued = $true; break }
        }
        $f['Continued'] = $continued
        $ignore = $script:Options.IgnoreStepPattern
        $f['Ignored'] = ($ignore -and $f.Step -match $ignore)
        $failures.Add($f)
    }

    $chosen = $null
    # A failure-handling TS continues past the real failure and then fails on purpose, so an
    # ignored step loses even to a continued one.
    $candidates = @($failures.ToArray() | Where-Object { -not $_.Continued -and -not $_.Ignored })
    if ($candidates.Count -eq 0) { $candidates = @($failures.ToArray() | Where-Object { -not $_.Ignored }) }
    if ($candidates.Count -eq 0) { $candidates = $failures.ToArray() }
    if ($candidates.Count -gt 0) { $chosen = $candidates[$candidates.Count - 1] }

    $failIdx = -1
    if ($null -ne $chosen) {
        $failIdx = $chosen.Index
        $result.FailedStep = $chosen.Step; $result.ErrorCode = $chosen.Code; $result.ErrorSource = $chosen.Source
        $result.FailureDetail = $chosen.Detail; $result.Group = $chosen.Group
        if ($chosen.Ignored) { [void]$Notes.Add("Only failures in steps matching -IgnoreStepPattern were found; reporting '$($chosen.Step)'.") }
    }
    else {
        for ($i = $n - 1; $i -ge 0; $i--) {
            $m = $script:RxTsFail.Match($sorted[$i].Message)
            if ($m.Success) {
                $failIdx = $i
                if ($m.Groups['code'].Success -and $m.Groups['code'].Value -notmatch '^en') { $result.ErrorCode = $m.Groups['code'].Value }
                break
            }
        }
    }
    if ($failIdx -lt 0) {
        [void]$Notes.Add('No task sequence failure line found in smsts.log - the TS may have hung or rebooted unexpectedly; the last smsts.log entry is used as the end time.')
        $failIdx = $n - 1
    }
    $result.FailureRecord = $sorted[$failIdx]

    # ---- Fill gaps from the lines leading up to the failure -----------------------------------
    for ($i = $failIdx; $i -ge 0 -and $i -ge $failIdx - 2000; $i--) {
        $msg = $sorted[$i].Message
        if (-not $result.ErrorCode) {
            $m = $script:RxErrorInMsg.Match($msg)
            if ($m.Success) { $result.ErrorCode = $m.Groups['code'].Value; $result.ErrorSource = $m.Groups['src'].Value.Trim() }
            else {
                $m = $script:RxExitCode.Match($msg)
                if ($m.Success -and $m.Groups['code'].Value -ne '0') { $result.ErrorCode = $m.Groups['code'].Value }
            }
        }
        if (-not $result.FailedStep) {
            $m = $script:RxInstruction.Match($msg)
            if ($m.Success) { $result.FailedStep = $m.Groups['step'].Value.Trim() }
        }
        if (-not $result.Group) {
            $m = $script:RxGroupAbort.Match($msg)
            if ($m.Success -and $i -ge $failIdx - 50) { $result.Group = $m.Groups['g'].Value }
        }
        if ($result.ErrorCode -and $result.FailedStep) { break }
    }
    if (-not $result.Group) {
        for ($i = $failIdx; $i -lt [Math]::Min($n, $failIdx + 50); $i++) {
            $m = $script:RxGroupAbort.Match($sorted[$i].Message)
            if ($m.Success) { $result.Group = $m.Groups['g'].Value; break }
        }
    }

    # ---- Run start -----------------------------------------------------------------------------
    # TSManager prints its banner again after every reboot inside one run, so a banner alone is not
    # a new run. A new run is a banner AFTER a task sequence end line.
    $runStart = -1
    $previousEnd = -1
    for ($i = $failIdx - 1; $i -ge 0; $i--) {
        if ($script:RxTsFail.IsMatch($sorted[$i].Message) -or $script:RxTsSuccess.IsMatch($sorted[$i].Message)) { $previousEnd = $i; break }
    }
    if ($previousEnd -ge 0) {
        for ($i = $previousEnd + 1; $i -le $failIdx; $i++) {
            if ($script:RxRunStart.IsMatch($sorted[$i].Message)) { $runStart = $i; break }
        }
        if ($runStart -ge 0) { [void]$Notes.Add('smsts.log holds more than one task sequence run; only the last run is reported.') }
    }
    if ($runStart -lt 0) {
        for ($i = 0; $i -le $failIdx; $i++) { if ($script:RxRunStart.IsMatch($sorted[$i].Message)) { $runStart = $i; break } }
        if ($runStart -ge 0) { $result.StartConfidence = 'Start marker found' }
    }
    else { $result.StartConfidence = 'Start marker found (earlier run in the same log ignored)' }
    if ($runStart -lt 0) {
        $runStart = 0
        $result.StartConfidence = 'Earliest surviving smsts.log entry (log rolled over - build may have started earlier)'
    }
    $result.Start = $sorted[$runStart].Time
    $result.End = $result.FailureRecord.Time
    $result.Duration = $result.End - $result.Start

    if ($result.Duration.TotalSeconds -lt 0) {
        [void]$Notes.Add('Failure time is earlier than start time - device clock changed during the build; duration is not reliable.')
    }
    elseif ($result.Duration.TotalHours -gt 24) {
        [void]$Notes.Add("Duration over 24 hours ($([Math]::Round($result.Duration.TotalHours, 1)) h) - check the device clock or a retried build.")
    }
    $biases = @($sorted[$runStart..$failIdx] | Where-Object { $_.Bias } | ForEach-Object { $_.Bias } | Select-Object -Unique)
    if ($biases.Count -gt 1) {
        [void]$Notes.Add("Time-zone bias changed during the build ($($biases -join ', ')) - expected when WinPE (default Pacific) hands over to the full OS; duration uses the wall clock.")
    }

    $result.OtherFailures = @($failures.ToArray() | Where-Object { $_.Index -ge $runStart -and $_ -ne $chosen } | ForEach-Object {
            $tag = @()
            if ($_.Continued) { $tag += 'continued' }
            if ($_.Ignored) { $tag += 'ignored by -IgnoreStepPattern' }
            $code = ''; if ($_.Code) { $c = ConvertTo-ErrorCode $_.Code; if ($null -ne $c) { $code = " $($c.Display)" } }
            $t = ''; if ($tag.Count -gt 0) { $t = " [$($tag -join ', ')]" }
            "$($_.Step)$code$t"
        })

    $result.ErrorsBefore = @(
        $sorted[$runStart..$failIdx] | Where-Object { $_.Severity -eq 'Error' -and -not [object]::ReferenceEquals($_, $result.FailureRecord) -and -not $script:RxSmstsNoise.IsMatch($_.Message) } |
            Select-Object -Last $script:Options.EvidenceLines
    )

    # ---- The failing step's own block of smsts.log -----------------------------------------------
    # This is what an engineer reads in CMTrace first, so it is reported in full (key lines) and
    # signatures found inside it outrank anything found in other logs.
    $stepStart = -1
    for ($i = $failIdx; $i -ge [Math]::Max($runStart, $failIdx - 20000); $i--) {
        $m = $script:RxInstruction.Match($sorted[$i].Message)
        if ($m.Success) {
            if (-not $result.FailedStep -or $m.Groups['step'].Value.Trim() -eq $result.FailedStep) {
                $stepStart = $i
                if ($m.Groups['type'].Success) { $result.StepType = $m.Groups['type'].Value -replace '^SMS_TaskSequence_', '' }
                break
            }
            if ($stepStart -lt 0) { $stepStart = -2 - $i }   # remember the nearest instruction of any name
        }
    }
    if ($stepStart -lt -1) { $stepStart = -2 - $stepStart }
    if ($stepStart -lt 0) { $stepStart = [Math]::Max($runStart, $failIdx - 300) }
    $result.StepStart = $sorted[$stepStart].Time

    # When the task sequence restarted the computer. Network errors in the first minutes after a
    # restart are normal while the network comes up, and how soon after a restart the failing step
    # ran is often the clue.
    $reboots = New-Object System.Collections.Generic.List[datetime]
    $windows = New-Object System.Collections.Generic.List[object]
    for ($i = $runStart; $i -le $failIdx; $i++) {
        $m = $script:RxInstruction.Match($sorted[$i].Message)
        if (-not $m.Success -or $sorted[$i].Message -match 'Disabled: 1') { continue }
        $label = $m.Groups['step'].Value + ' ' + $m.Groups['type'].Value
        if ($script:RxRebootStep.IsMatch($m.Groups['type'].Value) -or $script:RxRebootStep.IsMatch($m.Groups['step'].Value.Trim()) -or $label -match '(?i)RebootAction') {
            if ($null -eq $sorted[$i].Time) { continue }
            $reboots.Add($sorted[$i].Time)
            # The task sequence resumes at the first entry after a gap of 20 s or more (the machine
            # was down). Firmware updates can make that many minutes after the restart step.
            $resume = $sorted[$i].Time
            for ($j = $i + 1; $j -le [Math]::Min($failIdx, $i + 5000); $j++) {
                if ($null -eq $sorted[$j].Time -or $null -eq $sorted[$j - 1].Time) { continue }
                if (($sorted[$j].Time - $sorted[$j - 1].Time).TotalSeconds -ge 20) { $resume = $sorted[$j].Time; break }
            }
            $windows.Add([pscustomobject]@{ Restart = $sorted[$i].Time; Settled = $resume.AddMinutes(3) })
        }
    }
    $result.RebootTimes = $reboots.ToArray()
    $result.RebootWindows = $windows.ToArray()
    $block = @($sorted[$stepStart..$failIdx])

    foreach ($r in $block) {
        $m = $script:RxStepApplication.Match($r.Message)
        if ($m.Success) { $result.Application = $m.Groups['a'].Value }
    }
    if (-not $result.FailureDetail) {
        $errs = @($block | Where-Object { $_.Severity -eq 'Error' -and -not [object]::ReferenceEquals($_, $result.FailureRecord) -and -not $script:RxSmstsNoise.IsMatch($_.Message) })
        $failing = @($errs | Where-Object { $_.Message -match '(?i)fail' })
        if ($failing.Count -gt 0) { $result.FailureDetail = $failing[$failing.Count - 1].Message }
        elseif ($errs.Count -gt 0) { $result.FailureDetail = $errs[$errs.Count - 1].Message }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $prevText = $null; $repeat = 0
    foreach ($r in $block) {
        if ($script:RxSmstsNoise.IsMatch($r.Message)) { continue }
        if ($r.Severity -ne 'Error' -and $r.Severity -ne 'Warning' -and -not $script:RxStepKey.IsMatch($r.Message)) { continue }
        $text = Protect-LogText $r.Message 300
        if ($text -eq $prevText) { $repeat++; continue }
        if ($repeat -gt 0) { $lines[$lines.Count - 1] = $lines[$lines.Count - 1] + " (x$($repeat + 1))"; $repeat = 0 }
        $mark = switch ($r.Severity) { 'Error' { 'E' } 'Warning' { 'W' } default { ' ' } }
        $t = ''; if ($null -ne $r.Time) { $t = $r.Time.ToString('HH:mm:ss') }
        $lines.Add(('{0} [{1}] {2,-18} {3}' -f $t, $mark, $r.Component, $text))
        $prevText = $text
    }
    if ($repeat -gt 0) { $lines[$lines.Count - 1] = $lines[$lines.Count - 1] + " (x$($repeat + 1))" }
    $result.StepLog = @($lines.ToArray() | Select-Object -Last 40)
    return [pscustomobject]$result
}

function Test-InBuildWindow {
    <#
    .SYNOPSIS
        True when a finding belongs to the build that failed rather than to an older run or to the
        reference image (whose logs are often baked into the OS and copied into the bundle).
    .DESCRIPTION
        Timestamped findings must fall between 5 minutes before the run started and 30 minutes
        after the failure. Lines with no date (MSI logs, plain text) are judged by their log
        file's last-write time inside the zip: it must be after the run started.
    .PARAMETER Finding
        A finding from Find-LogSignature.
    .PARAMETER Timeline
        Output of Get-TaskSequenceTimeline.
    .EXAMPLE
        Test-InBuildWindow -Finding $f -Timeline $tl
    #>
    param($Finding, $Timeline)
    if ($null -eq $Timeline -or $null -eq $Timeline.Start -or $null -eq $Timeline.End) { return $true }
    if ($null -ne $Finding.Time) {
        return ($Finding.Time -ge $Timeline.Start.AddMinutes(-5) -and $Finding.Time -le $Timeline.End.AddMinutes(30))
    }
    if ($null -ne $Finding.FileWritten) { return ($Finding.FileWritten -ge $Timeline.Start.AddMinutes(-30)) }
    return $true
}

function Test-PostRebootNoise {
    <#
    .SYNOPSIS
        True for a name-resolution / MP connection error between a restart step and three minutes
        after the task sequence resumed, when such errors are expected while the network comes up.
    .PARAMETER Finding
        A finding from Find-LogSignature.
    .PARAMETER Timeline
        Output of Get-TaskSequenceTimeline.
    .EXAMPLE
        Test-PostRebootNoise -Finding $f -Timeline $tl
    #>
    param($Finding, $Timeline)
    if ($Finding.Signature.Id -notin @('DNS', 'MP_UNREACHABLE')) { return $false }
    if ($null -eq $Finding.Time -or $null -eq $Timeline -or $null -eq $Timeline.RebootWindows) { return $false }
    foreach ($w in $Timeline.RebootWindows) {
        if ($Finding.Time -ge $w.Restart -and $Finding.Time -le $w.Settled) { return $true }
    }
    return $false
}

function Test-InStepWindow {
    <#
    .SYNOPSIS
        True when a finding happened while the failing step was running.
    .PARAMETER Finding
        A finding from Find-LogSignature.
    .PARAMETER Timeline
        Output of Get-TaskSequenceTimeline.
    .EXAMPLE
        Test-InStepWindow -Finding $f -Timeline $tl
    #>
    param($Finding, $Timeline)
    if ($null -eq $Timeline -or $null -eq $Timeline.StepStart -or $null -eq $Timeline.End) { return $false }
    if ($null -ne $Finding.Time) { return ($Finding.Time -ge $Timeline.StepStart.AddMinutes(-2) -and $Finding.Time -le $Timeline.End.AddMinutes(1)) }
    if ($null -ne $Finding.FileWritten) { return ($Finding.FileWritten -ge $Timeline.StepStart.AddMinutes(-2)) }
    return $false
}

function Select-RootCause {
    <#
    .SYNOPSIS
        Ranks signature findings: specificity first, then nearness to the failure time.
    .DESCRIPTION
        Findings after the failure (logs written by an on-error group) and long before the run
        started are discounted rather than dropped, since plain-text logs have no timestamps.
    .PARAMETER Findings
        All findings in the bundle.
    .PARAMETER Timeline
        Output of Get-TaskSequenceTimeline.
    .EXAMPLE
        Select-RootCause -Findings $findings -Timeline $tl
    #>
    param($Findings, $Timeline)
    $empty = [pscustomobject]@{ Primary = $null; Symptom = $null; Ranked = @(); Contributing = @() }
    if ($null -eq $Findings -or $Findings.Count -eq 0) { return $empty }

    # Only findings from this build can be the cause, and not the network errors every restart
    # produces. Both stay in KnownIssues, marked.
    $candidates = @($Findings | Where-Object { (Test-InBuildWindow -Finding $_ -Timeline $Timeline) -and -not (Test-PostRebootNoise -Finding $_ -Timeline $Timeline) })
    if ($candidates.Count -eq 0) { return $empty }

    $isSmsts = { param($f) ($f.Log -replace '^.*/', '') -match '^smsts' }
    $scored = foreach ($f in $candidates) {
        $score = [double]$f.Signature.Weight
        if ($null -ne $f.Time -and $null -ne $Timeline.End) {
            $minsBefore = ($Timeline.End - $f.Time).TotalMinutes
            if ($minsBefore -ge 0) { $score += [Math]::Max(0, 10 - ($minsBefore / 6)) }   # up to +10 near the failure
        }
        # smsts.log is the primary record of the build: a signature inside the failing step's own
        # block is the strongest evidence there is, and smsts.log in general outranks other logs.
        if (& $isSmsts $f) {
            $score += 10
            if ($null -ne $f.Time -and $null -ne $Timeline.StepStart -and $f.Time -ge $Timeline.StepStart -and $f.Time -le $Timeline.End) { $score += 30 }
        }
        # A signature that fits the step that failed, or sits on the failure line itself, is
        # strong support.
        if ($Timeline.FailedStep -and $null -ne $f.Signature.StepHint -and $f.Signature.StepHint.IsMatch($Timeline.FailedStep)) { $score += 8 }
        if ($null -ne $Timeline.FailureRecord -and $f.Log -eq $Timeline.FailureRecord.Log -and $f.Line -eq $Timeline.FailureRecord.Line) { $score += 15 }
        [pscustomobject]@{ Finding = $f; Score = $score }
    }
    $ordered = @($scored | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = { $_.Finding.Line } })

    # The best-scoring finding is what the failing step itself reported. If another finding,
    # logged while that step ran, is a known underlying cause of it, that one is the root cause
    # and the step's own report is the symptom.
    $primary = $ordered[0].Finding
    $symptom = $null
    $explainer = @($ordered | Where-Object { $_.Finding.Signature.Explains -contains $primary.Signature.Id -and (Test-InStepWindow -Finding $_.Finding -Timeline $Timeline) } | Select-Object -First 1)
    if ($explainer.Count -gt 0) { $symptom = $primary; $primary = $explainer[0].Finding }

    # Evidence: root cause first, then the symptom, then the next best; up to three lines each.
    $idOrder = New-Object System.Collections.Generic.List[string]
    $idOrder.Add($primary.Signature.Id)
    if ($null -ne $symptom) { $idOrder.Add($symptom.Signature.Id) }
    foreach ($s in $ordered) { if (-not $idOrder.Contains($s.Finding.Signature.Id) -and $idOrder.Count -lt 4) { $idOrder.Add($s.Finding.Signature.Id) } }
    $ranked = New-Object System.Collections.Generic.List[object]
    foreach ($id in $idOrder) {
        foreach ($s in @($ordered | Where-Object { $_.Finding.Signature.Id -eq $id } | Select-Object -First 3)) { $ranked.Add($s.Finding) }
    }

    # Contributing factors: other signatures from this build, outside the failing step's own smsts.log
    # block, from ten minutes before the step started to the failure. Older errors that the build
    # got past are not reported as contributing.
    $contributing = New-Object System.Collections.Generic.List[string]
    $seenIds = @{ $primary.Signature.Id = $true }
    if ($null -ne $symptom) { $seenIds[$symptom.Signature.Id] = $true }
    foreach ($s in $ordered) {
        $f = $s.Finding
        if ($seenIds.ContainsKey($f.Signature.Id) -or $f.Signature.Weight -lt 40) { continue }
        # Lines inside the failing step's own block are the failure itself (shown in StepLog), not
        # something that contributed to it.
        if ((& $isSmsts $f) -and $null -ne $f.Time -and $null -ne $Timeline.StepStart -and $f.Time -ge $Timeline.StepStart -and $f.Time -le $Timeline.End) { continue }
        $when = ''
        if ($null -ne $f.Time -and $null -ne $Timeline.End) {
            $mins = [Math]::Round(($Timeline.End - $f.Time).TotalMinutes)
            $leadUp = $Timeline.End.AddMinutes(-120)
            if ($null -ne $Timeline.StepStart) { $leadUp = $Timeline.StepStart.AddMinutes(-10) }
            if ($f.Time -lt $leadUp) { continue }
            $when = " at $($f.Time.ToString('HH:mm:ss'))"
            if ($mins -gt 0) { $when += " ($mins min before the failure)" }
        }
        $seenIds[$f.Signature.Id] = $true
        $contributing.Add(('{0} - {1}:{2}{3}: {4}' -f $f.Signature.Title, ($f.Log -replace '^.*/', ''), $f.Line, $when, (Protect-LogText $f.Text 160)))
        if ($contributing.Count -ge 4) { break }
    }
    return [pscustomobject]@{ Primary = $primary; Symptom = $symptom; Ranked = $ranked.ToArray(); Contributing = $contributing.ToArray() }
}

function ConvertTo-EvidenceLine {
    <#
    .SYNOPSIS
        Builds one evidence line.
    .PARAMETER Kind
        What the line shows (signature id, Failure, smsts error).
    .PARAMETER Log
        Path of the log inside the bundle.
    .PARAMETER Line
        Line number (0 = context line).
    .PARAMETER Time
        Wall-clock time or $null.
    .PARAMETER Text
        The line; credentials are masked.
    .EXAMPLE
        ConvertTo-EvidenceLine -Kind Failure -Log smsts.log -Line 10 -Time (Get-Date) -Text 'x'
    #>
    param([string]$Kind, [string]$Log, [int]$Line, $Time, [string]$Text)
    $t = ''
    if ($null -ne $Time) { $t = ([datetime]$Time).ToString('yyyy-MM-dd HH:mm:ss') }
    [pscustomobject]@{ Kind = $Kind; Log = $Log; Line = $Line; Time = $t; Text = (Protect-LogText $Text) }
}

function ConvertTo-OsdReportObject {
    <#
    .SYNOPSIS
        Builds the per-bundle report object with a fixed property order.
    .PARAMETER File
        The bundle.
    .PARAMETER Status
        Analysed, NoTaskSequenceLog, Empty or Unreadable.
    .PARAMETER FileHost
        Hostname derived from the file name.
    .PARAMETER Hostname
        Resolved hostname.
    .PARAMETER HostnameSource
        Where the hostname came from.
    .PARAMETER Timeline
        Output of Get-TaskSequenceTimeline.
    .PARAMETER ErrorCode
        Display form of the error code.
    .PARAMETER ErrorDescription
        Decoded error code.
    .PARAMETER Summary
        One-line summary.
    .PARAMETER RootCause
        Root cause title.
    .PARAMETER Category
        Root cause category.
    .PARAMETER RootCauseDetail
        Root cause explanation and captured details.
    .PARAMETER Action
        Recommended next action.
    .PARAMETER KnownIssues
        Every signature that matched.
    .PARAMETER Evidence
        Evidence lines.
    .PARAMETER Inventory
        Logs reviewed.
    .PARAMETER Notes
        Caveats.
    .PARAMETER Device
        Make/Model/SerialNumber hashtable.
    .PARAMETER Contributing
        Other signatures from this build shortly before the failure.
    .PARAMETER Symptom
        What the failing step itself reported, when a deeper root cause was found.
    .EXAMPLE
        ConvertTo-OsdReportObject -File $f -Status Unreadable
    #>
    param(
        [IO.FileInfo]$File, [string]$Status, [string]$FileHost = '', [string]$Hostname = '', [string]$HostnameSource = '',
        $Timeline = $null, [string]$ErrorCode = '', [string]$ErrorDescription = '', [string]$Summary = '',
        [string]$RootCause = '', [string]$Category = '', [string]$RootCauseDetail = '', [string]$Action = '',
        [string[]]$KnownIssues = @(), [object[]]$Evidence = @(), [string[]]$Inventory = @(), [string[]]$Notes = @(),
        [hashtable]$Device = @{ Make = ''; Model = ''; SerialNumber = '' },
        [string[]]$Contributing = @(),
        [string]$Symptom = ''
    )
    if (-not $Hostname -and $FileHost) { $Hostname = $FileHost.ToUpperInvariant(); $HostnameSource = 'Bundle file name' }
    if (-not $Summary) {
        $Summary = switch ($Status) {
            'Unreadable' { 'Bundle could not be opened.' }
            'Empty' { 'Bundle contains no logs.' }
            default { '' }
        }
    }
    $start = $null; $end = $null; $duration = ''; $durationMin = $null; $conf = ''; $step = ''; $group = ''; $src = ''; $detail = ''
    $others = @(); $app = ''; $stepLog = @(); $stepType = ''
    if ($null -ne $Timeline) {
        $start = $Timeline.Start; $end = $Timeline.End; $conf = $Timeline.StartConfidence
        $step = $Timeline.FailedStep; $group = $Timeline.Group; $src = $Timeline.ErrorSource; $detail = Protect-LogText $Timeline.FailureDetail
        $others = @($Timeline.OtherFailures)
        $app = $Timeline.Application
        $stepLog = @($Timeline.StepLog)
        $stepType = $Timeline.StepType
        if ($null -ne $Timeline.Duration) {
            $d = $Timeline.Duration
            $sign = ''
            if ($d.TotalSeconds -lt 0) { $sign = '-'; $d = $d.Negate() }
            $duration = '{0}{1:00}:{2:00}:{3:00}' -f $sign, [Math]::Floor($d.TotalHours), $d.Minutes, $d.Seconds
            $durationMin = [Math]::Round($Timeline.Duration.TotalMinutes, 1)
        }
    }
    [pscustomobject][ordered]@{
        PSTypeName = 'Richo.OsdFailureReport'
        Hostname = $Hostname
        Status = $Status
        Summary = $Summary
        FailedStep = $step
        FailedGroup = $group
        StepType = $stepType
        Application = $app
        ErrorCode = $ErrorCode
        ErrorDescription = $ErrorDescription
        ErrorSource = $src
        FailureMessage = $detail
        RootCause = $RootCause
        Category = $Category
        Symptom = $Symptom
        RootCauseDetail = $RootCauseDetail
        RecommendedAction = $Action
        ContributingFactors = $Contributing
        StepLog = $stepLog
        BuildStart = $start
        FailureTime = $end
        Duration = $duration
        DurationMinutes = $durationMin
        StartConfidence = $conf
        Make = $Device.Make
        Model = $Device.Model
        SerialNumber = $Device.SerialNumber
        HostnameSource = $HostnameSource
        OtherFailures = $others
        KnownIssues = $KnownIssues
        Evidence = $Evidence
        LogsReviewed = $Inventory
        Notes = $Notes
        BundleName = $File.Name
        BundlePath = $File.FullName
        BundleUploaded = $File.LastWriteTime
        BundleSizeKB = [Math]::Round($File.Length / 1KB)
        ScriptVersion = $ScriptVersion
    }
}
# endregion

# ---------------------------------------------------------------------------------------------
# region REPORTS
# ---------------------------------------------------------------------------------------------
function Export-OsdFailureReport {
    <#
    .SYNOPSIS
        Writes CSV summary, CSV evidence, JSON and HTML reports.
    .PARAMETER Results
        Report objects.
    .PARAMETER Directory
        Output folder.
    .PARAMETER Scope
        Text describing the selection, shown in the HTML header.
    .EXAMPLE
        Export-OsdFailureReport -Results $results -Directory C:\Temp -Scope 'Last 24 hours'
    #>
    param([object[]]$Results, [string]$Directory, [string]$Scope)
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -Path $Directory -ItemType Directory -Force | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $base = Join-Path $Directory "OsdFailureReport-$stamp"

    $flat = foreach ($r in $Results) {
        [pscustomobject][ordered]@{
            Hostname = $r.Hostname; Status = $r.Status; Summary = $r.Summary; FailedStep = $r.FailedStep; FailedGroup = $r.FailedGroup; StepType = $r.StepType; Application = $r.Application
            ErrorCode = $r.ErrorCode; ErrorDescription = $r.ErrorDescription; RootCause = $r.RootCause; Category = $r.Category; Symptom = $r.Symptom
            RootCauseDetail = $r.RootCauseDetail; RecommendedAction = $r.RecommendedAction; ContributingFactors = ($r.ContributingFactors -join '; ')
            BuildStart = $(if ($r.BuildStart) { $r.BuildStart.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            FailureTime = $(if ($r.FailureTime) { $r.FailureTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            Duration = $r.Duration; DurationMinutes = $r.DurationMinutes; StartConfidence = $r.StartConfidence
            Make = $r.Make; Model = $r.Model; SerialNumber = $r.SerialNumber; HostnameSource = $r.HostnameSource
            OtherFailures = ($r.OtherFailures -join '; '); KnownIssues = ($r.KnownIssues -join '; '); Notes = ($r.Notes -join '; ')
            BundleName = $r.BundleName; BundleUploaded = $r.BundleUploaded.ToString('yyyy-MM-dd HH:mm:ss'); BundlePath = $r.BundlePath
            ScriptVersion = $r.ScriptVersion
        }
    }
    $flat | Export-Csv -Path "$base-summary.csv" -NoTypeInformation -Encoding UTF8

    $ev = foreach ($r in $Results) {
        foreach ($e in $r.Evidence) {
            [pscustomobject][ordered]@{ Hostname = $r.Hostname; BundleName = $r.BundleName; Kind = $e.Kind; Log = $e.Log; Line = $e.Line; Time = $e.Time; Text = $e.Text }
        }
        foreach ($l in $r.StepLog) {
            [pscustomobject][ordered]@{ Hostname = $r.Hostname; BundleName = $r.BundleName; Kind = 'Failed step (smsts.log)'; Log = 'smsts.log'; Line = 0; Time = ''; Text = $l }
        }
    }
    @($ev) | Export-Csv -Path "$base-evidence.csv" -NoTypeInformation -Encoding UTF8

    $Results | ConvertTo-Json -Depth 6 | Out-File -FilePath "$base.json" -Encoding utf8

    $enc = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>OSD Failure Report</title><style>')
    [void]$sb.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b;background:#fff}h1{font-size:22px}h2{font-size:17px;margin-top:28px;border-bottom:2px solid #ddd;padding-bottom:4px}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;font-size:13px;margin:8px 0}th,td{border:1px solid #d0d0d0;padding:4px 6px;text-align:left;vertical-align:top}th{background:#f0f2f5}')
    [void]$sb.AppendLine('.k{width:170px;font-weight:600;background:#fafafa}.mono{font-family:Consolas,monospace;font-size:12px;white-space:pre-wrap;word-break:break-word}.bad{color:#b00020;font-weight:600}.muted{color:#666}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine("<h1>MECM OSD failure report</h1><p class='muted'>$(& $enc $Scope) &middot; $($Results.Count) bundle(s) &middot; generated $((Get-Date).ToString('yyyy-MM-dd HH:mm')) &middot; Get-OsdFailureReport $ScriptVersion</p>")

    [void]$sb.AppendLine('<h2>Failures by cause</h2><table><tr><th>Count</th><th>Root cause</th><th>Error code</th><th>Failed step</th><th>Devices</th></tr>')
    foreach ($g in ($Results | Group-Object { '{0}|{1}|{2}' -f $_.RootCause, $_.ErrorCode, $_.FailedStep } | Sort-Object Count -Descending)) {
        $f = $g.Group[0]
        $hosts = ($g.Group | ForEach-Object { $_.Hostname } | Sort-Object -Unique) -join ', '
        [void]$sb.AppendLine("<tr><td>$($g.Count)</td><td>$(& $enc $f.RootCause)</td><td>$(& $enc $f.ErrorCode)</td><td>$(& $enc $f.FailedStep)</td><td>$(& $enc $hosts)</td></tr>")
    }
    [void]$sb.AppendLine('</table>')

    [void]$sb.AppendLine('<h2>Devices</h2><table><tr><th>Hostname</th><th>Uploaded</th><th>Duration</th><th>Failed step</th><th>Error</th><th>Root cause</th><th>Model</th></tr>')
    foreach ($r in $Results) {
        [void]$sb.AppendLine("<tr><td><a href='#$(& $enc $r.BundleName)'>$(& $enc $r.Hostname)</a></td><td>$($r.BundleUploaded.ToString('yyyy-MM-dd HH:mm'))</td><td>$(& $enc $r.Duration)</td><td>$(& $enc $r.FailedStep)</td><td>$(& $enc $r.ErrorCode)</td><td>$(& $enc $r.RootCause)</td><td>$(& $enc $r.Model)</td></tr>")
    }
    [void]$sb.AppendLine('</table>')

    foreach ($r in $Results) {
        [void]$sb.AppendLine("<h2 id='$(& $enc $r.BundleName)'>$(& $enc $r.Hostname) <span class='muted'>&mdash; $(& $enc $r.BundleName)</span></h2><table>")
        $rows = [ordered]@{
            'Summary' = $r.Summary; 'Failed step' = $r.FailedStep; 'Group' = $r.FailedGroup; 'Step type' = $r.StepType; 'Application' = $r.Application
            'Error code' = ('{0} {1}' -f $r.ErrorCode, $r.ErrorDescription).Trim(); 'Failure message' = $r.FailureMessage
            'Root cause' = $(if ($r.Category) { '{0} [{1}]' -f $r.RootCause, $r.Category } else { $r.RootCause }); 'Detail' = $r.RootCauseDetail
            'Symptom (what the step reported)' = $r.Symptom
            'Recommended action' = $r.RecommendedAction
            'Contributing factors' = ($r.ContributingFactors -join "`n")
            'Failed step in smsts.log' = ($r.StepLog -join "`n")
            'Build start' = $(if ($r.BuildStart) { $r.BuildStart.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            'Failure time' = $(if ($r.FailureTime) { $r.FailureTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            'Duration' = ('{0} {1}' -f $r.Duration, $(if ($r.StartConfidence) { "($($r.StartConfidence))" } else { '' })).Trim()
            'Device' = (@($r.Make, $r.Model, $(if ($r.SerialNumber) { "S/N $($r.SerialNumber)" } else { '' })) | Where-Object { $_ }) -join ' / '
            'Hostname source' = $r.HostnameSource; 'Other failures in run' = ($r.OtherFailures -join "`n"); 'All known issues' = ($r.KnownIssues -join "`n"); 'Notes' = ($r.Notes -join "`n")
            'Logs reviewed' = ($r.LogsReviewed -join "`n"); 'Status' = $r.Status
        }
        foreach ($k in $rows.Keys) {
            if ([string]::IsNullOrWhiteSpace([string]$rows[$k])) { continue }
            $cls = 'mono'; if ($k -in @('Summary', 'Root cause')) { $cls = 'bad' }
            [void]$sb.AppendLine("<tr><td class='k'>$k</td><td class='$cls'>$(& $enc $rows[$k])</td></tr>")
        }
        [void]$sb.AppendLine('</table>')
        if (@($r.Evidence).Count -gt 0) {
            [void]$sb.AppendLine('<table><tr><th>Kind</th><th>Log</th><th>Line</th><th>Time</th><th>Text</th></tr>')
            foreach ($e in $r.Evidence) {
                [void]$sb.AppendLine("<tr><td>$(& $enc $e.Kind)</td><td class='mono'>$(& $enc $e.Log)</td><td>$($e.Line)</td><td>$(& $enc $e.Time)</td><td class='mono'>$(& $enc $e.Text)</td></tr>")
            }
            [void]$sb.AppendLine('</table>')
        }
    }
    [void]$sb.AppendLine('</body></html>')
    [IO.File]::WriteAllText("$base.html", $sb.ToString(), (New-Object Text.UTF8Encoding $false))
    return $base
}
# endregion

# ---------------------------------------------------------------------------------------------
# region SELECTION
# ---------------------------------------------------------------------------------------------
function Select-OsdBundle {
    <#
    .SYNOPSIS
        Lets the operator pick bundles to analyse from a grid view, or a console list when no
        grid view is available.
    .PARAMETER Bundle
        Candidate bundles, newest first.
    .PARAMETER Scope
        Text describing the selection, shown in the title.
    .EXAMPLE
        $picked = Select-OsdBundle -Bundle $files -Scope 'Last 24 hours'
    #>
    param([AllowEmptyCollection()][IO.FileInfo[]]$Bundle, [string]$Scope)
    # Results are emitted one by one; the caller collects them with @().
    if ($null -eq $Bundle -or $Bundle.Count -eq 0) { return }

    $now = Get-Date
    $rows = for ($n = 0; $n -lt $Bundle.Count; $n++) {
        $b = $Bundle[$n]
        [pscustomobject][ordered]@{
            '#' = $n + 1
            Name = $b.Name
            Uploaded = $b.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            AgeHours = [Math]::Round(($now - $b.LastWriteTime).TotalHours, 1)
            SizeKB = [int][Math]::Ceiling($b.Length / 1KB)
            Folder = $b.DirectoryName
        }
    }

    $indexes = @()
    if (Get-Command -Name Out-GridView -ErrorAction SilentlyContinue) {
        $title = "Select OSD failure bundle(s) to analyse - $Scope - $($Bundle.Count) listed (Ctrl/Shift for several)"
        try {
            $indexes = @($rows | Out-GridView -Title $title -OutputMode Multiple | ForEach-Object { $_.'#' - 1 })
            foreach ($ix in $indexes) { $Bundle[$ix] }
            return
        }
        catch {
            # Out-GridView exists but cannot open a window (no desktop session); use the console.
            Write-OsdLog "Grid view unavailable ($($_.Exception.Message)); using a console list." -Level WARN
        }
    }

    $shown = [Math]::Min($Bundle.Count, 50)
    $listing = ($rows | Select-Object -First $shown | Format-Table -AutoSize | Out-String -Width 200).TrimEnd()
    Write-OsdLog "Bundles ($Scope), newest first$(if ($shown -lt $Bundle.Count) { " - showing $shown of $($Bundle.Count); narrow with -LastHours or -ComputerName" }):`n$listing" -Level INFO
    $answer = Read-Host 'Number(s) to analyse, e.g. 1 or 1,3 or 2-5 (blank to cancel)'
    foreach ($part in ("$answer" -split ',')) {
        $part = $part.Trim()
        if ($part -match '^(\d+)\s*-\s*(\d+)$') {
            $from = [int]$Matches[1]; $to = [int]$Matches[2]
            if ($from -gt $to) { $from, $to = $to, $from }
            $indexes += ($from..$to)
        }
        elseif ($part -match '^\d+$') { $indexes += [int]$part }
        elseif ($part) { Write-OsdLog "Ignored '$part' - not a number or range." -Level WARN }
    }
    $valid = @($indexes | Select-Object -Unique | Where-Object { $_ -ge 1 -and $_ -le $shown })
    if (@($indexes | Select-Object -Unique).Count -ne $valid.Count) { Write-OsdLog "Numbers outside 1-$shown were ignored." -Level WARN }
    foreach ($ix in $valid) { $Bundle[$ix - 1] }
}

function Write-OsdFaultDetail {
    <#
    .SYNOPSIS
        Writes one bundle's fault details, including evidence lines, to the console log.
    .PARAMETER Result
        A report object from Invoke-BundleAnalysis.
    .EXAMPLE
        Write-OsdFaultDetail -Result $r
    #>
    param($Result)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine(('=' * 100))
    [void]$sb.AppendLine("$($Result.Hostname)  ($($Result.BundleName), uploaded $($Result.BundleUploaded.ToString('yyyy-MM-dd HH:mm')))")
    [void]$sb.AppendLine(('=' * 100))
    $fields = [ordered]@{
        'Summary' = $Result.Summary
        'Failed step' = $Result.FailedStep
        'Group' = $Result.FailedGroup
        'Step type' = $Result.StepType
        'Application' = $Result.Application
        'Error code' = ('{0}  {1}' -f $Result.ErrorCode, $Result.ErrorDescription).Trim()
        'Failure message' = $Result.FailureMessage
        'Root cause' = $(if ($Result.Category) { '{0} [{1}]' -f $Result.RootCause, $Result.Category } else { $Result.RootCause })
        'Symptom' = $Result.Symptom
        'Detail' = $Result.RootCauseDetail
        'Recommended action' = $Result.RecommendedAction
        'Build start' = $(if ($Result.BuildStart) { $Result.BuildStart.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
        'Failure time' = $(if ($Result.FailureTime) { $Result.FailureTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
        'Duration' = ('{0}  {1}' -f $Result.Duration, $(if ($Result.StartConfidence) { "($($Result.StartConfidence))" } else { '' })).Trim()
        'Device' = (@($Result.Make, $Result.Model, $(if ($Result.SerialNumber) { "S/N $($Result.SerialNumber)" } else { '' })) | Where-Object { $_ }) -join ' / '
        'Hostname source' = $Result.HostnameSource
        'Status' = $Result.Status
    }
    foreach ($k in $fields.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$fields[$k])) { [void]$sb.AppendLine(('{0,-19}: {1}' -f $k, $fields[$k])) }
    }
    $logsWithFindings = @($Result.Evidence | ForEach-Object { $_.Log } | Select-Object -Unique)
    $logSummary = @("$(@($Result.LogsReviewed).Count) logs reviewed (full list in the object, CSV and HTML); smsts.log and logs with evidence:")
    $logSummary += @($Result.LogsReviewed | Where-Object { $l = $_; ($l -match '(^|/)smsts') -or @($logsWithFindings | Where-Object { $l.StartsWith("$_ (") }).Count -gt 0 })
    foreach ($list in @(@('Failed step in smsts.log (key lines)', $Result.StepLog), @('Contributing factors', $Result.ContributingFactors), @('Other failures', $Result.OtherFailures), @('Known issues', $Result.KnownIssues), @('Notes', $Result.Notes), @('Logs', $logSummary))) {
        $items = @($list[1])
        if ($items.Count -eq 0) { continue }
        [void]$sb.AppendLine("$($list[0]):")
        foreach ($item in $items) { [void]$sb.AppendLine("    $item") }
    }
    $evidence = @($Result.Evidence)
    if ($evidence.Count -gt 0) {
        [void]$sb.AppendLine('Evidence:')
        foreach ($e in $evidence) {
            $where = $e.Log
            if ($e.Line -gt 0) { $where = "$($e.Log):$($e.Line)" }
            [void]$sb.AppendLine(('    [{0}] {1} {2}' -f $e.Kind, $where, $e.Time).TrimEnd())
            [void]$sb.AppendLine("        $($e.Text)")
        }
    }
    Write-OsdLog $sb.ToString().TrimEnd() -Level INFO
}
# endregion

# ---------------------------------------------------------------------------------------------
# region MAIN
# ---------------------------------------------------------------------------------------------
try {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $cutoff = $null
    $scope = 'All bundles'
    if ($PSCmdlet.ParameterSetName -eq 'Hours') { $cutoff = (Get-Date).AddHours(-$LastHours); $scope = "Last $LastHours hours" }
    elseif ($PSCmdlet.ParameterSetName -eq 'Since') { $cutoff = $Since; $scope = "Since $($Since.ToString('yyyy-MM-dd HH:mm'))" }

    # ---- Find bundles ---------------------------------------------------------------------------
    $bundles = New-Object System.Collections.Generic.List[IO.FileInfo]
    foreach ($p in $Path) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-OsdLog "Path not found or not accessible: $p" -Level WARN
            continue
        }
        $item = Get-Item -LiteralPath $p
        if ($item -is [IO.FileInfo]) { $bundles.Add($item); continue }
        Write-OsdLog "Listing $Filter in $p$(if ($Recurse) { ' (recursive)' })" -Level INFO
        foreach ($f in (Get-ChildItem -LiteralPath $p -Filter $Filter -File -Recurse:$Recurse -ErrorAction Continue)) { $bundles.Add($f) }
    }
    $total = $bundles.Count
    $selected = @($bundles.ToArray() | Where-Object { $null -eq $cutoff -or $_.LastWriteTime -ge $cutoff } | Sort-Object LastWriteTime -Descending)
    Write-OsdLog "$total bundle(s) found, $($selected.Count) in scope ($scope)." -Level INFO

    $postFilterHost = $false
    if ($ComputerName -and $SelectBundle) {
        # The operator chooses from the list, so only narrow it by file name.
        $byName = @($selected | Where-Object { $n = $_.BaseName; @($ComputerName | Where-Object { $n -like "*$_*" }).Count -gt 0 })
        if ($byName.Count -gt 0) { $selected = $byName }
        else { Write-OsdLog 'No bundle file name matches -ComputerName; listing every in-scope bundle.' -Level INFO }
    }
    elseif ($ComputerName) {
        $byName = @($selected | Where-Object { $n = $_.BaseName; @($ComputerName | Where-Object { $n -like "*$_*" }).Count -gt 0 })
        if ($byName.Count -gt 0) {
            $selected = $byName
            Write-OsdLog "$($selected.Count) bundle(s) match -ComputerName by file name." -Level INFO
        }
        else {
            $postFilterHost = $true
            Write-OsdLog 'No bundle file name matches -ComputerName; opening every in-scope bundle and filtering on the hostname in the logs.' -Level INFO
        }
    }

    if ($SelectBundle) {
        if ($selected.Count -eq 0) {
            Write-OsdLog 'No bundles to choose from.' -Level WARN
            return
        }
        $selected = @(Select-OsdBundle -Bundle $selected -Scope $scope)
        if ($selected.Count -eq 0) {
            Write-OsdLog 'No bundle selected - nothing analysed.' -Level INFO
            return
        }
        $scope = "$scope, $($selected.Count) selected"
        Write-OsdLog "Selected: $(($selected | ForEach-Object { $_.Name }) -join ', ')" -Level INFO
    }

    # ---- Analyse --------------------------------------------------------------------------------
    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($b in $selected) {
        $i++
        Write-Progress -Activity 'Analysing OSD failure bundles' -Status "$i of $($selected.Count): $($b.Name)" -PercentComplete (100 * $i / [Math]::Max(1, $selected.Count))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-BundleAnalysis -File $b
        }
        catch {
            Write-OsdLog "$($b.Name): analysis failed - $($_.Exception.Message)" -Level WARN
            $r = ConvertTo-OsdReportObject -File $b -Status 'Unreadable' -Notes @("Analysis failed: $($_.Exception.Message)")
        }
        $sw.Stop()
        if ($postFilterHost -and @($ComputerName | Where-Object { $r.Hostname -like $_ }).Count -eq 0) { continue }

        $results.Add($r)
        $lvl = 'INFO'; if ($r.Status -eq 'Unreadable') { $lvl = 'WARN' }
        Write-OsdLog ('{0,-15} | {1,8} | {2} | {3}  [{4} ms]' -f $r.Hostname, $r.Duration, $r.Summary, $r.RootCause, $sw.ElapsedMilliseconds) -Level $lvl
        if ($SelectBundle) { Write-OsdFaultDetail -Result $r }
        $r
    }
    Write-Progress -Activity 'Analysing OSD failure bundles' -Completed

    # ---- Fleet summary --------------------------------------------------------------------------
    if ($results.Count -gt 0) {
        Write-OsdLog "---- $($results.Count) failure(s), by cause ----" -Level INFO
        foreach ($g in ($results.ToArray() | Group-Object { if ($_.RootCause) { $_.RootCause } else { "Bundle $($_.Status.ToLowerInvariant())" } } | Sort-Object Count -Descending)) {
            $name = $g.Name
            Write-OsdLog ('{0,4} x {1}' -f $g.Count, $name) -Level INFO
        }
    }
    else {
        Write-OsdLog 'No bundles to report.' -Level INFO
    }

    if ($OutputPath -and $results.Count -gt 0) {
        $base = Export-OsdFailureReport -Results $results.ToArray() -Directory $OutputPath -Scope $scope
        Write-OsdLog "Reports written: $base-summary.csv, $base-evidence.csv, $base.json, $base.html" -Level INFO
    }

    if ($GridView -and $results.Count -gt 0) {
        if (Get-Command -Name Out-GridView -ErrorAction SilentlyContinue) {
            $results.ToArray() | Select-Object Hostname, BundleUploaded, Duration, FailedStep, ErrorCode, RootCause, Summary, RecommendedAction, Model, BundleName |
                Out-GridView -Title "OSD failures - $scope"
        }
        else {
            Write-OsdLog 'Out-GridView is not available in this session.' -Level WARN
        }
    }
}
catch {
    Write-OsdLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
# endregion
