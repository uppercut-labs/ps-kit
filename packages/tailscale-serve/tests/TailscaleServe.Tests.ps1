#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'TailscaleServe') 'TailscaleServe.psd1') -Force

    # A stand-in for the tailscale CLI. It keeps a Serve configuration in memory and answers
    # `serve status --json`, `serve ... --set-path=... <target>` and `serve ... --set-path=... off`.
    # It lives in a global because the mock body runs in the module's session state.
    $global:TsFakeInvoke = {
        param($Arguments)
        $fake = $global:TsFake
        $fake.Calls.Add(($Arguments -join ' '))
        $ok = { param($lines) [pscustomobject]@{ ExitCode = 0; Output = @($lines); ErrorOutput = @() } }
        $fail = { param($text) [pscustomobject]@{ ExitCode = 1; Output = @(); ErrorOutput = @($text) } }
        if ($Arguments[0] -ne 'serve') { return (& $fail 'unexpected command') }
        if ($Arguments -contains 'status') {
            if ($fake.FailStatus) { return (& $fail 'status failed') }
            if ($fake.RawStatus) { return (& $ok $fake.RawStatus) }
            $json = if ($fake.Web.Count -eq 0 -and $fake.AllowFunnel.Count -eq 0) { '{}' } else {
                [ordered]@{ TCP = $fake.Tcp; Web = $fake.Web; AllowFunnel = $fake.AllowFunnel } | ConvertTo-Json -Depth 10
            }
            return (& $ok ($json -split "`n"))
        }
        if ($fake.FailSet) { return (& $fail 'set failed') }
        $port = ($Arguments | Where-Object { $_ -like '--https=*' } | Select-Object -First 1) -replace '^--https=', ''
        $mount = ($Arguments | Where-Object { $_ -like '--set-path=*' } | Select-Object -First 1) -replace '^--set-path=', ''
        $hostPort = "machine.example.invalid:$port"
        if ($fake.IgnoreSet) { return (& $ok @()) }
        if ($Arguments[-1] -eq 'off') {
            if ($fake.Web.Contains($hostPort) -and $fake.Web[$hostPort].Handlers.Contains($mount)) {
                $fake.Web[$hostPort].Handlers.Remove($mount)
            }
        } else {
            if (-not $fake.Web.Contains($hostPort)) {
                $fake.Web[$hostPort] = @{ Handlers = [ordered]@{} }
                $fake.Tcp[$port] = @{ HTTPS = $true }
            }
            $fake.Web[$hostPort].Handlers[$mount] = @{ Proxy = $Arguments[-1] }
            if ($fake.Disturb) { $fake.Web[$hostPort].Handlers['/'] = @{ Proxy = 'http://127.0.0.1:1' } }
        }
        & $ok @()
    }

    function global:New-TsFake {
        $global:TsFake = @{
            Calls = New-Object System.Collections.Generic.List[string]
            Tcp = [ordered]@{ '443' = @{ HTTPS = $true } }
            Web = [ordered]@{
                'machine.example.invalid:443' = @{ Handlers = [ordered]@{ '/' = @{ Proxy = 'http://127.0.0.1:8787' } } }
            }
            AllowFunnel = [ordered]@{}
            FailStatus = $false; FailSet = $false; IgnoreSet = $false; Disturb = $false; RawStatus = $null
        }
    }

    function global:Get-TsSetCalls { @($global:TsFake.Calls | Where-Object { $_ -like 'serve --*' -and $_ -notlike '*status*' }) }
}

AfterAll {
    Remove-Variable -Name TsFake, TsFakeInvoke -Scope Global -ErrorAction SilentlyContinue
    Remove-Item function:global:New-TsFake, function:global:Get-TsSetCalls -ErrorAction SilentlyContinue
    Remove-Module TailscaleServe -ErrorAction SilentlyContinue
}

Describe 'with a mocked tailscale CLI' {
    BeforeEach {
        New-TsFake
        Mock -ModuleName TailscaleServe Invoke-TsNative { & $global:TsFakeInvoke $Arguments }
    }

    Describe 'Get-TsServeConfig' {
        It 'parses the JSON status' {
            $config = Get-TsServeConfig -Executable 'tailscale'
            $config.Web.'machine.example.invalid:443'.Handlers.'/'.Proxy | Should -Be 'http://127.0.0.1:8787'
            $global:TsFake.Calls[0] | Should -Be 'serve status --json'
        }
        It 'returns an empty object when nothing is served' {
            $global:TsFake.Web.Clear(); $global:TsFake.Tcp.Clear()
            $config = Get-TsServeConfig -Executable 'tailscale'
            @($config.PSObject.Properties).Count | Should -Be 0
        }
        It 'throws when the CLI exits with an error' {
            $global:TsFake.FailStatus = $true
            { Get-TsServeConfig -Executable 'tailscale' } | Should -Throw '*Could not read*exit code 1*'
        }
        It 'throws when the output is not JSON' {
            $global:TsFake.RawStatus = 'https://machine.example.invalid (tailnet only)'
            { Get-TsServeConfig -Executable 'tailscale' } | Should -Throw '*not valid JSON*'
        }
    }

    Describe 'Get-TsServePath' {
        BeforeEach {
            $h = $global:TsFake.Web['machine.example.invalid:443'].Handlers
            $h['/env/'] = @{ Proxy = 'http://127.0.0.1:8799/env' }
            $h['/files'] = @{ Path = '/srv/files' }
            $global:TsFake.Web['machine.example.invalid:8460'] = @{ Handlers = [ordered]@{ '/' = @{ Proxy = 'http://127.0.0.1:4420' } } }
        }
        It 'lists every mapping with its kind and target' {
            $paths = @(Get-TsServePath -Executable 'tailscale')
            $paths.Count | Should -Be 4
            ($paths | Where-Object { $_.Mount -eq '/files' }).Kind | Should -Be 'Path'
            ($paths | Where-Object { $_.Mount -eq '/' -and $_.HttpsPort -eq 443 }).Target | Should -Be 'http://127.0.0.1:8787'
        }
        It 'filters by port' {
            $paths = @(Get-TsServePath -Executable 'tailscale' -HttpsPort 8460)
            $paths.Count | Should -Be 1
            $paths[0].Target | Should -Be 'http://127.0.0.1:4420'
        }
        It 'matches a path with or without a trailing slash' {
            @(Get-TsServePath -Executable 'tailscale' -Path '/env').Count | Should -Be 1
            @(Get-TsServePath -Executable 'tailscale' -Path '/env/').Count | Should -Be 1
            @(Get-TsServePath -Executable 'tailscale' -Path '/missing').Count | Should -Be 0
        }
        It 'accepts a configuration that was already read' {
            $config = Get-TsServeConfig -Executable 'tailscale'
            $global:TsFake.Calls.Clear()
            @(Get-TsServePath -Config $config -Path '/files').Count | Should -Be 1
            $global:TsFake.Calls.Count | Should -Be 0
        }
    }

    Describe 'Assert-TsNoFunnel' {
        It 'passes when Funnel is off' {
            { Assert-TsNoFunnel -Config (Get-TsServeConfig -Executable 'tailscale') } | Should -Not -Throw
        }
        It 'throws when Funnel is on for the port' {
            $global:TsFake.AllowFunnel['machine.example.invalid:443'] = $true
            { Assert-TsNoFunnel -Config (Get-TsServeConfig -Executable 'tailscale') } | Should -Throw '*Funnel is enabled on HTTPS port 443*'
        }
        It 'ignores Funnel on another port and entries set to false' {
            $global:TsFake.AllowFunnel['machine.example.invalid:8443'] = $true
            $global:TsFake.AllowFunnel['machine.example.invalid:443'] = $false
            { Assert-TsNoFunnel -Config (Get-TsServeConfig -Executable 'tailscale') } | Should -Not -Throw
        }
    }

    Describe 'Add-TsServePath' {
        It 'adds a new path with serve --set-path and confirms it' {
            $result = Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799/env' -Executable 'tailscale'
            $result.Action | Should -Be 'Added'
            $result.Changed | Should -BeTrue
            Get-TsSetCalls | Should -Be @('serve --bg --yes --https=443 --set-path=/env http://127.0.0.1:8799/env')
            $global:TsFake.Web['machine.example.invalid:443'].Handlers['/env'].Proxy | Should -Be 'http://127.0.0.1:8799/env'
        }
        It 'is idempotent: a second call runs nothing' {
            $null = Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799/env' -Executable 'tailscale'
            $global:TsFake.Calls.Clear()
            $again = Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799/env' -Executable 'tailscale'
            $again.Changed | Should -BeFalse
            $again.Action | Should -Be 'Unchanged'
            Get-TsSetCalls | Should -BeNullOrEmpty
        }
        It 'treats a trailing slash on the mount or target as the same mapping' {
            $global:TsFake.Web['machine.example.invalid:443'].Handlers['/env/'] = @{ Proxy = 'http://127.0.0.1:8799/env/' }
            $result = Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799/env' -Executable 'tailscale'
            $result.Changed | Should -BeFalse
            Get-TsSetCalls | Should -BeNullOrEmpty
        }
        It 'leaves a path that points elsewhere alone unless -Force is given' {
            $global:TsFake.Web['machine.example.invalid:443'].Handlers['/env'] = @{ Proxy = 'http://127.0.0.1:9000' }
            { Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799/env' -Executable 'tailscale' } | Should -Throw '*already maps to Proxy http://127.0.0.1:9000*-Force*'
            Get-TsSetCalls | Should -BeNullOrEmpty
            $result = Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799/env' -Force -Executable 'tailscale'
            $result.Action | Should -Be 'Updated'
            $global:TsFake.Web['machine.example.invalid:443'].Handlers['/env'].Proxy | Should -Be 'http://127.0.0.1:8799/env'
        }
        It 'replaces under the existing mount spelling' {
            $global:TsFake.Web['machine.example.invalid:443'].Handlers['/env/'] = @{ Proxy = 'http://127.0.0.1:9000' }
            $result = Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799/env' -Force -Executable 'tailscale'
            $result.Path | Should -Be '/env/'
            @(Get-TsSetCalls)[0] | Should -BeLike '*--set-path=/env/ *'
        }
        It 'refuses to touch a port where Funnel is enabled' {
            $global:TsFake.AllowFunnel['machine.example.invalid:443'] = $true
            { Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -Executable 'tailscale' } | Should -Throw '*Funnel is enabled*'
            Get-TsSetCalls | Should -BeNullOrEmpty
        }
        It 'never runs the funnel command' {
            $null = Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -Executable 'tailscale'
            $null = Remove-TsServePath -Path '/env' -Executable 'tailscale'
            @($global:TsFake.Calls | Where-Object { $_ -match 'funnel' }).Count | Should -Be 0
        }
        It 'uses the HTTPS port it is given' {
            $result = Add-TsServePath -Path '/' -Target 'http://127.0.0.1:4420' -HttpsPort 8460 -Executable 'tailscale'
            $result.HttpsPort | Should -Be 8460
            @(Get-TsSetCalls)[0] | Should -Be 'serve --bg --yes --https=8460 --set-path=/ http://127.0.0.1:4420'
        }
        It 'throws when the CLI reports a failure' {
            $global:TsFake.FailSet = $true
            { Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -Executable 'tailscale' } | Should -Throw '*failed with exit code 1*set failed*'
        }
        It 'throws when the mapping is not there after the command succeeded' {
            $global:TsFake.IgnoreSet = $true
            { Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -Executable 'tailscale' } | Should -Throw '*was not confirmed*<absent>*'
        }
        It 'throws when another mapping on the port changed meanwhile' {
            $global:TsFake.Disturb = $true
            { Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -Executable 'tailscale' } | Should -Throw '*Another Serve mapping*changed*'
        }
        It 'refuses when the root mapping is not the expected one' {
            { Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -RequireRoot 'http://127.0.0.1:1111' -Executable 'tailscale' } | Should -Throw '*Expected the root mapping*observed*8787*'
            Get-TsSetCalls | Should -BeNullOrEmpty
            $result = Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -RequireRoot 'http://127.0.0.1:8787/' -Executable 'tailscale'
            $result.Changed | Should -BeTrue
        }
        It 'refuses when a required root is absent' {
            $global:TsFake.Web.Clear()
            { Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -RequireRoot 'http://127.0.0.1:8787' -Executable 'tailscale' } | Should -Throw '*<absent>*'
        }
        It 'changes nothing under -WhatIf' {
            Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -WhatIf -Executable 'tailscale'
            Get-TsSetCalls | Should -BeNullOrEmpty
        }
        It 'rejects a malformed path or target before running anything' {
            { Add-TsServePath -Path 'env' -Target 'http://127.0.0.1:8799' -Executable 'tailscale' } | Should -Throw
            { Add-TsServePath -Path '/e v' -Target 'http://127.0.0.1:8799' -Executable 'tailscale' } | Should -Throw
            { Add-TsServePath -Path '/env' -Target '127.0.0.1:8799' -Executable 'tailscale' } | Should -Throw
            $global:TsFake.Calls.Count | Should -Be 0
        }
        It 'keeps the other mappings in place' {
            $null = Add-TsServePath -Path '/env' -Target 'http://127.0.0.1:8799' -Executable 'tailscale'
            $global:TsFake.Web['machine.example.invalid:443'].Handlers['/'].Proxy | Should -Be 'http://127.0.0.1:8787'
        }
    }

    Describe 'Remove-TsServePath' {
        BeforeEach {
            $global:TsFake.Web['machine.example.invalid:443'].Handlers['/env'] = @{ Proxy = 'http://127.0.0.1:8799/env' }
        }
        It 'removes one path and nothing else' {
            $result = Remove-TsServePath -Path '/env' -Executable 'tailscale'
            $result.Action | Should -Be 'Removed'
            Get-TsSetCalls | Should -Be @('serve --https=443 --set-path=/env off')
            $handlers = $global:TsFake.Web['machine.example.invalid:443'].Handlers
            $handlers.Contains('/env') | Should -BeFalse
            $handlers['/'].Proxy | Should -Be 'http://127.0.0.1:8787'
        }
        It 'is idempotent: an absent path runs nothing' {
            $result = Remove-TsServePath -Path '/missing' -Executable 'tailscale'
            $result.Changed | Should -BeFalse
            $result.Action | Should -Be 'Absent'
            Get-TsSetCalls | Should -BeNullOrEmpty
        }
        It 'refuses the root path unless -AllowRoot is given' {
            { Remove-TsServePath -Path '/' -Executable 'tailscale' } | Should -Throw '*root path*-AllowRoot*'
            Get-TsSetCalls | Should -BeNullOrEmpty
            (Remove-TsServePath -Path '/' -AllowRoot -Executable 'tailscale').Action | Should -Be 'Removed'
        }
        It 'removes under the existing mount spelling' {
            $global:TsFake.Web['machine.example.invalid:443'].Handlers['/docs/'] = @{ Proxy = 'http://127.0.0.1:5000' }
            $result = Remove-TsServePath -Path '/docs' -Executable 'tailscale'
            $result.Path | Should -Be '/docs/'
            @(Get-TsSetCalls)[0] | Should -Be 'serve --https=443 --set-path=/docs/ off'
        }
        It 'refuses to touch a port where Funnel is enabled' {
            $global:TsFake.AllowFunnel['machine.example.invalid:443'] = $true
            { Remove-TsServePath -Path '/env' -Executable 'tailscale' } | Should -Throw '*Funnel is enabled*'
        }
        It 'throws when the path is still there afterwards' {
            $global:TsFake.IgnoreSet = $true
            { Remove-TsServePath -Path '/env' -Executable 'tailscale' } | Should -Throw '*still present*'
        }
        It 'changes nothing under -WhatIf' {
            Remove-TsServePath -Path '/env' -WhatIf -Executable 'tailscale'
            Get-TsSetCalls | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-TsServeMappingTarget' {
    BeforeAll {
        $script:status = @'
https://machine.example.invalid (tailnet only)
|-- /          proxy http://127.0.0.1:8787
|-- /textbooks proxy http://127.0.0.1:8766/textbooks
'@
    }
    It 'reads a proxy target from the text status' {
        Get-TsServeMappingTarget -StatusText $script:status -Path '/textbooks' | Should -Be 'http://127.0.0.1:8766/textbooks'
        Get-TsServeMappingTarget -StatusText $script:status -Path '/' | Should -Be 'http://127.0.0.1:8787'
    }
    It 'returns null for an absent path' {
        Get-TsServeMappingTarget -StatusText $script:status -Path '/other' | Should -BeNullOrEmpty
    }
    It 'throws when a path is listed twice' {
        $twice = $script:status + "`n|-- /textbooks proxy http://127.0.0.1:1"
        { Get-TsServeMappingTarget -StatusText $twice -Path '/textbooks' } | Should -Throw '*more than one mapping*'
    }
}

Describe 'Invoke-TsNative' {
    BeforeAll {
        $script:pwsh = (Get-Process -Id $PID).Path
    }
    It 'returns the exit code, output and error output of a real process' {
        $result = Invoke-TsNative -Executable $script:pwsh -Arguments @('-NoProfile', '-Command', "[Console]::Out.WriteLine('out'); [Console]::Error.WriteLine('err'); exit 3")
        $result.ExitCode | Should -Be 3
        $result.Output | Should -Contain 'out'
        $result.ErrorOutput | Should -Contain 'err'
    }
    It 'returns exit code 0 for a successful process' {
        (Invoke-TsNative -Executable $script:pwsh -Arguments @('-NoProfile', '-Command', 'exit 0')).ExitCode | Should -Be 0
    }
}
