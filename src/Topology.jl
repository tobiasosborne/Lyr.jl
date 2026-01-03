# Topology.jl - Parse tree structure without values
#
# IMPORTANT: In the VDB binary format, only root entries store explicit origins.
# Internal2, Internal1, and Leaf nodes do NOT store their origins in the file.
# Origins for child nodes are computed from the parent origin + child index.
#
# Reference: https://jangafx.com/insights/vdb-a-deep-dive

"""
    LeafTopology

Topology of a leaf node (structure without values).
Origin is computed from parent, not stored in file.
"""
struct LeafTopology
    origin::Coord
    value_mask::LeafMask
end

"""
    Internal1Topology

Topology of an Internal1 node.
Origin is computed from parent, not stored in file.
"""
struct Internal1Topology
    origin::Coord
    child_mask::Internal1Mask
    value_mask::Internal1Mask
    children::Vector{Union{LeafTopology, Nothing}}
end

"""
    Internal2Topology

Topology of an Internal2 node.
Origin comes from root entry, not stored redundantly in Internal2 data.
"""
struct Internal2Topology
    origin::Coord
    child_mask::Internal2Mask
    value_mask::Internal2Mask
    children::Vector{Union{Internal1Topology, Nothing}}
end

"""
    RootTopology

Topology of the root node.
"""
struct RootTopology
    background_active::Bool
    tile_count::UInt32
    child_count::UInt32
    entries::Vector{Tuple{Coord, Bool, Union{Internal2Topology, Nothing}}}
end

# =============================================================================
# Child origin computation helpers
# =============================================================================

"""
    child_origin_internal2(parent_origin::Coord, child_index::Int) -> Coord

Compute the origin of an Internal1 child within an Internal2 node.
Internal2 is 32³ grid, each Internal1 covers 128³ voxels.
"""
function child_origin_internal2(parent_origin::Coord, child_index::Int)::Coord
    # Internal1 child size: 16 × 8 = 128 voxels per dimension
    child_size = Int32(128)

    # Convert linear index to 3D offset within 32³ grid
    ix = Int32(child_index % 32)
    iy = Int32((child_index ÷ 32) % 32)
    iz = Int32(child_index ÷ 1024)

    (parent_origin[1] + ix * child_size,
     parent_origin[2] + iy * child_size,
     parent_origin[3] + iz * child_size)
end

"""
    child_origin_internal1(parent_origin::Coord, child_index::Int) -> Coord

Compute the origin of a Leaf child within an Internal1 node.
Internal1 is 16³ grid, each Leaf covers 8³ voxels.
"""
function child_origin_internal1(parent_origin::Coord, child_index::Int)::Coord
    # Leaf child size: 8 voxels per dimension
    child_size = Int32(8)

    # Convert linear index to 3D offset within 16³ grid
    ix = Int32(child_index % 16)
    iy = Int32((child_index ÷ 16) % 16)
    iz = Int32(child_index ÷ 256)

    (parent_origin[1] + ix * child_size,
     parent_origin[2] + iy * child_size,
     parent_origin[3] + iz * child_size)
end

# =============================================================================
# Topology parsing functions
# =============================================================================

"""
    read_leaf_topology(bytes::Vector{UInt8}, pos::Int, origin::Coord) -> Tuple{LeafTopology, Int}

Parse leaf topology from bytes. Origin is passed in (computed from parent).
Leaf nodes do NOT store origin in the file - only the value mask.
"""
function read_leaf_topology(bytes::Vector{UInt8}, pos::Int, origin::Coord)::Tuple{LeafTopology, Int}
    # Read value mask (512 bits = 64 bytes)
    value_mask, pos = read_mask(LeafMask, bytes, pos)

    (LeafTopology(origin, value_mask), pos)
end

"""
    read_internal1_topology(bytes::Vector{UInt8}, pos::Int, origin::Coord) -> Tuple{Internal1Topology, Int}

Parse Internal1 topology from bytes. Origin is passed in (computed from parent).
Internal1 nodes do NOT store origin in the file.
"""
function read_internal1_topology(bytes::Vector{UInt8}, pos::Int, origin::Coord)::Tuple{Internal1Topology, Int}
    # Read child mask (4096 bits = 512 bytes)
    child_mask, pos = read_mask(Internal1Mask, bytes, pos)

    # Read value mask (4096 bits = 512 bytes)
    value_mask, pos = read_mask(Internal1Mask, bytes, pos)

    # Read children - origins computed from this node's origin + child index
    child_count = count_on(child_mask)
    children = Vector{Union{LeafTopology, Nothing}}(undef, child_count)

    for (i, child_idx) in enumerate(on_indices(child_mask))
        child_origin = child_origin_internal1(origin, child_idx)
        children[i], pos = read_leaf_topology(bytes, pos, child_origin)
    end

    (Internal1Topology(origin, child_mask, value_mask, children), pos)
end

"""
    read_internal2_topology(bytes::Vector{UInt8}, pos::Int, origin::Coord) -> Tuple{Internal2Topology, Int}

Parse Internal2 topology from bytes. Origin is passed in from root entry.
Internal2 nodes do NOT store origin in the file - it comes from the root.
"""
function read_internal2_topology(bytes::Vector{UInt8}, pos::Int, origin::Coord)::Tuple{Internal2Topology, Int}
    # Read child mask (32768 bits = 4096 bytes)
    child_mask, pos = read_mask(Internal2Mask, bytes, pos)

    # Read value mask (32768 bits = 4096 bytes)
    value_mask, pos = read_mask(Internal2Mask, bytes, pos)

    # Read children - origins computed from this node's origin + child index
    child_count = count_on(child_mask)
    children = Vector{Union{Internal1Topology, Nothing}}(undef, child_count)

    for (i, child_idx) in enumerate(on_indices(child_mask))
        child_origin = child_origin_internal2(origin, child_idx)
        children[i], pos = read_internal1_topology(bytes, pos, child_origin)
    end

    (Internal2Topology(origin, child_mask, value_mask, children), pos)
end

"""
    read_root_topology(bytes::Vector{UInt8}, pos::Int, grid_class::GridClass) -> Tuple{RootTopology, Int}

Parse root topology from bytes. Root entries contain explicit origins.

Note: The background_active byte is only present for fog volumes, not level sets.
Level sets use the background value semantically (outside = positive distance),
while fog volumes need an explicit flag to mark background as active/inactive.
"""
function read_root_topology(bytes::Vector{UInt8}, pos::Int, grid_class::GridClass)::Tuple{RootTopology, Int}
    # Read background active flag (only for fog volumes, not level sets)
    # Level sets don't have this byte - the background is always semantically "outside"
    background_active = false
    if grid_class == GRID_FOG_VOLUME || grid_class == GRID_UNKNOWN
        background_active_byte, pos = read_u8(bytes, pos)
        background_active = background_active_byte != 0
    end

    # Read tile count
    tile_count, pos = read_u32_le(bytes, pos)

    # Read child count
    child_count, pos = read_u32_le(bytes, pos)

    # Read entries (tiles and children)
    total_entries = tile_count + child_count
    entries = Vector{Tuple{Coord, Bool, Union{Internal2Topology, Nothing}}}(undef, total_entries)

    entry_idx = 1

    # Read tiles first (origin stored in file, no child data)
    for _ in 1:tile_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        active_byte, pos = read_u8(bytes, pos)
        active = active_byte != 0

        entries[entry_idx] = (origin, active, nothing)
        entry_idx += 1
    end

    # Read children (origin from root entry, then Internal2 data without redundant origin)
    for _ in 1:child_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        # Pass origin to Internal2 parser - it doesn't read origin from bytes
        child, pos = read_internal2_topology(bytes, pos, origin)
        entries[entry_idx] = (origin, false, child)
        entry_idx += 1
    end

    (RootTopology(background_active, tile_count, child_count, entries), pos)
end
