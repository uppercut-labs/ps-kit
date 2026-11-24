# ReleaseArtifact

A PowerShell module that builds a release archive from a staged folder and checks the result. It checks that the Git working tree is clean and names the commit, writes `release.json` and `SHA256SUMS`, zips the stage with forward-slash entry names and a `.sha256` sidecar, and then smoke-tests the finished archive by unpacking it into an empty folder and checking what is inside. It replaces the copies of "stage, hash, zip, check" that each app's `build-release` and `install-release` script carries.

What goes into the stage folder stays your script's job: it is different for every app. The module takes over the parts that are the same every time and easy to get subtly wrong (hash line format, path sorting, entry names, unpacking safely).

## What runs where

Everything here is PowerShell. There is no Bash, and no part needs one. Git is called through one private function so tests can replace it.

| Part | Language | Runs on |
| --- | --- | --- |
| The `ReleaseArtifact` module | PowerShell, using `Get-FileHash`, `System.IO.Compression` and the `git` command | Windows PowerShell 5.1 and PowerShell 7 on Windows; PowerShell 7 on macOS and Linux |
| The tests | PowerShell with Pester 5 or later | the same systems. They replace `git` and build their own small folders and archives, so they need no network and no repository |

Commands in this README are PowerShell. On macOS and Linux start `pwsh` first; do not paste them into Bash.

## Install

From the PowerShell Gallery, once a release is published there:

```powershell
Install-PSResource ReleaseArtifact          # PSResourceGet, in PowerShell 7
Install-Module ReleaseArtifact -Scope CurrentUser   # PowerShellGet, in Windows PowerShell 5.1
```

From a clone of the repository:

```powershell
Import-Module ./packages/release-artifact/ReleaseArtifact/ReleaseArtifact.psd1
```

## Example

```powershell
$version = '1.2.0'
$source = Get-ReleaseSourceIdentity -Path .          # throws unless the Git tree is clean
$stage  = New-ReleaseStage -Root . -Name "app-$version"

# Your script copies the files that belong in the release into $stage here.
Copy-Item .\app.ps1, .\README.md -Destination $stage

Write-ReleaseManifest -Stage $stage -Manifest ([ordered]@{
    app = 'example'; version = $version; commit = $source.Commit; short = $source.Short
}) -IncludeFiles | Out-Null
Write-Sha256Sums -Root $stage | Out-Null              # last, so that it covers release.json
$zip = New-ReleaseArchive -Stage $stage -OutputDirectory .\dist -Name "app-$version"

Test-ReleaseArchive $zip.Path -Require 'app.ps1', 'SHA256SUMS' -Forbid '*.pdb', '.env' `
    -ExpectManifest @{ app = 'example'; version = $version; short = $source.Short } `
    -Smoke { param($dir) & (Join-Path $dir 'app.ps1') -Version } `
    -EvidencePath .\dist\archive-check.json
```

The installing side can check an unpacked release against its own sums, the same way:

```powershell
Test-Sha256Sums -Root C:\Apps\example      # throws, naming every problem, or returns Checked and Passed
```

## Functions

| Function | What it does |
| --- | --- |
| `Get-ReleaseSourceIdentity [-Path] [-AllowDirty]` | Throws unless the Git tree is clean (no modified or untracked files). Returns `Commit` (40 hex digits), `Short` (12) and `Clean`. Throws when the revision cannot be read |
| `New-ReleaseStage -Root -Name [-Folder release]` | Creates an empty `<Root>/<Folder>/<Name>` and returns its path. An old folder of that name is removed, after checking that it is directly inside `<Root>/<Folder>`. `-Name` must be one path segment. Supports `-WhatIf` |
| `Write-ReleaseManifest -Stage -Manifest [-FileName release.json] [-IncludeFiles]` | Writes your ordered fields as indented JSON, UTF-8 without a byte order mark, ending in a newline. `-IncludeFiles` appends a `files` list of `path`, `bytes` and `sha256`. Supports `-WhatIf` |
| `Write-Sha256Sums -Root [-FileName SHA256SUMS]` | Writes `<hash>  <path>` for every file under the folder: lower-case hash, two spaces, forward slashes, sorted by an ordinal comparison, ASCII, `\n` line ends. The file does not list itself. Returns the lines. Supports `-WhatIf` |
| `Test-Sha256Sums -Root [-FileName SHA256SUMS] [-AllowExtra]` | Checks every listed file and that no file is left unlisted. Reads `hash  path` and `hash *path`. Throws once, naming every problem. Returns `Root`, `Checked`, `Passed` |
| `New-ReleaseArchive -Stage -OutputDirectory -Name [-BinaryMarker]` | Zips the stage to `<Name>.zip` with `/` in every entry name, entries in path order, and writes `<Name>.zip.sha256`. Returns `Path`, `Sha256`, `Bytes`, `ChecksumPath`, `Name`. Supports `-WhatIf` |
| `Test-ReleaseArchive -Path [-Require] [-Forbid] [-ExpectManifest] [-Smoke] [-EvidencePath] [-KeepExtracted]` | The smoke test, described below. Returns the evidence: `Archive`, `Bytes`, `Sha256`, `SidecarChecked`, `Files`, `Manifest`, `SmokePassed`, `VerifiedAtUtc` |

## What the archive smoke test checks

In this order, stopping at the first failure:

1. The archive matches its `.sha256` sidecar, when there is one.
2. Every entry name is safe: no rooted path, no drive letter, no `..` segment, nothing that resolves outside the folder, and no backslash. Nothing is extracted until every entry has passed.
3. The archive is extracted into a new empty folder under the system temporary folder.
4. Every `-Require` file exists, and no file's name matches a `-Forbid` pattern (a wildcard on the file name, in any folder).
5. `SHA256SUMS` inside the archive lists every file and every hash matches.
6. `release.json` has every field in `-ExpectManifest` with that value, compared as text and case-sensitively.
7. `-Smoke`, a script block that receives the extracted folder, runs and must neither throw nor return `$false`. It runs in your session, so run only code you trust.

The extracted folder is removed at the end, whatever happened, unless `-KeepExtracted`.

## Behavior and limits

- The module does not choose what is in a release, sign anything, upload anything or create a Git tag.
- Windows PowerShell 5.1's `Compress-Archive` writes backslashes in entry names, which other tools read as one long file name. `New-ReleaseArchive` writes forward slashes, and `Test-ReleaseArchive` refuses an archive that has a backslash.
- Sorting is ordinal (`B.txt` before `a.txt`), so the sums file is the same on every system and every culture.
- `Get-ReleaseSourceIdentity` runs `git status --porcelain` and `git rev-parse`. Ignored files do not count as changes.
- A hash proves that the file is the one that was listed, not that the list is honest. Take the archive's `.sha256` from a place the download does not control.

## Tests

The tests use Pester 5 or later, replace `git`, and need no network:

```powershell
Invoke-Pester ./packages/release-artifact/tests
```

## License

MIT
