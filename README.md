# dl-scripts

Five PowerShell scripts that search for media, download it, and put it where it
belongs.

Runs on **Windows and Linux**, including the **Steam Deck**.

| Script | Downloads | From | Using |
|--------|-----------|------|-------|
| [dlanime](dlanime/) | Anime series and films | nyaa.si | qBittorrent |
| [dlgame](dlgame/) | PC games | appnetica.com | qBittorrent |
| [dlmovie](dlmovie/) | Movies | YTS | qBittorrent |
| [dltv](dltv/) | TV shows | The Pirate Bay | qBittorrent |
| [dlrom](dlrom/) | Console ROMs | retrogametalk.com/repo | Motrix, AB, aria2c, curl, BITS, or PowerShell |

`dlrom` does more than download. It unpacks the ROM, installs it into the right
emulator folder, and adds it to Steam.

## Setup

### Windows

Requires Windows PowerShell 5.1 (built in) or PowerShell 7.

1. Add this repo's root folder to `PATH`.
2. Run any script from any terminal - `dlrom`, `dlgame`, and so on resolve to the
   `.cmd` wrappers.

### Linux and Steam Deck

Requires **PowerShell 7**. On an immutable OS like SteamOS there is nothing to install
system-wide - extract the tarball into your home directory:

```sh
mkdir -p ~/.local/pwsh
curl -sL https://github.com/PowerShell/PowerShell/releases/latest/download/powershell-linux-x64.tar.gz \
  | tar zx -C ~/.local/pwsh
```

Then add this repo's **`bin/`** folder to `PATH` (not the root - the root holds
directories named `dlrom`, `dlgame` and so on, which would shadow the launchers):

```sh
export PATH="$PATH:/path/to/dl-scripts/bin"
```

Paths follow each platform's conventions with no configuration: `%LOCALAPPDATA%\dlScripts`
on Windows, `~/.config/dlScripts` and `~/.local/share/dlScripts` on Linux. On a Steam Deck,
`dlrom` reads EmuDeck's own `settings.sh`, so ROMs land wherever EmuDeck was pointed -
usually the SD card - without you configuring anything.

### Steam Deck: Game Mode

Downloads work normally in Game Mode. The **Steam ROM Manager step does not** - in Game
Mode Steam *is* the session, so it cannot be shut down, and SRM would add the shortcut but
silently drop its categories.

So `dlrom` queues that step instead of running it, and applies it when you next enter
Desktop Mode:

```sh
dlrom --steam-queue      # what is waiting
dlrom --sync-steam       # apply it now (refuses while Game Mode is active)

bin/dlrom-install-autostart   # apply it automatically on Desktop Mode login
```

```
dlanime "Frieren" series
dlgame "Spider-Man"
dlmovie "Inception"
dltv "Breaking Bad"
dlrom "Zelda" --platform n64
dlrom "Danganronpa V3" --platform vita
```

Config is created for you at `%LOCALAPPDATA%\dlScripts\config.json` on first run.
There is no manual setup step.

Each subfolder has its own `README.md` with the full options list.

## The main rule: nothing waits for a download

Every script returns as soon as the download is handed off. None of them sit and
wait for gigabytes to arrive.

This matters when the caller is a script, a scheduled task, or an AI agent.

| Script | Returns when | Check progress with |
|--------|--------------|---------------------|
| `dlanime`, `dlgame`, `dlmovie`, `dltv` | the torrent is queued in qBittorrent | qBittorrent's web page on `:8075` |
| `dlrom` | the links are found and a worker has started | `dlrom --status <jobId>` or `dlrom --list` |

The four torrent scripts hand the file to qBittorrent. qBittorrent owns the
download and is where you watch it. They need no job system of their own.

`dlrom` downloads over HTTP itself. So it runs its own background worker and
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

Use `--wait` on `dlrom` only when you want to sit and watch a progress bar.

**No script prompts you unless you ask.** Use `--interactive` to pick from a list.
Without it, they choose the best match and continue. A run with no console
attached never stops to ask a question. It fails with an explanation instead.

## Testing without downloading

Add `-DryRun` to see what a script would do:

```
dlmovie "Inception" -DryRun
dltv "Breaking Bad" -DryRun
dlanime "Frieren" series -DryRun
dlgame "Spider-Man" -DryRun
dlrom "Crash Bandicoot" --links-only     # dlrom's version of the same idea
```

## Requirements

- **Windows** with PowerShell 5.1 or newer. This is built into Windows 10 and 11.
- **qBittorrent** with the Web UI enabled, for `dlanime`, `dlgame`, `dlmovie` and
  `dltv`.
- **7-Zip**, for `dlrom` to unpack archives.

Optional for `dlrom`: Motrix or AB Download Manager (faster, resumable downloads),
Steam ROM Manager (the Steam step), and Python 3 (only to rebuild the PS2 torrent
index). See [`dlrom/README.md`](dlrom/).

Nothing is hardcoded to one machine. Paths come from `config.json`, from live
drive detection, or from command-line options. The scripts work on a fresh setup.

## Config

Settings live in `%LOCALAPPDATA%\dlScripts\config.json`, one section per script:

```json
{
  "anime":  { "qbitHost": "...", "seriesDestination": "...", "moviesDestination": "...", "maxResults": 75, "autoAppendDualAudio": true, "preferredUploaders": ["judas", "..."], "useDriveMetadata": true },
  "movie":  { "qbitHost": "...", "destination": "...", "maxResults": 15, "useDriveMetadata": true },
  "tv":     { "qbitHost": "...", "destination": "...", "maxResults": 50, "useDriveMetadata": true },
  "game":   { "qbitHost": "...", "destination": "...", "maxResults": 10, "useDriveMetadata": true },
  "rom":    { "romsBase": "G:\\Emulation\\roms", "tempDir": "%TEMP%\\dlrom", "motrixRpcUrl": "http://localhost:16800/jsonrpc", "maxResults": 10, "pollIntervalMs": 2000, "steamSync": true, "srmExe": "", "srmRestartSteam": "auto", "srmEnableParser": true, "srmWrapperCmd": "", "abPort": 15151, "abDownloadDir": "", "abTimeoutSec": 1800, "vitaBuild": "emu", "jobKeepDays": 7 }
}
```

Each script sets itself up. If the file or its section is missing, it is created
with defaults and the run continues. Nothing crashes. New keys are added to
existing sections automatically on the next run.

**`useDriveMetadata`** defaults to `true`. When true, the destination is chosen at
runtime from the connected drives. Set it to `false` to always use the
`destination` field instead.

**Credentials:** only `dlgame` needs any. They go in a `.settings` file in the
`dlgame/` folder, which is gitignored. `dlrom` needs no account at all.

## Where files are saved

A separate service called **[drive-registry](../drive-registry)** picks the
destination drive. These scripts do not choose drives themselves.

That service keeps a central drive policy, writes a `drive-meta.json` onto each
connected drive, and answers "where should this media type go?".

It is a local HTTP API on `127.0.0.1`. Production uses port `9600`, dev uses
`9601`. `lib\DriveResolver.ps1` is a thin client for it.

The address is read from `DRIVE_REGISTRY_URL`, then a `driveRegistryUrl` key in
`config.json`, then the default `http://127.0.0.1:9600`.

**The service is optional.** If it is not running, or not installed, the scripts
do not fail. Each one falls back to a safe default:

1. Its configured `destination`.
2. A folder in your home directory: `~/Movies`, `~/TV`, `~/Games`,
   `~/Anime\Series`, `~/Anime\Movies`, or `~/Emulation\roms`.

A `WARN` line tells you the fallback happened.

### How a drive is chosen

The service reads its `policy.json`. For each drive that file says which media
types it accepts, with a priority. Higher priority wins. A drive can be marked
`last_resort`.

For one media type:
1. Only drives that advertise a path for that type are considered.
2. They are ranked: non-last-resort first, then priority, then free space.

Unplugged drives are simply absent. So a torrent is never sent to a dead path.

See the drive-registry repo for the policy format.

To see all connected drives and their picks:

```
powershell -File lib\DriveResolver.ps1
```

## dlrom in brief

`dlrom` has the most moving parts. Full detail is in
[`dlrom/README.md`](dlrom/). The short version:

**Where the ROM goes.** In this order, first match wins:

1. `--dest PATH`, an override for this run.
2. `romsBase` from the config, if that folder exists.
3. The drive-registry API.
4. Asking you, but only with `--interactive`.

The ROM is filed under `<romsBase>\<console>`. Folder names follow EmuDeck's
layout, so PS1 becomes `psx`, GameCube becomes `gc`, Master System becomes
`mastersystem`, and Vita becomes `psvita`. Both the emulators and Steam ROM
Manager expect those names.

Without `--platform`, the console is taken from the search result. So a bare
`dlrom "Game"` still lands in the right folder, not a generic `\roms`.

**Unpacking.** Real archives (zip, 7z, rar, detected by file signature) are
unpacked. A raw ROM download is installed as-is instead of failing.

**PS Vita has two versions of every game.** `[Vita3K]` is for the emulator.
`[NoNpDrm]` is for a modded console. They are not interchangeable, and picking
wrong fails silently: it installs fine, then will not run.

dlrom takes the Vita3K build by default and keeps it as a `.zip`, because the
emulator imports the archive itself. Use `--vita console` for real hardware. If a
game has only one build, dlrom warns and takes it. The keep-it-zipped rule follows
the file actually chosen, not what you asked for.

**Steam.** After installing, dlrom adds the ROM through Steam ROM Manager. It
never writes a Steam shortcut itself, so running SRM later updates rather than
duplicating. If SRM is not installed, dlrom logs where the ROM went and carries
on. Skip it for one run with `--no-steam`.

**Freeing space.** Downloads clean up after themselves. But a worker that is
*killed* (reboot, task manager, power cut) cannot. `dlrom --clean` sweeps up:

```
dlrom --clean             # temp files, abandoned part-files, caches
dlrom --clean --dry-run   # preview only
dlrom --clean --all       # also clear finished job records
```

It never deletes a file a running job is using, and never touches your download
manager's folder or `~\Downloads`.

**No account needed.** The Repo shows a members-only message, but only in the
browser. A script never runs that JavaScript. dlrom has no login and stores no
credentials.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the repo layout and conventions.

## License

[MIT](LICENSE).

## Disclaimer

These scripts automate downloads from third-party sites. Use them only for content
you are legally entitled to, such as personal backups of media you own. You are
responsible for following the laws where you live and the terms of the sites
involved.

---

# Notes for AI agents

This section is for AI agents working in this repo or calling these scripts.
Everything above still applies. This adds the rules that matter most to you.

## Rule 1: never wait for a download

Start the command. Report the result. Stop.

| Never do this | Why |
|---|---|
| Pass `--wait` to `dlrom` | It blocks until the download finishes. It exists for humans watching a progress bar. |
| Pass `--interactive` to anything | It waits for a keypress you cannot send. |
| Sleep, or poll in a loop | The download runs on its own. Polling wastes the user's time. |
| Re-run a command to check on it | That starts a second download. |

These files take minutes to hours. A blocked call means the user cannot talk to
you until it ends.

For the four torrent scripts, "added to qBittorrent" **is** the finished result.
Report it and stop.

For `dlrom`, the Job ID block **is** success. Report the Job ID and stop. Check
later with `dlrom --status <jobId>` only when the user asks.

## Rule 2: pick the right script

Decide series or film before calling `dlanime`. TV anime and OVAs are `series`.
A standalone anime film is `movie`. This picks the save folder.

Always pass `--platform` to `dlrom`. Only leave it out if nothing was found.

## Rule 3: read the job state before reporting

| Status | What to tell the user |
|---|---|
| `pending` | It is starting. |
| `running` | Give the percent and the `step`. |
| `completed` | It finished. |
| `failed` | Read the `message` field and say why. |
| `orphaned` | The worker died. Nothing is running. Offer to run it again. |

If a job is `failed` or `orphaned`, do not keep checking it.

## File layout

```
dl-scripts/
├── dlanime.cmd              ← run this (on PATH)
├── dlgame.cmd
├── dlmovie.cmd
├── dltv.cmd
├── dlrom.cmd
├── lib/
│   └── DriveResolver.ps1    ← shared: config setup + drive-registry API client
├── dlanime/
│   ├── Add-Anime.ps1        ← the actual logic
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
    ├── Constants.ps1        ← shared values (job names, extensions, regions, Vita markers)
    ├── Common.ps1           ← shared helpers (config, timestamps, region and Vita ranking)
    ├── Add-ROM.ps1          ← orchestrator + worker entry point (-JobFile)
    ├── Jobs.ps1             ← job state, starting the worker, --status and --list
    ├── Clean.ps1            ← --clean, and the rule that protects live jobs
    ├── RomPipeline.ps1      ← download, unpack, install, Steam (worker and --wait share it)
    ├── Logging.ps1          ← Write-Log, progress lines, formatters
    ├── RetroGameTalk.ps1    ← search and link discovery
    ├── Downloaders.ps1      ← download backends and dispatcher
    ├── RomFiles.ps1         ← unpacking and ROM install
    ├── SteamRomManager.ps1  ← Steam ROM Manager sync
    ├── QbitTorrent.ps1      ← qBittorrent client (PS2 torrent fallback)
    ├── Ps2TorrentIndex.ps1  ← PS2 torrent fallback
    ├── ps2_torrent.py       ← torrent index parser (Python helper)
    ├── Ps2Serial.ps1        ← PS2 serial lookup and the [HANDOFF] line
    ├── tests/               ← Pester suites and fixtures
    └── README.md
```

`dlrom` is split into modules that `Add-ROM.ps1` loads. The other four tools are
each a single file.

## How the CMD wrappers behave

- They use `%~dp0` to find the `.ps1` next to them. So the scripts work from any
  directory, whatever PATH says.
- They call PowerShell with `-NoProfile`. The user's profile is irrelevant here,
  and loading it is slow and adds noise to stdout.
- **The `.cmd` files must keep CRLF line endings.** `.gitattributes` enforces
  this. `cmd.exe` finds a `goto` label by jumping to a byte offset. With LF-only
  endings that jump lands mid-line once the file grows, and the label is reported
  "not found". The failure is silent and depends on file length, so it shows up as
  one subcommand breaking after an unrelated edit made the file longer.

### What each wrapper accepts

- `dlanime.cmd`: `"Query" [series|movie] [destination] [--list]`. `--list` can go
  anywhere.
- `dlgame.cmd`, `dlmovie.cmd`, `dltv.cmd`: `"Query" [destination]`.
- **All four also forward flags.** Any argument starting with `-` goes straight to
  the `.ps1`. Examples: `-DryRun`, `-Interactive`, `-MaxResults 20`,
  `-TrustedOnly`. The first bare word after the query is still the destination.
- `dlrom.cmd`: `"Query"` plus the options listed in
  [`dlrom/README.md`](dlrom/#flags). It also takes the subcommands `--status`,
  `--list` and `--clean`. Those are matched before `%1` is treated as a game name,
  because none of them carry one.

## How dlrom's background worker starts

The worker is the same `Add-ROM.ps1`, re-run with `-JobFile <path>`.

Job state and logs go to `%LOCALAPPDATA%\dlScripts\jobs\rom\<id>.json` and
`<id>.log`. Read the JSON directly if `--status --json` is inconvenient.

The worker starts through raw `ProcessStartInfo` with `CreateNoWindow` and
`UseShellExecute=$false`, and `cmd` redirects its output to the log file. Two
details are load-bearing:

1. PowerShell's `Start-Process` cannot set `CreateNoWindow`, so it flashes a
   console window.
2. The worker must not inherit the caller's console handles. If it does,
   `dlrom.cmd` stays tied to the worker and the caller's terminal hangs. Avoiding
   that is the entire reason this design exists.

The worker's stdin is redirected and closed. So a stray prompt hits end-of-file
and fails fast instead of blocking forever.

Finished jobs are deleted after `jobKeepDays` (default 7). Running jobs are never
deleted. `--wait` runs the identical pipeline in the foreground and still writes a
job file, so the two modes cannot drift apart.

## When editing scripts

- Logic goes in the `.ps1` files. The `.cmd` files only parse arguments and call
  PowerShell.
- `Initialize-DlConfig` lives in `lib\DriveResolver.ps1` and is loaded by each
  script.
- `Resolve-MediaPath` (same file) is only a client for the drive-registry API. It
  does no drive scanning or ranking. To change how drives are ranked, or to add a
  drive, edit the [drive-registry](../drive-registry) policy, not these scripts.
- All scripts log through `Write-Log` with the levels `INFO`, `SUCCESS`, `WARN`,
  `ERROR` and `DEBUG`. In `dlrom`, `DEBUG` is hidden unless you pass `--verbose`,
  and `--quiet` hides routine `INFO`.
