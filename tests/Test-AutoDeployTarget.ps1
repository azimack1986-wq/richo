<#
.SYNOPSIS
    Tests that the ESXi target comes from the cluster's Auto Deploy rule, and that the hosts needing
    work are the ones whose running image profile differs from it.

.DESCRIPTION
    The target used to be a string in the script. That is wrong in the way that is hardest to
    notice: these hosts are stateless and boot the image profile Auto Deploy hands them, so the
    rule IS the target. A version pinned in the script disagreed with the rule the moment anyone
    edited the rule, and the script would then have been the one deciding what "current" meant -
    marking hosts compliant that were about to boot something else, or rebooting hosts with nothing
    to gain.

    The properties asserted here:

      - the target is read from the rule, never assumed;
      - a rule item is identified as an image profile by TYPE, not by hoping the name looks right,
        so the host profile or the cluster in the same ItemList is never mistaken for it;
      - a cluster whose rules name DIFFERENT image profiles is reported, not silently resolved;
      - a host that cannot be asked is NOT treated as compliant;
      - nothing in the script pins a version any more.

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-AutoDeployTarget.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-ImageProfileNameFromItem','Get-ClusterDeployRuleTarget',
                                 'Get-VMHostRunningImageProfileName','Test-VMHostOnTargetImageProfile',
                                 'Resolve-ClusterEsxiTarget','Show-ClusterEsxiTargetComparison') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

$Global:RunSummary = New-Object System.Collections.Generic.List[object]
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Action=$Action; Result=$Result; Details=$Details }) }
function Stop-SafeExit { param($Message) throw "EXIT: $Message" }

$Global:TargetImageProfileName = ''
$Global:TargetEsxiBuild = ''
$Global:TargetDeployRuleName = ''
$Global:HostImageProfileCache = @{}

# The real type, so identification by type can be exercised rather than assumed.
if (-not ('VMware.ImageBuilder.Types.ImageProfile' -as [type])) {
    Add-Type -TypeDefinition @'
namespace VMware.ImageBuilder.Types {
    public class ImageProfile { public string Name; public object VibList; }
}
'@
}
function New-ImageProfile { param($Name)
    $p = New-Object VMware.ImageBuilder.Types.ImageProfile
    $p.Name = $Name
    return $p }

$cluster = [pscustomobject]@{ Name = 'd85cvt02' }
$hosts = @(
    [pscustomobject]@{ Name = 'esx01'; Build = '20000000' }
    [pscustomobject]@{ Name = 'esx02'; Build = '25429389' })

$script:Rules = @()
$script:MatchThrows = $false
$script:Running = @{}
$script:EsxCliThrowsFor = @()
function Get-DeployRule { param($Name,$ErrorAction) return @($script:Rules) }
function Get-VMHostMatchingRules { param($VMHost,$ErrorAction)
    if ($script:MatchThrows) { throw "Auto Deploy did not answer" }
    return @($script:Rules) }
function Get-EsxCli { param($VMHost,[switch]$V2,$ErrorAction)
    if ($script:EsxCliThrowsFor -contains [string]$VMHost.Name) { throw "host not reachable" }
    $name = [string]$script:Running[[string]$VMHost.Name]
    return [pscustomobject]@{ software = [pscustomobject]@{ profile = [pscustomobject]@{
        get = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name Invoke -Value ([scriptblock]::Create("[pscustomobject]@{ Name = '$name' }")) -PassThru } } } }

function Reset-Fixture {
    $script:Rules = @([pscustomobject]@{ Name = 'd85cvt02-rule'
        PatternList = @('domain=dpe.protected.mil.au')
        ItemList = @((New-ImageProfile -Name 'ESXi-8.0U3j-25429389-standard'), 'd85cvt02', 'd85cvt02_profile') })
    $script:MatchThrows = $false
    $script:EsxCliThrowsFor = @()
    $script:Running = @{ 'esx01' = 'ESXi-8.0U3a-20000000-standard'; 'esx02' = 'ESXi-8.0U3j-25429389-standard' }
    $Global:HostImageProfileCache = @{}
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
}

Write-Host "`n=== A rule item is identified as an image profile by TYPE ===" -ForegroundColor Cyan
# The ItemList is mixed - image profile, cluster, host profile. Picking the wrong one gives the run
# a target that is not a target at all, silently.
Assert-Equal "the image profile object is picked out" "ESXi-8.0U3j-25429389-standard" (Get-ImageProfileNameFromItem -Item (New-ImageProfile -Name 'ESXi-8.0U3j-25429389-standard'))
Assert-Equal "the cluster name is not an image profile" "" (Get-ImageProfileNameFromItem -Item 'd85cvt02')
Assert-Equal "nor is the host profile" "" (Get-ImageProfileNameFromItem -Item 'd85cvt02_profile')
Assert-Equal "a null item is not one either" "" (Get-ImageProfileNameFromItem -Item $null)
# A rule built by name holds strings. Those are matched on the shape of an ESXi profile name.
Assert-Equal "a profile named as a string is recognised" "ESXi-8.0U3j-25429389-standard" (Get-ImageProfileNameFromItem -Item 'ESXi-8.0U3j-25429389-standard')
Assert-Equal "an arbitrary string is not" "" (Get-ImageProfileNameFromItem -Item 'Production Hosts')

Write-Host "`n=== The target is read from the rule ===" -ForegroundColor Cyan
Reset-Fixture
$target = Get-ClusterDeployRuleTarget -Cluster $cluster -Hosts $hosts 6>$null
Assert-Equal "the image profile comes from the rule" "ESXi-8.0U3j-25429389-standard" $target.Name
Assert-Equal "and the rule is named" "d85cvt02-rule" $target.Rule

Reset-Fixture
Resolve-ClusterEsxiTarget -Cluster $cluster -Hosts $hosts 6>$null
Assert-Equal "the run's target is set from it" "ESXi-8.0U3j-25429389-standard" $Global:TargetImageProfileName
Assert-Equal "with the build derived for the reports" "25429389" $Global:TargetEsxiBuild
Assert-Equal "and recorded" "Resolved" (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -eq 'Resolve ESXi target' })[-1].Result)

Write-Host "`n=== Per-host rules first, the rule set second ===" -ForegroundColor Cyan
# Get-VMHostMatchingRules is the appliance answering "which rules apply to THIS host", so nothing
# here has to parse a PatternList. When it cannot answer, a rule that PLACES hosts in this cluster
# is this cluster's rule - which also covers a host that is powered off or not yet known.
Reset-Fixture
$script:MatchThrows = $true
$target = Get-ClusterDeployRuleTarget -Cluster $cluster -Hosts $hosts 6>$null
Assert-Equal "the rule set is searched by cluster" "ESXi-8.0U3j-25429389-standard" $target.Name

# A rule that does not place hosts in this cluster is not this cluster's rule.
Reset-Fixture
$script:MatchThrows = $true
$script:Rules = @([pscustomobject]@{ Name = 'other-rule'
    ItemList = @((New-ImageProfile -Name 'ESXi-7.0U3-19999999-standard'), 'SomeOtherCluster') })
$target = Get-ClusterDeployRuleTarget -Cluster $cluster -Hosts $hosts 6>$null
Assert-Equal "another cluster's rule is ignored" "" $target.Name

Write-Host "`n=== One image per cluster, required of every host in it ===" -ForegroundColor Cyan
# A cluster is expected to have one image profile across its rules - that is what the rules are
# for - and every host in it is required to be on it. Where the rules disagree, the most-cited one
# is taken and the disagreement goes on the record: a rule set that wants tidying is not a reason
# to abandon a change window, but it is never silent.
Reset-Fixture
$script:Rules = @(
    [pscustomobject]@{ Name = 'rule-a'; ItemList = @((New-ImageProfile -Name 'ESXi-8.0U3j-25429389-standard'), 'd85cvt02') }
    [pscustomobject]@{ Name = 'rule-b'; ItemList = @((New-ImageProfile -Name 'ESXi-8.0U3j-25429389-standard'), 'd85cvt02') }
    [pscustomobject]@{ Name = 'rule-c'; ItemList = @((New-ImageProfile -Name 'ESXi-8.0U3k-26000000-standard'), 'd85cvt02') })
$target = Get-ClusterDeployRuleTarget -Cluster $cluster -Hosts $hosts 6>$null
Assert-Equal "the most-cited profile is used" "ESXi-8.0U3j-25429389-standard" $target.Name
$out = Get-ClusterDeployRuleTarget -Cluster $cluster -Hosts $hosts 6>&1
$text = ($out | Out-String)
Assert-Equal "the disagreement is reported" $true (($text -match '8.0U3j') -and ($text -match '8.0U3k'))
Assert-Equal "with the chosen one marked" $true ($text -match '\[USING\] ESXi-8.0U3j')
Assert-Equal "and the other marked ignored" $true ($text -match '\[ignored\] ESXi-8.0U3k')
Assert-Equal "and it goes to the run summary" "Ambiguous" (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -eq 'Resolve ESXi target' })[-1].Result)
# Deterministic on a tie - alphabetical - so two runs of the same rule set never differ.
Reset-Fixture
$script:Rules = @(
    [pscustomobject]@{ Name = 'rule-z'; ItemList = @((New-ImageProfile -Name 'ESXi-8.0U3k-26000000-standard'), 'd85cvt02') }
    [pscustomobject]@{ Name = 'rule-a'; ItemList = @((New-ImageProfile -Name 'ESXi-8.0U3j-25429389-standard'), 'd85cvt02') })
Assert-Equal "a tie is broken by name, not by rule order" "ESXi-8.0U3j-25429389-standard" (Get-ClusterDeployRuleTarget -Cluster $cluster -Hosts $hosts 6>$null).Name

# The requirement is stated cluster-wide, not implied.
Reset-Fixture
$out = Resolve-ClusterEsxiTarget -Cluster $cluster -Hosts $hosts 6>&1
Assert-Equal "every host is said to require it" $true (($out | Out-String) -match "Every host in 'd85cvt02' is required to be on 'ESXi-8.0U3j-25429389-standard'")

Write-Host "`n=== The hosts that differ are the hosts that need updating ===" -ForegroundColor Cyan
Reset-Fixture
Resolve-ClusterEsxiTarget -Cluster $cluster -Hosts $hosts 6>$null
Assert-Equal "the host on an older profile needs work" $false (Test-VMHostOnTargetImageProfile -VMHostObject $hosts[0])
Assert-Equal "the host already on it does not" $true (Test-VMHostOnTargetImageProfile -VMHostObject $hosts[1])
$differ = @(Show-ClusterEsxiTargetComparison -Hosts $hosts 6>$null)
Assert-Equal "exactly one host is listed" 1 $differ.Count
Assert-Equal "and it is the right one" "esx01" $differ[0].Name

Write-Host "`n=== A host that cannot be asked is NOT compliant ===" -ForegroundColor Cyan
# Assuming a host that will not answer is already current is how a host gets skipped and left
# behind its cluster.
Reset-Fixture
Resolve-ClusterEsxiTarget -Cluster $cluster -Hosts $hosts 6>$null
$script:EsxCliThrowsFor = @('esx01','esx02')
$Global:HostImageProfileCache = @{}
Assert-Equal "an unreadable host on another build stays in scope" $false (Test-VMHostOnTargetImageProfile -VMHostObject $hosts[0])
# Where the build DOES match, that is accepted as a fallback: weaker than the profile name, since
# two profiles can share a build, but better than treating a reachable host as unknown.
Assert-Equal "a matching build is accepted as a fallback" $true (Test-VMHostOnTargetImageProfile -VMHostObject $hosts[1])
# With no target at all, nothing is compliant - the run does not quietly decide there is no work.
$Global:TargetImageProfileName = ''
$Global:TargetEsxiBuild = ''
Assert-Equal "and with no target nothing is compliant" $false (Test-VMHostOnTargetImageProfile -VMHostObject $hosts[1])

Write-Host "`n=== esxcli is asked once per host ===" -ForegroundColor Cyan
Reset-Fixture
$Global:TargetImageProfileName = 'ESXi-8.0U3j-25429389-standard'
$script:EsxCliCalls = 0
function Get-EsxCli { param($VMHost,[switch]$V2,$ErrorAction)
    $script:EsxCliCalls++
    return [pscustomobject]@{ software = [pscustomobject]@{ profile = [pscustomobject]@{
        get = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name Invoke -Value { [pscustomobject]@{ Name = 'ESXi-8.0U3j-25429389-standard' } } -PassThru } } } }
[void](Get-VMHostRunningImageProfileName -VMHostObject $hosts[0])
[void](Get-VMHostRunningImageProfileName -VMHostObject $hosts[0])
[void](Test-VMHostOnTargetImageProfile -VMHostObject $hosts[0])
Assert-Equal "cached after the first read" 1 $script:EsxCliCalls
# The closing verification exists to read state AFTER the change, so it must bypass the cache.
[void](Get-VMHostRunningImageProfileName -VMHostObject $hosts[0] -Refresh)
Assert-Equal "and -Refresh asks again" 2 $script:EsxCliCalls

Write-Host "`n=== Nothing pins a version any more ===" -ForegroundColor Cyan
$sourceText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "no TargetEsxiVersion setting remains" $false ($sourceText -match '\$TargetEsxiVersion\s*=')
Assert-Equal "no hard-coded ESXi build remains" $false ($sourceText -match '\$TargetEsxiBuild\s*=\s*"\d')
Assert-Equal "the target is resolved per cluster" $true ($sourceText -match 'Resolve-ClusterEsxiTarget -Cluster \$Cluster -Hosts \$allClusterHosts')
# ...and before anything decides which hosts are in scope.
Assert-Equal "before the in-scope decision" $true (
    $sourceText.IndexOf('Resolve-ClusterEsxiTarget -Cluster $Cluster') -lt
    $sourceText.IndexOf('$patchCandidateHosts = @($allClusterHosts'))
Assert-Equal "and Auto Deploy is loaded with the other modules" $true ($sourceText -match 'VMware\.DeployAutomation')

Write-Host "`n=== A FIRMWARE run does not check the ESXi target at all ===" -ForegroundColor Cyan
# The work there is the UCS firmware, every host is in scope whatever image it is on, and nothing
# downstream consults the answer. Reading it anyway would mean an Auto Deploy call and an esxcli
# round trip per host to produce a table nobody acts on - and a column headed UPDATE that nothing
# is going to update.
$sourceText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the resolve is gated on ESXi-only mode" $true ($sourceText -match '(?s)if \(\$Global:UpgradeMode -eq "ESXI_ONLY"\) \{\s*Resolve-ClusterEsxiTarget -Cluster \$Cluster -Hosts \$allClusterHosts')
Assert-Equal "and so is the comparison" $true ($sourceText -match '(?s)if \(\$Global:UpgradeMode -eq "ESXI_ONLY"\).*?Show-ClusterEsxiTargetComparison -Hosts \$allClusterHosts')
# Called in exactly one place each - no second, ungated call anywhere.
Assert-Equal "resolved once" 1 ([regex]::Matches($sourceText, 'Resolve-ClusterEsxiTarget -Cluster \$Cluster').Count)
# The assignment form, so the .EXAMPLE line in the function's own help is not counted as a call.
Assert-Equal "compared once" 1 ([regex]::Matches($sourceText, '\$needEsxiUpdateHosts = @\(Show-ClusterEsxiTargetComparison').Count)
# Nothing is carried over from a previous cluster, so the closing verification reports n/a rather
# than measuring a firmware cluster against a target it never checked.
Assert-Equal "the firmware branch clears the target" $true ($sourceText -match '(?s)else \{[^}]*\$Global:TargetImageProfileName = ""[^}]*\$Global:TargetEsxiBuild = ""')
# The advisory machinery is gone rather than merely unused.
Assert-Equal "no advisory switch remains" $false ($sourceText -match '\-Advisory')
Assert-Equal "and no information-only labelling" $false ($sourceText -match 'FOR INFORMATION ONLY')
# With no target, nothing reads as compliant - the verification says n/a, it does not guess.
$Global:TargetImageProfileName = ''
$Global:TargetEsxiBuild = ''
Assert-Equal "no target means no host is on target" $false (Test-VMHostOnTargetImageProfile -VMHostObject $hosts[1])

# An ESXi-only run is unchanged: it resolves, it asks when Auto Deploy cannot be read, and it stops
# if the operator says so.
Reset-Fixture
$script:MatchThrows = $true
$script:Rules = @()
$script:AskedForProfile = $false
function Read-Host { param($Prompt) $script:AskedForProfile = $true; return '' }
[void](Resolve-ClusterEsxiTarget -Cluster $cluster -Hosts $hosts 6>$null)
Assert-Equal "an ESXi-only run still asks for the image profile" $true $script:AskedForProfile
Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
