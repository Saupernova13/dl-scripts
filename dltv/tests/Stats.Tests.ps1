# Offline tests for dltv's job statistics: formatting, the speed estimator, ETA, drive lookup
# and the qBittorrent-shaped status record. Only fixtures and a temp dir are touched.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Lib  = Join-Path (Split-Path -Parent $script:Root) 'lib'
    . (Join-Path $script:Lib 'Platform.ps1')
    . (Join-Path $script:Root 'KissKH.ps1')
    . (Join-Path $script:Root 'Stats.ps1')
    . (Join-Path $script:Root 'Jobs.ps1')
    . (Join-Path $script:Root 'Download.ps1')
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

    function Read-JobFixture {
        $raw = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/job-running.json'), [System.Text.Encoding]::UTF8)
        return ($raw | ConvertFrom-Json)
    }
}

Describe 'size, speed and duration formatting' {
    It 'formats sizes' {
        Format-DltvSize 512 | Should -Be '512 B'
        Format-DltvSize (431MB) | Should -Be '431 MB'
        (Format-DltvSize ([long](6.91GB))) | Should -Match '^6[.,]91 GB$'
    }
    It 'formats speeds' {
        (Format-DltvSpeed (8.2MB)) | Should -Match '^8[.,]2 MB/s$'
        (Format-DltvSpeed 512KB) | Should -Match '^512 KB/s$'
        (Format-DltvSpeed 12) | Should -Be '12 B/s'
    }
    It 'formats durations' {
        Format-DltvDuration 45 | Should -Be '45s'
        Format-DltvDuration (14 * 60) | Should -Be '14m'
        Format-DltvDuration (3600 + 5 * 60) | Should -Be '1h 05m'
        Format-DltvDuration -3 | Should -Be '0s'
    }
}

Describe 'speed and ETA' {
    It 'seeds the average with the first sample' {
        Get-DltvEmaSpeed -Previous 0 -Instant 5000000 -Dt 2 | Should -Be 5000000
    }
    It 'moves toward a new sample without jumping to it' {
        $v = Get-DltvEmaSpeed -Previous 1000000 -Instant 3000000 -Dt 2 -Window 10
        $v | Should -BeGreaterThan 1000000
        $v | Should -BeLessThan 3000000
    }
    It 'converges after about one window' {
        $v = 0.0
        for ($i = 0; $i -lt 30; $i++) { $v = Get-DltvEmaSpeed -Previous $v -Instant 4000000 -Dt 2 -Window 10 }
        $v | Should -BeGreaterThan 3900000
    }
    It 'keeps the previous value for a zero interval' {
        Get-DltvEmaSpeed -Previous 123 -Instant 999 -Dt 0 | Should -Be 123
    }
    It 'computes the ETA, and null without speed' {
        Get-DltvEta -RemainingBytes 80000000 -SpeedBps 8000000 | Should -Be 10
        Get-DltvEta -RemainingBytes 1 -SpeedBps 0 | Should -BeNullOrEmpty
        Get-DltvEta -RemainingBytes -5 -SpeedBps 100 | Should -BeNullOrEmpty
    }
}

Describe 'drive info' {
    It 'reports the drive and free space of a real path' {
        $info = Get-DltvDriveInfo -Path ([System.IO.Path]::GetTempPath())
        $info.drive | Should -Not -BeNullOrEmpty
        if ($null -ne $info.freeGB) { $info.freeGB | Should -BeGreaterThan 0 }
    }
    It 'fails soft on an empty path' {
        { Get-DltvDriveInfo -Path '' } | Should -Not -Throw
    }
}

Describe 'status record' {
    It 'has the qBittorrent-style fields for a running job' {
        $o = ConvertTo-DltvStatusObject -Job (Read-JobFixture)
        $names = @($o.PSObject.Properties.Name)
        foreach ($f in 'id status source name country progress doneBytes totalBytes doneGB totalGB sizeExact dlspeed speedMBps eta episodesDone episodesTotal currentEpisode currentEpisodeProgress savePath drive driveName freeGB failed notReleased message createdAt startedAt completedAt lastUpdate'.Split(' ')) {
            $names | Should -Contain $f
        }
        $o.id | Should -Be '0123456789ab'
        $o.source | Should -Be 'kisskh'
        $o.name | Should -Be 'Crazy Love (2022)'
        $o.progress | Should -Be 0.5
        $o.doneGB | Should -Be 1.4
        $o.totalGB | Should -Be 2.79
        $o.sizeExact | Should -BeFalse
        $o.dlspeed | Should -Be 8000000
        $o.speedMBps | Should -Be 7.63
        $o.eta | Should -Be 187
        $o.episodesDone | Should -Be 1
        $o.episodesTotal | Should -Be 4
        $o.currentEpisode | Should -Be 2
        $o.currentEpisodeProgress | Should -Be 0.4
        $o.savePath | Should -Be 'D:\TV\Crazy Love (2022)'
        $o.driveName | Should -Be 'asmedia-4tb-hdd'
        $o.freeGB | Should -Be 1343.9
        @($o.notReleased) | Should -Be @('E04')
    }

    It 'serialises to JSON with 0-1 progress and byte counts' {
        $json = ConvertTo-DltvStatusObject -Job (Read-JobFixture) | ConvertTo-Json -Depth 5
        $back = $json | ConvertFrom-Json
        $back.progress | Should -Be 0.5
        $back.dlspeed | Should -Be 8000000
        $back.totalBytes | Should -Be 3000000000
    }

    It 'zeroes speed, ETA and current episode once the job is finished' {
        $j = Read-JobFixture
        $j.status = 'completed'
        $o = ConvertTo-DltvStatusObject -Job $j -Status 'completed'
        $o.progress | Should -Be 1
        $o.dlspeed | Should -Be 0
        $o.eta | Should -BeNullOrEmpty
        $o.currentEpisode | Should -BeNullOrEmpty
    }

    It 'zeroes speed for an orphaned job' {
        $o = ConvertTo-DltvStatusObject -Job (Read-JobFixture) -Status 'orphaned'
        $o.status | Should -Be 'orphaned'
        $o.dlspeed | Should -Be 0
    }

    It 'falls back to episode progress when no byte total is known, and tolerates old records' {
        $old = [PSCustomObject]@{ id = 'abc'; status = 'running'; title = 'Old'; destination = 'x'; total = 4; done = 1; current = ''; failed = @() }
        $o = ConvertTo-DltvStatusObject -Job $old
        $o.progress | Should -Be 0.25
        $o.totalBytes | Should -Be 0
        $o.currentEpisode | Should -BeNullOrEmpty
    }
}

Describe 'job views' {
    BeforeAll {
        $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dltv-stats-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
        $script:SavedXdg   = $env:XDG_DATA_HOME
        $script:SavedLocal = $env:LOCALAPPDATA
        if (Test-DlWindows) { $env:LOCALAPPDATA = $script:TestRoot } else { $env:XDG_DATA_HOME = $script:TestRoot }
    }
    AfterAll {
        $env:LOCALAPPDATA = $script:SavedLocal
        $env:XDG_DATA_HOME = $script:SavedXdg
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '--status --json prints only parseable JSON' {
        $j = New-DltvJob -Title 'Bad Buddy' -DramaId 4540 -BaseUrl 'https://kisskh.co' -Destination (Join-Path $script:TestRoot 'out') `
                -Episodes @([PSCustomObject]@{ Id = 1; Number = 1 }) -SubLangs @('en')
        Save-DltvJob -Job $j -Strict
        $text = (Show-DltvJobStatus -JobId $j.id -Json | Where-Object { $_ -isnot [bool] }) -join "`n"
        $o = $text | ConvertFrom-Json
        $o.id | Should -Be $j.id
        $o.name | Should -Be 'Bad Buddy'
        $o.source | Should -Be 'kisskh'
    }

    It '--status --json for an unknown job is a JSON error' {
        $text = (Show-DltvJobStatus -JobId 'nope' -Json | Where-Object { $_ -isnot [bool] }) -join "`n"
        ($text | ConvertFrom-Json).error | Should -Match 'Unknown job'
    }

    It '--jobs --json is always an array' {
        $text = (Show-DltvJobList -Json) -join "`n"
        $arr = $text | ConvertFrom-Json
        @($arr).Count | Should -BeGreaterThan 0
        $text.TrimStart().StartsWith('[') | Should -BeTrue
    }
}
