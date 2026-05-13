# dl-scripts

PowerShell scripts for searching and downloading media with automatic extraction and installation.

| Script | CMD | Source | Downloader | Description |
|--------|-----|--------|------------|-------------|
| [dlanime](dlanime/) | `dlanime.cmd` | nyaa.si | qBittorrent | Anime series and movies |
| [dlgame](dlgame/) | `dlgame.cmd` | appnetica.com | qBittorrent | PC games (Steam folder versions) |
| [dlmovie](dlmovie/) | `dlmovie.cmd` | YTS | qBittorrent | Movies |
| [dltv](dltv/) | `dltv.cmd` | The Pirate Bay | qBittorrent | TV shows |
| [dlrom](dlrom/) | `dlrom.cmd` | cdromance.org | Motrix / aria2c / curl / BITS / PowerShell | Video game ROMs (auto-extract + auto-install to emulator dirs) |

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
  "rom":    { "romsBase": "C:\\Emulation\\roms", "tempDir": "%TEMP%\\dlrom", "motrixRpcUrl": "http://localhost:16800/jsonrpc", "maxResults": 10, "pollIntervalMs": 2000 }
}
```

Each script self-bootstraps: if the file or its section is missing, it is created with defaults and execution continues. No crash, no manual step. New keys (e.g. `useDriveMetadata`) are automatically backfilled into existing sections on next run.

`dlgame` additionally requires a `.settings` file in the `dlgame/` subfolder for appnetica.com credentials (Email, Password). All other settings for dlgame come from `config.json`.

**`useDriveMetadata` (default: `true`)** — when true, destination is resolved at runtime from `drive-meta.json` files on connected drives instead of the hardcoded `destination` field. Set to `false` to re-enable the explicit `destination` field (e.g. for a pinned path you always want to use).

### Download methods

- **dlanime, dlgame, dlmovie, dltv**: Queue torrents to qBittorrent via WebUI API (`POST /api/v2/torrents/add`). qBittorrent must be running with Web UI enabled. The host is configured per-section in `config.json`.
- **dlrom**: Downloads direct files via **Motrix (preferred) → aria2c → curl.exe → BITS → PowerShell WebClient**. Auto-detects available downloader at runtime with fallbacks. Auto-extracts archives and installs ROMs to emulator directories.

### CMD wrapper behaviour

- `%~dp0` is used to resolve the `.ps1` path relative to the CMD file, so the scripts work correctly regardless of which directory the user is in or where PATH points.
- `dlanime.cmd` accepts: `"Query" [series|movie] [destination] [--list]` — `--list` can appear in any position.
- `dlgame.cmd`, `dlmovie.cmd`, `dltv.cmd` accept: `"Query" [destination]`.
- `dlrom.cmd` accepts: `"Query" [--platform PLATFORM] [--region REGION] [--sort SORT] [--dest PATH] [--interactive] [--no-extract]`.

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
  "game_pc_path": "Games\\PC"
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

