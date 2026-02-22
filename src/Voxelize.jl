# Voxelize.jl - Convert Field Protocol fields to VDB grids
#
# The bridge between continuous physics and discrete rendering.
# Every field must become a VDB grid before Lyr can render it.

"""
    auto_voxel_size(f::AbstractContinuousField) -> Float64

Compute a default voxel size from the field's characteristic scale.
Uses scale / 5.0 to provide ~5 samples per feature.
"""
auto_voxel_size(f::AbstractContinuousField) = characteristic_scale(f) / 5.0

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
    voxelize(f::VectorField3D; kwargs...) -> Grid{Float32}

Voxelize a vector field by computing its magnitude |v| at each point.

All keyword arguments are forwarded to the scalar `voxelize`.
"""
function voxelize(f::VectorField3D; kwargs...)
    mag_fn = (x, y, z) -> begin
        v = evaluate(f, x, y, z)
        sqrt(v[1]^2 + v[2]^2 + v[3]^2)
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
    voxelize(f::ParticleField; voxel_size, sigma, cutoff_sigma, normalize, threshold) -> Grid{Float32}

Voxelize particles via Gaussian splatting. Each particle contributes a Gaussian
kernel to the density field.

# Arguments
- `f::ParticleField` — Particle data
- `voxel_size::Float64` — World-space voxel size (default: `1.0`)
- `sigma::Float64` — Gaussian standard deviation in world units (default: `2.0`)
- `cutoff_sigma::Float64` — Kernel extent in sigma units (default: `3.0`)
- `normalize::Bool` — Normalize to [0, 1] (default: `true`)
- `threshold::Float64` — Discard values below this (default: `1e-6`)

# Example
```julia
pos = [SVec3d(randn(3)...) for _ in 1:500]
field = ParticleField(pos)
grid = voxelize(field; voxel_size=0.5, sigma=1.0)
```
"""
function voxelize(f::ParticleField;
                  voxel_size::Float64=1.0,
                  sigma::Float64=2.0,
                  cutoff_sigma::Float64=3.0,
                  normalize::Bool=true,
                  threshold::Float64=1e-6)
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
