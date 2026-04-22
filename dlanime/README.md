# dlanime

A PowerShell script that searches nyaa.si for anime torrents and automatically adds the best match to qBittorrent with intelligent scoring.

## Features

- Searches [nyaa.si](https://nyaa.si) for anime series and movies
- **Dual Audio Priority**: Automatically appends "dual audio" to searches to find dual audio releases
- **Intelligent Scoring System**: Ranks torrents based on seeders, release type, uploader, and audio track
- **Batch/Season Pack Preference**: Heavily favors complete season packs over individual episodes
- **Preferred Uploaders**: Configurable list of trusted uploaders (default: judas, cerebrus, cleo, animetime)
- **Interactive Mode**: Optional manual torrent selection
- **List Mode**: Preview results without adding anything to qBittorrent
- **qBittorrent Integration**: Adds the selected torrent via the qBittorrent WebUI API
- Configuration sourced from a central config file — no hardcoded paths

## Prerequisites

- PowerShell 5.1 or higher
- [qBittorrent](https://www.qbittorrent.org/) with Web UI enabled
- Central config file set up (see [Configuration](#configuration))

## Configuration

This script reads settings from `%LOCALAPPDATA%\dlScripts\config.ps1`.

Create the file with the following content (adjust paths to match your setup):

```powershell
# %LOCALAPPDATA%\dlScripts\config.ps1

# qBittorrent WebUI address
$qBitHost = "http://localhost:8080"

# Anime download destinations
$animeSeriesDestination = "D:\Anime\Series"
$animeMoviesDestination = "D:\Anime\Movies"
$animeMaxResults = 75

# Preferred uploaders (case-insensitive partial match)
$animePreferredUploaders = @('judas', 'cerebrus', 'cleo', 'animetime')

# Automatically append "dual audio" to every search query
$animeAutoAppendDualAudio = $true
```

> All settings can be overridden at runtime with command-line parameters.

## Usage

### Download an anime series (default)

```powershell
.\dlanime.ps1 -Query "Frieren"
```

### Download an anime movie

```powershell
.\dlanime.ps1 -Query "Spirited Away" -isAnimeSeries "no"
```

### Custom destination

```powershell
.\dlanime.ps1 -Query "Frieren" -Destination "E:\Anime"
```

### Interactive mode (manual selection)

```powershell
.\dlanime.ps1 -Query "Demon Slayer" -Interactive
```

### List results without downloading

```powershell
.\dlanime.ps1 -Query "Frieren" -ListOnly
```

### Trusted uploaders only

```powershell
.\dlanime.ps1 -Query "Frieren" -TrustedOnly
```

### Additional filter terms

```powershell
.\dlanime.ps1 -Query "One Piece" -Filter "1080p"
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Query` | Yes | — | Anime name to search |
| `-isAnimeSeries` | No | `"yes"` | `"yes"` = series destination, `"no"` = movie destination |
| `-Destination` | No | from config | Override save path (takes priority over `-isAnimeSeries`) |
| `-TrustedOnly` | No | `$false` | Only show verified/trusted uploads on nyaa.si |
| `-QbitHost` | No | from config | qBittorrent WebUI URL |
| `-MaxResults` | No | from config | Max number of results to display |
| `-Interactive` | No | `$false` | Manually select from results |
| `-Filter` | No | `""` | Extra terms appended to the search query |
| `-ListOnly` | No | `$false` | Show results with magnet links and exit — nothing added to qBittorrent |

## Scoring System

Torrents are ranked automatically to select the best match:

| Condition | Points |
|-----------|--------|
| Batch / season pack | +1000 |
| Single episode | −500 |
| Preferred uploader | +200 |
| Dual audio | +100 |
| Base: seeder count | — |

The highest-scored torrent is selected automatically unless `-Interactive` or `-ListOnly` is used.

## Default Preferred Uploaders

| Uploader | Known For |
|----------|-----------|
| judas | High-quality encodes, small file sizes |
| cerebrus | Reliable dual audio releases |
| cleo | Consistent quality releases |
| animetime | Broad catalogue coverage |

These can be customized via `$animePreferredUploaders` in the config file.

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

### Search for specific quality
```powershell
.\dlanime.ps1 -Query "One Piece" -Filter "1080p HEVC"
```

### Download to custom location
```powershell
.\dlanime.ps1 -Query "Attack on Titan" -Destination "C:\Downloads\Anime"
```

## Output

The script provides colored console output showing:
- Search query and parameters
- Parsed torrents with scores
- Selected torrent details
- qBittorrent add status

The script also returns a JSON object with the selected torrent details for programmatic use.

## Requirements

- PowerShell 5.1+
- qBittorrent (running and accessible)
- Internet connection

## License

MIT License - See LICENSE file for details

## Author

Sauraav Jayrajh (Saupernova13)

## Notes

- The script automatically appends "dual audio" to searches unless you specify a custom filter
- Batch releases are heavily prioritized over individual episodes
- The scoring system ensures you get the best available release based on quality, seeders, and uploader reputation
