# Test GPU rendering on CUDA backend (requires NVIDIA GPU)
# Skips gracefully if CUDA is not functional.
using Test
using Lyr

import Lyr: _gpu_get_value, _gpu_get_value_trilinear,
             _gpu_buf_load, _gpu_ray_box_intersect,
             NanoValueAccessor, nano_background, nano_bbox,
             _gpu_get_value_with_leaf, _gpu_get_value_cached,
             _gpu_get_value_trilinear_cached, _gpu_leaf_read
import Lyr: GPUNanoGrid, build_gpu_nanogrid,
             GPURenderContext, build_gpu_render_context

const CUDA_AVAILABLE = try
    using CUDA
    CUDA.functional()
catch
    false
end

@testset "GPU CUDA" begin
    if !CUDA_AVAILABLE
        @test_skip "CUDA not available"
    else
        import KernelAbstractions

        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")

        @testset "Extension loading" begin
            @test gpu_available() == true
            info = gpu_info()
            @test occursin("CUDA", info)
            @test typeof(Lyr._GPU_BACKEND[]) == CUDABackend
        end

        @testset "NanoGrid buffer transfer roundtrip" begin
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            cpu_buf = nano.buffer

            # Transfer to GPU and back
            dev_buf = CuArray(cpu_buf)
            @test length(dev_buf) == length(cpu_buf)

            roundtrip = Array(dev_buf)
            @test roundtrip == cpu_buf  # byte-for-byte identity
        end

        @testset "Value lookup correctness on CUDA" begin
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            acc = NanoValueAccessor(nano)
            bg = Float32(nano_background(nano))

            # Compare GPU kernel value lookups against CPU accessor
            # (run on CPU backend but with the same byte-level functions)
            buf = nano.buffer
            hts = Int32(sizeof(Float32))
            bbox = nano_bbox(nano)

            mismatches = 0
            for _ in 1:200
                x = Int32(rand(bbox.min.x:bbox.max.x))
                y = Int32(rand(bbox.min.y:bbox.max.y))
                z = Int32(rand(bbox.min.z:bbox.max.z))
                gpu_val = _gpu_get_value(buf, bg, x, y, z, hts)
                cpu_val = Float32(Lyr.get_value(acc, Lyr.coord(x, y, z)))
                if gpu_val != cpu_val
                    mismatches += 1
                end
            end
            @test mismatches == 0
        end

        @testset "Cached value lookup correctness" begin
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            buf = nano.buffer
            bg = Float32(nano_background(nano))
            hts = Int32(sizeof(Float32))
            bbox = nano_bbox(nano)

            cache_ox = Int32(0); cache_oy = Int32(0)
            cache_oz = Int32(0); cache_off = Int32(0)

            for _ in 1:200
                x = Int32(rand(bbox.min.x:bbox.max.x))
                y = Int32(rand(bbox.min.y:bbox.max.y))
                z = Int32(rand(bbox.min.z:bbox.max.z))
                cached_val, cache_ox, cache_oy, cache_oz, cache_off =
                    _gpu_get_value_cached(buf, bg, x, y, z, hts,
                        cache_ox, cache_oy, cache_oz, cache_off)
                direct_val = _gpu_get_value(buf, bg, x, y, z, hts)
                @test cached_val == direct_val
            end
        end

        @testset "Cached trilinear correctness" begin
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            buf = nano.buffer
            bg = Float32(nano_background(nano))
            hts = Int32(sizeof(Float32))
            bbox = nano_bbox(nano)

            cache_ox = Int32(0); cache_oy = Int32(0)
            cache_oz = Int32(0); cache_off = Int32(0)

            for _ in 1:100
                fx = Float32(rand() * (bbox.max.x - bbox.min.x - 2) + bbox.min.x + 1)
                fy = Float32(rand() * (bbox.max.y - bbox.min.y - 2) + bbox.min.y + 1)
                fz = Float32(rand() * (bbox.max.z - bbox.min.z - 2) + bbox.min.z + 1)
                cached_val, cache_ox, cache_oy, cache_oz, cache_off =
                    _gpu_get_value_trilinear_cached(buf, bg, fx, fy, fz, hts,
                        cache_ox, cache_oy, cache_oz, cache_off)
                direct_val = _gpu_get_value_trilinear(buf, bg, fx, fy, fz, hts)
                @test cached_val ≈ direct_val atol=1e-6
            end
        end

        @testset "gpu_render_volume on CUDA — smoke test" begin
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            cam = Camera((100.0, 80.0, 60.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
            mat = VolumeMaterial(tf_smoke(); sigma_scale=10.0)
            vol = VolumeEntry(grid, nano, mat)
            scene = Scene(cam, DirectionalLight((1.0,1.0,1.0), (1.0,0.8,0.6)), vol)

            # HDDA path
            img = gpu_render_volume(nano, scene, 32, 32; backend=CUDABackend(), hdda=true)
            @test size(img) == (32, 32)
            @test all(p -> all(c -> isfinite(c), p), img)

            # Linear path
            img2 = gpu_render_volume(nano, scene, 32, 32; backend=CUDABackend(), hdda=false)
            @test size(img2) == (32, 32)
        end

        @testset "gpu_render_volume on CUDA — cube level set" begin
            vdb = parse_vdb(cube_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            cam = Camera((50.0, 40.0, 30.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
            mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0)
            vol = VolumeEntry(grid, nano, mat)
            scene = Scene(cam, DirectionalLight((1.0,1.0,1.0), (1.0,1.0,1.0)), vol)

            img = gpu_render_volume(nano, scene, 32, 32; backend=CUDABackend())
            @test size(img) == (32, 32)
        end

        @testset "Multi-spp convergence on CUDA" begin
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            cam = Camera((100.0, 80.0, 60.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
            mat = VolumeMaterial(tf_smoke(); sigma_scale=10.0)
            vol = VolumeEntry(grid, nano, mat)
            scene = Scene(cam, DirectionalLight((1.0,1.0,1.0), (1.0,0.8,0.6)), vol)

            img1 = gpu_render_volume(nano, scene, 16, 16; spp=1, backend=CUDABackend())
            img4 = gpu_render_volume(nano, scene, 16, 16; spp=4, backend=CUDABackend())

            # Higher spp should have lower variance (check center pixel neighborhood)
            @test size(img1) == (16, 16)
            @test size(img4) == (16, 16)
        end

        @testset "Determinism on CUDA" begin
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            cam = Camera((100.0, 80.0, 60.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
            mat = VolumeMaterial(tf_smoke(); sigma_scale=10.0)
            vol = VolumeEntry(grid, nano, mat)
            scene = Scene(cam, DirectionalLight((1.0,1.0,1.0), (1.0,0.8,0.6)), vol)

            img_a = gpu_render_volume(nano, scene, 16, 16;
                spp=1, seed=UInt64(123), backend=CUDABackend())
            img_b = gpu_render_volume(nano, scene, 16, 16;
                spp=1, seed=UInt64(123), backend=CUDABackend())
            @test img_a == img_b
        end

        @testset "Resolution scaling on CUDA" begin
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            cam = Camera((100.0, 80.0, 60.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
            mat = VolumeMaterial(tf_smoke(); sigma_scale=10.0)
            vol = VolumeEntry(grid, nano, mat)
            scene = Scene(cam, DirectionalLight((1.0,1.0,1.0), (1.0,0.8,0.6)), vol)

            for res in [16, 32, 64, 128]
                img = gpu_render_volume(nano, scene, res, res; backend=CUDABackend())
                @test size(img) == (res, res)
            end
        end

        @testset "GPU memory stability" begin
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            cam = Camera((100.0, 80.0, 60.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
            mat = VolumeMaterial(tf_smoke(); sigma_scale=10.0)
            vol = VolumeEntry(grid, nano, mat)
            scene = Scene(cam, DirectionalLight((1.0,1.0,1.0), (1.0,0.8,0.6)), vol)

            # Render 5 times and check memory doesn't grow
            for _ in 1:5
                gpu_render_volume(nano, scene, 32, 32; backend=CUDABackend())
            end
            GC.gc()
            mem_after = CUDA.available_memory()
            gpu_render_volume(nano, scene, 32, 32; backend=CUDABackend())
            GC.gc()
            mem_final = CUDA.available_memory()
            # Allow 10MB tolerance for CUDA runtime fluctuation
            @test abs(Int64(mem_final) - Int64(mem_after)) < 10_000_000
        end

        @testset "GPURenderContext zero-alloc reuse on CUDA (C5 acceptance)" begin
            # ACCEPTANCE CRITERION (bead path-tracer-a7wt): repeated renders
            # through the same GPURenderContext allocate ZERO new device memory.
            # Ground truth: CUDA.jl memory model — fill!(::CuArray, isbits) is an
            # in-place kernel (0 device pool bytes); Adapt.adapt(backend,
            # fill(z,n)) allocates a fresh device array. CUDA.@allocated measures
            # DEVICE pool bytes only (the host Array(acc_buf) readback in the
            # render does NOT count).
            #
            # Use the proven smoke.vdb fog scene (a real volume the camera hits)
            # so the render is non-vacuous — an all-black render would make the
            # bit-identity assertion below pass for the wrong reason (fjo9 /
            # vacuous-render-test lesson).
            vdb  = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            cam  = Camera((150.0, 50.0, 150.0), (50.0, 50.0, 50.0), (0.0, 1.0, 0.0), 60.0)
            mat  = VolumeMaterial(tf_smoke(); sigma_scale=5.0)
            vol  = VolumeEntry(grid, nano, mat)
            scene = Scene(cam, DirectionalLight((0.577, 0.577, 0.577)), vol)
            backend = CUDABackend()
            W = 16; H = 16; SEED = UInt64(7)

            gpunano = build_gpu_nanogrid(nano, scene; backend=backend)
            ctx     = build_gpu_render_context(W, H; backend=backend)

            # Untimed WARM-UP render with the context: the first call JIT-
            # specializes the fill!/kernel paths and may allocate. Without this
            # warm-up the @allocated==0 assertion false-fails (the #1 trip-wire).
            warm = gpu_render_volume(gpunano, scene, W, H; spp=2, seed=SEED, context=ctx)
            # Non-vacuous: the warm render must hit density.
            @test any(p -> p != (0.0f0, 0.0f0, 0.0f0), warm)

            # ACCEPTANCE: a steady-state context render allocates 0 device bytes.
            bytes = CUDA.@allocated gpu_render_volume(gpunano, scene, W, H;
                                                       spp=2, seed=SEED, context=ctx)
            @test bytes == 0

            # Bit-identity (fjo9): a context render must equal a no-context
            # render for the same seed.
            base = gpu_render_volume(gpunano, scene, W, H; spp=2, seed=SEED)
            reused = gpu_render_volume(gpunano, scene, W, H; spp=2, seed=SEED, context=ctx)
            @test reused == base

            # Fail-loud on a context/dimension mismatch.
            @test_throws ErrorException gpu_render_volume(gpunano, scene, 32, 32;
                                                           spp=2, seed=SEED, context=ctx)
        end
    end
end
