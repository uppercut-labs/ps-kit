#Requires -Version 5.1
Set-StrictMode -Version Latest

# Downloads and unpacks a file only when its SHA-256 matches a value the caller pinned. A download goes to a
# temporary file beside the target and is moved into place only after the hash matches, so a failed or tampered
# download never leaves a file at the target. The one place that touches the network is Invoke-DownloadRaw,
# which a test replaces.

if ($PSVersionTable.PSVersion.Major -ge 6) { $script:OnWindows = [bool]$IsWindows } else { $script:OnWindows = $true }

function Invoke-DownloadRaw {
    param([string]$Uri, [string]$OutFile, [hashtable]$Headers)
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell 5.1 may default to protocols that sites no longer accept.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $params = @{ Uri = $Uri; OutFile = $OutFile; UseBasicParsing = $true }
    if ($Headers -and $Headers.Count -gt 0) { $params.Headers = $Headers }
    Invoke-WebRequest @params | Out-Null
}

function ConvertTo-Sha256Text {
    # Accepts 64 hex digits, with or without a "sha256:" prefix, in either case. Returns lower case.
    param([string]$Value)
    $text = ([string]$Value).Trim()
    if ($text -match '^(?i)sha256:(.+)$') { $text = $Matches[1] }
    if ($text -notmatch '^[0-9A-Fa-f]{64}$') { throw "The expected SHA-256 must be 64 hexadecimal digits. Got '$Value'." }
    $text.ToLowerInvariant()
}

function Get-FileSha256Text {
    param([string]$Path)
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-FileSha256 {
    <#
    .SYNOPSIS
    $true when the file's SHA-256 equals the expected value.
    .DESCRIPTION
    The expected value is 64 hexadecimal digits (case does not matter), optionally prefixed with sha256:.
    Returns $false for a file that does not exist. Throws for a value that is not a SHA-256.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [Parameter(Mandatory = $true, Position = 1)][string]$Sha256
    )
    $expected = ConvertTo-Sha256Text $Sha256
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    (Get-FileSha256Text $Path) -ceq $expected
}

function Save-VerifiedDownload {
    <#
    .SYNOPSIS
    Downloads a file over HTTPS and keeps it only if its SHA-256 matches.
    .DESCRIPTION
    Refuses a URI that is not https, and an expected hash that is not a SHA-256, before anything is fetched.
    The file is downloaded to a temporary file in the target's folder, hashed, and moved to -Path only when the
    hash matches; on a mismatch the temporary file is deleted and the call throws, naming the expected and the
    actual hash. A file already at -Path with the expected hash is kept and nothing is downloaded, unless -Force.
    .PARAMETER Sha256
    The pinned hash of the file. Take it from a source you trust, not from the download itself.
    .PARAMETER Headers
    Optional request headers, such as a User-Agent.
    .OUTPUTS
    An object with Uri, Path, Sha256, Bytes and Reused ($true when the existing file was kept).
    .EXAMPLE
    Save-VerifiedDownload -Uri 'https://downloads.example.invalid/tool-1.2.zip' -Path .\tool-1.2.zip -Sha256 '<64 hex digits>'
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Uri,
        [Parameter(Mandatory = $true, Position = 1)][string]$Path,
        [Parameter(Mandatory = $true, Position = 2)][string]$Sha256,
        [hashtable]$Headers,
        [switch]$Force
    )
    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne 'https') {
        throw "Only https downloads are allowed. Got '$Uri'."
    }
    $expected = ConvertTo-Sha256Text $Sha256
    $target = [IO.Path]::GetFullPath($Path)
    if (-not $Force -and (Test-Path -LiteralPath $target -PathType Leaf) -and ((Get-FileSha256Text $target) -ceq $expected)) {
        return [pscustomobject]@{ Uri = $Uri; Path = $target; Sha256 = $expected; Bytes = (Get-Item -LiteralPath $target).Length; Reused = $true }
    }
    if (-not $PSCmdlet.ShouldProcess($Uri, "Download to $target")) { return }
    $folder = Split-Path -Parent $target
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    $partial = "$target.$([guid]::NewGuid().ToString('N')).part"
    try {
        Invoke-DownloadRaw -Uri $Uri -OutFile $partial -Headers $Headers
        if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) { throw "The download of '$Uri' produced no file." }
        $actual = Get-FileSha256Text $partial
        if ($actual -cne $expected) {
            throw "SHA-256 mismatch for '$Uri': expected $expected, got $actual. The file was discarded."
        }
        Move-Item -LiteralPath $partial -Destination $target -Force
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{ Uri = $Uri; Path = $target; Sha256 = $expected; Bytes = (Get-Item -LiteralPath $target).Length; Reused = $false }
}

function Get-ZipEntryTarget {
    # The full path an entry would extract to, or a throw if it would land outside the root.
    param([string]$Root, [string]$EntryName)
    $name = $EntryName.Replace('\', '/')
    $segments = @($name -split '/' | Where-Object { $_ -ne '' -and $_ -ne '.' })
    if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or ($segments -contains '..')) {
        throw "The archive entry '$EntryName' would extract outside the destination. Nothing was kept."
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $target = [IO.Path]::GetFullPath((Join-Path $rootFull ($segments -join [IO.Path]::DirectorySeparatorChar)))
    $comparison = if ($script:OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $target.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw "The archive entry '$EntryName' would extract outside the destination. Nothing was kept."
    }
    $target
}

function Expand-VerifiedArchive {
    <#
    .SYNOPSIS
    Extracts a zip archive whose SHA-256 matches a pinned value, into an empty folder.
    .DESCRIPTION
    Checks the archive's hash first and extracts nothing on a mismatch. The destination must not exist or must
    be empty. Every entry is checked before any file is written: an entry with a rooted path, a drive letter or
    a .. segment, or one that would resolve outside the destination, makes the call throw. -MaxExpandedMB
    limits the total size of what the archive would write. After extraction, every -Require path must exist
    and no file may match a -Forbid name; on failure the destination folder this call created is removed.
    .PARAMETER Require
    Paths, relative to the destination, that must exist as files.
    .PARAMETER Forbid
    File names (wildcards allowed, compared to the file name only) that must not be present anywhere in the archive.
    .OUTPUTS
    An object with Path, ArchiveSha256 and Files (relative paths, with / separators).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [Parameter(Mandatory = $true, Position = 1)][string]$Sha256,
        [Parameter(Mandatory = $true, Position = 2)][string]$Destination,
        [string[]]$Require = @(),
        [string[]]$Forbid = @(),
        [ValidateRange(1, 1048576)][int]$MaxExpandedMB = 2048
    )
    $expected = ConvertTo-Sha256Text $Sha256
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The archive was not found: $Path" }
    $actual = Get-FileSha256Text $Path
    if ($actual -cne $expected) { throw "SHA-256 mismatch for '$Path': expected $expected, got $actual. Nothing was extracted." }

    $root = [IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $root) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "The destination is a file: $root" }
        if (@(Get-ChildItem -LiteralPath $root -Force).Count -gt 0) { throw "The destination is not empty: $root" }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
    try {
        $plan = New-Object System.Collections.Generic.List[object]
        $total = [int64]0
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
            $target = Get-ZipEntryTarget -Root $root -EntryName $entry.FullName
            foreach ($pattern in $Forbid) {
                if ($entry.Name -like $pattern) { throw "The archive contains '$($entry.FullName)', which is not allowed. Nothing was extracted." }
            }
            $total += $entry.Length
            $plan.Add([pscustomobject]@{ Entry = $entry; Target = $target; Relative = ($entry.FullName.Replace('\', '/').TrimStart('/')) })
        }
        if ($total -gt ([int64]$MaxExpandedMB * 1MB)) { throw "The archive would expand to more than $MaxExpandedMB MB. Nothing was extracted." }
        if (-not $PSCmdlet.ShouldProcess($root, "Extract $($plan.Count) files")) { return }
        $created = -not (Test-Path -LiteralPath $root)
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        try {
            foreach ($item in $plan) {
                $folder = Split-Path -Parent $item.Target
                if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($item.Entry, $item.Target, $false)
            }
            foreach ($required in $Require) {
                $requiredPath = Get-ZipEntryTarget -Root $root -EntryName $required
                if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "The archive does not contain the required file '$required'." }
            }
        } catch {
            if ($created) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
            throw
        }
    } finally {
        $zip.Dispose()
    }
    [pscustomobject]@{ Path = $root; ArchiveSha256 = $actual; Files = @($plan | ForEach-Object { $_.Relative }) }
}

function Install-VerifiedDownload {
    <#
    .SYNOPSIS
    Downloads an archive, verifies it, copies named files out of it, and records what was installed.
    .DESCRIPTION
    Runs Save-VerifiedDownload and Expand-VerifiedArchive in a temporary folder, then copies each file named in
    -Pick (found by file name anywhere in the archive; exactly one match each) into -Destination, hashes the
    installed copy, and removes the temporary folder. With -ReceiptPath the receipt is written as JSON, UTF-8
    without a byte order mark.
    .PARAMETER Pick
    File names to install, such as tool.exe. Each must match exactly one file in the archive.
    .PARAMETER ReceiptExtra
    Extra fields to put in the receipt, such as the version the hash was pinned for.
    .OUTPUTS
    The receipt: Uri, ArchiveName, ArchiveBytes, ArchiveSha256, Installed (Path, Sha256, Bytes for each file),
    InstalledAtUtc, and any -ReceiptExtra fields.
    .EXAMPLE
    Install-VerifiedDownload -Uri 'https://downloads.example.invalid/tool-1.2.zip' -Sha256 '<64 hex digits>' -Destination C:\Tools\tool -Pick tool.exe -ReceiptPath .\tool-receipt.json
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Uri,
        [Parameter(Mandatory = $true, Position = 1)][string]$Sha256,
        [Parameter(Mandatory = $true, Position = 2)][string]$Destination,
        [Parameter(Mandatory = $true)][string[]]$Pick,
        [hashtable]$Headers,
        [string]$ReceiptPath,
        [hashtable]$ReceiptExtra = @{}
    )
    if (-not $PSCmdlet.ShouldProcess([IO.Path]::GetFullPath($Destination), "Download $Uri and install $($Pick -join ', ')")) { return }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('download-verified-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $archiveName = [IO.Path]::GetFileName(([Uri]$Uri).AbsolutePath)
        if (-not $archiveName) { $archiveName = 'download.zip' }
        $archivePath = Join-Path $work $archiveName
        $saved = Save-VerifiedDownload -Uri $Uri -Path $archivePath -Sha256 $Sha256 -Headers $Headers -WhatIf:$false
        $extracted = Expand-VerifiedArchive -Path $saved.Path -Sha256 $Sha256 -Destination (Join-Path $work 'extract') -WhatIf:$false

        $picked = New-Object System.Collections.Generic.List[object]
        foreach ($name in $Pick) {
            $found = @($extracted.Files | Where-Object { ($_ -split '/')[-1] -ieq $name })
            if ($found.Count -eq 0) { throw "The archive does not contain '$name'." }
            if ($found.Count -gt 1) { throw "The archive contains more than one '$name': $($found -join ', '). Nothing was installed." }
            $picked.Add([pscustomobject]@{ Name = $name; Source = (Join-Path $extracted.Path ($found[0] -replace '/', [IO.Path]::DirectorySeparatorChar)) })
        }
        $destinationPath = [IO.Path]::GetFullPath($Destination)
        New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null
        $installed = foreach ($item in $picked) {
            $installedPath = Join-Path $destinationPath $item.Name
            Copy-Item -LiteralPath $item.Source -Destination $installedPath -Force
            [pscustomobject]@{ Path = $installedPath; Sha256 = (Get-FileSha256Text $installedPath); Bytes = (Get-Item -LiteralPath $installedPath).Length }
        }
        $receipt = [ordered]@{
            Uri            = $Uri
            ArchiveName    = $archiveName
            ArchiveBytes   = $saved.Bytes
            ArchiveSha256  = $saved.Sha256
            Installed      = @($installed)
            InstalledAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        foreach ($key in $ReceiptExtra.Keys) { $receipt[$key] = $ReceiptExtra[$key] }
        $receipt = [pscustomobject]$receipt
        if ($ReceiptPath) {
            $receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
            $receiptFolder = Split-Path -Parent $receiptFull
            if ($receiptFolder -and -not (Test-Path -LiteralPath $receiptFolder)) { New-Item -ItemType Directory -Force -Path $receiptFolder | Out-Null }
            [IO.File]::WriteAllText($receiptFull, ($receipt | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        }
        $receipt
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Save-VerifiedDownload, Expand-VerifiedArchive, Install-VerifiedDownload, Test-FileSha256
