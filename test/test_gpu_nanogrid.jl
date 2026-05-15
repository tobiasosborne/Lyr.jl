# Test GPUNanoGrid device-side cache struct.
# Beads: path-tracer-mx1u (C1), path-tracer-htby (C2), path-tracer-9syk (C2 follow-up).
# Part of EPIC path-tracer-ooul.
#
# The struct holds device-resident buffers that gpu_render_volume currently
# re-uploads on every call: nanovdb bytes, TF LUT, lights. Caching them in
# a user-constructed handle amortises H2D transfer across render calls.
#
# C1 defines only the struct. C2 adds the constructor `build_gpu_nanogrid`.
# 9syk extends both: cache `(dmin, dmax)` on the struct so the C3 render
# overload doesn't repay `_estimate_density_range` (host-side leaf scan,
# ~1 ms/MB of leaf data on smoke.vdb) per render.
#
# Ref: docs/stocktake/04_gpu_rendering.md §3 (architecture diagram) and
#      docs/stocktake/08_perf_vs_webgl.md §4.2 (the fix this enables).
using Test
using Lyr
using KernelAbstractions

import Lyr: GPUNanoGrid, build_gpu_nanogrid, _estimate_density_range

@testset "GPUNanoGrid struct (C1)" begin
    backend = KernelAbstractions.CPU()
    buf     = UInt8[0x01, 0x02, 0x03]
    tf_lut  = Float32[0.1, 0.2, 0.3, 0.4]
    lights  = Float32[0.0, 0.577, 0.577, 0.577, 1.0, 1.0, 1.0]
    dmin    = 0.0f0
    dmax    = 1.0f0

    g = GPUNanoGrid(backend, buf, tf_lut, lights, dmin, dmax)

    @testset "field access" begin
        @test g.backend === backend
        @test g.buffer  === buf
        @test g.tf_lut  === tf_lut
        @test g.lights  === lights
        @test g.dmin    === dmin
        @test g.dmax    === dmax
    end

    @testset "parametric over concrete types" begin
        # dmin/dmax are concrete Float32 scalars — no extra type parameter needed.
        @test g isa GPUNanoGrid{typeof(backend), typeof(buf), typeof(tf_lut), typeof(lights)}
    end

    @testset "immutable" begin
        @test !ismutabletype(GPUNanoGrid)
    end

    @testset "dmin/dmax are Float32 (9syk)" begin
        # The GPU kernel signature reads density extents as Float32; storing
        # Float64 here would mismatch and break C3's call site.
        @test fieldtype(GPUNanoGrid, :dmin) === Float32
        @test fieldtype(GPUNanoGrid, :dmax) === Float32
    end
end

@testset "build_gpu_nanogrid constructor (C2)" begin
    # Tiny but non-trivial scene: level-set sphere fits the EA preview path.
    grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=2.0, voxel_size=1.0)
    nano = build_nanogrid(grid.tree)
    cam  = Camera((10.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 45.0)
    mat  = VolumeMaterial(tf_smoke())
    vol  = VolumeEntry(grid, nano, mat)

    backend = KernelAbstractions.CPU()

    @testset "returns GPUNanoGrid with correct backend" begin
        light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 1.0, 1.0))
        scene = Scene(cam, light, vol)
        g = build_gpu_nanogrid(nano, scene; backend=backend)
        @test g isa GPUNanoGrid
        @test g.backend === backend
    end

    @testset "nanovdb buffer adapted to backend, length preserved" begin
        light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 1.0, 1.0))
        scene = Scene(cam, light, vol)
        g = build_gpu_nanogrid(nano, scene; backend=backend)
        @test eltype(g.buffer) === UInt8
        @test length(g.buffer) == length(nano.buffer)
        # CPU backend: Adapt.adapt is identity → values match exactly
        @test all(g.buffer .== nano.buffer)
    end

    @testset "tf_lut is 256-entry RGBA (1024 Float32s)" begin
        light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 1.0, 1.0))
        scene = Scene(cam, light, vol)
        g = build_gpu_nanogrid(nano, scene; backend=backend)
        @test eltype(g.tf_lut) === Float32
        @test length(g.tf_lut) == 256 * 4
    end

    @testset "single directional light packs to 7 floats" begin
        light = DirectionalLight((1.0, 0.0, 0.0), (0.5, 0.6, 0.7))
        scene = Scene(cam, light, vol)
        g = build_gpu_nanogrid(nano, scene; backend=backend)
        @test eltype(g.lights) === Float32
        @test length(g.lights) == 7
        @test g.lights[1] == 0.0f0           # type = directional
        @test g.lights[2:4] == Float32[1, 0, 0]   # direction
        @test g.lights[5:7] == Float32[0.5f0, 0.6f0, 0.7f0]  # intensity
    end

    @testset "single point light packs with type=1" begin
        light = PointLight((5.0, 6.0, 7.0), (0.1, 0.2, 0.3))
        scene = Scene(cam, light, vol)
        g = build_gpu_nanogrid(nano, scene; backend=backend)
        @test length(g.lights) == 7
        @test g.lights[1] == 1.0f0           # type = point
        @test g.lights[2:4] == Float32[5, 6, 7]   # position
        @test g.lights[5:7] == Float32[0.1f0, 0.2f0, 0.3f0]  # intensity
    end

    @testset "multiple mixed lights pack correctly" begin
        l1 = DirectionalLight((1.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        l2 = PointLight((5.0, 5.0, 5.0), (0.0, 1.0, 0.0))
        scene = Scene(cam, AbstractLight[l1, l2], vol)
        g = build_gpu_nanogrid(nano, scene; backend=backend)
        @test length(g.lights) == 14   # 2 lights × 7
        @test g.lights[1] == 0.0f0     # first: directional
        @test g.lights[8] == 1.0f0     # second: point
    end

    @testset "ConstantEnvironmentLight is skipped, fallback default substituted" begin
        env = ConstantEnvironmentLight((0.5, 0.5, 0.5))
        scene = Scene(cam, env, vol)
        g = build_gpu_nanogrid(nano, scene; backend=backend)
        # All lights skipped → fallback default directional = 7 floats
        @test length(g.lights) == 7
        @test g.lights[1] == 0.0f0     # directional fallback
    end

    @testset "deterministic across repeated invocations" begin
        # No RNG, no globals — same input must yield equal buffers.
        light = DirectionalLight((0.3, 0.4, 0.5), (0.6, 0.7, 0.8))
        scene = Scene(cam, light, vol)
        g1 = build_gpu_nanogrid(nano, scene; backend=backend)
        g2 = build_gpu_nanogrid(nano, scene; backend=backend)
        @test all(g1.buffer .== g2.buffer)
        @test all(g1.tf_lut .== g2.tf_lut)
        @test all(g1.lights .== g2.lights)
        @test g1.dmin === g2.dmin
        @test g1.dmax === g2.dmax
    end
end

# ============================================================================
# 9syk: dmin/dmax baked at construction so C3 (path-tracer-20xa) doesn't repay
# the host-side leaf scan in `_estimate_density_range` on every render call.
# ============================================================================
@testset "build_gpu_nanogrid bakes (dmin, dmax) (9syk)" begin
    # Known-by-construction density range. Three voxels at 0.25, 0.5, 0.75 →
    # _estimate_density_range scans the leaf's full 512 slots; inactive slots
    # hold the background (0.0f0 here), so the true min is 0.0 and max is 0.75.
    voxels = Dict(
        Lyr.coord(0, 0, 0) => 0.25f0,
        Lyr.coord(1, 0, 0) => 0.5f0,
        Lyr.coord(2, 0, 0) => 0.75f0,
    )
    grid = build_grid(voxels, 0.0f0; name="density")
    nano = build_nanogrid(grid.tree)
    cam  = Camera((10.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 45.0)
    mat  = VolumeMaterial(tf_smoke())
    vol  = VolumeEntry(grid, nano, mat)
    light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 1.0, 1.0))
    scene = Scene(cam, light, vol)
    backend = KernelAbstractions.CPU()

    g = build_gpu_nanogrid(nano, scene; backend=backend)
    dmin_ref, dmax_ref = _estimate_density_range(nano)

    @testset "fields match _estimate_density_range (Float32 cast)" begin
        @test g.dmin === Float32(dmin_ref)
        @test g.dmax === Float32(dmax_ref)
    end

    @testset "values are concretely Float32, not Float64" begin
        @test g.dmin isa Float32
        @test g.dmax isa Float32
    end

    @testset "ground-truth values for this synthetic grid" begin
        # The Dict-built grid has background 0.0f0; _estimate_density_range
        # scans all 512 leaf slots, so dmin = 0.0 (background) and dmax = 0.75.
        @test g.dmin == 0.0f0
        @test g.dmax == 0.75f0
    end
end

# ============================================================================
# CUDA-only: deterministic memory stability across many build cycles.
# Gated on CUDA.functional() so this file remains runnable on CPU-only systems.
# ============================================================================
@static if Base.find_package("CUDA") !== nothing
    using CUDA
    if CUDA.functional()
        using CUDA: CUDABackend
        @testset "build_gpu_nanogrid leak-stability on CUDA (100 cycles)" begin
            # Use a non-trivial grid so per-cycle bytes dominate the slop floor.
            # A radius=20 voxel=0.5 sphere produces a ~1 MB nanovdb buffer →
            # cumulative leak of ~100 MB over 100 cycles if anything is
            # retained, well above the slop threshold.
            grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=20.0, voxel_size=0.5)
            nano = build_nanogrid(grid.tree)
            cam  = Camera((10.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 45.0)
            mat  = VolumeMaterial(tf_smoke())
            vol  = VolumeEntry(grid, nano, mat)
            light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 1.0, 1.0))
            scene = Scene(cam, light, vol)
            backend = CUDABackend()

            # Warm up: first build allocates pinned host buffers, JIT-compiles
            # adapt paths, and may grow the CUDA caching allocator's reserve.
            # Discard a few cycles so the baseline reflects steady state.
            for _ in 1:5
                g = build_gpu_nanogrid(nano, scene; backend=backend)
                g = nothing
            end
            GC.gc(); GC.gc()
            CUDA.reclaim()

            free_before = CUDA.available_memory()

            for _ in 1:100
                g = build_gpu_nanogrid(nano, scene; backend=backend)
                g = nothing
            end
            GC.gc(); GC.gc()
            CUDA.reclaim()

            free_after = CUDA.available_memory()

            # A real leak retains every cycle's device allocations: 100 ×
            # nanovdb buffer ≈ 100 MB minimum. Tight slop at 4× per-cycle
            # bytes catches anything coarser than that without false-firing
            # on allocator-pool reserve growth.
            cycle_bytes = length(nano.buffer) + 256 * 4 * sizeof(Float32) + 7 * sizeof(Float32)
            slop = max(2 * 1024 * 1024, 4 * cycle_bytes)
            @test (free_before - free_after) < slop
        end
    end
end
