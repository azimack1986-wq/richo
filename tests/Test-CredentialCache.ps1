<#
.SYNOPSIS
    Tests the run credential cache: reuse is offered, never assumed, and a wrong password can
    never be replayed enough times to lock an account.

.DESCRIPTION
    A run signs in to UCS Manager once per domain and to Aria Operations once per cluster, so
    without a cache the same password is typed over and over - and a password typed six times is a
    password mistyped once.

    The risk that comes with caching is the whole reason this file exists: a cached password that
    is WRONG would be replayed at every domain in turn, which is exactly how an account gets locked
    out. So three properties are asserted above all others:

      - a failed sign-in discards the cached credential immediately;
      - attempts are counted per system, and past the limit NOTHING further is sent;
      - the cache is emptied when the run ends, however it ends.

    Standalone - no Pester, no vendor modules, no infrastructure, and no real credential.

.EXAMPLE
    pwsh -File ./tests/Test-CredentialCache.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Get-RunCredential','Register-RunCredentialResult','Clear-RunCredential',
                                 'Set-SharedRunCredential') } |
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

$Global:MaxCredentialAttempts = 3
$script:Prompts = New-Object System.Collections.Generic.List[string]
$script:Answers = New-Object System.Collections.Generic.Queue[string]
$script:TypedCount = 0
$script:TypedUser = 'first.user'

function Read-ChoiceExit { param($Message,$AllowedChoices,$ExitMessage)
    $script:Prompts.Add($Message)
    if ($script:Answers.Count -eq 0) { throw "EXIT: $ExitMessage" }
    return $script:Answers.Dequeue() }
function Get-Credential { param($Message,$UserName)
    $script:TypedCount++
    return [pscredential]::new($script:TypedUser, (ConvertTo-SecureString 'typed-password' -AsPlainText -Force)) }

function Reset-Cache {
    Clear-RunCredential
    $script:Prompts = New-Object System.Collections.Generic.List[string]
    $script:Answers = New-Object System.Collections.Generic.Queue[string]
    $script:TypedCount = 0
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
}

Write-Host "`n=== The first credential is typed, and held ===" -ForegroundColor Cyan
Reset-Cache
$first = Get-RunCredential -Purpose "UCS Manager" -Message "Enter UCSM credential" 6>$null
Assert-Equal "it was typed" 1 $script:TypedCount
Assert-Equal "nothing was asked - there was nothing held to offer" 0 $script:Prompts.Count
Assert-Equal "and it is held for the run" "first.user" $Global:CredentialCache["UCS Manager"].UserName
# The password is a SecureString, not a string on the object.
Assert-Equal "the password is held as a SecureString" "System.Security.SecureString" $first.Password.GetType().FullName

Write-Host "`n=== Reuse is silent - no question, no keystroke ===" -ForegroundColor Cyan
# The 1-type-again / 2-passthrough menu that guarded this while it was being proven is gone. A
# question whose answer is always 2 is just a keystroke between the operator and the change.
$again = Get-RunCredential -Purpose "UCS Manager" -Message "Enter UCSM credential" 6>$null
Assert-Equal "nothing was asked" 0 $script:Prompts.Count
Assert-Equal "the held credential came straight through" "first.user" $again.UserName
Assert-Equal "and nothing was typed" 1 $script:TypedCount
# It is still SAID, so the operator knows which account is about to be sent where when it 401s.
$spoken = (Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>&1 | Out-String)
Assert-Equal "the account in use is named on screen" $true ($spoken -match "using 'first.user'")
Assert-Equal "and where it came from" $true ($spoken -match 'entered for UCS Manager earlier')

Write-Host "`n=== One system's credential is not the other's ===" -ForegroundColor Cyan
Reset-Cache
[void](Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null)
# No prompt here means nothing was held for Aria - the caches are separate.
[void](Get-RunCredential -Purpose "Aria Operations" -Message "m" 6>$null)
Assert-Equal "both were typed" 2 $script:TypedCount
Assert-Equal "and neither offered the other's" 0 $script:Prompts.Count

Write-Host "`n=== A failed sign-in discards the credential at once ===" -ForegroundColor Cyan
# This is the property that makes caching safe. A wrong password that stays cached is a wrong
# password about to be sent to the next domain, and the one after that.
Reset-Cache
[void](Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null)
Register-RunCredentialResult -Purpose "UCS Manager" -Succeeded $false 6>$null
Assert-Equal "nothing is held any more" $true ($null -eq $Global:CredentialCache["UCS Manager"])
# So the next call types rather than offering - there is nothing to offer.
[void](Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null)
Assert-Equal "the next one is typed" 2 $script:TypedCount
Assert-Equal "with nothing asked either way" 0 $script:Prompts.Count

Write-Host "`n=== Past the limit, NOTHING further is sent ===" -ForegroundColor Cyan
# The lockout guard. Three failures and the system is given up on for the run - no prompt, no
# credential, no sign-in.
Reset-Cache
for ($i = 1; $i -le $Global:MaxCredentialAttempts; $i++) {
    [void](Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null)
    Register-RunCredentialResult -Purpose "UCS Manager" -Succeeded $false 6>$null
}
Assert-Equal "the system is blocked" $true $Global:CredentialBlocked["UCS Manager"]
$typedBefore = $script:TypedCount
$blocked = Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null
Assert-Equal "no credential is returned" $true ($null -eq $blocked)
Assert-Equal "and none is asked for" $typedBefore $script:TypedCount
Assert-Equal "it is on the record" "Blocked" (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'Blocked' })[-1].Result)
Assert-Equal "saying why" $true ((@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'Blocked' })[-1].Details) -match 'locking the account')
# The other system is untouched by it.
Assert-Equal "the other system is not blocked" $false ([bool]$Global:CredentialBlocked["Aria Operations"])
[void](Get-RunCredential -Purpose "Aria Operations" -Message "m" 6>$null)
Assert-Equal "and can still be signed in to" $true ($null -ne $Global:CredentialCache["Aria Operations"])

Write-Host "`n=== A success clears the countdown ===" -ForegroundColor Cyan
# A password that works must not be on a countdown for the rest of the run because of a typo an
# hour ago.
Reset-Cache
[void](Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null)
Register-RunCredentialResult -Purpose "UCS Manager" -Succeeded $false 6>$null
Register-RunCredentialResult -Purpose "UCS Manager" -Succeeded $false 6>$null
Assert-Equal "two failures counted" 2 $Global:CredentialAttempts["UCS Manager"]
Register-RunCredentialResult -Purpose "UCS Manager" -Succeeded $true 6>$null
Assert-Equal "a success resets the count" 0 $Global:CredentialAttempts["UCS Manager"]
Assert-Equal "and the system is not blocked" $false ([bool]$Global:CredentialBlocked["UCS Manager"])

Write-Host "`n=== Nothing outlives the run ===" -ForegroundColor Cyan
Reset-Cache
[void](Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null)
[void](Get-RunCredential -Purpose "Aria Operations" -Message "m" 6>$null)
Register-RunCredentialResult -Purpose "UCS Manager" -Succeeded $false 6>$null
Clear-RunCredential
Assert-Equal "no credential is held" 0 $Global:CredentialCache.Count
Assert-Equal "no attempt count survives" 0 $Global:CredentialAttempts.Count
Assert-Equal "no block survives" 0 $Global:CredentialBlocked.Count
Assert-Equal "and the vendor globals are cleared too" $true ($null -eq $Global:UcsCredential -and $null -eq $Global:AriaCredential)

Write-Host "`n=== Cancelling the dialog holds nothing ===" -ForegroundColor Cyan
Reset-Cache
function Get-Credential { param($Message,$UserName) $script:TypedCount++; return $null }
Assert-Equal "no credential is returned" $true ($null -eq (Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null))
Assert-Equal "and nothing is held" $true ($null -eq $Global:CredentialCache["UCS Manager"])
function Get-Credential { param($Message,$UserName) $script:TypedCount++; return [pscredential]::new($script:TypedUser, (ConvertTo-SecureString 'typed-password' -AsPlainText -Force)) }

Write-Host "`n=== It is wired in, and cleared however the run ends ===" -ForegroundColor Cyan
$sourceText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "UCS Manager goes through the cache" $true ($sourceText -match 'Get-RunCredential -Purpose "UCS Manager"')
# Aria has its own resolver - it offers a 1/2 choice where UCS Manager passes straight through,
# because vIDM rebuilds the username as user@domain@source and that composition is still being
# proven at this site. It uses the same cache, counters and block.
Assert-Equal "Aria Operations uses the same cache" $true ($sourceText -match '\$Global:CredentialCache\["Aria Operations"\] = \$credential')
Assert-Equal "and respects the same block" $true ($sourceText -match '\$Global:CredentialBlocked.ContainsKey\("Aria Operations"\)')
Assert-Equal "a UCSM failure is counted" $true ($sourceText -match 'Register-RunCredentialResult -Purpose "UCS Manager" -Succeeded \$false')
Assert-Equal "an Aria failure is counted" $true ($sourceText -match 'Register-RunCredentialResult -Purpose "Aria Operations" -Succeeded \$false')
# The clear is in the script's outermost finally, so an exit, a stop or a crash all reach it.
Assert-Equal "the cache is cleared in the outermost finally" $true ($sourceText -match '(?s)\} finally \{.*Clear-RunCredential')
# Nothing is written to disk.
Assert-Equal "no credential is ever exported" $true (-not ($sourceText -match 'Export-Clixml|ConvertFrom-SecureString'))
# The passthrough menu is gone and must stay gone - a question whose answer is always the same is
# a keystroke between the operator and the change.
Assert-Equal "no passthrough menu remains" $true (-not ($sourceText -match 'Use the one held'))

Write-Host "`n=== The vCenter credential is offered to the systems that follow ===" -ForegroundColor Cyan
# vCenter is signed in to first and exactly once, so by the time UCS Manager is reached it is the
# only credential in the run already proven against something. In these estates it is the same
# domain account for all three, and the operator should not type it three times.
Reset-Cache
Set-SharedRunCredential -Credential ([pscredential]::new('DPE\svc-esxi', (ConvertTo-SecureString 'vc-password' -AsPlainText -Force))) -Source "vCenter" 6>$null
$ucs = Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null
Assert-Equal "nothing was typed" 0 $script:TypedCount
Assert-Equal "the vCenter credential came through" "DPE\svc-esxi" $ucs.UserName
Assert-Equal "with no question asked" 0 $script:Prompts.Count
Assert-Equal "the source is recorded as shared" "Shared" $Global:CredentialSource["UCS Manager"]
# Any other system that has not refused it gets the same, silently.
$aria = Get-RunCredential -Purpose "Aria Operations" -Message "m" 6>$null
Assert-Equal "it passes through there too" "DPE\svc-esxi" $aria.UserName
Assert-Equal "still nothing typed" 0 $script:TypedCount
Assert-Equal "and still nothing asked" 0 $script:Prompts.Count

Write-Host "`n=== Only a PROVEN credential is shared ===" -ForegroundColor Cyan
# Set-SharedRunCredential is called after a successful sign-in and nowhere else. Sharing an
# unproven one would replay a wrong password at three systems in turn.
Reset-Cache
Set-SharedRunCredential -Credential $null -Source "vCenter" 6>$null
Assert-Equal "a null credential is not held" $true ($null -eq $Global:SharedCredential)
# It has to RETURN on $null, not prompt for the parameter. Connect-VCenterServer passes $null on
# every cancelled vCenter dialog, and a mandatory [pscredential] there hung the script on a console
# prompt instead. Asserted on the signature because the hang cannot be reproduced in-process.
$sigText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the shared-credential parameter cannot prompt" $true ($sigText -match '(?s)function Set-SharedRunCredential.*?param\(\s*\[AllowNull\(\)\]\$Credential,')
Set-SharedRunCredential -Credential ([pscredential]::new('first', (ConvertTo-SecureString 'p' -AsPlainText -Force))) -Source "vCenter" 6>$null
Set-SharedRunCredential -Credential ([pscredential]::new('second', (ConvertTo-SecureString 'p' -AsPlainText -Force))) -Source "UCS Manager" 6>$null
Assert-Equal "the first proven credential wins - vCenter's" "first" $Global:SharedCredential.UserName
Assert-Equal "and its source is named for the prompt" "vCenter" $Global:SharedCredentialSource

Write-Host "`n=== A system that rejects it is not offered it again ===" -ForegroundColor Cyan
# This is the lockout guard for the replay: UCS Manager refusing the domain account must not mean
# the same password goes at the next domain, and the next, until the account locks.
Reset-Cache
Set-SharedRunCredential -Credential ([pscredential]::new('DPE\svc-esxi', (ConvertTo-SecureString 'p' -AsPlainText -Force))) -Source "vCenter" 6>$null
[void](Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null)
Register-RunCredentialResult -Purpose "UCS Manager" -Succeeded $false 6>$null
Assert-Equal "UCS Manager is marked as having rejected it" $true $Global:SharedCredentialRejected["UCS Manager"]
$script:Prompts = New-Object System.Collections.Generic.List[string]
$next = Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null
Assert-Equal "so the next UCSM sign-in is typed, not replayed" 1 $script:TypedCount
Assert-Equal "it is the typed one" "first.user" $next.UserName
# Per system: one system refusing a domain account says nothing about the other.
$ariaAfter = Get-RunCredential -Purpose "Aria Operations" -Message "m" 6>$null
Assert-Equal "another system still passes it through" "DPE\svc-esxi" $ariaAfter.UserName

Write-Host "`n=== A credential typed for a system beats the shared one ===" -ForegroundColor Cyan
# Reached after the shared one is refused: what the operator then types for UCS Manager is what
# comes back next time, not the vCenter credential that has already failed there.
Reset-Cache
Set-SharedRunCredential -Credential ([pscredential]::new('shared.user', (ConvertTo-SecureString 'p' -AsPlainText -Force))) -Source "vCenter" 6>$null
[void](Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null)
Register-RunCredentialResult -Purpose "UCS Manager" -Succeeded $false 6>$null
$script:TypedUser = 'ucs.admin'
[void](Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null)
$second = Get-RunCredential -Purpose "UCS Manager" -Message "m" 6>$null
Assert-Equal "the UCSM-specific account is what comes back" "ucs.admin" $second.UserName
Assert-Equal "and it is recorded as this system's own" "Held" $Global:CredentialSource["UCS Manager"]
Assert-Equal "with nothing asked at any point" 0 $script:Prompts.Count
$script:TypedUser = 'first.user'

Write-Host "`n=== Clearing forgets the shared credential too ===" -ForegroundColor Cyan
Set-SharedRunCredential -Credential ([pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))) -Source "vCenter" 6>$null
Clear-RunCredential
Assert-Equal "nothing proven survives the run" $true ($null -eq $Global:SharedCredential)
Assert-Equal "nor the rejections" 0 $Global:SharedCredentialRejected.Count
Assert-Equal "nor the sources" 0 $Global:CredentialSource.Count

Write-Host "`n=== vCenter is where it is captured ===" -ForegroundColor Cyan
$vcText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "the vCenter connect asks for a credential" $true ($vcText -match 'Get-Credential -Message "vCenter account for')
Assert-Equal "and passes it to Connect-VIServer" $true ($vcText -match 'Connect-VIServer -Server \$Server -Credential \$vcCredential')
Assert-Equal "cancelling still connects the old way" $true ($vcText -match '(?s)else \{\s*Connect-VIServer -Server \$Server -ErrorAction Stop')
# Only after the connect succeeds - the line sits below the try/catch, not inside the try.
Assert-Equal "it is only shared once vCenter has accepted it" $true ($vcText -match '(?s)\$global:vCenterConnected = \$true.*Set-SharedRunCredential -Credential \$vcCredential -Source "vCenter"')

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
