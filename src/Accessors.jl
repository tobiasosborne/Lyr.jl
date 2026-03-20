# Accessors.jl — Tree queries, cached value access, and voxel/leaf iteration
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
# VDB tree hierarchy: Root -> Internal2(32^3) -> Internal1(16^3) -> Leaf(8^3)

"""Number of voxels covered by a root-level tile (4096^3)."""
const ROOT_TILE_VOXELS = Int64(4096)^3
"""Number of voxels covered by an Internal2-level tile (128^3)."""
const INTERNAL2_TILE_VOXELS = 128^3
"""Number of voxels covered by an Internal1-level tile (8^3)."""
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

# =============================================================================
# Shared tree iteration helpers
# =============================================================================

"""Convert leaf-local voxel offset (0:511) to world coordinate."""
@inline function _offset_to_coord(origin::Coord, offset::Int)
    Coord(origin.x + Int32((offset >> 6) & 7),
          origin.y + Int32((offset >> 3) & 7),
          origin.z + Int32(offset & 7))
end

"""Collect root pairs for iteration. Returns empty vector for empty trees."""
@inline function _collect_root_pairs(tree::Tree{T}) where T
    collect(tree.table)
end

"""
Advance through tree to the next leaf node, starting from the given position.
Returns `(leaf, root_idx, i2_idx, next_i1_idx)` or `nothing`.
"""
function _next_leaf(root_pairs::Vector{Pair{Coord, Union{InternalNode2{T}, Tile{T}}}},
                    root_idx::Int, i2_idx::Int, i1_idx::Int) where T
    while root_idx <= length(root_pairs)
        entry = root_pairs[root_idx].second
        if entry isa Tile{T}
            root_idx += 1; i2_idx = 1; i1_idx = 1; continue
        end
        node2 = entry::InternalNode2{T}
        while i2_idx <= length(node2.children)
            node1 = node2.children[i2_idx]
            if i1_idx <= length(node1.children)
                return (node1.children[i1_idx], root_idx, i2_idx, i1_idx + 1)
            end
            i2_idx += 1; i1_idx = 1
        end
        root_idx += 1; i2_idx = 1; i1_idx = 1
    end
    nothing
end

# =============================================================================
# Leaves Iterator
# =============================================================================

"""
    LeavesIterator{T}

Iterator over all `LeafNode{T}` nodes in a VDB tree.
"""
struct LeavesIterator{T}
    tree::Tree{T}
end

"""
    leaves(tree::Tree{T}) -> LeavesIterator{T}

Return an iterator over all leaf nodes in the tree.
"""
leaves(tree::Tree{T}) where T = LeavesIterator{T}(tree)

Base.IteratorSize(::Type{LeavesIterator{T}}) where T = Base.SizeUnknown()
Base.eltype(::Type{LeavesIterator{T}}) where T = LeafNode{T}

function Base.iterate(it::LeavesIterator{T}, state=nothing) where T
    if state === nothing
        root_pairs = _collect_root_pairs(it.tree)
        isempty(root_pairs) && return nothing
        result = _next_leaf(root_pairs, 1, 1, 1)
    else
        root_pairs, root_idx, i2_idx, i1_idx = state
        result = _next_leaf(root_pairs, root_idx, i2_idx, i1_idx)
    end
    result === nothing && return nothing
    leaf, ri, i2i, i1i = result
    return (leaf, (root_pairs, ri, i2i, i1i))
end

# =============================================================================
# Mask-filtered Voxel Iterator (active / inactive)
# =============================================================================

"""Voxel iterator that yields (Coord, T) for voxels matching a mask filter."""
struct MaskVoxelIterator{T, F}
    tree::Tree{T}
    mask_fn::F   # on_indices or off_indices
end

"""
    active_voxels(tree::Tree{T}) -> MaskVoxelIterator

Return an iterator over active voxels as `(Coord, T)` pairs.
"""
active_voxels(tree::Tree{T}) where T = MaskVoxelIterator{T, typeof(on_indices)}(tree, on_indices)

"""
    inactive_voxels(tree::Tree{T}) -> MaskVoxelIterator

Return an iterator over inactive (stored but not active) voxels as `(Coord, T)` pairs.
"""
inactive_voxels(tree::Tree{T}) where T = MaskVoxelIterator{T, typeof(off_indices)}(tree, off_indices)

Base.IteratorSize(::Type{<:MaskVoxelIterator}) = Base.SizeUnknown()
Base.eltype(::Type{MaskVoxelIterator{T, F}}) where {T, F} = Tuple{Coord, T}

# State: (root_pairs, root_idx, i2_idx, i1_idx, leaf_state, mask_fn)
function Base.iterate(it::MaskVoxelIterator{T, F}, state=nothing) where {T, F}
    if state === nothing
        root_pairs = _collect_root_pairs(it.tree)
        isempty(root_pairs) && return nothing
        return _advance_mask_voxels(root_pairs, 1, 1, 1, nothing, it.mask_fn)
    else
        root_pairs, ri, i2i, i1i, ls = state
        return _advance_mask_voxels(root_pairs, ri, i2i, i1i, ls, it.mask_fn)
    end
end

function _advance_mask_voxels(root_pairs::Vector{Pair{Coord, Union{InternalNode2{T}, Tile{T}}}},
                              root_idx::Int, i2_idx::Int, i1_idx::Int,
                              leaf_state, mask_fn) where T
    while true
        # Try to get next voxel from current leaf
        if leaf_state !== nothing
            # leaf_state is (leaf, mask_iter, mask_state)
            leaf, mask_iter, mask_state = leaf_state
            iter_result = iterate(mask_iter, mask_state)
            if iter_result !== nothing
                offset, next_ms = iter_result
                c = _offset_to_coord(leaf.origin, offset)
                val = leaf.values[offset + 1]
                return ((c, val), (root_pairs, root_idx, i2_idx, i1_idx, (leaf, mask_iter, next_ms)))
            end
            leaf_state = nothing
        end

        # Advance to next leaf
        result = _next_leaf(root_pairs, root_idx, i2_idx, i1_idx)
        result === nothing && return nothing
        leaf, root_idx, i2_idx, i1_idx = result

        # Start iterating this leaf's mask
        mask_iter = mask_fn(leaf.value_mask)
        iter_result = iterate(mask_iter)
        if iter_result !== nothing
            offset, next_ms = iter_result
            c = _offset_to_coord(leaf.origin, offset)
            val = leaf.values[offset + 1]
            return ((c, val), (root_pairs, root_idx, i2_idx, i1_idx, (leaf, mask_iter, next_ms)))
        end
        # Empty leaf for this filter — continue to next
    end
end

# Backward-compatible type aliases
const ActiveVoxelsIterator{T} = MaskVoxelIterator{T, typeof(on_indices)}
const InactiveVoxelsIterator{T} = MaskVoxelIterator{T, typeof(off_indices)}

# =============================================================================
# All Voxels Iterator
# =============================================================================

"""
Iterator over all voxels (active and inactive). Yields `(Coord, T, Bool)` tuples.
"""
struct AllVoxelsIterator{T}
    tree::Tree{T}
end

"""
    all_voxels(tree::Tree{T}) -> AllVoxelsIterator{T}

Return an iterator over all stored voxels as `(Coord, T, Bool)` tuples,
where the Bool indicates whether the voxel is active.
"""
all_voxels(tree::Tree{T}) where T = AllVoxelsIterator{T}(tree)

Base.IteratorSize(::Type{AllVoxelsIterator{T}}) where T = Base.SizeUnknown()
Base.eltype(::Type{AllVoxelsIterator{T}}) where T = Tuple{Coord, T, Bool}

# State: (root_pairs, root_idx, i2_idx, i1_idx, voxel_offset)
function Base.iterate(it::AllVoxelsIterator{T}, state=nothing) where T
    if state === nothing
        root_pairs = _collect_root_pairs(it.tree)
        isempty(root_pairs) && return nothing
        return _advance_all_voxels(root_pairs, 1, 1, 1, 0)
    else
        root_pairs, ri, i2i, i1i, voff = state
        return _advance_all_voxels(root_pairs, ri, i2i, i1i, voff)
    end
end

function _advance_all_voxels(root_pairs::Vector{Pair{Coord, Union{InternalNode2{T}, Tile{T}}}},
                             root_idx::Int, i2_idx::Int, i1_idx::Int,
                             voxel_offset::Int) where T
    while true
        # Try current leaf
        if voxel_offset > 0 && voxel_offset < 512
            # We're mid-leaf — find the current leaf again
            result = _next_leaf(root_pairs, root_idx, i2_idx, i1_idx - 1)
            if result !== nothing
                leaf = result[1]
                c = _offset_to_coord(leaf.origin, voxel_offset)
                val = leaf.values[voxel_offset + 1]
                active = is_on(leaf.value_mask, voxel_offset)
                return ((c, val, active), (root_pairs, root_idx, i2_idx, i1_idx, voxel_offset + 1))
            end
        end

        # Advance to next leaf
        result = _next_leaf(root_pairs, root_idx, i2_idx, i1_idx)
        result === nothing && return nothing
        leaf, root_idx, i2_idx, i1_idx = result

        # Emit first voxel (offset 0)
        c = _offset_to_coord(leaf.origin, 0)
        val = leaf.values[1]
        active = is_on(leaf.value_mask, 0)
        return ((c, val, active), (root_pairs, root_idx, i2_idx, i1_idx, 1))
    end
end

# =============================================================================
# InternalNode2 Iterator
# =============================================================================

"""
    I2NodesIterator{T}

Iterator over all `InternalNode2{T}` nodes in a VDB tree, yielding `(node, origin)` pairs.
"""
struct I2NodesIterator{T}
    tree::Tree{T}
end

"""
    i2_nodes(tree::Tree{T})

Return an iterator over all InternalNode2 nodes as `(InternalNode2{T}, Coord)` pairs.
"""
i2_nodes(tree::Tree{T}) where T = I2NodesIterator{T}(tree)

Base.IteratorSize(::Type{I2NodesIterator{T}}) where T = Base.SizeUnknown()
Base.eltype(::Type{I2NodesIterator{T}}) where T = Tuple{InternalNode2{T}, Coord}

function Base.iterate(it::I2NodesIterator{T}, state=nothing) where T
    pairs = state === nothing ? collect(it.tree.table) : state[1]
    idx = state === nothing ? 1 : state[2]
    while idx <= length(pairs)
        origin, entry = pairs[idx]
        if entry isa InternalNode2{T}
            return ((entry, origin), (pairs, idx + 1))
        end
        idx += 1
    end
    nothing
end

# =============================================================================
# InternalNode1 Iterator
# =============================================================================

"""
    I1NodesIterator{T}

Iterator over all `InternalNode1{T}` nodes in a VDB tree, yielding `(node, origin)` pairs.
"""
struct I1NodesIterator{T}
    tree::Tree{T}
end

"""
    i1_nodes(tree::Tree{T})

Return an iterator over all InternalNode1 nodes as `(InternalNode1{T}, Coord)` pairs.
"""
i1_nodes(tree::Tree{T}) where T = I1NodesIterator{T}(tree)

Base.IteratorSize(::Type{I1NodesIterator{T}}) where T = Base.SizeUnknown()
Base.eltype(::Type{I1NodesIterator{T}}) where T = Tuple{InternalNode1{T}, Coord}

function Base.iterate(it::I1NodesIterator{T}, state=nothing) where T
    if state === nothing
        root_pairs = collect(it.tree.table)
        return _advance_i1_nodes(root_pairs, 1, 1)
    else
        root_pairs, root_idx, i2_idx = state
        return _advance_i1_nodes(root_pairs, root_idx, i2_idx)
    end
end

function _advance_i1_nodes(root_pairs::Vector{Pair{Coord, Union{InternalNode2{T}, Tile{T}}}},
                           root_idx::Int, i2_idx::Int) where T
    while root_idx <= length(root_pairs)
        entry = root_pairs[root_idx].second
        if entry isa InternalNode2{T}
            node2 = entry::InternalNode2{T}
            if i2_idx <= length(node2.children)
                node1 = node2.children[i2_idx]
                return ((node1, node1.origin), (root_pairs, root_idx, i2_idx + 1))
            end
        end
        root_idx += 1
        i2_idx = 1
    end
    nothing
end

# =============================================================================
# Batch parallel leaf processing
# =============================================================================

"""
    collect_leaves(tree::Tree{T}) -> Vector{LeafNode{T}}

Materialize all leaves into a vector for random access and parallel chunking.
"""
function collect_leaves(tree::Tree{T})::Vector{LeafNode{T}} where T
    result = LeafNode{T}[]
    for leaf in leaves(tree)
        push!(result, leaf)
    end
    result
end

"""
    foreach_leaf(f, tree::Tree{T}) -> Nothing

Apply `f(leaf)` to every leaf in the tree, parallelized across threads.
"""
function foreach_leaf(f::F, tree::Tree{T})::Nothing where {F, T}
    lvs = collect_leaves(tree)
    Threads.@threads for leaf in lvs
        f(leaf)
    end
    nothing
end
