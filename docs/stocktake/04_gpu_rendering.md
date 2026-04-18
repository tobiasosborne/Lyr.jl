# GPU Rendering Pipeline — Architecture Stocktake

**Date**: 2026-04-18  
**Sources**: `src/GPU.jl` (1530 lines), `ext/LyrCUDAExt.jl` (36 lines), `src/ScalarQEDGPU.jl` (387 lines)  
**Reference**: `src/NanoVDB.jl` (buffer layout), `src/VolumeHDDA.jl` (CPU reference)

---

## 1. File Purposes

| File | Purpose |
|---|---|
| `src/GPU.jl` | All GPU rendering logic: backend Ref, device-side buffer primitives, delta-tracking kernels (linear + HDDA), leaf caching, trilinear interpolation, light packing, `gpu_render_volume` dispatch |
| `ext/LyrCUDAExt.jl` | Thin weakdep extension: sets `_GPU_BACKEND[] = CUDABackend()` in `__init__` when `CUDA.functional()`, adds `_gpu_info(::CUDABackend)` method |
| `src/ScalarQEDGPU.jl` | GPU-accelerated first-order Born scattering: KA wavepacket kernel, `GPUMomentumGrid`, `GPUFrameState` incremental accumulator, `ScalarQEDScatteringGPU` Field Protocol wrapper |

---

## 2. Public API

### Backend control
- `gpu_available() -> Bool` — `GPU.jl:49`: true iff `_GPU_BACKEND[]` is not `CPU()`.
- `gpu_info() -> String` — `GPU.jl:58`: dispatches to `_gpu_info(backend)`. CPU returns fixed string; CUDA extension (`LyrCUDAExt.jl:13`) queries `CUDA.device()`.
- `_GPU_BACKEND::Ref{Any}` — `GPU.jl:33`: initialized to `CPU()`; overwritten by `LyrCUDAExt.__init__` to `CUDABackend()`.

### Render entry point
```julia
gpu_render_volume(nanogrid, scene, width, height;
    spp=1, seed=UInt64(42),
    backend=_default_gpu_backend(),   # :auto semantics
    hdda=true,
    max_bounces=0) -> Matrix{NTuple{3,Float32}}
```
`GPU.jl:1415`. The `backend` argument defaults to `_default_gpu_backend()` which reads `_GPU_BACKEND[]`; no literal `:auto` symbol — auto-selection is implicit.

`gpu_render_multi_volume` (`GPU.jl:1540`) renders each volume independently with `gpu_render_volume` and composites additively (correct for non-overlapping volumes only).

### Scene/lights packing (GPU.jl:1446–1464)
Each `DirectionalLight` or `PointLight` is packed as **7 consecutive Float32s** in `light_data`:
```
[type(0=dir/1=pt), x, y, z, r, g, b]
```
`ConstantEnvironmentLight` is silently skipped. If no lights survive packing, a single default directional `(0.577, 0.577, 0.577)` white light is substituted. The packed host vector is adapted to the backend with `Adapt.adapt(backend, light_data)`.

The transfer function is pre-baked into a 256-entry RGBA LUT (`_bake_tf_lut`, `GPU.jl:1353`) and also adapted to device. The NanoGrid buffer itself is adapted via `Adapt.adapt(backend, nanogrid.buffer)`.

---

## 3. Architecture Diagram

```
HOST                              DEVICE (CuArray or CPU Array)
────────────────────────────────────────────────────────────────
NanoGrid{Float32}.buffer ──adapt──► dev_buf   (UInt8[])
tf_lut Vector{Float32}   ──adapt──► dev_tf    (Float32[])
light_data Float32[]     ──adapt──► dev_lights (Float32[])
fill(z3, W*H)            ──adapt──► output    (NTuple{3,F32}[])
fill(z3, W*H)            ──adapt──► acc_buf   (NTuple{3,F32}[])

Kernel dispatch:  ndrange = W*H  (one workitem = one pixel)

Per spp iteration:
  delta_tracking_hdda_kernel! → output[1..W*H]
  KernelAbstractions.synchronize(backend)
  _accumulate_kernel!          → acc_buf[i] += output[i]
  KernelAbstractions.synchronize(backend)

Final:  Array(acc_buf) → host; divide by spp; reshape to Matrix
```

**What lives where**: The raw NanoGrid byte buffer and all Float32 auxiliaries live entirely on device during rendering. Camera params, scalar material constants (sigma_maj, albedo, etc.), and geometry bounds are passed as kernel scalars (registers). The output and accumulation buffers are device arrays.

---

## 4. Kernel Anatomy

### `delta_tracking_kernel!` (GPU.jl:529) — naive linear traversal

One workitem = one pixel. Per pixel:
1. Wang-hash seed → xorshift RNG state (prevents pixel cross-correlation, `GPU.jl:561`).
2. Jittered sub-pixel sample → camera ray in index space.
3. **Outer bounce loop** (0..max_bounces):
   - Ray-AABB vs volume bbox (`_gpu_ray_box_intersect`). Miss → break.
   - **Inner delta-tracking loop** (max 1024 iterations):
     - Sample free-flight distance: `t += -log(xi)/sigma_maj`.
     - Evaluate trilinear density at sample point (`_gpu_get_value_trilinear`, 8 full tree traversals).
     - Acceptance test: `xi2 < density/sigma_maj`. On null collision: continue.
     - On real collision: determine scatter vs absorb via `xi3 < albedo`.
       - If scatter: for each light, offset shadow ray by `0.01*light_dir`, run ratio tracking (256 steps, `GPU.jl:639–652`), accumulate `tf_rgb * light_rgb * throughput * transmittance * HG_phase * emission_scale`.
     - Break inner loop on first real collision.
   - If no scatter occurred: break outer loop.
4. Multi-bounce: `throughput *= albedo`, sample new HG direction, offset ray origin by `1e-4`. Russian roulette after bounce 3 (`GPU.jl:675`).
5. Write clamped RGB to `output[idx]`.

**Key inefficiency**: uses `_gpu_get_value_trilinear` (8 full Root→I2→I1→Leaf traversals per trilinear sample) with no leaf caching and no empty-space skipping.

### `delta_tracking_hdda_kernel!` (GPU.jl:1270) — HDDA default

Same pixel setup and bounce/RR structure as above. The inner traversal is replaced entirely by `_gpu_hdda_delta_track(...)` (GPU.jl:1090), which:

1. **Phase 0**: `_gpu_collect_root_hits` scans root table, ray-AABBs all I2 nodes, insertion-sorts up to 4 hits into scalar slots (`t1..t4, o1..o4`). `GPU.jl:933`.
2. **I2 DDA** (stride 128, dim 32): Amanatides-Woo DDA over the 32³ I2 grid. For each I2 cell:
   - Check `I2_CMASK`: if child exists, descend to I1.
   - No child: check `I2_VMASK` for tile; open/close span accordingly.
3. **I1 DDA** (stride 8, dim 16) within each I1 node: checks `I1_CMASK | I1_VMASK`. Active cell → extend or open span. Inactive → close span and call `_gpu_integrate_span`.
4. **Span integration** (`_gpu_integrate_span`, GPU.jl:989): runs delta tracking only within `[t0, t1]` with leaf-cached trilinear lookup (up to 512 inner iterations). Returns updated `(acc_r/g/b, throughput, rng_state, terminated, scatter, hit_xyz, cache_ox/oy/oz/off)`.
5. Span boundary signals early exit if `terminated`.

The `span_t0 = -1.0f0` sentinel marks "no open span". Span merging across I1 boundaries is preserved: the span variable persists across I1 iterations within one I2 cell (`GPU.jl:1199`).

---

## 5. `_gpu_*` Helper Inventory

### Buffer loads / bit ops
| Helper | Line | Purpose |
|---|---|---|
| `_gpu_buf_load(::Type{T}, buf, pos)` | 101–129 | Scalar byte-shift loads for UInt8/UInt32/Int32/Float32/UInt64; GPU-safe (no `reinterpret(@view)`) |
| `_gpu_buf_mask_is_on(buf, mask_pos, bit_idx)` | 132 | Test one bit in a packed UInt64 mask word |
| `_gpu_buf_count_on_before(buf, mask_pos, prefix_pos, bit_idx)` | 141 | Count on-bits before `bit_idx` using stored prefix sums |

### Value lookup / trilinear
| Helper | Line | Purpose |
|---|---|---|
| `_gpu_coord_less(...)` | 168 | Lexicographic coord compare for binary search |
| `_gpu_get_value(buf, bg, cx,cy,cz, T_size)` | 185 | Stateless Root→I2→I1→Leaf traversal, returns Float32 |
| `_gpu_get_value_trilinear(buf, bg, fx,fy,fz, T_size)` | 302 | 8-corner trilinear interp, no cache |
| `_gpu_leaf_read(buf, leaf_off, cx,cy,cz, T_size)` | 694 | Direct voxel read from cached leaf offset |
| `_gpu_get_value_with_leaf(buf, bg, cx,cy,cz, T_size)` | 702 | Like `_gpu_get_value` but also returns `leaf_off` (0 if tile/bg) |
| `_gpu_get_value_cached(buf, bg, cx,cy,cz, T_size, cache...)` | 758 | Single-point lookup using leaf cache; updates and returns cache state |
| `_gpu_get_value_trilinear_cached(buf, bg, fx,fy,fz, T_size, cache...)` | 778 | Cached trilinear: same-leaf fast path (1 traversal + 8 direct reads) or per-corner cached fallback |

### HDDA DDA
| Helper | Line | Purpose |
|---|---|---|
| `_gpu_safe_floor_i32(x)` | 834 | Floor to Int32 with Inf/overflow guard |
| `_gpu_initial_tmax(origin_i, inv_dir_i, ijk_i, step_i, vs)` | 843 | Initial DDA tmax for one axis |
| `_gpu_dda_init(ox,oy,oz, dx,dy,dz, idx,idy,idz, tmin, vs)` | 854 | Amanatides-Woo DDA init; returns 12 scalars (ijk, step, tmax, tdelta) |
| `_gpu_dda_step(ijk..., step..., tmax..., tdelta...)` | 883 | Advance DDA by one cell; returns updated ijk and tmax |
| `_gpu_node_query(ijk..., orig..., child_size, dim)` | 904 | Bounds check + flat child index within a node |
| `_gpu_cell_time(tx, ty, tz)` | 918 | `min(tx,ty,tz)` — DDA cell exit time |
| `_gpu_root_get(slot, t1..t4, o1..o4)` | 923 | Access sorted root-hit slots by index (scalar unroll) |
| `_gpu_collect_root_hits(buf, ox,oy,oz, idx,idy,idz, T_size)` | 933 | Scan root table, ray-AABB all I2 nodes, return ≤4 sorted (tmin, i2_off) hits |

### Ray geometry
| Helper | Line | Purpose |
|---|---|---|
| `_gpu_ray_box_intersect(...)` | 344 | Slab-method ray-AABB, returns `(t_enter, t_exit)`, clamps to 0 |

### RNG
| Helper | Line | Purpose |
|---|---|---|
| `_gpu_xorshift(state)` | 372 | Xorshift32 step; returns `(Float32 in [0,1), new_state)` |
| `_gpu_wang_hash(key)` | 381 | Wang hash for seed decorrelation |

### HG phase / scatter
| Helper | Line | Purpose |
|---|---|---|
| `_gpu_hg_eval(g, cos_theta)` | 430 | Henyey-Greenstein phase function value; isotropic fallback for `|g|<1e-6` |
| `_gpu_hg_sample_cos_theta(g, xi)` | 438 | HG inverse-CDF sample |
| `_gpu_build_basis(wx,wy,wz)` | 447 | Gram-Schmidt ONB from direction |
| `_gpu_sample_scatter(dx,dy,dz, g, rng)` | 469 | Sample new direction from HG; returns `(new_dx,dy,dz, rng_state)` |

### Lighting
| Helper | Line | Purpose |
|---|---|---|
| `_gpu_read_light(light_buf, li)` | 489 | Unpack 7-float light record at index `li` |
| `_gpu_light_contribution(light_buf, li, pos...)` | 500 | Compute light dir + effective RGB at scatter point; directional=no falloff, point=1/r² |

### Transfer function
| Helper | Line | Purpose |
|---|---|---|
| `_gpu_tf_lookup(tf_lut, density, dmin, dmax)` | 395 | Normalize density and index into 256-entry pre-baked RGBA LUT |

### Accumulation
| Helper | Line | Purpose |
|---|---|---|
| `_accumulate_kernel!` | 416 | KA kernel: elementwise `acc[i] += src[i]` for NTuple{3} pixels |

### HDDA integration
| Helper | Line | Purpose |
|---|---|---|
| `_gpu_integrate_span(...)` | 989 | Delta tracking inside one `[t0,t1]` span with leaf-cached trilinear; returns full state tuple |
| `_gpu_hdda_delta_track(...)` | 1090 | Full HDDA traversal driving `_gpu_integrate_span`; returns `(acc_r,g,b, rng, scattered, hit_xyz)` |

---

## 6. Leaf Caching

The cache state is four `Int32` scalars threaded through return tuples (no mutable struct):

```
cache_ox, cache_oy, cache_oz :: Int32  — 8-aligned voxel origin of cached leaf
cache_off                    :: Int32  — byte offset of leaf in NanoGrid buffer (0 = invalid)
```

**Fast path** (`_gpu_get_value_trilinear_cached`, `GPU.jl:788`): if all 8 trilinear corners fall within one 8³ leaf (i.e. `x0&7 != 7 && y0&7 != 7 && z0&7 != 7`), one traversal finds the leaf, then 8 direct `_gpu_leaf_read` calls index into it without further tree descent. Cache origin is updated in place.

**Slow path**: when corners straddle a leaf boundary, 8 separate `_gpu_get_value_cached` calls each check the cache; only the misses do a full traversal.

**Threading**: `_gpu_integrate_span` receives `(cache_ox, cache_oy, cache_oz, cache_off)` as parameters and returns updated values in its 14-element return tuple (`GPU.jl:988`). `_gpu_hdda_delta_track` initialises cache to `Int32(0)` at ray start and threads it across consecutive span integrations (`GPU.jl:1107`), giving spatial coherence across the whole bounce path. Shadow rays use independent per-light caches, initialised fresh at each scatter event (`GPU.jl:1046`).

Reported hit rate: ~75% same-leaf for typical volume traversal.

---

## 7. Scalar-QED GPU

### What is implemented (`src/ScalarQEDGPU.jl`)
- **`wavepacket_kernel!`** (line 16): KA kernel evaluating Gaussian wavepackets on an N³ grid; one workitem per voxel. Reuses CPU `gaussian_wavepacket` function via scalar dispatch.
- **`GPUMomentumGrid`** (line 56): holds on-device 3D arrays (`k2, kx, ky, kz, E_k`, 1D `x_dev`) plus pre-planned FFTs (`FFTW.plan_fft` on CPU, or CUFFT when `CuArray` is the adapted type).
- **`GPUFrameState`** (line 123): mutable struct with on-device `S1_k, S2_k` Born accumulators; tracks `last_step` for incremental evaluation.
- **`accumulate_one_step!`** (line 144): recomputes one Born product step on GPU using broadcast ops + FFT; no `P_tilde` storage — eliminates O(N³ × nsteps) memory (the "107 GB problem").
- **`evaluate_frame_gpu`** (line 192): incremental accumulation to frame_idx, scattered wave construction, IFFT to position space, normalisation, electron density + EM cross-energy; returns CPU arrays.
- **`ScalarQEDScatteringGPU`** (line 274): Field Protocol constructor returning two `TimeEvolution{ScalarField3D}` fields (electron density, EM cross-energy) with CPU-side frame cache (`Dict{Int, Tuple{...}}`).

### What is not yet validated
- No benchmark comparison against the CPU `ScalarQEDScattering` path; numerical correctness unverified.
- FFT plan creation at `GPUMomentumGrid` construction time calls `plan_fft(plan_arr)` where `plan_arr` is a `ComplexF64` array on device — correct for CUFFT if `CUDA.jl` is loaded, but this is not tested.
- The `wavepacket_kernel!` calls `gaussian_wavepacket` (a CPU-defined function) inside a KA kernel; GPU compilation of this depends on the function being inlineable and not touching host memory — not explicitly verified.
- Per-frame `similar(state.S1_k)` allocations in `accumulate_one_step!` could thrash the GPU allocator at high step counts; no pooling.
- The frame cache (`frame_cache` Dict) lives on host — fine for serial access, but limits future parallelism.

---

## 8. Known Performance Traps and Applied Fixes

### Fixes applied (from fjo9 and prior work)

| Trap | Fix | Location |
|---|---|---|
| `reinterpret(@view)` not GPU-safe | Replaced with scalar byte-shift loads (`_gpu_buf_load`) | `GPU.jl:101–129` |
| Float32 absolute epsilons lost at large t (fjo9 bug) | DDA nudge is relative: `max(abs(tmin)*1e-5, 1e-5)` | `GPU.jl:861–862` |
| `@inline` on large kernels → register spilling | Kernels are `@kernel` (not `@inline`); only small helpers carry `@inline` | Throughout |
| `KA.zeros` incompatible with NTuple | `Adapt.adapt(backend, fill(z3, n))` | `GPU.jl:1483–1486` |
| Pixel-index RNG correlation (`idx+seed`) | Double Wang-hash: `_gpu_wang_hash(_gpu_wang_hash(UInt32(idx)) ⊻ seed)` | `GPU.jl:561` |
| Shadow rays starting inside medium | 0.01-unit offset along light direction | `GPU.jl:626–628, 1036–1038` |
| I2 root slot count | Capped at 4 (one root node covers 4096³ = virtually all practical grids) | `GPU.jl:941–944` |

### Remaining bottlenecks visible in source

1. **Linear kernel still exists** (`delta_tracking_kernel!`, used when `hdda=false`): 8 full Root→I2→I1→Leaf traversals per trilinear sample, no empty-space skipping. Only retained as fallback/reference; never used in production path.

2. **Shadow rays use naive linear tracking** even inside `_gpu_integrate_span` (lines 1048–1059): 256-step ratio tracking with cached trilinear but no HDDA. For thick volumes, shadow rays dominate cost. HDDA shadow rays would be a meaningful optimization.

3. **accept_prob redundancy in linear kernel**: `GPU.jl:615` computes `accept_prob = density * sigma_maj / sigma_maj` — simplifies to `density`. This is dead arithmetic (likely a leftover normalization from an earlier refactor); harmless but confusing.

4. **Root scan is O(root_count) linear** at each ray start (`_gpu_collect_root_hits`). With typical grids having 1–4 root entries this is negligible, but pathological grids with many I2 roots could be slow.

5. **Multi-volume compositing** (`gpu_render_multi_volume`) re-traverses each volume independently, then adds on the CPU. No inter-volume transmittance is tracked; shadowing between overlapping volumes is incorrect.

6. **ScalarQED per-step allocations**: `similar(state.S1_k)` called twice per step in `accumulate_one_step!` — allocation pressure at high N or step count is unaddressed.
