# Test `profile=true` instrumentation on gpu_render_volume.
# Bead: path-tracer-605p (A1). Runs on whichever backend Lyr auto-detects
# (CPU backend is fine — the timing API is backend-agnostic).
#
# Ref: docs/stocktake/08_perf_vs_webgl.md §3 — the H2D upload / per-spp
# kernel launches / D2H readback are the phases we need to measure.
using Test
using Lyr

@testset "GPU perf instrumentation (A1)" begin
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
    vol = VolumeEntry(grid, nanogrid, mat)
    scene = Scene(cam, DirectionalLight((0.577, 0.577, 0.577)), vol)

    @testset "profile=false preserves legacy return type" begin
        pixels = gpu_render_volume(nanogrid, scene, 16, 16; spp=1)
        @test pixels isa Matrix{NTuple{3, Float32}}
        @test size(pixels) == (16, 16)
    end

    @testset "profile=true returns (image, NamedTuple)" begin
        result = gpu_render_volume(nanogrid, scene, 16, 16; spp=2, profile=true)
        @test result isa Tuple
        @test length(result) == 2
        pixels, timing = result

        @test pixels isa Matrix{NTuple{3, Float32}}
        @test size(pixels) == (16, 16)

        @test timing isa NamedTuple
        @test haskey(timing, :upload_ms)
        @test haskey(timing, :kernel_ms)
        @test haskey(timing, :accum_ms)
        @test haskey(timing, :readback_ms)
        @test haskey(timing, :total_ms)

        @test timing.upload_ms   >= 0.0
        @test timing.kernel_ms   >= 0.0
        @test timing.accum_ms    >= 0.0
        @test timing.readback_ms >= 0.0
        @test timing.total_ms    >  0.0

        # Phases should account for most of total_ms (within float tolerance
        # + the small un-timed bookkeeping between phases).
        phases_sum = timing.upload_ms + timing.kernel_ms + timing.accum_ms + timing.readback_ms
        @test phases_sum <= timing.total_ms + 1e-6
        @test phases_sum >= 0.5 * timing.total_ms
    end

    @testset "profile=true produces same image as profile=false at fixed seed" begin
        # Image-equality is also the regression gate for the "no-extra-sync"
        # discipline on the profile=false hot path: if a future change introduces
        # stray `KernelAbstractions.synchronize` calls in the else-branch, the
        # images should still match, but profile=false wall time should not have
        # grown. Don't assert wall time here (noisy on CI); reviewers must
        # eyeball the diff to confirm the profile=false path stays sync-free
        # beyond the two pre-existing per-spp syncs.
        seed = UInt64(42)
        img_plain = gpu_render_volume(nanogrid, scene, 16, 16; spp=1, seed=seed)
        img_prof, _ = gpu_render_volume(nanogrid, scene, 16, 16; spp=1, seed=seed, profile=true)
        @test img_plain == img_prof
    end
end
