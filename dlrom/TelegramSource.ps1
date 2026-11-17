# Telegram as a ROM source: ask an NSWTL library bot for a game, take its .torrent, hand that to
# qBittorrent.
#
# Three layers, so a new console is a table row and a new bot family is one new reader:
#
#   NswtlBot.ps1       what a bot says (parser, reply kinds, page buttons, the family record)
#   this file          routing (--source), the conversation, the torrent handoff, the job record
#   lib/Telegram/      the MTProto client (loaded by Add-ROM.ps1 when this source is in play)
#
# The conversation takes a "bot family" record (see Get-NswtlBotFamily) instead of calling the
# parser directly: Find results -> pick -> fetch torrent is the whole contract.
#
# This source stops at "the torrent is downloading": it records a job (kind 'telegram', status
# running, step downloading) carrying everything a later worker needs to wait for the download,
# extract and install it. Nothing here moves or unpacks the result.
#
# Bots answer in the same chat, so every wait is "an incoming message after the one I sent that
# looks like what I expect". Broadcasts the bots push on their own (weekly top lists, donation
# appeals) and anything else that does not match are ignored, never mistaken for a reply.

# --- Routing ----------------------------------------------------------------------------------

# --source value -> canonical code, '' for blank (= auto), $null when unrecognised.
function Resolve-DlromSourceName {
    param([string]$Source)
    $s = ([string]$Source).Trim().ToLowerInvariant()
    if (-not $s) { return $script:SOURCE_AUTO }
    foreach ($alias in $script:SOURCE_ALIASES) {
        if ($s -match $alias.Rx) { return $alias.Code }
    }
    return $null
}

# --platform (or a RetroGameTalk slug) -> canonical Telegram key, $null when no bot serves it.
function Resolve-TgPlatformKey {
    param([string]$Platform)
    $k = ([string]$Platform).Trim().ToLowerInvariant()
    if (-not $k) { return $null }
    if ($script:TGSRC_PLATFORM_ALIASES.ContainsKey($k)) { return [string]$script:TGSRC_PLATFORM_ALIASES[$k] }
    return $null
}

function Get-TgPlatformFolder {
    param([string]$Key)
    if ($Key -and $script:TGSRC_PLATFORM_FOLDERS.ContainsKey($Key)) { return [string]$script:TGSRC_PLATFORM_FOLDERS[$Key] }
    return ''
}

# The bot for a platform key: [rom].telegramBots wins (its keys may be any platform alias, its
# values a username with or without the @), the built-in table fills any gap. $Overrides is the
# config object or a hashtable; both read the same.
function Get-TgBotName {
    param([string]$Key, $Overrides = $null)
    if (-not $Key) { return '' }
    if ($null -ne $Overrides) {
        $pairs = if ($Overrides -is [System.Collections.IDictionary]) {
            @($Overrides.GetEnumerator() | ForEach-Object { @{ Name = [string]$_.Key; Value = [string]$_.Value } })
        } else {
            @($Overrides.PSObject.Properties | ForEach-Object { @{ Name = [string]$_.Name; Value = [string]$_.Value } })
        }
        foreach ($p in $pairs) {
            if ((Resolve-TgPlatformKey $p.Name) -ne $Key) { continue }
            $name = $p.Value.Trim().TrimStart('@')
            if ($name) { return $name }
        }
    }
    if ($script:TGSRC_DEFAULT_BOTS.ContainsKey($Key)) { return [string]$script:TGSRC_DEFAULT_BOTS[$Key] }
    return ''
}

# Decide where a request goes. Pure: no config reads, no network.
#   Primary    'rgt' | 'telegram'  where to look first
#   Fallback   $true when a failed RetroGameTalk run should be retried on Telegram
#   FallbackSkip  why not, for the tip printed when RetroGameTalk fails
#   TgKey / Bot / Folder   the platform key, its bot and its ROM folder (when known)
#   Error      set when the request cannot be served as asked
function Resolve-DlromSourcePlan {
    param(
        [string]$Source = '',
        [string]$Platform = '',
        [string]$ResolvedSlug = '',
        $Overrides = $null,
        [bool]$FallbackEnabled = $true
    )

    $plan = [PSCustomObject]@{
        Source = ''; Primary = $script:SOURCE_RGT; Fallback = $false; FallbackSkip = ''
        TgKey = $null; Bot = ''; Folder = ''; Error = ''
    }

    $src = Resolve-DlromSourceName $Source
    if (-not $src) {
        $plan.Error = "Unknown --source '$Source' (expected auto, rgt or telegram)."
        return $plan
    }
    $plan.Source = $src

    $key = Resolve-TgPlatformKey $Platform
    if (-not $key) { $key = Resolve-TgPlatformKey $ResolvedSlug }
    $bot = if ($key) { Get-TgBotName -Key $key -Overrides $Overrides } else { '' }
    $plan.TgKey  = $key
    $plan.Bot    = $bot
    $plan.Folder = Get-TgPlatformFolder $key
    $tgOnly = ($key -and ($script:TGSRC_ONLY_PLATFORMS -contains $key))

    switch ($src) {
        'telegram' {
            $plan.Primary = $script:SOURCE_TELEGRAM
            if (-not $key)    { $plan.Error = "--source telegram needs --platform naming a console with a bot (got '$Platform')." }
            elseif (-not $bot) { $plan.Error = "No Telegram bot is configured for '$key' (set [rom].telegramBots)." }
        }
        'rgt' {
            $plan.Primary = $script:SOURCE_RGT
            if ($tgOnly) { $plan.Error = "'$Platform' is only served by the Telegram bots - use --source telegram (or leave --source on auto)." }
        }
        default {   # auto
            if ($tgOnly) {
                $plan.Primary = $script:SOURCE_TELEGRAM
                if (-not $bot) { $plan.Error = "No Telegram bot is configured for '$key' (set [rom].telegramBots)." }
            } else {
                $plan.Primary = $script:SOURCE_RGT
                if     (-not $FallbackEnabled) { $plan.FallbackSkip = 'disabled' }
                elseif (-not $key)             { $plan.FallbackSkip = $(if ($Platform) { 'no-bot' } else { 'no-platform' }) }
                elseif (-not $bot)             { $plan.FallbackSkip = 'no-bot' }
                else                           { $plan.Fallback = $true }
            }
        }
    }
    return $plan
}

# --- Torrent files --------------------------------------------------------------------------------

# End of the bencoded value starting at $Pos (exclusive).
function Get-BencodeEnd {
    param([byte[]]$Bytes, [int]$Pos)
    $c = [char]$Bytes[$Pos]
    if ($c -eq 'i') {
        while ($Bytes[$Pos] -ne [byte][char]'e') { $Pos++ }
        return ($Pos + 1)
    }
    if ($c -eq 'l' -or $c -eq 'd') {
        $Pos++
        while ($Bytes[$Pos] -ne [byte][char]'e') { $Pos = Get-BencodeEnd -Bytes $Bytes -Pos $Pos }
        return ($Pos + 1)
    }
    if ($c -ge '0' -and $c -le '9') {
        $len = 0
        while ($Bytes[$Pos] -ne [byte][char]':') { $len = $len * 10 + ($Bytes[$Pos] - [byte][char]'0'); $Pos++ }
        return ($Pos + 1 + $len)
    }
    throw "Not a valid .torrent: unexpected byte 0x$('{0:x2}' -f $Bytes[$Pos]) at offset $Pos."
}

# v1 infohash (lowercase hex SHA-1 of the bencoded "info" dictionary), the id qBittorrent uses.
# Lets the handoff tell "already in qBittorrent" from "added now" before it touches anything.
function Get-TorrentInfoHash {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 2 -or $bytes[0] -ne [byte][char]'d') { throw "Not a valid .torrent: $Path" }
    $key = [System.Text.Encoding]::ASCII.GetBytes('4:info')
    $pos = 1
    while ($pos -lt $bytes.Length -and $bytes[$pos] -ne [byte][char]'e') {
        $keyEnd = Get-BencodeEnd -Bytes $bytes -Pos $pos
        $isInfo = (($keyEnd - $pos) -eq $key.Length)
        if ($isInfo) { for ($i = 0; $i -lt $key.Length; $i++) { if ($bytes[$pos + $i] -ne $key[$i]) { $isInfo = $false; break } } }
        $valEnd = Get-BencodeEnd -Bytes $bytes -Pos $keyEnd
        if ($isInfo) {
            $sha = [System.Security.Cryptography.SHA1]::Create()
            try { $digest = $sha.ComputeHash($bytes, $keyEnd, $valEnd - $keyEnd) } finally { $sha.Dispose() }
            return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        $pos = $valEnd
    }
    throw "No info dictionary in $Path"
}

# A filename Windows and Linux both accept, whatever the bot called the document.
function ConvertTo-SafeTorrentName {
    param([string]$Name)
    $n = ([string]$Name) -replace '[<>:"/\\|?*\x00-\x1f]', '_'
    $n = $n.Trim().TrimEnd('.')
    if (-not $n) { $n = 'download' }
    if ($n.Length -gt 150) { $n = $n.Substring(0, 150) }
    if ($n -notlike '*.torrent') { $n += '.torrent' }
    return $n
}

# --- The conversation -------------------------------------------------------------------------------------

$script:TGSRC_LAST_SEND = [datetime]::MinValue

# Human pace: never two sends (or button presses) closer than telegramMinSendGapSec.
function Wait-TgSendGap {
    $gap = [double](Get-CfgValue 'telegramMinSendGapSec' 3)
    $elapsed = ([datetime]::UtcNow - $script:TGSRC_LAST_SEND).TotalSeconds
    if ($elapsed -lt $gap) { Start-Sleep -Milliseconds ([int](($gap - $elapsed) * 1000)) }
    $script:TGSRC_LAST_SEND = [datetime]::UtcNow
}

# Id of the newest message in the chat, 0 for an empty one.
function Get-TgLatestMessageId {
    param($Peer)
    $last = @(Get-TgHistory -Peer $Peer -Limit 1) | Select-Object -Last 1
    if ($last) { return [int]$last.id }
    return 0
}

# One message by id (recent history only), or $null.
function Get-TgMessageById {
    param($Peer, [int]$Id)
    foreach ($m in @(Get-TgHistory -Peer $Peer -Limit 30 -MinId ($Id - 1))) {
        if ([int]$m.id -eq $Id) { return $m }
    }
    return $null
}

# Send text and return the id replies must exceed. Send-TgMessage can fail to learn the id of
# its own message; the chat's newest id from just before the send is a safe floor then.
function Send-TgBotText {
    param($Peer, [string]$Text)
    $baseline = Get-TgLatestMessageId $Peer
    Wait-TgSendGap
    $sent = Send-TgMessage -Peer $Peer -Text $Text
    if ($sent.Id -gt 0) { return [int]$sent.Id }
    return $baseline
}

# Press an inline button. These bots EDIT the message and never answer the callback, so the
# BOT_RESPONSE_TIMEOUT Telegram reports after a few seconds is the normal outcome.
function Invoke-TgBotCallback {
    param($Peer, [int]$MessageId, [byte[]]$Data)
    Wait-TgSendGap
    try {
        [void](Invoke-TgApi ([ordered]@{ _ = 'messages.getBotCallbackAnswer'; peer = $Peer; msg_id = $MessageId; data = $Data }))
    } catch {
        if ([string]$_.Exception.Data['tgError'] -ne 'BOT_RESPONSE_TIMEOUT') { throw }
    }
}

# True when some result already holds every significant word of the query: later pages cannot
# improve on an exact hit, so there is no reason to press more buttons.
function Test-TgResultsCoverQuery {
    param([object[]]$Results, [string]$Query)
    $tokens = @(Get-Ps2Significant $Query)
    if ($tokens.Count -eq 0) { return $true }
    foreach ($r in @($Results)) {
        $have = @(Get-Ps2Significant $r.Title)
        $all = $true
        foreach ($t in $tokens) { if ($have -notcontains $t) { $all = $false; break } }
        if ($all) { return $true }
    }
    return $false
}

# Search one bot. Returns:
#   Kind      results | notfound | gate | ratelimit
#   Total     what the bot announced, over all its pages
#   Results   entries gathered (page 1, plus later pages while no entry covers the query)
#   Pages     pages read
#   Text      the bot's words for notfound / gate / ratelimit
# Throws when the bot says nothing recognisable within the timeout.
function Find-TgRomResults {
    param(
        $Peer, [string]$Query, $Family, [string]$Platform = '',
        [int]$TimeoutSec = 30, [int]$MaxPages = 4, [switch]$AllPages
    )
    $tgReader = $Family.Read
    $tgPlatform = $Platform

    $after = Send-TgBotText -Peer $Peer -Text $Query
    $msg = Wait-TgReply -Peer $Peer -AfterId $after -TimeoutSec $TimeoutSec -Predicate {
        param($m) ((& $tgReader $m.text $tgPlatform).Kind -ne 'other')
    }
    if (-not $msg) { throw "The bot did not reply within ${TimeoutSec}s." }

    $reply = & $tgReader $msg.text $Platform
    $out = [PSCustomObject]@{ Kind = $reply.Kind; Total = $reply.Total; Results = @(); Pages = 0; Text = $reply.Text; MessageId = $msg.id }
    if ($reply.Kind -ne $script:NSWTL_KIND_RESULTS) { return $out }

    $gathered = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $addPage = {
        param($page)
        foreach ($r in @($page)) { if (-not $seen.ContainsKey($r.DownloadCmd)) { $seen[$r.DownloadCmd] = $true; $gathered.Add($r) } }
    }
    & $addPage $reply.Results
    $out.Pages = 1

    $current = $msg
    $pageNo = 1
    while ($out.Pages -lt $MaxPages -and $reply.Total -gt $gathered.Count) {
        if (-not $AllPages -and (Test-TgResultsCoverQuery -Results $gathered.ToArray() -Query $Query)) { break }
        $next = @(& $Family.PageButtons $current) | Where-Object { $_.Page -eq ($pageNo + 1) } | Select-Object -First 1
        if (-not $next) { break }

        Invoke-TgBotCallback -Peer $Peer -MessageId $current.id -Data $next.Data
        # The edit lands a moment after the callback; wait for the text to change.
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        $edited = $null
        while ([DateTime]::UtcNow -lt $deadline) {
            $fresh = Get-TgMessageById -Peer $Peer -Id $current.id
            if ($fresh -and $fresh.text -ne $current.text) { $edited = $fresh; break }
            Start-Sleep -Milliseconds 1000
        }
        if (-not $edited) { Write-Log "The bot did not turn to page $($pageNo + 1); using what is loaded." 'WARN'; break }
        $current = $edited
        $pageNo++
        $out.Pages++
        & $addPage (& $tgReader $current.text $Platform).Results
    }
    $out.Results = $gathered.ToArray()
    return $out
}

# Pick the entry to download. Updates and DLC are separate listings in the 3DS/Switch bots and
# never what "the game" means, so they only compete when nothing else is left (or the query
# names them); the scoring itself is Select-RgtResult's.
function Select-TgResult {
    param([object[]]$Results, [string]$Query, [string]$Region = '')
    $all = @($Results)
    if ($all.Count -eq 0) { return $null }
    $rx = '(?i)\b(update|dlc|patch|add-?on)\b'
    $pool = $all
    if ($Query -notmatch $rx) {
        $base = @($all | Where-Object { $_.Title -notmatch $rx })
        if ($base.Count -gt 0) { $pool = $base }
    }
    # The bots search fuzzily ("Halo 3" lists "Halo -Reach"), so unlike The Repo a soft pick
    # would download the wrong game. Every query word must be in the title; a title the bot cut
    # short only needs half of them, since the rest may sit past the cut.
    $qtokens = @(Get-Ps2Significant $Query)
    if ($qtokens.Count -gt 0) {
        $pool = @($pool | Where-Object {
            $tt = @(Get-Ps2Significant $_.Title)
            $hits = @($qtokens | Where-Object { $tt -contains $_ }).Count
            ($hits -eq $qtokens.Count) -or ($_.Truncated -and ($hits * 2) -ge $qtokens.Count)
        })
        if ($pool.Count -eq 0) { return $null }
    }
    $pick = Select-RgtResult -Results $pool -Query $Query -Region $Region
    if (-not $pick) { $pick = $pool[0] }
    return $pick
}

# Ask the bot for one entry's torrent and save it. Returns @{ Path; FileName; MessageId }.
# Throws with the bot's own words when it gates or rate-limits the download.
function Get-TgRomTorrent {
    param($Peer, $Result, $Family, [string]$OutDir, [int]$TimeoutSec = 30)

    $tgReader = $Family.Read
    $tgIsTorrent = $Family.IsTorrent
    $kGate = $script:NSWTL_KIND_GATE
    $kLimit = $script:NSWTL_KIND_RATELIMIT

    $after = Send-TgBotText -Peer $Peer -Text (& $Family.DownloadText $Result)
    $msg = Wait-TgReply -Peer $Peer -AfterId $after -TimeoutSec $TimeoutSec -Predicate {
        param($m)
        if (& $tgIsTorrent $m) { return $true }
        $k = (& $tgReader $m.text '').Kind
        return ($k -eq $kGate -or $k -eq $kLimit)
    }
    if (-not $msg) { throw "The bot sent no .torrent within ${TimeoutSec}s." }
    if (-not (& $tgIsTorrent $msg)) { throw "The bot refused the download: $(($msg.text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' ')" }

    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $name = ConvertTo-SafeTorrentName $msg.document.file_name
    $path = Join-Path $OutDir $name
    try {
        [void](Save-TgDocument -Document $msg.document -Path $path)
    } catch {
        # A file reference goes stale; the client does not renew it, so fetch the message again
        # (which carries a fresh one) and retry once.
        if ([string]$_.Exception.Data['tgError'] -notmatch 'FILE_REFERENCE') { throw }
        $fresh = Get-TgMessageById -Peer $Peer -Id $msg.id
        if (-not $fresh -or -not $fresh.document) { throw }
        [void](Save-TgDocument -Document $fresh.document -Path $path)
    }
    return @{ Path = $path; FileName = $name; MessageId = [int]$msg.id }
}

# --- Handoff to qBittorrent ------------------------------------------------------------------------------------------

# Point the qBittorrent client at the configured WebUI. Returns $true when it answers.
function Initialize-DlromQbit {
    $base = Resolve-QbitBase -CfgHost ([string](Get-CfgValue 'qbitHost' ''))
    Initialize-Qbit -Base $base -User ([string](Get-CfgValue 'qbitUser' '')) -Pass ([string](Get-CfgValue 'qbitPass' ''))
    return (Test-QbitRunning)
}

# Add the .torrent and start it. A torrent qBittorrent already holds is left exactly as it is
# (never re-added, never forced to start): it may be the user's, or paused on purpose.
# Returns @{ Hash; AlreadyPresent }.
function Add-TgTorrentToQbit {
    param([string]$TorrentPath, [string]$SavePath, [string]$JobId)

    $infoHash = Get-TorrentInfoHash -Path $TorrentPath
    $existing = Get-QbitExistingHash -InfoHash $infoHash
    if ($existing) { return @{ Hash = $existing; AlreadyPresent = $true } }

    if (-not (Test-Path -LiteralPath $SavePath)) { New-Item -ItemType Directory -Path $SavePath -Force | Out-Null }
    # Two tags: the shared one marks it as dlrom's, the per-job one finds this exact torrent
    # again (a shared tag alone would match every earlier download).
    $jobTag = "$($script:TGSRC_QBIT_TAG)-$JobId"
    Add-QbitTorrentFile -TorrentPath $TorrentPath -SavePath $SavePath -Tag "$($script:TGSRC_QBIT_TAG),$jobTag"
    $hash = Wait-QbitHash -Tag $jobTag -InfoHash $infoHash -TimeoutSec 30
    if (-not $hash) { throw 'qBittorrent did not register the added torrent.' }
    # Add-QbitTorrentFile adds stopped (the PS2 path picks one file before starting); here the
    # whole torrent is wanted.
    Start-QbitTorrent -Hash $hash
    return @{ Hash = $hash; AlreadyPresent = $false }
}

# The job a later worker picks up. Everything it needs to wait for the download and install the
# result is in the record: the torrent hash, where qBittorrent saves it, the console folder and
# the final destination.
function New-TelegramRomJob {
    param(
        [string]$Query, $Result, [string]$Bot, [string]$Folder, [string]$Region = '',
        [string]$RomsBase, [string]$VitaBuild = '', [string]$TorrentFile, [string]$SavePath,
        [string]$Hash, [bool]$AlreadyPresent = $false, [bool]$NoExtract = $false, [bool]$NoSteam = $false
    )
    $job = New-DlromJob -Kind $script:JOB_KIND_TELEGRAM -Query $Query -Title $Result.Title `
            -Platform $Folder -Region $Region -RomsBase $RomsBase -RomDest (Join-Path $RomsBase $Folder) `
            -VitaBuild $VitaBuild -NoExtract $NoExtract -NoSteam $NoSteam `
            -Torrent @{
                hash = $Hash; bot = $Bot; command = $Result.DownloadCmd; sizeText = [string]$Result.SizeText
                file = $TorrentFile; savePath = $SavePath; platformFolder = $Folder
                tag = $script:TGSRC_QBIT_TAG; alreadyPresent = $AlreadyPresent
            }
    # Pending, like any job before its worker claims it: the worker stamps running, its pid and
    # startedAt. lastUpdate dates the spawn grace (Resolve-DlromJobStatus).
    $job.step       = $script:JOB_STEP_DOWNLOADING
    $job.progress   = 5
    $job.lastUpdate = (Get-UtcStamp)
    return $job
}

# --- The request ---------------------------------------------------------------------------------------------------------

function Write-TgResultList {
    param([object[]]$Results, [string]$Folder)
    Write-Host ""
    $i = 1
    foreach ($r in $Results) {
        Write-Host ("[{0,2}]" -f $i) -ForegroundColor Yellow -NoNewline
        Write-Host " $($r.Title)" -ForegroundColor White
        $size = if ($r.SizeText) { "  |  $($r.SizeText)" } else { '' }
        Write-Host ("       $Folder$size  |  $($r.DownloadCmd)") -ForegroundColor DarkGray
        $i++
    }
    Write-Host ""
}

function Write-TgJson {
    param([hashtable]$Object)
    Write-Host ($Object | ConvertTo-Json -Depth 6)
}

# search -> pick -> (unless a dry run) torrent -> qBittorrent -> job. Returns the exit code.
# Every failure is logged here (and printed as JSON under -AsJson); nothing throws out.
function Invoke-TelegramRomRequest {
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)]$Plan,
        [string]$Region = '',
        [string]$RomsBase = '',
        [int]$MaxResults = 10,
        [string]$VitaBuild = '',        # what --vita asked for, '' when it did not
        [switch]$DryRun, [switch]$Interactive, [switch]$AsJson,
        [switch]$NoExtract, [switch]$NoSteam,
        [switch]$Wait                   # run the worker here instead of detaching it
    )

    $fail = {
        param([string]$Message, [string]$Code)
        Write-Log $Message 'ERROR'
        if ($AsJson) { Write-TgJson @{ ok = $false; source = 'telegram'; error = $Message; code = $Code; query = $Query } }
        return 1
    }

    if (-not (Get-Command -Name Connect-Telegram -ErrorAction SilentlyContinue)) {
        return (& $fail 'The Telegram client is not loaded.' 'not-loaded')
    }

    $folder = $Plan.Folder
    $bot    = $Plan.Bot
    $family = Get-NswtlBotFamily
    $replyTimeout = [int](Get-CfgValue 'telegramReplyTimeoutSec' 30)

    # Local checks first: nothing should reach Telegram if the run cannot finish anyway.
    try {
        Initialize-DlromTelegram
        if (-not (Get-TgSession).userId) { throw 'not logged in' }
    } catch {
        return (& $fail "Telegram is not logged in ($($_.Exception.Message)). Run: dlrom --telegram-login --phone +<number>" 'not-logged-in')
    }
    if (-not $DryRun) {
        if (-not (Initialize-DlromQbit)) {
            return (& $fail "qBittorrent WebUI not reachable at $($script:QBIT_BASE) - start qBittorrent (or set [rom].qbitHost)." 'qbit-unreachable')
        }
        if (-not $RomsBase) { return (& $fail 'No ROMs base directory resolved.' 'no-roms-base') }
    }

    if ($Plan.TgKey -eq 'vita' -and $VitaBuild -eq $script:VITA_BUILD_EMU) {
        Write-Log "--vita emu: the Telegram bot only serves NoNpDrm (console) builds; downloading that anyway." 'WARN'
    }

    try {
        Write-Log "Searching @$bot for: $Query" 'INFO'
        [void](Connect-Telegram)
        $peer = Resolve-TgPeer $bot
        $search = Find-TgRomResults -Peer $peer -Query $Query -Family $family -Platform $folder `
                    -TimeoutSec $replyTimeout -MaxPages ([int](Get-CfgValue 'telegramMaxPages' 4)) -AllPages:$Interactive
    } catch {
        return (& $fail "Telegram search failed: $($_.Exception.Message)" 'search-error')
    }

    switch ($search.Kind) {
        'notfound'  { Write-Log "@$bot has nothing for: $Query" 'WARN'
                      if ($AsJson) { Write-TgJson @{ ok = $false; source = 'telegram'; error = 'no results'; code = 'no-results'; query = $Query; bot = $bot } }
                      return 1 }
        'gate'      { return (& $fail "@$bot wants a channel subscription before it will answer: $(($search.Text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' ')" 'gated') }
        'ratelimit' { return (& $fail "@$bot is rate-limiting this account: $(($search.Text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' ')" 'rate-limited') }
    }

    $shown = @($search.Results | Select-Object -First $MaxResults)
    if ($search.Total -gt $search.Results.Count) {
        Write-Log "@$bot found $($search.Total) in all; read $($search.Results.Count) over $($search.Pages) page(s)." 'INFO'
    }
    Write-TgResultList -Results $shown -Folder $folder

    # The pool the pick is made from is everything read, not just what fits on screen.
    $selected = $null
    if ($Interactive -and $shown.Count -gt 1) {
        $choice = Read-Host "Select [1-$($shown.Count)] or 0 to cancel"
        if ($choice -eq '0' -or $choice -eq '') { Write-Log 'Cancelled.' 'WARN'; return 0 }
        $idx = 0
        if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $shown.Count) {
            return (& $fail 'Invalid selection.' 'bad-selection')
        }
        $selected = $shown[$idx - 1]
    } else {
        $selected = Select-TgResult -Results $search.Results -Query $Query -Region $Region
        if (-not $selected) {
            return (& $fail "The bot listed $(@($search.Results).Count) result(s) but none has every word of '$Query' in its title. Re-run with --interactive to pick one yourself." 'no-match')
        }
        Write-Log "Auto-selecting: $($selected.Title)$(if ($selected.SizeText) { " [$($selected.SizeText)]" })" 'INFO'
    }
    if ($selected.Truncated) {
        Write-Log "The bot cut this title short ('$($selected.Title)'); the pick rests on the visible part." 'WARN'
    }

    if ($DryRun) {
        Write-Log "Dry run - not requesting the torrent ($($selected.DownloadCmd))." 'INFO'
        if ($AsJson) {
            Write-TgJson @{
                ok = $true; source = 'telegram'; dryRun = $true; query = $Query; bot = $bot; platform = $folder
                total = $search.Total
                results = @($shown | ForEach-Object { @{ title = $_.Title; sizeText = $_.SizeText; command = $_.DownloadCmd } })
                pick = @{ title = $selected.Title; sizeText = $selected.SizeText; command = $selected.DownloadCmd }
            }
        }
        return 0
    }

    # --- fetch the torrent, add it, record the job ---
    try {
        $torrentDir = Get-DlScriptsDataDir 'telegram/torrents'
        Write-Log "Requesting the torrent for: $($selected.Title)" 'INFO'
        $got = Get-TgRomTorrent -Peer $peer -Result $selected -Family $family -OutDir $torrentDir -TimeoutSec $replyTimeout
        Write-Log "Saved $($got.FileName)" 'DEBUG'

        $savePath = Join-DlPath $RomsBase $script:TGSRC_STAGING_DIR $folder
        # The job exists before the torrent does so its id can tag the torrent in qBittorrent;
        # the hash is filled in once qBittorrent has it.
        $vitaOut = if ($Plan.TgKey -eq 'vita') { $script:VITA_BUILD_CONSOLE } else { '' }
        $job = New-TelegramRomJob -Query $Query -Result $selected -Bot $bot -Folder $folder -Region $Region `
                -RomsBase $RomsBase -VitaBuild $vitaOut -TorrentFile $got.Path -SavePath $savePath `
                -NoExtract ([bool]$NoExtract) -NoSteam ([bool]$NoSteam)
        $added = Add-TgTorrentToQbit -TorrentPath $got.Path -SavePath $savePath -JobId $job.id
        $job.torrent.hash = $added.Hash
        $job.torrent.alreadyPresent = $added.AlreadyPresent
    } catch {
        return (& $fail "Could not fetch the torrent: $($_.Exception.Message)" 'fetch-error')
    }
    if ($added.AlreadyPresent) {
        Write-Log "qBittorrent already has this torrent ($($added.Hash)); leaving it as it is." 'WARN'
    }
    try { Save-DlromJob -Job $job -Strict } catch { return (& $fail "Could not write the job file: $($_.Exception.Message)" 'job-error') }

    $summary = {
        Write-TgJson @{
            ok = ($job.status -ne $script:JOB_STATUS_FAILED); source = 'telegram'; jobId = $job.id; title = $job.title
            hash = $added.Hash; bot = $bot; platform = $folder; savePath = $savePath; torrentFile = $got.Path
            alreadyPresent = $added.AlreadyPresent; status = $job.status; step = $job.step
            message = [string]$job.message; installedPaths = @($job.installedPaths); manualNote = [string]$job.manualNote
        }
    }

    if ($Wait) {
        # Same worker, this process: progress shows here and the exit code is the outcome.
        $done = [bool](@(Invoke-TelegramJob -Job $job -Cfg $script:DLROM_CFG) | Select-Object -Last 1)
        if ($AsJson) { & $summary }
        return $(if ($done) { 0 } else { 1 })
    }

    try {
        [void](Start-DlromJob -Job $job)
    } catch {
        return (& $fail "Could not start the worker: $($_.Exception.Message). The torrent is already downloading; run: dlrom --resume $($job.id)" 'spawn-error')
    }
    if ($AsJson) { & $summary } else { Write-DlromJobSpawned -Job $job }
    return 0
}
