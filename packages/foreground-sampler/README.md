# ForegroundSampler

A PowerShell module that samples the Windows foreground window every 100 ms and writes one JSON line each time it changes. Use it to see what came to the front during a run. With `-App` it also reports whether a given app's window came to the front, which is a failure for a check that must not take focus. It reads the window and never acts on it.

## What runs where

Everything here is PowerShell, and the module only works on Windows.

| Part | Language | Runs on |
| --- | --- | --- |
| The `ForegroundSampler` module | PowerShell, with a small C# type added at import for the Win32 calls | Windows PowerShell 5.1 and PowerShell 7 on Windows |
| The tests | PowerShell with Pester 5 or later | Windows. They replace the foreground reading and `Get-Process` with replayed values, so no window is read |

Commands in this README are PowerShell. There is no macOS or Linux equivalent in this package.

## Install

From the PowerShell Gallery, once a release is published there:

```powershell
Install-PSResource ForegroundSampler          # PSResourceGet, in PowerShell 7
Install-Module ForegroundSampler -Scope CurrentUser   # PowerShellGet, in Windows PowerShell 5.1
```

From a clone of the repository:

```powershell
Import-Module ./packages/foreground-sampler/ForegroundSampler/ForegroundSampler.psd1
```

## Example

```powershell
# Process 1, started before the first step. It blocks until the stop file exists or the time has passed.
Import-Module ForegroundSampler
Remove-Item -LiteralPath .\focus.stop -ErrorAction SilentlyContinue
$run = Watch-Foreground -Out .\focus.jsonl -StopFile .\focus.stop -Seconds 900 -App 'C:\Apps\Example\Example.exe'
if (-not $run.Passed) { throw "the app came to the front $($run.AppInFront) time(s)" }
"console windows in front: $($run.ConsoleInFront)"

# Process 2, after the last step, which ends process 1:
New-Item -ItemType File -Path .\focus.stop | Out-Null
```

Because the sampler blocks, run it in its own process, for example one started with `Start-Process`, and let the steps run in another.

## Functions

| Function | What it does |
| --- | --- |
| `Watch-Foreground -Out -StopFile [-Seconds 600] [-App]` | Samples until the stop file exists or the time has passed. Returns `Out`, `Samples`, `App`, `AppInFront`, `ConsoleInFront` and `Passed` |

## The output

Each line is a JSON object. A line is written for the first reading and each time the foreground window or its process changes:

```json
{"t":"2026-11-24T10:00:00.1234567+00:00","hwnd":131092,"pid":4120,"path":"C:\\Apps\\Example\\Example.exe","title":"Example"}
```

The last line is the end record: `{"t":...,"end":true,"samples":9000}`. With `-App` it also has `app`, `appInFront` and `consoleInFront`.

`ConsoleInFront` counts changes to Windows Terminal, `conhost` or `OpenConsole`. A console that comes and goes during a step can mean a script that should have run without a window. The owner switching to a terminal also counts, so read the count by the times in the file before deciding.

## Behavior

- A change is recorded when the window handle or its process id differs from the last reading.
- The path of the process is read only on a change. A process that cannot be read gives an empty `path`.
- `-App` compares paths without regard to case. `Passed` is `$false` only when `-App` was given and the app's window came to the front at least once.
- The file is UTF-8 without a byte order mark. It is closed even when the run is interrupted.
- `-Seconds 0` writes the end record with `samples` 0.

## Tests

The tests use Pester 5 or later. They replay a list of readings and check the lines written, the `-App` judgement and the console count:

```powershell
Invoke-Pester ./packages/foreground-sampler/tests
```

## License

MIT
