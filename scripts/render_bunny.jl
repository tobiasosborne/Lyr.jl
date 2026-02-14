#!/usr/bin/env julia
# render_bunny.jl - Smooth isosurface renderer for bunny_cloud.vdb
# Blurs the density field at render time for a clean, solid look.

using Lyr

"""
    smooth_sample(grid, point, radius) -> Float64

Sample density averaged over a 7-point stencil (center + 6 axis neighbors)
at the given radius. This acts as a spatial low-pass filter on the noisy cloud data.
"""
function smooth_sample(grid::Grid{Float32}, p::NTuple{3,Float64}, r::Float64)::Float64
    c  = Float64(sample_world(grid, p))
    xp = Float64(sample_world(grid, (p[1]+r, p[2], p[3])))
    xm = Float64(sample_world(grid, (p[1]-r, p[2], p[3])))
    yp = Float64(sample_world(grid, (p[1], p[2]+r, p[3])))
    ym = Float64(sample_world(grid, (p[1], p[2]-r, p[3])))
    zp = Float64(sample_world(grid, (p[1], p[2], p[3]+r)))
    zm = Float64(sample_world(grid, (p[1], p[2], p[3]-r)))
    (2.0 * c + xp + xm + yp + ym + zp + zm) / 8.0
end

function render_isosurface(grid::Grid{Float32}, cam::Camera, width::Int, height::Int;
                           threshold::Float64=0.15,
                           step_size::Float64=0.1,
                           blur_radius::Float64=2.0,
                           bisect_steps::Int=12,
                           light_dir::NTuple{3,Float64}=(0.5, 0.7, 0.4),
                           bg_color::NTuple{3,Float64}=(0.05, 0.08, 0.15),
                           surface_color::NTuple{3,Float64}=(0.85, 0.82, 0.75),
                           max_steps::Int=1200)
    aspect = Float64(width) / Float64(height)
    pixels = Matrix{NTuple{3,Float64}}(undef, height, width)

    bbox = active_bounding_box(grid.tree)
    wmin = index_to_world(grid.transform, bbox.min)
    wmax = index_to_world(grid.transform, bbox.max)
    pad = step_size * 2.0
    bmin = (wmin[1] - pad, wmin[2] - pad, wmin[3] - pad)
    bmax = (wmax[1] + pad, wmax[2] + pad, wmax[3] + pad)

    ll = sqrt(light_dir[1]^2 + light_dir[2]^2 + light_dir[3]^2)
    light = (light_dir[1]/ll, light_dir[2]/ll, light_dir[3]/ll)

    vs = voxel_size(grid.transform)[1]
    grad_h = blur_radius * 2.0  # gradient step = 2x blur radius for extra smoothness
    hit_count = Threads.Atomic{Int}(0)

    Threads.@threads for y in 1:height
        for x in 1:width
            u = (Float64(x) - 0.5) / Float64(width)
            v = 1.0 - (Float64(y) - 0.5) / Float64(height)

            ray = camera_ray(cam, u, v, aspect)

            t_enter, t_exit = _ray_box(ray, bmin, bmax)
            if t_enter > t_exit || t_exit < 0.0
                pixels[y, x] = bg_color
                continue
            end

            t = max(t_enter, 0.001)
            prev_d = 0.0
            prev_t = t
            found = false
            hit_t = 0.0

            for _ in 1:max_steps
                if t > t_exit
                    break
                end

                p = _at(ray, t)
                d = smooth_sample(grid, p, blur_radius)

                if d >= threshold && prev_d < threshold
                    # Bisect with smoothed density
                    lo = prev_t
                    hi = t
                    for _ in 1:bisect_steps
                        mid = (lo + hi) * 0.5
                        dm = smooth_sample(grid, _at(ray, mid), blur_radius)
                        if dm >= threshold
                            hi = mid
                        else
                            lo = mid
                        end
                    end
                    hit_t = (lo + hi) * 0.5
                    found = true
                    break
                end

                prev_d = d
                prev_t = t
                t += step_size
            end

            if !found
                pixels[y, x] = bg_color
                continue
            end

            Threads.atomic_add!(hit_count, 1)

            # Gradient normal using smoothed density at large step
            hp = _at(ray, hit_t)
            gx = smooth_sample(grid, (hp[1]+grad_h, hp[2], hp[3]), blur_radius) -
                 smooth_sample(grid, (hp[1]-grad_h, hp[2], hp[3]), blur_radius)
            gy = smooth_sample(grid, (hp[1], hp[2]+grad_h, hp[3]), blur_radius) -
                 smooth_sample(grid, (hp[1], hp[2]-grad_h, hp[3]), blur_radius)
            gz = smooth_sample(grid, (hp[1], hp[2], hp[3]+grad_h), blur_radius) -
                 smooth_sample(grid, (hp[1], hp[2], hp[3]-grad_h), blur_radius)
            glen = sqrt(gx^2 + gy^2 + gz^2)
            if glen > 1e-10
                gx /= glen; gy /= glen; gz /= glen
            end

            # Outward normal
            nx, ny, nz = -gx, -gy, -gz

            # Shading: ambient + diffuse + rim
            ndotl = max(0.0, nx*light[1] + ny*light[2] + nz*light[3])
            vd = _norm_t((-ray.direction[1], -ray.direction[2], -ray.direction[3]))
            ndotv = max(0.0, nx*vd[1] + ny*vd[2] + nz*vd[3])
            rim = 0.2 * (1.0 - ndotv)^3
            intensity = 0.15 + 0.65 * ndotl + rim

            pixels[y, x] = (clamp(surface_color[1] * intensity, 0.0, 1.0),
                            clamp(surface_color[2] * intensity, 0.0, 1.0),
                            clamp(surface_color[3] * intensity, 0.0, 1.0))
        end
    end

    println("  Pixels with hits: $(hit_count[]) / $(width * height)")
    pixels
end

_at(r::Ray, t::Float64) = (r.origin[1]+t*r.direction[1], r.origin[2]+t*r.direction[2], r.origin[3]+t*r.direction[3])

function _norm_t(v::NTuple{3,Float64})
    l = sqrt(v[1]^2 + v[2]^2 + v[3]^2)
    l < 1e-10 ? (0.0, 0.0, 1.0) : (v[1]/l, v[2]/l, v[3]/l)
end

function _ray_box(ray::Ray, bmin::NTuple{3,Float64}, bmax::NTuple{3,Float64})
    t1 = (bmin[1]-ray.origin[1])*ray.inv_dir[1]; t2 = (bmax[1]-ray.origin[1])*ray.inv_dir[1]
    tmin = min(t1,t2); tmax = max(t1,t2)
    t1 = (bmin[2]-ray.origin[2])*ray.inv_dir[2]; t2 = (bmax[2]-ray.origin[2])*ray.inv_dir[2]
    tmin = max(tmin,min(t1,t2)); tmax = min(tmax,max(t1,t2))
    t1 = (bmin[3]-ray.origin[3])*ray.inv_dir[3]; t2 = (bmax[3]-ray.origin[3])*ray.inv_dir[3]
    tmin = max(tmin,min(t1,t2)); tmax = min(tmax,max(t1,t2))
    (tmin, tmax)
end

function main()
    path = joinpath(@__DIR__, "..", "test", "fixtures", "samples", "bunny_cloud.vdb")
    println("Parsing $path...")
    vdb = parse_vdb(path)
    grid = vdb.grids[1]
    println("Grid: $(grid.name)  class=$(grid.grid_class)  leaves=$(leaf_count(grid.tree))")

    bbox = active_bounding_box(grid.tree)
    wmin = index_to_world(grid.transform, bbox.min)
    wmax = index_to_world(grid.transform, bbox.max)
    center = ((wmin[1]+wmax[1])/2, (wmin[2]+wmax[2])/2, (wmin[3]+wmax[3])/2)
    extent = max(wmax[1]-wmin[1], wmax[2]-wmin[2], wmax[3]-wmin[3])
    vs = voxel_size(grid.transform)[1]
    println("World: $wmin → $wmax  center=$center  extent=$extent  voxel_size=$vs")

    # Camera: 3/4 view slightly above
    dist = extent * 1.4
    cam_pos = (center[1] + dist*0.65, center[2] + dist*0.3, center[3] + dist*0.65)
    cam = Camera(cam_pos, center, (0.0, 1.0, 0.0), 36.0)
    println("Camera at $cam_pos → $center")

    width, height = 1024, 1024
    blur = vs * 5.0  # blur radius: 5 voxels
    println("Rendering $(width)x$(height) smooth isosurface (blur=$(round(blur, digits=2)))...")
    t0 = time()
    pixels = render_isosurface(grid, cam, width, height;
                               threshold=0.15, step_size=vs*1.0,
                               blur_radius=blur, max_steps=1500)
    elapsed = time() - t0
    println("  Time: $(round(elapsed, digits=1))s  ($(round(width*height/elapsed)) rays/sec)")

    out = joinpath(@__DIR__, "..", "bunny.ppm")
    write_ppm(out, pixels)
    println("Wrote $out")
end

main()
