# Accessors.jl - Tree queries and iteration
#
# Indexing Convention:
# - Coordinate offset functions (leaf_offset, internal1_child_index, etc.) return 0-based indices
# - Bitmask operations (is_on, on_indices, etc.) use 0-based bit positions
# - Julia arrays are 1-based, so add 1 when accessing: values[offset + 1]

"""
    ValueAccessor{T}

Mutable cache for accelerating repeated nearby lookups into a VDB tree.
Caches the most recently accessed leaf, Internal1, and Internal2 nodes.
For coherent access patterns (trilinear interpolation, ray marching),
7 of 8 lookups hit the cached leaf — yielding 5-8x speedup.

# Usage
```julia
acc = ValueAccessor(tree)
v = get_value(acc, coord(10, 20, 30))  # full traversal, caches nodes
v = get_value(acc, coord(10, 20, 31))  # cache hit on leaf — O(1)
```
"""
mutable struct ValueAccessor{T}
    const tree::Tree{T}
    # Cached leaf
    leaf::Union{LeafNode{T}, Nothing}
    leaf_origin::Coord
    # Cached Internal1
    i1::Union{InternalNode1{T}, Nothing}
    i1_origin::Coord
    # Cached Internal2
    i2::Union{InternalNode2{T}, Nothing}
    i2_origin::Coord
end

"""
    ValueAccessor(tree::Tree{T}) -> ValueAccessor{T}

Create a ValueAccessor with empty cache.
"""
function ValueAccessor(tree::Tree{T}) where T
    z = Coord(Int32(0), Int32(0), Int32(0))
    ValueAccessor{T}(tree, nothing, z, nothing, z, nothing, z)
end

"""
    get_value(acc::ValueAccessor{T}, c::Coord) -> T

Get the value at coordinate `c`, using cached nodes when possible.
"""
function get_value(acc::ValueAccessor{T}, c::Coord)::T where T
    # Level 0: check cached leaf
    if acc.leaf !== nothing && leaf_origin(c) == acc.leaf_origin
        offset = leaf_offset(c)
        return acc.leaf.values[offset + 1]
    end

    # Level 1: check cached I1
    if acc.i1 !== nothing && internal1_origin(c) == acc.i1_origin
        return _get_from_i1(acc, acc.i1, c)
    end

    # Level 2: check cached I2
    if acc.i2 !== nothing && internal2_origin(c) == acc.i2_origin
        return _get_from_i2(acc, acc.i2, c)
    end

    # Full traversal from root
    return _get_from_root(acc, c)
end

function _get_from_root(acc::ValueAccessor{T}, c::Coord)::T where T
    tree = acc.tree
    i2_origin = internal2_origin(c)
    entry = get(tree.table, i2_origin, nothing)
    entry === nothing && return tree.background
    entry isa Tile{T} && return entry.value

    node2 = entry::InternalNode2{T}
    acc.i2 = node2
    acc.i2_origin = i2_origin
    return _get_from_i2(acc, node2, c)
end

function _get_from_i2(acc::ValueAccessor{T}, node2::InternalNode2{T}, c::Coord)::T where T
    i1_idx = internal2_child_index(c)

    if is_off(node2.child_mask, i1_idx)
        if is_on(node2.value_mask, i1_idx)
            tile_idx = count_on_before(node2.value_mask, i1_idx) + 1
            return node2.tiles[tile_idx].value
        end
        return acc.tree.background
    end

    child_idx = count_on_before(node2.child_mask, i1_idx) + 1
    node1 = node2.children[child_idx]
    acc.i1 = node1
    acc.i1_origin = internal1_origin(c)
    return _get_from_i1(acc, node1, c)
end

function _get_from_i1(acc::ValueAccessor{T}, node1::InternalNode1{T}, c::Coord)::T where T
    leaf_idx = internal1_child_index(c)

    if is_off(node1.child_mask, leaf_idx)
        if is_on(node1.value_mask, leaf_idx)
            tile_idx = count_on_before(node1.value_mask, leaf_idx) + 1
            return node1.tiles[tile_idx].value
        end
        return acc.tree.background
    end

    child_idx = count_on_before(node1.child_mask, leaf_idx) + 1
    leaf = node1.children[child_idx]
    acc.leaf = leaf
    acc.leaf_origin = leaf_origin(c)
    offset = leaf_offset(c)
    return leaf.values[offset + 1]
end

# =============================================================================
# Dispatch-based tree probe — shared by get_value and is_active
# =============================================================================

"""Shared mask-check logic for internal nodes. Returns (value, is_active) or descends."""
@inline function _probe_internal(node, idx::Int, c::Coord, background::T) where T
    if is_off(node.child_mask, idx)
        if is_on(node.value_mask, idx)
            tile_idx = count_on_before(node.value_mask, idx) + 1
            return (node.tiles[tile_idx].value, true)
        end
        return (background, false)
    end
    child_idx = count_on_before(node.child_mask, idx) + 1
    _probe_node(node.children[child_idx], c, background)
end

"""Leaf base case: return value and active flag."""
@inline function _probe_node(leaf::LeafNode{T}, c::Coord, ::T) where T
    offset = leaf_offset(c)
    (leaf.values[offset + 1], is_on(leaf.value_mask, offset))
end

"""I1 dispatch: compute child index, then shared probe."""
@inline function _probe_node(node::InternalNode1{T}, c::Coord, bg::T) where T
    _probe_internal(node, internal1_child_index(c), c, bg)
end

"""I2 dispatch: compute child index, then shared probe."""
@inline function _probe_node(node::InternalNode2{T}, c::Coord, bg::T) where T
    _probe_internal(node, internal2_child_index(c), c, bg)
end

"""Navigate tree from root, returning (value, is_active)."""
function _tree_probe(tree::Tree{T}, c::Coord) where T
    entry = get(tree.table, internal2_origin(c), nothing)
    entry === nothing && return (tree.background, false)
    entry isa Tile{T} && return (entry.value, entry.active)
    _probe_node(entry::InternalNode2{T}, c, tree.background)
end

"""
    get_value(tree::Tree{T}, c::Coord) -> T

Get the value at coordinate `c`. Returns the background value if the coordinate
is not stored in the tree.
"""
get_value(tree::Tree{T}, c::Coord) where T = _tree_probe(tree, c)[1]

"""
    is_active(tree::Tree{T}, c::Coord) -> Bool

Check if the voxel at coordinate `c` is active.
"""
is_active(tree::Tree{T}, c::Coord) where T = _tree_probe(tree, c)[2]

"""
    is_active(acc::ValueAccessor{T}, c::Coord) -> Bool

Check if the voxel at coordinate `c` is active, using the accessor's tree.
"""
is_active(acc::ValueAccessor{T}, c::Coord) where T = _tree_probe(acc.tree, c)[2]

# Tile region sizes for counting active voxels
# VDB tree hierarchy: Root → Internal2(32³) → Internal1(16³) → Leaf(8³)
const ROOT_TILE_VOXELS = 4096^3
const INTERNAL2_TILE_VOXELS = 128^3
const INTERNAL1_TILE_VOXELS = 8^3

"""Count active tile voxels in an internal node."""
_count_active_tiles(node, tile_voxels::Int) = count(t -> t.active, node.tiles) * tile_voxels

_count_active(node::InternalNode1{T}) where T =
    _count_active_tiles(node, INTERNAL1_TILE_VOXELS) + sum(c -> count_on(c.value_mask), node.children; init=0)

_count_active(node::InternalNode2{T}) where T =
    _count_active_tiles(node, INTERNAL2_TILE_VOXELS) + sum(_count_active, node.children; init=0)

"""
    active_voxel_count(tree::Tree{T}) -> Int

Count the total number of active voxels in the tree.
"""
function active_voxel_count(tree::Tree{T})::Int where T
    total = 0
    for (_, entry) in tree.table
        total += entry isa Tile{T} ? (entry.active ? ROOT_TILE_VOXELS : 0) : _count_active(entry::InternalNode2{T})
    end
    total
end

"""
    leaf_count(tree::Tree{T}) -> Int

Count the number of leaf nodes in the tree.
"""
function leaf_count(tree::Tree{T})::Int where T
    total = 0
    for (_, entry) in tree.table
        entry isa InternalNode2{T} && (total += sum(c -> count_on(c.child_mask), entry.children; init=0))
    end
    total
end

"""
    active_bounding_box(tree::Tree{T}) -> Union{BBox, Nothing}

Compute the bounding box of all active voxels. Returns `nothing` if there are no active voxels.

Runs in O(leaves) by using each leaf's origin rather than iterating every voxel.
The result may overestimate by up to 7 voxels per axis (one leaf dimension).
"""
function active_bounding_box(tree::Tree{T})::Union{BBox, Nothing} where T
    min_coord = nothing
    max_coord = nothing
    leaf_max = Coord(Int32(7), Int32(7), Int32(7))

    for leaf in leaves(tree)
        count_on(leaf.value_mask) == 0 && continue
        if min_coord === nothing
            min_coord = leaf.origin
            max_coord = leaf.origin + leaf_max
        else
            min_coord = min(min_coord, leaf.origin)
            max_coord = max(max_coord, leaf.origin + leaf_max)
        end
    end

    min_coord === nothing ? nothing : BBox(min_coord, max_coord)
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
        n_i2_children = length(node2.children)

        while i2_idx <= n_i2_children
            node1 = node2.children[i2_idx]
            n_i1_children = length(node1.children)

            while i1_idx <= n_i1_children
                leaf = node1.children[i1_idx]

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
        n_i2_children = length(node2.children)

        while i2_idx <= n_i2_children
            node1 = node2.children[i2_idx]
            n_i1_children = length(node1.children)

            if i1_idx <= n_i1_children
                leaf = node1.children[i1_idx]
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
