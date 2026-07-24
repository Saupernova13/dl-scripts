# dlrom

Searches [The Repo](https://retrogametalk.com/repo/) on RetroGameTalk for a console game,
downloads it, extracts the ROM, files it into the matching emulator folder, and
(optionally) adds it to Steam via
[Steam ROM Manager](https://github.com/SteamGridDB/steam-rom-manager).

> The catalogue formerly published at cdromance.org now lives at
> `retrogametalk.com/repo/`, behind the forum. dlrom targets that address; the old
> cdromance domain (and the Cloudflare bypass it needed) is gone.

**Downloads run in the background by default.** dlrom searches, resolves the links, hands
the transfer to a detached worker and returns a job id — usually within seconds. Nothing
about your terminal (or your agent) has to stay attached to a multi-GB ROM download.

## Command

```
dlrom "Game Name" [--platform PLATFORM] [--region REGION] [--sort SORT] [--dest PATH]
                  [--wait] [--interactive] [--no-extract] [--no-steam] [--links-only]
                  [--no-torrent] [--torrent-pick N] [--json] [--verbose] [--quiet]
dlrom --status <jobId> [--json]
dlrom --list [--json]
```

Add the repo root to `PATH` and call it from any terminal. Quotes are required when the
name contains spaces.

**Platforms:** `ps2`, `ps1`/`psx`, `psp`, `eboot`, `vita`, `n64`, `gamecube`/`gc`, `wii`,
`nds`/`ds`, `gba`, `snes`, `nes`, `fds`, `gbc`, `gb`, `dreamcast`/`dc`, `saturn`, `segacd`,
`genesis`/`megadrive`, `32x`, `sms`/`mastersystem`, `gamegear`/`gg`, `pico`, `3do`, `amiga`,
`arcade`, `msx`, `dos`/`msdos`, `windows`, `scummvm`, `neogeocd`, `ngp`/`ngpc`, `pc88`,
`pc98`, `pcfx`, `tg16`/`pcengine`, `tgcd`, `wonderswan`/`ws`
**Regions:** `usa`, `europe`, `japan`, `world`

> The Repo carries no 3DS section, so the old `3ds` alias is gone. Everything else that
> cdromance hosted came across, plus a good deal more.

## Headless / background use

This is the default path, and the one to use from a script, an agent, or any session you
do not want to babysit.

```
$ dlrom "Gran Turismo 4" --platform ps2

Download job spawned.  It will continue in the background.
  Job ID:   a3f9c21b8e04
  Source:   retrogametalk
  Title:    Gran Turismo 4
  Dest:     C:\Emulation\roms\ps2
  Log:      C:\Users\you\AppData\Local\dlScripts\jobs\rom\a3f9c21b8e04.log
  Check:    dlrom --status a3f9c21b8e04
```

The command returns there. The worker carries on downloading, extracting, filing the ROM
and syncing to Steam on its own. Poll it whenever you like:

```
dlrom --status a3f9c21b8e04          # progress, step, and the last 20 log lines
dlrom --status a3f9c21b8e04 --json   # the whole job record, for scripts
dlrom --list                         # every recent job and its state
```

What happens before the job is spawned is deliberately synchronous: the search and the
link resolution. That way "no results on The Repo" is still an immediate answer rather
than something you only discover by polling. Only the slow half is detached.

### Job states

| Status | Meaning |
|---|---|
| `pending` | The job file is written; the worker is starting. |
| `running` | The worker owns it. `step` says where it is: `downloading`, `extracting`, `filing`, `steam-sync`. |
| `completed` | The ROM is installed. `installedPaths` lists the files; `handoff` carries the PS2 texture command. |
| `failed` | It finished without installing anything. `message` says why; the log has the detail. |
| `orphaned` | The worker's process is gone but it never recorded an outcome — killed, crashed, or the machine went down mid-download. |

### Useful job fields (`--status --json`)

| Field | Meaning |
|---|---|
| `id` | Job id. |
| `kind` | `retrogametalk` or `torrent` (the PS2 archive fallback). |
| `status` / `step` / `progress` | State, current phase, and 0-100. |
| `installedPaths` | Every file this job filed into the ROM folder. |
| `handoff` | The `[HANDOFF]` line for PS2 — feed its serial to `dlps2tex`. |
| `logFile` | Full worker log. |
| `message` | Last human-readable note, and the failure reason when `failed`. |

Job files and logs live in `%LOCALAPPDATA%\dlScripts\jobs\rom\`. Finished ones are pruned
after `jobKeepDays` (default 7); running jobs are never pruned.

### Staying in the foreground

`--wait` restores the old blocking behaviour — search, download, install, all in your
terminal with a live progress bar:

```
dlrom "Gran Turismo 4" --platform ps2 --wait
```

It runs the exact same pipeline as the worker and still writes a job file, so
`dlrom --status <id>` works for a `--wait` run too. Use it when you actually want to watch;
do not use it from an agent.

## Usage examples

```
dlrom "Rayman 2"                             # spawns a job, returns a job id
dlrom "Final Fantasy VII" --platform ps1
dlrom "Metal Slug" --platform ps2 --region usa
dlrom --status a3f9c21b8e04                  # how is it going?
dlrom --list                                 # every recent job
dlrom "Gran Turismo 4" --platform ps2 --wait # block until installed
dlrom "Zelda" --platform n64 --interactive   # pick from the list yourself
dlrom "Crash Bandicoot" --links-only         # resolve and print links, download nothing
dlrom "Spyro" --platform ps1 --verbose       # show every internal step
```

## Flags

| Flag | Effect |
|------|--------|
| `--status ID` | Show a job's progress, then exit. Reads the job file only — instant, even mid-download. |
| `--list` | List recent jobs, newest first. |
| `--wait` | Download in the foreground instead of spawning a worker. |
| `--json` | Machine-readable output: the job record on spawn, or the full state for `--status` / `--list`. |
| `--platform` | Restrict the search and choose the destination console folder. Omit it and the platform is inferred from the chosen result. |
| `--region` | Pass a region filter to the search (`usa`, `europe`, `japan`, `world`). |
| `--sort` | Pass a sort order to the search. |
| `--dest PATH` | Per-run override of the ROMs base directory (wins over config and the drive picker). |
| `--interactive` | Pick from the numbered results list instead of auto-selecting. Implies a human is present: it is also the only mode allowed to prompt for a missing ROMs base. |
| `--no-extract` | Keep the downloaded archive; do not extract or install. |
| `--no-steam` | Skip the Steam ROM Manager step for this run. |
| `--links-only` | Resolve and print the download links, then stop. Handy for confirming search and link reveal work. Always foreground — it downloads nothing. |
| `--no-torrent` | Disable the PS2 torrent fallback (see below) for this run. |
| `--torrent-pick N` | Force file index `N` from the PS2 archive torrent instead of auto-picking (use the index shown in the "closest titles" list). |
| `--verbose` | Show detailed step-by-step debug output. |
| `--quiet` | Show only results, warnings and errors. |

## PowerShell parameters

The CMD wrapper passes these through; you can also call the script directly:

```powershell
.\dlrom\Add-ROM.ps1 -Query "Zelda" [-Platform n64] [-Region usa] [-Sort ...] `
    [-Destination "D:\roms"] [-MaxResults 10] [-Wait] [-Interactive] [-NoExtract] `
    [-NoSteam] [-LinksOnly] [-NoTorrent] [-TorrentPick N] [-Json] [-Verbose] [-Quiet]

.\dlrom\Add-ROM.ps1 -Status <jobId> [-Json]
.\dlrom\Add-ROM.ps1 -ListJobs [-Json]
```

`-JobFile <path>` is the worker's own entry point. It is spawned by `Start-DlromJob` and is
not meant to be called by hand.

## PS2 torrent fallback

The Repo is the only web source, so any failure there (site unreachable, rate-limited, no
search results, or no download links) used to end the run. For **PS2 games** there is now
a second source: a local Redump PS2 archive `.torrent` that indexes the full set. When The
Repo can't deliver and `--platform ps2` was given, dlrom looks the game up in that archive
and pulls **only that one file** through qBittorrent's per-file selective download, then
extracts and files it exactly like a web download (and runs the Steam sync).

The match is auto-picked with heuristics: every word of your query (numbers included) must
appear in the title; demos/betas are rejected; edition/variant releases (FES, Undub,
Director's Cut, GOTY, ...) are skipped unless you name them (so `"Persona 3"` gets the base
game, not FES); region preference is your `--region` first, then USA, World, Europe, Japan.
If nothing matches confidently it refuses and lists the closest titles with their file
indices so you can re-run with `--torrent-pick N`.

After the single file finishes, the torrent entry is removed from qBittorrent (no seeding
is left running); the downloaded ROM stays on disk.

**Requirements:** qBittorrent with its WebUI enabled, and the archive `.torrent`. The
`.torrent` and its prebuilt index ship in `dlrom/data/ps2-torrent/`; the index is rebuilt
automatically (via `ps2_torrent.py`, standard-library Python) if the `.torrent` is
replaced. The WebUI host is auto-detected from `qBittorrent.ini` (the `WebUI\Port`, e.g.
`8075` — note the other dl-scripts default to `8080`), or set `[rom].qbitHost` in config.

**Relevant `[rom]` config keys** (`%LOCALAPPDATA%\dlScripts\config.json`):

| Key | Meaning |
|-----|---------|
| `ps2TorrentEnabled` | Master switch for the fallback (default `true`). |
| `ps2TorrentPath` | Path to the archive `.torrent`. Blank = the committed copy, else `Downloads`. |
| `ps2TorrentIndexPath` | Path to the JSON index. Blank = the committed copy. |
| `ps2TorrentStaging` | Where qBittorrent saves the file. Blank = `<romsBase>\.dlrom-torrent` (same drive as the ROM folder). |
| `ps2TorrentTimeoutSec` | Max wait for the single-file download (default `14400`). |
| `qbitHost` | qBittorrent WebUI base URL. Blank = auto-detect. |
| `qbitUser` / `qbitPass` | Only needed if `WebUI\LocalHostAuth` is enabled. |
| `ps2GameIndexPath` | PCSX2 `GameIndex.yaml` used to resolve the installed serial for the texture handoff. Blank = auto-detect. |

## Edition-aware selection and the texture handoff

The Repo auto-select prefers the **base** game over an edition (it picks "Persona 3", not
"Persona 3 FES") and honours `--region`, but never returns nothing — if only an edition exists,
it takes it. The torrent fallback applies the same preference more strictly (it *refuses* an
unrequested edition, since the archive always has the base).

When dlrom **finishes installing** a **PS2** game it produces a machine-readable line:

```
[HANDOFF] platform=ps2 serial=SLUS-21569 title="Shin Megami Tensei - Persona 3" texturecmd=dlps2tex "SLUS-21569"
```

The serial is resolved from `GameIndex.yaml` (the same source `dlps2tex` uses), so running the
`texturecmd` fetches HD textures for the **exact version** just downloaded — base vs FES,
USA vs PAL all line up. Use the serial rather than re-guessing the name.

Because the install happens in the worker, this line lands on the **completed job**, not in the
output of the `dlrom` call that spawned it:

```
dlrom --status <jobId>          # printed as the [HANDOFF] line
dlrom --status <jobId> --json   # the "handoff" field
```

(Under `--wait` it prints to your terminal at the end of the run, as it always did.)

## Output verbosity

By default the output is a clean narrative: the chosen downloader, the search, the result
list, the download progress bar, and where the ROM landed. Internal detail (link-discovery
strategies, ticket IDs, RPC GIDs, slug mapping) is hidden.

- `--verbose` adds all `DEBUG` lines (every internal step) for troubleshooting.
- `--quiet` drops routine `INFO`, leaving only results, warnings, and errors.

## How it works

Steps 1-3 run in your terminal. Step 4 onward is where the time goes, so unless you passed
`--wait` it is handed to a detached worker and the command returns.

1. **Search** - queries The Repo and lists matching games.
2. **Select** - auto-selects (preferring a USA result), or shows a numbered list with `--interactive`.
3. **Resolve links** - reveals the download table (mirrors the site's "SHOW LINKS" button), then
   filters demos and prefers English/patched and USA variants. Multi-disc games queue one link per disc.

   *--- a job is created here and, by default, a worker takes over from this point ---*

4. **Download** - via the best available backend (see below).
5. **Extract & install** - real archives are extracted with 7-Zip; a raw ROM download is filed as-is.
   The final file is sanitised (apostrophes etc. removed so Steam launch commands don't break) and moved
   into `<romsBase>\<console>`.
6. **Steam sync** - adds the ROM to Steam via Steam ROM Manager unless `--no-steam` is set.
7. **Cleanup** - the temp archive and extraction folder are removed whether the run succeeds or fails.
8. **Report** - the result block (and the PS2 `[HANDOFF]` line) goes to the job log, and the
   outcome is stamped on the job for `--status`.

The PS2 torrent fallback is backgrounded the same way: if The Repo dead-ends, dlrom spawns
a `torrent` job rather than pinning you for the multi-hour archive download.

### Worker mechanics

The worker is the same `Add-ROM.ps1` re-invoked with `-JobFile`. It is started through
`ProcessStartInfo` with `CreateNoWindow` (no console flash) and its stdout redirected to
the job's log file by `cmd`. Not inheriting the caller's console handles is the point: it is
what lets `dlrom.cmd` exit instead of staying tethered to a download that runs for hours.
`Start-DlromJob` in [`Jobs.ps1`](Jobs.ps1) has the detail.

## Download backends

dlrom auto-detects the best available downloader at runtime and falls through on failure:

```
Motrix (aria2 RPC)  ->  AB Download Manager  ->  aria2c  ->  curl.exe  ->  BITS  ->  Invoke-WebRequest
```

- **Motrix** is used when its aria2 RPC is reachable (`motrixRpcUrl`).
- **AB Download Manager** (`abPort`, default 15151) is used when Motrix isn't running. AB has no
  completion API, so dlrom passes a `suggestedName` and watches AB's download folder
  (`abDownloadDir`, default `%USERPROFILE%\Downloads\ABDM`) until the file finishes. Set
  `abDownloadDir` if you changed AB's download location; `abTimeoutSec` bounds the wait.
- The remaining tiers are direct, synchronous fallbacks that need no extra software (curl/BITS/WebClient
  ship with Windows).

## ROM destination resolution

The base directory is resolved in priority order, so a local emulation library always wins when present:

1. `--dest PATH` - explicit per-run override.
2. `romsBase` (default `C:\Emulation\roms`) - used whenever the folder exists.
3. **Drive picker** - only if `romsBase` is missing: a connected drive advertising a `rom_path` in its
   `drive-meta.json` (see the [root README](../README.md#drive-metadata)).
4. **Manual prompt** - last resort.

The ROM is filed under `<romsBase>\<console>`. Folder names match EmuDeck's layout
(PS1 -> `psx`, GameCube -> `gc`, Master System -> `mastersystem`, Vita -> `psvita`) so both the emulators
and Steam ROM Manager's parsers find the files.

## No account needed

The Repo advertises a members-only gate, but it is enforced entirely in the browser:

```js
if (!document.cookie.includes("xf_online=1")) { window.location.replace(".../login/") }
```

A script never executes that, so every step dlrom performs — browsing, searching, the
"Show Links" reveal, and the file transfer itself — works anonymously. dlrom therefore has
no login, stores no credentials, and needs no forum account.

It keeps one cookie jar per run for a narrower reason: the reveal call must present the
WordPress nonce scraped from the game page, and WordPress ties that nonce to the
`PHPSESSID` it was minted under. If a reveal comes back empty, dlrom discards the jar and
retries once with a freshly minted nonce.

The resolved `dl*.retrogametalk.com/download.php?…&key=…` URLs carry their own
authorisation in the query string and need no cookie at all, which is what lets Motrix, AB
Download Manager and aria2c fetch them directly.

No Docker, no FlareSolverr, no `curl_cffi`: unlike cdromance, retrogametalk.com serves
plain HTTP clients without a Cloudflare challenge, so `Invoke-WebRequest` is enough.

## Steam ROM Manager integration

After a ROM is installed, dlrom adds it to Steam via Steam ROM Manager (SRM) - it never writes a
Steam shortcut itself, so re-running SRM later reconciles instead of duplicating.

dlrom **prefers the standalone `srm-wrapper` CLI** if it's on `PATH` (or set `srmWrapperCmd`). If the
wrapper isn't installed or returns non-zero, dlrom falls back to its **built-in** SRM driver:

1. Locate `srm.exe` (`srmExe`, else `C:\Emulation\tools\srm.exe`, else `PATH`).
2. If `srmEnableParser`, enable any disabled SRM parser whose `romDirectory` resolves to the destination.
3. Honour `srmRestartSteam` (`auto`/`never`/`always`): on `auto`, restart Steam only if it is running.
4. Run `srm add` silently, then relaunch Steam if it was closed.

If neither the wrapper nor `srm.exe` is found, dlrom does not crash - it logs where the ROM was saved.

## Configuration

All settings live in the `rom` section of `%LOCALAPPDATA%\dlScripts\config.json`, created
automatically with defaults on first run.

```json
{
  "rom": {
    "romsBase": "C:\\Emulation\\roms",
    "tempDir": "%TEMP%\\dlrom",
    "motrixRpcUrl": "http://localhost:16800/jsonrpc",
    "maxResults": 10,
    "pollIntervalMs": 2000,
    "steamSync": true,
    "srmExe": "",
    "srmRestartSteam": "auto",
    "srmEnableParser": true,
    "srmWrapperCmd": "",
    "abPort": 15151,
    "abDownloadDir": "",
    "abTimeoutSec": 1800,
    "jobKeepDays": 7
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `romsBase` | `C:\Emulation\roms` | ROMs base directory. Used when it exists; otherwise the drive picker runs. |
| `tempDir` | `%TEMP%\dlrom` | Working directory for downloads and extraction. |
| `motrixRpcUrl` | `http://localhost:16800/jsonrpc` | Motrix aria2 RPC endpoint. |
| `maxResults` | `10` | Max search results shown. |
| `pollIntervalMs` | `2000` | Motrix progress poll interval. |
| `jobKeepDays` | `7` | Days to keep finished job files and logs in `%LOCALAPPDATA%\dlScripts\jobs\rom`. Running jobs are never pruned. |
| `steamSync` | `true` | Master on/off for the Steam ROM Manager step. |
| `srmExe` | `""` | Path to `srm.exe`; blank autodetects `C:\Emulation\tools\srm.exe` then `PATH`. |
| `srmRestartSteam` | `auto` | `auto` (restart only if running) / `never` / `always`. |
| `srmEnableParser` | `true` | Enable the SRM parser watching the destination before adding. |
| `srmWrapperCmd` | `""` | Path to `srm-wrapper.cmd`; blank autodetects on `PATH` (preferred over built-in). |
| `abPort` | `15151` | AB Download Manager integration port. |
| `abDownloadDir` | `""` | AB's download folder; blank autodetects `%USERPROFILE%\Downloads\ABDM`. |
| `abTimeoutSec` | `1800` | How long to wait for an AB download before giving up. |
| `rgtLogin` | `true` | Log in to RetroGameTalk before searching. `false` (or `--no-login`) browses as a guest. |
| `rgtSessionCache` | `""` | Where the `xf_*` cookies are cached; blank uses `%LOCALAPPDATA%\dlScripts\rgt-session.json`. |

Credentials are **not** config keys — see [Signing in to RetroGameTalk](#signing-in-to-retrogametalk).

## Requirements

- **Windows** with PowerShell 5.1+ (ships with Windows 10/11).
- **7-Zip** (`winget install 7zip.7zip`) - to extract `.7z`/`.rar` archives.
- Optional: **Python 3** on `PATH` - only to rebuild the PS2 archive torrent index.
- Optional: **Motrix** or **AB Download Manager** for faster, resumable downloads (any of the
  built-in fallbacks work without them).
- Optional: **Steam ROM Manager** (or `srm-wrapper`) for the Steam step.

## Tests

```powershell
.\dlrom\tests\Invoke-Tests.ps1          # offline suite, ~2s
.\dlrom\tests\Invoke-Tests.ps1 -Live    # plus the live site, ~90s
```

Needs Pester 5+ (`Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck`).

| Suite | What it covers |
|-------|----------------|
| `Shared.Tests.ps1` | The shared foundation: that there is exactly one ROM extension table (and that it covers every console `PLATFORM_SLUGS` advertises), one archive signature table that `Test-IsArchive` and `Get-ArchiveType` agree on, one reject regex, one region vocabulary; plus `Get-CfgValue` edge cases, the formatters, filename safety and `Install-RomFromDownload`. |
| `RetroGameTalk.Tests.ps1` | The real functions with only `Invoke-WebRequest` mocked: search URL construction for every platform and filter, result parsing, the nonce reveal POST, link extraction, demo/region/multi-disc selection, region detection, edition-aware picking, and failure classification. Fixtures in `tests/fixtures/` are trimmed captures of real Repo pages. |
| `RetroGameTalk.Live.Tests.ps1` (tag `Live`) | The live catalogue: every platform slug has a category page, every search filter is accepted and does not leak other platforms, 14 known ROMs across the major consoles resolve to real `download.php?...&key=` URLs, and one of those URLs is range-fetched to prove it serves bytes with no cookies. |

The live suite is what notices the site changing under us. A category rename, a filter value
that silently stops matching, or a login appearing server-side all fail there and nowhere
else &mdash; that class of breakage is what ended the cdromance integration.

## Module layout

`Add-ROM.ps1` is a thin orchestrator that dot-sources focused modules:

| File | Responsibility |
|------|----------------|
| `Constants.ps1` | Every shared literal: job/downloader vocabularies, ROM and archive extension tables, archive signatures, release markers, region preference, default endpoints. Loaded first. |
| `Common.ps1` | Dependency-free helpers: `Get-CfgValue`, `Get-UtcStamp`, `Get-DlScriptsDataDir`, `New-ShortId`, `Remove-EmptyDirectory`, region resolution/ranking. |
| `Add-ROM.ps1` | Argument/config handling, the search + link resolution, and the worker entry point. |
| `Jobs.ps1` | Job state on disk, the detached worker spawn, `--status` / `--list` rendering, pruning. |
| `RomPipeline.ps1` | Download -> extract -> file -> Steam. Shared by the worker and `--wait`. |
| `Logging.ps1` | `Write-Log` (verbosity-aware), progress lines, size/speed/label formatters. |
| `RetroGameTalk.ps1` | Platform tables, search, and download-link discovery/selection. |
| `Downloaders.ps1` | Motrix/AB/aria2c/curl/BITS/WebClient backends and the dispatcher. |
| `RomFiles.ps1` | Archive detection/extraction, ROM discovery, filename safety, and `Install-RomFromDownload` - the one download-to-installed-ROM path, shared by the web pipeline and the torrent fallback. |
| `SteamRomManager.ps1` | Steam ROM Manager sync (srm-wrapper preferred, built-in fallback). |
| `QbitTorrent.ps1` | qBittorrent WebUI client used by the PS2 torrent fallback. |
| `Ps2TorrentIndex.ps1` + `ps2_torrent.py` | PS2 archive torrent fallback: match, selective download, install. |
| `Ps2Serial.ps1` | PS2 serial resolution and the result block / `[HANDOFF]` line. |

## Troubleshooting

- **Search fails** - try `dlrom "..." --links-only --verbose` to see the request and the reason.
- **No download links found** - dlrom saves the page HTML to `%TEMP%\dlrom-debug.html` for inspection.
  A `403` from the reveal endpoint would mean the site started gating The Repo server-side.
- **AB download never finishes** - set `abDownloadDir` to AB's actual download folder; raise `abTimeoutSec`.
- **ROM lands in `\roms` instead of a console folder** - pass `--platform`, or the platform couldn't be
  inferred from the search result.
- **A job says `orphaned`** - its worker died without recording an outcome (killed, crashed, or the
  machine went down). Nothing is running; check the job's `logFile` for how far it got, then re-run.
- **A job sits at the same percentage** - the download backend is retrying. aria2/Motrix retry an
  unreachable host for a long time before erroring; `dlrom --status <id>` shows the last log lines,
  and Motrix's own UI shows the underlying task.
- **`Cannot resolve a ROMs base directory and there is no console to ask`** - dlrom refuses to prompt
  when nothing can answer. Pass `--dest`, set `romsBase` in the config, connect a drive advertising a
  `rom_path`, or re-run with `--interactive`.
