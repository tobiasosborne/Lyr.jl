# Values.jl - Value reading for TinyVDB
#
# After topology is parsed, values are read in a separate pass (ReadBuffer).
# This follows the VDB format's two-pass approach:
# 1. Topology pass: read tree structure (masks, child pointers)
# 2. Buffer pass: read actual voxel values
#
# For v222+, leaf nodes store:
# - value_mask (already read in topology, skip over it here)
# - per_node_flag (1 byte)
# - values (compressed or uncompressed)

# =============================================================================
# Constants - Per-node mask compression flags
# =============================================================================

"""No mask and no inactive values stored."""
const NO_MASK_OR_INACTIVE_VALS = UInt8(0)

"""No mask, one inactive value stored."""
const NO_MASK_AND_ONE_INACTIVE_VAL = UInt8(1)

"""Mask, no inactive values stored."""
const MASK_AND_NO_INACTIVE_VALS = UInt8(2)

"""Mask and one inactive value stored."""
const MASK_AND_ONE_INACTIVE_VAL = UInt8(3)

"""Mask and two inactive values stored."""
const MASK_AND_TWO_INACTIVE_VALS = UInt8(4)

"""Mask selects between two non-background inactive values."""
const MASK_AND_TWO_INACTIVE_VALS2 = UInt8(5)

"""No mask compression at all - all values stored."""
const NO_MASK_AND_ALL_VALS = UInt8(6)

# =============================================================================
# Leaf Value Reading
# =============================================================================

"""
    read_leaf_values(bytes::Vector{UInt8}, pos::Int, leaf::LeafNodeData,
                    file_version::UInt32, compression_flags::UInt32) -> Tuple{LeafNodeData, Int}

Read values for a leaf node from bytes.

Format (v222+):
- value_mask: 64 bytes (skip over, already read in topology)
- per_node_flag: 1 byte
- values: 512 Float32 values (possibly compressed)

Returns (updated LeafNodeData with values, new_pos).
"""
function read_leaf_values(bytes::Vector{UInt8}, pos::Int, leaf::LeafNodeData,
                         file_version::UInt32, compression_flags::UInt32)::Tuple{LeafNodeData, Int}
    num_voxels = 512  # 8x8x8

    # Skip over value_mask (64 bytes for log2dim=3)
    mask_bytes = 64  # 512 bits / 8 = 64 bytes
    pos += mask_bytes

    # Read per_node_flag (v222+)
    per_node_flag = UInt8(0)
    if file_version >= FILE_VERSION_NODE_MASK_COMPRESSION
        per_node_flag, pos = read_u8(bytes, pos)
    end

    # Determine how many values to read
    mask_compressed = (compression_flags & COMPRESS_ACTIVE_MASK) != 0
    read_count = num_voxels

    if mask_compressed && per_node_flag != NO_MASK_AND_ALL_VALS &&
       file_version >= FILE_VERSION_NODE_MASK_COMPRESSION
        # Only read active values
        read_count = count_on(leaf.value_mask)
    end

    # Read values
    values, pos = read_f32_values(bytes, pos, read_count, compression_flags)

    # Update leaf with values
    leaf.values = values

    return (leaf, pos)
end

# =============================================================================
# Internal Node Value Reading
# =============================================================================

"""
    read_internal_values(bytes::Vector{UInt8}, pos::Int, internal::InternalNodeData,
                        file_version::UInt32, compression_flags::UInt32) -> Tuple{InternalNodeData, Int}

Read values for an internal node and its children from bytes.

Internal nodes in TinyVDB don't store tile values (we only support reading topology).
This function recursively reads values for all child nodes.
"""
function read_internal_values(bytes::Vector{UInt8}, pos::Int, internal::InternalNodeData,
                             file_version::UInt32, compression_flags::UInt32)::Tuple{InternalNodeData, Int}
    # Process children in order
    is_leaf_child = (internal.log2dim - 1) == LOG2DIM_LEAF

    for i in 1:length(internal.children)
        child_pos, child = internal.children[i]

        if is_leaf_child
            updated_child, pos = read_leaf_values(bytes, pos, child::LeafNodeData,
                                                  file_version, compression_flags)
            internal.children[i] = (child_pos, updated_child)
        else
            updated_child, pos = read_internal_values(bytes, pos, child::InternalNodeData,
                                                      file_version, compression_flags)
            internal.children[i] = (child_pos, updated_child)
        end
    end

    return (internal, pos)
end

# =============================================================================
# Root Value Reading
# =============================================================================

"""
    read_tree_values(bytes::Vector{UInt8}, pos::Int, root::RootNodeData,
                    file_version::UInt32, compression_flags::UInt32) -> Tuple{RootNodeData, Int}

Read values for the entire tree, starting from the root.

This performs a depth-first traversal, reading values for all leaf nodes.
"""
function read_tree_values(bytes::Vector{UInt8}, pos::Int, root::RootNodeData,
                         file_version::UInt32, compression_flags::UInt32)::Tuple{RootNodeData, Int}
    # Root children are always I2 nodes
    for i in 1:length(root.children)
        coord, child = root.children[i]
        updated_child, pos = read_internal_values(bytes, pos, child,
                                                  file_version, compression_flags)
        root.children[i] = (coord, updated_child)
    end

    return (root, pos)
end
