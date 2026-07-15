# Search cdromance.org for a game, download it, extract and file the ROM into the right
# console folder, then optionally add it to Steam via Steam ROM Manager.
#
# This is the orchestrator; the real work lives in the sibling modules it dot-sources.
# Settings come from %LOCALAPPDATA%\dlScripts\config.json (created on first run).
#
# Normally invoked through dlrom.cmd:
#   dlrom "Game Name" [--platform ps2] [--region usa] [--interactive] [--verbose]

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Query,

    [string]$Platform = "",
    [string]$Region = "",
    [string]$Sort = "",
    [string]$Destination = "",
    [int]$MaxResults = 0,
    [switch]$Interactive,
    [switch]$NoExtract,
    [switch]$NoSteam,
    [switch]$LinksOnly,
    [switch]$Quiet,
    [switch]$NoTorrent,
    [int]$TorrentPick = -1
)

# Load order matters only for Logging: it must come first so the DriveResolver fallback
# sees a Write-Log already defined. The rest resolve each other's calls at runtime.
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Logging.ps1')           # Write-Log, Format-*, ConvertTo-ResponseText
. (Join-Path $repoRoot     'lib\DriveResolver.ps1') # Initialize-DlConfig, Resolve-MediaPath
. (Join-Path $PSScriptRoot 'Cdromance.ps1')         # platform tables, search, link discovery
. (Join-Path $PSScriptRoot 'Downloaders.ps1')       # Motrix/AB/aria2c/curl/BITS/webclient + dispatcher
. (Join-Path $PSScriptRoot 'RomFiles.ps1')          # archive extraction, ROM filing
. (Join-Path $PSScriptRoot 'SteamRomManager.ps1')   # Steam ROM Manager sync
. (Join-Path $PSScriptRoot 'CfSolver.ps1')          # Cloudflare bypass (Invoke-CdrWeb), Get-CdrFailureReason
. (Join-Path $PSScriptRoot 'QbitTorrent.ps1')       # qBittorrent WebUI client (PS2 torrent fallback)
. (Join-Path $PSScriptRoot 'Ps2TorrentIndex.ps1')   # PS2 archive torrent fallback (match + selective download + install)

# -Verbose (a common parameter) turns on DEBUG; -Quiet hides routine INFO.
$script:LOG_VERBOSE = ($VerbosePreference -ne 'SilentlyContinue')
$script:LOG_QUIET   = [bool]$Quiet

$cfg = Initialize-DlConfig -Section "rom" -Defaults ([PSCustomObject]@{
    romsBase        = "C:\Emulation\roms"
    tempDir         = (Join-Path $env:TEMP "dlrom")
    motrixRpcUrl    = "http://localhost:16800/jsonrpc"
    maxResults      = 10
    pollIntervalMs  = 2000
    steamSync       = $true     # after a successful install, add the ROM to Steam via Steam ROM Manager
    srmExe          = ""        # path to srm.exe; blank = autodetect C:\Emulation\tools\srm.exe
    srmRestartSteam = "auto"    # auto (restart only if running) | never | always
    srmEnableParser = $true     # enable the SRM parser watching the destination folder before adding
    srmWrapperCmd   = ""        # path to srm-wrapper.cmd; blank = autodetect on PATH (preferred over built-in)
    abPort          = 15151     # AB Download Manager integration port (used when Motrix isn't running)
    abDownloadDir   = ""        # AB's download folder; blank = autodetect %USERPROFILE%\Downloads\ABDM
    abTimeoutSec    = 1800      # how long to wait for an AB download to finish before giving up
    cfSolverUrl     = "http://localhost:8191/v1"  # FlareSolverr endpoint
    cfSolverMode    = "auto"    # auto (solve only when blocked) | always | never
    cfAutoStart     = $true     # docker start/run the solver container on demand (never opens a window)
    cfContainerName = "flaresolverr"
    cfDockerImage   = "ghcr.io/flaresolverr/flaresolverr:latest"
    cfSolverTimeoutMs = 120000  # per-challenge solve budget (ms)
    # PS2 torrent fallback: when cdromance + direct sources fail for a PS2 game,
    # pull just that one ROM from the local Redump PS2 archive torrent via qBittorrent.
    ps2TorrentEnabled    = $true
    ps2TorrentPath       = ""     # blank = repo copy (dlrom\data\ps2-torrent\*.torrent), else Downloads
    ps2TorrentIndexPath  = ""     # blank = dlrom\data\ps2-torrent\ps2-index.json
    ps2TorrentStaging    = ""     # blank = <romsBase>\.dlrom-torrent (same drive as the ROM dir)
    ps2TorrentTimeoutSec = 14400  # max wait for the single-file download (seconds)
    qbitHost             = ""     # blank = autodetect qBittorrent WebUI (qBittorrent.ini port, else :8075)
    qbitUser             = ""     # only needed if WebUI\LocalHostAuth is enabled
    qbitPass             = ""
})

# Read a config value with a fallback when the key is absent (stale config that missed backfill).
function Get-CfgValue {
    param([string]$Name, $Default)
    if ($cfg.PSObject.Properties.Name -contains $Name -and $null -ne $cfg.$Name) { return $cfg.$Name }
    return $Default
}

if ($MaxResults -eq 0) { $MaxResults = [int]$cfg.maxResults }
$script:MOTRIX_URL = $cfg.motrixRpcUrl
$tempDir           = $cfg.tempDir

# AB Download Manager settings (resolved before downloader selection)
$script:AB_PORT    = [int](Get-CfgValue 'abPort' 15151)
$script:AB_TIMEOUT = [int](Get-CfgValue 'abTimeoutSec' 1800)
$abDirCfg          = Get-CfgValue 'abDownloadDir' ''
$script:AB_DOWNLOAD_DIR = if ($abDirCfg) { $abDirCfg } else { Join-Path $env:USERPROFILE 'Downloads\ABDM' }

# Cloudflare bypass settings (consumed by CfSolver.ps1 / Invoke-CdrWeb)
$script:CF_SOLVER_URL = Get-CfgValue 'cfSolverUrl' 'http://localhost:8191/v1'
$script:CF_MODE       = (Get-CfgValue 'cfSolverMode' 'auto').ToString().ToLower()
$script:CF_AUTOSTART  = [bool](Get-CfgValue 'cfAutoStart' $true)
$script:CF_CONTAINER  = Get-CfgValue 'cfContainerName' 'flaresolverr'
$script:CF_IMAGE      = Get-CfgValue 'cfDockerImage' 'ghcr.io/flaresolverr/flaresolverr:latest'
$script:CF_TIMEOUT    = [int](Get-CfgValue 'cfSolverTimeoutMs' 120000)
$script:CF_CACHE_DIR  = $tempDir

$script:DOWNLOADER = Find-Downloader

$downloaderLabel = switch ($script:DOWNLOADER) {
    'motrix'    { 'Motrix (aria2 RPC)'                          }
    'ab'        { "AB Download Manager (port $script:AB_PORT)"  }
    'aria2c'    { 'aria2c (standalone)'                         }
    'curl'      { 'curl.exe (Windows built-in)'                 }
    'bits'      { 'BITS (Background Intelligent Transfer)'      }
    'webclient' { 'PowerShell Invoke-WebRequest (last resort)'  }
}
Write-Log "Downloader: $downloaderLabel" 'INFO'

# Resolve platform slug
$resolvedSlug = ""
if ($Platform) {
    $key = $Platform.ToLower()
    if ($PLATFORM_SLUGS.ContainsKey($key)) {
        $resolvedSlug = $PLATFORM_SLUGS[$key]
        Write-Log "Platform: $Platform -> slug '$resolvedSlug'" 'DEBUG'
    } else {
        Write-Log "Unknown platform '$Platform' - passing as-is to search URL." 'WARN'
        $resolvedSlug = $key
    }
}

# PS2 torrent fallback is eligible only for PS2 (we must know it's PS2 to pick the
# right archive), when enabled, and not in links-only mode.
$script:PS2_FALLBACK = ([bool]$cfg.ps2TorrentEnabled -and -not $NoTorrent -and -not $LinksOnly -and
    (($resolvedSlug -eq 'ps2-iso') -or ($Platform -and $Platform.ToLower() -eq 'ps2')))

# Every cdromance dead-end funnels through here: report the real reason, try the
# PS2 torrent fallback when eligible, and only then exit with the original code.
function Invoke-CdrFallbackOrExit {
    param([string]$ReasonCode, [string]$ReasonText, [int]$ExitCode)
    if ($ReasonText) { Write-Log $ReasonText 'WARN' }
    if ($script:PS2_FALLBACK) {
        $ok = $false
        try {
            $ok = Invoke-Ps2TorrentFallback -Query $Query -Region $Region -Destination $Destination `
                    -Cfg $cfg -NoExtract:$NoExtract -NoSteam:$NoSteam -PickIndex $TorrentPick -Reason $ReasonCode
        } catch {
            Write-Log "Torrent fallback error: $($_.Exception.Message)" 'ERROR'
        }
        if ($ok) { Write-Log "All done (PS2 torrent fallback)." 'SUCCESS'; exit 0 }
        Write-Log "PS2 torrent fallback did not install anything." 'WARN'
    } elseif (($resolvedSlug -eq 'ps2-iso') -or ($Platform -and $Platform.ToLower() -eq 'ps2')) {
        if ($NoTorrent)             { Write-Log "PS2 torrent fallback skipped (--no-torrent)." 'INFO' }
        elseif (-not $cfg.ps2TorrentEnabled) { Write-Log "PS2 torrent fallback disabled in config." 'INFO' }
    } else {
        Write-Log "Tip: pass --platform ps2 to enable the torrent fallback for PS2 games." 'INFO'
    }
    exit $ExitCode
}

# Search
Write-Log "Searching for: $Query" 'INFO'
$results = @()
try {
    $results = @(Invoke-CdromanceSearch -SearchQuery $Query -PlatformSlug $resolvedSlug -SearchRegion $Region -SearchSort $Sort)
} catch {
    $reason = Get-CdrFailureReason $_.Exception.Message
    Write-Log "cdromance search failed: $($reason.Text)" 'ERROR'
    Invoke-CdrFallbackOrExit -ReasonCode $reason.Code -ReasonText $null -ExitCode 1
}

if ($results.Count -eq 0) {
    Write-Log "No results found on cdromance for: $Query" 'WARN'
    Invoke-CdrFallbackOrExit -ReasonCode 'no-results' -ReasonText $null -ExitCode 0
}

$displayResults = @($results | Select-Object -First $MaxResults)

# Show results
Write-Host ""
$i = 1
foreach ($r in $displayResults) {
    Write-Host ("[{0,2}]" -f $i) -ForegroundColor Yellow -NoNewline
    Write-Host " $($r.Title)" -ForegroundColor White
    Write-Host ("       $($r.Platform)  |  $($r.Url)") -ForegroundColor DarkGray
    $i++
}
Write-Host ""

# Select game
$selected = $null
if ($Interactive -and $displayResults.Count -gt 1) {
    $choice = Read-Host "Select [1-$($displayResults.Count)] or 0 to cancel"
    if ($choice -eq '0' -or $choice -eq '') { Write-Log "Cancelled." 'WARN'; exit 0 }
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $displayResults.Count) {
        Write-Log "Invalid selection." 'ERROR'; exit 1
    }
    $selected = $displayResults[$idx]
} else {
    $usaResult = $displayResults | Where-Object { $_.Url -imatch '\busa\b' } | Select-Object -First 1
    $selected  = if ($usaResult) { $usaResult } else { $displayResults[0] }
    Write-Log "Auto-selecting: $($selected.Title)" 'INFO'
}

# Get download links (reveals the "SHOW LINKS" table)
Write-Log "Fetching download links for: $($selected.Title)" 'DEBUG'
$allLinks = @(Get-DownloadLinks -GamePageUrl $selected.Url)

if ($allLinks.Count -eq 0) {
    Write-Log "No download links found on the game page." 'ERROR'
    $debugPath = Join-Path $env:TEMP "dlrom-debug.html"
    try {
        $dbgResp = Invoke-CdrWeb -Uri $selected.Url
        $dbgResp.Content | Set-Content $debugPath -Encoding UTF8
        Write-Log "Debug HTML saved to: $debugPath" 'WARN'
    } catch { }
    Invoke-CdrFallbackOrExit -ReasonCode 'no-links' -ReasonText $null -ExitCode 1
}

Write-Log "Found $($allLinks.Count) raw link(s) on page." 'DEBUG'
$selectedLinks = @(Select-DownloadLinks -Links $allLinks)

if ($selectedLinks.Count -eq 0) {
    Write-Log "No suitable links after filtering (demos removed, nothing left)." 'ERROR'
    Invoke-CdrFallbackOrExit -ReasonCode 'no-suitable-links' -ReasonText $null -ExitCode 1
}

Write-Log "Will download $($selectedLinks.Count) file(s): $(($selectedLinks | ForEach-Object { $_.Label }) -join ', ')" 'INFO'

# Links-only: print the resolved download links and stop (useful for previewing and for
# verifying the Cloudflare bypass without downloading anything).
if ($LinksOnly) {
    Write-Log "Links-only mode - not downloading." 'INFO'
    foreach ($l in $selectedLinks) { Write-Host "$($l.Label)`t$($l.Url)" }
    exit 0
}

# Resolve ROM destination
$platformFolder = if ($resolvedSlug -and $PLATFORM_FOLDERS.ContainsKey($resolvedSlug)) {
    $PLATFORM_FOLDERS[$resolvedSlug]
} elseif ($Platform) {
    $Platform.ToLower()
} elseif ($selected.Platform -and $PLATFORM_FOLDERS.ContainsKey($selected.Platform)) {
    # No --platform given: use the platform detected from the chosen search result
    # so a bare `dlrom "Game"` still lands in the right console folder, not \roms.
    $PLATFORM_FOLDERS[$selected.Platform]
} else {
    "roms"
}

# Resolve the ROMs base directory in priority order:
#   1. -Destination          explicit per-run override (always wins)
#   2. cfg.romsBase          the configured base (C:\Emulation\roms) when it exists
#   3. drive-meta picker      a connected drive advertising a rom_path
#   4. manual prompt          last resort
$romsBase = $null
if ($Destination) {
    $romsBase = $Destination
} elseif ($cfg.romsBase -and (Test-Path $cfg.romsBase)) {
    $romsBase = $cfg.romsBase
    Write-Log "ROMs base: $romsBase" 'DEBUG'
} else {
    if ($cfg.romsBase) {
        Write-Log "Configured ROMs base not available: $($cfg.romsBase) - falling back to drive picker." 'WARN'
    }
    try {
        $romsBase = Resolve-MediaPath -MediaType 'rom' -Strict
        Write-Log "Drive picker selected ROMs base: $romsBase" 'INFO'
    } catch {
        Write-Log "No connected drive advertises a ROM path ($($_.Exception.Message))." 'DEBUG'
        Write-Host "Enter ROMs base path (or press Enter for $HOME\Emulation\roms): " -NoNewline
        $alt = Read-Host
        $romsBase = if ($alt) { $alt } else { Join-Path $HOME "Emulation\roms" }
    }
}

$romDest = Join-Path $romsBase $platformFolder
if (-not (Test-Path $romDest)) {
    New-Item -ItemType Directory -Path $romDest -Force | Out-Null
    Write-Log "Created ROM directory: $romDest" 'DEBUG'
}

if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

# Download, extract, and install each selected link.
# Each iteration removes its temp archive + extraction dir in a finally so nothing is
# left behind on success OR failure (--no-extract keeps the archive, which is the deliverable).
$installedCount = 0
foreach ($link in $selectedLinks) {
    Write-Log "Downloading: $($link.Label)" 'INFO'

    # Sanitise label for use as a Windows filename
    $safeLabel = $link.Label -replace '[<>:"/\\|?*]', '_'
    $outFile   = Join-Path $tempDir $safeLabel

    $completedPath = $null
    $extractDir    = $null
    try {
        try {
            $completedPath = Invoke-FileDownload -Url $link.Url -OutFile $outFile -Label $link.Label
        } catch {
            Write-Log "Download failed: $($_.Exception.Message)" 'ERROR'
            continue
        }

        if ($NoExtract) {
            Write-Log "Archive saved (--no-extract): $completedPath" 'SUCCESS'
            continue
        }

        if (-not $completedPath -or -not (Test-Path $completedPath)) {
            Write-Log "Downloaded file not found at: $outFile" 'ERROR'
            continue
        }

        # Raw ROM (not a real archive): file it straight into the console folder so it can
        # never be left behind in the downloader's folder. Only true archives get extracted.
        if (-not (Test-IsArchive $completedPath)) {
            $dlExt = [System.IO.Path]::GetExtension($completedPath).ToLower()
            if ($dlExt -notin $script:ROM_EXTS) {
                Write-Log "Download is not an archive and '$dlExt' is an unrecognised ROM type; filing as-is." 'WARN'
            }
            try {
                Move-RomToDest -SourcePath $completedPath -DestDir $romDest | Out-Null
                $installedCount++
            } catch {
                Write-Log "Failed to file ROM: $($_.Exception.Message)" 'ERROR'
            }
            continue
        }

        $extractId  = [System.IO.Path]::GetFileNameWithoutExtension($safeLabel) + '_' + (Get-Random)
        $extractDir = Join-Path $tempDir "extracted\$extractId"
        try {
            Expand-RomArchive -ArchivePath $completedPath -OutDir $extractDir
        } catch {
            Write-Log "Extraction failed: $($_.Exception.Message)" 'ERROR'
            continue
        }

        $romFile = Find-RomFile -ExtractedDir $extractDir
        if (-not $romFile) {
            Write-Log "No ROM file found after extraction." 'WARN'
            continue
        }

        try {
            Move-RomToDest -SourcePath $romFile.FullName -DestDir $romDest | Out-Null
            $installedCount++
        } catch {
            Write-Log "Move failed: $($_.Exception.Message)" 'ERROR'
        }
    }
    finally {
        # Always clean download artifacts (keep the archive only under --no-extract).
        if (-not $NoExtract) {
            if ($completedPath -and (Test-Path $completedPath)) { Remove-Item -Path $completedPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path $outFile)                              { Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue }
            if ($extractDir -and (Test-Path $extractDir))        { Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

# Prune the extraction parent if our cleanup left it empty.
$extractedParent = Join-Path $tempDir "extracted"
if ((Test-Path $extractedParent) -and -not (Get-ChildItem -LiteralPath $extractedParent -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -Path $extractedParent -Force -ErrorAction SilentlyContinue
}

# Add the freshly installed ROM(s) to Steam (srm-wrapper preferred, built-in fallback).
if ($installedCount -gt 0 -and -not $NoSteam -and [bool](Get-CfgValue 'steamSync' $true)) {
    Sync-RomToSteam -RomDest $romDest -RomsBase $romsBase -InstalledCount $installedCount
} elseif ($installedCount -gt 0 -and $NoSteam) {
    Write-Log "Skipping Steam sync (--no-steam)." 'INFO'
}

Write-Log "All done." 'SUCCESS'
