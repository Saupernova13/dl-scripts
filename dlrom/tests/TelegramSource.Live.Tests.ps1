# Live check of the Telegram ROM source: a real search against two NSWTL bots through the
# logged-in account. Two messages in all, human-paced; it never sends /download.
#
# Needs: a logged-in session (dlrom --telegram-login) and telegramApiId/telegramApiHash in
# config.json. Skipped with a note when either is missing. Tagged 'Live';
# run with: Invoke-Tests.ps1 -Live -Only

Describe 'Telegram source live search' -Tag 'Live' {
    BeforeAll {
        $moduleRoot = Split-Path -Parent $PSScriptRoot
        $repoRoot   = Split-Path -Parent $moduleRoot
        . (Join-Path $repoRoot 'lib/Platform.ps1')
        . (Join-Path $moduleRoot 'Constants.ps1')
        . (Join-Path $moduleRoot 'Common.ps1')
        . (Join-Path $moduleRoot 'Logging.ps1')
        . (Join-Path $moduleRoot 'RetroGameTalk.ps1')
        . (Join-Path $moduleRoot 'Ps2TorrentIndex.ps1')
        . (Join-Path $repoRoot 'lib/Telegram/Telegram.ps1')
        . (Join-Path $moduleRoot 'NswtlBot.ps1')
        . (Join-Path $moduleRoot 'TelegramSource.ps1')
        $script:LOG_QUIET = $true

        $script:Ready = $false
        $configPath = Join-Path (Get-DlConfigRoot) 'config.json'
        if (Test-Path -LiteralPath $configPath) {
            $rom = (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).rom
            Set-DlromConfig $rom
            Set-TgCredentials -ApiId ([string]$rom.telegramApiId) -ApiHash ([string]$rom.telegramApiHash)
            $script:Ready = [bool]((Get-TgSession).userId)
        }
        $script:Family = Get-NswtlBotFamily
    }

    It 'finds Danganronpa on the PS Vita bot' {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because 'no logged-in Telegram session'; return }
        [void](Connect-Telegram)
        $peer = Resolve-TgPeer (Get-TgBotName -Key 'vita' -Overrides (Get-CfgValue 'telegramBots' $null))
        $s = Find-TgRomResults -Peer $peer -Query 'Danganronpa' -Family $script:Family -Platform 'psvita' -TimeoutSec 30
        $s.Kind | Should -Be 'results'
        $pick = Select-TgResult -Results $s.Results -Query 'Danganronpa'
        $pick.Title | Should -Match 'Danganronpa'
        $pick.DownloadCmd | Should -Match '^/download\d+$'
    }

    It 'finds Bloodborne on the PS4 bot (a console RetroGameTalk does not carry)' {
        if (-not $script:Ready) { Set-ItResult -Skipped -Because 'no logged-in Telegram session'; return }
        Start-Sleep -Seconds 4
        [void](Connect-Telegram)
        $peer = Resolve-TgPeer (Get-TgBotName -Key 'ps4' -Overrides (Get-CfgValue 'telegramBots' $null))
        $s = Find-TgRomResults -Peer $peer -Query 'Bloodborne' -Family $script:Family -Platform 'ps4' -TimeoutSec 30
        $s.Kind | Should -Be 'results'
        (Select-TgResult -Results $s.Results -Query 'Bloodborne').DownloadCmd | Should -Match '^/download\d+$'
    }
}
