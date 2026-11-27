@{
    RootModule            = 'ForegroundSampler.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = 'd6019afe-7c98-41fe-a939-9b3937a90cd2'
    Author                = 'Uppercut Labs'
    CompanyName           = 'Uppercut Labs'
    Copyright             = '(c) 2026 Uppercut Labs. MIT License.'
    Description           = 'Samples the Windows foreground window on a timer and writes one JSON line per change. With -App it also reports whether an app''s window came to the front during the run.'
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')
    FunctionsToExport     = @(
        'Watch-Foreground'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Windows', 'Foreground', 'Focus', 'Testing', 'Diagnostics')
            ProjectUri   = 'https://github.com/uppercut-labs/ps-kit/tree/main/packages/foreground-sampler'
            LicenseUri   = 'https://github.com/uppercut-labs/ps-kit/blob/main/LICENSE'
            ReleaseNotes = 'First public release.'
        }
    }
}
