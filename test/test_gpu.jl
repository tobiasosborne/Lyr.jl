# Test GPU delta tracking kernel on KernelAbstractions CPU backend
using Test
using Lyr

# Internal symbols needed for testing
import Lyr: _gpu_get_value, _gpu_get_value_trilinear,
             _gpu_buf_mask_is_on, _gpu_buf_count_on_before,
             _gpu_buf_load, _gpu_ray_box_intersect, _gpu_xorshift, _gpu_wang_hash,
             _bake_tf_lut, _estimate_density_range,
             gpu_volume_march_cpu!, _gpu_hg_eval,
             _gpu_read_light, _gpu_light_contribution,
             _gpu_hg_sample_cos_theta, _gpu_build_basis, _gpu_sample_scatter,
             _I2_CMASK_OFF, _I2_VMASK_OFF, _I2_CPREFIX_OFF, _I2_VPREFIX_OFF,
             _I2_CHILDCOUNT_OFF, _I2_DATA_OFF,
             _I1_CMASK_OFF, _I1_VMASK_OFF, _I1_CPREFIX_OFF, _I1_VPREFIX_OFF,
             _I1_CHILDCOUNT_OFF, _I1_DATA_OFF,
             _LEAF_VMASK_OFF, _LEAF_VALUES_OFF

@testset "GPU Kernel" begin
    @testset "_gpu_get_value correctness vs NanoValueAccessor" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end
        vdb = parse_vdb(cube_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)
        acc = NanoValueAccessor(nanogrid)
        buf = nanogrid.buffer
        bg = Float32(nano_background(nanogrid))
        header_T_size = Int32(sizeof(eltype(grid.tree.background)))

        # Test random coordinates inside the active bounding box
        bbox = nano_bbox(nanogrid)
        for _ in 1:200
            x = Int32(rand(bbox.min.x:bbox.max.x))
            y = Int32(rand(bbox.min.y:bbox.max.y))
            z = Int32(rand(bbox.min.z:bbox.max.z))
            expected = Float32(get_value(acc, coord(x, y, z)))
            actual = _gpu_get_value(buf, bg, x, y, z, header_T_size)
            @test actual == expected
        end

        # Test coordinates outside bounds (should return background)
        for off in [Int32(1000), Int32(-1000)]
            val = _gpu_get_value(buf, bg, off, off, off, header_T_size)
            @test val == bg
        end
    end

    @testset "_gpu_get_value correctness with smoke volume" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
        vdb = parse_vdb(smoke_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)
        acc = NanoValueAccessor(nanogrid)
        buf = nanogrid.buffer
        bg = Float32(nano_background(nanogrid))
        header_T_size = Int32(sizeof(eltype(grid.tree.background)))

        bbox = nano_bbox(nanogrid)
        for _ in 1:200
            x = Int32(rand(bbox.min.x:bbox.max.x))
            y = Int32(rand(bbox.min.y:bbox.max.y))
            z = Int32(rand(bbox.min.z:bbox.max.z))
            expected = Float32(get_value(acc, coord(x, y, z)))
            actual = _gpu_get_value(buf, bg, x, y, z, header_T_size)
            @test actual == expected
        end
    end

    @testset "_gpu_get_value_trilinear: smooth interpolation" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end
        vdb = parse_vdb(cube_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)
        buf = nanogrid.buffer
        bg = Float32(nano_background(nanogrid))
        header_T_size = Int32(sizeof(eltype(grid.tree.background)))

        # At integer coordinates, trilinear should equal nearest-neighbor
        bbox = nano_bbox(nanogrid)
        for _ in 1:50
            x = Int32(rand((bbox.min.x + 1):(bbox.max.x - 1)))
            y = Int32(rand((bbox.min.y + 1):(bbox.max.y - 1)))
            z = Int32(rand((bbox.min.z + 1):(bbox.max.z - 1)))
            nn = _gpu_get_value(buf, bg, x, y, z, header_T_size)
            tri = _gpu_get_value_trilinear(buf, bg, Float32(x), Float32(y), Float32(z), header_T_size)
            @test tri ≈ nn atol=1e-6
        end

        # At fractional coordinates, trilinear should be between neighbors
        for _ in 1:50
            x = Float32(rand((bbox.min.x + 1):(bbox.max.x - 2))) + rand(Float32)
            y = Float32(rand((bbox.min.y + 1):(bbox.max.y - 2))) + rand(Float32)
            z = Float32(rand((bbox.min.z + 1):(bbox.max.z - 2))) + rand(Float32)
            val = _gpu_get_value_trilinear(buf, bg, x, y, z, header_T_size)
            @test isfinite(val)
        end
    end

    @testset "_gpu_ray_box_intersect" begin
        # Ray along +z through box centered at origin
        # origin = (0,0,-10), direction = (0,0,1), inv_dir = (Inf,Inf,1)
        t_enter, t_exit = _gpu_ray_box_intersect(
            0.0f0, 0.0f0, -10.0f0,     # origin
            Inf32, Inf32, 1.0f0,        # inv_dir
            -5.0f0, -5.0f0, -5.0f0,    # box min
            5.0f0, 5.0f0, 5.0f0,       # box max
        )
        @test t_enter < t_exit   # should hit
        @test t_enter ≈ 5.0f0    # enters at z=-5, t = (-5 - -10) * 1 = 5
        @test t_exit ≈ 15.0f0    # exits at z=5, t = (5 - -10) * 1 = 15

        # Ray completely missing box
        t_enter2, t_exit2 = _gpu_ray_box_intersect(
            100.0f0, 100.0f0, 0.0f0,   # origin far off axis
            Inf32, Inf32, 1.0f0,        # inv_dir along +z
            -5.0f0, -5.0f0, -5.0f0,
            5.0f0, 5.0f0, 5.0f0,
        )
        @test t_enter2 >= t_exit2  # miss
    end

    @testset "_gpu_xorshift produces valid range" begin
        state = UInt32(12345)
        for _ in 1:100
            val, state = _gpu_xorshift(state)
            @test 0.0f0 <= val < 1.0f0
            @test state != UInt32(0)  # xorshift should never reach 0
        end
    end

    @testset "_gpu_wang_hash decorrelation" begin
        # Different seeds should produce different hashes
        h1 = _gpu_wang_hash(UInt32(1))
        h2 = _gpu_wang_hash(UInt32(2))
        h3 = _gpu_wang_hash(UInt32(3))
        @test h1 != h2
        @test h2 != h3
        @test h1 != h3
    end

    @testset "_bake_tf_lut produces 1024 entries" begin
        tf = tf_smoke()
        lut = _bake_tf_lut(tf, 0.0, 1.0)
        @test length(lut) == 1024
        @test all(isfinite, lut)
    end

    @testset "gpu_render_volume: smoke test on CPU backend" begin
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
        light = DirectionalLight((0.577, 0.577, 0.577))
        scene = Scene(cam, light, vol)

        pixels = gpu_render_volume(nanogrid, scene, 16, 16; spp=1)

        @test size(pixels) == (16, 16)
        @test all(p -> all(c -> 0.0f0 <= c <= 1.0f0, p), pixels)
        @test all(p -> all(isfinite, p), pixels)
    end

    @testset "gpu_render_volume: multi-spp convergence" begin
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
        light = DirectionalLight((0.577, 0.577, 0.577))
        scene = Scene(cam, light, vol)

        # Higher spp should still produce valid output
        pixels = gpu_render_volume(nanogrid, scene, 8, 8; spp=4, seed=UInt64(123))

        @test size(pixels) == (8, 8)
        @test all(p -> all(c -> 0.0f0 <= c <= 1.0f0, p), pixels)
        @test all(p -> all(isfinite, p), pixels)
    end

    @testset "gpu_render_volume: deterministic with same seed" begin
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

        p1 = gpu_render_volume(nanogrid, scene, 4, 4; spp=1, seed=UInt64(42))
        p2 = gpu_render_volume(nanogrid, scene, 4, 4; spp=1, seed=UInt64(42))
        @test p1 == p2
    end

    @testset "gpu_render_volume: cube.vdb smoke test" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end
        vdb = parse_vdb(cube_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)

        cam = Camera((50.0, 50.0, -100.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 60.0)
        tf = tf_smoke()
        mat = VolumeMaterial(tf; sigma_scale=1.0)
        vol = VolumeEntry(grid, nanogrid, mat)
        light = DirectionalLight((0.577, 0.577, 0.577))
        scene = Scene(cam, light, vol)

        pixels = gpu_render_volume(nanogrid, scene, 8, 8; spp=1)
        @test size(pixels) == (8, 8)
        @test all(p -> all(isfinite, p), pixels)
    end

    @testset "gpu_volume_march_cpu! uses scene background color" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end
        vdb = parse_vdb(cube_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)
        tf = tf_smoke()

        # Camera pointing away from the volume — all rays miss
        cam = Camera((1000.0, 1000.0, 1000.0), (2000.0, 2000.0, 2000.0),
                     (0.0, 1.0, 0.0), 40.0)

        bg = (0.3, 0.5, 0.7)
        output = Matrix{NTuple{3, Float32}}(undef, 4, 4)
        gpu_volume_march_cpu!(output, nanogrid, cam, tf, 4, 4;
                              background=bg)

        # All pixels should be the background color (transmittance=1.0 for miss rays)
        for px in output
            @test px[1] ≈ Float32(0.3) atol=0.01
            @test px[2] ≈ Float32(0.5) atol=0.01
            @test px[3] ≈ Float32(0.7) atol=0.01
        end

        # Default background should be black
        gpu_volume_march_cpu!(output, nanogrid, cam, tf, 4, 4)
        for px in output
            @test px == (0.0f0, 0.0f0, 0.0f0)
        end
    end

    @testset "_gpu_hg_eval: matches CPU PhaseFunction" begin
        # g=0: isotropic — should be 1/(4π) for any cos_theta
        inv4pi = Float32(1.0 / (4π))
        for ct in Float32[-1.0, -0.5, 0.0, 0.5, 1.0]
            @test _gpu_hg_eval(0.0f0, ct) ≈ inv4pi atol=1.0f-6
        end
        # Match CPU HenyeyGreensteinPhase for various g values
        for g in [0.3, 0.6, 0.8, 0.95, -0.5]
            cpu_pf = HenyeyGreensteinPhase(Float64(g))
            for ct in [-1.0, -0.5, 0.0, 0.5, 0.99]
                cpu_val = Float32(evaluate(cpu_pf, Float64(ct)))
                gpu_val = _gpu_hg_eval(Float32(g), Float32(ct))
                @test gpu_val ≈ cpu_val rtol=1.0f-4
            end
        end
        # Forward scattering (g>0) peaks at cos_theta=1
        @test _gpu_hg_eval(0.8f0, 1.0f0) > _gpu_hg_eval(0.8f0, 0.0f0)
        @test _gpu_hg_eval(0.8f0, 0.0f0) > _gpu_hg_eval(0.8f0, -1.0f0)
        # Backward scattering (g<0) peaks at cos_theta=-1
        @test _gpu_hg_eval(-0.8f0, -1.0f0) > _gpu_hg_eval(-0.8f0, 0.0f0)
    end

    @testset "gpu_render_volume: HG phase g=0 matches isotropic" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
        vdb = parse_vdb(smoke_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)
        cam = Camera((150.0, 50.0, 150.0), (50.0, 50.0, 50.0), (0.0, 1.0, 0.0), 60.0)
        light = DirectionalLight((0.577, 0.577, 0.577))

        # IsotropicPhase (default) — g=0
        mat_iso = VolumeMaterial(tf_smoke(); sigma_scale=5.0)
        scene_iso = Scene(cam, light, VolumeEntry(grid, nanogrid, mat_iso))

        # HenyeyGreensteinPhase with g=0 — should be identical
        mat_hg0 = VolumeMaterial(tf_smoke(); sigma_scale=5.0, phase_function=HenyeyGreensteinPhase(0.0))
        scene_hg0 = Scene(cam, light, VolumeEntry(grid, nanogrid, mat_hg0))

        seed = UInt64(42)
        # Test both kernels
        for hdda in [false, true]
            p_iso = gpu_render_volume(nanogrid, scene_iso, 8, 8; spp=1, seed=seed, hdda=hdda)
            p_hg0 = gpu_render_volume(nanogrid, scene_hg0, 8, 8; spp=1, seed=seed, hdda=hdda)
            @test p_iso == p_hg0
        end
    end

    @testset "gpu_render_volume: HG phase g=0.8 forward scattering" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
        vdb = parse_vdb(smoke_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)

        # Camera looking toward the light (forward scattering should be bright)
        light_dir = (0.577, 0.577, 0.577)
        # Camera behind the volume, looking in light direction
        cam_fwd = Camera((150.0, 50.0, 150.0), (50.0, 50.0, 50.0), (0.0, 1.0, 0.0), 60.0)
        light = DirectionalLight(light_dir)

        mat_iso = VolumeMaterial(tf_smoke(); sigma_scale=5.0, scattering_albedo=0.9, emission_scale=3.0)
        mat_hg = VolumeMaterial(tf_smoke(); sigma_scale=5.0, scattering_albedo=0.9, emission_scale=3.0,
                                phase_function=HenyeyGreensteinPhase(0.8))

        scene_iso = Scene(cam_fwd, light, VolumeEntry(grid, nanogrid, mat_iso))
        scene_hg = Scene(cam_fwd, light, VolumeEntry(grid, nanogrid, mat_hg))

        p_iso = gpu_render_volume(nanogrid, scene_iso, 8, 8; spp=4, seed=UInt64(99))
        p_hg = gpu_render_volume(nanogrid, scene_hg, 8, 8; spp=4, seed=UInt64(99))

        # With HG g=0.8, pixels should differ from isotropic
        @test p_iso != p_hg
        # Both should produce valid output
        @test all(p -> all(c -> 0.0f0 <= c <= 1.0f0, p), p_hg)
        @test all(p -> all(isfinite, p), p_hg)
    end

    @testset "_gpu_read_light: round-trip packing" begin
        # Directional light
        buf = Float32[0.0, 0.577, 0.577, 0.577, 1.0, 0.8, 0.6]
        ltype, lx, ly, lz, lr, lg, lb = _gpu_read_light(buf, Int32(1))
        @test ltype == 0.0f0
        @test lx ≈ 0.577f0
        @test lr ≈ 1.0f0
        # Point light (2nd entry)
        buf2 = Float32[0.0, 0.577, 0.577, 0.577, 1.0, 0.8, 0.6,
                        1.0, 100.0, 50.0, 200.0, 2.0, 1.5, 1.0]
        ltype2, lx2, ly2, lz2, lr2, lg2, lb2 = _gpu_read_light(buf2, Int32(2))
        @test ltype2 == 1.0f0
        @test lx2 == 100.0f0
        @test lr2 == 2.0f0
    end

    @testset "_gpu_light_contribution: directional vs point" begin
        # Directional light: fixed direction, no falloff
        buf = Float32[0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0]
        ldx, ldy, ldz, lr, lg, lb, ldist = _gpu_light_contribution(buf, Int32(1), 0.0f0, 0.0f0, 0.0f0)
        @test ldx == 0.0f0
        @test ldz == 1.0f0
        @test lr == 1.0f0
        @test isinf(ldist)

        # Point light: direction from scatter point to light, 1/r² falloff
        buf2 = Float32[1.0, 100.0, 0.0, 0.0, 4.0, 4.0, 4.0]
        ldx, ldy, ldz, lr, lg, lb, ldist = _gpu_light_contribution(buf2, Int32(1), 0.0f0, 0.0f0, 0.0f0)
        @test ldx ≈ 1.0f0 atol=1.0f-5  # pointing toward light at x=100
        @test ldy ≈ 0.0f0 atol=1.0f-5
        @test ldist ≈ 100.0f0 atol=1.0f-3
        @test lr ≈ 4.0f0 / 10000.0f0 atol=1.0f-5  # intensity * 1/r² = 4/10000
    end

    @testset "gpu_render_volume: multi-light (directional + point)" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
        vdb = parse_vdb(smoke_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)
        cam = Camera((150.0, 50.0, 150.0), (50.0, 50.0, 50.0), (0.0, 1.0, 0.0), 60.0)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, scattering_albedo=0.9, emission_scale=3.0)

        # Scene with 1 directional light
        scene1 = Scene(cam, [DirectionalLight((0.577, 0.577, 0.577))],
                       [VolumeEntry(grid, nanogrid, mat)])

        # Scene with 2 lights (directional + point)
        scene2 = Scene(cam, [DirectionalLight((0.577, 0.577, 0.577)),
                             PointLight((200.0, 50.0, 100.0), (5.0, 5.0, 5.0))],
                       [VolumeEntry(grid, nanogrid, mat)])

        seed = UInt64(77)
        p1 = gpu_render_volume(nanogrid, scene1, 8, 8; spp=2, seed=seed)
        p2 = gpu_render_volume(nanogrid, scene2, 8, 8; spp=2, seed=seed)

        # Two-light render should differ from single-light
        @test p1 != p2
        # Both should be valid
        @test all(p -> all(c -> 0.0f0 <= c <= 1.0f0, p), p1)
        @test all(p -> all(c -> 0.0f0 <= c <= 1.0f0, p), p2)
        @test all(p -> all(isfinite, p), p2)
    end

    @testset "_gpu_hg_sample_cos_theta: range and isotropy" begin
        # g=0: should produce uniform cos_theta in [-1, 1]
        for xi in Float32[0.0, 0.25, 0.5, 0.75, 1.0]
            ct = _gpu_hg_sample_cos_theta(0.0f0, xi)
            @test -1.0f0 <= ct <= 1.0f0
        end
        # xi=0.5 with g=0 should give cos_theta=0
        @test _gpu_hg_sample_cos_theta(0.0f0, 0.5f0) ≈ 0.0f0 atol=1.0f-5
        # g=0.8: forward scattering peak — xi near 0 gives cos_theta near 1
        ct_fwd = _gpu_hg_sample_cos_theta(0.8f0, 0.01f0)
        @test ct_fwd > 0.5f0
    end

    @testset "_gpu_build_basis: orthonormality" begin
        for (wx, wy, wz) in [(1.0f0, 0.0f0, 0.0f0), (0.0f0, 1.0f0, 0.0f0),
                              (0.577f0, 0.577f0, 0.577f0)]
            tx, ty, tz, bx, by, bz = _gpu_build_basis(wx, wy, wz)
            # t · w ≈ 0
            @test abs(tx*wx + ty*wy + tz*wz) < 2.0f-3
            # b · w ≈ 0
            @test abs(bx*wx + by*wy + bz*wz) < 2.0f-3
            # t · b ≈ 0
            @test abs(tx*bx + ty*by + tz*bz) < 2.0f-3
            # |t| ≈ 1
            @test sqrt(tx^2 + ty^2 + tz^2) ≈ 1.0f0 atol=2.0f-3
        end
    end

    @testset "_gpu_sample_scatter: unit direction" begin
        for g in Float32[0.0, 0.5, 0.8, -0.3]
            rng = UInt32(12345)
            ndx, ndy, ndz, _ = _gpu_sample_scatter(0.0f0, 0.0f0, 1.0f0, g, rng)
            len = sqrt(ndx^2 + ndy^2 + ndz^2)
            @test len ≈ 1.0f0 atol=1.0f-4
        end
    end

    @testset "gpu_render_volume: multi-bounce (max_bounces > 0)" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
        vdb = parse_vdb(smoke_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)
        cam = Camera((150.0, 50.0, 150.0), (50.0, 50.0, 50.0), (0.0, 1.0, 0.0), 60.0)
        light = DirectionalLight((0.577, 0.577, 0.577))
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, scattering_albedo=0.9, emission_scale=3.0)
        scene = Scene(cam, light, VolumeEntry(grid, nanogrid, mat))

        seed = UInt64(42)
        # Single-scatter (default)
        p0 = gpu_render_volume(nanogrid, scene, 8, 8; spp=2, seed=seed, max_bounces=0)
        # Multi-bounce
        p8 = gpu_render_volume(nanogrid, scene, 8, 8; spp=2, seed=seed, max_bounces=8)

        # Multi-bounce should differ from single-scatter (more light reaches camera)
        @test p0 != p8
        # Both valid
        @test all(p -> all(c -> 0.0f0 <= c <= 1.0f0, p), p0)
        @test all(p -> all(c -> 0.0f0 <= c <= 1.0f0, p), p8)
        @test all(p -> all(isfinite, p), p8)

        # Also test HDDA path
        p8_hdda = gpu_render_volume(nanogrid, scene, 8, 8; spp=2, seed=seed, max_bounces=8, hdda=true)
        @test all(p -> all(c -> 0.0f0 <= c <= 1.0f0, p), p8_hdda)
        @test all(p -> all(isfinite, p), p8_hdda)
    end

    @testset "gpu_render_multi_volume: 2 volumes" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @test_skip "fixture not found: $smoke_path"
            return
        end
        vdb = parse_vdb(smoke_path)
        grid = vdb.grids[1]
        nanogrid = build_nanogrid(grid.tree)
        cam = Camera((150.0, 50.0, 150.0), (50.0, 50.0, 50.0), (0.0, 1.0, 0.0), 60.0)
        mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0)
        light = DirectionalLight((0.577, 0.577, 0.577))
        vol1 = VolumeEntry(grid, nanogrid, mat)
        vol2 = VolumeEntry(grid, nanogrid, mat)
        scene = Scene(cam, [light], [vol1, vol2])
        img = gpu_render_multi_volume(scene, 8, 8; spp=1)
        @test size(img) == (8, 8)
        @test all(p -> all(isfinite, p), img)
        @test all(p -> all(c -> 0.0f0 <= c <= 1.0f0, p), img)
    end

    @testset "gpu_gr_render: Schwarzschild shadow + disk" begin
        # Camera at r=30, equatorial, looking at BH with thin disk
        img = gpu_gr_render(1.0, 30.0, π/2, 0.0, 60.0, 16, 16;
                             disk_inner=6.0, disk_outer=20.0,
                             max_steps=5000, step_size=-0.3)
        @test size(img) == (16, 16)
        @test all(p -> all(isfinite, p), img)
        # Should have some black pixels (BH shadow) and some bright (disk/sky)
        n_black = count(p -> p[1] < 0.01 && p[2] < 0.01 && p[3] < 0.01, img)
        n_bright = count(p -> p[1] > 0.01 || p[2] > 0.01 || p[3] > 0.01, img)
        @test n_black > 0   # BH shadow exists
        @test n_bright > 0  # visible disk/sky
    end

    @testset "gpu_gr_render: no disk — checkerboard sky" begin
        img = gpu_gr_render(1.0, 30.0, π/2, 0.0, 40.0, 8, 8;
                             max_steps=3000, step_size=-0.5)
        @test size(img) == (8, 8)
        @test all(p -> all(isfinite, p), img)
        # All rays should either escape (sky color) or fall in (black)
        # Checkerboard has values ~0.15 or ~0.9
        n_sky = count(p -> p[1] > 0.1, img)
        @test n_sky > 0
    end

    @testset "gpu_gr_render: redshift changes disk colors" begin
        # Same scene with and without redshift — colors should differ
        args = (1.0, 30.0, π/2, 0.0, 60.0, 8, 8)
        kwargs = (disk_inner=6.0, disk_outer=20.0, max_steps=5000, step_size=-0.3)
        img_rs = gpu_gr_render(args...; kwargs..., use_redshift=true)
        img_no = gpu_gr_render(args...; kwargs..., use_redshift=false)
        @test img_rs != img_no  # redshift modifies colors
        @test all(p -> all(isfinite, p), img_rs)
    end

    @testset "gpu_gr_render: Minkowski limit (M=0) — no lensing" begin
        # M=0: flat space, no bending, all rays escape
        img = gpu_gr_render(0.0, 30.0, π/2, 0.0, 40.0, 8, 8;
                             max_steps=1000, step_size=-0.5, r_max=100.0)
        @test size(img) == (8, 8)
        @test all(p -> all(isfinite, p), img)
        # No black hole → no black pixels (all rays escape to sky)
        n_black = count(p -> p[1] == 0.0 && p[2] == 0.0 && p[3] == 0.0, img)
        @test n_black == 0
    end
end
