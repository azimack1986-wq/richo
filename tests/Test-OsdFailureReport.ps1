<#
.SYNOPSIS
    End-to-end tests for scripts/mecm/Get-OsdFailureReport.ps1 against generated failure bundles.

.DESCRIPTION
    Builds a folder of synthetic MECM OSD failure bundles (.zip) that reproduce the shapes real
    bundles take, runs the report against them, and checks what comes back:

      - CMTrace smsts.log with multi-line entries, so "Failed to run the action" stays joined to its
        "(Error: ...; Source: ...)" line;
      - the WinPE (+480) to full OS bias change part-way through a build;
      - smsts.log copies from several locations plus a rolled-over smsts-*.log (de-duplication);
      - a log with no start banner (rolled over) and a log holding two task sequence runs;
      - a failure-handling task sequence that copies the logs and then forces a failure;
      - UTF-16 Panther logs, NetSetup.log, AppEnforce.log, ZTIGather.log, unattend.xml with a
        password that must never be reported;
      - a nested zip, a bundle with no smsts.log, an empty bundle, and a corrupt file;
      - the -LastHours, -Since and -ComputerName filters, and -OutputPath reports.

    The log lines are modelled on real ConfigMgr output, but they are synthetic. A pass here proves
    the parsing and ranking logic, not that every wording in a production log is covered.

    Standalone - no Pester, no MECM, no network share.

.PARAMETER FixtureDirectory
    Keep the generated bundles here instead of a temp folder that is deleted afterwards.

.EXAMPLE
    pwsh -File ./tests/Test-OsdFailureReport.ps1
#>
param([string]$FixtureDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repoRoot 'scripts/mecm/Get-OsdFailureReport.ps1'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$keep = [bool]$FixtureDirectory
if (-not $FixtureDirectory) { $FixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ("osdfixtures-" + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
if (Test-Path $FixtureDirectory) { Remove-Item $FixtureDirectory -Recurse -Force }
New-Item -ItemType Directory -Path $FixtureDirectory | Out-Null

$script:pass = 0; $script:fail = 0
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red; if ($Detail) { Write-Host "          $Detail" -ForegroundColor Red } }
}

# ---- Fixture helpers ----------------------------------------------------------------------------
function L {
    # One CMTrace line. Type 1 info, 2 warning, 3 error.
    param([datetime]$At, [string]$Msg, [string]$Comp = 'TSManager', [int]$Type = 1, [string]$Bias = '+480')
    '<![LOG[{0}]LOG]!><time="{1}{2}" date="{3}" component="{4}" context="" type="{5}" thread="1234" file="tsmanager.cpp:100">' -f `
        $Msg, $At.ToString('HH:mm:ss.fff'), $Bias, $At.ToString('MM-dd-yyyy'), $Comp, $Type
}

function New-Bundle {
    param([string]$Name, [hashtable]$Files, [datetime]$Uploaded, [hashtable]$Encodings = @{}, [hashtable]$Written = @{})
    $path = Join-Path $FixtureDirectory $Name
    $fs = [IO.File]::Open($path, 'Create')
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($k in $Files.Keys) {
        $entry = $zip.CreateEntry($k)
        if ($Written.ContainsKey($k)) { $entry.LastWriteTime = [DateTimeOffset]$Written[$k] }
        $s = $entry.Open()
        $content = $Files[$k]
        if ($content -is [byte[]]) { $bytes = $content }
        else {
            $enc = New-Object Text.UTF8Encoding $false
            if ($Encodings.ContainsKey($k)) { $enc = $Encodings[$k] }
            $text = ($content -join "`r`n")
            $bytes = $enc.GetPreamble() + $enc.GetBytes($text)
        }
        $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
    }
    $zip.Dispose(); $fs.Dispose()
    (Get-Item $path).LastWriteTime = $Uploaded
}

function New-ZipBytes {
    param([hashtable]$Files)
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($k in $Files.Keys) {
        $entry = $zip.CreateEntry($k); $s = $entry.Open()
        $b = (New-Object Text.UTF8Encoding $false).GetBytes(($Files[$k] -join "`r`n")); $s.Write($b, 0, $b.Length); $s.Dispose()
    }
    $zip.Dispose()
    # Comma: stop PowerShell unrolling the byte[] into object[].
    return , $ms.ToArray()
}

$now = Get-Date
$day = $now.Date.AddHours(8)   # builds start 08:00 local "today"

# ---- PC1001: content not on DP during the driver package (WinPE) --------------------------------
$t = $day
$smsts = @(
    (L $t '==============================[ TSBootShell.exe ]==============================' 'TSBootShell')
    (L $t.AddSeconds(5) 'Booted from network (PXE)' 'TSBootShell')
    (L $t.AddMinutes(2) '==============================[ TSManager.exe ]==============================')
    (L $t.AddMinutes(3) 'Start executing an instruction. Instruction name: Partition Disk 0 - UEFI. Instruction pointer: 5')
    (L $t.AddMinutes(4) 'Process completed with exit code 0')
    (L $t.AddMinutes(5) 'Start executing an instruction. Instruction name: Apply Operating System. Instruction pointer: 9')
    (L $t.AddMinutes(19) 'Process completed with exit code 0')
    (L $t.AddMinutes(20) 'Start executing an instruction. Instruction name: Apply Driver Package - Latitude 7450. Instruction pointer: 14')
    (L $t.AddMinutes(21) 'Failed to resolve PackageID=P0100123, hr=0x80040104' 'OSDDriverClient' 3)
    (L $t.AddMinutes(21).AddSeconds(1) 'Process completed with exit code 2147942402')
    (L $t.AddMinutes(21).AddSeconds(2) ("Failed to run the action: Apply Driver Package - Latitude 7450. `r`nThe system cannot find the file specified. (Error: 80070002; Source: Windows)") 'TSManager' 3)
    (L $t.AddMinutes(21).AddSeconds(3) 'The execution of the group (Drivers) has failed and the execution has been aborted. An action failed. Operation aborted (Error: 80004004; Source: Windows)' 'TSManager' 2)
    (L $t.AddMinutes(21).AddSeconds(4) 'Execution of task sequence failed. The system cannot find the file specified. (Error: 80070002; Source: Windows)' 'TSManager' 3)
)
$gather = @(
    (L $t.AddMinutes(2) 'Property Make is now = Dell Inc.' 'ZTIGather')
    (L $t.AddMinutes(2) 'Property Model is now = Latitude 7450' 'ZTIGather')
    (L $t.AddMinutes(2) 'Property SerialNumber is now = 7XK2Q34' 'ZTIGather')
    (L $t.AddMinutes(2) 'Property OSDComputerName is now = PC1001' 'ZTIGather')
)
New-Bundle 'PC1001_20261109-0821.zip' @{ 'X/Windows/Temp/SMSTSLog/smsts.log' = $smsts; 'X/Windows/Temp/SMSTSLog/ZTIGather.log' = $gather } $now.AddHours(-3)

# ---- PC1002: domain join 0xaac, WinPE -> full OS, UTF-16 Panther, password in unattend ----------
$t = $day.AddMinutes(10)
$smstsPe = @(
    (L $t '==============================[ TSBootShell.exe ]==============================' 'TSBootShell')
    (L $t.AddMinutes(1) '==============================[ TSManager.exe ]==============================')
    (L $t.AddMinutes(2) 'Start executing an instruction. Instruction name: Apply Operating System. Instruction pointer: 9')
    (L $t.AddMinutes(18) 'Start executing an instruction. Instruction name: Setup Windows and ConfigMgr. Instruction pointer: 20')
)
$smstsOs = @(
    (L $t.AddMinutes(18) 'Start executing an instruction. Instruction name: Setup Windows and ConfigMgr. Instruction pointer: 20')
    (L $t.AddMinutes(30) '==============================[ TSManager.exe ]==============================' 'TSManager' 1 '-600')
    (L $t.AddMinutes(41) 'Start executing an instruction. Instruction name: Install Application - Corp Baseline. Instruction pointer: 31' 'TSManager' 1 '-600')
    (L $t.AddMinutes(52) ("Failed to run the action: Install Application - Corp Baseline. `r`nUnspecified error (Error: 80004005; Source: Windows)") 'TSManager' 3 '-600')
)
$netsetup = @(
    ('{0} -----------------------------------------------------------------' -f $t.AddMinutes(25).ToString('MM/dd/yyyy HH:mm:ss:fff'))
    ('{0} NetpDoDomainJoin' -f $t.AddMinutes(25).ToString('MM/dd/yyyy HH:mm:ss:fff'))
    ('{0} NetpJoinDomainOnDs: ...' -f $t.AddMinutes(25).ToString('MM/dd/yyyy HH:mm:ss:fff'))
    ("{0} `tHostName: PC1002" -f $t.AddMinutes(25).ToString('MM/dd/yyyy HH:mm:ss:fff'))
    ("{0} `tDomain: corp.example.local" -f $t.AddMinutes(25).ToString('MM/dd/yyyy HH:mm:ss:fff'))
    ("{0} `tMachineAccountOU: OU=Win11,OU=Workstations,DC=corp,DC=example,DC=local" -f $t.AddMinutes(25).ToString('MM/dd/yyyy HH:mm:ss:fff'))
    ("{0} `tAccount: CORP\svc-osdjoin" -f $t.AddMinutes(25).ToString('MM/dd/yyyy HH:mm:ss:fff'))
    ('{0} NetpDoDomainJoin: status: 0xaac' -f $t.AddMinutes(26).ToString('MM/dd/yyyy HH:mm:ss:fff'))
)
$setupact = @(
    ('{0}, Info                  [DJOIN.EXE] Unattended Join: Begin' -f $t.AddMinutes(25).ToString('yyyy-MM-dd HH:mm:ss'))
    ('{0}, Error                 [DJOIN.EXE] Unattended Join: NetJoinDomain attempt failed: 0xaac, will retry in 10 seconds...' -f $t.AddMinutes(26).ToString('yyyy-MM-dd HH:mm:ss'))
)
$unattend = @('<?xml version="1.0"?>', '<unattend><settings pass="specialize"><component><ComputerName>PC1002</ComputerName>',
    '<Identification><Credentials><Password>Sup3rS3cret!</Password></Credentials></Identification></component></settings></unattend>')
New-Bundle 'PC1002.zip' @{
    'X/Windows/Temp/SMSTSLog/smsts.log' = $smstsPe
    'C/Windows/CCM/Logs/SMSTSLog/smsts.log' = $smstsOs
    'C/Windows/debug/NetSetup.LOG' = $netsetup
    'C/Windows/Panther/UnattendGC/setupact.log' = $setupact
    'C/Windows/Panther/unattend.xml' = $unattend
} $now.AddHours(-5) @{ 'C/Windows/Panther/UnattendGC/setupact.log' = [Text.Encoding]::Unicode }

# ---- PC1003: app exit 1603, failure-handling group then a forced failure ------------------------
$t = $day.AddMinutes(20)
$smsts = @(
    (L $t '==============================[ TSManager.exe ]==============================' 'TSManager' 1 '-600')
    (L $t.AddMinutes(40) 'Start executing an instruction. Instruction name: Install Application - 7-Zip. Instruction pointer: 33' 'TSManager' 1 '-600')
    (L $t.AddMinutes(43) ("Failed to run the action: Install Application - 7-Zip. `r`nUnspecified error (Error: 80004005; Source: Windows)") 'TSManager' 3 '-600')
    (L $t.AddMinutes(43) 'Ignoring the failure because continue on error is set for the group (Main)' 'TSManager' 2 '-600')
    (L $t.AddMinutes(44) 'Start executing an instruction. Instruction name: Copy Logs to Share. Instruction pointer: 60' 'TSManager' 1 '-600')
    (L $t.AddMinutes(45) 'Start executing an instruction. Instruction name: Force Failure. Instruction pointer: 61' 'TSManager' 1 '-600')
    (L $t.AddMinutes(45) ("Failed to run the action: Force Failure. `r`nIncorrect function. (Error: 00000001; Source: Windows)") 'TSManager' 3 '-600')
)
$appEnforce = @(
    (L $t.AddMinutes(41) '+++ Starting Install enforcement for App DT "7-Zip 24.08 x64 - MSI" ApplicationDeliveryType - ScopeId_1/DeploymentType_2, Revision - 3' 'AppEnforce' 1 '-600')
    (L $t.AddMinutes(43) 'Process 4242 terminated with exitcode: 1603' 'AppEnforce' 1 '-600')
    (L $t.AddMinutes(43) 'Unmatched exit code (1603) is considered an execution failure.' 'AppEnforce' 2 '-600')
)
New-Bundle 'PC1003_20261109-0905.zip' @{ 'smsts.log' = $smsts; 'AppEnforce.log' = $appEnforce } $now.AddHours(-1)

# ---- PC1004: no disk (VMD), only a MININT name in the logs, uploaded 30 h ago -------------------
$t = $now.AddHours(-31)
$smsts = @(
    (L $t '==============================[ TSBootShell.exe ]==============================' 'TSBootShell')
    (L $t.AddSeconds(30) 'OSDComputerName = MININT-8H2K1L' 'TSManager')
    (L $t.AddMinutes(2) 'Start executing an instruction. Instruction name: Partition Disk 0 - UEFI. Instruction pointer: 5')
    (L $t.AddMinutes(2).AddSeconds(5) 'Unable to find a suitable disk. There are no fixed disks on this computer.' 'OSDDiskPart' 3)
    (L $t.AddMinutes(2).AddSeconds(6) ("Failed to run the action: Partition Disk 0 - UEFI. `r`nThe parameter is incorrect. (Error: 80070057; Source: Windows)") 'TSManager' 3)
)
New-Bundle 'PC1004_20261108.zip' @{ 'smsts.log' = $smsts } $now.AddHours(-30)

# ---- PC1005: hash mismatch, 50 h ago --------------------------------------------------------------
$t = $now.AddHours(-51)
$smsts = @(
    (L $t '==============================[ TSBootShell.exe ]==============================' 'TSBootShell')
    (L $t.AddMinutes(4) 'Start executing an instruction. Instruction name: Apply Operating System. Instruction pointer: 9')
    (L $t.AddMinutes(9) 'Hash could not be matched for the downloaded content. Original ContentHash = AB12, Downloaded ContentHash = CD34' 'ApplyOperatingSystem' 3)
    (L $t.AddMinutes(9) ("Failed to run the action: Apply Operating System. `r`nThe hash value is not correct. (Error: 80091007; Source: Windows)") 'TSManager' 3)
)
New-Bundle 'PC1005.zip' @{ 'smsts.log' = $smsts } $now.AddHours(-50)

# ---- PC1006: no smsts.log, unattend error in setupact ----------------------------------------------
$setupact = @(
    ('{0}, Error                 [setup.exe] Windows could not parse or process the unattend answer file for pass [specialize].' -f $now.AddHours(-2).ToString('yyyy-MM-dd HH:mm:ss'))
)
New-Bundle 'PC1006.zip' @{ 'Panther/setupact.log' = $setupact } $now.AddHours(-2)

# ---- Corrupt / empty --------------------------------------------------------------------------------
[IO.File]::WriteAllBytes((Join-Path $FixtureDirectory 'PC1007.zip'), [byte[]](1..200))
(Get-Item (Join-Path $FixtureDirectory 'PC1007.zip')).LastWriteTime = $now.AddHours(-1)
New-Bundle 'PC1011.zip' @{ 'readme.bin' = [byte[]](0, 1, 2) } $now.AddHours(-1)

# ---- PC1008: two runs, rollover + duplicate copies, last run fails on updates ---------------------
$r1 = $now.AddHours(-9)
$r2 = $now.AddHours(-6)
$rolled = @(
    (L $r1 '==============================[ TSBootShell.exe ]==============================' 'TSBootShell')
    (L $r1.AddMinutes(10) ("Failed to run the action: Apply Operating System. `r`nThe system cannot find the file specified. (Error: 80070002; Source: Windows)") 'TSManager' 3)
    (L $r1.AddMinutes(10) 'Execution of task sequence failed.' 'TSManager' 3)
    (L $r2 '==============================[ TSBootShell.exe ]==============================' 'TSBootShell')
    (L $r2.AddMinutes(1) '==============================[ TSManager.exe ]==============================')
)
$current = @(
    (L $r2.AddMinutes(1) '==============================[ TSManager.exe ]==============================')
    (L $r2.AddMinutes(30) '==============================[ TSManager.exe ]==============================' 'TSManager' 1 '-600')
    (L $r2.AddMinutes(62) 'Start executing an instruction. Instruction name: Install Software Updates. Instruction pointer: 40' 'TSManager' 1 '-600')
    (L $r2.AddMinutes(95) 'Failed to install updates. Error = 0x80240022' 'InstallSWUpdate' 3 '-600')
    (L $r2.AddMinutes(95) ("Failed to run the action: Install Software Updates. `r`nUnspecified error (Error: 80004005; Source: Windows)") 'TSManager' 3 '-600')
)
New-Bundle 'PC1008_20261109.zip' @{
    'Logs/smsts-20261109-020000.log' = $rolled
    'Logs/smsts.log' = $current
    'Copy2/smsts.log' = $current
} $now.AddHours(-4)

# ---- PC1009: nested zip, legacy-format line ----------------------------------------------------------
$t = $now.AddHours(-7)
$inner = New-ZipBytes @{
    'smsts.log' = @(
        (L $t '==============================[ TSBootShell.exe ]==============================' 'TSBootShell')
        (L $t.AddMinutes(1) 'Start executing an instruction. Instruction name: Use Toolkit Package. Instruction pointer: 2')
        (L $t.AddMinutes(1) 'There are no active network adapters in this computer' 'TSBootShell' 3)
        (L $t.AddMinutes(2) ("Failed to run the action: Use Toolkit Package. `r`nThe network path was not found. (Error: 80070035; Source: Windows)") 'TSManager' 3)
    )
}
$legacy = @('Starting legacy component  $$<LegacyComp><{0}+480><thread=1 (0x1)>' -f $t.ToString('MM-dd-yyyy HH:mm:ss.fff'))
New-Bundle 'PC1009.zip' @{ 'inner/X_logs.zip' = $inner; 'legacy.log' = $legacy } $now.AddHours(-7)

# ---- PC1010: rolled over (no banner), PKI/clock failure on policy ------------------------------------
$t = $now.AddHours(-10)
$smsts = @(
    (L $t 'Getting policy for CCM_SoftwareDistribution' 'TSPxe')
    (L $t.AddMinutes(1) 'Failed to get client identity (80072f8f)' 'TSPxe' 3)
    (L $t.AddMinutes(1).AddSeconds(2) 'Failed to download the task sequence policy (0x80072f8f)' 'TSPxe' 3)
)
New-Bundle 'PC1010.zip' @{ 'smsts.log' = $smsts } $now.AddHours(-10)

# ---- APTEST0001: modelled on a real bundle. Install Application fails because app policy never
# evaluates; NetSetup is full of SUCCESSFUL 0x0 join lines; reference-image MSI logs are baked in;
# the failure line uses the signed-decimal form; file named HOST.yyyy-MM-dd_HHmmss.zip ------------
$t0 = $now.AddHours(-2)
$ia = 'InstallApplication'
$app = 'Example Agent - 11.0 - R1'
$smsts = @(
    (L $t0 '==============================[ TSBootShell.exe ]==============================' 'TSBootShell')
    (L $t0.AddMinutes(2) '==============================[ TSManager.exe ]==============================')
    (L $t0.AddMinutes(60) '==============================[ TSManager.exe ]==============================' 'TSManager' 1 '-660')
    (L $t0.AddMinutes(61) 'Task Sequence environment is not initialized' 'TSManager' 3 '-660')
    (L $t0.AddMinutes(89) 'unknown host (gethostbyname failed)' 'TSManager' 3 '-660')
    (L $t0.AddMinutes(89) 'Sending with winhttp failed; 80072ee7' 'TSManager' 3 '-660')
    (L $t0.AddMinutes(92) 'Start executing an instruction. Instruction name: Install - Agents - Asset Management. Instruction pointer: 145' 'TSManager' 1 '-660')
    (L $t0.AddMinutes(92) "Installing application '$app'" $ia 1 '-660')
)
1..8 | ForEach-Object { $smsts += (L $t0.AddMinutes(92) 'CCMGetGlobalService(&spService), HRESULT=87d00219 (F:\dbs\sh\cmgm\src\Framework\Core\CCMCore\CcmConditions.cpp,162)' $ia 1 '-660') }
$smsts += @(
    (L $t0.AddMinutes(92) 'CAppMgmtSDK::GetEvaluationState - ScopeId_1/RequiredApplication_55b9.3 Not found in CI state store. Marking CIs state as EvaluationFailed' 'DCMAgent' 1 '-660')
    (L $t0.AddMinutes(92) 'NotifyProgress received: 16 (Application failed to evaluate )' $ia 1 '-660')
    (L $t0.AddMinutes(97) 'Waiting for job status notification...' $ia 1 '-660')
    (L $t0.AddMinutes(97) 'Retrying: 1 attempt' $ia 1 '-660')
    (L $t0.AddMinutes(102) 'Waiting for job status notification...' $ia 1 '-660')
    (L $t0.AddMinutes(102) 'Retrying: 2 attempt' $ia 1 '-660')
    (L $t0.AddMinutes(107) 'Waiting for job status notification...' $ia 1 '-660')
    (L $t0.AddMinutes(107) 'Retrying: 3 attempt' $ia 1 '-660')
    (L $t0.AddMinutes(107) 'nRetryVal != 0, HRESULT=80004005 (installapplication.cpp,1492)' $ia 3 '-660')
    (L $t0.AddMinutes(107) 'Exhausted retry attempts. Giving up. ' $ia 3 '-660')
    (L $t0.AddMinutes(107) "Install Dynamic application action failed to install application: '$app'. Error Code 0x80004005" $ia 3 '-660')
    (L $t0.AddMinutes(107) 'Install Dynamic application action cannot continue. ContinueOnErrorFlag is set to false.' $ia 3 '-660')
    (L $t0.AddMinutes(107).AddSeconds(1) ("Failed to run the action: Install - Agents - Asset Management. `r`nError -2147467259") 'TSManager' 3 '-660')
)
$ns = { param($at, $m) '{0} {1}' -f $at.ToString('MM/dd/yyyy HH:mm:ss:fff'), $m }
$netsetup = @(
    (& $ns $t0.AddMinutes(37) 'NetpDoDomainJoin')
    (& $ns $t0.AddMinutes(37) "NetpJoinDomain`r`n`tHostName: APTEST0001")
    (& $ns $t0.AddMinutes(37) "`tDomain: corp.example.local")
    (& $ns $t0.AddMinutes(37) "`tMachineAccountOU: OU=Thick,OU=End Points,DC=corp,DC=example,DC=local")
    (& $ns $t0.AddMinutes(37) "NetpJoinDomainOnDs: status of connecting to dc '\\DC01.corp.example.local': 0x0")
    (& $ns $t0.AddMinutes(37) 'NetpJoinDomainOnDs: status of setting netlogon cache: 0x0')
    (& $ns $t0.AddMinutes(37) "NetpJoinDomainOnDs: status of disconnecting from '\\DC01.corp.example.local': 0x0")
    (& $ns $t0.AddMinutes(37) 'NetpDoDomainJoin: status: 0x0')
)
$refImage = $now.AddDays(-49)
$msiOld = @('MSI (s) (30:F8) [16:05:36:673]: SOFTWARE RESTRICTION POLICY: C:\Windows\ccmcache\b\Objective Reporting.msi is not digitally signed')
$ciDownloader = @((L $t0.AddMinutes(80) 'Failed to download CI ScopeId_1/RequiredApplication_55b9 (0x87d00215)' 'CIDownloader' 3 '-660'))
New-Bundle 'APTEST0001.2026-11-09_034325.zip' @{
    'smsts.log' = $smsts
    'netsetup.log' = $netsetup
    'Objective_Reporting_11.log' = $msiOld
    'CIDownloader.log' = $ciDownloader
} $now.AddMinutes(-10) -Written @{ 'Objective_Reporting_11.log' = $refImage; 'smsts.log' = $t0.AddMinutes(108); 'netsetup.log' = $t0.AddMinutes(37); 'CIDownloader.log' = $t0.AddMinutes(80) }

# ---- BITSTEST0001: modelled on five real bundles. First Install Application step after a restart:
# BITS parks the app's CI download with 0x80200010 (no active network connection), so app policy
# evaluation fails. Current-build instruction format; DNS errors right after the restart are
# normal; CIAgent/CIDownloader housekeeping errors; the error routine's log-copy step also fails --
$r0 = $now.AddHours(-34)
$tsl = { param($at, $m, $type = 1, $comp = 'TSManager') L $at $m $comp $type '-660' }
$ins = { param($at, $name, $type) & $tsl $at "Start executing an instruction. Instruction name: '$name'.  Pointer: 290. Type: '$type'. Disabled: 0" }
$bitsError = "DTSJob({53D3B2A4-457F-40A3-A35C-27D60428B78E}):CDTSJob::HandleErrors - BITS Job '{DC2D5B9F-C0D8-4A15-914E-CF871C75CE2A}' under user 'S-1-5-18', ErrorCount=0, ErrorCode=0x80200010, ErrorText='BITS error: 'There are currently no active network connections. Background Intelligent Transfer Service (BITS) will try again when an adapter is connected.''"
$smsts = @(
    (L $r0.AddMinutes(-60) '==============================[ TSBootShell.exe ]==============================' 'TSBootShell')
    (& $ins $r0 'Restart - System - Windows Full Operating System' 'SMS_TaskSequence_RebootAction')
    (& $tsl $r0.AddSeconds(5) 'Rebooting the computer')
    (& $tsl $r0.AddSeconds(50) '==============================[ TSManager.exe ]==============================')
    (& $tsl $r0.AddSeconds(55) 'CLibSMSMessageWinHttpTransport::Send: WinHttpOpenRequest - URL: MP01.corp.example.local:80  CCM_POST /ccm_system/request')
    (& $tsl $r0.AddSeconds(55) 'Error. Received 0x80072ee7 from WinHttpSendRequest.')
    (& $tsl $r0.AddSeconds(55) 'unknown host (gethostbyname failed)' 3)
    (& $tsl $r0.AddSeconds(55) 'Sending with winhttp failed; 80072ee7' 3)
    (& $ins $r0.AddSeconds(80) 'Configure - Start BITS Service and Logging' 'SMS_TaskSequence_RunPowerShellScriptAction')
    (& $ins $r0.AddSeconds(90) 'Install - Applications - Desktop' 'SMS_TaskSequence_InstallApplicationAction')
    (& $tsl $r0.AddSeconds(92) "Installing application 'Example Maintenance Tool 2.4'" 1 'InstallApplication')
    (& $tsl $r0.AddSeconds(93) 'CAppMgmtSDK::GetEvaluationState - ScopeId_1/RequiredApplication_81d5.3 Not found in CI state store. Marking CIs state as EvaluationFailed' 1 'DCMAgent')
    (& $tsl $r0.AddSeconds(93) 'NotifyProgress received: 16 (Application failed to evaluate )' 1 'InstallApplication')
    (& $tsl $r0.AddSeconds(393) 'Retrying: 1 attempt' 1 'InstallApplication')
    (& $tsl $r0.AddSeconds(693) 'Retrying: 2 attempt' 1 'InstallApplication')
    (& $tsl $r0.AddSeconds(993) 'Retrying: 3 attempt' 1 'InstallApplication')
    (& $tsl $r0.AddSeconds(993) 'Exhausted retry attempts. Giving up. ' 3 'InstallApplication')
    (& $tsl $r0.AddSeconds(993) "Install Dynamic application action failed to install application: 'Example Maintenance Tool 2.4'. Error Code 0x80004005" 3 'InstallApplication')
    (& $tsl $r0.AddSeconds(994) ("Failed to run the action: Install - Applications - Desktop. `r`nError -2147467259") 3)
    (& $ins $r0.AddSeconds(995) 'Error Routine' '')
    (& $ins $r0.AddSeconds(996) 'Copy - Archive Logs to Network' 'SMS_TaskSequence_RunPowerShellScriptAction')
    (& $tsl $r0.AddSeconds(998) ("Failed to run the action: Copy - Archive Logs to Network. `r`nError -2147024894") 3)
)
$dts = @(
    (& $tsl $r0.AddSeconds(94) "DataTransferService: DTSJob({53D3B2A4-457F-40A3-A35C-27D60428B78E}) - Processing DTS job for user 'S-1-5-18'." 1 'DataTransferService')
    (& $tsl $r0.AddSeconds(94) 'Added (source=.sms_dcm?Id&DocumentId=ScopeId_1/RequiredApplication_81d5/3/MANIFEST)' 1 'DataTransferService')
    (& $tsl $r0.AddSeconds(94) "DataTransferService: DTSJob({53D3B2A4-457F-40A3-A35C-27D60428B78E}): state changing from 'PendingDownload' to state 'DownloadingData'." 1 'DataTransferService')
    (& $tsl $r0.AddSeconds(94) $bitsError 0 'DataTransferService')
)
$ciAgent = @((& $tsl $r0.AddSeconds(85) 'GetLoggedOnUserToken returning failure with Win32 error code=1008' 3 'CIAgent'))
$ciDl = @((& $tsl $r0.AddSeconds(86) 'DeleteInstanceFromLantern failed (0x80041002).' 3 'CIDownloader'))
New-Bundle 'BITSTEST0001.2026-11-10_001748.zip' @{
    'smsts.log' = $smsts; 'DataTransferService.log' = $dts; 'CIAgent.log' = $ciAgent; 'CIDownloader.log' = $ciDl
} $now.AddHours(-30)

# =====================================================================================================
Write-Host "`n=== Get-OsdFailureReport.ps1 against $FixtureDirectory ===" -ForegroundColor Cyan
$all = @(& $scriptPath -Path $FixtureDirectory 6>$null)
$by = @{}
foreach ($r in $all) { $by[$r.BundleName] = $r }

Assert-That 'one result per bundle (13)' ($all.Count -eq 13) "got $($all.Count)"

$r = $by['PC1001_20261109-0821.zip']
Assert-That 'PC1001 hostname from ZTIGather' ($r.Hostname -eq 'PC1001' -and $r.HostnameSource -like 'ZTIGather*') "$($r.Hostname) / $($r.HostnameSource)"
Assert-That 'PC1001 failed step joined across a multi-line entry' ($r.FailedStep -eq 'Apply Driver Package - Latitude 7450') $r.FailedStep
Assert-That 'PC1001 error code normalised' ($r.ErrorCode -eq '0x80070002') $r.ErrorCode
Assert-That 'PC1001 root cause is content not on DP' ($r.RootCause -eq 'Content not available on a distribution point') $r.RootCause
Assert-That 'PC1001 package ID surfaced' ($r.RootCauseDetail -match 'P0100123') $r.RootCauseDetail
Assert-That 'PC1001 failed group from the abort line' ($r.FailedGroup -eq 'Drivers') $r.FailedGroup
Assert-That 'PC1001 duration 00:21:02' ($r.Duration -eq '00:21:02') $r.Duration
Assert-That 'PC1001 model and serial from gather' ($r.Model -eq 'Latitude 7450' -and $r.SerialNumber -eq '7XK2Q34') "$($r.Model) $($r.SerialNumber)"
Assert-That 'PC1001 start marker found' ($r.StartConfidence -eq 'Start marker found') $r.StartConfidence

$r = $by['PC1002.zip']
Assert-That 'PC1002 hostname from unattend/NetSetup, not the file' ($r.Hostname -eq 'PC1002' -and $r.HostnameSource -ne 'Bundle file name') $r.HostnameSource
Assert-That 'PC1002 WinPE and OS smsts copies merged: duration 00:52:00' ($r.Duration -eq '00:52:00') $r.Duration
Assert-That 'PC1002 bias change noted' (@($r.Notes | Where-Object { $_ -like '*bias changed*' }).Count -eq 1) ($r.Notes -join ' | ')
Assert-That 'PC1002 domain join found in UTF-16 setupact and NetSetup' (@($r.KnownIssues | Where-Object { $_ -like 'Domain join failed*' }).Count -eq 1) ($r.KnownIssues -join ' | ')
Assert-That 'PC1002 domain join evidence decodes 0xaac' (@($r.Evidence | Where-Object { $_.Kind -eq 'DOMAIN_JOIN' }).Count -ge 1) ''
$dj = & $scriptPath -Path (Join-Path $FixtureDirectory 'PC1002.zip') -IgnoreStepPattern 'Install Application' 6>$null
Assert-That 'PC1002 domain join is the cause when the app step is excluded' ($dj.RootCause -eq 'Domain join failed' -and $dj.RootCauseDetail -match 'blocked by security policy' -and $dj.RootCauseDetail -match 'MachineAccountOU=OU=Win11') $dj.RootCauseDetail
$json = $all | ConvertTo-Json -Depth 6
Assert-That 'unattend.xml password never reported' ($json -notmatch 'Sup3rS3cret') ''

$r = $by['PC1003_20261109-0905.zip']
Assert-That 'PC1003 real failure reported, not the forced failure' ($r.FailedStep -eq 'Install Application - 7-Zip') $r.FailedStep
Assert-That 'PC1003 forced failure listed as ignored' (@($r.OtherFailures | Where-Object { $_ -like 'Force Failure*ignored*' }).Count -eq 1) ($r.OtherFailures -join ' | ')
Assert-That 'PC1003 root cause is the app exit code' ($r.RootCause -eq 'Application installer returned a failure exit code') $r.RootCause
Assert-That 'PC1003 application name and 1603 decoded' ($r.RootCauseDetail -match '7-Zip 24.08' -and $r.RootCauseDetail -match '1603') $r.RootCauseDetail

$r = $by['PC1004_20261108.zip']
Assert-That 'PC1004 MININT ignored, hostname from file name' ($r.Hostname -eq 'PC1004' -and $r.HostnameSource -eq 'Bundle file name') "$($r.Hostname) / $($r.HostnameSource)"
Assert-That 'PC1004 root cause is no disk' ($r.RootCause -eq 'No disk found') $r.RootCause

$r = $by['PC1005.zip']
Assert-That 'PC1005 hash mismatch' ($r.RootCause -eq 'Content hash mismatch' -and $r.ErrorCode -eq '0x80091007') "$($r.RootCause) $($r.ErrorCode)"

$r = $by['PC1006.zip']
Assert-That 'PC1006 no smsts.log status' ($r.Status -eq 'NoTaskSequenceLog') $r.Status
Assert-That 'PC1006 unattend cause found without smsts.log' ($r.RootCause -like 'Unattend*') $r.RootCause

Assert-That 'PC1007 corrupt bundle reported, not fatal' ($by['PC1007.zip'].Status -eq 'Unreadable') $by['PC1007.zip'].Status
Assert-That 'PC1011 bundle without logs is Empty' ($by['PC1011.zip'].Status -eq 'Empty') $by['PC1011.zip'].Status

$r = $by['PC1008_20261109.zip']
Assert-That 'PC1008 last run only: failed step' ($r.FailedStep -eq 'Install Software Updates') $r.FailedStep
Assert-That 'PC1008 last run only: duration 01:35:00' ($r.Duration -eq '01:35:00') $r.Duration
Assert-That 'PC1008 earlier run noted' (@($r.Notes | Where-Object { $_ -like '*more than one task sequence run*' }).Count -eq 1) ($r.Notes -join ' | ')
Assert-That 'PC1008 earlier run failure not listed as other failure' (@($r.OtherFailures).Count -eq 0) ($r.OtherFailures -join ' | ')
Assert-That 'PC1008 updates root cause' ($r.RootCause -eq 'Install Software Updates failed') $r.RootCause

$r = $by['PC1009.zip']
Assert-That 'PC1009 nested zip read' ($r.FailedStep -eq 'Use Toolkit Package' -and $r.RootCause -eq 'No network adapter in WinPE') "$($r.FailedStep) / $($r.RootCause)"
Assert-That 'PC1009 legacy-format log parsed' (@($r.LogsReviewed | Where-Object { $_ -like 'legacy.log (1 lines*' }).Count -eq 1) ($r.LogsReviewed -join ' | ')

$r = $by['PC1010.zip']
Assert-That 'PC1010 no banner -> earliest entry, flagged' ($r.StartConfidence -like 'Earliest surviving*') $r.StartConfidence
Assert-That 'PC1010 certificate/clock cause' ($r.RootCause -eq 'Certificate or device clock problem') $r.RootCause

$r = $by['APTEST0001.2026-11-09_034325.zip']
Assert-That 'APTEST hostname split at the dot in HOST.yyyy-MM-dd_HHmmss.zip' ($r.Hostname -eq 'APTEST0001' -and @($r.Notes | Where-Object { $_ -like 'Bundle file name suggests*' }).Count -eq 0) "$($r.Hostname) | $($r.Notes -join ' | ')"
Assert-That 'APTEST failed step from the signed-decimal failure line' ($r.FailedStep -eq 'Install - Agents - Asset Management' -and $r.ErrorCode -eq '0x80004005') "$($r.FailedStep) / $($r.ErrorCode)"
Assert-That 'APTEST root cause comes from the failing step in smsts.log' ($r.RootCause -eq 'Application policy evaluation failed (Install Application)') $r.RootCause
Assert-That 'APTEST application named' ($r.Application -eq 'Example Agent - 11.0 - R1' -and $r.Summary -match 'Example Agent') "$($r.Application) | $($r.Summary)"
Assert-That 'APTEST failure message filled from the step block' ($r.FailureMessage -match 'failed to install application') $r.FailureMessage
Assert-That 'APTEST successful 0x0 NetSetup lines are not a domain join failure' (@($r.KnownIssues | Where-Object { $_ -like 'Domain join*' }).Count -eq 0) ($r.KnownIssues -join ' | ')
Assert-That 'APTEST informational MSI "not digitally signed" is not a script failure' (@($r.KnownIssues | Where-Object { $_ -like '*script*' }).Count -eq 0) ($r.KnownIssues -join ' | ')
Assert-That 'APTEST DNS failure before the step is a contributing factor' (@($r.ContributingFactors | Where-Object { $_ -like 'DNS resolution failure*' }).Count -eq 1) ($r.ContributingFactors -join ' | ')
Assert-That 'APTEST step log shows the retries and give-up' (@($r.StepLog | Where-Object { $_ -match 'Exhausted retry attempts' }).Count -eq 1 -and @($r.StepLog | Where-Object { $_ -match 'Retrying: 3 attempt' }).Count -eq 1) ($r.StepLog -join ' | ')
Assert-That 'APTEST benign CCMGetGlobalService and TS-env noise kept out' (@($r.StepLog | Where-Object { $_ -match 'CCMGetGlobalService' }).Count -eq 0 -and @($r.Evidence | Where-Object { $_.Text -match 'environment is not initialized' }).Count -eq 0) ''
Assert-That 'APTEST "ContinueOnErrorFlag is set to false" does not mark the failure as continued' (@($r.OtherFailures).Count -eq 0) ($r.OtherFailures -join ' | ')

$r = $by['BITSTEST0001.2026-11-10_001748.zip']
Assert-That 'BITS root cause: BITS network disconnected found during the failing step' ($r.RootCause -eq 'BITS reported no active network connection - download stalled') $r.RootCause
Assert-That 'BITS symptom: the step-level app policy evaluation failure' ($r.Symptom -eq 'Application policy evaluation failed (Install Application)') $r.Symptom
Assert-That 'BITS current-build instruction format: step and type parsed' ($r.FailedStep -eq 'Install - Applications - Desktop' -and $r.StepType -eq 'InstallApplicationAction') "$($r.FailedStep) [$($r.StepType)]"
Assert-That 'BITS detail says how soon after a restart the step ran' ($r.RootCauseDetail -match '90 seconds after the task sequence restarted') $r.RootCauseDetail
Assert-That 'BITS error-routine log copy failure is passed over' ($r.FailedStep -notmatch 'Archive' -and @($r.OtherFailures | Where-Object { $_ -like 'Copy - Archive Logs*ignored*' }).Count -eq 1) ($r.OtherFailures -join ' | ')
Assert-That 'BITS DNS errors just after the restart are not contributing' (@($r.ContributingFactors | Where-Object { $_ -like 'DNS*' }).Count -eq 0) ($r.ContributingFactors -join ' | ')
Assert-That 'BITS DNS errors just after the restart are labelled normal' (@($r.KnownIssues | Where-Object { $_ -like 'DNS resolution failure*just after a restart*' }).Count -eq 1) ($r.KnownIssues -join ' | ')
Assert-That 'BITS CIAgent 1008 and Lantern 0x80041002 housekeeping is ignored' (@($r.KnownIssues | Where-Object { $_ -like 'Configuration item*' }).Count -eq 0) ($r.KnownIssues -join ' | ')
Assert-That 'BITS summary names symptom and cause' ($r.Summary -match 'application policy evaluation failed' -and $r.Summary -match 'likely cause: BITS reported no active network connection') $r.Summary

# ---- Filters ------------------------------------------------------------------------------------------
$h24 = @(& $scriptPath -Path $FixtureDirectory -LastHours 24 6>$null)
Assert-That '-LastHours 24 excludes the 30 h and 50 h bundles' ($h24.Count -eq 10 -and -not ($h24.BundleName -contains 'PC1004_20261108.zip')) "got $($h24.Count)"
$h48 = @(& $scriptPath -Path $FixtureDirectory -LastHours 48 6>$null)
Assert-That '-LastHours 48 includes the 30 h bundles only' ($h48.Count -eq 12) "got $($h48.Count)"
$since = @(& $scriptPath -Path $FixtureDirectory -Since $now.AddHours(-2.5) 6>$null)
Assert-That '-Since' ($since.Count -eq 5) "got $($since.Count): $($since.BundleName -join ', ')"
$one = @(& $scriptPath -Path $FixtureDirectory -ComputerName PC1003 6>$null)
Assert-That '-ComputerName by file name' ($one.Count -eq 1 -and $one[0].Hostname -eq 'PC1003') "got $($one.Count)"
$err = $null
try { & $scriptPath -Path $FixtureDirectory -LastHours 12 -Since $now 6>$null | Out-Null } catch { $err = $_ }
Assert-That '-LastHours and -Since cannot be combined' ($null -ne $err) ''

# ---- Reports ------------------------------------------------------------------------------------------
$out = Join-Path $FixtureDirectory 'out'
& $scriptPath -Path $FixtureDirectory -OutputPath $out 6>$null | Out-Null
$files = @(Get-ChildItem $out -File)
Assert-That '-OutputPath writes csv, evidence csv, json and html' ($files.Count -eq 4) ($files.Name -join ', ')
$html = Get-Content (Get-ChildItem $out -Filter *.html).FullName -Raw
$missing = @(@('PC1001', 'PC1002', 'PC1003', 'PC1009') | Where-Object { $html -notmatch $_ })
Assert-That 'html report lists every device' ($missing.Count -eq 0) ($missing -join ', ')
Assert-That 'html report never contains the unattend password' ($html -notmatch 'Sup3rS3cret') ''
$csv = @(Import-Csv (Get-ChildItem $out -Filter *-summary.csv).FullName)
Assert-That 'summary csv has a row per bundle' ($csv.Count -eq 13) "got $($csv.Count)"

# ---- Read-only ---------------------------------------------------------------------------------------
$before = @(Get-ChildItem $FixtureDirectory -File | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks })
& $scriptPath -Path $FixtureDirectory 6>$null | Out-Null
$after = @(Get-ChildItem $FixtureDirectory -File | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks })
Assert-That 'bundles are untouched (name, size, timestamp)' ($null -eq (Compare-Object $before $after)) ''

if (-not $keep) { Remove-Item $FixtureDirectory -Recurse -Force }

Write-Host "`n--- $script:pass passed, $script:fail failed ---" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
