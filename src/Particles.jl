# Particles.jl - Particle-to-volume conversion
#
# gaussian_splat:   particles → fog density (additive Gaussian kernels)
# particles_to_sdf: particles → level set SDF (CSG union of spheres via min)

"""
    gaussian_splat(positions;
                   voxel_size::Float64=1.0,
                   sigma::Float64=2.0,
                   cutoff_sigma::Float64=3.0,
                   values::Union{Nothing, AbstractVector}=nothing
                   ) -> Dict{Coord, Float32}

Convert particle positions into a smooth density field via Gaussian kernel splatting.

Each particle deposits a normalized Gaussian kernel onto the surrounding voxels.
If `values` is provided, computes a density-weighted average of particle values
instead of additive density.

# Arguments
- `positions`: vector of particle positions (anything indexable with `[1]`, `[2]`, `[3]`)
- `voxel_size`: size of each voxel in world units (default 1.0)
- `sigma`: Gaussian standard deviation in world units (default 2.0)
- `cutoff_sigma`: number of sigma to extend the kernel (default 3.0)
- `values`: optional per-particle scalar values for weighted averaging
"""
function gaussian_splat(positions::AbstractVector;
                        voxel_size::Float64=1.0,
                        sigma::Float64=2.0,
                        cutoff_sigma::Float64=3.0,
                        values::Union{Nothing, AbstractVector}=nothing)
    inv_vs = 1.0 / voxel_size
    inv_2sigma2 = 1.0 / (2.0 * sigma * sigma)
    r = ceil(Int, cutoff_sigma * sigma * inv_vs)

    # Thread-local dictionaries for parallel accumulation
    # Use Threads.maxthreadid() to handle Julia's dynamic thread pool
    nt = Threads.maxthreadid()
    local_dicts = [Dict{Coord, Float32}() for _ in 1:nt]

    Threads.@threads for pi in 1:length(positions)
        pos = positions[pi]
        d = local_dicts[Threads.threadid()]

        # Center voxel in index space
        cx = round(Int32, pos[1] * inv_vs)
        cy = round(Int32, pos[2] * inv_vs)
        cz = round(Int32, pos[3] * inv_vs)

        w = values === nothing ? 1.0 : Float64(values[pi])

        for dx in -r:r, dy in -r:r, dz in -r:r
            # World-space distance from particle to voxel center
            vx = (cx + dx) * voxel_size
            vy = (cy + dy) * voxel_size
            vz = (cz + dz) * voxel_size
            ddx = Float64(pos[1]) - vx
            ddy = Float64(pos[2]) - vy
            ddz = Float64(pos[3]) - vz
            dist2 = ddx*ddx + ddy*ddy + ddz*ddz
            weight = exp(-dist2 * inv_2sigma2)

            c = Coord(cx + Int32(dx), cy + Int32(dy), cz + Int32(dz))
            d[c] = get(d, c, 0f0) + Float32(w * weight)
        end
    end

    # Merge thread-local dicts
    result = local_dicts[1]
    for i in 2:nt
        for (c, v) in local_dicts[i]
            result[c] = get(result, c, 0f0) + v
        end
    end
    result
end

"""
    particles_to_sdf(positions, radii;
                     voxel_size=1.0, half_width=3.0) -> Grid{Float32}

Convert particles to a level set SDF via CSG union of sphere SDFs.
Each particle generates a sphere SDF; overlapping spheres merge via `min`
(the level set union operator). Only narrow-band voxels are stored.

# Arguments
- `positions`: vector of positions (anything indexable with `[1]`, `[2]`, `[3]`)
- `radii`: scalar (uniform) or vector (per-particle) radii in world units
- `voxel_size`: voxel edge length (default 1.0)
- `half_width`: narrow band half-width in voxels (default 3.0)

# Example
```julia
pos = [(0.0, 0.0, 0.0), (5.0, 0.0, 0.0)]
grid = particles_to_sdf(pos, 3.0; voxel_size=0.5)
```
"""
function particles_to_sdf(positions::AbstractVector, radii;
                           voxel_size::Float64=1.0,
                           half_width::Float64=3.0)
    bg = Float32(half_width * voxel_size)
    inv_vs = 1.0 / voxel_size

    # Thread-local dicts for parallel accumulation (min is associative)
    nt = Threads.maxthreadid()
    local_dicts = [Dict{Coord, Float32}() for _ in 1:nt]

    Threads.@threads for pi in 1:length(positions)
        pos = positions[pi]
        d = local_dicts[Threads.threadid()]
        r = radii isa Number ? Float64(radii) : Float64(radii[pi])

        # Narrow band extent in index space
        band = half_width * voxel_size
        extent = ceil(Int, (r + band) * inv_vs)

        # Particle center in index space
        cx = round(Int32, Float64(pos[1]) * inv_vs)
        cy = round(Int32, Float64(pos[2]) * inv_vs)
        cz = round(Int32, Float64(pos[3]) * inv_vs)

        for dx in -extent:extent, dy in -extent:extent, dz in -extent:extent
            # World-space distance from particle center to voxel center
            vx = Float64(cx + dx) * voxel_size
            vy = Float64(cy + dy) * voxel_size
            vz = Float64(cz + dz) * voxel_size
            dist = sqrt((Float64(pos[1]) - vx)^2 +
                        (Float64(pos[2]) - vy)^2 +
                        (Float64(pos[3]) - vz)^2)
            sdf = Float32(dist - r)

            # Only store within narrow band
            abs(sdf) > bg && continue

            c = Coord(cx + Int32(dx), cy + Int32(dy), cz + Int32(dz))
            d[c] = min(get(d, c, bg), sdf)
        end
    end

    # Merge: min across thread-local dicts
    result = local_dicts[1]
    for i in 2:nt
        for (c, v) in local_dicts[i]
            result[c] = min(get(result, c, bg), v)
        end
    end

    build_grid(result, bg; name="particles_sdf",
               grid_class=GRID_LEVEL_SET, voxel_size=voxel_size)
end
