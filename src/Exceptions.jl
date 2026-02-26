# Exceptions.jl - Typed exceptions for VDB parsing errors

"""
    LyrError <: Exception

Base type for all Lyr.jl exceptions.
"""
abstract type LyrError <: Exception end

# =============================================================================
# Parse Errors
# =============================================================================

"""
    ParseError <: LyrError

Base type for parsing errors.
"""
abstract type ParseError <: LyrError end

"""
    InvalidMagicError <: ParseError

Thrown when the file does not start with a valid VDB magic number.
"""
struct InvalidMagicError <: ParseError
    expected::UInt64
    got::UInt64
end

function Base.showerror(io::IO, e::InvalidMagicError)
    print(io, "InvalidMagicError: expected magic 0x$(string(e.expected, base=16)), got 0x$(string(e.got, base=16))")
end


# =============================================================================
# Compression Errors
# =============================================================================

"""
    CompressionError <: LyrError

Base type for compression/decompression errors.
"""
abstract type CompressionError <: LyrError end

"""
    ChunkSizeMismatchError <: CompressionError

Thrown when the uncompressed chunk size doesn't match expected size.
"""
struct ChunkSizeMismatchError <: CompressionError
    position::Int
    expected::Int
    got::Int
    chunk_size::Int64
end

function Base.showerror(io::IO, e::ChunkSizeMismatchError)
    print(io, "ChunkSizeMismatchError at position $(e.position): expected $(e.expected) bytes, got $(e.got) (chunk_size=$(e.chunk_size))")
end

"""
    CompressionBoundsError <: CompressionError

Thrown when compressed data extends beyond file bounds.
"""
struct CompressionBoundsError <: CompressionError
    position::Int
    chunk_size::Int64
    file_size::Int
end

function Base.showerror(io::IO, e::CompressionBoundsError)
    print(io, "CompressionBoundsError at position $(e.position): chunk_size=$(e.chunk_size) exceeds file_size=$(e.file_size)")
end

"""
    DecompressionSizeError <: CompressionError

Thrown when decompressed data size doesn't match expected size.
"""
struct DecompressionSizeError <: CompressionError
    expected::Int
    got::Int
end

function Base.showerror(io::IO, e::DecompressionSizeError)
    print(io, "DecompressionSizeError: expected $(e.expected) bytes, got $(e.got)")
end

# =============================================================================
# Value Errors
# =============================================================================

"""
    FormatError <: ParseError

Generic parse/format error for VDB data that doesn't match expected structure.
"""
struct FormatError <: ParseError
    message::String
end

function Base.showerror(io::IO, e::FormatError)
    print(io, "FormatError: ", e.message)
end

"""
    UnsupportedVersionError <: ParseError

Thrown when the VDB file version is not supported.
"""
struct UnsupportedVersionError <: ParseError
    version::UInt32
    min_version::UInt32
end

function Base.showerror(io::IO, e::UnsupportedVersionError)
    print(io, "UnsupportedVersionError: version $(e.version) not supported (minimum: $(e.min_version))")
end

# =============================================================================
# Value Errors
# =============================================================================

"""
    ValueCountError <: LyrError

Thrown when decompressed values have unexpected count.
"""
struct ValueCountError <: LyrError
    expected::Int
    got::Int
end

function Base.showerror(io::IO, e::ValueCountError)
    print(io, "ValueCountError: expected $(e.expected) values, got $(e.got)")
end
