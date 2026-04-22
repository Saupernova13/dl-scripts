@echo off
REM Quick game downloader for appnetica.com
REM Usage: dlgame "Game Name" [destination]
REM Default destination: from config (%LOCALAPPDATA%\dlScripts\config.ps1)

if "%~1"=="" (
    echo Usage: dlgame "Game Name" [destination]
    echo Example: dlgame "Spider-Man"
    echo Example: dlgame "Resident Evil" "E:\Games"
    echo.
    echo Default destination: resolved from %LOCALAPPDATA%\dlScripts\config.ps1
    exit /b 1
)

set "SCRIPT=%~dp0dlgame\Add-Game.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-Game.ps1 exists in the dlgame subfolder.
    exit /b 1
)

setlocal EnableDelayedExpansion
set "GAME=%~1"
set "DEST=%~2"

if "%DEST%"=="" (
    powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%GAME%"
) else (
    powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%GAME%" -Destination "%DEST%"
)
