# Telegram MTProto - cryptography.
#
# Everything is .NET BCL (SHA1/SHA256, AES-ECB under the IGE loop in TgNative, BigInteger).
# No third-party code. Nothing here touches the network or the schema, so each piece is unit
# tested against fixed vectors:
#   - AES-IGE, MTProto 2.0 msg_key / AES key derivation
#   - RSA_PAD (the scheme req_DH_params uses, core.telegram.org/mtproto/auth_key)
#   - pq factorisation, DH parameter checks
#   - the 2FA SRP proof (core.telegram.org/api/srp)

# The production RSA key Telegram's DCs advertise (Telegram Desktop's kPublicRSAKeys; its
# fingerprint 0xd09d1d85de64fd85 is what resPQ lists). PKCS#1 RSAPublicKey, base64 DER.
$script:TG_RSA_PUBLIC_KEYS = @(
    'MIIBCgKCAQEA6LszBcC1LGzyr992NzE0ieY+BSaOW622Aa9Bd4ZHLl+TuFQ4lo4g5nKaMBwK/BIb9xUfg0Q29/2mgIR6Zr9krM7HjuIcCzFvDtr+L0GQjae9H0pRB2OO62cECs5HKhT5DZ98K33vmWiLowc621dQuwKWSQKjWf50XYFw42h21P2KXUGyp2y/+aEyZ+uVgLLQbRA1dEjSDZ2iGRy12Mk5gpYc397aYp438fsJoHIgJ2lgMv5h7WY9t6N/byY9Nw9p21Og3AoXSL2q/2IJ1WRUhebgAdGVMlV1fkuOQoEzR7EdpqtQD9Cs5+bfo3Nhmcyvk5ftB0WkJ9z6bNZ7yxrP8wIDAQAB'
)

$script:TG_RNG = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$script:TG_PRIME_OK = @{}
# Telegram has used one fixed 2048-bit safe prime for DH and SRP for years; its SHA-256 is
# pinned here so the common case skips the (slow in PowerShell) primality test. Any other
# modulus still goes through Miller-Rabin.
$script:TG_KNOWN_PRIME_SHA256 = @('02f85e7687fc6f33ba678226a963b3c8a191b47c890cf30debe17c1d623b5af1')

# --- byte helpers ---------------------------------------------------------------

function Join-TgBytes {
    param([Parameter(ValueFromRemainingArguments)][object[]]$Parts)
    $ms = New-Object System.IO.MemoryStream
    foreach ($p in $Parts) {
        if ($null -eq $p) { continue }
        $b = [byte[]]$p
        $ms.Write($b, 0, $b.Length)
    }
    return ,$ms.ToArray()
}

function Get-TgSlice {
    param([byte[]]$Bytes, [int]$Offset, [int]$Count)
    $r = New-Object byte[] $Count
    [Array]::Copy($Bytes, $Offset, $r, 0, $Count)
    return ,$r
}

function New-TgRandomBytes {
    param([int]$Count)
    $b = New-Object byte[] $Count
    $script:TG_RNG.GetBytes($b)
    return ,$b
}

function Get-TgSha1 {
    param([Parameter(ValueFromRemainingArguments)][object[]]$Parts)
    $h = [System.Security.Cryptography.SHA1]::Create()
    try { return ,$h.ComputeHash([byte[]](Join-TgBytes @Parts)) } finally { $h.Dispose() }
}

function Get-TgSha256 {
    param([Parameter(ValueFromRemainingArguments)][object[]]$Parts)
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { return ,$h.ComputeHash([byte[]](Join-TgBytes @Parts)) } finally { $h.Dispose() }
}

function ConvertTo-TgHex {
    param([byte[]]$Bytes)
    return ([BitConverter]::ToString($Bytes).Replace('-', '').ToLowerInvariant())
}

function ConvertFrom-TgHex {
    param([string]$Hex)
    $Hex = $Hex -replace '\s', ''
    $b = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring(2 * $i, 2), 16) }
    return ,$b
}

function Compare-TgBytes {
    param([byte[]]$A, [byte[]]$B)
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function Invoke-TgXor {
    param([byte[]]$A, [byte[]]$B)
    $r = New-Object byte[] $A.Length
    for ($i = 0; $i -lt $A.Length; $i++) { $r[$i] = $A[$i] -bxor $B[$i] }
    return ,$r
}

# Big-endian bytes <-> BigInteger. Length 0 = minimal; otherwise left-padded.
function ConvertTo-TgBigInt { param([byte[]]$Bytes) return [DlTg.Bn]::FromBigEndian($Bytes) }
function ConvertFrom-TgBigInt {
    param([System.Numerics.BigInteger]$Value, [int]$Length = 0)
    return ,[DlTg.Bn]::ToBigEndian($Value, $Length)
}

# --- AES-IGE and the MTProto 2.0 key schedule -------------------------------------

function Protect-TgIge { param([byte[]]$Data, [byte[]]$Key, [byte[]]$Iv) return ,[DlTg.Ige]::Encrypt($Data, $Key, $Iv) }
function Unprotect-TgIge { param([byte[]]$Data, [byte[]]$Key, [byte[]]$Iv) return ,[DlTg.Ige]::Decrypt($Data, $Key, $Iv) }

# msg_key = bytes 8..23 of SHA256(auth_key[88+x .. 88+x+32] + plaintext_with_padding).
# x is 0 for client -> server and 8 for server -> client.
function Get-TgMsgKey {
    param([byte[]]$AuthKey, [byte[]]$Plain, [int]$X)
    $large = Get-TgSha256 (Get-TgSlice $AuthKey (88 + $X) 32) $Plain
    return ,(Get-TgSlice $large 8 16)
}

# AES key and IV for a message, derived from auth_key and msg_key.
function Get-TgAesKeyIv {
    param([byte[]]$AuthKey, [byte[]]$MsgKey, [int]$X)
    $a = Get-TgSha256 $MsgKey (Get-TgSlice $AuthKey $X 36)
    $b = Get-TgSha256 (Get-TgSlice $AuthKey (40 + $X) 36) $MsgKey
    return @{
        Key = (Join-TgBytes (Get-TgSlice $a 0 8) (Get-TgSlice $b 8 16) (Get-TgSlice $a 24 8))
        Iv  = (Join-TgBytes (Get-TgSlice $b 0 8) (Get-TgSlice $a 8 16) (Get-TgSlice $b 24 8))
    }
}

# --- RSA ------------------------------------------------------------------------------

# Minimal DER walk: a PKCS#1 RSAPublicKey is SEQUENCE { INTEGER n, INTEGER e }.
# Returns the tag, the offset of the value, its length and the offset just past it.
function Read-TgDerElement {
    param([byte[]]$Der, [int]$Pos, [int]$ExpectTag)
    if ($Der[$Pos] -ne $ExpectTag) { throw 'RSA key: unexpected DER tag' }
    $len = [int]$Der[$Pos + 1]
    $p = $Pos + 2
    if ($len -ge 0x80) {
        $count = $len -band 0x7F
        $len = 0
        for ($i = 0; $i -lt $count; $i++) { $len = ($len -shl 8) -bor $Der[$p]; $p++ }
    }
    return @{ Start = $p; Length = $len; Next = ($p + $len) }
}

function ConvertFrom-TgRsaDer {
    param([byte[]]$Der)
    $seq = Read-TgDerElement $Der 0 0x30
    $nEl = Read-TgDerElement $Der $seq.Start 0x02
    $eEl = Read-TgDerElement $Der $nEl.Next 0x02
    $n = Get-TgSlice $Der $nEl.Start $nEl.Length
    $e = Get-TgSlice $Der $eEl.Start $eEl.Length
    # Drop the sign byte DER adds to a high-bit modulus.
    $start = 0
    while ($start -lt $n.Length - 1 -and $n[$start] -eq 0) { $start++ }
    return @{ N = (Get-TgSlice $n $start ($n.Length - $start)); E = $e }
}

# Telegram's key fingerprint: low 64 bits (last 8 bytes, little endian) of
# SHA1(bytes(n) + bytes(e)) with both serialised as TL bytes.
function Get-TgRsaFingerprint {
    param([byte[]]$N, [byte[]]$E)
    $w = New-Object DlTg.TlWriter
    $w.WriteBytes($N); $w.WriteBytes($E)
    $sha = Get-TgSha1 $w.ToArray()
    return [BitConverter]::ToInt64($sha, 12)
}

# All built-in server keys: @{ Fingerprint = <long>; N = <byte[]>; E = <byte[]> }.
function Get-TgRsaKeys {
    $keys = @()
    foreach ($b64 in $script:TG_RSA_PUBLIC_KEYS) {
        $k = ConvertFrom-TgRsaDer ([Convert]::FromBase64String($b64))
        $keys += @{ Fingerprint = (Get-TgRsaFingerprint $k.N $k.E); N = $k.N; E = $k.E }
    }
    return ,@($keys)
}

# One RSA_PAD attempt with caller-supplied randomness (so tests are deterministic).
# Returns the 256-byte key_aes_encrypted block, or $null when it is not below the modulus
# (the caller retries with a fresh temp_key).
function New-TgRsaPadBlock {
    param([byte[]]$Data, [byte[]]$TempKey, [byte[]]$Padding, [byte[]]$Modulus)
    if ($Data.Length + $Padding.Length -ne 192) { throw 'RSA_PAD: data + padding must be 192 bytes' }
    $withPadding = Join-TgBytes $Data $Padding
    $reversed = [byte[]]$withPadding.Clone()
    [Array]::Reverse($reversed)
    $withHash = Join-TgBytes $reversed (Get-TgSha256 $TempKey $withPadding)
    $aesEnc = Protect-TgIge $withHash $TempKey (New-Object byte[] 32)
    $xored  = Invoke-TgXor $TempKey (Get-TgSha256 $aesEnc)
    $block  = Join-TgBytes $xored $aesEnc
    $num = ConvertTo-TgBigInt $block
    if ($num -ge (ConvertTo-TgBigInt $Modulus)) { return $null }
    return ,$block
}

# RSA_PAD + raw RSA ("textbook", no padding): encrypted_data for req_DH_params.
function Protect-TgRsaPad {
    param([byte[]]$Data, [hashtable]$Key)
    if ($Data.Length -gt 192) { throw 'RSA_PAD: data too long' }
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $pad = New-TgRandomBytes (192 - $Data.Length)
        $block = New-TgRsaPadBlock -Data $Data -TempKey (New-TgRandomBytes 32) -Padding $pad -Modulus $Key.N
        if ($block) {
            $m = ConvertTo-TgBigInt $block
            $c = [System.Numerics.BigInteger]::ModPow($m, (ConvertTo-TgBigInt $Key.E), (ConvertTo-TgBigInt $Key.N))
            return ,(ConvertFrom-TgBigInt $c 256)
        }
    }
    throw 'RSA_PAD: could not produce a block below the modulus'
}

# --- handshake arithmetic -----------------------------------------------------------------

# pq (big-endian bytes, up to 8) -> @{ P = byte[]; Q = byte[] } with P < Q.
function Get-TgPqFactors {
    param([byte[]]$Pq)
    if ($Pq.Length -gt 8) { throw 'pq longer than 8 bytes' }
    $n = [uint64](ConvertTo-TgBigInt $Pq)
    $f = [DlTg.Bn]::FactorPq($n)
    return @{
        P = (ConvertFrom-TgBigInt ([System.Numerics.BigInteger]$f[0]))
        Q = (ConvertFrom-TgBigInt ([System.Numerics.BigInteger]$f[1]))
    }
}

# Miller-Rabin with the first few prime bases: fine as a screen against a hostile or corrupted
# modulus, and cached per prime so the handshake and SRP do not pay for it twice.
function Test-TgPrime {
    param([System.Numerics.BigInteger]$N, [int]$Rounds = 6)
    if ($N -lt 2) { return $false }
    $small = 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37
    foreach ($s in $small) {
        if ($N -eq $s) { return $true }
        if (($N % $s) -eq 0) { return $false }
    }
    $d = $N - 1; $r = 0
    while ($d.IsEven) { $d = $d / 2; $r++ }
    foreach ($a in ($small | Select-Object -First $Rounds)) {
        $x = [System.Numerics.BigInteger]::ModPow($a, $d, $N)
        if ($x -eq 1 -or $x -eq ($N - 1)) { continue }
        $composite = $true
        for ($i = 1; $i -lt $r; $i++) {
            $x = ($x * $x) % $N
            if ($x -eq ($N - 1)) { $composite = $false; break }
        }
        if ($composite) { return $false }
    }
    return $true
}

# p must be a 2048-bit safe prime; the cache keys on the sha256 of its bytes.
function Test-TgSafePrime {
    param([byte[]]$P)
    $key = ConvertTo-TgHex (Get-TgSha256 $P)
    if ($script:TG_PRIME_OK.ContainsKey($key)) { return $script:TG_PRIME_OK[$key] }
    if ($script:TG_KNOWN_PRIME_SHA256 -contains $key) { return $true }
    $n = ConvertTo-TgBigInt $P
    $ok = ($P.Length -eq 256) -and ($P[0] -ge 0x80) -and (Test-TgPrime $n) -and (Test-TgPrime (($n - 1) / 2))
    $script:TG_PRIME_OK[$key] = $ok
    return $ok
}

# g must generate the prime-order subgroup of a safe prime p (core.telegram.org/api/srp).
function Test-TgDhGenerator {
    param([int]$G, [System.Numerics.BigInteger]$P)
    switch ($G) {
        2 { return (($P % 8) -eq 7) }
        3 { return (($P % 3) -eq 2) }
        4 { return $true }
        5 { $m = [int]($P % 5); return ($m -eq 1 -or $m -eq 4) }
        6 { $m = [int]($P % 24); return ($m -eq 19 -or $m -eq 23) }
        7 { $m = [int]($P % 7); return ($m -eq 3 -or $m -eq 5 -or $m -eq 6) }
        default { return $false }
    }
}

# 1 < x < p-1 and both x and p-x at least 2^(2048-64): the range Telegram requires of g_a, g_b.
function Test-TgDhRange {
    param([System.Numerics.BigInteger]$X, [System.Numerics.BigInteger]$P)
    $min = [System.Numerics.BigInteger]::Pow(2, 2048 - 64)
    return ($X -gt 1 -and $X -lt ($P - 1) -and $X -ge $min -and ($P - $X) -ge $min)
}

# --- 2FA SRP -------------------------------------------------------------------------------------

# SH(data, salt) = SHA256(salt | data | salt)
function Get-TgSrpSalted { param([byte[]]$Data, [byte[]]$Salt) return ,(Get-TgSha256 $Salt $Data $Salt) }

# x for passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow, as 32 bytes.
function Get-TgSrpPasswordHash {
    param([byte[]]$PasswordBytes, [byte[]]$Salt1, [byte[]]$Salt2, [int]$Iterations = 100000)
    $ph1 = Get-TgSrpSalted (Get-TgSrpSalted $PasswordBytes $Salt1) $Salt2
    $pbk = [DlTg.Bn]::Pbkdf2Sha512($ph1, $Salt1, $Iterations, 64)
    return ,(Get-TgSrpSalted $pbk $Salt2)
}

# Build inputCheckPasswordSRP. -Algo is the passwordKdfAlgo... object (salt1, salt2, g, p) from
# account.getPassword; -SrpB and -SrpId come from the same reply. -Secret (256 random bytes) exists
# so tests can pin the client's secret; leave it out in real use.
function New-TgSrpCheck {
    param(
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)]$Algo,
        [Parameter(Mandatory)][byte[]]$SrpB,
        [Parameter(Mandatory)]$SrpId,
        [byte[]]$Secret = $null,
        [int]$Iterations = 100000,
        [switch]$SkipPrimeCheck
    )
    $pBytes = [byte[]]$Algo.p
    $g = [int]$Algo.g
    $p = ConvertTo-TgBigInt $pBytes
    if (-not $SkipPrimeCheck) {
        if (-not (Test-TgSafePrime $pBytes)) { throw 'SRP: the server sent a modulus that is not a 2048-bit safe prime' }
    }
    if (-not (Test-TgDhGenerator $g $p)) { throw 'SRP: the server sent an invalid generator' }

    $bBig = ConvertTo-TgBigInt $SrpB
    if (-not (Test-TgDhRange $bBig $p)) { throw 'SRP: srp_B is out of range' }

    $xBytes = Get-TgSrpPasswordHash ([System.Text.Encoding]::UTF8.GetBytes($Password)) ([byte[]]$Algo.salt1) ([byte[]]$Algo.salt2) $Iterations
    $x   = ConvertTo-TgBigInt $xBytes
    $gBig = [System.Numerics.BigInteger]$g

    $pFor = ConvertFrom-TgBigInt $p 256
    $gFor = ConvertFrom-TgBigInt $gBig 256
    $bFor = ConvertFrom-TgBigInt $bBig 256
    $k    = ConvertTo-TgBigInt (Get-TgSha256 $pFor $gFor)
    $gx   = [System.Numerics.BigInteger]::ModPow($gBig, $x, $p)
    $kgx  = ($k * $gx) % $p

    while ($true) {
        $aBytes = if ($Secret) { $Secret } else { New-TgRandomBytes 256 }
        $a  = ConvertTo-TgBigInt $aBytes
        $gA = [System.Numerics.BigInteger]::ModPow($gBig, $a, $p)
        if (Test-TgDhRange $gA $p) {
            $aFor = ConvertFrom-TgBigInt $gA 256
            $u = ConvertTo-TgBigInt (Get-TgSha256 $aFor $bFor)
            if ($u -gt 0) { break }
        }
        if ($Secret) { throw 'SRP: the supplied client secret gives an unusable g_a' }
    }

    $t = ($bBig - $kgx) % $p
    if ($t -lt 0) { $t += $p }
    if (-not (Test-TgDhRange $t $p)) { throw 'SRP: derived value is out of range' }
    $s  = [System.Numerics.BigInteger]::ModPow($t, ($a + $u * $x), $p)
    $kk = Get-TgSha256 (ConvertFrom-TgBigInt $s 256)
    $m1 = Get-TgSha256 (Invoke-TgXor (Get-TgSha256 $pFor) (Get-TgSha256 $gFor)) `
                       (Get-TgSha256 ([byte[]]$Algo.salt1)) (Get-TgSha256 ([byte[]]$Algo.salt2)) `
                       $aFor $bFor $kk
    return [ordered]@{
        _      = 'inputCheckPasswordSRP'
        srp_id = [long]$SrpId
        A      = $aFor
        M1     = $m1
    }
}
