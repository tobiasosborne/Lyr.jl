# Values.jl - Parse node values

"""
    read_dense_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::Mask{N,W}, background::T) -> Tuple{Vector{T}, Int}

Read node values from bytes using VDB's internal compression schemes. Returns a dense vector of size N.
Used for both LeafNodes and InternalNodes.
"""
function read_dense_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::Mask{N,W}, background::T)::Tuple{Vector{T}, Int} where {T,N,W}
    # 1. Read metadata byte
    metadata, pos = read_u8(bytes, pos)

    # Inactive values based on metadata
    inactive_val1 = background
    inactive_val2 = background

    if metadata == 0 # NO_MASK_OR_INACTIVE_VALS
        inactive_val1 = background
    elseif metadata == 1 # NO_MASK_AND_MINUS_BG
        # For floats, this is -background.
        inactive_val1 = -background
    elseif metadata == 2 # NO_MASK_AND_ONE_INACTIVE_VAL
        inactive_val1, pos = read_tile_value(T, bytes, pos)
    elseif metadata == 3 # MASK_AND_NO_INACTIVE_VALS
        inactive_val1 = background
        inactive_val2 = -background
    elseif metadata == 4 # MASK_AND_ONE_INACTIVE_VAL
        inactive_val1 = background
        inactive_val2, pos = read_tile_value(T, bytes, pos)
    elseif metadata == 5 # MASK_AND_TWO_INACTIVE_VALS
        inactive_val1, pos = read_tile_value(T, bytes, pos)
        inactive_val2, pos = read_tile_value(T, bytes, pos)
    end

    # 3. Read selection mask if metadata is 3, 4, or 5
    selection_mask = nothing
    if 3 <= metadata <= 5
        selection_mask, pos = read_mask(Mask{N,W}, bytes, pos)
    end

    # 4. Read active values
    active_count = count_on(mask)

    expected_size = if metadata == 6 # NO_MASK_AND_ALL_VALS
        N * sizeof(T)
    else
        active_count * sizeof(T)
    end

    # Always call read_compressed_bytes to handle stream structure (e.g. size prefix)
    data, pos = read_compressed_bytes(bytes, pos, codec, expected_size)
    active_values = reinterpret(T, data)

    # 5. Assemble final values array
    all_values = Vector{T}(undef, N)

    if metadata == 6 # NO_MASK_AND_ALL_VALS
        # All values are stored densely, regardless of mask
        for i in 1:N
            all_values[i] = active_values[i]
        end
    else
        # Sparse storage: only active values are stored
        active_idx = 1
        for i in 0:(N-1)
            if is_on(mask, i)
                # Safely access active values
                if active_idx <= length(active_values)
                    all_values[i+1] = active_values[active_idx]
                    active_idx += 1
                else
                    # Fallback if active values are missing (e.g. chunk_size=0)
                    all_values[i+1] = inactive_val1
                end
            else
                # Inactive value reconstruction
                if selection_mask !== nothing
                    all_values[i+1] = is_on(selection_mask, i) ? inactive_val2 : inactive_val1
                else
                    all_values[i+1] = inactive_val1
                end
            end
        end
    end

    (all_values, pos)
end

"""
    read_leaf_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::LeafMask, background::T, version::UInt32) -> Tuple{NTuple{512,T}, Int}

Wrapper for read_dense_values for LeafNodes.
"""
function read_leaf_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::LeafMask, background::T, version::UInt32)::Tuple{NTuple{512,T}, Int} where T
    if version < 222
        # v220: Raw active values, no metadata
        active_count = count_on(mask)
        active_values, pos = read_active_values(T, bytes, pos, active_count)

        # Scatter
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
        values, pos = read_dense_values(T, bytes, pos, codec, mask, background)
        (NTuple{512, T}(values), pos)
    end
end

"""
    read_tile_value(::Type{T}, bytes::Vector{UInt8}, pos::Int) -> Tuple{T, Int}

Read a single tile value.
"""
function read_tile_value(::Type{T}, bytes::Vector{UInt8}, pos::Int)::Tuple{T, Int} where T
    data, pos = read_bytes(bytes, pos, sizeof(T))
    value = reinterpret(T, data)[1]
    (value, pos)
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
