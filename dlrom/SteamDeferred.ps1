# Deferred Steam sync queue.
#
# In Game Mode Steam *is* the session: it cannot be shut down, SRM's CLI warns that adding
# while Steam runs silently drops categories, and SRM writes files Steam holds open and
# rewrites on exit - so a mid-session add can be discarded outright.
#
# Downloading has none of those problems, so only the Steam-facing half is gated: in Game Mode
# it is written here as a pending entry and drained when a Desktop Mode session starts.
#
# A directory of small JSON files rather than one index, for the same reason the job store is:
# writer and drain are different processes, often hours apart, and a directory has no file to
# corrupt when two land at once.

function Get-SrmQueueDir {
    return (Get-DlScriptsDataDir 'srm-queue')
}

function Get-SrmQueuePath {
    param([Parameter(Mandatory)][string]$Id)
    return (Join-Path (Get-SrmQueueDir) "$Id.json")
}

# Every pending entry, oldest first. Unreadable files are reported and skipped rather than
# throwing: one bad file must not block the rest of the queue forever.
function Get-SrmDeferredJobs {
    $dir = Get-SrmQueueDir
    if (-not (Test-Path $dir)) { return @() }
    $entries = @()
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime)) {
        try {
            $entry = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if (-not $entry.id) { $entry | Add-Member -NotePropertyName id -NotePropertyValue $file.BaseName -Force }
            $entries += $entry
        } catch {
            Write-Log "Skipping unreadable Steam queue entry: $($file.Name)" 'WARN'
        }
    }
    return @($entries)
}

# Queue a Steam sync for later. Deduplicates on the destination folder: SRM works on whole
# folders, so two ROMs filed into the same platform dir need one add, not two.
function Add-SrmDeferredJob {
    param(
        [Parameter(Mandatory)][string]$RomDest,
        [string]$RomsBase = '',
        [int]$InstalledCount = 1,
        [string]$Title = '',
        [string]$Platform = ''
    )

    $existing = @(Get-SrmDeferredJobs | Where-Object { $_.romDest -eq $RomDest })
    if ($existing.Count -gt 0) {
        $entry = $existing[0]
        $entry.installedCount = [int]$entry.installedCount + $InstalledCount
        $entry.updatedAt      = (Get-UtcStamp)
        if ($Title -and ($entry.titles -notcontains $Title)) { $entry.titles = @($entry.titles) + $Title }
        $entry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-SrmQueuePath $entry.id) -Encoding UTF8
        Write-Log "Steam sync already queued for $RomDest - folded this ROM into it." 'INFO'
        return $entry.id
    }

    $id = New-ShortId
    $entry = [PSCustomObject]@{
        id             = $id
        romDest        = $RomDest
        romsBase       = $RomsBase
        installedCount = $InstalledCount
        titles         = @($Title | Where-Object { $_ })
        platform       = $Platform
        queuedBecause  = 'gamemode'
        createdAt      = (Get-UtcStamp)
        updatedAt      = (Get-UtcStamp)
        attempts       = 0
        lastError      = ''
    }
    $null = Get-SrmQueueDir   # creates it
    $entry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-SrmQueuePath $id) -Encoding UTF8
    return $id
}

function Remove-SrmDeferredJob {
    param([Parameter(Mandatory)][string]$Id)
    $path = Get-SrmQueuePath $Id
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Save-SrmDeferredJob {
    param([Parameter(Mandatory)]$Entry)
    $Entry.updatedAt = (Get-UtcStamp)
    $Entry | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-SrmQueuePath $Entry.id) -Encoding UTF8
}

# Run every queued sync. Called by `dlrom --sync-steam`, which the Desktop Mode autostart
# entry invokes; safe to run by hand at any time.
#
# Never drains in Game Mode: that would produce exactly the broken add the queue exists to
# avoid, and empty the queue doing it. Desktop Mode is only ever a means to an end here, so
# the device is handed back to Game Mode once the sync lands rather than parked on a desktop
# nobody asked for - and that is the last thing before returning, because the switch tears
# the desktop session down with it.
function Complete-SrmSyncSession {
    if (-not [bool](Get-CfgValue 'srmReturnToGameMode' $true)) { return }
    if (Test-DlGameMode) { return }   # already there
    $deckyWasUp = Test-DlDeckyActive
    Write-Log "Returning the Deck to Game Mode..." 'INFO'
    if (Enter-DlGameMode) { Write-Log "Switched to Game Mode." 'SUCCESS' }
    else { Write-Log "Could not switch to Game Mode (steamos-session-select unavailable)." 'DEBUG' }
    Restore-DlDecky -WasActive:$deckyWasUp
}

function Invoke-SrmDeferredDrain {
    param([switch]$AsJson)

    $pending = @(Get-SrmDeferredJobs)

    # Asked to sync from Game Mode: borrow the desktop and give it back rather than refusing.
    # Invoke-SrmInDesktopSession restores Game Mode on every path, so control returns here
    # already back where it started.
    if (Test-DlGameMode) {
        if ([bool](Get-CfgValue 'srmAutoSwitchSession' $true)) {
            $romsBase = [string](Get-CfgValue 'romsBase' $script:DEFAULT_ROMS_BASE)
            if (Invoke-SrmInDesktopSession -RomDest $romsBase -RomsBase $romsBase -InstalledCount 0) {
                foreach ($entry in $pending) { Remove-SrmDeferredJob -Id $entry.id }
                if ($AsJson) {
                    [PSCustomObject]@{ drained = $pending.Count; pending = 0; fullSync = $true; viaDesktop = $true } | ConvertTo-Json
                } else {
                    Write-Log "Steam library updated from $romsBase (borrowed the desktop, back in Game Mode)." 'SUCCESS'
                }
                return $pending.Count
            }
            Write-Log "Could not borrow a desktop session for the sync." 'WARN'
        }
        $msg = "Game Mode is active - not draining $($pending.Count) queued Steam sync(s). Switch to Desktop Mode."
        if ($AsJson) {
            [PSCustomObject]@{ drained = 0; pending = $pending.Count; skipped = 'gamemode' } | ConvertTo-Json
        } else { Write-Log $msg 'WARN' }
        return 0
    }

    # An empty queue does not mean there is nothing to do. The queue only holds syncs Game
    # Mode postponed, but --sync-steam almost always means "add the new ROMs to Steam", and
    # answering "No queued Steam syncs" is a dead end. 'srm add' walks every enabled parser,
    # so a full pass picks up anything new however it got onto the disk.
    if ($pending.Count -eq 0) {
        Write-Log "Nothing queued - running a full Steam ROM Manager pass instead." 'INFO'
        $romsBase = [string](Get-CfgValue 'romsBase' $script:DEFAULT_ROMS_BASE)
        try {
            Sync-RomToSteam -RomDest $romsBase -RomsBase $romsBase -InstalledCount 0 -AlreadyDeferred
            if ($AsJson) {
                [PSCustomObject]@{ drained = 0; pending = 0; fullSync = $true } | ConvertTo-Json
            } else {
                Write-Log "Steam library updated from $romsBase." 'SUCCESS'
            }
            Complete-SrmSyncSession
            return 0
        } catch {
            if ($AsJson) {
                [PSCustomObject]@{ drained = 0; pending = 0; fullSync = $false; error = $_.Exception.Message } | ConvertTo-Json
            } else {
                Write-Log "Full Steam sync failed: $($_.Exception.Message)" 'ERROR'
            }
            return 0
        }
    }

    Write-Log "Draining $($pending.Count) queued Steam sync(s)..." 'INFO'
    $drained = 0
    foreach ($entry in $pending) {
        if (-not (Test-Path $entry.romDest)) {
            Write-Log "Queued folder no longer exists, dropping entry: $($entry.romDest)" 'WARN'
            Remove-SrmDeferredJob -Id $entry.id
            continue
        }
        try {
            Sync-RomToSteam -RomDest $entry.romDest -RomsBase $entry.romsBase `
                            -InstalledCount ([int]$entry.installedCount) -AlreadyDeferred
            Remove-SrmDeferredJob -Id $entry.id
            $drained++
        } catch {
            $entry.attempts  = [int]$entry.attempts + 1
            $entry.lastError = $_.Exception.Message
            Save-SrmDeferredJob -Entry $entry
            Write-Log "Queued Steam sync failed for $($entry.romDest): $($_.Exception.Message)" 'ERROR'
        }
    }

    if ($AsJson) {
        [PSCustomObject]@{ drained = $drained; pending = @(Get-SrmDeferredJobs).Count } | ConvertTo-Json
    } else {
        Write-Log "Drained $drained of $($pending.Count) queued Steam sync(s)." 'SUCCESS'
    }
    if ($drained -gt 0) { Complete-SrmSyncSession }
    return $drained
}

# `dlrom --steam-queue` - what is waiting, without running any of it.
function Show-SrmDeferredQueue {
    param([switch]$AsJson)
    $pending = @(Get-SrmDeferredJobs)
    if ($AsJson) {
        [PSCustomObject]@{ session = (Get-DlSessionMode); count = $pending.Count; entries = $pending } |
            ConvertTo-Json -Depth 6
        return
    }
    if ($pending.Count -eq 0) { Write-Log "Steam sync queue is empty." 'INFO'; return }
    Write-Host ""
    Write-Host "  Queued Steam syncs ($($pending.Count)) - session: $(Get-DlSessionMode)"
    foreach ($entry in $pending) {
        $titles = if ($entry.titles) { ($entry.titles -join ', ') } else { '(unnamed)' }
        Write-Host ("  [{0}] {1}" -f $entry.id, $titles)
        Write-Host ("        {0}  x{1}  queued {2}" -f $entry.romDest, $entry.installedCount, $entry.createdAt)
        if ($entry.attempts -gt 0) { Write-Host ("        {0} failed attempt(s): {1}" -f $entry.attempts, $entry.lastError) }
    }
    Write-Host ""
}
