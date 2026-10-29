@echo off
REM Quick TV show downloader from The Pirate Bay
REM Usage: dltv "Show Name" [destination] [--dry-run] [--interactive] [--max-results N]
REM        dltv "Show Name" --asian [--episodes RANGE]      (KissKH, background job)
REM        dltv --jobs [--json] | dltv --status ID [--json]
REM Default destination: from config (%LOCALAPPDATA%\dlScripts\config.ps1)

setlocal EnableDelayedExpansion

set "SCRIPT=%~dp0dltv\Add-TV.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-TV.ps1 exists in the dltv subfolder.
    exit /b 1
)

if "%~1"=="" ( call :usage & exit /b 1 )

REM Positional: 1 = title, 2 = destination. Every flag, kebab or native, is translated by
REM the shared parser so all the launchers accept the same vocabulary.
call "%~dp0_dl-args.cmd" %*
if defined DL_ARGS_ERROR exit /b 1
if defined DL_ARGS_HELP ( call :usage & exit /b 0 )
REM A query is required unless the call only inspects jobs (--jobs, --status).
if defined DL_POS1 goto :have_query
if defined DL_JOB_MODE goto :have_query
call :usage
exit /b 1

:have_query
set "PS_ARGS="
if defined DL_POS1 set "PS_ARGS=-Query "%DL_POS1%""
if defined DL_POS2 set "PS_ARGS=!PS_ARGS! -Destination "%DL_POS2%""
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" !PS_ARGS!!DL_FLAGS!
exit /b %ERRORLEVEL%

:usage
echo Usage: dltv "Show Name" [destination] [flags]
echo Example: dltv "Breaking Bad"
echo Example: dltv "The Office" "E:\TV"
echo Example: dltv "Breaking Bad" --dry-run
echo Example: dltv "Bad Buddy" --asian --episodes 1-4
echo.
echo   --dry-run        show the matches and the torrent it would add, download nothing
echo   --list           same as --dry-run
echo   --interactive    pick from the results instead of auto-selecting
echo   --max-results N  cap how many results are considered
echo   --dest PATH      override the destination
echo   --asian          skip torrents, download from KissKH in a background job
echo   --episodes RANGE KissKH only: 3, 1-4 or 5- (default: all released episodes)
echo   --jobs           list KissKH download jobs
echo   --status ID      show one KissKH download job (size, speed, ETA, drive)
echo   --json           with --status or --jobs: print only JSON
echo.
echo A weak torrent (few seeders) falls back to KissKH on an exact title match.
echo.
echo Default destination: resolved from %LOCALAPPDATA%\dlScripts\config.ps1
goto :eof
