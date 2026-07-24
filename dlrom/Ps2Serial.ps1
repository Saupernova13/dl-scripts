# Ps2Serial.ps1
# Resolves an installed PS2 game's title to its serial via PCSX2's GameIndex.yaml
# (the same source dlps2tex uses), so dlrom can tell an agent exactly which version
# to fetch matching HD textures for. Also prints dlrom's end-of-run result block
# plus the ready-to-run dlps2tex handoff.
#
# Reuses ConvertTo-Ps2Norm / Get-Ps2Significant from Ps2TorrentIndex.ps1 and
# Resolve-RegionRequest / Get-CfgValue from Common.ps1 (all dot-sourced into the same
# scope). Region codes and the demo marker come from Constants.ps1.

function Get-Ps2GameIndexPath {
    param($Cfg)
    $cfgPath = [string](Get-CfgValue 'ps2GameIndexPath' '' -Cfg $Cfg)
    if ($cfgPath -and (Test-Path $cfgPath)) { return $cfgPath }
    $default = Join-Path $env:APPDATA 'EmuDeck\Emulators\PCSX2-Qt\resources\GameIndex.yaml'
    if (Test-Path $default) { return $default }
    return ''
}

function Get-Ps2GameDbCachePath {
    return (Join-Path (Get-DlScriptsDataDir) 'ps2-gamedb.json')
}

# Parse GameIndex.yaml into [{Serial,Name,NameEn,Region}]. Cached to JSON keyed by
# the source file's write time so the ~2.7 MB parse happens at most once per update.
function Import-Ps2GameDb {
    param([string]$IndexPath)
    if (-not $IndexPath -or -not (Test-Path $IndexPath)) { return @() }

    $cache   = Get-Ps2GameDbCachePath
    $srcTicks = (Get-Item $IndexPath).LastWriteTimeUtc.Ticks
    if (Test-Path $cache) {
        try {
            $c = Get-Content $cache -Raw | ConvertFrom-Json
            if ([long]$c.srcTicks -eq $srcTicks) { return @($c.entries) }
        } catch { }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $serial = $null; $name = $null; $nameEn = $null; $region = $null
    foreach ($line in [System.IO.File]::ReadLines($IndexPath)) {
        $sm = [regex]::Match($line, '^([A-Z]{4}-\d{5}):\s*$')
        if ($sm.Success) {
            if ($serial) { $entries.Add([PSCustomObject]@{ Serial = $serial; Name = $name; NameEn = $nameEn; Region = $region }) }
            $serial = $sm.Groups[1].Value; $name = $null; $nameEn = $null; $region = $null
            continue
        }
        if (-not $serial) { continue }
        $fm = [regex]::Match($line, '^\s{2}([a-zA-Z\-]+):\s*"?([^"]*?)"?\s*$')
        if (-not $fm.Success) { continue }
        switch ($fm.Groups[1].Value) {
            'name'    { $name   = $fm.Groups[2].Value }
            'name-en' { $nameEn = $fm.Groups[2].Value }
            'region'  { $region = $fm.Groups[2].Value }
        }
    }
    if ($serial) { $entries.Add([PSCustomObject]@{ Serial = $serial; Name = $name; NameEn = $nameEn; Region = $region }) }

    $arr = $entries.ToArray()
    try {
        $dir = Split-Path $cache -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        @{ srcTicks = $srcTicks; entries = $arr } | ConvertTo-Json -Depth 5 -Compress | Set-Content $cache -Encoding UTF8
    } catch { }
    return $arr
}

# Resolve a downloaded title (+ its region) to the matching GameIndex serial.
# Mirrors dlps2tex's scoring so the two agree, and strongly prefers the serial of
# the region actually downloaded. Returns the entry object or $null.
function Resolve-Ps2Serial {
    param([string]$Title, [string]$Region, $Cfg)

    $idx = Get-Ps2GameIndexPath -Cfg $Cfg
    if (-not $idx) { return $null }
    $db = @(Import-Ps2GameDb -IndexPath $idx)
    if ($db.Count -eq 0) { return $null }

    if ($Title -match '^[A-Z]{4}-\d{5}$') {
        $d = $db | Where-Object { $_.Serial -eq $Title } | Select-Object -First 1
        if ($d) { return $d }
    }

    $canonical  = Resolve-RegionRequest $Region
    $regionCode = if ($canonical -and $script:PS2_REGION_CODES.ContainsKey($canonical)) {
        $script:PS2_REGION_CODES[$canonical]
    } else { '' }

    $qn      = ConvertTo-Ps2Norm $Title
    $qTokens = Get-Ps2Significant $Title
    $best = $null; $bestScore = 0

    foreach ($e in $db) {
        $score = 0
        foreach ($cand in @($e.Name, $e.NameEn)) {
            if (-not $cand) { continue }
            $cn = ConvertTo-Ps2Norm $cand
            if ($cn -eq $qn)                 { if ($score -lt 1000) { $score = 1000 } }
            elseif ($cn.StartsWith("$qn "))  { if ($score -lt 700)  { $score = 700 } }
            elseif ($cn -like "* $qn *")     { if ($score -lt 500)  { $score = 500 } }
            elseif ($cn.Contains($qn))       { if ($score -lt 300)  { $score = 300 } }
            elseif ($qTokens.Count -gt 0) {
                $cTokens = Get-Ps2Significant $cand
                $all = $true
                foreach ($t in $qTokens) { if ($cTokens -notcontains $t) { $all = $false; break } }
                if ($all -and $score -lt 200) { $score = 200 }
            }
        }
        if ($score -le 0) { continue }

        if ($regionCode -and $e.Region -eq $regionCode) { $score += 500 }
        elseif ($e.Region -eq 'NTSC-U') { $score += 30 }
        elseif ($e.Region -eq 'PAL')    { $score += 20 }
        elseif ($e.Region -eq 'NTSC-J') { $score += 10 }

        if (($e.Name -and $e.Name -match $script:DEMO_RX) -or ($e.NameEn -and $e.NameEn -match $script:DEMO_RX)) { $score -= 500 }

        if ($score -gt $bestScore) { $bestScore = $score; $best = $e }
    }
    if ($bestScore -le 0) { return $null }
    return $best
}

# Print the end-of-run result and, for PS2, the dlps2tex handoff for the SAME
# version. The machine-readable [HANDOFF] line lets an agent grab the exact
# texture command without parsing prose.
# Prints the human-readable result block and returns the machine-readable [HANDOFF] line
# (empty for non-PS2), so a caller can stash it on the job for --status/--json to serve.
function Write-DlromResult {
    param([string]$Title, [string]$Platform, [string]$Region = '', [string]$Source = '', [string]$InstalledPath = '', $Cfg)

    $handoffLine = ''
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor DarkGray
    Write-Host "dlrom installed a ROM" -ForegroundColor Green
    Write-Host "  game:     $Title"
    Write-Host "  platform: $Platform"
    if ($Region)        { Write-Host "  region:   $Region" }
    if ($Source)        { Write-Host "  source:   $Source" }
    if ($InstalledPath) { Write-Host "  file:     $InstalledPath" }

    if ($Platform -eq 'ps2') {
        $serial = ''
        $handoff = $Title
        $resolved = $null
        try { $resolved = Resolve-Ps2Serial -Title $Title -Region $Region -Cfg $Cfg } catch { }
        if ($resolved) {
            $serial  = $resolved.Serial
            $handoff = $serial
            Write-Host "  serial:   $serial ($($resolved.Region))"
        }
        Write-Host ""
        Write-Host "Matching HD textures for the SAME version - run:" -ForegroundColor Cyan
        Write-Host "  dlps2tex `"$handoff`""
        $handoffLine = "[HANDOFF] platform=ps2 serial=$serial title=`"$Title`" texturecmd=dlps2tex `"$handoff`""
        Write-Host $handoffLine
    }
    Write-Host ("=" * 64) -ForegroundColor DarkGray
    Write-Host ""
    return $handoffLine
}
