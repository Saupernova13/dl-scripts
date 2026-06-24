# CfSolver.ps1
# Cloudflare bypass for dlrom. Two cooperating pieces, both fully off-screen:
#
#   1. FlareSolverr (headless Chromium in Docker) solves Cloudflare's challenge and
#      mints a cf_clearance cookie + matching User-Agent. This is the only step that
#      needs a real browser.
#   2. cdr_http.py (curl_cffi) replays that cookie while impersonating Chrome's TLS/HTTP2
#      fingerprint, so Cloudflare accepts it - and, unlike a browser navigation, it can
#      set headers such as X-Requested-With that the link-reveal endpoint requires.
#
# PowerShell's own web client can't pass Cloudflare (its TLS fingerprint isn't a browser's)
# and FlareSolverr can't set request headers, so neither works alone - hence the split.
# cf_clearance is cached on disk by the Python helper and reused across runs; a 403/503/429
# triggers one automatic re-mint + retry. The actual file download is a normal direct URL
# (not Cloudflare-gated) and stays on dlrom's existing downloaders.
#
# Dot-sourced by Add-ROM.ps1, which sets these script-scope vars from config.json:
#   $script:CF_SOLVER_URL  $script:CF_MODE     $script:CF_AUTOSTART
#   $script:CF_CONTAINER   $script:CF_IMAGE    $script:CF_TIMEOUT   $script:CF_CACHE_DIR
# $HTTP_HEADERS (with a User-Agent) comes from Cdromance.ps1; Write-Log and
# ConvertTo-ResponseText come from Logging.ps1. All resolve at call time.

$script:CF_PY        = $null    # resolved python invocation @{ Exe; Pre }
$script:CF_PY_READY  = $false   # curl_cffi confirmed importable this run

# --- Docker / solver lifecycle (all silent, no windows) -----------------------

function Invoke-DockerQuiet {
    param([string[]]$DArgs)
    try { return (& docker @DArgs 2>$null | Out-String) } catch { return '' }
}

function Test-DockerReady {
    try { & docker info 2>$null 1>$null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

function Get-CfSolverBase { return ($script:CF_SOLVER_URL -replace '/v1/?$', '') }

function Test-CfSolverUp {
    try {
        $r = Invoke-WebRequest -Uri (Get-CfSolverBase) -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
        return ((ConvertTo-ResponseText $r.Content) -match 'FlareSolverr')
    } catch { return $false }
}

# Ensure the solver is reachable; start (or create) the container if allowed. Never
# launches Docker Desktop itself - if the daemon is down we report and bail so nothing
# pops up on screen.
function Initialize-CfSolver {
    if (Test-CfSolverUp) { return $true }
    if (-not $script:CF_AUTOSTART) {
        Write-Log "FlareSolverr not reachable at $($script:CF_SOLVER_URL) and autostart is disabled." 'WARN'
        return $false
    }
    if (-not (Test-DockerReady)) {
        Write-Log "Docker daemon not available - start Docker Desktop to enable the Cloudflare bypass." 'WARN'
        return $false
    }
    $existing = Invoke-DockerQuiet @('ps', '-a', '--filter', "name=^/$($script:CF_CONTAINER)$", '--format', '{{.Names}}')
    if ($existing -match [regex]::Escape($script:CF_CONTAINER)) {
        Write-Log "Starting FlareSolverr container '$($script:CF_CONTAINER)'..." 'INFO'
        Invoke-DockerQuiet @('start', $script:CF_CONTAINER) | Out-Null
    } else {
        Write-Log "Creating FlareSolverr container '$($script:CF_CONTAINER)'..." 'INFO'
        $port = ((Get-CfSolverBase) -replace '^https?://[^:]+:?', '')
        if (-not $port) { $port = '8191' }
        Invoke-DockerQuiet @('run', '-d', '--name', $script:CF_CONTAINER,
            '-p', "${port}:8191", '--restart', 'unless-stopped',
            '-e', 'LOG_LEVEL=warning', $script:CF_IMAGE) | Out-Null
    }
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if (Test-CfSolverUp) { Write-Log "FlareSolverr is ready." 'SUCCESS'; return $true }
        Start-Sleep -Seconds 2
    }
    Write-Log "FlareSolverr did not become ready within 90s." 'WARN'
    return $false
}

# --- Python / curl_cffi plumbing ----------------------------------------------

function Resolve-PythonExe {
    if ($script:CF_PY) { return $script:CF_PY }
    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $script:CF_PY = @{ Exe = $cmd.Source; Pre = @() }; return $script:CF_PY }
    }
    $py = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($py) { $script:CF_PY = @{ Exe = $py.Source; Pre = @('-3') }; return $script:CF_PY }
    return $null
}

function Test-CurlCffi {
    param($Py)
    if ($script:CF_PY_READY) { return $true }
    & $Py.Exe @($Py.Pre + @('-c', 'import curl_cffi')) 2>$null 1>$null
    if ($LASTEXITCODE -eq 0) { $script:CF_PY_READY = $true; return $true }
    Write-Log "Installing curl_cffi (one-time, enables the Cloudflare bypass)..." 'INFO'
    & $Py.Exe @($Py.Pre + @('-m', 'pip', 'install', '--quiet', 'curl_cffi')) 2>$null 1>$null
    & $Py.Exe @($Py.Pre + @('-c', 'import curl_cffi')) 2>$null 1>$null
    $script:CF_PY_READY = ($LASTEXITCODE -eq 0)
    if (-not $script:CF_PY_READY) { Write-Log "Could not install curl_cffi." 'WARN' }
    return $script:CF_PY_READY
}

# --- Direct (non-solver) request, used only when cfSolverMode = never ----------

function Invoke-DirectCdr {
    param([string]$Uri, [string]$Method, [string]$Body, [string]$ContentType, [hashtable]$ExtraHeaders, [string]$Referer)
    $headers = $script:HTTP_HEADERS.Clone()
    if ($Referer) { $headers['Referer'] = $Referer }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }
    $params = @{ Uri = $Uri; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 45; ErrorAction = 'Stop' }
    if ($Method -eq 'POST') { $params.Body = $Body; $params.ContentType = $ContentType }
    return Invoke-WebRequest @params
}

# --- Unified cdromance request ------------------------------------------------
# Returns an object with a .Content property (page HTML). Callers use it like
# Invoke-WebRequest; the Cloudflare handling underneath is invisible to them.

function Invoke-CdrWeb {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [string]$Body,
        [string]$ContentType = 'application/x-www-form-urlencoded',
        [hashtable]$ExtraHeaders,
        [string]$Referer
    )

    # Function-scoped: stops a native stderr write from becoming a terminating
    # NativeCommandError when a caller runs with $ErrorActionPreference='Stop'.
    $ErrorActionPreference = 'Continue'

    if ($script:CF_MODE -eq 'never') {
        return (Invoke-DirectCdr -Uri $Uri -Method $Method -Body $Body -ContentType $ContentType -ExtraHeaders $ExtraHeaders -Referer $Referer)
    }

    if (-not (Initialize-CfSolver)) {
        throw "Cloudflare bypass needs FlareSolverr, which is unavailable (is Docker Desktop running?)."
    }
    $py = Resolve-PythonExe
    if (-not $py) { throw "Python 3 is required for the Cloudflare bypass but was not found on PATH." }
    if (-not (Test-CurlCffi $py)) { throw "curl_cffi (Python) is required for the Cloudflare bypass and could not be installed." }

    if (-not (Test-Path $script:CF_CACHE_DIR)) { New-Item -ItemType Directory -Path $script:CF_CACHE_DIR -Force | Out-Null }
    $outFile = Join-Path $script:CF_CACHE_DIR ('cdr_' + [guid]::NewGuid().ToString('N') + '.html')
    $cache   = Join-Path $script:CF_CACHE_DIR 'cf_session.json'

    $pyArgs = @((Join-Path $PSScriptRoot 'cdr_http.py'),
        '--url', $Uri, '--method', $Method, '--out', $outFile,
        '--solver', $script:CF_SOLVER_URL, '--cache', $cache, '--timeout-ms', $script:CF_TIMEOUT)
    if ($Method -eq 'POST' -and $Body) { $pyArgs += @('--data', $Body) }
    if ($Referer) { $pyArgs += @('--header', "Referer: $Referer") }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $pyArgs += @('--header', "${k}: $($ExtraHeaders[$k])") } }

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $lines = & $py.Exe @($py.Pre + $pyArgs) 2>$errFile
        $code  = $LASTEXITCODE
        $okStatus = $null; $errLine = $null
        foreach ($ln in @($lines)) {
            $s = [string]$ln
            if     ($s -match '^OK\s+(\d+)') { $okStatus = $Matches[1] }
            elseif ($s -match '^ERR\s+(.*)') { $errLine = $Matches[1] }
            elseif ($s -match '^LOG\s+(.*)') { Write-Log "[cf] $($Matches[1])" 'DEBUG' }
        }
        if ($code -ne 0 -or -not $okStatus) {
            $detail = if ($errLine) { $errLine } else { (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) }
            throw "Cloudflare fetch failed for $Uri ($(([string]$detail).Trim()))."
        }
        return [PSCustomObject]@{ Content = (Get-Content $outFile -Raw -Encoding UTF8); StatusCode = [int]$okStatus }
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    }
}
