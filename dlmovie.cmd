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

REM Arg 2 onward: a bare word is the destination, anything starting with "-" is a
REM flag for the PowerShell script (-DryRun, -Interactive, -MaxResults N, ...).
REM Without this split, "dlmovie \"Movie Name\" -DryRun" passed -DryRun as the
REM destination and PowerShell rejected it as a missing -Destination argument.
set "MOVIE=%~1"
set "DEST="
set "FLAGS="

:parse_args
shift
if "%~1"=="" goto :run
set "ARG=%~1"
if "!ARG:~0,1!"=="-" (
    set "FLAGS=!FLAGS! %1"
) else (
    if not defined DEST set "DEST=%~1"
)
goto :parse_args

:run
set "PS_ARGS=-Query "%MOVIE%""
if defined DEST set "PS_ARGS=!PS_ARGS! -Destination "%DEST%""
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" !PS_ARGS!!FLAGS!
exit /b %ERRORLEVEL%
