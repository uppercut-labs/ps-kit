@{
    RootModule            = 'OwnedTask.psm1'
    ModuleVersion         = '0.1.0'
    GUID                  = '7d2c9a64-5b3e-4f1a-8e60-2a9d4c1b7f35'
    Author                = 'Uppercut Labs'
    CompanyName           = 'Uppercut Labs'
    Copyright             = '(c) 2026 Uppercut Labs. MIT License.'
    Description           = 'Registers a Windows scheduled task for a script you own, as the logged-on user, a built-in service account or a PSCredential (never a plain-text password), refuses to replace a task that belongs to someone else, and reads the task back to confirm it.'
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')
    FunctionsToExport     = @(
        'Register-OwnedTask'
        'Unregister-OwnedTask'
        'Stop-OwnedTask'
        'Assert-OwnedTask'
        'Get-OwnedTaskSummary'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Windows', 'ScheduledTask', 'TaskScheduler', 'Automation', 'Security')
            ProjectUri   = 'https://github.com/uppercut-labs/ps-kit/tree/main/packages/owned-task'
            LicenseUri   = 'https://github.com/uppercut-labs/ps-kit/blob/main/LICENSE'
            ReleaseNotes = 'First public release.'
        }
    }
}
