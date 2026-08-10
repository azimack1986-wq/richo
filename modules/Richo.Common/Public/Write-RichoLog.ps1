function Write-RichoLog {
    <#
    .SYNOPSIS
        Writes a timestamped, levelled log line to the host and optionally to a file.

    .DESCRIPTION
        Every script in this repo logs through this function so output is consistent
        and greppable. Lines are formatted as:

            2026-08-10 14:32:07Z [INFO ] Connecting to vcenter01.example.com

        INFO and DEBUG go to the information/verbose streams, WARN to the warning
        stream, and ERROR to the error stream, so redirection and -ErrorAction still
        behave the way callers expect.

    .PARAMETER Message
        The text to log.

    .PARAMETER Level
        Severity: DEBUG, INFO, WARN, or ERROR. Defaults to INFO.

    .PARAMETER Path
        Optional log file to append to. Defaults to $env:RICHO_LOG_FILE when set.

    .EXAMPLE
        Write-RichoLog "Server profile deployed" -Level INFO

    .EXAMPLE
        Write-RichoLog "vCenter unreachable" -Level ERROR -Path .\logs\run.log
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [string]$Path = $env:RICHO_LOG_FILE
    )

    process {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
        $line = '{0} [{1,-5}] {2}' -f $stamp, $Level, $Message

        switch ($Level) {
            'DEBUG' { Write-Verbose $line }
            'INFO'  { Write-Information $line -InformationAction Continue }
            'WARN'  { Write-Warning $line }
            'ERROR' { Write-Error $line }
        }

        if ($Path) {
            $dir = Split-Path -Path $Path -Parent
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            Add-Content -Path $Path -Value $line -Encoding UTF8
        }
    }
}
