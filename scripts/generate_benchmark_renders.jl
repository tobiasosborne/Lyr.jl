# generate_benchmark_renders.jl — Generate golden PPMs and showcase PNGs
#
# Golden PPMs: test/fixtures/reference_renders/ (for regression tests)
# Showcase PPMs+PNGs: showcase/benchmarks/ (visible deliverables)
#
# Usage: JULIA_NUM_THREADS=auto julia --project scripts/generate_benchmark_renders.jl

using Lyr

import Lyr: active_bounding_box

println("Threads: ", Threads.nthreads())

# ============================================================================
# Canonical parameters (MUST match test/test_benchmark_renders.jl exactly)
# ============================================================================

const SEED_SPHERE_SS = UInt64(9001)
const SEED_SPHERE_MS = UInt64(9002)
const SEED_SMOKE_SS  = UInt64(9003)

const FIXTURE_DIR = joinpath(@__DIR__, "..", "test", "fixtures")
const SAMPLE_DIR = joinpath(FIXTURE_DIR, "samples")
const OPENVDB_DIR = joinpath(FIXTURE_DIR, "openvdb")
const DISNEY_DIR = joinpath(FIXTURE_DIR, "disney")
const REF_RENDER_DIR = joinpath(FIXTURE_DIR, "reference_renders")
const SHOWCASE_DIR = joinpath(@__DIR__, "..", "showcase", "benchmarks")

mkpath(REF_RENDER_DIR)
mkpath(SHOWCASE_DIR)

# Showcase resolution — 400x300 is fast, looks good
const SC_W = 400
const SC_H = 300

function _gen_fog_sphere(; radius=10.0, sigma_scale=5.0, albedo=0.9, emission_scale=1.0)
    sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=radius, voxel_size=1.0)
    fog = sdf_to_fog(sdf)
    nano = build_nanogrid(fog.tree)
    mat = VolumeMaterial(tf_smoke();
                         sigma_scale=sigma_scale,
                         emission_scale=emission_scale,
                         scattering_albedo=albedo)
    (fog, nano, mat)
end

function _gen_sphere_scene(fog, nano, mat)
    cam = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
    light = DirectionalLight((1.0, 0.5, 0.0), (8.0, 8.0, 8.0))
    vol = VolumeEntry(fog, nano, mat)
    Scene(cam, light, vol)
end

function _gen_vdb_camera(tree)
    bb = active_bounding_box(tree)
    bb === nothing && error("No active voxels in tree")
    cx = Float64(bb.min.x + bb.max.x) / 2.0
    cy = Float64(bb.min.y + bb.max.y) / 2.0
    cz = Float64(bb.min.z + bb.max.z) / 2.0
    r = max(Float64(bb.max.x - bb.min.x),
            Float64(bb.max.y - bb.min.y),
            Float64(bb.max.z - bb.min.z)) / 2.0
    r = max(r, 1.0)
    Camera((cx + r * 2.0, cy + r * 1.5, cz + r * 2.0),
           (cx, cy, cz), (0.0, 0.0, 1.0), 40.0)
end

function _gen_find_vdb(name::String)
    for dir in [SAMPLE_DIR, OPENVDB_DIR]
        p = joinpath(dir, name)
        isfile(p) && return p
    end
    return nothing
end

function _avg_brightness(pixels)
    total = 0.0
    for i in eachindex(pixels)
        r, g, b = pixels[i]
        total += (r + g + b) / 3.0
    end
    total / length(pixels)
end

"""Write PPM and convert to PNG via ImageMagick if available."""
function _save_showcase(pixels, name)
    ppm_path = joinpath(SHOWCASE_DIR, name * ".ppm")
    png_path = joinpath(SHOWCASE_DIR, name * ".png")
    write_ppm(ppm_path, pixels)
    try
        run(`convert $ppm_path $png_path`)
        println("  → $(name).png")
    catch
        println("  → $(name).ppm (no ImageMagick for PNG)")
    end
end

# ============================================================================
# Sphere fog renders
# ============================================================================

println("\n=== Sphere fog renders ===")
t0 = time()

fog, nano, mat = _gen_fog_sphere()
scene = _gen_sphere_scene(fog, nano, mat)

# Golden PPMs (small for git — these are what tests compare against)
print("  sphere_fog_ss_64x64 ... ")
let t = time()
    px = render_volume(scene, SingleScatterTracer(), 64, 64; spp=64, seed=SEED_SPHERE_SS)
    save_reference_render(px, joinpath(REF_RENDER_DIR, "sphere_fog_ss_64x64.ppm"))
    println("done ($(round(time()-t, digits=1))s, brightness=$(round(_avg_brightness(px), digits=4)))")
end

print("  sphere_fog_ms_64x64 ... ")
let t = time()
    px = render_volume(scene, ReferencePathTracer(max_bounces=16), 64, 64; spp=128, seed=SEED_SPHERE_MS)
    save_reference_render(px, joinpath(REF_RENDER_DIR, "sphere_fog_ms_64x64.ppm"))
    println("done ($(round(time()-t, digits=1))s, brightness=$(round(_avg_brightness(px), digits=4)))")
end

print("  sphere_fog_ea_64x64 ... ")
let t = time()
    px = render_volume(scene, EmissionAbsorption(step_size=0.5), 64, 64)
    save_reference_render(px, joinpath(REF_RENDER_DIR, "sphere_fog_ea_64x64.ppm"))
    println("done ($(round(time()-t, digits=1))s, brightness=$(round(_avg_brightness(px), digits=4)))")
end

# Showcase renders
print("  sphere_fog_ss showcase ... ")
let t = time()
    px = render_volume(scene, SingleScatterTracer(), SC_W, SC_H; spp=32, seed=SEED_SPHERE_SS)
    _save_showcase(px, "sphere_fog_ss")
    println("($(round(time()-t, digits=1))s)")
end

print("  sphere_fog_ms showcase ... ")
let t = time()
    px = render_volume(scene, ReferencePathTracer(max_bounces=16), SC_W, SC_H; spp=32, seed=SEED_SPHERE_MS)
    _save_showcase(px, "sphere_fog_ms")
    println("($(round(time()-t, digits=1))s)")
end

println("  Sphere total: $(round(time()-t0, digits=1))s")

# ============================================================================
# smoke.vdb renders
# ============================================================================

println("\n=== smoke.vdb renders ===")

let fpath = _gen_find_vdb("smoke.vdb")
    if fpath === nothing
        fpath = _gen_find_vdb("smoke1.vdb")
    end
    if fpath === nothing
        println("  SKIP: smoke.vdb not found")
    else
        file = parse_vdb(fpath)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _gen_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=2.0, emission_scale=1.0, scattering_albedo=0.8)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        print("  smoke1_ss_128x128 golden ... ")
        let t = time()
            px = render_volume(scene, SingleScatterTracer(), 128, 128; spp=64, seed=SEED_SMOKE_SS)
            save_reference_render(px, joinpath(REF_RENDER_DIR, "smoke1_ss_128x128.ppm"))
            println("done ($(round(time()-t, digits=1))s)")
        end

        print("  smoke1_ss showcase ... ")
        let t = time()
            px = render_volume(scene, SingleScatterTracer(), SC_W, SC_H; spp=16, seed=SEED_SMOKE_SS)
            _save_showcase(px, "smoke1_ss")
            println("($(round(time()-t, digits=1))s)")
        end
    end
end

# ============================================================================
# explosion.vdb renders
# ============================================================================

println("\n=== explosion.vdb renders ===")

let fpath = _gen_find_vdb("explosion.vdb")
    if fpath === nothing
        println("  SKIP: explosion.vdb not found")
    else
        file = parse_vdb(fpath)
        density_grid = nothing
        for g in file.grids
            if g.name == "density"
                density_grid = g
                break
            end
        end
        if density_grid === nothing
            println("  SKIP: no density grid")
        else
            nano = build_nanogrid(density_grid.tree)
            cam = _gen_vdb_camera(density_grid.tree)
            mat = VolumeMaterial(tf_blackbody(); sigma_scale=8.0, emission_scale=2.0, scattering_albedo=0.3)
            vol = VolumeEntry(density_grid, nano, mat)
            light = DirectionalLight((1.0, 1.0, 1.0), (4.0, 4.0, 4.0))
            scene = Scene(cam, light, vol)

            print("  explosion_ea_128x128 golden ... ")
            let t = time()
                px = render_volume(scene, EmissionAbsorption(step_size=0.5), 128, 128)
                save_reference_render(px, joinpath(REF_RENDER_DIR, "explosion_ea_128x128.ppm"))
                println("done ($(round(time()-t, digits=1))s)")
            end

            print("  explosion_blackbody showcase ... ")
            let t = time()
                px = render_volume(scene, EmissionAbsorption(step_size=0.5), SC_W, SC_H)
                _save_showcase(px, "explosion_blackbody")
                println("($(round(time()-t, digits=1))s)")
            end
        end
    end
end

# ============================================================================
# fire.vdb renders
# ============================================================================

println("\n=== fire.vdb renders ===")

let fpath = _gen_find_vdb("fire.vdb")
    if fpath === nothing
        println("  SKIP: fire.vdb not found")
    else
        file = parse_vdb(fpath)
        density_grid = nothing
        for g in file.grids
            if occursin("density", lowercase(g.name))
                density_grid = g
                break
            end
        end
        if density_grid === nothing
            println("  SKIP: no density grid")
        else
            nano = build_nanogrid(density_grid.tree)
            cam = _gen_vdb_camera(density_grid.tree)
            mat = VolumeMaterial(tf_blackbody(); sigma_scale=8.0, emission_scale=2.0, scattering_albedo=0.3)
            vol = VolumeEntry(density_grid, nano, mat)
            light = DirectionalLight((1.0, 1.0, 1.0), (4.0, 4.0, 4.0))
            scene = Scene(cam, light, vol)

            print("  fire_blackbody showcase ... ")
            let t = time()
                px = render_volume(scene, EmissionAbsorption(step_size=0.5), SC_W, SC_H)
                _save_showcase(px, "fire_blackbody")
                println("($(round(time()-t, digits=1))s)")
            end
        end
    end
end

# ============================================================================
# bunny_cloud.vdb renders
# ============================================================================

println("\n=== bunny_cloud.vdb renders ===")

let fpath = _gen_find_vdb("bunny_cloud.vdb")
    if fpath === nothing
        println("  SKIP: bunny_cloud.vdb not found")
    else
        file = parse_vdb(fpath)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _gen_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=2.0, emission_scale=1.0, scattering_albedo=0.8)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        print("  bunny_cloud_ss showcase ... ")
        let t = time()
            px = render_volume(scene, SingleScatterTracer(), SC_W, SC_H; spp=8, seed=UInt64(6003))
            _save_showcase(px, "bunny_cloud_ss")
            println("($(round(time()-t, digits=1))s)")
        end
    end
end

# ============================================================================
# Disney Cloud renders
# ============================================================================

println("\n=== Disney Cloud renders ===")

let disney_path = joinpath(DISNEY_DIR, "wdas_cloud_sixteenth.vdb")
    if !isfile(disney_path)
        println("  SKIP: Disney cloud not downloaded yet")
        println("  Run: julia --project scripts/download_disney_cloud.jl")
    else
        file = parse_vdb(disney_path)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _gen_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0, scattering_albedo=0.9)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        print("  disney_cloud_ea_64x64 golden ... ")
        let t = time()
            px = render_volume(scene, EmissionAbsorption(step_size=0.5), 64, 64)
            save_reference_render(px, joinpath(REF_RENDER_DIR, "disney_cloud_ea_64x64.ppm"))
            println("done ($(round(time()-t, digits=1))s)")
        end

        print("  disney_cloud showcase ... ")
        let t = time()
            px = render_volume(scene, SingleScatterTracer(), SC_W, SC_H; spp=16, seed=UInt64(7001))
            _save_showcase(px, "disney_cloud")
            println("($(round(time()-t, digits=1))s)")
        end
    end
end

# ============================================================================
# Convergence comparison (4-up composite)
# ============================================================================

println("\n=== Convergence comparison ===")

let t = time()
    fog, nano, mat = _gen_fog_sphere()
    scene = _gen_sphere_scene(fog, nano, mat)

    panel_w = 100
    panel_h = 100
    composite = Matrix{NTuple{3, Float64}}(undef, panel_h, panel_w * 4)

    for (idx, spp) in enumerate([1, 4, 16, 64])
        px = render_volume(scene, SingleScatterTracer(), panel_w, panel_h;
                           spp=spp, seed=UInt64(8888))
        x_offset = (idx - 1) * panel_w
        for y in 1:panel_h, x in 1:panel_w
            composite[y, x_offset + x] = px[y, x]
        end
    end

    _save_showcase(composite, "convergence_comparison")
    println("  ($(round(time()-t, digits=1))s)")
end

# Convert golden PPMs to PNG too
println("\n=== Converting golden PPMs to PNG ===")
for f in readdir(REF_RENDER_DIR; join=true)
    endswith(f, ".ppm") || continue
    png = replace(f, ".ppm" => ".png")
    try
        run(`convert $f $png`)
        println("  → $(basename(png))")
    catch
    end
end

println("\n=== All benchmark renders complete ===")
println("Golden PPMs: ", REF_RENDER_DIR)
println("Showcase:    ", SHOWCASE_DIR)
