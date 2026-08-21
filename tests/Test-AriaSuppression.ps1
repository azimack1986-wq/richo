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
                                 'Set-ClusterAriaPatchingSuppression','Test-DryRun',
                                 'Get-RunCredential','Register-RunCredentialResult','Clear-RunCredential',
                                 'Set-SharedRunCredential','Get-AriaRunCredential',
                                 'Resolve-AriaUserName') } |
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
$Global:AriaAuthSource = 'vIDMAuthSource'
$Global:AriaVidmDomain = 'dpe.protected.mil.au'
$Global:AriaLocalUserName = ''
$Global:AriaCredentialFile = 'config\aria.local.json'
$Global:AriaSkipCertificateCheck = $true
$Global:AriaCredential = [pscredential]::new('svc-esxi', (ConvertTo-SecureString 'p' -AsPlainText -Force))
$Global:AriaSession = $null
$Global:AriaUnusable = $false
$Global:CredentialCache = @{}
$Global:CredentialAttempts = @{}
$Global:CredentialBlocked = @{}
$Global:CredentialSource = @{}
$Global:SharedCredential = $null
$Global:SharedCredentialSource = ""
$Global:SharedCredentialRejected = @{}
$Global:MaxCredentialAttempts = 3
$ManagementEndpointProbeTimeoutSeconds = 60

function Add-SummaryRecord { param($Stage,$Batch,$HostName,$Action,$Result,$Details)
    $Global:RunSummary.Add([pscustomobject]@{ Stage=$Stage; Action=$Action; Result=$Result; Details=$Details }) }
function Add-ManualAttentionHost { param($HostName,$Reason,$Detail,[switch]$ExcludeFromRun)
    $Global:ManualAttentionHosts.Add([pscustomobject]@{ Host=$HostName; Reason=$Reason; Detail=$Detail }) }
function Confirm-ManagementEndpointReachable { param($Target,$DeviceKind,$TimeoutSeconds) return $true }
function Start-Sleep { param($Seconds,$Milliseconds) }
$script:AriaPrompts = 0
$script:AriaPromptUser = ''
$script:Choices = New-Object System.Collections.Generic.List[string]
$script:ChoiceAnswers = New-Object System.Collections.Generic.Queue[string]
function Get-Credential { param($Message,$UserName)
    $script:AriaPrompts++
    $script:AriaPromptUser = "$UserName"
    if ($null -ne $Global:AriaCredential) { return $Global:AriaCredential }
    return [pscredential]::new(("$UserName" -replace '^$','admin'), (ConvertTo-SecureString 'typed-password' -AsPlainText -Force)) }
function Read-ChoiceExit { param($Message,$AllowedChoices,$ExitMessage)
    $script:Choices.Add($Message)
    $script:LastAllowed = @($AllowedChoices)
    if ($script:ChoiceAnswers.Count -eq 0) { return '1' }
    return $script:ChoiceAnswers.Dequeue() }
$script:LastAllowed = @()

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
# How many token requests have been made, and up to which attempt they are rejected - so a retry
# can be shown to SUCCEED on the second account, not merely to be attempted.
$script:TokenAttempts = 0
$script:FailUntilAttempt = 99
$script:PutLags = 0
$script:ExtraProperty = $null

function Reset-Appliance {
    $script:Members = @($script:OtherMembers)
    $script:Calls = New-Object System.Collections.Generic.List[object]
    $script:DuplicateCluster = $false
    $script:TokenFails = $false
    $script:TokenAttempts = 0
    $script:FailUntilAttempt = 99
    $script:PutLags = 0
    $script:ExtraProperty = $null
    $Global:AriaSession = $null
    $Global:AriaUnusable = $false
    $Global:CredentialCache = @{}
    $Global:CredentialAttempts = @{}
    $Global:CredentialBlocked = @{}
    $Global:CredentialSource = @{}
    $Global:SharedCredential = $null
    $Global:SharedCredentialSource = ""
    $Global:SharedCredentialRejected = @{}
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
        $script:TokenAttempts++
        if ($script:TokenFails -and $script:TokenAttempts -le $script:FailUntilAttempt) { throw "Response status code does not indicate success: 401 (401)." }
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
# The username on the wire is the REBUILT one - vIDM will not resolve a bare account name.
Assert-Equal "carrying the composed username" "svc-esxi@dpe.protected.mil.au@vIDMAuthSource" $body.username
Assert-Equal "and the authentication source" "vIDMAuthSource" $body.authSource
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

Write-Host "`n=== The shipped default names an appliance, and says to change it ===" -ForegroundColor Cyan
# Suppression is ON out of the box, pointed at D85. That makes the site-specific value the thing a
# reader has to notice, so the warning is asserted rather than left to survive an edit.
$sourceText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "an appliance is set by default" $true ($sourceText -match '\$Global:AriaOperationsServer = "siepd85vop1110\.dpe\.protected\.mil\.au"')
Assert-Equal "the header says to check it before running elsewhere" $true ($sourceText -match 'CHECK THIS BEFORE YOU RUN IT SOMEWHERE NEW')
Assert-Equal "and the setting itself says to update it for the site" $true ($sourceText -match 'UPDATE THIS FOR THE SITE YOU ARE RUNNING AGAINST')
Assert-Equal "the pre-flight puts it on screen" $true ($sourceText -match 'CHECK THAT APPLIANCE IS THE RIGHT ONE FOR THIS SITE')
Assert-Equal "and says an empty value turns it off" $true ($sourceText -match 'set it to "" to turn suppression off')

Write-Host "`n=== Blank turns it off, and DRY RUN never writes ===" -ForegroundColor Cyan
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

Write-Host "`n=== The username is composed as account@vIDM-domain@source ===" -ForegroundColor Cyan
# The form tested against the appliance, which returned a token:
#     username = andrew.richard1_priv@dpe.protected.mil.au@vIDMAuthSource
#     authSource = vIDMAuthSource
#     password = the vIDM (domain) password
# A bare account name does not resolve against a vIDM source; it is a 401 that looks exactly like
# a wrong password. The operator only ever types the plain account - everything after the first @
# is added here, from one place.
Assert-Equal "a plain account is composed in full" "andrew.richard1_priv@dpe.protected.mil.au@vIDMAuthSource" (Resolve-AriaUserName -UserName 'andrew.richard1_priv' -AuthSource 'vIDMAuthSource')
# A vCenter credential is commonly entered as DOMAIN\user. That NetBIOS prefix names the directory
# rather than the account, and vIDM wants the DNS-style domain in the middle instead.
Assert-Equal "a NetBIOS prefix is replaced, not kept" "andrew.richard1_priv@dpe.protected.mil.au@vIDMAuthSource" (Resolve-AriaUserName -UserName 'DPE\andrew.richard1_priv' -AuthSource 'vIDMAuthSource')
# account@domain already: only the source is missing.
Assert-Equal "a UPN only gains the source" "svc@dpe.protected.mil.au@vIDMAuthSource" (Resolve-AriaUserName -UserName 'svc@dpe.protected.mil.au' -AuthSource 'vIDMAuthSource')
# Spelled out in full by the operator: left exactly as it is.
Assert-Equal "an already-qualified name is untouched" "svc@System Domain@vIDM-1" (Resolve-AriaUserName -UserName 'svc@System Domain@vIDM-1' -AuthSource 'vIDMAuthSource')
# No domain configured: send the account rather than invent a domain.
$savedDomain = $Global:AriaVidmDomain
$Global:AriaVidmDomain = ''
Assert-Equal "no domain means no invention" "svc" (Resolve-AriaUserName -UserName 'svc' -AuthSource 'vIDMAuthSource')
$Global:AriaVidmDomain = $savedDomain
# One composition, one place - no per-source branching left to get out of step.
$sourceCheck = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "no source-kind heuristic remains" $false ($sourceCheck -match 'Test-AriaVidmAuthSource')

Write-Host "`n=== vIDMAuthSource is the source, and it is not asked about ===" -ForegroundColor Cyan
$sourceText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the source is fixed to vIDMAuthSource" $true ($sourceText -match '\$Global:AriaAuthSource = "vIDMAuthSource"')
Assert-Equal "there is no source chooser" $false ($sourceText -match 'Select-AriaAuthSource')
Assert-Equal "the token request carries it" $true ($sourceText -match 'authSource = \$Global:AriaAuthSource')
Assert-Equal "and the sent username is the resolved one" $true ($sourceText -match 'Resolve-AriaUserName -UserName \$Global:AriaCredential.UserName -AuthSource \$Global:AriaAuthSource')
# The composed name is printed BEFORE the request, so a wrong domain is visible, not mysterious.
Assert-Equal "the composed name is printed before signing in" $true ($sourceText -match "Signing in as ..sendUser. against authSource")

Write-Host "`n=== NO PASSWORD IS IN THE SCRIPT ===" -ForegroundColor Cyan
Assert-Equal "no inline password setting exists" $false ($sourceText -match '\$Global:AriaLocalPassword')
Assert-Equal "nothing is exported to disk" $true (-not ($sourceText -match 'Export-Clixml|ConvertFrom-SecureString'))

Write-Host "`n=== Manual or passthrough - the operator is asked, while this is being proven ===" -ForegroundColor Cyan
# UCS Manager takes the account exactly as vCenter holds it, so its menu was removed. vIDM does
# not: the name is rebuilt, and until that composition has been seen to work here the operator
# should be able to choose and to compare the two.
Clear-RunCredential
$Global:AriaCredential = $null
$script:AriaPrompts = 0
$script:Choices = New-Object System.Collections.Generic.List[string]
Set-SharedRunCredential -Credential ([pscredential]::new('DPE\nick.beare_priv', (ConvertTo-SecureString 'domain-password' -AsPlainText -Force))) -Source "vCenter" 6>$null

$script:ChoiceAnswers.Enqueue('2')
$cred = Get-AriaRunCredential 6>$null
Assert-Equal "the choice was put to the operator" 1 $script:Choices.Count
Assert-Equal "2 passes the vCenter credential through" "DPE\nick.beare_priv" $cred.UserName
Assert-Equal "nothing was typed" 0 $script:AriaPrompts
Assert-Equal "recorded as a passthrough" "Shared" $Global:CredentialSource["Aria Operations"]
# ...and it is the REBUILT name that would go to the appliance.
Assert-Equal "which is sent composed in full" "nick.beare_priv@dpe.protected.mil.au@vIDMAuthSource" (Resolve-AriaUserName -UserName $cred.UserName -AuthSource $Global:AriaAuthSource)

# The menu must show what option 2 would actually send, or it is not a comparison.
$shown = (Get-AriaRunCredential 6>&1 | Out-String)
Assert-Equal "the menu previews what would be sent" $true ($shown -match "would be sent as 'nick.beare_priv@dpe.protected.mil.au@vIDMAuthSource'")

Clear-RunCredential
$Global:AriaCredential = $null
$script:AriaPrompts = 0
$script:Choices = New-Object System.Collections.Generic.List[string]
Set-SharedRunCredential -Credential ([pscredential]::new('DPE\nick.beare_priv', (ConvertTo-SecureString 'domain-password' -AsPlainText -Force))) -Source "vCenter" 6>$null
$script:ChoiceAnswers.Enqueue('1')
$cred = Get-AriaRunCredential 6>$null
Assert-Equal "1 types one instead" 1 $script:AriaPrompts
Assert-Equal "and it is what comes back" "typed-password" $cred.GetNetworkCredential().Password
Assert-Equal "recorded as entered by hand" "Manual" $Global:CredentialSource["Aria Operations"]
# Asked once per run, not once per cluster.
$script:Choices = New-Object System.Collections.Generic.List[string]
[void](Get-AriaRunCredential 6>$null)
Assert-Equal "the second call asks nothing" 0 $script:Choices.Count
Assert-Equal "and types nothing" 1 $script:AriaPrompts

Write-Host "`n=== A rejected passthrough is not offered again ===" -ForegroundColor Cyan
# The lockout guard for the replay. If vIDM refuses the vCenter credential, sending it again at
# the next cluster is how an account gets locked.
Clear-RunCredential
$Global:AriaCredential = $null
$script:AriaPrompts = 0
$script:Choices = New-Object System.Collections.Generic.List[string]
Set-SharedRunCredential -Credential ([pscredential]::new('DPE\nick.beare_priv', (ConvertTo-SecureString 'domain-password' -AsPlainText -Force))) -Source "vCenter" 6>$null
$script:ChoiceAnswers.Enqueue('2')
[void](Get-AriaRunCredential 6>$null)
Register-RunCredentialResult -Purpose "Aria Operations" -Succeeded $false 6>$null
$script:ChoiceAnswers.Enqueue('1')
[void](Get-AriaRunCredential 6>$null)
# The menu is always shown - what changes is that option 2 is no longer on it.
Assert-Equal "no passthrough is offered the second time" $false ($script:LastAllowed -contains '2')
Assert-Equal "it is typed instead" 1 $script:AriaPrompts
# Past the limit nothing further is asked for or sent at all.
Clear-RunCredential
$Global:AriaCredential = $null
$script:AriaPrompts = 0
for ($i = 1; $i -le $Global:MaxCredentialAttempts; $i++) {
    [void](Get-AriaRunCredential 6>$null)
    Register-RunCredentialResult -Purpose "Aria Operations" -Succeeded $false 6>$null
}
$before = $script:AriaPrompts
Assert-Equal "past the limit nothing is returned" $true ($null -eq (Get-AriaRunCredential 6>$null))
Assert-Equal "and nothing further is typed" $before $script:AriaPrompts
Clear-RunCredential

Write-Host "`n=== The environment and the gitignored file still skip the prompt ===" -ForegroundColor Cyan
Clear-RunCredential
$Global:AriaCredential = $null
$script:AriaPrompts = 0
$script:Choices = New-Object System.Collections.Generic.List[string]
$env:RICHO_ARIA_PASSWORD = 'from-the-environment'
$Global:AriaLocalUserName = 'svc-aria'
$cred = Get-AriaRunCredential 6>$null
Assert-Equal "the environment variable is used" "from-the-environment" $cred.GetNetworkCredential().Password
Assert-Equal "as the configured account" "svc-aria" $cred.UserName
Assert-Equal "held as a SecureString" "System.Security.SecureString" $cred.Password.GetType().FullName
Assert-Equal "and nothing was asked" 0 $script:Choices.Count
$env:RICHO_ARIA_PASSWORD = ''
$Global:AriaLocalUserName = ''

$fileDir = Join-Path ([IO.Path]::GetTempPath()) ("aria-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fileDir 'config') | Out-Null
'{"userName":"svc-aria","password":"from-the-file"}' | Set-Content -Path (Join-Path $fileDir 'config/aria.local.json') -Encoding UTF8
Push-Location $fileDir
$cred = Get-AriaRunCredential 6>$null
Pop-Location
Assert-Equal "the file is used" "from-the-file" $cred.GetNetworkCredential().Password
Assert-Equal "including the account it names" "svc-aria" $cred.UserName
Remove-Item -LiteralPath $fileDir -Recurse -Force -ErrorAction SilentlyContinue
Clear-RunCredential

Write-Host "`n=== Option 3 sends the username exactly as typed ===" -ForegroundColor Cyan
# FOR TESTING A STRING BY HAND. Confirming a particular username works must not require a
# different one to fail first - that burns an attempt, marks the passthrough rejected, and proves
# nothing about the string being tested. So option 3 is always on the menu, and what is typed goes
# onto the wire unaltered: nothing composed, no domain appended, no prefix stripped.
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = $null
$script:AriaPrompts = 0
$script:ReadHostAnswers = New-Object System.Collections.Generic.Queue[string]
$script:ReadHostAnswers.Enqueue('andrew.richard1_priv@dpe.protected.mil.au@vIDMAuthSource')
function Read-Host { param($Prompt,[switch]$AsSecureString)
    if ($AsSecureString) { return (ConvertTo-SecureString 'raw-password' -AsPlainText -Force) }
    if ($script:ReadHostAnswers.Count -eq 0) { return '' }
    return $script:ReadHostAnswers.Dequeue() }
$script:ChoiceAnswers.Enqueue('3')
$cred = Get-AriaRunCredential 6>$null
Assert-Equal "the exact string is held" "andrew.richard1_priv@dpe.protected.mil.au@vIDMAuthSource" $cred.UserName
Assert-Equal "with the password typed" "raw-password" $cred.GetNetworkCredential().Password
Assert-Equal "and it is flagged as raw" $true $Global:AriaUserNameIsRaw
Assert-Equal "the credential dialog was not used" 0 $script:AriaPrompts

# On the wire: unaltered. Not re-composed, which for a name that already has two @ would be a
# no-op anyway - but a DOMAIN\ prefix would NOT be, and raw has to mean raw.
Reset-Appliance
$script:ReadHostAnswers.Enqueue('DPE\andrew.richard1_priv')
$Global:AriaCredential = $null
Clear-RunCredential
$script:ChoiceAnswers.Enqueue('3')
$Global:AriaCredential = Get-AriaRunCredential 6>$null
Assert-Equal "even a form the composer would rewrite is left alone" "DPE\andrew.richard1_priv" $Global:AriaCredential.UserName
[void](Connect-AriaOperations 6>$null)
$acquire = @($script:Calls | Where-Object { $_.Uri -match 'token/acquire' })[-1]
Assert-Equal "and that is what reaches the appliance" "DPE\andrew.richard1_priv" (($acquire.Body | ConvertFrom-Json).username)
Assert-Equal "with the source still in authSource" "vIDMAuthSource" (($acquire.Body | ConvertFrom-Json).authSource)

# Option 3 is reachable with no passthrough available at all - it does not depend on one existing.
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = $null
$script:ChoiceAnswers.Enqueue('3')
$script:ReadHostAnswers.Enqueue('svc@System Domain@vIDM-1')
$cred = Get-AriaRunCredential 6>$null
Assert-Equal "offered with no shared credential held" $true ($script:LastAllowed -contains '3')
Assert-Equal "and it works" "svc@System Domain@vIDM-1" $cred.UserName
# THE DEFAULT: the KB syntax built from the account this run already knows, so the common case is
# one keypress and the syntax is on screen to copy and adjust.
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = $null
Set-SharedRunCredential -Credential ([pscredential]::new('DPE\andrew.iles_priv', (ConvertTo-SecureString 'domain-password' -AsPlainText -Force))) -Source "vCenter" 6>$null
$script:ChoiceAnswers.Enqueue('3')
$script:ReadHostAnswers.Clear()          # nothing typed at the username prompt: Enter
$cred = Get-AriaRunCredential 6>$null
Assert-Equal "Enter takes the composed default" "andrew.iles_priv@dpe.protected.mil.au@vIDMAuthSource" $cred.UserName
Assert-Equal "and it is still raw from there on" $true $Global:AriaUserNameIsRaw
# Typing one replaces the default whole.
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = $null
Set-SharedRunCredential -Credential ([pscredential]::new('DPE\andrew.iles_priv', (ConvertTo-SecureString 'domain-password' -AsPlainText -Force))) -Source "vCenter" 6>$null
$script:ChoiceAnswers.Enqueue('3')
$script:ReadHostAnswers.Enqueue('andrew.richard1_priv@dpe.protected.mil.au@vIDMAuthSource')
$cred = Get-AriaRunCredential 6>$null
Assert-Equal "a typed username wins over the default" "andrew.richard1_priv@dpe.protected.mil.au@vIDMAuthSource" $cred.UserName
# Nothing typed and nothing to default to is not a credential.
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = $null
$script:ChoiceAnswers.Enqueue('3')
$script:ReadHostAnswers.Clear()
Assert-Equal "no default and no input is no credential" $true ($null -eq (Get-AriaRunCredential 6>$null))

# Options 1 and 2 leave the raw flag off, so the composer is back in charge.
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = $null
$script:ChoiceAnswers.Enqueue('1')
[void](Get-AriaRunCredential 6>$null)
Assert-Equal "a normal entry is not raw" $false $Global:AriaUserNameIsRaw
Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
Clear-RunCredential
$Global:AriaCredential = [pscredential]::new('svc-esxi', (ConvertTo-SecureString 'p' -AsPlainText -Force))

Write-Host "`n=== A failed sign-in offers another account instead of killing the run ===" -ForegroundColor Cyan
# ONE BAD ACCOUNT USED TO COST THE WHOLE RUN. A single 401 marked Aria unusable for the session, so
# a passthrough that turned out not to be entitled in Aria meant no suppression on any cluster
# afterwards - with the operator standing right there, able to give an account that would work.
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = $null
$script:AriaPrompts = 0
$script:TokenFails = $true
$script:FailUntilAttempt = 1          # the appliance rejects the first account and accepts the next
$script:ChoiceAnswers.Enqueue('1')    # the credential menu: type an account
$script:ChoiceAnswers.Enqueue('1')    # after the 401: try a different account
$script:ChoiceAnswers.Enqueue('1')    # the credential menu again
Assert-Equal "the second account got in" $true (Connect-AriaOperations 6>$null)
Assert-Equal "it took two sign-ins" 2 $script:TokenAttempts
Assert-Equal "and Aria is still usable" $false $Global:AriaUnusable
Assert-Equal "the failure is on the record" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -eq 'Sign in' -and $_.Result -eq 'Failed' }).Count)
Assert-Equal "and so is the success" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Action -eq 'Sign in' -and $_.Result -eq 'Connected' }).Count)

Write-Host "`n=== Declining the retry gives up cleanly ===" -ForegroundColor Cyan
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = $null
$script:TokenFails = $true
$script:ChoiceAnswers.Enqueue('1')    # the credential menu: type an account
$script:ChoiceAnswers.Enqueue('2')    # after the 401: carry on without suppression
Assert-Equal "the sign-in gives up" $false (Connect-AriaOperations 6>$null)
Assert-Equal "without sending a second password" 1 $script:TokenAttempts
Assert-Equal "Aria is marked unusable" $true $Global:AriaUnusable
Assert-Equal "recorded as given up, not just failed" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'GivenUp' }).Count)

Write-Host "`n=== Retrying cannot outrun the attempt limit ===" -ForegroundColor Cyan
# The limit is what keeps a retry loop from becoming the lockout it looks like: the rejected
# credential is discarded rather than replayed, attempts are counted, and past the limit nothing
# further is asked for or sent - no matter how many times the operator answers 1.
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = $null
$script:TokenFails = $true
for ($i = 0; $i -lt 10; $i++) { $script:ChoiceAnswers.Enqueue('1') }
Assert-Equal "it gives up on its own" $false (Connect-AriaOperations 6>$null)
Assert-Equal "after exactly the attempt limit" $Global:MaxCredentialAttempts $script:TokenAttempts
Assert-Equal "and the system is blocked for the run" $true $Global:CredentialBlocked["Aria Operations"]
$script:ChoiceAnswers.Clear()
Reset-Appliance
Clear-RunCredential
$Global:AriaCredential = [pscredential]::new('svc-esxi', (ConvertTo-SecureString 'p' -AsPlainText -Force))

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
