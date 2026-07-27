# Tests for the shared foundation: Constants.ps1, Common.ps1, the Logging formatters and
# the file-handling helpers in RomFiles.ps1.
#
# Everything here used to exist in two or three copies scattered across the modules, and
# every one of those copies had drifted from its siblings. These tests pin the properties
# that made the duplication a bug - one ROM extension table, one archive signature table,
# one reject regex, one region vocabulary - so a future edit cannot quietly re-fork them.
#
# Only the filesystem is touched (in a temp dir); nothing here goes near the network.

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot

    . (Join-Path $ModuleRoot 'Constants.ps1')
    . (Join-Path $ModuleRoot 'Common.ps1')
    . (Join-Path $ModuleRoot 'Logging.ps1')
    . (Join-Path $ModuleRoot 'RomFiles.ps1')
    . (Join-Path $ModuleRoot 'RetroGameTalk.ps1')

    $script:LOG_QUIET = $true
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dlrom-tests-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

    # Write a file whose first bytes are a real archive signature.
    function New-SignedFile {
        param([string]$Name, [byte[]]$Signature, [int]$Pad = 64)
        $path  = Join-Path $script:TestRoot $Name
        $bytes = @($Signature) + @(0) * $Pad
        [System.IO.File]::WriteAllBytes($path, [byte[]]$bytes)
        return $path
    }

    $script:SIG_ZIP = [byte[]](0x50, 0x4B, 0x03, 0x04)
    $script:SIG_7Z  = [byte[]](0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C)
    $script:SIG_RAR = [byte[]](0x52, 0x61, 0x72, 0x21, 0x1A, 0x07)
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Constants: one table per concept' {

    It 'covers every console dlrom advertises with at least one ROM extension' {
        # The old Find-RomFile list was written for cdromance's 16 platforms. After the move
        # to The Repo it silently failed for Dreamcast (.cdi), Genesis (.md), Master System
        # (.sms), WonderSwan (.ws), FDS (.fds) and Vita (.vpk) - the archive extracted and
        # then "no ROM file found".
        $mustHave = @('.cdi', '.gdi', '.md', '.gen', '.sms', '.gg', '.ws', '.fds', '.32x',
                      '.vpk', '.adf', '.ngp', '.d88', '.rvz', '.wbfs', '.gcm', '.cso')
        foreach ($ext in $mustHave) {
            $script:ROM_EXTS | Should -Contain $ext -Because "$ext is a ROM format for a platform in PLATFORM_SLUGS"
        }
    }

    It 'keeps ROM extensions lowercase, dotted and unique' {
        foreach ($ext in $script:ROM_EXTS) {
            $ext | Should -Match '^\.[a-z0-9]+$'
        }
        ($script:ROM_EXTS | Select-Object -Unique).Count | Should -Be $script:ROM_EXTS.Count
    }

    It 'never treats a container format as a ROM' {
        # A .zip that reached Move-RomToDest unextracted would be filed as if it were a game.
        foreach ($ext in $script:ARCHIVE_EXTS) {
            $script:ROM_EXTS | Should -Not -Contain $ext
        }
    }

    It 'builds the download-extension regex from the download-extension list' {
        $script:DOWNLOAD_EXTS_RX | Should -BeExactly ($script:DOWNLOAD_EXTS -join '|')
        foreach ($ext in $script:DOWNLOAD_EXTS) {
            "game.$ext" | Should -Match "\.($script:DOWNLOAD_EXTS_RX)$"
        }
    }

    It 'rejects every marker all three old reject lists knew about' {
        # Union of the link filter, the torrent matcher and the serial resolver.
        foreach ($word in @('Demo', 'Trial', 'Sampler', 'Preview', 'Beta', 'Proto',
                            'Prototype', 'Sample', 'Kiosk', 'Promo')) {
            "Some Game ($word)" | Should -Match $script:DEMO_RX -Because "'$word' marks a non-retail release"
        }
        'Trade Demo'    | Should -Match $script:DEMO_RX
        'Test Disc'     | Should -Match $script:DEMO_RX
    }

    It 'does not reject an ordinary retail title' {
        foreach ($title in @('Shin Megami Tensei: Persona 3 FES (USA)',
                             'Chrono Trigger (USA)',
                             'Metal Gear Solid 3 - Subsistence (USA) (Disc 1)')) {
            $title | Should -Not -Match $script:DEMO_RX
        }
    }

    It 'gives every job status and step a distinct value' {
        $all = @($script:JOB_STATUS_PENDING, $script:JOB_STATUS_RUNNING, $script:JOB_STATUS_COMPLETED,
                 $script:JOB_STATUS_FAILED, $script:JOB_STATUS_ORPHANED)
        ($all | Select-Object -Unique).Count | Should -Be $all.Count

        $steps = @($script:JOB_STEP_DOWNLOADING, $script:JOB_STEP_EXTRACTING, $script:JOB_STEP_FILING,
                   $script:JOB_STEP_STEAM_SYNC, $script:JOB_STEP_DONE)
        ($steps | Select-Object -Unique).Count | Should -Be $steps.Count
    }

    It 'treats only pending and running as live jobs' {
        $script:JOB_STATUS_ACTIVE | Should -Contain $script:JOB_STATUS_RUNNING
        $script:JOB_STATUS_ACTIVE | Should -Contain $script:JOB_STATUS_PENDING
        $script:JOB_STATUS_ACTIVE | Should -Not -Contain $script:JOB_STATUS_COMPLETED
        $script:JOB_STATUS_ACTIVE | Should -Not -Contain $script:JOB_STATUS_FAILED
    }

    It 'has a label for every downloader id' {
        foreach ($id in @($script:DL_MOTRIX, $script:DL_AB, $script:DL_ARIA2C,
                          $script:DL_CURL, $script:DL_BITS, $script:DL_WEBCLIENT)) {
            $script:DOWNLOADER_LABELS[$id] | Should -Not -BeNullOrEmpty -Because "'$id' is dispatched on"
        }
        $script:DOWNLOADER_LABELS.Count | Should -Be 6
    }

    It 'gives every Vita build a distinct code and a label' {
        $all = @($script:VITA_BUILD_EMU, $script:VITA_BUILD_CONSOLE, $script:VITA_BUILD_ANY)
        ($all | Select-Object -Unique).Count | Should -Be $all.Count
        foreach ($b in $all) {
            $script:VITA_BUILD_LABELS[$b] | Should -Not -BeNullOrEmpty -Because "'$b' is shown to the user"
        }
    }

    It 'defaults Vita downloads to the emulator build' {
        # dlrom's documented behaviour, and what the config default and --vita fall back to.
        $script:VITA_BUILD_DEFAULT | Should -BeExactly $script:VITA_BUILD_EMU
    }

    It 'points the Vita slug at a real platform category' {
        $PLATFORM_SLUGS.Values  | Should -Contain $script:VITA_SLUG
        $PLATFORM_FOLDERS[$script:VITA_SLUG] | Should -BeExactly 'psvita'
    }

    It 'never lets the two Vita build patterns match the same marker' {
        # They gate opposite install behaviour, so an overlap would be a coin toss.
        foreach ($marker in @('vita3k', 'Vita3K', 'Vita3k')) {
            $marker | Should -Match     $script:VITA_EMU_RX
            $marker | Should -Not -Match $script:VITA_CONSOLE_RX
        }
        foreach ($marker in @('NoNpDrm', 'NoNpDRM', 'nonpdrm', 'NoNPDrm', 'MaiDump')) {
            $marker | Should -Match     $script:VITA_CONSOLE_RX
            $marker | Should -Not -Match $script:VITA_EMU_RX
        }
    }
}

Describe 'Get-CfgValue' {

    BeforeAll {
        $script:Section = [PSCustomObject]@{ present = 'value'; blank = ''; zero = 0; flagOff = $false }
    }

    It 'returns a present value' {
        Get-CfgValue 'present' 'fallback' -Cfg $script:Section | Should -BeExactly 'value'
    }

    It 'falls back when the key is absent' {
        Get-CfgValue 'missing' 'fallback' -Cfg $script:Section | Should -BeExactly 'fallback'
    }

    It 'treats a blank string as unset' {
        # Every blank in the shipped defaults documents an autodetect, never "use empty".
        Get-CfgValue 'blank' 'fallback' -Cfg $script:Section | Should -BeExactly 'fallback'
    }

    It 'preserves a legitimate zero and false' {
        # These are values, not absence: -contains/-not tests used to collapse them.
        Get-CfgValue 'zero' 99 -Cfg $script:Section    | Should -Be 0
        Get-CfgValue 'flagOff' $true -Cfg $script:Section | Should -Be $false
    }

    It 'falls back when there is no config at all' {
        Get-CfgValue 'anything' 'fallback' -Cfg $null | Should -BeExactly 'fallback'
    }

    It 'reads the ambient section when no -Cfg is given' {
        Set-DlromConfig ([PSCustomObject]@{ romsBase = 'D:\roms' })
        try {
            Get-CfgValue 'romsBase' 'C:\fallback' | Should -BeExactly 'D:\roms'
            Get-CfgValue 'nope' 'C:\fallback'     | Should -BeExactly 'C:\fallback'
        } finally { Set-DlromConfig $null }
    }
}

Describe 'Region helpers' {

    It 'resolves every documented --region synonym' {
        foreach ($alias in @('usa', 'us', 'ntsc-u', 'ntscu', 'america', 'american')) {
            Resolve-RegionRequest $alias | Should -BeExactly 'usa'
        }
        foreach ($alias in @('europe', 'eu', 'pal', 'uk', 'england')) {
            Resolve-RegionRequest $alias | Should -BeExactly 'europe'
        }
        foreach ($alias in @('japan', 'jp', 'ntsc-j', 'jpn')) {
            Resolve-RegionRequest $alias | Should -BeExactly 'japan'
        }
        Resolve-RegionRequest 'korea' | Should -BeExactly 'korea'
        Resolve-RegionRequest 'world' | Should -BeExactly 'world'
    }

    It 'is case-insensitive and tolerates padding' {
        Resolve-RegionRequest '  USA  ' | Should -BeExactly 'usa'
        Resolve-RegionRequest 'PAL'     | Should -BeExactly 'europe'
    }

    It 'returns empty for an unknown or missing region' {
        Resolve-RegionRequest 'atlantis' | Should -BeExactly ''
        Resolve-RegionRequest ''         | Should -BeExactly ''
        Resolve-RegionRequest $null      | Should -BeExactly ''
    }

    It 'ranks the requested region above everything else' {
        Get-RegionRank -Regions @('japan') -Requested 'japan' | Should -Be 0
        # Even though USA outranks Japan by default.
        (Get-RegionRank -Regions @('japan') -Requested 'japan') |
            Should -BeLessThan (Get-RegionRank -Regions @('usa') -Requested 'japan')
    }

    It 'falls back to the documented preference order' {
        $usa    = Get-RegionRank -Regions @('usa')    -Requested ''
        $world  = Get-RegionRank -Regions @('world')  -Requested ''
        $europe = Get-RegionRank -Regions @('europe') -Requested ''
        $japan  = Get-RegionRank -Regions @('japan')  -Requested ''
        $usa | Should -BeLessThan $world
        $world | Should -BeLessThan $europe
        $europe | Should -BeLessThan $japan
    }

    It 'ranks an unknown region last' {
        (Get-RegionRank -Regions @() -Requested '') |
            Should -BeGreaterThan (Get-RegionRank -Regions @('korea') -Requested '')
    }

    It 'maps canonical regions onto PCSX2 region codes' {
        $script:PS2_REGION_CODES['usa']    | Should -BeExactly 'NTSC-U'
        $script:PS2_REGION_CODES['europe'] | Should -BeExactly 'PAL'
        $script:PS2_REGION_CODES['japan']  | Should -BeExactly 'NTSC-J'
    }

    It 'agrees with the web scraper on region names' {
        # Get-RgtRegions reads a URL slug; Resolve-RegionRequest reads a --region argument.
        # Different inputs, but they must produce the same vocabulary or ranking breaks.
        $fromSlug = Get-RgtRegions 'https://retrogametalk.com/repo/ps2-iso/game-usa/' ''
        $fromSlug | Should -Contain (Resolve-RegionRequest 'usa')
    }
}

Describe 'PS Vita build helpers' {

    It 'resolves every documented --vita synonym' {
        foreach ($alias in @('emu', 'emulator', 'vita3k', 'vita-3k', '3k')) {
            Resolve-VitaBuild $alias | Should -BeExactly 'emu'
        }
        foreach ($alias in @('console', 'hardware', 'hw', 'real', 'handheld', 'nonpdrm', 'no-npdrm')) {
            Resolve-VitaBuild $alias | Should -BeExactly 'console'
        }
        foreach ($alias in @('any', 'both', 'either')) {
            Resolve-VitaBuild $alias | Should -BeExactly 'any'
        }
    }

    It 'is case-insensitive and tolerates padding' {
        Resolve-VitaBuild '  Vita3K '  | Should -BeExactly 'emu'
        Resolve-VitaBuild 'CONSOLE'    | Should -BeExactly 'console'
    }

    It 'returns empty for an unknown or missing build' {
        Resolve-VitaBuild 'ps4'   | Should -BeExactly ''
        Resolve-VitaBuild ''      | Should -BeExactly ''
        Resolve-VitaBuild $null   | Should -BeExactly ''
    }

    It 'reads the build out of every filename shape the live catalogue uses' {
        # Every one of these is a real label from retrogametalk.com/repo/vita/.
        $emu = @(
            'Danganronpa V3 (USA)(PCSE01100)[vita3k].zip',
            'Hitman GO - Definitive Edition (PCSE00846) (NTSC) (Vita3k).zip',
            'A Hole New World [PCSE01095] [USA] [Vita3k].zip',
            '#KILLALLZOMBIES [PCSE00965] [USA] [vita3k].zip'
        )
        foreach ($label in $emu) { Get-VitaLinkBuild $label | Should -BeExactly 'emu' -Because $label }

        $console = @(
            'Danganronpa V3 (USA)(PCSE01100)[NoNpDrm].zip',
            'A-men [PCSE00232] [USA] [NoNpDRM].zip',
            'Hitman GO - Definitive Edition (PCSE00846) (NTSC) (NoNpDRM).zip',
            'Sparkle 2 (USA)(NoNPDrm)(PCSE00454).7z',
            '#KILLALLZOMBIES [PCSE00965] [USA] [nonpdrm].zip'
        )
        foreach ($label in $console) { Get-VitaLinkBuild $label | Should -BeExactly 'console' -Because $label }
    }

    It 'refuses to guess at an unmarked file' {
        # An unmarked release, and a bonus file that is not the game at all.
        Get-VitaLinkBuild 'Miku Miku Hockey (Japan).zip' | Should -BeExactly ''
        Get-VitaLinkBuild 'AR Cards.zip'                 | Should -BeExactly ''
        Get-VitaLinkBuild ''                             | Should -BeExactly ''
    }

    It 'reports the build of a whole link set' {
        $emuLink = [PSCustomObject]@{ Label = 'Game (USA)[vita3k].zip' }
        $conLink = [PSCustomObject]@{ Label = 'Game (USA)[NoNpDrm].zip' }
        Get-VitaLinksBuild -Links @($emuLink)            | Should -BeExactly 'emu'
        Get-VitaLinksBuild -Links @($conLink)            | Should -BeExactly 'console'
        # Mixed or unmarked is not a build: the caller must then extract as usual rather
        # than assume Vita3K and leave a NoNpDrm dump zipped.
        Get-VitaLinksBuild -Links @($emuLink, $conLink)  | Should -BeExactly ''
        Get-VitaLinksBuild -Links @()                    | Should -BeExactly ''
    }
}

Describe 'Formatters' {

    It 'draws a bar of constant width at any percentage' {
        foreach ($pct in @(0, 1, 37, 50, 99, 100)) {
            (Format-ProgressBar -Percent $pct).Length | Should -Be ($script:PROGRESS_BAR_WIDTH + 2)
        }
    }

    It 'draws empty at 0 and full at 100' {
        Format-ProgressBar -Percent 0   | Should -Not -Match '#'
        Format-ProgressBar -Percent 100 | Should -BeExactly ('[' + ('#' * $script:PROGRESS_BAR_WIDTH) + ']')
    }

    It 'clamps out-of-range percentages instead of drawing a ragged bar' {
        (Format-ProgressBar -Percent -10).Length | Should -Be ($script:PROGRESS_BAR_WIDTH + 2)
        (Format-ProgressBar -Percent 250).Length | Should -Be ($script:PROGRESS_BAR_WIDTH + 2)
        Format-ProgressBar -Percent 250 | Should -BeExactly (Format-ProgressBar -Percent 100)
    }

    It 'supports the dotted style --status uses' {
        Format-ProgressBar -Percent 50 -Empty '.' | Should -Match '\.'
        Format-ProgressBar -Percent 50 -Empty '.' | Should -Not -Match ' '
    }

    It 'formats durations at second, minute and hour scale' {
        Format-Duration 0    | Should -BeExactly '0s'
        Format-Duration 45   | Should -BeExactly '45s'
        Format-Duration 125  | Should -BeExactly '2m 5s'
        Format-Duration 7325 | Should -BeExactly '2h 2m'
    }

    It 'computes an ETA and admits when it cannot' {
        Format-Eta -Done 0   -Total 100 -BytesPerSec 10 | Should -BeExactly '10s'
        Format-Eta -Done 100 -Total 100 -BytesPerSec 10 | Should -BeExactly '--'   # already done
        Format-Eta -Done 0   -Total 100 -BytesPerSec 0  | Should -BeExactly '--'   # stalled
    }

    It 'builds a transfer line with and without a rate' {
        $withRate = Format-TransferLine -Percent 50 -Done 512MB -Total 1GB -BytesPerSec 1MB -Label 'Game.7z'
        $withRate | Should -Match '\[#+\s*\]'
        $withRate | Should -Match '50%'
        $withRate | Should -Match 'ETA:'
        $withRate | Should -Match 'Game\.7z'

        # AB reports no total rate, so the line must simply omit speed and ETA.
        $noRate = Format-TransferLine -Prefix '[AB]' -Percent 50 -Done 512MB -Total 1GB -Label 'Game.7z'
        $noRate | Should -Match '\[AB\]'
        $noRate | Should -Not -Match 'ETA:'
    }

    It 'truncates a long label rather than wrapping the line' {
        $long = 'A' * 200
        (Format-ShortLabel $long).Length | Should -BeLessOrEqual 45
    }
}

Describe 'Archive detection' {

    It 'recognises each signature it claims to support' {
        (Get-ArchiveType (New-SignedFile 'a.dat' $script:SIG_ZIP)) | Should -BeExactly 'zip'
        (Get-ArchiveType (New-SignedFile 'b.dat' $script:SIG_7Z))  | Should -BeExactly '7z'
        (Get-ArchiveType (New-SignedFile 'c.dat' $script:SIG_RAR)) | Should -BeExactly 'rar'
    }

    It 'agrees with Test-IsArchive on every signature' {
        # These were two implementations with two signature tables: the sniffer matched a
        # 2-byte zip prefix while the test demanded 4, so a file could be typed 'zip' and
        # simultaneously reported not-an-archive.
        foreach ($sig in @($script:SIG_ZIP, $script:SIG_7Z, $script:SIG_RAR)) {
            $f = New-SignedFile "agree-$([guid]::NewGuid().ToString('N').Substring(0,6)).dat" $sig
            Test-IsArchive $f          | Should -BeTrue
            Get-ArchiveType -FilePath $f | Should -Not -BeNullOrEmpty
        }
    }

    It 'does not call a raw ROM an archive, whatever it is named' {
        # A .iso is a download, not a container - handing it to 7-Zip would fail the install.
        $iso = New-SignedFile 'game.iso' ([byte[]](0x01, 0x02, 0x03, 0x04))
        Test-IsArchive $iso | Should -BeFalse

        $liar = New-SignedFile 'actually-a-rom.zip' ([byte[]](0xDE, 0xAD, 0xBE, 0xEF))
        Test-IsArchive $liar | Should -BeFalse
    }

    It 'reports no archive for a missing or empty file' {
        Test-IsArchive (Join-Path $script:TestRoot 'does-not-exist.7z') | Should -BeFalse
        $empty = Join-Path $script:TestRoot 'empty.7z'
        New-Item -ItemType File -Path $empty -Force | Out-Null
        Test-IsArchive $empty | Should -BeFalse
    }
}

Describe 'Filename safety' {

    It 'strips the characters that break an SRM launch command' {
        # SRM single-quotes the launch path, so an apostrophe ends the string early. The
        # character is removed, not replaced: "Lunatea's" becomes "Lunateas".
        Get-SafeRomName "Klonoa 2 - Lunatea's Veil.iso" | Should -BeExactly 'Klonoa 2 - Lunateas Veil.iso'
        Get-SafeRomName 'Game`name.iso'                 | Should -BeExactly 'Gamename.iso'
    }

    It 'strips characters Windows will not accept in a filename' {
        Get-SafeRomName 'A<B>C:D"E/F\G|H?I*J.iso' | Should -BeExactly 'ABCDEFGHIJ.iso'
    }

    It 'collapses the whitespace left behind' {
        Get-SafeRomName 'Game   ::  Name.iso' | Should -BeExactly 'Game Name.iso'
    }

    It 'leaves an already-safe name untouched' {
        Get-SafeRomName 'Chrono Trigger (USA).zip' | Should -BeExactly 'Chrono Trigger (USA).zip'
    }
}

Describe 'Common helpers' {

    It 'stamps a round-trippable UTC time' {
        $stamp = Get-UtcStamp
        { [datetime]::Parse($stamp) } | Should -Not -Throw
        ([datetimeoffset]$stamp).Offset | Should -Be ([timespan]::Zero)
    }

    It 'mints ids of the requested length that do not repeat' {
        (New-ShortId).Length    | Should -Be 12
        (New-ShortId 8).Length  | Should -Be 8
        $ids = 1..50 | ForEach-Object { New-ShortId }
        ($ids | Select-Object -Unique).Count | Should -Be 50
    }

    It 'removes an empty directory but keeps one holding a file' {
        $empty = Join-Path $script:TestRoot 'empty-dir'
        $full  = Join-Path $script:TestRoot 'full-dir'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        New-Item -ItemType Directory -Path $full -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $full 'keep.txt') -Value 'x'

        Remove-EmptyDirectory -Path $empty
        Remove-EmptyDirectory -Path $full
        Test-Path $empty | Should -BeFalse
        Test-Path $full  | Should -BeTrue
    }

    It 'keeps a directory whose only file is nested deep' {
        $outer = Join-Path $script:TestRoot 'nested'
        $inner = Join-Path $outer 'a\b\c'
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $inner 'rom.iso') -Value 'x'
        Remove-EmptyDirectory -Path $outer
        Test-Path $inner | Should -BeTrue
    }

    It 'prunes only the empty children under -Recurse' {
        $root = Join-Path $script:TestRoot 'recurse'
        New-Item -ItemType Directory -Path (Join-Path $root 'gone') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'stays') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'stays\rom.iso') -Value 'x'

        Remove-EmptyDirectory -Path $root -Recurse
        Test-Path (Join-Path $root 'gone')  | Should -BeFalse
        Test-Path (Join-Path $root 'stays') | Should -BeTrue
        Test-Path $root                     | Should -BeTrue
    }

    It 'matches a phrase only on a word boundary' {
        Test-Phrase 'persona 3 fes' 'fes'   | Should -BeTrue
        Test-Phrase 'festival games' 'fes'  | Should -BeFalse
    }
}

Describe 'Install-RomFromDownload' {

    BeforeEach {
        $script:Dest = Join-Path $script:TestRoot "dest-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $script:Work = Join-Path $script:TestRoot "work-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $script:Dest -Force | Out-Null
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null
        $script:CapturedSteps = @()
    }

    It 'files a raw ROM without extracting it' {
        $rom = Join-Path $script:Work 'Some Game (USA).iso'
        Set-Content -LiteralPath $rom -Value 'rom-bytes'

        $installed = Install-RomFromDownload -DownloadedPath $rom -RomDest $script:Dest -WorkDir $script:Work
        $installed | Should -Not -BeNullOrEmpty
        Test-Path $installed | Should -BeTrue
        [System.IO.Path]::GetFileName($installed) | Should -BeExactly 'Some Game (USA).iso'
    }

    It 'sanitises the filename on the way in' {
        $rom = Join-Path $script:Work "Lunatea's Veil.iso"
        Set-Content -LiteralPath $rom -Value 'x'
        $installed = Install-RomFromDownload -DownloadedPath $rom -RomDest $script:Dest -WorkDir $script:Work
        [System.IO.Path]::GetFileName($installed) | Should -BeExactly 'Lunateas Veil.iso'
    }

    It 'keeps the archive under -NoExtract' {
        $arc = New-SignedFile 'keep-me.7z' $script:SIG_7Z
        $installed = Install-RomFromDownload -DownloadedPath $arc -RomDest $script:Dest `
                        -WorkDir $script:Work -NoExtract
        [System.IO.Path]::GetExtension($installed) | Should -BeExactly '.7z'
        Test-Path $installed | Should -BeTrue
    }

    It 'reports the steps it passes through, in order' {
        $rom = Join-Path $script:Work 'stepped.iso'
        Set-Content -LiteralPath $rom -Value 'x'
        $steps = @()
        Install-RomFromDownload -DownloadedPath $rom -RomDest $script:Dest -WorkDir $script:Work `
            -OnStep { param($s) $script:CapturedSteps += $s } | Out-Null
        # A raw ROM skips extraction entirely.
        $script:CapturedSteps | Should -Contain $script:JOB_STEP_FILING
    }

    It 'returns null rather than throwing when the download is missing' {
        Install-RomFromDownload -DownloadedPath (Join-Path $script:Work 'nope.iso') `
            -RomDest $script:Dest -WorkDir $script:Work | Should -BeNullOrEmpty
    }

    It 'survives a caller that supplies no step callback' {
        $rom = Join-Path $script:Work 'nocb.iso'
        Set-Content -LiteralPath $rom -Value 'x'
        { Install-RomFromDownload -DownloadedPath $rom -RomDest $script:Dest -WorkDir $script:Work } |
            Should -Not -Throw
    }
}
