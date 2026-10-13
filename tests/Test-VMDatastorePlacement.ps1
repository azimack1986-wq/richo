<#
.SYNOPSIS
    Tests Test-VMDatastorePlacement.ps1: which environment a VM belongs to, which environment a
    datastore belongs to, what gets reported, and the Storage vMotion planning and execution.

.DESCRIPTION
    Extracts the script's functions by AST and drives them with plain objects shaped like the
    vSphere views and inventory records - DNS-label matching, the siepdXXxxL hostname fallback,
    letter remapping (the "add b to DEV and rediscover" case), datastore keywords (SHARED is PROD),
    VMFS exclusion, the Not on PROD/SIT/DEV list, migration target eligibility, the migration plan,
    and the migration engine's throttling, failure, stop and -WhatIf behaviour. Names ending -P or -S
    are PROD, and only full VMs are shown: SRM placeholders and disk-less VMs are left out, while a
    real VM still carrying a stale SRM placeholder mark is kept.

    Then runs the script itself, headless, against a stubbed vCenter in which a Storage vMotion
    really moves the VM's files - so a migration followed by re-discovery shows the VM where it went
    - and drives the GUI's own handlers through stand-in controls.

    Deliberately standalone - no Pester, no PowerCLI, no vCenter. Windows Forms itself cannot load
    here, so the window, the migration dialog and the confirmation box are stubbed.

.EXAMPLE
    pwsh -File ./tests/Test-VMDatastorePlacement.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vsphere/Test-VMDatastorePlacement.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors in $scriptPath" }

$wanted = @('Write-PlacementLog', 'Split-RuleValue', 'ConvertTo-PlacementRuleSet', 'Get-DatastoreEnvironment',
            'Get-DnsEnvironment', 'Get-HostnameEnvironment', 'Resolve-VMExpectedEnvironment', 'Get-PlacementReportColumn',
            'Get-PlacementMigrationColumn', 'Format-PlacementSize', 'Test-VMPlacement', 'Invoke-PlacementEvaluation',
            'Format-PlacementSummary', 'Get-PlacementSiblingPath', 'Export-PlacementReport', 'Get-PlacementHostSeeing',
            'Format-PlacementTarget', 'Get-PlacementTargetChoice', 'Get-PlacementMigrationPlan',
            'Get-ViewProperty', 'Get-DatastoreNameFromPath', 'Format-PlacementNameList', 'ConvertTo-PlacementVMRecord', 'ConvertTo-PlacementDataTable',
            'Connect-PlacementVCenter', 'Disconnect-PlacementVCenter', 'Get-PlacementClusterList', 'Get-ClusterPlacementInventory',
            'Get-PlacementStorageInfo', 'Get-PlacementTaskState', 'Invoke-PlacementMigration',
            'Invoke-GuiAction', 'Get-GuiRuleDefinition', 'Invoke-GuiConnect', 'Invoke-GuiDisconnect', 'Invoke-GuiDiscovery',
            'Invoke-GuiEvaluation', 'Get-GuiActiveTable', 'Show-GuiMigrationProgress', 'Invoke-GuiMigration')
$funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name })
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }
$script:WhatIfRun = $false

$script:pass = 0; $script:fail = 0
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red }
}
function Get-Names { param($Rows) (@($Rows | ForEach-Object { $_.VMName } | Sort-Object) -join ',') }

Write-Host "`n=== Every function under test was found ===" -ForegroundColor Cyan
foreach ($name in $wanted) {
    Assert-True "$name is defined" ([bool](Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue))
}

# The script's own defaults, read from its param block so the tests cannot drift from them.
$paramBlock = $ast.ParamBlock
function Get-DefaultValue([string]$Name) {
    $p = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name }
    if ($null -eq $p.DefaultValue) { return $null }
    $p.DefaultValue.SafeGetValue()
}
$defaultPattern = Get-DefaultValue 'HostnamePattern'

function New-Definition {
    param([string]$ProdLetters = 'p', [string]$SitLetters = 't', [string]$DevLetters = 'd',
        [string]$ProdSuffixes = ((Get-DefaultValue 'ProdNameSuffixes') -join ', '), [string]$SitSuffixes = '', [string]$DevSuffixes = '')
    @(
        [pscustomobject]@{ Environment = 'PROD'; Letters = $ProdLetters; NameSuffixes = $ProdSuffixes; DnsLabels = ((Get-DefaultValue 'ProdDnsLabels') -join ', '); DatastoreKeywords = ((Get-DefaultValue 'ProdDatastoreKeywords') -join ', ') }
        [pscustomobject]@{ Environment = 'SIT'; Letters = $SitLetters; NameSuffixes = $SitSuffixes; DnsLabels = ((Get-DefaultValue 'SitDnsLabels') -join ', '); DatastoreKeywords = ((Get-DefaultValue 'SitDatastoreKeywords') -join ', ') }
        [pscustomobject]@{ Environment = 'DEV'; Letters = $DevLetters; NameSuffixes = $DevSuffixes; DnsLabels = ((Get-DefaultValue 'DevDnsLabels') -join ', '); DatastoreKeywords = ((Get-DefaultValue 'DevDatastoreKeywords') -join ', ') }
    )
}
$rules = ConvertTo-PlacementRuleSet -Definition (New-Definition) -HostnamePattern $defaultPattern

function New-VM {
    param([string]$Name, [string]$Dns = '', [string[]]$Datastore, [string]$Type = 'NFS')
    [pscustomobject]@{
        Cluster = 'CL01'; VMName = $Name; VMId = "id-$Name"; VMRef = $null; DnsName = $Dns; PowerState = 'poweredOn'; ToolsStatus = 'guestToolsRunning'
        EsxiHost = 'esx01'; vCenter = 'vc01'; DiscoveredAt = [datetime]'2026-10-12 09:00'; CommittedBytes = [long](40GB)
        Datastores = @($Datastore | ForEach-Object { [pscustomobject]@{ Name = $_; Type = $Type } })
    }
}
function Get-Outcome { param($Vm, $RuleSet = $rules, [switch]$Flag, [switch]$Hide)
    Test-VMPlacement -Record $Vm -RuleSet $RuleSet -FlagUnclassifiedDatastores:$Flag -HideUndetermined:$Hide -ScriptVersion 'test'
}

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Defaults match the requirement ===" -ForegroundColor Cyan
Assert-True "PROD letters default to p" ((Get-DefaultValue 'ProdLetters') -join ',' -eq 'p')
Assert-True "SIT letters default to t" ((Get-DefaultValue 'SitLetters') -join ',' -eq 't')
Assert-True "DEV letters default to d" ((Get-DefaultValue 'DevLetters') -join ',' -eq 'd')
Assert-True "names ending -P or -S are PROD by default" ((Get-DefaultValue 'ProdNameSuffixes') -join ',' -eq '-P,-S')
Assert-True "SIT and DEV have no name suffixes by default" (@(Get-DefaultValue 'SitNameSuffixes').Count -eq 0 -and @(Get-DefaultValue 'DevNameSuffixes').Count -eq 0)
Assert-True "PROD DNS labels are dpe, protected" ((Get-DefaultValue 'ProdDnsLabels') -join ',' -eq 'dpe,protected')
Assert-True "SIT DNS labels are dpesit, protectedsit" ((Get-DefaultValue 'SitDnsLabels') -join ',' -eq 'dpesit,protectedsit')
Assert-True "DEV DNS labels are dpedev, protecteddev" ((Get-DefaultValue 'DevDnsLabels') -join ',' -eq 'dpedev,protecteddev')
Assert-True "PROD datastores are named SHARED" ((Get-DefaultValue 'ProdDatastoreKeywords') -join ',' -eq 'SHARED')
Assert-True "SIT and DEV datastores keep SIT and DEV" (((Get-DefaultValue 'SitDatastoreKeywords') -join ',') -eq 'SIT' -and ((Get-DefaultValue 'DevDatastoreKeywords') -join ',') -eq 'DEV')
Assert-True "VMFS datastores are not discovered by default" ((Get-DefaultValue 'ExcludeDatastoreType') -join ',' -eq 'VMFS')
Assert-True "two migrations at once, 10% kept free, by default" ((Get-DefaultValue 'MaxConcurrentMigrations') -eq 2 -and (Get-DefaultValue 'MinFreeSpacePercent') -eq 10)

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== DNS name decides first, label by label ===" -ForegroundColor Cyan
$cases = @(
    @{ Dns = 'siepd85csp1000.dpe.protected.mil.au'; Expect = 'PROD' }
    @{ Dns = 'anything.protected.mil.au'; Expect = 'PROD' }
    @{ Dns = 'host.dpesit.protectedsit.mil.au'; Expect = 'SIT' }
    @{ Dns = 'host.protectedsit.mil.au'; Expect = 'SIT' }
    @{ Dns = 'host.dpedev.protecteddev.mil.au'; Expect = 'DEV' }
    @{ Dns = 'HOST.DPEDEV.PROTECTEDDEV.MIL.AU.'; Expect = 'DEV' }
)
foreach ($case in $cases) {
    $r = Get-DnsEnvironment -DnsName $case.Dns -RuleSet $rules
    Assert-True "'$($case.Dns)' is $($case.Expect)" ($r.Environment -eq $case.Expect) "got '$($r.Environment)'"
}
Assert-True "'dpe' does not match inside 'dpesit'" ((Get-DnsEnvironment -DnsName 'h.dpesit.mil.au' -RuleSet $rules).Environment -eq 'SIT')
Assert-True "the host label itself is ignored (a VM named 'dpe')" ((Get-DnsEnvironment -DnsName 'dpe.corp.local' -RuleSet $rules).Environment -eq '')
Assert-True "a short name has no domain to judge" ((Get-DnsEnvironment -DnsName 'siepd85csp1000' -RuleSet $rules).HasDomain -eq $false)
Assert-True "labels for two environments are AMBIGUOUS" ((Get-DnsEnvironment -DnsName 'h.dpe.protectedsit.mil.au' -RuleSet $rules).Environment -eq 'AMBIGUOUS')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Hostname siepdXXxxL decides when DNS cannot ===" -ForegroundColor Cyan
$cases = @(
    @{ Name = 'siepd85csp1000'; Expect = 'PROD'; Letter = 'p' }
    @{ Name = 'siepd85cst01'; Expect = 'SIT'; Letter = 't' }
    @{ Name = 'siepd12abd'; Expect = 'DEV'; Letter = 'd' }
    @{ Name = 'SIEPD85CSP1000'; Expect = 'PROD'; Letter = 'p' }
    @{ Name = 'siepd85csp1000.dpe.protected.mil.au'; Expect = 'PROD'; Letter = 'p' }
)
foreach ($case in $cases) {
    $r = Get-HostnameEnvironment -Name $case.Name -RuleSet $rules
    Assert-True "'$($case.Name)' is $($case.Expect) (letter $($case.Letter))" ($r.Matched -and $r.Environment -eq $case.Expect -and $r.Letter -eq $case.Letter) "got '$($r.Environment)'/'$($r.Letter)'"
}
foreach ($name in @('vcenter01', 'siepdXXcsp01', 'siepd8csp01', 'xsiepd85csp01', 'siepd85c1p01')) {
    Assert-True "'$name' does not match the standard" (-not (Get-HostnameEnvironment -Name $name -RuleSet $rules).Matched)
}
$r = Get-HostnameEnvironment -Name 'siepd85csb01' -RuleSet $rules
Assert-True "'siepd85csb01' matches with an unmapped letter b" ($r.Matched -and $r.Letter -eq 'b' -and $r.Environment -eq '')

Write-Host "`n=== Names ending -P or -S are PROD ===" -ForegroundColor Cyan
$cases = @(
    @{ Name = 'SQLCLUSTER01-P'; Suffix = '-p' }
    @{ Name = 'web01-s'; Suffix = '-s' }
    @{ Name = 'APP-02-P'; Suffix = '-p' }
    @{ Name = 'sql01-p.corp.local'; Suffix = '-p' }
)
foreach ($case in $cases) {
    $r = Get-HostnameEnvironment -Name $case.Name -RuleSet $rules
    Assert-True "'$($case.Name)' is PROD by suffix $($case.Suffix)" ($r.Matched -and $r.Environment -eq 'PROD' -and $r.Suffix -eq $case.Suffix) "got '$($r.Environment)'/'$($r.Suffix)'"
}
foreach ($name in @('APP-PROD', 'SERVERS', 'web01-sp', 'web01_p', 'p', 'sql-p (old)')) {
    Assert-True "'$name' does not end in a suffix" (-not (Get-HostnameEnvironment -Name $name -RuleSet $rules).Matched)
}
$r = Get-HostnameEnvironment -Name 'siepd85csp01-S' -RuleSet $rules
Assert-True "letter p and suffix -S agree: PROD" ($r.Environment -eq 'PROD' -and -not $r.Conflict)
$r = Get-HostnameEnvironment -Name 'siepd85csb01-P' -RuleSet $rules
Assert-True "unmapped letter b, suffix -P: the suffix decides, PROD" ($r.Environment -eq 'PROD' -and -not $r.Conflict)
$r = Get-HostnameEnvironment -Name 'siepd85csd01-P' -RuleSet $rules
Assert-True "letter d but suffix -P: a conflict, not a guess" ($r.Matched -and $r.Conflict -and $r.Environment -eq '' -and $r.LetterEnvironment -eq 'DEV' -and $r.SuffixEnvironment -eq 'PROD')
$r = Resolve-VMExpectedEnvironment -VmName 'siepd85csd01-P' -DnsName '' -RuleSet $rules
Assert-True "  reported as undetermined, naming both" ($r.Status -eq 'Environment undetermined' -and $r.Detail -match "DEV by its letter 'd' but PROD by its suffix '-p'")
$r = Resolve-VMExpectedEnvironment -VmName 'SQLCLUSTER01-P' -DnsName '' -RuleSet $rules
Assert-True "the reason names the suffix" ($r.Environment -eq 'PROD' -and $r.DeterminedBy -eq 'VM name' -and $r.Detail -match "suffix '-p'")
$r = Resolve-VMExpectedEnvironment -VmName 'SQLCLUSTER01-P' -DnsName 'sqlcluster01.dpedev.protecteddev.mil.au' -RuleSet $rules
Assert-True "a DEV DNS name still wins over a -P suffix" ($r.Environment -eq 'DEV' -and $r.DeterminedBy -eq 'DNS name')
$r = Resolve-VMExpectedEnvironment -VmName 'Payroll' -DnsName 'payroll-s' -RuleSet $rules
Assert-True "the guest hostname's suffix counts too" ($r.Environment -eq 'PROD' -and $r.DeterminedBy -eq 'Guest hostname')
$r = Resolve-VMExpectedEnvironment -VmName 'vcenter01' -DnsName '' -RuleSet $rules
Assert-True "an undetermined VM's reason lists the suffixes it was checked against" ($r.Detail -match 'nor a name suffix \(-p, -s\)')
$withQ = ConvertTo-PlacementRuleSet -Definition (New-Definition -SitSuffixes '-Q') -HostnamePattern $defaultPattern
Assert-True "a suffix added in the grid works the same - -Q to SIT" ((Get-HostnameEnvironment -Name 'APP01-Q' -RuleSet $withQ).Environment -eq 'SIT')
$noSuffix = ConvertTo-PlacementRuleSet -Definition (New-Definition -ProdSuffixes '') -HostnamePattern $defaultPattern
Assert-True "with the suffixes cleared, -P means nothing" (-not (Get-HostnameEnvironment -Name 'SQLCLUSTER01-P' -RuleSet $noSuffix).Matched)
Assert-True "  and an undetermined VM's reason does not mention suffixes" ((Resolve-VMExpectedEnvironment -VmName 'vcenter01' -DnsName '' -RuleSet $noSuffix).Detail -match 'the name does not match the hostname pattern .*\.$')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Which source wins ===" -ForegroundColor Cyan
$r = Resolve-VMExpectedEnvironment -VmName 'siepd85csd01' -DnsName 'siepd85csd01.dpe.protected.mil.au' -RuleSet $rules
Assert-True "DNS (PROD) wins over a conflicting name letter (d)" ($r.Environment -eq 'PROD' -and $r.DeterminedBy -eq 'DNS name')
$r = Resolve-VMExpectedEnvironment -VmName 'siepd85cst01' -DnsName '' -RuleSet $rules
Assert-True "no DNS name falls back to the VM name" ($r.Environment -eq 'SIT' -and $r.DeterminedBy -eq 'VM name')
$r = Resolve-VMExpectedEnvironment -VmName 'siepd85cst01' -DnsName 'siepd85cst01.corp.local' -RuleSet $rules
Assert-True "a DNS name with no known label falls back to the VM name" ($r.Environment -eq 'SIT' -and $r.DeterminedBy -eq 'VM name')
$r = Resolve-VMExpectedEnvironment -VmName 'Payroll App 01' -DnsName 'siepd85csd02' -RuleSet $rules
Assert-True "a non-standard VM name falls back to the guest hostname" ($r.Environment -eq 'DEV' -and $r.DeterminedBy -eq 'Guest hostname')
$r = Resolve-VMExpectedEnvironment -VmName 'vcenter01' -DnsName '' -RuleSet $rules
Assert-True "nothing usable is 'Environment undetermined'" ($r.Environment -eq '' -and $r.Status -eq 'Environment undetermined')
$r = Resolve-VMExpectedEnvironment -VmName 'siepd85csb01' -DnsName '' -RuleSet $rules
Assert-True "an unmapped letter says so, and names the letter" ($r.Status -eq 'Unmapped hostname letter' -and $r.Detail -match "'b'")
$r = Resolve-VMExpectedEnvironment -VmName 'siepd85csp01' -DnsName 'h.dpe.protectedsit.mil.au' -RuleSet $rules
Assert-True "ambiguous DNS is undetermined, not guessed" ($r.Environment -eq '' -and $r.Status -eq 'Environment undetermined')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Datastore classification - SHARED is PROD ===" -ForegroundColor Cyan
$cases = @(
    @{ Name = 'NFS_SHARED_01'; Expect = 'PROD' }
    @{ Name = 'nfs-shared-02'; Expect = 'PROD' }
    @{ Name = 'SIEPD85SHARED01'; Expect = 'PROD' }
    @{ Name = 'SHARED'; Expect = 'PROD' }
    @{ Name = 'SITE2_SHARED_01'; Expect = 'PROD' }
    @{ Name = 'NFS_PROD_01'; Expect = '' }
    @{ Name = 'SHAREDSTORE01'; Expect = '' }
    @{ Name = 'NFS_SIT_01'; Expect = 'SIT' }
    @{ Name = 'NFS_DEV_01'; Expect = 'DEV' }
    @{ Name = 'SITE2_DS01'; Expect = '' }
    @{ Name = 'DEVICE_STORE'; Expect = '' }
    @{ Name = 'ISO_LIBRARY'; Expect = '' }
    @{ Name = 'NFS_SHARED_DEV_MIGRATE'; Expect = 'AMBIGUOUS' }
)
foreach ($case in $cases) {
    $r = Get-DatastoreEnvironment -Name $case.Name -RuleSet $rules
    Assert-True "'$($case.Name)' is '$($case.Expect)'" ($r.Environment -eq $case.Expect) "got '$($r.Environment)'"
}

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== What is reported, on which tab - and what is not ===" -ForegroundColor Cyan
$o = Get-Outcome (New-VM 'siepd85csp1000' 'siepd85csp1000.dpe.protected.mil.au' 'NFS_SHARED_01')
Assert-True "PROD VM on SHARED datastore is not reported" ($o.Outcome -eq 'Correct')
$o = Get-Outcome (New-VM 'siepd85csp1000' 'siepd85csp1000.dpe.protected.mil.au' 'NFS_DEV_01')
Assert-True "PROD VM (by DNS) on DEV datastore is misplaced" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Wrong datastore' -and $o.Finding.ExpectedEnvironment -eq 'PROD')
Assert-True "  the report names the offending datastore" ($o.Finding.WrongDatastores -eq 'NFS_DEV_01 (DEV)')
Assert-True "  and carries what migration needs" ($o.Finding.VMId -eq 'id-siepd85csp1000' -and $o.Finding.CommittedBytes -eq 40GB -and $o.Finding.SizeGB -eq 40 -and (@($o.Finding.DatastoreNames) -join ',') -eq 'NFS_DEV_01')
$o = Get-Outcome (New-VM 'siepd85cst01' 'h.dpesit.protectedsit.mil.au' 'NFS_SIT_01')
Assert-True "SIT VM on SIT datastore is not reported" ($o.Outcome -eq 'Correct')
$o = Get-Outcome (New-VM 'siepd85cst01' '' 'NFS_SHARED_01')
Assert-True "SIT VM (by name) on SHARED datastore is misplaced" ($o.Outcome -eq 'Reported' -and $o.Finding.DeterminedBy -eq 'VM name' -and $o.Finding.HostnameLetter -eq 't')
$o = Get-Outcome (New-VM 'siepd85csd01' '' 'NFS_DEV_01')
Assert-True "DEV VM (by name) on DEV datastore is not reported" ($o.Outcome -eq 'Correct')
$o = Get-Outcome (New-VM 'SQLCLUSTER01-P' '' 'NFS_DEV_01')
Assert-True "a -P VM on a DEV datastore is misplaced, expected PROD" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Wrong datastore' -and $o.Finding.ExpectedEnvironment -eq 'PROD')
$o = Get-Outcome (New-VM 'WEB01-S' '' 'NFS_SHARED_01')
Assert-True "a -S VM on a SHARED datastore is not reported" ($o.Outcome -eq 'Correct')
$o = Get-Outcome (New-VM 'WEB02-S' '' 'NFS_MISC_01')
Assert-True "a -S VM on no PROD/SIT/DEV datastore is listed, expected PROD" ($o.Outcome -eq 'Unscoped' -and $o.Finding.ExpectedEnvironment -eq 'PROD')
$flagged = New-VM 'siepd85csp01' '' 'NFS_DEV_01'
$flagged | Add-Member -NotePropertyName SrmPlaceholderFlag -NotePropertyValue $true
$o = Get-Outcome $flagged
Assert-True "a full VM still carrying an SRM placeholder mark is reported, and the reason says so" ($o.Outcome -eq 'Reported' -and $o.Finding.Reason -match 'KB 412345')
$o = Get-Outcome (New-VM 'siepd85csp01' '' @('NFS_SHARED_01', 'NFS_DEV_02'))
Assert-True "a disk on the wrong datastore is enough to report" ($o.Outcome -eq 'Reported' -and $o.Finding.WrongDatastores -eq 'NFS_DEV_02 (DEV)' -and $o.Finding.DatastoreEnvironment -eq 'PROD, DEV')
$o = Get-Outcome (New-VM 'siepd85csp01' '' @('NFS_SHARED_01', 'ISO_LIBRARY'))
Assert-True "an unclassified second datastore is ignored by default" ($o.Outcome -eq 'Correct')
$o = Get-Outcome (New-VM 'siepd85csp01' '' @('NFS_SHARED_01', 'ISO_LIBRARY')) -Flag
Assert-True "  and reported as partly outside with -FlagUnclassifiedDatastores" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Partly outside PROD/SIT/DEV')
$o = Get-Outcome (New-VM 'siepd85csp01' '' 'NFS_MISC_01')
Assert-True "a VM on no PROD/SIT/DEV datastore goes to the Not on PROD/SIT/DEV list" ($o.Outcome -eq 'Unscoped' -and $o.Finding.Status -eq 'Not on a PROD/SIT/DEV datastore')
Assert-True "  with its expected environment, so it can be migrated" ($o.Finding.ExpectedEnvironment -eq 'PROD' -and $o.Finding.Reason -match 'uses only NFS_MISC_01')
$o = Get-Outcome (New-VM 'vcenter01' '' 'NFS_MISC_01') -Hide
Assert-True "  listed even when its environment is unknown and undetermined is hidden" ($o.Outcome -eq 'Unscoped' -and $o.Finding.ExpectedEnvironment -eq '')
$o = Get-Outcome (New-VM 'siepd85csp01' '' 'NFS_SHARED_DEV_MIGRATE')
Assert-True "an ambiguous datastore name is reported" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Ambiguous datastore name')
$o = Get-Outcome (New-VM 'vcenter01' '' 'NFS_SHARED_01')
Assert-True "undetermined VM on a SHARED datastore is reported by default" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Environment undetermined')
$o = Get-Outcome (New-VM 'vcenter01' '' 'NFS_SHARED_01') -Hide
Assert-True "  and hidden with -HideUndetermined" ($o.Outcome -eq 'Hidden')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Add 'b' to DEV and re-apply ===" -ForegroundColor Cyan
$bOnDev = New-VM 'siepd85csb01' '' 'NFS_DEV_01'
$bOnProd = New-VM 'siepd85csb02' '' 'NFS_SHARED_01'
$o = Get-Outcome $bOnDev
Assert-True "before: letter b is reported as unmapped" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Unmapped hostname letter')
$o = Get-Outcome $bOnDev -Hide
Assert-True "before: unmapped letters are reported even with -HideUndetermined" ($o.Outcome -eq 'Reported')
$withB = ConvertTo-PlacementRuleSet -Definition (New-Definition -DevLetters 'd, b') -HostnamePattern $defaultPattern
$o = Get-Outcome $bOnDev -RuleSet $withB
Assert-True "after: b VM on DEV datastore is no longer reported" ($o.Outcome -eq 'Correct')
$o = Get-Outcome $bOnProd -RuleSet $withB
Assert-True "after: b VM on SHARED datastore is wrong, expected DEV" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Wrong datastore' -and $o.Finding.ExpectedEnvironment -eq 'DEV')
$withB2 = ConvertTo-PlacementRuleSet -Definition (New-Definition -DevLetters 'D;B') -HostnamePattern $defaultPattern
Assert-True "letters are case-insensitive and ';' separates too" ((Get-HostnameEnvironment -Name 'siepd85csb01' -RuleSet $withB2).Environment -eq 'DEV')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Bad rules are refused, not guessed ===" -ForegroundColor Cyan
function Get-RuleError { param($Definition, $Pattern = $defaultPattern)
    try { [void](ConvertTo-PlacementRuleSet -Definition $Definition -HostnamePattern $Pattern); '' } catch { $_.Exception.Message }
}
Assert-True "a letter in two environments" ((Get-RuleError (New-Definition -ProdLetters 'p' -DevLetters 'd, p')) -match "'p' is mapped to both PROD and DEV")
Assert-True "a multi-character letter" ((Get-RuleError (New-Definition -DevLetters 'db')) -match 'not a single letter')
Assert-True "a digit as a letter" ((Get-RuleError (New-Definition -DevLetters '1')) -match 'not a single letter')
$dotted = New-Definition; $dotted[0].DnsLabels = 'dpe.protected'
Assert-True "a dotted DNS label" ((Get-RuleError $dotted) -match 'without dots')
$dupKeyword = New-Definition; $dupKeyword[2].DatastoreKeywords = 'DEV, shared'
Assert-True "a datastore keyword in two environments" ((Get-RuleError $dupKeyword) -match "'shared' is mapped to both PROD and DEV")
$noKeyword = New-Definition; $noKeyword[1].DatastoreKeywords = ''
Assert-True "an environment with no datastore keyword" ((Get-RuleError $noKeyword) -match 'SIT has no datastore keyword')
Assert-True "a pattern without an env group" ((Get-RuleError (New-Definition) '^siepd\d{2}[a-z]{3}') -match "group named 'env'")
Assert-True "an invalid regex" ((Get-RuleError (New-Definition) '^siepd(?<env>[a-z]') -match 'not a valid regular expression')
Assert-True "a suffix in two environments" ((Get-RuleError (New-Definition -DevSuffixes '-p')) -match "'-p' is mapped to both PROD and DEV")
Assert-True "a suffix with a symbol in it" ((Get-RuleError (New-Definition -ProdSuffixes '-P!')) -match "may only contain")
Assert-True "several problems are listed together" (((Get-RuleError (New-Definition -DevLetters 'db, p')) -split "`n").Count -ge 3)
Assert-True "the defaults are valid" ((Get-RuleError (New-Definition)) -eq '')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== vSphere view -> record, VMFS left out ===" -ForegroundColor Cyan
function New-Ref([string]$Type, [string]$Value) { [pscustomobject]@{ Type = $Type; Value = $Value } }
function New-Disk { param($Ref, $File)
    [pscustomobject]@{ PSTypeName = 'VMware.Vim.VirtualDisk'; Backing = [pscustomobject]@{ FileName = $File; Datastore = $(if ($Ref) { New-Ref 'Datastore' $Ref } else { $null }) } }
}
function New-View { param($Name, $Template = $false, $ManagedBy = $null, $ManagedType = 'x', $VmPath = '', $Devices = @(), $Datastore = @(), $HostName = '', $HostRef = 'host-1', $Id = '', [double]$CommittedGB = 0)
    $view = [pscustomobject]@{
        Name = $Name
        Config = [pscustomobject]@{
            Template = $Template
            ManagedBy = $(if ($ManagedBy) { [pscustomobject]@{ ExtensionKey = $ManagedBy; Type = $ManagedType } } else { $null })
            Files = [pscustomobject]@{ VmPathName = $VmPath }
            Hardware = [pscustomobject]@{ Device = $Devices }
        }
        Guest = [pscustomobject]@{ HostName = $HostName; ToolsRunningStatus = 'guestToolsRunning' }
        Runtime = [pscustomobject]@{ PowerState = 'poweredOn'; Host = (New-Ref 'HostSystem' $HostRef) }
        Summary = [pscustomobject]@{ Storage = [pscustomobject]@{ Committed = [long]($CommittedGB * 1GB) } }
        Datastore = $Datastore
    }
    if ($Id) { $view | Add-Member -NotePropertyName MoRef -NotePropertyValue (New-Ref 'VirtualMachine' $Id) }
    $view
}
$byRef = @{
    'ds-1' = [pscustomobject]@{ Name = 'NFS_SHARED_01'; Type = 'NFS' }
    'ds-2' = [pscustomobject]@{ Name = 'NFS_DEV_01'; Type = 'NFS' }
    'ds-3' = [pscustomobject]@{ Name = 'ISO_LIBRARY'; Type = 'NFS' }
}
$byName = @{}; foreach ($v in $byRef.Values) { $byName[$v.Name] = $v }
$exByRef = @{ 'ds-9' = 'LOCAL_ESX01' }
$exByName = @{ 'LOCAL_ESX01' = 'VMFS' }
$cdrom = [pscustomobject]@{ PSTypeName = 'VMware.Vim.VirtualCdrom'; Backing = [pscustomobject]@{ FileName = '[ISO_LIBRARY] rhel.iso'; Datastore = (New-Ref 'Datastore' 'ds-3') } }
$view = New-View -Name 'siepd85csp01' -Id 'vm-77' -CommittedGB 120 -VmPath '[NFS_SHARED_01] siepd85csp01/siepd85csp01.vmx' -HostName 'siepd85csp01.dpe.protected.mil.au' -Devices @(
    (New-Disk 'ds-1' '[NFS_SHARED_01] siepd85csp01/siepd85csp01.vmdk'),
    (New-Disk 'ds-2' '[NFS_DEV_01] siepd85csp01/siepd85csp01_1.vmdk'),
    (New-Disk 'ds-9' '[LOCAL_ESX01] siepd85csp01/siepd85csp01_2.vmdk'),
    $cdrom)
$c = ConvertTo-PlacementVMRecord -View $view -DatastoreByRef $byRef -DatastoreByName $byName -ExcludedByRef $exByRef -ExcludedByName $exByName -HostByRef @{ 'host-1' = 'esx01.example' } -Cluster 'CL01' -VCenter 'vc01'
$names = @($c.Record.Datastores | ForEach-Object { $_.Name })
Assert-True "home and every disk datastore, home first, no duplicates" (($names -join ',') -eq 'NFS_SHARED_01,NFS_DEV_01') "got $($names -join ',')"
Assert-True "a disk on VMFS is left out" ($names -notcontains 'LOCAL_ESX01')
Assert-True "a mounted ISO's datastore is not counted" ($names -notcontains 'ISO_LIBRARY')
Assert-True "DNS name, host and cluster are carried" ($c.Record.DnsName -eq 'siepd85csp01.dpe.protected.mil.au' -and $c.Record.EsxiHost -eq 'esx01.example' -and $c.Record.Cluster -eq 'CL01')
Assert-True "the VM reference and committed size are carried" ($c.Record.VMId -eq 'vm-77' -and $c.Record.VMRef.Value -eq 'vm-77' -and $c.Record.CommittedBytes -eq 120GB)
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'siepd85csp02' -VmPath '[LOCAL_ESX01] a/a.vmx' -Devices @((New-Disk 'ds-9' '[LOCAL_ESX01] a/a.vmdk'))) -DatastoreByRef $byRef -DatastoreByName $byName -ExcludedByRef $exByRef -ExcludedByName $exByName
Assert-True "a VM only on VMFS is skipped as Excluded" ($c.Skip -eq 'Excluded')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'siepd85csp03' -VmPath '[LOCAL_ESX01] a/a.vmx' -Devices @((New-Disk 'ds-1' '[NFS_SHARED_01] a/a.vmdk'))) -DatastoreByRef $byRef -DatastoreByName $byName -ExcludedByRef $exByRef -ExcludedByName $exByName
Assert-True "home on VMFS, disk on SHARED: judged on the SHARED disk" ($c.Skip -eq '' -and (@($c.Record.Datastores | ForEach-Object { $_.Name }) -join ',') -eq 'NFS_SHARED_01')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 't1' -Template $true) -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a template is skipped" ($c.Skip -eq 'Template')

Write-Host "`n=== Full VMs only: SRM placeholders and disk-less VMs left out ===" -ForegroundColor Cyan
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'siepd85csp01' -ManagedBy 'com.vmware.vcDr' -VmPath '[NFS_SHARED_01] x/x.vmx') -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "an SRM placeholder (marked, no disks) is left out" ($c.Skip -eq 'Placeholder')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'siepd85csp01' -ManagedBy 'com.vmware.vcDR' -ManagedType 'placeholderVm' -VmPath '[SRM_PH_01] x/x.vmx') -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "  the key in any case - com.vmware.vcDR as written by William Lam" ($c.Skip -eq 'Placeholder')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'siepd85csp01' -ManagedBy 'com.vmware.vcDr-site2' -VmPath '[SRM_PH_01] x/x.vmx') -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "  a key with a suffix after com.vmware.vcDr" ($c.Skip -eq 'Placeholder')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'siepd85csp01' -ManagedBy 'com.example.other' -ManagedType 'placeholderVm' -VmPath '[SRM_PH_01] x/x.vmx') -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "  type placeholderVm whatever the key" ($c.Skip -eq 'Placeholder')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'shell01' -VmPath '[NFS_SHARED_01] s/s.vmx') -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a VM with no disks and no SRM mark is left out too - not a full VM" ($c.Skip -eq 'NoDisks')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'siepd85csp44' -ManagedBy 'com.vmware.vcDr' -ManagedType 'placeholderVm' -VmPath '[NFS_DEV_01] r/r.vmx' -Devices @((New-Disk 'ds-2' '[NFS_DEV_01] r/r.vmdk'))) -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a marked VM WITH disks is a real VM (stale mark, KB 412345): kept" ($c.Skip -eq '' -and $c.Record.SrmPlaceholderFlag -eq $true)
Assert-True "an ordinary VM is not flagged" ((ConvertTo-PlacementVMRecord -View $view -DatastoreByRef $byRef -DatastoreByName $byName).Record.SrmPlaceholderFlag -eq $false)
Assert-True "long name lists are cut short in the log" ((Format-PlacementNameList -Name @('c', 'a', 'b', 'd') -Max 2) -eq 'a, b (+2 more)' -and (Format-PlacementNameList -Name @('b', 'a')) -eq 'a, b')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'vCLS-1234' -VmPath '[NFS_DEV_01] vCLS/vCLS.vmx') -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a vCLS VM is skipped" ($c.Skip -eq 'Agent')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'nsx-agent' -ManagedBy 'com.vmware.vim.eam' -VmPath '[NFS_SHARED_01] n/n.vmx' -Devices @((New-Disk 'ds-1' '[NFS_SHARED_01] n/n.vmdk'))) -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "an ESX Agent Manager VM is skipped" ($c.Skip -eq 'Agent')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'x' -VmPath '[NFS_UNKNOWN] x/x.vmx' -Devices @((New-Disk $null '[NFS_DEV_01] x/x.vmdk'))) -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a datastore is found by name when the backing has no reference" (@($c.Record.Datastores | ForEach-Object { $_.Name }) -contains 'NFS_DEV_01')
Assert-True "an unknown home datastore is kept with type Unknown" (@($c.Record.Datastores | Where-Object { $_.Name -eq 'NFS_UNKNOWN' -and $_.Type -eq 'Unknown' }).Count -eq 1)
$orphan = [pscustomobject]@{ Name = 'orphan'; Config = $null; Guest = $null; Runtime = $null; Datastore = @((New-Ref 'Datastore' 'ds-2')) }
$c = ConvertTo-PlacementVMRecord -View $orphan -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a VM with no config falls back to its datastore list" ($c.Skip -eq '' -and (@($c.Record.Datastores | ForEach-Object { $_.Name }) -join ',') -eq 'NFS_DEV_01')
$orphan = [pscustomobject]@{ Name = 'orphan2'; Config = $null; Guest = $null; Runtime = $null; Datastore = @((New-Ref 'Datastore' 'ds-9')) }
$c = ConvertTo-PlacementVMRecord -View $orphan -DatastoreByRef $byRef -DatastoreByName $byName -ExcludedByRef $exByRef -ExcludedByName $exByName
Assert-True "  and is skipped when that list is all VMFS" ($c.Skip -eq 'Excluded')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Cluster evaluation, both VM lists, and CSV ===" -ForegroundColor Cyan
$inventory = @([pscustomobject]@{
    Cluster = 'CL01'; vCenter = 'vc01'; DiscoveredAt = Get-Date
    Datastores = @([pscustomobject]@{ Name = 'NFS_SHARED_01'; Type = 'NFS' }, [pscustomobject]@{ Name = 'NFS_DEV_01'; Type = 'NFS' }, [pscustomobject]@{ Name = 'NFS_MISC_01'; Type = 'NFS' })
    VMs = @(
        (New-VM 'siepd85csp01' 'siepd85csp01.dpe.protected.mil.au' 'NFS_SHARED_01'),
        (New-VM 'siepd85csp02' '' 'NFS_DEV_01'),
        (New-VM 'siepd85csd01' '' 'NFS_DEV_01'),
        (New-VM 'siepd85csb01' '' 'NFS_DEV_01'),
        (New-VM 'vcenter01' '' 'NFS_SHARED_01'),
        (New-VM 'siepd85csp03' '' 'NFS_MISC_01'))
    ExcludedTypes = @('VMFS')
    SkippedTemplates = 2; SkippedAgents = 3; SkippedPlaceholders = 4; SkippedNoDisks = 6; SkippedExcluded = 5
})
$result = Invoke-PlacementEvaluation -Inventory $inventory -RuleSet $rules -ScriptVersion '9.9.9'
$s = $result.Summary
Assert-True "6 VMs: 2 correct, 3 misplaced, 1 not on PROD/SIT/DEV" ($s.VMs -eq 6 -and $s.Correct -eq 2 -and $s.Reported -eq 3 -and $s.NotOnScoped -eq 1) "got $($s.VMs)/$($s.Correct)/$($s.Reported)/$($s.NotOnScoped)"
Assert-True "skips are carried into the summary, placeholders, disk-less and VMFS-only included" ($s.SkippedTemplates -eq 2 -and $s.SkippedAgents -eq 3 -and $s.SkippedPlaceholders -eq 4 -and $s.SkippedNoDisks -eq 6 -and $s.SkippedExcluded -eq 5)
Assert-True "the misplaced list" ((Get-Names $result.Findings) -eq 'siepd85csb01,siepd85csp02,vcenter01')
Assert-True "the Not on PROD/SIT/DEV list" ((Get-Names $result.Unscoped) -eq 'siepd85csp03')
Assert-True "every row carries the script version" (@(@($result.Findings) + @($result.Unscoped) | Where-Object { $_.ScriptVersion -ne '9.9.9' }).Count -eq 0)
$dsRow = @($result.Datastores | Where-Object { $_.Datastore -eq 'NFS_DEV_01' })
Assert-True "Datastores tab classifies and counts VMs" ($dsRow.Count -eq 1 -and $dsRow[0].Environment -eq 'DEV' -and $dsRow[0].VMs -eq 3)
$line = Format-PlacementSummary -Summary $s
Assert-True "summary line reads cleanly" ($line -match '^1 cluster\(s\), 6 full VMs: 2 correct, 3 misplaced \(.*\), 1 not on a PROD/SIT/DEV datastore\. Not shown: ' -and $line -match '4 SRM placeholder\(s\), 6 with no disks, 5 only on VMFS datastores\.$') $line

Assert-True "sibling CSV name" ((Get-PlacementSiblingPath -Path 'C:\Temp\report.csv' -Suffix 'Migration') -eq 'C:\Temp\report_Migration.csv')
Assert-True "sibling CSV name with no extension" ((Get-PlacementSiblingPath -Path '/tmp/report' -Suffix 'NotOnProdSitDev') -eq '/tmp/report_NotOnProdSitDev.csv')
Assert-True "sizes read as GB and TB" ((Format-PlacementSize (512GB)) -match '^512[.,]0 GB$' -and (Format-PlacementSize (12.3TB)) -match '^12[.,]3 TB$')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("placement-" + [Guid]::NewGuid().ToString('N'))
$csv = Join-Path $tmp 'sub/report.csv'
Export-PlacementReport -Finding $result.Findings -Path $csv 6>$null
$back = @(Import-Csv -Path $csv)
Assert-True "CSV round-trips every misplaced row" ($back.Count -eq 3)
Assert-True "CSV columns are in the declared order, migration internals left out" ((($back[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') -eq ((Get-PlacementReportColumn) -join ','))
$empty = Join-Path $tmp 'empty.csv'
Export-PlacementReport -Finding @() -Path $empty 6>$null
Assert-True "an empty result still writes the header row" ((Get-Content -Path $empty -Raw).Trim() -eq ((@(Get-PlacementReportColumn) | ForEach-Object { '"' + $_ + '"' }) -join ','))
$custom = Join-Path $tmp 'custom.csv'
Export-PlacementReport -Finding $result.Datastores -Path $custom -Column @('Datastore', 'Environment') 6>$null
Assert-True "-Column picks the columns" ((((Get-Content -Path $custom)[0]) -replace '"', '') -eq 'Datastore,Environment')
Remove-Item -Path $tmp -Recurse -Force

$table = ConvertTo-PlacementDataTable -Row $result.Findings -Column (@(Get-PlacementReportColumn) + 'VMId')
Assert-True "grid table has a row per finding, plus the hidden VMId" ($table.Rows.Count -eq 3 -and $table.Columns.Contains('VMId'))
Assert-True "SizeGB sorts as a number" ($table.Columns['SizeGB'].DataType -eq [double])
$table = ConvertTo-PlacementDataTable -Row @() -Column @('Cluster', 'VMs')
Assert-True "an empty grid table still has its columns" ($table.Rows.Count -eq 0 -and $table.Columns.Count -eq 2)

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Migration targets: datastore clusters and NFS datastores ===" -ForegroundColor Cyan
function New-DsInfo { param($Ref, $Name, $Type = 'NFS', $Pod = '', [double]$FreeGB = 1000, [double]$CapacityGB = 2000, $Accessible = $true, $Maintenance = 'normal')
    [pscustomobject]@{ Ref = (New-Ref 'Datastore' $Ref); RefValue = $Ref; Name = $Name; Type = $Type; FreeBytes = $FreeGB * 1GB; CapacityBytes = $CapacityGB * 1GB; Accessible = $Accessible; MaintenanceMode = $Maintenance; PodRefValue = $Pod }
}
function New-PodInfo { param($Ref, $Name, [string[]]$Members, [double]$FreeGB = 3000, [double]$CapacityGB = 6000)
    [pscustomobject]@{ Ref = (New-Ref 'StoragePod' $Ref); RefValue = $Ref; Name = $Name; FreeBytes = $FreeGB * 1GB; CapacityBytes = $CapacityGB * 1GB; MemberRefValues = $Members }
}
$storageA = [pscustomobject]@{
    Cluster = 'CL-A'
    Datastores = @(
        (New-DsInfo 'd1' 'NFS_SHARED_01'), (New-DsInfo 'd2' 'NFS_SHARED_41' -Type 'NFS41'),
        (New-DsInfo 'd3' 'NFS_SHARED_MAINT' -Maintenance 'inMaintenance'), (New-DsInfo 'd4' 'NFS_SHARED_DOWN' -Accessible $false),
        (New-DsInfo 'd5' 'VSAN_SHARED' -Type 'vsan'), (New-DsInfo 'd6' 'NFS_SHARED_P1' -Pod 'p1'), (New-DsInfo 'd7' 'NFS_SHARED_P2' -Pod 'p1'),
        (New-DsInfo 'd8' 'NFS_SHARED_P3' -Pod 'p2'), (New-DsInfo 'd9' 'NFS_DEV_P4' -Pod 'p2'),
        (New-DsInfo 'd10' 'NFS_SHARED_UNMOUNTED'), (New-DsInfo 'd11' 'NFS_DEV_01'))
    Pods = @((New-PodInfo 'p1' 'DSC_SHARED_01' @('d6', 'd7')), (New-PodInfo 'p2' 'DSC_MIXED' @('d8', 'd9')), (New-PodInfo 'p3' 'DSC_SHARED_HALF' @('d6', 'd99')))
    HostDatastores = @{ esxA1 = @('d1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd7', 'd8', 'd9', 'd11'); esxA2 = @('d1', 'd6', 'd7') }
}
$prod = @(Get-PlacementTargetChoice -StorageInfo @($storageA) -RuleSet $rules -Environment 'PROD')
Assert-True "PROD: the all-SHARED datastore cluster first, then the SHARED NFS datastores" ((@($prod | ForEach-Object { $_.Name }) -join ',') -eq 'DSC_SHARED_01,NFS_SHARED_01,NFS_SHARED_41') "got $(@($prod | ForEach-Object { $_.Name }) -join ',')"
Assert-True "  NFS 4.1 counts as NFS" (@($prod | Where-Object { $_.Name -eq 'NFS_SHARED_41' }).Count -eq 1)
Assert-True "  not in maintenance mode, not inaccessible, not vSAN" (@($prod | Where-Object { $_.Name -match 'MAINT|DOWN|VSAN' }).Count -eq 0)
Assert-True "  a datastore cluster member is not offered on its own" (@($prod | Where-Object { $_.Name -match '_P\d$' }).Count -eq 0)
Assert-True "  a datastore cluster with a DEV member is not offered" (@($prod | Where-Object { $_.Name -eq 'DSC_MIXED' }).Count -eq 0)
Assert-True "  a datastore cluster with a member this cluster cannot see is not offered" (@($prod | Where-Object { $_.Name -eq 'DSC_SHARED_HALF' }).Count -eq 0)
Assert-True "  a datastore no host mounts is not offered" (@($prod | Where-Object { $_.Name -eq 'NFS_SHARED_UNMOUNTED' }).Count -eq 0)
Assert-True "  each target knows the hosts that mount it" ((@($prod[0].Hosts) -join ',') -eq 'esxA1,esxA2' -and (@($prod[2].Hosts) -join ',') -eq 'esxA1')
$dev = @(Get-PlacementTargetChoice -StorageInfo @($storageA) -RuleSet $rules -Environment 'DEV')
Assert-True "DEV: only the DEV NFS datastore" ((@($dev | ForEach-Object { $_.Name }) -join ',') -eq 'NFS_DEV_01')
$storageB = [pscustomobject]@{ Cluster = 'CL-B'; Datastores = @((New-DsInfo 'd1' 'NFS_SHARED_01')); Pods = @(); HostDatastores = @{ esxB1 = @('d1') } }
$merged = @(Get-PlacementTargetChoice -StorageInfo @($storageA, $storageB) -RuleSet $rules -Environment 'PROD' | Where-Object { $_.Name -eq 'NFS_SHARED_01' })
Assert-True "a datastore shared by two clusters is one target, usable from both" ($merged.Count -eq 1 -and (@($merged[0].Clusters) -join ',') -eq 'CL-A,CL-B' -and @($merged[0].Hosts) -contains 'esxB1')
Assert-True "the target line names kind, free space and clusters" ((Format-PlacementTarget -Target $prod[0]) -match '^Datastore cluster  DSC_SHARED_01  -  2[.,]9 TB free of 5[.,]9 TB  -  CL-A$') (Format-PlacementTarget -Target $prod[0])

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Migration plan: who moves, who is skipped, and why ===" -ForegroundColor Cyan
function New-Finding { param($Name, $Environment, $Cluster = 'CL-A', $EsxiHost = 'esxA1', [string[]]$Datastores = @('NFS_DEV_01'), [double]$SizeGB = 50, $Status = 'Wrong datastore', $Id = $Name)
    [pscustomobject]@{ VMName = $Name; VMId = $Id; VMRef = (New-Ref 'VirtualMachine' $Id); Cluster = $Cluster; EsxiHost = $EsxiHost; ExpectedEnvironment = $Environment
        DatastoreNames = $Datastores; SizeGB = $SizeGB; CommittedBytes = [long]($SizeGB * 1GB); Status = $Status }
}
$podTarget = $prod[0]
$nfsTarget = $prod[1]
$devTarget = $dev[0]
$plan = @(Get-PlacementMigrationPlan -Finding @(
        (New-Finding 'move-me' 'PROD'),
        (New-Finding 'no-env' '' -Status 'Environment undetermined'),
        (New-Finding 'no-target' 'SIT'),
        (New-Finding 'wrong-host' 'PROD' -EsxiHost 'esxZ9'),
        (New-Finding 'already' 'DEV' -Datastores @('NFS_DEV_01')),
        (New-Finding 'move-me' 'PROD')) -TargetByEnvironment @{ PROD = $podTarget; DEV = $devTarget })
function Get-PlanRow { param($Name) @($plan | Where-Object { $_.VMName -eq $Name }) }
Assert-True "one row per VM given" ($plan.Count -eq 6)
Assert-True "a PROD VM moves to the PROD datastore cluster" ((Get-PlanRow 'move-me')[0].Action -eq 'Migrate' -and (Get-PlanRow 'move-me')[0].Target -eq 'DSC_SHARED_01' -and (Get-PlanRow 'move-me')[0].TargetKind -eq 'Datastore cluster')
Assert-True "  and the move carries the VM and target references" ((Get-PlanRow 'move-me')[0].VMRef.Value -eq 'move-me' -and (Get-PlanRow 'move-me')[0].TargetRef.Value -eq 'p1')
Assert-True "a VM listed twice is planned once" ((Get-PlanRow 'move-me')[1].Action -eq 'Skip' -and (Get-PlanRow 'move-me')[1].Reason -match 'twice')
Assert-True "unknown environment: skipped - nowhere correct to go" ((Get-PlanRow 'no-env')[0].Action -eq 'Skip' -and (Get-PlanRow 'no-env')[0].Reason -match 'nowhere correct')
Assert-True "no target picked for SIT: skipped" ((Get-PlanRow 'no-target')[0].Action -eq 'Skip' -and (Get-PlanRow 'no-target')[0].Reason -eq 'No SIT target was picked.')
Assert-True "target not mounted on the VM's host: skipped" ((Get-PlanRow 'wrong-host')[0].Action -eq 'Skip' -and (Get-PlanRow 'wrong-host')[0].Reason -match 'not mounted on esxZ9')
Assert-True "already wholly on the target datastore: skipped" ((Get-PlanRow 'already')[0].Action -eq 'Skip' -and (Get-PlanRow 'already')[0].Reason -eq 'Already on NFS_DEV_01.')
$crossed = $nfsTarget.PSObject.Copy(); $crossed.Environment = 'DEV'
$p = @(Get-PlacementMigrationPlan -Finding @((New-Finding 'x' 'PROD')) -TargetByEnvironment @{ PROD = $crossed })
Assert-True "a target of another environment is refused even if handed in" ($p[0].Action -eq 'Skip' -and $p[0].Reason -match 'the VM belongs on PROD')

$tight = $nfsTarget.PSObject.Copy(); $tight.FreeBytes = 500GB; $tight.CapacityBytes = 1000GB
$p = @(Get-PlacementMigrationPlan -Finding @((New-Finding 'a' 'PROD' -SizeGB 250), (New-Finding 'b' 'PROD' -SizeGB 250), (New-Finding 'c' 'PROD' -SizeGB 50)) -TargetByEnvironment @{ PROD = $tight } -MinFreeSpacePercent 10)
Assert-True "space: the first 250 GB fits (250 GB left, 100 GB kept)" ($p[0].Action -eq 'Migrate')
Assert-True "space: the second does not, counting the first" ($p[1].Action -eq 'Skip' -and $p[1].Reason -match 'Not enough space')
Assert-True "space: a smaller one after it still fits" ($p[2].Action -eq 'Migrate')
$p = @(Get-PlacementMigrationPlan -Finding @((New-Finding 'a' 'PROD' -SizeGB 450)) -TargetByEnvironment @{ PROD = $tight } -MinFreeSpacePercent 0)
Assert-True "space: 0% kept lets a VM fill the target" ($p[0].Action -eq 'Migrate')

# ---------------------------------------------------------------------------------------------
# A stubbed vCenter. Get-View answers the shapes of request the script sends and throws on any
# other, so a new kind of call cannot slip through unstubbed. A Storage vMotion really moves the
# VM's files when its task succeeds, so re-discovery after a migration shows the new placement.
function New-DatastoreView { param($Ref, $Name, $Type = 'NFS', $Pod = '', [double]$FreeGB = 1000, [double]$CapacityGB = 2000)
    $parent = New-Ref 'Folder' 'group-s1'
    if ($Pod) { $parent = New-Ref 'StoragePod' $Pod }
    [pscustomobject]@{ Name = $Name; MoRef = (New-Ref 'Datastore' $Ref); Parent = $parent
        Summary = [pscustomobject]@{ Type = $Type; FreeSpace = [long]($FreeGB * 1GB); Capacity = [long]($CapacityGB * 1GB); Accessible = $true; MaintenanceMode = 'normal' } }
}
function New-World {
    $refs = { param([string[]]$Values) @($Values | ForEach-Object { New-Ref 'Datastore' $_ }) }
    @{
        Clusters = @(
            [pscustomobject]@{ Name = 'CL-PROD-01'; MoRef = (New-Ref 'ClusterComputeResource' 'domain-c1'); Datastore = (& $refs 'ds-1', 'ds-2', 'ds-4', 'ds-5', 'ds-6', 'ds-7'); Host = @((New-Ref 'HostSystem' 'host-1')) }
            [pscustomobject]@{ Name = 'CL-DEV-01'; MoRef = (New-Ref 'ClusterComputeResource' 'domain-c2'); Datastore = (& $refs 'ds-2', 'ds-3'); Host = @((New-Ref 'HostSystem' 'host-2')) }
        )
        Datastores = @(
            (New-DatastoreView 'ds-1' 'NFS_SHARED_01'), (New-DatastoreView 'ds-2' 'NFS_DEV_01'), (New-DatastoreView 'ds-3' 'NFS_DEV_02'),
            (New-DatastoreView 'ds-4' 'NFS_MISC_01'), (New-DatastoreView 'ds-5' 'LOCAL_ESX01' -Type 'VMFS'),
            (New-DatastoreView 'ds-6' 'NFS_SHARED_02' -Pod 'group-p1'), (New-DatastoreView 'ds-7' 'NFS_SHARED_03' -Type 'NFS41' -Pod 'group-p1')
        )
        Pods = @([pscustomobject]@{ Name = 'DSC_SHARED_01'; MoRef = (New-Ref 'StoragePod' 'group-p1'); ChildEntity = (& $refs 'ds-6', 'ds-7')
                Summary = [pscustomobject]@{ FreeSpace = [long](4000GB); Capacity = [long](8000GB) } })
        Hosts = @(
            [pscustomobject]@{ Name = 'esx01'; MoRef = (New-Ref 'HostSystem' 'host-1'); Datastore = (& $refs 'ds-1', 'ds-2', 'ds-4', 'ds-5', 'ds-6', 'ds-7') }
            [pscustomobject]@{ Name = 'esx02'; MoRef = (New-Ref 'HostSystem' 'host-2'); Datastore = (& $refs 'ds-2', 'ds-3') }
        )
        VMs = @{
            'domain-c1' = @(
                (New-View -Id 'vm-1' -Name 'siepd85csp01' -VmPath '[NFS_SHARED_01] a/a.vmx' -HostName 'siepd85csp01.dpe.protected.mil.au' -Devices @((New-Disk 'ds-1' '[NFS_SHARED_01] a/a.vmdk')))
                (New-View -Id 'vm-2' -Name 'siepd85csd02' -VmPath '[NFS_SHARED_01] b/b.vmx' -Devices @((New-Disk 'ds-1' '[NFS_SHARED_01] b/b.vmdk')) -CommittedGB 60)
                (New-View -Id 'vm-3' -Name 'vCLS-01' -VmPath '[NFS_DEV_01] v/v.vmx')
                (New-View -Id 'vm-5' -Name 'siepd85csp05' -VmPath '[LOCAL_ESX01] e/e.vmx' -Devices @((New-Disk 'ds-5' '[LOCAL_ESX01] e/e.vmdk')))
                (New-View -Id 'vm-6' -Name 'siepd85csp06' -VmPath '[NFS_SHARED_01] f/f.vmx' -Devices @((New-Disk 'ds-5' '[LOCAL_ESX01] f/f.vmdk')))
                (New-View -Id 'vm-7' -Name 'siepd85csp07' -VmPath '[NFS_DEV_01] g/g.vmx' -Devices @((New-Disk 'ds-2' '[NFS_DEV_01] g/g.vmdk')) -CommittedGB 80)
                (New-View -Id 'vm-8' -Name 'siepd85csp08' -VmPath '[NFS_MISC_01] h/h.vmx' -Devices @((New-Disk 'ds-4' '[NFS_MISC_01] h/h.vmdk')) -CommittedGB 20)
                (New-View -Id 'vm-9' -Name 'siepd85csp09' -ManagedBy 'com.vmware.vcDr' -ManagedType 'placeholderVm' -VmPath '[NFS_MISC_01] i/i.vmx')
                (New-View -Id 'vm-10' -Name 'siepd85csp10' -ManagedBy 'com.vmware.vcDr' -ManagedType 'placeholderVm' -VmPath '[NFS_SHARED_01] j/j.vmx' -Devices @((New-Disk 'ds-1' '[NFS_SHARED_01] j/j.vmdk')))
            )
            'domain-c2' = @(
                (New-View -Id 'vm-4' -Name 'siepd85csp03' -HostRef 'host-2' -VmPath '[NFS_DEV_01] c/c.vmx' -Devices @((New-Disk 'ds-2' '[NFS_DEV_01] c/c.vmdk')))
                (New-View -Id 'vm-11' -Name 'SQLCLUSTER01-P' -HostRef 'host-2' -VmPath '[NFS_DEV_01] k/k.vmx' -Devices @((New-Disk 'ds-2' '[NFS_DEV_01] k/k.vmdk')))
            )
        }
        Calls = New-Object System.Collections.Generic.List[string]
        Moves = New-Object System.Collections.Generic.List[string]
        ViewCalls = 0
        Tasks = @{}
        TaskSeq = 0
        Active = 0
        MaxActive = 0
        FailStart = @{}
        FailTask = @{}
        LoseTask = @{}
        ApiStateOnly = @{}
    }
}
function Move-WorldVM { param([string]$VmRef, [string]$TargetRef)
    $targetDs = $TargetRef
    $pod = @($world.Pods | Where-Object { $_.MoRef.Value -eq $TargetRef })
    if ($pod.Count -eq 1) { $targetDs = $pod[0].ChildEntity[0].Value }
    $ds = @($world.Datastores | Where-Object { $_.MoRef.Value -eq $targetDs })[0]
    foreach ($list in $world.VMs.Values) {
        foreach ($vmView in $list) {
            if ($vmView.MoRef.Value -ne $VmRef) { continue }
            $vmView.Config.Files.VmPathName = "[$($ds.Name)] $($vmView.Name)/$($vmView.Name).vmx"
            foreach ($disk in @($vmView.Config.Hardware.Device)) {
                $disk.Backing.Datastore = New-Ref 'Datastore' $targetDs
                $disk.Backing.FileName = "[$($ds.Name)] $($vmView.Name)/$($vmView.Name).vmdk"
            }
        }
    }
}
function Connect-VIServer { param($Server, $Credential) $world.Calls.Add("connect $Server"); [pscustomobject]@{ Name = $Server; Version = '8.0.3'; Build = '1'; User = 'DPE\tester' } }
function Disconnect-VIServer { param($Server, [switch]$Confirm, [switch]$WhatIf) $world.Calls.Add("disconnect $($Server.Name)") }
function Get-View {
    param($Server, $ViewType, $Id, $SearchRoot, $Property)
    $world.ViewCalls = $world.ViewCalls + 1
    if ($ViewType -eq 'ClusterComputeResource') { return $world.Clusters }
    if ($ViewType -eq 'VirtualMachine') { return $world.VMs[$SearchRoot.Value] }
    if ($null -ne $Id) {
        $all = @($world.Clusters) + @($world.Datastores) + @($world.Pods) + @($world.Hosts)
        foreach ($ref in @($Id)) {
            $hit = @($all | Where-Object { $_.MoRef.Value -eq $ref.Value })
            if ($hit.Count -ne 1) { throw "stub Get-View: unknown Id $($ref.Value)" }
            $hit[0]
        }
        return
    }
    throw "stub Get-View: unexpected call"
}
function Get-VIObjectByVIView { param($Server, $MORef) [pscustomobject]@{ Ref = $MORef } }
function Move-VM {
    param($VM, $Datastore, [switch]$RunAsync, [switch]$Confirm)
    $vmRef = [string]$VM.Ref.Value
    $world.Moves.Add("$vmRef->$($Datastore.Ref.Value)")
    if ($world.FailStart.ContainsKey($vmRef)) { throw 'Insufficient disk space on datastore.' }
    $world.TaskSeq = $world.TaskSeq + 1
    $taskId = "Task-task-$($world.TaskSeq)"
    $world.Tasks[$taskId] = [pscustomobject]@{ Vm = $vmRef; Target = [string]$Datastore.Ref.Value; Polls = 0; Done = $false }
    $world.Active = $world.Active + 1
    if ($world.Active -gt $world.MaxActive) { $world.MaxActive = $world.Active }
    [pscustomobject]@{ Id = $taskId }
}
function Get-Task {
    param($Server, $Id)
    $task = $world.Tasks[$Id]
    if ($world.LoseTask.ContainsKey($task.Vm)) { throw "The object 'vim.Task:$Id' has already been deleted or has not been completely created" }
    if ($world.ApiStateOnly.ContainsKey($task.Vm)) {
        # PowerCLI's State never moves on; only the API's Info.State says it finished.
        $task.Polls = $task.Polls + 1
        if ($task.Polls -gt 10) { throw 'stub Get-Task: still polled after 10 tries - the finished API state was ignored' }
        $apiState = 'running'
        if ($task.Polls -ge 2) { $apiState = 'success' }
        return [pscustomobject]@{ State = 'Unknown'; PercentComplete = 50; ExtensionData = [pscustomobject]@{ Info = [pscustomobject]@{ State = $apiState; Error = $null } } }
    }
    $task.Polls = $task.Polls + 1
    if ($task.Polls -lt 2) { return [pscustomobject]@{ State = 'Running'; PercentComplete = 40; ExtensionData = $null } }
    if (-not $task.Done) {
        $task.Done = $true
        $world.Active = $world.Active - 1
        if (-not $world.FailTask.ContainsKey($task.Vm)) { Move-WorldVM -VmRef $task.Vm -TargetRef $task.Target }
    }
    if ($world.FailTask.ContainsKey($task.Vm)) {
        return [pscustomobject]@{ State = 'Error'; PercentComplete = 60; ExtensionData = [pscustomobject]@{ Info = [pscustomobject]@{ Error = [pscustomobject]@{ LocalizedMessage = 'A general system error occurred: Storage vMotion failed to copy one or more disks.' } } } }
    }
    [pscustomobject]@{ State = 'Success'; PercentComplete = 100; ExtensionData = $null }
}
# The script's default poll interval is five seconds; nothing here needs to wait.
function Start-Sleep { param($Seconds, $Milliseconds) }

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Migration engine: throttle, WhatIf, failures, stop ===" -ForegroundColor Cyan
$world = New-World
$vc = [pscustomobject]@{ Name = 'vc.example' }
function New-PlanRow { param($Name, $Id, $TargetRef = 'ds-1', $Action = 'Migrate')
    [pscustomobject]@{ Action = $Action; Reason = "planned for $Name"; VMName = $Name; VMId = $Id; VMRef = (New-Ref 'VirtualMachine' $Id); Cluster = 'CL-PROD-01'; EsxiHost = 'esx01'
        ExpectedEnvironment = 'PROD'; From = 'NFS_DEV_01'; SizeGB = 10; SizeBytes = 10GB; Target = 'NFS_SHARED_01'; TargetKind = 'Datastore'; TargetRef = (New-Ref 'Datastore' $TargetRef) }
}
$enginePlan = @((New-PlanRow 'a' 'x-1'), (New-PlanRow 'b' 'x-2'), (New-PlanRow 'c' 'x-3'), (New-PlanRow 'd' 'x-4'), (New-PlanRow 'skip-me' 'x-5' -Action 'Skip'))

$out = @(Invoke-PlacementMigration -Server $vc -Plan $enginePlan -MaxConcurrent 2 -Wait {} -WhatIf 6>$null)
Assert-True "-WhatIf: nothing is moved" ($world.Moves.Count -eq 0)
Assert-True "-WhatIf: every planned move reads WhatIf, the skip stays Skipped" ((@($out | ForEach-Object { $_.Result }) -join ',') -eq 'WhatIf,WhatIf,WhatIf,WhatIf,Skipped')

$progressCalls = 0
$out = @(Invoke-PlacementMigration -Server $vc -Plan $enginePlan -MaxConcurrent 2 -Wait {} -Confirm:$false -OnProgress { param($Rows) $script:progressCalls++ } 6>$null)
Assert-True "live: all four moved" ((@($out | ForEach-Object { $_.Result }) -join ',') -eq 'Migrated,Migrated,Migrated,Migrated,Skipped')
Assert-True "live: never more than two at once" ($world.MaxActive -eq 2) "max $($world.MaxActive)"
Assert-True "live: the skipped row keeps its reason" ($out[4].Detail -eq 'planned for skip-me')
Assert-True "live: times and progress recorded" ($out[0].Started -and $out[0].Finished -and $out[0].Progress -eq 100)
Assert-True "live: progress reported as it goes" ($progressCalls -ge 3)

$world = New-World
$world.FailStart['x-2'] = $true
$world.FailTask['x-3'] = $true
$out = @(Invoke-PlacementMigration -Server $vc -Plan $enginePlan -MaxConcurrent 1 -Wait {} -Confirm:$false 6>$null 3>$null)
Assert-True "one at a time when asked" ($world.MaxActive -eq 1)
Assert-True "a move that will not start is Failed, with vCenter's reason, and the rest carry on" ($out[1].Result -eq 'Failed' -and $out[1].Detail -match 'Insufficient disk space' -and $out[3].Result -eq 'Migrated')
Assert-True "a task that errors is Failed, with the task's message" ($out[2].Result -eq 'Failed' -and $out[2].Detail -match 'failed to copy')

$world = New-World
$world.LoseTask['x-1'] = $true
$out = @(Invoke-PlacementMigration -Server $vc -Plan @($enginePlan[0]) -Wait {} -Confirm:$false 6>$null 3>$null)
Assert-True "a task that can no longer be read is Unknown after three tries, not a guess" ($out[0].Result -eq 'Unknown' -and $out[0].Detail -match 'check it in vCenter')

$world = New-World
$world.ApiStateOnly['x-1'] = $true
$out = @(Invoke-PlacementMigration -Server $vc -Plan @($enginePlan[0]) -Wait {} -Confirm:$false 6>$null 3>$null)
Assert-True "a task PowerCLI never reports finished still completes on the API's own state" ($out[0].Result -eq 'Migrated')

$world = New-World
$script:startedSoFar = 0
$out = @(Invoke-PlacementMigration -Server $vc -Plan $enginePlan -MaxConcurrent 1 -Wait {} -Confirm:$false -ShouldStop { $world.Moves.Count -ge 1 } 6>$null 3>$null)
Assert-True "stop: the running move finishes" ($out[0].Result -eq 'Migrated')
Assert-True "stop: nothing new starts" ($world.Moves.Count -eq 1 -and (@($out[1..3] | ForEach-Object { $_.Result }) -join ',') -eq 'Not started,Not started,Not started')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Argument checks before any connection ===" -ForegroundColor Cyan
function Get-RunError { param([hashtable]$Arguments)
    try { & $scriptPath @Arguments 6>$null 2>$null 3>$null; '' } catch { $_.Exception.Message }
}
$world = New-World
Assert-True "-NoGui without -Server is refused" ((Get-RunError @{ NoGui = $true }) -match '-Server is required')
Assert-True "bad -DevLetters are refused before a sign-in prompt" ((Get-RunError @{ NoGui = $true; Server = 'vc.example'; DevLetters = @('d', 'p') }) -match "'p' is mapped to both PROD and DEV")
Assert-True "-MigrateTo with an unknown environment is refused before a sign-in prompt" ((Get-RunError @{ NoGui = $true; Server = 'vc.example'; MigrateTo = @{ UAT = 'x' } }) -match 'UAT, which is not an environment')
Assert-True "  and nothing connected" ($world.Calls.Count -eq 0)
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Assert-True "the GUI refuses to start off Windows" ((Get-RunError @{}) -match 'needs Windows')
}

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Headless report end to end ===" -ForegroundColor Cyan
$world = New-World
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("placement-" + [Guid]::NewGuid().ToString('N'))
$csv = Join-Path $tmp 'run.csv'
$cred = New-Object System.Management.Automation.PSCredential('DPE\tester', (New-Object System.Security.SecureString))
$rows = @(& $scriptPath -NoGui -Server 'vc.example' -Credential $cred -OutputPath $csv 6>$null)
Assert-True "all clusters: four misplaced VMs output, the -P one included" ((@($rows | ForEach-Object { "$($_.Cluster)/$($_.VMName)" } | Sort-Object) -join ',') -eq 'CL-DEV-01/siepd85csp03,CL-DEV-01/SQLCLUSTER01-P,CL-PROD-01/siepd85csd02,CL-PROD-01/siepd85csp07') "got $(@($rows | ForEach-Object { $_.VMName }) -join ',')"
Assert-True "the PROD VM on SHARED by DNS is not reported" (@($rows | Where-Object { $_.VMName -eq 'siepd85csp01' }).Count -eq 0)
Assert-True "a VM with its home on SHARED and a disk on VMFS is correct" (@($rows | Where-Object { $_.VMName -eq 'siepd85csp06' }).Count -eq 0)
Assert-True "the vCLS VM and the VMFS-only VM are not reported" (@($rows | Where-Object { $_.VMName -match 'vCLS|csp05' }).Count -eq 0)
Assert-True "the -P VM is reported by its suffix" (@($rows | Where-Object { $_.VMName -eq 'SQLCLUSTER01-P' -and $_.ExpectedEnvironment -eq 'PROD' -and $_.Reason -match "suffix '-p'" }).Count -eq 1)
Assert-True "the SRM placeholder is in neither list" (@($rows | Where-Object { $_.VMName -eq 'siepd85csp09' }).Count -eq 0 -and @(Import-Csv -Path (Join-Path $tmp 'run_NotOnProdSitDev.csv') | Where-Object { $_.VMName -eq 'siepd85csp09' }).Count -eq 0)
Assert-True "the misplaced CSV holds the same rows" (@(Import-Csv -Path $csv).Count -eq 4)
$unscopedCsv = @(Import-Csv -Path (Join-Path $tmp 'run_NotOnProdSitDev.csv'))
Assert-True "the Not on PROD/SIT/DEV CSV holds the VM on NFS_MISC_01" ($unscopedCsv.Count -eq 1 -and $unscopedCsv[0].VMName -eq 'siepd85csp08')
Assert-True "connected once and disconnected once" (($world.Calls.ToArray() -join ',') -eq 'connect vc.example,disconnect vc.example') "got $($world.Calls.ToArray() -join ',')"
Assert-True "nothing was moved" ($world.Moves.Count -eq 0)

$world = New-World
$rows = @(& $scriptPath -NoGui -Server 'vc.example' -Credential $cred -Cluster 'CL-DEV-*' -OutputPath $csv 6>$null)
Assert-True "-Cluster with a wildcard discovers only that cluster" ((@($rows | ForEach-Object { $_.Cluster } | Sort-Object -Unique) -join ',') -eq 'CL-DEV-01')

$world = New-World
$message = try { & $scriptPath -NoGui -Server 'vc.example' -Credential $cred -Cluster 'NOPE' -OutputPath $csv 6>$null 2>$null; '' } catch { $_.Exception.Message }
Assert-True "an unknown cluster names the clusters that do exist" ($message -match 'CL-DEV-01, CL-PROD-01')
Assert-True "  and still disconnects" ($world.Calls.ToArray() -contains 'disconnect vc.example')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Headless migration ===" -ForegroundColor Cyan
$targets = @{ PROD = 'DSC_SHARED_01'; DEV = 'NFS_DEV_01' }
$world = New-World
$out = @(& $scriptPath -NoGui -Server 'vc.example' -Credential $cred -OutputPath $csv -MigrateTo $targets -WhatIf 6>$null)
Assert-True "-WhatIf: nothing is moved" ($world.Moves.Count -eq 0)
Assert-True "-WhatIf: the output is the migration plan, both lists included" ((Get-Names $out) -eq 'siepd85csd02,siepd85csp03,siepd85csp07,siepd85csp08,SQLCLUSTER01-P')
Assert-True "-WhatIf: the three reachable VMs would move" ((Get-Names @($out | Where-Object { $_.Result -eq 'WhatIf' })) -eq 'siepd85csd02,siepd85csp07,siepd85csp08')
$skip = @($out | Where-Object { $_.VMName -eq 'siepd85csp03' })
Assert-True "-WhatIf: the CL-DEV-01 VM is skipped - the PROD target is not on its host" ($skip[0].Result -eq 'Skipped' -and $skip[0].Detail -match 'not mounted on esx02')
Assert-True "-WhatIf: the reports and the migration CSV are still written" ((Test-Path $csv) -and @(Import-Csv -Path (Join-Path $tmp 'run_Migration.csv')).Count -eq 5)

$world = New-World
$out = @(& $scriptPath -NoGui -Server 'vc.example' -Credential $cred -OutputPath $csv -MigrateTo $targets -Confirm:$false 6>$null)
Assert-True "live: the three moved, to the right places" ((@($world.Moves.ToArray() | Sort-Object) -join ',') -eq 'vm-2->ds-2,vm-7->group-p1,vm-8->group-p1') "got $($world.Moves.ToArray() -join ',')"
Assert-True "live: results say so" ((Get-Names @($out | Where-Object { $_.Result -eq 'Migrated' })) -eq 'siepd85csd02,siepd85csp07,siepd85csp08')
Assert-True "live: never more than two at once" ($world.MaxActive -le 2)
$after = @(& $scriptPath -NoGui -Server 'vc.example' -Credential $cred -OutputPath $csv 6>$null)
Assert-True "live: a fresh report shows only the VMs that could not move" ((Get-Names $after) -eq 'siepd85csp03,SQLCLUSTER01-P')

$world = New-World
$out = @(& $scriptPath -NoGui -Server 'vc.example' -Credential $cred -OutputPath $csv -MigrateTo $targets -MigrateVM 'siepd85csd*' -Confirm:$false 6>$null)
Assert-True "-MigrateVM picks the VMs" ((Get-Names $out) -eq 'siepd85csd02' -and ($world.Moves.ToArray() -join ',') -eq 'vm-2->ds-2')

$world = New-World
$message = try { & $scriptPath -NoGui -Server 'vc.example' -Credential $cred -OutputPath $csv -MigrateTo @{ PROD = 'NFS_DEV_01' } -Confirm:$false 6>$null 2>$null; '' } catch { $_.Exception.Message }
Assert-True "a target that is not eligible for the environment is refused, listing the eligible ones" ($message -match "'NFS_DEV_01' is not an eligible PROD target\. Eligible: DSC_SHARED_01 \(datastore cluster\), NFS_SHARED_01 \(datastore\)") $message
Assert-True "  nothing moved, and the session closed" ($world.Moves.Count -eq 0 -and $world.Calls.ToArray() -contains 'disconnect vc.example')
Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== GUI flow - connect, discover, re-apply, disconnect - with stand-in controls ===" -ForegroundColor Cyan
# Windows Forms cannot load here, so the controls the GUI functions read and write are stood in by
# plain objects with the same members, and the functions that touch Windows Forms types directly
# (busy cursor, message box, migration dialog, confirmation, wait) are stubbed. Tabs are real .NET
# objects so the script's reference comparisons behave as they do with TabPages.
function Enter-GuiBusyState { param([string]$Text = 'Working...') $script:GuiState.Busy = $true; $busyTexts.Add($Text) }
function Exit-GuiBusyState { $script:GuiState.Busy = $false }
function Show-GuiMessage { param([string]$Text, [string]$Icon = 'Information') $messages.Add("${Icon}: $Text") }
function Wait-GuiInterval { param([int]$Seconds = 5) }
function Show-MigrationDialog {
    param($Environment, $Choice, $Count, $Unknown, $MaxConcurrent, $MinFreeSpacePercent, $WhatIfOnly)
    $script:dialogSeen = [pscustomobject]@{ Environment = @($Environment); Choice = $Choice; Count = $Count; WhatIfOnly = $WhatIfOnly }
    if ($null -eq $script:dialogMode) { return $null }
    $picked = @{}
    foreach ($name in @($Environment)) { if (@($Choice[$name]).Count -gt 0) { $picked[$name] = @($Choice[$name])[0] } }
    [pscustomobject]@{ Mode = $script:dialogMode; Targets = $picked; MaxConcurrent = 2; MinFreeSpacePercent = 10 }
}
function Confirm-GuiMigration { param($Plan, $MaxConcurrent) $script:confirmAsked++; $script:confirmAnswer }
$busyTexts = New-Object System.Collections.Generic.List[string]
$messages = New-Object System.Collections.Generic.List[string]

function New-StubRulesRow([string]$Environment, [string]$Letters, [string]$Suffixes, [string]$DnsLabels, [string]$Keywords) {
    [pscustomobject]@{ IsNewRow = $false; Cells = @{
            Environment = [pscustomobject]@{ Value = $Environment }; Letters = [pscustomobject]@{ Value = $Letters }; NameSuffixes = [pscustomobject]@{ Value = $Suffixes }
            DnsLabels = [pscustomobject]@{ Value = $DnsLabels }; DatastoreKeywords = [pscustomobject]@{ Value = $Keywords } } }
}
function New-StubSelection([string[]]$Id) { @($Id | ForEach-Object { [pscustomobject]@{ Cells = @{ VMId = [pscustomobject]@{ Value = $_ } } } }) }
$rulesRows = @(
    (New-StubRulesRow 'PROD' 'p' '-P, -S' 'dpe, protected' 'SHARED')
    (New-StubRulesRow 'SIT' 't' '' 'dpesit, protectedsit' 'SIT')
    (New-StubRulesRow 'DEV' 'd' '' 'dpedev, protecteddev' 'DEV')
)
$clusterList = [pscustomobject]@{ Items = (New-Object System.Collections.ArrayList); SelectedIndex = -1; Enabled = $true }
$clusterList | Add-Member -MemberType ScriptProperty -Name SelectedItem -Value { if ($this.SelectedIndex -ge 0 -and $this.SelectedIndex -lt $this.Items.Count) { $this.Items[$this.SelectedIndex] } }
$password = [pscustomobject]@{ Text = 'secret'; TextLength = 6 }
$password | Add-Member -MemberType ScriptMethod -Name Clear -Value { $this.Text = ''; $this.TextLength = 0 }
$rulesGrid = [pscustomobject]@{ Rows = $rulesRows }
$rulesGrid | Add-Member -MemberType ScriptMethod -Name EndEdit -Value { $true }
$resultsTab = @{ Text = '' }; $unscopedTab = @{ Text = '' }; $datastoreTab = @{ Text = '' }; $migrationTab = @{ Text = '' }

$script:Gui = @{
    Server = [pscustomobject]@{ Text = ' vc.example ' }
    User = [pscustomobject]@{ Text = 'DPE\tester' }
    Password = $password
    ClusterList = $clusterList
    ConnectionLabel = [pscustomobject]@{ Text = '' }
    Status = [pscustomobject]@{ Text = '' }
    Pattern = [pscustomobject]@{ Text = $defaultPattern }
    FlagUnclassified = [pscustomobject]@{ Checked = $false }
    ShowUndetermined = [pscustomobject]@{ Checked = $true }
    ResultsGrid = [pscustomobject]@{ DataSource = $null; SelectedRows = @() }
    UnscopedGrid = [pscustomobject]@{ DataSource = $null; SelectedRows = @() }
    DatastoreGrid = [pscustomobject]@{ DataSource = $null }
    MigrationGrid = [pscustomobject]@{ DataSource = $null }
    ResultsTab = $resultsTab
    UnscopedTab = $unscopedTab
    DatastoreTab = $datastoreTab
    MigrationTab = $migrationTab
    Tabs = [pscustomobject]@{ SelectedTab = $resultsTab }
    RulesGrid = $rulesGrid
}
$script:GuiState = @{ Connection = $null; Inventory = $null; Result = $null; Migrations = $null; FindingById = @{}; Scope = ''; Busy = $false; Migrating = $false; StopRequested = $false
    ClusterViews = @{}; SuppliedCredential = $null; ScriptVersion = 'gui-test'; ExcludeTypes = @('VMFS'); MaxConcurrent = 2; MinFreePercent = 10 }

$world = New-World
Invoke-GuiAction { Invoke-GuiConnect } 6>$null
Assert-True "connect: no error shown" ($messages.Count -eq 0) ($messages.ToArray() -join ' | ')
Assert-True "connect: signs in to the trimmed server name" ($world.Calls.ToArray() -contains 'connect vc.example')
Assert-True "connect: password box cleared" ($password.TextLength -eq 0 -and $password.Text -eq '')
Assert-True "connect: cluster list is All plus each cluster, sorted" (($clusterList.Items.ToArray() -join ',') -eq '(All clusters),CL-DEV-01,CL-PROD-01')
Assert-True "connect: first real cluster preselected" ($clusterList.SelectedItem -eq 'CL-DEV-01')
Assert-True "connect: label names the account and cluster count" ($script:Gui.ConnectionLabel.Text -match 'DPE\\tester - 2 cluster')

# The 1.0.0 failure: ONE cluster selected, then Discover.
$clusterList.SelectedIndex = 2
$busyTexts.Clear(); $messages.Clear()
Invoke-GuiAction { Invoke-GuiDiscovery } 6>$null
Assert-True "discover one cluster: no error shown" ($messages.Count -eq 0) ($messages.ToArray() -join ' | ')
Assert-True "discover one cluster: progress reads 1 of 1" ($busyTexts.ToArray() -contains 'Discovering CL-PROD-01 (1 of 1)...') ($busyTexts.ToArray() -join ' | ')
Assert-True "discover one cluster: misplaced tab" ((Get-Names $script:GuiState.Result.Findings) -eq 'siepd85csd02,siepd85csp07' -and $resultsTab.Text -eq 'Misplaced VMs (2)')
Assert-True "discover one cluster: Not on PROD/SIT/DEV tab" ((Get-Names $script:GuiState.Result.Unscoped) -eq 'siepd85csp08' -and $unscopedTab.Text -eq 'Not on PROD/SIT/DEV (1)' -and $script:Gui.UnscopedGrid.DataSource.Rows.Count -eq 1)
Assert-True "discover one cluster: grids carry the hidden VMId" ($script:Gui.ResultsGrid.DataSource.Columns.Contains('VMId') -and $script:GuiState.FindingById.ContainsKey('vm-2') -and $script:GuiState.FindingById.ContainsKey('vm-8'))
Assert-True "discover one cluster: datastores tab leaves VMFS out" ($script:Gui.DatastoreGrid.DataSource.Rows.Count -eq 5 -and @($script:Gui.DatastoreGrid.DataSource.Rows | Where-Object { $_['Datastore'] -eq 'LOCAL_ESX01' }).Count -eq 0)
Assert-True "discover one cluster: status bar summarises - the stale-marked VM counted as a full VM" ($script:Gui.Status.Text -match '^CL-PROD-01: 1 cluster\(s\), 6 full VMs: 3 correct, 2 misplaced') $script:Gui.Status.Text
Assert-True "discover one cluster: the placeholder and the VMFS-only VM are counted as not shown" ($script:Gui.Status.Text -match '1 SRM placeholder\(s\), 0 with no disks, 1 only on VMFS datastores') $script:Gui.Status.Text

$clusterList.SelectedIndex = 0
$busyTexts.Clear(); $messages.Clear()
Invoke-GuiAction { Invoke-GuiDiscovery } 6>$null
Assert-True "discover all: no error shown" ($messages.Count -eq 0) ($messages.ToArray() -join ' | ')
Assert-True "discover all: progress reads 1 of 2, 2 of 2" ((@($busyTexts.ToArray() | Where-Object { $_ -like 'Discovering*' }) -join ' | ') -eq 'Discovering CL-DEV-01 (1 of 2)... | Discovering CL-PROD-01 (2 of 2)...')
Assert-True "discover all: both clusters' misplaced VMs, the -P one included" ((Get-Names $script:GuiState.Result.Findings) -eq 'siepd85csd02,siepd85csp03,siepd85csp07,SQLCLUSTER01-P')

# Re-apply after editing the grid: letter p moved to DEV. No vCenter read.
$viewCallsBefore = $world.ViewCalls
$rulesRows[0].Cells.Letters.Value = ''
$rulesRows[2].Cells.Letters.Value = 'd, p'
$messages.Clear()
Invoke-GuiAction { Invoke-GuiEvaluation } 6>$null
Assert-True "re-apply: no error shown" ($messages.Count -eq 0) ($messages.ToArray() -join ' | ')
Assert-True "re-apply: p VMs on DEV are now correct, p VMs on SHARED now wrong; the -P suffix still says PROD" ((Get-Names $script:GuiState.Result.Findings) -eq 'siepd85csd02,siepd85csp06,siepd85csp10,SQLCLUSTER01-P')
Assert-True "re-apply: vCenter was not read again" ($world.ViewCalls -eq $viewCallsBefore)

$rulesRows[0].Cells.Letters.Value = 'p'
$messages.Clear()
Invoke-GuiAction { Invoke-GuiEvaluation } 6>$null 3>$null
Assert-True "re-apply bad rules: refused with a message" ($messages.Count -eq 1 -and $messages[0] -match "'p' is mapped to both PROD and DEV")
Assert-True "re-apply bad rules: status says it failed" ($script:Gui.Status.Text -eq 'Failed - see the Log tab.')
Assert-True "re-apply bad rules: last result kept" ($script:GuiState.Result.Findings.Count -eq 4)
$rulesRows[2].Cells.Letters.Value = 'd'
Invoke-GuiAction { Invoke-GuiEvaluation } 6>$null

$script:GuiState.Busy = $true
$ran = $false
Invoke-GuiAction { $script:ran = $true }
Assert-True "a click while busy does not start a second run" (-not $ran)
$script:GuiState.Busy = $false

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== GUI migration ===" -ForegroundColor Cyan
$script:confirmAsked = 0
$script:Gui.Tabs.SelectedTab = $datastoreTab
$messages.Clear()
Invoke-GuiAction { Invoke-GuiMigration } 6>$null 3>$null
Assert-True "from the wrong tab: told which tabs to use" ($messages.Count -eq 1 -and $messages[0] -match 'Open the Misplaced VMs or Not on PROD/SIT/DEV tab')

$script:Gui.Tabs.SelectedTab = $resultsTab
$script:Gui.ResultsGrid.SelectedRows = @()
$messages.Clear()
Invoke-GuiAction { Invoke-GuiMigration } 6>$null 3>$null
Assert-True "nothing selected: told to select" ($messages.Count -eq 1 -and $messages[0] -match 'Select one or more VMs')

$script:dialogMode = $null
$messages.Clear()
Invoke-GuiAction { Invoke-GuiMigration -All } 6>$null
Assert-True "dialog: offered PROD and DEV, in rule order" ((@($script:dialogSeen.Environment) -join ',') -eq 'PROD,DEV')
Assert-True "dialog: PROD choices - the datastore cluster, then the NFS datastore; VMFS never offered" ((@($script:dialogSeen.Choice['PROD'] | ForEach-Object { $_.Name }) -join ',') -eq 'DSC_SHARED_01,NFS_SHARED_01')
Assert-True "dialog: DEV choices" ((@($script:dialogSeen.Choice['DEV'] | ForEach-Object { $_.Name }) -join ',') -eq 'NFS_DEV_01,NFS_DEV_02')
Assert-True "dialog: counts per environment" ($script:dialogSeen.Count['PROD'] -eq 3 -and $script:dialogSeen.Count['DEV'] -eq 1)
Assert-True "dialog cancelled: nothing happens" ($world.Moves.Count -eq 0 -and $null -eq $script:GuiState.Migrations -and $messages.Count -eq 0)

$script:dialogMode = 'Preview'
$messages.Clear()
Invoke-GuiAction { Invoke-GuiMigration -All } 6>$null
Assert-True "preview: nothing moved, nothing asked" ($world.Moves.Count -eq 0 -and $script:confirmAsked -eq 0)
Assert-True "preview: Migrations tab shows the plan" ($migrationTab.Text -eq 'Migrations (4)' -and $script:Gui.MigrationGrid.DataSource.Rows.Count -eq 4 -and [object]::ReferenceEquals($script:Gui.Tabs.SelectedTab, $migrationTab))
Assert-True "preview: two would move, two skipped with the reason" ((Get-Names @($script:GuiState.Migrations | Where-Object { $_.Result -eq 'WhatIf' })) -eq 'siepd85csd02,siepd85csp07' -and @($script:GuiState.Migrations | Where-Object { $_.Result -eq 'Skipped' -and $_.Detail -match 'not mounted on esx02' }).Count -eq 2)
Assert-True "preview: says nothing was changed" ($messages.Count -eq 1 -and $messages[0] -match 'Preview only - nothing was changed')

$script:Gui.Tabs.SelectedTab = $resultsTab
$script:dialogMode = 'Migrate'
$script:confirmAnswer = $false
$messages.Clear()
Invoke-GuiAction { Invoke-GuiMigration -All } 6>$null
Assert-True "migrate, then No at the confirmation: nothing moved" ($script:confirmAsked -eq 1 -and $world.Moves.Count -eq 0)

$script:WhatIfRun = $true
$script:confirmAsked = 0
Invoke-GuiAction { Invoke-GuiMigration -All } 6>$null
Assert-True "started with -WhatIf: Migrate is forced to a preview, never asked, nothing moved" ($script:dialogSeen.WhatIfOnly -eq $true -and $script:confirmAsked -eq 0 -and $world.Moves.Count -eq 0)
$script:WhatIfRun = $false

$script:Gui.Tabs.SelectedTab = $resultsTab
$script:Gui.ResultsGrid.SelectedRows = New-StubSelection 'vm-2'
$script:confirmAnswer = $true
$viewCallsBefore = $world.ViewCalls
$messages.Clear()
Invoke-GuiAction { Invoke-GuiMigration } 6>$null
Assert-True "migrate selected: only the selected VM moves, to DEV" (($world.Moves.ToArray() -join ',') -eq 'vm-2->ds-2')
Assert-True "migrate selected: result Migrated" ((@($script:GuiState.Migrations | ForEach-Object { "$($_.VMName)=$($_.Result)" }) -join ',') -eq 'siepd85csd02=Migrated')
Assert-True "migrate selected: the cluster is re-discovered and the VM is gone from the list" ($world.ViewCalls -gt $viewCallsBefore -and (Get-Names $script:GuiState.Result.Findings) -eq 'siepd85csp03,siepd85csp07,SQLCLUSTER01-P')
Assert-True "migrate selected: not left in a migrating state" (-not $script:GuiState.Migrating)

$script:Gui.Tabs.SelectedTab = $unscopedTab
$messages.Clear()
Invoke-GuiAction { Invoke-GuiMigration -All } 6>$null
Assert-True "migrate all from the Not on PROD/SIT/DEV tab: the VM on NFS_MISC_01 goes to the SHARED datastore cluster" ($world.Moves.ToArray()[-1] -eq 'vm-8->group-p1')
Assert-True "  and that tab is now empty" ($script:GuiState.Result.Unscoped.Count -eq 0 -and $unscopedTab.Text -eq 'Not on PROD/SIT/DEV (0)')

$script:Gui.Tabs.SelectedTab = $resultsTab
$world.FailTask['vm-7'] = $true
$messages.Clear()
Invoke-GuiAction { Invoke-GuiMigration -All } 6>$null 3>$null
Assert-True "a failed move is reported as a warning, and the VM stays listed" ($messages.Count -eq 1 -and $messages[0] -match '^Warning: 0 VM\(s\) migrated, 1 failed' -and (Get-Names $script:GuiState.Result.Findings) -eq 'siepd85csp03,siepd85csp07,SQLCLUSTER01-P')

$script:Gui.Tabs.SelectedTab = $migrationTab
$active = Get-GuiActiveTable
Assert-True "export from the Migrations tab exports the migration rows" ($active.Name -eq 'Migrations' -and @($active.Row).Count -eq 3 -and ($active.Column -join ',') -eq ((Get-PlacementMigrationColumn) -join ','))

$world.Calls.Clear()
Invoke-GuiAction { Invoke-GuiDisconnect } 6>$null
Assert-True "disconnect: signs out and empties the cluster list" (($world.Calls.ToArray() -join ',') -eq 'disconnect vc.example' -and $clusterList.Items.Count -eq 0 -and $null -eq $script:GuiState.Connection)
Assert-True "disconnect: results stay exportable" ($null -ne $script:GuiState.Result)
$messages.Clear()
Invoke-GuiAction { Invoke-GuiMigration -All } 6>$null 3>$null
Assert-True "disconnected: migration refused" ($messages.Count -eq 1 -and $messages[0] -match 'Connect to vCenter first')

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
