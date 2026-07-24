# Scraping for RetroGameTalk's ROM repository ("The Repo", https://retrogametalk.com/repo/),
# which is where the old cdromance.org catalogue now lives: platform tables, search, and
# per-game link discovery.
#
# The Repo is a WordPress catalogue mounted under a XenForo forum. Two things follow:
#
#   * There is no sign-in step. The Repo advertises a members-only gate, but it is
#     enforced entirely in the browser:
#         if (!document.cookie.includes("xf_online=1")) { location.replace("/login/") }
#     A script never executes that, so browsing, searching and link reveal all work
#     anonymously. Every request below is therefore unauthenticated, and the module keeps
#     one cookie jar purely so the WordPress nonce and the PHPSESSID that minted it stay
#     consistent across the two calls that need each other.
#   * The download table is not in the page. "Show Links" POSTs the post id plus a
#     per-page WordPress nonce to the cdr-main ajax endpoint, which returns the table as
#     an HTML fragment. Both values are scraped from the game page (see Get-RgtDownloadLinks).
#
# Unlike cdromance, retrogametalk.com serves plain HTTP clients without a Cloudflare
# challenge, so there is no FlareSolverr/curl_cffi machinery here - Invoke-WebRequest is
# enough. The resolved dl*.retrogametalk.com URLs are unauthenticated too (the ?key= in
# the query string is the authorisation), which is what lets Motrix/AB/aria2c fetch them
# with no cookie of their own.
#
# Dot-sourced by Add-ROM.ps1. Write-Log and ConvertTo-ResponseText come from Logging.ps1.

Add-Type -AssemblyName System.Web

$RGT_BASE_URL = 'https://retrogametalk.com'
$RGT_REPO_URL = "$RGT_BASE_URL/repo"

# Platform alias -> Repo category slug used in the search URL and game page paths.
# These are NOT the old cdromance slugs: gba/snes/gbc/gb/dreamcast/saturn/wii all
# changed when the catalogue moved, and 3DS did not come across at all.
$PLATFORM_SLUGS = @{
    "ps2"          = "ps2-iso"
    "ps1"          = "psx-iso"
    "psx"          = "psx-iso"
    "psp"          = "psp"
    "eboot"        = "psx2psp-eboots"
    "vita"         = "vita"
    "n64"          = "n64-roms"
    "gamecube"     = "gamecube"
    "gc"           = "gamecube"
    "wii"          = "wii-iso"
    "nds"          = "nds-roms"
    "ds"           = "nds-roms"
    "gba"          = "gba-roms"
    "snes"         = "snes-rom"
    "nes"          = "nes-roms"
    "fds"          = "famicom_disk_system"
    "gbc"          = "gameboy-color-roms"
    "gb"           = "gameboy-roms"
    "dreamcast"    = "dc-iso"
    "dc"           = "dc-iso"
    "saturn"       = "sega_saturn_isos"
    "segacd"       = "sega_cd_isos"
    "genesis"      = "sega_genesis_roms"
    "megadrive"    = "sega_genesis_roms"
    "32x"          = "sega_32x_roms"
    "sms"          = "sms_roms"
    "mastersystem" = "sms_roms"
    "gamegear"     = "game-gear"
    "gg"           = "game-gear"
    "pico"         = "sega-pico"
    "3do"          = "3do-iso"
    "amiga"        = "amiga"
    "arcade"       = "arcade"
    "msx"          = "msx-roms"
    "msdos"        = "msdos"
    "dos"          = "msdos"
    "windows"      = "windows"
    "scummvm"      = "scummvm"
    "neogeocd"     = "neo-geo-cd"
    "ngp"          = "neo-geo-pocket"
    "ngpc"         = "neo-geo-pocket"
    "pc88"         = "pc-88"
    "pc98"         = "pc-98"
    "pcfx"         = "pc-fx"
    "tg16"         = "turbografx-16"
    "pcengine"     = "turbografx-16"
    "tgcd"         = "turbografx-cd"
    "wonderswan"   = "wonderswan"
    "ws"           = "wonderswan"
}

# Category slug -> value the search form's `platform=` filter expects.
#
# For most platforms the two are the same string, but not all: the search dropdown and the
# permalink structure were clearly built at different times. Passing the category slug for
# one of these returns ZERO results rather than an error - a silent "not found" - so any
# slug that disagrees must be listed here. Verified against the <select id="platform">
# options on /repo/?s=<anything>; re-check this table if a platform starts finding nothing.
$PLATFORM_SEARCH_VALUES = @{
    "gamecube"            = "gcn-iso"
    "gameboy-color-roms"  = "gbc_roms"
    "gameboy-roms"        = "gb_roms"
    "psx2psp-eboots"      = "psx2psp"
}

# Category slug -> on-disk console folder. Names follow EmuDeck's roms layout so the
# emulators and Steam ROM Manager parsers both find the files (PS1 -> 'psx', etc.).
$PLATFORM_FOLDERS = @{
    "ps2-iso"             = "ps2"
    "psx-iso"             = "psx"
    "psp"                 = "psp"
    "psx2psp-eboots"      = "psp"
    "vita"                = "psvita"
    "n64-roms"            = "n64"
    "gamecube"            = "gc"
    "wii-iso"             = "wii"
    "nds-roms"            = "nds"
    "gba-roms"            = "gba"
    "snes-rom"            = "snes"
    "nes-roms"            = "nes"
    "famicom_disk_system" = "fds"
    "gameboy-color-roms"  = "gbc"
    "gameboy-roms"        = "gb"
    "dc-iso"              = "dreamcast"
    "sega_saturn_isos"    = "saturn"
    "sega_cd_isos"        = "segacd"
    "sega_genesis_roms"   = "genesis"
    "sega_32x_roms"       = "sega32x"
    "sms_roms"            = "mastersystem"
    "game-gear"           = "gamegear"
    "sega-pico"           = "segapico"
    "3do-iso"             = "3do"
    "amiga"               = "amiga"
    "arcade"              = "arcade"
    "msx-roms"            = "msx"
    "msdos"               = "dos"
    "windows"             = "windows"
    "scummvm"             = "scummvm"
    "neo-geo-cd"          = "neocd"
    "neo-geo-pocket"      = "ngp"
    "pc-88"               = "pc88"
    "pc-98"               = "pc98"
    "pc-fx"               = "pcfx"
    "turbografx-16"       = "tg16"
    "turbografx-cd"       = "tg16cd"
    "wonderswan"          = "wonderswan"
}

# Repo paths that are site furniture, not game categories - skipped when scanning hrefs.
$RGT_NON_GAME_SLUGS = @('page', 'category', 'tag', 'author', 'guides', 'news', 'reviews',
    'platforms', 'recent-comments', 'contact', 'dmca', 'privacy-policy', 'user-agreement',
    'sitemap', 'bios-files', 'wp-content', 'wp-admin', 'wp-includes', 'cdn-cgi')

# Browser-like headers reused for every request (and the User-Agent handed to downloaders).
$HTTP_HEADERS = @{
    'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    'Accept-Language' = 'en-US,en;q=0.5'
}

# --- Session ------------------------------------------------------------------
#
# One cookie jar for the whole run. There is no login: The Repo serves anonymous HTTP
# clients in full (its members-only gate is browser-side JavaScript, which a script never
# executes). The jar exists because the link-reveal call has to present the WordPress
# nonce scraped from the game page, and WordPress ties that nonce to the PHPSESSID it was
# minted under - reusing one session keeps the two consistent.

$script:RGT_SESSION = $null    # Microsoft.PowerShell.Commands.WebRequestSession

function Get-RgtSession {
    if (-not $script:RGT_SESSION) {
        $script:RGT_SESSION = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $script:RGT_SESSION.UserAgent = $HTTP_HEADERS['User-Agent']
    }
    return $script:RGT_SESSION
}

# Drop the cookie jar so the next request starts a fresh PHPSESSID. Used when a reveal is
# rejected, which is the symptom of a nonce whose session the server has already expired.
function Reset-RgtSession {
    $script:RGT_SESSION = $null
}

# Unified Repo request. Returns an object with a .Content property (page HTML), so callers
# use it exactly like Invoke-WebRequest; the session handling underneath is invisible.
function Invoke-RgtWeb {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [string]$Body,
        [string]$ContentType = 'application/x-www-form-urlencoded',
        [hashtable]$ExtraHeaders,
        [string]$Referer
    )

    $session = Get-RgtSession

    $headers = $HTTP_HEADERS.Clone()
    if ($Referer)      { $headers['Referer'] = $Referer }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }

    $params = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $headers
        WebSession      = $session
        UseBasicParsing = $true
        TimeoutSec      = 45
        ErrorAction     = 'Stop'
    }
    if ($Method -eq 'POST') {
        $params.Body        = $Body
        $params.ContentType = $ContentType
    }

    $resp = Invoke-WebRequest @params
    return [PSCustomObject]@{
        Content    = (ConvertTo-ResponseText $resp.Content)
        StatusCode = [int]$resp.StatusCode
    }
}

# --- Search -------------------------------------------------------------------

# Pull download links out of a results/listing fragment.
function Get-LinksFromHtml {
    param([string]$Html)
    $links = @()
    $archExts = '7z|zip|rar|iso|bin|img|chd|pbp'

    # Primary: anchor text is the filename. The Repo's reveal table is built this way -
    # the href is a download.php?file=... redirector, so only the text carries the name.
    $pattern = '<a[\s\S]+?href="([^"]+)"[^>]*>\s*([^<]+\.' + '(' + $archExts + '))\s*</a>'
    $found = [regex]::Matches($Html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $found) {
        $url   = [System.Web.HttpUtility]::HtmlDecode($m.Groups[1].Value.Trim())
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
        $url   = [System.Web.HttpUtility]::HtmlDecode($m.Groups[1].Value.Trim())
        $label = [System.Web.HttpUtility]::HtmlDecode($m.Groups[3].Value.Trim())
        if (-not $label) { $label = [System.IO.Path]::GetFileName(($url -split '\?')[0]) }
        if ($url -match '^https?://') {
            $links += [PSCustomObject]@{ Label = $label; Url = $url }
        }
    }
    return $links
}

function Invoke-RgtSearch {
    param(
        [string]$SearchQuery,
        [string]$PlatformSlug = "",
        [string]$SearchRegion = "",
        [string]$SearchSort   = ""
    )

    $encoded = [System.Web.HttpUtility]::UrlEncode($SearchQuery)
    $url = "$RGT_REPO_URL/?s=$encoded"
    if ($PlatformSlug) {
        # The filter wants the dropdown's value, which is not always the category slug.
        $filterValue = if ($PLATFORM_SEARCH_VALUES.ContainsKey($PlatformSlug)) {
            $PLATFORM_SEARCH_VALUES[$PlatformSlug]
        } else {
            $PlatformSlug
        }
        if ($filterValue -ne $PlatformSlug) {
            Write-Log "Search filter for '$PlatformSlug' is '$filterValue'." 'DEBUG'
        }
        $url += "&platform=$filterValue"
    }
    if ($SearchRegion)  { $url += "&region=$([System.Web.HttpUtility]::UrlEncode($SearchRegion))" }
    if ($SearchSort)    { $url += "&sorted=$([System.Web.HttpUtility]::UrlEncode($SearchSort))" }

    Write-Log "Searching: $url" 'DEBUG'

    try {
        $resp = Invoke-RgtWeb -Uri $url -Referer "$RGT_REPO_URL/"
    } catch {
        # Re-throw so the orchestrator can classify the cause and decide whether to try
        # the PS2 torrent fallback instead of exiting here.
        throw "retrogametalk search request failed: $($_.Exception.Message)"
    }

    return @(Get-RgtResultsFromHtml $resp.Content)
}

# Parse a Repo listing (search results, platform index) into title/url/platform rows.
#
# The Repo renders one <div class="game-container"> per game, holding a .cover-link anchor
# and a .game-title div. Splitting on the container keeps the two associated even when a
# card grows extra markup between them, which a single flat regex could not promise.
function Get-RgtResultsFromHtml {
    param([string]$Html)

    $results = @()
    $seen    = @{}
    $gameUrlPat = 'https://retrogametalk\.com/repo/([a-z0-9_-]+)/([^/"]+)/'

    $blocks = [regex]::Split($Html, '(?=<div class="game-container">)')
    foreach ($block in $blocks) {
        if ($block -notmatch 'class="cover-link"') { continue }

        $linkMatch = [regex]::Match($block, 'class="cover-link"[^>]*href="(' + $gameUrlPat + ')"')
        if (-not $linkMatch.Success) {
            $linkMatch = [regex]::Match($block, 'href="(' + $gameUrlPat + ')"[^>]*class="cover-link"')
        }
        if (-not $linkMatch.Success) { continue }

        $gameUrl  = $linkMatch.Groups[1].Value.Trim()
        $platSlug = $linkMatch.Groups[2].Value.Trim()
        if ($platSlug -in $RGT_NON_GAME_SLUGS) { continue }
        if ($gameUrl -match '/page/')          { continue }
        if ($seen.ContainsKey($gameUrl))       { continue }

        $titleMatch = [regex]::Match($block, 'class="game-title"[^>]*>([^<]+)<')
        $title = if ($titleMatch.Success) {
            [System.Web.HttpUtility]::HtmlDecode(($titleMatch.Groups[1].Value -replace '\s+', ' ').Trim())
        } else {
            # No title div (layout drift): fall back to the slug so the result is still usable.
            (Get-Culture).TextInfo.ToTitleCase(($linkMatch.Groups[3].Value -replace '-', ' '))
        }
        if (-not $title) { continue }

        $seen[$gameUrl] = $true
        $results += [PSCustomObject]@{ Title = $title; Url = $gameUrl; Platform = $platSlug }
    }

    if ($results.Count -gt 0) { return $results }

    # Fallback: no game-container markup at all - scan every Repo game URL on the page.
    Write-Log "Game-container parsing found nothing; falling back to a raw URL scan." 'DEBUG'
    $urlMatches = [regex]::Matches($Html, 'href="(' + $gameUrlPat + ')"[^>]*>([^<]*)</a>')
    foreach ($m in $urlMatches) {
        $gameUrl  = $m.Groups[1].Value.Trim()
        $platSlug = $m.Groups[2].Value.Trim()
        $title    = [System.Web.HttpUtility]::HtmlDecode(($m.Groups[4].Value -replace '\s+', ' ').Trim())
        if (-not $title) { continue }
        if ($platSlug -in $RGT_NON_GAME_SLUGS) { continue }
        if ($gameUrl -match '/page/')          { continue }
        if ($seen.ContainsKey($gameUrl))       { continue }
        $seen[$gameUrl] = $true
        $results += [PSCustomObject]@{ Title = $title; Url = $gameUrl; Platform = $platSlug }
    }
    return $results
}

# --- Link discovery -----------------------------------------------------------

# Open a game page and dig out its actual download links.
#
# The "Show Links" button POSTs { post_id, _wpnonce } to the cdr-main ajax endpoint with
# X-Requested-With: XMLHttpRequest, and gets the download table back as an HTML fragment.
# All three inputs are per-page, so they are scraped fresh from the game page every time -
# the nonce in particular is short-lived and tied to the current session.
function Get-RgtDownloadLinks {
    param([string]$GamePageUrl)

    Write-Log "Fetching game page..." 'DEBUG'
    try {
        $resp = Invoke-RgtWeb -Uri $GamePageUrl -Referer "$RGT_REPO_URL/"
    } catch {
        Write-Log "Failed to fetch game page: $($_.Exception.Message)" 'ERROR'
        return @()
    }
    $html = $resp.Content

    $links = @(Invoke-RgtLinkReveal -Html $html -GamePageUrl $GamePageUrl)
    if ($links.Count -gt 0) { return $links }

    # An expired session shows up here: the page renders, but the nonce it carries was
    # minted under a PHPSESSID the server has since dropped, so the reveal is refused.
    # Start a fresh session and retry once with a newly minted nonce before giving up.
    Write-Log "Link reveal came back empty; retrying once with a fresh session." 'DEBUG'
    Reset-RgtSession
    try {
        $html2 = (Invoke-RgtWeb -Uri $GamePageUrl -Referer "$RGT_REPO_URL/").Content
        $links = @(Invoke-RgtLinkReveal -Html $html2 -GamePageUrl $GamePageUrl)
        if ($links.Count -gt 0) { return $links }
        $html = $html2
    } catch {
        Write-Log "Retry with a fresh session failed: $($_.Exception.Message)" 'DEBUG'
    }

    # Last resort: the links are occasionally inlined on the page itself (older posts).
    Write-Log "Falling back to a raw href scan on the game page." 'DEBUG'
    return @(Get-LinksFromHtml $html)
}

# One reveal attempt against an already-fetched game page.
function Invoke-RgtLinkReveal {
    param([string]$Html, [string]$GamePageUrl)

    $wrapper = [regex]::Match($Html, '<div\s+id="acf-content-wrapper"[^>]*>')
    if (-not $wrapper.Success) {
        $wrapper = [regex]::Match($Html, '<div[^>]*id="acf-content-wrapper"[^>]*>')
    }
    if (-not $wrapper.Success) {
        Write-Log "No acf-content-wrapper on the page - nothing to reveal." 'DEBUG'
        return @()
    }

    $postId = [regex]::Match($wrapper.Value, 'data-id="([^"]+)"').Groups[1].Value
    $nonce  = [regex]::Match($wrapper.Value, 'data-nonce="([^"]+)"').Groups[1].Value
    if (-not $postId) {
        Write-Log "acf-content-wrapper carries no data-id." 'DEBUG'
        return @()
    }

    # The endpoint is advertised in-page; only fall back to the known path if it is absent.
    $ajaxUrl = [regex]::Match($Html, 'var cdrData\s*=\s*\{"ajaxUrl":"([^"]+)"').Groups[1].Value -replace '\\/', '/'
    if (-not $ajaxUrl) { $ajaxUrl = "$RGT_REPO_URL/wp-content/plugins/cdr-main/public/ajax.php" }

    Write-Log "Revealing links: post_id=$postId nonce=$(if ($nonce) { 'yes' } else { 'MISSING' })" 'DEBUG'

    $body = "post_id=$([System.Web.HttpUtility]::UrlEncode($postId))"
    if ($nonce) { $body += "&_wpnonce=$([System.Web.HttpUtility]::UrlEncode($nonce))" }

    try {
        $apiResp = Invoke-RgtWeb -Uri $ajaxUrl -Method POST -Body $body -Referer $GamePageUrl `
            -ExtraHeaders @{ 'X-Requested-With' = 'XMLHttpRequest' }
    } catch {
        # 403 here means the nonce was rejected (expired, or minted for another session).
        Write-Log "Link reveal POST failed: $($_.Exception.Message)" 'DEBUG'
        return @()
    }

    $links = @(Get-LinksFromHtml $apiResp.Content)
    Write-Log "Reveal returned $($apiResp.Content.Length) bytes, $($links.Count) link(s)." 'DEBUG'
    return $links
}

# --- Selection ----------------------------------------------------------------

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

# Region codes for a Repo result, read from its slug/title (the region rides in the URL
# slug, e.g. ...-fes-usa-2/ or ...-persona-3-europe/).
function Get-RgtRegions {
    param([string]$Url, [string]$Title)
    $s = (($Url + ' ' + $Title)).ToLower()
    $r = @()
    if ($s -match '(^|[^a-z])usa([^a-z]|$)')      { $r += 'usa' }
    if ($s -match 'europe|europa|[-(]eur|\bpal\b'){ $r += 'europe' }
    if ($s -match 'japan|[-(]jpn')                { $r += 'japan' }
    if ($s -match '\bworld\b')                    { $r += 'world' }
    if ($s -match 'korea')                        { $r += 'korea' }
    return @($r | Select-Object -Unique)
}

# Pick the best Repo search result. Same spirit as the torrent matcher but a SOFT
# preference: prefer a full query match, a base release over an edition/variant (FES,
# Undub, ...) unless the query named it, non-hack over hack, and the requested region -
# yet ALWAYS return something. An edition beats no game at all (the Repo often carries
# only FES, not the base). Helpers come from Ps2TorrentIndex.ps1.
function Select-RgtResult {
    param([object[]]$Results, [string]$Query, [string]$Region)
    if (-not $Results -or $Results.Count -eq 0) { return $null }
    if ($Results.Count -eq 1) { return $Results[0] }

    $qtokens   = Get-Ps2Significant $Query
    $normQuery = ConvertTo-Ps2Norm $Query
    $requested = Resolve-Ps2RegionRequest $Region

    $i = 0
    $scored = @()
    foreach ($r in $Results) {
        $tn = ConvertTo-Ps2Norm $r.Title
        $tt = Get-Ps2Significant $r.Title

        $allPresent = $true
        foreach ($qt in $qtokens) { if ($tt -notcontains $qt) { $allPresent = $false; break } }
        $matchRank = if ($allPresent) { 0 } else { 1 }

        $demo = if ($r.Title -match $script:PS2_DEMO_RX) { 1 } else { 0 }
        $hack = if ((($r.Url + ' ' + $r.Title)) -match '(?i)(\bhack\b|\bmod\b|\bpatch\b|controllable|-hack)') { 1 } else { 0 }

        $edition = 0
        foreach ($kw in $script:PS2_EDITION_KW) {
            if ((Test-Ps2Phrase $tn $kw) -and -not (Test-Ps2Phrase $normQuery $kw)) { $edition = 1; break }
        }

        $regions    = Get-RgtRegions $r.Url $r.Title
        $regionRank = Get-Ps2RegionRank -Regions $regions -Requested $requested
        $extra      = @($tt | Where-Object { $qtokens -notcontains $_ }).Count

        $scored += [PSCustomObject]@{ R = $r; Demo = $demo; Match = $matchRank; Hack = $hack;
            Edition = $edition; RegionRank = $regionRank; Extra = $extra; Idx = $i }
        $i++
    }
    $best = $scored | Sort-Object Demo, Match, Hack, Edition, RegionRank, Extra, Idx | Select-Object -First 1
    return $best.R
}

# Classify a Repo failure message into a short reason code plus human text, so the
# orchestrator can report the real cause and decide whether to try the torrent fallback.
function Get-RgtFailureReason {
    param([string]$Message)
    $m = [string]$Message
    if ($m -match '(?i)\b(401|403)\b|forbidden|unauthor') {
        return @{ Code = 'rgt-forbidden'; Text = 'RetroGameTalk refused the request (403) - the site may have started gating The Repo server-side.' }
    }
    if ($m -match '(?i)\b(429)\b|too many requests') {
        return @{ Code = 'rgt-ratelimited'; Text = 'RetroGameTalk is rate-limiting this client; try again shortly.' }
    }
    if ($m -match '(?i)\b(50\d)\b|service unavailable|bad gateway') {
        return @{ Code = 'rgt-server-error'; Text = 'RetroGameTalk returned a server error.' }
    }
    if ($m -match '(?i)timed? ?out|timeout') {
        return @{ Code = 'rgt-timeout'; Text = 'RetroGameTalk did not respond in time.' }
    }
    if ($m -match '(?i)resolve|no such host|connection|network') {
        return @{ Code = 'rgt-unreachable'; Text = 'Could not reach retrogametalk.com (network or DNS problem).' }
    }
    return @{ Code = 'search-error'; Text = $m }
}
