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
#   Windows  %APPDATA%\EmuDeck\settings.ps1  $romsPath="<drive>:\Emulation\roms"
# The quotes sit mid-value on Linux because the storage root is interpolated, so strip all of
# them rather than expecting a fully-quoted value.
#
# Reading this beats hardcoding a drive on either OS: EmuDeck can be pointed at any drive,
# and a literal in here is only ever correct on the machine it was written on. The fallback
# when EmuDeck is absent derives from the system drive rather than naming one.

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

# The systemd unit is the authority here, and its name is stable. The process name is not:
# SteamOS runs the compositor as 'gamescope-wl' while its own argv[0] still reads
# 'gamescope', and pgrep -x matches on comm - so `pgrep -x gamescope` found nothing and Game
# Mode was indistinguishable from Desktop Mode. That silently disarmed the guard: every
# caller believed it was safe to run Steam ROM Manager, which is exactly the broken add the
# guard exists to prevent. Verified on SteamOS 2026-07-29 with gamescope-session active.
function Test-DlGameMode {
    if ($script:DL_IS_WINDOWS) { return $false }
    try {
        $state = & systemctl --user is-active gamescope-session.service 2>$null
        if ("$state".Trim() -eq 'active') { return $true }
    } catch { }
    # Fallback for a session started outside systemd. Both spellings, because which one
    # matches depends on how the compositor was launched.
    foreach ($name in @('gamescope-wl', 'gamescope')) {
        try {
            $null = & pgrep -x $name 2>$null
            if ($LASTEXITCODE -eq 0) { return $true }
        } catch { }
    }
    return $false
}

# Put the Deck back into Game Mode. steamos-session-select stops the plasma workspace and
# starts gamescope-session, which brings Steam up in Big Picture - the state the device
# normally lives in, and the one the user wants to be in once a library sync has finished.
#
# It is deliberately the last thing any caller does: the switch tears down the desktop
# session, so anything still running there goes with it. Returns false when this is not a
# Deck or steamos-session-select is absent, which is not an error - there is simply no Game
# Mode to return to.
function Enter-DlGameMode { return (Set-DlSteamSession 'gamescope') }

# Drop to the desktop so a GUI tool can run. 'plasma' is SteamOS's ONE-SHOT desktop session
# (plasma-steamos-oneshot.desktop) rather than a persistent one, which is what we want for a
# temporary visit: it does not change what the Deck boots into.
function Exit-DlGameMode { return (Set-DlSteamSession 'plasma') }

# steamos-session-select re-execs itself through pkexec, so this depends on the polkit rule
# SteamOS ships for it - there is no interactive agent on an SSH-driven run. It also stops the
# current session, which is survivable here only because the worker runs under systemd --user
# rather than in the session cgroup (see Jobs.ps1); a plain background child would die with it.
function Set-DlSteamSession {
    param([ValidateSet('gamescope', 'plasma')][string]$Session)
    if ($script:DL_IS_WINDOWS) { return $false }
    $exe = Get-Command 'steamos-session-select' -ErrorAction SilentlyContinue
    if (-not $exe) { return $false }
    try {
        & $exe.Source $Session 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# --- Decky Loader -------------------------------------------------------------
# Switching sessions kills Steam, and Decky Loader exits when it loses Steam's CEF. systemd
# records that as an explicit Stop, so the unit's own Restart=always does NOT bring it back -
# the user just finds their homescreen unstyled and CSS Loader missing, with every plugin still
# installed. Anything that restarts the session has to put it back.
#
# 'systemctl restart' on a system unit needs authorisation. SteamOS ships no polkit rule for
# unit management (it does for steamos-session-select), so this only succeeds where the local
# rule from install-decky-polkit.sh is present; without it we warn with the exact fix rather
# than failing silently, because silence is what made this hard to find.

function Test-DlDeckyPresent {
    if ($script:DL_IS_WINDOWS) { return $false }
    return (Test-Path '/etc/systemd/system/plugin_loader.service')
}

function Test-DlDeckyActive {
    if (-not (Test-DlDeckyPresent)) { return $false }
    try {
        $state = & systemctl is-active plugin_loader 2>$null
        return ("$state".Trim() -eq 'active')
    } catch { return $false }
}

# $SettleSec is spent only when Decky was up beforehand: Game Mode restarts Steam, and Decky
# needs a moment to reattach before it is fair to call it dead. Waiting unconditionally would
# add the delay to every caller - including Windows, where there is no Decky at all.
function Restore-DlDecky {
    param([switch]$WasActive, [int]$SettleSec = 8)
    if (-not $WasActive -or -not (Test-DlDeckyPresent)) { return }
    if ($SettleSec -gt 0) { Start-Sleep -Seconds $SettleSec }
    if (Test-DlDeckyActive) { return }          # survived the switch, nothing to do

    Write-Log "Decky Loader stopped during the session switch - restarting it..." 'INFO'
    try { & systemctl restart plugin_loader 2>$null | Out-Null } catch { }
    Start-Sleep -Seconds 3
    if (Test-DlDeckyActive) {
        Write-Log "Decky Loader is back." 'SUCCESS'
        return
    }
    Write-Log "Could not restart Decky Loader - it needs authorisation this session does not have." 'WARN'
    Write-Log "Your plugins and themes are intact; only the loader is down. Fix it with:" 'WARN'
    Write-Log "  sudo systemctl start plugin_loader        (one off)" 'WARN'
    Write-Log "  sudo ~/install-decky-polkit.sh           (so this repairs itself in future)" 'WARN'
}

# Block until a desktop session is actually usable, not merely requested. Steam ROM Manager
# is an Electron app and needs a real X display: starting it while plasma is still coming up
# fails with "Missing X server or $DISPLAY" and a segfault. A session is ready once some
# process in it is advertising DISPLAY, which is the same signal Import-DesktopSessionEnv
# borrows the environment from.
function Wait-DlDesktopSession {
    param([int]$TimeoutSec = 120)
    if ($script:DL_IS_WINDOWS) { return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        foreach ($name in @('kwin_x11', 'kwin_wayland', 'plasmashell')) {
            foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                try {
                    $raw = [System.IO.File]::ReadAllText("/proc/$($proc.Id)/environ")
                    if ($raw.Split([char]0) -match '^DISPLAY=.') { return $true }
                } catch { }
            }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# 'windows' | 'gamemode' | 'desktop' - the vocabulary written into deferred job files,
# so these strings are a contract with anything reading them back.
function Get-DlSessionMode {
    if ($script:DL_IS_WINDOWS)  { return 'windows' }
    if (Test-DlGameMode)        { return 'gamemode' }
    return 'desktop'
}
