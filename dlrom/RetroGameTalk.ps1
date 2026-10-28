# Scraping for RetroGameTalk's ROM repository ("The Repo", https://retrogametalk.com/repo/):
# platform tables, search, and per-game link discovery.
#
# The Repo is a WordPress catalogue under a XenForo forum. Two things follow:
#
#   * There is no sign-in step. The members-only gate is browser-side JavaScript, which a
#     script never executes, so every request below is unauthenticated. The one cookie jar
#     exists only to keep a WordPress nonce and the PHPSESSID that minted it consistent.
#   * The download table is not in the page. "Show Links" POSTs the post id plus a per-page
#     nonce to the cdr-main ajax endpoint, which returns the table as an HTML fragment.
#
# retrogametalk.com serves plain HTTP clients with no Cloudflare challenge, so
# Invoke-WebRequest is enough. The resolved dl*.retrogametalk.com URLs carry their own
# authorisation in the ?key=, which is what lets Motrix/AB/aria2c fetch them cookieless.

Add-Type -AssemblyName System.Web

# Platform alias -> Repo category slug, used in the search URL and game page paths.
# There is no 3DS entry: The Repo does not carry 3DS games.
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
# Usually the same string, but not always. Passing the category slug for one of the odd ones
# returns ZERO results rather than an error, so every slug that disagrees must be listed here.
# Source of truth is <select id="platform"> on /repo/?s=<anything>.
$PLATFORM_SEARCH_VALUES = @{
    "gamecube"            = "gcn-iso"
    "gameboy-color-roms"  = "gbc_roms"
    "gameboy-roms"        = "gb_roms"
    "psx2psp-eboots"      = "psx2psp"
}

# Category slug -> on-disk console folder. Names follow EmuDeck's roms layout so emulators
# and SRM parsers both find the files (PS1 -> 'psx', etc.).
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

# --- Session ------------------------------------------------------------------
#
# One cookie jar for the whole run, and not for a login - there isn't one. WordPress ties the
# reveal nonce to the PHPSESSID it was minted under, so one session keeps the two consistent.

$script:RGT_SESSION = $null    # Microsoft.PowerShell.Commands.WebRequestSession

function Get-RgtSession {
    if (-not $script:RGT_SESSION) {
        $script:RGT_SESSION = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $script:RGT_SESSION.UserAgent = $HTTP_HEADERS['User-Agent']
    }
    return $script:RGT_SESSION
}

# Drop the cookie jar so the next request starts a fresh PHPSESSID. A rejected reveal is the
# symptom of a nonce whose session the server has already expired.
function Reset-RgtSession {
    $script:RGT_SESSION = $null
}

# Returns an object with a .Content property, so callers use it exactly like
# Invoke-WebRequest; the session handling underneath is invisible.
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
    $archExts = $script:DOWNLOAD_EXTS_RX

    # Primary: anchor text is the filename. The href is a download.php?file=... redirector,
    # so only the text carries the name.
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
        # Re-throw so the orchestrator can classify the cause and decide whether to try the
        # PS2 torrent fallback.
        throw "retrogametalk search request failed: $($_.Exception.Message)"
    }

    return @(Get-RgtResultsFromHtml $resp.Content)
}

# Parse a Repo listing (search results, platform index) into title/url/platform rows.
#
# One <div class="game-container"> per game, holding a .cover-link anchor and a .game-title
# div. Splitting on the container keeps the two associated even when a card grows extra
# markup between them, which a single flat regex could not promise.
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
# "Show Links" POSTs { post_id, _wpnonce } to the cdr-main ajax endpoint with
# X-Requested-With: XMLHttpRequest and gets the table back as an HTML fragment. All three
# inputs are per-page and scraped fresh every time; the nonce is short-lived.
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

    # An expired session shows up here: the page renders, but its nonce was minted under a
    # PHPSESSID the server has dropped. Start a fresh session and retry once.
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

# Narrow a Vita game's links to the build that will actually run on the target.
#
# When the page has no such build - older titles are often console-only - it hands back
# everything rather than nothing: a build you have to convert beats no download. That is safe
# because the caller re-reads the winning link's own marker (Get-VitaLinksBuild) instead of
# trusting the request.
function Select-VitaLinks {
    param([object[]]$Links, [string]$Build)

    if ($Links.Count -eq 0) { return @() }
    if (-not $Build -or $Build -eq $script:VITA_BUILD_ANY) { return @($Links) }

    $wanted = @($Links | Where-Object { (Get-VitaLinkBuild $_.Label) -eq $Build })
    if ($wanted.Count -gt 0) {
        Write-Log "Vita: taking the $($script:VITA_BUILD_LABELS[$Build]) build." 'INFO'
        return $wanted
    }

    Write-Log ("Vita: this game has no {0} build on The Repo - falling back to what it does offer." -f
        $script:VITA_BUILD_LABELS[$Build]) 'WARN'
    return @($Links)
}

# Narrow candidate links to what we want: the Vita build, no demos, English/USA preferred,
# one link per disc for multi-disc sets.
#
# -PlatformSlug is the Repo category the game came from; it only matters for Vita.
function Select-DownloadLinks {
    param([object[]]$Links, [string]$PlatformSlug = '', [string]$VitaBuild = '')

    if ($Links.Count -eq 0) { return @() }

    # Phase 0: Vita - both builds carry identical region and language markers, so the phases
    # below cannot tell them apart and would take whichever the page listed first. Also drops
    # the unmarked extras some pages carry (manuals, "AR Cards.zip") that nothing else rejects.
    $candidates = if ($PlatformSlug -eq $script:VITA_SLUG) {
        @(Select-VitaLinks -Links $Links -Build $VitaBuild)
    } else {
        @($Links)
    }

    # Phase 1: filter demos, betas and prototypes
    $filtered = @($candidates | Where-Object { $_.Label -notmatch $script:DEMO_RX })
    if ($filtered.Count -eq 0) {
        Write-Log "All links appear to be demos; taking first link as fallback." 'WARN'
        return @($candidates[0])
    }

    # Phase 2: prefer English/patched/undub variants
    $english = @($filtered | Where-Object { $_.Label -imatch $script:ENGLISH_RX })
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

# Region codes for a Repo result. The region rides in the URL slug, e.g. ...-fes-usa-2/.
function Get-RgtRegions {
    param([string]$Url, [string]$Title)
    $s = (($Url + ' ' + $Title)).ToLower()
    $r = @()
    if ($s -match '(^|[^a-z])usa([^a-z]|$)')       { $r += 'usa' }
    if ($s -match 'europe|europa|[-(]eur|\bpal\b') { $r += 'europe' }
    if ($s -match 'japan|[-(]jpn')                 { $r += 'japan' }
    if ($s -match '\bworld\b')                     { $r += 'world' }
    if ($s -match 'korea')                         { $r += 'korea' }
    return @($r | Select-Object -Unique)
}

# Pick the best Repo search result. Same spirit as the torrent matcher, but SOFT: prefer a
# full query match, a base release over an edition unless the query named it, non-hack over
# hack, and the requested region - yet ALWAYS return something. The Repo often carries only
# FES and not the base, and an edition beats no game at all.
function Select-RgtResult {
    param([object[]]$Results, [string]$Query, [string]$Region)
    if (-not $Results -or $Results.Count -eq 0) { return $null }
    if ($Results.Count -eq 1) { return $Results[0] }

    $qtokens   = Get-Ps2Significant $Query
    $normQuery = ConvertTo-Ps2Norm $Query
    $requested = Resolve-RegionRequest $Region

    $i = 0
    $scored = @()
    foreach ($r in $Results) {
        $tn = ConvertTo-Ps2Norm $r.Title
        $tt = Get-Ps2Significant $r.Title

        $allPresent = $true
        foreach ($qt in $qtokens) { if ($tt -notcontains $qt) { $allPresent = $false; break } }
        $matchRank = if ($allPresent) { 0 } else { 1 }

        $demo = if ($r.Title -match $script:DEMO_RX) { 1 } else { 0 }
        $hack = if ((($r.Url + ' ' + $r.Title)) -match $script:HACK_RX) { 1 } else { 0 }

        $edition = 0
        foreach ($kw in $script:EDITION_KW) {
            if ((Test-Phrase $tn $kw) -and -not (Test-Phrase $normQuery $kw)) { $edition = 1; break }
        }

        $regions    = Get-RgtRegions $r.Url $r.Title
        $regionRank = Get-RegionRank -Regions $regions -Requested $requested
        $extra      = @($tt | Where-Object { $qtokens -notcontains $_ }).Count

        $scored += [PSCustomObject]@{ R = $r; Demo = $demo; Match = $matchRank; Hack = $hack;
            Edition = $edition; RegionRank = $regionRank; Extra = $extra; Idx = $i }
        $i++
    }
    $best = $scored | Sort-Object Demo, Match, Hack, Edition, RegionRank, Extra, Idx | Select-Object -First 1
    return $best.R
}

# Reason code plus human text, so the orchestrator can report the real cause and decide
# whether to try the torrent fallback.
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
