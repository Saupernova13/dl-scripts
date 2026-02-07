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

Write-Log "Starting anime download process" "INFO"
