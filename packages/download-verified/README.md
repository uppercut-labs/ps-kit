# DownloadVerified

A PowerShell module that downloads a file only over HTTPS and only keeps it if its SHA-256 matches a value you pinned, extracts a zip archive without letting any entry write outside the destination, installs named files from it, and writes a receipt of what was installed. It replaces the install script that fetches a release archive, unzips it, copies out an executable and records its hash, where the hash is only recorded and never checked.

The hash you pass is the trust decision, so take it from a source you trust (a release page, a signed manifest, an earlier install you reviewed), not from the download.

## What runs where

Everything here is PowerShell. There is no Bash, and no part needs one.

| Part | Language | Runs on |
| --- | --- | --- |
| The `DownloadVerified` module | PowerShell, using `Invoke-WebRequest`, `Get-FileHash` and `System.IO.Compression` | Windows PowerShell 5.1 and PowerShell 7 on Windows; PowerShell 7 on macOS and Linux |
| The tests | PowerShell with Pester 5 or later | the same systems. They replace the network call and build their own small zip files, so they need no network |

Commands in this README are PowerShell. On macOS and Linux start `pwsh` first; do not paste them into Bash.

## Install

From the PowerShell Gallery, once a release is published there:

```powershell
Install-PSResource DownloadVerified          # PSResourceGet, in PowerShell 7
Install-Module DownloadVerified -Scope CurrentUser   # PowerShellGet, in Windows PowerShell 5.1
```

From a clone of the repository:

```powershell
Import-Module ./packages/download-verified/DownloadVerified/DownloadVerified.psd1
```

## Example

```powershell
$sha = '<64 hex digits you pinned>'
$uri = 'https://downloads.example.invalid/tool-1.2.zip'

# Download, check, extract, copy out tool.exe, hash the installed copy, and record it.
$receipt = Install-VerifiedDownload -Uri $uri -Sha256 $sha -Destination 'C:\Tools\tool' -Pick 'tool.exe' `
    -ReceiptPath 'C:\Tools\tool\receipt.json' -ReceiptExtra @{ Version = '1.2' }
$receipt.Installed[0].Sha256

# Or the steps one at a time.
$file = Save-VerifiedDownload -Uri $uri -Path .\tool-1.2.zip -Sha256 $sha
$unpacked = Expand-VerifiedArchive -Path $file.Path -Sha256 $sha -Destination .\tool-1.2 -Require 'tool.exe' -Forbid 'ffmpeg.exe'

# Later: is the installed file still the one that was installed?
Test-FileSha256 'C:\Tools\tool\tool.exe' $receipt.Installed[0].Sha256
```

## Functions

| Function | What it does |
| --- | --- |
| `Save-VerifiedDownload -Uri -Path -Sha256 [-Headers] [-Force]` | Downloads over HTTPS to a temporary file beside the target, hashes it, and moves it to `-Path` only if the hash matches. Returns `Uri`, `Path`, `Sha256`, `Bytes`, `Reused`. Supports `-WhatIf` |
| `Expand-VerifiedArchive -Path -Sha256 -Destination [-Require] [-Forbid] [-MaxExpandedMB 2048]` | Checks the archive's hash, then extracts into an empty folder. Returns `Path`, `ArchiveSha256` and `Files`. Supports `-WhatIf` |
| `Install-VerifiedDownload -Uri -Sha256 -Destination -Pick [-Headers] [-ReceiptPath] [-ReceiptExtra]` | Both of the above in a temporary folder, then copies each `-Pick` file into `-Destination` and returns the receipt. Supports `-WhatIf` |
| `Test-FileSha256 -Path -Sha256` | `$true` when the file has that hash. `$false` for a missing file |

The receipt has `Uri`, `ArchiveName`, `ArchiveBytes`, `ArchiveSha256`, `Installed` (`Path`, `Sha256`, `Bytes` for each file), `InstalledAtUtc` and any `-ReceiptExtra` fields. With `-ReceiptPath` it is also written as JSON, UTF-8 without a byte order mark.

## Behavior

- Only `https://` addresses are downloaded. `http://`, `file:`, `ftp:`, UNC and relative addresses are refused before anything is fetched. Windows PowerShell 5.1 is switched to allow TLS 1.2.
- The pinned hash is 64 hexadecimal digits in either case, optionally prefixed `sha256:`. Anything else is refused before anything is fetched.
- A download that does not match is deleted and the call throws, naming the expected and the actual hash. The file that was at the target before is left as it was. A failed or interrupted download leaves no `.part` file.
- A file already at the target with the pinned hash is kept and nothing is downloaded, unless `-Force`.
- Archive entries are checked before any file is written. An entry with a rooted path, a drive letter, or a `..` segment, or one that would resolve outside the destination, makes the call throw and extracts nothing (the "zip slip" case). Entries may use `/` or `\`.
- `-MaxExpandedMB` limits what an archive may write, against an archive that expands to a huge size.
- The destination must not exist or must be empty. When a `-Require` file is missing after extraction, the folder this call created is removed.
- `Install-VerifiedDownload` installs a file by name: each `-Pick` name must match exactly one file in the archive (any folder, any case), and is copied flat into `-Destination`. It removes its temporary folder on success and on failure.
- Not included: signature checks (such as Authenticode or minisign), formats other than zip, resuming a download, and proxies other than the system's. A hash is as good as the place you got it from.

## Tests

The tests use Pester 5 or later and replace the network call, so they need no network:

```powershell
Invoke-Pester ./packages/download-verified/tests
```

## License

MIT
