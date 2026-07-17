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

        Update-DlromJob -Job $Job -Status 'running' -Step 'downloading' -Progress $bandLo `
                        -Message "Downloading $($link.Label) ($linkIndex/$linkCount)"
        Write-Log "Downloading: $($link.Label)" 'INFO'

        # Feed the downloader's live percentage into the job so --status tracks a running
        # download instead of sitting at the band floor until it finishes.
        $script:JOB_PROGRESS_CB = {
            param($Percent, $Line)
            if ($Percent -lt 0) { return }
            $Job.progress   = $bandLo + [int](($bandHi - $bandLo) * ($Percent / 100.0))
            $Job.lastUpdate = (Get-Date).ToUniversalTime().ToString('o')
            Save-DlromJob -Job $Job
        }.GetNewClosure()

        # Sanitise label for use as a Windows filename
        $safeLabel = $link.Label -replace '[<>:"/\\|?*]', '_'
        $outFile   = Join-Path $TempDir $safeLabel

        $completedPath = $null
        $extractDir    = $null
        try {
            try {
                $completedPath = Invoke-FileDownload -Url $link.Url -OutFile $outFile -Label $link.Label
            } catch {
                Write-Log "Download failed: $($_.Exception.Message)" 'ERROR'
                continue
            } finally {
                $script:JOB_PROGRESS_CB = $null
            }

            if ($Job.noExtract) {
                Write-Log "Archive saved (--no-extract): $completedPath" 'SUCCESS'
                Update-DlromJob -Job $Job -InstalledPath $completedPath
                $installedCount++
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
                Update-DlromJob -Job $Job -Step 'filing' -Progress $script:P_FILE
                try {
                    $moved = Move-RomToDest -SourcePath $completedPath -DestDir $romDest
                    Update-DlromJob -Job $Job -InstalledPath $moved
                    $installedCount++
                } catch {
                    Write-Log "Failed to file ROM: $($_.Exception.Message)" 'ERROR'
                }
                continue
            }

            Update-DlromJob -Job $Job -Step 'extracting' -Progress $script:P_EXTRACT -Message "Extracting $($link.Label)"
            $extractId  = [System.IO.Path]::GetFileNameWithoutExtension($safeLabel) + '_' + (Get-Random)
            $extractDir = Join-Path $TempDir "extracted\$extractId"
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

            Update-DlromJob -Job $Job -Step 'filing' -Progress $script:P_FILE
            try {
                $moved = Move-RomToDest -SourcePath $romFile.FullName -DestDir $romDest
                Update-DlromJob -Job $Job -InstalledPath $moved
                $installedCount++
            } catch {
                Write-Log "Move failed: $($_.Exception.Message)" 'ERROR'
            }
        }
        finally {
            $script:JOB_PROGRESS_CB = $null
            # Always clean download artifacts (keep the archive only under --no-extract).
            if (-not $Job.noExtract) {
                if ($completedPath -and (Test-Path $completedPath)) { Remove-Item -Path $completedPath -Force -ErrorAction SilentlyContinue }
                if (Test-Path $outFile)                              { Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue }
                if ($extractDir -and (Test-Path $extractDir))        { Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    # Prune the extraction parent if our cleanup left it empty.
    $extractedParent = Join-Path $TempDir "extracted"
    if ((Test-Path $extractedParent) -and -not (Get-ChildItem -LiteralPath $extractedParent -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $extractedParent -Force -ErrorAction SilentlyContinue
    }

    if ($installedCount -eq 0) { return $false }

    # Add the freshly installed ROM(s) to Steam (srm-wrapper preferred, built-in fallback).
    if (-not $Job.noSteam -and [bool](Get-CfgValue 'steamSync' $true)) {
        Update-DlromJob -Job $Job -Step 'steam-sync' -Progress $script:P_STEAM -Message 'Adding to Steam'
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
                   -Source $Job.kind -InstalledPath (@($Job.installedPaths)[-1]) -Cfg $Cfg
    if ($handoff) { $Job.handoff = $handoff }

    return $true
}
