# Compression.jl - Compression handling for TinyVDB
#
# VDB files support multiple compression schemes:
# - COMPRESS_NONE: No compression
# - COMPRESS_ZIP: Zlib compression
# - COMPRESS_ACTIVE_MASK: Use active mask to reduce stored values
# - COMPRESS_BLOSC: Blosc compression (not supported in TinyVDB)
#
# TinyVDB only supports COMPRESS_NONE and COMPRESS_ZIP.

using CodecZlib

# =============================================================================
# Constants
# =============================================================================

"""No compression."""
const COMPRESS_NONE = UInt32(0x00)

"""Zlib compression."""
const COMPRESS_ZIP = UInt32(0x01)

"""Active mask compression (reduces stored values to active voxels only)."""
const COMPRESS_ACTIVE_MASK = UInt32(0x02)

"""Blosc compression (not supported)."""
const COMPRESS_BLOSC = UInt32(0x04)

"""File version where per-grid compression was introduced."""
const FILE_VERSION_NODE_MASK_COMPRESSION = UInt32(222)

# =============================================================================
# Compression Reading Functions
# =============================================================================

"""
    read_grid_compression(bytes::Vector{UInt8}, pos::Int, file_version::UInt32) -> Tuple{UInt32, Int}

Read per-grid compression flags from bytes.

For file version >= 222, reads a u32 containing compression flags.
For older versions, returns COMPRESS_NONE and doesn't advance position.

Returns (compression_flags, new_pos).
"""
function read_grid_compression(bytes::Vector{UInt8}, pos::Int, file_version::UInt32)::Tuple{UInt32, Int}
    if file_version >= FILE_VERSION_NODE_MASK_COMPRESSION
        flags, pos = read_u32(bytes, pos)
        return (flags, pos)
    else
        return (COMPRESS_NONE, pos)
    end
end

"""
    read_compressed_data(bytes::Vector{UInt8}, pos::Int, count::Int, element_size::Int,
                        compression_flags::UInt32) -> Tuple{Vector{UInt8}, Int}

Read compressed or uncompressed data from bytes.

# Arguments
- `bytes`: Source byte array
- `pos`: Starting position (1-indexed)
- `count`: Number of elements to read
- `element_size`: Size of each element in bytes
- `compression_flags`: Compression flags (COMPRESS_NONE, COMPRESS_ZIP, etc.)

# Returns
- Decompressed data as a byte vector
- New position after reading

# Format for COMPRESS_ZIP
- i64 numZippedBytes: Number of compressed bytes (negative means uncompressed)
- If numZippedBytes > 0: compressed data
- If numZippedBytes <= 0: raw uncompressed data

# Format for COMPRESS_NONE
- Raw data bytes (count * element_size)
"""
function read_compressed_data(bytes::Vector{UInt8}, pos::Int, count::Int, element_size::Int,
                              compression_flags::UInt32)::Tuple{Vector{UInt8}, Int}
    total_bytes = count * element_size

    if (compression_flags & COMPRESS_BLOSC) != 0
        error("Blosc compression is not supported in TinyVDB")
    end

    if (compression_flags & COMPRESS_ZIP) != 0
        # Read the size of compressed data
        num_zipped_bytes, pos = read_i64(bytes, pos)

        if num_zipped_bytes <= 0
            # Data is uncompressed despite ZIP flag
            data = bytes[pos:pos+total_bytes-1]
            return (data, pos + total_bytes)
        else
            # Read compressed data
            compressed = bytes[pos:pos+Int(num_zipped_bytes)-1]
            pos += Int(num_zipped_bytes)

            # Decompress with zlib
            decompressed = transcode(ZlibDecompressor, compressed)

            if length(decompressed) != total_bytes
                error("Decompressed size mismatch: expected $total_bytes, got $(length(decompressed))")
            end

            return (decompressed, pos)
        end
    else
        # No compression - read raw bytes
        data = bytes[pos:pos+total_bytes-1]
        return (data, pos + total_bytes)
    end
end

"""
    read_f32_values(bytes::Vector{UInt8}, pos::Int, count::Int,
                   compression_flags::UInt32) -> Tuple{Vector{Float32}, Int}

Read Float32 values, handling compression if needed.

Returns (values, new_pos).
"""
function read_f32_values(bytes::Vector{UInt8}, pos::Int, count::Int,
                        compression_flags::UInt32)::Tuple{Vector{Float32}, Int}
    data, pos = read_compressed_data(bytes, pos, count, 4, compression_flags)
    values = reinterpret(Float32, data)
    return (Vector{Float32}(values), pos)
end
