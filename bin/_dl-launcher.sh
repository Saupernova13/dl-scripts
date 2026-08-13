# Shared body for the Linux launchers in this directory. Sourced, never executed.
#
# These live in bin/ because the repo root already holds DIRECTORIES named dlrom, dlgame,
# dlmovie, dltv and dlanime. On Windows PATHEXT still resolves `dlrom` to dlrom.cmd, but on
# Linux the directory would shadow a launcher of the same name. Put bin/ on PATH:
#
#   export PATH="$PATH:/path/to/dl-scripts/bin"
#
# Every launcher speaks one argument style: kebab-case double-dash flags, translated here into
# the PowerShell parameters the scripts declare. Native -PascalCase flags are still accepted so
# older invocations keep working, but they are not the documented way in.
#
# Each launcher sets, before sourcing:
#
#   PS_SCRIPT          path to the Add-*.ps1 it drives
#   DL_POSITIONALS     PowerShell parameter names for the bare words, in order
#                      ("Query Destination")
#   DL_FLAG_SWITCHES   valid --kebab:Param pairs for flags taking no value
#   DL_FLAG_VALUES     valid --kebab:Param pairs for flags taking a value
#   DL_ANIME_TYPE      1 only for dlanime, whose second bare word may be series|movie
#   dl_usage()         a function printing the usage block

if [ ! -f "$PS_SCRIPT" ]; then
    echo "[ERROR] Script not found: $PS_SCRIPT" >&2
    exit 1
fi

# PowerShell 7. On an immutable OS like SteamOS a tarball in $HOME is the normal case; check
# PATH first so a system-wide install still wins. DL_PWSH pins one when several are present.
PWSH="${DL_PWSH:-}"
[ -n "$PWSH" ] || PWSH=$(command -v pwsh 2>/dev/null || true)
if [ -z "$PWSH" ]; then
    for candidate in "$HOME/.local/pwsh/pwsh" "$HOME/powershell/pwsh" /opt/microsoft/powershell/7/pwsh; do
        if [ -x "$candidate" ]; then PWSH="$candidate"; break; fi
    done
fi
if [ -z "$PWSH" ]; then
    echo "[ERROR] PowerShell 7 (pwsh) not found." >&2
    echo "Install it without root:" >&2
    echo "  mkdir -p ~/.local/pwsh" >&2
    echo "  curl -sL https://github.com/PowerShell/PowerShell/releases/latest/download/powershell-linux-x64.tar.gz | tar zx -C ~/.local/pwsh" >&2
    exit 1
fi

# Look "$2" up in the --kebab:Param table "$1"; print the parameter name on a hit.
dl_lookup() {
    for _pair in $1; do
        case $_pair in
            "$2":*) printf '%s' "${_pair#*:}"; return 0 ;;
        esac
    done
    return 1
}

# Native PowerShell flags that consume the word after them. Without this list that word looks
# like a bare argument, and `dlmovie Name -MaxResults 5` treats 5 as the destination.
dl_raw_takes_value() {
    case $1 in
        -Destination|-QbitHost|-MaxResults|-Filter|-Platform|-Region|-Sort|-VitaBuild| \
        -TorrentPick|-Status|-JobFile|-Dest)
            return 0 ;;
    esac
    return 1
}

# Consume from the front of "$@", append to the back, stop at a sentinel marking where the
# original list ended. Every value stays a real positional parameter, so a title with spaces
# or quotes needs no escaping and no eval.
dl_sentinel='--dl-args-end--'
dl_pos_n=0
set -- "$@" "$dl_sentinel"

while [ "$1" != "$dl_sentinel" ]; do
    dl_arg=$1
    shift

    case $dl_arg in
        -h|--help|-\?)
            dl_usage
            exit 0
            ;;
        --*)
            if dl_param=$(dl_lookup "${DL_FLAG_VALUES:-}" "$dl_arg"); then
                if [ "$1" = "$dl_sentinel" ]; then
                    echo "[ERROR] $dl_arg expects a value" >&2
                    exit 1
                fi
                dl_value=$1
                shift
                set -- "$@" "-$dl_param" "$dl_value"
            elif dl_param=$(dl_lookup "${DL_FLAG_SWITCHES:-}" "$dl_arg"); then
                set -- "$@" "-$dl_param"
            else
                # Forwarding a typo to PowerShell reports it as a missing parameter, which
                # reads like the script is broken rather than the command being wrong.
                echo "[ERROR] Unknown option: $dl_arg" >&2
                dl_usage >&2
                exit 1
            fi
            ;;
        -*)
            set -- "$@" "$dl_arg"
            if dl_raw_takes_value "$dl_arg" && [ "$1" != "$dl_sentinel" ]; then
                dl_value=$1
                shift
                set -- "$@" "$dl_value"
            fi
            ;;
        *)
            dl_pos_n=$((dl_pos_n + 1))

            # dlanime only: the optional second bare word selects series or movie, anything
            # else there is the destination. Consuming a type undoes the increment, so a
            # destination after it still lands in the second slot.
            if [ "${DL_ANIME_TYPE:-0}" = 1 ] && [ "$dl_pos_n" = 2 ]; then
                case $dl_arg in
                    series) set -- "$@" -isAnimeSeries yes; dl_pos_n=1; continue ;;
                    movie)  set -- "$@" -isAnimeSeries no;  dl_pos_n=1; continue ;;
                esac
            fi

            dl_slot=0
            for dl_name in $DL_POSITIONALS; do
                dl_slot=$((dl_slot + 1))
                if [ "$dl_slot" = "$dl_pos_n" ]; then
                    set -- "$@" "-$dl_name" "$dl_arg"
                    break
                fi
            done
            ;;
    esac
done
shift   # drop the sentinel; what remains is the translated argument vector

exec "$PWSH" -NoProfile -File "$PS_SCRIPT" "$@"
