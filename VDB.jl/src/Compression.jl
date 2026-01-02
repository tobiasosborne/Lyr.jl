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
    read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::Codec, expected_size::Int) -> Tuple{Vector{UInt8}, Int}

Read a size-prefixed compressed block and decompress it.
The block format is: compressed_size (u64) | compressed_data

For NoCompression, the compressed_size equals expected_size.
"""
function read_compressed_bytes(bytes::Vector{UInt8}, pos::Int, codec::Codec, expected_size::Int)::Tuple{Vector{UInt8}, Int}
    # Read compressed size
    compressed_size, pos = read_u64_le(bytes, pos)

    if compressed_size == 0
        return (UInt8[], pos)
    end

    # Read compressed data
    compressed_data, pos = read_bytes(bytes, pos, Int(compressed_size))

    # Decompress
    decompressed = decompress(codec, compressed_data)

    # Verify expected size
    if length(decompressed) != expected_size
        error("Decompressed size mismatch: expected $expected_size, got $(length(decompressed))")
    end

    (decompressed, pos)
end
