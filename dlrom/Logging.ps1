# Console logging plus the size/speed/label formatting used across dlrom.
#
# Write-Log respects two flags that Add-ROM sets from -Verbose / -Quiet:
#   $script:LOG_VERBOSE   also print DEBUG (per-step detail)
#   $script:LOG_QUIET     drop routine INFO, keep results and warnings

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
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

function Format-Bytes {
    param([long]$B)
    if ($B -ge 1GB) { return '{0:F2} GB' -f ($B / 1GB) }
    if ($B -ge 1MB) { return '{0:F1} MB' -f ($B / 1MB) }
    if ($B -ge 1KB) { return '{0:F1} KB' -f ($B / 1KB) }
    return "$B B"
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
