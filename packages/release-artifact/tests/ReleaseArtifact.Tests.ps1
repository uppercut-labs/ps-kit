#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'ReleaseArtifact') 'ReleaseArtifact.psd1') -Force
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # Git is replaced: Invoke-ReleaseGit answers from $global:RaGit, a hashtable keyed by the joined arguments.
    Mock -ModuleName ReleaseArtifact Invoke-ReleaseGit {
        param($WorkingDirectory, $Arguments)
        $key = $Arguments -join ' '
        if ($global:RaGit.ContainsKey($key)) { $global:RaGit[$key] } else { [pscustomobject]@{ ExitCode = 128; Output = @('fatal') } }
    }

    function global:Set-RaFile {
        param([string]$Root, [string]$Relative, [string]$Text)
        $path = Join-Path $Root ($Relative -replace '/', [IO.Path]::DirectorySeparatorChar)
        $folder = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
        [IO.File]::WriteAllText($path, $Text, (New-Object Text.UTF8Encoding($false)))
    }
    # A zip whose entry names are exactly as given, including unsafe ones.
    function global:New-RaZip {
        param([string]$Path, [hashtable]$Entries)
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Create)
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entries.Keys) {
                $entry = $zip.CreateEntry($name)
                $writer = New-Object IO.StreamWriter($entry.Open())
                $writer.Write([string]$Entries[$name])
                $writer.Dispose()
            }
        } finally { $zip.Dispose(); $stream.Dispose() }
    }
    function global:Get-RaEntryName([string]$Path) {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        try { @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
    }
}

AfterAll {
    Remove-Variable -Name RaGit -Scope Global -ErrorAction SilentlyContinue
    Remove-Item function:global:Set-RaFile, function:global:New-RaZip, function:global:Get-RaEntryName -ErrorAction SilentlyContinue
    Remove-Module ReleaseArtifact -ErrorAction SilentlyContinue
}

Describe 'ReleaseArtifact' {
    BeforeEach {
        # Pester keeps the test drive for the whole block, so each test works in a folder of its own.
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work | Out-Null
        $commit = ('0123456789abcdef' * 3).Substring(0, 40)
        $global:RaGit = @{
            'status --porcelain'         = [pscustomobject]@{ ExitCode = 0; Output = @() }
            'rev-parse HEAD'             = [pscustomobject]@{ ExitCode = 0; Output = @($commit) }
            'rev-parse --short=12 HEAD'  = [pscustomobject]@{ ExitCode = 0; Output = @($commit.Substring(0, 12)) }
        }
    }

    Describe 'Get-ReleaseSourceIdentity' {
        It 'returns the full and the 12-digit commit for a clean tree' {
            $id = Get-ReleaseSourceIdentity -Path $work
            $id.Commit | Should -Be $commit
            $id.Short | Should -Be $commit.Substring(0, 12)
            $id.Clean | Should -BeTrue
        }
        It 'refuses a tree with uncommitted or untracked changes' {
            $global:RaGit['status --porcelain'] = [pscustomobject]@{ ExitCode = 0; Output = @(' M app.ps1', '?? new.txt') }
            { Get-ReleaseSourceIdentity -Path $work } | Should -Throw '*clean Git working tree*'
        }
        It 'allows a dirty tree with -AllowDirty and says so' {
            $global:RaGit['status --porcelain'] = [pscustomobject]@{ ExitCode = 0; Output = @(' M app.ps1') }
            (Get-ReleaseSourceIdentity -Path $work -AllowDirty).Clean | Should -BeFalse
        }
        It 'throws when git cannot inspect the folder' {
            $global:RaGit['status --porcelain'] = [pscustomobject]@{ ExitCode = 128; Output = @('fatal: not a git repository') }
            { Get-ReleaseSourceIdentity -Path $work } | Should -Throw '*inspect the Git working tree*'
        }
        It 'throws when there is no commit yet' {
            $global:RaGit['rev-parse HEAD'] = [pscustomobject]@{ ExitCode = 128; Output = @('fatal') }
            { Get-ReleaseSourceIdentity -Path $work } | Should -Throw '*committed Git revision*'
        }
        It 'refuses a revision that is not 40 hex digits, or a short form that is not 12' {
            $global:RaGit['rev-parse HEAD'] = [pscustomobject]@{ ExitCode = 0; Output = @('abc123') }
            { Get-ReleaseSourceIdentity -Path $work } | Should -Throw '*resolve the source revision*'
            $global:RaGit['rev-parse HEAD'] = [pscustomobject]@{ ExitCode = 0; Output = @($commit) }
            $global:RaGit['rev-parse --short=12 HEAD'] = [pscustomobject]@{ ExitCode = 0; Output = @('abc1234') }
            { Get-ReleaseSourceIdentity -Path $work } | Should -Throw '*resolve the source revision*'
        }
    }

    Describe 'New-ReleaseStage' {
        It 'creates an empty folder for the release and replaces an old one' {
            $stage = New-ReleaseStage -Root $work -Name 'app-1.0.0'
            Test-Path -LiteralPath $stage -PathType Container | Should -BeTrue
            Set-RaFile $stage 'old.txt' 'old'
            $again = New-ReleaseStage -Root $work -Name 'app-1.0.0'
            $again | Should -Be $stage
            @(Get-ChildItem -LiteralPath $again).Count | Should -Be 0
        }
        It 'puts the stage under <Root>/release by default and under -Folder when given' {
            (New-ReleaseStage -Root $work -Name 'a') | Should -Be ([IO.Path]::GetFullPath((Join-Path (Join-Path $work 'release') 'a')))
            (New-ReleaseStage -Root $work -Name 'a' -Folder 'out') | Should -Be ([IO.Path]::GetFullPath((Join-Path (Join-Path $work 'out') 'a')))
        }
        It 'refuses a name that is not one path segment' {
            { New-ReleaseStage -Root $work -Name '..' } | Should -Throw
            { New-ReleaseStage -Root $work -Name '../x' } | Should -Throw
            { New-ReleaseStage -Root $work -Name 'a/b' } | Should -Throw
            { New-ReleaseStage -Root $work -Name '' } | Should -Throw
        }
        It 'does nothing under -WhatIf' {
            New-ReleaseStage -Root $work -Name 'x' -WhatIf | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path (Join-Path $work 'release') 'x') | Should -BeFalse
        }
    }

    Describe 'Write-ReleaseManifest' {
        BeforeEach {
            $stage = New-ReleaseStage -Root $work -Name 'app'
            Set-RaFile $stage 'bin/app.ps1' 'Write-Output hi'
        }
        It 'writes the fields in the order given, as UTF-8 without a byte order mark, ending in a newline' {
            $path = Write-ReleaseManifest -Stage $stage -Manifest ([ordered]@{ app = 'example'; version = '1.0.0'; commit = $commit })
            $bytes = [IO.File]::ReadAllBytes($path)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            $text.EndsWith("`n") | Should -BeTrue
            $text.IndexOf('"app"') | Should -BeLessThan $text.IndexOf('"version"')
            $text.IndexOf('"version"') | Should -BeLessThan $text.IndexOf('"commit"')
            $json = $text | ConvertFrom-Json
            $json.version | Should -Be '1.0.0'
        }
        It 'adds a sorted files list with bytes and hashes when asked, and not the manifest or the sums' {
            Set-RaFile $stage 'README.txt' 'readme'
            Set-RaFile $stage 'SHA256SUMS' 'ignored'
            $path = Write-ReleaseManifest -Stage $stage -Manifest ([ordered]@{ app = 'example' }) -IncludeFiles
            $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            @($json.files | ForEach-Object { $_.path }) | Should -Be @('README.txt', 'bin/app.ps1')
            $json.files[1].bytes | Should -Be 15
            $json.files[1].sha256 | Should -Be ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path (Join-Path $stage 'bin') 'app.ps1')).Hash.ToLowerInvariant())
        }
        It 'does not write under -WhatIf' {
            Write-ReleaseManifest -Stage $stage -Manifest ([ordered]@{ app = 'x' }) -WhatIf | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $stage 'release.json') | Should -BeFalse
        }
    }

    Describe 'Write-Sha256Sums and Test-Sha256Sums' {
        BeforeEach {
            $stage = New-ReleaseStage -Root $work -Name 'app'
            Set-RaFile $stage 'b.txt' 'bee'
            Set-RaFile $stage 'a.txt' 'aye'
            Set-RaFile $stage 'dir/c.txt' 'sea'
            Set-RaFile $stage 'C.txt' 'upper'
        }
        It 'writes lower-case hash, two spaces, forward-slash path, sorted ordinally, ASCII, Unix line ends' {
            $lines = Write-Sha256Sums -Root $stage
            $lines.Count | Should -Be 4
            $text = [IO.File]::ReadAllText((Join-Path $stage 'SHA256SUMS'))
            $text.Contains("`r") | Should -BeFalse
            $text.EndsWith("`n") | Should -BeTrue
            $paths = @($text.TrimEnd("`n") -split "`n" | ForEach-Object { $_.Substring(66) })
            $paths | Should -Be @('C.txt', 'a.txt', 'b.txt', 'dir/c.txt')
            $text | Should -Match '^[0-9a-f]{64}  C\.txt\n'
        }
        It 'does not list the sums file itself and can be run twice with the same result' {
            Write-Sha256Sums -Root $stage | Out-Null
            $first = [IO.File]::ReadAllText((Join-Path $stage 'SHA256SUMS'))
            Write-Sha256Sums -Root $stage | Out-Null
            [IO.File]::ReadAllText((Join-Path $stage 'SHA256SUMS')) | Should -Be $first
            $first | Should -Not -Match 'SHA256SUMS'
        }
        It 'throws for an empty folder' {
            $empty = New-ReleaseStage -Root $work -Name 'empty'
            { Write-Sha256Sums -Root $empty } | Should -Throw '*no files*'
        }
        It 'Test-Sha256Sums passes for what was written and reports the count' {
            Write-Sha256Sums -Root $stage | Out-Null
            $result = Test-Sha256Sums -Root $stage
            $result.Passed | Should -BeTrue
            $result.Checked | Should -Be 4
        }
        It 'fails on a changed file, naming it' {
            Write-Sha256Sums -Root $stage | Out-Null
            Set-RaFile $stage 'a.txt' 'changed'
            { Test-Sha256Sums -Root $stage } | Should -Throw '*checksum mismatch: a.txt*'
        }
        It 'fails on a missing file' {
            Write-Sha256Sums -Root $stage | Out-Null
            Remove-Item -LiteralPath (Join-Path $stage 'b.txt')
            { Test-Sha256Sums -Root $stage } | Should -Throw '*missing: b.txt*'
        }
        It 'fails on a file that the sums do not list, unless -AllowExtra' {
            Write-Sha256Sums -Root $stage | Out-Null
            Set-RaFile $stage 'extra.txt' 'x'
            { Test-Sha256Sums -Root $stage } | Should -Throw '*not listed: extra.txt*'
            (Test-Sha256Sums -Root $stage -AllowExtra).Passed | Should -BeTrue
        }
        It 'accepts the binary-marker form and upper-case hashes' {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $stage 'a.txt')).Hash
            $folder = New-ReleaseStage -Root $work -Name 'one'
            Set-RaFile $folder 'a.txt' 'aye'
            [IO.File]::WriteAllText((Join-Path $folder 'SHA256SUMS'), "$hash *a.txt`n")
            (Test-Sha256Sums -Root $folder).Checked | Should -Be 1
        }
        It 'refuses malformed lines, rooted paths and .. segments, and names every problem once' {
            Set-RaFile $stage 'SHA256SUMS' ("not a hash line`n" + ('a' * 64) + "  ../outside.txt`n" + ('a' * 64) + "  /etc/passwd`n" + ('a' * 64) + "  C:/x.txt`n")
            $message = $null
            try { Test-Sha256Sums -Root $stage } catch { $message = $_.Exception.Message }
            $message | Should -Match 'malformed line'
            $message | Should -Match 'unsafe path: \.\./outside\.txt'
            $message | Should -Match 'unsafe path: /etc/passwd'
            $message | Should -Match 'unsafe path: C:/x\.txt'
        }
        It 'fails when the sums file lists nothing, or is absent' {
            Set-RaFile $stage 'SHA256SUMS' "`n"
            { Test-Sha256Sums -Root $stage } | Should -Throw '*lists no files*'
            Remove-Item -LiteralPath (Join-Path $stage 'SHA256SUMS')
            { Test-Sha256Sums -Root $stage } | Should -Throw '*not found*'
        }
    }

    Describe 'New-ReleaseArchive' {
        BeforeEach {
            $stage = New-ReleaseStage -Root $work -Name 'app-1.0.0'
            Set-RaFile $stage 'bin/app.ps1' 'Write-Output hi'
            Set-RaFile $stage 'README.txt' 'readme'
            $out = Join-Path $work 'dist'
        }
        It 'writes the zip with forward-slash entry names in path order, and the sidecar' {
            $zip = New-ReleaseArchive -Stage $stage -OutputDirectory $out -Name 'app-1.0.0'
            $zip.Name | Should -Be 'app-1.0.0.zip'
            Get-RaEntryName $zip.Path | Should -Be @('README.txt', 'bin/app.ps1')
            ((Get-RaEntryName $zip.Path) -join '').Contains('\') | Should -BeFalse
            $zip.Sha256 | Should -Be ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip.Path).Hash.ToLowerInvariant())
            [IO.File]::ReadAllText($zip.ChecksumPath) | Should -Be "$($zip.Sha256)  app-1.0.0.zip`n"
        }
        It 'writes the binary marker form when asked' {
            $zip = New-ReleaseArchive -Stage $stage -OutputDirectory $out -Name 'app' -BinaryMarker
            [IO.File]::ReadAllText($zip.ChecksumPath) | Should -Be "$($zip.Sha256) *app.zip`n"
        }
        It 'replaces an archive of the same name' {
            New-ReleaseArchive -Stage $stage -OutputDirectory $out -Name 'app' | Out-Null
            Set-RaFile $stage 'more.txt' 'more'
            $zip = New-ReleaseArchive -Stage $stage -OutputDirectory $out -Name 'app'
            (Get-RaEntryName $zip.Path).Count | Should -Be 3
        }
        It 'refuses an empty stage and a name that is not one file name' {
            $empty = New-ReleaseStage -Root $work -Name 'empty'
            { New-ReleaseArchive -Stage $empty -OutputDirectory $out -Name 'x' } | Should -Throw '*empty*'
            { New-ReleaseArchive -Stage $stage -OutputDirectory $out -Name '../x' } | Should -Throw
        }
        It 'does not write under -WhatIf' {
            New-ReleaseArchive -Stage $stage -OutputDirectory $out -Name 'app' -WhatIf | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $out 'app.zip') | Should -BeFalse
        }
    }

    Describe 'Test-ReleaseArchive' {
        BeforeEach {
            $stage = New-ReleaseStage -Root $work -Name 'app-1.0.0'
            Set-RaFile $stage 'bin/app.ps1' 'Write-Output hi'
            Set-RaFile $stage 'README.txt' 'readme'
            Write-ReleaseManifest -Stage $stage -Manifest ([ordered]@{ app = 'example'; version = '1.0.0'; commit = $commit }) | Out-Null
            Write-Sha256Sums -Root $stage | Out-Null
            $out = Join-Path $work 'dist'
            $zip = New-ReleaseArchive -Stage $stage -OutputDirectory $out -Name 'app-1.0.0'
        }
        It 'passes a good archive and returns the evidence' {
            $evidence = Test-ReleaseArchive $zip.Path -Require 'bin/app.ps1', 'release.json' -ExpectManifest @{ app = 'example'; version = '1.0.0' }
            $evidence.Archive | Should -Be 'app-1.0.0.zip'
            $evidence.Sha256 | Should -Be $zip.Sha256
            $evidence.SidecarChecked | Should -BeTrue
            $evidence.Files | Should -Be 4
            $evidence.Manifest.commit | Should -Be $commit
            $evidence.SmokePassed | Should -BeNullOrEmpty
        }
        It 'fails when the archive no longer matches its sidecar' {
            [IO.File]::AppendAllText($zip.Path, 'x')
            { Test-ReleaseArchive $zip.Path } | Should -Throw '*does not match its checksum file*'
        }
        It 'fails when a required file is missing' {
            { Test-ReleaseArchive $zip.Path -Require 'bin/missing.exe' } | Should -Throw '*missing the required file: bin/missing.exe*'
        }
        It 'fails when a forbidden name is present, in any folder' {
            { Test-ReleaseArchive $zip.Path -Forbid 'app.ps1' } | Should -Throw "*forbidden name 'app.ps1'*"
            { Test-ReleaseArchive $zip.Path -Forbid '*.pdb', 'app.*' } | Should -Throw '*bin/app.ps1*'
        }
        It 'fails when a manifest field has another value or is absent' {
            { Test-ReleaseArchive $zip.Path -ExpectManifest @{ version = '2.0.0' } } | Should -Throw "*field 'version' is '1.0.0', expected '2.0.0'*"
            { Test-ReleaseArchive $zip.Path -ExpectManifest @{ channel = 'stable' } } | Should -Throw "*no field 'channel'*"
        }
        It 'fails when the archive has no manifest but one is expected' {
            $plain = New-ReleaseStage -Root $work -Name 'plain'
            Set-RaFile $plain 'a.txt' 'a'
            Write-Sha256Sums -Root $plain | Out-Null
            $bare = New-ReleaseArchive -Stage $plain -OutputDirectory $out -Name 'plain'
            { Test-ReleaseArchive $bare.Path -ExpectManifest @{ app = 'x' } } | Should -Throw '*has no release.json*'
        }
        It 'fails when a file was changed after the sums were written' {
            $tampered = New-ReleaseStage -Root $work -Name 'tampered'
            Set-RaFile $tampered 'a.txt' 'a'
            Write-Sha256Sums -Root $tampered | Out-Null
            Set-RaFile $tampered 'a.txt' 'changed'
            $bad = New-ReleaseArchive -Stage $tampered -OutputDirectory $out -Name 'tampered'
            { Test-ReleaseArchive $bad.Path } | Should -Throw '*checksum mismatch: a.txt*'
        }
        It 'fails when the archive has a file the sums do not list' {
            $extra = New-ReleaseStage -Root $work -Name 'extra'
            Set-RaFile $extra 'a.txt' 'a'
            Write-Sha256Sums -Root $extra | Out-Null
            Set-RaFile $extra 'late.txt' 'late'
            $bad = New-ReleaseArchive -Stage $extra -OutputDirectory $out -Name 'extra'
            { Test-ReleaseArchive $bad.Path } | Should -Throw '*not listed: late.txt*'
        }
        It 'refuses entries that would extract outside the folder, and extracts nothing' {
            $evil = Join-Path $work 'evil.zip'
            New-RaZip -Path $evil -Entries @{ 'ok.txt' = 'ok'; '../escape.txt' = 'x' }
            { Test-ReleaseArchive $evil } | Should -Throw '*outside the folder*'
            Test-Path -LiteralPath (Join-Path $work 'escape.txt') | Should -BeFalse
        }
        It 'refuses a rooted entry and a drive-letter entry' {
            foreach ($name in '/abs.txt', 'C:/abs.txt') {
                $evil = Join-Path $work ('r-' + [guid]::NewGuid().ToString('N') + '.zip')
                New-RaZip -Path $evil -Entries @{ $name = 'x' }
                { Test-ReleaseArchive $evil } | Should -Throw '*outside the folder*'
            }
        }
        It 'refuses an entry name with a backslash (the Windows PowerShell 5.1 Compress-Archive shape)' {
            $back = Join-Path $work 'back.zip'
            New-RaZip -Path $back -Entries @{ 'bin\app.ps1' = 'x' }
            { Test-ReleaseArchive $back } | Should -Throw '*uses a backslash*'
        }
        It 'runs the smoke script with the extracted folder, and fails when it throws or returns false' {
            $box = @{}
            $evidence = Test-ReleaseArchive $zip.Path -Smoke { param($dir) $box.Text = Get-Content -LiteralPath (Join-Path (Join-Path $dir 'bin') 'app.ps1') -Raw }
            $evidence.SmokePassed | Should -BeTrue
            $box.Text | Should -Be 'Write-Output hi'
            { Test-ReleaseArchive $zip.Path -Smoke { param($dir) throw 'boom' } } | Should -Throw '*boom*'
            { Test-ReleaseArchive $zip.Path -Smoke { param($dir) $false } } | Should -Throw '*reported failure*'
        }
        It 'removes the extracted folder afterwards, unless -KeepExtracted' {
            $box = @{}
            Test-ReleaseArchive $zip.Path -Smoke { param($dir) $box.Folder = $dir } | Out-Null
            Test-Path -LiteralPath $box.Folder | Should -BeFalse
            Test-ReleaseArchive $zip.Path -KeepExtracted -Smoke { param($dir) $box.Kept = $dir } | Out-Null
            try { Test-Path -LiteralPath $box.Kept | Should -BeTrue } finally { Remove-Item -LiteralPath (Split-Path -Parent $box.Kept) -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'writes the evidence file as JSON without a byte order mark' {
            $path = Join-Path (Join-Path $work 'evidence') 'archive.json'
            Test-ReleaseArchive $zip.Path -EvidencePath $path | Out-Null
            $bytes = [IO.File]::ReadAllBytes($path)
            ($bytes[0] -eq 0xEF) | Should -BeFalse
            ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json).Sha256 | Should -Be $zip.Sha256
        }
        It 'throws for an archive that is not there' {
            { Test-ReleaseArchive (Join-Path $work 'nope.zip') } | Should -Throw '*was not found*'
        }
        It 'works with no sidecar and reports that it was not checked' {
            Remove-Item -LiteralPath $zip.ChecksumPath
            (Test-ReleaseArchive $zip.Path).SidecarChecked | Should -BeFalse
        }
    }

    Describe 'Relative paths' {
        It 'resolve against the current PowerShell location, as Push-Location sets it' {
            Push-Location -LiteralPath $work
            try {
                $stage = New-ReleaseStage -Root '.' -Name 'rel'
                $stage | Should -Be ([IO.Path]::GetFullPath((Join-Path (Join-Path $work 'release') 'rel')))
                Set-RaFile $stage 'a.txt' 'a'
                Write-Sha256Sums -Root (Join-Path 'release' 'rel') | Out-Null
                $zip = New-ReleaseArchive -Stage (Join-Path 'release' 'rel') -OutputDirectory 'out' -Name 'rel'
                $zip.Path | Should -Be ([IO.Path]::GetFullPath((Join-Path (Join-Path $work 'out') 'rel.zip')))
                (Test-ReleaseArchive (Join-Path 'out' 'rel.zip')).Files | Should -Be 2
            } finally { Pop-Location }
        }
    }

    Describe 'Whole build' {
        It 'stages, writes manifest and sums, zips, and the finished archive passes its own smoke test' {
            $stage = New-ReleaseStage -Root $work -Name 'app-2.0.0'
            Set-RaFile $stage 'app.ps1' 'Write-Output 2'
            $id = Get-ReleaseSourceIdentity -Path $work
            Write-ReleaseManifest -Stage $stage -Manifest ([ordered]@{ app = 'example'; version = '2.0.0'; commit = $id.Commit; short = $id.Short }) -IncludeFiles | Out-Null
            Write-Sha256Sums -Root $stage | Out-Null
            $zip = New-ReleaseArchive -Stage $stage -OutputDirectory (Join-Path $work 'dist') -Name 'app-2.0.0'
            $evidence = Test-ReleaseArchive $zip.Path -Require 'app.ps1', 'release.json', 'SHA256SUMS' -ExpectManifest @{ version = '2.0.0'; short = $id.Short }
            $evidence.Files | Should -Be 3
        }
    }
}
