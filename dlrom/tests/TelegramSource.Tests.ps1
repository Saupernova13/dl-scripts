# Offline tests for dlrom's Telegram ROM source: NswtlBot.ps1 (reading bot replies) and
# TelegramSource.ps1 (routing, the conversation, the qBittorrent handoff, the job record).
#
# Nothing touches the network. The reply parser runs against REAL bot messages captured live
# (tests/fixtures/telegram/; synthetic-truncated.txt is the one hand-made fixture, because no
# truncated title has been caught yet). The conversation functions run against mocked
# lib/Telegram calls, so the sequencing - what is sent, what counts as a reply, when pages are
# read - is the production code. The live check is TelegramSource.Live.Tests.ps1.

BeforeAll {
    $script:ModuleRoot  = Split-Path -Parent $PSScriptRoot
    $script:FixtureRoot = Join-Path (Join-Path $PSScriptRoot 'fixtures') 'telegram'

    . (Join-Path $ModuleRoot 'Constants.ps1')
    . (Join-Path $ModuleRoot 'Common.ps1')
    . (Join-Path $ModuleRoot 'Logging.ps1')
    . (Join-Path $ModuleRoot 'RetroGameTalk.ps1')
    . (Join-Path $ModuleRoot 'Ps2TorrentIndex.ps1')   # Select-RgtResult borrows its matchers
    . (Join-Path $ModuleRoot 'Jobs.ps1')
    . (Join-Path $ModuleRoot 'Clean.ps1')
    . (Join-Path $ModuleRoot 'QbitTorrent.ps1')
    . (Join-Path $ModuleRoot 'NswtlBot.ps1')
    . (Join-Path $ModuleRoot 'TelegramSource.ps1')
    . (Join-Path $ModuleRoot 'TelegramJob.ps1')

    $script:LOG_QUIET   = $true
    $script:LOG_VERBOSE = $false
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

    # Jobs land in a scratch dir, never the real jobs folder.
    $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) "dlrom-tgsrc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:Scratch -Force | Out-Null
    function Get-DlromJobsDir { return $script:Scratch }
    function Get-DlScriptsDataDir { param([string]$SubPath = '') return $script:Scratch }

    # Stand-ins for the lib/Telegram client, so the functions under test can be mocked.
    function Connect-Telegram { param([int]$Dc = 0) }
    function Resolve-TgPeer { param([string]$Username, [switch]$Refresh) }
    function Send-TgMessage { param($Peer, [string]$Text, [switch]$NoWebPage) }
    function Get-TgHistory { param($Peer, [int]$Limit = 20, [int]$MinId = 0) }
    function Wait-TgReply { param($Peer, [int]$AfterId = 0, [int]$TimeoutSec = 60, [scriptblock]$Predicate = { $true }, [double]$PollSec = 1.5) }
    function Save-TgDocument { param($Document, [string]$Path, [scriptblock]$OnProgress = $null) }
    function Invoke-TgApi { param($Query, [int]$Dc = 0, [string]$ResultType = '', [switch]$NoAuthorize, [int]$MaxFloodSleepSec = 60) }
    function Get-TgSession { }
    function Initialize-DlromTelegram { }

    function Get-Fixture { param([string]$Name) return [System.IO.File]::ReadAllText((Join-Path $script:FixtureRoot $Name)) }
    function Get-FixtureReply { param([string]$Name) return (Read-NswtlReply -Text (Get-Fixture $Name) -Platform 'psvita') }

    # An exception carrying a Telegram error name, the way the client throws them.
    function New-TgError { param([string]$Name) $e = New-Object System.Exception "Telegram error: $Name"; $e.Data['tgError'] = $Name; return $e }

    # A page-button row like the one under a real result list.
    function New-PageMarkup {
        param([int]$Current = 1, [int]$Count = 3, [string]$Tag = 'q')
        $buttons = @(1..$Count | ForEach-Object {
            $label = if ($_ -eq $Current) { "-$_-" } else { "$_" }
            @{ _ = 'keyboardInlineButton'; text = $label
               type = @{ _ = 'inlineButtonTypeCallback'; data = [System.Text.Encoding]::ASCII.GetBytes("${Tag}_&_1_&_$_") } }
        })
        return @{ _ = 'replyInlineMarkup'; rows = @(@{ _ = 'keyboardInlineButtonRow'; buttons = $buttons }) }
    }
    function New-BotMessage {
        param([int]$Id, [string]$Text, $Markup = $null, $Document = $null)
        return @{ id = $Id; out = $false; text = $Text; replyMarkup = $Markup; document = $Document; entities = @() }
    }
}

AfterAll {
    if ($script:Scratch -and (Test-Path $script:Scratch)) { Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'NSWTL reply parser' {

    It 'reads a "Title [size]" list (PS Vita layout)' {
        $r = Get-FixtureReply 'results-danganronpa.txt'
        $r.Kind    | Should -Be 'results'
        $r.Total   | Should -Be 5
        $r.Results.Count | Should -Be 5
        $first = $r.Results[0]
        $first.Title       | Should -BeExactly 'Danganronpa - Trigger Happy Havoc'
        $first.SizeText    | Should -BeExactly '2.63 GB'
        $first.SizeBytes   | Should -Be ([long][Math]::Round(2.63 * 1GB))
        $first.DownloadCmd | Should -BeExactly '/download471'
        $first.CoverCmd    | Should -BeExactly '/cover471'
        $first.Id          | Should -BeExactly '471'
        $first.Truncated   | Should -BeFalse
        $first.Url         | Should -BeExactly '/download471'
        $first.Platform    | Should -BeExactly 'psvita'
    }

    It 'keeps every entry of a full first page and reports the total over all pages' {
        $r = Get-FixtureReply 'results-page1.txt'
        $r.Total | Should -Be 72
        $r.Results.Count | Should -Be 12
        $r.Results[0].Title | Should -BeExactly 'A Rose in the Twilight'
        $r.Results[11].Title | Should -BeExactly 'Berserk and the Band of the Hawk'
        # the footer ("Dont know what to play? ... /recommended") is not an entry
        @($r.Results | Where-Object { $_.Title -match 'recommend|Dont know' }).Count | Should -Be 0
    }

    It 'reads the edited second page the same way' {
        $r = Get-FixtureReply 'results-page2.txt'
        $r.Results[0].Title | Should -BeExactly 'Bloodstained - Curse of the Moon'
        $r.Results.Count | Should -Be 12
    }

    It 'reads the multi-line layout (Switch): title, note, Size:, Download:' {
        $r = Get-FixtureReply 'results-switch-page1.txt'
        $r.Kind  | Should -Be 'results'
        $r.Total | Should -Be 29
        $r.Results.Count | Should -Be 12
        $r.Results[0].Title | Should -BeExactly 'Arcade Archives Mario Bros, Arcade Archives VS SUPER MARIO BROS'
        $r.Results[0].Note  | Should -Match 'Arcade Archives Collection'
        $r.Results[0].SizeText | Should -BeExactly '26.05 GB'
        $r.Results[0].DownloadCmd | Should -BeExactly '/download165'
        $kart = $r.Results | Where-Object { $_.Title -eq 'Mario Kart 8 Deluxe' }
        $kart.SizeText | Should -BeExactly '8.08 GB'
        $kart.DownloadCmd | Should -BeExactly '/download1606'
    }

    It 'reads the size-less /rate layout (3DS)' {
        $r = Get-FixtureReply 'results-3ds.txt'
        $r.Kind  | Should -Be 'results'
        $r.Total | Should -Be 7
        $r.Results.Count | Should -Be 7
        $r.Results[0].Title | Should -BeExactly "Legend of Zelda - Majora's Mask 3D,The"
        $r.Results[0].SizeText | Should -BeNullOrEmpty
        $r.Results[0].SizeBytes | Should -Be 0
        $r.Results[0].DownloadCmd | Should -BeExactly '/download690'
        $r.Results[0].CoverCmd    | Should -BeExactly '/rate690'
    }

    It 'keeps non-Latin titles and same-titled entries apart' {
        $ps4 = Get-FixtureReply 'results-ps4.txt'
        $ps4.Results[0].Title | Should -Match '^Bloodborne - \S+ \S+$'
        $ps3 = Get-FixtureReply 'results-ps3.txt'
        $ascension = @($ps3.Results | Where-Object { $_.Title -eq 'God of War - Ascension' })
        $ascension.Count | Should -Be 3
        @($ascension.DownloadCmd | Select-Object -Unique).Count | Should -Be 3
    }

    It 'ignores the extra footer some bots add' {
        $r = Get-FixtureReply 'results-ps3.txt'      # ends with the "Bots may disappear ... /gui" notice
        $r.Results.Count | Should -Be 10
        @($r.Results | Where-Object { $_.Title -match 'Bots may disappear' }).Count | Should -Be 0
    }

    It 'flags a title the bot cut short' {
        $r = Get-FixtureReply 'synthetic-truncated.txt'
        $r.Results[0].Truncated | Should -BeTrue
        $r.Results[0].Title | Should -Match '\.\.\.$'
        $r.Results[0].SizeText | Should -BeExactly '6.38 GB'
        $r.Results[1].Truncated | Should -BeFalse
    }

    It 'flags a title cut with a single ellipsis character too' {
        $e = @(ConvertFrom-NswtlResults -Text ("A very long title" + [char]0x2026 + " [1 GB]`n/download1 /cover1`n"))
        $e[0].Truncated | Should -BeTrue
    }

    It 'recognises "nothing found" and returns no results' {
        $r = Get-FixtureReply 'not-found.txt'
        $r.Kind  | Should -Be 'notfound'
        $r.Total | Should -Be 0
        $r.Results.Count | Should -Be 0
    }

    It 'treats the "Your torrent is ready" message as unrelated to a search' {
        (Get-FixtureReply 'torrent-ready.txt').Kind | Should -Be 'other'
    }

    It 'does not mistake a weekly top-list broadcast for results' {
        $broadcast = "Top-15 most downloaded games this week:`n`n1. God of war Collection PS VITA [3.97 GB]`n/download91 /cover91`n2. Gravity Rush [2.79 GB]`n/download405 /cover405`n"
        (Read-NswtlReply -Text $broadcast).Kind | Should -Be 'other'
    }

    It 'numbered digest lines still parse if handed to the entry reader directly' {
        $e = @(ConvertFrom-NswtlResults -Text "1. Gravity Rush [2.79 GB]`n/download405 /cover405`n")
        $e[0].Title | Should -BeExactly 'Gravity Rush'
    }

    It 'classifies subscription gates and rate limits (heuristic: no live sample yet)' {
        (Read-NswtlReply -Text 'To use this bot you must subscribe to our channel @nswtl first.').Kind | Should -Be 'gate'
        (Read-NswtlReply -Text 'Too many requests. Please try again later.').Kind | Should -Be 'ratelimit'
        (Read-NswtlReply -Text 'No torrents found for your query').Kind | Should -Be 'notfound'
        (Read-NswtlReply -Text '').Kind | Should -Be 'other'
    }

    It 'converts size text to bytes' {
        ConvertTo-NswtlSizeBytes '1 KB'    | Should -Be 1024
        ConvertTo-NswtlSizeBytes '27.8 MB' | Should -Be ([long][Math]::Round(27.8 * 1MB))
        ConvertTo-NswtlSizeBytes '2,5 GB'  | Should -Be ([long](2.5 * 1GB))
        ConvertTo-NswtlSizeBytes 'a lot'   | Should -Be 0
        ConvertTo-NswtlSizeBytes ''        | Should -Be 0
    }
}

Describe 'NSWTL message shapes' {

    It 'finds the numbered page buttons and which one is current' {
        $pages = @(Get-NswtlPageButtons (New-BotMessage 1 'x' (New-PageMarkup -Current 1 -Count 6)))
        $pages.Count | Should -Be 6
        ($pages | Where-Object Current).Page | Should -Be 1
        $pages[1].Page | Should -Be 2
        [System.Text.Encoding]::ASCII.GetString($pages[1].Data) | Should -Be 'q_&_1_&_2'
    }

    It 'reports no buttons for a single page or a message without markup' {
        @(Get-NswtlPageButtons (New-BotMessage 1 'x')).Count | Should -Be 0
        @(Get-NswtlPageButtons $null).Count | Should -Be 0
    }

    It 'recognises the torrent document by mime type or extension' {
        Test-NswtlTorrentMessage (New-BotMessage 1 'r' $null @{ mime = 'application/x-bittorrent'; file_name = 'a' }) | Should -BeTrue
        Test-NswtlTorrentMessage (New-BotMessage 1 'r' $null @{ mime = 'application/octet-stream'; file_name = 'Game.torrent' }) | Should -BeTrue
        Test-NswtlTorrentMessage (New-BotMessage 1 'r' $null @{ mime = 'image/png'; file_name = 'cover.png' }) | Should -BeFalse
        Test-NswtlTorrentMessage (New-BotMessage 1 'no document') | Should -BeFalse
    }
}

Describe 'Picking from bot results' {

    It 'takes the base game over its demo and sequels' {
        $r = (Get-FixtureReply 'results-danganronpa.txt').Results
        (Select-TgResult -Results $r -Query 'Danganronpa').Title | Should -BeExactly 'Danganronpa - Trigger Happy Havoc'
        (Select-TgResult -Results $r -Query 'Danganronpa V3').Title | Should -BeExactly 'Danganronpa V3 - Killing Harmony'
    }

    It 'goes through Select-RgtResult (the demo is demoted by its scorer)' {
        $r = (Get-FixtureReply 'results-danganronpa.txt').Results
        $direct = Select-RgtResult -Results $r -Query 'Danganronpa V3' -Region ''
        (Select-TgResult -Results $r -Query 'Danganronpa V3').DownloadCmd | Should -Be $direct.DownloadCmd
    }

    It 'prefers a game over its update or DLC listing' {
        $r = (Get-FixtureReply 'results-3ds.txt').Results
        (Select-TgResult -Results $r -Query 'Zelda').Title | Should -Not -Match '\bUpdate\b'
    }

    It 'still takes an update when the query asks for one, or nothing else is left' {
        $r = (Get-FixtureReply 'results-3ds.txt').Results
        (Select-TgResult -Results $r -Query 'Zelda Tri Force Heroes Update').Title | Should -Match 'Update'
        $only = @($r | Where-Object { $_.Title -match 'Update' })
        (Select-TgResult -Results $only -Query 'Zelda').Title | Should -Match 'Update'
    }

    It 'refuses a fuzzy hit that lacks a query word (Halo 3 is not Halo Reach)' {
        $r = @([PSCustomObject]@{ Title = 'Halo -Reach'; Url = '/download1'; DownloadCmd = '/download1'; Truncated = $false })
        Select-TgResult -Results $r -Query 'Halo 3' | Should -BeNullOrEmpty
    }

    It 'lets a cut-short title through on half the query words' {
        $r = @([PSCustomObject]@{ Title = 'Danganronpa Another Episode - Ultra Despair G'; Url = '/download378'; DownloadCmd = '/download378'; Truncated = $true })
        (Select-TgResult -Results $r -Query 'Danganronpa Another Episode Ultra Despair Girls').DownloadCmd | Should -Be '/download378'
    }

    It 'returns null for no results' {
        Select-TgResult -Results @() -Query 'x' | Should -BeNullOrEmpty
    }

    It 'refuses the bot''s fuzzy match when it is the wrong game (live Halo 3 reply)' {
        $r = (Get-FixtureReply 'results-xbox360.txt').Results
        Select-TgResult -Results $r -Query 'Halo 3' | Should -BeNullOrEmpty
    }
}

Describe 'Platform and bot tables' {

    It 'gives every platform alias a folder and a bot' {
        foreach ($alias in $script:TGSRC_PLATFORM_ALIASES.Keys) {
            $key = $script:TGSRC_PLATFORM_ALIASES[$alias]
            $script:TGSRC_PLATFORM_FOLDERS.ContainsKey($key) | Should -BeTrue -Because "'$alias' -> '$key' needs a folder"
            $script:TGSRC_DEFAULT_BOTS.ContainsKey($key)     | Should -BeTrue -Because "'$key' needs a default bot"
        }
    }

    It 'names the EmuDeck folders for the Telegram-only consoles' {
        (Get-TgPlatformFolder 'switch')  | Should -Be 'switch'
        (Get-TgPlatformFolder '3ds')     | Should -Be 'n3ds'
        (Get-TgPlatformFolder 'ps3')     | Should -Be 'ps3'
        (Get-TgPlatformFolder 'ps4')     | Should -Be 'ps4'
        (Get-TgPlatformFolder 'ps5')     | Should -Be 'ps5'
        (Get-TgPlatformFolder 'xbox360') | Should -Be 'xbox360'
        (Get-TgPlatformFolder 'xbox')    | Should -Be 'xbox'
        (Get-TgPlatformFolder 'wiiu')    | Should -Be 'wiiu'
    }

    It 'agrees with the RetroGameTalk folder table on the shared consoles' {
        foreach ($alias in 'ps2', 'psx', 'ps1', 'psp', 'vita', 'nds', 'wii', 'gc', 'gamecube', 'dreamcast') {
            $slug = $PLATFORM_SLUGS[$alias]
            (Get-TgPlatformFolder (Resolve-TgPlatformKey $alias)) | Should -Be $PLATFORM_FOLDERS[$slug] -Because $alias
        }
    }

    It 'resolves the documented aliases' {
        Resolve-TgPlatformKey 'NSW'    | Should -Be 'switch'
        Resolve-TgPlatformKey 'ns'     | Should -Be 'switch'
        Resolve-TgPlatformKey 'n3ds'   | Should -Be '3ds'
        Resolve-TgPlatformKey 'x360'   | Should -Be 'xbox360'
        Resolve-TgPlatformKey 'ps1'    | Should -Be 'psx'
        Resolve-TgPlatformKey 'ps2-iso' | Should -Be 'ps2'
        Resolve-TgPlatformKey 'n64'    | Should -BeNullOrEmpty
        Resolve-TgPlatformKey ''       | Should -BeNullOrEmpty
    }

    It 'uses the built-in bots, sharing one for Wii and Wii U' {
        Get-TgBotName -Key 'vita' | Should -Be 'PSVita_library_bot'
        Get-TgBotName -Key 'wii'  | Should -Be 'Wii_library_bot'
        Get-TgBotName -Key 'wiiu' | Should -Be 'Wii_library_bot'
        Get-TgBotName -Key 'xbox360' | Should -Be 'Xbox360_library_bot'
        Get-TgBotName -Key 'nope' | Should -BeNullOrEmpty
    }

    It 'lets [rom].telegramBots override a bot, by any alias, and falls back for the rest' {
        $cfg = [PSCustomObject]@{ vita = '@NewVita_bot'; ns = 'NewSwitch_bot'; ps1 = 'NewPsx_bot'; ps4 = '  ' }
        Get-TgBotName -Key 'vita'   -Overrides $cfg | Should -Be 'NewVita_bot'
        Get-TgBotName -Key 'switch' -Overrides $cfg | Should -Be 'NewSwitch_bot'
        Get-TgBotName -Key 'psx'    -Overrides $cfg | Should -Be 'NewPsx_bot'
        Get-TgBotName -Key 'ps4'    -Overrides $cfg | Should -Be 'PS4_libr_bot'      # blank override ignored
        Get-TgBotName -Key 'ps3'    -Overrides $cfg | Should -Be 'PS3_libr_bot'      # missing key falls back
        Get-TgBotName -Key 'vita'   -Overrides @{ vita = 'FromHashtable_bot' } | Should -Be 'FromHashtable_bot'
        Get-TgBotName -Key 'vita'   -Overrides ([PSCustomObject]@{}) | Should -Be 'PSVita_library_bot'
    }

    It 'reads the override through Get-CfgValue from the real config shape' {
        Set-DlromConfig ([PSCustomObject]@{ telegramBots = ('{ "vita": "Cfg_bot" }' | ConvertFrom-Json) })
        try { Get-TgBotName -Key 'vita' -Overrides (Get-CfgValue 'telegramBots' $null) | Should -Be 'Cfg_bot' }
        finally { Set-DlromConfig $null }
    }
}

Describe 'Source routing' {

    It 'maps --source spellings' {
        Resolve-DlromSourceName ''            | Should -Be 'auto'
        Resolve-DlromSourceName 'AUTO'        | Should -Be 'auto'
        Resolve-DlromSourceName 'tg'          | Should -Be 'telegram'
        Resolve-DlromSourceName 'Telegram'    | Should -Be 'telegram'
        Resolve-DlromSourceName 'rgt'         | Should -Be 'rgt'
        Resolve-DlromSourceName 'retrogametalk' | Should -Be 'rgt'
        Resolve-DlromSourceName 'repo'        | Should -Be 'rgt'
        Resolve-DlromSourceName 'carrier-pigeon' | Should -BeNullOrEmpty
    }

    It 'auto sends Telegram-only consoles straight to Telegram' {
        foreach ($p in 'switch', 'nsw', '3ds', 'ps3', 'ps4', 'ps5', 'xbox360', 'x360', 'xbox', 'wiiu') {
            $plan = Resolve-DlromSourcePlan -Source 'auto' -Platform $p
            $plan.Primary | Should -Be 'telegram' -Because $p
            $plan.Error   | Should -BeNullOrEmpty -Because $p
            $plan.Bot     | Should -Not -BeNullOrEmpty -Because $p
        }
        (Resolve-DlromSourcePlan -Platform 'ns').Folder | Should -Be 'switch'
        (Resolve-DlromSourcePlan -Platform '3ds').Folder | Should -Be 'n3ds'
    }

    It 'auto tries RetroGameTalk first elsewhere, falling back to Telegram when a bot exists' {
        foreach ($p in 'vita', 'ps2', 'psp', 'psx', 'ps1', 'nds', 'wii', 'gc', 'gamecube', 'dreamcast') {
            $plan = Resolve-DlromSourcePlan -Source '' -Platform $p
            $plan.Primary  | Should -Be 'rgt' -Because $p
            $plan.Fallback | Should -BeTrue -Because $p
            $plan.Bot      | Should -Not -BeNullOrEmpty -Because $p
        }
    }

    It 'skips the fallback, with a reason, when it cannot apply' {
        $plan = Resolve-DlromSourcePlan -Platform 'vita' -FallbackEnabled $false
        $plan.Fallback | Should -BeFalse
        $plan.FallbackSkip | Should -Be 'disabled'

        $plan = Resolve-DlromSourcePlan -Platform ''
        $plan.Primary | Should -Be 'rgt'
        $plan.Fallback | Should -BeFalse
        $plan.FallbackSkip | Should -Be 'no-platform'

        $plan = Resolve-DlromSourcePlan -Platform 'n64'          # RetroGameTalk has it, no bot does
        $plan.Primary | Should -Be 'rgt'
        $plan.Fallback | Should -BeFalse
        $plan.FallbackSkip | Should -Be 'no-bot'
    }

    It '--source rgt never falls back, and refuses a Telegram-only console' {
        $plan = Resolve-DlromSourcePlan -Source 'rgt' -Platform 'vita'
        $plan.Primary | Should -Be 'rgt'
        $plan.Fallback | Should -BeFalse
        (Resolve-DlromSourcePlan -Source 'repo' -Platform 'switch').Error | Should -Match 'only served by the Telegram'
    }

    It '--source telegram needs a platform with a bot' {
        $plan = Resolve-DlromSourcePlan -Source 'tg' -Platform 'vita'
        $plan.Primary | Should -Be 'telegram'
        $plan.Error | Should -BeNullOrEmpty
        $plan.Bot | Should -Be 'PSVita_library_bot'
        (Resolve-DlromSourcePlan -Source 'telegram' -Platform '').Error | Should -Match 'needs --platform'
        (Resolve-DlromSourcePlan -Source 'telegram' -Platform 'n64').Error | Should -Match 'needs --platform'
    }

    It 'rejects an unknown --source' {
        (Resolve-DlromSourcePlan -Source 'ftp' -Platform 'vita').Error | Should -Match "Unknown --source 'ftp'"
    }

    It 'honours a configured bot in the plan' {
        $plan = Resolve-DlromSourcePlan -Source 'telegram' -Platform 'vita' -Overrides ([PSCustomObject]@{ vita = 'Other_bot' })
        $plan.Bot | Should -Be 'Other_bot'
    }

    It 'can resolve the console from a RetroGameTalk slug when --platform was not given' {
        $plan = Resolve-DlromSourcePlan -Platform '' -ResolvedSlug 'ps2-iso'
        $plan.TgKey | Should -Be 'ps2'
        $plan.Fallback | Should -BeTrue
    }
}

Describe 'Torrent files' {

    It 'computes the v1 infohash like qBittorrent does' {
        # d 4:info d 6:lengthi5e 4:name1:a 12:piece lengthi16384e 6:pieces20:<20 bytes> e e
        $pieces = [byte[]](1..20)
        $info = [System.Text.Encoding]::ASCII.GetBytes('d6:lengthi5e4:name1:a12:piece lengthi16384e6:pieces20:') + $pieces + [byte[]][char]'e'
        $file = [System.Text.Encoding]::ASCII.GetBytes('d8:announce3:udp4:info') + $info + [byte[]][char]'e'
        $path = Join-Path $script:Scratch 't.torrent'
        [System.IO.File]::WriteAllBytes($path, $file)
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $expected = (($sha.ComputeHash($info) | ForEach-Object { $_.ToString('x2') }) -join '')
        Get-TorrentInfoHash $path | Should -Be $expected
    }

    It 'agrees with the infohash recorded for the bundled PS2 archive torrent' {
        $dir = Join-Path (Join-Path $script:ModuleRoot 'data') 'ps2-torrent'
        $index = Get-Content -LiteralPath (Join-Path $dir 'ps2-index.json') -Raw | ConvertFrom-Json
        Get-TorrentInfoHash (Join-Path $dir 'ps2-redump.torrent') | Should -Be $index.infohash_v1
    }

    It 'refuses a file that is not a torrent' {
        $path = Join-Path $script:Scratch 'junk.torrent'
        [System.IO.File]::WriteAllText($path, 'hello')
        { Get-TorrentInfoHash $path } | Should -Throw
    }

    It 'makes document names safe for both platforms' {
        ConvertTo-SafeTorrentName 'Danganronpa - Trigger Happy Havoc [NoNpDrm] [RUS, ENG].torrent' | Should -Be 'Danganronpa - Trigger Happy Havoc [NoNpDrm] [RUS, ENG].torrent'
        ConvertTo-SafeTorrentName 'a/b:c*d?.torrent' | Should -Be 'a_b_c_d_.torrent'
        ConvertTo-SafeTorrentName '..\..\evil' | Should -Be '.._.._evil.torrent'
        ConvertTo-SafeTorrentName '' | Should -Be 'download.torrent'
        (ConvertTo-SafeTorrentName ('x' * 400)).Length | Should -BeLessOrEqual 158
    }
}

Describe 'The conversation' {

    BeforeEach {
        Set-DlromConfig ([PSCustomObject]@{ telegramMinSendGapSec = 0 })
        $script:Peer   = @{ _ = 'inputPeerUser' }
        $script:Family = Get-NswtlBotFamily
        $script:Sent   = New-Object System.Collections.Generic.List[string]
        Mock Get-TgHistory { return @() }
        Mock Send-TgMessage { $script:Sent.Add($Text); return @{ Id = 100; RandomId = 1 } }
    }
    AfterEach { Set-DlromConfig $null }

    Context 'Find-TgRomResults' {

        It 'sends the game name and returns the parsed list when it already covers the query' {
            $script:Inbox = @(
                (New-BotMessage 90 (Get-Fixture 'results-ps3.txt') $null),              # old, before our send: must be ignored by id
                (New-BotMessage 101 (Get-Fixture 'results-danganronpa.txt') $null)
            )
            Mock Wait-TgReply { foreach ($m in $script:Inbox) { if ($m.id -gt $AfterId -and (& $Predicate $m)) { return $m } } return $null }
            $s = Find-TgRomResults -Peer $script:Peer -Query 'Danganronpa' -Family $script:Family -Platform 'psvita' -TimeoutSec 5
            $script:Sent | Should -Be @('Danganronpa')
            $s.Kind | Should -Be 'results'
            $s.Results.Count | Should -Be 5
            $s.Pages | Should -Be 1
            Should -Invoke Wait-TgReply -Times 1 -ParameterFilter { $AfterId -eq 100 }
        }

        It 'ignores unrelated bot messages while waiting (broadcasts, banners)' {
            $script:Inbox = @(
                (New-BotMessage 101 'Dear friends, good day! Please donate.' $null),
                (New-BotMessage 102 (Get-Fixture 'torrent-ready.txt') $null),
                (New-BotMessage 103 (Get-Fixture 'results-danganronpa.txt') $null)
            )
            Mock Wait-TgReply { foreach ($m in $script:Inbox) { if ($m.id -gt $AfterId -and (& $Predicate $m)) { return $m } } return $null }
            (Find-TgRomResults -Peer $script:Peer -Query 'Danganronpa' -Family $script:Family -TimeoutSec 5).Results.Count | Should -Be 5
        }

        It 'reports "nothing found" without throwing' {
            $script:Inbox = @((New-BotMessage 101 (Get-Fixture 'not-found.txt') $null))
            Mock Wait-TgReply { foreach ($m in $script:Inbox) { if ($m.id -gt $AfterId -and (& $Predicate $m)) { return $m } } return $null }
            $s = Find-TgRomResults -Peer $script:Peer -Query 'zzqxjkv' -Family $script:Family -TimeoutSec 5
            $s.Kind | Should -Be 'notfound'
            $s.Results.Count | Should -Be 0
        }

        It 'throws when the bot stays silent' {
            Mock Wait-TgReply { return $null }
            { Find-TgRomResults -Peer $script:Peer -Query 'x' -Family $script:Family -TimeoutSec 1 } | Should -Throw '*did not reply*'
        }

        It 'falls back to the chat''s newest id when the send does not report one' {
            Mock Send-TgMessage { $script:Sent.Add($Text); return @{ Id = 0; RandomId = 1 } }
            Mock Get-TgHistory { return @(@{ id = 77 }) }
            $script:Inbox = @((New-BotMessage 78 (Get-Fixture 'results-danganronpa.txt') $null))
            Mock Wait-TgReply { foreach ($m in $script:Inbox) { if ($m.id -gt $AfterId -and (& $Predicate $m)) { return $m } } return $null }
            [void](Find-TgRomResults -Peer $script:Peer -Query 'Danganronpa' -Family $script:Family -TimeoutSec 5)
            Should -Invoke Wait-TgReply -Times 1 -ParameterFilter { $AfterId -eq 77 }
        }

        It 'pages through the results until one covers the query, pressing the right button' {
            $page1 = New-BotMessage 101 (Get-Fixture 'results-page1.txt') (New-PageMarkup -Current 1 -Count 6 -Tag 'the')
            $script:Inbox = @($page1)
            Mock Wait-TgReply { foreach ($m in $script:Inbox) { if ($m.id -gt $AfterId -and (& $Predicate $m)) { return $m } } return $null }
            $script:Pressed = New-Object System.Collections.Generic.List[string]
            Mock Invoke-TgApi {
                $script:Pressed.Add([System.Text.Encoding]::ASCII.GetString([byte[]]$Query.data))
                throw (New-TgError 'BOT_RESPONSE_TIMEOUT')      # these bots edit the message and never answer
            }
            # After the press the bot edits message 101 in place.
            $script:HistoryCalls = 0
            Mock Get-TgHistory {
                $script:HistoryCalls++
                if ($script:Pressed.Count -eq 0) { return @() }
                return @(@{ id = 101; out = $false; text = (Get-Fixture 'results-page2.txt'); replyMarkup = (New-PageMarkup -Current 2 -Count 6 -Tag 'the') })
            }
            # "Bloodstained" is only on page 2; page 1 does not cover the query.
            $s = Find-TgRomResults -Peer $script:Peer -Query 'Bloodstained Curse Moon' -Family $script:Family -TimeoutSec 5 -MaxPages 4
            $script:Pressed.Count | Should -Be 1
            $script:Pressed[0] | Should -Be 'the_&_1_&_2'
            $s.Pages | Should -Be 2
            $s.Results.Count | Should -Be 24
            $s.Total | Should -Be 72
            (Select-TgResult -Results $s.Results -Query 'Bloodstained Curse Moon').Title | Should -BeExactly 'Bloodstained - Curse of the Moon'
        }

        It 'does not press any button when page 1 already holds an answer' {
            $script:Inbox = @((New-BotMessage 101 (Get-Fixture 'results-page1.txt') (New-PageMarkup -Current 1 -Count 6)))
            Mock Wait-TgReply { foreach ($m in $script:Inbox) { if ($m.id -gt $AfterId -and (& $Predicate $m)) { return $m } } return $null }
            Mock Invoke-TgApi { }
            $s = Find-TgRomResults -Peer $script:Peer -Query 'Rose Twilight' -Family $script:Family -TimeoutSec 5
            Should -Invoke Invoke-TgApi -Times 0
            $s.Pages | Should -Be 1
        }

        It 'reads every page up to the cap with -AllPages (interactive picking)' {
            $script:Inbox = @((New-BotMessage 101 (Get-Fixture 'results-page1.txt') (New-PageMarkup -Current 1 -Count 6)))
            Mock Wait-TgReply { foreach ($m in $script:Inbox) { if ($m.id -gt $AfterId -and (& $Predicate $m)) { return $m } } return $null }
            $script:N = 0
            Mock Invoke-TgApi { $script:N++; throw (New-TgError 'BOT_RESPONSE_TIMEOUT') }
            Mock Get-TgHistory {
                if ($script:N -eq 0) { return @() }
                $text = if ($script:N % 2) { Get-Fixture 'results-page2.txt' } else { Get-Fixture 'results-page1.txt' }
                # distinct text per press so the "edit landed" check sees a change
                return @(@{ id = 101; out = $false; text = ($text + "`n#$script:N"); replyMarkup = (New-PageMarkup -Current ($script:N + 1) -Count 6) })
            }
            $s = Find-TgRomResults -Peer $script:Peer -Query 'Rose' -Family $script:Family -TimeoutSec 5 -MaxPages 3 -AllPages
            $s.Pages | Should -Be 3
            $script:N | Should -Be 2
        }

        It 'lets a real callback error through (only the bot''s missing answer is expected)' {
            $script:Inbox = @((New-BotMessage 101 (Get-Fixture 'results-page1.txt') (New-PageMarkup -Current 1 -Count 6)))
            Mock Wait-TgReply { foreach ($m in $script:Inbox) { if ($m.id -gt $AfterId -and (& $Predicate $m)) { return $m } } return $null }
            Mock Invoke-TgApi { throw (New-TgError 'MESSAGE_ID_INVALID') }
            { Find-TgRomResults -Peer $script:Peer -Query 'zzz nothing' -Family $script:Family -TimeoutSec 5 } | Should -Throw '*MESSAGE_ID_INVALID*'
        }
    }

    Context 'Get-TgRomTorrent' {

        BeforeEach {
            $script:Result = [PSCustomObject]@{ Title = 'Danganronpa - Trigger Happy Havoc'; DownloadCmd = '/download471' }
            $script:Doc = @{ id = 1; access_hash = 2; file_reference = [byte[]](1, 2); dc_id = 2; size = 100
                             mime = 'application/x-bittorrent'; file_name = 'Danganronpa - Trigger Happy Havoc [NoNpDrm] [RUS, ENG].torrent' }
            Mock Wait-TgReply { foreach ($m in $script:Inbox) { if ($m.id -gt $AfterId -and (& $Predicate $m)) { return $m } } return $null }
        }

        It 'sends the command, waits for the document message and saves it' {
            $script:Inbox = @(
                (New-BotMessage 101 'Some ad' $null),
                (New-BotMessage 102 (Get-Fixture 'torrent-ready.txt') $null $script:Doc)
            )
            Mock Save-TgDocument { return $Path }
            $got = Get-TgRomTorrent -Peer $script:Peer -Result $script:Result -Family $script:Family -OutDir $script:Scratch -TimeoutSec 5
            $script:Sent | Should -Be @('/download471')
            $got.FileName | Should -Be 'Danganronpa - Trigger Happy Havoc [NoNpDrm] [RUS, ENG].torrent'
            $got.Path | Should -Be (Join-Path $script:Scratch $got.FileName)
            Should -Invoke Save-TgDocument -Times 1
        }

        It 'renews a stale file reference once by re-reading the message' {
            $script:Inbox = @((New-BotMessage 102 'ready' $null $script:Doc))
            $script:Calls = 0
            Mock Save-TgDocument { $script:Calls++; if ($script:Calls -eq 1) { throw (New-TgError 'FILE_REFERENCE_EXPIRED') }; return $Path }
            $fresh = $script:Doc.Clone(); $fresh.file_reference = [byte[]](9, 9)
            Mock Get-TgHistory { return @(@{ id = 102; out = $false; text = 'ready'; document = $fresh }) }
            $null = Get-TgRomTorrent -Peer $script:Peer -Result $script:Result -Family $script:Family -OutDir $script:Scratch -TimeoutSec 5
            $script:Calls | Should -Be 2
            Should -Invoke Save-TgDocument -Times 1 -ParameterFilter { $Document.file_reference[0] -eq 9 }
        }

        It 'does not swallow other download errors' {
            $script:Inbox = @((New-BotMessage 102 'ready' $null $script:Doc))
            Mock Save-TgDocument { throw (New-TgError 'AUTH_KEY_UNREGISTERED') }
            { Get-TgRomTorrent -Peer $script:Peer -Result $script:Result -Family $script:Family -OutDir $script:Scratch -TimeoutSec 5 } | Should -Throw '*AUTH_KEY*'
        }

        It 'reports a gate or rate limit in the bot''s own words' {
            $script:Inbox = @((New-BotMessage 102 'Too many requests. Try again later.' $null))
            { Get-TgRomTorrent -Peer $script:Peer -Result $script:Result -Family $script:Family -OutDir $script:Scratch -TimeoutSec 5 } | Should -Throw '*refused the download*Too many requests*'
        }

        It 'throws when no torrent arrives' {
            $script:Inbox = @()
            { Get-TgRomTorrent -Peer $script:Peer -Result $script:Result -Family $script:Family -OutDir $script:Scratch -TimeoutSec 1 } | Should -Throw '*no .torrent*'
        }
    }
}

Describe 'qBittorrent handoff' {

    BeforeEach {
        $script:Torrent = Join-Path $script:Scratch 'h.torrent'
        $info = [System.Text.Encoding]::ASCII.GetBytes('d6:lengthi5e4:name1:a12:piece lengthi16384e6:pieces20:') + [byte[]](1..20) + [byte[]][char]'e'
        [System.IO.File]::WriteAllBytes($script:Torrent, ([System.Text.Encoding]::ASCII.GetBytes('d4:info') + $info + [byte[]][char]'e'))
    }

    It 'adds the torrent tagged, then starts it (the add helper adds it stopped)' {
        Mock Get-QbitExistingHash { return '' }
        Mock Add-QbitTorrentFile { }
        Mock Wait-QbitHash { return 'abc123' }
        Mock Start-QbitTorrent { }
        $r = Add-TgTorrentToQbit -TorrentPath $script:Torrent -SavePath (Join-Path $script:Scratch 'save') -JobId 'job1'
        $r.Hash | Should -Be 'abc123'
        $r.AlreadyPresent | Should -BeFalse
        Should -Invoke Add-QbitTorrentFile -Times 1 -ParameterFilter { $Tag -eq 'dlrom,dlrom-job1' -and $SavePath -like '*save' }
        Should -Invoke Wait-QbitHash -Times 1 -ParameterFilter { $Tag -eq 'dlrom-job1' }
        Should -Invoke Start-QbitTorrent -Times 1 -ParameterFilter { $Hash -eq 'abc123' }
    }

    It 'leaves a torrent qBittorrent already has completely alone' {
        Mock Get-QbitExistingHash { return 'existinghash' }
        Mock Add-QbitTorrentFile { }
        Mock Start-QbitTorrent { }
        $r = Add-TgTorrentToQbit -TorrentPath $script:Torrent -SavePath (Join-Path $script:Scratch 'save') -JobId 'job2'
        $r.Hash | Should -Be 'existinghash'
        $r.AlreadyPresent | Should -BeTrue
        Should -Invoke Add-QbitTorrentFile -Times 0
        Should -Invoke Start-QbitTorrent -Times 0
    }

    It 'fails clearly when qBittorrent never registers the torrent' {
        Mock Get-QbitExistingHash { return '' }
        Mock Add-QbitTorrentFile { }
        Mock Wait-QbitHash { return '' }
        { Add-TgTorrentToQbit -TorrentPath $script:Torrent -SavePath (Join-Path $script:Scratch 'save') -JobId 'job3' } | Should -Throw '*did not register*'
    }
}

Describe 'The job record' {

    BeforeAll {
        $script:Pick = [PSCustomObject]@{ Title = 'Danganronpa - Trigger Happy Havoc'; DownloadCmd = '/download471'; SizeText = '2.63 GB' }
        $script:Job = New-TelegramRomJob -Query 'Danganronpa' -Result $script:Pick -Bot 'PSVita_library_bot' -Folder 'psvita' `
            -RomsBase 'G:\Emulation\roms' -VitaBuild 'console' -TorrentFile 'C:\data\x.torrent' `
            -SavePath 'G:\Emulation\roms\.dlrom-torrent\psvita' -Hash 'deadbeef'
    }

    It 'is a pending telegram job at the downloading step, claimed later by its worker' {
        $script:Job.kind   | Should -Be 'telegram'
        $script:Job.status | Should -Be 'pending'
        $script:Job.step   | Should -Be 'downloading'
        $script:Job.progress | Should -BeGreaterThan 0
        $script:Job.startedAt | Should -BeNullOrEmpty      # the worker stamps it
        $script:Job.pid | Should -Be 0
        # Within the spawn grace the worker is still starting: not orphaned yet.
        (Resolve-DlromJobStatus $script:Job) | Should -Be 'pending'
    }

    It 'carries what the installing worker needs' {
        $j = $script:Job
        $j.query    | Should -Be 'Danganronpa'
        $j.title    | Should -Be 'Danganronpa - Trigger Happy Havoc'
        $j.platform | Should -Be 'psvita'
        $j.romsBase | Should -Be 'G:\Emulation\roms'
        $j.romDest  | Should -Be (Join-Path 'G:\Emulation\roms' 'psvita')
        $j.vitaBuild | Should -Be 'console'
        $j.torrent.hash | Should -Be 'deadbeef'
        $j.torrent.bot  | Should -Be 'PSVita_library_bot'
        $j.torrent.command | Should -Be '/download471'
        $j.torrent.file | Should -Be 'C:\data\x.torrent'
        $j.torrent.savePath | Should -Be 'G:\Emulation\roms\.dlrom-torrent\psvita'
        $j.torrent.platformFolder | Should -Be 'psvita'
        $j.torrent.tag | Should -Be 'dlrom'
        $j.jobFile | Should -BeLike (Join-Path $script:Scratch '*.json')
    }

    It 'survives the save and read round trip with the torrent block intact' {
        Save-DlromJob -Job $script:Job -Strict
        $back = Read-DlromJob $script:Job.id
        $back.kind | Should -Be 'telegram'
        $back.torrent.hash | Should -Be 'deadbeef'
        $back.torrent.platformFolder | Should -Be 'psvita'
    }

    It 'other job kinds are unchanged (torrent block empty)' {
        (New-DlromJob -Kind 'torrent' -Query 'q').torrent | Should -BeNullOrEmpty
    }

    It 'is announced in the spawn style, with the hash, as text or JSON' {
        $text = (Write-DlromJobSpawned -Job $script:Job 6>&1 | Out-String)
        $text | Should -Match ('Job ID:\s+' + $script:Job.id)
        $text | Should -Match 'Source:\s+telegram'
        $text | Should -Match 'Hash:\s+deadbeef'
        $text | Should -Match 'dlrom --status'
        $json = (Write-DlromJobSpawned -Job $script:Job -AsJson 6>$null | Out-String | ConvertFrom-Json)
        $json.torrent.hash | Should -Be 'deadbeef'
    }

    It '--clean keeps the staging folder of a running Telegram job' {
        Save-DlromJob -Job $script:Job -Strict
        $protected = Get-DlromProtectedNames
        Test-DlromProtected -Name 'psvita' -Protected $protected | Should -BeTrue
        Test-DlromProtected -Name 'switch' -Protected $protected | Should -BeFalse
    }
}

Describe 'Invoke-TelegramRomRequest' {

    BeforeEach {
        Set-DlromConfig ([PSCustomObject]@{ telegramMinSendGapSec = 0 })
        $script:Plan = Resolve-DlromSourcePlan -Source 'telegram' -Platform 'vita'
        $script:Dan  = (Get-FixtureReply 'results-danganronpa.txt').Results
        Mock Initialize-DlromTelegram { }
        Mock Get-TgSession { return @{ userId = '42' } }
        Mock Connect-Telegram { }
        Mock Resolve-TgPeer { return @{ _ = 'inputPeerUser' } }
        Mock Initialize-DlromQbit { return $true }
        Mock Find-TgRomResults { return [PSCustomObject]@{ Kind = 'results'; Total = 5; Results = $script:Dan; Pages = 1; Text = ''; MessageId = 1 } }
        Mock Get-TgRomTorrent { return @{ Path = (Join-Path $script:Scratch 'x.torrent'); FileName = 'x.torrent'; MessageId = 5 } }
        Mock Add-TgTorrentToQbit { return @{ Hash = 'cafebabe'; AlreadyPresent = $false } }
        Mock Start-DlromJob { return 4242 }
        Mock Invoke-TelegramJob { return $true }
        $script:QBIT_BASE = 'http://127.0.0.1:8075'
    }
    AfterEach { Set-DlromConfig $null }

    It 'dry run: searches, shows the pick, and never asks for the torrent or touches qBittorrent' {
        $out = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase '' -DryRun -AsJson 6>&1 | Out-String
        $json = ($out -replace '(?s)^.*?(\{.*\}).*$', '$1') | ConvertFrom-Json
        $json.ok | Should -BeTrue
        $json.dryRun | Should -BeTrue
        $json.pick.title | Should -Be 'Danganronpa - Trigger Happy Havoc'
        $json.pick.command | Should -Be '/download471'
        @($json.results).Count | Should -Be 5
        Should -Invoke Get-TgRomTorrent -Times 0
        Should -Invoke Add-TgTorrentToQbit -Times 0
        Should -Invoke Initialize-DlromQbit -Times 0
        Should -Invoke Start-DlromJob -Times 0
        Should -Invoke Invoke-TelegramJob -Times 0
    }

    It 'dry run with --wait still sends and adds nothing' {
        $null = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase '' -DryRun -Wait 6>$null
        Should -Invoke Get-TgRomTorrent -Times 0
        Should -Invoke Add-TgTorrentToQbit -Times 0
        Should -Invoke Start-DlromJob -Times 0
        Should -Invoke Invoke-TelegramJob -Times 0
    }

    It 'dry run returns exit code 0' {
        $rc = @(Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -DryRun 6>$null)
        $rc[-1] | Should -Be 0
    }

    It 'full run: fetches the torrent, adds it, writes the job, starts its worker and prints the id, title and hash' {
        $out = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase (Join-Path $script:Scratch 'roms') -AsJson 6>&1 | Out-String
        $json = ($out -replace '(?s)^.*?(\{.*\}).*$', '$1') | ConvertFrom-Json
        $json.ok | Should -BeTrue
        $json.hash | Should -Be 'cafebabe'
        $json.title | Should -Be 'Danganronpa - Trigger Happy Havoc'
        $json.platform | Should -Be 'psvita'
        $json.savePath | Should -BeLike '*.dlrom-torrent*psvita'
        $job = Read-DlromJob $json.jobId
        $job.kind | Should -Be 'telegram'
        $job.status | Should -Be 'pending'      # the spawned worker claims it
        $job.step | Should -Be 'downloading'
        $job.vitaBuild | Should -Be 'console'
        $job.torrent.hash | Should -Be 'cafebabe'
        Should -Invoke Get-TgRomTorrent -Times 1 -ParameterFilter { $Result.DownloadCmd -eq '/download471' }
        Should -Invoke Add-TgTorrentToQbit -Times 1 -ParameterFilter { $SavePath -like '*.dlrom-torrent*psvita' -and $JobId -eq $json.jobId }
    }

    It 'background mode starts the worker for the saved job and never runs it inline' {
        $out = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase (Join-Path $script:Scratch 'roms') -AsJson 6>&1 | Out-String
        $json = ($out -replace '(?s)^.*?(\{.*\}).*$', '$1') | ConvertFrom-Json
        Should -Invoke Start-DlromJob -Times 1 -ParameterFilter { $Job.id -eq $json.jobId -and $Job.kind -eq 'telegram' }
        Should -Invoke Invoke-TelegramJob -Times 0
        (Read-DlromJob $json.jobId).torrent.hash | Should -Be 'cafebabe'
    }

    It '--wait runs the worker inline, spawns nothing and returns its exit code' {
        $rc = @(Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase (Join-Path $script:Scratch 'roms') -Wait 6>$null)
        $rc[-1] | Should -Be 0
        Should -Invoke Invoke-TelegramJob -Times 1 -ParameterFilter { $Job.kind -eq 'telegram' }
        Should -Invoke Start-DlromJob -Times 0
        Mock Invoke-TelegramJob { return $false }
        $rc = @(Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase (Join-Path $script:Scratch 'roms') -Wait 6>$null)
        $rc[-1] | Should -Be 1
    }

    It '--wait --json still prints one result object' {
        $out = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase (Join-Path $script:Scratch 'roms') -Wait -AsJson 6>&1 | Out-String
        $json = ($out -replace '(?s)^.*?(\{.*\}).*$', '$1') | ConvertFrom-Json
        $json.ok | Should -BeTrue
        $json.jobId | Should -Not -BeNullOrEmpty
    }

    It 'reports a worker that cannot be started and points at --resume' {
        Mock Start-DlromJob { throw 'no process for you' }
        $out = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase (Join-Path $script:Scratch 'roms') -AsJson 6>&1 | Out-String
        $out | Should -Match 'spawn-error'
        $out | Should -Match 'dlrom --resume'
    }

    It 'plain output uses the spawn summary' {
        $out = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase (Join-Path $script:Scratch 'roms') 6>&1 | Out-String
        $out | Should -Match 'Download job spawned'
        $out | Should -Match 'Hash:\s+cafebabe'
    }

    It 'lets --interactive choose from the parsed list' {
        Mock Read-Host { return '2' }
        $out = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase (Join-Path $script:Scratch 'roms') -Interactive -AsJson 6>&1 | Out-String
        $json = ($out -replace '(?s)^.*?(\{.*\}).*$', '$1') | ConvertFrom-Json
        $json.title | Should -Be 'Danganronpa 2 - Goodbye Despair'
        Should -Invoke Get-TgRomTorrent -Times 1 -ParameterFilter { $Result.DownloadCmd -eq '/download335' }
    }

    It 'cancels cleanly on 0' {
        Mock Read-Host { return '0' }
        $rc = @(Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase $script:Scratch -Interactive 6>$null)
        $rc[-1] | Should -Be 0
        Should -Invoke Get-TgRomTorrent -Times 0
    }

    It 'fails with a pointer to --telegram-login when not logged in, before any message is sent' {
        Mock Get-TgSession { return @{ userId = $null } }
        $out = Invoke-TelegramRomRequest -Query 'x' -Plan $script:Plan -RomsBase $script:Scratch -AsJson 6>&1 | Out-String
        $out | Should -Match 'not-logged-in'
        $out | Should -Match 'dlrom --telegram-login'
        Should -Invoke Find-TgRomResults -Times 0
    }

    It 'fails before messaging the bot when qBittorrent is down' {
        Mock Initialize-DlromQbit { return $false }
        $out = Invoke-TelegramRomRequest -Query 'x' -Plan $script:Plan -RomsBase $script:Scratch -AsJson 6>&1 | Out-String
        $out | Should -Match 'qbit-unreachable'
        Should -Invoke Find-TgRomResults -Times 0
    }

    It 'returns 1 on "nothing found"' {
        Mock Find-TgRomResults { return [PSCustomObject]@{ Kind = 'notfound'; Total = 0; Results = @(); Pages = 0; Text = 'none'; MessageId = 1 } }
        $rc = @(Invoke-TelegramRomRequest -Query 'zz' -Plan $script:Plan -RomsBase $script:Scratch 6>$null)
        $rc[-1] | Should -Be 1
        Should -Invoke Get-TgRomTorrent -Times 0
    }

    It 'reports a gate' {
        Mock Find-TgRomResults { return [PSCustomObject]@{ Kind = 'gate'; Total = -1; Results = @(); Pages = 0; Text = 'Subscribe to our channel'; MessageId = 1 } }
        $out = Invoke-TelegramRomRequest -Query 'x' -Plan $script:Plan -RomsBase $script:Scratch -AsJson 6>&1 | Out-String
        $out | Should -Match 'gated'
    }

    It 'reports a fetch failure as an error, not an exception' {
        Mock Get-TgRomTorrent { throw 'The bot sent no .torrent within 30s.' }
        $out = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -RomsBase $script:Scratch -AsJson 6>&1 | Out-String
        $out | Should -Match 'fetch-error'
    }

    It 'warns when --vita emu was asked for but the bot only has console builds' {
        Mock Write-Log { }
        $null = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -DryRun -VitaBuild 'emu' 6>$null
        Should -Invoke Write-Log -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'NoNpDrm' }
    }

    It 'does not warn about Vita builds for other consoles or when --vita was not given' {
        Mock Write-Log { }
        $null = Invoke-TelegramRomRequest -Query 'Danganronpa' -Plan $script:Plan -DryRun 6>$null
        Should -Invoke Write-Log -Times 0 -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'NoNpDrm' }
    }
}
