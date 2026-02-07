# game-grabber

A PowerShell tool to automatically search for games on appnetica.com and download them via qBittorrent.

## Features

- Automatic login to appnetica.com
- Search for games by name
- Filters for Steam versions only (excludes repacks)
- Automatic torrent download
- Direct integration with qBittorrent WebUI
- Configuration file support
- Interactive mode for manual game selection

## Prerequisites

- PowerShell 5.1 or higher
- qBittorrent with WebUI enabled
- appnetica.com account

## Installation

1. Clone this repository
2. Copy `.settings.example` to `.settings`
3. Edit `.settings` with your credentials and preferences
4. Ensure qBittorrent WebUI is enabled

## Configuration

Edit `.settings` file:

```ini
Email=your@email.com
Password=yourpassword
Destination=D:\Games
QbitHost=http://localhost:8075
MaxResults=10
```

## Usage

### Basic Usage

```powershell
.\Add-Game.ps1 -Query "Spider-Man"
```

### Interactive Mode

```powershell
.\Add-Game.ps1 -Query "Dark Souls" -Interactive
```

### Override Settings

```powershell
.\Add-Game.ps1 -Query "Elden Ring" -Destination "E:\Games"
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Query` | Yes | - | Game name to search for |
| `-Email` | No | From `.settings` | Appnetica login email |
| `-Password` | No | From `.settings` | Appnetica password |
| `-Destination` | No | `D:\Games` | Download folder |
| `-QbitHost` | No | `http://localhost:8075` | qBittorrent WebUI URL |
| `-MaxResults` | No | `10` | Max search results |
| `-Interactive` | No | `false` | Choose from results manually |

## How It Works

1. Logs into appnetica.com
2. Searches for games using the query
3. Parses SvelteKit API response
4. Filters for Steam versions (excludes repacks)
5. Downloads the selected game's torrent file
6. Uploads to qBittorrent automatically

## Notes

- Only Steam folder versions are downloaded (no repacks like Decepticon, FitGirl, etc.)
- Requires qBittorrent WebUI to be enabled and accessible
- Credentials are stored in `.settings` file (not tracked by git)

## License

MIT
