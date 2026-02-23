# Render.jl - Sphere tracing renderer for VDB level sets

using Random: Xoshiro

"""
    Camera

A camera for rendering, defined by position and view parameters.

# Fields
- `position::NTuple{3, Float64}` - Camera position in world space
- `forward::NTuple{3, Float64}` - Forward direction (normalized)
- `right::NTuple{3, Float64}` - Right direction (normalized)
- `up::NTuple{3, Float64}` - Up direction (normalized)
- `fov::Float64` - Field of view in degrees
"""
struct Camera
    position::NTuple{3, Float64}
    forward::NTuple{3, Float64}
    right::NTuple{3, Float64}
    up::NTuple{3, Float64}
    fov::Float64
end

"""
    Camera(position, target, up, fov) -> Camera

Construct a camera looking from `position` toward `target`.

# Arguments
- `position::NTuple{3, Float64}` - Camera position
- `target::NTuple{3, Float64}` - Point to look at
- `up::NTuple{3, Float64}` - World up direction (usually (0, 1, 0))
- `fov::Float64` - Field of view in degrees
"""
function Camera(position::NTuple{3, Float64}, target::NTuple{3, Float64},
                up::NTuple{3, Float64}, fov::Float64)
    # Compute forward direction
    forward = _normalize(_sub(target, position))

    # Compute right = forward × up (then normalize)
    right = _normalize(_cross(forward, up))

    # Compute true up = right × forward
    cam_up = _cross(right, forward)

    Camera(position, forward, right, cam_up, fov)
end

"""
    camera_ray(cam::Camera, u::Float64, v::Float64, aspect::Float64) -> Ray

Generate a ray through pixel coordinates (u, v) where u,v ∈ [0, 1].
"""
function camera_ray(cam::Camera, u::Float64, v::Float64, aspect::Float64)::Ray
    # Convert FOV to radians and compute half-width
    half_fov = tan(deg2rad(cam.fov / 2.0))

    # Map (u, v) from [0,1] to [-1,1]
    px = (2.0 * u - 1.0) * aspect * half_fov
    py = (2.0 * v - 1.0) * half_fov

    # Ray direction in world space
    dir = _add(_add(cam.forward, _scale(cam.right, px)), _scale(cam.up, py))

    Ray(cam.position, dir)
end

"""
    sphere_trace(ray::Ray, grid::Grid{T}, max_steps::Int) -> Union{Tuple{NTuple{3, Float64}, NTuple{3, Float64}}, Nothing}

Find the first surface intersection along a ray through a level set grid.
Returns `(hit_point, normal)` as `NTuple{3,Float64}` tuples, or `nothing`.

Delegates to `find_surface` (DDA + zero-crossing bisection). The `max_steps`
and `world_bounds` parameters are retained for API compatibility but ignored —
DDA terminates by geometry, not by step count.
"""
function sphere_trace(ray::Ray, grid::Grid{T}, max_steps::Int;
                      world_bounds=nothing) where T <: AbstractFloat
    hit = find_surface(ray, grid)
    hit === nothing && return nothing
    (Tuple(hit.position), Tuple(hit.normal))
end

"""
    _intersect_float_bbox(ray::Ray, bmin::NTuple{3,Float64}, bmax::NTuple{3,Float64}) -> Tuple{Float64, Float64}

Ray-box intersection for float bounding box. Returns (t_enter, t_exit).
If no intersection, t_enter > t_exit.
"""
function _intersect_float_bbox(ray::Ray, bmin::NTuple{3,Float64}, bmax::NTuple{3,Float64})
    t1 = (bmin[1] - ray.origin[1]) * ray.inv_dir[1]
    t2 = (bmax[1] - ray.origin[1]) * ray.inv_dir[1]
    tmin = min(t1, t2)
    tmax = max(t1, t2)

    t1 = (bmin[2] - ray.origin[2]) * ray.inv_dir[2]
    t2 = (bmax[2] - ray.origin[2]) * ray.inv_dir[2]
    tmin = max(tmin, min(t1, t2))
    tmax = min(tmax, max(t1, t2))

    t1 = (bmin[3] - ray.origin[3]) * ray.inv_dir[3]
    t2 = (bmax[3] - ray.origin[3]) * ray.inv_dir[3]
    tmin = max(tmin, min(t1, t2))
    tmax = min(tmax, max(t1, t2))

    (tmin, tmax)
end


"""
    _safe_sample(grid::Grid{T}, point::NTuple{3,Float64}, fallback::Float64) -> Float64

Sample grid at point, returning fallback if point is outside bounds or invalid.
"""
function _safe_sample(grid::Grid{T}, point::NTuple{3,Float64}, fallback::Float64)::Float64 where T
    # Check for NaN or Inf values
    if !all(isfinite, point)
        return fallback
    end

    # Check if point is within reasonable world bounds (avoid Int32 overflow)
    max_coord = 1e9
    if any(abs(p) > max_coord for p in point)
        return fallback
    end

    Float64(sample_world(grid, point))
end

"""
    _estimate_normal(grid::Grid{T}, point::NTuple{3, Float64}, h::Float64) -> NTuple{3, Float64}

Estimate surface normal using central differences on the SDF.
"""
function _estimate_normal(grid::Grid{T}, point::NTuple{3, Float64}, h::Float64)::NTuple{3, Float64} where T
    # Central differences
    dx = sample_world(grid, (point[1] + h, point[2], point[3])) -
         sample_world(grid, (point[1] - h, point[2], point[3]))
    dy = sample_world(grid, (point[1], point[2] + h, point[3])) -
         sample_world(grid, (point[1], point[2] - h, point[3]))
    dz = sample_world(grid, (point[1], point[2], point[3] + h)) -
         sample_world(grid, (point[1], point[2], point[3] - h))

    _normalize((Float64(dx), Float64(dy), Float64(dz)))
end

"""
    shade(normal::NTuple{3, Float64}, light_dir::NTuple{3, Float64}) -> Float64

Compute Lambertian shading. Returns a value in [0, 1].

# Arguments
- `normal` - Surface normal (normalized)
- `light_dir` - Direction TO the light (normalized)
"""
function shade(normal::NTuple{3, Float64}, light_dir::NTuple{3, Float64})::Float64
    ambient = 0.2
    diffuse = 0.8

    # Lambertian: max(0, N · L)
    n_dot_l = max(0.0, _dot(normal, light_dir))

    ambient + diffuse * n_dot_l
end

"""
    render_image(grid::Grid{T}, camera::Camera, width::Int, height::Int; kwargs...)

!!! warning "Deprecated"
    `render_image` is deprecated. Use `render_volume_image` (Scene-based volume
    renderer) or `visualize` (one-call field-to-image) instead.

Legacy level-set renderer. Returns a height×width matrix of RGB tuples in [0, 1].
"""
function render_image(grid::Grid{T}, camera::Camera, width::Int, height::Int;
                      light_dir::NTuple{3, Float64}=(0.577, 0.577, 0.577),
                      background::NTuple{3, Float64}=(0.1, 0.1, 0.15),
                      max_steps::Int=200,
                      samples_per_pixel::Int=1,
                      gamma::Float64=1.0,
                      seed::UInt64=UInt64(42)) where T <: AbstractFloat
    Base.depwarn("`render_image` is deprecated, use `render_volume_image` or `visualize` instead.", :render_image)
    aspect = Float64(width) / Float64(height)
    pixels = Matrix{NTuple{3, Float64}}(undef, height, width)

    # Normalize light direction
    light = _normalize(light_dir)

    # Compute stratification grid size
    spp = max(1, samples_per_pixel)
    k = isqrt(spp)  # stratification grid dimension
    if k * k != spp
        k = isqrt(spp) + 1  # round up to next square for non-square spp
    end
    actual_spp = k * k
    inv_spp = 1.0 / actual_spp
    inv_k = 1.0 / k

    # Gamma correction exponent
    inv_gamma = gamma > 0.0 ? 1.0 / gamma : 1.0

    for y in 1:height
        rng = Xoshiro(seed + UInt64(y))
        for x in 1:width
            if actual_spp == 1
                # Fast path: single sample, no jitter
                u = (Float64(x) - 0.5) / Float64(width)
                v = 1.0 - (Float64(y) - 0.5) / Float64(height)

                ray = camera_ray(camera, u, v, aspect)
                hit = find_surface(ray, grid)

                if hit !== nothing
                    intensity = shade(Tuple(hit.normal), light)
                    pixels[y, x] = (intensity, intensity, intensity)
                else
                    pixels[y, x] = background
                end
            else
                # Multi-sample: stratified jittered supersampling
                acc_r = 0.0
                acc_g = 0.0
                acc_b = 0.0

                for sy in 0:k-1
                    for sx in 0:k-1
                        # Jittered sub-pixel offset within stratum
                        jx = (sx + rand(rng)) * inv_k
                        jy = (sy + rand(rng)) * inv_k

                        u = (Float64(x) - 1.0 + jx) / Float64(width)
                        v = 1.0 - (Float64(y) - 1.0 + jy) / Float64(height)

                        ray = camera_ray(camera, u, v, aspect)
                        hit = find_surface(ray, grid)

                        if hit !== nothing
                            intensity = shade(Tuple(hit.normal), light)
                            acc_r += intensity
                            acc_g += intensity
                            acc_b += intensity
                        else
                            acc_r += background[1]
                            acc_g += background[2]
                            acc_b += background[3]
                        end
                    end
                end

                pixels[y, x] = (acc_r * inv_spp, acc_g * inv_spp, acc_b * inv_spp)
            end
        end
    end

    # Apply gamma correction if needed
    if inv_gamma != 1.0
        for i in eachindex(pixels)
            r, g, b = pixels[i]
            pixels[i] = (clamp(r, 0.0, 1.0) ^ inv_gamma,
                         clamp(g, 0.0, 1.0) ^ inv_gamma,
                         clamp(b, 0.0, 1.0) ^ inv_gamma)
        end
    end

    pixels
end

"""
    write_ppm(filename::String, pixels::Matrix{NTuple{3, Float64}})

Write an image to a PPM file.

# Arguments
- `filename` - Output file path
- `pixels` - height×width matrix of RGB tuples, channels in [0, 1]
"""
function write_ppm(filename::String, pixels::Matrix{NTuple{3, Float64}})
    height, width = size(pixels)

    open(filename, "w") do io
        println(io, "P3")
        println(io, "$width $height")
        println(io, "255")

        for y in 1:height
            row = String[]
            for x in 1:width
                r, g, b = pixels[y, x]
                # Clamp and convert to 0-255
                ri = clamp(round(Int, r * 255), 0, 255)
                gi = clamp(round(Int, g * 255), 0, 255)
                bi = clamp(round(Int, b * 255), 0, 255)
                push!(row, "$ri $gi $bi")
            end
            println(io, join(row, " "))
        end
    end
end

# ============================================================================
# Vector utilities (internal)
# ============================================================================

function _normalize(v::NTuple{3, Float64})::NTuple{3, Float64}
    len = sqrt(v[1]^2 + v[2]^2 + v[3]^2)
    if len < 1e-10
        return (0.0, 0.0, 1.0)  # Default direction for zero vector
    end
    (v[1] / len, v[2] / len, v[3] / len)
end

function _dot(a::NTuple{3, Float64}, b::NTuple{3, Float64})::Float64
    a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
end

function _cross(a::NTuple{3, Float64}, b::NTuple{3, Float64})::NTuple{3, Float64}
    (a[2]*b[3] - a[3]*b[2],
     a[3]*b[1] - a[1]*b[3],
     a[1]*b[2] - a[2]*b[1])
end

function _sub(a::NTuple{3, Float64}, b::NTuple{3, Float64})::NTuple{3, Float64}
    (a[1] - b[1], a[2] - b[2], a[3] - b[3])
end

function _add(a::NTuple{3, Float64}, b::NTuple{3, Float64})::NTuple{3, Float64}
    (a[1] + b[1], a[2] + b[2], a[3] + b[3])
end

function _scale(v::NTuple{3, Float64}, s::Float64)::NTuple{3, Float64}
    (v[1] * s, v[2] * s, v[3] * s)
end

function _ray_at(ray::Ray, t::Float64)::NTuple{3, Float64}
    (ray.origin[1] + t * ray.direction[1],
     ray.origin[2] + t * ray.direction[2],
     ray.origin[3] + t * ray.direction[3])
end
