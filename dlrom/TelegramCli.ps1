# dlrom's Telegram flags: --telegram-login, --telegram-status, --telegram-logout.
#
# CLI glue only: argument handling, prompts and output. The protocol lives in lib/Telegram/
# (dot-sourced by Add-ROM.ps1 as Telegram.ps1). Login is two-step so an agent without a TTY can
# drive it:
#
#   dlrom --telegram-login --phone +27821234567      sends the code, remembers the login
#   dlrom --telegram-login --code 12345              signs in (add --password for 2FA)
#   dlrom --telegram-login                           interactive host: prompts for each
#
# Exit codes: 0 ok / logged in, 1 error, 2 logged out or not logged in (status), 3 more input
# needed (code sent, or a 2FA password is required).

# True when a person can answer a prompt: a console is attached and stdin is not redirected.
function Test-DlromInteractive {
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { return $false }
}

# Read a secret without echoing it, as plain text for the SRP computation.
function Read-DlromSecret {
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# One result printer for human and --json output.
function Write-DlromTelegramResult {
    param([hashtable]$Result, [switch]$AsJson, [string]$Text)
    # Write-Host, not Write-Output: the caller's functions also return an exit code, and anything
    # on the output stream would be swallowed into that return value.
    if ($AsJson) { Write-Host ($Result | ConvertTo-Json -Depth 4) }
    elseif ($Text) { Write-Host $Text }
}

function Format-DlromTgUser {
    param($User)
    $name = (@($User.firstName, $User.lastName) | Where-Object { $_ }) -join ' '
    $handle = if ($User.username) { " (@$($User.username))" } else { '' }
    return "$name$handle, id $($User.id)"
}

# Seed the client's api_id / api_hash from config.json ([rom].telegramApiId / telegramApiHash);
# TG_API_ID / TG_API_HASH in the environment override them.
function Initialize-DlromTelegram {
    Set-TgCredentials -ApiId ([string](Get-CfgValue 'telegramApiId' '')) -ApiHash ([string](Get-CfgValue 'telegramApiHash' ''))
}

# Entry point for the three flags. Returns the process exit code.
function Invoke-DlromTelegram {
    param(
        [switch]$Login, [switch]$Status, [switch]$Logout,
        [string]$Phone = '', [string]$Code = '', [string]$Password = '',
        [switch]$AsJson
    )
    Initialize-DlromTelegram
    try {
        if ($Status) { return (Invoke-DlromTelegramStatus -AsJson:$AsJson) }
        if ($Logout) { return (Invoke-DlromTelegramLogout -AsJson:$AsJson) }
        return (Invoke-DlromTelegramLogin -Phone $Phone -Code $Code -Password $Password -AsJson:$AsJson)
    } catch {
        $msg = $_.Exception.Message
        Write-DlromTelegramResult @{ ok = $false; state = 'error'; error = $msg } -AsJson:$AsJson -Text "[ERROR] $msg"
        return 1
    }
}

function Invoke-DlromTelegramStatus {
    param([switch]$AsJson)
    # Without credentials the session cannot be used, but a missing session is still just
    # "not logged in" - answer that without demanding configuration.
    $session = Get-TgSession
    if ($session.userId) { Assert-TgCredentials }
    $st = Get-TgStatus
    if ($st.loggedIn) {
        Write-DlromTelegramResult (@{ ok = $true } + $st) -AsJson:$AsJson -Text ("Logged in as " + (Format-DlromTgUser $st) + ", phone +$($st.phone)")
        return 0
    }
    Write-DlromTelegramResult @{ ok = $true; loggedIn = $false; reason = $st.reason } -AsJson:$AsJson -Text $(if ($st.reason -eq 'not logged in') { 'Not logged in.' } else { "Not logged in ($($st.reason))." })
    return 2
}

function Invoke-DlromTelegramLogout {
    param([switch]$AsJson)
    $session = Get-TgSession
    if ($session.userId) { Assert-TgCredentials }
    $r = Invoke-TgLogout
    $text = if ($r.RemoteLogout) { 'Logged out and session deleted.' } else { 'Local session deleted.' }
    Write-DlromTelegramResult @{ ok = $true; loggedIn = $false; remoteLogout = $r.RemoteLogout } -AsJson:$AsJson -Text $text
    return 0
}

function Invoke-DlromTelegramLogin {
    param([string]$Phone, [string]$Code, [string]$Password, [switch]$AsJson)

    Assert-TgCredentials
    $session = Get-TgSession
    if (-not $Password -and $env:TG_2FA_PASSWORD) { $Password = $env:TG_2FA_PASSWORD }

    # Step 1: --phone
    if ($Phone) {
        $r = Send-TgLoginCode -Phone $Phone
        if ($r.LoggedIn) { return (Invoke-DlromTelegramStatus -AsJson:$AsJson) }
        Write-DlromTelegramResult @{ ok = $true; state = 'code_sent'; phone = $r.Phone; delivery = $r.DeliveryType; codeLength = $r.CodeLength } `
            -AsJson:$AsJson -Text "code sent to +$($r.Phone) via $($r.DeliveryType). Finish with: dlrom --telegram-login --code <code>"
        return 3
    }

    # Steps 2 and 3: --code and/or --password
    if ($Code -or ($Password -and $session.passwordNeeded)) {
        $r = Complete-TgLogin -Code $Code -Password $Password
        return (Write-DlromTelegramLoginOutcome $r -AsJson:$AsJson)
    }

    # Nothing supplied: already in, or ask a person.
    if ($session.userId) { return (Invoke-DlromTelegramStatus -AsJson:$AsJson) }
    if (-not (Test-DlromInteractive)) {
        $msg = 'Not interactive. Run "dlrom --telegram-login --phone +27..." to get a code, then "dlrom --telegram-login --code <code>" (add --password or TG_2FA_PASSWORD for 2FA).'
        Write-DlromTelegramResult @{ ok = $false; state = 'error'; error = $msg } -AsJson:$AsJson -Text "[ERROR] $msg"
        return 1
    }

    $phoneIn = Read-Host -Prompt 'Phone number (international format, e.g. +27821234567)'
    $r = Send-TgLoginCode -Phone $phoneIn
    if (-not $r.LoggedIn) {
        Write-Host "Code sent via $($r.DeliveryType)."
        $codeIn = Read-Host -Prompt 'Login code'
        $out = Complete-TgLogin -Code $codeIn
        if ($out.PasswordNeeded) {
            $pw = Read-DlromSecret 'Two-step verification password'
            $out = Complete-TgLogin -Password $pw
        }
        return (Write-DlromTelegramLoginOutcome $out -AsJson:$AsJson)
    }
    return (Invoke-DlromTelegramStatus -AsJson:$AsJson)
}

function Write-DlromTelegramLoginOutcome {
    param($Outcome, [switch]$AsJson)
    if ($Outcome.LoggedIn) {
        $u = $Outcome.User
        $info = @{ ok = $true; state = 'logged_in'; loggedIn = $true }
        $text = 'Logged in.'
        if ($u) {
            $info.id = [string]$u.id; $info.username = [string]$u.username
            $info.firstName = [string]$u.first_name; $info.lastName = [string]$u.last_name
            $text = 'Logged in as ' + (Format-DlromTgUser @{ firstName = $u.first_name; lastName = $u.last_name; username = $u.username; id = $u.id })
        }
        Write-DlromTelegramResult $info -AsJson:$AsJson -Text $text
        return 0
    }
    if ($Outcome.PasswordNeeded) {
        Write-DlromTelegramResult @{ ok = $true; state = 'password_needed' } -AsJson:$AsJson `
            -Text 'Two-step verification is enabled. Finish with: dlrom --telegram-login --password <password> (or set TG_2FA_PASSWORD).'
        return 3
    }
    Write-DlromTelegramResult @{ ok = $false; state = 'error'; error = 'login did not complete' } -AsJson:$AsJson -Text '[ERROR] login did not complete'
    return 1
}
