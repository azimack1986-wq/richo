#Requires -Version 5.1
Set-StrictMode -Version Latest

# Dot-source every function file, then export only what the manifest lists.
foreach ($scope in 'Private', 'Public') {
    $dir = Join-Path $PSScriptRoot $scope
    if (-not (Test-Path $dir)) { continue }

    Get-ChildItem -Path $dir -Filter '*.ps1' -File | ForEach-Object {
        try {
            . $_.FullName
        }
        catch {
            throw "Failed to load $($_.FullName): $_"
        }
    }
}
