# Filing a finished torrent's content into a console's ROM folder.
#
# Torrents arrive in every shape (a Switch folder, a lone .iso, an extracted PS3 game dir), so
# what to do with one is data: TORRENT_INSTALL_RULES (Constants.ps1) maps the job's console
# folder to a rule, the rule names a strategy, and TORRENT_INSTALL_STRATEGIES below maps that
# name to its function. A new console is a table row; a new layout is one function and one entry.
#
# Strategies are pure filesystem: no jobs, no qBittorrent. Each takes
#   -ContentPath -RomDest -Title -Rule -Mode (move|copy) -WorkDir [-OnStep]
# and returns @{ Installed = @(paths); ManualNote; SteamSync; Reason }. Nothing installed means
# Reason says why and the downloaded data is untouched.
#
# Mode 'move' renames (staging is on the ROM drive); 'copy' is for a torrent the user already
# had, whose files must stay where they are. Extracted files live in WorkDir and are always moved.
# Except the generic strategy (it reuses the web pipeline's filing, which replaces a same-named
# ROM), nothing here overwrites: a taken destination gets " (2)", " (3)", ...

$script:TORRENT_INSTALL_STRATEGIES = @{
    folder    = 'Install-TorrentFolder'
    files     = 'Install-TorrentFiles'
    gamedir   = 'Install-TorrentGameDir'
    container = 'Install-TorrentContainer'
    rpxdir    = 'Install-TorrentRpxDir'
    manual    = 'Install-TorrentManual'
    generic   = 'Install-TorrentGeneric'
}

function Get-TorrentInstallRule {
    param([string]$Folder)
    $key = ([string]$Folder).ToLower()
    if ($script:TORRENT_INSTALL_RULES.ContainsKey($key)) { return $script:TORRENT_INSTALL_RULES[$key] }
    return $script:TORRENT_INSTALL_DEFAULT
}

function New-TorrentInstallResult {
    param([string[]]$Installed = @(), $ManualNote = $null, [bool]$SteamSync = $true, [string]$Reason = $null)
    return @{ Installed = @($Installed); ManualNote = $ManualNote; SteamSync = $SteamSync; Reason = $Reason }
}

function New-TorrentFailure {
    param([string]$Reason)
    return (New-TorrentInstallResult -SteamSync $false -Reason $Reason)
}

# The folder/file name a title files under. Falls back to the content's own name.
function Get-TorrentTitleName {
    param([string]$Title, [string]$ContentPath)
    $name = Get-SafeRomName $Title
    if (-not $name) { $name = Get-SafeRomName ([System.IO.Path]::GetFileNameWithoutExtension($ContentPath)) }
    if (-not $name) { $name = 'torrent' }
    return $name
}

# <Dir>\<Name><Suffix>, or the first free "<Name> (n)<Suffix>" when that is taken.
function Get-TorrentFreePath {
    param([string]$Dir, [string]$Name, [string]$Suffix = '')
    $path = Join-Path $Dir "$Name$Suffix"
    $n = 2
    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Dir "$Name ($n)$Suffix"
        $n++
    }
    return $path
}

# Place a file or folder at a free path under Dir and return where it landed.
function Move-TorrentItem {
    param([string]$Source, [string]$Dir, [string]$Name, [string]$Suffix = '', [string]$Mode = 'move')
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $dest = Get-TorrentFreePath -Dir $Dir -Name $Name -Suffix $Suffix
    if ($Mode -eq 'copy') { Copy-Item -LiteralPath $Source -Destination $dest -Recurse -ErrorAction Stop }
    else                  { Move-Item -LiteralPath $Source -Destination $dest -ErrorAction Stop }
    if (-not (Test-Path -LiteralPath $dest)) { throw "Did not appear at destination: $dest" }
    Write-Log "Filed: $dest" 'SUCCESS'
    return $dest
}

# File one file flat into Dir under its sanitised name.
function Move-TorrentFile {
    param([string]$Source, [string]$Dir, [string]$Mode = 'move')
    $leaf = Get-SafeRomName ([System.IO.Path]::GetFileName($Source))
    return (Move-TorrentItem -Source $Source -Dir $Dir -Name ([System.IO.Path]::GetFileNameWithoutExtension($leaf)) `
            -Suffix ([System.IO.Path]::GetExtension($leaf)) -Mode $Mode)
}

# Files under Path (or Path itself, when it is a file) whose extension is in Exts; all when Exts is empty.
function Get-TorrentFiles {
    param([string]$Path, [string[]]$Exts = @())
    $items = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Get-Item -LiteralPath $Path -Force) }
             else { @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue) }
    return @($items | Where-Object { -not $Exts -or $Exts.Count -eq 0 -or $Exts -contains $_.Extension.ToLower() } |
            Sort-Object FullName)
}

function Test-TorrentIsDir {
    param([string]$Path)
    return (Test-Path -LiteralPath $Path -PathType Container)
}

# Unpack every archive under Path into WorkDir. Returns @{ Archive; Dir } per archive.
function Expand-TorrentArchives {
    param([string]$Path, [string]$WorkDir, [scriptblock]$OnStep)
    $out = @()
    foreach ($f in @(Get-TorrentFiles -Path $Path | Where-Object { Test-IsArchive $_.FullName })) {
        if ($OnStep) { try { & $OnStep $script:JOB_STEP_EXTRACTING } catch { } }
        $dir = Join-DlPath $WorkDir 'extracted' ('{0}_{1}' -f [System.IO.Path]::GetFileNameWithoutExtension($f.Name), (New-ShortId 8))
        Expand-RomArchive -ArchivePath $f.FullName -OutDir $dir
        $out += @{ Archive = $f.FullName; Dir = $dir }
    }
    return @($out)
}

# A copy of Path inside WorkDir when copying (so the filing code may consume it), else Path.
function Get-TorrentWorkCopy {
    param([string]$Path, [string]$Mode, [string]$WorkDir, [string]$Tag = '0')
    if ($Mode -ne 'copy') { return $Path }
    $dir = Join-DlPath $WorkDir 'copy' $Tag
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $dest = Join-Path $dir ([System.IO.Path]::GetFileName($Path))
    Copy-Item -LiteralPath $Path -Destination $dest -ErrorAction Stop
    return $dest
}

# The shallowest directory under Path (Path included) that has a child directory named Marker.
function Find-TorrentMarkerDir {
    param([string]$Path, [string]$Marker)
    if (-not (Test-TorrentIsDir $Path)) { return $null }
    if (Test-Path -LiteralPath (Join-Path $Path $Marker) -PathType Container) { return $Path }
    $hit = @(Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ieq $Marker } |
             Sort-Object { ($_.FullName -split '[\\/]').Count }, FullName) | Select-Object -First 1
    if ($hit) { return $hit.Parent.FullName }
    return $null
}

# --- Strategies -------------------------------------------------------------------------------

# switch: a folder keeps base game, updates and DLC together; a lone .nsp/.xci is filed flat.
function Install-TorrentFolder {
    param($ContentPath, $RomDest, $Title, $Rule, $Mode, $WorkDir, [scriptblock]$OnStep)
    $exts = @($Rule.Exts)
    if (@(Get-TorrentFiles -Path $ContentPath -Exts $exts).Count -eq 0) {
        return (New-TorrentFailure "No $($exts -join '/') files found in the torrent.")
    }
    if ($OnStep) { try { & $OnStep $script:JOB_STEP_FILING } catch { } }
    $placed = if (Test-TorrentIsDir $ContentPath) {
        Move-TorrentItem -Source $ContentPath -Dir $RomDest -Name (Get-TorrentTitleName $Title $ContentPath) -Mode $Mode
    } else {
        Move-TorrentFile -Source $ContentPath -Dir $RomDest -Mode $Mode
    }
    return (New-TorrentInstallResult -Installed @($placed) -SteamSync ([bool]$Rule.SteamSync))
}

# The note to show when every filed file's extension has one in Rule.ExtNotes.
function Get-TorrentExtNote {
    param($Rule, [string[]]$Paths)
    if (-not $Rule.ExtNotes -or $Paths.Count -eq 0) { return $null }
    $exts = @($Paths | ForEach-Object { [System.IO.Path]::GetExtension($_).ToLower() } | Select-Object -Unique)
    foreach ($e in $exts) { if (-not $Rule.ExtNotes.ContainsKey($e)) { return $null } }
    return [string]$Rule.ExtNotes[$exts[0]]
}

# n3ds / xbox360 / xbox / wiiu: matching files filed flat; archives are unpacked when none match;
# Rule.Then names what to try after that.
function Install-TorrentFiles {
    param($ContentPath, $RomDest, $Title, $Rule, $Mode, $WorkDir, [scriptblock]$OnStep)
    $exts    = @($Rule.Exts)
    $found   = @(Get-TorrentFiles -Path $ContentPath -Exts $exts)
    $unpacked = @()
    if ($found.Count -eq 0) {
        $unpacked = @(Expand-TorrentArchives -Path $ContentPath -WorkDir $WorkDir -OnStep $OnStep)
        foreach ($u in $unpacked) { $found += @(Get-TorrentFiles -Path $u.Dir -Exts $exts) }
    }

    if ($found.Count -eq 0) {
        foreach ($u in $unpacked) { Remove-Item -LiteralPath $u.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        if ($Rule.Then) {
            $next = $script:TORRENT_INSTALL_STRATEGIES[[string]$Rule.Then]
            return (& $next -ContentPath $ContentPath -RomDest $RomDest -Title $Title -Rule $Rule -Mode $Mode -WorkDir $WorkDir -OnStep $OnStep)
        }
        return (New-TorrentFailure "No $($exts -join '/') files found in the torrent.")
    }

    if ($OnStep) { try { & $OnStep $script:JOB_STEP_FILING } catch { } }
    $placed = @()
    foreach ($f in $found) {
        $fromWork = $f.FullName.StartsWith((Join-Path $WorkDir 'extracted'), [System.StringComparison]::OrdinalIgnoreCase)
        $placed += Move-TorrentFile -Source $f.FullName -Dir $RomDest -Mode $(if ($fromWork) { 'move' } else { $Mode })
    }
    foreach ($u in $unpacked) {
        Remove-Item -LiteralPath $u.Dir -Recurse -Force -ErrorAction SilentlyContinue
        # The archive is consumed; a copy-mode source is someone else's file and stays.
        if ($Mode -ne 'copy') { Remove-Item -LiteralPath $u.Archive -Force -ErrorAction SilentlyContinue }
    }
    Remove-EmptyDirectory (Join-Path $WorkDir 'extracted')
    return (New-TorrentInstallResult -Installed $placed -SteamSync ([bool]$Rule.SteamSync) `
            -ManualNote (Get-TorrentExtNote -Rule $Rule -Paths $placed))
}

# xbox360 fallback: a GOD/XBLA container folder goes under <console>\<Rule.Sub>\<Title>.
function Install-TorrentContainer {
    param($ContentPath, $RomDest, $Title, $Rule, $Mode, $WorkDir, [scriptblock]$OnStep)
    if (-not (Test-TorrentIsDir $ContentPath) -or @(Get-TorrentFiles -Path $ContentPath).Count -eq 0) {
        return (New-TorrentFailure 'Nothing installable: no matching file and no content folder in the torrent.')
    }
    if ($OnStep) { try { & $OnStep $script:JOB_STEP_FILING } catch { } }
    $dir    = Join-DlPath $RomDest ([string]$Rule.Sub)
    $placed = Move-TorrentItem -Source $ContentPath -Dir $dir -Name (Get-TorrentTitleName $Title $ContentPath) -Mode $Mode
    return (New-TorrentInstallResult -Installed @($placed) -SteamSync ([bool]$Rule.SteamSync))
}

# wiiu fallback: the game directory is the parent of a `code` folder holding an .rpx.
function Install-TorrentRpxDir {
    param($ContentPath, $RomDest, $Title, $Rule, $Mode, $WorkDir, [scriptblock]$OnStep)
    $rpx = @(Get-TorrentFiles -Path $ContentPath -Exts @('.rpx') |
             Where-Object { $_.Directory.Name -ieq 'code' } |
             Sort-Object { ($_.FullName -split '[\\/]').Count }, FullName) | Select-Object -First 1
    if (-not $rpx) { return (New-TorrentFailure 'Nothing installable: no game file and no code\*.rpx folder in the torrent.') }
    if ($OnStep) { try { & $OnStep $script:JOB_STEP_FILING } catch { } }
    $game   = $rpx.Directory.Parent.FullName
    $placed = Move-TorrentItem -Source $game -Dir $RomDest -Name (Get-TorrentTitleName $Title $ContentPath) -Mode $Mode
    return (New-TorrentInstallResult -Installed @($placed) -SteamSync ([bool]$Rule.SteamSync))
}

# Keep the content as it is under <console>\<Title>\ (a lone file goes flat); the user finishes by hand.
function Install-TorrentManual {
    param($ContentPath, $RomDest, $Title, $Rule, $Mode, $WorkDir, [scriptblock]$OnStep)
    if (@(Get-TorrentFiles -Path $ContentPath).Count -eq 0) { return (New-TorrentFailure 'The torrent holds no files.') }
    if ($OnStep) { try { & $OnStep $script:JOB_STEP_FILING } catch { } }
    $placed = if (Test-TorrentIsDir $ContentPath) {
        Move-TorrentItem -Source $ContentPath -Dir $RomDest -Name (Get-TorrentTitleName $Title $ContentPath) -Mode $Mode
    } else {
        Move-TorrentFile -Source $ContentPath -Dir $RomDest -Mode $Mode
    }
    return (New-TorrentInstallResult -Installed @($placed) -ManualNote $Rule.Note -SteamSync $false)
}

# ps3: the directory holding PS3_GAME becomes <console>\<Title>.ps3. Without one, a .pkg/.iso is kept for hand install.
function Install-TorrentGameDir {
    param($ContentPath, $RomDest, $Title, $Rule, $Mode, $WorkDir, [scriptblock]$OnStep)
    $game = Find-TorrentMarkerDir -Path $ContentPath -Marker ([string]$Rule.Marker)
    if ($game) {
        if ($OnStep) { try { & $OnStep $script:JOB_STEP_FILING } catch { } }
        $placed = Move-TorrentItem -Source $game -Dir $RomDest -Name (Get-TorrentTitleName $Title $ContentPath) `
                    -Suffix ([string]$Rule.Suffix) -Mode $Mode
        return (New-TorrentInstallResult -Installed @($placed) -SteamSync ([bool]$Rule.SteamSync))
    }
    if ($Rule.ManualExts -and @(Get-TorrentFiles -Path $ContentPath -Exts @($Rule.ManualExts)).Count -gt 0) {
        return (Install-TorrentManual -ContentPath $ContentPath -RomDest $RomDest -Title $Title `
                -Rule @{ Note = $Rule.ManualNote } -Mode $Mode -WorkDir $WorkDir -OnStep $OnStep)
    }
    return (New-TorrentFailure "No $($Rule.Marker) folder (and no $(@($Rule.ManualExts) -join '/') file) found in the torrent.")
}

# Install-RomFromDownload on one file, working on a copy when copying.
function Install-TorrentOneFile {
    param([string]$Path, [string]$RomDest, [string]$Mode, [string]$WorkDir, [scriptblock]$OnStep)
    $src = Get-TorrentWorkCopy -Path $Path -Mode $Mode -WorkDir $WorkDir
    return @(Install-RomFromDownload -DownloadedPath $src -RomDest $RomDest -WorkDir $WorkDir -OnStep $OnStep)[-1]
}

# Everything else: a file or lone archive goes through the web pipeline's filing; otherwise a
# .cue with its .bin files, or the largest ROM file.
function Install-TorrentGeneric {
    param($ContentPath, $RomDest, $Title, $Rule, $Mode, $WorkDir, [scriptblock]$OnStep)
    $steam = [bool]$Rule.SteamSync
    $single = $null
    if (-not (Test-TorrentIsDir $ContentPath)) {
        $single = $ContentPath
    } else {
        $archives = @(Get-TorrentFiles -Path $ContentPath | Where-Object { Test-IsArchive $_.FullName })
        if ($archives.Count -eq 1) { $single = $archives[0].FullName }
    }
    if ($single) {
        $placed = Install-TorrentOneFile -Path $single -RomDest $RomDest -Mode $Mode -WorkDir $WorkDir -OnStep $OnStep
        if (-not $placed) { return (New-TorrentFailure 'No ROM file found in the download.') }
        return (New-TorrentInstallResult -Installed @($placed) -SteamSync $steam)
    }

    $roms = @(Get-TorrentFiles -Path $ContentPath -Exts $script:ROM_EXTS)
    if ($roms.Count -eq 0) { return (New-TorrentFailure 'No ROM file found in the torrent.') }
    $cues = @($roms | Where-Object { $_.Extension -ieq '.cue' })
    $pick = if ($cues.Count -gt 0) {
        $dirs = @($cues | ForEach-Object { $_.DirectoryName } | Select-Object -Unique)
        @($cues) + @($roms | Where-Object { $_.Extension -ieq '.bin' -and $dirs -contains $_.DirectoryName })
    } else {
        @($roms | Sort-Object Length -Descending | Select-Object -First 1)
    }

    if ($OnStep) { try { & $OnStep $script:JOB_STEP_FILING } catch { } }
    # Copying: stage every file first, so a .cue and its .bin files sit together when filed.
    $dirIndex = @{}
    $sources  = @()
    foreach ($f in $pick) {
        if ($Mode -ne 'copy') { $sources += $f.FullName; continue }
        if (-not $dirIndex.ContainsKey($f.DirectoryName)) { $dirIndex[$f.DirectoryName] = [string]$dirIndex.Count }
        $sources += Get-TorrentWorkCopy -Path $f.FullName -Mode $Mode -WorkDir $WorkDir -Tag $dirIndex[$f.DirectoryName]
    }
    $placed = @()
    foreach ($src in $sources) {
        # A .bin already moved along with its .cue is gone from here.
        if (Test-Path -LiteralPath $src) { $placed += @(Move-RomToDest -SourcePath $src -DestDir $RomDest)[-1] }
    }
    return (New-TorrentInstallResult -Installed $placed -SteamSync $steam)
}

# --- Entry point ------------------------------------------------------------------------------

# Install ContentPath per the rule for Folder. Never throws: a failure is a result with a Reason.
function Invoke-TorrentInstall {
    param(
        [Parameter(Mandatory)][string]$ContentPath, [Parameter(Mandatory)][string]$RomDest,
        [string]$Title = '', [string]$Folder = '', [string]$Mode = 'move', [string]$WorkDir = '',
        [scriptblock]$OnStep
    )
    if (-not (Test-Path -LiteralPath $ContentPath)) { return (New-TorrentFailure "Downloaded content not found: $ContentPath") }
    $rule = Get-TorrentInstallRule -Folder $Folder
    $fn   = $script:TORRENT_INSTALL_STRATEGIES[[string]$rule.Strategy]
    if (-not $fn) { return (New-TorrentFailure "No install strategy named '$($rule.Strategy)'.") }
    if (-not $WorkDir) { $WorkDir = Join-DlPath ([System.IO.Path]::GetTempPath()) "dlrom-$(New-ShortId 8)" }
    try {
        $r = @(& $fn -ContentPath $ContentPath -RomDest $RomDest -Title $Title -Rule $rule -Mode $Mode -WorkDir $WorkDir -OnStep $OnStep)
        return $r[-1]
    } catch {
        return (New-TorrentFailure "Install failed: $($_.Exception.Message)")
    }
}
