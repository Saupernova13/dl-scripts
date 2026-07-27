# dl-scripts

PowerShell scripts for searching and downloading media with automatic extraction and installation.

| Script | CMD | Source | Downloader | Description |
|--------|-----|--------|------------|-------------|
| [dlanime](dlanime/) | `dlanime.cmd` | nyaa.si | qBittorrent | Anime series and movies |
| [dlgame](dlgame/) | `dlgame.cmd` | appnetica.com | qBittorrent | PC games (Steam folder versions) |
| [dlmovie](dlmovie/) | `dlmovie.cmd` | YTS | qBittorrent | Movies |
| [dltv](dltv/) | `dltv.cmd` | The Pirate Bay | qBittorrent | TV shows |
| [dlrom](dlrom/) | `dlrom.cmd` | retrogametalk.com/repo | Motrix / AB / aria2c / curl / BITS / PowerShell | Video game ROMs (auto-extract + auto-install to emulator dirs + auto-add to Steam via Steam ROM Manager) |

## Setup

1. Add the root of this repo to `PATH`
2. Run any script directly from any terminal:

```
dlanime "Frieren"
dlgame "Spider-Man"
dlmovie "Inception"
dltv "Breaking Bad"
dlrom "Zelda" --platform n64
dlrom "Danganronpa V3" --platform vita   # Vita3K build by default; --vita console for hardware
```

Config is stored at `%LOCALAPPDATA%\dlScripts\config.json` and is **auto-created with defaults on first run** — no manual setup required. See each subfolder's `README.md` for the full parameter reference.

## Nothing here blocks on a download

Every script returns as soon as the transfer is handed off. None of them sit and wait for
gigabytes to arrive, which matters when the caller is a script, a scheduled task, or an
agent that has better things to do.

| Script | Returns when | Follow progress with |
|--------|--------------|----------------------|
| `dlanime` / `dlgame` / `dlmovie` / `dltv` | the torrent is queued in qBittorrent | qBittorrent (WebUI on `:8075`) |
| `dlrom` | the links are resolved and a worker is spawned | `dlrom --status <jobId>` / `dlrom --list` |

The torrent-based scripts have always behaved this way — qBittorrent owns the transfer and
is where you watch it, so they need no job system of their own.

`dlrom` is the one that downloads over HTTP itself, so it runs its own background worker and
tracks it as a job:

```
$ dlrom "Gran Turismo 4" --platform ps2
  Job ID:   a3f9c21b8e04
  Check:    dlrom --status a3f9c21b8e04
$                                          # returns here; the worker keeps going

$ dlrom --status a3f9c21b8e04
  Status:     running
  Step:       downloading
  Progress:   [########............] 41%
```

Pass `--wait` to `dlrom` only when you want to sit and watch it. See
[dlrom/README.md](dlrom/#headless--background-use) for the job model, states, and JSON fields.

None of these scripts prompt unless you ask for it: interactive selection is opt-in via
`--interactive`, and without it they auto-select and carry on. A run with no console
attached will never stop to ask a question — it fails with an explanation instead.

## Requirements

- **Windows** with PowerShell 5.1+ (built into Windows 10/11).
- A torrent client (**qBittorrent** with the Web UI enabled) for `dlanime`/`dlgame`/`dlmovie`/`dltv`.
- `dlrom` additionally uses **7-Zip** (extraction); a download manager (Motrix / AB), Steam ROM Manager and **Python 3** (only to rebuild the PS2 torrent index) are optional — see [`dlrom/README.md`](dlrom/).

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

A monorepo of five independent PowerShell download scripts, each wrapped by a root-level `.cmd` file. The CMD wrappers are what gets invoked from the terminal (and from PATH). They delegate to the `.ps1` files inside each subfolder.

### Never block on a download (read this first)

Every command here is designed to hand off and return. **Do not wait for a download to
finish, and never wrap one in a poll-until-done loop.** Start it, report the handle, move on.

- `dlanime` / `dlgame` / `dlmovie` / `dltv` — return the moment the torrent is queued in
  qBittorrent. There is nothing to wait for; qBittorrent (`:8075`) owns the transfer.
- `dlrom` — searches, resolves links, spawns a background worker, prints a **Job ID**, and
  returns. Report the job id. Check it later with `dlrom --status <jobId>`
  (add `--json` for parsing) or `dlrom --list`.
- `--wait` on `dlrom` exists for humans who want to watch a progress bar. **Do not use it.**

These downloads are ROM- and film-sized: minutes to hours. A blocked call is a session you
cannot talk to until it ends.

Interactive prompts are opt-in via `--interactive`; without it every script auto-selects.
If a run genuinely cannot proceed without an answer (e.g. no ROMs base can be resolved) it
fails with an explanation rather than hanging on a prompt no one can see.

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
    ├── Constants.ps1        ← shared literals (job/downloader vocab, extensions, regions)
    ├── Common.ps1           ← shared helpers (config access, timestamps, region ranking)
    ├── Add-ROM.ps1          ← orchestrator (thin) + worker entry point (-JobFile)
    ├── Jobs.ps1             ← job state, detached spawn, --status/--list
    ├── RomPipeline.ps1      ← download→extract→file→Steam (worker and --wait share it)
    ├── Logging.ps1          ← Write-Log + progress lines + formatters
    ├── RetroGameTalk.ps1    ← search + link discovery
    ├── Downloaders.ps1      ← download backends + dispatcher
    ├── RomFiles.ps1         ← extraction + ROM install (Install-RomFromDownload)
    ├── SteamRomManager.ps1  ← Steam ROM Manager sync
    ├── QbitTorrent.ps1      ← qBittorrent WebUI client (PS2 torrent fallback)
    ├── Ps2TorrentIndex.ps1  ← PS2 archive torrent fallback
    ├── ps2_torrent.py       ← torrent index parser (Python helper)
    ├── Ps2Serial.ps1        ← PS2 serial resolve + [HANDOFF] line
    ├── tests/               ← Pester suites + fixtures (Invoke-Tests.ps1)
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
  "rom":    { "romsBase": "C:\\Emulation\\roms", "tempDir": "%TEMP%\\dlrom", "motrixRpcUrl": "http://localhost:16800/jsonrpc", "maxResults": 10, "pollIntervalMs": 2000, "steamSync": true, "srmExe": "", "srmRestartSteam": "auto", "srmEnableParser": true, "srmWrapperCmd": "", "abPort": 15151, "abDownloadDir": "", "abTimeoutSec": 1800, "vitaBuild": "emu", "jobKeepDays": 7 }
}
```

Each script self-bootstraps: if the file or its section is missing, it is created with defaults and execution continues. No crash, no manual step. New keys (e.g. `useDriveMetadata`) are automatically backfilled into existing sections on next run.

`dlgame` additionally requires a `.settings` file in the `dlgame/` subfolder for appnetica.com credentials (Email, Password); it is gitignored. `dlrom` needs no credentials at all. All other settings come from `config.json`.

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

### PS Vita: emulator vs console builds (dlrom)

The Vita is the one platform whose games The Repo publishes **twice**, and the two files are not interchangeable: `[Vita3K]` is repacked for the [Vita3K](https://vita3k.org/) emulator, `[NoNpDrm]` is a dump for a modded console. Grabbing the wrong one fails silently — it installs perfectly and then will not run.

- **The Vita3K build is the default.** `--vita console` takes the hardware dump instead, `--vita any` switches the preference off, and `[rom].vitaBuild` changes the default for every run. Given without `--platform`, `--vita` also implies the Vita catalogue.
- **A Vita3K download is never extracted** — the emulator imports the `.zip` itself, so it is filed into `<romsBase>\psvita` exactly as it arrived. No `--no-extract` needed.
- **One-build games still work.** Console-only and unmarked releases are common; dlrom warns and takes what exists rather than returning nothing. The keep-it-zipped rule follows the file that was actually chosen, not the request, so a NoNpDrm fallback still extracts normally.

Which build landed is recorded on the job (`vitaBuild`) and printed in the result block. Full detail in [`dlrom/README.md`](dlrom/#ps-vita-emulator-vs-console-builds).

### The Repo needs no account (dlrom)

The ROM catalogue that used to live at cdromance.org is now **The Repo**, a WordPress catalogue mounted under the RetroGameTalk forum at `retrogametalk.com/repo/`.

It advertises a members-only gate, but that gate is enforced entirely in the browser — `if (!document.cookie.includes("xf_online=1")) location.replace("/login/")` — and a script never executes it. Browsing, searching, the "Show Links" reveal and the file transfer all work anonymously, so dlrom has **no login and stores no credentials**.

dlrom keeps one cookie jar per run for a narrower reason: the reveal call must present the WordPress nonce scraped from the game page, and WordPress ties that nonce to the `PHPSESSID` it was minted under. An empty reveal makes dlrom discard the jar and retry once with a fresh nonce.

Unlike cdromance, retrogametalk.com serves plain HTTP clients without a Cloudflare challenge, so there is **no Docker, FlareSolverr or `curl_cffi` dependency any more** — `Invoke-WebRequest` is enough. The resolved `dl*.retrogametalk.com/download.php?…&key=…` URLs carry their own authorisation in the query string and need no cookie, so Motrix/AB/aria2 fetch them directly.

Use `--links-only` to resolve and print the download links without downloading.

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
- Platform folders match EmuDeck's layout (e.g. PS1 → `psx`, GameCube → `gc`, Master System → `mastersystem`, Vita → `psvita`) so both the emulators and SRM's parsers find the files.
- `srm add` runs **all** currently-enabled parsers, so the first sync may add a backlog of everything already on disk — SRM dedupes, so this is safe.
- Requires SRM configured once (EmuDeck does this) with its parsers pointing at `romsBase`.

### Temp cleanup (dlrom)

Each download removes its temp archive and extraction directory in a `finally`, so nothing is left in `%TEMP%\dlrom` whether the download **succeeds or fails**. Only the installed ROM remains at its destination. `--no-extract` is the one exception: it intentionally keeps the downloaded archive (that's the deliverable) and does not extract. A PS Vita **Vita3K** build takes that same path automatically, since the emulator installs the `.zip` itself.

A worker that is *killed* — reboot, task manager, power cut — never reaches that `finally`, so `dlrom --clean` exists to sweep up after it:

```
dlrom --clean             # temp files, abandoned partials (.aria2/.part/...), caches
dlrom --clean --dry-run   # preview only
dlrom --clean --all       # also clear finished job records and logs
```

It will **never** delete something a live job is downloading (identity comes from the active jobs' link labels, not from the file), and it does not touch your download manager's folder or `~\Downloads`. Details in [`dlrom/README.md`](dlrom/#housekeeping--clean).

### CMD wrapper behaviour

- `%~dp0` is used to resolve the `.ps1` path relative to the CMD file, so the scripts work correctly regardless of which directory the user is in or where PATH points.
- All wrappers invoke PowerShell with `-NoProfile`: the user's profile is irrelevant to these scripts, and loading it slows every run and prepends profile noise to stdout that a caller parsing output has to wade through.
- **The `.cmd` files must keep CRLF line endings** (enforced by `.gitattributes`). `cmd.exe` resolves `goto` by seeking to a byte offset, and with LF-only endings that seek lands mid-line once the file is long enough — the label is then reported "not found". It fails positionally, so it surfaces as one subcommand breaking after an unrelated edit made the file longer.
- `dlanime.cmd` accepts: `"Query" [series|movie] [destination] [--list]` — `--list` can appear in any position.
- `dlgame.cmd`, `dlmovie.cmd`, `dltv.cmd` accept: `"Query" [destination]`.
- **All four also forward PowerShell flags.** Any argument starting with `-` (e.g. `-DryRun`, `-Interactive`, `-MaxResults 20`, `-TrustedOnly`) is passed straight through to the `.ps1`; the first bare word after the query is still the destination. Before this, `dlmovie "Inception" -DryRun` handed `-DryRun` over as the *destination* and PowerShell rejected it with `Missing an argument for parameter 'Destination'` — so the documented `-DryRun` examples never actually worked from the wrappers.
- `dlrom.cmd` accepts: `"Query" [--platform PLATFORM] [--region REGION] [--vita emu|console] [--sort SORT] [--dest PATH] [--wait] [--interactive] [--no-extract] [--no-steam] [--links-only] [--json] [--verbose] [--quiet]`, plus the subcommands `--status <jobId> [--json]`, `--list [--json]` and `--clean [--all] [--dry-run] [--json]`. These are matched before `%1` is treated as a game name, since none of them carry one. By default it prints a clean summary; `--verbose` reveals every internal step, `--quiet` shows only results and problems.

### Background jobs (dlrom)

`dlrom` returns after resolving links and spawning a worker; the worker is the same
`Add-ROM.ps1` re-invoked with `-JobFile <path>`.

- Job state and logs: `%LOCALAPPDATA%\dlScripts\jobs\rom\<id>.json` / `<id>.log`. Read the
  JSON directly if `--status --json` is inconvenient.
- The spawn uses raw `ProcessStartInfo` with `CreateNoWindow` + `UseShellExecute=$false`,
  and `cmd`'s own `> log 2>&1` for output. Two reasons, both load-bearing: PowerShell's
  `Start-Process` cannot express `CreateNoWindow` (so it flashes a console window), and the
  worker must not inherit the caller's console handles — if it does, `dlrom.cmd` stays
  tethered to the worker and the caller's terminal hangs, which is the whole bug this
  design exists to avoid. The worker's stdin is redirected and closed, so a stray prompt
  hits EOF and fails fast instead of blocking forever.
- Statuses: `pending`, `running`, `completed`, `failed`, and `orphaned` (the worker's process
  is gone but recorded no outcome — computed at read time, never stored).
- Finished jobs are pruned after `jobKeepDays` (default 7). Running jobs are never pruned.
- `--wait` runs the identical pipeline in the foreground and still writes a job file, so the
  two modes cannot drift apart.

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
- **dlrom** is split into dot-sourced modules (the others are single-file). `Add-ROM.ps1` is the orchestrator; the logic lives in `RetroGameTalk.ps1` (scraping: `Invoke-RgtSearch`, `Get-RgtDownloadLinks`, `Select-DownloadLinks` — PS Vita build choice, multi-disc, English/USA preference, demo filtering), `Downloaders.ps1` (the `Invoke-FileDownload` dispatcher over Motrix/AB/aria2c/curl/BITS/WebClient), `RomFiles.ps1` (extraction + install), `SteamRomManager.ps1`, and `Logging.ps1`. See [`dlrom/README.md`](dlrom/) for the full breakdown.

