#Requires -Version 5.1
Set-StrictMode -Version Latest

# Samples the foreground window (Windows only). It reads the window and never acts on it.
# A test replaces Get-ForegroundSample, so the logic runs without a desktop.

if (-not ('UppercutLabs.ForegroundSampler.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace UppercutLabs.ForegroundSampler {
    public static class NativeMethods {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
    }
}
'@
}

function Get-ForegroundSample {
    # One reading: the window handle, its process id and its title.
    $handle = [UppercutLabs.ForegroundSampler.NativeMethods]::GetForegroundWindow()
    $processId = 0
    [void][UppercutLabs.ForegroundSampler.NativeMethods]::GetWindowThreadProcessId($handle, [ref]$processId)
    $title = New-Object System.Text.StringBuilder 256
    [void][UppercutLabs.ForegroundSampler.NativeMethods]::GetWindowText($handle, $title, 256)
    [pscustomobject]@{
        Handle    = $handle
        ProcessId = [int]$processId
        Title     = $title.ToString()
    }
}

function Watch-Foreground {
    <#
    .SYNOPSIS
    Records the foreground window every 100 ms until a stop file appears or the time runs out.
    .DESCRIPTION
    Writes one JSON line when the foreground window or its process changes (and one for the first
    reading), then an end line with the sample count. The file is UTF-8 without a byte order mark.
    The run stops when -StopFile exists or -Seconds has passed, whichever comes first.

    With -App, a change that puts that executable in front counts as an app-in-front event. The
    console count (Windows Terminal, conhost, OpenConsole) is reported beside it, so a console that
    appears during a step can be told from the owner switching to a terminal. Read the console count
    by its times in the file. Passed is $false when the app came to the front at least once.
    .PARAMETER Out
    The JSON lines file to write.
    .PARAMETER StopFile
    The run ends when this path exists. Remove it before the run that should use it.
    .PARAMETER Seconds
    The longest the run may last. Defaults to 600.
    .PARAMETER App
    Optional. The full path of the executable that must not come to the front.
    .OUTPUTS
    An object with Out, Samples, App, AppInFront, ConsoleInFront and Passed.
    .EXAMPLE
    Watch-Foreground -Out .\focus.jsonl -StopFile .\focus.stop -Seconds 900 -App 'C:\Apps\Example\Example.exe'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Out,
        [Parameter(Mandatory = $true)][string]$StopFile,
        [int]$Seconds = 600,
        [string]$App
    )
    $writer = [System.IO.StreamWriter]::new($Out, $true, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    $last = ''
    $samples = 0
    $appInFront = 0
    $consoleInFront = 0
    $deadline = (Get-Date).AddSeconds($Seconds)
    try {
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $StopFile)) {
            $sample = Get-ForegroundSample
            $samples++
            $key = "$($sample.Handle)|$($sample.ProcessId)"
            if ($key -ne $last) {
                $path = ''
                try { $path = (Get-Process -Id $sample.ProcessId -ErrorAction Stop).Path } catch {}
                $line = [ordered]@{
                    t    = (Get-Date).ToString('o')
                    hwnd = [int64]$sample.Handle
                    pid  = [int]$sample.ProcessId
                    path = $path
                    title = $sample.Title
                }
                $writer.WriteLine(($line | ConvertTo-Json -Compress))
                if ($App -and $path -and ($path -ieq $App)) { $appInFront++ }
                if ($path -match '(WindowsTerminal|conhost|OpenConsole)\.exe$') { $consoleInFront++ }
                $last = $key
            }
            Start-Sleep -Milliseconds 100
        }
        $end = [ordered]@{ t = (Get-Date).ToString('o'); end = $true; samples = $samples }
        if ($App) { $end['app'] = $App; $end['appInFront'] = $appInFront; $end['consoleInFront'] = $consoleInFront }
        $writer.WriteLine(($end | ConvertTo-Json -Compress))
    } finally {
        $writer.Close()
    }
    [pscustomobject]@{
        Out            = $Out
        Samples        = $samples
        App            = $App
        AppInFront     = $appInFront
        ConsoleInFront = $consoleInFront
        Passed         = ((-not $App) -or ($appInFront -eq 0))
    }
}

Export-ModuleMember -Function Watch-Foreground
