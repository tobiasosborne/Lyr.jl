#!/usr/bin/env julia
# GPU Rendering Benchmark — HDDA + Leaf Cache vs Linear
#
# Run: julia --project -t auto examples/benchmark_gpu.jl
#
# Tests across grid types (sparse fog, dense level set, large cloud)
# and resolutions. Reports wall time, speedup, and saves renders.

using CUDA, Lyr, Printf
import KernelAbstractions

const WARMUP_RES = 32
const BENCHMARK_RES = 512
const BENCHMARK_SPP = 8

# --- Benchmark helpers ---

function setup_scene(grid, nano; sigma=10.0)
    cam = Camera((100.0, 80.0, 60.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
    mat = VolumeMaterial(tf_smoke(); sigma_scale=sigma)
    vol = VolumeEntry(grid, nano, mat)
    light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 0.8, 0.6))
    Scene(cam, light, vol)
end

function benchmark_render(nano, scene, w, h, spp, backend; hdda=true, warmup=true)
    # Warmup (JIT)
    if warmup
        gpu_render_volume(nano, scene, WARMUP_RES, WARMUP_RES;
            spp=1, backend=backend, hdda=hdda)
    end
    # Timed run
    GC.gc()
    t = @elapsed img = gpu_render_volume(nano, scene, w, h;
        spp=spp, backend=backend, hdda=hdda)
    (t, img)
end

function count_active_voxels(grid)
    n = 0
    for leaf in Lyr.leaves(grid.tree)
        n += count(leaf.vmask.bits) do w; count_ones(w) end
    end
    n
end

# --- Main ---

function main()
    println("=" ^ 70)
    println("GPU RENDERING BENCHMARK — Lyr.jl")
    println("=" ^ 70)
    println()

    # Device info
    dev = CUDA.device()
    println("Device:     $(CUDA.name(dev))")
    println("CUDA:       $(CUDA.runtime_version())")
    println("Backend:    $(Lyr._default_gpu_backend())")
    println("Resolution: $(BENCHMARK_RES)x$(BENCHMARK_RES) @ $(BENCHMARK_SPP) spp")
    println()

    # Test grids — different sparsity levels
    test_cases = [
        ("smoke.vdb (sparse fog)",     "test/fixtures/samples/smoke.vdb",    10.0),
        ("cube.vdb (dense level set)", "test/fixtures/samples/cube.vdb",      5.0),
        ("torus.vdb (medium)",         "test/fixtures/samples/torus.vdb",     8.0),
        ("fire.vdb (complex sparse)",  "test/fixtures/openvdb/fire.vdb",     15.0),
        ("bunny.vdb (level set)",      "test/fixtures/openvdb/bunny.vdb",     5.0),
    ]

    results = []
    backend = CUDABackend()

    # JIT warmup with first grid
    println("JIT warmup...")
    vdb0 = parse_vdb(test_cases[1][2])
    g0 = vdb0.grids[1]; n0 = build_nanogrid(g0.tree)
    s0 = setup_scene(g0, n0; sigma=test_cases[1][3])
    gpu_render_volume(n0, s0, WARMUP_RES, WARMUP_RES; backend=backend, hdda=true)
    gpu_render_volume(n0, s0, WARMUP_RES, WARMUP_RES; backend=backend, hdda=false)
    println("JIT done.\n")

    println("-" ^ 70)
    for (name, path, sigma) in test_cases
        if !isfile(path)
            println("SKIP: $name — file not found")
            continue
        end

        print("Loading $name... ")
        vdb = parse_vdb(path)
        grid = vdb.grids[1]
        nano = build_nanogrid(grid.tree)
        scene = setup_scene(grid, nano; sigma=sigma)

        active = active_voxel_count(grid.tree)
        buf_kb = round(length(nano.buffer) / 1024; digits=0)
        println("$(active) active voxels, $(buf_kb) KB buffer")

        # HDDA + cache
        GC.gc()
        t_hdda, img_hdda = benchmark_render(nano, scene,
            BENCHMARK_RES, BENCHMARK_RES, BENCHMARK_SPP, backend;
            hdda=true, warmup=false)

        # Linear (no HDDA)
        GC.gc()
        t_linear, _ = benchmark_render(nano, scene,
            BENCHMARK_RES, BENCHMARK_RES, BENCHMARK_SPP, backend;
            hdda=false, warmup=false)

        # CPU baseline (smaller res to keep reasonable)
        GC.gc()
        cpu_res = 128
        t_cpu = @elapsed gpu_render_volume(nano, scene, cpu_res, cpu_res;
            spp=2, backend=KernelAbstractions.CPU(), hdda=false)
        # Scale CPU time to match GPU resolution and spp
        scale_factor = (BENCHMARK_RES / cpu_res)^2 * (BENCHMARK_SPP / 2)
        t_cpu_est = t_cpu * scale_factor

        speedup_hdda = t_linear / t_hdda
        speedup_cpu = t_cpu_est / t_hdda

        @printf("  HDDA+cache:  %7.3fs\n", t_hdda)
        @printf("  Linear GPU:  %7.3fs  (HDDA speedup: %.1fx)\n", t_linear, speedup_hdda)
        @printf("  CPU (est):   %7.1fs  (GPU speedup:  %.0fx)\n", t_cpu_est, speedup_cpu)

        # Save render
        safe_name = replace(split(name, " ")[1], "." => "_")
        outpath = "showcase/gpu_$(safe_name).ppm"
        mkpath("showcase")
        write_ppm(outpath, img_hdda)
        println("  Saved: $outpath")
        println()

        push!(results, (name=name, active=active, buf_kb=buf_kb,
                        t_hdda=t_hdda, t_linear=t_linear, t_cpu_est=t_cpu_est,
                        speedup_hdda=speedup_hdda, speedup_cpu=speedup_cpu))
    end

    # Summary table
    println("=" ^ 70)
    println("SUMMARY")
    println("=" ^ 70)
    @printf("%-30s %8s %8s %8s %6s %6s\n",
            "Grid", "HDDA(s)", "Lin(s)", "CPU(s)", "vs Lin", "vs CPU")
    println("-" ^ 70)
    for r in results
        @printf("%-30s %8.3f %8.3f %8.1f %5.1fx %5.0fx\n",
                r.name, r.t_hdda, r.t_linear, r.t_cpu_est,
                r.speedup_hdda, r.speedup_cpu)
    end
    println("-" ^ 70)

    if !isempty(results)
        avg_hdda = sum(r.speedup_hdda for r in results) / length(results)
        avg_cpu = sum(r.speedup_cpu for r in results) / length(results)
        @printf("%-30s %8s %8s %8s %5.1fx %5.0fx\n",
                "AVERAGE", "", "", "", avg_hdda, avg_cpu)
    end

    println("\nAll renders saved to showcase/")
    println("Device: $(CUDA.name(CUDA.device()))")
end

main()
