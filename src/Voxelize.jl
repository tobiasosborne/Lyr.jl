# Voxelize.jl - Convert Field Protocol fields to VDB grids
#
# The bridge between continuous physics and discrete rendering.
# Every field must become a VDB grid before Lyr can render it.

"""
    auto_voxel_size(f::AbstractContinuousField) -> Float64

Compute a default voxel size from the field's characteristic scale.
Uses scale / 5.0 to provide ~5 samples per feature.
"""
auto_voxel_size(f::AbstractField) = characteristic_scale(f) / 5.0

"""
    voxelize(f::ScalarField3D; voxel_size, threshold, normalize) -> Grid{Float32}

Sample a scalar field onto a VDB grid by uniform evaluation over the domain.

# Arguments
- `f::ScalarField3D` — The field to voxelize
- `voxel_size::Float64` — World-space voxel size (default: `characteristic_scale / 5`)
- `threshold::Float64` — Values below this (after normalization) are discarded (default: `1e-6`)
- `normalize::Bool` — Normalize values to [0, 1] before thresholding (default: `true`)

# Returns
`Grid{Float32}` — A VDB fog volume grid

# Example
```julia
field = ScalarField3D(
    (x, y, z) -> exp(-(x^2 + y^2 + z^2)),
    BoxDomain((-3.0, -3.0, -3.0), (3.0, 3.0, 3.0)),
    1.0
)
grid = voxelize(field)  # auto voxel_size = 0.2
```
"""
function voxelize(f::ScalarField3D;
                  voxel_size::Float64=auto_voxel_size(f),
                  threshold::Float64=1e-6,
                  normalize::Bool=true,
                  adaptive::Bool=true,
                  block_tolerance::Float64=0.01)
    if adaptive
        _voxelize_adaptive(f; voxel_size=voxel_size, threshold=threshold,
                           normalize=normalize, block_tolerance=block_tolerance)
    else
        _voxelize_uniform(f; voxel_size=voxel_size, threshold=threshold,
                          normalize=normalize)
    end
end

function _voxelize_uniform(f::ScalarField3D;
                           voxel_size::Float64=auto_voxel_size(f),
                           threshold::Float64=1e-6,
                           normalize::Bool=true)
    dom = domain(f)
    inv_vs = 1.0 / voxel_size

    imin = floor(Int32, dom.min[1] * inv_vs)
    jmin = floor(Int32, dom.min[2] * inv_vs)
    kmin = floor(Int32, dom.min[3] * inv_vs)
    imax = ceil(Int32, dom.max[1] * inv_vs)
    jmax = ceil(Int32, dom.max[2] * inv_vs)
    kmax = ceil(Int32, dom.max[3] * inv_vs)

    data = Dict{Coord, Float32}()
    max_val = 0.0

    for iz in kmin:kmax, iy in jmin:jmax, ix in imin:imax
        x = Float64(ix) * voxel_size
        y = Float64(iy) * voxel_size
        z = Float64(iz) * voxel_size
        val = evaluate(f, x, y, z)
        if abs(val) > 0.0
            data[coord(ix, iy, iz)] = Float32(val)
            abs_val = abs(val)
            abs_val > max_val && (max_val = abs_val)
        end
    end

    if normalize && max_val > 0.0
        _normalize_and_threshold!(data, max_val, threshold)
    elseif !normalize && threshold > 0.0
        _apply_threshold!(data, threshold)
    end

    build_grid(data, 0.0f0; name="density",
               grid_class=GRID_FOG_VOLUME, voxel_size=voxel_size)
end

"""
    _voxelize_adaptive(f; voxel_size, threshold, normalize, block_tolerance)

Adaptive voxelization: divide domain into 8³ blocks (VDB leaf size),
sample corners to estimate variation, only fill leaves where the field
has significant structure. Skips near-constant regions entirely.

`block_tolerance` controls the relative variation threshold — blocks where
`(max - min) / global_max < block_tolerance` are skipped.
"""
function _voxelize_adaptive(f::ScalarField3D;
                            voxel_size::Float64=auto_voxel_size(f),
                            threshold::Float64=1e-6,
                            normalize::Bool=true,
                            block_tolerance::Float64=0.01)
    dom = domain(f)
    inv_vs = 1.0 / voxel_size
    B = Int32(8)  # block size = VDB leaf dimension

    # Domain bounds in index space, aligned to block boundaries
    imin = fld(floor(Int32, dom.min[1] * inv_vs), B) * B
    jmin = fld(floor(Int32, dom.min[2] * inv_vs), B) * B
    kmin = fld(floor(Int32, dom.min[3] * inv_vs), B) * B
    imax = cld(ceil(Int32, dom.max[1] * inv_vs), B) * B
    jmax = cld(ceil(Int32, dom.max[2] * inv_vs), B) * B
    kmax = cld(ceil(Int32, dom.max[3] * inv_vs), B) * B

    # Pass 1: sample block corners to find global max and identify active blocks
    global_max = 0.0
    corner_cache = Dict{NTuple{3,Int32}, Float64}()

    function _sample_corner(ix, iy, iz)
        key = (ix, iy, iz)
        get!(corner_cache, key) do
            evaluate(f, Float64(ix) * voxel_size, Float64(iy) * voxel_size, Float64(iz) * voxel_size)
        end
    end

    # Collect block info: (block_origin, corner_min, corner_max)
    blocks = NTuple{3,Int32}[]
    block_ranges = Float64[]  # max - min per block

    for bz in kmin:B:kmax-1, by in jmin:B:jmax-1, bx in imin:B:imax-1
        # Sample 8 corners of this block
        cmin = Inf; cmax = -Inf
        for dz in (Int32(0), B), dy in (Int32(0), B), dx in (Int32(0), B)
            v = _sample_corner(bx + dx, by + dy, bz + dz)
            v < cmin && (cmin = v)
            v > cmax && (cmax = v)
        end
        amax = max(abs(cmin), abs(cmax))
        amax > global_max && (global_max = amax)
        push!(blocks, (bx, by, bz))
        push!(block_ranges, cmax - cmin)
    end

    global_max == 0.0 && return build_grid(Dict{Coord,Float32}(), 0.0f0;
                                           name="density", grid_class=GRID_FOG_VOLUME, voxel_size=voxel_size)

    # Pass 2: only fill blocks with significant variation
    abs_tol = block_tolerance * global_max
    data = Dict{Coord, Float32}()
    max_val = 0.0

    for (idx, (bx, by, bz)) in enumerate(blocks)
        # Skip blocks where field is near-zero AND near-constant
        block_range = block_ranges[idx]

        # Check if any corner has significant value
        any_significant = false
        for dz in (Int32(0), B), dy in (Int32(0), B), dx in (Int32(0), B)
            if abs(_sample_corner(bx + dx, by + dy, bz + dz)) > abs_tol
                any_significant = true
                break
            end
        end
        !any_significant && block_range < abs_tol && continue

        # Fill this leaf at full resolution
        for iz in bz:(bz+B-Int32(1)), iy in by:(by+B-Int32(1)), ix in bx:(bx+B-Int32(1))
            x = Float64(ix) * voxel_size
            y = Float64(iy) * voxel_size
            z = Float64(iz) * voxel_size
            val = evaluate(f, x, y, z)
            if abs(val) > 0.0
                data[coord(ix, iy, iz)] = Float32(val)
                abs_val = abs(val)
                abs_val > max_val && (max_val = abs_val)
            end
        end
    end

    if normalize && max_val > 0.0
        _normalize_and_threshold!(data, max_val, threshold)
    elseif !normalize && threshold > 0.0
        _apply_threshold!(data, threshold)
    end

    build_grid(data, 0.0f0; name="density",
               grid_class=GRID_FOG_VOLUME, voxel_size=voxel_size)
end

"""
    voxelize(f::VectorField3D; kwargs...) -> Grid{Float32}

Voxelize a vector field by computing its magnitude |v| at each point.

All keyword arguments are forwarded to the scalar `voxelize`.
"""
function voxelize(f::VectorField3D; kwargs...)
    mag_fn = (x, y, z) -> begin
        v = evaluate(f, x, y, z)
        norm(v)
    end
    scalar_f = ScalarField3D(mag_fn, domain(f), characteristic_scale(f))
    voxelize(scalar_f; kwargs...)
end

"""
    voxelize(f::ComplexScalarField3D; kwargs...) -> Grid{Float32}

Voxelize a complex scalar field by computing the probability density |ψ|².

This is the natural reduction for quantum mechanical wavefunctions.
All keyword arguments are forwarded to the scalar `voxelize`.
"""
function voxelize(f::ComplexScalarField3D; kwargs...)
    abs2_fn = (x, y, z) -> abs2(evaluate(f, x, y, z))
    scalar_f = ScalarField3D(abs2_fn, domain(f), characteristic_scale(f))
    voxelize(scalar_f; kwargs...)
end

"""
    voxelize(f::ParticleField; voxel_size, mode, sigma, cutoff_sigma, half_width, normalize, threshold) -> Grid{Float32}

Voxelize particles via Gaussian splatting (fog mode) or as a level set SDF (levelset mode).

# Mode selection
- `:auto` (default) — if `f.properties` contains `:radii`, produces a level set; otherwise fog
- `:fog` — Gaussian splatting density field
- `:levelset` — CSG union of sphere SDFs via `particles_to_sdf`

# Arguments
- `f::ParticleField` — Particle data
- `voxel_size::Float64` — World-space voxel size (default: `characteristic_scale / 5`)
- `mode::Symbol` — `:auto`, `:fog`, or `:levelset` (default: `:auto`)
- `sigma::Float64` — Gaussian standard deviation in world units, fog mode only (default: `2.0`)
- `cutoff_sigma::Float64` — Kernel extent in sigma units, fog mode only (default: `3.0`)
- `half_width::Float64` — Narrow band half-width in voxels, levelset mode only (default: `3.0`)
- `normalize::Bool` — Normalize to [0, 1], fog mode only (default: `true`)
- `threshold::Float64` — Discard values below this, fog mode only (default: `1e-6`)

# Examples
```julia
# Fog mode (no radii)
pos = [SVec3d(randn(3)...) for _ in 1:500]
field = ParticleField(pos)
grid = voxelize(field; voxel_size=0.5, sigma=1.0)

# Level set mode (with radii)
pos = [SVec3d(0.0, 0.0, 0.0), SVec3d(10.0, 0.0, 0.0)]
props = Dict{Symbol, Vector}(:radii => [3.0, 3.0])
field = ParticleField(pos; properties=props)
grid = voxelize(field; voxel_size=0.5)  # auto-detects :levelset
```
"""
function voxelize(f::ParticleField;
                  voxel_size::Float64=auto_voxel_size(f),
                  mode::Symbol=:auto,
                  sigma::Float64=2.0,
                  cutoff_sigma::Float64=3.0,
                  half_width::Float64=3.0,
                  normalize::Bool=true,
                  threshold::Float64=1e-6)
    # Auto-detect mode based on whether radii are present
    actual_mode = mode
    if mode === :auto
        actual_mode = haskey(f.properties, :radii) ? :levelset : :fog
    end

    if actual_mode === :levelset
        # Level set mode: CSG union of sphere SDFs
        radii = get(f.properties, :radii, 1.0)
        return particles_to_sdf(f.positions, radii;
                                voxel_size=voxel_size, half_width=half_width)
    end

    # Fog mode: Gaussian splatting (existing behavior, unchanged)
    density = gaussian_splat(f.positions;
                             voxel_size=voxel_size,
                             sigma=sigma,
                             cutoff_sigma=cutoff_sigma)

    if normalize && !isempty(density)
        max_val = Float64(maximum(values(density)))
        if max_val > 0.0
            _normalize_and_threshold!(density, max_val, threshold)
        end
    end

    build_grid(density, 0.0f0; name="particles",
               grid_class=GRID_FOG_VOLUME, voxel_size=voxel_size)
end

# ============================================================================
# Internal helpers
# ============================================================================

"""
    _normalize_and_threshold!(data, max_val, threshold)

Normalize all values in `data` to [0, 1] by dividing by `max_val`, then
delete entries below `threshold`. Operates in-place on the Dict.
"""
function _normalize_and_threshold!(data::Dict{Coord, Float32},
                                    max_val::Float64, threshold::Float64)
    inv_max = Float32(1.0 / max_val)
    thresh = Float32(threshold)
    to_delete = Coord[]
    for (k, v) in data
        nv = v * inv_max
        if abs(nv) < thresh
            push!(to_delete, k)
        else
            data[k] = nv
        end
    end
    for k in to_delete
        delete!(data, k)
    end
    data
end

"""
    _apply_threshold!(data, threshold)

Delete entries from `data` whose absolute value is below `threshold`. In-place.
"""
function _apply_threshold!(data::Dict{Coord, Float32}, threshold::Float64)
    thresh = Float32(threshold)
    to_delete = Coord[]
    for (k, v) in data
        if abs(v) < thresh
            push!(to_delete, k)
        end
    end
    for k in to_delete
        delete!(data, k)
    end
    data
end

# ============================================================================
# TimeEvolution support
# ============================================================================

"""
    voxelize(te::TimeEvolution; t=te.t_range[1], kwargs...) -> Grid{Float32}

Snapshot a time-evolving field at time `t` and voxelize it.
"""
function voxelize(te::TimeEvolution; t::Float64=te.t_range[1], kwargs...)
    voxelize(te.eval_fn(t); kwargs...)
end
