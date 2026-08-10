#Requires -Modules Pester

<#
    Smoke tests for the shared module. Run with:

        Invoke-Pester -Path .\tests

    These deliberately touch no infrastructure -- they check that the module
    loads, exports what the manifest promises, and that config lookup fails
    with useful messages.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ModulePath = Join-Path $RepoRoot 'modules/Richo.Common/Richo.Common.psd1'
    Import-Module $ModulePath -Force
}

AfterAll {
    Remove-Module Richo.Common -Force -ErrorAction SilentlyContinue
}

Describe 'Richo.Common module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $ModulePath } | Should -Not -Throw
    }

    It 'exports every function named in the manifest' {
        $manifest = Import-PowerShellDataFile -Path $ModulePath
        $exported = (Get-Command -Module Richo.Common).Name

        foreach ($name in $manifest.FunctionsToExport) {
            $exported | Should -Contain $name
        }
    }
}

Describe 'Write-RichoLog' {
    It 'writes a timestamped line to the given file' {
        $logFile = Join-Path $TestDrive 'test.log'
        Write-RichoLog -Message 'hello' -Level INFO -Path $logFile 6>$null

        $content = Get-Content -Path $logFile -Raw
        $content | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z \[INFO \] hello'
    }

    It 'rejects an unknown level' {
        { Write-RichoLog -Message 'x' -Level 'CRITICAL' } | Should -Throw
    }
}

Describe 'Get-RichoConfig' {
    It 'throws a helpful error when the config file is missing' {
        { Get-RichoConfig -Path (Join-Path $TestDrive 'nope.json') } |
            Should -Throw '*Config file not found*'
    }

    It 'reads the example config and resolves the default environment' {
        $example = Join-Path $RepoRoot 'config/environments.example.json'
        $result = Get-RichoConfig -Path $example

        $result.Name | Should -Be 'lab'
        $result.vcenter.server | Should -Not -BeNullOrEmpty
    }

    It 'throws and lists known environments for an unknown name' {
        $example = Join-Path $RepoRoot 'config/environments.example.json'
        { Get-RichoConfig -Name 'nowhere' -Path $example } | Should -Throw '*Known environments*'
    }
}

Describe 'Assert-RichoModule' {
    It 'throws with an install hint for a module that is not present' {
        { Assert-RichoModule -Name 'Definitely.Not.Installed.Module' } |
            Should -Throw '*Install-Module*'
    }

    It 'rejects -MinimumVersion with multiple module names' {
        { Assert-RichoModule -Name 'A', 'B' -MinimumVersion '1.0' } |
            Should -Throw '*single module*'
    }
}
