# Offline tests for lib/MediaFolders.ps1: show and season parsing, existing-folder reuse and the
# final save path. Only a Pester TestDrive is touched.

BeforeAll {
    $script:Lib = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'lib'
    . (Join-Path $script:Lib 'Platform.ps1')
    . (Join-Path $script:Lib 'MediaFolders.ps1')
}

Describe 'Get-DlShowName and Get-DlSeasonNumber (TV)' {
    It 'parses <name>' -ForEach @(
        @{ name = 'Avatar Seven Havens S01E13 1080p WEB h264-GRACE';                show = 'Avatar Seven Havens'; season = 1 }
        @{ name = 'Avatar.Seven.Havens.S01E13.1080p.WEB.h264-GRACE[EZTVx.to].mkv'; show = 'Avatar Seven Havens'; season = 1 }
        @{ name = 'Breaking Bad S01-S05 720p Bluray x265-BMF';                      show = 'Breaking Bad';        season = $null }
        @{ name = 'The.Office.US.S03.1080p.BluRay.x265';                            show = 'The Office US';       season = 3 }
        @{ name = 'Severance.2022.S02E01.1080p';                                    show = 'Severance (2022)';    season = 2 }
        @{ name = 'Show Name Season 2 Complete 720p';                               show = 'Show Name';           season = 2 }
        @{ name = 'Some Show Seasons 1-3 1080p';                                    show = 'Some Show';           season = $null }
        @{ name = 'Some Show Complete Series 720p';                                 show = 'Some Show';           season = $null }
    ) {
        Get-DlShowName -TorrentName $name | Should -Be $show
        Get-DlSeasonNumber -TorrentName $name | Should -Be $season
    }
    It 'strips invalid file-name characters' {
        Get-DlShowName -TorrentName 'Who: Is? This S01E01' | Should -Be 'Who Is This'
    }
    It 'returns null when nothing sensible remains' {
        Get-DlShowName -TorrentName 'S01E01 1080p' | Should -BeNullOrEmpty
    }
}

Describe 'Get-DlShowName (anime)' {
    It 'drops the group tag and the episode number' {
        Get-DlShowName -Anime -TorrentName '[SubsPlease] Sousou no Frieren - 13 (1080p) [ABCD1234].mkv' |
            Should -Be 'Sousou no Frieren'
    }
    It 'keeps the season marker' {
        Get-DlShowName -Anime -TorrentName '[Judas] Shingeki no Kyojin S2 [1080p][Batch]' |
            Should -Be 'Shingeki no Kyojin S2'
    }
}

Describe 'Resolve-DlShowFolder' {
    BeforeEach {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Abbott Elementary (2021)') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'Bluey (2018)') -Force | Out-Null
    }
    It 'reuses an existing folder that carries a year' {
        Resolve-DlShowFolder -Root $TestDrive -Name 'Abbott Elementary' |
            Should -Be (Join-Path $TestDrive 'Abbott Elementary (2021)')
    }
    It 'matches case-insensitively and ignores punctuation' {
        Resolve-DlShowFolder -Root $TestDrive -Name 'bluey' | Should -Be (Join-Path $TestDrive 'Bluey (2018)')
        Resolve-DlShowFolder -Root $TestDrive -Name 'Abbott Elementary (2021)' |
            Should -Be (Join-Path $TestDrive 'Abbott Elementary (2021)')
    }
    It 'returns a new path under the root without creating it' {
        $p = Resolve-DlShowFolder -Root $TestDrive -Name 'New Show'
        $p | Should -Be (Join-DlPath $TestDrive 'New Show')
        Test-Path -LiteralPath $p | Should -BeFalse
    }
}

Describe 'Get-DlEpisodeSavePath' {
    It 'files a single episode under the season folder' {
        Get-DlEpisodeSavePath -Root $TestDrive -TorrentName 'Avatar Seven Havens S01E13 1080p WEB h264-GRACE' -Fallback 'avatar' |
            Should -Be (Join-DlPath $TestDrive 'Avatar Seven Havens' 'Season 01')
    }
    It 'omits the season folder for a complete series' {
        Get-DlEpisodeSavePath -Root $TestDrive -TorrentName 'Breaking Bad S01-S05 720p Bluray x265-BMF' -Fallback 'Breaking Bad' -CompleteSeries |
            Should -Be (Join-DlPath $TestDrive 'Breaking Bad')
        Get-DlEpisodeSavePath -Root $TestDrive -TorrentName 'Breaking Bad S01-S05 720p Bluray x265-BMF' -Fallback 'Breaking Bad' |
            Should -Be (Join-DlPath $TestDrive 'Breaking Bad')
    }
    It 'never adds a season folder for anime' {
        Get-DlEpisodeSavePath -Root $TestDrive -Anime -TorrentName '[SubsPlease] Sousou no Frieren - 13 (1080p) [ABCD1234].mkv' -Fallback 'Frieren' |
            Should -Be (Join-DlPath $TestDrive 'Sousou no Frieren')
    }
    It 'falls back to the query when the name has no show' {
        Get-DlEpisodeSavePath -Root $TestDrive -TorrentName '1080p' -Fallback 'My: Query' |
            Should -Be (Join-DlPath $TestDrive 'My Query')
    }
}
