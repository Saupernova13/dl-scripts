# Download backends and the dispatcher that chooses between them. Order of preference:
# a running manager (Motrix, then AB Download Manager), then direct tiers
# (aria2c -> curl -> BITS -> Invoke-WebRequest). Falls through on failure.
#
# Add-ROM sets the script-scope values we read: MOTRIX_URL, AB_PORT, AB_TIMEOUT,
# AB_DOWNLOAD_DIR and DOWNLOADER. Backend ids, labels, HTTP_HEADERS and the partial-file
# suffixes come from Constants.ps1; progress rendering from Logging.ps1.

# Motrix speaks aria2's JSON-RPC. (RPC plumbing carried over from dlmotrix.)
function Invoke-MotrixRpc {
    param([string]$Method, [object[]]$Params = @())
    $body = @{ jsonrpc = '2.0'; id = '1'; method = $Method; params = $Params } | ConvertTo-Json -Depth 10
    $resp = Invoke-WebRequest -Uri $script:MOTRIX_URL -Method POST -Body $body -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
    $json = ConvertTo-ResponseText $resp.Content | ConvertFrom-Json
    if ($json.error) { throw "Motrix RPC error ($Method): $($json.error.message)" }
    return $json.result
}

function Test-MotrixRunning {
    try {
        $body = @{ jsonrpc = '2.0'; id = '1'; method = 'aria2.getVersion'; params = @() } | ConvertTo-Json -Depth 5
        $resp = Invoke-WebRequest -Uri $script:MOTRIX_URL -Method POST -Body $body `
            -ContentType 'application/json' -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $json = ConvertTo-ResponseText $resp.Content | ConvertFrom-Json
        return (-not $json.error -and $null -ne $json.result)
    } catch { return $false }
}

# AB Download Manager's local API (default port 15151): POST /ping -> "pong",
# POST /add { items:[...], options:{...} }. There's no status/completion endpoint, so
# we hand it a suggestedName and watch its download folder instead (Wait-AbFile).
function Get-AbBaseUrl {
    $port = if ($script:AB_PORT) { $script:AB_PORT } else { $script:DEFAULT_AB_PORT }
    return "http://$($script:LOOPBACK):$port"
}

function Test-AbRunning {
    try {
        $resp = Invoke-WebRequest -Uri "$(Get-AbBaseUrl)/ping" -Method POST -Body 'null' `
            -ContentType 'application/json' -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        return ((ConvertTo-ResponseText $resp.Content) -match '(?i)pong')
    } catch { return $false }
}

function Add-AbDownload {
    param([string]$Url, [string]$SuggestedName = $null, [string]$Referer = $null, [hashtable]$Headers = $null)
    $item = [ordered]@{
        link          = $Url
        downloadPage  = $Referer
        headers       = $Headers
        description   = $null
        suggestedName = $SuggestedName
        type          = 'http'
    }
    $body = @{ items = @($item); options = @{ silentAdd = $true; silentStart = $true } } | ConvertTo-Json -Depth 6
    Invoke-WebRequest -Uri "$(Get-AbBaseUrl)/add" -Method POST -Body $body `
        -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
}

# The direct, synchronous tiers in preference order - used both as the initial pick
# (no manager running) and as the fallback once Motrix/AB are out.
function Get-DirectDownloader {
    foreach ($name in @('aria2c.exe', 'aria2c')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $script:DL_ARIA2C }
    }
    if (Get-Command 'curl.exe' -ErrorAction SilentlyContinue)           { return $script:DL_CURL }
    if (Get-Command 'Start-BitsTransfer' -ErrorAction SilentlyContinue) { return $script:DL_BITS }
    return $script:DL_WEBCLIENT
}

# A running manager first, then the best direct tier.
function Find-Downloader {
    if (Test-MotrixRunning) { return $script:DL_MOTRIX }
    if (Test-AbRunning)     { return $script:DL_AB     }
    return (Get-DirectDownloader)
}

# When Motrix fails: prefer AB next, then the direct tiers.
function Get-FallbackDownloader {
    if (Test-AbRunning) { return $script:DL_AB }
    return Get-DirectDownloader
}

function Wait-MotrixDownload {
    param([string]$Gid, [string]$Label = "", [int]$PollMs = 2000)

    $fields     = @("status", "completedLength", "totalLength", "downloadSpeed", "files")
    $shortLabel = Format-ShortLabel $Label

    while ($true) {
        $status = Invoke-MotrixRpc 'aria2.tellStatus' @($Gid, $fields)
        # Throw rather than exit: the caller already treats a failed link as "try the next
        # one", and a worker must be allowed to mark its job failed on the way out.
        if (-not $status) { Stop-ProgressLine; throw "Lost contact with Motrix." }

        $state = $status.status
        $done  = [long]$status.completedLength
        $total = [long]$status.totalLength
        $speed = [long]$status.downloadSpeed
        $pct   = if ($total -gt 0) { [int](($done / $total) * 100) } else { 0 }
        Write-ProgressLine -Percent $pct -Line (Format-TransferLine -Percent $pct -Done $done `
            -Total $total -BytesPerSec $speed -Label $shortLabel)

        if ($state -eq 'complete') {
            Stop-ProgressLine
            Write-Log "Download complete." 'SUCCESS'
            $filePath = if ($status.files -and $status.files[0].path) { $status.files[0].path } else { "" }
            return $filePath
        }
        if ($state -eq 'error') {
            Stop-ProgressLine
            throw "Motrix reported a download error for GID $Gid."
        }

        Start-Sleep -Milliseconds $PollMs
    }
}

# Done = the named file is present, has no .part/.tmp sibling, and its size holds
# steady across two polls.
function Wait-AbFile {
    param([string]$Dir, [string]$Name, [int]$TimeoutSec = 1800, [string]$Label = "")
    $target     = Join-Path $Dir $Name
    $deadline   = (Get-Date).AddSeconds($TimeoutSec)
    $lastSize   = -1
    $stable     = 0
    $shortLabel = Format-ShortLabel $Label
    while ((Get-Date) -lt $deadline) {
        $partials = @(Get-ChildItem -LiteralPath $Dir -Filter "$Name*" -File -ErrorAction SilentlyContinue |
                      Where-Object { $script:PARTIAL_EXTS -contains $_.Extension.ToLower() })
        $exists = Test-Path -LiteralPath $target
        $size   = if ($exists) { (Get-Item -LiteralPath $target).Length } else { 0 }
        if ($exists -and $partials.Count -eq 0 -and $size -gt 0 -and $size -eq $lastSize) {
            $stable++
            if ($stable -ge 2) { Stop-ProgressLine; return $target }
        } else {
            $stable = 0
        }
        $lastSize = $size
        # AB reports no total, so there is no percentage to give -- bytes-so-far only.
        Write-ProgressLine -Line "  [AB] $(Format-Bytes $size)  $shortLabel"
        Start-Sleep -Seconds 2
    }
    Stop-ProgressLine
    return $null
}

function Invoke-MotrixDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    $gid = Invoke-MotrixRpc 'aria2.addUri' @(, @($Url))
    if (-not $gid) { throw "Motrix failed to queue the download." }
    Write-Log "GID: $gid" 'DEBUG'
    return Wait-MotrixDownload -Gid $gid -Label $Label -PollMs ([int]$cfg.pollIntervalMs)
}

function Invoke-Aria2cDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    Write-Log "Downloading via aria2c: $Label" 'DEBUG'
    $outDir  = [System.IO.Path]::GetDirectoryName($OutFile)
    $outName = [System.IO.Path]::GetFileName($OutFile)
    $proc = Start-Process 'aria2c' -ArgumentList @(
        "--dir=`"$outDir`"", "--out=`"$outName`"",
        "--console-log-level=warn", "--summary-interval=1",
        "--max-connection-per-server=4", "--split=4",
        "`"$Url`""
    ) -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "aria2c exited with code $($proc.ExitCode)" }
    return $OutFile
}

function Invoke-CurlDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    Write-Log "Downloading via curl: $Label" 'DEBUG'
    $proc = Start-Process 'curl.exe' -ArgumentList @(
        '-L', '--progress-bar', '--retry', '3', '--retry-delay', '2',
        '-o', "`"$OutFile`"", "`"$Url`""
    ) -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "curl.exe exited with code $($proc.ExitCode)" }
    return $OutFile
}

function Invoke-BitsDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    Write-Log "Downloading via BITS: $Label" 'DEBUG'
    $shortLabel = Format-ShortLabel $Label
    $job = Start-BitsTransfer -Source $Url -Destination $OutFile -Asynchronous
    try {
        while ($job.JobState -notin @('Transferred', 'Error', 'TransientError')) {
            $done   = $job.BytesTransferred
            $total  = $job.BytesTotal
            $pct = if ($total -gt 0) { [int]($done / $total * 100) } else { 0 }
            Write-ProgressLine -Percent $pct -Line (Format-TransferLine -Percent $pct -Done $done `
                -Total $total -Label $shortLabel)
            Start-Sleep -Seconds 1
        }
        Stop-ProgressLine
        if ($job.JobState -in @('Error', 'TransientError')) {
            $errMsg = $job.ErrorDescription
            Remove-BitsTransfer $job -ErrorAction SilentlyContinue
            throw "BITS transfer failed: $errMsg"
        }
        Complete-BitsTransfer $job
        Write-Log "Download complete." 'SUCCESS'
        return $OutFile
    } catch {
        try { Remove-BitsTransfer $job -ErrorAction SilentlyContinue } catch { }
        throw
    }
}

function Invoke-WebClientDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    Write-Log "Downloading via Invoke-WebRequest: $Label" 'DEBUG'
    $ProgressPreference = 'Continue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing `
            -Headers @{ 'User-Agent' = $HTTP_HEADERS['User-Agent'] } -ErrorAction Stop
        Write-Log "Download complete." 'SUCCESS'
        return $OutFile
    } catch {
        throw "WebRequest failed: $($_.Exception.Message)"
    }
}

function Invoke-AbDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    $name = [System.IO.Path]::GetFileName($OutFile)
    Write-Log "Handing download to AB Download Manager (port $script:AB_PORT): $Label" 'DEBUG'
    Add-AbDownload -Url $Url -SuggestedName $name -Referer "$RGT_REPO_URL/" -Headers @{ 'User-Agent' = $HTTP_HEADERS['User-Agent'] }
    Write-Log "Queued in AB; watching $script:AB_DOWNLOAD_DIR for '$name'..." 'DEBUG'
    $done = Wait-AbFile -Dir $script:AB_DOWNLOAD_DIR -Name $name -TimeoutSec $script:AB_TIMEOUT -Label $Label
    if (-not $done) {
        throw "AB Download Manager did not produce '$name' in $($script:AB_DOWNLOAD_DIR) within $($script:AB_TIMEOUT)s (folder/name may differ - set [rom].abDownloadDir)."
    }
    Write-Log "AB download complete." 'SUCCESS'
    # Pull it back into our temp dir so the extract/install path doesn't care it came from AB.
    if ($done -ne $OutFile) { Move-Item -LiteralPath $done -Destination $OutFile -Force -ErrorAction Stop }
    return $OutFile
}

# Run the chosen downloader, falling through Motrix -> AB -> direct tiers on failure.
function Invoke-FileDownload {
    param([string]$Url, [string]$OutFile, [string]$Label = "")
    if ($script:DOWNLOADER -eq $script:DL_MOTRIX) {
        try {
            return Invoke-MotrixDownload -Url $Url -OutFile $OutFile -Label $Label
        } catch {
            Write-Log "Motrix failed: $($_.Exception.Message)" 'WARN'
            $script:DOWNLOADER = Get-FallbackDownloader
            Write-Log "Falling back to: $script:DOWNLOADER" 'WARN'
        }
    }
    if ($script:DOWNLOADER -eq $script:DL_AB) {
        try {
            return Invoke-AbDownload -Url $Url -OutFile $OutFile -Label $Label
        } catch {
            Write-Log "AB Download Manager failed: $($_.Exception.Message)" 'WARN'
            $script:DOWNLOADER = Get-DirectDownloader
            Write-Log "Falling back to: $script:DOWNLOADER" 'WARN'
        }
    }
    switch ($script:DOWNLOADER) {
        $script:DL_ARIA2C    { return Invoke-Aria2cDownload    -Url $Url -OutFile $OutFile -Label $Label }
        $script:DL_CURL      { return Invoke-CurlDownload      -Url $Url -OutFile $OutFile -Label $Label }
        $script:DL_BITS      { return Invoke-BitsDownload      -Url $Url -OutFile $OutFile -Label $Label }
        $script:DL_WEBCLIENT { return Invoke-WebClientDownload -Url $Url -OutFile $OutFile -Label $Label }
        default              { throw "No supported downloader found." }
    }
}
