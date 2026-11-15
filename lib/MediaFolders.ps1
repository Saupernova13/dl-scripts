# MediaFolders.ps1
# Pure helpers that turn a torrent name into a library folder, so TV and anime episodes are
# filed as <root>\<Show>\Season NN instead of landing loose in the library root. Needs
# Join-DlPath from lib/Platform.ps1 (loaded by lib/DriveResolver.ps1). Nothing here touches
# the network, and nothing creates a directory.

# Cleans raw text into a single folder-name component: separators to spaces, invalid
# file-name characters dropped, edges trimmed. Returns $null when under 2 characters remain.
function ConvertTo-DlFolderName {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = $Text -replace '[._]', ' '
    $t = $t -replace '[<>:"/\\|?*]', ''
    $t = $t -replace '\s+', ' '
    $t = $t.Trim(' ', '-', '[', ']', '(', ')', '{', '}')
    $t = $t.TrimEnd('.', ' ')
    if ($t.Length -lt 2) { return $null }
    return $t
}

function Get-DlShowName {
    param(
        [string]$TorrentName,
        [switch]$Anime
    )
    if (-not $TorrentName) { return $null }
    $n = $TorrentName -replace '[._]', ' '

    if ($Anime) {
        # Drop leading release-group tags such as "[SubsPlease] ".
        $n = $n -replace '^\s*(\[[^\]]*\]\s*)+', ''
        $m = [regex]::Match($n, '\s+-\s+\d+|\[|\(|\b\d{3,4}p\b|\bBatch\b|\bComplete\b', 'IgnoreCase')
        if ($m.Success) { $n = $n.Substring(0, $m.Index) }
        return (ConvertTo-DlFolderName $n)
    }

    $pattern = '\bS\d{1,2}E\d{1,3}|\bS\d{1,2}\b|\bSeasons?[\s._-]*\d+|\bComplete\b|\b\d{3,4}p\b|\b(?:19|20)\d{2}\b'
    $m = [regex]::Match($n, $pattern, 'IgnoreCase')
    $year = $null
    if ($m.Success) {
        if ($m.Value -match '^(19|20)\d{2}$') { $year = $m.Value }
        $n = $n.Substring(0, $m.Index)
    }
    $name = ConvertTo-DlFolderName $n
    if (-not $name) { return $null }
    if ($year) { return "$name ($year)" }
    return $name
}

function Get-DlSeasonNumber {
    param([string]$TorrentName)
    if (-not $TorrentName) { return $null }
    $n = $TorrentName -replace '[._]', ' '

    # Ranges and complete series span several seasons: no single season folder fits.
    if ($n -match '\bS\d{1,2}\s*-\s*S?\d' -or
        $n -match '\bSeasons\b' -or
        $n -match '\bComplete[\s-]*(Series|Collection)\b') { return $null }

    $seasons = @()
    foreach ($m in [regex]::Matches($n, '\bS(\d{1,2})(?!\d)|\bSeason[\s-]*(\d{1,2})(?!\d)', 'IgnoreCase')) {
        $v = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        $seasons += [int]$v
    }
    $seasons = @($seasons | Select-Object -Unique)
    if ($seasons.Count -ne 1) { return $null }
    return $seasons[0]
}

# Lowercase, drop a trailing "(YYYY)", drop everything that is not a letter or digit.
function ConvertTo-DlShowKey {
    param([string]$Name)
    $k = $Name.ToLowerInvariant() -replace '\s*\((?:19|20)\d{2}\)\s*$', ''
    return ($k -replace '[^a-z0-9]', '')
}

function Resolve-DlShowFolder {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )
    if (Test-Path -LiteralPath $Root -PathType Container) {
        $key = ConvertTo-DlShowKey $Name
        if ($key) {
            $hit = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
                   Where-Object { (ConvertTo-DlShowKey $_.Name) -eq $key } |
                   Sort-Object Name | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return (Join-DlPath $Root $Name)
}

function Get-DlEpisodeSavePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$TorrentName,
        [string]$Fallback,
        [switch]$Anime,
        [switch]$CompleteSeries
    )
    $show = Get-DlShowName -TorrentName $TorrentName -Anime:$Anime
    if (-not $show) { $show = ConvertTo-DlFolderName $Fallback }
    if (-not $show) { return $Root }   # nothing usable; keep the old behaviour

    $folder = Resolve-DlShowFolder -Root $Root -Name $show
    if ($Anime -or $CompleteSeries) { return $folder }
    $season = Get-DlSeasonNumber -TorrentName $TorrentName
    if ($null -eq $season) { return $folder }
    return (Join-DlPath $folder ('Season {0:D2}' -f $season))
}
