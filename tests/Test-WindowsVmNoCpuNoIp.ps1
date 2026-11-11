<#
.SYNOPSIS
    Tests the match rules and folder-path building in Export-WindowsVmNoCpuNoIpReport.ps1.

.DESCRIPTION
    Extracts the pure helpers from the script by AST and runs them against hand-built objects
    shaped like Get-View results: Windows detection from the configured guest OS when Tools is
    silent, CPU threshold, Tools IP detection, power-state and template exclusion, and the VM
    folder path (hidden 'vm' folder dropped, vApps included, broken chains marked).

    Standalone - no Pester, no vendor modules, no infrastructure.

.EXAMPLE
    pwsh -File ./tests/Test-WindowsVmNoCpuNoIp.ps1
#>

Set-StrictMode -Version Latest

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/vsphere/Export-WindowsVmNoCpuNoIpReport.ps1'
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "parse errors in $scriptPath" }

$wanted = @('Get-SafeProperty', 'Get-MoRefKey', 'Test-WindowsGuest', 'Get-ToolsIpAddress', 'Get-VmEvaluation', 'Get-VmFolderPath')
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name } |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ($Expected -eq $Actual) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}

function New-Ref { param([string]$Type, [string]$Value) [pscustomobject]@{ Type = $Type; Value = $Value } }

# A VM shaped like a Get-View -Property result. Anything not passed is left null, as Get-View does.
function New-VmView {
    param(
        [string]$GuestId = 'windows2019srv_64Guest',
        [string]$GuestFullName = 'Microsoft Windows Server 2019 (64-bit)',
        [string]$GuestFamily = $null,
        [string]$IpAddress = $null,
        [object[]]$NetIps = @(),
        $Cpu = 0,
        [string]$PowerState = 'poweredOn',
        [bool]$Template = $false,
        [switch]$NoConfig
    )
    $nics = @()
    if ($NetIps.Count -gt 0) { $nics = @([pscustomobject]@{ IpAddress = $NetIps }) }
    $config = if ($NoConfig) { $null } else { [pscustomobject]@{ GuestId = $GuestId; GuestFullName = $GuestFullName; Template = $Template } }
    [pscustomobject]@{
        Name    = 'vm01'
        Config  = $config
        Guest   = [pscustomobject]@{ GuestFamily = $GuestFamily; IpAddress = $IpAddress; Net = $nics }
        Summary = [pscustomobject]@{ QuickStats = [pscustomobject]@{ OverallCpuUsage = $Cpu } }
        Runtime = [pscustomobject]@{ PowerState = $PowerState }
    }
}

Write-Host "`n=== Get-SafeProperty never throws under StrictMode ===" -ForegroundColor Cyan
Assert-Equal "null input"               $null (Get-SafeProperty -InputObject $null -Path 'A.B')
Assert-Equal "missing property"         $null (Get-SafeProperty -InputObject ([pscustomobject]@{ A = 1 }) -Path 'B')
Assert-Equal "null in the middle"       $null (Get-SafeProperty -InputObject ([pscustomobject]@{ A = $null }) -Path 'A.B')
Assert-Equal "nested value"             5     (Get-SafeProperty -InputObject ([pscustomobject]@{ A = [pscustomobject]@{ B = 5 } }) -Path 'A.B')

Write-Host "`n=== Windows detection ===" -ForegroundColor Cyan
Assert-Equal "configured windows2019srv_64Guest"   $true  (Test-WindowsGuest -VmView (New-VmView))
Assert-Equal "old winNetStandardGuest id"          $true  (Test-WindowsGuest -VmView (New-VmView -GuestId 'winNetStandardGuest' -GuestFullName 'Microsoft Windows Server 2003'))
Assert-Equal "full name only says Windows"         $true  (Test-WindowsGuest -VmView (New-VmView -GuestId 'otherGuest64' -GuestFullName 'Microsoft Windows Server 2022'))
Assert-Equal "Tools family only (no Config)"       $true  (Test-WindowsGuest -VmView (New-VmView -NoConfig -GuestFamily 'windowsGuest'))
Assert-Equal "RHEL is not Windows"                 $false (Test-WindowsGuest -VmView (New-VmView -GuestId 'rhel8_64Guest' -GuestFullName 'Red Hat Enterprise Linux 8 (64-bit)'))
Assert-Equal "no Config and no Tools"              $false (Test-WindowsGuest -VmView (New-VmView -NoConfig))

Write-Host "`n=== Tools IP detection ===" -ForegroundColor Cyan
Assert-Equal "no IP anywhere"                      0 @(Get-ToolsIpAddress -VmView (New-VmView)).Count
Assert-Equal "primary IP only"                     1 @(Get-ToolsIpAddress -VmView (New-VmView -IpAddress '10.1.1.5')).Count
Assert-Equal "NIC IP only"                         1 @(Get-ToolsIpAddress -VmView (New-VmView -NetIps @('10.1.1.6'))).Count
Assert-Equal "primary repeated on NIC is one"      2 @(Get-ToolsIpAddress -VmView (New-VmView -IpAddress '10.1.1.5' -NetIps @('10.1.1.5', 'fe80::1'))).Count
Assert-Equal "blank strings are not IPs"           0 @(Get-ToolsIpAddress -VmView (New-VmView -IpAddress '  ' -NetIps @('', $null))).Count

Write-Host "`n=== Match rules ===" -ForegroundColor Cyan
Assert-Equal "Windows, on, 0 MHz, no IP -> match"  $true  (Get-VmEvaluation -VmView (New-VmView)).IsMatch
Assert-Equal "null CPU counts as zero"             $true  (Get-VmEvaluation -VmView (New-VmView -Cpu $null)).IsMatch
Assert-Equal "has an IP -> no match"               $false (Get-VmEvaluation -VmView (New-VmView -IpAddress '10.1.1.5')).IsMatch
Assert-Equal "CPU 1 MHz -> no match at 0"          $false (Get-VmEvaluation -VmView (New-VmView -Cpu 1)).IsMatch
Assert-Equal "CPU 15 MHz matches at threshold 20"  $true  (Get-VmEvaluation -VmView (New-VmView -Cpu 15) -CpuThresholdMhz 20).IsMatch
Assert-Equal "CPU 20 MHz matches at threshold 20"  $true  (Get-VmEvaluation -VmView (New-VmView -Cpu 20) -CpuThresholdMhz 20).IsMatch
Assert-Equal "Linux -> no match"                   $false (Get-VmEvaluation -VmView (New-VmView -GuestId 'rhel8_64Guest' -GuestFullName 'Red Hat 8')).IsMatch
Assert-Equal "template -> no match"                $false (Get-VmEvaluation -VmView (New-VmView -Template $true)).IsMatch
Assert-Equal "powered off -> no match by default"  $false (Get-VmEvaluation -VmView (New-VmView -PowerState 'poweredOff')).IsMatch
Assert-Equal "powered off -> match when included"  $true  (Get-VmEvaluation -VmView (New-VmView -PowerState 'poweredOff') -IncludePoweredOff).IsMatch
Assert-Equal "suspended -> match when included"    $true  (Get-VmEvaluation -VmView (New-VmView -PowerState 'suspended') -IncludePoweredOff).IsMatch

Write-Host "`n=== VM folder path ===" -ForegroundColor Cyan
$dc = New-Ref 'Datacenter' 'datacenter-1'
$vmRoot = New-Ref 'Folder' 'group-v1'
$prod = New-Ref 'Folder' 'group-v10'
$app = New-Ref 'Folder' 'group-v11'
$vapp = New-Ref 'VirtualApp' 'resgroup-v50'
$rp = New-Ref 'ResourcePool' 'resgroup-9'
$lookup = @{
    (Get-MoRefKey -Ref $dc)     = [pscustomobject]@{ Name = 'DC1'; Parent = (New-Ref 'Folder' 'group-d1') }
    (Get-MoRefKey -Ref $vmRoot) = [pscustomobject]@{ Name = 'vm'; Parent = $dc }
    (Get-MoRefKey -Ref $prod)   = [pscustomobject]@{ Name = 'Prod'; Parent = $vmRoot }
    (Get-MoRefKey -Ref $app)    = [pscustomobject]@{ Name = 'App'; Parent = $prod }
    (Get-MoRefKey -Ref $vapp)   = [pscustomobject]@{ Name = 'MyVApp'; Parent = $rp; ParentFolder = $prod; ParentVApp = $null }
}

$nested = Get-VmFolderPath -Lookup $lookup -StartRef $app
Assert-Equal "nested folder path"                  '/Prod/App' $nested.Path
Assert-Equal "datacenter found"                    'DC1'       $nested.Datacenter
Assert-Equal "VM at the root shows /"              '/'         (Get-VmFolderPath -Lookup $lookup -StartRef $vmRoot).Path
Assert-Equal "VM in a vApp"                        '/Prod/MyVApp' (Get-VmFolderPath -Lookup $lookup -StartRef $vapp).Path
Assert-Equal "no parent at all"                    '(incomplete) /' (Get-VmFolderPath -Lookup $lookup -StartRef $null).Path
Assert-Equal "unknown folder is marked"            '(incomplete) /' (Get-VmFolderPath -Lookup $lookup -StartRef (New-Ref 'Folder' 'group-v999')).Path

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
