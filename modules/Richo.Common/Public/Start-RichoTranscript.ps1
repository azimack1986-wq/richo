function Start-RichoTranscript {
    <#
    .SYNOPSIS
        Starts a PowerShell transcript in logs/ and returns the file path.

    .DESCRIPTION
        Change work usually needs an artifact showing exactly what ran and what
        came back. This starts a transcript named for the calling script and the
        UTC start time, and sets $env:RICHO_LOG_FILE so Write-RichoLog appends to
        a matching .log file alongside it.

        Remember to call Stop-Transcript in a finally block.

    .PARAMETER Name
        Base name for the transcript. Defaults to the calling script's file name.

    .PARAMETER Directory
        Where to write. Defaults to a logs/ folder at the repo root.

    .EXAMPLE
        $transcript = Start-RichoTranscript
        try   { ... }
        finally { Stop-Transcript }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [string]$Directory
    )

    if (-not $Name) {
        $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1).ScriptName
        $Name = if ($caller) { [IO.Path]::GetFileNameWithoutExtension($caller) } else { 'richo' }
    }

    if (-not $Directory) {
        $repoRoot = Split-Path $PSScriptRoot -Parent | Split-Path -Parent | Split-Path -Parent
        $Directory = Join-Path $repoRoot 'logs'
    }

    if (-not (Test-Path $Directory)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $base = Join-Path $Directory "$Name-$stamp"

    $env:RICHO_LOG_FILE = "$base.log"
    Start-Transcript -Path "$base.transcript" -Force | Out-Null

    Write-RichoLog "Transcript started: $base.transcript" -Level INFO
    "$base.transcript"
}
