# FastSweeping.jl - Eikonal reinitialization for level set SDF grids
#
# Implements the Fast Sweeping Method (Zhao 2004) on sparse VDB grids.
# Decouples from the immutable tree during computation: extracts active
# voxels into flat arrays, sweeps with zero-alloc inner loop, rebuilds once.
#
# Usage:
#   grid = create_level_set_sphere(center=(0,0,0), radius=10.0)
#   distorted = ...  # CSG, advection, etc.
#   fixed = reinitialize_sdf(distorted)

# ============================================================================
# Helpers — inlined, zero-allocation
# ============================================================================

"""Neighbor value: index 0 means missing → return background."""
@inline _fs_nbval(vals::Vector{T}, idx::Int32, bg::T) where T =
    idx == Int32(0) ? bg : @inbounds vals[idx]

"""Sort 3 values ascending. 3 comparisons, ≤3 swaps."""
@inline function _fs_sort3(a::T, b::T, c::T) where T
    a > b && ((a, b) = (b, a))
    a > c && ((a, c) = (c, a))
    b > c && ((b, c) = (c, b))
    (a, b, c)
end

"""
Godunov upwind Eikonal solver: 1D → 2D → 3D cascade.

Given the minimum neighbor distances along each axis (a ≤ b ≤ c, pre-sorted)
and the grid spacing h, solve |∇φ| = 1 for the smallest consistent φ.
"""
@inline function _fs_solve_eikonal(a::T, b::T, c::T, h::T)::T where T
    h2 = h * h
    # 1D: u = a + h
    u = a + h
    u <= b && return u
    # 2D: (u-a)² + (u-b)² = h²
    disc = T(2) * h2 - (a - b)^2
    disc <= zero(T) && return u
    u = (a + b + sqrt(disc)) * T(0.5)
    u <= c && return u
    # 3D: (u-a)² + (u-b)² + (u-c)² = h²
    disc = T(3) * h2 - ((a - b)^2 + (a - c)^2 + (b - c)^2)
    disc <= zero(T) && return u
    (a + b + c + sqrt(disc)) / T(3)
end

"""Single voxel sweep update. Zero allocation, pure array arithmetic."""
@inline function _fs_sweep_update!(vals::Vector{T}, nbrs::Vector{NTuple{6,Int32}},
                                   frozen::BitVector, bg::T, i::Int, h::T) where T
    @inbounds begin
        frozen[i] && return
        nb = nbrs[i]
        a = min(_fs_nbval(vals, nb[1], bg), _fs_nbval(vals, nb[2], bg))
        b = min(_fs_nbval(vals, nb[3], bg), _fs_nbval(vals, nb[4], bg))
        c = min(_fs_nbval(vals, nb[5], bg), _fs_nbval(vals, nb[6], bg))
        a, b, c = _fs_sort3(a, b, c)
        u = _fs_solve_eikonal(a, b, c, h)
        u < vals[i] && (vals[i] = u)
    end
end

# ============================================================================
# Public API
# ============================================================================

"""
    reinitialize_sdf(grid::Grid{T}; iterations::Int=2) -> Grid{T}

Recompute signed distances for a level set grid by solving the Eikonal
equation |∇φ| = 1 via the Fast Sweeping Method (Zhao 2004).

Use this after CSG operations, advection, or any transformation that
distorts the distance field. The output satisfies |∇φ| ≈ 1 everywhere
in the narrow band, with the same sign (inside/outside topology) as
the input.

# Arguments
- `grid::Grid{T}` — input level set grid (background > 0)
- `iterations::Int` — number of full sweep passes (default: 2, each = 8 sweeps)

# Example
```julia
a = create_level_set_sphere(center=(0,0,0), radius=10.0)
b = create_level_set_sphere(center=(8,0,0), radius=10.0)
merged = csg_union(a, b)            # SDF distorted by min()
fixed  = reinitialize_sdf(merged)   # |∇φ| = 1 restored
```
"""
function reinitialize_sdf(grid::Grid{T}; iterations::Int=2) where {T <: AbstractFloat}
    bg = grid.tree.background
    h = T(_grid_voxel_size(grid))

    # --- Phase A: Extract active voxels into flat arrays ---
    n = active_voxel_count(grid.tree)
    n == 0 && return grid

    coords = Vector{Coord}(undef, n)
    input_vals = Vector{T}(undef, n)
    k = 0
    for (c, v) in active_voxels(grid.tree)
        k += 1
        coords[k] = c
        input_vals[k] = v
    end

    # --- Phase B: Build dense index + precompute neighbors ---
    coord_to_idx = Dict{Coord, Int32}()
    sizehint!(coord_to_idx, n)
    for i in 1:n
        coord_to_idx[coords[i]] = Int32(i)
    end

    nbrs = Vector{NTuple{6,Int32}}(undef, n)
    @inbounds for i in 1:n
        c = coords[i]
        ix, iy, iz = c.x, c.y, c.z
        nbrs[i] = (
            get(coord_to_idx, Coord(ix - Int32(1), iy, iz), Int32(0)),
            get(coord_to_idx, Coord(ix + Int32(1), iy, iz), Int32(0)),
            get(coord_to_idx, Coord(ix, iy - Int32(1), iz), Int32(0)),
            get(coord_to_idx, Coord(ix, iy + Int32(1), iz), Int32(0)),
            get(coord_to_idx, Coord(ix, iy, iz - Int32(1)), Int32(0)),
            get(coord_to_idx, Coord(ix, iy, iz + Int32(1)), Int32(0)),
        )
    end

    # --- Phase C: Detect interface + initialize ---
    signs = Vector{T}(undef, n)
    vals = Vector{T}(undef, n)
    frozen = falses(n)
    big_val = T(10) * bg  # large sentinel (finite, avoids Inf issues)

    @inbounds for i in 1:n
        v = input_vals[i]
        signs[i] = v >= zero(T) ? one(T) : -one(T)
        abs_v = abs(v)

        # Check 6 face neighbors for sign change (active neighbors only)
        min_dist = big_val
        nb = nbrs[i]
        for ni_idx in 1:6
            ni = nb[ni_idx]
            ni == Int32(0) && continue  # skip missing — bg creates false interfaces
            vn = input_vals[ni]
            if (v > zero(T)) != (vn > zero(T))
                # Linear interpolation to zero-crossing
                dist = abs_v / (abs_v + abs(vn)) * h
                dist < min_dist && (min_dist = dist)
            end
        end

        if min_dist < big_val
            frozen[i] = true
            vals[i] = min_dist
        else
            vals[i] = big_val
        end
    end

    # --- Phase D: Precompute 4 sort orders ---
    perms = (
        sortperm(coords, by=c -> ( Int(c.x),  Int(c.y),  Int(c.z))),
        sortperm(coords, by=c -> ( Int(c.x),  Int(c.y), -Int(c.z))),
        sortperm(coords, by=c -> ( Int(c.x), -Int(c.y),  Int(c.z))),
        sortperm(coords, by=c -> (-Int(c.x),  Int(c.y),  Int(c.z))),
    )

    # --- Phase E: Sweep ---
    for _ in 1:iterations
        for perm in perms
            @inbounds for j in 1:n
                _fs_sweep_update!(vals, nbrs, frozen, bg, perm[j], h)
            end
            @inbounds for j in n:-1:1
                _fs_sweep_update!(vals, nbrs, frozen, bg, perm[j], h)
            end
        end
    end

    # --- Phase F: Apply signs, clamp, rebuild ---
    data = Dict{Coord, T}()
    sizehint!(data, n)
    @inbounds for i in 1:n
        data[coords[i]] = signs[i] * min(vals[i], bg)
    end

    build_grid(data, bg; name=grid.name, grid_class=GRID_LEVEL_SET,
               voxel_size=_grid_voxel_size(grid))
end
