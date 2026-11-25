@{
    RootModule            = 'TailscaleServe.psm1'
    ModuleVersion         = '0.2.0'
    GUID                  = '5e7f0b1c-3b0d-4a43-9d57-6f2c1f6e7a10'
    Author                = 'Uppercut Labs'
    CompanyName           = 'Uppercut Labs'
    Copyright             = '(c) 2026 Uppercut Labs. MIT License.'
    Description           = 'Add, remove and list Tailscale Serve path mappings, and set up Tailscale Services (svc: names). Idempotent, verified by reading the configuration back, and tailnet only: path changes are refused when Funnel is enabled on the port, and nothing here runs tailscale funnel.'
    PowerShellVersion     = '5.1'
    CompatiblePSEditions  = @('Desktop', 'Core')
    FunctionsToExport     = @(
        'Get-TsServeConfig'
        'Get-TsServePath'
        'Add-TsServePath'
        'Remove-TsServePath'
        'Assert-TsNoFunnel'
        'Get-TsServeMappingTarget'
        'Invoke-TsNative'
        'Get-TsServiceConfig'
        'Set-TsServeService'
        'Remove-TsServeService'
        'Get-TsServiceReceipt'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Tailscale', 'Serve', 'Tailnet', 'Windows', 'macOS', 'Linux')
            ProjectUri   = 'https://github.com/uppercut-labs/ps-kit/tree/main/packages/tailscale-serve'
            LicenseUri   = 'https://github.com/uppercut-labs/ps-kit/blob/main/LICENSE'
            ReleaseNotes = '0.2.0: service mode (Get-TsServiceConfig, Set-TsServeService, Remove-TsServeService, Get-TsServiceReceipt) for Tailscale Services. The path-mode commands are unchanged. 0.1.0: first public release.'
        }
    }
}
