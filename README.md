# ps-kit

Small, focused PowerShell modules from Uppercut Labs. Each package is a module that can be installed on its own, and may be published on the PowerShell Gallery.

PowerShell is part of the daily workflow here, not an afterthought: the modules run on Windows PowerShell 5.1 and PowerShell 7, and on macOS and Linux where PowerShell 7 is installed. Every package README has a "What runs where" table that says which parts are PowerShell, which (if any) are not, and on which system. Commands in these READMEs are PowerShell; on macOS and Linux start `pwsh` first instead of pasting them into Bash.

| Package | What it does |
| --- | --- |
| [`TailscaleServe`](packages/tailscale-serve) | Add, remove and list Tailscale Serve path mappings: idempotent, verified by reading the configuration back, and tailnet only because it refuses to act where Funnel is enabled |
| [`ProcessTreeMemory`](packages/process-tree-memory) | Private memory and working set summed over a Windows process and all of its descendants, with an optional budget and ceiling check. Windows only |
| [`ForegroundSampler`](packages/foreground-sampler) | Samples the Windows foreground window and writes a JSON line per change; with `-App`, reports whether an app's window came to the front. Windows only |
| [`RunAsUserShortcut`](packages/run-as-user-shortcut) | Runs a script in the owner's normal shell, outside a packaged app's redirected profile, through a headless console shortcut, and returns its result file. Windows only |

## Working in this repo

You need PowerShell 7 and Pester 5 or later:

```powershell
Install-PSResource Pester -Scope CurrentUser
./tools/Invoke-Check.ps1
```

Each package lives in `packages/<name>` with its own README and tests, and holds one module folder named for the module (`packages/<name>/<Module>/<Module>.psd1`). Packages have no dependencies on each other unless their README says so.

`tools/release_gate.py` is the one non-PowerShell file: a Python 3 script that scans the source, the history and the packed module before a release. It runs the same on every system.

See [RELEASING.md](RELEASING.md) for how a version is released.

## License

MIT
