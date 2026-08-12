<#
.SYNOPSIS
    Tests that a deserialization failure is not mistaken for a rejected API key.

.DESCRIPTION
    Intersight.PowerShell reports both a rejected key and an unparseable response as
    "Error performing this operation. Check that BasePath and API Key identifier are configured
    correctly". Only one of those is about credentials. Telling an operator to regenerate a
    working API key mid-change is expensive and wrong, so the classification is tested against
    the real error shapes.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-IntersightFailureKind.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchControl.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-IntersightFailureKind','Get-ExceptionDetail','Get-IntersightDeployRefusalReason') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

function New-ErrorRecord {
    param([string]$OuterMessage,[string]$InnerMessage)
    $inner = if ($InnerMessage) { [System.IO.InvalidDataException]::new($InnerMessage) } else { $null }
    $outer = if ($inner) { [System.Exception]::new($OuterMessage, $inner) } else { [System.Exception]::new($OuterMessage) }
    return [System.Management.Automation.ErrorRecord]::new($outer, 'TestError', 'NotSpecified', $null)
}

$genericOuter = "Error performing this operation. Check that BasePath and API Key identifier are configured correctly using the Set-IntersightConfiguration cmdlet."

Write-Host "`n=== The real failure: key accepted, response unparseable ===" -ForegroundColor Cyan

# Abridged from an actual PVA run. The payload carries real account data, which the appliance
# only returns once it has verified the request signature.
$realInner = 'The JSON string `{"ObjectType":"organization.Organization.List","Results":[{"Account":{"ClassId":"mo.MoRef","Moid":"66a991c2756461301f36ec7f","ObjectType":"iam.Account"},"Name":"global","ObjectType":"organization.Organization"}]}` cannot be deserialized into any schema defined.'
$rec = New-ErrorRecord -OuterMessage $genericOuter -InnerMessage $realInner
$kind = Get-IntersightFailureKind -ErrorRecord $rec
Assert-Equal "classified as Deserialization, not Authentication" "Deserialization" $kind.Kind
Assert-Equal "reported as authenticated" $true $kind.Authenticated

Write-Host "`n=== Genuine credential rejections ===" -ForegroundColor Cyan
foreach ($case in @(
    @{ Name = "iam_api_key_is_invalid"; Inner = "iam_api_key_is_invalid: the supplied key is not valid" },
    @{ Name = "AuthenticationFailure";  Inner = "AuthenticationFailure" },
    @{ Name = "401 Unauthorized";       Inner = "The remote server returned an error: (401) Unauthorized." },
    @{ Name = "signature rejected";     Inner = "cannot sign http request, request does not contain date header" }
)) {
    $k = Get-IntersightFailureKind -ErrorRecord (New-ErrorRecord -OuterMessage $genericOuter -InnerMessage $case.Inner)
    Assert-Equal "'$($case.Name)' classified as Authentication" "Authentication" $k.Kind
    Assert-Equal "'$($case.Name)' not reported as authenticated" $false $k.Authenticated
}

Write-Host "`n=== Anything else stays Unknown rather than guessing ===" -ForegroundColor Cyan
$k = Get-IntersightFailureKind -ErrorRecord (New-ErrorRecord -OuterMessage "Connection timed out" -InnerMessage "A socket operation timed out")
Assert-Equal "timeout is Unknown" "Unknown" $k.Kind
Assert-Equal "timeout not reported as authenticated" $false $k.Authenticated

$k = Get-IntersightFailureKind -ErrorRecord (New-ErrorRecord -OuterMessage $genericOuter -InnerMessage $null)
Assert-Equal "bare generic message is Unknown" "Unknown" $k.Kind

Write-Host "`n=== Giant payloads are truncated, not dumped ===" -ForegroundColor Cyan
$huge = 'The JSON string `{"Results":[' + ('{"Moid":"66a991c2756461301f36ec7f","Name":"padding"},' * 500) + ']}` cannot be deserialized into any schema defined.'
$detail = Get-ExceptionDetail -ErrorRecord (New-ErrorRecord -OuterMessage $genericOuter -InnerMessage $huge)
Assert-Equal "huge inner message truncated" $true ($detail.Length -lt 1500)
Assert-Equal "truncation is stated, not silent" $true ($detail -match 'truncated')
Assert-Equal "original message length reported" $true ($detail -match '\d+ chars total')

Write-Host "`n=== A refused deploy is classified, not flattened to 'deploy failed' ===" -ForegroundColor Cyan
# Straight from a live run. The blade had dropped off Intersight; nothing about the profile or the
# firmware policy was wrong, and no amount of retrying from the script would have helped. Telling
# the operator "deploy failed" would have sent them looking in the wrong place.
$disconnected = 'Error calling UpdateServerProfile: {"code":"InvalidRequest","message":"Cannot deploy the server profile. The server is disconnected. Check connectivity and try again.","messageId":"gershwin_server_is_not_connected","traceId":"NBfe8772878ef9cb88ded0a76c00ac8e97"}'
$r = Get-IntersightDeployRefusalReason -Message $disconnected
Assert-Equal "a disconnected server is named as such" "Server disconnected from Intersight" $r.Reason
Assert-Equal "and the advice points at connectivity, not configuration" $true ($r.Advice -match 'device connector')
Assert-Equal "it does not blame the firmware policy" $true (-not ($r.Advice -match '(?i)policy is wrong|re-?stage'))

$notAllowed = 'Error calling UpdateServerProfile: {"code":"InvalidRequest","message":"Action ''Activate'' is not allowed in the current state.","messageId":"gershwin_user_action_is_not_allowed"}'
Assert-Equal "a state refusal is told apart from a connectivity one" "Deploy not allowed from the profile's current state" (Get-IntersightDeployRefusalReason -Message $notAllowed).Reason

$upgrading = 'Cannot perform power action when a firmware upgrade is in progress. messageId: action_not_allowed_firmware_upgrade_in_progress'
Assert-Equal "an upgrade already running is its own case" "A firmware upgrade is already running" (Get-IntersightDeployRefusalReason -Message $upgrading).Reason

# Never invent a cause. An unrecognised message keeps the appliance's own words.
$novel = 'Error calling UpdateServerProfile: something nobody has seen before'
$u = Get-IntersightDeployRefusalReason -Message $novel
Assert-Equal "an unrecognised refusal is not guessed at" "Intersight refused the deploy" $u.Reason
Assert-Equal "and the appliance's own words are kept" $novel $u.Summary
Assert-Equal "an empty message does not throw" "Intersight refused the deploy" (Get-IntersightDeployRefusalReason -Message '').Reason

Write-Host "`n=== A refused deploy does not end the run ===" -ForegroundColor Cyan
# The live failure ended the whole run with the rest of the batch already evacuated and in
# Maintenance mode. One host the appliance will not deploy is one host's problem.
$deployText = [System.IO.File]::ReadAllText($scriptPath)
$catchBlock = ""
if ($deployText -match '(?s)Add-SummaryRecord -Stage "IntersightAcceptReboot" -Batch \$BatchNumber -HostName \$row\.Host -Action "Deploy server profile" -Result "Failed".{0,400}') { $catchBlock = $Matches[0] }
Assert-Equal "the deploy failure path was found" $true (-not [string]::IsNullOrWhiteSpace($catchBlock))
Assert-Equal "a failed deploy no longer stops the workflow" $true (-not ($deployText -match 'Stop-WithMessage "Intersight server profile deploy failed'))
Assert-Equal "it is recorded for manual rectification instead" $true ($deployText -match 'Add-ManualAttentionHost -HostName \$row\.Host -Reason \$reason\.Reason')
# Nothing was sent, so nothing reboots. A stale baseline would have the reconnect gate wait out
# its whole window for a restart that was never requested, then report the host as not back.
Assert-Equal "the boot-time baseline is cleared so no reboot is expected" $true ($deployText -match '\$Global:PreRebootBootTimes\.Remove\(\$row\.Host\)')

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
