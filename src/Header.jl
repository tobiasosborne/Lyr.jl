# Header.jl - VDB file header parsing

"""
VDB file magic number: bytes [0x20, 0x42, 0x44, 0x56] (" BDV") read as little-endian u32.
"""
const VDB_MAGIC = 0x56444220

"""
    VDBHeader

Header information from a VDB file.

# Fields
- `format_version::UInt32` - File format version
- `library_major::UInt32` - Library major version
- `library_minor::UInt32` - Library minor version
- `has_grid_offsets::Bool` - Whether grid offsets are stored
- `compression::Codec` - File-level compression codec
- `uuid::String` - Unique file identifier (36-char ASCII UUID string)
"""
struct VDBHeader
    format_version::UInt32
    library_major::UInt32
    library_minor::UInt32
    has_grid_offsets::Bool
    compression::Codec
    uuid::String
end

"""
    read_header(bytes::Vector{UInt8}, pos::Int) -> Tuple{VDBHeader, Int}

Parse VDB file header. Format (verified against OpenVDB samples):
- Magic (4 bytes) + padding (4 bytes) = 8 bytes total
- Format version (4 bytes u32 LE)
- Library major (4 bytes u32 LE)
- Library minor (4 bytes u32 LE)
- Has grid offsets (1 byte) if version >= 212
- UUID (36 bytes ASCII string, e.g., "a2313abf-7b19-4669-a9ea-f4a83e6bf20d")
- Compression (4 bytes u32 LE) if version >= 222: 0=none, 1=zlib, 2=blosc
"""
function read_header(bytes::Vector{UInt8}, pos::Int)::Tuple{VDBHeader, Int}
    # Read and verify magic number (4 bytes)
    magic, pos = read_u32_le(bytes, pos)
    if magic != VDB_MAGIC
        throw(InvalidMagicError(UInt64(VDB_MAGIC), UInt64(magic)))
    end

    # Skip 4 bytes of padding after magic
    _, pos = read_u32_le(bytes, pos)

    # Read format version
    format_version, pos = read_u32_le(bytes, pos)

    # Read library version
    library_major, pos = read_u32_le(bytes, pos)
    library_minor, pos = read_u32_le(bytes, pos)

    # Read has_grid_offsets flag (1 byte) if version >= 212
    has_grid_offsets = false
    if format_version >= 212
        offsets_byte, pos = read_u8(bytes, pos)
        has_grid_offsets = offsets_byte != 0
    end

    # Version 220-221 has a half_float flag (1 byte) before UUID
    # This was removed in version 222+ (moved to per-grid metadata)
    if format_version >= 220 && format_version < 222
        _, pos = read_u8(bytes, pos)  # half_float flag (skip)
    end

    # Read UUID (36 bytes ASCII string)
    uuid_bytes, pos = read_bytes(bytes, pos, 36)
    uuid = String(uuid_bytes)

    # Read compression (4 bytes u32 LE) if version >= 222
    # For older versions, default to ZipCodec (standard OpenVDB behavior)
    compression = if format_version >= 222
        compression_u32, pos = read_u32_le(bytes, pos)
        if compression_u32 == 0
            NoCompression()
        elseif compression_u32 == 1
            ZipCodec()
        elseif compression_u32 == 2
            BloscCodec()
        else
            NoCompression()  # Unknown, assume none
        end
    else
        ZipCodec()
    end

    header = VDBHeader(format_version, library_major, library_minor, has_grid_offsets, compression, uuid)
    (header, pos)
end
