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

    Write-Log "Process completed" "SUCCESS"
} catch {
    Write-Log "Exception occurred: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
    exit 1
}
