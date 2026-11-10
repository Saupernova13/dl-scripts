# Telegram MTProto - login, status and logout.
#
# Login is deliberately two separate steps so an agent can drive it without a TTY:
#   1. Send-TgLoginCode  -Phone +27...      auth.sendCode; phone and phone_code_hash go to the session
#   2. Complete-TgLogin  -Code 12345        auth.signIn; if the account has 2FA the call reports
#                                            PasswordNeeded and the session remembers it
#   3. Complete-TgLogin  -Password ...      account.getPassword + SRP + auth.checkPassword
# (-Code and -Password can be given together.)
#
# Depends on TgClient.ps1, TgCrypto.ps1 (SRP) and TgSession.ps1.

# Step 1: ask Telegram to send a login code. Returns @{ Phone; DeliveryType; CodeLength }.
function Send-TgLoginCode {
    param([Parameter(Mandatory)][string]$Phone)
    Assert-TgCredentials
    $phone = ($Phone -replace '[\s\-()]', '')
    if ($phone -notmatch '^\+?\d{6,15}$') { throw (New-TgException "That does not look like a phone number: '$Phone'. Use international format, e.g. +27821234567.") }
    $phone = $phone.TrimStart('+')

    [void](Connect-Telegram)
    $res = Invoke-TgApi ([ordered]@{
        _ = 'auth.sendCode'; phone_number = $phone
        api_id = [int]$script:TG_API_ID; api_hash = $script:TG_API_HASH
        settings = [ordered]@{ _ = 'codeSettings' }
    })
    if ($res._ -eq 'auth.sentCodeSuccess') {
        # Already authorised by an existing session on this key: nothing to type in.
        Complete-TgAuthorization $res.authorization
        return @{ Phone = $phone; DeliveryType = 'success'; CodeLength = 0; LoggedIn = $true }
    }
    if ($res._ -ne 'auth.sentCode') { throw (New-TgException "Telegram answered auth.sendCode with $($res._); cannot continue.") }

    $s = Get-TgSession
    $s.phone = $phone
    $s.phoneCodeHash = [string]$res.phone_code_hash
    $s.passwordNeeded = $false
    Save-TgSession
    $len = 0
    if ($res.type.length) { $len = [int]$res.type.length }
    return @{ Phone = $phone; DeliveryType = ([string]$res.type._ -replace '^auth\.sentCodeType', ''); CodeLength = $len; LoggedIn = $false }
}

# Record a successful auth.authorization in the session.
function Complete-TgAuthorization {
    param($Authorization)
    if ($Authorization._ -eq 'auth.authorizationSignUpRequired') {
        throw (New-TgException 'This phone number has no Telegram account yet. Register it in the official app first, then log in here.')
    }
    $s = Get-TgSession
    $s.userId = [string]$Authorization.user.id
    $s.phoneCodeHash = ''
    $s.passwordNeeded = $false
    $conn = $script:TG_CONNS[[int]$s.dcId]
    if ($conn) { Set-TgDcEntry ([int]$s.dcId) $conn $true } else { Save-TgSession }
}

# SRP half of login: account.getPassword -> proof -> auth.checkPassword.
function Invoke-TgPasswordLogin {
    param([Parameter(Mandatory)][string]$Password)
    $pw = Invoke-TgApi ([ordered]@{ _ = 'account.getPassword' })
    if (-not $pw.has_password -or -not $pw.current_algo) { throw (New-TgException 'Telegram reports no 2FA password is set on this account.') }
    $algo = $pw.current_algo
    if ($algo._ -ne 'passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow') {
        throw (New-TgException "Unsupported 2FA algorithm '$($algo._)'. Update dlScripts.")
    }
    $check = New-TgSrpCheck -Password $Password -Algo $algo -SrpB ([byte[]]$pw.srp_B) -SrpId $pw.srp_id
    $res = Invoke-TgApi ([ordered]@{ _ = 'auth.checkPassword'; password = $check })
    Complete-TgAuthorization $res
}

# Steps 2 and 3. Returns @{ LoggedIn = <bool>; PasswordNeeded = <bool>; User = <user or $null> }.
# Throws on a wrong or expired code / password with Telegram's own error name in the message.
function Complete-TgLogin {
    param([string]$Code = '', [string]$Password = '')
    Assert-TgCredentials
    $s = Get-TgSession
    [void](Connect-Telegram)

    if ($Code) {
        if (-not $s.phone -or -not $s.phoneCodeHash) {
            throw (New-TgException 'No login in progress. Request a code first: dlrom --telegram-login --phone +27...')
        }
        try {
            $res = Invoke-TgApi ([ordered]@{
                _ = 'auth.signIn'; phone_number = $s.phone; phone_code_hash = $s.phoneCodeHash
                phone_code = ($Code -replace '\s', '')
            })
            Complete-TgAuthorization $res
        } catch {
            if ([string]$_.Exception.Data['tgError'] -eq 'SESSION_PASSWORD_NEEDED') {
                $s.passwordNeeded = $true
                Save-TgSession
                if (-not $Password) { return @{ LoggedIn = $false; PasswordNeeded = $true; User = $null } }
            } else { throw }
        }
    }

    if (-not $s.userId -and $Password) {
        if (-not $s.passwordNeeded -and -not $Code) {
            throw (New-TgException 'Nothing is waiting for a password. Send the login code first.')
        }
        Invoke-TgPasswordLogin $Password
    } elseif (-not $s.userId) {
        return @{ LoggedIn = $false; PasswordNeeded = [bool]$s.passwordNeeded; User = $null }
    }
    return @{ LoggedIn = $true; PasswordNeeded = $false; User = (Get-TgSelf) }
}

# users.getUsers [inputUserSelf]: the logged-in user object, or $null when the key is not
# (or no longer) authorised.
function Get-TgSelf {
    try {
        $users = Invoke-TgApi ([ordered]@{ _ = 'users.getUsers'; id = @([ordered]@{ _ = 'inputUserSelf' }) })
    } catch {
        $name = [string]$_.Exception.Data['tgError']
        if ($name -match '^(AUTH_KEY_UNREGISTERED|SESSION_REVOKED|SESSION_EXPIRED|USER_DEACTIVATED|AUTH_KEY_INVALID)') { return $null }
        throw
    }
    $u = @($users) | Select-Object -First 1
    if (-not $u -or $u._ -ne 'user') { return $null }
    return $u
}

# Status for display / JSON. Does not touch the network when there is no session.
function Get-TgStatus {
    $s = Get-TgSession
    if (-not $s.userId) {
        return @{ loggedIn = $false; reason = $(if ($s.phoneCodeHash) { 'login in progress (code sent, not yet entered)' } else { 'not logged in' }) }
    }
    $u = Get-TgSelf
    if (-not $u) { return @{ loggedIn = $false; reason = 'session is no longer valid' } }
    return @{
        loggedIn = $true; id = [string]$u.id; username = [string]$u.username
        firstName = [string]$u.first_name; lastName = [string]$u.last_name
        phone = [string]$u.phone; dc = [int]$s.dcId
    }
}

# auth.logOut (best effort) and forget the session either way.
function Invoke-TgLogout {
    $s = Get-TgSession
    $remote = $false
    if ($s.userId) {
        try {
            [void](Invoke-TgApi ([ordered]@{ _ = 'auth.logOut' }))
            $remote = $true
        } catch { Write-Verbose "auth.logOut failed: $($_.Exception.Message)" }
    }
    Disconnect-Telegram
    Remove-TgSession
    return @{ RemoteLogout = $remote }
}
