# lib/DriveResolver.ps1
# Shared library for dl-scripts. Provides:
#   Initialize-DlConfig    - Bootstraps %LOCALAPPDATA%\dlScripts\config.json sections,
#                            backfilling any new keys from $Defaults into existing sections.
#   Get-DriveMetaInventory - Enumerates connected drives with valid drive-meta.json files.
#   Resolve-MediaPath      - Picks a drive at runtime by reading those metadata files.
#
# Each script dot-sources this file via:
#   . (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\DriveResolver.ps1")
#
# Run this file directly to invoke the test harness.

# Default logger - scripts may redefine Write-Log later; identical signatures so no behaviour change.
if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param([string]$Message, [string]$Level = "INFO")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $color = switch ($Level) {
            "INFO"    { "Cyan" }
            "SUCCESS" { "Green" }
            "WARN"    { "Yellow" }
            "ERROR"   { "Red" }
            "DEBUG"   { "Gray" }
            default   { "White" }
        }
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }
}

function Initialize-DlConfig {
    param([string]$Section, [PSCustomObject]$Defaults)
    $configDir  = Join-Path $env:LOCALAPPDATA "dlScripts"
    $configPath = Join-Path $configDir "config.json"
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $config = $null
    $dirty  = $false
    if (Test-Path $configPath) {
        try   { $config = Get-Content $configPath -Raw | ConvertFrom-Json }
        catch {
            Write-Host "[dlScripts] config.json could not be parsed  - [$Section] defaults will be written." -ForegroundColor Yellow
            $config = [PSCustomObject]@{}
            $dirty  = $true
        }
    } else {
        Write-Host "[dlScripts] Config not found  - creating: $configPath" -ForegroundColor Yellow
        $config = [PSCustomObject]@{}
        $dirty  = $true
    }
    if (-not ($config.PSObject.Properties.Name -contains $Section)) {
        Add-Member -InputObject $config -MemberType NoteProperty -Name $Section -Value $Defaults
        Write-Host "[dlScripts] Added [$Section] defaults to config.json  - edit to customise." -ForegroundColor Cyan
        $dirty = $true
    } else {
        $existing = $config.$Section
        foreach ($prop in $Defaults.PSObject.Properties) {
            if (-not ($existing.PSObject.Properties.Name -contains $prop.Name)) {
                Add-Member -InputObject $existing -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
                Write-Host "[dlScripts] Backfilled missing key [$Section.$($prop.Name)] in config.json" -ForegroundColor Cyan
                $dirty = $true
            }
        }
    }
    if ($dirty) { $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8 }
    return $config.$Section
}

function Get-DriveMetaInventory {
    $results = @()
    $seenNames = @{}
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    foreach ($drv in $drives) {
        if ($drv.Name.Length -ne 1) { continue }
        $metaPath = Join-Path $drv.Root "drive-meta.json"
        if (-not (Test-Path $metaPath)) { continue }
        try {
            $meta = Get-Content $metaPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Log "[resolver] skipping $($drv.Root) - drive-meta.json could not be parsed: $($_.Exception.Message)" "WARN"
            continue
        }
        if (-not $meta.drive_name) {
            Write-Log "[resolver] skipping $($drv.Root) - drive-meta.json missing drive_name" "WARN"
            continue
        }
        if ($seenNames.ContainsKey($meta.drive_name)) {
            Write-Log "[resolver] skipping $($drv.Root) - duplicate drive_name '$($meta.drive_name)' (also on $($seenNames[$meta.drive_name]))" "WARN"
            continue
        }
        $seenNames[$meta.drive_name] = $drv.Root
        $freeBytes = $null
        try {
            $vol = Get-Volume -DriveLetter $drv.Name -ErrorAction Stop
            $freeBytes = $vol.SizeRemaining
        } catch {
            $freeBytes = $drv.Free
        }
        $results += [PSCustomObject]@{
            DriveLetter = $drv.Name
            Root        = $drv.Root
            FreeBytes   = $freeBytes
            FreeGB      = [math]::Round($freeBytes / 1GB, 1)
            Meta        = $meta
        }
    }
    return $results
}

function Resolve-MediaPath {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('movie','tv','anime_series','anime_movie','game_pc')]
        [string]$MediaType,
        [switch]$Strict,
        [switch]$DryRun
    )
    $pathKey   = "${MediaType}_path"
    $inventory = Get-DriveMetaInventory
    $candidates = @()
    foreach ($entry in $inventory) {
        $relPath = $entry.Meta.$pathKey
        if (-not $relPath) { continue }
        $base = if ($null -ne $entry.Meta.drive_priority) { [int]$entry.Meta.drive_priority } else { 50 }
        $preferred = 0
        $preferredArr = $entry.Meta.drive_preferred_media
        if ($preferredArr -and ($preferredArr -contains $MediaType)) { $preferred = 1000 }
        $type = if ($entry.Meta.drive_type) { $entry.Meta.drive_type } else { 'hdd' }
        if ($MediaType -eq 'game_pc') {
            $typeBonus = switch ($type) { 'ssd' { 300 } 'sdcard' { -200 } default { 0 } }
        } else {
            $typeBonus = switch ($type) { 'hdd' { 300 } 'ssd' { 100 } default { 0 } }
        }
        $lastResort = if ($entry.Meta.drive_last_resort) { -5000 } else { 0 }
        $freeGB = $entry.FreeGB
        $score = $base + $preferred + $typeBonus + $lastResort + ($freeGB * 0.5)
        $candidates += [PSCustomObject]@{
            DriveLetter = $entry.DriveLetter
            DriveName   = $entry.Meta.drive_name
            Type        = $type
            RelPath     = $relPath
            AbsPath     = (Join-Path $entry.Root $relPath)
            FreeGB      = $freeGB
            Base        = $base
            Preferred   = $preferred
            TypeBonus   = $typeBonus
            LastResort  = $lastResort
            Score       = $score
        }
    }
    if ($candidates.Count -eq 0) {
        $fallback = Join-Path $HOME $MediaType
        if ($Strict) { throw "Resolve-MediaPath: no connected drive advertises '$MediaType'." }
        Write-Log "[resolver] no connected drive advertises '$MediaType' - falling back to $fallback" "WARN"
        if ($DryRun) { return $null }
        return $fallback
    }
    $pick = $candidates | Sort-Object -Property Score -Descending | Select-Object -First 1
    $scoreStr = "{0:N1}" -f $pick.Score
    Write-Log "[resolver] picked $($pick.DriveLetter): ($($pick.DriveName)) for $MediaType, free=$($pick.FreeGB)GB, score=$scoreStr" "INFO"
    if ($DryRun) { return $pick }
    return $pick.AbsPath
}

function Invoke-DriveResolverTest {
    Write-Host "`n=== DriveResolver Test Harness ===" -ForegroundColor Magenta
    $inv = Get-DriveMetaInventory
    Write-Host "`nDrive inventory ($($inv.Count) drives with drive-meta.json):" -ForegroundColor Magenta
    foreach ($d in $inv) {
        $preferred = if ($d.Meta.drive_preferred_media) { $d.Meta.drive_preferred_media -join "," } else { "(none)" }
        Write-Host ("  {0}: {1,-30} type={2,-6} free={3,7}GB preferred=[{4}]" -f $d.DriveLetter, $d.Meta.drive_name, $d.Meta.drive_type, $d.FreeGB, $preferred) -ForegroundColor Gray
    }
    foreach ($mt in 'movie','tv','anime_series','anime_movie','game_pc') {
        Write-Host "`n--- $mt ---" -ForegroundColor Magenta
        $pick = Resolve-MediaPath -MediaType $mt -DryRun
        if ($pick) {
            Write-Host ("  pick:  {0}: ({1}) -> {2}" -f $pick.DriveLetter, $pick.DriveName, $pick.AbsPath) -ForegroundColor Green
            Write-Host ("  score: base={0} preferred={1} type={2} lastResort={3} freeGB*0.5={4:N1} -> total={5:N1}" -f $pick.Base, $pick.Preferred, $pick.TypeBonus, $pick.LastResort, ($pick.FreeGB * 0.5), $pick.Score) -ForegroundColor Gray
        }
    }
    Write-Host ""
}

# Run the test harness when this file is invoked directly (not dot-sourced).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DriveResolverTest
}
