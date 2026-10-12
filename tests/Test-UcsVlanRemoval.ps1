<#
.SYNOPSIS
    Tests Remove-UcsUnusedVlan.ps1: what it refuses, what it re-checks live, the order it works in,
    and that -WhatIf changes nothing.

.DESCRIPTION
    The manifest is produced by the real audit code (Get-UcsVlanAudit.ps1) from the shared fixture
    domain, so this also tests the contract between the two scripts. The removal then runs against
    a stateful fake UCS Manager: the Remove-* stubs change it, updating-template changes reach
    service profiles after a configurable number of reads, and pending acknowledgements and live
    drift can be injected.

    Also checks that the helper functions the two scripts share are byte-for-byte identical, so
    they cannot drift into resolving a VLAN name differently.

    Standalone - no Pester, no UCS PowerTool, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsVlanRemoval.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$auditPath = Join-Path $repoRoot 'scripts/ucs/Get-UcsVlanAudit.ps1'
$removalPath = Join-Path $repoRoot 'scripts/ucs/Remove-UcsUnusedVlan.ps1'
function Get-FunctionAst {
    param([string]$Path)
    $errors = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "parse errors in $Path" }
    @{ Ast = $ast; Functions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) }
}
$audit = Get-FunctionAst $auditPath
$removal = Get-FunctionAst $removalPath

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
function Assert-Throws {
    param([string]$Name, [scriptblock]$Script, [string]$Like = '*')
    try { & $Script; $script:fail++; Write-Host "  FAIL  $Name (did not throw)" -ForegroundColor Red }
    catch {
        if ($_.Exception.Message -like $Like) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
        else { $script:fail++; Write-Host "  FAIL  $Name (threw '$($_.Exception.Message)')" -ForegroundColor Red }
    }
}

# ---- Shared helpers must be identical ------------------------------------------------------
Write-Host "`n=== Shared helpers ===" -ForegroundColor Cyan
$shared = @('Get-PropertyValue', 'Get-PropertyList', 'Test-UcsYes', 'ConvertTo-MacAddress', 'ConvertTo-SortedIntArray', 'Format-IdList',
    'Connect-UcsWithTimeout', 'Get-UcsFabricList', 'Resolve-UcsVlanReference', 'ConvertTo-UcsVlanInventory', 'Get-UcsVlanInventory')
foreach ($name in $shared) {
    $a = @($audit.Functions | Where-Object { $_.Name -eq $name })
    $r = @($removal.Functions | Where-Object { $_.Name -eq $name })
    Assert-True "$name is identical in the audit and removal scripts" ($a.Count -eq 1 -and $r.Count -eq 1 -and $a[0].Extent.Text -ceq $r[0].Extent.Text)
}

# ---- Produce a manifest with the real audit code -------------------------------------------
foreach ($f in $audit.Functions) { Invoke-Expression $f.Extent.Text }
$ScriptVersion = 'test'
$DefaultDomainSuffix = '.test'
$MasterUcsList = @('PD24000001SS101', 'PD84000001SS028', 'PD85000001SS003')
function Write-RichoLog { param([string]$Message, [string]$Level = 'INFO') $script:Log.Add("[$Level] $Message") }
$script:Log = New-Object System.Collections.Generic.List[string]
. (Join-Path $PSScriptRoot 'UcsVlanFixture.ps1')

function New-Manifest {
    param([scriptblock]$Tweak, $Confirmation = (Get-Confirmation), [datetime]$GeneratedUtc = (Get-Date).ToUniversalTime())
    $run = Invoke-Audit -Confirmation $Confirmation -GeneratedUtc $GeneratedUtc
    $json = ConvertTo-Json -InputObject $run.Result.Manifest -Depth 8
    $manifest = $json | ConvertFrom-Json
    if ($Tweak) { & $Tweak $manifest }
    $manifest
}
$goodManifest = New-Manifest
Assert-Equal 'the audit fixture yields VLAN 200 as the only candidate' '200' ((@($goodManifest.Candidates) | ForEach-Object { $_.VlanId }) -join ',')

# ---- Load the removal script (shared helpers are identical, so order does not matter) ------
foreach ($f in $removal.Functions) { Invoke-Expression $f.Extent.Text }
$ScriptVersion = 'test'

# ---- Fake UCS Manager ----------------------------------------------------------------------
$script:Calls = New-Object System.Collections.Generic.List[string]
function Reset-Domain {
    param([int]$PropagationReads = 1, [switch]$AckOnChange, [switch]$NeverPropagate, [switch]$FailTemplateRemove)
    $fixture = New-UcsFixture
    $script:Domain = @{}
    foreach ($key in $fixture.Keys) { $script:Domain[$key] = New-Object System.Collections.Generic.List[object]; foreach ($item in @($fixture[$key])) { $script:Domain[$key].Add($item) } }
    $script:Domain['Ack'] = New-Object System.Collections.Generic.List[object]
    $script:Domain['Fault'] = New-Object System.Collections.Generic.List[object]
    $script:Pending = New-Object System.Collections.Generic.List[object]
    $script:PropagationReads = $PropagationReads
    $script:AckOnChange = [bool]$AckOnChange
    $script:NeverPropagate = [bool]$NeverPropagate
    $script:FailTemplateRemove = [bool]$FailTemplateRemove
    $script:Calls.Clear()
    $script:Log.Clear()
    # The SP vNICs bound to the updating templates carry materialised copies of VLAN 200.
    foreach ($sp in @('esx02')) { $script:Domain.EtherIf.Add((EtherIf "org-root/ls-$sp/ether-eth1" 'VL200')) }
}
function Invoke-Propagation {
    foreach ($item in $script:Pending.ToArray()) {
        $item.Reads--
        if ($item.Reads -gt 0 -or $script:NeverPropagate) { continue }
        $bound = @($script:Domain.Vnic | Where-Object { $_.OperNwTemplName -eq $item.TemplateDn } | ForEach-Object { $_.Dn })
        foreach ($e in @($script:Domain.EtherIf | Where-Object { $_.Name -eq $item.Name -and $bound -contains ($_.Dn.Substring(0, $_.Dn.LastIndexOf('/'))) })) { [void]$script:Domain.EtherIf.Remove($e) }
        [void]$script:Pending.Remove($item)
    }
}
function Get-UcsManagedObject {
    param($ClassId, $Ucs, $Dn, $ErrorAction)
    switch ($ClassId) {
        'fabricVlan' { $script:Domain.Vlan.ToArray() }
        'vnicLanConnTempl' { $script:Domain.VnicTemplate.ToArray() }
        'vnicEtherIf' { Invoke-Propagation; $script:Domain.EtherIf.ToArray() }
        'vnicEther' { $script:Domain.Vnic.ToArray() }
        'lsServer' { $script:Domain.ServiceProfile.ToArray() }
        'fabricPooledVlan' { $script:Domain.PooledVlan.ToArray() }
        'mgmtInbandProfile' { $script:Domain.InbandProfile.ToArray() }
        'lsmaintAck' { $script:Domain.Ack.ToArray() }
        'faultInst' { $script:Domain.Fault.ToArray() }
        default { throw "unexpected class $ClassId" }
    }
}
function Connect-UcsWithTimeout { param($Server, $Credential, $TimeoutSeconds) $script:Calls.Add("Connect $Server"); 'handle' }
function Disconnect-Ucs { param($Ucs, $ErrorAction) $script:Calls.Add('Disconnect') }
function Start-Sleep { param($Seconds) }
function Get-UcsVnicTemplate { param($Ucs, $ErrorAction) $script:Domain.VnicTemplate.ToArray() }
function Get-UcsVnicInterface {
    param([Parameter(ValueFromPipeline)]$Template)
    process { $script:Domain.EtherIf.ToArray() | Where-Object { $_.Dn -like "$($Template.Dn)/if-*" } }
}
function Remove-UcsVnicInterface {
    param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force)
    process {
        if ($script:FailTemplateRemove) { throw 'simulated UCS Manager error' }
        $script:Calls.Add("Remove-UcsVnicInterface $($InputObject.Dn)")
        [void]$script:Domain.EtherIf.Remove($InputObject)
        $templateDn = $InputObject.Dn.Substring(0, $InputObject.Dn.LastIndexOf('/'))
        $script:Pending.Add([pscustomobject]@{ TemplateDn = $templateDn; Name = $InputObject.Name; Reads = $script:PropagationReads })
        if ($script:AckOnChange) { $script:Domain.Ack.Add([pscustomobject]@{ Dn = 'org-root/ls-esx01/ack' }) }
    }
}
function Get-UcsVlan { param($Ucs, $ErrorAction) $script:Domain.Vlan.ToArray() }
function Remove-UcsVlan {
    param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force)
    process {
        $script:Calls.Add("Remove-UcsVlan $($InputObject.Dn)")
        [void]$script:Domain.Vlan.Remove($InputObject)
        if (@($script:Domain.EtherIf | Where-Object { $_.Name -eq $InputObject.Name }).Count -gt 0) { $script:Domain.Fault.Add([pscustomobject]@{ Code = 'F0933'; Dn = "fault-for-$($InputObject.Name)" }) }
    }
}

$cred = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
$outRoot = Join-Path ([IO.Path]::GetTempPath()) ('vlan-removal-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outRoot | Out-Null
function Invoke-Removal {
    param($Manifest = $goodManifest, [int[]]$VlanId = @(200), [string]$Stage = 'Both', [switch]$WhatIf)
    @(Invoke-UcsVlanRemoval -Manifest $Manifest -VlanId $VlanId -Stage $Stage -MaxManifestAgeDays 3 -Credential $cred -OutputRoot $outRoot -PollSeconds 0 -PropagationTimeoutSeconds 5 -WhatIf:$WhatIf -Confirm:$false)
}
function Get-Row { param($Plan, $Stage, $Target) @($Plan | Where-Object { $_.Stage -eq $Stage -and $_.TargetDn -like $Target })[0] }
function Get-RemovalCalls { @($script:Calls | Where-Object { $_ -like 'Remove-*' }) }

# ---- Manifest gate ---------------------------------------------------------------------------
Write-Host "`n=== Manifest gate ===" -ForegroundColor Cyan
$now = (Get-Date).ToUniversalTime()
Assert-Equal 'a complete, fresh audit is accepted' 200 @(Test-RemovalManifest -Manifest $goodManifest -VlanId 200 -NowUtc $now -MaxAgeDays 3)[0].VlanId
$prelim = New-Manifest -Confirmation (Get-Confirmation -Scope $false)
Assert-Throws 'a preliminary audit is refused' { Test-RemovalManifest -Manifest $prelim -VlanId 200 -NowUtc $now -MaxAgeDays 3 } '*Preliminary candidates are never removed*'
Assert-Throws '...and its candidate is named as not validated' { Test-RemovalManifest -Manifest $prelim -VlanId 200 -NowUtc $now -MaxAgeDays 3 } "*VLAN 200 is 'PRELIMINARY UCSM CLEANUP CANDIDATE'*"
Assert-Throws 'a stale audit is refused' { Test-RemovalManifest -Manifest $goodManifest -VlanId 200 -NowUtc $now.AddDays(4) -MaxAgeDays 3 } '*days old; the limit is 3*'
Assert-Throws 'an audit dated in the future is refused' { Test-RemovalManifest -Manifest $goodManifest -VlanId 200 -NowUtc $now.AddDays(-2) -MaxAgeDays 3 } '*in the future*'
Assert-Throws 'an empty VLAN list is refused' { Test-RemovalManifest -Manifest $goodManifest -VlanId @() -NowUtc $now -MaxAgeDays 3 } '*No VLAN IDs were given*'
Assert-Throws 'a VLAN that is not a candidate is refused' { Test-RemovalManifest -Manifest $goodManifest -VlanId 200, 100 -NowUtc $now -MaxAgeDays 3 } '*VLAN 100 is not a cleanup candidate*'
$warned = New-Manifest -Tweak { param($m) $m.Warnings = @('something') }
Assert-Throws 'an audit carrying any warning is refused' { Test-RemovalManifest -Manifest $warned -VlanId 200 -NowUtc $now -MaxAgeDays 3 } '*carries 1 warning*'
$stringDate = New-Manifest -Tweak { param($m) $m.GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o') }
Assert-Equal 'the audit time is read as a string (Windows PowerShell) or a date (PowerShell 7)' 1 @(Test-RemovalManifest -Manifest $stringDate -VlanId 200 -NowUtc $now -MaxAgeDays 3).Count
try { Test-RemovalManifest -Manifest $prelim -VlanId 200, 100 -NowUtc $now.AddDays(9) -MaxAgeDays 3 } catch { $all = $_.Exception.Message }
Assert-True 'every problem is reported in one pass' (($all -like '*Preliminary*') -and ($all -like '*days old*') -and ($all -like '*VLAN 100*'))
Reset-Domain
Assert-Throws 'a refused manifest never logs in' { Invoke-Removal -Manifest $prelim } '*Removal refused*'
Assert-Equal '...no connection was made' 0 @($script:Calls | Where-Object { $_ -like 'Connect*' }).Count

# ---- The normal run ------------------------------------------------------------------------
Write-Host "`n=== Normal run ===" -ForegroundColor Cyan
Reset-Domain -PropagationReads 2
$plan = Invoke-Removal
$removals = @(Get-RemovalCalls)
Assert-Equal 'three removals: two templates, then the LAN Cloud' 3 $removals.Count
Assert-True 'templates first' (($removals[0] -like 'Remove-UcsVnicInterface*') -and ($removals[1] -like 'Remove-UcsVnicInterface*'))
Assert-Equal 'LAN Cloud last' 'Remove-UcsVlan fabric/lan/net-VL200' $removals[2]
Assert-Equal 'template A result' 'REMOVED' (Get-Row $plan 'Template' '*ESX-A0').Result
Assert-Equal 'template B result' 'REMOVED' (Get-Row $plan 'Template' '*ESX-B1').Result
Assert-Equal 'LAN Cloud result' 'REMOVED' (Get-Row $plan 'LanCloud' 'fabric/lan/net-VL200').Result
Assert-True 'the LAN Cloud delete waited for the service profiles to drop the VLAN' (@($script:Domain.EtherIf | Where-Object { $_.Name -eq 'VL200' }).Count -eq 0)
Assert-Equal 'no F0933 raised' 0 $script:Domain.Fault.Count
Assert-True 'every other VLAN untouched' (@($script:Domain.Vlan | Where-Object { $_.Name -in @('VL100', 'VL300', 'VL400', 'VL500', 'GRP', 'INB', 'NATIVE') }).Count -eq 8)
$runFolder = @(Get-ChildItem $outRoot -Directory | Sort-Object LastWriteTime)[-1].FullName
foreach ($file in @('plan.csv', 'snapshot.json', 'rollback.ps1', 'results.csv')) { Assert-True "$file written" (Test-Path (Join-Path $runFolder $file)) }
Assert-Equal 'results rows carry the script version' 'test' @(Import-Csv (Join-Path $runFolder 'results.csv'))[0].ScriptVersion
$rollback = Get-Content (Join-Path $runFolder 'rollback.ps1') -Raw
Assert-True 'rollback re-creates the LAN Cloud VLAN' ($rollback -like "*Add-UcsVlan -Name 'VL200' -Id 200*")
Assert-Equal 'rollback re-adds both template memberships' 2 ([regex]::Matches($rollback, "Add-UcsVnicInterface -Name 'VL200'")).Count
Assert-True 'rollback restores the LAN Cloud before the templates' ($rollback.IndexOf('Add-UcsVlan') -lt $rollback.IndexOf('Add-UcsVnicInterface'))
$errors = $null; $tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($rollback, [ref]$tokens, [ref]$errors)
Assert-Equal 'rollback script parses' 0 @($errors).Count
$snapshot = Get-Content (Join-Path $runFolder 'snapshot.json') -Raw | ConvertFrom-Json
Assert-Equal 'snapshot holds the VLAN as it was' 'fabric/lan/net-VL200' @($snapshot.LanCloudVlans)[0].Dn
Assert-True 'snapshot holds the bound service profiles' (@(@($snapshot.TemplateBinding)[0].ServiceProfiles) -contains 'org-root/ls-esx01')
Assert-Equal 'disconnected at the end' 'Disconnect' $script:Calls[-1]

# ---- -WhatIf -------------------------------------------------------------------------------
Write-Host "`n=== WhatIf ===" -ForegroundColor Cyan
Reset-Domain
$plan = Invoke-Removal -WhatIf
Assert-Equal '-WhatIf removes nothing' 0 @(Get-RemovalCalls).Count
Assert-Equal '-WhatIf leaves the domain as it was' 1 @($script:Domain.Vlan | Where-Object { $_.Name -eq 'VL200' }).Count
Assert-Equal 'template rows report WHATIF' 'WHATIF,WHATIF' ((@($plan | Where-Object { $_.Stage -eq 'Template' }) | ForEach-Object { $_.Result }) -join ',')
Assert-Equal 'the LAN Cloud delete is previewed as it would run after the templates' 'WHATIF' (Get-Row $plan 'LanCloud' 'fabric/lan/net-VL200').Result
$runFolder = @(Get-ChildItem $outRoot -Directory | Sort-Object LastWriteTime)[-1].FullName
Assert-True '-WhatIf still writes the plan (the dry run is its output)' (Test-Path (Join-Path $runFolder 'plan.csv'))
Reset-Domain
Assert-Equal 'helper honours -WhatIf on its own' 'NOT PERFORMED' (Remove-LanCloudVlan -Ucs 'h' -VlanDn 'fabric/lan/net-VL200' -VlanName 'VL200' -VlanId 200 -WhatIf)
Assert-Equal '...and calls nothing' 0 @(Get-RemovalCalls).Count

# ---- Live re-validation --------------------------------------------------------------------
Write-Host "`n=== Live re-validation ===" -ForegroundColor Cyan
Reset-Domain
$script:Domain.VnicTemplate.Add([pscustomobject]@{ Name = 'ESX-C2'; Dn = 'org-root/lan-conn-templ-ESX-C2'; SwitchId = 'A'; TemplType = 'updating-template' })
$script:Domain.EtherIf.Add((EtherIf 'org-root/lan-conn-templ-ESX-C2' 'VL200'))
$plan = Invoke-Removal
Assert-Equal 'VLAN added to a template since the audit: nothing removed' 0 @(Get-RemovalCalls).Count
Assert-True '...and every row for it is blocked with the reason' (@($plan | Where-Object { $_.Status -ne 'BLOCKED' }).Count -eq 0 -and (Get-Row $plan 'LanCloud' '*VL200').Reason -like '*Added to template(s) since the audit: ESX-C2*')

Reset-Domain
$script:Domain.Vnic.Add((Vnic 'org-root/ls-bm01' 'eth1' 'A' '00:25:B5:00:00:06' 'org-root/lan-conn-templ-ESX-A0'))
$plan = Invoke-Removal
Assert-Equal 'template now used by an unaudited associated profile: nothing removed' 0 @(Get-RemovalCalls).Count
Assert-True '...the reason names the profile' ((Get-Row $plan 'Template' '*ESX-A0').Reason -like '*did not match to an ESXi host: org-root/ls-bm01*')
Assert-True '...and the partner template is held back too, keeping the pair consistent' ((Get-Row $plan 'Template' '*ESX-B1').Reason -like 'Another template membership of this VLAN is blocked*')

Reset-Domain
$script:Domain.Ack.Add([pscustomobject]@{ Dn = 'org-root/ls-esx02/ack' })
$plan = Invoke-Removal
Assert-Equal 'a pending acknowledgement on a bound profile beforehand: nothing removed' 0 @(Get-RemovalCalls).Count
Assert-True '...and said so' ((Get-Row $plan 'Template' '*ESX-A0').Reason -like '*pending reboot acknowledgement: org-root/ls-esx02*')

Reset-Domain
@($script:Domain.EtherIf | Where-Object { $_.Dn -eq 'org-root/lan-conn-templ-ESX-B1/if-VL200' })[0].DefaultNet = 'yes'
$plan = Invoke-Removal
Assert-Equal 'native on a template since the audit: nothing removed' 0 @(Get-RemovalCalls).Count
Assert-True '...and said so' ((Get-Row $plan 'LanCloud' '*VL200').Reason -like '*native on 1 vNIC/template*')

Reset-Domain
$script:Domain.Vlan.Add((UcsVlan 'VL200' 200 -Fabric A))
$plan = Invoke-Removal
Assert-Equal 'LAN Cloud definitions changed since the audit: nothing removed' 0 @(Get-RemovalCalls).Count
Assert-True '...the reason shows both' ((Get-Row $plan 'LanCloud' 'fabric/lan/net-VL200').Reason -like '*changed since the audit*')

Reset-Domain
$script:Domain.EtherIf.Add((EtherIf 'org-root/ls-bm01/ether-eth0' 'VL200'))
$plan = Invoke-Removal
Assert-Equal 'a direct vNIC reference added since the audit: templates are cleaned...' 2 @(Get-RemovalCalls).Count
Assert-Equal '...but the LAN Cloud delete is blocked by the live check' 'BLOCKED - LIVE CHECK' (Get-Row $plan 'LanCloud' '*VL200').Result
Assert-True '...naming the reference' ((Get-Row $plan 'LanCloud' '*VL200').Details -like '*org-root/ls-bm01/ether-eth0/if-VL200*')
Assert-Equal '...and no F0933 was caused' 0 $script:Domain.Fault.Count

Reset-Domain
$script:Domain.PooledVlan.Add([pscustomobject]@{ Dn = 'fabric/lan/net-group-UPLINKS/net-VL200'; Name = 'VL200' })
$plan = Invoke-Removal
Assert-Equal 'VLAN group membership blocks the LAN Cloud delete' 'BLOCKED - LIVE CHECK' (Get-Row $plan 'LanCloud' '*VL200').Result
Assert-True '...naming the group' ((Get-Row $plan 'LanCloud' '*VL200').Details -like '*VLAN group(s) UPLINKS*')

# ---- Stopping safely -----------------------------------------------------------------------
Write-Host "`n=== Stopping safely ===" -ForegroundColor Cyan
Reset-Domain -AckOnChange
$plan = Invoke-Removal
Assert-Equal 'a reboot acknowledgement raised by the template change stops the LAN Cloud stage' 'NOT ATTEMPTED' (Get-Row $plan 'LanCloud' '*VL200').Result
Assert-Equal '...no LAN Cloud delete was made' 0 @(Get-RemovalCalls | Where-Object { $_ -like 'Remove-UcsVlan*' }).Count
Assert-True '...it is logged as an error' (@($script:Log | Where-Object { $_.StartsWith('[ERROR]') -and $_ -like '*pending reboot acknowledgement*Nothing was acknowledged*' }).Count -eq 1)
Assert-True '...and nothing was acknowledged (no acknowledge cmdlet exists in the script)' ($removal.Ast.Extent.Text -notmatch '(?i)Set-UcsLsmaintAck|trigger-immediate')

Reset-Domain -NeverPropagate
$plan = Invoke-Removal
Assert-Equal 'changes that never reach the service profiles stop the LAN Cloud stage' 'NOT ATTEMPTED' (Get-Row $plan 'LanCloud' '*VL200').Result
Assert-True '...with the reason' ((Get-Row $plan 'LanCloud' '*VL200').Details -like '*had not reached 2 vNIC(s) after 5 s*')

Reset-Domain -FailTemplateRemove
$plan = Invoke-Removal
Assert-Equal 'a failed template removal is recorded' 'FAILED' (Get-Row $plan 'Template' '*ESX-A0').Result
Assert-Equal '...and the LAN Cloud delete is blocked' 'BLOCKED' (Get-Row $plan 'LanCloud' '*VL200').Result
Assert-Equal '...with no LAN Cloud call' 0 @(Get-RemovalCalls | Where-Object { $_ -like 'Remove-UcsVlan*' }).Count

# ---- Stages --------------------------------------------------------------------------------
Write-Host "`n=== Stages ===" -ForegroundColor Cyan
Reset-Domain
$plan = Invoke-Removal -Stage Templates
Assert-Equal '-Stage Templates removes from templates only' 2 @(Get-RemovalCalls | Where-Object { $_ -like 'Remove-UcsVnicInterface*' }).Count
Assert-Equal '...and leaves the LAN Cloud' 'SKIPPED - STAGE' (Get-Row $plan 'LanCloud' '*VL200').Status
$plan = Invoke-Removal -Stage LanCloud
Assert-Equal '-Stage LanCloud in a later window then deletes it' 'REMOVED' (Get-Row $plan 'LanCloud' '*VL200').Result
Assert-Equal '...without touching templates again' 3 @(Get-RemovalCalls).Count
Reset-Domain
$plan = Invoke-Removal -Stage LanCloud
Assert-Equal '-Stage LanCloud while templates still hold it is blocked live' 'BLOCKED - LIVE CHECK' (Get-Row $plan 'LanCloud' '*VL200').Result
Assert-Equal '...with no calls' 0 @(Get-RemovalCalls).Count

# ---- Plan rules in isolation ---------------------------------------------------------------
Write-Host "`n=== Plan rules ===" -ForegroundColor Cyan
Reset-Domain
$inventory = Get-UcsVlanInventory -Ucs 'h'
$candidate = @($goodManifest.Candidates)[0]
$ambiguous = $inventory.Memberships | Where-Object { $_.TemplateDn -like '*ESX-A0' -and $_.VLANName -eq 'VL200' }
$ambiguous.ResolvedVlanIds = [int[]]@(200, 201)
$p = @(Get-VlanRemovalPlan -Candidate @($candidate) -Inventory $inventory -MatchedServiceProfileDn @($goodManifest.MatchedServiceProfileDns) -PendingAckProfileDn @() -Stage Both)
Assert-True 'a name that could also mean an unapproved VLAN is not removed' ((Get-Row $p 'Template' '*ESX-A0').Reason -like "*can also mean VLAN 201*")
$init = $inventory.Memberships | Where-Object { $_.TemplateDn -like '*ESX-B1' -and $_.VLANName -eq 'VL200' }
$init.TemplateType = 'initial-template'
$p = @(Get-VlanRemovalPlan -Candidate @($candidate) -Inventory (Get-UcsVlanInventory -Ucs 'h') -MatchedServiceProfileDn @($goodManifest.MatchedServiceProfileDns) -PendingAckProfileDn @() -Stage Both)
Assert-Equal 'unchanged fixture plans every row' 'PLANNED,PLANNED,PLANNED' ((@($p) | ForEach-Object { $_.Status }) -join ',')
$script:Domain.VnicTemplate[1].TemplType = 'initial-template'
$p = @(Get-VlanRemovalPlan -Candidate @($candidate) -Inventory (Get-UcsVlanInventory -Ucs 'h') -MatchedServiceProfileDn @($goodManifest.MatchedServiceProfileDns) -PendingAckProfileDn @() -Stage Both)
Assert-True 'an initial template is flagged: its profiles keep the VLAN' ((Get-Row $p 'Template' '*ESX-B1').Reason -like 'Initial template*')

# ---- Static guarantees ---------------------------------------------------------------------
Write-Host "`n=== Static guarantees ===" -ForegroundColor Cyan
$scriptBinding = $removal.Ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
Assert-True 'script supports -WhatIf/-Confirm with ConfirmImpact High' ($scriptBinding.Extent.Text -match 'SupportsShouldProcess' -and $scriptBinding.Extent.Text -match "ConfirmImpact = 'High'")
$vlanParam = $removal.Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'VlanId' }
Assert-True 'VLAN 1 cannot be requested' ($vlanParam.Extent.Text -match 'ValidateRange\(2, 4094\)')
Assert-True 'an empty -VlanId is rejected at binding' ($vlanParam.Extent.Text -match 'ValidateCount\(1, ')
$destructive = @($removal.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^Remove-Ucs' }, $true))
foreach ($call in $destructive) {
    $parent = $call.Parent
    while ($parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
    Assert-True "$($call.GetCommandName()) only inside a ShouldProcess-guarded function ($($parent.Name))" ($parent -and $parent.Extent.Text -match 'SupportsShouldProcess' -and $parent.Extent.Text -match '\$PSCmdlet\.ShouldProcess')
}
$helperCalls = @($removal.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Remove-TemplateVlanMembership', 'Remove-LanCloudVlan') }, $true))
Assert-Equal 'helpers are called from exactly two places' 2 $helperCalls.Count
Assert-Equal 'no Write-Host (house rule)' 0 @($removal.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Host' }, $true)).Count

Remove-Item $outRoot -Recurse -Force
Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
