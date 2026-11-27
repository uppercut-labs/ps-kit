@{
    RootModule            = 'ReleaseArtifact.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = '4e9b7c20-d1a3-4f68-b5e7-0c8a2d6f3b91'
    Author                = 'Uppercut Labs'
    CompanyName           = 'Uppercut Labs'
    Copyright             = '(c) 2026 Uppercut Labs. MIT License.'
    Description           = 'Builds a release archive from a staged folder: checks the Git tree is clean and names the commit, writes release.json and SHA256SUMS, zips with forward-slash entry names and a .sha256 sidecar, and smoke-tests the finished archive by unpacking it into an empty folder.'
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')
    FunctionsToExport     = @(
        'Get-ReleaseSourceIdentity'
        'New-ReleaseStage'
        'Write-ReleaseManifest'
        'Write-Sha256Sums'
        'Test-Sha256Sums'
        'New-ReleaseArchive'
        'Test-ReleaseArchive'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Release', 'Archive', 'SHA256', 'Checksum', 'Packaging', 'Windows', 'macOS', 'Linux')
            ProjectUri   = 'https://github.com/uppercut-labs/ps-kit/tree/main/packages/release-artifact'
            LicenseUri   = 'https://github.com/uppercut-labs/ps-kit/blob/main/LICENSE'
            ReleaseNotes = 'First public release.'
        }
    }
}
