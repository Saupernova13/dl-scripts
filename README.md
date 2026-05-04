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
  "anime":  { "qbitHost": "...", "seriesDestination": "...", "moviesDestination": "...", "maxResults": 75, "autoAppendDualAudio": true, "preferredUploaders": ["judas", "..."] },
  "movie":  { "qbitHost": "...", "destination": "...", "maxResults": 15 },
  "tv":     { "qbitHost": "...", "destination": "...", "maxResults": 50 },
  "game":   { "qbitHost": "...", "destination": "...", "maxResults": 10 },
  "rom":    { "romsBase": "C:\\Emulation\\roms", "tempDir": "%TEMP%\\dlrom", "motrixRpcUrl": "http://localhost:16800/jsonrpc", "maxResults": 10, "pollIntervalMs": 2000 }
}
```

Each script self-bootstraps: if the file or its section is missing, it is created with defaults and execution continues. No crash, no manual step.

`dlgame` additionally requires a `.settings` file in the `dlgame/` subfolder for appnetica.com credentials (Email, Password). All other settings for dlgame come from `config.json`.

### Download methods

- **dlanime, dlgame, dlmovie, dltv**: Queue torrents to qBittorrent via WebUI API (`POST /api/v2/torrents/add`). qBittorrent must be running with Web UI enabled. The host is configured per-section in `config.json`.
- **dlrom**: Downloads direct files via **Motrix (preferred) → aria2c → curl.exe → BITS → PowerShell WebClient**. Auto-detects available downloader at runtime with fallbacks. Auto-extracts archives and installs ROMs to emulator directories.

### CMD wrapper behaviour

- `%~dp0` is used to resolve the `.ps1` path relative to the CMD file, so the scripts work correctly regardless of which directory the user is in or where PATH points.
- `dlanime.cmd` accepts: `"Query" [series|movie] [destination] [--list]` — `--list` can appear in any position.
- `dlgame.cmd`, `dlmovie.cmd`, `dltv.cmd` accept: `"Query" [destination]`.
- `dlrom.cmd` accepts: `"Query" [--platform PLATFORM] [--region REGION] [--sort SORT] [--dest PATH] [--interactive] [--no-extract]`.

### When editing scripts

- Logic lives in the `.ps1` files. The `.cmd` files only parse args and invoke PowerShell.
- `Initialize-DlConfig` is duplicated in the `.ps1` files by design (no shared module dependency).
- All scripts use identical logging via `Write-Log` with levels: `INFO`, `SUCCESS`, `WARN`, `ERROR`, `DEBUG`.
- **dlrom** (`Add-ROM.ps1`) uses: `Invoke-CdromanceSearch` for web scraping, `Get-DownloadLinks` + `Select-DownloadLinks` for link filtering (handles multi-disc, English preference, demo filtering), and a unified `Invoke-FileDownload` dispatcher that auto-detects the best available downloader (Motrix RPC, aria2c, curl, BITS, or WebClient).

