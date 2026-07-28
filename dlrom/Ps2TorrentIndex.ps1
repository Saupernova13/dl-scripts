# Ps2TorrentIndex.ps1
# The PS2 torrent fallback for dlrom: when RetroGameTalk and the direct downloaders
# can't produce a PS2 ROM, look the game up in the local Redump PS2 archive
# torrent's index and fetch just that one file via qBittorrent's selective
# download, then hand it to dlrom's normal extract/file/Steam pipeline.
#
# Matching is auto-pick with heuristics (the user's chosen behaviour):
#   - all query words (numbers included) must appear in the title;
#   - demos/betas/prototypes are always rejected;
#   - edition/variant releases (FES, Undub, Director's Cut, GOTY, ...) are
#     rejected unless the query names them, so "Persona 3" never picks "Persona 3
#     FES";
#   - budget reprints (Greatest Hits, Platinum, ...) are allowed but deprioritised;
#   - region preference is: the requested --region first, then USA, World, Europe,
#     Japan, Korea; and the closest-to-base title wins ties.
#   - if nothing matches, it refuses and lists near-misses rather than guessing.
#
# Depends on helpers already dot-sourced by Add-ROM.ps1: Resolve-MediaPath
# (DriveResolver), Install-RomFromDownload (RomFiles), Sync-RomToSteam (SteamRomManager),
# and the qBittorrent client (QbitTorrent.ps1). Write-Log/Format-* from Logging;
# release-marker tables, region ranking and Get-CfgValue from Constants/Common.

$script:PS2_ROMAN = @{ 'i'='1'; 'ii'='2'; 'iii'='3'; 'iv'='4'; 'v'='5'; 'vi'='6'; 'vii'='7'; 'viii'='8'; 'ix'='9'; 'x'='10' }
$script:PS2_STOP  = @('the','of','a','an','and','to','in','for','vs','de','la')
# Redump entries are always one of the container formats, never a bare ROM.
$script:PS2_ARCHIVE_RX = '\.(' + ($script:DOWNLOAD_EXTS -join '|') + ')$'

function ConvertTo-Ps2Norm { param([string]$Text) return (($Text -replace '[^A-Za-z0-9]+',' ').Trim().ToLower()) }

function Get-Ps2Tokens {
    param([string]$Text)
    $out = @()
    foreach ($t in ((ConvertTo-Ps2Norm $Text) -split '\s+')) {
        if (-not $t) { continue }
        if ($script:PS2_ROMAN.ContainsKey($t)) { $out += $script:PS2_ROMAN[$t] } else { $out += $t }
    }
    return $out
}

function Get-Ps2Significant {
    param([string]$Text)
    return @(Get-Ps2Tokens $Text | Where-Object { $script:PS2_STOP -notcontains $_ } | Select-Object -Unique)
}

# Region codes present in a Redump filename's parentheticals.
function Get-Ps2Regions {
    param([string]$FileName)
    $regions = @()
    foreach ($m in [regex]::Matches($FileName, '\(([^)]*)\)')) {
        $g = $m.Groups[1].Value.ToLower()
        if ($g -match '\b(usa|america)\b')                                             { $regions += 'usa' }
        if ($g -match '\b(europe|europa|pal|uk|england|germany|france|spain|italy|netherlands|sweden|australia)\b') { $regions += 'europe' }
        if ($g -match '\bjapan\b')                                                     { $regions += 'japan' }
        if ($g -match '\bkorea\b')                                                     { $regions += 'korea' }
        if ($g -match '\bworld\b')                                                     { $regions += 'world' }
        if ($g -match '\basia\b')                                                      { $regions += 'asia' }
    }
    return @($regions | Select-Object -Unique)
}

# Score/qualify one index entry against the query. Returns $null (reject) or a
# ranking record. Lower sort keys are better.
function Get-Ps2Candidate {
    param($File, [string[]]$QueryTokens, [string]$NormQuery, [string]$Requested)

    $path = [string]$File.path
    if ($path -notmatch '(?i)/Sony - PlayStation 2/') { return $null }
    if ($path -notmatch $script:PS2_ARCHIVE_RX)       { return $null }

    $fileName  = Split-Path $path -Leaf
    if ($fileName -match $script:DEMO_RX) { return $null }

    $titlePart = ($fileName -replace $script:PS2_ARCHIVE_RX, '')
    $titlePart = ($titlePart -replace '\s*\(.*$', '')          # drop region/disc/flag parentheticals
    $normTitle = ConvertTo-Ps2Norm $titlePart
    $titleToks = Get-Ps2Significant $titlePart

    # Gate: every query word (numbers too) must be present in the title.
    foreach ($qt in $QueryTokens) { if ($titleToks -notcontains $qt) { return $null } }

    # Edition rule: reject unrequested edition/variant markers.
    foreach ($kw in $script:EDITION_KW) {
        if ((Test-Phrase $normTitle $kw) -and -not (Test-Phrase $NormQuery $kw)) { return $null }
    }

    $budgetPenalty = 0
    foreach ($kw in $script:BUDGET_KW) {
        if ((Test-Phrase $normTitle $kw) -and -not (Test-Phrase $NormQuery $kw)) { $budgetPenalty = 1; break }
    }

    $regions   = Get-Ps2Regions $fileName
    $regionRnk = Get-RegionRank -Regions $regions -Requested $Requested
    $extra     = @($titleToks | Where-Object { $QueryTokens -notcontains $_ }).Count
    $disc      = 1
    $dm = [regex]::Match($fileName, '(?i)\(Disc\s*(\d+)\)')
    if ($dm.Success) { $disc = [int]$dm.Groups[1].Value }

    return [PSCustomObject]@{
        File        = $File
        Index       = [int]$File.index
        Path        = $path
        Title       = $titlePart.Trim()
        Regions     = ($regions -join ',')
        RegionRank  = $regionRnk
        Budget      = $budgetPenalty
        Extra       = $extra
        Disc        = $disc
        PathLen     = $path.Length
        Length      = [long]$File.length
    }
}

# Auto-pick the best matching file, or $null. Also returns near-miss candidates for logging.
function Find-Ps2TorrentMatch {
    param($Index, [string]$Query, [string]$Region, [int]$PickIndex = -1)

    $files = @($Index.files)

    if ($PickIndex -ge 0) {
        $hit = $files | Where-Object { [int]$_.index -eq $PickIndex } | Select-Object -First 1
        if (-not $hit) { return @{ File = $null; Reason = "no file with index $PickIndex in the torrent" } }
        return @{ File = $hit; Reason = 'explicit --torrent-pick'; Chosen = $null; Candidates = @() }
    }

    $qtokens = Get-Ps2Significant $Query
    if ($qtokens.Count -eq 0) { return @{ File = $null; Reason = 'query has no usable words' } }
    $normQuery = ConvertTo-Ps2Norm $Query
    $requested = Resolve-RegionRequest $Region

    $cands = @()
    foreach ($f in $files) {
        $c = Get-Ps2Candidate -File $f -QueryTokens $qtokens -NormQuery $normQuery -Requested $requested
        if ($c) { $cands += $c }
    }

    if ($cands.Count -eq 0) {
        return @{ File = $null; Reason = "no PS2 title in the archive matches '$Query'"; Candidates = @() }
    }

    $ranked = $cands | Sort-Object RegionRank, Budget, Extra, Disc, PathLen
    $best   = $ranked[0]

    # Warn (do not fail) when the chosen game is multi-disc: selective download
    # grabs one disc at a time; the user can re-run with --torrent-pick for others.
    $sameTitleDiscs = @($ranked | Where-Object { $_.Title -eq $best.Title -and $_.Regions -eq $best.Regions })
    return @{
        File       = $best.File
        Chosen     = $best
        Reason     = 'auto-pick'
        Candidates = @($ranked | Select-Object -First 6)
        DiscCount  = $sameTitleDiscs.Count
    }
}

# ---- index build / load ------------------------------------------------------

function Get-Ps2TorrentPath {
    param($Cfg)
    $cfgPath = [string](Get-CfgValue 'ps2TorrentPath' '' -Cfg $Cfg)
    if ($cfgPath -and (Test-Path $cfgPath)) { return $cfgPath }
    $repoCopy = Join-DlPath $PSScriptRoot 'data' 'ps2-torrent'
    if (Test-Path $repoCopy) {
        $t = Get-ChildItem $repoCopy -Filter '*.torrent' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($t) { return $t.FullName }
    }
    $dl = Get-ChildItem (Get-DlDownloadsDir) -Filter '*PlayStation 2*.torrent' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dl) { return $dl.FullName }
    return ''
}

function Get-Ps2IndexPath {
    param($Cfg)
    $cfgIdx = [string](Get-CfgValue 'ps2TorrentIndexPath' '' -Cfg $Cfg)
    if ($cfgIdx) { return $cfgIdx }
    return (Join-DlPath $PSScriptRoot 'data' 'ps2-torrent' 'ps2-index.json')
}

# Locate a Python 3 interpreter for ps2_torrent.py. Returns @{ Exe; Pre } so callers can
# splat the prefix args that the `py` launcher needs and `python` does not.
$script:PS2_PY = $null

function Resolve-PythonExe {
    if ($script:PS2_PY) { return $script:PS2_PY }
    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $script:PS2_PY = @{ Exe = $cmd.Source; Pre = @() }; return $script:PS2_PY }
    }
    $py = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($py) { $script:PS2_PY = @{ Exe = $py.Source; Pre = @('-3') }; return $script:PS2_PY }
    return $null
}

# Ensure the JSON index exists and is current. Builds it from the .torrent via
# ps2_torrent.py when possible; otherwise uses whatever committed index is present.
function Update-Ps2TorrentIndex {
    param([string]$TorrentPath, [string]$IndexPath)
    $py = Resolve-PythonExe
    if (-not $py) {
        if (Test-Path $IndexPath) { Write-Log "Python not found; using existing index." 'DEBUG'; return $true }
        Write-Log "Python 3 is required to build the PS2 torrent index and was not found." 'ERROR'
        return $false
    }
    if (-not (Test-Path $TorrentPath)) {
        if (Test-Path $IndexPath) { Write-Log "Torrent file not found; using existing index." 'WARN'; return $true }
        Write-Log "PS2 archive .torrent not found (set [rom].ps2TorrentPath)." 'ERROR'
        return $false
    }
    $script = Join-Path $PSScriptRoot 'ps2_torrent.py'
    & $py.Exe @($py.Pre + @($script, 'build', '--torrent', $TorrentPath, '--out', $IndexPath)) 2>$null 1>$null
    if ($LASTEXITCODE -ne 0 -and -not (Test-Path $IndexPath)) {
        Write-Log "Failed to build the PS2 torrent index." 'ERROR'
        return $false
    }
    return (Test-Path $IndexPath)
}

function Import-Ps2Index {
    param([string]$IndexPath)
    return (Get-Content $IndexPath -Raw | ConvertFrom-Json)
}

# ---- destination (mirrors Add-ROM's priority, but never prompts) -------------

function Resolve-Ps2RomDest {
    param([string]$Destination, $Cfg)
    $base = $null
    if ($Destination) {
        $base = $Destination
    } elseif ((Get-CfgValue 'romsBase' '' -Cfg $Cfg) -and (Test-Path (Get-CfgValue 'romsBase' '' -Cfg $Cfg))) {
        $base = Get-CfgValue 'romsBase' '' -Cfg $Cfg
    } else {
        try { $base = Resolve-MediaPath -MediaType 'rom' -Strict } catch { $base = $null }
        if (-not $base) { $base = Get-CfgValue 'romsBase' (Join-DlPath (Get-DlHomeDir) 'Emulation' 'roms') -Cfg $Cfg }
    }
    $dest = Join-Path $base 'ps2'
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    return [PSCustomObject]@{ Base = $base; Dest = $dest }
}

# ---- orchestrator ------------------------------------------------------------

# Returns $true if a ROM was installed via the torrent fallback, else $false.
function Invoke-Ps2TorrentFallback {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Region = '',
        [string]$Destination = '',
        [Parameter(Mandatory)]$Cfg,
        [switch]$NoExtract,
        [switch]$NoSteam,
        [int]$PickIndex = -1,
        [string]$Reason = '',
        # Optional: when a background worker owns this run, progress and the final result
        # are stamped onto its job. Absent (a --wait run), this behaves exactly as before.
        [PSCustomObject]$Job = $null
    )

    Write-Log "PS2 torrent fallback engaged ($Reason)." 'INFO'

    $torrentPath = Get-Ps2TorrentPath -Cfg $Cfg
    $indexPath   = Get-Ps2IndexPath   -Cfg $Cfg
    if (-not (Update-Ps2TorrentIndex -TorrentPath $torrentPath -IndexPath $indexPath)) { return $false }

    $index = Import-Ps2Index -IndexPath $indexPath
    Write-Log "PS2 archive index: $(@($index.files).Count) files (infohash $($index.infohash_v1))." 'DEBUG'

    $match = Find-Ps2TorrentMatch -Index $index -Query $Query -Region $Region -PickIndex $PickIndex
    if (-not $match.File) {
        Write-Log "No confident torrent match: $($match.Reason)." 'WARN'
        if ($match.Candidates -and $match.Candidates.Count -gt 0) {
            Write-Log "Closest titles:" 'INFO'
            foreach ($c in $match.Candidates) { Write-Host ("    [{0}] {1}  ({2})" -f $c.Index, $c.Title, $c.Regions) }
            Write-Log "Re-run with --torrent-pick <index> to force one." 'INFO'
        }
        return $false
    }

    $chosen = $match.Chosen
    if ($chosen) {
        Write-Log ("Torrent match: [{0}] {1} ({2}) {3}" -f $chosen.Index, $chosen.Title, $chosen.Regions, (Format-Bytes $chosen.Length)) 'SUCCESS'
        if ($match.DiscCount -gt 1) {
            Write-Log "This title has $($match.DiscCount) discs; fetching the first. Use --torrent-pick for the others." 'WARN'
        }
    } else {
        Write-Log "Torrent file selected by --torrent-pick: $($match.File.path)" 'INFO'
    }

    # qBittorrent must be reachable; we don't launch it (avoids popping a window).
    $qbase = Resolve-QbitBase -CfgHost ([string](Get-CfgValue 'qbitHost' '' -Cfg $Cfg))
    $quser = [string](Get-CfgValue 'qbitUser' '' -Cfg $Cfg)
    $qpass = [string](Get-CfgValue 'qbitPass' '' -Cfg $Cfg)
    Initialize-Qbit -Base $qbase -User $quser -Pass $qpass
    if (-not (Test-QbitRunning)) {
        Write-Log "qBittorrent WebUI not reachable at $qbase - start qBittorrent (or set [rom].qbitHost)." 'ERROR'
        return $false
    }

    $destInfo = Resolve-Ps2RomDest -Destination $Destination -Cfg $Cfg
    $romDest  = $destInfo.Dest
    $staging = [string](Get-CfgValue 'ps2TorrentStaging' (Join-Path $destInfo.Base '.dlrom-torrent') -Cfg $Cfg)
    if (-not (Test-Path $staging)) { New-Item -ItemType Directory -Path $staging -Force | Out-Null }

    $timeout = [int](Get-CfgValue 'ps2TorrentTimeoutSec' 14400 -Cfg $Cfg)

    Write-Log "Downloading via qBittorrent to $staging ..." 'INFO'
    $downloaded = $null
    try {
        $downloaded = Invoke-QbitSelectiveDownload `
            -TorrentPath $torrentPath -SavePath $staging `
            -FilePathInTorrent ([string]$match.File.path) -FileIndex ([int]$match.File.index) `
            -InfoHash ([string]$index.infohash_v1) -TimeoutSec $timeout
    } catch {
        Write-Log "qBittorrent download failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
    if (-not $downloaded -or -not (Test-Path $downloaded)) {
        Write-Log "Download did not produce a file." 'ERROR'
        return $false
    }
    Write-Log "Downloaded: $downloaded" 'SUCCESS'

    # Same extract/find/file/cleanup decision tree as a web download, so it is the same
    # function. This used to be a second copy that had already drifted: it never warned
    # about an unrecognised raw extension, and its cleanup ran on a different condition.
    $installedRomPath = $null
    try {
        $installedRomPath = Install-RomFromDownload -DownloadedPath $downloaded -RomDest $romDest `
                                -WorkDir $staging -NoExtract:$NoExtract
    } catch {
        Write-Log "Install from torrent download failed: $($_.Exception.Message)" 'ERROR'
    } finally {
        # qBittorrent recreates the torrent's root folder under staging; drop it once the
        # single file we asked for has been consumed.
        if (-not $NoExtract) { Remove-EmptyDirectory -Path $staging -Recurse }
    }

    if (-not $installedRomPath) { return $false }

    if (-not $NoSteam -and [bool](Get-CfgValue 'steamSync' $true -Cfg $Cfg)) {
        try { Sync-RomToSteam -RomDest $romDest -RomsBase $destInfo.Base -InstalledCount 1 }
        catch { Write-Log "Steam sync failed (ROM still installed): $($_.Exception.Message)" 'WARN' }
    }

    # Report the exact version installed + the matching dlps2tex command (same
    # serial), so an agent can chain the texture download for this version.
    $resultTitle  = if ($chosen) { $chosen.Title } else { [System.IO.Path]::GetFileNameWithoutExtension([string]$match.File.path) }
    $resultRegion = if ($chosen -and $chosen.Regions) { @($chosen.Regions -split ',')[0] } elseif ($Region) { $Region } else { '' }
    # Capture, never let this fall through as output: Write-DlromResult returns the
    # [HANDOFF] line, and an uncaptured string here would ride out on this function's
    # return value alongside the $true and break the caller's boolean test.
    $handoff = Write-DlromResult -Title $resultTitle -Platform 'ps2' -Region $resultRegion `
        -Source 'torrent' -InstalledPath $installedRomPath -Cfg $Cfg

    # Mirror the outcome onto the job so --status can answer without reading the log.
    if ($Job) {
        $Job.title = $resultTitle
        $Job.region = $resultRegion
        $Job.installedPaths += $installedRomPath
        if ($handoff) { $Job.handoff = $handoff }
    }
    return $true
}
