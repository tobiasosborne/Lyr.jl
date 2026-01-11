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
- `active_mask_compression::Bool` - Whether COMPRESS_ACTIVE_MASK is set (sparse value storage)
- `uuid::String` - Unique file identifier (36-char ASCII UUID string)
"""
struct VDBHeader
    format_version::UInt32
    library_major::UInt32
    library_minor::UInt32
    has_grid_offsets::Bool
    compression::Codec
    active_mask_compression::Bool
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

    # Read compression flags (4 bytes u32 LE) if version >= 222
    # Flags are a bitfield: 0x1=ZIP, 0x2=ACTIVE_MASK, 0x4=BLOSC
    # For older versions, default to ZipCodec with ACTIVE_MASK (standard OpenVDB behavior)
    compression_flags = if format_version >= 222
        flags, pos = read_u32_le(bytes, pos)
        flags
    else
        UInt32(0x3)  # ZIP + ACTIVE_MASK default for pre-222
    end

    # Determine codec from flags
    compression = if (compression_flags & 0x4) != 0
        BloscCodec()
    elseif (compression_flags & 0x1) != 0
        ZipCodec()
    else
        NoCompression()
    end

    # Check COMPRESS_ACTIVE_MASK flag (0x2)
    active_mask_compression = (compression_flags & 0x2) != 0

    header = VDBHeader(format_version, library_major, library_minor, has_grid_offsets, compression, active_mask_compression, uuid)
    (header, pos)
end
