<#
.SYNOPSIS
    Tests the UCS best practice audit's verdict engine and the checks most able to be quietly wrong.

.DESCRIPTION
    An audit script fails in a way ordinary scripts do not: it fails by producing a confident,
    well-formatted answer that is not true. Nobody re-reads a 170 row CSV against the domain, so a
    check that silently passes something it never read is worse than a check that crashes.

    Every assertion here is aimed at that failure mode:

      1. A "Does Not Meet" row must carry the value to set. A failing row with an empty
         RecommendedValue tells the operator nothing, so the row builder refuses to make one.
      2. A property this UCSM release does not expose must produce Unknown, never a verdict.
         The property set of a managed object varies by release; reaching for one that is not
         there and concluding "not configured" is the way an audit invents findings.
      3. A class that fails to read must produce Unknown, never silence. An absent row reads as
         "nothing to see" to whoever reviews the CSV.
      4. A setting owned by UCS Central must say so in its remediation. These domains are
         registered, and a remediation naming the wrong console is a remediation nobody can carry
         out - the change is refused or reverted at the next policy push.
      5. Truncation must be reported. A capped detail list that does not say it was capped reads
         as a complete one.
      6. Policy resolution controls must be discovered by value, not from a fixed list of property
         names, so a control added in a later UCS Manager release is still reported.
      7. The Ethernet-only checks: a domain with no Fibre Channel must produce Not Applicable
         rather than failures, and stray FC configuration must be found rather than ignored.
      8. A service profile pointing at a non-compliant maintenance policy must fail even when a
         compliant policy exists elsewhere in the domain - the policy list passing is not the
         same question as the servers using it.

    Standalone - no Pester, no UCS PowerTool, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsBestPractice.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ucs/Test-UcsBestPractice.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) {
    Write-Host "  FAIL  scripts/ucs/Test-UcsBestPractice.ps1 does not parse" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "          line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    exit 1
}

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object {
        $_.Name -in @(
            'Get-UcsBpProperty', 'Test-UcsBpPropertyPresent', 'Get-UcsBpMo', 'Test-UcsBpClassReadable',
            'Get-UcsBpReadFailure', 'Test-UcsBpOwnerIsGlobal', 'ConvertTo-UcsBpDisplayValue',
            'Add-UcsBpRow', 'Add-UcsBpPropertyCheck', 'Add-UcsBpUnreadableClassRow', 'Add-UcsBpOffenderRows',
            'Get-UcsBpFabricFamily', 'Get-UcsBpSummaryText',
            'Test-UcsBpEquipment', 'Test-UcsBpQos', 'Test-UcsBpVlan', 'Test-UcsBpSan',
            'Get-UcsBpFabricOf', 'Test-UcsBpFabricFailover',
            'Test-UcsBpServiceProfile', 'Test-UcsBpUcsCentral'
        )
    } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

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

# --- The state the extracted functions read ------------------------------------------------------
$ScriptVersion = '1.0.0'
$MaxDetailRowsPerCheck = 3
$script:FabricName = 'test-fabric'
$script:RunTimestampUtc = '2026-08-26T00:00:00Z'
$script:FabricFamily = '6400'
$script:UcsHandle = 'fake'

function Reset-Run {
    param([hashtable]$Domain = @{})
    $script:Rows = New-Object System.Collections.Generic.List[object]
    $script:ReadFailures = @{}
    $script:MoCache = @{}
    $global:TestDomain = $Domain
}

# Stands in for Cisco PowerTool. A class absent from the domain throws, exactly as UCSM does for a
# class this release does not expose - which is the case the Unknown path exists for.
function Get-UcsManagedObject {
    param($Ucs, [string]$ClassId, $ErrorAction)
    if ($global:TestDomain.ContainsKey($ClassId)) { return @($global:TestDomain[$ClassId]) }
    throw "class '$ClassId' is not exposed by this UCSM release"
}

# The script logs through Write-RichoLog. Stubbed rather than importing Richo.Common so this test
# stays standalone, and silent so the assertions are not lost in log lines.
function Write-RichoLog { param([Parameter(Position = 0)][AllowEmptyString()]$Message, [Parameter(Position = 1)]$Level, $Path) }

function New-Mo { param([hashtable]$P) [pscustomobject]$P }
function Get-Row { param([string]$CheckId) @($script:Rows | Where-Object { $_.CheckId -eq $CheckId }) | Select-Object -First 1 }

Write-Host "`n=== Row builder: a failing row must state the value to set ===" -ForegroundColor Cyan
Reset-Run
$threw = $false
try {
    Add-UcsBpRow -Category 'X' -CheckId 'X-1' -Setting 's' -CurrentValue 'bad' -Result 'Does Not Meet' -Severity 'High'
}
catch { $threw = $true }
Assert-True 'Does Not Meet with no RecommendedValue is refused' $threw
Assert-Equal 'and no row was recorded' 0 $script:Rows.Count

Reset-Run
Add-UcsBpRow -Category 'X' -CheckId 'X-2' -Setting 's' -CurrentValue 'ok' -Result 'Meets' -Severity 'Low'
Assert-Equal 'a Meets row needs no RecommendedValue' 1 $script:Rows.Count

Write-Host "`n=== Ownership: a UCS Central owned setting says where to fix it ===" -ForegroundColor Cyan
Assert-True  "PolicyOwner 'policy' is global"        (Test-UcsBpOwnerIsGlobal -Owner 'policy')
Assert-True  "PolicyOwner 'ucs-central' is global"   (Test-UcsBpOwnerIsGlobal -Owner 'ucs-central')
Assert-True  "PolicyOwner 'pending-policy' is global" (Test-UcsBpOwnerIsGlobal -Owner 'pending-policy')
Assert-Equal "PolicyOwner 'local' is not global" $false (Test-UcsBpOwnerIsGlobal -Owner 'local')
Assert-Equal 'an empty PolicyOwner is not global' $false (Test-UcsBpOwnerIsGlobal -Owner '')

Reset-Run
Add-UcsBpRow -Category 'X' -CheckId 'G-1' -Setting 's' -Owner 'policy' -CurrentValue 'bad' `
    -RecommendedValue 'good' -Result 'Does Not Meet' -Severity 'High' -Remediation 'Do the thing.'
Add-UcsBpRow -Category 'X' -CheckId 'L-1' -Setting 's' -Owner 'local' -CurrentValue 'bad' `
    -RecommendedValue 'good' -Result 'Does Not Meet' -Severity 'High' -Remediation 'Do the thing.'
Assert-True  'a globally owned row is sent to UCS Central' ((Get-Row 'G-1').Remediation -like '*change it in UCS Central*')
Assert-True  'and keeps the original remediation'          ((Get-Row 'G-1').Remediation -like '*Do the thing.*')
Assert-Equal 'a locally owned row is not' 'Do the thing.'   (Get-Row 'L-1').Remediation

Write-Host "`n=== Reading: unknown beats a guess ===" -ForegroundColor Cyan
Reset-Run
$mo = New-Mo @{ Dn = 'sys/x'; Mode = 'End-Host'; PolicyOwner = 'local' }

Add-UcsBpPropertyCheck -Mo $mo -Property 'Mode' -Expected @('end-host') `
    -Category 'X' -CheckId 'C-1' -Setting 'mode' -Severity 'High'
Assert-Equal 'comparison ignores case' 'Meets' (Get-Row 'C-1').Result

Add-UcsBpPropertyCheck -Mo $mo -Property 'NotInThisRelease' -Expected @('enabled') `
    -Category 'X' -CheckId 'C-2' -Setting 'a setting this release does not expose' -Severity 'High'
Assert-Equal 'a property absent from the schema is Unknown, not a verdict' 'Unknown' (Get-Row 'C-2').Result
Assert-True  'and the row says which property could not be read' ((Get-Row 'C-2').Detail -like "*NotInThisRelease*")

Add-UcsBpPropertyCheck -Mo $null -Property 'Mode' -Expected @('end-host') `
    -Category 'X' -CheckId 'C-3' -Setting 'a missing object' -Severity 'High'
Assert-Equal 'a missing object is Unknown too' 'Unknown' (Get-Row 'C-3').Result

Assert-Equal 'a null property falls back to the default' 'fallback' `
    (Get-UcsBpProperty -InputObject $mo -Name 'Nope' -Default 'fallback')
Assert-Equal 'an absent property is reported absent' $false (Test-UcsBpPropertyPresent -InputObject $mo -Name 'Nope')
Assert-True  'a present property is reported present'        (Test-UcsBpPropertyPresent -InputObject $mo -Name 'Mode')

Write-Host "`n=== Reading: a class that will not read is reported, not skipped ===" -ForegroundColor Cyan
Reset-Run @{}
$result = Get-UcsBpMo -ClassId 'commSnmp'
Assert-Equal 'a failed read returns nothing'              0 @($result).Count
Assert-Equal 'and is remembered as a failure'             $false (Test-UcsBpClassReadable -ClassId 'commSnmp')
Assert-True  'with the reason kept'                       ((Get-UcsBpReadFailure -ClassId 'commSnmp') -like '*not exposed*')
Add-UcsBpUnreadableClassRow -Category 'X' -CheckId 'U-1' -Setting 'SNMP' -ClassId 'commSnmp' -RecommendedValue 'enabled'
Assert-Equal 'and produces an Unknown row rather than silence' 'Unknown' (Get-Row 'U-1').Result

Reset-Run @{ commSnmp = @() }
$null = Get-UcsBpMo -ClassId 'commSnmp'
Assert-True 'a class that reads but is empty is NOT a read failure' (Test-UcsBpClassReadable -ClassId 'commSnmp')

Write-Host "`n=== Fabric interconnect family ===" -ForegroundColor Cyan
$pair6400 = @( (New-Mo @{ Model = 'UCS-FI-6454' }), (New-Mo @{ Model = 'UCS-FI-6454' }) )
Assert-Equal '6454 pair is 6400' '6400' (Get-UcsBpFabricFamily -NetworkElement $pair6400).Family
Assert-Equal '64108 is 6400 as well' '6400' (Get-UcsBpFabricFamily -NetworkElement @(New-Mo @{ Model = 'UCS-FI-64108' })).Family
Assert-Equal '6332 is 6300' '6300' (Get-UcsBpFabricFamily -NetworkElement @(New-Mo @{ Model = 'UCS-FI-6332-16UP' })).Family
$mismatched = @( (New-Mo @{ Model = 'UCS-FI-6454' }), (New-Mo @{ Model = 'UCS-FI-6332' }) )
Assert-Equal 'a mismatched pair is Mixed, not a guess' 'Mixed' (Get-UcsBpFabricFamily -NetworkElement $mismatched).Family
Assert-Equal 'no models at all is Unknown' 'Unknown' (Get-UcsBpFabricFamily -NetworkElement @()).Family

Write-Host "`n=== Truncation is never silent ===" -ForegroundColor Cyan
Reset-Run
$offenders = @(1..10 | ForEach-Object { New-Mo @{ Dn = "org-root/ls-sp$_"; Name = "sp$_" } })
$emitted = Add-UcsBpOffenderRows -Offender $offenders -Category 'X' -CheckId 'T-1' -Setting 'thing' `
    -CurrentValueScript { param($mo, $arg) "$(Get-UcsBpProperty -InputObject $mo -Name 'Name' -Default '?')" } `
    -RecommendedValue 'set it'
Assert-Equal 'detail rows are capped at MaxDetailRowsPerCheck' 3 $emitted
Assert-Equal 'and the caller is told how many were emitted'    3 @($script:Rows | Where-Object { $_.CheckId -eq 'T-1-D' }).Count
Assert-True  'the detail script block can call the script own helpers' `
    (@($script:Rows | Where-Object { $_.CheckId -eq 'T-1-D' })[0].CurrentValue -eq 'sp1')

Reset-Run
$emitted = Add-UcsBpOffenderRows -Offender @() -Category 'X' -CheckId 'T-2' -Setting 'thing' `
    -CurrentValueScript { param($mo, $arg) 'x' } -RecommendedValue 'set it'
Assert-Equal 'an empty offender list emits nothing' 0 $emitted

Write-Host "`n=== Equipment policies ===" -ForegroundColor Cyan
Reset-Run @{
    computeChassisDiscPolicy = @( New-Mo @{ Dn = 'org-root/chassis-discovery'; Action = '2-link'; LinkAggregationPref = 'none'; PolicyOwner = 'local' } )
    computePsuPolicy         = @( New-Mo @{ Dn = 'org-root/psu-policy'; Redundancy = 'non-redund'; PolicyOwner = 'local' } )
    computePowerMgmtPolicy   = @( New-Mo @{ Dn = 'org-root/pwrmgmtpolicy'; Style = 'intelligent-policy-driven'; PolicyOwner = 'policy' } )
    topInfoPolicy            = @( New-Mo @{ Dn = 'sys/info-policy'; State = 'enabled' } )
    equipmentChassis         = @( New-Mo @{ Dn = 'sys/chassis-1'; Operability = 'operable' } )
}
Test-UcsBpEquipment
Assert-Equal 'link grouping None fails'                 'Does Not Meet' (Get-Row 'UCS-EQP-001').Result
Assert-True  'and names port-channel as the fix'        ((Get-Row 'UCS-EQP-001').RecommendedValue -like 'port-channel*')
Assert-Equal 'non-redundant power fails'                'Does Not Meet' (Get-Row 'UCS-EQP-010').Result
Assert-Equal 'policy driven power allocation passes'    'Meets'         (Get-Row 'UCS-EQP-011').Result
Assert-True  'and is sent to UCS Central, being global' ((Get-Row 'UCS-EQP-011').Remediation -like '*UCS Central*')
Assert-Equal 'info policy enabled passes'               'Meets'         (Get-Row 'UCS-EQP-012').Result

Write-Host "`n=== QoS: MTU and the FCoE class of service ===" -ForegroundColor Cyan
Reset-Run @{
    qosclassEthBE         = @( New-Mo @{ Dn = 'fabric/lan/classes/class-best-effort'; Priority = 'best-effort'; Rn = 'class-best-effort'; AdminState = 'enabled'; Mtu = '9000'; Cos = 'any'; Weight = '5' } )
    qosclassEthClassified = @( New-Mo @{ Dn = 'fabric/lan/classes/class-platinum'; Priority = 'platinum'; Rn = 'class-platinum'; AdminState = 'enabled'; Mtu = '9216'; Cos = '3'; Weight = '10' } )
    qosclassFc            = @( New-Mo @{ Dn = 'fabric/lan/classes/class-fc'; Priority = 'fc'; Rn = 'class-fc'; AdminState = 'enabled'; Mtu = 'fc'; Cos = '3'; Weight = '5' } )
}
Test-UcsBpQos
$mtuRows = @($script:Rows | Where-Object { $_.CheckId -eq 'UCS-QOS-001' })
Assert-Equal 'MTU 9000 - neither standard nor UCS jumbo - fails' 'Does Not Meet' `
    (@($mtuRows | Where-Object { $_.Setting -like "*best-effort*" })[0].Result)
Assert-Equal 'MTU 9216 passes' 'Meets' (@($mtuRows | Where-Object { $_.Setting -like "*platinum*" })[0].Result)
Assert-Equal 'MTU fc passes'   'Meets' (@($mtuRows | Where-Object { $_.Setting -like "*fc*" })[0].Result)
Assert-Equal 'an Ethernet class sharing CoS 3 with FCoE fails' 'Does Not Meet' (Get-Row 'UCS-QOS-002').Result

Reset-Run @{
    qosclassEthBE         = @( New-Mo @{ Dn = 'be'; Priority = 'best-effort'; Rn = 'class-best-effort'; AdminState = 'enabled'; Mtu = 'normal'; Cos = 'any'; Weight = '5' } )
    qosclassEthClassified = @( New-Mo @{ Dn = 'gold'; Priority = 'gold'; Rn = 'class-gold'; AdminState = 'disabled'; Mtu = '9216'; Cos = '3'; Weight = '9' } )
    qosclassFc            = @( New-Mo @{ Dn = 'fc'; Priority = 'fc'; Rn = 'class-fc'; AdminState = 'enabled'; Mtu = 'fc'; Cos = '3'; Weight = '5' } )
}
Test-UcsBpQos
Assert-Equal 'a DISABLED class on CoS 3 does not count against the FCoE class' 'Meets' (Get-Row 'UCS-QOS-002').Result

Write-Host "`n=== VLANs ===" -ForegroundColor Cyan
Reset-Run @{
    fabricVlan = @(
        New-Mo @{ Dn = 'fabric/lan/net-default'; Id = '1'; Name = 'default'; SwitchId = 'dual'; DefaultNet = 'yes'; PolicyOwner = 'local' }
        New-Mo @{ Dn = 'fabric/lan/net-mgmt'; Id = '100'; Name = 'mgmt'; SwitchId = 'dual'; DefaultNet = 'no'; PolicyOwner = 'policy' }
        New-Mo @{ Dn = 'fabric/lan/A/net-legacy'; Id = '300'; Name = 'legacy-a'; SwitchId = 'A'; DefaultNet = 'no'; PolicyOwner = 'local' }
        New-Mo @{ Dn = 'fabric/lan/net-dup'; Id = '100'; Name = 'mgmt-old'; SwitchId = 'dual'; DefaultNet = 'no'; PolicyOwner = 'local' }
        New-Mo @{ Dn = 'fabric/lan/net-orphan'; Id = '400'; Name = 'orphan'; SwitchId = 'dual'; DefaultNet = 'no'; PolicyOwner = 'local' }
    )
    vnicEtherIf   = @( New-Mo @{ Dn = 'org-root/ls-a/ether-v0/if-mgmt'; Name = 'mgmt' } )
    fabricNetGroup = @( New-Mo @{ Dn = 'fabric/lan/net-group-prod'; Name = 'prod' } )
}
Test-UcsBpVlan
Assert-Equal 'a VLAN on one fabric only is found'        'Does Not Meet' (Get-Row 'UCS-VLAN-003').Result
Assert-Equal 'one VLAN ID under two names is found'      'Does Not Meet' (Get-Row 'UCS-VLAN-004').Result
Assert-Equal 'VLANs no vNIC references are reported'     'Review'        (Get-Row 'UCS-VLAN-005').Result
Assert-Equal 'a single native VLAN passes'               'Meets'         (Get-Row 'UCS-VLAN-006').Result
Assert-Equal 'VLAN 1 not used for data passes'           'Meets'         (Get-Row 'UCS-VLAN-002').Result
Assert-Equal 'the single-fabric VLAN is named in a detail row' 1 `
    @($script:Rows | Where-Object { $_.CheckId -eq 'UCS-VLAN-003-D' -and $_.CurrentValue -like '*legacy-a*' }).Count

Write-Host "`n=== SAN: this deployment is Ethernet only ===" -ForegroundColor Cyan
Reset-Run @{ fabricFcSanEp = @(); fabricFcSanPc = @(); fabricVsan = @( New-Mo @{ Dn = 'fabric/san/net-default'; Id = '1'; Name = 'default' } ) }
Test-UcsBpSan
Assert-Equal 'no Fibre Channel configuration is the expected state' 'Meets' (Get-Row 'UCS-SAN-001').Result
Assert-Equal 'FC switching mode is Not Applicable, not a failure'   'Not Applicable' (Get-Row 'UCS-SAN-002').Result
Assert-Equal 'as is the 6400 unified port rule'                     'Not Applicable' (Get-Row 'UCS-SAN-005').Result

Reset-Run @{
    fabricFcSanEp   = @( New-Mo @{ Dn = 'fabric/san/A/phys-slot-1-port-1'; PortId = '1'; SwitchId = 'A' } )
    fabricFcSanPc   = @()
    fabricFcSanPcEp = @()
    fabricVsan      = @( New-Mo @{ Dn = 'fabric/san/net-prod'; Id = '10'; Name = 'prod'; FcoeVlan = '100' } )
    fabricSanCloud  = @( New-Mo @{ Dn = 'fabric/san'; Mode = 'end-host' } )
    fabricVlan      = @( New-Mo @{ Dn = 'fabric/lan/net-mgmt'; Id = '100'; Name = 'mgmt' } )
}
Test-UcsBpSan
Assert-Equal 'stray Fibre Channel configuration is found, not ignored' 'Does Not Meet' (Get-Row 'UCS-SAN-001').Result
Assert-Equal 'and it is then audited properly - FCoE VLAN clashing with an Ethernet VLAN' 'Does Not Meet' (Get-Row 'UCS-SAN-004').Result
Assert-Equal 'an unbundled FC uplink is found'                        'Does Not Meet' (Get-Row 'UCS-SAN-003').Result

Write-Host "`n=== Service profiles: the policy list passing is not the same as the servers using it ===" -ForegroundColor Cyan
Reset-Run @{
    lsServer = @(
        New-Mo @{ Dn = 'org-root/ls-esx01'; Name = 'esx01'; Type = 'instance'; AssocState = 'associated'; MaintPolicyName = 'user-ack'; HostFwPolicyName = 'ESX'; BiosProfileName = 'ESX'; LocalDiskPolicyName = 'default'; SrcTemplName = 'esx-templ' }
        New-Mo @{ Dn = 'org-root/ls-win01'; Name = 'win01'; Type = 'instance'; AssocState = 'associated'; MaintPolicyName = 'default'; HostFwPolicyName = ''; BiosProfileName = ''; LocalDiskPolicyName = 'default'; SrcTemplName = '' }
    )
    lsmaintMaintPolicy = @(
        New-Mo @{ Dn = 'org-root/maint-default'; Name = 'default'; UptimeDisr = 'immediate' }
        New-Mo @{ Dn = 'org-root/maint-userack'; Name = 'user-ack'; UptimeDisr = 'user-ack' }
    )
}
Test-UcsBpServiceProfile
Assert-Equal 'a profile pointing at an immediate policy fails' 'Does Not Meet' (Get-Row 'UCS-SP-010').Result
Assert-True  'and the offending profile is named'             (@($script:Rows | Where-Object { $_.CheckId -eq 'UCS-SP-010-D' })[0].CurrentValue -like '*win01*')
Assert-Equal 'a missing host firmware package fails'          'Does Not Meet' (Get-Row 'UCS-SP-011').Result
Assert-Equal 'a policy every profile carries passes'          'Meets'         (Get-Row 'UCS-SP-013').Result

Write-Host "`n=== UCS Central: controls are found by value, not by a fixed name list ===" -ForegroundColor Cyan
Reset-Run @{
    policyControlEp = @( New-Mo @{
            Dn = 'org-root/control-ep-policy'; Name = 'ucscentral.example.com'; RegState = 'registered'
            timeZone = 'global'; aaa = 'global'; psuPolicy = 'local'
            # A control this script has no label for. It must still be reported.
            someControlAddedLater = 'global'
        } )
    commNtpProvider = @( New-Mo @{ Dn = 'ntp1'; Name = '10.1.1.1' } )
    commDateTime    = @( New-Mo @{ Dn = 'dt'; Timezone = 'Australia/Sydney' } )
}
Test-UcsBpUcsCentral
Assert-Equal 'a registered domain passes'                       'Meets' (Get-Row 'UCS-UCSC-001').Result
Assert-Equal 'NTP and time zone prerequisites pass'             'Meets' (Get-Row 'UCS-UCSC-002').Result
Assert-Equal 'a known control is reported under its real name'  'global' (Get-Row 'UCS-UCSC-010-timeZone').CurrentValue
Assert-True  'with the UCS Central name, not the property name' ((Get-Row 'UCS-UCSC-010-timeZone').Setting -like '*Time Zone Management*')
Assert-True  'a control with no label is still reported'        ($null -ne (Get-Row 'UCS-UCSC-010-someControlAddedLater'))
Assert-Equal 'a locally resolved control is reported too'       'local' (Get-Row 'UCS-UCSC-010-psuPolicy').CurrentValue
Assert-Equal 'four controls found in total'                     4 @($script:Rows | Where-Object { $_.CheckId -like 'UCS-UCSC-010-*' }).Count

Reset-Run @{ commNtpProvider = @(); commDateTime = @() }
Test-UcsBpUcsCentral
Assert-Equal 'an unreadable registration object is Unknown, not "not registered"' 'Unknown' (Get-Row 'UCS-UCSC-001').Result

Write-Host "`n=== Which fabric an object belongs to ===" -ForegroundColor Cyan
Assert-Equal 'SwitchId wins'                          'A' (Get-UcsBpFabricOf -Mo (New-Mo @{ SwitchId = 'A'; Dn = 'x' }))
Assert-Equal 'a failover pair reports its primary'    'A' (Get-UcsBpFabricOf -Mo (New-Mo @{ SwitchId = 'A-B'; Dn = 'x' }))
Assert-Equal 'B-A reports B'                          'B' (Get-UcsBpFabricOf -Mo (New-Mo @{ SwitchId = 'B-A'; Dn = 'x' }))
Assert-Equal 'the Dn is the fallback'                 'B' (Get-UcsBpFabricOf -Mo (New-Mo @{ Dn = 'fabric/lan/B/pc-10' }))
Assert-Equal 'and sw-A in a Dn resolves'              'A' (Get-UcsBpFabricOf -Mo (New-Mo @{ Dn = 'fabric/server/sw-A/slot-1-port-1' }))
Assert-Equal 'unresolvable is empty, not a guess'     ''  (Get-UcsBpFabricOf -Mo (New-Mo @{ Dn = 'org-root/thing' }))
# An IO module numbers itself 1 or 2. Nothing else does, so the mapping is opt-in - left on by
# default it would resolve port channel Id 1 to fabric A, silently and wrongly.
Assert-Equal 'a numeric Id is NOT a fabric by default' '' (Get-UcsBpFabricOf -Mo (New-Mo @{ Id = '1'; Dn = 'sys/chassis-1/slot-1' }))
Assert-Equal 'IO module Id 1 is fabric A when asked'  'A' (Get-UcsBpFabricOf -Mo (New-Mo @{ Id = '1'; Dn = 'sys/chassis-1/slot-1' }) -NumericIdIsFabric)
Assert-Equal 'IO module Id 2 is fabric B when asked'  'B' (Get-UcsBpFabricOf -Mo (New-Mo @{ Id = '2'; Dn = 'sys/chassis-1/slot-2' }) -NumericIdIsFabric)

Write-Host "`n=== Fabric failover: what breaks when one fabric goes away ===" -ForegroundColor Cyan
# The domain that explains a subordinate reboot taking everything down: fabric A's uplink is
# already dead, so all traffic has been going through B and nobody knew.
Reset-Run @{
    mgmtEntity     = @(
        New-Mo @{ Dn = 'sys/mgmt-entity-A'; Id = 'A'; LeadershipState = 'primary' }
        New-Mo @{ Dn = 'sys/mgmt-entity-B'; Id = 'B'; LeadershipState = 'subordinate' }
    )
    fabricLanCloud = @( New-Mo @{ Dn = 'fabric/lan'; Mode = 'switch' } )
    stpInstance    = @( New-Mo @{ Dn = 'fabric/lan/stp-inst-1' } )
    fabricEthLanPc = @(
        New-Mo @{ Dn = 'fabric/lan/A/pc-10'; Name = 'uplink-A'; SwitchId = 'A'; OperState = 'down'; AdminState = 'enabled' }
        New-Mo @{ Dn = 'fabric/lan/B/pc-10'; Name = 'uplink-B'; SwitchId = 'B'; OperState = 'up'; AdminState = 'enabled' }
    )
    fabricEthLanPcEp = @( New-Mo @{ Dn = 'fabric/lan/B/pc-10/ep-slot-1-port-49'; SwitchId = 'B' } )
    fabricEthLanEp   = @()
    fabricVlan       = @(
        New-Mo @{ Dn = 'fabric/lan/net-mgmt'; Id = '100'; Name = 'mgmt'; SwitchId = 'dual' }
        New-Mo @{ Dn = 'fabric/lan/A/net-legacy'; Id = '300'; Name = 'legacy-a'; SwitchId = 'A' }
    )
    fabricNetGroup    = @( New-Mo @{ Dn = 'fabric/lan/net-group-prod'; Name = 'prod' } )
    fabricNetGroupRef = @( New-Mo @{ Dn = 'fabric/lan/B/pc-10/net-group-ref-prod'; Name = 'prod'; SwitchId = 'B' } )
    fabricLanPinGroup  = @( New-Mo @{ Dn = 'fabric/lan/pin-group-storage'; Name = 'storage-pin' } )
    fabricLanPinTarget = @( New-Mo @{ Dn = 'fabric/lan/pin-group-storage/target-B'; EpDn = 'fabric/lan/B/pc-10' } )
    vnicEther = @(
        New-Mo @{ Dn = 'org-root/ls-esx01/ether-vnic0'; SwitchId = 'A'; NwCtrlPolicyName = 'esx' }
        New-Mo @{ Dn = 'org-root/ls-esx01/ether-vnic1'; SwitchId = 'B'; NwCtrlPolicyName = 'esx' }
        New-Mo @{ Dn = 'org-root/ls-win01/ether-vnic0'; SwitchId = 'B'; NwCtrlPolicyName = 'esx' }
    )
    nwctrlDefinition = @( New-Mo @{ Dn = 'org-root/nwctrl-esx'; Name = 'esx'; UplinkFailAction = 'warning'; Cdp = 'enabled' } )
    networkLanNeighborEntry = @(
        New-Mo @{ Dn = 'sys/switch-A/lan-neighbor-1'; SwitchId = 'A'; SysName = 'n9k-core-01' }
        New-Mo @{ Dn = 'sys/switch-B/lan-neighbor-1'; SwitchId = 'B'; SysName = 'n9k-core-01' }
    )
    equipmentIOCard = @( New-Mo @{ Dn = 'sys/chassis-1/slot-1'; ChassisId = '1'; Id = '1'; OperState = 'operable' } )
    fabricEthEstcEp = @(); fabricEthEstcPc = @(); vnicLanConnTempl = @()
}
Test-UcsBpFabricFailover

$fabricARow = @($script:Rows | Where-Object { $_.CheckId -eq 'UCS-FO-002' -and $_.Setting -like '*Fabric A*' })[0]
$fabricBRow = @($script:Rows | Where-Object { $_.CheckId -eq 'UCS-FO-002' -and $_.Setting -like '*Fabric B*' })[0]
Assert-Equal 'a fabric whose uplink is down has no working northbound path' 'Does Not Meet' $fabricARow.Result
Assert-Equal 'the fabric carrying everything passes'                        'Meets'         $fabricBRow.Result
Assert-Equal 'and the domain is flagged as running on one side'             'Does Not Meet' (Get-Row 'UCS-FO-003').Result
Assert-Equal 'which is Critical - it is the whole outage'                   'Critical'      (Get-Row 'UCS-FO-003').Severity

Assert-Equal 'switching mode is a finding, not a preference'  'Does Not Meet' (Get-Row 'UCS-FO-010').Result
Assert-True  'and it explains the upstream reconvergence'     ((Get-Row 'UCS-FO-010').Remediation -like '*spanning tree*')
Assert-True  'spanning tree instances are reported in switch mode' ($null -ne (Get-Row 'UCS-FO-011'))

Assert-Equal 'a VLAN on one fabric only is counted'      'Does Not Meet' (Get-Row 'UCS-FO-020').Result
Assert-Equal 'a VLAN group bound to one fabric fails'    'Does Not Meet' (Get-Row 'UCS-FO-021').Result
Assert-Equal 'and it is Critical - it strands the other fabric too' 'Critical' (Get-Row 'UCS-FO-021').Severity
Assert-Equal 'a pin group targeting one fabric fails'    'Does Not Meet' (Get-Row 'UCS-FO-030').Result
Assert-Equal 'a service profile on one fabric is found'  'Does Not Meet' (Get-Row 'UCS-FO-040').Result
Assert-True  'and named'                                 (@($script:Rows | Where-Object { $_.CheckId -eq 'UCS-FO-040-D' })[0].CurrentValue -like '*win01*')
Assert-Equal 'uplink fail action warning is Critical'    'Does Not Meet' (Get-Row 'UCS-FO-050').Result
Assert-Equal 'both fabrics on one upstream switch fails' 'Does Not Meet' (Get-Row 'UCS-FO-061').Result
Assert-Equal 'a chassis with one IO module fails'        'Does Not Meet' (Get-Row 'UCS-FO-070').Result

Write-Host "`n=== Fabric failover: a domain that would survive the reboot ===" -ForegroundColor Cyan
Reset-Run @{
    mgmtEntity     = @( New-Mo @{ Dn = 'sys/mgmt-entity-A'; Id = 'A'; LeadershipState = 'primary' } )
    fabricLanCloud = @( New-Mo @{ Dn = 'fabric/lan'; Mode = 'end-host' } )
    fabricEthLanPc = @(
        New-Mo @{ Dn = 'fabric/lan/A/pc-10'; Name = 'uplink-A'; SwitchId = 'A'; OperState = 'up'; AdminState = 'enabled' }
        New-Mo @{ Dn = 'fabric/lan/B/pc-10'; Name = 'uplink-B'; SwitchId = 'B'; OperState = 'up'; AdminState = 'enabled' }
    )
    fabricEthLanPcEp = @(
        New-Mo @{ Dn = 'fabric/lan/A/pc-10/ep-1'; SwitchId = 'A' }
        New-Mo @{ Dn = 'fabric/lan/B/pc-10/ep-1'; SwitchId = 'B' }
    )
    fabricEthLanEp = @()
    fabricVlan     = @( New-Mo @{ Dn = 'fabric/lan/net-mgmt'; Id = '100'; Name = 'mgmt'; SwitchId = 'dual' } )
    fabricNetGroup    = @( New-Mo @{ Dn = 'fabric/lan/net-group-prod'; Name = 'prod' } )
    fabricNetGroupRef = @(
        New-Mo @{ Dn = 'fabric/lan/A/pc-10/net-group-ref-prod'; Name = 'prod'; SwitchId = 'A' }
        New-Mo @{ Dn = 'fabric/lan/B/pc-10/net-group-ref-prod'; Name = 'prod'; SwitchId = 'B' }
    )
    fabricLanPinGroup = @(); fabricLanPinTarget = @()
    vnicEther = @(
        New-Mo @{ Dn = 'org-root/ls-esx01/ether-vnic0'; SwitchId = 'A'; NwCtrlPolicyName = 'esx' }
        New-Mo @{ Dn = 'org-root/ls-esx01/ether-vnic1'; SwitchId = 'B'; NwCtrlPolicyName = 'esx' }
    )
    nwctrlDefinition = @( New-Mo @{ Dn = 'org-root/nwctrl-esx'; Name = 'esx'; UplinkFailAction = 'link-down' } )
    networkLanNeighborEntry = @(
        New-Mo @{ Dn = 'sys/switch-A/lan-neighbor-1'; SwitchId = 'A'; SysName = 'n9k-core-01' }
        New-Mo @{ Dn = 'sys/switch-B/lan-neighbor-1'; SwitchId = 'B'; SysName = 'n9k-core-02' }
    )
    equipmentIOCard = @(
        New-Mo @{ Dn = 'sys/chassis-1/slot-1'; ChassisId = '1'; Id = '1'; OperState = 'operable' }
        New-Mo @{ Dn = 'sys/chassis-1/slot-2'; ChassisId = '1'; Id = '2'; OperState = 'operable' }
    )
    fabricEthEstcEp = @(); fabricEthEstcPc = @(); vnicLanConnTempl = @()
}
Test-UcsBpFabricFailover
Assert-Equal 'both fabrics have a path'                    'Meets' (Get-Row 'UCS-FO-003').Result
Assert-Equal 'end-host mode keeps UCS out of spanning tree' 'Meets' (Get-Row 'UCS-FO-010').Result
Assert-True  'and no spanning tree row is emitted'          ($null -eq (Get-Row 'UCS-FO-011'))
Assert-Equal 'no single-fabric VLANs'                       'Meets' (Get-Row 'UCS-FO-020').Result
Assert-Equal 'the VLAN group spans both fabrics'            'Meets' (Get-Row 'UCS-FO-021').Result
Assert-Equal 'no pin groups is the good answer'             'Meets' (Get-Row 'UCS-FO-030').Result
Assert-Equal 'every profile has both fabrics'               'Meets' (Get-Row 'UCS-FO-040').Result
Assert-Equal 'uplink loss is signalled'                     'Meets' (Get-Row 'UCS-FO-050').Result
Assert-Equal 'the fabrics reach different upstream switches' 'Meets' (Get-Row 'UCS-FO-061').Result
Assert-Equal 'both IO modules present'                      'Meets' (Get-Row 'UCS-FO-070').Result

Write-Host "`n=== Fabric failover: what cannot be read is not passed ===" -ForegroundColor Cyan
Reset-Run @{
    fabricLanCloud = @( New-Mo @{ Dn = 'fabric/lan'; Mode = 'end-host' } )
    fabricEthLanPc = @( New-Mo @{ Dn = 'fabric/lan/A/pc-10'; SwitchId = 'A'; OperState = 'up' } )
    fabricEthLanPcEp = @(); fabricEthLanEp = @(); fabricVlan = @()
    fabricNetGroup = @( New-Mo @{ Dn = 'fabric/lan/net-group-prod'; Name = 'prod' } )
    fabricLanPinGroup = @(); fabricLanPinTarget = @(); vnicEther = @(); nwctrlDefinition = @()
    equipmentIOCard = @(); fabricEthEstcEp = @(); fabricEthEstcPc = @(); vnicLanConnTempl = @()
    mgmtEntity = @()
}
Test-UcsBpFabricFailover
Assert-Equal 'a VLAN group whose bindings cannot be read is Unknown' 'Unknown' (Get-Row 'UCS-FO-021').Result
Assert-Equal 'and it is not quietly downgraded'                     'High'    (Get-Row 'UCS-FO-021').Severity
Assert-Equal 'no neighbour data is Unknown, not "different switches"' 'Unknown' (Get-Row 'UCS-FO-060').Result
Assert-True  'and it says to turn the info policy on'               ((Get-Row 'UCS-FO-060').Remediation -like '*Info Policy*')

Write-Host "`n=== Display values ===" -ForegroundColor Cyan
Assert-Equal 'null renders explicitly'        '(not set)' (ConvertTo-UcsBpDisplayValue -Value $null)
Assert-Equal 'empty string renders explicitly' '(not set)' (ConvertTo-UcsBpDisplayValue -Value '')
Assert-Equal 'an empty array renders explicitly' '(none)'  (ConvertTo-UcsBpDisplayValue -Value @())
Assert-Equal 'an array is joined, not stringified' 'a; b'  (ConvertTo-UcsBpDisplayValue -Value @('a', 'b'))
Assert-Equal 'a number survives'                '0'        (ConvertTo-UcsBpDisplayValue -Value 0)

Write-Host "`n=== Summary text ===" -ForegroundColor Cyan
# Guards the regression that produced a completed audit reported as a failed run: the summary was
# handed @($script:Rows) on a List[object], which does not convert.
$rowsList = New-Object System.Collections.Generic.List[object]
$rowsList.Add([pscustomobject]@{ Result = 'Does Not Meet'; Severity = 'Critical'; CheckId = 'A-1'; Setting = 's'; CurrentValue = 'c'; RecommendedValue = 'r' })
$summaryOk = $false
try { $summary = Get-UcsBpSummaryText -Row $rowsList.ToArray(); $summaryOk = ($summary -like '*Does Not Meet*') } catch { $summaryOk = $false }
Assert-True 'the summary builds from a List via ToArray()' $summaryOk
Assert-True 'and names the value that should be set'       ($summary -like '*should: r*')

Write-Host ''
if ($script:fail -eq 0) { Write-Host "  $($script:pass) assertions passed." -ForegroundColor Green }
else { Write-Host "  $($script:pass) passed, $($script:fail) FAILED." -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
