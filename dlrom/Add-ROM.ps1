# Add-ROM.ps1
# Download ROMs from cdromance.org via Motrix
# Usage: dlrom "Game Name" [--platform ps2] [--region usa] [--interactive]
# Configuration sourced from %LOCALAPPDATA%\dlScripts\config.json

param(
    [Parameter(Mandatory=$true)]
    [string]$Query,

    [Parameter(Mandatory=$false)]
    [string]$Platform = "",

    [Parameter(Mandatory=$false)]
    [string]$Region = "",

    [Parameter(Mandatory=$false)]
    [string]$Sort = "",

    [Parameter(Mandatory=$false)]
    [string]$Destination = "",

    [Parameter(Mandatory=$false)]
    [int]$MaxResults = 0,

    [Parameter(Mandatory=$false)]
    [switch]$Interactive = $false,

    [Parameter(Mandatory=$false)]
    [switch]$NoExtract = $false,

    [Parameter(Mandatory=$false)]
    [switch]$NoSteam = $false
)

Add-Type -AssemblyName System.Web

# Shared resolver library (sibling lib/). Dot-sourced for Resolve-MediaPath, which
# backs the ROM destination drive-picker fallback when the configured base is absent.
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\DriveResolver.ps1")

# ─── Logging ─────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'INFO'    { 'Cyan' }
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'DEBUG'   { 'Gray' }
        default   { 'White' }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

# ─── Config ──────────────────────────────────────────────────────────────────

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
            Write-Host "[dlScripts] config.json could not be parsed - [$Section] defaults will be written." -ForegroundColor Yellow
            $config = [PSCustomObject]@{}
            $dirty  = $true
        }
    } else {
        Write-Host "[dlScripts] Config not found - creating: $configPath" -ForegroundColor Yellow
        $config = [PSCustomObject]@{}
        $dirty  = $true
    }
    if (-not ($config.PSObject.Properties.Name -contains $Section)) {
        Add-Member -InputObject $config -MemberType NoteProperty -Name $Section -Value $Defaults
        Write-Host "[dlScripts] Added [$Section] defaults to config.json - edit to customise." -ForegroundColor Cyan
        $dirty = $true
    } else {
        $existing = $config.$Section
        foreach ($prop in $Defaults.PSObject.Properties) {
            if (-not ($existing.PSObject.Properties.Name -contains $prop.Name)) {
                Add-Member -InputObject $existing -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
                Write-Host "[dlScripts] Backfilled missing key [$Section.$($prop.Name)] in config.json" -ForegroundColor Cyan
                $dirty = $true
            }
        }
    }
    if ($dirty) { $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8 }
    return $config.$Section
}

# ─── Motrix RPC (adapted from dlmotrix) ──────────────────────────────────────

function ConvertFrom-RpcResponse {
    param($Content)
    $str = if ($Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($Content) } else { [string]$Content }
    return $str | ConvertFrom-Json
}

function Invoke-MotrixRpc {
    param([string]$Method, [object[]]$Params = @())
    $body = @{ jsonrpc = '2.0'; id = '1'; method = $Method; params = $Params } | ConvertTo-Json -Depth 10
    $resp = Invoke-WebRequest -Uri $script:MOTRIX_URL -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
    $json = ConvertFrom-RpcResponse $resp.Content
    if ($json.error) { throw "Motrix RPC error ($Method): $($json.error.message)" }
    return $json.result
}

function Format-Bytes {
    param([long]$B)
    if ($B -ge 1GB) { return '{0:F2} GB' -f ($B / 1GB) }
    if ($B -ge 1MB) { return '{0:F1} MB' -f ($B / 1MB) }
    if ($B -ge 1KB) { return '{0:F1} KB' -f ($B / 1KB) }
    return "$B B"
}

function Format-Speed {
    param([long]$Bps)
    if ($Bps -eq 0) { return '--' }
    return "$(Format-Bytes $Bps)/s"
}

# ─── Downloader Detection ─────────────────────────────────────────────────────

function Test-MotrixRunning {
    try {
        $body = @{ jsonrpc = '2.0'; id = '1'; method = 'aria2.getVersion'; params = @() } | ConvertTo-Json -Depth 5
        $resp = Invoke-WebRequest -Uri $script:MOTRIX_URL -Method POST -Body $body `
            -ContentType 'application/json' -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $json = ConvertFrom-RpcResponse $resp.Content
        return (-not $json.error -and $null -ne $json.result)
    } catch { return $false }
}

# AB Download Manager exposes a local HTTP integration API (default port 15151).
# POST /ping -> "pong"; POST /add { items:[{link,downloadPage,headers,description,suggestedName,type}], options:{silentAdd,silentStart} }.
# It has no completion/status API, so callers watch its download folder for the finished file.
function Test-AbRunning {
    $port = if ($script:AB_PORT) { $script:AB_PORT } else { 15151 }
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/ping" -Method POST -Body 'null' `
            -ContentType 'application/json' -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $txt = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
        return ($txt -match '(?i)pong')
    } catch { return $false }
}

function Add-AbDownload {
    param([string]$Url, [string]$SuggestedName = $null, [string]$Referer = $null, [hashtable]$Headers = $null)
    $port = if ($script:AB_PORT) { $script:AB_PORT } else { 15151 }
    $item = [ordered]@{
        link          = $Url
        downloadPage  = $Referer
        headers       = $Headers
        description   = $null
        suggestedName = $SuggestedName
        type          = 'http'
    }
    $body = @{ items = @($item); options = @{ silentAdd = $true; silentStart = $true } } | ConvertTo-Json -Depth 6
    Invoke-WebRequest -Uri "http://127.0.0.1:$port/add" -Method POST -Body $body `
        -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
}

function Find-Downloader {
    if (Test-MotrixRunning)                                           { return 'motrix'    }
    if (Test-AbRunning)                                               { return 'ab'        }
    if (Get-Command 'aria2c.exe' -ErrorAction SilentlyContinue)      { return 'aria2c'    }
    if (Get-Command 'aria2c'     -ErrorAction SilentlyContinue)      { return 'aria2c'    }
    if (Get-Command 'curl.exe'   -ErrorAction SilentlyContinue)      { return 'curl'      }
    if (Get-Command 'Start-BitsTransfer' -ErrorAction SilentlyContinue) { return 'bits'   }
    return 'webclient'
}

# ─── Platform Tables ──────────────────────────────────────────────────────────

$PLATFORM_SLUGS = @{
    "ps2"       = "ps2-iso"
    "ps1"       = "psx-iso"
    "psx"       = "psx-iso"
    "psp"       = "psp"
    "vita"      = "vita"
    "n64"       = "n64-roms"
    "gamecube"  = "gamecube"
    "gc"        = "gamecube"
    "nds"       = "nds-roms"
    "ds"        = "nds-roms"
    "gba"       = "gba"
    "snes"      = "snes-roms"
    "nes"       = "nes-roms"
    "gbc"       = "gbc-roms"
    "gb"        = "gb-roms"
    "dreamcast" = "dreamcast"
    "dc"        = "dreamcast"
    "saturn"    = "saturn"
    "wii"       = "wii"
    "3ds"       = "3ds-roms"
}

# Folder names match EmuDeck's roms layout so its emulators and Steam ROM Manager
# parsers both see the files (e.g. PS1 lives in 'psx', GameCube in 'gc').
$PLATFORM_FOLDERS = @{
    "ps2-iso"   = "ps2"
    "psx-iso"   = "psx"
    "psp"       = "psp"
    "vita"      = "psvita"
    "n64-roms"  = "n64"
    "gamecube"  = "gc"
    "nds-roms"  = "nds"
    "gba"       = "gba"
    "snes-roms" = "snes"
    "nes-roms"  = "nes"
    "gbc-roms"  = "gbc"
    "gb-roms"   = "gb"
    "dreamcast" = "dreamcast"
    "saturn"    = "saturn"
    "wii"       = "wii"
    "3ds-roms"  = "n3ds"
}

# ─── Archive Helpers ──────────────────────────────────────────────────────────

function Find-7zip {
    $fromPath = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    $pf   = Join-Path $env:ProgramFiles "7-Zip\7z.exe"
    $pf86 = Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe"
    if (Test-Path $pf)   { return $pf }
    if (Test-Path $pf86) { return $pf86 }
    return $null
}

function Get-ArchiveType {
    param([string]$FilePath)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $head  = ($bytes | Select-Object -First 8 | ForEach-Object { $_.ToString("X2") }) -join ""
        if ($head -match "^504B")       { return "zip" }
        if ($head -match "^377ABCAF")   { return "7z"  }
        if ($head -match "^526172211A") { return "rar" }
    } catch { }
    $ext = [System.IO.Path]::GetExtension($FilePath).TrimStart('.').ToLower()
    if ($ext -in @("7z", "rar", "zip")) { return $ext }
    return "zip"
}

# ─── CDRomance Scraping ───────────────────────────────────────────────────────

$HTTP_HEADERS = @{
    'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    'Accept-Language' = 'en-US,en;q=0.5'
}

function Extract-LinksFromHtml {
    param([string]$Html)
    $links = @()
    $archExts = '7z|zip|rar|iso|bin|img|chd|pbp'

    # Primary: anchor text is the filename (matches how CDRomance tables are structured)
    $pattern = '<a[\s\S]+?href="([^"]+)"[^>]*>\s*([^<]+\.' + '(' + $archExts + '))\s*</a>'
    $found = [regex]::Matches($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $found) {
        $url   = $m.Groups[1].Value.Trim()
        $label = [System.Web.HttpUtility]::HtmlDecode($m.Groups[2].Value.Trim())
        if ($url -match '^https?://') {
            $links += [PSCustomObject]@{ Label = $label; Url = $url }
        }
    }
    if ($links.Count -gt 0) { return $links }

    # Fallback: href itself ends with an archive extension
    $pattern2 = '<a[\s\S]+?href="([^"]+\.' + '(' + $archExts + ')(?:\?[^"]*)?)"[^>]*>([^<]*)</a>'
    $found2 = [regex]::Matches($Html, $pattern2, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $found2) {
        $url   = $m.Groups[1].Value.Trim()
        $label = [System.Web.HttpUtility]::HtmlDecode($m.Groups[3].Value.Trim())
        if (-not $label) { $label = [System.IO.Path]::GetFileName($url) }
        if ($url -match '^https?://') {
            $links += [PSCustomObject]@{ Label = $label; Url = $url }
        }
    }
    return $links
}

function Invoke-CdromanceSearch {
    param(
        [string]$SearchQuery,
        [string]$PlatformSlug = "",
        [string]$SearchRegion = "",
        [string]$SearchSort   = ""
    )

    $encoded = [System.Web.HttpUtility]::UrlEncode($SearchQuery)
    $url = "https://cdromance.org/?s=$encoded"
    if ($PlatformSlug)  { $url += "&platform=$PlatformSlug" }
    if ($SearchRegion)  { $url += "&region=$([System.Web.HttpUtility]::UrlEncode($SearchRegion))" }
    if ($SearchSort)    { $url += "&sorted=$([System.Web.HttpUtility]::UrlEncode($SearchSort))" }

    Write-Log "Searching: $url" 'DEBUG'

    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $HTTP_HEADERS -UseBasicParsing -ErrorAction Stop
    } catch {
        $code = $_.Exception.Response.StatusCode.Value__
        if ($code -in @(403, 503)) {
            Write-Log "Cloudflare blocked the request (HTTP $code)." 'ERROR'
            Write-Log "Open https://cdromance.org in your browser first, then re-run." 'WARN'
            exit 1
        }
        Write-Log "Search failed: $($_.Exception.Message)" 'ERROR'
        exit 1
    }

    $html    = $resp.Content
    $results = @()

    # Parse WordPress article cards: <article class="...post...">...</article>
    $articleMatches = [regex]::Matches($html, '(?si)<article\b[^>]*class="[^"]*post[^"]*"[^>]*>(.*?)</article>')
    foreach ($m in $articleMatches) {
        $inner     = $m.Groups[1].Value
        $linkMatch = [regex]::Match($inner, 'href="(https://cdromance\.org/([a-z0-9-]+)/[^/"]+/)"[^>]*>([^<]+)</a>')
        if (-not $linkMatch.Success) { continue }

        $gameUrl  = $linkMatch.Groups[1].Value.Trim()
        $platSlug = $linkMatch.Groups[2].Value.Trim()
        $title    = [System.Web.HttpUtility]::HtmlDecode(($linkMatch.Groups[3].Value -replace '\s+', ' ').Trim())

        if ($title -and $gameUrl -notmatch '/page/') {
            $results += [PSCustomObject]@{ Title = $title; Url = $gameUrl; Platform = $platSlug }
        }
    }

    # Fallback: scan for cdromance.org game page URLs if article parsing returned nothing
    if ($results.Count -eq 0) {
        Write-Log "Article parsing found nothing; falling back to URL scan." 'DEBUG'
        $seen = @{}
        $urlMatches = [regex]::Matches($html, 'href="(https://cdromance\.org/([a-z0-9-]+)/[^/"]+/)"[^>]*>([^<]+)</a>')
        foreach ($m in $urlMatches) {
            $gameUrl  = $m.Groups[1].Value.Trim()
            $platSlug = $m.Groups[2].Value.Trim()
            $title    = [System.Web.HttpUtility]::HtmlDecode(($m.Groups[3].Value -replace '\s+', ' ').Trim())
            if (-not $seen.ContainsKey($gameUrl) -and $platSlug -notin @('page','category','tag','author','guides','news','reviews','cdn-cgi','wp-content') -and $title) {
                $seen[$gameUrl] = $true
                $results += [PSCustomObject]@{ Title = $title; Url = $gameUrl; Platform = $platSlug }
            }
        }
    }

    # Fallback 2: cover-link grid layout (no <article> tags, title in <div class="game-title">)
    if ($results.Count -eq 0) {
        Write-Log "Grid parsing found nothing; trying cover-link layout." 'DEBUG'
        $seen = @{}
        $coverPatA = 'class="cover-link"[^>]*href="(https://cdromance\.org/([a-z0-9-]+)/[^/"]+/)"'
        $coverPatB = 'href="(https://cdromance\.org/([a-z0-9-]+)/[^/"]+/)"[^>]*class="cover-link"'
        $coverMatches = @([regex]::Matches($html, $coverPatA, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) +
                        @([regex]::Matches($html, $coverPatB, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
        foreach ($m in $coverMatches) {
            $gameUrl = $m.Groups[1].Value.Trim()
            $platSlug = $m.Groups[2].Value.Trim()
            if ($platSlug -in @('page','category','tag','author','guides','news','reviews','cdn-cgi','wp-content')) { continue }
            if ($gameUrl -match '/page/') { continue }
            if ($seen.ContainsKey($gameUrl)) { continue }
            # Extract title from <div class="game-title"> within this <a> block
            $after = $html.Substring($m.Groups[0].Index, [Math]::Min(800, $html.Length - $m.Groups[0].Index))
            $titleMatch = [regex]::Match($after, 'class="game-title"[^>]*>([^<]+)<')
            $title = ""
            if ($titleMatch.Success) {
                $title = [System.Web.HttpUtility]::HtmlDecode($titleMatch.Groups[1].Value.Trim())
            }
            if ($title) {
                $seen[$gameUrl] = $true
                $results += [PSCustomObject]@{ Title = $title; Url = $gameUrl; Platform = $platSlug }
            }
        }
    }

    return $results
}

function Get-DownloadLinks {
    param([string]$GamePageUrl)

    $headers = $HTTP_HEADERS.Clone()
    $headers['Referer'] = 'https://cdromance.org/'

    Write-Log "Fetching game page..." 'INFO'
    try {
        $resp = Invoke-WebRequest -Uri $GamePageUrl -Headers $headers -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Log "Failed to fetch game page: $($_.Exception.Message)" 'ERROR'
        return @()
    }
    $html = $resp.Content

    # Strategy A: ticket POST (replicates the "SHOW LINKS" button click server-side)
    $ticketMatch = [regex]::Match($html, '<span\s+id="obfuscatedId"\s*>(\d+)</span>')
    if ($ticketMatch.Success) {
        $ticket = $ticketMatch.Groups[1].Value
        Write-Log "Found ticket: $ticket" 'DEBUG'

        $postHeaders = $headers.Clone()
        $postHeaders['Content-Type'] = 'application/x-www-form-urlencoded'
        $postHeaders['Referer']      = $GamePageUrl

        try {
            $ticketResp = Invoke-WebRequest -Uri 'https://cdromance.org/' -Method POST `
                -Body "cdrTicketInput=$ticket" -Headers $postHeaders -UseBasicParsing -ErrorAction Stop
            $links = @(Extract-LinksFromHtml $ticketResp.Content)
            if ($links.Count -gt 0) {
                Write-Log "Strategy A (ticket POST) found $($links.Count) link(s)." 'DEBUG'
                return $links
            }
        } catch {
            Write-Log "Ticket POST failed: $($_.Exception.Message)" 'DEBUG'
        }
    }

    # Strategy B: ACF data-id → cdr-main/ajax.php
    $acfMatch = [regex]::Match($html, 'id="acf-content-wrapper"[^>]*data-id="([^"]+)"')
    if (-not $acfMatch.Success) {
        $acfMatch = [regex]::Match($html, 'data-id="([^"]+)"[^>]*id="acf-content-wrapper"')
    }
    if ($acfMatch.Success) {
        $postId = $acfMatch.Groups[1].Value
        Write-Log "ACF wrapper found: id=$postId" 'DEBUG'

        $apiHeaders = $headers.Clone()
        $apiHeaders['Content-Type']   = 'application/x-www-form-urlencoded'
        $apiHeaders['Referer']        = $GamePageUrl
        $apiHeaders['X-Requested-With'] = 'XMLHttpRequest'

        try {
            $apiResp = Invoke-WebRequest -Uri 'https://cdromance.org/wp-content/plugins/cdr-main/public/ajax.php' `
                -Method POST -Body "post_id=$postId" -Headers $apiHeaders -UseBasicParsing -ErrorAction Stop
            Write-Log "AJAX response length: $($apiResp.Content.Length)" 'DEBUG'
            $links = @(Extract-LinksFromHtml $apiResp.Content)
            Write-Log "Extracted $($links.Count) links from AJAX response" 'DEBUG'
            if ($links.Count -gt 0) {
                Write-Log "Strategy B (cdr-main ajax.php) found $($links.Count) link(s)." 'DEBUG'
                return $links
            }
        } catch {
            Write-Log "cdr-main ajax.php POST failed: $($_.Exception.Message)" 'DEBUG'
        }
    }

    # Strategy C: raw href scan on the original game page
    Write-Log "Falling back to raw href scan on game page." 'DEBUG'
    return @(Extract-LinksFromHtml $html)
}

function Select-DownloadLinks {
    param([object[]]$Links)

    if ($Links.Count -eq 0) { return @() }

    # Phase 1: filter demos
    $filtered = @($Links | Where-Object { $_.Label -notmatch '(?i)\b(demo|trial|sampler|preview)\b' })
    if ($filtered.Count -eq 0) {
        Write-Log "All links appear to be demos; taking first link as fallback." 'WARN'
        return @($Links[0])
    }

    # Phase 2: prefer English/patched/undub variants
    $englishPat = '(?i)\b(english|undub|undubbed|patched|dub)\b|\(eng\)'
    $english    = @($filtered | Where-Object { $_.Label -imatch $englishPat })
    $working    = if ($english.Count -gt 0) {
        Write-Log "English/patched variant(s) detected: $($english.Count) link(s)" 'DEBUG'
        $english
    } else {
        $filtered
    }

    # Phase 2b: prefer USA/NTSC-U region
    $usaPat = '(?i)\busa\b'
    $usa    = @($working | Where-Object { $_.Label -imatch $usaPat })
    if ($usa.Count -gt 0) {
        Write-Log "USA variant(s) detected: $($usa.Count) link(s)" 'DEBUG'
        $working = $usa
    }

    # Phase 3: multi-disc detection — return one link per disc number
    $discPat   = '(?i)\b(?:disc|disk|cd)\s*(\d+)\b'
    $discLinks = @($working | Where-Object { $_.Label -imatch $discPat })

    if ($discLinks.Count -ge 2) {
        $discGroups = @{}
        foreach ($link in $discLinks) {
            if ($link.Label -imatch $discPat) {
                $dn = $Matches[1]
                if (-not $discGroups.ContainsKey($dn)) { $discGroups[$dn] = $link }
            }
        }
        if ($discGroups.Count -ge 2) {
            $sorted = @($discGroups.Keys | Sort-Object { [int]$_ } | ForEach-Object { $discGroups[$_] })
            Write-Log "Multi-disc: $($sorted.Count) disc(s) queued" 'INFO'
            return $sorted
        }
    }

    # Phase 4: tie-break — take first remaining link
    return @($working | Select-Object -First 1)
}

# ─── Download Monitor ─────────────────────────────────────────────────────────

function Wait-MotrixDownload {
    param([string]$Gid, [string]$Label = "", [int]$PollMs = 2000)

    $fields     = @("status", "completedLength", "totalLength", "downloadSpeed", "files")
    $shortLabel = if ($Label.Length -gt 45) { $Label.Substring(0, 42) + '...' } else { $Label }

    while ($true) {
        $status = Invoke-MotrixRpc 'aria2.tellStatus' @($Gid, $fields)
        if (-not $status) { Write-Log "Lost contact with Motrix." 'ERROR'; exit 1 }

        $state = $status.status
        $done  = [long]$status.completedLength
        $total = [long]$status.totalLength
        $speed = [long]$status.downloadSpeed
        $pct   = if ($total -gt 0) { [int](($done / $total) * 100) } else { 0 }
        $eta   = if ($speed -gt 0 -and $total -gt $done) {
            $secs = [int](($total - $done) / $speed)
            if ($secs -ge 3600) { '{0}h {1}m' -f [int]($secs / 3600), [int](($secs % 3600) / 60) }
            elseif ($secs -ge 60) { '{0}m {1}s' -f [int]($secs / 60), ($secs % 60) }
            else { "${secs}s" }
        } else { '--' }

        $filled = [int]($pct / 5)
        $bar    = '[' + ('#' * $filled) + (' ' * (20 - $filled)) + ']'
        $line   = " $bar $pct%  $(Format-Bytes $done)/$(Format-Bytes $total)  $(Format-Speed $speed)  ETA: $eta  $shortLabel"
        Write-Host "`r$line   " -NoNewline -ForegroundColor Cyan

        if ($state -eq 'complete') {
            Write-Host ""
            Write-Log "Download complete." 'SUCCESS'
            $filePath = if ($status.files -and $status.files[0].path) { $status.files[0].path } else { "" }
            return $filePath
        }
        if ($state -eq 'error') {
            Write-Host ""
            Write-Log "Motrix reported a download error for GID $Gid." 'ERROR'
            exit 1
        }

        Start-Sleep -Milliseconds $PollMs
    }
}

# ─── Extraction & Install ─────────────────────────────────────────────────────

function Expand-RomArchive {
    param([string]$ArchivePath, [string]$OutDir)

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $archType = Get-ArchiveType -FilePath $ArchivePath
    Write-Log "Extracting .$archType archive..." 'INFO'

    if ($archType -eq 'zip') {
        $sz = Find-7zip
        if ($sz) {
            $proc = Start-Process -FilePath $sz -ArgumentList "x `"-o$OutDir`" -y `"$ArchivePath`"" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) { throw "7z.exe exited with code $($proc.ExitCode)" }
        } else {
            Write-Log "7z.exe not found; using built-in Expand-Archive for .zip" 'WARN'
            Expand-Archive -Path $ArchivePath -DestinationPath $OutDir -Force
        }
        return
    }

    $sz = Find-7zip
    if (-not $sz) {
        Write-Log "7z.exe is required to extract .$archType archives but was not found." 'ERROR'
        Write-Log "Install it with:  winget install 7zip.7zip" 'WARN'
        Write-Log "The archive is at: $ArchivePath" 'WARN'
        exit 1
    }

    $proc = Start-Process -FilePath $sz -ArgumentList "x `"-o$OutDir`" -y `"$ArchivePath`"" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "7z.exe exited with code $($proc.ExitCode)" }
}

function Find-RomFile {
    param([string]$ExtractedDir)

    $romExts = @('.iso', '.bin', '.img', '.nds', '.gba', '.z64', '.n64', '.v64',
                 '.sfc', '.smc', '.nes', '.gb', '.gbc', '.gg', '.cue', '.chd', '.pbp')

    return Get-ChildItem -Path $ExtractedDir -Recurse -File |
        Where-Object { $romExts -contains $_.Extension.ToLower() } |
        Sort-Object Length -Descending |
        Select-Object -First 1
}

# ─── Download Backends ────────────────────────────────────────────────────────

function Invoke-MotrixDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    $gid = Invoke-MotrixRpc 'aria2.addUri' @(, @($Url))
    if (-not $gid) { throw "Motrix failed to queue the download." }
    Write-Log "GID: $gid" 'DEBUG'
    return Wait-MotrixDownload -Gid $gid -Label $Label -PollMs ([int]$cfg.pollIntervalMs)
}

function Invoke-Aria2cDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    Write-Log "Downloading via aria2c: $Label" 'INFO'
    $outDir  = [System.IO.Path]::GetDirectoryName($OutFile)
    $outName = [System.IO.Path]::GetFileName($OutFile)
    $proc = Start-Process 'aria2c' -ArgumentList @(
        "--dir=`"$outDir`"", "--out=`"$outName`"",
        "--console-log-level=warn", "--summary-interval=1",
        "--max-connection-per-server=4", "--split=4",
        "`"$Url`""
    ) -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "aria2c exited with code $($proc.ExitCode)" }
    return $OutFile
}

function Invoke-CurlDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    Write-Log "Downloading via curl: $Label" 'INFO'
    $proc = Start-Process 'curl.exe' -ArgumentList @(
        '-L', '--progress-bar', '--retry', '3', '--retry-delay', '2',
        '-o', "`"$OutFile`"", "`"$Url`""
    ) -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "curl.exe exited with code $($proc.ExitCode)" }
    return $OutFile
}

function Invoke-BitsDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    Write-Log "Downloading via BITS: $Label" 'INFO'
    $shortLabel = if ($Label.Length -gt 45) { $Label.Substring(0, 42) + '...' } else { $Label }
    $job = Start-BitsTransfer -Source $Url -Destination $OutFile -Asynchronous
    try {
        while ($job.JobState -notin @('Transferred', 'Error', 'TransientError')) {
            $done   = $job.BytesTransferred
            $total  = $job.BytesTotal
            $pct    = if ($total -gt 0) { [int]($done / $total * 100) } else { 0 }
            $filled = [int]($pct / 5)
            $bar    = '[' + ('#' * $filled) + (' ' * (20 - $filled)) + ']'
            Write-Host "`r $bar $pct%  $(Format-Bytes $done)/$(Format-Bytes $total)  $shortLabel   " -NoNewline -ForegroundColor Cyan
            Start-Sleep -Seconds 1
        }
        Write-Host ""
        if ($job.JobState -in @('Error', 'TransientError')) {
            $errMsg = $job.ErrorDescription
            Remove-BitsTransfer $job -ErrorAction SilentlyContinue
            throw "BITS transfer failed: $errMsg"
        }
        Complete-BitsTransfer $job
        Write-Log "Download complete." 'SUCCESS'
        return $OutFile
    } catch {
        try { Remove-BitsTransfer $job -ErrorAction SilentlyContinue } catch { }
        throw
    }
}

function Invoke-WebClientDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    Write-Log "Downloading via Invoke-WebRequest: $Label" 'INFO'
    $ProgressPreference = 'Continue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing `
            -Headers @{ 'User-Agent' = $HTTP_HEADERS['User-Agent'] } -ErrorAction Stop
        Write-Log "Download complete." 'SUCCESS'
        return $OutFile
    } catch {
        throw "WebRequest failed: $($_.Exception.Message)"
    }
}

# AB has no completion API, so watch its download folder for the file (named after suggestedName).
# Completion = file present, no partial sibling, and size stable across two polls.
function Wait-AbFile {
    param([string]$Dir, [string]$Name, [int]$TimeoutSec = 1800, [string]$Label = "")
    $target     = Join-Path $Dir $Name
    $deadline   = (Get-Date).AddSeconds($TimeoutSec)
    $lastSize   = -1
    $stable     = 0
    $partialExt = @('.part', '.tmp', '.download', '.crdownload', '.abdownload', '.bak')
    $shortLabel = if ($Label.Length -gt 45) { $Label.Substring(0, 42) + '...' } else { $Label }
    while ((Get-Date) -lt $deadline) {
        $partials = @(Get-ChildItem -LiteralPath $Dir -Filter "$Name*" -File -ErrorAction SilentlyContinue |
                      Where-Object { $partialExt -contains $_.Extension.ToLower() })
        $exists = Test-Path -LiteralPath $target
        $size   = if ($exists) { (Get-Item -LiteralPath $target).Length } else { 0 }
        if ($exists -and $partials.Count -eq 0 -and $size -gt 0 -and $size -eq $lastSize) {
            $stable++
            if ($stable -ge 2) { Write-Host ""; return $target }
        } else {
            $stable = 0
        }
        $lastSize = $size
        Write-Host "`r  [AB] $(Format-Bytes $size)  $shortLabel   " -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 2
    }
    Write-Host ""
    return $null
}

function Invoke-AbDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    $name = [System.IO.Path]::GetFileName($OutFile)
    Write-Log "Handing download to AB Download Manager (port $script:AB_PORT): $Label" 'INFO'
    Add-AbDownload -Url $Url -SuggestedName $name -Referer 'https://cdromance.org/' -Headers @{ 'User-Agent' = $HTTP_HEADERS['User-Agent'] }
    Write-Log "Queued in AB; watching $script:AB_DOWNLOAD_DIR for '$name'..." 'INFO'
    $done = Wait-AbFile -Dir $script:AB_DOWNLOAD_DIR -Name $name -TimeoutSec $script:AB_TIMEOUT -Label $Label
    if (-not $done) {
        throw "AB Download Manager did not produce '$name' in $($script:AB_DOWNLOAD_DIR) within $($script:AB_TIMEOUT)s (folder/name may differ - set [rom].abDownloadDir)."
    }
    Write-Log "AB download complete." 'SUCCESS'
    # Move into dlrom's temp pipeline so the rest of the flow (extract/install) is unchanged.
    if ($done -ne $OutFile) { Move-Item -LiteralPath $done -Destination $OutFile -Force -ErrorAction Stop }
    return $OutFile
}

# Direct (synchronous) tiers only - used as the final fallback after Motrix/AB.
function Get-DirectDownloader {
    if (Get-Command 'aria2c.exe' -ErrorAction SilentlyContinue) { return 'aria2c' }
    if (Get-Command 'aria2c'     -ErrorAction SilentlyContinue) { return 'aria2c' }
    if (Get-Command 'curl.exe'   -ErrorAction SilentlyContinue) { return 'curl'   }
    if (Get-Command 'Start-BitsTransfer' -ErrorAction SilentlyContinue) { return 'bits' }
    return 'webclient'
}

# When Motrix fails: prefer AB next, then the direct tiers.
function Get-FallbackDownloader {
    if (Test-AbRunning) { return 'ab' }
    return Get-DirectDownloader
}

function Invoke-FileDownload {
    param([string]$Url, [string]$OutFile, [string]$Label = "")
    if ($script:DOWNLOADER -eq 'motrix') {
        try {
            return Invoke-MotrixDownload -Url $Url -OutFile $OutFile -Label $Label
        } catch {
            Write-Log "Motrix failed: $($_.Exception.Message)" 'WARN'
            $script:DOWNLOADER = Get-FallbackDownloader
            Write-Log "Falling back to: $script:DOWNLOADER" 'WARN'
        }
    }
    if ($script:DOWNLOADER -eq 'ab') {
        try {
            return Invoke-AbDownload -Url $Url -OutFile $OutFile -Label $Label
        } catch {
            Write-Log "AB Download Manager failed: $($_.Exception.Message)" 'WARN'
            $script:DOWNLOADER = Get-DirectDownloader
            Write-Log "Falling back to: $script:DOWNLOADER" 'WARN'
        }
    }
    switch ($script:DOWNLOADER) {
        'aria2c'    { return Invoke-Aria2cDownload    -Url $Url -OutFile $OutFile -Label $Label }
        'curl'      { return Invoke-CurlDownload      -Url $Url -OutFile $OutFile -Label $Label }
        'bits'      { return Invoke-BitsDownload      -Url $Url -OutFile $OutFile -Label $Label }
        'webclient' { return Invoke-WebClientDownload -Url $Url -OutFile $OutFile -Label $Label }
        default     { throw "No supported downloader found." }
    }
}

# ─── Config Setup ─────────────────────────────────────────────────────────────

$cfg = Initialize-DlConfig -Section "rom" -Defaults ([PSCustomObject]@{
    romsBase        = "C:\Emulation\roms"
    tempDir         = (Join-Path $env:TEMP "dlrom")
    motrixRpcUrl    = "http://localhost:16800/jsonrpc"
    maxResults      = 10
    pollIntervalMs  = 2000
    steamSync       = $true     # after a successful install, add the ROM to Steam via Steam ROM Manager
    srmExe          = ""        # path to srm.exe; blank = autodetect C:\Emulation\tools\srm.exe
    srmRestartSteam = "auto"    # auto (restart only if running) | never | always
    srmEnableParser = $true     # enable the SRM parser watching the destination folder before adding
    srmWrapperCmd   = ""        # path to srm-wrapper.cmd; blank = autodetect on PATH (preferred over built-in)
    abPort          = 15151     # AB Download Manager integration port (preferred over Motrix when reachable order-wise)
    abDownloadDir   = ""        # AB's download folder; blank = autodetect %USERPROFILE%\Downloads\ABDM
    abTimeoutSec    = 1800      # how long to wait for an AB download to finish before giving up
})

# Read a config value with a fallback when the key is absent (stale config that missed backfill).
function Get-CfgValue {
    param([string]$Name, $Default)
    if ($cfg.PSObject.Properties.Name -contains $Name -and $null -ne $cfg.$Name) { return $cfg.$Name }
    return $Default
}

# ─── Steam ROM Manager Integration ────────────────────────────────────────────

function Find-Srm {
    param([string]$Configured)
    if ($Configured -and (Test-Path $Configured)) { return $Configured }
    $default = "C:\Emulation\tools\srm.exe"
    if (Test-Path $default) { return $default }
    $cmd = Get-Command "srm.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Locate the standalone srm-wrapper CLI (preferred over the built-in logic below).
function Find-SrmWrapper {
    param([string]$Configured)
    if ($Configured -and (Test-Path $Configured)) { return $Configured }
    foreach ($name in @('srm-wrapper.cmd', 'srm-wrapper')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Get-SrmUserDataDir {
    param([string]$SrmExe)
    return Join-Path (Split-Path -Parent $SrmExe) "userData"
}

function Get-SrmRomsDir {
    param([string]$SrmExe, [string]$Fallback)
    $settingsPath = Join-Path (Get-SrmUserDataDir $SrmExe) "userSettings.json"
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($settings.environmentVariables.romsDirectory) { return $settings.environmentVariables.romsDirectory }
        } catch { }
    }
    return $Fallback
}

function Get-SrmSteamExe {
    param([string]$SrmExe)
    $settingsPath = Join-Path (Get-SrmUserDataDir $SrmExe) "userSettings.json"
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            $steamDir = $settings.environmentVariables.steamDirectory
            if ($steamDir) {
                $candidate = Join-Path $steamDir "steam.exe"
                if (Test-Path $candidate) { return $candidate }
            }
        } catch { }
    }
    $fallback = Join-Path ${env:ProgramFiles(x86)} "Steam\steam.exe"
    if (Test-Path $fallback) { return $fallback }
    return $null
}

# Returns parserIds of *disabled* SRM parsers whose romDirectory resolves to $RomDest.
function Get-SrmParserIdsForFolder {
    param([string]$SrmExe, [string]$RomDest, [string]$RomsBase)
    $configPath = Join-Path (Get-SrmUserDataDir $SrmExe) "userConfigurations.json"
    if (-not (Test-Path $configPath)) { return @() }
    try {
        $parsers = Get-Content $configPath -Raw | ConvertFrom-Json
    } catch {
        Write-Log "Could not parse SRM userConfigurations.json; skipping parser enable." 'WARN'
        return @()
    }
    $romsDir    = Get-SrmRomsDir -SrmExe $SrmExe -Fallback $RomsBase
    $targetNorm = ($RomDest -replace '/', '\').TrimEnd('\')
    $ids = @()
    foreach ($p in $parsers) {
        if (-not $p.romDirectory) { continue }
        $dir = $p.romDirectory
        $dir = $dir.Replace('${romsdirglobal}', $romsDir)
        $dir = $dir.Replace('${/}', '\')
        $dir = $dir.Replace('/', '\')
        if ($dir.TrimEnd('\') -ieq $targetNorm -and $p.disabled -eq $true) {
            $ids += $p.parserId
        }
    }
    return @($ids)
}

function Invoke-Srm {
    param([string]$SrmExe, [string[]]$SrmArgs)
    $workDir = Split-Path -Parent $SrmExe
    $proc = Start-Process -FilePath $SrmExe -ArgumentList $SrmArgs -WorkingDirectory $workDir `
        -WindowStyle Hidden -Wait -PassThru
    return $proc.ExitCode
}

function Invoke-SteamRomManager {
    param([string]$RomDest, [string]$RomsBase)

    $srm = Find-Srm -Configured (Get-CfgValue 'srmExe' '')
    if (-not $srm) {
        Write-Log "Steam sync skipped: neither srm-wrapper nor Steam ROM Manager (srm.exe) was found." 'WARN'
        Write-Log "Install srm-wrapper on PATH, or Steam ROM Manager (EmuDeck installs it at C:\Emulation\tools\srm.exe), to auto-add ROMs to Steam." 'WARN'
        Write-Log "The ROM is downloaded and in place at: $RomDest" 'WARN'
        return
    }
    Write-Log "Steam ROM Manager: $srm" 'INFO'

    # 1) Enable the parser watching this folder (if requested and currently disabled)
    if ([bool](Get-CfgValue 'srmEnableParser' $true)) {
        $ids = @(Get-SrmParserIdsForFolder -SrmExe $srm -RomDest $RomDest -RomsBase $RomsBase)
        if ($ids.Count -gt 0) {
            Write-Log "Enabling SRM parser(s) for $RomDest : $($ids -join ', ')" 'INFO'
            $code = Invoke-Srm -SrmExe $srm -SrmArgs (@('enable') + $ids)
            if ($code -ne 0) { Write-Log "srm enable exited with code $code." 'WARN' }
        } else {
            Write-Log "No disabled SRM parser watches $RomDest (already enabled or none configured)." 'DEBUG'
        }
    }

    # 2) Decide Steam restart behaviour
    $policy   = (Get-CfgValue 'srmRestartSteam' 'auto').ToString().ToLower()
    $running  = [bool](Get-Process -Name steam -ErrorAction SilentlyContinue)
    $restart  = switch ($policy) {
        'always' { $true }
        'never'  { $false }
        default  { $running }   # 'auto'
    }
    $steamExe = Get-SrmSteamExe -SrmExe $srm

    # 3) Close Steam so SRM can fully apply (categories require Steam closed)
    if ($restart -and $running) {
        if ($steamExe) {
            Write-Log "Shutting down Steam so SRM can apply changes..." 'INFO'
            Start-Process -FilePath $steamExe -ArgumentList '-shutdown' -WindowStyle Hidden | Out-Null
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Process -Name steam -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
            }
            if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
                Write-Log "Steam did not exit within 20s; continuing anyway (new shortcut may need a manual Steam restart)." 'WARN'
            }
        } else {
            Write-Log "Steam is running but steam.exe path is unknown; cannot restart it automatically." 'WARN'
        }
    }

    # 4) Add to Steam
    Write-Log "Running Steam ROM Manager 'add'..." 'INFO'
    $addCode = Invoke-Srm -SrmExe $srm -SrmArgs @('add')
    if ($addCode -eq 0) {
        Write-Log "Steam ROM Manager finished adding games to Steam." 'SUCCESS'
    } else {
        Write-Log "srm add exited with code $addCode." 'WARN'
    }

    # 5) Relaunch Steam
    if ($restart -and ($running -or $policy -eq 'always')) {
        if ($steamExe) {
            Write-Log "Relaunching Steam..." 'INFO'
            Start-Process -FilePath $steamExe | Out-Null
        } else {
            Write-Log "Could not relaunch Steam (steam.exe path unknown); start it manually to see the new game." 'WARN'
        }
    } elseif (-not $restart) {
        Write-Log "Steam not restarted (policy: $policy). Restart Steam to see the new game." 'INFO'
    }
}

if ($MaxResults -eq 0) { $MaxResults = [int]$cfg.maxResults }
$script:MOTRIX_URL = $cfg.motrixRpcUrl
$tempDir           = $cfg.tempDir

# AB Download Manager settings (resolved before downloader selection)
$script:AB_PORT    = [int](Get-CfgValue 'abPort' 15151)
$script:AB_TIMEOUT = [int](Get-CfgValue 'abTimeoutSec' 1800)
$abDirCfg          = Get-CfgValue 'abDownloadDir' ''
$script:AB_DOWNLOAD_DIR = if ($abDirCfg) { $abDirCfg } else { Join-Path $env:USERPROFILE 'Downloads\ABDM' }

$script:DOWNLOADER = Find-Downloader

# ─── Main ─────────────────────────────────────────────────────────────────────

# Report which downloader will be used
$downloaderLabel = switch ($script:DOWNLOADER) {
    'motrix'    { 'Motrix (aria2 RPC)'                          }
    'ab'        { "AB Download Manager (port $script:AB_PORT)"  }
    'aria2c'    { 'aria2c (standalone)'                         }
    'curl'      { 'curl.exe (Windows built-in)'                 }
    'bits'      { 'BITS (Background Intelligent Transfer)'      }
    'webclient' { 'PowerShell Invoke-WebRequest (last resort)'  }
}
Write-Log "Downloader: $downloaderLabel" 'INFO'

# Resolve platform slug
$resolvedSlug = ""
if ($Platform) {
    $key = $Platform.ToLower()
    if ($PLATFORM_SLUGS.ContainsKey($key)) {
        $resolvedSlug = $PLATFORM_SLUGS[$key]
        Write-Log "Platform: $Platform -> slug '$resolvedSlug'" 'DEBUG'
    } else {
        Write-Log "Unknown platform '$Platform' - passing as-is to search URL." 'WARN'
        $resolvedSlug = $key
    }
}

# Search
Write-Log "Searching for: $Query" 'INFO'
$results = @(Invoke-CdromanceSearch -SearchQuery $Query -PlatformSlug $resolvedSlug -SearchRegion $Region -SearchSort $Sort)

if ($results.Count -eq 0) {
    Write-Log "No results found for: $Query" 'WARN'
    exit 0
}

$displayResults = @($results | Select-Object -First $MaxResults)

# Show results
Write-Host ""
$i = 1
foreach ($r in $displayResults) {
    Write-Host ("[{0,2}]" -f $i) -ForegroundColor Yellow -NoNewline
    Write-Host " $($r.Title)" -ForegroundColor White
    Write-Host ("       $($r.Platform)  |  $($r.Url)") -ForegroundColor DarkGray
    $i++
}
Write-Host ""

# Select game
$selected = $null
if ($Interactive -and $displayResults.Count -gt 1) {
    $choice = Read-Host "Select [1-$($displayResults.Count)] or 0 to cancel"
    if ($choice -eq '0' -or $choice -eq '') { Write-Log "Cancelled." 'WARN'; exit 0 }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $displayResults.Count) {
        Write-Log "Invalid selection." 'ERROR'; exit 1
    }
    $selected = $displayResults[$idx]
} else {
    $usaResult = $displayResults | Where-Object { $_.Url -imatch '\busa\b' } | Select-Object -First 1
    $selected  = if ($usaResult) { $usaResult } else { $displayResults[0] }
    Write-Log "Auto-selecting: $($selected.Title) [$($selected.Url)]" 'INFO'
}

# Get download links (reveals the "SHOW LINKS" table)
Write-Log "Fetching download links for: $($selected.Title)" 'INFO'
$allLinks = @(Get-DownloadLinks -GamePageUrl $selected.Url)

if ($allLinks.Count -eq 0) {
    Write-Log "No download links found on the game page." 'ERROR'
    $debugPath = Join-Path $env:TEMP "dlrom-debug.html"
    try {
        $dbgResp = Invoke-WebRequest -Uri $selected.Url -Headers $HTTP_HEADERS -UseBasicParsing -ErrorAction SilentlyContinue
        $dbgResp.Content | Set-Content $debugPath -Encoding UTF8
        Write-Log "Debug HTML saved to: $debugPath" 'WARN'
    } catch { }
    exit 1
}

Write-Log "Found $($allLinks.Count) raw link(s) on page." 'DEBUG'
$selectedLinks = @(Select-DownloadLinks -Links $allLinks)

if ($selectedLinks.Count -eq 0) {
    Write-Log "No suitable links after filtering (demos removed, nothing left)." 'ERROR'
    exit 1
}

Write-Log "Will download $($selectedLinks.Count) file(s): $(($selectedLinks | ForEach-Object { $_.Label }) -join ', ')" 'INFO'

# Resolve ROM destination
$platformFolder = if ($resolvedSlug -and $PLATFORM_FOLDERS.ContainsKey($resolvedSlug)) {
    $PLATFORM_FOLDERS[$resolvedSlug]
} elseif ($Platform) {
    $Platform.ToLower()
} elseif ($selected.Platform -and $PLATFORM_FOLDERS.ContainsKey($selected.Platform)) {
    # No --platform given: use the platform detected from the chosen search result
    # so a bare `dlrom "Game"` still lands in the right console folder, not \roms.
    $PLATFORM_FOLDERS[$selected.Platform]
} else {
    "roms"
}

# Resolve the ROMs base directory in priority order:
#   1. -Destination          explicit per-run override (always wins)
#   2. cfg.romsBase          the configured base (C:\Emulation\roms) when it exists
#   3. drive-meta picker      a connected drive advertising a rom_path
#   4. manual prompt          last resort
$romsBase = $null
if ($Destination) {
    $romsBase = $Destination
} elseif ($cfg.romsBase -and (Test-Path $cfg.romsBase)) {
    $romsBase = $cfg.romsBase
    Write-Log "ROMs base: $romsBase" 'DEBUG'
} else {
    if ($cfg.romsBase) {
        Write-Log "Configured ROMs base not available: $($cfg.romsBase) - falling back to drive picker." 'WARN'
    }
    try {
        $romsBase = Resolve-MediaPath -MediaType 'rom' -Strict
        Write-Log "Drive picker selected ROMs base: $romsBase" 'INFO'
    } catch {
        Write-Log "No connected drive advertises a ROM path ($($_.Exception.Message))." 'DEBUG'
        Write-Host "Enter ROMs base path (or press Enter for $HOME\Emulation\roms): " -NoNewline
        $alt = Read-Host
        $romsBase = if ($alt) { $alt } else { Join-Path $HOME "Emulation\roms" }
    }
}

$romDest = Join-Path $romsBase $platformFolder
if (-not (Test-Path $romDest)) {
    New-Item -ItemType Directory -Path $romDest -Force | Out-Null
    Write-Log "Created ROM directory: $romDest" 'INFO'
}

if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

# Download, extract, and install each selected link.
# Each iteration removes its temp archive + extraction dir in a finally so nothing is
# left behind on success OR failure (--no-extract keeps the archive, which is the deliverable).
$installedCount = 0
foreach ($link in $selectedLinks) {
    Write-Log "Downloading: $($link.Label)" 'INFO'

    # Sanitise label for use as a Windows filename
    $safeLabel = $link.Label -replace '[<>:"/\\|?*]', '_'
    $outFile   = Join-Path $tempDir $safeLabel

    $completedPath = $null
    $extractDir    = $null
    try {
        try {
            $completedPath = Invoke-FileDownload -Url $link.Url -OutFile $outFile -Label $link.Label
        } catch {
            Write-Log "Download failed: $($_.Exception.Message)" 'ERROR'
            continue
        }

        if ($NoExtract) {
            Write-Log "Archive saved (--no-extract): $completedPath" 'SUCCESS'
            continue
        }

        if (-not $completedPath -or -not (Test-Path $completedPath)) {
            Write-Log "Downloaded file not found at: $outFile" 'ERROR'
            continue
        }

        $extractId  = [System.IO.Path]::GetFileNameWithoutExtension($safeLabel) + '_' + (Get-Random)
        $extractDir = Join-Path $tempDir "extracted\$extractId"
        try {
            Expand-RomArchive -ArchivePath $completedPath -OutDir $extractDir
        } catch {
            Write-Log "Extraction failed: $($_.Exception.Message)" 'ERROR'
            continue
        }

        $romFile = Find-RomFile -ExtractedDir $extractDir
        if (-not $romFile) {
            Write-Log "No ROM file found after extraction." 'WARN'
            continue
        }

        try {
            Move-Item -Path $romFile.FullName -Destination $romDest -Force -ErrorAction Stop
            if (Test-Path (Join-Path $romDest $romFile.Name)) {
                $installedCount++
                Write-Log "ROM saved to: $(Join-Path $romDest $romFile.Name)" 'SUCCESS'

                # Move paired .cue sheet when the ROM is a .bin
                if ($romFile.Extension.ToLower() -eq '.bin') {
                    $cueSrc = Join-Path $romFile.DirectoryName ([System.IO.Path]::ChangeExtension($romFile.Name, '.cue'))
                    if (Test-Path $cueSrc) {
                        Move-Item -Path $cueSrc -Destination $romDest -Force -ErrorAction SilentlyContinue
                        Write-Log "Paired .cue moved alongside .bin" 'DEBUG'
                    }
                }
            }
        } catch {
            Write-Log "Move failed: $($_.Exception.Message)" 'ERROR'
        }
    }
    finally {
        # Always clean download artifacts (keep the archive only under --no-extract).
        if (-not $NoExtract) {
            if ($completedPath -and (Test-Path $completedPath)) { Remove-Item -Path $completedPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path $outFile)                              { Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue }
            if ($extractDir -and (Test-Path $extractDir))        { Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

# Prune the extraction parent if our cleanup left it empty.
$extractedParent = Join-Path $tempDir "extracted"
if ((Test-Path $extractedParent) -and -not (Get-ChildItem -LiteralPath $extractedParent -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -Path $extractedParent -Force -ErrorAction SilentlyContinue
}

# Add the freshly installed ROM(s) to Steam. Prefer the standalone srm-wrapper CLI;
# fall back to the built-in implementation if it isn't installed or fails.
if ($installedCount -gt 0 -and -not $NoSteam -and [bool](Get-CfgValue 'steamSync' $true)) {
    Write-Log "Syncing $installedCount new ROM(s) to Steam..." 'INFO'
    $handled = $false
    $wrapper = Find-SrmWrapper -Configured (Get-CfgValue 'srmWrapperCmd' '')
    if ($wrapper) {
        Write-Log "Using srm-wrapper: $wrapper" 'INFO'
        $wrapperArgs = @('--rom-dir', $romDest, '--restart-steam', ((Get-CfgValue 'srmRestartSteam' 'auto').ToString()))
        $srmExeCfg = (Get-CfgValue 'srmExe' '')
        if ($srmExeCfg) { $wrapperArgs += @('--srm', $srmExeCfg) }
        try {
            & $wrapper @wrapperArgs
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                $handled = $true
                Write-Log "Steam sync handled by srm-wrapper." 'SUCCESS'
            } else {
                Write-Log "srm-wrapper exited with code $code; falling back to built-in SRM logic." 'WARN'
            }
        } catch {
            Write-Log "srm-wrapper failed: $($_.Exception.Message); falling back to built-in SRM logic." 'WARN'
        }
    }
    if (-not $handled) {
        Invoke-SteamRomManager -RomDest $romDest -RomsBase $romsBase
    }
} elseif ($installedCount -gt 0 -and $NoSteam) {
    Write-Log "Skipping Steam sync (--no-steam)." 'INFO'
}

Write-Log "All done." 'SUCCESS'
