# lib/DriveResolver.ps1
# Shared library for dl-scripts. Provides:
#   Initialize-DlConfig    - Bootstraps %LOCALAPPDATA%\dlScripts\config.json sections,
#                            backfilling any new keys from $Defaults into existing sections.
#   Get-DriveRegistryUrl   - Base URL of the drive-registry API (env / config / default).
#   Get-DriveMetaInventory - Connected drives, from the drive-registry API.
#   Get-FallbackMediaPath  - Safe local default path for a media type (no API needed).
#   Resolve-MediaPath      - Picks a destination drive for a media type via the API.
#
# The drive-picking logic no longer lives here: it is owned by the drive-registry service
# (Documents\github\drive-registry, http://127.0.0.1:9600), which also stamps the
# drive-meta.json file onto every connected drive - including drives plugged in after it
# started. This library is a thin API client.
#
# The API is OPTIONAL: if the service isn't configured or isn't running, Resolve-MediaPath
# degrades to a safe default destination (the caller's configured folder, else a per-type
# folder under the home directory) so every dl-script works standalone. Only -Strict callers
# (dlrom's ROM base) get a thrown error instead, so they can run their own fallback.
#
# Each script dot-sources this file via:
#   . (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\DriveResolver.ps1")
#
# Run this file directly to invoke the test harness.

# Default logger - scripts may redefine Write-Log later; identical signatures so no behaviour change.
if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $color = switch ($Level) {
            "INFO"    { "Cyan" }
            "SUCCESS" { "Green" }
            "WARN"    { "Yellow" }
            "ERROR"   { "Red" }
            "DEBUG"   { "Gray" }
            default   { "White" }
        }
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }
}

function Initialize-DlConfig {
    param([string]$Section, [PSCustomObject]$Defaults)
    $configDir  = Join-Path $env:LOCALAPPDATA "dlScripts"
    $configPath = Join-Path $configDir "config.json"
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $config = $null
    $dirty  = $false
    if (Test-Path $configPath) {
        try   { $config = Get-Content $configPath -Raw | ConvertFrom-Json }
        catch {
            Write-Host "[dlScripts] config.json could not be parsed  - [$Section] defaults will be written." -ForegroundColor Yellow
            $config = [PSCustomObject]@{}
            $dirty  = $true
        }
    } else {
        Write-Host "[dlScripts] Config not found  - creating: $configPath" -ForegroundColor Yellow
        $config = [PSCustomObject]@{}
        $dirty  = $true
    }
    if (-not ($config.PSObject.Properties.Name -contains $Section)) {
        Add-Member -InputObject $config -MemberType NoteProperty -Name $Section -Value $Defaults
        Write-Host "[dlScripts] Added [$Section] defaults to config.json  - edit to customise." -ForegroundColor Cyan
        $dirty = $true
    } else {
        $existing = $config.$Section
        foreach ($prop in $Defaults.PSObject.Properties) {
            if (-not ($existing.PSObject.Properties.Name -contains $prop.Name)) {
                Add-Member -InputObject $existing -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
                Write-Host "[dlScripts] Backfilled missing key [$Section.$($prop.Name)] in config.json" -ForegroundColor Cyan
                $dirty = $true
            }
        }
    }
    if ($dirty) { $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8 }
    return $config.$Section
}

# Base URL of the drive-registry API. Resolved from (in order): DRIVE_REGISTRY_URL env var,
# a top-level "driveRegistryUrl" key in dlScripts config.json, then the localhost default.
function Get-DriveRegistryUrl {
    if ($env:DRIVE_REGISTRY_URL) { return ([string]$env:DRIVE_REGISTRY_URL).TrimEnd('/') }
    $configPath = Join-Path (Join-Path $env:LOCALAPPDATA "dlScripts") "config.json"
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.driveRegistryUrl) { return ([string]$cfg.driveRegistryUrl).TrimEnd('/') }
        } catch { }
    }
    return "http://127.0.0.1:9600"
}

# HTTP status of a failed Invoke-RestMethod, or $null if the call never reached the server
# (connection refused / DNS / timeout). Distinguishes "service down" from an HTTP error.
function Get-WebErrorStatus {
    param($ErrorRecord)
    try { if ($ErrorRecord.Exception.Response) { return [int]$ErrorRecord.Exception.Response.StatusCode } } catch { }
    return $null
}

# Connected drives as reported by the drive-registry API (letter, serial, freeGB, meta, ...).
function Get-DriveMetaInventory {
    $base = Get-DriveRegistryUrl
    try {
        $resp = Invoke-RestMethod -Uri "$base/drives" -Method Get -TimeoutSec 15 -ErrorAction Stop
    } catch {
        throw "Get-DriveMetaInventory: drive-registry API not reachable at $base - is the drive-registry service running? ($($_.Exception.Message))"
    }
    return $resp.drives
}

# Safe local default destination for a media type, used when the drive-registry service is
# unavailable or advertises no drive for the type. Keeps every script usable with no API
# configured. Mirrors each script's own configured default so behaviour is consistent.
function Get-FallbackMediaPath {
    param([Parameter(Mandatory=$true)][string]$MediaType)
    switch ($MediaType) {
        'movie'        { return (Join-Path $HOME 'Movies') }
        'tv'           { return (Join-Path $HOME 'TV') }
        'anime_series' { return (Join-Path $HOME 'Anime\Series') }
        'anime_movie'  { return (Join-Path $HOME 'Anime\Movies') }
        'game_pc'      { return (Join-Path $HOME 'Games') }
        'rom'          { return (Join-Path $HOME 'Emulation\roms') }
        default        { return (Join-Path $HOME $MediaType) }
    }
}

function Resolve-MediaPath {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('movie','tv','anime_series','anime_movie','game_pc','rom')]
        [string]$MediaType,
        # Destination to use when the service can't be reached or has no drive for this type.
        # Callers pass their configured folder; blank falls to a safe per-type home default.
        [string]$FallbackPath = "",
        [switch]$Strict,
        [switch]$DryRun
    )
    $fallback = if ($FallbackPath) { $FallbackPath } else { Get-FallbackMediaPath -MediaType $MediaType }

    $base = Get-DriveRegistryUrl
    $uri  = "$base/resolve?media=$([uri]::EscapeDataString($MediaType))"
    if ($Strict) { $uri += "&strict=1" }

    try {
        $resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15 -ErrorAction Stop
    } catch {
        $status = Get-WebErrorStatus $_
        if ($status -eq 409) {
            # Strict mode and no connected drive advertises this media type. Surface it so the
            # strict caller (e.g. dlrom) can run its own fallback.
            throw "Resolve-MediaPath: no connected drive advertises '$MediaType'."
        }
        # Service down / timeout / API error. Strict callers want to decide for themselves;
        # everyone else degrades to the safe default so the script still works with no API.
        $detail = if ($null -eq $status) {
            "drive-registry service not reachable at $base (is it running?)"
        } else {
            "drive-registry API error (HTTP $status) at $base"
        }
        if ($Strict) {
            throw "Resolve-MediaPath: $detail resolving '$MediaType'. $($_.Exception.Message)"
        }
        Write-Log "[resolver] $detail - using safe default $fallback" "WARN"
        if ($DryRun) { return $null }
        return $fallback
    }

    $pick = $resp.pick
    if (-not $pick) {
        # Non-strict, and the service reports no drive for this media type. Fall back so the
        # download still lands somewhere (the API is up; it just had no candidate - e.g. every
        # target drive is disconnected).
        Write-Log "[resolver] drive-registry has no drive for '$MediaType' - using safe default $fallback" "WARN"
        if ($DryRun) { return $null }
        return $fallback
    }

    $freeStr = if ($null -ne $pick.freeGB) { "$($pick.freeGB)GB" } else { "?" }
    Write-Log "[resolver] picked $($pick.letter): ($($pick.driveName)) for $MediaType, free=$freeStr, priority=$($pick.priority)" "INFO"
    if ($DryRun) {
        return [PSCustomObject]@{
            DriveLetter = $pick.letter
            DriveName   = $pick.driveName
            Type        = $pick.type
            RelPath     = $pick.relPath
            AbsPath     = $pick.absPath
            FreeGB      = $pick.freeGB
            Priority    = $pick.priority
            LastResort  = $pick.lastResort
        }
    }
    return $pick.absPath
}

function Invoke-DriveResolverTest {
    $base = Get-DriveRegistryUrl
    Write-Host "`n=== DriveResolver (drive-registry API @ $base) ===" -ForegroundColor Magenta
    try {
        $health = Invoke-RestMethod -Uri "$base/health" -Method Get -TimeoutSec 10 -ErrorAction Stop
        Write-Host ("service: {0} v{1} (up {2}s)" -f $health.service, $health.version, $health.uptimeSec) -ForegroundColor Gray
    } catch {
        Write-Host "drive-registry API not reachable at $base - is the service running?" -ForegroundColor Red
        return
    }

    $inv = Get-DriveMetaInventory
    Write-Host "`nDrive inventory ($($inv.Count) connected):" -ForegroundColor Magenta
    foreach ($d in $inv) {
        $name = if ($d.meta -and $d.meta.drive_name) { $d.meta.drive_name } else { "(unstamped)" }
        $type = if ($d.meta -and $d.meta.drive_type) { $d.meta.drive_type } else { "?" }
        Write-Host ("  {0}: {1,-30} type={2,-6} free={3,8}GB" -f $d.letter, $name, $type, $d.freeGB) -ForegroundColor Gray
    }

    foreach ($mt in 'movie','tv','anime_series','anime_movie','game_pc','rom') {
        Write-Host "`n--- $mt ---" -ForegroundColor Magenta
        $pick = Resolve-MediaPath -MediaType $mt -DryRun
        if ($pick) {
            Write-Host ("  pick:  {0}: ({1}) -> {2}" -f $pick.DriveLetter, $pick.DriveName, $pick.AbsPath) -ForegroundColor Green
            $lr = if ($pick.LastResort) { " last-resort" } else { "" }
            Write-Host ("  rank:  priority={0}{1} free={2}GB type={3}" -f $pick.Priority, $lr, $pick.FreeGB, $pick.Type) -ForegroundColor Gray
        } else {
            Write-Host "  (no drive advertises this media type)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

# Run the test harness when this file is invoked directly (not dot-sourced).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DriveResolverTest
}
