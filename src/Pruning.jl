# Pruning.jl - Collapse uniform leaf nodes into tiles
#
# VDB pruning identifies leaf nodes where all 512 voxel values are within
# a given tolerance and replaces them with constant-value tiles, reducing
# memory usage without significant loss of fidelity.

"""
    _is_uniform_leaf(leaf::LeafNode{T}, tolerance) where T -> Bool

Check whether all 512 values in a leaf are within `tolerance` of each other
(i.e., max - min <= tolerance).
"""
function _is_uniform_leaf(leaf::LeafNode{T}, tolerance) where T
    vmin = leaf.values[1]
    vmax = leaf.values[1]
    for i in 2:512
        v = leaf.values[i]
        vmin = min(vmin, v)
        vmax = max(vmax, v)
    end
    return vmax - vmin <= tolerance
end

"""
    _prune_i1(i1::InternalNode1{T}, tolerance) where T -> InternalNode1{T}

Prune an Internal1 node by collapsing uniform leaf children into tiles.
Returns a new InternalNode1 with updated masks and child/tile vectors.
"""
function _prune_i1(i1::InternalNode1{T}, tolerance) where T
    child_indices = collect(on_indices(i1.child_mask))  # 0-indexed positions
    new_children = LeafNode{T}[]
    new_child_bits = Int[]
    new_tile_bits = Int[]
    new_tiles = Tile{T}[]

    # Keep existing tiles
    tile_indices = collect(on_indices(i1.value_mask))
    for (i, tile_idx) in enumerate(tile_indices)
        push!(new_tile_bits, tile_idx)
        push!(new_tiles, i1.tiles[i])
    end

    # Process children: collapse uniform leaves into tiles
    for (i, child_idx) in enumerate(child_indices)
        leaf = i1.children[i]
        if _is_uniform_leaf(leaf, tolerance)
            # Convert to tile — use first value, active if any voxel was active
            push!(new_tile_bits, child_idx)
            push!(new_tiles, Tile{T}(leaf.values[1], !is_empty(leaf.value_mask)))
        else
            push!(new_children, leaf)
            push!(new_child_bits, child_idx)
        end
    end

    # Sort tiles by bit position so ordering matches mask popcount indexing
    perm = sortperm(new_tile_bits)
    new_tile_bits = new_tile_bits[perm]
    new_tiles = new_tiles[perm]

    new_cmask = _build_mask(Internal1Mask, new_child_bits)
    new_vmask = _build_mask(Internal1Mask, new_tile_bits)

    InternalNode1{T}(i1.origin, new_cmask, new_vmask, new_children, new_tiles)
end

"""
    _prune_i2(i2::InternalNode2{T}, tolerance) where T -> InternalNode2{T}

Prune an Internal2 node by pruning each of its I1 children (leaf → tile).
Returns a new InternalNode2 with rebuilt I1 children.
"""
function _prune_i2(i2::InternalNode2{T}, tolerance) where T
    new_children = InternalNode1{T}[]
    for i1 in i2.children
        push!(new_children, _prune_i1(i1, tolerance))
    end
    InternalNode2{T}(i2.origin, i2.child_mask, i2.value_mask, new_children, i2.tiles)
end

"""
    prune(grid::Grid{T}; tolerance=zero(T)) where T -> Grid{T}

Return a new grid with uniform leaf nodes collapsed into tiles.

A leaf is considered "uniform" if all 512 of its voxel values fall within
`tolerance` of each other (max - min <= tolerance). Uniform leaves are
replaced by constant-value tiles, reducing tree size.

# Arguments
- `grid`: The input grid to prune.
- `tolerance`: Maximum allowed variation within a leaf for it to be collapsed.
  Defaults to `zero(T)` (exact uniformity required).

# Returns
A new `Grid{T}` with the same metadata and transform, but a pruned tree.

# Example
```julia
pruned = prune(grid)                   # exact match only
pruned = prune(grid; tolerance=0.01f0) # allow small variation
```
"""
function prune(grid::Grid{T}; tolerance=zero(T)) where T
    tree = grid.tree

    # Rebuild root table with pruned I2 nodes
    new_table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()
    for (origin, entry) in tree.table
        if entry isa Tile{T}
            new_table[origin] = entry
        else
            new_table[origin] = _prune_i2(entry::InternalNode2{T}, tolerance)
        end
    end

    new_tree = RootNode{T}(tree.background, new_table)
    Grid{T}(grid.name, grid.grid_class, grid.transform, new_tree)
end
