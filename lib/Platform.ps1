# lib/Platform.ps1
#
# The one place that knows which OS this is running on. Every path that differs between
# Windows and Linux resolves through a function here, so no module has to carry its own
# `if ($IsWindows)` and the two platforms cannot drift apart in a corner nobody tested.
#
# Loaded first by Add-ROM.ps1, and defensively by DriveResolver.ps1 so the other dl*
# scripts pick it up through the one file they all already dot-source.
#
# Usage:
#   . (Join-Path (Split-Path -Parent $PSScriptRoot) "lib/Platform.ps1")

# $IsWindows only exists on PowerShell 6+. On Windows PowerShell 5.1 it is $null, and 5.1
# only ever runs on Windows - so absent means Windows.
$script:DL_IS_WINDOWS = if ($null -eq $IsWindows) { $true } else { [bool]$IsWindows }

function Test-DlWindows { return $script:DL_IS_WINDOWS }

# Join any number of segments with the running platform's separator.
#
# `Join-Path a 'b\c'` is not portable: .NET on Linux treats the backslash as an ordinary
# filename character, so 'Emulation\roms' becomes one directory with a backslash in its
# name rather than two nested ones. Multi-argument Join-Path would solve it but is
# PowerShell 6+, and the Windows entry points still run under 5.1 - hence this.
function Join-DlPath {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Base,
        [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Parts
    )
    $path = $Base
    foreach ($part in $Parts) {
        if (-not $part) { continue }
        # Accept either separator in the literal so callers can write the natural form.
        foreach ($segment in ($part -split '[\\/]+')) {
            if ($segment) { $path = Join-Path $path $segment }
        }
    }
    return $path
}

# The user's home directory. $HOME is set on both platforms, but fall back for a service
# account or a stripped environment where it is not.
function Get-DlHomeDir {
    if ($HOME) { return $HOME }
    if ($script:DL_IS_WINDOWS) { return $env:USERPROFILE }
    return (Join-Path '/home' $env:USER)
}

# Config lives with the user's other config: %LOCALAPPDATA% on Windows, XDG on Linux.
# Windows resolves exactly where it always has, so no existing install moves.
function Get-DlConfigRoot {
    if ($script:DL_IS_WINDOWS) { return (Join-Path $env:LOCALAPPDATA 'dlScripts') }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-DlPath (Get-DlHomeDir) '.config' }
    return (Join-Path $base 'dlScripts')
}

# State that is regenerable rather than configured - job files, caches, the PS2 game db.
# Same directory as the config on Windows; ~/.local/share on Linux, per XDG.
function Get-DlDataRoot {
    if ($script:DL_IS_WINDOWS) { return (Join-Path $env:LOCALAPPDATA 'dlScripts') }
    $base = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-DlPath (Get-DlHomeDir) '.local' 'share' }
    return (Join-Path $base 'dlScripts')
}

# $env:TEMP is a Windows-only variable - it is empty on Linux, which silently turns
# `Join-Path $env:TEMP 'dlrom'` into a relative path in the current directory.
function Get-DlTempDir {
    if ($script:DL_IS_WINDOWS) { return $env:TEMP }
    if ($env:TMPDIR) { return $env:TMPDIR.TrimEnd('/') }
    return '/tmp'
}

# Where a browser or download manager drops files by default.
function Get-DlDownloadsDir {
    return (Join-DlPath (Get-DlHomeDir) 'Downloads')
}

# Roaming app data, for reading another application's config (PCSX2, qBittorrent).
# On Linux those live under XDG config, not a roaming profile.
function Get-DlRoamingRoot {
    if ($script:DL_IS_WINDOWS) { return $env:APPDATA }
    if ($env:XDG_CONFIG_HOME) { return $env:XDG_CONFIG_HOME }
    return (Join-DlPath (Get-DlHomeDir) '.config')
}

# --- EmuDeck layout -----------------------------------------------------------
# EmuDeck publishes its own paths as assignments, and both platforms can be read the same
# way - only the file and a leading '$' differ:
#   Linux    ~/emudeck/settings.sh          romsPath="/run/media/deck/<SD-LABEL>"/Emulation/roms
#   Windows  %APPDATA%\EmuDeck\settings.ps1  $romsPath="G:\Emulation\roms"
# The quotes sit mid-value on Linux because the storage root is interpolated, so strip all of
# them rather than expecting a fully-quoted value.
#
# Reading this beats hardcoding a drive on either OS: it follows wherever EmuDeck was
# pointed. Windows used to hardcode C:\Emulation, so moving the library to another drive
# left every default pointing at a folder that no longer held the ROMs.

$script:DL_EMUDECK_SETTINGS = $null

function Get-DlEmuDeckSettingsFile {
    if ($script:DL_IS_WINDOWS) {
        return (Join-DlPath ([Environment]::GetFolderPath('ApplicationData')) 'EmuDeck' 'settings.ps1')
    }
    return (Join-DlPath (Get-DlHomeDir) 'emudeck' 'settings.sh')
}

function Get-DlEmuDeckSetting {
    param([Parameter(Mandatory)][string]$Name)
    if ($null -eq $script:DL_EMUDECK_SETTINGS) {
        $script:DL_EMUDECK_SETTINGS = @{}
        $file = Get-DlEmuDeckSettingsFile
        if (Test-Path $file) {
            foreach ($line in (Get-Content $file -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*\$?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$') {
                    $script:DL_EMUDECK_SETTINGS[$Matches[1]] = $Matches[2] -replace '["'']', ''
                }
            }
        }
    }
    if ($script:DL_EMUDECK_SETTINGS.ContainsKey($Name)) { return [string]$script:DL_EMUDECK_SETTINGS[$Name] }
    return ''
}

# --- Steam Deck session mode --------------------------------------------------
# Game Mode is the gamescope session, where Steam *is* the session: it cannot be exited,
# and Steam ROM Manager's own CLI warns that adding while Steam runs loses categories.
# Downloads are unaffected, so callers gate only the Steam-facing step on this.

function Test-DlGameMode {
    if ($script:DL_IS_WINDOWS) { return $false }
    try {
        $null = & pgrep -x gamescope 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# Put the Deck back into Game Mode. steamos-session-select stops the plasma workspace and
# starts gamescope-session, which brings Steam up in Big Picture - the state the device
# normally lives in, and the one the user wants to be in once a library sync has finished.
#
# It is deliberately the last thing any caller does: the switch tears down the desktop
# session, so anything still running there goes with it. Returns false when this is not a
# Deck or steamos-session-select is absent, which is not an error - there is simply no Game
# Mode to return to.
function Enter-DlGameMode {
    if ($script:DL_IS_WINDOWS) { return $false }
    $exe = Get-Command 'steamos-session-select' -ErrorAction SilentlyContinue
    if (-not $exe) { return $false }
    try {
        & $exe.Source 'gamescope' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# 'windows' | 'gamemode' | 'desktop' - the vocabulary written into deferred job files,
# so these strings are a contract with anything reading them back.
function Get-DlSessionMode {
    if ($script:DL_IS_WINDOWS)  { return 'windows' }
    if (Test-DlGameMode)        { return 'gamemode' }
    return 'desktop'
}
