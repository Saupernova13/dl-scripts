@echo off
REM Quick movie downloader from YTS.bz
REM Usage: dlmovie "Movie Name" [destination]
REM Default destination: from config (%LOCALAPPDATA%\dlScripts\config.ps1)

if "%~1"=="" (
    echo Usage: dlmovie "Movie Name" [destination]
    echo Example: dlmovie "Inception"
    echo Example: dlmovie "Inception" "E:\Movies"
    echo.
    echo Default destination: resolved from %LOCALAPPDATA%\dlScripts\config.ps1
    exit /b 1
)

set "SCRIPT=%~dp0dlmovie\Add-Movie.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-Movie.ps1 exists in the dlmovie subfolder.
    exit /b 1
)

setlocal EnableDelayedExpansion
set "MOVIE=%~1"
set "DEST=%~2"

if "%DEST%"=="" (
    powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%MOVIE%"
) else (
    powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%MOVIE%" -Destination "%DEST%"
)
