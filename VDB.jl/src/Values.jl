# Values.jl - Parse values and combine with topology

"""
    read_leaf_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::LeafMask) -> Tuple{NTuple{512,T}, Int}

Read leaf voxel values from bytes.
"""
function read_leaf_values(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask::LeafMask)::Tuple{NTuple{512,T}, Int} where T
    # Calculate expected size
    expected_size = 512 * sizeof(T)

    # Read and decompress
    data, pos = read_compressed_bytes(bytes, pos, codec, expected_size)

    # Convert to values
    values = reinterpret(T, data)

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
    materialize_internal1(::Type{T}, topo::Internal1Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec) -> Tuple{InternalNode1{T}, Int}

Create an InternalNode1 from topology, reading values from bytes.
"""
function materialize_internal1(::Type{T}, topo::Internal1Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec)::Tuple{InternalNode1{T}, Int} where T
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
            values, pos = read_leaf_values(T, bytes, pos, codec, child_topo.value_mask)
            table[i] = materialize_leaf(T, child_topo, values)
        end
    end

    node = InternalNode1{T}(topo.origin, topo.child_mask, topo.value_mask, table)
    (node, pos)
end

"""
    materialize_internal2(::Type{T}, topo::Internal2Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec) -> Tuple{InternalNode2{T}, Int}

Create an InternalNode2 from topology, reading values from bytes.
"""
function materialize_internal2(::Type{T}, topo::Internal2Topology, bytes::Vector{UInt8}, pos::Int, codec::Codec)::Tuple{InternalNode2{T}, Int} where T
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
            child, pos = materialize_internal1(T, child_topo, bytes, pos, codec)
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
            child, pos = materialize_internal2(T, child_topo, bytes, pos, codec)
            table[origin] = child
        end
    end

    tree = RootNode{T}(background, table)
    (tree, pos)
end
