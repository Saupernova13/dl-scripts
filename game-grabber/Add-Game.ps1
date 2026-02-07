# Add-Game.ps1
# Search appnetica.com for games and add torrents to qBittorrent

param(
    [Parameter(Mandatory=$true)]
    [string]$Query,

    [Parameter(Mandatory=$true)]
    [string]$Email,

    [Parameter(Mandatory=$true)]
    [string]$Password
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
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

Write-Log "Starting game download process" "INFO"

# Create web session for maintaining login
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# Login to appnetica.com
Write-Log "Logging in to appnetica.com..." "INFO"

$loginUrl = "https://appnetica.com/auth?/login"
$loginBody = "email=$([System.Web.HttpUtility]::UrlEncode($Email))&password=$([System.Web.HttpUtility]::UrlEncode($Password))"

$loginHeaders = @{
    "Content-Type" = "application/x-www-form-urlencoded"
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    "Origin" = "https://appnetica.com"
    "Referer" = "https://appnetica.com/"
}

try {
    $loginResponse = Invoke-WebRequest -Uri $loginUrl -Method POST -Body $loginBody -Headers $loginHeaders -WebSession $session -UseBasicParsing

    $authCookie = $session.Cookies.GetCookies("https://appnetica.com") | Where-Object { $_.Name -eq "pb_auth" }

    if ($authCookie) {
        Write-Log "Login successful" "SUCCESS"
    } else {
        Write-Log "Login failed - no auth cookie" "ERROR"
        exit 1
    }
} catch {
    Write-Log "Login failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Search for games
Write-Log "Searching for: $Query" "INFO"
$searchUrl = "https://appnetica.com/api/search?q=$([System.Web.HttpUtility]::UrlEncode($Query))"

try {
    $searchResponse = Invoke-WebRequest -Uri $searchUrl -WebSession $session -UseBasicParsing
    $searchData = $searchResponse.Content | ConvertFrom-Json

    Write-Log "Found $($searchData.results.Count) results" "SUCCESS"
} catch {
    Write-Log "Search failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
