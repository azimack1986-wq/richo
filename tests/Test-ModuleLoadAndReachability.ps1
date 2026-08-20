<#
.SYNOPSIS
    Tests the guarded module loading and the management endpoint reachability probe.

.DESCRIPTION
    Two faults, both reported from the field.

    MODULES. The script relied on PowerShell auto-loading every module on first use. In a VS Code
    integrated console that failed on random servers and the cmdlets came back "not recognized" -
    the command discovery cache had not finished walking $env:PSModulePath, which for
    Intersight.PowerShell means parsing a manifest exporting several thousand cmdlets. What matters
    here is not that a module gets imported but that a module ALREADY LOADED is never touched: the
    jump hosts carry pinned bundles, and re-importing one is worse than the problem being fixed.

    REACHABILITY. A firewall that DROPS a port sends nothing back, so the UCSM or Intersight client
    sits on its own timeout - minutes, with no output - and then reports something about
    credentials. The probe bounds that to a known budget and says what it actually is.

    Standalone - no Pester, no PowerCLI, no infrastructure, and no sockets are opened.

.EXAMPLE
    pwsh -File ./tests/Test-ModuleLoadAndReachability.ps1
#>

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/firmware/Invoke-AutoDeployFirmwareBatchPreAuth.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors" }

$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in @('Import-RequiredModules','Get-EndpointHostName',
                                 'Test-ManagementEndpointReachable','Confirm-ManagementEndpointReachable') } |
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

# --- Module loading -----------------------------------------------------------------------------
$script:Loaded    = @()          # modules the session already has
$script:Available = @()          # modules installed but not loaded
$script:Imported  = New-Object System.Collections.Generic.List[string]
$script:ImportFails = @()

function Get-Module { param($Name,[switch]$ListAvailable)
    if ($ListAvailable) { return @() }   # never used directly - see the cache assertion below
    if ($script:Loaded -contains $Name) { return [pscustomobject]@{ Name = $Name } }
    return $null }
function Import-Module { param($Name,$ErrorAction)
    # A module that is not installed throws here - which is exactly how the real cmdlet behaves,
    # and why no availability probe is needed in front of it.
    if ($script:ImportFails -contains $Name) { throw "blocked by policy" }
    if ($script:Available -notcontains $Name) { throw "The specified module '$Name' was not loaded because no valid module file was found in any module directory." }
    $script:Imported.Add($Name) }

function Reset-ModuleState {
    $script:Loaded = @(); $script:Available = @(); $script:ImportFails = @()
    $script:Imported = New-Object System.Collections.Generic.List[string]
    $Global:RequiredModulesLoaded = $false
    $Global:RunSummary = New-Object System.Collections.Generic.List[object]
}

Write-Host "`n=== A module already in the session is never re-imported ===" -ForegroundColor Cyan
# THE RULE THIS PRESERVES. These jump hosts carry pinned bundles. An unconditional import either
# duplicates a load or fights a version that was chosen deliberately.
Reset-ModuleState
$script:Loaded = @('VMware.VimAutomation.Core','VMware.DeployAutomation','Intersight.PowerShell','Cisco.UCSManager')
$script:Available = @('VMware.VimAutomation.Core','VMware.DeployAutomation','Intersight.PowerShell','Cisco.UCSManager')
Import-RequiredModules 6>$null
Assert-Equal "nothing was imported" 0 $script:Imported.Count

Write-Host "`n=== A module that is installed but not loaded is loaded once ===" -ForegroundColor Cyan
Reset-ModuleState
$script:Available = @('VMware.VimAutomation.Core','VMware.DeployAutomation','Intersight.PowerShell','Cisco.UCSManager')
Import-RequiredModules 6>$null
Assert-Equal "all four were imported" 4 $script:Imported.Count
# Auto Deploy is in the list because the ESXi target is now read from the deploy rule rather than
# typed into the script - without it there is no target to compare a host against.
Assert-Equal "PowerCLI, Auto Deploy, Intersight and UCS PowerTool" "VMware.VimAutomation.Core,VMware.DeployAutomation,Intersight.PowerShell,Cisco.UCSManager" ($script:Imported.ToArray() -join ',')

Write-Host "`n=== It runs once per session, not once per cluster ===" -ForegroundColor Cyan
$script:Imported = New-Object System.Collections.Generic.List[string]
Import-RequiredModules 6>$null
Assert-Equal "a second call does nothing" 0 $script:Imported.Count

Write-Host "`n=== A renamed product module falls back to its other names ===" -ForegroundColor Cyan
# UCS PowerTool has shipped as Cisco.UCSManager, Cisco.UCS.Core and CiscoUcsPS across releases.
Reset-ModuleState
$script:Available = @('CiscoUcsPS')
Import-RequiredModules 6>$null
Assert-Equal "the name that is actually installed is used" "CiscoUcsPS" ($script:Imported.ToArray() -join ',')

Write-Host "`n=== A module that will not load is reported, not fatal ===" -ForegroundColor Cyan
# The checks that follow - Assert-IntersightPowerShellAvailable, Assert-UcsPowerToolAvailable,
# Connect-VCenterServer - say precisely what is missing and why it matters. Throwing here would
# stop the run before any of them could.
Reset-ModuleState
$script:Available = @('VMware.VimAutomation.Core','Intersight.PowerShell')
$script:ImportFails = @('Intersight.PowerShell')
$threw = $false
try { Import-RequiredModules 6>$null } catch { $threw = $true }
Assert-Equal "it does not throw" $false $threw
Assert-Equal "PowerCLI still loaded" "VMware.VimAutomation.Core" ($script:Imported.ToArray() -join ',')
Assert-Equal "and the failure is on the record" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'NotLoaded' -and $_.Details -match 'Intersight' }).Count)

Write-Host "`n=== A module that is not installed is not imported ===" -ForegroundColor Cyan
Reset-ModuleState
Import-RequiredModules 6>$null
Assert-Equal "nothing was imported" 0 $script:Imported.Count
Assert-Equal "all four reported as not loaded" 4 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'NotLoaded' }).Count)

Write-Host "`n=== It never installs or updates anything ===" -ForegroundColor Cyan
# A module load is a decision about this session. Installing is a decision about the machine, and
# is not this script's to make.
$importFn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'Import-RequiredModules' })[0]
Assert-Equal "no Install-Module" $true (-not ($importFn.Extent.Text -match 'Install-Module'))
Assert-Equal "no Update-Module" $true (-not ($importFn.Extent.Text -match 'Update-Module'))
Assert-Equal "no Save-Module" $true (-not ($importFn.Extent.Text -match 'Save-Module'))
Assert-Equal "it imports rather than probing availability first" $true (-not ($importFn.Extent.Text -match 'Get-Module -ListAvailable'))
Assert-Equal "and the already-loaded guard is still there" $true ($importFn.Extent.Text -match 'Get-Module -Name \$name')

Write-Host "`n=== It is the first thing the pre-flight does ===" -ForegroundColor Cyan
$prereqFn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'Confirm-RunPrerequisites' })[0]
Assert-Equal "pre-flight loads the modules" $true ($prereqFn.Extent.Text -match 'Import-RequiredModules')

# --- Endpoint reachability ----------------------------------------------------------------------
Write-Host "`n=== A URL, a bare name and a host:port all reduce to the host ===" -ForegroundColor Cyan
Assert-Equal "https URL"        "pva.example.com" (Get-EndpointHostName -Target "https://pva.example.com")
Assert-Equal "with a path"      "pva.example.com" (Get-EndpointHostName -Target "https://pva.example.com/an/api")
Assert-Equal "http URL"         "ucsm-a"          (Get-EndpointHostName -Target "http://ucsm-a")
Assert-Equal "bare name"        "ucsm-a"          (Get-EndpointHostName -Target "ucsm-a")
Assert-Equal "host and port"    "ucsm-a"          (Get-EndpointHostName -Target "ucsm-a:443")
Assert-Equal "surrounding space" "ucsm-a"         (Get-EndpointHostName -Target "  ucsm-a  ")
Assert-Equal "an IPv6 literal is left alone" "fd00::1" (Get-EndpointHostName -Target "fd00::1")
Assert-Equal "nothing in, nothing out" "" (Get-EndpointHostName -Target "")

Write-Host "`n=== HTTPS is tried first, HTTP only to tell the two apart ===" -ForegroundColor Cyan
$script:PortsTried = New-Object System.Collections.Generic.List[string]
$script:OpenPorts = @(443)
function Test-TcpPortOpen { param($ComputerName,$Port,$TimeoutSeconds)
    $script:PortsTried.Add("$ComputerName`:$Port/$TimeoutSeconds")
    return ($script:OpenPorts -contains $Port) }

$script:PortsTried.Clear()
$result = Test-ManagementEndpointReachable -Target "https://pva.example.com" -TimeoutSeconds 60
Assert-Equal "reachable" $true $result.Reachable
Assert-Equal "on 443" 443 $result.Port
Assert-Equal "and 80 was never asked" 1 $script:PortsTried.Count

$script:PortsTried.Clear(); $script:OpenPorts = @(80)
$result = Test-ManagementEndpointReachable -Target "ucsm-a" -TimeoutSeconds 60
Assert-Equal "HTTP answering still counts as reachable" $true $result.Reachable
Assert-Equal "on 80" 80 $result.Port
Assert-Equal "having tried 443 first" "ucsm-a:443/40" $script:PortsTried[0]

Write-Host "`n=== The whole probe stays inside its budget ===" -ForegroundColor Cyan
# The point of the number is that the operator is told inside a minute. A probe that splits its
# budget badly and takes two is no better than the client timeout it replaces.
$script:PortsTried.Clear(); $script:OpenPorts = @()
$result = Test-ManagementEndpointReachable -Target "ucsm-a" -TimeoutSeconds 60
$budgets = @($script:PortsTried.ToArray() | ForEach-Object { [int]($_ -split '/')[1] })
Assert-Equal "both ports were tried" 2 $budgets.Count
Assert-Equal "and together they do not exceed the budget" $true ((($budgets | Measure-Object -Sum).Sum) -le 60)
Assert-Equal "unreachable is reported as unreachable" $false $result.Reachable
Assert-Equal "naming both ports and the budget" $true ($result.Detail -match '443.*80.*60')

Write-Host "`n=== A name that resolves to nothing is unreachable, not an error ===" -ForegroundColor Cyan
$result = Test-ManagementEndpointReachable -Target "" -TimeoutSeconds 60
Assert-Equal "empty target is unreachable" $false $result.Reachable
Assert-Equal "and says why" $true ($result.Detail -match 'No host name')

Write-Host "`n=== An unreachable endpoint says firewall, and asks ===" -ForegroundColor Cyan
$script:Answers = New-Object System.Collections.Generic.Queue[string]
$script:Prompts = New-Object System.Collections.Generic.List[string]
function Read-ChoiceExit { param($Message,$AllowedChoices,$ExitMessage)
    $script:Prompts.Add($Message)
    if ($script:Answers.Count -eq 0) { throw "EXIT: $ExitMessage" }
    return $script:Answers.Dequeue() }

$script:OpenPorts = @(); $script:Prompts.Clear()
$script:Answers.Enqueue('C')
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$ok = Confirm-ManagementEndpointReachable -Target "ucsm-a" -DeviceKind "UCS Manager" -TimeoutSeconds 60 6>$null
Assert-Equal "C continues anyway, reporting the endpoint as unproven" $false $ok
Assert-Equal "the operator was asked once" 1 $script:Prompts.Count
Assert-Equal "and told which device did not answer" $true ($script:Prompts[0] -match "UCS Manager 'ucsm-a'")
Assert-Equal "the override is on the record" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'Overridden' }).Count)

Write-Host "`n=== R re-probes, so a rule raised mid-run is picked up ===" -ForegroundColor Cyan
$script:OpenPorts = @(); $script:Prompts.Clear()
$Global:RunSummary = New-Object System.Collections.Generic.List[object]
$script:Answers.Clear(); $script:Answers.Enqueue('R')
# The firewall rule lands between the two probes.
function Test-TcpPortOpen { param($ComputerName,$Port,$TimeoutSeconds)
    $script:PortsTried.Add("$ComputerName`:$Port")
    if ($script:Prompts.Count -ge 1) { return ($Port -eq 443) }
    return $false }
$ok = Confirm-ManagementEndpointReachable -Target "ucsm-a" -DeviceKind "UCS Manager" -TimeoutSeconds 60 6>$null
Assert-Equal "the second probe succeeds" $true $ok
Assert-Equal "after exactly one question" 1 $script:Prompts.Count
Assert-Equal "and the endpoint is recorded reachable" 1 (@($Global:RunSummary.ToArray() | Where-Object { $_.Result -eq 'Reachable' }).Count)

Write-Host "`n=== A reachable endpoint asks nothing ===" -ForegroundColor Cyan
$script:Prompts.Clear()
function Test-TcpPortOpen { param($ComputerName,$Port,$TimeoutSeconds) return $true }
$ok = Confirm-ManagementEndpointReachable -Target "https://pva.example.com" -DeviceKind "Intersight" -TimeoutSeconds 60 6>$null
Assert-Equal "reachable" $true $ok
Assert-Equal "no prompt" 0 $script:Prompts.Count

Write-Host "`n=== The probe runs before the login, for both products ===" -ForegroundColor Cyan
$scriptText = [System.IO.File]::ReadAllText($scriptPath)
Assert-Equal "UCS Manager is probed" $true ($scriptText -match 'Confirm-ManagementEndpointReachable -Target \$target -DeviceKind "UCS Manager"')
Assert-Equal "Intersight is probed" $true ($scriptText -match 'Confirm-ManagementEndpointReachable -Target \$\S+ -DeviceKind "Intersight"')
$ucsConnect = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -eq 'Connect-UcsCached' })[0]
Assert-Equal "and it is ahead of Connect-Ucs, not after it" $true (
    $ucsConnect.Extent.Text.IndexOf('Confirm-ManagementEndpointReachable') -lt $ucsConnect.Extent.Text.IndexOf('Connect-UcsOneAttempt -UcsTarget $target'))

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
