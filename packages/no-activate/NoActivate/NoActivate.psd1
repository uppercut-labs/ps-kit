@{
    RootModule            = 'NoActivate.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = 'b6f0b2de-8a27-4c0e-9d1c-3e5a71c4f2a9'
    Author                = 'Uppercut Labs'
    CompanyName           = 'Uppercut Labs'
    Copyright             = '(c) 2026 Uppercut Labs. MIT License.'
    Description           = 'Starts a Windows program so its first window never takes keyboard focus, keeps its windows on one display without activating them, and can run a program on a private desktop that is never shown.'
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')
    FunctionsToExport     = @(
        'Start-NoActivate'
        'Invoke-OnPrivateDesktop'
        'Set-NoActDisplay'
        'Get-NoActDisplay'
        'Move-ToDisplay'
        'Wait-Pinned'
        'Get-NoActWindow'
        'Get-ForegroundPid'
        'ConvertTo-NoActCommandLine'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Windows', 'Focus', 'Window', 'Automation', 'Testing', 'Desktop')
            ProjectUri   = 'https://github.com/uppercut-labs/ps-kit/tree/main/packages/no-activate'
            LicenseUri   = 'https://github.com/uppercut-labs/ps-kit/blob/main/LICENSE'
            ReleaseNotes = 'First public release.'
        }
    }
}
