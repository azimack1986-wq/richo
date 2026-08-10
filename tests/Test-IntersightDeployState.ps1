<#
.SYNOPSIS
    Tests which server profile ConfigStates are treated as needing a deploy.

.DESCRIPTION
    A firmware policy change leaves the profile in "Pending-changes", not "Inconsistent". An
    earlier version matched only "Inconsistent", so a live run reported nothing to do, sent no
    deploy, and then waited out the full post-reboot window for a reboot that never happened.

    These cases pin that behaviour down, including the spelling and casing variants the API has
    used for the same state.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-IntersightDeployState.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchControl.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'Get-IntersightProfileDeployState' } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

# Same list the script ships with.
$Global:IntersightActionableConfigStates = @('Pending-changes','Inconsistent','Out-of-sync','Not-deployed')

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

function New-Profile {
    param($ConfigState,[switch]$NoContext)
    if ($NoContext) { return [pscustomobject]@{ Name='sp01'; Moid='abc' } }
    return [pscustomobject]@{ Name='sp01'; Moid='abc'; ConfigContext = [pscustomobject]@{ ConfigState = $ConfigState } }
}

Write-Host "`n=== The state seen on the live run ===" -ForegroundColor Cyan
$s = Get-IntersightProfileDeployState -ServerProfile (New-Profile -ConfigState 'Pending-changes')
Assert-Equal "Pending-changes requires a deploy" $true $s.RequiresDeploy
Assert-Equal "Pending-changes is reported verbatim" "Pending-changes" $s.ConfigState
Assert-Equal "Pending-changes counts as a known state" $true $s.StateKnown

Write-Host "`n=== Other states that mean work is staged ===" -ForegroundColor Cyan
foreach ($state in @('Inconsistent','Out-of-sync','Not-deployed')) {
    Assert-Equal "'$state' requires a deploy" $true (Get-IntersightProfileDeployState -ServerProfile (New-Profile -ConfigState $state)).RequiresDeploy
}

Write-Host "`n=== Spelling and casing variants of the same state ===" -ForegroundColor Cyan
foreach ($variant in @('pending-changes','PENDING-CHANGES','PendingChanges','pending changes','Pending_Changes','OutOfSync','out of sync')) {
    Assert-Equal "'$variant' requires a deploy" $true (Get-IntersightProfileDeployState -ServerProfile (New-Profile -ConfigState $variant)).RequiresDeploy
}

Write-Host "`n=== States with nothing staged must NOT trigger a reboot ===" -ForegroundColor Cyan
foreach ($state in @('Associated','Ok','Assigned','Configuring','Activating','Not-assigned')) {
    Assert-Equal "'$state' does not require a deploy" $false (Get-IntersightProfileDeployState -ServerProfile (New-Profile -ConfigState $state)).RequiresDeploy
}

Write-Host "`n=== An unreadable state is never silently treated as 'nothing to do' ===" -ForegroundColor Cyan
$s = Get-IntersightProfileDeployState -ServerProfile (New-Profile -ConfigState '')
Assert-Equal "blank ConfigState is UNKNOWN" "UNKNOWN" $s.ConfigState
Assert-Equal "blank ConfigState is flagged as not known" $false $s.StateKnown
Assert-Equal "blank ConfigState does not itself trigger a deploy" $false $s.RequiresDeploy

$s = Get-IntersightProfileDeployState -ServerProfile (New-Profile -NoContext)
Assert-Equal "missing ConfigContext is UNKNOWN" "UNKNOWN" $s.ConfigState
Assert-Equal "missing ConfigContext is flagged as not known" $false $s.StateKnown

$s = Get-IntersightProfileDeployState -ServerProfile (New-Profile -ConfigState $null)
Assert-Equal "null ConfigState is UNKNOWN" "UNKNOWN" $s.ConfigState
Assert-Equal "null ConfigState is flagged as not known" $false $s.StateKnown

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
