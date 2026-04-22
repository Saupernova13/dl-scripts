# dltv

A PowerShell script that searches The Pirate Bay for TV shows and automatically adds the best available torrent to qBittorrent.

## Features

- Searches The Pirate Bay API (apibay.org) in the TV category
- Smart scoring system prefers complete series > season packs > individual episodes
- Quality detection: 4K, 1080p, 720p with source bonuses (BluRay, WEB-DL, etc.)
- Safety filters reject non-TV content (games, software, books, executables, archives)
- Interactive mode for manual selection
- Configuration sourced from a central config file — no hardcoded paths

## Prerequisites

- PowerShell 5.1 or higher
- [qBittorrent](https://www.qbittorrent.org/) with Web UI enabled
- `curl.exe` (included with Windows 10 1803+)
- Central config file set up (see [Configuration](#configuration))

## Configuration

This script reads settings from `%LOCALAPPDATA%\dlScripts\config.ps1`.

Create the file with the following content (adjust paths to match your setup):

```powershell
# %LOCALAPPDATA%\dlScripts\config.ps1

# qBittorrent WebUI address
$qBitHost = "http://localhost:8080"

# TV download destination
$tvDestination = "D:\TV"
$tvMaxResults = 50
```

> All settings can be overridden at runtime with command-line parameters.

## Usage

### Basic

```powershell
.\dltv.ps1 -Query "Breaking Bad"
```

### Custom destination

```powershell
.\dltv.ps1 -Query "The Office" -Destination "E:\TV Shows"
```

### Interactive mode (manual selection)

```powershell
.\dltv.ps1 -Query "Breaking Bad" -Interactive
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Query` | Yes | — | Show name to search |
| `-Destination` | No | from config | Download save path |
| `-QbitHost` | No | from config | qBittorrent WebUI URL |
| `-MaxResults` | No | from config | Max results to display |
| `-Interactive` | No | `$false` | Manually pick from results |

## Scoring System

Torrents are ranked automatically to find the best match:

| Condition | Points |
|-----------|--------|
| Complete series (all seasons) | +2000 |
| Complete season pack | +1800 |
| Season pack (no episode number) | +1500 |
| Single episode | −800 |
| 4K / 2160p | +300 |
| 1080p | +200 |
| 720p | +100 |
| BluRay source | +150 |
| WEB-DL source | +120 |
| WEBRip / streaming source | +80 |
| Base: seeder count | — |

## Safety Filters

The script hard-rejects any torrent whose name matches:

- Executable / script file extensions (`.exe`, `.bat`, `.ps1`, etc.)
- Archive extensions (`.rar`, `.zip`, `.7z`, etc.)
- Game-related keywords (CODEX, FitGirl, GOG, Steam, etc.)
- Software-related keywords (Keygen, Activator, Installer, etc.)
- Book / ebook keywords (epub, audiobook, Manga, etc.)

## How It Works

1. Queries The Pirate Bay API for the show name in the TV category
2. Filters out non-TV content via safety rules
3. Scores and sorts all results
4. Displays the top results
5. Auto-selects the top-scored result (or prompts in interactive mode)
6. Sends the magnet link to qBittorrent with the configured save path

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
