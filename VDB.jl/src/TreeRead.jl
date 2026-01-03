# TreeRead.jl - Combined topology + value parsing
#
# VDB files store topology and values interleaved at the subtree level:
# For each Internal2 subtree:
#   1. All topology (Internal2 masks, then Internal1 masks, then Leaf masks)
#   2. All values (tile values, then leaf values)
#
# This module provides combined reading functions that handle this format.

"""
    read_leaf_node(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, origin::Coord) -> Tuple{LeafNode{T}, Int}

Read a complete leaf node (topology mask only - values read later in batch).
Returns the topology info needed; values are read separately after all leaf masks.
"""
function read_leaf_node(::Type{T}, bytes::Vector{UInt8}, pos::Int, origin::Coord)::Tuple{LeafTopology, Int} where T
    mask, pos = read_mask(LeafMask, bytes, pos)
    (LeafTopology(origin, mask), pos)
end

"""
    read_internal2_subtree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, origin::Coord, background::T) -> Tuple{InternalNode2{T}, Int}

Read a complete Internal2 subtree (topology then values).

VDB format for Internal2 subtree:
1. Internal2 child_mask + value_mask (8192 bytes)
2. For each Internal1 child: child_mask + value_mask (1024 bytes each)
3. For each Leaf (nested): value_mask (64 bytes each)
4. Internal2 tile values
5. For each Internal1: tile values + leaf compressed values
"""
function read_internal2_subtree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, origin::Coord, background::T)::Tuple{InternalNode2{T}, Int} where T
    # Phase 1: Read all topology

    # Read Internal2 masks
    i2_child_mask, pos = read_mask(Internal2Mask, bytes, pos)
    i2_value_mask, pos = read_mask(Internal2Mask, bytes, pos)

    i2_child_count = count_on(i2_child_mask)
    i2_tile_count = count_on(i2_value_mask)

    # Collect Internal1 topology and Leaf topology
    # Structure: Vector of (Internal1 info, Vector of Leaf info)
    internal1_data = Vector{Tuple{Coord, Internal1Mask, Internal1Mask, Vector{Tuple{Coord, LeafMask}}}}()

    for child_idx in on_indices(i2_child_mask)
        i1_origin = child_origin_internal2(origin, child_idx)

        # Read Internal1 masks
        i1_child_mask, pos = read_mask(Internal1Mask, bytes, pos)
        i1_value_mask, pos = read_mask(Internal1Mask, bytes, pos)

        # Read Leaf masks for this Internal1
        leaves = Vector{Tuple{Coord, LeafMask}}()
        for leaf_idx in on_indices(i1_child_mask)
            leaf_origin = child_origin_internal1(i1_origin, leaf_idx)
            leaf_mask, pos = read_mask(LeafMask, bytes, pos)
            push!(leaves, (leaf_origin, leaf_mask))
        end

        push!(internal1_data, (i1_origin, i1_child_mask, i1_value_mask, leaves))
    end

    # Phase 2: Read all values

    # Read Internal2 tile values
    i2_tiles = Vector{Tile{T}}()
    for _ in 1:i2_tile_count
        value, pos = read_tile_value(T, bytes, pos)
        active_byte, pos = read_u8(bytes, pos)
        push!(i2_tiles, Tile{T}(value, active_byte != 0))
    end

    # Read Internal1 children with their values
    i1_children = Vector{InternalNode1{T}}()

    for (i1_origin, i1_child_mask, i1_value_mask, leaf_topos) in internal1_data
        i1_child_count = count_on(i1_child_mask)
        i1_tile_count = count_on(i1_value_mask)

        # Read Internal1 tile values
        i1_tiles = Vector{Tile{T}}()
        for _ in 1:i1_tile_count
            value, pos = read_tile_value(T, bytes, pos)
            active_byte, pos = read_u8(bytes, pos)
            push!(i1_tiles, Tile{T}(value, active_byte != 0))
        end

        # Read leaf values (compressed)
        leaves = Vector{LeafNode{T}}()
        for (leaf_origin, leaf_mask) in leaf_topos
            values, pos = read_leaf_values(T, bytes, pos, codec, leaf_mask, background)
            push!(leaves, LeafNode{T}(leaf_origin, leaf_mask, values))
        end

        # Build Internal1 table
        i1_table = Vector{Union{LeafNode{T}, Tile{T}}}(undef, i1_child_count + i1_tile_count)
        for (i, leaf) in enumerate(leaves)
            i1_table[i] = leaf
        end
        for (i, tile) in enumerate(i1_tiles)
            i1_table[i1_child_count + i] = tile
        end

        push!(i1_children, InternalNode1{T}(i1_origin, i1_child_mask, i1_value_mask, i1_table))
    end

    # Build Internal2 table
    i2_table = Vector{Union{InternalNode1{T}, Tile{T}}}(undef, i2_child_count + i2_tile_count)
    for (i, child) in enumerate(i1_children)
        i2_table[i] = child
    end
    for (i, tile) in enumerate(i2_tiles)
        i2_table[i2_child_count + i] = tile
    end

    node = InternalNode2{T}(origin, i2_child_mask, i2_value_mask, i2_table)
    (node, pos)
end

"""
    read_tree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, grid_class::GridClass) -> Tuple{Tree{T}, Int}

Read a complete VDB tree structure, handling interleaved topology and values.

Root format (interleaved - each entry is complete before the next):
- background_active (1 byte, only for fog volumes)
- tile_count (4 bytes)
- child_count (4 bytes)
- For each tile: origin (12 bytes) + value (sizeof(T)) + active (1 byte)
- For each child: origin (12 bytes) + Internal2 subtree (topology then values)

Note: Tiles come first, then children. Each entry is complete before the next.
"""
function read_tree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, grid_class::GridClass)::Tuple{Tree{T}, Int} where T
    # Read background_active (only for fog volumes)
    background_active = false
    if grid_class == GRID_FOG_VOLUME || grid_class == GRID_UNKNOWN
        bg_byte, pos = read_u8(bytes, pos)
        background_active = bg_byte != 0
    end

    # Read counts
    tile_count, pos = read_u32_le(bytes, pos)
    child_count, pos = read_u32_le(bytes, pos)

    table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()

    # Read tiles (origin + value + active for each)
    for _ in 1:tile_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        value, pos = read_tile_value(T, bytes, pos)
        active_byte, pos = read_u8(bytes, pos)

        table[origin] = Tile{T}(value, active_byte != 0)
    end

    # Read children (origin + complete subtree for each)
    for _ in 1:child_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        child, pos = read_internal2_subtree(T, bytes, pos, codec, origin, background)
        table[origin] = child
    end

    tree = RootNode{T}(background, table)
    (tree, pos)
end
