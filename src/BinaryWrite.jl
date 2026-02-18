# BinaryWrite.jl - Pure functions for writing primitive types to IO streams
#
# All functions have signature: (io::IO, val) -> nothing
# All multi-byte types are little-endian
# This is the exact inverse of Binary.jl
#
# Design: write to IO streams (not byte vectors) for efficient file output.
# The IO abstraction supports both files and in-memory IOBuffer.

using Base: htol

"""
    write_u8!(io::IO, val::UInt8) -> Nothing

Write a single unsigned byte.
"""
function write_u8!(io::IO, val::UInt8)::Nothing
    write(io, val)
    nothing
end

"""
    write_u32_le!(io::IO, val::UInt32) -> Nothing

Write a 32-bit unsigned integer in little-endian format.
"""
function write_u32_le!(io::IO, val::UInt32)::Nothing
    write(io, htol(val))
    nothing
end

"""
    write_u64_le!(io::IO, val::UInt64) -> Nothing

Write a 64-bit unsigned integer in little-endian format.
"""
function write_u64_le!(io::IO, val::UInt64)::Nothing
    write(io, htol(val))
    nothing
end

"""
    write_i32_le!(io::IO, val::Int32) -> Nothing

Write a 32-bit signed integer in little-endian format.
"""
function write_i32_le!(io::IO, val::Int32)::Nothing
    write(io, htol(val))
    nothing
end

"""
    write_i64_le!(io::IO, val::Int64) -> Nothing

Write a 64-bit signed integer in little-endian format.
"""
function write_i64_le!(io::IO, val::Int64)::Nothing
    write(io, htol(val))
    nothing
end

"""
    write_f16_le!(io::IO, val::Float16) -> Nothing

Write a 16-bit (half-precision) float in little-endian format.
"""
function write_f16_le!(io::IO, val::Float16)::Nothing
    write(io, htol(val))
    nothing
end

"""
    write_f32_le!(io::IO, val::Float32) -> Nothing

Write a 32-bit float in little-endian format.
"""
function write_f32_le!(io::IO, val::Float32)::Nothing
    write(io, htol(val))
    nothing
end

"""
    write_f64_le!(io::IO, val::Float64) -> Nothing

Write a 64-bit float in little-endian format.
"""
function write_f64_le!(io::IO, val::Float64)::Nothing
    write(io, htol(val))
    nothing
end

"""
    write_bytes!(io::IO, data::Vector{UInt8}) -> Nothing

Write a raw byte vector.
"""
function write_bytes!(io::IO, data::Vector{UInt8})::Nothing
    write(io, data)
    nothing
end

"""
    write_cstring!(io::IO, s::String) -> Nothing

Write a null-terminated C string.
"""
function write_cstring!(io::IO, s::String)::Nothing
    write(io, Vector{UInt8}(s))
    write(io, UInt8(0x00))
    nothing
end

"""
    write_string_with_size!(io::IO, s::String) -> Nothing

Write a size-prefixed string. The size is a 32-bit little-endian integer
giving the byte length of the string (no null terminator).
"""
function write_string_with_size!(io::IO, s::String)::Nothing
    data = Vector{UInt8}(s)
    write_u32_le!(io, UInt32(length(data)))
    if !isempty(data)
        write(io, data)
    end
    nothing
end

"""
    write_tile_value!(io::IO, val::T) -> Nothing

Write a single tile/voxel value. Specializations for all supported VDB value types.
Generic fallback errors to prevent silent corruption.
"""
function write_tile_value!(io::IO, val::T)::Nothing where T
    throw(ArgumentError("write_tile_value!: no specialization for type $T — add one to BinaryWrite.jl"))
end

function write_tile_value!(io::IO, val::Float32)::Nothing
    write_f32_le!(io, val)
end

function write_tile_value!(io::IO, val::Float64)::Nothing
    write_f64_le!(io, val)
end

function write_tile_value!(io::IO, val::Int32)::Nothing
    write_i32_le!(io, val)
end

function write_tile_value!(io::IO, val::Int64)::Nothing
    write_i64_le!(io, val)
end

function write_tile_value!(io::IO, val::Bool)::Nothing
    write_u8!(io, val ? UInt8(0x01) : UInt8(0x00))
end

"""
    write_tile_value!(io::IO, val::NTuple{3, Float32}) -> Nothing

Write a Vec3f (3 consecutive Float32 values).
"""
function write_tile_value!(io::IO, val::NTuple{3, Float32})::Nothing
    write_f32_le!(io, val[1])
    write_f32_le!(io, val[2])
    write_f32_le!(io, val[3])
end

"""
    write_tile_value!(io::IO, val::NTuple{3, Float64}) -> Nothing

Write a Vec3d (3 consecutive Float64 values).
"""
function write_tile_value!(io::IO, val::NTuple{3, Float64})::Nothing
    write_f64_le!(io, val[1])
    write_f64_le!(io, val[2])
    write_f64_le!(io, val[3])
end
