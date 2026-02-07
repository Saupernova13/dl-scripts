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

    # Select first game
    $selectedGame = $games[0]
    Write-Log "Selected: $($selectedGame.Title)" "INFO"

    # Get game page to find download link
    Write-Log "Fetching game page..." "INFO"
    $gamePage = Invoke-WebRequest -Uri $selectedGame.URL -WebSession $session -UseBasicParsing
    $gameHtml = $gamePage.Content

    # Find download link pattern: /file/{fileId}?game={gameId}
    $downloadUrl = $null

    # Pattern 1: href="/file/...?game=..."
    $pattern1 = 'href="(/file/[a-zA-Z0-9]+\?game=[a-zA-Z0-9]+)"'
    $match = [regex]::Match($gameHtml, $pattern1)
    if ($match.Success) {
        $downloadUrl = $match.Groups[1].Value
    }

    # Pattern 2: Direct /file/ search
    if (-not $downloadUrl) {
        $pattern2 = '/file/([a-zA-Z0-9]+)\?game=([a-zA-Z0-9]+)'
        $match = [regex]::Match($gameHtml, $pattern2)
        if ($match.Success) {
            $downloadUrl = $match.Value
        }
    }

    if (-not $downloadUrl) {
        Write-Log "Could not find download link" "ERROR"
        exit 1
    }

    # Make URL absolute
    if (-not $downloadUrl.StartsWith("http")) {
        $downloadUrl = "https://appnetica.com$downloadUrl"
    }

    Write-Log "Download URL: $downloadUrl" "SUCCESS"

    # Download torrent file
    Write-Log "Downloading torrent..." "INFO"
    $torrentPath = Join-Path $env:TEMP "$($selectedGame.Slug).torrent"
    Invoke-WebRequest -Uri $downloadUrl -WebSession $session -OutFile $torrentPath -UseBasicParsing

    if (-not (Test-Path $torrentPath)) {
        Write-Log "Failed to download torrent" "ERROR"
        exit 1
    }

    Write-Log "Torrent saved to: $torrentPath" "SUCCESS"

    # Add torrent to qBittorrent
    Write-Log "Adding to qBittorrent..." "INFO"

    $qbitHost = "http://localhost:8075"
    $destination = "D:\Games"

    # Read torrent file
    $torrentBytes = [System.IO.File]::ReadAllBytes($torrentPath)
    $fileName = [System.IO.Path]::GetFileName($torrentPath)

    # Build multipart form data properly using MemoryStream
    $boundary = [System.Guid]::NewGuid().ToString()
    $LF = "`r`n"

    $memStream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.StreamWriter($memStream)
    $writer.NewLine = $LF

    # Part 1: Torrent file
    $writer.WriteLine("--$boundary")
    $writer.WriteLine("Content-Disposition: form-data; name=`"torrents`"; filename=`"$fileName`"")
    $writer.WriteLine("Content-Type: application/x-bittorrent")
    $writer.WriteLine()
    $writer.Flush()
    $memStream.Write($torrentBytes, 0, $torrentBytes.Length)
    $writer.WriteLine()

    # Part 2: Save path
    $writer.WriteLine("--$boundary")
    $writer.WriteLine("Content-Disposition: form-data; name=`"savepath`"")
    $writer.WriteLine()
    $writer.WriteLine($destination)

    # End boundary
    $writer.WriteLine("--$boundary--")
    $writer.Flush()

    $bodyBytes = $memStream.ToArray()
    $writer.Close()
    $memStream.Close()

    $headers = @{
        "Content-Type" = "multipart/form-data; boundary=$boundary"
    }

    try {
        $response = Invoke-WebRequest -Uri "$qbitHost/api/v2/torrents/add" -Method POST -Body $bodyBytes -Headers $headers -UseBasicParsing

        if ($response.StatusCode -eq 200) {
            Write-Log "Successfully added to qBittorrent!" "SUCCESS"
            Remove-Item $torrentPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "Failed to add to qBittorrent: $($_.Exception.Message)" "ERROR"
    }

} catch {
    Write-Log "Error: $($_.Exception.Message)" "ERROR"
    exit 1
}
