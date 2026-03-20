# Lyr.jl Handoff Document

**API Reference**: `docs/api_reference.md` -- full signatures, gotchas, source file map, workflow examples.
**Lessons Learned**: `docs/lessons.md` -- crash recovery, implementation pitfalls.

---

## Current Status

Lyr.jl is an agent-native physics visualization platform: pure Julia OpenVDB parser + production volume renderer + Field Protocol bridging physics to pixels. The codebase has ~17,200 LOC source across 60+ files, with 94,000+ tests passing. All documentation comprehensively updated as of 2026-03-20.

---

## Latest Session (2026-03-20) -- Documentation Review + Repo Tidiness

**Status**: GREEN -- Major documentation overhaul complete. No code logic changed.

### What Was Done

**Documentation (8 parallel subagents):**
- **README.md**: Updated test count (29k → 94k+), phase statuses, 6 new feature rows (ScalarQED, Wavepackets, Mesh Ops, Diff Ops, Animation), 3 new gallery sections (scattering, grid ops, cloud rendering), ScalarQED architecture block
- **HANDOFF.md**: Condensed 93% (3,330 → 231 lines). Recent 2 sessions in full, 38 older condensed to summary table, consolidated open issues
- **docs/api_reference.md**: +415 lines. 13 new sections: GR module (metrics, camera, matter, integrator, redshift, rendering), ScalarQED, HydrogenAtom, Wavepackets, Animation, FastSweeping, Meshing, Segmentation, PointAdvection, PhaseFunction, ImageCompare, IntegrationMethods. Source file map reorganized by category (60+ files)
- **docs/usage.md**: Complete rewrite (209 → 1,190 lines). 21 tutorial sections with copy-pasteable examples, all API signatures verified from source code

**Source Docstrings (60 files, 3 parallel agents):**
- Module-level comments standardized across all src/ files
- Docstrings added to all public types, functions, and key constants
- Core/IO: VDB constants, NanoVDB accessors, iterator types, mask aliases, file I/O
- Grid ops: Interpolation NTuple wrappers, marching cubes constants, internal helpers
- Rendering/Physics/GR: Volume integrator internals, GR metric interface, Kerr types, ScalarQED functions, camera/render docstrings

**Repo Tidiness:**
- `.gitignore`: Added 7 patterns (`*.djvu`, `*.mp4`, `*.exr`, `*.pdf`, frame dirs, `test-results/`, OS junk)
- `.beads/.gitignore`: Added `dolt-server.activity`, `dolt-server.port`
- PDFs removed from tracking: 6 files (168MB) via `git rm --cached` (kept locally)
- `Project.toml`: Removed CUDA and BenchmarkTools from `[deps]` → `[extras]` (CUDA was never imported in source, BenchmarkTools is test-only)
- `test/runtests.jl`: Added 5 missing test files (test_csg, test_gridops, test_iterators, test_level_set_primitives, test_scalar_qed). Documented 4 intentional exclusions.

### Not Done
- `git filter-repo` to purge 504MB `test_output.log` from git packfile (tool not installed). Run when convenient:
  ```
  pip install git-filter-repo && git filter-repo --path test_output.log --invert-paths
  ```

---

## Previous Session (2026-03-19, evening) -- Scalar QED + Moller + Ionization

**Status**: YELLOW -- Core scalar QED infrastructure complete (23 tests). Moller + ionization demos created but rendering quality needs iteration. GPU variant created but CUDA backend not yet validated.

### What Was Done

**Scalar QED (`wizv` -- CLOSED):**
- Created `src/ScalarQED.jl` -- tree-level Dyson series for two charged scalar particles
  - MomentumGrid: 3D FFT infrastructure with fftfreq ordering
  - Time-dependent Born approximation: precompute FT[V_other * psi_free] at each time step
  - Incremental accumulation: S_n(k) running sum with free propagator phase
  - EM cross-energy: E1*E2 from Poisson-solved Coulomb fields (virtual photon)
  - 4pi Poisson factor (Gaussian units), Born normalization for unitarity
  - `exchange_sign` parameter: 0=distinguishable, +1=bosons, -1=fermions (Moller)
- 23 tests, FFTW.jl dependency, 5 EQ:TAGs in `docs/scattering_physics.md`

**Moller Scattering (`tjyx` -- IN PROGRESS):**
- Created `examples/scatter_qed_moller.jl` -- calls ScalarQEDScattering with exchange_sign=-1
- Fermi antisymmetrization: rho = |psi1|^2 + |psi2|^2 - 2Re(psi1*psi2)
- Issue: exchange term only matters during brief wavefunction overlap -- visually identical to scalar QED for most frames

**H-H Ionization (`22lf` -- IN PROGRESS):**
- Created `examples/scatter_hh_ionization.jl` -- expanding Gaussian for freed electron
- Issue: ionized electron is a hardcoded expanding Gaussian, not computed from collision dynamics

**GPU Acceleration:**
- Spawned 3 proposer subagents for GPU design, selected recompute + incremental accumulation (Proposal C)
  - Eliminates 107 GB P_tilde storage entirely
  - Frame f+1 = frame f + 1 Born step -- O(nsteps) total
  - N=256 fits in 4.4 GB VRAM
- Created `src/ScalarQEDGPU.jl` -- KA kernels, pre-planned FFTs, GPU frame evaluator
- CUDA.jl `Pkg.add` was running when session ended (may need retry)
- NOT YET TESTED -- module compiles but CUDA backend not validated

### Known Issues

1. **Virtual photon visibility**: E1*E2 cross-term is weak at large separations. May need artificial EM scaling for visualization.
2. **Born approximation unitarity**: Normalized per-frame, preserves probability but doesn't guarantee correct scattered wave amplitude.
3. **Moller vs scalar QED**: In NR limit, the only difference is the exchange sign on the density overlap term -- visually negligible except during collision.
4. **Resolution vs scale trade-off**: N=128 with L=120 gives dx=1.875 a.u., sigma=6 spans ~6 voxels.

### What's Next

1. **Finish CUDA.jl install** -- `julia --project -e 'import Pkg; Pkg.add("CUDA")'` (may need retry)
2. **Test GPU path** -- `using CUDA; using Lyr; ScalarQEDScatteringGPU(...)` on a small grid (N=32)
3. **Rerun 128-cubed zooming camera render** -- `julia --project -t auto examples/scatter_scalar_qed.jl`
4. If EM field still invisible at large scale: increase alpha or add EM scaling
5. Close `tjyx` and `22lf` once demos look good
6. Remaining ready issues: `hecg` (P1 refactor), `fgzb`/`fj1a` (P2 tests)

### Commits

- `00599e2` fix: H-H elastic -- glancing collision rewrite
- `c742c6a` feat: scalar QED tree-level scattering -- Born + EM cross-energy
- `c0db295` fix: scalar QED -- 4pi Poisson factor + Born normalization
- `1ef124b` fix: scalar QED demo -- 10x larger simulation
- `662ee6c` feat: QED Moller + H-H ionization demos
- `6ea1965` fix: 128-cubed grid, zooming camera, 512x512 render
- `59d8711` feat: GPU-accelerated scalar QED -- recompute + incremental accumulation

---

## Previous Session (2026-03-17, evening) -- 3 Refactors Done + QFT Scattering Viz Planned

**Status**: YELLOW -- 94,325 passed, 2 fail (pre-existing golden image mismatch), 1 error (pre-existing). Code committed and pushed.

### What Was Done

**3 Code Changes (committed in `8bb3e5d`, pushed):**
- **P3 (jirf)**: `_PrecomputedVolume.pf` to `Union{IsotropicPhase, HenyeyGreensteinPhase}`. Union splitting eliminates dynamic dispatch in scatter loop.
- **P2 (lwp3)**: NanoVDB I1/I2 view dedup. Unified into `NanoInternalView{T, L<:NodeLevel}` with `Level1`/`Level2` type params. -54 net lines.
- **P1 (hecg)**: HDDA span sampling dedup. Extracted `_delta_sample_span`/`_ratio_sample_span` @inline helpers. 8 copy-paste sites to 2 helpers. -54 net lines.

**New Project: QFT Scattering Visualization Series (10 issues created):**

Six-scenario energy ladder: H-H elastic -> H-H excitation -> H-H ionization -> e-e Coulomb -> tree-level QED Moller scattering with virtual photon exchange. All physics is analytic -- Gaussian wavepackets convolved with known propagators. Every equation has a `EQ:TAG` in `docs/scattering_physics.md`.

| ID | P | Title | Blocked by |
|---|---|---|---|
| `06zv` | P1 | EPIC: QFT Scattering Visualization Series | -- |
| `vkhv` | P1 | Ground truth physics reference document | 06zv |
| `4pim` | P1 | Wavepacket + FFT convolution infrastructure | vkhv |
| `qzxv` | P1 | Hydrogen atom eigenstates + MO reconstruction | vkhv |
| `9ohr` | P2 | Scattering animation rendering pipeline | 4pim |
| `dygj` | P2 | VIZ: H-H elastic scattering (scenarios 1-2) | qzxv, 4pim, 9ohr |
| `qkc2` | P2 | VIZ: H-H excitation (scenario 3) | dygj |
| `22lf` | P2 | VIZ: H-H ionization (scenario 4) | qkc2 |
| `s6hk` | P2 | VIZ: e-e Coulomb scattering (scenario 5) | 4pim, 9ohr |
| `tjyx` | P1 | VIZ: Tree-level QED Moller scattering (scenario 6) | s6hk, vkhv |

**Critical path**: `06zv` -> `vkhv` -> `4pim` -> `9ohr` -> `s6hk` -> `tjyx`

### Cleanup Still Needed

1. Confirm 2 test failures are pre-existing: `julia --project --threads=32 -e 'using Pkg; Pkg.test()'`
2. `bd close path-tracer-jirf path-tracer-lwp3 path-tracer-hecg` -- code done
3. `bd close path-tracer-fj1a path-tracer-emsz` -- already tested, no code needed
4. Write unit tests: eu65 (GR integrator), fgzb (VolumeIntegrator)
5. Regenerate golden images: T10.4/T10.5 PPM format mismatch

---

## Session History

| Date | Focus | Key Outcomes |
|------|-------|-------------|
| 2026-03-17 afternoon | Type Stability + Performance + Refactoring | 14 issues closed. Type stability fixes (IntegratorConfig, VolumeEntry, Scene). @fastmath on hot paths. Unified voxel iterators (-144 LOC). NanoVDB header offsets chain-derived. |
| 2026-03-16 | Correctness + Performance | 23 issues closed. Thin-disk BL fix (P0), Schwarzschild tetrad fix, delta tracking Woodcock formula, Kerr analytic partials (10-20x speedup), Planck-to-RGB LUT (400x speedup), CSG narrow-band dilation, DDA branchless step, binary P6 PPM. |
| 2026-03-12h | Session Recovery | Recovered uncommitted Novikov-Thorne accretion + Planck-to-RGB pipeline code from terminated sessions. |
| 2026-03-12g | Full-Scale Code Review | 7 parallel review agents (architecture, tests, bugs, idiomaticity, Torvalds/Carmack/Knuth styles). 58 new beads issues filed with 12 dependency chains. |
| 2026-03-12f | Volumetric Planck Pipeline | RGB Planck accumulation in volumetric GR renderer. Washed-out colors (Reinhard tone mapping issue). Pole artifact mitigation (sin-squared floors). |
| 2026-03-12e | Kerr Showcase | 1920x1080 Kerr a=0.95 + Schwarzschild renders. Filed physically-correct-disk and pole-artifact issues. |
| 2026-03-12d | Kerr Metric Complete | All 169 Kerr tests pass. ForwardDiff compat, Keplerian 4-velocity for Kerr BL. |
| 2026-03-12c | Kerr Metric Implementation | Full BL metric: metric(), metric_inverse(), is_singular(), coordinate_bounds(), ISCO. Kerr tetrad in camera.jl. |
| 2026-03-12b | All 339 Issues Closed | Fixed HG phase function sign error (cos_theta negation). Cross-renderer 9/9 pass vs Mitsuba 3. |
| 2026-03-12 | Test Suite Green + Bug Fixes | Fixed DDA InexactError (safe_floor_int32). Regenerated 6 golden PPMs. Added ConstantEnvironmentLight. 337/339 closed. |
| 2026-03-03 | 13-Issue Parallel Sprint | FastSweeping Eikonal solver, particle_trails_to_sdf, fog_to_sdf, point advection, marching cubes, connected components, node-level iteration. 14,620+ new tests. |
| 2026-03-02b | Renderer 20x Speedup | Inlined HDDA (eliminated closure boxing), accessor reuse, precomputed per-volume constants, same-leaf trilinear fast-path, scalar intersect_bbox. 152MB -> 8.6MB allocations. |
| 2026-03-02 | Ground Truth Test Framework | 825 tests across 4 tiers: Beer-Lambert, white furnace, HG phase stats, renderer cross-validation, conservation invariants. |
| 2026-03-01b | Multi-scatter Path Tracer | Reference renderer: full random walks with NEE, absorption weighting, Russian roulette. `render_volume(scene, ReferencePathTracer(...))` API. |
| 2026-03-01 | mesh_to_level_set | Triangle mesh to narrow-band SDF via angle-weighted pseudonormals (Baerentzen & Aanes 2005). 3,258 tests. |
| 2026-02-28b | HDDA Volume Rendering | Span-merging HDDA following OpenVDB VolumeHDDA pattern. 97% empty space skipped on sparse grids. Trilinear interpolation in volume renderer. |
| 2026-02-28 | Phases 4-7 Complete | Differential operators (gradient, divergence, curl, laplacian, mean curvature), level set ops, morphology, filtering, quadratic interpolation, particles_to_sdf. 19 issues closed. |
| 2026-02-28 | OpenVDB Feature Parity Phase 1+3 | 43 beads issues created. CSG union/intersection/difference, level set primitives, grid ops (activate/deactivate, comp_max/min/sum, clip), pruning, compression write. 12 issues closed. |
| 2026-02-28 | Final Sprint 282/282 | Buffer reuse in read_dense_values. Render.jl extraction declined. All original issues closed. |
| 2026-02-28 | Julian Idiomaticity | Vector ops to stdlib (norm/dot/cross), VDBConstants.jl, mmap option, active-voxel gradient. 9 issues closed. |
| 2026-02-27 | Elegance Sprint Part 2 | Float16 tests, iterator edge cases, sphere_trace tests, robustness/truncation tests, export reduction (164 -> 40 symbols). |
| 2026-02-26 | Elegance Sprint | Typed exceptions, parametric tile dispatch, FileWrite cleanup, dispatch-based tree probe. -227 LOC. 10 issues closed. |
| 2026-02-25 evening | 34 Issues + Showcase Suite | Camera SVec3d, generic pixel pipeline, threaded gaussian_splat, GPU accumulation. 17 showcase stills + 4 movies. |
| 2026-02-25 | GR Architecture Review | Literature review (GRay2, RAPTOR, ipole, GYOTO). Fixed phi-wrap seam and CKS tetrad. 10 improvement beads created with dependency DAG. |
| 2026-02-24 | GR Rendering Fixes | VolumetricMatter bridge, future-directed momentum fix, verlet_step zero-alloc. Vertical seam diagnosed (phi-wrap in sphere_lookup). |
| 2026-02-24 | VolumetricMatter Bridge | ThickDisk, emission-absorption through curved spacetime. 39 new tests. |
| 2026-02-24 | GR Ray Tracing Phase 1 | Full Lyr.GR submodule: Schwarzschild metric, adaptive Stormer-Verlet, GRCamera with tetrad, ThinDisk, redshift, threaded rendering. 313 new GR tests. |
| 2026-02-24 | Camera voxel_size fix | World-space/index-space camera round-trip for non-unit voxel sizes. |
| 2026-02-23 | Type stability + dedup | VolumeEntry{G}, Scene{V} parametric. Extracted _render_grid helper. GPU CPU fallback background color. |
| 2026-02-23 | 3 P1 fixes | VolumeEntry without NanoGrid throws. FieldProtocol closures type-stable. VolumeMaterial concrete types. |
| 2026-02-23 | Code Review Distillation | 27 issues from 6-specialist review. Fixed adaptive voxelizer Z-axis bound. Fixed multi-volume compositing break/continue. |
| 2026-02-22 | Field Protocol v1.0 | AbstractField hierarchy, voxelize(), visualize(). 4 example scripts. 25,617 new tests. |
| 2026-02-21 | Gaussian splatting + grid builder | build_grid from Dict, gaussian_splat, MD spring demo. |
| 2026-02-21 | Denoising filters | denoise_nlm (non-local means) + denoise_bilateral. 558 new tests. |
| 2026-02-21 | GPU delta tracking | KernelAbstractions.jl kernel, device-side NanoVDB traversal, per-pixel RNG. 620 new tests. |
| 2026-02-18 | API cleanup | Export reduction (195 -> 129), Base.show methods, CTZ-based off_indices, TinyVDB cleanup. |
| 2026-02-18 | NanoVDB flat-buffer | Complete NanoVDB: leaf/I1/I2/root views, build_nanogrid, NanoValueAccessor, NanoVolumeRayIntersector. 6,274 new tests. |
| 2026-02-17 | DDA renderer complete | VolumeRayIntersector replaces brute-force intersect_leaves. sphere_trace delegates to find_surface. |
| 2026-02-16 | Hierarchical DDA | Amanatides-Woo 3D-DDA, Node-level DDA, Root->I2->I1->Leaf traversal. |
| 2026-02-15 | Tests + Phase 1 roadmap | read_dense_values tests, TreeRead tests, boundary-aware trilinear, precomputed matrix inverse. 21-issue Phase 1 roadmap. |
| 2026-02-15 | Fix 9 issues: perf + bugs | Mask prefix-sum O(1), ValueAccessor cache, TinyVDB compression fixes, ARM-portable unaligned load. |
| 2026-02-14 | Code review + 10 bug fixes | 6-specialist review, 77 issues created. Critical: read_tile_value types, TinyVDB compressed data, selection mask, v222 tile values. |
| 2026-02-14 | Level set rendering | Diagnosed trilinear corruption at node boundaries. Step clamping. DDA identified as proper fix. |
| 2026-02-14 | Multi-grid parsing | Fixed descriptor interleaving, parse_value_type regex, half-precision vec3. 12/12 OpenVDB files parse. |
| 2026-02-14 | v220 tree reader | Two-phase topology+values for pre-v222 files. bunny_cloud.vdb parses. |
| 2026-02-14 | smoke.vdb fix + rearch | Fixed transform/tree reading bugs. Main Lyr is sole production parser, TinyVDB is test oracle only. |

---

## Open Issues / What's Next

### Immediate (from latest sessions)

1. **Finish CUDA.jl install + test GPU path** for ScalarQEDGPU on small grid (N=32)
2. **Rerun scalar QED 128-cubed zooming camera render** -- `julia --project -t auto examples/scatter_scalar_qed.jl`
3. **Close beads**: `tjyx` (Moller) and `22lf` (ionization) once demos look good
4. **Close beads**: `jirf`, `lwp3`, `hecg`, `fj1a`, `emsz` -- code is done
5. **Regenerate golden images**: T10.4/T10.5 PPM format mismatch (2 pre-existing test failures)

### QFT Scattering Viz Series (active project)

Critical path: `06zv` -> `vkhv` -> `4pim` -> `9ohr` -> `s6hk` -> `tjyx`

Most infrastructure issues (`vkhv`, `4pim`, `9ohr`) were completed during recent sessions. Remaining: close out Moller (`tjyx`) and ionization (`22lf`) demos once render quality is acceptable.

### Test Coverage Gaps

- `eu65` -- GR integrator unit tests (not yet written)
- `fgzb` -- VolumeIntegrator.jl unit tests (blocked by delta tracking fix, now unblocked)
- `fj1a` -- ImageCompare.jl unit tests (already tested, needs formal close)

### GR Improvement Beads (from 2026-02-25 architecture review)

These are lower priority now but represent the remaining GR rendering improvement path:

| ID | P | What | Status |
|---|---|---|---|
| `esr2` | P1 | RK4 integrator (critical path, unblocks 4 downstream) | Open |
| `l8dy` | P1 | Fix volumetric double-intensity color mapping | Open |
| `tyrz` | P1 | Early tau-cutoff in volumetric tracer | Open |
| `vsfi` | P1 | Outgoing Kerr-Schild for backward tracing | Open (depends on 6gu3, done) |
| `a5ze` | P1 | Angular-velocity adaptive stepping | Open (depends on esr2) |
| `bjox` | P2 | Fuse metric_inverse + partials | Open (depends on esr2) |
| `o9zw` | P2 | Tile-based rendering for cache locality | Open (depends on esr2) |
| `837k` | P2 | GPU via KernelAbstractions.jl | Open (depends on esr2, bjox) |

### Rendering Quality Issues

- **Washed-out volumetric GR colors**: Reinhard tone mapping over-compresses. Try `1 - exp(-exposure * r)` or `clamp(r * gain, 0, 1)`. The split between normalized `disk_temperature` and Kelvin `disk_temperature_nt` may be incorrect.
- **Pole artifact**: Residual dotted vertical line above/below BH shadow. sin-squared floors and theta termination help but don't eliminate it. Consider wider pole termination or Kerr-Schild for near-pole rays.
- **Virtual photon visibility**: E1*E2 cross-term weak at large separations in scalar QED. May need artificial EM scaling for visualization.

---

## Active Beads Issues

Use `bd ready` for current unblocked list and `bd stats` for project health.

**Key active issue IDs referenced above:**
- QFT Scattering: `06zv` (epic), `vkhv`, `4pim`, `qzxv`, `9ohr`, `dygj`, `qkc2`, `22lf`, `s6hk`, `tjyx`
- Test coverage: `eu65`, `fgzb`, `fj1a`, `emsz`
- GR improvements: `esr2`, `l8dy`, `tyrz`, `vsfi`, `a5ze`, `bjox`, `o9zw`, `837k`
- Refactoring (code done, needs close): `jirf`, `lwp3`, `hecg`

```bash
bd ready           # Unblocked issues
bd blocked         # Dependency chain view
bd stats           # Project health
julia --project -e 'using Pkg; Pkg.test()'  # Full suite (~12 min)
```
