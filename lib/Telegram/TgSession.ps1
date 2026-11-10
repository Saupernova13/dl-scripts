# Telegram MTProto - session persistence and credentials.
#
# One JSON file, <data root>/telegram/session.json, holds everything needed to resume without a
# new login: the home DC, an auth key + server salt per DC, the user id, a pending login's
# phone / phone_code_hash, and cached peer access hashes. The auth key IS the account, so the
# file (and its directory) is restricted to the current user and no function here ever logs a
# key, salt or hash.
#
# In memory the session is a hashtable:
#   dcId       home DC (0 = not chosen yet)
#   userId     logged-in user id, 0 = not logged in
#   phone, phoneCodeHash, passwordNeeded   a login in progress
#   dcs        '<dc>' -> @{ authKey = <base64>; salt = '<long>'; timeOffset = <int>; authorized = <bool> }
#   dcAddresses  '<dc>' -> @('ip', ...)   learned from help.getConfig
#   peers      'username' -> @{ type; id = '<long>'; accessHash = '<long>' }
#
# Depends on lib/Platform.ps1 (Join-DlPath, Test-DlWindows, Get-DlDataRoot).

$script:TG_DATA_DIR = $null     # tests (or a power user) can point the whole client elsewhere
$script:TG_SESSION  = $null
$script:TG_API_ID   = $null
$script:TG_API_HASH = $null

# --- credentials ------------------------------------------------------------------------------------

# api_id / api_hash from https://my.telegram.org. Env vars TG_API_ID / TG_API_HASH win over
# whatever the caller (dlrom's config.json) supplies.
function Set-TgCredentials {
    param([string]$ApiId = '', [string]$ApiHash = '')
    $id   = if ($env:TG_API_ID)   { $env:TG_API_ID }   else { $ApiId }
    $hash = if ($env:TG_API_HASH) { $env:TG_API_HASH } else { $ApiHash }
    $script:TG_API_ID   = ([string]$id).Trim()
    $script:TG_API_HASH = ([string]$hash).Trim()
}

function Test-TgCredentials {
    return ([bool]$script:TG_API_ID -and [bool]$script:TG_API_HASH -and ($script:TG_API_ID -match '^\d+$'))
}

# A clear, actionable failure for the very common "never configured" case.
function Assert-TgCredentials {
    if (Test-TgCredentials) { return }
    throw (New-TgException ('Telegram api_id / api_hash are not set. Create an app at https://my.telegram.org, ' +
        'then put the values in config.json ([rom].telegramApiId and [rom].telegramApiHash) ' +
        'or set the TG_API_ID and TG_API_HASH environment variables.') @{ tgConfig = $true })
}

# --- files and permissions --------------------------------------------------------------------------

function Get-TgDataDir {
    $dir = if ($script:TG_DATA_DIR) { $script:TG_DATA_DIR } else { Join-DlPath (Get-DlDataRoot) 'telegram' }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Protect-TgPath $dir -Directory
    }
    return $dir
}

function Get-TgSessionPath { return (Join-Path (Get-TgDataDir) 'session.json') }

# Windows: strip inherited ACEs and grant the current user only. Linux: chmod 700 / 600.
function Protect-TgPath {
    param([string]$Path, [switch]$Directory)
    try {
        if (Test-DlWindows) {
            $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $grant = if ($Directory) { "${user}:(OI)(CI)F" } else { "${user}:F" }
            & icacls $Path /inheritance:r /grant:r $grant 2>&1 | Out-Null
        } else {
            & chmod $(if ($Directory) { '700' } else { '600' }) $Path 2>&1 | Out-Null
        }
    } catch {
        Write-Warning "Could not restrict permissions on $Path : $($_.Exception.Message)"
    }
}

# JSON -> nested hashtables (ConvertFrom-Json yields PSCustomObjects, awkward to mutate).
function ConvertTo-TgHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-TgHashtable $p.Value }
        return $h
    }
    if ($Value -is [System.Array]) {
        return ,@($Value | ForEach-Object { ConvertTo-TgHashtable $_ })
    }
    return $Value
}

function New-TgEmptySession {
    return @{
        version = 1; dcId = 0; userId = 0
        phone = ''; phoneCodeHash = ''; passwordNeeded = $false
        dcs = @{}; dcAddresses = @{}; peers = @{}
    }
}

# Load the session from disk (once); an absent or unreadable file yields an empty session.
function Get-TgSession {
    param([switch]$Reload)
    if ($script:TG_SESSION -and -not $Reload) { return $script:TG_SESSION }
    $session = New-TgEmptySession
    $path = Get-TgSessionPath
    if (Test-Path -LiteralPath $path) {
        try {
            $loaded = ConvertTo-TgHashtable ((Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json)
            foreach ($k in $loaded.Keys) { $session[$k] = $loaded[$k] }
        } catch {
            Write-Warning "Telegram session file is unreadable and will be ignored: $($_.Exception.Message)"
        }
    }
    foreach ($k in 'dcs', 'dcAddresses', 'peers') {
        if ($session[$k] -isnot [hashtable]) { $session[$k] = @{} }
    }
    $script:TG_SESSION = $session
    return $session
}

# Write atomically (temp file in the same directory, then rename) with owner-only rights.
function Save-TgSession {
    $session = Get-TgSession
    $path = Get-TgSessionPath
    $tmp  = "$path.tmp"
    $isNew = -not (Test-Path -LiteralPath $path)
    [System.IO.File]::WriteAllText($tmp, '', (New-Object System.Text.UTF8Encoding $false))
    if (-not (Test-DlWindows)) { Protect-TgPath $tmp }
    $json = $session | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Move-Item -LiteralPath $tmp -Destination $path -Force
    if ($isNew -and (Test-DlWindows)) { Protect-TgPath $path }
}

# Forget everything: delete the file and the in-memory copy.
function Remove-TgSession {
    $path = Get-TgSessionPath
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    $script:TG_SESSION = $null
}

# --- per-DC key storage --------------------------------------------------------------------------------

function Get-TgDcEntry {
    param([int]$Dc)
    $s = Get-TgSession
    $e = $s.dcs[[string]$Dc]
    if ($e -is [hashtable] -and $e.authKey) { return $e }
    return $null
}

function Set-TgDcEntry {
    param([int]$Dc, $Conn, [bool]$Authorized = $false)
    $s = Get-TgSession
    $prev = $s.dcs[[string]$Dc]
    $auth = $Authorized -or ($prev -is [hashtable] -and [bool]$prev.authorized)
    $s.dcs[[string]$Dc] = @{
        authKey    = [Convert]::ToBase64String($Conn.AuthKey)
        salt       = [string][long]$Conn.Salt
        timeOffset = [int]$Conn.TimeOffset
        authorized = $auth
    }
    Save-TgSession
}

function Remove-TgDcEntry {
    param([int]$Dc)
    $s = Get-TgSession
    $s.dcs.Remove([string]$Dc)
    Save-TgSession
}
