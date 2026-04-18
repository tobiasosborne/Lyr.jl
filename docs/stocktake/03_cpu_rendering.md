# CPU Rendering Pipeline — Architectural Stocktake

## 1. File Purposes

| File | One-line purpose |
|---|---|
| `Ray.jl` | Ray struct + precomputed inv_dir, slab AABB intersection, `LeafIntersection` |
| `DDA.jl` | Amanatides-Woo DDA (`DDAState`/`dda_step!`) + hierarchical `VolumeRayIntersector` lazy iterator |
| `VolumeHDDA.jl` | Span-merging HDDA over NanoGrid: `NanoVolumeHDDA` iterator + zero-alloc `foreach_hdda_span` |
| `VolumeIntegrator.jl` | Delta tracking, ratio tracking, single-scatter and multi-bounce path tracers, `render_volume_image` |
| `Render.jl` | Camera, `camera_ray`, surface `render_image` (sphere-trace dispatch + Lambertian shading) |
| `Surface.jl` | Level-set surface finding: DDA voxel walk + sign-change bisection + normal via central differences |
| `Particles.jl` | Gaussian splatting and particle-to-SDF conversion (grid-building only, not rendering) |
| `TransferFunction.jl` | Piecewise-linear RGBA TF: binary-search interpolation + named presets |
| `PhaseFunction.jl` | Isotropic and Henyey-Greenstein phase functions: `evaluate` + analytic CDF `sample_phase` |
| `Scene.jl` | Scene graph types: `Camera`, lights, `VolumeMaterial`, `VolumeEntry`, `Scene` |
| `Visualize.jl` | High-level `visualize(field)` one-call pipeline: voxelize → auto-camera → render → tonemap |
| `Interpolation.jl` | Nearest/trilinear/quadratic-B-spline sampling; `get_value_trilinear` used in integrator hot path |

---

## 2. Entry Points and Call Graph

```
visualize(field)                          [Visualize.jl:250]
  voxelize(field)
  build_nanogrid(grid.tree)
  _render_grid(grid, nanogrid; ...)       [Visualize.jl:300]
    render_volume_image(scene, w, h)      [VolumeIntegrator.jl:550]
      _render_volume_image_cpu(...)       [VolumeIntegrator.jl:573]
        _precompute_volume(vol)           [VolumeIntegrator.jl:45]
        Threads.@threads per row
          camera_ray(scene.camera, u, v)  [Render.jl:50]
          _trace_ss(ray, pvols, ...)      [VolumeIntegrator.jl:608]
            intersect_bbox(ray, bmin,bmax)[Ray.jl:80]
            delta_tracking_step(...)      [VolumeIntegrator.jl:136]
              node_dda_init / dda_step!   [DDA.jl:149/98]
              _delta_sample_span(...)     [VolumeIntegrator.jl:82]
                get_value_trilinear(acc)
            ratio_tracking(shadow_ray)    [VolumeIntegrator.jl:296]
            evaluate(pv.tf, density)      [TransferFunction.jl:47]
            evaluate(pv.pf, cos_theta)    [PhaseFunction.jl:55/66]

render_image(grid, camera, w, h)         [Render.jl:146]  -- surface path
  camera_ray(camera, u, v, aspect)
  find_surface(ray, grid)                [Surface.jl:184]
    VolumeRayIntersector(tree, idx_ray)  [DDA.jl:315]
    dda_init / dda_step!                 [DDA.jl:43/98]
    _bisect_crossing(...)                [Surface.jl:80]
    _surface_normal(...)                 [Surface.jl:111]
  shade(normal, light_dir)              [Render.jl:130]

render_volume(scene, ReferencePathTracer,...) [VolumeIntegrator.jl:811]
  _trace_ms_opt(...)                    [VolumeIntegrator.jl:737]
    delta_tracking_step / ratio_tracking
    sample_phase(pv.pf, dir, rng)       [PhaseFunction.jl:83/102]
    Russian roulette [VolumeIntegrator.jl:784]
```

---

## 3. Ray Representation and Intersection Primitives

`Ray` (`Ray.jl:37`) stores `origin::SVec3d`, `direction::SVec3d` (normalized), and precomputed `inv_dir::SVec3d`. Zero-component directions become `copysign(Inf,0)` via `_safe_inv_dir` (`Ray.jl:48`) to make slab math numerically safe.

`intersect_bbox` (`Ray.jl:80`) is a scalar slab test with no intermediate `SVector` allocation. NaN-safe `_nmin`/`_nmax` helpers absorb parallel-axis rays gracefully. Returns `(t_enter, t_exit)` or `nothing`. Three overloads accept `AABB`, `BBox`, or min/max corner pairs.

`AABB` (`Ray.jl:12`) is the float-precision variant; `BBox` (integer `Coord`) is used inside the tree — converted on demand.

---

## 4. DDA / HDDA Architecture

### Flat DDA (`DDA.jl`)

`DDAState` (`DDA.jl:28`) is a mutable struct with `ijk::Coord`, `step`, `tmax`, `tdelta` (latter two constant after init). `dda_init` (`DDA.jl:43`) nudges `tmin` by `1e-9` inward to avoid boundary ambiguity. `dda_step!` (`DDA.jl:98`) selects the minimum-`tmax` axis and advances it — one `Coord` rebuild per step (no allocation, stack-only).

`NodeDDA` (`DDA.jl:128`) wraps a `DDAState` scoped to an internal node's child grid at stride `child_size`. `node_dda_query` (`DDA.jl:162`) combines the bounds check and child-index computation in a single pass.

### Hierarchical DDA over Tree (`DDA.jl:212`)

`VolumeRayIntersector{T}` (`DDA.jl:315`) is a lazy front-to-back iterator. Its three-phase state machine (`_vri_advance`, `DDA.jl:376`):

1. **Phase 1** — drain I1 `NodeDDA` (16³ grid, stride 8), yield `LeafIntersection` on each active leaf AABB hit.
2. **Phase 2** — step I2 `NodeDDA` (32³ grid, stride 128) to find the next I1 child with an AABB hit.
3. **Phase 3** — advance to the next pre-sorted I2 root entry.

This is used by both `intersect_leaves` (`Ray.jl:156`) and `find_surface` (`Surface.jl:197`).

### Span-Merging HDDA over NanoGrid (`VolumeHDDA.jl`)

`NanoVolumeHDDA{T}` (`VolumeHDDA.jl:33`) and `foreach_hdda_span` (`VolumeHDDA.jl:230`) share the same three-phase logic but over the flat NanoGrid byte buffer:

- Active cells (child or tile) **extend** an open `span_t0`.
- An inactive cell with an open span **closes and yields** a `TimeSpan`.
- Span merging is implicit: consecutive active cells accumulate into one span without intermediate yields.

`foreach_hdda_span` avoids all heap allocation: root hits go into `MVector{8}` stack buffers, sorted by insertion sort (typically 1–2 roots). This is the preferred integration path. `NanoVolumeHDDA` (iterator protocol) is provided for ergonomics but forces `HDDAState` onto the heap.

In the integrator, `delta_tracking_step` and `ratio_tracking` each inline the full three-phase HDDA state machine directly (`VolumeIntegrator.jl:136, 296`) to avoid closure boxing of mutable loop variables — the critical design decision enabling zero-allocation inner loops.

---

## 5. VolumeIntegrator Internals

### `_PrecomputedVolume` (`VolumeIntegrator.jl:25`)

Created once per frame from `VolumeEntry`. Caches `sigma_maj = max_density * sigma_scale`, `accept_scale = 1/max_density`, bounding box, TF, and phase function. Avoids per-ray tree traversal for these scalars.

### Delta Tracking (`delta_tracking_step`, `VolumeIntegrator.jl:136`)

Woodcock/delta tracking (Woodcock et al. 1965):
1. Sample free-flight distance `t += randexp(rng) / sigma_maj`.
2. Query `get_value_trilinear` at the hit position.
3. Accept with probability `density * accept_scale = density / max_density`.
4. On accept: return `:scattered` (prob = albedo) or `:absorbed`.
5. On reject: continue (null collision).

Helper `_delta_sample_span` (`VolumeIntegrator.jl:82`) encapsulates the per-span inner loop; called from the inlined HDDA state machine.

### Ratio Tracking (`ratio_tracking`, `VolumeIntegrator.jl:296`)

Used for shadow rays (transmittance estimation). Biased approximation: accumulates `T *= (1 - density * accept_scale)` at each null-collision step. Early exit when `T < 1e-10`. Deterministic result for fixed rng seed.

### Single-Scatter Path (`_trace_ss`, `VolumeIntegrator.jl:608`)

Per sample per pixel:
1. Intersect volume bounding box.
2. `delta_tracking_step` → collision event.
3. On scatter/absorb: query TF at hit density for emission color.
4. For each light: build shadow ray, `ratio_tracking` → transmittance.
5. NEE: `color += emission * light_intensity * phase * transmittance * emission_scale`.
6. Escaped rays add background.

No multi-bounce; throughput is a scalar that currently stays at `1.0` (single scatter).

### Multi-Scatter Path Tracer (`_trace_ms_opt`, `VolumeIntegrator.jl:737`)

Loop `bounce in 0:max_bounces`:
1. `delta_tracking_step` with albedo=1.0 to find collision.
2. NEE shadow ray via `_shadow_transmittance`.
3. `throughput *= albedo`.
4. `sample_phase` for new scatter direction → update `current_ray`.
5. Russian roulette starting at `rr_start`: survive prob = `clamp(throughput, 0.05, 1.0)`, rescale on survival.
6. Early exit if `throughput < 1e-10`.

### Emission-Absorption Preview (`render_volume_preview`, `VolumeIntegrator.jl:473`)

Deterministic fixed-step ray marching via `foreach_hdda_span`. Per step:
`sigma_t = alpha * sigma_scale * step_size`, `T *= exp(-sigma_t)`, emission accumulated via `(1 - exp(-sigma_t)) * emission_scale`. No stochastic sampling; good for iteration speed.

### Dispatch (`render_volume`, `VolumeIntegrator.jl:804`)

`render_volume(scene, ReferencePathTracer(...))` → multi-scatter.  
`render_volume(scene, SingleScatterTracer(), ...)` → `render_volume_image`.  
`render_volume(scene, EmissionAbsorption(...))` → preview.

---

## 6. Phase and Transfer Functions

### TransferFunction (`TransferFunction.jl`)

`TransferFunction` holds a sorted `Vector{ControlPoint}` (`density::Float64`, `color::NTuple{4,Float64}`). `evaluate` (`TransferFunction.jl:47`) uses binary search (O(log n)) then lerps the bracketing pair component-wise. No LUT — evaluated per stochastic hit (low call rate in delta tracking). Presets: `tf_blackbody`, `tf_smoke`, `tf_cool_warm`, `tf_viridis`.

### PhaseFunction (`PhaseFunction.jl`)

Two concrete types: `IsotropicPhase` (returns `1/(4π)` always) and `HenyeyGreensteinPhase{g}`.

`evaluate(::HenyeyGreensteinPhase, cos_theta)` (`PhaseFunction.jl:66`):
`p = (1 - g²) / (4π (1 + g² - 2g cos_θ)^(3/2))`

`sample_phase(::HenyeyGreensteinPhase, incoming, rng)` (`PhaseFunction.jl:102`) uses the analytic inverse CDF: samples `ξ ~ U[0,1]`, computes `cos_theta = (1 + g² - ((1-g²)/(1+g-2gξ))²) / (2g)`. Builds an orthonormal basis from `incoming` via Gram-Schmidt with least-axis selection (`_build_orthonormal_basis`, `PhaseFunction.jl:137`).

The `_PrecomputedVolume.pf` field is typed `Union{IsotropicPhase, HenyeyGreensteinPhase}` (`VolumeIntegrator.jl:35`) — a concrete union that enables union-splitting by the Julia compiler, eliminating virtual dispatch in the hot path.

---

## 7. Surface and Particle Renderers

### Surface Renderer (`Surface.jl`, `Render.jl`)

`find_surface` (`Surface.jl:184`) operates in index space:
1. Transform world ray to index space via `_to_index_ray` (nudges perpendicular axes by `1e-6` to avoid `0*Inf` NaN at node boundaries).
2. Iterate leaves front-to-back via `VolumeRayIntersector`.
3. Within each leaf: run `dda_init/dda_step!` at stride 1, read SDF directly from `leaf.values` (O(1)).
4. Detect positive→non-positive sign change.
5. `_bisect_crossing`: 8 binary search iterations → ~1/256 voxel precision.
6. `_surface_normal`: central differences with active-mask-aware fallback (one-sided when neighbor is outside narrow band).
7. Transform hit point and normal back to world space via inverse-transpose for non-uniform scale.

`render_image` (`Render.jl:146`) dispatches to `find_surface`, then `shade` (Lambertian: `0.2 + 0.8 * max(0, N·L)`). Supports stratified jittered supersampling and gamma correction.

### Particle Tools (`Particles.jl`)

`gaussian_splat` and `particles_to_sdf` are grid-building functions, not renderers. They produce `Grid{Float32}` instances that feed into the standard volume pipeline. Parallel via `Threads.@threads` with thread-local `Dict` accumulators merged afterward. `particle_trails_to_sdf` adds capsule (line-segment) SDF geometry.

---

## 8. Materials

`VolumeMaterial` (`Scene.jl:92`) stores:
- `transfer_function::TransferFunction`
- `phase_function::PhaseFunction` (abstract — triggers dynamic dispatch unless via `_PrecomputedVolume`)
- `sigma_scale`, `emission_scale`, `scattering_albedo` (all `Float64`)

`VolumeEntry{G,N}` (`Scene.jl:131`) is parametric on grid type `G` and nanogrid type `N ∈ {NanoGrid, Nothing}`. The `N` parameter lets the compiler prove `nanogrid !== nothing` is unreachable when `N=NanoGrid`, eliminating the branch.

`_PrecomputedVolume{T}` (`VolumeIntegrator.jl:25`) extracts all hot-path scalars once per frame. The phase function is stored as `Union{IsotropicPhase, HenyeyGreensteinPhase}` — a concrete union that enables **union-splitting**: the compiler generates two specialised code paths and selects at compile time, removing all virtual dispatch from the render loop.

---

## 9. Hot Paths and Allocation Hygiene

- **Zero-alloc inner loop**: `delta_tracking_step` and `ratio_tracking` inline the HDDA state machine directly instead of using a closure over `foreach_hdda_span`. This avoids boxing of mutable loop variables (`span_t0`, `t`, `T_acc`) that would otherwise escape to the heap (`VolumeIntegrator.jl:119–125`).
- **Stack root buffers**: `MVector{8, Float64}` collects I2 root hits without heap allocation; insertion sort is O(1) for typical 1–2 roots (`VolumeHDDA.jl:237`, `VolumeIntegrator.jl:147`).
- **`@inline` on all inner-loop helpers**: `dda_step!`, `node_dda_query`, `node_dda_cell_time`, `intersect_bbox`, `_delta_sample_span`, `_ratio_sample_span`, `_precompute_volume`, `_light_contribution` — prevents call overhead in the million-times-per-frame paths.
- **`Threads.@threads` per row**: Each thread owns a `Xoshiro` RNG seeded by `seed + y` and a pre-allocated `NanoValueAccessor` array. No shared mutable state; no locks.
- **`NanoValueAccessor` reuse**: A single accessor per thread is passed into `delta_tracking_step` and reset with `reset!(acc)` between calls, avoiding per-call allocation (`VolumeIntegrator.jl:139, 299`).
- **`@inbounds`**: Applied to root-buffer loops and I1/I2 DDA loops in `foreach_hdda_span` and both inlined integrator state machines.
- **`const` scalars**: `_INV_FOUR_PI` (`PhaseFunction.jl:48`), `_MAX_ROOTS` (`VolumeHDDA.jl:219`) are module-level constants.
- **No `@fastmath`**: Not used — preserves IEEE semantics needed for correct transmittance and NaN-guarded slab math.
- **TF binary search vs LUT**: TF `evaluate` uses binary search on a small sorted vector (typically 4–6 points). This is called only at stochastic collision sites (not per step), so the O(log n) cost is negligible; no LUT needed.
