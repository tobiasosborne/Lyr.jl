# Lyr.jl Work Log

Gotchas, learnings, decisions, surprises. Updated every step.
Institutional memory for future agents. If you hit something non-obvious, write it down before moving on.

Rule 0 of CLAUDE.md is implicit: *maintain this file*.

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
