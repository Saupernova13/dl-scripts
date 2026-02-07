# Add-Anime.ps1
# Wrapper to search nyaa.si and add torrents to qBittorrent
# Usage: .\Add-Anime.ps1 -Query "Frieren" -Destination "D:\TV"
# Default destination: D:\TV (4TB drive)

param(
    [Parameter(Mandatory=$true)]
    [string]$Query,

    [Parameter(Mandatory=$false)]
    [string]$Destination = "D:\TV",  # 4TB drive - default location

    [Parameter(Mandatory=$false)]
    [switch]$TrustedOnly = $false,

    [Parameter(Mandatory=$false)]
    [string]$QbitHost = "http://localhost:8075",

    [Parameter(Mandatory=$false)]
    [int]$MaxResults = 75,

    [Parameter(Mandatory=$false)]
    [switch]$Interactive = $false,

    [Parameter(Mandatory=$false)]
    [string]$Filter = ""
)

# Logging helper function
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

# Load System.Web for HttpUtility
Add-Type -AssemblyName System.Web

# Build search URL
$searchQuery = $Query

# Automatically append "dual audio" to prioritize dual audio releases
# Skip if user already included it or specified a custom filter
if (-not $Filter -and $searchQuery -inotmatch 'dual[\s\-_]*audio') {
    $searchQuery = "$Query dual audio"
    Write-Log "Automatically appending 'dual audio' to search query" "DEBUG"
}
elseif ($Filter) {
    $searchQuery = "$Query $Filter"
}

$encodedQuery = [System.Web.HttpUtility]::UrlEncode($searchQuery)
$amp = [char]38
# Match browser URL format exactly: ?f=0&c=0_0&q=...
# f=0: No filter (show all, not just trusted)
# c=0_0: All categories (broadest search)
$filterParam = if ($TrustedOnly) { "f=2" } else { "f=0" }
$url = "https://nyaa.si/?$filterParam" + "$amp" + "c=0_0" + "$amp" + "q=$encodedQuery"

Write-Log "Starting anime download process" "INFO"
Write-Log "Search query: $searchQuery" "INFO"
Write-Log "Destination: $Destination" "INFO"
Write-Log "Trusted only: $TrustedOnly" "DEBUG"
Write-Log "URL: $url" "DEBUG"

# Fetch and parse results
try {
    Write-Log "Fetching results from nyaa.si..." "INFO"
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing
    $html = $response.Content
    Write-Log "Received HTML response: $($html.Length) bytes" "DEBUG"

    # Parse torrent entries - split by rows first to avoid regex performance issues
    $torrents = @()

    # HTML entity patterns
    $htmlQuot = '&' + 'quot;'
    $htmlAmp = '&' + 'amp;'

    # Split HTML into table rows - be flexible with class names and whitespace
    Write-Log "Parsing HTML table rows..." "INFO"
    $rowPattern = '<tr\s+class="(?:success|default|danger)"[^>]*>(.*?)</tr>'
    $rowMatches = [regex]::Matches($html, $rowPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

    if ($rowMatches.Count -eq 0) {
        Write-Log "No results found for: $searchQuery" "ERROR"
        Write-Log "HTML sample (first 500 chars): $($html.Substring(0, [Math]::Min(500, $html.Length)))" "DEBUG"
        exit 1
    }

    Write-Log "Found $($rowMatches.Count) potential matches in HTML" "DEBUG"

    $count = 0
    $allTorrents = @()
    foreach ($rowMatch in $rowMatches) {

        $rowHtml = $rowMatch.Groups[1].Value

        # Extract fields from this row with simple patterns
        $viewIdMatch = [regex]::Match($rowHtml, 'href="/view/(\d+)"')
        $titleMatch = [regex]::Match($rowHtml, 'href="/view/\d+" title="([^"]*)"')
        $downloadIdMatch = [regex]::Match($rowHtml, 'href="/download/(\d+)\.torrent"')
        $magnetMatch = [regex]::Match($rowHtml, 'magnet:\?xt=urn:btih:([a-f0-9]+)')

        # Extract table cells - get all text-center cells
        $cellMatches = [regex]::Matches($rowHtml, '<td class="text-center"[^>]*>\s*([^<]+?)\s*</td>')

        if (-not $viewIdMatch.Success -or -not $titleMatch.Success -or $cellMatches.Count -lt 5) {
            Write-Log "Skipping row - incomplete data" "DEBUG"
            continue
        }

        # Clean up the name
        $torrentName = $titleMatch.Groups[1].Value
        $torrentName = $torrentName.Replace($htmlQuot, '"')
        $torrentName = $torrentName.Replace($htmlAmp, '&')

        # Extract numeric values safely
        $seedersText = $cellMatches[2].Groups[1].Value.Trim()
        $leechersText = $cellMatches[3].Groups[1].Value.Trim()
        $downloadsText = $cellMatches[4].Groups[1].Value.Trim()

        $seeders = if ($seedersText -match '^\d+$') { [int]$seedersText } else { 0 }
        $leechers = if ($leechersText -match '^\d+$') { [int]$leechersText } else { 0 }
        $downloads = if ($downloadsText -match '^\d+$') { [int]$downloadsText } else { 0 }

        # Extract uploader from torrent name (usually in brackets at start)
        $uploaderMatch = [regex]::Match($torrentName, '^\[([^\]]+)\]')
        $uploader = if ($uploaderMatch.Success) { $uploaderMatch.Groups[1].Value } else { "Unknown" }

        $torrent = @{
            ID = $viewIdMatch.Groups[1].Value
            Name = $torrentName
            Uploader = $uploader
            DownloadID = $downloadIdMatch.Groups[1].Value
            InfoHash = $magnetMatch.Groups[1].Value
            Size = $cellMatches[0].Groups[1].Value.Trim()
            Date = $cellMatches[1].Groups[1].Value.Trim()
            Seeders = $seeders
            Leechers = $leechers
            Downloads = $downloads
        }

        $allTorrents += [PSCustomObject]$torrent
        $count++
    }

    Write-Log "Parsed $count torrents successfully" "SUCCESS"
    Write-Log "Process completed" "SUCCESS"
} catch {
    Write-Log "Exception occurred: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
    exit 1
}
