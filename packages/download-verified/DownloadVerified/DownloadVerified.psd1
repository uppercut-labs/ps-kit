@{
    RootModule            = 'DownloadVerified.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = 'c2a5e8b1-6f47-4d93-a0e2-8b13d7f5c649'
    Author                = 'Uppercut Labs'
    CompanyName           = 'Uppercut Labs'
    Copyright             = '(c) 2026 Uppercut Labs. MIT License.'
    Description           = 'Downloads a file only over HTTPS and only if its SHA-256 matches a pinned value, extracts a zip archive without letting an entry escape the destination, installs named files from it, and writes a receipt of what was installed.'
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')
    FunctionsToExport     = @(
        'Save-VerifiedDownload'
        'Expand-VerifiedArchive'
        'Install-VerifiedDownload'
        'Test-FileSha256'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Download', 'SHA256', 'Checksum', 'Zip', 'Security', 'Windows', 'macOS', 'Linux')
            ProjectUri   = 'https://github.com/uppercut-labs/ps-kit/tree/main/packages/download-verified'
            LicenseUri   = 'https://github.com/uppercut-labs/ps-kit/blob/main/LICENSE'
            ReleaseNotes = 'First public release.'
        }
    }
}
