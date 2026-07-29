# Shared literals for dlrom.
#
# Everything here is either a vocabulary two or more modules must agree on (job states,
# downloader ids, region names) or a table that encodes an external contract (file
# signatures, ROM extensions, default endpoints). Keeping them in one place is not
# tidiness for its own sake: every one of these used to exist in two or three copies that
# had already drifted apart, and each divergence was a silent bug.
#
# Dot-sourced FIRST by Add-ROM.ps1 - every other module reads from here.
#
# Single-use literals deliberately stay where they are used. This file is for values with
# more than one reader, not a dumping ground.
#
# The EmuDeck defaults below need lib/Platform.ps1. Add-ROM.ps1 loads it first, but the
# tests dot-source this file on its own, so pull it in when it is not already there.

if (-not (Get-Command -Name Test-DlWindows -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/Platform.ps1')
}

# --- Identity / endpoints -----------------------------------------------------

$script:DLROM_SOURCE_NAME = 'retrogametalk'

$RGT_BASE_URL = 'https://retrogametalk.com'
$RGT_REPO_URL = "$RGT_BASE_URL/repo"

# Browser-like headers for every outbound HTTP request, and the User-Agent handed to
# whichever downloader ends up fetching the file. Lives here rather than in the site
# module because Downloaders.ps1 needs it too, and a downloader is not site-specific.
$HTTP_HEADERS = @{
    'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    'Accept-Language' = 'en-US,en;q=0.5'
}

# Loopback, never 'localhost': the name resolves to ::1 first on Windows and a closed
# IPv6 port costs seconds per probe before the IPv4 retry.
$script:LOOPBACK             = '127.0.0.1'
$script:DEFAULT_MOTRIX_RPC   = 'http://localhost:16800/jsonrpc'
$script:DEFAULT_AB_PORT      = 15151
$script:DEFAULT_QBIT_PORT    = 8075
# EmuDeck's install locations. On Linux they come from EmuDeck's own settings.sh, so they
# follow whichever drive it was pointed at (on a Deck that is usually the SD card, not
# $HOME); the literals below are only the fallback for a machine without EmuDeck.
$emuRoms  = Get-DlEmuDeckSetting 'romsPath'
$emuTools = Get-DlEmuDeckSetting 'toolsPath'
if (Test-DlWindows) {
    # Fall back to EmuDeck's own default location, <system drive>\Emulation, derived rather
    # than written out: a literal drive letter here is only ever right on one machine, and
    # anyone whose library lives elsewhere is already covered by the settings lookup above
    # or by romsBase in their config.
    $emuRoot = Join-Path $env:SystemDrive 'Emulation'
    $script:DEFAULT_ROMS_BASE = if ($emuRoms)  { $emuRoms }  else { Join-Path $emuRoot 'roms' }
    $script:DEFAULT_SRM_EXE   = if ($emuTools) { Join-Path $emuTools 'srm.exe' }
                                else { Join-DlPath $emuRoot 'tools' 'srm.exe' }
} else {
    $script:DEFAULT_ROMS_BASE = if ($emuRoms)  { $emuRoms }  else { Join-DlPath (Get-DlHomeDir) 'Emulation' 'roms' }
    $script:DEFAULT_SRM_EXE   = if ($emuTools) { Join-Path $emuTools 'Steam-ROM-Manager.AppImage' }
                                else { Join-DlPath (Get-DlHomeDir) 'Applications' 'Steam-ROM-Manager.AppImage' }
}

# --- Job vocabulary -----------------------------------------------------------
# Written into the job JSON that `dlrom --status --json` serves, so these strings are a
# public contract with anything parsing that output.

$script:JOB_STATUS_PENDING   = 'pending'
$script:JOB_STATUS_RUNNING   = 'running'
$script:JOB_STATUS_COMPLETED = 'completed'
$script:JOB_STATUS_FAILED    = 'failed'
$script:JOB_STATUS_ORPHANED  = 'orphaned'

# Statuses that mean a worker should still be alive; anything else is terminal.
$script:JOB_STATUS_ACTIVE = @($script:JOB_STATUS_RUNNING, $script:JOB_STATUS_PENDING)

$script:JOB_STEP_DOWNLOADING = 'downloading'
$script:JOB_STEP_EXTRACTING  = 'extracting'
$script:JOB_STEP_FILING      = 'filing'
$script:JOB_STEP_STEAM_SYNC  = 'steam-sync'
$script:JOB_STEP_DONE        = 'done'

$script:JOB_KIND_WEB     = $script:DLROM_SOURCE_NAME
$script:JOB_KIND_TORRENT = 'torrent'

# --- Downloader vocabulary ----------------------------------------------------
# Ids are what Find-Downloader returns and what Invoke-FileDownload dispatches on; the
# labels are the single source of the human-readable name, so adding a backend does not
# mean remembering to update a switch in Add-ROM.ps1 as well.

$script:DL_MOTRIX    = 'motrix'
$script:DL_AB        = 'ab'
$script:DL_ARIA2C    = 'aria2c'
$script:DL_CURL      = 'curl'
$script:DL_BITS      = 'bits'
$script:DL_WEBCLIENT = 'webclient'

$script:DOWNLOADER_LABELS = @{
    $script:DL_MOTRIX    = 'Motrix (aria2 RPC)'
    $script:DL_AB        = 'AB Download Manager'
    $script:DL_ARIA2C    = 'aria2c (standalone)'
    $script:DL_CURL      = 'curl'
    $script:DL_BITS      = 'BITS (Background Intelligent Transfer)'
    $script:DL_WEBCLIENT = 'PowerShell Invoke-WebRequest (last resort)'
}

# How often the native tiers (curl, aria2c) stat their output file to report progress.
# One second matches Motrix's poll and is far cheaper than the transfer it is measuring.
$script:NATIVE_POLL_MS = 1000

# Suffixes a download manager leaves on a file that is still being written. Drives both the
# "has AB finished?" check and what --clean recognises as an abandoned transfer.
# .aria2 is aria2's own control file, which Motrix leaves beside every in-flight download.
$script:PARTIAL_EXTS = @('.part', '.tmp', '.download', '.crdownload', '.abdownload', '.bak', '.aria2')

# --- Archives -----------------------------------------------------------------

# Magic numbers, most specific first. One table drives both "is this really an archive?"
# and "which extractor does it need?", which previously disagreed: the type sniffer
# matched a 2-byte zip prefix while the archive test demanded 4, so a file could be
# classified zip yet reported not-an-archive.
$script:ARCHIVE_SIGNATURES = @(
    @{ Type = 'zip'; Hex = @('504B0304', '504B0506', '504B0708') }
    @{ Type = '7z';  Hex = @('377ABCAF271C') }
    @{ Type = 'rar'; Hex = @('526172211A07') }
)

# Container formats 7-Zip can unpack. NOT the same as "things the site serves": a .iso or
# .chd download is a ROM already and must never be handed to an extractor.
$script:ARCHIVE_EXTS = @('.zip', '.7z', '.rar')

# Extensions that can appear as a download on The Repo - archives plus the raw disc images
# it serves uncompressed. Drives the link scraper's filename regex.
$script:DOWNLOAD_EXTS = @('7z', 'zip', 'rar', 'iso', 'bin', 'img', 'chd', 'pbp')

# Alternation fragment for use inside a larger regex, e.g. "\.($DOWNLOAD_EXTS_RX)$".
$script:DOWNLOAD_EXTS_RX = ($script:DOWNLOAD_EXTS -join '|')

# --- ROM extensions -----------------------------------------------------------
#
# ONE list, used both to find a ROM inside an extracted archive and to recognise a raw
# download that needs no extraction. These were two lists that disagreed by seven
# extensions, so an archive containing a .gdi/.rvz/.wbfs extracted fine and then reported
# "no ROM file found". The list also predates the move to The Repo and covered only the
# consoles cdromance carried; everything below is reachable from PLATFORM_SLUGS.
$script:ROM_EXTS = @(
    # Disc images (PS1/PS2/PSP/GC/Wii/Saturn/Sega CD/Dreamcast/3DO/PC-FX/TG-CD/Neo Geo CD)
    '.iso', '.bin', '.cue', '.img', '.chd', '.pbp', '.cso', '.gdi', '.cdi',
    '.rvz', '.wbfs', '.gcm', '.nrg', '.mdf', '.ccd'
    # Nintendo cartridges
    '.nds', '.gba', '.gb', '.gbc', '.nes', '.fds', '.sfc', '.smc', '.z64', '.n64', '.v64'
    # Sega cartridges
    '.md', '.gen', '.smd', '.32x', '.sms', '.gg'
    # Other handhelds / micros
    '.ws', '.wsc', '.ngp', '.ngc', '.pce', '.vpk', '.adf', '.d88', '.fdi', '.rom', '.dsk'
)

# --- Release markers ----------------------------------------------------------
#
# One reject list, previously three that disagreed: link selection dropped
# demo/trial/sampler/preview, the torrent matcher also rejected beta/proto/kiosk/promo,
# and serial resolution used a third set. Same intent everywhere - not the game you asked
# for - so it is now the union.
$script:DEMO_RX = '(?i)\b(demo|trade\s*demo|beta|proto|prototype|sample|sampler|kiosk|promo|trial|preview|test\s*disc)\b'

# Different content from the base release: only wanted when the query asks for it.
$script:EDITION_KW = @('fes', 'undub', 'append', 'goty', 'game of the year', 'directors cut', 'director cut',
                       'collector', 'collectors', 'deluxe', 'complete', 'premium', 'limited edition')

# Same content, different printing: allowed, but a base release wins.
$script:BUDGET_KW = @('greatest hits', 'players choice', 'the best', 'platinum', 'not for resale', 'reprint')

# A release that has been modified - preferred against when a clean dump exists.
$script:HACK_RX = '(?i)(\bhack\b|\bmod\b|\bpatch\b|controllable|-hack)'

# Language markers worth preferring in a filename.
$script:ENGLISH_RX = '(?i)\b(english|undub|undubbed|patched|dub)\b|\(eng\)'

# --- PS Vita builds -----------------------------------------------------------
#
# The Repo publishes most Vita titles TWICE, and the two files are not interchangeable:
#
#   [NoNpDrm]  a dump for real hardware, installed on a modded Vita via the NoNpDrm plugin
#   [Vita3K]   the same game repacked for the Vita3K emulator
#
# Picking the wrong one fails silently: it downloads and files perfectly well, and then
# simply will not run. No other platform here has that split, which is why Vita gets its
# own vocabulary rather than another entry in the generic preference lists.
#
# The markers ride in brackets or parentheses, in whatever casing the uploader felt like -
# the live catalogue currently carries [vita3k], [Vita3k], (Vita3k), [NoNpDrm], [NoNpDRM],
# (NoNPDrm) and [nonpdrm] - so both patterns are case-insensitive and tolerate the internal
# spacing. Order on the page is not stable either (either build can come first), so nothing
# may infer the build from position.
$script:VITA_SLUG = 'vita'

$script:VITA_BUILD_EMU     = 'emu'       # Vita3K
$script:VITA_BUILD_CONSOLE = 'console'   # NoNpDrm / MaiDump, real hardware
$script:VITA_BUILD_ANY     = 'any'       # no preference - fall through to the usual rules

# Emulation is the common case, so an unqualified Vita download prefers Vita3K.
$script:VITA_BUILD_DEFAULT = $script:VITA_BUILD_EMU

$script:VITA_EMU_RX     = '(?i)\bvita\s*3\s*k\b'
$script:VITA_CONSOLE_RX = '(?i)\bno\s*np\s*drm\b|\bmai\s*dump\b'

# --vita synonyms -> canonical build. Same shape as REGION_ALIASES.
$script:VITA_BUILD_ALIASES = @(
    @{ Code = 'emu';     Rx = '^(emu|emulator|vita3k|vita-3k|3k)$'                     }
    @{ Code = 'console'; Rx = '^(console|hardware|hw|real|handheld|nonpdrm|no-npdrm)$' }
    @{ Code = 'any';     Rx = '^(any|both|either)$'                                    }
)

# The single source of each build's human-readable name, for logs and the result block.
$script:VITA_BUILD_LABELS = @{
    'emu'     = 'Vita3K (emulator)'
    'console' = 'NoNpDrm (console)'
    'any'     = 'no preference'
}

# --- Regions ------------------------------------------------------------------

# Canonical region codes. Order is the fallback preference when the caller did not ask
# for one: an American dump first, then the widest release, then PAL, then the original.
$script:REGION_PREFERENCE = @('usa', 'world', 'europe', 'japan', 'korea', 'asia')

# --region synonyms -> canonical code.
$script:REGION_ALIASES = @(
    @{ Code = 'usa';    Rx = '^(usa|us|ntsc-?u|america|american)$' }
    @{ Code = 'europe'; Rx = '^(europe|eu|pal|uk|england)$'        }
    @{ Code = 'japan';  Rx = '^(japan|jp|ntsc-?j|jpn)$'            }
    @{ Code = 'world';  Rx = '^(world)$'                           }
    @{ Code = 'korea';  Rx = '^(korea|kr)$'                        }
)

# Canonical code -> the region string PCSX2's GameIndex.yaml uses.
$script:PS2_REGION_CODES = @{
    'usa'    = 'NTSC-U'
    'europe' = 'PAL'
    'japan'  = 'NTSC-J'
    'korea'  = 'NTSC-K'
    'world'  = 'NTSC-U'
}

# --- Rendering ----------------------------------------------------------------

$script:PROGRESS_BAR_WIDTH = 20
