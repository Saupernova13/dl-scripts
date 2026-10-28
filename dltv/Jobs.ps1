# Background job lifecycle for dltv's KissKH downloads: persist a job to JSON, spawn a detached
# worker, and read job state back for --status / --jobs.
#
# Modelled on dlrom/Jobs.ps1, so a job id and a status string mean the same thing in both.
# Job files live in <data root>/dltv/jobs/<id>.json, the worker's console output beside them
# in <id>.log.
#
# Needs lib/Platform.ps1 and lib/Detach.ps1 loaded first.

# Same vocabulary as dlrom's Constants.ps1, so agents polling either tool read one set.
$script:DLTV_JOB_PENDING   = 'pending'
$script:DLTV_JOB_RUNNING   = 'running'
$script:DLTV_JOB_COMPLETED = 'completed'
$script:DLTV_JOB_FAILED    = 'failed'
$script:DLTV_JOB_ORPHANED  = 'orphaned'
# Statuses that mean a worker should still be alive; anything else is terminal.
$script:DLTV_JOB_ACTIVE = @($script:DLTV_JOB_RUNNING, $script:DLTV_JOB_PENDING)

function Get-DltvUtcStamp { return (Get-Date).ToUniversalTime().ToString('o') }

function Get-DltvJobsDir {
    $dir = Join-DlPath (Get-DlDataRoot) 'dltv/jobs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-DltvJobPath    { param([string]$JobId) return (Join-Path (Get-DltvJobsDir) "$JobId.json") }
function Get-DltvJobLogPath { param([string]$JobId) return (Join-Path (Get-DltvJobsDir) "$JobId.log") }

# Progress writes happen after every episode, so a transient sharing violation (a --status
# reader holding the file) must never kill the download - a failed save is a lost progress
# tick, nothing more.
function Save-DltvJob {
    param([PSCustomObject]$Job, [switch]$Strict)
    try {
        $json = $Job | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($Job.jobFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        if ($Strict) { throw }
    }
}

function Read-DltvJobFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try   { return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) }
    catch { return $null }
}

function Read-DltvJob {
    param([string]$JobId)
    return (Read-DltvJobFile (Get-DltvJobPath $JobId))
}

function New-DltvJob {
    param(
        [string]$Title,
        [long]  $DramaId,
        [string]$BaseUrl,
        [string]$Destination,       # series folder the episodes land in
        [object[]]$Episodes,        # @{ Id; Number } records
        [string[]]$SubLangs,
        [double]$MaxEpisodeGB = 8   # abort an episode whose output passes this
    )
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    return [PSCustomObject]@{
        id          = $id
        source      = 'kisskh'
        status      = $script:DLTV_JOB_PENDING
        title       = $Title
        dramaId     = $DramaId
        baseUrl     = $BaseUrl
        destination = $Destination
        subLangs    = @($SubLangs)
        maxEpisodeGB = $MaxEpisodeGB
        episodes    = @($Episodes | ForEach-Object { [PSCustomObject]@{ id = [long]$_.Id; number = [int]$_.Number } })
        total       = @($Episodes).Count
        done        = 0
        failed      = @()
        current     = ''
        message     = ''
        pid         = 0
        createdAt   = (Get-DltvUtcStamp)
        startedAt   = ''
        completedAt = ''
        lastUpdate  = ''
        jobFile     = (Get-DltvJobPath $id)
        logFile     = (Get-DltvJobLogPath $id)
    }
}

# Stamp a progress update onto the job and flush it.
function Update-DltvJob {
    param([PSCustomObject]$Job, [string]$Status, [string]$Current, [string]$Message)
    if ($Status) { $Job.status = $Status }
    if ($PSBoundParameters.ContainsKey('Current')) { $Job.current = $Current }
    if ($PSBoundParameters.ContainsKey('Message')) { $Job.message = $Message }
    $Job.lastUpdate = (Get-DltvUtcStamp)
    Save-DltvJob -Job $Job
}

# Stamp the terminal outcome. 'failed' only when zero episodes succeeded.
function Complete-DltvJob {
    param([PSCustomObject]$Job, [string]$Message = '')
    $Job.status = if ($Job.done -gt 0) { $script:DLTV_JOB_COMPLETED } else { $script:DLTV_JOB_FAILED }
    $Job.current = ''
    if ($Message) { $Job.message = $Message }
    $Job.completedAt = (Get-DltvUtcStamp)
    $Job.lastUpdate  = $Job.completedAt
    Save-DltvJob -Job $Job
}

# Launch the worker detached and return immediately. The worker owns the job file from the
# moment it starts and records its own $PID; writing the pid here would race it, so the
# value returned is for display only.
function Start-DltvJob {
    param([PSCustomObject]$Job, [Parameter(Mandatory)][string]$ScriptPath)
    $Job.status = $script:DLTV_JOB_PENDING
    Save-DltvJob -Job $Job -Strict
    return (Start-DlDetachedScript -ScriptPath $ScriptPath `
                -ScriptArgs @('-JobFile', $Job.jobFile) `
                -LogFile $Job.logFile -UnitName "dltv-$($Job.id)")
}

# A worker that dies hard (killed, power cut, unhandled crash) leaves 'running' behind
# forever. If the pid is gone and nothing wrote an outcome, say so rather than lying.
function Resolve-DltvJobStatus {
    param([PSCustomObject]$Job)
    if ($Job.status -notin $script:DLTV_JOB_ACTIVE) { return $Job.status }
    if (-not $Job.pid) { return $Job.status }
    if (Get-Process -Id $Job.pid -ErrorAction SilentlyContinue) { return $Job.status }
    return $script:DLTV_JOB_ORPHANED
}

function Show-DltvJobStatus {
    param([string]$JobId)
    $job = Read-DltvJob $JobId
    if (-not $job) {
        Write-Log "Unknown job: $JobId" 'ERROR'
        Write-Log "Jobs live in $(Get-DltvJobsDir)" 'INFO'
        return $false
    }
    $job.status = Resolve-DltvJobStatus $job

    Write-Host ""
    Write-Host "Job $($job.id)" -ForegroundColor Yellow
    Write-Host "  Status:     $($job.status)" -ForegroundColor Cyan
    if ($job.current) { Write-Host "  Current:    E$('{0:D2}' -f [int]$job.current)" -ForegroundColor Cyan }
    Write-Host "  Progress:   $($job.done)/$($job.total) episodes" -ForegroundColor Cyan
    Write-Host "  Title:      $($job.title)"
    Write-Host "  Folder:     $($job.destination)"
    Write-Host "  Created:    $($job.createdAt)"
    if ($job.startedAt)   { Write-Host "  Started:    $($job.startedAt)" }
    if ($job.lastUpdate)  { Write-Host "  Last upd:   $($job.lastUpdate)" }
    if ($job.completedAt) { Write-Host "  Completed:  $($job.completedAt)" }
    if ($job.message)     { Write-Host "  Message:    $($job.message)" }
    Write-Host ""

    if ($job.logFile -and (Test-Path -LiteralPath $job.logFile)) {
        Write-Host "--- tail $($job.logFile) ---" -ForegroundColor DarkGray
        Get-Content -LiteralPath $job.logFile -Tail 15 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
    }
    return $true
}

function Show-DltvJobList {
    $jobs = @()
    Get-ChildItem -LiteralPath (Get-DltvJobsDir) -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $j = Read-DltvJobFile $_.FullName
            if ($j) { $j.status = Resolve-DltvJobStatus $j; $jobs += $j }
        }

    if ($jobs.Count -eq 0) {
        Write-Log "No dltv jobs yet." 'INFO'
        return
    }

    Write-Host ""
    Write-Host ("{0,-14}  {1,-10}  {2,-9}  {3}" -f 'JOB ID', 'STATUS', 'EPISODES', 'TITLE') -ForegroundColor Cyan
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    foreach ($j in $jobs) {
        $color = switch ($j.status) {
            $script:DLTV_JOB_COMPLETED { 'Green'  }
            $script:DLTV_JOB_FAILED    { 'Red'    }
            $script:DLTV_JOB_ORPHANED  { 'Red'    }
            $script:DLTV_JOB_RUNNING   { 'Yellow' }
            default                    { 'Gray'   }
        }
        $title = [string]$j.title
        if ($title.Length -gt 36) { $title = $title.Substring(0, 33) + '...' }
        Write-Host ("{0,-14}  {1,-10}  {2,-9}  {3}" -f $j.id, $j.status, "$($j.done)/$($j.total)", $title) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "Detail: dltv --status <jobId>" -ForegroundColor DarkGray
    Write-Host ""
}

# Drop finished jobs (and their logs) older than the retention window. Active jobs are never
# touched.
function Remove-OldDltvJobs {
    param([int]$KeepDays = 7)
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -LiteralPath (Get-DltvJobsDir) -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            $j = Read-DltvJobFile $_.FullName
            if ($j -and ((Resolve-DltvJobStatus $j) -in $script:DLTV_JOB_ACTIVE)) { return }
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            $log = [System.IO.Path]::ChangeExtension($_.FullName, '.log')
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        }
}
