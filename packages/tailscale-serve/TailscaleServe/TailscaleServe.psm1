#Requires -Version 5.1
Set-StrictMode -Version Latest

# Manages path mappings in Tailscale Serve. Only `tailscale serve` is ever run, never
# `tailscale funnel`, and every change is refused when Funnel is on for the port.
# All calls to the CLI go through Invoke-TsNative, which is the one place a test replaces.

function Get-TsProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-TsPropertyList {
    param($Object)
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties)
}

function Resolve-TsExecutable {
    param([string]$Executable)
    if ($Executable) { return $Executable }
    foreach ($name in 'tailscale', 'tailscale.exe') {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    $macApp = '/Applications/Tailscale.app/Contents/MacOS/Tailscale'
    if (Test-Path -LiteralPath $macApp) { return $macApp }
    throw 'The tailscale CLI was not found on PATH. Pass -Executable with its full path.'
}

function Invoke-TsNative {
    <#
    .SYNOPSIS
    Runs the tailscale CLI and returns its exit code and output without throwing.
    .OUTPUTS
    An object with ExitCode, Output (standard output lines) and ErrorOutput (standard error lines).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $standardOutput = New-Object System.Collections.Generic.List[string]
    $standardError = New-Object System.Collections.Generic.List[string]
    $previousPreference = $ErrorActionPreference
    try {
        # Native stderr must not become a terminating error before the exit code is read.
        $ErrorActionPreference = 'Continue'
        foreach ($item in (& $Executable @Arguments 2>&1)) {
            if ($item -is [System.Management.Automation.ErrorRecord]) { $standardError.Add([string]$item) }
            else { $standardOutput.Add([string]$item) }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    [pscustomobject]@{
        ExitCode    = $exitCode
        Output      = $standardOutput.ToArray()
        ErrorOutput = $standardError.ToArray()
    }
}

function Invoke-TsChecked {
    param([string]$Executable, [string[]]$Arguments)
    Write-Verbose "tailscale $($Arguments -join ' ')"
    $result = Invoke-TsNative -Executable $Executable -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $detail = (@($result.ErrorOutput) + @($result.Output) | Where-Object { $_ }) -join ' '
        throw "tailscale $($Arguments -join ' ') failed with exit code $($result.ExitCode). $detail".TrimEnd()
    }
    $result
}

function Get-TsServeConfig {
    <#
    .SYNOPSIS
    Reads the Serve configuration with `tailscale serve status --json`.
    .DESCRIPTION
    Throws when the CLI fails or prints something that is not JSON, so a caller never acts on a guess.
    An empty configuration comes back as an object with no properties.
    #>
    [CmdletBinding()]
    param([string]$Executable)
    $exe = Resolve-TsExecutable $Executable
    $result = Invoke-TsNative -Executable $exe -Arguments @('serve', 'status', '--json')
    if ($result.ExitCode -ne 0) {
        throw "Could not read the Tailscale Serve configuration (exit code $($result.ExitCode)). Nothing was changed."
    }
    $text = (@($result.Output) -join "`n").Trim()
    if (-not $text) { return [pscustomobject]@{} }
    try {
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw 'The Tailscale Serve status was not valid JSON. Nothing was changed.'
    }
}

function Assert-TsNoFunnel {
    <#
    .SYNOPSIS
    Throws when Funnel is enabled on an HTTPS port, because Serve paths there would be public.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [ValidateRange(1, 65535)][int]$HttpsPort = 443
    )
    foreach ($entry in @(Get-TsPropertyList (Get-TsProperty $Config 'AllowFunnel'))) {
        if ($entry.Value -eq $true -and $entry.Name -like "*:$HttpsPort") {
            throw "Funnel is enabled on HTTPS port $HttpsPort ($($entry.Name)). Serve paths there would be public, so nothing was changed."
        }
    }
}

function Test-TsSameMount {
    param([string]$Left, [string]$Right)
    return $Left.TrimEnd('/') -ceq $Right.TrimEnd('/')
}

function Test-TsSameTarget {
    param([string]$Left, [string]$Right)
    return $Left.TrimEnd('/') -ieq $Right.TrimEnd('/')
}

function Get-TsServePath {
    <#
    .SYNOPSIS
    Lists the path mappings in a Serve configuration.
    .DESCRIPTION
    Returns one object per mapping with HostPort, HttpsPort, Mount, Kind (Proxy, Path, Text, Redirect or Other)
    and Target. -Path matches a mount with or without a trailing slash.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [ValidateRange(0, 65535)][int]$HttpsPort = 0,
        $Config,
        [string]$Executable
    )
    if ($null -eq $Config) { $Config = Get-TsServeConfig -Executable $Executable }
    foreach ($web in @(Get-TsPropertyList (Get-TsProperty $Config 'Web'))) {
        $portMatch = [regex]::Match($web.Name, ':(\d+)$')
        $port = if ($portMatch.Success) { [int]$portMatch.Groups[1].Value } else { 0 }
        if ($HttpsPort -ne 0 -and $port -ne $HttpsPort) { continue }
        foreach ($handler in @(Get-TsPropertyList (Get-TsProperty $web.Value 'Handlers'))) {
            if ($Path -and -not (Test-TsSameMount $handler.Name $Path)) { continue }
            $kind = 'Other'
            $target = $null
            foreach ($candidate in 'Proxy', 'Path', 'Text', 'Redirect') {
                $value = Get-TsProperty $handler.Value $candidate
                if ($value) { $kind = $candidate; $target = [string]$value; break }
            }
            [pscustomobject]@{
                HostPort  = $web.Name
                HttpsPort = $port
                Mount     = $handler.Name
                Kind      = $kind
                Target    = $target
            }
        }
    }
}

function Get-TsServeMappingTarget {
    <#
    .SYNOPSIS
    Reads the proxy target of a path from the text form of `tailscale serve status`.
    .DESCRIPTION
    For old CLIs that have no --json. Prefer Get-TsServePath. Returns $null when the path is absent
    and throws when the status lists it more than once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StatusText,
        [Parameter(Mandatory = $true)][ValidatePattern('^/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]*$')][string]$Path
    )
    $pattern = "(?m)^\s*\|--\s+$([regex]::Escape($Path))\s+proxy\s+(\S+)\s*$"
    $found = [regex]::Matches($StatusText, $pattern)
    if ($found.Count -gt 1) { throw "Tailscale Serve status contains more than one mapping for '$Path'." }
    if ($found.Count -eq 0) { return $null }
    return $found[0].Groups[1].Value
}

function Assert-TsOtherMountsUnchanged {
    param($Before, $After, [string]$Mount, [int]$HttpsPort)
    $format = {
        param($Items)
        @($Items | Where-Object { $_.HttpsPort -eq $HttpsPort -and -not (Test-TsSameMount $_.Mount $Mount) } |
            ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.HostPort, $_.Mount, $_.Kind, $_.Target } | Sort-Object)
    }
    $beforeText = (& $format $Before) -join "`n"
    $afterText = (& $format $After) -join "`n"
    if ($beforeText -ne $afterText) {
        throw "Another Serve mapping on port $HttpsPort changed while '$Mount' was being updated. Inspect it with Get-TsServePath before going on."
    }
}

function Add-TsServePath {
    <#
    .SYNOPSIS
    Maps a path on the tailnet HTTPS address to a local target, tailnet only.
    .DESCRIPTION
    Idempotent: when the path already proxies to the target nothing is run and Changed is $false.
    A path that points somewhere else is left alone unless -Force is given. Refuses to run when Funnel is on
    for the port. Afterwards it reads the configuration back and confirms the mapping and that no other
    mapping on the port changed. -RequireRoot refuses to act unless the root path proxies to that target.
    Use -HttpsPort and -Path / to give a service its own HTTPS port.
    .OUTPUTS
    An object with Path, HttpsPort, Target, Changed and Action (Added, Updated or Unchanged).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('^/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]*$')][string]$Path,
        [Parameter(Mandatory = $true, Position = 1)][ValidatePattern('^https?://\S+$')][string]$Target,
        [ValidateRange(1, 65535)][int]$HttpsPort = 443,
        [string]$RequireRoot,
        [switch]$Force,
        [string]$Executable
    )
    $exe = Resolve-TsExecutable $Executable
    $before = Get-TsServeConfig -Executable $exe
    Assert-TsNoFunnel -Config $before -HttpsPort $HttpsPort

    if ($RequireRoot) {
        $root = @(Get-TsServePath -Config $before -Path '/' -HttpsPort $HttpsPort)
        $rootTarget = if ($root.Count -eq 1 -and $root[0].Kind -eq 'Proxy') { $root[0].Target } else { $null }
        if (-not $rootTarget -or -not (Test-TsSameTarget $rootTarget $RequireRoot)) {
            $observed = if ($rootTarget) { $rootTarget } else { '<absent>' }
            throw "Expected the root mapping '/ -> $RequireRoot' on port $HttpsPort, observed '/ -> $observed'. Serve was left unchanged."
        }
    }

    $existing = @(Get-TsServePath -Config $before -Path $Path -HttpsPort $HttpsPort)
    if ($existing.Count -gt 1) {
        throw "More than one Serve mapping matches '$Path' on port $HttpsPort. Serve was left unchanged."
    }
    $mount = $Path
    $action = 'Added'
    if ($existing.Count -eq 1) {
        $mount = $existing[0].Mount
        if ($existing[0].Kind -eq 'Proxy' -and (Test-TsSameTarget $existing[0].Target $Target)) {
            return [pscustomobject]@{ Path = $mount; HttpsPort = $HttpsPort; Target = $existing[0].Target; Changed = $false; Action = 'Unchanged' }
        }
        if (-not $Force) {
            $now = if ($existing[0].Target) { "$($existing[0].Kind) $($existing[0].Target)" } else { $existing[0].Kind }
            throw "The Serve path '$mount' on port $HttpsPort already maps to $now. Use -Force to replace it. It was left unchanged."
        }
        $action = 'Updated'
    }

    if (-not $PSCmdlet.ShouldProcess("$mount on HTTPS port $HttpsPort", "Map to $Target")) { return }
    $null = Invoke-TsChecked -Executable $exe -Arguments @('serve', '--bg', '--yes', "--https=$HttpsPort", "--set-path=$mount", $Target)

    $after = Get-TsServeConfig -Executable $exe
    Assert-TsNoFunnel -Config $after -HttpsPort $HttpsPort
    $confirmed = @(Get-TsServePath -Config $after -Path $mount -HttpsPort $HttpsPort)
    if ($confirmed.Count -ne 1 -or $confirmed[0].Kind -ne 'Proxy' -or -not (Test-TsSameTarget $confirmed[0].Target $Target)) {
        $observed = if ($confirmed.Count -eq 1 -and $confirmed[0].Target) { $confirmed[0].Target } else { '<absent>' }
        throw "Tailscale accepted the command, but '$mount -> $Target' was not confirmed (observed '$observed')."
    }
    Assert-TsOtherMountsUnchanged -Before @(Get-TsServePath -Config $before) -After @(Get-TsServePath -Config $after) -Mount $mount -HttpsPort $HttpsPort
    [pscustomobject]@{ Path = $mount; HttpsPort = $HttpsPort; Target = $confirmed[0].Target; Changed = $true; Action = $action }
}

function Remove-TsServePath {
    <#
    .SYNOPSIS
    Removes one path mapping and nothing else.
    .DESCRIPTION
    Idempotent: an absent path gives Changed $false. The root path is refused unless -AllowRoot is given.
    Afterwards it confirms the path is gone and that no other mapping on the port changed.
    .OUTPUTS
    An object with Path, HttpsPort, Changed and Action (Removed or Absent).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('^/(?:[A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]*$')][string]$Path,
        [ValidateRange(1, 65535)][int]$HttpsPort = 443,
        [switch]$AllowRoot,
        [string]$Executable
    )
    if ($Path -eq '/' -and -not $AllowRoot) {
        throw "Refusing to remove the root path. Pass -AllowRoot if the whole port should stop serving."
    }
    $exe = Resolve-TsExecutable $Executable
    $before = Get-TsServeConfig -Executable $exe
    Assert-TsNoFunnel -Config $before -HttpsPort $HttpsPort

    $existing = @(Get-TsServePath -Config $before -Path $Path -HttpsPort $HttpsPort)
    if ($existing.Count -eq 0) {
        return [pscustomobject]@{ Path = $Path; HttpsPort = $HttpsPort; Changed = $false; Action = 'Absent' }
    }
    if ($existing.Count -gt 1) {
        throw "More than one Serve mapping matches '$Path' on port $HttpsPort. Serve was left unchanged."
    }
    $mount = $existing[0].Mount
    if (-not $PSCmdlet.ShouldProcess("$mount on HTTPS port $HttpsPort", 'Remove the Serve mapping')) { return }
    $null = Invoke-TsChecked -Executable $exe -Arguments @('serve', "--https=$HttpsPort", "--set-path=$mount", 'off')

    $after = Get-TsServeConfig -Executable $exe
    $left = @(Get-TsServePath -Config $after -Path $mount -HttpsPort $HttpsPort)
    if ($left.Count -gt 0) {
        throw "The Serve path '$mount' is still present after removal (target '$($left[0].Target)')."
    }
    Assert-TsOtherMountsUnchanged -Before @(Get-TsServePath -Config $before) -After @(Get-TsServePath -Config $after) -Mount $mount -HttpsPort $HttpsPort
    [pscustomobject]@{ Path = $mount; HttpsPort = $HttpsPort; Changed = $true; Action = 'Removed' }
}

Export-ModuleMember -Function Get-TsServeConfig, Get-TsServePath, Add-TsServePath, Remove-TsServePath, Assert-TsNoFunnel, Get-TsServeMappingTarget, Invoke-TsNative
