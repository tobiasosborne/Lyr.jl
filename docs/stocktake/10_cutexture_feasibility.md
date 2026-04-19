# CuTexture Hardware Trilinear — Feasibility for Lyr.jl GPU Render

**Bead**: path-tracer-9h77 (E1)  **Date**: 2026-04-19
**Scope**: Research-only. Determine go/no-go on using CUDA.jl's `CuTexture{T,3}` for hardware trilinear sampling in Lyr's GPU volume renderer. No code changes in this document.
**Sources**: CUDA.jl master (commit as of 2026-04-19), NVIDIA CUDA C++ Programming Guide, deviceQuery output for RTX 3090, local reading of `/home/tobiasosborne/Projects/Lyr.jl/src/GPU.jl` and `/home/tobiasosborne/Projects/Lyr.jl/ext/LyrCUDAExt.jl`.

---

## Recommendation

**CONDITIONAL-GO.** CUDA.jl's `CuTexture{Float32,3}` with `LinearInterpolation()` provides hardware trilinear filtering, is fully passable into a KernelAbstractions `@kernel` on `CUDABackend` (the adapt pipeline is wired — see §2), and the RTX 3090 supports 3D textures up to 16384 per dimension (practically limited by GPU RAM, not by the texture unit). The fast path is therefore viable as a CUDA-only extension inside `ext/LyrCUDAExt.jl`.

The **condition** is scope: the CuTexture path is only usable when the volume is *dense* (has been copied into a `CuArray{Float32,3}` or `CuTextureArray{Float32,3}`). Truly sparse NanoVDB grids (smoke.vdb is 6.5 MB sparse → ~2048³ dense would be 32 GB at Float32; bunny_cloud is 138 MB sparse → unknown dense size, likely 10s of GB) cannot be densified without either tile-based streaming or exceeding the RTX 3090's 24 GB. So the plan is: add a CuTexture fast-path for volumes up to ~512³ Float32 (~512 MB), fall back to the existing NanoVDB software traversal for anything larger. The fast-path should be selected automatically by volume size with a user override flag.

Estimated effort: **3–5 engineering days** for the minimum viable implementation (dense upload helper + CUDA-specific kernel variant + fallback logic + tests + one benchmark demo). Expected speedup, extrapolating the measured ~100-byte-read-per-sample software cost vs. a single hardware fetch, is 10–30× on the density-sampling component; wall-time speedup will depend on how much of the kernel's 917–2626 ms is sampling vs. shading/DDA, which should be profiled as part of the work.

---

## 1. CUDA.jl API surface (current as of CUDA.jl master, 2026-04-19)

All citations below are verbatim from the master branch of `JuliaGPU/CUDA.jl`. The texture API lives in:

- Host-side: `CUDACore/src/texture.jl`
- Device-side: `CUDACore/src/device/texture.jl`

### 1.1 Filter modes (host type hierarchy)

From `CUDACore/src/device/texture.jl`:

```julia
abstract type TextureInterpolationMode end
struct NearestNeighbour      <: TextureInterpolationMode end
struct LinearInterpolation   <: TextureInterpolationMode end
struct CubicInterpolation    <: TextureInterpolationMode end
```

These are exported via `@public NearestNeighbour, LinearInterpolation, CubicInterpolation`. `LinearInterpolation()` is the one we want — it maps to `CU_TR_FILTER_MODE_LINEAR` (confirmed at `CUDACore/src/texture.jl`, `Base.convert(::Type{CUfilter_mode}, ::LinearInterpolation) = CU_TR_FILTER_MODE_LINEAR`). In 3D it is trilinear, done in the texture unit in hardware.

`CubicInterpolation()` is also `CU_TR_FILTER_MODE_LINEAR` at the hardware level; the cubic is a software overlay on top of eight hardware linear fetches (GPU Gems 2 Ch. 20 reference in the source). It's 1D/2D-only — the constructor explicitly throws for N>2 — so it's irrelevant to volume rendering anyway.

### 1.2 Address modes

From `CUDACore/src/texture.jl`, line ~176:

```julia
@enum_without_prefix visibility=:public CUaddress_mode CU_TR_
```

This exports the four CUDA address modes: `ADDRESS_MODE_WRAP`, `ADDRESS_MODE_CLAMP`, `ADDRESS_MODE_MIRROR`, `ADDRESS_MODE_BORDER`. `ADDRESS_MODE_CLAMP` is the default (see constructor below) and is what Lyr wants for both fog volumes (clamp density to the background value at the boundary) and level sets (clamp SDF to a large positive value just past the bbox — we will need to pad a border before upload; see §5).

### 1.3 CuTextureArray constructor

```julia
mutable struct CuTextureArray{T,N}
    mem::ArrayMemory{T}
    dims::Dims{N}
    ctx::CuContext
end

CuTextureArray{T,N}(::UndefInitializer, dims::Dims{N})
CuTextureArray{T,N}(xs::AbstractArray{<:Any,N})  # host Array
CuTextureArray{T,N}(xs::CuArray{<:Any,N})        # device CuArray
CuTextureArray(A::AbstractArray{T,N}) = CuTextureArray{T,N}(A)
```

Marked "Experimental API. Subject to change without deprecation." in the docstring, but the API has been stable in its essentials since CUDA.jl 2.1 (2020-10-30 blog post announcing it). The underlying allocation type is `ArrayMemory{T}`, which is CUDA's special texture-optimized layout; **this is not the same as `DeviceMemory` used by `CuArray`**.

There are explicit `Base.copyto!` methods for 1D, 2D, and 3D:

```julia
Base.copyto!(dst::CuTextureArray{T,3}, src::Array{T,3}) where {T}
Base.copyto!(dst::CuTextureArray{T,3}, src::CuArray{T,3,M}) where {T, M}
Base.copyto!(dst::CuTextureArray{T,3}, src::CuTextureArray{T,3}) where {T}
```

So 3D support is fully present.

### 1.4 CuTexture constructor (the one we actually call)

From `CUDACore/src/texture.jl`:

```julia
mutable struct CuTexture{T,N,P} <: AbstractArray{T,N}
    parent::P
    handle::CUtexObject
    interpolation::TextureInterpolationMode
    normalized_coordinates::Bool
    ctx::CuContext
end

function CuTexture{T,N,P}(parent::P;
                          address_mode::Union{CUaddress_mode,NTuple{N,CUaddress_mode}}=ADDRESS_MODE_CLAMP,
                          interpolation::TextureInterpolationMode=NearestNeighbour(),
                          normalized_coordinates::Bool=false) where {T,N,P}
    ...
end

CuTexture(x::CuTextureArray{T,N}; kwargs...) where {T,N}
CuTexture(x::CuArray{T,N}; kwargs...) where {T,N}
```

Three keyword arguments:

- `address_mode`: scalar `CUaddress_mode` (applied to all dims) or `NTuple{N,CUaddress_mode}`. Default `ADDRESS_MODE_CLAMP`.
- `interpolation`: `NearestNeighbour()` (default) / `LinearInterpolation()` / `CubicInterpolation()`.
- `normalized_coordinates`: `Bool`, default `false`.

`CuArray` can be wrapped directly **only for 1D or 2D** — the source explicitly enforces this:

```julia
function CUDA_RESOURCE_DESC(arr::CuArray{T,N}) where {T,N}
    1 <= N <= 2 || throw(ArgumentError("Only 1 or 2D CuArray objects can be wrapped in a texture"))
    ...
end
```

So **for 3D, we MUST go through `CuTextureArray{T,3}`** — not a raw `CuArray{T,3}`. This is the critical host-side idiom.

### 1.5 Device-side type and fetch (what the kernel actually touches)

From `CUDACore/src/device/texture.jl`:

```julia
struct CuDeviceTexture{T,N,M<:TextureMemorySource,NC,I<:TextureInterpolationMode} <: AbstractArray{T,N}
    dims::Dims{N}
    handle::CUtexObject
end

# The indexing path used in a kernel
@inline function Base.getindex(t::CuDeviceTexture{T,N,<:Any,false,I}, idx::Vararg{Float32,N}) where
                              {T,N,I<:Union{NearestNeighbour,LinearInterpolation}}
    # non-normalized coordinates should be adjusted for 1-based indexing
    vals = tex(t, ntuple(i->idx[i]-0.5, N)...)
    return unpack(T, vals)
end
```

With `normalized_coordinates=false`, `tex[fx, fy, fz]` with three `Float32`s subtracts 0.5 from each coordinate and calls the NVVM intrinsic `llvm.nvvm.tex.unified.3d.v4f32.f32`, which returns four Float32s (RGBA); `unpack` extracts the first element for single-channel textures.

**This means `tex[fx, fy, fz]` with 1-based float voxel indices is the one-line drop-in replacement for Lyr's 100-byte-read software trilinear.** The -0.5 adjustment is applied for us; from the caller's perspective, `tex[1.0f0, 1.0f0, 1.0f0]` samples the center of voxel (1,1,1).

### 1.6 Adapt dispatch (what bridges host → device)

Critical wiring (`CUDACore/src/texture.jl`, last line of the file):

```julia
Adapt.adapt_storage(::KernelAdaptor, t::CuTexture{T,N}) where {T,N} =
    CuDeviceTexture{T,N,typeof(memory_source(parent(t))),
                    t.normalized_coordinates, typeof(t.interpolation)}(size(t), t.handle)
```

So whenever a `CuTexture` is passed through `cudaconvert` (which is what `@cuda` and `KA.argconvert` both call), it becomes a `CuDeviceTexture` automatically. This is the exact same dispatch path used for `CuArray → CuDeviceArray`, and it is the reason §2 is not a problem.

---

## 2. KernelAbstractions.jl compatibility

**Yes — CuTexture can be passed as an argument to a `@kernel` function running on `CUDABackend`.** No workaround needed. The reasoning:

### 2.1 The argconvert bridge

In `CUDACore/src/CUDAKernels.jl` (the file KernelAbstractions's backend extension defines for `CUDABackend`):

```julia
KA.argconvert(k::KA.Kernel{CUDABackend}, arg) = cudaconvert(arg)
```

`cudaconvert(arg)` internally calls `adapt(KernelAdaptor(), arg)`, and from §1.6 we already have:

```julia
Adapt.adapt_storage(::KernelAdaptor, t::CuTexture{T,N}) where {T,N} = CuDeviceTexture{...}(...)
```

So when KA launches a kernel on `CUDABackend()` with a `CuTexture` argument, it is automatically converted to a `CuDeviceTexture` before reaching the kernel body. This is the same mechanism by which a `CuArray` becomes a `CuDeviceArray` — no special-casing required.

### 2.2 Absence of contradicting issues

I searched `github.com/JuliaGPU/KernelAbstractions.jl/issues?q=texture`: **zero issues** match "texture". If passing CuTexture through `@kernel` were broken, it would almost certainly have surfaced as a bug report by now (the feature is 5+ years old).

### 2.3 One precedent that looks like a counterexample but isn't

`SciML/DiffEqGPU.jl` issue #224 ("EnsembleGPUKernel + Texture Memory Support") reports an `InvalidIR` error when using CuTexture inside `EnsembleGPUKernel`. Reading the thread carefully: the failure is specific to `EnsembleGPUKernel`'s per-trajectory kernel-generation pattern (it synthesizes a kernel per ODE problem, which interacts badly with type inference on the texture handle). It is not a general KA incompatibility. Lyr's use case — a fixed, statically typed `@kernel` that takes a `CuDeviceTexture{Float32,3,ArrayMemorySource,false,LinearInterpolation}` argument — is the straightforward case that works.

### 2.4 Porting recommendation

Because the CuTexture path is **CUDA-only**, the cleanest integration is:

- Keep `delta_tracking_hdda_kernel!` in `src/GPU.jl` as the portable fallback (NanoVDB software path, works on any KA backend).
- Add a **CUDA-specific** kernel `delta_tracking_hdda_texture_kernel!` in `ext/LyrCUDAExt.jl`, which takes a `CuTexture{Float32,3}` argument in place of the `buf::CuDeviceArray{UInt8}` argument.
- A user-facing dispatch function picks the fast-path when (a) the backend is `CUDABackend` and (b) the volume is below the size ceiling (see §3).

An alternative — generic KA kernel with `@sample(::AbstractBackend, ...)` hook — is *not* worth it. Only CUDA has hardware 3D texture fetch; AMDGPU's equivalent (through ROCm) has different APIs, and Metal/oneAPI don't expose anything equivalent through the KA abstractions today. Writing an abstraction that only CUDA fills is over-engineering.

---

## 3. Dense-backing constraint and memory ceiling

### 3.1 The constraint

`CuTexture{T,3,P}` requires `P <: CuTextureArray{T,3}` (per §1.4; the `CuArray` wrapper path is guarded to 1D and 2D only). A `CuTextureArray{Float32,3}` of dimensions `(nx, ny, nz)` allocates `nx * ny * nz * 4` bytes in texture-optimized layout. **This is dense** — there is no sparse-texture support in CUDA that we can exploit from Julia today.

So to use CuTexture, we must densify the NanoVDB grid into a `CuArray{Float32,3}` and then `copyto!` into a `CuTextureArray{Float32,3}`. The densification can happen on the CPU (iterate the grid, write to a dense `Array{Float32,3}`, upload) or on the GPU (allocate dense `CuArray`, run a KA kernel that calls `_gpu_get_value` on each voxel). The latter is faster for large grids; the former is simpler.

### 3.2 Memory table

| Grid dim | Float32 dense bytes | Notes |
|---|---|---|
| 64³       | 1 MB       | Trivially fits. |
| 128³      | 8 MB       | Trivially fits. |
| 256³      | 64 MB      | Trivially fits; comfortable interactive size. |
| 512³      | 512 MB     | Fits easily on 24 GB RTX 3090. Recommended ceiling. |
| 1024³     | 4 GB       | Fits but occupies 17% of VRAM; probably OK alone, not OK with other large buffers. Soft ceiling. |
| 2048³     | 32 GB      | **Exceeds RTX 3090's 24 GB.** No-go for dense. |
| 4096³     | 256 GB     | No-go. |

Note that CUDA's `CuTextureArray` is **not** a drop-in substitute for `CuArray` in terms of memory — it uses a special opaque layout ("CUDA array") managed by the driver. The actual footprint is close to nominal (`nx*ny*nz*sizeof(T)`) but there may be padding for alignment. We should measure once with `CUDA.memory_status()` rather than trust the nominal number to the byte.

### 3.3 Comparison to NanoVDB sparse buffers (from benchmark baseline)

| Volume           | NanoVDB size | Equivalent dense bbox | Dense Float32 size |
|------------------|--------------|-----------------------|---------------------|
| smoke.vdb        | 6.5 MB       | ~300³ (estimate)      | ~100 MB             |
| bunny_cloud.vdb  | 138 MB       | unknown, likely 500³–800³ | 500 MB – 2 GB    |
| level_set_sphere | synthetic    | ~128³                 | 8 MB                |

The interesting observation: **smoke.vdb (300³-ish, 100 MB dense) and level_set_sphere (128³, 8 MB dense) are in the sweet spot**. Those are exactly the scenes where the current GPU path is slow (917 ms and 2626 ms respectively) — so the CuTexture path lights up the workloads that currently perform worst. bunny_cloud at ~138 MB NanoVDB is borderline; if the dense bbox is 512³ (~512 MB), it still fits. If it's 1024³, we hit the soft ceiling.

### 3.4 Practical ceiling

Recommendation: **soft-cap the CuTexture path at 512³ (~512 MB)** and fall back to NanoVDB for anything larger. Leave 1024³ as an opt-in with `force_texture=true` if the user knows they have headroom. The automatic heuristic is:

```julia
dense_bytes = prod(bbox_dims) * sizeof(Float32)
use_texture = (dense_bytes ≤ 512 * 1024 * 1024) && gpu_has_enough_free_memory(dense_bytes * 2)
```

The factor of 2 accounts for the transient `CuArray` used during upload (before copyto! into `CuTextureArray`) — we hold both for a moment.

---

## 4. Hardware size limits (NVIDIA 3D textures)

### 4.1 The authoritative numbers

NVIDIA CUDA C++ Programming Guide, "Technical Specifications per Compute Capability" (the section formerly known as §F.1, currently in §20). The per-dimension limit for 3D textures depends on compute capability:

| Compute capability | 3D texture max per dim (w × h × d) | Example GPUs |
|---|---|---|
| 1.0 – 1.3          | 2048 × 2048 × 2048   | G80/G92 era        |
| 2.0 – 3.x          | 2048 × 2048 × 2048 (early) → 4096 × 4096 × 4096 | Fermi, Kepler |
| 5.0 – 5.x          | 4096 × 4096 × 4096   | Maxwell            |
| 6.0+               | 16384 × 16384 × 16384 | Pascal, Volta, Turing, Ampere, Hopper |
| 8.6 (RTX 3090)     | 16384 × 16384 × 16384 | Confirmed by deviceQuery output |

RTX 3090 is compute capability 8.6. Per multiple published deviceQuery outputs (search results cite: "Maximum 3D texture size: 1D=(131072), 2D=(131072, 65536), 3D=(16384, 16384, 16384)"), the per-dimension max is 16384. That is nominal — we will never get close to it because 16384³ × 4 bytes = 17.6 TB, which is four orders of magnitude larger than GPU RAM. **The practical ceiling is set by RAM (§3), not the texture unit.**

### 4.2 Caveat about "elements" vs "bytes"

The per-dim limit is in *elements*, not bytes. That means for a 4-channel RGBA Float32 texture you still get the same 16384³ nominal limit, just with 4× the storage cost. Since we're using single-channel Float32, this doesn't bite us.

### 4.3 What about `maxMipmapLevelClamp` etc.?

The `CuTexture` constructor initializes mipmap fields to zero (see `CUDA_TEXTURE_DESC(...)` in `CUDACore/src/texture.jl`) — we are *not* using mipmapped textures. Good; mipmapping adds a 1.33× storage cost and doesn't help volume rendering (we already have the LoD we want; we do not re-sample at varying scales per ray).

---

## 5. Filter / address mode choices for Lyr's use case

### 5.1 Filter: `LinearInterpolation()`

This is the whole point. Hardware trilinear.

### 5.2 Address mode: what to use

Lyr's volume types:

1. **Fog volume (density grid)**: background density = 0.0f0. Outside the grid, we want "no medium." `ADDRESS_MODE_CLAMP` clamps to the nearest boundary voxel — which is the wrong behavior if the boundary voxel is dense. `ADDRESS_MODE_BORDER` samples a border color (initialized to 0 for us, per `ntuple(_->Cfloat(zero(eltype(T))), 4)` in the constructor) — this is exactly what we want for fog.
2. **Level set (SDF grid)**: background value = large positive (outside). `ADDRESS_MODE_CLAMP` is OK *if* we pad the dense buffer with a ring of "definitely outside" voxels before upload, so the clamp-to-boundary semantic gives correct SDF sign. `ADDRESS_MODE_BORDER` would need the border color set to a large positive number, and CUDA.jl currently hardcodes the border color to `zero(eltype(T))` — which for SDF would mean "surface", not "outside". So for level sets, **clamp + explicit padding** is the right choice.

**Recommendation**: Use `ADDRESS_MODE_CLAMP` as the default and add a 1-voxel ring of background-value padding on upload for level sets. For fog volumes specifically, consider switching to `ADDRESS_MODE_BORDER` once we can patch the border color (this would require a small PR to CUDA.jl, or wrapping `cuTexObjectCreate` directly — not worth it for v1).

### 5.3 Normalized vs non-normalized

Use `normalized_coordinates=false`. That way, inside the kernel we pass voxel-index floats directly: `tex[fx, fy, fz]` where `fx ∈ [0.5, nx+0.5)` gives the correct trilinear between voxel centers. Julia handles the -0.5 adjustment for us (§1.5). Normalized coordinates would force us to divide by `(nx, ny, nz)` at every sample, which is extra shader ALU for zero benefit on CUDA hardware.

### 5.4 Integer flags we don't need

`CU_TRSF_READ_AS_INTEGER` is set automatically if `eltype(T) <: Integer`; since we're Float32, it's off. `CU_TRSF_SRGB` (sRGB decode) is not exposed by CUDA.jl's constructor — irrelevant for physics density data.

---

## 6. Minimum working code sketch (current CUDA.jl API)

Pseudocode. Actual names are exact per the master source.

```julia
# ========== HOST SIDE (in ext/LyrCUDAExt.jl) ==========
using CUDA
using CUDA: CuTexture, CuTextureArray, LinearInterpolation, ADDRESS_MODE_CLAMP

"""
    _build_dense_texture(nanogrid, bbox) -> CuTexture{Float32, 3}

Densify a NanoGrid into a CuTextureArray and return a CuTexture bound to it.
Caller is responsible for lifetime: hold onto this across spp iterations and
across multiple render calls. The underlying CuTextureArray is a finalizer-
managed mutable; keep a Julia reference alive.
"""
function _build_dense_texture(nanogrid::NanoGrid{Float32}, bbox::BBox)
    # 1. Determine dense dims (bbox is in index space).
    nx = Int(bbox.max.x - bbox.min.x + 1)
    ny = Int(bbox.max.y - bbox.min.y + 1)
    nz = Int(bbox.max.z - bbox.min.z + 1)

    dense_bytes = nx * ny * nz * sizeof(Float32)
    dense_bytes ≤ 512 * 1024 * 1024 || error(
        "dense volume would be $(dense_bytes ÷ 1024 ÷ 1024) MB; exceeds 512 MB CuTexture ceiling")

    # 2. Allocate device CuArray and fill it with voxel values.
    #    Option A (simple): fill on CPU, upload.
    #    Option B (fast for large grids): run a KA kernel that calls
    #      the existing _gpu_get_value on every voxel of the dense grid.
    # We sketch Option B below.
    dev = CuArray{Float32, 3}(undef, nx, ny, nz)

    fill_kernel = _dense_fill_kernel!(CUDABackend())
    fill_kernel(dev, nanogrid.buffer, bbox.min.x, bbox.min.y, bbox.min.z,
                nanogrid.background; ndrange=(nx, ny, nz))
    KernelAbstractions.synchronize(CUDABackend())

    # 3. Copy into a CuTextureArray (texture-optimized layout).
    tex_arr = CuTextureArray{Float32, 3}(dev)      # calls copyto!(undef, dev)
    CUDA.unsafe_free!(dev)                          # release the CuArray; CuTextureArray owns the data now

    # 4. Wrap in a CuTexture with hardware trilinear.
    tex = CuTexture(tex_arr;
                    address_mode = ADDRESS_MODE_CLAMP,
                    interpolation = LinearInterpolation(),
                    normalized_coordinates = false)
    return tex, tex_arr   # return both so caller can keep tex_arr alive
end

@kernel function _dense_fill_kernel!(dense, buf, ox::Int32, oy::Int32, oz::Int32, bg::Float32)
    i, j, k = @index(Global, NTuple)
    cx = ox + Int32(i) - Int32(1)
    cy = oy + Int32(j) - Int32(1)
    cz = oz + Int32(k) - Int32(1)
    # Reuse Lyr's existing _gpu_get_value traversal. One time cost at upload.
    @inbounds dense[i, j, k] = Lyr._gpu_get_value(buf, bg, cx, cy, cz, Int32(sizeof(Float32)))
end

# ========== DEVICE SIDE (the rendering kernel) ==========
@kernel function delta_tracking_hdda_texture_kernel!(
    output, tex::CUDA.CuDeviceTexture{Float32, 3}, tf_lut, light_buf,
    width::Int32, height::Int32, cam_px::Float32, cam_py::Float32, cam_pz::Float32, ...,
    bbox_ox::Int32, bbox_oy::Int32, bbox_oz::Int32, ...)

    idx = @index(Global, Linear)
    # ... (same pixel setup / ray construction as current kernel) ...

    # The ONE-LINE replacement for _gpu_get_value_trilinear_cached:
    # instead of 8 corner fetches through NanoVDB, one hardware fetch.
    # Coordinates are in voxel-index space, rebased to the dense buffer origin.
    @inline function sample_density(fx::Float32, fy::Float32, fz::Float32)
        # shift world voxel-space coord into dense-buffer coord (1-based, center-aligned)
        lx = fx - Float32(bbox_ox) + 1.0f0
        ly = fy - Float32(bbox_oy) + 1.0f0
        lz = fz - Float32(bbox_oz) + 1.0f0
        return @inbounds tex[lx, ly, lz]   # hardware trilinear
    end

    # ... rest of delta tracking / HDDA / shading identical to existing kernel,
    #     just replacing every _gpu_get_value_trilinear_cached call with sample_density ...
end
```

Key API details verified against the source:

- `CuTextureArray{Float32, 3}(dev::CuArray{Float32, 3})` — constructor exists (`CUDACore/src/texture.jl`, line ~93).
- `CuTexture(tex_arr; address_mode=..., interpolation=..., normalized_coordinates=...)` — exact kwarg names (`CUDACore/src/texture.jl`, line ~196).
- `tex[fx, fy, fz]` with `fx,fy,fz::Float32` — device-side `getindex` exists (`CUDACore/src/device/texture.jl`, line ~79), auto-subtracts 0.5.
- CUDA's address-mode symbol `ADDRESS_MODE_CLAMP` is exported via `@enum_without_prefix` — no `CUDA.` qualifier needed if we `using CUDA`.

**Things to double-check at implementation time** (not confirmed, could differ):

- Whether the `_dense_fill_kernel!` pattern compiles cleanly when called from a package extension (KA + Lyr + CUDA). Should work per §2 but worth a single smoke test before building on it.
- Lifetime of `CuTextureArray`: the finalizer calls `free(mem)` in `unsafe_destroy!`. We must ensure the `CuTextureArray` Julia object is held by a reference (e.g., stashed in a `GPUNanoGrid`-like struct) for the duration of every render call that uses the corresponding `CuTexture`. Dropping the `CuTextureArray` invalidates the texture handle.
- Whether we need `CUDA.synchronize()` between `copyto!` and `CuTexture` construction. The source uses `unsafe_copy3d!` which is a CUDA driver API call; it is typically asynchronous on the default stream. Safer to `CUDA.synchronize()` once before returning.

---

## 7. Existing Julia ecosystem precedent

### 7.1 Direct precedents found

- **`cdsousa/CuTextures.jl`** (archived, deprecated 2020-10-30). Original implementation; folded into CUDA.jl. The README's worked 2D example is the pattern `tex[idx...]` that CUDA.jl inherited.
- **CUDA.jl 2.1 release blog** (`juliagpu.org/post/2020-10-30-cuda_2.1/`) — announces the texture API with the example `gpu_tex = CuTexture(gpu_src; interpolation=CUDA.NearestNeighbour())` and `broadcast!(...)`. Only 2D shown; no 3D example.
- No obvious Julia package that currently uses `CuTexture{Float32, 3}` for volume rendering. MedEye3d.jl does medical volume viz but is OpenGL-based, not CUDA.
- `SciML/DiffEqGPU.jl` issue #224 is the one published case of someone trying to use CuTexture from a KA-adjacent framework; as discussed in §2.3 the failure was specific to EnsembleGPUKernel's kernel-generation pattern.

### 7.2 Indirect precedents (pattern confirmation)

- `DannyRuijters/CubicInterpolationCUDA` (the GPU Gems 2 Chapter 20 reference implementation) — demonstrates the 3D texture + linear fetch + cubic overlay pattern in raw CUDA. Not Julia, but the CUDA.jl cubic implementation in `CUDACore/src/device/texture.jl` ports from this.
- The generic *expectation* that CUDA.jl 3D textures "work" is consistent with their existence in the API surface, their documented 1D/2D use, and the absence of open issues against 3D usage.

### 7.3 What this means for Lyr

Lyr would likely be among the first published Julia applications to drive CUDA.jl's 3D texture path in production. That is not a red flag — the API is well-formed, well-adapted to KA, and has a clear hardware basis — but it does mean we should build in defensive code (fallback to NanoVDB on any upload or sample failure; assertion checks on the densified grid; a test that compares texture-sampled density to NanoVDB-sampled density at a grid of points within tolerance).

---

## 8. Integration plan + effort estimate

### 8.1 Where code lives

- **`ext/LyrCUDAExt.jl`**: gains `_build_dense_texture`, `delta_tracking_hdda_texture_kernel!`, and a dispatch shim `gpu_render_volume(::CUDABackend, nanogrid, scene, w, h; use_texture=true, ...)`. All CUDA-specific code stays here.
- **`src/GPU.jl`**: unchanged for the fallback path. Expose any helpers needed (e.g., `_gpu_get_value` must remain non-private enough that the extension can call it from its upload kernel; add an `@inline` wrapper function documented as "stable device-side API for extensions").
- **Tests**: new file `test/test_cuda_texture.jl`, gated on `CUDA.functional()`. Tests should verify (a) texture round-trip (upload a known `Array{Float32,3}`, sample at voxel centers, check equality); (b) trilinear semantics at half-voxel points matches `Lyr._trilinear_cpu` within 1e-6; (c) the full `gpu_render_volume` with `use_texture=true` produces an image whose PSNR against the NanoVDB-path image is ≥ 40 dB on a sample scene.
- **Benchmark**: update `examples/benchmark_gpu.jl` to add a third row for the texture path (same scenes: smoke, bunny_cloud, level_set_sphere). Expected outputs: smoke.vdb 917 ms → 50–100 ms; level_set_sphere 2626 ms → 100–200 ms. bunny_cloud may fall to fallback path due to size.

### 8.2 User-facing API

Two options. I recommend option B:

- **Option A**: new entry point `gpu_render_volume_texture(nano, scene, w, h; ...)`. Explicit but duplicates surface.
- **Option B (recommended)**: add a keyword to existing `gpu_render_volume`:
  ```julia
  gpu_render_volume(nanogrid, scene, width, height;
      spp=1, seed=UInt64(42), backend=_default_gpu_backend(),
      hdda=true, max_bounces=0,
      use_texture=:auto)          # :auto, true, false
  ```
  - `:auto` — pick texture path when backend==CUDA, dense_bytes ≤ 512 MB, and `use_texture_default[]` is true.
  - `true` — force texture, error if backend ≠ CUDA or size too big.
  - `false` — force NanoVDB path (current behavior).

The `:auto` default is the right way to ship this: for users who don't care, small scenes just get faster. For users who need reproducibility against the NanoVDB path (e.g., CPU-GPU cross-validation), `use_texture=false` is explicit.

### 8.3 Fallback conditions (explicit)

Fall back to NanoVDB path when:

1. `backend != CUDABackend()` (KA-portable path only).
2. `dense_bytes > 512 MB` (configurable via `ENV["LYR_TEXTURE_CEILING_MB"]`).
3. `CUDA.available_memory() < 2 * dense_bytes` (not enough headroom for upload transient).
4. Volume value type is not `Float32` (CUDA textures don't support Float64; see discourse thread `discourse.julialang.org/t/63346`).
5. User explicitly sets `use_texture=false`.

Emit a single `@info` (not `@warn`) when falling back from `:auto`, telling the user why and how to force the choice.

### 8.4 Effort estimate

- **Day 1**: `_build_dense_texture` + `_dense_fill_kernel!` in extension. Tests for upload + sample round-trip. Verify KA passes `CuTexture` through `@kernel` (single smoke test — I expect this just works per §2 but it's the first risky step).
- **Day 2**: Port `delta_tracking_hdda_kernel!` to `delta_tracking_hdda_texture_kernel!`. Most of the code is copy-paste; the only substantive change is replacing every call site of `_gpu_get_value_trilinear_cached` and `_gpu_get_value_cached` with `sample_density`. The leaf cache machinery (`cache_ox/oy/oz/off`) disappears — hardware texture cache replaces it. This actually *simplifies* the kernel (~80 LOC removed).
- **Day 3**: Dispatch layer in `gpu_render_volume`, fallback heuristics, `:auto`/`true`/`false` logic. Lifetime management for `CuTextureArray` (likely a new `DenseGPUGrid` struct that holds both the `CuTextureArray` and `CuTexture`).
- **Day 4**: Benchmarks, regression tests against NanoVDB golden, doc updates (`docs/api_reference.md` + new section in `04_gpu_rendering.md`).
- **Day 5**: Buffer for surprises. Almost guaranteed to be needed.

**Total: 3–5 days for a junior-safe plan; realistically 3 days for someone who has already internalized the GPU.jl kernel.**

### 8.5 What this does NOT address

- Multi-volume compositing (`gpu_render_multi_volume`): each volume would need its own texture; still OK but the per-call overhead grows linearly with volume count. Low priority.
- Shadow-ray HDDA replacement: shadow rays (256 steps per light per scatter) would also benefit from texture sampling. Apply the same substitution. In fact, the biggest wall-time gain may be on shadow rays, since they're the dominant cost for thick fog volumes with `max_bounces>0`.
- Russian roulette, path tracer convergence, sigma_maj estimation — all orthogonal; unchanged.
- NanoVDB sparse → dense streaming for truly huge volumes (>512 MB) — this is the next project if the texture path succeeds and users hit the ceiling.

---

## 9. Open questions / known unknowns

- **Lifetime semantics of `CuTextureArray`**: I stated "keep a reference alive" but did not verify the exact failure mode when the finalizer fires. Worth a `@test_throws` experiment: drop all refs, `GC.gc()`, then try to sample — does it throw, return garbage, or segfault? Determines how defensive the `DenseGPUGrid` struct needs to be.
- **Does the `CuTexture` handle survive a `CUDA.device!()` switch?** If the user changes devices between creating the texture and rendering, does the driver error cleanly or crash? The source stores `ctx::CuContext`; `unsafe_destroy!` uses `context!(t.ctx; skip_destroyed=true)`, so ctx is captured at construction. Needs a test in multi-GPU setups — probably out of scope for this effort.
- **Border color for fog volumes**: The current CUDA.jl constructor hardcodes the border color to zero (`ntuple(_->Cfloat(zero(eltype(T))), 4)`). For fog (bg=0) this is exactly right and `ADDRESS_MODE_BORDER` works. Could be worth a small CUDA.jl PR to expose a `border_color` kwarg; not blocking for Lyr v1.
- **WSL2 + CUDA + texture memory**: I have not seen anyone report WSL2-specific texture issues. The Lyr benchmarks already run under WSL2 (CLAUDE.md line on "WSL2 + CUDA works via GPU passthrough"), and the texture unit is part of the standard CUDA runtime, so nothing architectural suggests it would fail. But — worth one explicit test before assuming.
- **Densification cost vs. render cost**: On first render, we pay `nx*ny*nz` traversals of the NanoVDB tree to fill the dense grid. For 512³ that's ~134M traversals. On a GPU at ~1 ns/traversal that's 134 ms — noticeable. Amortized across many renders it's irrelevant. Needs to be measured, and the result needs to land in the user-facing docs so the first render doesn't look slower than expected.
- **Precision**: CUDA linear filtering uses a 9-bit fraction representation for the interpolation weights (per CUDA C++ Programming Guide §3.2.14.1.2). For level-set SDFs near the zero-isosurface, the loss of precision vs. software Float32 lerp could shift the isosurface by ≤1 voxel × 2⁻⁹. This is usually imperceptible, but **the test comparing texture vs NanoVDB density should run at 1e-3 tolerance, not 1e-6, precisely because of this**. Worth noting in docs.
- **Whether `gpu_render_volume` should manage the texture lifetime or hand it back to the caller**: If render A creates a texture and renders; render B reuses the same grid — ideally we reuse the texture. Currently `gpu_render_volume` uploads nanogrid.buffer fresh every call (stocktake doc 08, §4.2 flags this as a separate bug). Solving both at once — a `GPUNanoGrid`-plus-optional-`DenseGPUGrid` cached type that survives across render calls — would be ~1 extra day but makes the whole GPU path cleaner. Recommend folding it in.

---

## References

- CUDA.jl master, `CUDACore/src/texture.jl` — host-side `CuTexture` / `CuTextureArray` definitions. https://github.com/JuliaGPU/CUDA.jl/blob/master/CUDACore/src/texture.jl
- CUDA.jl master, `CUDACore/src/device/texture.jl` — device-side `CuDeviceTexture`, NVVM `tex.unified.*` intrinsics. https://github.com/JuliaGPU/CUDA.jl/blob/master/CUDACore/src/device/texture.jl
- CUDA.jl master, `CUDACore/src/CUDAKernels.jl` — `KA.argconvert(::KA.Kernel{CUDABackend}, arg) = cudaconvert(arg)`. https://github.com/JuliaGPU/CUDA.jl/blob/master/CUDACore/src/CUDAKernels.jl
- CUDA.jl 2.1 release announcement, 2020-10-30. https://juliagpu.org/post/2020-10-30-cuda_2.1/
- CuTextures.jl (deprecated original, archived reference). https://github.com/cdsousa/CuTextures.jl
- NVIDIA CUDA C++ Programming Guide, "Texture Memory" (§3.2.14) and "Technical Specifications per Compute Capability" (§20). https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html
- RTX 3090 deviceQuery output (max 3D texture 16384³). HPCDIY Blog. https://server-gear.shop/blog/post/rtx3090-nvidia-smi-devicequery.html
- SciML/DiffEqGPU.jl issue #224 — EnsembleGPUKernel + Texture Memory Support (negative precedent). https://github.com/SciML/DiffEqGPU.jl/issues/224
- Julia Discourse, "CuTextureArray for Float64?" — confirms Float64 unsupported at hardware level. https://discourse.julialang.org/t/cutexturearray-for-float64/63346
- Julia Discourse, "Relation between KernelAbstractions and Adapt" — confirms adapt_storage dispatch path. https://discourse.julialang.org/t/relation-between-kernelabstractions-and-adapt/130326
- Local: `/home/tobiasosborne/Projects/Lyr.jl/src/GPU.jl` (the software trilinear path being replaced).
- Local: `/home/tobiasosborne/Projects/Lyr.jl/ext/LyrCUDAExt.jl` (where the fast path will land).
- Local: `/home/tobiasosborne/Projects/Lyr.jl/docs/stocktake/04_gpu_rendering.md` (current kernel architecture).
- Local: `/home/tobiasosborne/Projects/Lyr.jl/docs/stocktake/08_perf_vs_webgl.md` §1.1, §4.4 (the perf gap this document addresses).
