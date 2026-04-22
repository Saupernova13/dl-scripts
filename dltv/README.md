# dltv

Searches [The Pirate Bay](https://thepiratebay.org) for TV show torrents and automatically adds the best match to qBittorrent.

## Command

```
dltv "Show Name" [destination]
```

Add the repo root to `PATH` and call it from any terminal. Quotes are required when the name contains spaces.

## Usage Examples

```
dltv "Breaking Bad"
dltv "The Office" "E:\TV Shows"
```

The second positional argument is an optional destination override. Omit it to use the path from config.

## PowerShell Parameters

The CMD wrapper passes these through. You can also call the script directly for full control:

```powershell
.\dltv\Add-TV.ps1 -Query "Breaking Bad" [-Destination "path"] [-QbitHost "url"] [-MaxResults N] [-Interactive]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Query` | Yes | � | Show name to search |
| `-Destination` | No | from config | Download save path |
| `-QbitHost` | No | from config | qBittorrent WebUI URL |
| `-MaxResults` | No | from config | Max results to display |
| `-Interactive` | No | `$false` | Manually pick from the scored results list |

## Configuration

All settings are read from `%LOCALAPPDATA%\dlScripts\config.json`. The file is created automatically with defaults the first time you run the script. If the `tv` section is missing from an existing file, it is added automatically.

Default location: `C:\Users\<you>\AppData\Local\dlScripts\config.json`

```json
{
  "tv": {
    "qbitHost": "http://localhost:8080",
    "destination": "C:\\Users\\you\\TV",
    "maxResults": 50
  }
}
```

All values can be overridden at runtime with the corresponding command-line parameter.

## How It Works

1. Queries The Pirate Bay API (apibay.org) in the TV category for the show name
2. Passes every result through safety filters (see below) � rejects anything that is not TV content
3. Scores and sorts all remaining results
4. Auto-selects the highest-scored torrent, or prompts you in `-Interactive` mode
5. Sends the magnet link to qBittorrent with the configured save path

## Scoring System

Torrents are ranked automatically to find the best match:

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
| Base: seeder count | � |

Complete series and season packs are strongly preferred. Quality and source bonuses stack on top of the seeder count.

## Safety Filters

Any torrent whose name matches one of the following patterns is hard-rejected before scoring:

- Executable or script extensions: `.exe`, `.bat`, `.ps1`, `.cmd`, `.vbs`, `.js`, `.jar`, `.py`, `.sh`, `.dll`, `.scr`, `.pif`, `.hta`, `.wsf`, `.com`
- Archive extensions: `.rar`, `.zip`, `.7z`, `.tar`, `.gz`, `.bz2`, `.xz`, `.zst`, `.cab`
- Game-related keywords: CODEX, FitGirl, GOG, Steam, Xbox, PlayStation, SKIDROW, RELOADED, RG Mechanics, etc.
- Software-related keywords: Keygen, Activator, Cracked, Installer, Portable, Serial Key, License Key, Full Version, etc.
- Book / ebook keywords: epub, audiobook, Manga, PDF, mobi, azw3, comic, etc.

## Example Output

```
[2026-04-22 18:00:00] [INFO] Starting TV show download process
[2026-04-22 18:00:00] [INFO] Search query: Breaking Bad
[2026-04-22 18:00:01] [INFO] API returned 38 results

[1] Breaking Bad Complete Series 1080p BluRay
    Size: 47.3 GB | Seeds: 892 | Score: 3042 [COMPLETE SERIES]

[2] Breaking Bad S05 Complete 1080p WEB-DL
    Size: 18.1 GB | Seeds: 421 | Score: 2541 [SEASON PACK]

[2026-04-22 18:00:01] [INFO] Auto-selecting top-scored torrent
[2026-04-22 18:00:02] [SUCCESS] Successfully added to qBittorrent!
```

## Notes

- Requires `curl.exe`, which is bundled with Windows 10 1803 and later
- qBittorrent Web UI must be enabled and reachable at the configured host
- Safety filters are aggressive by design � use `-Interactive` if a legitimate result gets rejected
