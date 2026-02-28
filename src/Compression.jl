# Compression.jl - Codec abstraction for VDB compression

using Blosc
using CodecZlib

"""
    Codec

Abstract type for compression codecs.
"""
abstract type Codec end

"""
    NoCompression <: Codec

No compression - data is stored as-is.
"""
struct NoCompression <: Codec end

"""
    BloscCodec <: Codec

Blosc compression codec.
"""
struct BloscCodec <: Codec end

"""
    ZipCodec <: Codec

Zlib/Zip compression codec.
"""
struct ZipCodec <: Codec end

"""
    decompress(::NoCompression, bytes::Vector{UInt8}) -> Vector{UInt8}

Identity decompression - returns input unchanged.
"""
decompress(::NoCompression, bytes::Vector{UInt8})::Vector{UInt8} = bytes

"""
    decompress(::BloscCodec, bytes::Vector{UInt8}) -> Vector{UInt8}

Decompress Blosc-compressed data.
"""
function decompress(::BloscCodec, bytes::Vector{UInt8})::Vector{UInt8}
    if isempty(bytes)
        return UInt8[]
    end
    Blosc.decompress(UInt8, bytes)
end

"""
    decompress(::ZipCodec, bytes::Vector{UInt8}) -> Vector{UInt8}

Decompress Zlib-compressed data.
"""
function decompress(::ZipCodec, bytes::Vector{UInt8})::Vector{UInt8}
    if isempty(bytes)
        return UInt8[]
    end
    transcode(ZlibDecompressor, bytes)
end

"""
    read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::NoCompression, expected_size::Int)

Read uncompressed data directly (no size prefix). Returns a view into the
original bytes to avoid copying.
"""
function read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::NoCompression, expected_size::Int)
    @boundscheck checkbounds(bytes, pos:pos+expected_size-1)
    (@view(bytes[pos:pos+expected_size-1]), pos + expected_size)
end

"""
    read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::Codec, expected_size::Int) -> Tuple{Vector{UInt8}, Int}

Read a size-prefixed compressed block and decompress it.
The block format is: chunk_size (Int64) | data

Per VDB format spec (Section 10):
- If chunk_size == 0: Empty chunk, return empty array
- If chunk_size < 0: Uncompressed, read abs(chunk_size) raw bytes
- If chunk_size > 0: Compressed, read chunk_size bytes then decompress

For NoCompression codec, no size prefix is used (handled by separate method).
"""
function read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::Codec, expected_size::Int)
    # Read chunk size (signed Int64)
    chunk_size, pos = read_i64_le(bytes, pos)

    if chunk_size == 0
        # Empty chunk
        return (UInt8[], pos)
    elseif chunk_size < 0
        # Uncompressed data: read abs(chunk_size) raw bytes
        raw_size = Int(-chunk_size)

        # Verify size matches expected
        if raw_size != expected_size
            throw(ChunkSizeMismatchError(pos, expected_size, raw_size, chunk_size))
        end

        data, pos = read_bytes(bytes, pos, raw_size)
        return (data, pos)
    else
        # Compressed data: read chunk_size bytes then decompress
        compressed_data = UInt8[]
        try
            compressed_data, pos = read_bytes(bytes, pos, Int(chunk_size))
        catch e
            if isa(e, BoundsError)
                throw(CompressionBoundsError(pos, chunk_size, length(bytes)))
            else
                rethrow(e)
            end
        end

        # Decompress
        decompressed = decompress(codec, compressed_data)

        # Verify expected size
        if length(decompressed) != expected_size
            throw(DecompressionSizeError(expected_size, length(decompressed)))
        end

        return (decompressed, pos)
    end
end
