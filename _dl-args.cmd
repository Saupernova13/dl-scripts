@echo off
REM Shared argument parser for the Windows launchers (dlanime, dlgame, dlmovie, dltv).
REM Called, never run directly. dlrom.cmd parses its own arguments because it carries a
REM much larger flag surface, but it speaks the same vocabulary.
REM
REM Every launcher accepts kebab-case double-dash flags, which is the one style documented
REM for humans and agents. PowerShell's native -PascalCase flags still work so older
REM invocations and scripts do not break.
REM
REM Contract - the caller runs:
REM
REM     call "%~dp0_dl-args.cmd" %*
REM
REM Sets, in the caller's environment:
REM     DL_POS1 DL_POS2 DL_POS3   bare words in the order given (query, then whatever the
REM                               launcher defines positionally)
REM     DL_FLAGS                  translated flags, ready to append to the PowerShell
REM                               command line (each already space-prefixed)
REM     DL_ARGS_ERROR             set when an option was rejected; the caller must stop
REM     DL_ARGS_HELP              set when help was asked for
REM
REM Reads, before being called:
REM     DL_LIST_PARAM             PowerShell switch that --list maps to. Defaults to
REM                               DryRun; dlanime sets ListOnly for its longer listing.
REM
REM Style note: every branch below is a plain "if ... goto :label", and no jump leaves a
REM parenthesised block. An earlier draft set the flag inline - ( set ... & goto ... ) -
REM and "dlmovie X --interactive" came back with a phantom -Filter "" appended, as though
REM control had resumed inside the :dl_val_filter block. That is the byte-offset goto seek
REM .gitattributes warns about: it depends on where labels land in the file, so it survives
REM being "fixed" by an unrelated edit and comes back later. One statement per label keeps
REM the branches short and uniform, which is the cheapest defence available in batch.

set "DL_POS1="
set "DL_POS2="
set "DL_POS3="
set "DL_FLAGS="
set "DL_ARGS_ERROR="
set "DL_ARGS_HELP="
if not defined DL_LIST_PARAM set "DL_LIST_PARAM=DryRun"

REM One shift happens at the top of every iteration. Only the value-taking flags shift
REM again, to consume the argument that belongs to them.
:dl_args_loop
if "%~1"=="" goto :dl_args_done
set "DL_ARG=%~1"
shift

if /i "%DL_ARG%"=="--help"          goto :dl_sw_help
if /i "%DL_ARG%"=="-h"              goto :dl_sw_help
if    "%DL_ARG%"=="-?"              goto :dl_sw_help

REM --- kebab flags taking a value ---
if /i "%DL_ARG%"=="--dest"          goto :dl_val_dest
if /i "%DL_ARG%"=="--destination"   goto :dl_val_dest
if /i "%DL_ARG%"=="--qbit-host"     goto :dl_val_qbit
if /i "%DL_ARG%"=="--max-results"   goto :dl_val_max
if /i "%DL_ARG%"=="--filter"        goto :dl_val_filter

REM --- kebab switches ---
if /i "%DL_ARG%"=="--dry-run"       goto :dl_sw_dryrun
if /i "%DL_ARG%"=="--dryrun"        goto :dl_sw_dryrun
if /i "%DL_ARG%"=="--links-only"    goto :dl_sw_dryrun
if /i "%DL_ARG%"=="--list"          goto :dl_sw_list
if /i "%DL_ARG%"=="--interactive"   goto :dl_sw_interactive
if /i "%DL_ARG%"=="--trusted-only"  goto :dl_sw_trusted

REM An unrecognised kebab flag is a typo, not something to hand to PowerShell: forwarded,
REM it surfaces as "a parameter cannot be found that matches parameter name '-dry-runn'",
REM which reads like the script is broken rather than the command being wrong.
if "%DL_ARG:~0,2%"=="--"            goto :dl_unknown_flag

REM --- a native PowerShell flag: forward it untouched ---
if "%DL_ARG:~0,1%"=="-"             goto :dl_raw_flag

REM --- a bare word: fills the next free positional slot ---
if not defined DL_POS1              goto :dl_pos1
if not defined DL_POS2              goto :dl_pos2
if not defined DL_POS3              goto :dl_pos3
goto :dl_args_loop

:dl_sw_help
set "DL_ARGS_HELP=1"
goto :dl_args_loop

:dl_sw_dryrun
set "DL_FLAGS=%DL_FLAGS% -DryRun"
goto :dl_args_loop

:dl_sw_list
set "DL_FLAGS=%DL_FLAGS% -%DL_LIST_PARAM%"
goto :dl_args_loop

:dl_sw_interactive
set "DL_FLAGS=%DL_FLAGS% -Interactive"
goto :dl_args_loop

:dl_sw_trusted
set "DL_FLAGS=%DL_FLAGS% -TrustedOnly"
goto :dl_args_loop

:dl_val_dest
set "DL_FLAGS=%DL_FLAGS% -Destination "%~1""
shift
goto :dl_args_loop

:dl_val_qbit
set "DL_FLAGS=%DL_FLAGS% -QbitHost "%~1""
shift
goto :dl_args_loop

:dl_val_max
set "DL_FLAGS=%DL_FLAGS% -MaxResults %~1"
shift
goto :dl_args_loop

:dl_val_filter
set "DL_FLAGS=%DL_FLAGS% -Filter "%~1""
shift
goto :dl_args_loop

REM A native flag that takes a value must swallow the word after it, or that word would be
REM mistaken for a positional - which is how "dlmovie Name -MaxResults 5" used to end up
REM treating 5 as the destination.
:dl_raw_flag
set "DL_FLAGS=%DL_FLAGS% %DL_ARG%"
set "DL_TAKES_VALUE="
if /i "%DL_ARG%"=="-Destination" set "DL_TAKES_VALUE=1"
if /i "%DL_ARG%"=="-QbitHost"    set "DL_TAKES_VALUE=1"
if /i "%DL_ARG%"=="-MaxResults"  set "DL_TAKES_VALUE=1"
if /i "%DL_ARG%"=="-Filter"      set "DL_TAKES_VALUE=1"
if not defined DL_TAKES_VALUE goto :dl_args_loop
set "DL_FLAGS=%DL_FLAGS% "%~1""
shift
goto :dl_args_loop

:dl_pos1
set "DL_POS1=%DL_ARG%"
goto :dl_args_loop

:dl_pos2
set "DL_POS2=%DL_ARG%"
goto :dl_args_loop

:dl_pos3
set "DL_POS3=%DL_ARG%"
goto :dl_args_loop

:dl_unknown_flag
echo [ERROR] Unknown option: %DL_ARG% >&2
echo Valid options: --dry-run --list --interactive --trusted-only --dest PATH >&2
echo                --max-results N --filter TEXT --qbit-host URL --help >&2
set "DL_ARGS_ERROR=1"
goto :eof

:dl_args_done
set "DL_ARG="
set "DL_TAKES_VALUE="
goto :eof
