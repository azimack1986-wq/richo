<#
.SYNOPSIS
    Generates the self-contained build of the UCS best practice audit.

.DESCRIPTION
    Test-UcsBestPractice.ps1 lives in the repo and imports Richo.Common for logging, credentials,
    module checks and transcripts. That is right for a repo checkout and useless on a jump host or
    a file share, where the script is copied on its own and the import fails before a single check
    has run.

    This produces the version for that case: one file, no imports, nothing beside it. It is
    GENERATED rather than maintained by hand, because two hand-maintained copies of a three
    thousand line audit diverge, and the copy that diverges is the one on the share that nobody
    looks at.

    Four things change between the repo script and the generated one:

      1. The Import-Module line is replaced by the public functions of Richo.Common, inlined
         verbatim from modules/Richo.Common/Public.
      2. Output goes to the directory the operator is IN rather than a repo-relative output/
         folder. A copy sitting on a read-only or shared location must not be where audit CSVs
         accumulate.
      3. The transcript follows the CSV to the same directory, for the same reason.
      4. The help text says which build it is and where the output lands.

    Nothing else is touched. Every check, threshold and reference is the repo script's.

    tests/Test-UcsBestPracticeStandalone.ps1 regenerates this in memory and compares it against the
    committed file, so the two cannot drift without the test suite saying so.

.PARAMETER OutputPath
    Where to write the generated script. Defaults to dist/Test-UcsBestPractice-Standalone.ps1 at
    the repo root.

.PARAMETER PassThru
    Return the generated text instead of writing it. Used by the sync test.

.EXAMPLE
    .\tools\Build-UcsBestPracticeStandalone.ps1

.EXAMPLE
    $text = .\tools\Build-UcsBestPracticeStandalone.ps1 -PassThru
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$OutputPath,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$sourcePath = Join-Path $repoRoot 'scripts/ucs/Test-UcsBestPractice.ps1'
$modulePublic = Join-Path $repoRoot 'modules/Richo.Common/Public'

if (-not (Test-Path $sourcePath)) { throw "Source script not found: $sourcePath" }

$text = [IO.File]::ReadAllText($sourcePath)

# The helpers the audit actually calls. Listed explicitly rather than globbed so that a new public
# function appearing in the module does not silently swell every generated build.
$helperNames = @('Write-RichoLog', 'Get-RichoCredential', 'Assert-RichoModule', 'Start-RichoTranscript')

$helperText = New-Object System.Collections.Generic.List[string]
$helperText.Add('# =============================================================================================')
$helperText.Add('# Richo.Common helpers, inlined')
$helperText.Add('#')
$helperText.Add('# In the repo these come from modules/Richo.Common and are imported. This build is meant to be')
$helperText.Add('# copied somewhere on its own - a jump host, a file share - where there is no module to import,')
$helperText.Add('# so they are carried here verbatim. Edit them in the module, not here: this file is generated')
$helperText.Add('# by tools/Build-UcsBestPracticeStandalone.ps1 and anything changed here is lost on the next')
$helperText.Add('# regeneration.')
$helperText.Add('# =============================================================================================')
$helperText.Add('')

foreach ($name in $helperNames) {
    $helperPath = Join-Path $modulePublic "$name.ps1"
    if (-not (Test-Path $helperPath)) { throw "Helper not found: $helperPath" }
    $helperText.Add(([IO.File]::ReadAllText($helperPath)).TrimEnd())
    $helperText.Add('')
}

$helperBlock = ($helperText -join "`n").TrimEnd()

# --- 1. Replace the module import with the inlined helpers ------------------------------------
$importLine = "Import-Module (Join-Path `$PSScriptRoot '..\..\modules\Richo.Common\Richo.Common.psd1') -Force"
if ($text -notlike "*$importLine*") { throw 'The Import-Module line was not found. The source script has changed shape; update this builder.' }
$text = $text.Replace($importLine, $helperBlock)

# --- 2. Output directory ------------------------------------------------------------------------
$outputAnchor = @'
        $repoRoot = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
        $outputDir = Join-Path $repoRoot 'output'
'@
if ($text -notlike "*$outputAnchor*") { throw 'The default output path block was not found. Update this builder.' }
$text = $text.Replace($outputAnchor, @'
        $outputDir = $script:BpOutputDirectory
'@)

# --- 3. Hoist the output directory, and point the transcript at it ------------------------------
$transcriptAnchor = '$transcriptPath = if ($Transcript) { Start-RichoTranscript } else { $null }'
if ($text -notlike "*$transcriptAnchor*") { throw 'The transcript line was not found. Update this builder.' }
$text = $text.Replace($transcriptAnchor, @'
# --- Where this build writes ------------------------------------------------------------------
# The CSV and the transcript go to the directory the operator is IN, not the one the script is in.
# This build exists to be copied somewhere - a jump host, a file share, a WSUS distribution point -
# and those are places output must not accumulate, and often places it cannot be written at all.
# If the current location is not a filesystem one (a registry or certificate drive), fall back to
# the user's Documents folder rather than failing at the very end of a long audit.
$script:BpOutputDirectory = if ($PWD.Provider.Name -eq 'FileSystem') { $PWD.ProviderPath } else { [Environment]::GetFolderPath('MyDocuments') }

$transcriptPath = if ($Transcript) { Start-RichoTranscript -Directory $script:BpOutputDirectory } else { $null }
'@)

# --- 4. Help text -------------------------------------------------------------------------------
$helpAnchor = '    CSV to write. Defaults to output/UcsBestPractice-<fabric>-<utc timestamp>.csv at the repo root.'
if ($text -notlike "*$helpAnchor*") { throw 'The OutputPath help text was not found. Update this builder.' }
$text = $text.Replace($helpAnchor, @'
    CSV to write. Defaults to UcsBestPractice-<fabric>-<utc timestamp>.csv in the directory you run
    the script FROM - not the directory the script itself sits in, which is often a read-only share.
'@.TrimEnd())

# The heading alone, not the block under it - so that editing the requirements in the source
# script does not silently stop the standalone banner being inserted.
$notesAnchor = '    REQUIREMENTS'
$anchorCount = ([regex]::Matches($text, [regex]::Escape($notesAnchor))).Count
if ($anchorCount -ne 1) { throw "Expected exactly one '$notesAnchor' heading in the source script, found $anchorCount. Update this builder." }
$text = $text.Replace($notesAnchor, @'
    THIS IS THE SELF-CONTAINED BUILD. One file, no module to install alongside it, nothing needed
    beside it. Copy it wherever is convenient and run it. It is generated from the repo copy by
    tools/Build-UcsBestPracticeStandalone.ps1, so make changes there - anything edited into this
    file is lost the next time it is regenerated.

    RUNNING IT FROM A FILE SHARE. Windows marks files copied from a network location as coming
    from another computer, and PowerShell refuses to run them. If it will not start:

        Unblock-File .\Test-UcsBestPractice-Standalone.ps1
        powershell.exe -ExecutionPolicy Bypass -File .\Test-UcsBestPractice-Standalone.ps1

    Better still, copy it to a local folder and run it from there - that is also where the CSV
    lands, since output follows the directory you are in rather than the one the script sits in.

    REQUIREMENTS
'@.TrimEnd() + "`n")

if ($PassThru) { return $text }

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot 'dist/Test-UcsBestPractice-Standalone.ps1'
}

$parent = Split-Path -Path $OutputPath -Parent
if ($parent -and -not (Test-Path $parent)) {
    if ($PSCmdlet.ShouldProcess($parent, 'Create output directory')) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($OutputPath, 'Write the self-contained build')) {
    # UTF8 without BOM, LF endings - .gitattributes decides what lands in a checkout.
    [IO.File]::WriteAllText($OutputPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    $lineCount = ($text -split "`n").Count
    Write-Information "Wrote $OutputPath ($lineCount lines)." -InformationAction Continue
}
