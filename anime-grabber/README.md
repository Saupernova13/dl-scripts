# anime-grabber

PowerShell script to automatically search nyaa.si for anime torrents and add them to qBittorrent with intelligent scoring.

## Features

- **Smart Search**: Automatically searches nyaa.si with customizable filters
- **Dual Audio Priority**: Automatically appends "dual audio" to searches to prioritize dual audio releases
- **Intelligent Scoring System**: Ranks torrents based on multiple criteria:
  - **Base Score**: Number of seeders
  - **Batch Bonus**: +1000 points for season packs and batch releases
  - **Episode Penalty**: -500 points for individual episodes
  - **Preferred Uploader Bonus**: +200 points for trusted uploaders
  - **Dual Audio Bonus**: +100 points for dual audio releases
- **Preferred Uploaders**: Prioritizes releases from judas, cerebrus, cleo, and animetime
- **Interactive Mode**: Optional manual selection of torrents
- **qBittorrent Integration**: Automatically adds selected torrents to qBittorrent

## Installation

1. Ensure PowerShell 5.1 or higher is installed
2. Clone this repository
3. Ensure qBittorrent is running and accessible (default: http://localhost:8075)

## Usage

### Basic Usage

```powershell
.\Add-Anime.ps1 -Query "Frieren"
```

### With Custom Destination

```powershell
.\Add-Anime.ps1 -Query "Frieren" -Destination "E:\Anime"
```

### Interactive Mode (Manual Selection)

```powershell
.\Add-Anime.ps1 -Query "Frieren" -Interactive
```

### Trusted Only (Verified Uploaders)

```powershell
.\Add-Anime.ps1 -Query "Frieren" -TrustedOnly
```

### Custom Filter

```powershell
.\Add-Anime.ps1 -Query "Frieren" -Filter "1080p"
```

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Query` | string | Yes | - | Search query for the anime |
| `-Destination` | string | No | `D:\TV` | Download destination path |
| `-TrustedOnly` | switch | No | `false` | Only show verified/trusted uploaders |
| `-QbitHost` | string | No | `http://localhost:8075` | qBittorrent host URL |
| `-MaxResults` | int | No | `75` | Maximum number of results to display |
| `-Interactive` | switch | No | `false` | Enable manual torrent selection |
| `-Filter` | string | No | `""` | Additional filter terms |

## Scoring System

The script uses a sophisticated scoring system to automatically select the best torrent:

1. **Base Score** = Number of seeders
2. **+1000 points** for batch/season releases (e.g., "Season 1", "Batch", "Complete")
3. **-500 points** for individual episodes
4. **+200 points** for preferred uploaders (judas, cerebrus, cleo, animetime)
5. **+100 points** for dual audio releases

The highest-scored torrent is automatically selected unless Interactive mode is enabled.

## Preferred Uploaders

The script prioritizes releases from these trusted uploaders:
- **judas**: High-quality encodes with small file sizes
- **cerebrus**: Reliable dual audio releases
- **cleo**: Quality anime releases
- **animetime**: Consistent uploaders

## Examples

### Search for Frieren (auto-select best match)
```powershell
.\Add-Anime.ps1 -Query "Frieren"
```

### Search with manual selection
```powershell
.\Add-Anime.ps1 -Query "Demon Slayer" -Interactive
```

### Search for specific quality
```powershell
.\Add-Anime.ps1 -Query "One Piece" -Filter "1080p HEVC"
```

### Download to custom location
```powershell
.\Add-Anime.ps1 -Query "Attack on Titan" -Destination "C:\Downloads\Anime"
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
