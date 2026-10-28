# Steam ROM Manager (SRM) integration. We never write a Steam shortcut directly - SRM
# tracks what it added, so driving it (rather than the shortcuts file) means re-running
# reconciles instead of duplicating.

function Find-Srm {
    param([string]$Configured)
    if ($Configured -and (Test-Path $Configured)) { return $Configured }
    if (Test-Path $script:DEFAULT_SRM_EXE) { return $script:DEFAULT_SRM_EXE }
    $names = if (Test-DlWindows) { @('srm.exe') } else { @('steam-rom-manager', 'srm') }
    foreach ($name in $names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# Locate the standalone srm-wrapper CLI (preferred over the built-in logic below).
function Find-SrmWrapper {
    param([string]$Configured)
    if ($Configured -and (Test-Path $Configured)) { return $Configured }
    foreach ($name in @('srm-wrapper.cmd', 'srm-wrapper')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# Where SRM keeps userSettings.json and userConfigurations.json.
#
# Windows SRM is portable: userData sits beside the exe. The Linux AppImage is read-only and
# uses ~/.config/steam-rom-manager/userData instead - looking beside the AppImage finds
# nothing, and the parser-enable step then silently does nothing.
function Get-SrmUserDataDir {
    param([string]$SrmExe)
    if (-not (Test-DlWindows)) {
        $electron = Join-DlPath (Get-DlRoamingRoot) 'steam-rom-manager' 'userData'
        if (Test-Path $electron) { return $electron }
    }
    return Join-Path (Split-Path -Parent $SrmExe) "userData"
}

# SRM's userSettings.json, or $null. One reader for both callers below, which each want a
# different key out of the same file.
function Get-SrmUserSettings {
    param([string]$SrmExe)
    $settingsPath = Join-Path (Get-SrmUserDataDir $SrmExe) 'userSettings.json'
    if (-not (Test-Path $settingsPath)) { return $null }
    try   { return (Get-Content $settingsPath -Raw | ConvertFrom-Json) }
    catch { return $null }
}

function Get-SrmRomsDir {
    param([string]$SrmExe, [string]$Fallback)
    $romsDir = (Get-SrmUserSettings -SrmExe $SrmExe).environmentVariables.romsDirectory
    if ($romsDir) { return $romsDir }
    return $Fallback
}

function Get-SrmSteamExe {
    param([string]$SrmExe)
    $steamDir = (Get-SrmUserSettings -SrmExe $SrmExe).environmentVariables.steamDirectory
    $exeName  = if (Test-DlWindows) { 'steam.exe' } else { 'steam' }
    if ($steamDir) {
        $candidate = Join-Path $steamDir $exeName
        # -PathType Leaf: on Linux ~/.steam/steam/steam is a DIRECTORY, and a bare Test-Path
        # matched it and handed Start-Process a folder. The fallback below finds the real one.
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    if (Test-DlWindows) {
        $fallback = Join-DlPath ${env:ProgramFiles(x86)} 'Steam' 'steam.exe'
        if (Test-Path $fallback) { return $fallback }
        return $null
    }
    # On Linux steamDirectory points at the data dir (~/.local/share/Steam), not the binary.
    $cmd = Get-Command 'steam' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# SRM stores parser folders with '${/}' placeholders and mixed separators; fold to '/'.
function ConvertTo-ComparablePath {
    param([string]$Path)
    return ([string]$Path -replace '\\', '/').TrimEnd('/')
}

# Parsers to enable so $RomDest is picked up - or nothing, when an enabled parser already
# covers it (Test-SrmParserCovers below decides, weighing romDirectory AND the glob).
#
# One console must end up served by ONE emulator: two enabled parsers over the same folder
# each emit a shortcut per game, so the Steam library shows every title twice.
function Get-SrmParserIdsForFolder {
    param([string]$SrmExe, [string]$RomDest, [string]$RomsBase)
    $configPath = Join-Path (Get-SrmUserDataDir $SrmExe) "userConfigurations.json"
    if (-not (Test-Path $configPath)) { return @() }
    try {
        $parsers = Get-Content $configPath -Raw | ConvertFrom-Json
    } catch {
        Write-Log "Could not parse SRM userConfigurations.json; skipping parser enable." 'WARN'
        return @()
    }
    $romsDir    = Get-SrmRomsDir -SrmExe $SrmExe -Fallback $RomsBase
    $targetNorm = ConvertTo-ComparablePath $RomDest

    $exact = @()
    foreach ($p in $parsers) {
        if (-not $p.romDirectory) { continue }
        $dir  = ConvertTo-ComparablePath (($p.romDirectory -replace [regex]::Escape('${romsdirglobal}'), $romsDir) -replace [regex]::Escape('${/}'), '/')
        $glob = [string]$p.parserInputs.glob
        # An enabled parser that already reaches into this folder: add nothing.
        if ($p.disabled -ne $true -and (Test-SrmParserCovers -ParserDir $dir -Glob $glob -Target $targetNorm)) {
            Write-Log "Folder $RomDest is already served by '$($p.configTitle)' - not enabling another parser." 'DEBUG'
            return @()
        }
        if ($dir -ieq $targetNorm -and $p.disabled -eq $true) { $exact += $p.parserId }
    }
    # Only ever one, so a RetroArch core and a standalone emulator never both get enabled.
    if ($exact.Count -gt 1) { return @($exact[0]) }
    return @($exact)
}

# Does a parser's search actually reach into $Target?
#
# romDirectory alone does not answer it: many parsers sit on the BASE roms directory and pick
# their platform in the GLOB instead.
#
#   Nintendo 64 - Rosalie's Mupen GUI    dir=<roms>      glob=@(n64|n64dd)/**/${title}@(.z64|…)
#   Desktop Applications                 dir=<roms>      glob={desktop/**/…,desktop}/${title}…
#   RetroArch Mupen64Plus Next           dir=<roms>/n64  glob=**/${title}@(.z64|…)
#
# So an ancestor is necessary but not sufficient - treat any ancestor as covering and
# "Desktop Applications", on the base dir, covers every console.
function Test-SrmParserCovers {
    param([string]$ParserDir, [string]$Glob, [string]$Target)
    if (-not $ParserDir -or -not $Target) { return $false }
    if ($ParserDir -ieq $Target) { return $true }

    $prefix = $ParserDir.TrimEnd('/') + '/'
    if (-not $Target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }

    # Ancestor: the glob must name the folder we care about.
    $leaf = (($Target.Substring($prefix.Length)) -split '/')[0]
    $lead = ($Glob -split '/')[0]
    # '**' or a '${title}' first segment means it walks everything below romDirectory.
    if (-not $lead -or $lead -like '**' -or $lead -match '^\*' -or $lead -match '\$\{') { return $true }
    $alts = @($lead -split '[@!(){}|,]' | Where-Object { $_ })
    return ($alts -contains $leaf)
}

# -WindowStyle is Windows-only and pwsh on Linux throws rather than ignoring it. Steam sync is
# warn-and-continue by design, so this failed quietly and shortcuts.vdf went untouched.
function Get-HiddenWindowOption {
    if (Test-DlWindows) { return @{ WindowStyle = 'Hidden' } }
    return @{}
}

# Relaunch Steam WITHOUT passing on an administrator token.
#
# Start-Process copies the caller's token to the child, so an elevated shell leaves an elevated
# Steam behind until the next reboot, and every emulator it launches inherits admin (Ryujinx
# refuses to start at all). explorer.exe runs at medium integrity, so handing it the path makes
# it the parent instead. Fire and forget: Steam is not explorer's child.
function Start-SteamDeElevated {
    param([string]$SteamExe)

    if (-not (Test-DlWindows)) { Start-Process -FilePath $SteamExe | Out-Null; return }

    $elevated = $false
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $elevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Log "Could not determine elevation ($($_.Exception.Message)); starting Steam directly." 'DEBUG'
    }

    if (-not $elevated) { Start-Process -FilePath $SteamExe | Out-Null; return }

    Write-Log "Shell is elevated - starting Steam via explorer.exe so it does not inherit administrator." 'INFO'
    try {
        Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList "`"$SteamExe`"" | Out-Null
    } catch {
        Write-Log "explorer.exe handoff failed ($($_.Exception.Message)); starting Steam directly - it will be elevated." 'WARN'
        Start-Process -FilePath $SteamExe | Out-Null
    }
}

# SRM is Electron: even its CLI subcommands start a renderer, so it needs a desktop session
# and dies over SSH with "Missing X server or $DISPLAY". DISPLAY=:0 alone is not enough - the
# XAUTHORITY cookie is required too and its filename is random per session, so it has to be
# discovered rather than assumed.
function Import-DesktopSessionEnv {
    if (Test-DlWindows) { return $true }
    if ($env:DISPLAY -and $env:XAUTHORITY) { return $true }

    $wanted = @('DISPLAY', 'XAUTHORITY', 'XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS', 'WAYLAND_DISPLAY')
    foreach ($name in @('kwin_x11', 'kwin_wayland', 'plasmashell', 'gamescope', 'steam')) {
        foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try   { $raw = [System.IO.File]::ReadAllText("/proc/$($proc.Id)/environ") }
            catch { continue }

            $found = @{}
            foreach ($entry in $raw.Split([char]0)) {
                $split = $entry.IndexOf('=')
                if ($split -lt 1) { continue }
                $key = $entry.Substring(0, $split)
                if ($wanted -contains $key) { $found[$key] = $entry.Substring($split + 1) }
            }
            if (-not $found.ContainsKey('DISPLAY')) { continue }

            foreach ($key in $found.Keys) { Set-Item -Path "Env:$key" -Value $found[$key] }
            Write-Log "Using the desktop session from '$name' (DISPLAY=$($found['DISPLAY']))." 'DEBUG'
            return $true
        }
    }
    Write-Log "No desktop session found. Steam ROM Manager is a GUI app and cannot run headless." 'WARN'
    return $false
}

function Invoke-Srm {
    param([string]$SrmExe, [string[]]$SrmArgs)
    $workDir = Split-Path -Parent $SrmExe
    $hidden  = Get-HiddenWindowOption
    [void](Import-DesktopSessionEnv)
    $proc = Start-Process -FilePath $SrmExe -ArgumentList $SrmArgs -WorkingDirectory $workDir `
        -Wait -PassThru @hidden
    return $proc.ExitCode
}

# Built-in SRM driver (used when the standalone srm-wrapper CLI isn't available).
function Invoke-SteamRomManager {
    param([string]$RomDest, [string]$RomsBase)

    $srm = Find-Srm -Configured (Get-CfgValue 'srmExe' '')
    if (-not $srm) {
        Write-Log "Steam sync skipped: neither srm-wrapper nor Steam ROM Manager (srm.exe) was found." 'WARN'
        Write-Log "Install srm-wrapper on PATH, or Steam ROM Manager (EmuDeck installs it at $($script:DEFAULT_SRM_EXE)), to auto-add ROMs to Steam." 'WARN'
        Write-Log "The ROM is downloaded and in place at: $RomDest" 'WARN'
        return
    }
    Write-Log "Steam ROM Manager: $srm" 'DEBUG'

    # 1) Enable the parser watching this folder (if requested and currently disabled)
    if ([bool](Get-CfgValue 'srmEnableParser' $true)) {
        $ids = @(Get-SrmParserIdsForFolder -SrmExe $srm -RomDest $RomDest -RomsBase $RomsBase)
        if ($ids.Count -gt 0) {
            Write-Log "Enabling SRM parser(s) for $RomDest : $($ids -join ', ')" 'INFO'
            $code = Invoke-Srm -SrmExe $srm -SrmArgs (@('enable') + $ids)
            if ($code -ne 0) { Write-Log "srm enable exited with code $code." 'WARN' }
        } else {
            Write-Log "No disabled SRM parser watches $RomDest (already enabled or none configured)." 'DEBUG'
        }
    }

    # 2) Decide Steam restart behaviour
    $policy   = (Get-CfgValue 'srmRestartSteam' 'auto').ToString().ToLower()
    $running  = [bool](Get-Process -Name steam -ErrorAction SilentlyContinue)
    $restart  = switch ($policy) {
        'always' { $true }
        'never'  { $false }
        default  { $running }   # 'auto'
    }
    $steamExe = Get-SrmSteamExe -SrmExe $srm

    # 3) Close Steam so SRM can fully apply (categories require Steam closed)
    if ($restart -and $running) {
        if ($steamExe) {
            Write-Log "Shutting down Steam so SRM can apply changes..." 'INFO'
            $hidden = Get-HiddenWindowOption
            Start-Process -FilePath $steamExe -ArgumentList '-shutdown' @hidden | Out-Null
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Process -Name steam -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
            }
            if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
                Write-Log "Steam did not exit within 20s; continuing anyway (new shortcut may need a manual Steam restart)." 'WARN'
            }
        } else {
            Write-Log "Steam is running but steam.exe path is unknown; cannot restart it automatically." 'WARN'
        }
    }

    # 4) Add to Steam
    Write-Log "Running Steam ROM Manager 'add'..." 'INFO'
    $addCode = Invoke-Srm -SrmExe $srm -SrmArgs @('add')
    if ($addCode -eq 0) {
        Write-Log "Steam ROM Manager finished adding games to Steam." 'SUCCESS'
    } else {
        Write-Log "srm add exited with code $addCode." 'WARN'
    }

    # 5) Relaunch Steam
    if ($restart -and ($running -or $policy -eq 'always')) {
        if ($steamExe) {
            Write-Log "Relaunching Steam..." 'INFO'
            Start-SteamDeElevated -SteamExe $steamExe
        } else {
            Write-Log "Could not relaunch Steam (steam.exe path unknown); start it manually to see the new game." 'WARN'
        }
    } elseif (-not $restart) {
        Write-Log "Steam not restarted (policy: $policy). Restart Steam to see the new game." 'INFO'
    }
}

# Add freshly installed ROM(s) to Steam. Prefer the standalone srm-wrapper CLI; fall back
# to the built-in Invoke-SteamRomManager if the wrapper isn't installed or returns non-zero.
#
# -AlreadyDeferred is set by the queue drain, which has already established that this is a
# safe moment to touch Steam; without it the drain would re-queue what it just picked up.
#
# On a Deck this borrows the desktop for one sync and hands it straight back, so a ROM asked
# for from Game Mode arrives finished rather than half-done. Only this step needs the desktop,
# so the device is away for about a minute rather than the length of the transfer.
#
# The switch stops the running session, which the worker survives only because it lives under
# systemd --user rather than the session cgroup (see Jobs.ps1). False means the round trip
# could not be made and the caller should queue - the Deck is never left on the desktop.
function Invoke-SrmInDesktopSession {
    param([string]$RomDest, [string]$RomsBase, [int]$InstalledCount)

    # Noted before the first switch: Decky does not survive Steam going away, and only
    # something that knew it was up beforehand can put it back.
    $deckyWasUp = Test-DlDeckyActive

    Write-Log "Game Mode is active - switching to Desktop Mode to run Steam ROM Manager..." 'INFO'
    if (-not (Exit-DlGameMode)) {
        Write-Log "Could not leave Game Mode (steamos-session-select unavailable or refused)." 'WARN'
        return $false
    }

    if (-not (Wait-DlDesktopSession -TimeoutSec 120)) {
        Write-Log "Desktop session did not become usable within 120s." 'WARN'
        $null = Enter-DlGameMode        # never strand the Deck on a half-started desktop
        Restore-DlDecky -WasActive:$deckyWasUp
        return $false
    }
    Write-Log "Desktop session is up." 'DEBUG'

    try {
        Sync-RomToSteam -RomDest $RomDest -RomsBase $RomsBase -InstalledCount $InstalledCount -AlreadyDeferred
        return $true
    } catch {
        Write-Log "Steam sync failed in the borrowed desktop session: $($_.Exception.Message)" 'ERROR'
        return $false
    } finally {
        # Every path, including the failure above: back to Game Mode whether the sync worked.
        Write-Log "Returning the Deck to Game Mode..." 'INFO'
        if (Enter-DlGameMode) { Write-Log "Back in Game Mode." 'SUCCESS' }
        else { Write-Log "Could not switch back to Game Mode." 'WARN' }
        Restore-DlDecky -WasActive:$deckyWasUp
    }
}

function Sync-RomToSteam {
    param([string]$RomDest, [string]$RomsBase, [int]$InstalledCount, [switch]$AlreadyDeferred)

    # Game Mode gate. The download is already on disk and staying there; only the Steam step
    # is affected, because SRM cannot write the library from inside the gamescope session.
    # Preferred answer is to borrow the desktop and give it straight back; queueing is the
    # fallback when the session will not switch, or when auto-switching is off.
    if (-not $AlreadyDeferred -and (Test-DlGameMode)) {
        if ([bool](Get-CfgValue 'srmAutoSwitchSession' $true)) {
            if (Invoke-SrmInDesktopSession -RomDest $RomDest -RomsBase $RomsBase -InstalledCount $InstalledCount) { return }
            Write-Log "Falling back to the deferred queue." 'WARN'
        }
        if ([bool](Get-CfgValue 'srmDeferInGameMode' $true)) {
            $id = Add-SrmDeferredJob -RomDest $RomDest -RomsBase $RomsBase -InstalledCount $InstalledCount
            Write-Log "Game Mode detected - Steam sync deferred (queue id $id)." 'INFO'
            Write-Log "The ROM is installed at $RomDest and will be added to Steam automatically in Desktop Mode." 'INFO'
            Write-Log "To do it now: switch to Desktop Mode, or run 'dlrom --sync-steam'." 'INFO'
            return
        }
    }

    Write-Log "Syncing $InstalledCount new ROM(s) to Steam..." 'INFO'
    $wrapper = Find-SrmWrapper -Configured (Get-CfgValue 'srmWrapperCmd' '')
    if ($wrapper) {
        Write-Log "Using srm-wrapper: $wrapper" 'DEBUG'
        $wrapperArgs = @('--rom-dir', $RomDest, '--restart-steam', ((Get-CfgValue 'srmRestartSteam' 'auto').ToString()))
        $srmExeCfg = (Get-CfgValue 'srmExe' '')
        if ($srmExeCfg) { $wrapperArgs += @('--srm', $srmExeCfg) }
        try {
            & $wrapper @wrapperArgs
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                Write-Log "Steam sync handled by srm-wrapper." 'SUCCESS'
                return
            }
            Write-Log "srm-wrapper exited with code $code; falling back to built-in SRM logic." 'WARN'
        } catch {
            Write-Log "srm-wrapper failed: $($_.Exception.Message); falling back to built-in SRM logic." 'WARN'
        }
    }
    Invoke-SteamRomManager -RomDest $RomDest -RomsBase $RomsBase
}
