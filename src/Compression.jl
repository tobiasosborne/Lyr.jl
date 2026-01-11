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
    read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::NoCompression, expected_size::Int) -> Tuple{Vector{UInt8}, Int}

Read uncompressed data directly (no size prefix).
"""
function read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::NoCompression, expected_size::Int)::Tuple{Vector{UInt8}, Int}
    read_bytes(bytes, pos, expected_size)
end

"""
    read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::Codec, expected_size::Int) -> Tuple{Vector{UInt8}, Int}

Read a size-prefixed compressed block and decompress it.
The block format is: compressed_size (i64) | data

- If compressed_size <= 0: Data is uncompressed. Read expected_size bytes directly.
  (The sign is just a flag; the actual size is always expected_size for uncompressed data)
- If compressed_size > 0: Data is compressed. Read compressed_size bytes then decompress.

For NoCompression, the format is just raw bytes (this function shouldn't be called typically, or handled by size=expected).
"""
function read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::Codec, expected_size::Int)::Tuple{Vector{UInt8}, Int}
    # Read chunk size (signed Int64)
    chunk_size, pos = read_i64_le(bytes, pos)

    if chunk_size <= 0
        # Uncompressed data (chunk_size <= 0 is just a flag, not the size)
        # Read expected_size raw bytes directly
        data, pos = read_bytes(bytes, pos, expected_size)
        return (data, pos)
    else
        # Compressed data
        compressed_size = chunk_size
        
        # Read compressed data
        compressed_data = UInt8[]
        try
            compressed_data, pos = read_bytes(bytes, pos, Int(compressed_size))
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
