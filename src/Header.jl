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

    # Version 220-221 has a global compression flag (1 byte) before UUID
    # See tinyvdbio.h:2896 — is_compressed: nonzero=ZIP, zero=NONE
    # This was removed in version 222+ (compression moved to per-grid metadata)
    is_compressed_byte = UInt8(0)
    if format_version >= 220 && format_version < VDB_FILE_VERSION_NODE_MASK_COMPRESSION
        is_compressed_byte, pos = read_u8(bytes, pos)
    end

    # Read UUID (36 bytes ASCII string)
    uuid_bytes, pos = read_bytes(bytes, pos, 36)
    uuid = String(uuid_bytes)

    # Compression handling differs by version:
    # - v220-221: Global compression flag in header (read above)
    # - v222+: Compression is per-grid, NOT in header. Read at start of each grid.
    compression_flags = if format_version < VDB_FILE_VERSION_NODE_MASK_COMPRESSION
        flags = VDB_COMPRESS_ACTIVE_MASK  # ACTIVE_MASK always set for v220-221
        if is_compressed_byte != 0
            flags |= VDB_COMPRESS_ZIP
        end
        flags
    else
        VDB_COMPRESS_NONE  # Placeholder for v222+; overridden per-grid
    end

    # Determine codec from flags (for v220-221; v222+ overrides per-grid)
    compression = if (compression_flags & VDB_COMPRESS_BLOSC) != 0
        BloscCodec()
    elseif (compression_flags & VDB_COMPRESS_ZIP) != 0
        ZipCodec()
    else
        NoCompression()
    end

    # Check COMPRESS_ACTIVE_MASK flag
    active_mask_compression = (compression_flags & VDB_COMPRESS_ACTIVE_MASK) != 0

    header = VDBHeader(format_version, library_major, library_minor, has_grid_offsets, compression, active_mask_compression, uuid)
    (header, pos)
end
