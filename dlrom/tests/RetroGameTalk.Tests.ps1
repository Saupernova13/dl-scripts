# Tests for RetroGameTalk.ps1 - the search/link-discovery half of dlrom.
#
# These exercise the real functions end to end. The ONLY thing mocked is Invoke-WebRequest,
# the single external dependency; every URL, every regex and every selection rule below is
# the production code path. Fixtures under tests/fixtures/ are trimmed captures of real
# Repo pages, so the parsers are tested against the markup the site actually serves.
#
# Run:  Invoke-Pester .\dlrom\tests
# The live suite (real HTTP) is tagged 'Live' and skipped by default:
#       Invoke-Pester .\dlrom\tests -Tag Live

BeforeAll {
    $script:ModuleRoot  = Split-Path -Parent $PSScriptRoot
    $script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures'

    . (Join-Path $ModuleRoot 'Logging.ps1')
    . (Join-Path $ModuleRoot 'RetroGameTalk.ps1')
    . (Join-Path $ModuleRoot 'Ps2TorrentIndex.ps1')   # Select-RgtResult borrows its matchers

    $script:LOG_QUIET   = $true
    $script:LOG_VERBOSE = $false

    # Several tests drive the WARN/ERROR paths on purpose. Write-Log always prints those,
    # which puts scary-looking lines in the middle of a passing run - so silence it here.
    # No test asserts on logging; the module's own behaviour is unchanged.
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

    function Get-Fixture {
        param([string]$Name)
        Get-Content -LiteralPath (Join-Path $script:FixtureRoot $Name) -Raw
    }

    # Stand-in for a WebRequest response: only .Content is consumed by the module.
    function New-Response {
        param([string]$Content, [int]$StatusCode = 200)
        return [PSCustomObject]@{ Content = $Content; StatusCode = $StatusCode }
    }

    # Invoke-WebRequest types -Uri as [System.Uri], and Uri.ToString() DECODES percent
    # escapes. Asserting against that would hide an encoding bug, so always compare the
    # string the caller actually passed.
    function Get-RequestedUri {
        param($Uri)
        if ($Uri -is [uri]) { return $Uri.OriginalString }
        return [string]$Uri
    }
}

Describe 'Platform tables' {

    It 'maps every alias to a slug that has a ROM folder' {
        foreach ($alias in $PLATFORM_SLUGS.Keys) {
            $slug = $PLATFORM_SLUGS[$alias]
            $PLATFORM_FOLDERS.ContainsKey($slug) |
                Should -BeTrue -Because "alias '$alias' resolves to '$slug', which needs a folder mapping"
        }
    }

    It 'has no folder mapping for a slug nothing can reach' {
        foreach ($slug in $PLATFORM_FOLDERS.Keys) {
            $PLATFORM_SLUGS.Values | Should -Contain $slug -Because "'$slug' has a folder but no alias"
        }
    }

    It 'resolves the console aliases to their real Repo category slugs' {
        # Locked to the live values: several of these changed when the catalogue moved off
        # cdromance, and a silent regression here sends ROMs to the wrong folder.
        $PLATFORM_SLUGS['ps2']       | Should -BeExactly 'ps2-iso'
        $PLATFORM_SLUGS['ps1']       | Should -BeExactly 'psx-iso'
        $PLATFORM_SLUGS['psx']       | Should -BeExactly 'psx-iso'
        $PLATFORM_SLUGS['psp']       | Should -BeExactly 'psp'
        $PLATFORM_SLUGS['vita']      | Should -BeExactly 'vita'
        $PLATFORM_SLUGS['n64']       | Should -BeExactly 'n64-roms'
        $PLATFORM_SLUGS['gamecube']  | Should -BeExactly 'gamecube'
        $PLATFORM_SLUGS['gc']        | Should -BeExactly 'gamecube'
        $PLATFORM_SLUGS['wii']       | Should -BeExactly 'wii-iso'
        $PLATFORM_SLUGS['nds']       | Should -BeExactly 'nds-roms'
        $PLATFORM_SLUGS['gba']       | Should -BeExactly 'gba-roms'
        $PLATFORM_SLUGS['snes']      | Should -BeExactly 'snes-rom'
        $PLATFORM_SLUGS['nes']       | Should -BeExactly 'nes-roms'
        $PLATFORM_SLUGS['gbc']       | Should -BeExactly 'gameboy-color-roms'
        $PLATFORM_SLUGS['gb']        | Should -BeExactly 'gameboy-roms'
        $PLATFORM_SLUGS['dreamcast'] | Should -BeExactly 'dc-iso'
        $PLATFORM_SLUGS['saturn']    | Should -BeExactly 'sega_saturn_isos'
        $PLATFORM_SLUGS['genesis']   | Should -BeExactly 'sega_genesis_roms'
        $PLATFORM_SLUGS['sms']       | Should -BeExactly 'sms_roms'
    }

    It 'files each console under its EmuDeck folder name' {
        $PLATFORM_FOLDERS['psx-iso']            | Should -BeExactly 'psx'
        $PLATFORM_FOLDERS['ps2-iso']            | Should -BeExactly 'ps2'
        $PLATFORM_FOLDERS['gamecube']           | Should -BeExactly 'gc'
        $PLATFORM_FOLDERS['vita']               | Should -BeExactly 'psvita'
        $PLATFORM_FOLDERS['dc-iso']             | Should -BeExactly 'dreamcast'
        $PLATFORM_FOLDERS['sega_saturn_isos']   | Should -BeExactly 'saturn'
        $PLATFORM_FOLDERS['gameboy-color-roms'] | Should -BeExactly 'gbc'
        $PLATFORM_FOLDERS['sms_roms']           | Should -BeExactly 'mastersystem'
    }

    It 'sends PSP eboots to the psp folder' {
        $PLATFORM_FOLDERS[$PLATFORM_SLUGS['eboot']] | Should -BeExactly 'psp'
    }

    It 'no longer offers a 3ds alias' {
        # The Repo has no 3DS section; keeping the alias would build a URL that 404s.
        $PLATFORM_SLUGS.ContainsKey('3ds') | Should -BeFalse
    }
}

Describe 'Search URL construction' {

    BeforeEach {
        $script:CapturedUri    = $null
        $script:CapturedMethod = $null
        Mock -CommandName Invoke-WebRequest -MockWith {
            $script:CapturedUri    = Get-RequestedUri $Uri
            $script:CapturedMethod = $Method
            New-Response (Get-Fixture 'search-results.html')
        }
    }

    It 'builds a bare search against the Repo root' {
        Invoke-RgtSearch -SearchQuery 'Persona 3' | Out-Null
        $script:CapturedUri | Should -BeExactly 'https://retrogametalk.com/repo/?s=Persona+3'
    }

    It 'url-encodes characters that would break the query string' {
        Invoke-RgtSearch -SearchQuery "Tom & Jerry: Infurnal Escape" | Out-Null
        $script:CapturedUri | Should -Not -Match '[ &]Jerry'
        $script:CapturedUri | Should -Match '%26'      # the & is encoded, not a new param
        $script:CapturedUri | Should -Match '%3a|%3A'  # so is the colon
    }

    It 'appends the platform filter' {
        Invoke-RgtSearch -SearchQuery 'Persona 3' -PlatformSlug 'ps2-iso' | Out-Null
        $script:CapturedUri | Should -BeExactly 'https://retrogametalk.com/repo/?s=Persona+3&platform=ps2-iso'
    }

    It 'appends region and sort filters' {
        Invoke-RgtSearch -SearchQuery 'Metal Slug' -PlatformSlug 'ps2-iso' -SearchRegion 'usa' -SearchSort 'downloads' | Out-Null
        $script:CapturedUri | Should -BeExactly 'https://retrogametalk.com/repo/?s=Metal+Slug&platform=ps2-iso&region=usa&sorted=downloads'
    }

    It 'omits filters that were not asked for' {
        Invoke-RgtSearch -SearchQuery 'Zelda' -SearchSort 'alpha' | Out-Null
        $script:CapturedUri | Should -BeExactly 'https://retrogametalk.com/repo/?s=Zelda&sorted=alpha'
        $script:CapturedUri | Should -Not -Match 'platform='
        $script:CapturedUri | Should -Not -Match 'region='
    }

    It 'searches with GET' {
        Invoke-RgtSearch -SearchQuery 'Zelda' | Out-Null
        $script:CapturedMethod | Should -Be 'GET'
    }

    It 'translates the four slugs whose search filter differs from their URL path' {
        # The dropdown and the permalinks disagree for these. Passing the category slug
        # returns zero results instead of an error, so the mapping is load-bearing.
        $cases = @{
            'gamecube'           = 'gcn-iso'
            'gameboy-color-roms' = 'gbc_roms'
            'gameboy-roms'       = 'gb_roms'
            'psx2psp-eboots'     = 'psx2psp'
        }
        foreach ($slug in $cases.Keys) {
            Invoke-RgtSearch -SearchQuery 'Zelda' -PlatformSlug $slug | Out-Null
            $script:CapturedUri | Should -BeExactly "https://retrogametalk.com/repo/?s=Zelda&platform=$($cases[$slug])"
        }
    }

    It 'passes every other slug through unchanged' {
        foreach ($slug in @($PLATFORM_SLUGS.Values | Select-Object -Unique)) {
            if ($PLATFORM_SEARCH_VALUES.ContainsKey($slug)) { continue }
            Invoke-RgtSearch -SearchQuery 'x' -PlatformSlug $slug | Out-Null
            $script:CapturedUri | Should -BeExactly "https://retrogametalk.com/repo/?s=x&platform=$slug"
        }
    }

    It 'produces a resolvable URL for every supported alias' {
        foreach ($alias in $PLATFORM_SLUGS.Keys) {
            Invoke-RgtSearch -SearchQuery 'Mario' -PlatformSlug $PLATFORM_SLUGS[$alias] | Out-Null
            $script:CapturedUri | Should -Match '^https://retrogametalk\.com/repo/\?s=Mario&platform=[A-Za-z0-9_-]+$'
        }
    }

    It 'surfaces a transport failure as a search error' {
        Mock -CommandName Invoke-WebRequest -MockWith { throw 'The remote name could not be resolved' }
        { Invoke-RgtSearch -SearchQuery 'Zelda' } | Should -Throw '*retrogametalk search request failed*'
    }
}

Describe 'Search result parsing' {

    BeforeAll {
        $script:Results = Get-RgtResultsFromHtml (Get-Fixture 'search-results.html')
    }

    It 'finds every game card on the page' {
        $script:Results.Count | Should -Be 9
    }

    It 'reads the real title, URL and platform off a card' {
        $first = $script:Results[0]
        $first.Title    | Should -BeExactly 'Shin Megami Tensei: Persona 3 FES'
        $first.Url      | Should -BeExactly 'https://retrogametalk.com/repo/ps2-iso/shin-megami-tensei-persona-3-fes-usa-2/'
        $first.Platform | Should -BeExactly 'ps2-iso'
    }

    It 'returns absolute Repo game URLs for every result' {
        foreach ($r in $script:Results) {
            $r.Url | Should -Match '^https://retrogametalk\.com/repo/[a-z0-9_-]+/[^/]+/$'
        }
    }

    It 'never returns the same game twice' {
        $urls = @($script:Results | ForEach-Object { $_.Url })
        ($urls | Select-Object -Unique).Count | Should -Be $urls.Count
    }

    It 'gives every result a non-empty title' {
        foreach ($r in $script:Results) { $r.Title | Should -Not -BeNullOrEmpty }
    }

    It 'decodes HTML entities in titles' {
        $html = @'
<div class="game-container"><a class="cover-link" href="https://retrogametalk.com/repo/ps2-iso/dot-hack/"></a>
<div class="game-title">.hack//G.U. Vol.1&#8212;Rebirth &amp; More</div></div>
'@
        $expected = '.hack//G.U. Vol.1' + [char]0x2014 + 'Rebirth & More'
        (Get-RgtResultsFromHtml $html)[0].Title | Should -BeExactly $expected
    }

    It 'skips navigation links that are not games' {
        $html = @'
<div class="game-container"><a class="cover-link" href="https://retrogametalk.com/repo/platforms/list/"></a>
<div class="game-title">By Platform</div></div>
<div class="game-container"><a class="cover-link" href="https://retrogametalk.com/repo/author/ingram/"></a>
<div class="game-title">Spike</div></div>
<div class="game-container"><a class="cover-link" href="https://retrogametalk.com/repo/ps2-iso/real-game/"></a>
<div class="game-title">Real Game</div></div>
'@
        $r = @(Get-RgtResultsFromHtml $html)
        $r.Count     | Should -Be 1
        $r[0].Title  | Should -BeExactly 'Real Game'
    }

    It 'returns nothing for a page with no results' {
        @(Get-RgtResultsFromHtml '<div class="games-loop"><p>Nothing found.</p></div>').Count | Should -Be 0
    }

    It 'falls back to a raw URL scan when the card markup is gone' {
        # Guards the layout-drift path: no game-container, but real game links present.
        $html = '<a href="https://retrogametalk.com/repo/n64-roms/super-mario-64/">Super Mario 64</a>'
        $r = @(Get-RgtResultsFromHtml $html)
        $r.Count        | Should -Be 1
        $r[0].Title     | Should -BeExactly 'Super Mario 64'
        $r[0].Platform  | Should -BeExactly 'n64-roms'
    }
}

Describe 'Download link reveal' {

    It 'POSTs post_id and the WordPress nonce to the advertised endpoint' {
        $script:Captured = @{}
        Mock -CommandName Invoke-WebRequest -MockWith {
            $script:Captured = @{ Uri = (Get-RequestedUri $Uri); Method = $Method; Body = $Body; Headers = $Headers }
            New-Response (Get-Fixture 'reveal-response.html')
        }

        $links = @(Invoke-RgtLinkReveal -Html (Get-Fixture 'game-page.html') `
                    -GamePageUrl 'https://retrogametalk.com/repo/ps2-iso/shin-megami-tensei-persona-3-fes-usa-2/')

        $script:Captured.Uri    | Should -BeExactly 'https://retrogametalk.com/repo/wp-content/plugins/cdr-main/public/ajax.php'
        $script:Captured.Method | Should -Be 'POST'
        $script:Captured.Body   | Should -BeExactly 'post_id=6069&_wpnonce=2c3e69dc0a'
        # Without this header the endpoint answers 403.
        $script:Captured.Headers['X-Requested-With'] | Should -BeExactly 'XMLHttpRequest'
        $script:Captured.Headers['Referer']          | Should -BeExactly 'https://retrogametalk.com/repo/ps2-iso/shin-megami-tensei-persona-3-fes-usa-2/'
        $links.Count | Should -Be 2
    }

    It 'falls back to the known endpoint when the page does not advertise one' {
        $script:Uri = $null
        Mock -CommandName Invoke-WebRequest -MockWith {
            $script:Uri = Get-RequestedUri $Uri; New-Response (Get-Fixture 'reveal-response.html')
        }
        $html = '<div id="acf-content-wrapper" data-nonce="abc123" data-id="42"></div>'
        Invoke-RgtLinkReveal -Html $html -GamePageUrl 'https://retrogametalk.com/repo/ps2-iso/x/' | Out-Null
        $script:Uri | Should -BeExactly 'https://retrogametalk.com/repo/wp-content/plugins/cdr-main/public/ajax.php'
    }

    It 'still POSTs when the page carries no nonce' {
        $script:Body = $null
        Mock -CommandName Invoke-WebRequest -MockWith { $script:Body = $Body; New-Response '' }
        Invoke-RgtLinkReveal -Html '<div id="acf-content-wrapper" data-id="99"></div>' `
            -GamePageUrl 'https://retrogametalk.com/repo/ps2-iso/x/' | Out-Null
        $script:Body | Should -BeExactly 'post_id=99'
    }

    It 'returns nothing, without calling out, when there is no reveal widget' {
        Mock -CommandName Invoke-WebRequest -MockWith { New-Response '' }
        @(Invoke-RgtLinkReveal -Html '<p>no widget here</p>' -GamePageUrl 'https://x/').Count | Should -Be 0
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It 'treats a 403 from the endpoint as no links rather than an exception' {
        Mock -CommandName Invoke-WebRequest -MockWith { throw 'The remote server returned an error: (403) Forbidden.' }
        @(Invoke-RgtLinkReveal -Html (Get-Fixture 'game-page.html') -GamePageUrl 'https://x/').Count | Should -Be 0
    }

    It 'fetches the game page then reveals, end to end' {
        $script:Calls = @()
        Mock -CommandName Invoke-WebRequest -MockWith {
            $script:Calls += Get-RequestedUri $Uri
            if ($Uri -like '*ajax.php') { New-Response (Get-Fixture 'reveal-response.html') }
            else                        { New-Response (Get-Fixture 'game-page.html') }
        }
        $links = @(Get-RgtDownloadLinks -GamePageUrl 'https://retrogametalk.com/repo/ps2-iso/persona/')
        $links.Count       | Should -Be 2
        $script:Calls[0]   | Should -BeExactly 'https://retrogametalk.com/repo/ps2-iso/persona/'
        $script:Calls[1]   | Should -Match 'ajax\.php$'
    }

    It 'retries once with a fresh session when the first reveal is empty' {
        $script:Attempts = 0
        Mock -CommandName Invoke-WebRequest -MockWith {
            if ($Uri -like '*ajax.php') {
                $script:Attempts++
                # First nonce is stale; the retry's nonce is accepted.
                if ($script:Attempts -eq 1) { New-Response '' }
                else { New-Response (Get-Fixture 'reveal-response.html') }
            } else { New-Response (Get-Fixture 'game-page.html') }
        }
        $links = @(Get-RgtDownloadLinks -GamePageUrl 'https://retrogametalk.com/repo/ps2-iso/persona/')
        $script:Attempts | Should -Be 2
        $links.Count     | Should -Be 2
    }

    It 'gives up gracefully when the game page cannot be fetched' {
        Mock -CommandName Invoke-WebRequest -MockWith { throw 'timed out' }
        @(Get-RgtDownloadLinks -GamePageUrl 'https://retrogametalk.com/repo/ps2-iso/x/').Count | Should -Be 0
    }
}

Describe 'Download link extraction' {

    BeforeAll {
        $script:Links = @(Get-LinksFromHtml (Get-Fixture 'reveal-response.html'))
    }

    It 'pulls both files out of the reveal table' {
        $script:Links.Count | Should -Be 2
    }

    It 'reads the filename from the anchor text, not the href' {
        # The href is a download.php redirector, so the extension only exists in the text.
        $script:Links[0].Label | Should -BeExactly 'Shin Megami Tensei - Persona 3 FES (USA).7z'
        $script:Links[1].Label | Should -BeExactly 'Shin Megami Tensei - Persona 3 FES (USA)(Deinterlaced).7z'
    }

    It 'returns the real, complete download URLs' {
        $script:Links[0].Url | Should -BeExactly 'https://dl3b.retrogametalk.com/download.php?file=Shin%20Megami%20Tensei%20-%20Persona%203%20FES%20%28USA%29.7z&id=6069&platform=ps2-iso&key=2991986453'
        $script:Links[1].Url | Should -BeExactly 'https://dl3.retrogametalk.com/download.php?file=Shin%20Megami%20Tensei%20-%20Persona%203%20FES%20%28USA%29%28Deinterlaced%29.7z&id=6069&platform=ps2-iso&key=2186867636'
    }

    It 'keeps the key parameter that authorises the transfer' {
        foreach ($l in $script:Links) {
            $l.Url | Should -Match '^https://dl[0-9a-z]*\.retrogametalk\.com/download\.php\?'
            $l.Url | Should -Match '&key=\d+$'
            $l.Url | Should -Match '&id=\d+'
            $l.Url | Should -Match '&platform=[a-z0-9_-]+'
        }
    }

    It 'recognises every archive and raw-ROM extension the Repo serves' {
        foreach ($ext in @('7z', 'zip', 'rar', 'iso', 'bin', 'img', 'chd', 'pbp')) {
            $html = "<a href=""https://dl1.retrogametalk.com/download.php?file=x.$ext&key=1"">Some Game (USA).$ext</a>"
            $l = @(Get-LinksFromHtml $html)
            $l.Count    | Should -Be 1 -Because "'.$ext' should be recognised"
            $l[0].Label | Should -BeExactly "Some Game (USA).$ext"
        }
    }

    It 'decodes HTML-escaped ampersands in the href' {
        $html = '<a href="https://dl1.retrogametalk.com/download.php?file=x.7z&amp;id=1&amp;key=9">Game (USA).7z</a>'
        (Get-LinksFromHtml $html)[0].Url | Should -BeExactly 'https://dl1.retrogametalk.com/download.php?file=x.7z&id=1&key=9'
    }

    It 'falls back to hrefs that end in an archive extension' {
        $html = '<a href="https://dl1.retrogametalk.com/files/Some%20Game.zip">Download now</a>'
        $l = @(Get-LinksFromHtml $html)
        $l.Count    | Should -Be 1
        $l[0].Label | Should -BeExactly 'Download now'
    }

    It 'ignores relative and non-http hrefs' {
        @(Get-LinksFromHtml '<a href="/local/file.7z">Game.7z</a>').Count | Should -Be 0
    }

    It 'returns nothing for markup with no downloads' {
        @(Get-LinksFromHtml '<div class="download-links table"><p>No links.</p></div>').Count | Should -Be 0
    }
}

Describe 'Link selection' {

    BeforeAll {
        function New-Link {
            param($Label)
            [PSCustomObject]@{ Label = $Label; Url = "https://dl1.retrogametalk.com/download.php?file=$Label&key=1" }
        }
    }

    It 'drops demos, betas and samplers' {
        $links = @(New-Link 'Game (USA) (Demo).7z'), (New-Link 'Game (USA).7z')
        (Select-DownloadLinks -Links $links)[0].Label | Should -BeExactly 'Game (USA).7z'
    }

    It 'keeps a demo when it is the only thing on offer' {
        $links = @(New-Link 'Game (USA) (Demo).7z')
        $r = @(Select-DownloadLinks -Links $links)
        $r.Count    | Should -Be 1
        $r[0].Label | Should -BeExactly 'Game (USA) (Demo).7z'
    }

    It 'prefers an English or undub release' {
        $links = @(New-Link 'Game (Japan).7z'), (New-Link 'Game (Japan) (English).7z')
        (Select-DownloadLinks -Links $links)[0].Label | Should -Match 'English'
    }

    It 'prefers USA once language ties' {
        $links = @(New-Link 'Game (Europe).7z'), (New-Link 'Game (USA).7z')
        (Select-DownloadLinks -Links $links)[0].Label | Should -Match 'USA'
    }

    It 'returns one link per disc for a multi-disc set, in order' {
        $links = @(New-Link 'Game (USA) (Disc 2).7z'), (New-Link 'Game (USA) (Disc 1).7z'), (New-Link 'Game (USA) (Disc 3).7z')
        $r = @(Select-DownloadLinks -Links $links)
        $r.Count | Should -Be 3
        $r[0].Label | Should -Match 'Disc 1'
        $r[1].Label | Should -Match 'Disc 2'
        $r[2].Label | Should -Match 'Disc 3'
    }

    It 'does not treat a single disc as a multi-disc set' {
        @(Select-DownloadLinks -Links @((New-Link 'Game (USA) (Disc 1).7z'))).Count | Should -Be 1
    }

    It 'picks exactly one link from the real reveal fixture' {
        $r = @(Select-DownloadLinks -Links @(Get-LinksFromHtml (Get-Fixture 'reveal-response.html')))
        $r.Count    | Should -Be 1
        $r[0].Label | Should -BeExactly 'Shin Megami Tensei - Persona 3 FES (USA).7z'
    }

    It 'returns nothing when given nothing' {
        @(Select-DownloadLinks -Links @()).Count | Should -Be 0
    }
}

Describe 'Region detection' {

    It 'reads the region out of a real Repo slug' {
        Get-RgtRegions 'https://retrogametalk.com/repo/ps2-iso/shin-megami-tensei-persona-3-fes-usa-2/' '' | Should -Contain 'usa'
        Get-RgtRegions 'https://retrogametalk.com/repo/ps2-iso/shin-megami-tensei-persona-3-europe/' ''   | Should -Contain 'europe'
        Get-RgtRegions 'https://retrogametalk.com/repo/ps2-iso/persona-3-fes-japan/' ''                   | Should -Contain 'japan'
    }

    It 'reads the region out of the title when the slug is silent' {
        Get-RgtRegions '' 'Some Game (Korea)' | Should -Contain 'korea'
        Get-RgtRegions '' 'Some Game (World)' | Should -Contain 'world'
    }

    It 'treats PAL as Europe' {
        Get-RgtRegions '' 'Some Game (PAL)' | Should -Contain 'europe'
    }

    It 'does not invent a region from an unrelated word' {
        # 'usa' inside 'Yakusa' must not read as the USA region.
        @(Get-RgtRegions 'https://retrogametalk.com/repo/ps2-iso/yakusa/' 'Yakusa') | Should -Not -Contain 'usa'
    }

    It 'returns nothing when no region is stated' {
        @(Get-RgtRegions 'https://retrogametalk.com/repo/ps2-iso/some-game/' 'Some Game').Count | Should -Be 0
    }
}

Describe 'Result selection' {

    BeforeAll {
        $script:Fixture = @(Get-RgtResultsFromHtml (Get-Fixture 'search-results.html'))
    }

    It 'prefers the base game over an edition, against the real result set' {
        # The fixture holds FES, Spanish, Japan, UNDUB and hack variants alongside the base.
        $pick = Select-RgtResult -Results $script:Fixture -Query 'Persona 3' -Region ''
        $pick.Title | Should -BeExactly 'Shin Megami Tensei: Persona 3'
        $pick.Url   | Should -BeExactly 'https://retrogametalk.com/repo/ps2-iso/shin-megami-tensei-persona-3-usa/'
    }

    It 'honours an explicitly requested edition' {
        $pick = Select-RgtResult -Results $script:Fixture -Query 'Persona 3 FES' -Region ''
        $pick.Title | Should -Match 'FES'
    }

    It 'honours a requested region' {
        $pick = Select-RgtResult -Results $script:Fixture -Query 'Persona 3' -Region 'europe'
        (Get-RgtRegions $pick.Url $pick.Title) | Should -Contain 'europe'
    }

    It 'avoids hacks when a clean release exists' {
        $pick = Select-RgtResult -Results $script:Fixture -Query 'Persona 3' -Region ''
        $pick.Url | Should -Not -Match 'hack'
    }

    It 'returns the only candidate without scoring it' {
        $one = @([PSCustomObject]@{ Title = 'Solo'; Url = 'https://retrogametalk.com/repo/ps2-iso/solo/'; Platform = 'ps2-iso' })
        (Select-RgtResult -Results $one -Query 'anything' -Region '').Title | Should -BeExactly 'Solo'
    }

    It 'returns null for an empty result set' {
        Select-RgtResult -Results @() -Query 'x' -Region '' | Should -BeNullOrEmpty
    }
}

Describe 'Failure classification' {

    It 'names a 403 as a server-side gate' {
        (Get-RgtFailureReason 'The remote server returned an error: (403) Forbidden.').Code | Should -BeExactly 'rgt-forbidden'
    }

    It 'names rate limiting' {
        (Get-RgtFailureReason 'The remote server returned an error: (429) Too Many Requests.').Code | Should -BeExactly 'rgt-ratelimited'
    }

    It 'names a server error' {
        (Get-RgtFailureReason 'The remote server returned an error: (503) Service Unavailable.').Code | Should -BeExactly 'rgt-server-error'
    }

    It 'names a timeout' {
        (Get-RgtFailureReason 'The operation has timed out').Code | Should -BeExactly 'rgt-timeout'
    }

    It 'names a DNS or connection failure' {
        (Get-RgtFailureReason 'The remote name could not be resolved').Code | Should -BeExactly 'rgt-unreachable'
    }

    It 'falls back to a generic search error' {
        (Get-RgtFailureReason 'something else entirely').Code | Should -BeExactly 'search-error'
    }

    It 'always returns text for the user' {
        foreach ($m in @('403 Forbidden', '429', '500', 'timed out', 'could not be resolved', 'weird')) {
            (Get-RgtFailureReason $m).Text | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Session handling' {

    It 'reuses one cookie jar across calls so the nonce stays valid' {
        Reset-RgtSession
        $a = Get-RgtSession
        $b = Get-RgtSession
        [object]::ReferenceEquals($a, $b) | Should -BeTrue
    }

    It 'issues a new jar after a reset' {
        Reset-RgtSession
        $a = Get-RgtSession
        Reset-RgtSession
        [object]::ReferenceEquals($a, (Get-RgtSession)) | Should -BeFalse
    }

    It 'sends a browser User-Agent' {
        Reset-RgtSession
        (Get-RgtSession).UserAgent | Should -Match '^Mozilla/5\.0'
    }

    It 'never sends credentials or a login request' {
        # The Repo needs no account; a login POST reappearing here is a regression.
        $script:Uris = @()
        Mock -CommandName Invoke-WebRequest -MockWith {
            $script:Uris += Get-RequestedUri $Uri
            New-Response (Get-Fixture 'search-results.html')
        }
        Invoke-RgtSearch -SearchQuery 'Persona 3' -PlatformSlug 'ps2-iso' | Out-Null
        $script:Uris | Should -Not -Contain 'https://retrogametalk.com/login/login'
        foreach ($u in $script:Uris) { $u | Should -Not -Match '/login' }
    }
}
