# dl-scripts

PowerShell scripts for searching and downloading media with automatic extraction and installation.

| Script | CMD | Source | Downloader | Description |
|--------|-----|--------|------------|-------------|
| [dlanime](dlanime/) | `dlanime.cmd` | nyaa.si | qBittorrent | Anime series and movies |
| [dlgame](dlgame/) | `dlgame.cmd` | appnetica.com | qBittorrent | PC games (Steam folder versions) |
| [dlmovie](dlmovie/) | `dlmovie.cmd` | YTS | qBittorrent | Movies |
| [dltv](dltv/) | `dltv.cmd` | The Pirate Bay | qBittorrent | TV shows |
| [dlrom](dlrom/) | `dlrom.cmd` | cdromance.org | Motrix / AB / aria2c / curl / BITS / PowerShell | Video game ROMs (auto-extract + auto-install to emulator dirs + auto-add to Steam via Steam ROM Manager) |

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

## Requirements

- **Windows** with PowerShell 5.1+ (built into Windows 10/11).
- A torrent client (**qBittorrent** with the Web UI enabled) for `dlanime`/`dlgame`/`dlmovie`/`dltv`.
- `dlrom` additionally uses **Docker Desktop** + **Python 3** (Cloudflare bypass) and **7-Zip** (extraction); a download manager (Motrix / AB) and Steam ROM Manager are optional — see [`dlrom/README.md`](dlrom/).

Nothing here is hardcoded to one machine: paths come from `config.json` (auto-created), runtime drive
detection, or command-line overrides, so the scripts work on a fresh setup.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the repo layout and conventions (config-driven paths,
ASCII-only scripts, approved PowerShell verbs, `Write-Log` levels).

## License

[MIT](LICENSE).

## Disclaimer

These scripts automate downloads from third-party sites. Use them only for content you are legally
entitled to (for example, personal backups of games and media you own). You are responsible for
complying with the laws of your jurisdiction and the terms of the sites involved.

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
│   └── DriveResolver.ps1    ← shared: Initialize-DlConfig + drive-registry API client (Resolve-MediaPath)
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
    ├── Add-ROM.ps1          ← orchestrator (thin)
    ├── Logging.ps1          ← Write-Log + formatters
    ├── Cdromance.ps1        ← search + link discovery
    ├── Downloaders.ps1      ← download backends + dispatcher
    ├── RomFiles.ps1         ← extraction + ROM install
    ├── SteamRomManager.ps1  ← Steam ROM Manager sync
    ├── CfSolver.ps1         ← Cloudflare bypass
    ├── cdr_http.py          ← Cloudflare bypass (Python helper)
    └── README.md
```

> dlrom is split into focused modules that `Add-ROM.ps1` dot-sources. The other tools are
> still single-file. See [`dlrom/README.md`](dlrom/) for the per-module breakdown.

### Config

All non-credential settings live in `%LOCALAPPDATA%\dlScripts\config.json`, structured as one object per script:

```json
{
  "anime":  { "qbitHost": "...", "seriesDestination": "...", "moviesDestination": "...", "maxResults": 75, "autoAppendDualAudio": true, "preferredUploaders": ["judas", "..."], "useDriveMetadata": true },
  "movie":  { "qbitHost": "...", "destination": "...", "maxResults": 15, "useDriveMetadata": true },
  "tv":     { "qbitHost": "...", "destination": "...", "maxResults": 50, "useDriveMetadata": true },
  "game":   { "qbitHost": "...", "destination": "...", "maxResults": 10, "useDriveMetadata": true },
  "rom":    { "romsBase": "C:\\Emulation\\roms", "tempDir": "%TEMP%\\dlrom", "motrixRpcUrl": "http://localhost:16800/jsonrpc", "maxResults": 10, "pollIntervalMs": 2000, "steamSync": true, "srmExe": "", "srmRestartSteam": "auto", "srmEnableParser": true, "srmWrapperCmd": "", "abPort": 15151, "abDownloadDir": "", "abTimeoutSec": 1800, "cfSolverUrl": "http://localhost:8191/v1", "cfSolverMode": "auto", "cfAutoStart": true, "cfContainerName": "flaresolverr", "cfDockerImage": "ghcr.io/flaresolverr/flaresolverr:latest", "cfSolverTimeoutMs": 120000 }
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
3. **drive-registry API** — only if `romsBase` is missing: `Resolve-MediaPath -MediaType 'rom' -Strict` calls `GET /resolve?media=rom&strict=1`, which returns the highest-priority connected drive advertising a ROM path.
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
- `dlrom.cmd` accepts: `"Query" [--platform PLATFORM] [--region REGION] [--sort SORT] [--dest PATH] [--interactive] [--no-extract] [--no-steam] [--links-only] [--verbose] [--quiet]`. By default it prints a clean summary; `--verbose` reveals every internal step, `--quiet` shows only results and problems.

### Drive metadata (drive-registry API)

Destination drives are chosen by the **[drive-registry](../drive-registry)** service, not by these
scripts. That service owns the whole story: it holds a central, serial-keyed drive policy, stamps a
`drive-meta.json` onto each connected drive (including drives plugged in after it started), and
resolves the best destination for a media type. It is a localhost HTTP API bound to `127.0.0.1`
(prod `:9600`, dev `:9601`). `lib\DriveResolver.ps1` is a thin client: `Resolve-MediaPath -MediaType
<type>` calls `GET /resolve?media=<type>` and returns the picked path. No drive-picking logic lives
in this repo anymore.

The base URL is resolved from `DRIVE_REGISTRY_URL`, then a top-level `driveRegistryUrl` key in
`config.json`, then the `http://127.0.0.1:9600` default. To run the service, use `setup-startup.ps1`
in the [drive-registry](../drive-registry) repo (registers it to launch at logon) or `npm start`
there for a foreground instance.

**The service is optional.** If it isn't running (or isn't installed at all), the scripts don't
fail — each one degrades to a safe default destination: its configured `destination` (the same folder
it uses when `useDriveMetadata` is `false`), else a per-type folder under your home directory
(`~/Movies`, `~/TV`, `~/Games`, `~/Anime\Series`, `~/Anime\Movies`, `~/Emulation\roms`). A `WARN`
line notes the fallback. So `dl*` works out of the box; the service just adds multi-drive routing.
(Set `useDriveMetadata` to `false` in `config.json` to skip the service entirely and always use the
configured `destination`.)

The service computes each drive's role live from its central `policy.json`, which declares per drive
the media it accepts, each with a priority (higher wins) and optional `last_resort`. For a media type,
only drives that advertise a path for it are candidates; they rank by non-last-resort first, then
priority, then free space. Drives that are unplugged are simply absent, so a torrent is never sent to a
dead path. See the drive-registry repo for the policy format.

**To test resolution without submitting a torrent:**
```
dlmovie "Test" -DryRun
dlgame "Test" -DryRun
dlanime "Test" -isAnimeSeries yes -DryRun
dltv "Test" -DryRun
```

**To inspect all connected drives and their picks (queries the API):**
```
powershell -File lib\DriveResolver.ps1
```

### When editing scripts

- Logic lives in the `.ps1` files. The `.cmd` files only parse args and invoke PowerShell.
- `Initialize-DlConfig` lives in `lib\DriveResolver.ps1` and is dot-sourced by each script. The function signature is unchanged.
- `Resolve-MediaPath` (same file) is a client for the drive-registry API — it does no drive scanning or scoring itself. To change how drives are ranked or add a drive, edit the [drive-registry](../drive-registry) policy, not these scripts.
- All scripts use identical logging via `Write-Log` with levels: `INFO`, `SUCCESS`, `WARN`, `ERROR`, `DEBUG`. In dlrom, `DEBUG` is hidden unless `--verbose`/`-Verbose` is passed, and `--quiet`/`-Quiet` hides routine `INFO`.
- **dlrom** is split into dot-sourced modules (the others are single-file). `Add-ROM.ps1` is the orchestrator; the logic lives in `Cdromance.ps1` (scraping: `Invoke-CdromanceSearch`, `Get-DownloadLinks`, `Select-DownloadLinks` — multi-disc, English/USA preference, demo filtering), `Downloaders.ps1` (the `Invoke-FileDownload` dispatcher over Motrix/AB/aria2c/curl/BITS/WebClient), `RomFiles.ps1` (extraction + install), `SteamRomManager.ps1`, and `Logging.ps1`. See [`dlrom/README.md`](dlrom/) for the full breakdown.

