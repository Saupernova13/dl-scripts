# Numbers for dltv's KissKH jobs: size, speed and ETA formatting, the speed estimator, the
# drive a download lands on, and the qBittorrent-shaped status record that `--status --json`
# and `--jobs --json` print. Pure helpers wherever possible, so they are unit-testable.
#
# Needs lib/Platform.ps1 loaded first. DriveResolver.ps1 supplies Get-DriveMetaInventory (optional).

# --- Formatting ---------------------------------------------------------------

function Format-DltvSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return "$Bytes B"
}

function Format-DltvSpeed {
    param([double]$BytesPerSec)
    if ($BytesPerSec -ge 1MB) { return ('{0:N1} MB/s' -f ($BytesPerSec / 1MB)) }
    if ($BytesPerSec -ge 1KB) { return ('{0:N0} KB/s' -f ($BytesPerSec / 1KB)) }
    return ('{0:N0} B/s' -f $BytesPerSec)
}

# 45s | 14m | 1h 05m
function Format-DltvDuration {
    param([double]$Seconds)
    $s = [int][Math]::Max(0, [Math]::Round($Seconds))
    if ($s -lt 60)   { return "${s}s" }
    if ($s -lt 3600) { return ('{0}m' -f [int][Math]::Floor($s / 60)) }
    return ('{0}h {1:D2}m' -f [int][Math]::Floor($s / 3600), [int][Math]::Floor(($s % 3600) / 60))
}

# --- Speed and ETA ------------------------------------------------------------

# Exponential moving average of throughput over roughly -Window seconds. -Previous <= 0 seeds
# the average with the first sample.
function Get-DltvEmaSpeed {
    param([double]$Previous, [double]$Instant, [double]$Dt, [double]$Window = 10)
    if ($Dt -le 0) { return $Previous }
    if ($Previous -le 0) { return $Instant }
    $alpha = 1 - [Math]::Exp(-$Dt / $Window)
    return ($alpha * $Instant + (1 - $alpha) * $Previous)
}

# Seconds left, or $null when there is no speed to extrapolate from.
function Get-DltvEta {
    param([double]$RemainingBytes, [double]$SpeedBps)
    if ($SpeedBps -le 0 -or $RemainingBytes -lt 0) { return $null }
    return [int][Math]::Ceiling($RemainingBytes / $SpeedBps)
}

# --- Drive --------------------------------------------------------------------

# Where a path lives: drive letter (or mount root), the drive-registry's name for it, and free
# space. Every part fails soft to an empty value.
function Get-DltvDriveInfo {
    param([string]$Path)
    $info = [PSCustomObject]@{ drive = ''; driveName = ''; freeGB = $null }
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root) { return $info }
        $info.drive = $root.TrimEnd('\', '/')
        if ($info.drive -eq '') { $info.drive = '/' }
    } catch { return $info }

    try {
        $di = New-Object System.IO.DriveInfo($root)
        $info.freeGB = [Math]::Round($di.AvailableFreeSpace / 1GB, 1)
    } catch { }

    if ($info.drive -match '^([A-Za-z]):$') {
        try {
            $letter = $Matches[1].ToUpperInvariant()
            $match = @(Get-DriveMetaInventory) | Where-Object { ([string]$_.letter).ToUpperInvariant() -eq $letter } | Select-Object -First 1
            if ($match -and $match.meta -and $match.meta.drive_name) { $info.driveName = [string]$match.meta.drive_name }
        } catch { }
    }
    return $info
}

# --- Status record ------------------------------------------------------------

# A job-file field, tolerating records written before the field existed.
function Get-DltvField {
    param($Obj, [string]$Name, $Default = $null)
    $p = $Obj.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    return $Default
}

# The job as the agent reads it for torrents from qBittorrent's /torrents/info: progress is
# 0-1, sizes in bytes and GB, dlspeed in bytes/s, eta in seconds. -Status overrides the stored
# status (orphan detection resolves it first).
function ConvertTo-DltvStatusObject {
    param($Job, [string]$Status)
    if (-not $Status) { $Status = [string]$Job.status }
    $active = ($Status -eq 'running' -or $Status -eq 'pending')

    $total = [long](Get-DltvField $Job 'totalBytes' 0)
    $done  = [long](Get-DltvField $Job 'doneBytes' 0)
    $epsTotal = [int](Get-DltvField $Job 'total' 0)
    $epsDone  = [int](Get-DltvField $Job 'done' 0)
    $progress = 0.0
    if ($Status -eq 'completed') { $progress = 1.0 }
    elseif ($total -gt 0)        { $progress = [Math]::Min(1.0, [double]$done / [double]$total) }
    elseif ($epsTotal -gt 0)     { $progress = [double]$epsDone / [double]$epsTotal }

    $speed = 0L
    $eta = $null
    if ($active) {
        $speed = [long](Get-DltvField $Job 'speedBps' 0)
        $e = Get-DltvField $Job 'etaSec' $null
        if ($null -ne $e -and [int]$e -gt 0) { $eta = [int]$e }
    }
    $cur = Get-DltvField $Job 'current' $null
    $curProg = 0.0
    if ($cur -and $active) { $curProg = [double](Get-DltvField $Job 'currentProgress' 0) }
    $free = Get-DltvField $Job 'freeGB' $null
    $estimated = Get-DltvField $Job 'estimatedBytes' $null

    return [PSCustomObject]([ordered]@{
        id                     = [string]$Job.id
        status                 = $Status
        source                 = 'kisskh'
        name                   = [string]$Job.title
        country                = [string](Get-DltvField $Job 'country' '')
        showStatus             = [string](Get-DltvField $Job 'showStatus' '')
        progress               = [Math]::Round($progress, 4)
        doneBytes              = $done
        totalBytes             = $total
        doneGB                 = [Math]::Round($done / 1GB, 2)
        totalGB                = [Math]::Round($total / 1GB, 2)
        sizeExact              = [bool](Get-DltvField $Job 'sizeExact' $false)
        dlspeed                = $speed
        speedMBps              = [Math]::Round($speed / 1MB, 2)
        eta                    = $eta
        episodesDone           = $epsDone
        episodesTotal          = $epsTotal
        currentEpisode         = $(if ($cur -and $active) { [int]$cur } else { $null })
        currentEpisodeProgress = [Math]::Round($curProg, 4)
        savePath               = [string]$Job.destination
        drive                  = [string](Get-DltvField $Job 'drive' '')
        driveName              = [string](Get-DltvField $Job 'driveName' '')
        freeGB                 = $(if ($null -ne $free) { [double]$free } else { $null })
        failed                 = @(Get-DltvField $Job 'failed' @())
        notReleased            = @(Get-DltvField $Job 'notReleased' @())
        message                = [string](Get-DltvField $Job 'message' '')
        createdAt              = [string](Get-DltvField $Job 'createdAt' '')
        startedAt              = [string](Get-DltvField $Job 'startedAt' '')
        completedAt            = [string](Get-DltvField $Job 'completedAt' '')
        lastUpdate             = [string](Get-DltvField $Job 'lastUpdate' '')
    })
}
