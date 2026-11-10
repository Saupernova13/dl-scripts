# Telegram MTProto - schema-driven TL serializer / deserializer.
#
# Objects are ordered hashtables with `_` holding the constructor name ('auth.sentCode') and
# one key per field. Conditional (`flags.N?T`) fields are simply absent when their bit is clear,
# and `true` flags are $true when set. On the way out the `flags` words are computed from which
# fields are present, so callers never touch them.
#
#   ConvertTo-TlBytes   @{ _ = 'users.getUsers'; id = @(@{ _ = 'inputUserSelf' }) }  -> byte[]
#   ConvertFrom-TlBytes $bytes                                                      -> object
#
# Value mapping: int -> [int]; long -> [long]; double; string -> [string]; bytes -> [byte[]];
# int128/int256 -> [byte[]]; Bool -> [bool]; Vector -> [object[]]; any boxed type -> object.
# `!X` (a nested query) accepts an object, or a byte[] that is already serialized.
#
# Depends on TgNative.ps1 (TlWriter/TlReader) and TgSchema.ps1.

$script:TL_VECTOR_ID = 0x1cb5c415
$script:TL_GZIP_ID   = 0x3072cfa1

# --- value coercion -----------------------------------------------------------

function ConvertTo-TlInt32 {
    param($Value)
    if ($Value -is [int]) { return $Value }
    if ($Value -is [bool]) { return [int][bool]$Value }
    $n = [long]$Value
    if ($n -gt [int]::MaxValue) { $n = $n - 4294967296L }   # 0xFFFFFFFF-style unsigned wire values
    return [int]$n
}

function ConvertTo-TlInt64 {
    param($Value)
    if ($Value -is [long]) { return $Value }
    if ($Value -is [uint64]) { return [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$Value), 0) }
    if ($Value -is [string]) {
        # A decimal string is the lossless way to pass an unsigned 64-bit id around (JSON, CLI).
        $big = [System.Numerics.BigInteger]::Parse($Value)
        if ($big -gt [long]::MaxValue) { $big = $big - [System.Numerics.BigInteger]::Pow(2, 64) }
        return [long]$big
    }
    return [long]$Value
}

function Get-TlFieldValue {
    param($Object, [string]$Name)
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# --- writer -------------------------------------------------------------------

function Write-TlValue {
    param($Writer, $Info, $Value, [string]$Context)
    switch ($Info.Kind) {
        'int'    { $Writer.WriteInt((ConvertTo-TlInt32 $Value)) }
        'flags'  { $Writer.WriteInt((ConvertTo-TlInt32 $Value)) }
        'long'   { $Writer.WriteLong((ConvertTo-TlInt64 $Value)) }
        'double' { $Writer.WriteDouble([double]$Value) }
        'string' {
            if ($Value -is [byte[]]) { $Writer.WriteBytes($Value) } else { $Writer.WriteString([string]$Value) }
        }
        'bytes'  {
            if ($Value -is [byte[]]) { $Writer.WriteBytes($Value) } else { $Writer.WriteString([string]$Value) }
        }
        'int128' {
            if (-not ($Value -is [byte[]]) -or $Value.Length -ne 16) { throw "TL: $Context needs 16 bytes" }
            $Writer.WriteRaw($Value)
        }
        'int256' {
            if (-not ($Value -is [byte[]]) -or $Value.Length -ne 32) { throw "TL: $Context needs 32 bytes" }
            $Writer.WriteRaw($Value)
        }
        'true'   { }   # carried entirely by its flag bit
        'vector' {
            if ($Info.Boxed) { $Writer.WriteInt($script:TL_VECTOR_ID) }
            $items = @($Value)
            $Writer.WriteInt($items.Count)
            foreach ($item in $items) { Write-TlValue $Writer $Info.Inner $item $Context }
        }
        'bare' {
            $ctor = $null
            if ($Info.ByCtor) {
                $ctor = (Initialize-TgSchema).ByName[$Info.Name]
            } else {
                $name = Get-TlFieldValue $Value '_'
                if ($name) { $ctor = (Initialize-TgSchema).ByName[$name] }
                else {
                    $cands = (Initialize-TgSchema).ByType[$Info.Name]
                    if ($cands -and $cands.Count -eq 1) { $ctor = $cands[0] }
                }
            }
            if (-not $ctor) { throw "TL: no constructor for bare type '$($Info.Name)' ($Context)" }
            Write-TlConstructor $Writer $ctor $Value $true
        }
        'boxed' {
            if ($Value -is [bool]) {
                $id = if ($Value) { 0x997275b5 } else { 0xbc799737 }   # boolTrue / boolFalse
                $Writer.WriteInt((ConvertTo-TlInt32 $id))
            } elseif ($Value -is [byte[]]) {
                $Writer.WriteRaw($Value)                                # pre-serialized query
            } else {
                $name = Get-TlFieldValue $Value '_'
                if (-not $name) { throw "TL: $Context needs an object with a '_' constructor name" }
                $ctor = (Initialize-TgSchema).ByName[$name]
                if (-not $ctor) { throw "TL: unknown constructor '$name' ($Context)" }
                Write-TlConstructor $Writer $ctor $Value $false
            }
        }
        default { throw "TL: cannot write kind '$($Info.Kind)'" }
    }
}

function Write-TlConstructor {
    param($Writer, $Ctor, $Object, [bool]$Bare)
    if (-not $Bare) { $Writer.WriteInt($Ctor.Id) }
    $fields = @(Get-TlParams $Ctor)
    foreach ($f in $fields) {
        $ctx = "$($Ctor.Name).$($f.Name)"
        if ($f.Info.Kind -eq 'flags') {
            # The flags word is derived: a bit is set when its field is present (or $true).
            [int]$word = 0
            foreach ($g in $fields) {
                if ($g.FlagField -ne $f.Name) { continue }
                $gv = Get-TlFieldValue $Object $g.Name
                $present = if ($g.Info.Kind -eq 'true') { $gv -eq $true } else { $null -ne $gv }
                if ($present) { $word = $word -bor (1 -shl $g.Bit) }
            }
            $Writer.WriteInt($word)
            continue
        }
        $value = Get-TlFieldValue $Object $f.Name
        if ($f.FlagField) {
            if ($f.Info.Kind -eq 'true') { continue }
            if ($null -eq $value) { continue }
        } elseif ($null -eq $value) {
            throw "TL: missing field '$($f.Name)' for $($Ctor.Name)"
        }
        Write-TlValue $Writer $f.Info $value $ctx
    }
}

# Serialize a boxed object (constructor id + fields) to bytes.
function ConvertTo-TlBytes {
    param([Parameter(Mandatory)]$Object)
    $w = New-Object DlTg.TlWriter
    Write-TlValue $w (Get-TlTypeInfo 'Object') $Object 'object'
    return ,$w.ToArray()
}

# --- reader -------------------------------------------------------------------

# gzip_packed payloads are plain RFC1952 gzip streams.
function ConvertFrom-TlGzip {
    param([byte[]]$Data)
    $inMs = New-Object System.IO.MemoryStream (,$Data)
    $gz   = New-Object System.IO.Compression.GZipStream($inMs, [System.IO.Compression.CompressionMode]::Decompress)
    $out  = New-Object System.IO.MemoryStream
    try {
        $gz.CopyTo($out)
    } finally {
        $gz.Dispose(); $inMs.Dispose()
    }
    return ,$out.ToArray()
}

# Compress bytes the way gzip_packed carries them (used by tests and by large requests).
function ConvertTo-TlGzip {
    param([byte[]]$Data)
    $out = New-Object System.IO.MemoryStream
    $gz  = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress, $true)
    $gz.Write($Data, 0, $Data.Length)
    $gz.Dispose()
    return ,$out.ToArray()
}

function Read-TlValue {
    param($Reader, $Info)
    switch ($Info.Kind) {
        'int'    { return $Reader.ReadInt() }
        'flags'  { return $Reader.ReadInt() }
        'long'   { return $Reader.ReadLong() }
        'double' { return $Reader.ReadDouble() }
        'string' { return $Reader.ReadString() }
        'bytes'  { return ,$Reader.ReadBytes() }
        'int128' { return ,$Reader.ReadRaw(16) }
        'int256' { return ,$Reader.ReadRaw(32) }
        'true'   { return $true }
        'vector' {
            if ($Info.Boxed) {
                $id = $Reader.ReadInt()
                if ($id -eq (ConvertTo-TlInt32 $script:TL_GZIP_ID)) {
                    # A whole vector result can arrive gzipped: re-read the inflated body.
                    $inner = New-Object DlTg.TlReader (,(ConvertFrom-TlGzip $Reader.ReadBytes()))
                    return ,(Read-TlValue $inner $Info)
                }
                if ($id -ne (ConvertTo-TlInt32 $script:TL_VECTOR_ID)) {
                    throw ('TL: expected vector id, got 0x{0:x8}' -f $id)
                }
            }
            $count = $Reader.ReadInt()
            if ($count -lt 0) { throw "TL: negative vector length $count" }
            $items = [Array]::CreateInstance([object], $count)
            for ($i = 0; $i -lt $count; $i++) { $items[$i] = Read-TlValue $Reader $Info.Inner }
            return ,$items
        }
        'bare' {
            $schema = Initialize-TgSchema
            if ($Info.ByCtor) {
                $ctor = $schema.ByName[$Info.Name]
            } else {
                $cands = $schema.ByType[$Info.Name]
                $ctor = if ($cands -and $cands.Count -ge 1) { $cands[0] } else { $null }
            }
            if (-not $ctor) { throw "TL: no constructor for bare type '$($Info.Name)'" }
            return (Read-TlConstructor $Reader $ctor)
        }
        'boxed' {
            $id = $Reader.ReadInt()
            if ($id -eq (ConvertTo-TlInt32 $script:TL_GZIP_ID)) {
                $inner = New-Object DlTg.TlReader (,(ConvertFrom-TlGzip $Reader.ReadBytes()))
                return (Read-TlValue $inner $Info)
            }
            $ctor = (Initialize-TgSchema).ById[$id]
            if (-not $ctor) {
                if ($id -eq (ConvertTo-TlInt32 $script:TL_VECTOR_ID)) {
                    # Vector under an untyped Object: elements can only be read as boxed objects.
                    $count = $Reader.ReadInt()
                    $items = [Array]::CreateInstance([object], $count)
                    $objInfo = Get-TlTypeInfo 'Object'
                    for ($i = 0; $i -lt $count; $i++) { $items[$i] = Read-TlValue $Reader $objInfo }
                    return ,$items
                }
                throw ('TL: unknown constructor 0x{0:x8} (schema layer {1})' -f $id, (Initialize-TgSchema).Layer)
            }
            if ($ctor.Name -eq 'boolTrue')  { return $true }
            if ($ctor.Name -eq 'boolFalse') { return $false }
            return (Read-TlConstructor $Reader $ctor)
        }
        default { throw "TL: cannot read kind '$($Info.Kind)'" }
    }
}

function Read-TlConstructor {
    param($Reader, $Ctor)
    $obj = [ordered]@{ _ = $Ctor.Name }
    $flagWords = @{}
    foreach ($f in @(Get-TlParams $Ctor)) {
        if ($f.Info.Kind -eq 'flags') {
            $word = $Reader.ReadInt()
            $flagWords[$f.Name] = $word
            $obj[$f.Name] = $word
            continue
        }
        if ($f.FlagField) {
            $word = $flagWords[$f.FlagField]
            if (-not ($word -band (1 -shl $f.Bit))) { continue }
            if ($f.Info.Kind -eq 'true') { $obj[$f.Name] = $true; continue }
        }
        $obj[$f.Name] = Read-TlValue $Reader $f.Info
    }
    return $obj
}

# Parse bytes as a value of the given TL type ('Object' = any boxed object). A leading
# gzip_packed is inflated transparently. Trailing bytes are an error unless -AllowTrailing.
function ConvertFrom-TlBytes {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [string]$Type = 'Object',
        [switch]$AllowTrailing
    )
    $reader = New-Object DlTg.TlReader (,$Bytes)
    $value  = Read-TlValue $reader (Get-TlTypeInfo $Type)
    if ($reader.Remaining -gt 0 -and -not $AllowTrailing) {
        throw "TL: $($reader.Remaining) unparsed trailing byte(s) after $Type"
    }
    return $value
}
