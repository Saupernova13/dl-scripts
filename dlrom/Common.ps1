# Small helpers with no dependencies beyond Constants.ps1, shared by every other module.
# Each replaces a pattern that was open-coded in several places.

# The [rom] config section, published once by Add-ROM.ps1 so the modules that only ever
# read one or two keys do not each need it threaded through their signatures.
$script:DLROM_CFG = $null

function Set-DlromConfig {
    param($Cfg)
    $script:DLROM_CFG = $Cfg
}

# Read a value from a config section, tolerating a key that predates the current defaults.
#
# Initialize-DlConfig backfills new keys on load, but a hand-edited config can still be
# missing one, and $cfg.missingKey is $null rather than an error. Every read goes through
# here so "absent" and "explicitly blank" both fall back to the documented default.
#
# -Cfg is last and optional so the positional form `Get-CfgValue 'steamSync' $true` reads
# naturally against the ambient section, while a caller handed a section explicitly can still
# say `Get-CfgValue 'qbitHost' '' -Cfg $Cfg`.
function Get-CfgValue {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)]$Default = $null,
        $Cfg = $null
    )
    if ($null -eq $Cfg) { $Cfg = $script:DLROM_CFG }
    if ($null -eq $Cfg) { return $Default }
    if ($Cfg.PSObject.Properties.Name -notcontains $Name) { return $Default }
    $value = $Cfg.$Name
    if ($null -eq $value) { return $Default }
    # A blank string in config means "unset, use the default", never "use empty".
    if ($value -is [string] -and $value -eq '') { return $Default }
    return $value
}

# ISO-8601 UTC, the one timestamp format written into job files.
function Get-UtcStamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

# Where job files and caches live: %LOCALAPPDATA%\dlScripts on Windows, ~/.local/share
# on Linux. Get-DlDataRoot (lib/Platform.ps1) owns the difference.
function Get-DlScriptsDataDir {
    param([string]$SubPath = '')
    $dir = Get-DlDataRoot
    if ($SubPath) { $dir = Join-DlPath $dir $SubPath }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# Short, collision-resistant id for job ids and qBittorrent tags.
function New-ShortId {
    param([int]$Length = 12)
    return [guid]::NewGuid().ToString('N').Substring(0, $Length)
}

# Delete a directory only if it holds no files (at any depth). Used to tidy staging and
# extraction parents without ever removing something still in use.
function Remove-EmptyDirectory {
    param([string]$Path, [switch]$Recurse)
    if (-not $Path -or -not (Test-Path $Path)) { return }
    $targets = if ($Recurse) {
        @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    } else {
        @($Path)
    }
    foreach ($t in $targets) {
        if (Get-ChildItem -LiteralPath $t -Recurse -File -ErrorAction SilentlyContinue) { continue }
        Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Region helpers -----------------------------------------------------------
# Shared by the web scraper (region from a URL slug) and the torrent matcher (region from a
# Redump parenthetical). Different input formats, one vocabulary and one preference order.

# A --region argument's synonym -> canonical code ('' when unrecognised).
function Resolve-RegionRequest {
    param([string]$Region)
    $r = ([string]$Region).Trim().ToLower()
    if (-not $r) { return '' }
    foreach ($alias in $script:REGION_ALIASES) {
        if ($r -match $alias.Rx) { return $alias.Code }
    }
    return ''
}

# Rank a candidate's regions: 0 when it is what was asked for, then REGION_PREFERENCE
# order, then everything else. Lower is better.
function Get-RegionRank {
    param([string[]]$Regions, [string]$Requested)
    if ($Requested -and ($Regions -contains $Requested)) { return 0 }
    for ($i = 0; $i -lt $script:REGION_PREFERENCE.Count; $i++) {
        if ($Regions -contains $script:REGION_PREFERENCE[$i]) { return $i + 1 }
    }
    return 99
}

# Whole-phrase match against already-normalised text (see ConvertTo-Ps2Norm).
function Test-Phrase {
    param([string]$NormText, [string]$Phrase)
    return ($NormText -match ('\b' + [regex]::Escape($Phrase) + '\b'))
}

# --- PS Vita build helpers ----------------------------------------------------
# Turn the two inputs that mention a Vita build - a --vita argument and a download filename -
# into the one vocabulary from Constants.ps1, so the link filter, the extract-or-keep decision
# and the result block cannot disagree about what was downloaded.

# A --vita argument's synonym -> canonical build ('' when unrecognised or absent).
function Resolve-VitaBuild {
    param([string]$Build)
    $b = ([string]$Build).Trim().ToLower()
    if (-not $b) { return '' }
    foreach ($alias in $script:VITA_BUILD_ALIASES) {
        if ($b -match $alias.Rx) { return $alias.Code }
    }
    return ''
}

# Which build a filename advertises, or '' when it says nothing - an unmarked release, or a
# bonus file a page carries alongside the game. Never guesses: an unmarked file is unmarked.
function Get-VitaLinkBuild {
    param([string]$Label)
    $l = [string]$Label
    if ($l -match $script:VITA_EMU_RX)     { return $script:VITA_BUILD_EMU }
    if ($l -match $script:VITA_CONSOLE_RX) { return $script:VITA_BUILD_CONSOLE }
    return ''
}

# The build a whole set of chosen links represents, or '' when unmarked or in disagreement.
# Callers act on this rather than on what was requested, because link selection is allowed to
# fall back to the other build.
function Get-VitaLinksBuild {
    param([object[]]$Links)
    $builds = @($Links | ForEach-Object { Get-VitaLinkBuild $_.Label } |
                Where-Object { $_ } | Select-Object -Unique)
    if ($builds.Count -eq 1) { return $builds[0] }
    return ''
}
