# Shared body for the Linux launchers in this directory. Sourced, never executed.
#
# Each launcher sets PS_SCRIPT, DL_ARG_STYLE and (for the kebab style) VALUE_FLAGS, then
# sources this file. Finding pwsh, translating arguments and quoting all happen once here.
#
# These live in bin/ because the repo root already holds DIRECTORIES named dlrom, dlgame,
# dlmovie, dltv and dlanime. On Windows PATHEXT still resolves `dlrom` to dlrom.cmd, but on
# Linux the directory would shadow a launcher of the same name. Put bin/ on PATH:
#
#   export PATH="$PATH:/path/to/dl-scripts/bin"
#
# Two argument styles, because the wrappers genuinely differ and pretending otherwise would
# break one of them:
#
#   kebab       dlrom's convention - `--platform ps2` becomes `-Platform ps2`.
#   passthrough dlgame/dlmovie/dltv/dlanime - `dlgame "Name" [destination]` plus PowerShell
#               flags forwarded verbatim (-DryRun, -Interactive, -MaxResults 5).

if [ ! -f "$PS_SCRIPT" ]; then
    echo "[ERROR] Script not found: $PS_SCRIPT" >&2
    exit 1
fi

# PowerShell 7. On an immutable OS like SteamOS there is no package to install, so a
# tarball extracted into $HOME is the normal case; check PATH first so a system-wide
# install still wins. DL_PWSH pins a specific interpreter when several are present.
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

dl_value_flag() {
    for _f in ${VALUE_FLAGS:-}; do
        [ "$1" = "$_f" ] && return 0
    done
    return 1
}

# --kebab-case -> -PascalCase, plus the few parameter names that differ from their flag.
dl_to_param() {
    case "$1" in
        --dest)        printf 'Destination'; return 0 ;;
        --vita)        printf 'VitaBuild';   return 0 ;;
        --list|--jobs) printf 'ListJobs';    return 0 ;;
        --clear)       printf 'Clean';       return 0 ;;
    esac
    printf '%s' "${1#--}" |
        awk -F- '{ for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2) }'
}

# Translate in place: consume from the front of "$@", append the result to the back, and
# stop at a sentinel marking where the original list ended. Every value stays in a real
# positional parameter, so a title with spaces or quotes needs no escaping and no eval.
dl_sentinel='--dl-args-end--'
dl_query_taken=0
dl_dest_taken=0
dl_prev_was_flag=0
set -- "$@" "$dl_sentinel"

while [ "$1" != "$dl_sentinel" ]; do
    dl_arg=$1
    shift
    case "$dl_arg" in
        -h|--help)
            dl_usage
            exit 0
            ;;
    esac

    if [ "${DL_ARG_STYLE:-kebab}" = passthrough ]; then
        case "$dl_arg" in
            -*)
                # A PowerShell flag: forward it untouched. Remember it, because the next
                # bare word may be its value (-MaxResults 5) rather than the destination.
                set -- "$@" "$dl_arg"
                dl_prev_was_flag=1
                ;;
            *)
                if [ "$dl_prev_was_flag" = 1 ]; then
                    set -- "$@" "$dl_arg"          # value of the flag before it
                elif [ "$dl_query_taken" = 0 ]; then
                    set -- "$@" -Query "$dl_arg"
                    dl_query_taken=1
                elif [ "$dl_dest_taken" = 0 ]; then
                    set -- "$@" -Destination "$dl_arg"
                    dl_dest_taken=1
                fi
                dl_prev_was_flag=0
                ;;
        esac
        continue
    fi

    case "$dl_arg" in
        --*)
            dl_param=$(dl_to_param "$dl_arg")
            if dl_value_flag "$dl_arg"; then
                if [ "$1" = "$dl_sentinel" ]; then
                    echo "[ERROR] $dl_arg expects a value" >&2
                    exit 1
                fi
                dl_value=$1
                shift
                set -- "$@" "-$dl_param" "$dl_value"
            else
                set -- "$@" "-$dl_param"
            fi
            ;;
        *)
            # The first bare argument is the query; the batch wrappers ignore any further
            # ones rather than silently searching for a concatenation, so match that.
            if [ "$dl_query_taken" = 0 ]; then
                set -- "$@" -Query "$dl_arg"
                dl_query_taken=1
            fi
            ;;
    esac
done
shift   # drop the sentinel; what remains is the translated argument vector

exec "$PWSH" -NoProfile -File "$PS_SCRIPT" "$@"
