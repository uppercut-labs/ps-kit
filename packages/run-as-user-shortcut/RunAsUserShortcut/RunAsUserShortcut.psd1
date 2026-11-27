@{
    RootModule            = 'RunAsUserShortcut.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = '13986c14-d2ce-4f34-bef8-e27431e9242d'
    Author                = 'Uppercut Labs'
    CompanyName           = 'Uppercut Labs'
    Copyright             = '(c) 2026 Uppercut Labs. MIT License.'
    Description           = 'Runs a Windows PowerShell script in the owner''s normal shell, outside a packaged app''s redirected profile, by handing it to Explorer as a shortcut, and returns the result file it writes.'
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')
    FunctionsToExport     = @(
        'Invoke-InUserContext'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Windows', 'MSIX', 'Explorer', 'Shortcut', 'Automation', 'Testing')
            ProjectUri   = 'https://github.com/uppercut-labs/ps-kit/tree/main/packages/run-as-user-shortcut'
            LicenseUri   = 'https://github.com/uppercut-labs/ps-kit/blob/main/LICENSE'
            ReleaseNotes = 'First public release.'
        }
    }
}
