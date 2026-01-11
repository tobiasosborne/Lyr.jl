# Binary.jl - Binary reading primitives for TinyVDB
#
# All functions have signature: (bytes::Vector{UInt8}, pos::Int) -> (result, new_pos::Int)
# Positions are 1-indexed (Julia convention)
# All multi-byte types are little-endian

using Base: ltoh

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
    read_u32(bytes::Vector{UInt8}, pos::Int) -> Tuple{UInt32, Int}

Read a 32-bit unsigned integer in little-endian format.
Returns the value and the next position.
"""
function read_u32(bytes::Vector{UInt8}, pos::Int)::Tuple{UInt32, Int}
    @boundscheck checkbounds(bytes, pos:pos+3)
    GC.@preserve bytes begin
        @inbounds val = unsafe_load(Ptr{UInt32}(pointer(bytes, pos)))
    end
    (ltoh(val), pos + 4)
end

"""
    read_i32(bytes::Vector{UInt8}, pos::Int) -> Tuple{Int32, Int}

Read a 32-bit signed integer in little-endian format.
Returns the value and the next position.
"""
function read_i32(bytes::Vector{UInt8}, pos::Int)::Tuple{Int32, Int}
    @boundscheck checkbounds(bytes, pos:pos+3)
    GC.@preserve bytes begin
        @inbounds val = unsafe_load(Ptr{Int32}(pointer(bytes, pos)))
    end
    (ltoh(val), pos + 4)
end

"""
    read_u64(bytes::Vector{UInt8}, pos::Int) -> Tuple{UInt64, Int}

Read a 64-bit unsigned integer in little-endian format.
Returns the value and the next position.
"""
function read_u64(bytes::Vector{UInt8}, pos::Int)::Tuple{UInt64, Int}
    @boundscheck checkbounds(bytes, pos:pos+7)
    GC.@preserve bytes begin
        @inbounds val = unsafe_load(Ptr{UInt64}(pointer(bytes, pos)))
    end
    (ltoh(val), pos + 8)
end

"""
    read_i64(bytes::Vector{UInt8}, pos::Int) -> Tuple{Int64, Int}

Read a 64-bit signed integer in little-endian format.
Returns the value and the next position.
"""
function read_i64(bytes::Vector{UInt8}, pos::Int)::Tuple{Int64, Int}
    @boundscheck checkbounds(bytes, pos:pos+7)
    GC.@preserve bytes begin
        @inbounds val = unsafe_load(Ptr{Int64}(pointer(bytes, pos)))
    end
    (ltoh(val), pos + 8)
end

"""
    read_f32(bytes::Vector{UInt8}, pos::Int) -> Tuple{Float32, Int}

Read a 32-bit float in little-endian format (IEEE 754).
Returns the value and the next position.
"""
function read_f32(bytes::Vector{UInt8}, pos::Int)::Tuple{Float32, Int}
    @boundscheck checkbounds(bytes, pos:pos+3)
    GC.@preserve bytes begin
        @inbounds val = unsafe_load(Ptr{Float32}(pointer(bytes, pos)))
    end
    (ltoh(val), pos + 4)
end

"""
    read_f64(bytes::Vector{UInt8}, pos::Int) -> Tuple{Float64, Int}

Read a 64-bit float in little-endian format (IEEE 754).
Returns the value and the next position.
"""
function read_f64(bytes::Vector{UInt8}, pos::Int)::Tuple{Float64, Int}
    @boundscheck checkbounds(bytes, pos:pos+7)
    GC.@preserve bytes begin
        @inbounds val = unsafe_load(Ptr{Float64}(pointer(bytes, pos)))
    end
    (ltoh(val), pos + 8)
end

"""
    read_string(bytes::Vector{UInt8}, pos::Int) -> Tuple{String, Int}

Read a length-prefixed string. The length is a 32-bit little-endian unsigned integer,
followed by that many bytes of character data.
Returns the string and the next position.
"""
function read_string(bytes::Vector{UInt8}, pos::Int)::Tuple{String, Int}
    len, pos = read_u32(bytes, pos)
    if len == 0
        return ("", pos)
    end
    n = Int(len)
    @boundscheck checkbounds(bytes, pos:pos+n-1)
    str = GC.@preserve bytes unsafe_string(pointer(bytes, pos), n)
    (str, pos + n)
end
