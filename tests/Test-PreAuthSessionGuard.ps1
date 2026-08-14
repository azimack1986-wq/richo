<#
.SYNOPSIS
    Verifies the embedded Intersight authentication block applies once per PowerShell session.

.DESCRIPTION
    Invoke-AutoDeployFirmwareBatchPreAuth.ps1 carries the operator's own Set-IntersightConfiguration
    call near the top. Cisco's guidance is that it is applied once per session, and re-applying it
    in a session where it has already been set is unreliable - the fault behind the repeated
    authentication mismatches.

    Running the script twice in one session would otherwise re-apply it silently. This extracts the
    authentication region and runs it repeatedly against a counting stub, asserting the
    configuration is sent exactly once no matter how many times the region is entered.

    Standalone - no Pester, no vendor modules, no infrastructure. Nothing is sent anywhere.

.EXAMPLE
    pwsh -File ./tests/Test-PreAuthSessionGuard.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$text = [System.IO.File]::ReadAllText($scriptPath)

# The guard declaration through to the end marker - the whole once-per-session mechanism.
$pattern = '(?s)if \(\$null -eq \$Global:IntersightConfigurationApplied\).*?# <<< END INTERSIGHT AUTHENTICATION <<<'
$match = [regex]::Match($text, $pattern)
if (-not $match.Success) { throw "Could not locate the authentication region in $scriptPath" }
$authRegion = $match.Value

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# Counting stub. Captures what would have been sent without sending it.
#
# Declares the real cmdlet's parameter names only - note ApiKeyFilePath, not ApiKeyFile. The
# authentication block passes APIKeyFile, which PowerShell resolves as an unambiguous abbreviation
# of ApiKeyFilePath. Modelling the genuine surface means this test also proves that binding works
# rather than assuming it.
# The preflight the region now runs before configuring anything. It loads the module if it is not
# already present, then refuses to go on unless the cmdlet, the PowerShell edition and the key
# file are all genuinely there - so a session that cannot configure Intersight is stopped with the
# reason rather than told it succeeded.
#
# Get-IntersightConfiguration reads back from $script:LastConfig, which the counting stub below
# sets: one source of truth for "what the appliance now holds", so the read-back cannot drift from
# what was sent.
$script:KeyFileReachable = $true
function Test-Path { param($LiteralPath,$Path,$ErrorAction) return $script:KeyFileReachable }
function Get-Module { param($Name,[switch]$ListAvailable) return [pscustomobject]@{ Name = 'Intersight.PowerShell' } }
function Get-IntersightConfiguration {
    if ($null -eq $script:LastConfig) { return [pscustomobject]@{ BasePath = '' } }
    return [pscustomobject]@{ BasePath = $script:LastConfig.BasePath } }

$script:ConfigCallCount = 0
$script:LastConfig = $null
function Set-IntersightConfiguration {
    param(
        [string]$BasePath,
        [string]$ApiKeyId,
        [string]$ApiKeyFilePath,
        [string]$ApiKeyString,
        [string[]]$HttpSigningHeader,
        [string]$HashAlgorithm,
        [string]$ApiKeyPassPhrase,
        [switch]$SkipCertificateCheck
    )
    $script:ConfigCallCount++
    $script:LastConfig = [pscustomobject]@{
        BasePath             = $BasePath
        ApiKeyId             = $ApiKeyId
        ApiKeyFilePath       = $ApiKeyFilePath
        HttpSigningHeader    = $HttpSigningHeader
        HashAlgorithm        = $HashAlgorithm
        SkipCertificateCheck = [bool]$SkipCertificateCheck
    }
}

Write-Host "`n=== The configuration is applied once per session ===" -ForegroundColor Cyan

$Global:IntersightConfigurationApplied = $null
Invoke-Expression $authRegion 6>$null
Assert-Equal "first entry applies the configuration" 1 $script:ConfigCallCount
Assert-Equal "the guard is set after applying" $true $Global:IntersightConfigurationApplied

Invoke-Expression $authRegion 6>$null
Assert-Equal "second entry does not re-apply" 1 $script:ConfigCallCount

Invoke-Expression $authRegion 6>$null
Invoke-Expression $authRegion 6>$null
Assert-Equal "further entries never re-apply" 1 $script:ConfigCallCount

Write-Host "`n=== A fresh session starts clean ===" -ForegroundColor Cyan
# What a new PowerShell process looks like: the guard variable does not exist yet.
Remove-Variable -Name IntersightConfigurationApplied -Scope Global -ErrorAction SilentlyContinue
$script:ConfigCallCount = 0
Invoke-Expression $authRegion 6>$null
Assert-Equal "an undefined guard is treated as not-yet-applied" 1 $script:ConfigCallCount

Write-Host "`n=== The values reach the configuration that is sent ===" -ForegroundColor Cyan
$Global:IntersightConfigurationApplied = $null
$script:ConfigCallCount = 0
Invoke-Expression $authRegion 6>$null

$config = $script:LastConfig
Assert-Equal "BasePath is built from the server variable" "https://$IntersightServer" $config.BasePath
Assert-Equal "BasePath carries no /api path" $false ($config.BasePath -match '/api/')
Assert-Equal "BasePath has no trailing slash" $false ($config.BasePath.EndsWith('/'))
Assert-Equal "the API key id is passed" $APIKeyID $config.ApiKeyId
Assert-Equal "APIKeyFile binds to the real ApiKeyFilePath parameter" $APIKeyFile $config.ApiKeyFilePath
Assert-Equal "four signing headers are passed" 4 @($config.HttpSigningHeader).Count
Assert-Equal "signing headers are in the required order" "(request-target),Host,Date,Digest" (@($config.HttpSigningHeader) -join ',')
Assert-Equal "the API key id has three segments" 3 @($APIKeyID -split '/').Count

# Both are commented out in the block and must stay that way unless the appliance needs them:
# HashAlgorithm already defaults to SHA256, and SkipCertificateCheck swaps the HTTP handler.
Assert-Equal "HashAlgorithm is left at the module default" "" ([string]$config.HashAlgorithm)
Assert-Equal "SkipCertificateCheck is not sent" $false $config.SkipCertificateCheck

Write-Host "`n=== The rest of the script sees the same appliance ===" -ForegroundColor Cyan
# $Global:IntersightBaseUrl is derived from $IntersightServer in User Settings, which runs after
# this region, so one edit above is reflected wherever the script reports the appliance.
$derived = if ($IntersightServer) { "https://$IntersightServer" } else { "" }
Assert-Equal "the script-wide BasePath matches the configured one" $config.BasePath $derived

Write-Host "`n=== A session that cannot configure Intersight is stopped, not told it succeeded ===" -ForegroundColor Cyan
# The live failure: on another PC the module was not installed, Set-IntersightConfiguration was not
# recognised, and the region carried on to print "Intersight configuration applied" and set the
# once-per-session flag. The run failed much later with "Intersight environment is not configured",
# and a retry answered "already applied - start a fresh session". Three misleading messages from
# one unchecked call.
$Global:IntersightConfigurationApplied = $false
$script:ConfigCallCount = 0
$script:LastConfig = $null
$script:KeyFileReachable = $false
$stopped = $false
try { Invoke-Expression $authRegion 6>$null } catch { $stopped = "$_" -match 'prerequisites are not met' }
Assert-Equal "an unreachable key file stops the run" $true $stopped
Assert-Equal "and nothing was sent" 0 $script:ConfigCallCount
Assert-Equal "the session is NOT marked as configured" $false $Global:IntersightConfigurationApplied
$script:KeyFileReachable = $true

# A configuration that returns but did not take - the state behind the live
# "Active BasePath: https://intersight.com" on a run that had just claimed success.
$Global:IntersightConfigurationApplied = $false
$script:LastConfig = [pscustomobject]@{ BasePath = 'https://intersight.com' }
function Set-IntersightConfiguration { param($BasePath,$ApiKeyId,$ApiKeyFilePath,$ApiKeyString,$HttpSigningHeader,$HashAlgorithm,$ApiKeyPassPhrase,[switch]$SkipCertificateCheck)
    $script:LastConfig = [pscustomobject]@{ BasePath = 'https://intersight.com' } }
$stopped2 = $false
try { Invoke-Expression $authRegion 6>$null } catch { $stopped2 = "$_" -match 'did not take effect' }
Assert-Equal "a configuration that did not take is caught by reading it back" $true $stopped2
Assert-Equal "and the session stays unconfigured, so a retry can try again" $false $Global:IntersightConfigurationApplied

# A throwing cmdlet is reported, not swallowed.
$Global:IntersightConfigurationApplied = $false
function Set-IntersightConfiguration { param($BasePath,$ApiKeyId,$ApiKeyFilePath,$ApiKeyString,$HttpSigningHeader,$HashAlgorithm,$ApiKeyPassPhrase,[switch]$SkipCertificateCheck)
    throw "iam_api_key_is_invalid" }
$stopped3 = $false
try { Invoke-Expression $authRegion 6>$null } catch { $stopped3 = "$_" -match 'Set-IntersightConfiguration failed' }
Assert-Equal "a failing configuration call stops the run" $true $stopped3
Assert-Equal "and still leaves the session free to retry" $false $Global:IntersightConfigurationApplied

# The first-run fix itself: the module is loaded once, guarded, before the cmdlet is used.
Assert-Equal "the module is loaded before the cmdlet is used" $true ($authRegion -match 'Import-Module -Name Intersight\.PowerShell')
Assert-Equal "and only when it is not already present" $true ($authRegion -match 'if \(-not \(Get-Module -Name Intersight\.PowerShell\)\)')
Assert-Equal "Windows PowerShell is named as the wrong host" $true ($authRegion -match 'pwsh\.exe')
Assert-Equal "the key file is checked before anything is sent" $true ($authRegion -match 'Test-Path -LiteralPath \$APIKeyFile')

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
