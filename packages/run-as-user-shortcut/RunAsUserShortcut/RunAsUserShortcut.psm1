#Requires -Version 5.1
Set-StrictMode -Version Latest

# Windows only. Explorer starts a shortcut outside any packaged (MSIX) app, so a script started through
# it reads and writes the owner's normal %APPDATA% and %LOCALAPPDATA%. An agent's own shell inside a
# packaged app does not: its writes are redirected into the package.

function New-LaunchShortcut {
    # Writes the .lnk. A test replaces this, so no shortcut is needed to run the tests.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.WindowStyle = 7   # minimized, not activated
    $shortcut.Save()
}

function Invoke-InUserContext {
    <#
    .SYNOPSIS
    Runs a PowerShell script in the owner's normal shell, in a console with no window, and returns the
    result file the script writes.
    .DESCRIPTION
    Writes a shortcut that starts powershell.exe inside conhost.exe --headless, starts it through Explorer,
    waits until the script has written -ResultPath, and returns that file's lines.

    Why a headless console. Any visible console takes the foreground. A .cmd file does, and so does a
    shortcut to powershell.exe that is minimized and hidden on a system where Windows Terminal is the
    default terminal: Terminal opens its own window for the console and ignores both settings. A
    console with no window avoids that. Any app started earlier can then hold the right to take the
    foreground when Windows activates another window, so a caller that must not disturb the owner's
    work should also sample the foreground (see the ForegroundSampler package).

    The script receives no arguments. Pass its inputs in a file it reads, as installed checks do.
    .PARAMETER ScriptPath
    The .ps1 file to run. It must exist.
    .PARAMETER WorkingDirectory
    The working directory of the shortcut, usually the repository root.
    .PARAMETER ResultPath
    The file the script writes when it is done. It is removed before the script starts, so a stale
    result is never returned. Its folder is created if needed.
    .PARAMETER ShortcutPath
    Optional. Where the .lnk is written. Defaults to run-as-user.lnk beside the result file.
    .PARAMETER WaitSeconds
    How long to wait for the result file. Defaults to 180.
    .OUTPUTS
    The lines of the result file, as Get-Content returns them.
    .EXAMPLE
    Invoke-InUserContext -ScriptPath .\scripts\install.ps1 -WorkingDirectory $repo -ResultPath $repo\qa\evidence\install-log.txt
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [string]$ShortcutPath,
        [int]$WaitSeconds = 180
    )
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "No script at $ScriptPath" }
    $target = (Resolve-Path -LiteralPath $ScriptPath).Path
    $result = [System.IO.Path]::GetFullPath($ResultPath)
    $resultFolder = Split-Path -Parent $result
    New-Item -ItemType Directory -Force -Path $resultFolder | Out-Null
    if (-not $ShortcutPath) { $ShortcutPath = Join-Path $resultFolder 'run-as-user.lnk' }

    Remove-Item -LiteralPath $result -ErrorAction SilentlyContinue
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "--headless `"$powershell`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`""
    New-LaunchShortcut -ShortcutPath $ShortcutPath `
        -TargetPath (Join-Path $env:SystemRoot 'System32\conhost.exe') `
        -Arguments $arguments `
        -WorkingDirectory $WorkingDirectory
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "`"$ShortcutPath`""

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while (-not (Test-Path -LiteralPath $result) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path -LiteralPath $result)) { throw "No result at $result after $WaitSeconds s." }
    Start-Sleep -Milliseconds 300
    Get-Content -LiteralPath $result
}

Export-ModuleMember -Function Invoke-InUserContext
