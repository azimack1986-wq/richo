<#
.SYNOPSIS
    Runs the real Get-UcsVlanAudit.ps1 and Remove-UcsUnusedVlan.ps1 entry points end to end against
    stub UCS PowerTool and PowerCLI modules.

.DESCRIPTION
    The other suites test functions lifted out of the scripts. This one runs the scripts as an
    operator would - module loading, credential resolution, prompts answered on stdin, report
    and manifest files on disk - and checks the two guarantees that only hold at that level:

      - the audit's candidates.json is accepted by the removal script as written; and
      - -WhatIf given to the removal SCRIPT reaches every removal, so nothing is changed.

    Stub modules named Cisco.UcsManager and VMware.VimAutomation.Core are put first on
    PSModulePath for the child processes. They serve the shared fixture domain
    (tests/UcsVlanFixture.ps1) and record every removal call to a file.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsVlanEndToEnd.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$shell = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('vlan-e2e-' + [Guid]::NewGuid().ToString('N'))
$modules = Join-Path $work 'modules'
$out = Join-Path $work 'output'
$callLog = Join-Path $work 'calls.log'
New-Item -ItemType Directory -Path $modules, $out | Out-Null
$fixture = (Join-Path $PSScriptRoot 'UcsVlanFixture.ps1').Replace("'", "''")

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}
function Assert-True {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

# ---- Stub modules ----------------------------------------------------------------------------
$common = @"
`$MasterUcsList = @('PD24000001SS101', 'PD84000001SS028', 'PD85000001SS003')
. '$fixture'
function Write-Call { param([string]`$Text) Add-Content -LiteralPath `$env:RICHO_TEST_CALLS -Value `$Text }
"@

New-Item -ItemType Directory -Path (Join-Path $modules 'Cisco.UcsManager') | Out-Null
Set-Content -Path (Join-Path $modules 'Cisco.UcsManager/Cisco.UcsManager.psm1') -Value ($common + @'

$fixtureDomain = New-UcsFixture
$script:Domain = @{}
foreach ($key in $fixtureDomain.Keys) { $script:Domain[$key] = New-Object System.Collections.Generic.List[object]; foreach ($item in @($fixtureDomain[$key])) { $script:Domain[$key].Add($item) } }

function Connect-Ucs { param($Name, $Credential) [pscustomobject]@{ Name = $Name; Ucs = $Name } }
function Disconnect-Ucs { param($Ucs) }
function Get-UcsManagedObject {
    param($ClassId, $Ucs)
    switch ($ClassId) {
        'fabricVlan' { $script:Domain.Vlan.ToArray() }
        'vnicLanConnTempl' { $script:Domain.VnicTemplate.ToArray() }
        'vnicEtherIf' { $script:Domain.EtherIf.ToArray() }
        'vnicEther' { $script:Domain.Vnic.ToArray() }
        'lsServer' { $script:Domain.ServiceProfile.ToArray() }
        'fabricPooledVlan' { $script:Domain.PooledVlan.ToArray() }
        'mgmtInbandProfile' { $script:Domain.InbandProfile.ToArray() }
        default { @() }
    }
}
function Get-UcsVnicTemplate { param($Ucs) $script:Domain.VnicTemplate.ToArray() }
function Get-UcsVnicInterface { param([Parameter(ValueFromPipeline)]$Template) process { $script:Domain.EtherIf.ToArray() | Where-Object { $_.Dn -like "$($Template.Dn)/if-*" } } }
function Remove-UcsVnicInterface {
    param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force)
    process {
        Write-Call "Remove-UcsVnicInterface $($InputObject.Dn)"
        [void]$script:Domain.EtherIf.Remove($InputObject)
        # An updating template pushes the change to its bound service profile vNICs.
        $templateDn = $InputObject.Dn.Substring(0, $InputObject.Dn.LastIndexOf('/'))
        $bound = @($script:Domain.Vnic | Where-Object { $_.OperNwTemplName -eq $templateDn } | ForEach-Object { "$($_.Dn)/if-$($InputObject.Name)" })
        foreach ($copy in @($script:Domain.EtherIf | Where-Object { $bound -contains $_.Dn })) { [void]$script:Domain.EtherIf.Remove($copy) }
    }
}
function Get-UcsVlan { param($Ucs) $script:Domain.Vlan.ToArray() }
function Remove-UcsVlan {
    param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force)
    process {
        Write-Call "Remove-UcsVlan $($InputObject.Dn)"
        [void]$script:Domain.Vlan.Remove($InputObject)
    }
}
'@)

New-Item -ItemType Directory -Path (Join-Path $modules 'VMware.VimAutomation.Core') | Out-Null
Set-Content -Path (Join-Path $modules 'VMware.VimAutomation.Core/VMware.VimAutomation.Core.psm1') -Value ($common + @'

$script:VCenter = New-VCenterFixture
function Connect-VIServer { param($Server, $Credential) [pscustomobject]@{ Name = $Server } }
function Disconnect-VIServer { param($Server, [switch]$Confirm) }
function Get-View {
    param($Server, $ViewType, $Id, $Property)
    if ($ViewType) {
        switch ($ViewType) {
            'ComputeResource' { $script:VCenter.ComputeView }
            'HostSystem' { $script:VCenter.HostView }
            'VmwareDistributedVirtualSwitch' { $script:VCenter.DvsView }
            'DistributedVirtualPortgroup' { $script:VCenter.PortgroupView }
            'VirtualMachine' { $script:VCenter.VmView }
        }
        return
    }
    foreach ($reference in @($Id)) {
        $hostKey = 'HostSystem-' + ($reference.Value -replace '^ns-', '')
        $view = [pscustomobject]@{ MoRef = $reference; HostKey = $hostKey }
        $hint = $script:VCenter.DiscoveryHint[$hostKey]
        $view | Add-Member -MemberType ScriptMethod -Name QueryNetworkHint -Value { param($Device) if ($hint.Error) { throw $hint.Error }; $hint.Hints }.GetNewClosure()
        $view
    }
}
'@)

function Invoke-Child {
    param([string]$Command, [string[]]$Answers = @())
    $env:PSModulePath = $modules + [IO.Path]::PathSeparator + $env:PSModulePath
    $env:RICHO_TEST_CALLS = $callLog
    $env:RICHO_UCSM_USER = 'admin'; $env:RICHO_UCSM_PASSWORD = 'x'
    $env:RICHO_VCENTER_USER = 'admin'; $env:RICHO_VCENTER_PASSWORD = 'x'
    try {
        $output = ($Answers -join "`n") | & $shell -NoProfile -Command $Command 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }
    finally {
        $env:PSModulePath = ($env:PSModulePath -split [regex]::Escape([IO.Path]::PathSeparator) | Where-Object { $_ -ne $modules }) -join [IO.Path]::PathSeparator
        foreach ($name in 'RICHO_TEST_CALLS', 'RICHO_UCSM_USER', 'RICHO_UCSM_PASSWORD', 'RICHO_VCENTER_USER', 'RICHO_VCENTER_PASSWORD') { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    }
}
function Get-Calls { if (Test-Path $callLog) { @(Get-Content $callLog) } else { @() } }

# ---- Audit -----------------------------------------------------------------------------------
Write-Host "`n=== Audit entry point ===" -ForegroundColor Cyan
$auditScript = (Join-Path $repoRoot 'scripts/ucs/Get-UcsVlanAudit.ps1').Replace("'", "''")
# Answers: protected side; scope confirmed; no other physical VLANs; native confirmed; no special VLANs.
$run = Invoke-Child -Command "& '$auditScript' -UcsDomain PD24000001SS101 -VCenter vc1.test -ReportFormat CSV -OutputDirectory '$out'" -Answers @('1', '1', '2', '1', '2')
Assert-Equal 'audit exits cleanly' 0 $run.ExitCode
if ($run.ExitCode -ne 0) { Write-Host $run.Output }
$auditFolder = @(Get-ChildItem $out -Directory -Filter 'PD24000001SS101_VLAN-Audit_*')
Assert-Equal 'one audit folder written' 1 $auditFolder.Count
$manifestFile = Join-Path $auditFolder[0].FullName 'candidates.json'
Assert-True 'candidates.json written' (Test-Path $manifestFile)
$manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
Assert-Equal 'audit complete' 'COMPLETE' $manifest.Overall
Assert-Equal 'VLAN 200 is the candidate' '200' ((@($manifest.Candidates) | ForEach-Object { $_.VlanId }) -join ',')
Assert-Equal 'every report sheet written as CSV' 18 @(Get-ChildItem $auditFolder[0].FullName -Filter '*.csv').Count
Assert-True 'operator answers were logged' ($run.Output -like '*SCOPE CONFIRMATION: 1. CONFIRMED*')
Assert-Equal 'the audit removed nothing' 0 @(Get-Calls).Count

# ---- Removal: dry run ------------------------------------------------------------------------
Write-Host "`n=== Removal entry point, -WhatIf ===" -ForegroundColor Cyan
$removalScript = (Join-Path $repoRoot 'scripts/ucs/Remove-UcsUnusedVlan.ps1').Replace("'", "''")
$removalOut = Join-Path $work 'removal'
$run = Invoke-Child -Command "& '$removalScript' -ManifestPath '$($auditFolder[0].FullName)' -VlanId 200 -OutputDirectory '$removalOut' -WhatIf"
Assert-Equal 'dry run exits cleanly' 0 $run.ExitCode
if ($run.ExitCode -ne 0) { Write-Host $run.Output }
Assert-Equal '-WhatIf on the script removes nothing' 0 @(Get-Calls).Count
Assert-Equal 'every removal is announced as What if' 3 ([regex]::Matches($run.Output, 'What if:')).Count
$dryFolder = @(Get-ChildItem $removalOut -Directory)
Assert-True 'the dry run wrote its plan' ($dryFolder.Count -eq 1 -and (Test-Path (Join-Path $dryFolder[0].FullName 'plan.csv')))

# ---- Removal: for real -----------------------------------------------------------------------
Write-Host "`n=== Removal entry point, confirmed ===" -ForegroundColor Cyan
$run = Invoke-Child -Command "& '$removalScript' -ManifestPath '$manifestFile' -VlanId 200 -OutputDirectory '$removalOut' -PropagationTimeoutSeconds 20 -Confirm:`$false"
Assert-Equal 'removal exits cleanly' 0 $run.ExitCode
if ($run.ExitCode -ne 0) { Write-Host $run.Output }
$calls = @(Get-Calls)
Assert-Equal 'two template removals then the LAN Cloud delete' 'Remove-UcsVnicInterface,Remove-UcsVnicInterface,Remove-UcsVlan' (($calls | ForEach-Object { ($_ -split ' ')[0] }) -join ',')
Assert-Equal 'the LAN Cloud VLAN removed is VL200' 'Remove-UcsVlan fabric/lan/net-VL200' $calls[-1]
Assert-True 'the run reports what it removed' ($run.Output -like '*Removed: 3. Blocked or failed: 0.*')

# ---- Removal: refusal ------------------------------------------------------------------------
Write-Host "`n=== Removal entry point, refusal ===" -ForegroundColor Cyan
Remove-Item $callLog -ErrorAction SilentlyContinue
$run = Invoke-Child -Command "& '$removalScript' -ManifestPath '$manifestFile' -VlanId 100 -OutputDirectory '$removalOut' -Confirm:`$false"
Assert-True 'asking for a protected VLAN fails' ($run.ExitCode -ne 0)
Assert-True '...saying why' ($run.Output -like '*VLAN 100 is not a cleanup candidate*')
Assert-Equal '...having removed nothing' 0 @(Get-Calls).Count

Remove-Item $work -Recurse -Force
Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
