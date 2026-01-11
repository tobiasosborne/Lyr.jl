# Topology.jl - Tree topology parsing for TinyVDB
#
# VDB trees have the following structure:
# - RootNode: sparse hash map of children and tiles
# - InternalNode2 (I2): 32x32x32 = 32768 children (log2dim=5)
# - InternalNode1 (I1): 16x16x16 = 4096 children (log2dim=4)
# - LeafNode: 8x8x8 = 512 voxels (log2dim=3)
#
# This module reads the topology (structure) of the tree.
# Values are read in a separate pass (ReadBuffer).

# =============================================================================
# Constants
# =============================================================================

"""Log2dim for InternalNode2 (32x32x32)."""
const LOG2DIM_I2 = Int32(5)

"""Log2dim for InternalNode1 (16x16x16)."""
const LOG2DIM_I1 = Int32(4)

"""Log2dim for LeafNode (8x8x8)."""
const LOG2DIM_LEAF = Int32(3)

# =============================================================================
# Data Structures
# =============================================================================

"""
    LeafNodeData

Topology data for a leaf node.

# Fields
- `value_mask::NodeMask`: Bitmask indicating which voxels are active
- `values::Vector{Float32}`: Voxel values (populated during value reading)
"""
mutable struct LeafNodeData
    value_mask::NodeMask
    values::Vector{Float32}
end

"""
    InternalNodeData

Topology data for an internal node (I1 or I2).

# Fields
- `log2dim::Int32`: Log2 of dimension (4 for I1, 5 for I2)
- `child_mask::NodeMask`: Bitmask indicating which children are node pointers
- `value_mask::NodeMask`: Bitmask indicating which children are active tiles
- `values::Vector{Float32}`: Tile values for non-child positions
- `children::Vector{Tuple{Int32, Any}}`: Child nodes (position, node data)
"""
mutable struct InternalNodeData
    log2dim::Int32
    child_mask::NodeMask
    value_mask::NodeMask
    values::Vector{Float32}
    children::Vector{Tuple{Int32, Any}}  # Any can be InternalNodeData or LeafNodeData
end

"""
    RootNodeData

Topology data for the root node.

# Fields
- `background::Float32`: Background (default) value
- `num_tiles::Int32`: Number of tile entries
- `num_children::Int32`: Number of child node entries
- `tiles::Vector{Tuple{Coord, Float32, Bool}}`: (origin, value, active) tuples
- `children::Vector{Tuple{Coord, InternalNodeData}}`: (origin, child) tuples
"""
mutable struct RootNodeData
    background::Float32
    num_tiles::Int32
    num_children::Int32
    tiles::Vector{Tuple{Coord, Float32, Bool}}
    children::Vector{Tuple{Coord, InternalNodeData}}
end

# =============================================================================
# Leaf Node Topology
# =============================================================================

"""
    read_leaf_topology(bytes::Vector{UInt8}, pos::Int) -> Tuple{LeafNodeData, Int}

Read leaf node topology from bytes.

Format:
- value_mask: NodeMask (512 bits = 64 bytes for log2dim=3)

Returns (LeafNodeData, new_pos).
"""
function read_leaf_topology(bytes::Vector{UInt8}, pos::Int)::Tuple{LeafNodeData, Int}
    value_mask, pos = read_mask(bytes, pos, LOG2DIM_LEAF)
    leaf = LeafNodeData(value_mask, Float32[])
    return (leaf, pos)
end

# =============================================================================
# Internal Node Topology
# =============================================================================

"""
    read_internal_topology(bytes::Vector{UInt8}, pos::Int, log2dim::Int32,
                          file_version::UInt32, compression_flags::UInt32,
                          background::Float32) -> Tuple{InternalNodeData, Int}

Read internal node topology from bytes.

Format:
- child_mask: NodeMask
- value_mask: NodeMask
- (v222+) Per-node metadata for value compression
- For each position where child_mask is ON: recursively read child topology

# Arguments
- `bytes`: Source byte array
- `pos`: Starting position (1-indexed)
- `log2dim`: Log2 of dimension (5 for I2, 4 for I1)
- `file_version`: VDB file version
- `compression_flags`: Compression flags
- `background`: Background value for filling inactive tiles

Returns (InternalNodeData, new_pos).
"""
function read_internal_topology(bytes::Vector{UInt8}, pos::Int, log2dim::Int32,
                                file_version::UInt32, compression_flags::UInt32,
                                background::Float32)::Tuple{InternalNodeData, Int}
    # Read masks
    child_mask, pos = read_mask(bytes, pos, log2dim)
    value_mask, pos = read_mask(bytes, pos, log2dim)

    num_values = 1 << (3 * log2dim)  # Total slots in this node

    # For v222+, values for non-child positions are read in ReadMaskValues
    # during topology reading. For simplicity in TinyVDB, we defer all value
    # reading to the buffer reading pass.
    values = Float32[]

    # Determine child type: I2 -> I1, I1 -> Leaf
    child_log2dim = log2dim - 1
    is_leaf_child = (child_log2dim == LOG2DIM_LEAF)

    # Read child nodes recursively
    children = Vector{Tuple{Int32, Any}}()
    for i in 0:(num_values - 1)
        if is_on(child_mask, i)
            if is_leaf_child
                child, pos = read_leaf_topology(bytes, pos)
            else
                child, pos = read_internal_topology(bytes, pos, child_log2dim,
                                                   file_version, compression_flags, background)
            end
            push!(children, (Int32(i), child))
        end
    end

    internal = InternalNodeData(log2dim, child_mask, value_mask, values, children)
    return (internal, pos)
end

# =============================================================================
# Root Node Topology
# =============================================================================

"""
    read_root_topology(bytes::Vector{UInt8}, pos::Int;
                      file_version::UInt32=UInt32(222),
                      compression_flags::UInt32=COMPRESS_NONE) -> Tuple{RootNodeData, Int}

Read root node topology from bytes.

Format:
- background: f32
- num_tiles: i32
- num_children: i32
- For each tile: coord (3x i32), value (f32), active (bool)
- For each child: coord (3x i32), then child topology (I2)

Returns (RootNodeData, new_pos).
"""
function read_root_topology(bytes::Vector{UInt8}, pos::Int;
                           file_version::UInt32=UInt32(222),
                           compression_flags::UInt32=COMPRESS_NONE)::Tuple{RootNodeData, Int}
    # Read background value
    background, pos = read_f32(bytes, pos)

    # Read counts
    num_tiles, pos = read_i32(bytes, pos)
    num_children, pos = read_i32(bytes, pos)

    # Read tiles
    tiles = Vector{Tuple{Coord, Float32, Bool}}()
    for _ in 1:num_tiles
        x, pos = read_i32(bytes, pos)
        y, pos = read_i32(bytes, pos)
        z, pos = read_i32(bytes, pos)
        value, pos = read_f32(bytes, pos)
        active, pos = read_u8(bytes, pos)
        push!(tiles, (Coord(x, y, z), value, active != 0))
    end

    # Read children
    children = Vector{Tuple{Coord, InternalNodeData}}()
    for _ in 1:num_children
        x, pos = read_i32(bytes, pos)
        y, pos = read_i32(bytes, pos)
        z, pos = read_i32(bytes, pos)

        # Children of root are always I2 nodes (log2dim=5)
        child, pos = read_internal_topology(bytes, pos, LOG2DIM_I2,
                                           file_version, compression_flags, background)
        push!(children, (Coord(x, y, z), child))
    end

    root = RootNodeData(background, num_tiles, num_children, tiles, children)
    return (root, pos)
end
