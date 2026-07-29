# dlrom

Downloads one console game and installs it for you.

It searches [The Repo](https://retrogametalk.com/repo/) on RetroGameTalk, downloads
the ROM, unpacks it, puts it in the right emulator folder, and adds it to Steam.

> The old cdromance.org catalogue now lives at `retrogametalk.com/repo/`. dlrom
> uses that address. cdromance is gone, and so is the Cloudflare bypass it needed.

**Downloads run in the background.** dlrom finds the file, starts a worker, and
gives you a job id. It returns in seconds. You never wait for the download.

## Command

```
dlrom "Game Name" [options]
dlrom --status <jobId> [--json]
dlrom --list [--json]
dlrom --clean [--all] [--dry-run] [--json]
```

Add the repo root to `PATH` to run it from anywhere. Put the game name in quotes.

### Platforms

`ps2`, `ps1`, `psx`, `psp`, `eboot`, `vita`, `n64`, `gamecube`, `gc`, `wii`,
`nds`, `ds`, `gba`, `snes`, `nes`, `fds`, `gbc`, `gb`, `dreamcast`, `dc`,
`saturn`, `segacd`, `genesis`, `megadrive`, `32x`, `sms`, `mastersystem`,
`gamegear`, `gg`, `pico`, `3do`, `amiga`, `arcade`, `msx`, `dos`, `msdos`,
`windows`, `scummvm`, `neogeocd`, `ngp`, `ngpc`, `pc88`, `pc98`, `pcfx`,
`tg16`, `pcengine`, `tgcd`, `wonderswan`, `ws`

There is no 3DS. The Repo does not carry 3DS games.

### Regions

`usa`, `europe`, `japan`, `world`

## Quick examples

```
dlrom "Rayman 2"                              # returns a job id
dlrom "Final Fantasy VII" --platform ps1
dlrom "Metal Slug" --platform ps2 --region usa
dlrom "Danganronpa V3" --platform vita        # Vita3K build, kept zipped
dlrom "Persona 4 Golden" --vita console       # NoNpDrm build, for a real Vita

dlrom --status a3f9c21b8e04                   # how is it going?
dlrom --list                                  # all recent jobs
dlrom --clean                                 # free disk space

dlrom "Crash Bandicoot" --links-only          # print links, download nothing
dlrom "Spyro" --platform ps1 --verbose        # show every internal step
dlrom "Zelda" --platform n64 --interactive    # pick from a list yourself
dlrom "Gran Turismo 4" --platform ps2 --wait  # block until installed
```

## Flags

| Flag | What it does |
|------|--------------|
| `--platform NAME` | Search one console only, and pick the folder to install into. Without it, dlrom guesses the console from the search result. |
| `--region NAME` | Prefer a region: `usa`, `europe`, `japan`, `world`. |
| `--vita emu\|console\|any` | PS Vita only. Which build to take. See [PS Vita](#ps-vita-two-versions-of-every-game). |
| `--sort ORDER` | Sort the search results. |
| `--dest PATH` | Install into this folder instead of the usual one. |
| `--wait` | Download in this window instead of the background. For humans watching a progress bar. |
| `--status ID` | Show one job's progress, then exit. Instant, even mid-download. |
| `--list` | List recent jobs, newest first. |
| `--clean` | Delete temp files, part-files and caches. See [Housekeeping](#housekeeping). |
| `--all` | With `--clean`: also delete finished job records. |
| `--dry-run` | With `--clean`: show what would go, delete nothing. |
| `--json` | Machine-readable output. |
| `--interactive` | Pick from the results list yourself. Needs a person at the keyboard. |
| `--no-extract` | Keep the downloaded archive. Do not unpack or install it. |
| `--no-steam` | Skip the Steam step this run. |
| `--links-only` | Print the download links and stop. Downloads nothing. |
| `--no-torrent` | Turn off the PS2 torrent fallback this run. |
| `--torrent-pick N` | Force file number `N` from the PS2 torrent. |
| `--verbose` | Show every internal step. For troubleshooting. |
| `--quiet` | Show only results, warnings and errors. |

## Background jobs

This is the normal way to use dlrom. Use it from a script, an agent, or any
session you do not want to sit and watch.

```
$ dlrom "Gran Turismo 4" --platform ps2

Download job spawned.  It will continue in the background.
  Job ID:   a3f9c21b8e04
  Source:   retrogametalk
  Title:    Gran Turismo 4
  Dest:     G:\Emulation\roms\ps2
  Log:      C:\Users\you\AppData\Local\dlScripts\jobs\rom\a3f9c21b8e04.log
  Check:    dlrom --status a3f9c21b8e04
```

The command returns there. A worker keeps going on its own. It downloads,
unpacks, installs, and syncs to Steam.

Check on it whenever you like:

```
dlrom --status a3f9c21b8e04          # progress, step, and the last 20 log lines
dlrom --status a3f9c21b8e04 --json   # the whole job record, for scripts
dlrom --list                         # every recent job and its state
```

**The search and the link lookup happen first, in your terminal.** That is on
purpose. "No results" is an instant answer, not something you discover by polling
later. Only the slow half runs in the background.

### Job states

| Status | Meaning |
|---|---|
| `pending` | The job file exists. The worker is starting. |
| `running` | The worker owns it. Check `step` to see where it is. |
| `completed` | The ROM is installed. |
| `failed` | It stopped without installing anything. `message` says why. |
| `orphaned` | The worker died and never recorded an outcome. Nothing is running. |

While `running`, the `step` field is one of: `downloading`, `extracting`,
`filing`, `steam-sync`.

### Useful job fields (`--status --json`)

| Field | Meaning |
|---|---|
| `id` | Job id. |
| `kind` | `retrogametalk` or `torrent` (the PS2 fallback). |
| `status` | See the table above. |
| `step` | Current phase. |
| `progress` | 0 to 100. |
| `installedPaths` | Every file this job installed. |
| `vitaBuild` | `emu` or `console` for a PS Vita download. Empty otherwise. |
| `noExtract` | True if the download was kept as an archive. |
| `handoff` | The `[HANDOFF]` line for PS2. Feed its serial to `dlps2tex`. |
| `logFile` | Full worker log. |
| `message` | Last note, and the failure reason when `failed`. |

Job files live in `%LOCALAPPDATA%\dlScripts\jobs\rom\`. Finished ones are deleted
after `jobKeepDays` (default 7). Running jobs are never deleted.

### Watching it live instead

`--wait` downloads in your terminal with a progress bar:

```
dlrom "Gran Turismo 4" --platform ps2 --wait
```

It runs the same code as the worker and still writes a job file, so
`dlrom --status <id>` works afterwards. Use it when you want to watch. Do not use
it from a script or an agent.

## PS Vita: two versions of every game

The Vita is the only console here where every game is published **twice**. The two
files are not interchangeable.

| Marker in the filename | Runs on | dlrom installs it |
|---|---|---|
| `[Vita3K]` | the [Vita3K](https://vita3k.org/) emulator | **as the downloaded `.zip`, never unpacked** |
| `[NoNpDrm]` | a modded PS Vita console | unpacked like any other ROM |

**Picking the wrong one fails silently.** It downloads, installs and syncs to
Steam perfectly well. Then it just will not run.

So dlrom chooses on purpose. It does not take whatever the page lists first,
because that order is not stable. Either build can come first.

### The default is the emulator

```
dlrom "Danganronpa V3" --platform vita                  # Vita3K (the default)
dlrom "Danganronpa V3" --platform vita --vita console   # NoNpDrm, for real hardware
dlrom "Danganronpa V3" --vita emu                       # --platform vita is implied
dlrom "Danganronpa V3"                                  # also Vita3K
```

The last example works because dlrom reads the console from the search result.

`--vita` accepts:

| Value | Aliases | Meaning |
|---|---|---|
| `emu` | `emulator`, `vita3k`, `3k` | Vita3K build. The default. |
| `console` | `hardware`, `hw`, `real`, `nonpdrm` | NoNpDrm build. |
| `any` | `both`, `either` | No preference. Take the first one listed. |

Set `[rom].vitaBuild` in the config to change the default for every run.

### Why the zip is not unpacked

Vita3K imports the `.zip` itself. Inside is an `app/<TITLEID>/…` folder tree, not
a ROM file. Unpacking it would give you a folder the emulator cannot install.

So a Vita3K download is copied into `<romsBase>\psvita` exactly as it arrived.
This is automatic. You do not need `--no-extract`.

The NoNpDrm build is a normal archive and is unpacked as usual.

### When a game has only one build

Some older games are console-only. A few have no marker at all. Some pages also
list extra files that are not the game, like `AR Cards.zip`. dlrom drops those
extras.

If the build you asked for does not exist, dlrom warns you and takes what does
exist:

```
[WARN] Vita: this game has no Vita3K (emulator) build on The Repo - falling back to what it does offer.
[INFO] Vita build: NoNpDrm (console)
```

A build you have to convert beats no download at all.

**The "keep it zipped" rule follows the file that was actually chosen.** It does
not follow what you asked for. So a NoNpDrm build reached by this fallback is
still unpacked normally.

Which build you got is recorded on the job as `vitaBuild`, and printed at the end.

## Housekeeping

A download that dies partway leaves a part-file behind. A worker that dies between
unpacking and installing leaves a folder behind. Both are ROM-sized. Nothing ever
comes back for them.

`--clean` removes them.

```
dlrom --clean             # temp files, abandoned part-files, caches
dlrom --clean --dry-run   # show what would go, delete nothing
dlrom --clean --all       # also delete finished job records and logs
dlrom --clean --json      # machine-readable result
```

### What it deletes

| Category | What goes |
|---|---|
| `work` | Everything in `tempDir`: interrupted downloads and `extracted\` folders. Also `%TEMP%\dlrom-debug.html` and anything left in the PS2 torrent staging folder. |
| `partial` | `.aria2`, `.part`, `.tmp` and similar control files in the AB download folder. |
| `cache` | `ps2-gamedb.json` (rebuilt from `GameIndex.yaml` when needed) and the obsolete `cf_session.json`. |
| `job` | **Only with `--all`:** finished job records and logs in `jobs\rom`. |

### What it never deletes

**Files a running job is using.** This is the rule the whole feature is built
around.

A running download's part-file looks exactly like an abandoned one. You cannot
tell them apart by looking at the file. So dlrom does not look at the file. It
reads the active jobs and skips their filenames. Active job records survive
`--all` too.

It says so when it skips something:

```
[INFO] Keeping Danganronpa V3 (USA)(PCSE01100)[NoNpDrm].zip - a running job is downloading it.
[INFO] Keeping job 8a1cf5cfaa7e - it is still running.
```

**Your download manager's folder.** dlrom does not touch Motrix's folder, or
`~\Downloads` in general. Those belong to the manager and to you. The one
exception is the AB Download Manager watch folder, because dlrom is what told AB
to use it.

Finished jobs are also deleted by age on every normal run (`jobKeepDays`,
default 7). `--clean --all` is the on-demand version.

## PS2 torrent fallback

The Repo is the only website dlrom uses. If it fails, the run used to end there.

For **PS2 games** there is a second source: a local Redump PS2 archive `.torrent`
that indexes the full set.

When The Repo cannot deliver and you passed `--platform ps2`, dlrom looks the game
up in that archive. It downloads **only that one file** through qBittorrent, then
unpacks and installs it exactly like a web download.

The Repo "cannot deliver" means any of: the site is unreachable, it is
rate-limiting, the search found nothing, or the page had no download links.

### How it picks the file

- Every word of your query must appear in the title. Numbers count.
- Demos, betas and prototypes are rejected.
- Special editions (FES, Undub, Director's Cut, GOTY) are skipped unless you named
  one. So `"Persona 3"` gets the base game.
- Region order: your `--region` first, then USA, World, Europe, Japan.

If nothing matches confidently, it refuses. It then lists the closest titles with
their file numbers so you can re-run with `--torrent-pick N`.

After the file finishes, the torrent is removed from qBittorrent. Nothing is left
seeding. The ROM stays on disk.

### Requirements

qBittorrent must be running with its WebUI enabled. dlrom finds the port from
`qBittorrent.ini` (usually `8075`). Note the other dl-scripts default to `8080`.
You can set `[rom].qbitHost` instead.

The `.torrent` and its prebuilt index ship in `dlrom/data/ps2-torrent/`. The index
is rebuilt automatically if you replace the `.torrent`. That needs Python 3 on
`PATH`.

### PS2 torrent config keys

| Key | Meaning |
|-----|---------|
| `ps2TorrentEnabled` | Turn the fallback on or off. Default `true`. |
| `ps2TorrentPath` | Path to the archive `.torrent`. Blank uses the committed copy. |
| `ps2TorrentIndexPath` | Path to the JSON index. Blank uses the committed copy. |
| `ps2TorrentStaging` | Where qBittorrent saves the file. Blank uses `<romsBase>\.dlrom-torrent`. |
| `ps2TorrentTimeoutSec` | Max wait for the download. Default `14400`. |
| `qbitHost` | qBittorrent WebUI address. Blank auto-detects. |
| `qbitUser` / `qbitPass` | Only needed if the WebUI asks for a login. |
| `ps2GameIndexPath` | PCSX2 `GameIndex.yaml`, used to find the serial. Blank auto-detects. |

## Which release it picks

dlrom prefers the **base** game over a special edition. `dlrom "Persona 3"` picks
"Persona 3", not "Persona 3 FES". It also honours `--region`.

But it never returns nothing. If only an edition exists, it takes the edition.

The torrent fallback is stricter. It refuses an edition you did not ask for,
because the archive always has the base game.

## PS2 texture handoff

When dlrom **finishes installing** a **PS2** game, it prints this line:

```
[HANDOFF] platform=ps2 serial=SLUS-21569 title="Shin Megami Tensei - Persona 3" texturecmd=dlps2tex "SLUS-21569"
```

Run that `texturecmd` to get HD textures for the **exact version** you just
downloaded. Base or FES, USA or PAL, they will line up. Use the serial rather than
typing the name again.

The serial comes from `GameIndex.yaml`, the same file `dlps2tex` uses.

**The line appears when the job finishes, not when it starts.** So it is not in
the output of the command that spawned the job:

```
dlrom --status <jobId>          # printed as the [HANDOFF] line
dlrom --status <jobId> --json   # the "handoff" field
```

Under `--wait` it prints to your terminal at the end of the run.

## How it works

Steps 1 to 3 run in your terminal. Step 4 onward is the slow part, so a worker
takes over unless you passed `--wait`.

1. **Search.** Query The Repo and list matching games.
2. **Select.** Auto-select the best match, or show a numbered list with
   `--interactive`.
3. **Resolve links.** Reveal the download table. Pick the Vita build if this is a
   Vita game. Drop demos. Prefer English and USA versions. Queue one link per disc
   for multi-disc games.

   *A job is created here. By default a worker takes over from this point.*

4. **Download.** Through the best available backend.
5. **Unpack and install.** Real archives are unpacked with 7-Zip. A raw ROM
   download is installed as-is, and so is a Vita3K build. The filename is cleaned
   up so Steam launch commands do not break. The file moves to
   `<romsBase>\<console>`.
6. **Steam sync.** Add the ROM to Steam, unless `--no-steam`.
7. **Cleanup.** Delete the temp archive and unpack folder, whether the run
   succeeded or failed.
8. **Report.** Write the result and the PS2 `[HANDOFF]` line to the job.

The PS2 torrent fallback runs in the background the same way.

### How the worker is started

The worker is the same `Add-ROM.ps1`, re-run with `-JobFile`.

It starts through `ProcessStartInfo` with `CreateNoWindow`, so no console window
flashes. `cmd` sends its output to the job's log file.

The important part: the worker does **not** inherit your console handles. That is
what lets `dlrom.cmd` exit instead of staying tied to a download that runs for
hours. See [`Jobs.ps1`](Jobs.ps1).

## Download backends

dlrom finds the best available downloader at runtime. If one fails, it tries the
next:

```
Motrix (aria2 RPC)  ->  AB Download Manager  ->  aria2c  ->  curl.exe  ->  BITS  ->  Invoke-WebRequest
```

- **Motrix** is used when its aria2 RPC answers (`motrixRpcUrl`).
- **AB Download Manager** is used when Motrix is not running (`abPort`, default
  15151). AB cannot report when a download finishes. So dlrom passes a filename
  and watches AB's folder (`abDownloadDir`, default `%USERPROFILE%\Downloads\ABDM`)
  until the file is done. Set `abDownloadDir` if you moved AB's folder.
  `abTimeoutSec` limits the wait.
- The rest ship with Windows and need nothing installed.

## Where ROMs are installed

dlrom picks the base folder in this order. The first one that works wins.

1. `--dest PATH`. An explicit override for this run.
2. `romsBase` from the config (default `G:\Emulation\roms`), if that folder exists.
3. **Drive picker.** A connected drive advertising a `rom_path` in its
   `drive-meta.json`. See the [root README](../README.md#where-files-are-saved).
4. **Ask you.** Last resort, and only with `--interactive`.

The ROM goes into `<romsBase>\<console>`.

Folder names match EmuDeck's layout so the emulators and Steam ROM Manager find
them. For example PS1 becomes `psx`, GameCube becomes `gc`, Master System becomes
`mastersystem`, and Vita becomes `psvita`.

## No account needed

The Repo shows a members-only message, but only in the browser:

```js
if (!document.cookie.includes("xf_online=1")) { window.location.replace(".../login/") }
```

A script never runs that JavaScript. So browsing, searching, revealing links and
downloading all work without an account. dlrom has no login and stores no
credentials.

It keeps one cookie jar per run for a smaller reason. The link reveal has to send
a WordPress nonce scraped from the game page, and WordPress ties that nonce to the
session that created it. If a reveal comes back empty, dlrom throws the jar away
and retries once with a fresh nonce.

The `dl*.retrogametalk.com/download.php?…&key=…` links carry their own
authorisation in the URL. They need no cookie. That is what lets Motrix, AB
Download Manager and aria2c fetch them directly.

There is no Docker, no FlareSolverr and no `curl_cffi`. Unlike cdromance,
retrogametalk.com serves plain HTTP clients, so `Invoke-WebRequest` is enough.

## Steam ROM Manager

After a ROM is installed, dlrom adds it to Steam through Steam ROM Manager (SRM).
It never writes a Steam shortcut itself. That means running SRM later updates
things instead of creating duplicates.

dlrom prefers the standalone `srm-wrapper` CLI if it is on `PATH`, or set
`srmWrapperCmd`. If the wrapper is missing or fails, dlrom uses its built-in
driver:

1. Find `srm.exe` (`srmExe`, else `G:\Emulation\tools\srm.exe`, else `PATH`).
2. If `srmEnableParser` is on, enable any disabled SRM parser pointing at the
   destination folder.
3. Follow `srmRestartSteam`: `auto` restarts Steam only if it is running, `never`
   never does, `always` always does.
4. Run `srm add` quietly, then restart Steam if it was closed.

If neither the wrapper nor `srm.exe` is found, dlrom does not crash. It logs where
the ROM was saved.

## Output detail

By default the output is a clean story: the downloader chosen, the search, the
results, a progress bar, and where the ROM went. Internal detail is hidden.

- `--verbose` adds every internal step. Use it for troubleshooting.
- `--quiet` hides routine progress. Only results, warnings and errors remain.

## Configuration

Settings live in the `rom` section of `%LOCALAPPDATA%\dlScripts\config.json`. The
file is created with defaults on first run.

```json
{
  "rom": {
    "romsBase": "G:\\Emulation\\roms",
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
    "vitaBuild": "emu",
    "jobKeepDays": 7
  }
}
```

| Key | Default | What it does |
|-----|---------|--------------|
| `romsBase` | `G:\Emulation\roms` | Where ROMs go. Used when the folder exists. |
| `tempDir` | `%TEMP%\dlrom` | Working folder for downloads and unpacking. |
| `motrixRpcUrl` | `http://localhost:16800/jsonrpc` | Motrix aria2 RPC address. |
| `maxResults` | `10` | How many search results to show. |
| `pollIntervalMs` | `2000` | How often to ask Motrix for progress. |
| `jobKeepDays` | `7` | Days to keep finished job files. Running jobs are never deleted. |
| `steamSync` | `true` | Turn the Steam step on or off. |
| `srmExe` | `""` | Path to `srm.exe`. Blank auto-detects. |
| `srmRestartSteam` | `auto` | `auto`, `never` or `always`. |
| `srmEnableParser` | `true` | Enable the SRM parser for the destination before adding. |
| `srmWrapperCmd` | `""` | Path to `srm-wrapper.cmd`. Blank auto-detects on `PATH`. |
| `abPort` | `15151` | AB Download Manager port. |
| `abDownloadDir` | `""` | AB's download folder. Blank auto-detects. |
| `abTimeoutSec` | `1800` | How long to wait for an AB download. |
| `vitaBuild` | `emu` | Which PS Vita build to prefer: `emu` or `console`. |

The PS2 torrent keys are listed [above](#ps2-torrent-config-keys).

## PowerShell parameters

The CMD wrapper passes these through. You can also call the script directly:

```powershell
.\dlrom\Add-ROM.ps1 -Query "Zelda" [-Platform n64] [-Region usa] [-VitaBuild emu] `
    [-Sort ...] [-Destination "D:\roms"] [-MaxResults 10] [-Wait] [-Interactive] `
    [-NoExtract] [-NoSteam] [-LinksOnly] [-NoTorrent] [-TorrentPick N] [-Json] `
    [-Verbose] [-Quiet]

.\dlrom\Add-ROM.ps1 -Status <jobId> [-Json]
.\dlrom\Add-ROM.ps1 -ListJobs [-Json]
.\dlrom\Add-ROM.ps1 -Clean [-All] [-DryRun] [-Json]
```

`-JobFile <path>` is the worker's own entry point. `Start-DlromJob` uses it. Do not
call it by hand.

## Requirements

- **Windows** with PowerShell 5.1 or newer. This ships with Windows 10 and 11.
- **7-Zip** (`winget install 7zip.7zip`) to unpack `.7z` and `.rar` files.
- Optional: **Python 3** on `PATH`, only to rebuild the PS2 torrent index.
- Optional: **Motrix** or **AB Download Manager** for faster, resumable downloads.
  The built-in fallbacks work without them.
- Optional: **Steam ROM Manager** or `srm-wrapper` for the Steam step.

## Tests

```powershell
.\dlrom\tests\Invoke-Tests.ps1          # offline suite, about 2 seconds
.\dlrom\tests\Invoke-Tests.ps1 -Live    # plus the live site, about 90 seconds
```

Needs Pester 5 or newer:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

| Suite | What it covers |
|-------|----------------|
| `Shared.Tests.ps1` | The shared foundation. That there is exactly one ROM extension table, and it covers every console. One archive signature table that both readers agree on. One reject regex. One region vocabulary. One Vita build vocabulary whose two patterns never overlap. Plus config reading, the formatters, filename safety, and `Install-RomFromDownload`. |
| `RetroGameTalk.Tests.ps1` | The real functions with only `Invoke-WebRequest` mocked. Search URLs for every platform and filter, result parsing, the nonce reveal, link extraction, demo and region and multi-disc selection, Vita build selection and its fallbacks, region detection, edition-aware picking, and failure classification. Fixtures in `tests/fixtures/` are trimmed captures of real pages. |
| `RetroGameTalk.Live.Tests.ps1` (tag `Live`) | The live site. Every platform slug has a category page. Every search filter works and does not leak other platforms. 14 known ROMs resolve to real download URLs. A Vita page still carries both builds, told apart only by the filename marker. One URL is fetched to prove it serves bytes with no cookies. |

**The live suite is what notices the site changing.** A renamed category, a filter
that silently stops matching, or a login appearing server-side all fail there and
nowhere else. That class of breakage is what ended the cdromance integration.

## Module layout

`Add-ROM.ps1` is a thin orchestrator. It loads these modules:

| File | Responsibility |
|------|----------------|
| `Constants.ps1` | Every shared value: job and downloader names, ROM and archive extensions, archive signatures, release markers, region order, Vita build markers, default addresses. Loaded first. |
| `Common.ps1` | Small helpers with no dependencies: config reading, timestamps, data folders, short ids, empty-folder cleanup, region and Vita build resolution. |
| `Add-ROM.ps1` | Arguments, config, the search, the link lookup, and the worker entry point. |
| `Jobs.ps1` | Job state on disk, starting the detached worker, `--status` and `--list` output, pruning. |
| `Clean.ps1` | `--clean`. Finds temp files, part-files, caches and job history. Refuses to remove anything a live job owns. |
| `RomPipeline.ps1` | Download, unpack, install, Steam. Shared by the worker and `--wait`. |
| `Logging.ps1` | `Write-Log`, progress lines, and size and speed formatting. |
| `RetroGameTalk.ps1` | Platform tables, search, and download link discovery and selection. |
| `Downloaders.ps1` | The Motrix, AB, aria2c, curl, BITS and WebClient backends, and the dispatcher. |
| `RomFiles.ps1` | Archive detection and unpacking, finding the ROM, filename safety, and `Install-RomFromDownload`. That is the one download-to-installed-ROM path, shared by the web pipeline and the torrent fallback. |
| `SteamRomManager.ps1` | Steam ROM Manager sync. |
| `QbitTorrent.ps1` | qBittorrent WebUI client, used by the PS2 torrent fallback. |
| `Ps2TorrentIndex.ps1` + `ps2_torrent.py` | PS2 torrent fallback: match, download one file, install. |
| `Ps2Serial.ps1` | PS2 serial lookup and the result block with the `[HANDOFF]` line. |

## Troubleshooting

| Problem | What to do |
|---|---|
| Search fails | Run `dlrom "..." --links-only --verbose` to see the request and the reason. |
| No download links found | dlrom saves the page to `%TEMP%\dlrom-debug.html`. A `403` from the reveal endpoint would mean the site started gating The Repo server-side. |
| An AB download never finishes | Set `abDownloadDir` to AB's real folder. Raise `abTimeoutSec`. |
| ROM lands in `\roms` instead of a console folder | Pass `--platform`. The console could not be guessed from the search result. |
| A job says `orphaned` | Its worker died without recording an outcome. Nothing is running. Check the job's `logFile` to see how far it got, then run it again. |
| A job sits at the same percentage | The download backend is retrying. aria2 and Motrix retry an unreachable host for a long time before giving up. `dlrom --status <id>` shows the last log lines. |
| `Cannot resolve a ROMs base directory` | dlrom refuses to prompt when nothing can answer. Pass `--dest`, set `romsBase` in the config, connect a drive with a `rom_path`, or re-run with `--interactive`. |
| A Vita game will not load in Vita3K | Check the job's `vitaBuild`. If it says `console`, the game had no Vita3K build and you have a NoNpDrm dump to convert. |
| A Vita download arrived as a `.zip` | That is correct for a Vita3K build. The emulator installs the archive itself. Use `--vita console` if you wanted the hardware dump. |
