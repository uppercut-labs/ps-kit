# NoActivate

A PowerShell module that starts a Windows program so its first window never takes keyboard focus, keeps that program's windows on one display without activating them, and can run a program on a private desktop that is never shown. It is for scripts and agents that launch applications while a person is working: a launch should not steal the keyboard, play sound or leave an error dialog on the screen.

The module never calls `SetForegroundWindow`, sends no keys or other input, and never makes a window topmost.

## What runs where

Everything here is PowerShell, and the module only works on Windows. It compiles a small C# class with `Add-Type` the first time a command needs it, so it can be imported (and its tests run) on any system, but the commands do nothing useful off Windows.

| Part | Language | Runs on |
| --- | --- | --- |
| The `NoActivate` module | PowerShell, with a C# class compiled by `Add-Type` that calls `CreateProcess`, `CreateDesktop`, `EnumWindows` and `SetWindowPos` | Windows PowerShell 5.1 and PowerShell 7 on Windows |
| The tests | PowerShell with Pester 5 or later | Any system with Pester. They replace every native call, so no process is started and no window is moved |

Commands in this README are PowerShell. There is no macOS or Linux equivalent in this package.

## Install

From the PowerShell Gallery, once a release is published there:

```powershell
Install-PSResource NoActivate          # PSResourceGet, in PowerShell 7
Install-Module NoActivate -Scope CurrentUser   # PowerShellGet, in Windows PowerShell 5.1
```

From a clone of the repository:

```powershell
Import-Module ./packages/no-activate/NoActivate/NoActivate.psd1
```

## Example

```powershell
# Tell the module which display to keep windows on, once per session (physical pixels).
Set-NoActDisplay -X 1920 -Y 0 -Width 1280 -Height 960

# Start a program without taking focus, keep its windows on that display for 20 seconds, and prove focus did not move.
$before = Get-ForegroundPid
$process = Start-NoActivate -Executable 'C:\Apps\Example\Example.exe' -ArgumentList @('--windowed', 'my file.dat') -Mute
$exited = Wait-Pinned $process -TimeoutSeconds 20
$after = Get-ForegroundPid
if ($before -ne $after) { Write-Warning "Focus moved from process $before to process $after." }

# A program that still takes the foreground can run where nothing is ever shown.
Invoke-OnPrivateDesktop -Executable 'C:\Apps\Example\Example.exe' -ArgumentList @('--batch') -Desktop 'example-run' -TimeoutSeconds 300
```

## Functions

| Function | What it does |
| --- | --- |
| `Start-NoActivate -Executable [-ArgumentList] [-WorkingDirectory] [-NoConsole] [-Mute] [-AllowErrorDialogs] [-Show 4\|7]` | Starts the program with its window shown without activation and returns the `Process`. Also accepts the short names `-Exe`, `-ArgList` and `-WorkDir` |
| `Invoke-OnPrivateDesktop -Executable [-ArgumentList] [-WorkingDirectory] [-Desktop] [-TimeoutSeconds 600]` | Runs the program on a desktop that is never switched to, waits for it, and returns `exit <code> pid <pid>` or `timeout, killed pid <pid>` |
| `Set-NoActDisplay -X -Y -Width -Height` | Sets the display rectangle that the next two commands use when none is passed |
| `Get-NoActDisplay` | Returns that rectangle as a hashtable with `x`, `y`, `w` and `h`. Throws if none was set |
| `Move-ToDisplay -ProcessId [-Display] [-PassThru]` | Moves the process's visible windows that sit outside the display onto it, without activating them |
| `Wait-Pinned -Process [-TimeoutSeconds 20] [-IntervalMilliseconds 100] [-Display]` | Calls `Move-ToDisplay` repeatedly until the process exits (returns `$true`) or the time runs out (`$false`). Also accepts `-TimeoutSec` and `-IntervalMs` |
| `Get-NoActWindow -ProcessId` | Lists a process's visible windows with `Handle`, the rectangle and the size. Read only |
| `Get-ForegroundPid` | The process id of the foreground window. Read only: read it before and after a launch and compare |
| `ConvertTo-NoActCommandLine -Executable [-ArgumentList]` | Builds the quoted command line the launch commands use |

## Behavior

- `Start-NoActivate` uses `CreateProcess` with `STARTUPINFO.wShowWindow` set to `SW_SHOWNOACTIVATE` (4), or `SW_SHOWMINNOACTIVE` (7) with `-Show 7`. Each argument is quoted: embedded quotes are escaped and backslashes before a quote, or at the end of an argument, are doubled, so a program that parses its line the usual way receives the arguments you gave.
- SDL 2 and SDL 3 programs choose their own show command, so three variables that they read (`SDL_WINDOW_ACTIVATE_WHEN_SHOWN`, `SDL_WINDOW_ACTIVATE_WHEN_RAISED`, `SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN`) are set for the launch and put back afterwards, even if the launch throws. They never reach later children of the caller.
- `-Mute` starts an SDL program with its `disk` audio driver writing to the null device: silent, but still a valid audio device. A value already set in the environment wins.
- By default the child inherits `SEM_FAILCRITICALERRORS`, `SEM_NOGPFAULTERRORBOX` and `SEM_NOOPENFILEERRORBOX`, so a missing DLL or a crash fails silently instead of leaving a modal error box on the screen. Read the exit code and the program's logs. `-AllowErrorDialogs` opts out. The error mode is a property of the calling process, so it stays set there after the call.
- `-NoConsole` adds `CREATE_NO_WINDOW`, so a console program gets no console window.
- The show flags are not airtight. Some programs still take the foreground now and then, whatever they are told. For a loop of launches, also give the window an unfocusable style inside the program itself. Where that is not possible, `Invoke-OnPrivateDesktop` is the strongest mode: none of the program's windows or dialogs can reach the owner's desktop, focus or input. It is not a drop-in for every program, because some exit at once or idle when they find no usable display.
- `Move-ToDisplay` leaves a window that is already inside the rectangle alone. A window outside is moved to 20 pixels inside the rectangle's top left corner and cut down to the rectangle's size if it is larger. The move uses `SWP_NOZORDER` and `SWP_NOACTIVATE`. The call makes the PowerShell process per-monitor DPI aware so that all numbers are physical pixels.
- The module holds no screen layout. Call `Set-NoActDisplay` once per session, or pass `-Display` each time.
- `Invoke-OnPrivateDesktop` ends a program that outlives `-TimeoutSeconds` through its own process handle, and reads the real exit code from that handle. The desktop name may use letters, digits, `.`, `_` and `-`.

## Tests

The tests use Pester 5 or later and replace every native call (the process start, the desktop run, the window list and move, the foreground read, `Start-Sleep`), so they need neither a desktop nor Windows:

```powershell
Invoke-Pester ./packages/no-activate/tests
```

## License

MIT
