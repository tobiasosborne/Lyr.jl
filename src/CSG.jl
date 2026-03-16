# CSG.jl - Constructive Solid Geometry operations on level set grids
#
# Level set grids store signed distance field (SDF) values where:
#   negative = inside, zero = on surface, positive = outside
#
# CSG operations combine two SDFs:
#   union:        min(sdf_a, sdf_b)
#   intersection: max(sdf_a, sdf_b)
#   difference:   max(sdf_a, -sdf_b)
#
# All operations are non-mutating: they collect active voxel coords from both
# grids, evaluate the CSG combinator at each coord, and build a fresh grid.

"""
    csg_union(a::Grid{T}, b::Grid{T}) where T -> Grid{T}

CSG union of two level set grids: the combined surface encloses any point
that is inside *either* `a` or `b`.

At each voxel coordinate the result is `min(sdf_a, sdf_b)`.
"""
function csg_union(a::Grid{T}, b::Grid{T})::Grid{T} where T
    _csg_combine(a, b, min)
end

"""
    csg_intersection(a::Grid{T}, b::Grid{T}) where T -> Grid{T}

CSG intersection of two level set grids: the combined surface encloses only
points that are inside *both* `a` and `b`.

At each voxel coordinate the result is `max(sdf_a, sdf_b)`.
"""
function csg_intersection(a::Grid{T}, b::Grid{T})::Grid{T} where T
    _csg_combine(a, b, max)
end

"""
    csg_difference(a::Grid{T}, b::Grid{T}) where T -> Grid{T}

CSG difference of two level set grids (`a` minus `b`): the combined surface
encloses points that are inside `a` but *outside* `b`.

At each voxel coordinate the result is `max(sdf_a, -sdf_b)`.
"""
function csg_difference(a::Grid{T}, b::Grid{T})::Grid{T} where T
    _csg_combine(a, b, (va, vb) -> max(va, -vb))
end

# =============================================================================
# Internal implementation
# =============================================================================

"""
    _csg_combine(a::Grid{T}, b::Grid{T}, op) where T -> Grid{T}

Generic CSG combinator.  Collects every active coordinate from both input
grids, evaluates `op(get_value(a, c), get_value(b, c))` at each, and stores
the result when it differs from the background.

The output grid inherits `a`'s name, grid class (forced to `GRID_LEVEL_SET`),
background value, and voxel size.
"""
function _csg_combine(a::Grid{T}, b::Grid{T}, op)::Grid{T} where T
    bg = a.tree.background

    # Collect all active coordinates from both grids, plus 1-voxel dilation
    # to close narrow-band gaps at intersection seams (Museth, ACM TOG 2013 §5.1)
    all_coords = Set{Coord}()
    for (c, _) in active_voxels(a.tree)
        push!(all_coords, c)
        _push_face_neighbors!(all_coords, c)
    end
    for (c, _) in active_voxels(b.tree)
        push!(all_coords, c)
        _push_face_neighbors!(all_coords, c)
    end

    # Evaluate the CSG operation at each coordinate
    result = Dict{Coord, T}()
    for c in all_coords
        va = get_value(a.tree, c)
        vb = get_value(b.tree, c)
        combined = op(va, vb)
        if combined != bg
            result[c] = combined
        end
    end

    vs = _grid_voxel_size(a)
    build_grid(result, bg; name=a.name, grid_class=GRID_LEVEL_SET, voxel_size=vs)
end

@inline function _push_face_neighbors!(s::Set{Coord}, c::Coord)
    push!(s, Coord(c.x + Int32(1), c.y, c.z))
    push!(s, Coord(c.x - Int32(1), c.y, c.z))
    push!(s, Coord(c.x, c.y + Int32(1), c.z))
    push!(s, Coord(c.x, c.y - Int32(1), c.z))
    push!(s, Coord(c.x, c.y, c.z + Int32(1)))
    push!(s, Coord(c.x, c.y, c.z - Int32(1)))
end
