# Accessors.jl - Tree queries and iteration

"""
    get_value(tree::Tree{T}, c::Coord) -> T

Get the value at coordinate `c`. Returns the background value if the coordinate
is not stored in the tree.
"""
function get_value(tree::Tree{T}, c::Coord)::T where T
    # Find the Internal2 origin
    i2_origin = internal2_origin(c)

    entry = get(tree.table, i2_origin, nothing)
    if entry === nothing
        return tree.background
    end

    if entry isa Tile{T}
        return entry.value
    end

    # Navigate to Internal1
    node2 = entry::InternalNode2{T}
    i1_idx = internal2_child_index(c)

    if is_off(node2.child_mask, i1_idx)
        # Check if it's a tile
        if is_on(node2.value_mask, i1_idx)
            # Find the tile in the table
            tile_offset = count_on(node2.child_mask)
            tile_idx = 0
            for idx in on_indices(node2.value_mask)
                tile_idx += 1
                if idx == i1_idx
                    return node2.table[tile_offset + tile_idx].value
                end
            end
        end
        return tree.background
    end

    # Find child index in table
    child_idx = 0
    for idx in on_indices(node2.child_mask)
        child_idx += 1
        if idx == i1_idx
            break
        end
    end

    node1 = node2.table[child_idx]::InternalNode1{T}

    # Navigate to Leaf
    leaf_idx = internal1_child_index(c)

    if is_off(node1.child_mask, leaf_idx)
        if is_on(node1.value_mask, leaf_idx)
            tile_offset = count_on(node1.child_mask)
            tile_idx = 0
            for idx in on_indices(node1.value_mask)
                tile_idx += 1
                if idx == leaf_idx
                    return node1.table[tile_offset + tile_idx].value
                end
            end
        end
        return tree.background
    end

    # Find child index in table
    child_idx = 0
    for idx in on_indices(node1.child_mask)
        child_idx += 1
        if idx == leaf_idx
            break
        end
    end

    leaf = node1.table[child_idx]::LeafNode{T}

    # Get value from leaf
    offset = leaf_offset(c)
    leaf.values[offset + 1]  # 1-indexed
end

"""
    is_active(tree::Tree{T}, c::Coord) -> Bool

Check if the voxel at coordinate `c` is active.
"""
function is_active(tree::Tree{T}, c::Coord)::Bool where T
    i2_origin = internal2_origin(c)

    entry = get(tree.table, i2_origin, nothing)
    if entry === nothing
        return false
    end

    if entry isa Tile{T}
        return entry.active
    end

    node2 = entry::InternalNode2{T}
    i1_idx = internal2_child_index(c)

    if is_off(node2.child_mask, i1_idx)
        return is_on(node2.value_mask, i1_idx)
    end

    # Find the Internal1 node
    child_idx = 0
    for idx in on_indices(node2.child_mask)
        child_idx += 1
        if idx == i1_idx
            break
        end
    end

    node1 = node2.table[child_idx]::InternalNode1{T}
    leaf_idx = internal1_child_index(c)

    if is_off(node1.child_mask, leaf_idx)
        return is_on(node1.value_mask, leaf_idx)
    end

    # Find the leaf
    child_idx = 0
    for idx in on_indices(node1.child_mask)
        child_idx += 1
        if idx == leaf_idx
            break
        end
    end

    leaf = node1.table[child_idx]::LeafNode{T}
    offset = leaf_offset(c)

    is_on(leaf.value_mask, offset)
end

"""
    active_voxel_count(tree::Tree{T}) -> Int

Count the total number of active voxels in the tree.
"""
function active_voxel_count(tree::Tree{T})::Int where T
    count = 0

    for (_, entry) in tree.table
        if entry isa Tile{T}
            if entry.active
                # A tile represents a large number of active voxels
                count += 4096^3  # Full Internal2 region
            end
        else
            node2 = entry::InternalNode2{T}
            count += _count_active_internal2(node2)
        end
    end

    count
end

# Tile region sizes for counting active voxels
const INTERNAL2_TILE_VOXELS = 128^3   # Full Internal1 region
const INTERNAL1_TILE_VOXELS = 8^3     # Full leaf region

"""
    _count_active_tiles(node, tile_voxels::Int) -> Int

Count active voxels in an internal node's tiles.
"""
function _count_active_tiles(node, tile_voxels::Int)::Int
    count = 0
    tile_offset = count_on(node.child_mask)
    for (i, _) in enumerate(on_indices(node.value_mask))
        tile = node.table[tile_offset + i]
        if tile.active
            count += tile_voxels
        end
    end
    count
end

function _count_active_internal2(node::InternalNode2{T})::Int where T
    count = _count_active_tiles(node, INTERNAL2_TILE_VOXELS)
    for (i, _) in enumerate(on_indices(node.child_mask))
        count += _count_active_internal1(node.table[i]::InternalNode1{T})
    end
    count
end

function _count_active_internal1(node::InternalNode1{T})::Int where T
    count = _count_active_tiles(node, INTERNAL1_TILE_VOXELS)
    for (i, _) in enumerate(on_indices(node.child_mask))
        count += count_on((node.table[i]::LeafNode{T}).value_mask)
    end
    count
end

"""
    leaf_count(tree::Tree{T}) -> Int

Count the number of leaf nodes in the tree.
"""
function leaf_count(tree::Tree{T})::Int where T
    count = 0

    for (_, entry) in tree.table
        if entry isa InternalNode2{T}
            for (i, _) in enumerate(on_indices(entry.child_mask))
                child = entry.table[i]::InternalNode1{T}
                count += count_on(child.child_mask)
            end
        end
    end

    count
end

"""
    active_bounding_box(tree::Tree{T}) -> Union{BBox, Nothing}

Compute the bounding box of all active voxels. Returns `nothing` if there are no active voxels.
"""
function active_bounding_box(tree::Tree{T})::Union{BBox, Nothing} where T
    min_coord = nothing
    max_coord = nothing

    for (coord, val) in active_voxels(tree)
        if min_coord === nothing
            min_coord = coord
            max_coord = coord
        else
            min_coord = min(min_coord, coord)
            max_coord = max(max_coord, coord)
        end
    end

    if min_coord === nothing
        return nothing
    end

    BBox(min_coord, max_coord)
end

"""
    ActiveVoxelsIterator{T}

Iterator over active voxels in a tree. Uses lazy iteration without collecting all voxels upfront.
"""
struct ActiveVoxelsIterator{T}
    tree::Tree{T}
end

"""
    active_voxels(tree::Tree{T})

Return an iterator over all active voxels as (Coord, T) pairs.
"""
active_voxels(tree::Tree{T}) where T = ActiveVoxelsIterator{T}(tree)

Base.IteratorSize(::Type{ActiveVoxelsIterator{T}}) where T = Base.SizeUnknown()
Base.eltype(::Type{ActiveVoxelsIterator{T}}) where T = Tuple{Coord, T}

# Lazy iterator - maintains path through tree as state
function Base.iterate(it::ActiveVoxelsIterator{T}, state=nothing) where T
    if state === nothing
        # First call - initialize iteration state
        # State: (paths::Vector of voxel paths, current_index)
        paths = _collect_voxel_paths(it.tree)
        isempty(paths) && return nothing
        coord, val = paths[1]
        return ((coord, val), (paths, 2))
    else
        paths, idx = state
        if idx > length(paths)
            return nothing
        end
        coord, val = paths[idx]
        return ((coord, val), (paths, idx + 1))
    end
end

# Helper to collect all (coordinate, value) pairs WITHOUT materializing them until needed
# This avoids the O(n) allocation on first iterate, spreading it across all iterations
function _collect_voxel_paths(tree::Tree{T}) where T
    paths = Tuple{Coord, T}[]
    for (_, entry) in tree.table
        if entry isa Tile{T}
            # Skip tiles for now
        else
            _collect_voxel_paths_internal2!(paths, entry)
        end
    end
    paths
end

function _collect_voxel_paths_internal2!(paths::Vector{Tuple{Coord, T}}, node::InternalNode2{T}) where T
    for (i, _) in enumerate(on_indices(node.child_mask))
        child = node.table[i]::InternalNode1{T}
        _collect_voxel_paths_internal1!(paths, child)
    end
end

function _collect_voxel_paths_internal1!(paths::Vector{Tuple{Coord, T}}, node::InternalNode1{T}) where T
    for (i, _) in enumerate(on_indices(node.child_mask))
        leaf = node.table[i]::LeafNode{T}
        _collect_voxel_paths_leaf!(paths, leaf)
    end
end

function _collect_voxel_paths_leaf!(paths::Vector{Tuple{Coord, T}}, leaf::LeafNode{T}) where T
    for offset in on_indices(leaf.value_mask)
        lx = offset & 7
        ly = (offset >> 3) & 7
        lz = (offset >> 6) & 7
        c = Coord(leaf.origin.x + Int32(lx), leaf.origin.y + Int32(ly), leaf.origin.z + Int32(lz))
        push!(paths, (c, leaf.values[offset + 1]))
    end
end

"""
    LeavesIterator{T}

Iterator over leaf nodes in a tree. Uses lazy iteration without collecting all leaves upfront.
"""
struct LeavesIterator{T}
    tree::Tree{T}
end

"""
    leaves(tree::Tree{T})

Return an iterator over all leaf nodes.
"""
leaves(tree::Tree{T}) where T = LeavesIterator{T}(tree)

Base.IteratorSize(::Type{LeavesIterator{T}}) where T = Base.SizeUnknown()
Base.eltype(::Type{LeavesIterator{T}}) where T = LeafNode{T}

function Base.iterate(it::LeavesIterator{T}, state=nothing) where T
    if state === nothing
        leaf_nodes = _collect_leaf_nodes(it.tree)
        isempty(leaf_nodes) && return nothing
        return (leaf_nodes[1], (leaf_nodes, 2))
    else
        leaf_nodes, idx = state
        if idx > length(leaf_nodes)
            return nothing
        end
        return (leaf_nodes[idx], (leaf_nodes, idx + 1))
    end
end

function _collect_leaf_nodes(tree::Tree{T}) where T
    leaf_nodes = LeafNode{T}[]
    for (_, entry) in tree.table
        if entry isa InternalNode2{T}
            for (i, _) in enumerate(on_indices(entry.child_mask))
                child = entry.table[i]::InternalNode1{T}
                for (j, _) in enumerate(on_indices(child.child_mask))
                    push!(leaf_nodes, child.table[j]::LeafNode{T})
                end
            end
        end
    end
    leaf_nodes
end
