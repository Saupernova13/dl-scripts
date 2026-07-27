# `dlrom --clean`: reclaim the disk dlrom itself is holding.
#
# Four kinds of leftover accumulate, and none of them are the user's problem to find:
#
#   * working files      a download that died mid-transfer leaves its part-file in tempDir,
#                        and a crash between extract and file leaves an extracted\ tree
#   * partial downloads  aria2/AB control files (.aria2, .part, ...) in the folder dlrom
#                        watches, left when a transfer was abandoned
#   * caches             ps2-gamedb.json (rebuilt from GameIndex.yaml on demand) and
#                        cf_session.json (dead: the Cloudflare bypass died with cdromance)
#   * job records        the JSON + log history under jobs\rom, pruned by age at runtime
#                        but never on demand
#
# THE RULE THIS FILE EXISTS TO ENFORCE: never delete anything a live job is using. A running
# worker's part-file looks exactly like an abandoned one, and removing it corrupts a transfer
# that is minutes from finishing. Every target is filtered through Get-DlromProtectedNames
# before it is offered for deletion, and job records for active jobs are never touched.
#
# dlrom also deliberately does NOT clean the download manager's own folder (Motrix's, and
# anything else in ~\Downloads). Those are the user's and the manager's, not dlrom's; the
# only exception is the AB watch folder, which dlrom told AB to use.

# Kind labels, used for grouping in the report and in --json output.
$script:CLEAN_KIND_WORK   = 'work'
$script:CLEAN_KIND_PART   = 'partial'
$script:CLEAN_KIND_CACHE  = 'cache'
$script:CLEAN_KIND_JOB    = 'job'

# Files that live in tempDir but are NOT interrupted downloads. The sweep of that directory
# would otherwise offer them a second time under the wrong label, and the duplicate delete
# then fails because the first one already removed the file.
$script:CLEAN_TEMP_CLAIMED = @('cf_session.json')

# Names an active job is (or will be) writing. A download in flight is indistinguishable
# from an abandoned one by looking at the file, so identity has to come from the job.
#
# Both spellings are returned: the raw link label is what a download manager saves under,
# and the sanitised one is what RomPipeline writes into tempDir.
function Get-DlromProtectedNames {
    $names = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath (Get-DlromJobsDir) -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $job = Read-DlromJob ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
        if (-not $job) { continue }
        if ((Resolve-DlromJobStatus $job) -notin $script:JOB_STATUS_ACTIVE) { continue }
        foreach ($link in @($job.links)) {
            if (-not $link.Label) { continue }
            $names[$link.Label] = $true
            $names[($link.Label -replace '[<>:"/\\|?*]', '_')] = $true
        }
    }
    return $names
}

# True when a filename belongs to something still downloading. Matches on prefix because a
# partial carries a suffix the job never named: "Game.zip" -> "Game.zip.aria2".
function Test-DlromProtected {
    param([string]$Name, [hashtable]$Protected)
    foreach ($p in $Protected.Keys) {
        if ($Name.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-PathSize {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) { return [long]$item.Length }
        return [long](@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue) |
            Measure-Object -Property Length -Sum).Sum
    } catch { return 0 }
}

function New-CleanTarget {
    param([string]$Kind, [string]$Path, [string]$Note = '')
    return [PSCustomObject]@{
        kind  = $Kind
        path  = $Path
        bytes = (Get-PathSize $Path)
        note  = $Note
    }
}

# Everything --clean would remove, in report order. -IncludeJobs adds the finished job
# records; without it the history survives (it is small, and it is the audit trail).
function Get-DlromCleanTargets {
    param([string]$TempDir, [switch]$IncludeJobs)

    $targets   = @()
    $protected = Get-DlromProtectedNames

    # 1. The working directory: part-files from dead transfers and extracted\ trees from
    #    runs that died between extraction and filing.
    if ($TempDir -and (Test-Path -LiteralPath $TempDir)) {
        foreach ($item in @(Get-ChildItem -LiteralPath $TempDir -Force -ErrorAction SilentlyContinue)) {
            if ($script:CLEAN_TEMP_CLAIMED -contains $item.Name) { continue }   # counted as a cache below
            if (Test-DlromProtected -Name $item.Name -Protected $protected) {
                Write-Log "Keeping $($item.Name) - a running job is downloading it." 'INFO'
                continue
            }
            $note = if ($item.PSIsContainer) { 'extraction working dir' } else { 'interrupted download' }
            $targets += New-CleanTarget $script:CLEAN_KIND_WORK $item.FullName $note
        }
    }

    # 2. The page dump written when link discovery finds nothing. One file, always stale.
    $debugHtml = Join-Path $env:TEMP 'dlrom-debug.html'
    if (Test-Path -LiteralPath $debugHtml) {
        $targets += New-CleanTarget $script:CLEAN_KIND_WORK $debugHtml 'saved debug page'
    }

    # 3. The PS2 torrent staging area. qBittorrent writes the selected file here before it
    #    is filed; anything still present is from a fallback that did not finish.
    $staging = [string](Get-CfgValue 'ps2TorrentStaging' '')
    if (-not $staging) {
        $base = [string](Get-CfgValue 'romsBase' $script:DEFAULT_ROMS_BASE)
        if ($base) { $staging = Join-Path $base '.dlrom-torrent' }
    }
    if ($staging -and (Test-Path -LiteralPath $staging)) {
        foreach ($item in @(Get-ChildItem -LiteralPath $staging -Force -ErrorAction SilentlyContinue)) {
            if (Test-DlromProtected -Name $item.Name -Protected $protected) { continue }
            $targets += New-CleanTarget $script:CLEAN_KIND_WORK $item.FullName 'torrent staging leftover'
        }
    }

    # 4. Control/part files in the folder dlrom asked AB to download into. Only this folder:
    #    Motrix's own directory belongs to Motrix, and to the user.
    $abDir = if ($script:AB_DOWNLOAD_DIR) { $script:AB_DOWNLOAD_DIR } else { Join-Path $env:USERPROFILE 'Downloads\ABDM' }
    if (Test-Path -LiteralPath $abDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $abDir -File -Force -ErrorAction SilentlyContinue)) {
            if ($script:PARTIAL_EXTS -notcontains $file.Extension.ToLower()) { continue }
            if (Test-DlromProtected -Name $file.Name -Protected $protected) { continue }
            $targets += New-CleanTarget $script:CLEAN_KIND_PART $file.FullName 'abandoned partial'
        }
    }

    # 5. Rebuildable caches. Both regenerate silently on the next run that needs them.
    $dataDir = Get-DlScriptsDataDir
    $gameDb  = Join-Path $dataDir 'ps2-gamedb.json'
    if (Test-Path -LiteralPath $gameDb) {
        $targets += New-CleanTarget $script:CLEAN_KIND_CACHE $gameDb 'PS2 GameIndex cache, rebuilt on demand'
    }
    # Left behind by the retired cdromance Cloudflare bypass; nothing reads it any more.
    $cfSession = Join-Path $TempDir 'cf_session.json'
    if ($TempDir -and (Test-Path -LiteralPath $cfSession)) {
        $targets += New-CleanTarget $script:CLEAN_KIND_CACHE $cfSession 'obsolete Cloudflare session'
    }

    # 6. Job history, only when asked. Active jobs are never included - deleting the file a
    #    live worker is writing would blind --status for the rest of the run.
    if ($IncludeJobs) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Get-DlromJobsDir) -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $id  = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $job = Read-DlromJob $id
            if ($job -and (Resolve-DlromJobStatus $job) -in $script:JOB_STATUS_ACTIVE) {
                Write-Log "Keeping job $id - it is still $($job.status)." 'INFO'
                continue
            }
            $status = if ($job) { Resolve-DlromJobStatus $job } else { 'unreadable' }
            $targets += New-CleanTarget $script:CLEAN_KIND_JOB $file.FullName "job record ($status)"
            $log = [System.IO.Path]::ChangeExtension($file.FullName, '.log')
            if (Test-Path -LiteralPath $log) {
                $targets += New-CleanTarget $script:CLEAN_KIND_JOB $log "job log ($status)"
            }
        }
    }

    return @($targets)
}

# Remove one target. Never throws: a file held open by another process is worth reporting,
# not worth aborting the rest of the sweep for.
function Remove-CleanTarget {
    param([PSCustomObject]$Target)
    try {
        Remove-Item -LiteralPath $Target.path -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Log "Could not remove $($Target.path): $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# The --clean entry point. Returns the exit code for the caller.
function Invoke-DlromClean {
    param([string]$TempDir, [switch]$All, [switch]$DryRun, [switch]$AsJson)

    $targets = @(Get-DlromCleanTargets -TempDir $TempDir -IncludeJobs:$All)
    $total   = [long](@($targets) | Measure-Object -Property bytes -Sum).Sum

    if ($targets.Count -eq 0) {
        if ($AsJson) {
            (@{ removed = @(); failed = @(); bytes = 0; dryRun = [bool]$DryRun } | ConvertTo-Json -Depth 5)
        } else {
            Write-Log "Nothing to clean - dlrom is holding no temp files, partials or caches." 'SUCCESS'
        }
        return 0
    }

    if (-not $AsJson) {
        Write-Host ""
        Write-Host $(if ($DryRun) { "Would remove:" } else { "Removing:" }) -ForegroundColor Cyan
        Write-Host ""
    }

    $removed = @()
    $failed  = @()
    foreach ($t in $targets) {
        $ok = if ($DryRun) { $true } else { Remove-CleanTarget -Target $t }
        if ($ok) { $removed += $t } else { $failed += $t }
        if (-not $AsJson) {
            $mark  = if ($ok) { ' ' } else { '!' }
            $color = if ($ok) { 'Gray' } else { 'Red' }
            Write-Host ("{0} {1,-9} {2,10}  {3}" -f $mark, $t.kind, (Format-Bytes $t.bytes), $t.path) -ForegroundColor $color
            if ($t.note) { Write-Host ("             {0}" -f $t.note) -ForegroundColor DarkGray }
        }
    }

    if ($AsJson) {
        (@{
            removed = @($removed | ForEach-Object { $_.path })
            failed  = @($failed  | ForEach-Object { $_.path })
            bytes   = [long](@($removed) | Measure-Object -Property bytes -Sum).Sum
            dryRun  = [bool]$DryRun
        } | ConvertTo-Json -Depth 5)
        return $(if ($failed.Count -gt 0) { 1 } else { 0 })
    }

    Write-Host ""
    $freed = [long](@($removed) | Measure-Object -Property bytes -Sum).Sum
    if ($DryRun) {
        Write-Log "$($targets.Count) item(s), $(Format-Bytes $total) - dry run, nothing was deleted." 'INFO'
        Write-Log "Re-run without --dry-run to remove them." 'INFO'
    } else {
        Write-Log "Removed $($removed.Count) item(s), freed $(Format-Bytes $freed)." 'SUCCESS'
        if ($failed.Count -gt 0) { Write-Log "$($failed.Count) item(s) could not be removed (in use?)." 'WARN' }
    }
    if (-not $All) {
        Write-Log "Job history was kept. Add --all to clear finished job records and logs too." 'INFO'
    }
    Write-Host ""
    return $(if ($failed.Count -gt 0) { 1 } else { 0 })
}
