@echo off
REM Quick game downloader for appnetica.com
REM Usage: dlgame "Game Name" [destination] [--dry-run] [--interactive] [--max-results N]
REM Default destination: from config (%LOCALAPPDATA%\dlScripts\config.ps1)

setlocal EnableDelayedExpansion

set "SCRIPT=%~dp0dlgame\Add-Game.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-Game.ps1 exists in the dlgame subfolder.
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
echo Usage: dlgame "Game Name" [destination] [flags]
echo Example: dlgame "Spider-Man"
echo Example: dlgame "Resident Evil" "E:\Games"
echo Example: dlgame "Spider-Man" --dry-run
echo.
echo   --dry-run        show the match and the link it would fetch, download nothing
echo   --list           same as --dry-run
echo   --interactive    pick from the results instead of auto-selecting
echo   --max-results N  cap how many results are considered
echo   --dest PATH      override the destination
echo.
echo Default destination: resolved from %LOCALAPPDATA%\dlScripts\config.ps1
goto :eof
