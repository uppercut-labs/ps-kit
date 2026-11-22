# Releasing

Every package is versioned and released on its own. A release only goes out after the release gate passes on the source tree, the git history and the exact file that will be uploaded.

Everything below is PowerShell except the gate, which is Python 3 and runs the same on Windows, macOS and Linux. Run the commands in `pwsh` (PowerShell 7).

1. Bump `ModuleVersion` in `packages/<name>/<Module>/<Module>.psd1` and note the change in `ReleaseNotes` and in the package README if behavior changed.
2. `./tools/Invoke-Check.ps1` (validates every manifest, then runs every Pester test).
3. Pack the module into a `.nupkg`:

   ```powershell
   New-Item -ItemType Directory -Force ./dist | Out-Null   # Compress-PSResource needs the folder to exist
   Compress-PSResource -Path ./packages/<name>/<Module> -DestinationPath ./dist
   ```

4. `python tools/release_gate.py --artifact dist/<Module>.<version>.nupkg`
   - The gate needs `RELEASE_GATE_DENYLIST` (a private file of strings that must never ship, kept outside this repo) and `gitleaks` on `PATH` or in `GITLEAKS`.
   - The gate also needs `RELEASE_GATE_ALLOWED_EMAILS`, a comma-separated list of the commit author and committer emails it accepts. Any other address in the history fails the gate. For this repository: `packages@uppercut-labs.com` (the commit identity), the maintainer's GitHub `users.noreply.github.com` address, and `noreply@github.com` (the committer GitHub records on merged pull requests).
   - Exit code 0 is the only passing result.
5. Publishing to the PowerShell Gallery is optional. A `.nupkg` made in step 3 is the file the gate scanned:

   ```powershell
   Publish-PSResource -NupkgPath ./dist/<Module>.<version>.nupkg -Repository PSGallery -ApiKey $env:PSGALLERY_API_KEY
   ```

   Without a gallery release, the module installs from a clone of this repository or from the GitHub release page.
6. Tag the commit `<name>@<version>` and push the tag.

Releases are made from a maintainer machine. This repository does not use hosted CI for publishing.
