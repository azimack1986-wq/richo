<#
.SYNOPSIS
    Runs Invoke-VvfVCenterUpgrade.ps1 end to end against simulated ESXi hosts and vCenter
    appliances, and checks what it leaves behind -- above all SSH on every vCenter.

.DESCRIPTION
    PowerCLI, Posh-SSH and the appliance REST API are replaced by stubs over a small in-memory
    world (two vCenters in one SSO domain, each on its own ESXi host). The script itself runs
    unmodified, in this process, so its main body -- the order of the steps, the gates and the
    SSH lifecycle -- is what is tested:

      A. Dry run: SSH turned on where it was off, every check run (none skipped), turned off
         again at the end; a dry-run record written; nothing powered off or mounted.
      B. Real run: refused without -ConfirmVCenter, and refused without a passing dry run.
      C. Full upgrade: both vCenters upgraded; SSH found OFF after a reboot is turned on again;
         at the end SSH is off where the run turned it on and left on where it was on before.
      D. -SshFinalState Disable: SSH off on every vCenter at the end.
      E. Failure in round 2: exit 1, SSH left ON where the run turned it on, recorded in the
         state file; -Resume completes the upgrade and turns that SSH off.
      F. A real run refused at the pre-upgrade checks puts SSH back as it found it.

    What the stubs cannot show: real appliance timing, real API error shapes, real sshd
    behaviour. This is a check of the script's logic, not of vCenter.

    Standalone - no Pester, no PowerCLI, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-VvfVCenterUpgradeSimulation.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vsphere/Invoke-VvfVCenterUpgrade.ps1'
$script:pass = 0; $script:fail = 0
function Assert-Equal { param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

$Target = '8.0.3.01000'
$IsoFull = '[SoftwareRepo] ISO/VMware-vCenter-Server-Appliance-8.0.3.01000-24305161-patch-FP.iso'
$Csv = "VCenter,EsxiHost`nvcenter1.corp.local,esx01.corp.local`nvcenter2.corp.local,esx02.corp.local"

function New-World {
    param([bool]$Vc1Ssh = $false, [bool]$Vc2Ssh = $true)
    $global:W = @{
        Vc = [ordered]@{
            'vcenter1.corp.local' = @{ Ssh = $Vc1Ssh; Version = '8.0.3.00500'; Uptime = 5000; Host = 'esx01.corp.local'; Vm = 'vcenter1' }
            'vcenter2.corp.local' = @{ Ssh = $Vc2Ssh; Version = '8.0.3.00500'; Uptime = 5000; Host = 'esx02.corp.local'; Vm = 'vcenter2' }
        }
        Vm = @{
            'vm-1' = @{ Id = 'vm-1'; Name = 'vcenter1'; Host = 'esx01.corp.local'; Vc = 'vcenter1.corp.local'; Power = 'PoweredOn'; Snaps = [System.Collections.Generic.List[string]]::new(); Iso = ''; Connected = $false; StartConnected = $false }
            'vm-2' = @{ Id = 'vm-2'; Name = 'vcenter2'; Host = 'esx02.corp.local'; Vc = 'vcenter2.corp.local'; Power = 'PoweredOn'; Snaps = [System.Collections.Generic.List[string]]::new(); Iso = ''; Connected = $false; StartConnected = $false }
        }
        SshPuts = [System.Collections.Generic.List[string]]::new()
        FailInstallOn = ''          # a vCenter whose stage-and-install is refused
        SshOffAfterRebootOn = ''    # a vCenter whose SSH setting is lost on reboot
        RedHealthOn = ''            # a vCenter whose system health reads red
        PowerOffs = 0
    }
}
function Get-WVm { param([string]$VcName) foreach ($v in $global:W.Vm.Values) { if ($v.Vc -eq $VcName) { return $v } } }

# ------------------------------------------------------------------ PowerCLI stubs --
function global:Connect-VIServer { [CmdletBinding()] param($Server, $Credential) [pscustomobject]@{ Name = $Server; Version = '8.0.3'; Build = '1' } }
function global:Disconnect-VIServer { [CmdletBinding()] param($Server, $Confirm) }
function global:Set-PowerCLIConfiguration { [CmdletBinding()] param($Scope, $InvalidCertificateAction, $Confirm) }
function global:ConvertTo-StubVm { param($v) [pscustomobject]@{ Id = $v.Id; Name = $v.Name; PowerState = $v.Power; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ ToolsRunningStatus = 'guestToolsRunning'; HostName = ''; IpAddress = '' } } } }
function global:Get-VM { [CmdletBinding()] param($Server, $Id)
    if ($Id) { return (ConvertTo-StubVm $global:W.Vm[$Id]) }
    @($global:W.Vm.Values | Where-Object { $_.Host -eq $Server.Name } | ForEach-Object { ConvertTo-StubVm $_ }) }
function global:Shutdown-VMGuest { [CmdletBinding()] param($VM, $Confirm) $global:W.Vm[$VM.Id].Power = 'PoweredOff' }
function global:Stop-VM { [CmdletBinding()] param($VM, $Confirm) $global:W.Vm[$VM.Id].Power = 'PoweredOff'; $global:W.PowerOffs++ }
function global:Start-VM { [CmdletBinding()] param($VM, $Confirm) $v = $global:W.Vm[$VM.Id]; $v.Power = 'PoweredOn'; $global:W.Vc[$v.Vc].Uptime = 0 }
function global:New-Snapshot { [CmdletBinding()] param($VM, $Name, $Description, $Memory, $Quiesce, $Confirm) $global:W.Vm[$VM.Id].Snaps.Add($Name) }
function global:Get-Snapshot { [CmdletBinding()] param($VM) $id = $VM.Id; @($global:W.Vm[$id].Snaps | ForEach-Object { [pscustomobject]@{ Name = $_; VmId = $id } }) }
function global:Remove-Snapshot { [CmdletBinding()] param($Snapshot, $Confirm) $null = $global:W.Vm[$Snapshot.VmId].Snaps.Remove($Snapshot.Name) }
function global:ConvertTo-StubDrive { param($v)
    [pscustomobject]@{ VmId = $v.Id; IsoPath = $v.Iso; ConnectionState = [pscustomobject]@{ Connected = $v.Connected; StartConnected = $v.StartConnected }
        ExtensionData = [pscustomobject]@{ Connectable = [pscustomobject]@{ Connected = $v.Connected; StartConnected = $v.StartConnected } } } }
function global:Get-CDDrive { [CmdletBinding()] param($VM) ConvertTo-StubDrive $global:W.Vm[$VM.Id] }
function global:Set-CDDrive { [CmdletBinding()] param($CD, $IsoPath, [switch]$NoMedia, $StartConnected, $Connected, $Confirm)
    $v = $global:W.Vm[$CD.VmId]
    if ($PSBoundParameters.ContainsKey('IsoPath')) { $v.Iso = $IsoPath }
    if ($NoMedia) { $v.Iso = ''; $v.Connected = $false }
    if ($PSBoundParameters.ContainsKey('StartConnected')) { $v.StartConnected = [bool]$StartConnected }
    if ($PSBoundParameters.ContainsKey('Connected')) { $v.Connected = [bool]$Connected }
    ConvertTo-StubDrive $v }
function global:Get-Datastore { [CmdletBinding()] param($Server, $Name) [pscustomobject]@{ Name = $Name } }
function global:New-PSDrive { [CmdletBinding()] param($Name, $PSProvider, $Root, $Location) }
function global:Remove-PSDrive { [CmdletBinding()] param($Name, [switch]$Force) }
function global:Test-Path { [CmdletBinding()] param([Parameter(Position = 0)]$Path, $LiteralPath, $PathType)
    $p = [string]$(if ($LiteralPath) { $LiteralPath } else { $Path })
    if ($p -like 'vvfiso*') { return $true }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
function global:Get-VMQuestion { [CmdletBinding()] param($VM) @() }
function global:Get-View { [CmdletBinding()] param($Id, $Server)
    if ($Id -eq 'task-1') { return [pscustomobject]@{ Info = [pscustomobject]@{ State = 'success'; Error = $null } } }
    $o = [pscustomobject]@{ VmId = $Id }
    $o | Add-Member -MemberType ScriptMethod -Name ReconfigVM_Task -Value { param($spec) $global:W.Vm[$this.VmId].Connected = $false; $global:W.Vm[$this.VmId].StartConnected = $false; 'task-1' }
    $o }

# ------------------------------------------------------------------ Posh-SSH stubs --
function global:New-SSHSession { [CmdletBinding()] param($ComputerName, $Credential, [switch]$AcceptKey, $ConnectionTimeout)
    $vc = $global:W.Vc[$ComputerName]
    if (-not $vc.Ssh -or (Get-WVm $ComputerName).Power -ne 'PoweredOn') { throw 'No connection could be made because the target machine actively refused it' }
    [pscustomobject]@{ Host = $ComputerName; Connected = $true } }
function global:Remove-SSHSession { [CmdletBinding()] param($SSHSession) }
function global:Invoke-SSHCommand { [CmdletBinding()] param($SSHSession, $Command, $TimeOut)
    $h = $SSHSession.Host
    if (-not $global:W.Vc[$h].Ssh) { throw 'An established connection was aborted by the server.' }
    $o = switch -Regex ($Command) {
        'VVF_PROBE'          { @('VVF_PROBE_42') }
        '##SC'               { @('##SC', 'Running:', ' vmware-vmon lwsmd vmafdd vmdird', '##VMON', '##SVC vpxd', 'Starttype: AUTOMATIC', 'RunState: STARTED', 'HealthState: HEALTHY') }
        'vcha'               { @() }
        '^df '               { @('Filesystem 1024-blocks Used Available Capacity Mounted on', '/dev/sda3 100 10 90 10% /') }
        'chage'              { @('Password expires : never') }
        'vecs-cli'           { @('notAfter=Jan  1 00:00:00 2031 GMT') }
        'showservers'        { @($global:W.Vc.Keys | ForEach-Object { "cn=$_,cn=Servers,cn=Default-First-Site,cn=Sites,cn=Configuration,dc=vsphere,dc=local" }) }
        'showpartnerstatus'  { @(('Partner: ' + @($global:W.Vc.Keys | Where-Object { $_ -ne $h })[0]), 'Host available:   Yes', 'Status available: Yes', 'Partner is 0 changes behind.') }
        'END\|'              { @('EJECTED|/dev/sr0', 'END|') }
        default              { @() }
    }
    [pscustomobject]@{ Output = [string[]]@($o); ExitStatus = 0; Error = '' } }

# ------------------------------------------------------------ appliance API stub --
function global:Invoke-RestMethod { [CmdletBinding()] param($Method, $Uri, $Headers, $Body, $TimeoutSec, $ContentType, [switch]$SkipCertificateCheck)
    if ($Uri -notmatch '^https://([^/:]+)(:\d+)?/api(/[^?]*)(\?(.*))?$') { throw "stub: bad uri $Uri" }
    $name = $Matches[1]; $path = $Matches[3]; $query = [string]$Matches[5]
    $vc = $global:W.Vc[$name]
    if ((Get-WVm $name).Power -ne 'PoweredOn') { throw 'No connection could be made because the target machine actively refused it.' }
    switch -Regex ("$Method $path") {
        '^Post /session$'                   { return 'token' }
        '^Get /appliance/access/ssh$'       { return $vc.Ssh }
        '^Put /appliance/access/ssh$'       { $en = [bool](($Body | ConvertFrom-Json).enabled); $vc.Ssh = $en; $global:W.SshPuts.Add("$name=$en"); return $null }
        '^Get /appliance/system/version$'   { return [pscustomobject]@{ version = $vc.Version; build = '1' } }
        '^Get /appliance/system/uptime$'    { return [double]$vc.Uptime }
        '^Get /appliance/health/(.+)$'      { if ($Matches[1] -eq 'system' -and $global:W.RedHealthOn -eq $name) { return 'red' } return 'green' }
        '^Get /appliance/update$'           { return [pscustomobject]@{ state = 'UP_TO_DATE'; version = $vc.Version } }
        '^Get /appliance/update/pending$'   { if ((Get-WVm $name).Connected -and (Get-WVm $name).Iso) { return @([pscustomobject]@{ version = $Target; name = 'patch' }) } throw 'status code does not indicate success: 404' }
        '^Post /appliance/update/pending/'  {
            if ($query -match 'precheck') { return [pscustomobject]@{ issues = [pscustomobject]@{ errors = @(); warnings = @(); info = @() }; questions = @() } }
            if ($query -match 'validate') { return [pscustomobject]@{ errors = @(); warnings = @(); info = @() } }
            if ($query -match 'stage-and-install') {
                if ($global:W.FailInstallOn -eq $name) { throw 'Response status code does not indicate success: 400 (Bad Request).' }
                $vc.Version = $Target; return $null
            }
        }
        '^Post /appliance/shutdown$'        { $vc.Uptime = 0; if ($global:W.SshOffAfterRebootOn -eq $name) { $vc.Ssh = $false }; return $null }
    }
    throw "stub: no route for $Method $path" }

function global:Start-Sleep { [CmdletBinding()] param($Seconds, $Milliseconds) }

# ---------------------------------------------------------------- running it --
$env:RICHO_VVF_ESXI_USER = 'root'; $env:RICHO_VVF_ESXI_PASSWORD = 'esx'
$env:RICHO_VVF_VCENTER_USER = 'root'; $env:RICHO_VVF_VCENTER_PASSWORD = 'vc'
$env:RICHO_VVF_SSO_USER = 'administrator@vsphere.local'; $env:RICHO_VVF_SSO_PASSWORD = 'sso'
$LogFolder = Join-Path ([IO.Path]::GetTempPath()) ('vvf-sim-' + [guid]::NewGuid().ToString('N'))

function Invoke-Run { param([hashtable]$Extra)
    $a = @{ VCenterCsvText = $Csv; IsoPath = $IsoFull; LogFolder = $LogFolder; SshClient = 'PoshSSH' }
    foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
    $out = & $scriptPath @a *>&1
    $global:LastOut = ($out | ForEach-Object { "$_" }) -join "`n"
    $res = @($out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Script'] })
    if ($env:VVF_SIM_VERBOSE) { $global:LastOut }
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Result = $(if ($res.Count) { $res[-1] } else { $null }) } }
function Get-SshState { (@($global:W.Vc.Keys | ForEach-Object { "$((($_ -split '\.')[0]))=$($global:W.Vc[$_].Ssh)" }) -join ',') }

Write-Host 'A. Dry run'
New-World -Vc1Ssh $false -Vc2Ssh $true
$r = Invoke-Run @{ DryRun = $true }
Assert-Equal 'dry run passes'                         0 $r.Exit
Assert-Equal 'result object says so'                  'DryRunPassed' $r.Result.Result
Assert-Equal 'SSH back as found (vc1 off, vc2 on)'    'vcenter1=False,vcenter2=True' (Get-SshState)
Assert-Equal 'SSH was turned on then off on vc1 only' 'vcenter1.corp.local=True,vcenter1.corp.local=False' ($global:W.SshPuts -join ',')
Assert-Equal 'no check skipped for SSH'               $false ($global:LastOut -match 'Checks skipped|SSH is off')
Assert-Equal 'nothing mounted'                        '' ($global:W.Vm['vm-1'].Iso + $global:W.Vm['vm-2'].Iso)
Assert-Equal 'nothing powered off or snapshotted'     0 ($global:W.Vm['vm-1'].Snaps.Count + $global:W.Vm['vm-2'].Snaps.Count)
Assert-Equal 'dry-run record written'                 $true (Test-Path -LiteralPath (Join-Path $LogFolder 'dryrun-vcenter1.json'))

Write-Host 'B. Real run gates'
$r = Invoke-Run @{}
Assert-Equal 'no -ConfirmVCenter -> refused'          1 $r.Exit
Assert-Equal '... and SSH untouched (only the dry run''s two changes)' 2 $global:W.SshPuts.Count
$r = Invoke-Run @{ ConfirmVCenter = 'vcenter1'; IsoPath = '[SoftwareRepo] ISO/other-patch-FP.iso' }
Assert-Equal 'another ISO than the dry run -> refused' 1 $r.Exit
Assert-Equal '... says it is locked'                  $true ($global:LastOut -match 'The real run is locked')
Assert-Equal '... SSH untouched'                      2 $global:W.SshPuts.Count

Write-Host 'C. Full upgrade, SSH lost on a reboot'
$global:W.SshPuts.Clear()
$global:W.SshOffAfterRebootOn = 'vcenter2.corp.local'
$r = Invoke-Run @{ ConfirmVCenter = 'vcenter1' }
Assert-Equal 'upgrade completes'                      0 $r.Exit
Assert-Equal 'result Upgraded'                        'Upgraded' $r.Result.Result
Assert-Equal 'both on the target version'             "$Target,$Target" (($global:W.Vc.Values | ForEach-Object { $_.Version }) -join ',')
Assert-Equal 'SSH lost on reboot was turned on again' $true ($global:LastOut -match 'vcenter2.corp.local: SSH was off after the power cycle')
Assert-Equal 'end: SSH off on both (vc1 was off; vc2 re-enabled by the run)' 'vcenter1=False,vcenter2=False' (Get-SshState)
Assert-Equal 'the ISO is off both'                    '' ($global:W.Vm['vm-1'].Iso + $global:W.Vm['vm-2'].Iso)
Assert-Equal 'SSH turned off only after the ISO came off' $true ($global:LastOut.IndexOf('ISO unmounted') -lt $global:LastOut.IndexOf('Turning SSH off'))
Assert-Equal 'snapshots kept (2 rounds x 2 vCenters)' 4 ($global:W.Vm['vm-1'].Snaps.Count + $global:W.Vm['vm-2'].Snaps.Count)
Assert-Equal 'no state file left'                     $false (Test-Path -LiteralPath (Join-Path $LogFolder 'upgrade-state-vcenter1.json'))
Assert-Equal 'summary has both rows'                  2 @($r.Result.Nodes).Count
Assert-Equal 'no hard power-off'                      0 $global:W.PowerOffs

Write-Host 'C2. Full upgrade, SSH on before the run stays on (Restore)'
New-World -Vc1Ssh $false -Vc2Ssh $true
$null = Invoke-Run @{ DryRun = $true }
$r = Invoke-Run @{ ConfirmVCenter = 'vcenter1' }
Assert-Equal 'upgrade completes'                      0 $r.Exit
Assert-Equal 'end: vc1 off (run turned it on), vc2 on (was on)' 'vcenter1=False,vcenter2=True' (Get-SshState)

Write-Host 'D. -SshFinalState Disable'
New-World -Vc1Ssh $true -Vc2Ssh $true
$null = Invoke-Run @{ DryRun = $true }
Assert-Equal 'dry run leaves SSH that was on, on'     'vcenter1=True,vcenter2=True' (Get-SshState)
$r = Invoke-Run @{ ConfirmVCenter = 'vcenter1'; SshFinalState = 'Disable'; RemoveSnapshots = $true }
Assert-Equal 'upgrade completes'                      0 $r.Exit
Assert-Equal 'end: SSH off on every vCenter'          'vcenter1=False,vcenter2=False' (Get-SshState)
Assert-Equal '-RemoveSnapshots removed them'          0 ($global:W.Vm['vm-1'].Snaps.Count + $global:W.Vm['vm-2'].Snaps.Count)

Write-Host 'E. Failure in round 2, then -Resume'
New-World -Vc1Ssh $false -Vc2Ssh $false
$null = Invoke-Run @{ DryRun = $true }
$global:W.FailInstallOn = 'vcenter2.corp.local'
$r = Invoke-Run @{ ConfirmVCenter = 'vcenter1' }
Assert-Equal 'failure -> exit 1'                      1 $r.Exit
Assert-Equal 'result Failed'                          'Failed' $r.Result.Result
Assert-Equal 'vc1 upgraded, vc2 not'                  "$Target,8.0.3.00500" (($global:W.Vc.Values | ForEach-Object { $_.Version }) -join ',')
Assert-Equal 'SSH left ON on both for the resume'     'vcenter1=True,vcenter2=True' (Get-SshState)
$statePath = Join-Path $LogFolder 'upgrade-state-vcenter1.json'
$st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
Assert-Equal 'state records the run turned SSH on, both' 'True,True' (($st.Nodes | ForEach-Object { $_.SshEnabledByRun }) -join ',')
Assert-Equal 'state: vc1 Done, vc2 Pending'           'Done,Pending' (($st.Nodes | ForEach-Object { $_.Stage }) -join ',')
Assert-Equal 'says SSH is left on'                    $true ($global:LastOut -match 'SSH is left ON on')
Assert-Equal 'says how to carry on'                   $true ($global:LastOut -match 'run again with -Resume')
$r = Invoke-Run @{ ConfirmVCenter = 'vcenter1' }
Assert-Equal 'a run without -Resume or -StartFresh is refused' 1 $r.Exit
Assert-Equal '... and leaves the state file'          $true (Test-Path -LiteralPath $statePath)
Assert-Equal '... and SSH as it was'                  'vcenter1=True,vcenter2=True' (Get-SshState)
$global:W.FailInstallOn = ''
$r = Invoke-Run @{ ConfirmVCenter = 'vcenter1'; Resume = $true }
Assert-Equal 'resume completes'                       0 $r.Exit
Assert-Equal 'both on the target'                     "$Target,$Target" (($global:W.Vc.Values | ForEach-Object { $_.Version }) -join ',')
Assert-Equal 'end: SSH off on both (the stopped run had turned it on)' 'vcenter1=False,vcenter2=False' (Get-SshState)
Assert-Equal 'state file gone'                        $false (Test-Path -LiteralPath $statePath)

Write-Host 'F. Refused at the pre-upgrade checks'
New-World -Vc1Ssh $false -Vc2Ssh $true
$null = Invoke-Run @{ DryRun = $true }
$global:W.RedHealthOn = 'vcenter2.corp.local'
$r = Invoke-Run @{ ConfirmVCenter = 'vcenter1' }
Assert-Equal 'red health -> refused'                  1 $r.Exit
Assert-Equal 'says -ProceedOverPreCheckErrors'        $true ($global:LastOut -match 'ProceedOverPreCheckErrors')
Assert-Equal 'SSH put back as found'                  'vcenter1=False,vcenter2=True' (Get-SshState)
Assert-Equal 'nothing powered off'                    0 ($global:W.Vm['vm-1'].Snaps.Count + $global:W.Vm['vm-2'].Snaps.Count)
Assert-Equal 'no state file'                          $false (Test-Path -LiteralPath (Join-Path $LogFolder 'upgrade-state-vcenter1.json'))

Remove-Item -LiteralPath $LogFolder -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "$($script:pass) passed, $($script:fail) failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
