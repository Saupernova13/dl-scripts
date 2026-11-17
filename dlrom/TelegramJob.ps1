# The worker half of a Telegram ROM job, and getting a stuck one going again.
#
# TelegramSource.ps1 fetches the .torrent, hands it to qBittorrent and records the job. The
# worker here waits for the whole torrent, takes it out of qBittorrent when the job owns it,
# files the content per its console rule (TorrentInstall.ps1) and adds it to Steam.
#
# A worker that dies, or a torrent that stalls, leaves the job orphaned or failed with a
# resumable reason; --resume (or auto-resume on the next download) starts a new worker, which
# simply goes back to waiting on the same torrent.

# Wait for the torrent, install it, sync Steam, record the outcome. Completes the job itself
# (the message carries the manual note or the failure reason). Returns $true when installed.
function Invoke-TelegramJob {
    param([Parameter(Mandatory)]$Job, $Cfg = $null)

    $Job.status    = $script:JOB_STATUS_RUNNING
    $Job.pid       = $PID
    $Job.startedAt = (Get-UtcStamp)
    Save-DlromJob -Job $Job

    # The qBittorrent wait reports through Write-ProgressLine; map it onto the job.
    $script:TG_JOB = $Job
    $script:JOB_PROGRESS_CB = { param($Percent, $Line) Set-TelegramJobProgress -Percent $Percent }

    try {
        $info   = Wait-TelegramJobTorrent -Job $Job -Cfg $Cfg
        $result = Install-TelegramJobContent -Job $Job -Info $info
        Sync-TelegramJobSteam -Job $Job -Result $result -Cfg $Cfg

        $note = [string]$result.ManualNote
        # Records from before the field existed have no such property to assign.
        Add-Member -InputObject $Job -NotePropertyName manualNote -NotePropertyValue $note -Force
        Complete-DlromJob -Job $Job -Ok $true -Message $(if ($note) { "Installed - manual step: $note" } else { 'Installed' })
        return $true
    } catch {
        Write-Log "Telegram job failed: $($_.Exception.Message)" 'ERROR'
        Complete-DlromJob -Job $Job -Ok $false -Message $_.Exception.Message
        return $false
    } finally {
        $script:JOB_PROGRESS_CB = $null
        $script:TG_JOB = $null
    }
}

# The running worker's job, for the progress and step callbacks (plain scriptblocks, no closures).
$script:TG_JOB = $null

# Download percent 0..100 -> job progress 5..90.
function Set-TelegramJobProgress {
    param([int]$Percent)
    $job = $script:TG_JOB
    if (-not $job -or $Percent -lt 0) { return }
    $job.step       = $script:JOB_STEP_DOWNLOADING
    $job.progress   = 5 + [int](85 * ($Percent / 100.0))
    $job.lastUpdate = (Get-UtcStamp)
    Save-DlromJob -Job $job
}

# A strategy reached a step: extracting or filing.
function Set-TelegramJobStep {
    param([string]$Step)
    if (-not $script:TG_JOB) { return }
    $pct = switch ($Step) { 'extracting' { 91 } 'filing' { 93 } default { -1 } }
    Update-DlromJob -Job $script:TG_JOB -Step $Step -Progress $pct
}

# Connect to qBittorrent (never launching it) and wait for the job's torrent. Returns its info.
function Wait-TelegramJobTorrent {
    param($Job, $Cfg = $null)
    if (-not (Initialize-DlromQbit)) {
        throw "qBittorrent is not reachable at $($script:QBIT_BASE) - start it, then run: dlrom --resume $($Job.id)"
    }
    $hash = [string]$Job.torrent.hash
    if (-not $hash) { throw 'The job has no torrent hash.' }
    Update-DlromJob -Job $Job -Step $script:JOB_STEP_DOWNLOADING
    return (Wait-QbitTorrent -Hash $hash `
            -OwnsTorrent:(-not [bool]$Job.torrent.alreadyPresent) `
            -TimeoutSec ([int](Get-CfgValue 'telegramTorrentTimeoutSec' 86400 -Cfg $Cfg)) `
            -StallTimeoutSec ([double](Get-CfgValue 'telegramStallTimeoutSec' 3600 -Cfg $Cfg)))
}

# File the finished torrent. A torrent the job added is released from qBittorrent first and
# moved; one the user already had is copied and left seeding. Throws when nothing was installed.
function Install-TelegramJobContent {
    param($Job, $Info)

    $content = [string]$Info.content_path
    if (-not $content -or -not (Test-Path -LiteralPath $content)) { throw "The torrent's content is not on disk: $content" }
    # A torrent added without a root folder reports its whole save folder as its content.
    if ($Info.save_path -and (Get-TorrentFullPath $content) -eq (Get-TorrentFullPath ([string]$Info.save_path))) {
        throw "The torrent has no folder of its own ($content); refusing to file a whole download folder."
    }

    $owned = -not [bool]$Job.torrent.alreadyPresent
    $mode  = if ($owned) { 'move' } else { 'copy' }
    $work  = Join-DlPath $Job.romsBase $script:TGSRC_STAGING_DIR "$($Job.id)-work"
    $onStep = { param($Step) Set-TelegramJobStep -Step $Step }

    if ($owned) {
        # Release the data first: qBittorrent must not hold files that are about to move.
        Write-Log 'Releasing the torrent from qBittorrent (data kept).' 'INFO'
        Remove-QbitTorrent -Hash ([string]$Job.torrent.hash)
    } else {
        Write-Log 'This torrent was already in qBittorrent; copying and leaving it as it is.' 'INFO'
    }

    $result = Invoke-TorrentInstall -ContentPath $content -RomDest ([string]$Job.romDest) -Title ([string]$Job.title) `
                -Folder ([string]$Job.torrent.platformFolder) -Mode $mode -WorkDir $work -OnStep $onStep
    if (@($result.Installed).Count -eq 0) {
        $where = if ($owned) { " The downloaded data was left in $content" } else { '' }
        throw "$($result.Reason)$where"
    }
    foreach ($p in @($result.Installed)) { Update-DlromJob -Job $Job -InstalledPath $p }

    if ($owned) {
        foreach ($dir in @($content, $work, [string]$Job.torrent.savePath, (Join-DlPath $Job.romsBase $script:TGSRC_STAGING_DIR))) {
            Remove-EmptyDirectory $dir
        }
    }
    return $result
}

function Get-TorrentFullPath {
    param([string]$Path)
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
}

# Add the console folder to Steam when the rule has a parser for it and nothing opts out.
function Sync-TelegramJobSteam {
    param($Job, $Result, $Cfg = $null)
    if (-not $Result.SteamSync) { return }
    if ($Job.noSteam) { Write-Log 'Skipping Steam sync (--no-steam).' 'INFO'; return }
    if (-not [bool](Get-CfgValue 'steamSync' $true -Cfg $Cfg)) { return }
    Update-DlromJob -Job $Job -Step $script:JOB_STEP_STEAM_SYNC -Progress 95 -Message 'Adding to Steam'
    try {
        Sync-RomToSteam -RomDest ([string]$Job.romDest) -RomsBase ([string]$Job.romsBase) -InstalledCount @($Result.Installed).Count
    } catch {
        # The ROM is installed; Steam is a nice-to-have.
        Write-Log "Steam sync failed: $($_.Exception.Message)" 'WARN'
    }
}

# --- Resume -----------------------------------------------------------------------------------

function Get-TelegramJobs {
    $jobs = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (Get-DlromJobsDir) -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $j = Read-DlromJob ([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
        if ($j -and $j.kind -eq $script:JOB_KIND_TELEGRAM) { $jobs += $j }
    }
    return @($jobs)
}

# Why --resume refuses this job, or '' when it may go ahead.
function Get-TelegramResumeRefusal {
    param($Job)
    if ($Job.kind -ne $script:JOB_KIND_TELEGRAM) { return "Job $($Job.id) is not a Telegram job; only those can be resumed." }
    $status = Resolve-DlromJobStatus $Job
    if ($status -eq $script:JOB_STATUS_COMPLETED) { return "Job $($Job.id) is already completed; nothing to resume." }
    if ($status -in $script:JOB_STATUS_ACTIVE)    { return "Job $($Job.id) is still $status; nothing to resume." }
    if (-not (Test-TelegramJobResumable $Job))    { return "Job $($Job.id) failed and a retry would not help: $($Job.message)" }
    return ''
}

# Start a fresh worker for the job (detached, or inline with -Wait). Returns $true when it ran
# inline and installed, or when the detached worker was started.
function Start-TelegramJobResume {
    param($Job, [switch]$Wait, $Cfg = $null)
    $Job.status      = $script:JOB_STATUS_PENDING
    $Job.pid         = 0
    $Job.message     = 'Resumed'
    $Job.completedAt = ''
    $Job.lastUpdate  = (Get-UtcStamp)
    Save-DlromJob -Job $Job -Strict
    if ($Wait) { return [bool](@(Invoke-TelegramJob -Job $Job -Cfg $Cfg) | Select-Object -Last 1) }
    [void](Start-DlromJob -Job $Job)
    return $true
}

# dlrom --resume <jobId|all>. Returns the exit code.
function Invoke-DlromResume {
    param([string]$Id, [switch]$Wait, [switch]$AsJson, $Cfg = $null)

    $targets = @()
    $error1  = ''
    if ($Id -eq 'all') {
        $targets = @(Get-TelegramJobs | Where-Object { Test-TelegramJobResumable $_ })
    } else {
        $job = Read-DlromJob $Id
        if (-not $job)      { $error1 = "Unknown job: $Id" }
        else {
            $error1 = Get-TelegramResumeRefusal $job
            if (-not $error1) { $targets = @($job) }
        }
    }

    $resumed = @(); $failed = @()
    if ($error1) { Write-Log $error1 'ERROR' }
    elseif ($targets.Count -eq 0) { Write-Log 'No Telegram jobs need resuming.' 'INFO' }
    foreach ($t in $targets) {
        Write-Log "Resuming job $($t.id): $($t.title)" 'INFO'
        try {
            if (Start-TelegramJobResume -Job $t -Wait:$Wait -Cfg $Cfg) { $resumed += $t.id } else { $failed += $t.id }
        } catch {
            Write-Log "Could not resume $($t.id): $($_.Exception.Message)" 'ERROR'
            $failed += $t.id
        }
    }

    if ($AsJson) {
        Write-Host (@{ ok = (-not $error1 -and $failed.Count -eq 0); resumed = $resumed; failed = $failed; error = $error1; wait = [bool]$Wait } |
            ConvertTo-Json -Depth 4)
    } elseif ($resumed.Count -gt 0 -and -not $Wait) {
        foreach ($rid in $resumed) { Write-Log "Worker started for $rid. Check: dlrom --status $rid" 'SUCCESS' }
    }
    return $(if ($error1 -or $failed.Count -gt 0) { 1 } else { 0 })
}

# Before a normal download: restart Telegram jobs whose worker died. Orphaned only (a failed
# job is the user's to retry). Reads job files and starts workers; no qBittorrent call here.
# Returns how many were resumed.
function Invoke-TelegramAutoResume {
    param($Cfg = $null)
    if (-not [bool](Get-CfgValue 'telegramAutoResume' $true -Cfg $Cfg)) { return 0 }
    $n = 0
    foreach ($job in @(Get-TelegramJobs)) {
        if ((Resolve-DlromJobStatus $job) -ne $script:JOB_STATUS_ORPHANED) { continue }
        Write-Log "Resuming orphaned Telegram job $($job.id): $($job.title)" 'INFO'
        try { [void](Start-TelegramJobResume -Job $job -Cfg $Cfg); $n++ }
        catch { Write-Log "Could not resume $($job.id): $($_.Exception.Message)" 'WARN' }
    }
    return $n
}
