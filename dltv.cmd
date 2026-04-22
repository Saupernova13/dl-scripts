@echo off
REM Quick TV show downloader from The Pirate Bay
REM Usage: dltv "Show Name" [destination]
REM Default destination: from config (%LOCALAPPDATA%\dlScripts\config.ps1)

if "%~1"=="" (
    echo Usage: dltv "Show Name" [destination]
    echo Example: dltv "Breaking Bad"
    echo Example: dltv "The Office" "E:\TV"
    echo.
    echo Default destination: resolved from %LOCALAPPDATA%\dlScripts\config.ps1
    exit /b 1
)

set "SCRIPT=%~dp0dltv\Add-TV.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-TV.ps1 exists in the dltv subfolder.
    exit /b 1
)

setlocal EnableDelayedExpansion
set "SHOW=%~1"
set "DEST=%~2"

if "%DEST%"=="" (
    powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%SHOW%"
) else (
    powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%SHOW%" -Destination "%DEST%"
)
