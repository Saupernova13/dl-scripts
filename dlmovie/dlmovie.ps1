# dlmovie.ps1
# Search YTS.bz for movies and add torrents to qBittorrent
# Configuration sourced from %APPDATA%/Local/dlScripts/config.ps1

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
    [switch]$Interactive = $false
)

# Load configuration
$configPath = Join-Path $env:APPDATA "Local\dlScripts\config.ps1"
if (Test-Path $configPath) {
    . $configPath
} else {
    Write-Error "Configuration file not found: $configPath`nPlease ensure dlScripts config is set up."
    exit 1
}

# Apply config defaults if not specified
if (-not $QbitHost) { $QbitHost = $qBitHost }
if (-not $Destination) { $Destination = $movieDestination }
if ($MaxResults -eq 0) { $MaxResults = $movieMaxResults }

# Ensure destination directory exists
if (-not (Test-Path $Destination)) {
    try {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    } catch {
        Write-Error "Cannot create destination directory: $Destination"
        exit 1
    }
}

Add-Type -AssemblyName System.Web

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
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

$amp = [char]38

$trackers = @(
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.openbittorrent.com:80",
    "udp://tracker.coppersurfer.tk:6969",
    "udp://glotorrents.pw:6969/announce",
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://torrent.gresille.org:80/announce",
    "udp://p4p.arenabg.com:1337",
    "udp://tracker.leechers-paradise.org:6969"
)

Write-Log "Starting movie download process" "INFO"
Write-Log "Search query: $Query" "INFO"
Write-Log "Destination: $Destination" "INFO"

$encodedQuery = [System.Web.HttpUtility]::UrlEncode($Query)
$apiUrl = "https://yts.bz/api/v2/list_movies.json?query_term=$encodedQuery" + "$amp" + "sort_by=seeds" + "$amp" + "limit=50"

Write-Log "Fetching from YTS API..." "INFO"
Write-Log "URL: $apiUrl" "DEBUG"

try {
    $response = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing
    $data = $response.Content | ConvertFrom-Json

    if ($data.status -ne "ok") {
        Write-Log "API returned status: $($data.status_message)" "ERROR"
        exit 1
    }

    if ($data.data.movie_count -eq 0 -or -not $data.data.movies) {
        Write-Log "No movies found for: $Query" "ERROR"
        exit 1
    }

    Write-Log "API returned $($data.data.movie_count) result(s)" "DEBUG"

    $movies = @()

    foreach ($movie in $data.data.movies | Select-Object -First $MaxResults) {
        if (-not $movie.torrents -or $movie.torrents.Count -eq 0) {
            Write-Log "Skipping '$($movie.title)' - no torrents" "DEBUG"
            continue
        }

        $bestTorrent = $movie.torrents |
            Where-Object { $_.quality -eq "1080p" -and $_.type -match "bluray|blu.ray" } |
            Sort-Object seeds -Descending |
            Select-Object -First 1
        $qualityLabel = if ($bestTorrent) { "1080p BluRay" } else { $null }

        if (-not $bestTorrent) {
            $bestTorrent = $movie.torrents |
                Where-Object { $_.quality -eq "1080p" } |
                Sort-Object seeds -Descending |
                Select-Object -First 1
            $qualityLabel = if ($bestTorrent) { "1080p $($bestTorrent.type)" } else { $null }
        }

        if (-not $bestTorrent) {
            $bestTorrent = $movie.torrents |
                Sort-Object seeds -Descending |
                Select-Object -First 1
            $qualityLabel = if ($bestTorrent) { "$($bestTorrent.quality) $($bestTorrent.type)" } else { $null }
        }

        if (-not $bestTorrent) { continue }

        Write-Log "Movie: $($movie.title) ($($movie.year)) -> $qualityLabel ($($bestTorrent.seeds) seeds)" "DEBUG"

        $dn = [System.Web.HttpUtility]::UrlEncode("$($movie.title) ($($movie.year)) [$qualityLabel] [YTS.BZ]")
        $magnetLink = "magnet:?xt=urn:btih:$($bestTorrent.hash)" + "$amp" + "dn=$dn"
        foreach ($tr in $trackers) {
            $magnetLink += "$amp" + "tr=$([System.Web.HttpUtility]::UrlEncode($tr))"
        }

        $allQualities = ($movie.torrents | ForEach-Object { "$($_.quality) $($_.type)" }) -join ", "

        $movies += [PSCustomObject]@{
            Title         = $movie.title
            Year          = $movie.year
            Rating        = $movie.rating
            QualityLabel  = $qualityLabel
            Size          = $bestTorrent.size
            Seeds         = $bestTorrent.seeds
            Peers         = $bestTorrent.peers
            AllQualities  = $allQualities
            MagnetLink    = $magnetLink
            TorrentUrl    = $bestTorrent.url
        }
    }

    if ($movies.Count -eq 0) {
        Write-Log "No movies with available torrents found" "ERROR"
        exit 1
    }

    Write-Log "Parsed $($movies.Count) movie(s)" "SUCCESS"

    Write-Host ""
    for ($i = 0; $i -lt $movies.Count; $i++) {
        $m = $movies[$i]
        Write-Host "[$($i+1)] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($m.Title) ($($m.Year))" -ForegroundColor White
        Write-Host "    Quality: $($m.QualityLabel) | Size: $($m.Size) | Seeds: $($m.Seeds) | Rating: $($m.Rating)" -ForegroundColor Cyan
        Write-Host "    All available: $($m.AllQualities)" -ForegroundColor Gray
        Write-Host ""
    }

    $selectedIndex = 0
    if ($Interactive -and $movies.Count -gt 1) {
        Write-Log "Interactive mode: waiting for user selection..." "INFO"
        Write-Host "Select movie [1-$($movies.Count)] or 0 to cancel: " -NoNewline -ForegroundColor Cyan
        $selection = Read-Host
        $selectedIndex = [int]$selection - 1

        if ($selectedIndex -lt 0 -or $selectedIndex -ge $movies.Count) {
            Write-Log "User cancelled selection" "WARN"
            exit 0
        }
        Write-Log "User selected movie #$($selectedIndex + 1)" "INFO"
    } else {
        Write-Log "Auto-selecting top result" "INFO"
    }

    $selected = $movies[$selectedIndex]

    Write-Log "Selected: $($selected.Title) ($($selected.Year))" "SUCCESS"
    Write-Log "  Quality: $($selected.QualityLabel)" "DEBUG"
    Write-Log "  Size: $($selected.Size)" "DEBUG"
    Write-Log "  Seeds: $($selected.Seeds)" "DEBUG"
    Write-Host ""

    Write-Log "Adding to qBittorrent at $QbitHost..." "INFO"

    $body = @{
        urls     = $selected.MagnetLink
        savepath = $Destination
    }

    $addResponse = Invoke-WebRequest -Uri "$QbitHost/api/v2/torrents/add" -Method POST -Body $body -UseBasicParsing

    if ($addResponse.StatusCode -eq 200) {
        Write-Log "Successfully added to qBittorrent!" "SUCCESS"
        Write-Log "  Movie: $($selected.Title) ($($selected.Year))" "INFO"
        Write-Log "  Quality: $($selected.QualityLabel)" "INFO"
        Write-Log "  Size: $($selected.Size)" "INFO"
        Write-Log "  Destination: $Destination" "INFO"
        Write-Host ""
        Write-Log "Process completed successfully" "SUCCESS"

        $result = $selected | ConvertTo-Json
        return $result
    } else {
        Write-Log "Failed to add to qBittorrent (Status: $($addResponse.StatusCode))" "ERROR"
        exit 1
    }

} catch {
    Write-Log "Exception occurred: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
    exit 1
}
