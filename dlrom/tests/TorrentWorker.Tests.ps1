# Offline tests for the Telegram job worker: waiting for a whole torrent (QbitTorrent.ps1), the
# per-console install strategies (TorrentInstall.ps1), the worker and --resume (TelegramJob.ps1).
#
# Strategies run against real temp directories; qBittorrent, Steam and 7-Zip are mocked. Nothing
# touches the network, a real qBittorrent or the real jobs folder.

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot

    . (Join-Path $ModuleRoot 'Constants.ps1')
    . (Join-Path $ModuleRoot 'Common.ps1')
    . (Join-Path $ModuleRoot 'Logging.ps1')
    . (Join-Path $ModuleRoot 'Jobs.ps1')
    . (Join-Path $ModuleRoot 'Clean.ps1')
    . (Join-Path $ModuleRoot 'RomFiles.ps1')
    . (Join-Path $ModuleRoot 'QbitTorrent.ps1')
    . (Join-Path $ModuleRoot 'TorrentInstall.ps1')
    . (Join-Path $ModuleRoot 'TelegramJob.ps1')

    $script:DeadPid     = 2000000000   # no such process
    $script:LOG_QUIET   = $true
    $script:LOG_VERBOSE = $false
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

    $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) "dlrom-worker-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:Scratch -Force | Out-Null
    $script:JobsDir = Join-Path $script:Scratch 'jobs'
    function Get-DlromJobsDir { New-Item -ItemType Directory -Path $script:JobsDir -Force | Out-Null; return $script:JobsDir }
    function Get-DlScriptsDataDir { param([string]$SubPath = '') return $script:Scratch }

    # Stand-ins for what other modules own, so the worker's calls can be mocked.
    function Initialize-DlromQbit { return $true }
    function Sync-RomToSteam { param([string]$RomDest, [string]$RomsBase, [int]$InstalledCount, [switch]$AlreadyDeferred) }

    function New-TFile {
        param([string]$Path, [int]$Size = 10, [byte[]]$Bytes = $null)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (-not $Bytes) { $Bytes = [byte[]](1..$Size | ForEach-Object { 65 }) }
        [System.IO.File]::WriteAllBytes($Path, $Bytes)
        return $Path
    }
    # A file with a zip signature: Test-IsArchive reads the header, never the extension.
    function New-TZip { param([string]$Path) return (New-TFile -Path $Path -Bytes ([byte[]](0x50, 0x4B, 3, 4, 0, 0, 0, 0))) }
    function New-TCase {
        $root = Join-Path $script:Scratch ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $c = @{ Root = $root; Src = (Join-Path $root 'src'); Roms = (Join-Path $root 'roms'); Work = (Join-Path $root 'work') }
        New-Item -ItemType Directory -Path $c.Src, $c.Roms -Force | Out-Null
        return $c
    }
    function Install-T {
        param($Case, [string]$Content, [string]$Folder, [string]$Title = 'Game Title', [string]$Mode = 'move')
        return (Invoke-TorrentInstall -ContentPath $Content -RomDest (Join-Path $Case.Roms $Folder) -Title $Title `
                -Folder $Folder -Mode $Mode -WorkDir $Case.Work)
    }
}

AfterAll {
    if ($script:Scratch -and (Test-Path $script:Scratch)) {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Rule table -------------------------------------------------------------------------------

Describe 'Torrent install rules' {

    It 'names only strategies that exist' {
        foreach ($k in $script:TORRENT_INSTALL_RULES.Keys) {
            $r = $script:TORRENT_INSTALL_RULES[$k]
            $script:TORRENT_INSTALL_STRATEGIES.ContainsKey($r.Strategy) | Should -BeTrue -Because $k
            if ($r.Then) { $script:TORRENT_INSTALL_STRATEGIES.ContainsKey($r.Then) | Should -BeTrue -Because "$k Then" }
        }
        foreach ($name in $script:TORRENT_INSTALL_STRATEGIES.Values) {
            Get-Command -Name $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'covers every Telegram-only console and falls back to generic for the rest' {
        foreach ($f in 'switch', 'n3ds', 'ps3', 'xbox360', 'xbox', 'wiiu', 'psvita', 'ps4', 'ps5') {
            $script:TORRENT_INSTALL_RULES.ContainsKey($f) | Should -BeTrue -Because $f
        }
        foreach ($f in 'nds', 'psx', 'ps2', 'psp', 'gc', 'wii', 'dreamcast', 'unknown') {
            (Get-TorrentInstallRule $f).Strategy | Should -Be 'generic' -Because $f
        }
    }

    It 'marks the manual consoles as not Steam-syncable' {
        foreach ($f in 'psvita', 'ps4', 'ps5') {
            $script:TORRENT_INSTALL_RULES[$f].SteamSync | Should -BeFalse
            $script:TORRENT_INSTALL_RULES[$f].Note | Should -Not -BeNullOrEmpty
        }
    }
}

# --- Wait-QbitTorrent -------------------------------------------------------------------------

Describe 'Get-QbitTorrentInfo' {
    It 'returns the first object of a JSON array (the 5.1 single-object quirk included)' {
        Mock Invoke-QbitApi { return [PSCustomObject]@{ Content = '[{"hash":"h1","state":"uploading"}]' } }
        (Get-QbitTorrentInfo -Hash 'h1').state | Should -Be 'uploading'
    }
    It 'returns $null for an empty list' {
        Mock Invoke-QbitApi { return [PSCustomObject]@{ Content = '[]' } }
        Get-QbitTorrentInfo -Hash 'h1' | Should -BeNullOrEmpty
    }
}

Describe 'Wait-QbitTorrent' {

    BeforeAll {
        function New-QInfo {
            param([string]$State = 'downloading', [double]$Progress = 0.5, [double]$Downloaded = 500)
            return [PSCustomObject]@{ hash = 'h'; state = $State; progress = $Progress; downloaded = $Downloaded; completed = $Downloaded
                                      size = 1000; dlspeed = 100; name = 'Game'; content_path = 'C:/stage/Game'; save_path = 'C:/stage' }
        }
    }
    BeforeEach {
        $script:Seq = New-Object System.Collections.Queue
        $script:Last = $null
        Mock Get-QbitTorrentInfo {
            if ($script:Seq.Count -gt 0) { $script:Last = $script:Seq.Dequeue() }
            return $script:Last
        }
        Mock Start-QbitTorrent { }
        Mock Write-ProgressLine { }
        Mock Stop-ProgressLine { }
    }

    It 'returns the info once progress is 1 and the state is a completed one' {
        $script:Seq.Enqueue((New-QInfo 'downloading' 0.5))
        $script:Seq.Enqueue((New-QInfo 'stalledUP' 1.0 1000))
        $info = Wait-QbitTorrent -Hash 'h' -PollSec 0.01
        $info.content_path | Should -Be 'C:/stage/Game'
        $info.save_path    | Should -Be 'C:/stage'
        $info.name         | Should -Be 'Game'
    }

    It 'accepts every completed state' {
        foreach ($s in 'uploading', 'stalledUP', 'queuedUP', 'forcedUP', 'pausedUP', 'stoppedUP', 'checkingUP') {
            $script:Seq.Clear(); $script:Last = $null
            $script:Seq.Enqueue((New-QInfo $s 1.0 1000))
            (Wait-QbitTorrent -Hash 'h' -PollSec 0.01).state | Should -Be $s
        }
    }

    It 'keeps waiting while progress is 1 but the state is still a download state' {
        $script:Seq.Enqueue((New-QInfo 'checkingDL' 1.0 1000))
        $script:Seq.Enqueue((New-QInfo 'uploading' 1.0 1000))
        (Wait-QbitTorrent -Hash 'h' -PollSec 0.01).state | Should -Be 'uploading'
    }

    It 'throws, naming the state, on error and missingFiles' {
        $script:Seq.Enqueue((New-QInfo 'error' 0.2))
        { Wait-QbitTorrent -Hash 'h' -PollSec 0.01 } | Should -Throw "*state 'error'*"
        $script:Seq.Clear(); $script:Last = $null
        $script:Seq.Enqueue((New-QInfo 'missingFiles' 0.2))
        { Wait-QbitTorrent -Hash 'h' -PollSec 0.01 } | Should -Throw "*state 'missingFiles'*"
    }

    It 'throws a clear error when the torrent disappears from qBittorrent' {
        $script:Seq.Enqueue((New-QInfo 'downloading' 0.2))
        $script:Seq.Enqueue($null)
        Mock Get-QbitTorrentInfo { if ($script:Seq.Count -gt 0) { return $script:Seq.Dequeue() } return $null }
        { Wait-QbitTorrent -Hash 'h' -PollSec 0.01 } | Should -Throw '*no longer in qBittorrent*'
    }

    It 'fails as stalled when the byte count stops growing (and leaves the torrent alone)' {
        Mock Get-QbitTorrentInfo { return (New-QInfo 'downloading' 0.3 300) }
        Mock Remove-QbitTorrent { }
        { Wait-QbitTorrent -Hash 'h' -PollSec 0.05 -StallTimeoutSec 0.3 } | Should -Throw 'stalled: no progress for*'
        Should -Invoke Remove-QbitTorrent -Times 0
    }

    It 'does not count time spent queued or checking towards the stall timeout' {
        $script:Calls = 0
        Mock Get-QbitTorrentInfo {
            $script:Calls++
            if ($script:Calls -ge 12) { return (New-QInfo 'uploading' 1.0 1000) }
            return (New-QInfo 'queuedDL' 0.3 300)
        }
        (Wait-QbitTorrent -Hash 'h' -PollSec 0.05 -StallTimeoutSec 0.3).state | Should -Be 'uploading'
    }

    It 'says a paused torrent it does not own is paused when it stalls' {
        Mock Get-QbitTorrentInfo { return (New-QInfo 'pausedDL' 0.3 300) }
        { Wait-QbitTorrent -Hash 'h' -PollSec 0.05 -StallTimeoutSec 0.3 } | Should -Throw 'stalled: the torrent is paused in qBittorrent*'
        Should -Invoke Start-QbitTorrent -Times 0
    }

    It 'does not call a slowly growing download stalled' {
        $script:Calls = 0
        Mock Get-QbitTorrentInfo {
            $script:Calls++
            if ($script:Calls -ge 10) { return (New-QInfo 'uploading' 1.0 1000) }
            return (New-QInfo 'downloading' 0.3 (300 + $script:Calls))
        }
        (Wait-QbitTorrent -Hash 'h' -PollSec 0.05 -StallTimeoutSec 0.3).state | Should -Be 'uploading'
    }

    It 'gives up at the overall timeout even while bytes keep coming' {
        $script:Calls = 0
        Mock Get-QbitTorrentInfo { $script:Calls++; return (New-QInfo 'downloading' 0.3 (300 + $script:Calls)) }
        { Wait-QbitTorrent -Hash 'h' -PollSec 0.05 -TimeoutSec 1 } | Should -Throw 'Timed out after 1s*'
    }

    It 'says so when qBittorrent cannot be reached' {
        Mock Get-QbitTorrentInfo { throw 'connection refused' }
        { Wait-QbitTorrent -Hash 'h' -PollSec 0.05 -StallTimeoutSec 0.3 } | Should -Throw '*qBittorrent is not reachable*'
    }

    It 'starts a stopped torrent once when the job owns it' {
        $script:Seq.Enqueue((New-QInfo 'stoppedDL' 0.2 200))
        $script:Seq.Enqueue((New-QInfo 'stoppedDL' 0.2 200))
        $script:Seq.Enqueue((New-QInfo 'uploading' 1.0 1000))
        $null = Wait-QbitTorrent -Hash 'h' -PollSec 0.01 -OwnsTorrent
        Should -Invoke Start-QbitTorrent -Times 1 -ParameterFilter { $Hash -eq 'h' }
    }

    It 'does not start a paused torrent it does not own' {
        $script:Seq.Enqueue((New-QInfo 'pausedDL' 0.2 200))
        $script:Seq.Enqueue((New-QInfo 'uploading' 1.0 1000))
        $null = Wait-QbitTorrent -Hash 'h' -PollSec 0.01
        Should -Invoke Start-QbitTorrent -Times 0
    }

    It 'reports progress with speed and ETA through Write-ProgressLine' {
        $script:Seq.Enqueue((New-QInfo 'downloading' 0.5 500))
        $script:Seq.Enqueue((New-QInfo 'uploading' 1.0 1000))
        $null = Wait-QbitTorrent -Hash 'h' -PollSec 0.01
        Should -Invoke Write-ProgressLine -ParameterFilter { $Percent -eq 50 -and $Line -match 'ETA' -and $Line -match '/s' }
    }
}

# --- Strategies -------------------------------------------------------------------------------

Describe 'Install strategies' {

    BeforeEach { $script:C = New-TCase }

    Context 'switch' {
        It 'moves a folder whole to switch\<Title>, updates and DLC together' {
            $content = Join-Path $script:C.Src 'Zelda.Folder'
            $null = New-TFile (Join-Path $content 'base.nsp'); $null = New-TFile (Join-Path $content 'update.nsp')
            $null = New-TFile (Join-Path $content 'DLC\dlc1.nsp')
            $r = Install-T $script:C $content 'switch' "Zelda: Tears"
            $dest = Join-Path (Join-Path $script:C.Roms 'switch') 'Zelda Tears'
            $r.Installed | Should -Be @($dest)
            $r.SteamSync | Should -BeTrue
            $r.ManualNote | Should -BeNullOrEmpty
            (Join-Path $dest 'DLC\dlc1.nsp') | Should -Exist
            $content | Should -Not -Exist
        }
        It 'files a lone .nsp flat into switch\' {
            $f = New-TFile (Join-Path $script:C.Src 'game.nsp')
            $r = Install-T $script:C $f 'switch'
            $r.Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'switch') 'game.nsp'))
            $f | Should -Not -Exist
        }
        It 'refuses a folder with no switch files and leaves it where it is' {
            $content = Join-Path $script:C.Src 'Odd'
            $null = New-TFile (Join-Path $content 'readme.txt')
            $r = Install-T $script:C $content 'switch'
            @($r.Installed).Count | Should -Be 0
            $r.Reason | Should -Match '\.nsp'
            (Join-Path $content 'readme.txt') | Should -Exist
        }
    }

    Context 'n3ds' {
        It 'files game files flat into n3ds\ from any depth' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'A.3ds'); $null = New-TFile (Join-Path $content 'sub\B.3dsx')
            $null = New-TFile (Join-Path $content 'readme.txt')
            $r = Install-T $script:C $content 'n3ds'
            $dir = Join-Path $script:C.Roms 'n3ds'
            @($r.Installed).Count | Should -Be 2
            (Join-Path $dir 'A.3ds') | Should -Exist
            (Join-Path $dir 'B.3dsx') | Should -Exist
            $r.ManualNote | Should -BeNullOrEmpty
        }
        It 'extracts an archive when it holds the game (move mode consumes the archive)' {
            Mock Expand-RomArchive {
                New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $OutDir 'Inner.3ds') -Value 'x'
            }
            $content = Join-Path $script:C.Src 'Pack'
            $zip = New-TZip (Join-Path $content 'Game.zip')
            $r = Install-T $script:C $content 'n3ds'
            $r.Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'n3ds') 'Inner.3ds'))
            $zip | Should -Not -Exist
            Should -Invoke Expand-RomArchive -Times 1
        }
        It 'keeps the archive when copying' {
            Mock Expand-RomArchive {
                New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $OutDir 'Inner.3ds') -Value 'x'
            }
            $zip = New-TZip (Join-Path $script:C.Src 'Pack\Game.zip')
            $r = Install-T $script:C (Join-Path $script:C.Src 'Pack') 'n3ds' -Mode copy
            (Join-Path (Join-Path $script:C.Roms 'n3ds') 'Inner.3ds') | Should -Exist
            $zip | Should -Exist
        }
        It 'files a .cia-only torrent and says to install it in Azahar' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'Game.cia')
            $r = Install-T $script:C $content 'n3ds'
            @($r.Installed).Count | Should -Be 1
            $r.ManualNote | Should -Match 'Azahar'
            $r.SteamSync | Should -BeTrue
        }
        It 'gives no note when a .cia comes with a playable file' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'Game.cia'); $null = New-TFile (Join-Path $content 'Game.3ds')
            (Install-T $script:C $content 'n3ds').ManualNote | Should -BeNullOrEmpty
        }
    }

    Context 'ps3' {
        It 'moves the directory holding PS3_GAME to ps3\<Title>.ps3' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'KH\PS3_GAME\USRDIR\EBOOT.BIN')
            $null = New-TFile (Join-Path $content 'KH\PS3_DISC.SFB')
            $null = New-TFile (Join-Path $content 'notes.txt')
            $r = Install-T $script:C $content 'ps3' 'Kingdom Hearts HD II.5 Remix (BLES02070 - Eng)'
            $dest = Join-Path (Join-Path $script:C.Roms 'ps3') 'Kingdom Hearts HD II.5 Remix (BLES02070 - Eng).ps3'
            $r.Installed | Should -Be @($dest)
            (Join-Path $dest 'PS3_GAME\USRDIR\EBOOT.BIN') | Should -Exist
            $r.SteamSync | Should -BeTrue
            (Join-Path $content 'notes.txt') | Should -Exist
        }
        It 'uses the content folder itself when it is the game dir' {
            $content = Join-Path $script:C.Src 'Game'
            $null = New-TFile (Join-Path $content 'PS3_GAME\USRDIR\EBOOT.BIN')
            $r = Install-T $script:C $content 'ps3' 'Game'
            (Join-Path (Join-Path (Join-Path $script:C.Roms 'ps3') 'Game.ps3') 'PS3_GAME\USRDIR\EBOOT.BIN') | Should -Exist
        }
        It 'falls back to manual for a .pkg: kept under ps3\<Title>\, no Steam sync, with a note' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'Game.pkg')
            $r = Install-T $script:C $content 'ps3' 'Game'
            $r.Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'ps3') 'Game'))
            $r.SteamSync | Should -BeFalse
            $r.ManualNote | Should -Match 'RPCS3'
            (Join-Path $r.Installed[0] 'Game.pkg') | Should -Exist
        }
        It 'fails when there is neither a game dir nor a .pkg/.iso' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'readme.txt')
            $r = Install-T $script:C $content 'ps3'
            @($r.Installed).Count | Should -Be 0
            $r.Reason | Should -Match 'PS3_GAME'
            (Join-Path $content 'readme.txt') | Should -Exist
        }
    }

    Context 'xbox360 and xbox' {
        It 'files an .iso flat into xbox360\' {
            $f = New-TFile (Join-Path $script:C.Src 'Pack\Halo.iso')
            $r = Install-T $script:C (Join-Path $script:C.Src 'Pack') 'xbox360'
            $r.Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'xbox360') 'Halo.iso'))
        }
        It 'moves a GOD/XBLA folder to xbox360\xbla\<Title>' {
            $content = Join-Path $script:C.Src 'Arcade'
            $null = New-TFile (Join-Path $content '00007000\ABCDEF')
            $r = Install-T $script:C $content 'xbox360' 'Arcade Game'
            $dest = Join-Path (Join-Path (Join-Path $script:C.Roms 'xbox360') 'xbla') 'Arcade Game'
            $r.Installed | Should -Be @($dest)
            (Join-Path $dest '00007000\ABCDEF') | Should -Exist
            $r.SteamSync | Should -BeTrue
        }
        It 'files an .iso flat into xbox\' {
            $f = New-TFile (Join-Path $script:C.Src 'Halo.iso')
            (Install-T $script:C $f 'xbox').Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'xbox') 'Halo.iso'))
        }
        It 'fails on an xbox torrent with no .iso' {
            $null = New-TFile (Join-Path $script:C.Src 'Pack\readme.txt')
            @((Install-T $script:C (Join-Path $script:C.Src 'Pack') 'xbox').Installed).Count | Should -Be 0
        }
    }

    Context 'wiiu' {
        It 'files a .wua flat into wiiu\' {
            $null = New-TFile (Join-Path $script:C.Src 'Pack\Mario.wua')
            $r = Install-T $script:C (Join-Path $script:C.Src 'Pack') 'wiiu'
            $r.Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'wiiu') 'Mario.wua'))
        }
        It 'moves the parent of code\*.rpx to wiiu\<Title>' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'Game\code\app.rpx')
            $null = New-TFile (Join-Path $content 'Game\content\a.bin'); $null = New-TFile (Join-Path $content 'Game\meta\meta.xml')
            $r = Install-T $script:C $content 'wiiu' 'Mario Kart 8'
            $dest = Join-Path (Join-Path $script:C.Roms 'wiiu') 'Mario Kart 8'
            $r.Installed | Should -Be @($dest)
            (Join-Path $dest 'code\app.rpx') | Should -Exist
            (Join-Path $dest 'content\a.bin') | Should -Exist
        }
        It 'fails with neither' {
            $null = New-TFile (Join-Path $script:C.Src 'Pack\readme.txt')
            @((Install-T $script:C (Join-Path $script:C.Src 'Pack') 'wiiu').Installed).Count | Should -Be 0
        }
    }

    Context 'manual consoles' {
        It 'keeps a <f> folder under <f>\<Title>\ with its note and no Steam sync' -ForEach @(
            @{ f = 'psvita'; note = 'Vita3K' }, @{ f = 'ps4'; note = 'shadPS4' }, @{ f = 'ps5'; note = 'reference' }
        ) {
            $content = Join-Path $script:C.Src 'Dump'
            $null = New-TFile (Join-Path $content 'app\PCSE00001\eboot.bin')
            $r = Install-T $script:C $content $f 'Some Game'
            $dest = Join-Path (Join-Path $script:C.Roms $f) 'Some Game'
            $r.Installed | Should -Be @($dest)
            $r.SteamSync | Should -BeFalse
            $r.ManualNote | Should -Match $note
            (Join-Path $dest 'app\PCSE00001\eboot.bin') | Should -Exist
        }
        It 'files a lone file flat' {
            $f = New-TFile (Join-Path $script:C.Src 'game.pkg')
            (Install-T $script:C $f 'ps4').Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'ps4') 'game.pkg'))
        }
    }

    Context 'generic' {
        It 'unpacks a single archive file through the web pipeline filing' {
            Mock Expand-RomArchive {
                New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $OutDir 'Game.nds') -Value 'rom'
            }
            $zip = New-TZip (Join-Path $script:C.Src 'Game.zip')
            $r = Install-T $script:C $zip 'nds'
            $r.Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'nds') 'Game.nds'))
            $r.SteamSync | Should -BeTrue
            $zip | Should -Not -Exist
        }
        It 'files a raw ROM file' {
            $f = New-TFile (Join-Path $script:C.Src 'Game.nds')
            (Install-T $script:C $f 'nds').Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'nds') 'Game.nds'))
        }
        It 'uses the one archive in a folder' {
            Mock Expand-RomArchive {
                New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $OutDir 'Game.gba') -Value 'rom'
            }
            $null = New-TZip (Join-Path $script:C.Src 'Pack\Game.zip'); $null = New-TFile (Join-Path $script:C.Src 'Pack\readme.txt')
            $r = Install-T $script:C (Join-Path $script:C.Src 'Pack') 'gba'
            $r.Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'gba') 'Game.gba'))
        }
        It 'files a .cue with its .bin together' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'Game.cue') -Size 5; $null = New-TFile (Join-Path $content 'Game.bin') -Size 500
            $null = New-TFile (Join-Path $content 'readme.txt')
            $r = Install-T $script:C $content 'psx'
            $dir = Join-Path $script:C.Roms 'psx'
            (Join-Path $dir 'Game.cue') | Should -Exist
            (Join-Path $dir 'Game.bin') | Should -Exist
            (Join-Path $dir 'readme.txt') | Should -Not -Exist
        }
        It 'picks the largest ROM file otherwise' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'small.nds') -Size 10; $null = New-TFile (Join-Path $content 'big.nds') -Size 100
            $r = Install-T $script:C $content 'nds'
            $r.Installed | Should -Be @((Join-Path (Join-Path $script:C.Roms 'nds') 'big.nds'))
            (Join-Path $content 'small.nds') | Should -Exist
        }
        It 'fails when nothing in the folder is a ROM and leaves the data in place' {
            $null = New-TFile (Join-Path $script:C.Src 'Pack\readme.txt')
            $r = Install-T $script:C (Join-Path $script:C.Src 'Pack') 'nds'
            @($r.Installed).Count | Should -Be 0
            $r.Reason | Should -Match 'No ROM'
            (Join-Path $script:C.Src 'Pack\readme.txt') | Should -Exist
        }
    }

    Context 'destinations and modes' {
        It 'never overwrites a folder: a taken name gets " (2)", then " (3)"' {
            $dir = Join-Path $script:C.Roms 'switch'
            $null = New-TFile (Join-Path $dir 'Game Title\old.nsp')
            $null = New-TFile (Join-Path $script:C.Src 'a\x.nsp')
            $r = Install-T $script:C (Join-Path $script:C.Src 'a') 'switch'
            $r.Installed | Should -Be @((Join-Path $dir 'Game Title (2)'))
            $null = New-TFile (Join-Path $script:C.Src 'b\x.nsp')
            (Install-T $script:C (Join-Path $script:C.Src 'b') 'switch').Installed | Should -Be @((Join-Path $dir 'Game Title (3)'))
            (Join-Path $dir 'Game Title\old.nsp') | Should -Exist
        }
        It 'never overwrites a flat file' {
            $dir = Join-Path $script:C.Roms 'xbox'
            $old = New-TFile (Join-Path $dir 'Halo.iso') -Size 3
            $f = New-TFile (Join-Path $script:C.Src 'Halo.iso') -Size 9
            $r = Install-T $script:C $f 'xbox'
            $r.Installed | Should -Be @((Join-Path $dir 'Halo (2).iso'))
            (Get-Item $old).Length | Should -Be 3
        }
        It 'puts a numbered suffix before the .ps3 extension' {
            $dir = Join-Path $script:C.Roms 'ps3'
            $null = New-TFile (Join-Path $dir 'G.ps3\PS3_GAME\x')
            $null = New-TFile (Join-Path $script:C.Src 'Pack\PS3_GAME\USRDIR\EBOOT.BIN')
            (Install-T $script:C (Join-Path $script:C.Src 'Pack') 'ps3' 'G').Installed | Should -Be @((Join-Path $dir 'G (2).ps3'))
        }
        It 'copy mode leaves the source intact' {
            $content = Join-Path $script:C.Src 'Pack'
            $null = New-TFile (Join-Path $content 'base.nsp')
            $r = Install-T $script:C $content 'switch' 'Game' -Mode copy
            (Join-Path $r.Installed[0] 'base.nsp') | Should -Exist
            (Join-Path $content 'base.nsp') | Should -Exist
        }
        It 'copy mode leaves a flat source file and a generic source intact' {
            $f = New-TFile (Join-Path $script:C.Src 'a.nsp')
            $null = Install-T $script:C $f 'switch' -Mode copy
            $f | Should -Exist
            $g = New-TFile (Join-Path $script:C.Src 'Game.nds')
            $r = Install-T $script:C $g 'nds' -Mode copy
            $g | Should -Exist
            $r.Installed[0] | Should -Exist
            $c = Join-Path $script:C.Src 'Disc'
            $null = New-TFile (Join-Path $c 'D.cue') -Size 5; $null = New-TFile (Join-Path $c 'D.bin') -Size 50
            $null = Install-T $script:C $c 'psx' -Mode copy
            (Join-Path $c 'D.cue') | Should -Exist
            (Join-Path $c 'D.bin') | Should -Exist
            (Join-Path (Join-Path $script:C.Roms 'psx') 'D.bin') | Should -Exist
        }
        It 'reports missing content instead of throwing' {
            $r = Install-T $script:C (Join-Path $script:C.Src 'gone') 'switch'
            @($r.Installed).Count | Should -Be 0
            $r.Reason | Should -Match 'not found'
        }
    }
}

# --- Worker -----------------------------------------------------------------------------------

Describe 'Invoke-TelegramJob' {

    BeforeEach {
        Set-DlromConfig ([PSCustomObject]@{ steamSync = $true })
        Remove-Item -Path (Join-Path $script:JobsDir '*') -Force -ErrorAction SilentlyContinue
        $script:C = New-TCase
        $script:Order = @()
        Mock Initialize-DlromQbit { return $true }
        Mock Remove-QbitTorrent { $script:Order += 'remove'; $script:ContentAtRemove = (Test-Path -LiteralPath $script:Content) }
        Mock Sync-RomToSteam { }
        Mock Wait-QbitTorrent {
            $script:AtWait = Read-DlromJob $script:Job.id
            return [PSCustomObject]@{ state = 'uploading'; progress = 1.0; content_path = $script:Content; save_path = $script:Save; name = 'Game' }
        }
    }
    AfterEach { Set-DlromConfig $null }

    BeforeAll {
        # A job with its torrent already finished in staging.
        function New-WJob {
            param($Case, [string]$Folder, [string]$Title = 'Game Title', [bool]$AlreadyPresent = $false, [bool]$NoSteam = $false,
                  [string[]]$Files = @('Game.nsp'))
            $stage = Join-Path (Join-Path $Case.Roms '.dlrom-torrent') $Folder
            $script:Save = $stage
            $script:Content = Join-Path $stage 'Game Name'
            foreach ($f in $Files) { $null = New-TFile (Join-Path $script:Content $f) }
            $job = New-DlromJob -Kind 'telegram' -Query 'q' -Title $Title -Platform $Folder -RomsBase $Case.Roms `
                    -RomDest (Join-Path $Case.Roms $Folder) -NoSteam $NoSteam `
                    -Torrent @{ hash = 'abc'; bot = 'b'; platformFolder = $Folder; savePath = $stage; alreadyPresent = $AlreadyPresent }
            $job.step = 'downloading'; $job.progress = 5
            Save-DlromJob -Job $job -Strict
            $script:Job = $job
            return $job
        }
    }

    It 'owned torrent: releases it from qBittorrent while the data is still in staging, then moves it' {
        $job = New-WJob $script:C 'switch'
        $ok = [bool](@(Invoke-TelegramJob -Job $job -Cfg $null) | Select-Object -Last 1)
        $ok | Should -BeTrue
        Should -Invoke Remove-QbitTorrent -Times 1 -ParameterFilter { $Hash -eq 'abc' }
        $script:ContentAtRemove | Should -BeTrue
        $script:Content | Should -Not -Exist
        $dest = Join-Path (Join-Path $script:C.Roms 'switch') 'Game Title'
        (Join-Path $dest 'Game.nsp') | Should -Exist
        $back = Read-DlromJob $job.id
        $back.status | Should -Be 'completed'
        $back.message | Should -Be 'Installed'
        @($back.installedPaths) | Should -Be @($dest)
        Should -Invoke Wait-QbitTorrent -Times 1 -ParameterFilter { $OwnsTorrent }
    }

    It 'claims the job (running, own pid) before waiting, and tidies the empty staging folders' {
        $job = New-WJob $script:C 'switch'
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        $script:AtWait.status | Should -Be 'running'
        $script:AtWait.pid | Should -Be $PID
        $script:AtWait.startedAt | Should -Not -BeNullOrEmpty
        (Join-Path $script:C.Roms '.dlrom-torrent') | Should -Not -Exist
    }

    It 'already-present torrent: copies, never removes it, leaves the files and the entry alone' {
        $job = New-WJob $script:C 'switch' -AlreadyPresent $true
        $ok = [bool](@(Invoke-TelegramJob -Job $job -Cfg $null) | Select-Object -Last 1)
        $ok | Should -BeTrue
        Should -Invoke Remove-QbitTorrent -Times 0
        Should -Invoke Wait-QbitTorrent -Times 1 -ParameterFilter { -not $OwnsTorrent }
        (Join-Path $script:Content 'Game.nsp') | Should -Exist
        (Join-Path (Join-Path (Join-Path $script:C.Roms 'switch') 'Game Title') 'Game.nsp') | Should -Exist
    }

    It 'syncs Steam once for a rule that has a parser' {
        $job = New-WJob $script:C 'switch'
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        Should -Invoke Sync-RomToSteam -Times 1 -ParameterFilter { $RomDest -eq (Join-Path $script:C.Roms 'switch') -and $InstalledCount -eq 1 }
    }

    It 'skips Steam for --no-steam, for a manual console and when steamSync is off' {
        $job = New-WJob $script:C 'switch' -NoSteam $true
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        $script:C = New-TCase
        $job = New-WJob $script:C 'psvita' -Files @('app\PCSE00001\eboot.bin')
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        $script:C = New-TCase
        Set-DlromConfig ([PSCustomObject]@{ steamSync = $false })
        $job = New-WJob $script:C 'switch'
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        Should -Invoke Sync-RomToSteam -Times 0
    }

    It 'still completes when the Steam sync throws' {
        Mock Sync-RomToSteam { throw 'srm exploded' }
        $job = New-WJob $script:C 'switch'
        $ok = [bool](@(Invoke-TelegramJob -Job $job -Cfg $null) | Select-Object -Last 1)
        $ok | Should -BeTrue
        (Read-DlromJob $job.id).status | Should -Be 'completed'
    }

    It 'records the manual note on the job and in the completion message' {
        $job = New-WJob $script:C 'psvita' -Files @('app\PCSE00001\eboot.bin')
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        $back = Read-DlromJob $job.id
        $back.status | Should -Be 'completed'
        $back.manualNote | Should -Match 'Vita3K'
        $back.message | Should -BeLike 'Installed - manual step: *Vita3K*'
    }

    It 'puts the real failure reason in the job message and leaves the data in staging' {
        $job = New-WJob $script:C 'switch' -Files @('readme.txt')
        $ok = [bool](@(Invoke-TelegramJob -Job $job -Cfg $null) | Select-Object -Last 1)
        $ok | Should -BeFalse
        $back = Read-DlromJob $job.id
        $back.status | Should -Be 'failed'
        $back.message | Should -Match '\.nsp'
        $back.message | Should -Match 'left in'
        (Join-Path $script:Content 'readme.txt') | Should -Exist
        Should -Invoke Sync-RomToSteam -Times 0
    }

    It 'a stalled wait fails the job as resumable and keeps the torrent' {
        Mock Wait-QbitTorrent { throw 'stalled: no progress for 60 min' }
        $job = New-WJob $script:C 'switch'
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        $back = Read-DlromJob $job.id
        $back.status | Should -Be 'failed'
        $back.message | Should -Be 'stalled: no progress for 60 min'
        (Test-TelegramJobResumable $back) | Should -BeTrue
        Should -Invoke Remove-QbitTorrent -Times 0
    }

    It 'fails clearly, without waiting, when qBittorrent is not running' {
        Mock Initialize-DlromQbit { return $false }
        $job = New-WJob $script:C 'switch'
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        $back = Read-DlromJob $job.id
        $back.status | Should -Be 'failed'
        $back.message | Should -Match 'qBittorrent is not reachable'
        $back.message | Should -Match "--resume $($job.id)"
        (Test-TelegramJobResumable $back) | Should -BeTrue
        Should -Invoke Wait-QbitTorrent -Times 0
    }

    It 'refuses to file a whole download folder when the torrent has no folder of its own' {
        Mock Wait-QbitTorrent { return [PSCustomObject]@{ state = 'uploading'; progress = 1.0; content_path = $script:Save; save_path = $script:Save } }
        $job = New-WJob $script:C 'switch'
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        (Read-DlromJob $job.id).message | Should -Match 'no folder of its own'
        Should -Invoke Remove-QbitTorrent -Times 0
    }

    It 'maps qBittorrent progress onto the job (5..90, step downloading)' {
        Mock Wait-QbitTorrent {
            Write-ProgressLine -Percent 50 -Line 'x'
            $script:Seen = Read-DlromJob $script:Job.id
            return [PSCustomObject]@{ state = 'uploading'; progress = 1.0; content_path = $script:Content; save_path = $script:Save }
        }
        Mock Write-Host { }
        $script:LOG_HEADLESS = $true
        $job = New-WJob $script:C 'switch'
        $null = Invoke-TelegramJob -Job $job -Cfg $null
        $script:LOG_HEADLESS = $false
        $script:Seen.step | Should -Be 'downloading'
        $script:Seen.progress | Should -Be 47
    }
}

# --- Resume -----------------------------------------------------------------------------------

Describe 'Resume and self-healing' {

    BeforeAll {
        function New-RJob {
            param([string]$Status, [int]$ProcId = 0, [string]$Message = '', [string]$Kind = 'telegram', [int]$AgeSec = 3600,
                  [string]$Folder = 'switch')
            $job = New-DlromJob -Kind $Kind -Query 'q' -Title "T-$Status" -Platform $Folder -RomsBase (Join-Path $script:Scratch 'roms') `
                    -Torrent @{ hash = 'abc'; platformFolder = $Folder; savePath = 'x'; alreadyPresent = $false }
            $job.status = $Status; $job.pid = $ProcId; $job.message = $Message
            $job.lastUpdate = (Get-Date).ToUniversalTime().AddSeconds(-$AgeSec).ToString('o')
            Save-DlromJob -Job $job -Strict
            return $job
        }
    }
    BeforeEach {
        Remove-Item -Path (Join-Path $script:JobsDir '*') -Force -ErrorAction SilentlyContinue
        Set-DlromConfig ([PSCustomObject]@{ telegramAutoResume = $true })
        Mock Start-DlromJob { return 4242 }
        Mock Invoke-TelegramJob { return $true }
        Mock Initialize-DlromQbit { return $true }
    }
    AfterEach { Set-DlromConfig $null }

    Context 'status' {
        It 'reads a legacy pid-0 running or pending telegram job as orphaned' {
            (Resolve-DlromJobStatus (New-RJob 'running')) | Should -Be 'orphaned'
            (Resolve-DlromJobStatus (New-RJob 'pending')) | Should -Be 'orphaned'
        }
        It 'gives a fresh pid-0 job the spawn grace' {
            (Resolve-DlromJobStatus (New-RJob 'pending' -AgeSec 5)) | Should -Be 'pending'
        }
        It 'detects a dead worker pid on a telegram job' {
            (Resolve-DlromJobStatus (New-RJob 'running' -ProcId $script:DeadPid)) | Should -Be 'orphaned'
            (Resolve-DlromJobStatus (New-RJob 'running' -ProcId $PID)) | Should -Be 'running'
        }
        It 'reads a live pid that started after the job as a reused pid (orphaned)' {
            $self = (Get-Process -Id $PID).StartTime.ToUniversalTime()
            $j = New-RJob 'running' -ProcId $PID
            $j.startedAt = $self.AddHours(-1).ToString('o')
            (Resolve-DlromJobStatus $j) | Should -Be 'orphaned'
            $j.startedAt = $self.AddSeconds(2).ToString('o')
            (Resolve-DlromJobStatus $j) | Should -Be 'running'
        }
        It 'leaves other kinds and terminal states alone' {
            (Resolve-DlromJobStatus (New-RJob 'running' -Kind 'retrogametalk')) | Should -Be 'running'
            (Resolve-DlromJobStatus (New-RJob 'completed')) | Should -Be 'completed'
            (Resolve-DlromJobStatus (New-RJob 'failed' -Message 'x')) | Should -Be 'failed'
        }
        It 'handles a lastUpdate that was read back as a DateTime' {
            $j = New-RJob 'running' -AgeSec 3600
            $j.lastUpdate = [datetime]::UtcNow.AddHours(-1)
            (Resolve-DlromJobStatus $j) | Should -Be 'orphaned'
        }
    }

    Context 'eligibility' {
        It 'orphaned: yes' { Test-TelegramJobResumable (New-RJob 'running') | Should -BeTrue }
        It 'completed: no' { Test-TelegramJobResumable (New-RJob 'completed') | Should -BeFalse }
        It 'live worker: no' { Test-TelegramJobResumable (New-RJob 'running' -ProcId $PID) | Should -BeFalse }
        It 'failed with <m>: <e>' -ForEach @(
            @{ m = 'stalled: no progress for 60 min'; e = $true }
            @{ m = 'Timed out after 86400s waiting for the torrent.'; e = $true }
            @{ m = 'qBittorrent is not reachable at http://127.0.0.1:8075 - start it'; e = $true }
            @{ m = 'No .nsp/.xci files found in the torrent.'; e = $false }
            @{ m = 'Torrent abc is no longer in qBittorrent (removed?); nothing to wait for.'; e = $false }
            @{ m = "qBittorrent reported state 'error' for the torrent."; e = $false }
        ) {
            Test-TelegramJobResumable (New-RJob 'failed' -Message $m) | Should -Be $e
        }
        It 'other kinds: no' { Test-TelegramJobResumable (New-RJob 'running' -Kind 'torrent') | Should -BeFalse }
    }

    Context 'dlrom --resume' {
        It 'restarts an orphaned job: pending, pid 0, cleared message, a new worker spawned' {
            $j = New-RJob 'running' -ProcId $script:DeadPid
            (Invoke-DlromResume -Id $j.id) | Should -Be 0
            Should -Invoke Start-DlromJob -Times 1 -ParameterFilter { $Job.id -eq $j.id }
            $back = Read-DlromJob $j.id
            $back.status | Should -Be 'pending'
            $back.pid | Should -Be 0
            $back.message | Should -Be 'Resumed'
            Should -Invoke Initialize-DlromQbit -Times 0
        }
        It 'restarts a stalled failed job' {
            $j = New-RJob 'failed' -Message 'stalled: no progress for 60 min'
            (Invoke-DlromResume -Id $j.id) | Should -Be 0
            Should -Invoke Start-DlromJob -Times 1
        }
        It 'refuses a completed job' {
            $j = New-RJob 'completed'
            (Invoke-DlromResume -Id $j.id) | Should -Be 1
            Should -Invoke Start-DlromJob -Times 0
        }
        It 'refuses a job that failed for another reason, a running one, a non-Telegram one and an unknown id' {
            (Invoke-DlromResume -Id (New-RJob 'failed' -Message 'No .nsp files found').id) | Should -Be 1
            (Invoke-DlromResume -Id (New-RJob 'running' -ProcId $PID).id) | Should -Be 1
            (Invoke-DlromResume -Id (New-RJob 'running' -Kind 'torrent').id) | Should -Be 1
            (Invoke-DlromResume -Id 'nosuchjob') | Should -Be 1
            Should -Invoke Start-DlromJob -Times 0
        }
        It '"all" resumes exactly the eligible jobs' {
            $a = New-RJob 'running' -ProcId $script:DeadPid
            $b = New-RJob 'failed' -Message 'stalled: no progress for 60 min'
            $null = New-RJob 'completed'
            $null = New-RJob 'failed' -Message 'No .nsp files found'
            $null = New-RJob 'running' -ProcId $PID
            $null = New-RJob 'running' -Kind 'torrent' -ProcId $script:DeadPid
            (Invoke-DlromResume -Id 'all') | Should -Be 0
            Should -Invoke Start-DlromJob -Times 2
            Should -Invoke Start-DlromJob -Times 1 -ParameterFilter { $Job.id -eq $a.id }
            Should -Invoke Start-DlromJob -Times 1 -ParameterFilter { $Job.id -eq $b.id }
        }
        It '"all" with nothing eligible is a quiet success' {
            $null = New-RJob 'completed'
            (Invoke-DlromResume -Id 'all') | Should -Be 0
            Should -Invoke Start-DlromJob -Times 0
        }
        It '--wait runs the worker inline and returns its outcome' {
            $j = New-RJob 'running' -ProcId $script:DeadPid
            (Invoke-DlromResume -Id $j.id -Wait) | Should -Be 0
            Should -Invoke Invoke-TelegramJob -Times 1
            Should -Invoke Start-DlromJob -Times 0
            Mock Invoke-TelegramJob { return $false }
            $k = New-RJob 'running' -ProcId $script:DeadPid
            (Invoke-DlromResume -Id $k.id -Wait) | Should -Be 1
        }
        It 'prints one JSON object with --json' {
            $j = New-RJob 'running' -ProcId $script:DeadPid
            $out = Invoke-DlromResume -Id $j.id -AsJson 6>&1 | Out-String
            $o = ($out -replace '(?s)^.*?(\{.*\}).*$', '$1') | ConvertFrom-Json
            $o.ok | Should -BeTrue
            @($o.resumed) | Should -Be @($j.id)
        }
    }

    Context 'auto-resume' {
        It 'restarts orphaned Telegram jobs only, each in the background' {
            $a = New-RJob 'running'
            $null = New-RJob 'failed' -Message 'stalled: no progress for 60 min'
            $null = New-RJob 'completed'
            $null = New-RJob 'running' -Kind 'torrent' -ProcId $script:DeadPid
            (Invoke-TelegramAutoResume) | Should -Be 1
            Should -Invoke Start-DlromJob -Times 1 -ParameterFilter { $Job.id -eq $a.id }
            Should -Invoke Invoke-TelegramJob -Times 0
        }
        It 'does nothing, and makes no qBittorrent call, when no job is orphaned' {
            $null = New-RJob 'completed'; $null = New-RJob 'running' -ProcId $PID
            (Invoke-TelegramAutoResume) | Should -Be 0
            Should -Invoke Start-DlromJob -Times 0
            Should -Invoke Initialize-DlromQbit -Times 0
        }
        It 'does nothing when telegramAutoResume is false' {
            Set-DlromConfig ([PSCustomObject]@{ telegramAutoResume = $false })
            $null = New-RJob 'running'
            (Invoke-TelegramAutoResume) | Should -Be 0
            Should -Invoke Start-DlromJob -Times 0
        }
        It 'is wired only into the normal download path of Add-ROM.ps1' {
            $src = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Add-ROM.ps1') -Raw
            $at = $src.IndexOf('Invoke-TelegramAutoResume -Cfg')
            $at | Should -BeGreaterThan 0
            # After every early exit: queries, clean, resume, the worker, and the no-query usage error.
            foreach ($marker in 'if ($Status)', 'if ($ListJobs)', 'if ($Clean)', 'if ($Resume)', 'if ($JobFile)', 'if (-not $Query)', 'if ($TelegramLogin') {
                $src.IndexOf($marker) | Should -BeLessThan $at -Because $marker
            }
            # Never on a dry run, and only once.
            $src.Substring($src.LastIndexOf("`n", $at) + 1, 40) | Should -Match 'if \(-not \$LinksOnly\)'
            ([regex]::Matches($src, 'Invoke-TelegramAutoResume')).Count | Should -Be 1
        }
    }
}

# --- --clean ----------------------------------------------------------------------------------

Describe '--clean and Telegram staging' {

    BeforeEach {
        Remove-Item -Path (Join-Path $script:JobsDir '*') -Force -ErrorAction SilentlyContinue
        $script:Roms = Join-Path $script:Scratch ('roms-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $null = New-TFile (Join-Path $script:Roms '.dlrom-torrent\switch\Game\x.nsp')
        Set-DlromConfig ([PSCustomObject]@{ romsBase = $script:Roms })
    }
    AfterEach { Set-DlromConfig $null }

    BeforeAll {
        function Get-StagingTargets { param($Roms) (Get-DlromCleanTargets -TempDir (Join-Path $script:Scratch 'no-temp') | Where-Object { $_.path -like "$Roms*" }) }
        function New-CJob {
            param([string]$Status, [int]$ProcId = 0, [string]$Message = '')
            $job = New-DlromJob -Kind 'telegram' -Query 'q' -Platform 'switch' -RomsBase $script:Roms `
                    -Torrent @{ hash = 'abc'; platformFolder = 'switch'; savePath = 'x'; alreadyPresent = $false }
            $job.status = $Status; $job.pid = $ProcId; $job.message = $Message
            $job.lastUpdate = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
            Save-DlromJob -Job $job -Strict
        }
    }

    It 'sweeps the staging leftover of a completed job' {
        New-CJob 'completed'
        @(Get-StagingTargets $script:Roms).Count | Should -BeGreaterThan 0
        (Get-StagingTargets $script:Roms | Select-Object -First 1).note | Should -Be 'torrent staging leftover'
    }
    It 'sweeps the staging leftover of a job that failed for a reason a retry cannot fix' {
        New-CJob 'failed' -Message 'No .nsp files found'
        @(Get-StagingTargets $script:Roms).Count | Should -BeGreaterThan 0
    }
    It 'keeps the staging folder of a running job' {
        New-CJob 'running' -ProcId $PID
        @(Get-StagingTargets $script:Roms).Count | Should -Be 0
    }
    It 'keeps the staging folder of an orphaned job, which is about to be resumed' {
        New-CJob 'running' -ProcId $script:DeadPid
        @(Get-StagingTargets $script:Roms).Count | Should -Be 0
    }
    It 'keeps the staging folder of a job that stalled and can be resumed' {
        New-CJob 'failed' -Message 'stalled: no progress for 60 min'
        @(Get-StagingTargets $script:Roms).Count | Should -Be 0
    }
}
