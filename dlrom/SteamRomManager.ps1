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
# The Windows build is a portable app: userData sits next to the exe. The Linux build is an
# Electron AppImage, which cannot write inside its own read-only image and so uses the
# standard Electron location instead - ~/.config/steam-rom-manager/userData. Looking beside
# the AppImage there finds nothing, and the parser-enable step silently does nothing.
function Get-SrmUserDataDir {
    param([string]$SrmExe)
    if (-not (Test-DlWindows)) {
        $electron = Join-DlPath (Get-DlRoamingRoot) 'steam-rom-manager' 'userData'
        if (Test-Path $electron) { return $electron }
    }
    return Join-Path (Split-Path -Parent $SrmExe) "userData"
}

# SRM's userSettings.json, or $null. One reader: both callers below want a different key
# out of the same file, and each used to open, parse and swallow errors on its own.
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
        if (Test-Path $candidate) { return $candidate }
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

# Compare two paths as strings across platforms: SRM stores its parser folders with '${/}'
# placeholders and mixed separators, so both sides are folded to '/' before matching.
function ConvertTo-ComparablePath {
    param([string]$Path)
    return ([string]$Path -replace '\\', '/').TrimEnd('/')
}

# Returns parserIds of *disabled* SRM parsers whose romDirectory resolves to $RomDest.
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
    $ids = @()
    foreach ($p in $parsers) {
        if (-not $p.romDirectory) { continue }
        $dir = $p.romDirectory
        $dir = $dir.Replace('${romsdirglobal}', $romsDir)
        $dir = $dir.Replace('${/}', '/')
        if ((ConvertTo-ComparablePath $dir) -ieq $targetNorm -and $p.disabled -eq $true) {
            $ids += $p.parserId
        }
    }
    return @($ids)
}

function Invoke-Srm {
    param([string]$SrmExe, [string[]]$SrmArgs)
    $workDir = Split-Path -Parent $SrmExe
    $proc = Start-Process -FilePath $SrmExe -ArgumentList $SrmArgs -WorkingDirectory $workDir `
        -WindowStyle Hidden -Wait -PassThru
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
            Start-Process -FilePath $steamExe -ArgumentList '-shutdown' -WindowStyle Hidden | Out-Null
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
            Start-Process -FilePath $steamExe | Out-Null
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
# safe moment to touch Steam. Without it the drain would re-queue everything it just picked up.
function Sync-RomToSteam {
    param([string]$RomDest, [string]$RomsBase, [int]$InstalledCount, [switch]$AlreadyDeferred)

    # Game Mode gate. The download is already on disk and staying there; only the Steam
    # step waits. See SteamDeferred.ps1 for why this cannot simply run anyway.
    if (-not $AlreadyDeferred -and (Test-DlGameMode) -and [bool](Get-CfgValue 'srmDeferInGameMode' $true)) {
        $id = Add-SrmDeferredJob -RomDest $RomDest -RomsBase $RomsBase -InstalledCount $InstalledCount
        Write-Log "Game Mode detected - Steam sync deferred (queue id $id)." 'INFO'
        Write-Log "The ROM is installed at $RomDest and will be added to Steam automatically in Desktop Mode." 'INFO'
        Write-Log "To do it now: switch to Desktop Mode, or run 'dlrom --sync-steam'." 'INFO'
        return
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
