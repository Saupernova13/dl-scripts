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

# Flags on EVERY transfer: a stalled connection fails (and --retry retries it) instead of
# hanging forever. Fewer than 1 KB/s for 60 s counts as stalled.
$script:DLTV_CURL_COMMON = @('-s', '-S', '-L', '--fail', '--retry', '5', '--retry-delay', '3',
                             '--connect-timeout', '20', '--speed-limit', '1024', '--speed-time', '60')

# One argument as CommandLineToArgvW wants it. PS 5.1 has no ProcessStartInfo.ArgumentList, so
# the Arguments string is built by hand. URLs carrying & and ? need nothing: curl is started
# directly, not through a shell.
function ConvertTo-DltvArgument {
    param([string]$Arg)
    if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
    $s = $Arg -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return ('"' + $s + '"')
}

# Current length of a file another process may hold open. On Windows a directory-entry size
# (Get-ChildItem, and FileInfo even after Refresh) goes stale while the writer keeps the file
# open - a download read 382 MB when it was really 1.9 GB. A handle opened with FileShare
# ReadWrite asks the file itself, so it is live.
function Get-DltvFileLength {
    param([string]$Path)
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                  ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try { return [long]$fs.Length } finally { $fs.Dispose() }
    } catch {
        $fi = New-Object System.IO.FileInfo $Path
        $fi.Refresh()
        if ($fi.Exists) { return [long]$fi.Length }
        return 0L
    }
}

# Run curl as a child process and wait for it, calling -OnTick with the output file's live size
# about every -TickMs. -MaxBytes > 0 kills curl once the file passes it. No console handle is
# inherited: stdin/stdout/stderr are all redirected, stderr is kept for the error message.
function Invoke-DltvCurl {
    param(
        [Parameter(Mandatory)][string[]]$CurlArgs,
        [string]$OutFile,
        [long]$MaxBytes = 0,
        [scriptblock]$OnTick,
        [int]$TickMs = 2000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = Get-DlCurlPath
    $psi.Arguments              = (($CurlArgs | ForEach-Object { ConvertTo-DltvArgument $_ }) -join ' ')
    $psi.CreateNoWindow         = $true
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $capped = $false
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.WaitForExit(250)) {
        if ($OutFile -and $clock.ElapsedMilliseconds -ge $TickMs) {
            $clock.Restart()
            $size = Get-DltvFileLength $OutFile
            if ($MaxBytes -gt 0 -and $size -gt $MaxBytes) {
                try { $proc.Kill() } catch { }
                $capped = $true
                break
            }
            if ($OnTick) { & $OnTick $size }
        }
    }
    $proc.WaitForExit()
    [void]$outTask.Wait(2000)
    $errText = ''
    if ($errTask.Wait(2000)) { $errText = $errTask.Result }
    $code = $proc.ExitCode
    $proc.Dispose()
    return [PSCustomObject]@{ ExitCode = $code; Error = $errText.Trim(); Capped = $capped }
}

# Download one URL to a file. -Resume continues a partial file (-C -), which is what makes a
# re-run of a large .mp4 cheap. -Range "start-end" fetches just that byte range. Returns $true
# on success; a failure is logged, not thrown, so the caller decides whether it is fatal. Throws
# only when -MaxBytes is passed and the file outgrows it (the partial file is deleted).
function Invoke-DltvCurlDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$BaseUrl,
        [switch]$Resume,
        [string]$Range,
        [long]$MaxBytes = 0,
        [scriptblock]$OnTick
    )
    $base = Get-KissKHBaseUrl $BaseUrl
    $curlArgs = @($script:DLTV_CURL_COMMON)
    if ($Resume) { $curlArgs += @('-C', '-') }
    if ($Range)  { $curlArgs += @('-r', $Range) }
    $curlArgs += @('-A', $script:KISSKH_USER_AGENT, '-e', "$base/", '-o', $OutFile, $Url)

    $r = Invoke-DltvCurl -CurlArgs $curlArgs -OutFile $OutFile -MaxBytes $MaxBytes -OnTick $OnTick
    if ($r.Capped) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        throw "download passed the $(Format-DltvSize $MaxBytes) per-episode cap (kisskhMaxEpisodeGB); aborted"
    }
    if ($r.ExitCode -ne 0) {
        Write-Log "curl exit $($r.ExitCode) downloading $OutFile $($r.Error)" 'DEBUG'
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

# "<len>[@<offset>]" of EXT-X-BYTERANGE. A missing offset continues from -PrevEnd, the end of
# the previous range of the same URI (0 when there is none).
function ConvertFrom-DltvHlsByteRange {
    param([string]$Text, [long]$PrevEnd = 0)
    $parts = $Text.Trim().Trim('"').Split('@')
    $len = [long]$parts[0]
    $start = $PrevEnd
    if ($parts.Count -gt 1 -and $parts[1]) { $start = [long]$parts[1] }
    return [PSCustomObject]@{ Start = $start; Length = $len; End = ($start + $len - 1) }
}

# Media playlist -> @{ Map = <init segment URL or $null>; Segments = @({ Uri; Sequence; Key; Range }) }
# where Key is $null (clear) or @{ Uri; IvText } for METHOD=AES-128, and Range is $null (the
# whole URI) or @{ Start; Length; End } from EXT-X-BYTERANGE. A key applies to every segment
# after it until the next EXT-X-KEY. Ignoring BYTERANGE makes every segment download the whole
# file the ranges are cut from.
function Read-DltvHlsMediaPlaylist {
    param([string]$Text, [string]$BaseUri)
    $seq = 0L
    $key = $null
    $map = $null
    $range = $null
    $segments = @()
    $lastEnd = @{}      # uri -> end offset (exclusive) of its previous range
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#EXT-X-MEDIA-SEQUENCE:')) {
            $seq = [long]$line.Substring('#EXT-X-MEDIA-SEQUENCE:'.Length).Trim()
        } elseif ($line.StartsWith('#EXT-X-BYTERANGE:')) {
            $range = $line.Substring('#EXT-X-BYTERANGE:'.Length).Trim()
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
            $uri = Resolve-DltvHlsUri $BaseUri $line
            $r = $null
            if ($range) {
                $prev = 0L
                if ($lastEnd.ContainsKey($uri)) { $prev = [long]$lastEnd[$uri] }
                $r = ConvertFrom-DltvHlsByteRange -Text $range -PrevEnd $prev
                $lastEnd[$uri] = $r.End + 1
                $range = $null      # a BYTERANGE applies to the one segment after it
            }
            $segments += [PSCustomObject]@{ Uri = $uri; Sequence = $seq; Key = $key; Range = $r }
            $seq++
        }
    }
    return [PSCustomObject]@{ Map = $map; Segments = @($segments) }
}

# When every segment is a byte range of ONE URI, contiguous from 0, unencrypted and with no init
# segment, the playlist is just one file cut into pieces: return that URI (download it whole,
# resumably) and the file's length from the last range. Otherwise $null.
function Get-DltvHlsSingleFile {
    param($Playlist)
    $segs = @($Playlist.Segments)
    if ($segs.Count -eq 0 -or $Playlist.Map) { return $null }
    $uri = $segs[0].Uri
    $expect = 0L
    foreach ($s in $segs) {
        if ($s.Uri -ne $uri -or $s.Key -or -not $s.Range) { return $null }
        if ($s.Range.Start -ne $expect) { return $null }
        $expect = $s.Range.End + 1
    }
    return [PSCustomObject]@{ Uri = $uri; Length = $expect }
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

# "start-end" for curl -r, or $null.
function Get-DltvCurlRange {
    param($Range)
    if (-not $Range) { return $null }
    return ('{0}-{1}' -f $Range.Start, $Range.End)
}

# Fetch a small URL (a key, or an AES segment) into memory via a temp file. In-memory is for
# those only: a plain segment goes through Copy-DltvUrlToStream so it is never held whole.
function Get-DltvUrlBytes {
    param([string]$Url, [string]$BaseUrl, $Range)
    $tmp = Join-Path (Get-DlTempDir) ("dltv-seg-" + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if (-not (Invoke-DltvCurlDownload -Url $Url -OutFile $tmp -BaseUrl $BaseUrl -Range (Get-DltvCurlRange $Range))) {
            throw "could not fetch $Url"
        }
        return ,([System.IO.File]::ReadAllBytes($tmp))
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Fetch a URL (optionally one byte range) and append it to an open stream, without holding it
# in memory.
function Copy-DltvUrlToStream {
    param([string]$Url, [string]$BaseUrl, $Range, [System.IO.Stream]$Stream)
    $tmp = Join-Path (Get-DlTempDir) ("dltv-seg-" + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if (-not (Invoke-DltvCurlDownload -Url $Url -OutFile $tmp -BaseUrl $BaseUrl -Range (Get-DltvCurlRange $Range))) {
            throw "could not fetch $Url"
        }
        $in = [System.IO.File]::OpenRead($tmp)
        try { $in.CopyTo($Stream) } finally { $in.Dispose() }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ffmpeg remux "<Stem>.ts" -> "<Stem>.mp4". Returns the final path; keeps the .ts when ffmpeg is
# missing or fails.
function Convert-DltvTsToMp4 {
    param([string]$Ts, [string]$Stem)
    $ffmpeg = Get-Command 'ffmpeg' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ffmpeg) {
        Write-Log "ffmpeg not found on PATH; keeping the HLS download as .ts" 'INFO'
        return $Ts
    }
    $mp4 = "$Stem.mp4"
    $mp4Part = "$Stem.mp4.part"
    $ffOut = & $ffmpeg.Source -y -loglevel error -i $Ts -c copy -f mp4 $mp4Part 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $mp4Part)) {
        Remove-Item -LiteralPath $mp4Part -Force -ErrorAction SilentlyContinue
        Write-Log "ffmpeg remux failed, keeping .ts: $(($ffOut | Out-String).Trim())" 'WARN'
        return $Ts
    }
    Move-Item -LiteralPath $mp4Part -Destination $mp4 -Force
    Remove-Item -LiteralPath $Ts -Force -ErrorAction SilentlyContinue
    return $mp4
}

# The media playlist behind an HLS URL (resolving a master to its best variant).
# Returns @{ Url; Playlist }.
function Get-DltvHlsMedia {
    param([string]$Url, [string]$BaseUrl)
    $text = Invoke-KissKHGet -Url $Url -BaseUrl $BaseUrl
    $variant = Get-DltvHlsBestVariant -Text $text -BaseUri $Url
    if ($variant) {
        Write-Log "HLS master playlist: using highest bandwidth variant" 'DEBUG'
        $Url  = $variant
        $text = Invoke-KissKHGet -Url $Url -BaseUrl $BaseUrl
    }
    return [PSCustomObject]@{ Url = $Url; Playlist = (Read-DltvHlsMediaPlaylist -Text $text -BaseUri $Url) }
}

# Download an HLS stream to "<Stem>.mp4" (ffmpeg present) or "<Stem>.ts" and return that path.
# A playlist that is one file cut into byte ranges is downloaded once, as a plain resumable
# transfer; anything else goes segment by segment, streamed to disk. -MaxBytes > 0 aborts the
# episode once its output passes that size.
function Save-DltvHlsStream {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Stem,
        [string]$BaseUrl,
        [long]$MaxBytes = 0,
        [scriptblock]$OnTick
    )

    $media = Get-DltvHlsMedia -Url $Url -BaseUrl $BaseUrl
    $playlist = $media.Playlist
    $segs = @($playlist.Segments)
    if ($segs.Count -eq 0) { throw "HLS playlist has no segments" }

    $tsPart = "$Stem.ts.part"
    $single = Get-DltvHlsSingleFile $playlist
    if ($single) {
        Write-Log "HLS playlist is one file in $($segs.Count) byte ranges; downloading it once" 'DEBUG'
        if (-not (Invoke-DltvCurlDownload -Url $single.Uri -OutFile $tsPart -BaseUrl $BaseUrl -Resume -MaxBytes $MaxBytes -OnTick $OnTick)) {
            throw "video download failed"
        }
    } else {
        $keyCache = @{}
        $fs = [System.IO.File]::Create($tsPart)
        try {
            if ($playlist.Map) {
                $init = Get-DltvUrlBytes -Url $playlist.Map -BaseUrl $BaseUrl
                $fs.Write($init, 0, $init.Length)
            }
            $n = 0
            foreach ($s in $segs) {
                if ($s.Key) {
                    $data = Get-DltvUrlBytes -Url $s.Uri -BaseUrl $BaseUrl -Range $s.Range
                    if (-not $keyCache.ContainsKey($s.Key.Uri)) {
                        $keyCache[$s.Key.Uri] = Get-DltvUrlBytes -Url $s.Key.Uri -BaseUrl $BaseUrl
                    }
                    $iv = Get-DltvHlsIvBytes -IvText $s.Key.IvText -Sequence $s.Sequence
                    $data = ConvertFrom-DltvHlsSegment -Data $data -Key $keyCache[$s.Key.Uri] -Iv $iv
                    $fs.Write($data, 0, $data.Length)
                } else {
                    Copy-DltvUrlToStream -Url $s.Uri -BaseUrl $BaseUrl -Range $s.Range -Stream $fs
                }
                $n++
                if ($MaxBytes -gt 0 -and $fs.Length -gt $MaxBytes) {
                    throw "download passed the $(Format-DltvSize $MaxBytes) per-episode cap (kisskhMaxEpisodeGB); aborted"
                }
                if ($OnTick) { & $OnTick $fs.Length }
                if ($n % 50 -eq 0) { Write-Log "  segments $n/$($segs.Count)" 'DEBUG' }
            }
        } catch {
            $fs.Dispose()
            Remove-Item -LiteralPath $tsPart -Force -ErrorAction SilentlyContinue
            throw
        }
        $fs.Dispose()
    }

    $ts = "$Stem.ts"
    Move-Item -LiteralPath $tsPart -Destination $ts -Force
    return (Convert-DltvTsToMp4 -Ts $ts -Stem $Stem)
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
    $maxBytes = [long]([double]$Job.maxEpisodeGB * 1GB)

    if ($url -match '\.m3u8(\?|#|$)') {
        $final = Save-DltvHlsStream -Url $url -Stem $stem -BaseUrl $Job.baseUrl -MaxBytes $maxBytes
    } else {
        $final = "$stem.mp4"
        if (-not (Invoke-DltvCurlDownload -Url $url -OutFile "$final.part" -BaseUrl $Job.baseUrl -Resume -MaxBytes $maxBytes)) {
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
