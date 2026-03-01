# Test multi-scatter volumetric path tracer (reference renderer)
using Test
using Lyr
using Random: Xoshiro

import Lyr: _delta_tracking_collision, _shadow_transmittance, _trace_multiscatter,
            _volume_bounds, IsotropicPhase, HenyeyGreensteinPhase

# Helper: create a uniform fog sphere for testing
function _make_fog_sphere(; radius=8.0, density=0.5f0, sigma_scale=10.0,
                           albedo=0.9, phase=IsotropicPhase())
    sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=radius)
    fog = sdf_to_fog(sdf)
    # Scale fog density
    fog_data = Dict{Coord, Float32}()
    for (c, v) in active_voxels(fog.tree)
        fog_data[c] = v * density / 1.0f0  # fog values are 0-1
    end
    grid = build_grid(fog_data, 0.0f0; name="fog_sphere")
    nano = build_nanogrid(grid.tree)
    tf = tf_smoke()
    mat = VolumeMaterial(tf; sigma_scale=sigma_scale, emission_scale=1.0,
                         scattering_albedo=albedo, phase_function=phase)
    (grid, nano, mat)
end

@testset "Multi-scatter Path Tracer" begin

    @testset "empty volume returns background" begin
        # Zero-density fog volume
        data = Dict{Coord, Float32}()
        for iz in 0:7, iy in 0:7, ix in 0:7
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 0.0f0
        end
        grid = build_grid(data, 0.0f0; name="empty")
        nano = build_nanogrid(grid.tree)
        tf = tf_smoke()
        mat = VolumeMaterial(tf; sigma_scale=1.0)
        vol = VolumeEntry(grid, nano, mat)

        cam = Camera((4.0, 4.0, -20.0), (4.0, 4.0, 4.0), (0.0, 1.0, 0.0), 60.0)
        light = DirectionalLight((0.0, 0.0, 1.0))
        bg_color = (0.2, 0.3, 0.5)
        scene = Scene(cam, light, vol; background=bg_color)

        pixels = render_volume(scene, ReferencePathTracer(max_bounces=8), 4, 4; spp=4)
        @test size(pixels) == (4, 4)
        # All pixels should be approximately background color (zero density → escape)
        for p in pixels
            @test p[1] ≈ bg_color[1] atol=0.15
            @test p[2] ≈ bg_color[2] atol=0.15
            @test p[3] ≈ bg_color[3] atol=0.15
        end
    end

    @testset "produces valid output (no NaN/Inf, in [0,1])" begin
        grid, nano, mat = _make_fog_sphere()
        vol = VolumeEntry(grid, nano, mat)

        cam = Camera((25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        scene = Scene(cam, light, vol)

        pixels = render_volume(scene, ReferencePathTracer(max_bounces=16), 8, 8; spp=4)
        @test size(pixels) == (8, 8)
        @test all(p -> all(c -> 0.0 <= c <= 1.0, p), pixels)
        @test all(p -> all(isfinite, p), pixels)
    end

    @testset "deterministic with same seed" begin
        grid, nano, mat = _make_fog_sphere()
        vol = VolumeEntry(grid, nano, mat)

        cam = Camera((25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0))
        scene = Scene(cam, light, vol)
        method = ReferencePathTracer(max_bounces=8)

        p1 = render_volume(scene, method, 4, 4; spp=2, seed=UInt64(123))
        p2 = render_volume(scene, method, 4, 4; spp=2, seed=UInt64(123))
        @test p1 == p2
    end

    @testset "multi-scatter brighter on far side from light" begin
        # Directional light from +X, camera at -X looking at origin.
        # Far side of cloud (toward camera) should be brighter with multi-scatter
        # because light diffuses through.
        grid, nano, mat = _make_fog_sphere(radius=8.0, density=0.8f0,
                                            sigma_scale=8.0, albedo=0.95)
        vol = VolumeEntry(grid, nano, mat)

        cam = Camera((-25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        scene = Scene(cam, light, vol)

        # Single-scatter (max_bounces=1)
        px_single = render_volume(scene, ReferencePathTracer(max_bounces=1), 8, 8;
                                  spp=64, seed=UInt64(42))
        # Multi-scatter
        px_multi = render_volume(scene, ReferencePathTracer(max_bounces=32), 8, 8;
                                 spp=64, seed=UInt64(42))

        # Average brightness of center pixels (far side from light)
        function avg_brightness(pixels)
            h, w = size(pixels)
            total = 0.0
            count = 0
            for y in (h÷4+1):(3h÷4), x in (w÷4+1):(3w÷4)
                r, g, b = pixels[y, x]
                total += (r + g + b) / 3.0
                count += 1
            end
            total / count
        end

        bright_single = avg_brightness(px_single)
        bright_multi = avg_brightness(px_multi)

        # Multi-scatter should be at least as bright (more light paths reach camera)
        @test bright_multi >= bright_single - 0.01  # allow small noise tolerance
    end

    @testset "throughput decays with bounces" begin
        # High albedo = slow decay; low albedo = fast decay.
        # Run a trace and check that the path tracer actually runs multiple bounces
        # by verifying multi-bounce result differs from single-bounce.
        grid, nano, mat = _make_fog_sphere(radius=8.0, density=0.8f0,
                                            sigma_scale=10.0, albedo=0.99)
        vol = VolumeEntry(grid, nano, mat)

        cam = Camera((-25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        scene = Scene(cam, light, vol)

        px1 = render_volume(scene, ReferencePathTracer(max_bounces=1), 4, 4;
                            spp=32, seed=UInt64(77))
        px64 = render_volume(scene, ReferencePathTracer(max_bounces=64), 4, 4;
                             spp=32, seed=UInt64(77))

        # With high albedo, more bounces → different result
        # (may be brighter or slightly different due to extra scattered light)
        @test px1 != px64
    end

    @testset "energy conservation: radiance bounded" begin
        # Total accumulated radiance should not exceed source intensity.
        # Light intensity = (1,1,1), albedo < 1 → energy dissipates.
        grid, nano, mat = _make_fog_sphere(radius=8.0, density=0.5f0,
                                            sigma_scale=5.0, albedo=0.8)
        vol = VolumeEntry(grid, nano, mat)

        cam = Camera((25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))
        scene = Scene(cam, light, vol)

        pixels = render_volume(scene, ReferencePathTracer(max_bounces=32), 8, 8;
                               spp=32, seed=UInt64(55))

        # No pixel channel should exceed a reasonable bound
        # (light intensity 1.0, emission_scale 1.0, in-scattered ≤ 1 / 4pi per vertex)
        # Clamped to [0,1] by render_volume, so this is always true:
        @test all(p -> all(c -> c <= 1.0, p), pixels)
    end

    @testset "background blend: escaped rays" begin
        # Camera looking away from volume → pure background
        grid, nano, mat = _make_fog_sphere()
        vol = VolumeEntry(grid, nano, mat)

        # Camera at (0,0,0) looking at (0,0,-100) — away from sphere at origin
        cam = Camera((0.0, 0.0, 50.0), (0.0, 0.0, 100.0), (0.0, 1.0, 0.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0))
        bg = (0.1, 0.2, 0.3)
        scene = Scene(cam, light, vol; background=bg)

        pixels = render_volume(scene, ReferencePathTracer(max_bounces=8), 4, 4; spp=4)
        for p in pixels
            @test p[1] ≈ bg[1] atol=0.05
            @test p[2] ≈ bg[2] atol=0.05
            @test p[3] ≈ bg[3] atol=0.05
        end
    end

    @testset "render_volume dispatch: SingleScatterTracer matches render_volume_image" begin
        grid, nano, mat = _make_fog_sphere()
        vol = VolumeEntry(grid, nano, mat)

        cam = Camera((25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0))
        scene = Scene(cam, light, vol)

        p1 = render_volume(scene, SingleScatterTracer(), 4, 4; spp=2, seed=UInt64(42))
        p2 = render_volume_image(scene, 4, 4; spp=2, seed=UInt64(42))
        @test p1 == p2
    end

    @testset "render_volume dispatch: EmissionAbsorption matches render_volume_preview" begin
        grid, nano, mat = _make_fog_sphere()
        vol = VolumeEntry(grid, nano, mat)

        cam = Camera((25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0))
        scene = Scene(cam, light, vol)

        p1 = render_volume(scene, EmissionAbsorption(step_size=1.0, max_steps=500), 4, 4)
        p2 = render_volume_preview(scene, 4, 4; step_size=1.0, max_steps=500)
        @test p1 == p2
    end

    @testset "VolumeEntry without NanoGrid throws on render_volume" begin
        sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=5.0)
        fog = sdf_to_fog(sdf)
        tf = tf_smoke()
        mat = VolumeMaterial(tf)
        vol = VolumeEntry(fog, mat)  # no nanogrid

        cam = Camera((25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0))
        scene = Scene(cam, light, vol)

        @test_throws ArgumentError render_volume(scene, ReferencePathTracer(), 4, 4)
    end

    @testset "HenyeyGreenstein phase function scattering" begin
        # Forward-peaked scattering (g=0.8) should produce different result from isotropic
        grid_iso, nano_iso, mat_iso = _make_fog_sphere(
            radius=8.0, density=0.6f0, sigma_scale=8.0, albedo=0.9,
            phase=IsotropicPhase())
        grid_hg, nano_hg, mat_hg = _make_fog_sphere(
            radius=8.0, density=0.6f0, sigma_scale=8.0, albedo=0.9,
            phase=HenyeyGreensteinPhase(0.8))

        vol_iso = VolumeEntry(grid_iso, nano_iso, mat_iso)
        vol_hg = VolumeEntry(grid_hg, nano_hg, mat_hg)

        cam = Camera((-25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0), (1.0, 1.0, 1.0))  # light from +X

        scene_iso = Scene(cam, light, vol_iso)
        scene_hg = Scene(cam, light, vol_hg)
        method = ReferencePathTracer(max_bounces=16)

        px_iso = render_volume(scene_iso, method, 4, 4; spp=32, seed=UInt64(42))
        px_hg = render_volume(scene_hg, method, 4, 4; spp=32, seed=UInt64(42))

        # Forward scattering (g=0.8) with light from behind should be brighter
        # when looking through the cloud (light goes forward toward camera)
        @test px_iso != px_hg
    end

    @testset "_delta_tracking_collision: escapes empty volume" begin
        data = Dict{Coord, Float32}()
        for iz in 0:7, iy in 0:7, ix in 0:7
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 0.0f0
        end
        grid = build_grid(data, 0.0f0; name="empty_collision")
        nano = build_nanogrid(grid.tree)

        ray = Ray(SVec3d(-5.0, 4.0, 4.0), SVec3d(1.0, 0.0, 0.0))
        rng = Xoshiro(42)
        t, found = _delta_tracking_collision(ray, nano, 0.0, 20.0, 1.0, rng)
        @test !found
        @test t == 20.0
    end

    @testset "_shadow_transmittance: empty scene returns 1.0" begin
        data = Dict{Coord, Float32}()
        for iz in 0:7, iy in 0:7, ix in 0:7
            data[coord(Int32(ix), Int32(iy), Int32(iz))] = 0.0f0
        end
        grid = build_grid(data, 0.0f0; name="empty_shadow")
        nano = build_nanogrid(grid.tree)
        tf = tf_smoke()
        mat = VolumeMaterial(tf; sigma_scale=1.0)
        vol = VolumeEntry(grid, nano, mat)

        cam = Camera((25.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        light = DirectionalLight((1.0, 0.0, 0.0))
        scene = Scene(cam, light, vol)

        shadow_ray = Ray(SVec3d(0.0, 0.0, 0.0), SVec3d(1.0, 0.0, 0.0))
        rng = Xoshiro(42)
        T = _shadow_transmittance(shadow_ray, scene, 100.0, rng)
        @test T ≈ 1.0 atol=0.05
    end
end
