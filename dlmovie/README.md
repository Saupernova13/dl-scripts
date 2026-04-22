# dlmovie

Searches the [YTS](https://yts.bz) API for movies and automatically adds the best available torrent to qBittorrent.

## Command

```
dlmovie "Movie Name" [destination]
```

Add the repo root to `PATH` and call it from any terminal. Quotes are required when the name contains spaces.

## Usage Examples

```
dlmovie "Inception"
dlmovie "Inception" "E:\Movies"
```

The second positional argument is an optional destination override. Omit it to use the path from config.

## PowerShell Parameters

The CMD wrapper passes these through. You can also call the script directly for full control:

```powershell
.\dlmovie\Add-Movie.ps1 -Query "Inception" [-Destination "path"] [-QbitHost "url"] [-MaxResults N] [-Interactive]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Query` | Yes | — | Movie name to search |
| `-Destination` | No | from config | Download save path |
| `-QbitHost` | No | from config | qBittorrent WebUI URL |
| `-MaxResults` | No | from config | Max results to consider |
| `-Interactive` | No | `$false` | Manually pick from the results list |

## Configuration

All settings are read from `%LOCALAPPDATA%\dlScripts\config.ps1`. Create the file if it does not exist:

```powershell
# %LOCALAPPDATA%\dlScripts\config.ps1

$qBitHost         = "http://localhost:8080"
$movieDestination = "D:\Movies"
$movieMaxResults  = 15
```

All config values can be overridden at runtime with the corresponding parameter.

## How It Works

1. Queries the YTS API with the movie name, sorted by seeds
2. For each result, picks the best available torrent by quality priority (see below)
3. Displays results sorted by seeder count
4. Auto-selects the top result, or prompts you in `-Interactive` mode
5. Sends the magnet link to qBittorrent with the configured save path

## Quality Priority

Torrents are selected in this order of preference:

1. **1080p BluRay** — highest quality
2. **1080p Web** — streaming source
3. **Best available** — fallback to the highest-seeded torrent of any quality

## Example Output

```
[2026-04-22 18:00:00] [INFO] Starting movie download process
[2026-04-22 18:00:00] [INFO] Search query: Inception
[2026-04-22 18:00:00] [INFO] Fetching from YTS API...

[1] Inception (2010)
    Quality: 1080p BluRay | Size: 2.18 GB | Seeds: 4521 | Rating: 8.8
    All available: 720p web, 1080p bluray, 2160p bluray

[2026-04-22 18:00:01] [INFO] Auto-selecting top result
[2026-04-22 18:00:01] [SUCCESS] Selected: Inception (2010)
[2026-04-22 18:00:02] [SUCCESS] Successfully added to qBittorrent!
```

## Notes

- Results are sourced from the YTS public API — only movies indexed by YTS are findable
- qBittorrent Web UI must be enabled and reachable at the configured host
