<#
.SYNOPSIS
    Reports NSX segments and Tier-1 gateways that appear to be unused. Read only.

.DESCRIPTION
    Audits an NSX 4.2 Manager through the Policy API and writes a CSV of
    candidates for clean-up. Nothing in NSX is changed: every call is a GET,
    apart from creating and destroying the API session itself.

    A segment is reported only when ALL of these hold:
      - it has no segment ports (no VM, vmknic, container or edge vNIC);
      - no Tier-0 or Tier-1 gateway interface (service interface or external
        uplink) names it as its segment. Interfaces are checked directly
        rather than assumed to show up as segment ports;
      - it has no edge bridge profile and no L2VPN extension, either of which
        carries traffic for workloads that are not attached to NSX ports.

    A Tier-1 gateway is reported only when ALL of these hold:
      - no segment is connected to it, counting both infra segments and the
        fixed segments created under the Tier-1 itself;
      - it has no service interfaces;
      - no load balancer service is attached to it;
      - it has no IPSec VPN or L2 VPN service.
    A check that could not be run (the endpoint returned 404) is named in the
    Notes column rather than silently treated as "none found". Inside a
    multi-tenancy project NSX answers some of these APIs with HTTP 400, error
    524223, "not supported in the context of a Project" - load balancer
    services, for one. That feature cannot exist in the project, so the check
    counts as none and is logged once, not noted on every row.

    Multi-tenancy projects (NSX 4.1 and later) are audited alongside the
    default space. A project whose segments or Tier-1 gateways cannot be read
    is left out whole, with a warning, rather than failing the run. VPC subnets
    and Federation global objects are not audited.

    One CSV row per reported object. For a Tier-1 row, ConnectivityPath is the
    Tier-0 it uplinks to (tier0_path). ScriptVersion is stamped on every row.

    "Reported" means "worth a human look", not "safe to delete". Read the
    CreatedBy and Protection columns first: objects created by a principal
    identity (NCP, vSphere with Tanzu, Aria Automation, VCF) are protected in
    NSX and belong to the system that created them.

    Vendor guidance this follows (NSX 4.2 API Guide, Overview section):
      - Pagination: a list call returns at most page_size results (1000 by
        default, and possibly fewer). A "cursor" property is present only while
        more pages remain and is passed back unchanged on the same query.
      - Optional empty fields are left out of responses, so every optional
        property is read defensively. This script runs under StrictMode, where
        reading an absent property is a terminating error.
      - Rate limiting: 100 requests per second per client (HTTP 429), 40
        concurrent requests per client and 199 overall (HTTP 503). Requests are
        throttled client side, and 429/503 are retried with exponential
        backoff.
      - Authentication: session-based (/api/session/create, then the session
        cookie plus X-XSRF-TOKEN) by default. The password is sent at sign-in
        rather than on every request, and the script keeps working where Basic
        authentication has been disabled for hardening (Broadcom KB 447337).
        -UseBasicAuth is the fallback.

.PARAMETER NsxManager
    NSX Manager FQDN, IP address or cluster VIP. Prompted for when omitted. A
    leading https:// and anything after the host name are ignored.

.PARAMETER CredentialName
    Name resolved through Get-RichoCredential: SecretManagement first, then
    RICHO_<NAME>_USER / RICHO_<NAME>_PASSWORD, then an interactive prompt.
    Defaults to 'nsx'. Give an LDAP or VIDM account as user@domain.

.PARAMETER OutputPath
    CSV file to write. Defaults to NSX-Unused-Objects-<manager>-<timestamp>.csv
    in the current directory.

.PARAMETER UseBasicAuth
    Send HTTP Basic credentials on every request instead of opening a session.
    Use it only if session creation is blocked, or if an external load balancer
    in front of the managers has no session persistence - NSX sessions are local
    to the node that created them.

.PARAMETER MaxRequestsPerSecond
    Client-side throttle. NSX allows 100 requests per second per client, and
    that budget is shared with anything else signed in as the same account, so
    the default of 50 leaves headroom.

.PARAMETER SkipCertificateCheck
    Do not validate the NSX Manager certificate. Works on Windows PowerShell 5.1
    and PowerShell 7. Trusting the CA that signed the manager certificate is the
    better fix.

.PARAMETER Transcript
    Also capture a PowerShell transcript in logs/.

.EXAMPLE
    .\Get-NsxUnusedObject.ps1

    Prompts for the manager and a credential, then writes the CSV to the
    current directory.

.EXAMPLE
    .\Get-NsxUnusedObject.ps1 -NsxManager nsx01.example.com -CredentialName nsx-prod -Transcript

.EXAMPLE
    .\Get-NsxUnusedObject.ps1 -NsxManager 10.0.0.10 -UseBasicAuth -SkipCertificateCheck -OutputPath C:\Temp\nsx-audit.csv

.NOTES
    Written against the NSX 4.2 Policy API. Read only. Runs on Windows
    PowerShell 5.1 and PowerShell 7.
#>
#Requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialName',
    Justification = 'The name of a stored secret, not the secret itself.')]
[CmdletBinding()]
param(
    [string]$NsxManager,

    [ValidateNotNullOrEmpty()]
    [string]$CredentialName = 'nsx',

    [string]$OutputPath,

    [switch]$UseBasicAuth,

    [ValidateRange(1, 100)]
    [int]$MaxRequestsPerSecond = 50,

    [switch]$SkipCertificateCheck,

    [switch]$Transcript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.1.0'

Import-Module (Join-Path $PSScriptRoot '..\..\modules\Richo.Common\Richo.Common.psd1') -Force

# Connection state shared by the request helpers. Populated once the inputs are known.
$script:Nsx = @{
    BaseUri = $null
    Credential = $null
    UseBasicAuth = $false
    WebSession = $null
    XsrfToken = $null
    SkipCertificateCheck = $false
    SupportsSkipCertificateCheck = $false
    MaxRequestsPerSecond = 50
    RecentRequests = New-Object 'System.Collections.Generic.Queue[datetime]'
    RequestCount = 0
    LastStatus = $null
    LastUnavailable = $null
    AuthFailed = $false
}

# Checks NSX does not support inside a project, already logged once per space.
$script:UnsupportedLogged = @{}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-NsxProperty {
    <#
    .SYNOPSIS
        Reads a property from an NSX response object, or $null when it is absent.

    .DESCRIPTION
        NSX leaves optional empty fields out of its responses (API Guide, "Example
        Requests and Responses"), and under StrictMode reading an absent property
        throws. Array values are enumerated, so filter $null before counting:
        @(Get-NsxProperty $o 'x' | Where-Object { $null -ne $_ }).

    .PARAMETER InputObject
        The object returned by NSX.

    .PARAMETER Name
        The JSON property name, e.g. connectivity_path.

    .EXAMPLE
        Get-NsxProperty -InputObject $segment -Name 'connectivity_path'
    #>
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-NsxManagerHost {
    <#
    .SYNOPSIS
        Normalises what an operator types at the manager prompt to host[:port].

    .DESCRIPTION
        Accepts a bare FQDN or IP, or a pasted URL. Returns an empty string for
        anything that is not a plausible host, so the caller can ask again.

    .PARAMETER Value
        The raw input.

    .EXAMPLE
        ConvertTo-NsxManagerHost -Value 'https://nsx01.example.com/login.jsp'
    #>
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $candidate = $Value.Trim().Trim('"', "'")
    $candidate = $candidate -replace '^(?i)https?://', ''
    $candidate = ($candidate -split '/')[0]
    if ($candidate -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-]*(:\d{1,5})?$|^\[[0-9A-Fa-f:.]+\](:\d{1,5})?$') { return '' }
    return $candidate
}

function ConvertTo-NsxApiPath {
    <#
    .SYNOPSIS
        Turns an NSX policy path into a request path under /policy/api/v1.

    .DESCRIPTION
        Uses the "path" NSX returns for each object rather than rebuilding it
        from IDs, so infra, fixed (Tier-1) and project-scoped objects all work
        the same way. Each component is escaped: IDs can contain characters that
        are reserved in a URL.

    .PARAMETER PolicyPath
        e.g. /infra/segments/web-01 or /orgs/default/projects/p1/infra/tier-1s/t1.

    .PARAMETER Suffix
        Appended unescaped, e.g. '/ports'.

    .EXAMPLE
        ConvertTo-NsxApiPath -PolicyPath $segment.path -Suffix '/ports'
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PolicyPath,

        [string]$Suffix = ''
    )

    $parts = @($PolicyPath.Trim('/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) })
    return '/policy/api/v1/' + ($parts -join '/') + $Suffix
}

function Get-NsxHttpStatus {
    <#
    .SYNOPSIS
        Returns the HTTP status of a failed web request, or $null if there was none.

    .DESCRIPTION
        Works on Windows PowerShell 5.1 (WebException) and PowerShell 7
        (HttpResponseException). A DNS, TCP or TLS failure has no response at
        all, and its exception has no Response property - which StrictMode would
        turn into a second, misleading error.

    .PARAMETER ErrorRecord
        The record caught from Invoke-RestMethod or Invoke-WebRequest.

    .EXAMPLE
        $status = Get-NsxHttpStatus -ErrorRecord $_
    #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) { return $null }
    try { return [int]$responseProperty.Value.StatusCode }
    catch { return $null }
}

function Get-NsxUnavailableReason {
    <#
    .SYNOPSIS
        Tells "this API is not available here" apart from a real failure.

    .DESCRIPTION
        Two answers mean there is nothing of that kind to check, not that the audit failed:

          - HTTP 404: the endpoint, or its parent object, does not exist.
          - HTTP 400 with error_code 524223, "This API is not supported in the context of a
            Project". NSX 4.2 answers this inside a multi-tenancy project for features a project
            cannot use - load balancer services, for one. Nothing of that kind can exist there.

        Returns 'NotFound', 'NotSupportedInProject', or $null for any other failure.

    .PARAMETER ErrorRecord
        The caught error.

    .PARAMETER Status
        Its HTTP status, if there was one.

    .EXAMPLE
        Get-NsxUnavailableReason -ErrorRecord $_ -Status 400
    #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()]$Status
    )

    if ($Status -eq 404) { return 'NotFound' }
    if ($Status -ne 400) { return $null }

    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try { $body = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop }
        catch { $body = $null }
    }
    $code = [string](Get-NsxProperty $body 'error_code')
    $message = [string](Get-NsxProperty $body 'error_message')
    if ($code -eq '524223' -or $message -match 'not supported in the context of a Project') { return 'NotSupportedInProject' }
    return $null
}

function Get-NsxUnavailableNote {
    <#
    .SYNOPSIS
        Turns an unavailable check into a Notes entry, or into nothing when it cannot apply.

    .DESCRIPTION
        NotFound means the check could not run, so the reader must be told. NotSupportedInProject
        means NSX does not allow that feature in the project at all, so there is nothing to find;
        that is logged once per space and check instead of noted on every row.

    .PARAMETER Check
        What could not be read, e.g. 'lb-services'.

    .PARAMETER Reason
        'NotFound' or 'NotSupportedInProject'.

    .PARAMETER Space
        The space the check ran in.

    .EXAMPLE
        Get-NsxUnavailableNote -Check 'lb-services' -Reason NotFound -Space default
    #>
    param([string]$Check, [string]$Reason, [string]$Space)

    if ($Reason -eq 'NotSupportedInProject') {
        $key = "$Space|$Check"
        if (-not $script:UnsupportedLogged.ContainsKey($key)) {
            $script:UnsupportedLogged[$key] = $true
            Write-RichoLog "${Space}: NSX does not support $Check in a project, so there are none to find." -Level INFO
        }
        return $null
    }
    return "$Check not checked (HTTP 404)"
}

function Format-NsxError {
    <#
    .SYNOPSIS
        Builds a readable message from a failed NSX request.

    .DESCRIPTION
        Prefers the error_message and error_code from the NSX error body, falls
        back to the raw body (a proxy may answer with HTML), then to the
        exception message. Never includes request headers, so no credential or
        session token can leak into a log.

    .PARAMETER ErrorRecord
        The caught error.

    .PARAMETER Method
        HTTP method, for the message.

    .PARAMETER Path
        Request path, for the message.

    .PARAMETER Status
        HTTP status, if there was one.

    .EXAMPLE
        throw (Format-NsxError -ErrorRecord $_ -Method GET -Path $Path -Status 500)
    #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Method,
        [string]$Path,
        [AllowNull()]$Status
    )

    $message = "NSX API $Method $Path failed"
    if ($Status) { $message += " with HTTP $Status" }

    $detail = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $detail = [string]$ErrorRecord.ErrorDetails.Message
        try { $body = $detail | ConvertFrom-Json -ErrorAction Stop }
        catch { $body = $null }
        $nsxMessage = Get-NsxProperty $body 'error_message'
        if ($nsxMessage) {
            $nsxCode = Get-NsxProperty $body 'error_code'
            $detail = if ($nsxCode) { "$nsxMessage (error_code $nsxCode)" } else { [string]$nsxMessage }
        }
    }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    $detail = ($detail -replace '\s+', ' ').Trim()
    if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) + '...' }

    if ($Status -eq 401 -or $Status -eq 403) {
        $message += '. Check the account and that its NSX role can read this object'
    }
    return "$message. $detail"
}

function Wait-NsxRateLimit {
    <#
    .SYNOPSIS
        Keeps this client under its per-second request budget.

    .DESCRIPTION
        NSX refuses requests above the per-client rate with HTTP 429, and the API
        Guide asks clients to throttle themselves rather than rely on retries. A
        sliding one-second window over the last requests sent.

    .EXAMPLE
        Wait-NsxRateLimit
    #>
    $window = [TimeSpan]::FromSeconds(1)
    $queue = $script:Nsx.RecentRequests
    while ($true) {
        $now = [datetime]::UtcNow
        while ($queue.Count -gt 0 -and ($now - $queue.Peek()) -ge $window) { [void]$queue.Dequeue() }
        if ($queue.Count -lt $script:Nsx.MaxRequestsPerSecond) { break }
        $waitMs = [int][Math]::Ceiling(($window - ($now - $queue.Peek())).TotalMilliseconds)
        Start-Sleep -Milliseconds ([Math]::Max($waitMs, 1))
    }
    $queue.Enqueue([datetime]::UtcNow)
    $script:Nsx.RequestCount++
}

function Get-NsxResponseHeader {
    <#
    .SYNOPSIS
        Reads one response header by name, case-insensitively, on 5.1 and 7.

    .PARAMETER Response
        The Invoke-WebRequest response.

    .PARAMETER Name
        Header name.

    .EXAMPLE
        Get-NsxResponseHeader -Response $response -Name 'X-XSRF-TOKEN'
    #>
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Name
    )

    # Windows PowerShell returns a string per header, PowerShell 7 a string array.
    foreach ($key in @($Response.Headers.Keys)) {
        if ($key -ieq $Name) { return [string](@($Response.Headers[$key])[0]) }
    }
    return $null
}

function Initialize-NsxTransport {
    <#
    .SYNOPSIS
        Prepares Windows PowerShell 5.1 to talk to NSX, and records what it changed.

    .DESCRIPTION
        Windows PowerShell 5.1 can default to protocols NSX 4.x does not accept,
        so TLS 1.2 is added to the enabled set. 5.1 also has no
        -SkipCertificateCheck, so when it is requested the process-wide
        validation callback is replaced instead. Both are put back by
        Restore-NsxTransport. PowerShell 7 needs neither.

    .PARAMETER SkipCertificateCheck
        Relax certificate validation.

    .EXAMPLE
        $state = Initialize-NsxTransport -SkipCertificateCheck:$SkipCertificateCheck
    #>
    param([switch]$SkipCertificateCheck)

    $state = [pscustomobject]@{
        SupportsSkipCertificateCheck = (Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')
        PreviousProtocol = $null
        PreviousCallback = $null
        CallbackReplaced = $false
    }

    if (-not $state.SupportsSkipCertificateCheck) {
        $state.PreviousProtocol = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = $state.PreviousProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ($SkipCertificateCheck) {
            $state.PreviousCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $state.CallbackReplaced = $true
        }
    }
    return $state
}

function Restore-NsxTransport {
    <#
    .SYNOPSIS
        Undoes Initialize-NsxTransport, so the session is left as it was found.

    .PARAMETER State
        The object Initialize-NsxTransport returned.

    .EXAMPLE
        Restore-NsxTransport -State $state
    #>
    param([AllowNull()]$State)

    if ($null -eq $State -or $State.SupportsSkipCertificateCheck) { return }
    if ($State.CallbackReplaced) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $State.PreviousCallback
    }
    if ($null -ne $State.PreviousProtocol) {
        [Net.ServicePointManager]::SecurityProtocol = $State.PreviousProtocol
    }
}

function Connect-NsxApi {
    <#
    .SYNOPSIS
        Opens an NSX API session (POST /api/session/create).

    .DESCRIPTION
        Posts j_username / j_password as form data and keeps the session cookie
        and the X-XSRF-TOKEN response header for later requests, as the NSX 4.2
        API Guide describes. A rejected sign-in is never retried: NSX locks an
        account out after repeated failures.

        Does nothing with -UseBasicAuth, where every request carries the
        credential instead.

    .EXAMPLE
        Connect-NsxApi
    #>
    if ($script:Nsx.UseBasicAuth) { return }

    $credential = $script:Nsx.Credential
    $request = @{
        Method = 'POST'
        Uri = $script:Nsx.BaseUri + '/api/session/create'
        Body = @{
            j_username = $credential.UserName
            j_password = $credential.GetNetworkCredential().Password
        }
        ContentType = 'application/x-www-form-urlencoded'
        SessionVariable = 'nsxSession'
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    if ($script:Nsx.SkipCertificateCheck -and $script:Nsx.SupportsSkipCertificateCheck) {
        $request.SkipCertificateCheck = $true
    }

    Wait-NsxRateLimit
    try {
        $ProgressPreference = 'SilentlyContinue'
        $response = Invoke-WebRequest @request
    }
    catch {
        $status = Get-NsxHttpStatus -ErrorRecord $_
        if ($status -eq 401 -or $status -eq 403) {
            $script:Nsx.AuthFailed = $true
            throw (("NSX rejected the sign-in for '{0}' (HTTP {1}). Check the password, and give LDAP or VIDM " +
                    "accounts as user@domain. Not retried - NSX locks an account out after repeated failures.") -f
                $credential.UserName, $status)
        }
        throw (Format-NsxError -ErrorRecord $_ -Method 'POST' -Path '/api/session/create' -Status $status)
    }
    finally {
        $request.Body = $null
    }

    $token = Get-NsxResponseHeader -Response $response -Name 'X-XSRF-TOKEN'
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'NSX accepted the sign-in but returned no X-XSRF-TOKEN header. Re-run with -UseBasicAuth.'
    }
    $script:Nsx.WebSession = $nsxSession
    $script:Nsx.XsrfToken = $token
}

function Disconnect-NsxApi {
    <#
    .SYNOPSIS
        Closes the NSX API session (POST /api/session/destroy). Never throws.

    .EXAMPLE
        Disconnect-NsxApi
    #>
    if ($script:Nsx.UseBasicAuth -or $null -eq $script:Nsx.WebSession) { return }
    try {
        $null = Invoke-NsxRequest -Method POST -Path '/api/session/destroy' -NoReauthenticate
        Write-RichoLog 'NSX API session closed.' -Level DEBUG
    }
    catch {
        Write-RichoLog "Could not close the NSX API session cleanly; it will time out on its own. $($_.Exception.Message)" -Level WARN
    }
    $script:Nsx.WebSession = $null
    $script:Nsx.XsrfToken = $null
}

function Invoke-NsxRequest {
    <#
    .SYNOPSIS
        Sends one NSX API request, with throttling, retries and readable errors.

    .DESCRIPTION
        Retries HTTP 429 (per-client rate limit) and 503 (concurrency limit or
        server busy) with exponential backoff, as the NSX 4.2 API Guide asks of
        clients. A 403 on a session is taken to mean the session expired - the
        documented behaviour - and the sign-in is redone once; a second 403 is a
        real permission failure.

    .PARAMETER Path
        Path under the manager, e.g. /policy/api/v1/infra/segments.

    .PARAMETER Method
        GET (default) or POST.

    .PARAMETER AllowUnavailable
        Return $null instead of throwing when the API is not available here: HTTP 404, or not
        supported in a project (see Get-NsxUnavailableReason). $script:Nsx.LastUnavailable says
        which.

    .PARAMETER NoReauthenticate
        Do not sign in again on a 403.

    .EXAMPLE
        Invoke-NsxRequest -Path '/policy/api/v1/infra'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('GET', 'POST')]
        [string]$Method = 'GET',

        [switch]$AllowUnavailable,

        [switch]$NoReauthenticate
    )

    # Windows PowerShell renders a progress bar per response, which slows every call.
    $ProgressPreference = 'SilentlyContinue'
    $maxAttempts = 6
    $attempt = 0
    $reauthenticated = $false

    while ($true) {
        $attempt++
        # charset=UTF-8 because the API Guide requires it whenever the URL carries percent-encoded
        # UTF-8, which ConvertTo-NsxApiPath produces for any non-ASCII object ID.
        $request = @{
            Method = $Method
            Uri = $script:Nsx.BaseUri + $Path
            Headers = @{ Accept = 'application/json' }
            ContentType = 'application/json; charset=utf-8'
            ErrorAction = 'Stop'
        }
        if ($script:Nsx.UseBasicAuth) {
            $pair = '{0}:{1}' -f $script:Nsx.Credential.UserName, $script:Nsx.Credential.GetNetworkCredential().Password
            $request.Headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
            $pair = $null
        }
        else {
            $request.WebSession = $script:Nsx.WebSession
            $request.Headers['X-XSRF-TOKEN'] = $script:Nsx.XsrfToken
        }
        if ($script:Nsx.SkipCertificateCheck -and $script:Nsx.SupportsSkipCertificateCheck) {
            $request.SkipCertificateCheck = $true
        }

        Wait-NsxRateLimit
        try {
            return Invoke-RestMethod @request
        }
        catch {
            $status = Get-NsxHttpStatus -ErrorRecord $_
            $script:Nsx.LastStatus = $status

            if ($AllowUnavailable) {
                $unavailable = Get-NsxUnavailableReason -ErrorRecord $_ -Status $status
                if ($unavailable) {
                    $script:Nsx.LastUnavailable = $unavailable
                    return $null
                }
            }

            if (($status -eq 429 -or $status -eq 503) -and $attempt -lt $maxAttempts) {
                $delay = [int][Math]::Pow(2, $attempt - 1)
                Write-RichoLog "NSX answered HTTP $status for $Path (rate or concurrency limit); retrying in $delay s, attempt $attempt of $maxAttempts." -Level WARN
                Start-Sleep -Seconds $delay
                continue
            }

            if ($status -eq 403 -and -not $script:Nsx.UseBasicAuth -and -not $NoReauthenticate -and -not $reauthenticated) {
                Write-RichoLog "HTTP 403 for $Path - the session may have expired. Signing in again once." -Level WARN
                $reauthenticated = $true
                Connect-NsxApi
                continue
            }

            throw (Format-NsxError -ErrorRecord $_ -Method $Method -Path $Path -Status $status)
        }
    }
}

function Get-NsxPagedResult {
    <#
    .SYNOPSIS
        Returns every item of an NSX list call, following the cursor.

    .DESCRIPTION
        NSX returns at most page_size items per call and includes a "cursor"
        property only while more pages remain; the cursor is passed back
        unchanged with the same query (NSX 4.2 API Guide, "API Pagination").

        Returns ONE array object, never enumerated, so an empty collection
        (empty array) and an API that is not available here ($null, only with
        -AllowUnavailable) stay distinguishable. Assign the result; do not wrap the
        call in @().

    .PARAMETER Path
        List path, without page_size or cursor.

    .PARAMETER PageSize
        1 to 1000; 1000 is NSX's default.

    .PARAMETER FirstItemOnly
        Stop as soon as one item is found. For "is there anything here?"
        checks, so a busy segment does not page through every port.

    .PARAMETER AllowUnavailable
        Return $null when the API is not available here (see Invoke-NsxRequest).

    .EXAMPLE
        $segments = Get-NsxPagedResult -Path '/policy/api/v1/infra/segments'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateRange(1, 1000)]
        [int]$PageSize = 1000,

        [switch]$FirstItemOnly,

        [switch]$AllowUnavailable
    )

    $items = New-Object System.Collections.Generic.List[object]
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $firstPage = "$Path${separator}page_size=$PageSize"
    $requestPath = $firstPage
    $seenCursors = @{}

    while ($true) {
        $response = Invoke-NsxRequest -Path $requestPath -AllowUnavailable:$AllowUnavailable
        if ($null -eq $response) { return $null }

        foreach ($item in @(Get-NsxProperty $response 'results')) {
            if ($null -ne $item) { $items.Add($item) }
        }
        if ($FirstItemOnly -and $items.Count -gt 0) { break }

        $cursor = [string](Get-NsxProperty $response 'cursor')
        if ([string]::IsNullOrEmpty($cursor)) { break }
        if ($seenCursors.ContainsKey($cursor)) {
            throw "NSX returned the same cursor twice for $Path; stopping rather than looping."
        }
        $seenCursors[$cursor] = $true
        $requestPath = "$firstPage&cursor=$([Uri]::EscapeDataString($cursor))"
    }

    return , $items.ToArray()
}

function Get-NsxSpace {
    <#
    .SYNOPSIS
        Lists the default space plus every multi-tenancy project.

    .DESCRIPTION
        Project objects live under /orgs/default/projects/<id>/infra and are not
        returned by the /infra list calls, so each project is audited as its own
        space. The project with ID "default" is the default space itself and is
        skipped so nothing is counted twice. Before NSX 4.1 there is no projects
        API; the 404 is expected and only the default space is audited.

    .EXAMPLE
        $spaces = Get-NsxSpace
    #>
    $spaces = New-Object System.Collections.Generic.List[object]
    $spaces.Add([pscustomobject]@{ Name = 'default'; InfraPath = '/infra'; Complete = $true })

    try {
        $projects = Get-NsxPagedResult -Path '/policy/api/v1/orgs/default/projects' -AllowUnavailable
    }
    catch {
        Write-RichoLog "Could not list multi-tenancy projects, so only the default space is audited. $($_.Exception.Message)" -Level WARN
        $spaces[0].Complete = $false
        return , $spaces.ToArray()
    }

    if ($null -eq $projects) {
        Write-RichoLog 'No projects API on this manager; auditing the default space only.' -Level INFO
        return , $spaces.ToArray()
    }

    foreach ($project in $projects) {
        $id = [string](Get-NsxProperty $project 'id')
        if ([string]::IsNullOrEmpty($id) -or $id -eq 'default') { continue }
        $path = [string](Get-NsxProperty $project 'path')
        if ([string]::IsNullOrEmpty($path)) { $path = "/orgs/default/projects/$id" }
        $spaces.Add([pscustomobject]@{ Name = "project:$id"; InfraPath = "$path/infra"; Complete = $true })
    }
    return , $spaces.ToArray()
}

function Get-NsxDisplayName {
    <#
    .SYNOPSIS
        Returns an object's display_name, or its id when it has none.

    .PARAMETER InputObject
        An NSX object.

    .EXAMPLE
        Get-NsxDisplayName -InputObject $segment
    #>
    param([Parameter(Mandatory)]$InputObject)

    $name = [string](Get-NsxProperty $InputObject 'display_name')
    if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
    return [string](Get-NsxProperty $InputObject 'id')
}

function Get-NsxGatewayInterface {
    <#
    .SYNOPSIS
        Returns every interface of a Tier-0 or Tier-1 gateway, across its locale services.

    .PARAMETER Gateway
        The Tier-0 or Tier-1 object.

    .PARAMETER AllowUnavailable
        Return $null if the locale services or interfaces API is not available here.

    .EXAMPLE
        $interfaces = Get-NsxGatewayInterface -Gateway $tier1
    #>
    param(
        [Parameter(Mandatory)]$Gateway,
        [switch]$AllowUnavailable
    )

    $interfaces = New-Object System.Collections.Generic.List[object]
    $localeServices = Get-NsxPagedResult -Path (ConvertTo-NsxApiPath -PolicyPath $Gateway.path -Suffix '/locale-services') -AllowUnavailable:$AllowUnavailable
    if ($null -eq $localeServices) { return $null }
    foreach ($localeService in $localeServices) {
        $found = Get-NsxPagedResult -Path (ConvertTo-NsxApiPath -PolicyPath $localeService.path -Suffix '/interfaces') -AllowUnavailable:$AllowUnavailable
        if ($null -eq $found) { return $null }
        foreach ($interface in $found) { $interfaces.Add($interface) }
    }
    return , $interfaces.ToArray()
}

function Resolve-NsxSegmentUsage {
    <#
    .SYNOPSIS
        Decides whether a segment shows any sign of use, and why.

    .PARAMETER Segment
        The segment object.

    .PARAMETER HasPort
        Whether the segment has at least one segment port.

    .PARAMETER GatewayInterfaceCount
        Gateway interfaces whose segment_path is this segment.

    .EXAMPLE
        Resolve-NsxSegmentUsage -Segment $segment -HasPort $false -GatewayInterfaceCount 0
    #>
    param(
        [Parameter(Mandatory)]$Segment,
        [bool]$HasPort,
        [int]$GatewayInterfaceCount
    )

    $evidence = New-Object System.Collections.Generic.List[string]
    if ($HasPort) { $evidence.Add('segment ports') }
    if ($GatewayInterfaceCount -gt 0) { $evidence.Add("$GatewayInterfaceCount gateway interface(s)") }
    if (@(Get-NsxProperty $Segment 'bridge_profiles' | Where-Object { $null -ne $_ }).Count -gt 0) {
        $evidence.Add('edge bridge profile')
    }
    if ($null -ne (Get-NsxProperty $Segment 'l2_extension')) { $evidence.Add('L2VPN extension') }

    return [pscustomobject]@{
        Unused = ($evidence.Count -eq 0)
        Evidence = $evidence.ToArray()
    }
}

function Resolve-NsxTier1Usage {
    <#
    .SYNOPSIS
        Decides whether a Tier-1 gateway shows any sign of use, and why.

    .PARAMETER ConnectedSegmentCount
        Segments (infra and fixed) connected to the Tier-1.

    .PARAMETER ServiceInterfaceCount
        Service interfaces on the Tier-1.

    .PARAMETER LoadBalancerCount
        Load balancer services whose connectivity_path is the Tier-1.

    .PARAMETER VpnServiceCount
        IPSec and L2 VPN services found on the Tier-1.

    .EXAMPLE
        Resolve-NsxTier1Usage -ConnectedSegmentCount 0 -ServiceInterfaceCount 0 -LoadBalancerCount 0 -VpnServiceCount 0
    #>
    param(
        [int]$ConnectedSegmentCount,
        [int]$ServiceInterfaceCount,
        [int]$LoadBalancerCount,
        [int]$VpnServiceCount
    )

    $evidence = New-Object System.Collections.Generic.List[string]
    if ($ConnectedSegmentCount -gt 0) { $evidence.Add("$ConnectedSegmentCount connected segment(s)") }
    if ($ServiceInterfaceCount -gt 0) { $evidence.Add("$ServiceInterfaceCount service interface(s)") }
    if ($LoadBalancerCount -gt 0) { $evidence.Add("$LoadBalancerCount load balancer service(s)") }
    if ($VpnServiceCount -gt 0) { $evidence.Add("$VpnServiceCount VPN service(s)") }

    return [pscustomobject]@{
        Unused = ($evidence.Count -eq 0)
        Evidence = $evidence.ToArray()
    }
}

function Get-NsxOwnershipNote {
    <#
    .SYNOPSIS
        Flags objects that belong to a principal identity or to NSX itself.

    .PARAMETER InputObject
        An NSX object.

    .EXAMPLE
        Get-NsxOwnershipNote -InputObject $tier1
    #>
    param([Parameter(Mandatory)]$InputObject)

    $notes = New-Object System.Collections.Generic.List[string]
    $protection = [string](Get-NsxProperty $InputObject '_protection')
    if ($protection -eq 'PROTECTED' -or $protection -eq 'REQUIRE_OVERRIDE') {
        $owner = [string](Get-NsxProperty $InputObject '_create_user')
        $notes.Add("Created by principal identity '$owner' - remove it through that system, not by hand")
    }
    if ((Get-NsxProperty $InputObject '_system_owned') -eq $true) { $notes.Add('System-owned') }
    return , $notes.ToArray()
}

function ConvertTo-NsxAuditRow {
    <#
    .SYNOPSIS
        Converts an NSX object into one CSV row, with every column present.

    .PARAMETER ObjectType
        'Segment' or 'Tier-1 Gateway'.

    .PARAMETER InputObject
        The NSX object.

    .PARAMETER Space
        'default' or 'project:<id>'.

    .PARAMETER Values
        Column values that differ by object type.

    .PARAMETER Reason
        Why it was reported.

    .PARAMETER Notes
        Caveats the reader must see before acting.

    .EXAMPLE
        ConvertTo-NsxAuditRow -ObjectType Segment -InputObject $segment -Space default -Reason '...'
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ObjectType,
        [AllowNull()]$InputObject,
        [string]$Space,
        [hashtable]$Values = @{},
        [string]$Reason,
        [string[]]$Notes = @()
    )

    $lastModified = ''
    $modifiedMs = Get-NsxProperty $InputObject '_last_modified_time'
    if ($null -ne $modifiedMs) {
        $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
        $lastModified = $epoch.AddMilliseconds([double]$modifiedMs).ToString('yyyy-MM-dd HH:mm:ss') + 'Z'
    }

    $tags = @(Get-NsxProperty $InputObject 'tags' | Where-Object { $null -ne $_ } | ForEach-Object {
            $scope = [string](Get-NsxProperty $_ 'scope')
            $tag = [string](Get-NsxProperty $_ 'tag')
            if ($scope) { "${scope}:$tag" } else { $tag }
        }) -join '; '

    $row = [ordered]@{
        ObjectType = $ObjectType
        Name = if ($null -ne $InputObject) { Get-NsxDisplayName -InputObject $InputObject } else { '' }
        ID = [string](Get-NsxProperty $InputObject 'id')
        Path = [string](Get-NsxProperty $InputObject 'path')
        Space = $Space
        ConnectivityPath = ''
        SegmentPortCount = ''
        ConnectedSegments = ''
        InterfaceCount = ''
        LoadBalancerServices = ''
        VpnServices = ''
        AdminState = ''
        TransportZone = ''
        VLANIDs = ''
        CreatedBy = [string](Get-NsxProperty $InputObject '_create_user')
        Protection = [string](Get-NsxProperty $InputObject '_protection')
        LastModifiedUtc = $lastModified
        Tags = $tags
        Reason = $Reason
        Notes = ($Notes | Where-Object { $_ }) -join '; '
        NSXManager = [string]$script:Nsx.BaseUri -replace '^https://', ''
        ScriptVersion = $ScriptVersion
    }
    foreach ($key in $Values.Keys) {
        if (-not $row.Contains($key)) { throw "ConvertTo-NsxAuditRow: unknown column '$key'." }
        $row[$key] = $Values[$key]
    }
    return [pscustomobject]$row
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$transcriptPath = if ($Transcript) { Start-RichoTranscript } else { $null }
$transport = $null

try {
    Write-RichoLog "Get-NsxUnusedObject $ScriptVersion - read only, makes no NSX configuration changes." -Level INFO

    # ---- Inputs -----------------------------------------------------------
    $managerHost = ConvertTo-NsxManagerHost -Value $NsxManager
    while ([string]::IsNullOrEmpty($managerHost)) {
        if (-not [string]::IsNullOrWhiteSpace($NsxManager)) {
            Write-RichoLog "'$NsxManager' is not a host name or IP address." -Level WARN
        }
        $NsxManager = Read-Host 'NSX Manager FQDN or IP address'
        $managerHost = ConvertTo-NsxManagerHost -Value $NsxManager
    }

    $credential = Get-RichoCredential -Name $CredentialName
    if ($null -eq $credential) { throw 'No credential was supplied.' }

    if (-not $OutputPath) {
        $fileName = 'NSX-Unused-Objects-{0}-{1}.csv' -f ($managerHost -replace '[^A-Za-z0-9.\-]', '_'), (Get-Date -Format 'yyyyMMdd-HHmmss')
        $OutputPath = Join-Path (Get-Location).Path $fileName
    }

    # ---- Connect ----------------------------------------------------------
    $transport = Initialize-NsxTransport -SkipCertificateCheck:$SkipCertificateCheck
    $script:Nsx.BaseUri = "https://$managerHost"
    $script:Nsx.Credential = $credential
    $script:Nsx.UseBasicAuth = [bool]$UseBasicAuth
    $script:Nsx.SkipCertificateCheck = [bool]$SkipCertificateCheck
    $script:Nsx.SupportsSkipCertificateCheck = $transport.SupportsSkipCertificateCheck
    $script:Nsx.MaxRequestsPerSecond = $MaxRequestsPerSecond

    $authLabel = if ($UseBasicAuth) { 'HTTP Basic authentication' } else { 'a session' }
    Write-RichoLog "Connecting to $managerHost as '$($credential.UserName)' using $authLabel." -Level INFO
    Connect-NsxApi
    $null = Invoke-NsxRequest -Path '/policy/api/v1/infra'
    Write-RichoLog 'Connected; the Policy API is readable.' -Level INFO

    try {
        $version = Invoke-NsxRequest -Path '/api/v1/node/version' -AllowUnavailable -NoReauthenticate
        $productVersion = [string](Get-NsxProperty $version 'product_version')
        if ($productVersion) {
            Write-RichoLog "NSX version $productVersion." -Level INFO
            if ($productVersion -notmatch '^4\.2\.') {
                Write-RichoLog "This script was written against the NSX 4.2 Policy API; check the results with care on $productVersion." -Level WARN
            }
        }
    }
    catch {
        Write-RichoLog "Could not read the NSX version; continuing. $($_.Exception.Message)" -Level WARN
    }

    # ---- Inventory --------------------------------------------------------
    $spaces = Get-NsxSpace
    Write-RichoLog ("Auditing {0} space(s): {1}." -f $spaces.Count, (($spaces | ForEach-Object { $_.Name }) -join ', ')) -Level INFO

    $segmentsByPath = @{}            # path -> segment
    $segmentSpace = @{}              # path -> space name
    $tier1s = New-Object System.Collections.Generic.List[object]
    $tier1Space = @{}                # path -> space name
    $loadBalancersByTier1 = @{}      # Tier-1 path -> count
    $lbUnavailableSpaces = @{}       # space name -> note, when the LB list could not be read

    foreach ($space in $spaces) {
        # Read the whole space before using any of it. A project that cannot be read is left out
        # entirely, so a half-read project cannot make anything look unused; the default space
        # has no such fallback.
        try {
            $segments = Get-NsxPagedResult -Path (ConvertTo-NsxApiPath -PolicyPath "$($space.InfraPath)/segments")
            $spaceTier1s = Get-NsxPagedResult -Path (ConvertTo-NsxApiPath -PolicyPath "$($space.InfraPath)/tier-1s")
            $loadBalancers = Get-NsxPagedResult -Path (ConvertTo-NsxApiPath -PolicyPath "$($space.InfraPath)/lb-services") -AllowUnavailable
            $lbReason = $script:Nsx.LastUnavailable
        }
        catch {
            if ($space.Name -eq 'default' -or $script:Nsx.AuthFailed -or $_.Exception -is [System.OperationCanceledException]) { throw }
            Write-RichoLog "Project '$($space.Name)' could not be read and is left out of the report. $($_.Exception.Message)" -Level WARN
            $space.Complete = $false
            continue
        }

        foreach ($segment in $segments) {
            $segmentsByPath[[string]$segment.path] = $segment
            $segmentSpace[[string]$segment.path] = $space.Name
        }
        foreach ($tier1 in $spaceTier1s) {
            $tier1s.Add($tier1)
            $tier1Space[[string]$tier1.path] = $space.Name
        }

        if ($null -eq $loadBalancers) {
            $lbNote = Get-NsxUnavailableNote -Check 'lb-services' -Reason $lbReason -Space $space.Name
            if ($lbNote) { $lbUnavailableSpaces[$space.Name] = $lbNote }
        }
        else {
            foreach ($loadBalancer in $loadBalancers) {
                $target = [string](Get-NsxProperty $loadBalancer 'connectivity_path')
                if ($target) { $loadBalancersByTier1[$target] = 1 + [int]$loadBalancersByTier1[$target] }
            }
        }

        Write-RichoLog ("{0}: {1} segment(s), {2} Tier-1 gateway(s)." -f $space.Name, $segments.Count, $spaceTier1s.Count) -Level INFO
    }

    # Gateway interfaces name the segment they attach to. Tier-0 gateways exist only in the
    # default space.
    $interfacesBySegment = @{}       # segment path -> count
    $tier0s = Get-NsxPagedResult -Path '/policy/api/v1/infra/tier-0s'
    foreach ($tier0 in $tier0s) {
        foreach ($interface in (Get-NsxGatewayInterface -Gateway $tier0)) {
            $segmentPath = [string](Get-NsxProperty $interface 'segment_path')
            if ($segmentPath) { $interfacesBySegment[$segmentPath] = 1 + [int]$interfacesBySegment[$segmentPath] }
        }
    }
    Write-RichoLog "Tier-0 gateways: $($tier0s.Count)." -Level INFO

    # Per Tier-1: service interfaces, fixed segments, VPN services.
    $tier1Facts = @{}                # Tier-1 path -> facts
    $tier1Index = 0
    foreach ($tier1 in $tier1s) {
        $tier1Index++
        $tier1Name = Get-NsxDisplayName -InputObject $tier1
        Write-Progress -Activity 'Reading Tier-1 gateways' -Status "$tier1Name ($tier1Index of $($tier1s.Count))" -PercentComplete ([int](100 * $tier1Index / $tier1s.Count))

        $unchecked = New-Object System.Collections.Generic.List[string]

        $interfaces = Get-NsxGatewayInterface -Gateway $tier1 -AllowUnavailable
        if ($null -eq $interfaces) {
            $note = Get-NsxUnavailableNote -Check 'service interfaces' -Reason $script:Nsx.LastUnavailable -Space $tier1Space[[string]$tier1.path]
            if ($note) { $unchecked.Add($note) }
            $interfaces = @()
        }
        foreach ($interface in $interfaces) {
            $segmentPath = [string](Get-NsxProperty $interface 'segment_path')
            if ($segmentPath) { $interfacesBySegment[$segmentPath] = 1 + [int]$interfacesBySegment[$segmentPath] }
        }

        # Fixed segments live under the Tier-1, not under /infra/segments.
        $fixedSegmentPaths = @()
        $fixedSegments = Get-NsxPagedResult -Path (ConvertTo-NsxApiPath -PolicyPath $tier1.path -Suffix '/segments') -AllowUnavailable
        if ($null -eq $fixedSegments) {
            $note = Get-NsxUnavailableNote -Check 'fixed segments' -Reason $script:Nsx.LastUnavailable -Space $tier1Space[[string]$tier1.path]
            if ($note) { $unchecked.Add($note) }
        }
        else {
            foreach ($segment in $fixedSegments) {
                $segmentsByPath[[string]$segment.path] = $segment
                $segmentSpace[[string]$segment.path] = $tier1Space[[string]$tier1.path]
            }
            $fixedSegmentPaths = @($fixedSegments | ForEach-Object { [string]$_.path })
        }

        $vpnCount = 0
        foreach ($kind in @('ipsec-vpn-services', 'l2vpn-services')) {
            $services = Get-NsxPagedResult -Path (ConvertTo-NsxApiPath -PolicyPath $tier1.path -Suffix "/$kind") -AllowUnavailable -FirstItemOnly
            if ($null -eq $services) {
                $note = Get-NsxUnavailableNote -Check $kind -Reason $script:Nsx.LastUnavailable -Space $tier1Space[[string]$tier1.path]
                if ($note) { $unchecked.Add($note) }
            }
            else { $vpnCount += $services.Count }
        }

        if ($lbUnavailableSpaces.ContainsKey($tier1Space[[string]$tier1.path])) {
            $unchecked.Add($lbUnavailableSpaces[$tier1Space[[string]$tier1.path]])
        }

        $tier1Facts[[string]$tier1.path] = [pscustomobject]@{
            ServiceInterfaceCount = $interfaces.Count
            FixedSegmentPaths = $fixedSegmentPaths
            VpnServiceCount = $vpnCount
            Unchecked = $unchecked.ToArray()
        }
    }
    Write-Progress -Activity 'Reading Tier-1 gateways' -Completed

    $results = New-Object System.Collections.Generic.List[object]

    # ---- Segments ---------------------------------------------------------
    $segmentPaths = @($segmentsByPath.Keys | Sort-Object)
    $segmentsWithPorts = 0
    $segmentsSkipped = 0
    $segmentIndex = 0
    foreach ($segmentPath in $segmentPaths) {
        $segmentIndex++
        $segment = $segmentsByPath[$segmentPath]
        $segmentName = Get-NsxDisplayName -InputObject $segment
        Write-Progress -Activity 'Checking segments' -Status "$segmentName ($segmentIndex of $($segmentPaths.Count))" -PercentComplete ([int](100 * $segmentIndex / $segmentPaths.Count))

        # page_size=1: only "any port at all?" matters, and a busy segment's port list is large.
        $ports = Get-NsxPagedResult -Path (ConvertTo-NsxApiPath -PolicyPath $segmentPath -Suffix '/ports') -PageSize 1 -FirstItemOnly -AllowUnavailable
        if ($null -eq $ports) {
            $why = if ($script:Nsx.LastUnavailable -eq 'NotFound') { 'HTTP 404 - it may have just been deleted' } else { 'not supported in a project' }
            Write-RichoLog "Skipped segment '$segmentName' ($segmentPath): its ports could not be read ($why)." -Level WARN
            $segmentsSkipped++
            continue
        }
        $hasPort = $ports.Count -gt 0
        if ($hasPort) { $segmentsWithPorts++ }

        $usage = Resolve-NsxSegmentUsage -Segment $segment -HasPort $hasPort -GatewayInterfaceCount ([int]$interfacesBySegment[$segmentPath])
        if (-not $usage.Unused) { continue }

        $results.Add((ConvertTo-NsxAuditRow -ObjectType 'Segment' -InputObject $segment -Space $segmentSpace[$segmentPath] `
                    -Reason 'No segment ports, gateway interfaces, edge bridge or L2VPN extension' `
                    -Notes (Get-NsxOwnershipNote -InputObject $segment) `
                    -Values @{
                    ConnectivityPath = [string](Get-NsxProperty $segment 'connectivity_path')
                    SegmentPortCount = 0
                    AdminState = [string](Get-NsxProperty $segment 'admin_state')
                    TransportZone = [string](Get-NsxProperty $segment 'transport_zone_path')
                    VLANIDs = @(Get-NsxProperty $segment 'vlan_ids' | Where-Object { $null -ne $_ }) -join ', '
                }))
    }
    Write-Progress -Activity 'Checking segments' -Completed

    # ---- Tier-1 gateways --------------------------------------------------
    $segmentsByTier1 = @{}           # Tier-1 path -> set of connected segment paths
    foreach ($segmentPath in $segmentPaths) {
        $target = [string](Get-NsxProperty $segmentsByPath[$segmentPath] 'connectivity_path')
        if (-not $target) { continue }
        if (-not $segmentsByTier1.ContainsKey($target)) { $segmentsByTier1[$target] = @{} }
        $segmentsByTier1[$target][$segmentPath] = $true
    }

    foreach ($tier1 in $tier1s) {
        $tier1Path = [string]$tier1.path
        $facts = $tier1Facts[$tier1Path]

        $connected = @{}
        if ($segmentsByTier1.ContainsKey($tier1Path)) {
            foreach ($path in $segmentsByTier1[$tier1Path].Keys) { $connected[$path] = $true }
        }
        foreach ($path in $facts.FixedSegmentPaths) { $connected[$path] = $true }

        $loadBalancerCount = [int]$loadBalancersByTier1[$tier1Path]
        $usage = Resolve-NsxTier1Usage -ConnectedSegmentCount $connected.Count -ServiceInterfaceCount $facts.ServiceInterfaceCount `
            -LoadBalancerCount $loadBalancerCount -VpnServiceCount $facts.VpnServiceCount
        if (-not $usage.Unused) { continue }

        # Assigned first: @() around a call that returns one array would nest it.
        $ownership = Get-NsxOwnershipNote -InputObject $tier1
        $notes = @($ownership) + @($facts.Unchecked)
        $results.Add((ConvertTo-NsxAuditRow -ObjectType 'Tier-1 Gateway' -InputObject $tier1 -Space $tier1Space[$tier1Path] `
                    -Reason 'No connected segments, service interfaces, load balancer or VPN services' `
                    -Notes $notes `
                    -Values @{
                    ConnectivityPath = [string](Get-NsxProperty $tier1 'tier0_path')
                    ConnectedSegments = 0
                    InterfaceCount = 0
                    LoadBalancerServices = 0
                    VpnServices = 0
                }))
    }

    # ---- Sanity -----------------------------------------------------------
    if ($segmentPaths.Count -gt 0 -and $segmentsWithPorts -eq 0) {
        Write-RichoLog (("Not one of {0} segments reported a port. That is implausible for an estate with " +
                "workloads - check the account's NSX role before acting on this report.") -f $segmentPaths.Count) -Level WARN
    }

    # ---- Export -----------------------------------------------------------
    $outputDirectory = Split-Path -Path $OutputPath -Parent
    if ($outputDirectory -and -not (Test-Path -Path $outputDirectory)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }

    if ($results.Count -gt 0) {
        $results.ToArray() | Sort-Object ObjectType, Space, Name |
            Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    }
    else {
        # Header row only, so an empty result is still a well-formed CSV.
        (ConvertTo-NsxAuditRow -ObjectType '' -InputObject $null | ConvertTo-Csv -NoTypeInformation)[0] |
            Set-Content -Path $OutputPath -Encoding UTF8
    }

    $segmentCount = @($results | Where-Object { $_.ObjectType -eq 'Segment' }).Count
    $tier1Count = $results.Count - $segmentCount
    Write-RichoLog ("Checked {0} segment(s) and {1} Tier-1 gateway(s) in {2} API request(s)." -f
        $segmentPaths.Count, $tier1s.Count, $script:Nsx.RequestCount) -Level INFO
    if ($segmentsSkipped -gt 0) {
        Write-RichoLog "$segmentsSkipped segment(s) could not be checked and are not in the report." -Level WARN
    }
    if (@($spaces | Where-Object { -not $_.Complete }).Count -gt 0) {
        Write-RichoLog 'One or more multi-tenancy projects were NOT audited - see the warnings above.' -Level WARN
    }
    Write-RichoLog "Potentially unused: $segmentCount segment(s), $tier1Count Tier-1 gateway(s)." -Level INFO
    Write-RichoLog "CSV: $OutputPath" -Level INFO

    if ($results.Count -gt 0) {
        $results.ToArray() | Sort-Object ObjectType, Space, Name |
            Format-Table ObjectType, Name, Space, CreatedBy -AutoSize |
            Out-String -Width 4096 | Out-Host
    }

    Write-RichoLog 'Completed successfully.' -Level INFO
}
catch {
    Write-RichoLog "Failed: $($_.Exception.Message)" -Level ERROR
    throw
}
finally {
    Write-Progress -Activity 'Reading Tier-1 gateways' -Completed
    Write-Progress -Activity 'Checking segments' -Completed
    Disconnect-NsxApi
    Restore-NsxTransport -State $transport
    if ($transcriptPath) { Stop-Transcript | Out-Null }
}
