#Requires -Version 7.0
# Runs every package's checks: each module manifest must be valid, then every Pester test runs.
# Pester 5 or later is required: Install-PSResource Pester -Scope CurrentUser
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester 5 or later is required. Run: Install-PSResource Pester -Scope CurrentUser' }
Import-Module $pester -Force

foreach ($manifest in Get-ChildItem -Path (Join-Path $root 'packages') -Recurse -Filter '*.psd1') {
    $null = Test-ModuleManifest -Path $manifest.FullName -ErrorAction Stop
    Write-Host "manifest ok: $($manifest.FullName.Substring($root.Length + 1))"
}

$result = Invoke-Pester -Path (Join-Path $root 'packages') -PassThru -Output Minimal
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
