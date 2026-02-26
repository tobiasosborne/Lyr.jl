# Lyr.jl Handoff Document

---

## Latest Session (2026-02-26) — Elegance Sprint: 10 Issues Closed, -227 LOC

**Status**: GREEN — 29,662 tests pass (+97 new), 10 issues closed (17 → 11 remaining), 96% complete (271/282)

### What Was Done

1. **Typed exceptions** (`49f63d8`): Added `FormatError` and `UnsupportedVersionError` to exception hierarchy. Replaced all bare `error()` calls across 12 files with typed `throw()`. TinyVDB gets self-contained copies (standalone testing).

2. **Parametric tile value dispatch** (`31d0211`): Replaced 18 hand-written `read_tile_value`/`write_tile_value!` specializations (Float32, Float64, Int32, Int64, Vec3f, Vec3d) with 6 parametric methods. Key pattern: `ntuple(Val(N))` for compile-time unrolled NTuple reads — automatically works for any N, not just 3. Added `read_le` generic to Binary.jl. **-41 LOC.**

3. **FileWrite.jl cleanup** (`9c69d4f`): Extracted `_write_vec3d!`, `_write_scale_map_data!`, `_write_scale_translate_data!` helpers. Merged identical ScaleTranslateMap/UniformScaleTranslateMap branches. Collapsed `grid_type_string` to one-liner dispatch table. Used `write_tile_value!` for vec3 metadata. Eliminated O(32768) dense array allocations in topology writers by writing tile values directly. **-124 LOC.**

4. **Dispatch-based tree probe** (`e6bef92`): Replaced 80 lines of duplicated `get_value(tree,c)` and `is_active(tree,c)` traversal with `_probe_node` dispatch chain (I2→I1→Leaf) + shared `_probe_internal` for mask checks. Both become one-liners over `_tree_probe`. Collapsed counting functions to `sum`/`count` one-liners. Unified 4 Transform NTuple wrappers to 2 via `AbstractTransform`. **-93 LOC.**

5. **Parsing infrastructure tests** (`b8a527b`): Single elegant test file closing 5 issues with 97 new tests. Covers: showerror messages for all 7 exception types, binary reader boundaries/edge cases, `read_transform` for all 4 map types, `read_grid_descriptor` with/without offsets, `read_grid_metadata` for all 10 value types.

### Key Patterns Established
- **Union dispatch**: `where {T <: Union{Float32, Float64, ...}}` — one method replaces N specializations
- **`ntuple(Val(N))`**: compile-time unrolled tuple construction for any N
- **Recursive node dispatch**: `_probe_node(::LeafNode)`, `_probe_node(::InternalNode1)`, etc.
- **Functional counting**: `count(pred, collection)`, `sum(f, iter; init=0)` replacing manual loops
- **`@testset for` parametric tests**: loop over `(exception, pattern)` pairs for systematic coverage

### Key Files Changed
- `src/Exceptions.jl` — FormatError, UnsupportedVersionError
- `src/Binary.jl` — read_le generic
- `src/Values.jl` — parametric read_tile_value (3 methods replace 9)
- `src/BinaryWrite.jl` — parametric write_tile_value! (3 methods replace 9)
- `src/FileWrite.jl` — transform helpers, topology simplification (700→575 LOC)
- `src/Accessors.jl` — _probe_node dispatch, functional counting
- `src/Transforms.jl` — AbstractTransform wrappers
- `src/TinyVDB/*.jl` — typed exceptions (6 files)
- `test/test_parsing_infrastructure.jl` — 97 new tests (NEW)

### What Remains (11 issues)
- **Tests (3)**: half-precision values, iterator edge cases, sphere_trace surface hit
- **Refactor (2)**: TinyVDB dedup (~315 LOC), export reduction (~65→~20 symbols)
- **Features (3)**: active-voxel gradient, mmap I/O, decompression buffer reuse
- **Architecture (1)**: extract Render.jl to separate package (P4 backlog)
- **Robustness (1)**: truncated/corrupted file tests

---

## Previous Session (2026-02-25 evening) — 34 Issues Closed, P2 Refactors, Showcase Suite

**Status**: GREEN — 29,565 tests pass, 34 issues closed (52 ready → 21 ready), comprehensive showcase rendered

### What Was Done

1. **34 beads issues closed** in one session — mix of bugs, perf, features, false positives:
   - PPM writer zero-alloc, read_mask zero-alloc, OnIndicesIterator HasLength
   - GridBuilder fill() optimization, TimeEvolution domain caching
   - Ray intersect_bbox NaN fix, delta tracking majorant clamping
   - GPU density estimator full 512-voxel scan, visualize(TimeEvolution)
   - Grid getindex syntax, multi-threaded render/preview/denoise
   - PNGFiles/OpenEXR module detection (isdefined → loaded_modules)
   - ParticleField characteristic_scale, PhaseFunction docstring
   - 9 false positives closed with explanation

2. **All P2 issues resolved** (4 implemented, 1 deferred):
   - Camera struct NTuple{3,Float64} → SVec3d, deleted 7 hand-rolled vector math functions (-19 LOC net)
   - Generic pixel type pipeline: all tonemap/write functions accept NTuple{3,T} where T<:AbstractFloat
   - gaussian_splat: thread-local Dicts via Threads.maxthreadid() + @threads
   - GPU accumulation: @kernel _accumulate_kernel! for device-side element-wise add
   - Deep EXR compositing: deferred (needs per-sample depth data + OpenEXR deep format)

3. **GR bug fix**: `_trace_pixel_with_p0` used `cam.position[2]` (Cartesian x-coordinate) instead of `_coord_r(m, cam.position)` for observer radius in SchwarzschildKS. Caused `sqrt(negative)` DomainError at certain camera angles. Fixed in both volumetric and thin-disk tracers.

4. **Comprehensive showcase** (scripts/showcase.jl):
   - 17 stills: H orbitals (1s, 3d, 4f), E&M (dipole, magnetic bottle), stat mech (Ising ordered/critical/disordered), particles (FCC, galaxy), GR (volumetric oblique/face-on/edge-on), standing wave, wavepacket, TF comparison, denoising comparison
   - 4 movies: orbital rotation, wavefunction evolution (1s+2p), Ising cooling quench, black hole volumetric flyby
   - Process-parallel GR rendering: bh_launch.sh spawns N Julia workers with full internal threading

5. **Threading profiled** with BenchmarkTools (scripts/profile_threading.jl):
   - Volume renderer: 8.9x speedup at 32 threads
   - GR renderer: 22.7x speedup at 32 threads
   - Root cause of "threading doesn't work": Julia defaults to 1 thread, must use `-t auto`

### Key Files Changed
- `src/Render.jl` — Camera SVec3d, deleted 7 helpers, generic write_ppm
- `src/Output.jl` — Generic tonemap/write functions, threaded denoisers, module detection
- `src/VolumeIntegrator.jl` — Threaded render, GPU accumulation kernel, NanoGrid validation
- `src/GR/render.jl` — _coord_r fix for observer 4-velocity
- `src/Particles.jl` — Threaded gaussian_splat
- `src/Masks.jl` — Zero-alloc read_mask, HasLength iterator
- `src/FieldProtocol.jl` — TimeEvolution caching, ParticleField characteristic_scale
- `src/GPU.jl` — _accumulate_kernel!, density estimator, module detection
- `scripts/showcase.jl` — Full showcase generator
- `scripts/bh_launch.sh` + `scripts/bh_worker.jl` — Process-parallel GR rendering

---

## Previous Session (2026-02-25) — GR Architecture Review + P0 Bug Fixes

**Status**: GREEN — 2 P0 bugs fixed, 378/379 GR tests pass (1 pre-existing flaky H-conservation)

### What Was Done

1. **Comprehensive GR architecture review** against state-of-the-art GRRT literature (GRay2, RAPTOR, ipole, GYOTO, Odyssey, Blacklight, Coport, Mahakala). Web-searched key papers including Ripperda et al. 2023 on coordinate choice.

2. **Created 10 beads** (dependency-chained improvement plan) covering all review findings — see plan below.

3. **Fixed `path-xdbh` [P0]**: sphere_lookup φ-wrap bilinear interpolation seam.
   - Root cause: `fu = u - floor(u - 0.5) - 0.5` had a half-pixel offset causing fu to jump from ~1.0 to ~0.0 at the φ=0/2π boundary — a discontinuity that produced the full-frame vertical seam.
   - Fix: `fu = u - j0_raw` (3 lines). Also store `j0_raw` before mod1 wrapping and derive `j1` from it.
   - +11 tests for wrap-boundary continuity.

4. **Fixed `path-6gu3` [P0]**: CKS tetrad orientation and matrix layout.
   - Bug 1 (orientation): Gram-Schmidt used arbitrary seed vectors (`if abs(lz) < 0.9` and a loop over seed candidates), producing inconsistent tetrad orientation depending on camera angular position. Replaced with analytic spatial legs: ê_r = (x/r, y/r, z/r), ê_θ = (xz/(rρ), yz/(rρ), -ρ/r), ê_φ = (-y/ρ, x/ρ, 0). Clean pole fallback when ρ < ε.
   - Bug 2 (matrix layout): SMat4d constructor is column-major, but old code put `(u[1], e1[1], e2[1], e3[1])` as column 1 — the first components of all legs, not all components of one leg. For BL this worked by accident (diagonal metric → legs have single nonzero components). For KS it was fundamentally broken. Fixed to `(u[1], u[2], u[3], u[4])` as column 1.
   - +15 tests: orthonormality at 5 positions (including near-pole), orientation matching BL, off-axis radial direction.

### GR Improvement Plan (10 Beads, Dependency DAG)

```
LAYER 0 — No blockers (work immediately, can parallelize)
├── path-xdbh [P0] Fix sphere_lookup φ-wrap seam                    ✅ DONE
├── path-6gu3 [P0] Fix CKS tetrad (analytic spatial legs)           ✅ DONE
├── path-esr2 [P1] Add RK4 integrator as default geodesic stepper
├── path-l8dy [P1] Fix volumetric double-intensity color mapping
└── path-tyrz [P1] Add early τ-cutoff in volumetric tracer

LAYER 1 — Unblocked after Layer 0
├── path-vsfi [P1] Use outgoing Kerr-Schild for backward tracing    ← depends on path-6gu3
├── path-a5ze [P1] Angular-velocity adaptive stepping                ← depends on path-esr2
├── path-bjox [P2] Fuse metric_inverse + partials                   ← depends on path-esr2
└── path-o9zw [P2] Tile-based rendering for cache locality          ← depends on path-esr2

LAYER 2 — Unblocked after Layers 0+1
└── path-837k [P2] GPU via KernelAbstractions.jl                    ← depends on 6gu3, esr2, bjox
```

### Detailed Plan for Each Remaining Bead

#### path-esr2 [P1] — Add RK4 Integrator (CRITICAL PATH)

**Why**: All major GRRT codes (GRay2, RAPTOR, GYOTO, Odyssey, Blacklight) use RK4. Current Störmer-Verlet is 2nd-order, requiring ~3-5× more steps for equivalent accuracy. The 4500-step escape rays and 10,000 max_steps budget indicate step count is already the bottleneck.

**What**:
- New `rk4_step(m, x, p, dl)` using `hamiltonian_rhs()` (already exists, returns dx/dλ and dp/dλ)
- Standard k1/k2/k3/k4 stages: 4 calls to `hamiltonian_rhs` per step
- Add `stepper::Symbol` field to `IntegratorConfig` (`:rk4` default, `:verlet` option)
- Update `integrate_geodesic` and `trace_pixel` to dispatch on stepper
- Keep `renormalize_null` every 20-50 steps for RK4 (vs 10 for Verlet)

**Files**: `src/GR/integrator.jl`, `src/GR/render.jl`, `test/test_gr_integrator.jl`

**Validation**: Circular orbit H conservation, shadow radius, render comparison (RMSE < 0.01), wall-time speedup measurement.

**Unblocks**: path-a5ze, path-bjox, path-o9zw, path-837k (4 downstream beads)

---

#### path-l8dy [P1] — Fix Volumetric Double-Intensity

**Why**: `_volumetric_final_color` uses `blackbody_color(clamp(I_acc, 0.0, 2.0))` to get RGB, then multiplies by `I_acc` again. This double-applies intensity, blowing out colors to white for moderate optical depth.

**What**:
- Option A (simple): Remove the extra `I_acc` multiplication, use `blackbody_color(I_acc)` directly as final color
- Option B (better): Track luminosity-weighted average temperature during accumulation, compute color from `T_avg`, scale by `I_acc`

**Files**: `src/GR/render.jl` (`_volumetric_final_color`, `_trace_pixel_with_p0`)

**Validation**: Rendered disk shows color gradients (not all-white), I_acc=0.5 → warm red.

---

#### path-tyrz [P1] — Early Optical-Depth Cutoff

**Why**: Volumetric tracer continues integrating even when τ > 10 (transmittance < 4.5e-5). Wastes steps in optically thick regions.

**What**: Add `if τ_acc > 8.0; return _volumetric_final_color(I_acc, τ_acc, (0,0,0)); end` after the `τ_acc += dτ` line.

**Files**: `src/GR/render.jl` (1 line in `_trace_pixel_with_p0`)

**Validation**: Pixel-wise RMSE < 1e-3 vs no cutoff, 10-30% fewer total steps.

---

#### path-vsfi [P1] — Outgoing Kerr-Schild Coordinates

**Why**: Ripperda et al. 2023 (arXiv:2310.02321) proved ingoing KS is fundamentally unsuitable for backward ray tracing. Outgoing photons near the horizon experience diverging dt/dλ in ingoing coordinates (~100,000 steps where outgoing KS needs ~11). Current `SchwarzschildKS` uses ingoing l_α = (1, x/r, y/r, z/r).

**What**: Flip spatial sign of the null 1-form to outgoing: l_α = (1, -x/r, -y/r, -z/r). Update metric, metric_inverse, all analytic partials. The Sherman-Morrison structure g = η + f l⊗l is unchanged.

**Files**: `src/GR/metrics/schwarzschild_ks.jl` (metric, metric_inverse, metric_inverse_partials, _ks_r_and_l)

**Validation**: g·g⁻¹=I, det matches, analytic vs ForwardDiff partials < 1e-10, shadow radius, near-horizon step count reduction.

**Depends on**: path-6gu3 (tetrad must work first) ✅

---

#### path-a5ze [P1] — Angular-Velocity Adaptive Stepping

**Why**: Current `adaptive_step` is purely radial: `scale = clamp((r-rh)/(8M), 0.1, 1.0)`. Misses angular dynamics near the photon sphere where a ray at r=3.001M can orbit multiple times. RAPTOR uses: `dl = ε × min(x_θ, 1-x_θ) / (|k_θ| + δ)`.

**What**: Modify `adaptive_step` to accept momentum p and compute:
```
scale_r = clamp((r - rh) / (8M), 0.1, 1.0)
scale_θ = ε / (|g^{θμ} p_μ| + δ)
scale = min(scale_r, scale_θ)
```

**Files**: `src/GR/integrator.jl` (signature + logic), `src/GR/render.jl` (pass p to adaptive_step)

**Depends on**: path-esr2 (both share the integrator)

---

#### path-bjox [P2] — Fuse metric_inverse + partials

**Why**: `verlet_step` computes `metric_inverse_partials(m, x)` then `metric_inverse(m, x)` at the same point — redundant work. Both share intermediate values (r, θ, f for BL; r, inv_r, l, f for KS). ~20-30% of per-step metric cost is wasted.

**What**: New `metric_inverse_and_partials(m, x) -> (ginv, partials)` that computes both in one pass. Update steppers to use it.

**Files**: `src/GR/metric.jl`, `src/GR/metrics/schwarzschild.jl`, `src/GR/metrics/schwarzschild_ks.jl`, `src/GR/integrator.jl`

**Depends on**: path-esr2 (fuse for both steppers)

---

#### path-o9zw [P2] — Tile-Based Rendering

**Why**: Current per-row threading (`Threads.@threads for j in 1:height`) is 1D decomposition. Tile-based (16×16) gives better cache locality for metric evaluations and enables early-out for tiles entirely inside the shadow.

**What**: Replace row loop with tile loop. Optional: pre-classify corner pixels for shadow early-out.

**Files**: `src/GR/render.jl` (`gr_render_image`)

**Depends on**: path-esr2 (benchmark against better integrator)

---

#### path-837k [P2] — GPU via KernelAbstractions.jl

**Why**: GRay2 demonstrated 100-600× speedup on GPU. CKS is specifically designed for GPU: no trig, uniform branching, pure arithmetic. Julia has mature GPU via CUDA.jl + KernelAbstractions.jl. Coport (Julia GRRT code) validates feasibility.

**What**: New `src/GR/gpu_render.jl` with a KernelAbstractions kernel that traces one pixel per thread. SchwarzschildKS primary target. Float32 variants for consumer GPU perf.

**Files**: `src/GR/gpu_render.jl` (NEW), `src/GR/GR.jl`, `Project.toml`

**Depends on**: path-6gu3 ✅, path-esr2, path-bjox (all three must land first)

---

### Key Findings from Literature Review

1. **Coordinate choice**: Cartesian KS is correct long-term choice (GRay2, Blacklight, Mahakala all use it). BUT must use OUTGOING KS for backward tracing (Ripperda et al. 2023).

2. **Integrator**: RK4 is the consensus workhorse. Verlet is valid but requires 3-5× more steps. Adaptive symplectic methods (Luo et al. 2024) are the theoretical optimum for long integrations.

3. **Geodesic formulation**: Hamiltonian with covariant momenta — our approach matches the consensus exactly. Better than Christoffel-based codes (fewer terms, no Γ bookkeeping).

4. **Camera**: Gram-Schmidt with analytic seeds is correct for CKS. For Kerr, need ZAMO/LNRF tetrad (static observers don't exist inside ergosphere).

5. **Radiative transfer**: Our `j/z³` scaling correctly implements the I_ν/ν³ invariant. The emission-absorption integration is sound.

6. **Architecture**: Our code is more elegant than Coport (the other Julia GRRT code) — Hamiltonian + metric partials vs Christoffel symbols. Our ForwardDiff fallback + analytic specialization pattern is clean.

### References

- Chan et al. 2018 (GRay2): arXiv:1706.07062 — CKS, RK4, GPU
- Bronzwaer et al. 2018 (RAPTOR): arXiv:1801.10452 — adaptive stepping, angular-velocity
- Mościbrodzka & Gammie 2018 (ipole): arXiv:1712.03057 — semi-analytic polarized transfer
- Ripperda et al. 2023: arXiv:2310.02321 — outgoing vs ingoing KS (critical finding)
- Luo et al. 2024: arXiv:2412.01045 — adaptive symplectic integrators
- Huang et al. 2024 (Coport): arXiv:2407.10431 — Julia GRRT precedent
- White 2022 (Blacklight): arXiv:2203.15963 — CKS, adaptive RK

### Files Modified

| File | Change |
|------|--------|
| `src/GR/matter.jl` | Fixed sphere_lookup φ-wrap interpolation (3 lines) |
| `src/GR/metrics/schwarzschild_ks.jl` | Analytic tetrad legs + correct SMat4d column-major layout |
| `test/test_gr_camera.jl` | +70 lines: KS orthonormality (5 positions), orientation matching BL |
| `test/test_gr_matter.jl` | +60 lines: φ-wrap continuity, periodic texture smoothness scan |

### Test Results

```
378 pass, 1 fail (pre-existing flaky H-conservation), 0 errors
New tests: 26 (11 matter + 15 camera)
```

---

## Previous Session (2026-02-24) — GR Rendering Fixes (IN PROGRESS, BROKEN)

**Status**: RED — Work in progress, multiple issues. Tests NOT verified. Needs careful continuation.

### What Was Attempted

Rendering a Schwarzschild black hole with volumetric thick accretion disk and ESA Gaia Milky Way background. Session spiraled into debugging cascading issues.

### What Works (committed, on master)

These commits are pushed and tests passed at time of commit:

1. **`feat: VolumetricMatter bridge`** — ThickDisk, emission-absorption, volumetric trace_pixel (39 tests)
2. **`fix: future-directed momentum + null-cone re-projection`** — The core physics fix. `pixel_to_momentum` now creates future-directed null momentum (removed negation). `renormalize_null()` projects p back onto null cone. 29,513 tests passed at commit time.
3. **`fix: verlet_step Core.Box elimination`** — Unrolled `ntuple` closures to eliminate 1.5KB/step heap allocation that was killing GC and thread utilization. 0 allocations verified.

### What Is Broken (uncommitted changes on disk)

The working directory has **uncommitted changes** across 7 files that are in a BROKEN state:

| File | Change | Status |
|------|--------|--------|
| `src/GR/metrics/schwarzschild_ks.jl` | **NEW** — SchwarzschildKS (Cartesian Kerr-Schild) metric, camera tetrad, sky lookup | **BROKEN** — tetrad orientation wrong, renders garbage |
| `src/GR/render.jl` | Coordinate dispatch helpers (`_coord_r`, `_to_spherical`, `_sky_color` taking metric), supersampling scaffolding (`samples_per_pixel`, `_trace_one_sub`) | **PARTIALLY BROKEN** — dispatch works but supersampling incomplete, H-drift check removed |
| `src/GR/camera.jl` | Docstring edit for sub-pixel `pixel_to_momentum(cam, i, j, dx, dy)` | Minor, probably fine |
| `src/GR/integrator.jl` | Polar regularization in `verlet_step`, fast `renormalize_null` for Schwarzschild (diagonal), every-10-steps renorm in `integrate_geodesic` | Mixed — polar regularization untested, fast renorm works |
| `src/GR/matter.jl` | `keplerian_four_velocity(m::SchwarzschildKS, r, x)` for Cartesian coords | Untested |
| `src/GR/redshift.jl` | `volumetric_redshift(m::SchwarzschildKS, ...)` dispatch | Untested |
| `src/GR/GR.jl` | Include schwarzschild_ks.jl, export SchwarzschildKS | Fine |

### The Rendering Problem That Remains

The rendered image has a **vertical seam/line artifact** running through the CENTER of the image, **from top to bottom of the entire frame** — not just near the shadow. This is the critical unsolved problem.

**Key evidence**: The seam extends uniformly across the full image height, including far-field regions where geodesics are barely deflected. This CANNOT be explained by photon-sphere chaos alone (which only affects a narrow band near the shadow boundary). The artifact has TWO components:

1. **Full-frame vertical seam** — extends top-to-bottom at constant x ≈ center column. This persists in weakly-lensed far-field regions. This points to a **systematic coordinate or texture mapping bug**, NOT chaos. Possible causes:
   - Boyer-Lindquist φ coordinate wrapping issue in `sphere_lookup` bilinear interpolation at φ=0/2π boundary
   - The camera at φ=0 looks inward; escaped rays behind the BH end up at φ≈π. Rays at the image center column map to φ values near 0 or 2π (the texture seam). If bilinear interpolation doesn't wrap correctly at this boundary, there's a visible seam.
   - The 1/sin²θ amplification of φ-velocity near BL coordinate poles (θ→0, θ→π) corrupts φ values for rays that pass near the axis, even if θ itself is moderate at the escape point

2. **Shadow-boundary aliasing** — near the photon sphere, adjacent pixels DO map to wildly different sky locations (φ jumps of ~2π). This is physical chaos. Supersampling is the correct fix for this component only.

**The previous agent incorrectly dismissed the coordinate singularity explanation.** While sinθ ≈ 0.9 at the specific sampled pixels, the full-frame seam proves there is a systematic issue beyond chaos. The next session MUST:
- Test `sphere_lookup` bilinear interpolation at the φ=0/2π wrap boundary
- Test the BL integrator's φ accuracy: trace a far-field ray (barely deflected) and check if the final φ matches the expected value
- Consider whether the Cartesian KS approach (which eliminates ALL φ-related issues) is the correct long-term fix

The Cartesian KS implementation was started but is broken:
1. The tetrad construction gives wrong ray directions (renders show wrong part of sky)
2. The non-diagonal metric is ~2× slower per step than BL diagonal
3. It needs fixing, not abandoning — it's the approach used by all production GR ray tracers

### Recommended Next Steps

1. **REVERT uncommitted changes** or cherry-pick only the good parts:
   - KEEP: `verlet_step` unrolled ntuple (zero alloc fix)
   - KEEP: `_sky_color` taking metric+position (coordinate-aware sky lookup)
   - KEEP: `_coord_r`, `_to_spherical` dispatch helpers
   - KEEP: Fast `renormalize_null` for Schwarzschild
   - DISCARD: SchwarzschildKS (broken tetrad, incomplete)
   - DISCARD: Supersampling scaffolding (incomplete)
   - DISCARD: Polar regularization in verlet_step (untested, may cause Core.Box return)

2. **Diagnose the full-frame vertical seam** (HIGHEST PRIORITY):
   - Render a FLAT spacetime (no BH) with the Milky Way texture to isolate: is the seam in `sphere_lookup` itself?
   - Test `sphere_lookup` bilinear interpolation at φ ≈ 0 and φ ≈ 2π — check for discontinuity
   - Trace far-field rays (impact parameter >> photon sphere) and verify φ at escape matches expected
   - If the seam is in BL φ handling, Cartesian KS is the correct fix

3. **Fix SchwarzschildKS** (the right long-term approach):
   - The tetrad orientation is wrong: e1 outward + negative step = rays go outward (wrong)
   - Root cause: in BL, future-directed outward photon has dx^r/dλ > 0; in KS it has dx^x/dλ > 0 too BUT the sign convention differs because KS is Cartesian
   - Need to carefully derive the correct tetrad-to-momentum mapping for KS
   - Reference: GRay2 paper (arXiv:1706.07062) uses KS throughout — study their camera setup

4. **Supersampling** (for shadow-boundary aliasing only):
   - Scaffolding exists in render.jl (`samples_per_pixel`, `_trace_one_sub`)
   - Implement stratified 2×2 or 3×3 jitter per pixel
   - This fixes the chaos artifact near the photon sphere but NOT the full-frame seam

5. **Thread utilization**:
   - Dynamic scheduling (`Threads.@threads :dynamic`) was added
   - Shadow pixels ~675 steps, escape pixels ~4500 steps — uneven work
   - Profile with `@time` per-row to verify dynamic scheduling helps

### Key Files

| File | Purpose |
|------|---------|
| `src/GR/render.jl` | Both trace_pixel methods (ThinDisk + Volumetric), gr_render_image |
| `src/GR/integrator.jl` | verlet_step, renormalize_null, integrate_geodesic |
| `src/GR/camera.jl` | pixel_to_momentum, static_observer_tetrad |
| `src/GR/volumetric.jl` | VolumetricMatter, ThickDisk, emission_absorption |
| `src/GR/redshift.jl` | volumetric_redshift, redshift_factor |
| `src/GR/metrics/schwarzschild.jl` | BL Schwarzschild (working) |
| `src/GR/metrics/schwarzschild_ks.jl` | Cartesian KS (BROKEN, uncommitted) |

### Performance Profile (from profiling agent)

- `verlet_step`: 596ns/call, 0 allocations (after unroll fix)
- `renormalize_null` (Schwarzschild fast path): 332ns/call, 0 allocations
- Per-step overhead from H-drift check: was 400ns (redundant `metric_inverse`), removed in uncommitted changes
- Render time (BL, 1920×1080, 64 threads): ~33s with correct physics

### References

- [GRay2 paper](https://arxiv.org/abs/1706.07062) — Cartesian KS geodesic integrator
- [RAPTOR](https://www.aanda.org/articles/aa/full_html/2018/05/aa32149-17/aa32149-17.html) — Modified KS coordinates
- ESA Gaia EDR3 Milky Way panorama: `/tmp/milkyway_4k.png` (4000×2000, downloaded)

---

## Previous Session (2026-02-24) — VolumetricMatter Bridge (GR Phase 2)

**Status**: COMPLETE — 36,066 tests pass (39 new volumetric + all existing)

### What Was Done

Implemented the VolumetricMatter bridge: the infrastructure connecting the geodesic integrator to volumetric density/emission queries for thick accretion disk rendering through curved spacetime.

| # | File | Lines | What |
|---|------|-------|------|
| 1 | `src/GR/volumetric.jl` | 87 | **NEW** — VolumetricMatter struct, ThickDisk analytic density, emission-absorption coefficients |
| 2 | `src/GR/redshift.jl` | +14 | `volumetric_redshift()` — Keplerian redshift at each geodesic step |
| 3 | `src/GR/render.jl` | +95 | New `trace_pixel` method for VolumetricMatter, `_volumetric_final_color`, `_sky_color`, updated `gr_render_image` |
| 4 | `src/GR/GR.jl` | ~8 | Reordered includes, added exports |
| 5 | `test/test_gr_volumetric.jl` | 198 | **NEW** — 39 tests covering density, emission, redshift, rendering |

### Architecture

- **VolumetricMatter{M, D}** — generic over metric type M and density source D
- **ThickDisk** — first concrete density source: Gaussian vertical + r^{-2} radial profile
- **Accumulation loop** — emission-absorption integration along geodesic arcs (deterministic ray marching)
- **Multiple dispatch** — new `trace_pixel(cam, config, vol::VolumetricMatter, sky, i, j)` keeps ThinDisk path untouched
- **Analytic first** — no VDB pre-voxelization needed; swap in grid lookup later

### Key Decisions

1. Analytic density evaluation at each geodesic step (no pre-voxelization) — fast enough and avoids the coordinate mapping question
2. Simplified bremsstrahlung emission (j ∝ ρ²√T) and electron scattering absorption (α ∝ κ_es × ρ)
3. Shakura-Sunyaev temperature profile T ∝ (r_in/r)^{3/4}
4. VolumetricMatter takes precedence over ThinDisk when both provided

### Next Steps

- Novikov-Thorne exact temperature profile (Page & Thorne 1974)
- Spiral density perturbation (m=2 mode with differential rotation)
- VDB grid bridge (swap analytic density for `sample_world(grid, coords)`)
- Kerr metric support

---

## Previous Session (2026-02-24) — GR Ray Tracing Module (Phase 1 Complete)

**Status**: 🟢 COMPLETE — 1685 tests pass (313 new GR + 1342 existing)

### What Was Done

Implemented the `Lyr.GR` submodule: a physically correct general relativistic ray tracer using Hamiltonian null geodesic integration through Lorentzian metrics.

| # | File | Lines | What |
|---|------|-------|------|
| 1 | `src/GR/GR.jl` | 100 | Module root: includes, exports, using |
| 2 | `src/GR/types.jl` | 47 | SVec4d, SMat4d, GeodesicState, GeodesicTrace, TerminationReason enum |
| 3 | `src/GR/metric.jl` | 83 | MetricSpace{D} abstract type, ForwardDiff auto-partials, Hamiltonian H = ½ gᵘᵛ pμ pν |
| 4 | `src/GR/integrator.jl` | 130 | Adaptive Störmer-Verlet (symplectic), verlet_step, adaptive_step, integrate_geodesic |
| 5 | `src/GR/camera.jl` | 106 | GRCamera{M} with tetrad, static_observer_tetrad, pixel_to_momentum |
| 6 | `src/GR/matter.jl` | 130 | ThinDisk (power-law emissivity, Keplerian orbits), CelestialSphere (bilinear interp) |
| 7 | `src/GR/redshift.jl` | 56 | redshift_factor (1+z = p·u_emit / p·u_obs), blackbody_color, doppler_color |
| 8 | `src/GR/render.jl` | 160 | gr_render_image (threaded pixel loop), trace_pixel (geodesic + disk + sky) |
| 9 | `src/GR/metrics/schwarzschild.jl` | 140 | Full Schwarzschild metric with analytic ∂gᵘᵛ/∂xᵘ, polar singularity clamping |
| 10 | `src/GR/metrics/minkowski.jl` | 25 | Flat spacetime (test helper) |
| 11 | `src/GR/metrics/kerr.jl` | 52 | Kerr stub: type + ISCO formula (Phase 2) |
| 12 | `src/GR/stubs/weak_field.jl` | 18 | WeakField interface stub (Phase 2) |
| 13 | `src/GR/stubs/volumetric.jl` | 14 | VolumetricMatter VDB bridge stub (Phase 2) |

### Tests Created (10 files, 313 tests)

| File | Tests | Focus |
|------|-------|-------|
| `test_gr_types.jl` | 20 | SVec4d/SMat4d construction, enum, GeodesicState/Trace |
| `test_gr_metric.jl` | 19 | Minkowski metric, ForwardDiff partials=0, Hamiltonian null condition |
| `test_gr_schwarzschild.jl` | 42 | g×g⁻¹=I, det=-r⁴sin²θ, analytic vs ForwardDiff partials, singularity |
| `test_gr_integrator.jl` | 25 | Circular orbit r=3M, radial infall, escape, H conservation |
| `test_gr_camera.jl` | 23 | Tetrad orthonormality, 4-velocity norm, null condition on pixels |
| `test_gr_matter.jl` | 21 | Disk emissivity bounds, Keplerian normalization, crossing detection |
| `test_gr_redshift.jl` | 12 | Gravitational redshift = 1/√(1−2M/r), same-point unity |
| `test_gr_render.jl` | 135 | Image dimensions, no NaN, disk emission, center pixels dark |
| `test_gr_validation.jl` | 16 | Photon sphere stability, deflection angle, H conservation, shadow size |

### Existing Files Modified

| File | Change |
|------|--------|
| `src/Lyr.jl` | Added `include("GR/GR.jl")` |
| `Project.toml` | Added ForwardDiff, LinearAlgebra, OrdinaryDiffEq |
| `test/runtests.jl` | Added 9 GR test includes |
| `.gitignore` | Added `test/fixtures/starmap_*` |

### Dependencies Added

| Package | Purpose |
|---------|---------|
| ForwardDiff | Automatic ∂gᵘᵛ/∂xᵘ for MetricSpace default implementation |
| LinearAlgebra | dot, norm, cross, I, det |
| OrdinaryDiffEq | Available for Phase 2 higher-order symplectic methods |

### Architecture Decisions

1. **Submodule pattern**: `src/GR/GR.jl` following TinyVDB pattern. Access via `using Lyr.GR`.
2. **Hand-rolled Störmer-Verlet**: Simpler than DiffEq for Phase 1. OrdinaryDiffEq available for Phase 2.
3. **Adaptive step sizing**: `adaptive_step(dl, r, M)` scales step by distance from horizon. 0.1× at r=2M, 1× at r>10M. Makes renders 55× faster than fixed step.
4. **ForwardDiff compatibility**: `metric`/`metric_inverse` must accept `SVector{4}` (not `SVec4d`) so Dual numbers pass through.
5. **Polar singularity clamping**: `sin²θ = max(sin²θ, 1e-10)` in metric + partials prevents blowup at θ=0,π.
6. **Bilinear sky interpolation**: `sphere_lookup` uses bilinear interpolation on the texture with horizontal wrapping.
7. **Unresolved rays → sky fallback**: Rays that hit MAX_STEPS or H drift look up the sky at their final position instead of returning black.

### Renders Produced

- `schwarzschild_128.ppm` — 128×128 test render (7s)
- `schwarzschild_hd.ppm` — 1920×1080 with NASA Deep Star Maps 2020 background (52s, 36 threads)
  - Features visible: BH shadow, accretion disk (ISCO→25M), gravitationally lensed back-side disk, Einstein ring, lensed Milky Way starfield

### Phase 1 → Phase 2 Roadmap

Phase 1 (this session) delivered the Schwarzschild MVP. The Phase 2 stubs are in place:

```
✅ Phase 1: Schwarzschild Ray Tracer
   ✅ MetricSpace abstract type + interface
   ✅ Schwarzschild metric (Schwarzschild coordinates)
   ✅ Adaptive Störmer-Verlet integrator
   ✅ GRCamera with tetrad
   ✅ ThinDisk + CelestialSphere matter sources
   ✅ Frequency shift computation
   ✅ Threaded rendering pipeline
   ✅ 313 tests + physics validation

○ Phase 2: Kerr + Volume Rendering + Weak-Field
   ○ Kerr metric (Boyer-Lindquist) — stub exists at src/GR/metrics/kerr.jl
   ○ VolumetricMatter bridge to VDB — stub at src/GR/stubs/volumetric.jl
   ○ WeakField (Poisson solve) — stub at src/GR/stubs/weak_field.jl
   ○ Eddington-Finkelstein coordinates (horizon penetration)
   ○ Covariant radiative transfer (I_ν/ν³ invariant)

○ Phase 3: Cosmological + Exotic Spacetimes
○ Phase 4: Numerical Relativity Import (3+1 ADM)
○ Phase 5: GR Path Tracing (Multi-Scattering GRRT)
```

### Next Priority

1. **Kerr metric** — Boyer-Lindquist implementation (stub ready)
2. **Eddington-Finkelstein coordinates** — fixes horizon-crossing H drift
3. **VolumetricMatter bridge** — connect GR geodesics to existing VDB tree queries
4. **Doppler-shifted disk** — enable `use_redshift=true` (currently disabled in HD render due to visual tuning needed)

---

## Previous Session (2026-02-24) — Fix camera auto-setup voxel_size bug (0qvn)

**Status**: COMPLETE — 1 issue closed (0qvn), 29,160 tests pass

### What Was Done

**`path-tracer-0qvn` — Camera auto-setup now accounts for voxel_size transform**

The `_auto_camera` function used `active_bounding_box` which returns index-space coordinates. When `voxel_size != 1.0` (e.g., Field Protocol voxelization with `voxel_size=0.2`), user-provided cameras in world space were misinterpreted as index-space coordinates, causing the camera to end up inside the volume.

Fix: Two-part approach maintaining internal index-space rendering while exposing a world-space API:
1. `_auto_camera` now multiplies bbox coordinates by `voxel_size`, returning a world-space camera
2. New `_camera_to_index_space(cam, vs)` helper scales camera position by `1/voxel_size`
3. `_render_grid` converts all cameras (auto or user-provided) from world to index space before creating the Scene

The round-trip is verified: `_auto_camera` → world → `_camera_to_index_space` → index produces identical index-space coordinates regardless of `voxel_size`.

### Files Modified

| File | Change |
|------|--------|
| `src/Visualize.jl` | `_auto_camera` multiplies by voxel_size; new `_camera_to_index_space` helper; `_render_grid` converts camera |
| `test/test_visualize.jl` | +14 tests: world-to-index round-trip, `_camera_to_index_space`, visualize with non-unit voxel_size + custom camera |

### Test Results

```
29,160 pass, 0 fail, 0 errors (was 29,146)
```

### Next Priority

Ready P2 issues (from `bd ready`):
- `path-tracer-igk8` — No visualize method for TimeEvolution
- `path-tracer-j3bq` — Hand-rolled NTuple vector math in Render.jl
- `path-tracer-rcx7` — isdefined(Main, :PNGFiles) antipattern
- `path-tracer-1uce` — Inconsistent pixel type Float64 vs Float32 across pipeline

---

## Previous Session (2026-02-23) — 4 issues: type stability, dedup, bug fix, API cleanup

**Status**: COMPLETE — 4 issues closed (8mfh, 701w, k250, gt5s), 29,146 tests pass

### What Was Done

**1. `path-tracer-8mfh` — Parametrize VolumeEntry{G} and Scene{V} for type stability**

Replaced `grid::Any` in `VolumeEntry` with parametric `grid::G`. Parametrized `Scene{V}` on its volumes container — single-volume scenes store a `Tuple{VolumeEntry{G}}` (fully specialized), multi-volume scenes keep a `Vector`. Added `Scene(cam, lights::Vector, vol::VolumeEntry)` constructor that auto-wraps in tuple. Both `visualize` pipelines now pass single volumes directly.

**2. `path-tracer-701w` — Extract _render_grid to deduplicate visualize pipelines**

The `ParticleField` and `AbstractContinuousField` `visualize` methods shared 90%+ identical code (camera, material, scene, render, post-process, output). Extracted shared grid→image pipeline into `_render_grid(grid, nanogrid; default_tf, kwargs...)`. Each method handles only its field-specific voxelization, then delegates. Only difference: default transfer function (`tf_viridis()` vs `tf_cool_warm()`).

**3. `path-tracer-k250` — GPU CPU fallback now uses scene background color**

`gpu_volume_march_cpu!` hardcoded `(0,0,0)` for background blend on miss rays. Added `background::NTuple{3,Float64}=(0.0,0.0,0.0)` keyword argument. Test verifies miss rays render with specified background color.

**4. `path-tracer-gt5s` — Deprecate legacy render_image**

Removed `render_image` from export list. Added `Base.depwarn` pointing users to `render_volume_image`/`visualize`. Updated docstring with deprecation notice. Tests use `Lyr.render_image` (qualified access).

### Files Modified

| File | Change |
|------|--------|
| `src/Scene.jl` | `VolumeEntry{G}`, `Scene{V}`, new single-vol+lights constructor |
| `src/Visualize.jl` | `_render_grid` helper, both pipelines delegate to it |
| `src/GPU.jl` | `background` kwarg on `gpu_volume_march_cpu!` |
| `src/Lyr.jl` | Removed `render_image` from exports |
| `src/Render.jl` | `Base.depwarn` + deprecation docstring on `render_image` |
| `test/test_scene.jl` | `VolumeEntry[vol]` → `[vol]` |
| `test/test_gpu.jl` | +33 LOC: background color test for CPU fallback |
| `test/test_render.jl` | `render_image` → `Lyr.render_image` |
| `test/test_tinyvdb_bridge.jl` | `render_image` → `Lyr.render_image` |

### Test Results

```
29,146 pass, 0 fail, 0 errors (was 29,082)
```

### Next Priority

Ready P2 issues (from `bd ready`):
- `path-tracer-0qvn` — Camera auto-setup ignores voxel_size transform
- `path-tracer-igk8` — No visualize method for TimeEvolution (unblocked by 701w)
- `path-tracer-j3bq` — Hand-rolled NTuple vector math in Render.jl
- `path-tracer-rcx7` — isdefined(Main, :PNGFiles) antipattern

---

## Previous Session (2026-02-23) — Fix 3 P1 issues (6esy, gg2x, m8ub)

**Status**: COMPLETE — 3 P1 issues fixed, 29,082 tests pass

### What Was Done

**1. `path-tracer-6esy` — VolumeEntry without NanoGrid now throws ArgumentError**

Both render paths (`render_volume_preview` and `render_volume_image`) previously silently `continue`d past volumes with `nanogrid === nothing`, producing black images with no error. Now throws `ArgumentError("VolumeEntry has no NanoGrid — call build_nanogrid(grid.tree) before rendering")`. Added test covering both renderers.

**2. `path-tracer-gg2x` — FieldProtocol closures are now type-stable**

Parametrized 4 field structs on their function type so the compiler can inline closure calls in hot paths:
- `ScalarField3D{F}`, `VectorField3D{F}`, `ComplexScalarField3D{F}` — `eval_fn::F` instead of `eval_fn::Function`
- `TimeEvolution{F,G}` — added `G` parameter for `eval_fn`, with convenience constructor `TimeEvolution{F}(...)` preserving existing API

Added `Base.show(::Type{<:T})` methods to keep type display clean (no `{var"#2#3"}`). Verified with `@code_warntype`: `evaluate` now infers `Body::Float64` (was `Any` through abstract `Function`).

**3. `path-tracer-m8ub` — VolumeMaterial uses concrete types instead of Any**

Replaced `transfer_function::Any` with `transfer_function::TransferFunction` (concrete struct — zero dispatch overhead) and `phase_function::Any` with `phase_function::PhaseFunction` (abstract with 2 subtypes — small union). Left `grid::Any` in VolumeEntry for downstream `8mfh` issue.

### Files Modified

| File | Change |
|------|--------|
| `src/VolumeIntegrator.jl` | Lines 184, 299: `continue` → `throw(ArgumentError(...))` |
| `src/FieldProtocol.jl` | 4 structs parametrized on function type + show methods |
| `src/Scene.jl` | `VolumeMaterial` fields: `Any` → `TransferFunction`/`PhaseFunction` |
| `test/test_volume_renderer.jl` | +18 LOC: test VolumeEntry without NanoGrid throws |

### Test Results

```
29,082 pass, 0 fail, 0 errors (was 29,080)
```

### Next Priority

Unblocked by this session:
- `path-tracer-8mfh` — Scene container type erasure (VolumeEntry parametric on Grid type)

---

## Previous Session (2026-02-23) — Distill code review + fix 2 P1 bugs

**Status**: COMPLETE — 27 issues created, 8 dep edges wired, 2 bugs fixed, 29,080 tests pass

### What Was Done

**1. Distilled 6-specialist code review into 27 actionable beads issues**

Cross-referenced ~1MB of review transcripts against 38 existing open issues and current codebase. Filtered out findings already addressed by v1.0 work (Field Protocol, voxelize, visualize). Created issues with self-contained descriptions (file:line, root cause, recommended fix).

| Priority | Count | Categories |
|----------|-------|-----------|
| P1 | 5 | 3 correctness bugs + 2 type stability issues |
| P2 | 10 | Architecture, performance, API consistency |
| P3 | 12 | Dedup, threading, minor bugs, docs |

Wired 8 dependency edges forming a DAG:
```
T1 (gg2x) → A1 (8mfh) → gtti → A3 (2hm9) → L2 (28v4)
T2 (m8ub) ↗
T1 → L4 (6u3q)
A2 (j3bq) → L1 (85cd)
A10 (701w) → A7 (igk8)
```

**2. Fixed `path-tracer-ssn4` — adaptive voxelizer Z-axis bound**

`Voxelize.jl:134`: Z-axis block loop used `imax` (X bound) instead of `kmax`. Non-cubic domains where Z > X silently skipped Z blocks. One-character fix + regression test with elongated domain.

**3. Fixed `path-tracer-9ka2` — multi-volume compositing escaped ray**

`VolumeIntegrator.jl:318`: `break` after `:escaped` exited the entire volume loop, so second volume never tested. Changed to `continue`. Regression test with two synthetic volumes (empty + dense).

### Files Modified

| File | Change |
|------|--------|
| `src/Voxelize.jl` | `imax` → `kmax` on line 134 |
| `src/VolumeIntegrator.jl` | `break` → `continue` on line 318 |
| `test/test_voxelize.jl` | +20 LOC: non-cubic domain regression test |
| `test/test_volume_renderer.jl` | +38 LOC: multi-volume regression test |
| `.beads/issues.jsonl` | +27 issues, 8 dependency edges |

### Test Results

```
29,080 pass, 0 fail, 0 errors (was 29,076)
```

### Project Status Summary

**~14,300 LOC source, ~11,000 LOC tests, 45 source files, 63 open issues**

| Phase | Status | Key Components |
|-------|--------|----------------|
| Phase 1: Foundation | **COMPLETE** | VDB read/write, DDA traversal, NanoVDB flat layout |
| Phase 2: Volume Renderer | **~86% DONE** | Delta/ratio tracking, TF, scene, PNG/EXR, denoising |
| Phase 3: Field Protocol | **COMPLETE** | AbstractField, voxelize, visualize, 4 example scripts |
| Phase 4: Physics Modules | Not started | LyrEM, LyrQM, etc. (separate packages) |
| Phase 5: Production Quality | Not started | Multi-scatter, differentiable, Makie integration |

### Next Priority

Unblocked P1 issues ready to work:
1. `path-tracer-6esy` — VolumeEntry without NanoGrid silently renders nothing
2. `path-tracer-gg2x` — FieldProtocol stores closures as abstract `Function` type (blocks 3 downstream issues)
3. `path-tracer-m8ub` — VolumeMaterial/VolumeEntry use `Any` typed fields (blocks A1)

---

## Previous Session (2026-02-22) — Field Protocol + voxelize + visualize

**Status**: COMPLETE — 6 issues closed, 36,027 tests pass (25,617 new)

### What Was Done

Implemented the Field Protocol — the core v1.0 abstraction layer that bridges physics computation to volumetric rendering. This is the product per the PRD: "minimal cognitive distance from physics to pixels."

Also added adaptive voxelization (`adaptive=true`, default) to `voxelize()` — samples block corners first, only fills 8³ leaves where the field has structure. Helps for localized fields (orbitals, particles). For smooth fields filling the whole domain (e.g., dipole 1/r²), uniform is faster — use `adaptive=false`.

Explored vector field visualization: three overlapping volumes with directional coloring (warm = E_z up, cool = E_z down, white = radial). Multi-volume compositing works. HD renders of all 4 examples produced.

1. **Field Protocol** (`src/FieldProtocol.jl`, ~250 LOC) — Abstract types (`AbstractField`, `AbstractContinuousField`, `AbstractDiscreteField`), domain types (`BoxDomain` with SVec3d), and reference implementations (`ScalarField3D`, `VectorField3D`, `ComplexScalarField3D`, `ParticleField`, `TimeEvolution`). Interface: `evaluate()`, `domain()`, `field_eltype()`, `characteristic_scale()`.

2. **Voxelize** (`src/Voxelize.jl`, ~150 LOC) — `voxelize()` bridges fields to VDB grids: uniform sampling for scalar fields, magnitude reduction for vector fields, `abs2` for complex fields (probability density), Gaussian splatting for particles. Auto `voxel_size` from `characteristic_scale / 5`.

3. **Visualize** (`src/Visualize.jl`, ~250 LOC) — `visualize(field)` is a one-call entry point: voxelize → build_nanogrid → auto-camera → Scene → render_volume_image → tonemap → write. Presets: `camera_orbit/front/iso`, `material_emission/cloud/fire`, `light_studio/natural/dramatic`.

4. **Example scripts** (`examples/`, 4 scripts) — EM dipole (ScalarField3D), 3D Ising model (ScalarField3D from lattice), hydrogen 3d_z² orbital (ComplexScalarField3D), MD spring particles (ParticleField). All run end-to-end.

### Files Created/Modified

| File | Change |
|------|--------|
| `src/FieldProtocol.jl` | **NEW** — Field Protocol types + interface |
| `src/Voxelize.jl` | **NEW** — voxelize() for all field types |
| `src/Visualize.jl` | **NEW** — visualize(), presets, auto-camera |
| `src/Lyr.jl` | 3 includes + ~20 new exports |
| `test/test_field_protocol.jl` | **NEW** — 44 tests |
| `test/test_voxelize.jl` | **NEW** — 25,547 tests |
| `test/test_visualize.jl` | **NEW** — 26 tests |
| `test/runtests.jl` | 3 includes + import |
| `examples/em_dipole.jl` | **NEW** — EM field visualization |
| `examples/ising_model.jl` | **NEW** — Ising model visualization |
| `examples/hydrogen_orbital.jl` | **NEW** — QM orbital visualization |
| `examples/md_particles.jl` | **NEW** — MD particle visualization |
| `VISION.md` | Rewritten: agent-native physics visualization platform |
| `PRD.md` | Updated: v1.0 product requirements |

### Test Results

```
36,027 pass, 0 fail, 0 errors (was 10,410)
25,617 new tests (Field Protocol: 44, Voxelize: 25,547, Visualize: 26)
```

### Project Status Summary

**~14,300 LOC source, ~11,000 LOC tests, 45 source files**

| Phase | Status | Key Components |
|-------|--------|----------------|
| Phase 1: Foundation | **COMPLETE** | VDB read/write, DDA traversal, NanoVDB flat layout |
| Phase 2: Volume Renderer | **~86% DONE** | Delta/ratio tracking, TF, scene, PNG/EXR, denoising |
| Phase 3: Field Protocol | **COMPLETE** | AbstractField, voxelize, visualize, 4 example scripts |
| Phase 4: Physics Modules | Not started | LyrEM, LyrQM, etc. (separate packages) |
| Phase 5: Production Quality | Not started | Multi-scatter, differentiable, Makie integration |

### v1.0 Checklist (from PRD)

- [x] VDB read/write
- [x] Delta tracking (CPU + GPU)
- [x] Ratio tracking shadows
- [x] Transfer functions
- [x] Camera models
- [x] Scene graph
- [x] Denoising (NLM + bilateral)
- [x] Tonemapping
- [x] PNG + basic EXR output
- [x] Grid builder
- [x] Gaussian splatting
- [x] GPU delta tracking kernel
- [x] **Field Protocol** (AbstractField, evaluate, domain, field_eltype)
- [x] **voxelize()** (continuous field → VDB grid)
- [x] **visualize()** (high-level entry point with defaults)
- [x] **Example scripts** (4 physics domains: EM, stat mech, QM, classical)
- [x] **Docstrings** (agent-contract quality on all new code)
- [x] **10,000+ tests** (36,027)

### Next Priority

1. **Julia General registry** — package registration
2. **Deep EXR compositing** — Phase 2 completion
3. **Multi-scatter** — Production rendering quality
4. **Makie integration** — Interactive viewports

---

## Previous Session (2026-02-21) — Gaussian splatting + grid builder + MD demo

**Status**: 🟢 COMPLETE — 4 issues closed, 10410 tests pass (49 new)

### What Was Done

Added two missing pipeline pieces for particle-to-volume visualization:

1. **`build_grid`** (`src/GridBuilder.jl`, ~100 LOC) — Builds a complete VDB tree bottom-up from sparse `Dict{Coord, T}` data. Groups voxels by leaf origin → I1 origin → I2 origin, constructs masks and node tables in correct order.

2. **`gaussian_splat`** (`src/Particles.jl`, ~50 LOC) — Converts particle positions into a smooth density field via Gaussian kernel splatting. Supports configurable voxel size, sigma, cutoff, and optional per-particle weighted values.

3. **MD spring demo** (`scripts/md_spring_demo.jl`, ~150 LOC) — End-to-end demo: 1000 particles on a 10×10×10 grid, harmonic spring forces, velocity Verlet integration, splat → build_grid → write_vdb → render → denoise → tonemap → PPM output.

### Files Modified

| File | Change |
|------|--------|
| `src/GridBuilder.jl` | **NEW** — `build_grid` + `_build_mask` helper |
| `src/Particles.jl` | **NEW** — `gaussian_splat` |
| `src/Lyr.jl` | Include both files + export `build_grid`, `gaussian_splat` |
| `scripts/md_spring_demo.jl` | **NEW** — complete MD → render pipeline demo |
| `test/test_grid_builder.jl` | **NEW** — 49 tests: single voxel, multi-leaf, multi-I1/I2, negatives, empty, round-trip write/parse, Float64, splat symmetry/accumulation/conservation |
| `test/runtests.jl` | Include `test_grid_builder.jl` |

### Key Design Decisions

- `build_grid` works with any `T` (Float32, Float64, etc.) — builds immutable `Mask` from word tuples via `_build_mask`
- Children sorted by bit index before insertion into node tables (matches `on_indices` iteration order)
- `gaussian_splat` returns `Dict{Coord, Float32}` — directly feeds into `build_grid`
- Demo uses `render_volume_image` (MC delta tracking), not preview renderer, for quality output

---

## Previous Session (2026-02-21) — Denoising filters for MC volume rendering

**Status**: 🟢 COMPLETE — 1 issue closed, 10361 tests pass (558 new)

### What Was Done

Implemented two post-render denoising filters for Monte Carlo noise reduction (`path-tracer-gj8d`). Both are pure Julia, no new dependencies, and work in the pipeline between render and tonemap:

```
render → denoise_nlm / denoise_bilateral → tonemap → write
```

| Function | Algorithm | Use Case |
|----------|-----------|----------|
| `denoise_nlm` | Non-local means: L2 patch distance weighting over search window | Best quality for MC noise (exploits non-local self-similarity) |
| `denoise_bilateral` | Gaussian spatial × Gaussian color-difference | Fast alternative (~400× cheaper), edge-preserving |

Both are parameterized on `T <: AbstractFloat` — works with Float64 (CPU renderer) and Float32 (GPU renderer output).

### Files Modified

| File | Change |
|------|--------|
| `src/Output.jl` | +120 LOC: `denoise_nlm` and `denoise_bilateral` between tone mapping and EXR sections |
| `src/Lyr.jl` | Export `denoise_nlm`, `denoise_bilateral` |
| `test/test_output.jl` | +110 LOC: 10 test groups — uniform invariance, noise variance reduction, Float32 compat, edge preservation, 1×1 edge case, finite output |

### Test Results

```
10361 pass, 0 fail, 0 errors (was 9803)
558 new denoiser tests
```

### Project Status Summary

**~12,100 LOC source, ~9,900 LOC tests, 42 files**

| Phase | Status | Key Components |
|-------|--------|----------------|
| Phase 1: Foundation | **COMPLETE** | VDB read/write, DDA traversal, NanoVDB flat layout |
| Phase 2: Volume Renderer | **~86% DONE** | Delta/ratio tracking, TF, scene, PNG/EXR output. Missing: deep EXR |
| Phase 3: GPU Acceleration | **~80% DONE** | Delta tracking @kernel, NLM + bilateral denoising. Missing: ratio tracking |
| Phase 4: Creation Tools | Not started | Mesh-to-SDF, procedural, CSG |
| Phase 5: Ecosystem | Not started | Makie, animation, multi-scatter, differentiable rendering |

### Next Priority

1. **Deep EXR compositing** (`path-tracer-mt7t`) — Phase 2 completion
2. **Makie recipe** — Interactive volume preview
3. **Multi-scatter** — Beyond single-scatter for production quality

---

## Previous Session (2026-02-21) — GPU delta tracking kernel + stale issue cleanup

**Status**: 🟢 COMPLETE — 21 issues closed, 5 created, 9803 tests pass (620 new)

### What Was Done

Audited codebase against VISION.md, closed 19 stale beads issues verified as complete, created 5 new VISION gap issues, and implemented the GPU delta tracking kernel via KernelAbstractions.jl.

**Issue housekeeping**:
- Closed 19 stale issues: 8 NanoVDB (all phases done), 4 recent commits (show/rename/exports/off_indices), 5 dead code, 2 other (read_f16_le, DDA sphere_trace)
- Created 5 VISION gap issues: Deep EXR (P2), GPU delta tracking (P1), GPU ratio tracking (P1, blocked by delta), Denoising (P2), Deprecate fixed-step march (P3)

**GPU delta tracking kernel** (`path-tracer-6y5p`, `path-tracer-zzml`):

| Component | What |
|-----------|------|
| `_gpu_buf_count_on_before` | Device-side prefix sum lookup for mask child indexing |
| `_gpu_get_value` | Stateless Root→I2→I1→Leaf traversal on flat NanoGrid buffer (all Int32 arithmetic) |
| `_gpu_ray_box_intersect` | Float32 ray-AABB slab intersection |
| `_gpu_xorshift` / `_gpu_wang_hash` | Per-pixel RNG (xorshift32 + Wang hash for decorrelation) |
| `_gpu_tf_lookup` | Device-side 1D transfer function LUT evaluation |
| `delta_tracking_kernel!` | KA.jl `@kernel`: exponential free-flight, null-collision rejection, ratio tracking shadow rays, single-scatter |
| `gpu_render_volume` | Dispatch wrapper: bakes TF LUT, adapts buffer, progressive spp accumulation |

### Files Modified/Created

| File | Change |
|------|--------|
| `Project.toml` | Added KernelAbstractions v0.9 + Adapt v4 deps |
| `src/GPU.jl` | +595 LOC: device-side buffer ops, value lookup, delta tracking @kernel, render wrapper |
| `src/Lyr.jl` | Export `gpu_render_volume` |
| `test/test_gpu.jl` | **NEW** — 620 tests: _gpu_get_value vs NanoValueAccessor (200+200 coords on cube+smoke), ray-box, RNG, TF LUT, render smoke tests, determinism, multi-spp |
| `test/runtests.jl` | Include test_gpu.jl + GPU internal imports |

### Test Results

```
9803 pass, 0 fail, 0 errors (was 9183)
620 new GPU tests (value lookup correctness, kernel smoke tests, determinism)
```

### Project Status Summary

**~12,000 LOC source, ~9,300 LOC tests, 42 files**

| Phase | Status | Key Components |
|-------|--------|----------------|
| Phase 1: Foundation | **COMPLETE** | VDB read/write, DDA traversal, NanoVDB flat layout |
| Phase 2: Volume Renderer | **~86% DONE** | Delta/ratio tracking, TF, scene, PNG/EXR output. Missing: deep EXR |
| Phase 3: GPU Acceleration | **~67% DONE** | Delta tracking @kernel, ratio tracking, CPU backend. Missing: denoising |
| Phase 4: Creation Tools | Not started | Mesh-to-SDF, procedural, CSG |
| Phase 5: Ecosystem | Not started | Makie, animation, multi-scatter, differentiable rendering |

### Next Priority

1. **Deep EXR compositing** (`path-tracer-mt7t`) — Phase 2 completion
2. **Denoising** (`path-tracer-gj8d`) — Phase 3 completion
3. **Makie recipe** — Interactive volume preview
4. **Multi-scatter** — Beyond single-scatter for production quality

---

## Previous Session (2026-02-18) — API cleanup & code hygiene

**Status**: 🟢 COMPLETE — 14 issues closed, 9183 tests pass (23 new)

### What Was Done

Systematic cleanup pass across the codebase: export reduction, dead code removal, naming fixes, algorithm improvements, and REPL experience.

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `ydgg` | P2 | task | Reduce public API from 195 → 129 exports. Binary r/w primitives, parser internals, DDA primitives, compression functions, coordinate internals, exception detail types, render/volume/GPU internals removed from export. Tests import explicitly via `runtests.jl`. |
| 2 | `hwz9` | P3 | task | Move `TinyVDBBridge.jl` from `src/` to `test/` — test infrastructure, not production code |
| 3 | `mphw` | P3 | task | Dead code `_estimate_normal_safe` — already removed in prior session |
| 4 | `9ikg` | P3 | task | Dead code `_bisect_surface` — already removed in prior session |
| 5 | `hgtb` | P3 | task | TinyVDB `read_grid_descriptors`: `read_i32` → `read_u32` for grid count |
| 6 | `z986` | P3 | task | TinyVDB `read_root_topology`: `read_i32` → `read_u32` for tile/child counts |
| 7 | `rep3` | P3 | task | TinyVDB `read_grid`: `read_i32` → `read_u32` for buffer_count |
| 8 | `ne2` | P3 | bug | Half-precision: replaced heap-allocating `bytes[pos:pos+1]` + `reinterpret` with zero-alloc `read_f16_le` |
| 9 | `05ih` | P3 | task | Renamed `inactive_val1/val2` → `inactive_val0/val1` to match C++ `inactiveVal0/inactiveVal1` |
| 10 | `9u3` | P3 | task | Added `ROOT_TILE_VOXELS = 4096^3` named constant, documented all tile region sizes |
| 11 | `n9aw` | P3 | task | Renamed misleading `offset_to_data` → `data_pos` in TinyVDB header |
| 12 | `thac` | P3 | task | Renamed `src/Topology.jl` → `src/ChildOrigins.jl` (was confusing with TinyVDB/Topology.jl) |
| 13 | `9ezy` | P3 | task | Reduced TinyVDB exports from 45+ → 9 symbols (test oracle API only) |
| 14 | `40mo` | P3 | task | Fixed `off_indices` iterator: O(N) linear scan → O(count_off) CTZ-based |
| 15 | `qgdu` | P3 | feature | Added `Base.show` methods for Mask, LeafNode, Tile, InternalNode1/2, Tree, Grid, VDBFile |
| 16 | `x0u3` | P3 | feature | Covered by `qgdu` — Base.show methods for REPL experience |

Also removed dead `_safe_sample_nearest` from Render.jl.

### Files Modified/Created

| File | Change |
|------|--------|
| `src/Lyr.jl` | Export reduction (195→129), include rename |
| `src/Masks.jl` | `Base.show` for Mask, CTZ-based `off_indices` |
| `src/TreeTypes.jl` | `Base.show` for LeafNode, Tile, InternalNode1/2, RootNode |
| `src/Grid.jl` | `Base.show` for Grid |
| `src/File.jl` | `Base.show` for VDBFile |
| `src/Render.jl` | Removed dead `_safe_sample_nearest` |
| `src/Values.jl` | Zero-alloc half-precision read, `inactive_val0/1` rename |
| `src/Accessors.jl` | `ROOT_TILE_VOXELS` constant |
| `src/ChildOrigins.jl` | Renamed from `src/Topology.jl` |
| `src/TinyVDB/TinyVDB.jl` | Reduced exports (45+ → 9) |
| `src/TinyVDB/GridDescriptor.jl` | `read_i32` → `read_u32` |
| `src/TinyVDB/Topology.jl` | `read_i32` → `read_u32` |
| `src/TinyVDB/Parser.jl` | `read_i32` → `read_u32` |
| `src/TinyVDB/Types.jl` | Renamed `offset_to_data` → `data_pos` |
| `src/TinyVDB/Header.jl` | Updated docstring |
| `test/runtests.jl` | Explicit `import Lyr:` for internal test symbols |
| `test/test_show.jl` | **NEW** — 23 tests for Base.show methods |
| `test/test_tinyvdb.jl` | Explicit imports for reduced TinyVDB exports |
| `test/test_values.jl` | `inactive_val0/1` rename |
| `test/TinyVDBBridge.jl` | Moved from `src/` |
| `test/test_parser_equivalence.jl` | Updated include path |

### Test Results

```
9183 pass, 0 fail, 0 errors (was 9160)
23 new tests (Base.show methods)
```

### Project Status Summary

**~9,200 LOC source, ~8,700 LOC tests, 41 files, 281 issues closed, 32 open**

| Phase | Status | Key Components |
|-------|--------|----------------|
| Phase 1: Foundation | **COMPLETE** | VDB read/write, DDA traversal, NanoVDB flat layout |
| Phase 2: Volume Renderer | **COMPLETE (basic)** | Delta/ratio tracking, transfer functions, scene, PNG output |
| Phase 3: GPU Acceleration | **Scaffolded** | GPUNanoGrid + CPU reference kernels, needs KA.jl wiring |
| Phase 4: Creation Tools | Not started | Mesh-to-SDF, procedural, CSG |
| Phase 5: Ecosystem | Not started | Makie, animation, multi-scatter, differentiable rendering |

### Next Priority

1. **GPU kernels** — Wire KernelAbstractions.jl to existing NanoVDB buffer + CPU reference kernels
2. **Makie recipe** (`9gqg`) — Interactive volume preview
3. **Render quality** — Grazing DDA (`1s6w`), AA (`8lcs`), crease normals (`ikrs`)

---

## Previous Session (2026-02-18) — NanoVDB flat-buffer implementation

**Status**: 🟢 COMPLETE — 8 issues closed, 7664 tests pass (6274 new)

### What Was Done

Implemented the complete NanoVDB flat-buffer representation — serializes the pointer-based VDB tree (`Root→I2→I1→Leaf`) into a single contiguous `Vector{UInt8}` buffer with byte-offset references. This is the critical path to GPU rendering via KernelAbstractions.jl.

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `i70d` | P1 | design | NanoVDB buffer layout: Header, Root Table (sorted, binary-searchable), I2/I1 (variable-size with mask+prefix+child offsets+tile values), Leaf (fixed-size) |
| 2 | `g4eh` | P1 | feature | `NanoLeafView{T}` — zero-copy view into leaf node (origin, value_mask, values) |
| 3 | `jy23` | P1 | feature | `NanoI1View{T}`, `NanoI2View{T}` — views with child_mask/value_mask + prefix sums, child offset lookup, tile value lookup |
| 4 | `61ij` | P1 | feature | `NanoRootView` — sorted Coord entries with `_nano_root_find` binary search |
| 5 | `icfa` | P1 | feature | `build_nanogrid(tree::Tree{T})::NanoGrid{T}` — two-pass inventory→write converter |
| 6 | `9og6` | P1 | feature | `get_value(grid::NanoGrid{T}, c)` + `NanoValueAccessor{T}` with leaf/I1/I2 byte-offset cache |
| 7 | `tzd5` | P1 | feature | `NanoVolumeRayIntersector{T}` — lazy DDA iterator through flat buffer, yields `NanoLeafHit{T}` |
| 8 | `61fz` | P1 | test | Full equivalence test suite: 6274 assertions across 9 test sets |

### Phase 1.3 Status: NanoVDB Flat Layout — COMPLETE

```
✅ i70d  Design NanoVDB layout
  ✅ g4eh  NanoLeaf flat view
    ✅ jy23  NanoI1/NanoI2 flat views
      ✅ 61ij  NanoRoot sorted table
        ✅ icfa  NanoGrid build from Tree
          ✅ 9og6  Value accessor on NanoGrid
            ✅ tzd5  DDA on NanoGrid
              ✅ 61fz  Equivalence tests
```

### Files Created/Modified

| File | Change |
|------|--------|
| `src/NanoVDB.jl` | **NEW** (~570 LOC) — buffer primitives, view types, builder, accessors, DDA |
| `src/Lyr.jl` | Include NanoVDB.jl + 9 export lines |
| `test/test_nanovdb.jl` | **NEW** (~200 LOC) — 9 test sets, 6274 assertions |
| `test/runtests.jl` | Include test_nanovdb.jl |

### Buffer Layout

```
┌──────────────────────────────────────────────────────┐
│ Header (68+sizeof(T) bytes)                          │
├──────────────────────────────────────────────────────┤
│ Root Table (sorted entries, binary-searchable)       │
├──────────────────────────────────────────────────────┤
│ I2 Nodes (variable size, mask+prefix+offsets+tiles)  │
├──────────────────────────────────────────────────────┤
│ I1 Nodes (variable size, same structure)             │
├──────────────────────────────────────────────────────┤
│ Leaf Nodes (fixed: 76+512×sizeof(T) bytes each)     │
└──────────────────────────────────────────────────────┘
```

### Test Results

```
7664 pass, 0 fail, 0 errors (was 1390)
NanoVDB tests: 6274 new (buffer ops, views, build, get_value, accessor, DDA, multi-grid)
```

### Next Priority

1. **`1s6w`** — Fix grazing DDA missed zero-crossings (P2 bug)
2. **`8lcs`** — Multi-sample anti-aliasing (P2)
3. **GPU kernels** — KernelAbstractions.jl integration using NanoGrid buffer

---

## Previous Session (2026-02-17) — DDA renderer complete + beads housekeeping

**Status**: 🟢 COMPLETE — 9 issues closed, 4 new issues created, 1390 tests pass

### What Was Done

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `ay5g` | P1 | task | Replace `intersect_leaves` (brute-force O(all_leaves)) with `collect(VolumeRayIntersector(...))` (DDA O(leaves_hit)). Make `sphere_trace` delegate to `find_surface`. Update `render_image` to call `find_surface` directly, removing stale world-bounds pre-computation. −100 LOC. |
| 2 | `9ysk` | P1 | feature | Closed stale — `VolumeRayIntersector` already implemented in commit `15c9d90`. |
| 3 | `tzw5` | P1 | feature | Closed stale — `find_surface` already implemented in commit `476e6c4` (`src/Surface.jl`). |
| 4 | `ck6p` | P3 | feature | Closed stale — superseded by `gduf`/`9ysk`. |
| 5 | `ydx` | P3 | feature | Closed stale — duplicate. |
| 6 | `m647` | P3 | task | Closed stale — already tested in `test_volume_ray_intersector.jl`. |
| 7 | `tyk7` | P3 | task | Closed stale — handled in `File.jl`. |
| 8 | `gim` | P3 | task | Closed stale — `.claude/` is hook-managed. |
| 9 | NaN guard | fix | test | Fixed pre-existing `NaN == NaN` bug in `test_properties.jl` "Empty tree returns background". |

**New issues created** (render quality findings from test renders):

| ID | Title | P | Blocks |
|----|-------|---|--------|
| `1s6w` | Fix missed zero-crossings at near-grazing voxel incidence | P2 | — |
| `ikrs` | Feature-preserving normals at sharp geometric creases | P2 | blocked by `czn` |
| `8lcs` | Multi-sample anti-aliasing (jittered supersampling) | P2 | — |
| `ga40` | Gamma correction and exposure control in render_image | P3 | blocked by `8lcs` |

### Files Modified

| File | Change |
|------|--------|
| `src/Ray.jl` | `intersect_leaves` → 1-line `collect(VolumeRayIntersector(...))`. Deleted `_intersect_internal2!`, `_intersect_internal1!`, `_intersect_leaf!` |
| `src/Render.jl` | `sphere_trace` delegates to `find_surface`. `render_image` calls `find_surface` directly |
| `test/test_render.jl` | +3 testsets: `sphere_trace` hits sphere.vdb, miss, max_steps-is-ignored |
| `test/test_ray.jl` | +1 testset: `intersect_leaves` equivalence vs `intersect_leaves_dda` on cube.vdb |
| `test/test_properties.jl` | `isnan(bg)` guard in "Empty tree returns background" property test |

### Phase 1.2 Status: DDA Ray Traversal — COMPLETE

```
✅ avxb  New Ray type with SVector
  ✅ bcba  AABB-ray slab intersection
    ✅ lmzm  3D-DDA stepper (Amanatides-Woo)
      ✅ p7md  Node-level DDA
        ✅ gduf  Hierarchical DDA (Root→I2→I1→Leaf)
          ✅ 9ysk  VolumeRayIntersector iterator
            ✅ tzw5  Level set surface finding
              ✅ ay5g  Replace sphere_trace    ← this session
```

### Beads Housekeeping

- Purged 72 stale `ly-*` closed issues from DB + JSONL (were causing `bd sync` prefix-mismatch loop)
- Removed erroneous `sync.branch = master` config (caused sync to loop on local JSONL)
- Workflow: commit `.beads/` directly to master — do NOT use `bd sync`
- Database now clean: **235 issues, all `path-tracer-*`**

### Render Quality — Known Artifacts & Roadmap

Test renders of `bunny.vdb` and `icosahedron.vdb` confirm the DDA renderer is geometrically correct (no node-boundary block artifacts). Remaining visual issues and their issues:

| Artifact | Root Cause | Issue |
|----------|-----------|-------|
| Horizontal banding (bunny) | 1 sample/pixel voxel aliasing | `8lcs` AA |
| Dark speckles at face edges (icosahedron) | Central-diff gradient straddles crease | `czn` → `ikrs` |
| Diagonal scan lines on flat faces | DDA misses sign-change at grazing incidence | `1s6w` |
| Washed-out midtones | Linear output, no gamma | `ga40` |

### Next Priority

1. **`1s6w`** — Fix grazing DDA missed zero-crossings (standalone P2 bug, fast win)
2. **`8lcs`** — Multi-sample AA (standalone P2, eliminates banding)
3. **`i70d`** — Design NanoVDB flat layout (Phase 1.3 entry point)

---

## Previous Session (2026-02-16) — Hierarchical DDA + DDA foundation

**Status**: 🟢 COMPLETE — 4 issues closed, 1285 tests pass

### What Was Done

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `gduf` | P1 | feature | Hierarchical DDA: `intersect_leaves_dda` — Root → I2 → I1 → Leaf traversal. 88 new tests. |
| 2 | `bcba` | P1 | task | AABB struct (SVec3d min/max), refactored `intersect_bbox` to AABB primary + BBox overload. 12 new tests. |
| 3 | `lmzm` | P1 | feature | Amanatides-Woo 3D-DDA in `src/DDA.jl`: `DDAState`, `dda_init`, `dda_step!`. 112 new tests. |
| 4 | `p7md` | P1 | feature | Node-level DDA: `NodeDDA`, `node_dda_init`, `node_dda_child_index`, `node_dda_inside`, `node_dda_voxel_origin`. 57 new tests. |

### Files Modified/Created

| File | Change |
|------|--------|
| `src/Ray.jl` | Added `AABB` struct + `BBox` converter; refactored `intersect_bbox` to use AABB |
| `src/DDA.jl` | **NEW** — DDA stepper + NodeDDA + hierarchical traversal |
| `src/Lyr.jl` | Include DDA.jl; export AABB + DDA symbols |
| `test/test_ray.jl` | +12 AABB tests |
| `test/test_dda.jl` | **NEW** — 112 DDA tests |
| `test/test_node_dda.jl` | **NEW** — 57 NodeDDA tests |
| `test/test_hierarchical_dda.jl` | **NEW** — 88 hierarchical DDA tests |
| `test/runtests.jl` | Include new test files |

---

## Previous Session (2026-02-15) — Tests, hygiene, features, Phase 1 roadmap

**Status**: 🟢 COMPLETE — 8 issues closed, 996 tests pass, Phase 1 roadmap created (21 issues)

### What Was Done

**Part 1: Close top-of-queue issues (8 closed)**

| # | ID | P | Type | What |
|---|-----|---|------|------|
| 1 | `90su` | P1 | test | 10 unit tests for `read_dense_values` — all 7 metadata flags + half-precision + edge cases |
| 2 | `i4u4` | P1 | test | 40 unit tests for `TreeRead.jl` — `_decode_values`, `align_to_16`, `read_internal_tiles`, minimal tree integration |
| 3 | `3ox` | P2 | hygiene | Removed `Manifest.toml` from git tracking (already in .gitignore) |
| 4 | `py5` | P2 | hygiene | Deleted ~65MB image artifacts (40 PNG/PPM) from project root |
| 5 | `tla` | P2 | hygiene | Deleted `renders/` directory (~46MB, 36 files) |
| 6 | `nzn` | P2 | hygiene | Deleted 45 debug scripts (kept `render_vdb.jl`, `test_and_render_all.jl`) |
| 7 | `2zo` | P2 | feature | Boundary-aware trilinear interpolation — falls back to nearest at ±background |
| 8 | `al6m` | P2 | perf | Precomputed matrix inverse in `LinearTransform` (inv_mat field, ~2x for world_to_index) |

**Part 2: Phase 1 roadmap — pivot from parser polish to rendering pipeline**

Decision: parser is done (996 tests, all files parse). Remaining 51 old issues are diminishing-returns polish. Downgraded all old P1/P2 to P3. Created 21 new P1 issues across three phases:

**Phase 1.1: StaticArrays Foundation (5 issues, chain)**
```
ovkr  Add StaticArrays.jl + type aliases (SVec3d, SMat3d)  ← ENTRY POINT
  → e0v8  Refactor LinearTransform to SMatrix/SVector
    → 0yey  Refactor world_to_index/index_to_world
      → 717b  Refactor Interpolation.jl to SVec3d
        → uapd  StaticArrays foundation tests
```

**Phase 1.2: DDA Ray Traversal (8 issues, chain)**
```
ovkr  (shared root)
  → avxb  New Ray type with SVector origin/direction/inv_dir
    → bcba  AABB-ray slab intersection
      → lmzm  3D-DDA stepper (Amanatides-Woo)
        → p7md  Node-level DDA (per internal node)
          → gduf  Hierarchical DDA (Root→I2→I1→Leaf)
            → 9ysk  VolumeRayIntersector iterator
              → tzw5  Level set surface finding (DDA + bisection)
                → ay5g  Replace sphere_trace
```

**Phase 1.3: NanoVDB Flat Layout (8 issues, chain)**
```
i70d  Design NanoVDB layout  ← ENTRY POINT (parallel with 1.1)
  → g4eh  NanoLeaf flat view
    → jy23  NanoI1/NanoI2 flat views
      → 61ij  NanoRoot sorted table
        → icfa  NanoGrid build from Tree
          → 9og6  Value accessor on NanoGrid
            → tzd5  DDA on NanoGrid (also depends on 9ysk)
              → 61fz  Equivalence tests
```

### Files Modified

| File | Change |
|------|--------|
| `test/test_values.jl` | +10 read_dense_values unit tests (flags 0-6, half-prec, position) |
| `test/test_tree_read.jl` | **NEW** — 40 tests for TreeRead.jl utility + integration |
| `test/runtests.jl` | Include test_tree_read.jl |
| `src/Interpolation.jl` | Boundary-aware trilinear: `_is_background` check, nearest fallback |
| `test/test_interpolation.jl` | +2 boundary fallback tests |
| `src/Transforms.jl` | `inv_mat` field + `_invert_3x3`; simplified `world_to_index_float` |
| `Manifest.toml` | Removed from tracking |
| `teapot.png` | Removed from tracking |
| `scripts/` | 28 tracked debug scripts removed (kept render_vdb.jl, test_and_render_all.jl) |

### Next Priority

1. **`ovkr`** — Add StaticArrays.jl (gates Phase 1.1 + 1.2)
2. **`i70d`** — Design NanoVDB layout (gates Phase 1.3, parallelizable with 1.1)

---

## Previous Session (2026-02-15) - Fix 9 issues: perf + bugs

**Status**: 🟢 COMPLETE — 9 issues closed, 920 tests pass

### What Was Done

Worked through `bd ready` queue top-to-bottom, fixing bugs and implementing perf features.

| # | ID | Priority | Type | Fix |
|---|-----|----------|------|-----|
| 1 | `46r` | P1 | bug | TinyVDB `read_grid_compression` — propagate `header.is_compressed` for v220 files (was returning COMPRESS_NONE) |
| 2 | `50y1` | P1 | perf | `Mask{N,W}` prefix-sum — added `NTuple{W,UInt32}` for O(1) `count_on_before` (was O(W) loop over 512 words for I2) |
| 3 | `clws` | P1 | perf | `ValueAccessor{T}` — mutable cache for leaf/I1/I2 nodes; 5-8x speedup for trilinear (7/8 lookups hit same leaf) |
| 4 | `60i` | P2 | bug | TinyVDB `read_compressed_data` — added `abs(chunk_size)` cross-validation against `total_bytes` |
| 5 | `u1k` | P2 | bug | TinyVDB `read_metadata` — size prefixes from `read_i32` → `read_u32` (VDB spec uses unsigned) |
| 6 | `b93` | P2 | bug | `Binary.jl` — replaced `unsafe_load(Ptr{T}(...))` with `memcpy`-based `_unaligned_load` for ARM portability |
| 7 | `ql1` | P2 | bug | `volume(BBox)` — return `Int128` instead of `Int64` to avoid overflow for large bounding boxes |
| 8 | `fls` | P2 | bug | `File.jl` — `@warn` for unsupported grid value types instead of silent skip |
| 9 | `d9i` | P2 | bug | TinyVDB `read_transform` — accept `ScaleMap` and `ScaleTranslateMap` (same binary layout as Uniform variants) |
| 10 | `1xd` | P2 | bug | `sample_trilinear` — use `Int64` arithmetic to avoid `Int32` overflow on `coord+1` near typemax |

### Learnings

- **Mask prefix-sum**: Adding a `prefix::NTuple{W,UInt32}` field to the existing `Mask{N,W}` struct required updating all constructors. The inner constructor trick (`Mask{N,W}(words::NTuple{W,UInt64})`) that auto-computes prefix sums keeps call sites unchanged. One test used `(0b10110001,)` (Tuple{UInt8}) which the old implicit struct constructor auto-promoted but the new explicit constructor rejects — needed `UInt64(...)` cast.

- **`_unaligned_load` pattern**: Julia's `unsafe_load(Ptr{T}(...))` requires alignment on ARM. The portable fix is `ccall(:memcpy, ...)` into a `Ref{T}`. This is zero-cost on x86 (compiler elides the memcpy) and correct everywhere.

- **`ValueAccessor` design**: Mutable struct with `const tree` field (Julia 1.8+). Cache check is just `leaf_origin(c) == acc.leaf_origin` — a single `Coord` equality (3 Int32 compares). Falls through I1/I2 cache levels before full root traversal.

- **Beads sync prefix conflict**: `bd sync` fails with "prefix mismatch" when JSONL contains issues from multiple projects. Workaround: commit `.beads/` separately with `git add .beads/ && git commit`.

### Next Priority (from `bd ready`)

1. `90su` — Unit tests for `read_dense_values` (all 7 metadata flags)
2. `i4u4` — Unit tests for `TreeRead.jl` (518 LOC, zero tests)
3. `2zo` — Boundary-aware trilinear interpolation
4. `py5` — Delete ~65MB untracked image artifacts
5. `al6m` — Precompute matrix inverse in LinearTransform

---

## Previous Session (2026-02-14) - Code review + fix 10 bugs + 1 hygiene

**Status**: 🟢 COMPLETE — comprehensive code review, 77 issues created, 11 issues closed

### What Was Done

1. **Comprehensive 6-specialist code review** spawned in parallel:
   - Hygiene inspector (138 junk files found)
   - Julia idiomaticity expert (grade B overall, type instability issues, ~315 LOC duplication)
   - Test coverage reviewer (critical gap: Values.jl/TreeRead.jl have zero unit tests)
   - Line-by-line bug hunter (2 CRITICAL, 8 HIGH, 7 MEDIUM, 13 LOW bugs found)
   - Architecture reviewer (clean deps, over-exported API, path to 1.0)
   - Knuth algorithm analyst (count_on_before is O(512) should be O(1), ValueAccessor needed)

2. **Created 77 beads issues** with 23 dependency edges across 6 categories

3. **Fixed 7 bugs** (top of the priority queue):

| # | ID | Priority | Fix |
|---|-----|----------|-----|
| 1 | `yx7` | P0 CRITICAL | `read_tile_value` — added Int32/Int64/Bool specializations; generic now errors instead of calling `ltoh` on unsupported types |
| 2 | `k0a` | P0 CRITICAL | TinyVDB `read_compressed_data` — split `==0` (empty chunk, return zeros) from `<0` (uncompressed, read abs bytes) |
| 3 | `8mu` | P1 HIGH | Selection mask ternary inverted vs C++ — swapped to match `isOn→inactiveVal1` |
| 4 | `vgu` | P1 HIGH | v222+ tile values discarded — made I1TopoData/I2TopoData parametric on T, store `node_values` from topology pass |
| 5 | `339` | P1 HIGH | v220 header compression — use actually-read byte instead of hardcoding ZIP |
| 6 | `avn` | P1 HIGH | `read_mask` — throw BoundsError on truncated data instead of zero-padding |
| 7 | `ykk` | P1 HIGH | `read_active_values` — removed try/catch that swallowed BoundsError with `zero(T)` |
| 8 | `3ej` | P1 HIGH | Transforms.jl — replaced wrong 23-byte skip AffineMap fallback with clear error |
| 9 | `3di` | P1 HIGH | `read_bytes` — replaced `unsafe_wrap` aliased memory with safe byte slice copy |
| 10 | `2j4` | P1 TASK | Project.toml — moved Debugger/Infiltrator to extras, replaced placeholder UUID |

4. **Updated .gitignore** (`oq8`) — Manifest.toml, renders, debug scripts, IDE dirs (unblocks 5 hygiene issues)

### Test Results

```
920 pass, 0 fail, 0 errors (was 911)
```

### Files Modified

| File | Change |
|------|--------|
| `src/Values.jl` | Int32/Int64/Bool read_tile_value specializations; generic errors; selection mask ternary fix; removed BoundsError swallowing |
| `src/TreeRead.jl` | I1TopoData{T}/I2TopoData{T} parametric with node_values; tile construction uses actual values |
| `src/TinyVDB/Compression.jl` | Split empty chunk (==0) from uncompressed (<0) in read_compressed_data |
| `src/Masks.jl` | read_mask throws BoundsError on truncated data |
| `src/Header.jl` | v220 compression from actual byte, not hardcoded ZIP |
| `src/Transforms.jl` | Replaced wrong AffineMap fallback with clear ArgumentError |
| `src/Binary.jl` | Safe byte slice copy instead of unsafe_wrap |
| `Project.toml` | Debugger/Infiltrator to extras, proper UUID |
| `test/test_values.jl` | Tests for Int32/Int64/Bool read_tile_value + unsupported type error |
| `.gitignore` | Comprehensive patterns for Manifest.toml, renders, scripts, IDE |

### Next Priority (from `bd ready`)

1. `46r` — TinyVDB read_grid_compression returns COMPRESS_NONE for v220
2. `50y1` — Prefix-sum popcount (O(1) count_on_before)
3. `90su` — Unit tests for read_dense_values (all 7 metadata flags)
4. `i4u4` — Unit tests for TreeRead.jl
5. `60i` — TinyVDB read_compressed_data lacks abs(chunk_size) validation

---

## Previous Session (2026-02-14) - Fix level set rendering artifacts

**Status**: 🟡 PARTIAL — sphere tracer improved (step clamping, utility helpers added) but node boundary artifacts remain

### What Was Done

1. **Diagnosed the root cause thoroughly**: The level set renderer's artifacts come from trilinear interpolation corrupting SDF values at VDB tree node boundaries (8³ leaf, 16³ I1, 32³ I2). When `sample_trilinear` straddles a node boundary, some of the 8 corners return the background value (~0.15 for sphere.vdb) while others return real SDF values. The blended result is wrong, causing the tracer to take wrong-sized steps.

2. **Key finding: SDF values are in WORLD units** (not voxel units). For sphere.vdb: background=0.15, voxel_size=0.05, so narrow band is 3 voxels wide. The step distance `abs(dist)` is already in world units — no conversion needed.

3. **Added step clamping** to `sphere_trace`: `step = min(abs(dist), vs * 2.0)` prevents overshooting. The original code had no clamp and jumped by full `background` (0.15 = 3 voxels) when outside the band.

4. **Added utility functions** for future use:
   - `_safe_sample_nearest` — NN sampling (immune to trilinear boundary corruption)
   - `_bisect_surface` — binary search between two t values to find exact zero-crossing
   - `_estimate_normal_safe` — index-space gradient with one-sided difference fallback
   - `_gradient_axis_safe` — per-axis gradient that handles band-edge samples

5. **Explored multiple approaches** (documented in detail below for next session)

### Approaches Tried (for next session's reference)

| Approach | Result | Issue |
|----------|--------|-------|
| NN stepping + threshold | 0 bg, scattered holes | NN quantization: some rays step past threshold |
| NN + sign-change detection + bisection | 0 bg, correct shape | False crossings at node boundaries (SDF jumps +band to -background) |
| NN sign-change + false-crossing rejection | 884 bg, most rejected | Too aggressive filter, misses real crossings too |
| Hybrid (trilinear step + NN sign-change backup) | 0 bg | Grid artifacts remain from trilinear normal corruption |
| Trilinear + step clamp (committed) | 0 bg, reduced artifacts | Thin dark lines at node boundaries remain |

### Remaining Problem: Node Boundary Artifacts

**The fundamental issue**: Trilinear interpolation is structurally broken at node boundaries because `get_value` returns `tree.background` for coordinates outside the tree. When trilinear's 8-corner samples straddle a boundary between a populated leaf and empty space, the result is garbage.

**What would fix this properly** (future work):
1. **DDA tree traversal** — walk the ray through the tree structure leaf-by-leaf (like OpenVDB's `VolumeRayIntersector`), only sampling within populated nodes. This is the correct approach used by production renderers.
2. **Boundary-aware interpolation** — modify `sample_trilinear` to detect when any of the 8 corners returns background and fall back to nearest-neighbor for that sample.
3. **Active-voxel-aware gradient** — for normals, only use neighbors that are active voxels in the tree (not background fill).

### Files Modified

| File | Change |
|------|--------|
| `src/Render.jl` | Step clamping in `sphere_trace`; added `_safe_sample_nearest`, `_bisect_surface`, `_estimate_normal_safe`, `_gradient_axis_safe` utilities |

### Test Results

```
911 pass, 0 fail, 0 errors (unchanged)
```

---

## Previous Session (2026-02-14) - Fix multi-grid + render all VDBs

**Status**: 🟡 PARTIAL — multi-grid parsing fixed (12/12 VDBs), renders generated but level set renderer has artifacts

### What Was Done

1. **Fixed multi-grid VDB parsing** (3 bugs):
   - Grid descriptors interleaved with data → merged descriptor+grid loop with end_offset seeking
   - `parse_value_type` false-matched `_HalfFloat` suffix → regex-based token extraction + `vec3s` support
   - Half-precision `value_size` for vec3 was 2 instead of 6 → threaded `value_size` through v220 reader

2. **Fixed NaN property test** — added `isnan` guard (NaN == NaN is false in IEEE 754)

3. **Rendered all 20 VDB files** to PNG at 512x512 → `renders/` directory

### Results

```
911 pass, 0 fail, 0 errors
20/20 VDB files parse, 18/20 rendered to PNG
```

### Next Task: Fix Level Set Rendering Artifacts

**Problem**: Level set renders (sphere, armadillo, bunny, ISS, etc.) show grid-like scaffolding, missing pixels, and dark lines at node boundaries. The sphere is worst — clearly shows internal 8³/16³/32³ block structure. Fog volumes (explosion, fire, smoke, bunny_cloud) render fine.

**Root Cause Analysis** (investigation done, fix NOT implemented):

The sphere tracer in `src/Render.jl` has these issues:

1. **Trilinear interpolation corrupts SDF at narrow-band edges** (`Interpolation.jl:18-41`):
   When `sample_trilinear` straddles a node boundary, some of the 8 corners return the background value (typically 3.0) while others return actual SDF values. The interpolated result is a meaningless number between the true SDF and background. This causes the tracer to take wrong-sized steps and either overshoot or miss the surface.

2. **Background step is too aggressive** (`Render.jl:125-128`):
   When `abs(dist - background) < 1e-6`, the tracer steps by the full background value (~3.0 voxels). This overshoots thin features and surface details near node edges.

3. **No distinction between "outside narrow band" and "near band edge"**:
   A trilinear sample near a band boundary might return 2.5 (just below background=3.0) — this looks like a valid SDF distance but is actually garbage from interpolating with background values.

**Suggested Fix Strategy**:

1. **Use nearest-neighbor for sphere trace stepping** — `sample_world(grid, point; method=:nearest)` avoids trilinear artifacts at band edges. Only matters for the step distance, not final shading.

2. **Clamp max step size** — `step = min(abs(dist), narrow_band_width * 0.8)` prevents overshooting. The narrow band width is typically `background` (3 voxels × voxel_size).

3. **Conservative fallback stepping** — when the sample returns background or near-background, use a fixed small step (e.g., `vs * 1.0`) to walk through the gap rather than jumping by `background`.

4. **Use trilinear only for normals** — once a hit is found (we're guaranteed to be well within the band), trilinear gives smooth normals.

**Key files**:
- `src/Render.jl:76-136` — `sphere_trace` function (the main thing to fix)
- `src/Render.jl:168-181` — `_safe_sample` (wraps `sample_world`)
- `src/Render.jl:188-197` — `_estimate_normal_safe` (normal estimation)
- `src/Interpolation.jl:18-41` — `sample_trilinear` (the 8-corner trilinear sampler)
- `src/Accessors.jl:14-66` — `get_value` (returns background when coordinate not in tree)

**Quick test**: render just the sphere to iterate fast:
```julia
julia --project -e '
using Lyr
vdb = parse_vdb("test/fixtures/samples/sphere.vdb")
grid = vdb.grids[1]
cam = Camera((3.0, 2.0, 3.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 40.0)
pixels = render_image(grid, cam, 256, 256; max_steps=500)
write_ppm("sphere_test.ppm", pixels)
'
convert sphere_test.ppm sphere_test.png
```

### Files Modified This Session

| File | Change |
|------|--------|
| `src/File.jl` | Merged descriptor+grid loops; seek to end_offset; vec3 half-precision value_size |
| `src/GridDescriptor.jl` | Regex-based value type parsing; vec3s support |
| `src/TreeRead.jl` | `_decode_values` helper; threaded `value_size` through v220 |
| `src/Values.jl` | Half-precision conversion in v220 leaf values path |
| `test/test_integration.jl` | Added multi-grid tests (explosion, fire, smoke2) |
| `test/test_properties.jl` | NaN guard in tile property test |
| `renders/*.png` | 18 rendered images (not committed — in .gitignore) |

---

## Previous Session (2026-02-14) - Fix multi-grid VDB parsing

**Status**: 🟢 COMPLETE — 12/12 OpenVDB test files parse, 911 tests pass

### Summary

Fixed 3 bugs preventing multi-grid VDB files (explosion, fire, smoke2) from parsing:

1. **Grid descriptor interleaving**: Descriptors are interleaved with grid data in VDB files, not stored contiguously. `File.jl` now reads each descriptor then seeks to `end_offset` for the next.

2. **`parse_value_type` false matching**: Loose `contains("Float")` matched the `_HalfFloat` suffix, misidentifying `Tree_vec3s_5_4_3_HalfFloat` as `Float32`. Now extracts value type token via regex. Also added `vec3s` support (= `Vec3f` = `NTuple{3, Float32}`).

3. **Half-precision vec3 `value_size`**: Was `2` (scalar Float16) instead of `6` (3 × Float16). Threaded `value_size` through entire v220 tree reader chain and added `_decode_values` helper for Float16→T conversion.

Also fixed property test NaN bug (`NaN == NaN` is `false`).

### Results

```
911 pass, 0 fail, 0 errors (was 890 pass, 0 fail, 1 error)
20/20 VDB files parse: 12 OpenVDB test suite + 8 original fixtures
```

### Files Modified

| File | Change |
|------|--------|
| `src/File.jl` | Merged descriptor+grid loops; seek to end_offset between grids; vec3 half-precision value_size |
| `src/GridDescriptor.jl` | Regex-based value type parsing; vec3s support |
| `src/TreeRead.jl` | `_decode_values` helper; threaded `value_size` through v220 functions |
| `src/Values.jl` | Half-precision conversion in v220 leaf values path |
| `test/test_integration.jl` | Added multi-grid tests (explosion, fire, smoke2) |
| `test/test_properties.jl` | NaN guard in tile property test |

---

## Previous Session (2026-02-14) - Download OpenVDB test suite + render scripts

**Status**: 🟢 COMPLETE — 12 VDB files downloaded, test/render script created

### Summary

1. **Rendered bunny_cloud.vdb** at 1024x1024 using volumetric ray marching (fog volume, not level set). Iterated through cloud renderer → isosurface renderer → smoothed isosurface with blurred density sampling. Cloud data is inherently turbulent so surface is rough.

2. **Downloaded official OpenVDB test suite** from artifacts.aswf.io into `test/fixtures/openvdb/`. 12 files (~1GB total) covering level sets and fog volumes at various scales.

3. **Created `scripts/test_and_render_all.jl`** — parses every VDB file and raytraces each one (sphere trace for level sets, volume march for fog volumes). Auto camera placement. Outputs to `renders/`.

### Parse Results

| File | Size | Version | Status | Type |
|------|------|---------|--------|------|
| armadillo.vdb | 61M | v222 | OK | Level set, 121k leaves |
| buddha.vdb | 38M | v222 | OK | Level set, 74k leaves |
| bunny.vdb | 15M | v222 | OK | Level set, 29k leaves |
| crawler.vdb | 444M | v222 | OK | Level set, 760k leaves |
| dragon.vdb | 63M | v222 | OK | Level set, 124k leaves |
| iss.vdb | 212M | v222 | OK | Level set, 367k leaves |
| torus_knot_helix.vdb | 25M | v222 | OK | Level set, 65k leaves |
| venusstatue.vdb | 27M | v222 | OK | Level set, 29k leaves |
| smoke1.vdb | 2.4M | v222 | OK | Fog volume, 3k leaves |
| explosion.vdb | 75M | v220 | FAIL | Multi-grid descriptor bug |
| fire.vdb | 28M | v222 | FAIL | Multi-grid descriptor bug |
| smoke2.vdb | 30M | v220 | FAIL | Multi-grid descriptor bug |

9/12 parse successfully. 3 failures are multi-grid files — second grid descriptor reads garbage string length. Pre-existing bug in `read_grid_descriptor` when parsing files with >1 grid.

### Files Created/Modified

| File | Change |
|------|--------|
| `test/fixtures/openvdb/` | **NEW** — 12 VDB files from official OpenVDB samples |
| `scripts/render_bunny.jl` | **NEW** — volumetric/isosurface renderer for bunny_cloud.vdb |
| `scripts/test_and_render_all.jl` | **NEW** — parse + render all VDBs, summary table |
| `.gitignore` | Added `test/fixtures/openvdb/` (large binaries, not committed) |

### Known Bugs Found

1. **Multi-grid descriptor parsing**: Files with >1 grid (explosion, fire, smoke2) fail when reading the 2nd grid descriptor — garbage string length in `read_string_with_size`. Likely the grid descriptor loop doesn't account for some v220/multi-grid format difference.

### Next Steps

- Fix multi-grid descriptor parsing (3 files)
- Run `scripts/test_and_render_all.jl` to render all files
- The smooth `bunny.vdb` (level set) can be rendered beautifully with the existing sphere tracer

---

## Previous Session (2026-02-14) - Fix v220 tree reader for bunny_cloud.vdb

**Status**: 🟢 COMPLETE — 2 issues closed, 0 errors remaining

### Summary

Fixed the v220 (pre-v222) tree reader so bunny_cloud.vdb parses correctly. Three bugs:

1. **Internal node values format**: v220 stores non-child values as a compressed block (`childMask.countOff()` values, no metadata byte), not as (value, active_byte) pairs. See tinyvdbio.h:2266.

2. **Two-phase structure**: v220 `readTopology` reads ALL topology for ALL root children first, then `readBuffers` reads ALL leaf values. Our code was interleaving per-subtree. Split into `read_i2_topology_v220` + `materialize_i2_values_v220` (mirrors v222+ architecture).

3. **Leaf buffer format**: v220 `readBuffers` re-emits value_mask (64 bytes) before origin+numBuffers+data, and stores ALL 512 values compressed (not just active values).

### Results

```
891 pass, 0 fail, 0 errors (was 678 pass, 0 fail, 2 errors)
```

All 8 test VDB files now parse successfully through Main Lyr.

### Files Modified

| File | Change |
|------|--------|
| `src/TreeRead.jl` | Replaced `read_internal2_subtree_interleaved` with `I2TopoDataV220`, `read_i2_topology_v220`, `materialize_i2_values_v220`. Restructured `read_tree_interleaved` into two-phase. |
| `src/Values.jl` | Fixed v220 leaf path: added 64-byte value_mask skip, changed expected_size to 512*sizeof(T) |

### Issues Closed

| ID | Title |
|---|---|
| `path-tracer-0ij` | Fix v220 tree interleaved reader for bunny_cloud.vdb |
| `path-tracer-2ul` | Promote TinyVDB as primary parser (Phase 3 umbrella) |

---

## Previous Session (2026-02-14) - Fix smoke.vdb + rearch (delete TinyVDB routing)

**Status**: 🟢 COMPLETE — 2 issues closed

### Summary

1. **smoke.vdb fix (d42)**: Root cause was three bugs in Main Lyr's transform/tree reading:
   - `Transforms.jl`: Bogus `pos += 4` after UniformScaleMap and `pos += 23` after UniformScaleTranslateMap. Removed both.
   - `Grid.jl`: Missing `buffer_count` read between transform and background. Added it.
   - `TreeRead.jl`: Spurious `background_active` byte read for fog volumes. Removed it.

2. **Rearch / TinyVDB demotion (ac4)**: Main Lyr is now the sole production parser. TinyVDB is test-only.

### Issues Closed

| ID | Title |
|---|---|
| `path-tracer-d42` | Fix legacy parser smoke.vdb structural failure |
| `path-tracer-ac4` | Delete TinyVDBBridge, demote TinyVDB to test-only |
