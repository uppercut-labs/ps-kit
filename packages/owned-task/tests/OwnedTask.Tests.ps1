#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'OwnedTask') 'OwnedTask.psd1') -Force

    # An in-memory Task Scheduler. Every Windows call sits behind a small function in the module, and each is
    # replaced here, so no task is registered and the tests do not need Windows. The fake stores tasks in the same
    # plain shape that Get-OwnedTaskRaw returns.
    $global:OtSecret = 'Sup3r-Secret-Value-12345'
    $global:OtAccounts = @{
        'EXAMPLE\me'    = 'S-1-5-21-1000-1'
        'EXAMPLE\svc'   = 'S-1-5-21-1000-2'
        'EXAMPLE\other' = 'S-1-5-21-1000-3'
        '.\svc'         = 'S-1-5-21-1000-2'
    }

    Mock -ModuleName OwnedTask Get-OwnedCurrentAccount { [pscustomobject]@{ Name = 'EXAMPLE\me'; Sid = 'S-1-5-21-1000-1' } }
    Mock -ModuleName OwnedTask Resolve-OwnedAccountSid {
        param($Account)
        if ($Account -match '^S-1-') { return $Account }
        if ($global:OtAccounts.ContainsKey($Account)) { return $global:OtAccounts[$Account] }
        throw "no such account $Account"
    }
    Mock -ModuleName OwnedTask Start-Sleep {}
    Mock -ModuleName OwnedTask Get-OwnedTaskRaw {
        param($TaskName, $TaskPath)
        $key = "$TaskPath$TaskName"
        if (-not $global:OtTasks.ContainsKey($key)) { return $null }
        $task = $global:OtTasks[$key]
        if ($task.State -eq 'Running' -and $task.Stopping) {
            $global:OtPolls++
            if ($global:OtPolls -gt $global:OtStopAfter) { $task.State = 'Ready' }
        }
        $task
    }
    Mock -ModuleName OwnedTask Get-OwnedTaskInfoRaw {
        param($TaskName, $TaskPath)
        [pscustomobject]@{ LastRunTime = [datetime]'2026-01-02T03:04:05'; LastTaskResult = 0 }
    }
    Mock -ModuleName OwnedTask Register-OwnedTaskRaw {
        param($Spec, $Credential)
        $global:OtRegistered.Add([pscustomobject]@{ Spec = $Spec; Credential = $Credential })
        $runLevel = if ($global:OtReadBackRunLevel) { $global:OtReadBackRunLevel } else { $Spec.Principal.RunLevel }
        $global:OtTasks["$($Spec.TaskPath)$($Spec.TaskName)"] = [pscustomobject]@{
            TaskName    = $Spec.TaskName
            TaskPath    = $Spec.TaskPath
            State       = 'Ready'
            Enabled     = $true
            UserId      = $Spec.Principal.UserId
            LogonType   = $Spec.Principal.LogonType
            RunLevel    = $runLevel
            Description = $Spec.Description
            Actions     = @([pscustomobject]@{ Execute = $Spec.Execute; Arguments = $Spec.Argument; WorkingDirectory = $Spec.WorkingDirectory })
            Triggers    = @($Spec.Triggers | ForEach-Object { [pscustomobject]@{ Kind = $_.Kind; At = $_.At } })
            Stopping    = $false
        }
    }
    Mock -ModuleName OwnedTask Unregister-OwnedTaskRaw {
        param($TaskName, $TaskPath)
        if (-not $global:OtKeepOnRemove) { $global:OtTasks.Remove("$TaskPath$TaskName") }
    }
    Mock -ModuleName OwnedTask Start-OwnedTaskRaw {
        param($TaskName, $TaskPath)
        $global:OtTasks["$TaskPath$TaskName"].State = 'Running'
    }
    Mock -ModuleName OwnedTask Stop-OwnedTaskRaw {
        param($TaskName, $TaskPath)
        $global:OtTasks["$TaskPath$TaskName"].Stopping = $true
    }
}

AfterAll {
    Remove-Variable -Name OtSecret, OtAccounts, OtTasks, OtRegistered, OtPolls, OtStopAfter, OtReadBackRunLevel, OtKeepOnRemove -Scope Global -ErrorAction SilentlyContinue
    Remove-Module OwnedTask -ErrorAction SilentlyContinue
}

Describe 'OwnedTask' {
    BeforeEach {
        $global:OtTasks = @{}
        $global:OtRegistered = New-Object System.Collections.Generic.List[object]
        $global:OtPolls = 0
        $global:OtStopAfter = 1
        $global:OtReadBackRunLevel = $null
        $global:OtKeepOnRemove = $false
        function Add-FakeTask($name, $path = '\', $userId = 'EXAMPLE\me', $execute = 'C:\Apps\Example\server.exe', $arguments = '--port 8080', $state = 'Ready') {
            $global:OtTasks["$path$name"] = [pscustomobject]@{
                TaskName = $name; TaskPath = $path; State = $state; Enabled = $true; UserId = $userId; LogonType = 'Interactive'; RunLevel = 'Limited'
                Description = ''; Actions = @([pscustomobject]@{ Execute = $execute; Arguments = $arguments; WorkingDirectory = '' })
                Triggers = @([pscustomobject]@{ Kind = 'Logon'; At = $null }); Stopping = $false
            }
        }
    }

    Describe 'Register-OwnedTask as the current user' {
        It 'registers a task that runs the program as the logged-on user, Limited, with safe defaults' {
            $result = Register-OwnedTask -TaskName 'Example Server' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -WorkingDirectory 'C:\Apps\Example' -AtLogOn
            $result.Action | Should -Be 'Created'
            $result.TaskPath | Should -Be '\'
            $result.UserId | Should -Be 'EXAMPLE\me'
            $result.LogonType | Should -Be 'Interactive'
            $result.RunLevel | Should -Be 'Limited'
            $global:OtRegistered.Count | Should -Be 1
            $spec = $global:OtRegistered[0].Spec
            $spec.Execute | Should -Be 'C:\Apps\Example\server.exe'
            $spec.Argument | Should -Be '--port 8080'
            $spec.WorkingDirectory | Should -Be 'C:\Apps\Example'
            $spec.Settings.ExecutionTimeLimit | Should -Be (New-TimeSpan -Hours 1)
            $spec.Settings.MultipleInstances | Should -Be 'IgnoreNew'
            $spec.Settings.StartWhenAvailable | Should -BeTrue
            $spec.Settings.RestartCount | Should -Be 0
            $global:OtRegistered[0].Credential | Should -BeNullOrEmpty
        }

        It 'limits the logon trigger to that user' {
            $null = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -AtLogOn
            $trigger = $global:OtRegistered[0].Spec.Triggers[0]
            $trigger.Kind | Should -Be 'Logon'
            $trigger.User | Should -Be 'EXAMPLE\me'
        }

        It 'adds one daily trigger per time, zero padded' {
            $null = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -DailyAt '2:10', '14:40'
            $times = @($global:OtRegistered[0].Spec.Triggers | ForEach-Object { "$($_.Kind) $($_.At)" })
            $times | Should -Be @('Daily 02:10', 'Daily 14:40')
        }

        It 'adds a weekly trigger and needs both the time and the days' {
            $null = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -WeeklyAt '00:00' -DaysOfWeek Monday
            $global:OtRegistered[0].Spec.Triggers[0].Kind | Should -Be 'Weekly'
            { Register-OwnedTask -TaskName 'U' -Execute 'C:\a.exe' -WeeklyAt '00:00' } | Should -Throw '*needs -DaysOfWeek*'
            { Register-OwnedTask -TaskName 'U' -Execute 'C:\a.exe' -DaysOfWeek Monday } | Should -Throw '*needs -WeeklyAt*'
        }

        It 'adds an endless repeating trigger for a recheck, and refuses less than a minute' {
            $result = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -AtLogOn -RepeatEvery (New-TimeSpan -Minutes 5)
            @($result.Triggers) | Should -Be @('Logon', 'Repeat')
            $global:OtRegistered[0].Spec.Triggers[1].Every | Should -Be (New-TimeSpan -Minutes 5)
            { Register-OwnedTask -TaskName 'U' -Execute 'C:\a.exe' -RepeatEvery (New-TimeSpan -Seconds 30) } | Should -Throw '*at least one minute*'
        }

        It 'passes the settings it was given' {
            $null = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -DailyAt '01:00' -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10) `
                -WakeToRun -RunOnBatteries -MultipleInstances Queue -StartWhenAvailable $false -Description 'Example task'
            $spec = $global:OtRegistered[0].Spec
            $spec.Settings.ExecutionTimeLimit | Should -Be ([TimeSpan]::Zero)
            $spec.Settings.RestartCount | Should -Be 3
            $spec.Settings.RestartInterval | Should -Be (New-TimeSpan -Minutes 10)
            $spec.Settings.WakeToRun | Should -BeTrue
            $spec.Settings.RunOnBatteries | Should -BeTrue
            $spec.Settings.MultipleInstances | Should -Be 'Queue'
            $spec.Settings.StartWhenAvailable | Should -BeFalse
            $spec.Description | Should -Be 'Example task'
        }

        It 'puts the task in the folder it is given, with a closing backslash' {
            $result = Register-OwnedTask -TaskName 'T' -TaskPath '\Example' -Execute 'C:\a.exe' -DailyAt '01:00'
            $result.TaskPath | Should -Be '\Example\'
            $global:OtTasks.ContainsKey('\Example\T') | Should -BeTrue
        }

        It 'rejects a task name with a backslash and a folder that does not start with one' {
            { Register-OwnedTask -TaskName 'Example\T' -Execute 'C:\a.exe' } | Should -Throw
            { Register-OwnedTask -TaskName 'T' -TaskPath 'Example' -Execute 'C:\a.exe' } | Should -Throw
            $global:OtRegistered.Count | Should -Be 0
        }

        It 'asks for Highest only when told to' {
            $null = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -DailyAt '01:00' -RunLevel Highest
            $global:OtRegistered[0].Spec.Principal.RunLevel | Should -Be 'Highest'
        }

        It 'starts the task afterwards with -Start' {
            $result = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -AtLogOn -Start
            $result.Started | Should -BeTrue
            $result.State | Should -Be 'Started'
            Should -Invoke -ModuleName OwnedTask Start-OwnedTaskRaw -Times 1 -Exactly
        }

        It 'does not start it without -Start' {
            $result = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -AtLogOn
            $result.Started | Should -BeFalse
            Should -Invoke -ModuleName OwnedTask Start-OwnedTaskRaw -Times 0
        }

        It 'changes nothing under -WhatIf' {
            $result = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -AtLogOn -WhatIf
            $result | Should -BeNullOrEmpty
            $global:OtRegistered.Count | Should -Be 0
        }
    }

    Describe 'Register-OwnedTask as a service account' {
        It 'registers under the built-in account with logon type ServiceAccount and no credential' {
            $result = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -DailyAt '02:00' -ServiceAccount LocalService
            $result.UserId | Should -Be 'NT AUTHORITY\LOCAL SERVICE'
            $result.LogonType | Should -Be 'ServiceAccount'
            $global:OtRegistered[0].Credential | Should -BeNullOrEmpty
        }

        It 'knows the other built-in accounts' {
            $null = Register-OwnedTask -TaskName 'A' -Execute 'C:\a.exe' -DailyAt '02:00' -ServiceAccount NetworkService
            $null = Register-OwnedTask -TaskName 'B' -Execute 'C:\a.exe' -DailyAt '02:00' -ServiceAccount System
            $global:OtRegistered[0].Spec.Principal.UserId | Should -Be 'NT AUTHORITY\NETWORK SERVICE'
            $global:OtRegistered[1].Spec.Principal.UserId | Should -Be 'NT AUTHORITY\SYSTEM'
        }

        It 'refuses -AtLogOn, which a service account does not have' {
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -AtLogOn -ServiceAccount System } | Should -Throw '*no logon*'
        }

        It 'rejects an account that is not one of the three' {
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -DailyAt '02:00' -ServiceAccount 'EXAMPLE\me' } | Should -Throw
        }
    }

    Describe 'Register-OwnedTask with a credential, and passwords' {
        BeforeEach {
            $secure = ConvertTo-SecureString $global:OtSecret -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential 'EXAMPLE\svc', $secure
        }

        It 'hands the PSCredential to the registration and uses logon type Password' {
            $result = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -DailyAt '02:10' -Credential $credential
            $result.LogonType | Should -Be 'Password'
            $result.UserId | Should -Be 'EXAMPLE\svc'
            $global:OtRegistered[0].Credential | Should -BeOfType ([pscredential])
            $global:OtRegistered[0].Credential.UserName | Should -Be 'EXAMPLE\svc'
        }

        It 'never puts the password in the result, the spec or any output stream' {
            $streams = Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -DailyAt '02:10' -Credential $credential -Verbose 4>&1 3>&1 5>&1 6>&1
            $text = ($streams | Out-String) + ($global:OtRegistered[0].Spec | ConvertTo-Json -Depth 6) + ($global:OtTasks.Values | ConvertTo-Json -Depth 6)
            $text | Should -Not -BeLike "*$($global:OtSecret)*"
        }

        It 'checks an existing task against the credential account' {
            Add-FakeTask -name 'T' -userId 'EXAMPLE\other' -execute 'C:\a.exe' -arguments ''
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -DailyAt '02:10' -Credential $credential } | Should -Throw '*belongs to another account*'
            $global:OtRegistered.Count | Should -Be 0
        }

        It 'has no parameter that takes a password as text' {
            $names = @()
            foreach ($command in 'Register-OwnedTask', 'Unregister-OwnedTask', 'Stop-OwnedTask', 'Assert-OwnedTask', 'Get-OwnedTaskSummary') {
                foreach ($parameter in (Get-Command $command).Parameters.Values) {
                    if ($parameter.Name -match 'pass|pwd|secret|token|key' -or $parameter.ParameterType -eq [securestring]) { $names += "$command -$($parameter.Name)" }
                }
            }
            $names | Should -BeNullOrEmpty
            (Get-Command Register-OwnedTask).Parameters['Credential'].ParameterType | Should -Be ([pscredential])
        }

        It 'reads a password out of a PSCredential in exactly one place' {
            $source = Get-Content -Raw -LiteralPath (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'OwnedTask') 'OwnedTask.psm1')
            ([regex]::Matches($source, 'GetNetworkCredential\(\)')).Count | Should -Be 1
            ([regex]::Matches($source, '-Password\b')).Count | Should -Be 1
            $start = $source.IndexOf('function Register-OwnedTaskRaw')
            $end = $source.IndexOf('function Unregister-OwnedTaskRaw')
            $block = $source.Substring($start, $end - $start)
            $block | Should -BeLike '*GetNetworkCredential()*'
            $block | Should -BeLike '*-Password*'
            ([regex]::Matches($source, 'ConvertTo-SecureString|-AsPlainText|Read-Host')).Count | Should -Be 0
        }
    }

    Describe 'Register-OwnedTask when the task already exists' {
        It 'replaces a task of ours that runs the same program, and says Updated' {
            Add-FakeTask -name 'T' -arguments '--port 1'
            $result = Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 1' -AtLogOn
            $result.Action | Should -Be 'Updated'
            $global:OtRegistered.Count | Should -Be 1
        }

        It 'accepts an older argument string that was listed as owned' {
            Add-FakeTask -name 'T' -arguments '"C:\old\server.py"'
            $result = Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '"C:\new\server.py"' -AtLogOn -OwnedArgument '"C:\old\server.py"'
            $result.Action | Should -Be 'Updated'
            $global:OtTasks['\T'].Actions[0].Arguments | Should -Be '"C:\new\server.py"'
        }

        It 'refuses a task that belongs to another account and leaves it alone' {
            Add-FakeTask -name 'T' -userId 'EXAMPLE\other'
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -AtLogOn } | Should -Throw '*belongs to another account*left unchanged*'
            $global:OtRegistered.Count | Should -Be 0
            $global:OtTasks['\T'].UserId | Should -Be 'EXAMPLE\other'
        }

        It 'compares accounts by security identifier, so another spelling of the same account matches' {
            Add-FakeTask -name 'T' -userId 'S-1-5-21-1000-1'
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -AtLogOn } | Should -Not -Throw
        }

        It 'refuses a task that runs another program' {
            Add-FakeTask -name 'T' -execute 'C:\Other\thing.exe'
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -AtLogOn } | Should -Throw '*runs another program*'
            $global:OtRegistered.Count | Should -Be 0
        }

        It 'refuses a task that runs the program with other arguments, unless -AdoptExisting' {
            Add-FakeTask -name 'T' -arguments '--other'
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -AtLogOn } | Should -Throw '*other arguments*'
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -AtLogOn -AdoptExisting } | Should -Not -Throw
        }

        It 'refuses a task with no principal' {
            Add-FakeTask -name 'T' -userId ''
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -AtLogOn } | Should -Throw '*no verifiable user principal*'
        }

        It 'refuses a task whose principal cannot be resolved' {
            Add-FakeTask -name 'T' -userId 'EXAMPLE\gone'
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -AtLogOn } | Should -Throw '*cannot be resolved*'
        }

        It 'stops a running instance first and waits for it' {
            Add-FakeTask -name 'T' -state 'Running'
            $global:OtStopAfter = 2
            $null = Register-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -AtLogOn
            Should -Invoke -ModuleName OwnedTask Stop-OwnedTaskRaw -Times 1 -Exactly
            $global:OtRegistered.Count | Should -Be 1
        }
    }

    Describe 'Register-OwnedTask read-back' {
        It 'throws when the task does not read back as asked' {
            $global:OtReadBackRunLevel = 'Highest'
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -AtLogOn } | Should -Throw "*did not read back as asked*run level is 'Highest'*"
        }

        It 'throws when a trigger is missing from the registered task' {
            Mock -ModuleName OwnedTask Register-OwnedTaskRaw {
                param($Spec, $Credential)
                $global:OtTasks["$($Spec.TaskPath)$($Spec.TaskName)"] = [pscustomobject]@{
                    TaskName = $Spec.TaskName; TaskPath = $Spec.TaskPath; State = 'Ready'; Enabled = $true; UserId = $Spec.Principal.UserId
                    LogonType = $Spec.Principal.LogonType; RunLevel = $Spec.Principal.RunLevel; Description = ''
                    Actions = @([pscustomobject]@{ Execute = $Spec.Execute; Arguments = $Spec.Argument; WorkingDirectory = '' }); Triggers = @(); Stopping = $false
                }
            }
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -DailyAt '02:10' } | Should -Throw "*triggers are ''*expected 'Daily'*"
        }

        It 'throws when the task is disabled' {
            Mock -ModuleName OwnedTask Register-OwnedTaskRaw {
                param($Spec, $Credential)
                $global:OtTasks["$($Spec.TaskPath)$($Spec.TaskName)"] = [pscustomobject]@{
                    TaskName = $Spec.TaskName; TaskPath = $Spec.TaskPath; State = 'Disabled'; Enabled = $false; UserId = $Spec.Principal.UserId
                    LogonType = $Spec.Principal.LogonType; RunLevel = $Spec.Principal.RunLevel; Description = ''
                    Actions = @([pscustomobject]@{ Execute = $Spec.Execute; Arguments = $Spec.Argument; WorkingDirectory = '' }); Triggers = @([pscustomobject]@{ Kind = 'Logon'; At = $null }); Stopping = $false
                }
            }
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -AtLogOn } | Should -Throw '*disabled*'
        }

        It 'does not start the task when the read-back failed' {
            $global:OtReadBackRunLevel = 'Highest'
            { Register-OwnedTask -TaskName 'T' -Execute 'C:\a.exe' -AtLogOn -Start } | Should -Throw
            Should -Invoke -ModuleName OwnedTask Start-OwnedTaskRaw -Times 0
        }
    }

    Describe 'Unregister-OwnedTask' {
        It 'removes a task of ours' {
            Add-FakeTask -name 'T'
            $result = Unregister-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080'
            $result.Action | Should -Be 'Removed'
            $result.Changed | Should -BeTrue
            $global:OtTasks.ContainsKey('\T') | Should -BeFalse
        }

        It 'is idempotent: an absent task gives Absent' {
            $result = Unregister-OwnedTask -TaskName 'Nope' -Execute 'C:\a.exe'
            $result.Action | Should -Be 'Absent'
            $result.Changed | Should -BeFalse
            Should -Invoke -ModuleName OwnedTask Unregister-OwnedTaskRaw -Times 0
        }

        It 'refuses a task that belongs to another account' {
            Add-FakeTask -name 'T' -userId 'EXAMPLE\other'
            { Unregister-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' } | Should -Throw '*belongs to another account*'
            $global:OtTasks.ContainsKey('\T') | Should -BeTrue
        }

        It 'refuses a task that runs another program' {
            Add-FakeTask -name 'T' -execute 'C:\Other\thing.exe'
            { Unregister-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' } | Should -Throw '*runs another program*'
        }

        It 'needs -Execute or -AdoptExisting' {
            Add-FakeTask -name 'T'
            { Unregister-OwnedTask -TaskName 'T' } | Should -Throw '*-Execute*-AdoptExisting*'
            (Unregister-OwnedTask -TaskName 'T' -AdoptExisting).Action | Should -Be 'Removed'
        }

        It 'checks a service account owner when asked to' {
            Add-FakeTask -name 'T' -userId 'NT AUTHORITY\LOCAL SERVICE'
            { Unregister-OwnedTask -TaskName 'T' -AdoptExisting } | Should -Throw '*belongs to another account*'
            (Unregister-OwnedTask -TaskName 'T' -OwnerAccount LocalService -AdoptExisting) | Should -Not -BeNullOrEmpty
        }

        It 'stops a running task first' {
            Add-FakeTask -name 'T' -state 'Running'
            $null = Unregister-OwnedTask -TaskName 'T' -AdoptExisting
            Should -Invoke -ModuleName OwnedTask Stop-OwnedTaskRaw -Times 1 -Exactly
        }

        It 'throws when the task is still there afterwards' {
            Add-FakeTask -name 'T'
            $global:OtKeepOnRemove = $true
            { Unregister-OwnedTask -TaskName 'T' -AdoptExisting } | Should -Throw '*still registered*'
        }

        It 'changes nothing under -WhatIf' {
            Add-FakeTask -name 'T'
            $null = Unregister-OwnedTask -TaskName 'T' -AdoptExisting -WhatIf
            $global:OtTasks.ContainsKey('\T') | Should -BeTrue
        }
    }

    Describe 'Stop-OwnedTask' {
        It 'returns $false for an absent or idle task and stops nothing' {
            Stop-OwnedTask -TaskName 'Nope' | Should -BeFalse
            Add-FakeTask -name 'T' -state 'Ready'
            Stop-OwnedTask -TaskName 'T' | Should -BeFalse
            Should -Invoke -ModuleName OwnedTask Stop-OwnedTaskRaw -Times 0
        }

        It 'stops a running task and waits until it is no longer running' {
            Add-FakeTask -name 'T' -state 'Running'
            $global:OtStopAfter = 3
            Stop-OwnedTask -TaskName 'T' | Should -BeTrue
            $global:OtTasks['\T'].State | Should -Be 'Ready'
        }

        It 'throws, naming the time, when the task does not stop' {
            Add-FakeTask -name 'T' -state 'Running'
            $global:OtStopAfter = 1000000
            { Stop-OwnedTask -TaskName 'T' -TimeoutSeconds 1 } | Should -Throw '*did not stop within 1 seconds*'
        }
    }

    Describe 'Assert-OwnedTask' {
        It 'returns nothing for an absent task' {
            { Assert-OwnedTask -TaskName 'Nope' -Execute 'C:\a.exe' } | Should -Not -Throw
        }

        It 'passes for a task of ours' {
            Add-FakeTask -name 'T'
            { Assert-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' } | Should -Not -Throw
        }

        It 'accepts an empty argument string when the task has none' {
            Add-FakeTask -name 'T' -arguments ''
            { Assert-OwnedTask -TaskName 'T' -Execute 'C:\Apps\Example\server.exe' } | Should -Not -Throw
        }

        It 'knows the built-in service accounts by the short names Task Scheduler reports' {
            Add-FakeTask -name 'A' -userId 'LOCAL SERVICE' -execute 'C:\a.exe' -arguments ''
            Add-FakeTask -name 'B' -userId 'SYSTEM' -execute 'C:\a.exe' -arguments ''
            Add-FakeTask -name 'C' -userId 'NT AUTHORITY\NETWORK SERVICE' -execute 'C:\a.exe' -arguments ''
            { Assert-OwnedTask -TaskName 'A' -OwnerAccount LocalService -Execute 'C:\a.exe' } | Should -Not -Throw
            { Assert-OwnedTask -TaskName 'B' -OwnerAccount System -Execute 'C:\a.exe' } | Should -Not -Throw
            { Assert-OwnedTask -TaskName 'C' -OwnerAccount NetworkService -Execute 'C:\a.exe' } | Should -Not -Throw
            { Assert-OwnedTask -TaskName 'A' -OwnerAccount System -Execute 'C:\a.exe' } | Should -Throw '*belongs to another account*'
        }

        It 'compares the program without regard to case' {
            Add-FakeTask -name 'T'
            { Assert-OwnedTask -TaskName 'T' -Execute 'c:\apps\example\SERVER.EXE' -Argument '--PORT 8080' } | Should -Not -Throw
        }
    }

    Describe 'Get-OwnedTaskSummary' {
        It 'reports an absent task as NotInstalled and an installed one with its command' {
            Add-FakeTask -name 'T'
            $rows = @(Get-OwnedTaskSummary -TaskName 'T', 'Nope')
            $rows.Count | Should -Be 2
            $rows[0].State | Should -Be 'Ready'
            $rows[0].Command | Should -Be 'C:\Apps\Example\server.exe --port 8080'
            $rows[0].LastResult | Should -Be 0
            $rows[1].State | Should -Be 'NotInstalled'
            $rows[1].Command | Should -BeNullOrEmpty
        }
    }
}
