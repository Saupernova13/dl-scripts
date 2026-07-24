# Search RetroGameTalk's ROM repository (https://retrogametalk.com/repo/) for a game,
# download it, extract and file the ROM into the right console folder, then optionally add
# it to Steam via Steam ROM Manager.
#
# This is the orchestrator; the real work lives in the sibling modules it dot-sources.
# Settings come from %LOCALAPPDATA%\dlScripts\config.json (created on first run). The Repo
# needs no account, so there are no credentials to configure.
#
# Normally invoked through dlrom.cmd:
#   dlrom "Game Name" [--platform ps2] [--region usa] [--interactive] [--verbose]
#
# Downloads are ROM-sized, so the default is to hand the slow half to a detached worker
# and return a job id immediately (see Jobs.ps1 / RomPipeline.ps1):
#   dlrom "Game Name"            search + resolve links, spawn a worker, return a job id
#   dlrom --status <jobId>       progress of a running or finished job
#   dlrom --list                 every recent job
#   dlrom "Game Name" --wait     stay in the foreground until it is installed
#
# Modes:
#   -JobFile <path>  internal; the worker entry point, spawned by Start-DlromJob

[CmdletBinding()]
param(
    # Not Mandatory: --status/--list/-JobFile carry no query, and a mandatory parameter
    # would make PowerShell prompt for it -- hanging any run with no console attached.
    [string]$Query = "",

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
    [int]$TorrentPick = -1,

    # Background job surface
    [switch]$Wait,
    [string]$Status = "",
    [switch]$ListJobs,
    [string]$JobFile = "",
    [switch]$Json
)

# Load order matters for the two files that define script-scope VALUES rather than just
# functions: Constants.ps1 must come first (Logging's formatters read PROGRESS_BAR_WIDTH
# at parse time of their default parameters), then Common.ps1, then Logging so the
# DriveResolver fallback sees a Write-Log already defined. Everything after that is
# functions only, and resolves each other's calls at runtime.
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Constants.ps1')         # shared literals: job/downloader vocab, extensions, regions
. (Join-Path $PSScriptRoot 'Common.ps1')            # Get-CfgValue, Get-UtcStamp, region helpers
. (Join-Path $PSScriptRoot 'Logging.ps1')           # Write-Log, Format-*, ConvertTo-ResponseText
. (Join-Path $repoRoot     'lib\DriveResolver.ps1') # Initialize-DlConfig, Resolve-MediaPath
. (Join-Path $PSScriptRoot 'Jobs.ps1')             # job state, detached worker spawn, --status/--list
. (Join-Path $PSScriptRoot 'RetroGameTalk.ps1')     # platform tables, search, link discovery
. (Join-Path $PSScriptRoot 'Downloaders.ps1')       # Motrix/AB/aria2c/curl/BITS/webclient + dispatcher
. (Join-Path $PSScriptRoot 'RomFiles.ps1')          # archive extraction, ROM filing
. (Join-Path $PSScriptRoot 'SteamRomManager.ps1')   # Steam ROM Manager sync
. (Join-Path $PSScriptRoot 'QbitTorrent.ps1')       # qBittorrent WebUI client (PS2 torrent fallback)
. (Join-Path $PSScriptRoot 'Ps2TorrentIndex.ps1')   # PS2 archive torrent fallback (match + selective download + install)
. (Join-Path $PSScriptRoot 'Ps2Serial.ps1')         # PS2 serial resolve + result/handoff to dlps2tex
. (Join-Path $PSScriptRoot 'RomPipeline.ps1')       # download -> extract -> file -> Steam (shared by worker and --wait)

# -Verbose (a common parameter) turns on DEBUG; -Quiet hides routine INFO.
$script:LOG_VERBOSE = ($VerbosePreference -ne 'SilentlyContinue')
$script:LOG_QUIET   = [bool]$Quiet

# ---------------------------------------------------------------------------
# Job queries. Answered straight from the jobs dir -- no config, no network, so
# `dlrom --status <id>` stays instant even while a download is saturating the line.
# ---------------------------------------------------------------------------
if ($Status)   { Show-DlromJobStatus -JobId $Status -AsJson:$Json; exit 0 }
if ($ListJobs) { Show-DlromJobList -AsJson:$Json; exit 0 }

$cfg = Initialize-DlConfig -Section "rom" -Defaults ([PSCustomObject]@{
    romsBase        = $script:DEFAULT_ROMS_BASE
    tempDir         = (Join-Path $env:TEMP "dlrom")
    motrixRpcUrl    = $script:DEFAULT_MOTRIX_RPC
    maxResults      = 10
    pollIntervalMs  = 2000
    steamSync       = $true     # after a successful install, add the ROM to Steam via Steam ROM Manager
    srmExe          = ""        # path to srm.exe; blank = autodetect C:\Emulation\tools\srm.exe
    srmRestartSteam = "auto"    # auto (restart only if running) | never | always
    srmEnableParser = $true     # enable the SRM parser watching the destination folder before adding
    srmWrapperCmd   = ""        # path to srm-wrapper.cmd; blank = autodetect on PATH (preferred over built-in)
    abPort          = $script:DEFAULT_AB_PORT   # AB Download Manager integration port (used when Motrix isn't running)
    abDownloadDir   = ""        # AB's download folder; blank = autodetect %USERPROFILE%\Downloads\ABDM
    abTimeoutSec    = 1800      # how long to wait for an AB download to finish before giving up
    # PS2 torrent fallback: when The Repo + direct sources fail for a PS2 game,
    # pull just that one ROM from the local Redump PS2 archive torrent via qBittorrent.
    ps2TorrentEnabled    = $true
    ps2TorrentPath       = ""     # blank = repo copy (dlrom\data\ps2-torrent\*.torrent), else Downloads
    ps2TorrentIndexPath  = ""     # blank = dlrom\data\ps2-torrent\ps2-index.json
    ps2TorrentStaging    = ""     # blank = <romsBase>\.dlrom-torrent (same drive as the ROM dir)
    ps2TorrentTimeoutSec = 14400  # max wait for the single-file download (seconds)
    qbitHost             = ""     # blank = autodetect qBittorrent WebUI (qBittorrent.ini port, else :8075)
    qbitUser             = ""     # only needed if WebUI\LocalHostAuth is enabled
    qbitPass             = ""
    ps2GameIndexPath     = ""     # blank = autodetect PCSX2 GameIndex.yaml (serial resolution for the dlps2tex handoff)
    jobKeepDays          = 7      # prune finished job files + logs after this many days
})

# Publish the section so every module's Get-CfgValue (Common.ps1) reads the same config
# without it being threaded through signatures that do not otherwise need it.
Set-DlromConfig $cfg

if ($MaxResults -eq 0) { $MaxResults = [int](Get-CfgValue 'maxResults' 10) }
$script:MOTRIX_URL = Get-CfgValue 'motrixRpcUrl' $script:DEFAULT_MOTRIX_RPC
$tempDir           = Get-CfgValue 'tempDir' (Join-Path $env:TEMP 'dlrom')

# AB Download Manager settings (resolved before downloader selection)
$script:AB_PORT    = [int](Get-CfgValue 'abPort' $script:DEFAULT_AB_PORT)
$script:AB_TIMEOUT = [int](Get-CfgValue 'abTimeoutSec' 1800)
$abDirCfg          = Get-CfgValue 'abDownloadDir' ''
$script:AB_DOWNLOAD_DIR = if ($abDirCfg) { $abDirCfg } else { Join-Path $env:USERPROFILE 'Downloads\ABDM' }

# ---------------------------------------------------------------------------
# Worker mode (internal). Runs the slow half of a job that the parent already
# resolved, with nothing but a log file for company.
# ---------------------------------------------------------------------------
if ($JobFile) {
    $script:LOG_HEADLESS = $true
    $script:LOG_QUIET    = $false   # nobody is reading stdout; the log wants everything

    if (-not (Test-Path $JobFile)) { Write-Log "Worker: job file not found: $JobFile" 'ERROR'; exit 1 }
    $job = Get-Content -LiteralPath $JobFile -Raw | ConvertFrom-Json

    # Claim the job: our own pid is what --status checks for liveness, and recording it here
    # (rather than in the spawning parent) keeps the file single-writer from now on.
    $job.status    = $script:JOB_STATUS_RUNNING
    $job.pid       = $PID
    $job.startedAt = (Get-UtcStamp)
    Save-DlromJob -Job $job

    $script:DOWNLOADER = Find-Downloader
    Write-Log "Worker started for job $($job.id) [$($job.kind)] using $script:DOWNLOADER" 'INFO'

    $ok = $false
    try {
        if ($job.kind -eq $script:JOB_KIND_TORRENT) {
            # The qbit wait loop reports through Write-ProgressLine; map it onto the job.
            $script:JOB_PROGRESS_CB = {
                param($Percent, $Line)
                if ($Percent -lt 0) { return }
                $job.step       = 'downloading'
                $job.progress   = 5 + [int](85 * ($Percent / 100.0))
                $job.lastUpdate = (Get-UtcStamp)
                Save-DlromJob -Job $job
            }.GetNewClosure()

            $ok = Invoke-Ps2TorrentFallback -Query $job.query -Region $job.region `
                    -Destination $job.romsBase -Cfg $cfg -NoExtract:$job.noExtract `
                    -NoSteam:$job.noSteam -PickIndex $job.torrentPick -Reason $job.reason -Job $job
        } else {
            $ok = Invoke-RomPipeline -Job $job -Cfg $cfg -TempDir $tempDir
        }
        Complete-DlromJob -Job $job -Ok ([bool]$ok) `
            -Message $(if ($ok) { 'Installed' } else { 'Nothing was installed' })
    } catch {
        Write-Log "Worker failed: $($_.Exception.Message)" 'ERROR'
        Write-Log $_.ScriptStackTrace 'DEBUG'
        Complete-DlromJob -Job $job -Ok $false -Message $_.Exception.Message
    } finally {
        $script:JOB_PROGRESS_CB = $null
    }

    Write-Log "Worker finished for job $($job.id): $($job.status)" $(if ($ok) { 'SUCCESS' } else { 'ERROR' })
    exit $(if ($ok) { 0 } else { 1 })
}

# ---------------------------------------------------------------------------
# Parent mode: search, resolve links, then hand the download off.
# ---------------------------------------------------------------------------
if (-not $Query) {
    Write-Log "No game name given." 'ERROR'
    Write-Log 'Usage: dlrom "Game Name" [--platform ps2] | dlrom --status <jobId> | dlrom --list' 'INFO'
    exit 1
}

Remove-OldDlromJobs -KeepDays ([int](Get-CfgValue 'jobKeepDays' 7))

$script:DOWNLOADER = Find-Downloader

$downloaderLabel = $script:DOWNLOADER_LABELS[$script:DOWNLOADER]
if (-not $downloaderLabel) { $downloaderLabel = $script:DOWNLOADER }
if ($script:DOWNLOADER -eq $script:DL_AB) { $downloaderLabel += " (port $script:AB_PORT)" }
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
$script:PS2_FALLBACK = ([bool](Get-CfgValue 'ps2TorrentEnabled' $true) -and -not $NoTorrent -and -not $LinksOnly -and
    (($resolvedSlug -eq 'ps2-iso') -or ($Platform -and $Platform.ToLower() -eq 'ps2')))

# Announce a spawned job in the shape agents and humans both read: the id first, then
# how to follow it. Mirrors ps2tex's spawn output.
function Write-DlromJobSpawned {
    param([PSCustomObject]$Job)
    Write-Host ""
    Write-Host "Download job spawned.  It will continue in the background." -ForegroundColor Green
    Write-Host "  Job ID:   $($Job.id)" -ForegroundColor Yellow
    Write-Host "  Source:   $($Job.kind)"
    if ($Job.title) { Write-Host "  Title:    $($Job.title)" }
    Write-Host "  Dest:     $($Job.romDest)"
    Write-Host "  Log:      $($Job.logFile)"
    Write-Host "  Check:    dlrom --status $($Job.id)"
    Write-Host ""
    if ($Json) {
        $Job | ConvertTo-Json -Depth 8
    }
}

# Every Repo dead-end funnels through here: report the real reason, try the
# PS2 torrent fallback when eligible, and only then exit with the original code.
function Invoke-RgtFallbackOrExit {
    param([string]$ReasonCode, [string]$ReasonText, [int]$ExitCode)
    if ($ReasonText) { Write-Log $ReasonText 'WARN' }
    if ($script:PS2_FALLBACK) {
        $job = New-DlromJob -Kind $script:JOB_KIND_TORRENT -Query $Query -Platform 'ps2' -Region $Region `
                 -RomsBase $Destination -Reason $ReasonCode -TorrentPick $TorrentPick `
                 -NoExtract:$NoExtract -NoSteam:$NoSteam

        if (-not $Wait) {
            # The archive match + selective download is the same multi-hour job as any
            # other; background it rather than pinning the caller for four hours.
            try {
                Start-DlromJob -Job $job | Out-Null
                Write-DlromJobSpawned -Job $job
                exit 0
            } catch {
                Write-Log "Could not spawn torrent fallback worker: $($_.Exception.Message)" 'ERROR'
                exit 1
            }
        }

        Save-DlromJob -Job $job -Strict
        $ok = $false
        try {
            $ok = Invoke-Ps2TorrentFallback -Query $Query -Region $Region -Destination $Destination `
                    -Cfg $cfg -NoExtract:$NoExtract -NoSteam:$NoSteam -PickIndex $TorrentPick `
                    -Reason $ReasonCode -Job $job
        } catch {
            Write-Log "Torrent fallback error: $($_.Exception.Message)" 'ERROR'
        }
        Complete-DlromJob -Job $job -Ok ([bool]$ok)
        if ($ok) { Write-Log "All done (PS2 torrent fallback)." 'SUCCESS'; exit 0 }
        Write-Log "PS2 torrent fallback did not install anything." 'WARN'
    } elseif (($resolvedSlug -eq 'ps2-iso') -or ($Platform -and $Platform.ToLower() -eq 'ps2')) {
        if ($NoTorrent)             { Write-Log "PS2 torrent fallback skipped (--no-torrent)." 'INFO' }
        elseif (-not (Get-CfgValue 'ps2TorrentEnabled' $true)) { Write-Log "PS2 torrent fallback disabled in config." 'INFO' }
    } else {
        Write-Log "Tip: pass --platform ps2 to enable the torrent fallback for PS2 games." 'INFO'
    }
    exit $ExitCode
}

# Search
Write-Log "Searching for: $Query" 'INFO'
$results = @()
try {
    $results = @(Invoke-RgtSearch -SearchQuery $Query -PlatformSlug $resolvedSlug -SearchRegion $Region -SearchSort $Sort)
} catch {
    $reason = Get-RgtFailureReason $_.Exception.Message
    Write-Log "RetroGameTalk search failed: $($reason.Text)" 'ERROR'
    Invoke-RgtFallbackOrExit -ReasonCode $reason.Code -ReasonText $null -ExitCode 1
}

if ($results.Count -eq 0) {
    Write-Log "No results found on RetroGameTalk for: $Query" 'WARN'
    Invoke-RgtFallbackOrExit -ReasonCode 'no-results' -ReasonText $null -ExitCode 0
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
    # Edition-aware auto-select: prefer the base game over an edition (FES, ...)
    # and the requested region, but always pick something.
    $selected = Select-RgtResult -Results $displayResults -Query $Query -Region $Region
    if (-not $selected) { $selected = $displayResults[0] }
    Write-Log "Auto-selecting: $($selected.Title)" 'INFO'
}

# Get download links (reveals the "Show Links" table)
Write-Log "Fetching download links for: $($selected.Title)" 'DEBUG'
$allLinks = @(Get-RgtDownloadLinks -GamePageUrl $selected.Url)

if ($allLinks.Count -eq 0) {
    Write-Log "No download links found on the game page." 'ERROR'
    $debugPath = Join-Path $env:TEMP "dlrom-debug.html"
    try {
        $dbgResp = Invoke-RgtWeb -Uri $selected.Url
        $dbgResp.Content | Set-Content $debugPath -Encoding UTF8
        Write-Log "Debug HTML saved to: $debugPath" 'WARN'
    } catch { }
    Invoke-RgtFallbackOrExit -ReasonCode 'no-links' -ReasonText $null -ExitCode 1
}

Write-Log "Found $($allLinks.Count) raw link(s) on page." 'DEBUG'
$selectedLinks = @(Select-DownloadLinks -Links $allLinks)

if ($selectedLinks.Count -eq 0) {
    Write-Log "No suitable links after filtering (demos removed, nothing left)." 'ERROR'
    Invoke-RgtFallbackOrExit -ReasonCode 'no-suitable-links' -ReasonText $null -ExitCode 1
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
#   4. manual prompt          last resort, and only with a human watching
$romsBase = $null
if ($Destination) {
    $romsBase = $Destination
} elseif ((Get-CfgValue 'romsBase' '') -and (Test-Path (Get-CfgValue 'romsBase' ''))) {
    $romsBase = Get-CfgValue 'romsBase' ''
    Write-Log "ROMs base: $romsBase" 'DEBUG'
} else {
    $configuredBase = Get-CfgValue 'romsBase' ''
    if ($configuredBase) {
        Write-Log "Configured ROMs base not available: $configuredBase - falling back to drive picker." 'WARN'
    }
    try {
        $romsBase = Resolve-MediaPath -MediaType 'rom' -Strict
        Write-Log "Drive picker selected ROMs base: $romsBase" 'INFO'
    } catch {
        Write-Log "No connected drive advertises a ROM path ($($_.Exception.Message))." 'DEBUG'
        # Prompting is only safe when a human asked to be asked. An agent or a scheduled
        # run has no console, so this would block forever on a prompt nobody can see --
        # tell the caller how to fix it instead.
        if (-not $Interactive) {
            Write-Log "Cannot resolve a ROMs base directory and there is no console to ask." 'ERROR'
            Write-Log "Fix with one of:" 'ERROR'
            Write-Log "  dlrom `"$Query`" --dest <path>" 'ERROR'
            Write-Log "  set romsBase in $env:LOCALAPPDATA\dlScripts\config.json" 'ERROR'
            Write-Log "  connect a drive that advertises a rom_path, or re-run with --interactive" 'ERROR'
            exit 1
        }
        Write-Host "Enter ROMs base path (or press Enter for $HOME\Emulation\roms): " -NoNewline
        $alt = Read-Host
        $romsBase = if ($alt) { $alt } else { Join-Path $HOME "Emulation\roms" }
    }
}

$romDest      = Join-Path $romsBase $platformFolder
$resultRegion = if ($Region) { $Region } else { @(Get-RgtRegions $selected.Url $selected.Title)[0] }

$job = New-DlromJob -Kind $script:JOB_KIND_WEB -Query $Query -Title $selected.Title `
        -Platform $platformFolder -Region $resultRegion -RomsBase $romsBase -RomDest $romDest `
        -Links $selectedLinks -SourceUrl $selected.Url `
        -NoExtract:$NoExtract -NoSteam:$NoSteam

# Default: hand the download to a detached worker and return now. ROM downloads run for
# minutes to hours, and holding the caller (usually an agent) hostage for that is the
# whole reason this exists. --wait opts back into the old blocking behaviour.
if (-not $Wait) {
    try {
        Start-DlromJob -Job $job | Out-Null
    } catch {
        Write-Log "Could not spawn worker: $($_.Exception.Message)" 'ERROR'
        Write-Log "Run with --wait to download in the foreground instead." 'WARN'
        exit 1
    }
    Write-DlromJobSpawned -Job $job
    exit 0
}

# --wait: same pipeline, same job file, just in this process where you can watch it.
Save-DlromJob -Job $job -Strict
$ok = $false
try {
    $ok = Invoke-RomPipeline -Job $job -Cfg $cfg -TempDir $tempDir
    Complete-DlromJob -Job $job -Ok ([bool]$ok)
} catch {
    Complete-DlromJob -Job $job -Ok $false -Message $_.Exception.Message
    Write-Log "Failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}

if (-not $ok) { Write-Log "Nothing was installed." 'WARN'; exit 1 }
Write-Log "All done." 'SUCCESS'
exit 0
