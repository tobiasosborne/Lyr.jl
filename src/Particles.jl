# Particles.jl - Particle-to-volume conversion via Gaussian splatting

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
