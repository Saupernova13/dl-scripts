# Telegram MTProto - TL schema parser.
#
# Reads Telegram Desktop's api.tl and mtproto.tl (lib/Telegram/schema/) into lookup tables the
# codec drives. The scan is deliberately cheap: one pass of string slicing records every
# constructor's name, id, result type and the RAW parameter text. Parameters are only split
# into fields the first time a constructor is actually used, so loading the ~3000 line layer
# costs tens of milliseconds and needs no on-disk cache.
#
# Shape of the tables (all in $script:TG_SCHEMA):
#   Layer   int
#   ById    int32 id -> constructor
#   ByName  'auth.sendCode' -> constructor
#   ByType  'auth.SentCode' -> constructors producing that type (for %Bare lookups)
# A constructor is a hashtable: Name, Id, Result, Raw, IsFunction, Params ($null until used).

$script:TG_LIB_ROOT = $PSScriptRoot
$script:TG_SCHEMA   = $null
$script:TG_TYPE_CACHE = @{}

# TL definitions the schema files only carry as comments ("parsed manually"). Declaring them
# here lets the generic codec read and write them like any other constructor.
# _mt_message is the container's inner "message" - renamed because api.tl owns `message`.
$script:TG_BUILTIN_TL = @(
    'rpc_result#f35c6d01 req_msg_id:long result:Object = RpcResult;'
    '_mt_message#5bb8e511 msg_id:long seqno:int bytes:int body:Object = MtMessage;'
    'msg_container#73f1f8dc messages:vector<_mt_message> = MessageContainer;'
    'msg_copy#e06046b2 orig_message:_mt_message = MessageCopy;'
    'gzip_packed#3072cfa1 packed_data:string = Object;'
)

$script:TG_CRC_TABLE = $null

# CRC32 (IEEE) of an ASCII string, as a signed int32 - TL constructor ids are signed on the wire.
function Get-TlCrc32 {
    param([Parameter(Mandatory)][string]$Text)
    if ($null -eq $script:TG_CRC_TABLE) {
        $table = New-Object 'long[]' 256
        for ($i = 0; $i -lt 256; $i++) {
            [long]$c = $i
            for ($k = 0; $k -lt 8; $k++) {
                if ($c -band 1) { $c = (0xEDB88320L -bxor ($c -shr 1)) } else { $c = ($c -shr 1) }
            }
            $table[$i] = $c
        }
        $script:TG_CRC_TABLE = $table
    }
    [long]$crc = 0xFFFFFFFFL
    foreach ($b in [System.Text.Encoding]::ASCII.GetBytes($Text)) {
        $crc = $script:TG_CRC_TABLE[($crc -bxor $b) -band 0xFF] -bxor ($crc -shr 8)
    }
    $crc = ($crc -bxor 0xFFFFFFFFL) -band 0xFFFFFFFFL
    return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$crc), 0)
}

# Id for a definition line that carries no #id: CRC32 of its normalised text.
# Normalisation (the TL spec's, as Telethon applies it): `X:flags.N?true` params dropped,
# bytes -> string, <> and {} reduced to spaces/nothing.
function Get-TlConstructorId {
    param([Parameter(Mandatory)][string]$Definition)
    $text = $Definition.Trim().TrimEnd(';').Trim()
    $text = [regex]::Replace($text, ' \w+:flags\d*\.\d+\?true', '')
    $text = $text.Replace(':bytes ', ':string ').Replace('?bytes ', '?string ')
    $text = $text.Replace('<', ' ').Replace('>', '').Replace('{', '').Replace('}', '')
    return (Get-TlCrc32 $text)
}

# Register one definition line. Returns $true when it became a constructor.
function Register-TlLine {
    param($Schema, [string]$Line, [bool]$IsFunction)

    $line = $Line.Trim()
    if (-not $line -or $line.StartsWith('//')) { return $false }
    $cut = $line.IndexOf(' //')
    if ($cut -ge 0) { $line = $line.Substring(0, $cut).TrimEnd() }
    $line = $line.TrimEnd(';').TrimEnd()

    # The core-type declarations at the top of mtproto.tl (`int ? = Int;`, `vector {t:Type} # [ t ]`)
    # describe what the codec hard-codes; they are not constructors.
    if ($line.Contains(' ? = ') -or $line.Contains(' [ ') -or $line.Contains('*[')) { return $false }

    $eq = $line.LastIndexOf(' = ')
    if ($eq -lt 0) { return $false }
    $left   = $line.Substring(0, $eq)
    $result = $line.Substring($eq + 3).Trim()

    $space  = $left.IndexOf(' ')
    $head   = if ($space -lt 0) { $left } else { $left.Substring(0, $space) }
    $raw    = if ($space -lt 0) { '' } else { $left.Substring($space + 1).Trim() }

    $hash = $head.IndexOf('#')
    if ($hash -ge 0) {
        $name = $head.Substring(0, $hash)
        $id   = [Convert]::ToInt32($head.Substring($hash + 1), 16)   # 8 hex digits wrap to signed
    } else {
        $name = $head
        $id   = Get-TlConstructorId $line
    }

    $ctor = @{ Name = $name; Id = $id; Result = $result; Raw = $raw; IsFunction = $IsFunction; Params = $null }
    $Schema.ById[$id]     = $ctor
    $Schema.ByName[$name] = $ctor
    if (-not $Schema.ByType.ContainsKey($result)) { $Schema.ByType[$result] = New-Object System.Collections.ArrayList }
    [void]$Schema.ByType[$result].Add($ctor)
    return $true
}

# Parse one .tl file's text into $Schema; returns the LAYER number if the file states one.
function Import-TlText {
    param($Schema, [string]$Text)
    $isFunction = $false
    $layer = 0
    foreach ($line in $Text.Split("`n")) {
        $l = $line.Trim()
        if ($l -eq '---functions---') { $isFunction = $true;  continue }
        if ($l -eq '---types---')     { $isFunction = $false; continue }
        if ($l.StartsWith('// LAYER ')) { $layer = [int]$l.Substring(9).Trim(); continue }
        [void](Register-TlLine -Schema $Schema -Line $l -IsFunction $isFunction)
    }
    return $layer
}

# Load (once) and return the schema. -Force reloads.
function Initialize-TgSchema {
    param([switch]$Force, [string]$SchemaDir = '')
    if ($script:TG_SCHEMA -and -not $Force) { return $script:TG_SCHEMA }

    if (-not $SchemaDir) { $SchemaDir = Join-Path $script:TG_LIB_ROOT 'schema' }
    $schema = @{
        Layer  = 0
        ById   = @{}
        ByName = @{}
        ByType = @{}
    }
    foreach ($file in 'mtproto.tl', 'api.tl') {
        $path = Join-Path $SchemaDir $file
        if (-not (Test-Path -LiteralPath $path)) { throw "Telegram schema file missing: $path" }
        $text  = [System.IO.File]::ReadAllText($path)
        $layer = Import-TlText -Schema $schema -Text $text
        if ($layer -gt 0) { $schema.Layer = $layer }
    }
    foreach ($def in $script:TG_BUILTIN_TL) {
        [void](Register-TlLine -Schema $schema -Line $def -IsFunction $false)
    }
    if ($schema.Layer -le 0) { throw 'Telegram schema carries no // LAYER marker.' }
    $script:TG_SCHEMA = $schema
    return $schema
}

# Find a constructor by name or int32 id; $null when unknown.
function Get-TlConstructor {
    param([Parameter(Mandatory)]$Key)
    $schema = Initialize-TgSchema
    if ($Key -is [string]) { return $schema.ByName[$Key] }
    return $schema.ById[[int]$Key]
}

# Describe a TL type string once: Kind is one of
#   int long double string bytes int128 int256 true flags   primitives
#   vector      Inner = element descriptor, Boxed = carries the 0x1cb5c415 id
#   bare        no constructor id on the wire; Name = type (%Type) or constructor (lowercase)
#   boxed       constructor id first (also covers Bool, Object and the !X generic)
function Get-TlTypeInfo {
    param([Parameter(Mandatory)][string]$Type)
    $hit = $script:TG_TYPE_CACHE[$Type]
    if ($hit) { return $hit }

    $info = $null
    switch -CaseSensitive ($Type) {
        'int'    { $info = @{ Kind = 'int' } }
        'long'   { $info = @{ Kind = 'long' } }
        'double' { $info = @{ Kind = 'double' } }
        'string' { $info = @{ Kind = 'string' } }
        'bytes'  { $info = @{ Kind = 'bytes' } }
        'int128' { $info = @{ Kind = 'int128' } }
        'int256' { $info = @{ Kind = 'int256' } }
        'true'   { $info = @{ Kind = 'true' } }
        '#'      { $info = @{ Kind = 'flags' } }
    }
    if (-not $info) {
        if ($Type -match '^[Vv]ector<(.+)>$') {
            $info = @{ Kind = 'vector'; Boxed = ($Type[0] -ceq 'V'); Inner = (Get-TlTypeInfo $Matches[1]) }
        } elseif ($Type.StartsWith('%')) {
            $info = @{ Kind = 'bare'; Name = $Type.Substring(1); ByCtor = $false }
        } elseif ($Type.StartsWith('!')) {
            $info = @{ Kind = 'boxed'; Name = 'Object' }
        } else {
            $last = $Type.Substring($Type.LastIndexOf('.') + 1)
            if ($last.Length -gt 0 -and [char]::IsLower($last[0])) {
                $info = @{ Kind = 'bare'; Name = $Type; ByCtor = $true }
            } else {
                $info = @{ Kind = 'boxed'; Name = $Type }
            }
        }
    }
    $script:TG_TYPE_CACHE[$Type] = $info
    return $info
}

# The constructor's ordered fields, split from the raw text on first use.
# Each field: Name, Type (string), Info (type descriptor), FlagField ('' or 'flags'/'flags2'),
# Bit (flag bit, -1 when unconditional).
function Get-TlParams {
    param([Parameter(Mandatory)]$Ctor)
    if ($null -ne $Ctor.Params) { return $Ctor.Params }

    $fields = New-Object System.Collections.ArrayList
    if ($Ctor.Raw) {
        foreach ($tok in ($Ctor.Raw -split '\s+')) {
            if (-not $tok -or $tok.StartsWith('{')) { continue }     # {X:Type} generics carry no data
            $colon = $tok.IndexOf(':')
            if ($colon -lt 1) { throw "Cannot parse TL parameter '$tok' in $($Ctor.Name)" }
            $fname = $tok.Substring(0, $colon)
            $ftype = $tok.Substring($colon + 1)
            $flagField = ''
            $bit = -1
            if ($ftype -match '^(flags\d*)\.(\d+)\?(.+)$') {
                $flagField = $Matches[1]
                $bit       = [int]$Matches[2]
                $ftype     = $Matches[3]
            }
            [void]$fields.Add(@{
                Name = $fname; Type = $ftype; Info = (Get-TlTypeInfo $ftype)
                FlagField = $flagField; Bit = $bit
            })
        }
    }
    $Ctor.Params = $fields.ToArray()
    return $Ctor.Params
}
