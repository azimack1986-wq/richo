<#
.SYNOPSIS
    Task sequence step: waits until Windows reports the network as connected, so the Install
    Application steps that follow can download their policy through BITS.

.DESCRIPTION
    Read-only. Changes nothing on the device: it only reads network state and writes it to the step
    output, which OSDRunPowerShellScript copies into smsts.log.

    Why: in failed Windows 11 builds the first Install Application step after a restart failed with
    "Application failed to evaluate". The client's BITS job for the application's policy (CI
    documents) was held with 0x80200010 "There are currently no active network connections"
    because Windows Network List Manager reported "Connected to Network: FALSE" - while task
    sequence traffic to the management point was still working. BITS waits for Windows to report
    the network connected; the step's evaluation retries ran out first.

    The step polls the same Network List Manager state that BITS and the ConfigMgr client use
    (IsConnected), and returns once it has been connected for -StableSeconds in a row. Every state
    change is written out with the time, so smsts.log shows how long the device took to settle.

    If the network is not connected by -TimeoutSeconds it writes a diagnostic snapshot (adapters,
    connection profiles, IP/DNS configuration, the Network Location Awareness service, BITS jobs)
    and then exits 0 so the build carries on as it would have done - or exits 1 with
    -FailOnTimeout, so the build stops at a step whose name says what is wrong instead of 15
    minutes later inside an application install.

    Use: add a "Run PowerShell Script" step before each Install Application step that follows a
    restart (or once after each restart), with this script and, for example,
    "-TimeoutSeconds 900 -StableSeconds 30" as its parameters.

.PARAMETER TimeoutSeconds
    How long to wait for the network to be reported connected. Default 900 (15 minutes).

.PARAMETER PollSeconds
    How often to check. Default 10.

.PARAMETER StableSeconds
    How long the network must stay connected before the step returns. Default 30, because in the
    failed builds Windows reported the network connected at boot and then not connected about three
    minutes later.

.PARAMETER FailOnTimeout
    Exit 1 (fail the step) when the network is never reported connected. Without it the step
    exits 0 after writing the diagnostics.

.EXAMPLE
    .\Wait-OsdNetworkConnected.ps1 -TimeoutSeconds 900 -StableSeconds 30

    As a Run PowerShell Script step before Install Application.

.EXAMPLE
    .\Wait-OsdNetworkConnected.ps1 -TimeoutSeconds 600 -FailOnTimeout

    Stop the build with a clear failure if the network has not connected within ten minutes.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(10, 7200)]
    [int]$TimeoutSeconds = 900,

    [ValidateRange(1, 300)]
    [int]$PollSeconds = 10,

    [ValidateRange(0, 3600)]
    [int]$StableSeconds = 30,

    [switch]$FailOnTimeout
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

# The step output is the log: OSDRunPowerShellScript copies the success stream into smsts.log.
function Write-StepLog {
    <#
    .SYNOPSIS
        Writes a timestamped line to the step output (and so to smsts.log).
    .PARAMETER Message
        The text to write.
    .EXAMPLE
        Write-StepLog 'Network connected'
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Write-Output ('{0} Wait-OsdNetworkConnected: {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message)
}

function Get-NetworkConnectedState {
    <#
    .SYNOPSIS
        Reads the connectivity state BITS and the ConfigMgr client use (Network List Manager), plus
        each connection profile's IPv4/IPv6 connectivity.
    .DESCRIPTION
        Connected is $true or $false from Network List Manager. When NLM cannot be read, it falls
        back to the connection profiles: connected when any profile has LocalNetwork or Internet
        connectivity.
    .EXAMPLE
        Get-NetworkConnectedState
    #>
    $connected = $null
    $internet = $null
    try {
        $nlm = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]'DCB00C01-570F-4A9B-8D69-199FDBA5723B'))
        $connected = [bool]$nlm.IsConnected
        $internet = [bool]$nlm.IsConnectedToInternet
    }
    catch {
        $connected = $null
    }

    $profiles = @()
    try {
        $profiles = @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object {
                '{0}: {1}, IPv4 {2}, IPv6 {3}' -f $_.InterfaceAlias, $_.NetworkCategory, $_.IPv4Connectivity, $_.IPv6Connectivity
            })
        if ($null -eq $connected) {
            $connected = [bool]@(Get-NetConnectionProfile -ErrorAction Stop | Where-Object { "$($_.IPv4Connectivity)" -in @('LocalNetwork', 'Internet') -or "$($_.IPv6Connectivity)" -in @('LocalNetwork', 'Internet') }).Count
        }
    }
    catch {
        $profiles = @("Get-NetConnectionProfile failed: $($_.Exception.Message)")
    }

    [pscustomobject]@{
        Connected = [bool]$connected
        Internet = $internet
        Source = $(if ($null -ne $internet) { 'Network List Manager' } else { 'connection profiles' })
        Profiles = $profiles
    }
}

function Write-NetworkDiagnostic {
    <#
    .SYNOPSIS
        Writes a snapshot of the network state for the engineer: adapters, profiles, IP/DNS,
        the Network Location Awareness service and BITS jobs. Every probe is optional.
    .EXAMPLE
        Write-NetworkDiagnostic
    #>
    Write-StepLog '---- Network diagnostics ----'
    $probes = [ordered]@{
        'Adapters' = { Get-NetAdapter -ErrorAction Stop | ForEach-Object { '{0} [{1}] {2} {3}' -f $_.Name, $_.InterfaceDescription, $_.Status, $_.LinkSpeed } }
        'Connection profiles' = { Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object { '{0}: {1} ({2}), IPv4 {3}, IPv6 {4}' -f $_.InterfaceAlias, $_.Name, $_.NetworkCategory, $_.IPv4Connectivity, $_.IPv6Connectivity } }
        'IP configuration' = { Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $null -ne $_.IPv4Address } | ForEach-Object { '{0}: IP {1}, gateway {2}, DNS {3}' -f $_.InterfaceAlias, (@($_.IPv4Address | ForEach-Object { $_.IPAddress }) -join ','), (@($_.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ','), (@($_.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ',') } }
        'Services' = { Get-Service -Name NlaSvc, netprofm, Dot3svc, BITS -ErrorAction SilentlyContinue | ForEach-Object { '{0} ({1}): {2}' -f $_.Name, $_.DisplayName, $_.Status } }
        'BITS jobs' = { Get-BitsTransfer -AllUsers -ErrorAction Stop | ForEach-Object { '{0} [{1}] {2} {3}' -f $_.DisplayName, $_.OwnerAccount, $_.JobState, $_.ErrorDescription } }
    }
    foreach ($name in $probes.Keys) {
        try {
            $lines = @(& $probes[$name])
            if ($lines.Count -eq 0) { $lines = @('(none)') }
            Write-StepLog "${name}:"
            foreach ($l in $lines) { Write-StepLog "    $l" }
        }
        catch {
            Write-StepLog "${name}: unavailable ($($_.Exception.Message))"
        }
    }
    Write-StepLog '---- End of network diagnostics ----'
}

function Wait-NetworkConnected {
    <#
    .SYNOPSIS
        Polls a state reader until it reports connected for StableSeconds in a row, or times out.
    .DESCRIPTION
        Separate from the reader so it can be tested without a real network. Returns an object with
        Connected (whether it settled), Seconds waited and the number of state changes seen.
    .PARAMETER GetState
        Script block returning an object with Connected, Source and Profiles.
    .PARAMETER TimeoutSeconds
        Give up after this long.
    .PARAMETER PollSeconds
        Seconds between checks.
    .PARAMETER StableSeconds
        Connected time required before returning.
    .EXAMPLE
        Wait-NetworkConnected -GetState { Get-NetworkConnectedState } -TimeoutSeconds 900 -PollSeconds 10 -StableSeconds 30
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$GetState,
        [int]$TimeoutSeconds,
        [int]$PollSeconds,
        [int]$StableSeconds
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    $connectedSince = $null
    $changes = 0
    while ($true) {
        $state = & $GetState
        $now = $clock.Elapsed.TotalSeconds
        if ($null -eq $last -or $state.Connected -ne $last) {
            if ($null -ne $last) { $changes++ }
            $word = if ($state.Connected) { 'CONNECTED' } else { 'NOT CONNECTED' }
            Write-StepLog ("Network {0} (by {1}) after {2:N0}s. {3}" -f $word, $state.Source, $now, ($state.Profiles -join '; '))
            $last = $state.Connected
            $connectedSince = if ($state.Connected) { $now } else { $null }
        }
        if ($state.Connected -and ($now - $connectedSince) -ge $StableSeconds) {
            return [pscustomobject]@{ Connected = $true; Seconds = [Math]::Round($now); Changes = $changes }
        }
        if ($now -ge $TimeoutSeconds) {
            return [pscustomobject]@{ Connected = $false; Seconds = [Math]::Round($now); Changes = $changes }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

# ---- Main --------------------------------------------------------------------------------------
Write-StepLog "Version $ScriptVersion. Waiting up to $TimeoutSeconds s for the network to be connected for $StableSeconds s (checking every $PollSeconds s)."
# Wait-NetworkConnected writes its progress lines to the output stream (so they reach smsts.log as
# they happen) and returns its verdict last; pass the lines through and keep the verdict.
$verdict = @{}
Wait-NetworkConnected -GetState { Get-NetworkConnectedState } -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -StableSeconds $StableSeconds |
    ForEach-Object { if ($_ -is [string]) { $_ } else { $verdict['Result'] = $_ } }
$result = $verdict['Result']

if ($result.Connected) {
    Write-StepLog "Network connected and stable after $($result.Seconds) s ($($result.Changes) state change(s))."
    exit 0
}

Write-StepLog "Network was NOT reported connected within $TimeoutSeconds s ($($result.Changes) state change(s)). BITS downloads (application policy and content) will not run while Windows reports no connection."
Write-NetworkDiagnostic
if ($FailOnTimeout) {
    Write-StepLog 'Failing the step (-FailOnTimeout).'
    exit 1
}
Write-StepLog 'Continuing (no -FailOnTimeout); the next Install Application step is likely to fail with "Application failed to evaluate".'
exit 0
