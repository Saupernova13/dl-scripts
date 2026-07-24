# Console logging plus the size/speed/label formatting used across dlrom.
#
# Write-Log respects two flags that Add-ROM sets from -Verbose / -Quiet:
#   $script:LOG_VERBOSE   also print DEBUG (per-step detail)
#   $script:LOG_QUIET     drop routine INFO, keep results and warnings
#
# A background worker sets a third:
#   $script:LOG_HEADLESS  no terminal is attached; stdout is a log file

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')

    # DEBUG is opt-in, INFO is opt-out; WARN/ERROR/SUCCESS always print.
    if ($Level -eq 'DEBUG' -and -not $script:LOG_VERBOSE) { return }
    if ($Level -eq 'INFO'  -and  $script:LOG_QUIET)       { return }

    $ts = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'INFO'    { 'Cyan' }
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'DEBUG'   { 'Gray' }
        default   { 'White' }
    }
    # A worker's stdout is a redirected file with no color support, and -ForegroundColor
    # against a non-console host throws. Plain text also keeps the log greppable.
    if ($script:LOG_HEADLESS) { Write-Host "[$ts] [$Level] $Message" }
    else { Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color }
}

# Live progress for the download wait loops.
#
# On a terminal this is a carriage-return overwrite, so one line animates in place. That
# is exactly wrong for a worker, whose stdout is a file: \r writes no newline, so a
# multi-GB download would land as one endless line and swamp the log tail. Headless runs
# therefore push the numbers into the job state (which is what --status reads) and emit a
# plain line only every $PROGRESS_LOG_EVERY_SEC, leaving a readable trail behind.
$script:PROGRESS_LOG_EVERY_SEC = 30
$script:JOB_PROGRESS_CB        = $null   # set by the worker: { param($Percent, $Line) ... }
$script:_lastProgressLog       = $null

function Write-ProgressLine {
    param([string]$Line, [int]$Percent = -1)

    # The job is fed regardless of who is rendering: a --wait run in one terminal should
    # still answer `dlrom --status` truthfully from another.
    if ($script:JOB_PROGRESS_CB) {
        try { & $script:JOB_PROGRESS_CB $Percent $Line } catch { }
    }

    if (-not $script:LOG_HEADLESS) {
        Write-Host "`r$Line   " -NoNewline -ForegroundColor Cyan
        return
    }

    $now = Get-Date
    if (-not $script:_lastProgressLog -or
        ($now - $script:_lastProgressLog).TotalSeconds -ge $script:PROGRESS_LOG_EVERY_SEC) {
        $script:_lastProgressLog = $now
        Write-Host "[$($now.ToString('HH:mm:ss'))] [PROG]$Line"
    }
}

# Close off an animated progress line. On a terminal that means a newline so the next
# message starts fresh; headless there is nothing to close.
function Stop-ProgressLine {
    if (-not $script:LOG_HEADLESS) { Write-Host "" }
    $script:_lastProgressLog = $null
}

function Format-Bytes {
    param([long]$B)
    if ($B -ge 1GB) { return '{0:F2} GB' -f ($B / 1GB) }
    if ($B -ge 1MB) { return '{0:F1} MB' -f ($B / 1MB) }
    if ($B -ge 1KB) { return '{0:F1} KB' -f ($B / 1KB) }
    return "$B B"
}

# A fixed-width [####    ] bar. Every download backend and `--status` renders one, so the
# width and fill character are decided here instead of by whichever loop drew it last.
function Format-ProgressBar {
    param(
        [int]$Percent,
        [int]$Width = $script:PROGRESS_BAR_WIDTH,
        [char]$Empty = ' '
    )
    if ($Percent -lt 0)   { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $filled = [int][Math]::Round($Width * ($Percent / 100.0))
    return '[' + ('#' * $filled) + ([string]$Empty * ($Width - $filled)) + ']'
}

# Seconds -> "2h 5m" / "5m 3s" / "42s". Used for download ETAs.
function Format-Duration {
    param([int]$Seconds)
    if ($Seconds -lt 0)    { return '--' }
    if ($Seconds -ge 3600) { return '{0}h {1}m' -f [int]($Seconds / 3600), [int](($Seconds % 3600) / 60) }
    if ($Seconds -ge 60)   { return '{0}m {1}s' -f [int]($Seconds / 60), ($Seconds % 60) }
    return "${Seconds}s"
}

# Remaining time from a byte count and a rate, or '--' when it cannot be known.
function Format-Eta {
    param([long]$Done, [long]$Total, [long]$BytesPerSec)
    if ($BytesPerSec -le 0 -or $Total -le $Done) { return '--' }
    return (Format-Duration ([int](($Total - $Done) / $BytesPerSec)))
}

# The one download progress line: bar, percent, transferred/total, rate, ETA, label.
function Format-TransferLine {
    param(
        [string]$Prefix = '',
        [int]$Percent,
        [long]$Done,
        [long]$Total,
        [long]$BytesPerSec = -1,
        [string]$Label = ''
    )
    $parts = @()
    if ($Prefix) { $parts += $Prefix }
    $parts += (Format-ProgressBar -Percent $Percent)
    $parts += ('{0,3}%' -f $Percent)
    $parts += "$(Format-Bytes $Done)/$(Format-Bytes $Total)"
    if ($BytesPerSec -ge 0) {
        $parts += (Format-Speed $BytesPerSec)
        $parts += "ETA: $(Format-Eta -Done $Done -Total $Total -BytesPerSec $BytesPerSec)"
    }
    if ($Label) { $parts += (Format-ShortLabel $Label) }
    return ' ' + ($parts -join '  ')
}

function Format-Speed {
    param([long]$Bps)
    if ($Bps -eq 0) { return '--' }
    return "$(Format-Bytes $Bps)/s"
}

# Truncate a label so the progress line doesn't wrap.
function Format-ShortLabel {
    param([string]$Label, [int]$Max = 45)
    if ($Label.Length -gt $Max) { return $Label.Substring(0, $Max - 3) + '...' }
    return $Label
}

# Invoke-WebRequest -UseBasicParsing sometimes returns byte[] instead of a string.
function ConvertTo-ResponseText {
    param($Content)
    if ($Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($Content) }
    return [string]$Content
}
