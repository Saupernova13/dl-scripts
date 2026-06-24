# Scraping for cdromance.org: platform tables, search, and per-game link discovery.
# Every request goes through Invoke-CdrWeb (CfSolver.ps1) so the Cloudflare handling
# is out of the way here.

Add-Type -AssemblyName System.Web

$CDR_BASE_URL = 'https://cdromance.org'

# Platform alias -> cdromance category slug used in the search URL.
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

# Category slug -> on-disk console folder. Names follow EmuDeck's roms layout so the
# emulators and Steam ROM Manager parsers both find the files (PS1 -> 'psx', etc.).
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

# Slugs that are site navigation, not games - skipped when scanning hrefs for results.
$CDR_NON_GAME_SLUGS = @('page', 'category', 'tag', 'author', 'guides', 'news', 'reviews', 'cdn-cgi', 'wp-content')

# Browser-like headers reused for direct requests (and the User-Agent for downloads).
$HTTP_HEADERS = @{
    'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    'Accept-Language' = 'en-US,en;q=0.5'
}

# Pull download links out of a results/listing fragment.
function Get-LinksFromHtml {
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
    $url = "$CDR_BASE_URL/?s=$encoded"
    if ($PlatformSlug)  { $url += "&platform=$PlatformSlug" }
    if ($SearchRegion)  { $url += "&region=$([System.Web.HttpUtility]::UrlEncode($SearchRegion))" }
    if ($SearchSort)    { $url += "&sorted=$([System.Web.HttpUtility]::UrlEncode($SearchSort))" }

    Write-Log "Searching: $url" 'DEBUG'

    try {
        $resp = Invoke-CdrWeb -Uri $url
    } catch {
        Write-Log "Search failed: $($_.Exception.Message)" 'ERROR'
        Write-Log "If this is a Cloudflare block, ensure Docker Desktop is running so FlareSolverr can solve it." 'WARN'
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
            if (-not $seen.ContainsKey($gameUrl) -and $platSlug -notin $CDR_NON_GAME_SLUGS -and $title) {
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
            if ($platSlug -in $CDR_NON_GAME_SLUGS) { continue }
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

# Open a game page and dig out its actual download links.
function Get-DownloadLinks {
    param([string]$GamePageUrl)

    Write-Log "Fetching game page..." 'DEBUG'
    try {
        $resp = Invoke-CdrWeb -Uri $GamePageUrl -Referer "$CDR_BASE_URL/"
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

        try {
            $ticketResp = Invoke-CdrWeb -Uri "$CDR_BASE_URL/" -Method POST `
                -Body "cdrTicketInput=$ticket" -Referer $GamePageUrl
            $links = @(Get-LinksFromHtml $ticketResp.Content)
            if ($links.Count -gt 0) {
                Write-Log "Strategy A (ticket POST) found $($links.Count) link(s)." 'DEBUG'
                return $links
            }
        } catch {
            Write-Log "Ticket POST failed: $($_.Exception.Message)" 'DEBUG'
        }
    }

    # Strategy B: ACF data-id -> cdr-main/ajax.php
    $acfMatch = [regex]::Match($html, 'id="acf-content-wrapper"[^>]*data-id="([^"]+)"')
    if (-not $acfMatch.Success) {
        $acfMatch = [regex]::Match($html, 'data-id="([^"]+)"[^>]*id="acf-content-wrapper"')
    }
    if ($acfMatch.Success) {
        $postId = $acfMatch.Groups[1].Value
        Write-Log "ACF wrapper found: id=$postId" 'DEBUG'

        try {
            $apiResp = Invoke-CdrWeb -Uri "$CDR_BASE_URL/wp-content/plugins/cdr-main/public/ajax.php" `
                -Method POST -Body "post_id=$postId" -Referer $GamePageUrl `
                -ExtraHeaders @{ 'X-Requested-With' = 'XMLHttpRequest' }
            Write-Log "AJAX response length: $($apiResp.Content.Length)" 'DEBUG'
            $links = @(Get-LinksFromHtml $apiResp.Content)
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
    return @(Get-LinksFromHtml $html)
}

# Narrow a list of candidate links down to what we actually want to grab:
# skip demos, prefer English/USA, and keep one link per disc for multi-disc sets.
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

    # Phase 3: multi-disc detection - return one link per disc number
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

    # Phase 4: tie-break - take first remaining link
    return @($working | Select-Object -First 1)
}
