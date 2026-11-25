#Requires -Version 5.1
Set-StrictMode -Version Latest

# Windows only. Starts a program without letting its window take keyboard focus, and keeps its windows
# where the caller says without activating them. It never calls SetForegroundWindow, sends no input and
# makes no window topmost. Every native call goes through one of the small functions below that a test
# replaces (Start-NoActProcess, Start-NoActDesktopProcess, Set-NoActWindowPosition, Get-NoActWindowList,
# Get-NoActForegroundProcessId, Set-NoActErrorMode), so the logic runs without a desktop.

$script:NoActNativeReady = $false
$script:NoActDisplay = $null

function Initialize-NoActNative {
    # Compiles the P/Invoke class on first use, so importing the module on a system without Windows works.
    if ($script:NoActNativeReady) { return }
    if (-not ('UppercutLabs.NoActivate.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace UppercutLabs.NoActivate {
    public static class NativeMethods {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct STARTUPINFO {
            public int cb; public string reserved; public string desktop; public string title;
            public int x, y, xSize, ySize, xChars, yChars, fillAttribute, flags;
            public short showWindow, reserved2;
            public IntPtr reserved3, stdInput, stdOutput, stdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION { public IntPtr process, thread; public int processId, threadId; }
        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
            uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
        [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
        [DllImport("kernel32.dll")] static extern uint SetErrorMode(uint mode);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr devMode, uint flags, uint access, IntPtr sa);
        [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
        [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        delegate bool EnumProc(IntPtr h, IntPtr p);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr p);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

        public static uint SetMode(uint mode) { return SetErrorMode(mode); }

        // STARTF_USESHOWWINDOW with the given show command: 4 = SW_SHOWNOACTIVATE, 7 = SW_SHOWMINNOACTIVE.
        public static int Start(string exe, string commandLine, string dir, uint flags, short show) {
            STARTUPINFO si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(si); si.flags = 0x1; si.showWindow = show;
            PROCESS_INFORMATION pi;
            if (!CreateProcessW(exe, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, dir, ref si, out pi))
                throw new System.ComponentModel.Win32Exception();
            CloseHandle(pi.thread); CloseHandle(pi.process);
            return pi.processId;
        }

        // Runs the program on a new desktop that is never switched to. Returns "exit <code> pid <pid>"
        // or "timeout, killed pid <pid>" (the program is ended by its own handle).
        public static string RunOnDesktop(string exe, string commandLine, string dir, string desktop, int timeoutMs) {
            IntPtr d = CreateDesktopW(desktop, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, IntPtr.Zero);
            if (d == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            try {
                STARTUPINFO si = new STARTUPINFO();
                si.cb = Marshal.SizeOf(si); si.desktop = "WinSta0\\" + desktop; si.flags = 0x1; si.showWindow = 4;
                PROCESS_INFORMATION pi;
                if (!CreateProcessW(exe, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, 0, IntPtr.Zero, dir, ref si, out pi))
                    throw new System.ComponentModel.Win32Exception();
                CloseHandle(pi.thread);
                try {
                    if (WaitForSingleObject(pi.process, (uint)timeoutMs) != 0) {
                        TerminateProcess(pi.process, 1);
                        WaitForSingleObject(pi.process, 10000);
                        return "timeout, killed pid " + pi.processId;
                    }
                    uint code; GetExitCodeProcess(pi.process, out code);
                    return "exit " + code + " pid " + pi.processId;
                } finally { CloseHandle(pi.process); }
            } finally { CloseDesktop(d); }
        }

        // Visible top-level windows of a process, as groups of five numbers: handle, left, top, right, bottom.
        public static long[] Windows(uint pid) {
            SetProcessDpiAwarenessContext((IntPtr)(-4));
            List<long> found = new List<long>();
            EnumWindows(delegate (IntPtr h, IntPtr p) {
                uint owner; GetWindowThreadProcessId(h, out owner);
                if (owner != pid || !IsWindowVisible(h)) return true;
                RECT r; GetWindowRect(h, out r);
                found.Add(h.ToInt64()); found.Add(r.Left); found.Add(r.Top); found.Add(r.Right); found.Add(r.Bottom);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }

        // SWP_NOZORDER | SWP_NOACTIVATE: the window moves and nothing else about it changes.
        public static void Place(long handle, int x, int y, int w, int h) {
            SetWindowPos(new IntPtr(handle), IntPtr.Zero, x, y, w, h, 0x0004 | 0x0010);
        }

        public static uint ForegroundPid() {
            uint pid = 0; IntPtr h = GetForegroundWindow();
            if (h != IntPtr.Zero) GetWindowThreadProcessId(h, out pid);
            return pid;
        }
    }
}
'@
    }
    $script:NoActNativeReady = $true
}

function Set-NoActErrorMode {
    param([uint32]$Mode)
    Initialize-NoActNative
    [void][UppercutLabs.NoActivate.NativeMethods]::SetMode($Mode)
}

function Start-NoActProcess {
    param([string]$Executable, [string]$CommandLine, [string]$WorkingDirectory, [uint32]$CreationFlags, [int]$Show)
    Initialize-NoActNative
    [UppercutLabs.NoActivate.NativeMethods]::Start($Executable, $CommandLine, $WorkingDirectory, $CreationFlags, [int16]$Show)
}

function Start-NoActDesktopProcess {
    param([string]$Executable, [string]$CommandLine, [string]$WorkingDirectory, [string]$Desktop, [int]$TimeoutMilliseconds)
    Initialize-NoActNative
    [UppercutLabs.NoActivate.NativeMethods]::RunOnDesktop($Executable, $CommandLine, $WorkingDirectory, $Desktop, $TimeoutMilliseconds)
}

function Get-NoActWindowList {
    param([int]$ProcessId)
    Initialize-NoActNative
    $numbers = [UppercutLabs.NoActivate.NativeMethods]::Windows([uint32]$ProcessId)
    for ($i = 0; $i -lt $numbers.Count; $i += 5) {
        [pscustomobject]@{
            Handle = [IntPtr][long]$numbers[$i]
            Left   = [int]$numbers[$i + 1]
            Top    = [int]$numbers[$i + 2]
            Right  = [int]$numbers[$i + 3]
            Bottom = [int]$numbers[$i + 4]
        }
    }
}

function Set-NoActWindowPosition {
    param([IntPtr]$Handle, [int]$X, [int]$Y, [int]$Width, [int]$Height)
    Initialize-NoActNative
    [UppercutLabs.NoActivate.NativeMethods]::Place([long]$Handle, $X, $Y, $Width, $Height)
}

function Get-NoActForegroundProcessId {
    Initialize-NoActNative
    [int][UppercutLabs.NoActivate.NativeMethods]::ForegroundPid()
}

function ConvertTo-NoActCommandLine {
    <#
    .SYNOPSIS
    Builds the command line CreateProcess expects: the program and each argument in double quotes.
    .DESCRIPTION
    Backslashes before a quote, and at the end of an argument, are doubled and embedded quotes are escaped,
    so a program that parses its line the usual way (the C runtime, .NET) reads back exactly the arguments
    that were given. An empty argument stays an empty quoted argument.
    .EXAMPLE
    ConvertTo-NoActCommandLine -Executable 'C:\Apps\a.exe' -ArgumentList @('one', 'two words', 'C:\dir\')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$ArgumentList = @()
    )
    $quote = {
        param([string]$Text)
        $escaped = [regex]::Replace($Text, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }
    $parts = @(& $quote $Executable)
    foreach ($argument in @($ArgumentList)) { $parts += (& $quote ([string]$argument)) }
    $parts -join ' '
}

function Start-NoActivate {
    <#
    .SYNOPSIS
    Starts a program so its first window is shown without taking keyboard focus, and returns the Process.
    .DESCRIPTION
    Uses CreateProcess with STARTUPINFO wShowWindow set to SW_SHOWNOACTIVATE (4). Programs that choose their
    own show command are told not to activate by environment variables that SDL 2 and SDL 3 read. Those
    variables are set only for the launch and restored afterwards, so they do not reach later children of the
    caller.

    The show flags are not airtight. Some programs still take the foreground now and then; for those, give the
    window an unfocusable style inside the program itself, or use Invoke-OnPrivateDesktop.

    By default the child inherits SEM_FAILCRITICALERRORS, SEM_NOGPFAULTERRORBOX and SEM_NOOPENFILEERRORBOX, so a
    missing DLL or a crash fails silently (read the exit code and the logs) instead of leaving a modal error box
    on the owner's screen. -AllowErrorDialogs opts out. The setting stays on the calling process.
    .PARAMETER Executable
    The program to start. Its full path.
    .PARAMETER ArgumentList
    Arguments, one array item each. Each is quoted for you.
    .PARAMETER WorkingDirectory
    Defaults to the folder of the program.
    .PARAMETER NoConsole
    Creates the process with CREATE_NO_WINDOW, so a console program gets no console window at all.
    .PARAMETER Mute
    Starts an SDL program with its "disk" audio driver writing to the null device: silent, but still a valid
    audio device. A value already set in the environment for SDL_AUDIO_DRIVER or SDL_AUDIO_DISK_OUTPUT_FILE wins.
    .PARAMETER Show
    4 (SW_SHOWNOACTIVATE, the default) or 7 (SW_SHOWMINNOACTIVE, shown minimized).
    .OUTPUTS
    System.Diagnostics.Process. Its handle is opened before it is returned, so ExitCode still reads after the
    process has exited.
    .EXAMPLE
    $p = Start-NoActivate -Executable 'C:\Apps\Example\Example.exe' -ArgumentList @('--windowed', 'my file.dat') -Mute
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Alias('Exe')][string]$Executable,
        [Alias('ArgList')][string[]]$ArgumentList = @(),
        [Alias('WorkDir')][string]$WorkingDirectory,
        [switch]$NoConsole,
        [switch]$AllowErrorDialogs,
        [switch]$Mute,
        [ValidateSet(4, 7)][int]$Show = 4
    )
    if (-not $AllowErrorDialogs) { Set-NoActErrorMode -Mode 0x8003 }
    $variables = [ordered]@{
        SDL_WINDOW_ACTIVATE_WHEN_SHOWN      = '0'   # SDL 3
        SDL_WINDOW_ACTIVATE_WHEN_RAISED     = '0'   # SDL 3
        SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN = '1'   # SDL 2
    }
    if ($Mute) {
        if (-not [Environment]::GetEnvironmentVariable('SDL_AUDIO_DRIVER', 'Process')) { $variables['SDL_AUDIO_DRIVER'] = 'disk' }
        if (-not [Environment]::GetEnvironmentVariable('SDL_AUDIO_DISK_OUTPUT_FILE', 'Process')) { $variables['SDL_AUDIO_DISK_OUTPUT_FILE'] = 'NUL' }
    }
    $saved = @{}
    foreach ($name in $variables.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $variables[$name], 'Process')
    }
    try {
        if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $Executable }
        $commandLine = ConvertTo-NoActCommandLine -Executable $Executable -ArgumentList $ArgumentList
        $flags = if ($NoConsole) { 0x08000000 } else { 0 }
        $processId = Start-NoActProcess -Executable $Executable -CommandLine $commandLine -WorkingDirectory $WorkingDirectory -CreationFlags $flags -Show $Show
        $process = [System.Diagnostics.Process]::GetProcessById([int]$processId)
        [void]$process.Handle
        $process
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

function Invoke-OnPrivateDesktop {
    <#
    .SYNOPSIS
    Runs a program on a Windows desktop that is never switched to, and waits for it.
    .DESCRIPTION
    Creates a desktop (CreateDesktop) and starts the program on it (STARTUPINFO lpDesktop), so none of its
    windows or dialogs can reach the owner's desktop, focus or input. Use it where Start-NoActivate is not
    enough. It is not a drop-in for every program: some exit at once, or idle, when they find no usable display.

    Blocks until the program exits or -TimeoutSeconds passes, and then ends it by its own handle.
    .OUTPUTS
    The string "exit <code> pid <pid>", or "timeout, killed pid <pid>".
    .EXAMPLE
    Invoke-OnPrivateDesktop -Executable 'C:\Apps\Example\Example.exe' -ArgumentList @('--batch') -Desktop 'example-run' -TimeoutSeconds 300
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][Alias('Exe')][string]$Executable,
        [Alias('ArgList')][string[]]$ArgumentList = @(),
        [Alias('WorkDir')][string]$WorkingDirectory,
        [ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Desktop = 'noactivate-private',
        [ValidateRange(1, 86400)][Alias('TimeoutSec')][int]$TimeoutSeconds = 600
    )
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $Executable }
    $commandLine = ConvertTo-NoActCommandLine -Executable $Executable -ArgumentList $ArgumentList
    Start-NoActDesktopProcess -Executable $Executable -CommandLine $commandLine -WorkingDirectory $WorkingDirectory -Desktop $Desktop -TimeoutMilliseconds ($TimeoutSeconds * 1000)
}

function Set-NoActDisplay {
    <#
    .SYNOPSIS
    Sets the display rectangle that Move-ToDisplay and Wait-Pinned use when none is passed, in physical pixels.
    .DESCRIPTION
    The module holds no screen layout. Set the rectangle once per session, or pass -Display each time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][ValidateRange(1, 100000)][int]$Width,
        [Parameter(Mandatory = $true)][ValidateRange(1, 100000)][int]$Height
    )
    $script:NoActDisplay = @{ x = $X; y = $Y; w = $Width; h = $Height }
}

function Get-NoActDisplay {
    <#
    .SYNOPSIS
    Returns the display rectangle from Set-NoActDisplay as a hashtable with x, y, w and h.
    #>
    [CmdletBinding()]
    param()
    if ($null -eq $script:NoActDisplay) {
        throw 'No display is set. Call Set-NoActDisplay -X -Y -Width -Height first, or pass -Display.'
    }
    @{ x = $script:NoActDisplay.x; y = $script:NoActDisplay.y; w = $script:NoActDisplay.w; h = $script:NoActDisplay.h }
}

function Get-NoActWindow {
    <#
    .SYNOPSIS
    Lists the visible top-level windows of a process, with their handle and screen rectangle.
    .DESCRIPTION
    Read only. Returns Handle, Left, Top, Right, Bottom, Width and Height in physical pixels, one object per window.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    foreach ($window in @(Get-NoActWindowList -ProcessId $ProcessId)) {
        [pscustomobject]@{
            Handle = $window.Handle
            Left   = $window.Left
            Top    = $window.Top
            Right  = $window.Right
            Bottom = $window.Bottom
            Width  = $window.Right - $window.Left
            Height = $window.Bottom - $window.Top
        }
    }
}

function Move-ToDisplay {
    <#
    .SYNOPSIS
    Moves a process's visible windows that sit outside the display onto it, without activating them.
    .DESCRIPTION
    A window already inside the rectangle is left alone. One outside is moved to 20 pixels inside the
    rectangle's top left corner and cut down to the rectangle's size if it is larger. The move uses
    SWP_NOZORDER and SWP_NOACTIVATE, so it changes neither the stacking order nor the focus.
    .PARAMETER Display
    A hashtable with x, y, w and h. Defaults to the rectangle from Set-NoActDisplay.
    .PARAMETER PassThru
    Returns the number of windows that were moved. Without it the function returns nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][Alias('ProcId')][int]$ProcessId,
        [Parameter(Position = 1)][hashtable]$Display,
        [switch]$PassThru
    )
    if ($null -eq $Display) { $Display = Get-NoActDisplay }
    foreach ($key in 'x', 'y', 'w', 'h') {
        if (-not $Display.ContainsKey($key)) { throw "The display needs x, y, w and h. Missing '$key'." }
    }
    $moved = 0
    foreach ($window in @(Get-NoActWindowList -ProcessId $ProcessId)) {
        $width = [Math]::Min($window.Right - $window.Left, $Display.w)
        $height = [Math]::Min($window.Bottom - $window.Top, $Display.h)
        $inside = $window.Left -ge $Display.x -and $window.Top -ge $Display.y -and
            $window.Right -le ($Display.x + $Display.w) -and $window.Bottom -le ($Display.y + $Display.h)
        if ($inside) { continue }
        Set-NoActWindowPosition -Handle $window.Handle -X ($Display.x + 20) -Y ($Display.y + 20) -Width $width -Height $height
        $moved++
    }
    if ($PassThru) { $moved }
}

function Wait-Pinned {
    <#
    .SYNOPSIS
    Keeps a process's windows on the display until it exits or the time runs out.
    .DESCRIPTION
    Calls Move-ToDisplay every -IntervalMilliseconds. Returns $true when the process has exited and $false
    when -TimeoutSeconds passed first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]$Process,
        [ValidateRange(0, 86400)][Alias('TimeoutSec')][int]$TimeoutSeconds = 20,
        [ValidateRange(1, 60000)][Alias('IntervalMs')][int]$IntervalMilliseconds = 100,
        [hashtable]$Display
    )
    if ($null -eq $Display) { $Display = Get-NoActDisplay }
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $end -and -not $Process.HasExited) {
        Move-ToDisplay -ProcessId $Process.Id -Display $Display
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
    [bool]$Process.HasExited
}

function Get-ForegroundPid {
    <#
    .SYNOPSIS
    The process id of the foreground window (read only), for proving a launch did not take focus.
    .DESCRIPTION
    Read it before and after a launch and compare. Returns 0 when there is no foreground window.
    #>
    [CmdletBinding()]
    param()
    Get-NoActForegroundProcessId
}

Export-ModuleMember -Function Start-NoActivate, Invoke-OnPrivateDesktop, Set-NoActDisplay, Get-NoActDisplay, Move-ToDisplay, Wait-Pinned, Get-NoActWindow, Get-ForegroundPid, ConvertTo-NoActCommandLine
