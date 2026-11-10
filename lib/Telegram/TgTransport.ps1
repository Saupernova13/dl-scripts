# Telegram MTProto - TCP transport, auth key creation and the encrypted RPC loop.
#
# One connection = one TCP socket to one DC = one auth key = one session. The transport is the
# "intermediate" one: a 0xeeeeeeee marker once, then every packet as a 4-byte little-endian
# length followed by the payload. Calls are synchronous: send a request, then read packets
# until the matching rpc_result (or error) arrives, handling the service messages
# (new_session_created, bad_server_salt, bad_msg_notification, msgs_ack, containers, gzip)
# on the way.
#
# A connection is a hashtable:
#   Dc, Host, Port, Client, Stream             the socket
#   AuthKey, AuthKeyId, Salt, TimeOffset       crypto state (never logged)
#   SessionId, Seq, LastMsgId                  MTProto session counters
#   Inited                                     invokeWithLayer(initConnection) already sent
#
# Depends on TgNative, TgSchema, TgCodec, TgCrypto.

$script:TG_EPOCH = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)

# Wire constructor ids we recognise by hand while draining the socket.
$script:TG_ID = @{
    RpcResult         = [Convert]::ToInt32('f35c6d01', 16)
    RpcError          = [Convert]::ToInt32('2144ca19', 16)
    MsgContainer      = [Convert]::ToInt32('73f1f8dc', 16)
    GzipPacked        = [Convert]::ToInt32('3072cfa1', 16)
    NewSessionCreated = [Convert]::ToInt32('9ec20908', 16)
    BadServerSalt     = [Convert]::ToInt32('edab447b', 16)
    BadMsgNotify      = [Convert]::ToInt32('a7eff811', 16)
    MsgsAck           = [Convert]::ToInt32('62d6b459', 16)
    Pong              = [Convert]::ToInt32('347773c5', 16)
}

# Production DC addresses (Telegram Desktop's built-in list). help.getConfig refines them.
$script:TG_DC_ADDRESSES = @{
    1 = @('149.154.175.50')
    2 = @('149.154.167.51', '95.161.76.100')
    3 = @('149.154.175.100')
    4 = @('149.154.167.91')
    5 = @('149.154.171.5')
}
$script:TG_PORT = 443

# --- errors -----------------------------------------------------------------------------------

# An exception carrying structured data, so callers branch on .Data['tgCode'] / ['tgError']
# instead of parsing the message.
function New-TgException {
    param([string]$Message, [hashtable]$Data = @{})
    $ex = New-Object System.Exception $Message
    foreach ($k in $Data.Keys) { $ex.Data[$k] = $Data[$k] }
    return $ex
}

function Get-TgErrorInfo {
    param($ErrorRecord)
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    return @{
        Code    = $ex.Data['tgCode']
        Error   = $ex.Data['tgError']
        Message = $ex.Message
    }
}

# --- time and ids ---------------------------------------------------------------------------------

function Get-TgUnixTime { return [long][math]::Floor(([DateTime]::UtcNow - $script:TG_EPOCH).TotalSeconds) }

# Client message ids: server-corrected unix time in the high 32 bits, sub-second in the low,
# divisible by 4, strictly increasing within a connection.
function New-TgMsgId {
    param($Conn)
    $ms  = ([DateTime]::UtcNow - $script:TG_EPOCH).TotalMilliseconds
    $sec = [long][math]::Floor($ms / 1000) + [long]$Conn.TimeOffset
    $frac = [long](($ms % 1000) * 4294967.296)
    $id = (($sec -shl 32) -bor $frac) -band ([long]-4)
    if ($id -le $Conn.LastMsgId) { $id = $Conn.LastMsgId + 4 }
    $Conn.LastMsgId = $id
    return $id
}

# --- socket -----------------------------------------------------------------------------------------

function Read-TgExact {
    param($Stream, [int]$Count)
    $buf = New-Object byte[] $Count
    $got = 0
    while ($got -lt $Count) {
        try {
            $n = $Stream.Read($buf, $got, $Count - $got)
        } catch [System.IO.IOException] {
            throw (New-TgException "Telegram connection timed out or dropped: $($_.Exception.Message)" @{ tgTransport = 'io' })
        }
        if ($n -le 0) { throw (New-TgException 'Telegram closed the connection.' @{ tgTransport = 'closed' }) }
        $got += $n
    }
    return ,$buf
}

# Open the TCP connection and send the transport marker.
function Open-TgConnection {
    param([int]$Dc, [string]$HostName, [int]$Port = 443, [int]$TimeoutSec = 20, [int]$ReadTimeoutSec = 30)
    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $iar = $client.BeginConnect($HostName, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) {
        $client.Close()
        throw (New-TgException "Timed out connecting to Telegram DC $Dc ($HostName`:$Port)." @{ tgTransport = 'connect' })
    }
    try { $client.EndConnect($iar) } catch {
        $client.Close()
        throw (New-TgException "Could not connect to Telegram DC $Dc ($HostName`:$Port): $($_.Exception.Message)" @{ tgTransport = 'connect' })
    }
    $stream = $client.GetStream()
    $stream.ReadTimeout  = $ReadTimeoutSec * 1000
    $stream.WriteTimeout = 30000
    $marker = [byte[]](0xEE, 0xEE, 0xEE, 0xEE)
    $stream.Write($marker, 0, 4)
    return @{
        Dc = $Dc; Host = $HostName; Port = $Port; Client = $client; Stream = $stream
        AuthKey = $null; AuthKeyId = $null; Salt = [long]0; TimeOffset = 0
        SessionId = [BitConverter]::ToInt64((New-TgRandomBytes 8), 0)
        Seq = 0; LastMsgId = [long]0; Inited = $false
    }
}

function Close-TgConnection {
    param($Conn)
    if (-not $Conn) { return }
    try { if ($Conn.Stream) { $Conn.Stream.Dispose() } } catch { }
    try { if ($Conn.Client) { $Conn.Client.Close() } } catch { }
    $Conn.Stream = $null; $Conn.Client = $null
}

function Send-TgPacket {
    param($Conn, [byte[]]$Payload)
    $frame = Join-TgBytes ([BitConverter]::GetBytes([int]$Payload.Length)) $Payload
    $Conn.Stream.Write($frame, 0, $frame.Length)
}

function Receive-TgPacket {
    param($Conn)
    $len = [BitConverter]::ToInt32((Read-TgExact $Conn.Stream 4), 0)
    if ($len -lt 0 -or $len -gt 0x1000000) { throw (New-TgException "Telegram sent an implausible packet length ($len)." @{ tgTransport = 'framing' }) }
    $payload = Read-TgExact $Conn.Stream $len
    if ($len -eq 4) {
        $code = [BitConverter]::ToInt32($payload, 0)
        throw (New-TgException "Telegram transport error $code." @{ tgTransport = 'error'; tgTransportCode = $code })
    }
    return ,$payload
}

# --- unencrypted messages (key creation only) -----------------------------------------------------------

function Invoke-TgPlain {
    param($Conn, $Query)
    $body = ConvertTo-TlBytes $Query
    $msg = Join-TgBytes (New-Object byte[] 8) ([BitConverter]::GetBytes((New-TgMsgId $Conn))) `
                        ([BitConverter]::GetBytes([int]$body.Length)) $body
    Send-TgPacket $Conn $msg
    $resp = Receive-TgPacket $Conn
    if ($resp.Length -lt 20) { throw (New-TgException 'Telegram sent a truncated handshake reply.') }
    $len = [BitConverter]::ToInt32($resp, 16)
    if ($len -lt 4 -or 20 + $len -gt $resp.Length) { throw (New-TgException 'Telegram sent a malformed handshake reply.') }
    return (ConvertFrom-TlBytes (Get-TgSlice $resp 20 $len))
}

# Create a fresh auth key on an open connection (req_pq_multi -> req_DH_params ->
# set_client_DH_params). Fills AuthKey / AuthKeyId / Salt / TimeOffset on $Conn.
function New-TgAuthKey {
    param($Conn, [int]$MaxAttempts = 3)

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try { return (Invoke-TgAuthKeyExchange $Conn) }
        catch {
            $lastError = $_
            # Only a dh_gen_retry is worth another go on the same socket; anything else is final.
            if ($_.Exception.Data['tgRetry']) { continue }
            throw
        }
    }
    throw $lastError
}

function Invoke-TgAuthKeyExchange {
    param($Conn)

    $nonce = New-TgRandomBytes 16
    $res = Invoke-TgPlain $Conn ([ordered]@{ _ = 'req_pq_multi'; nonce = $nonce })
    if ($res._ -ne 'resPQ' -or -not (Compare-TgBytes $res.nonce $nonce)) { throw (New-TgException 'Handshake: bad resPQ.') }
    $serverNonce = [byte[]]$res.server_nonce

    $key = $null
    $keys = Get-TgRsaKeys
    foreach ($fp in $res.server_public_key_fingerprints) {
        $key = $keys | Where-Object { $_.Fingerprint -eq $fp } | Select-Object -First 1
        if ($key) { break }
    }
    if (-not $key) { throw (New-TgException 'Handshake: the server offers no RSA key this client knows.') }

    $pf = Get-TgPqFactors ([byte[]]$res.pq)
    $newNonce = New-TgRandomBytes 32
    $innerBytes = ConvertTo-TlBytes ([ordered]@{
        _ = 'p_q_inner_data_dc'; pq = [byte[]]$res.pq; p = $pf.P; q = $pf.Q
        nonce = $nonce; server_nonce = $serverNonce; new_nonce = $newNonce; dc = $Conn.Dc
    })
    $dh = Invoke-TgPlain $Conn ([ordered]@{
        _ = 'req_DH_params'; nonce = $nonce; server_nonce = $serverNonce; p = $pf.P; q = $pf.Q
        public_key_fingerprint = $key.Fingerprint; encrypted_data = (Protect-TgRsaPad $innerBytes $key)
    })
    if ($dh._ -ne 'server_DH_params_ok') { throw (New-TgException "Handshake: server answered $($dh._).") }
    if (-not (Compare-TgBytes $dh.nonce $nonce) -or -not (Compare-TgBytes $dh.server_nonce $serverNonce)) {
        throw (New-TgException 'Handshake: nonce mismatch in server_DH_params.')
    }

    # tmp_aes_key = SHA1(new_nonce+server_nonce) + SHA1(server_nonce+new_nonce)[0..12]
    # tmp_aes_iv  = SHA1(server_nonce+new_nonce)[12..20] + SHA1(new_nonce+new_nonce) + new_nonce[0..4]
    $h1 = Get-TgSha1 $newNonce $serverNonce
    $h2 = Get-TgSha1 $serverNonce $newNonce
    $h3 = Get-TgSha1 $newNonce $newNonce
    $tmpKey = Join-TgBytes $h1 (Get-TgSlice $h2 0 12)
    $tmpIv  = Join-TgBytes (Get-TgSlice $h2 12 8) $h3 (Get-TgSlice $newNonce 0 4)

    $answer = Unprotect-TgIge ([byte[]]$dh.encrypted_answer) $tmpKey $tmpIv
    $answerData = Get-TgSlice $answer 20 ($answer.Length - 20)
    $reader = New-Object DlTg.TlReader (,$answerData)
    $inner = Read-TlValue $reader (Get-TlTypeInfo 'Object')
    if (-not (Compare-TgBytes (Get-TgSlice $answer 0 20) (Get-TgSha1 (Get-TgSlice $answerData 0 $reader.Position)))) {
        throw (New-TgException 'Handshake: server_DH_inner_data hash mismatch.')
    }
    if ($inner._ -ne 'server_DH_inner_data') { throw (New-TgException 'Handshake: unexpected inner data.') }
    if (-not (Compare-TgBytes $inner.nonce $nonce) -or -not (Compare-TgBytes $inner.server_nonce $serverNonce)) {
        throw (New-TgException 'Handshake: nonce mismatch in server_DH_inner_data.')
    }

    $pBytes = [byte[]]$inner.dh_prime
    $g = [int]$inner.g
    $p = ConvertTo-TgBigInt $pBytes
    if (-not (Test-TgSafePrime $pBytes)) { throw (New-TgException 'Handshake: dh_prime is not a 2048-bit safe prime.') }
    if (-not (Test-TgDhGenerator $g $p)) { throw (New-TgException 'Handshake: unusable DH generator.') }
    $gA = ConvertTo-TgBigInt ([byte[]]$inner.g_a)
    if (-not (Test-TgDhRange $gA $p)) { throw (New-TgException 'Handshake: g_a is out of range.') }

    $timeOffset = [int]([long]$inner.server_time - (Get-TgUnixTime))

    $b   = ConvertTo-TgBigInt (New-TgRandomBytes 256)
    $gB  = [System.Numerics.BigInteger]::ModPow($g, $b, $p)
    if (-not (Test-TgDhRange $gB $p)) { throw (New-TgException 'Handshake: g_b is out of range.') }
    $authKey = ConvertFrom-TgBigInt ([System.Numerics.BigInteger]::ModPow($gA, $b, $p)) 256

    $clientInner = ConvertTo-TlBytes ([ordered]@{
        _ = 'client_DH_inner_data'; nonce = $nonce; server_nonce = $serverNonce
        retry_id = [long]0; g_b = (ConvertFrom-TgBigInt $gB)
    })
    $withHash = Join-TgBytes (Get-TgSha1 $clientInner) $clientInner
    $padLen = (16 - ($withHash.Length % 16)) % 16
    if ($padLen) { $withHash = Join-TgBytes $withHash (New-TgRandomBytes $padLen) }
    $fin = Invoke-TgPlain $Conn ([ordered]@{
        _ = 'set_client_DH_params'; nonce = $nonce; server_nonce = $serverNonce
        encrypted_data = (Protect-TgIge $withHash $tmpKey $tmpIv)
    })

    $authSha = Get-TgSha1 $authKey
    if ($fin._ -eq 'dh_gen_retry') { throw (New-TgException 'Handshake: server asked to retry.' @{ tgRetry = $true }) }
    if ($fin._ -ne 'dh_gen_ok') { throw (New-TgException "Handshake: server answered $($fin._)." ) }
    $expect = Get-TgSlice (Get-TgSha1 $newNonce ([byte[]]@(1)) (Get-TgSlice $authSha 0 8)) 4 16
    if (-not (Compare-TgBytes $expect ([byte[]]$fin.new_nonce_hash1))) { throw (New-TgException 'Handshake: new_nonce_hash1 mismatch.') }

    $Conn.AuthKey    = $authKey
    $Conn.AuthKeyId  = Get-TgSlice $authSha 12 8
    $Conn.TimeOffset = $timeOffset
    $Conn.Salt       = [BitConverter]::ToInt64((Invoke-TgXor (Get-TgSlice $newNonce 0 8) (Get-TgSlice $serverNonce 0 8)), 0)
    return $Conn
}

# --- encrypted messages ---------------------------------------------------------------------------------------

# Encrypt and send one message. Content-related messages (RPC calls) take an odd seq_no and
# advance the counter; service messages (acks) take an even one. Returns the msg_id.
function Send-TgEncrypted {
    param($Conn, [byte[]]$Body, [bool]$Content = $true)
    $msgId = New-TgMsgId $Conn
    $seqNo = $Conn.Seq * 2
    if ($Content) { $seqNo += 1; $Conn.Seq++ }

    $head = Join-TgBytes ([BitConverter]::GetBytes([long]$Conn.Salt)) ([BitConverter]::GetBytes([long]$Conn.SessionId)) `
                         ([BitConverter]::GetBytes([long]$msgId)) ([BitConverter]::GetBytes([int]$seqNo)) `
                         ([BitConverter]::GetBytes([int]$Body.Length))
    $padLen = 12 + ((16 - ((32 + $Body.Length + 12) % 16)) % 16)
    $plain = Join-TgBytes $head $Body (New-TgRandomBytes $padLen)

    $msgKey = Get-TgMsgKey $Conn.AuthKey $plain 0
    $ki = Get-TgAesKeyIv $Conn.AuthKey $msgKey 0
    $enc = Protect-TgIge $plain $ki.Key $ki.Iv
    Send-TgPacket $Conn (Join-TgBytes $Conn.AuthKeyId $msgKey $enc)
    return $msgId
}

# Read one packet, verify and decrypt it. Returns @{ MsgId; SeqNo; Body } or $null for a message
# from some other session (stale, safe to skip).
function Receive-TgEncrypted {
    param($Conn)
    $pkt = Receive-TgPacket $Conn
    if ($pkt.Length -lt 24 + 32 -or (($pkt.Length - 24) % 16) -ne 0) {
        throw (New-TgException 'Telegram sent a malformed encrypted packet.')
    }
    if (-not (Compare-TgBytes (Get-TgSlice $pkt 0 8) $Conn.AuthKeyId)) {
        throw (New-TgException 'Telegram answered with an unknown auth key.' @{ tgTransport = 'authkey' })
    }
    $msgKey = Get-TgSlice $pkt 8 16
    $ki = Get-TgAesKeyIv $Conn.AuthKey $msgKey 8
    $plain = Unprotect-TgIge (Get-TgSlice $pkt 24 ($pkt.Length - 24)) $ki.Key $ki.Iv
    if (-not (Compare-TgBytes (Get-TgMsgKey $Conn.AuthKey $plain 8) $msgKey)) {
        throw (New-TgException 'Telegram message failed its msg_key check.')
    }
    $sessionId = [BitConverter]::ToInt64($plain, 8)
    $msgId = [BitConverter]::ToInt64($plain, 16)
    $seqNo = [BitConverter]::ToInt32($plain, 24)
    $len   = [BitConverter]::ToInt32($plain, 28)
    if ($len -lt 0 -or 32 + $len -gt $plain.Length) { throw (New-TgException 'Telegram message has a bad length.') }
    if ($sessionId -ne $Conn.SessionId) { return $null }
    return @{ MsgId = $msgId; SeqNo = $seqNo; Body = (Get-TgSlice $plain 32 $len) }
}

# Tell the server we have these (content-related) messages, so it stops retransmitting them.
function Send-TgAcks {
    param($Conn, $MsgIds)
    $ids = @($MsgIds)
    if ($ids.Count -eq 0) { return }
    $body = ConvertTo-TlBytes ([ordered]@{ _ = 'msgs_ack'; msg_ids = [long[]]$ids })
    try { [void](Send-TgEncrypted $Conn $body $false) } catch { Write-Verbose "ack failed: $($_.Exception.Message)" }
}

# --- reading the reply --------------------------------------------------------------------------------------------

# Interpret one server message (recursing into containers and gzip) and record in $State what
# it means for the call in flight:
#   State.Outcome = $null            keep reading
#                 = @{Kind='result'; Value}   the answer
#                 = @{Kind='error'; Code; Message}   rpc_error
#                 = @{Kind='resend'}   salt/time/seq fixed - send the request again
function Read-TgServerMessage {
    param($Conn, $State, [long]$MsgId, [int]$SeqNo, [byte[]]$Body)
    if ($Body.Length -lt 4) { return }
    if ($SeqNo -band 1) { [void]$State.Acks.Add($MsgId) }
    $id = [BitConverter]::ToInt32($Body, 0)
    $ids = $script:TG_ID

    if ($id -eq $ids.MsgContainer) {
        $r = New-Object DlTg.TlReader (,$Body)
        [void]$r.ReadInt()
        $count = $r.ReadInt()
        for ($i = 0; $i -lt $count; $i++) {
            $innerId  = $r.ReadLong()
            $innerSeq = $r.ReadInt()
            $innerLen = $r.ReadInt()
            Read-TgServerMessage $Conn $State $innerId $innerSeq ($r.ReadRaw($innerLen))
        }
    }
    elseif ($id -eq $ids.GzipPacked) {
        $r = New-Object DlTg.TlReader (,$Body)
        [void]$r.ReadInt()
        Read-TgServerMessage $Conn $State $MsgId ($SeqNo -band -2) (ConvertFrom-TlGzip $r.ReadBytes())  # acked above
    }
    elseif ($id -eq $ids.RpcResult) {
        $reqId = [BitConverter]::ToInt64($Body, 4)
        if ($reqId -ne $State.ReqMsgId) { return }       # an answer to something we stopped waiting for
        $result = Get-TgSlice $Body 12 ($Body.Length - 12)
        if ($result.Length -ge 4 -and [BitConverter]::ToInt32($result, 0) -eq $ids.GzipPacked) {
            $r = New-Object DlTg.TlReader (,$result)
            [void]$r.ReadInt()
            $result = ConvertFrom-TlGzip $r.ReadBytes()
        }
        if ($result.Length -ge 4 -and [BitConverter]::ToInt32($result, 0) -eq $ids.RpcError) {
            $r = New-Object DlTg.TlReader (,$result)
            [void]$r.ReadInt()
            $code = $r.ReadInt()
            $State.Outcome = @{ Kind = 'error'; Code = $code; Message = $r.ReadString() }
        } else {
            $State.Outcome = @{ Kind = 'result'; Value = (ConvertFrom-TlBytes $result -Type $State.ResultType -AllowTrailing) }
        }
    }
    elseif ($id -eq $ids.NewSessionCreated) {
        $Conn.Salt = [BitConverter]::ToInt64($Body, 20)
    }
    elseif ($id -eq $ids.BadServerSalt) {
        $badId = [BitConverter]::ToInt64($Body, 4)
        $Conn.Salt = [BitConverter]::ToInt64($Body, 20)
        if ($badId -eq $State.ReqMsgId) { $State.Outcome = @{ Kind = 'resend'; Why = 'bad_server_salt' } }
    }
    elseif ($id -eq $ids.BadMsgNotify) {
        $badId = [BitConverter]::ToInt64($Body, 4)
        $code  = [BitConverter]::ToInt32($Body, 16)
        if ($badId -ne $State.ReqMsgId) { return }
        switch ($code) {
            { $_ -in 16, 17 } {
                # msg_id too low/high: our clock is off. The server's own msg_id tells the time.
                $Conn.TimeOffset = [int](($MsgId -shr 32) - (Get-TgUnixTime))
                $State.Outcome = @{ Kind = 'resend'; Why = "bad_msg_notification $code" }
            }
            32 { $Conn.Seq += 64; $State.Outcome = @{ Kind = 'resend'; Why = 'seq_no too low' } }
            33 { $Conn.Seq = [math]::Max(0, $Conn.Seq - 16); $State.Outcome = @{ Kind = 'resend'; Why = 'seq_no too high' } }
            48 { $State.Outcome = @{ Kind = 'resend'; Why = 'bad salt' } }
            default {
                $State.Outcome = @{ Kind = 'error'; Code = 0; Message = "MTPROTO_BAD_MSG_$code" }
            }
        }
    }
    # msgs_ack, pong, msg_detailed_info, updates...: nothing to do for a synchronous caller.
}

# Wait for the answer to $ReqMsgId. Returns the Outcome hashtable.
function Wait-TgOutcome {
    param($Conn, [long]$ReqMsgId, [string]$ResultType, [int]$DeadlineSec = 90)
    $state = @{ ReqMsgId = $ReqMsgId; ResultType = $ResultType; Outcome = $null; Acks = (New-Object System.Collections.ArrayList) }
    $deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSec)
    while ($null -eq $state.Outcome) {
        if ([DateTime]::UtcNow -gt $deadline) { throw (New-TgException "Telegram did not answer within $DeadlineSec s." @{ tgTransport = 'timeout' }) }
        $m = Receive-TgEncrypted $Conn
        if ($null -eq $m) { continue }
        Read-TgServerMessage $Conn $state $m.MsgId $m.SeqNo $m.Body
    }
    Send-TgAcks $Conn $state.Acks
    return $state.Outcome
}

# --- RPC -------------------------------------------------------------------------------------------------------------

# Call one API method on a connection that already has an auth key. The first call on a
# connection is wrapped in invokeWithLayer(initConnection(...)). Throws on rpc_error with
# .Exception.Data['tgCode'] (int) and ['tgError'] (e.g. 'PHONE_MIGRATE_4').
function Invoke-TgRpc {
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)]$Query,
        [string]$ResultType = '',
        [int]$DeadlineSec = 90,
        [int]$MaxResends = 6
    )
    if (-not $Conn.AuthKey) { throw (New-TgException 'Connection has no auth key.') }
    if (-not $ResultType) {
        $c = Get-TlConstructor $Query._
        if (-not $c) { throw (New-TgException "Unknown API method '$($Query._)'.") }
        $ResultType = $c.Result
    }

    for ($attempt = 0; $attempt -le $MaxResends; $attempt++) {
        $payload = $Query
        $wrapped = -not $Conn.Inited
        if ($wrapped) { $payload = New-TgInitWrapper $Query }
        $reqId = Send-TgEncrypted $Conn (ConvertTo-TlBytes $payload) $true
        $out = Wait-TgOutcome $Conn $reqId $ResultType $DeadlineSec
        switch ($out.Kind) {
            'result' {
                if ($wrapped) { $Conn.Inited = $true }
                return ,$out.Value
            }
            'resend' { Write-Verbose "resend: $($out.Why)"; continue }
            'error' {
                if ($wrapped -and $out.Code -ne 0 -and $out.Message -notmatch 'CONNECTION_') { $Conn.Inited = $true }
                throw (New-TgException ("Telegram error {0}: {1}" -f $out.Code, $out.Message) @{ tgCode = $out.Code; tgError = $out.Message })
            }
        }
    }
    throw (New-TgException 'Telegram kept asking for a resend; giving up.')
}

# invokeWithLayer(layer, initConnection(api_id, device info, query)). api_id comes from
# $script:TG_API_ID, set by Set-TgCredentials.
function New-TgInitWrapper {
    param($Query)
    if (-not $script:TG_API_ID) { throw (New-TgException 'Telegram api_id is not configured.') }
    $os = if (Test-DlWindows) { 'Windows' } else { 'Linux' }
    return [ordered]@{
        _ = 'invokeWithLayer'
        layer = (Initialize-TgSchema).Layer
        query = [ordered]@{
            _ = 'initConnection'
            api_id = [int]$script:TG_API_ID
            device_model = 'dlScripts'
            system_version = $os
            app_version = '1.0'
            system_lang_code = 'en'
            lang_pack = ''
            lang_code = 'en'
            query = $Query
        }
    }
}
