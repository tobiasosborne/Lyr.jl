# TreeRead.jl - Combined topology + value parsing
#
# VDB file formats differ by version:
# - v222+: Topology and values are in separate sections (uses block_offset)
# - Pre-v222: Topology and values interleaved per-subtree
#
# This module handles both formats.

# =============================================================================
# Half-precision value conversion
# =============================================================================

"""
    _decode_values(::Type{T}, data, count, value_size) -> Vector{T}

Decode a byte buffer into `count` values of type T.
Handles half-precision (Float16 components) when `value_size < sizeof(T)`.
"""
function _decode_values(::Type{T}, data::Vector{UInt8}, count::Int, value_size::Int)::Vector{T} where T
    if value_size == sizeof(T)
        return collect(reinterpret(T, data))
    end
    # Half-precision: each scalar component stored as Float16
    halfs = reinterpret(Float16, data)
    if T === Float32
        return Float32.(halfs)
    elseif T === Float64
        return Float64.(halfs)
    elseif T <: NTuple
        n = length(T.parameters)
        ET = T.parameters[1]
        return [ntuple(j -> ET(halfs[(i-1)*n + j]), n) for i in 1:count]
    else
        error("unsupported half-precision type: $T")
    end
end

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
    I1TopoData{T}

Internal1 topology data collected during Phase 1.
`node_values` stores all 4096 values from ReadMaskValues (used for tile construction).
"""
struct I1TopoData{T}
    origin::Coord
    child_mask::Internal1Mask
    value_mask::Internal1Mask
    leaves::Vector{LeafTopoWithSelection}
    node_values::Vector{T}
end

"""
    I2TopoData{T}

Internal2 topology data collected during Phase 1.
`node_values` stores all 32768 values from ReadMaskValues (used for tile construction).
"""
struct I2TopoData{T}
    origin::Coord
    child_mask::Internal2Mask
    value_mask::Internal2Mask
    children::Vector{I1TopoData{T}}
    node_values::Vector{T}
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
    read_i2_topology_v222(::Type{T}, bytes, pos, origin, codec, mask_compressed, background, version) -> Tuple{I2TopoData, Int}

Read Internal2 topology for v222+ format.

In v222+, internal node values (ReadMaskValues format) are embedded in the topology
section after each node's masks. We must skip these to keep pos aligned.
"""
function read_i2_topology_v222(::Type{T}, bytes::Vector{UInt8}, pos::Int, origin::Coord, codec::Codec, mask_compressed::Bool, background::T, version::UInt32; value_size::Int=sizeof(T))::Tuple{I2TopoData{T}, Int} where T
    # Read Internal2 masks
    i2_child_mask, pos = read_mask(Internal2Mask, bytes, pos)
    i2_value_mask, pos = read_mask(Internal2Mask, bytes, pos)

    # Read I2 embedded values (ReadMaskValues format) — needed for tile construction
    i2_node_values, pos = read_dense_values(T, bytes, pos, codec, mask_compressed, i2_value_mask, background; value_size)

    # Read Internal1 children
    i1_children = Vector{I1TopoData{T}}()

    for child_idx in on_indices(i2_child_mask)
        i1_origin = child_origin_internal2(origin, child_idx)

        # Read Internal1 masks
        i1_child_mask, pos = read_mask(Internal1Mask, bytes, pos)
        i1_value_mask, pos = read_mask(Internal1Mask, bytes, pos)

        # Read I1 embedded values (ReadMaskValues format) — needed for tile construction
        i1_node_values, pos = read_dense_values(T, bytes, pos, codec, mask_compressed, i1_value_mask, background; value_size)

        # Read leaf value masks
        leaves = Vector{LeafTopoWithSelection}()
        for leaf_idx in on_indices(i1_child_mask)
            leaf_origin = child_origin_internal1(i1_origin, leaf_idx)
            leaf_mask, pos = read_mask(LeafMask, bytes, pos)
            push!(leaves, LeafTopoWithSelection(leaf_origin, leaf_mask, nothing))
        end

        push!(i1_children, I1TopoData{T}(i1_origin, i1_child_mask, i1_value_mask, leaves, i1_node_values))
    end

    (I2TopoData{T}(origin, i2_child_mask, i2_value_mask, i1_children, i2_node_values), pos)
end

"""
    materialize_i2_values_v222(::Type{T}, i2_topo::I2TopoData, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, background::T, version::UInt32) -> Tuple{InternalNode2{T}, Int}

Materialize values for an I2 subtree from the values section (v222+ format).

V222+ value format per-leaf:
1. Metadata byte (1 byte) - determines format variant
2. Optional inactive value(s) based on metadata
3. Optional selection mask (64 bytes) for metadata 3/4/5
4. Compressed values - count depends on mask_compressed flag:
   - If mask_compressed: only active values (value_mask.countOn())
   - Otherwise: all 512 values
"""
function materialize_i2_values_v222(::Type{T}, i2_topo::I2TopoData{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, background::T, version::UInt32; value_size::Int=sizeof(T))::Tuple{InternalNode2{T}, Int} where T
    # V222+ format: each leaf has [metadata][optional inactive vals][optional selection mask][compressed values]
    i1_nodes = Vector{InternalNode1{T}}()

    for i1_topo in i2_topo.children
        leaf_nodes = Vector{LeafNode{T}}()

        for leaf_topo in i1_topo.leaves
            values, pos = read_leaf_values(T, bytes, pos, codec, mask_compressed, leaf_topo.value_mask, background, version; value_size)
            push!(leaf_nodes, LeafNode{T}(leaf_topo.origin, leaf_topo.value_mask, values))
        end

        # Construct I1 node — extract tile values from stored node_values
        i1_tiles = Tile{T}[Tile{T}(i1_topo.node_values[bit_idx + 1], true) for bit_idx in on_indices(i1_topo.value_mask)]

        push!(i1_nodes, InternalNode1{T}(i1_topo.origin, i1_topo.child_mask, i1_topo.value_mask, leaf_nodes, i1_tiles))
    end

    # Construct I2 node — extract tile values from stored node_values
    i2_tiles = Tile{T}[Tile{T}(i2_topo.node_values[bit_idx + 1], true) for bit_idx in on_indices(i2_topo.value_mask)]

    node = InternalNode2{T}(i2_topo.origin, i2_topo.child_mask, i2_topo.value_mask, i1_nodes, i2_tiles)
    (node, pos)
end

"""
    read_tree_v222(::Type{T}, bytes, pos, codec, mask_compressed, background, grid_class, version) -> Tuple{Tree{T}, Int}

Read a complete VDB tree for v222+ format where topology and values are separate.
Sequential reading: topology pass skips internal node values, then values pass reads leaves.
"""
function read_tree_v222(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, background::T, grid_class::GridClass, version::UInt32; value_size::Int=sizeof(T))::Tuple{Tree{T}, Int} where T
    # Read counts
    tile_count, pos = read_u32_le(bytes, pos)
    child_count, pos = read_u32_le(bytes, pos)

    table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()

    # Read root tiles (origin + value + active for each — always full precision)
    for _ in 1:tile_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        value, pos = read_tile_value(T, bytes, pos)
        active_byte, pos = read_u8(bytes, pos)

        table[origin] = Tile{T}(value, active_byte != 0)
    end

    # Phase 1: Read ALL root children topology
    i2_topos = Vector{I2TopoData{T}}()
    i2_origins = Coord[]

    for _ in 1:child_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)
        push!(i2_origins, origin)

        i2_topo, pos = read_i2_topology_v222(T, bytes, pos, origin, codec, mask_compressed, background, version; value_size)
        push!(i2_topos, i2_topo)
    end

    # Phase 2: Read leaf values (pos flows sequentially from topology)
    for (origin, i2_topo) in zip(i2_origins, i2_topos)
        node, pos = materialize_i2_values_v222(T, i2_topo, bytes, pos, codec, mask_compressed, background, version; value_size)
        table[origin] = node
    end

    tree = RootNode{T}(background, table)
    (tree, pos)
end

# =============================================================================
# Pre-v222 format: Interleaved topology and values
# =============================================================================

"""
    I2TopoDataV220{T}

Internal2 topology data for pre-v222 format. Stores masks, tile values, and I1 children topology.
"""
struct I2TopoDataV220{T}
    origin::Coord
    child_mask::Internal2Mask
    value_mask::Internal2Mask
    active_vals::Vector{T}
    i1_children::Vector{Tuple{Coord, Internal1Mask, Internal1Mask, Vector{Tuple{Coord, LeafMask}}, Vector{T}}}
end

"""
    read_i2_topology_v220(::Type{T}, bytes, pos, codec, origin) -> Tuple{I2TopoDataV220{T}, Int}

Read Internal2 topology for pre-v222 format (readTopology pass).
Pre-v222 readTopology: masks, then readCompressedValues (non-child values only), then recurse.
See reference/InternalNode.h:2419 and reference/tinyvdbio.h:2221-2266.
"""
function read_i2_topology_v220(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, origin::Coord; value_size::Int=sizeof(T))::Tuple{I2TopoDataV220{T}, Int} where T
    # Read Internal2 Masks
    i2_child_mask, pos = read_mask(Internal2Mask, bytes, pos)
    i2_value_mask, pos = read_mask(Internal2Mask, bytes, pos)

    # Read I2 compressed values: non-child values only (no metadata byte for pre-v222)
    # tinyvdbio.h:2266 — old_version uses child_mask.countOff(), not NUM_VALUES
    i2_non_child_count = 32768 - count_on(i2_child_mask)
    i2_all_data, pos = read_compressed_bytes(bytes, pos, codec, i2_non_child_count * value_size)
    i2_all_values = _decode_values(T, i2_all_data, i2_non_child_count, value_size)

    # Extract active tile values: iterate non-child slots in order, match to value array
    i2_active_vals = T[]
    val_idx = 1
    for idx in 0:32767
        if !is_on(i2_child_mask, idx)
            if is_on(i2_value_mask, idx)
                push!(i2_active_vals, i2_all_values[val_idx])
            end
            val_idx += 1
        end
    end

    # Read I1 children topology
    i1_children = Vector{Tuple{Coord, Internal1Mask, Internal1Mask, Vector{Tuple{Coord, LeafMask}}, Vector{T}}}()

    for child_idx in on_indices(i2_child_mask)
        i1_origin = child_origin_internal2(origin, child_idx)

        i1_child_mask, pos = read_mask(Internal1Mask, bytes, pos)
        i1_value_mask, pos = read_mask(Internal1Mask, bytes, pos)

        # Read I1 compressed values: non-child values only
        i1_non_child_count = 4096 - count_on(i1_child_mask)
        i1_all_data, pos = read_compressed_bytes(bytes, pos, codec, i1_non_child_count * value_size)
        i1_all_values = _decode_values(T, i1_all_data, i1_non_child_count, value_size)

        i1_active_vals = T[]
        val_idx = 1
        for idx in 0:4095
            if !is_on(i1_child_mask, idx)
                if is_on(i1_value_mask, idx)
                    push!(i1_active_vals, i1_all_values[val_idx])
                end
                val_idx += 1
            end
        end

        leaves = Vector{Tuple{Coord, LeafMask}}()
        for leaf_idx in on_indices(i1_child_mask)
            leaf_origin = child_origin_internal1(i1_origin, leaf_idx)
            leaf_mask, pos = read_mask(LeafMask, bytes, pos)
            push!(leaves, (leaf_origin, leaf_mask))
        end

        push!(i1_children, (i1_origin, i1_child_mask, i1_value_mask, leaves, i1_active_vals))
    end

    topo = I2TopoDataV220{T}(origin, i2_child_mask, i2_value_mask, i2_active_vals, i1_children)
    (topo, pos)
end

"""
    materialize_i2_values_v220(::Type{T}, topo, bytes, pos, codec, background, version) -> Tuple{InternalNode2{T}, Int}

Read leaf buffers and construct an I2 subtree for pre-v222 format (readBuffers pass).
"""
function materialize_i2_values_v220(::Type{T}, topo::I2TopoDataV220{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, background::T, version::UInt32; value_size::Int=sizeof(T))::Tuple{InternalNode2{T}, Int} where T
    i1_nodes = Vector{InternalNode1{T}}()

    for (i1_origin, i1_child_mask, i1_value_mask, leaf_topos, i1_active_vals) in topo.i1_children
        leaf_nodes = Vector{LeafNode{T}}()
        for (leaf_origin, leaf_mask) in leaf_topos
            values, pos = read_leaf_values(T, bytes, pos, codec, false, leaf_mask, background, version; value_size)
            push!(leaf_nodes, LeafNode{T}(leaf_origin, leaf_mask, values))
        end

        i1_tiles = Tile{T}[Tile{T}(val, true) for val in i1_active_vals]

        push!(i1_nodes, InternalNode1{T}(i1_origin, i1_child_mask, i1_value_mask, leaf_nodes, i1_tiles))
    end

    # Construct Internal2 Node
    i2_tiles = Tile{T}[Tile{T}(val, true) for val in topo.active_vals]

    node = InternalNode2{T}(topo.origin, topo.child_mask, topo.value_mask, i1_nodes, i2_tiles)
    (node, pos)
end

"""
    read_tree_interleaved(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, background::T, grid_class::GridClass, version::UInt32) -> Tuple{Tree{T}, Int}

Read a complete VDB tree for pre-v222 format.
Two-phase: readTopology reads ALL topology (masks + internal values) for ALL root children,
then readBuffers reads ALL leaf values. See reference/RootNode.h:2384 and :2439.
"""
function read_tree_interleaved(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, background::T, grid_class::GridClass, version::UInt32; value_size::Int=sizeof(T))::Tuple{Tree{T}, Int} where T
    tile_count, pos = read_u32_le(bytes, pos)
    child_count, pos = read_u32_le(bytes, pos)

    table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()

    # Read root tiles
    for _ in 1:tile_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        value, pos = read_tile_value(T, bytes, pos)
        active_byte, pos = read_u8(bytes, pos)

        table[origin] = Tile{T}(value, active_byte != 0)
    end

    # Phase 1: Read ALL topology for ALL root children (readTopology)
    i2_topos = Vector{I2TopoDataV220{T}}()

    for _ in 1:child_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        topo, pos = read_i2_topology_v220(T, bytes, pos, codec, origin; value_size)
        push!(i2_topos, topo)
    end

    # Phase 2: Read ALL leaf buffers for ALL root children (readBuffers)
    for topo in i2_topos
        node, pos = materialize_i2_values_v220(T, topo, bytes, pos, codec, background, version; value_size)
        table[topo.origin] = node
    end

    tree = RootNode{T}(background, table)
    (tree, pos)
end

# =============================================================================
# Main entry point
# =============================================================================

"""
    read_tree(::Type{T}, bytes, pos, codec, mask_compressed, background, grid_class, version) -> Tuple{Tree{T}, Int}

Read a complete VDB tree structure.
Dispatches to v222+ or pre-v222 format based on version.
"""
function read_tree(::Type{T}, bytes::Vector{UInt8}, pos::Int, codec::Codec, mask_compressed::Bool, background::T, grid_class::GridClass, version::UInt32; value_size::Int=sizeof(T))::Tuple{Tree{T}, Int} where T
    if version >= 222
        read_tree_v222(T, bytes, pos, codec, mask_compressed, background, grid_class, version; value_size)
    else
        read_tree_interleaved(T, bytes, pos, codec, mask_compressed, background, grid_class, version; value_size)
    end
end
