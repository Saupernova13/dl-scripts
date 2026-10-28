# KissKH client for dltv: search, drama and episode lookup, the signed stream request, subtitle
# fetch and decryption, and title matching. Pure PowerShell + .NET + curl, no third-party tools.
#
# Needs lib/Platform.ps1 loaded first (DriveResolver.ps1 does that). Write-Log comes from the
# caller.

# --- Site constants -----------------------------------------------------------
# Every value the kkey signing depends on lives here and nowhere else. They come from kisskh's
# common.js and its player chunk, and must be refreshed if the site bumps appVer (a stale set
# makes the stream and subtitle routes answer with an empty or error body).
$script:KISSKH_APP_VER      = '2.8.10'
$script:KISSKH_PLATFORM_VER = '4830201'
$script:KISSKH_APP_NAME     = 'kisskh'
$script:KISSKH_MARKER       = 'mg3c3b04ba'
$script:KISSKH_GUID_VIDEO   = '62f176f3bb1b5b8e70e39932ad34a0c7'
$script:KISSKH_GUID_SUB     = 'VgV52sWhwvBSf8BsM3BRY9weWiiCbtGp'
# AES-128 key and IV words of the kkey cipher, as the signed int32 words the site's JS uses.
$script:KISSKH_KKEY_KEY_WORDS = @(0x4f6bdaa3L, -0x61d07350L, 0x7f5e722dL, -0x61210cecL)
$script:KISSKH_KKEY_IV_WORDS  = @(0x01504af3L, 0x56e619cfL, 0x2e42bba6L, -0x73c08f07L)

$script:KISSKH_DEFAULT_BASE = 'https://kisskh.co'
$script:KISSKH_USER_AGENT   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'

# Subtitle cipher sets, picked by the file extension of the track's src. Anything that is not
# .srt (plain), .txt or .txt1 uses the third set.
$script:KISSKH_SUB_KEYS = @{
    'txt'     = @{ Key = '8056483646328763'; Iv = '6852612370185273' }
    'txt1'    = @{ Key = 'AmSmZVcH93UQUezi'; Iv = 'ReBKWW8cqdjPEnF6' }
    'default' = @{ Key = 'sWODXX04QRTkHdlZ'; Iv = '8pwhapJeC4hrS9hO' }
}

# --- HTTP ---------------------------------------------------------------------

# 'curl.exe' does not exist on Linux, where the binary is plain 'curl' - dltv is one of the
# commands reachable on the Deck, so the name has to be resolved rather than assumed.
function Get-DlCurlPath {
    foreach ($name in @('curl.exe', 'curl')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    throw "curl was not found on PATH."
}

function Get-KissKHBaseUrl {
    param([string]$BaseUrl)
    if (-not $BaseUrl) { $BaseUrl = $script:KISSKH_DEFAULT_BASE }
    return $BaseUrl.TrimEnd('/')
}

# GET a URL and return the body as text. The body goes to a temp file and is decoded as UTF-8
# by us: native-command output is decoded with the console code page, which garbles non-ASCII
# titles, and the stream route answers with Content-Type image/png although the body is JSON
# (Invoke-WebRequest hands that back as byte[] on 5.1). curl sidesteps both.
function Invoke-KissKHGet {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$BaseUrl,
        [int]$TimeoutSec = 30
    )
    $base = Get-KissKHBaseUrl $BaseUrl
    $curl = Get-DlCurlPath
    $tmp  = Join-Path (Get-DlTempDir) ("dltv-get-" + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        & $curl -s -S -L --fail --retry 2 --retry-delay 2 --max-time $TimeoutSec `
            --connect-timeout 20 --speed-limit 1024 --speed-time 60 `
            -A $script:KISSKH_USER_AGENT -e "$base/" -o $tmp $Url 2>$null
        if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE for $Url" }
        if (-not (Test-Path -LiteralPath $tmp)) { throw "no response body for $Url" }
        return [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# --- kkey ---------------------------------------------------------------------

# Wrap a value to a signed int32, as JS's `| 0` does.
function ConvertTo-Int32Wrap {
    param([long]$Value)
    $v = $Value -band 0xFFFFFFFFL
    if ($v -ge 0x80000000L) { $v -= 0x100000000L }
    return $v
}

# JS: h = (h << 5) - h + charCode. ONLY the shift truncates to int32; the subtraction and
# addition do not, so the result exceeds int32 range - hence [long].
function Get-KissKHHash {
    param([Parameter(Mandatory)][string]$Text)
    [long]$h = 0
    foreach ($c in $Text.ToCharArray()) {
        $shl = ConvertTo-Int32Wrap ((ConvertTo-Int32Wrap $h) -shl 5)
        $h = $shl - $h + [int]$c
    }
    return $h
}

# Big-endian bytes of signed int32 words.
function ConvertTo-KissKHWordBytes {
    param([long[]]$Words)
    $out = New-Object byte[] ($Words.Count * 4)
    for ($i = 0; $i -lt $Words.Count; $i++) {
        $w = $Words[$i] -band 0xFFFFFFFFL
        $out[$i * 4]     = [byte](($w -shr 24) -band 0xFF)
        $out[$i * 4 + 1] = [byte](($w -shr 16) -band 0xFF)
        $out[$i * 4 + 2] = [byte](($w -shr 8)  -band 0xFF)
        $out[$i * 4 + 3] = [byte]($w -band 0xFF)
    }
    return ,$out
}

# The plaintext that gets encrypted: the hash of the pipe-joined parts, inserted at index 1.
function Get-KissKHKkeyPlaintext {
    param([Parameter(Mandatory)][long]$EpisodeId, [Parameter(Mandatory)][string]$Guid)
    $app = $script:KISSKH_APP_NAME
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.AddRange([string[]]@('', "$EpisodeId", '', $script:KISSKH_MARKER, $script:KISSKH_APP_VER,
                                $Guid, $script:KISSKH_PLATFORM_VER, $app, $app, $app, $app, $app, $app, '00', ''))
    $parts.Insert(1, [string](Get-KissKHHash ($parts -join '|')))
    return ($parts -join '|')
}

# AES-128-CBC/PKCS7 over the ASCII plaintext, returned as UPPERCASE hex.
function New-KissKHKkey {
    param([Parameter(Mandatory)][long]$EpisodeId, [Parameter(Mandatory)][string]$Guid)
    $plain = [System.Text.Encoding]::GetEncoding(28591).GetBytes((Get-KissKHKkeyPlaintext -EpisodeId $EpisodeId -Guid $Guid))
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = ConvertTo-KissKHWordBytes $script:KISSKH_KKEY_KEY_WORDS
        $aes.IV  = ConvertTo-KissKHWordBytes $script:KISSKH_KKEY_IV_WORDS
        $cipher = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    } finally { $aes.Dispose() }
    return (($cipher | ForEach-Object { $_.ToString('X2') }) -join '')
}

function New-KissKHVideoKkey { param([long]$EpisodeId) return (New-KissKHKkey -EpisodeId $EpisodeId -Guid $script:KISSKH_GUID_VIDEO) }
function New-KissKHSubKkey   { param([long]$EpisodeId) return (New-KissKHKkey -EpisodeId $EpisodeId -Guid $script:KISSKH_GUID_SUB) }

# --- API ----------------------------------------------------------------------

# JSON array text -> array of its elements. `@($text | ConvertFrom-Json)` is NOT enough on
# PS 5.1: ConvertFrom-Json emits the array as ONE pipeline object, so @() nests it and a
# 50-element result reads as Count 1. foreach enumerates the elements properly, and gives an
# empty array for `[]`.
function ConvertFrom-DltvJsonList {
    param([string]$Text)
    $items = @()
    if (-not $Text -or -not $Text.Trim()) { return $items }
    foreach ($x in ($Text | ConvertFrom-Json)) { $items += $x }
    return $items
}

function Search-KissKHDrama {
    param([Parameter(Mandatory)][string]$Query, [string]$BaseUrl)
    $base = Get-KissKHBaseUrl $BaseUrl
    $enc  = [System.Uri]::EscapeDataString($Query)
    $text = Invoke-KissKHGet -Url "$base/api/DramaList/Search?q=$enc&type=0" -BaseUrl $base
    return (ConvertFrom-DltvJsonList $text)
}

function Get-KissKHDrama {
    param([Parameter(Mandatory)][long]$Id, [string]$BaseUrl)
    $base = Get-KissKHBaseUrl $BaseUrl
    $text = Invoke-KissKHGet -Url "$base/api/DramaList/Drama/${Id}?isq=false" -BaseUrl $base
    return ($text | ConvertFrom-Json)
}

# Pull the video URL out of a stream response body. $null means the episode is not released
# yet (empty Video, or a tickcounter placeholder).
function Get-KissKHVideoUrlFromJson {
    param([string]$Text)
    if (-not $Text) { return $null }
    $obj = $Text | ConvertFrom-Json
    $url = [string]$obj.Video
    if (-not $url -or $url -match 'tickcounter') { return $null }
    return $url
}

# The signed, IP-locked stream URL. Fetch it just-in-time per episode.
function Get-KissKHStreamUrl {
    param([Parameter(Mandatory)][long]$EpisodeId, [string]$BaseUrl)
    $base = Get-KissKHBaseUrl $BaseUrl
    $kkey = New-KissKHVideoKkey $EpisodeId
    $text = Invoke-KissKHGet -Url "$base/api/DramaList/Episode/$EpisodeId.png?err=false&ts=null&time=null&kkey=$kkey" -BaseUrl $base
    return (Get-KissKHVideoUrlFromJson $text)
}

function Get-KissKHSubtitleTracks {
    param([Parameter(Mandatory)][long]$EpisodeId, [string]$BaseUrl)
    $base = Get-KissKHBaseUrl $BaseUrl
    $kkey = New-KissKHSubKkey $EpisodeId
    $text = Invoke-KissKHGet -Url "$base/api/Sub/${EpisodeId}?kkey=$kkey" -BaseUrl $base
    return (ConvertFrom-DltvJsonList $text)
}

# --- Subtitles ----------------------------------------------------------------

# Extension of a subtitle src, ignoring any query or fragment, lowercased, without the dot.
function Get-KissKHSubtitleExtension {
    param([string]$Src)
    $path = ($Src -split '[?#]')[0]
    $name = ($path -split '[\\/]')[-1]
    $dot  = $name.LastIndexOf('.')
    if ($dot -lt 0) { return '' }
    return $name.Substring($dot + 1).ToLowerInvariant()
}

function Get-KissKHSubtitleCipher {
    param([string]$Extension)
    if ($Extension -eq 'srt') { return $null }
    if ($script:KISSKH_SUB_KEYS.ContainsKey($Extension)) { return $script:KISSKH_SUB_KEYS[$Extension] }
    return $script:KISSKH_SUB_KEYS['default']
}

# Decrypt one base64 cue text. Throws if it is not valid base64 or the padding is wrong.
function ConvertFrom-KissKHCipherText {
    param([string]$Text, [string]$Key, [string]$Iv)
    $cipher = [System.Convert]::FromBase64String($Text.Trim())
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = [System.Text.Encoding]::UTF8.GetBytes($Key)
        $aes.IV  = [System.Text.Encoding]::UTF8.GetBytes($Iv)
        $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)
    } finally { $aes.Dispose() }
    return ([System.Text.Encoding]::UTF8.GetString($plain)).TrimEnd([char]0)
}

# One cue's text lines -> decrypted text. Whole text with newlines removed first, then line
# by line, then the original untouched (the site does the same with try/catch).
function ConvertFrom-KissKHCueText {
    param([string[]]$Lines, [string]$Key, [string]$Iv)
    try { return (ConvertFrom-KissKHCipherText -Text (($Lines -join '')) -Key $Key -Iv $Iv) } catch { }
    try {
        $out = foreach ($l in $Lines) { ConvertFrom-KissKHCipherText -Text $l -Key $Key -Iv $Iv }
        return ($out -join "`n")
    } catch { }
    return ($Lines -join "`n")
}

# Turn a subtitle file body into plain SRT text. -Extension is the src extension; .srt is
# returned as is.
function ConvertFrom-KissKHSubtitle {
    param([string]$Text, [string]$Extension)
    $cipher = Get-KissKHSubtitleCipher $Extension
    if (-not $cipher) { return $Text }

    $norm = $Text.TrimStart([char]0xFEFF) -replace "`r`n?", "`n"
    $blocks = $norm -split "`n{2,}"
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($block in $blocks) {
        if (-not $block.Trim()) { continue }
        $lines = $block -split "`n"
        $timeIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '-->') { $timeIdx = $i; break }
        }
        if ($timeIdx -lt 0 -or $timeIdx -eq ($lines.Count - 1)) { $out.Add($block); continue }
        $head = $lines[0..$timeIdx]
        $body = @($lines[($timeIdx + 1)..($lines.Count - 1)] | Where-Object { $_.Trim() })
        $dec  = ConvertFrom-KissKHCueText -Lines $body -Key $cipher.Key -Iv $cipher.Iv
        $dec  = ($dec -replace "`r`n?", "`n")
        $out.Add((($head -join "`n") + "`n" + $dec))
    }
    return (($out -join "`n`n") + "`n")
}

# --- Matching -----------------------------------------------------------------

# Lowercase, drop a trailing "(2023)", punctuation to spaces, collapse whitespace.
function ConvertTo-DltvTitleKey {
    param([string]$Title)
    if (-not $Title) { return '' }
    $t = $Title.ToLowerInvariant()
    $t = $t -replace '\s*\(\d{4}\)\s*$', ''
    $t = $t -replace '[^\p{L}\p{N}]+', ' '
    return $t.Trim()
}

# Matches ranked best first. Strict: exact normalized equality only. Non-strict ranks exact >
# title starts with the query (on a word boundary) > every query token present as a word in
# the title; nothing else counts. The sort is stable on API order, so ties keep it.
function Get-DltvKissKHMatches {
    param([string]$Query, [object[]]$Results, [switch]$Strict)
    $q = ConvertTo-DltvTitleKey $Query
    if (-not $q) { return @() }
    $qTokens = @($q -split ' ')

    $ranked = @()
    $order = 0
    foreach ($r in @($Results)) {
        $order++
        if (-not $r -or -not $r.title) { continue }
        $t = ConvertTo-DltvTitleKey ([string]$r.title)
        $rank = 0
        if ($t -eq $q) { $rank = 3 }
        elseif (-not $Strict) {
            if ($t.StartsWith("$q ")) { $rank = 2 }
            else {
                $tTokens = @($t -split ' ')
                $missing = @($qTokens | Where-Object { $tTokens -notcontains $_ })
                if ($missing.Count -eq 0) { $rank = 1 }
            }
        }
        if ($rank -gt 0) { $ranked += [PSCustomObject]@{ Rank = $rank; Order = $order; Item = $r } }
    }
    return @($ranked | Sort-Object @{ Expression = 'Rank'; Descending = $true }, @{ Expression = 'Order'; Descending = $false } |
             ForEach-Object { $_.Item })
}

function Find-DltvKissKHMatch {
    param([string]$Query, [object[]]$Results, [switch]$Strict)
    $m = @(Get-DltvKissKHMatches -Query $Query -Results $Results -Strict:$Strict)
    if ($m.Count -eq 0) { return $null }
    return $m[0]
}

# --- Episodes -----------------------------------------------------------------

# '3' | '1-4' | '5-' -> @{ From; To }. Empty means every episode ($null). Throws on junk.
function ConvertFrom-DltvEpisodeRange {
    param([string]$Range)
    if (-not $Range -or -not $Range.Trim()) { return $null }
    $r = $Range.Trim()
    if ($r -match '^(\d+)$')        { return [PSCustomObject]@{ From = [int]$Matches[1]; To = [int]$Matches[1] } }
    if ($r -match '^(\d+)-(\d+)$')  {
        $from = [int]$Matches[1]; $to = [int]$Matches[2]
        if ($to -lt $from) { throw "Invalid episode range '$Range': end is before start." }
        return [PSCustomObject]@{ From = $from; To = $to }
    }
    if ($r -match '^(\d+)-$')       { return [PSCustomObject]@{ From = [int]$Matches[1]; To = [int]::MaxValue } }
    throw "Invalid episode range '$Range'. Use 3, 1-4 or 5-."
}

# Integer episodes of a drama, ascending, filtered by -Range. Fractional numbers (16.1) are
# recaps and specials and are skipped; Skipped says how many.
function Select-KissKHEpisodes {
    param([Parameter(Mandatory)]$Drama, [string]$Range)
    $r = ConvertFrom-DltvEpisodeRange $Range
    $keep = @()
    $skipped = 0
    foreach ($e in @($Drama.episodes)) {
        $n = [double]$e.number
        if ($n -ne [Math]::Floor($n)) { $skipped++; continue }
        $num = [int]$n
        if ($r -and ($num -lt $r.From -or $num -gt $r.To)) { continue }
        $keep += [PSCustomObject]@{ Id = [long]$e.id; Number = $num }
    }
    return [PSCustomObject]@{
        Episodes = @($keep | Sort-Object Number)
        Skipped  = $skipped
    }
}

# --- Source selection ---------------------------------------------------------

# Should dltv try KissKH instead of the torrent it found? Returns the reason as a string, or
# $null to stay with TPB. -Torrents is the scored list, best first: the auto-selected pick is
# the first entry. The caller gates this on kisskhFallback and -Interactive.
function Test-DltvKissKHFallback {
    param([object[]]$Torrents, [int]$MinSeeders = 5)
    $list = @($Torrents)
    if ($list.Count -eq 0) { return 'TPB has no usable torrents' }
    $top = $list[0]
    if ([int]$top.Seeders -lt $MinSeeders) {
        return "TPB best has $($top.Seeders) seeds (< $MinSeeders)"
    }
    return $null
}
