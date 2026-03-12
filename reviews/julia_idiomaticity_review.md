# Julia Idiomaticity & Efficiency Review

## Summary

Lyr.jl is a well-architected Julia codebase with strong fundamentals: immutable data types, parametric type system, zero-allocation hot paths, and effective use of multiple dispatch. The NanoVDB flat-buffer design, inlined HDDA state machines, and `NTuple{512,T}` leaf storage show expert-level performance awareness. The GR module is cleanly separated with proper abstract type hierarchies and ForwardDiff integration.

The main areas for improvement are:

1. **Type instability in Scene/VolumeEntry** -- `Union{NanoGrid, Nothing}` and `Vector{AbstractLight}` fields force runtime dispatch in rendering hot paths.
2. **Massive code duplication** in VolumeIntegrator.jl -- the HDDA+delta-tracking inner loop is copy-pasted 5+ times.
3. **Missing `@inline` / `@fastmath`** in a few numerically-intensive functions that would benefit.
4. **RootNode table uses Union-typed Dict** -- forces a type check on every tree access.
5. **DDAState is mutable but could benefit from restructuring** for better stack allocation.

Overall quality: **high**. This is professional-grade Julia code. The findings below are ordered by severity and performance impact.

---

## Findings

### [SEVERITY: major] Type-unstable `lights` field in Scene forces dynamic dispatch in render loops

- **Location**: `src/Scene.jl:149`
- **Current Code**:
```julia
struct Scene{V}
    camera::Camera
    lights::Vector{AbstractLight}
    volumes::V
    background::SVec3d
end
```
- **Issue**: `Vector{AbstractLight}` is a type-unstable container. Every access to a light in the inner render loop (called millions of times) triggers dynamic dispatch through `_light_contribution`. Since the set of light types is small and fixed (PointLight, DirectionalLight, ConstantEnvironmentLight), this is avoidable overhead.
- **Idiomatic Version**:
```julia
struct Scene{V, L}
    camera::Camera
    lights::L  # Tuple{DirectionalLight} or Vector{AbstractLight}
    volumes::V
    background::SVec3d
end
```
For the common single-light case, passing a `Tuple{DirectionalLight}` would give full type specialization. Alternatively, use `@nospecialize` on the light dispatch and keep the current approach (the overhead is small since lights are iterated once per pixel, not per sample step).
- **Performance Impact**: medium -- affects every pixel traced. In practice the branch predictor handles this well for single-light scenes, but multi-light scenes with mixed types pay ~5-15% overhead.

---

### [SEVERITY: major] Union-typed Dict in RootNode forces runtime type check on every voxel access

- **Location**: `src/TreeTypes.jl:108`
- **Current Code**:
```julia
struct RootNode{T} <: AbstractNode{T}
    background::T
    table::Dict{Coord, Union{InternalNode2{T}, Tile{T}}}
end
```
- **Issue**: Every `get_value` call hits `get(tree.table, ...)` which returns `Union{InternalNode2{T}, Tile{T}, Nothing}`. The `isa` check at the root level is unavoidable per-query overhead. In VDB, root tiles are rare (most entries are InternalNode2), so this Union penalizes the common case.
- **Idiomatic Version**: Consider separating tiles from children at the root level:
```julia
struct RootNode{T} <: AbstractNode{T}
    background::T
    children::Dict{Coord, InternalNode2{T}}
    tiles::Dict{Coord, Tile{T}}
end
```
This eliminates the Union entirely. The root lookup becomes:
```julia
node = get(tree.children, i2_origin, nothing)
node !== nothing && return _get_from_i2(acc, node, c)
tile = get(tree.tiles, i2_origin, nothing)
tile !== nothing && return tile.value
return tree.background
```
- **Performance Impact**: medium -- one less branch per tree query. Matters most for NanoVDB-free paths (direct tree access via ValueAccessor). NanoVDB bypasses this entirely with binary search, so the impact on rendering is low.

---

### [SEVERITY: major] VolumeEntry uses `Union{NanoGrid, Nothing}` -- loses type parameter

- **Location**: `src/Scene.jl:120-124`
- **Current Code**:
```julia
struct VolumeEntry{G}
    grid::G
    nanogrid::Union{NanoGrid, Nothing}
    material::VolumeMaterial
end
```
- **Issue**: `NanoGrid` is parameterized (`NanoGrid{T}`), but the field type is the unparameterized abstract `NanoGrid`. This means `_precompute_volume` must extract and assert the type:
```julia
nano = vol.nanogrid::NanoGrid  # loses T parameter
```
The type parameter `T` of the NanoGrid is not propagated through the scene, potentially causing type instability downstream.
- **Idiomatic Version**:
```julia
struct VolumeEntry{G, N}
    grid::G
    nanogrid::N  # NanoGrid{T} or Nothing
    material::VolumeMaterial
end
```
This propagates the full type through the scene, enabling the compiler to specialize all NanoGrid operations.
- **Performance Impact**: medium -- the `_precompute_volume` function extracts the nanogrid once per render and stores it in a concrete `_PrecomputedVolume{T}`, which mitigates much of the damage. But the initial extraction requires a runtime assertion.

---

### [SEVERITY: major] Massive code duplication in VolumeIntegrator.jl

- **Location**: `src/VolumeIntegrator.jl:57-230` (delta_tracking_step) and `src/VolumeIntegrator.jl:250-407` (ratio_tracking)
- **Current Code**: The HDDA state machine (root collection, insertion sort, I2/I1 DDA loop, span merging) is copy-pasted in full across:
  1. `delta_tracking_step` (~175 lines)
  2. `ratio_tracking` (~155 lines)
  3. `foreach_hdda_span` in VolumeHDDA.jl (~130 lines)

  Each copy has the identical root-hit collection, sort, and triple-nested DDA loop, differing only in the "span action" (delta tracking vs ratio tracking vs callback).
- **Issue**: This is not a performance issue (the duplication exists to avoid closure boxing), but it violates DRY and makes bug fixes error-prone. If a DDA bug is found, it must be fixed in 3+ places.
- **Idiomatic Version**: Factor out the HDDA machinery into a `@generated` function or use a `@inline` callback pattern that the compiler can fully inline:
```julia
@inline function _hdda_walk(action::F, buf, nanogrid, ray) where F
    # ... shared HDDA state machine ...
    # At each span close:
    action(span_t0, span_end) || return
end
```
With `action` being a `@inline`-annotated functor struct (not a closure):
```julia
struct DeltaTrackingAction{T}
    acc::NanoValueAccessor{T}
    ray::Ray
    # ... other fields ...
end
@inline (a::DeltaTrackingAction)(t0, t1) = # delta tracking logic
```
This avoids closure boxing while eliminating duplication.
- **Performance Impact**: negligible (refactoring for maintainability, not speed). The current inlined approach is correct for performance.

---

### [SEVERITY: major] `NanoVRIState` uses Union-typed fields causing allocation

- **Location**: `src/NanoVDB.jl:975-982`
- **Current Code**:
```julia
mutable struct NanoVRIState{T}
    roots::Vector{Tuple{Float64, Int}}
    root_idx::Int
    i2_ndda::Union{NodeDDA, Nothing}
    i2_off::Int
    i1_ndda::Union{NodeDDA, Nothing}
    i1_off::Int
end
```
- **Issue**: `Union{NodeDDA, Nothing}` fields in a mutable struct prevent the struct from being stored inline. Since `NodeDDA` contains a `DDAState` (also mutable), the entire iterator state escapes to the heap. This is the exact reason `foreach_hdda_span` was created as a zero-allocation alternative.
- **Idiomatic Version**: The `foreach_hdda_span` callback approach already solves this. The iterator-based `NanoVolumeHDDA` and `NanoVolumeRayIntersector` should be marked as non-performance-critical APIs (for convenience/debugging), with `foreach_hdda_span` being the production path. Consider adding a comment to this effect.
- **Performance Impact**: low (already mitigated by `foreach_hdda_span` in the production path).

---

### [SEVERITY: minor] `HDDAState` also uses Union-typed fields

- **Location**: `src/VolumeHDDA.jl:41-51`
- **Current Code**:
```julia
mutable struct HDDAState{T}
    roots::Vector{Tuple{Float64, Int}}
    root_idx::Int
    i2_ndda::Union{NodeDDA, Nothing}
    i2_off::Int
    i2_t_entry::Float64
    i1_ndda::Union{NodeDDA, Nothing}
    i1_off::Int
    i1_t_entry::Float64
    span_t0::Float64
end
```
- **Issue**: Same as above. The `Union{NodeDDA, Nothing}` fields prevent inline storage. Since this is the iterator-protocol version (not the callback version), it inherently allocates.
- **Idiomatic Version**: Same as above -- the zero-allocation `foreach_hdda_span` callback version is the production path. Document this clearly.
- **Performance Impact**: low (mitigated by callback version).

---

### [SEVERITY: minor] `_PrecomputedVolume` loses type parameter on `TransferFunction` and `PhaseFunction`

- **Location**: `src/VolumeIntegrator.jl:18-27`
- **Current Code**:
```julia
struct _PrecomputedVolume{T}
    nanogrid::NanoGrid{T}
    bmin::SVec3d
    bmax::SVec3d
    sigma_maj::Float64
    albedo::Float64
    emission_scale::Float64
    tf::TransferFunction
    pf::PhaseFunction
end
```
- **Issue**: `TransferFunction` and `PhaseFunction` are concrete types (not abstract), so `tf::TransferFunction` is type-stable. However, `pf::PhaseFunction` is abstract -- the concrete type is either `IsotropicPhase` or `HenyeyGreensteinPhase`. This forces dynamic dispatch on `evaluate(pf, cos_theta)` in the render loop.
- **Idiomatic Version**:
```julia
struct _PrecomputedVolume{T, PF<:PhaseFunction}
    nanogrid::NanoGrid{T}
    bmin::SVec3d
    bmax::SVec3d
    sigma_maj::Float64
    albedo::Float64
    emission_scale::Float64
    tf::TransferFunction
    pf::PF
end
```
- **Performance Impact**: low -- `evaluate(::IsotropicPhase, ...)` just returns a constant, and the branch predictor handles this well. But parametrizing removes the dispatch entirely.

---

### [SEVERITY: minor] `IntegratorConfig.stepper` is a Symbol -- forces runtime dispatch in hot loop

- **Location**: `src/GR/integrator.jl:29, 210-213`
- **Current Code**:
```julia
struct IntegratorConfig
    # ...
    stepper::Symbol
    # ...
end

@inline function _do_step(m::MetricSpace{4}, x::SVec4d, p::SVec4d, dl::Float64,
                           stepper::Symbol)::Tuple{SVec4d, SVec4d}
    stepper === :rk4 ? rk4_step(m, x, p, dl) : verlet_step(m, x, p, dl)
end
```
- **Issue**: `stepper::Symbol` is a runtime value. While the `===` comparison is fast and the branch predictor handles it well, this prevents the compiler from specializing the entire integration loop on the stepper choice. Each call to `_do_step` includes both code paths.
- **Idiomatic Version**: Use a type parameter or dispatch:
```julia
abstract type AbstractStepper end
struct RK4Stepper <: AbstractStepper end
struct VerletStepper <: AbstractStepper end

struct IntegratorConfig{S<:AbstractStepper}
    step_size::Float64
    max_steps::Int
    # ...
    stepper::S
end

@inline _do_step(m, x, p, dl, ::RK4Stepper) = rk4_step(m, x, p, dl)
@inline _do_step(m, x, p, dl, ::VerletStepper) = verlet_step(m, x, p, dl)
```
This eliminates the branch entirely and allows the compiler to inline the specific stepper.
- **Performance Impact**: low-medium for GR rendering -- the geodesic integration loop runs 10k+ steps per pixel, and removing a branch per step (even well-predicted) saves a few percent.

---

### [SEVERITY: minor] `DDAState` is mutable but only `ijk` and `tmax` change

- **Location**: `src/DDA.jl:28-33`
- **Current Code**:
```julia
mutable struct DDAState
    ijk::Coord
    const step::SVector{3, Int32}
    tmax::SVec3d
    const tdelta::SVec3d
end
```
- **Issue**: The `const` annotations on `step` and `tdelta` are good. However, Julia's optimizer can struggle with mutable structs that escape to the heap. In the DDA hot path, `dda_step!` modifies `ijk` and `tmax` in-place, which is correct. The issue is that `NodeDDA` wraps `DDAState` in an immutable struct, so `dda_step!` mutates through a reference -- this is fine for correctness but prevents stack allocation of the entire `NodeDDA`.
- **Idiomatic Version**: For maximum performance, consider making `DDAState` immutable and returning new values:
```julia
struct DDAState
    ijk::Coord
    step::SVector{3, Int32}
    tmax::SVec3d
    tdelta::SVec3d
end

@inline function dda_step(state::DDAState)::DDAState
    # ... return new DDAState with updated ijk and tmax
end
```
This would allow the entire DDA state to live on the stack. However, this would require changing the `NodeDDA` pattern and all call sites to thread the state through, which is a significant refactor.
- **Performance Impact**: low -- the current mutable approach works well in practice because `DDAState` is small and the mutation pattern is simple. The `foreach_hdda_span` callback already avoids heap-allocating the outer state.

---

### [SEVERITY: minor] `write_ppm` uses text-mode PPM (P3) -- slow for large images

- **Location**: `src/Render.jl:251-274`
- **Current Code**:
```julia
function write_ppm(filename::String, pixels::Matrix{NTuple{3, T}}) where T <: AbstractFloat
    open(filename, "w") do io
        println(io, "P3")
        # ... text output ...
        print(io, ri, ' ', gi, ' ', bi)
```
- **Issue**: Text-mode PPM (`P3`) is 3-5x slower to write than binary PPM (`P6`) because of `print`/integer-to-string conversions. For a 1920x1080 image, this can take hundreds of milliseconds.
- **Idiomatic Version**:
```julia
function write_ppm(filename::String, pixels::Matrix{NTuple{3, T}}) where T <: AbstractFloat
    height, width = size(pixels)
    open(filename, "w") do io
        write(io, "P6\n$width $height\n255\n")
        buf = Vector{UInt8}(undef, width * 3)
        for y in 1:height
            for x in 1:width
                r, g, b = pixels[y, x]
                idx = (x - 1) * 3
                buf[idx + 1] = clamp(round(UInt8, r * 255), 0x00, 0xff)
                buf[idx + 2] = clamp(round(UInt8, g * 255), 0x00, 0xff)
                buf[idx + 3] = clamp(round(UInt8, b * 255), 0x00, 0xff)
            end
            write(io, buf)
        end
    end
end
```
- **Performance Impact**: low (I/O is rarely the bottleneck compared to rendering).

---

### [SEVERITY: minor] `Coord.getindex` uses chained ternary -- could use `@inline` and `getfield`

- **Location**: `src/Coordinates.jl:28`
- **Current Code**:
```julia
Base.getindex(c::Coord, i::Int) = i == 1 ? c.x : i == 2 ? c.y : i == 3 ? c.z : throw(BoundsError(c, i))
```
- **Issue**: This is called extensively in DDA code (e.g., `ndda.state.ijk[1]`). The chained ternary compiles to two branches. While simple, it could be slightly faster with a `@boundscheck`/`@inbounds` pattern.
- **Idiomatic Version**:
```julia
@inline function Base.getindex(c::Coord, i::Int)
    @boundscheck (1 <= i <= 3) || throw(BoundsError(c, i))
    @inbounds i == 1 ? c.x : i == 2 ? c.y : c.z
end
```
More idiomatic: since `Coord` has exactly 3 fields, use `ntuple` or define it as a wrapper around `SVector{3, Int32}` for automatic indexing.
- **Performance Impact**: negligible -- LLVM optimizes the ternary chain well.

---

### [SEVERITY: minor] `planck_to_xyz` recomputes physical constants per call

- **Location**: `src/GR/redshift.jl:176-188`
- **Current Code**:
```julia
function planck_to_xyz(T::Float64)::NTuple{3, Float64}
    T <= 0.0 && return (0.0, 0.0, 0.0)
    X, Y, Z = 0.0, 0.0, 0.0
    dλ = 5e-9
    for (λ_nm, xbar, ybar, zbar) in _CIE_XYZ_5NM
        λ_m = λ_nm * 1e-9
        B = planck_spectral_radiance(λ_m, T)
        X += B * xbar * dλ
        Y += B * ybar * dλ
        Z += B * zbar * dλ
    end
    (X, Y, Z)
end
```
- **Issue**: The loop iterates over 81 spectral samples per call, computing `planck_spectral_radiance` each time (which involves `exp`). This is called per-pixel in volumetric GR rendering. The CIE data is a `const` Tuple of Tuples, which is good -- the iteration is type-stable.
- **Idiomatic Version**: Cache a lookup table (LUT) for Planck-to-RGB at module init:
```julia
const _PLANCK_LUT_SIZE = 1024
const _PLANCK_LUT_T_MAX = 50000.0
const _PLANCK_LUT = let
    lut = Vector{NTuple{3, Float64}}(undef, _PLANCK_LUT_SIZE)
    for i in 1:_PLANCK_LUT_SIZE
        T = (i - 0.5) / _PLANCK_LUT_SIZE * _PLANCK_LUT_T_MAX
        lut[i] = _planck_to_rgb_exact(T)  # the current implementation
    end
    lut
end

function planck_to_rgb(T_kelvin::Float64)::NTuple{3, Float64}
    T_kelvin <= 0.0 && return (0.0, 0.0, 0.0)
    T_kelvin >= _PLANCK_LUT_T_MAX && return _PLANCK_LUT[end]
    idx_f = T_kelvin / _PLANCK_LUT_T_MAX * _PLANCK_LUT_SIZE
    idx = clamp(floor(Int, idx_f) + 1, 1, _PLANCK_LUT_SIZE)
    @inbounds _PLANCK_LUT[idx]
end
```
This replaces 81 `exp` calls with a single table lookup.
- **Performance Impact**: medium for GR volumetric rendering (removes ~80% of per-pixel compute for Planck color).

---

### [SEVERITY: minor] `sample_quadratic` creates a `ValueAccessor` on every call

- **Location**: `src/Interpolation.jl:134`
- **Current Code**:
```julia
function sample_quadratic(tree::Tree{T}, ijk::SVec3d)::T where T
    # ...
    acc = ValueAccessor(tree)
    # ... 27-point stencil using acc ...
end
```
- **Issue**: A new `ValueAccessor` is heap-allocated on every `sample_quadratic` call. For a 27-point stencil, the cache hits only help for the 26 neighbors of the first point -- the accessor is discarded immediately after.
- **Idiomatic Version**: Accept an optional `ValueAccessor` parameter:
```julia
function sample_quadratic(tree::Tree{T}, ijk::SVec3d;
                           acc::ValueAccessor{T}=ValueAccessor(tree))::T where T
```
Or better, add a method that accepts a pre-existing accessor:
```julia
function sample_quadratic(acc::ValueAccessor{T}, ijk::SVec3d)::T where T
```
- **Performance Impact**: low for typical use. Medium if `sample_quadratic` is called in a tight loop (e.g., `resample_to_match`).

---

### [SEVERITY: minor] `_lerp3` for scalars uses `1 - u` pattern instead of `muladd`

- **Location**: `src/Interpolation.jl:227-237`
- **Current Code**:
```julia
function _lerp3(v000::T, ..., u::T, v::T, w::T)::T where T <: AbstractFloat
    c00 = v000 * (1 - u) + v100 * u
    c10 = v010 * (1 - u) + v110 * u
    # ...
end
```
- **Issue**: `a * (1 - t) + b * t` is numerically equivalent to `a + t * (b - a)` but the latter is one multiplication fewer. LLVM may or may not optimize this. Using `muladd` or the `@fastmath` macro would help.
- **Idiomatic Version**:
```julia
@fastmath function _lerp3(v000::T, ..., u::T, v::T, w::T)::T where T <: AbstractFloat
    c00 = muladd(u, v100 - v000, v000)
    c10 = muladd(u, v110 - v010, v010)
    # ...
end
```
Or simply add `@fastmath` to the existing function since this is an interpolation context where reassociation is acceptable.
- **Performance Impact**: negligible (LLVM handles this well in most cases).

---

### [SEVERITY: minor] `VolumeMaterial` stores concrete `TransferFunction` but abstract `PhaseFunction`

- **Location**: `src/Scene.jl:89-95`
- **Current Code**:
```julia
struct VolumeMaterial
    transfer_function::TransferFunction
    phase_function::PhaseFunction  # abstract type!
    sigma_scale::Float64
    emission_scale::Float64
    scattering_albedo::Float64
end
```
- **Issue**: `PhaseFunction` is abstract. Storing an abstract type in a struct field boxes the value and requires dynamic dispatch on every `evaluate(pf, ...)` call.
- **Idiomatic Version**:
```julia
struct VolumeMaterial{PF<:PhaseFunction}
    transfer_function::TransferFunction
    phase_function::PF
    sigma_scale::Float64
    emission_scale::Float64
    scattering_albedo::Float64
end
```
- **Performance Impact**: low (evaluated once per scattering event, not per sample step).

---

### [SEVERITY: minor] `ParticleField.properties` uses `Dict{Symbol, Vector}` -- untyped values

- **Location**: `src/FieldProtocol.jl:309`
- **Current Code**:
```julia
struct ParticleField <: AbstractField
    positions::Vector{SVec3d}
    velocities::Union{Nothing, Vector{SVec3d}}
    properties::Dict{Symbol, Vector}
end
```
- **Issue**: `Dict{Symbol, Vector}` stores untyped vectors. Accessing a property requires a `Vector{Float64}` cast at the call site, which is type-unstable. This is fine for a metadata/schema-style container that is not accessed in hot loops.
- **Idiomatic Version**: If type safety matters, consider:
```julia
properties::Dict{Symbol, Any}  # explicit about heterogeneity
```
Or use a typed wrapper:
```julia
struct TypedProperty{T}
    data::Vector{T}
end
properties::Dict{Symbol, TypedProperty}
```
- **Performance Impact**: negligible (not accessed in render loops).

---

### [SEVERITY: minor] Missing `@fastmath` in GR integrator inner loop

- **Location**: `src/GR/integrator.jl:78-102` (rk4_step), `src/GR/render.jl:155-249` (volumetric trace)
- **Current Code**: The RK4 step and volumetric rendering inner loops perform many floating-point operations without `@fastmath`.
- **Issue**: The GR integrator uses IEEE-754 strict arithmetic by default. For physically-inspired rendering (not exact numerical simulation), `@fastmath` would allow LLVM to use FMA, reassociate additions, and eliminate redundant NaN checks.
- **Idiomatic Version**:
```julia
@fastmath function rk4_step(m::MetricSpace{4}, x::SVec4d, p::SVec4d, dl::Float64)
    # ... same code ...
end
```
Note: only apply `@fastmath` to the rendering path, not to test/validation code.
- **Performance Impact**: low-medium (10-20% speedup on the integration loop for FMA-capable CPUs).

---

### [SEVERITY: minor] `_buf_store!` uses `Ref` + `memcpy` -- could use `unsafe_store!`

- **Location**: `src/NanoVDB.jl:25-36`
- **Current Code**:
```julia
@inline function _buf_store!(buf::Vector{UInt8}, pos::Int, val::T) where T
    @boundscheck checkbounds(buf, pos:pos + sizeof(T) - 1)
    GC.@preserve buf begin
        @inbounds ptr = pointer(buf, pos)
        ref = Ref(val)
        GC.@preserve ref begin
            src = Base.unsafe_convert(Ptr{T}, ref)
            ccall(:memcpy, Ptr{Cvoid}, (Ptr{UInt8}, Ptr{T}, Csize_t), ptr, src, sizeof(T))
        end
    end
    nothing
end
```
- **Issue**: This creates a `Ref`, converts to pointer, and calls `memcpy`. For small types (UInt32, Float32), `unsafe_store!` is simpler and potentially faster:
- **Idiomatic Version**:
```julia
@inline function _buf_store!(buf::Vector{UInt8}, pos::Int, val::T) where T
    @boundscheck checkbounds(buf, pos:pos + sizeof(T) - 1)
    GC.@preserve buf begin
        ptr = Base.unsafe_convert(Ptr{T}, pointer(buf, pos))
        unsafe_store!(ptr, val)
    end
    nothing
end
```
Note: This assumes the platform handles unaligned stores (true on x86, may need care on ARM). Since `_buf_load` already uses `_unaligned_load` via `memcpy`, `_buf_store!` should arguably also use `memcpy` for ARM portability. The current code is correct but verbose.
- **Performance Impact**: negligible (build_nanogrid is called once, not in the render loop).

---

### [SEVERITY: minor] `_escape_radiance` scans lights vector every pixel

- **Location**: `src/VolumeIntegrator.jl:427-434`
- **Current Code**:
```julia
@inline function _escape_radiance(scene::Scene)::NTuple{3, Float64}
    for light in scene.lights
        if light isa ConstantEnvironmentLight
            return (light.radiance[1], light.radiance[2], light.radiance[3])
        end
    end
    (scene.background[1], scene.background[2], scene.background[3])
end
```
- **Issue**: This iterates through the lights array (with dynamic dispatch due to `Vector{AbstractLight}`) to find a `ConstantEnvironmentLight`. It is called once before the render loop, so it is not in the hot path. However, it scans unnecessarily.
- **Idiomatic Version**: Cache the escape radiance in the Scene struct or compute it once in the renderer setup.
- **Performance Impact**: negligible (called once per render, not per pixel).

---

### [SEVERITY: nit] Redundant type annotations on function returns

- **Location**: Throughout the codebase (e.g., `src/Coordinates.jl:56`, `src/Masks.jl:81`, etc.)
- **Current Code**:
```julia
@inline function leaf_origin(c::Coord)::Coord
    # ...
end
function is_on(m::Mask{N,W}, i::Int)::Bool where {N,W}
    # ...
end
```
- **Issue**: Julia style guides recommend return type annotations only when they serve as documentation or enforce a contract. In most cases here, the return type is obvious from the implementation and the annotation adds noise. However, these annotations also serve as a form of documentation and can catch bugs during development.
- **Idiomatic Version**: This is a style preference. The current approach is consistent and serves as documentation. No change needed, but be aware that `::T` return annotations can sometimes inhibit type inference if the function returns a subtype of `T`.
- **Performance Impact**: negligible (the annotations do not affect codegen in practice).

---

### [SEVERITY: nit] `zeros(SMat4d)` allocates -- use `zero(SMat4d)` or `@SMatrix zeros(4,4)`

- **Location**: `src/GR/metrics/schwarzschild.jl:106`
- **Current Code**:
```julia
zero4 = zeros(SMat4d)
```
- **Issue**: `zeros(SMat4d)` may not dispatch to the StaticArrays zero constructor. Use `zero(SMat4d)` for guaranteed static allocation.
- **Idiomatic Version**:
```julia
zero4 = zero(SMat4d)
```
- **Performance Impact**: negligible (called once per metric evaluation, which is already expensive).

---

### [SEVERITY: nit] `OffIndicesIterator` has `Base.SizeUnknown()` but could be `HasLength`

- **Location**: `src/Masks.jl:251`
- **Current Code**:
```julia
Base.IteratorSize(::Type{OffIndicesIterator{N,W}}) where {N,W} = Base.SizeUnknown()
```
- **Issue**: The length of off-indices is `N - count_on(mask)`, which is known. Using `HasLength()` would enable `collect` to preallocate and `length` to work.
- **Idiomatic Version**:
```julia
Base.IteratorSize(::Type{OffIndicesIterator{N,W}}) where {N,W} = Base.HasLength()
Base.length(it::OffIndicesIterator{N,W}) where {N,W} = N - count_on(it.mask)
```
- **Performance Impact**: negligible.

---

### [SEVERITY: nit] `_compute_prefix` uses a loop inside `ntuple` -- could be `cumsum`-style

- **Location**: `src/Masks.jl:17-25`
- **Current Code**:
```julia
@inline function _compute_prefix(words::NTuple{W, UInt64}) where W
    ntuple(Val(W)) do i
        s = UInt32(0)
        for j in 1:i
            s += UInt32(count_ones(words[j]))
        end
        s
    end
end
```
- **Issue**: This is O(W^2) due to recomputing the partial sum from scratch for each `i`. For W=512 (Internal2Mask), this is 512*512/2 = 131k additions. Since this runs at parse time (not render time), it is not a hot path, but it is inelegant.
- **Idiomatic Version**:
```julia
@inline function _compute_prefix(words::NTuple{W, UInt64}) where W
    # Cumulative sum: prefix[i] = sum of popcounts of words[1:i]
    ntuple(Val(W)) do i
        @inbounds if i == 1
            UInt32(count_ones(words[1]))
        else
            # This still recomputes from 1, but LLVM constant-folds it for small W.
            # For large W, a manual accumulation would be better.
            s = UInt32(0)
            for j in 1:i
                s += UInt32(count_ones(words[j]))
            end
            s
        end
    end
end
```
The truly efficient version would use `@generated` or a manual loop, but since `ntuple(Val(W))` with a constant `W` gets fully unrolled by the compiler, the O(W^2) is actually O(W^2) compile-time operations producing O(W) runtime operations. For W <= 64 (Internal1Mask), this is fine. For W = 512, it may cause long compile times.
- **Performance Impact**: negligible at runtime, potentially significant compile time for W=512.

---

### [SEVERITY: nit] `read_bytes` creates a copy -- `@view` would avoid allocation

- **Location**: `src/Binary.jl:144-147`
- **Current Code**:
```julia
function read_bytes(bytes::Vector{UInt8}, pos::Int, n::Int)::Tuple{Vector{UInt8}, Int}
    @boundscheck checkbounds(bytes, pos:pos+n-1)
    (bytes[pos:pos+n-1], pos + n)
end
```
- **Issue**: `bytes[pos:pos+n-1]` creates a copy. If the caller only reads from the result, a `@view` would avoid the allocation.
- **Idiomatic Version**: If backward compatibility allows:
```julia
function read_bytes(bytes::Vector{UInt8}, pos::Int, n::Int)
    @boundscheck checkbounds(bytes, pos:pos+n-1)
    (@view(bytes[pos:pos+n-1]), pos + n)
end
```
However, returning a view changes the return type and could affect callers that expect ownership. Check all call sites first.
- **Performance Impact**: negligible (only used in file parsing, not rendering).

---

### [SEVERITY: nit] `build_nanogrid` uses `objectid` for node identity -- fragile

- **Location**: `src/NanoVDB.jl:443-459`
- **Current Code**:
```julia
i2_index = Dict{UInt, Int}()   # objectid → index
# ...
i2_index[objectid(node2)] = length(i2_nodes)
```
- **Issue**: `objectid` returns the memory address of an object, which is stable for the lifetime of the object but not across GC cycles. Since `build_nanogrid` holds references to all nodes (via `i2_nodes`, `i1_nodes`, `leaf_nodes`), GC cannot collect them during the function, so this is safe. However, it is fragile -- if the code were refactored to not retain references, `objectid` could silently break.
- **Idiomatic Version**: This is a pragmatic choice for a two-pass serialization algorithm. An alternative would be to store indices alongside the tree structure, but that would require modifying the tree types. The current approach is acceptable with a comment explaining the safety invariant.
- **Performance Impact**: none.

---

### [SEVERITY: nit] Module organization: `using Random: Xoshiro, randexp` at file scope inside module

- **Location**: `src/VolumeIntegrator.jl:12`
- **Current Code**:
```julia
using Random: Xoshiro, randexp
```
- **Issue**: This `using` statement is inside the `Lyr` module (since VolumeIntegrator.jl is `include`'d), which means `Xoshiro` and `randexp` become available in the `Lyr` module scope. This is fine but could be more explicit. The same pattern appears in `src/Render.jl:3` and `src/PhaseFunction.jl:3`.
- **Idiomatic Version**: Centralizing all `using` statements in `Lyr.jl` (the main module file) is a common Julia convention:
```julia
# In Lyr.jl
using Random: Xoshiro, randexp, AbstractRNG, rand
```
This makes dependencies explicit and avoids scattered imports.
- **Performance Impact**: none (purely organizational).

---

## Patterns Done Well

The following patterns are exemplary and worth highlighting:

1. **Immutable NTuple-based leaf storage** (`NTuple{512,T}` in `LeafNode`) -- eliminates GC pressure entirely for leaf values. This is a critical design choice.

2. **Prefix-sum bitmask** (`Mask{N,W}` with precomputed prefix sums) -- O(1) `count_on_before` is essential for the popcount-indexed sparse table lookup pattern.

3. **Zero-allocation callback HDDA** (`foreach_hdda_span` with `MVector` stack buffers) -- correctly identifies that the iterator protocol forces heap allocation and provides a zero-allocation alternative.

4. **NanoValueAccessor** with 3-level cache -- mirrors OpenVDB's accessor pattern and exploits spatial coherence in ray marching.

5. **Parametric Grid type** (`Grid{T, Tr}`) -- the transform type parameter avoids dynamic dispatch on world-to-index conversion.

6. **GR MetricSpace hierarchy** with ForwardDiff fallback -- clean separation between the metric interface (required methods) and the default implementation (automatic differentiation), with analytic overrides for Schwarzschild.

7. **Field Protocol design** -- parametric field types (`ScalarField3D{F}`) capture the evaluation function's type, enabling full specialization.

8. **Proper use of `GC.@preserve`** in all unsafe pointer operations -- prevents the GC from collecting the backing array during pointer arithmetic.
