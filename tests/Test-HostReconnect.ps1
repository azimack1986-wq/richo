<#
.SYNOPSIS
    Tests reconnecting a host that vCenter has dropped, using the ESXi root credential.

.DESCRIPTION
    The failure this exists for: the host reboots, comes back, and vCenter cannot re-establish its
    connection because the password it holds for the host no longer works. vCenter shows it
    Disconnected and will not recover on its own, so the run waits out its whole window for
    something that is never going to resolve itself.

    What has to be true:
      - a transient drop is fixed by vCenter's own stored credentials, without spending the root
        password on it;
      - a STALE PASSWORD is fixed by ReconnectHost_Task with an explicit credential - and never by
        removing and re-adding the host, which would take its VMs out of inventory with it;
      - a host missing from inventory is reported, not guessed at;
      - no credential means no reconnect, reported plainly rather than failing silently;
      - none of it throws, because other hosts are in flight.

    Standalone - no Pester, no PowerCLI, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-HostReconnect.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Restore-DisconnectedVMHost','Test-VMHostDisconnected','Test-VMHostNotResponding') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal { param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

function Start-Sleep { param($Seconds,$Milliseconds) }
$script:State = 'Disconnected'
$script:SetVMHostCalls = 0
$script:ReconnectSpecs = New-Object System.Collections.Generic.List[string]
$script:StoredCredsWork = $false
$script:RootCredsWork = $true
$script:HostPresent = $true

function Get-VMHost { param($Name,$Location,$ErrorAction)
    if (-not $script:HostPresent) { return $null }
    $obj = [pscustomobject]@{ Name = $Name; ConnectionState = $script:State }
    # ExtensionData.ReconnectHost_Task is the vSphere API operation the script uses.
    $ext = New-Object psobject
    $ext | Add-Member -MemberType ScriptMethod -Name ReconnectHost_Task -Value {
        param($spec,$a,$b)
        $script:ReconnectSpecs.Add("$($spec.HostName)|$($spec.UserName)|$($spec.Password)|$($spec.Force)")
        if ($script:RootCredsWork) { $script:State = 'Maintenance' }
        return 'task-1' }
    $obj | Add-Member -NotePropertyName ExtensionData -NotePropertyValue $ext -Force
    return $obj }

function Set-VMHost { param($VMHost,$State,$Confirm,$ErrorAction)
    $script:SetVMHostCalls++
    if ($script:StoredCredsWork) { $script:State = 'Connected'; return }
    throw "Cannot complete login due to an incorrect user name or password" }

# The spec type is PowerCLI's, so it is built by a helper the script owns and this replaces.
function New-VMHostConnectSpec { param($HostName,$Credential)
    return [pscustomobject]@{ HostName = $HostName; UserName = $Credential.UserName
        Password = $Credential.GetNetworkCredential().Password; Force = $true } }

$cred = [pscredential]::new('root', (ConvertTo-SecureString 'S3cret!' -AsPlainText -Force))

Write-Host "`n=== Disconnected is told apart from Not Responding ===" -ForegroundColor Cyan
# NOT INTERCHANGEABLE, and treating them as one was wrong on the case that matters most.
# NotResponding is vCenter unable to reach the host RIGHT NOW - which is exactly what a blade being
# reflashed and power-cycled looks like, and it resolves itself when the host boots. Disconnected
# is vCenter having GIVEN UP, typically because the credential it holds no longer works, and that
# never resolves on its own.
#
# Including NotResponding here started the reconnect clock on every host in the middle of its own
# firmware reboot: useless, and a way to lock the root account against a host that was never broken.
foreach ($pair in @(@('Disconnected',$true), @('NotResponding',$false), @('Connected',$false), @('Maintenance',$false))) {
    $script:State = $pair[0]
    Assert-Equal "'$($pair[0])' reports disconnected = $($pair[1])" $pair[1] (Test-VMHostDisconnected -HostName 'esx01')
}
foreach ($pair in @(@('NotResponding',$true), @('Disconnected',$false), @('Connected',$false), @('Maintenance',$false))) {
    $script:State = $pair[0]
    Assert-Equal "'$($pair[0])' reports not-responding = $($pair[1])" $pair[1] (Test-VMHostNotResponding -HostName 'esx01')
}
$script:HostPresent = $false
Assert-Equal "a host absent from inventory is not 'not responding'" $false (Test-VMHostNotResponding -HostName 'esx01')
$script:HostPresent = $true
$script:HostPresent = $false
Assert-Equal "a host absent from inventory is not 'disconnected'" $false (Test-VMHostDisconnected -HostName 'esx01')
$script:HostPresent = $true

Write-Host "`n=== A transient drop costs no root password ===" -ForegroundColor Cyan
$Global:EsxiRootCredential = $cred
$script:State = 'Disconnected'; $script:StoredCredsWork = $true
$script:SetVMHostCalls = 0; $script:ReconnectSpecs.Clear()
Assert-Equal "it reconnects" $true (Restore-DisconnectedVMHost -HostName 'esx01' -TimeoutMinutes 1 6>$null)
Assert-Equal "using vCenter's own stored credentials" 1 $script:SetVMHostCalls
Assert-Equal "and the root password is never sent" 0 $script:ReconnectSpecs.Count

Write-Host "`n=== A stale password is fixed with the root credential ===" -ForegroundColor Cyan
$script:State = 'Disconnected'; $script:StoredCredsWork = $false; $script:RootCredsWork = $true
$script:SetVMHostCalls = 0; $script:ReconnectSpecs.Clear()
Assert-Equal "it reconnects" $true (Restore-DisconnectedVMHost -HostName 'esx01' -TimeoutMinutes 1 6>$null)
Assert-Equal "the stored-credential attempt came first" 1 $script:SetVMHostCalls
Assert-Equal "then the root credential was sent once" 1 $script:ReconnectSpecs.Count
Assert-Equal "with the host, the account and Force" "esx01|root|S3cret!|True" $script:ReconnectSpecs[0]

Write-Host "`n=== A host that will not come back is reported, not thrown ===" -ForegroundColor Cyan
$script:State = 'Disconnected'; $script:StoredCredsWork = $false; $script:RootCredsWork = $false
$threw = $false; $result = $null
try { $result = Restore-DisconnectedVMHost -HostName 'esx01' -TimeoutMinutes 0 6>$null } catch { $threw = $true }
Assert-Equal "it does not throw - other hosts are in flight" $false $threw
Assert-Equal "and it reports failure honestly" $false $result

Write-Host "`n=== Missing host, and missing credential ===" -ForegroundColor Cyan
$script:HostPresent = $false
Assert-Equal "a host absent from inventory is not guessed at" $false (Restore-DisconnectedVMHost -HostName 'esx01' -TimeoutMinutes 0 6>$null)
$script:HostPresent = $true
$Global:EsxiRootCredential = $null
$script:SetVMHostCalls = 0
Assert-Equal "no credential means no reconnect" $false (Restore-DisconnectedVMHost -HostName 'esx01' -TimeoutMinutes 0 6>$null)
Assert-Equal "and nothing is attempted at all" 0 $script:SetVMHostCalls

Write-Host "`n=== The host is never removed and re-added ===" -ForegroundColor Cyan
# Remove-VMHost would take the host's VMs out of inventory with it. ReconnectHost_Task is the
# vSphere API's own operation for a stale password and leaves everything in place.
$reconnectText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Restore-DisconnectedVMHost','New-VMHostConnectSpec') } |
    ForEach-Object { $_.Extent.Text }) -join "`n"
foreach ($destructive in @('Remove-VMHost','Remove-Inventory','Add-VMHost')) {
    Assert-Equal "the reconnect never calls $destructive" $true (-not ($reconnectText -match "\b$([regex]::Escape($destructive))\b"))
}
Assert-Equal "it uses the vSphere reconnect operation" $true ($reconnectText -match 'ReconnectHost_Task')
# The password comes out of the credential only where it is handed to the API.
$scriptText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the password is never written to the run summary" $true (-not ($scriptText -match 'Details.*GetNetworkCredential'))
Assert-Equal "the credential is cleared when the cluster changes" $true ($scriptText -match '\$Global:EsxiRootCredential = \$null\s*\r?\n\s*Reset-ClusterScopedState')
Assert-Equal "the disconnect grace period is 5 minutes" $true ($scriptText -match '\$HostReconnectAfterDisconnectMinutes = 5')

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
