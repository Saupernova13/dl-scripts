# Offline tests for the native Telegram MTProto client (lib/Telegram/) and its dlrom glue.
#
# Nothing here touches the network: the codec, crypto, key schedule, service-message state
# machine, DC migration and flood-wait handling are driven with fixed vectors and mocks. The
# live handshake lives in Telegram.Live.Tests.ps1.
#
# Reference vectors (KDF, SRP, PBKDF2) came from an independent Python hashlib/pow calculation.

BeforeDiscovery {
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'lib/Platform.ps1')
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $RepoRoot 'lib/Platform.ps1')
    . (Join-Path $RepoRoot 'lib/Telegram/Telegram.ps1')
    . (Join-Path (Join-Path $RepoRoot 'dlrom') 'Common.ps1')
    . (Join-Path (Join-Path $RepoRoot 'dlrom') 'TelegramCli.ps1')

    $script:TG_DATA_DIR = Join-Path ([System.IO.Path]::GetTempPath()) "tg-tests-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:TG_DATA_DIR -Force | Out-Null

    $script:RefPrimeHex = 'c71caeb9c6b1c9048e6c522f70f13f73980d40238e3e21c14934d037563d930f48198a0aa7c14058229493d22530f4dbfa336f6e0ac925139543aed44cce7c3720fd51f69458705ac68cd4fe6b6b13abdc9746512969328454f18faf8c595f642477fe96bb2a941d5bcd1d4ac8cc49880708fa9b378e3c4f3a9060bee67cf9a4a4a695811051907e162753b56b0f6b410dba74d8a84b2a14b3144e0ef1284754fd17ed950d5965b4b9dd46582db1178d169c6bc465b0d6ff9ca3928fef5b9ae4e418fc15e83ebea0f87fa9ff5eed70050ded2849f47bf959d956850ce929851f0d8115f635b105ee2e4e15d04b2454bf6f4fadf034b10403119cd8e3b92fcc5b'
    $script:RefPbkdf2   = '9fa86b13b9d7bd6143024b697b74b9acf49cfbd305d783e0f5cec6782f82023c1f7fe5c273437caadd84de149a0e96b284edfa26f5df1ec659e046152be45620'
    $script:RefB  = '028d585cadeab91c808ef61fea94d9c06ce5ad698aebabc297e07bbe44e44709d32a541a97fc1cfb0823e8d2ca748b3f237980501a0a223960b407c13ed9cf962e0c1eae401ef21d7af0fccf610aa103e87b6c203d4075514f8bfebc71cc0884fb3da34291e693c13b4dc08c657b20a49f3dee28255ea9abbfea22fc450cd75e2f595cba4546452b51b860924d92a082c59d33efdd48d62d959932b8456a4e5db2e09da92ec26fe019a5bdf875f0a0051637c832520c76a44c1d172eeb0271b4e82856ffdda8fb10d491786e47c7ee8e8a23ff373a2ef70eefd0da8eecc13fc355c76d1025afb9d6b0dc9d39e6266ade1bd7f35ee4edc7e55d6ccfbc5fea77f9'
    $script:RefA  = '9304912dd01ed7a95d976f2bc7707ca99022165c315b84929eed67953750e4f10bd94924cdb215fd156b3d6b435ba0ce2c4e820d9d040074e5315064cb7fa4e4d15f5e23ab9607108c1a3f4fc034f1f6f05f1d797534b725cb6c988e57bf30e672b31fc95ff68d6e8765247ecdb36df4540aac08b481711ae4a53062de3a602785e92275a3494683c3c4918bc8b64db0c38cb653a4f3c72d94b8128f8909ad16da38027a837c5b8a740e295ea3f5df7602c6fbee35d5201957e3dde9b1b7d748c2c4f5ab7bfd9464ae02062aea9d642b067fea326b5bfc5d3ef14a17c0a767146e0b4096f0d7180ce93bfbded69fcc8d79582b0e487df2ce67380e38a75fac6c'
    $script:RefM1 = 'c3f7a73d28c57bbbb15c4e4638def0ef796fbbe786b5726422f4f42ad16deca8'

    function Hex { param([string]$h) return ,(ConvertFrom-TgHex $h) }
}

AfterAll {
    if ($script:TG_DATA_DIR -and (Test-Path $script:TG_DATA_DIR)) { Remove-Item -LiteralPath $script:TG_DATA_DIR -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'TL schema' {
    It 'parses the pinned layer' {
        (Initialize-TgSchema).Layer | Should -Be 233
    }
    It 'knows thousands of constructors' {
        (Initialize-TgSchema).ById.Count | Should -BeGreaterThan 2500
    }
    It 'reads constructor ids from the #tags' {
        '{0:x8}' -f (Get-TlConstructor 'auth.sendCode').Id    | Should -Be 'a677244f'
        '{0:x8}' -f (Get-TlConstructor 'resPQ').Id            | Should -Be '05162463'
        '{0:x8}' -f (Get-TlConstructor 'req_pq_multi').Id     | Should -Be 'be7e8ef1'
        '{0:x8}' -f (Get-TlConstructor 'help.getConfig').Id   | Should -Be 'c4f9186b'
        '{0:x8}' -f (Get-TlConstructor 'boolTrue').Id         | Should -Be '997275b5'
    }
    It 'looks up by id too' {
        (Get-TlConstructor ([Convert]::ToInt32('7f3b18ea', 16))).Name | Should -Be 'inputPeerEmpty'
    }
    It 'computes CRC32 ids for definitions without a tag' {
        '{0:x8}' -f (Get-TlConstructorId 'inputPeerEmpty = InputPeer;') | Should -Be '7f3b18ea'
        '{0:x8}' -f (Get-TlConstructorId 'inputPeerChat chat_id:long = InputPeer;') | Should -Be '35a95cb9'
        '{0:x8}' -f (Get-TlConstructorId 'resPQ nonce:int128 server_nonce:int128 pq:string server_public_key_fingerprints:Vector<long> = ResPQ;') | Should -Be '05162463'
    }
    It 'splits flags and conditional fields' {
        $p = @(Get-TlParams (Get-TlConstructor 'upload.getFile'))
        ($p | ForEach-Object { $_.Name }) -join ',' | Should -Be 'flags,precise,cdn_supported,location,offset,limit'
        ($p | Where-Object { $_.Name -eq 'precise' }).Bit | Should -Be 0
        ($p | Where-Object { $_.Name -eq 'cdn_supported' }).Bit | Should -Be 1
    }
    It 'parses every constructor in the layer' {
        $bad = 0
        foreach ($c in (Initialize-TgSchema).ById.Values) { try { [void](Get-TlParams $c) } catch { $bad++ } }
        $bad | Should -Be 0
    }
}

Describe 'TL codec' {
    It 'serializes a method to known bytes' {
        (ConvertTo-TgHex (ConvertTo-TlBytes @{ _ = 'help.getConfig' })) | Should -Be '6b18f9c4'
        (ConvertTo-TgHex (ConvertTo-TlBytes ([ordered]@{ _ = 'users.getUsers'; id = @(@{ _ = 'inputUserSelf' }) }))) |
            Should -Be '48a5910d15c4b51c010000003fb1c1f7'
    }
    It 'round-trips flags, vectors, true flags, longs and nested objects' {
        $o = [ordered]@{
            _ = 'messages.sendMessage'; no_webpage = $true
            peer = [ordered]@{ _ = 'inputPeerUser'; user_id = [long]5; access_hash = [long]-3 }
            message = 'hello'; random_id = [long]::MinValue
            entities = @([ordered]@{ _ = 'messageEntityBold'; offset = 0; length = 5 })
        }
        $r = ConvertFrom-TlBytes (ConvertTo-TlBytes $o)
        $r._ | Should -Be 'messages.sendMessage'
        $r.no_webpage | Should -BeTrue
        $r.peer.access_hash | Should -Be ([long]-3)
        $r.random_id | Should -Be ([long]::MinValue)
        $r.entities.Count | Should -Be 1
        $r.entities[0]._ | Should -Be 'messageEntityBold'
        $r.Contains('reply_to') | Should -BeFalse
    }
    It 'omits a conditional field and clears its bit when absent' {
        $r = ConvertFrom-TlBytes (ConvertTo-TlBytes ([ordered]@{ _ = 'upload.getFile'
            location = @{ _ = 'inputPeerPhotoFileLocation'; peer = @{ _ = 'inputPeerSelf' }; photo_id = [long]1 }
            offset = [long]0; limit = 4096 }))
        $r.flags | Should -Be 0
        $r.Contains('precise') | Should -BeFalse
    }
    It 'pads strings and bytes across the 254 length boundary' {
        foreach ($n in 0, 1, 2, 3, 4, 5, 253, 254, 255, 256, 300, 1000) {
            $b = New-Object byte[] $n
            for ($i = 0; $i -lt $n; $i++) { $b[$i] = [byte]($i % 251) }
            $w = New-Object DlTg.TlWriter
            $w.WriteBytes($b)
            ($w.Length % 4) | Should -Be 0
            $rd = New-Object DlTg.TlReader (,$w.ToArray())
            (ConvertTo-TgHex $rd.ReadBytes()) | Should -Be (ConvertTo-TgHex $b)
            $rd.Remaining | Should -Be 0
        }
    }
    It 'handles int128 and Bool and a boxed Vector<long>' {
        $nonce = New-TgRandomBytes 16
        $r = ConvertFrom-TlBytes (ConvertTo-TlBytes ([ordered]@{ _ = 'req_pq_multi'; nonce = $nonce }))
        (ConvertTo-TgHex $r.nonce) | Should -Be (ConvertTo-TgHex $nonce)
        $res = ConvertFrom-TlBytes (ConvertTo-TlBytes ([ordered]@{ _ = 'resPQ'; nonce = $nonce; server_nonce = $nonce
            pq = (Hex '17ed48941a08f981'); server_public_key_fingerprints = @([long]1, [long]-2) }))
        $res.server_public_key_fingerprints[1] | Should -Be ([long]-2)
        (ConvertFrom-TlBytes (Hex 'b5757299') -Type 'Bool') | Should -BeTrue
        (ConvertFrom-TlBytes (Hex '379779bc') -Type 'Bool') | Should -BeFalse
    }
    It 'reads a Vector result by declared type' {
        $w = New-Object DlTg.TlWriter
        $w.WriteInt(0x1cb5c415); $w.WriteInt(2); $w.WriteLong(7); $w.WriteLong(9)
        $r = ConvertFrom-TlBytes $w.ToArray() -Type 'Vector<long>'
        $r.Count | Should -Be 2
        $r[1] | Should -Be 9
    }
    It 'inflates gzip_packed, including a gzipped vector result' {
        $inner = ConvertTo-TlBytes ([ordered]@{ _ = 'users.getUsers'; id = @(@{ _ = 'inputUserSelf' }) })
        $w = New-Object DlTg.TlWriter
        $w.WriteInt([Convert]::ToInt32('3072cfa1', 16)); $w.WriteBytes((ConvertTo-TlGzip $inner))
        (ConvertFrom-TlBytes $w.ToArray())._ | Should -Be 'users.getUsers'

        $vec = New-Object DlTg.TlWriter
        $vec.WriteInt(0x1cb5c415); $vec.WriteInt(1); $vec.WriteLong(42)
        $g = New-Object DlTg.TlWriter
        $g.WriteInt([Convert]::ToInt32('3072cfa1', 16)); $g.WriteBytes((ConvertTo-TlGzip $vec.ToArray()))
        (ConvertFrom-TlBytes $g.ToArray() -Type 'Vector<long>')[0] | Should -Be 42
    }
    It 'parses rpc_result and msg_container generically' {
        $w = New-Object DlTg.TlWriter
        $w.WriteInt([Convert]::ToInt32('f35c6d01', 16)); $w.WriteLong(123)
        $w.WriteRaw((ConvertTo-TlBytes @{ _ = 'help.getConfig' }))
        $r = ConvertFrom-TlBytes $w.ToArray()
        $r._ | Should -Be 'rpc_result'
        $r.req_msg_id | Should -Be 123
        $r.result._ | Should -Be 'help.getConfig'

        $body = ConvertTo-TlBytes @{ _ = 'help.getConfig' }
        $c = New-Object DlTg.TlWriter
        $c.WriteInt([Convert]::ToInt32('73f1f8dc', 16)); $c.WriteInt(1)
        $c.WriteLong(4); $c.WriteInt(1); $c.WriteInt($body.Length); $c.WriteRaw($body)
        $cr = ConvertFrom-TlBytes $c.ToArray()
        $cr.messages[0].msg_id | Should -Be 4
        $cr.messages[0].body._ | Should -Be 'help.getConfig'
    }
    It 'rejects unknown constructors and trailing bytes' {
        { ConvertFrom-TlBytes (Hex '01020304') } | Should -Throw '*unknown constructor*'
        { ConvertFrom-TlBytes (Hex '6b18f9c400000000') } | Should -Throw '*trailing*'
    }
    It 'refuses a missing required field' {
        { ConvertTo-TlBytes @{ _ = 'users.getUsers' } } | Should -Throw '*missing field*'
    }
    It 'wraps a nested query (!X) in invokeWithLayer / initConnection' {
        $script:TG_API_ID = '4'
        $bytes = ConvertTo-TlBytes (New-TgInitWrapper ([ordered]@{ _ = 'help.getConfig' }))
        $r = ConvertFrom-TlBytes $bytes
        $r._ | Should -Be 'invokeWithLayer'
        $r.layer | Should -Be 233
        $r.query._ | Should -Be 'initConnection'
        $r.query.api_id | Should -Be 4
        $r.query.query._ | Should -Be 'help.getConfig'
    }
}

Describe 'Telegram crypto' {
    It 'matches the published AES-IGE vector' {
        $key = Hex '000102030405060708090A0B0C0D0E0F'
        $iv  = Hex '000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F'
        $c = Protect-TgIge (New-Object byte[] 32) $key $iv
        (ConvertTo-TgHex $c) | Should -Be '1a8519a6557be652e9da8e43da4ef4453cf456b4ca488aa383c79c98b34797cb'
        (ConvertTo-TgHex (Unprotect-TgIge $c $key $iv)) | Should -Be ('00' * 32)
    }
    It 'round-trips AES-256-IGE' {
        $data = New-TgRandomBytes 256; $key = New-TgRandomBytes 32; $iv = New-TgRandomBytes 32
        (ConvertTo-TgHex (Unprotect-TgIge (Protect-TgIge $data $key $iv) $key $iv)) | Should -Be (ConvertTo-TgHex $data)
    }
    It 'derives the MTProto 2.0 AES key and iv' {
        $auth = New-Object byte[] 256; for ($i = 0; $i -lt 256; $i++) { $auth[$i] = $i }
        $mk = New-Object byte[] 16;    for ($i = 0; $i -lt 16; $i++) { $mk[$i] = $i }
        $c = Get-TgAesKeyIv $auth $mk 0
        (ConvertTo-TgHex $c.Key) | Should -Be '704ed09c8b41668ae8f99d244738f71dbddc44469b6bbd4aa8573dd042bd059e'
        (ConvertTo-TgHex $c.Iv)  | Should -Be '4d266000a550edabbf4c7ce40fd0043cc92230184cd317a5cc9c2482fd3b9318'
        $s = Get-TgAesKeyIv $auth $mk 8
        (ConvertTo-TgHex $s.Key) | Should -Be '217725799b245806458174a1fcfbc883906807b15033fdd0ea2b4d69cf9c364e'
        (ConvertTo-TgHex $s.Iv)  | Should -Be '669a6538917a4fa56ca32360a431c9160be4ad887140980dab91ce7bdc47ffbc'
    }
    It 'computes msg_key from the right auth key window' {
        $auth = New-Object byte[] 256; for ($i = 0; $i -lt 256; $i++) { $auth[$i] = $i }
        $plain = New-Object byte[] 64; for ($i = 0; $i -lt 64; $i++) { $plain[$i] = ($i * 7 + 3) % 256 }
        (ConvertTo-TgHex (Get-TgMsgKey $auth $plain 0)) | Should -Be '2caeff69eac67b81810622b660da7a5c'
        (ConvertTo-TgHex (Get-TgMsgKey $auth $plain 8)) | Should -Be '821a222c0fa3892fb3b14c8ad5980594'
    }
    It 'builds and verifies an RSA_PAD block with a throwaway key pair' {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider 2048
        $pp = $rsa.ExportParameters($true)
        $n = [byte[]]$pp.Modulus
        $data = New-Object byte[] 96; for ($i = 0; $i -lt 96; $i++) { $data[$i] = $i }
        $pad  = New-Object byte[] 96; for ($i = 0; $i -lt 96; $i++) { $pad[$i] = 255 - $i }
        $block = $null
        for ($t = 1; $t -lt 50 -and -not $block; $t++) {
            $tk = New-Object byte[] 32; for ($i = 0; $i -lt 32; $i++) { $tk[$i] = ($i * $t) % 256 }
            $block = New-TgRsaPadBlock -Data $data -TempKey $tk -Padding $pad -Modulus $n
        }
        $block | Should -Not -BeNullOrEmpty
        $block.Length | Should -Be 256
        # Undo: temp_key = xor_part ^ SHA256(aes_encrypted); decrypt; reverse; check hash.
        $xored = Get-TgSlice $block 0 32; $aesEnc = Get-TgSlice $block 32 224
        $temp = Invoke-TgXor $xored (Get-TgSha256 $aesEnc)
        $withHash = Unprotect-TgIge $aesEnc $temp (New-Object byte[] 32)
        $rev = Get-TgSlice $withHash 0 192
        [Array]::Reverse($rev)
        (ConvertTo-TgHex $rev) | Should -Be (ConvertTo-TgHex (Join-TgBytes $data $pad))
        (ConvertTo-TgHex (Get-TgSlice $withHash 192 32)) | Should -Be (ConvertTo-TgHex (Get-TgSha256 $temp (Join-TgBytes $data $pad)))
        # Full RSA path: encrypt then decrypt with the private exponent recovers a 256-byte block.
        $key = @{ N = $n; E = [byte[]]$pp.Exponent }
        $enc = Protect-TgRsaPad $data $key
        $enc.Length | Should -Be 256
        $m = [System.Numerics.BigInteger]::ModPow((ConvertTo-TgBigInt $enc), (ConvertTo-TgBigInt ([byte[]]$pp.D)), (ConvertTo-TgBigInt $n))
        (ConvertFrom-TgBigInt $m 256).Length | Should -Be 256
    }
    It 'knows the production RSA key fingerprint' {
        '{0:x16}' -f (Get-TgRsaKeys)[0].Fingerprint | Should -Be 'd09d1d85de64fd85'
    }
    It 'factors pq' {
        $f = Get-TgPqFactors (Hex '17ED48941A08F981')
        (ConvertTo-TgHex $f.P) | Should -Be '494c553b'
        (ConvertTo-TgHex $f.Q) | Should -Be '53911073'
        $g = Get-TgPqFactors (Hex '0100000009')    # small semiprime: 4294967305 = 5 * 858993461
        ([System.Numerics.BigInteger](ConvertTo-TgBigInt $g.P) * (ConvertTo-TgBigInt $g.Q)) | Should -Be 4294967305
    }
    It 'checks DH parameters' {
        $p = ConvertTo-TgBigInt (Hex $script:RefPrimeHex)
        Test-TgDhGenerator 3 $p | Should -BeTrue
        Test-TgDhGenerator 2 $p | Should -BeFalse
        Test-TgSafePrime (Hex $script:RefPrimeHex) | Should -BeTrue
        $bad = (Hex $script:RefPrimeHex); $bad[255] = $bad[255] -bxor 2
        Test-TgSafePrime $bad | Should -BeFalse
        Test-TgDhRange 5 $p | Should -BeFalse
        Test-TgPrime 7919 | Should -BeTrue
        Test-TgPrime 7917 | Should -BeFalse
    }
    It 'PBKDF2-HMAC-SHA512 matches the reference' {
        $pw = [byte[]](0x70, 0x77, 0x2d, 1, 2)
        (ConvertTo-TgHex ([DlTg.Bn]::Pbkdf2Sha512($pw, (Hex '000102030405060708090a0b0c0d0e0f'), 1000, 64))) | Should -Be $script:RefPbkdf2
    }
    It 'computes the SRP proof M1 like the reference' {
        $algo = @{
            salt1 = [byte[]](0..39 | ForEach-Object { ($_ * 3 + 1) % 256 })
            salt2 = [byte[]](0..31 | ForEach-Object { ($_ * 5 + 2) % 256 })
            g = 3; p = (Hex $script:RefPrimeHex)
        }
        $a = [byte[]](0..255 | ForEach-Object { ($_ * 13 + 5) % 256 })
        $r = New-TgSrpCheck -Password 'hunter2' -Algo $algo -SrpB (Hex $script:RefB) -SrpId ([long]77) -Secret $a
        $r._ | Should -Be 'inputCheckPasswordSRP'
        $r.srp_id | Should -Be 77
        (ConvertTo-TgHex $r.A)  | Should -Be $script:RefA
        (ConvertTo-TgHex $r.M1) | Should -Be $script:RefM1
        (ConvertFrom-TlBytes (ConvertTo-TlBytes $r))._ | Should -Be 'inputCheckPasswordSRP'
    }
    It 'rejects an out-of-range srp_B' {
        $algo = @{ salt1 = (New-TgRandomBytes 8); salt2 = (New-TgRandomBytes 8); g = 3; p = (Hex $script:RefPrimeHex) }
        { New-TgSrpCheck -Password 'x' -Algo $algo -SrpB (Hex '05') -SrpId 1 } | Should -Throw '*out of range*'
    }
}

Describe 'Telegram transport' {
    BeforeAll {
        # Server-side packet builder: same layout as the client's, key schedule x = 8.
        function New-ServerPacket {
            param($Conn, [byte[]]$Body, [long]$MsgId = 1001, [int]$SeqNo = 1, [long]$Session = -1)
            if ($Session -eq -1) { $Session = $Conn.SessionId }
            $head = Join-TgBytes ([BitConverter]::GetBytes([long]5)) ([BitConverter]::GetBytes($Session)) ([BitConverter]::GetBytes($MsgId)) `
                ([BitConverter]::GetBytes($SeqNo)) ([BitConverter]::GetBytes([int]$Body.Length))
            $padLen = 12 + ((16 - ((32 + $Body.Length + 12) % 16)) % 16)
            $plain = Join-TgBytes $head $Body (New-Object byte[] $padLen)
            $mk = Get-TgMsgKey $Conn.AuthKey $plain 8
            $ki = Get-TgAesKeyIv $Conn.AuthKey $mk 8
            $pkt = Join-TgBytes $Conn.AuthKeyId $mk (Protect-TgIge $plain $ki.Key $ki.Iv)
            return ,(Join-TgBytes ([BitConverter]::GetBytes([int]$pkt.Length)) $pkt)
        }
    }
    BeforeEach {
        $script:Auth = New-Object byte[] 256; for ($i = 0; $i -lt 256; $i++) { $script:Auth[$i] = ($i * 5) % 256 }
        $script:Conn = @{
            Dc = 2; Stream = $null; AuthKey = $script:Auth; AuthKeyId = (Get-TgSlice (Get-TgSha1 $script:Auth) 12 8)
            Salt = [long]111; TimeOffset = 0; SessionId = [long]222; Seq = 0; LastMsgId = [long]0; Inited = $false
        }
    }

    It 'issues strictly increasing msg_ids divisible by 4' {
        $prev = 0L
        1..200 | ForEach-Object {
            $id = New-TgMsgId $script:Conn
            ($id % 4) | Should -Be 0
            $id | Should -BeGreaterThan $prev
            $prev = $id
        }
    }
    It 'applies the time offset to msg_id' {
        $script:Conn.TimeOffset = 1000
        $id = New-TgMsgId $script:Conn
        ($id -shr 32) | Should -BeGreaterThan ((Get-TgUnixTime) + 990)
    }
    It 'encrypts a client message that the x=0 schedule decrypts' {
        $ms = New-Object System.IO.MemoryStream
        $script:Conn.Stream = $ms
        $body = ConvertTo-TlBytes @{ _ = 'help.getConfig' }
        $msgId = Send-TgEncrypted $script:Conn $body $true
        $raw = $ms.ToArray()
        [BitConverter]::ToInt32($raw, 0) | Should -Be ($raw.Length - 4)
        (ConvertTo-TgHex (Get-TgSlice $raw 4 8)) | Should -Be (ConvertTo-TgHex $script:Conn.AuthKeyId)
        $mk = Get-TgSlice $raw 12 16
        $ki = Get-TgAesKeyIv $script:Auth $mk 0
        $plain = Unprotect-TgIge (Get-TgSlice $raw 28 ($raw.Length - 28)) $ki.Key $ki.Iv
        (ConvertTo-TgHex (Get-TgMsgKey $script:Auth $plain 0)) | Should -Be (ConvertTo-TgHex $mk)
        [BitConverter]::ToInt64($plain, 0)  | Should -Be 111
        [BitConverter]::ToInt64($plain, 8)  | Should -Be 222
        [BitConverter]::ToInt64($plain, 16) | Should -Be $msgId
        [BitConverter]::ToInt32($plain, 24) | Should -Be 1          # first content message: seq_no 1
        [BitConverter]::ToInt32($plain, 28) | Should -Be $body.Length
        (($plain.Length - 32 - $body.Length) -ge 12) | Should -BeTrue
        ($plain.Length % 16) | Should -Be 0
        $script:Conn.Seq | Should -Be 1
        [void](Send-TgEncrypted $script:Conn $body $false)           # ack-style: even seq_no, no increment
        $script:Conn.Seq | Should -Be 1
    }
    It 'decrypts a server packet and rejects tampering and a foreign auth key' {
        $body = ConvertTo-TlBytes @{ _ = 'help.getConfig' }
        $wire = New-ServerPacket $script:Conn $body
        $script:Conn.Stream = New-Object System.IO.MemoryStream (,$wire)
        $m = Receive-TgEncrypted $script:Conn
        $m.MsgId | Should -Be 1001
        (ConvertTo-TgHex $m.Body) | Should -Be (ConvertTo-TgHex $body)

        $bad = [byte[]]$wire.Clone(); $bad[$bad.Length - 1] = $bad[$bad.Length - 1] -bxor 1
        $script:Conn.Stream = New-Object System.IO.MemoryStream (,$bad)
        { Receive-TgEncrypted $script:Conn } | Should -Throw '*msg_key*'

        $other = [byte[]]$wire.Clone(); $other[4] = $other[4] -bxor 1
        $script:Conn.Stream = New-Object System.IO.MemoryStream (,$other)
        { Receive-TgEncrypted $script:Conn } | Should -Throw '*unknown auth key*'

        $script:Conn.Stream = New-Object System.IO.MemoryStream (,(New-ServerPacket $script:Conn $body 1 1 999))
        Receive-TgEncrypted $script:Conn | Should -BeNullOrEmpty    # other session: skipped
    }
    It 'turns a 4-byte frame into a transport error' {
        $script:Conn.Stream = New-Object System.IO.MemoryStream (,(Hex '040000006cfeffff'))
        { Receive-TgPacket $script:Conn } | Should -Throw '*transport error -404*'
    }

    Context 'service messages' {
        BeforeEach {
            $script:State = @{ ReqMsgId = [long]500; ResultType = 'Vector<long>'; Outcome = $null; Acks = (New-Object System.Collections.ArrayList) }
        }
        It 'returns the result of the awaited rpc_result and acks it' {
            $w = New-Object DlTg.TlWriter
            $w.WriteInt([Convert]::ToInt32('f35c6d01', 16)); $w.WriteLong(500)
            $w.WriteInt(0x1cb5c415); $w.WriteInt(1); $w.WriteLong(31337)
            Read-TgServerMessage $script:Conn $script:State 1001 1 $w.ToArray()
            $script:State.Outcome.Kind | Should -Be 'result'
            $script:State.Outcome.Value[0] | Should -Be 31337
            $script:State.Acks | Should -Contain 1001
        }
        It 'ignores an rpc_result for another request' {
            $w = New-Object DlTg.TlWriter
            $w.WriteInt([Convert]::ToInt32('f35c6d01', 16)); $w.WriteLong(499); $w.WriteInt(0x1cb5c415); $w.WriteInt(0)
            Read-TgServerMessage $script:Conn $script:State 1001 1 $w.ToArray()
            $script:State.Outcome | Should -BeNullOrEmpty
        }
        It 'decodes rpc_error, also when gzipped' {
            $e = New-Object DlTg.TlWriter
            $e.WriteInt([Convert]::ToInt32('2144ca19', 16)); $e.WriteInt(303); $e.WriteString('PHONE_MIGRATE_4')
            $w = New-Object DlTg.TlWriter
            $w.WriteInt([Convert]::ToInt32('f35c6d01', 16)); $w.WriteLong(500); $w.WriteRaw($e.ToArray())
            Read-TgServerMessage $script:Conn $script:State 1001 1 $w.ToArray()
            $script:State.Outcome.Kind | Should -Be 'error'
            $script:State.Outcome.Message | Should -Be 'PHONE_MIGRATE_4'
            $script:State.Outcome.Code | Should -Be 303

            $script:State.Outcome = $null
            $gz = New-Object DlTg.TlWriter
            $gz.WriteInt([Convert]::ToInt32('3072cfa1', 16)); $gz.WriteBytes((ConvertTo-TlGzip $e.ToArray()))
            $w2 = New-Object DlTg.TlWriter
            $w2.WriteInt([Convert]::ToInt32('f35c6d01', 16)); $w2.WriteLong(500); $w2.WriteRaw($gz.ToArray())
            Read-TgServerMessage $script:Conn $script:State 1002 1 $w2.ToArray()
            $script:State.Outcome.Message | Should -Be 'PHONE_MIGRATE_4'
        }
        It 'adopts a new salt and asks for a resend on bad_server_salt' {
            $w = New-Object DlTg.TlWriter
            $w.WriteInt([Convert]::ToInt32('edab447b', 16)); $w.WriteLong(500); $w.WriteInt(1); $w.WriteInt(48); $w.WriteLong(987654321)
            Read-TgServerMessage $script:Conn $script:State 1001 0 $w.ToArray()
            $script:Conn.Salt | Should -Be 987654321
            $script:State.Outcome.Kind | Should -Be 'resend'
        }
        It 'adopts the salt from new_session_created without ending the wait' {
            $w = New-Object DlTg.TlWriter
            $w.WriteInt([Convert]::ToInt32('9ec20908', 16)); $w.WriteLong(1); $w.WriteLong(2); $w.WriteLong(555)
            Read-TgServerMessage $script:Conn $script:State 1001 1 $w.ToArray()
            $script:Conn.Salt | Should -Be 555
            $script:State.Outcome | Should -BeNullOrEmpty
        }
        It 'corrects the clock on bad_msg_notification 17 from the server msg_id' {
            $w = New-Object DlTg.TlWriter
            $w.WriteInt([Convert]::ToInt32('a7eff811', 16)); $w.WriteLong(500); $w.WriteInt(1); $w.WriteInt(17)
            $serverId = ((Get-TgUnixTime) + 3600) -shl 32
            Read-TgServerMessage $script:Conn $script:State $serverId 0 $w.ToArray()
            $script:State.Outcome.Kind | Should -Be 'resend'
            $script:Conn.TimeOffset | Should -BeGreaterThan 3590
        }
        It 'walks a container holding a salt notice and the result' {
            $inner1 = New-Object DlTg.TlWriter
            $inner1.WriteInt([Convert]::ToInt32('9ec20908', 16)); $inner1.WriteLong(1); $inner1.WriteLong(2); $inner1.WriteLong(777)
            $inner2 = New-Object DlTg.TlWriter
            $inner2.WriteInt([Convert]::ToInt32('f35c6d01', 16)); $inner2.WriteLong(500)
            $inner2.WriteInt(0x1cb5c415); $inner2.WriteInt(1); $inner2.WriteLong(8)
            $c = New-Object DlTg.TlWriter
            $c.WriteInt([Convert]::ToInt32('73f1f8dc', 16)); $c.WriteInt(2)
            $c.WriteLong(10); $c.WriteInt(1); $b1 = $inner1.ToArray(); $c.WriteInt($b1.Length); $c.WriteRaw($b1)
            $c.WriteLong(12); $c.WriteInt(1); $b2 = $inner2.ToArray(); $c.WriteInt($b2.Length); $c.WriteRaw($b2)
            Read-TgServerMessage $script:Conn $script:State 2000 0 $c.ToArray()
            $script:Conn.Salt | Should -Be 777
            $script:State.Outcome.Value[0] | Should -Be 8
            $script:State.Acks.Count | Should -Be 2
        }
    }

    Context 'Invoke-TgRpc' {
        It 'resends after a salt notice and then returns the value' {
            Mock Send-TgEncrypted { return [long]1 }
            $script:Calls = 0
            Mock Wait-TgOutcome {
                $script:Calls++
                if ($script:Calls -eq 1) { return @{ Kind = 'resend'; Why = 'bad_server_salt' } }
                return @{ Kind = 'result'; Value = @(1, 2, 3) }
            }
            $script:TG_API_ID = '4'
            $r = Invoke-TgRpc -Conn $script:Conn -Query ([ordered]@{ _ = 'help.getNearestDc' })
            $script:Calls | Should -Be 2
            @($r).Count | Should -Be 3
            $script:Conn.Inited | Should -BeTrue
        }
        It 'throws rpc errors with code and name in Data' {
            Mock Send-TgEncrypted { return [long]1 }
            Mock Wait-TgOutcome { return @{ Kind = 'error'; Code = 400; Message = 'PHONE_CODE_INVALID' } }
            $script:TG_API_ID = '4'
            try { Invoke-TgRpc -Conn $script:Conn -Query ([ordered]@{ _ = 'help.getConfig' }) } catch { $err = $_ }
            $err.Exception.Data['tgCode']  | Should -Be 400
            $err.Exception.Data['tgError'] | Should -Be 'PHONE_CODE_INVALID'
        }
    }
}

Describe 'Telegram client' {
    BeforeEach {
        $script:TG_SESSION = $null
        Remove-Item -LiteralPath (Join-Path $script:TG_DATA_DIR 'session.json') -Force -ErrorAction SilentlyContinue
        $s = Get-TgSession
        $s.dcId = 2
    }

    Context 'Invoke-TgApi' {
        It 'switches the home DC on PHONE_MIGRATE and remembers it' {
            $script:Dcs = @()
            Mock Get-TgConnection { $script:Dcs += $Dc; return @{ Dc = $Dc } }
            Mock Invoke-TgRpc {
                if ($Conn.Dc -eq 2) { throw (New-TgException 'x' @{ tgCode = 303; tgError = 'PHONE_MIGRATE_4' }) }
                return 'ok'
            }
            $r = Invoke-TgApi ([ordered]@{ _ = 'help.getConfig' })
            $r | Should -Be 'ok'
            $script:Dcs | Should -Be @(2, 4)
            (Get-TgSession).dcId | Should -Be 4
        }
        It 'follows FILE_MIGRATE without changing the home DC' {
            Mock Get-TgConnection { return @{ Dc = $Dc } }
            Mock Invoke-TgRpc {
                if ($Conn.Dc -eq 2) { throw (New-TgException 'x' @{ tgCode = 303; tgError = 'FILE_MIGRATE_4' }) }
                return 'bytes'
            }
            (Invoke-TgApi ([ordered]@{ _ = 'help.getConfig' }) -Dc 2) | Should -Be 'bytes'
            (Get-TgSession).dcId | Should -Be 2
        }
        It 'sleeps through a short FLOOD_WAIT and retries' {
            $script:N = 0
            Mock Get-TgConnection { return @{ Dc = 2 } }
            Mock Start-Sleep { }
            Mock Invoke-TgRpc {
                $script:N++
                if ($script:N -eq 1) { throw (New-TgException 'x' @{ tgCode = 420; tgError = 'FLOOD_WAIT_3' }) }
                return 'done'
            }
            (Invoke-TgApi ([ordered]@{ _ = 'help.getConfig' })) | Should -Be 'done'
            Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 4 }
        }
        It 'refuses a long FLOOD_WAIT with a clear error' {
            Mock Get-TgConnection { return @{ Dc = 2 } }
            Mock Invoke-TgRpc { throw (New-TgException 'x' @{ tgCode = 420; tgError = 'FLOOD_WAIT_300' }) }
            { Invoke-TgApi ([ordered]@{ _ = 'help.getConfig' }) } | Should -Throw '*flood wait*300*'
        }
        It 'passes other errors through' {
            Mock Get-TgConnection { return @{ Dc = 2 } }
            Mock Invoke-TgRpc { throw (New-TgException 'boom' @{ tgCode = 400; tgError = 'PEER_ID_INVALID' }) }
            { Invoke-TgApi ([ordered]@{ _ = 'help.getConfig' }) } | Should -Throw '*boom*'
        }
    }

    Context 'peers and messages' {
        It 'resolves a username once and caches the access hash' {
            Mock Invoke-TgApi {
                return [ordered]@{ _ = 'contacts.resolvedPeer'; peer = @{ _ = 'peerUser'; user_id = [long]77 }
                    users = @([ordered]@{ _ = 'user'; id = [long]77; access_hash = [long]-9 }); chats = @() }
            }
            $p = Resolve-TgPeer -Username '@SomeBot'
            $p._ | Should -Be 'inputPeerUser'
            $p.user_id | Should -Be 77
            $p.access_hash | Should -Be (-9)
            $p2 = Resolve-TgPeer -Username 'somebot'
            $p2.access_hash | Should -Be (-9)
            Should -Invoke Invoke-TgApi -Times 1 -Exactly
            $script:TG_SESSION = $null     # and it survives a reload from disk
            (Resolve-TgPeer -Username 'SomeBot').user_id | Should -Be 77
        }
        It 'sends a message with a random_id and extracts its id' {
            Mock Invoke-TgApi { return [ordered]@{ _ = 'updateShortSentMessage'; id = 4242 } }
            $r = Send-TgMessage -Peer @{ _ = 'inputPeerSelf' } -Text 'hi'
            $r.Id | Should -Be 4242
            Should -Invoke Invoke-TgApi -ParameterFilter { $Query._ -eq 'messages.sendMessage' -and $Query.message -eq 'hi' -and $Query.random_id -ne 0 }
        }
        It 'finds the sent id in a full Updates envelope by random_id' {
            $u = [ordered]@{ _ = 'updates'; updates = @([ordered]@{ _ = 'updateMessageID'; id = 9; random_id = [long]5 }) }
            Get-TgSentMessageId $u ([long]5) | Should -Be 9
        }
        It 'simplifies history messages including document metadata' {
            Mock Invoke-TgApi {
                return [ordered]@{ _ = 'messages.messages'; chats = @(); users = @(); messages = @(
                    [ordered]@{ _ = 'message'; id = 12; date = 1700000000; out = $false; message = 'file'
                        media = [ordered]@{ _ = 'messageMediaDocument'; document = [ordered]@{ _ = 'document'; id = [long]1; access_hash = [long]2
                            file_reference = [byte[]](1, 2); dc_id = 4; size = [long]1000; mime_type = 'application/zip'
                            attributes = @([ordered]@{ _ = 'documentAttributeFilename'; file_name = 'game.zip' }) } } }
                    [ordered]@{ _ = 'message'; id = 11; date = 1700000000; out = $true; message = 'mine' }
                    [ordered]@{ _ = 'messageService'; id = 10 }) }
            }
            $h = @(Get-TgHistory -Peer @{ _ = 'inputPeerSelf' } -Limit 5)
            $h.Count | Should -Be 2
            $h[0].id | Should -Be 11                          # oldest first
            $h[0].out | Should -BeTrue
            $h[1].document.file_name | Should -Be 'game.zip'
            $h[1].document.dc_id | Should -Be 4
            $h[1].document.size | Should -Be 1000
            $h[1].document.mime | Should -Be 'application/zip'
            $h[1].date.Year | Should -Be 2023
        }
        It 'waits for an incoming message that satisfies the predicate' {
            $script:Round = 0
            Mock Get-TgHistory {
                $script:Round++
                if ($script:Round -lt 3) { return @(@{ id = 6; out = $true; text = 'me' }) }
                return @(@{ id = 6; out = $true; text = 'me' }, @{ id = 7; out = $false; text = 'noise' }, @{ id = 8; out = $false; text = 'RESULT list' })
            }
            Mock Start-Sleep { }
            $m = Wait-TgReply -Peer @{} -AfterId 5 -TimeoutSec 30 -Predicate { $args[0].text -like 'RESULT*' }
            $m.id | Should -Be 8
            $script:Round | Should -Be 3
        }
        It 'returns $null when nothing arrives in time' {
            Mock Get-TgHistory { return @() }
            $r = Wait-TgReply -Peer @{} -AfterId 5 -TimeoutSec 0 -PollSec 0.01
            $r | Should -BeNullOrEmpty
        }
    }

    Context 'Save-TgDocument' {
        BeforeEach { $script:TG_CHUNK = 8 }
        AfterEach { $script:TG_CHUNK = 512 * 1024 }
        It 'downloads chunk by chunk from the document DC and renames on success' {
            $script:Data = [byte[]](1..20)
            Mock Invoke-TgApi {
                $off = [int]$Query.offset
                $n = [math]::Min(8, 20 - $off)
                return [ordered]@{ _ = 'upload.file'; bytes = [byte[]]$script:Data[$off..($off + $n - 1)] }
            }
            $doc = @{ id = [long]1; access_hash = [long]2; file_reference = [byte[]](9); dc_id = 4; size = [long]20 }
            $path = Join-Path $script:TG_DATA_DIR 'out\file.bin'
            [void](Save-TgDocument -Document $doc -Path $path)
            ((Get-Item $path).Length) | Should -Be 20
            [System.IO.File]::ReadAllBytes($path)[19] | Should -Be 20
            (Test-Path "$path.part") | Should -BeFalse
            Should -Invoke Invoke-TgApi -Times 3 -Exactly -ParameterFilter { $Dc -eq 4 }
        }
        It 'removes the partial file when the transfer is short' {
            Mock Invoke-TgApi { return [ordered]@{ _ = 'upload.file'; bytes = [byte[]](1, 2, 3) } }
            $doc = @{ id = [long]1; access_hash = [long]2; file_reference = [byte[]](9); dc_id = 4; size = [long]20 }
            $path = Join-Path $script:TG_DATA_DIR 'short.bin'
            { Save-TgDocument -Document $doc -Path $path } | Should -Throw '*incomplete*'
            (Test-Path $path) | Should -BeFalse
            (Test-Path "$path.part") | Should -BeFalse
        }
    }
}

Describe 'Telegram session and credentials' {
    BeforeEach {
        $script:TG_SESSION = $null
        Remove-Item -LiteralPath (Join-Path $script:TG_DATA_DIR 'session.json') -Force -ErrorAction SilentlyContinue
    }
    It 'round-trips the session through disk' {
        $s = Get-TgSession
        $s.dcId = 4; $s.userId = '12345'
        $conn = @{ AuthKey = (New-TgRandomBytes 256); Salt = [long]-5; TimeOffset = 7 }
        Set-TgDcEntry 4 $conn $true
        $script:TG_SESSION = $null
        $r = Get-TgSession
        $r.dcId | Should -Be 4
        $r.userId | Should -Be '12345'
        $e = Get-TgDcEntry 4
        $e.salt | Should -Be '-5'
        $e.authorized | Should -BeTrue
        (ConvertTo-TgHex ([Convert]::FromBase64String($e.authKey))) | Should -Be (ConvertTo-TgHex $conn.AuthKey)
    }
    It 'restricts the session file to the current user (Windows ACL)' -Skip:(-not (Test-DlWindows)) {
        $s = Get-TgSession; Save-TgSession
        $acl = Get-Acl -LiteralPath (Get-TgSessionPath)
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        @($acl.Access | Where-Object { $_.IdentityReference.Value -ne $me }).Count | Should -Be 0
    }
    It 'removes the session' {
        [void](Get-TgSession); Save-TgSession
        Remove-TgSession
        (Test-Path (Get-TgSessionPath)) | Should -BeFalse
    }
    It 'tolerates a corrupt session file' {
        Set-Content -LiteralPath (Get-TgSessionPath) -Value '{ not json'
        $s = Get-TgSession 3>$null
        $s.userId | Should -Be 0
    }
    It 'lets env vars override configured credentials' {
        try {
            $env:TG_API_ID = '999'; $env:TG_API_HASH = 'envhash'
            Set-TgCredentials -ApiId '1' -ApiHash 'cfg'
            $script:TG_API_ID | Should -Be '999'
            $script:TG_API_HASH | Should -Be 'envhash'
        } finally { Remove-Item Env:\TG_API_ID, Env:\TG_API_HASH -ErrorAction SilentlyContinue }
    }
    It 'fails with a helpful message when api_id / api_hash are missing' {
        Remove-Item Env:\TG_API_ID, Env:\TG_API_HASH -ErrorAction SilentlyContinue
        Set-TgCredentials -ApiId '' -ApiHash ''
        { Assert-TgCredentials } | Should -Throw '*my.telegram.org*'
        { Send-TgLoginCode -Phone '+27821234567' } | Should -Throw '*api_id*'
        { Complete-TgLogin -Code '12345' } | Should -Throw '*api_id*'
    }
}

Describe 'dlrom Telegram CLI' {
    BeforeEach {
        $script:TG_SESSION = $null
        Remove-Item -LiteralPath (Join-Path $script:TG_DATA_DIR 'session.json') -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\TG_API_ID, Env:\TG_API_HASH, Env:\TG_2FA_PASSWORD -ErrorAction SilentlyContinue
        Set-DlromConfig ([pscustomobject]@{ telegramApiId = ''; telegramApiHash = '' })
        Mock Write-Host { }
    }
    It 'reports not logged in (exit 2) without needing credentials' {
        Invoke-DlromTelegram -Status | Should -Be 2
    }
    It 'fails cleanly (exit 1) on login without credentials' {
        Invoke-DlromTelegram -Login -Phone '+27821234567' | Should -Be 1
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*api_id*' }
    }
    It 'reads api_id / api_hash from config' {
        Set-DlromConfig ([pscustomobject]@{ telegramApiId = 12345; telegramApiHash = 'abc' })
        Initialize-DlromTelegram
        $script:TG_API_ID | Should -Be '12345'
        Test-TgCredentials | Should -BeTrue
    }
    It 'step 1 stores the code request and exits 3' {
        Set-DlromConfig ([pscustomobject]@{ telegramApiId = 12345; telegramApiHash = 'abc' })
        Mock Send-TgLoginCode { return @{ Phone = '27821234567'; DeliveryType = 'App'; CodeLength = 5; LoggedIn = $false } }
        Invoke-DlromTelegram -Login -Phone '+27821234567' | Should -Be 3
    }
    It 'step 2 reports password_needed (exit 3) and logs in (exit 0)' {
        Set-DlromConfig ([pscustomobject]@{ telegramApiId = 12345; telegramApiHash = 'abc' })
        Mock Complete-TgLogin { return @{ LoggedIn = $false; PasswordNeeded = $true; User = $null } }
        Invoke-DlromTelegram -Login -Code '12345' | Should -Be 3
        Mock Complete-TgLogin { return @{ LoggedIn = $true; PasswordNeeded = $false; User = @{ id = 1; first_name = 'A'; last_name = ''; username = 'a' } } }
        Invoke-DlromTelegram -Login -Code '12345' -Password 'x' | Should -Be 0
    }
    It 'uses TG_2FA_PASSWORD when --password is absent' {
        Set-DlromConfig ([pscustomobject]@{ telegramApiId = 12345; telegramApiHash = 'abc' })
        $env:TG_2FA_PASSWORD = 'envpw'
        try {
            Mock Complete-TgLogin { return @{ LoggedIn = $true; PasswordNeeded = $false; User = $null } }
            Invoke-DlromTelegram -Login -Code '1' | Should -Be 0
            Should -Invoke Complete-TgLogin -ParameterFilter { $Password -eq 'envpw' }
        } finally { Remove-Item Env:\TG_2FA_PASSWORD -ErrorAction SilentlyContinue }
    }
    It 'refuses to prompt when not interactive' {
        Set-DlromConfig ([pscustomobject]@{ telegramApiId = 12345; telegramApiHash = 'abc' })
        Mock Test-DlromInteractive { return $false }
        Invoke-DlromTelegram -Login | Should -Be 1
    }
    It 'logout deletes the local session even offline' {
        $s = Get-TgSession; Save-TgSession
        Invoke-DlromTelegram -Logout | Should -Be 0
        (Test-Path (Get-TgSessionPath)) | Should -BeFalse
    }
}
