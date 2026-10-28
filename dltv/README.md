# dltv

Downloads TV shows from two sources:

| Source | Good for | How it downloads | Returns when |
|--------|----------|------------------|--------------|
| [The Pirate Bay](https://thepiratebay.org) (default) | Western TV, well-seeded packs | Magnet to qBittorrent | The torrent is queued |
| [KissKH](https://kisskh.co) | K-drama, C-drama, Thai and other Asian series, with English subtitles | Direct HTTP in a background job | A Job ID is printed |

Regional shows are archived but rarely seeded, so their torrents often sit at 0-2 seeds.
KissKH streams almost all of them. dltv uses it in two ways:

- **`--asian`** goes straight to KissKH and never touches TPB.
- **Automatic fallback:** when the torrent dltv would pick has fewer than `minSeeders` seeds
  (default 5), or there is no torrent at all, dltv checks KissKH for an **exact** title
  match and downloads from there instead. Without an exact match it keeps the torrent.

## Command

```
dltv "Show Name" [destination] [flags]
dltv --jobs
dltv --status <jobId>
```

Add the repo root to `PATH` and call it from any terminal. Quotes are required when the name contains spaces.

## Usage Examples

```
dltv "Breaking Bad"                       # TPB torrent
dltv "Bad Buddy"                          # TPB is weak, falls back to KissKH
dltv "Queen of Tears" --asian             # KissKH only
dltv "Queen of Tears" --asian --episodes 1-4
dltv "Hidden Love" --asian --dry-run      # show what KissKH has, download nothing
dltv --status 4dbce0bc1c34
```

The second positional argument is an optional destination override. Omit it to use the path from config.

## Flags

| Flag | What it does |
|------|--------------|
| `--dry-run` | Search, print what it would download, then stop. Nothing is queued or spawned. On the KissKH path it makes one stream lookup to estimate the size. |
| `--list` | Same as `--dry-run`. |
| `--interactive` | Pick from the results yourself. Needs a person at the keyboard. Disables the automatic fallback. |
| `--max-results N` | Cap how many torrent results are considered. |
| `--dest PATH` | Override the destination. |
| `--qbit-host URL` | Override the qBittorrent WebUI URL. |
| `--asian` | Use KissKH only. Exits 1 if KissKH has no match. |
| `--episodes RANGE` | KissKH only: `3`, `1-4`, or `5-` (5 to the end). Default: every released episode. |
| `--jobs` | List KissKH download jobs. |
| `--status ID` | Show one job: progress, GB done of total, speed, ETA, current episode, drive, and the log tail. |
| `--json` | With `--status` or `--jobs`: print only JSON, for scripts and agents. |
| `--help` | Print usage and exit. |

The same spellings work on every `dl*` command. An unknown `--flag` is rejected rather than ignored, so a typo cannot turn a preview into a download.

## PowerShell Parameters

The CMD wrapper passes these through. You can also call the script directly:

```powershell
.\dltv\Add-TV.ps1 -Query "Bad Buddy" [-Destination "path"] [-Asian] [-Episodes "1-4"] [-DryRun] [-Interactive]
.\dltv\Add-TV.ps1 -Jobs
.\dltv\Add-TV.ps1 -Status <jobId>
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Query` | - | Show name. Required unless `-Jobs` or `-Status` is given |
| `-Destination` | from config | Download root |
| `-QbitHost` | from config | qBittorrent WebUI URL |
| `-MaxResults` | from config | Max torrent results to consider |
| `-Interactive` | `$false` | Pick from the results by hand |
| `-DryRun` | `$false` | Preview only |
| `-Asian` | `$false` | KissKH only |
| `-Episodes` | all | KissKH episode range |
| `-Jobs` / `-Status` | - | Inspect background jobs |
| `-Json` | `$false` | Machine-readable output for `-Jobs` / `-Status` |
| `-JobFile` | - | Internal: the background worker's entry point |

## Configuration

Settings live in the `tv` section of `%LOCALAPPDATA%\dlScripts\config.json` (`~/.config/dlScripts/config.json` on Linux). Missing keys are added with their defaults on the next run.

```json
{
  "tv": {
    "qbitHost": "http://localhost:8080",
    "destination": "C:\\Users\\you\\TV",
    "maxResults": 50,
    "useDriveMetadata": true,
    "minSeeders": 5,
    "kisskhFallback": true,
    "kisskhBaseUrl": "https://kisskh.co",
    "kisskhSubLangs": ["en"],
    "kisskhMaxEpisodeGB": 8,
    "jobKeepDays": 7
  }
}
```

| Key | Meaning |
|-----|---------|
| `minSeeders` | A torrent pick below this falls back to KissKH |
| `kisskhFallback` | `false` turns the automatic fallback off (`--asian` still works) |
| `kisskhBaseUrl` | KissKH mirror to use. Change it if the domain moves |
| `kisskhSubLangs` | Subtitle languages to save, by KissKH's language code (`en`, `ar`, `km`, ...) |
| `kisskhMaxEpisodeGB` | Safety cap: an episode whose download passes this is aborted and its partial file deleted |
| `jobKeepDays` | Finished job records older than this are pruned |

## How It Works

### Torrent path

1. Queries the Pirate Bay API (apibay.org) in the TV category.
2. Drops anything that fails the safety filters (below).
3. Scores the rest and takes the top result, or lets you pick with `--interactive`.
4. If that pick is weak, tries the KissKH fallback (see above).
5. Sends the magnet to qBittorrent with the configured save path.

### KissKH path

1. Searches KissKH and picks the best title match. The fallback only accepts an exact
   match; `--asian` also accepts "title starts with the query" and "all words present".
2. Lists the drama's episodes. Recaps and specials (fractional numbers such as 16.1) are skipped.
3. Estimates the size from the first episode, then prints a summary and returns with the Job ID:

   ```
   [SUCCESS] Background job started: Crazy Love (2022) (16 episodes)
     Title:    Crazy Love (2022)
     Country:  South Korea
     Status:   Completed
     Episodes: 16 (E01-E16)
     Size:     ~10.41 GB (est. from E02: 710 MB)
     Folder:   D:\TV\Crazy Love (2022)
     Drive:    D: (asmedia-4tb-hdd), 1342.4 GB free
     Source:   KissKH direct download (no seeders)
     Job ID:   ed70bdb6a463
   ```

4. The detached worker first scans every episode for its size, so the total becomes
   exact and unreleased episodes are known up front. Then it downloads each episode in order:
   - asks KissKH for a signed stream URL (generated just in time, because it is tied to your IP)
   - downloads the `.mp4` with curl, resuming a partial `.part` file. An HLS (`.m3u8`)
     stream is fetched and remuxed to `.mp4` by ffmpeg when it is installed, otherwise kept
     as `.ts`. KissKH usually serves HLS as byte ranges of one or two whole files; those
     files are downloaded once each, resumably, not range by range
   - saves and decrypts the subtitles as `.srt`

   Every transfer gives up and retries after 60 s under 1 KB/s, so a dead connection
   cannot hang the job, and `kisskhMaxEpisodeGB` stops a runaway episode.

Files land as:

```
<destination>\<Title>\<Title> S01E01.mp4
<destination>\<Title>\<Title> S01E01.en.srt
```

A re-run skips episodes whose `.mp4` already exists, so it resumes an interrupted job.
An episode that is not out yet is skipped and listed as "not released" in the job message.
One failed episode does not stop the rest. A job ends `failed` only if no episode succeeded.

### Job status

| Status | Meaning |
|--------|---------|
| `pending` | Starting |
| `running` | Downloading; `--status` shows the current episode and `done/total` |
| `completed` | At least one episode downloaded; the message lists any failures |
| `failed` | Nothing downloaded; the message says why |
| `orphaned` | The worker died (reboot, killed). Run the same command again to resume |

`dltv --status <id>` while a job runs:

```
Job c22cba354f6a
  Status:     running
  Title:      Crazy Love (2022) (South Korea)
  Progress:   20.0%  178 MB of 851 MB
  Episodes:   0/1 (current E01 at 20%)
  Speed:      3.3 MB/s
  ETA:        3m
  Folder:     D:\TV\Crazy Love (2022)
  Drive:      D: (asmedia-4tb-hdd), 1342.4 GB free
  Source:     KissKH direct download (no seeders)
  ...
```

`dltv --status <id> --json` (and `dltv --jobs --json`, always an array) prints the same as
JSON. The field names follow qBittorrent's `torrents/info` where one exists:

| Field | Meaning |
|-------|---------|
| `name`, `country`, `showStatus` | The show |
| `status` | `pending`, `running`, `completed`, `failed`, `orphaned` |
| `progress` | 0 to 1 |
| `doneBytes`, `totalBytes`, `doneGB`, `totalGB` | Transferred so far, and the total (`sizeExact` false while part of it is an estimate) |
| `dlspeed`, `speedMBps` | Current speed, a 10 s moving average (bytes/s, MB/s) |
| `eta` | Seconds left, or null |
| `episodesDone`, `episodesTotal`, `currentEpisode`, `currentEpisodeProgress` | Episode view |
| `savePath`, `drive`, `driveName`, `freeGB` | Where it lands |
| `failed`, `notReleased`, `message` | Outcome detail |

Read progress from `--status`, not from the folder. Windows reports a stale size for a file
that another process still has open, so Explorer or `Get-ChildItem` can show a download as
stuck while it is still growing.

Job files and logs live in `%LOCALAPPDATA%\dlScripts\dltv\jobs\` (`~/.local/share/dlScripts/dltv/jobs/` on Linux).

## Scoring System (torrents)

| Condition | Points |
|-----------|--------|
| Complete series (all seasons) | +2000 |
| Complete season pack | +1800 |
| Season pack (no episode number) | +1500 |
| Single episode | -800 |
| 4K / 2160p | +300 |
| 1080p | +200 |
| 720p | +100 |
| BluRay source | +150 |
| WEB-DL source | +120 |
| WEBRip / streaming source | +80 |
| Base: seeder count | - |

## Safety Filters (torrents)

Any torrent whose name matches one of these is rejected before scoring:

- Executable or script extensions: `.exe`, `.bat`, `.ps1`, `.cmd`, `.vbs`, `.js`, `.jar`, `.py`, `.sh`, `.dll`, `.scr`, `.pif`, `.hta`, `.wsf`, `.com`
- Archive extensions: `.rar`, `.zip`, `.7z`, `.tar`, `.gz`, `.bz2`, `.xz`, `.zst`, `.cab`
- Game keywords: CODEX, FitGirl, GOG, Steam, Xbox, PlayStation, SKIDROW, RELOADED, RG Mechanics, etc.
- Software keywords: Keygen, Activator, Cracked, Installer, Portable, Serial Key, License Key, Full Version, etc.
- Book keywords: epub, audiobook, Manga, PDF, mobi, azw3, comic, etc.

## When KissKH stops working

Everything KissKH-specific is in `dltv/KissKH.ps1`, and every value the request signing
depends on sits in the constants block at the top. Common breakages:

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Search fails or times out | Domain moved | Set `kisskhBaseUrl` to the current mirror |
| Search works, every episode fails or shows "not released" | Site bumped its app version or GUIDs | Refresh the constants from the site's JS (below) |
| Video downloads, subtitles stay base64 | Subtitle keys rotated | Refresh `KISSKH_SUB_KEYS` |

Where the constants come from, in the site's own scripts:

- **kkey cipher** (AES key and IV words, the `mg3c3b04ba` marker): `common.js`, the
  obfuscated function the player calls as `cryptoService.key(...)`.
- **App version, platform version, video and subtitle GUIDs**: the player chunk, as
  `this.appVer`, `this.platformVer`, `this.viGuid` and `this.subGuid`.
- **Subtitle keys**: `.txt` in `scripts.js` (`a1`); `.txt1` and the rest in the packed
  `scripts.<hash>.js` (`a2`, `a3`).

`.\dltv\tests\Invoke-Tests.ps1 -Live` checks search, episode listing, the signed stream
request and the subtitle request against the live site. Run it whenever KissKH downloads
start failing.

## Tests

```powershell
.\dltv\tests\Invoke-Tests.ps1          # offline, about 2s
.\dltv\tests\Invoke-Tests.ps1 -Live    # also hits kisskh.co
```

## Notes

- Requires `curl` (bundled with Windows 10 1803 and later). ffmpeg is optional and only used to remux HLS streams.
- qBittorrent's Web UI must be reachable for the torrent path.
- The KissKH path needs nothing beyond curl and PowerShell. No browser, no Python packages.
- Safety filters are aggressive by design. Use `--interactive` if a legitimate torrent gets rejected.
