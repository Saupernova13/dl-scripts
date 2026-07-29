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
    # 'curl' before 'curl.exe' so Linux finds /usr/bin/curl. Probing only the .exe name sent
    # SteamOS straight past a working curl to the last-resort tier.
    foreach ($name in @('curl.exe', 'curl')) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { return $script:DL_CURL }
    }
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

# The denominator for the progress bar. Best effort - a download with no percentage still
# works, it just cannot be told apart from a stalled one, which is the whole problem.
function Get-RemoteContentLength {
    param([string]$Url)
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 20 `
                    -Headers @{ 'User-Agent' = $HTTP_HEADERS['User-Agent'] } -ErrorAction Stop
        $len = $resp.Headers['Content-Length']
        if ($len -is [array]) { $len = $len[0] }
        return [long]$len
    } catch {
        return 0
    }
}

# .NET Framework has no ProcessStartInfo.ArgumentList, only the single Arguments string.
function Test-ArgumentListSupported {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    return [bool]($psi | Get-Member -Name 'ArgumentList' -MemberType Property)
}

# Run a download tool and report progress by watching its output file grow.
#
# Neither obvious way of starting it works here. Start-Process splits ArgumentList on
# spaces on Linux, so an output path like "Iron Man (USA) (En,Fr,Es).7z" arrives as four
# separate arguments and curl tries to resolve "Man" as a hostname. The call operator
# quotes correctly but blocks this runspace, and a blocked runspace cannot poll anything -
# which is why every native tier reported the job's floor percentage for the whole
# download, making a working transfer look identical to a dead one.
#
# ArgumentList passes an argv array verbatim and leaves us free to poll. Windows PowerShell
# 5.1 lacks it and falls back to a blocking run: there Motrix or aria2c normally serves,
# and both report progress by other means.
function Invoke-NativeDownload {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [string]$OutFile,
        [string]$Label,
        [long]$TotalBytes = 0
    )

    if (-not (Test-ArgumentListSupported)) {
        & $Exe @Arguments
        return $LASTEXITCODE
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $Exe
    $psi.UseShellExecute = $false
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }

    $proc       = [System.Diagnostics.Process]::Start($psi)
    $shortLabel = Format-ShortLabel $Label
    $lastDone   = 0
    $lastTick   = Get-Date

    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds $script:NATIVE_POLL_MS
        $done = 0
        try {
            if (Test-Path -LiteralPath $OutFile) { $done = (Get-Item -LiteralPath $OutFile).Length }
        } catch { }

        $now     = Get-Date
        $elapsed = ($now - $lastTick).TotalSeconds
        $speed   = if ($elapsed -gt 0) { [long](($done - $lastDone) / $elapsed) } else { -1 }
        $lastDone = $done
        $lastTick = $now

        $pct = if ($TotalBytes -gt 0) { [int](($done / $TotalBytes) * 100) } else { -1 }
        Write-ProgressLine -Percent $pct -Line (Format-TransferLine -Percent $pct -Done $done `
            -Total $TotalBytes -BytesPerSec $speed -Label $shortLabel)
    }
    $proc.WaitForExit()
    Stop-ProgressLine
    return $proc.ExitCode
}

# First name on PATH wins; $null when none of them resolve.
function Get-NativeTool {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Invoke-Aria2cDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    $exe = Get-NativeTool @('aria2c.exe', 'aria2c')
    if (-not $exe) { throw "aria2c was not found on PATH." }
    Write-Log "Downloading via aria2c: $Label" 'DEBUG'
    $outDir  = [System.IO.Path]::GetDirectoryName($OutFile)
    $outName = [System.IO.Path]::GetFileName($OutFile)
    $exit = Invoke-NativeDownload -Exe $exe -OutFile $OutFile -Label $Label `
        -TotalBytes (Get-RemoteContentLength $Url) `
        -Arguments @("--dir=$outDir", "--out=$outName", '--console-log-level=warn',
                     '--summary-interval=0', '--max-connection-per-server=4', '--split=4',
                     "--user-agent=$($HTTP_HEADERS['User-Agent'])", $Url)
    if ($exit -ne 0) { throw "aria2c exited with code $exit" }
    Write-Log "Download complete." 'SUCCESS'
    return $OutFile
}

function Invoke-CurlDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)
    $exe = Get-NativeTool @('curl.exe', 'curl')
    if (-not $exe) { throw "curl was not found on PATH." }
    Write-Log "Downloading via curl: $Label" 'DEBUG'
    # --fail so an HTTP error page is a non-zero exit rather than a saved error page.
    # -sS keeps curl's own bar out of the log; progress comes from the file watcher.
    $exit = Invoke-NativeDownload -Exe $exe -OutFile $OutFile -Label $Label `
        -TotalBytes (Get-RemoteContentLength $Url) `
        -Arguments @('-L', '--fail', '-sS', '--retry', '3', '--retry-delay', '2',
                     '-A', $HTTP_HEADERS['User-Agent'], '-o', $OutFile, $Url)
    if ($exit -ne 0) { throw "curl exited with code $exit" }
    Write-Log "Download complete." 'SUCCESS'
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

# Every backend reports success in its own way - an exit code, an RPC status, or merely
# returning without throwing - and none of them proved the bytes landed. Invoke-WebRequest
# in particular returned cleanly after a 978 MB download that left nothing on disk, so the
# job logged "Download complete." and then "Downloaded file not found" in the same second.
# One check on the way out means a backend cannot claim a file it did not produce.
function Assert-DownloadedFile {
    param([string]$Path, [string]$Backend)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Backend reported success but returned no file path."
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Backend reported success but no file exists at: $Path"
    }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -le 0) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "$Backend produced an empty file at: $Path"
    }
    Write-Log "Downloaded $(Format-Bytes $size) to $Path" 'DEBUG'
    return $Path
}

# Run the chosen downloader, falling through Motrix -> AB -> direct tiers on failure.
function Invoke-FileDownload {
    param([string]$Url, [string]$OutFile, [string]$Label = "")
    # Verification sits inside each try so a backend that "succeeded" without producing a
    # file falls through to the next tier, exactly as a thrown error does.
    if ($script:DOWNLOADER -eq $script:DL_MOTRIX) {
        try {
            $path = Invoke-MotrixDownload -Url $Url -OutFile $OutFile -Label $Label
            return (Assert-DownloadedFile -Path $path -Backend 'Motrix')
        } catch {
            Write-Log "Motrix failed: $($_.Exception.Message)" 'WARN'
            $script:DOWNLOADER = Get-FallbackDownloader
            Write-Log "Falling back to: $script:DOWNLOADER" 'WARN'
        }
    }
    if ($script:DOWNLOADER -eq $script:DL_AB) {
        try {
            $path = Invoke-AbDownload -Url $Url -OutFile $OutFile -Label $Label
            return (Assert-DownloadedFile -Path $path -Backend 'AB Download Manager')
        } catch {
            Write-Log "AB Download Manager failed: $($_.Exception.Message)" 'WARN'
            $script:DOWNLOADER = Get-DirectDownloader
            Write-Log "Falling back to: $script:DOWNLOADER" 'WARN'
        }
    }
    $path = switch ($script:DOWNLOADER) {
        $script:DL_ARIA2C    { Invoke-Aria2cDownload    -Url $Url -OutFile $OutFile -Label $Label }
        $script:DL_CURL      { Invoke-CurlDownload      -Url $Url -OutFile $OutFile -Label $Label }
        $script:DL_BITS      { Invoke-BitsDownload      -Url $Url -OutFile $OutFile -Label $Label }
        $script:DL_WEBCLIENT { Invoke-WebClientDownload -Url $Url -OutFile $OutFile -Label $Label }
        default              { throw "No supported downloader found." }
    }
    return (Assert-DownloadedFile -Path $path -Backend $script:DOWNLOADER)
}
