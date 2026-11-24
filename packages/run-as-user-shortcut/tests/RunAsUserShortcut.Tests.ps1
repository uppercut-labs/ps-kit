#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'RunAsUserShortcut') 'RunAsUserShortcut.psd1') -Force

    # The shortcut writer, Explorer and the wait are replaced. Start-Process writes the result file the
    # way a finished script would, unless a test says otherwise.
    Mock -ModuleName RunAsUserShortcut New-LaunchShortcut {}
    Mock -ModuleName RunAsUserShortcut Start-Sleep {}
    Mock -ModuleName RunAsUserShortcut Start-Process {
        param($FilePath, $ArgumentList)
        $global:RunAsLaunches.Add([pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList })
        if ($global:RunAsWriteResult) { Set-Content -LiteralPath $global:RunAsResult -Value $global:RunAsOutput -Encoding ASCII }
    }
}

AfterAll {
    Remove-Variable -Name RunAsLaunches, RunAsWriteResult, RunAsResult, RunAsOutput -Scope Global -ErrorAction SilentlyContinue
    Remove-Module RunAsUserShortcut -ErrorAction SilentlyContinue
}

Describe 'Invoke-InUserContext' {
    BeforeEach {
        $global:RunAsLaunches = New-Object System.Collections.Generic.List[object]
        $global:RunAsWriteResult = $true
        $global:RunAsOutput = @('done', 'step ok')
        $repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'scripts') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'scripts\job.ps1') -Value 'exit 0' -Encoding ASCII
        $global:RunAsScript = Join-Path $repo 'scripts\job.ps1'
        $global:RunAsRepo = $repo
        $global:RunAsResult = Join-Path $repo 'qa\evidence\job-result.txt'
    }

    AfterEach {
        Remove-Item -LiteralPath $global:RunAsResult -ErrorAction SilentlyContinue
    }

    It 'writes a headless conhost shortcut that runs the script, then hands it to Explorer' {
        $null = Invoke-InUserContext -ScriptPath $global:RunAsScript -WorkingDirectory $global:RunAsRepo -ResultPath $global:RunAsResult

        Should -Invoke -ModuleName RunAsUserShortcut New-LaunchShortcut -Times 1 -ParameterFilter {
            $TargetPath -eq (Join-Path $env:SystemRoot 'System32\conhost.exe') -and
            $Arguments -like '--headless *powershell.exe* -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File *job.ps1"' -and
            $WorkingDirectory -eq $global:RunAsRepo -and
            $ShortcutPath -eq (Join-Path (Split-Path -Parent $global:RunAsResult) 'run-as-user.lnk')
        }
        $global:RunAsLaunches.Count | Should -Be 1
        $global:RunAsLaunches[0].FilePath | Should -Be (Join-Path $env:SystemRoot 'explorer.exe')
        $global:RunAsLaunches[0].ArgumentList | Should -BeLike '"*run-as-user.lnk"'
    }

    It 'returns the lines of the result file' {
        $lines = Invoke-InUserContext -ScriptPath $global:RunAsScript -WorkingDirectory $global:RunAsRepo -ResultPath $global:RunAsResult
        @($lines) | Should -Be @('done', 'step ok')
    }

    It 'removes a stale result before the script starts' {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $global:RunAsResult) | Out-Null
        Set-Content -LiteralPath $global:RunAsResult -Value 'stale' -Encoding ASCII
        $global:RunAsWriteResult = $false
        $global:RunAsStaleSeen = $null
        Mock -ModuleName RunAsUserShortcut Start-Process { param($FilePath, $ArgumentList) $global:RunAsStaleSeen = Test-Path -LiteralPath $global:RunAsResult }
        { Invoke-InUserContext -ScriptPath $global:RunAsScript -WorkingDirectory $global:RunAsRepo -ResultPath $global:RunAsResult -WaitSeconds 1 } | Should -Throw
        $global:RunAsStaleSeen | Should -BeFalse
    }

    It 'throws when no result appears within the wait' {
        $global:RunAsWriteResult = $false
        { Invoke-InUserContext -ScriptPath $global:RunAsScript -WorkingDirectory $global:RunAsRepo -ResultPath $global:RunAsResult -WaitSeconds 1 } | Should -Throw '*No result at*after 1 s*'
    }

    It 'uses the shortcut path it is given' {
        $shortcut = Join-Path $TestDrive 'elsewhere\launch.lnk'
        $null = Invoke-InUserContext -ScriptPath $global:RunAsScript -WorkingDirectory $global:RunAsRepo -ResultPath $global:RunAsResult -ShortcutPath $shortcut
        Should -Invoke -ModuleName RunAsUserShortcut New-LaunchShortcut -Times 1 -ParameterFilter { $ShortcutPath -eq $shortcut }
        $global:RunAsLaunches[0].ArgumentList | Should -BeLike ('"' + $shortcut + '"')
    }

    It 'creates the folder of the result file' {
        $null = Invoke-InUserContext -ScriptPath $global:RunAsScript -WorkingDirectory $global:RunAsRepo -ResultPath $global:RunAsResult
        Test-Path -LiteralPath (Split-Path -Parent $global:RunAsResult) -PathType Container | Should -BeTrue
    }

    It 'throws before writing anything when the script does not exist' {
        $missing = Join-Path $TestDrive 'no-such-script.ps1'
        { Invoke-InUserContext -ScriptPath $missing -WorkingDirectory $global:RunAsRepo -ResultPath $global:RunAsResult } | Should -Throw '*No script at*'
        Should -Invoke -ModuleName RunAsUserShortcut New-LaunchShortcut -Times 0
        $global:RunAsLaunches.Count | Should -Be 0
    }
}
