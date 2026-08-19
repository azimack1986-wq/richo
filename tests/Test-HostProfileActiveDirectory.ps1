<#
.SYNOPSIS
    Tests that ONLY the Active Directory settings in a cluster's host profile are unticked and
    re-ticked, and that nothing else in the profile is touched.

.DESCRIPTION
    The instruction was exact: untick the Active Directory settings when the cluster is selected,
    re-tick them when the cluster completes, and do not update, copy or modify any other setting.

    A host profile is a tree of ApplyProfile nodes, each with an Enabled flag - the tick box in the
    Edit host profile dialog. The ones in scope, from the vSphere API:

        authentication                  Authentication Configuration
          activeDirectory               Active Directory Configuration
        security/permission[n]          Active Directory Permission and its principal

    and the ones sitting alongside them that must come through untouched: Role, User Configuration,
    Lockdown Mode, Host Acceptance Level, Firewall Configuration, Service Configuration.

    The strongest assertion here is the negative one: a snapshot of every OTHER node's Enabled flag
    before and after, compared. A change to any of them fails the test.

    Standalone - no Pester, no PowerCLI, no vCenter.

.EXAMPLE
    pwsh -File ./tests/Test-HostProfileActiveDirectory.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-HostProfileApplyNode','Test-HostProfileActiveDirectoryNode',
                                 'Get-ClusterHostProfile','Set-ClusterHostProfileActiveDirectory','Test-DryRun') } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name,$Expected,$Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

$Global:RunMode = 'LIVE'
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$Global:HostProfileAdChanges = @{}
$Global:HostProfileActiveDirectoryPatterns = @('(?i)^authentication','(?i)activedirectory')
function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Action=$Action; Result=$Result; Details=$Details }) }
function Add-ManualAttentionHost { param($HostName,$Reason,$Detail,[switch]$ExcludeFromRun)
    $Global:ManualAttentionHosts.Add([pscustomobject]@{ Host=$HostName; Reason=$Reason; Detail=$Detail }) }

# --- A host profile shaped like the real one ----------------------------------------------------
# Mirrors the vSphere API: every node has Enabled and ProfileTypeName; HostApplyProfile exposes
# typed children; generic subprofiles hang off Property[] with a PropertyName and a Profile[].
function New-Node { param([string]$Type,[bool]$Enabled = $true)
    [pscustomobject]@{ Enabled = $Enabled; ProfileTypeName = $Type; ProfileVersion = '8.0'; Policy = @(); Property = @() } }

function New-TestProfileTree {
    $adConfig  = New-Node -Type 'ActiveDirectoryProfile'
    $auth      = New-Node -Type 'AuthenticationProfile'
    $auth | Add-Member -MemberType NoteProperty -Name ActiveDirectory -Value $adConfig

    $principal = New-Node -Type 'ActiveDirectoryPermissionProfile'
    $adPerm    = New-Node -Type 'ActiveDirectoryPermissionProfile'
    $adPerm    | Add-Member -MemberType NoteProperty -Name Key -Value 'DPE\res-d-vmware-esxi-admins'
    $adPerm.Property = @([pscustomobject]@{ PropertyName = 'principal'; Array = $false; Profile = @($principal) })

    # Everything else under Security, which must come through untouched.
    $rolePerm  = New-Node -Type 'PermissionProfile'
    $rolePerm  | Add-Member -MemberType NoteProperty -Name Key -Value 'root'

    $security  = New-Node -Type 'SecurityProfile'
    $security  | Add-Member -MemberType NoteProperty -Name Permission -Value @($adPerm, $rolePerm)
    $security.Property = @([pscustomobject]@{ PropertyName = 'role'; Array = $true
                                              Profile = @((New-Node -Type 'RoleProfile'), (New-Node -Type 'UserConfigurationProfile')) },
                           [pscustomobject]@{ PropertyName = 'lockdown'; Array = $false
                                              Profile = @((New-Node -Type 'LockdownModeProfile')) })

    $root = New-Node -Type 'HostApplyProfile'
    $root | Add-Member -MemberType NoteProperty -Name Authentication -Value $auth
    $root | Add-Member -MemberType NoteProperty -Name Security -Value $security
    $root | Add-Member -MemberType NoteProperty -Name Firewall -Value (New-Node -Type 'FirewallProfile')
    $root | Add-Member -MemberType NoteProperty -Name Service -Value @((New-Node -Type 'ServiceProfile'))
    return $root
}

$script:Updates = New-Object System.Collections.Generic.List[object]
$script:UpdateThrows = ""
function New-TestHostProfile {
    $tree = New-TestProfileTree
    $view = [pscustomobject]@{
        Name = 'd85mgt01_profile'
        Config = [pscustomobject]@{ ApplyProfile = $tree; Annotation = 'do not touch me'; Enabled = $true }
    }
    $view | Add-Member -MemberType ScriptMethod -Name UpdateHostProfile -Value {
        param($spec)
        if ($script:UpdateThrows) { throw $script:UpdateThrows }
        $script:Updates.Add($spec)
    }
    return [pscustomobject]@{ Name = 'd85mgt01_profile'; ExtensionData = $view }
}

$script:Profiles = @()
function Get-VMHostProfile { param($Entity,$ErrorAction) return @($script:Profiles) }
# The real spec type is not available off-vCenter; this stands in for it and records what was set.
if (-not ('VMware.Vim.HostProfileCompleteConfigSpec' -as [type])) {
    Add-Type -TypeDefinition @'
namespace VMware.Vim {
    public class HostProfileCompleteConfigSpec {
        public string Name;
        public string Annotation;
        public object Enabled;
        public object ApplyProfile;
        public bool DisabledExpressionListChanged;
    }
}
'@
}

$cluster = [pscustomobject]@{ Name = 'd85sql01' }

function Get-EnabledSnapshot { param($Tree)
    $map = @{}
    foreach ($row in (Get-HostProfileApplyNode -Node $Tree)) { $map["$($row.Path)|$($row.ProfileTypeName)"] = [bool]$row.Node.Enabled }
    return $map
}

Write-Host "`n=== The whole tree is walked, typed children and generic subprofiles alike ===" -ForegroundColor Cyan
$tree = New-TestProfileTree
$nodes = @(Get-HostProfileApplyNode -Node $tree)
# root, authentication, activeDirectory, the AD permission and its principal, the role permission,
# security, role, user configuration, lockdown, firewall, service.
Assert-Equal "every node was found" 12 $nodes.Count
Assert-Equal "the typed Authentication child is reached" 1 (@($nodes | Where-Object { $_.ProfileTypeName -eq 'AuthenticationProfile' }).Count)
Assert-Equal "its ActiveDirectory child too" 1 (@($nodes | Where-Object { $_.ProfileTypeName -eq 'ActiveDirectoryProfile' }).Count)
Assert-Equal "the Permission array is reached" 1 (@($nodes | Where-Object { $_.ProfileTypeName -eq 'PermissionProfile' }).Count)
Assert-Equal "and nodes behind Property[] containers are reached" 1 (@($nodes | Where-Object { $_.ProfileTypeName -eq 'LockdownModeProfile' }).Count)
Assert-Equal "paths are stable and descriptive" $true ((@($nodes | ForEach-Object { $_.Path }) -join ',') -match 'Security/Permission\[0\]')

Write-Host "`n=== Only Active Directory profile types match ===" -ForegroundColor Cyan
foreach ($type in @('AuthenticationProfile','ActiveDirectoryProfile','ActiveDirectoryPermissionProfile')) {
    Assert-Equal "'$type' is an AD setting" $true (Test-HostProfileActiveDirectoryNode -ProfileTypeName $type)
}
# The ones sitting alongside them in the same dialog. A false positive here would silently disable
# lockdown mode or the local user configuration on every host in the cluster.
foreach ($type in @('RoleProfile','UserConfigurationProfile','LockdownModeProfile','PermissionProfile',
                    'SecurityProfile','FirewallProfile','ServiceProfile','HostAcceptanceLevelProfile',
                    'HostApplyProfile','DomainSettingsProfile')) {
    Assert-Equal "'$type' is NOT an AD setting" $false (Test-HostProfileActiveDirectoryNode -ProfileTypeName $type)
}
Assert-Equal "an empty type is not an AD setting" $false (Test-HostProfileActiveDirectoryNode -ProfileTypeName '')

Write-Host "`n=== Unticking touches the AD settings and NOTHING else ===" -ForegroundColor Cyan
$script:Profiles = @(New-TestHostProfile)
$script:Updates.Clear(); $Global:HostProfileAdChanges = @{}
$tree = $script:Profiles[0].ExtensionData.Config.ApplyProfile
$before = Get-EnabledSnapshot -Tree $tree

Set-ClusterHostProfileActiveDirectory -Cluster $cluster -Enable $false 6>$null
$after = Get-EnabledSnapshot -Tree $tree

$adKeys = @($before.Keys | Where-Object { $_ -match 'Authentication|ActiveDirectory' })
Assert-Equal "the AD settings are all off" 0 (@($adKeys | Where-Object { $after[$_] }).Count)
# THE NEGATIVE ASSERTION. Every other flag must be byte-identical.
$others = @($before.Keys | Where-Object { $_ -notmatch 'Authentication|ActiveDirectory' })
$drifted = @($others | Where-Object { $before[$_] -ne $after[$_] })
Assert-Equal "no other setting changed" 0 $drifted.Count
Assert-Equal "one update was written" 1 $script:Updates.Count
Assert-Equal "carrying the name through unchanged" "d85mgt01_profile" $script:Updates[0].Name
Assert-Equal "and the annotation unchanged" "do not touch me" $script:Updates[0].Annotation
Assert-Equal "the disabled expression list is left alone" $false $script:Updates[0].DisabledExpressionListChanged
Assert-Equal "the profile's own tree was submitted, not a rebuilt one" $true ([object]::ReferenceEquals($script:Updates[0].ApplyProfile, $tree))

Write-Host "`n=== Re-ticking restores exactly what was unticked ===" -ForegroundColor Cyan
$script:Updates.Clear()
Set-ClusterHostProfileActiveDirectory -Cluster $cluster -Enable $true 6>$null
$restored = Get-EnabledSnapshot -Tree $tree
$changed = @($before.Keys | Where-Object { $before[$_] -ne $restored[$_] })
Assert-Equal "the profile is back exactly as it was found" 0 $changed.Count
Assert-Equal "one update was written" 1 $script:Updates.Count

Write-Host "`n=== A setting already unticked by hand stays unticked ===" -ForegroundColor Cyan
# The operator may have turned Active Directory Configuration off for their own reasons. Turning it
# back on at the end would be this run making a change nobody asked for.
$script:Profiles = @(New-TestHostProfile)
$Global:HostProfileAdChanges = @{}
$tree = $script:Profiles[0].ExtensionData.Config.ApplyProfile
$tree.Authentication.ActiveDirectory.Enabled = $false
Set-ClusterHostProfileActiveDirectory -Cluster $cluster -Enable $false 6>$null
Set-ClusterHostProfileActiveDirectory -Cluster $cluster -Enable $true 6>$null
Assert-Equal "the one the operator had already turned off is still off" $false $tree.Authentication.ActiveDirectory.Enabled
Assert-Equal "the one this run turned off is back on" $true $tree.Authentication.Enabled

Write-Host "`n=== Nothing to do is not an error ===" -ForegroundColor Cyan
$script:Profiles = @()
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
Set-ClusterHostProfileActiveDirectory -Cluster $cluster -Enable $false 6>$null
Assert-Equal "a cluster with no host profile is reported, not failed" "NoProfile" (@($Global:RunSummary.ToArray())[-1].Result)

Write-Host "`n=== A profile that cannot be written is reported, never thrown ===" -ForegroundColor Cyan
# This is a pre-requisite, not the change itself. It must not take a cluster down with it.
$script:Profiles = @(New-TestHostProfile)
$Global:HostProfileAdChanges = @{}
$Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
$script:UpdateThrows = "insufficient privileges"
$threw = $false
try { Set-ClusterHostProfileActiveDirectory -Cluster $cluster -Enable $false 6>$null } catch { $threw = $true }
$script:UpdateThrows = ""
Assert-Equal "it does not throw" $false $threw
Assert-Equal "and it is listed for manual rectification" 1 (@($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Reason -match 'Active Directory settings not' }).Count)

Write-Host "`n=== DRY RUN changes no host profile ===" -ForegroundColor Cyan
$script:Profiles = @(New-TestHostProfile)
$script:Updates.Clear()
$Global:RunMode = 'DRYRUN'
Set-ClusterHostProfileActiveDirectory -Cluster $cluster -Enable $false 6>$null
Assert-Equal "no update was written" 0 $script:Updates.Count
$Global:RunMode = 'LIVE'

Write-Host "`n=== The run puts it back even when the cluster does not finish ===" -ForegroundColor Cyan
$workflowText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the re-tick is in a finally" $true ($workflowText -match '(?s)finally \{[^}]*Set-ClusterHostProfileActiveDirectory -Cluster \$Cluster -Enable \$true')
Assert-Equal "and the untick runs before the rolling upgrade" $true (
    $workflowText.IndexOf('Set-ClusterHostProfileActiveDirectory -Cluster $Cluster -Enable $false') -lt
    $workflowText.IndexOf('Invoke-RollingClusterUpgrade -Cluster $Cluster'))

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
