# dlgame

A PowerShell script that searches [appnetica.com](https://appnetica.com) for PC games and automatically downloads them via qBittorrent.

## Features

- Authenticates with appnetica.com and searches by game name
- Filters for Steam versions — excludes repacks and undesired entries
- Auto-selects the first result, or lets you choose in interactive mode
- Downloads the `.torrent` file and adds it to qBittorrent
- Configuration split between a central config file (paths, qBittorrent) and a local `.settings` file (credentials)

## Prerequisites

- PowerShell 5.1 or higher
- [qBittorrent](https://www.qbittorrent.org/) with Web UI enabled
- An [appnetica.com](https://appnetica.com) account
- Central config file set up (see [Configuration](#configuration))

## Configuration

### Central config (paths & qBittorrent)

Settings are read from `%LOCALAPPDATA%\dlScripts\config.ps1`:

```powershell
# %LOCALAPPDATA%\dlScripts\config.ps1

# qBittorrent WebUI address
$qBitHost = "http://localhost:8080"

# Game download destination
$gameDestination = "D:\Games"
$gameMaxResults = 10
```

### Credentials (`.settings`)

Copy `.settings.example` to `.settings` in the same directory as the script and fill in your details:

```ini
Email=your@email.com
Password=yourpassword
```

> `.settings` is gitignored and will never be committed.

## Usage

### Basic

```powershell
.\dlgame.ps1 -Query "Spider-Man"
```

### Custom destination

```powershell
.\dlgame.ps1 -Query "Spider-Man" -Destination "E:\Games"
```

### Interactive mode (manual selection)

```powershell
.\dlgame.ps1 -Query "Resident Evil" -Interactive
```

### Pass credentials at runtime (no `.settings` file needed)

```powershell
.\dlgame.ps1 -Query "Witcher 3" -Email "you@example.com" -Password "yourpass"
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Query` | Yes | — | Game name to search |
| `-Email` | No* | from `.settings` | appnetica.com login email |
| `-Password` | No* | from `.settings` | appnetica.com login password |
| `-Destination` | No | from config | Download save path |
| `-QbitHost` | No | from config | qBittorrent WebUI URL |
| `-MaxResults` | No | from config | Max number of results to show |
| `-Interactive` | No | `$false` | Manually pick from results |

*Either `.settings` or runtime parameters must supply credentials.

## How It Works

1. **Login** — Authenticates with appnetica.com using your credentials
2. **Search** — Queries the SvelteKit search endpoint for the game
3. **Filter** — Focuses on "Папка игры" (game folder) entries, excludes repacks
4. **Select** — Auto-selects the first result, or shows a list in interactive mode
5. **Download** — Downloads the `.torrent` file from the game's page
6. **Add to qBittorrent** — Sends the torrent to qBittorrent with the configured save path
7. **Cleanup** — Removes the temporary `.torrent` file

## Example Output

```
[2026-04-22 18:00:00] [INFO] Starting game download process
[2026-04-22 18:00:00] [INFO] Search query: Spider-Man
[2026-04-22 18:00:00] [INFO] Logging in to appnetica.com...
[2026-04-22 18:00:01] [SUCCESS] Login successful
[2026-04-22 18:00:01] [INFO] Searching for games...
[2026-04-22 18:00:02] [SUCCESS] Found 3 potential games

[1] Marvel's Spider-Man 2
    URL: https://appnetica.com/games/marvels-spider-man-2-steam

[2026-04-22 18:00:02] [INFO] Auto-selecting first game
[2026-04-22 18:00:05] [SUCCESS] Successfully added to qBittorrent!
```
.\dlgame.ps1 -Query "Dark Souls" -Interactive
```

### Override Settings

```powershell
.\dlgame.ps1 -Query "Elden Ring" -Destination "E:\Games"
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
