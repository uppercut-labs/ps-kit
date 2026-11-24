#Requires -Version 5.1
Set-StrictMode -Version Latest

# Builds and checks a release archive. The app-specific part (which files go in the stage folder) stays in the
# caller. Git is called only through Invoke-ReleaseGit, which a test replaces.

if ($PSVersionTable.PSVersion.Major -ge 6) { $script:OnWindows = [bool]$IsWindows } else { $script:OnWindows = $true }
$script:Ascii = New-Object System.Text.ASCIIEncoding
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Resolve-ReleasePath {
    # A path the caller gave, made absolute against PowerShell's current location (not the process's folder, which
    # Push-Location and Set-Location do not change), with . and .. segments removed.
    param([string]$Path)
    [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Invoke-ReleaseGit {
    param([string]$WorkingDirectory, [string[]]$Arguments)
    $previous = Get-Location
    try {
        Set-Location -LiteralPath $WorkingDirectory
        $output = @(& git @Arguments 2>&1 | ForEach-Object { [string]$_ })
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } finally { Set-Location -LiteralPath $previous.Path }
}

function Get-ReleaseSourceIdentity {
    <#
    .SYNOPSIS
    Checks that the Git working tree is clean and returns the commit it is at.
    .DESCRIPTION
    Throws when Git cannot be read, when there is any uncommitted or untracked change (unless -AllowDirty), or
    when the revision is not a full 40-digit commit with a 12-digit short form.
    .OUTPUTS
    An object with Commit, Short and Clean.
    #>
    [CmdletBinding()]
    param([string]$Path = '.', [switch]$AllowDirty)
    $root = (Resolve-Path -LiteralPath $Path).Path
    $status = Invoke-ReleaseGit -WorkingDirectory $root -Arguments @('status', '--porcelain')
    if ($status.ExitCode -ne 0) { throw 'Unable to inspect the Git working tree.' }
    $clean = @($status.Output | Where-Object { $_ }).Count -eq 0
    if (-not $clean -and -not $AllowDirty) { throw 'Release builds require a clean Git working tree.' }
    $full = Invoke-ReleaseGit -WorkingDirectory $root -Arguments @('rev-parse', 'HEAD')
    $short = Invoke-ReleaseGit -WorkingDirectory $root -Arguments @('rev-parse', '--short=12', 'HEAD')
    if ($full.ExitCode -ne 0 -or $short.ExitCode -ne 0) { throw 'Release requires a committed Git revision.' }
    $commit = ($full.Output | Select-Object -First 1).Trim()
    $shortText = ($short.Output | Select-Object -First 1).Trim()
    if ($commit -notmatch '^[0-9a-f]{40}$' -or $shortText -notmatch '^[0-9a-f]{12}$') { throw 'Unable to resolve the source revision.' }
    [pscustomobject]@{ Commit = $commit; Short = $shortText; Clean = $clean }
}

function New-ReleaseStage {
    <#
    .SYNOPSIS
    Creates an empty stage folder named for the release under <Root>\release, removing an old one of that name.
    .DESCRIPTION
    The name must be one path segment. The folder to remove is checked to be directly inside <Root>\release
    before anything is deleted.
    .OUTPUTS
    The full path of the new, empty stage folder.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Name,
        [string]$Folder = 'release'
    )
    $parent = Resolve-ReleasePath (Join-Path $Root $Folder)
    $stage = [IO.Path]::GetFullPath((Join-Path $parent $Name))
    if ((Split-Path -Parent $stage) -ne $parent) { throw "Refusing to use a stage folder outside '$parent': $stage" }
    if (-not $PSCmdlet.ShouldProcess($stage, 'Create an empty stage folder')) { return }
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $stage
}

function Get-StageFile {
    # Every file under a folder, sorted by relative path with an ordinal comparison (the same on every system).
    param([string]$Stage, [string[]]$Exclude = @())
    $root = (Resolve-ReleasePath $Stage).TrimEnd('\', '/')
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse -Force) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($Exclude -contains $relative) { continue }
        $list.Add([pscustomobject]@{ Relative = $relative; FullName = $file.FullName; Bytes = $file.Length })
    }
    $list.Sort([Comparison[object]]{ param($left, $right) [string]::CompareOrdinal($left.Relative, $right.Relative) })
    $list.ToArray()
}

function Write-ReleaseManifest {
    <#
    .SYNOPSIS
    Writes release.json into the stage folder: your fields, in your order, as indented JSON.
    .DESCRIPTION
    UTF-8 without a byte order mark, ending in a newline. With -IncludeFiles a files list (path, bytes, sha256 of
    every file already in the stage, sorted by path) is added as the last field. Write the manifest before
    Write-Sha256Sums, so that the checksums cover it.
    .PARAMETER Manifest
    An ordered dictionary of fields.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Manifest,
        [string]$FileName = 'release.json',
        [switch]$IncludeFiles
    )
    $document = [ordered]@{}
    foreach ($key in $Manifest.Keys) { $document[$key] = $Manifest[$key] }
    if ($IncludeFiles) {
        $document['files'] = @(Get-StageFile -Stage $Stage -Exclude @($FileName, 'SHA256SUMS') | ForEach-Object {
            [ordered]@{ path = $_.Relative; bytes = $_.Bytes; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
        })
    }
    $path = Join-Path (Resolve-ReleasePath $Stage) $FileName
    if (-not $PSCmdlet.ShouldProcess($path, 'Write the release manifest')) { return }
    [IO.File]::WriteAllText($path, (($document | ConvertTo-Json -Depth 8) + "`n"), $script:Utf8NoBom)
    $path
}

function Write-Sha256Sums {
    <#
    .SYNOPSIS
    Writes SHA256SUMS for every file under a folder: "<hash>  <relative/path>", sorted by path.
    .DESCRIPTION
    Lower-case hashes, two spaces (the format sha256sum -c reads), forward slashes, ASCII, Unix line ends. The
    sums file itself is not listed. Paths are sorted with an invariant, case-sensitive comparison, so the file is
    the same on every machine.
    .OUTPUTS
    The lines that were written.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$FileName = 'SHA256SUMS'
    )
    $lines = @(Get-StageFile -Stage $Root -Exclude @($FileName) | ForEach-Object {
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())  $($_.Relative)"
    })
    if ($lines.Count -eq 0) { throw "There are no files under '$Root' to list." }
    $path = Join-Path (Resolve-ReleasePath $Root) $FileName
    if (-not $PSCmdlet.ShouldProcess($path, 'Write the checksum file')) { return }
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $script:Ascii)
    $lines
}

function Test-Sha256Sums {
    <#
    .SYNOPSIS
    Checks every file listed in a SHA256SUMS file, and that no file is left unlisted.
    .DESCRIPTION
    Reads lines of the form "<hash>  <path>" or "<hash> *<path>". Refuses a malformed line, a rooted path, a path
    with a .. segment, a listed file that is missing, a hash that differs, and (unless -AllowExtra) a file in the
    folder that the sums do not list. Throws once, naming every problem.
    .OUTPUTS
    An object with Root, Checked (the number of files) and Passed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Root,
        [string]$FileName = 'SHA256SUMS',
        [switch]$AllowExtra
    )
    $rootFull = (Resolve-ReleasePath $Root).TrimEnd('\', '/')
    $sumsPath = Join-Path $rootFull $FileName
    if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) { throw "The checksum file was not found: $sumsPath" }
    $problems = New-Object System.Collections.Generic.List[string]
    $listed = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in [IO.File]::ReadAllLines($sumsPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64}) [ *](?<path>.+)$') { $problems.Add("malformed line: $line"); continue }
        $relative = $Matches['path'].Replace('\', '/')
        $segments = @($relative -split '/')
        if ($relative.StartsWith('/') -or $relative -match '^[A-Za-z]:' -or ($segments -contains '..')) { $problems.Add("unsafe path: $relative"); continue }
        $null = $listed.Add($relative)
        $file = Join-Path $rootFull ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $problems.Add("missing: $relative"); continue }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant() -ne $Matches['hash'].ToLowerInvariant()) { $problems.Add("checksum mismatch: $relative") }
    }
    if ($listed.Count -eq 0 -and $problems.Count -eq 0) { $problems.Add('the checksum file lists no files') }
    if (-not $AllowExtra) {
        foreach ($file in Get-StageFile -Stage $rootFull -Exclude @($FileName)) {
            if (-not $listed.Contains($file.Relative)) { $problems.Add("not listed: $($file.Relative)") }
        }
    }
    if ($problems.Count -gt 0) { throw "Checksum verification failed for '$rootFull': $($problems -join '; ')." }
    [pscustomobject]@{ Root = $rootFull; Checked = $listed.Count; Passed = $true }
}

function New-ReleaseArchive {
    <#
    .SYNOPSIS
    Zips a stage folder and writes the archive's SHA-256 beside it.
    .DESCRIPTION
    Every entry name uses forward slashes (Windows PowerShell 5.1's Compress-Archive writes backslashes) and
    entries are added in path order. An old archive of the same name is replaced. The sidecar <archive>.sha256
    holds one line, "<hash>  <name>" (or "<hash> *<name>" with -BinaryMarker, the form some tools expect), and is
    read back to confirm it.
    .OUTPUTS
    An object with Path, Sha256, Bytes, ChecksumPath and Name.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Name,
        [switch]$BinaryMarker
    )
    $stageFull = Resolve-ReleasePath $Stage
    $files = @(Get-StageFile -Stage $stageFull)
    if ($files.Count -eq 0) { throw "The stage folder is empty: $stageFull" }
    $outputFull = Resolve-ReleasePath $OutputDirectory
    $zipPath = Join-Path $outputFull "$Name.zip"
    if (-not $PSCmdlet.ShouldProcess($zipPath, 'Create the release archive')) { return }
    New-Item -ItemType Directory -Force -Path $outputFull | Out-Null
    Remove-Item -LiteralPath $zipPath, "$zipPath.sha256" -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in $files) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $file.Relative, [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
    $marker = if ($BinaryMarker) { ' *' } else { '  ' }
    $sidecar = "$zipPath.sha256"
    [IO.File]::WriteAllText($sidecar, "$hash$marker$([IO.Path]::GetFileName($zipPath))`n", $script:Ascii)
    $readBack = ([IO.File]::ReadAllText($sidecar)).Trim()
    if ($readBack -ne "$hash$marker$([IO.Path]::GetFileName($zipPath))") { throw 'The checksum file did not read back as written.' }
    [pscustomobject]@{ Path = $zipPath; Sha256 = $hash; Bytes = (Get-Item -LiteralPath $zipPath).Length; ChecksumPath = $sidecar; Name = [IO.Path]::GetFileName($zipPath) }
}

function Get-SafeEntryTarget {
    param([string]$Root, [string]$EntryName)
    $name = $EntryName.Replace('\', '/')
    $segments = @($name -split '/' | Where-Object { $_ -ne '' -and $_ -ne '.' })
    if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or ($segments -contains '..')) { throw "The archive entry '$EntryName' would extract outside the folder." }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $target = [IO.Path]::GetFullPath((Join-Path $rootFull ($segments -join [IO.Path]::DirectorySeparatorChar)))
    $comparison = if ($script:OnWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $target.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw "The archive entry '$EntryName' would extract outside the folder." }
    $target
}

function Test-ReleaseArchive {
    <#
    .SYNOPSIS
    Smoke-tests a finished release archive by unpacking it into an empty folder and checking what is inside.
    .DESCRIPTION
    In order: the archive against its .sha256 sidecar (when there is one); every entry name is safe and uses no
    backslash; the archive is extracted into a new empty folder; every -Require file exists and no file matches
    a -Forbid name; the SHA256SUMS inside lists every file and every hash matches (Test-Sha256Sums); the manifest
    (release.json) has every field in -ExpectManifest with that value; and, last, the -Smoke script block runs
    with the extracted folder as its argument and must not throw or return $false. The extracted folder is
    removed at the end unless -KeepExtracted.
    .PARAMETER ExpectManifest
    Fields the manifest must have, such as @{ app = 'example'; version = '1.2.0' }. Compared as text.
    .PARAMETER Smoke
    A script block that receives the extracted folder, for example one that runs the packaged program with
    --version. It runs in the caller's session.
    .PARAMETER EvidencePath
    Where to write the result as JSON (UTF-8, no byte order mark).
    .OUTPUTS
    An object with Archive, Bytes, Sha256, SidecarChecked, Files, Manifest, SmokePassed and VerifiedAtUtc.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [string[]]$Require = @(),
        [string[]]$Forbid = @(),
        [hashtable]$ExpectManifest = @{},
        [string]$ManifestName = 'release.json',
        [scriptblock]$Smoke,
        [string]$EvidencePath,
        [switch]$KeepExtracted
    )
    $archive = Resolve-ReleasePath $Path
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "The release archive was not found: $archive" }
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    $sidecar = "$archive.sha256"
    $sidecarChecked = $false
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        $first = (([IO.File]::ReadAllText($sidecar)).Trim() -split '\s+')[0]
        if ($first.ToLowerInvariant() -ne $sha) { throw "The archive does not match its checksum file: expected $first, got $sha." }
        $sidecarChecked = $true
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $work = Join-Path ([IO.Path]::GetTempPath()) ('release-archive-' + [guid]::NewGuid().ToString('N'))
    $extracted = Join-Path $work 'package'
    $files = New-Object System.Collections.Generic.List[string]
    try {
        New-Item -ItemType Directory -Force -Path $extracted | Out-Null
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $plan = New-Object System.Collections.Generic.List[object]
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
                if ($entry.FullName.Contains('\')) { throw "The archive entry '$($entry.FullName)' uses a backslash. Entry names must use forward slashes." }
                $plan.Add([pscustomobject]@{ Entry = $entry; Target = (Get-SafeEntryTarget -Root $extracted -EntryName $entry.FullName); Name = $entry.FullName })
            }
            foreach ($item in $plan) {
                $folder = Split-Path -Parent $item.Target
                if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($item.Entry, $item.Target, $false)
                $files.Add($item.Name)
            }
        } finally { $zip.Dispose() }
        foreach ($required in $Require) {
            if (-not (Test-Path -LiteralPath (Get-SafeEntryTarget -Root $extracted -EntryName $required) -PathType Leaf)) { throw "The release archive is missing the required file: $required" }
        }
        foreach ($pattern in $Forbid) {
            $hit = @($files | Where-Object { ($_ -split '/')[-1] -like $pattern })
            if ($hit.Count -gt 0) { throw "The release archive contains '$($hit[0])', which matches the forbidden name '$pattern'." }
        }
        $null = Test-Sha256Sums -Root $extracted
        $manifest = $null
        $manifestPath = Join-Path $extracted $ManifestName
        if ($ExpectManifest.Count -gt 0 -or (Test-Path -LiteralPath $manifestPath)) {
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "The release archive has no $ManifestName." }
            try { $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -ErrorAction Stop }
            catch { throw "$ManifestName is not valid JSON." }
            foreach ($key in $ExpectManifest.Keys) {
                $property = $manifest.PSObject.Properties[$key]
                if ($null -eq $property) { throw "$ManifestName has no field '$key'." }
                if ([string]$property.Value -cne [string]$ExpectManifest[$key]) { throw "$ManifestName field '$key' is '$($property.Value)', expected '$($ExpectManifest[$key])'." }
            }
        }
        $smokePassed = $null
        if ($Smoke) {
            $result = & $Smoke $extracted
            if ($result -is [bool] -and -not $result) { throw 'The smoke test reported failure.' }
            $smokePassed = $true
        }
        $evidence = [pscustomobject]@{
            Archive        = [IO.Path]::GetFileName($archive)
            Bytes          = (Get-Item -LiteralPath $archive).Length
            Sha256         = $sha
            SidecarChecked = $sidecarChecked
            Files          = $files.Count
            Manifest       = $manifest
            SmokePassed    = $smokePassed
            VerifiedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        }
        if ($EvidencePath) {
            $evidencePath = Resolve-ReleasePath $EvidencePath
            $folder = Split-Path -Parent $evidencePath
            if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
            [IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
        }
        $evidence
    } finally {
        if (-not $KeepExtracted -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Get-ReleaseSourceIdentity, New-ReleaseStage, Write-ReleaseManifest, Write-Sha256Sums, Test-Sha256Sums, New-ReleaseArchive, Test-ReleaseArchive
