# Telegram MTProto - client API.
#
# The layer other code (dlrom's NSWTL bot source, the CLI glue) talks to. It owns connection
# reuse per DC, auth keys, DC migration, flood waits and the simplified message objects; it
# knows nothing about login prompts (TgAuth.ps1) or the wire (TgTransport.ps1).
#
#   Connect-Telegram           load the session, make sure the home DC has an auth key
#   Invoke-TgApi               call any schema method, with migration / flood-wait handling
#   Resolve-TgPeer             @username -> input peer (access_hash cached in the session)
#   Send-TgMessage             messages.sendMessage
#   Get-TgHistory              messages.getHistory -> simplified messages
#   Wait-TgReply               poll history until an incoming message satisfies a predicate
#   Save-TgDocument            download a document to disk in 512 KB chunks

$script:TG_CONNS      = @{}
$script:TG_DEFAULT_DC = 2
$script:TG_CHUNK      = 512 * 1024

# --- connections ---------------------------------------------------------------------------------------------

# Addresses to try for a DC: what help.getConfig taught us, then the built-in list.
function Get-TgDcAddresses {
    param([int]$Dc)
    $s = Get-TgSession
    $list = @()
    $learned = $s.dcAddresses[[string]$Dc]
    if ($learned) { $list += @($learned) }
    foreach ($a in @($script:TG_DC_ADDRESSES[$Dc])) { if ($a -and $list -notcontains $a) { $list += $a } }
    if ($list.Count -eq 0) { throw (New-TgException "No known address for Telegram DC $Dc.") }
    return $list
}

function Open-TgDcSocket {
    param([int]$Dc)
    $lastError = $null
    foreach ($addr in (Get-TgDcAddresses $Dc)) {
        try { return (Open-TgConnection -Dc $Dc -HostName $addr -Port $script:TG_PORT) }
        catch { $lastError = $_ }
    }
    throw $lastError
}

# The connection for a DC, created (and its auth key made or restored) on first use.
# -Authorize: for a DC other than home, make sure the logged-in account is imported there.
function Get-TgConnection {
    param([int]$Dc, [switch]$Authorize, [switch]$ForceNewKey)

    $existing = $script:TG_CONNS[$Dc]
    if ($existing -and $existing.Client -and $existing.Client.Connected -and -not $ForceNewKey) {
        $conn = $existing
    } else {
        if ($existing) { Close-TgConnection $existing; $script:TG_CONNS.Remove($Dc) }
        Assert-TgCredentials
        $conn = Open-TgDcSocket $Dc
        $entry = if ($ForceNewKey) { $null } else { Get-TgDcEntry $Dc }
        if ($entry) {
            $conn.AuthKey    = [Convert]::FromBase64String($entry.authKey)
            $conn.AuthKeyId  = Get-TgSlice (Get-TgSha1 $conn.AuthKey) 12 8
            $conn.Salt       = [long]$entry.salt
            $conn.TimeOffset = [int]$entry.timeOffset
        } else {
            [void](New-TgAuthKey $conn)
            Set-TgDcEntry $Dc $conn
        }
        $script:TG_CONNS[$Dc] = $conn
    }

    if ($Authorize) { Confirm-TgDcAuthorized $Dc $conn }
    return $conn
}

# Move the logged-in account onto another DC's key (needed before downloading from it).
function Confirm-TgDcAuthorized {
    param([int]$Dc, $Conn)
    $s = Get-TgSession
    if (-not $s.userId -or $Dc -eq $s.dcId) { return }
    $entry = Get-TgDcEntry $Dc
    if ($entry -and $entry.authorized) { return }

    $exported = Invoke-TgApi ([ordered]@{ _ = 'auth.exportAuthorization'; dc_id = $Dc })
    [void](Invoke-TgApi ([ordered]@{ _ = 'auth.importAuthorization'; id = $exported.id; bytes = $exported.bytes }) -Dc $Dc -NoAuthorize)
    Set-TgDcEntry $Dc $Conn $true
}

# Load the session and make sure the home DC has a working auth key. Returns the connection.
function Connect-Telegram {
    param([int]$Dc = 0)
    Assert-TgCredentials
    $s = Get-TgSession
    if ($Dc -le 0) { $Dc = if ($s.dcId) { [int]$s.dcId } else { $script:TG_DEFAULT_DC } }
    $conn = Get-TgConnection -Dc $Dc
    if (-not $s.dcId) { $s.dcId = $Dc; Save-TgSession }
    return $conn
}

# Drop every open socket (keys stay on disk).
function Disconnect-Telegram {
    foreach ($c in @($script:TG_CONNS.Values)) { Close-TgConnection $c }
    $script:TG_CONNS = @{}
}

# Refresh the DC address table from help.getConfig. Best effort.
function Update-TgDcAddresses {
    try {
        $cfg = Invoke-TgApi ([ordered]@{ _ = 'help.getConfig' })
        $s = Get-TgSession
        $byDc = @{}
        foreach ($o in $cfg.dc_options) {
            if ($o.ipv6 -or $o.media_only -or $o.cdn -or $o.tcpo_only) { continue }
            $k = [string]$o.id
            if (-not $byDc.ContainsKey($k)) { $byDc[$k] = @() }
            $byDc[$k] += [string]$o.ip_address
        }
        foreach ($k in $byDc.Keys) { $s.dcAddresses[$k] = $byDc[$k] }
        Save-TgSession
    } catch { Write-Verbose "getConfig refresh failed: $($_.Exception.Message)" }
}

# --- calling the API -----------------------------------------------------------------------------------------------

# Call a schema method. Handles, transparently:
#   *_MIGRATE_N       switch DC (home DC for PHONE/USER/NETWORK, a file DC for FILE)
#   FLOOD_WAIT_N      sleep when N <= 60 s, otherwise throw
#   dead auth key     make a new key once (only possible before login)
#   dropped socket    reconnect and retry once (safe: sendMessage dedups on random_id)
function Invoke-TgApi {
    param(
        [Parameter(Mandatory)]$Query,
        [int]$Dc = 0,
        [string]$ResultType = '',
        [switch]$NoAuthorize,
        [int]$MaxFloodSleepSec = 60
    )
    $s = Get-TgSession
    $isHome = ($Dc -le 0)
    if ($isHome) { $Dc = if ($s.dcId) { [int]$s.dcId } else { $script:TG_DEFAULT_DC } }

    $reconnects = 0
    $rekeys = 0
    for ($hop = 0; $hop -lt 12; $hop++) {
        try {
            $conn = Get-TgConnection -Dc $Dc -Authorize:(-not $isHome -and -not $NoAuthorize)
            $value = Invoke-TgRpc -Conn $conn -Query $Query -ResultType $ResultType
            return ,$value
        } catch {
            $err = $_
            $ex = $err.Exception
            $name = [string]$ex.Data['tgError']
            if ($name -match '^(PHONE|USER|NETWORK)_MIGRATE_(\d+)$') {
                $Dc = [int]$Matches[2]
                $s.dcId = $Dc; Save-TgSession       # the account lives there now
                $isHome = $true
                continue
            }
            if ($name -match '^FILE_MIGRATE_(\d+)$') {
                $Dc = [int]$Matches[1]
                $isHome = $false
                continue
            }
            if ($name -match '^FLOOD(_PREMIUM)?_WAIT_(\d+)$') {
                $wait = [int]$Matches[2]
                if ($wait -gt $MaxFloodSleepSec) {
                    throw (New-TgException "Telegram flood wait: retry in $wait s (too long to wait here)." @{ tgCode = 420; tgError = $name; tgFloodWait = $wait })
                }
                Write-Verbose "FLOOD_WAIT $wait s"
                Start-Sleep -Seconds ($wait + 1)
                continue
            }
            $transport = [string]$ex.Data['tgTransport']
            if ($transport -eq 'authkey' -or $ex.Data['tgTransportCode'] -eq -404) {
                if ($rekeys -ge 1 -or $s.userId) { throw }   # a logged-in key is not ours to discard silently
                $rekeys++
                [void](Get-TgConnection -Dc $Dc -ForceNewKey)
                continue
            }
            if ($transport -in 'io', 'closed', 'framing' -and $reconnects -lt 1) {
                $reconnects++
                $c = $script:TG_CONNS[$Dc]; if ($c) { Close-TgConnection $c; $script:TG_CONNS.Remove($Dc) }
                continue
            }
            throw
        }
    }
    throw (New-TgException "Telegram call '$($Query._)' kept redirecting; giving up.")
}

# --- peers -------------------------------------------------------------------------------------------------------------

# Turn a cached peer record into an input peer object.
function ConvertTo-TgInputPeer {
    param($Record)
    switch ($Record.type) {
        'user'    { return [ordered]@{ _ = 'inputPeerUser';    user_id = (ConvertTo-TlInt64 $Record.id);    access_hash = (ConvertTo-TlInt64 $Record.accessHash) } }
        'channel' { return [ordered]@{ _ = 'inputPeerChannel'; channel_id = (ConvertTo-TlInt64 $Record.id); access_hash = (ConvertTo-TlInt64 $Record.accessHash) } }
        'chat'    { return [ordered]@{ _ = 'inputPeerChat';    chat_id = (ConvertTo-TlInt64 $Record.id) } }
    }
    throw (New-TgException "Unknown cached peer type '$($Record.type)'.")
}

# Resolve @username (with or without the @) to an input peer usable in the other calls.
# The access_hash is cached in the session, so a bot is resolved over the network once.
function Resolve-TgPeer {
    param([Parameter(Mandatory)][string]$Username, [switch]$Refresh)
    $name = $Username.Trim().TrimStart('@')
    $key  = $name.ToLowerInvariant()
    $s = Get-TgSession
    if (-not $Refresh -and $s.peers[$key]) { return (ConvertTo-TgInputPeer $s.peers[$key]) }

    $r = Invoke-TgApi ([ordered]@{ _ = 'contacts.resolveUsername'; username = $name })
    $peer = $r.peer
    $record = $null
    switch ($peer._) {
        'peerUser' {
            $u = @($r.users) | Where-Object { $_.id -eq $peer.user_id } | Select-Object -First 1
            if ($u) { $record = @{ type = 'user'; id = [string]$u.id; accessHash = [string]$u.access_hash } }
        }
        'peerChannel' {
            $c = @($r.chats) | Where-Object { $_.id -eq $peer.channel_id } | Select-Object -First 1
            if ($c) { $record = @{ type = 'channel'; id = [string]$c.id; accessHash = [string]$c.access_hash } }
        }
        'peerChat' { $record = @{ type = 'chat'; id = [string]$peer.chat_id; accessHash = '0' } }
    }
    if (-not $record) { throw (New-TgException "Telegram did not return an entity for '@$name'.") }
    $s.peers[$key] = $record
    Save-TgSession
    return (ConvertTo-TgInputPeer $record)
}

# --- messages ----------------------------------------------------------------------------------------------------------------

function New-TgRandomId { return [BitConverter]::ToInt64((New-TgRandomBytes 8), 0) }

# Pull the id of the message we just sent out of whichever Updates shape came back.
function Get-TgSentMessageId {
    param($Updates, [long]$RandomId)
    if ($Updates._ -eq 'updateShortSentMessage') { return [int]$Updates.id }
    foreach ($u in @($Updates.updates)) {
        if ($u._ -eq 'updateMessageID' -and $u.random_id -eq $RandomId) { return [int]$u.id }
    }
    foreach ($u in @($Updates.updates)) {
        if ($u._ -in 'updateNewMessage', 'updateNewChannelMessage' -and $u.message.out) { return [int]$u.message.id }
    }
    return 0
}

# Send a text message. Returns @{ Id = <message id>; RandomId = <long> }.
function Send-TgMessage {
    param(
        [Parameter(Mandatory)]$Peer,
        [Parameter(Mandatory)][string]$Text,
        [switch]$NoWebPage
    )
    $rid = New-TgRandomId
    $q = [ordered]@{ _ = 'messages.sendMessage'; peer = $Peer; message = $Text; random_id = $rid }
    if ($NoWebPage) { $q.no_webpage = $true }
    $res = Invoke-TgApi $q
    return @{ Id = (Get-TgSentMessageId $res $rid); RandomId = $rid }
}

# Reduce a message object to what callers need; Raw keeps the full parsed object (reply
# markup, media, anything else).
function ConvertTo-TgSimpleMessage {
    param($Message)
    $doc = $null
    if ($Message.media -and $Message.media._ -eq 'messageMediaDocument' -and $Message.media.document -and $Message.media.document._ -eq 'document') {
        $d = $Message.media.document
        $fileName = ''
        foreach ($a in @($d.attributes)) { if ($a._ -eq 'documentAttributeFilename') { $fileName = [string]$a.file_name } }
        $doc = @{
            id = $d.id; access_hash = $d.access_hash; file_reference = $d.file_reference
            dc_id = $d.dc_id; size = $d.size; mime = [string]$d.mime_type; file_name = $fileName
        }
    }
    $unix = [long]$Message.date
    return @{
        id          = [int]$Message.id
        date        = $script:TG_EPOCH.AddSeconds($unix)
        out         = [bool]$Message.out
        text        = [string]$Message.message
        entities    = @($Message.entities)
        document    = $doc
        replyMarkup = $Message.reply_markup
        raw         = $Message
    }
}

# Recent messages of a chat as simplified objects, oldest first. -MinId only returns messages
# with a greater id (so polling after a known message is cheap).
function Get-TgHistory {
    param(
        [Parameter(Mandatory)]$Peer,
        [int]$Limit = 20,
        [int]$MinId = 0
    )
    $r = Invoke-TgApi ([ordered]@{
        _ = 'messages.getHistory'; peer = $Peer; offset_id = 0; offset_date = 0; add_offset = 0
        limit = $Limit; max_id = 0; min_id = $MinId; hash = [long]0
    })
    if ($r._ -eq 'messages.messagesNotModified') { return @() }
    $out = @()
    foreach ($m in @($r.messages)) {
        if ($m._ -ne 'message') { continue }        # messageEmpty / messageService carry no text
        $out += ,(ConvertTo-TgSimpleMessage $m)
    }
    return @($out | Sort-Object { $_.id })
}

# Poll the chat every ~1.5 s until an incoming (not ours) message with id > AfterId satisfies
# -Predicate (a scriptblock receiving the simplified message; default: any). Returns that
# message, or $null on timeout.
function Wait-TgReply {
    param(
        [Parameter(Mandatory)]$Peer,
        [int]$AfterId = 0,
        [int]$TimeoutSec = 60,
        [scriptblock]$Predicate = { $true },
        [double]$PollSec = 1.5
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ($true) {
        $msgs = Get-TgHistory -Peer $Peer -Limit 20 -MinId $AfterId
        foreach ($m in $msgs) {
            if ($m.out -or $m.id -le $AfterId) { continue }
            if (& $Predicate $m) { return $m }
        }
        if ([DateTime]::UtcNow -ge $deadline) { return $null }
        Start-Sleep -Milliseconds ([int]($PollSec * 1000))
    }
}

# --- files ---------------------------------------------------------------------------------------------------------------------

# Download a document (the `document` of a simplified message) to -Path. Reads 512 KB chunks
# from the document's own DC (importing the account there first if needed) into <Path>.part,
# renaming on success. -OnProgress receives (bytesDone, totalBytes).
function Save-TgDocument {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$OnProgress = $null
    )
    $total = [long]$Document.size
    $dc = [int]$Document.dc_id
    $location = [ordered]@{
        _ = 'inputDocumentFileLocation'
        id = $Document.id; access_hash = $Document.access_hash
        file_reference = [byte[]]$Document.file_reference; thumb_size = ''
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $part = "$Path.part"
    $fs = [System.IO.File]::Open($part, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $done = 0L
    try {
        while ($true) {
            $res = Invoke-TgApi ([ordered]@{
                _ = 'upload.getFile'; location = $location; offset = $done; limit = $script:TG_CHUNK
            }) -Dc $dc
            if ($res._ -ne 'upload.file') { throw (New-TgException "Telegram served the file through a CDN ($($res._)); not supported.") }
            $chunk = [byte[]]$res.bytes
            if ($chunk.Length -gt 0) { $fs.Write($chunk, 0, $chunk.Length) }
            $done += $chunk.Length
            if ($OnProgress) { & $OnProgress $done $total }
            if ($chunk.Length -lt $script:TG_CHUNK -or ($total -gt 0 -and $done -ge $total)) { break }
        }
    } catch {
        $fs.Dispose(); $fs = $null
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    if ($total -gt 0 -and $done -ne $total) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw (New-TgException "Download incomplete: got $done of $total bytes.")
    }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $part -Destination $Path -Force
    return $Path
}
