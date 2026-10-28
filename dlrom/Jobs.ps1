# Background job lifecycle for dlrom: persist a job to JSON, spawn a detached worker,
# and read job state back for --status / --list.
#
# Mirrors ps2tex's JobService on purpose: both tools are driven by the same agents, so a job
# id means the same thing in both.
#
# Job files live in %LOCALAPPDATA%\dlScripts\jobs\rom\<id>.json, the worker's console output
# beside them in <id>.log.

function Get-DlromJobsDir {
    return (Get-DlScriptsDataDir 'jobs\rom')
}

function Get-DlromJobPath {
    param([string]$JobId)
    return (Join-Path (Get-DlromJobsDir) "$JobId.json")
}

function Get-DlromJobLogPath {
    param([string]$JobId)
    return (Join-Path (Get-DlromJobsDir) "$JobId.log")
}

# Progress writes happen every couple of seconds, so a transient sharing violation (a
# --status reader holding the file) must never kill the download - a failed save is a lost
# progress tick, nothing more.
function Save-DlromJob {
    param([PSCustomObject]$Job, [switch]$Strict)
    $path = Get-DlromJobPath $Job.id
    try {
        $Job | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
    } catch {
        if ($Strict) { throw }
    }
}

function Read-DlromJob {
    param([string]$JobId)
    $path = Get-DlromJobPath $JobId
    if (-not (Test-Path $path)) { return $null }
    try   { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch { return $null }
}

# Stamp a progress update onto the job and flush it. Only the named fields change, so a
# worker can report a step without restating everything it already knows.
function Update-DlromJob {
    param(
        [PSCustomObject]$Job,
        [string]$Status,
        [string]$Step,
        [int]$Progress = -1,
        [string]$Message,
        [string]$InstalledPath
    )
    if ($Status)        { $Job.status  = $Status }
    if ($Step)          { $Job.step    = $Step }
    if ($Progress -ge 0){ $Job.progress = $Progress }
    if ($PSBoundParameters.ContainsKey('Message')) { $Job.message = $Message }
    if ($InstalledPath) { $Job.installedPaths += $InstalledPath }
    $Job.lastUpdate = (Get-UtcStamp)
    Save-DlromJob -Job $Job
}

function New-DlromJob {
    param(
        [string]$Kind,          # JOB_KIND_WEB | JOB_KIND_TORRENT
        [string]$Query,
        [string]$Title,
        [string]$Platform,
        [string]$Region,
        [string]$RomsBase,
        [string]$RomDest,
        [array] $Links,
        [string]$SourceUrl,
        [string]$Reason,        # why the torrent fallback fired (torrent jobs only)
        [string]$VitaBuild = '', # 'emu' | 'console' for a Vita download; '' everywhere else
        [int]   $TorrentPick = -1,
        [bool]  $NoExtract = $false,
        [bool]  $NoSteam = $false
    )
    $id = New-ShortId
    return [PSCustomObject]@{
        id             = $id
        kind           = $Kind
        status         = $script:JOB_STATUS_PENDING
        step           = ''
        progress       = 0
        message        = ''
        query          = $Query
        title          = $Title
        platform       = $Platform
        region         = $Region
        romsBase       = $RomsBase
        romDest        = $RomDest
        links          = @($Links)
        sourceUrl      = $SourceUrl
        reason         = $Reason
        vitaBuild      = $VitaBuild
        torrentPick    = $TorrentPick
        noExtract      = $NoExtract
        noSteam        = $NoSteam
        installedPaths = @()
        handoff        = ''
        pid            = 0
        createdAt      = (Get-UtcStamp)
        startedAt      = ''
        completedAt    = ''
        lastUpdate     = ''
        jobFile        = (Get-DlromJobPath $id)
        logFile        = (Get-DlromJobLogPath $id)
    }
}

# Launch the worker as a detached process and return immediately.
#
# Two load-bearing details on Windows:
#   * CreateNoWindow + UseShellExecute=$false, via raw ProcessStartInfo. Start-Process
#     cannot express CreateNoWindow, so it flashes a console window.
#   * The worker must NOT inherit this console's handles, or dlrom.cmd stays attached to it
#     and the caller's terminal hangs. cmd's own `> log 2>&1` gives the worker a file for
#     stdout/stderr, and redirecting stdin (then closing it) makes a stray prompt hit EOF
#     rather than block forever.
#
# Linux needs both for a different reason: the common caller is `ssh deck 'dlrom ...'`, and
# sshd waits on any pipe the worker still holds.
#
# Escaping the dying session needs more than setsid. SteamOS sets KillUserProcesses=True, and
# logind kills the session's whole CGROUP on teardown - a new session id does not leave that
# cgroup, so a setsid'd worker dies the instant the ssh command returns, leaving the job at
# "pending" with an empty log. systemd-run --user puts it under user@1000.service instead,
# which teardown does not touch; setsid stays as the fallback where that is unavailable.
#
# To outlive the *last* session too, the user manager must persist: `loginctl enable-linger`.
function Start-DlromJob {
    param([PSCustomObject]$Job)

    $Job.status = $script:JOB_STATUS_PENDING
    Save-DlromJob -Job $Job -Strict

    $psExe     = (Get-Process -Id $PID).Path        # re-run the same PowerShell we are on
    if (-not $psExe) { $psExe = if (Test-DlWindows) { 'powershell.exe' } else { 'pwsh' } }
    $scriptPath = Join-Path $PSScriptRoot 'Add-ROM.ps1'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.CreateNoWindow         = $true
    $psi.UseShellExecute        = $false

    if (Test-DlWindows) {
        # cmd /c ""ps.exe" -File "script" -JobFile "job" > "log" 2>&1"
        $inner = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -JobFile "{2}" > "{3}" 2>&1' -f `
                    $psExe, $scriptPath, $Job.jobFile, $Job.logFile
        $psi.FileName              = 'cmd.exe'
        $psi.Arguments             = "/c `"$inner`""
        $psi.RedirectStandardInput = $true
    } else {
        # Prefer a transient user-manager unit; fall back to setsid where systemd-run or a
        # user bus is missing. A runtime probe, not an OS guess - either can be absent
        # anywhere. --collect reaps the unit on exit so no failed unit is left behind, and
        # the pid comes from `systemctl show` because the worker is a grandchild of systemd,
        # not of this shell, so $! would be the systemd-run client that exits immediately.
        $q = { param($s) "'" + ($s -replace "'", "'\''") + "'" }
        $unit    = "dlrom-$($Job.id)"
        $qLog    = & $q $Job.logFile
        $worker  = '{0} -NoProfile -File {1} -JobFile {2}' -f `
                    (& $q $psExe), (& $q $scriptPath), (& $q $Job.jobFile)

        $sdRun = "systemd-run --user --collect --quiet --unit=$unit " +
                 "--property=StandardOutput=append:$qLog " +
                 "--property=StandardError=append:$qLog " +
                 "--property=StandardInput=null $worker"

        $inner = @(
            'has_user_bus() { command -v systemd-run >/dev/null 2>&1 && [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]; }'
            "if has_user_bus && $sdRun >/dev/null 2>&1; then"
            "    systemctl --user show -p MainPID --value $unit.service 2>/dev/null"
            '    exit 0'
            'fi'
            "setsid $worker > $qLog 2>&1 < /dev/null & echo `$!"
        ) -join "`n"
        $psi.FileName               = '/bin/sh'
        $psi.ArgumentList.Add('-c')
        $psi.ArgumentList.Add($inner)
        $psi.RedirectStandardOutput = $true
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { throw "Failed to start dlrom worker process" }

    if (Test-DlWindows) {
        $proc.StandardInput.Close()
    } else {
        $workerPid = ($proc.StandardOutput.ReadLine() -as [int])
        $proc.WaitForExit()
        if ($workerPid) { return $workerPid }
    }

    # Deliberately NOT saved: the worker owns the job file from the moment it starts and
    # records its own $PID. Writing here would race it, and the worker's next update would
    # put pid back to 0, permanently blinding the orphan check.
    $Job.pid = $proc.Id   # in-memory only, for the caller to display
    return $proc.Id
}

# Stamp the terminal outcome. Called from both the worker and a --wait run, so a job file
# is a complete record either way.
function Complete-DlromJob {
    param([PSCustomObject]$Job, [bool]$Ok, [string]$Message = '')
    $Job.status = if ($Ok) { $script:JOB_STATUS_COMPLETED } else { $script:JOB_STATUS_FAILED }
    if ($Ok) { $Job.progress = 100; $Job.step = $script:JOB_STEP_DONE }
    if ($Message) { $Job.message = $Message }
    $Job.completedAt = (Get-UtcStamp)
    $Job.lastUpdate  = $Job.completedAt
    Save-DlromJob -Job $Job
}

# A worker that dies hard (killed, power cut, unhandled crash) leaves 'running' behind
# forever. If the pid is gone and nothing wrote an outcome, say so rather than lying.
function Resolve-DlromJobStatus {
    param([PSCustomObject]$Job)
    if ($Job.status -notin $script:JOB_STATUS_ACTIVE) { return $Job.status }
    if (-not $Job.pid) { return $Job.status }
    if (Get-Process -Id $Job.pid -ErrorAction SilentlyContinue) { return $Job.status }
    return $script:JOB_STATUS_ORPHANED
}

function Show-DlromJobStatus {
    param([string]$JobId, [switch]$AsJson)

    $job = Read-DlromJob $JobId
    if (-not $job) {
        if ($AsJson) {
            (@{ error = "Unknown job: $JobId"; jobId = $JobId } | ConvertTo-Json)
            return
        }
        Write-Log "Unknown job: $JobId" 'ERROR'
        Write-Log "Jobs live in $(Get-DlromJobsDir)" 'INFO'
        return
    }

    $job.status = Resolve-DlromJobStatus $job

    if ($AsJson) {
        $job | ConvertTo-Json -Depth 8
        return
    }

    Write-Host ""
    Write-Host "Job $($job.id)" -ForegroundColor Yellow
    Write-Host "  Status:     $($job.status)" -ForegroundColor Cyan
    if ($job.step)     { Write-Host "  Step:       $($job.step)" -ForegroundColor Cyan }
    if ($job.progress -gt 0) {
        $bar = Format-ProgressBar -Percent $job.progress -Empty '.'
        Write-Host "  Progress:   $bar $($job.progress)%" -ForegroundColor Cyan
    }
    Write-Host "  Source:     $($job.kind)"
    Write-Host "  Query:      $($job.query)"
    if ($job.title)    { Write-Host "  Title:      $($job.title)" }
    if ($job.platform) { Write-Host "  Platform:   $($job.platform)" }
    if ($job.vitaBuild) {
        $buildLabel = if ($script:VITA_BUILD_LABELS.ContainsKey($job.vitaBuild)) {
            $script:VITA_BUILD_LABELS[$job.vitaBuild]
        } else { $job.vitaBuild }
        Write-Host "  Build:      $buildLabel"
    }
    if ($job.reason)   { Write-Host "  Fallback:   $($job.reason)" }
    Write-Host "  Created:    $($job.createdAt)"
    if ($job.startedAt)   { Write-Host "  Started:    $($job.startedAt)" }
    if ($job.lastUpdate)  { Write-Host "  Last upd:   $($job.lastUpdate)" }
    if ($job.completedAt) { Write-Host "  Completed:  $($job.completedAt)" }
    foreach ($p in @($job.installedPaths)) { Write-Host "  Installed:  $p" }
    if ($job.message)  { Write-Host "  Message:    $($job.message)" }
    if ($job.handoff)  { Write-Host "  $($job.handoff)" -ForegroundColor Green }
    Write-Host ""

    if (Test-Path $job.logFile) {
        Write-Host "--- tail $($job.logFile) ---" -ForegroundColor DarkGray
        Get-Content -LiteralPath $job.logFile -Tail 20 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
    }
}

function Show-DlromJobList {
    param([switch]$AsJson)

    $jobs = @()
    Get-ChildItem -LiteralPath (Get-DlromJobsDir) -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $j = Read-DlromJob ([System.IO.Path]::GetFileNameWithoutExtension($_.Name))
            if ($j) { $j.status = Resolve-DlromJobStatus $j; $jobs += $j }
        }

    if ($AsJson) { return ($jobs | ConvertTo-Json -Depth 8) }

    if ($jobs.Count -eq 0) {
        Write-Log "No dlrom jobs yet." 'INFO'
        return
    }

    Write-Host ""
    Write-Host ("{0,-14}  {1,-11}  {2,-9}  {3,-8}  {4}" -f 'JOB ID', 'STATUS', 'STEP', 'PROGRESS', 'TITLE') -ForegroundColor Cyan
    Write-Host ("-" * 96) -ForegroundColor DarkGray
    foreach ($j in $jobs) {
        $color = switch ($j.status) {
            $script:JOB_STATUS_COMPLETED { 'Green'  }
            $script:JOB_STATUS_FAILED    { 'Red'    }
            $script:JOB_STATUS_ORPHANED  { 'Red'    }
            $script:JOB_STATUS_RUNNING   { 'Yellow' }
            default                      { 'Gray'   }
        }
        $title = if ($j.title) { $j.title } else { $j.query }
        if ($title.Length -gt 40) { $title = $title.Substring(0, 37) + '...' }
        Write-Host ("{0,-14}  {1,-11}  {2,-9}  {3,-8}  {4}" -f `
            $j.id, $j.status, $j.step, "$($j.progress)%", $title) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "Detail: dlrom --status <jobId>" -ForegroundColor DarkGray
    Write-Host ""
}

# Keep the jobs dir from growing without bound: drop finished jobs (and their logs)
# older than the retention window. Running jobs are never touched.
function Remove-OldDlromJobs {
    param([int]$KeepDays = 7)
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -LiteralPath (Get-DlromJobsDir) -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            $j = Read-DlromJob ([System.IO.Path]::GetFileNameWithoutExtension($_.Name))
            if ($j -and (Resolve-DlromJobStatus $j) -in $script:JOB_STATUS_ACTIVE) { return }
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $log = [System.IO.Path]::ChangeExtension($_.FullName, '.log')
            if (Test-Path $log) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
        }
}
