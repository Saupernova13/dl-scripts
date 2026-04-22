# dlgame

Authenticates with [appnetica.com](https://appnetica.com), searches for a PC game, and adds its torrent to qBittorrent.

## Command

```
dlgame "Game Name" [destination]
```

Add the repo root to `PATH` and call it from any terminal. Quotes are required when the name contains spaces.

## Usage Examples

```
dlgame "Spider-Man"
dlgame "Resident Evil" "E:\Games"
dlgame "Elden Ring" --interactive
```

The second positional argument is an optional destination override. Omit it to use the path from config.

## PowerShell Parameters

The CMD wrapper passes these through. You can also call the script directly for full control:

```powershell
.\dlgame\Add-Game.ps1 -Query "Spider-Man" [-Email "you@example.com"] [-Password "pass"] [-Destination "path"] [-QbitHost "url"] [-MaxResults N] [-Interactive]
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Query` | Yes | � | Game name to search |
| `-Email` | No* | from `.settings` | appnetica.com login email |
| `-Password` | No* | from `.settings` | appnetica.com login password |
| `-Destination` | No | from config | Download save path |
| `-QbitHost` | No | from config | qBittorrent WebUI URL |
| `-MaxResults` | No | from config | Max number of results to display |
| `-Interactive` | No | `$false` | Manually pick from the results list |

\* Either `.settings` or command-line parameters must supply credentials.

## Configuration

Settings are split between two files.

### Shared config (paths & qBittorrent)

`%LOCALAPPDATA%\dlScripts\config.json` — created automatically with defaults on first run. If the `game` section is missing from an existing file, it is added automatically.

Default location: `C:\Users\<you>\AppData\Local\dlScripts\config.json`

```json
{
  "game": {
    "qbitHost": "http://localhost:8080",
    "destination": "C:\\Users\\you\\Games",
    "maxResults": 10
  }
}
```

### Credentials (`.settings`)

Copy `.settings.example` to `.settings` in the `dlgame/` folder and fill in your details:

```ini
Email=your@email.com
Password=yourpassword
```

`.settings` is gitignored and will never be committed. Command-line parameters (`-Email`, `-Password`) override `.settings`.

## How It Works

1. **Login** � Authenticates with appnetica.com using your credentials
2. **Search** � Queries the SvelteKit search endpoint for the game name
3. **Filter** � Focuses on "????? ????" (Steam game folder) entries; excludes repacks and undesired entries
4. **Select** � Auto-selects the first result, or shows a numbered list in `-Interactive` mode
5. **Download** � Fetches the `.torrent` file from the game's detail page
6. **Add to qBittorrent** � Sends the torrent to qBittorrent with the configured save path
7. **Cleanup** � Removes the temporary `.torrent` file

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

## Notes

- Only Steam folder versions are downloaded � repacks (FitGirl, Decepticon, etc.) are excluded
- Credentials are never logged or stored outside `.settings`
- qBittorrent Web UI must be enabled and reachable at the configured host
