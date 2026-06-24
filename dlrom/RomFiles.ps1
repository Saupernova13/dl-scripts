# Local-file side of things: spotting and extracting archives, finding the ROM inside one,
# cleaning up filenames so Steam launch commands don't choke, and filing the ROM into its
# console folder.

function Find-7zip {
    $fromPath = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    $pf   = Join-Path $env:ProgramFiles "7-Zip\7z.exe"
    $pf86 = Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe"
    if (Test-Path $pf)   { return $pf }
    if (Test-Path $pf86) { return $pf86 }
    return $null
}

function Get-ArchiveType {
    param([string]$FilePath)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $head  = ($bytes | Select-Object -First 8 | ForEach-Object { $_.ToString("X2") }) -join ""
        if ($head -match "^504B")       { return "zip" }
        if ($head -match "^377ABCAF")   { return "7z"  }
        if ($head -match "^526172211A") { return "rar" }
    } catch { }
    $ext = [System.IO.Path]::GetExtension($FilePath).TrimStart('.').ToLower()
    if ($ext -in @("7z", "rar", "zip")) { return $ext }
    return "zip"
}

# True only if the file really begins with a zip/7z/rar signature. This drives the
# extract-or-file-directly decision; Get-ArchiveType always returns a type, so it can't.
function Test-IsArchive {
    param([string]$Path)
    try {
        $fs  = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 8
            $n   = $fs.Read($buf, 0, 8)
        } finally { $fs.Dispose() }
        if ($n -lt 4) { return $false }
        $hex = ($buf[0..($n - 1)] | ForEach-Object { $_.ToString('X2') }) -join ''
        if ($hex -match '^504B0304' -or $hex -match '^504B0506' -or $hex -match '^504B0708') { return $true }  # zip
        if ($hex -match '^377ABCAF271C') { return $true }  # 7z
        if ($hex -match '^526172211A07') { return $true }  # rar4/rar5
        return $false
    } catch { return $false }
}

function Expand-RomArchive {
    param([string]$ArchivePath, [string]$OutDir)

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $archType = Get-ArchiveType -FilePath $ArchivePath
    Write-Log "Extracting .$archType archive..." 'INFO'

    if ($archType -eq 'zip') {
        $sz = Find-7zip
        if ($sz) {
            $proc = Start-Process -FilePath $sz -ArgumentList "x `"-o$OutDir`" -y `"$ArchivePath`"" -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) { throw "7z.exe exited with code $($proc.ExitCode)" }
        } else {
            Write-Log "7z.exe not found; using built-in Expand-Archive for .zip" 'WARN'
            Expand-Archive -Path $ArchivePath -DestinationPath $OutDir -Force
        }
        return
    }

    $sz = Find-7zip
    if (-not $sz) {
        Write-Log "7z.exe is required to extract .$archType archives but was not found." 'ERROR'
        Write-Log "Install it with:  winget install 7zip.7zip" 'WARN'
        Write-Log "The archive is at: $ArchivePath" 'WARN'
        exit 1
    }

    $proc = Start-Process -FilePath $sz -ArgumentList "x `"-o$OutDir`" -y `"$ArchivePath`"" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "7z.exe exited with code $($proc.ExitCode)" }
}

# Biggest matching file in the extract is almost always the ROM.
function Find-RomFile {
    param([string]$ExtractedDir)

    $romExts = @('.iso', '.bin', '.img', '.nds', '.gba', '.z64', '.n64', '.v64',
                 '.sfc', '.smc', '.nes', '.gb', '.gbc', '.gg', '.cue', '.chd', '.pbp')

    return Get-ChildItem -Path $ExtractedDir -Recurse -File |
        Where-Object { $romExts -contains $_.Extension.ToLower() } |
        Sort-Object Length -Descending |
        Select-Object -First 1
}

# Extensions we treat as an already-installable ROM (download was a raw ROM, not an archive).
$script:ROM_EXTS = @('.iso', '.bin', '.cue', '.img', '.chd', '.pbp', '.gdi',
                     '.nds', '.3ds', '.cia', '.gba', '.gb', '.gbc', '.gg',
                     '.z64', '.n64', '.v64', '.sfc', '.smc', '.nes',
                     '.rvz', '.wbfs', '.gcm', '.cso')

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
