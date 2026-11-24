# TailscaleServe

A PowerShell module for Tailscale Serve, in two modes.

- **Path mode** adds, removes and lists path mappings on this node's HTTPS address. It reads the configuration with `tailscale serve status --json`, changes one mapping, reads the configuration back and confirms the result, and refuses to act on a port where Funnel is enabled.
- **Service mode** (version 0.2.0) points a [Tailscale Service](https://tailscale.com/docs/features/tailscale-services) (a `svc:` name with its own address) at a local target, advertises this node as its host, reads the service configuration back, and can write a receipt. It is the form where the stable name belongs to the service, not to a machine.

Both only ever run `tailscale serve` (and `tailscale status` for the receipt), never `tailscale funnel`, so nothing is made public.

## What runs where

Everything here is PowerShell. There is no Bash, and no part needs one.

| Part | Language | Runs on |
| --- | --- | --- |
| The `TailscaleServe` module | PowerShell | Windows PowerShell 5.1 and PowerShell 7 on Windows; PowerShell 7 on macOS and Linux |
| The tests | PowerShell with Pester 5 or later | the same systems. They replace the CLI with an in-memory stand-in, so Tailscale does not have to be installed |
| `tailscale` itself | the Tailscale command line | whatever system you manage. The module finds `tailscale` or `tailscale.exe` on `PATH`, then the macOS app's copy |

Commands in this README are PowerShell. On macOS and Linux start `pwsh` first; do not paste them into Bash.

## Install

From the PowerShell Gallery, once a release is published there:

```powershell
Install-PSResource TailscaleServe          # PSResourceGet, in PowerShell 7
Install-Module TailscaleServe -Scope CurrentUser   # PowerShellGet, in Windows PowerShell 5.1
```

From a clone of the repository:

```powershell
Import-Module ./packages/tailscale-serve/TailscaleServe/TailscaleServe.psd1
```

Or copy the `TailscaleServe` folder into a folder on `$env:PSModulePath` to import it by name.

## Example

```powershell
# Map https://machine.example.invalid/docs to a local server. Running it twice changes nothing the second time.
Add-TsServePath -Path /docs -Target http://127.0.0.1:8766/docs

# Only act if the root mapping is still the one this machine expects.
Add-TsServePath -Path /docs -Target http://127.0.0.1:8766/docs -RequireRoot http://127.0.0.1:8787

# Give a service its own HTTPS port.
Add-TsServePath -Path / -Target http://127.0.0.1:4420 -HttpsPort 8460

Get-TsServePath | Format-Table HostPort, Mount, Kind, Target
Remove-TsServePath -Path /docs

# Service mode: point the service svc:example at a local server and advertise this node as its host.
# The service has to be defined in the tailnet first; this configures the node and never approves a host.
Set-TsServeService -Service svc:example -Target http://127.0.0.1:4100

# Start the service from nothing (drain, clear, serve, advertise), then keep a receipt of what Tailscale reports.
Set-TsServeService -Service svc:example -Target http://127.0.0.1:4100 -Reset
Get-TsServiceReceipt -Service svc:example -Path ./receipts/example.json
Remove-TsServeService -Service svc:example
```

## Functions

| Function | What it does |
| --- | --- |
| `Get-TsServeConfig [-Executable]` | Runs `serve status --json` and returns the parsed object. Throws when the CLI fails or prints something other than JSON. An empty configuration returns an object with no properties |
| `Get-TsServePath [-Path] [-HttpsPort] [-Config] [-Executable]` | Lists mappings as objects with `HostPort`, `HttpsPort`, `Mount`, `Kind` (`Proxy`, `Path`, `Text`, `Redirect`, `Other`) and `Target`. `-Path` matches with or without a trailing slash |
| `Add-TsServePath -Path -Target [-HttpsPort 443] [-RequireRoot] [-Force] [-Executable]` | Maps a path to an `http://` or `https://` target. Returns `Path`, `HttpsPort`, `Target`, `Changed` and `Action` (`Added`, `Updated`, `Unchanged`). Supports `-WhatIf` and `-Confirm` |
| `Remove-TsServePath -Path [-HttpsPort 443] [-AllowRoot] [-Executable]` | Removes one mapping. Returns `Changed` and `Action` (`Removed`, `Absent`). Supports `-WhatIf` and `-Confirm` |
| `Assert-TsNoFunnel -Config [-HttpsPort 443]` | Throws when Funnel is enabled on the port |
| `Get-TsServeMappingTarget -StatusText -Path` | Reads a proxy target from the text form of `tailscale serve status`, for a CLI too old to print JSON. Returns `$null` when the path is absent |
| `Invoke-TsNative -Executable -Arguments` | Runs the CLI and returns `ExitCode`, `Output` and `ErrorOutput` without throwing. Every call to the CLI goes through it |
| `Get-TsServiceConfig [-Service] [-All] [-Executable]` | Runs `serve get-config --service=<name>` (or `--all`) and returns one object per service with `Service`, `Advertised` and `Endpoints` (`Port`, `Protocol`, `Target`). Nothing for a service this node does not host. Throws when the CLI fails or prints something that is not JSON |
| `Set-TsServeService -Service -Target [-Port 443] [-Protocol Https\|Http] [-Replace] [-Reset] [-NoAdvertise] [-Executable]` | Points the service at `http://127.0.0.1:<port>`, advertises it and confirms it by reading it back. Returns `Service`, `Protocol`, `Port`, `Target`, `Changed`, `Action` (`Added`, `Updated`, `Advertised`, `Unchanged`) and `Advertised`. Supports `-WhatIf` and `-Confirm` |
| `Remove-TsServeService -Service [-Executable]` | Drains the service, clears it and confirms it is gone. Returns `Changed` and `Action` (`Removed`, `Absent`). Supports `-WhatIf` and `-Confirm` |
| `Get-TsServiceReceipt -Service [-Path] [-Executable]` | A read-only record: the service configuration, the names of all services on this node, and the node's `DeviceId`, `HostName` and `service-host` capability from `tailscale status --json`. `-Path` also writes it as UTF-8 JSON without a byte order mark |

Without `-Executable` the CLI is found as `tailscale` or `tailscale.exe` on `PATH`, then at the macOS app location.

## Behavior

- A path that already proxies to the target is left alone and nothing is run.
- A path that points somewhere else is not replaced unless `-Force` is given. A replacement uses the mount's existing spelling, so `/docs/` is not duplicated as `/docs`.
- Targets are compared without a trailing slash and without regard to case; mounts without a trailing slash and with case.
- After each change the module confirms the mapping, confirms Funnel is still off, and confirms every other mapping on the port is unchanged. A mismatch throws.
- `-RequireRoot` throws unless the root path proxies to that target.
- `Remove-TsServePath` refuses `/` unless `-AllowRoot` is given.
- Paths must look like `/`, `/name` or `/a/b`, using letters, digits and `._~-`.

### Service mode

- A service name is `svc:` followed by lower-case letters, digits and single hyphens. The target is a local address: `http://127.0.0.1:<port>`, `127.0.0.1:<port>` or `localhost:<port>` (and `https://` for a local HTTPS backend). Anything else is rejected before the CLI runs.
- `Set-TsServeService` runs `tailscale serve --service=<name> --https=<port> --yes <target>` and then `tailscale serve advertise <name>`. It does not use `--bg`: Tailscale runs a service in the background by itself.
- Idempotent. When the endpoint already maps to the target (scheme, case, `localhost` and a trailing slash are ignored) and the service is advertised, nothing is run. A service that is configured as asked but drained (not advertised) is only advertised again.
- An endpoint that points somewhere else is not replaced unless `-Replace` is given, which just runs the `serve` command for that port. `-Reset` first drains and clears the whole service, every endpoint on it, then configures it from nothing, and implies `-Replace`. With no existing configuration `-Reset` skips the drain and clear.
- After the commands the service configuration is read back, and the call throws unless the endpoint is there with the target and the service is advertised (`-NoAdvertise` skips the advertised check and the `advertise` command).
- `Remove-TsServeService` drains first, so existing connections finish and no new ones start, then clears.
- Service mode needs the service to exist in the tailnet already (its name, port and tags are defined by the tailnet's policy or the Tailscale admin console or API). Approving a host, and any call to the Tailscale control-plane API, are outside this module, as is checking who is running the command.
- The `serve get-config` output is read as the Tailscale Services configuration file format (JSON with `//` comments and trailing commas tolerated). A node that prints something else makes the read throw instead of guessing.

## Tests

The tests use Pester 5 or later and replace `Invoke-TsNative` with an in-memory stand-in for the CLI (`TailscaleServe.Tests.ps1` for path mode, `TailscaleServe.Service.Tests.ps1` for service mode), so they need neither Tailscale nor a network:

```powershell
Invoke-Pester ./packages/tailscale-serve/tests
```

## License

MIT
