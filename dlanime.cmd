@echo off
REM Quick anime downloader
REM Usage: dlanime "Anime Name" [series|movie] [destination] [--list] [--dry-run]
REM   series (default) -> destination from config
REM   movie            -> destination from config

setlocal EnableDelayedExpansion

set "SCRIPT=%~dp0dlanime\Add-Anime.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-Anime.ps1 exists in the dlanime subfolder.
    exit /b 1
)

if "%~1"=="" ( call :usage & exit /b 1 )

REM --list is the longer listing here - top 100 results with every magnet - rather than the
REM single-pick preview --dry-run gives, so point the shared parser at -ListOnly.
set "DL_LIST_PARAM=ListOnly"

REM Positional: 1 = title, 2 = series|movie, 3 = destination. The type is optional, so a
REM second bare word that is not series/movie is the destination.
call "%~dp0_dl-args.cmd" %*
if defined DL_ARGS_ERROR exit /b 1
if defined DL_ARGS_HELP ( call :usage & exit /b 0 )
if not defined DL_POS1 ( call :usage & exit /b 1 )

set "TYPE=%DL_POS2%"
set "DEST=%DL_POS3%"
if /i not "%TYPE%"=="series" if /i not "%TYPE%"=="movie" (
    if not defined DEST set "DEST=%TYPE%"
    set "TYPE="
)
if "%TYPE%"=="" set "TYPE=series"

set "IS_SERIES=yes"
if /i "%TYPE%"=="movie" set "IS_SERIES=no"

set "PS_ARGS=-Query "%DL_POS1%" -isAnimeSeries "%IS_SERIES%""
if defined DEST set "PS_ARGS=!PS_ARGS! -Destination "%DEST%""
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" !PS_ARGS!!DL_FLAGS!
exit /b %ERRORLEVEL%

:usage
echo Usage: dlanime "Anime Name" [series^|movie] [destination] [flags]
echo Example: dlanime "Frieren"
echo Example: dlanime "Your Name" movie
echo Example: dlanime "Frieren" series "E:\Anime"
echo Example: dlanime "Frieren" --list
echo.
echo   --list           show the top 100 results with every magnet, download nothing
echo   --dry-run        show the matches and the torrent it would add, download nothing
echo   --interactive    pick from the results instead of auto-selecting
echo   --trusted-only   only consider torrents from trusted uploaders
echo   --max-results N  cap how many results are considered
echo   --filter TEXT    keep only results matching TEXT
echo   --dest PATH      override the destination
echo.
echo Defaults: type=series, destination auto-resolved from config
goto :eof
