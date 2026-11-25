#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'NoActivate') 'NoActivate.psd1') -Force

    # Every native call sits behind a small function that is replaced here, so nothing is started, no
    # window is moved and no desktop is created. Start-NoActProcess answers with this test process's own
    # id, so Start-NoActivate has a real process to wrap, and it records the environment it saw.
    Mock -ModuleName NoActivate Set-NoActErrorMode {}
    Mock -ModuleName NoActivate Start-NoActProcess {
        $global:NaLaunches.Add([pscustomobject]@{
            Executable       = $Executable
            CommandLine      = $CommandLine
            WorkingDirectory = $WorkingDirectory
            CreationFlags    = $CreationFlags
            Show             = $Show
            Environment      = @{
                ShowWhen  = $env:SDL_WINDOW_ACTIVATE_WHEN_SHOWN
                Raised    = $env:SDL_WINDOW_ACTIVATE_WHEN_RAISED
                NoActive  = $env:SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN
                Driver    = $env:SDL_AUDIO_DRIVER
                DiskFile  = $env:SDL_AUDIO_DISK_OUTPUT_FILE
            }
        })
        if ($global:NaLaunchThrows) { throw 'launch failed' }
        $PID
    }
    Mock -ModuleName NoActivate Start-NoActDesktopProcess { $global:NaDesktopRuns.Add([pscustomobject]@{ Executable = $Executable; CommandLine = $CommandLine; WorkingDirectory = $WorkingDirectory; Desktop = $Desktop; TimeoutMilliseconds = $TimeoutMilliseconds }); 'exit 0 pid 77' }
    Mock -ModuleName NoActivate Get-NoActWindowList { $global:NaWindows }
    Mock -ModuleName NoActivate Set-NoActWindowPosition {}
    Mock -ModuleName NoActivate Get-NoActForegroundProcessId { 4242 }
    Mock -ModuleName NoActivate Start-Sleep { param($Milliseconds) $global:NaSleeps++; if ($global:NaSleeps -ge $global:NaExitAfter) { $global:NaProcess.HasExited = $true } }
}

AfterAll {
    Remove-Variable -Name NaLaunches, NaLaunchThrows, NaDesktopRuns, NaWindows, NaSleeps, NaExitAfter, NaProcess -Scope Global -ErrorAction SilentlyContinue
    Remove-Module NoActivate -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-NoActCommandLine' {
    It 'quotes the program and every argument' {
        ConvertTo-NoActCommandLine -Executable 'C:\Apps\Example Tool\tool.exe' -ArgumentList @('one', 'two words') |
            Should -Be '"C:\Apps\Example Tool\tool.exe" "one" "two words"'
    }
    It 'gives a program with no arguments just its own quoted path' {
        ConvertTo-NoActCommandLine -Executable 'tool.exe' | Should -Be '"tool.exe"'
    }
    It 'escapes embedded quotes' {
        ConvertTo-NoActCommandLine -Executable 'tool.exe' -ArgumentList @('say "hi"') | Should -Be '"tool.exe" "say \"hi\""'
    }
    It 'doubles backslashes that end an argument, so the closing quote survives' {
        ConvertTo-NoActCommandLine -Executable 'tool.exe' -ArgumentList @('C:\dir\') | Should -Be '"tool.exe" "C:\dir\\"'
    }
    It 'doubles backslashes in front of an embedded quote' {
        ConvertTo-NoActCommandLine -Executable 'tool.exe' -ArgumentList @('a\"b') | Should -Be '"tool.exe" "a\\\"b"'
    }
    It 'keeps an empty argument as an empty quoted argument' {
        ConvertTo-NoActCommandLine -Executable 'tool.exe' -ArgumentList @('a', '', 'b') | Should -Be '"tool.exe" "a" "" "b"'
    }
}

Describe 'Start-NoActivate' {
    BeforeEach {
        $global:NaLaunches = New-Object System.Collections.Generic.List[object]
        $global:NaLaunchThrows = $false
        $appFolder = Join-Path $TestDrive 'app'
        $exe = Join-Path $appFolder 'example.exe'
        $env:SDL_AUDIO_DRIVER = $null
        $env:SDL_AUDIO_DISK_OUTPUT_FILE = $null
        $env:SDL_WINDOW_ACTIVATE_WHEN_SHOWN = $null
        $env:SDL_WINDOW_ACTIVATE_WHEN_RAISED = $null
        $env:SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN = $null
    }

    It 'starts the program with SW_SHOWNOACTIVATE, no creation flags and the quoted command line' {
        $null = Start-NoActivate -Executable $exe -ArgumentList @('--windowed', 'my file.dat')
        $global:NaLaunches.Count | Should -Be 1
        $launch = $global:NaLaunches[0]
        $launch.Executable | Should -Be $exe
        $launch.CommandLine | Should -Be ('"{0}" "--windowed" "my file.dat"' -f $exe)
        $launch.Show | Should -Be 4
        $launch.CreationFlags | Should -Be 0
    }

    It 'defaults the working directory to the folder of the program' {
        $null = Start-NoActivate -Executable $exe
        $global:NaLaunches[0].WorkingDirectory | Should -Be $appFolder
    }

    It 'uses the working directory it is given' {
        $null = Start-NoActivate -Executable $exe -WorkingDirectory $TestDrive
        $global:NaLaunches[0].WorkingDirectory | Should -Be $TestDrive
    }

    It 'accepts the short parameter names Exe, ArgList and WorkDir' {
        $null = Start-NoActivate -Exe $exe -ArgList @('a') -WorkDir $TestDrive
        $global:NaLaunches[0].Executable | Should -Be $exe
        $global:NaLaunches[0].WorkingDirectory | Should -Be $TestDrive
    }

    It 'creates the process with CREATE_NO_WINDOW under -NoConsole' {
        $null = Start-NoActivate -Executable $exe -NoConsole
        $global:NaLaunches[0].CreationFlags | Should -Be 0x08000000
    }

    It 'shows the window minimized and not activated with -Show 7' {
        $null = Start-NoActivate -Executable $exe -Show 7
        $global:NaLaunches[0].Show | Should -Be 7
    }

    It 'rejects a show command other than 4 and 7' {
        { Start-NoActivate -Executable $exe -Show 1 } | Should -Throw
        $global:NaLaunches.Count | Should -Be 0
    }

    It 'returns the process that was started, with its handle open' {
        $process = Start-NoActivate -Executable $exe
        $process | Should -BeOfType ([System.Diagnostics.Process])
        $process.Id | Should -Be $PID
    }

    It 'sets the SDL no-activate variables for the launch only' {
        $null = Start-NoActivate -Executable $exe
        $seen = $global:NaLaunches[0].Environment
        $seen.ShowWhen | Should -Be '0'
        $seen.Raised | Should -Be '0'
        $seen.NoActive | Should -Be '1'
        $env:SDL_WINDOW_ACTIVATE_WHEN_SHOWN | Should -BeNullOrEmpty
        $env:SDL_WINDOW_ACTIVATE_WHEN_RAISED | Should -BeNullOrEmpty
        $env:SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN | Should -BeNullOrEmpty
    }

    It 'restores a value the caller had already set' {
        $env:SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN = 'caller'
        $null = Start-NoActivate -Executable $exe
        $global:NaLaunches[0].Environment.NoActive | Should -Be '1'
        $env:SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN | Should -Be 'caller'
    }

    It 'restores the environment when the launch fails' {
        $global:NaLaunchThrows = $true
        { Start-NoActivate -Executable $exe -Mute } | Should -Throw '*launch failed*'
        $env:SDL_WINDOW_ACTIVATE_WHEN_SHOWN | Should -BeNullOrEmpty
        $env:SDL_AUDIO_DRIVER | Should -BeNullOrEmpty
    }

    It 'points SDL audio at the null device under -Mute' {
        $null = Start-NoActivate -Executable $exe -Mute
        $seen = $global:NaLaunches[0].Environment
        $seen.Driver | Should -Be 'disk'
        $seen.DiskFile | Should -Be 'NUL'
        $env:SDL_AUDIO_DRIVER | Should -BeNullOrEmpty
        $env:SDL_AUDIO_DISK_OUTPUT_FILE | Should -BeNullOrEmpty
    }

    It 'leaves SDL audio alone without -Mute' {
        $null = Start-NoActivate -Executable $exe
        $global:NaLaunches[0].Environment.Driver | Should -BeNullOrEmpty
    }

    It 'does not override an audio setting the caller made' {
        $env:SDL_AUDIO_DRIVER = 'dummy'
        $null = Start-NoActivate -Executable $exe -Mute
        $global:NaLaunches[0].Environment.Driver | Should -Be 'dummy'
        $global:NaLaunches[0].Environment.DiskFile | Should -Be 'NUL'
        $env:SDL_AUDIO_DRIVER | Should -Be 'dummy'
    }

    It 'turns error dialogs off for the child by default' {
        $null = Start-NoActivate -Executable $exe
        Should -Invoke -ModuleName NoActivate Set-NoActErrorMode -Times 1 -ParameterFilter { $Mode -eq 0x8003 }
    }

    It 'leaves the error mode alone under -AllowErrorDialogs' {
        $null = Start-NoActivate -Executable $exe -AllowErrorDialogs
        Should -Invoke -ModuleName NoActivate Set-NoActErrorMode -Times 0
    }
}

Describe 'Invoke-OnPrivateDesktop' {
    BeforeEach {
        $global:NaDesktopRuns = New-Object System.Collections.Generic.List[object]
        $exe = Join-Path (Join-Path $TestDrive 'app') 'example.exe'
    }

    It 'runs the program on a named desktop and returns the run summary' {
        $result = Invoke-OnPrivateDesktop -Executable $exe -ArgumentList @('--batch', 'a b') -Desktop 'example-run' -TimeoutSeconds 30
        $result | Should -Be 'exit 0 pid 77'
        $run = $global:NaDesktopRuns[0]
        $run.Executable | Should -Be $exe
        $run.CommandLine | Should -Be ('"{0}" "--batch" "a b"' -f $exe)
        $run.Desktop | Should -Be 'example-run'
        $run.TimeoutMilliseconds | Should -Be 30000
        $run.WorkingDirectory | Should -Be (Join-Path $TestDrive 'app')
    }

    It 'defaults the desktop name and the timeout' {
        $null = Invoke-OnPrivateDesktop -Exe $exe
        $global:NaDesktopRuns[0].Desktop | Should -Be 'noactivate-private'
        $global:NaDesktopRuns[0].TimeoutMilliseconds | Should -Be 600000
    }

    It 'rejects a desktop name with characters Windows would treat as a path' {
        { Invoke-OnPrivateDesktop -Executable $exe -Desktop 'a\b' } | Should -Throw
        $global:NaDesktopRuns.Count | Should -Be 0
    }
}

Describe 'the display' {
    BeforeEach {
        InModuleScope NoActivate { $script:NoActDisplay = $null }
    }

    It 'has no built-in layout: reading it before it is set throws' {
        { Get-NoActDisplay } | Should -Throw '*Set-NoActDisplay*'
    }

    It 'returns the rectangle that was set, as x, y, w and h' {
        Set-NoActDisplay -X 100 -Y 50 -Width 1280 -Height 960
        $display = Get-NoActDisplay
        $display.x | Should -Be 100
        $display.y | Should -Be 50
        $display.w | Should -Be 1280
        $display.h | Should -Be 960
    }

    It 'rejects an empty rectangle' {
        { Set-NoActDisplay -X 0 -Y 0 -Width 0 -Height 100 } | Should -Throw
    }
}

Describe 'Move-ToDisplay' {
    BeforeEach {
        Set-NoActDisplay -X 1000 -Y 500 -Width 800 -Height 600
        $inside = [pscustomobject]@{ Handle = [IntPtr]1; Left = 1010; Top = 510; Right = 1410; Bottom = 910 }
        $outside = [pscustomobject]@{ Handle = [IntPtr]2; Left = 0; Top = 0; Right = 300; Bottom = 200 }
        $tooBig = [pscustomobject]@{ Handle = [IntPtr]3; Left = 0; Top = 0; Right = 1600; Bottom = 1200 }
    }

    It 'leaves a window that is already inside the display alone' {
        $global:NaWindows = @($inside)
        Move-ToDisplay -ProcessId 5
        Should -Invoke -ModuleName NoActivate Set-NoActWindowPosition -Times 0
    }

    It 'moves a window from outside to 20 pixels inside the corner, keeping its size' {
        $global:NaWindows = @($outside)
        Move-ToDisplay -ProcessId 5
        Should -Invoke -ModuleName NoActivate Set-NoActWindowPosition -Times 1 -Exactly -ParameterFilter {
            $Handle -eq [IntPtr]2 -and $X -eq 1020 -and $Y -eq 520 -and $Width -eq 300 -and $Height -eq 200
        }
    }

    It 'cuts a window that is larger than the display down to the display size' {
        $global:NaWindows = @($tooBig)
        Move-ToDisplay -ProcessId 5
        Should -Invoke -ModuleName NoActivate Set-NoActWindowPosition -Times 1 -Exactly -ParameterFilter {
            $Handle -eq [IntPtr]3 -and $Width -eq 800 -and $Height -eq 600
        }
    }

    It 'handles every window of the process and counts the moved ones with -PassThru' {
        $global:NaWindows = @($inside, $outside, $tooBig)
        Move-ToDisplay -ProcessId 5 -PassThru | Should -Be 2
        Should -Invoke -ModuleName NoActivate Set-NoActWindowPosition -Times 2 -Exactly
    }

    It 'returns nothing without -PassThru, so a caller that prints its output is not changed' {
        $global:NaWindows = @($outside)
        $output = @(Move-ToDisplay -ProcessId 5)
        $output.Count | Should -Be 0
    }

    It 'accepts a display of its own, positional, and the old -ProcId name' {
        $global:NaWindows = @($outside)
        Move-ToDisplay 5 @{ x = 0; y = 0; w = 100; h = 100 }
        Should -Invoke -ModuleName NoActivate Set-NoActWindowPosition -Times 1 -Exactly -ParameterFilter { $X -eq 20 -and $Y -eq 20 -and $Width -eq 100 -and $Height -eq 100 }
        { Move-ToDisplay -ProcId 5 -Display @{ x = 0; y = 0; w = 4000; h = 4000 } } | Should -Not -Throw
    }

    It 'throws on a display that lacks a key, before touching a window' {
        $global:NaWindows = @($outside)
        { Move-ToDisplay -ProcessId 5 -Display @{ x = 0; y = 0 } } | Should -Throw "*Missing 'w'*"
        Should -Invoke -ModuleName NoActivate Set-NoActWindowPosition -Times 0
    }
}

Describe 'Wait-Pinned' {
    BeforeEach {
        Set-NoActDisplay -X 1000 -Y 500 -Width 800 -Height 600
        $global:NaWindows = @([pscustomobject]@{ Handle = [IntPtr]2; Left = 0; Top = 0; Right = 300; Bottom = 200 })
        $global:NaSleeps = 0
        $global:NaExitAfter = 3
        $global:NaProcess = [pscustomobject]@{ Id = 5; HasExited = $false }
    }

    It 'keeps moving the windows until the process exits, then returns $true' {
        Wait-Pinned $global:NaProcess -TimeoutSeconds 60 -IntervalMilliseconds 10 | Should -BeTrue
        Should -Invoke -ModuleName NoActivate Set-NoActWindowPosition -Times 3 -Exactly
        Should -Invoke -ModuleName NoActivate Start-Sleep -Times 3 -Exactly -ParameterFilter { $Milliseconds -eq 10 }
    }

    It 'returns $false when the time runs out first' {
        Wait-Pinned $global:NaProcess -TimeoutSeconds 0 | Should -BeFalse
        Should -Invoke -ModuleName NoActivate Set-NoActWindowPosition -Times 0
    }

    It 'accepts the old -TimeoutSec and -IntervalMs names' {
        Wait-Pinned $global:NaProcess -TimeoutSec 60 -IntervalMs 25 | Should -BeTrue
        Should -Invoke -ModuleName NoActivate Start-Sleep -Times 1 -ParameterFilter { $Milliseconds -eq 25 }
    }

    It 'prints only its result' {
        $output = @(Wait-Pinned $global:NaProcess -TimeoutSeconds 60)
        $output.Count | Should -Be 1
    }
}

Describe 'Get-NoActWindow' {
    It 'lists the windows of a process with their size' {
        $global:NaWindows = @([pscustomobject]@{ Handle = [IntPtr]9; Left = 10; Top = 20; Right = 110; Bottom = 220 })
        $window = @(Get-NoActWindow -ProcessId 5)
        $window.Count | Should -Be 1
        $window[0].Width | Should -Be 100
        $window[0].Height | Should -Be 200
        $window[0].Handle | Should -Be ([IntPtr]9)
    }

    It 'returns nothing when the process has no visible window' {
        $global:NaWindows = @()
        @(Get-NoActWindow -ProcessId 5).Count | Should -Be 0
    }
}

Describe 'Get-ForegroundPid' {
    It 'returns the process id of the foreground window' {
        Get-ForegroundPid | Should -Be 4242
    }
}
