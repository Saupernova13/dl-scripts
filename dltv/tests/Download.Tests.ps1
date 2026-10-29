# Offline tests for the download side: file naming, the HLS playlist parser and decryptor, and
# the job store. Only the filesystem (a temp dir) is touched.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Lib  = Join-Path (Split-Path -Parent $script:Root) 'lib'
    . (Join-Path $script:Lib 'Platform.ps1')
    . (Join-Path $script:Root 'KissKH.ps1')
    . (Join-Path $script:Root 'Jobs.ps1')
    . (Join-Path $script:Root 'Download.ps1')
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
}

Describe 'naming' {
    It 'strips filesystem-hostile characters and trailing dots' {
        Get-DltvSafeName 'Who: Am I? <1> "x" a/b\c|d*.' | Should -Be 'Who Am I 1 x abcd'
        Get-DltvSafeName '  Title...  ' | Should -Be 'Title'
        Get-DltvSafeName '???' | Should -Be 'KissKH'
    }
    It 'builds the episode stem' {
        Get-DltvEpisodeStem -Title 'Bad Buddy' -Number 7  | Should -Be 'Bad Buddy S01E07'
        Get-DltvEpisodeStem -Title 'Bad Buddy' -Number 12 | Should -Be 'Bad Buddy S01E12'
    }
}

Describe 'HLS playlists' {
    It 'picks the highest-bandwidth variant of a master playlist and resolves it' {
        $master = @'
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080
../hi/index.m3u8?t=1
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720
mid/index.m3u8
'@
        Get-DltvHlsBestVariant -Text $master -BaseUri 'https://cdn.example/a/b/master.m3u8' |
            Should -Be 'https://cdn.example/a/hi/index.m3u8?t=1'
    }

    It 'returns null for a media playlist' {
        Get-DltvHlsBestVariant -Text "#EXTM3U`n#EXTINF:4,`nseg0.ts`n" -BaseUri 'https://cdn.example/x.m3u8' | Should -BeNullOrEmpty
    }

    It 'resolves relative, root-relative and absolute segment URIs' {
        $pl = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/a/b/index.m3u8' -Text @'
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:7
#EXTINF:4,
seg0.ts
#EXTINF:4,
/root/seg1.ts
#EXTINF:4,
https://other.example/seg2.ts?x=1
'@
        $pl.Segments.Count | Should -Be 3
        $pl.Segments[0].Uri | Should -Be 'https://cdn.example/a/b/seg0.ts'
        $pl.Segments[1].Uri | Should -Be 'https://cdn.example/root/seg1.ts'
        $pl.Segments[2].Uri | Should -Be 'https://other.example/seg2.ts?x=1'
        $pl.Segments[0].Sequence | Should -Be 7
        $pl.Segments[2].Sequence | Should -Be 9
        $pl.Map | Should -BeNullOrEmpty
    }

    It 'parses AES-128 KEY with an explicit IV, and EXT-X-MAP' {
        $pl = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/v/index.m3u8' -Text @'
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXT-X-KEY:METHOD=AES-128,URI="keys/k1.bin",IV=0x000102030405060708090A0B0C0D0E0F
#EXTINF:4,
a.m4s
#EXT-X-KEY:METHOD=NONE
#EXTINF:4,
b.m4s
'@
        $pl.Map | Should -Be 'https://cdn.example/v/init.mp4'
        $pl.Segments[0].Key.Uri    | Should -Be 'https://cdn.example/v/keys/k1.bin'
        $pl.Segments[0].Key.IvText | Should -Be '0x000102030405060708090A0B0C0D0E0F'
        $pl.Segments[1].Key | Should -BeNullOrEmpty
    }

    It 'rejects unsupported encryption' {
        { Read-DltvHlsMediaPlaylist -BaseUri 'https://x/y.m3u8' -Text "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=`"k`"`nseg.ts" } | Should -Throw
    }

    It 'turns an explicit IV into 16 bytes' {
        $iv = Get-DltvHlsIvBytes -IvText '0x000102030405060708090A0B0C0D0E0F' -Sequence 0
        $iv.Length | Should -Be 16
        (($iv | ForEach-Object { $_.ToString('x2') }) -join '') | Should -Be '000102030405060708090a0b0c0d0e0f'
    }

    It 'uses the media sequence as a big-endian IV when none is given' {
        $iv = Get-DltvHlsIvBytes -IvText $null -Sequence 258
        $iv.Length | Should -Be 16
        (($iv | ForEach-Object { $_.ToString('x2') }) -join '') | Should -Be '00000000000000000000000000000102'
    }

    It 'decrypts a segment encrypted with the parsed key and IV' {
        $key  = [byte[]](1..16)
        $iv   = Get-DltvHlsIvBytes -IvText $null -Sequence 5
        $data = [System.Text.Encoding]::ASCII.GetBytes('segment payload that is longer than one block')
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $key; $aes.IV = $iv
        $cipher = $aes.CreateEncryptor().TransformFinalBlock($data, 0, $data.Length)
        $plain = ConvertFrom-DltvHlsSegment -Data $cipher -Key $key -Iv $iv
        [System.Text.Encoding]::ASCII.GetString($plain) | Should -Be 'segment payload that is longer than one block'
    }
}

Describe 'HLS byte ranges' {
    BeforeAll {
        $script:U = 'https://cdn.example/4659/Ep1_index0.ts'
        $script:RangePl = @"
#EXTM3U
#EXT-X-VERSION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.5,
#EXT-X-BYTERANGE:531288@0
$script:U
#EXTINF:6.0,
#EXT-X-BYTERANGE:1451360@531288
$script:U
#EXTINF:5.7,
#EXT-X-BYTERANGE:1540472@1982648
$script:U
"@
    }

    It 'parses explicit offsets' {
        $pl = Read-DltvHlsMediaPlaylist -Text $script:RangePl -BaseUri 'https://cdn.example/x.m3u8'
        $pl.Segments.Count | Should -Be 3
        $pl.Segments[1].Range.Start  | Should -Be 531288
        $pl.Segments[1].Range.Length | Should -Be 1451360
        $pl.Segments[1].Range.End    | Should -Be (531288 + 1451360 - 1)
        (Get-DltvCurlRange $pl.Segments[2].Range) | Should -Be '1982648-3523119'
    }

    It 'continues an implicit offset from the previous range of the same URI' {
        $pl = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text @'
#EXTM3U
#EXT-X-BYTERANGE:100@50
a.ts
#EXT-X-BYTERANGE:200
a.ts
#EXT-X-BYTERANGE:10
b.ts
#EXT-X-BYTERANGE:30
a.ts
'@
        $pl.Segments[0].Range.Start | Should -Be 50
        $pl.Segments[1].Range.Start | Should -Be 150
        $pl.Segments[1].Range.End   | Should -Be 349
        $pl.Segments[2].Range.Start | Should -Be 0
        $pl.Segments[3].Range.Start | Should -Be 350
    }

    It 'leaves segments without BYTERANGE as whole files' {
        $pl = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text "#EXTINF:4,`na.ts`n#EXT-X-BYTERANGE:5@0`nb.ts`n#EXTINF:4,`nc.ts`n"
        $pl.Segments[0].Range | Should -BeNullOrEmpty
        $pl.Segments[1].Range.Length | Should -Be 5
        $pl.Segments[2].Range | Should -BeNullOrEmpty
    }

    It 'detects one contiguous file and reports its length' {
        $pl = Read-DltvHlsMediaPlaylist -Text $script:RangePl -BaseUri 'https://cdn.example/x.m3u8'
        $single = Get-DltvHlsSingleFile $pl
        $single.Uri | Should -Be $script:U
        $single.Length | Should -Be 3523120
    }

    It 'is not a single file when URIs are mixed' {
        $pl = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text "#EXT-X-BYTERANGE:10@0`na.ts`n#EXT-X-BYTERANGE:10@10`nb.ts`n"
        Get-DltvHlsSingleFile $pl | Should -BeNullOrEmpty
    }

    It 'is not a single file when ranges leave a gap or do not start at 0' {
        $gap = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text "#EXT-X-BYTERANGE:10@0`na.ts`n#EXT-X-BYTERANGE:10@20`na.ts`n"
        Get-DltvHlsSingleFile $gap | Should -BeNullOrEmpty
        $late = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text "#EXT-X-BYTERANGE:10@5`na.ts`n"
        Get-DltvHlsSingleFile $late | Should -BeNullOrEmpty
    }

    It 'is not a single file when encrypted, mapped, or any segment lacks a range' {
        $enc = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text "#EXT-X-KEY:METHOD=AES-128,URI=`"k`"`n#EXT-X-BYTERANGE:10@0`na.ts`n"
        Get-DltvHlsSingleFile $enc | Should -BeNullOrEmpty
        $map = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text "#EXT-X-MAP:URI=`"i.mp4`"`n#EXT-X-BYTERANGE:10@0`na.ts`n"
        Get-DltvHlsSingleFile $map | Should -BeNullOrEmpty
        $plain = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text "#EXT-X-BYTERANGE:10@0`na.ts`na.ts`n"
        Get-DltvHlsSingleFile $plain | Should -BeNullOrEmpty
    }
}

Describe 'HLS whole-file groups' {
    It 'finds two files, each a contiguous run from 0 (how KissKH serves a long episode)' {
        $pl = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text @'
#EXT-X-BYTERANGE:100@0
https://h/Ep1_index0.ts
#EXT-X-BYTERANGE:200@100
https://h/Ep1_index0.ts
#EXT-X-BYTERANGE:50@0
https://h/Ep1_index1.ts
#EXT-X-BYTERANGE:70
https://h/Ep1_index1.ts
'@
        $files = @(Get-DltvHlsWholeFiles $pl)
        $files.Count | Should -Be 2
        $files[0].Uri | Should -Be 'https://h/Ep1_index0.ts'
        $files[0].Length | Should -Be 300
        $files[1].Length | Should -Be 120
        Get-DltvHlsSingleFile $pl | Should -BeNullOrEmpty
    }

    It 'rejects a URI that comes back after another one' {
        $pl = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text "#EXT-X-BYTERANGE:10@0`na.ts`n#EXT-X-BYTERANGE:10@0`nb.ts`n#EXT-X-BYTERANGE:10@10`na.ts`n"
        Get-DltvHlsWholeFiles $pl | Should -BeNullOrEmpty
    }

    It 'rejects a second file that does not start at 0' {
        $pl = Read-DltvHlsMediaPlaylist -BaseUri 'https://cdn.example/x.m3u8' -Text "#EXT-X-BYTERANGE:10@0`na.ts`n#EXT-X-BYTERANGE:10@5`nb.ts`n"
        Get-DltvHlsWholeFiles $pl | Should -BeNullOrEmpty
    }
}

Describe 'curl plumbing' {
    It 'quotes arguments for CommandLineToArgvW' {
        ConvertTo-DltvArgument 'plain' | Should -Be 'plain'
        ConvertTo-DltvArgument 'https://h/a.mp4?x=1&y=2' | Should -Be 'https://h/a.mp4?x=1&y=2'
        ConvertTo-DltvArgument 'C:\a b\c.part' | Should -Be '"C:\a b\c.part"'
        ConvertTo-DltvArgument 'say "hi"' | Should -Be '"say \"hi\""'
        ConvertTo-DltvArgument 'C:\a b\' | Should -Be '"C:\a b\\"'
        ConvertTo-DltvArgument '' | Should -Be '""'
    }

    It 'carries the stall protection flags' {
        $f = $script:DLTV_CURL_COMMON -join ' '
        $f | Should -Match '--connect-timeout 20'
        $f | Should -Match '--speed-limit 1024 --speed-time 60'
    }

    It 'reads the live length of a file another handle is still writing' {
        $p = Join-Path ([System.IO.Path]::GetTempPath()) "dltv-live-$([guid]::NewGuid().ToString('N')).bin"
        $w = New-Object System.IO.FileStream($p, 'Create', 'Write', 'ReadWrite')
        try {
            $w.Write((New-Object byte[] 1000), 0, 1000); $w.Flush()
            Get-DltvFileLength $p | Should -Be 1000
            $w.Write((New-Object byte[] 5000), 0, 5000); $w.Flush()
            Get-DltvFileLength $p | Should -Be 6000
        } finally { $w.Dispose(); Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }

    It 'returns 0 for a missing file' {
        Get-DltvFileLength (Join-Path ([System.IO.Path]::GetTempPath()) 'dltv-nope-file.bin') | Should -Be 0
    }
}

Describe 'job store' {
    BeforeAll {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dltv-tests-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
        $script:SavedXdg   = $env:XDG_DATA_HOME
        $script:SavedLocal = $env:LOCALAPPDATA
        # Redirect the data root so the tests never touch the real job directory.
        if (Test-DlWindows) { $env:LOCALAPPDATA = $script:TestRoot } else { $env:XDG_DATA_HOME = $script:TestRoot }

        function New-TestJob {
            return (New-DltvJob -Title 'Bad Buddy' -DramaId 4540 -BaseUrl 'https://kisskh.co' `
                        -Destination (Join-Path $script:TestRoot 'out') `
                        -Episodes @([PSCustomObject]@{ Id = 11; Number = 1 }, [PSCustomObject]@{ Id = 12; Number = 2 }) `
                        -SubLangs @('en'))
        }
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:SavedLocal
        $env:XDG_DATA_HOME = $script:SavedXdg
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'keeps jobs under the data root, in dltv/jobs' {
        (Get-DltvJobsDir) | Should -BeLike (Join-Path $script:TestRoot '*')
        (Get-DltvJobsDir) | Should -Match 'dltv'
    }

    It 'round-trips a job through its file, including non-ASCII titles' {
        $j = New-TestJob
        $j.title = "Caf$([char]0xE9) $([char]0x4E2D)"
        Save-DltvJob -Job $j -Strict
        $back = Read-DltvJob $j.id
        $back.title | Should -Be $j.title
        $back.total | Should -Be 2
        @($back.episodes).Count | Should -Be 2
        $back.status | Should -Be 'pending'
    }

    It 'ends failed only when zero episodes succeeded' {
        $a = New-TestJob; $a.done = 0; Save-DltvJob $a
        Complete-DltvJob -Job $a -Message '0/2 episodes; failed: E01, E02'
        $a.status | Should -Be 'failed'

        $b = New-TestJob; $b.done = 1; Save-DltvJob $b
        Complete-DltvJob -Job $b -Message '1/2 episodes; failed: E02'
        $b.status | Should -Be 'completed'
        $b.completedAt | Should -Not -BeNullOrEmpty
    }

    It 'reports an active job with a dead pid as orphaned' {
        $j = New-TestJob
        $j.status = 'running'
        $j.pid = 2147483000
        Resolve-DltvJobStatus $j | Should -Be 'orphaned'
        $j.pid = $PID
        Resolve-DltvJobStatus $j | Should -Be 'running'
        $j.status = 'completed'; $j.pid = 2147483000
        Resolve-DltvJobStatus $j | Should -Be 'completed'
    }

    It 'prunes old finished jobs but never an active one' {
        $old = New-TestJob; $old.status = 'completed'; Save-DltvJob $old
        $act = New-TestJob; $act.status = 'running'; $act.pid = $PID; Save-DltvJob $act
        foreach ($j in @($old, $act)) {
            (Get-Item -LiteralPath $j.jobFile).LastWriteTime = (Get-Date).AddDays(-30)
        }
        Remove-OldDltvJobs -KeepDays 7
        Test-Path -LiteralPath $old.jobFile | Should -BeFalse
        Test-Path -LiteralPath $act.jobFile | Should -BeTrue
    }

    It 'shows an unknown job without throwing' {
        Show-DltvJobStatus -JobId 'doesnotexist' | Should -BeFalse
    }
}
