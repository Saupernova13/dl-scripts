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

# Search for games using SvelteKit endpoint
Write-Log "Searching for: $Query" "INFO"
$searchUrl = "https://appnetica.com/search/__data.json?term=$([System.Web.HttpUtility]::UrlEncode($Query))&x-sveltekit-invalidated=011"

try {
    $searchResponse = Invoke-WebRequest -Uri $searchUrl -WebSession $session -UseBasicParsing
    $svelteData = $searchResponse.Content | ConvertFrom-Json

    # Parse SvelteKit data structure - find search results node
    $searchNode = $null
    for ($i = 0; $i -lt $svelteData.nodes.Count; $i++) {
        $node = $svelteData.nodes[$i]
        if ($node.type -eq "data" -and $node.uses -and $node.uses.search_params) {
            $searchNode = $node
            Write-Log "Found search node at index $i" "INFO"
            break
        }
    }

    if (-not $searchNode) {
        Write-Log "Failed to find search results" "ERROR"
        exit 1
    }

    # Dereference numeric references in data array
    $dataArray = $searchNode.data
    $searchResults = $dataArray[0]

    # Get totalItems (dereference if it's a number)
    $totalItemsRef = $searchResults.totalItems
    $totalItems = if ($totalItemsRef -is [int]) { $dataArray[$totalItemsRef] } else { $totalItemsRef }

    Write-Log "Found $totalItems games" "SUCCESS"

    if ($totalItems -eq 0) {
        Write-Log "No results found" "WARN"
        exit 1
    }

    # Get games array (dereference)
    $gamesRef = $searchResults.games
    $gamesData = if ($gamesRef -is [int]) { $dataArray[$gamesRef] } else { $gamesRef }

    $itemsRef = $gamesData.items
    $itemsArray = if ($itemsRef -is [int]) { $dataArray[$itemsRef] } else { $itemsRef }

    # Extract game titles and slugs
    $games = @()
    foreach ($itemRef in $itemsArray) {
        $game = if ($itemRef -is [int]) { $dataArray[$itemRef] } else { $itemRef }
        $title = if ($game.title -is [int]) { $dataArray[$game.title] } else { $game.title }
        $slug = if ($game.slug -is [int]) { $dataArray[$game.slug] } else { $game.slug }

        $games += [PSCustomObject]@{
            Title = $title
            Slug = $slug
            URL = "https://appnetica.com/games/$slug"
        }

        if ($games.Count -ge 10) { break }
    }

    Write-Log "Parsed $($games.Count) games" "SUCCESS"

} catch {
    Write-Log "Search failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
