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

- If compressed_size < 0: Data is uncompressed. Read abs(compressed_size) bytes.
- If compressed_size > 0: Data is compressed. Read compressed_size bytes then decompress.
- If compressed_size = 0: Empty.

For NoCompression, the format is just raw bytes (this function shouldn't be called typically, or handled by size=expected).
"""
function read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::Codec, expected_size::Int)::Tuple{Vector{UInt8}, Int}
    # Read chunk size (signed Int64)
    chunk_size, pos = read_i64_le(bytes, pos)

    if chunk_size == 0
        return (UInt8[], pos)
    end

    if chunk_size < 0
        # Uncompressed data
        # Size is -chunk_size
        raw_size = -chunk_size
        if raw_size != expected_size
            error("Uncompressed chunk size mismatch: expected $expected_size, got $raw_size")
        end
        
        # Read raw bytes directly
        data, pos = read_bytes(bytes, pos, Int(raw_size))
        return (data, pos)
    else
        # Compressed data
        compressed_size = chunk_size
        
        # Read compressed data
        compressed_data, pos = read_bytes(bytes, pos, Int(compressed_size))

        # Decompress
        decompressed = decompress(codec, compressed_data)

        # Verify expected size
        if length(decompressed) != expected_size
            error("Decompressed size mismatch: expected $expected_size, got $(length(decompressed))")
        end

        return (decompressed, pos)
    end
end
