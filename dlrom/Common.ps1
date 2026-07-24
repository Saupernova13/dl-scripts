# Small helpers with no dependencies beyond Constants.ps1, shared by every other module.
#
# Each of these replaces a pattern that was open-coded in several places. Get-CfgValue in
# particular existed once as a function (closing over Add-ROM's $cfg) and about eight more
# times as an inline PSObject.Properties.Name test, so the modules that could not reach the
# function grew their own copy of the idea.

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
# -Cfg is last and optional on purpose: it keeps the common positional form
# `Get-CfgValue 'steamSync' $true` reading naturally against the ambient section, while
# Invoke-Ps2TorrentFallback - which is handed a section explicitly - can still say
# `Get-CfgValue 'qbitHost' '' -Cfg $Cfg`. Before this there were two spellings of the
# same idea: a closure in Add-ROM.ps1 and an inline PSObject.Properties test in every
# module that could not reach it.
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

# %LOCALAPPDATA%\dlScripts - where config.json, job files and caches all live.
function Get-DlScriptsDataDir {
    param([string]$SubPath = '')
    $dir = Join-Path $env:LOCALAPPDATA 'dlScripts'
    if ($SubPath) { $dir = Join-Path $dir $SubPath }
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
# Shared by the web scraper (region from a URL slug) and the torrent matcher (region from
# a Redump parenthetical). The two read different formats, but the vocabulary they produce
# and the preference order they rank by are the same, so both live here.

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
