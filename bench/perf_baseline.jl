#!/usr/bin/env julia
# bench/perf_baseline.jl — WebGL-gap baseline for the GPU volume renderer.
#
# Bead: path-tracer-78us (A2) of EPIC path-tracer-ooul.
#
# Runs `gpu_render_volume(..., profile=true)` (the A1 instrumentation, bead
# path-tracer-605p) on three canonical scenes and writes one record per
# scene to bench/results/YYYY-MM-DD.json. Each record has all four A1
# phases (upload_ms, kernel_ms, accum_ms, readback_ms) plus total_ms and
# grid-size metadata.
#
# Baseline numbers written here are what C (device-cache), D (fused-spp),
# and E (CuTexture) phases of the epic must beat. They are deliberately
# captured at the same (800, 600, spp=8) config the epic targets.
#
# Scene selection (per bead) was smoke.vdb / Schwarzschild thin disk /
# level-set sphere. Schwarzschild substituted with bunny_cloud.vdb: A1's
# profile=true lives on `gpu_render_volume`, not `gpu_gr_render`, so GR
# phase breakdown needs its own bead before it can slot in here.
#
# Timings *will* be noisy on a shared machine — prefer relative
# comparisons (phase-to-phase, before/after C/D/E) over absolute numbers.
#
# Usage:
#   julia --project -t 2 bench/perf_baseline.jl          # defaults: 800x600 spp=8
#   julia --project -t 2 bench/perf_baseline.jl --smoke  # tiny config for CI
#
# Ref:
#   src/GPU.jl gpu_render_volume(...; profile=true) — A1 instrumentation
#   docs/stocktake/08_perf_vs_webgl.md §3 — phase cost diagnosis
#   examples/benchmark_gpu.jl — scene-construction template

using Lyr
using Dates
using Printf
import KernelAbstractions

# Optional CUDA: loading it flips Lyr._GPU_BACKEND[] to CUDABackend() via
# the weakdep extension. Without it the script runs on the KA CPU backend,
# which is still useful for shape validation even if the numbers differ.
try
    @eval using CUDA
catch
    # CUDA.jl not available (e.g. non-GPU CI). Proceed on CPU backend.
end

# ----------------------------------------------------------------------------
# Scene builders — each returns (grid, nanogrid, scene) ready for render
# ----------------------------------------------------------------------------

const FIXTURES = joinpath(@__DIR__, "..", "test", "fixtures", "samples")

"Sparse fog: OpenVDB smoke sim."
function build_smoke_scene()
    path = joinpath(FIXTURES, "smoke.vdb")
    isfile(path) || return nothing
    vdb  = parse_vdb(path)
    grid = vdb.grids[1]
    nano = build_nanogrid(grid.tree)
    bbox = Lyr.active_bounding_box(grid.tree)
    cx = 0.5 * (bbox.min.x + bbox.max.x)
    cy = 0.5 * (bbox.min.y + bbox.max.y)
    cz = 0.5 * (bbox.min.z + bbox.max.z)
    diag = hypot(bbox.max.x - bbox.min.x, bbox.max.y - bbox.min.y, bbox.max.z - bbox.min.z)
    cam = Camera((cx + 1.5*diag, cy + 0.8*diag, cz + 0.6*diag),
                 (cx, cy, cz), (0.0, 0.0, 1.0), 40.0)
    mat = VolumeMaterial(tf_smoke(); sigma_scale=10.0)
    vol = VolumeEntry(grid, nano, mat)
    light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 0.8, 0.6))
    (grid=grid, nano=nano, scene=Scene(cam, light, vol), path=path)
end

"Dense cloud: OpenVDB bunny_cloud (substituted for Schwarzschild thin disk)."
function build_bunny_cloud_scene()
    path = joinpath(FIXTURES, "bunny_cloud.vdb")
    isfile(path) || return nothing
    vdb  = parse_vdb(path)
    grid = vdb.grids[1]
    nano = build_nanogrid(grid.tree)
    bbox = Lyr.active_bounding_box(grid.tree)
    cx = 0.5 * (bbox.min.x + bbox.max.x)
    cy = 0.5 * (bbox.min.y + bbox.max.y)
    cz = 0.5 * (bbox.min.z + bbox.max.z)
    diag = hypot(bbox.max.x - bbox.min.x, bbox.max.y - bbox.min.y, bbox.max.z - bbox.min.z)
    cam = Camera((cx + 1.5*diag, cy + 0.8*diag, cz + 0.6*diag),
                 (cx, cy, cz), (0.0, 0.0, 1.0), 40.0)
    mat = VolumeMaterial(tf_smoke(); sigma_scale=8.0)
    vol = VolumeEntry(grid, nano, mat)
    light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 1.0, 1.0))
    (grid=grid, nano=nano, scene=Scene(cam, light, vol), path=path)
end

"Synthetic level-set sphere converted to fog for volume rendering."
function build_level_set_sphere_scene()
    sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=20.0,
                                  voxel_size=0.5, half_width=3.0)
    grid = sdf_to_fog(sdf)
    nano = build_nanogrid(grid.tree)
    cam = Camera((60.0, 45.0, 35.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
    mat = VolumeMaterial(tf_smoke(); sigma_scale=12.0)
    vol = VolumeEntry(grid, nano, mat)
    light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 1.0, 0.9))
    (grid=grid, nano=nano, scene=Scene(cam, light, vol), path="synthetic:level_set_sphere")
end

# ----------------------------------------------------------------------------
# Bench runner
# ----------------------------------------------------------------------------

"""
    bench_scene(name, build_fn; width, height, spp, warmup_res, backend)

Build the scene, do one small warmup render to defeat JIT first-call effects,
then one timed render with `profile=true`. Returns a NamedTuple record suitable
for JSON serialization. If the fixture is missing, returns `nothing`.
"""
function bench_scene(name::String, build_fn;
                     width::Int, height::Int, spp::Int,
                     warmup_res::Int=32,
                     backend=Lyr._default_gpu_backend())
    built = build_fn()
    built === nothing && return nothing

    (; grid, nano, scene, path) = built
    active = Lyr.active_voxel_count(grid.tree)
    buf_bytes = length(nano.buffer)

    # Warmup — tiny render, discarded. JIT + first-call allocations must not
    # pollute the timed run.
    gpu_render_volume(nano, scene, warmup_res, warmup_res;
                      spp=1, backend=backend, hdda=true)

    GC.gc()
    _, timing = gpu_render_volume(nano, scene, width, height;
                                  spp=spp, backend=backend, hdda=true,
                                  profile=true)

    (
        mode        = "stochastic",
        name        = name,
        source      = string(path),
        active_vox  = active,
        buffer_kb   = round(buf_bytes / 1024; digits=1),
        width       = width,
        height      = height,
        spp         = spp,
        upload_ms   = timing.upload_ms,
        kernel_ms   = timing.kernel_ms,
        accum_ms    = timing.accum_ms,
        readback_ms = timing.readback_ms,
        total_ms    = timing.total_ms,
    )
end

"""
    bench_preview_scene(name, build_fn; width, height, warmup_res, backend, step_size)

Time `gpu_render_volume_preview` — the WebGL-fair comparison mode (fixed-step
EA, no shadows, no multi-scatter). Bead: path-tracer-9kad. Per-phase breakdown
is not yet wired into the preview kernel; total_ms is measured with `@elapsed`
bracketed by `KernelAbstractions.synchronize` for honest wall-clock time.
"""
function bench_preview_scene(name::String, build_fn;
                             width::Int, height::Int,
                             warmup_res::Int=32,
                             backend=Lyr._default_gpu_backend(),
                             step_size::Float32=0.5f0)
    built = build_fn()
    built === nothing && return nothing

    (; grid, nano, scene, path) = built
    active = Lyr.active_voxel_count(grid.tree)
    buf_bytes = length(nano.buffer)

    gpu_render_volume_preview(nano, scene, warmup_res, warmup_res;
                              step_size=step_size, backend=backend)

    GC.gc()
    KernelAbstractions.synchronize(backend)
    t0 = time_ns()
    gpu_render_volume_preview(nano, scene, width, height;
                              step_size=step_size, backend=backend)
    KernelAbstractions.synchronize(backend)
    total_ms = (time_ns() - t0) / 1_000_000.0

    (
        mode        = "preview",
        name        = name,
        source      = string(path),
        active_vox  = active,
        buffer_kb   = round(buf_bytes / 1024; digits=1),
        width       = width,
        height      = height,
        spp         = 1,
        upload_ms   = NaN,  # not instrumented on the preview kernel yet
        kernel_ms   = NaN,
        accum_ms    = NaN,
        readback_ms = NaN,
        total_ms    = total_ms,
    )
end

# ----------------------------------------------------------------------------
# C6 — Orbit benchmark: static volume, moving camera (bead path-tracer-ug5k)
# ----------------------------------------------------------------------------
#
# A 10-frame orbit of a STATIC volume where only the camera azimuth changes
# (36°/frame) is the canonical interactive/turntable use case. The kernel cost
# per frame is IDENTICAL between the two paths — the ONLY difference is whether
# the NanoVDB buffer + TF LUT + lights + the host-side density-range leaf scan
# (and the pixel buffers) are re-uploaded/re-allocated each frame.
#
#   LEGACY: gpu_render_volume(nano::NanoGrid, scene_k, W, H; ...)
#           → rebuilds a fresh GPUNanoGrid every frame (full H2D upload +
#             _estimate_density_range host scan) AND allocs fresh pixel buffers.
#   CACHED: build_gpu_nanogrid(nano, scene) ONCE + build_gpu_render_context()
#           ONCE, then gpu_render_volume(gpunano, scene_k, W, H; context=ctx)
#           → zero per-frame upload, zero per-frame device alloc.
#
# Speedup = legacy_total / cached_total is therefore bounded by the fraction of
# per-frame wall-time that is upload+scan+alloc vs kernel+readback. It is large
# at small render sizes (kernel cheap, upload dominates) and shrinks toward 1×
# as W×H grows and the shared kernel cost dominates. This is the honest story
# (Lyr Rule 1: measure the true speedup, do not game the config).

"""
    _orbit_camera(center, radius, elev, azimuth_deg, fov) -> Camera

Camera on a circle of `radius` around `center` at fixed vertical offset `elev`,
azimuth `azimuth_deg` (degrees) in the world XY plane, looking at `center`.
World up is +Z (matches build_smoke_scene). Only azimuth varies per frame.
"""
function _orbit_camera(center::NTuple{3,Float64}, radius::Float64, elev::Float64,
                       azimuth_deg::Float64, fov::Float64)
    a = deg2rad(azimuth_deg)
    pos = (center[1] + radius * cos(a),
           center[2] + radius * sin(a),
           center[3] + elev)
    Camera(pos, center, (0.0, 0.0, 1.0), fov)
end

"""
    bench_orbit(scene_name, build_fn; W, H, spp, frames=10, backend) -> NamedTuple

Time a `frames`-frame orbit of a STATIC volume (camera azimuth rotates
360/frames degrees per frame) under both the LEGACY per-frame-upload path and
the CACHED GPUNanoGrid+GPURenderContext path. `build_fn` is a scene builder
(e.g. `build_smoke_scene`, `build_bunny_cloud_scene`) returning the
`(grid, nano, scene, path)` NamedTuple; `scene_name` labels the result.

The orbit radius/elevation are derived from the chosen scene's camera framing:
every builder frames its camera at `(cx+1.5d, cy+0.8d, cz+0.6d)` looking at the
bbox centre (`d` = bbox diagonal), so the orbit traces the SAME shell the proven
scene was framed at — only azimuth varies per frame. This keeps the orbit
faithful to each scene's vetted framing (smoke and bunny_cloud both use the
1.5d/0.8d/0.6d offset; see `build_smoke_scene` / `build_bunny_cloud_scene`).

Each path is WARMED UP with one untimed frame (JIT specialization) before the
timed `frames`-frame loop. Per-frame timing is `@elapsed` bracketed by
`CUDA.synchronize()` (or, on the CPU/KA backend, `KernelAbstractions.synchronize`)
for honest GPU wall-clock. Returns per-path total ms, per-frame mean/median/max
ms, and both the total and stall-resistant median speedups.

Asserts the cached render is NON-VACUOUS (some pixel ≠ (0,0,0)) so a degenerate
all-black orbit cannot silently produce a meaningless timing (Lyr "vacuous
render" lesson). Both smoke.vdb fog and bunny_cloud.vdb dense fog hit density
along the orbit; a level-set sphere would graze empty space, so only fog/cloud
scenes are valid here.

When `profile_decompose=true` (default), one extra profiled legacy frame and one
profiled cached frame are rendered (outside the timed loop) so the per-frame
legacy upload+density-scan delta can be reported: `legacy.upload_ms` folds in
`build_gpu_nanogrid` (137 MB H2D + 19.2 M-voxel `_estimate_density_range` host
scan for bunny_cloud) + pixel alloc, while `cached.upload_ms` is JUST the
pixel-buffer re-zero. Their difference is the amortised-away per-frame cost.
"""
function bench_orbit(scene_name::String, build_fn;
                       W::Int, H::Int, spp::Int, frames::Int=10,
                       backend=Lyr._default_gpu_backend(),
                       seed::UInt64=UInt64(42),
                       profile_decompose::Bool=true)
    built = build_fn()
    built === nothing && return nothing
    (; grid, nano, scene, path) = built

    # Orbit geometry: reuse the scene builder's camera distance. Every builder
    # sits the camera at (cx+1.5d, cy+0.8d, cz+0.6d) looking at the bbox center —
    # derive the horizontal radius and vertical elevation from that so the orbit
    # traces the same shell the proven scene was framed at, just sweeping azimuth.
    bbox = Lyr.active_bounding_box(grid.tree)
    cx = 0.5 * (bbox.min.x + bbox.max.x)
    cy = 0.5 * (bbox.min.y + bbox.max.y)
    cz = 0.5 * (bbox.min.z + bbox.max.z)
    center = (Float64(cx), Float64(cy), Float64(cz))
    diag = hypot(bbox.max.x - bbox.min.x, bbox.max.y - bbox.min.y, bbox.max.z - bbox.min.z)
    radius = hypot(1.5 * diag, 0.8 * diag)   # XY radius from the builder's offset
    elev   = 0.6 * diag                       # +Z elevation from the builder's offset
    fov    = scene.camera.fov
    dazim  = 360.0 / frames                    # 36° for frames=10

    # The static volume's material/light are unchanged; only the camera moves.
    light = scene.lights[1]
    vol   = scene.volumes[1]
    scene_at(az) = Scene(_orbit_camera(center, radius, elev, az, fov), light, vol)

    # GPU-aware sync + timing helpers. CUDA.@sync waits for the device; on the
    # KA CPU backend fall back to KernelAbstractions.synchronize.
    is_cuda = backend !== KernelAbstractions.CPU()
    sync!() = is_cuda ? CUDA.synchronize() : KernelAbstractions.synchronize(backend)

    # Per-frame wall times (sync-bracketed) collected alongside the loop total.
    # The TOTAL/mean speedup folds in legacy's allocator-stall tail latency (the
    # per-frame 7.84 MB device churn of the ::NanoGrid path occasionally triggers
    # a multi-hundred-ms-to-second CUDA allocator/GC pause). The MEDIAN per-frame
    # speedup is the stall-resistant, kernel-bound number. Reporting both is the
    # honest decomposition (Lyr Rule 1): see docs/perf_baseline.md §1.4.
    function _timed_loop(render_frame)
        per = Float64[]
        sync!()
        for k in 0:(frames - 1)
            t = 1000.0 * @elapsed begin
                render_frame(k)
                sync!()
            end
            push!(per, t)
        end
        per
    end

    # ----- LEGACY path: fresh GPUNanoGrid + fresh pixel buffers every frame ---
    # Warmup (untimed): JIT-specialize the ::NanoGrid overload at this config.
    gpu_render_volume(nano, scene_at(0.0), W, H; spp=spp, seed=seed,
                      backend=backend, hdda=true)
    sync!()
    GC.gc()
    legacy_per = _timed_loop(k -> gpu_render_volume(nano, scene_at(k * dazim), W, H;
                                                    spp=spp, seed=seed,
                                                    backend=backend, hdda=true))
    legacy_total_ms = sum(legacy_per)

    # ----- CACHED path: build GPUNanoGrid + GPURenderContext ONCE -------------
    gpunano = build_gpu_nanogrid(nano, scene; backend=backend)
    ctx     = build_gpu_render_context(W, H; backend=backend)
    # Warmup (untimed): JIT-specialize the ::GPUNanoGrid overload at this config.
    warm = gpu_render_volume(gpunano, scene_at(0.0), W, H;
                             spp=spp, seed=seed, context=ctx)
    sync!()

    # Sanity: the cached path must produce a NON-VACUOUS render, or the timing
    # is measuring an all-black no-op. Both smoke.vdb fog and bunny_cloud.vdb
    # dense fog guarantee density hits along the orbit.
    nonvacuous = any(p -> p != (0.0f0, 0.0f0, 0.0f0), warm)
    nonvacuous || error("bench_orbit[$scene_name]: cached render is VACUOUS (all " *
                        "black) — timing would be meaningless. Check scene/camera/density.")

    GC.gc()
    cached_per = _timed_loop(k -> gpu_render_volume(gpunano, scene_at(k * dazim), W, H;
                                                    spp=spp, seed=seed, context=ctx))
    cached_total_ms = sum(cached_per)

    # ----- Per-frame cost DECOMPOSITION (Lyr Rule 1: show WHERE time goes) -----
    # One extra profiled frame per path, OUTSIDE the timed loop. The legacy
    # profile=true upload_ms folds in build_gpu_nanogrid (full H2D upload of the
    # NanoVDB buffer + the _estimate_density_range host scan over every active
    # voxel) PLUS the fresh pixel-buffer alloc; the cached profile=true upload_ms
    # is JUST the pixel-buffer re-zero (zero device alloc with a context). Their
    # delta is the per-frame work the device cache amortises away.
    legacy_upload_ms = NaN; legacy_kernel_ms = NaN
    cached_upload_ms = NaN; cached_kernel_ms = NaN
    upload_scan_delta_ms = NaN
    if profile_decompose
        sync!()
        _, lt = gpu_render_volume(nano, scene_at(0.0), W, H;
                                  spp=spp, seed=seed, backend=backend,
                                  hdda=true, profile=true)
        sync!()
        _, ct = gpu_render_volume(gpunano, scene_at(0.0), W, H;
                                  spp=spp, seed=seed, context=ctx, profile=true)
        sync!()
        legacy_upload_ms = lt.upload_ms; legacy_kernel_ms = lt.kernel_ms
        cached_upload_ms = ct.upload_ms; cached_kernel_ms = ct.kernel_ms
        # upload_ms(legacy) - upload_ms(cached) ≈ build_gpu_nanogrid cost
        # (H2D buffer upload + density scan + LUT bake + lights pack), since the
        # pixel-buffer alloc term is common to both upload_ms figures.
        upload_scan_delta_ms = lt.upload_ms - ct.upload_ms
    end

    _median(v) = (s = sort(v); n = length(s);
                  isodd(n) ? s[(n + 1) ÷ 2] : 0.5 * (s[n ÷ 2] + s[n ÷ 2 + 1]))

    legacy_median_ms = _median(legacy_per)
    cached_median_ms = _median(cached_per)

    speedup        = legacy_total_ms / cached_total_ms             # incl. tail latency
    median_speedup = legacy_median_ms / cached_median_ms           # stall-resistant

    (
        name             = "$scene_name orbit ($(frames) frames, $(round(dazim;digits=1))°/frame)",
        scene            = scene_name,
        source           = string(path),
        active_vox       = Lyr.active_voxel_count(grid.tree),
        buffer_kb        = round(length(nano.buffer) / 1024; digits=1),
        width            = W,
        height           = H,
        spp              = spp,
        frames           = frames,
        legacy_total_ms  = legacy_total_ms,
        cached_total_ms  = cached_total_ms,
        legacy_per_frame_ms = legacy_total_ms / frames,
        cached_per_frame_ms = cached_total_ms / frames,
        legacy_median_ms = legacy_median_ms,
        cached_median_ms = cached_median_ms,
        legacy_max_ms    = maximum(legacy_per),
        cached_max_ms    = maximum(cached_per),
        legacy_upload_ms = legacy_upload_ms,
        cached_upload_ms = cached_upload_ms,
        legacy_kernel_ms = legacy_kernel_ms,
        cached_kernel_ms = cached_kernel_ms,
        upload_scan_delta_ms = upload_scan_delta_ms,
        speedup          = speedup,
        median_speedup   = median_speedup,
        nonvacuous       = nonvacuous,
    )
end

"""
    run_orbit(; scenes, smoke_configs, bunny_configs, frames, backend)
        -> Vector{NamedTuple}

Run `bench_orbit` across several scenes × (W, H, spp) configs and collect the
records. Each scene gets its own config list because the upload-amortisation
regime depends on the buffer size:

- **smoke.vdb** (6.34 MB buffer, ~1 M voxels): the per-frame upload is cheap, so
  the speedup is bounded near 1× even at small render sizes (documented in §1.4).
  Configs span preview-ish 256² / 512².
- **bunny_cloud.vdb** (137 MB buffer, ~19.2 M voxels): the per-frame re-upload +
  host density-scan is GENUINELY expensive. Small render sizes (128²/256²/512²,
  spp=1) expose the upload-amortisation regime where the cache pays off; a larger
  config (512² spp=8) keeps the regime-shrink story.

Missing fixtures are skipped (each builder returns `nothing`).
"""
function run_orbit(; scenes=[("smoke.vdb", build_smoke_scene),
                             ("bunny_cloud.vdb", build_bunny_cloud_scene)],
                     smoke_configs=[(256, 256, 1), (512, 512, 1), (256, 256, 8)],
                     bunny_configs=[(128, 128, 1), (256, 256, 1), (512, 512, 1), (512, 512, 8)],
                     frames::Int=10,
                     backend=Lyr._default_gpu_backend())
    recs = NamedTuple[]
    for (name, fn) in scenes
        cfgs = name == "bunny_cloud.vdb" ? bunny_configs : smoke_configs
        for (w, h, spp) in cfgs
            rec = bench_orbit(name, fn; W=w, H=h, spp=spp, frames=frames, backend=backend)
            rec === nothing && continue
            push!(recs, rec)
            # bunny_cloud's 137 MB legacy re-upload churns the CUDA pool; reclaim
            # between configs so a later config does not inherit fragmentation.
            GC.gc()
        end
    end
    recs
end

function print_orbit_summary(io::IO, recs)
    println(io, "=" ^ 100)
    println(io, "Lyr.jl C6 ORBIT BENCHMARK — static volume, moving camera (smoke.vdb + bunny_cloud.vdb)")
    println(io, "=" ^ 100)
    println(io, gpu_info())
    println(io, "Julia:   ", VERSION)
    println(io)
    if isempty(recs)
        println(io, "(no orbit rendered — fixtures missing)")
        return
    end
    @printf(io, "%-16s %-10s %5s %4s %10s %10s %10s %10s %7s %7s\n",
            "config", "scene", "frms", "spp",
            "leg tot", "cac tot", "leg med", "cac med", "tot ×", "med ×")
    @printf(io, "%-16s %-10s %5s %4s %10s %10s %10s %10s %7s %7s\n",
            "(W×H×spp)", "", "", "", "(ms)", "(ms)", "(ms)", "(ms)", "", "")
    println(io, "-" ^ 100)
    for r in recs
        cfg = "$(r.width)×$(r.height)×$(r.spp)"
        scn = first(split(r.scene, "."))  # "smoke" / "bunny_cloud"
        @printf(io, "%-16s %-10s %5d %4d %10.1f %10.1f %10.2f %10.2f %7.2f %7.2f\n",
                cfg, scn, r.frames, r.spp,
                r.legacy_total_ms, r.cached_total_ms,
                r.legacy_median_ms, r.cached_median_ms,
                r.speedup, r.median_speedup)
    end
    println(io, "-" ^ 100)
    # Per-frame cost decomposition: where the legacy time goes vs cached.
    println(io)
    println(io, "Per-frame cost decomposition (profiled single frame, ms):")
    @printf(io, "%-16s %-10s %12s %12s %12s %12s\n",
            "config", "scene", "leg upld", "cac upld", "upld Δ", "leg/cac kern")
    println(io, "-" ^ 80)
    for r in recs
        cfg = "$(r.width)×$(r.height)×$(r.spp)"
        scn = first(split(r.scene, "."))
        kern = isnan(r.legacy_kernel_ms) ? "-" :
               @sprintf("%.1f/%.1f", r.legacy_kernel_ms, r.cached_kernel_ms)
        _f(x) = isnan(x) ? "    -   " : @sprintf("%12.2f", x)
        @printf(io, "%-16s %-10s %s %s %s %12s\n",
                cfg, scn, _f(r.legacy_upload_ms), _f(r.cached_upload_ms),
                _f(r.upload_scan_delta_ms), kern)
    end
    println(io, "-" ^ 80)
    println(io, "(upld Δ = legacy upload_ms − cached upload_ms ≈ per-frame H2D buffer")
    println(io, " upload + _estimate_density_range host scan amortised away by the cache)")
    println(io)
    _tag(r) = string(first(split(r.scene, ".")), r.width, "²")
    println(io, "leg max frame: ", join(["$(_tag(r))=$(round(r.legacy_max_ms;digits=0))ms" for r in recs], "  "))
    println(io, "cac max frame: ", join(["$(_tag(r))=$(round(r.cached_max_ms;digits=0))ms" for r in recs], "  "))
end

# ----------------------------------------------------------------------------
# Minimal JSON emitter — flat shape only, no external dep
# ----------------------------------------------------------------------------

_json_escape(s::AbstractString) = replace(string(s),
    '\\' => "\\\\", '"' => "\\\"", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t")

_json_val(x::AbstractString) = '"' * _json_escape(x) * '"'
_json_val(x::Bool)            = x ? "true" : "false"
_json_val(x::Integer)         = string(x)
_json_val(x::AbstractFloat)   = isfinite(x) ? string(x) : "null"
_json_val(x::Nothing)         = "null"
_json_val(x::NamedTuple)      = _json_obj(pairs(x))
_json_val(x::AbstractDict)    = _json_obj(pairs(x))
_json_val(x::AbstractVector)  = "[" * join((_json_val(v) for v in x), ",") * "]"

function _json_obj(kvs)
    parts = String[]
    for (k, v) in kvs
        push!(parts, _json_val(string(k)) * ":" * _json_val(v))
    end
    "{" * join(parts, ",") * "}"
end

write_json(path::AbstractString, obj) = open(f -> write(f, _json_val(obj)), path, "w")

# ----------------------------------------------------------------------------
# Public entry point — callable from tests, from the CLI, from the REPL
# ----------------------------------------------------------------------------

"""
    run_baseline(; width=800, height=600, spp=8, output_path=nothing)
        -> (records::Vector{NamedTuple}, output_path::String)

Run the A2 baseline. Default config is the one the epic targets.
`output_path=nothing` routes output to bench/results/YYYY-MM-DD.json.
"""
function run_baseline(; width::Int=800, height::Int=600, spp::Int=8,
                        warmup_res::Int=32,
                        output_path=nothing,
                        preview_only::Bool=false)

    scenes = [
        ("smoke.vdb (sparse fog)",         build_smoke_scene),
        ("bunny_cloud.vdb (dense cloud)",  build_bunny_cloud_scene),
        ("level_set_sphere (synthetic)",   build_level_set_sphere_scene),
    ]

    backend = Lyr._default_gpu_backend()
    records = NamedTuple[]
    skipped = String[]

    if !preview_only
        for (name, fn) in scenes
            rec = bench_scene(name, fn;
                              width=width, height=height, spp=spp,
                              warmup_res=warmup_res, backend=backend)
            if rec === nothing
                push!(skipped, name)
            else
                push!(records, rec)
            end
        end
    end

    # Preview-path measurements at the same resolution. This is the
    # WebGL-fair comparison mode (bead path-tracer-9kad; see
    # docs/perf_baseline.md §2).
    for (name, fn) in scenes
        rec = bench_preview_scene(name, fn;
                                   width=width, height=height,
                                   warmup_res=warmup_res, backend=backend)
        if rec === nothing
            preview_only && push!(skipped, name)
        else
            push!(records, rec)
        end
    end

    if output_path === nothing
        outdir = joinpath(@__DIR__, "results")
        mkpath(outdir)
        output_path = joinpath(outdir, Dates.format(today(), "yyyy-mm-dd") * ".json")
    end

    payload = (
        generated_at = string(now()),
        backend      = string(typeof(backend)),
        gpu_info     = gpu_info(),
        julia        = string(VERSION),
        config       = (width=width, height=height, spp=spp),
        scenes       = records,
        skipped      = skipped,
    )
    write_json(output_path, payload)

    (records, output_path)
end

# ----------------------------------------------------------------------------
# Pretty-print helper — called from main()
# ----------------------------------------------------------------------------

function print_summary(io::IO, records, output_path)
    println(io, "=" ^ 72)
    println(io, "Lyr.jl A2 BASELINE — GPU volume render per-phase timings")
    println(io, "=" ^ 72)
    println(io, gpu_info())
    println(io, "Julia:   ", VERSION)
    println(io, "Output:  ", output_path)
    println(io)
    if isempty(records)
        println(io, "(no scenes rendered — fixtures missing)")
        return
    end
    @printf(io, "%-12s %-36s %9s %9s %9s %9s %9s\n",
            "mode", "scene", "upload", "kernel", "accum", "readback", "total")
    @printf(io, "%-12s %-36s %9s %9s %9s %9s %9s\n",
            "", "", "(ms)", "(ms)", "(ms)", "(ms)", "(ms)")
    println(io, "-" ^ 84)
    _fmt(x::Real) = isnan(x) ? "     -   " : @sprintf("%9.2f", x)
    for r in records
        @printf(io, "%-12s %-36s %s %s %s %s %s\n",
                r.mode, r.name,
                _fmt(r.upload_ms), _fmt(r.kernel_ms), _fmt(r.accum_ms),
                _fmt(r.readback_ms), _fmt(r.total_ms))
    end
    println(io, "-" ^ 84)
end

# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

function main(args=ARGS)
    # --orbit:       run the C6 orbit benchmark on BOTH smoke + bunny_cloud.
    # --orbit-bunny: run it on bunny_cloud.vdb ONLY (faster iteration).
    # Either prints the table and returns; the A2/A3 baseline path is untouched.
    if "--orbit-bunny" in args
        backend = Lyr._default_gpu_backend()
        recs = run_orbit(; scenes=[("bunny_cloud.vdb", build_bunny_cloud_scene)],
                           backend=backend)
        print_orbit_summary(stdout, recs)
        return recs
    end
    if "--orbit" in args
        backend = Lyr._default_gpu_backend()
        recs = run_orbit(; backend=backend)
        print_orbit_summary(stdout, recs)
        return recs
    end

    width, height, spp, warmup = 800, 600, 8, 32
    if "--smoke" in args
        width, height, spp, warmup = 32, 32, 1, 8
    end
    records, outpath = run_baseline(; width=width, height=height, spp=spp,
                                      warmup_res=warmup)
    print_summary(stdout, records, outpath)

    # Also emit a preview-only run at 1920×1080 — the canonical WebGL-fair
    # resolution (bead path-tracer-9kad; docs/perf_baseline.md §2.2).
    if !("--smoke" in args)
        outdir = joinpath(@__DIR__, "results")
        out1080 = joinpath(outdir, Dates.format(today(), "yyyy-mm-dd") * "-preview-1080p.json")
        println("\n--- 1920×1080 preview-only (WebGL-fair target 16.7 ms) ---\n")
        records_1080, path_1080 = run_baseline(;
            width=1920, height=1080, spp=1, warmup_res=warmup,
            output_path=out1080, preview_only=true)
        print_summary(stdout, records_1080, path_1080)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
