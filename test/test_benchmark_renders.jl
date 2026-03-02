# test_benchmark_renders.jl — Benchmark render tests with golden image regression
#
# Tier 5: Image Comparison Infrastructure Tests
# Tier 6: Local VDB Render Consistency
# Tier 7: Disney Cloud Benchmark
# Tier 8: Monte Carlo Convergence Rate
# Tier 9: Multi-Grid VDB Rendering
# Tier 10: Golden Image Regression
# Tier 11: Determinism on Real VDB Files

using Test
using Lyr
using Random: Xoshiro

import Lyr: active_bounding_box, BBox, intersect_bbox, _volume_bounds,
            NanoValueAccessor, PhaseFunction, IsotropicPhase, HenyeyGreensteinPhase

# Inline stats helpers (avoid Statistics.jl dependency)
_bmean(x) = sum(x) / length(x)

# ============================================================================
# Shared constants and helpers
# ============================================================================

const FIXTURE_DIR = joinpath(@__DIR__, "fixtures")
const SAMPLE_DIR = joinpath(FIXTURE_DIR, "samples")
const OPENVDB_DIR = joinpath(FIXTURE_DIR, "openvdb")
const DISNEY_DIR = joinpath(FIXTURE_DIR, "disney")
const REF_RENDER_DIR = joinpath(FIXTURE_DIR, "reference_renders")

# Canonical seeds for golden renders (must match generate_benchmark_renders.jl)
const SEED_SPHERE_SS = UInt64(9001)
const SEED_SPHERE_MS = UInt64(9002)
const SEED_SMOKE_SS  = UInt64(9003)

"""Average brightness of a pixel matrix (mean of all channels of all pixels)."""
function _bm_avg_brightness(pixels::Matrix)
    total = 0.0
    count = 0
    for i in eachindex(pixels)
        r, g, b = pixels[i]
        total += (r + g + b) / 3.0
        count += 1
    end
    count == 0 ? 0.0 : total / count
end

"""Build fog sphere for benchmark tests. Shared canonical scene."""
function _bm_fog_sphere(; radius=10.0, sigma_scale=5.0, albedo=0.9, emission_scale=1.0)
    sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=radius, voxel_size=1.0)
    fog = sdf_to_fog(sdf)
    nano = build_nanogrid(fog.tree)
    mat = VolumeMaterial(tf_smoke();
                         sigma_scale=sigma_scale,
                         emission_scale=emission_scale,
                         scattering_albedo=albedo)
    (fog, nano, mat)
end

"""Canonical sphere camera/light for golden renders."""
function _bm_sphere_scene(fog, nano, mat)
    cam = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
    light = DirectionalLight((1.0, 0.5, 0.0), (8.0, 8.0, 8.0))
    vol = VolumeEntry(fog, nano, mat)
    Scene(cam, light, vol)
end

"""Auto-camera for VDB files: diagonal view from active bounding box."""
function _bm_vdb_camera(tree)
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

"""Find a VDB file, checking samples then openvdb directories."""
function _bm_find_vdb(name::String)
    for dir in [SAMPLE_DIR, OPENVDB_DIR]
        p = joinpath(dir, name)
        isfile(p) && return p
    end
    return nothing
end

# ============================================================================

@testset "Benchmark Renders" begin

# ============================================================================
# Tier 5: Image Comparison Infrastructure Tests
# ============================================================================

@testset "Tier 5: Image Comparison Infrastructure" begin

    @testset "T5.1 RMSE of identical images = 0.0" begin
        img = [(Float64(x)/10, Float64(y)/10, 0.5) for y in 1:8, x in 1:8]
        @test image_rmse(img, img) == 0.0
    end

    @testset "T5.2 RMSE known value: red vs black" begin
        red = fill((1.0, 0.0, 0.0), 4, 4)
        black = fill((0.0, 0.0, 0.0), 4, 4)
        # RMSE = sqrt((16 * 1.0) / (3 * 16)) = sqrt(1/3)
        @test image_rmse(red, black) ≈ sqrt(1.0 / 3.0) atol=1e-12
    end

    @testset "T5.3 PSNR of identical images = Inf" begin
        img = fill((0.5, 0.3, 0.7), 4, 4)
        @test image_psnr(img, img) == Inf
    end

    @testset "T5.4 PSNR decreases as noise increases" begin
        base = fill((0.5, 0.5, 0.5), 8, 8)
        low_noise = [(0.5 + 0.01 * (mod(i + j, 3) - 1), 0.5, 0.5) for i in 1:8, j in 1:8]
        high_noise = [(0.5 + 0.1 * (mod(i + j, 3) - 1), 0.5, 0.5) for i in 1:8, j in 1:8]
        @test image_psnr(base, low_noise) > image_psnr(base, high_noise)
    end

    @testset "T5.5 SSIM of identical images = 1.0" begin
        img = [(Float64(x)/8, Float64(y)/8, 0.3) for y in 1:8, x in 1:8]
        @test image_ssim(img, img) ≈ 1.0 atol=1e-10
    end

    @testset "T5.6 SSIM decreases as noise increases" begin
        base = [(0.5 + 0.3 * sin(Float64(x)), 0.5, 0.5) for y in 1:16, x in 1:16]
        low_noise = [(r + 0.02 * (mod(i, 3) - 1), g, b)
                     for (i, (r, g, b)) in enumerate(base)]
        low_noise = reshape(low_noise, size(base))
        high_noise = [(r + 0.2 * (mod(i, 3) - 1), g, b)
                      for (i, (r, g, b)) in enumerate(base)]
        high_noise = reshape(high_noise, size(base))
        @test image_ssim(base, low_noise) > image_ssim(base, high_noise)
    end

    @testset "T5.7 max_diff exact value" begin
        a = fill((0.0, 0.0, 0.0), 4, 4)
        b = fill((0.0, 0.0, 0.0), 4, 4)
        b[2, 3] = (0.0, 0.7, 0.0)
        @test image_max_diff(a, b) ≈ 0.7 atol=1e-12
    end

    @testset "T5.8 PPM write→read round-trip" begin
        original = [(Float64(x)/10, Float64(y)/20, 0.5) for y in 1:8, x in 1:8]
        tmp = tempname() * ".ppm"
        write_ppm(tmp, original)
        loaded = read_ppm(tmp)
        @test size(loaded) == size(original)
        # Quantization error ≤ 0.5/255 ≈ 0.002 per channel
        @test image_max_diff(original, loaded) < 1.0 / 255.0 + 1e-10
        rm(tmp; force=true)
    end

    @testset "T5.9 PPM round-trip various sizes" begin
        for (h, w) in [(1, 1), (64, 64), (128, 64)]
            original = [(rand(), rand(), rand()) for _ in 1:h, _ in 1:w]
            tmp = tempname() * ".ppm"
            write_ppm(tmp, original)
            loaded = read_ppm(tmp)
            @test size(loaded) == (h, w)
            @test image_max_diff(original, loaded) < 1.0 / 255.0 + 1e-10
            rm(tmp; force=true)
        end
    end

end  # Tier 5

# ============================================================================
# Tier 6: Local VDB Render Consistency
# ============================================================================

@testset "Tier 6: Local VDB Render Consistency" begin

    @testset "T6.1 smoke.vdb SingleScatter consistency" begin
        fpath = _bm_find_vdb("smoke.vdb")
        if fpath === nothing
            fpath = _bm_find_vdb("smoke1.vdb")
        end
        if fpath === nothing
            @test_skip "smoke.vdb not available"
            return
        end

        file = parse_vdb(fpath)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _bm_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=2.0, emission_scale=1.0, scattering_albedo=0.8)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        # High SPP vs low SPP — should have small RMSE
        px_high = render_volume(scene, SingleScatterTracer(), 32, 32; spp=128, seed=UInt64(6001))
        px_low = render_volume(scene, SingleScatterTracer(), 32, 32; spp=8, seed=UInt64(6001))
        rmse = image_rmse(px_high, px_low)
        @test rmse < 0.15
        @test _bm_avg_brightness(px_high) > 0.0
    end

    @testset "T6.2 smoke.vdb EA deterministic" begin
        fpath = _bm_find_vdb("smoke.vdb")
        if fpath === nothing
            fpath = _bm_find_vdb("smoke1.vdb")
        end
        if fpath === nothing
            @test_skip "smoke.vdb not available"
            return
        end

        file = parse_vdb(fpath)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _bm_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=2.0, emission_scale=1.0, scattering_albedo=0.8)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        px1 = render_volume(scene, EmissionAbsorption(step_size=0.5), 32, 32)
        px2 = render_volume(scene, EmissionAbsorption(step_size=0.5), 32, 32)
        @test px1 == px2
        @test _bm_avg_brightness(px1) > 0.0
    end

    @testset "T6.3 bunny_cloud.vdb SingleScatter consistency" begin
        fpath = _bm_find_vdb("bunny_cloud.vdb")
        if fpath === nothing
            @test_skip "bunny_cloud.vdb not available"
            return
        end

        file = parse_vdb(fpath)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _bm_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=2.0, emission_scale=1.0, scattering_albedo=0.8)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        px_high = render_volume(scene, SingleScatterTracer(), 32, 32; spp=32, seed=UInt64(6003))
        px_low = render_volume(scene, SingleScatterTracer(), 32, 32; spp=4, seed=UInt64(6003))
        rmse = image_rmse(px_high, px_low)
        @test rmse < 0.20
        @test _bm_avg_brightness(px_high) > 0.0
    end

    @testset "T6.4 explosion.vdb density EA deterministic" begin
        fpath = _bm_find_vdb("explosion.vdb")
        if fpath === nothing
            @test_skip "explosion.vdb not available"
            return
        end

        file = parse_vdb(fpath)
        # Find density grid
        density_grid = nothing
        for g in file.grids
            if g.name == "density"
                density_grid = g
                break
            end
        end
        if density_grid === nothing
            @test_skip "No density grid in explosion.vdb"
            return
        end
        nano = build_nanogrid(density_grid.tree)
        cam = _bm_vdb_camera(density_grid.tree)
        mat = VolumeMaterial(tf_blackbody(); sigma_scale=8.0, emission_scale=2.0, scattering_albedo=0.3)
        vol = VolumeEntry(density_grid, nano, mat)
        light = DirectionalLight((1.0, 1.0, 1.0), (4.0, 4.0, 4.0))
        scene = Scene(cam, light, vol)

        px1 = render_volume(scene, EmissionAbsorption(step_size=0.5), 32, 32)
        px2 = render_volume(scene, EmissionAbsorption(step_size=0.5), 32, 32)
        @test px1 == px2
        @test _bm_avg_brightness(px1) > 0.0
    end

    @testset "T6.5 fire.vdb density EA deterministic" begin
        fpath = _bm_find_vdb("fire.vdb")
        if fpath === nothing
            @test_skip "fire.vdb not available"
            return
        end

        file = parse_vdb(fpath)
        density_grid = nothing
        for g in file.grids
            if occursin("density", lowercase(g.name))
                density_grid = g
                break
            end
        end
        if density_grid === nothing
            @test_skip "No density grid in fire.vdb"
            return
        end
        nano = build_nanogrid(density_grid.tree)
        cam = _bm_vdb_camera(density_grid.tree)
        mat = VolumeMaterial(tf_blackbody(); sigma_scale=8.0, emission_scale=2.0, scattering_albedo=0.3)
        vol = VolumeEntry(density_grid, nano, mat)
        light = DirectionalLight((1.0, 1.0, 1.0), (4.0, 4.0, 4.0))
        scene = Scene(cam, light, vol)

        px1 = render_volume(scene, EmissionAbsorption(step_size=0.5), 32, 32)
        px2 = render_volume(scene, EmissionAbsorption(step_size=0.5), 32, 32)
        @test px1 == px2
        @test _bm_avg_brightness(px1) > 0.0
    end

end  # Tier 6

# ============================================================================
# Tier 7: Disney Cloud Benchmark
# ============================================================================

@testset "Tier 7: Disney Cloud" begin

    disney_path = joinpath(DISNEY_DIR, "wdas_cloud_sixteenth.vdb")

    @testset "T7.1 Parses without error" begin
        if !isfile(disney_path)
            @test_skip "Disney cloud VDB not available"
            return
        end
        file = parse_vdb(disney_path)
        @test length(file.grids) >= 1
        @test active_voxel_count(file.grids[1].tree) > 0
    end

    @testset "T7.2 Renders without crash" begin
        if !isfile(disney_path)
            @test_skip "Disney cloud VDB not available"
            return
        end
        file = parse_vdb(disney_path)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _bm_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0, scattering_albedo=0.9)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        px = render_volume(scene, EmissionAbsorption(step_size=0.5), 32, 32)
        @test size(px) == (32, 32)
        for i in eachindex(px)
            r, g, b = px[i]
            @test 0.0 <= r <= 1.0
            @test 0.0 <= g <= 1.0
            @test 0.0 <= b <= 1.0
        end
    end

    @testset "T7.3 Physical plausibility" begin
        if !isfile(disney_path)
            @test_skip "Disney cloud VDB not available"
            return
        end
        file = parse_vdb(disney_path)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _bm_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0, scattering_albedo=0.9)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        px = render_volume(scene, SingleScatterTracer(), 32, 32; spp=16, seed=UInt64(7003))
        avg = _bm_avg_brightness(px)
        @test avg > 0.001  # Cloud should scatter some light
    end

    @testset "T7.4 Multi-scatter vs single-scatter" begin
        if !isfile(disney_path)
            @test_skip "Disney cloud VDB not available"
            return
        end
        file = parse_vdb(disney_path)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _bm_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0, scattering_albedo=0.9)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        px_ss = render_volume(scene, SingleScatterTracer(), 16, 16; spp=32, seed=UInt64(7004))
        px_ms = render_volume(scene, ReferencePathTracer(max_bounces=8), 16, 16; spp=32, seed=UInt64(7004))
        avg_ss = _bm_avg_brightness(px_ss)
        avg_ms = _bm_avg_brightness(px_ms)
        # Multi-scatter should be at least as bright (more light paths)
        @test avg_ms >= avg_ss * 0.8  # Allow some MC noise tolerance
    end

    @testset "T7.5 Golden image regression" begin
        if !isfile(disney_path)
            @test_skip "Disney cloud VDB not available"
            return
        end
        ref_path = joinpath(REF_RENDER_DIR, "disney_cloud_ea_64x64.ppm")
        if !isfile(ref_path)
            @test_skip "Disney cloud golden image not generated yet"
            return
        end

        file = parse_vdb(disney_path)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _bm_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0, scattering_albedo=0.9)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        px = render_volume(scene, EmissionAbsorption(step_size=0.5), 64, 64)
        ref = load_reference_render(ref_path)
        rmse = image_rmse(px, ref)
        @test rmse < 0.005  # Deterministic — only PPM quantization
    end

end  # Tier 7

# ============================================================================
# Tier 8: Monte Carlo Convergence Rate
# ============================================================================

@testset "Tier 8: MC Convergence Rate" begin

    fog, nano, mat = _bm_fog_sphere(sigma_scale=5.0, albedo=0.9)
    scene = _bm_sphere_scene(fog, nano, mat)

    @testset "T8.1 SS RMSE decreases with SPP" begin
        # Ground truth at high SPP
        gt = render_volume(scene, SingleScatterTracer(), 16, 16; spp=1024, seed=UInt64(8001))
        prev_rmse = Inf
        for spp in [4, 16, 64, 256]
            px = render_volume(scene, SingleScatterTracer(), 16, 16; spp=spp, seed=UInt64(8001))
            rmse = image_rmse(px, gt)
            @test rmse < prev_rmse
            prev_rmse = rmse
        end
    end

    @testset "T8.2 Convergence rate ≈ O(1/√N)" begin
        gt = render_volume(scene, SingleScatterTracer(), 16, 16; spp=1024, seed=UInt64(8002))
        rmse_4 = image_rmse(
            render_volume(scene, SingleScatterTracer(), 16, 16; spp=4, seed=UInt64(8002)), gt)
        rmse_64 = image_rmse(
            render_volume(scene, SingleScatterTracer(), 16, 16; spp=64, seed=UInt64(8002)), gt)
        # Expected ratio: sqrt(64/4) = 4.0, allow 40% tolerance
        ratio = rmse_4 / max(rmse_64, 1e-10)
        @test ratio > 4.0 * 0.4  # At least 1.6
        @test ratio < 4.0 * 2.5  # At most 10
    end

    @testset "T8.3 MS RMSE decreases with SPP" begin
        gt = render_volume(scene, ReferencePathTracer(max_bounces=8), 16, 16;
                           spp=512, seed=UInt64(8003))
        prev_rmse = Inf
        for spp in [4, 16, 64]
            px = render_volume(scene, ReferencePathTracer(max_bounces=8), 16, 16;
                               spp=spp, seed=UInt64(8003))
            rmse = image_rmse(px, gt)
            @test rmse < prev_rmse
            prev_rmse = rmse
        end
    end

    @testset "T8.4 EA has zero variance" begin
        px1 = render_volume(scene, EmissionAbsorption(step_size=0.5), 16, 16)
        px2 = render_volume(scene, EmissionAbsorption(step_size=0.5), 16, 16)
        @test image_rmse(px1, px2) == 0.0
    end

    @testset "T8.5 At spp=64, SS RMSE < 0.05" begin
        gt = render_volume(scene, SingleScatterTracer(), 16, 16; spp=1024, seed=UInt64(8005))
        px = render_volume(scene, SingleScatterTracer(), 16, 16; spp=64, seed=UInt64(8005))
        @test image_rmse(px, gt) < 0.05
    end

end  # Tier 8

# ============================================================================
# Tier 9: Multi-Grid VDB Rendering
# ============================================================================

@testset "Tier 9: Multi-Grid VDB" begin

    @testset "T9.1 explosion.vdb has density, v, temperature" begin
        fpath = _bm_find_vdb("explosion.vdb")
        if fpath === nothing
            @test_skip "explosion.vdb not available"
            return
        end
        file = parse_vdb(fpath)
        names = [g.name for g in file.grids]
        @test "density" in names
        @test "v" in names
        @test "temperature" in names
        @test length(file.grids) >= 3
    end

    @testset "T9.2 explosion.vdb different TFs produce different renders" begin
        fpath = _bm_find_vdb("explosion.vdb")
        if fpath === nothing
            @test_skip "explosion.vdb not available"
            return
        end
        file = parse_vdb(fpath)
        density_grid = nothing
        for g in file.grids
            if g.name == "density"
                density_grid = g
                break
            end
        end
        density_grid === nothing && (@test_skip "No density grid"; return)

        nano = build_nanogrid(density_grid.tree)
        cam = _bm_vdb_camera(density_grid.tree)
        light = DirectionalLight((1.0, 1.0, 1.0), (4.0, 4.0, 4.0))

        mat_smoke = VolumeMaterial(tf_smoke(); sigma_scale=5.0, emission_scale=1.0)
        mat_bb = VolumeMaterial(tf_blackbody(); sigma_scale=5.0, emission_scale=2.0)

        scene_smoke = Scene(cam, light, VolumeEntry(density_grid, nano, mat_smoke))
        scene_bb = Scene(cam, light, VolumeEntry(density_grid, nano, mat_bb))

        px_smoke = render_volume(scene_smoke, EmissionAbsorption(step_size=0.5), 32, 32)
        px_bb = render_volume(scene_bb, EmissionAbsorption(step_size=0.5), 32, 32)

        @test image_rmse(px_smoke, px_bb) > 0.01
    end

    @testset "T9.3 fire.vdb has density + temperature" begin
        fpath = _bm_find_vdb("fire.vdb")
        if fpath === nothing
            @test_skip "fire.vdb not available"
            return
        end
        file = parse_vdb(fpath)
        names = [lowercase(g.name) for g in file.grids]
        has_density = any(occursin("density", n) for n in names)
        has_temp = any(occursin("temperature", n) || occursin("temp", n) for n in names)
        @test has_density
        @test has_temp
        @test length(file.grids) >= 2

        # Render density grid
        density_grid = nothing
        for g in file.grids
            if occursin("density", lowercase(g.name))
                density_grid = g
                break
            end
        end
        if density_grid !== nothing
            nano = build_nanogrid(density_grid.tree)
            cam = _bm_vdb_camera(density_grid.tree)
            mat = VolumeMaterial(tf_blackbody(); sigma_scale=5.0, emission_scale=2.0, scattering_albedo=0.3)
            vol = VolumeEntry(density_grid, nano, mat)
            light = DirectionalLight((1.0, 1.0, 1.0), (4.0, 4.0, 4.0))
            scene = Scene(cam, light, vol)
            px = render_volume(scene, EmissionAbsorption(step_size=0.5), 16, 16)
            @test _bm_avg_brightness(px) > 0.0
        end
    end

    @testset "T9.4 smoke2.vdb has v + density" begin
        fpath = _bm_find_vdb("smoke2.vdb")
        if fpath === nothing
            @test_skip "smoke2.vdb not available"
            return
        end
        file = parse_vdb(fpath)
        names = [lowercase(g.name) for g in file.grids]
        has_density = any(occursin("density", n) for n in names)
        has_v = any(n == "v" for n in names)
        @test has_density
        @test has_v
        @test length(file.grids) >= 2

        # Render density grid
        density_grid = nothing
        for g in file.grids
            if occursin("density", lowercase(g.name))
                density_grid = g
                break
            end
        end
        if density_grid !== nothing
            nano = build_nanogrid(density_grid.tree)
            cam = _bm_vdb_camera(density_grid.tree)
            mat = VolumeMaterial(tf_smoke(); sigma_scale=2.0, emission_scale=1.0, scattering_albedo=0.8)
            vol = VolumeEntry(density_grid, nano, mat)
            light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
            scene = Scene(cam, light, vol)
            px = render_volume(scene, EmissionAbsorption(step_size=0.5), 16, 16)
            @test _bm_avg_brightness(px) > 0.0
        end
    end

end  # Tier 9

# ============================================================================
# Tier 10: Golden Image Regression
# ============================================================================

@testset "Tier 10: Golden Image Regression" begin

    @testset "T10.1 sphere_fog SingleScatter" begin
        ref_path = joinpath(REF_RENDER_DIR, "sphere_fog_ss_64x64.ppm")
        if !isfile(ref_path)
            @test_skip "Golden image not generated yet"
            return
        end
        fog, nano, mat = _bm_fog_sphere()
        scene = _bm_sphere_scene(fog, nano, mat)
        px = render_volume(scene, SingleScatterTracer(), 64, 64; spp=64, seed=SEED_SPHERE_SS)
        ref = load_reference_render(ref_path)
        @test image_rmse(px, ref) < 0.03
    end

    @testset "T10.2 sphere_fog RefPathTracer" begin
        ref_path = joinpath(REF_RENDER_DIR, "sphere_fog_ms_64x64.ppm")
        if !isfile(ref_path)
            @test_skip "Golden image not generated yet"
            return
        end
        fog, nano, mat = _bm_fog_sphere()
        scene = _bm_sphere_scene(fog, nano, mat)
        px = render_volume(scene, ReferencePathTracer(max_bounces=16), 64, 64;
                           spp=128, seed=SEED_SPHERE_MS)
        ref = load_reference_render(ref_path)
        @test image_rmse(px, ref) < 0.03
    end

    @testset "T10.3 sphere_fog EA (deterministic)" begin
        ref_path = joinpath(REF_RENDER_DIR, "sphere_fog_ea_64x64.ppm")
        if !isfile(ref_path)
            @test_skip "Golden image not generated yet"
            return
        end
        fog, nano, mat = _bm_fog_sphere()
        scene = _bm_sphere_scene(fog, nano, mat)
        px = render_volume(scene, EmissionAbsorption(step_size=0.5), 64, 64)
        ref = load_reference_render(ref_path)
        @test image_rmse(px, ref) < 0.005  # Tight — only PPM quantization
    end

    @testset "T10.4 smoke.vdb SingleScatter" begin
        ref_path = joinpath(REF_RENDER_DIR, "smoke1_ss_128x128.ppm")
        if !isfile(ref_path)
            @test_skip "Golden image not generated yet"
            return
        end
        fpath = _bm_find_vdb("smoke.vdb")
        if fpath === nothing
            fpath = _bm_find_vdb("smoke1.vdb")
        end
        if fpath === nothing
            @test_skip "smoke.vdb not available"
            return
        end
        file = parse_vdb(fpath)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _bm_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=2.0, emission_scale=1.0, scattering_albedo=0.8)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        px = render_volume(scene, SingleScatterTracer(), 128, 128; spp=64, seed=SEED_SMOKE_SS)
        ref = load_reference_render(ref_path)
        @test image_rmse(px, ref) < 0.03
    end

    @testset "T10.5 explosion.vdb EA (deterministic)" begin
        ref_path = joinpath(REF_RENDER_DIR, "explosion_ea_128x128.ppm")
        if !isfile(ref_path)
            @test_skip "Golden image not generated yet"
            return
        end
        fpath = _bm_find_vdb("explosion.vdb")
        if fpath === nothing
            @test_skip "explosion.vdb not available"
            return
        end
        file = parse_vdb(fpath)
        density_grid = nothing
        for g in file.grids
            if g.name == "density"
                density_grid = g
                break
            end
        end
        if density_grid === nothing
            @test_skip "No density grid in explosion.vdb"
            return
        end
        nano = build_nanogrid(density_grid.tree)
        cam = _bm_vdb_camera(density_grid.tree)
        mat = VolumeMaterial(tf_blackbody(); sigma_scale=8.0, emission_scale=2.0, scattering_albedo=0.3)
        vol = VolumeEntry(density_grid, nano, mat)
        light = DirectionalLight((1.0, 1.0, 1.0), (4.0, 4.0, 4.0))
        scene = Scene(cam, light, vol)

        px = render_volume(scene, EmissionAbsorption(step_size=0.5), 128, 128)
        ref = load_reference_render(ref_path)
        @test image_rmse(px, ref) < 0.005
    end

end  # Tier 10

# ============================================================================
# Tier 11: Determinism on Real VDB Files
# ============================================================================

@testset "Tier 11: Determinism on VDB" begin

    @testset "T11.1 sphere SS same seed → same pixels" begin
        fog, nano, mat = _bm_fog_sphere()
        scene = _bm_sphere_scene(fog, nano, mat)
        px1 = render_volume(scene, SingleScatterTracer(), 16, 16; spp=8, seed=UInt64(11001))
        px2 = render_volume(scene, SingleScatterTracer(), 16, 16; spp=8, seed=UInt64(11001))
        @test px1 == px2
    end

    @testset "T11.2 sphere MS same seed → same pixels" begin
        fog, nano, mat = _bm_fog_sphere()
        scene = _bm_sphere_scene(fog, nano, mat)
        px1 = render_volume(scene, ReferencePathTracer(max_bounces=8), 16, 16;
                            spp=8, seed=UInt64(11002))
        px2 = render_volume(scene, ReferencePathTracer(max_bounces=8), 16, 16;
                            spp=8, seed=UInt64(11002))
        @test px1 == px2
    end

    @testset "T11.3 sphere SS different seeds differ" begin
        fog, nano, mat = _bm_fog_sphere()
        scene = _bm_sphere_scene(fog, nano, mat)
        px1 = render_volume(scene, SingleScatterTracer(), 16, 16; spp=8, seed=UInt64(11003))
        px2 = render_volume(scene, SingleScatterTracer(), 16, 16; spp=8, seed=UInt64(99999))
        @test px1 != px2
    end

    @testset "T11.4 smoke.vdb SS deterministic" begin
        fpath = _bm_find_vdb("smoke.vdb")
        if fpath === nothing
            fpath = _bm_find_vdb("smoke1.vdb")
        end
        if fpath === nothing
            @test_skip "smoke.vdb not available"
            return
        end
        file = parse_vdb(fpath)
        grid = file.grids[1]
        nano = build_nanogrid(grid.tree)
        cam = _bm_vdb_camera(grid.tree)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=2.0, emission_scale=1.0, scattering_albedo=0.8)
        vol = VolumeEntry(grid, nano, mat)
        light = DirectionalLight((1.0, 0.5, 1.0), (8.0, 8.0, 8.0))
        scene = Scene(cam, light, vol)

        px1 = render_volume(scene, SingleScatterTracer(), 16, 16; spp=8, seed=UInt64(11004))
        px2 = render_volume(scene, SingleScatterTracer(), 16, 16; spp=8, seed=UInt64(11004))
        @test px1 == px2
    end

    @testset "T11.5 explosion.vdb EA deterministic" begin
        fpath = _bm_find_vdb("explosion.vdb")
        if fpath === nothing
            @test_skip "explosion.vdb not available"
            return
        end
        file = parse_vdb(fpath)
        density_grid = nothing
        for g in file.grids
            if g.name == "density"
                density_grid = g
                break
            end
        end
        if density_grid === nothing
            @test_skip "No density grid"
            return
        end
        nano = build_nanogrid(density_grid.tree)
        cam = _bm_vdb_camera(density_grid.tree)
        mat = VolumeMaterial(tf_blackbody(); sigma_scale=8.0, emission_scale=2.0, scattering_albedo=0.3)
        vol = VolumeEntry(density_grid, nano, mat)
        light = DirectionalLight((1.0, 1.0, 1.0), (4.0, 4.0, 4.0))
        scene = Scene(cam, light, vol)

        px1 = render_volume(scene, EmissionAbsorption(step_size=0.5), 16, 16)
        px2 = render_volume(scene, EmissionAbsorption(step_size=0.5), 16, 16)
        @test px1 == px2
    end

end  # Tier 11

end  # Benchmark Renders
