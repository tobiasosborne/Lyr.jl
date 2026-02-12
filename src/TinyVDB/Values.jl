# Values.jl - Value reading for TinyVDB
#
# After topology is parsed, values are read in a separate pass (ReadBuffer).
# This follows the VDB format's two-pass approach:
# 1. Topology pass: read tree structure (masks, child pointers)
# 2. Buffer pass: read actual voxel values
#
# For v222+, leaf nodes store (in the buffer pass):
# - value_mask: 64 bytes (skip over, already read in topology)
# - per_node_flag: 1 byte (determines inactive value encoding)
# - [optional] inactiveVal0: Float32
# - [optional] inactiveVal1: Float32
# - [optional] selection_mask: NodeMask (64 bytes for leaf)
# - compressed values (active-only if mask_compressed, else all 512)
#
# Per-node mask compression flag constants are defined in Topology.jl
# (NO_MASK_OR_INACTIVE_VALS through NO_MASK_AND_ALL_VALS)
#
# Algorithm follows ReadMaskValues from reference/tinyvdbio.h lines 2017-2127,
# NOT the incomplete ReadBuffer at line 2352.

# =============================================================================
# Leaf Value Reading
# =============================================================================

"""
    read_leaf_values(bytes::Vector{UInt8}, pos::Int, leaf::LeafNodeData,
                    file_version::UInt32, compression_flags::UInt32,
                    background::Float32) -> Tuple{LeafNodeData, Int}

Read values for a leaf node from bytes.

Follows the ReadMaskValues algorithm from tinyvdbio.h (lines 2017-2127).

Format (v222+, after topology has already read value_mask):
1. value_mask (64 bytes) — skipped, already read in topology
2. per_node_flag (1 byte) — selects inactive value encoding (0-6)
3. [conditional] inactiveVal0 (4 bytes Float32) — if flag ∈ {2,4,5}
4. [conditional] inactiveVal1 (4 bytes Float32) — if flag == 5
5. [conditional] selection_mask (64 bytes) — if flag ∈ {3,4,5}
6. compressed values — read_count Float32 values

If mask_compressed and flag != 6, only active values are stored.
Full 512-value buffer is reconstructed using inactive values + selection mask.

Returns (updated LeafNodeData with full 512 values, new_pos).
"""
function read_leaf_values(bytes::Vector{UInt8}, pos::Int, leaf::LeafNodeData,
                         file_version::UInt32, compression_flags::UInt32,
                         background::Float32; value_size::Int=4)::Tuple{LeafNodeData, Int}
    num_voxels = 512  # 8x8x8

    # Step 1: Skip over value_mask (64 bytes for log2dim=3, already read in topology)
    pos += 64

    mask_compressed = (compression_flags & COMPRESS_ACTIVE_MASK) != 0

    # Step 2: Read per_node_flag (v222+)
    per_node_flag = NO_MASK_AND_ALL_VALS
    if file_version >= FILE_VERSION_NODE_MASK_COMPRESSION
        per_node_flag, pos = read_u8(bytes, pos)
    end

    # Step 3: Initialize inactive values from flag and background
    inactiveVal1 = background
    if per_node_flag == NO_MASK_OR_INACTIVE_VALS
        inactiveVal0 = background
    else
        inactiveVal0 = -background
    end

    # Step 4: Conditionally read inactiveVal0 (and maybe inactiveVal1)
    if per_node_flag == NO_MASK_AND_ONE_INACTIVE_VAL ||
       per_node_flag == MASK_AND_ONE_INACTIVE_VAL ||
       per_node_flag == MASK_AND_TWO_INACTIVE_VALS
        if value_size == 2
            raw, pos = read_u8(bytes, pos)
            raw2, pos = read_u8(bytes, pos)
            inactiveVal0 = Float32(reinterpret(Float16, UInt16(raw) | UInt16(raw2) << 8))
        else
            inactiveVal0, pos = read_f32(bytes, pos)
        end

        if per_node_flag == MASK_AND_TWO_INACTIVE_VALS
            if value_size == 2
                raw, pos = read_u8(bytes, pos)
                raw2, pos = read_u8(bytes, pos)
                inactiveVal1 = Float32(reinterpret(Float16, UInt16(raw) | UInt16(raw2) << 8))
            else
                inactiveVal1, pos = read_f32(bytes, pos)
            end
        end
    end

    # Step 5: Conditionally read selection_mask
    selection_mask = NodeMask(LOG2DIM_LEAF)  # all zeros
    if per_node_flag == MASK_AND_NO_INACTIVE_VALS ||
       per_node_flag == MASK_AND_ONE_INACTIVE_VAL ||
       per_node_flag == MASK_AND_TWO_INACTIVE_VALS
        selection_mask, pos = read_mask(bytes, pos, LOG2DIM_LEAF)
    end

    # Step 6: Determine how many values to actually read
    read_count = num_voxels
    if mask_compressed && per_node_flag != NO_MASK_AND_ALL_VALS &&
       file_version >= FILE_VERSION_NODE_MASK_COMPRESSION
        read_count = count_on(leaf.value_mask)
    end

    # Step 7: Read compressed/decompressed values into temp buffer
    temp_values, pos = read_float_values(bytes, pos, read_count, compression_flags, value_size)

    # Step 8: Reconstruct full 512-value buffer
    if mask_compressed && read_count != num_voxels
        # Active-only data: expand to full buffer using masks
        values = Vector{Float32}(undef, num_voxels)
        temp_idx = 1
        for i in 0:(num_voxels - 1)
            if is_on(leaf.value_mask, i)
                values[i + 1] = temp_values[temp_idx]
                temp_idx += 1
            else
                values[i + 1] = is_on(selection_mask, i) ? inactiveVal1 : inactiveVal0
            end
        end
        leaf.values = values
    else
        # All 512 values present (no mask compression, or flag == 6)
        leaf.values = temp_values
    end

    return (leaf, pos)
end

# =============================================================================
# Internal Node Value Reading
# =============================================================================

"""
    read_internal_values(bytes::Vector{UInt8}, pos::Int, internal::InternalNodeData,
                        file_version::UInt32, compression_flags::UInt32,
                        background::Float32) -> Tuple{InternalNodeData, Int}

Read values for an internal node's children from bytes (depth-first).

Internal node tile values are already read/skipped during topology (skip_mask_values).
This function recursively reads values for all child nodes.
"""
function read_internal_values(bytes::Vector{UInt8}, pos::Int, internal::InternalNodeData,
                             file_version::UInt32, compression_flags::UInt32,
                             background::Float32; value_size::Int=4)::Tuple{InternalNodeData, Int}
    is_leaf_child = (internal.log2dim - 1) == LOG2DIM_LEAF

    for i in 1:length(internal.children)
        child_pos, child = internal.children[i]

        if is_leaf_child
            updated_child, pos = read_leaf_values(bytes, pos, child::LeafNodeData,
                                                  file_version, compression_flags, background;
                                                  value_size=value_size)
            internal.children[i] = (child_pos, updated_child)
        else
            updated_child, pos = read_internal_values(bytes, pos, child::InternalNodeData,
                                                      file_version, compression_flags, background;
                                                      value_size=value_size)
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

Performs a depth-first traversal, reading values for all leaf nodes.
Uses root.background for inactive value reconstruction.
"""
function read_tree_values(bytes::Vector{UInt8}, pos::Int, root::RootNodeData,
                         file_version::UInt32, compression_flags::UInt32;
                         value_size::Int=4)::Tuple{RootNodeData, Int}
    background = root.background

    for i in 1:length(root.children)
        coord, child = root.children[i]
        updated_child, pos = read_internal_values(bytes, pos, child,
                                                  file_version, compression_flags, background;
                                                  value_size=value_size)
        root.children[i] = (coord, updated_child)
    end

    return (root, pos)
end
