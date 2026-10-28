# dltv.ps1
# Search TV shows and add torrents to qBittorrent, or download them from KissKH.
# Configuration sourced from %LOCALAPPDATA%\dlScripts\config.json
#
# Sources: The Pirate Bay (torrent, the default) and KissKH (direct download in a background
# job). -Asian goes straight to KissKH; otherwise KissKH is the fallback when the best torrent
# is weak. -JobFile is the background worker's own entry point.

param(
    [Parameter(Mandatory=$false)]
    [string]$Query = "",

    [Parameter(Mandatory=$false)]
    [string]$Destination = "",

    [Parameter(Mandatory=$false)]
    [string]$QbitHost = "",

    [Parameter(Mandatory=$false)]
    [int]$MaxResults = 0,

    [Parameter(Mandatory=$false)]
    [switch]$Interactive = $false,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,

    # Go straight to KissKH, skip TPB, never fall back to it.
    [Parameter(Mandatory=$false)]
    [switch]$Asian = $false,

    # KissKH only: 3, 1-4 or 5- (from 5 to the end). Default is every released episode.
    [Parameter(Mandatory=$false)]
    [string]$Episodes = "",

    # Show one job / list jobs.
    [Parameter(Mandatory=$false)]
    [string]$Status = "",

    [Parameter(Mandatory=$false)]
    [switch]$Jobs = $false,

    # Internal: the worker spawned by a KissKH download.
    [Parameter(Mandatory=$false)]
    [string]$JobFile = ""
)

# Shared resolver library: Initialize-DlConfig, Resolve-MediaPath, Get-DriveMetaInventory.
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib/DriveResolver.ps1")
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib/Detach.ps1")
. (Join-Path $PSScriptRoot "KissKH.ps1")
. (Join-Path $PSScriptRoot "Jobs.ps1")
. (Join-Path $PSScriptRoot "Download.ps1")

$cfg = Initialize-DlConfig -Section "tv" -Defaults ([PSCustomObject]@{
    qbitHost         = "http://localhost:8080"
    destination      = (Join-DlPath (Get-DlHomeDir) "TV")
    maxResults       = 50
    useDriveMetadata = $true
    minSeeders       = 5
    kisskhFallback   = $true
    kisskhBaseUrl    = "https://kisskh.co"
    kisskhSubLangs   = @("en")
    jobKeepDays      = 7
    kisskhMaxEpisodeGB = 8
})

# Apply config defaults if not specified
if (-not $QbitHost)    { $QbitHost    = $cfg.qbitHost }
if ($MaxResults -eq 0) { $MaxResults  = $cfg.maxResults }

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

# --- Job modes: no query, no destination, no search ---------------------------

if ($JobFile) {
    if (-not (Test-Path -LiteralPath $JobFile)) { Write-Log "Worker: job file not found: $JobFile" 'ERROR'; exit 1 }
    $workerJob = Read-DltvJobFile $JobFile
    if (-not $workerJob) { Write-Log "Worker: job file is unreadable: $JobFile" 'ERROR'; exit 1 }
    try { Invoke-DltvKissKHWorker -Job $workerJob }
    catch {
        Write-Log "Worker crashed: $($_.Exception.Message)" 'ERROR'
        Complete-DltvJob -Job $workerJob -Message "worker crashed: $($_.Exception.Message)"
        exit 1
    }
    exit 0
}

if ($Jobs) {
    Remove-OldDltvJobs -KeepDays ([int]$cfg.jobKeepDays)
    Show-DltvJobList
    exit 0
}

if ($Status) {
    Remove-OldDltvJobs -KeepDays ([int]$cfg.jobKeepDays)
    if (Show-DltvJobStatus -JobId $Status) { exit 0 }
    exit 1
}

if (-not $Query -or -not $Query.Trim()) {
    Write-Log "A show name is required (or use --jobs / --status ID)." 'ERROR'
    exit 1
}

if ($Episodes) {
    try { [void](ConvertFrom-DltvEpisodeRange $Episodes) }
    catch { Write-Log $_.Exception.Message 'ERROR'; exit 1 }
}

# Resolve destination:
#   -Destination CLI > drive-meta resolver (when useDriveMetadata) > cfg.destination > $HOME fallback.
if ($Destination) {
    $destRoot = [System.IO.Path]::GetPathRoot($Destination)
    if ($destRoot -and -not (Test-Path $destRoot)) {
        Write-Error "Destination drive '$destRoot' is not connected. Refusing to send torrent to a dead drive."
        exit 1
    }
} elseif ($cfg.useDriveMetadata) {
    $Destination = Resolve-MediaPath -MediaType 'tv' -FallbackPath $cfg.destination
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

# --- KissKH source ------------------------------------------------------------

# Search KissKH and choose a drama. Strict matching requires an exact title; non-strict ranks
# looser matches. With -Interactive the candidates are listed and the user picks. Returns the
# search result, or $null when nothing matches. Throws if KissKH cannot be reached.
function Get-DltvKissKHCandidate {
    param([string]$Query, [switch]$Strict, [switch]$Interactive, [string]$BaseUrl)

    Write-Log "Searching KissKH for: $Query" "INFO"
    $results = @(Search-KissKHDrama -Query $Query -BaseUrl $BaseUrl)
    Write-Log "KissKH returned $($results.Count) results" "DEBUG"

    $cands = @(Get-DltvKissKHMatches -Query $Query -Results $results -Strict:$Strict)
    if ($Interactive -and $cands.Count -eq 0 -and $results.Count -gt 0) {
        Write-Log "No close KissKH match; listing every result" "WARN"
        $cands = $results
    }
    if ($cands.Count -eq 0) { return $null }

    if ($Interactive) {
        Write-Host ""
        for ($i = 0; $i -lt $cands.Count; $i++) {
            $m = $cands[$i]
            Write-Host "[$($i+1)] " -NoNewline -ForegroundColor Yellow
            Write-Host "$($m.title)" -ForegroundColor White
            Write-Host "    Episodes: $($m.episodesCount) | Id: $($m.id)" -ForegroundColor Cyan
            Write-Host ""
        }
        if ($cands.Count -gt 1) {
            Write-Host "Select drama [1-$($cands.Count)] or 0 to cancel: " -NoNewline -ForegroundColor Cyan
            $idx = [int](Read-Host) - 1
            if ($idx -lt 0 -or $idx -ge $cands.Count) {
                Write-Log "Cancelled" "WARN"
                exit 0
            }
            Write-Log "User selected #$($idx + 1)" "INFO"
            return $cands[$idx]
        }
    }
    return $cands[0]
}

# Resolve the episode list and either print the plan (-DryRun) or create a job and spawn the
# detached worker. Returns the result JSON, or $null when there is nothing to download.
function Start-DltvKissKHDownload {
    param($Candidate, [string]$Destination, [string]$Range, [string]$BaseUrl, [string[]]$SubLangs, [double]$MaxEpisodeGB = 8, [switch]$DryRun)

    $drama = Get-KissKHDrama -Id ([long]$Candidate.id) -BaseUrl $BaseUrl
    $title = [string]$drama.title
    if (-not $title) { $title = [string]$Candidate.title }
    $sel = Select-KissKHEpisodes -Drama $drama -Range $Range
    if ($sel.Skipped -gt 0) {
        Write-Log "Skipped $($sel.Skipped) fractional episode(s) (recaps/specials)" "INFO"
    }
    $eps = @($sel.Episodes)
    if ($eps.Count -eq 0) {
        Write-Log "No episodes to download for $title$(if ($Range) { " in range $Range" })" "ERROR"
        return $null
    }
    $folder = Join-DlPath $Destination (Get-DltvSafeName $title)

    if ($DryRun) {
        Write-Host ""
        Write-Host "  Title:    $title" -ForegroundColor White
        Write-Host "  Id:       $($drama.id)" -ForegroundColor Cyan
        Write-Host "  Country:  $($drama.country)" -ForegroundColor Cyan
        Write-Host "  Status:   $($drama.status)" -ForegroundColor Cyan
        Write-Host "  Episodes: $($eps.Count) (E$('{0:D2}' -f $eps[0].Number)-E$('{0:D2}' -f $eps[-1].Number))" -ForegroundColor Cyan
        Write-Host "  Folder:   $folder" -ForegroundColor Cyan
        Write-Host ""
        Write-Log "[DRY RUN] would start a background job to download $($eps.Count) episodes" "INFO"
        $jobId = $null
    } else {
        $job = New-DltvJob -Title $title -DramaId ([long]$drama.id) -BaseUrl $BaseUrl `
                           -Destination $folder -Episodes $eps -SubLangs $SubLangs -MaxEpisodeGB $MaxEpisodeGB
        $scriptPath = Join-Path $PSScriptRoot 'Add-TV.ps1'
        [void](Start-DltvJob -Job $job -ScriptPath $scriptPath)
        Write-Log "Background job started: $title ($($eps.Count) episodes)" "SUCCESS"
        Write-Host "  Job ID:   $($job.id)" -ForegroundColor Yellow
        Write-Host "  Check:    dltv --status $($job.id)"
        Write-Host ""
        $jobId = $job.id
    }

    return ([PSCustomObject]@{
        source      = 'kisskh'
        title       = $title
        dramaId     = [long]$drama.id
        episodes    = $eps.Count
        destination = $folder
        jobId       = $jobId
    } | ConvertTo-Json)
}

# --- TPB source ---------------------------------------------------------------

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

# Search TPB and return the safe torrents, unsorted. Returns an empty array - never exits - so
# the caller can fall back to KissKH; a failed search is logged and treated as no results.
function Search-DltvTpb {
    param([string]$Query)

    $encodedQuery = [System.Web.HttpUtility]::UrlEncode($Query)
    $apiUrl = "https://apibay.org/q.php?q=$encodedQuery&cat=200"
    Write-Log "API: $apiUrl" "DEBUG"

    try {
        Write-Log "Fetching results from The Pirate Bay API..." "INFO"

        # 'curl.exe' does not exist on Linux, where the binary is plain 'curl' - dltv is one of
        # the commands reachable on the Deck, so the name has to be resolved rather than assumed.
        $curl = Get-DlCurlPath

        $json = & $curl -s $apiUrl
        if ($LASTEXITCODE -ne 0 -or -not $json) {
            throw "curl failed with exit code $LASTEXITCODE"
        }

        $results = @(ConvertFrom-DltvJsonList ([string]($json -join "`n")))
        Write-Log "API returned $($results.Count) results" "DEBUG"

        if ($results.Count -eq 1 -and $results[0].id -eq "0") {
            Write-Log "No results found for: $Query" "WARN"
            return @()
        }

        $found = @()
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

            $found += [PSCustomObject]@{
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

        if ($found.Count -eq 0) {
            Write-Log "All results were blocked by safety filters, or the site returned no results." "WARN"
        } else {
            Write-Log "Found $($found.Count) valid torrents after safety filtering" "SUCCESS"
        }
        return $found
    } catch {
        Write-Log "TPB search failed: $($_.Exception.Message)" "WARN"
        Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
        return @()
    }
}

# --- Main ---------------------------------------------------------------------

Write-Log "Starting TV show download process" "INFO"
Write-Log "Search query: $Query" "INFO"
Write-Log "Destination: $Destination" "INFO"

$kkBase    = Get-KissKHBaseUrl ([string]$cfg.kisskhBaseUrl)
$kkLangs   = @($cfg.kisskhSubLangs)

# -Asian: KissKH only, loose matching, and no TPB fallback if it finds nothing.
if ($Asian) {
    try {
        $candidate = Get-DltvKissKHCandidate -Query $Query -Interactive:$Interactive -BaseUrl $kkBase
        if (-not $candidate) {
            Write-Log "No KissKH match for: $Query" "ERROR"
            exit 1
        }
        Remove-OldDltvJobs -KeepDays ([int]$cfg.jobKeepDays)
        $kkJson = Start-DltvKissKHDownload -Candidate $candidate -Destination $Destination -Range $Episodes `
                                           -BaseUrl $kkBase -SubLangs $kkLangs -MaxEpisodeGB ([double]$cfg.kisskhMaxEpisodeGB) -DryRun:$DryRun
    } catch {
        Write-Log "KissKH failed: $($_.Exception.Message)" "ERROR"
        Write-Log "Stack trace: $($_.ScriptStackTrace)" "DEBUG"
        exit 1
    }
    if (-not $kkJson) { exit 1 }
    return $kkJson
}

try {
    $torrents = @(Search-DltvTpb -Query $Query | Sort-Object Score -Descending | Select-Object -First $MaxResults)

    # Weak or absent torrents fall back to KissKH, unless the user is choosing by hand. Strict
    # matching keeps a western show with weak seeds from grabbing an unrelated Asian drama.
    $fallbackReason = $null
    if ($cfg.kisskhFallback -and -not $Interactive) {
        $fallbackReason = Test-DltvKissKHFallback -Torrents $torrents -MinSeeders ([int]$cfg.minSeeders)
    }
    if ($fallbackReason) {
        $candidate = $null
        try {
            $candidate = Get-DltvKissKHCandidate -Query $Query -Strict -BaseUrl $kkBase
        } catch {
            Write-Log "KissKH lookup failed: $($_.Exception.Message)" "WARN"
        }
        if ($candidate) {
            Write-Log "$fallbackReason; using KissKH: $($candidate.title) ($($candidate.episodesCount) episodes)" "WARN"
            Remove-OldDltvJobs -KeepDays ([int]$cfg.jobKeepDays)
            $kkJson = Start-DltvKissKHDownload -Candidate $candidate -Destination $Destination -Range $Episodes `
                                               -BaseUrl $kkBase -SubLangs $kkLangs -MaxEpisodeGB ([double]$cfg.kisskhMaxEpisodeGB) -DryRun:$DryRun
            if (-not $kkJson) { exit 1 }
            return $kkJson
        }
        if ($torrents.Count -gt 0) {
            Write-Log "$fallbackReason, and KissKH has no exact match; continuing with the torrent" "WARN"
        }
    }

    if ($torrents.Count -eq 0) {
        Write-Log "No valid TV show torrents found for: $Query" "ERROR"
        exit 1
    }

    if ($Episodes) {
        Write-Log "-Episodes only applies to KissKH; ignored for a torrent" "WARN"
    }

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
