# GridOps.jl — Element-wise grid compositing, clipping, and conversion operations
#
# All operations are non-mutating: they iterate source grid(s), compute results,
# and build new grids via Dict{Coord,T} accumulation + build_grid().

# =============================================================================
# Background / Activation operations
# =============================================================================

"""
    change_background(grid::Grid{T}, new_bg::T) where T -> Grid{T}

Return a new grid with the background value changed to `new_bg`.
Inactive voxels that held the old background value are updated to `new_bg`.
Active voxels are unchanged.
"""
function change_background(grid::Grid{T}, new_bg::T) where T
    tree = grid.tree
    old_bg = tree.background

    # Collect all voxels, replacing inactive values with new background
    data = Dict{Coord, T}()
    for leaf in leaves(tree)
        origin = leaf.origin
        for offset in on_indices(leaf.value_mask)
            lz = offset & 7
            ly = (offset >> 3) & 7
            lx = (offset >> 6) & 7
            c = Coord(origin.x + Int32(lx), origin.y + Int32(ly), origin.z + Int32(lz))
            data[c] = leaf.values[offset + 1]
        end
    end

    vs = _grid_voxel_size(grid)
    build_grid(data, new_bg; name=grid.name, grid_class=grid.grid_class, voxel_size=vs)
end

"""
    activate(grid::Grid{T}, value::T) where T -> Grid{T}

Return a new grid where any voxel (active or inactive within existing leaves)
whose stored value equals `value` is made active. Voxels already active are
kept. This effectively expands the active set.
"""
function activate(grid::Grid{T}, value::T) where T
    tree = grid.tree

    # Start with all currently-active voxels
    data = Dict{Coord, T}()
    for (c, v) in active_voxels(tree)
        data[c] = v
    end

    # Also activate any inactive voxels in existing leaves that match `value`
    for leaf in leaves(tree)
        origin = leaf.origin
        for offset in off_indices(leaf.value_mask)
            if leaf.values[offset + 1] == value
                lz = offset & 7
                ly = (offset >> 3) & 7
                lx = (offset >> 6) & 7
                c = Coord(origin.x + Int32(lx), origin.y + Int32(ly), origin.z + Int32(lz))
                data[c] = value
            end
        end
    end

    vs = _grid_voxel_size(grid)
    build_grid(data, tree.background; name=grid.name, grid_class=grid.grid_class, voxel_size=vs)
end

"""
    deactivate(grid::Grid{T}, value::T) where T -> Grid{T}

Return a new grid where any active voxel whose value equals `value` is
deactivated (removed from the active set). Other active voxels are kept.
"""
function deactivate(grid::Grid{T}, value::T) where T
    tree = grid.tree

    data = Dict{Coord, T}()
    for (c, v) in active_voxels(tree)
        if v != value
            data[c] = v
        end
    end

    vs = _grid_voxel_size(grid)
    build_grid(data, tree.background; name=grid.name, grid_class=grid.grid_class, voxel_size=vs)
end

# =============================================================================
# Dense copy operations
# =============================================================================

"""
    copy_to_dense(grid::Grid{T}, bbox::BBox) where T -> Array{T, 3}

Extract the region defined by `bbox` into a dense 3D array.
The array is filled with the grid's background value, then overwritten
with `get_value` for every coordinate in the bounding box.

Array indices map as:
  array[ix, iy, iz] corresponds to coord(bbox.min.x + ix - 1, bbox.min.y + iy - 1, bbox.min.z + iz - 1)
"""
function copy_to_dense(grid::Grid{T}, bbox::BBox) where T
    tree = grid.tree
    dx = Int(bbox.max.x - bbox.min.x) + 1
    dy = Int(bbox.max.y - bbox.min.y) + 1
    dz = Int(bbox.max.z - bbox.min.z) + 1

    result = fill(tree.background, dx, dy, dz)

    for iz in Int32(0):Int32(dz - 1)
        for iy in Int32(0):Int32(dy - 1)
            for ix in Int32(0):Int32(dx - 1)
                c = Coord(bbox.min.x + ix, bbox.min.y + iy, bbox.min.z + iz)
                result[ix + 1, iy + 1, iz + 1] = get_value(tree, c)
            end
        end
    end

    result
end

"""
    copy_from_dense(array::Array{T, 3}, background::T;
                    bbox_min::Coord=coord(0, 0, 0),
                    name::String="density",
                    grid_class::GridClass=GRID_FOG_VOLUME,
                    voxel_size::Float64=1.0) where T -> Grid{T}

Build a VDB grid from a dense 3D array. Only values that differ from
`background` are stored as active voxels. `bbox_min` defines the world-space
origin of `array[1,1,1]`.
"""
function copy_from_dense(array::Array{T, 3}, background::T;
                         bbox_min::Coord=coord(0, 0, 0),
                         name::String="density",
                         grid_class::GridClass=GRID_FOG_VOLUME,
                         voxel_size::Float64=1.0) where T
    nx, ny, nz = size(array)
    data = Dict{Coord, T}()

    for iz in 1:nz
        for iy in 1:ny
            for ix in 1:nx
                v = array[ix, iy, iz]
                if v != background
                    c = Coord(bbox_min.x + Int32(ix - 1),
                              bbox_min.y + Int32(iy - 1),
                              bbox_min.z + Int32(iz - 1))
                    data[c] = v
                end
            end
        end
    end

    build_grid(data, background; name=name, grid_class=grid_class, voxel_size=voxel_size)
end

# =============================================================================
# Compositing operations
# =============================================================================

"""
    comp_max(a::Grid{T}, b::Grid{T}) where T -> Grid{T}

Return a new grid whose active voxels are the union of `a` and `b`,
taking the maximum value at coordinates where both are active.
"""
function comp_max(a::Grid{T}, b::Grid{T}) where T
    data = Dict{Coord, T}()

    for (c, v) in active_voxels(a.tree)
        data[c] = v
    end
    for (c, v) in active_voxels(b.tree)
        existing = get(data, c, nothing)
        data[c] = existing === nothing ? v : max(existing, v)
    end

    vs = _grid_voxel_size(a)
    build_grid(data, a.tree.background; name=a.name, grid_class=a.grid_class, voxel_size=vs)
end

"""
    comp_min(a::Grid{T}, b::Grid{T}) where T -> Grid{T}

Return a new grid whose active voxels are the union of `a` and `b`,
taking the minimum value at coordinates where both are active.
"""
function comp_min(a::Grid{T}, b::Grid{T}) where T
    data = Dict{Coord, T}()

    for (c, v) in active_voxels(a.tree)
        data[c] = v
    end
    for (c, v) in active_voxels(b.tree)
        existing = get(data, c, nothing)
        data[c] = existing === nothing ? v : min(existing, v)
    end

    vs = _grid_voxel_size(a)
    build_grid(data, a.tree.background; name=a.name, grid_class=a.grid_class, voxel_size=vs)
end

"""
    comp_sum(a::Grid{T}, b::Grid{T}) where T -> Grid{T}

Return a new grid whose active voxels are the union of `a` and `b`.
At overlapping coordinates the values are summed; at non-overlapping
coordinates the original value is kept.
"""
function comp_sum(a::Grid{T}, b::Grid{T}) where T
    data = Dict{Coord, T}()

    for (c, v) in active_voxels(a.tree)
        data[c] = v
    end
    for (c, v) in active_voxels(b.tree)
        existing = get(data, c, nothing)
        data[c] = existing === nothing ? v : existing + v
    end

    vs = _grid_voxel_size(a)
    build_grid(data, a.tree.background; name=a.name, grid_class=a.grid_class, voxel_size=vs)
end

"""
    comp_mul(a::Grid{T}, b::Grid{T}) where T -> Grid{T}

Return a new grid whose active voxels are the union of `a` and `b`.
At overlapping coordinates the values are multiplied; at non-overlapping
coordinates the original value is kept.
"""
function comp_mul(a::Grid{T}, b::Grid{T}) where T
    data = Dict{Coord, T}()

    for (c, v) in active_voxels(a.tree)
        data[c] = v
    end
    for (c, v) in active_voxels(b.tree)
        existing = get(data, c, nothing)
        data[c] = existing === nothing ? v : existing * v
    end

    vs = _grid_voxel_size(a)
    build_grid(data, a.tree.background; name=a.name, grid_class=a.grid_class, voxel_size=vs)
end

"""
    comp_replace(a::Grid{T}, b::Grid{T}) where T -> Grid{T}

Return a new grid that starts with `a`'s active voxels, then overwrites
with `b`'s active voxels. B "stamps on top of" A.
"""
function comp_replace(a::Grid{T}, b::Grid{T}) where T
    data = Dict{Coord, T}()

    for (c, v) in active_voxels(a.tree)
        data[c] = v
    end
    for (c, v) in active_voxels(b.tree)
        data[c] = v
    end

    vs = _grid_voxel_size(a)
    build_grid(data, a.tree.background; name=a.name, grid_class=a.grid_class, voxel_size=vs)
end

# =============================================================================
# Clipping operations
# =============================================================================

"""
    clip(grid::Grid{T}, bbox::BBox) where T -> Grid{T}

Return a new grid containing only the active voxels of `grid` that lie
within the bounding box `bbox`.
"""
function clip(grid::Grid{T}, bbox::BBox) where T
    tree = grid.tree
    data = Dict{Coord, T}()

    for (c, v) in active_voxels(tree)
        if contains(bbox, c)
            data[c] = v
        end
    end

    vs = _grid_voxel_size(grid)
    build_grid(data, tree.background; name=grid.name, grid_class=grid.grid_class, voxel_size=vs)
end

"""
    clip(grid::Grid{T}, mask_grid::Grid) where T -> Grid{T}

Return a new grid containing only the active voxels of `grid` at
coordinates where `mask_grid` is also active.
"""
function clip(grid::Grid{T}, mask_grid::Grid) where T
    tree = grid.tree
    mask_tree = mask_grid.tree
    data = Dict{Coord, T}()

    for (c, v) in active_voxels(tree)
        if is_active(mask_tree, c)
            data[c] = v
        end
    end

    vs = _grid_voxel_size(grid)
    build_grid(data, tree.background; name=grid.name, grid_class=grid.grid_class, voxel_size=vs)
end

# =============================================================================
# Internal helpers
# =============================================================================

"""Extract uniform voxel size from a grid's transform (first axis)."""
function _grid_voxel_size(grid::Grid)::Float64
    vs = voxel_size(grid.transform)
    vs[1]
end
