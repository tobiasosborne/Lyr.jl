# Values.jl - Parse node values

"""
    read_dense_values(::Type{T}, bytes, pos, codec, mask_compressed, mask, background; value_size) -> Tuple{Vector{T}, Int}

Read node values from bytes using VDB's ReadMaskValues algorithm. Returns a dense vector of size N.
Used for both LeafNodes and InternalNodes.

`value_size` is the on-disk element size (2 for half-precision Float16, otherwise sizeof(T)).
"""
function read_dense_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, mask::Mask{N,W}, background::T; value_size::Int=sizeof(T))::Tuple{Vector{T}, Int} where {T,N,W}
    is_half = (value_size == 2 && sizeof(T) == 4)

    # 1. Read metadata byte
    metadata, pos = read_u8(bytes, pos)

    # 2. Inactive values based on metadata
    inactive_val1 = background
    inactive_val2 = background

    if metadata == 0 # NO_MASK_OR_INACTIVE_VALS
        inactive_val1 = background
    elseif metadata == 1 # NO_MASK_AND_MINUS_BG
        inactive_val1 = -background
    elseif metadata == 2 # NO_MASK_AND_ONE_INACTIVE_VAL
        inactive_val1, pos = _read_value(T, bytes, pos, is_half)
    elseif metadata == 3 # MASK_AND_NO_INACTIVE_VALS
        inactive_val1 = background
        inactive_val2 = -background
    elseif metadata == 4 # MASK_AND_ONE_INACTIVE_VAL
        inactive_val1 = background
        inactive_val2, pos = _read_value(T, bytes, pos, is_half)
    elseif metadata == 5 # MASK_AND_TWO_INACTIVE_VALS
        inactive_val1, pos = _read_value(T, bytes, pos, is_half)
        inactive_val2, pos = _read_value(T, bytes, pos, is_half)
    end

    # 3. Read selection mask if metadata is 3, 4, or 5
    selection_mask = nothing
    if 3 <= metadata <= 5
        selection_mask, pos = read_mask(Mask{N,W}, bytes, pos)
    end

    # 4. Determine how many values to read
    active_count = count_on(mask)
    use_sparse = mask_compressed && metadata != 6

    expected_size = if use_sparse
        active_count * value_size
    else
        N * value_size
    end

    # Read compressed data
    data, pos = read_compressed_bytes(bytes, pos, codec, expected_size)
    stored_values = if is_half
        T.(reinterpret(Float16, data))
    else
        reinterpret(T, data)
    end

    # 5. Assemble final values array
    all_values = Vector{T}(undef, N)

    if use_sparse
        active_idx = 1
        for i in 0:(N-1)
            if is_on(mask, i)
                if active_idx <= length(stored_values)
                    all_values[i+1] = stored_values[active_idx]
                    active_idx += 1
                else
                    all_values[i+1] = inactive_val1
                end
            else
                if selection_mask !== nothing
                    all_values[i+1] = is_on(selection_mask, i) ? inactive_val2 : inactive_val1
                else
                    all_values[i+1] = inactive_val1
                end
            end
        end
    else
        for i in 1:N
            if i <= length(stored_values)
                all_values[i] = stored_values[i]
            else
                all_values[i] = inactive_val1
            end
        end
    end

    (all_values, pos)
end

"""
    _read_value(::Type{T}, bytes, pos, is_half) -> Tuple{T, Int}

Read a single value, handling half-precision (Float16 → T widening).
"""
function _read_value(::Type{T}, bytes::Vector{UInt8}, pos::Int, is_half::Bool)::Tuple{T, Int} where T
    if is_half
        @boundscheck checkbounds(bytes, pos:pos+1)
        @inbounds val = T(reinterpret(Float16, bytes[pos:pos+1])[1])
        (val, pos + 2)
    else
        read_tile_value(T, bytes, pos)
    end
end

"""
    read_leaf_values(::Type{T}, bytes, pos, codec, mask_compressed, mask, background, version; value_size) -> Tuple{NTuple{512,T}, Int}

Read leaf node values. Dispatches to v220 (interleaved) or v222+ (ReadMaskValues) format.
"""
function read_leaf_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, mask::LeafMask, background::T, version::UInt32; value_size::Int=sizeof(T))::Tuple{NTuple{512,T}, Int} where T
    if version < 222
        # v220/v221: Origin + numBuffers precede values (13 bytes)
        pos += 12  # skip origin (3 × Int32)
        pos += 1   # skip numBuffers (Int8)

        active_count = count_on(mask)
        expected_size = active_count * sizeof(T)

        data, pos = read_compressed_bytes(bytes, pos, codec, expected_size)
        active_values = reinterpret(T, data)

        all_values = Vector{T}(undef, 512)
        active_idx = 1
        for i in 0:511
            if is_on(mask, i)
                if active_idx <= length(active_values)
                    all_values[i+1] = active_values[active_idx]
                    active_idx += 1
                else
                    all_values[i+1] = background
                end
            else
                all_values[i+1] = background
            end
        end
        (NTuple{512, T}(all_values), pos)
    else
        # v222+ buffer pass: each leaf re-emits its value_mask (64 bytes) before ReadMaskValues data.
        # Skip it — already read during topology pass.
        pos += 64
        values, pos = read_dense_values(T, bytes, pos, codec, mask_compressed, mask, background; value_size)
        (NTuple{512, T}(values), pos)
    end
end

"""
    read_tile_value(::Type{T}, bytes::Vector{UInt8}, pos::Int) -> Tuple{T, Int}

Read a single tile value using direct pointer load (zero-copy).
"""
function read_tile_value(::Type{T}, bytes::Vector{UInt8}, pos::Int)::Tuple{T, Int} where T
    n = sizeof(T)
    @boundscheck checkbounds(bytes, pos:pos+n-1)
    GC.@preserve bytes begin
        @inbounds val = unsafe_load(Ptr{T}(pointer(bytes, pos)))
    end
    (ltoh(val), pos + n)
end

# Specializations for common types
function read_tile_value(::Type{Float32}, bytes::Vector{UInt8}, pos::Int)::Tuple{Float32, Int}
    read_f32_le(bytes, pos)
end

function read_tile_value(::Type{Float64}, bytes::Vector{UInt8}, pos::Int)::Tuple{Float64, Int}
    read_f64_le(bytes, pos)
end

"""
    read_active_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, count::Int) -> Tuple{Vector{T}, Int}

Read `count` values of type T sequentially. Resilient to EOF.
"""
function read_active_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, count::Int)::Tuple{Vector{T}, Int} where T
    vals = Vector{T}(undef, count)
    for i in 1:count
        try
            vals[i], pos = read_tile_value(T, bytes, pos)
        catch e
            if isa(e, BoundsError)
                # Handle EOF gracefully by padding with zero
                vals[i] = zero(T)
            else
                rethrow(e)
            end
        end
    end
    (vals, pos)
end

# =============================================================================
# Vec3 specializations (VDB stores vectors as 3 consecutive floats)
# =============================================================================

"""
    read_tile_value(::Type{NTuple{3, Float32}}, bytes, pos) -> Tuple{NTuple{3, Float32}, Int}

Read a Vec3f (3 consecutive Float32 values).
"""
function read_tile_value(::Type{NTuple{3, Float32}}, bytes::Vector{UInt8}, pos::Int)::Tuple{NTuple{3, Float32}, Int}
    x, pos = read_f32_le(bytes, pos)
    y, pos = read_f32_le(bytes, pos)
    z, pos = read_f32_le(bytes, pos)
    ((x, y, z), pos)
end

"""
    read_tile_value(::Type{NTuple{3, Float64}}, bytes, pos) -> Tuple{NTuple{3, Float64}, Int}

Read a Vec3d (3 consecutive Float64 values).
"""
function read_tile_value(::Type{NTuple{3, Float64}}, bytes::Vector{UInt8}, pos::Int)::Tuple{NTuple{3, Float64}, Int}
    x, pos = read_f64_le(bytes, pos)
    y, pos = read_f64_le(bytes, pos)
    z, pos = read_f64_le(bytes, pos)
    ((x, y, z), pos)
end
