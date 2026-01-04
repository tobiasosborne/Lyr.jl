# TreeRead.jl - Combined topology + value parsing
#
# VDB file formats differ by version:
# - v222+: Topology and values are in separate sections (uses block_offset)
# - Pre-v222: Topology and values interleaved per-subtree
#
# This module handles both formats.

# =============================================================================
# Leaf selection mask type (for v222+)
# =============================================================================

"""
    LeafSelectionMask

A 64-byte mask indicating which voxels have stored values vs background.
Only used in v222+ format.
"""
const LeafSelectionMask = LeafMask

# =============================================================================
# Topology storage types (for collecting topology before reading values)
# =============================================================================

"""
    LeafTopoWithSelection

Leaf topology with optional selection mask (for v222+).
"""
struct LeafTopoWithSelection
    origin::Coord
    value_mask::LeafMask
    selection_mask::Union{LeafMask, Nothing}
end

"""
    I1TopoData

Internal1 topology data collected during Phase 1.
"""
struct I1TopoData
    origin::Coord
    child_mask::Internal1Mask
    value_mask::Internal1Mask
    leaves::Vector{LeafTopoWithSelection}
end

"""
    I2TopoData

Internal2 topology data collected during Phase 1.
"""
struct I2TopoData
    origin::Coord
    child_mask::Internal2Mask
    value_mask::Internal2Mask
    children::Vector{I1TopoData}
end

# =============================================================================
# Helper functions
# =============================================================================

"""
    read_internal_tiles(::Type{T}, bytes::Vector{UInt8}, pos::Int, mask::Mask{N,W}) -> Tuple{Vector{T}, Int}

Read tile values for an internal node.
Internal node tiles are stored as (value, active_byte) pairs for each set bit in the mask.
"""
function read_internal_tiles(::Type{T}, bytes::Vector{UInt8}, pos::Int, mask::Mask{N,W})::Tuple{Vector{T}, Int} where {T,N,W}
    count = count_on(mask)
    vals = Vector{T}(undef, count)
    for i in 1:count
        vals[i], pos = read_tile_value(T, bytes, pos)
        _, pos = read_u8(bytes, pos)  # skip active_byte
    end
    (vals, pos)
end

# =============================================================================
# V222+ format: Topology and values in separate sections
# =============================================================================

"""
    read_i2_topology_v222(bytes::Vector{UInt8}, pos::Int, origin::Coord) -> Tuple{I2TopoData, Int}

Read Internal2 topology for v222+ format (masks only, no values).
Also reads selection masks for all leaves.
"""
function read_i2_topology_v222(bytes::Vector{UInt8}, pos::Int, origin::Coord)::Tuple{I2TopoData, Int}
    # Read Internal2 masks
    i2_child_mask, pos = read_mask(Internal2Mask, bytes, pos)
    i2_value_mask, pos = read_mask(Internal2Mask, bytes, pos)

    # Read Internal1 children
    i1_children = Vector{I1TopoData}()

    for child_idx in on_indices(i2_child_mask)
        i1_origin = child_origin_internal2(origin, child_idx)

        # Read Internal1 masks
        i1_child_mask, pos = read_mask(Internal1Mask, bytes, pos)
        i1_value_mask, pos = read_mask(Internal1Mask, bytes, pos)

        # Read leaf value masks
        leaves = Vector{LeafTopoWithSelection}()
        for leaf_idx in on_indices(i1_child_mask)
            leaf_origin = child_origin_internal1(i1_origin, leaf_idx)
            leaf_mask, pos = read_mask(LeafMask, bytes, pos)
            # Selection mask will be read later
            push!(leaves, LeafTopoWithSelection(leaf_origin, leaf_mask, nothing))
        end

        push!(i1_children, I1TopoData(i1_origin, i1_child_mask, i1_value_mask, leaves))
    end

    (I2TopoData(origin, i2_child_mask, i2_value_mask, i1_children), pos)
end

"""
    read_selection_masks_v222!(i2_topo::I2TopoData, bytes::Vector{UInt8}, pos::Int) -> Int

Read selection masks for all leaves in an I2 subtree (v222+ format).
Mutates the I2TopoData in place to add selection masks.
"""
function read_selection_masks_v222!(i2_topo::I2TopoData, bytes::Vector{UInt8}, pos::Int)::Tuple{I2TopoData, Int}
    # Create new I1 children with selection masks filled in
    new_i1_children = Vector{I1TopoData}()

    for i1_topo in i2_topo.children
        new_leaves = Vector{LeafTopoWithSelection}()
        for leaf in i1_topo.leaves
            selection_mask, pos = read_mask(LeafMask, bytes, pos)
            push!(new_leaves, LeafTopoWithSelection(leaf.origin, leaf.value_mask, selection_mask))
        end
        push!(new_i1_children, I1TopoData(i1_topo.origin, i1_topo.child_mask, i1_topo.value_mask, new_leaves))
    end

    new_i2_topo = I2TopoData(i2_topo.origin, i2_topo.child_mask, i2_topo.value_mask, new_i1_children)
    (new_i2_topo, pos)
end

"""
    align_to_16(pos::Int) -> Int

Round up position to next 16-byte boundary.
"""
function align_to_16(pos::Int)::Int
    remainder = (pos - 1) % 16  # -1 because Julia is 1-indexed
    if remainder == 0
        pos
    else
        pos + (16 - remainder)
    end
end

"""
    read_leaf_values_v222_raw(::Type{T}, bytes::Vector{UInt8}, pos::Int, selection_mask::LeafMask, background::T) -> Tuple{NTuple{512,T}, Int}

Read leaf values from raw Float32 array (v222+ level set format).
Only voxels with bits set in selection_mask have stored values.
"""
function read_leaf_values_v222_raw(::Type{T}, bytes::Vector{UInt8}, pos::Int, selection_mask::LeafMask, background::T)::Tuple{NTuple{512,T}, Int} where T
    values = Vector{T}(undef, 512)

    for i in 0:511
        if is_on(selection_mask, i)
            values[i+1], pos = read_tile_value(T, bytes, pos)
        else
            values[i+1] = background
        end
    end

    (NTuple{512,T}(values), pos)
end

"""
    materialize_i2_values_v222(::Type{T}, i2_topo::I2TopoData, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, version::UInt32) -> Tuple{InternalNode2{T}, Int}

Materialize values for an I2 subtree from the values section (v222+ format).

V222+ level set format per-leaf:
1. Selection mask (64 bytes) - indicates which voxels have stored values
2. Raw Float32 values for selected voxels (no compression, no metadata)
3. Non-selected voxels use background value
"""
function materialize_i2_values_v222(::Type{T}, i2_topo::I2TopoData, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, version::UInt32)::Tuple{InternalNode2{T}, Int} where T
    # V222+ level set format: interleaved [64-byte selection mask][raw values] per leaf
    i1_nodes = Vector{InternalNode1{T}}()

    for i1_topo in i2_topo.children
        leaf_nodes = Vector{LeafNode{T}}()

        for leaf_topo in i1_topo.leaves
            # Read 64-byte selection mask inline
            selection_mask, pos = read_mask(LeafMask, bytes, pos)
            # Read raw values for selected voxels
            values, pos = read_leaf_values_v222_raw(T, bytes, pos, selection_mask, background)
            push!(leaf_nodes, LeafNode{T}(leaf_topo.origin, leaf_topo.value_mask, values))
        end

        # Construct I1 node - tiles use background value for level sets
        i1_child_count = count_on(i1_topo.child_mask)
        i1_tile_count = count_on(i1_topo.value_mask)
        i1_table = Vector{Union{LeafNode{T}, Tile{T}}}(undef, i1_child_count + i1_tile_count)

        for (i, leaf) in enumerate(leaf_nodes)
            i1_table[i] = leaf
        end
        for i in 1:i1_tile_count
            # I1 tiles default to background for level sets
            i1_table[i1_child_count + i] = Tile{T}(background, true)
        end

        push!(i1_nodes, InternalNode1{T}(i1_topo.origin, i1_topo.child_mask, i1_topo.value_mask, i1_table))
    end

    # Construct I2 node
    i2_child_count = count_on(i2_topo.child_mask)
    i2_tile_count = count_on(i2_topo.value_mask)
    i2_table = Vector{Union{InternalNode1{T}, Tile{T}}}(undef, i2_child_count + i2_tile_count)

    for (i, child) in enumerate(i1_nodes)
        i2_table[i] = child
    end
    for i in 1:i2_tile_count
        # I2 tiles default to background for level sets
        i2_table[i2_child_count + i] = Tile{T}(background, true)
    end

    node = InternalNode2{T}(i2_topo.origin, i2_topo.child_mask, i2_topo.value_mask, i2_table)
    (node, pos)
end

"""
    is_valid_i2_origin(x::Int32, y::Int32, z::Int32) -> Bool

Check if coordinates form a valid Internal2 node origin (4096-aligned, reasonable range).
"""
function is_valid_i2_origin(x::Int32, y::Int32, z::Int32)::Bool
    x % 4096 == 0 && y % 4096 == 0 && z % 4096 == 0 &&
    abs(x) <= 100000 && abs(y) <= 100000 && abs(z) <= 100000
end

"""
    read_tree_v222(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, grid_class::GridClass, version::UInt32, values_start::Int) -> Tuple{Tree{T}, Int}

Read a complete VDB tree for v222+ format where topology and values are separate.
"""
function read_tree_v222(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, grid_class::GridClass, version::UInt32, values_start::Int)::Tuple{Tree{T}, Int} where T
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

    # Read root tiles (origin + value + active for each)
    root_tile_origins = Coord[]
    for _ in 1:tile_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)
        push!(root_tile_origins, origin)

        value, pos = read_tile_value(T, bytes, pos)
        active_byte, pos = read_u8(bytes, pos)

        table[origin] = Tile{T}(value, active_byte != 0)
    end

    # Phase 1: Read ALL root children topology (masks + selection masks)
    i2_topos = Vector{I2TopoData}()
    i2_origins = Coord[]

    for i in 1:child_count
        # Stop if we've reached the values section
        if pos >= values_start
            break
        end

        # Read origin
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)

        # Check if this is a valid I2 origin (non-zero for actual children)
        # In v222+, some files declare more children than actually exist
        # The actual children have valid 4096-aligned origins
        if !is_valid_i2_origin(x, y, z)
            break
        end

        # Additional check: origin (0,0,0) is valid but may indicate padding
        # If all coordinates are zero and we're in later children, likely padding
        if x == 0 && y == 0 && z == 0 && i > 1
            # Peek ahead to see if this looks like real data or padding
            # Real I2 child_mask would have sparse set bits, padding is all zeros
            if pos + 4096 <= length(bytes)
                # Check if first 128 bytes of would-be mask are all zeros
                all_zeros = true
                for j in 0:127
                    if bytes[pos + j] != 0
                        all_zeros = false
                        break
                    end
                end
                if all_zeros
                    # Likely padding, not a real child - stop here
                    break
                end
            end
        end

        origin = coord(x, y, z)
        push!(i2_origins, origin)

        # Read I2 topology (masks only, no selection masks)
        i2_topo, pos = read_i2_topology_v222(bytes, pos, origin)

        push!(i2_topos, i2_topo)
    end

    # Phase 2: Seek to values section and read selection masks + values
    # Format is interleaved: [mask][values][mask][values] per leaf
    pos = values_start

    for (origin, i2_topo) in zip(i2_origins, i2_topos)
        # materialize_i2_values_v222 reads selection masks inline with values
        node, pos = materialize_i2_values_v222(T, i2_topo, bytes, pos, codec, background, version)
        table[origin] = node
    end

    tree = RootNode{T}(background, table)
    (tree, pos)
end

# =============================================================================
# Pre-v222 format: Interleaved topology and values
# =============================================================================

"""
    read_internal2_subtree_interleaved(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, origin::Coord, background::T, version::UInt32) -> Tuple{InternalNode2{T}, Int}

Read a complete Internal2 subtree with interleaved topology and values (pre-v222 format).
"""
function read_internal2_subtree_interleaved(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, origin::Coord, background::T, version::UInt32)::Tuple{InternalNode2{T}, Int} where T
    # ========== Phase 1: All Topology (masks only) ==========

    # Read Internal2 Masks
    i2_child_mask, pos = read_mask(Internal2Mask, bytes, pos)
    i2_value_mask, pos = read_mask(Internal2Mask, bytes, pos)

    # Collect Internal1 topology
    internal1_topo = Vector{Tuple{Coord, Internal1Mask, Internal1Mask, Vector{Tuple{Coord, LeafMask}}}}()

    for child_idx in on_indices(i2_child_mask)
        i1_origin = child_origin_internal2(origin, child_idx)

        i1_child_mask, pos = read_mask(Internal1Mask, bytes, pos)
        i1_value_mask, pos = read_mask(Internal1Mask, bytes, pos)

        leaves = Vector{Tuple{Coord, LeafMask}}()
        for leaf_idx in on_indices(i1_child_mask)
            leaf_origin = child_origin_internal1(i1_origin, leaf_idx)
            leaf_mask, pos = read_mask(LeafMask, bytes, pos)
            push!(leaves, (leaf_origin, leaf_mask))
        end

        push!(internal1_topo, (i1_origin, i1_child_mask, i1_value_mask, leaves))
    end

    # ========== Phase 2: All Values ==========

    # Read Internal2 Tile Values
    i2_active_vals, pos = read_internal_tiles(T, bytes, pos, i2_value_mask)

    # Read Internal1 Tile Values and Leaf Values
    i1_children = Vector{InternalNode1{T}}()

    for (i1_origin, i1_child_mask, i1_value_mask, leaf_topos) in internal1_topo
        i1_active_vals, pos = read_internal_tiles(T, bytes, pos, i1_value_mask)

        leaves = Vector{LeafNode{T}}()
        for (leaf_origin, leaf_mask) in leaf_topos
            values, pos = read_leaf_values(T, bytes, pos, codec, leaf_mask, background, version)
            push!(leaves, LeafNode{T}(leaf_origin, leaf_mask, values))
        end

        i1_child_count = count_on(i1_child_mask)
        i1_tile_count = count_on(i1_value_mask)
        i1_table = Vector{Union{LeafNode{T}, Tile{T}}}(undef, i1_child_count + i1_tile_count)

        for (i, leaf) in enumerate(leaves)
            i1_table[i] = leaf
        end
        for (i, val) in enumerate(i1_active_vals)
            i1_table[i1_child_count + i] = Tile{T}(val, true)
        end

        push!(i1_children, InternalNode1{T}(i1_origin, i1_child_mask, i1_value_mask, i1_table))
    end

    # Construct Internal2 Node
    i2_child_count = count_on(i2_child_mask)
    i2_tile_count = count_on(i2_value_mask)
    i2_table = Vector{Union{InternalNode1{T}, Tile{T}}}(undef, i2_child_count + i2_tile_count)

    for (i, child) in enumerate(i1_children)
        i2_table[i] = child
    end
    for (i, val) in enumerate(i2_active_vals)
        i2_table[i2_child_count + i] = Tile{T}(val, true)
    end

    node = InternalNode2{T}(origin, i2_child_mask, i2_value_mask, i2_table)
    (node, pos)
end

"""
    read_tree_interleaved(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, grid_class::GridClass, version::UInt32) -> Tuple{Tree{T}, Int}

Read a complete VDB tree with interleaved topology and values (pre-v222 format).
"""
function read_tree_interleaved(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, grid_class::GridClass, version::UInt32)::Tuple{Tree{T}, Int} where T
    # Read counts (no background_active for pre-v222)
    tile_count, pos = read_u32_le(bytes, pos)
    child_count, pos = read_u32_le(bytes, pos)

    table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()

    # Read tiles
    for _ in 1:tile_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        value, pos = read_tile_value(T, bytes, pos)
        active_byte, pos = read_u8(bytes, pos)

        table[origin] = Tile{T}(value, active_byte != 0)
    end

    # Read children (interleaved)
    for _ in 1:child_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        child, pos = read_internal2_subtree_interleaved(T, bytes, pos, codec, origin, background, version)
        table[origin] = child
    end

    tree = RootNode{T}(background, table)
    (tree, pos)
end

# =============================================================================
# Main entry point
# =============================================================================

"""
    read_tree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, grid_class::GridClass, version::UInt32, values_start::Int) -> Tuple{Tree{T}, Int}

Read a complete VDB tree structure.
Dispatches to v222+ or pre-v222 format based on version.
"""
function read_tree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, grid_class::GridClass, version::UInt32, values_start::Int)::Tuple{Tree{T}, Int} where T
    if version >= 222
        read_tree_v222(T, bytes, pos, codec, background, grid_class, version, values_start)
    else
        read_tree_interleaved(T, bytes, pos, codec, background, grid_class, version)
    end
end
