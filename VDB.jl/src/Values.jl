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
                all_values[i+1] = active_values[active_idx]
                active_idx += 1
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
    read_leaf_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::LeafMask, background::T) -> Tuple{NTuple{512,T}, Int}

Wrapper for read_dense_values for LeafNodes.
"""
function read_leaf_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::LeafMask, background::T)::Tuple{NTuple{512,T}, Int} where T
    values, pos = read_dense_values(T, bytes, pos, codec, mask, background)
    (NTuple{512, T}(values), pos)
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
    materialize_leaf(::Type{T}, topo::LeafTopology, values::NTuple{512,T}) -> LeafNode{T}

Create a LeafNode from topology and values.
"""
function materialize_leaf(::Type{T}, topo::LeafTopology, values::NTuple{512,T})::LeafNode{T} where T
    LeafNode{T}(topo.origin, topo.value_mask, values)
end

"""
    materialize_internal1(::Type{T}, topo::Internal1Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T) -> Tuple{InternalNode1{T}, Int}

Create an InternalNode1 from topology, reading values from bytes.
"""
function materialize_internal1(::Type{T}, topo::Internal1Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T)::Tuple{InternalNode1{T}, Int} where T
    child_count = count_on(topo.child_mask)
    tile_count = count_on(topo.value_mask)

    table = Vector{Union{LeafNode{T}, Tile{T}}}(undef, child_count + tile_count)

    # Read tile values first
    tile_idx = 1
    for _ in on_indices(topo.value_mask)
        value, pos = read_tile_value(T, bytes, pos)
        active_byte, pos = read_u8(bytes, pos)
        table[child_count + tile_idx] = Tile{T}(value, active_byte != 0)
        tile_idx += 1
    end

    # Materialize children
    for (i, child_topo) in enumerate(topo.children)
        if child_topo !== nothing
            values, pos = read_leaf_values(T, bytes, pos, codec, child_topo.value_mask, background)
            table[i] = materialize_leaf(T, child_topo, values)
        end
    end

    node = InternalNode1{T}(topo.origin, topo.child_mask, topo.value_mask, table)
    (node, pos)
end

"""
    materialize_internal2(::Type{T}, topo::Internal2Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T) -> Tuple{InternalNode2{T}, Int}

Create an InternalNode2 from topology, reading values from bytes.
"""
function materialize_internal2(::Type{T}, topo::Internal2Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T)::Tuple{InternalNode2{T}, Int} where T
    child_count = count_on(topo.child_mask)
    tile_count = count_on(topo.value_mask)

    table = Vector{Union{InternalNode1{T}, Tile{T}}}(undef, child_count + tile_count)

    # Read tile values first
    tile_idx = 1
    for _ in on_indices(topo.value_mask)
        value, pos = read_tile_value(T, bytes, pos)
        active_byte, pos = read_u8(bytes, pos)
        table[child_count + tile_idx] = Tile{T}(value, active_byte != 0)
        tile_idx += 1
    end

    # Materialize children
    for (i, child_topo) in enumerate(topo.children)
        if child_topo !== nothing
            child, pos = materialize_internal1(T, child_topo, bytes, pos, codec, background)
            table[i] = child
        end
    end

    node = InternalNode2{T}(topo.origin, topo.child_mask, topo.value_mask, table)
    (node, pos)
end

"""
    materialize_tree(::Type{T}, topo::RootTopology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T) -> Tuple{Tree{T}, Int}

Create a complete Tree from root topology, reading all values from bytes.
"""
function materialize_tree(::Type{T}, topo::RootTopology, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T)::Tuple{Tree{T}, Int} where T
    table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()

    for (origin, is_tile, child_topo) in topo.entries
        if child_topo === nothing
            # It's a tile
            value, pos = read_tile_value(T, bytes, pos)
            active_byte, pos = read_u8(bytes, pos)
            table[origin] = Tile{T}(value, active_byte != 0)
        else
            # It's a child
            child, pos = materialize_internal2(T, child_topo, bytes, pos, codec, background)
            table[origin] = child
        end
    end

    tree = RootNode{T}(background, table)
    (tree, pos)
end
