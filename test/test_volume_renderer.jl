# Test volume renderer — delta tracking, ratio tracking, single scatter
using Test
using Lyr
using Random: Xoshiro

@testset "Volume Renderer" begin
    @testset "ratio_tracking: empty volume returns 1.0" begin
        # Build a NanoGrid with all-zero density (background = 0)
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if isfile(cube_path)
            vdb = parse_vdb(cube_path)
            grid = vdb.grids[1]
            nanogrid = build_nanogrid(grid.tree)

            # Ray that doesn't intersect any active voxels
            ray = Ray(SVec3d(1000.0, 1000.0, 1000.0), SVec3d(1.0, 0.0, 0.0))
            rng = Xoshiro(42)

            # Ratio tracking over empty region
            T = ratio_tracking(ray, nanogrid, 0.0, 100.0, 1.0, rng)
            @test T ≈ 1.0 atol=0.1  # should be near 1.0 (no extinction)
        end
    end

    @testset "delta_tracking_step: escapes empty volume" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if isfile(cube_path)
            vdb = parse_vdb(cube_path)
            grid = vdb.grids[1]
            nanogrid = build_nanogrid(grid.tree)

            # Ray through empty region
            ray = Ray(SVec3d(1000.0, 1000.0, 1000.0), SVec3d(1.0, 0.0, 0.0))
            rng = Xoshiro(42)

            t, event = delta_tracking_step(ray, nanogrid, 0.0, 10.0, 1.0, 0.5, rng)
            @test event == :escaped
            @test t == 10.0
        end
    end

    @testset "Preview renderer: produces valid output" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if isfile(smoke_path)
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nanogrid = build_nanogrid(grid.tree)

            cam = Camera((150.0, 50.0, 150.0), (50.0, 50.0, 50.0), (0.0, 1.0, 0.0), 60.0)
            tf = tf_smoke()
            mat = VolumeMaterial(tf; sigma_scale=5.0)
            vol = VolumeEntry(grid, nanogrid, mat)

            scene = Scene(cam, DirectionalLight((0.577, 0.577, 0.577)),
                         vol; background=(0.0, 0.0, 0.0))

            pixels = render_volume_preview(scene, 16, 16; step_size=2.0)
            @test size(pixels) == (16, 16)
            @test all(p -> all(c -> 0.0 <= c <= 1.0, p), pixels)
        end
    end

    @testset "Single-scatter renderer: produces valid output" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if isfile(smoke_path)
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nanogrid = build_nanogrid(grid.tree)

            cam = Camera((150.0, 50.0, 150.0), (50.0, 50.0, 50.0), (0.0, 1.0, 0.0), 60.0)
            tf = tf_smoke()
            mat = VolumeMaterial(tf; sigma_scale=5.0)
            vol = VolumeEntry(grid, nanogrid, mat)
            light = PointLight((200.0, 200.0, 200.0), (50.0, 50.0, 50.0))

            scene = Scene(cam, light, vol)

            pixels = render_volume_image(scene, 8, 8; spp=1)
            @test size(pixels) == (8, 8)
            @test all(p -> all(c -> 0.0 <= c <= 1.0, p), pixels)

            # No NaN or Inf
            @test all(p -> all(isfinite, p), pixels)
        end
    end

    @testset "Single-scatter renderer: deterministic with same seed" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if isfile(smoke_path)
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nanogrid = build_nanogrid(grid.tree)

            cam = Camera((150.0, 50.0, 150.0), (50.0, 50.0, 50.0), (0.0, 1.0, 0.0), 60.0)
            tf = tf_smoke()
            mat = VolumeMaterial(tf; sigma_scale=5.0)
            vol = VolumeEntry(grid, nanogrid, mat)
            scene = Scene(cam, DirectionalLight((0.577, 0.577, 0.577)), vol)

            p1 = render_volume_image(scene, 4, 4; spp=2, seed=UInt64(99))
            p2 = render_volume_image(scene, 4, 4; spp=2, seed=UInt64(99))
            @test p1 == p2
        end
    end

    @testset "Tone mapping round-trip" begin
        pixels = [(0.5, 0.3, 0.8) (1.5, 2.0, 0.1);
                  (0.0, 0.0, 0.0) (0.01, 0.99, 0.5)]

        # Reinhard
        r = tonemap_reinhard(pixels)
        @test all(p -> all(c -> 0.0 <= c <= 1.0, p), r)

        # ACES
        a = tonemap_aces(pixels)
        @test all(p -> all(c -> 0.0 <= c <= 1.0, p), a)

        # Exposure
        e = tonemap_exposure(pixels, 1.5)
        @test all(p -> all(c -> 0.0 <= c <= 1.0, p), e)
    end
end
