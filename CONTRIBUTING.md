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

`dlrom` is further split into dot-sourced modules (`Logging.ps1`, `Cdromance.ps1`,
`Downloaders.ps1`, `RomFiles.ps1`, `SteamRomManager.ps1`, `CfSolver.ps1`) with `Add-ROM.ps1` as a
thin orchestrator. New, self-contained concerns should follow that pattern rather than growing a
single file.

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

There's no test framework; before opening a PR, please:

1. Parse-check every script you touched:
   ```powershell
   Get-ChildItem .\dlrom\*.ps1 | ForEach-Object {
       $e = $null
       [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
       if ($e) { "$($_.Name):"; $e }
   }
   ```
2. Run the tool end-to-end against a real query, and once with `--verbose` to confirm the detailed path.
3. For `dlrom`, `--links-only` is a quick way to exercise search + Cloudflare bypass without downloading.

## Scope and legality

These scripts automate downloads from third-party sites. Only use them for content you are legally
entitled to (e.g. backups of games you own). Please don't add features whose primary purpose is to
circumvent paywalls or DRM beyond what the target sites already serve publicly.
