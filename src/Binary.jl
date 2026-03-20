# Binary.jl — Pure functions for reading primitive types from byte vectors
#
# All functions have signature: (bytes::Vector{UInt8}, pos::Int) -> (result, new_pos::Int)
# Positions are 1-indexed (Julia convention)
# All multi-byte types are little-endian
#
# Uses alignment=1 for all pointer loads to support unaligned access (ARM portability).

using Base: ltoh

"""Load a value of type T from an unaligned pointer position."""
@inline function _unaligned_load(::Type{T}, ptr::Ptr{UInt8}) where T
    ref = Ref{T}()
    GC.@preserve ref begin
        dst = Base.unsafe_convert(Ptr{T}, ref)
        ccall(:memcpy, Ptr{Cvoid}, (Ptr{T}, Ptr{UInt8}, Csize_t), dst, ptr, sizeof(T))
    end
    return ref[]
end

"""
    read_le(::Type{T}, bytes::Vector{UInt8}, pos::Int) -> Tuple{T, Int}

Read any primitive bitstype from bytes in little-endian format.
Generic over all types supported by `_unaligned_load`.
"""
@inline function read_le(::Type{T}, bytes::Vector{UInt8}, pos::Int)::Tuple{T, Int} where T
    @boundscheck checkbounds(bytes, pos:pos+sizeof(T)-1)
    GC.@preserve bytes begin
        @inbounds val = _unaligned_load(T, pointer(bytes, pos))
    end
    (ltoh(val), pos + sizeof(T))
end

"""
    read_u8(bytes::Vector{UInt8}, pos::Int) -> Tuple{UInt8, Int}

Read a single unsigned byte at position `pos`.
Returns the value and the next position.
"""
function read_u8(bytes::Vector{UInt8}, pos::Int)::Tuple{UInt8, Int}
    @boundscheck checkbounds(bytes, pos)
    @inbounds val = bytes[pos]
    (val, pos + 1)
end

"""
    read_u32_le(bytes::Vector{UInt8}, pos::Int) -> Tuple{UInt32, Int}

Read a 32-bit unsigned integer in little-endian format.
"""
function read_u32_le(bytes::Vector{UInt8}, pos::Int)::Tuple{UInt32, Int}
    @boundscheck checkbounds(bytes, pos:pos+3)
    GC.@preserve bytes begin
        @inbounds val = _unaligned_load(UInt32, pointer(bytes, pos))
    end
    (ltoh(val), pos + 4)
end

"""
    read_u64_le(bytes::Vector{UInt8}, pos::Int) -> Tuple{UInt64, Int}

Read a 64-bit unsigned integer in little-endian format.
"""
function read_u64_le(bytes::Vector{UInt8}, pos::Int)::Tuple{UInt64, Int}
    @boundscheck checkbounds(bytes, pos:pos+7)
    GC.@preserve bytes begin
        @inbounds val = _unaligned_load(UInt64, pointer(bytes, pos))
    end
    (ltoh(val), pos + 8)
end

"""
    read_i32_le(bytes::Vector{UInt8}, pos::Int) -> Tuple{Int32, Int}

Read a 32-bit signed integer in little-endian format.
"""
function read_i32_le(bytes::Vector{UInt8}, pos::Int)::Tuple{Int32, Int}
    @boundscheck checkbounds(bytes, pos:pos+3)
    GC.@preserve bytes begin
        @inbounds val = _unaligned_load(Int32, pointer(bytes, pos))
    end
    (ltoh(val), pos + 4)
end

"""
    read_i64_le(bytes::Vector{UInt8}, pos::Int) -> Tuple{Int64, Int}

Read a 64-bit signed integer in little-endian format.
"""
function read_i64_le(bytes::Vector{UInt8}, pos::Int)::Tuple{Int64, Int}
    @boundscheck checkbounds(bytes, pos:pos+7)
    GC.@preserve bytes begin
        @inbounds val = _unaligned_load(Int64, pointer(bytes, pos))
    end
    (ltoh(val), pos + 8)
end

"""
    read_f16_le(bytes::Vector{UInt8}, pos::Int) -> Tuple{Float16, Int}

Read a 16-bit (half-precision) float in little-endian format.
"""
function read_f16_le(bytes::Vector{UInt8}, pos::Int)::Tuple{Float16, Int}
    @boundscheck checkbounds(bytes, pos:pos+1)
    GC.@preserve bytes begin
        @inbounds val = _unaligned_load(Float16, pointer(bytes, pos))
    end
    (ltoh(val), pos + 2)
end

"""
    read_f32_le(bytes::Vector{UInt8}, pos::Int) -> Tuple{Float32, Int}

Read a 32-bit float in little-endian format.
"""
function read_f32_le(bytes::Vector{UInt8}, pos::Int)::Tuple{Float32, Int}
    @boundscheck checkbounds(bytes, pos:pos+3)
    GC.@preserve bytes begin
        @inbounds val = _unaligned_load(Float32, pointer(bytes, pos))
    end
    (ltoh(val), pos + 4)
end

"""
    read_f64_le(bytes::Vector{UInt8}, pos::Int) -> Tuple{Float64, Int}

Read a 64-bit float in little-endian format.
"""
function read_f64_le(bytes::Vector{UInt8}, pos::Int)::Tuple{Float64, Int}
    @boundscheck checkbounds(bytes, pos:pos+7)
    GC.@preserve bytes begin
        @inbounds val = _unaligned_load(Float64, pointer(bytes, pos))
    end
    (ltoh(val), pos + 8)
end

"""
    read_bytes(bytes::Vector{UInt8}, pos::Int, n::Int) -> Tuple{Vector{UInt8}, Int}

Read `n` bytes starting at position `pos`.
Returns a copy of the byte range (safe, no aliasing with input buffer).
"""
function read_bytes(bytes::Vector{UInt8}, pos::Int, n::Int)::Tuple{Vector{UInt8}, Int}
    @boundscheck checkbounds(bytes, pos:pos+n-1)
    (bytes[pos:pos+n-1], pos + n)
end

"""
    read_cstring(bytes::Vector{UInt8}, pos::Int) -> Tuple{String, Int}

Read a null-terminated C string starting at position `pos`.
Returns the string (without null terminator) and position after the null byte.
Uses unsafe_string to avoid intermediate array allocation.
"""
function read_cstring(bytes::Vector{UInt8}, pos::Int)::Tuple{String, Int}
    start = pos
    @inbounds while pos <= length(bytes) && bytes[pos] != 0x00
        pos += 1
    end
    if pos > length(bytes)
        throw(BoundsError(bytes, pos))
    end
    len = pos - start
    str = GC.@preserve bytes unsafe_string(pointer(bytes, start), len)
    (str, pos + 1)  # Skip the null terminator
end

"""
    read_string_with_size(bytes::Vector{UInt8}, pos::Int) -> Tuple{String, Int}

Read a size-prefixed string. The size is a 32-bit little-endian integer.
Uses unsafe_string to avoid intermediate array allocation.
"""
function read_string_with_size(bytes::Vector{UInt8}, pos::Int)::Tuple{String, Int}
    size, pos = read_u32_le(bytes, pos)
    if size == 0
        return ("", pos)
    end
    len = Int(size)
    @boundscheck checkbounds(bytes, pos:pos+len-1)
    str = GC.@preserve bytes unsafe_string(pointer(bytes, pos), len)
    (str, pos + len)
end
