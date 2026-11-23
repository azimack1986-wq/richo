<#
.SYNOPSIS
    Offline tests for what Invoke-VvfVCenterUpgrade.ps1 3.0.0 decides without asking anyone.

.DESCRIPTION
    3.0.0 made the script non-interactive (for a script-runner front end) and SSH automatic.
    The decisions that replaced the prompts, and the SSH lifecycle, are pure functions; these
    tests pin them down:

      - SSH at the end of a run (Get-SshEndAction): a completed upgrade turns it off where the
        run turned it on (and everywhere with -SshFinalState Disable); a run part way through
        leaves it on for -Resume; a dry run, or a run refused before it started, puts it back.
      - Which vCenters the run turned SSH on for survives a stop: written to the state file,
        read back (a 2.x state file without the field reads as "not us"), and merged into an
        existing file without touching its stages.
      - Credentials without a prompt (Resolve-VvfCredential): per-target secret, then the
        parameter, then the shared secret / RICHO_* variables; none -> a throw naming them all.
      - Installer questions: -InstallerAnswers, else the default, else a throw naming the item.
      - The dry-run gate: a CSV given as a file and the same CSV pasted as text hash the same.

    Standalone - no Pester, no PowerCLI, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-VvfVCenterUpgrade.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vsphere/Invoke-VvfVCenterUpgrade.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors in ${scriptPath}: $($errors | ForEach-Object { $_.Message })" }
$wanted = @('Get-Prop', 'Get-PropPath', 'Get-ShortName', 'Get-SshEndAction', 'ConvertTo-SecretSlug', 'Get-CredentialNames',
    'Resolve-VvfCredential', 'Get-InstallerAnswer', 'Test-TypedConfirmation', 'ConvertTo-UpgradeStateJson',
    'ConvertFrom-UpgradeStateJson', 'Merge-StateSshFlags', 'Get-TextSha256', 'ConvertFrom-VCenterCsv',
    'ConvertTo-DryRunRecordJson', 'Test-DryRunRecord', 'Get-RoundPlan', 'Test-StopRequested')
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in $wanted } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal { param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }
function Assert-Throws { param([string]$Name, [scriptblock]$Block, [string]$Match = '')
    try { & $Block; $script:fail++; Write-Host "  FAIL  $Name (did not throw)" -ForegroundColor Red }
    catch {
        if ($Match -and $_.Exception.Message -notmatch $Match) { $script:fail++; Write-Host "  FAIL  $Name (threw '$($_.Exception.Message)')" -ForegroundColor Red }
        else { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    } }
function New-Cred { param($u, $p) [System.Management.Automation.PSCredential]::new($u, (ConvertTo-SecureString $p -AsPlainText -Force)) }

# The script refuses to run where these functions are not; every one asked for was found.
Assert-Equal 'every function under test was loaded from the script' $wanted.Count @($wanted | Where-Object { Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue }).Count

Write-Host 'SSH at the end of a run'
#                                                                 byRun  completed unfinished dryRun final
Assert-Equal 'completed, run turned it on -> off'           'Disable' (Get-SshEndAction $true  $true  $false $false 'Restore')
Assert-Equal 'completed, was on before, Restore -> left'    'Leave'   (Get-SshEndAction $false $true  $false $false 'Restore')
Assert-Equal 'completed, was on before, Disable -> off'     'Disable' (Get-SshEndAction $false $true  $false $false 'Disable')
Assert-Equal 'part way (will resume), run turned it on -> left on' 'Leave' (Get-SshEndAction $true $false $true $false 'Restore')
Assert-Equal 'part way, Disable mode -> still left on'      'Leave'   (Get-SshEndAction $true  $false $true  $false 'Disable')
Assert-Equal 'refused before the start -> put back'         'Disable' (Get-SshEndAction $true  $false $false $false 'Restore')
Assert-Equal 'refused before the start, was on -> left'     'Leave'   (Get-SshEndAction $false $false $false $false 'Disable')
Assert-Equal 'dry run, turned it on -> off'                 'Disable' (Get-SshEndAction $true  $false $false $true  'Restore')
Assert-Equal 'dry run never turns off one that was on'      'Leave'   (Get-SshEndAction $false $false $false $true  'Disable')
Assert-Equal 'dry run ignores an unfinished state'          'Disable' (Get-SshEndAction $true  $false $true  $true  'Restore')

Write-Host 'SSH flags through the state file'
$nodes = @(
    [pscustomobject]@{ Name = 'vc1.corp'; EsxiHost = 'esx1'; Vm = [pscustomobject]@{ Name = 'vc1' }; Stage = 'Done'; TargetVersion = '8.0.3.01000'; InstallMark = $null; LastError = $null; SshEnabledByScript = $true }
    [pscustomobject]@{ Name = 'vc2.corp'; EsxiHost = 'esx2'; Vm = $null; Stage = 'Pending'; TargetVersion = ''; InstallMark = $null; LastError = 'boom'; SshEnabledByScript = $false }
)
$json = ConvertTo-UpgradeStateJson 'vc1.corp' $nodes '[Repo] ISO/x-patch-FP.iso'
$st = ConvertFrom-UpgradeStateJson $json
Assert-Equal 'round trip: vc1 turned on by the run' $true $st.Nodes[0].SshEnabledByRun
Assert-Equal 'round trip: vc2 not'                  $false $st.Nodes[1].SshEnabledByRun
Assert-Equal 'round trip: stages kept'              'Done,Pending' (($st.Nodes | ForEach-Object { $_.Stage }) -join ',')
$old = '{"Script":"Invoke-VvfVCenterUpgrade","StateVersion":1,"Primary":"vc1.corp","IsoPath":"","Nodes":[{"Name":"vc1.corp","Stage":"Installed","TargetVersion":"8.0.3"}]}'
Assert-Equal 'a 2.x state file (no field) reads as not turned on by us' $false (ConvertFrom-UpgradeStateJson $old).Nodes[0].SshEnabledByRun
$merged = ConvertFrom-UpgradeStateJson (Merge-StateSshFlags $json @{ 'vc2.corp' = $true; 'vc1.corp' = $false })
Assert-Equal 'merge sets a new flag'                $true $merged.Nodes[1].SshEnabledByRun
Assert-Equal 'merge never clears a flag already set' $true $merged.Nodes[0].SshEnabledByRun
Assert-Equal 'merge leaves the stages alone'        'Done,Pending' (($merged.Nodes | ForEach-Object { $_.Stage }) -join ',')
Assert-Equal 'merge leaves the error alone'         'boom' $merged.Nodes[1].LastError
$mergedOld = ConvertFrom-UpgradeStateJson (Merge-StateSshFlags $old @{ 'vc1.corp' = $true })
Assert-Equal 'merge adds the field to a 2.x file'   $true $mergedOld.Nodes[0].SshEnabledByRun
Assert-Equal 'merge keeps a 2.x file stage'         'Installed' $mergedOld.Nodes[0].Stage

Write-Host 'Credentials without a prompt'
$given = New-Cred 'root' 'param-pw'
$env1 = @{ 'RICHO_VVF_ESXI_USER' = 'root'; 'RICHO_VVF_ESXI_PASSWORD' = 'shared-pw'; 'RICHO_VVF_ESXI_ESX02_CORP_USER' = 'root'; 'RICHO_VVF_ESXI_ESX02_CORP_PASSWORD' = 'esx02-pw' }
$getEnv = { param($n) $env1[$n] }.GetNewClosure()
$noSecret = { param($n) $null }
Assert-Equal 'names: per host first, then shared' 'vvf-esxi-esx01.corp,vvf-esxi' ((Get-CredentialNames 'Esxi' 'ESX01.corp') -join ',')
Assert-Equal 'names: SSO is shared only'          'vvf-sso' ((Get-CredentialNames 'Sso') -join ',')
Assert-Equal 'slug: as Get-RichoCredential'       'VVF_ESXI_ESX01_CORP' (ConvertTo-SecretSlug 'vvf-esxi-esx01.corp')
$r = Resolve-VvfCredential (Get-CredentialNames 'Esxi' 'esx02.corp') $given 'EsxiCredential' $noSecret $getEnv
Assert-Equal 'per-host variables outrank the parameter' 'esx02-pw' $r.Credential.GetNetworkCredential().Password
$r = Resolve-VvfCredential (Get-CredentialNames 'Esxi' 'esx01.corp') $given 'EsxiCredential' $noSecret $getEnv
Assert-Equal 'the parameter outranks the shared variables' 'param-pw' $r.Credential.GetNetworkCredential().Password
Assert-Equal 'source says it was the parameter'          '-EsxiCredential' $r.Source
$r = Resolve-VvfCredential (Get-CredentialNames 'Esxi' 'esx01.corp') $null 'EsxiCredential' $noSecret $getEnv
Assert-Equal 'no parameter -> shared variables'           'shared-pw' $r.Credential.GetNetworkCredential().Password
$secret = { param($n) if ($n -eq 'vvf-esxi-esx01.corp') { New-Cred 'root' 'vault-pw' } }
$r = Resolve-VvfCredential (Get-CredentialNames 'Esxi' 'esx01.corp') $given 'EsxiCredential' $secret $getEnv
Assert-Equal 'a per-host vault secret outranks everything' 'vault-pw' $r.Credential.GetNetworkCredential().Password
$notCred = { param($n) 'a plain string secret' }
$r = Resolve-VvfCredential (Get-CredentialNames 'Sso') $null 'SsoCredential' $notCred { param($n) @{ 'RICHO_VVF_SSO_USER' = 'administrator@vsphere.local'; 'RICHO_VVF_SSO_PASSWORD' = 'sso' }[$n] }
Assert-Equal 'a secret that is not a PSCredential is passed over' 'administrator@vsphere.local' $r.Credential.UserName
$r = Resolve-VvfCredential (Get-CredentialNames 'Sso') $given 'SsoCredential' $noSecret { param($n) $null }
Assert-Equal 'SSO: the parameter is used'                  'param-pw' $r.Credential.GetNetworkCredential().Password
Assert-Throws 'nothing anywhere -> a throw naming the parameter and the variables' { Resolve-VvfCredential (Get-CredentialNames 'VCenter' 'vc1.corp') $null 'VCenterRootCredential' $noSecret { param($n) $null } } '-VCenterRootCredential.*RICHO_VVF_VCENTER_VC1_CORP_USER.*RICHO_VVF_VCENTER_USER'
Assert-Throws 'a user without a password does not count' { Resolve-VvfCredential (Get-CredentialNames 'Sso') $null 'SsoCredential' $noSecret { param($n) if ($n -like '*_USER') { 'x' } } } 'No credential'

Write-Host 'Installer questions and the start confirmation'
Assert-Equal 'a given answer wins'            'yes'  (Get-InstallerAnswer 'a.b' 'Q?' 'no' @{ 'a.b' = 'yes' }).Answer
Assert-Equal 'else the installer default'     'no'   (Get-InstallerAnswer 'a.b' 'Q?' 'no' @{}).Answer
Assert-Equal 'the source is said'             'the installer default' (Get-InstallerAnswer 'a.b' 'Q?' 'no' @{}).Source
Assert-Throws 'no answer and no default -> a throw naming the item' { Get-InstallerAnswer 'c.d' 'Q?' $null @{} } "c\.d.*-InstallerAnswers"
Assert-Equal 'ConfirmVCenter matches, any case'   $true  (Test-TypedConfirmation ' VCenter1 ' 'vcenter1')
Assert-Equal 'ConfirmVCenter empty does not'      $false (Test-TypedConfirmation '' 'vcenter1')
Assert-Equal 'ConfirmVCenter missing does not'    $false (Test-TypedConfirmation $null 'vcenter1')
Assert-Equal 'another group''s name does not'     $false (Test-TypedConfirmation 'vcenter9' 'vcenter1')

Write-Host 'The CSV as a file or as text, and the dry-run gate'
$fileText = "VCenter,EsxiHost,VmName`r`nvc1.corp,esx1,vc1`r`nvc2.corp,esx2,`r`n"
$pasted = "VCenter,EsxiHost,VmName`nvc1.corp,esx1,vc1  `nvc2.corp,esx2,"
Assert-Equal 'CRLF file and pasted text hash the same' (Get-TextSha256 $fileText) (Get-TextSha256 $pasted)
Assert-Equal 'a real change hashes differently' $false ((Get-TextSha256 $fileText) -eq (Get-TextSha256 ($fileText -replace 'esx2', 'esx3')))
$rows = @(ConvertFrom-VCenterCsv ($pasted -split "`r?`n"))
Assert-Equal 'pasted text parses: 2 rows'      2 $rows.Count
Assert-Equal 'pasted text parses: VmName kept' 'vc1' $rows[0].VmName
$sha = Get-TextSha256 $fileText
$now = Get-Date
$rec = ConvertTo-DryRunRecordJson $sha '[Repo] ISO/x-patch-FP.iso' @('vc1.corp', 'vc2.corp') $now.AddHours(-2) '3.0.0'
Assert-Equal 'gate: matching record opens it'   $true  (Test-DryRunRecord $rec (Get-TextSha256 $pasted) '[Repo] ISO/x-patch-FP.iso' $now).Valid
Assert-Equal 'gate: another ISO keeps it shut'  $false (Test-DryRunRecord $rec $sha '[Repo] ISO/y-patch-FP.iso' $now).Valid
Assert-Equal 'gate: an edited CSV keeps it shut' $false (Test-DryRunRecord $rec (Get-TextSha256 ($fileText + '# x')) '[Repo] ISO/x-patch-FP.iso' $now).Valid
Assert-Equal 'gate: over 24 hours keeps it shut' $false (Test-DryRunRecord $rec $sha '[Repo] ISO/x-patch-FP.iso' $now.AddHours(23)).Valid
Assert-Equal 'gate: no record keeps it shut'    $false (Test-DryRunRecord '' $sha '[Repo] ISO/x-patch-FP.iso' $now).Valid

Write-Host 'Resume and stopping'
Assert-Equal 'a resumed Pending vCenter gets a fresh snapshot' $true  (Get-RoundPlan 'Pending' $true).Snapshot
Assert-Equal 'a resumed Installed vCenter goes on to the reboot' 'False,True' ("{0},{1}" -f (Get-RoundPlan 'Installed' $true).Install, (Get-RoundPlan 'Installed' $true).Reboot)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("vvf-stop-" + [guid]::NewGuid().ToString('N'))
Assert-Equal 'no STOP file -> no stop' '' (Test-StopRequested $tmp)
Set-Content -LiteralPath $tmp -Value ''
Assert-Equal 'a STOP file -> stop'     'file' (Test-StopRequested $tmp)
Remove-Item -LiteralPath $tmp -Force

Write-Host ''
Write-Host "$($script:pass) passed, $($script:fail) failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
