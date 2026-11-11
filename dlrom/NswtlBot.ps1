# The NSWTL "library" bots (@PSVita_library_bot, @Switch_library_bot, ...): what they say and how
# to read it. Pure text and message-shape logic - no network, no Telegram client - so it is
# tested against real captured replies (tests/fixtures/telegram/).
#
# The bots are one project but not one format. Three result layouts have been seen:
#
#   A  PS Vita / PS3 / PS4 / Xbox 360 ...      "Found torrents: 5"
#        Title [2.63 GB]
#        /download471 /cover471
#   B  Switch                                  "Found torrents for you: 29"
#        Title
#        In the torrent: "..."      (optional)
#        Size: 4.17 GB
#        Download: /download1605 /cover1605
#   C  3DS                                     "Found games: 7"
#        Title                      (no size)
#        /download690 /rate690
#
# One line-by-line reader covers all three: an entry is the title lines gathered since the last
# blank line or command line, closed by the line carrying /download<id>. Everything else in the
# message (the legend, footers, ads, the "Bots may disappear" notice) never matches that shape
# and is dropped. Results past the first dozen are paged with inline buttons on the SAME
# message, which the bot edits in place.
#
# Reply kinds the conversation layer waits for:
#   results    a result list (Results filled)
#   notfound   "Found torrents: 0" / "No torrents found ..."
#   gate       the bot wants a channel subscription (text not captured yet - heuristic)
#   ratelimit  too many requests (text not captured yet - heuristic)
#   other      anything else: broadcasts, "Your torrent is ready!", /start banners. Ignored.

$script:NSWTL_KIND_RESULTS   = 'results'
$script:NSWTL_KIND_NOTFOUND  = 'notfound'
$script:NSWTL_KIND_GATE      = 'gate'
$script:NSWTL_KIND_RATELIMIT = 'ratelimit'
$script:NSWTL_KIND_OTHER     = 'other'

$script:NSWTL_HEADER_RX   = '(?i)\bFound\s+(?:torrents|games)(?:\s+for\s+you)?\s*:\s*(\d+)'
$script:NSWTL_NOTFOUND_RX = '(?i)\bno\s+(?:torrents|games|results)\s+found\b|\bnothing\s+(?:was\s+)?found\b'
$script:NSWTL_GATE_RX     = '(?i)\bsubscribe\b|\bjoin\s+(?:our|the|my)\s+(?:channel|group)\b|\bmember\s+of\s+(?:our|the)\s+channel\b|\bto\s+use\s+(?:this|the)\s+bot\b.*\bchannel\b'
$script:NSWTL_LIMIT_RX    = '(?i)\btoo\s+many\s+(?:requests|messages|queries|downloads)\b|\brate.?limit|\bflood\b|\bslow\s+down\b|\btry\s+again\s+(?:later|in)\b|\b(?:daily|download)\s+limit\b|\blimit\s+(?:reached|exceeded)\b'

$script:NSWTL_CMD_RX      = '/download(\d+)\b'
$script:NSWTL_INFO_CMD_RX = '/(cover|rate)(\d+)\b'
$script:NSWTL_META_RX     = '(?i)^(?:size|download|in the torrent)\s*:'
$script:NSWTL_SIZE_RX     = '(?i)^\s*(\d+(?:[.,]\d+)?)\s*(B|KB|MB|GB|TB|KiB|MiB|GiB|TiB)\s*$'

# "2.63 GB" -> bytes. 0 when the text is not a size. Binary multiples: the bots print what a
# file manager would, and qBittorrent reports the same way.
function ConvertTo-NswtlSizeBytes {
    param([string]$Text)
    if ($Text -notmatch $script:NSWTL_SIZE_RX) { return [long]0 }
    $number = [double]::Parse($Matches[1].Replace(',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
    $power = switch -Regex ($Matches[2].ToUpperInvariant()) {
        '^KI?B$' { 1 }
        '^MI?B$' { 2 }
        '^GI?B$' { 3 }
        '^TI?B$' { 4 }
        default  { 0 }
    }
    return [long][Math]::Round($number * [Math]::Pow(1024, $power))
}

# The entries of a result message. Pure; each entry has what Select-RgtResult scores on (Title,
# Url) plus everything the caller needs to act (DownloadCmd, Id).
function ConvertFrom-NswtlResults {
    param([string]$Text, [string]$Platform = '')

    $results = @()
    $pending = New-Object System.Collections.Generic.List[string]

    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if (-not $line) { $pending.Clear(); continue }

        $isCommand = ($line -match $script:NSWTL_CMD_RX)
        $id = if ($isCommand) { [string]$Matches[1] } else { '' }
        if (-not $isCommand) {
            # Legend lines ("download" - download the torrent) and the header are not titles.
            if ($line -match '^"[a-z.]+"\s*-' -or $line -match $script:NSWTL_HEADER_RX) { continue }
            $pending.Add($line)
            continue
        }

        $infoCmd = ''
        if ($line -match $script:NSWTL_INFO_CMD_RX) { $infoCmd = "/$($Matches[1])$($Matches[2])" }

        $title = ''; $sizeText = ''; $note = ''
        foreach ($p in $pending) {
            if ($p -match '(?i)^size\s*:\s*(.+)$')           { $sizeText = $Matches[1].Trim(); continue }
            if ($p -match '(?i)^in the torrent\s*:\s*(.+)$') { $note = $Matches[1].Trim(); continue }
            if ($p -match $script:NSWTL_META_RX)             { continue }
            if (-not $title) { $title = $p }
        }
        $pending.Clear()
        if (-not $title) { continue }

        # Broadcast digests number their lines ("1. Title [3.97 GB]").
        $title = ($title -replace '^\d+\.\s+', '')
        # Format A carries the size in trailing brackets; other formats on a Size: line.
        if ($title -match '^(.*?)\s*\[([^\]]+)\]\s*$') {
            $bare = $Matches[1].Trim(); $bracket = $Matches[2].Trim()
            if ((ConvertTo-NswtlSizeBytes $bracket) -gt 0) { $title = $bare; $sizeText = $bracket }
        }
        $truncated = ($title.EndsWith('...') -or $title.EndsWith([string][char]0x2026))

        $results += [PSCustomObject]@{
            Title       = $title
            SizeText    = $sizeText
            SizeBytes   = (ConvertTo-NswtlSizeBytes $sizeText)
            Id          = $id
            DownloadCmd = "/download$id"
            CoverCmd    = $infoCmd
            Truncated   = $truncated
            Note        = $note
            # The command is the "URL": Select-RgtResult reads Url, and nothing else here has one.
            Url         = "/download$id"
            Platform    = $Platform
        }
    }
    return @($results)
}

# Classify a bot message and, for a result list, parse it.
#   Kind     results | notfound | gate | ratelimit | other
#   Total    the count the bot announced (all pages), or -1 when it announced none
#   Results  the entries on THIS message
function Read-NswtlReply {
    param([string]$Text, [string]$Platform = '')

    $reply = [PSCustomObject]@{ Kind = $script:NSWTL_KIND_OTHER; Total = -1; Results = @(); Text = $Text }
    if (-not $Text) { return $reply }

    if ($Text -match $script:NSWTL_HEADER_RX) {
        $reply.Total = [int]$Matches[1]
        if ($reply.Total -eq 0) { $reply.Kind = $script:NSWTL_KIND_NOTFOUND; return $reply }
        $reply.Results = @(ConvertFrom-NswtlResults -Text $Text -Platform $Platform)
        if ($reply.Results.Count -gt 0) { $reply.Kind = $script:NSWTL_KIND_RESULTS }
        return $reply
    }
    if ($Text -match $script:NSWTL_NOTFOUND_RX) { $reply.Kind = $script:NSWTL_KIND_NOTFOUND;  return $reply }
    if ($Text -match $script:NSWTL_GATE_RX)     { $reply.Kind = $script:NSWTL_KIND_GATE;      return $reply }
    if ($Text -match $script:NSWTL_LIMIT_RX)    { $reply.Kind = $script:NSWTL_KIND_RATELIMIT; return $reply }
    return $reply
}

# Numbered page buttons under a result message, from a simplified message (replyMarkup). The
# current page is drawn "-1-". Returns @{ Page; Current; Data } ordered by page; empty when the
# list fits one page.
function Get-NswtlPageButtons {
    param($Message)
    $pages = @()
    if (-not $Message -or -not $Message.replyMarkup) { return @() }
    foreach ($row in @($Message.replyMarkup.rows)) {
        foreach ($b in @($row.buttons)) {
            if (-not $b.type -or $b.type._ -ne 'inlineButtonTypeCallback') { continue }
            if ([string]$b.text -notmatch '^\s*([-\[(]*)\s*(\d+)\s*[-\])]*\s*$') { continue }
            $pages += [PSCustomObject]@{
                Page    = [int]$Matches[2]
                Current = ($Matches[1].Length -gt 0)
                Data    = [byte[]]$b.type.data
            }
        }
    }
    return @($pages | Sort-Object Page)
}

# A message carrying the .torrent the bot was asked for.
function Test-NswtlTorrentMessage {
    param($Message)
    if (-not $Message -or -not $Message.document) { return $false }
    $d = $Message.document
    return ([string]$d.mime -eq 'application/x-bittorrent' -or [string]$d.file_name -like '*.torrent')
}

# The bot family as the conversation layer sees it. A different bot family would supply its own
# record with the same members and nothing else would change:
#   Read           text, platform -> reply (Kind / Total / Results)
#   PageButtons    message -> page buttons
#   IsTorrent      message -> bool, the file reply
#   DownloadText   result -> the text to send to fetch it
function Get-NswtlBotFamily {
    return [PSCustomObject]@{
        Name         = 'nswtl'
        Read         = { param($Text, $Platform) Read-NswtlReply -Text $Text -Platform $Platform }
        PageButtons  = { param($Message) Get-NswtlPageButtons -Message $Message }
        IsTorrent    = { param($Message) Test-NswtlTorrentMessage -Message $Message }
        DownloadText = { param($Result) [string]$Result.DownloadCmd }
    }
}
