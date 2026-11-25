@{
    RootModule            = 'ProcessTreeMemory.psm1'
    ModuleVersion         = '0.1.0'
    GUID                  = '3e4b3131-1a05-4a6f-85f4-ce655f70a742'
    Author                = 'Uppercut Labs'
    CompanyName           = 'Uppercut Labs'
    Copyright             = '(c) 2026 Uppercut Labs. MIT License.'
    Description           = 'Reports the private memory and working set of a Windows process and all of its descendants, as one object, with an optional budget and ceiling check.'
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')
    FunctionsToExport     = @(
        'Get-ProcessTreeMemory'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Windows', 'Memory', 'Process', 'Budget', 'Diagnostics')
            ProjectUri   = 'https://github.com/uppercut-labs/ps-kit/tree/main/packages/process-tree-memory'
            LicenseUri   = 'https://github.com/uppercut-labs/ps-kit/blob/main/LICENSE'
            ReleaseNotes = 'First public release.'
        }
    }
}
