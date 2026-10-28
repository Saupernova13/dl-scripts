# Live tests: these hit kisskh.co for real. Nothing is mocked.
#
# They catch the site changing underneath us - a bumped appVer (stale kkey constants), a
# renamed route, a changed response shape. Slow and network-dependent, hence tagged 'Live' and
# skipped by default. Run with .\dltv\tests\Invoke-Tests.ps1 -Live

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Lib  = Join-Path (Split-Path -Parent $script:Root) 'lib'
    . (Join-Path $script:Lib 'Platform.ps1')
    . (Join-Path $script:Root 'KissKH.ps1')
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }
}

Describe 'KissKH API is reachable and our signing is accepted' -Tag Live {
    It 'search finds Bad Buddy (id 4540)' {
        $r = @(Search-KissKHDrama -Query 'Bad Buddy')
        @($r | Where-Object { $_.id -eq 4540 }).Count | Should -Be 1
    }

    It 'search with no hits returns an empty list' {
        @(Search-KissKHDrama -Query 'zzzqqqxxxnotashow').Count | Should -Be 0
    }

    It 'drama 4540 has 12 integer episodes' {
        $d = Get-KissKHDrama -Id 4540
        $d.title | Should -Be 'Bad Buddy'
        @((Select-KissKHEpisodes -Drama $d).Episodes).Count | Should -Be 12
    }

    It 'the stream endpoint accepts our kkey for episode 84998' {
        $url = Get-KissKHStreamUrl -EpisodeId 84998
        $url | Should -Not -BeNullOrEmpty
        $url | Should -Match '^https?://'
    }

    It 'the subtitle endpoint returns at least one track for episode 84998' {
        $tracks = @(Get-KissKHSubtitleTracks -EpisodeId 84998)
        $tracks.Count | Should -BeGreaterThan 0
        @($tracks | Where-Object { $_.land -eq 'en' }).Count | Should -BeGreaterThan 0
    }

    It 'the English subtitle decrypts to readable SRT' {
        $track = @(Get-KissKHSubtitleTracks -EpisodeId 84998) | Where-Object { $_.land -eq 'en' } | Select-Object -First 1
        $raw = Invoke-KissKHGet -Url ([string]$track.src)
        $srt = ConvertFrom-KissKHSubtitle -Text $raw -Extension (Get-KissKHSubtitleExtension ([string]$track.src))
        $srt | Should -Match '\d\d:\d\d:\d\d,\d{3} --> \d\d:\d\d:\d\d,\d{3}'
        $srt | Should -Not -Match '^[A-Za-z0-9+/=\s]{200,}$'
    }
}
