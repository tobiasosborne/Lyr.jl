# Lyr.jl GPU Rendering: Performance Diagnostic vs WebGL Volume Renderers

**Date**: 2026-04-18  
**Scope**: Full rendering pipeline, CPU and GPU paths. Evidence-based: every claim
is anchored to a file:line in the codebase.  
**Goal**: Understand *why* Lyr's GPU path is structurally slower than a typical WebGL
volume renderer on similar scenes. This document does NOT prescribe fixes; it diagnoses.

---

## 1. The Architectural Gap

### 1.1 Dense 3D Texture + Hardware Trilinear vs Sparse NanoVDB Byte-Buffer + Software Trilinear

**WebGL**: a `sampler3D` uniform backed by a GPU-resident `GL_TEXTURE_3D` object.
A single `texture(sampler, uvw)` GLSL call performs trilinear interpolation
*in the hardware texture unit*, which does not consume shader ALU cycles and
typically takes a fixed 1–4 texture clock cycles (with L1/L2 texture-cache hits).

**Lyr**: every trilinear sample calls `_gpu_get_value_trilinear` (GPU.jl:302–338),
which calls `_gpu_get_value` eight times (GPU.jl:319–326), one per corner voxel.
Each `_gpu_get_value` (GPU.jl:185–289) performs:

1. A header read to get `root_count` and `root_pos` (two 4-byte buffer loads,
   GPU.jl:189–190).
2. A binary search over the root table (GPU.jl:200–220, `while lo <= hi` loop).
3. One mask bit-test at the I2 level (`_gpu_buf_mask_is_on`, GPU.jl:132–138):
   a 64-bit buffer load + shift + AND.
4. A prefix-sum read via `_gpu_buf_count_on_before` (GPU.jl:141–157), which
   itself does a UInt32 buffer load plus a `count_ones` on a partial word.
5. Another buffer load to follow the I2→I1 offset pointer (GPU.jl:255).
6. Repeat steps 3–5 at the I1 level.
7. A final buffer load for the leaf value (GPU.jl:288).

Total for a leaf-resident corner: **~12–16 scalar buffer reads** per corner ×
8 corners = **~100–130 scalar reads per trilinear lookup**, all scattered through
a byte array by pointer arithmetic. Each read is `_gpu_buf_load` (GPU.jl:101–129),
implemented as individual byte loads assembled with bit shifts. On CUDA that is
up to 8 load instructions (for `UInt64`) vs a single `ld.global.u8` per step.

The leaf-cache optimization (`_gpu_get_value_trilinear_cached`, GPU.jl:778–825)
helps when all 8 corners fall in the same 8³ leaf (GPU.jl:788 fast-path), but
that fast path still requires one full tree traversal to find the leaf the first
time, and misses on every leaf-boundary voxel.

**Verdict**: hardware texture sampling is functionally free compared to this software
tree descent. The gap is roughly the cost of ~100 scattered byte reads vs 1 hardware
fetch per voxel sample.

---

### 1.2 Fixed-Step Front-to-Back Marching vs Stochastic Delta Tracking

**WebGL**: fixed step size Δt along the ray; each step is one texture lookup +
one multiply-accumulate into the composited color. Noise-free at the cost of being
biased (step size visible as banding). Renders 1 sample per pixel per fragment
invocation, trivially parallelized across every fragment.

**Lyr**: the production path uses Woodcock delta tracking (VolumeIntegrator.jl:82–95
for CPU; GPU.jl:600–664 for linear GPU, GPU.jl:1008–1079 for HDDA GPU). Per free-
flight step:

- Sample an exponential free-flight distance with `randexp` / `_gpu_xorshift` + `log`.
- Perform a trilinear density lookup (cost: see §1.1 above).
- Draw a rejection sample with probability `density / sigma_maj`.
- If scattered: draw a third random number for absorption vs scattering.
- If scattered and rendering with `max_bounces > 0`: fire a **full shadow ray**
  per light (GPU.jl:622–660 / GPU.jl:1030–1070) — another up to 256 trilinear
  lookups per light, per scatter event.

For a ray that traverses D voxels of active medium, the *expected* number of free-
flight iterations is `D * sigma_maj` regardless of the scene's actual opacity —
because null collisions are included. In optically thick media with `sigma_scale=10`
(the default in `benchmark_gpu.jl`:22), this is dramatically more work than a fixed-
step traversal of the same region.

The **showcase** (`volumetric_showcase.jl`:116) uses `spp=32, max_bounces=48` on the
CPU reference path tracer. Applying spp×(expected_bounces_per_path) cost to a
1920×1080 scene gives an enormous multiply vs a fixed-step WebGL shader.

---

### 1.3 GLSL Fragment Shader (One Kernel Launch, Persistent) vs KernelAbstractions Kernel Loop

**WebGL**: a fragment shader runs once per frame as part of the rasterization
pipeline. The driver/GPU scheduler keeps threads alive for the duration. No
host-side allocation, no launch overhead between samples.

**Lyr GPU**: `gpu_render_volume` (GPU.jl:1415–1529) launches a separate kernel
invocation **per sample** (GPU.jl:1490–1512):

```julia
for s in 1:spp                           # GPU.jl:1490
    kernel!(...; ndrange=npixels)         # GPU.jl:1491–1506
    KernelAbstractions.synchronize(...)   # GPU.jl:1507 — CPU blocks here
    acc_kernel!(acc_buf, output; ...)     # GPU.jl:1510 accumulate kernel
    KernelAbstractions.synchronize(...)   # GPU.jl:1512 — CPU blocks again
end
```

For `spp=8` (the benchmark default), that is 8 render-kernel launches + 8
accumulate-kernel launches + 16 `synchronize` calls. Each `synchronize` is a
CPU stall waiting for the GPU to drain. At typical CUDA kernel launch overhead
of 5–50 µs per launch and synchronize, this adds `2 * spp * ~20µs = ~320µs`
pure overhead for `spp=8`, before counting actual render work. WebGL launches
zero extra commands for multiple samples — it just draws a quad per frame.

Additionally, every call to `gpu_render_volume` does:

- `_estimate_density_range`: a full scan of all 512 values in every leaf
  (GPU.jl:1372–1393), on the CPU.
- `Adapt.adapt(backend, nanogrid.buffer)`: **copies the entire NanoGrid byte
  buffer from CPU to GPU** on every call (GPU.jl:1476). This is `O(buffer_size)`
  host→device transfer even if the volume has not changed.
- `Adapt.adapt(backend, fill(z3, npixels))`: allocates and uploads two pixel
  buffers every call (GPU.jl:1482–1486).
- `Array(acc_buf)` at the end: **copies the entire pixel buffer back to CPU**
  (GPU.jl:1517), then does a final reshape loop on the CPU.

For a 512×512 render (`benchmark_gpu.jl:15 BENCHMARK_RES = 512`) the pixel
buffer is 512×512×12 bytes ≈ 3 MB round-trip per render call regardless of spp.

---

### 1.4 Software Mask Prefix-Sum (`_gpu_buf_count_on_before`) vs Hardware Texture Fetch

The child-index lookup inside the NanoVDB tree requires counting set bits
before a given position in the node's child-count mask. On GPU this is done by
`_gpu_buf_count_on_before` (GPU.jl:141–157): it loads a precomputed UInt32
prefix-sum word from the buffer, then calls `count_ones` on a partial UInt64
word. This is two buffer loads + one popcount per level crossed.

In a WebGL shader the equivalent operation does not exist — it's just an integer
divide/mod on a flat 3D texture coordinate. Prefix-sum lookups are a structural
cost of the sparse tree that simply does not arise in the dense-texture case.

---

### 1.5 NanoVDB Tree Descent (Root → I2 → I1 → Leaf) per Sample

Even with the HDDA path, every call to `_gpu_get_value_trilinear_cached`
that misses the leaf cache falls back to `_gpu_get_value_with_leaf`
(GPU.jl:702–755), which does a full binary search over the root table
(GPU.jl:710–725) — an O(log root_count) loop of buffer reads. On a grid
with multiple I2 nodes this is a genuinely variable-depth search, not a
constant-time random access. WebGL's `texture()` call is unconditionally O(1)
in hardware.

---

### 1.6 Float64 Register Pressure and Integer Widths on GPU

The CPU path (`VolumeIntegrator.jl`, `VolumeHDDA.jl`) uses `Float64` throughout
for positions and ray parameters (e.g., `VolumeIntegrator.jl:82–95`), and uses
native Julia `Int` (64-bit on x86-64) for buffer offsets. The GPU path correctly
uses `Float32` and `Int32` (GPU.jl:101–157, all offsets `Int32`), and `_gpu_xorshift`
(GPU.jl:372–377) is a minimal 32-bit PRNG. This part is reasonably optimized.

The `delta_tracking_kernel!` function body (GPU.jl:529–687) is not marked `@inline`
at the definition site (it is a `@kernel`, so inlining is handled by
KernelAbstractions). However, the inner helper `_gpu_hdda_delta_track`
(GPU.jl:1090–1265) is marked `@inline`, as is `_gpu_integrate_span`
(GPU.jl:988–1079). The trilinear helpers at GPU.jl:302, 302, 394 are also
`@inline`. Register pressure is not obviously catastrophic but has not been
profiled.

---

### 1.7 Multi-Bounce Path Tracing Is Not Gated at the API Level

The `render_volume_image` function defaults to `max_bounces=1`
(VolumeIntegrator.jl:553), and the GPU kernel defaults to `max_bounces=0`
(GPU.jl:1420). The showcase (`volumetric_showcase.jl`:116) uses
`max_bounces=48` — a full path tracer. This is a user choice, but the API
does not make the cost difference visible or provide a documented "preview"
mode that is clearly distinct from "production".

Each bounce multiplies the shadow ray cost: 1 bounce = 1 primary traversal +
1 shadow traversal per light. At `max_bounces=48` on a purely single-threaded
CPU run with `spp=32`, the expected path work is enormous. WebGL volume renderers
simply do not support multiple scattering in any comparable sense.

---

### 1.8 Shadow Rays / Next-Event Estimation Overhead

Both the CPU single-scatter path (`_trace_ss`, VolumeIntegrator.jl:608–651) and
the GPU kernel (GPU.jl:622–660) fire a **ratio-tracking shadow ray per light per
scatter event**. The GPU shadow loop (GPU.jl:638–652 in the linear kernel,
GPU.jl:1046–1069 in the HDDA kernel) runs up to 256 delta-tracking steps per
shadow ray, each doing a trilinear lookup. With `n_lights` lights
(GPU.jl:623 / 1031), the shadow cost is `n_lights × up to 256` trilinear
lookups per scatter event. The showcase uses 3 lights (`volumetric_showcase.jl`:106),
so the shadow budget is up to 768 trilinear lookups per scatter event before the
primary ray cost.

---

### 1.9 Host↔Device Transfers Per Render Call

As noted in §1.3, `gpu_render_volume` (GPU.jl:1415–1529):

- Uploads `nanogrid.buffer` every call via `Adapt.adapt` (GPU.jl:1476).
- Allocates and uploads `fill(z3, npixels)` twice (GPU.jl:1482–1486).
- Downloads `acc_buf` to CPU via `Array(acc_buf)` (GPU.jl:1517).

There is no caching of the device-side NanoGrid across render calls. A WebGL
renderer uploads the texture once and reuses it across all frames.

---

## 2. Concrete Per-Pixel Cost Accounting

For a W×H render with `spp` samples, one light, and mean free path µ through
D voxels of active medium:

**(a) Expected free-flight delta-tracking iterations per pixel**:

```
E[iterations] = spp × D × sigma_maj
```

With `sigma_maj = max_density × sigma_scale` (VolumeIntegrator.jl:56–58),
a volume with `max_density=1.0` and `sigma_scale=10` gives `sigma_maj=10`.
If a ray crosses 100 voxels of active medium, `E[iterations] = spp × 1000`
free-flight steps per pixel before a scatter event or escape.

**(b) Trilinear lookups per pixel**:

Each free-flight step calls `_gpu_get_value_trilinear` (GPU.jl:302–338 for linear
kernel, or `_gpu_get_value_trilinear_cached` GPU.jl:778–825 for HDDA kernel):

- Best case (all 8 corners in same cached leaf): **1 tree traversal + 8 leaf reads**.
- Worst case (all 8 corners in different leaves): **8 full tree traversals**.

At scatter, a shadow ray fires up to 256 additional trilinear lookups per light.

Total worst-case trilinear lookups per pixel:

```
T = spp × (E[iters_primary] × 8_corners + E[scatter] × n_lights × 256)
```

For `spp=8, D=100, sigma_maj=10, n_lights=1, scatter_prob=0.5`:
```
T ≈ 8 × (1000 × 8 + 500 × 256) ≈ 8 × 136000 = ~1,088,000 trilinear lookups per pixel
```

**(c) Buffer byte reads per trilinear lookup**:

Worst-case (cache miss, leaf-resident value):
- Root header: 2 × 4B = 8B
- Root binary search: ~3 iterations × ~3 reads × 4B = ~36B  
- I2 mask test: 1 UInt64 load = 8B
- I2 prefix sum: 1 UInt32 + 1 UInt64 = 12B
- I2→I1 offset: 4B
- I1 mask test: 8B
- I1 prefix sum: 12B
- I1→leaf offset: 4B
- Leaf value: 4B

**~96B per tree traversal**, × 8 corners = **~768B per trilinear lookup**
(worst case, cold cache).

For a 1920×1080×spp=8 render with the above parameters:
```
Total byte reads ≈ 1920 × 1080 × 1,088,000 × 768B ≈ 1.9 petabytes nominal
```

(Most of this hits L1/L2 cache, but the irregular access pattern means cache
efficiency is poor for scattered-density volumes.)

---

## 3. Measured vs Theoretical: What the Benchmark Actually Measures

`examples/benchmark_gpu.jl` measures:

1. **HDDA + leaf cache kernel** vs **linear kernel** (no HDDA) at 512×512, `spp=8`.
2. **GPU (HDDA) vs an estimated CPU time**, where the CPU time is measured at
   128×128 with `spp=2` and then *scaled* by `(512/128)² × (8/2) = 64` (line 119–120).

**What this benchmark does NOT measure**:

- Comparison against any WebGL renderer or a reference fixed-step GPU marcher.
- Transfer overhead (NanoGrid upload happens inside the timed region every call).
- Performance at large resolutions (1920×1080) typical of WebGL demos.
- Impact of `spp > 8` (WebGL demos run at ~60 FPS ≈ 16.7 ms per frame, implying
  1 spp at 1080p in real time).
- Performance with `max_bounces > 0` (the default in `gpu_render_volume` is 0,
  but the showcase uses 48).

**Is it a fair comparison to WebGL?**

No. The benchmark measures Lyr-HDDA vs Lyr-linear (both NanoVDB paths). It tells
us how much HDDA helps within Lyr. It says nothing about the gap between Lyr's
stochastic-delta-tracking pipeline and a WebGL fixed-step trilinear-texture shader.

A fair WebGL comparison benchmark would:
1. Use the same volume (same voxel count, same bounding box, same density range).
2. Run a fixed-step emission-absorption march (`render_volume_preview` is
   Lyr's closest equivalent: VolumeIntegrator.jl:473–531).
3. Use `spp=1` (WebGL renders 1 sample/pixel at 60 FPS).
4. Exclude NanoGrid upload time for Lyr (upload amortized over many frames in WebGL).
5. Report time-to-first-pixel, not wall time for the full render.

---

## 4. Low-Hanging Fruit (Changes That Would Close the Gap)

### 4.1 Default `spp` / `max_bounces` "Preview" Mode

`render_volume_image` (VolumeIntegrator.jl:550) defaults to `spp=1, max_bounces=1`.
The GPU path defaults to `max_bounces=0` (GPU.jl:1420). There is no documented
"preview" mode that communicates to users "this will be fast but noisy."

**Fix**: expose a `RenderQuality` enum or named keyword (`quality=:preview` →
`spp=1, max_bounces=0`; `quality=:production` → `spp=16, max_bounces=4`).
The `render_volume_preview` function (VolumeIntegrator.jl:473) already does
fixed-step EA and is the correct preview path — but it is not the default
called by `render_volume_image`.

### 4.2 Cache the Device-Side NanoGrid Across Calls

`Adapt.adapt(backend, nanogrid.buffer)` at GPU.jl:1476 uploads the full buffer
on every call. For a 1 MB NanoGrid and `spp=8`, that is 8 MB of H2D transfer
in the benchmark's loop. Caching a `GPUNanoGrid` and reusing it across `spp`
iterations and across multiple render calls would eliminate this transfer.
The `GPUNanoGrid` type (GPU.jl:76–79) already exists for exactly this purpose
but is not used in the main rendering path.

### 4.3 Fuse the `spp` Loop into the Kernel

Instead of launching `spp` separate kernels (GPU.jl:1490–1512) with a
`synchronize` between each, accumulate all samples inside a single kernel
invocation. This eliminates `2×spp` synchronize calls and `spp-1` kernel
launch overheads. Each thread would loop over `spp` samples internally, which
also improves register reuse.

### 4.4 Dense 3D Texture Fast-Path for Small Grids

For grids that fit within GPU texture memory limits (typically ≤2 GB, often
≤512³ for Float32 = 512 MB), upload as a `CuTexture` and use hardware trilinear
sampling. This would require a CUDA-specific code path (not expressible in
KernelAbstractions without CUDA.jl helpers), but would bring small/medium
volumes to within a constant factor of WebGL performance for the EA preview path.
This is the single highest-leverage change for closing the WebGL gap.

### 4.5 Half-Precision Data Path

NanoVDB stores Float32 values. Converting density grids to Float16 would halve
the buffer size, improving cache efficiency for the byte-level tree traversals.
The `header_T_size` parameter (GPU.jl:1471) already parameterizes the value size,
so the kernel can in principle handle Float16 without structural changes.

---

## 5. Fundamental Limits: What the Architecture Cannot Match WebGL Without Redesign

### 5.1 Hardware Texture Interpolation

The GLSL `sampler3D` + `texture()` path is simply not available through
KernelAbstractions. CUDA.jl exposes `CuTexture{T,3}` with hardware interpolation
when the underlying GPU has texture units, but this is CUDA-only and
KernelAbstractions does not abstract it. Any use of hardware trilinear would
require a CUDA-specific extension (similar to `LyrCUDAExt.jl`) and cannot be
the default portable path.

### 5.2 Algorithmic Difference: Stochastic vs Deterministic

Delta tracking is an unbiased Monte Carlo estimator. It converges to the correct
scattering solution as `spp → ∞` but is fundamentally noisier at low spp than
a fixed-step deterministic integrator. A WebGL renderer at `spp=1` looks clean
but is systematically biased (under-samples thin features, over-opaque at coarse
step size). Lyr's approach is physically correct; the WebGL approach is not.
These are *different products*, not better vs worse implementations of the same thing.

### 5.3 Sparse Representation Overhead for Dense Grids

HDDA is a win for sparse volumes (96% empty voxels). For a dense 128³ fog volume
(near-100% filled), HDDA has overhead but no skip benefit, and fixed-step marching
of a dense 3D texture would be faster. The NanoVDB sparse format imposes the tree
traversal cost unconditionally.

### 5.4 Warp Divergence in Delta Tracking

All threads within a CUDA warp execute the same instruction. With delta tracking,
neighboring pixels terminate at unpredictable depths (the free-flight distance is
stochastic). Threads scatter across the bounding box, causing different threads
to exit their loops at different times. The warp stalls until the last thread
finishes. In a fixed-step shader all threads advance by exactly Δt per step, with
zero warp divergence.

### 5.5 No Progressive Display

WebGL volume renderers display partial results frame-by-frame at interactive rates.
Lyr blocks the CPU until the full render is done, then transfers the full image.
There is no mechanism to show `spp=1` results at interactive rates while accumulating
more samples.

---

## 6. Prioritized Recommendation

| Priority | Change | Where | Effort | Expected Impact |
|----------|--------|--------|--------|-----------------|
| 1 | **Cache `GPUNanoGrid` device buffer across `spp` loop and across calls** | GPU.jl:1476, reshape `gpu_render_volume` to accept a cached `GPUNanoGrid` | 1 day | Eliminates `O(buffer_size × spp)` H2D transfer; critical for repeated renders |
| 2 | **Fuse `spp` loop into kernel** | GPU.jl:1490–1512; add inner `for s in 1:spp` inside `delta_tracking_hdda_kernel!` | 1–2 days | Eliminates `2×spp` synchronize+launch overheads; better register reuse |
| 3 | **Dense 3D texture fast-path via `CuTexture` in LyrCUDAExt** | ext/LyrCUDAExt.jl + new GPU fast path | 3–5 days | Hardware trilinear; closes the single biggest gap vs WebGL for EA-mode preview |
| 4 | **Expose a documented fast preview path** | VolumeIntegrator.jl:553; add `quality=:preview` that routes to `render_volume_preview` | Half day | Prevents users from inadvertently running full path tracer for previews |
| 5 | **Profile kernel register pressure with `ptxas`** | Inspect compiled PTX for `delta_tracking_hdda_kernel!` | 1 day | May reveal register spilling in the large HDDA kernel (many scalar locals); fix by splitting into smaller helpers |

---

## Appendix: Key Line References

| Topic | File | Lines |
|-------|------|-------|
| `_gpu_get_value` tree descent | GPU.jl | 185–289 |
| `_gpu_get_value_trilinear` (8 corners) | GPU.jl | 302–338 |
| `_gpu_get_value_trilinear_cached` (leaf cache) | GPU.jl | 778–825 |
| `_gpu_buf_count_on_before` (prefix-sum bit count) | GPU.jl | 141–157 |
| Linear delta-tracking kernel (per-pixel loop, up to 1024 steps) | GPU.jl | 603 |
| Shadow ray inner loop (up to 256 steps) | GPU.jl | 639 |
| HDDA delta-tracking kernel | GPU.jl | 1270–1342 |
| `spp` kernel launch loop + synchronize pairs | GPU.jl | 1490–1512 |
| NanoGrid buffer upload per call | GPU.jl | 1476 |
| Pixel buffer allocate + upload per call | GPU.jl | 1482–1486 |
| Device → host pixel download per call | GPU.jl | 1517 |
| `_estimate_density_range` (full leaf scan on CPU) | GPU.jl | 1372–1393 |
| CPU delta tracking (shows same algorithmic structure) | VolumeIntegrator.jl | 82–275 |
| Shadow ratio-tracking (CPU) | VolumeIntegrator.jl | 296–429 |
| Showcase: 32 spp × 48 bounces | volumetric_showcase.jl | 116 |
| Benchmark: CPU time is extrapolated, not measured | benchmark_gpu.jl | 115–120 |
| HDDA span-merging iterator | VolumeHDDA.jl | 60–210 |
