# RunAsUserShortcut

A PowerShell module that runs a script in the owner's normal shell and returns the result file the script writes. An agent's own shell inside a packaged (MSIX) app has its `%APPDATA%` and `%LOCALAPPDATA%` writes redirected into that package, so the owner's apps cannot see them. This module starts the script through Explorer instead, using a shortcut to `conhost.exe --headless`, so the script runs outside the package in a console with no window.

## What runs where

Everything here is PowerShell, and the module only works on Windows.

| Part | Language | Runs on |
| --- | --- | --- |
| The `RunAsUserShortcut` module | PowerShell, using the `WScript.Shell` COM object and Explorer | Windows PowerShell 5.1 and PowerShell 7 on Windows |
| The tests | PowerShell with Pester 5 or later | Windows. They replace the shortcut writer, `Start-Process` and the wait, so no shortcut is written and nothing is launched |

Commands in this README are PowerShell. There is no macOS or Linux equivalent in this package.

## Install

From the PowerShell Gallery, once a release is published there:

```powershell
Install-PSResource RunAsUserShortcut          # PSResourceGet, in PowerShell 7
Install-Module RunAsUserShortcut -Scope CurrentUser   # PowerShellGet, in Windows PowerShell 5.1
```

From a clone of the repository:

```powershell
Import-Module ./packages/run-as-user-shortcut/RunAsUserShortcut/RunAsUserShortcut.psd1
```

## Example

```powershell
# A script that writes its result to a file when it is done.
# (The script receives no arguments: pass its inputs in a file it reads.)
$repo = 'C:\src\my-app'
$lines = Invoke-InUserContext `
    -ScriptPath (Join-Path $repo 'scripts\install.ps1') `
    -WorkingDirectory $repo `
    -ResultPath (Join-Path $repo 'qa\evidence\install-log.txt') `
    -WaitSeconds 300
$lines
```

## Functions

| Function | What it does |
| --- | --- |
| `Invoke-InUserContext -ScriptPath -WorkingDirectory -ResultPath [-ShortcutPath] [-WaitSeconds 180]` | Writes the shortcut, starts it through Explorer, waits for the result file and returns its lines |

The shortcut defaults to `run-as-user.lnk` beside the result file. The result folder is created if it does not exist.

## Behavior

- The shortcut's target is `conhost.exe --headless`, and its arguments start `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <script>`. Its window style is minimized and it is not activated.
- Any stale result file is removed before the shortcut is written, so a result from an earlier run is never returned.
- The function waits for the result file and then 300 ms more, so a script that is still flushing its file is read whole.
- It throws when the script does not exist, and when no result appears within `-WaitSeconds`.
- Why a headless console: a visible console takes the foreground. A `.cmd` file does. So does a shortcut to `powershell.exe` set to hidden, on a system where Windows Terminal is the default terminal, because Terminal opens its own window for the console and ignores both settings.
- A console with no window can still take focus back from a caller that is holding it. A script that must not disturb the owner's work should sample the foreground while it runs; the ForegroundSampler package does that.

## Tests

The tests use Pester 5 or later and replace the shortcut writer, `Start-Process` and the wait:

```powershell
Invoke-Pester ./packages/run-as-user-shortcut/tests
```

## License

MIT
