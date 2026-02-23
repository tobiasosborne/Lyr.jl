# Test GPU delta tracking kernel on KernelAbstractions CPU backend
using Test
using Lyr

# Internal symbols needed for testing
import Lyr: _gpu_get_value, _gpu_get_value_trilinear,
             _gpu_buf_mask_is_on, _gpu_buf_count_on_before,
             _gpu_buf_load, _gpu_ray_box_intersect, _gpu_xorshift, _gpu_wang_hash,
             _bake_tf_lut, _estimate_density_range,
             gpu_volume_march_cpu!,
             _I2_CMASK_OFF, _I2_VMASK_OFF, _I2_CPREFIX_OFF, _I2_VPREFIX_OFF,
             _I2_CHILDCOUNT_OFF, _I2_DATA_OFF,
             _I1_CMASK_OFF, _I1_VMASK_OFF, _I1_CPREFIX_OFF, _I1_VPREFIX_OFF,
             _I1_CHILDCOUNT_OFF, _I1_DATA_OFF,
             _LEAF_VMASK_OFF, _LEAF_VALUES_OFF

@testset "GPU Kernel" begin
    @testset "_gpu_get_value correctness vs NanoValueAccessor" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if isfile(cube_path)
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
    end

    @testset "_gpu_get_value correctness with smoke volume" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if isfile(smoke_path)
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
    end

    @testset "_gpu_get_value_trilinear: smooth interpolation" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if isfile(cube_path)
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
        if isfile(smoke_path)
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
    end

    @testset "gpu_render_volume: multi-spp convergence" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if isfile(smoke_path)
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
    end

    @testset "gpu_render_volume: deterministic with same seed" begin
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

            p1 = gpu_render_volume(nanogrid, scene, 4, 4; spp=1, seed=UInt64(42))
            p2 = gpu_render_volume(nanogrid, scene, 4, 4; spp=1, seed=UInt64(42))
            @test p1 == p2
        end
    end

    @testset "gpu_render_volume: cube.vdb smoke test" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if isfile(cube_path)
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
    end

    @testset "gpu_volume_march_cpu! uses scene background color" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if isfile(cube_path)
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
    end
end
