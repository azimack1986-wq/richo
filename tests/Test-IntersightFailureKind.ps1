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
    Where-Object { $_.Name -in @('Get-IntersightFailureKind','Get-ExceptionDetail') } |
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

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
