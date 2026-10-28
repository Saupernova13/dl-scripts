# Download side of dltv's KissKH path: the curl file fetch, a native HLS downloader, subtitle
# saving and the worker's episode loop. No yt-dlp, no browser; curl does the transfers and
# ffmpeg is used, when present, only to remux HLS output to .mp4.
#
# Needs KissKH.ps1, Jobs.ps1 and lib/Platform.ps1 loaded first, and Write-Log from the caller.

# --- Naming -------------------------------------------------------------------

# Strip the characters Windows forbids in a file name, then trailing dots and spaces.
function Get-DltvSafeName {
    param([string]$Name)
    $n = ($Name -replace '[\\/:*?"<>|]', '')
    $n = ($n -replace '\s+', ' ').Trim().Trim('.').Trim()
    if (-not $n) { return 'KissKH' }
    return $n
}

# "<Title> S01E07" - the shared stem of an episode's video and subtitle files.
function Get-DltvEpisodeStem {
    param([string]$Title, [int]$Number)
    return ('{0} S01E{1:D2}' -f (Get-DltvSafeName $Title), $Number)
}

# --- curl ---------------------------------------------------------------------

# Download one URL to a file. -Resume continues a partial file (-C -), which is what makes a
# re-run of a large .mp4 cheap. Returns $true on success; a failure is logged, not thrown,
# so the caller decides whether it is fatal.
function Invoke-DltvCurlDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$BaseUrl,
        [switch]$Resume
    )
    $base = Get-KissKHBaseUrl $BaseUrl
    $curl = Get-DlCurlPath
    $curlArgs = @('-s', '-S', '-L', '--fail', '--retry', '5', '--retry-delay', '3')
    if ($Resume) { $curlArgs += @('-C', '-') }
    $curlArgs += @('-A', $script:KISSKH_USER_AGENT, '-e', "$base/", '-o', $OutFile, $Url)

    $out = & $curl @curlArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "curl exit $LASTEXITCODE downloading $OutFile $(($out | Out-String).Trim())" 'DEBUG'
        return $false
    }
    return $true
}

function Format-DltvSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return "$Bytes B"
}

# --- HLS ----------------------------------------------------------------------

function Resolve-DltvHlsUri {
    param([string]$Base, [string]$Ref)
    return (New-Object System.Uri ((New-Object System.Uri $Base), $Ref)).AbsoluteUri
}

# KEY=VALUE,KEY="VALUE" attribute list -> hashtable (keys uppercased, quotes stripped).
function ConvertFrom-DltvHlsAttributes {
    param([string]$Text)
    $attrs = @{}
    foreach ($m in [regex]::Matches($Text, '([A-Za-z0-9-]+)=("[^"]*"|[^,]*)')) {
        $attrs[$m.Groups[1].Value.ToUpperInvariant()] = $m.Groups[2].Value.Trim('"')
    }
    return $attrs
}

# Master playlist -> URL of the highest-BANDWIDTH variant, or $null when the text is already a
# media playlist.
function Get-DltvHlsBestVariant {
    param([string]$Text, [string]$BaseUri)
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() })
    $best = $null
    $bestBw = -1L
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].StartsWith('#EXT-X-STREAM-INF:')) { continue }
        $attrs = ConvertFrom-DltvHlsAttributes $lines[$i].Substring('#EXT-X-STREAM-INF:'.Length)
        $bw = 0L
        if ($attrs.ContainsKey('BANDWIDTH')) { [void][long]::TryParse($attrs['BANDWIDTH'], [ref]$bw) }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -and -not $lines[$j].StartsWith('#')) {
                if ($bw -gt $bestBw) { $bestBw = $bw; $best = Resolve-DltvHlsUri $BaseUri $lines[$j] }
                break
            }
        }
    }
    return $best
}

# 16-byte IV: the playlist's 0x... value, left-padded; else the media sequence number as a
# big-endian 128-bit value.
function Get-DltvHlsIvBytes {
    param([string]$IvText, [long]$Sequence)
    $iv = New-Object byte[] 16
    if ($IvText) {
        $hex = ($IvText -replace '^0[xX]', '')
        if ($hex.Length % 2) { $hex = "0$hex" }
        $hex = $hex.PadLeft(32, '0')
        if ($hex.Length -gt 32) { $hex = $hex.Substring($hex.Length - 32) }
        for ($i = 0; $i -lt 16; $i++) { $iv[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
        return ,$iv
    }
    for ($i = 15; $i -ge 8; $i--) {
        $iv[$i] = [byte]($Sequence -band 0xFF)
        $Sequence = $Sequence -shr 8
    }
    return ,$iv
}

# Media playlist -> @{ Map = <init segment URL or $null>; Segments = @({ Uri; Sequence; Key }) }
# where Key is $null (clear) or @{ Uri; IvText } for METHOD=AES-128. A key applies to every
# segment after it until the next EXT-X-KEY.
function Read-DltvHlsMediaPlaylist {
    param([string]$Text, [string]$BaseUri)
    $seq = 0L
    $key = $null
    $map = $null
    $segments = @()
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#EXT-X-MEDIA-SEQUENCE:')) {
            $seq = [long]$line.Substring('#EXT-X-MEDIA-SEQUENCE:'.Length).Trim()
        } elseif ($line.StartsWith('#EXT-X-KEY:')) {
            $a = ConvertFrom-DltvHlsAttributes $line.Substring('#EXT-X-KEY:'.Length)
            if ($a['METHOD'] -eq 'AES-128' -and $a.ContainsKey('URI')) {
                $iv = $null
                if ($a.ContainsKey('IV')) { $iv = $a['IV'] }
                $key = [PSCustomObject]@{ Uri = (Resolve-DltvHlsUri $BaseUri $a['URI']); IvText = $iv }
            } elseif ($a['METHOD'] -eq 'NONE') {
                $key = $null
            } else {
                throw "Unsupported HLS encryption: $($a['METHOD'])"
            }
        } elseif ($line.StartsWith('#EXT-X-MAP:')) {
            $a = ConvertFrom-DltvHlsAttributes $line.Substring('#EXT-X-MAP:'.Length)
            if ($a.ContainsKey('URI')) { $map = Resolve-DltvHlsUri $BaseUri $a['URI'] }
        } elseif (-not $line.StartsWith('#')) {
            $segments += [PSCustomObject]@{ Uri = (Resolve-DltvHlsUri $BaseUri $line); Sequence = $seq; Key = $key }
            $seq++
        }
    }
    return [PSCustomObject]@{ Map = $map; Segments = @($segments) }
}

function ConvertFrom-DltvHlsSegment {
    param([byte[]]$Data, [byte[]]$Key, [byte[]]$Iv)
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $Key
        $aes.IV  = $Iv
        return ,($aes.CreateDecryptor().TransformFinalBlock($Data, 0, $Data.Length))
    } finally { $aes.Dispose() }
}

# Fetch a small URL (a segment or key) into memory via a temp file.
function Get-DltvUrlBytes {
    param([string]$Url, [string]$BaseUrl)
    $tmp = Join-Path (Get-DlTempDir) ("dltv-seg-" + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if (-not (Invoke-DltvCurlDownload -Url $Url -OutFile $tmp -BaseUrl $BaseUrl)) {
            throw "could not fetch $Url"
        }
        return ,([System.IO.File]::ReadAllBytes($tmp))
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Download an HLS stream to "<Stem>.mp4" (ffmpeg present) or "<Stem>.ts" and return that path.
function Save-DltvHlsStream {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Stem, [string]$BaseUrl)

    $text = Invoke-KissKHGet -Url $Url -BaseUrl $BaseUrl
    $variant = Get-DltvHlsBestVariant -Text $text -BaseUri $Url
    if ($variant) {
        Write-Log "HLS master playlist: using highest bandwidth variant" 'DEBUG'
        $Url  = $variant
        $text = Invoke-KissKHGet -Url $Url -BaseUrl $BaseUrl
    }
    $playlist = Read-DltvHlsMediaPlaylist -Text $text -BaseUri $Url
    $segs = @($playlist.Segments)
    if ($segs.Count -eq 0) { throw "HLS playlist has no segments" }

    $tsPart = "$Stem.ts.part"
    $keyCache = @{}
    $fs = [System.IO.File]::Create($tsPart)
    try {
        if ($playlist.Map) {
            $init = Get-DltvUrlBytes -Url $playlist.Map -BaseUrl $BaseUrl
            $fs.Write($init, 0, $init.Length)
        }
        $n = 0
        foreach ($s in $segs) {
            $data = Get-DltvUrlBytes -Url $s.Uri -BaseUrl $BaseUrl
            if ($s.Key) {
                if (-not $keyCache.ContainsKey($s.Key.Uri)) {
                    $keyCache[$s.Key.Uri] = Get-DltvUrlBytes -Url $s.Key.Uri -BaseUrl $BaseUrl
                }
                $iv = Get-DltvHlsIvBytes -IvText $s.Key.IvText -Sequence $s.Sequence
                $data = ConvertFrom-DltvHlsSegment -Data $data -Key $keyCache[$s.Key.Uri] -Iv $iv
            }
            $fs.Write($data, 0, $data.Length)
            $n++
            if ($n % 50 -eq 0) { Write-Log "  segments $n/$($segs.Count)" 'DEBUG' }
        }
    } catch {
        $fs.Dispose()
        throw
    }
    $fs.Dispose()

    $ts = "$Stem.ts"
    Move-Item -LiteralPath $tsPart -Destination $ts -Force

    $ffmpeg = Get-Command 'ffmpeg' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ffmpeg) {
        Write-Log "ffmpeg not found on PATH; keeping the HLS download as .ts" 'INFO'
        return $ts
    }
    $mp4 = "$Stem.mp4"
    $mp4Part = "$Stem.mp4.part"
    $ffOut = & $ffmpeg.Source -y -loglevel error -i $ts -c copy -f mp4 $mp4Part 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $mp4Part)) {
        Remove-Item -LiteralPath $mp4Part -Force -ErrorAction SilentlyContinue
        Write-Log "ffmpeg remux failed, keeping .ts: $(($ffOut | Out-String).Trim())" 'WARN'
        return $ts
    }
    Move-Item -LiteralPath $mp4Part -Destination $mp4 -Force
    Remove-Item -LiteralPath $ts -Force -ErrorAction SilentlyContinue
    return $mp4
}

# --- Subtitles ----------------------------------------------------------------

# Fetch, decrypt and write "<Stem>.<lang>.srt" for each wanted language. Failures are WARNs:
# a missing subtitle never costs the episode.
function Save-DltvSubtitles {
    param([long]$EpisodeId, [string]$Stem, [string[]]$Langs, [string]$BaseUrl)
    $tracks = @(Get-KissKHSubtitleTracks -EpisodeId $EpisodeId -BaseUrl $BaseUrl)
    $saved = 0
    foreach ($lang in $Langs) {
        $track = $tracks | Where-Object { $_.land -and ([string]$_.land).ToLowerInvariant() -eq $lang.ToLowerInvariant() } |
                 Select-Object -First 1
        if (-not $track) { Write-Log "  no '$lang' subtitle track" 'INFO'; continue }
        try {
            $raw = Invoke-KissKHGet -Url ([string]$track.src) -BaseUrl $BaseUrl
            $srt = ConvertFrom-KissKHSubtitle -Text $raw -Extension (Get-KissKHSubtitleExtension ([string]$track.src))
            $safeLang = ([string]$track.land) -replace '[^A-Za-z0-9_-]', ''
            [System.IO.File]::WriteAllText("$Stem.$safeLang.srt", $srt, (New-Object System.Text.UTF8Encoding($false)))
            $saved++
        } catch {
            Write-Log "  subtitle '$lang' failed: $($_.Exception.Message)" 'WARN'
        }
    }
    return $saved
}

# --- Worker -------------------------------------------------------------------

# Download one episode into $Folder. Returns 'ok', 'unreleased'; throws on failure.
function Save-DltvEpisode {
    param([PSCustomObject]$Job, $Episode, [string]$Folder)
    $stem = Join-Path $Folder (Get-DltvEpisodeStem -Title $Job.title -Number $Episode.number)

    $url = Get-KissKHStreamUrl -EpisodeId $Episode.id -BaseUrl $Job.baseUrl
    if (-not $url) { return 'unreleased' }

    if ($url -match '\.m3u8(\?|#|$)') {
        $final = Save-DltvHlsStream -Url $url -Stem $stem -BaseUrl $Job.baseUrl
    } else {
        $final = "$stem.mp4"
        if (-not (Invoke-DltvCurlDownload -Url $url -OutFile "$final.part" -BaseUrl $Job.baseUrl -Resume)) {
            throw "video download failed"
        }
        Move-Item -LiteralPath "$final.part" -Destination $final -Force
    }
    Write-Log "  saved $(Split-Path -Leaf $final) ($(Format-DltvSize (Get-Item -LiteralPath $final).Length))" 'SUCCESS'

    try { [void](Save-DltvSubtitles -EpisodeId $Episode.id -Stem $stem -Langs @($Job.subLangs) -BaseUrl $Job.baseUrl) }
    catch { Write-Log "  subtitles failed: $($_.Exception.Message)" 'WARN' }
    return 'ok'
}

# The detached worker: ascending episodes, resume by skipping finished files, one failure
# never stops the rest. Ends 'failed' only when zero episodes succeeded.
function Invoke-DltvKissKHWorker {
    param([PSCustomObject]$Job)

    $Job.pid = $PID
    $Job.startedAt = (Get-DltvUtcStamp)
    Update-DltvJob -Job $Job -Status $script:DLTV_JOB_RUNNING -Message 'downloading'

    $folder = [string]$Job.destination
    try { New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null }
    catch {
        Write-Log "Cannot create $folder : $($_.Exception.Message)" 'ERROR'
        Complete-DltvJob -Job $Job -Message "cannot create destination: $folder"
        return
    }

    $failed = @()
    $unreleased = @()
    $episodes = @($Job.episodes | Sort-Object number)
    Write-Log "Downloading $($episodes.Count) episodes of $($Job.title) to $folder" 'INFO'

    foreach ($ep in $episodes) {
        $tag = 'E{0:D2}' -f $ep.number
        $stem = Join-Path $folder (Get-DltvEpisodeStem -Title $Job.title -Number $ep.number)
        if ((Test-Path -LiteralPath "$stem.mp4") -or (Test-Path -LiteralPath "$stem.ts")) {
            Write-Log "$tag already downloaded, skipping" 'INFO'
            $Job.done++
            Update-DltvJob -Job $Job -Current ''
            continue
        }

        Update-DltvJob -Job $Job -Current ([string]$ep.number)
        Write-Log "$tag ($($Job.done + $failed.Count + $unreleased.Count + 1)/$($episodes.Count))" 'INFO'
        try {
            $result = Save-DltvEpisode -Job $Job -Episode $ep -Folder $folder
            if ($result -eq 'unreleased') {
                Write-Log "$tag is not released yet, skipping" 'WARN'
                $unreleased += $tag
            } else {
                $Job.done++
            }
        } catch {
            Write-Log "$tag failed: $($_.Exception.Message)" 'ERROR'
            $failed += $tag
            $Job.failed = @($failed)
        }
        Update-DltvJob -Job $Job -Current ''
    }

    $msg = "$($Job.done)/$($episodes.Count) episodes"
    if ($failed.Count)     { $msg += "; failed: $($failed -join ', ')" }
    if ($unreleased.Count) { $msg += "; not released: $($unreleased -join ', ')" }
    Complete-DltvJob -Job $Job -Message $msg
    $lvl = if ($Job.status -eq $script:DLTV_JOB_COMPLETED) { 'SUCCESS' } else { 'ERROR' }
    Write-Log "Job $($Job.status): $msg" $lvl
}
