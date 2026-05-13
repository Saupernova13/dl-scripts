# dlgame.ps1
# Search appnetica.com for games and add torrents to qBittorrent
# Usage: .\dlgame.ps1 -Query "Spider-Man"
# Configuration sourced from %LOCALAPPDATA%\dlScripts\config.json
# Credentials sourced from .settings file in the same directory as this script

param(
    [Parameter(Mandatory=$true)]
    [string]$Query,

    [Parameter(Mandatory=$false)]
    [string]$Email,

    [Parameter(Mandatory=$false)]
    [string]$Password,

    [Parameter(Mandatory=$false)]
    [string]$Destination,

    [Parameter(Mandatory=$false)]
    [string]$QbitHost,

    [Parameter(Mandatory=$false)]
    [int]$MaxResults = 0,

    [Parameter(Mandatory=$false)]
    [switch]$Interactive = $false,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false
)

# Load System.Web for HttpUtility
Add-Type -AssemblyName System.Web

# Shared resolver library: Initialize-DlConfig, Resolve-MediaPath, Get-DriveMetaInventory.
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\DriveResolver.ps1")

$cfg = Initialize-DlConfig -Section "game" -Defaults ([PSCustomObject]@{
    qbitHost         = "http://localhost:8080"
    destination      = (Join-Path $HOME "Games")
    maxResults       = 10
    useDriveMetadata = $true
})

# Load .settings for credentials (Email and Password only)
$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsFile = Join-Path $scriptDir ".settings"

if (Test-Path $settingsFile) {
    $settings = @{}
    Get-Content $settingsFile | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '=' } | ForEach-Object {
        $key, $value = $_ -split '=', 2
        $settings[$key.Trim()] = $value.Trim()
    }
    if (-not $Email    -and $settings['Email'])    { $Email    = $settings['Email'] }
    if (-not $Password -and $settings['Password']) { $Password = $settings['Password'] }
}

# Validate required credentials
if (-not $Email -or -not $Password) {
    Write-Host "ERROR: Email and Password must be provided via .settings file or command-line parameters." -ForegroundColor Red
    Write-Host "       Copy .settings.example to .settings and fill in your credentials." -ForegroundColor Yellow
    exit 1
}

# Apply config defaults for non-credential settings
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
    $Destination = Resolve-MediaPath -MediaType 'game_pc'
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

Write-Log "Starting game download process" "INFO"
Write-Log "Search query: $Query" "INFO"
Write-Log "Destination: $Destination" "INFO"

# Create web session for maintaining login
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

try {
    # Step 1: Login to appnetica.com
    Write-Log "Logging in to appnetica.com..." "INFO"

    $loginUrl = "https://appnetica.com/auth?/login"

    # Use form data (NOT JSON)
    $loginBody = "email=$([System.Web.HttpUtility]::UrlEncode($Email))&password=$([System.Web.HttpUtility]::UrlEncode($Password))"

    $loginHeaders = @{
        "Content-Type" = "application/x-www-form-urlencoded"
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        "Origin" = "https://appnetica.com"
        "Referer" = "https://appnetica.com/"
    }

    try {
        $loginResponse = Invoke-WebRequest -Uri $loginUrl -Method POST -Body $loginBody -Headers $loginHeaders -WebSession $session -UseBasicParsing

        # Check if we got the pb_auth cookie
        $authCookie = $session.Cookies.GetCookies("https://appnetica.com") | Where-Object { $_.Name -eq "pb_auth" }

        if ($authCookie) {
            Write-Log "Login successful - auth cookie received" "SUCCESS"
        } else {
            Write-Log "Login response received but no auth cookie found" "WARN"
            Write-Log "Response status: $($loginResponse.StatusCode)" "DEBUG"
        }
    } catch {
        Write-Log "Login failed: $($_.Exception.Message)" "ERROR"
        Write-Log "Please check your credentials" "ERROR"
        exit 1
    }

    # Step 2: Search for games using SvelteKit endpoint
    Write-Log "Searching for games..." "INFO"
    $searchUrl = "https://appnetica.com/search/__data.json?term=$([System.Web.HttpUtility]::UrlEncode($Query))&x-sveltekit-invalidated=011"
    Write-Log "Search URL: $searchUrl" "DEBUG"

    try {
        $searchResponse = Invoke-WebRequest -Uri $searchUrl -WebSession $session -UseBasicParsing
        Write-Log "Search response received (Status: $($searchResponse.StatusCode))" "DEBUG"

        $svelteData = $searchResponse.Content | ConvertFrom-Json
        Write-Log "JSON parsed successfully" "DEBUG"

        # Parse SvelteKit data structure - find the search results node
        $searchNode = $null
        for ($i = 0; $i -lt $svelteData.nodes.Count; $i++) {
            $node = $svelteData.nodes[$i]
            if ($node.type -eq "data" -and $node.uses -and $node.uses.search_params) {
                $searchNode = $node
                Write-Log "Found search node at index $i" "DEBUG"
                break
            }
        }

        if (-not $searchNode) {
            Write-Log "Failed to find search results node" "ERROR"
            Write-Log "Available node types: $($svelteData.nodes | ForEach-Object { $_.type } | Out-String)" "DEBUG"
            exit 1
        }

        # The data array contains values with numeric references
        $dataArray = $searchNode.data
        Write-Log "Data array has $($dataArray.Count) elements" "DEBUG"

        # First element should be the search results object
        $searchResults = $dataArray[0]

        # Get totalItems - it's a reference (number) to another position in array
        $totalItemsRef = $searchResults.totalItems
        $totalItems = if ($totalItemsRef -is [int]) { $dataArray[$totalItemsRef] } else { $totalItemsRef }

        Write-Log "Found $totalItems total items" "DEBUG"

        # Step 3: Parse search results
        Write-Log "Parsing search results..." "INFO"

        if ($totalItems -eq 0) {
            Write-Log "No results found for: $Query" "ERROR"
            Write-Log "Try a different search term" "WARN"
            exit 1
        }

        # Get games data - it's also a reference
        $gamesRef = $searchResults.games
        $gamesData = if ($gamesRef -is [int]) { $dataArray[$gamesRef] } else { $gamesRef }

        Write-Log "Games data type: $($gamesData.GetType().Name)" "DEBUG"

        # Get items array - also a reference
        $itemsRef = $gamesData.items
        $itemsArray = if ($itemsRef -is [int]) { $dataArray[$itemsRef] } else { $itemsRef }

        Write-Log "Found $($itemsArray.Count) game items" "DEBUG"

        # Extract games from items array - filter for Steam versions only
        $games = @()
        $skippedRepacks = 0

        foreach ($itemRef in $itemsArray) {
            # Dereference the item
            $game = if ($itemRef -is [int]) { $dataArray[$itemRef] } else { $itemRef }

            # Dereference title and slug
            $title = if ($game.title -is [int]) { $dataArray[$game.title] } else { $game.title }
            $slug = if ($game.slug -is [int]) { $dataArray[$game.slug] } else { $game.slug }

            # Get publication type to filter out repacks
            $publicationType = $null
            if ($game.expand -ne $null) {
                $expandRef = if ($game.expand -is [int]) { $dataArray[$game.expand] } else { $game.expand }
                if ($expandRef.publication_type -ne $null) {
                    $pubTypeRef = if ($expandRef.publication_type -is [int]) { $dataArray[$expandRef.publication_type] } else { $expandRef.publication_type }
                    if ($pubTypeRef.source -ne $null) {
                        $publicationType = if ($pubTypeRef.source -is [int]) { $dataArray[$pubTypeRef.source] } else { $pubTypeRef.source }
                    }
                }
            }

            Write-Log "Found game: $title (type: $publicationType)" "DEBUG"

            # Filter: Only include Steam folder versions, exclude repacks
            # Repack sources: dec, fit, dodi, etc.
            # Steam sources: steam_folder, steam_rip, etc. (we want these)
            if ($publicationType -and $publicationType -match "^(dec|fit|dodi|elamigos|r\.g\.|repack)") {
                Write-Log "  Skipping repack: $publicationType" "DEBUG"
                $skippedRepacks++
                continue
            }

            # Only include if it's a Steam version or has "steam" in slug
            if ($publicationType -match "steam" -or $slug -match "steam") {
                $games += [PSCustomObject]@{
                    Title = $title
                    Slug = $slug
                    URL = "https://appnetica.com/games/$slug"
                    PublicationType = $publicationType
                }
            } else {
                Write-Log "  Skipping non-Steam game" "DEBUG"
                continue
            }

            if ($games.Count -ge $MaxResults) { break }
        }

        Write-Log "Extracted $($games.Count) Steam games (skipped $skippedRepacks repacks)" "DEBUG"

    } catch {
        Write-Log "Error during search: $($_.Exception.Message)" "ERROR"
        Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
        exit 1
    }

    if ($games.Count -eq 0) {
        Write-Log "No Steam folder versions found (only repacks or non-Steam versions available)" "WARN"
        Write-Log "Try a different search term" "WARN"
        exit 1
    }

    Write-Log "Found $($games.Count) Steam game(s)" "SUCCESS"

    # Display results
    Write-Log "Displaying top $($games.Count) results..." "INFO"
    Write-Host ""

    for ($i = 0; $i -lt $games.Count; $i++) {
        $g = $games[$i]
        Write-Host "[$($i+1)] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($g.Title)" -ForegroundColor White
        Write-Host "    URL: $($g.URL)" -ForegroundColor Gray
        Write-Host ""
    }

    # Select game
    $selectedIndex = 0
    if ($Interactive -and $games.Count -gt 1) {
        Write-Log "Interactive mode: waiting for user selection..." "INFO"
        Write-Host "Select game [1-$($games.Count)] or 0 to cancel: " -NoNewline -ForegroundColor Cyan
        $selection = Read-Host
        $selectedIndex = [int]$selection - 1

        if ($selectedIndex -lt 0 -or $selectedIndex -ge $games.Count) {
            Write-Log "User cancelled selection" "WARN"
            exit 0
        }
        Write-Log "User selected game #$($selectedIndex + 1)" "INFO"
    } else {
        Write-Log "Auto-selecting first game" "INFO"
    }

    $selectedGame = $games[$selectedIndex]
    Write-Log "Selected: $($selectedGame.Title)" "SUCCESS"
    Write-Host ""

    # Step 4: Get game page to find download link
    Write-Log "Fetching game page..." "INFO"
    $gamePage = Invoke-WebRequest -Uri $selectedGame.URL -WebSession $session -UseBasicParsing
    $gameHtml = $gamePage.Content

    # Look for download link in format: /file/{fileId}?game={gameId}
    # This is typically in a href or onclick handler
    Write-Log "Searching for download link pattern..." "DEBUG"

    # Try multiple patterns
    $downloadUrl = $null

    # Pattern 1: href="/file/...?game=..."
    $pattern1 = 'href="(/file/[a-zA-Z0-9]+\?game=[a-zA-Z0-9]+)"'
    $match = [regex]::Match($gameHtml, $pattern1)
    if ($match.Success) {
        $downloadUrl = $match.Groups[1].Value
        Write-Log "Found download link (pattern 1): $downloadUrl" "DEBUG"
    }

    # Pattern 2: Look in embedded JSON data for file/download info
    if (-not $downloadUrl) {
        $pattern2 = '["'']file["'']:\s*["'']([^"'']+)["'']'
        $match = [regex]::Match($gameHtml, $pattern2)
        if ($match.Success) {
            $fileId = $match.Groups[1].Value
            Write-Log "Found file ID in JSON: $fileId" "DEBUG"

            # Extract game ID from URL
            if ($selectedGame.Slug -match '([a-zA-Z0-9]{15})$') {
                $gameId = $matches[1]
            } else {
                # Try to find game ID in page HTML
                $gameIdMatch = [regex]::Match($gameHtml, '"id"\s*:\s*"([a-zA-Z0-9]{15})"')
                if ($gameIdMatch.Success) {
                    $gameId = $gameIdMatch.Groups[1].Value
                }
            }

            if ($gameId) {
                $downloadUrl = "/file/$fileId?game=$gameId"
                Write-Log "Constructed download URL: $downloadUrl" "DEBUG"
            }
        }
    }

    # Pattern 3: Search for "file/" anywhere in the HTML
    if (-not $downloadUrl) {
        $pattern3 = '/file/([a-zA-Z0-9]+)\?game=([a-zA-Z0-9]+)'
        $match = [regex]::Match($gameHtml, $pattern3)
        if ($match.Success) {
            $downloadUrl = $match.Value
            Write-Log "Found download link (pattern 3): $downloadUrl" "DEBUG"
        }
    }

    if (-not $downloadUrl) {
        Write-Log "Could not find download link on game page" "ERROR"
        Write-Log "Saving page HTML to temp file for inspection..." "DEBUG"
        $debugFile = Join-Path $env:TEMP "game-page-debug.html"
        $gameHtml | Out-File -FilePath $debugFile -Encoding UTF8
        Write-Log "Page saved to: $debugFile" "DEBUG"
        exit 1
    }

    # Make URL absolute if needed
    if (-not $downloadUrl.StartsWith("http")) {
        $downloadUrl = "https://appnetica.com$downloadUrl"
    }

    Write-Log "Download URL: $downloadUrl" "SUCCESS"

    if ($DryRun) {
        Write-Log "[DRY RUN] Would download torrent from: $downloadUrl" "INFO"
        Write-Log "[DRY RUN] Would POST to $QbitHost/api/v2/torrents/add" "INFO"
        Write-Log "[DRY RUN]   savepath: $Destination" "INFO"
        Write-Log "Dry run complete - no torrent downloaded or submitted." "SUCCESS"
        return (@{ Title = $selectedGame.Title; Destination = $Destination } | ConvertTo-Json)
    }

    # Step 5: Download torrent file
    Write-Log "Downloading torrent file..." "INFO"
    $torrentPath = Join-Path $env:TEMP "$($selectedGame.Slug).torrent"

    Invoke-WebRequest -Uri $downloadUrl -WebSession $session -OutFile $torrentPath -UseBasicParsing

    if (-not (Test-Path $torrentPath)) {
        Write-Log "Failed to download torrent file" "ERROR"
        exit 1
    }

    Write-Log "Torrent file saved to: $torrentPath" "SUCCESS"

    # Step 6: Add torrent to qBittorrent
    Write-Log "Adding torrent to qBittorrent..." "INFO"

    try {
        # Read torrent file
        $torrentBytes = [System.IO.File]::ReadAllBytes($torrentPath)
        $fileName = [System.IO.Path]::GetFileName($torrentPath)

        # Build multipart/form-data body (PowerShell 5.1 compatible)
        $boundary = [System.Guid]::NewGuid().ToString()
        $LF = "`r`n"

        # Create MemoryStream to build the body
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
        $writer.WriteLine($Destination)

        # End boundary
        $writer.WriteLine("--$boundary--")
        $writer.Flush()

        # Get the complete body
        $bodyBytes = $memStream.ToArray()
        $writer.Close()
        $memStream.Close()

        # Make the request
        $headers = @{
            "Content-Type" = "multipart/form-data; boundary=$boundary"
        }

        Write-Log "Sending torrent to qBittorrent (size: $($torrentBytes.Length) bytes)..." "DEBUG"
        $addResponse = Invoke-WebRequest -Uri "$QbitHost/api/v2/torrents/add" -Method POST -Body $bodyBytes -Headers $headers -UseBasicParsing

        if ($addResponse.StatusCode -eq 200) {
            Write-Log "Successfully added to qBittorrent!" "SUCCESS"
            Write-Log "  Game: $($selectedGame.Title)" "INFO"
            Write-Log "  Destination: $Destination" "INFO"
            Write-Host ""

            # Clean up temp file
            Remove-Item $torrentPath -Force -ErrorAction SilentlyContinue

            # Return info
            $result = @{
                Title = $selectedGame.Title
                URL = $selectedGame.URL
                Destination = $Destination
            } | ConvertTo-Json

            Write-Log "Process completed successfully" "SUCCESS"
            return $result
        } else {
            Write-Log "Failed to add to qBittorrent (Status: $($addResponse.StatusCode))" "ERROR"
            exit 1
        }

    } catch {
        Write-Log "Error adding to qBittorrent: $($_.Exception.Message)" "ERROR"

        # Save the torrent file for manual addition
        $savedTorrent = Join-Path $env:USERPROFILE "Downloads\$($selectedGame.Slug).torrent"
        Copy-Item $torrentPath $savedTorrent -Force -ErrorAction SilentlyContinue
        Write-Log "Torrent file saved to: $savedTorrent" "INFO"
        Write-Log "You can add it manually to qBittorrent" "WARN"

        exit 1
    }

} catch {
    Write-Log "Exception occurred: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
    exit 1
}
