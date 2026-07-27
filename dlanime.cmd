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

REM Collect anything starting with "-" as a flag for the PowerShell script
REM (-DryRun, -Interactive, -TrustedOnly, ...) and strip it out of the
REM positional args below, which only understand [series^|movie] [destination].
REM Note "--list" is NOT a flag here: it is handled positionally just below and
REM maps to -ListOnly.
set "FLAGS="
set "POS1="
set "POS2="
set "POS3="
:parse_args
shift
if "%~1"=="" goto :parsed
set "ARG=%~1"
if /i "%ARG%"=="--list" (
    if not defined POS1 ( set "POS1=--list" ) else if not defined POS2 ( set "POS2=--list" ) else set "POS3=--list"
) else if "!ARG:~0,1!"=="-" (
    set "FLAGS=!FLAGS! %1"
) else (
    if not defined POS1 ( set "POS1=%~1" ) else if not defined POS2 ( set "POS2=%~1" ) else set "POS3=%~1"
)
goto :parse_args

:parsed
set "ARG2=%POS1%"
set "ARG3=%POS2%"
set "ARG4=%POS3%"
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
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%ANIME%" -isAnimeSeries "%IS_SERIES%" -ListOnly!FLAGS!
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%ANIME%" -isAnimeSeries "%IS_SERIES%" -Destination "%DEST%" -ListOnly!FLAGS!
    )
) else (
    if "%DEST%"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%ANIME%" -isAnimeSeries "%IS_SERIES%"!FLAGS!
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Query "%ANIME%" -isAnimeSeries "%IS_SERIES%" -Destination "%DEST%"!FLAGS!
    )
)
