@echo off
REM Quick movie downloader from YTS.bz
REM Usage: dlmovie "Movie Name" [destination] [--quality Q] [--dry-run] [--interactive] [--max-results N]
REM Default destination: from config (%LOCALAPPDATA%\dlScripts\config.json)

setlocal EnableDelayedExpansion

set "SCRIPT=%~dp0dlmovie\Add-Movie.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-Movie.ps1 exists in the dlmovie subfolder.
    exit /b 1
)

if "%~1"=="" ( call :usage & exit /b 1 )

REM Positional: 1 = title, 2 = destination. Every flag, kebab or native, is translated by
REM the shared parser so all the launchers accept the same vocabulary.
call "%~dp0_dl-args.cmd" %*
if defined DL_ARGS_ERROR exit /b 1
if defined DL_ARGS_HELP ( call :usage & exit /b 0 )
if not defined DL_POS1 ( call :usage & exit /b 1 )

set "PS_ARGS=-Query "%DL_POS1%""
if defined DL_POS2 set "PS_ARGS=!PS_ARGS! -Destination "%DL_POS2%""
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" !PS_ARGS!!DL_FLAGS!
exit /b %ERRORLEVEL%

:usage
echo Usage: dlmovie "Movie Name" [destination] [flags]
echo Example: dlmovie "Inception"
echo Example: dlmovie "Inception" "E:\Movies"
echo Example: dlmovie "Inception" --dry-run
echo Example: dlmovie "Inception" --quality 2160p
echo.
echo   --dry-run        show the matches and the torrent it would add, download nothing
echo   --list           same as --dry-run
echo   --interactive    pick from the results instead of auto-selecting
echo   --max-results N  cap how many results are considered
echo   --quality Q      preferred resolution: 720p, 1080p (default), 2160p/4k, 3D
echo   --dest PATH      override the destination
echo.
echo Default destination: resolved from %LOCALAPPDATA%\dlScripts\config.json
goto :eof
