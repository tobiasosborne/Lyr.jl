# Values.jl - Parse values and combine with topology

"""
    read_dense_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::Mask{N,W}, background::T) -> Tuple{Vector{T}, Int}

Read node values from bytes using VDB's internal compression schemes. Returns a dense vector of size N.
Used for both LeafNodes and InternalNodes.
"""
function read_dense_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::Mask{N,W}, background::T)::Tuple{Vector{T}, Int} where {T,N,W}
    # 1. Read metadata byte
    metadata, pos = read_u8(bytes, pos)
    # println("DEBUG: read_dense_values pos=$(pos-1) metadata=$metadata N=$N")

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
        # NOTE: v220 format is not yet fully supported
        # v220 uses Blosc compression for leaf values, but the format differs from v222
        # This code path will cause BoundsError on large v220 files like bunny_cloud.vdb
        # See: https://github.com/tobiasosborne/Lyr.jl/issues (v220 support tracking)
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
        # Validate decompressed values length before NTuple construction
        if length(values) != 512
            throw(ValueCountError(512, length(values)))
        end
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
                # Keep pos at EOF or increment? 
                # If we are at EOF, we can't read more. 
                # Just keep pos as is (or increment virtually?)
                # Incrementing virtually ensures we don't get stuck if we loop?
                # But read_tile_value usually increments pos.
                # If we failed, pos was not updated by read_tile_value.
                # We should advance pos to avoid infinite loops if any.
                # But here we just return vals.
            else
                rethrow(e)
            end
        end
    end
    (vals, pos)
end

"""
    materialize_leaf(::Type{T}, topo::LeafTopology, values::NTuple{512,T}) -> LeafNode{T}

Create a LeafNode from topology and values.
"""
function materialize_leaf(::Type{T}, topo::LeafTopology, values::NTuple{512,T})::LeafNode{T} where T
    LeafNode{T}(topo.origin, topo.value_mask, values)
end

# =============================================================================
# Generic internal node materialization pattern
# =============================================================================

"""
    _read_internal_tiles!(::Type{T}, table::Vector, bytes::Vector{UInt8}, pos::Int,
                          value_mask, child_count::Int) -> Int

Read tile values for an internal node, storing them after children in the table.
Returns the new file position.
"""
function _read_internal_tiles!(::Type{T}, table::Vector, bytes::Vector{UInt8}, pos::Int,
                               value_mask, child_count::Int)::Int where T
    tile_idx = 1
    for _ in on_indices(value_mask)
        value, pos = read_tile_value(T, bytes, pos)
        active_byte, pos = read_u8(bytes, pos)
        table[child_count + tile_idx] = Tile{T}(value, active_byte != 0)
        tile_idx += 1
    end
    pos
end

"""
    materialize_internal1(::Type{T}, topo::Internal1Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, version::UInt32) -> Tuple{InternalNode1{T}, Int}

Create an InternalNode1 from topology, reading values from bytes.
"""
function materialize_internal1(::Type{T}, topo::Internal1Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, version::UInt32)::Tuple{InternalNode1{T}, Int} where T
    child_count = count_on(topo.child_mask)
    tile_count = count_on(topo.value_mask)
    table = Vector{Union{LeafNode{T}, Tile{T}}}(undef, child_count + tile_count)

    # Read tiles
    pos = _read_internal_tiles!(T, table, bytes, pos, topo.value_mask, child_count)

    # Materialize leaf children
    for (i, child_topo) in enumerate(topo.children)
        if child_topo !== nothing
            values, pos = read_leaf_values(T, bytes, pos, codec, child_topo.value_mask, background, version)
            table[i] = materialize_leaf(T, child_topo, values)
        end
    end

    (InternalNode1{T}(topo.origin, topo.child_mask, topo.value_mask, table), pos)
end

"""
    materialize_internal2(::Type{T}, topo::Internal2Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, version::UInt32) -> Tuple{InternalNode2{T}, Int}

Create an InternalNode2 from topology, reading values from bytes.
"""
function materialize_internal2(::Type{T}, topo::Internal2Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, version::UInt32)::Tuple{InternalNode2{T}, Int} where T
    child_count = count_on(topo.child_mask)
    tile_count = count_on(topo.value_mask)
    table = Vector{Union{InternalNode1{T}, Tile{T}}}(undef, child_count + tile_count)

    # Read tiles
    pos = _read_internal_tiles!(T, table, bytes, pos, topo.value_mask, child_count)

    # Materialize Internal1 children
    for (i, child_topo) in enumerate(topo.children)
        if child_topo !== nothing
            table[i], pos = materialize_internal1(T, child_topo, bytes, pos, codec, background, version)
        end
    end

    (InternalNode2{T}(topo.origin, topo.child_mask, topo.value_mask, table), pos)
end

"""
    materialize_tree(::Type{T}, topo::RootTopology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, version::UInt32) -> Tuple{Tree{T}, Int}

Create a complete Tree from root topology, reading all values from bytes.
"""
function materialize_tree(::Type{T}, topo::RootTopology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, version::UInt32)::Tuple{Tree{T}, Int} where T
    table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()

    for (origin, is_tile, child_topo) in topo.entries
        if child_topo === nothing
            # It's a tile
            value, pos = read_tile_value(T, bytes, pos)
            active_byte, pos = read_u8(bytes, pos)
            table[origin] = Tile{T}(value, active_byte != 0)
        else
            # It's a child
            child, pos = materialize_internal2(T, child_topo, bytes, pos, codec, background, version)
            table[origin] = child
        end
    end

    tree = RootNode{T}(background, table)
    (tree, pos)
end
