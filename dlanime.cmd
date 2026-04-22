@echo off
REM Quick anime downloader
REM Usage: dlanime "Anime Name" [series|movie] [destination] [--list]
REM   series (default) -> destination from config
REM   movie            -> destination from config
REM   --list           -> Show top 100 results with magnets, don't add to qBittorrent

if "%~1"=="" (
    echo Usage: dlanime "Anime Name" [series^|movie] [destination] [--list]
    echo Example: dlanime "Frieren"
    echo Example: dlanime "Your Name" movie
    echo Example: dlanime "Frieren" series "E:\Anime"
    echo Example: dlanime "Frieren" --list
    echo.
    echo Defaults: type=series, destination auto-resolved from config
    echo Use --list to preview top 100 results without downloading
    exit /b 1
)

set "SCRIPT=%~dp0dlanime\Add-Anime.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-Anime.ps1 exists in the dlanime subfolder.
    exit /b 1
)

setlocal EnableDelayedExpansion
set "ANIME=%~1"
set "ARG2=%~2"
set "ARG3=%~3"
set "ARG4=%~4"
set "LIST_ONLY="

REM Detect --list flag in any position
if /i "%ARG2%"=="--list" set "LIST_ONLY=1"
if /i "%ARG3%"=="--list" set "LIST_ONLY=1"
if /i "%ARG4%"=="--list" set "LIST_ONLY=1"

REM Set TYPE (skip if it's --list)
set "TYPE=%ARG2%"
if /i "%TYPE%"=="--list" set "TYPE="

REM Set DEST (skip if it's --list)
set "DEST=%ARG3%"
if /i "%DEST%"=="--list" set "DEST="

REM If DEST still empty, check ARG4
if "%DEST%"=="" (
    if not "%ARG4%"=="" (
        if /i not "%ARG4%"=="--list" set "DEST=%ARG4%"
    )
)

REM Default type to series
if "%TYPE%"=="" set "TYPE=series"

REM Map type to isAnimeSeries flag
set "IS_SERIES=yes"
if /i "%TYPE%"=="movie" set "IS_SERIES=no"

REM Destination defaults are resolved from config inside the script when not specified
if defined LIST_ONLY (
    if "%DEST%"=="" (
        powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%ANIME%" -isAnimeSeries "%IS_SERIES%" -ListOnly
    ) else (
        powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%ANIME%" -isAnimeSeries "%IS_SERIES%" -Destination "%DEST%" -ListOnly
    )
) else (
    if "%DEST%"=="" (
        powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%ANIME%" -isAnimeSeries "%IS_SERIES%"
    ) else (
        powershell -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%ANIME%" -isAnimeSeries "%IS_SERIES%" -Destination "%DEST%"
    )
)
