# dlanime

Searches [nyaa.si](https://nyaa.si) for anime torrents and automatically adds the best match to qBittorrent.

## Command

```
dlanime "Anime Name" [series|movie] [destination] [--list]
```

Add the repo root to `PATH` and call it from any terminal. Quotes are required when the name contains spaces.

## Usage Examples

```
dlanime "Frieren"
dlanime "Your Name" movie
dlanime "Frieren" series "E:\Anime"
dlanime "Demon Slayer" series "" --list
```

The second positional argument is the type (`series` or `movie`). The third is an optional destination override. Pass `--list` anywhere to preview results without adding to qBittorrent.

## PowerShell Parameters

The CMD wrapper passes these through. You can also call the script directly for full control:

```powershell
.\dlanime\Add-Anime.ps1 -Query "Frieren" [-isAnimeSeries yes|no] [-Destination "path"] [-TrustedOnly] [-Interactive] [-Filter "term"] [-ListOnly] [-QbitHost "url"] [-MaxResults N]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Query` | Yes | ï¿½ | Anime name to search |
| `-isAnimeSeries` | No | `"yes"` | `"yes"` saves to series destination, `"no"` saves to movies destination |
| `-Destination` | No | from config | Override save path; takes priority over `-isAnimeSeries` |
| `-TrustedOnly` | No | `$false` | Only show verified/trusted uploads on nyaa.si |
| `-QbitHost` | No | from config | qBittorrent WebUI URL |
| `-MaxResults` | No | from config | Max number of results to fetch from nyaa.si |
| `-Interactive` | No | `$false` | Manually pick from the scored results list |
| `-Filter` | No | `""` | Extra search terms appended to the query (overrides auto dual-audio append) |
| `-ListOnly` | No | `$false` | Print results with magnet links and exit ï¿½ nothing is added to qBittorrent |

## Configuration

All settings are read from `%LOCALAPPDATA%\dlScripts\config.json`. The file is created automatically with defaults the first time you run the script. If the `anime` section is missing from an existing file, it is added automatically.

Default location: `C:\Users\<you>\AppData\Local\dlScripts\config.json`

```json
{
  "anime": {
    "qbitHost": "http://localhost:8080",
    "seriesDestination": "C:\\Users\\you\\Anime\\Series",
    "moviesDestination": "C:\\Users\\you\\Anime\\Movies",
    "maxResults": 75,
    "autoAppendDualAudio": true,
    "preferredUploaders": ["judas", "cerebrus", "cleo", "animetime"]
  }
}
```

All values can be overridden at runtime with the corresponding command-line parameter.

## How It Works

1. Appends "dual audio" to the query unless `-Filter` is specified
2. Fetches the nyaa.si search results page and parses the HTML table
3. Scores every torrent (see Scoring System below)
4. Auto-selects the highest-scored torrent, or prompts you in `-Interactive` mode
5. Sends the torrent to qBittorrent via the WebUI API with the configured save path

## Scoring System

| Condition | Points |
|-----------|--------|
| Batch / season pack | +1000 |
| Single episode | -500 |
| Preferred uploader | +200 |
| Dual audio | +100 |
| Base: seeder count | ï¿½ |

Complete season packs are strongly preferred over individual episodes. The preferred uploader list and dual-audio bonus stack on top.

## Default Preferred Uploaders

| Uploader | Known For |
|----------|-----------|
| judas | High-quality encodes, small file sizes |
| cerebrus | Reliable dual audio releases |
| cleo | Consistent quality |
| animetime | Broad catalogue coverage |

Customise via `$animePreferredUploaders` in config.

## Example Output

```
[2026-04-22 18:00:00] [INFO] Starting anime download process
[2026-04-22 18:00:00] [INFO] Search query: Frieren dual audio
[2026-04-22 18:00:00] [INFO] Destination: D:\Anime\Series
[2026-04-22 18:00:01] [INFO] Found 75 potential matches in HTML

[1] [Judas] Frieren - Beyond Journey's End (Season 1) [Dual Audio] [1080p]
    Uploader: Judas [BATCH/SEASON, PREFERRED, DUAL AUDIO]
    Size: 12.8 GiB | Seeds: 1243 | Score: 2543

[2026-04-22 18:00:01] [INFO] Auto-selecting top-scored torrent
[2026-04-22 18:00:02] [SUCCESS] Successfully added torrent to qBittorrent!
```

## Notes

- Batch releases are heavily prioritised over individual episodes
- The scoring system picks the best available release based on quality, seeders, and uploader reputation
- Use `-ListOnly` to preview what would be selected before committing
