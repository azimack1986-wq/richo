<#
.SYNOPSIS
    Tests the polling logic of scripts/mecm/Wait-OsdNetworkConnected.ps1 with simulated network states.

.DESCRIPTION
    The real state reader needs Windows networking, so Wait-NetworkConnected is lifted out of the
    script and driven by a fake reader. The properties checked:

      - connected straight away returns once it has stayed connected for StableSeconds;
      - a network that is connected at boot and then drops (the pattern seen in failed builds)
        does not count as settled until it has been connected again for StableSeconds;
      - a network that never connects returns Connected = $false at the timeout, not before.

    Standalone - no Pester, no network.

.EXAMPLE
    pwsh -File ./tests/Test-WaitOsdNetworkConnected.ps1
#>
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/mecm/Wait-OsdNetworkConnected.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors in $scriptPath" }
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Write-StepLog', 'Wait-NetworkConnected') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red; if ($Detail) { Write-Host "          $Detail" -ForegroundColor Red } }
}
function New-FakeReader {
    # Returns a reader that plays back Sequence, repeating its last value. The state lives in a
    # hashtable captured by the closure, so each call advances it.
    param([bool[]]$Sequence)
    $fake = @{ Seq = $Sequence; Idx = 0 }
    { $v = $fake.Seq[[Math]::Min($fake.Idx, $fake.Seq.Count - 1)]; $fake.Idx++; [pscustomobject]@{ Connected = $v; Source = 'fake'; Profiles = @() } }.GetNewClosure()
}

Write-Host "`n=== Wait-OsdNetworkConnected.ps1 ===" -ForegroundColor Cyan

$reader = New-FakeReader @($true)
$out = @(Wait-NetworkConnected -GetState $reader -TimeoutSeconds 30 -PollSeconds 1 -StableSeconds 0)
$r = $out[-1]
Assert-That 'connected straight away returns at once' ($r.Connected -and $r.Seconds -le 1) "$($r | Out-String)"

$reader = New-FakeReader @($true, $false, $false, $true, $true, $true, $true)
$out = @(Wait-NetworkConnected -GetState $reader -TimeoutSeconds 30 -PollSeconds 1 -StableSeconds 2)
$r = $out[-1]
$lines = @($out | Where-Object { $_ -is [string] })
Assert-That 'connect, drop, reconnect: settles only after being stable again' ($r.Connected -and $r.Changes -eq 2 -and $r.Seconds -ge 4) "$($r | Out-String)"
Assert-That 'each state change is logged with its time' (@($lines | Where-Object { $_ -match 'Network NOT CONNECTED' }).Count -eq 1 -and @($lines | Where-Object { $_ -match 'Network CONNECTED' }).Count -eq 2) ($lines -join ' | ')

$reader = New-FakeReader @($false)
$out = @(Wait-NetworkConnected -GetState $reader -TimeoutSeconds 3 -PollSeconds 1 -StableSeconds 0)
$r = $out[-1]
Assert-That 'never connected: returns not connected at the timeout' ((-not $r.Connected) -and $r.Seconds -ge 3) "$($r | Out-String)"

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
