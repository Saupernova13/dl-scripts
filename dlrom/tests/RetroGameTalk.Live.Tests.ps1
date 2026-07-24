# Live integration tests: these hit retrogametalk.com for real. Nothing is mocked.
#
# They exist because the mocked suite can only prove dlrom is self-consistent - it cannot
# notice that the site renamed a category, changed a filter value, or started demanding a
# login. That is exactly the class of breakage that killed the cdromance integration, so
# these assert against the live catalogue: every platform slug, the filter values, and a
# real, byte-serving download URL for a known ROM on each major console.
#
# Excluded from a normal run because they are slow and depend on the network:
#     Invoke-Pester .\dlrom\tests -Tag Live      # run them
#     Invoke-Pester .\dlrom\tests                # skip them (default)

# Pester expands -ForEach while DISCOVERING tests, which happens before BeforeAll runs.
# The platform tables therefore have to be loaded here as well, or the per-platform cases
# below silently expand to nothing and the suite reports success having tested no platform.
BeforeDiscovery {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Logging.ps1')
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'RetroGameTalk.ps1')
    $script:AllSlugs = @($PLATFORM_SLUGS.Values | Select-Object -Unique | Sort-Object)
}

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $ModuleRoot 'Logging.ps1')
    . (Join-Path $ModuleRoot 'RetroGameTalk.ps1')
    . (Join-Path $ModuleRoot 'Ps2TorrentIndex.ps1')

    $script:LOG_QUIET   = $true
    $script:LOG_VERBOSE = $false

    function Get-LiveHtml {
        param([string]$Uri)
        (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = $HTTP_HEADERS['User-Agent'] }).Content
    }

    # Resolve a query the way dlrom does, and hand back the links it would download.
    function Resolve-LiveLinks {
        param([string]$Query, [string]$Alias, [string]$Region = '')
        $slug    = $PLATFORM_SLUGS[$Alias]
        $results = @(Invoke-RgtSearch -SearchQuery $Query -PlatformSlug $slug -SearchRegion $Region)
        if ($results.Count -eq 0) { return @() }
        $pick    = Select-RgtResult -Results $results -Query $Query -Region $Region
        return @(Select-DownloadLinks -Links @(Get-RgtDownloadLinks -GamePageUrl $pick.Url))
    }
}

Describe 'The Repo is reachable and open' -Tag Live {

    It 'serves the Repo index to an anonymous client' {
        $html = Get-LiveHtml 'https://retrogametalk.com/repo/'
        $html | Should -Match 'game-container|games-loop'
    }

    It 'still gates only in the browser, never server-side' {
        # If this ever fails, The Repo has started enforcing membership for real and dlrom
        # needs a login again. That is the single assumption the whole no-auth design rests on.
        $html = Get-LiveHtml 'https://retrogametalk.com/repo/'
        $html | Should -Match 'xf_online'   # the client-side check is still the gate
        $html | Should -Not -Match '<form[^>]*action="/login/login"'
    }
}

Describe 'Every platform resolves on the live site' -Tag Live {

    It 'has a live category page for <_>' -ForEach $AllSlugs {
        $rows = @(Get-RgtResultsFromHtml (Get-LiveHtml "https://retrogametalk.com/repo/$_/"))
        $rows.Count | Should -BeGreaterThan 0 -Because "https://retrogametalk.com/repo/$_/ should list games"
        # Everything on a category page must belong to that category.
        foreach ($r in $rows) { $r.Platform | Should -BeExactly $_ }
    }
}

Describe 'Search filters are accepted by the live site' -Tag Live {

    # A rejected platform filter returns zero results rather than an error, so each case
    # searches for a term taken from that platform's own catalogue.
    It 'filters correctly for <_>' -ForEach $AllSlugs {
        $slug    = $_
        $listing = @(Get-RgtResultsFromHtml (Get-LiveHtml "https://retrogametalk.com/repo/$slug/"))
        $listing.Count | Should -BeGreaterThan 0

        # Longest word in a real title: distinctive, and never an Elasticsearch stopword.
        $term = ($listing[0].Title -split '[^A-Za-z0-9]+' |
                 Where-Object { $_.Length -ge 4 } | Sort-Object Length -Descending | Select-Object -First 1)
        if (-not $term) { Set-ItResult -Skipped -Because 'no usable search term on this platform' ; return }

        $rows = @(Invoke-RgtSearch -SearchQuery $term -PlatformSlug $slug)
        $rows.Count | Should -BeGreaterThan 0 -Because "the '$slug' filter should not silently match nothing"
        foreach ($r in $rows) { $r.Platform | Should -BeExactly $slug -Because 'the filter must not leak other platforms' }
    }
}

Describe 'Known ROMs resolve to real download URLs' -Tag Live {

    # One well-known title per major console, including every platform whose slug or search
    # filter changed when the catalogue moved off cdromance.
    $cases = @(
        @{ Alias = 'ps2';       Query = 'Persona 3';        Expect = 'ps2-iso' }
        @{ Alias = 'psx';       Query = 'Crash Bandicoot';  Expect = 'psx-iso' }
        @{ Alias = 'psp';       Query = 'Daxter';           Expect = 'psp' }
        @{ Alias = 'n64';       Query = 'Mario 64';         Expect = 'n64-roms' }
        @{ Alias = 'gamecube';  Query = 'Wind Waker';       Expect = 'gamecube' }
        @{ Alias = 'snes';      Query = 'Chrono Trigger';   Expect = 'snes-rom' }
        @{ Alias = 'nes';       Query = 'Metroid';          Expect = 'nes-roms' }
        @{ Alias = 'gba';       Query = 'Golden Sun';       Expect = 'gba-roms' }
        @{ Alias = 'gbc';       Query = 'Oracle of Ages';   Expect = 'gameboy-color-roms' }
        @{ Alias = 'gb';        Query = 'Tetris';           Expect = 'gameboy-roms' }
        @{ Alias = 'nds';       Query = 'Castlevania';      Expect = 'nds-roms' }
        @{ Alias = 'dreamcast'; Query = 'Sonic Adventure';  Expect = 'dc-iso' }
        @{ Alias = 'saturn';    Query = 'Panzer Dragoon';   Expect = 'sega_saturn_isos' }
        @{ Alias = 'genesis';   Query = 'Sonic';            Expect = 'sega_genesis_roms' }
    )

    It 'resolves <Query> on <Alias> to a downloadable file' -ForEach $cases {
        $slug    = $PLATFORM_SLUGS[$Alias]
        $slug | Should -BeExactly $Expect

        $results = @(Invoke-RgtSearch -SearchQuery $Query -PlatformSlug $slug)
        $results.Count | Should -BeGreaterThan 0 -Because "'$Query' should exist on $Alias"

        $pick = Select-RgtResult -Results $results -Query $Query -Region ''
        $pick.Url      | Should -Match "^https://retrogametalk\.com/repo/$([regex]::Escape($slug))/[^/]+/$"
        $pick.Platform | Should -BeExactly $slug

        $links = @(Select-DownloadLinks -Links @(Get-RgtDownloadLinks -GamePageUrl $pick.Url))
        $links.Count | Should -BeGreaterThan 0 -Because 'the reveal endpoint should return links'

        foreach ($l in $links) {
            $l.Url   | Should -Match '^https://dl[0-9a-z]*\.retrogametalk\.com/download\.php\?'
            $l.Url   | Should -Match 'key=\d+'
            $l.Label | Should -Match '\.(7z|zip|rar|iso|bin|img|chd|pbp)$'
        }
    }
}

Describe 'A resolved link actually serves the ROM' -Tag Live {

    It 'returns file bytes with no cookies at all' {
        # This is the assumption Motrix/AB/aria2c depend on: the ?key= in the query string
        # is the whole authorisation, so a downloader with an empty cookie jar can fetch it.
        # @() matters: PowerShell unwraps a one-element array, and .Count on a bare
        # PSCustomObject is $null under PowerShell 5.1.
        $links = @(Resolve-LiveLinks -Query 'Tetris' -Alias 'gb')
        $links.Count | Should -BeGreaterThan 0

        $url  = $links[0].Url
        $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) "dlrom-live-$([guid]::NewGuid().ToString('N')).bin"
        try {
            # curl.exe, not Invoke-WebRequest: Range is a restricted header on the latter.
            $headers = & curl.exe -s -o $tmp -D - -r 0-2047 --max-time 90 `
                            -A $HTTP_HEADERS['User-Agent'] $url 2>$null | Out-String

            $headers | Should -Match 'HTTP/[\d.]+ 206'          # range honoured => resumable
            $headers | Should -Match 'Content-Disposition:.*attachment'
            (Get-Item $tmp).Length | Should -Be 2048
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Region and sort filters change the live result set' -Tag Live {

    It 'narrows results when a region is given' {
        $all = @(Invoke-RgtSearch -SearchQuery 'Persona' -PlatformSlug 'ps2-iso')
        $usa = @(Invoke-RgtSearch -SearchQuery 'Persona' -PlatformSlug 'ps2-iso' -SearchRegion 'usa')
        $all.Count | Should -BeGreaterThan 0
        $usa.Count | Should -BeGreaterThan 0
        $usa.Count | Should -BeLessOrEqual $all.Count
    }

    It 'accepts every documented sort order' {
        foreach ($sort in @('latest', 'downloads', 'voted', 'alpha')) {
            $rows = @(Invoke-RgtSearch -SearchQuery 'Mario' -PlatformSlug 'n64-roms' -SearchSort $sort)
            $rows.Count | Should -BeGreaterThan 0 -Because "sorted=$sort should still return results"
        }
    }

    It 'returns an empty set for a query that matches nothing' {
        @(Invoke-RgtSearch -SearchQuery 'zzzznotarealgamezzzz' -PlatformSlug 'ps2-iso').Count | Should -Be 0
    }
}
