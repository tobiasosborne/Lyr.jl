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

Read a complete Internal2 subtree.
Format (verified against OpenVDB source for 222+):
1. I2 Masks (Child + Value)
2. I2 Tile Values (Compressed, Dense) - Note: In 222, tiles are stored here!
3. For each active I1 child:
    a. I1 Masks (Child + Value)
    b. I1 Tile Values (Compressed, Dense)
    c. For each active Leaf child:
        i. Leaf Value Mask
4. Phase 2 (Leaf Values):
    a. For each active I1 child:
        i. For each active Leaf child:
            1. Leaf Values (Compressed)
"""
function read_internal2_subtree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, origin::Coord, background::T, version::UInt32)::Tuple{InternalNode2{T}, Int} where T
    # --- Phase 1: Topology and Internal Values ---

    # For v220, InternalNode tiles seem to be uncompressed (no chunk size prefix)
    # or follow a different compression scheme that matches NoCompression logic (raw data or metadata-only)
    tile_codec = if version < 222
        NoCompression()
    else
        codec
    end

    # 1. Read Internal2 Masks
    i2_child_mask, pos = read_mask(Internal2Mask, bytes, pos)
    i2_value_mask, pos = read_mask(Internal2Mask, bytes, pos)

    # 2. Read Internal2 Tile Values (Compressed Dense Array)
    i2_dense_vals, pos = read_dense_values(T, bytes, pos, tile_codec, i2_value_mask, background)

    # Collect Internal1 children data
    internal1_data = Vector{Tuple{Coord, Internal1Mask, Internal1Mask, Vector{T}, Vector{Tuple{Coord, LeafMask}}}}()

    for child_idx in on_indices(i2_child_mask)
        i1_origin = child_origin_internal2(origin, child_idx)

        # 3a. Read Internal1 Masks
        i1_child_mask, pos = read_mask(Internal1Mask, bytes, pos)
        i1_value_mask, pos = read_mask(Internal1Mask, bytes, pos)

        # 3b. Read Internal1 Tile Values (Compressed Dense Array)
        i1_dense_vals, pos = read_dense_values(T, bytes, pos, tile_codec, i1_value_mask, background)

        # 3c. Read Leaf Masks
        leaves = Vector{Tuple{Coord, LeafMask}}()
        for leaf_idx in on_indices(i1_child_mask)
            leaf_origin = child_origin_internal1(i1_origin, leaf_idx)
            leaf_mask, pos = read_mask(LeafMask, bytes, pos)
            push!(leaves, (leaf_origin, leaf_mask))
        end

        push!(internal1_data, (i1_origin, i1_child_mask, i1_value_mask, i1_dense_vals, leaves))
    end

    # --- Phase 2: Leaf Values ---

    i1_children = Vector{InternalNode1{T}}()

    for (i1_origin, i1_child_mask, i1_value_mask, i1_dense_vals, leaf_topos) in internal1_data
        
        # Construct Leaf Nodes
        leaves = Vector{LeafNode{T}}()
        for (leaf_origin, leaf_mask) in leaf_topos
            values, pos = read_leaf_values(T, bytes, pos, codec, leaf_mask, background)
            push!(leaves, LeafNode{T}(leaf_origin, leaf_mask, values))
        end

        # Construct Internal1 Node
        i1_child_count = count_on(i1_child_mask)
        i1_tile_count = count_on(i1_value_mask)
        i1_table = Vector{Union{LeafNode{T}, Tile{T}}}(undef, i1_child_count + i1_tile_count)

        # Add children (Leaves)
        for (i, leaf) in enumerate(leaves)
            i1_table[i] = leaf
        end

        # Add tiles (from dense values)
        tile_idx = 1
        for idx in on_indices(i1_value_mask)
            val = i1_dense_vals[idx + 1] # 1-based
            i1_table[i1_child_count + tile_idx] = Tile{T}(val, true)
            tile_idx += 1
        end

        push!(i1_children, InternalNode1{T}(i1_origin, i1_child_mask, i1_value_mask, i1_table))
    end

    # Construct Internal2 Node
    i2_child_count = count_on(i2_child_mask)
    i2_tile_count = count_on(i2_value_mask)
    i2_table = Vector{Union{InternalNode1{T}, Tile{T}}}(undef, i2_child_count + i2_tile_count)

    # Add children (Internal1s)
    for (i, child) in enumerate(i1_children)
        i2_table[i] = child
    end

    # Add tiles (from dense values)
    tile_idx = 1
    for idx in on_indices(i2_value_mask)
        val = i2_dense_vals[idx + 1] # 1-based
        i2_table[i2_child_count + tile_idx] = Tile{T}(val, true)
        tile_idx += 1
    end

    node = InternalNode2{T}(origin, i2_child_mask, i2_value_mask, i2_table)
    (node, pos)
end

"""
    read_tree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, grid_class::GridClass, version::UInt32) -> Tuple{Tree{T}, Int}

Read a complete VDB tree structure, handling interleaved topology and values.

Root format (interleaved - each entry is complete before the next):
- background_active (1 byte, only for fog volumes AND version >= 222)
- tile_count (4 bytes)
- child_count (4 bytes)
- For each tile: origin (12 bytes) + value (sizeof(T)) + active (1 byte)
- For each child: origin (12 bytes) + Internal2 subtree (topology then values)

Note: Tiles come first, then children. Each entry is complete before the next.
"""
function read_tree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, grid_class::GridClass, version::UInt32)::Tuple{Tree{T}, Int} where T
    # Read background_active (only for fog volumes)
    # Appears to be absent in v220 files (bunny_cloud.vdb)
    background_active = false
    if (grid_class == GRID_FOG_VOLUME || grid_class == GRID_UNKNOWN) && version >= 222
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

        child, pos = read_internal2_subtree(T, bytes, pos, codec, origin, background, version)
        table[origin] = child
    end

    tree = RootNode{T}(background, table)
    (tree, pos)
end