#Requires -Version 5.1
Set-StrictMode -Version Latest

# Manages path mappings and Tailscale Services (`svc:` names) in Tailscale Serve. Only `tailscale serve` (and
# `tailscale status` for the receipt) is ever run, never `tailscale funnel`. Path changes are refused when Funnel
# is on for the port; a Tailscale Service is a tailnet resource, so service mode never makes anything public.
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

# ---- Service mode (Tailscale Services, `svc:` names) ------------------------------------------------------


function ConvertTo-TsServiceTargetKey {
    param([string]$Target)
    $key = $Target.Trim().ToLowerInvariant()
    $key = $key -replace '^https?://', ''
    $key = $key -replace '^localhost:', '127.0.0.1:'
    return $key.TrimEnd('/')
}

function ConvertFrom-TsServiceConfigText {
    # The service configuration file is huJSON: comments and trailing commas are allowed.
    param([string]$Text)
    $clean = [regex]::Replace($Text, '(?m)^\s*//.*$', '')
    $clean = [regex]::Replace($clean, ',(\s*[}\]])', '$1')
    try { return ($clean | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'The Tailscale Service configuration was not valid JSON. Nothing was changed.' }
}

function Get-TsServiceConfig {
    <#
    .SYNOPSIS
    Reads Tailscale Service configuration with `tailscale serve get-config`.
    .DESCRIPTION
    Returns one object per service with Service, Advertised ($false only when the file says so) and Endpoints,
    each with Port, Protocol and Target. A service that has no configuration on this node returns nothing.
    Throws when the CLI fails or prints something that is not JSON, so a caller never acts on a guess.
    .PARAMETER Service
    A service name such as svc:example. Without it (or -All) every service on this node is listed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][ValidatePattern('(?-i)^svc:[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$Service,
        [switch]$All,
        [string]$Executable
    )
    $exe = Resolve-TsExecutable $Executable
    $arguments = if ($Service -and -not $All) { @('serve', 'get-config', "--service=$Service") } else { @('serve', 'get-config', '--all') }
    $result = Invoke-TsNative -Executable $exe -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        throw "Could not read the Tailscale Service configuration (exit code $($result.ExitCode)). Nothing was changed."
    }
    $text = (@($result.Output) -join "`n").Trim()
    if (-not $text) { return }
    $config = ConvertFrom-TsServiceConfigText $text
    foreach ($entry in @(Get-TsPropertyList (Get-TsProperty $config 'services'))) {
        if ($Service -and -not $All -and $entry.Name -ne $Service) { continue }
        $advertised = Get-TsProperty $entry.Value 'advertised'
        $endpoints = foreach ($endpoint in @(Get-TsPropertyList (Get-TsProperty $entry.Value 'endpoints'))) {
            $parts = $endpoint.Name -split ':', 2
            [pscustomobject]@{
                Port     = if ($parts.Count -eq 2 -and $parts[1] -match '^\d+$') { [int]$parts[1] } else { 0 }
                Protocol = $parts[0]
                Target   = [string]$endpoint.Value
            }
        }
        [pscustomobject]@{
            Service    = $entry.Name
            Advertised = if ($null -eq $advertised) { $true } else { [bool]$advertised }
            Endpoints  = @($endpoints)
        }
    }
}

function Get-TsServiceEndpointFor {
    param($Config, [int]$Port)
    if ($null -eq $Config) { return $null }
    $found = @($Config.Endpoints | Where-Object { $_.Port -eq $Port })
    if ($found.Count -eq 0) { return $null }
    return $found[0]
}

function Set-TsServeService {
    <#
    .SYNOPSIS
    Points a Tailscale Service at a local target and advertises this node as its host, tailnet only.
    .DESCRIPTION
    Runs `tailscale serve --service=<name> --https=<port> --yes <target>` then `tailscale serve advertise <name>`,
    and reads the service configuration back to confirm it. Idempotent: when the endpoint already maps to the
    target and the service is advertised, nothing is run and Changed is $false. A service that is configured but
    drained (not advertised) is advertised again and nothing else is touched.

    An endpoint that points somewhere else is left alone unless -Replace is given. -Reset drains and clears the
    whole service first (every endpoint on it, as `tailscale serve clear` does) and implies -Replace; use it when
    the service must start from nothing.

    The service itself (its name, port and tags) has to be defined in the tailnet first. This function configures
    the node that hosts it and never approves a host.
    .PARAMETER Service
    The service name, svc: and lower-case letters, digits and hyphens.
    .PARAMETER Target
    The local target: http://127.0.0.1:<port> or 127.0.0.1:<port> (localhost works too).
    .PARAMETER Port
    The port the service listens on, 443 by default.
    .PARAMETER Protocol
    Https (the default) or Http.
    .OUTPUTS
    An object with Service, Protocol, Port, Target, Changed, Action (Added, Updated, Advertised or Unchanged) and Advertised.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('(?-i)^svc:[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$Service,
        [Parameter(Mandatory = $true, Position = 1)][ValidatePattern('(?-i)^(?:https?://)?(?:127\.0\.0\.1|localhost):\d{1,5}(?:/\S*)?$')][string]$Target,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [ValidateSet('Https', 'Http')][string]$Protocol = 'Https',
        [switch]$Replace,
        [switch]$Reset,
        [switch]$NoAdvertise,
        [string]$Executable
    )
    $exe = Resolve-TsExecutable $Executable
    $flag = "--$($Protocol.ToLowerInvariant())=$Port"
    $before = @(Get-TsServiceConfig -Service $Service -Executable $exe) | Select-Object -First 1
    $endpoint = Get-TsServiceEndpointFor -Config $before -Port $Port
    $action = 'Added'
    $skipSet = $false
    if ($endpoint) {
        if ((ConvertTo-TsServiceTargetKey $endpoint.Target) -ceq (ConvertTo-TsServiceTargetKey $Target) -and -not $Reset) {
            if ($before.Advertised -or $NoAdvertise) {
                return [pscustomobject]@{ Service = $Service; Protocol = $Protocol; Port = $Port; Target = $endpoint.Target; Changed = $false; Action = 'Unchanged'; Advertised = $before.Advertised }
            }
            $action = 'Advertised'
            $skipSet = $true
        } elseif (-not ($Replace -or $Reset)) {
            throw "The Tailscale Service $Service already maps tcp:$Port to $($endpoint.Target). Use -Replace to point it at $Target, or -Reset to clear the service first. It was left unchanged."
        } else {
            $action = 'Updated'
        }
    }
    if (-not $PSCmdlet.ShouldProcess("$Service on $Protocol port $Port", "Map to $Target")) { return }

    if ($Reset -and $before) {
        $null = Invoke-TsChecked -Executable $exe -Arguments @('serve', 'drain', $Service)
        $null = Invoke-TsChecked -Executable $exe -Arguments @('serve', 'clear', $Service)
        if ($action -eq 'Advertised') { $action = 'Updated' }
        $skipSet = $false
    }
    if (-not $skipSet) {
        $null = Invoke-TsChecked -Executable $exe -Arguments @('serve', "--service=$Service", $flag, '--yes', $Target)
    }
    if (-not $NoAdvertise) {
        $null = Invoke-TsChecked -Executable $exe -Arguments @('serve', 'advertise', $Service)
    }

    $after = @(Get-TsServiceConfig -Service $Service -Executable $exe) | Select-Object -First 1
    $confirmed = Get-TsServiceEndpointFor -Config $after -Port $Port
    if (-not $confirmed -or (ConvertTo-TsServiceTargetKey $confirmed.Target) -cne (ConvertTo-TsServiceTargetKey $Target)) {
        $observed = if ($confirmed) { $confirmed.Target } else { '<absent>' }
        throw "Tailscale accepted the commands, but '$Service tcp:$Port -> $Target' was not confirmed (observed '$observed')."
    }
    if (-not $NoAdvertise -and -not $after.Advertised) {
        throw "Tailscale accepted the commands, but $Service is still not advertised by this node."
    }
    [pscustomobject]@{ Service = $Service; Protocol = $Protocol; Port = $Port; Target = $confirmed.Target; Changed = $true; Action = $action; Advertised = $after.Advertised }
}

function Remove-TsServeService {
    <#
    .SYNOPSIS
    Drains a Tailscale Service from this node and clears its configuration.
    .DESCRIPTION
    Idempotent: a service with no configuration on this node gives Changed $false. Drain stops new connections
    and lets existing ones finish. Afterwards the configuration is read back and must be gone.
    .OUTPUTS
    An object with Service, Changed and Action (Removed or Absent).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('(?-i)^svc:[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$Service,
        [string]$Executable
    )
    $exe = Resolve-TsExecutable $Executable
    $before = @(Get-TsServiceConfig -Service $Service -Executable $exe)
    if ($before.Count -eq 0) { return [pscustomobject]@{ Service = $Service; Changed = $false; Action = 'Absent' } }
    if (-not $PSCmdlet.ShouldProcess($Service, 'Drain and clear the Tailscale Service on this node')) { return }
    $null = Invoke-TsChecked -Executable $exe -Arguments @('serve', 'drain', $Service)
    $null = Invoke-TsChecked -Executable $exe -Arguments @('serve', 'clear', $Service)
    $left = @(Get-TsServiceConfig -Service $Service -Executable $exe)
    if ($left.Count -gt 0) { throw "The Tailscale Service $Service is still configured after removal." }
    [pscustomobject]@{ Service = $Service; Changed = $true; Action = 'Removed' }
}

function Get-TsServiceReceipt {
    <#
    .SYNOPSIS
    A read-only record of a service as this node serves it: the configuration, the other services, and the node.
    .DESCRIPTION
    Reads `serve get-config` for the service and for all services, and `tailscale status --json` for the node's
    id, host name and `service-host` capability. Changes nothing. With -Path the receipt is also written as
    UTF-8 JSON without a byte order mark. The receipt holds node identifiers, so keep it where the node's other
    records are kept.
    .OUTPUTS
    An object with Service, Config, Services, DeviceId, HostName, ServiceHost and ReadAt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidatePattern('(?-i)^svc:[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$Service,
        [string]$Path,
        [string]$Executable
    )
    $exe = Resolve-TsExecutable $Executable
    $config = @(Get-TsServiceConfig -Service $Service -Executable $exe) | Select-Object -First 1
    $services = @(Get-TsServiceConfig -All -Executable $exe | ForEach-Object { $_.Service })
    $statusResult = Invoke-TsNative -Executable $exe -Arguments @('status', '--json')
    if ($statusResult.ExitCode -ne 0) { throw "Could not read the Tailscale status (exit code $($statusResult.ExitCode))." }
    try { $status = (@($statusResult.Output) -join "`n") | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'The Tailscale status was not valid JSON.' }
    $self = Get-TsProperty $status 'Self'
    $capMap = Get-TsProperty $self 'CapMap'
    $receipt = [pscustomobject]@{
        Service     = $Service
        Config      = $config
        Services    = $services
        DeviceId    = Get-TsProperty $self 'ID'
        HostName    = Get-TsProperty $self 'HostName'
        ServiceHost = Get-TsProperty $capMap 'service-host'
        ReadAt      = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($Path) {
        $folder = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), ($receipt | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    }
    $receipt
}


Export-ModuleMember -Function Get-TsServeConfig, Get-TsServePath, Add-TsServePath, Remove-TsServePath, Assert-TsNoFunnel, Get-TsServeMappingTarget, Invoke-TsNative, Get-TsServiceConfig, Set-TsServeService, Remove-TsServeService, Get-TsServiceReceipt
