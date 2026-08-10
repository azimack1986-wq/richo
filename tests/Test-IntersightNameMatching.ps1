<#
.SYNOPSIS
    Tests Intersight CSV name matching in the firmware batch controller.

.DESCRIPTION
    Extracts the CSV-matching functions from the controller by AST and exercises them against
    every combination of fabric suffix (-A, -B, none, lower case, bracket-decorated) and
    FQDN/short shape on both the CSV side and the CDP/LLDP side.

    Deliberately standalone - no Pester and no vendor modules - so it can run anywhere,
    including on a jump host with no gallery access. Touches no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-IntersightNameMatching.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchControl.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$wanted = @('Remove-UcsTargetDecoration','Get-IntersightMatchKeyList','Get-IntersightCsvRowIdentity',
            'Resolve-IntersightCsvMatch','Import-IntersightServerCsv','Convert-FiSystemNameToUcsCandidate')
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name }
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }

# Stubs for the run-summary/exit helpers the import function calls.
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details) }
function Stop-WithMessage { param($Message) throw $Message }

$script:pass = 0; $script:fail = 0
function Assert-True {
    param([string]$Name,[bool]$Condition)
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

$domain = ".dpe.protected.mil.au"
$base   = "PD24000001SS101"

# Every shape either side of the match can legitimately take.
$forms = @(
    @{ Label = 'short, no suffix'; Value = $base },
    @{ Label = 'short, -A';        Value = "$base-A" },
    @{ Label = 'short, -B';        Value = "$base-B" },
    @{ Label = 'short, -a lower';  Value = "$base-a" },
    @{ Label = 'fqdn, no suffix';  Value = "$base$domain" },
    @{ Label = 'fqdn, -A';         Value = "$base-A$domain" },
    @{ Label = 'fqdn, -B';         Value = "$base-B$domain" },
    @{ Label = 'fqdn, -b lower';   Value = "$base-b$domain" },
    @{ Label = 'fqdn, -A bracket'; Value = "$base-A$domain(FD0261301D1)" }
)

Write-Host "`n=== Every CSV form must match every CDP form (same domain) ===" -ForegroundColor Cyan
$csvDir = Join-Path ([IO.Path]::GetTempPath()) ("csvtest-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $csvDir | Out-Null

foreach ($csvForm in $forms) {
    $IntersightCsvPath = Join-Path $csvDir "one.csv"
    "Name`n$($csvForm.Value -replace '"','""')" | Set-Content -Path $IntersightCsvPath -Encoding UTF8
    $Global:IntersightServerList = @{}
    Import-IntersightServerCsv 6>$null

    $misses = @()
    foreach ($cdpForm in $forms) {
        if ($null -eq (Resolve-IntersightCsvMatch -CdpSystemName $cdpForm.Value)) { $misses += $cdpForm.Label }
    }
    Assert-True "CSV '$($csvForm.Label)' matches all 9 CDP forms$(if($misses){" (missed: $($misses -join '; '))"})" ($misses.Count -eq 0)
}

Write-Host "`n=== A different domain must NOT match ===" -ForegroundColor Cyan
$IntersightCsvPath = Join-Path $csvDir "one.csv"
"Name`n$base-A$domain" | Set-Content -Path $IntersightCsvPath -Encoding UTF8
$Global:IntersightServerList = @{}
Import-IntersightServerCsv 6>$null
foreach ($other in @("PD24000001SS102-A$domain", "PD24000001SS102", "PD24000001SS10-A$domain", "OTHERBOX-B")) {
    Assert-True "no false match for '$other'" ($null -eq (Resolve-IntersightCsvMatch -CdpSystemName $other))
}
Assert-True "blank CDP name does not match" ($null -eq (Resolve-IntersightCsvMatch -CdpSystemName ""))

Write-Host "`n=== A and B rows for one fabric pair coexist, not overwrite ===" -ForegroundColor Cyan
$IntersightCsvPath = Join-Path $csvDir "pair.csv"
@"
Name,ServerProfileName
$base-A$domain,SP-ESXi-01
$base-B$domain,SP-ESXi-01
"@ | Set-Content -Path $IntersightCsvPath -Encoding UTF8
$Global:IntersightServerList = @{}
Import-IntersightServerCsv 6>$null
$m = Resolve-IntersightCsvMatch -CdpSystemName "$base-B$domain"
Assert-True "A/B pair resolves" ($null -ne $m)
Assert-True "A/B pair both indexed under the base key" (@($Global:IntersightServerList["$base$domain"]).Count -eq 2)
Assert-True "A/B pair agreeing on profile is not ambiguous" (@($Global:IntersightServerList["$base$domain"] | ForEach-Object { Get-IntersightCsvRowIdentity -CsvRow $_ } | Select-Object -Unique).Count -eq 1)

Write-Host "`n=== Genuinely conflicting rows are detectable ===" -ForegroundColor Cyan
$IntersightCsvPath = Join-Path $csvDir "conflict.csv"
@"
Name,ServerProfileName
$base-A$domain,SP-ESXi-01
$base-B$domain,SP-ESXi-99
"@ | Set-Content -Path $IntersightCsvPath -Encoding UTF8
$Global:IntersightServerList = @{}
Import-IntersightServerCsv 6>$null
Assert-True "disagreeing profiles flagged as ambiguous" (@($Global:IntersightServerList["$base$domain"] | ForEach-Object { Get-IntersightCsvRowIdentity -CsvRow $_ } | Select-Object -Unique).Count -eq 2)

Write-Host "`n=== Domain labels ending in -a/-b are not truncated ===" -ForegroundColor Cyan
$keys = Get-IntersightMatchKeyList -Value "HOST01.site-a.example.com"
Assert-True "domain '-a' preserved" ($keys -contains "HOST01.site-a.example.com")
Assert-True "domain '-a' not treated as fabric suffix" (-not ($keys | Where-Object { $_ -eq "HOST01.site" }))

Write-Host "`n=== Old single-key behaviour would have missed these ===" -ForegroundColor Cyan
foreach ($case in @(
    @{ Csv = "$base-A";        Cdp = "$base-B$domain" },
    @{ Csv = "$base";          Cdp = "$base-A$domain" },
    @{ Csv = "$base-A$domain"; Cdp = "$base-B" }
)) {
    $oldCsvKey = Convert-FiSystemNameToUcsCandidate -SystemName $case.Csv
    $oldCdpKey = Convert-FiSystemNameToUcsCandidate -SystemName $case.Cdp
    $oldMatched = ($oldCsvKey -eq $oldCdpKey)

    $IntersightCsvPath = Join-Path $csvDir "regress.csv"
    "Name`n$($case.Csv)" | Set-Content -Path $IntersightCsvPath -Encoding UTF8
    $Global:IntersightServerList = @{}
    Import-IntersightServerCsv 6>$null
    $newMatched = ($null -ne (Resolve-IntersightCsvMatch -CdpSystemName $case.Cdp))

    Assert-True "CSV '$($case.Csv)' vs CDP '$($case.Cdp)': old=$oldMatched new=$newMatched" ((-not $oldMatched) -and $newMatched)
}

Remove-Item -Path $csvDir -Recurse -Force
Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
