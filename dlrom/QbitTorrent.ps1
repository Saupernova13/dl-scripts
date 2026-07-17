# QbitTorrent.ps1
# qBittorrent WebUI client for dlrom's PS2 torrent fallback. Adds a large
# multi-file archive .torrent, marks every file except the one the user asked for
# as "do not download", starts it, waits for that single file to complete, then
# (only if this run added the torrent) removes the torrent entry while keeping the
# downloaded file on disk. No seeding is left running.
#
# Confirmed against qBittorrent 5.1.2 / WebAPI 2.11.4:
#   - add returns "Ok." (not the hash); the v1 infohash we compute matches the
#     hash qBittorrent assigns, and a per-run tag is a reliable fallback lookup.
#   - a torrent's file "name" includes the root folder and matches the index path
#     built by ps2_torrent.py, so on disk the file is savepath\<name-as-path>.
#
# Add-ROM sets $script:QBIT_BASE (and optional creds) before calling in.
# Write-Log, ConvertTo-ResponseText, Format-* come from Logging.ps1.

$script:QBIT_BASE    = $null
$script:QBIT_SESSION = $null

function Get-QbitPortFromIni {
    $ini = Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini'
    if (-not (Test-Path $ini)) { return $null }
    foreach ($line in Get-Content $ini -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*WebUI\\Port\s*=\s*(\d+)') { return [int]$Matches[1] }
    }
    return $null
}

# Base URL from an explicit config value, else the WebUI port in qBittorrent.ini,
# else the 8075 default this machine uses.
function Resolve-QbitBase {
    param([string]$CfgHost)
    if ($CfgHost) { return ([string]$CfgHost).TrimEnd('/') }
    $port = Get-QbitPortFromIni
    if (-not $port) { $port = 8075 }
    return "http://127.0.0.1:$port"
}

function Initialize-Qbit {
    param([string]$Base, [string]$User = '', [string]$Pass = '')
    $script:QBIT_BASE    = $Base
    $script:QBIT_SESSION = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    # WebUI\LocalHostAuth is usually off, so a localhost client needs no login.
    # Only attempt a login when credentials are actually configured.
    if ($User) {
        try {
            Invoke-WebRequest -Uri "$Base/api/v2/auth/login" -Method POST `
                -Body @{ username = $User; password = $Pass } `
                -WebSession $script:QBIT_SESSION -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null
        } catch {
            Write-Log "qBittorrent login failed (continuing unauthenticated): $($_.Exception.Message)" 'DEBUG'
        }
    }
}

function Invoke-QbitApi {
    param([string]$Path, [string]$Method = 'GET', $Body = $null, [string]$ContentType = $null, [int]$TimeoutSec = 30)
    $params = @{ Uri = "$($script:QBIT_BASE)$Path"; Method = $Method; WebSession = $script:QBIT_SESSION;
                 UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $params.Body = $Body }
    if ($ContentType)    { $params.ContentType = $ContentType }
    return Invoke-WebRequest @params
}

function ConvertFrom-QbitJson {
    param($Response)
    return (ConvertTo-ResponseText $Response.Content | ConvertFrom-Json)
}

function Test-QbitRunning {
    try { return ((Invoke-QbitApi -Path '/api/v2/app/version' -TimeoutSec 5).StatusCode -eq 200) }
    catch { return $false }
}

# Build and POST a multipart add for the .torrent, stopped, tagged, keeping its
# root folder. Sends both 'stopped' (5.x) and 'paused' (4.x) so it never auto-starts.
function Add-QbitTorrentFile {
    param([string]$TorrentPath, [string]$SavePath, [string]$Tag)

    $bytes    = [System.IO.File]::ReadAllBytes($TorrentPath)
    $fileName = [System.IO.Path]::GetFileName($TorrentPath)
    $boundary = [System.Guid]::NewGuid().ToString()
    $LF       = "`r`n"
    $ms       = New-Object System.IO.MemoryStream
    $w        = New-Object System.IO.StreamWriter($ms)
    $w.NewLine = $LF

    $w.WriteLine("--$boundary")
    $w.WriteLine("Content-Disposition: form-data; name=`"torrents`"; filename=`"$fileName`"")
    $w.WriteLine("Content-Type: application/x-bittorrent")
    $w.WriteLine()
    $w.Flush()
    $ms.Write($bytes, 0, $bytes.Length)
    $w.WriteLine()

    foreach ($kv in @(@('savepath', $SavePath), @('stopped', 'true'), @('paused', 'true'),
                      @('tags', $Tag), @('root_folder', 'true'))) {
        $w.WriteLine("--$boundary")
        $w.WriteLine("Content-Disposition: form-data; name=`"$($kv[0])`"")
        $w.WriteLine()
        $w.WriteLine($kv[1])
    }
    $w.WriteLine("--$boundary--")
    $w.Flush()
    $body = $ms.ToArray()
    $w.Close(); $ms.Close()

    Invoke-QbitApi -Path '/api/v2/torrents/add' -Method POST -Body $body `
        -ContentType "multipart/form-data; boundary=$boundary" -TimeoutSec 60 | Out-Null
}

# Return the hash of a torrent already present with the given infohash, or ''.
function Get-QbitExistingHash {
    param([string]$InfoHash)
    if (-not $InfoHash) { return '' }
    try {
        $list = @(ConvertFrom-QbitJson (Invoke-QbitApi -Path "/api/v2/torrents/info?hashes=$InfoHash"))
        if ($list.Count -ge 1 -and $list[0].hash) { return [string]$list[0].hash }
    } catch { }
    return ''
}

# Wait for an added torrent to register; resolve its hash by our unique tag, with
# the computed infohash as a secondary lookup.
function Wait-QbitHash {
    param([string]$Tag, [string]$InfoHash = '', [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $list = @(ConvertFrom-QbitJson (Invoke-QbitApi -Path "/api/v2/torrents/info?tag=$Tag"))
            if ($list.Count -ge 1 -and $list[0].hash) { return [string]$list[0].hash }
        } catch { }
        $h = Get-QbitExistingHash -InfoHash $InfoHash
        if ($h) { return $h }
        Start-Sleep -Milliseconds 500
    }
    return ''
}

function Get-QbitFiles {
    param([string]$Hash)
    return @(ConvertFrom-QbitJson (Invoke-QbitApi -Path "/api/v2/torrents/files?hash=$Hash"))
}

# Locate the target file's qBittorrent index by exact path match (fall back to the
# index precomputed from the .torrent).
function Resolve-QbitFileIndex {
    param($Files, [string]$FilePathInTorrent, [int]$FallbackIndex = -1)
    $norm = ($FilePathInTorrent -replace '\\', '/')
    for ($k = 0; $k -lt $Files.Count; $k++) {
        $idx  = if ($null -ne $Files[$k].index) { [int]$Files[$k].index } else { $k }
        $name = ([string]$Files[$k].name -replace '\\', '/')
        if ($name -eq $norm) { return $idx }
    }
    return $FallbackIndex
}

# Everything to "do not download" (0), then the one target file to normal (1).
function Set-QbitSingleFile {
    param([string]$Hash, [int]$FileCount, [int]$TargetIndex)
    $allIds = (0..($FileCount - 1)) -join '|'
    Invoke-QbitApi -Path '/api/v2/torrents/filePrio' -Method POST `
        -Body @{ hash = $Hash; id = $allIds; priority = 0 } -TimeoutSec 60 | Out-Null
    Invoke-QbitApi -Path '/api/v2/torrents/filePrio' -Method POST `
        -Body @{ hash = $Hash; id = "$TargetIndex"; priority = 1 } -TimeoutSec 30 | Out-Null
}

function Start-QbitTorrent {
    param([string]$Hash)
    foreach ($ep in @('/api/v2/torrents/start', '/api/v2/torrents/resume')) {
        try { Invoke-QbitApi -Path $ep -Method POST -Body @{ hashes = $Hash } | Out-Null; return } catch { }
    }
}

# Poll the target file to 100%, printing a heartbeat. Returns the on-disk path.
function Wait-QbitFile {
    param([string]$Hash, [string]$FilePathInTorrent, [string]$SavePath,
          [int]$TimeoutSec = 14400, [int]$PollSec = 3)

    $norm       = ($FilePathInTorrent -replace '\\', '/')
    $onDisk     = Join-Path $SavePath ($norm -replace '/', '\')
    $deadline   = (Get-Date).AddSeconds($TimeoutSec)
    $shortLabel = Format-ShortLabel ([System.IO.Path]::GetFileName($norm))

    while ((Get-Date) -lt $deadline) {
        $prog = 0.0; $size = 0
        try {
            $files = Get-QbitFiles -Hash $Hash
            $tf = $files | Where-Object { ([string]$_.name -replace '\\','/') -eq $norm } | Select-Object -First 1
            if ($tf) { $prog = [double]$tf.progress; $size = [long]$tf.size }
        } catch { }

        $speed = 0; $state = ''
        try {
            $info = @(ConvertFrom-QbitJson (Invoke-QbitApi -Path "/api/v2/torrents/info?hashes=$Hash"))
            if ($info.Count -ge 1) { $speed = [long]$info[0].dlspeed; $state = [string]$info[0].state }
        } catch { }

        $pct  = [int]($prog * 100)
        $done = [long]($prog * $size)
        Write-ProgressLine -Percent $pct -Line ("  [qbit] {0,3}%  {1}/{2}  {3}  {4}" -f `
            $pct, (Format-Bytes $done), (Format-Bytes $size), (Format-Speed $speed), $shortLabel)

        if ($prog -ge 1.0 -and (Test-Path -LiteralPath $onDisk)) {
            Stop-ProgressLine
            return $onDisk
        }
        if ($state -eq 'error' -or $state -eq 'missingFiles') {
            Write-Host ""
            throw "qBittorrent reported state '$state' for the target file."
        }
        Start-Sleep -Seconds $PollSec
    }
    Write-Host ""
    throw "Timed out after ${TimeoutSec}s waiting for '$norm'."
}

# Remove a torrent entry, keeping downloaded files on disk (no seeding left behind).
function Remove-QbitTorrent {
    param([string]$Hash)
    try {
        Invoke-QbitApi -Path '/api/v2/torrents/delete' -Method POST `
            -Body @{ hashes = $Hash; deleteFiles = 'false' } | Out-Null
    } catch {
        Write-Log "Could not remove torrent entry $Hash from qBittorrent: $($_.Exception.Message)" 'WARN'
    }
}

# End-to-end selective download of one file from a multi-file torrent.
# Returns the on-disk path of the completed file, or throws.
function Invoke-QbitSelectiveDownload {
    param(
        [Parameter(Mandatory)][string]$TorrentPath,
        [Parameter(Mandatory)][string]$SavePath,
        [Parameter(Mandatory)][string]$FilePathInTorrent,
        [int]$FileIndex = -1,
        [string]$InfoHash = '',
        [int]$TimeoutSec = 14400
    )

    if (-not (Test-Path $SavePath)) { New-Item -ItemType Directory -Path $SavePath -Force | Out-Null }

    $hash    = Get-QbitExistingHash -InfoHash $InfoHash
    $weAdded = $false
    if ($hash) {
        Write-Log "Torrent already present in qBittorrent (hash $hash); reusing it." 'DEBUG'
    } else {
        $tag = 'dlrom-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        Write-Log "Adding torrent to qBittorrent (stopped, tag $tag)..." 'DEBUG'
        Add-QbitTorrentFile -TorrentPath $TorrentPath -SavePath $SavePath -Tag $tag
        $weAdded = $true
        $hash = Wait-QbitHash -Tag $tag -InfoHash $InfoHash -TimeoutSec 30
        if (-not $hash) { throw "qBittorrent did not register the added torrent." }
    }

    $files = Get-QbitFiles -Hash $hash
    if ($files.Count -eq 0) { throw "qBittorrent returned no file list for $hash." }

    $targetIdx = Resolve-QbitFileIndex -Files $files -FilePathInTorrent $FilePathInTorrent -FallbackIndex $FileIndex
    if ($targetIdx -lt 0) { throw "Could not locate '$FilePathInTorrent' in the torrent." }

    Write-Log "Selecting file #$targetIdx, deselecting the other $($files.Count - 1)..." 'DEBUG'
    Set-QbitSingleFile -Hash $hash -FileCount $files.Count -TargetIndex $targetIdx
    Start-QbitTorrent -Hash $hash

    try {
        $onDisk = Wait-QbitFile -Hash $hash -FilePathInTorrent $FilePathInTorrent -SavePath $SavePath -TimeoutSec $TimeoutSec
    } finally {
        # Per configuration: stop seeding and drop the torrent entry, but only if we
        # added it this run (never touch a torrent the user already had). The file
        # stays on disk (deleteFiles=false).
        if ($weAdded) { Remove-QbitTorrent -Hash $hash }
    }
    return $onDisk
}
