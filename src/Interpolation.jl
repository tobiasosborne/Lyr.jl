# Interpolation.jl — Sampling, gradient computation, and grid resampling

# --- Interpolation method types ---

"""
    InterpolationMethod

Abstract type for grid sampling strategies.
Concrete subtypes: [`NearestInterpolation`](@ref), [`TrilinearInterpolation`](@ref).
"""
abstract type InterpolationMethod end

"""Nearest-neighbor sampling — snaps to closest voxel center."""
struct NearestInterpolation  <: InterpolationMethod end

"""Trilinear sampling — linearly interpolates the 8 surrounding voxels."""
struct TrilinearInterpolation <: InterpolationMethod end

"""Quadratic B-spline sampling — smooth interpolation using the 27 surrounding voxels."""
struct QuadraticInterpolation <: InterpolationMethod end

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
    sample_world(grid, xyz, [method]) -> T

Sample the grid at world coordinates using the given [`InterpolationMethod`](@ref).
Defaults to [`TrilinearInterpolation`](@ref).
"""
sample_world(grid::Grid{T}, xyz::SVec3d, ::NearestInterpolation) where T =
    sample_nearest(grid.tree, world_to_index_float(grid.transform, xyz))

sample_world(grid::Grid{T}, xyz::SVec3d, ::TrilinearInterpolation) where T =
    sample_trilinear(grid.tree, world_to_index_float(grid.transform, xyz))

sample_world(grid::Grid{T}, xyz::SVec3d, ::QuadraticInterpolation) where T =
    sample_quadratic(grid.tree, world_to_index_float(grid.transform, xyz))

sample_world(grid::Grid{T}, xyz::SVec3d) where T =
    sample_world(grid, xyz, TrilinearInterpolation())

# --- NTuple convenience wrappers ---

"NTuple convenience wrapper: converts to SVec3d and delegates."
sample_nearest(tree::Tree{T}, ijk::NTuple{3, Float64}) where T =
    sample_nearest(tree, SVec3d(ijk...))

"NTuple convenience wrapper: converts to SVec3d and delegates."
sample_trilinear(tree::Tree{T}, ijk::NTuple{3, Float64}) where T =
    sample_trilinear(tree, SVec3d(ijk...))

"NTuple convenience wrapper: converts to SVec3d and delegates."
sample_quadratic(tree::Tree{T}, ijk::NTuple{3, Float64}) where T =
    sample_quadratic(tree, SVec3d(ijk...))

"NTuple convenience wrapper: converts to SVec3d and delegates."
sample_world(grid::Grid{T}, xyz::NTuple{3, Float64}, method::InterpolationMethod) where T =
    sample_world(grid, SVec3d(xyz...), method)

"NTuple convenience wrapper: converts to SVec3d and delegates."
sample_world(grid::Grid{T}, xyz::NTuple{3, Float64}) where T =
    sample_world(grid, SVec3d(xyz...), TrilinearInterpolation())

# --- Quadratic B-spline sampling ---

"""
    sample_quadratic(tree::Tree{T}, ijk::SVec3d) -> T

Sample the tree using quadratic B-spline interpolation (27-point stencil).
Smoother than trilinear with C1 continuity. Falls back to nearest-neighbor
at narrow band boundaries (where any of the 27 values equals ±background).
"""
function sample_quadratic(tree::Tree{T}, ijk::SVec3d)::T where T
    sample_quadratic(ValueAccessor(tree), tree.background, ijk)
end

"""
    sample_quadratic(acc, bg, ijk) -> T

Quadratic B-spline sampling with pre-existing accessor (avoids allocation per call).
"""
function sample_quadratic(acc::ValueAccessor{T}, bg::T, ijk::SVec3d)::T where T
    # Nearest grid point and fractional offsets ∈ [-0.5, 0.5]
    i0 = round(Int64, ijk[1])
    j0 = round(Int64, ijk[2])
    k0 = round(Int64, ijk[3])
    u = T(ijk[1] - Float64(i0))
    v = T(ijk[2] - Float64(j0))
    w = T(ijk[3] - Float64(k0))

    # Quadratic B-spline weights per axis
    wx = _quad_weights(u)
    wy = _quad_weights(v)
    wz = _quad_weights(w)
    result = zero(T)
    for di in -1:1
        for dj in -1:1
            for dk in -1:1
                val = get_value(acc, coord(i0 + di, j0 + dj, k0 + dk))
                _is_background(val, bg) && return get_value(acc, coord(round(Int64, ijk[1]), round(Int64, ijk[2]), round(Int64, ijk[3])))
                result += wx[di + 2] * wy[dj + 2] * wz[dk + 2] * val
            end
        end
    end
    result
end

"""Quadratic B-spline weights for offset t ∈ [-0.5, 0.5]. Returns (w₋₁, w₀, w₁)."""
@inline function _quad_weights(t::T) where {T <: AbstractFloat}
    half = T(0.5)
    (half * (half - t)^2,
     T(0.75) - t * t,
     half * (half + t)^2)
end

# --- Resampling ---

"""
    resample_to_match(source::Grid{T}, target::Grid;
                      method=TrilinearInterpolation()) -> Grid{T}

Resample `source` at every active voxel position of `target`. Each target
voxel coordinate is converted to world space via `target`'s transform, then
sampled from `source` using the specified interpolation method.
Returns a new grid with `target`'s transform and topology.
"""
function resample_to_match(source::Grid{T}, target::Grid;
                           method::InterpolationMethod=TrilinearInterpolation()) where T
    data = Dict{Coord, T}()
    bg = source.tree.background
    for (c, _) in active_voxels(target.tree)
        world_xyz = index_to_world(target.transform,
                                   SVec3d(Float64(c.x), Float64(c.y), Float64(c.z)))
        val = sample_world(source, world_xyz, method)
        val != bg && (data[c] = val)
    end
    build_grid(data, bg; name=source.name, grid_class=source.grid_class,
               voxel_size=_grid_voxel_size(target))
end

"""
    resample_to_match(source::Grid{T}; voxel_size::Float64,
                      method=TrilinearInterpolation()) -> Grid{T}

Resample `source` to a new resolution. Iterates over the active bounding box
at the new voxel size and samples the source at each position.
"""
function resample_to_match(source::Grid{T}; voxel_size::Float64,
                           method::InterpolationMethod=TrilinearInterpolation()) where T
    bbox = active_bounding_box(source.tree)
    bbox === nothing && return build_grid(Dict{Coord, T}(), source.tree.background;
                                          name=source.name, voxel_size=voxel_size)
    src_tf = source.transform
    # World-space bounding box
    wmin = index_to_world(src_tf, SVec3d(Float64(bbox.min.x), Float64(bbox.min.y), Float64(bbox.min.z)))
    wmax = index_to_world(src_tf, SVec3d(Float64(bbox.max.x), Float64(bbox.max.y), Float64(bbox.max.z)))

    # Target index-space bounds
    inv_vs = 1.0 / voxel_size
    imin = floor.(Int32, wmin .* inv_vs)
    imax = ceil.(Int32, wmax .* inv_vs)

    tgt_tf = UniformScaleTransform(voxel_size)
    data = Dict{Coord, T}()
    bg = source.tree.background
    for xi in imin[1]:imax[1]
        for yi in imin[2]:imax[2]
            for zi in imin[3]:imax[3]
                world_xyz = SVec3d(Float64(xi), Float64(yi), Float64(zi)) .* voxel_size
                val = sample_world(source, world_xyz, method)
                val != bg && (data[coord(xi, yi, zi)] = val)
            end
        end
    end
    build_grid(data, bg; name=source.name, grid_class=source.grid_class,
               voxel_size=voxel_size)
end

# --- Internal helpers (unchanged) ---

"Check if a scalar value equals +background or -background (narrow band boundary detection)."
_is_background(val::T, bg::T) where {T <: AbstractFloat} = (val == bg) || (val == -bg)

"Check if a vector value equals the background tuple."
_is_background(val::NTuple{N,T}, bg::NTuple{N,T}) where {N, T <: AbstractFloat} = (val == bg)

"Trilinear interpolation of 8 corner scalar values with fractional offsets (u, v, w)."
function _lerp3(v000::T, v100::T, v010::T, v110::T, v001::T, v101::T, v011::T, v111::T, u::T, v::T, w::T)::T where T <: AbstractFloat
    c00 = v000 * (1 - u) + v100 * u
    c10 = v010 * (1 - u) + v110 * u
    c01 = v001 * (1 - u) + v101 * u
    c11 = v011 * (1 - u) + v111 * u

    c0 = c00 * (1 - v) + c10 * v
    c1 = c01 * (1 - v) + c11 * v

    c0 * (1 - w) + c1 * w
end

"Trilinear interpolation of 8 corner vector values, applied component-wise."
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

"""
    gradient(tree::Tree{NTuple{N,T}}, c::Coord) -> NTuple{3, NTuple{N,T}}

Compute the gradient of a vector field at coordinate `c` using central differences.
Returns 3 component-wise derivative vectors (d/dx, d/dy, d/dz).
"""
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
