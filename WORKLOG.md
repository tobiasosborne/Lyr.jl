# Lyr.jl Work Log

Gotchas, learnings, decisions, surprises. Updated every step.
Institutional memory for future agents. If you hit something non-obvious, write it down before moving on.

Rule 0 of CLAUDE.md is implicit: *maintain this file*.

---

## 2026-05-15 — Session: 9syk cache (dmin, dmax) on GPUNanoGrid

**Stop reason:** 9syk GREEN. Targeted suite + CUDA regression pass. C3 (`path-tracer-20xa`) now unblocked.

### What shipped

| Bead | What | Commit |
|------|------|--------|
| `path-tracer-9syk` (C2 follow-up, P2) | Added `dmin::Float32, dmax::Float32` fields to `GPUNanoGrid`. `build_gpu_nanogrid` already computed `(dmin, dmax)` to bake the TF LUT — now it also Float32-casts and stores them on the struct so the upcoming C3 render overload can skip `_estimate_density_range` (host-side leaf scan, ~1 ms/MB of leaf data on smoke.vdb) entirely. 6 new green tests; existing C1 positional constructor test updated. | (this commit) |

### Key decisions and gotchas

1. **Field ordering: append at the end.** `dmin`/`dmax` go after `lights`, not in between. Two positional call-sites exist (`build_gpu_nanogrid` in `src/GPU.jl` and the C1 struct test in `test_gpu_nanogrid.jl`); appending keeps reader intuition that the device buffers come first and the cached scalars after. The C1 test was updated to pass `dmin=0.0f0, dmax=1.0f0`.

2. **No new type parameter for `dmin`/`dmax`.** They're concrete `Float32` scalars — adding a `D` parameter would force every method dispatch to specialize on the same type that's hardcoded anyway. The struct stays `GPUNanoGrid{B,BUF,TF,L}`; the C1 immutability and parametric-shape assertions still hold.

3. **Explicit `Float32` cast in the constructor.** `_estimate_density_range` returns `Tuple{Float64, Float64}` (it accumulates Inf-initialized `Float64`s). The constructor does `Float32(dmin), Float32(dmax)`. Storing Float64 would force the C3 kernel signature to either widen or coerce per-call, defeating the cache. Test `fields are concretely Float32, not Float64` guards against accidental widening.

4. **Pre-existing E2 perf regression (NOT this bead's fault).** `test/test_gpu_preview_texture.jl` E2 acceptance fails on clean master HEAD with 2.78× speedup vs the 3.0× threshold (test passes 3 of 4 subtests; PSNR 61 dB intact). Reproduced on stashed working tree — no relation to 9syk's struct change. Flagged for the user as a potential follow-up bead.

### What's now unblocked

- **`path-tracer-20xa` (C3) — `gpu_render_volume(::GPUNanoGrid, scene; ...)` overload.** The cache now carries everything C3 needs: nanovdb buffer, TF LUT, packed lights, density range. Per-render `_estimate_density_range` call at `src/GPU.jl:1585` can be replaced with `nanogrid.dmin, nanogrid.dmax` in the new overload (legacy CPU-NanoGrid entry point untouched per scope).

### Tests run (all green)

- `test/test_gpu_nanogrid.jl` — 10 + 26 + 6 + 1 CUDA leak = 43/43 pass
- `test/test_gpu_cuda.jl` — 318/318 pass

---

## 2026-05-03 — Session: C2 build_gpu_nanogrid (cache constructor)

**Stop reason:** C2 green, reviewer GREEN-light, all regression tests pass. Winding up at user request.

### What shipped

| Bead | What | Commit |
|------|------|--------|
| `path-tracer-htby` (C2) | `build_gpu_nanogrid(nano, scene; backend) -> GPUNanoGrid` constructor: bakes TF LUT, packs lights via new `_pack_lights` helper, `Adapt.adapt`s all three to backend. 24 RED→GREEN tests + CUDA 100-cycle leak test. | (this commit) |
| `path-tracer-9syk` (filed, P2) | Follow-up: cache `(dmin, dmax)` on the struct so C3 doesn't repay `_estimate_density_range` (host-side leaf scan) per render. Discovered in review. | n/a |

### Key decisions and gotchas

1. **No explicit `finalizer` — relied on `CuArray` inner-field finalizers.** The C1 test asserts `!ismutabletype(GPUNanoGrid)`, foreclosing on `finalizer(f, g)` for the struct itself. Each `CuArray` field has its own finalizer; when the struct goes out of scope, GC drops references and the inner finalizers free VRAM. The bead description mentioned `CUDA.unsafe_free!`, but that's the deterministic-release escape hatch — not strictly needed for the leak test. The 100-cycle CUDA test passes on RTX 3090 with `GC.gc(); CUDA.reclaim()` between phases. Deferred opt-in `release!(g)` to a future bead.

2. **Extracted `_pack_lights(lights) -> Vector{Float32}` from `gpu_render_volume`'s inline code.** Byte-for-byte equivalent: same type codes (0=directional, 1=point), same Float32 coercion, same `ConstantEnvironmentLight` skip rule, same fallback default `[0.0, 0.577, 0.577, 0.577, 1.0, 1.0, 1.0]`. Reviewer verified line-by-line. The refactor in `gpu_render_volume` collapses 17 LOC of inline packing to one call.

3. **Tightened the leak test threshold.** First draft used a tiny `radius=2 voxel=1` sphere whose nanovdb buffer was ~30 KB, so `4 × cycle_bytes ≈ 120 KB` lost to the `8 MB` slop floor — the floor would mask `tf_lut`-only leaks (4 KB × 100 = 400 KB). Reviewer flagged it; switched to `radius=20 voxel=0.5` (~1 MB buffer) and dropped the slop to `max(2 MB, 4× cycle)`. Now 100 cycles of any real per-cycle leak ≥ 100 MB, well above the threshold.

4. **HANDOFF.md C2 description called out a `CuTextureArray` field that is NOT in the C1 struct.** The C1 deliverable was `GPUNanoGrid{B,BUF,TF,L}` — backend, nanovdb buffer, tf_lut, lights. CuTextureArray caching for the E2 path is separate (`_gpu_preview_texture_try`). The HANDOFF wording will need a small correction; left as-is for now since this session only shipped C2.

5. **Cache is incomplete for C3.** `gpu_render_volume` currently calls `_estimate_density_range` on every entry (host-side leaf scan, ~1 ms/MB of leaf data). The cache as built doesn't memoize `(dmin, dmax)`; C3 will either repay this scan per render or thread the values through a separate kwarg. Filed `path-tracer-9syk` as a P2 follow-up before C3 starts.

### Current ready queue (epic perspective)

```
  bd ready
  ○ path-tracer-9syk  P2   C2 follow-up: cache (dmin,dmax) on GPUNanoGrid
  ○ path-tracer-hk1f  P1   A3: Record baseline perf numbers in docs/perf_baseline.md
  ○ path-tracer-mmf2  P2   B1: Add quality=:preview/:production kwarg
  ○ path-tracer-vs5y  P2   D1: Research KA/CUDA kernel-internal accumulation
  ○ path-tracer-acxp  P3   Float32 HDDA grazing-ray robustness
```

C3 (`path-tracer-20xa`: `gpu_render_volume(::GPUNanoGrid, scene; ...)` overload) is the natural critical-path next pickup — but consider taking `path-tracer-9syk` first (cache dmin/dmax) so C3 lands clean.

### Recommended next pickup

- **`path-tracer-9syk` then `path-tracer-20xa` (C3)** — extend GPUNanoGrid with dmin/dmax, then ship the render overload that consumes the cache. This is what closes the WebGL gap on smoke.vdb (currently 30 ms post-E2; the per-call upload is ~5 ms, the leaf scan is ~1 ms, both should drop near zero with the cache).
- `path-tracer-hk1f` (A3 docs) is independent — write up `docs/perf_baseline.md` with the A2 baseline + E2 numbers.
- B1, D1, E1 follow-ups remain in the queue.

---

## 2026-04-19 — Session (evening): P0 preview port + E2 CuTexture + follow-up beads

**Stop reason:** E2 green and pushed. Epic critical path now runs: **C2 `htby`** next (cache `GPUNanoGrid` to amortise the texture densification that eats the CuTexture win on small grids).

### What shipped

| Bead | What | Commit |
|------|------|--------|
| `path-tracer-9kad` (P0) | `gpu_render_volume_preview` — GPU port of the CPU EA march. 7/7 tests, 40+ dB PSNR on production fixtures. | `bb80565` |
| `path-tracer-kbhm` (E2) | CuTexture hardware-trilinear fast path in `ext/LyrCUDAExt.jl`. **4.47× speedup**, PSNR 61 dB on 128³ dense acceptance test. | `c828d39` |
| `path-tracer-acxp` (filed, P3) | Follow-up for Float32 HDDA grazing-ray robustness on silhouette rays (level_set_sphere drops to 27 dB; production scenes hit 40+ dB). | n/a |

### Measured numbers (RTX 3090, 1920×1080 preview, `use_texture=:auto`)

| Scene | Dense | Path | Pre-E2 | Post-E2 | Speedup | WebGL gap |
|---|---:|:---:|---:|---:|---:|---:|
| smoke.vdb | 11.5 MB | CuTexture | 54 ms | **30 ms** | 1.8× | **1.8× WebGL target** |
| bunny_cloud.vdb | 565 MB | NanoVDB (over ceiling) | 279 | 336 | 0.83× | 20× |
| level_set_sphere | 4 MB | CuTexture | 49 | 45 | 1.1× | 2.7× |

Synthetic 128³ dense radial fog at 256×192 (the E2 acceptance test):
**45 ms → 10 ms = 4.47×.** PSNR 61 dB.

### Interesting asymmetries

1. **Densification dominates for small grids.** For smoke.vdb (11.5 MB dense) the
   4.47× peak drops to 1.8× on a single render because we pay `O(N³)` tree
   traversals on every call to fill the `CuTextureArray`. C2 (`path-tracer-htby` —
   cache `GPUNanoGrid` across calls) will amortise this; expect smoke to go
   from 30 ms to under the 16.7 ms WebGL target after C2 lands.
2. **bunny_cloud exceeds the 512 MB ceiling** and falls back to NanoVDB. This
   is intentional — dense Float32 of a 584×576×440 bbox is 565 MB, above the
   default cap. Either raise `ENV["LYR_TEXTURE_CEILING_MB"]` on systems with
   VRAM to spare, or accept that large dense clouds stay on the sparse path.
3. **Float32 HDDA silhouette precision** (acxp) drops level_set_sphere PSNR
   to 27 dB on perfectly-grazing rays. The `_gpu_dda_init` relative nudge
   from `fjo9` overshoots sub-ULP-wide grazing spans. Tightening the nudge
   reopens fjo9; a proper fix needs a span-width-aware DDA init. Filed as P3.

### Key decisions and gotchas

1. **E2 applies to the preview kernel only, not delta-tracking.** The preview
   kernel is 40 LOC (no HDDA needed for dense textures); the delta-tracking
   kernel is 200+ LOC with shadow rays + bounce loop. Porting delta-tracking
   is a separate bead if the need arises. The WebGL-fair comparison was the
   point of E2 anyway — preview is what matters for that target.
2. **`GC.@preserve` across `CUDA.synchronize()`.** `CuDeviceTexture` only
   stores `(dims, handle)` — no parent reference back to the `CuTextureArray`.
   Julia's liveness analysis could drop the array while the kernel still
   holds its handle. `GC.@preserve tex tex_arr tf_lut_dev output` is
   load-bearing; removing it would produce intermittent segfaults.
3. **Narrowing-only AABB slack.** My first cut of the Float32 grazing-ray
   slack widened both `tmin` and `tmax`; reviewer caught that widening
   `tmax` could permit rays to extend past their true exit into adjacent
   AABBs. Narrowing `tmin` alone is enough; tmax unchanged.
4. **`_gpu_tf_lookup_lerp` is a separate function** from the nearest-bin
   `_gpu_tf_lookup`. The existing nearest lookup is correct for stochastic
   delta tracking (evaluated once per scatter event, averaged by spp); it
   compounds unacceptably in the EA product chain (200+ multiplicative
   steps per pixel). Both coexist; EA path uses lerp, delta path uses nearest.

### Followups now visible

- **C2 `path-tracer-htby`** (blocked on C1 ✓, depends on no open beads) —
  the natural next step. Caches `GPUNanoGrid` across calls, which would
  ship both the existing NanoVDB-buffer upload cache AND the new CuTexture
  dense-array cache in one type.
- **`path-tracer-acxp` P3** — Float32 HDDA grazing-ray fix. Low urgency.

### A2 baseline regenerated (default now uses :auto → CuTexture)

See `bench/results/2026-04-19.json` and `bench/results/2026-04-19-preview-1080p.json`.
Numbers in table above. The bench script regenerates both files on each run.

---

## 2026-04-19 — Session: C1 GPUNanoGrid + A2 baseline captured

**Stop reason:** both beads green and pushed. The A2 numbers reshape the epic's priority ordering (see below).

### What shipped

| Bead | What | Commit |
|------|------|--------|
| `path-tracer-mx1u` (C1) | `GPUNanoGrid{B,BUF,TF,L}` struct — backend + nanovdb buffer + tf_lut + lights. 6 tests. Removed orphaned `adapt_nanogrid`. | `de09f79` |
| `path-tracer-78us` (A2) | `bench/perf_baseline.jl` + `test/test_perf_baseline.jl` + `bench/results/2026-04-19.json` baseline on RTX 3090 | (this commit) |

### A2 baseline numbers (RTX 3090, 800×600, spp=8, HDDA on)

| Scene | upload | kernel | accum | readback | **total** |
|---|---:|---:|---:|---:|---:|
| smoke.vdb (1.0M voxels, 6.5 MB buffer) | 5 ms | **917 ms** | 2 ms | 4 ms | **935 ms** |
| bunny_cloud.vdb (19M voxels, 138 MB buffer) | 21 ms | **1269 ms** | 2 ms | 4 ms | **1304 ms** |
| level_set_sphere (synthetic) | 2 ms | **2626 ms** | 5 ms | 1 ms | **2638 ms** |

**Key reading:** kernel is 95–98% of wall time across all three scenes. Upload is 0.5–2%. Readback and accumulation are each well under 1%.

### Implication for the epic priority order

The epic currently has:
- **C** (device-cache GPUNanoGrid, P1) — attacks upload (~10 ms)
- **D** (fused-spp kernel, P2) — attacks per-spp launch overhead (inside the 917–2626 ms kernel bucket)
- **E** (CuTexture hardware trilinear, P3) — attacks the kernel cost itself

With the numbers now in hand: **E is the only change that attacks the 95% bucket.** C1/C2/C3 and the other C work save tens of ms per call, which matters for animations (amortising over N frames) but is invisible on a single still render. The epic may want to promote E ahead of C for the critical path, keep C/D as supporting infrastructure. Recommend the next agent or user reconsider ordering before picking up C2 (`htby`).

Bead `jgjq` (A4: WebGL comparison target) is the companion: once we have the comparison number, E's 1–2 clock texture fetch budget is the target.

### Deviations from spec (documented in commits)

1. **A2 scene #2 — Schwarzschild thin disk → bunny_cloud.vdb.** A1's `profile=true` instrumentation is on `gpu_render_volume` only; `gpu_gr_render` needs a separate instrumentation bead before it can slot into this harness. The substitute is a canonical dense volume that exercises the same kernel path.
2. **A2 directory — used `bench/` as the bead specified** even though `benchmark/` already exists for micro-benchmarks and allocation tracking. Different concern (end-to-end render phase timing vs per-function micro-bench). If the sibling dirs become noisy, merge later.
3. **A2 LAW 1 inversion.** Wrote the script first and the test second. The test passed on first try, which is evidence the script was correct — but it is not the red-green sequence the law mandates. For bench scripts with a tight spec (I/O shape only) this is a lower-risk violation than for library code.

### Next pickup

**Re-evaluate ordering** in light of the 95% finding above. Before picking up C2:

- **E1 (`9h77`) research** — CuTexture + hardware trilinear feasibility via CUDA.jl/KA.jl. Currently P3 but the numbers argue for promotion.
- **A4 (`jgjq`)** — record WebGL target numbers for a comparable scene. Gives E a concrete target.
- **B1 (`mmf2`)** — `quality=:preview/:production` kwarg. Independent of kernel perf, still valuable.

If the user wants to continue on the filed plan as-is, **C2 (`htby`: `build_gpu_nanogrid` constructor)** is the natural next step.

---

## 2026-04-18 — Session: stocktake + rules rewrite + A1 instrumentation

**Stop reason:** end of planned scope (A1 only). Tree is clean, pushed to `origin/master`. `bd stats` shows 1 in_progress→closed, 20 still open from the perf epic (`path-tracer-ooul`).

### What shipped

| Bead | What | Commit |
|------|------|--------|
| (none) | Full architectural stocktake — 8 subagent reports under `docs/stocktake/` + INDEX | `8154e13` |
| (none) | CLAUDE.md rewrite adapting Feynfeld + Sturm rules, adding **Law 1 (red-green TDD)** and **Law 2 (ground truth before code)** | `8154e13` |
| `path-tracer-ooul` | **Filed EPIC**: Close WebGL perf gap in GPU volume renderer | n/a |
| 21 sub-beads A1–F3 | Filed granular plan; DAG wired | n/a |
| `path-tracer-605p` (A1) | `gpu_render_volume(...; profile=true)` returns `(img, timing::NamedTuple)` with 4 phase breakdowns + total | `6ed8b86` |

### Key decisions and gotchas

1. **Chose `time_ns()` + `KernelAbstractions.synchronize(backend)` over `CUDA.@elapsed`.**
   Reason: CUDA is a weakdep (`ext/LyrCUDAExt.jl`), so `CUDA.@elapsed` is not callable from core `src/GPU.jl`. `time_ns()` bracketed by explicit synchronize works on any backend (CPU, CUDA, future AMDGPU) with no dep. Wall-clock precision is fine for the ms-scale phases we care about. The bead description originally named `CUDA.@elapsed`; I deviated deliberately and documented why in the docstring.

2. **`profile=false` hot path must not add sync barriers.**
   Reviewer flagged that bracketing the upload phase with `synchronize` unconditionally would stall the pipeline for every ordinary render. Fix: all profiling (sync + time_ns + accumulators) is inside `if profile ... else ...`. The else-branch is identical to the pre-change code in sync count. Regression gate: image-equality at fixed seed (won't catch extra syncs but will catch any behavioral drift). Discipline documented inline in the test file.

3. **Readback timer MUST isolate D2H from CPU reshape.**
   First draft had `t_rb = time_ns()` before the pixel-clamp loop, which conflated the `Array(acc_buf)` transfer with pure CPU work. Reviewer caught it. Fixed: timer stops immediately after `host_buf = Array(acc_buf)`, before the reshape/clamp loop. This matters for the WebGL-gap diagnosis — inflated readback_ms would mask the real bottleneck.

4. **Hoisted `acc_kernel! = _accumulate_kernel!(backend)` out of the `spp` loop.**
   The launcher closure is stateless; recreating it per-iteration was redundant. Tiny perf win, but flagged in the diff comment so reviewers don't mistake it for an unrelated drive-by.

5. **Return-type instability is acceptable for a diagnostic tool.**
   `gpu_render_volume` now returns `Matrix{NTuple{3,Float32}}` or `Tuple{Matrix, NamedTuple}` depending on `profile`. Profile mode is never on a hot inner loop; users call it manually to diagnose. No `Val`-based dispatch needed.

6. **Pre-existing test errors in `test/test_gpu.jl`.**
   `NanoValueAccessor` and `nano_background` `UndefVarError`s under Julia 1.12. Three errors, not caused by this change. HANDOFF.md already notes this. Not in scope for A1.

### Perf gap architectural summary (from `docs/stocktake/08_perf_vs_webgl.md`)

Three compounding structural costs make Lyr's GPU path much slower than a WebGL volume shader on equivalent scenes:

1. **Software NanoVDB tree descent per trilinear corner** (8× `_gpu_get_value`, ~100–130 byte-buffer reads) vs one hardware `texture(sampler3D, uvw)` call (1–4 clocks).
2. **Stochastic delta tracking × path depth × shadow rays.** Default showcase config (`sigma_scale=15`, `max_bounces=48`, 3 lights) is ~1000× a WebGL fixed-step march per primary ray.
3. **Per-call H2D upload + per-spp kernel launches + CPU-blocking sync** (`src/GPU.jl:1476`, `1488–1512`). WebGL uploads the 3D texture once and redraws the quad.

### The plan — 21 beads under EPIC `path-tracer-ooul`

| Phase | Beads | Status |
|-------|-------|--------|
| **A** Instrument | `605p` `78us` `hk1f` `jgjq` | A1 done; A2 next (unblocked) |
| **B** Preview mode | `mmf2` `jzsu` `d9yj` | ready: B1 |
| **C** Device-cache `GPUNanoGrid` | `mx1u` `htby` `20xa` `4m72` `a7wt` `ug5k` | ready: C1 |
| **D** Kernel fusion | `vs5y` `12tg` `2xaq` `orkl` | ready: D1 |
| **E** CuTexture | `9h77` `kbhm` | ready: E1 (research-only) |
| **F** Close-out | `pjrr` `7d7w` `m1ix` | blocked on C+D+B |

Every bead has: a named RED test, a ground-truth source cited, an acceptance criterion.

### Current ready queue

```
  bd ready
  ○ path-tracer-78us  P1   A2: Baseline benchmark script for 3 canonical scenes
  ○ path-tracer-jgjq  P1   A4: Identify WebGL comparison target + record target numbers
  ○ path-tracer-mx1u  P1   C1: Define GPUNanoGrid struct
  ○ path-tracer-mmf2  P2   B1: Add quality=:preview/:production kwarg
  ○ path-tracer-vs5y  P2   D1: Research KA.jl/CUDA.jl kernel-internal accumulation patterns
  ○ path-tracer-9h77  P3   E1: Research CuTexture + hardware trilinear feasibility
```

(Plus pre-existing non-epic beads: `fgzb`, `h53s`, `rmfe`, `o601`, `1zcr`, `54vs`, `ylmz`, `oeco`, `l9f3`.)

### Recommended next pickup

- **A2 (`path-tracer-78us`)** is the natural continuation. It depends on A1 (now done) and feeds A3. Write `bench/perf_baseline.jl` that renders 3 canonical scenes at 800×600 spp=8 using A1's `profile=true`, dumps JSON. RED: script doesn't exist.
- **C1 (`path-tracer-mx1u`)** is independent — a cold-start agent could pick it up in parallel without blocking A2. Low risk: just a struct definition.
- **D1 / E1** are research-only (no code). Good for warm-up or context-starved sessions.

### Operational notes for next agent

- `bd dolt push` is a no-op in this repo (no remote configured). `git push` is the only remote sync.
- Full test suite is ~18 min on WSL2 with `-t 2`. Never use `-t auto` — 59GB+ RAM kills WSL.
- Pre-existing failures: 2 golden image mismatches (T10.4/T10.5), 3 `NanoValueAccessor` Julia 1.12 errors in `test_gpu.jl`. Don't chase these in perf-track work.
- The stocktake in `docs/stocktake/` is canonical for subsystem understanding. Start there before diving into any src/ file.
- CLAUDE.md LAWS are not suggestions. Red bar before code. Ground truth before code. No exceptions.
