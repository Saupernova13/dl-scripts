# The slow half of dlrom: download each selected link, extract it, file the ROM into the
# console folder, sync to Steam, and report the result.
#
# This lives behind one function so that `--wait` (foreground) and the detached worker run
# byte-for-byte the same code -- the only difference is who is watching. Everything it
# learns is stamped onto the job, so `dlrom --status <id>` can answer without it.

# Percent milestones. The download dominates the wall clock, so it owns most of the range
# and the post-processing steps are near the top.
$script:P_DOWNLOAD_START = 5
$script:P_DOWNLOAD_END   = 70
$script:P_EXTRACT        = 75
$script:P_FILE           = 85
$script:P_STEAM          = 95

function Invoke-RomPipeline {
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$Job,
        [Parameter(Mandatory=$true)]$Cfg,
        [Parameter(Mandatory=$true)][string]$TempDir
    )

    $links     = @($Job.links)
    $romDest   = $Job.romDest
    $linkCount = [Math]::Max($links.Count, 1)

    if (-not (Test-Path $romDest)) {
        New-Item -ItemType Directory -Path $romDest -Force | Out-Null
        Write-Log "Created ROM directory: $romDest" 'DEBUG'
    }
    if (-not (Test-Path $TempDir)) {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    }

    $installedCount = 0
    $linkIndex      = 0

    foreach ($link in $links) {
        # Spread the download band across the links so a 2-disc game does not jump back to 5%.
        $bandLo = $script:P_DOWNLOAD_START +
                  [int](($script:P_DOWNLOAD_END - $script:P_DOWNLOAD_START) * ($linkIndex / $linkCount))
        $bandHi = $script:P_DOWNLOAD_START +
                  [int](($script:P_DOWNLOAD_END - $script:P_DOWNLOAD_START) * (($linkIndex + 1) / $linkCount))
        $linkIndex++

        Update-DlromJob -Job $Job -Status $script:JOB_STATUS_RUNNING -Step $script:JOB_STEP_DOWNLOADING -Progress $bandLo `
                        -Message "Downloading $($link.Label) ($linkIndex/$linkCount)"
        Write-Log "Downloading: $($link.Label)" 'INFO'

        # Feed the downloader's live percentage into the job so --status tracks a running
        # download instead of sitting at the band floor until it finishes.
        $script:JOB_PROGRESS_CB = {
            param($Percent, $Line)
            if ($Percent -lt 0) { return }
            $Job.progress   = $bandLo + [int](($bandHi - $bandLo) * ($Percent / 100.0))
            $Job.lastUpdate = (Get-UtcStamp)
            Save-DlromJob -Job $Job
        }.GetNewClosure()

        # Sanitise label for use as a Windows filename
        $safeLabel = $link.Label -replace '[<>:"/\\|?*]', '_'
        $outFile   = Join-Path $TempDir $safeLabel

        $completedPath = $null
        try {
            try {
                $completedPath = Invoke-FileDownload -Url $link.Url -OutFile $outFile -Label $link.Label
            } catch {
                Write-Log "Download failed: $($_.Exception.Message)" 'ERROR'
                continue
            } finally {
                $script:JOB_PROGRESS_CB = $null
            }

            # Extraction, ROM discovery, filing and cleanup are identical for a web
            # download and a torrent one, so both go through Install-RomFromDownload.
            # The callback maps its step names onto this job's progress bands.
            $onStep = {
                param($Step)
                $pct = switch ($Step) {
                    $script:JOB_STEP_EXTRACTING { $script:P_EXTRACT }
                    $script:JOB_STEP_FILING     { $script:P_FILE }
                    default                     { -1 }
                }
                Update-DlromJob -Job $Job -Step $Step -Progress $pct
            }.GetNewClosure()

            $moved = Install-RomFromDownload -DownloadedPath $completedPath -RomDest $romDest `
                        -WorkDir $TempDir -NoExtract:([bool]$Job.noExtract) -OnStep $onStep
            if ($moved) {
                Update-DlromJob -Job $Job -InstalledPath $moved
                $installedCount++
            }
        } catch {
            Write-Log "Install failed: $($_.Exception.Message)" 'ERROR'
        } finally {
            $script:JOB_PROGRESS_CB = $null
            # Install-RomFromDownload removes what it consumed; this catches the case
            # where the downloader wrote somewhere other than the path it returned.
            if ((-not $Job.noExtract) -and (Test-Path $outFile)) {
                Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($installedCount -eq 0) { return $false }

    # Add the freshly installed ROM(s) to Steam (srm-wrapper preferred, built-in fallback).
    if (-not $Job.noSteam -and [bool](Get-CfgValue 'steamSync' $true)) {
        Update-DlromJob -Job $Job -Step $script:JOB_STEP_STEAM_SYNC -Progress $script:P_STEAM -Message 'Adding to Steam'
        try {
            Sync-RomToSteam -RomDest $romDest -RomsBase $Job.romsBase -InstalledCount $installedCount
        } catch {
            # Steam is a nice-to-have; the ROM is already installed and that is the deliverable.
            Write-Log "Steam sync failed: $($_.Exception.Message)" 'WARN'
        }
    } elseif ($Job.noSteam) {
        Write-Log "Skipping Steam sync (--no-steam)." 'INFO'
    }

    # Report what was installed and, for PS2, the dlps2tex command for matching textures
    # (same version). An agent can read the [HANDOFF] line -- or the job's handoff field.
    $handoff = Write-DlromResult -Title $Job.title -Platform $Job.platform -Region $Job.region `
                   -Source $Job.kind -InstalledPath (@($Job.installedPaths)[-1]) `
                   -Build ([string]$Job.vitaBuild) -Cfg $Cfg
    if ($handoff) { $Job.handoff = $handoff }

    return $true
}
