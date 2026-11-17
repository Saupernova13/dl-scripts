# dlrom

Downloads one console game and installs it for you.

It searches [The Repo](https://retrogametalk.com/repo/) on RetroGameTalk, downloads
the ROM, unpacks it, puts it in the right emulator folder, and adds it to Steam.

For consoles The Repo does not carry (Switch, 3DS, PS3, PS4, PS5, Xbox 360, Xbox, Wii U),
and for games The Repo fails on, it asks the NSWTL Telegram library bots instead. That is
a second source with its own rules: see [Telegram bots as a source](#telegram-bots-as-a-source).

> The old cdromance.org catalogue now lives at `retrogametalk.com/repo/`. dlrom
> uses that address. cdromance is gone, and so is the Cloudflare bypass it needed.

**Downloads run in the background.** dlrom finds the file, starts a worker, and
gives you a job id. It returns in seconds. You never wait for the download.

## Command

```
dlrom "Game Name" [options]
dlrom "Game Name" --platform switch          # Telegram-only console
dlrom --status <jobId> [--json]
dlrom --jobs [--json]
dlrom --resume <jobId|all> [--wait] [--json]  # restart a stalled or orphaned Telegram job
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

Served only by the Telegram bots (see [Telegram bots as a source](#telegram-bots-as-a-source)):

| Platform | Aliases | Folder under `romsBase` |
|---|---|---|
| `switch` | `nsw`, `ns` | `switch` |
| `3ds` | `n3ds` | `n3ds` |
| `ps3` | | `ps3` |
| `ps4` | | `ps4` |
| `ps5` | | `ps5` |
| `xbox360` | `x360` | `xbox360` |
| `xbox` | | `xbox` |
| `wiiu` | | `wiiu` |

The Repo does not carry these, so `--source auto` sends them straight to Telegram.

### Regions

`usa`, `europe`, `japan`, `world`

## Quick examples

```
dlrom "Rayman 2"                              # returns a job id
dlrom "Final Fantasy VII" --platform ps1
dlrom "Metal Slug" --platform ps2 --region usa
dlrom "Danganronpa V3" --platform vita        # Vita3K build, kept zipped
dlrom "Persona 4 Golden" --vita console       # NoNpDrm build, for a real Vita
dlrom "Mario Kart 8" --platform switch       # Telegram bot (no Repo for Switch)
dlrom "Danganronpa" --platform vita --source telegram --dry-run   # ask the bot, print the pick

dlrom --status a3f9c21b8e04                   # how is it going?
dlrom --jobs                                  # all recent jobs
dlrom --clean                                 # free disk space

dlrom "Crash Bandicoot" --dry-run             # print links, download nothing
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
| `--source auto\|rgt\|telegram` | Where to look. `auto` (default): The Repo first, the console's Telegram bot as the fallback, and Telegram straight away for Telegram-only consoles. `rgt` (aliases `retrogametalk`, `repo`): The Repo only. `telegram` (alias `tg`): the bot only; needs `--platform`. See [Telegram bots as a source](#telegram-bots-as-a-source). |
| `--sort ORDER` | Sort the search results. |
| `--dest PATH` | Install into this folder instead of the usual one. |
| `--wait` | Download in this window instead of the background. For humans watching a progress bar. With `--resume`, runs the resumed worker here. |
| `--status ID` | Show one job's progress, then exit. Instant, even mid-download. For a Telegram job it also shows the staging save path and any manual step. |
| `--jobs` | List recent jobs, newest first. `--list` with no game name does the same. |
| `--resume ID\|all` | Restart the worker of a Telegram job that is `orphaned`, or `failed` because it stalled, timed out or qBittorrent was down. Refuses completed jobs. `all` resumes every such job. See [Resuming a Telegram job](#resuming-a-telegram-job). |
| `--clean` | Delete temp files, part-files and caches. See [Housekeeping](#housekeeping). |
| `--all` | With `--clean`: also delete finished job records. |
| `--dry-run` | Resolve everything and stop: with a game name, print the download links and download nothing (Telegram: send the search, print the results and the pick, never request the torrent); with `--clean`, show what would go and delete nothing. `--list` and `--links-only` are synonyms of the first sense. |
| `--json` | Machine-readable output. A Telegram run prints one object: `ok`, `jobId`, `title`, `hash`, `bot`, `platform`, `savePath`, `status`, plus `message`, `installedPaths` and `manualNote` (filled in under `--wait`). |
| `--interactive` | Pick from the results list yourself, on any source. Needs a person at the keyboard. |
| `--no-extract` | Keep the downloaded archive. Do not unpack or install it. |
| `--no-steam` | Skip the Steam step this run. On a Steam Deck this also means it never leaves Game Mode. |
| `--sync-steam` | Add ROMs to Steam now. Runs a full Steam ROM Manager pass when nothing is queued. |
| `--no-game-mode` | With `--sync-steam` on a Steam Deck: stay in Desktop Mode afterwards. |
| `--steam-queue` | Show Steam syncs waiting for a desktop session. |
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
  Dest:     C:\Emulation\roms\ps2
  Log:      C:\Users\you\AppData\Local\dlScripts\jobs\rom\a3f9c21b8e04.log
  Check:    dlrom --status a3f9c21b8e04
```

The command returns there. A worker keeps going on its own. It downloads,
unpacks, installs, and syncs to Steam.

Check on it whenever you like:

```
dlrom --status a3f9c21b8e04          # progress, step, and the last 20 log lines
dlrom --status a3f9c21b8e04 --json   # the whole job record, for scripts
dlrom --jobs                         # every recent job and its state
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
| `orphaned` | The worker died and never recorded an outcome. Nothing is running. A Telegram job can be restarted with `--resume` (and is, automatically, see below). A Telegram job that has had no worker for two minutes also reads `orphaned`. |

While `running`, the `step` field is one of: `downloading`, `extracting`,
`filing`, `steam-sync`.

### Useful job fields (`--status --json`)

| Field | Meaning |
|---|---|
| `id` | Job id. |
| `kind` | `retrogametalk`, `torrent` (the PS2 fallback) or `telegram` (a bot torrent). |
| `status` | See the table above. |
| `step` | Current phase. |
| `progress` | 0 to 100. |
| `installedPaths` | Every file this job installed. |
| `vitaBuild` | `emu` or `console` for a PS Vita download. Empty otherwise. |
| `torrent` | Telegram jobs only: `hash`, `bot`, `command`, `savePath`, `platformFolder`, `file`, `tag`, `alreadyPresent`. |
| `manualNote` | Telegram jobs: what is still left to do by hand (install a `.cia`, a `.pkg`, ...). Empty when nothing is. |
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
Motrix (aria2 RPC)  ->  AB Download Manager  ->  aria2c  ->  curl  ->  BITS  ->  Invoke-WebRequest
```

- **Motrix** is used when its aria2 RPC answers (`motrixRpcUrl`).
- **AB Download Manager** is used when Motrix is not running (`abPort`, default
  15151). AB cannot report when a download finishes. So dlrom passes a filename
  and watches AB's folder (`abDownloadDir`, default `%USERPROFILE%\Downloads\ABDM`)
  until the file is done. Set `abDownloadDir` if you moved AB's folder.
  `abTimeoutSec` limits the wait.
- **curl** and **aria2c** are found by name on either platform (`curl` on Linux,
  `curl.exe` on Windows) and report progress by watching the output file grow.
- **BITS** and **Invoke-WebRequest** are Windows-only last resorts.

Every backend's output is checked before it is believed: a tier that reports success
without leaving a non-empty file is treated as a failure and the next one is tried. This is
not hypothetical — `Invoke-WebRequest` once returned cleanly after a 978 MB download that
left nothing on disk.

## Where ROMs are installed

dlrom picks the base folder in this order. The first one that works wins.

1. `--dest PATH`. An explicit override for this run.
2. `romsBase` from the config, if that folder exists. Its default is taken from EmuDeck's
   own settings (`%APPDATA%\EmuDeck\settings.ps1`, or `~/emudeck/settings.sh` on Linux), so
   it follows whichever drive you pointed EmuDeck at. With no EmuDeck installed it falls
   back to `<system drive>\Emulation\roms` on Windows and `~/Emulation/roms` on Linux.
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

## Telegram bots as a source

NSWTL runs one Telegram bot per console (`@PSVita_library_bot`, `@Switch_library_bot`, ...).
You message it a game name, it lists matches, and `/download<id>` returns a `.torrent`. dlrom
does that conversation for you through the [native Telegram client](#telegram-account-native-mtproto-client)
and hands the torrent to qBittorrent.

```
dlrom "Danganronpa" --platform vita --source telegram
dlrom "Mario Kart 8" --platform switch            # auto: Telegram-only console, straight to the bot
dlrom "Rayman 2" --platform ps2                   # auto: The Repo first, the PS2 bot if that fails
```

### How a run goes

1. Checks (before any message is sent): the Telegram session is logged in (`dlrom --telegram-login`,
   once) and qBittorrent's WebUI answers. dlrom does not start qBittorrent.
2. Sends the game name to the console's bot and waits for its result list. Only a message that
   looks like a result list, "nothing found", a subscription gate or a rate-limit notice counts
   as the answer; broadcasts and other chatter are ignored.
3. The bot pages long lists (12 entries per page, inline buttons). dlrom reads further pages only
   while no entry holds every word of your query, up to `telegramMaxPages`. `--interactive`
   reads all of them (up to the cap) so you can choose from the lot.
4. Picks one entry with the same scorer as The Repo: a base game over an edition or demo, then the
   fewest extra words. Updates and DLC are left out unless the query names them.
5. Sends `/download<id>`, saves the `.torrent` under `<data dir>/telegram/torrents/`, and adds it
   to qBittorrent with save path `<romsBase>\.dlrom-torrent\<folder>` and tags `dlrom` plus
   `dlrom-<jobId>`. qBittorrent starts it. A torrent qBittorrent already holds is left exactly as
   it is.
6. Records a job (`kind` `telegram`, `step` `downloading`) with the torrent hash, bot, command, save
   path, console folder and final destination, starts a detached worker for it and prints the usual
   spawn summary (or one JSON object with `--json`). With `--wait` the same worker runs in your
   terminal instead and the exit code is the outcome. `--dry-run` never gets this far.

### What the worker does

1. Connects to qBittorrent (it never launches it; if the WebUI is down the job fails with
   `qBittorrent is not reachable` and `--resume` retries it).
2. Waits for the whole torrent: progress and speed/ETA feed the job (`progress` 5 to 90, `step`
   `downloading`). Done means 100% in a completed state (seeding, queued, paused after finish).
   It fails on `error` or `missingFiles`, when the torrent is removed from qBittorrent, when no new
   bytes arrive for `telegramStallTimeoutSec` (`stalled: no progress for N min`) or at
   `telegramTorrentTimeoutSec` (`Timed out`). A stalled or timed-out torrent is left in qBittorrent.
   A torrent that is stopped/paused and incomplete when the wait starts is started once, if the job added it.
3. Files the content by console (table below), sets `extracting` / `filing`, adds the console folder to
   Steam (unless `--no-steam`, `steamSync` is off, or the console has no Steam parser; a failure is
   only a warning), and completes the job with `Installed`, or `Installed - manual step: <note>`.
4. If nothing could be installed the job fails with the reason, and the downloaded data stays in the
   staging folder (`.dlrom-torrent`); it is never deleted.

### Where each console's torrent is filed

Torrents come in every shape, so the layout is a rule per console folder (`TORRENT_INSTALL_RULES` in
`Constants.ps1`, strategies in `TorrentInstall.ps1`). Anything not listed (`nds`, `psx`, `ps2`, `psp`,
`gc`, `wii`, `dreamcast`, ...) uses the generic rule.

| Folder | Strategy | Result | Steam |
|---|---|---|---|
| `switch` | folder | A folder (base game, updates, DLC) moves whole to `switch\<Title>\`. A lone `.nsp`/`.xci`/`.nsz`/`.xcz` is filed flat in `switch\`. | yes |
| `n3ds` | files | `.3ds .cci .cxi .3dsx .app .cia`, flat in `n3ds\`. Archives inside are unpacked. A `.cia`-only torrent is filed with a note: install it in Azahar (File > Install CIA). | yes |
| `ps3` | gamedir | The shallowest folder holding `PS3_GAME` becomes `ps3\<Title>.ps3\`. With none but a `.pkg`/`.iso`: kept in `ps3\<Title>\` as a manual step (RPCS3 installs the `.pkg`). | yes (extracted game only) |
| `xbox360` | files | `.iso`/`.xex` flat in `xbox360\`. No such file but a folder (GOD/XBLA): `xbox360\xbla\<Title>\`. | yes |
| `xbox` | files | `.iso`, flat in `xbox\`. | yes |
| `wiiu` | files | `.wua .wux .wud .iso` flat in `wiiu\`. Otherwise the folder holding `code\*.rpx` goes to `wiiu\<Title>\`. | yes |
| `psvita` | manual | Kept in `psvita\<Title>\`. Note: NoNpDrm dump, install it in Vita3K or copy `app\<TITLEID>` to `ux0:app` on a Vita. | no |
| `ps4` | manual | Kept in `ps4\<Title>\`. Note: install the `.pkg` in shadPS4 and add a shortcut under `ps4\shortcuts`. | no |
| `ps5` | manual | Kept in `ps5\<Title>\`. Note: no emulator, kept for reference. | no |
| anything else | generic | One file or archive goes through the same filing as a web download (archives unpacked). A folder with one archive uses it; otherwise a `.cue` with its `.bin` files, or the largest ROM file. | yes |

`<Title>` is the bot's title with characters that break Steam launch commands removed. A destination
that already exists is never overwritten: the new one is named `<Title> (2)`, `(3)`, and so on. (The
generic rule shares the web pipeline's filing, which replaces a ROM file of the same name.)

Files left in the torrent that the rule does not take (notes, extra folders) stay in staging, which
`dlrom --clean` sweeps. Empty staging folders are removed after an install.

### Copy or move, and seeding

- A torrent **dlrom added**: the worker removes it from qBittorrent (data kept) and then moves the
  content into place (staging is on the ROM drive, so it is a rename). Nothing is left seeding.
- A torrent **qBittorrent already had** (`alreadyPresent`): the content is copied, the entry and its
  files are never touched, so it keeps seeding wherever you put it.

### Resuming a Telegram job

A worker that dies (reboot, killed), a torrent that stalls and a qBittorrent that is down all leave the
torrent in qBittorrent with the job `orphaned` or `failed`. Resuming starts a new worker that goes
back to waiting on the same torrent.

```
dlrom --resume a3f9c21b8e04        # one job (background)
dlrom --resume all                 # every eligible Telegram job
dlrom --resume a3f9c21b8e04 --wait # run it here
```

Eligible: `orphaned`, or `failed` with a stall, timeout or qBittorrent-down reason. Completed jobs and
other failures (nothing installable, torrent removed, qBittorrent error state) are refused.

**Auto-resume:** before any normal download (not `--status`, `--list`, `--clean`, `--resume`,
`--telegram-*`, `--dry-run`, and never inside a worker) dlrom restarts `orphaned` Telegram jobs in the
background and logs one line each. It reads job files only, so it costs nothing when there are none.
Failed jobs are not auto-resumed. Turn it off with `telegramAutoResume: false`. Jobs written before
workers existed (status `running` with no worker) read as `orphaned` and are picked up the same way.

`dlrom --clean` keeps the staging folder of running, orphaned and resumable-failed Telegram jobs; a
completed job's or a hopelessly failed job's leftovers are fair game.

### What the bots say

| Reply | Handled as |
|---|---|
| `Found torrents: N` (also `Found torrents for you: N`, `Found games: N`) | a result list; `N` counts all pages |
| `Found torrents: 0` / "No torrents found for your query" | nothing found: exit 1, no fallback left |
| inline buttons `-1- 2 3 ...` | pages of 12; the bot edits the same message when one is pressed |
| a message with a `.torrent` document | the answer to `/download<id>` |
| "subscribe to our channel", "too many requests" | reported with the bot's own words (the exact texts have not been seen yet, so these are matched loosely) |

The bots do not share one layout. Three have been seen (`Title [size]`, a multi-line
`Title / Size: / Download:` block on Switch, and a size-less `/rate` form on 3DS) and the parser
reads all of them. Search is fuzzy: "Halo 3" on Xbox 360 returns "Halo -Reach". A title the bot
cuts with `...` is flagged and the pick is made on the visible part. Several entries can share a
title with different sizes (a full dump and a PSN pack); the first one wins a tie.

### Notes

- **PS Vita**: the bot's torrents are NoNpDrm (console) builds. `--vita emu` still proceeds, with a
  warning; the job records `vitaBuild: console`.
- **PS2 with `auto`**: the Redump torrent fallback runs first. In the default background mode it
  takes over the request, so the Telegram bot is only tried after it with `--wait`.
- Messages are sent at a human pace (`telegramMinSendGapSec`) and never repeated.
- Errors that name a login problem point at `dlrom --telegram-login`.

### Telegram source config keys

| Key | Meaning |
|---|---|
| `telegramBots` | Object mapping a platform (any alias: `vita`, `ps4`, `switch`, `ps1`) to a bot username, `@` optional. Overrides the built-in table, which NSWTL may outgrow; a missing key falls back to the built-in bot. |
| `telegramReplyTimeoutSec` | How long to wait for a bot's answer. Default `30`. |
| `telegramFallback` | In `auto`, retry a failed RetroGameTalk search on Telegram. Default `true`. |
| `telegramMinSendGapSec` | Minimum gap between messages (and button presses) sent to a bot. Default `3`. |
| `telegramMaxPages` | Result pages read per search. Default `4`. |
| `telegramTorrentTimeoutSec` | Overall wait for a Telegram torrent to finish. Default `86400`. |
| `telegramStallTimeoutSec` | Fail a torrent that gains no bytes for this long. Default `3600`. |
| `telegramAutoResume` | Restart orphaned Telegram jobs before a normal download. Default `true`. |
| `qbitHost` / `qbitUser` / `qbitPass` | The qBittorrent WebUI, as for the PS2 fallback. |

Built-in bots: `switch` Switch_library_bot, `3ds` N3DS_library_bot, `nds` NDS_library_bot, `psx`
PSX_library_bot, `ps2` PS2_libr_bot, `ps3` PS3_libr_bot, `ps4` PS4_libr_bot, `ps5` PS5_libr_bot,
`psp` PSP_libr_bot, `vita` PSVita_library_bot, `wii` and `wiiu` Wii_library_bot, `gamecube`
Gamecube_library_bot, `dreamcast` Dreamcast_library_bot, `xbox360` Xbox360_library_bot, `xbox`
Xbox_library_bot. All resolve on Telegram; searches have been sent to the Vita, Switch, PS3, PS4,
3DS and Xbox 360 bots.
## Telegram account (native MTProto client)

`lib/Telegram/` is a Telegram user-account client written in PowerShell on the .NET BCL alone
(no TDLib, Telethon or packages). It is what the Telegram bot source talks through; the flags
below only manage the login.

1. Create an app at https://my.telegram.org and put the values in `config.json` under `[rom]`
   (`telegramApiId`, `telegramApiHash`), or set `TG_API_ID` / `TG_API_HASH` (these win).
2. Log in in two steps, so an agent without a terminal can do it:

```
dlrom --telegram-login --phone +27821234567     # sends the code, prints "code sent"
dlrom --telegram-login --code 12345             # signs in
dlrom --telegram-login --password <2FA>         # only if 2FA is on (or set TG_2FA_PASSWORD)
dlrom --telegram-login                          # interactive host: prompts for each
dlrom --telegram-status [--json]                # who is logged in
dlrom --telegram-logout                         # auth.logOut and delete the session
```

Exit codes: 0 ok, 1 error, 2 not logged in (status), 3 more input needed (code sent / password
needed). The session (auth keys, user id) lives in `<data dir>/telegram/session.json`, readable
by the current user only; it is the account, so never share it. The bundled TL schema
(`lib/Telegram/schema/`) is layer 233; see its README for the pinned commit.

## Steam ROM Manager

After a ROM is installed, dlrom adds it to Steam through Steam ROM Manager (SRM).
It never writes a Steam shortcut itself. That means running SRM later updates
things instead of creating duplicates.

dlrom prefers the standalone `srm-wrapper` CLI if it is on `PATH`, or set
`srmWrapperCmd`. If the wrapper is missing or fails, dlrom uses its built-in
driver:

1. Find `srm.exe` (`srmExe`, else EmuDeck's `toolsPath`, else `<system drive>\Emulation\tools\srm.exe`, else `PATH`).
2. If `srmEnableParser` is on, enable any disabled SRM parser pointing at the
   destination folder.
3. Follow `srmRestartSteam`: `auto` restarts Steam only if it is running, `never`
   never does, `always` always does.
4. Run `srm add` quietly, then restart Steam if it was closed.

If neither the wrapper nor `srm.exe` is found, dlrom does not crash. It logs where
the ROM was saved.

### Steam Deck: Game Mode

SRM cannot write the Steam library from inside Game Mode — Steam *is* the session there, and
adding while it runs silently drops categories. dlrom handles that itself rather than asking
you to switch:

1. The ROM **downloads in Game Mode**. Nothing is interrupted.
2. For the Steam step only, it drops to the desktop (`steamos-session-select plasma` — the
   one-shot session, so it does not change what the Deck boots into).
3. It runs SRM.
4. It **returns to Game Mode**, including when the sync failed.

The desktop is borrowed for roughly a minute, at the end, and never for the length of the
download. Measured end to end from an agent request: ~56s for a platform already in your
library, ~2m45s the first time a platform's parser has to be enabled.

**Leaving Game Mode closes a running game.** Use `--no-steam` to download without touching the
session, then `dlrom --sync-steam` when you are done playing.

If the session will not switch, the sync is queued instead (`srmDeferInGameMode`) and drains
on the next `--sync-steam`. Set `srmAutoSwitchSession` to `false` to always queue rather than
switch.

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
    "vitaBuild": "emu",
    "jobKeepDays": 7
  }
}
```

| Key | Default | What it does |
|-----|---------|--------------|
| `romsBase` | EmuDeck's `romsPath` | Where ROMs go. Used when the folder exists. Falls back to `<system drive>\Emulation\roms`. |
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
| `srmAutoSwitchSession` | `true` | Steam Deck: in Game Mode, drop to the desktop for the Steam step and return. |
| `srmReturnToGameMode` | `true` | Steam Deck: go back to Game Mode after `--sync-steam`. |
| `srmDeferInGameMode` | `true` | Steam Deck: queue the Steam step if the session will not switch. |
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
.\dlrom\Add-ROM.ps1 -Resume <jobId|all> [-Wait] [-Json]
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
| `QbitTorrent.ps1` | qBittorrent WebUI client, used by the PS2 torrent fallback and, for whole torrents, by the Telegram worker. |
| `TorrentInstall.ps1` | The per-console rules and strategies that file a finished Telegram torrent. Pure filesystem. |
| `TelegramJob.ps1` | The Telegram worker (wait, install, Steam), `--resume` and auto-resume. |
| `Ps2TorrentIndex.ps1` + `ps2_torrent.py` | PS2 torrent fallback: match, download one file, install. |
| `Ps2Serial.ps1` | PS2 serial lookup and the result block with the `[HANDOFF]` line. |

## Troubleshooting

| Problem | What to do |
|---|---|
| Search fails | Run `dlrom "..." --dry-run --verbose` to see the request and the reason. |
| No download links found | dlrom saves the page to `%TEMP%\dlrom-debug.html`. A `403` from the reveal endpoint would mean the site started gating The Repo server-side. |
| An AB download never finishes | Set `abDownloadDir` to AB's real folder. Raise `abTimeoutSec`. |
| ROM lands in `\roms` instead of a console folder | Pass `--platform`. The console could not be guessed from the search result. |
| A job says `orphaned` | Its worker died without recording an outcome. Nothing is running. Check the job's `logFile` to see how far it got, then run it again. A Telegram job: `dlrom --resume <id>` (the next download also does it for you). |
| A Telegram job failed with `stalled` or `qBittorrent is not reachable` | The torrent is still in qBittorrent. Fix the swarm or start qBittorrent, then `dlrom --resume <id>`. |
| A Telegram job failed with "No ... files found" | The rule for that console found nothing it can file. The data is still in `<romsBase>\.dlrom-torrent`; install it by hand. |
| A job sits at the same percentage | The download backend is retrying. aria2 and Motrix retry an unreachable host for a long time before giving up. `dlrom --status <id>` shows the last log lines. |
| `Cannot resolve a ROMs base directory` | dlrom refuses to prompt when nothing can answer. Pass `--dest`, set `romsBase` in the config, connect a drive with a `rom_path`, or re-run with `--interactive`. |
| A Vita game will not load in Vita3K | Check the job's `vitaBuild`. If it says `console`, the game had no Vita3K build and you have a NoNpDrm dump to convert. |
| A Vita download arrived as a `.zip` | That is correct for a Vita3K build. The emulator installs the archive itself. Use `--vita console` if you wanted the hardware dump. |
