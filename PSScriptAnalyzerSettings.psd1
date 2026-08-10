@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Write-Host is never used here; output goes through Write-RichoLog.
        # Vendor modules (PowerCLI, Intersight) expose plural nouns we cannot rename.
        'PSUseSingularNouns'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSUseConsistentIndentation = @{
            Enable          = $true
            Kind            = 'space'
            IndentationSize = 4
        }
        PSUseConsistentWhitespace = @{
            Enable         = $true
            CheckOpenBrace = $true
            CheckOperator  = $true
            CheckSeparator = $true
        }
        PSAvoidUsingCmdletAliases = @{
            Enable = $true
        }
    }
}
