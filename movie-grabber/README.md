# movie-grabber

A PowerShell script that searches the YTS API for movies and automatically adds the best available torrent to qBittorrent.

## Features

- Searches YTS (yts.bz) API by movie name
- Automatically selects the best quality torrent (priority: 1080p BluRay → 1080p Web → best available)
- Direct qBittorrent WebUI integration via magnet link
- Interactive mode for manual selection
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

# Movie download destination
$movieDestination = "D:\Movies"
$movieMaxResults = 15
```

> All settings can be overridden at runtime with command-line parameters.

## Usage

### Basic

```powershell
.\Add-Movie.ps1 -Query "Inception"
```

### Custom destination

```powershell
.\Add-Movie.ps1 -Query "Inception" -Destination "E:\Movies"
```

### Interactive mode (manual selection)

```powershell
.\Add-Movie.ps1 -Query "Inception" -Interactive
```

### Custom qBittorrent host

```powershell
.\Add-Movie.ps1 -Query "Inception" -QbitHost "http://192.168.1.10:8080"
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Query` | Yes | — | Movie name to search |
| `-Destination` | No | from config | Download save path |
| `-QbitHost` | No | from config | qBittorrent WebUI URL |
| `-MaxResults` | No | from config | Max results to consider |
| `-Interactive` | No | `$false` | Manually pick from results |

## Quality Priority

1. **1080p BluRay** — highest quality
2. **1080p Web** — streaming source
3. **Best available** — fallback to highest-seeded torrent

## How It Works

1. Queries the YTS API for the movie name
2. For each result, picks the best available torrent by quality priority
3. Displays results (sorted by seeder count)
4. Auto-selects the top result (or prompts in interactive mode)
5. Sends the magnet link to qBittorrent with the configured save path

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
