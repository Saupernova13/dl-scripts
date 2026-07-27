@echo off
REM dlrom - Download ROMs from RetroGameTalk's Repo and install them to your emulator folders
REM Usage: dlrom "Game Name" [--platform PLATFORM] [--region REGION] [--vita emu|console] [--sort SORT] [--dest PATH] [--wait] [--interactive] [--no-extract] [--no-steam] [--links-only] [--json] [--verbose] [--quiet]
REM        dlrom --status <jobId> [--json]
REM        dlrom --list [--json]
REM        dlrom --clean [--all] [--dry-run] [--json]
REM
REM --clean reclaims what dlrom is holding: interrupted downloads, extraction working dirs,
REM abandoned partials, the saved debug page and rebuildable caches. Files a running job is
REM downloading are never touched. --all also clears finished job records and logs.
REM
REM Downloads run in the BACKGROUND by default: dlrom searches, resolves the links, spawns
REM a worker and returns a job id straight away. Follow it with --status; use --wait only
REM when you actually want to sit and watch the transfer.
REM
REM Source: https://retrogametalk.com/repo/ (the former cdromance catalogue). No account
REM is required - The Repo serves anonymous clients in full.
REM
REM Platforms: ps2, ps1/psx, psp, eboot, vita, n64, gamecube, wii, nds, gba, snes, nes, fds,
REM            gbc, gb, dreamcast, saturn, segacd, genesis, 32x, sms, gamegear, pico, 3do,
REM            amiga, arcade, msx, dos, windows, scummvm, neogeocd, ngp, pc88, pc98, pcfx,
REM            tg16, tgcd, wonderswan
REM Regions:   usa, europe, japan, world
REM
REM PS Vita games are published twice - [NoNpDrm] for a modded console and [Vita3K] for the
REM emulator. dlrom takes the Vita3K build by default and leaves the archive zipped (that is
REM what the emulator imports). Use --vita console for a real Vita.
REM
REM Examples:
REM   dlrom "Rayman 2"
REM   dlrom "Final Fantasy VII" --platform ps1
REM   dlrom "Danganronpa V3" --platform vita             (Vita3K build)
REM   dlrom "Danganronpa V3" --platform vita --vita console
REM   dlrom --status a3f9c21b8e04
REM   dlrom --list

set "SCRIPT=%~dp0dlrom\Add-ROM.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Script not found: %SCRIPT%
    echo Please ensure Add-ROM.ps1 exists in the dlrom subfolder.
    exit /b 1
)

REM --- job queries and housekeeping: these carry no game name, so handle them before
REM     %1 becomes the query ---
if /i "%~1"=="--list"   goto :job_list
if /i "%~1"=="-list"    goto :job_list
if /i "%~1"=="--jobs"   goto :job_list
if /i "%~1"=="--status" goto :job_status
if /i "%~1"=="-status"  goto :job_status
if /i "%~1"=="--clean"  goto :do_clean
if /i "%~1"=="-clean"   goto :do_clean
if /i "%~1"=="--clear"  goto :do_clean

if "%~1"=="" (
    echo Usage: dlrom "Game Name" [--platform PLATFORM] [--region REGION] [--vita emu^|console] [--sort SORT] [--dest PATH] [--wait] [--interactive] [--no-extract] [--no-steam] [--links-only] [--json] [--verbose] [--quiet]
    echo        dlrom --status ^<jobId^> [--json]
    echo        dlrom --list [--json]
    echo        dlrom --clean [--all] [--dry-run] [--json]
    echo.
    echo Downloads run in the BACKGROUND by default and return a job id immediately.
    echo.
    echo Platforms: ps2, ps1/psx, psp, eboot, vita, n64, gamecube, wii, nds, gba, snes, nes,
    echo            fds, gbc, gb, dreamcast, saturn, segacd, genesis, 32x, sms, gamegear, pico,
    echo            3do, amiga, arcade, msx, dos, windows, scummvm, neogeocd, ngp, pc88, pc98,
    echo            pcfx, tg16, tgcd, wonderswan
    echo Regions:   usa, europe, japan, world
    echo.
    echo PS Vita games ship as two builds: [Vita3K] for the emulator and [NoNpDrm] for a
    echo modded console. dlrom takes Vita3K by default and leaves that archive zipped.
    echo.
    echo   --vita emu     PS Vita: take the Vita3K build - the default, kept as a .zip
    echo   --vita console PS Vita: take the NoNpDrm build for real hardware
    echo   --vita any     PS Vita: no preference, take whatever is listed first
    echo   --wait         stay in the foreground until the ROM is installed
    echo   --status ID    show progress for a job
    echo   --list         list recent jobs
    echo   --clean        delete temp files, abandoned partials and caches
    echo                  add --all for job history, --dry-run to preview
    echo   --json         machine-readable output
    echo   --interactive  pick from the results list instead of auto-selecting
    echo   --no-extract   keep the downloaded archive; do not extract or install
    echo   --no-steam     skip adding the download to Steam via Steam ROM Manager
    echo   --links-only   resolve and print the download links, then stop without downloading
    echo   --no-torrent   disable the PS2 torrent fallback used when RetroGameTalk fails
    echo   --torrent-pick N   force a specific file index from the PS2 archive torrent
    echo   --verbose      show detailed step-by-step debug output
    echo   --quiet        show only results, warnings and errors
    echo.
    echo Examples:
    echo   dlrom "Rayman 2"
    echo   dlrom "Final Fantasy VII" --platform ps1
    echo   dlrom "Metal Slug" --platform ps2 --region usa
    echo   dlrom "Danganronpa V3" --platform vita
    echo   dlrom "Danganronpa V3" --platform vita --vita console
    echo   dlrom --status a3f9c21b8e04
    exit /b 1
)

set "QUERY=%~1"
set "PLATFORM="
set "REGION="
set "VITA="
set "SORT="
set "DEST="
set "INTERACTIVE="
set "NO_EXTRACT="
set "NO_STEAM="
set "LINKS_ONLY="
set "VERBOSE="
set "QUIET="
set "NO_TORRENT="
set "TORRENT_PICK="
set "WAIT="
set "JSON="

:shift_args
shift
if "%~1"=="" goto :build_cmd
if /i "%~1"=="--platform"     goto :set_platform
if /i "%~1"=="--region"       goto :set_region
if /i "%~1"=="--vita"         goto :set_vita
if /i "%~1"=="--sort"         goto :set_sort
if /i "%~1"=="--dest"         goto :set_dest
if /i "%~1"=="--torrent-pick" goto :set_torrent_pick
if /i "%~1"=="--interactive"  ( set "INTERACTIVE=1" & goto :shift_args )
if /i "%~1"=="--no-extract"   ( set "NO_EXTRACT=1"  & goto :shift_args )
if /i "%~1"=="--no-steam"     ( set "NO_STEAM=1"    & goto :shift_args )
if /i "%~1"=="--links-only"   ( set "LINKS_ONLY=1"  & goto :shift_args )
if /i "%~1"=="--no-torrent"   ( set "NO_TORRENT=1"  & goto :shift_args )
if /i "%~1"=="--wait"         ( set "WAIT=1"        & goto :shift_args )
if /i "%~1"=="--json"         ( set "JSON=1"        & goto :shift_args )
if /i "%~1"=="--verbose"      ( set "VERBOSE=1"     & goto :shift_args )
if /i "%~1"=="--quiet"        ( set "QUIET=1"       & goto :shift_args )
goto :shift_args

:set_platform
shift
set "PLATFORM=%~1"
goto :shift_args

:set_region
shift
set "REGION=%~1"
goto :shift_args

:set_vita
shift
set "VITA=%~1"
goto :shift_args

:set_sort
shift
set "SORT=%~1"
goto :shift_args

:set_dest
shift
set "DEST=%~1"
goto :shift_args

:set_torrent_pick
shift
set "TORRENT_PICK=%~1"
goto :shift_args

:build_cmd
set "PS_ARGS=-Query "%QUERY%""
if defined PLATFORM    set "PS_ARGS=%PS_ARGS% -Platform "%PLATFORM%""
if defined REGION      set "PS_ARGS=%PS_ARGS% -Region "%REGION%""
if defined VITA        set "PS_ARGS=%PS_ARGS% -VitaBuild "%VITA%""
if defined SORT        set "PS_ARGS=%PS_ARGS% -Sort "%SORT%""
if defined DEST        set "PS_ARGS=%PS_ARGS% -Destination "%DEST%""
if defined INTERACTIVE set "PS_ARGS=%PS_ARGS% -Interactive"
if defined NO_EXTRACT  set "PS_ARGS=%PS_ARGS% -NoExtract"
if defined NO_STEAM    set "PS_ARGS=%PS_ARGS% -NoSteam"
if defined LINKS_ONLY  set "PS_ARGS=%PS_ARGS% -LinksOnly"
if defined NO_TORRENT  set "PS_ARGS=%PS_ARGS% -NoTorrent"
if defined TORRENT_PICK set "PS_ARGS=%PS_ARGS% -TorrentPick %TORRENT_PICK%"
if defined WAIT        set "PS_ARGS=%PS_ARGS% -Wait"
if defined JSON        set "PS_ARGS=%PS_ARGS% -Json"
if defined VERBOSE     set "PS_ARGS=%PS_ARGS% -Verbose"
if defined QUIET       set "PS_ARGS=%PS_ARGS% -Quiet"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %PS_ARGS%
exit /b %ERRORLEVEL%

:job_list
set "PS_ARGS=-ListJobs"
if /i "%~2"=="--json" set "PS_ARGS=%PS_ARGS% -Json"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %PS_ARGS%
exit /b %ERRORLEVEL%

:job_status
if "%~2"=="" (
    echo Usage: dlrom --status ^<jobId^>
    echo Run "dlrom --list" to see recent job ids.
    exit /b 1
)
set "PS_ARGS=-Status "%~2""
if /i "%~3"=="--json" set "PS_ARGS=%PS_ARGS% -Json"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %PS_ARGS%
exit /b %ERRORLEVEL%

REM --- housekeeping: --clean [--all] [--dry-run] [--json] in any order ---
:do_clean
set "PS_ARGS=-Clean"
:clean_args
shift
if "%~1"=="" goto :clean_run
if /i "%~1"=="--all"     ( set "PS_ARGS=%PS_ARGS% -All"    & goto :clean_args )
if /i "%~1"=="--dry-run" ( set "PS_ARGS=%PS_ARGS% -DryRun" & goto :clean_args )
if /i "%~1"=="--dryrun"  ( set "PS_ARGS=%PS_ARGS% -DryRun" & goto :clean_args )
if /i "%~1"=="-n"        ( set "PS_ARGS=%PS_ARGS% -DryRun" & goto :clean_args )
if /i "%~1"=="--json"    ( set "PS_ARGS=%PS_ARGS% -Json"   & goto :clean_args )
if /i "%~1"=="--verbose" ( set "PS_ARGS=%PS_ARGS% -Verbose" & goto :clean_args )
goto :clean_args
:clean_run
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %PS_ARGS%
exit /b %ERRORLEVEL%
