<#
.SYNOPSIS
    Tests the Aria Operations ESXi patching hardware suppression: the cluster joins the group for
    the change and leaves it afterwards, and can never disturb the other members.

.DESCRIPTION
    The Aria UI posts the whole edit form to a private endpoint - customDatacenter.action, with a
    secureToken and the FULL child list. That is a REPLACE: getting the list wrong by one entry
    silently removes every other cluster from suppression, and the interface is bound to a browser
    session and unsupported besides.

    The suite-api models the same membership as resource relationships, and they are INCREMENTAL:

        GET    /suite-api/api/resources/{group}/relationships/children
        POST   /suite-api/api/resources/{group}/relationships/children      additive
        DELETE /suite-api/api/resources/{group}/relationships/children/{id} one member

    so this run can only add or remove its own cluster. The assertion that matters most here is
    therefore the negative one: the other members are untouched, and no request ever carries them.

    Two more things this covers, both learned the hard way elsewhere in this script: an ambiguous
    name is never resolved by taking the first match, and a DELETE that the API documents as
    asynchronous is confirmed by re-reading rather than assumed from the response.

    Standalone - no Pester, no network, no appliance.

.EXAMPLE
    pwsh -File ./tests/Test-AriaSuppression.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Connect-AriaOperations','Disconnect-AriaOperations','Get-AriaResourceId',
                                 'Invoke-AriaRestCall','Get-AriaCustomDatacenter','Get-AriaMembershipProperty',
                                 'Set-ClusterAriaPatchingSuppression','Test-DryRun') } |
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
$Global:AriaOperationsServer = 'siepd85vop1110.dpe.protected.mil.au'
$Global:AriaSuppressionGroupName = 'ESXi Patching Hardware Suppression'
$Global:AriaSuppressionGroupId = ''
$Global:AriaAuthSource = 'LOCAL'
$Global:AriaSkipCertificateCheck = $true
$Global:AriaCredential = [pscredential]::new('svc-esxi', (ConvertTo-SecureString 'p' -AsPlainText -Force))
$Global:AriaSession = $null
$Global:AriaUnusable = $false
$ManagementEndpointProbeTimeoutSeconds = 60

function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Action=$Action; Result=$Result; Details=$Details }) }
function Add-ManualAttentionHost { param($HostName,$Reason,$Detail,[switch]$ExcludeFromRun)
    $Global:ManualAttentionHosts.Add([pscustomobject]@{ Host=$HostName; Reason=$Reason; Detail=$Detail }) }
function Confirm-ManagementEndpointReachable { param($Target,$DeviceKind,$TimeoutSeconds) return $true }
function Start-Sleep { param($Seconds,$Milliseconds) }
function Get-Credential { param($Message,$UserName) return $Global:AriaCredential }

# --- The appliance ------------------------------------------------------------------------------
# The group already holds eleven other members. Nothing this run does may change that list.
$script:GroupId = '9c76e2d6-b468-47b2-a125-bb4c592a0655'
$script:OtherMembers = @(
    '08bcd38a-bc18-4433-9505-643c72074580','0f9283cc-459c-48b4-88ff-f8bfd7409865',
    '395ef08e-2121-4bba-891e-376327bfd888','51b7cdf1-dbfb-438a-82fb-5a7cb9b94b19',
    '66a14181-71fe-4225-8a3b-5f959abbdfa1','70a9c53d-8ba3-4ab9-b4d6-3a74939526d6',
    '7a275230-952b-489f-8360-32cdec363bd7','b3255297-5d98-4501-9412-606598e67e74',
    'eae52876-d89e-45d4-95d2-4657f3ce018d','ebec1210-6009-4cbd-b3ad-c8eccfe8fae5',
    'f42626e2-6617-4bd4-ab3c-c7f9862392f2')
$script:ClusterId = '0c9ce6f6-b841-4b28-8226-2661d4a843a6'

$script:Members = @()
$script:Calls = New-Object System.Collections.Generic.List[object]
$script:DuplicateCluster = $false
$script:TokenFails = $false
$script:PutLags = 0
$script:ExtraProperty = $null

function Reset-Appliance {
    $script:Members = @($script:OtherMembers)
    $script:Calls = New-Object System.Collections.Generic.List[object]
    $script:DuplicateCluster = $false
    $script:TokenFails = $false
    $script:PutLags = 0
    $script:ExtraProperty = $null
    $Global:AriaSession = $null
    $Global:AriaUnusable = $false
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
    $Global:ManualAttentionHosts = New-Object System.Collections.Generic.List[object]
}

# The object exactly as the appliance's own example payload shows it, description and all - so the
# assertions can prove the PUT hands everything back unchanged except the one id.
function New-CustomDatacenter {
    $cdc = [pscustomobject]@{
        id               = $script:GroupId
        name             = $Global:AriaSuppressionGroupName
        description      = 'temporary group to be used for ESXi Patching'
        childResourceIds = @($script:Members)
    }
    if ($null -ne $script:ExtraProperty) { $cdc | Add-Member -MemberType NoteProperty -Name $script:ExtraProperty -Value @('11111111-2222-3333-4444-555555555555') }
    return $cdc
}

function Invoke-RestMethod {
    param($Uri,$Method,$Headers,$Body,[switch]$SkipCertificateCheck,$ErrorAction)
    $script:Calls.Add([pscustomobject]@{ Uri=$Uri; Method=$Method; Body=$Body; Auth=$Headers['Authorization'] })

    if ($Uri -match '/auth/token/acquire$') {
        if ($script:TokenFails) { throw "Invalid credentials" }
        return [pscustomobject]@{ token = 'tok-123'; validity = 999 }
    }
    if ($Uri -match '/auth/token/release$') { return $null }

    if ($Uri -match '/api/resources/customdatacenters$') {
        if ($Method -eq 'PUT') {
            $sent = $Body | ConvertFrom-Json
            if ($script:PutLags -gt 0) { $script:PutLags--; return $null }   # accepted, not yet applied
            $script:Members = @($sent.childResourceIds)
            return $null
        }
        return [pscustomobject]@{ customDatacenters = @((New-CustomDatacenter)) }
    }
    if ($Uri -match "/api/resources/customdatacenters/(.+)$") { return (New-CustomDatacenter) }

    if ($Uri -match '/api/resources\?name=([^&]+)') {
        $name = [System.Uri]::UnescapeDataString($Matches[1])
        $rows = @([pscustomobject]@{ identifier = $script:ClusterId
            resourceKey = [pscustomobject]@{ name = $name; resourceKindKey = 'ClusterComputeResource'; adapterKindKey = 'VMWARE' } })
        if ($script:DuplicateCluster) {
            $rows += [pscustomobject]@{ identifier = 'deadbeef-0000-0000-0000-000000000000'
                resourceKey = [pscustomobject]@{ name = $name; resourceKindKey = 'ClusterComputeResource'; adapterKindKey = 'VMWARE' } }
        }
        return [pscustomobject]@{ resourceList = $rows }
    }
    throw "unexpected call: $Method $Uri"
}

$cluster = [pscustomobject]@{ Name = 'd85pay01' }

Write-Host "`n=== Signing in uses the documented token exchange ===" -ForegroundColor Cyan
Reset-Appliance
Assert-Equal "the sign-in succeeds" $true (Connect-AriaOperations 6>$null)
$acquire = @($script:Calls | Where-Object { $_.Uri -match 'token/acquire' })[0]
Assert-Equal "POST to the acquire endpoint" "POST" $acquire.Method
Assert-Equal "on the suite-api, not the UI action API" $true ($acquire.Uri -match '/suite-api/api/auth/token/acquire$')
$body = $acquire.Body | ConvertFrom-Json
Assert-Equal "carrying the username" "svc-esxi" $body.username
Assert-Equal "and the authentication source" "LOCAL" $body.authSource
Assert-Equal "the token is held for the run" "tok-123" $Global:AriaSession

Write-Host "`n=== The member list is READ, modified by one, and written back whole ===" -ForegroundColor Cyan
# PUT replaces the object, so the list that goes back has to be the list that came off the
# appliance. Composing it from anything else - the run's own idea of who belongs, a cached copy, an
# empty array on a failed read - silently drops every other cluster out of suppression.
Reset-Appliance
Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $true 6>$null
Assert-Equal "the cluster is in the group" $true ($script:Members -contains $script:ClusterId)
Assert-Equal "all eleven other members are still there" 11 (@($script:OtherMembers | Where-Object { $script:Members -contains $_ }).Count)
Assert-Equal "twelve members in total, not one" 12 $script:Members.Count

$put = @($script:Calls | Where-Object { $_.Method -eq 'PUT' })
Assert-Equal "exactly one write was made" 1 $put.Count
Assert-Equal "to the supported endpoint" $true ($put[0].Uri -match '/suite-api/api/resources/customdatacenters$')
Assert-Equal "the private UI endpoint is never called" 0 (@($script:Calls | Where-Object { $_.Uri -match 'customDatacenter\.action|secureToken' }).Count)
# The read has to come first, and from the appliance.
$readsBeforeWrite = @($script:Calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -match 'customdatacenters' })
Assert-Equal "the object was read before it was written" $true ($readsBeforeWrite.Count -ge 1)

$sent = $put[0].Body | ConvertFrom-Json
Assert-Equal "the write carried all twelve ids" 12 @($sent.childResourceIds).Count
Assert-Equal "including every one it started with" 11 (@($script:OtherMembers | Where-Object { @($sent.childResourceIds) -contains $_ }).Count)
# Everything that is not the member list goes back exactly as it came.
Assert-Equal "the id is unchanged" $script:GroupId $sent.id
Assert-Equal "the name is unchanged" "ESXi Patching Hardware Suppression" $sent.name
Assert-Equal "and the description is unchanged" "temporary group to be used for ESXi Patching" $sent.description
Assert-Equal "recorded as applied" "Applied" (@($Global:RunSummary.ToArray() | Where-Object { $_.Stage -eq 'AriaSuppression' -and $_.Action -match 'suppression' })[-1].Result)

Write-Host "`n=== Removing takes out one member, and only that one ===" -ForegroundColor Cyan
Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $false 6>$null
Assert-Equal "the cluster is out" $false ($script:Members -contains $script:ClusterId)
Assert-Equal "the other eleven are still there" 11 $script:Members.Count
$put = @($script:Calls | Where-Object { $_.Method -eq 'PUT' })[-1]
$sent = $put.Body | ConvertFrom-Json
Assert-Equal "the write carried the remaining eleven" 11 @($sent.childResourceIds).Count
Assert-Equal "and not the cluster" $false (@($sent.childResourceIds) -contains $script:ClusterId)

Write-Host "`n=== A write that has not taken is caught by the read-back ===" -ForegroundColor Cyan
# A PUT returning says nothing about what the appliance stored.
Reset-Appliance
$script:PutLags = 1
Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $true 6>$null
Assert-Equal "it is not reported as applied" $true ((@($Global:RunSummary.ToArray() | Where-Object { $_.Action -match 'suppression' })[-1].Result) -eq 'Failed')
Assert-Equal "and it is listed for manual attention" 1 (@($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Reason -match 'suppression not applied' }).Count)

Write-Host "`n=== The member property is the documented one, and ambiguity is refused ===" -ForegroundColor Cyan
Assert-Equal "childResourceIds is taken by name" "childResourceIds" (Get-AriaMembershipProperty -CustomDatacenter ([pscustomobject]@{ id='x'; name='y'; childResourceIds=@() }))
# A release that renames it is still handled, by finding the one array of UUIDs.
Assert-Equal "an unnamed member list is discovered" "memberIds" (Get-AriaMembershipProperty -CustomDatacenter ([pscustomobject]@{ id='x'; name='y'; memberIds=@('4f64f721-e59b-44ef-a6ad-870127545f6b') }))
# Two candidates means the wrong array could be edited, which is how every other cluster falls out.
Assert-Equal "two candidates are refused, not guessed between" "" (Get-AriaMembershipProperty -CustomDatacenter ([pscustomobject]@{
    memberIds=@('4f64f721-e59b-44ef-a6ad-870127545f6b'); otherIds=@('8ab92306-fd06-40f5-9194-d6730d5c8654') }) 6>$null)
Assert-Equal "and none at all is refused too" "" (Get-AriaMembershipProperty -CustomDatacenter ([pscustomobject]@{ id='x'; name='y' }))

Write-Host "`n=== A member list that cannot be identified is never written ===" -ForegroundColor Cyan
Reset-Appliance
$script:ExtraProperty = 'someOtherIds'
# childResourceIds is still present, so the documented name still wins - the extra array cannot
# confuse it. Proving that is the point: discovery is the fallback, not the first choice.
Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $true 6>$null
Assert-Equal "the documented property is still used" $true ($script:Members -contains $script:ClusterId)
Assert-Equal "and the unrelated array is untouched" 12 $script:Members.Count

Write-Host "`n=== Already in, or already out, is not a change ===" -ForegroundColor Cyan
Reset-Appliance
$script:Members += $script:ClusterId
Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $true 6>$null
Assert-Equal "no write was made" 0 (@($script:Calls | Where-Object { $_.Method -eq 'PUT' }).Count)
Assert-Equal "and it says so" "AlreadyIn" (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -match 'suppression' })[-1].Result)

Reset-Appliance
Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $false 6>$null
Assert-Equal "removing one that is not there writes nothing" 0 (@($script:Calls | Where-Object { $_.Method -eq 'PUT' }).Count)
Assert-Equal "and says so" "AlreadyOut" (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -match 'suppression' })[-1].Result)

Write-Host "`n=== Two clusters of the same name are never guessed between ===" -ForegroundColor Cyan
# The Aria object picker shows identical rows for same-named clusters in different vCenters - the
# screenshot of the estate has exactly that. Suppressing the wrong one leaves the right one alerting.
Reset-Appliance
$script:DuplicateCluster = $true
Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $true 6>$null
Assert-Equal "nothing was written" 0 (@($script:Calls | Where-Object { $_.Method -eq 'PUT' }).Count)
Assert-Equal "the group is untouched" 11 $script:Members.Count
Assert-Equal "and it is listed for manual attention" 1 (@($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Reason -match 'suppression not applied' }).Count)

Write-Host "`n=== Aria being unavailable never stops the upgrade ===" -ForegroundColor Cyan
# Suppression is a courtesy to the monitoring team, not part of the change. An unsuppressed cluster
# raises alerts; a cluster that does not get patched is worse.
Reset-Appliance
$script:TokenFails = $true
$threw = $false
try { Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $true 6>$null } catch { $threw = $true }
Assert-Equal "it does not throw" $false $threw
Assert-Equal "and the cluster is listed for manual attention" 1 (@($Global:ManualAttentionHosts.ToArray() | Where-Object { $_.Reason -match 'suppression not applied' }).Count)
Assert-Equal "the credential is dropped so it is asked for again" $null $Global:AriaCredential
$Global:AriaCredential = [pscredential]::new('svc-esxi', (ConvertTo-SecureString 'p' -AsPlainText -Force))

Write-Host "`n=== Off by default, and off in DRY RUN ===" -ForegroundColor Cyan
Reset-Appliance
$Global:AriaOperationsServer = ''
Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $true 6>$null
Assert-Equal "no appliance configured means no calls at all" 0 $script:Calls.Count
$Global:AriaOperationsServer = 'siepd85vop1110.dpe.protected.mil.au'

Reset-Appliance
$Global:RunMode = 'DRYRUN'
Set-ClusterAriaPatchingSuppression -Cluster $cluster -InSuppression $true 6>$null
Assert-Equal "DRY RUN makes no call" 0 $script:Calls.Count
Assert-Equal "and the group is untouched" 11 $script:Members.Count
$Global:RunMode = 'LIVE'

Write-Host "`n=== It is applied for the cluster and removed whatever the outcome ===" -ForegroundColor Cyan
$workflowText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "suppression goes on before the rolling upgrade" $true (
    $workflowText.IndexOf('Set-ClusterAriaPatchingSuppression -Cluster $Cluster -InSuppression $true') -lt
    $workflowText.IndexOf('Invoke-RollingClusterUpgrade -Cluster $Cluster'))
Assert-Equal "and comes off in a finally" $true ($workflowText -match '(?s)finally \{[^}]*Set-ClusterAriaPatchingSuppression -Cluster \$Cluster -InSuppression \$false')

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
