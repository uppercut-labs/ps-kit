# TailscaleServe

A PowerShell module that adds, removes and lists path mappings in Tailscale Serve. It reads the configuration with `tailscale serve status --json`, changes one mapping, reads the configuration back and confirms the result. It only ever runs `tailscale serve`, never `tailscale funnel`, and it refuses to act on a port where Funnel is enabled, so mappings stay on the tailnet.

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
# Map https://<machine>.<tailnet>.ts.net/docs to a local server. Running it twice changes nothing the second time.
Add-TsServePath -Path /docs -Target http://127.0.0.1:8766/docs

# Only act if the root mapping is still the one this machine expects.
Add-TsServePath -Path /docs -Target http://127.0.0.1:8766/docs -RequireRoot http://127.0.0.1:8787

# Give a service its own HTTPS port.
Add-TsServePath -Path / -Target http://127.0.0.1:4420 -HttpsPort 8460

Get-TsServePath | Format-Table HostPort, Mount, Kind, Target
Remove-TsServePath -Path /docs
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

Without `-Executable` the CLI is found as `tailscale` or `tailscale.exe` on `PATH`, then at the macOS app location.

## Behavior

- A path that already proxies to the target is left alone and nothing is run.
- A path that points somewhere else is not replaced unless `-Force` is given. A replacement uses the mount's existing spelling, so `/docs/` is not duplicated as `/docs`.
- Targets are compared without a trailing slash and without regard to case; mounts without a trailing slash and with case.
- After each change the module confirms the mapping, confirms Funnel is still off, and confirms every other mapping on the port is unchanged. A mismatch throws.
- `-RequireRoot` throws unless the root path proxies to that target.
- `Remove-TsServePath` refuses `/` unless `-AllowRoot` is given.
- Paths must look like `/`, `/name` or `/a/b`, using letters, digits and `._~-`.

## Tests

The tests use Pester 5 or later and replace `Invoke-TsNative` with an in-memory stand-in for the CLI, so they need neither Tailscale nor a network:

```powershell
Invoke-Pester ./packages/tailscale-serve/tests
```

## License

MIT
