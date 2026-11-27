# ps-kit

Small, focused PowerShell modules from Uppercut Labs. Every module is at version 1.0.0 and is released as a git tag `<name>@1.0.0` in this repository. Each module installs on its own.

The modules run on Windows PowerShell 5.1 and PowerShell 7, and on macOS and Linux where PowerShell 7 is installed. Every package README has a "What runs where" table that says which parts are PowerShell, which (if any) are not, and on which system. Commands in these READMEs are PowerShell; on macOS and Linux start `pwsh` first instead of pasting them into Bash.

| Package | What it does |
| --- | --- |
| [`TailscaleServe`](packages/tailscale-serve) | Add, remove and list Tailscale Serve path mappings, and set up Tailscale Services (`svc:` names) with drain, clear, advertise, read-back and a receipt: idempotent, verified by reading the configuration back, and tailnet only because nothing here runs Funnel and path changes are refused where it is enabled |
| [`ReleaseArtifact`](packages/release-artifact) | Builds a release archive from a staged folder: checks that the Git tree is clean, writes `release.json` and `SHA256SUMS`, zips with forward-slash entry names and a `.sha256` sidecar, and smoke-tests the finished archive by unpacking it |
| [`DownloadVerified`](packages/download-verified) | Downloads a file over HTTPS only if its pinned SHA-256 matches, extracts a zip without letting an entry escape the destination, installs named files from it, and writes a receipt |
| [`OwnedTask`](packages/owned-task) | Registers a Windows scheduled task for a program you own, as the logged-on user, a built-in service account or a PSCredential (never a plain-text password), refuses to replace a task that belongs to someone else, and reads the task back to confirm it. Windows only |
| [`NoActivate`](packages/no-activate) | Starts a Windows program so its first window never takes keyboard focus, keeps its windows on one display without activating them, and can run it on a private desktop that is never shown. Windows only |
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
