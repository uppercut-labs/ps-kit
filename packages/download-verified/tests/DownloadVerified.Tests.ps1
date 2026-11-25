#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    Import-Module (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'DownloadVerified') 'DownloadVerified.psd1') -Force
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # The network is replaced: Invoke-DownloadRaw writes the bytes that the test registered for the address.
    Mock -ModuleName DownloadVerified Invoke-DownloadRaw {
        param($Uri, $OutFile, $Headers)
        $global:DvDownloads.Add([pscustomobject]@{ Uri = $Uri; OutFile = $OutFile; Headers = $Headers })
        if ($global:DvFail) { throw 'network down' }
        if ($global:DvBytes.ContainsKey($Uri)) { [IO.File]::WriteAllBytes($OutFile, $global:DvBytes[$Uri]) }
    }

    # A zip with the entry names exactly as given (including unsafe ones). A value is the entry's text.
    function global:New-DvZip {
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
    function global:Get-DvSha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
}

AfterAll {
    Remove-Variable -Name DvDownloads, DvBytes, DvFail -Scope Global -ErrorAction SilentlyContinue
    Remove-Item function:global:New-DvZip, function:global:Get-DvSha -ErrorAction SilentlyContinue
    Remove-Module DownloadVerified -ErrorAction SilentlyContinue
}

Describe 'DownloadVerified' {
    BeforeEach {
        # Pester keeps the test drive for the whole block, so each test works in a folder of its own.
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work | Out-Null
        $global:DvDownloads = New-Object System.Collections.Generic.List[object]
        $global:DvBytes = @{}
        $global:DvFail = $false
        $uri = 'https://downloads.example.invalid/tool-1.2.zip'
        $content = [Text.Encoding]::UTF8.GetBytes('example file contents')
        $contentHash = (New-Object Security.Cryptography.SHA256Managed).ComputeHash($content)
        $contentSha = -join ($contentHash | ForEach-Object { $_.ToString('x2') })
        $global:DvBytes[$uri] = $content
    }

    Describe 'Test-FileSha256' {
        It 'is true for the matching hash in either case, with or without the sha256: prefix' {
            $file = Join-Path $work 'a.bin'
            [IO.File]::WriteAllBytes($file, $content)
            Test-FileSha256 $file $contentSha | Should -BeTrue
            Test-FileSha256 $file $contentSha.ToUpperInvariant() | Should -BeTrue
            Test-FileSha256 $file "sha256:$contentSha" | Should -BeTrue
        }
        It 'is false for another hash and for a file that is not there' {
            $file = Join-Path $work 'a.bin'
            [IO.File]::WriteAllBytes($file, $content)
            Test-FileSha256 $file ('0' * 64) | Should -BeFalse
            Test-FileSha256 (Join-Path $work 'missing.bin') $contentSha | Should -BeFalse
        }
        It 'throws for a value that is not a SHA-256' {
            $file = Join-Path $work 'a.bin'
            [IO.File]::WriteAllBytes($file, $content)
            { Test-FileSha256 $file 'abc' } | Should -Throw '*64 hexadecimal digits*'
            { Test-FileSha256 $file ('g' * 64) } | Should -Throw
        }
    }

    Describe 'Save-VerifiedDownload' {
        It 'keeps a file whose hash matches and reports it' {
            $target = Join-Path $work 'out\tool.zip'
            $result = Save-VerifiedDownload -Uri $uri -Path $target -Sha256 $contentSha
            $result.Reused | Should -BeFalse
            $result.Sha256 | Should -Be $contentSha
            $result.Bytes | Should -Be $content.Length
            $result.Path | Should -Be ([IO.Path]::GetFullPath($target))
            Test-FileSha256 $target $contentSha | Should -BeTrue
        }

        It 'leaves no partial file behind' {
            $target = Join-Path $work 'out\tool.zip'
            $null = Save-VerifiedDownload -Uri $uri -Path $target -Sha256 $contentSha
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $target)).Count | Should -Be 1
        }

        It 'discards a download whose hash does not match and names both hashes' {
            $target = Join-Path $work 'out\tool.zip'
            $wrong = '1' * 64
            { Save-VerifiedDownload -Uri $uri -Path $target -Sha256 $wrong } | Should -Throw "*mismatch*expected $wrong, got $contentSha*discarded*"
            Test-Path -LiteralPath $target | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $target)).Count | Should -Be 0
        }

        It 'keeps the file that was already there when the new download does not match' {
            $target = Join-Path $work 'old.zip'
            [IO.File]::WriteAllText($target, 'old')
            { Save-VerifiedDownload -Uri $uri -Path $target -Sha256 ('2' * 64) } | Should -Throw '*mismatch*'
            [IO.File]::ReadAllText($target) | Should -Be 'old'
        }

        It 'does not download again when the file is already there with the expected hash' {
            $target = Join-Path $work 'tool.zip'
            [IO.File]::WriteAllBytes($target, $content)
            $result = Save-VerifiedDownload -Uri $uri -Path $target -Sha256 $contentSha
            $result.Reused | Should -BeTrue
            $global:DvDownloads.Count | Should -Be 0
        }

        It 'downloads again with -Force' {
            $target = Join-Path $work 'tool.zip'
            [IO.File]::WriteAllBytes($target, $content)
            $result = Save-VerifiedDownload -Uri $uri -Path $target -Sha256 $contentSha -Force
            $result.Reused | Should -BeFalse
            $global:DvDownloads.Count | Should -Be 1
        }

        It 'replaces a file that has another hash, once the new one is verified' {
            $target = Join-Path $work 'tool.zip'
            [IO.File]::WriteAllText($target, 'something else')
            $null = Save-VerifiedDownload -Uri $uri -Path $target -Sha256 $contentSha
            Test-FileSha256 $target $contentSha | Should -BeTrue
        }

        It 'refuses an address that is not https, before any download' {
            foreach ($bad in 'http://downloads.example.invalid/a.zip', 'ftp://downloads.example.invalid/a.zip', 'file:///etc/passwd', 'downloads.example.invalid/a.zip', '\\server\share\a.zip') {
                { Save-VerifiedDownload -Uri $bad -Path (Join-Path $work 'x.zip') -Sha256 $contentSha } | Should -Throw '*Only https*'
            }
            $global:DvDownloads.Count | Should -Be 0
        }

        It 'refuses a hash that is not a SHA-256, before any download' {
            { Save-VerifiedDownload -Uri $uri -Path (Join-Path $work 'x.zip') -Sha256 'deadbeef' } | Should -Throw '*64 hexadecimal digits*'
            $global:DvDownloads.Count | Should -Be 0
        }

        It 'passes the headers on' {
            $null = Save-VerifiedDownload -Uri $uri -Path (Join-Path $work 'x.zip') -Sha256 $contentSha -Headers @{ 'User-Agent' = 'example-client' }
            $global:DvDownloads[0].Headers['User-Agent'] | Should -Be 'example-client'
        }

        It 'throws, and leaves nothing, when the download itself fails' {
            $global:DvFail = $true
            $target = Join-Path $work 'out\tool.zip'
            { Save-VerifiedDownload -Uri $uri -Path $target -Sha256 $contentSha } | Should -Throw '*network down*'
            Test-Path -LiteralPath $target | Should -BeFalse
        }

        It 'throws when the download produced no file' {
            $global:DvBytes.Clear()
            { Save-VerifiedDownload -Uri $uri -Path (Join-Path $work 'x.zip') -Sha256 $contentSha } | Should -Throw '*produced no file*'
        }

        It 'downloads nothing under -WhatIf' {
            $null = Save-VerifiedDownload -Uri $uri -Path (Join-Path $work 'x.zip') -Sha256 $contentSha -WhatIf
            $global:DvDownloads.Count | Should -Be 0
        }
    }

    Describe 'Expand-VerifiedArchive' {
        BeforeEach {
            $zipPath = Join-Path $work 'good.zip'
            New-DvZip -Path $zipPath -Entries @{ 'tool.exe' = 'binary'; 'docs/readme.txt' = 'read me'; 'docs/deep/notes.txt' = 'notes' }
            $zipSha = Get-DvSha $zipPath
            $dest = Join-Path $work 'extracted'
        }

        It 'extracts the files, keeps the folder structure and lists them' {
            $result = Expand-VerifiedArchive -Path $zipPath -Sha256 $zipSha -Destination $dest
            $result.ArchiveSha256 | Should -Be $zipSha
            @($result.Files | Sort-Object) | Should -Be @('docs/deep/notes.txt', 'docs/readme.txt', 'tool.exe')
            [IO.File]::ReadAllText((Join-Path $dest 'tool.exe')) | Should -Be 'binary'
            [IO.File]::ReadAllText((Join-Path (Join-Path $dest 'docs') 'readme.txt')) | Should -Be 'read me'
        }

        It 'extracts nothing when the hash does not match, and does not create the destination' {
            { Expand-VerifiedArchive -Path $zipPath -Sha256 ('3' * 64) -Destination $dest } | Should -Throw '*mismatch*Nothing was extracted*'
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'accepts an existing empty destination and refuses one that is not empty' {
            New-Item -ItemType Directory -Path $dest | Out-Null
            { Expand-VerifiedArchive -Path $zipPath -Sha256 $zipSha -Destination $dest } | Should -Not -Throw
            { Expand-VerifiedArchive -Path $zipPath -Sha256 $zipSha -Destination $dest } | Should -Throw '*not empty*'
        }

        It 'refuses a destination that is a file' {
            $file = Join-Path $work 'a-file'
            [IO.File]::WriteAllText($file, 'x')
            { Expand-VerifiedArchive -Path $zipPath -Sha256 $zipSha -Destination $file } | Should -Throw '*is a file*'
        }

        It 'throws for an archive that is not there' {
            { Expand-VerifiedArchive -Path (Join-Path $work 'missing.zip') -Sha256 $zipSha -Destination $dest } | Should -Throw '*not found*'
        }

        It 'refuses an entry that would extract outside the destination, and writes nothing' {
            foreach ($bad in '../evil.txt', '..\evil.txt', 'a/../../evil.txt', '/evil.txt', 'C:\evil.txt', 'C:evil.txt') {
                $evil = Join-Path $work 'evil.zip'
                New-DvZip -Path $evil -Entries @{ 'fine.txt' = 'fine'; $bad = 'evil' }
                $evilDest = Join-Path (Join-Path $work 'evil-out') ([guid]::NewGuid().ToString('N'))
                { Expand-VerifiedArchive -Path $evil -Sha256 (Get-DvSha $evil) -Destination $evilDest } | Should -Throw '*outside the destination*'
                Test-Path -LiteralPath $evilDest | Should -BeFalse
            }
            Test-Path -LiteralPath (Join-Path $work 'evil.txt') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path (Join-Path $work 'evil-out') 'evil.txt') | Should -BeFalse
        }

        It 'checks a required file and removes the folder it created when one is missing' {
            { Expand-VerifiedArchive -Path $zipPath -Sha256 $zipSha -Destination $dest -Require 'tool.exe', 'missing.dll' } | Should -Throw "*required file 'missing.dll'*"
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'passes when every required file is there, with either kind of slash' {
            { Expand-VerifiedArchive -Path $zipPath -Sha256 $zipSha -Destination $dest -Require 'tool.exe', 'docs/readme.txt', 'docs\deep\notes.txt' } | Should -Not -Throw
        }

        It 'refuses a forbidden file name anywhere in the archive, before extracting' {
            { Expand-VerifiedArchive -Path $zipPath -Sha256 $zipSha -Destination $dest -Forbid 'notes.*' } | Should -Throw '*not allowed*Nothing was extracted*'
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'refuses an archive that would expand beyond the size limit' {
            $big = Join-Path $work 'big.zip'
            New-DvZip -Path $big -Entries @{ 'zeros.bin' = ('0' * (2MB)) }
            { Expand-VerifiedArchive -Path $big -Sha256 (Get-DvSha $big) -Destination (Join-Path $work 'big-out') -MaxExpandedMB 1 } | Should -Throw '*more than 1 MB*'
            Test-Path -LiteralPath (Join-Path $work 'big-out') | Should -BeFalse
        }

        It 'extracts nothing under -WhatIf' {
            $null = Expand-VerifiedArchive -Path $zipPath -Sha256 $zipSha -Destination $dest -WhatIf
            Test-Path -LiteralPath $dest | Should -BeFalse
        }
    }

    Describe 'Install-VerifiedDownload' {
        BeforeEach {
            $zipPath = Join-Path $work 'release.zip'
            New-DvZip -Path $zipPath -Entries @{ 'pkg-1.2/bin/tool.exe' = 'the tool'; 'pkg-1.2/readme.txt' = 'read me' }
            $zipSha = Get-DvSha $zipPath
            $global:DvBytes[$uri] = [IO.File]::ReadAllBytes($zipPath)
            $dest = Join-Path $work 'installed'
            $tempBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'download-verified-*' -ErrorAction SilentlyContinue).Count
        }

        It 'installs the named file, hashes the installed copy and returns a receipt' {
            $receipt = Install-VerifiedDownload -Uri $uri -Sha256 $zipSha -Destination $dest -Pick 'tool.exe'
            [IO.File]::ReadAllText((Join-Path $dest 'tool.exe')) | Should -Be 'the tool'
            Test-Path -LiteralPath (Join-Path $dest 'readme.txt') | Should -BeFalse
            $receipt.Uri | Should -Be $uri
            $receipt.ArchiveName | Should -Be 'tool-1.2.zip'
            $receipt.ArchiveSha256 | Should -Be $zipSha
            $receipt.ArchiveBytes | Should -Be (Get-Item -LiteralPath $zipPath).Length
            @($receipt.Installed).Count | Should -Be 1
            $receipt.Installed[0].Path | Should -Be (Join-Path ([IO.Path]::GetFullPath($dest)) 'tool.exe')
            $receipt.Installed[0].Sha256 | Should -Be (Get-DvSha (Join-Path $dest 'tool.exe'))
            $receipt.InstalledAtUtc | Should -Match '^\d{4}-\d\d-\d\dT'
        }

        It 'writes the receipt as UTF-8 JSON without a byte order mark, with the extra fields' {
            $path = Join-Path (Join-Path $work 'receipts') 'tool.json'
            $null = Install-VerifiedDownload -Uri $uri -Sha256 $zipSha -Destination $dest -Pick 'tool.exe' -ReceiptPath $path -ReceiptExtra @{ Version = '1.2' }
            $bytes = [IO.File]::ReadAllBytes($path)
            ($bytes[0] -eq 0xEF) | Should -BeFalse
            $json = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
            $json.Version | Should -Be '1.2'
            $json.ArchiveSha256 | Should -Be $zipSha
            $json.Installed[0].Sha256 | Should -Not -BeNullOrEmpty
        }

        It 'installs several files' {
            $null = Install-VerifiedDownload -Uri $uri -Sha256 $zipSha -Destination $dest -Pick 'tool.exe', 'readme.txt'
            @(Get-ChildItem -LiteralPath $dest).Count | Should -Be 2
        }

        It 'throws when a named file is not in the archive, and installs nothing' {
            { Install-VerifiedDownload -Uri $uri -Sha256 $zipSha -Destination $dest -Pick 'tool.exe', 'nope.exe' } | Should -Throw "*does not contain 'nope.exe'*"
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'throws when a name matches two files, and installs nothing' {
            $dup = Join-Path $work 'dup.zip'
            New-DvZip -Path $dup -Entries @{ 'a/tool.exe' = 'one'; 'b/tool.exe' = 'two' }
            $global:DvBytes[$uri] = [IO.File]::ReadAllBytes($dup)
            { Install-VerifiedDownload -Uri $uri -Sha256 (Get-DvSha $dup) -Destination $dest -Pick 'tool.exe' } | Should -Throw '*more than one*Nothing was installed*'
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'installs nothing when the archive hash does not match' {
            { Install-VerifiedDownload -Uri $uri -Sha256 ('4' * 64) -Destination $dest -Pick 'tool.exe' } | Should -Throw '*mismatch*'
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'leaves no temporary folder behind, on success or on failure' {
            $null = Install-VerifiedDownload -Uri $uri -Sha256 $zipSha -Destination $dest -Pick 'tool.exe'
            { Install-VerifiedDownload -Uri $uri -Sha256 ('4' * 64) -Destination $dest -Pick 'tool.exe' } | Should -Throw
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'download-verified-*' -ErrorAction SilentlyContinue).Count | Should -Be $tempBefore
        }

        It 'downloads nothing under -WhatIf' {
            $null = Install-VerifiedDownload -Uri $uri -Sha256 $zipSha -Destination $dest -Pick 'tool.exe' -WhatIf
            $global:DvDownloads.Count | Should -Be 0
            Test-Path -LiteralPath $dest | Should -BeFalse
        }

        It 'refuses an address that is not https' {
            { Install-VerifiedDownload -Uri 'http://downloads.example.invalid/tool.zip' -Sha256 $zipSha -Destination $dest -Pick 'tool.exe' } | Should -Throw '*Only https*'
        }
    }
}
