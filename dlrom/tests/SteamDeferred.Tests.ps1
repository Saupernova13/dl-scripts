# Tests for the deferred Steam sync queue (SteamDeferred.ps1) and the Game Mode gate in
# Sync-RomToSteam.
#
# The property that matters is not "does it queue" but "is the queue never lost": a Steam
# Deck user starts a download mid-game, and the only thing standing between them and a
# silently-dropped shortcut is that this queue survives a refused drain, a failed sync and
# a second ROM landing in the same folder. Each of those is pinned below.
#
# Test-DlGameMode is redefined per-context rather than mocked, because the production code
# calls it as a plain function from a dot-sourced file - Pester's Mock cannot intercept
# that without the module scaffolding this repo deliberately does not have.
#
# Only the filesystem is touched (a temp dir); nothing here runs Steam ROM Manager.

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    $script:RepoRoot   = Split-Path -Parent $script:ModuleRoot

    . (Join-Path $script:RepoRoot 'lib/Platform.ps1')
    . (Join-Path $script:ModuleRoot 'Constants.ps1')
    . (Join-Path $script:ModuleRoot 'Common.ps1')
    . (Join-Path $script:ModuleRoot 'Logging.ps1')
    . (Join-Path $script:ModuleRoot 'SteamRomManager.ps1')
    . (Join-Path $script:ModuleRoot 'SteamDeferred.ps1')

    $script:LOG_QUIET = $true
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dlrom-srmq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null

    # Point the queue at a temp dir so a real install's queue is never touched.
    function Get-SrmQueueDir {
        $dir = Join-Path $script:TestRoot 'srm-queue'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        return $dir
    }

    function Clear-TestQueue {
        Get-ChildItem -LiteralPath (Get-SrmQueueDir) -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    function New-TestRomDir {
        param([string]$Name)
        $dir = Join-Path $script:TestRoot $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    Set-DlromConfig ([PSCustomObject]@{ srmDeferInGameMode = $true })
}

AfterAll {
    if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Sync-RomToSteam Game Mode gate' {
    BeforeEach { Clear-TestQueue }

    Context 'in Game Mode' {
        BeforeAll { function Test-DlGameMode { return $true } }

        It 'queues instead of running Steam ROM Manager' {
            $dest = New-TestRomDir 'ps2'
            # Would throw if the gate let execution through to the real SRM driver.
            function Invoke-SteamRomManager { throw 'SRM must not run in Game Mode' }
            { Sync-RomToSteam -RomDest $dest -RomsBase $script:TestRoot -InstalledCount 1 } | Should -Not -Throw
            @(Get-SrmDeferredJobs).Count | Should -Be 1
        }

        It 'folds a second ROM for the same folder into one entry' {
            $dest = New-TestRomDir 'ps2'
            Add-SrmDeferredJob -RomDest $dest -InstalledCount 1 -Title 'First'  | Out-Null
            Add-SrmDeferredJob -RomDest $dest -InstalledCount 1 -Title 'Second' | Out-Null
            $entries = @(Get-SrmDeferredJobs)
            $entries.Count | Should -Be 1
            $entries[0].installedCount | Should -Be 2
            $entries[0].titles | Should -Contain 'Second'
        }

        It 'keeps separate entries for different folders' {
            Add-SrmDeferredJob -RomDest (New-TestRomDir 'ps2') | Out-Null
            Add-SrmDeferredJob -RomDest (New-TestRomDir 'psp') | Out-Null
            @(Get-SrmDeferredJobs).Count | Should -Be 2
        }

        It 'refuses to drain, and does not empty the queue doing so' {
            Add-SrmDeferredJob -RomDest (New-TestRomDir 'ps2') | Out-Null
            Invoke-SrmDeferredDrain | Should -Be 0
            @(Get-SrmDeferredJobs).Count | Should -Be 1
        }

        It 'honours srmDeferInGameMode = false' {
            $dest = New-TestRomDir 'ps2'
            Set-DlromConfig ([PSCustomObject]@{ srmDeferInGameMode = $false })
            function Invoke-SteamRomManager { param([string]$RomDest, [string]$RomsBase) }
            function Find-SrmWrapper { param([string]$Configured) return $null }
            Sync-RomToSteam -RomDest $dest -RomsBase $script:TestRoot -InstalledCount 1
            @(Get-SrmDeferredJobs).Count | Should -Be 0
            Set-DlromConfig ([PSCustomObject]@{ srmDeferInGameMode = $true })
        }
    }

    Context 'in Desktop Mode' {
        BeforeAll { function Test-DlGameMode { return $false } }

        It 'does not queue - it syncs' {
            $dest = New-TestRomDir 'ps2'
            function Invoke-SteamRomManager { param([string]$RomDest, [string]$RomsBase) }
            function Find-SrmWrapper { param([string]$Configured) return $null }
            Sync-RomToSteam -RomDest $dest -RomsBase $script:TestRoot -InstalledCount 1
            @(Get-SrmDeferredJobs).Count | Should -Be 0
        }
    }
}

Describe 'Invoke-SrmDeferredDrain' {
    BeforeAll { function Test-DlGameMode { return $false } }
    BeforeEach { Clear-TestQueue }

    It 'syncs each entry and clears it' {
        $a = New-TestRomDir 'ps2'
        $b = New-TestRomDir 'psp'
        Add-SrmDeferredJob -RomDest $a | Out-Null
        Add-SrmDeferredJob -RomDest $b | Out-Null
        $script:Synced = @()
        function Sync-RomToSteam {
            param([string]$RomDest, [string]$RomsBase, [int]$InstalledCount, [switch]$AlreadyDeferred)
            $script:Synced += $RomDest
        }
        Invoke-SrmDeferredDrain | Should -Be 2
        @(Get-SrmDeferredJobs).Count | Should -Be 0
        $script:Synced.Count | Should -Be 2
    }

    It 'passes -AlreadyDeferred so the drain cannot re-queue what it just took' {
        Add-SrmDeferredJob -RomDest (New-TestRomDir 'ps2') | Out-Null
        $script:SawFlag = $null
        function Sync-RomToSteam {
            param([string]$RomDest, [string]$RomsBase, [int]$InstalledCount, [switch]$AlreadyDeferred)
            $script:SawFlag = [bool]$AlreadyDeferred
        }
        Invoke-SrmDeferredDrain | Out-Null
        $script:SawFlag | Should -BeTrue
    }

    It 'keeps a failed entry, recording the attempt and the error' {
        Add-SrmDeferredJob -RomDest (New-TestRomDir 'ps2') | Out-Null
        function Sync-RomToSteam {
            param([string]$RomDest, [string]$RomsBase, [int]$InstalledCount, [switch]$AlreadyDeferred)
            throw 'simulated SRM failure'
        }
        Invoke-SrmDeferredDrain | Should -Be 0
        $left = @(Get-SrmDeferredJobs)
        $left.Count          | Should -Be 1
        $left[0].attempts    | Should -Be 1
        $left[0].lastError   | Should -Match 'simulated SRM failure'
    }

    It 'drops an entry whose folder has since been deleted' {
        $dir = New-TestRomDir 'gone'
        Add-SrmDeferredJob -RomDest $dir | Out-Null
        Remove-Item -LiteralPath $dir -Recurse -Force
        function Sync-RomToSteam {
            param([string]$RomDest, [string]$RomsBase, [int]$InstalledCount, [switch]$AlreadyDeferred)
            throw 'must not be called for a missing folder'
        }
        Invoke-SrmDeferredDrain | Should -Be 0
        @(Get-SrmDeferredJobs).Count | Should -Be 0
    }

    It 'survives an unreadable queue file instead of blocking the queue' {
        Add-SrmDeferredJob -RomDest (New-TestRomDir 'ps2') | Out-Null
        Set-Content -LiteralPath (Join-Path (Get-SrmQueueDir) 'corrupt.json') -Value '{ not json' -Encoding UTF8
        function Sync-RomToSteam {
            param([string]$RomDest, [string]$RomsBase, [int]$InstalledCount, [switch]$AlreadyDeferred)
        }
        Invoke-SrmDeferredDrain | Should -Be 1
    }
}

Describe 'Platform helpers' {
    It 'Join-DlPath accepts either separator in a literal segment' {
        $joined = Join-DlPath 'base' 'Emulation\roms'
        $joined | Should -Be (Join-Path (Join-Path 'base' 'Emulation') 'roms')
    }

    It 'Join-DlPath skips empty segments rather than producing a trailing separator' {
        Join-DlPath 'base' '' 'leaf' | Should -Be (Join-Path 'base' 'leaf')
    }

    It 'reports a session mode from the documented vocabulary' {
        Get-DlSessionMode | Should -BeIn @('windows', 'gamemode', 'desktop')
    }

    It 'never reports Game Mode on Windows' {
        if (Test-DlWindows) { Test-DlGameMode | Should -BeFalse }
        else { Set-ItResult -Skipped -Because 'not running on Windows' }
    }
}
