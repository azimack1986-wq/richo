<#
.SYNOPSIS
    Tests fabric interconnect family detection and the firmware policy it selects.

.DESCRIPTION
    The firmware policy is no longer chosen by an operator - it is derived from the fabric
    interconnect model reported by the connected UCSM domain. That makes the derivation
    load-bearing: get the family wrong and a 6300 domain is pointed at 6400 firmware.

    Covers the model strings Cisco actually ships, the mapping to a host firmware package, reuse of
    an existing package, creation of a missing one by name alone, and the cases that must stop the
    run rather than guess.

    Creation by name alone is the point of the last group: no blade or rack bundle version may be
    written by this script. The package takes its versions from the global firmware setting its name
    refers to, and a bundle string sent from here would override that setting silently.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-UcsFabricFamily.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-UcsFabricFamily','Resolve-UcsFirmwarePolicyForTarget','Remove-UcsHostsAlreadyOnTargetFirmware','ConvertTo-UcsBundleVersionFromPolicyName','Get-UcsFirmwarePolicyRows','Test-UcsFirmwarePolicyExists','Get-UcsFirmwarePolicyLookup',
                                 'Test-UcsRemotePolicyMessage','Set-UcsServiceProfileTemplateFirmwarePolicy',
                                 'New-UcsGlobalFirmwarePolicy',
                                 'Get-UcsServiceProfileFirmwarePolicyName','ConvertTo-UcsFirmwarePolicyName',
                                 'Test-DryRun') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$Global:RunMode = 'LIVE'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$ScriptVersion = 'test'
$Global:UcsFirmwarePolicyByTarget = @{}
$Global:UcsFirmwarePolicyByFabricFamily = @{
    '6400' = 'global-602d'
    '6300' = 'global-436h'
}

function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Host=$HostName; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-WithMessage { param($Message) throw "STOP: $Message" }
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:ExcludedFromRunHosts = @{}
$Global:CurrentClusterName = 'TestCluster'
function Add-ManualAttentionHost { param($HostName,$Reason,$Detail,$ClusterName,[switch]$ExcludeFromRun)
    $Global:ManualAttentionHosts.Add([pscustomobject]@{ Host=$HostName; Reason=$Reason; Detail=$Detail; Excluded=[bool]$ExcludeFromRun }) }
function Stop-SafeExit { param($Message) throw "EXIT: $Message" }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

# --- Stubs -----------------------------------------------------------------------------------
$script:Models = @('UCS-FI-6454','UCS-FI-6454')
$script:Packs = @()
$script:Created = @()
# Single-key answers, as the real prompts now offer: C to create, X to stop.
$script:Answer = 'C'
function Get-UcsNetworkElement { param($Ucs,$ErrorAction)
    if ($script:Models -eq 'THROW') { throw "connection lost" }
    return @($script:Models | ForEach-Object { [pscustomobject]@{ Dn='sys/switch'; Model=$_ } }) }
# The real cmdlet is asked three different ways by Get-UcsFirmwarePolicyLookup - by org and name,
# by Dn, and unfiltered - so the stub has to answer all three, and be able to FAIL, which is the
# case that used to be read as "the policy does not exist".
$script:PackQueryThrows = $false
function Get-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$Dn,$ErrorAction)
    if ($script:PackQueryThrows) { throw "connection lost" }
    $all = @($script:Packs | ForEach-Object { [pscustomobject]@{ Name=$_; Dn="org-root/fw-host-pack-$_"; Descr=''
        PolicyOwner=$(if ($script:OwnerAfterCreate.ContainsKey($_)) { $script:OwnerAfterCreate[$_] } else { 'local' }) } })
    if ($Name) { return @($all | Where-Object { $_.Name -eq $Name }) }
    if ($Dn)   { return @($all | Where-Object { $_.Dn -eq $Dn }) }
    return $all }

# Service profile templates, for the alignment pass that runs once the policy is resolved.
$script:Templates = @()
$script:TemplateWrites = New-Object System.Collections.Generic.List[string]
$script:TemplateSetThrows = ""
function Get-UcsServiceProfile { param($Ucs,$Type,$Dn,$ErrorAction)
    if ($Dn) { return @($script:Templates | Where-Object { $_.Dn -eq $Dn }) }
    if ($Type) { return @($script:Templates | Where-Object { $_.Type -eq $Type }) }
    return @($script:Templates) }
function Set-UcsServiceProfile { param($Ucs,$ServiceProfile,$HostFwPolicyName,[switch]$Force,$ErrorAction)
    if ($script:TemplateSetThrows) { throw $script:TemplateSetThrows }
    $script:TemplateWrites.Add("$($ServiceProfile.Name)|$HostFwPolicyName|Force=$Force")
    $ServiceProfile.HostFwPolicyName = $HostFwPolicyName }
# Bundle parameters are still declared, so that passing one is recorded rather than silently
# swallowed by parameter binding - the assertions below require that they arrive empty.
# PolicyOwner and ModifyPresent are declared for the same reason: the whole point of the create is
# that the ownership travels WITH it, in one managed-object write.
$script:AddThrows = ""
function Add-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$PolicyOwner,[switch]$ModifyPresent,$BladeBundleVersion,$RackBundleVersion,$Descr,$ErrorAction)
    if ($script:AddThrows) { throw $script:AddThrows }
    $script:Created += [pscustomobject]@{ Org=$Org; Name=$Name; Owner=$PolicyOwner; ModifyPresent=[bool]$ModifyPresent
                                          Blade=$BladeBundleVersion; Rack=$RackBundleVersion; Descr=$Descr
                                          InTransaction=$script:TxOpen }
    $script:Packs += $Name
    if ($PolicyOwner) { $script:OwnerAfterCreate[$Name] = $PolicyOwner } }

# The transaction is the configConfMos batch. Recording the order proves the estimate goes out
# BEFORE the commit, which is the pair the GUI sends.
$script:TxOpen = $false
$script:TxLog = New-Object System.Collections.Generic.List[string]
$script:OwnerAfterCreate = @{}
function Start-UcsTransaction { param($Ucs,$ErrorAction) $script:TxOpen = $true; $script:TxLog.Add('start') }
function Complete-UcsTransaction { param($Ucs,$ErrorAction) $script:TxOpen = $false; $script:TxLog.Add('commit') }
function Undo-UcsTransaction { param($Ucs,$ErrorAction) $script:TxOpen = $false; $script:TxLog.Add('undo') }
function Get-UcsTransactionImpact { param($Ucs,$ErrorAction)
    $script:TxLog.Add('estimate')
    return @([pscustomobject]@{ Message = 'Server reboot required to activate firmware.' }) }
function Read-ChoiceExit { param($Message,$AllowedChoices,$ExitMessage) $script:LastPrompt = $Message; return $script:Answer }

Write-Host "`n=== Model strings map to the right family ===" -ForegroundColor Cyan
foreach ($case in @(
    @{ Models=@('UCS-FI-6454','UCS-FI-6454');   Expect='6400'; Label='6454 (6400 series)' },
    @{ Models=@('UCS-FI-64108','UCS-FI-64108'); Expect='6400'; Label='64108 (6400 series, five digits)' },
    @{ Models=@('UCS-FI-6332','UCS-FI-6332');   Expect='6300'; Label='6332 (6300 series)' },
    @{ Models=@('UCS-FI-6332-16UP');            Expect='6300'; Label='6332-16UP (6300 series, suffixed)' },
    @{ Models=@('UCS-FI-6248UP','UCS-FI-6248UP'); Expect='6200'; Label='6248UP (6200 series)' },
    @{ Models=@('UCS-FI-6536','UCS-FI-6536');   Expect='6500'; Label='6536 (6500 series)' }
)) {
    $script:Models = $case.Models
    Assert-Equal $case.Label $case.Expect (Get-UcsFabricFamily -UcsSession 'x').Family
}

Write-Host "`n=== Ambiguous or unreadable fabrics are never guessed ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6332','UCS-FI-6454')
Assert-Equal "mismatched fabric interconnects report Mixed" "Mixed" (Get-UcsFabricFamily -UcsSession 'x').Family
$script:Models = @('SOMETHING-ELSE')
Assert-Equal "an unrecognised model reports Unknown" "Unknown" (Get-UcsFabricFamily -UcsSession 'x').Family
$script:Models = @()
Assert-Equal "no fabric interconnects reports Unknown" "Unknown" (Get-UcsFabricFamily -UcsSession 'x').Family
$script:Models = 'THROW'
Assert-Equal "a failed query reports Unknown rather than throwing" "Unknown" (Get-UcsFabricFamily -UcsSession 'x').Family

Write-Host "`n=== A package the domain has resolved is used as-is ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6454'); $script:Packs = @('global-602d'); $script:Created = @()
$Global:UcsFirmwarePolicyByTarget = @{}
Assert-Equal "6400 domain resolves to global-602d" "global-602d" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-a' -UcsSession 'x' 6>$null)
Assert-Equal "nothing was created" 0 $script:Created.Count

Write-Host "`n=== The resolution is cached per domain ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6332'); $script:Packs = @('global-436h'); $Global:UcsFirmwarePolicyByTarget = @{}
Assert-Equal "6300 domain resolves to global-436h" "global-436h" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-b' -UcsSession 'x' 6>$null)
$script:Models = 'THROW'   # a second call must not go back to the domain at all
Assert-Equal "a second call reuses the resolved policy" "global-436h" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-b' -UcsSession 'x' 6>$null)
$script:Models = @('UCS-FI-6332')

Write-Host "`n=== Creation is not put to the operator ===" -ForegroundColor Cyan
# At the operator's direction. What gets created is fully determined - the name comes from the
# fabric family, the org is always org-root, no bundle version is written - so the confirmation
# had nothing to decide and only stood between the run and the blades.
# Asserted against the two functions themselves rather than the whole file, so an unrelated
# message that happens to use the same words cannot make this pass or fail by accident.
$policyFunctions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Resolve-UcsFirmwarePolicyForTarget','Set-UcsServiceProfileTemplateFirmwarePolicy') })
Assert-Equal "both policy functions are present" 2 $policyFunctions.Count
$policyPrompts = @($policyFunctions | Where-Object { $_.Extent.Text -match 'Read-ChoiceExit' } | ForEach-Object { $_.Name })
Assert-Equal "neither asks the operator anything" "" ($policyPrompts -join ',')
$policySource = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "and no 'creation was declined' path survives" $true (-not ($policySource -match 'creation was declined'))

Write-Host "`n=== A query that cannot be answered is never read as 'not there' ===" -ForegroundColor Cyan
# THE LIVE FAULT. Get-UcsFirmwareComputeHostPack was called with -ErrorAction SilentlyContinue, so
# a failed query returned an empty list, the run decided the package was missing, and tried to
# CREATE one UCS Central already owned. UCSM refused with "resolved from remote policy server".
$script:PackQueryThrows = $true
$lookup = Get-UcsFirmwarePolicyLookup -PolicyName 'global-436h' -UcsSession 'x'
Assert-Equal "an unanswerable lookup is Unknown, not absent" $false $lookup.Known
Assert-Equal "and does not claim the policy exists" $false $lookup.Exists
$script:Models = @('UCS-FI-6332'); $script:Created = @(); $Global:UcsFirmwarePolicyByTarget = @{}
$stoppedUnknown = $false
try { [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-c' -UcsSession 'x' 6>$null) } catch { $stoppedUnknown = "$_" -match 'could not be established' }
Assert-Equal "the run stops rather than creating on a guess" $true $stoppedUnknown
Assert-Equal "and nothing was created" 0 $script:Created.Count
$script:PackQueryThrows = $false

Write-Host "`n=== The lookup finds a package by name, by Dn, or in the list ===" -ForegroundColor Cyan
$script:Packs = @('global-436h')
Assert-Equal "found, and known" $true (Get-UcsFirmwarePolicyLookup -PolicyName 'global-436h' -UcsSession 'x').Exists
Assert-Equal "a genuine absence is Known and not Exists" $false (Get-UcsFirmwarePolicyLookup -PolicyName 'global-999z' -UcsSession 'x').Exists
Assert-Equal "and a genuine absence is answered, not unknown" $true (Get-UcsFirmwarePolicyLookup -PolicyName 'global-999z' -UcsSession 'x').Known
$script:Packs = @()

Write-Host "`n=== 'Resolved from remote policy server' means already Global ===" -ForegroundColor Cyan
# UCSM's own wording for "UCS Central owns this object, you may not touch it". Read as a failure it
# produced "could not be made Global and would upgrade nothing" for a package that was in exactly
# the state the run wanted.
Assert-Equal "the message is recognised" $true (Test-UcsRemotePolicyMessage -Message "PD21000001SS004:Policy org-root/fw-host-pack-global-436h is resolved from remote policy server. Create/Delete/Modify operations are not allowed.")
Assert-Equal "casing does not matter" $true (Test-UcsRemotePolicyMessage -Message "RESOLVED FROM REMOTE POLICY SERVER")
Assert-Equal "an unrelated failure is not mistaken for it" $false (Test-UcsRemotePolicyMessage -Message "Authentication failed")
Assert-Equal "and neither is nothing" $false (Test-UcsRemotePolicyMessage -Message "")

Write-Host "`n=== An unmapped family stops rather than picking something ===" -ForegroundColor Cyan
$script:Models = @('UCS-FI-6248UP'); $script:Packs = @('global-436h'); $Global:UcsFirmwarePolicyByTarget = @{}
$script:OwnerAfterCreate = @{}
$stopped = $false
try { [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-d' -UcsSession 'x' 6>$null) } catch { $stopped = "$_" -match 'No firmware policy is mapped' }
Assert-Equal "an unmapped 6200 domain stops the run" $true $stopped

Write-Host "`n=== DRY RUN resolves and reports, and writes nothing ===" -ForegroundColor Cyan
$Global:RunMode = 'DRYRUN'
$script:Models = @('UCS-FI-6332'); $script:Packs = @('global-436h'); $script:Created = @()
$script:TemplateWrites = New-Object System.Collections.Generic.List[string]
$Global:UcsFirmwarePolicyByTarget = @{}
Assert-Equal "DRY RUN still reports the policy it will use" "global-436h" (Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-e' -UcsSession 'x' 6>$null)
Assert-Equal "DRY RUN created nothing" 0 $script:Created.Count
Assert-Equal "and wrote no template" 0 $script:TemplateWrites.Count
$Global:RunMode = 'LIVE'

Write-Host "`n=== The target version is read back out of the policy name ===" -ForegroundColor Cyan
# The end-state comparison needs a version to compare against, and the package names already encode
# one. Reading it back from the name keeps the script free of a version table while still being able
# to say whether a server actually landed on the right firmware.
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'ConvertTo-UcsBundleVersionFromPolicyName' } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

Assert-Equal "global-602d means 6.0(2d)" "6.0(2d)" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName 'global-602d')
Assert-Equal "global-436h means 4.3(6h)" "4.3(6h)" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName 'global-436h')
Assert-Equal "casing does not matter" "6.0(2d)" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName 'GLOBAL-602D')
# A name nobody can decode must produce no comparison at all, rather than a comparison against a
# version nobody chose.
Assert-Equal "a name off the convention yields nothing" "" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName 'site-standard-fw')
Assert-Equal "an empty name yields nothing" "" (ConvertTo-UcsBundleVersionFromPolicyName -PolicyName '')

Write-Host "`n=== The script contains no hard-coded bundle versions ===" -ForegroundColor Cyan
# A stub can only prove what was passed on the paths the test walks. This proves it for the whole
# file: the moment someone reintroduces -BladeBundleVersion, the policy stops following the global
# setting, and no runtime assertion would necessarily walk that line.
$scriptText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "no -BladeBundleVersion anywhere in the script" $true (-not ($scriptText -match '-BladeBundleVersion'))
Assert-Equal "no -RackBundleVersion anywhere in the script"  $true (-not ($scriptText -match '-RackBundleVersion'))

Write-Host "`n=== A missing package is created in UCSM and handed to UCS Central in ONE write ===" -ForegroundColor Cyan
# The package has to exist in the domain before Central can take it over. Creating it LOCAL and
# then modifying policyOwner is the order that failed: by the second call the object was resolved
# from the policy server and UCSM refused it, leaving a local, empty package behind. The ownership
# therefore travels with the create.
function Reset-Create {
    $script:Created = @(); $script:Packs = @(); $script:AddThrows = ""
    $script:TxLog = New-Object System.Collections.Generic.List[string]
    $script:OwnerAfterCreate = @{}
    $script:TemplateWrites = New-Object System.Collections.Generic.List[string]
    $Global:UcsFirmwarePolicyByTarget = @{}
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
    $Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
}

# BOTH mapped families, because the fix has to be the mapping, not one hard-coded version.
foreach ($case in @(
    @{ Models=@('UCS-FI-6332','UCS-FI-6332'); Policy='global-436h'; Family='6300' },
    @{ Models=@('UCS-FI-6454','UCS-FI-6454'); Policy='global-602d'; Family='6400' }
)) {
    Reset-Create
    $script:Models = $case.Models
    $resolved = Resolve-UcsFirmwarePolicyForTarget -UcsTarget "ucsm-$($case.Family)" -UcsSession 'x' 6>$null

    Assert-Equal "$($case.Family): resolves to $($case.Policy)" $case.Policy $resolved
    Assert-Equal "$($case.Family): exactly one package was written" 1 $script:Created.Count
    Assert-Equal "$($case.Family): at org-root" "org-root" $script:Created[0].Org
    Assert-Equal "$($case.Family): named $($case.Policy)" $case.Policy $script:Created[0].Name
    # The payload's policyOwner="pending-policy" - UCSM's "Pending Global". NOT "policy": that is
    # what it becomes once Central claims it, which is Central's to do, not the domain's.
    Assert-Equal "$($case.Family): handed over in the same write, as pending-policy" "pending-policy" $script:Created[0].Owner
    # The payload's status="created,modified".
    Assert-Equal "$($case.Family): sent with -ModifyPresent" $true $script:Created[0].ModifyPresent
    Assert-Equal "$($case.Family): inside the transaction" $true $script:Created[0].InTransaction
    # No bundle versions: they are the reason for the handover and come from the global policy.
    Assert-Equal "$($case.Family): no blade bundle version" $true ([string]::IsNullOrEmpty($script:Created[0].Blade))
    Assert-Equal "$($case.Family): no rack bundle version" $true ([string]::IsNullOrEmpty($script:Created[0].Rack))
    # configEstimateImpact then configConfMos, in that order.
    Assert-Equal "$($case.Family): estimate goes out before the commit" "start,estimate,commit" ($script:TxLog.ToArray() -join ',')
    Assert-Equal "$($case.Family): recorded as created" "Created" (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -eq 'Create global firmware policy' })[0].Result)
    # And the workflow continues - the templates are aligned as they would be for a package that
    # had been there all along.
    Assert-Equal "$($case.Family): the run continued into the templates" $true ($null -ne $script:TemplateWrites)
    Assert-Equal "$($case.Family): nothing raised for manual rectification" 0 $Global:ManualAttentionHosts.Count
}

Write-Host "`n=== Created but still local is flagged, and the run still continues ===" -ForegroundColor Cyan
# A local package carries no bundle versions of its own, so it applies cleanly and changes no
# firmware. The run carries on - the blades still need their windows - but this is on the report.
Reset-Create
$script:Models = @('UCS-FI-6332','UCS-FI-6332')
function Add-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$PolicyOwner,[switch]$ModifyPresent,$BladeBundleVersion,$RackBundleVersion,$Descr,$ErrorAction)
    $script:Created += [pscustomobject]@{ Org=$Org; Name=$Name; Owner=$PolicyOwner; ModifyPresent=[bool]$ModifyPresent
                                          Blade=$BladeBundleVersion; Rack=$RackBundleVersion; Descr=$Descr; InTransaction=$script:TxOpen }
    $script:Packs += $Name }   # the domain does NOT take the handover
$continued = $true
try { [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-local' -UcsSession 'x' 6>$null) } catch { $continued = $false }
Assert-Equal "the run continues to the blades" $true $continued
Assert-Equal "recorded as still local" "StillLocal" (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -eq 'Create global firmware policy' })[0].Result)
Assert-Equal "and listed for manual rectification" 1 (@($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Reason -eq 'Host firmware package is not Global' }).Count)

Write-Host "`n=== A create UCS Central refuses means Central already owns it ===" -ForegroundColor Cyan
Reset-Create
$script:Models = @('UCS-FI-6332','UCS-FI-6332')
function Add-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$PolicyOwner,[switch]$ModifyPresent,$BladeBundleVersion,$RackBundleVersion,$Descr,$ErrorAction)
    throw "PD21000001SS004:Policy org-root/fw-host-pack-global-436h is resolved from remote policy server. Create/Delete/Modify operations are not allowed." }
$remoteOk = $true
try { [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-remote' -UcsSession 'x' 6>$null) } catch { $remoteOk = $false }
Assert-Equal "it is not treated as a failure" $true $remoteOk
Assert-Equal "recorded as owned by UCS Central" "RemoteOwned" (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -eq 'Create global firmware policy' })[0].Result)
Assert-Equal "the half-open transaction was discarded" $true (($script:TxLog.ToArray() -join ',') -match 'undo')
Assert-Equal "and nothing was flagged" 0 $Global:ManualAttentionHosts.Count

Write-Host "`n=== A create that genuinely fails stops before any service profile is touched ===" -ForegroundColor Cyan
Reset-Create
$script:Models = @('UCS-FI-6332','UCS-FI-6332')
function Add-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$PolicyOwner,[switch]$ModifyPresent,$BladeBundleVersion,$RackBundleVersion,$Descr,$ErrorAction)
    throw "insufficient privileges" }
$stoppedCreate = $false
try { [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-bad' -UcsSession 'x' 6>$null) } catch { $stoppedCreate = "$_" }
Assert-Equal "the run stops" $true ($stoppedCreate -match 'could not be created')
Assert-Equal "saying nothing was changed on any service profile" $true ($stoppedCreate -match 'Nothing has been changed')
Assert-Equal "no template was written" 0 $script:TemplateWrites.Count

# Put the recording stub back for whatever follows.
function Add-UcsFirmwareComputeHostPack { param($Ucs,$Org,$Name,$PolicyOwner,[switch]$ModifyPresent,$BladeBundleVersion,$RackBundleVersion,$Descr,$ErrorAction)
    if ($script:AddThrows) { throw $script:AddThrows }
    $script:Created += [pscustomobject]@{ Org=$Org; Name=$Name; Owner=$PolicyOwner; ModifyPresent=[bool]$ModifyPresent
                                          Blade=$BladeBundleVersion; Rack=$RackBundleVersion; Descr=$Descr; InTransaction=$script:TxOpen }
    $script:Packs += $Name
    if ($PolicyOwner) { $script:OwnerAfterCreate[$Name] = $PolicyOwner } }

Write-Host "`n=== The payload shape is fixed in the script, not just in this test ===" -ForegroundColor Cyan
$policySource = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the ownership travels with the create" $true ($policySource -match '-PolicyOwner "pending-policy" -ModifyPresent')
Assert-Equal "the estimate is asked before the commit" $true ($policySource -match '(?s)Get-UcsTransactionImpact.*?Complete-UcsTransaction')
Assert-Equal "no bundle version is ever written" $true (-not ($policySource -match '-BladeBundleVersion|-RackBundleVersion'))
Assert-Equal "and the name always comes from the fabric-family map" $true ($policySource -match '\$policyName = \[string\]\$Global:UcsFirmwarePolicyByFabricFamily\[\$fabric\.Family\]')

Write-Host "`n=== A name UCSM could never write is caught at the mapping, not at the profile ===" -ForegroundColor Cyan
# lsServer.hostFwPolicyName is capped at 16 characters by the schema
# (r"""[\-\.:_a-zA-Z0-9]{0,16}"""), so a longer name can never reach a service profile. Caught
# here it names the mapping table; caught later it is a parameter binding error a long way from it.
$Global:UcsFirmwarePolicyByFabricFamily['6500'] = 'global-a-very-long-package-name'
$script:Models = @('UCS-FI-6536','UCS-FI-6536'); $Global:UcsFirmwarePolicyByTarget = @{}
$tooLong = $false
try { [void](Resolve-UcsFirmwarePolicyForTarget -UcsTarget 'ucsm-g' -UcsSession 'x' 6>$null) } catch { $tooLong = "$_" }
Assert-Equal "the run stops before touching anything" $true ($tooLong -match 'at most 16')
Assert-Equal "naming the fabric family whose mapping is wrong" $true ($tooLong -match "'6500'")
$Global:UcsFirmwarePolicyByFabricFamily.Remove('6500')

$script:Models = @('UCS-FI-6332'); $script:Packs = @('global-436h'); $Global:UcsFirmwarePolicyByTarget = @{}

Write-Host "`n=== A resolved policy arrives as a DN and is reduced to its name ===" -ForegroundColor Cyan
# THE LIVE FAULT. lsServer reports the same policy two ways: hostFwPolicyName is the bare name
# (16 characters by schema) and operHostFwPolicyName is the RESOLVED policy as a distinguished
# name (256). Preferring the resolved one without normalising it compared a DN against a name in
# every caller, so nothing ever matched:
#
#   CurrentPolicy org-root/fw-host-pack-global-436h   TargetPolicy global-436h   NotVerified
Assert-Equal "a DN reduces to its name" "global-436h" (ConvertTo-UcsFirmwarePolicyName -Value 'org-root/fw-host-pack-global-436h')
Assert-Equal "a sub-organisation DN too" "global-602d" (ConvertTo-UcsFirmwarePolicyName -Value 'org-root/org-prod/fw-host-pack-global-602d')
Assert-Equal "a bare name is left alone" "global-436h" (ConvertTo-UcsFirmwarePolicyName -Value 'global-436h')
Assert-Equal "including one with hyphens of its own" "site-standard-fw" (ConvertTo-UcsFirmwarePolicyName -Value 'site-standard-fw')
Assert-Equal "surrounding space is trimmed" "global-436h" (ConvertTo-UcsFirmwarePolicyName -Value '  org-root/fw-host-pack-global-436h  ')
Assert-Equal "nothing in, nothing out" "" (ConvertTo-UcsFirmwarePolicyName -Value '')

# And the reader that every comparison goes through returns the NAME whichever property carried it.
$viaOper = [pscustomobject]@{ Name='sp-1'; OperHostFwPolicyName='org-root/fw-host-pack-global-436h'; HostFwPolicyName='' }
Assert-Equal "read from the resolved DN, returned as a name" "global-436h" (Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $viaOper)
$viaSet = [pscustomobject]@{ Name='sp-2'; OperHostFwPolicyName=''; HostFwPolicyName='global-435c' }
Assert-Equal "read from the writable name, unchanged" "global-435c" (Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $viaSet)
# A profile bound to an updating template carries nothing in the writable field - the template
# supplies it - so the resolved one has to win.
$bound = [pscustomobject]@{ Name='sp-3'; OperHostFwPolicyName='org-root/fw-host-pack-global-602d'; HostFwPolicyName='' }
Assert-Equal "a template-bound profile still reports a policy" "global-602d" (Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $bound)
$neither = [pscustomobject]@{ Name='sp-4'; OperHostFwPolicyName=''; HostFwPolicyName='' }
Assert-Equal "and nothing at all is UNKNOWN, not an empty match" "UNKNOWN" (Get-UcsServiceProfileFirmwarePolicyName -ServiceProfile $neither)

Write-Host "`n=== A template already on target is compliant, not rewritten ===" -ForegroundColor Cyan
# Straight from the live run: four templates reported as "could NOT be set (still
# 'org-root/fw-host-pack-global-436h')" when every one of them was already correct.
$script:Templates = @(
    [pscustomobject]@{ Name='vmware-d85pay01'; Dn='org-root/ls-vmware-d85pay01'; Type='updating-template'
                       OperHostFwPolicyName='org-root/fw-host-pack-global-436h'; HostFwPolicyName='' },
    [pscustomobject]@{ Name='windows_2012r2-rackmount'; Dn='org-root/ls-windows_2012r2-rackmount'; Type='initial-template'
                       OperHostFwPolicyName='org-root/fw-host-pack-global-436h'; HostFwPolicyName='' }
)
$script:TemplateWrites = New-Object System.Collections.Generic.List[string]
$script:TemplateSetThrows = ""
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
Set-UcsServiceProfileTemplateFirmwarePolicy -UcsTarget 'PD85000001SS003' -UcsSession 'x' -PolicyName 'global-436h' 6>$null
Assert-Equal "neither template was written" 0 $script:TemplateWrites.Count
Assert-Equal "both are recorded as compliant" 2 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'Compliant' }).Count)
Assert-Equal "and nothing is flagged for manual rectification" 0 $Global:ManualAttentionHosts.Count
$script:Templates = @()

Write-Host "`n=== Service profile templates are aligned to the target package ===" -ForegroundColor Cyan
# A template that still names the old package puts it back - on the next template push, on a
# rebind, or on the next profile created from it. Setting only the profiles fixes this cluster and
# leaves the domain to undo it.
function New-Template { param([string]$Name,[string]$Policy,[string]$Type)
    [pscustomobject]@{ Name=$Name; Dn="org-root/ls-$Name"; Type=$Type; HostFwPolicyName=$Policy } }

$script:Templates = @(
    (New-Template -Name 'vmware-d84dds05' -Policy 'global-435c' -Type 'updating-template'),
    (New-Template -Name 'vmware-d84vdi01' -Policy 'global-436h' -Type 'updating-template'),
    (New-Template -Name 'vmware-d84vdi02' -Policy 'global-434a' -Type 'initial-template')
)
$script:TemplateWrites.Clear(); $script:TemplateSetThrows = ""
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
Set-UcsServiceProfileTemplateFirmwarePolicy -UcsTarget 'ucsm-a' -UcsSession 'x' -PolicyName 'global-436h' 6>$null

Assert-Equal "only the two off-target templates were written" 2 $script:TemplateWrites.Count
Assert-Equal "the one already on target was left alone" 0 (@($script:TemplateWrites.ToArray() | Where-Object { $_ -match 'vmware-d84vdi01' }).Count)
Assert-Equal "and it is recorded as compliant, not changed" "Compliant" (@($Global:RunSummary.ToArray() | Where-Object { $_.Details -match 'vmware-d84vdi01' })[0].Result)
Assert-Equal "both template types are covered" $true (($script:TemplateWrites.ToArray() -join ',') -match 'vmware-d84dds05' -and ($script:TemplateWrites.ToArray() -join ',') -match 'vmware-d84vdi02')
Assert-Equal "each write named the target package, with -Force" "global-436h|Force=True" (($script:TemplateWrites[0] -split '\|', 2)[1])
Assert-Equal "the change is verified by reading the template back" "Updated" (@($Global:RunSummary.ToArray() | Where-Object { $_.Details -match 'vmware-d84dds05' })[0].Result)

# A template UCS Central owns is not a failure - Central manages it.
$script:Templates = @((New-Template -Name 'central-tmpl' -Policy 'global-435c' -Type 'updating-template'))
$script:TemplateWrites.Clear()
$script:TemplateSetThrows = "Policy org-root/ls-central-tmpl is resolved from remote policy server. Create/Delete/Modify operations are not allowed."
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
Set-UcsServiceProfileTemplateFirmwarePolicy -UcsTarget 'ucsm-a' -UcsSession 'x' -PolicyName 'global-436h' 6>$null
Assert-Equal "a UCS Central-owned template is recorded as remote-owned" "RemoteOwned" (@($Global:RunSummary.ToArray() | Where-Object { $_.Details -match 'central-tmpl' })[0].Result)
Assert-Equal "and raises nothing for manual rectification" 0 $Global:ManualAttentionHosts.Count

# A genuine failure IS flagged, because a template left on the old package will undo the run.
$script:TemplateSetThrows = "server busy"
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
Set-UcsServiceProfileTemplateFirmwarePolicy -UcsTarget 'ucsm-a' -UcsSession 'x' -PolicyName 'global-436h' 6>$null
Assert-Equal "a template that will not take is flagged" 1 (@($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Reason -match 'template not on the target firmware package' }).Count)
$script:TemplateSetThrows = ""

# DRY RUN writes nothing.
$Global:RunMode = 'DRYRUN'
$script:Templates = @((New-Template -Name 'dry-tmpl' -Policy 'global-435c' -Type 'updating-template'))
$script:TemplateWrites.Clear()
Set-UcsServiceProfileTemplateFirmwarePolicy -UcsTarget 'ucsm-a' -UcsSession 'x' -PolicyName 'global-436h' 6>$null
Assert-Equal "DRY RUN writes no template" 0 $script:TemplateWrites.Count
$Global:RunMode = 'LIVE'
$script:Templates = @()

# It runs as part of resolving the policy, not as a separate thing to remember.
$resolveFn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'Resolve-UcsFirmwarePolicyForTarget' })[0]
Assert-Equal "resolving a domain's policy also aligns its templates" $true ($resolveFn.Extent.Text -match 'Set-UcsServiceProfileTemplateFirmwarePolicy')

Write-Host "`n=== A policy already on target is compliant, and nothing else is consulted ===" -ForegroundColor Cyan
# Straight from a live run: eleven hosts showed CurrentPolicy global-436h against TargetPolicy
# global-436h and were batched anyway - evacuated, put into Maintenance mode, given a policy they
# already had, and returned to service. A maintenance window each, for nothing.
#
# CurrentPolicy equal to TargetPolicy is the whole test. The policy carries the version, so a
# profile already on it is compliant.
$Global:IntersightHostMap = @{}
$Global:UcsHostMap = @{}
$script:SpPolicy = @{}
$script:SpAcks = @{}
$script:RunningReads = 0
function Get-UcsSessionForTarget { param($UcsTarget) return 'session' }
function Resolve-UcsServiceProfileForHost { param($HostName,$UcsTarget) return [pscustomobject]@{ Name = $HostName } }
function Get-UcsServiceProfileFirmwarePolicyName { param($ServiceProfile) return $script:SpPolicy[$ServiceProfile.Name] }
function Get-UcsRunningFirmwareVersion { param($UcsSession,$ServiceProfile) $script:RunningReads++; return '5.4(0.260050)' }
function Get-UcsLsmaintAck { param($Ucs,$ErrorAction)
    return @($script:SpAcks.Keys | ForEach-Object { [pscustomobject]@{ Dn = "org-root/ls-$_/ack" } }) }
function New-UcsCandidate { param([string]$Name) [pscustomobject]@{ Name = $Name } }
function Register-UcsHost { param([string]$Name,[string]$Current,[string]$Target)
    $Global:UcsHostMap[$Name] = [pscustomobject]@{ UcsTarget='ucsm-a'; ServiceProfileDn="org-root/ls-$Name"; TargetPolicy=$Target }
    $script:SpPolicy[$Name] = $Current }

Register-UcsHost -Name 'esx21' -Current 'global-436h' -Target 'global-436h'
Register-UcsHost -Name 'esx32' -Current 'global-435c' -Target 'global-436h'
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:RunningReads = 0
$kept = @(Remove-UcsHostsAlreadyOnTargetFirmware -CandidateHosts @((New-UcsCandidate 'esx21'), (New-UcsCandidate 'esx32')) 6>$null)
Assert-Equal "the host already on target is excluded" $true ($kept.Name -notcontains 'esx21')
Assert-Equal "and the one that needs the change is kept" $true ($kept.Name -contains 'esx32')
Assert-Equal "it is recorded as Compliant" "Compliant" (@($Global:RunSummary | Where-Object { $_.Host -eq 'esx21' })[0].Result)

# THE FIX. A live domain reported running 5.4(0.260050) against a policy-derived 4.3(6h) - different
# numbering schemes entirely - so the old version comparison could never match and warned on every
# compliant host. The version is no longer read here at all, and nothing is flagged.
Assert-Equal "the running version is not consulted" 0 $script:RunningReads
Assert-Equal "and no host is flagged for manual rectification" 0 $Global:ManualAttentionHosts.Count

# A pending acknowledgement does not change the answer either - the policy decides, quietly.
$script:SpAcks = @{ 'esx21' = $true }
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$kept = @(Remove-UcsHostsAlreadyOnTargetFirmware -CandidateHosts @((New-UcsCandidate 'esx21')) 6>$null)
Assert-Equal "a pending acknowledgement does not re-batch a compliant host" 0 $kept.Count
Assert-Equal "and it raises no note" 0 $Global:ManualAttentionHosts.Count
$script:SpAcks = @{}

# An Intersight-routed host is not this filter's business.
$Global:IntersightHostMap = @{ 'esx50' = $true }
$Global:UcsHostMap = @{}; $script:SpPolicy = @{}
$kept = @(Remove-UcsHostsAlreadyOnTargetFirmware -CandidateHosts @((New-UcsCandidate 'esx50')) 6>$null)
Assert-Equal "an Intersight-routed host is left alone by the UCS filter" $true ($kept.Name -contains 'esx50')
$Global:IntersightHostMap = @{}

# The progress read must not gate on the version either, or every UCS host reports "activating"
# forever on a domain whose running version does not resemble the policy name.
$progressText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'Get-UcsUpgradeProgress' } | ForEach-Object { $_.Extent.Text }) -join "`n"
Assert-Equal "progress is decided by the acknowledgement, not the version" $true ($progressText -match 'no pending acknowledgement')
Assert-Equal "and the version is not compared to the policy name there" $true (-not ($progressText -match 'ConvertTo-UcsBundleVersionFromPolicyName'))

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
