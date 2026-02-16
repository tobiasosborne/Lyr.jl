# Interpolation.jl - Sampling and gradient computation

# --- SVec3d primary methods ---

"""
    sample_nearest(tree::Tree{T}, ijk::SVec3d) -> T

Sample the tree using nearest-neighbor interpolation.
"""
function sample_nearest(tree::Tree{T}, ijk::SVec3d)::T where T
    c = coord(round(Int32, ijk[1]), round(Int32, ijk[2]), round(Int32, ijk[3]))
    get_value(tree, c)
end

"""
    sample_trilinear(tree::Tree{T}, ijk::SVec3d) -> T

Sample the tree using trilinear interpolation.
"""
function sample_trilinear(tree::Tree{T}, ijk::SVec3d)::T where T
    # Get the base integer coordinates (Int64 to avoid overflow on +1)
    i0 = floor(Int64, ijk[1])
    j0 = floor(Int64, ijk[2])
    k0 = floor(Int64, ijk[3])

    # Fractional parts
    u = ijk[1] - Float64(i0)
    v = ijk[2] - Float64(j0)
    w = ijk[3] - Float64(k0)

    # Sample all 8 corners (coord() safely truncates to Int32)
    v000 = get_value(tree, coord(i0, j0, k0))
    v100 = get_value(tree, coord(i0 + 1, j0, k0))
    v010 = get_value(tree, coord(i0, j0 + 1, k0))
    v110 = get_value(tree, coord(i0 + 1, j0 + 1, k0))
    v001 = get_value(tree, coord(i0, j0, k0 + 1))
    v101 = get_value(tree, coord(i0 + 1, j0, k0 + 1))
    v011 = get_value(tree, coord(i0, j0 + 1, k0 + 1))
    v111 = get_value(tree, coord(i0 + 1, j0 + 1, k0 + 1))

    # Boundary check: if any corner is at ±background, fall back to nearest-neighbor.
    # For level sets, background values indicate outside the narrow band — interpolating
    # these with interior values produces artifacts.
    bg = tree.background
    if _is_background(v000, bg) || _is_background(v100, bg) ||
       _is_background(v010, bg) || _is_background(v110, bg) ||
       _is_background(v001, bg) || _is_background(v101, bg) ||
       _is_background(v011, bg) || _is_background(v111, bg)
        return sample_nearest(tree, ijk)
    end

    # Trilinear interpolation
    _lerp3(v000, v100, v010, v110, v001, v101, v011, v111, T(u), T(v), T(w))
end

"""
    sample_world(grid::Grid{T}, xyz::SVec3d; method::Symbol=:trilinear) -> T

Sample the grid at world coordinates.

# Arguments
- `grid::Grid{T}` - The grid to sample
- `xyz::SVec3d` - World coordinates
- `method::Symbol` - Interpolation method (:nearest or :trilinear)
"""
function sample_world(grid::Grid{T}, xyz::SVec3d; method::Symbol=:trilinear)::T where T
    ijk = world_to_index_float(grid.transform, xyz)

    if method == :nearest
        sample_nearest(grid.tree, ijk)
    else
        sample_trilinear(grid.tree, ijk)
    end
end

# --- NTuple wrappers for backward compatibility ---

sample_nearest(tree::Tree{T}, ijk::NTuple{3, Float64}) where T =
    sample_nearest(tree, SVec3d(ijk...))

sample_trilinear(tree::Tree{T}, ijk::NTuple{3, Float64}) where T =
    sample_trilinear(tree, SVec3d(ijk...))

sample_world(grid::Grid{T}, xyz::NTuple{3, Float64}; method::Symbol=:trilinear) where T =
    sample_world(grid, SVec3d(xyz...); method=method)

# --- Internal helpers (unchanged) ---

# Check if a value equals ±background (for boundary detection)
_is_background(val::T, bg::T) where {T <: AbstractFloat} = (val == bg) || (val == -bg)
_is_background(val::NTuple{N,T}, bg::NTuple{N,T}) where {N, T <: AbstractFloat} = (val == bg)

# Scalar lerp
function _lerp3(v000::T, v100::T, v010::T, v110::T, v001::T, v101::T, v011::T, v111::T, u::T, v::T, w::T)::T where T <: AbstractFloat
    c00 = v000 * (1 - u) + v100 * u
    c10 = v010 * (1 - u) + v110 * u
    c01 = v001 * (1 - u) + v101 * u
    c11 = v011 * (1 - u) + v111 * u

    c0 = c00 * (1 - v) + c10 * v
    c1 = c01 * (1 - v) + c11 * v

    c0 * (1 - w) + c1 * w
end

# Vector lerp
function _lerp3(v000::NTuple{N, T}, v100::NTuple{N, T}, v010::NTuple{N, T}, v110::NTuple{N, T},
                v001::NTuple{N, T}, v101::NTuple{N, T}, v011::NTuple{N, T}, v111::NTuple{N, T},
                u::T, v::T, w::T)::NTuple{N, T} where {N, T <: AbstractFloat}
    ntuple(i -> _lerp3(v000[i], v100[i], v010[i], v110[i], v001[i], v101[i], v011[i], v111[i], u, v, w), Val(N))
end

"""
    gradient(tree::Tree{T}, c::Coord) -> NTuple{3, T}

Compute the gradient at coordinate `c` using central differences.
"""
function gradient(tree::Tree{T}, c::Coord)::NTuple{3, T} where T
    i, j, k = c.x, c.y, c.z

    # Central differences
    dx = (get_value(tree, Coord(i + Int32(1), j, k)) - get_value(tree, Coord(i - Int32(1), j, k))) / T(2)
    dy = (get_value(tree, Coord(i, j + Int32(1), k)) - get_value(tree, Coord(i, j - Int32(1), k))) / T(2)
    dz = (get_value(tree, Coord(i, j, k + Int32(1))) - get_value(tree, Coord(i, j, k - Int32(1)))) / T(2)

    (dx, dy, dz)
end

# Gradient for vector types
function gradient(tree::Tree{NTuple{N, T}}, c::Coord)::NTuple{3, NTuple{N, T}} where {N, T}
    i, j, k = c.x, c.y, c.z

    vxp = get_value(tree, Coord(i + Int32(1), j, k))
    vxm = get_value(tree, Coord(i - Int32(1), j, k))
    vyp = get_value(tree, Coord(i, j + Int32(1), k))
    vym = get_value(tree, Coord(i, j - Int32(1), k))
    vzp = get_value(tree, Coord(i, j, k + Int32(1)))
    vzm = get_value(tree, Coord(i, j, k - Int32(1)))

    dx = ntuple(idx -> (vxp[idx] - vxm[idx]) / T(2), Val(N))
    dy = ntuple(idx -> (vyp[idx] - vym[idx]) / T(2), Val(N))
    dz = ntuple(idx -> (vzp[idx] - vzm[idx]) / T(2), Val(N))

    (dx, dy, dz)
end
