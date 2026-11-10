# Live Telegram test: a real handshake against a production DC. No account or login needed -
# it creates a throwaway auth key, then calls help.getConfig and help.getNearestDc, proving
# the TCP transport, RSA_PAD, DH, MTProto 2.0 encryption and the TL decoder end to end.
# Tagged 'Live' (network); run with: Invoke-Tests.ps1 -Live -Only

Describe 'Telegram live handshake' -Tag 'Live' {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repoRoot 'lib/Platform.ps1')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        . (Join-Path $repoRoot 'lib/Telegram/Telegram.ps1')
        $script:LoadMs = $sw.ElapsedMilliseconds
        $sw.Restart(); [void](Initialize-TgSchema -Force); $script:SchemaMs = $sw.ElapsedMilliseconds
        # help.getConfig needs an initConnection but accepts any api_id for an unauthenticated call.
        $script:TG_API_ID = if ($env:TG_API_ID) { $env:TG_API_ID } else { '1' }
        $sw.Restart()
        $script:Conn = Open-TgConnection -Dc 2 -HostName '149.154.167.51'
        $script:ConnectMs = $sw.ElapsedMilliseconds
        $sw.Restart()
        [void](New-TgAuthKey $script:Conn)
        $script:HandshakeMs = $sw.ElapsedMilliseconds
    }
    AfterAll { Close-TgConnection $script:Conn }

    It 'creates an auth key' {
        $script:Conn.AuthKey.Length | Should -Be 256
        Write-Host ("  timings: native+schema load {0} ms, schema scan {1} ms, tcp connect {2} ms, auth key handshake {3} ms" -f $script:LoadMs, $script:SchemaMs, $script:ConnectMs, $script:HandshakeMs)
    }
    It 'answers help.getConfig over the encrypted channel' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $cfg = Invoke-TgRpc -Conn $script:Conn -Query ([ordered]@{ _ = 'help.getConfig' })
        Write-Host ("  help.getConfig: {0} ms, {1} dc options, this_dc {2}" -f $sw.ElapsedMilliseconds, $cfg.dc_options.Count, $cfg.this_dc)
        $cfg._ | Should -Be 'config'
        $cfg.this_dc | Should -Be 2
        $cfg.dc_options.Count | Should -BeGreaterThan 4
    }
    It 'answers help.getNearestDc' {
        $r = Invoke-TgRpc -Conn $script:Conn -Query ([ordered]@{ _ = 'help.getNearestDc' })
        Write-Host ("  nearestDc: country {0}, this {1}, nearest {2}" -f $r.country, $r.this_dc, $r.nearest_dc)
        $r._ | Should -Be 'nearestDc'
        $r.nearest_dc | Should -BeIn 1, 2, 3, 4, 5
    }
}
