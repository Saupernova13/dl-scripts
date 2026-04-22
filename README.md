# dl-scripts

PowerShell scripts for searching and queueing media downloads to qBittorrent.

| Script | Source | Description |
|--------|--------|-------------|
| [dlanime](dlanime/) | nyaa.si | Anime series and movies |
| [dlgame](dlgame/) | appnetica.com | PC games |
| [dlmovie](dlmovie/) | YTS | Movies |
| [dltv](dltv/) | The Pirate Bay | TV shows |

## Setup

Add the root of this repo to your `PATH`, then run any script from any terminal:

```
dlanime "Frieren"
dlgame "Spider-Man"
dlmovie "Inception"
dltv "Breaking Bad"
```

See each subfolder's `README.md` for full parameter reference, configuration, and how each script works.
