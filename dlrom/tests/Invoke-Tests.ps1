# Test runner for dlrom.
#
#   .\dlrom\tests\Invoke-Tests.ps1           unit tests only (offline, ~2s)
#   .\dlrom\tests\Invoke-Tests.ps1 -Live     add the live tests (real HTTP, ~90s)
#   .\dlrom\tests\Invoke-Tests.ps1 -Live -Only   live tests only
#
# Exits non-zero when anything fails, so it can gate a commit or a CI step.

[CmdletBinding()]
param(
    [switch]$Live,   # also run the tests that hit retrogametalk.com
    [switch]$Only,   # with -Live: skip the offline suite
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable Pester |
          Where-Object { $_.Version -ge [version]'5.0.0' } |
          Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Host "Pester 5+ is required. Install it with:" -ForegroundColor Yellow
    Write-Host "  Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck" -ForegroundColor Yellow
    exit 2
}
Import-Module $pester.Path -Force

$config = New-PesterConfiguration
$config.Run.Path      = $PSScriptRoot
$config.Run.PassThru  = $true
$config.Output.Verbosity = $(if ($Quiet) { 'Normal' } else { 'Detailed' })

if ($Live -and $Only) { $config.Filter.Tag        = 'Live' }
elseif ($Live)        { }                                     # everything, live included
else                  { $config.Filter.ExcludeTag = 'Live' }

$result = Invoke-Pester -Configuration $config

Write-Host ""
Write-Host ("{0} passed, {1} failed, {2} skipped" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount) `
    -ForegroundColor $(if ($result.FailedCount -gt 0) { 'Red' } else { 'Green' })

exit $(if ($result.FailedCount -gt 0) { 1 } else { 0 })
