# Contributing to dl-scripts

Thanks for your interest in improving dl-scripts. This is a small monorepo of independent
Windows download helpers, so contributions are kept lightweight.

## Repo shape

Each tool is a root-level `.cmd` wrapper that parses arguments and delegates to PowerShell in
a same-named subfolder. The `.cmd` files only marshal arguments &mdash; all logic lives in the
`.ps1` files. Shared helpers live in `lib/`.

```
<tool>.cmd        ← arg parsing, on PATH; calls the .ps1 with -Named parameters
<tool>/*.ps1      ← the actual logic
lib/*.ps1         ← shared (Initialize-DlConfig; Resolve-MediaPath = drive-registry API client)
```

`dlrom` is further split into dot-sourced modules (`Constants.ps1`, `Common.ps1`, `Logging.ps1`,
`RetroGameTalk.ps1`, `Downloaders.ps1`, `RomFiles.ps1`, `SteamRomManager.ps1`) with `Add-ROM.ps1`
as a thin orchestrator. New, self-contained concerns should follow that pattern rather than
growing a single file.

`Constants.ps1` loads first and owns every literal more than one module depends on - job
states, downloader ids, ROM/archive extensions, release markers, region preference. If you
find yourself writing a second copy of a table or a regex, it belongs there instead; the
tables that are in there now each started life as two or three copies that drifted apart.

## Conventions

- **No hardcoded personal paths.** Anything machine-specific belongs in
  `%LOCALAPPDATA%\dlScripts\config.json` (auto-created and backfilled by `Initialize-DlConfig`),
  resolved at runtime via the drive-registry API, or accepted as a parameter. Ship sensible defaults.
- **ASCII only in script content.** No box-drawing characters, smart quotes, or emoji in `.ps1` /
  `.cmd` / `.py` files &mdash; they break across terminals and editors. Plain `# --- Section ---`
  dividers are fine.
- **Approved PowerShell verbs.** Use `Get-`, `Invoke-`, `Test-`, `Find-`, `Format-`, etc.
  (`Get-Verb` lists them). Keep functions small and single-purpose.
- **Logging goes through `Write-Log`** with levels `INFO`, `SUCCESS`, `WARN`, `ERROR`, `DEBUG`.
  Default output should stay clean: put step-by-step detail at `DEBUG` (hidden unless `--verbose`),
  reserve `INFO` for things the user actually wants to see.
- **Fail soft.** Missing optional dependencies (Motrix, SRM, a drive) should degrade gracefully with
  a clear message, not crash.
- **Commits:** conventional style, e.g. `feat(dlrom): ...`, `fix(dlrom): ...`, `docs: ...`.

## Testing changes

`dlrom` has a [Pester](https://pester.dev) suite; the other tools do not yet. Before opening a PR:

1. Run the `dlrom` tests (needs Pester 5+:
   `Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck`):
   ```powershell
   .\dlrom\tests\Invoke-Tests.ps1          # offline, ~2s - run this every time
   .\dlrom\tests\Invoke-Tests.ps1 -Live    # also hits retrogametalk.com, ~90s
   ```
   The offline suite mocks exactly one thing, `Invoke-WebRequest`, and drives the real
   functions against trimmed captures of real Repo pages in `dlrom/tests/fixtures/`. Add
   cases there when you touch URL building, parsing or selection.

   The `Live` suite is the one that catches the site changing underneath us - a renamed
   category, a filter value that stops matching, a login appearing. Run it before shipping
   anything that touches `RetroGameTalk.ps1`, and when `dlrom` starts finding nothing.

2. Parse-check every script you touched (the tests only cover `dlrom`):
   ```powershell
   Get-ChildItem .\dlrom\*.ps1 | ForEach-Object {
       $e = $null
       [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
       if ($e) { "$($_.Name):"; $e }
   }
   ```
3. Run the tool end-to-end against a real query, and once with `--verbose` to confirm the detailed path.
4. For `dlrom`, `--links-only` is a quick way to exercise search + link reveal without downloading.

## Scope and legality

These scripts automate downloads from third-party sites. Only use them for content you are legally
entitled to (e.g. backups of games you own). Please don't add features whose primary purpose is to
circumvent paywalls or DRM beyond what the target sites already serve publicly.
