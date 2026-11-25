# OwnedTask

A PowerShell module that registers a Windows scheduled task for a program you own, refuses to replace a task that belongs to someone else, and reads the task back to confirm it. One call replaces the hand-written `New-ScheduledTaskAction`, `New-ScheduledTaskTrigger`, `New-ScheduledTaskSettingsSet`, `New-ScheduledTaskPrincipal` and `Register-ScheduledTask` sequence that each script otherwise repeats with small differences.

## Why there is no password parameter

A task that runs under an account with a password is the easiest place to leak that password: a script reads it into a string, passes it to `Register-ScheduledTask -Password`, and the text sits in a variable, a transcript or a process listing. This module closes that off:

- Nothing in the module's interface takes a password as text. There is no `-Password`, and no `[string]` or `[SecureString]` parameter for one.
- The task runs as one of three things, chosen by which parameter you give:
  1. the current user, only while that user is logged on (the default; logon type `Interactive`, no password needed);
  2. `-ServiceAccount LocalService`, `NetworkService` or `System` (logon type `ServiceAccount`, no password needed). **Prefer this** for unattended jobs that do not need a user profile or network credentials;
  3. `-Credential`, a `PSCredential` for an account that has a password (logon type `Password`, so the task runs whether or not that account is logged on). `Get-Credential` prompts for it without echo.
- Task Scheduler's own API stores a password only if it is handed the password as text once. The module reads it from the `PSCredential` in exactly one private function (`Register-OwnedTaskRaw`), holds it in one local variable for that single call, clears the variable in a `finally` block, and never writes, logs or returns it. A test fails if the module's source reads a password anywhere else, if any command gains a parameter whose name suggests a password, or if the secret appears in the result or in any output stream.
- Windows keeps the stored password itself. You do not have to keep it anywhere.

Prefer a service account when you can; use `-Credential` only for a dedicated account that must have a password.

## What runs where

Everything here is PowerShell, and the module only works on Windows (it drives the `ScheduledTasks` module).

| Part | Language | Runs on |
| --- | --- | --- |
| The `OwnedTask` module | PowerShell, using the `ScheduledTasks` module | Windows PowerShell 5.1 and PowerShell 7 on Windows |
| The tests | PowerShell with Pester 5 or later | Any system with Pester. They replace every Task Scheduler call with an in-memory stand-in, so no task is registered |

Commands in this README are PowerShell. There is no macOS or Linux equivalent in this package.

## Install

From the PowerShell Gallery, once a release is published there:

```powershell
Install-PSResource OwnedTask          # PSResourceGet, in PowerShell 7
Install-Module OwnedTask -Scope CurrentUser   # PowerShellGet, in Windows PowerShell 5.1
```

From a clone of the repository:

```powershell
Import-Module ./packages/owned-task/OwnedTask/OwnedTask.psd1
```

## Example

```powershell
# A server that starts at logon and is rechecked every five minutes (IgnoreNew leaves a running copy alone).
Register-OwnedTask -TaskName 'Example Server' `
    -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080' -WorkingDirectory 'C:\Apps\Example' `
    -AtLogOn -RepeatEvery (New-TimeSpan -Minutes 5) -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -Start

# A nightly job as a built-in service account, in a task folder.
Register-OwnedTask -TaskName 'Example Backup' -TaskPath '\Example\' `
    -Execute 'pwsh.exe' -Argument '-NoProfile -NonInteractive -File "C:\Apps\Example\backup.ps1"' `
    -DailyAt '02:10' -ServiceAccount LocalService -WakeToRun

# A nightly job that needs a dedicated account with a password. The password is typed into the prompt, not into the script.
Register-OwnedTask -TaskName 'Example Report' -TaskPath '\Example\' `
    -Execute 'C:\Apps\Example\report.exe' -DailyAt '03:00' -Credential (Get-Credential -Message 'Account for the Example Report task')

Get-OwnedTaskSummary -TaskName 'Example Server', 'Example Backup' -TaskPath '\' | Format-Table
Unregister-OwnedTask -TaskName 'Example Server' -Execute 'C:\Apps\Example\server.exe' -Argument '--port 8080'
```

## Functions

| Function | What it does |
| --- | --- |
| `Register-OwnedTask -TaskName -Execute [-Argument] [-WorkingDirectory] [-TaskPath \] [triggers] [principal] [settings] [-OwnedArgument] [-AdoptExisting] [-Start]` | Registers the task, then reads it back. Returns `TaskName`, `TaskPath`, `Action` (`Created` or `Updated`), `UserId`, `LogonType`, `RunLevel`, `Triggers`, `State` and `Started`. Supports `-WhatIf` and `-Confirm` |
| `Unregister-OwnedTask -TaskName [-TaskPath] [-OwnerAccount] [-Execute] [-Argument] [-AdoptExisting]` | Removes a task that is owned, stopping it first. An absent task gives `Absent` |
| `Stop-OwnedTask -TaskName [-TaskPath] [-TimeoutSeconds 10]` | Stops a running task and waits until it is not running. Throws if it does not stop. Never ends a process by any other means |
| `Assert-OwnedTask -TaskName [-TaskPath] [-OwnerAccount] [-Execute] [-Argument] [-AdoptExisting]` | Throws unless the registered task is owned. Returns nothing when the task is absent |
| `Get-OwnedTaskSummary -TaskName [-TaskPath]` | `TaskName`, `State` (`NotInstalled` when absent), `LastRunTime`, `LastResult` and `Command` for each name |

The parameters of `Register-OwnedTask`:

| Group | Parameters |
| --- | --- |
| Who it runs as | none (the current user); `-ServiceAccount LocalService\|NetworkService\|System`; `-Credential <PSCredential>`; `-RunLevel Limited\|Highest` (default `Limited`) |
| Triggers | `-AtLogOn`, `-DailyAt 'HH:mm'` (one or more), `-WeeklyAt 'HH:mm' -DaysOfWeek`, `-RepeatEvery <TimeSpan>` (at least one minute; repeats without end) |
| Settings | `-ExecutionTimeLimit` (default one hour; `[TimeSpan]::Zero` for none), `-RestartCount` (default 0) with `-RestartInterval` (default one minute), `-StartWhenAvailable` (default `$true`), `-WakeToRun`, `-RunOnBatteries`, `-MultipleInstances` (default `IgnoreNew`) |

## Behavior

- **Ownership.** A task of the same name and folder is replaced only if it is owned: its principal resolves to the same account as the one this call registers (compared by security identifier, so `DOMAIN\user`, `.\user` and a SID all match; the built-in service accounts match by any name Task Scheduler reports), and it has exactly one action that runs `-Execute` with the new `-Argument` or one of the `-OwnedArgument` values (use that for the argument string an earlier version of your script registered). Otherwise the call throws, naming the reason, and nothing changes. `-AdoptExisting` skips the program check and keeps only the account check.
- **Read-back.** After registering, the task is read again, and the call throws if the program, its arguments, the working directory, the logon type, the run level, the trigger kinds and times, or the enabled state differ from what was asked for, or if the principal is not the expected account.
- A running instance of an existing task is stopped, and waited for, before it is replaced.
- `-RepeatEvery` adds a trigger that starts one minute from now and repeats with no end date (the cmdlet's finite default duration is removed). It is how a server task is rechecked when restart-on-failure alone does not recover every stopped task.
- The folder is given with or without a closing backslash. A name must not contain a backslash: use `-TaskPath` for the folder.
- A service account has no logon, so `-AtLogOn` with `-ServiceAccount` throws.
- The task never gets the run level `Highest` unless `-RunLevel Highest` is given.

## Tests

The tests use Pester 5 or later and replace every Task Scheduler and account-lookup call with an in-memory stand-in, so they need neither Windows nor administrator rights:

```powershell
Invoke-Pester ./packages/owned-task/tests
```

## License

MIT
