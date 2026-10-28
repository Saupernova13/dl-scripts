# Offline tests for the KissKH client: kkey signing, subtitle decryption, title matching, the
# fallback decision and episode selection. Nothing here touches the network; the search and
# drama fixtures are captures of the real API.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Lib  = Join-Path (Split-Path -Parent $script:Root) 'lib'
    . (Join-Path $script:Lib 'Platform.ps1')
    . (Join-Path $script:Root 'KissKH.ps1')
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    function Read-Fixture {
        param([string]$Name)
        return [System.IO.File]::ReadAllText((Join-Path $script:Fixtures $Name), [System.Text.Encoding]::UTF8)
    }
    $script:Search = @(ConvertFrom-DltvJsonList (Read-Fixture 'search-bad-buddy.json'))
    $script:Drama  = (Read-Fixture 'drama-4540.json') | ConvertFrom-Json

    # Encrypt like the site does, so decryption is tested against an independent path.
    function Protect-TestText {
        param([string]$Text, [string]$Key, [string]$Iv)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $aes.Key = [System.Text.Encoding]::UTF8.GetBytes($Key)
        $aes.IV  = [System.Text.Encoding]::UTF8.GetBytes($Iv)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return [Convert]::ToBase64String($aes.CreateEncryptor().TransformFinalBlock($bytes, 0, $bytes.Length))
    }
}

Describe 'kkey' {
    It 'hashes the video plaintext to the known value' {
        $plain = Get-KissKHKkeyPlaintext -EpisodeId 84998 -Guid $script:KISSKH_GUID_VIDEO
        $plain | Should -Be '|9843552748|84998||mg3c3b04ba|2.8.10|62f176f3bb1b5b8e70e39932ad34a0c7|4830201|kisskh|kisskh|kisskh|kisskh|kisskh|kisskh|00|'
        $plain.Length | Should -Be 123
    }

    It 'hashes the subtitle plaintext to the known value' {
        Get-KissKHKkeyPlaintext -EpisodeId 84998 -Guid $script:KISSKH_GUID_SUB |
            Should -Be '|2757044353|84998||mg3c3b04ba|2.8.10|VgV52sWhwvBSf8BsM3BRY9weWiiCbtGp|4830201|kisskh|kisskh|kisskh|kisskh|kisskh|kisskh|00|'
    }

    It 'keeps the hash outside int32 range (only the shift truncates)' {
        $h = Get-KissKHHash '|84998||mg3c3b04ba|2.8.10|62f176f3bb1b5b8e70e39932ad34a0c7|4830201|kisskh|kisskh|kisskh|kisskh|kisskh|kisskh|00|'
        $h | Should -BeGreaterThan ([int]::MaxValue)
    }

    It 'is 256 uppercase hex characters' {
        $k = New-KissKHVideoKkey 84998
        $k.Length | Should -Be 256
        $k | Should -MatchExactly '^[0-9A-F]{256}$'
    }

    It 'differs between the video and subtitle keys and between episodes' {
        (New-KissKHVideoKkey 84998) | Should -Not -Be (New-KissKHSubKkey 84998)
        (New-KissKHVideoKkey 84998) | Should -Not -Be (New-KissKHVideoKkey 84999)
    }

    It 'builds key and IV bytes big-endian from the signed words' {
        $key = ConvertTo-KissKHWordBytes $script:KISSKH_KKEY_KEY_WORDS
        $iv  = ConvertTo-KissKHWordBytes $script:KISSKH_KKEY_IV_WORDS
        (($key | ForEach-Object { $_.ToString('x2') }) -join '') | Should -Be '4f6bdaa39e2f8cb07f5e722d9edef314'
        (($iv  | ForEach-Object { $_.ToString('x2') }) -join '') | Should -Be '01504af356e619cf2e42bba68c3f70f9'
    }
}

Describe 'stream response' {
    It 'reads the Video url' {
        Get-KissKHVideoUrlFromJson '{"Video":"https://x.example/a.mp4?sig=1","ThirdParty":""}' | Should -Be 'https://x.example/a.mp4?sig=1'
    }
    It 'treats an empty Video as unreleased' {
        Get-KissKHVideoUrlFromJson '{"Video":""}' | Should -BeNullOrEmpty
    }
    It 'treats a tickcounter placeholder as unreleased' {
        Get-KissKHVideoUrlFromJson '{"Video":"https://www.tickcounter.com/countdown/1"}' | Should -BeNullOrEmpty
    }
}

Describe 'subtitle decryption' {
    BeforeAll {
        $script:Srt = "1`n00:00:01,000 --> 00:00:02,000`n{0}`n`n2`n00:00:03,000 --> 00:00:04,000`n{1}`n"
    }

    It 'picks the extension ignoring query and fragment' {
        Get-KissKHSubtitleExtension 'https://h/a/b.SRT?x=1.txt#f' | Should -Be 'srt'
        Get-KissKHSubtitleExtension 'https://h/a/b.txt1?v=2'      | Should -Be 'txt1'
        Get-KissKHSubtitleExtension 'https://h/a/noext'           | Should -Be ''
    }

    It 'returns .srt untouched' {
        $text = "1`n00:00:01,000 --> 00:00:02,000`nplain`n"
        ConvertFrom-KissKHSubtitle -Text $text -Extension 'srt' | Should -Be $text
    }

    It 'decrypts <ext> with its own key set' -ForEach @(
        @{ ext = 'txt';  key = '8056483646328763'; iv = '6852612370185273' }
        @{ ext = 'txt1'; key = 'AmSmZVcH93UQUezi'; iv = 'ReBKWW8cqdjPEnF6' }
        @{ ext = 'vtt';  key = 'sWODXX04QRTkHdlZ'; iv = '8pwhapJeC4hrS9hO' }
    ) {
        $enc = $script:Srt -f (Protect-TestText 'Hello there' $key $iv), (Protect-TestText 'Second cue' $key $iv)
        $out = ConvertFrom-KissKHSubtitle -Text $enc -Extension $ext
        $out | Should -Match '00:00:01,000 --> 00:00:02,000\nHello there\n'
        $out | Should -Match '00:00:03,000 --> 00:00:04,000\nSecond cue\n'
    }

    It 'does not decrypt with the wrong extension keys' {
        $enc = $script:Srt -f (Protect-TestText 'Hello there' '8056483646328763' '6852612370185273'), 'x'
        (ConvertFrom-KissKHSubtitle -Text $enc -Extension 'txt1') | Should -Not -Match 'Hello there'
    }

    It 'keeps a multi-line cue and strips trailing NULs' {
        $c = Protect-TestText "First line`nSecond line$([char]0)$([char]0)" 'sWODXX04QRTkHdlZ' '8pwhapJeC4hrS9hO'
        $out = ConvertFrom-KissKHSubtitle -Text ($script:Srt -f $c, $c) -Extension 'vtt'
        $out | Should -Match 'First line\nSecond line\n'
        $out.Contains([string][char]0) | Should -BeFalse
    }

    It 'decrypts a cue whose ciphertext is split across lines' {
        $a = Protect-TestText 'Line A' 'sWODXX04QRTkHdlZ' '8pwhapJeC4hrS9hO'
        $b = Protect-TestText 'Line B' 'sWODXX04QRTkHdlZ' '8pwhapJeC4hrS9hO'
        $out = ConvertFrom-KissKHSubtitle -Text ($script:Srt -f "$a`n$b", $a) -Extension 'vtt'
        $out | Should -Match 'Line A\nLine B\n'
    }

    It 'leaves garbage text unchanged' {
        $out = ConvertFrom-KissKHSubtitle -Text ($script:Srt -f 'this is not base64!', 'QUJD') -Extension 'txt'
        $out | Should -Match 'this is not base64!'
        $out | Should -Match 'QUJD'
    }

    It 'handles CRLF input and a BOM' {
        $c = Protect-TestText 'Hi' '8056483646328763' '6852612370185273'
        $text = [string][char]0xFEFF + (($script:Srt -f $c, $c) -replace "`n", "`r`n")
        (ConvertFrom-KissKHSubtitle -Text $text -Extension 'txt') | Should -Match 'Hi\n'
    }
}

Describe 'title matching' {
    It 'normalizes case, a trailing year, punctuation and whitespace' {
        ConvertTo-DltvTitleKey '  Bad   Buddy! ' | Should -Be 'bad buddy'
        ConvertTo-DltvTitleKey 'Hidden Love (2023)' | Should -Be 'hidden love'
        ConvertTo-DltvTitleKey 'Mr. Bad' | Should -Be 'mr bad'
    }

    It 'parses the whole search fixture as 50 results' {
        $script:Search.Count | Should -Be 50
    }

    It 'strict: Bad Buddy gives id 4540' {
        (Find-DltvKissKHMatch -Query 'Bad Buddy' -Results $script:Search -Strict).id | Should -Be 4540
    }
    It 'strict: punctuation and case are ignored' {
        (Find-DltvKissKHMatch -Query 'bad buddy!' -Results $script:Search -Strict).id | Should -Be 4540
    }
    It 'strict: a partial title is not a match' {
        Find-DltvKissKHMatch -Query 'Bad' -Results $script:Search -Strict | Should -BeNullOrEmpty
    }
    It 'strict: a title with a trailing year matches the bare query' {
        $r = @([PSCustomObject]@{ id = 1; title = 'Hidden Love (2023)' }, [PSCustomObject]@{ id = 2; title = 'Hidden Love 2' })
        (Find-DltvKissKHMatch -Query 'Hidden Love' -Results $r -Strict).id | Should -Be 1
    }
    It 'returns nothing for an empty result set or empty query' {
        Find-DltvKissKHMatch -Query 'Bad Buddy' -Results @() -Strict | Should -BeNullOrEmpty
        Find-DltvKissKHMatch -Query '!!' -Results $script:Search | Should -BeNullOrEmpty
        @(ConvertFrom-DltvJsonList (Read-Fixture 'search-empty.json')).Count | Should -Be 0
    }

    It 'non-strict ranks exact > prefix > all tokens, ties by API order' {
        $r = @(
            [PSCustomObject]@{ id = 1; title = 'The Bad Mother' },       # tokens only
            [PSCustomObject]@{ id = 2; title = 'Bad Mother Returns' },   # prefix
            [PSCustomObject]@{ id = 3; title = 'Bad Mother' },           # exact
            [PSCustomObject]@{ id = 4; title = 'Bad Mother Again' },     # prefix, later
            [PSCustomObject]@{ id = 5; title = 'Badminton Mother' }      # no match
        )
        $ids = @(Get-DltvKissKHMatches -Query 'bad mother' -Results $r | ForEach-Object { $_.id })
        $ids -join ',' | Should -Be '3,2,4,1'
    }

    It 'non-strict: token match is order-independent' {
        (Find-DltvKissKHMatch -Query 'mother bad' -Results @([PSCustomObject]@{ id = 9; title = 'Bad Mother' })).id | Should -Be 9
    }

    It 'non-strict: a prefix has to end on a word boundary' {
        Find-DltvKissKHMatch -Query 'bad' -Results @([PSCustomObject]@{ id = 9; title = 'Badminton' }) | Should -BeNullOrEmpty
    }

    It 'non-strict: unrelated titles are not matches' {
        Find-DltvKissKHMatch -Query 'Breaking Bad Season Nine' -Results $script:Search | Should -BeNullOrEmpty
    }
}

Describe 'KissKH fallback decision' {
    It 'falls back when there are no torrents' {
        Test-DltvKissKHFallback -Torrents @() -MinSeeders 5 | Should -Not -BeNullOrEmpty
    }
    It 'falls back when the top pick is under minSeeders, naming the numbers' {
        $t = @([PSCustomObject]@{ Seeders = 2 }, [PSCustomObject]@{ Seeders = 900 })
        Test-DltvKissKHFallback -Torrents $t -MinSeeders 5 | Should -Be 'TPB best has 2 seeds (< 5)'
    }
    It 'stays on TPB at exactly minSeeders' {
        Test-DltvKissKHFallback -Torrents @([PSCustomObject]@{ Seeders = 5 }) -MinSeeders 5 | Should -BeNullOrEmpty
    }
    It 'stays on TPB with healthy seeds' {
        Test-DltvKissKHFallback -Torrents @([PSCustomObject]@{ Seeders = 488 }) -MinSeeders 5 | Should -BeNullOrEmpty
    }
}

Describe 'episode selection' {
    It 'parses ranges' {
        $r = ConvertFrom-DltvEpisodeRange '3'
        $r.From | Should -Be 3
        $r.To   | Should -Be 3
        $r = ConvertFrom-DltvEpisodeRange '1-4'
        $r.From | Should -Be 1
        $r.To   | Should -Be 4
        $r = ConvertFrom-DltvEpisodeRange '5-'
        $r.From | Should -Be 5
        $r.To   | Should -Be ([int]::MaxValue)
        ConvertFrom-DltvEpisodeRange '' | Should -BeNullOrEmpty
    }
    It 'rejects junk and backwards ranges' {
        { ConvertFrom-DltvEpisodeRange 'abc' } | Should -Throw
        { ConvertFrom-DltvEpisodeRange '4-1' } | Should -Throw
        { ConvertFrom-DltvEpisodeRange '-3' }  | Should -Throw
    }
    It 'returns all 12 integer episodes of the fixture, ascending' {
        $sel = Select-KissKHEpisodes -Drama $script:Drama
        @($sel.Episodes).Count | Should -Be 12
        $sel.Episodes[0].Number  | Should -Be 1
        $sel.Episodes[11].Number | Should -Be 12
        $sel.Skipped | Should -Be 0
    }
    It 'filters by range' {
        @((Select-KissKHEpisodes -Drama $script:Drama -Range '3').Episodes).Count   | Should -Be 1
        @((Select-KissKHEpisodes -Drama $script:Drama -Range '1-4').Episodes).Count | Should -Be 4
        $from5 = Select-KissKHEpisodes -Drama $script:Drama -Range '5-'
        @($from5.Episodes).Count | Should -Be 8
        $from5.Episodes[0].Number | Should -Be 5
    }
    It 'skips and counts fractional recap episodes' {
        $d = [PSCustomObject]@{ episodes = @(
            [PSCustomObject]@{ id = 3; number = 2.0 },
            [PSCustomObject]@{ id = 2; number = 1.1 },
            [PSCustomObject]@{ id = 1; number = 1.0 }) }
        $sel = Select-KissKHEpisodes -Drama $d
        @($sel.Episodes).Count | Should -Be 2
        $sel.Skipped | Should -Be 1
        $sel.Episodes[0].Id | Should -Be 1
    }
}
