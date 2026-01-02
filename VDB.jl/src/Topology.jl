# Topology.jl - Parse tree structure without values

"""
    LeafTopology

Topology of a leaf node (structure without values).
"""
struct LeafTopology
    origin::Coord
    value_mask::LeafMask
end

"""
    Internal1Topology

Topology of an Internal1 node.
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

"""
    read_leaf_topology(bytes::Vector{UInt8}, pos::Int) -> Tuple{LeafTopology, Int}

Parse leaf topology from bytes.
"""
function read_leaf_topology(bytes::Vector{UInt8}, pos::Int)::Tuple{LeafTopology, Int}
    # Read origin
    x, pos = read_i32_le(bytes, pos)
    y, pos = read_i32_le(bytes, pos)
    z, pos = read_i32_le(bytes, pos)
    origin = coord(x, y, z)

    # Read value mask
    value_mask, pos = read_mask(LeafMask, bytes, pos)

    (LeafTopology(origin, value_mask), pos)
end

"""
    read_internal1_topology(bytes::Vector{UInt8}, pos::Int) -> Tuple{Internal1Topology, Int}

Parse Internal1 topology from bytes.
"""
function read_internal1_topology(bytes::Vector{UInt8}, pos::Int)::Tuple{Internal1Topology, Int}
    # Read origin
    x, pos = read_i32_le(bytes, pos)
    y, pos = read_i32_le(bytes, pos)
    z, pos = read_i32_le(bytes, pos)
    origin = coord(x, y, z)

    # Read child mask
    child_mask, pos = read_mask(Internal1Mask, bytes, pos)

    # Read value mask
    value_mask, pos = read_mask(Internal1Mask, bytes, pos)

    # Read children
    child_count = count_on(child_mask)
    children = Vector{Union{LeafTopology, Nothing}}(undef, child_count)

    for (i, _) in enumerate(on_indices(child_mask))
        children[i], pos = read_leaf_topology(bytes, pos)
    end

    (Internal1Topology(origin, child_mask, value_mask, children), pos)
end

"""
    read_internal2_topology(bytes::Vector{UInt8}, pos::Int) -> Tuple{Internal2Topology, Int}

Parse Internal2 topology from bytes.
"""
function read_internal2_topology(bytes::Vector{UInt8}, pos::Int)::Tuple{Internal2Topology, Int}
    # Read origin
    x, pos = read_i32_le(bytes, pos)
    y, pos = read_i32_le(bytes, pos)
    z, pos = read_i32_le(bytes, pos)
    origin = coord(x, y, z)

    # Read child mask
    child_mask, pos = read_mask(Internal2Mask, bytes, pos)

    # Read value mask
    value_mask, pos = read_mask(Internal2Mask, bytes, pos)

    # Read children
    child_count = count_on(child_mask)
    children = Vector{Union{Internal1Topology, Nothing}}(undef, child_count)

    for (i, _) in enumerate(on_indices(child_mask))
        children[i], pos = read_internal1_topology(bytes, pos)
    end

    (Internal2Topology(origin, child_mask, value_mask, children), pos)
end

"""
    read_root_topology(bytes::Vector{UInt8}, pos::Int) -> Tuple{RootTopology, Int}

Parse root topology from bytes.
"""
function read_root_topology(bytes::Vector{UInt8}, pos::Int)::Tuple{RootTopology, Int}
    # Read background active flag
    background_active_byte, pos = read_u8(bytes, pos)
    background_active = background_active_byte != 0

    # Read tile count
    tile_count, pos = read_u32_le(bytes, pos)

    # Read child count
    child_count, pos = read_u32_le(bytes, pos)

    # Read entries (tiles and children)
    total_entries = tile_count + child_count
    entries = Vector{Tuple{Coord, Bool, Union{Internal2Topology, Nothing}}}(undef, total_entries)

    entry_idx = 1

    # Read tiles first
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

    # Read children
    for _ in 1:child_count
        x, pos = read_i32_le(bytes, pos)
        y, pos = read_i32_le(bytes, pos)
        z, pos = read_i32_le(bytes, pos)
        origin = coord(x, y, z)

        child, pos = read_internal2_topology(bytes, pos)
        entries[entry_idx] = (origin, false, child)
        entry_idx += 1
    end

    (RootTopology(background_active, tile_count, child_count, entries), pos)
end
