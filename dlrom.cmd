@echo off
REM dlrom - Download ROMs from cdromance.org via Motrix
REM Usage: dlrom "Game Name" [--platform PLATFORM] [--region REGION] [--sort SORT] [--interactive] [--no-extract] [--dest PATH]
REM
REM Platforms: ps2, ps1, psp, vita, n64, gamecube, nds, gba, snes, nes, gbc, gb, dreamcast, saturn, wii, 3ds
REM Regions:   usa, europe, japan, world
REM
REM Examples:
REM   dlrom "Rayman 2"
REM   dlrom "Final Fantasy VII" --platform ps1
REM   dlrom "Metal Slug" --platform ps2 --region usa
REM   dlrom "Zelda" --platform n64 --interactive

if "%~1"=="" (
    echo Usage: dlrom "Game Name" [--platform PLATFORM] [--region REGION] [--sort SORT] [--interactive] [--no-extract]
    echo.
    echo Platforms: ps2, ps1, psp, vita, n64, gamecube, nds, gba, snes, nes, gbc, gb, dreamcast, saturn, wii, 3ds
    echo Regions:   usa, europe, japan, world
    echo.
    echo Examples:
    echo   dlrom "Rayman 2"
    echo   dlrom "Final Fantasy VII" --platform ps1
    echo   dlrom "Metal Slug" --platform ps2 --region usa
    echo   dlrom "Zelda" --platform n64 --interactive
    exit /b 1
)

set "SCRIPT=%~dp0dlrom\Add-ROM.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-ROM.ps1 exists in the dlrom subfolder.
    exit /b 1
)

set "QUERY=%~1"
set "PLATFORM="
set "REGION="
set "SORT="
set "DEST="
set "INTERACTIVE="
set "NO_EXTRACT="

:shift_args
shift
if "%~1"=="" goto :build_cmd
if /i "%~1"=="--platform"    goto :set_platform
if /i "%~1"=="--region"      goto :set_region
if /i "%~1"=="--sort"        goto :set_sort
if /i "%~1"=="--dest"        goto :set_dest
if /i "%~1"=="--interactive" ( set "INTERACTIVE=1" & goto :shift_args )
if /i "%~1"=="--no-extract"  ( set "NO_EXTRACT=1"  & goto :shift_args )
goto :shift_args

:set_platform
shift
set "PLATFORM=%~1"
goto :shift_args

:set_region
shift
set "REGION=%~1"
goto :shift_args

:set_sort
shift
set "SORT=%~1"
goto :shift_args

:set_dest
shift
set "DEST=%~1"
goto :shift_args

:build_cmd
set "PS_ARGS=-Query "%QUERY%""
if defined PLATFORM    set "PS_ARGS=%PS_ARGS% -Platform "%PLATFORM%""
if defined REGION      set "PS_ARGS=%PS_ARGS% -Region "%REGION%""
if defined SORT        set "PS_ARGS=%PS_ARGS% -Sort "%SORT%""
if defined DEST        set "PS_ARGS=%PS_ARGS% -Destination "%DEST%""
if defined INTERACTIVE set "PS_ARGS=%PS_ARGS% -Interactive"
if defined NO_EXTRACT  set "PS_ARGS=%PS_ARGS% -NoExtract"

powershell -ExecutionPolicy Bypass -File "%SCRIPT%" %PS_ARGS%
