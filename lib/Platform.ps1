# The one place that knows which OS this is running on. Every path that differs between
# Windows and Linux resolves through a function here, so no module carries its own
# `if ($IsWindows)` and the two platforms cannot drift apart in a corner nobody tested.
#
# Loaded first by Add-ROM.ps1, and defensively by DriveResolver.ps1 so the other dl* scripts
# pick it up through the one file they all dot-source.

# $IsWindows is PS6+. On 5.1 it is $null, and 5.1 only runs on Windows - so absent means Windows.
$script:DL_IS_WINDOWS = if ($null -eq $IsWindows) { $true } else { [bool]$IsWindows }

function Test-DlWindows { return $script:DL_IS_WINDOWS }

# `Join-Path a 'b\c'` is not portable: .NET on Linux treats the backslash as a filename
# character, so 'Emulation\roms' becomes one directory, not two. Multi-argument Join-Path
# fixes it but is PS6+, and the Windows entry points still run under 5.1.
function Join-DlPath {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Base,
        [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Parts
    )
    $path = $Base
    foreach ($part in $Parts) {
        if (-not $part) { continue }
        # Accept either separator so callers can write the natural form.
        foreach ($segment in ($part -split '[\\/]+')) {
            if ($segment) { $path = Join-Path $path $segment }
        }
    }
    return $path
}

# $HOME is set on both platforms; fall back for a stripped environment where it is not.
function Get-DlHomeDir {
    if ($HOME) { return $HOME }
    if ($script:DL_IS_WINDOWS) { return $env:USERPROFILE }
    return (Join-Path '/home' $env:USER)
}

# %LOCALAPPDATA% on Windows, XDG config on Linux.
function Get-DlConfigRoot {
    if ($script:DL_IS_WINDOWS) { return (Join-Path $env:LOCALAPPDATA 'dlScripts') }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-DlPath (Get-DlHomeDir) '.config' }
    return (Join-Path $base 'dlScripts')
}

# Regenerable state - job files, caches, the PS2 game db. XDG data dir on Linux.
function Get-DlDataRoot {
    if ($script:DL_IS_WINDOWS) { return (Join-Path $env:LOCALAPPDATA 'dlScripts') }
    $base = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-DlPath (Get-DlHomeDir) '.local' 'share' }
    return (Join-Path $base 'dlScripts')
}

# $env:TEMP is Windows-only; empty on Linux, which silently makes Join-Path relative.
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
function Get-DlRoamingRoot {
    if ($script:DL_IS_WINDOWS) { return $env:APPDATA }
    if ($env:XDG_CONFIG_HOME) { return $env:XDG_CONFIG_HOME }
    return (Join-DlPath (Get-DlHomeDir) '.config')
}

# --- EmuDeck layout -----------------------------------------------------------
# EmuDeck writes both platforms' paths as assignments; only the file and a leading '$' differ:
#   Linux    ~/emudeck/settings.sh          romsPath="/run/media/deck/<SD-LABEL>"/Emulation/roms
#   Windows  %APPDATA%\EmuDeck\settings.ps1  $romsPath="<drive>:\Emulation\roms"
# Linux interpolates the storage root, so quotes sit mid-value - strip all of them. Reading
# this beats hardcoding a drive: a literal is only correct on the machine it was written on.

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
# In Game Mode Steam is the session: it cannot be exited, and SRM's own CLI warns that adding
# while Steam runs loses categories. Downloads are unaffected, so callers gate only the
# Steam-facing step on this.

# The systemd unit is the authority; the process name is not - SteamOS runs the compositor as
# 'gamescope-wl' and pgrep -x matches on comm, so `pgrep -x gamescope` found nothing and Game
# Mode looked exactly like Desktop Mode, silently disarming the guard.
function Test-DlGameMode {
    if ($script:DL_IS_WINDOWS) { return $false }
    try {
        $state = & systemctl --user is-active gamescope-session.service 2>$null
        if ("$state".Trim() -eq 'active') { return $true }
    } catch { }
    # Fallback for a session started outside systemd; both spellings.
    foreach ($name in @('gamescope-wl', 'gamescope')) {
        try {
            $null = & pgrep -x $name 2>$null
            if ($LASTEXITCODE -eq 0) { return $true }
        } catch { }
    }
    return $false
}

# Deliberately the last thing any caller does: the switch tears down the desktop session, so
# anything still running there goes with it. False means this is not a Deck, which is not an
# error - there is simply no Game Mode to return to.
function Enter-DlGameMode { return (Set-DlSteamSession 'gamescope') }

# 'plasma' is SteamOS's ONE-SHOT desktop session, so a temporary visit does not change what
# the Deck boots into.
function Exit-DlGameMode { return (Set-DlSteamSession 'plasma') }

# steamos-session-select re-execs through pkexec, so this needs the polkit rule SteamOS ships
# - there is no interactive agent over SSH. It also stops the current session, survivable only
# because the worker runs under systemd --user, not in the session cgroup (see Jobs.ps1).
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
# Switching sessions kills Steam, and Decky exits when it loses Steam's CEF. systemd records
# that as an explicit Stop, so Restart=always does NOT bring it back - the homescreen just
# comes up unstyled with every plugin still installed. Anything that restarts the session has
# to put it back, and 'systemctl restart' only succeeds where the local polkit rule from
# install-decky-polkit.sh is present.

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
# needs a moment to reattach before it is fair to call it dead.
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

# Block until a desktop session is usable, not merely requested: SRM is Electron and needs a
# real X display, so starting it while plasma comes up fails with "Missing X server". Ready
# means some process in the session is advertising DISPLAY.
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

# 'windows' | 'gamemode' | 'desktop' - written into deferred job files, so these strings are
# a contract with anything reading them back.
function Get-DlSessionMode {
    if ($script:DL_IS_WINDOWS)  { return 'windows' }
    if (Test-DlGameMode)        { return 'gamemode' }
    return 'desktop'
}
