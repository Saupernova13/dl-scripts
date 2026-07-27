# Contributing to dl-scripts

Thanks for your interest in improving dl-scripts.

This is a small collection of independent Windows download helpers. Contributions
are kept lightweight.

## Repo shape

Each tool has a `.cmd` wrapper in the repo root. The wrapper parses arguments and
calls a PowerShell script in a folder of the same name.

The `.cmd` files only handle arguments. All logic lives in the `.ps1` files.
Shared helpers live in `lib/`.

```
<tool>.cmd        ← arg parsing, on PATH; calls the .ps1 with -Named parameters
<tool>/*.ps1      ← the actual logic
lib/*.ps1         ← shared (Initialize-DlConfig; Resolve-MediaPath = drive-registry API client)
```

`dlrom` is split further into modules that `Add-ROM.ps1` loads: `Constants.ps1`,
`Common.ps1`, `Logging.ps1`, `RetroGameTalk.ps1`, `Downloaders.ps1`,
`RomFiles.ps1`, `Clean.ps1` and `SteamRomManager.ps1`.

`Add-ROM.ps1` stays thin. Add a new module for a new concern instead of growing
one file.

`Constants.ps1` loads first. It owns every value that more than one module needs:
job states, downloader ids, ROM and archive extensions, release markers, region
order, and PS Vita build markers.

If you are about to write a second copy of a table or a regex, put it there
instead. Every table in that file began as two or three copies that drifted apart.

## Conventions

- **No hardcoded personal paths.** Anything machine-specific goes in one of three
  places: `%LOCALAPPDATA%\dlScripts\config.json`, the drive-registry API at
  runtime, or a parameter. Always ship a sensible default.
- **ASCII only in script content.** No box-drawing characters, smart quotes or
  emoji in `.ps1`, `.cmd` or `.py` files. They break across terminals and editors.
  Plain `# --- Section ---` dividers are fine.
- **Approved PowerShell verbs.** Use `Get-`, `Invoke-`, `Test-`, `Find-`,
  `Format-` and so on. Run `Get-Verb` for the full list. Keep functions small and
  single-purpose.
- **Log through `Write-Log`.** The levels are `INFO`, `SUCCESS`, `WARN`, `ERROR`
  and `DEBUG`. Keep the default output clean. Put step-by-step detail at `DEBUG`,
  which is hidden unless `--verbose` is passed. Use `INFO` only for things the
  user wants to see.
- **Fail soft.** A missing optional dependency, such as Motrix, SRM or a drive,
  should print a clear message and carry on. It must not crash.
- **Commits:** conventional style, e.g. `feat(dlrom): ...`, `fix(dlrom): ...`, `docs: ...`.

## Testing changes

`dlrom` has a [Pester](https://pester.dev) suite; the other tools do not yet. Before opening a PR:

1. Run the `dlrom` tests (needs Pester 5+:
   `Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck`):
   ```powershell
   .\dlrom\tests\Invoke-Tests.ps1          # offline, ~2s - run this every time
   .\dlrom\tests\Invoke-Tests.ps1 -Live    # also hits retrogametalk.com, ~90s
   ```
   The offline suite mocks exactly one thing: `Invoke-WebRequest`. Everything else
   is the real code, run against trimmed captures of real pages in
   `dlrom/tests/fixtures/`. Add cases there when you touch URL building, parsing
   or selection.

   The `Live` suite catches the site changing underneath us. That means a renamed
   category, a filter that stops matching, or a login appearing. Run it before
   shipping anything that touches `RetroGameTalk.ps1`, and whenever `dlrom` starts
   finding nothing.

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
