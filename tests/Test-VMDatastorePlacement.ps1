<#
.SYNOPSIS
    Tests the placement logic in Test-VMDatastorePlacement.ps1: which environment a VM belongs to,
    which environment a datastore belongs to, and what gets reported.

.DESCRIPTION
    Extracts the pure functions from the script by AST and drives them with plain objects shaped
    like the vSphere views and inventory records - so it covers DNS-label matching, the siepdXXxxL
    hostname fallback, letter remapping (the "add b to DEV and rediscover" case), datastore keyword
    boundaries, multi-datastore VMs, the skip rules and the CSV export.

    Also runs the script itself for the argument checks that happen before any connection.

    Deliberately standalone - no Pester, no PowerCLI, no vCenter.

.EXAMPLE
    pwsh -File ./tests/Test-VMDatastorePlacement.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vsphere/Test-VMDatastorePlacement.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors in $scriptPath" }

$wanted = @('Write-PlacementLog', 'Split-RuleValue', 'ConvertTo-PlacementRuleSet', 'Get-DatastoreEnvironment',
            'Get-DnsEnvironment', 'Get-HostnameEnvironment', 'Resolve-VMExpectedEnvironment', 'Get-PlacementReportColumn',
            'Test-VMPlacement', 'Invoke-PlacementEvaluation', 'Format-PlacementSummary', 'Export-PlacementReport',
            'Get-ViewProperty', 'Get-DatastoreNameFromPath', 'ConvertTo-PlacementVMRecord', 'ConvertTo-PlacementDataTable',
            'Connect-PlacementVCenter', 'Disconnect-PlacementVCenter', 'Get-PlacementClusterList', 'Get-ClusterPlacementInventory',
            'Invoke-GuiAction', 'Get-GuiRuleDefinition', 'Invoke-GuiConnect', 'Invoke-GuiDisconnect', 'Invoke-GuiDiscovery', 'Invoke-GuiEvaluation')
$funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name })
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red }
}

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
    param([string]$ProdLetters = 'p', [string]$SitLetters = 't', [string]$DevLetters = 'd')
    @(
        [pscustomobject]@{ Environment = 'PROD'; Letters = $ProdLetters; DnsLabels = ((Get-DefaultValue 'ProdDnsLabels') -join ', '); DatastoreKeywords = ((Get-DefaultValue 'ProdDatastoreKeywords') -join ', ') }
        [pscustomobject]@{ Environment = 'SIT'; Letters = $SitLetters; DnsLabels = ((Get-DefaultValue 'SitDnsLabels') -join ', '); DatastoreKeywords = ((Get-DefaultValue 'SitDatastoreKeywords') -join ', ') }
        [pscustomobject]@{ Environment = 'DEV'; Letters = $DevLetters; DnsLabels = ((Get-DefaultValue 'DevDnsLabels') -join ', '); DatastoreKeywords = ((Get-DefaultValue 'DevDatastoreKeywords') -join ', ') }
    )
}
$rules = ConvertTo-PlacementRuleSet -Definition (New-Definition) -HostnamePattern $defaultPattern

function New-VM {
    param([string]$Name, [string]$Dns = '', [string[]]$Datastore, [string]$Type = 'NFS')
    [pscustomobject]@{
        Cluster = 'CL01'; VMName = $Name; DnsName = $Dns; PowerState = 'poweredOn'; ToolsStatus = 'guestToolsRunning'
        EsxiHost = 'esx01'; vCenter = 'vc01'; DiscoveredAt = [datetime]'2026-10-12 09:00'
        Datastores = @($Datastore | ForEach-Object { [pscustomobject]@{ Name = $_; Type = $Type } })
    }
}
function Get-Outcome { param($Vm, $RuleSet = $rules, [switch]$NfsOnly, [switch]$Flag, [switch]$Hide)
    Test-VMPlacement -Record $Vm -RuleSet $RuleSet -NfsOnly:$NfsOnly -FlagUnclassifiedDatastores:$Flag -HideUndetermined:$Hide -ScriptVersion 'test'
}

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Defaults match the requirement ===" -ForegroundColor Cyan
Assert-True "PROD letters default to p" ((Get-DefaultValue 'ProdLetters') -join ',' -eq 'p')
Assert-True "SIT letters default to t" ((Get-DefaultValue 'SitLetters') -join ',' -eq 't')
Assert-True "DEV letters default to d" ((Get-DefaultValue 'DevLetters') -join ',' -eq 'd')
Assert-True "PROD DNS labels are dpe, protected" ((Get-DefaultValue 'ProdDnsLabels') -join ',' -eq 'dpe,protected')
Assert-True "SIT DNS labels are dpesit, protectedsit" ((Get-DefaultValue 'SitDnsLabels') -join ',' -eq 'dpesit,protectedsit')
Assert-True "DEV DNS labels are dpedev, protecteddev" ((Get-DefaultValue 'DevDnsLabels') -join ',' -eq 'dpedev,protecteddev')

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
Write-Host "`n=== Datastore classification ===" -ForegroundColor Cyan
$cases = @(
    @{ Name = 'NFS_PROD_01'; Expect = 'PROD' }
    @{ Name = 'nfs-prod-02'; Expect = 'PROD' }
    @{ Name = 'SIEPD85PROD01'; Expect = 'PROD' }
    @{ Name = 'PROD'; Expect = 'PROD' }
    @{ Name = 'NFS_SIT_01'; Expect = 'SIT' }
    @{ Name = 'NFS_DEV_01'; Expect = 'DEV' }
    @{ Name = 'SITE2_PROD_01'; Expect = 'PROD' }
    @{ Name = 'SITE2_DS01'; Expect = '' }
    @{ Name = 'DEVICE_STORE'; Expect = '' }
    @{ Name = 'ISO_LIBRARY'; Expect = '' }
    @{ Name = 'NFS_PROD_DEV_MIGRATE'; Expect = 'AMBIGUOUS' }
)
foreach ($case in $cases) {
    $r = Get-DatastoreEnvironment -Name $case.Name -Type 'NFS' -RuleSet $rules
    Assert-True "'$($case.Name)' is '$($case.Expect)'" ($r.Environment -eq $case.Expect) "got '$($r.Environment)'"
}
Assert-True "-NfsOnly leaves a VMFS PROD datastore out" ((Get-DatastoreEnvironment -Name 'VMFS_PROD_01' -Type 'VMFS' -RuleSet $rules -NfsOnly).Environment -eq '')
Assert-True "-NfsOnly keeps NFS 4.1" ((Get-DatastoreEnvironment -Name 'NFS_PROD_01' -Type 'NFS41' -RuleSet $rules -NfsOnly).Environment -eq 'PROD')
Assert-True "without -NfsOnly a VMFS PROD datastore counts" ((Get-DatastoreEnvironment -Name 'VMFS_PROD_01' -Type 'VMFS' -RuleSet $rules).Environment -eq 'PROD')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== What is reported - and what is not ===" -ForegroundColor Cyan
$o = Get-Outcome (New-VM 'siepd85csp1000' 'siepd85csp1000.dpe.protected.mil.au' 'NFS_PROD_01')
Assert-True "PROD VM on PROD datastore is not reported" ($o.Outcome -eq 'Correct')
$o = Get-Outcome (New-VM 'siepd85csp1000' 'siepd85csp1000.dpe.protected.mil.au' 'NFS_DEV_01')
Assert-True "PROD VM (by DNS) on DEV datastore is reported" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Wrong datastore' -and $o.Finding.ExpectedEnvironment -eq 'PROD')
Assert-True "  the report names the offending datastore" ($o.Finding.WrongDatastores -eq 'NFS_DEV_01 (DEV)')
$o = Get-Outcome (New-VM 'siepd85cst01' 'h.dpesit.protectedsit.mil.au' 'NFS_SIT_01')
Assert-True "SIT VM on SIT datastore is not reported" ($o.Outcome -eq 'Correct')
$o = Get-Outcome (New-VM 'siepd85cst01' '' 'NFS_PROD_01')
Assert-True "SIT VM (by name) on PROD datastore is reported" ($o.Outcome -eq 'Reported' -and $o.Finding.DeterminedBy -eq 'VM name' -and $o.Finding.HostnameLetter -eq 't')
$o = Get-Outcome (New-VM 'siepd85csd01' '' 'NFS_DEV_01')
Assert-True "DEV VM (by name) on DEV datastore is not reported" ($o.Outcome -eq 'Correct')
$o = Get-Outcome (New-VM 'siepd85csp01' '' @('NFS_PROD_01', 'NFS_DEV_02'))
Assert-True "a disk on the wrong datastore is enough to report" ($o.Outcome -eq 'Reported' -and $o.Finding.WrongDatastores -eq 'NFS_DEV_02 (DEV)' -and $o.Finding.DatastoreEnvironment -eq 'PROD, DEV')
$o = Get-Outcome (New-VM 'siepd85csp01' '' @('NFS_PROD_01', 'ISO_LIBRARY'))
Assert-True "an unclassified second datastore is ignored by default" ($o.Outcome -eq 'Correct')
$o = Get-Outcome (New-VM 'siepd85csp01' '' @('NFS_PROD_01', 'ISO_LIBRARY')) -Flag
Assert-True "  and reported with -FlagUnclassifiedDatastores" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -match '^Not on a ')
$o = Get-Outcome (New-VM 'siepd85csp01' '' 'LOCAL_ESX01')
Assert-True "a VM on no PROD/SIT/DEV datastore is out of scope" ($o.Outcome -eq 'OutOfScope')
$o = Get-Outcome (New-VM 'siepd85csp01' '' 'NFS_PROD_DEV_MIGRATE')
Assert-True "an ambiguous datastore name is reported" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Ambiguous datastore name')
$o = Get-Outcome (New-VM 'vcenter01' '' 'NFS_PROD_01')
Assert-True "undetermined VM on a PROD datastore is reported by default" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Environment undetermined')
$o = Get-Outcome (New-VM 'vcenter01' '' 'NFS_PROD_01') -Hide
Assert-True "  and hidden with -HideUndetermined" ($o.Outcome -eq 'Hidden')
$o = Get-Outcome (New-VM 'VMFS_ONLY_VM' '' 'VMFS_PROD_01' -Type 'VMFS') -NfsOnly
Assert-True "with -NfsOnly, a VM only on VMFS is out of scope" ($o.Outcome -eq 'OutOfScope')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Add 'b' to DEV and re-apply ===" -ForegroundColor Cyan
$bOnDev = New-VM 'siepd85csb01' '' 'NFS_DEV_01'
$bOnProd = New-VM 'siepd85csb02' '' 'NFS_PROD_01'
$o = Get-Outcome $bOnDev
Assert-True "before: letter b is reported as unmapped" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Unmapped hostname letter')
$o = Get-Outcome $bOnDev -Hide
Assert-True "before: unmapped letters are reported even with -HideUndetermined" ($o.Outcome -eq 'Reported')
$withB = ConvertTo-PlacementRuleSet -Definition (New-Definition -DevLetters 'd, b') -HostnamePattern $defaultPattern
$o = Get-Outcome $bOnDev -RuleSet $withB
Assert-True "after: b VM on DEV datastore is no longer reported" ($o.Outcome -eq 'Correct')
$o = Get-Outcome $bOnProd -RuleSet $withB
Assert-True "after: b VM on PROD datastore is reported as wrong, expected DEV" ($o.Outcome -eq 'Reported' -and $o.Finding.Status -eq 'Wrong datastore' -and $o.Finding.ExpectedEnvironment -eq 'DEV')
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
$dupKeyword = New-Definition; $dupKeyword[2].DatastoreKeywords = 'DEV, prod'
Assert-True "a datastore keyword in two environments" ((Get-RuleError $dupKeyword) -match "'prod' is mapped to both PROD and DEV")
$noKeyword = New-Definition; $noKeyword[1].DatastoreKeywords = ''
Assert-True "an environment with no datastore keyword" ((Get-RuleError $noKeyword) -match 'SIT has no datastore keyword')
Assert-True "a pattern without an env group" ((Get-RuleError (New-Definition) '^siepd\d{2}[a-z]{3}') -match "group named 'env'")
Assert-True "an invalid regex" ((Get-RuleError (New-Definition) '^siepd(?<env>[a-z]') -match 'not a valid regular expression')
Assert-True "several problems are listed together" (((Get-RuleError (New-Definition -DevLetters 'db, p')) -split "`n").Count -ge 3)
Assert-True "the defaults are valid" ((Get-RuleError (New-Definition)) -eq '')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== vSphere view -> record ===" -ForegroundColor Cyan
$byRef = @{
    'datastore-1' = [pscustomobject]@{ Name = 'NFS_PROD_01'; Type = 'NFS' }
    'datastore-2' = [pscustomobject]@{ Name = 'NFS_DEV_01'; Type = 'NFS' }
    'datastore-3' = [pscustomobject]@{ Name = 'ISO_LIBRARY'; Type = 'NFS' }
}
$byName = @{}; foreach ($v in $byRef.Values) { $byName[$v.Name] = $v }
function New-Disk { param($Ref, $File)
    [pscustomobject]@{ PSTypeName = 'VMware.Vim.VirtualDisk'; Backing = [pscustomobject]@{ FileName = $File; Datastore = $(if ($Ref) { [pscustomobject]@{ Value = $Ref } } else { $null }) } }
}
function New-View { param($Name, $Template = $false, $ManagedBy = $null, $VmPath = '', $Devices = @(), $Datastore = @(), $HostName = '')
    [pscustomobject]@{
        Name = $Name
        Config = [pscustomobject]@{
            Template = $Template
            ManagedBy = $(if ($ManagedBy) { [pscustomobject]@{ ExtensionKey = $ManagedBy; Type = 'x' } } else { $null })
            Files = [pscustomobject]@{ VmPathName = $VmPath }
            Hardware = [pscustomobject]@{ Device = $Devices }
        }
        Guest = [pscustomobject]@{ HostName = $HostName; ToolsRunningStatus = 'guestToolsRunning' }
        Runtime = [pscustomobject]@{ PowerState = 'poweredOn'; Host = [pscustomobject]@{ Value = 'host-1' } }
        Datastore = $Datastore
    }
}
$cdrom = [pscustomobject]@{ PSTypeName = 'VMware.Vim.VirtualCdrom'; Backing = [pscustomobject]@{ FileName = '[ISO_LIBRARY] rhel.iso'; Datastore = [pscustomobject]@{ Value = 'datastore-3' } } }
$view = New-View -Name 'siepd85csp01' -VmPath '[NFS_PROD_01] siepd85csp01/siepd85csp01.vmx' -HostName 'siepd85csp01.dpe.protected.mil.au' -Devices @(
    (New-Disk 'datastore-1' '[NFS_PROD_01] siepd85csp01/siepd85csp01.vmdk'),
    (New-Disk 'datastore-2' '[NFS_DEV_01] siepd85csp01/siepd85csp01_1.vmdk'),
    $cdrom)
$c = ConvertTo-PlacementVMRecord -View $view -DatastoreByRef $byRef -DatastoreByName $byName -HostByRef @{ 'host-1' = 'esx01.example' } -Cluster 'CL01' -VCenter 'vc01'
$names = @($c.Record.Datastores | ForEach-Object { $_.Name })
Assert-True "home and every disk datastore, home first, no duplicates" (($names -join ',') -eq 'NFS_PROD_01,NFS_DEV_01') "got $($names -join ',')"
Assert-True "a mounted ISO's datastore is not counted" ($names -notcontains 'ISO_LIBRARY')
Assert-True "DNS name, host and cluster are carried" ($c.Record.DnsName -eq 'siepd85csp01.dpe.protected.mil.au' -and $c.Record.EsxiHost -eq 'esx01.example' -and $c.Record.Cluster -eq 'CL01')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 't1' -Template $true) -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a template is skipped" ($c.Skip -eq 'Template')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'siepd85csp01' -ManagedBy 'com.vmware.vcDr' -VmPath '[NFS_PROD_01] x/x.vmx') -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "an SRM placeholder is skipped" ($c.Skip -eq 'Placeholder')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'vCLS-1234' -VmPath '[NFS_DEV_01] vCLS/vCLS.vmx') -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a vCLS VM is skipped" ($c.Skip -eq 'Agent')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'nsx-agent' -ManagedBy 'com.vmware.vim.eam') -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "an ESX Agent Manager VM is skipped" ($c.Skip -eq 'Agent')
$c = ConvertTo-PlacementVMRecord -View (New-View -Name 'x' -VmPath '[NFS_UNKNOWN] x/x.vmx' -Devices @((New-Disk $null '[NFS_DEV_01] x/x.vmdk'))) -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a datastore is found by name when the backing has no reference" (@($c.Record.Datastores | ForEach-Object { $_.Name }) -contains 'NFS_DEV_01')
Assert-True "an unknown home datastore is kept with type Unknown" (@($c.Record.Datastores | Where-Object { $_.Name -eq 'NFS_UNKNOWN' -and $_.Type -eq 'Unknown' }).Count -eq 1)
$orphan = [pscustomobject]@{ Name = 'orphan'; Config = $null; Guest = $null; Runtime = $null; Datastore = @([pscustomobject]@{ Value = 'datastore-2' }) }
$c = ConvertTo-PlacementVMRecord -View $orphan -DatastoreByRef $byRef -DatastoreByName $byName
Assert-True "a VM with no config falls back to its datastore list" ($c.Skip -eq '' -and (@($c.Record.Datastores | ForEach-Object { $_.Name }) -join ',') -eq 'NFS_DEV_01')

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Cluster evaluation and CSV ===" -ForegroundColor Cyan
$inventory = @([pscustomobject]@{
    Cluster = 'CL01'; vCenter = 'vc01'; DiscoveredAt = Get-Date
    Datastores = @([pscustomobject]@{ Name = 'NFS_PROD_01'; Type = 'NFS' }, [pscustomobject]@{ Name = 'NFS_DEV_01'; Type = 'NFS' }, [pscustomobject]@{ Name = 'LOCAL_ESX01'; Type = 'VMFS' })
    VMs = @(
        (New-VM 'siepd85csp01' 'siepd85csp01.dpe.protected.mil.au' 'NFS_PROD_01'),
        (New-VM 'siepd85csp02' '' 'NFS_DEV_01'),
        (New-VM 'siepd85csd01' '' 'NFS_DEV_01'),
        (New-VM 'siepd85csb01' '' 'NFS_DEV_01'),
        (New-VM 'vcenter01' '' 'NFS_PROD_01'),
        (New-VM 'siepd85csp03' '' 'LOCAL_ESX01' -Type 'VMFS'))
    SkippedTemplates = 2; SkippedAgents = 3; SkippedPlaceholders = 4
})
$result = Invoke-PlacementEvaluation -Inventory $inventory -RuleSet $rules -ScriptVersion '9.9.9'
$s = $result.Summary
Assert-True "6 VMs: 2 correct, 3 reported, 1 out of scope" ($s.VMs -eq 6 -and $s.Correct -eq 2 -and $s.Reported -eq 3 -and $s.OutOfScope -eq 1) "got $($s.VMs)/$($s.Correct)/$($s.Reported)/$($s.OutOfScope)"
Assert-True "skips are carried into the summary" ($s.SkippedTemplates -eq 2 -and $s.SkippedAgents -eq 3 -and $s.SkippedPlaceholders -eq 4)
Assert-True "only the misplaced VMs are reported" ((@($result.Findings | ForEach-Object { $_.VMName } | Sort-Object) -join ',') -eq 'siepd85csb01,siepd85csp02,vcenter01')
Assert-True "every row carries the script version" (@($result.Findings | Where-Object { $_.ScriptVersion -ne '9.9.9' }).Count -eq 0)
$dsRow = @($result.Datastores | Where-Object { $_.Datastore -eq 'NFS_DEV_01' })
Assert-True "Datastores tab classifies and counts VMs" ($dsRow.Count -eq 1 -and $dsRow[0].Environment -eq 'DEV' -and $dsRow[0].VMs -eq 3)
Assert-True "summary line reads cleanly" ((Format-PlacementSummary -Summary $s) -match '^1 cluster\(s\), 6 VMs: 2 correct, 3 reported \(')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("placement-" + [Guid]::NewGuid().ToString('N'))
$csv = Join-Path $tmp 'sub/report.csv'
Export-PlacementReport -Finding $result.Findings -Path $csv 6>$null
$back = @(Import-Csv -Path $csv)
Assert-True "CSV round-trips every reported row" ($back.Count -eq 3)
Assert-True "CSV columns are in the declared order" ((($back[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ',') -eq ((Get-PlacementReportColumn) -join ','))
$empty = Join-Path $tmp 'empty.csv'
Export-PlacementReport -Finding @() -Path $empty 6>$null
Assert-True "an empty result still writes the header row" ((Get-Content -Path $empty -Raw).Trim() -eq ((@(Get-PlacementReportColumn) | ForEach-Object { '"' + $_ + '"' }) -join ','))
Remove-Item -Path $tmp -Recurse -Force

$table = ConvertTo-PlacementDataTable -Row $result.Findings -Column @(Get-PlacementReportColumn)
Assert-True "grid table has a row per finding" ($table.Rows.Count -eq 3 -and $table.Columns.Count -eq @(Get-PlacementReportColumn).Count)
$table = ConvertTo-PlacementDataTable -Row @() -Column @('Cluster', 'VMs')
Assert-True "an empty grid table still has its columns" ($table.Rows.Count -eq 0 -and $table.Columns.Count -eq 2)

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Argument checks before any connection ===" -ForegroundColor Cyan
function Get-RunError { param([hashtable]$Arguments)
    try { & $scriptPath @Arguments 6>$null 2>$null 3>$null; '' } catch { $_.Exception.Message }
}
Assert-True "-NoGui without -Server is refused" ((Get-RunError @{ NoGui = $true }) -match '-Server is required')
Assert-True "bad -DevLetters are refused before a sign-in prompt" ((Get-RunError @{ NoGui = $true; Server = 'vc.example'; DevLetters = @('d', 'p') }) -match "'p' is mapped to both PROD and DEV")
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Assert-True "the GUI refuses to start off Windows" ((Get-RunError @{}) -match 'needs Windows')
}

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== Headless run end to end, against stubbed PowerCLI ===" -ForegroundColor Cyan
# Stand-ins for the four PowerCLI calls the script makes. Get-View answers the exact shapes of
# request the script sends: clusters by type, then cluster/datastores/hosts by Id, then VMs under
# the cluster. Anything else throws, so a new kind of call cannot slip through unstubbed.
function New-Ref([string]$Type, [string]$Value) { [pscustomobject]@{ Type = $Type; Value = $Value } }
$stub = @{
    Clusters = @(
        [pscustomobject]@{ Name = 'CL-PROD-01'; MoRef = (New-Ref 'ClusterComputeResource' 'domain-c1'); Datastore = @((New-Ref 'Datastore' 'datastore-1'), (New-Ref 'Datastore' 'datastore-2')); Host = @((New-Ref 'HostSystem' 'host-1')) }
        [pscustomobject]@{ Name = 'CL-DEV-01'; MoRef = (New-Ref 'ClusterComputeResource' 'domain-c2'); Datastore = @((New-Ref 'Datastore' 'datastore-2')); Host = @((New-Ref 'HostSystem' 'host-2')) }
    )
    Datastores = @(
        [pscustomobject]@{ Name = 'NFS_PROD_01'; MoRef = (New-Ref 'Datastore' 'datastore-1'); Summary = [pscustomobject]@{ Type = 'NFS' } }
        [pscustomobject]@{ Name = 'NFS_DEV_01'; MoRef = (New-Ref 'Datastore' 'datastore-2'); Summary = [pscustomobject]@{ Type = 'NFS' } }
    )
    Hosts = @(
        [pscustomobject]@{ Name = 'esx01'; MoRef = (New-Ref 'HostSystem' 'host-1') }
        [pscustomobject]@{ Name = 'esx02'; MoRef = (New-Ref 'HostSystem' 'host-2') }
    )
    VMs = @{
        'domain-c1' = @(
            ((New-View -Name 'siepd85csp01' -VmPath '[NFS_PROD_01] a/a.vmx' -HostName 'siepd85csp01.dpe.protected.mil.au' -Devices @((New-Disk 'datastore-1' '[NFS_PROD_01] a/a.vmdk'))) | Add-Member -NotePropertyName MoRef -NotePropertyValue (New-Ref 'VirtualMachine' 'vm-1') -PassThru)
            ((New-View -Name 'siepd85csd02' -VmPath '[NFS_PROD_01] b/b.vmx' -Devices @((New-Disk 'datastore-1' '[NFS_PROD_01] b/b.vmdk'))) | Add-Member -NotePropertyName MoRef -NotePropertyValue (New-Ref 'VirtualMachine' 'vm-2') -PassThru)
            ((New-View -Name 'vCLS-01' -VmPath '[NFS_DEV_01] v/v.vmx') | Add-Member -NotePropertyName MoRef -NotePropertyValue (New-Ref 'VirtualMachine' 'vm-3') -PassThru)
        )
        'domain-c2' = @(
            ((New-View -Name 'siepd85csp03' -VmPath '[NFS_DEV_01] c/c.vmx' -Devices @((New-Disk 'datastore-2' '[NFS_DEV_01] c/c.vmdk'))) | Add-Member -NotePropertyName MoRef -NotePropertyValue (New-Ref 'VirtualMachine' 'vm-4') -PassThru)
        )
    }
    Calls = New-Object System.Collections.Generic.List[string]
    ViewCalls = 0
}
function Connect-VIServer { param($Server, $Credential) $stub.Calls.Add("connect $Server"); [pscustomobject]@{ Name = $Server; Version = '8.0.3'; Build = '1'; User = 'DPE\tester' } }
function Disconnect-VIServer { param($Server, [switch]$Confirm) $stub.Calls.Add("disconnect $($Server.Name)") }
function Get-View {
    param($Server, $ViewType, $Id, $SearchRoot, $Property)
    $stub.ViewCalls = $stub.ViewCalls + 1
    if ($ViewType -eq 'ClusterComputeResource') { return $stub.Clusters }
    if ($ViewType -eq 'VirtualMachine') { return $stub.VMs[$SearchRoot.Value] }
    if ($null -ne $Id) {
        foreach ($ref in @($Id)) {
            $all = @($stub.Clusters) + @($stub.Datastores) + @($stub.Hosts)
            $hit = @($all | Where-Object { $_.MoRef.Value -eq $ref.Value })
            if ($hit.Count -ne 1) { throw "stub Get-View: unknown Id $($ref.Value)" }
            $hit[0]
        }
        return
    }
    throw "stub Get-View: unexpected call"
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("placement-" + [Guid]::NewGuid().ToString('N'))
$csv = Join-Path $tmp 'run.csv'
$cred = New-Object System.Management.Automation.PSCredential('DPE\tester', (New-Object System.Security.SecureString))
$rows = @(& $scriptPath -NoGui -Server 'vc.example' -Credential $cred -OutputPath $csv 6>$null)
Assert-True "all clusters: two misplaced VMs output" ((@($rows | ForEach-Object { "$($_.Cluster)/$($_.VMName)" } | Sort-Object) -join ',') -eq 'CL-DEV-01/siepd85csp03,CL-PROD-01/siepd85csd02') "got $(@($rows | ForEach-Object { $_.VMName }) -join ',')"
Assert-True "the PROD VM on PROD by DNS is not reported" (@($rows | Where-Object { $_.VMName -eq 'siepd85csp01' }).Count -eq 0)
Assert-True "the vCLS VM is not reported" (@($rows | Where-Object { $_.VMName -like 'vCLS*' }).Count -eq 0)
Assert-True "the CSV holds the same rows" (@(Import-Csv -Path $csv).Count -eq 2)
Assert-True "connected once and disconnected once" (($stub.Calls.ToArray() -join ',') -eq 'connect vc.example,disconnect vc.example') "got $($stub.Calls.ToArray() -join ',')"

$stub.Calls.Clear()
$rows = @(& $scriptPath -NoGui -Server 'vc.example' -Credential $cred -Cluster 'CL-DEV-*' -OutputPath $csv 6>$null)
Assert-True "-Cluster with a wildcard discovers only that cluster" ((@($rows | ForEach-Object { $_.Cluster } | Sort-Object -Unique) -join ',') -eq 'CL-DEV-01')

$stub.Calls.Clear()
$message = try { & $scriptPath -NoGui -Server 'vc.example' -Credential $cred -Cluster 'NOPE' -OutputPath $csv 6>$null 2>$null; '' } catch { $_.Exception.Message }
Assert-True "an unknown cluster names the clusters that do exist" ($message -match 'CL-DEV-01, CL-PROD-01')
Assert-True "  and still disconnects" ($stub.Calls.ToArray() -contains 'disconnect vc.example')
Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------------------------
Write-Host "`n=== GUI flow - connect, discover, re-apply, disconnect - with stand-in controls ===" -ForegroundColor Cyan
# Windows Forms cannot load here, so the controls the GUI functions read and write are stood in by
# plain objects with the same members, and the three functions that touch Windows Forms types
# directly (busy cursor, message box) are stubbed. Everything else is the script's own code. This
# is the path that failed live in 1.0.0: one cluster picked, Discover clicked.
function Enter-GuiBusyState { param([string]$Text = 'Working...') $script:GuiState.Busy = $true; $busyTexts.Add($Text) }
function Exit-GuiBusyState { $script:GuiState.Busy = $false }
function Show-GuiMessage { param([string]$Text, [string]$Icon = 'Information') $messages.Add("${Icon}: $Text") }
$busyTexts = New-Object System.Collections.Generic.List[string]
$messages = New-Object System.Collections.Generic.List[string]

function New-StubRulesRow([string]$Environment, [string]$Letters, [string]$DnsLabels, [string]$Keywords) {
    [pscustomobject]@{ IsNewRow = $false; Cells = @{
            Environment = [pscustomobject]@{ Value = $Environment }; Letters = [pscustomobject]@{ Value = $Letters }
            DnsLabels = [pscustomobject]@{ Value = $DnsLabels }; DatastoreKeywords = [pscustomobject]@{ Value = $Keywords } } }
}
$rulesRows = @(
    (New-StubRulesRow 'PROD' 'p' 'dpe, protected' 'PROD')
    (New-StubRulesRow 'SIT' 't' 'dpesit, protectedsit' 'SIT')
    (New-StubRulesRow 'DEV' 'd' 'dpedev, protecteddev' 'DEV')
)
$clusterList = [pscustomobject]@{ Items = (New-Object System.Collections.ArrayList); SelectedIndex = -1; Enabled = $true }
$clusterList | Add-Member -MemberType ScriptProperty -Name SelectedItem -Value { if ($this.SelectedIndex -ge 0 -and $this.SelectedIndex -lt $this.Items.Count) { $this.Items[$this.SelectedIndex] } }
$password = [pscustomobject]@{ Text = 'secret'; TextLength = 6 }
$password | Add-Member -MemberType ScriptMethod -Name Clear -Value { $this.Text = ''; $this.TextLength = 0 }
$rulesGrid = [pscustomobject]@{ Rows = $rulesRows }
$rulesGrid | Add-Member -MemberType ScriptMethod -Name EndEdit -Value { $true }

$script:Gui = @{
    Server = [pscustomobject]@{ Text = ' vc.example ' }
    User = [pscustomobject]@{ Text = 'DPE\tester' }
    Password = $password
    ClusterList = $clusterList
    ConnectionLabel = [pscustomobject]@{ Text = '' }
    Status = [pscustomobject]@{ Text = '' }
    Pattern = [pscustomobject]@{ Text = $defaultPattern }
    NfsOnly = [pscustomobject]@{ Checked = $false }
    FlagUnclassified = [pscustomobject]@{ Checked = $false }
    ShowUndetermined = [pscustomobject]@{ Checked = $true }
    ResultsGrid = [pscustomobject]@{ DataSource = $null }
    DatastoreGrid = [pscustomobject]@{ DataSource = $null }
    ResultsTab = [pscustomobject]@{ Text = '' }
    DatastoreTab = [pscustomobject]@{ Text = '' }
    RulesGrid = $rulesGrid
}
$script:GuiState = @{ Connection = $null; Inventory = $null; Result = $null; Scope = ''; Busy = $false; ClusterViews = @{}; SuppliedCredential = $null; ScriptVersion = 'gui-test' }

$stub.Calls.Clear()
Invoke-GuiAction { Invoke-GuiConnect } 6>$null
Assert-True "connect: no error shown" ($messages.Count -eq 0) ($messages.ToArray() -join ' | ')
Assert-True "connect: signs in to the trimmed server name" ($stub.Calls.ToArray() -contains 'connect vc.example')
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
Assert-True "discover one cluster: only that cluster's misplaced VM" ((@($script:GuiState.Result.Findings | ForEach-Object { $_.VMName }) -join ',') -eq 'siepd85csd02')
Assert-True "discover one cluster: grid holds the row, tab shows the count" ($script:Gui.ResultsGrid.DataSource.Rows.Count -eq 1 -and $script:Gui.ResultsTab.Text -eq 'Misplaced VMs (1)')
Assert-True "discover one cluster: datastores tab filled" ($script:Gui.DatastoreGrid.DataSource.Rows.Count -eq 2 -and $script:Gui.DatastoreTab.Text -eq 'Datastores (2)')
Assert-True "discover one cluster: status bar summarises" ($script:Gui.Status.Text -match '^CL-PROD-01: 1 cluster\(s\), 2 VMs: 1 correct, 1 reported')
Assert-True "discover one cluster: rows stamped with the version" (@($script:GuiState.Result.Findings | Where-Object { $_.ScriptVersion -ne 'gui-test' }).Count -eq 0)

$clusterList.SelectedIndex = 0
$busyTexts.Clear(); $messages.Clear()
Invoke-GuiAction { Invoke-GuiDiscovery } 6>$null
Assert-True "discover all: no error shown" ($messages.Count -eq 0) ($messages.ToArray() -join ' | ')
Assert-True "discover all: progress reads 1 of 2, 2 of 2" ((@($busyTexts.ToArray() | Where-Object { $_ -like 'Discovering*' }) -join ' | ') -eq 'Discovering CL-DEV-01 (1 of 2)... | Discovering CL-PROD-01 (2 of 2)...')
Assert-True "discover all: both clusters' misplaced VMs" ($script:GuiState.Result.Findings.Count -eq 2)

# Re-apply after editing the grid: letter p moved to DEV. No vCenter read.
$viewCallsBefore = $stub.ViewCalls
$rulesRows[0].Cells.Letters.Value = ''
$rulesRows[2].Cells.Letters.Value = 'd, p'
$messages.Clear()
Invoke-GuiAction { Invoke-GuiEvaluation } 6>$null
Assert-True "re-apply: no error shown" ($messages.Count -eq 0) ($messages.ToArray() -join ' | ')
Assert-True "re-apply: p on a DEV datastore is now correct" ((@($script:GuiState.Result.Findings | ForEach-Object { $_.VMName }) -join ',') -eq 'siepd85csd02')
Assert-True "re-apply: vCenter was not read again" ($stub.ViewCalls -eq $viewCallsBefore)

# A contradictory grid is refused with a message, and the last good result stays on screen.
$rulesRows[0].Cells.Letters.Value = 'p'
$messages.Clear()
Invoke-GuiAction { Invoke-GuiEvaluation } 6>$null 3>$null
Assert-True "re-apply bad rules: refused with a message" ($messages.Count -eq 1 -and $messages[0] -match "'p' is mapped to both PROD and DEV")
Assert-True "re-apply bad rules: status says it failed" ($script:Gui.Status.Text -eq 'Failed - see the Log tab.')
Assert-True "re-apply bad rules: last result kept" ($script:GuiState.Result.Findings.Count -eq 1)
$rulesRows[2].Cells.Letters.Value = 'd'

$script:GuiState.Busy = $true
$ran = $false
Invoke-GuiAction { $script:ran = $true }
Assert-True "a click while busy does not start a second run" (-not $ran)
$script:GuiState.Busy = $false

$stub.Calls.Clear()
Invoke-GuiAction { Invoke-GuiDisconnect } 6>$null
Assert-True "disconnect: signs out and empties the cluster list" (($stub.Calls.ToArray() -join ',') -eq 'disconnect vc.example' -and $clusterList.Items.Count -eq 0 -and $null -eq $script:GuiState.Connection)
Assert-True "disconnect: results stay exportable" ($null -ne $script:GuiState.Result)

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
