<#
.SYNOPSIS
    Tests Intersight BasePath normalisation and SaaS/PVA classification.

.DESCRIPTION
    Extracts ConvertTo-IntersightBaseUrl and Test-IntersightSaaSUrl from the controller by AST
    and checks the forms an operator might actually type or paste at the FQDN prompt, plus the
    inputs that must be rejected rather than guessed at.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-IntersightBaseUrl.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchControl.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$wanted = @('ConvertTo-IntersightBaseUrl','Test-IntersightSaaSUrl')
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

$pva = "siepd24pva0001.dpe.protected.mil.au"

Write-Host "`n=== Accepted input forms all normalise to the same BasePath ===" -ForegroundColor Cyan
foreach ($input in @(
    $pva,
    "  $pva  ",
    "https://$pva",
    "http://$pva",
    "https://$pva/",
    "https://$pva///",
    "https://$pva/api/v1",
    "https://$pva/api/v1/",
    "$pva/api/v1",
    "https://$pva/API/V1",
    "`"$pva`"",
    "'$pva'"
)) {
    Assert-Equal "'$input'" "https://$pva" (ConvertTo-IntersightBaseUrl -Value $input)
}

Write-Host "`n=== Other valid shapes ===" -ForegroundColor Cyan
Assert-Equal "bare hostname"          "https://pva01"            (ConvertTo-IntersightBaseUrl -Value "pva01")
Assert-Equal "IPv4 address"           "https://10.20.30.40"      (ConvertTo-IntersightBaseUrl -Value "10.20.30.40")
Assert-Equal "explicit port kept"     "https://$pva`:443"        (ConvertTo-IntersightBaseUrl -Value "https://$pva`:443/")
Assert-Equal "SaaS default"           "https://intersight.com"   (ConvertTo-IntersightBaseUrl -Value "intersight.com")
Assert-Equal "hostname with hyphens"  "https://pva-01.example.com" (ConvertTo-IntersightBaseUrl -Value "pva-01.example.com")

Write-Host "`n=== Rejected input returns empty so the prompt repeats ===" -ForegroundColor Cyan
foreach ($bad in @(
    "", "   ", "https://", "http://", "/",
    "not a hostname",
    "$pva/extra/path",
    "https://$pva/somethingelse",
    "-leadinghyphen.example.com",
    "trailinghyphen-.example.com",
    "user:pass@$pva",
    "${pva}:notaport",
    "${pva}:99999999",
    "pva 01.example.com"
)) {
    Assert-Equal "rejects '$bad'" "" (ConvertTo-IntersightBaseUrl -Value $bad)
}

Write-Host "`n=== SaaS vs on-prem PVA classification ===" -ForegroundColor Cyan
Assert-Equal "intersight.com is SaaS"          $true  (Test-IntersightSaaSUrl -BaseUrl "https://intersight.com")
Assert-Equal "eu.intersight.com is SaaS"       $true  (Test-IntersightSaaSUrl -BaseUrl "https://eu.intersight.com")
Assert-Equal "PVA FQDN is not SaaS"            $false (Test-IntersightSaaSUrl -BaseUrl "https://$pva")
Assert-Equal "lookalike domain is not SaaS"    $false (Test-IntersightSaaSUrl -BaseUrl "https://intersight.com.evil.example")
Assert-Equal "IP is not SaaS"                  $false (Test-IntersightSaaSUrl -BaseUrl "https://10.20.30.40")

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
