#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'TailscaleServe') 'TailscaleServe.psd1') -Force

    # A stand-in for the tailscale CLI in service mode. It keeps Tailscale Services in memory and answers
    # `serve get-config --service=<name>|--all`, `serve --service=<name> --https=<port> --yes <target>`,
    # `serve advertise|drain|clear <name>` and `status --json`. It lives in a global because the mock body
    # runs in the module's session state.
    $global:TsSvcInvoke = {
        param($Arguments)
        $fake = $global:TsSvc
        $fake.Calls.Add(($Arguments -join ' '))
        $ok = { param($lines) [pscustomobject]@{ ExitCode = 0; Output = @($lines); ErrorOutput = @() } }
        $fail = { param($text) [pscustomobject]@{ ExitCode = 1; Output = @(); ErrorOutput = @($text) } }
        if ($Arguments[0] -eq 'status') {
            if ($fake.FailStatus) { return (& $fail 'status failed') }
            return (& $ok (@('{ "Self": { "ID": "node-example-1", "HostName": "host-example", "CapMap": { "service-host": [ { "svc:example": "x" } ] } } }')))
        }
        if ($Arguments[0] -ne 'serve') { return (& $fail 'unexpected command') }
        if ($Arguments[1] -eq 'get-config') {
            if ($fake.FailGet) { return (& $fail 'get-config failed') }
            if ($fake.RawGet) { return (& $ok $fake.RawGet) }
            $names = @($fake.Services.Keys)
            $service = ($Arguments | Where-Object { $_ -like '--service=*' } | Select-Object -First 1)
            if ($service) { $names = @($names | Where-Object { $_ -eq ($service -replace '^--service=', '') }) }
            if ($names.Count -eq 0) { return (& $ok @()) }
            $services = [ordered]@{}
            foreach ($name in $names) {
                $entry = [ordered]@{ endpoints = [ordered]@{} }
                foreach ($key in $fake.Services[$name].Endpoints.Keys) { $entry.endpoints[$key] = $fake.Services[$name].Endpoints[$key] }
                if (-not $fake.Services[$name].Advertised) { $entry.advertised = $false }
                $services[$name] = $entry
            }
            $json = [ordered]@{ version = '0.0.1'; services = $services } | ConvertTo-Json -Depth 8
            return (& $ok ($json -split "`n"))
        }
        if ($fake.FailSet -and $Arguments[1] -like '--service=*') { return (& $fail 'set failed') }
        if ($Arguments[1] -eq 'advertise') {
            if (-not $fake.Services.Contains($Arguments[2])) { return (& $fail 'no such service') }
            if (-not $fake.NeverAdvertise) { $fake.Services[$Arguments[2]].Advertised = $true }
            return (& $ok @())
        }
        if ($Arguments[1] -eq 'drain') {
            if (-not $fake.Services.Contains($Arguments[2])) { return (& $fail 'no such service') }
            $fake.Services[$Arguments[2]].Advertised = $false
            return (& $ok @())
        }
        if ($Arguments[1] -eq 'clear') {
            if (-not $fake.Services.Contains($Arguments[2])) { return (& $fail 'no such service') }
            if (-not $fake.KeepOnClear) { $fake.Services.Remove($Arguments[2]) }
            return (& $ok @())
        }
        if ($Arguments[1] -like '--service=*') {
            $name = $Arguments[1] -replace '^--service=', ''
            $port = ($Arguments[2] -replace '^--https?=', '')
            $target = $Arguments[-1]
            if ($fake.IgnoreSet) { return (& $ok @()) }
            if (-not $fake.Services.Contains($name)) { $fake.Services[$name] = @{ Endpoints = [ordered]@{}; Advertised = $true } }
            $normalized = if ($target -match '^https?://') { $target } else { "http://$target" }
            $fake.Services[$name].Endpoints["tcp:$port"] = $normalized
            return (& $ok @())
        }
        & $fail 'unexpected serve command'
    }

    function global:New-TsSvcFake {
        $global:TsSvc = @{
            Calls = New-Object System.Collections.Generic.List[string]
            Services = [ordered]@{}
            FailGet = $false; FailSet = $false; IgnoreSet = $false; NeverAdvertise = $false; KeepOnClear = $false; FailStatus = $false; RawGet = $null
        }
    }
    function global:Add-TsSvcFakeService([string]$Name, [string]$Target = 'http://127.0.0.1:4100', [int]$Port = 443, [bool]$Advertised = $true) {
        $global:TsSvc.Services[$Name] = @{ Endpoints = [ordered]@{ "tcp:$Port" = $Target }; Advertised = $Advertised }
    }
    # The commands that change anything, in the order they ran (reads are get-config and status).
    function global:Get-TsSvcChanges { @($global:TsSvc.Calls | Where-Object { $_ -notlike 'serve get-config*' -and $_ -notlike 'status*' }) }
}

AfterAll {
    Remove-Variable -Name TsSvc, TsSvcInvoke -Scope Global -ErrorAction SilentlyContinue
    Remove-Item function:global:New-TsSvcFake, function:global:Add-TsSvcFakeService, function:global:Get-TsSvcChanges -ErrorAction SilentlyContinue
    Remove-Module TailscaleServe -ErrorAction SilentlyContinue
}

Describe 'Tailscale Services (service mode)' {
    BeforeEach {
        New-TsSvcFake
        Mock -ModuleName TailscaleServe Invoke-TsNative { & $global:TsSvcInvoke $Arguments }
    }

    Describe 'Get-TsServiceConfig' {
        It 'reads one service: its endpoints and whether it is advertised' {
            Add-TsSvcFakeService 'svc:example' 'http://127.0.0.1:4100'
            $config = @(Get-TsServiceConfig -Service 'svc:example' -Executable 'tailscale')
            $config.Count | Should -Be 1
            $config[0].Service | Should -Be 'svc:example'
            $config[0].Advertised | Should -BeTrue
            $config[0].Endpoints.Count | Should -Be 1
            $config[0].Endpoints[0].Port | Should -Be 443
            $config[0].Endpoints[0].Protocol | Should -Be 'tcp'
            $config[0].Endpoints[0].Target | Should -Be 'http://127.0.0.1:4100'
            $global:TsSvc.Calls[0] | Should -Be 'serve get-config --service=svc:example'
        }

        It 'lists every service with -All' {
            Add-TsSvcFakeService 'svc:one' 'http://127.0.0.1:4100'
            Add-TsSvcFakeService 'svc:two' 'http://127.0.0.1:4101' -Advertised $false
            $config = @(Get-TsServiceConfig -All -Executable 'tailscale')
            $config.Count | Should -Be 2
            ($config | Where-Object { $_.Service -eq 'svc:two' }).Advertised | Should -BeFalse
            $global:TsSvc.Calls[0] | Should -Be 'serve get-config --all'
        }

        It 'returns nothing for a service that has no configuration' {
            @(Get-TsServiceConfig -Service 'svc:example' -Executable 'tailscale').Count | Should -Be 0
        }

        It 'returns only the service that was asked for' {
            $global:TsSvc.RawGet = '{ "version": "0.0.1", "services": { "svc:one": { "endpoints": { "tcp:443": "http://127.0.0.1:1" } }, "svc:example": { "endpoints": { "tcp:443": "http://127.0.0.1:2" } } } }'
            $config = @(Get-TsServiceConfig -Service 'svc:example' -Executable 'tailscale')
            $config.Count | Should -Be 1
            $config[0].Endpoints[0].Target | Should -Be 'http://127.0.0.1:2'
        }

        It 'reads the huJSON file format: comments and trailing commas' {
            $global:TsSvc.RawGet = @(
                '{',
                '  "version": "0.0.1",',
                '  // the example service',
                '  "services": { "svc:example": { "endpoints": { "tcp:443": "https://localhost:8443", }, "advertised": false, }, },',
                '}'
            )
            $config = @(Get-TsServiceConfig -Service 'svc:example' -Executable 'tailscale')
            $config[0].Advertised | Should -BeFalse
            $config[0].Endpoints[0].Target | Should -Be 'https://localhost:8443'
        }

        It 'throws when the CLI fails or prints something that is not JSON' {
            $global:TsSvc.FailGet = $true
            { Get-TsServiceConfig -Service 'svc:example' -Executable 'tailscale' } | Should -Throw '*Could not read*exit code 1*'
            $global:TsSvc.FailGet = $false
            $global:TsSvc.RawGet = 'not json at all'
            { Get-TsServiceConfig -Service 'svc:example' -Executable 'tailscale' } | Should -Throw '*not valid JSON*'
        }

        It 'rejects a name that is not svc: with lower-case letters, digits and hyphens, before running anything' {
            foreach ($bad in 'example', 'svc:', 'svc:Example', 'svc:a_b', 'svc:a--b', 'svc:-a') {
                { Get-TsServiceConfig -Service $bad -Executable 'tailscale' } | Should -Throw
            }
            $global:TsSvc.Calls.Count | Should -Be 0
        }
    }

    Describe 'Set-TsServeService' {
        It 'configures a new service, advertises it and confirms it by reading it back' {
            $result = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -Executable 'tailscale'
            $result.Action | Should -Be 'Added'
            $result.Changed | Should -BeTrue
            $result.Advertised | Should -BeTrue
            $result.Port | Should -Be 443
            Get-TsSvcChanges | Should -Be @('serve --service=svc:example --https=443 --yes http://127.0.0.1:4100', 'serve advertise svc:example')
            $global:TsSvc.Calls[-1] | Should -Be 'serve get-config --service=svc:example'
        }

        It 'is idempotent: a second call runs nothing but reads' {
            $null = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -Executable 'tailscale'
            $global:TsSvc.Calls.Clear()
            $result = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -Executable 'tailscale'
            $result.Action | Should -Be 'Unchanged'
            $result.Changed | Should -BeFalse
            Get-TsSvcChanges | Should -BeNullOrEmpty
        }

        It 'treats a target without a scheme, with localhost or with a trailing slash as the same' {
            Add-TsSvcFakeService 'svc:example' 'http://127.0.0.1:4100'
            foreach ($same in '127.0.0.1:4100', 'localhost:4100', 'http://localhost:4100/') {
                (Set-TsServeService -Service 'svc:example' -Target $same -Executable 'tailscale').Action | Should -Be 'Unchanged'
            }
            Get-TsSvcChanges | Should -BeNullOrEmpty
        }

        It 'does not replace an endpoint that points elsewhere unless -Replace or -Reset is given' {
            Add-TsSvcFakeService 'svc:example' 'http://127.0.0.1:4100'
            { Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4200' -Executable 'tailscale' } | Should -Throw '*already maps tcp:443 to http://127.0.0.1:4100*-Replace*left unchanged*'
            Get-TsSvcChanges | Should -BeNullOrEmpty
        }

        It 'replaces it with -Replace, without draining or clearing' {
            Add-TsSvcFakeService 'svc:example' 'http://127.0.0.1:4100'
            $result = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4200' -Replace -Executable 'tailscale'
            $result.Action | Should -Be 'Updated'
            $result.Target | Should -Be 'http://127.0.0.1:4200'
            Get-TsSvcChanges | Should -Be @('serve --service=svc:example --https=443 --yes http://127.0.0.1:4200', 'serve advertise svc:example')
        }

        It 'drains and clears first with -Reset, in that order' {
            Add-TsSvcFakeService 'svc:example' 'http://127.0.0.1:4100'
            $result = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4200' -Reset -Executable 'tailscale'
            $result.Action | Should -Be 'Updated'
            Get-TsSvcChanges | Should -Be @('serve drain svc:example', 'serve clear svc:example', 'serve --service=svc:example --https=443 --yes http://127.0.0.1:4200', 'serve advertise svc:example')
        }

        It 'skips the drain and clear under -Reset when the service has nothing yet' {
            $null = Set-TsServeService -Service 'svc:example' -Target '127.0.0.1:4100' -Reset -Executable 'tailscale'
            Get-TsSvcChanges | Should -Be @('serve --service=svc:example --https=443 --yes 127.0.0.1:4100', 'serve advertise svc:example')
        }

        It 'only advertises a service that is configured as asked but drained' {
            Add-TsSvcFakeService 'svc:example' 'http://127.0.0.1:4100' -Advertised $false
            $result = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -Executable 'tailscale'
            $result.Action | Should -Be 'Advertised'
            $result.Changed | Should -BeTrue
            Get-TsSvcChanges | Should -Be @('serve advertise svc:example')
        }

        It 'does not advertise under -NoAdvertise' {
            $result = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -NoAdvertise -Executable 'tailscale'
            $result.Action | Should -Be 'Added'
            Get-TsSvcChanges | Should -Be @('serve --service=svc:example --https=443 --yes http://127.0.0.1:4100')
        }

        It 'serves plain HTTP on the port it is given' {
            $result = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -Protocol Http -Port 80 -Executable 'tailscale'
            $result.Port | Should -Be 80
            $result.Protocol | Should -Be 'Http'
            (Get-TsSvcChanges)[0] | Should -Be 'serve --service=svc:example --http=80 --yes http://127.0.0.1:4100'
        }

        It 'leaves other ports of the same service alone when it adds one' {
            Add-TsSvcFakeService 'svc:example' 'http://127.0.0.1:4100' -Port 443
            $null = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4101' -Protocol Http -Port 80 -Executable 'tailscale'
            $config = @(Get-TsServiceConfig -Service 'svc:example' -Executable 'tailscale')
            $config[0].Endpoints.Count | Should -Be 2
        }

        It 'throws, naming the CLI error, when the command fails' {
            $global:TsSvc.FailSet = $true
            { Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -Executable 'tailscale' } | Should -Throw '*failed with exit code 1*set failed*'
        }

        It 'throws when the CLI accepts the command but the endpoint is not there afterwards' {
            $global:TsSvc.IgnoreSet = $true
            { Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -NoAdvertise -Executable 'tailscale' } | Should -Throw '*was not confirmed*<absent>*'
        }

        It 'throws when the service is still not advertised afterwards' {
            $global:TsSvc.NeverAdvertise = $true
            Add-TsSvcFakeService 'svc:example' 'http://127.0.0.1:4100' -Advertised $false
            { Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -Executable 'tailscale' } | Should -Throw '*still not advertised*'
        }

        It 'changes nothing under -WhatIf' {
            $result = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -WhatIf -Executable 'tailscale'
            $result | Should -BeNullOrEmpty
            Get-TsSvcChanges | Should -BeNullOrEmpty
        }

        It 'accepts only a local http(s) target and a svc: name, before running anything' {
            foreach ($bad in 'http://example.invalid:4100', '0.0.0.0:4100', 'http://127.0.0.1', 'ftp://127.0.0.1:1', '4100') {
                { Set-TsServeService -Service 'svc:example' -Target $bad -Executable 'tailscale' } | Should -Throw
            }
            { Set-TsServeService -Service 'example' -Target 'http://127.0.0.1:4100' -Executable 'tailscale' } | Should -Throw
            $global:TsSvc.Calls.Count | Should -Be 0
        }

        It 'never runs tailscale funnel' {
            $null = Set-TsServeService -Service 'svc:example' -Target 'http://127.0.0.1:4100' -Reset -Executable 'tailscale'
            $null = Remove-TsServeService -Service 'svc:example' -Executable 'tailscale'
            @($global:TsSvc.Calls | Where-Object { $_ -match 'funnel' }).Count | Should -Be 0
        }
    }

    Describe 'Remove-TsServeService' {
        It 'drains, then clears, and confirms the service is gone' {
            Add-TsSvcFakeService 'svc:example'
            $result = Remove-TsServeService -Service 'svc:example' -Executable 'tailscale'
            $result.Action | Should -Be 'Removed'
            $result.Changed | Should -BeTrue
            Get-TsSvcChanges | Should -Be @('serve drain svc:example', 'serve clear svc:example')
        }

        It 'is idempotent: an absent service runs nothing' {
            $result = Remove-TsServeService -Service 'svc:example' -Executable 'tailscale'
            $result.Action | Should -Be 'Absent'
            $result.Changed | Should -BeFalse
            Get-TsSvcChanges | Should -BeNullOrEmpty
        }

        It 'throws when the service is still configured afterwards' {
            Add-TsSvcFakeService 'svc:example'
            $global:TsSvc.KeepOnClear = $true
            { Remove-TsServeService -Service 'svc:example' -Executable 'tailscale' } | Should -Throw '*still configured after removal*'
        }

        It 'changes nothing under -WhatIf' {
            Add-TsSvcFakeService 'svc:example'
            $null = Remove-TsServeService -Service 'svc:example' -WhatIf -Executable 'tailscale'
            Get-TsSvcChanges | Should -BeNullOrEmpty
        }

        It 'does not touch another service' {
            Add-TsSvcFakeService 'svc:example'
            Add-TsSvcFakeService 'svc:other' 'http://127.0.0.1:4101'
            $null = Remove-TsServeService -Service 'svc:example' -Executable 'tailscale'
            $global:TsSvc.Services.Contains('svc:other') | Should -BeTrue
        }
    }

    Describe 'Get-TsServiceReceipt' {
        It 'collects the configuration, the other services and the node, and changes nothing' {
            Add-TsSvcFakeService 'svc:example'
            Add-TsSvcFakeService 'svc:other' 'http://127.0.0.1:4101'
            $receipt = Get-TsServiceReceipt -Service 'svc:example' -Executable 'tailscale'
            $receipt.Service | Should -Be 'svc:example'
            $receipt.Config.Endpoints[0].Target | Should -Be 'http://127.0.0.1:4100'
            @($receipt.Services) | Should -Be @('svc:example', 'svc:other')
            $receipt.DeviceId | Should -Be 'node-example-1'
            $receipt.HostName | Should -Be 'host-example'
            $receipt.ServiceHost | Should -Not -BeNullOrEmpty
            $receipt.ReadAt | Should -Match '^\d{4}-\d\d-\d\dT'
            Get-TsSvcChanges | Should -BeNullOrEmpty
            ($global:TsSvc.Calls | Where-Object { $_ -eq 'status --json' }).Count | Should -Be 1
        }

        It 'writes the receipt as UTF-8 JSON without a byte order mark when given a path' {
            Add-TsSvcFakeService 'svc:example'
            $path = Join-Path (Join-Path $TestDrive 'receipts') 'example.json'
            $null = Get-TsServiceReceipt -Service 'svc:example' -Path $path -Executable 'tailscale'
            $bytes = [IO.File]::ReadAllBytes($path)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
            ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json).Service | Should -Be 'svc:example'
        }

        It 'throws when the node status cannot be read' {
            Add-TsSvcFakeService 'svc:example'
            $global:TsSvc.FailStatus = $true
            { Get-TsServiceReceipt -Service 'svc:example' -Executable 'tailscale' } | Should -Throw '*Could not read the Tailscale status*'
        }
    }
}
