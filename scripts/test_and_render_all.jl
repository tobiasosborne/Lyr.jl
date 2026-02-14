#!/usr/bin/env julia
#
# test_and_render_all.jl — Parse-check + raytrace every VDB in the test suite
#
# Usage:
#   julia --project scripts/test_and_render_all.jl [--width=512] [--height=512] [--skip-render]
#
# Outputs:
#   renders/<name>.ppm  — one image per successfully parsed grid
#   prints a summary table at the end

using Lyr

# =============================================================================
# Volume ray marcher for fog volumes (density fields)
# =============================================================================

function render_fog_volume(grid::Grid{T}, cam::Camera, width::Int, height::Int;
                           step_size::Float64=0.15,
                           absorption::Float64=12.0,
                           light_dir::NTuple{3,Float64}=(0.5, 0.7, 0.4),
                           bg_color::NTuple{3,Float64}=(0.05, 0.08, 0.15),
                           max_steps::Int=800) where T <: AbstractFloat
    aspect = Float64(width) / Float64(height)
    pixels = Matrix{NTuple{3,Float64}}(undef, height, width)

    bbox = active_bounding_box(grid.tree)
    bbox === nothing && return fill(bg_color, height, width)
    wmin = index_to_world(grid.transform, bbox.min)
    wmax = index_to_world(grid.transform, bbox.max)
    pad = step_size * 2.0
    bmin = (wmin[1]-pad, wmin[2]-pad, wmin[3]-pad)
    bmax = (wmax[1]+pad, wmax[2]+pad, wmax[3]+pad)

    ll = sqrt(light_dir[1]^2 + light_dir[2]^2 + light_dir[3]^2)
    light = (light_dir[1]/ll, light_dir[2]/ll, light_dir[3]/ll)
    vol_color = (1.0, 0.95, 0.88)

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
            transmittance = 1.0
            cr, cg, cb = 0.0, 0.0, 0.0

            for _ in 1:max_steps
                (t > t_exit || transmittance < 0.005) && break
                px = ray.origin[1] + t*ray.direction[1]
                py = ray.origin[2] + t*ray.direction[2]
                pz = ray.origin[3] + t*ray.direction[3]
                density = Float64(sample_world(grid, (px, py, pz)))

                if density > 0.001
                    ext = density * absorption * step_size
                    tr_step = exp(-ext)
                    h = step_size * 0.5
                    gx = Float64(sample_world(grid, (px+h,py,pz))) - Float64(sample_world(grid, (px-h,py,pz)))
                    gy = Float64(sample_world(grid, (px,py+h,pz))) - Float64(sample_world(grid, (px,py-h,pz)))
                    gz = Float64(sample_world(grid, (px,py,pz+h))) - Float64(sample_world(grid, (px,py,pz-h)))
                    gl = sqrt(gx^2 + gy^2 + gz^2)
                    if gl > 1e-8; gx /= gl; gy /= gl; gz /= gl; end
                    ndotl = max(0.0, -(gx*light[1] + gy*light[2] + gz*light[3]))
                    shade = 0.3 + 0.7*ndotl
                    energy = transmittance * (1.0 - tr_step)
                    cr += energy * vol_color[1] * shade
                    cg += energy * vol_color[2] * shade
                    cb += energy * vol_color[3] * shade
                    transmittance *= tr_step
                end
                t += step_size
            end

            cr += transmittance * bg_color[1]
            cg += transmittance * bg_color[2]
            cb += transmittance * bg_color[3]
            pixels[y, x] = (clamp(cr, 0.0, 1.0), clamp(cg, 0.0, 1.0), clamp(cb, 0.0, 1.0))
        end
    end
    pixels
end

# =============================================================================
# Helpers
# =============================================================================

function _ray_box(ray::Ray, bmin::NTuple{3,Float64}, bmax::NTuple{3,Float64})
    t1 = (bmin[1]-ray.origin[1])*ray.inv_dir[1]; t2 = (bmax[1]-ray.origin[1])*ray.inv_dir[1]
    tmin = min(t1,t2); tmax = max(t1,t2)
    t1 = (bmin[2]-ray.origin[2])*ray.inv_dir[2]; t2 = (bmax[2]-ray.origin[2])*ray.inv_dir[2]
    tmin = max(tmin,min(t1,t2)); tmax = min(tmax,max(t1,t2))
    t1 = (bmin[3]-ray.origin[3])*ray.inv_dir[3]; t2 = (bmax[3]-ray.origin[3])*ray.inv_dir[3]
    tmin = max(tmin,min(t1,t2)); tmax = min(tmax,max(t1,t2))
    (tmin, tmax)
end

function auto_camera(grid, dist_mult::Float64=1.8, fov::Float64=40.0)
    bbox = active_bounding_box(grid.tree)
    bbox === nothing && return nothing
    wmin = index_to_world(grid.transform, bbox.min)
    wmax = index_to_world(grid.transform, bbox.max)
    center = ((wmin[1]+wmax[1])/2, (wmin[2]+wmax[2])/2, (wmin[3]+wmax[3])/2)
    extent = max(wmax[1]-wmin[1], wmax[2]-wmin[2], wmax[3]-wmin[3])
    dist = extent * dist_mult
    cam_pos = (center[1] + dist*0.65, center[2] + dist*0.35, center[3] + dist*0.65)
    Camera(cam_pos, center, (0.0, 1.0, 0.0), fov)
end

function parse_cli_args()
    width = 512
    height = 512
    skip_render = false
    for arg in ARGS
        if startswith(arg, "--width=")
            width = parse(Int, arg[9:end])
        elseif startswith(arg, "--height=")
            height = parse(Int, arg[10:end])
        elseif arg == "--skip-render"
            skip_render = true
        end
    end
    (width, height, skip_render)
end

# =============================================================================
# Main
# =============================================================================

function main()
    width, height, skip_render = parse_cli_args()

    # Collect all VDB files from both fixture directories
    root = joinpath(@__DIR__, "..")
    dirs = [
        joinpath(root, "test", "fixtures", "samples"),
        joinpath(root, "test", "fixtures", "openvdb"),
    ]

    vdb_files = String[]
    for d in dirs
        isdir(d) || continue
        for f in sort(readdir(d))
            endswith(f, ".vdb") || continue
            push!(vdb_files, joinpath(d, f))
        end
    end

    println("=" ^ 80)
    println("Lyr.jl VDB Test Suite — $(length(vdb_files)) files")
    println("=" ^ 80)

    # Results tracking
    results = Vector{NamedTuple{(:file, :status, :version, :grids, :render_time, :error), Tuple{String, Symbol, String, String, Float64, String}}}()

    outdir = joinpath(root, "renders")
    mkpath(outdir)

    for path in vdb_files
        fname = basename(path)
        sz = round(filesize(path) / 1024 / 1024, digits=1)
        print("$(fname) ($(sz)MB) ... ")

        # Phase 1: Parse
        local vdb
        try
            vdb = parse_vdb(path)
        catch e
            msg = first(sprint(showerror, e), 80)
            println("PARSE FAILED: $msg")
            push!(results, (file=fname, status=:parse_error, version="?", grids="", render_time=0.0, error=msg))
            continue
        end

        ver = string(vdb.header.format_version)
        grid_descs = String[]
        for g in vdb.grids
            lc = leaf_count(g.tree)
            ac = active_voxel_count(g.tree)
            push!(grid_descs, "$(g.name)($(g.grid_class), $(lc) leaves, $(ac) active)")
        end
        grids_str = join(grid_descs, "; ")
        println("OK v$ver — $grids_str")

        if skip_render || isempty(vdb.grids)
            push!(results, (file=fname, status=:parsed, version=ver, grids=grids_str, render_time=0.0, error=""))
            continue
        end

        # Phase 2: Render first grid
        grid = vdb.grids[1]
        cam = auto_camera(grid)
        if cam === nothing
            println("  → skip render (no active voxels)")
            push!(results, (file=fname, status=:no_voxels, version=ver, grids=grids_str, render_time=0.0, error=""))
            continue
        end

        out_ppm = joinpath(outdir, replace(fname, ".vdb" => ".ppm"))
        print("  → rendering $(width)x$(height) ... ")

        local pixels
        t0 = time()
        try
            if grid.grid_class == GRID_LEVEL_SET
                # Sphere trace for level sets
                vs = voxel_size(grid.transform)[1]
                pixels = render_image(grid, cam, width, height; max_steps=500)
            else
                # Volume ray march for fog volumes
                vs = voxel_size(grid.transform)[1]
                pixels = render_fog_volume(grid, cam, width, height;
                                           step_size=vs*2.0, max_steps=800)
            end
        catch e
            elapsed = time() - t0
            msg = first(sprint(showerror, e), 80)
            println("RENDER FAILED ($(round(elapsed, digits=1))s): $msg")
            push!(results, (file=fname, status=:render_error, version=ver, grids=grids_str, render_time=elapsed, error=msg))
            continue
        end
        elapsed = time() - t0

        write_ppm(out_ppm, pixels)
        println("$(round(elapsed, digits=1))s → $out_ppm")
        push!(results, (file=fname, status=:rendered, version=ver, grids=grids_str, render_time=elapsed, error=""))
    end

    # Summary
    println()
    println("=" ^ 80)
    println("SUMMARY")
    println("=" ^ 80)

    n_parsed = count(r -> r.status in (:parsed, :rendered, :no_voxels), results)
    n_rendered = count(r -> r.status == :rendered, results)
    n_parse_err = count(r -> r.status == :parse_error, results)
    n_render_err = count(r -> r.status == :render_error, results)
    total_render = sum(r -> r.render_time, results)

    println("Files:    $(length(results))")
    println("Parsed:   $n_parsed / $(length(results))")
    println("Rendered: $n_rendered")
    if n_parse_err > 0
        println("Parse errors: $n_parse_err")
        for r in results
            r.status == :parse_error && println("  ✗ $(r.file): $(r.error)")
        end
    end
    if n_render_err > 0
        println("Render errors: $n_render_err")
        for r in results
            r.status == :render_error && println("  ✗ $(r.file): $(r.error)")
        end
    end
    if n_rendered > 0
        println("Total render time: $(round(total_render, digits=1))s")
        println()
        println("Render times:")
        for r in sort(collect(filter(r -> r.status == :rendered, results)), by=r -> -r.render_time)
            println("  $(lpad(string(round(r.render_time, digits=1)), 7))s  $(r.file)")
        end
    end
    println()
    println("Output directory: renders/")
end

main()
