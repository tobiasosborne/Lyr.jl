# LevelSetPrimitives.jl - Generate level set grids from analytic SDF primitives
#
# Level sets store signed distance field (SDF) values in a narrow band around
# the surface. Negative = inside, zero = on surface, positive = outside.
# Only voxels within half_width * voxel_size of the surface are stored;
# everything else returns the background value (half_width * voxel_size).

"""
    create_level_set_sphere(; center, radius, voxel_size=1.0, half_width=3.0,
                              name="level_set") -> Grid{Float32}

Create a VDB level set grid representing a sphere.

The grid stores signed distance values in a narrow band of `half_width` voxels
around the sphere surface. Voxels outside the band are implicit (background).

# Arguments
- `center::NTuple{3,Float64}` — sphere center in world space
- `radius::Float64` — sphere radius in world space
- `voxel_size::Float64` — size of each voxel (default: `1.0`)
- `half_width::Float64` — narrow band width in voxels (default: `3.0`)
- `name::String` — grid name (default: `"level_set"`)

# Returns
`Grid{Float32}` with `grid_class == GRID_LEVEL_SET`

# Example
```julia
grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0)
```
"""
function create_level_set_sphere(; center::NTuple{3,Float64},
                                   radius::Float64,
                                   voxel_size::Float64=1.0,
                                   half_width::Float64=3.0,
                                   name::String="level_set")
    inv_vs = 1.0 / voxel_size
    band = half_width * voxel_size
    background = Float32(band)

    # Bounding box in index space: center/voxel_size +/- (radius/voxel_size + half_width)
    cx, cy, cz = center
    extent = radius * inv_vs + half_width
    imin = floor(Int32, cx * inv_vs - extent)
    jmin = floor(Int32, cy * inv_vs - extent)
    kmin = floor(Int32, cz * inv_vs - extent)
    imax = ceil(Int32, cx * inv_vs + extent)
    jmax = ceil(Int32, cy * inv_vs + extent)
    kmax = ceil(Int32, cz * inv_vs + extent)

    data = Dict{Coord, Float32}()

    for iz in kmin:kmax, iy in jmin:jmax, ix in imin:imax
        wx = Float64(ix) * voxel_size
        wy = Float64(iy) * voxel_size
        wz = Float64(iz) * voxel_size
        sdf = sqrt((wx - cx)^2 + (wy - cy)^2 + (wz - cz)^2) - radius
        if abs(sdf) < band
            data[coord(ix, iy, iz)] = Float32(sdf)
        end
    end

    build_grid(data, background; name=name, grid_class=GRID_LEVEL_SET,
               voxel_size=voxel_size)
end

"""
    create_level_set_box(; min_corner, max_corner, voxel_size=1.0, half_width=3.0,
                           name="level_set") -> Grid{Float32}

Create a VDB level set grid representing an axis-aligned box.

The grid stores signed distance values in a narrow band of `half_width` voxels
around the box surface. Uses the standard box SDF formula with exact Euclidean
distance at corners and edges.

# Arguments
- `min_corner::NTuple{3,Float64}` — minimum corner in world space
- `max_corner::NTuple{3,Float64}` — maximum corner in world space
- `voxel_size::Float64` — size of each voxel (default: `1.0`)
- `half_width::Float64` — narrow band width in voxels (default: `3.0`)
- `name::String` — grid name (default: `"level_set"`)

# Returns
`Grid{Float32}` with `grid_class == GRID_LEVEL_SET`

# Example
```julia
grid = create_level_set_box(min_corner=(-5.0, -5.0, -5.0),
                            max_corner=(5.0, 5.0, 5.0))
```
"""
function create_level_set_box(; min_corner::NTuple{3,Float64},
                                max_corner::NTuple{3,Float64},
                                voxel_size::Float64=1.0,
                                half_width::Float64=3.0,
                                name::String="level_set")
    inv_vs = 1.0 / voxel_size
    band = half_width * voxel_size
    background = Float32(band)

    lo_x, lo_y, lo_z = min_corner
    hi_x, hi_y, hi_z = max_corner

    # Bounding box in index space: expand box bounds by half_width voxels
    imin = floor(Int32, lo_x * inv_vs - half_width)
    jmin = floor(Int32, lo_y * inv_vs - half_width)
    kmin = floor(Int32, lo_z * inv_vs - half_width)
    imax = ceil(Int32, hi_x * inv_vs + half_width)
    jmax = ceil(Int32, hi_y * inv_vs + half_width)
    kmax = ceil(Int32, hi_z * inv_vs + half_width)

    data = Dict{Coord, Float32}()

    for iz in kmin:kmax, iy in jmin:jmax, ix in imin:imax
        wx = Float64(ix) * voxel_size
        wy = Float64(iy) * voxel_size
        wz = Float64(iz) * voxel_size

        # Box SDF: exact Euclidean distance with correct sign
        # d = max(lo - p, p - hi)  component-wise
        dx = max(lo_x - wx, wx - hi_x)
        dy = max(lo_y - wy, wy - hi_y)
        dz = max(lo_z - wz, wz - hi_z)

        # Outside distance: Euclidean distance from clamped components
        outside_dist = sqrt(max(dx, 0.0)^2 + max(dy, 0.0)^2 + max(dz, 0.0)^2)
        # Inside distance: negative penetration depth (max of all components, clamped to 0)
        inside_dist = min(max(dx, dy, dz), 0.0)
        sdf = outside_dist + inside_dist

        if abs(sdf) < band
            data[coord(ix, iy, iz)] = Float32(sdf)
        end
    end

    build_grid(data, background; name=name, grid_class=GRID_LEVEL_SET,
               voxel_size=voxel_size)
end
