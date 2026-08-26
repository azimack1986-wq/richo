<#
.SYNOPSIS
    Tests that the committed self-contained build matches the repo script it is generated from.

.DESCRIPTION
    There are two copies of the UCS audit in this repo: the one under scripts/ucs that imports
    Richo.Common, and the generated one under dist that carries the helpers inline so it can be
    dropped on a jump host or a file share on its own.

    Two copies of a three thousand line script drift. The copy that drifts is the one on the
    share - the one an operator actually runs, months later, against production, believing it is
    the reviewed version. So the generated file is committed (it has to be, to be downloadable)
    and this test regenerates it in memory and compares.

    A failure here means one of two things: the repo script changed and the build was not
    regenerated, or somebody edited the generated file by hand. Both are fixed the same way:

        pwsh -File ./tools/Build-UcsBestPracticeStandalone.ps1

    Line endings are normalised before comparing. .gitattributes checks .ps1 out as CRLF while the
    builder writes LF, so a byte comparison would fail on a Windows checkout for a reason that has
    nothing to do with the content.

    Standalone - no Pester, no UCS PowerTool, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsBestPracticeStandalone.ps1
#>

$repoRoot = Split-Path $PSScriptRoot -Parent
$builderPath = Join-Path $repoRoot 'tools/Build-UcsBestPracticeStandalone.ps1'
$sourcePath = Join-Path $repoRoot 'scripts/ucs/Test-UcsBestPractice.ps1'
$distPath = Join-Path $repoRoot 'dist/Test-UcsBestPractice-Standalone.ps1'

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}
function Assert-True {
    param([string]$Name, $Condition)
    Assert-Equal -Name $Name -Expected $true -Actual ([bool]$Condition)
}
function ConvertTo-Lf { param([string]$Text) ($Text -replace "`r`n", "`n").TrimEnd() }

Write-Host "`n=== The generated build exists and is current ===" -ForegroundColor Cyan
Assert-True 'the builder is present' (Test-Path $builderPath)
Assert-True 'the source script is present' (Test-Path $sourcePath)
Assert-True 'the generated build is committed' (Test-Path $distPath)

if (-not (Test-Path $distPath)) {
    Write-Host "`n  $($script:pass) passed, $($script:fail) FAILED." -ForegroundColor Red
    exit 1
}

$regenerated = & $builderPath -PassThru
$committed = [IO.File]::ReadAllText($distPath)
Assert-Equal 'the committed build matches a fresh regeneration' (ConvertTo-Lf $regenerated) (ConvertTo-Lf $committed)
if ((ConvertTo-Lf $regenerated) -ne (ConvertTo-Lf $committed)) {
    Write-Host '          Regenerate it: pwsh -File ./tools/Build-UcsBestPracticeStandalone.ps1' -ForegroundColor Red
}

Write-Host "`n=== The generated build stands on its own ===" -ForegroundColor Cyan
$errors = $null; $tokens = $null
$distAst = [System.Management.Automation.Language.Parser]::ParseFile($distPath, [ref]$tokens, [ref]$errors)
Assert-Equal 'it parses without syntax errors' 0 @($errors).Count

$distText = ConvertTo-Lf $committed

# Checked against the parsed commands, not the raw text: the inlined helper block carries a comment
# naming modules/Richo.Common as the place to edit them, and a text search cannot tell that comment
# apart from an actual import.
$distImports = @($distAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object { $_.GetCommandName() -eq 'Import-Module' })
$richoImports = @($distImports | Where-Object { $_.Extent.Text -match 'Richo' })
Assert-Equal 'it imports Richo.Common nowhere' 0 $richoImports.Count
Assert-True  'and has no repo-relative module path left' ($distText -notmatch '\.\.\\\.\.\\modules')

# The one Import-Module that legitimately survives is inside Assert-RichoModule's -Import switch,
# which imports a VENDOR module and which this audit never passes.
Assert-Equal 'the only Import-Module left is the vendor one in Assert-RichoModule' 1 $distImports.Count

$distFunctions = @($distAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
foreach ($helper in @('Write-RichoLog', 'Get-RichoCredential', 'Assert-RichoModule', 'Start-RichoTranscript')) {
    Assert-True "$helper is inlined" ($distFunctions -contains $helper)
}

Write-Host "`n=== The generated build audits exactly what the repo script audits ===" -ForegroundColor Cyan
$sourceErrors = $null; $sourceTokens = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$sourceTokens, [ref]$sourceErrors)
Assert-Equal 'the source script parses' 0 @($sourceErrors).Count

$sourceChecks = @($sourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $_.Name -like 'Test-UcsBp*' -or $_.Name -like 'Get-UcsBp*' -or $_.Name -like 'Add-UcsBp*' } |
        ForEach-Object { $_.Name } | Sort-Object)
$distChecks = @($distFunctions | Where-Object { $_ -like 'Test-UcsBp*' -or $_ -like 'Get-UcsBp*' -or $_ -like 'Add-UcsBp*' } | Sort-Object)
Assert-Equal 'every check function survives generation' ($sourceChecks -join ',') ($distChecks -join ',')

# The CheckId literals are the audit. If generation dropped or altered one, the CSV would quietly
# lose a row and nothing else would say so.
function Get-CheckId {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
            ForEach-Object { $_.Value } |
            Where-Object { $_ -match '^UCS-[A-Z]+-\d' } |
            Sort-Object -Unique)
}
$sourceIds = Get-CheckId -Ast $sourceAst
$distIds = Get-CheckId -Ast $distAst
Assert-True  'the source script defines check IDs' ($sourceIds.Count -gt 40)
Assert-Equal 'every check ID survives generation'  ($sourceIds -join ',') ($distIds -join ',')

Write-Host "`n=== Output does not land next to the script ===" -ForegroundColor Cyan
# The whole point of this build is that it gets copied to a share. Writing the CSV beside itself
# would mean writing audit output to that share - often read-only, always the wrong place.
Assert-True 'the build resolves its output directory from the current location' ($distText -match '\$script:BpOutputDirectory')
Assert-True 'from $PWD rather than $PSScriptRoot'                               ($distText -match '\$PWD\.ProviderPath')
Assert-True 'with a fallback when the current location is not a filesystem one' ($distText -match 'MyDocuments')
Assert-True 'and the transcript follows it'                                     ($distText -match 'Start-RichoTranscript -Directory \$script:BpOutputDirectory')
Assert-True 'the repo script is unchanged in this respect'                      ((ConvertTo-Lf ([IO.File]::ReadAllText($sourcePath))) -match "Join-Path \`$repoRoot 'output'")

Write-Host ''
if ($script:fail -eq 0) { Write-Host "  $($script:pass) assertions passed." -ForegroundColor Green }
else { Write-Host "  $($script:pass) passed, $($script:fail) FAILED." -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
