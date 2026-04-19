# Lyr.jl Full Stocktake — 2026-04-18

Eight subsystem reports produced by parallel Sonnet subagents surveying all 84 `src/` files + `ext/LyrCUDAExt.jl`. Each report lists one-line purpose for every file, public API surface, key data structures, and known smells.

## Reports

| # | Report | Scope | Files |
|---|--------|-------|-------|
| 01 | [VDB I/O + parsing](01_vdb_io.md) | Binary format, compression, metadata, two-phase parse, TinyVDB oracle | 16 prod + 10 TinyVDB |
| 02 | [Tree + NanoVDB](02_tree_nanovdb.md) | In-memory `Grid{T}`, flat `NanoGrid` buffer, accessor caching, pruning | 7 |
| 03 | [CPU rendering](03_cpu_rendering.md) | Ray → DDA → HDDA → VolumeIntegrator → TF/phase → Scene | 12 |
| 04 | [GPU rendering](04_gpu_rendering.md) | `GPU.jl` kernels, CUDA ext, leaf caching, ScalarQEDGPU | 3 |
| 05 | [General relativity](05_gr.md) | 4 metrics, geodesic integrator, tetrad camera, matter, redshift | 14 |
| 06 | [Field Protocol + physics](06_field_protocol.md) | `AbstractField`, voxelize/visualize, ScalarQED, Wavepackets, Hydrogen, Animation | 7 |
| 07 | [Grid ops + main module](07_grid_ops.md) | CSG, level sets, filtering, morphology, fast sweeping, meshing, `Lyr.jl` | 17 |
| 08 | [**Perf diagnosis vs WebGL**](08_perf_vs_webgl.md) | Why Lyr GPU lags a WebGL volume shader — concrete bottlenecks + fixes | cross-cutting |
| 10 | [CuTexture feasibility (E1)](10_cutexture_feasibility.md) | Go/no-go + code sketch for hardware trilinear via CUDA.jl `CuTexture{Float32,3}` | cross-cutting |

## Headline findings

### The WebGL perf gap is architectural, not a bug (report 08)

Three compounding structural costs — all verified at source line level:

1. **Software tree descent per trilinear corner.** Every volume sample performs 8× `_gpu_get_value` (GPU.jl:319–326), and each of those is a root binary-search + two mask-bit tests + two prefix-sum reads + two pointer chases through the NanoVDB byte buffer. WebGL's `texture(sampler3D, uvw)` is 1–4 clocks in a hardware texture unit. Leaf caching (~75% hit rate on coherent rays) mitigates but does not close the gap.
2. **Stochastic delta tracking multiplies work by `sigma_maj × path_depth`.** In a modestly thick volume with `max_bounces=48` and 3 lights (the showcase config), the expected per-primary-ray cost is easily **1000× a fixed-step WebGL march**. WebGL does one texture fetch per step, no shadow rays, no scatter.
3. **Per-call H2D upload + `spp` kernel launches with CPU-blocking sync.** `gpu_render_volume` re-uploads the whole NanoVDB buffer every call (GPU.jl:1476) and launches `spp` separate kernels each followed by `KernelAbstractions.synchronize` (GPU.jl:1488–1512). WebGL uploads the 3D texture once and redraws a quad.

### Top 3 fixes (prioritized)

1. **Cache the device-side NanoGrid** — expose a `GPUNanoGrid` that holds `dev_buf` across calls. Eliminates the dominant repeated H2D transfer. **~1 day.**
2. **Fuse the `spp` loop inside the kernel** — one launch, one sync. Enables register reuse across samples. **~1–2 days.**
3. **`CuTexture`-backed fast path** for emission-absorption preview mode — the only way to access hardware trilinear through CUDA.jl. Would make preview-quality renders competitive with WebGL on small/medium grids. **~3–5 days.**

Beyond these: default `max_bounces=0` for a "preview" quality mode (currently 48 is visible-in-source), persistent-thread wavefront kernels, half-precision data path.

## Cross-cutting observations

- **Two orthogonal duplication problems**: TinyVDB re-implements ~40% of the production VDB parser (report 01), and the GR render pipeline shares zero code with the main render pipeline (open issue `ylmz`).
- **Float32 epsilon traps** keep biting — `fjo9` was one (fixed); the perf report calls out more potential sites.
- **NanoVDB is the rendering contract** — the in-memory `Grid{T}` is authoritative but unreachable from rendering without `build_nanogrid`. Reports 02 + 04 describe this handoff in detail.
- **Field Protocol is clean** (report 06): ~4 methods to implement, adaptive voxelize, one-call visualize. Adding new physics is the easiest extension path.
- **GR is well-factored** (report 05): analytic Christoffel for Schwarzschild + Kerr, tetrad camera, redshift Planck LUT. Still single-threaded CPU (RK4 upgrade `esr2` open).
- **Known sharp edges**: `Meshing.jl` silently drops cells with corners exactly at `±background`; `Output.jl` silently falls back `.png → .ppm` if PNGFiles not loaded; `VDBFile` write/read is asymmetric for integer grids.

## How to use these reports

- Starting on a subsystem? Read the corresponding report first — each has a file:line call graph.
- Diagnosing a render perf issue? Start with **08**, then **04** (GPU) or **03** (CPU).
- Adding a new physics field? Read **06** — the Field Protocol section lists the exact 4 methods.
- Adding a new metric? Read **05** — the metric abstraction section lists the required overloads.
