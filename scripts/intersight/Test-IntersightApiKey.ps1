<#
.SYNOPSIS
    Diagnoses an Intersight API Key ID and .pem private key against an appliance.

.DESCRIPTION
    Standalone read-only checker for the exact failure the firmware batch controller reports as
    "Error performing this operation. Check that BasePath and API Key identifier are configured
    correctly" - a message that covers every possible cause and names none of them.

    Works through the causes in order and prints a verdict for each:

      1. PowerShell edition and version. Intersight.PowerShell is a binary module built for
         PowerShell 7 (Core). Windows PowerShell 5.1 is a known-bad host for it.
      2. Installed module versions. Side-by-side versions are the most common cause of an
         authentication failure with a perfectly valid key.
      3. Private key file - existence, PEM header and footer, key type, byte-order mark,
         line endings, stray whitespace. Contents are never printed.
      4. API Key ID shape - three segments, each a 24-character hex object ID.
      5. Proxy in front of the appliance, which can break signature validation.
      6. Reachability, separating a wrong or unreachable FQDN from a rejected key.
      7. Clock skew against the appliance's own Date header. HTTP signature auth signs the
         Date header, so a jump host more than a few minutes out is rejected with no clue why.
      8. The authentication itself, tried first with the key file and then with the key passed
         as a string, which works around PEM encoding and whitespace problems.

    Changes nothing. Touches no host, no profile, no policy.

.PARAMETER BaseUrl
    Appliance address. Bare FQDN or full URL; scheme, trailing slash and any /api/v1 suffix are
    handled. Prompted for when omitted.

.PARAMETER ApiKeyId
    Intersight API Key ID, three segments separated by '/'. Prompted for when omitted.

.PARAMETER ApiKeyFilePath
    Path to the .pem private key issued with that Key ID. Prompted for when omitted.

.PARAMETER SkipCertificateCheck
    Relax certificate validation, as an on-prem PVA with a private CA normally requires.
    Defaults to on for anything that is not intersight.com.

.EXAMPLE
    .\Test-IntersightApiKey.ps1

.EXAMPLE
    .\Test-IntersightApiKey.ps1 -BaseUrl siepd85csp1000.dpe.protected.mil.au -ApiKeyFilePath C:\Temp\CPMidrange_intersight.pem
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl,
    [string]$ApiKeyId,
    [string]$ApiKeyFilePath,
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Findings = New-Object System.Collections.Generic.List[object]

function Write-Check {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][ValidateSet('PASS','WARN','FAIL','INFO')][string]$Result,
        [string]$Detail = ""
    )
    $colour = switch ($Result) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ("  [{0}] {1}" -f $Result.PadRight(4), $Name) -ForegroundColor $colour
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "         $Detail" -ForegroundColor Gray }
    $script:Findings.Add([pscustomobject]@{ Check=$Name; Result=$Result; Detail=$Detail })
}

function Write-Section { param([string]$Title) Write-Host "`n$Title" -ForegroundColor Cyan }

function ConvertTo-BaseUrl {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $h = $Value.Trim().Trim('"').Trim("'")
    $h = $h -replace '^\s*[A-Za-z][A-Za-z0-9+.-]*://', ''
    $h = $h -replace '/+$', ''
    $h = $h -replace '(?i)/api/v\d+$', ''
    $h = $h -replace '/+$', ''
    if ($h -notmatch '^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*(:\d{1,5})?$') { return "" }
    return "https://$h"
}

function Get-ExceptionChain {
    param($ErrorRecord)
    $lines = New-Object System.Collections.Generic.List[string]
    $ex = $ErrorRecord.Exception
    $depth = 0
    while ($null -ne $ex -and $depth -lt 6) {
        $lines.Add("    [$($ex.GetType().Name)] $($ex.Message)")
        foreach ($prop in @("StatusCode","ErrorCode","ResponseBody","ErrorContent")) {
            try {
                if ($ex.PSObject.Properties.Name -contains $prop -and $null -ne $ex.$prop) {
                    $v = [string]$ex.$prop
                    if (-not [string]::IsNullOrWhiteSpace($v) -and $v.Length -lt 2000) { $lines.Add("        ${prop}: $v") }
                }
            } catch {}
        }
        $ex = $ex.InnerException
        $depth++
    }
    return ($lines -join [Environment]::NewLine)
}

Write-Host "`n=====================================================================" -ForegroundColor Cyan
Write-Host " Intersight API key checker - read only, changes nothing" -ForegroundColor Cyan
Write-Host "=====================================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($BaseUrl))        { $BaseUrl = Read-Host "Intersight FQDN (e.g. siepd85csp1000.dpe.protected.mil.au)" }
if ([string]::IsNullOrWhiteSpace($ApiKeyId))       { $ApiKeyId = Read-Host "Intersight API Key ID (aaa/bbb/ccc)" }
if ([string]::IsNullOrWhiteSpace($ApiKeyFilePath)) { $ApiKeyFilePath = (Read-Host "Path to the .pem private key").Trim().Trim('"') }

$normalisedBase = ConvertTo-BaseUrl -Value $BaseUrl
if ([string]::IsNullOrWhiteSpace($normalisedBase)) {
    Write-Host "`n'$BaseUrl' is not a valid hostname, FQDN or IP address." -ForegroundColor Red
    exit 1
}
$ApiKeyId = $ApiKeyId.Trim()

$isSaaS = ($normalisedBase -match '(?i)^https://([A-Za-z0-9-]+\.)*intersight\.com(:\d+)?$')
if (-not $PSBoundParameters.ContainsKey('SkipCertificateCheck')) { $SkipCertificateCheck = (-not $isSaaS) }

Write-Host "`nTarget    : $normalisedBase"
Write-Host "Kind      : $(if ($isSaaS) { 'SaaS' } else { 'on-prem PVA' })"
Write-Host "Key file  : $ApiKeyFilePath"
Write-Host "Cert check: $(if ($SkipCertificateCheck) { 'relaxed' } else { 'enforced' })"

# ---------------------------------------------------------------------------
# 1. PowerShell edition
# ---------------------------------------------------------------------------
Write-Section "1. PowerShell host"
# $PSVersionTable is a Hashtable, so membership is ContainsKey - .PSObject.Properties returns its
# .NET members, not its keys, and would report every PowerShell 7 host as Desktop.
# PSEdition is absent entirely on 5.0 and earlier, where Desktop is the correct answer.
$edition = if ($PSVersionTable.ContainsKey('PSEdition')) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
if ($edition -eq 'Core') {
    Write-Check -Name "PowerShell edition" -Result PASS -Detail "$edition $($PSVersionTable.PSVersion) - correct host for Intersight.PowerShell."
}
else {
    Write-Check -Name "PowerShell edition" -Result FAIL -Detail "$edition $($PSVersionTable.PSVersion). Intersight.PowerShell is a binary module built for PowerShell 7 (Core). Re-run this in pwsh.exe, not Windows PowerShell 5.1."
}

# ---------------------------------------------------------------------------
# 2. Module versions
# ---------------------------------------------------------------------------
Write-Section "2. Intersight.PowerShell module"
$available = @(Get-Module -ListAvailable -Name Intersight.PowerShell -ErrorAction SilentlyContinue)
if ($available.Count -eq 0) {
    Write-Check -Name "Module installed" -Result FAIL -Detail "Not found. Install-Module Intersight.PowerShell -Scope CurrentUser"
}
else {
    $distinct = @($available | Select-Object -ExpandProperty Version -Unique)
    if ($distinct.Count -gt 1) {
        Write-Check -Name "Single module version" -Result FAIL -Detail "$($distinct.Count) versions installed. This is the most common cause of this failure with a valid key."
        foreach ($m in $available) { Write-Host "         $($m.Version)  $($m.ModuleBase)" -ForegroundColor Gray }
        Write-Host "         Remove the older versions, close PowerShell, reopen, and retry." -ForegroundColor Yellow
    }
    else {
        Write-Check -Name "Single module version" -Result PASS -Detail "$($distinct[0])  $($available[0].ModuleBase)"
    }
    Import-Module Intersight.PowerShell -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 3. Private key file
# ---------------------------------------------------------------------------
Write-Section "3. Private key file"
if (-not (Test-Path -Path $ApiKeyFilePath)) {
    Write-Check -Name "Key file exists" -Result FAIL -Detail "Not found at '$ApiKeyFilePath'."
}
else {
    $bytes = [System.IO.File]::ReadAllBytes($ApiKeyFilePath)
    $text  = [System.IO.File]::ReadAllText($ApiKeyFilePath)
    $lines = @($text -split "`r?`n" | Where-Object { $_ -ne "" })

    Write-Check -Name "Key file exists" -Result PASS -Detail "$($bytes.Length) bytes, $($lines.Count) non-empty lines."

    $firstLine = if ($lines.Count -gt 0) { $lines[0] } else { "" }
    $lastLine  = if ($lines.Count -gt 0) { $lines[$lines.Count - 1] } else { "" }

    if ($firstLine -match '^-----BEGIN (EC|RSA) PRIVATE KEY-----$') {
        $keyType = $Matches[1]
        Write-Check -Name "PEM header" -Result PASS -Detail "$firstLine  ($keyType key - Intersight API key $(if ($keyType -eq 'EC') { 'v3' } else { 'v2' }))"
    }
    elseif ($firstLine -match '^-----BEGIN PRIVATE KEY-----$') {
        Write-Check -Name "PEM header" -Result WARN -Detail "PKCS#8 wrapper. Intersight issues EC or RSA PEM. If auth fails, re-download the secret key rather than converting it."
    }
    else {
        Write-Check -Name "PEM header" -Result FAIL -Detail "First line is not a PEM private key header. Found: '$firstLine'"
    }

    if ($lastLine -match '^-----END .*PRIVATE KEY-----$') {
        Write-Check -Name "PEM footer" -Result PASS -Detail $lastLine
    }
    else {
        Write-Check -Name "PEM footer" -Result FAIL -Detail "Last line is not a PEM footer. Found: '$lastLine'. The file may be truncated."
    }

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Write-Check -Name "No byte-order mark" -Result FAIL -Detail "File starts with a UTF-8 BOM. Re-save as UTF-8 without BOM, or use the key-string method below."
    }
    else {
        Write-Check -Name "No byte-order mark" -Result PASS
    }

    if ($text -match '^\s') {
        Write-Check -Name "No leading whitespace" -Result WARN -Detail "File begins with whitespace before the PEM header."
    }
    else {
        Write-Check -Name "No leading whitespace" -Result PASS
    }
}

# ---------------------------------------------------------------------------
# 4. API Key ID shape
# ---------------------------------------------------------------------------
Write-Section "4. API Key ID"
$segments = @($ApiKeyId -split '/')
if ($segments.Count -ne 3) {
    Write-Check -Name "Three segments" -Result FAIL -Detail "Found $($segments.Count). Expected aaa/bbb/ccc."
}
else {
    Write-Check -Name "Three segments" -Result PASS
    $badSegments = @()
    for ($i = 0; $i -lt 3; $i++) {
        if ($segments[$i] -notmatch '^[0-9a-fA-F]{24}$') { $badSegments += "segment $($i+1) ('$($segments[$i])') is $($segments[$i].Length) chars" }
    }
    if ($badSegments.Count -gt 0) {
        Write-Check -Name "Segments are 24-char object IDs" -Result WARN -Detail ($badSegments -join '; ')
    }
    else {
        Write-Check -Name "Segments are 24-char object IDs" -Result PASS
    }
}

# ---------------------------------------------------------------------------
# 5. Proxy
# ---------------------------------------------------------------------------
Write-Section "5. Proxy"
try {
    $proxy = [System.Net.WebRequest]::DefaultWebProxy
    $proxyUri = $null
    if ($null -ne $proxy) { $proxyUri = $proxy.GetProxy([Uri]"$normalisedBase/") }
    if ($null -ne $proxyUri -and $proxyUri.AbsoluteUri.TrimEnd('/') -ne "$normalisedBase") {
        Write-Check -Name "No proxy in path" -Result WARN -Detail "Requests to the appliance route via $($proxyUri.AbsoluteUri). An intercepting proxy can alter headers and break signature validation. Try bypassing it for this host."
    }
    else {
        Write-Check -Name "No proxy in path" -Result PASS -Detail "Direct connection."
    }
}
catch { Write-Check -Name "Proxy detection" -Result INFO -Detail $_.Exception.Message }

# ---------------------------------------------------------------------------
# 6 and 7. Reachability and clock skew
# ---------------------------------------------------------------------------
Write-Section "6. Reachability and clock"
$previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$applianceDate = $null
try {
    $supportsSkip = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')
    if (-not $supportsSkip -and $SkipCertificateCheck) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}

    $iwr = @{ Uri = "$normalisedBase/"; Method = 'Get'; TimeoutSec = 20; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if ($supportsSkip -and $SkipCertificateCheck) { $iwr['SkipCertificateCheck'] = $true }

    $resp = $null
    try { $resp = Invoke-WebRequest @iwr }
    catch {
        $webResp = $null
        try { $webResp = $_.Exception.Response } catch {}
        if ($null -ne $webResp) {
            Write-Check -Name "Appliance answers HTTPS" -Result PASS -Detail "HTTP $([int]$webResp.StatusCode) - the endpoint is live, so this is about the key, not the address."
            try { $applianceDate = [datetime]::Parse($webResp.Headers['Date']) } catch {}
        }
        else {
            Write-Check -Name "Appliance answers HTTPS" -Result FAIL -Detail $_.Exception.Message
        }
    }

    if ($null -ne $resp) {
        Write-Check -Name "Appliance answers HTTPS" -Result PASS -Detail "HTTP $([int]$resp.StatusCode) from $normalisedBase/"
        try { $applianceDate = [datetime]::Parse([string]$resp.Headers['Date']) } catch {}
    }

    if ($null -ne $applianceDate) {
        $skew = [Math]::Abs(((Get-Date).ToUniversalTime() - $applianceDate.ToUniversalTime()).TotalSeconds)
        $detail = "Local UTC $((Get-Date).ToUniversalTime().ToString('u')), appliance UTC $($applianceDate.ToUniversalTime().ToString('u')), skew $([Math]::Round($skew)) seconds."
        if ($skew -gt 300) {
            Write-Check -Name "Clock within 5 minutes of appliance" -Result FAIL -Detail "$detail HTTP signature auth signs the Date header, so this alone will cause the failure you are seeing. Sync this machine's clock (w32tm /resync)."
        }
        elseif ($skew -gt 60) {
            Write-Check -Name "Clock within 5 minutes of appliance" -Result WARN -Detail $detail
        }
        else {
            Write-Check -Name "Clock within 5 minutes of appliance" -Result PASS -Detail $detail
        }
    }
    else {
        Write-Check -Name "Clock comparison" -Result INFO -Detail "Appliance did not return a usable Date header."
    }
}
finally {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
}

# ---------------------------------------------------------------------------
# 8. Authentication
# ---------------------------------------------------------------------------
Write-Section "7. Authentication"
if ($null -eq (Get-Command Set-IntersightConfiguration -ErrorAction SilentlyContinue)) {
    Write-Check -Name "Authentication" -Result FAIL -Detail "Set-IntersightConfiguration is unavailable, so the key cannot be tested. Resolve the module problems above first."
}
else {
    $signingHeaders = @("(request-target)", "Host", "Date", "Digest")
    $authenticated = $false

    foreach ($method in @('KeyFile','KeyString')) {
        if ($authenticated) { break }
        if ($method -eq 'KeyString' -and -not (Test-Path -Path $ApiKeyFilePath)) { continue }

        try {
            $cfg = @{
                BasePath          = $normalisedBase
                ApiKeyId          = $ApiKeyId
                HttpSigningHeader = $signingHeaders
                HashAlgorithm     = "SHA256"
                ErrorAction       = "Stop"
            }
            if ($method -eq 'KeyFile') { $cfg['ApiKeyFilePath'] = $ApiKeyFilePath }
            else { $cfg['ApiKeyString'] = (Get-Content -Path $ApiKeyFilePath -Raw) }
            if ($SkipCertificateCheck) { $cfg['SkipCertificateCheck'] = $true }

            Set-IntersightConfiguration @cfg | Out-Null
            [void](Get-IntersightServerProfile -Top 1 -ErrorAction Stop)

            Write-Check -Name "Authentication ($method)" -Result PASS -Detail "The key is accepted by $normalisedBase."
            $authenticated = $true
        }
        catch {
            Write-Check -Name "Authentication ($method)" -Result FAIL -Detail $_.Exception.Message
            Write-Host (Get-ExceptionChain -ErrorRecord $_) -ForegroundColor DarkGray
            if ($method -eq 'KeyFile') { Write-Host "         Retrying with the key passed as a string, which bypasses file encoding problems..." -ForegroundColor Yellow }
        }
    }

    if ($authenticated -and $method -eq 'KeyString') {
        Write-Host "         The key file failed but its contents succeeded - this points at file encoding or whitespace." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
Write-Host "`n=====================================================================" -ForegroundColor Cyan
$failures = @($script:Findings | Where-Object { $_.Result -eq 'FAIL' })
$warnings = @($script:Findings | Where-Object { $_.Result -eq 'WARN' })

if ($failures.Count -eq 0 -and $warnings.Count -eq 0) {
    Write-Host " All checks passed." -ForegroundColor Green
}
else {
    if ($failures.Count -gt 0) {
        Write-Host " $($failures.Count) failure(s) - fix in this order:" -ForegroundColor Red
        $i = 1
        foreach ($f in $failures) { Write-Host "   $i. $($f.Check): $($f.Detail)" -ForegroundColor Red; $i++ }
    }
    if ($warnings.Count -gt 0) {
        Write-Host " $($warnings.Count) warning(s):" -ForegroundColor Yellow
        foreach ($w in $warnings) { Write-Host "   - $($w.Check): $($w.Detail)" -ForegroundColor Yellow }
    }
    Write-Host ""
    Write-Host " If everything above passes but authentication still fails, the Key ID and .pem" -ForegroundColor Yellow
    Write-Host " are almost certainly not a matched pair, or the key was created on a different" -ForegroundColor Yellow
    Write-Host " appliance. They are only ever valid together and the secret is downloadable only" -ForegroundColor Yellow
    Write-Host " at creation. Generate a fresh API key in Settings > API Keys and retry." -ForegroundColor Yellow
}
Write-Host "=====================================================================" -ForegroundColor Cyan
