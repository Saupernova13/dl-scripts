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
    [switch]$NoExtract = $false
)

Add-Type -AssemblyName System.Web

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

function Find-Downloader {
    if (Test-MotrixRunning)                                           { return 'motrix'    }
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

$PLATFORM_FOLDERS = @{
    "ps2-iso"   = "ps2"
    "psx-iso"   = "ps1"
    "psp"       = "psp"
    "vita"      = "vita"
    "n64-roms"  = "n64"
    "gamecube"  = "gamecube"
    "nds-roms"  = "nds"
    "gba"       = "gba"
    "snes-roms" = "snes"
    "nes-roms"  = "nes"
    "gbc-roms"  = "gbc"
    "gb-roms"   = "gb"
    "dreamcast" = "dreamcast"
    "saturn"    = "saturn"
    "wii"       = "wii"
    "3ds-roms"  = "3ds"
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

function Get-FallbackDownloader {
    if (Get-Command 'aria2c.exe' -ErrorAction SilentlyContinue) { return 'aria2c' }
    if (Get-Command 'aria2c'     -ErrorAction SilentlyContinue) { return 'aria2c' }
    if (Get-Command 'curl.exe'   -ErrorAction SilentlyContinue) { return 'curl'   }
    if (Get-Command 'Start-BitsTransfer' -ErrorAction SilentlyContinue) { return 'bits' }
    return 'webclient'
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
    romsBase       = "C:\Emulation\roms"
    tempDir        = (Join-Path $env:TEMP "dlrom")
    motrixRpcUrl   = "http://localhost:16800/jsonrpc"
    maxResults     = 10
    pollIntervalMs = 2000
})

if ($MaxResults -eq 0) { $MaxResults = [int]$cfg.maxResults }
$script:MOTRIX_URL = $cfg.motrixRpcUrl
$tempDir           = $cfg.tempDir
$script:DOWNLOADER = Find-Downloader

# ─── Main ─────────────────────────────────────────────────────────────────────

# Report which downloader will be used
$downloaderLabel = switch ($script:DOWNLOADER) {
    'motrix'    { 'Motrix (aria2 RPC)'                          }
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
} else {
    "roms"
}

$romsBase = if ($Destination) { $Destination } else { $cfg.romsBase }
if (-not (Test-Path $romsBase)) {
    Write-Log "ROMs base path not found: $romsBase" 'WARN'
    Write-Host "Enter alternate path (or press Enter for $HOME\Emulation\roms): " -NoNewline
    $alt = Read-Host
    $romsBase = if ($alt) { $alt } else { Join-Path $HOME "Emulation\roms" }
}

$romDest = Join-Path $romsBase $platformFolder
if (-not (Test-Path $romDest)) {
    New-Item -ItemType Directory -Path $romDest -Force | Out-Null
    Write-Log "Created ROM directory: $romDest" 'INFO'
}

if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

# Download, extract, and install each selected link
foreach ($link in $selectedLinks) {
    Write-Log "Downloading: $($link.Label)" 'INFO'

    # Sanitise label for use as a Windows filename
    $safeLabel = $link.Label -replace '[<>:"/\\|?*]', '_'
    $outFile   = Join-Path $tempDir $safeLabel

    $completedPath = $null
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
        Write-Log "Archive left at: $completedPath" 'WARN'
        continue
    }

    $romFile = Find-RomFile -ExtractedDir $extractDir
    if (-not $romFile) {
        Write-Log "No ROM file found after extraction. Extracted dir: $extractDir" 'WARN'
        Write-Log "Archive left at: $completedPath" 'WARN'
        continue
    }

    $moved = $false
    try {
        Move-Item -Path $romFile.FullName -Destination $romDest -Force -ErrorAction Stop
        if (Test-Path (Join-Path $romDest $romFile.Name)) {
            $moved = $true
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
        Write-Log "Extracted files remain at: $extractDir" 'WARN'
    }

    # Clean up only after the ROM is confirmed at its destination
    if ($moved) {
        try { Remove-Item -Path $completedPath -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        Write-Log "Temp files cleaned up." 'DEBUG'
    }
}

Write-Log "All done." 'SUCCESS'
