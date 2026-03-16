# Test volume renderer — delta tracking, ratio tracking, single scatter
using Test
using Lyr
using Random: Xoshiro

@testset "Volume Renderer" begin
    @testset "ratio_tracking: empty volume returns 1.0" begin
        # Build a NanoGrid with all-zero density (background = 0)
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end
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

    @testset "delta_tracking_step: escapes empty volume" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end
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

    @testset "Preview renderer: produces valid output" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
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

    @testset "Single-scatter renderer: produces valid output" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
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

    @testset "Single-scatter renderer: deterministic with same seed" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
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

    @testset "Multi-volume: escaped first volume still tests second" begin
        # Regression: `break` on :escaped skipped subsequent volumes.
        # Volume 1: zero density + very low sigma (ray escapes in ~1 step)
        # Volume 2: 16^3 at z=24..39, density=0.3 (bright in tf_smoke)
        empty_data = Dict{Coord, Float32}()
        for iz in 0:7, iy in 0:7, ix in 0:7
            empty_data[coord(Int32(ix), Int32(iy), Int32(iz))] = 0.0f0
        end
        empty_grid = build_grid(empty_data, 0.0f0; name="empty")
        empty_nano = build_nanogrid(empty_grid.tree)

        dense_data = Dict{Coord, Float32}()
        for iz in 24:39, iy in 0:15, ix in 0:15
            dense_data[coord(Int32(ix), Int32(iy), Int32(iz))] = 0.3f0
        end
        dense_grid = build_grid(dense_data, 0.0f0; name="dense")
        dense_nano = build_nanogrid(dense_grid.tree)

        cam = Camera((8.0, 8.0, -10.0), (8.0, 8.0, 30.0), (0.0, 1.0, 0.0), 60.0)
        tf = tf_smoke()
        mat_dense = VolumeMaterial(tf; sigma_scale=20.0, emission_scale=5.0)
        # Low sigma_scale → large free-flight steps → fast escape, minimal RNG consumed
        mat_empty = VolumeMaterial(tf; sigma_scale=0.01, emission_scale=1.0)

        vol_empty = VolumeEntry(empty_grid, empty_nano, mat_empty)
        vol_dense = VolumeEntry(dense_grid, dense_nano, mat_dense)
        light = DirectionalLight((0.0, 1.0, 0.0))

        scene_only = Scene(cam, [light], [vol_dense]; background=(0.0, 0.0, 0.0))
        scene_both = Scene(cam, [light], [vol_empty, vol_dense]; background=(0.0, 0.0, 0.0))

        px_only = render_volume_image(scene_only, 4, 4; spp=128, seed=UInt64(999))
        px_both = render_volume_image(scene_both, 4, 4; spp=128, seed=UInt64(999))

        any_nonzero = any(any(c -> c > 0.001, p) for p in px_only)
        @test any_nonzero  # sanity: dense volume alone produces light

        # With the fix, multi-volume also reaches the dense volume
        any_nonzero_both = any(any(c -> c > 0.001, p) for p in px_both)
        @test any_nonzero_both
    end

    @testset "VolumeEntry without NanoGrid throws on render" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end
        vdb = parse_vdb(cube_path)
        grid = vdb.grids[1]
        tf = tf_smoke()
        mat = VolumeMaterial(tf; sigma_scale=1.0)
        vol = VolumeEntry(grid, mat)  # nanogrid = nothing

        cam = Camera((10.0, 5.0, 10.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 60.0)
        light = DirectionalLight((0.577, 0.577, 0.577))
        scene = Scene(cam, light, vol)

        @test_throws ArgumentError render_volume_preview(scene, 4, 4)
        @test_throws ArgumentError render_volume_image(scene, 4, 4; spp=1)
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
