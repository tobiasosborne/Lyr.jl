# Accessors.jl - Tree queries and iteration
#
# Indexing Convention:
# - Coordinate offset functions (leaf_offset, internal1_child_index, etc.) return 0-based indices
# - Bitmask operations (is_on, on_indices, etc.) use 0-based bit positions
# - Julia arrays are 1-based, so add 1 when accessing: values[offset + 1]

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
            # O(1) table lookup using popcount
            tile_offset = count_on(node2.child_mask)
            tile_idx = count_on_before(node2.value_mask, i1_idx) + 1
            return node2.table[tile_offset + tile_idx].value
        end
        return tree.background
    end

    # O(1) child lookup using popcount
    child_idx = count_on_before(node2.child_mask, i1_idx) + 1
    node1 = node2.table[child_idx]::InternalNode1{T}

    # Navigate to Leaf
    leaf_idx = internal1_child_index(c)

    if is_off(node1.child_mask, leaf_idx)
        if is_on(node1.value_mask, leaf_idx)
            # O(1) table lookup using popcount
            tile_offset = count_on(node1.child_mask)
            tile_idx = count_on_before(node1.value_mask, leaf_idx) + 1
            return node1.table[tile_offset + tile_idx].value
        end
        return tree.background
    end

    # O(1) child lookup using popcount
    child_idx = count_on_before(node1.child_mask, leaf_idx) + 1
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

    # O(1) child lookup using popcount
    child_idx = count_on_before(node2.child_mask, i1_idx) + 1
    node1 = node2.table[child_idx]::InternalNode1{T}
    leaf_idx = internal1_child_index(c)

    if is_off(node1.child_mask, leaf_idx)
        return is_on(node1.value_mask, leaf_idx)
    end

    # O(1) child lookup using popcount
    child_idx = count_on_before(node1.child_mask, leaf_idx) + 1
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

Iterator over active voxels in a tree. True lazy iteration - traverses tree on demand
without collecting voxels upfront. Memory usage is O(1) regardless of voxel count.
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

# State for lazy tree traversal - tracks position at each level
# State tuple: (root_pairs, root_idx, i2_idx, i1_idx, leaf_mask_state)
# where indices are into the respective tables, and leaf_mask_state is for on_indices

function Base.iterate(it::ActiveVoxelsIterator{T}, state=nothing) where T
    if state === nothing
        # Initialize: collect root entries (typically very few - O(1) to O(10))
        root_pairs = collect(it.tree.table)
        isempty(root_pairs) && return nothing
        # Start with first root entry, first I2 child, first I1 child, first voxel
        return _advance_voxels(root_pairs, 1, 1, 1, nothing)
    else
        root_pairs, root_idx, i2_idx, i1_idx, leaf_state = state
        return _advance_voxels(root_pairs, root_idx, i2_idx, i1_idx, leaf_state)
    end
end

# Advance to next voxel, handling all level transitions
function _advance_voxels(root_pairs::Vector{Pair{Coord, Union{InternalNode2{T}, Tile{T}}}},
                         root_idx::Int, i2_idx::Int, i1_idx::Int,
                         leaf_state) where T
    while root_idx <= length(root_pairs)
        entry = root_pairs[root_idx].second

        # Skip tiles at root level (TODO: could iterate tile voxels if needed)
        if entry isa Tile{T}
            root_idx += 1
            i2_idx = 1
            i1_idx = 1
            leaf_state = nothing
            continue
        end

        node2 = entry::InternalNode2{T}
        n_i2_children = count_on(node2.child_mask)

        while i2_idx <= n_i2_children
            node1 = node2.table[i2_idx]::InternalNode1{T}
            n_i1_children = count_on(node1.child_mask)

            while i1_idx <= n_i1_children
                leaf = node1.table[i1_idx]::LeafNode{T}

                # Iterate voxels in this leaf
                leaf_iter = on_indices(leaf.value_mask)
                iter_result = leaf_state === nothing ? iterate(leaf_iter) : iterate(leaf_iter, leaf_state)

                if iter_result !== nothing
                    offset, next_leaf_state = iter_result
                    # Compute coordinate from leaf origin + offset (OpenVDB: x*64 + y*8 + z)
                    lz = offset & 7
                    ly = (offset >> 3) & 7
                    lx = (offset >> 6) & 7
                    c = Coord(leaf.origin.x + Int32(lx),
                              leaf.origin.y + Int32(ly),
                              leaf.origin.z + Int32(lz))
                    val = leaf.values[offset + 1]
                    return ((c, val), (root_pairs, root_idx, i2_idx, i1_idx, next_leaf_state))
                end

                # Move to next leaf
                i1_idx += 1
                leaf_state = nothing
            end

            # Move to next Internal1
            i2_idx += 1
            i1_idx = 1
            leaf_state = nothing
        end

        # Move to next root entry
        root_idx += 1
        i2_idx = 1
        i1_idx = 1
        leaf_state = nothing
    end

    nothing
end

"""
    LeavesIterator{T}

Iterator over leaf nodes in a tree. True lazy iteration - traverses tree on demand
without collecting leaves upfront. Memory usage is O(1) regardless of leaf count.
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

# State tuple: (root_pairs, root_idx, i2_idx, i1_idx)
function Base.iterate(it::LeavesIterator{T}, state=nothing) where T
    if state === nothing
        root_pairs = collect(it.tree.table)
        isempty(root_pairs) && return nothing
        return _advance_leaves(root_pairs, 1, 1, 1)
    else
        root_pairs, root_idx, i2_idx, i1_idx = state
        return _advance_leaves(root_pairs, root_idx, i2_idx, i1_idx)
    end
end

function _advance_leaves(root_pairs::Vector{Pair{Coord, Union{InternalNode2{T}, Tile{T}}}},
                         root_idx::Int, i2_idx::Int, i1_idx::Int) where T
    while root_idx <= length(root_pairs)
        entry = root_pairs[root_idx].second

        if entry isa Tile{T}
            root_idx += 1
            i2_idx = 1
            i1_idx = 1
            continue
        end

        node2 = entry::InternalNode2{T}
        n_i2_children = count_on(node2.child_mask)

        while i2_idx <= n_i2_children
            node1 = node2.table[i2_idx]::InternalNode1{T}
            n_i1_children = count_on(node1.child_mask)

            if i1_idx <= n_i1_children
                leaf = node1.table[i1_idx]::LeafNode{T}
                return (leaf, (root_pairs, root_idx, i2_idx, i1_idx + 1))
            end

            i2_idx += 1
            i1_idx = 1
        end

        root_idx += 1
        i2_idx = 1
        i1_idx = 1
    end

    nothing
end
