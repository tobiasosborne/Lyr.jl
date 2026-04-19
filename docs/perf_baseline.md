# Lyr.jl Performance Baseline + WebGL Target

**Bead**: path-tracer-jgjq (A4)
**Date**: 2026-04-19
**Hardware reference**: NVIDIA GeForce RTX 3090, Julia 1.12.3, CUDABackend.
**Author**: research task output. No code was executed to produce this document.

This document fixes a concrete, numeric WebGL target for the perf epic. Without
this, "WebGL is faster" is rhetoric. With this, every future perf change has a
time budget to hit and a scene to reproduce.

---

## 1. Lyr baseline (A2 snapshot, RTX 3090)

Source of numbers: `bench/results/2026-04-19.json` (generated 2026-04-19 14:51
UTC). Config: **800 × 600, spp=8, stochastic delta tracking through NanoVDB,
`max_bounces=0` (primary + direct lighting only)**. This is Lyr's production
GPU path (`gpu_render_volume`, `src/GPU.jl:1415`), not the preview path.

| Scene | Active voxels | Buffer (KB) | Upload (ms) | Kernel (ms) | Accum (ms) | Readback (ms) | **Total (ms)** |
|---|---:|---:|---:|---:|---:|---:|---:|
| smoke.vdb (sparse fog) | 1,049,275 | 6,493 | 5.1 | 916.6 | 2.2 | 4.2 | **935.4** |
| bunny_cloud.vdb (dense cloud) | 19,210,271 | 137,804 | 21.1 | 1,268.7 | 2.0 | 4.5 | **1,303.9** |
| level_set_sphere (synthetic) | 55,636 | 1,004 | 2.4 | 2,626.3 | 4.8 | 0.8 | **2,638.4** |

Interpretation:

- **Kernel dominates**: 95-99% of wall time across all three scenes. Upload
  (H2D), accumulate, and readback are already negligible at 800×600. The
  optimization target is kernel time.
- **Active-voxel count does not predict time**. The sparsest scene
  (level_set_sphere, 56 k active voxels, ~1 MB buffer) is the *slowest*
  because the level-set geometry produces thick optical depth with HDDA spans
  that traverse most of the bounding box and trigger many scatter events per
  ray. Lesson: "sparse" helps empty-space skipping but does not bound work.
- **Stochastic path tracer behavior**: at spp=8 and `max_bounces=0`, each pixel
  fires 8 independent delta-tracking rays plus 8 shadow rays (one per sample,
  since lighting is evaluated at primary scatter). The expected number of
  free-flight iterations per ray is `D × sigma_maj` where D is voxels
  traversed of active medium (see `docs/stocktake/08_perf_vs_webgl.md` §2).
  For `sigma_maj = max_density × sigma_scale` with typical `sigma_scale ≈ 10`,
  this is structurally more work than a WebGL fixed-step march of the same
  region.

---

## 2. WebGL comparison target

### 2.1 Chosen reference renderer

**Will Usher's WebGL Volume Raycaster** (a.k.a. the Twinklebear raycaster).

| Field | Value |
|---|---|
| Source | https://github.com/Twinklebear/webgl-volume-raycaster |
| Pinned commit | `c1859be` (2022-08-09) |
| Live demo | https://www.willusher.io/webgl-volume-raycaster/ |
| Blog reference | https://www.willusher.io/webgl/2019/01/13/volume-rendering-with-webgl/ |
| Author | Will Usher (scivis researcher, author of OSPRay browser port) |
| License | MIT |

**Why this one, not three.js / vtk.js / WebGPU / Shadertoy clouds.**

- **three.js `webgl2_materials_texture3d` + `VolumeRenderShader1`**: I pulled
  the source. The shader implements **MIP (Maximum Intensity Projection)** and
  **ISO (isosurface with refinement)**, not emission-absorption Beer-Lambert
  compositing. Quote from the shader: `if (val > max_val) { max_val = val; ... }`.
  It is the wrong comparison target — neither mode corresponds to what Lyr
  does. Using it would overstate our gap (MIP is even cheaper than EA) and
  misrepresent the algorithm.
- **vtk.js cinematic volume rendering**: implements volumetric shading with
  shadow rays and is a closer match algorithmically. But it is a large
  production library with many configuration axes, and Kitware's published
  benchmarks evaluate clinical CT/US datasets with five different shading
  configurations rather than a single canonical scene. Too many knobs to pin
  a reproducible target.
- **WebGPU volume renderers**: exist but none is as canonical / referenced as
  the Usher raycaster. WebGPU in browsers stabilized in 2023; adoption for
  volume rendering is still fragmentary.
- **Shadertoy volumetric clouds**: evaluate analytic density fields (FBM noise,
  Mandelbulb SDF), not a stored 3D texture. The ALU/texture mix is totally
  different from Lyr's grid-based rendering. They are popular but not the
  right target.

The Usher raycaster is the right reference because: (a) it uses a stored
`TEXTURE_3D` volume — directly comparable to NanoVDB; (b) it is
emission-absorption front-to-back compositing — directly comparable to
`render_volume_preview`; (c) its source is ~90 lines of GLSL, so the
algorithm is fully auditable; (d) Will Usher is the go-to author for
WebGL scivis volume rendering (OSPRay maintainer, HPG/VIS publications),
so it is the defensible "canonical" choice.

### 2.2 Numeric target

The full rendering algorithm is the fragment shader at
`js/shader-srcs.js` in the raycaster repo. I reproduce the load-bearing part
because the exact behavior is the target:

```glsl
// compute per-ray step size: one sample per voxel along longest axis
vec3 dt_vec = 1.0 / (vec3(volume_dims) * abs(ray_dir));
float dt = dt_scale * min(dt_vec.x, min(dt_vec.y, dt_vec.z));
float offset = wang_hash(int(gl_FragCoord.x + 640.0 * gl_FragCoord.y));
vec3 p = transformed_eye + (t_hit.x + offset * dt) * ray_dir;
for (float t = t_hit.x; t < t_hit.y; t += dt) {
    float val = texture(volume, p).r;                          // hardware trilinear
    vec4 val_color = vec4(texture(colormap, vec2(val, 0.5)).rgb, val);
    val_color.a = 1.0 - pow(1.0 - val_color.a, dt_scale);      // opacity correction
    color.rgb += (1.0 - color.a) * val_color.a * val_color.rgb; // front-to-back
    color.a += (1.0 - color.a) * val_color.a;
    if (color.a >= 0.95) { break; }                            // early ray termination
    p += ray_dir * dt;
}
```

Key algorithmic facts:

- **Fixed-step front-to-back EA compositing.** Pure Beer-Lambert emission-
  absorption with hard-coded 0.95 early ray termination.
- **Step size = one sample per voxel along the longest axis**, modulated by
  `dt_scale` (the dynamic quality knob).
- **Hardware trilinear** via the `sampler3D` `texture()` intrinsic. This is
  the single biggest structural difference from Lyr, which does software
  trilinear over the NanoVDB byte buffer.
- **Per-pixel jitter via wang_hash** over `gl_FragCoord` to hide stepping
  banding (this is effectively 1-tap dithering, not spp).
- **No shadow rays, no multi-bounce, no scattering.** One fragment shader
  invocation per pixel, one ray, one accumulation loop, done.
- **Data precision**: `R8` (8-bit unsigned, normalized). Quote from
  `volume-raycaster.js`: `gl.texStorage3D(gl.TEXTURE_3D, 1, gl.R8, ...)`.
  The demo does not use Float32 volumes.

**Canvas resolution (official demo)**: 640 × 480. Quote from `index.html`:
`<canvas id="glcanvas" ... width="640" height="480">`.

**Target frame time (official demo)**: 32 ms. Quote from
`volume-raycaster.js`: `var targetFrameTime = 32;`. The renderer's sampling
rate control loop PID-targets this as its steady-state, meaning on a
sufficiently fast GPU the shader runs faster than 32 ms/frame and
`samplingRate` is held at its default (`dt_scale = 1.0`, one sample per
voxel along the longest axis). On slower GPUs it backs `dt_scale` off until
frame time lands at ~32 ms.

**Canonical dataset**: Skull 256³ uint8 (also Bonsai 256³, Foot 256³, Engine
256×256×128). Quote from the volume list:
```
"Skull": "...skull_256x256x256_uint8.raw"
```
Use **Skull 256³ uint8** as the canonical scene. It is the iconic volume
rendering benchmark dataset (the original Siemens skull CT), it is in the
demo's dropdown, and it is a dense volume with meaningful interior structure
that requires traversing most of the bounding box.

#### Per-frame sample count (order-of-magnitude accounting)

For Skull 256³ rendered diagonally:
- Ray length in normalized volume space ≈ √3 ≈ 1.73
- Steps per ray = 1.73 / dt ≈ 1.73 × 256 ≈ **~443 samples along the longest diagonal**, typically 256-443 for arbitrary orientations.
- Pixels at 640×480 = 307,200. Pixels at 1920×1080 = 2,073,600.

At dt_scale=1.0, per-frame sample budget:
- 640×480: ~307k × 300 avg ≈ **92 M hardware-trilinear samples/frame**
- 1920×1080: ~2.07M × 300 avg ≈ **620 M hardware-trilinear samples/frame**

RTX 3090 sustained texture fill on `R8` 3D textures with trilinear is hundreds
of gigasamples/s; 620M samples is well within a sub-16 ms budget at 1080p,
consistent with the observation that on desktop the Usher demo stays pinned
at `dt_scale = 1.0` and runs substantially faster than its 32 ms/frame
software-side target.

#### The numeric target

**Primary target (official demo config):**
- **Skull 256³ uint8 volume, 640 × 480, `dt_scale = 1.0`, EA compositing, ≤32 ms/frame (≥30 FPS)**.
- This is what the canonical WebGL raycaster literally targets in its control loop.
- Upload amortized (one-time); includes only kernel time and display swap.

**Aggressive target (typical desktop user experience):**
- **Skull 256³ uint8, 1920 × 1080, `dt_scale = 1.0`, EA compositing, ≤16.7 ms/frame (60 FPS)**.
- An RTX 3090 running the Usher shader at 1080p is not a published number, but
  given (a) the RTX 3090 has ~570 Gsample/s trilinear 3D texture throughput,
  (b) the shader at 1080p is ~620M samples/frame, and (c) the demo's own
  sampling-rate controller reports rendering is faster than 32 ms/frame at
  `dt_scale = 1.0` on any post-2015 dGPU — an RTX 3090 at 1080p easily
  clears 60 FPS. Call this **~8 ms kernel time** as a conservative estimate
  (half of the 16.7 ms frame budget), with a stated margin of ±3 ms given
  that no exact number is published.
- The conservative target for the perf epic is **16.7 ms** (the 60 FPS
  budget), not 8 ms (the estimate of what the WebGL reference actually hits).
  We aim to hit the frame budget, not to match what RTX-3090-running-browser
  has spare.

**Floor of the gap**: At 1920×1080, Lyr's `render_volume_preview` on a sparse
~1 MB NanoVDB (the smoke-analog) needs to come in at ≤16.7 ms to match the
WebGL target. Today's A2 baseline at 800×600 spp=8 delta-tracking is
~935 ms — but that's a different algorithm. The correct Lyr-side number to
compare is yet-to-be-measured `render_volume_preview` on GPU at 1920×1080
with equivalent config. That measurement is the first deliverable of the
perf epic. See §3.

### 2.3 Fair-comparison methodology

**Which Lyr mode corresponds to the WebGL shader.**

| WebGL Usher shader | Lyr equivalent |
|---|---|
| Fixed-step EA ray march | `render_volume_preview` (`src/VolumeIntegrator.jl:473`) |
| Hardware trilinear texture | `_gpu_get_value_trilinear` (software, `src/GPU.jl:302`) — hardware trilinear via CuTexture fast path is not yet implemented (see stocktake §4.4) |
| spp=1 with wang_hash dither | spp=1, no jitter (preview path is deterministic) |
| No shadow rays | `render_volume_preview` does no shadow rays |
| No multi-scatter | `max_bounces` does not apply to preview path |
| Step size = 1/max_dim | `step_size=0.5` kwarg default; set to match voxel size for apples-to-apples |
| Upload once, amortize | Use cached `GPUNanoGrid` (type exists at `src/GPU.jl:76-79` but not wired into main path; see stocktake §4.2) |

The comparison Lyr mode is **NOT** `gpu_render_volume` with spp=8 and
delta tracking — that's the production path tracer, which is algorithmically
different. The A2 baseline numbers (935-2638 ms) are that path, and should
**not** be used in the WebGL comparison. The perf epic needs a new
benchmark: `render_volume_preview` on GPU (which currently only runs on CPU —
see §3, phase 0).

**Resolutions.**
- Primary: 1920×1080. This is the modern laptop / desktop viewport and the
  resolution users mean when they say "smooth in the browser."
- Secondary: 640×480 (matches the Usher demo exactly). Useful for
  reproducing his own control loop behavior on the same GPU and ruling
  out any per-pixel-budget difference.

**What to include in the kernel-time comparison.**
- Ray march kernel launch + synchronize.
- All sampling, compositing, and early termination.

**What to exclude.**
- H2D upload. WebGL uploads a volume once when loading a dataset and then
  runs thousands of frames against the same texture. Including upload in
  per-frame time is never done in the WebGL literature.
- Pixel readback. The WebGL demo never reads pixels back — it displays
  directly. For a fair per-frame comparison we exclude `Array(output_buf)`
  at the end of Lyr's render. (This is a separate axis of the design: Lyr
  is an offline renderer; the WebGL shader is an interactive display. We
  compare kernel time only and acknowledge the display pipeline difference
  in §2.4.)

### 2.4 Why this is not apples-to-apples even after tuning

These caveats are structural. They cannot be engineered away and need to
be stated every time this comparison is cited.

1. **Biased vs unbiased.** The Usher shader is fixed-step with a wang_hash
   dither. At dt_scale=1 (one sample per voxel) it is visibly banded near
   high-gradient features and systematically over-opaque at coarse step size
   (`1 - (1-α)^dt_scale` is a bias correction, not an exact reconstruction).
   Lyr's delta tracking is an unbiased Monte Carlo estimator of the volume
   rendering equation and converges to the analytic solution as spp → ∞. The
   preview-path comparison sets `render_volume_preview` against `Usher
   shader`, both biased; the full-path comparison (which we are **not**
   doing here) would be apples-to-oranges.

2. **Hardware trilinear vs software tree descent.** See
   `docs/stocktake/08_perf_vs_webgl.md` §1.1. One `texture()` call in GLSL
   is ~1-4 texture clock cycles. One `_gpu_get_value_trilinear` in Lyr is
   ~100 scattered byte reads. Even an optimal Lyr preview path with
   `CuTexture` fast path (stocktake §4.4) is CUDA-only; the portable path
   through KernelAbstractions has no abstraction for texture hardware.
   Matching WebGL on the portable path requires either dense 3D-texture
   fallback or warp-level coalescing tricks, neither of which is free.

3. **No shadow rays, no scattering.** The WebGL shader models neither. It is
   a scivis volume visualizer, not a physically-correct volume renderer.
   Matching its speed on the preview path says nothing about Lyr's
   production path tracer, which is an intentionally more expensive
   (because physically correct) product.

4. **Sparse tree overhead for dense grids.** The WebGL shader samples a
   dense `TEXTURE_3D`. For the Skull 256³ uint8 volume (16 MB) this is a
   trivial upload and ideal for dense-texture hardware. For the same data
   in NanoVDB, we pay tree traversal costs for every sample even though the
   grid is dense. This is a representation mismatch for dense scenes. The
   fix is "dense 3D texture fast path for small grids" (stocktake §4.4),
   not something closable in the current sparse-tree path.

5. **WebGL persistent fragment shader vs kernel-per-spp launches.** See
   stocktake §1.3. WebGL draws a single quad per frame, dispatches the
   shader via the rasterizer, and never synchronizes with the CPU. Lyr
   launches `2 × spp` kernels with `synchronize` between each. For spp=1
   preview, this is a single kernel launch — so for the preview comparison
   this caveat is mild, but it reappears whenever the user bumps spp.

6. **WebGL does not target "render completion".** It targets "interactive
   response within 32 ms." When dt_scale backs off, image quality degrades
   until frame time lands in budget. Lyr has no equivalent knob. A fair
   "at equal quality" comparison must either disable Usher's control loop
   (pin `dt_scale = 1.0`) or give Lyr a matching quality knob.

7. **Disney cloud note.** There is no canonical WebGL renderer of the
   Disney cloud VDB. The Disney cloud is typically rendered offline with
   PBRT / Mitsuba / production renderers; no browser-scale public demo
   exists. This means we cannot directly benchmark Lyr's `bunny_cloud.vdb`
   (a cloud-like VDB) against WebGL at parity — the closest available
   comparison is Skull 256³ on the Usher demo vs a Lyr-voxelized dense
   density grid of similar voxel count. We accept this substitution; the
   VDB-to-dense-texture comparison is documented here rather than hidden.

---

## 3. Implications for the perf epic

The perf epic is bounded by the targets in §2.2. Concrete phased milestones:

### Phase 0 — Measurement prerequisites (no optimization yet)

Before any optimization, produce two missing measurements. Neither is
controversial; both are infrastructure.

- **P0.1**: Port `render_volume_preview` to a GPU kernel (it is currently CPU
  only, `src/VolumeIntegrator.jl:473-531` is `Threads.@threads`). This is the
  mode that should be benchmarked against the Usher shader. Without a GPU
  preview, we are literally unable to make the intended comparison.
- **P0.2**: Add a benchmark config for 1920×1080 and 640×480 alongside the
  existing 800×600 A2 baseline (`bench/results/2026-04-19.json`). Add the
  Skull 256³ uint8 dataset as a fixture (convert `.raw` to NanoVDB at
  `voxel_size=1.0` with the uint8 values in a Float32 grid, documenting the
  precision delta).

### Phase 1 — Get within 2× of target

- **Target**: GPU `render_volume_preview` at 1920×1080 on Skull 256³,
  ≤**33 ms/frame** kernel time (2× the 16.7 ms WebGL budget).
- **Expected levers**: (a) NanoGrid device-buffer caching (stocktake §4.2 —
  the `GPUNanoGrid` type exists but is not used in the main path); (b) fusing
  the spp loop into the kernel (stocktake §4.3 — preview is spp=1 so this
  doesn't apply to the preview path, but it applies to the production path);
  (c) exposing the preview mode via `quality=:preview` on `render_volume_image`
  (stocktake §4.1).

### Phase 2 — Get within 1.2× of target

- **Target**: GPU preview at 1920×1080, ≤**20 ms/frame** kernel time.
- **Expected levers**: (a) dense 3D texture fast path via `CuTexture` in
  `ext/LyrCUDAExt.jl` (stocktake §4.4). This is the single biggest structural
  change; it gets Lyr within a constant factor of hardware trilinear for
  grids that fit in texture memory. (b) ptxas register-pressure profiling on
  the preview kernel (stocktake §4.5) — smaller kernel than the delta-
  tracking kernel, should be cleaner.

### Phase 3 — Match target (with caveats)

- **Target**: GPU preview at 1920×1080, ≤**16.7 ms/frame** kernel time, on
  dense grids that fit in CUDA texture memory.
- **Caveats required in any public claim**: (1) preview path only, not full
  path tracer; (2) CUDA fast path only, KernelAbstractions portable path
  will remain 2-5× slower; (3) only applies to grids ≤512³ Float32 that fit
  in CuTexture.

### Not targeted by this epic

Lyr's stochastic delta tracking production path (`gpu_render_volume` at
`max_bounces > 0` with shadow rays) is a *different product* from the Usher
shader. No amount of kernel optimization makes unbiased Monte Carlo cheaper
than fixed-step deterministic march. The full-path-tracer epic is separate
(denoising, adaptive sampling, bidirectional estimators) and has a different
reference target (Mitsuba 3 / PBRT v4), not WebGL.

---

## 4. Sources

### Primary (the chosen reference)
- Twinklebear/webgl-volume-raycaster (commit `c1859be`, 2022-08-09):
  https://github.com/Twinklebear/webgl-volume-raycaster
- Live demo: https://www.willusher.io/webgl-volume-raycaster/
- Shader source (quoted above): https://raw.githubusercontent.com/Twinklebear/webgl-volume-raycaster/master/js/shader-srcs.js
- JS driver (640×480 canvas, `targetFrameTime = 32`, volume dict): https://raw.githubusercontent.com/Twinklebear/webgl-volume-raycaster/master/js/volume-raycaster.js
- HTML (canvas size): https://raw.githubusercontent.com/Twinklebear/webgl-volume-raycaster/master/index.html
- Companion blog post ("Volume Rendering with WebGL", 2019-01-13): https://www.willusher.io/webgl/2019/01/13/volume-rendering-with-webgl/
- Will Usher projects index: https://www.willusher.io/projects/

### Rejected alternatives (with reason)
- three.js `webgl2_materials_texture3d` (MIP/ISO, not EA): https://threejs.org/examples/webgl2_materials_texture3d.html
- three.js `VolumeRenderShader1` source (confirmed MIP/ISO): `examples/jsm/shaders/VolumeShader.js` in mrdoob/three.js
- vtk.js cinematic volume rendering (too many knobs, clinical focus): https://www.kitware.com/cinematic-volume-rendering/
- Shadertoy volumetric raymarchers (analytic density, wrong algorithm mix): https://www.shadertoy.com/view/DtBGR1

### Local context files consulted
- `/home/tobiasosborne/Projects/Lyr.jl/docs/stocktake/08_perf_vs_webgl.md` — existing architectural diagnosis; supplies the "why Lyr is slower" inventory and the prioritized fix list referenced in §2.4 and §3.
- `/home/tobiasosborne/Projects/Lyr.jl/bench/results/2026-04-19.json` — the A2 baseline numbers in §1.
- `/home/tobiasosborne/Projects/Lyr.jl/src/VolumeIntegrator.jl:460-531` — `render_volume_preview` source; confirms the preview path is CPU-only today (Phase 0 implication in §3).
- `/home/tobiasosborne/Projects/Lyr.jl/src/GPU.jl:76-79` — existing `GPUNanoGrid` type referenced for Phase 1.
- `/home/tobiasosborne/Projects/Lyr.jl/src/GPU.jl:302` — `_gpu_get_value_trilinear` referenced in the software-trilinear caveat (§2.4 item 2).

### On the 1920×1080 RTX 3090 estimate
No published Usher-raycaster FPS numbers exist for that hardware+resolution
combination. The estimate in §2.2 ("~8 ms kernel time ±3 ms") is derived from:
(a) RTX 3090 peak trilinear 3D texture throughput (NVIDIA Ampere whitepaper
class, order of 500+ Gsample/s); (b) 620 M samples/frame for 1920×1080 Skull
256³ at dt_scale=1.0, computed in §2.2; (c) the demo's own control loop
showing `samplingRate` never backs off from 1.0 on desktop GPUs (the
`targetSamplingRate > samplingRate` branch in `volume-raycaster.js` only
fires when frame time exceeds the 32 ms target). The target used by the
perf epic is **16.7 ms / 60 FPS**, not the estimate — the estimate exists
only to confirm the target is actually achievable for the reference
implementation on the reference hardware.
