# dl-scripts

PowerShell scripts for searching and downloading media with automatic extraction and installation.

| Script | CMD | Source | Downloader | Description |
|--------|-----|--------|------------|-------------|
| [dlanime](dlanime/) | `dlanime.cmd` | nyaa.si | qBittorrent | Anime series and movies |
| [dlgame](dlgame/) | `dlgame.cmd` | appnetica.com | qBittorrent | PC games (Steam folder versions) |
| [dlmovie](dlmovie/) | `dlmovie.cmd` | YTS | qBittorrent | Movies |
| [dltv](dltv/) | `dltv.cmd` | The Pirate Bay | qBittorrent | TV shows |
| [dlrom](dlrom/) | `dlrom.cmd` | cdromance.org | Motrix / aria2c / curl / BITS / PowerShell | Video game ROMs (auto-extract + auto-install to emulator dirs + auto-add to Steam via Steam ROM Manager) |

## Setup

1. Add the root of this repo to `PATH`
2. Run any script directly from any terminal:

```
dlanime "Frieren"
dlgame "Spider-Man"
dlmovie "Inception"
dltv "Breaking Bad"
dlrom "Zelda" --platform n64
```

Config is stored at `%LOCALAPPDATA%\dlScripts\config.json` and is **auto-created with defaults on first run** — no manual setup required. See each subfolder's `README.md` for the full parameter reference.

---

## Agent Context

> This section is for AI agents operating in this repo or calling these scripts.

### What this repo is

A monorepo of four independent PowerShell download scripts, each wrapped by a root-level `.cmd` file. The CMD wrappers are what gets invoked from the terminal (and from PATH). They delegate to the `.ps1` files inside each subfolder.

### File layout

```
dl-scripts/
├── dlanime.cmd              ← invoke this (on PATH)
├── dlgame.cmd
├── dlmovie.cmd
├── dltv.cmd
├── dlrom.cmd
├── lib/
│   └── DriveResolver.ps1    ← shared: Initialize-DlConfig, Resolve-MediaPath, Get-DriveMetaInventory
├── dlanime/
│   ├── Add-Anime.ps1        ← actual logic
│   └── README.md
├── dlgame/
│   ├── Add-Game.ps1
│   ├── .settings            ← credentials (gitignored, must exist locally)
│   ├── .settings.example
│   └── README.md
├── dlmovie/
│   ├── Add-Movie.ps1
│   └── README.md
├── dltv/
│   ├── Add-TV.ps1
│   └── README.md
└── dlrom/
    ├── Add-ROM.ps1
    └── README.md
```

### Config

All non-credential settings live in `%LOCALAPPDATA%\dlScripts\config.json`, structured as one object per script:

```json
{
  "anime":  { "qbitHost": "...", "seriesDestination": "...", "moviesDestination": "...", "maxResults": 75, "autoAppendDualAudio": true, "preferredUploaders": ["judas", "..."], "useDriveMetadata": true },
  "movie":  { "qbitHost": "...", "destination": "...", "maxResults": 15, "useDriveMetadata": true },
  "tv":     { "qbitHost": "...", "destination": "...", "maxResults": 50, "useDriveMetadata": true },
  "game":   { "qbitHost": "...", "destination": "...", "maxResults": 10, "useDriveMetadata": true },
  "rom":    { "romsBase": "C:\\Emulation\\roms", "tempDir": "%TEMP%\\dlrom", "motrixRpcUrl": "http://localhost:16800/jsonrpc", "maxResults": 10, "pollIntervalMs": 2000, "steamSync": true, "srmExe": "", "srmRestartSteam": "auto", "srmEnableParser": true, "srmWrapperCmd": "", "abPort": 15151, "abDownloadDir": "", "abTimeoutSec": 1800 }
}
```

Each script self-bootstraps: if the file or its section is missing, it is created with defaults and execution continues. No crash, no manual step. New keys (e.g. `useDriveMetadata`) are automatically backfilled into existing sections on next run.

`dlgame` additionally requires a `.settings` file in the `dlgame/` subfolder for appnetica.com credentials (Email, Password). All other settings for dlgame come from `config.json`.

**`useDriveMetadata` (default: `true`)** — when true, destination is resolved at runtime from `drive-meta.json` files on connected drives instead of the hardcoded `destination` field. Set to `false` to re-enable the explicit `destination` field (e.g. for a pinned path you always want to use).

### Download methods

- **dlanime, dlgame, dlmovie, dltv**: Queue torrents to qBittorrent via WebUI API (`POST /api/v2/torrents/add`). qBittorrent must be running with Web UI enabled. The host is configured per-section in `config.json`.
- **dlrom**: Downloads direct files via **Motrix → AB Download Manager → aria2c → curl.exe → BITS → PowerShell WebClient**. Auto-detects the best available downloader at runtime and falls through on failure. Auto-extracts archives and installs ROMs to emulator directories.
  - **AB Download Manager** (port `abPort`, default 15151) is used when Motrix isn't running. Its API can queue a download but can't report completion, so dlrom passes a `suggestedName` and **watches AB's download folder** (`abDownloadDir`, default `%USERPROFILE%\Downloads\ABDM`) until the file finishes, then moves it into the pipeline. Set `abDownloadDir` if you changed AB's download location; `abTimeoutSec` bounds the wait.

### ROM destination resolution (dlrom)

The base directory is resolved in priority order, so the local emulation library always wins when present:

1. `--dest PATH` — explicit per-run override.
2. `romsBase` (default `C:\Emulation\roms`) — used whenever the folder exists.
3. **Drive picker** — only if `romsBase` is missing: `Resolve-MediaPath -MediaType 'rom'` picks a connected drive advertising a `rom_path` in its `drive-meta.json`.
4. Manual prompt — last resort if no drive advertises a ROM path.

The ROM is filed under `<romsBase>\<console>` (EmuDeck layout). When `--platform` is omitted, the console folder is taken from the platform detected on the chosen search result, so a bare `dlrom "Game"` still lands in the right folder instead of a generic `\roms`.

Whatever the downloader (Motrix, AB, etc.) drops the file as, the final ROM is always moved into `<romsBase>\<console>`: real archives (zip/7z/rar, detected by signature) are extracted first; a **raw ROM** download (`.iso`/`.chd`/`.nds`/…) is filed directly instead of failing extraction and being left behind in the downloader's folder.

### Cloudflare bypass (dlrom)

cdromance.org sits behind Cloudflare, which rejects plain script requests (HTTP 403) because their TLS fingerprint isn't a browser's. dlrom gets past this automatically, with nothing shown on screen:

1. **FlareSolverr** (headless Chromium in Docker) solves the challenge and mints a `cf_clearance` cookie + matching User-Agent. This is the only step that needs a real browser. dlrom auto-`docker start`s (or creates) the container on demand; it never launches Docker Desktop itself, so no window ever appears.
2. **`cdr_http.py`** (Python + `curl_cffi`) replays that cookie while impersonating Chrome's TLS/HTTP2 fingerprint, so Cloudflare accepts it — and, unlike a browser navigation, it can send headers like `X-Requested-With` that the link-reveal endpoint requires. `curl_cffi` is auto-installed on first use.

The `cf_clearance` is cached under `%TEMP%\dlrom\cf_session.json` and reused across runs (the first run mints it, ~15-100s; later runs are instant). A `403`/`503`/`429` triggers one automatic re-mint + retry. Only the page scraping uses this path — the actual file download is a normal direct URL that isn't Cloudflare-gated, so it stays on Motrix/AB/aria2.

**One-time setup** (dlrom will also do this for you on demand):
```
docker run -d --name flaresolverr -p 8191:8191 --restart unless-stopped ghcr.io/flaresolverr/flaresolverr:latest
```
The `--restart unless-stopped` policy means it comes back automatically after a reboot (once Docker Desktop is running).

Config keys (`[rom]` section): `cfSolverUrl` (default `http://localhost:8191/v1`), `cfSolverMode` (`auto` = solve only when blocked / `always` / `never`), `cfAutoStart`, `cfContainerName`, `cfDockerImage`, `cfSolverTimeoutMs`. Requires Docker and Python 3 on PATH. Use `--links-only` to resolve and print the download links without downloading (handy for confirming the bypass works).

### Steam ROM Manager integration (dlrom)

After a ROM is installed, `dlrom` adds it to Steam via **Steam ROM Manager (SRM)** — it never writes a Steam shortcut itself. Because SRM tracks what it has added, running SRM by hand later reconciles instead of creating duplicates.

`dlrom` **prefers the standalone `srm-wrapper` CLI** (sibling `srm-wrapper` repo) if it's on `PATH` (or set `srmWrapperCmd`): it runs `srm-wrapper --rom-dir <dest> --restart-steam <policy>`. If the wrapper isn't installed or returns non-zero, `dlrom` falls back to its **built-in** implementation (`Invoke-SteamRomManager` in `Add-ROM.ps1`):
1. Locate `srm.exe` (config `srmExe`, else `C:\Emulation\tools\srm.exe`, else `PATH`).
2. If `srmEnableParser`, read SRM's `userConfigurations.json` and enable any **disabled** parser whose `romDirectory` resolves to the destination folder (`srm enable <id>`), so the platform actually gets scanned.
3. Honour `srmRestartSteam`: on `auto` (default) restart Steam only if it is running — gracefully `steam -shutdown`, run SRM, then relaunch (SRM needs Steam closed to apply categories, and Steam only reads new shortcuts on restart).
4. Run `srm add` silently (`-WindowStyle Hidden`), then relaunch Steam if it was closed.

If **neither** the wrapper nor `srm.exe` is found, `dlrom` does **not** crash — it logs where the ROM was saved and suggests installing `srm-wrapper` or SRM.

Config keys (`[rom]` section): `steamSync` (master on/off, default `true`), `srmWrapperCmd` (blank = autodetect on PATH), `srmExe`, `srmRestartSteam` (`auto`/`never`/`always`), `srmEnableParser`. Skip per-run with `--no-steam`.

Notes:
- Platform folders match EmuDeck's layout (e.g. PS1 → `psx`, GameCube → `gc`, 3DS → `n3ds`, Vita → `psvita`) so both the emulators and SRM's parsers find the files.
- `srm add` runs **all** currently-enabled parsers, so the first sync may add a backlog of everything already on disk — SRM dedupes, so this is safe.
- Requires SRM configured once (EmuDeck does this) with its parsers pointing at `romsBase`.

### Temp cleanup (dlrom)

Each download removes its temp archive and extraction directory in a `finally`, so nothing is left in `%TEMP%\dlrom` whether the download **succeeds or fails**. Only the installed ROM remains at its destination. `--no-extract` is the one exception: it intentionally keeps the downloaded archive (that's the deliverable) and does not extract.

### CMD wrapper behaviour

- `%~dp0` is used to resolve the `.ps1` path relative to the CMD file, so the scripts work correctly regardless of which directory the user is in or where PATH points.
- `dlanime.cmd` accepts: `"Query" [series|movie] [destination] [--list]` — `--list` can appear in any position.
- `dlgame.cmd`, `dlmovie.cmd`, `dltv.cmd` accept: `"Query" [destination]`.
- `dlrom.cmd` accepts: `"Query" [--platform PLATFORM] [--region REGION] [--sort SORT] [--dest PATH] [--interactive] [--no-extract] [--no-steam] [--links-only]`.

### Drive metadata

Each connected drive can advertise where it stores different media types by placing a `drive-meta.json` file at its root. Scripts read these files at runtime to pick the best available destination automatically — no more hardcoded paths.

**Schema** (paths are relative to drive root):
```json
{
  "drive_name": "hiksemi-1tb-ssd",
  "drive_label": "Hiksemi 1TB External SSD",
  "drive_size_tb": 1.0,
  "drive_type": "ssd",
  "drive_preferred_media": ["game_pc"],
  "drive_priority": 50,
  "drive_last_resort": false,
  "movie_path": "",
  "tv_path": "",
  "anime_series_path": "",
  "anime_movie_path": "",
  "game_pc_path": "Games\\PC",
  "rom_path": "Emulation\\roms"
}
```

- `drive_type`: `ssd` / `hdd` / `sdcard` — user-declared (USB drives report "Unspecified" from the OS)
- `drive_preferred_media`: array of media-type keys this drive is optimised for
- `drive_last_resort`: drive is only used when no other candidate is available (set on the OS drive)
- Empty string paths mean the drive does not accept that media type

**Scoring** — when multiple drives advertise the same media type, the resolver picks by score:
```
score = drive_priority + (1000 if preferred) + typeBonus + freeGB*0.5 - (5000 if last_resort)
typeBonus: game_pc → ssd=+300, hdd=0 | movie/tv/anime → hdd=+300, ssd=+100
```

Drives that are unplugged are simply absent from the scan, so a torrent is never sent to a dead path.

**To test resolution without submitting a torrent:**
```
dlmovie "Test" -DryRun
dlgame "Test" -DryRun
dlanime "Test" -isAnimeSeries yes -DryRun
dltv "Test" -DryRun
```

**To inspect all connected drives and their picks:**
```
powershell -File lib\DriveResolver.ps1
```

### When editing scripts

- Logic lives in the `.ps1` files. The `.cmd` files only parse args and invoke PowerShell.
- `Initialize-DlConfig` lives in `lib\DriveResolver.ps1` and is dot-sourced by each script. The function signature is unchanged.
- All scripts use identical logging via `Write-Log` with levels: `INFO`, `SUCCESS`, `WARN`, `ERROR`, `DEBUG`.
- **dlrom** (`Add-ROM.ps1`) uses: `Invoke-CdromanceSearch` for web scraping, `Get-DownloadLinks` + `Select-DownloadLinks` for link filtering (handles multi-disc, English preference, demo filtering), and a unified `Invoke-FileDownload` dispatcher that auto-detects the best available downloader (Motrix RPC, aria2c, curl, BITS, or WebClient).

