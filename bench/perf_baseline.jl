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
