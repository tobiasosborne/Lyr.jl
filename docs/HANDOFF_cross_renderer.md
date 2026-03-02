# Cross-Renderer Ground Truth: Lyr.jl vs Mitsuba 3

**Status**: IN PROGRESS — infrastructure built, Mitsuba references generated, cross-renderer tests NOT YET VALIDATED (too slow at current SPP/resolution)

**Date**: 2026-03-02

---

## What Was Done This Session

### 1. Benchmark Framework (Tiers 5-11) — COMPLETE
- **79,528 tests pass, 0 failures** (up from 76,391)
- 3,137 new tests: image comparison, VDB consistency, Disney Cloud, MC convergence, golden regression, determinism
- Disney Cloud downloaded (2.97GB zip → 1.6MB sixteenth VDB, 415,642 voxels)
- 8 showcase PNGs in `showcase/benchmarks/`
- 6 golden reference PPMs in `test/fixtures/reference_renders/`
- Committed and pushed: `5345ca3`

### 2. Mitsuba 3 Cross-Renderer — PARTIALLY COMPLETE

**What exists:**
- Mitsuba 3.8.0 installed in `.mitsuba-env/` virtualenv
- `scripts/mitsuba_reference.py` — generates 7 reference renders (scenes A-D)
- Reference .bin files generated in `test/fixtures/mitsuba_reference/` (4096 spp, 256×256)
- `src/ImageCompare.jl` — extended with `read_float32_image()` for Mitsuba binary format
- `src/Scene.jl` — added `ConstantEnvironmentLight` for white furnace test
- `src/VolumeIntegrator.jl` — added `_escape_radiance()` to handle environment lights
- `test/test_cross_renderer.jl` — written but NOT YET VALIDATED

**What is NOT done:**
- Cross-renderer tests have not been run to completion — Lyr rendering at 256×256 even at 512 spp is too slow (minutes per scene)
- No RMSE values yet — we don't know if Lyr matches Mitsuba
- Scene E (VDB volume comparison) not implemented
- `test_cross_renderer.jl` not added to `runtests.jl` yet
- Nothing committed for the cross-renderer work

### 3. Performance Problem — CRITICAL BLOCKER

**Root cause**: Lyr renders a homogeneous fog sphere by storing it as a VDB tree and doing trilinear NanoVDB lookups at every delta tracking step. Mitsuba uses `type: homogeneous` — zero spatial lookups, constant sigma_t.

For 256×256 × 512 spp = 33M rays, each doing multiple delta tracking steps with 8-point trilinear interpolation through a VDB tree, the total time is many minutes. Mitsuba does the same in 5 seconds.

**Fix options (not yet implemented):**
1. **HomogeneousMedium fast path** — skip VDB entirely for constant-density media. Sample free-flight analytically: `t = -log(rand) / sigma_t`. No tree traversal, no interpolation. This would match Mitsuba's speed.
2. **Lower resolution for tests** — 64×64 at 128 spp would run in seconds. Sufficient for RMSE validation.
3. **Both** — use 64×64 for fast CI tests, have a separate high-res validation script.

---

## Key Files

| File | Status | Purpose |
|------|--------|---------|
| `src/ImageCompare.jl` | Modified | Added `read_float32_image()` |
| `src/Scene.jl` | Modified | Added `ConstantEnvironmentLight` |
| `src/VolumeIntegrator.jl` | Modified | Added `_escape_radiance()` for env lights |
| `src/Lyr.jl` | Modified | Exports for new types |
| `scripts/mitsuba_reference.py` | New | Renders Mitsuba 3 references |
| `test/test_cross_renderer.jl` | New, UNVALIDATED | Lyr vs Mitsuba comparison |
| `test/fixtures/mitsuba_reference/*.bin` | New | Mitsuba reference renders |
| `.mitsuba-env/` | New | Python venv with Mitsuba 3.8.0 |

## Parameter Mapping (Lyr ↔ Mitsuba)

| Lyr | Mitsuba 3 |
|-----|-----------|
| `sigma_scale = S` | `sigma_t = S` (with density=1.0 fog) |
| `scattering_albedo = a` | `albedo = a` |
| `IsotropicPhase()` | `phase: isotropic` |
| `HenyeyGreensteinPhase(g)` | `phase: hg, g=g` |
| `DirectionalLight((0,0,1), I)` | `direction: [0,0,-1]` (NEGATED — toward vs travel) |
| `emission_scale = 1.0` | *(none)* |
| `TF = constant (1,1,1,1)` | *(none — disables Lyr's color modulation)* |

## Canonical Scenes

| Scene | sigma_t | albedo | phase | light | method | Mitsuba max_depth |
|-------|---------|--------|-------|-------|--------|-------------------|
| A: Single scatter | 1.0 | 0.8 | isotropic | directional | SingleScatter | 2 |
| B: Multi scatter | 1.0 | 1.0 | isotropic | directional | PathTracer(64) | -1 |
| C: White furnace | 1.0 | 1.0 | isotropic | constant env | PathTracer(64) | -1 |
| D: HG sweep | 1.0 | 0.8 | HG g={0,0.3,0.7,0.9} | directional | SingleScatter | 2 |

## Next Steps (Priority Order)

1. **Drop test resolution to 64×64, SPP to 64** — get a fast feedback loop (seconds, not minutes)
2. **Run cross-renderer tests** — find out the actual RMSE values
3. **Debug mismatches** — camera convention, light direction, phase normalization
4. **Once matching**: bump resolution back up for final validation
5. **Add `HomogeneousMedium`** fast path for performance parity with Mitsuba
6. **Commit and push** the cross-renderer work
7. **Add to `runtests.jl`** once stable

## Potential Mismatch Sources

1. **Camera Y-axis flip** — Lyr flips V: `v = 1.0 - (y-1+jitter)/height`. Mitsuba may or may not.
2. **Light direction** — Lyr = toward light `(0,0,1)`, Mitsuba = light travel `(0,0,-1)`. Already accounted for in test code but not verified.
3. **Phase function 1/(4π)** — isotropic should be `1/(4π)` per steradian. Both renderers should agree but worth checking.
4. **Pixel filter** — Mitsuba set to `box` filter (no bleed). Lyr uses jittered subpixel — should converge to same result at high SPP.
5. **Clamp to [0,1]** — Lyr clamps pixel output. Mitsuba does not. For these dim scenes (<0.1 avg brightness) this shouldn't matter.
6. **Shadow ray offset** — Lyr uses `hit_pos + 0.01 * light_dir`. Too large = visible bias. Too small = self-shadowing.

## Lessons Learned

1. **4096 spp at 256×256 is NOT "fast"** for a VDB-backed renderer — 268M rays × VDB lookups = minutes. Always profile before promising speed.
2. **Homogeneous media need a fast path** — storing constant density in a VDB tree and doing trilinear interpolation at every step is pure waste.
3. **Mitsuba 3 installs trivially** via `uv pip install mitsuba` into a venv. The Python API is clean and fast.
4. **Transfer functions are visualization, not physics** — for cross-renderer comparison, use constant white TF `(1,1,1,1)` with `emission_scale=1.0` to reduce to standard radiative transfer.
5. **Disney Cloud zip is 2.97GB**, not 1.6MB. The sixteenth-resolution VDB inside it is 1.6MB. Plan for the download time.
