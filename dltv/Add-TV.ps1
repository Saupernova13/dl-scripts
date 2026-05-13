# dltv.ps1
# Search TV shows and add torrents to qBittorrent
# Configuration sourced from %LOCALAPPDATA%\dlScripts\config.json

param(
    [Parameter(Mandatory=$true)]
    [string]$Query,

    [Parameter(Mandatory=$false)]
    [string]$Destination = "",

    [Parameter(Mandatory=$false)]
    [string]$QbitHost = "",

    [Parameter(Mandatory=$false)]
    [int]$MaxResults = 0,

    [Parameter(Mandatory=$false)]
    [switch]$Interactive = $false,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false
)

# Shared resolver library: Initialize-DlConfig, Resolve-MediaPath, Get-DriveMetaInventory.
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\DriveResolver.ps1")

$cfg = Initialize-DlConfig -Section "tv" -Defaults ([PSCustomObject]@{
    qbitHost         = "http://localhost:8080"
    destination      = (Join-Path $HOME "TV")
    maxResults       = 50
    useDriveMetadata = $true
})

# Apply config defaults if not specified
if (-not $QbitHost)    { $QbitHost    = $cfg.qbitHost }
if ($MaxResults -eq 0) { $MaxResults  = $cfg.maxResults }

# Resolve destination:
#   -Destination CLI > drive-meta resolver (when useDriveMetadata) > cfg.destination > $HOME fallback.
if ($Destination) {
    $destRoot = [System.IO.Path]::GetPathRoot($Destination)
    if ($destRoot -and -not (Test-Path $destRoot)) {
        Write-Error "Destination drive '$destRoot' is not connected. Refusing to send torrent to a dead drive."
        exit 1
    }
} elseif ($cfg.useDriveMetadata) {
    $Destination = Resolve-MediaPath -MediaType 'tv'
} else {
    $Destination = $cfg.destination
}

# Ensure destination directory exists (skip side effects in DryRun)
if (-not (Test-Path $Destination)) {
    if ($DryRun) {
        Write-Host "[DRY RUN] Destination would be created: $Destination" -ForegroundColor Gray
    } else {
        try {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        } catch {
            Write-Error "Cannot create destination directory: $Destination"
            exit 1
        }
    }
}

Add-Type -AssemblyName System.Web

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "DEBUG"   { "Gray" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

$blockedExtensions = @(
    '\.exe\b', '\.msi\b', '\.bat\b', '\.cmd\b', '\.ps1\b', '\.vbs\b',
    '\.js\b',  '\.jar\b', '\.py\b',  '\.sh\b',  '\.dll\b', '\.scr\b',
    '\.pif\b', '\.hta\b', '\.wsf\b', '\.com\b',
    '\.rar\b', '\.zip\b', '\.7z\b',  '\.tar\b', '\.gz\b',
    '\.bz2\b', '\.xz\b',  '\.zst\b', '\.cab\b'
)

$nonTvPatterns = @(
    '\bPC[\s\-]?Game\b', '\bXbox\b', '\bPlayStation\b', '\bPS[2345]\b',
    '\bNintendo\b', '\bNSW\b', '\bSteam\b', '\bGOG\b', '\bCODEX\b',
    '\bFitGirl\b', '\bElamigos\b', '\bEMPRESS\b', '\bDARKSIDERS\b',
    '\bSKIDROW\b', '\bRELOADED\b', '\bRG[\s\-]Mechanics\b',
    '\bPortable\b', '\bKeygen\b', '\bActivator\b', '\bCracked\b',
    '\bNulled\b', '\bSerial[\s\-]?Key\b', '\bLicense[\s\-]?Key\b',
    '\bFull[\s\-]?Version\b', '\bSetup\.\w', '\bInstaller\b',
    '\bv\d+\.\d+\.\d+\b',
    '\bebook\b', '\bepub\b', '\.pdf\b', '\baudiobook\b',
    '\bmobi\b', '\bazw3\b', '\bcomic\b', '\bManga\b'
)

function Test-IsSafe {
    param([string]$Name)

    foreach ($ext in $blockedExtensions) {
        if ($Name -imatch $ext) {
            Write-Log "REJECTED (blocked extension match '$ext'): $($Name.Substring(0, [Math]::Min(80, $Name.Length)))" "WARN"
            return $false
        }
    }

    foreach ($pattern in $nonTvPatterns) {
        if ($Name -imatch $pattern) {
            Write-Log "REJECTED (non-TV pattern '$pattern'): $($Name.Substring(0, [Math]::Min(80, $Name.Length)))" "WARN"
            return $false
        }
    }

    return $true
}

function Get-TorrentScore {
    param([string]$Name, [int]$Seeders)

    $score = $Seeders

    $hasEpisode = $Name -imatch 'S\d{2}E\d{2}'
    $hasSeason  = $Name -imatch '(S\d{2}|Season[\s\.\-]+\d+)'

    if ($Name -imatch '(Complete[\s\.\-]+Series|Complete[\s\.\-]+Collection|All[\s\.\-]+Seasons|Seasons?[\s\.\-]+\d+[\s\-]+\d+)') {
        $score += 2000
    }
    elseif ($Name -imatch '(Complete[\s\.\-]+Season|Season[\s\.\-]+\d+[\s\.\-]+Complete|S\d{2}[\s\.\-]+Complete)') {
        $score += 1800
    }
    elseif ($hasSeason -and -not $hasEpisode) {
        $score += 1500
    }
    elseif ($hasEpisode) {
        $score -= 800
    }

    if ($Name -imatch '2160p|4K\b')  { $score += 300 }
    elseif ($Name -imatch '1080p')   { $score += 200 }
    elseif ($Name -imatch '720p')    { $score += 100 }

    if ($Name -imatch 'BluRay|Blu[\s\-]Ray|BDRip')              { $score += 150 }
    elseif ($Name -imatch 'WEB[\s\-]?DL')                       { $score += 120 }
    elseif ($Name -imatch 'WEBRip|AMZN|DSNP|NF\b|HULU|HBO\b')  { $score += 80  }

    return $score
}

$trackers = @(
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.tracker.cl:1337/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://open.stealth.si:80/announce"
)
$trackerParams = ($trackers | ForEach-Object { "&tr=" + [System.Web.HttpUtility]::UrlEncode($_) }) -join ""

$encodedQuery = [System.Web.HttpUtility]::UrlEncode($Query)
$apiUrl = "https://apibay.org/q.php?q=$encodedQuery&cat=200"

Write-Log "Starting TV show download process" "INFO"
Write-Log "Search query: $Query" "INFO"
Write-Log "Destination: $Destination" "INFO"
Write-Log "API: $apiUrl" "DEBUG"

try {
    Write-Log "Fetching results from The Pirate Bay API..." "INFO"

    $json = curl.exe -s $apiUrl
    if ($LASTEXITCODE -ne 0 -or -not $json) {
        throw "curl.exe failed with exit code $LASTEXITCODE"
    }

    $results = $json | ConvertFrom-Json
    Write-Log "API returned $($results.Count) results" "DEBUG"

    if ($results.Count -eq 1 -and $results[0].id -eq "0") {
        Write-Log "No results found for: $Query" "ERROR"
        exit 1
    }

    $allTorrents = @()

    foreach ($item in $results) {
        $torrentName = $item.name
        if (-not $torrentName -or $torrentName.Trim().Length -lt 3) { continue }

        if (-not (Test-IsSafe -Name $torrentName)) { continue }

        $seeders = [int]$item.seeders
        $sizeBytes = [long]$item.size
        $sizeStr = if ($sizeBytes -ge 1GB) { "{0:N2} GB" -f ($sizeBytes / 1GB) }
                   elseif ($sizeBytes -ge 1MB) { "{0:N0} MB" -f ($sizeBytes / 1MB) }
                   else { "$sizeBytes B" }

        $magnetLink = "magnet:?xt=urn:btih:$($item.info_hash)&dn=$([System.Web.HttpUtility]::UrlEncode($torrentName))$trackerParams"

        $score = Get-TorrentScore -Name $torrentName -Seeders $seeders

        $isCompleteSeries = $torrentName -imatch '(Complete[\s\.\-]+Series|Complete[\s\.\-]+Collection|All[\s\.\-]+Seasons)'
        $isSeasonPack     = (-not $isCompleteSeries) -and
                            ($torrentName -imatch '(S\d{2}|Season[\s\.\-]+\d+)') -and
                            ($torrentName -inotmatch 'S\d{2}E\d{2}')
        $isSingleEpisode  = $torrentName -imatch 'S\d{2}E\d{2}'

        $allTorrents += [PSCustomObject]@{
            Name             = $torrentName
            MagnetLink       = $magnetLink
            Size             = $sizeStr
            Seeders          = $seeders
            Score            = $score
            IsCompleteSeries = $isCompleteSeries
            IsSeasonPack     = $isSeasonPack
            IsSingleEpisode  = $isSingleEpisode
        }
    }

    if ($allTorrents.Count -eq 0) {
        Write-Log "No valid TV show torrents found for: $Query" "ERROR"
        Write-Log "All results were blocked by safety filters, or the site returned no results." "WARN"
        exit 1
    }

    Write-Log "Found $($allTorrents.Count) valid torrents after safety filtering" "SUCCESS"

    $torrents = $allTorrents | Sort-Object Score -Descending | Select-Object -First $MaxResults

    Write-Host ""
    for ($i = 0; $i -lt $torrents.Count; $i++) {
        $t = $torrents[$i]
        Write-Host "[$($i+1)] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($t.Name)" -ForegroundColor White

        $tags = @()
        if ($t.IsCompleteSeries) { $tags += "COMPLETE SERIES" }
        elseif ($t.IsSeasonPack) { $tags += "SEASON PACK" }
        elseif ($t.IsSingleEpisode) { $tags += "SINGLE EPISODE" }
        $tagStr = if ($tags.Count -gt 0) { " [" + ($tags -join ", ") + "]" } else { "" }

        Write-Host "    Size: $($t.Size) | Seeds: $($t.Seeders) | Score: $($t.Score)$tagStr" -ForegroundColor Cyan
        Write-Host ""
    }

    $selectedIndex = 0
    if ($Interactive -and $torrents.Count -gt 1) {
        Write-Host "Select torrent [1-$($torrents.Count)] or 0 to cancel: " -NoNewline -ForegroundColor Cyan
        $selection = Read-Host
        $selectedIndex = [int]$selection - 1
        if ($selectedIndex -lt 0 -or $selectedIndex -ge $torrents.Count) {
            Write-Log "Cancelled" "WARN"
            exit 0
        }
        Write-Log "User selected #$($selectedIndex + 1)" "INFO"
    } else {
        Write-Log "Auto-selecting top-scored torrent" "INFO"
    }

    $selected = $torrents[$selectedIndex]

    Write-Log "Selected: $($selected.Name)" "SUCCESS"
    Write-Log "  Size:            $($selected.Size)" "DEBUG"
    Write-Log "  Seeders:         $($selected.Seeders)" "DEBUG"
    Write-Log "  Score:           $($selected.Score)" "DEBUG"
    Write-Log "  Complete Series: $($selected.IsCompleteSeries)" "DEBUG"
    Write-Log "  Season Pack:     $($selected.IsSeasonPack)" "DEBUG"
    Write-Log "  Single Episode:  $($selected.IsSingleEpisode)" "DEBUG"
    Write-Host ""

    if ($DryRun) {
        $magnetPreview = $selected.MagnetLink.Substring(0, [Math]::Min(120, $selected.MagnetLink.Length))
        Write-Log "[DRY RUN] Would POST to $QbitHost/api/v2/torrents/add" "INFO"
        Write-Log "[DRY RUN]   savepath: $Destination" "INFO"
        Write-Log "[DRY RUN]   magnet:   $magnetPreview..." "INFO"
        Write-Log "Dry run complete - no torrent submitted." "SUCCESS"
        return ($selected | ConvertTo-Json)
    }

    Write-Log "Adding to qBittorrent at $QbitHost..." "INFO"

    $body = @{
        urls     = $selected.MagnetLink
        savepath = $Destination
    }

    $addResponse = Invoke-WebRequest -Uri "$QbitHost/api/v2/torrents/add" -Method POST -Body $body -UseBasicParsing

    if ($addResponse.StatusCode -eq 200) {
        Write-Log "Successfully added to qBittorrent!" "SUCCESS"
        Write-Log "  Show:        $($selected.Name)" "INFO"
        Write-Log "  Size:        $($selected.Size)" "INFO"
        Write-Log "  Destination: $Destination" "INFO"
        Write-Host ""
        Write-Log "Process completed successfully" "SUCCESS"
        return ($selected | ConvertTo-Json)
    } else {
        Write-Log "Failed to add to qBittorrent (Status: $($addResponse.StatusCode))" "ERROR"
        exit 1
    }

} catch {
    Write-Log "Exception: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
    exit 1
}
