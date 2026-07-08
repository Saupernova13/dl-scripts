# lib/DriveResolver.ps1
# Shared library for dl-scripts. Provides:
#   Initialize-DlConfig    - Bootstraps %LOCALAPPDATA%\dlScripts\config.json sections,
#                            backfilling any new keys from $Defaults into existing sections.
#   Get-DriveRegCli        - Locates the drive-registry CLI (env / config / PATH).
#   Get-DriveMetaInventory - Connected drives, from the drive-registry CLI.
#   Resolve-MediaPath      - Picks a destination drive for a media type via the CLI.
#
# The drive-picking logic lives in the drive-registry CLI (Documents\github\drive-registry),
# a PATH-registered command (`drivereg`). This library is a thin client: it shells out to
# `drivereg resolve <media> --json` and parses the result. There is no service and no port -
# each call runs the tool synchronously. If the CLI is missing, resolution fails loudly
# (install it: run install.ps1 in the drive-registry repo) rather than guessing a path.
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

# Locate the drive-registry CLI. Resolved from (in order): DRIVEREG_CLI env var (a path to the
# executable/.cmd), a top-level "driveRegistryCli" key in dlScripts config.json, then `drivereg`
# on PATH. Throws a clear, actionable error if none is found.
function Get-DriveRegCli {
    if ($env:DRIVEREG_CLI) { return [string]$env:DRIVEREG_CLI }
    $configPath = Join-Path (Join-Path $env:LOCALAPPDATA "dlScripts") "config.json"
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.driveRegistryCli) { return [string]$cfg.driveRegistryCli }
        } catch { }
    }
    $cmd = Get-Command 'drivereg' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "drivereg CLI not found on PATH. Install it: run install.ps1 in the drive-registry repo (adds it to your PATH), then open a new shell. Or set DRIVEREG_CLI to the drivereg.cmd path."
}

# Run the drive-registry CLI and return @{ Output = <stdout string>; ExitCode = <int> }.
# stderr is discarded so stdout stays clean JSON; the exit code carries success/failure.
function Invoke-DriveReg {
    param([Parameter(Mandatory=$true)][string[]]$CliArgs)
    $cli = Get-DriveRegCli
    $out = & $cli @CliArgs 2>$null
    return [PSCustomObject]@{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
}

# Connected drives as reported by the drive-registry CLI (letter, serial, freeGB, meta, ...).
function Get-DriveMetaInventory {
    $res = Invoke-DriveReg -CliArgs @('drives', '--json')
    if ($res.ExitCode -ne 0) {
        throw "Get-DriveMetaInventory: drivereg failed (exit $($res.ExitCode)). $($res.Output)"
    }
    try { $resp = $res.Output | ConvertFrom-Json }
    catch { throw "Get-DriveMetaInventory: could not parse drivereg output. $($res.Output)" }
    return $resp.drives
}

function Resolve-MediaPath {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('movie','tv','anime_series','anime_movie','game_pc','rom')]
        [string]$MediaType,
        [switch]$Strict,
        [switch]$DryRun
    )
    $cliArgs = @('resolve', $MediaType, '--json')
    if ($Strict) { $cliArgs += '--strict' }

    $res = Invoke-DriveReg -CliArgs $cliArgs

    # Exit 3 = --strict and no connected drive advertises this media type (was HTTP 409).
    if ($res.ExitCode -eq 3) {
        throw "Resolve-MediaPath: no connected drive advertises '$MediaType'."
    }
    if ($res.ExitCode -ne 0) {
        throw "Resolve-MediaPath: drivereg error (exit $($res.ExitCode)) resolving '$MediaType'. $($res.Output)"
    }

    try { $resp = $res.Output | ConvertFrom-Json }
    catch { throw "Resolve-MediaPath: could not parse drivereg output for '$MediaType'. $($res.Output)" }

    $pick = $resp.pick
    if (-not $pick) {
        # Non-strict, and no drive advertises this media type. Fall back to a home folder so the
        # download still lands somewhere (the CLI ran fine; it just had no candidate - e.g. every
        # target drive is disconnected).
        $fallback = Join-Path $HOME $MediaType
        Write-Log "[resolver] drivereg has no drive for '$MediaType' - falling back to $fallback" "WARN"
        if ($DryRun) { return $null }
        return $fallback
    }

    $freeStr = if ($null -ne $pick.freeGB) { "$($pick.freeGB)GB" } else { "?" }
    Write-Log "[resolver] picked $($pick.letter): ($($pick.driveName)) for $MediaType, free=$freeStr, priority=$($pick.priority)" "INFO"
    if ($DryRun) {
        return [PSCustomObject]@{
            DriveLetter = $pick.letter
            DriveName   = $pick.driveName
            Type        = $pick.type
            RelPath     = $pick.relPath
            AbsPath     = $pick.absPath
            FreeGB      = $pick.freeGB
            Priority    = $pick.priority
            LastResort  = $pick.lastResort
        }
    }
    return $pick.absPath
}

function Invoke-DriveResolverTest {
    Write-Host "`n=== DriveResolver (drive-registry CLI) ===" -ForegroundColor Magenta
    try {
        $cli = Get-DriveRegCli
        Write-Host "drivereg: $cli" -ForegroundColor Gray
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        return
    }

    $inv = Get-DriveMetaInventory
    Write-Host "`nDrive inventory ($($inv.Count) connected):" -ForegroundColor Magenta
    foreach ($d in $inv) {
        $name = if ($d.meta -and $d.meta.drive_name) { $d.meta.drive_name } else { "(no role)" }
        $type = if ($d.meta -and $d.meta.drive_type) { $d.meta.drive_type } else { "?" }
        Write-Host ("  {0}: {1,-30} type={2,-6} free={3,8}GB" -f $d.letter, $name, $type, $d.freeGB) -ForegroundColor Gray
    }

    foreach ($mt in 'movie','tv','anime_series','anime_movie','game_pc','rom') {
        Write-Host "`n--- $mt ---" -ForegroundColor Magenta
        $pick = Resolve-MediaPath -MediaType $mt -DryRun
        if ($pick) {
            Write-Host ("  pick:  {0}: ({1}) -> {2}" -f $pick.DriveLetter, $pick.DriveName, $pick.AbsPath) -ForegroundColor Green
            $lr = if ($pick.LastResort) { " last-resort" } else { "" }
            Write-Host ("  rank:  priority={0}{1} free={2}GB type={3}" -f $pick.Priority, $lr, $pick.FreeGB, $pick.Type) -ForegroundColor Gray
        } else {
            Write-Host "  (no drive advertises this media type)" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

# Run the test harness when this file is invoked directly (not dot-sourced).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-DriveResolverTest
}
