# dlrom

Searches [cdromance.org](https://cdromance.org) for a console game, downloads it, extracts
the ROM, files it into the matching emulator folder, and (optionally) adds it to Steam via
[Steam ROM Manager](https://github.com/SteamGridDB/steam-rom-manager).

## Command

```
dlrom "Game Name" [--platform PLATFORM] [--region REGION] [--sort SORT] [--dest PATH]
                  [--interactive] [--no-extract] [--no-steam] [--links-only]
                  [--no-torrent] [--torrent-pick N] [--verbose] [--quiet]
```

Add the repo root to `PATH` and call it from any terminal. Quotes are required when the
name contains spaces.

**Platforms:** `ps2`, `ps1`/`psx`, `psp`, `vita`, `n64`, `gamecube`/`gc`, `nds`/`ds`,
`gba`, `snes`, `nes`, `gbc`, `gb`, `dreamcast`/`dc`, `saturn`, `wii`, `3ds`
**Regions:** `usa`, `europe`, `japan`, `world`

## Usage examples

```
dlrom "Rayman 2"
dlrom "Final Fantasy VII" --platform ps1
dlrom "Metal Slug" --platform ps2 --region usa
dlrom "Zelda" --platform n64 --interactive
dlrom "Crash Bandicoot" --links-only        # resolve and print links, download nothing
dlrom "Spyro" --platform ps1 --verbose       # show every internal step
```

## Flags

| Flag | Effect |
|------|--------|
| `--platform` | Restrict the search and choose the destination console folder. Omit it and the platform is inferred from the chosen result. |
| `--region` | Pass a region filter to the search (`usa`, `europe`, `japan`, `world`). |
| `--sort` | Pass a sort order to the search. |
| `--dest PATH` | Per-run override of the ROMs base directory (wins over config and the drive picker). |
| `--interactive` | Pick from the numbered results list instead of auto-selecting. |
| `--no-extract` | Keep the downloaded archive; do not extract or install. |
| `--no-steam` | Skip the Steam ROM Manager step for this run. |
| `--links-only` | Resolve and print the download links, then stop. Handy for confirming the Cloudflare bypass works. |
| `--no-torrent` | Disable the PS2 torrent fallback (see below) for this run. |
| `--torrent-pick N` | Force file index `N` from the PS2 archive torrent instead of auto-picking (use the index shown in the "closest titles" list). |
| `--verbose` | Show detailed step-by-step debug output. |
| `--quiet` | Show only results, warnings and errors. |

## PowerShell parameters

The CMD wrapper passes these through; you can also call the script directly:

```powershell
.\dlrom\Add-ROM.ps1 -Query "Zelda" [-Platform n64] [-Region usa] [-Sort ...] `
    [-Destination "D:\roms"] [-MaxResults 10] [-Interactive] [-NoExtract] `
    [-NoSteam] [-LinksOnly] [-NoTorrent] [-TorrentPick N] [-Verbose] [-Quiet]
```

## PS2 torrent fallback

cdromance is the only web source, so any cdromance failure (Cloudflare unsolved,
FlareSolverr/Docker down, no search results, or no download links) used to end the run.
For **PS2 games** there is now a second source: a local Redump PS2 archive `.torrent`
that indexes the full set. When cdromance can't deliver and `--platform ps2` was given,
dlrom looks the game up in that archive and pulls **only that one file** through
qBittorrent's per-file selective download, then extracts and files it exactly like a
cdromance download (and runs the Steam sync).

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

The cdromance auto-select prefers the **base** game over an edition (it picks "Persona 3", not
"Persona 3 FES") and honours `--region`, but never returns nothing — if only an edition exists,
it takes it. The torrent fallback applies the same preference more strictly (it *refuses* an
unrequested edition, since the archive always has the base).

When dlrom installs a **PS2** game it prints a result block ending in a machine-readable line:

```
[HANDOFF] platform=ps2 serial=SLUS-21569 title="Shin Megami Tensei - Persona 3" texturecmd=dlps2tex "SLUS-21569"
```

The serial is resolved from `GameIndex.yaml` (the same source `dlps2tex` uses), so running the
printed `texturecmd` fetches HD textures for the **exact version** just downloaded — base vs FES,
USA vs PAL all line up. An agent should read the `[HANDOFF]` line and run `dlps2tex "<serial>"`
rather than re-guessing the name.

## Output verbosity

By default the output is a clean narrative: the chosen downloader, the search, the result
list, the download progress bar, and where the ROM landed. Internal detail (link-discovery
strategies, ticket IDs, RPC GIDs, slug mapping) is hidden.

- `--verbose` adds all `DEBUG` lines (every internal step) for troubleshooting.
- `--quiet` drops routine `INFO`, leaving only results, warnings, and errors.

## How it works

1. **Search** - queries cdromance.org and lists matching games.
2. **Select** - auto-selects (preferring a USA result), or shows a numbered list with `--interactive`.
3. **Resolve links** - reveals the download table (mirrors the site's "SHOW LINKS" button), then
   filters demos and prefers English/patched and USA variants. Multi-disc games queue one link per disc.
4. **Download** - via the best available backend (see below).
5. **Extract & install** - real archives are extracted with 7-Zip; a raw ROM download is filed as-is.
   The final file is sanitised (apostrophes etc. removed so Steam launch commands don't break) and moved
   into `<romsBase>\<console>`.
6. **Steam sync** - adds the ROM to Steam via Steam ROM Manager unless `--no-steam` is set.
7. **Cleanup** - the temp archive and extraction folder are removed whether the run succeeds or fails.

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
(PS1 -> `psx`, GameCube -> `gc`, 3DS -> `n3ds`, Vita -> `psvita`) so both the emulators
and Steam ROM Manager's parsers find the files.

## Cloudflare bypass

cdromance.org sits behind Cloudflare, which rejects plain script requests. dlrom gets past this
automatically, with nothing shown on screen:

1. **FlareSolverr** (headless Chromium in Docker) solves the challenge and mints a `cf_clearance`
   cookie. dlrom `docker start`s (or creates) the container on demand; it never launches Docker Desktop
   itself, so no window appears.
2. **`cdr_http.py`** (Python + `curl_cffi`) replays that cookie while impersonating Chrome's
   TLS/HTTP2 fingerprint, so Cloudflare accepts it and the link-reveal endpoint can be called with the
   headers it needs. `curl_cffi` is auto-installed on first use.

The session is cached under `%TEMP%\dlrom\cf_session.json` and reused across runs (the first run mints
it, ~15-100s; later runs are instant). Only page scraping uses this path - the actual file download
is a normal direct URL that isn't Cloudflare-gated.

One-time container setup (dlrom will also do this for you on demand):

```
docker run -d --name flaresolverr -p 8191:8191 --restart unless-stopped ghcr.io/flaresolverr/flaresolverr:latest
```

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
    "cfSolverUrl": "http://localhost:8191/v1",
    "cfSolverMode": "auto",
    "cfAutoStart": true,
    "cfContainerName": "flaresolverr",
    "cfDockerImage": "ghcr.io/flaresolverr/flaresolverr:latest",
    "cfSolverTimeoutMs": 120000
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `romsBase` | `C:\Emulation\roms` | ROMs base directory. Used when it exists; otherwise the drive picker runs. |
| `tempDir` | `%TEMP%\dlrom` | Working directory for downloads, extraction, and the Cloudflare cache. |
| `motrixRpcUrl` | `http://localhost:16800/jsonrpc` | Motrix aria2 RPC endpoint. |
| `maxResults` | `10` | Max search results shown. |
| `pollIntervalMs` | `2000` | Motrix progress poll interval. |
| `steamSync` | `true` | Master on/off for the Steam ROM Manager step. |
| `srmExe` | `""` | Path to `srm.exe`; blank autodetects `C:\Emulation\tools\srm.exe` then `PATH`. |
| `srmRestartSteam` | `auto` | `auto` (restart only if running) / `never` / `always`. |
| `srmEnableParser` | `true` | Enable the SRM parser watching the destination before adding. |
| `srmWrapperCmd` | `""` | Path to `srm-wrapper.cmd`; blank autodetects on `PATH` (preferred over built-in). |
| `abPort` | `15151` | AB Download Manager integration port. |
| `abDownloadDir` | `""` | AB's download folder; blank autodetects `%USERPROFILE%\Downloads\ABDM`. |
| `abTimeoutSec` | `1800` | How long to wait for an AB download before giving up. |
| `cfSolverUrl` | `http://localhost:8191/v1` | FlareSolverr endpoint. |
| `cfSolverMode` | `auto` | `auto` (solve only when blocked) / `always` / `never`. |
| `cfAutoStart` | `true` | `docker start`/`run` the solver container on demand. |
| `cfContainerName` | `flaresolverr` | Docker container name to start/create. |
| `cfDockerImage` | `ghcr.io/...` | FlareSolverr image used when creating the container. |
| `cfSolverTimeoutMs` | `120000` | Per-challenge solve budget. |

## Requirements

- **Windows** with PowerShell 5.1+ (ships with Windows 10/11).
- **Docker Desktop** + **Python 3** on `PATH` - for the Cloudflare bypass.
- **7-Zip** (`winget install 7zip.7zip`) - to extract `.7z`/`.rar` archives.
- Optional: **Motrix** or **AB Download Manager** for faster, resumable downloads (any of the
  built-in fallbacks work without them).
- Optional: **Steam ROM Manager** (or `srm-wrapper`) for the Steam step.

## Module layout

`Add-ROM.ps1` is a thin orchestrator that dot-sources focused modules:

| File | Responsibility |
|------|----------------|
| `Add-ROM.ps1` | Argument/config handling and the main flow. |
| `Logging.ps1` | `Write-Log` (verbosity-aware) and size/speed/label formatters. |
| `Cdromance.ps1` | Platform tables, search, and download-link discovery/selection. |
| `Downloaders.ps1` | Motrix/AB/aria2c/curl/BITS/WebClient backends and the dispatcher. |
| `RomFiles.ps1` | Archive detection/extraction, ROM discovery, filename safety, install. |
| `SteamRomManager.ps1` | Steam ROM Manager sync (srm-wrapper preferred, built-in fallback). |
| `CfSolver.ps1` + `cdr_http.py` | Cloudflare bypass (FlareSolverr + curl_cffi). |

## Troubleshooting

- **Search fails / Cloudflare block** - make sure Docker Desktop is running so FlareSolverr can
  solve the challenge. Try `dlrom "..." --links-only --verbose`.
- **No download links found** - dlrom saves the page HTML to `%TEMP%\dlrom-debug.html` for inspection.
- **AB download never finishes** - set `abDownloadDir` to AB's actual download folder; raise `abTimeoutSec`.
- **ROM lands in `\roms` instead of a console folder** - pass `--platform`, or the platform couldn't be
  inferred from the search result.
