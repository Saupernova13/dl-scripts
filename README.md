# dl-scripts

A collection of PowerShell scripts for searching and queueing media downloads to qBittorrent.

## Scripts

| Script | Description |
|--------|-------------|
| [dlanime](dlanime/) | Search nyaa.si for anime and add to qBittorrent |
| [dlgame](dlgame/) | Search appnetica.com for PC games and add to qBittorrent |
| [dlmovie](dlmovie/) | Search YTS for movies and add to qBittorrent |
| [dltv](dltv/) | Search The Pirate Bay for TV shows and add to qBittorrent |

## Setup

All scripts source shared configuration from `%LOCALAPPDATA%\dlScripts\config.ps1`.

```powershell
# %LOCALAPPDATA%\dlScripts\config.ps1
$Destination = "D:\Media"
$QbitHost    = "http://localhost:8080"
$MaxResults  = 10
```

Scripts that require credentials (e.g. `dlgame`) also read a `.settings` file in their own directory. See the `.settings.example` file in that subfolder.

## Usage

```powershell
.\dlanime\dlanime.ps1 -Query "Frieren"
.\dlgame\dlgame.ps1   -Query "Spider-Man"
.\dlmovie\dlmovie.ps1 -Query "Inception"
.\dltv\dltv.ps1       -Query "Breaking Bad"
```

Refer to each subfolder's `README.md` for the full parameter reference.
