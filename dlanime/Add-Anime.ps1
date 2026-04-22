# dlanime.ps1
# Search nyaa.si and add anime torrents to qBittorrent
# Configuration sourced from %LOCALAPPDATA%\dlScripts\config.json

param(
    [Parameter(Mandatory=$true)]
    [string]$Query,

    [Parameter(Mandatory=$false)]
    [ValidateSet("yes", "no")]
    [string]$isAnimeSeries = "yes",

    [Parameter(Mandatory=$false)]
    [string]$Destination = "",

    [Parameter(Mandatory=$false)]
    [switch]$TrustedOnly = $false,

    [Parameter(Mandatory=$false)]
    [string]$QbitHost = "",

    [Parameter(Mandatory=$false)]
    [int]$MaxResults = 0,

    [Parameter(Mandatory=$false)]
    [switch]$Interactive = $false,

    [Parameter(Mandatory=$false)]
    [string]$Filter = "",

    [Parameter(Mandatory=$false)]
    [switch]$ListOnly = $false
)

# Load/create config.json and return this script's section.
# On first run: creates the file and writes defaults. On subsequent runs: reads existing values.
# If the section is missing from an existing file, it is added with defaults.
function Initialize-DlConfig {
    param([string]$Section, [PSCustomObject]$Defaults)
    $configDir  = Join-Path $env:LOCALAPPDATA "dlScripts"
    $configPath = Join-Path $configDir "config.json"
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $config = $null
    $dirty  = $false
    if (Test-Path $configPath) {
        try   { $config = Get-Content $configPath -Raw | ConvertFrom-Json }
        catch {
            Write-Host "[dlScripts] config.json could not be parsed  - [$Section] defaults will be written." -ForegroundColor Yellow
            $config = [PSCustomObject]@{}
            $dirty  = $true
        }
    } else {
        Write-Host "[dlScripts] Config not found  - creating: $configPath" -ForegroundColor Yellow
        $config = [PSCustomObject]@{}
        $dirty  = $true
    }
    if (-not ($config.PSObject.Properties.Name -contains $Section)) {
        Add-Member -InputObject $config -MemberType NoteProperty -Name $Section -Value $Defaults
        Write-Host "[dlScripts] Added [$Section] defaults to config.json  - edit to customise." -ForegroundColor Cyan
        $dirty = $true
    }
    if ($dirty) { $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8 }
    return $config.$Section
}

$cfg = Initialize-DlConfig -Section "anime" -Defaults ([PSCustomObject]@{
    qbitHost            = "http://localhost:8080"
    seriesDestination   = (Join-Path $HOME "Anime\Series")
    moviesDestination   = (Join-Path $HOME "Anime\Movies")
    maxResults          = 75
    autoAppendDualAudio = $true
    preferredUploaders  = @("judas", "cerebrus", "cleo", "animetime")
})

# Apply config defaults if not specified as parameters
if (-not $QbitHost)    { $QbitHost   = $cfg.qbitHost }
if ($MaxResults -eq 0) { $MaxResults = $cfg.maxResults }

# Resolve destination based on isAnimeSeries if not explicitly provided
if (-not $Destination) {
    $Destination = if ($isAnimeSeries -eq "no") { $cfg.moviesDestination } else { $cfg.seriesDestination }
}

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

$preferredUploaders = $cfg.preferredUploaders

$searchQuery = $Query

$dualAudioAppended = $false
if ($cfg.autoAppendDualAudio -and -not $Filter -and $searchQuery -inotmatch 'dual[\s\-_]*audio') {
    $searchQuery = "$Query dual audio"
    $dualAudioAppended = $true
    Write-Log "Automatically appending 'dual audio' to search query" "DEBUG"
} elseif ($Filter) {
    $searchQuery = "$Query $Filter"
}

$encodedQuery = [System.Web.HttpUtility]::UrlEncode($searchQuery)
$amp = [char]38
$filterParam = if ($TrustedOnly) { "f=2" } else { "f=0" }
$url = "https://nyaa.si/?$filterParam" + "$amp" + "c=0_0" + "$amp" + "q=$encodedQuery"

Write-Log "Starting anime download process" "INFO"
Write-Log "Search query: $searchQuery" "INFO"
Write-Log "Destination: $Destination" "INFO"
Write-Log "Trusted only: $TrustedOnly" "DEBUG"
Write-Log "URL: $url" "DEBUG"

# Fetches a nyaa.si search URL and returns an array of scored torrent objects.
function Invoke-NyaaSearch {
    param([string]$Url)
    $resp     = Invoke-WebRequest -Uri $Url -UseBasicParsing
    $html     = $resp.Content
    Write-Log "Received HTML response: $($html.Length) bytes" "DEBUG"

    $hQuot      = '&' + 'quot;'
    $hAmp       = '&' + 'amp;'
    $localAmp   = [char]38
    $rowPattern = '<tr\s+class="(?:success|default|danger)"[^>]*>(.*?)</tr>'
    $rowMatches = [regex]::Matches($html, $rowPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Write-Log "Found $($rowMatches.Count) potential matches in HTML" "DEBUG"

    $parsed = @()
    foreach ($rowMatch in $rowMatches) {
        $rowHtml = $rowMatch.Groups[1].Value

        $viewIdMatch     = [regex]::Match($rowHtml, 'href="/view/(\d+)"')
        $titleMatch      = [regex]::Match($rowHtml, 'href="/view/\d+" title="([^"]*)"')
        $downloadIdMatch = [regex]::Match($rowHtml, 'href="/download/(\d+)\.torrent"')
        $magnetMatch     = [regex]::Match($rowHtml, 'magnet:\?xt=urn:btih:([a-f0-9]+)')
        $cellMatches     = [regex]::Matches($rowHtml, '<td class="text-center"[^>]*>\s*([^<]+?)\s*</td>')

        if (-not $viewIdMatch.Success -or -not $titleMatch.Success -or $cellMatches.Count -lt 5) {
            Write-Log "Skipping row - incomplete data" "DEBUG"
            continue
        }

        $torrentName = $titleMatch.Groups[1].Value
        $torrentName = $torrentName.Replace($hQuot, '"')
        $torrentName = $torrentName.Replace($hAmp, '&')

        $seeders   = if ($cellMatches[2].Groups[1].Value.Trim() -match '^\d+$') { [int]$cellMatches[2].Groups[1].Value.Trim() } else { 0 }
        $leechers  = if ($cellMatches[3].Groups[1].Value.Trim() -match '^\d+$') { [int]$cellMatches[3].Groups[1].Value.Trim() } else { 0 }
        $downloads = if ($cellMatches[4].Groups[1].Value.Trim() -match '^\d+$') { [int]$cellMatches[4].Groups[1].Value.Trim() } else { 0 }

        $uploaderMatch = [regex]::Match($torrentName, '^\[([^\]]+)\]')
        $uploader = if ($uploaderMatch.Success) { $uploaderMatch.Groups[1].Value } else { "Unknown" }

        $isBatch             = $false
        $isIndividualEpisode = $false
        if ($torrentName -imatch '(Season\s+\d+|Season\s+0\d+|S\d{2}|S0\d+|\d+-\d+|Batch|Complete|Series|全集|整季)') {
            $isBatch = $true
            Write-Log "  Detected batch/season release" "DEBUG"
        } elseif ($torrentName -imatch '\s-\s\d+\s|\sEP?\d+\s|第\d+話|\s\d+\s\(') {
            $isIndividualEpisode = $true
            Write-Log "  Detected individual episode" "DEBUG"
        }

        $score = $seeders
        if ($isBatch)             { $score += 1000; Write-Log "  Batch bonus applied: +1000" "DEBUG" }
        if ($isIndividualEpisode) { $score -= 500;  Write-Log "  Individual episode penalty applied: -500" "DEBUG" }

        $isDualAudio = $torrentName -imatch 'dual[\s\-_]*audio'
        if ($isDualAudio) { $score += 100; Write-Log "  Found dual audio release: $uploader" "DEBUG" }

        $isPreferredUploader = $false
        foreach ($preferred in $preferredUploaders) {
            if ($uploader -imatch $preferred) {
                $isPreferredUploader = $true
                $score += 200
                Write-Log "  Found preferred uploader: $uploader (matched: $preferred)" "DEBUG"
                break
            }
        }

        $parsed += [PSCustomObject]@{
            ID                  = $viewIdMatch.Groups[1].Value
            Name                = $torrentName
            Uploader            = $uploader
            DownloadID          = $downloadIdMatch.Groups[1].Value
            InfoHash            = $magnetMatch.Groups[1].Value
            Size                = $cellMatches[0].Groups[1].Value.Trim()
            Date                = $cellMatches[1].Groups[1].Value.Trim()
            Seeders             = $seeders
            Leechers            = $leechers
            Downloads           = $downloads
            IsDualAudio         = $isDualAudio
            IsPreferredUploader = $isPreferredUploader
            IsBatch             = $isBatch
            IsIndividualEpisode = $isIndividualEpisode
            Score               = $score
            MagnetLink          = "magnet:?xt=urn:btih:$($magnetMatch.Groups[1].Value)${localAmp}dn=$([System.Web.HttpUtility]::UrlEncode($torrentName))"
        }
    }
    return $parsed
}

try {
    Write-Log "Fetching results from nyaa.si..." "INFO"
    $allTorrents = Invoke-NyaaSearch -Url $url

    if ($allTorrents.Count -eq 0) {
        Write-Log "No results found for: $searchQuery" "ERROR"
        exit 1
    }

    # If dual audio was auto-appended but none of the results are dual audio, retry without it
    if ($dualAudioAppended -and -not ($allTorrents | Where-Object { $_.IsDualAudio })) {
        Write-Log "No dual audio results found - retrying search without 'dual audio'..." "WARN"
        $fallbackQuery = if ($Filter) { "$Query $Filter" } else { $Query }
        $fallbackUrl   = "https://nyaa.si/?$filterParam" + "$amp" + "c=0_0" + "$amp" + "q=" + [System.Web.HttpUtility]::UrlEncode($fallbackQuery)
        Write-Log "Fallback search query: $fallbackQuery" "INFO"
        $fallbackTorrents = Invoke-NyaaSearch -Url $fallbackUrl
        if ($fallbackTorrents.Count -gt 0) {
            $allTorrents = $fallbackTorrents
            Write-Log "Fallback returned $($allTorrents.Count) results" "SUCCESS"
        } else {
            Write-Log "Fallback also returned no results" "WARN"
        }
    }

    Write-Log "Parsed $($allTorrents.Count) torrents successfully" "SUCCESS"

    if ($ListOnly) { $MaxResults = 100 }

    Write-Log "Sorting torrents by preference score..." "INFO"
    $sortedTorrents = $allTorrents | Sort-Object -Property Score -Descending

    Write-Log "Top 20 torrents by score:" "DEBUG"
    $topDebug = $sortedTorrents | Select-Object -First 20
    foreach ($td in $topDebug) {
        $debugTags = @()
        if ($td.IsBatch) { $debugTags += "BATCH" }
        if ($td.IsPreferredUploader) { $debugTags += "PREF" }
        if ($td.IsDualAudio) { $debugTags += "DUAL" }
        $tagStr = if ($debugTags.Count -gt 0) { " [" + ($debugTags -join ",") + "]" } else { "" }
        Write-Log "  Score $($td.Score): [$($td.Uploader)]$tagStr $($td.Name.Substring(0, [Math]::Min(60, $td.Name.Length)))..." "DEBUG"
    }

    $torrents = $sortedTorrents | Select-Object -First $MaxResults
    Write-Log "Selected top $($torrents.Count) torrents for display" "DEBUG"

    Write-Log "Displaying top $($torrents.Count) results..." "INFO"
    Write-Host ""

    for ($i = 0; $i -lt $torrents.Count; $i++) {
        $t = $torrents[$i]
        Write-Host "[$($i+1)] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($t.Name)" -ForegroundColor White

        $tags = @()
        if ($t.IsBatch) { $tags += "BATCH/SEASON" }
        if ($t.IsIndividualEpisode) { $tags += "SINGLE EPISODE" }
        if ($t.IsPreferredUploader) { $tags += "PREFERRED" }
        if ($t.IsDualAudio) { $tags += "DUAL AUDIO" }
        $tagString = if ($tags.Count -gt 0) { " [" + ($tags -join ", ") + "]" } else { "" }

        Write-Host "    Uploader: $($t.Uploader)$tagString" -ForegroundColor Cyan
        Write-Host "    Size: $($t.Size) | Seeds: $($t.Seeders) | Leech: $($t.Leechers) | DL: $($t.Downloads) | Score: $($t.Score)" -ForegroundColor Gray
        Write-Host ""
    }

    if ($ListOnly) {
        Write-Host ""
        Write-Host "--- MAGNET LINKS (top $($torrents.Count)) ---" -ForegroundColor Magenta
        for ($i = 0; $i -lt $torrents.Count; $i++) {
            $t = $torrents[$i]
            Write-Host "[$($i+1)] $($t.Name)" -ForegroundColor Yellow
            Write-Host "    Size: $($t.Size) | Seeds: $($t.Seeders) | Leech: $($t.Leechers) | Score: $($t.Score)" -ForegroundColor Gray
            Write-Host "    $($t.MagnetLink)" -ForegroundColor DarkCyan
            Write-Host ""
        }
        Write-Log "List-only mode: $($torrents.Count) results shown. Nothing added to qBittorrent." "SUCCESS"
        exit 0
    }

    $selectedIndex = 0
    if ($Interactive -and $torrents.Count -gt 1) {
        Write-Log "Interactive mode: waiting for user selection..." "INFO"
        Write-Host "Select torrent [1-$($torrents.Count)] or 0 to cancel: " -NoNewline -ForegroundColor Cyan
        $selection = Read-Host
        $selectedIndex = [int]$selection - 1

        if ($selectedIndex -lt 0 -or $selectedIndex -ge $torrents.Count) {
            Write-Log "User cancelled selection" "WARN"
            exit 0
        }
        Write-Log "User selected torrent #$($selectedIndex + 1)" "INFO"
    } else {
        Write-Log "Auto-selecting top-scored torrent" "INFO"
    }

    $selectedTorrent = $torrents[$selectedIndex]

    Write-Log "Selected torrent: $($selectedTorrent.Name)" "SUCCESS"
    Write-Log "  Uploader: $($selectedTorrent.Uploader)" "DEBUG"
    Write-Log "  Score: $($selectedTorrent.Score)" "DEBUG"
    Write-Log "  Seeders: $($selectedTorrent.Seeders)" "DEBUG"
    Write-Log "  Batch/Season: $($selectedTorrent.IsBatch)" "DEBUG"
    Write-Log "  Individual Episode: $($selectedTorrent.IsIndividualEpisode)" "DEBUG"
    Write-Log "  Dual Audio: $($selectedTorrent.IsDualAudio)" "DEBUG"
    Write-Log "  Preferred Uploader: $($selectedTorrent.IsPreferredUploader)" "DEBUG"
    Write-Host ""

    Write-Log "Adding torrent to qBittorrent at $QbitHost..." "INFO"

    $body = @{
        urls = $selectedTorrent.MagnetLink
        savepath = $Destination
    }

    Write-Log "Sending POST request to qBittorrent API..." "DEBUG"
    $addResponse = Invoke-WebRequest -Uri "$QbitHost/api/v2/torrents/add" -Method POST -Body $body -UseBasicParsing

    if ($addResponse.StatusCode -eq 200) {
        Write-Log "Successfully added torrent to qBittorrent!" "SUCCESS"
        Write-Log "  Destination: $Destination" "INFO"
        Write-Log "  Name: $($selectedTorrent.Name)" "INFO"
        Write-Log "  Size: $($selectedTorrent.Size)" "INFO"
        Write-Log "  Seeds: $($selectedTorrent.Seeders)" "INFO"
        Write-Log "  Uploader: $($selectedTorrent.Uploader)" "INFO"
        Write-Host ""

        $result = $selectedTorrent | ConvertTo-Json
        Write-Log "Process completed successfully" "SUCCESS"
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
