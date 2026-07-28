# Local-file side of things: spotting and extracting archives, finding the ROM inside one,
# cleaning up filenames so Steam launch commands don't choke, and filing the ROM into its
# console folder.
#
# Extension and signature tables come from Constants.ps1; there is exactly one of each.

# 7-Zip is what extracts .7z and .rar - the two formats The Repo publishes most often - so
# a miss here is not cosmetic: the download succeeds and the install then fails.
# SteamOS ships 7z in /usr/bin, so on Linux PATH is the whole story; Windows also has to
# look in Program Files because the installer does not add itself to PATH.
function Find-7zip {
    $names = if (Test-DlWindows) { @('7z.exe') } else { @('7z', '7za', '7zz') }
    foreach ($name in $names) {
        $fromPath = Get-Command $name -ErrorAction SilentlyContinue
        if ($fromPath) { return $fromPath.Source }
    }
    if (-not (Test-DlWindows)) { return $null }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        $candidate = Join-DlPath $root '7-Zip' '7z.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

# Read the leading bytes of a file as an uppercase hex string. One reader for both the
# archive test and the type sniffer, which used to open the file two different ways and
# compare against two different signature tables.
function Get-FileHeaderHex {
    param([string]$Path, [int]$Length = 8)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] $Length
            $n   = $fs.Read($buf, 0, $Length)
        } finally { $fs.Dispose() }
        if ($n -le 0) { return '' }
        return (($buf[0..($n - 1)] | ForEach-Object { $_.ToString('X2') }) -join '')
    } catch { return '' }
}

# The archive type a file's signature says it is, or '' when it is not an archive.
function Get-ArchiveSignatureType {
    param([string]$Path)
    $hex = Get-FileHeaderHex -Path $Path
    if (-not $hex) { return '' }
    foreach ($sig in $script:ARCHIVE_SIGNATURES) {
        foreach ($prefix in $sig.Hex) {
            if ($hex.StartsWith($prefix)) { return $sig.Type }
        }
    }
    return ''
}

# True only when the file really begins with an archive signature. This drives the
# extract-or-file-directly decision, so it must never guess from the extension: a ROM
# named .zip that isn't one has to be filed, not handed to 7-Zip.
function Test-IsArchive {
    param([string]$Path)
    return [bool](Get-ArchiveSignatureType -Path $Path)
}

# Which extractor a file needs. Signature first; the extension is only a fallback for a
# truncated read, and 'zip' is the last resort because Expand-Archive can handle it
# without 7-Zip installed.
function Get-ArchiveType {
    param([string]$FilePath)
    $bySignature = Get-ArchiveSignatureType -Path $FilePath
    if ($bySignature) { return $bySignature }
    $ext = [System.IO.Path]::GetExtension($FilePath).TrimStart('.').ToLower()
    if ($script:ARCHIVE_EXTS -contains ".$ext") { return $ext }
    return 'zip'
}

function Expand-RomArchive {
    param([string]$ArchivePath, [string]$OutDir)

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $archType = Get-ArchiveType -FilePath $ArchivePath
    Write-Log "Extracting .$archType archive..." 'INFO'

    $sz = Find-7zip
    if ($sz) {
        $proc = Start-Process -FilePath $sz -ArgumentList "x `"-o$OutDir`" -y `"$ArchivePath`"" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) { throw "7z.exe exited with code $($proc.ExitCode)" }
        return
    }

    # Only .zip has a built-in fallback; .7z and .rar genuinely need 7-Zip.
    if ($archType -eq 'zip') {
        Write-Log "7z.exe not found; using built-in Expand-Archive for .zip" 'WARN'
        Expand-Archive -Path $ArchivePath -DestinationPath $OutDir -Force
        return
    }

    Write-Log "Install it with:  winget install 7zip.7zip" 'WARN'
    Write-Log "The archive is at: $ArchivePath" 'WARN'
    # Throw, don't exit: a background worker has to record the failure on its job.
    throw "7z.exe is required to extract .$archType archives but was not found."
}

# Biggest ROM-shaped file in the extract is almost always the ROM. Searches the same
# extension table used to recognise a raw download, so anything dlrom will file directly
# is also something it can find inside an archive.
function Find-RomFile {
    param([string]$ExtractedDir)
    return Get-ChildItem -Path $ExtractedDir -Recurse -File |
        Where-Object { $script:ROM_EXTS -contains $_.Extension.ToLower() } |
        Sort-Object Length -Descending |
        Select-Object -First 1
}

# Drop characters that are illegal in Windows filenames or that break Steam launches.
# SRM wraps each launch path in a single-quoted PowerShell string, so an apostrophe or
# backtick in the name (e.g. "Klonoa 2 - Lunatea's Veil") ends the string early and the
# game won't boot. Every install funnels through here, so disk and shortcut stay in sync.
function Get-SafeRomName {
    param([string]$Name)
    $strip = @("'", '`', '<', '>', ':', '"', '/', '\', '|', '?', '*')
    foreach ($c in $strip) { $Name = $Name.Replace($c, '') }
    return ($Name -replace '\s+', ' ').Trim()
}

# Keep a .cue's internal FILE "name" reference(s) in sync after its data track was
# renamed by Get-SafeRomName, so the pair still resolves.
function Repair-CueFileRefs {
    param([string]$CuePath)
    try {
        $lines   = Get-Content -LiteralPath $CuePath -ErrorAction Stop
        $changed = $false
        $out = foreach ($line in $lines) {
            $m = [regex]::Match($line, '^(?<pre>\s*FILE\s+")(?<f>[^"]+)(?<post>".*)$', 'IgnoreCase')
            if ($m.Success) {
                $safe = Get-SafeRomName $m.Groups['f'].Value
                if ($safe -ne $m.Groups['f'].Value) { $changed = $true }
                $m.Groups['pre'].Value + $safe + $m.Groups['post'].Value
            } else { $line }
        }
        if ($changed) {
            Set-Content -LiteralPath $CuePath -Value $out -Encoding ASCII
            Write-Log "Updated .cue FILE reference(s) to match sanitised names." 'DEBUG'
        }
    } catch {
        Write-Log "Could not patch .cue references: $($_.Exception.Message)" 'WARN'
    }
}

# Move a single ROM into the console destination, verify it landed, and bring along a
# paired .cue/.bin sibling. Throws if the move fails or the file does not appear at dest.
function Move-RomToDest {
    param([string]$SourcePath, [string]$DestDir)
    if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    $origName = [System.IO.Path]::GetFileName($SourcePath)
    $name     = Get-SafeRomName $origName
    if ($name -ne $origName) {
        Write-Log "Sanitised ROM filename for Steam launch safety: '$origName' -> '$name'" 'INFO'
    }
    $final = Join-Path $DestDir $name
    Move-Item -LiteralPath $SourcePath -Destination $final -Force -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $final)) { throw "ROM did not appear at destination: $final" }
    Write-Log "ROM saved to: $final" 'SUCCESS'
    $ext = [System.IO.Path]::GetExtension($name).ToLower()
    if ($ext -eq '.bin' -or $ext -eq '.cue') {
        $pairExt = if ($ext -eq '.bin') { '.cue' } else { '.bin' }
        $pairSrc = [System.IO.Path]::ChangeExtension($SourcePath, $pairExt)
        if (Test-Path -LiteralPath $pairSrc) {
            $pairName = Get-SafeRomName ([System.IO.Path]::GetFileName($pairSrc))
            $pairDest = Join-Path $DestDir $pairName
            Move-Item -LiteralPath $pairSrc -Destination $pairDest -Force -ErrorAction SilentlyContinue
            Write-Log "Paired $pairExt moved alongside $ext" 'DEBUG'
            # The .cue lists the .bin by name; resync it after either side was renamed.
            $cuePath = if ($ext -eq '.cue') { $final } else { $pairDest }
            if (Test-Path -LiteralPath $cuePath) { Repair-CueFileRefs -CuePath $cuePath }
        }
    }
    return $final
}

# Turn one completed download into an installed ROM.
#
# The web pipeline and the PS2 torrent fallback both had their own copy of this decision
# tree and had already drifted - only one of them warned about an unrecognised raw
# extension, and only one pruned its extraction directory. It is the same problem in both
# cases (a file arrived; put a ROM in the console folder), so it is one function.
#
# Returns the installed path, or $null when nothing could be installed. Callers decide
# what that means for their job. Cleanup always runs, except under -NoExtract where
# keeping the downloaded archive is the whole point.
function Install-RomFromDownload {
    param(
        [Parameter(Mandatory)][string]$DownloadedPath,
        [Parameter(Mandatory)][string]$RomDest,
        [string]$WorkDir,
        [switch]$NoExtract,
        # Invoked as { param($Step) } before extraction and filing, so a caller with a job
        # can report progress without this function knowing what a job is.
        [scriptblock]$OnStep
    )

    if (-not (Test-Path -LiteralPath $DownloadedPath)) {
        Write-Log "Downloaded file not found at: $DownloadedPath" 'ERROR'
        return $null
    }

    $report = { param($Step) if ($OnStep) { try { & $OnStep $Step } catch { } } }

    # -NoExtract keeps the archive as downloaded; file it and stop.
    if ($NoExtract) {
        & $report $script:JOB_STEP_FILING
        Write-Log "Archive kept (--no-extract): $DownloadedPath" 'SUCCESS'
        return (Move-RomToDest -SourcePath $DownloadedPath -DestDir $RomDest)
    }

    # A raw ROM (not a container): file it as-is rather than failing extraction and
    # leaving it behind in the downloader's folder.
    if (-not (Test-IsArchive $DownloadedPath)) {
        $ext = [System.IO.Path]::GetExtension($DownloadedPath).ToLower()
        if ($script:ROM_EXTS -notcontains $ext) {
            Write-Log "Download is not an archive and '$ext' is an unrecognised ROM type; filing as-is." 'WARN'
        }
        & $report $script:JOB_STEP_FILING
        return (Move-RomToDest -SourcePath $DownloadedPath -DestDir $RomDest)
    }

    if (-not $WorkDir) { $WorkDir = [System.IO.Path]::GetDirectoryName($DownloadedPath) }
    $extractDir = Join-Path $WorkDir ('extracted\{0}_{1}' -f
                    [System.IO.Path]::GetFileNameWithoutExtension($DownloadedPath), (New-ShortId 8))

    try {
        & $report $script:JOB_STEP_EXTRACTING
        Expand-RomArchive -ArchivePath $DownloadedPath -OutDir $extractDir

        $romFile = Find-RomFile -ExtractedDir $extractDir
        if (-not $romFile) {
            Write-Log "No ROM file found after extraction." 'WARN'
            return $null
        }

        & $report $script:JOB_STEP_FILING
        return (Move-RomToDest -SourcePath $romFile.FullName -DestDir $RomDest)
    } finally {
        if (Test-Path -LiteralPath $DownloadedPath) {
            Remove-Item -LiteralPath $DownloadedPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-EmptyDirectory (Join-Path $WorkDir 'extracted')
    }
}
