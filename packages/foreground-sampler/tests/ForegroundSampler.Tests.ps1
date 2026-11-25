#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'ForegroundSampler') 'ForegroundSampler.psd1') -Force

    # The window readings are replayed from $global:FgReadings. The last reading repeats, and the stop
    # file is created after the last one, so the run ends by itself. Get-Process returns a path for
    # process 42 only, the app, and a console path for process 7.
    $global:FgPaths = @{
        42 = 'C:\Apps\Example\Example.exe'
        7  = 'C:\Windows\System32\conhost.exe'
        9  = 'C:\Tools\Editor.exe'
    }

    Mock -ModuleName ForegroundSampler Start-Sleep {}
    Mock -ModuleName ForegroundSampler Get-Process {
        param([int]$Id)
        if ($global:FgPaths.ContainsKey($Id)) { [pscustomobject]@{ Id = $Id; Path = $global:FgPaths[$Id] } }
        else { throw "no process $Id" }
    }
    Mock -ModuleName ForegroundSampler Get-ForegroundSample {
        $index = [Math]::Min($global:FgIndex, $global:FgReadings.Count - 1)
        $global:FgIndex++
        if ($global:FgIndex -ge $global:FgReadings.Count) {
            New-Item -ItemType File -Path $global:FgStop -Force | Out-Null
        }
        $global:FgReadings[$index]
    }
}

AfterAll {
    Remove-Variable -Name FgPaths, FgReadings, FgIndex, FgStop -Scope Global -ErrorAction SilentlyContinue
    Remove-Module ForegroundSampler -ErrorAction SilentlyContinue
}

Describe 'Watch-Foreground' {
    BeforeEach {
        $global:FgIndex = 0
        $global:FgStop = Join-Path $TestDrive 'stop.flag'
        $global:FgOut = Join-Path $TestDrive 'focus.jsonl'
        Remove-Item -LiteralPath $global:FgStop, $global:FgOut -ErrorAction SilentlyContinue
    }

    Context 'without -App' {
        BeforeEach {
            $global:FgReadings = @(
                [pscustomobject]@{ Handle = 1001; ProcessId = 9; Title = 'Editor' }
                [pscustomobject]@{ Handle = 1001; ProcessId = 9; Title = 'Editor' }
                [pscustomobject]@{ Handle = 2002; ProcessId = 42; Title = 'Example' }
            )
        }

        It 'writes one line per change and an end line' {
            $result = Watch-Foreground -Out $global:FgOut -StopFile $global:FgStop -Seconds 30
            $lines = @(Get-Content -LiteralPath $global:FgOut)
            $lines.Count | Should -Be 3
            ($lines[0] | ConvertFrom-Json).path | Should -Be 'C:\Tools\Editor.exe'
            ($lines[1] | ConvertFrom-Json).pid | Should -Be 42
            ($lines[2] | ConvertFrom-Json).end | Should -BeTrue
            $result.Samples | Should -Be 3
        }

        It 'leaves app keys out of the end line when no app is named' {
            $null = Watch-Foreground -Out $global:FgOut -StopFile $global:FgStop -Seconds 30
            $end = Get-Content -LiteralPath $global:FgOut | Select-Object -Last 1 | ConvertFrom-Json
            $end.PSObject.Properties.Name | Should -Not -Contain 'app'
            $end.samples | Should -Be 3
        }

        It 'always passes when no app is named' {
            $result = Watch-Foreground -Out $global:FgOut -StopFile $global:FgStop -Seconds 30
            $result.Passed | Should -BeTrue
            $result.AppInFront | Should -Be 0
        }

        It 'writes UTF-8 without a byte order mark' {
            $null = Watch-Foreground -Out $global:FgOut -StopFile $global:FgStop -Seconds 30
            $bytes = [System.IO.File]::ReadAllBytes($global:FgOut)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        }
    }

    Context 'with -App' {
        It 'fails the run when the app came to the front' {
            $global:FgReadings = @(
                [pscustomobject]@{ Handle = 1001; ProcessId = 9; Title = 'Editor' }
                [pscustomobject]@{ Handle = 2002; ProcessId = 42; Title = 'Example' }
                [pscustomobject]@{ Handle = 1001; ProcessId = 9; Title = 'Editor' }
            )
            $result = Watch-Foreground -Out $global:FgOut -StopFile $global:FgStop -Seconds 30 -App 'C:\Apps\Example\Example.exe'
            $result.AppInFront | Should -Be 1
            $result.Passed | Should -BeFalse
            $end = Get-Content -LiteralPath $global:FgOut | Select-Object -Last 1 | ConvertFrom-Json
            $end.app | Should -Be 'C:\Apps\Example\Example.exe'
            $end.appInFront | Should -Be 1
            $end.consoleInFront | Should -Be 0
        }

        It 'passes when the app never came to the front, and counts console windows' {
            $global:FgReadings = @(
                [pscustomobject]@{ Handle = 1001; ProcessId = 9; Title = 'Editor' }
                [pscustomobject]@{ Handle = 3003; ProcessId = 7; Title = 'Terminal' }
            )
            $result = Watch-Foreground -Out $global:FgOut -StopFile $global:FgStop -Seconds 30 -App 'C:\Apps\Example\Example.exe'
            $result.Passed | Should -BeTrue
            $result.AppInFront | Should -Be 0
            $result.ConsoleInFront | Should -Be 1
        }

        It 'compares the path without regard to case' {
            $global:FgReadings = @([pscustomobject]@{ Handle = 2002; ProcessId = 42; Title = 'Example' })
            $result = Watch-Foreground -Out $global:FgOut -StopFile $global:FgStop -Seconds 30 -App 'c:\apps\example\example.EXE'
            $result.AppInFront | Should -Be 1
        }
    }

    Context 'when the run ends' {
        It 'stops at once when the stop file already exists' {
            $global:FgReadings = @([pscustomobject]@{ Handle = 1001; ProcessId = 9; Title = 'Editor' })
            New-Item -ItemType File -Path $global:FgStop -Force | Out-Null
            $result = Watch-Foreground -Out $global:FgOut -StopFile $global:FgStop -Seconds 30
            $result.Samples | Should -Be 0
            @(Get-Content -LiteralPath $global:FgOut).Count | Should -Be 1
            $global:FgIndex | Should -Be 0
        }

        It 'stops at once when no time is allowed' {
            $global:FgReadings = @([pscustomobject]@{ Handle = 1001; ProcessId = 9; Title = 'Editor' })
            $result = Watch-Foreground -Out $global:FgOut -StopFile $global:FgStop -Seconds 0
            $result.Samples | Should -Be 0
        }
    }
}
