# Telegram MTProto 2.0 user-account client, written in PowerShell on the .NET BCL alone.
# Dot-source this one file; it loads the layers in dependency order:
#
#   TgNative     compiled hot loops (TL reader/writer, AES-IGE, PBKDF2, pq factoring)
#   TgSchema     TL schema parser (schema/api.tl, schema/mtproto.tl)
#   TgCodec      schema-driven serializer / deserializer
#   TgCrypto     hashes, key schedule, RSA_PAD, DH checks, 2FA SRP
#   TgTransport  TCP, auth key creation, encrypted RPC loop
#   TgSession    session.json, credentials, permissions
#   TgClient     public API: Connect-Telegram, Resolve-TgPeer, Send-TgMessage, Get-TgHistory,
#                Wait-TgReply, Save-TgDocument
#   TgAuth       login / status / logout
#
# Needs lib/Platform.ps1 loaded first (Join-DlPath, Test-DlWindows, Get-DlDataRoot).

$tgRoot = $PSScriptRoot
. (Join-Path $tgRoot 'TgNative.ps1')
. (Join-Path $tgRoot 'TgSchema.ps1')
. (Join-Path $tgRoot 'TgCodec.ps1')
. (Join-Path $tgRoot 'TgCrypto.ps1')
. (Join-Path $tgRoot 'TgTransport.ps1')
. (Join-Path $tgRoot 'TgSession.ps1')
. (Join-Path $tgRoot 'TgClient.ps1')
. (Join-Path $tgRoot 'TgAuth.ps1')
