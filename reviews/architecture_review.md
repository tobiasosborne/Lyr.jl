# Architecture Review

## Summary

Lyr.jl is a ~14,000-line single-module Julia package implementing a pure-Julia OpenVDB parser, a production volume renderer with delta/ratio tracking, a general relativity ray tracer (GR submodule), and a Field Protocol bridging physics simulations to visualization. The architecture follows a layered design: binary I/O primitives at the bottom, VDB tree types and parsing in the middle, query/interpolation/rendering at the top, with two self-contained submodules (TinyVDB as test oracle, GR for curved-spacetime rendering).

The overall design is sound for a single-developer research platform. The VDB tree types are well-designed (immutable, parametric, zero-alloc leaf access), the NanoVDB flat buffer is a clean GPU-readiness abstraction, and the Field Protocol provides a coherent interface between physics and rendering. However, the flat file structure (55+ files in `src/`) with no intermediate submodules creates maintenance pressure, the `VolumeIntegrator.jl` has significant code duplication from performance-motivated inlining, and there are several abstraction leaks between the rendering layers. The GR submodule is cleanly isolated but entirely disconnected from the main volume rendering pipeline, creating two parallel and incompatible rendering systems.

## Findings

### [SEVERITY: major] Flat module structure with 55+ files and no intermediate namespaces

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/Lyr.jl` (lines 12-96), all files in `src/`
- **Description**: The main `Lyr` module includes 55+ files via `include()` in a single flat namespace. Every function, type, and constant from every file shares the same module scope. Files are ordered manually by dependency, and the only submodules are `TinyVDB` and `GR`. Conceptual groups (VDB parsing, grid operations, rendering pipeline, field protocol) exist only as comments in `Lyr.jl`.
- **Impact**: (1) Name collisions become increasingly likely as the codebase grows. (2) Include ordering is fragile -- moving a file can cause cryptic "not defined" errors. (3) There is no way to load just the parser without also loading the renderer, GPU code, field protocol, and GR module. (4) Internal helper functions like `_buf_load`, `_nano_root_find`, `_precompute_volume` pollute the module namespace and could accidentally shadow each other across files.
- **Recommendation**: Introduce intermediate submodules for the major conceptual groups: `Lyr.VDB` (parsing, tree types, accessors), `Lyr.Render` (scene, integrator, output), `Lyr.Fields` (field protocol, voxelize, visualize). The main `Lyr` module would re-export the public API from these. This also enables lazy loading of heavy subsystems (e.g., OrdinaryDiffEq is only needed by PointAdvection).

### [SEVERITY: major] Massive code duplication in VolumeIntegrator.jl (delta_tracking + ratio_tracking HDDA inlining)

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/VolumeIntegrator.jl` (780 lines)
- **Description**: The `delta_tracking_step` function (lines 57-231) and `ratio_tracking` function (lines 250-407) each contain a complete, manually-inlined copy of the HDDA state machine from `VolumeHDDA.jl`. The inner loop pattern -- root collection, insertion sort, I2 DDA, I1 DDA, span merging, density sampling -- is duplicated 8 times across the file (8 occurrences of `while t < span_end`). The rationale (comments at lines 42-49) is to avoid closure boxing of mutable captured variables.
- **Impact**: Any bug fix or algorithmic improvement to the HDDA traversal must be manually replicated in 3+ locations (`delta_tracking_step`, `ratio_tracking`, and `foreach_hdda_span` in `VolumeHDDA.jl`). This has already led to subtle divergence between the implementations. The file is the single largest non-GPU source file at 780 lines, most of which is boilerplate.
- **Recommendation**: Extract the shared HDDA state machine into a single inline-friendly function that takes a callback/functor struct (not a closure) for the per-span action. In Julia, a struct with `@inline` callable method avoids boxing:
  ```julia
  struct DeltaTrackingAction ... end
  @inline (a::DeltaTrackingAction)(span_t0, span_t1) = ...
  ```
  Alternatively, use `@generated` or a macro to stamp out the HDDA body with different inner-loop logic. This would reduce VolumeIntegrator.jl by ~60%.

### [SEVERITY: major] Two completely independent rendering pipelines with no shared abstractions

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/VolumeIntegrator.jl` (main renderer), `/home/tobiasosborne/Projects/Lyr.jl/src/GR/render.jl` (GR renderer)
- **Description**: The main volume renderer (`Scene`, `Camera`, `VolumeEntry`, `render_volume_image`) and the GR renderer (`GRCamera`, `GRRenderConfig`, `VolumetricMatter`, `gr_render_image`) share no types, no code, and no abstractions. They each have their own camera model, their own pixel loop with threading, their own tone mapping, their own ray-matter interaction logic. The main `Camera` (defined in `Render.jl`) and `GRCamera` (defined in `GR/camera.jl`) are unrelated types. Even `write_ppm` is referenced from GR docs via `Lyr.write_ppm`, coupling the submodule to the parent.
- **Impact**: Users working on a project that uses both flat-space and curved-space rendering must learn two entirely different APIs. Code improvements to the pixel loop (e.g., better stratified sampling, denoising, output formats) must be duplicated. There is no path to progressive enhancement (e.g., a "weak-field" mode that transitions smoothly between flat and curved rendering).
- **Recommendation**: Define a shared `AbstractRenderer` protocol with a common pixel-loop driver that accepts a `trace_ray(ray, scene) -> color` callback. The main renderer and GR renderer would each implement `trace_ray`. The outer loop (pixel iteration, threading, supersampling, tone mapping, output) would be shared. This also positions the codebase for the `WeakField` metric that bridges both worlds.

### [SEVERITY: major] `evaluate` function name overloading across unrelated domains

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/TransferFunction.jl` (line 47), `/home/tobiasosborne/Projects/Lyr.jl/src/FieldProtocol.jl` (line 159), `/home/tobiasosborne/Projects/Lyr.jl/src/PhaseFunction.jl` (line 55), `/home/tobiasosborne/Projects/Lyr.jl/src/GR/volumetric.jl` (line 60)
- **Description**: The name `evaluate` is used for four conceptually different operations: (1) `evaluate(tf::TransferFunction, density)` -- density-to-color mapping, (2) `evaluate(f::AbstractContinuousField, x, y, z)` -- spatial field sampling, (3) `evaluate(pf::PhaseFunction, cos_theta)` -- angular scattering distribution, (4) `evaluate_density(disk::ThickDisk, r, theta, phi)` -- volumetric density query (at least this one uses a distinct name). The FieldProtocol.jl comments explicitly acknowledge this (line 156-157) and claim "no ambiguity" via multiple dispatch.
- **Impact**: While Julia's dispatch prevents runtime ambiguity, the cognitive load is significant. Reading `evaluate(pv.tf, density)` next to `evaluate(pv.pf, cos_theta)` in VolumeIntegrator.jl (lines 555-572) requires context to distinguish transfer function evaluation from phase function evaluation. The single exported `evaluate` symbol forces users to import all meanings. Adding a new `evaluate` method for a future field type could create dispatch ambiguity with the transfer function signature if both accept a single Float64.
- **Recommendation**: Use domain-specific names: `tf_evaluate` or `lookup` for transfer functions, `sample` or `evaluate` for fields (already the standard), `phase_eval` or `evaluate` for phase functions. At minimum, do not export the single name `evaluate` -- let users qualify with `Lyr.evaluate` or import the specific method they need.

### [SEVERITY: minor] GR submodule re-declares StaticArrays types already defined in parent

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/GR/types.jl` (lines 1-9), `/home/tobiasosborne/Projects/Lyr.jl/src/Lyr.jl` (lines 7-9)
- **Description**: The parent module defines `SVec3f`, `SVec3d`, `SMat3d` from StaticArrays. The GR submodule independently `using StaticArrays` and defines `SVec4d = SVector{4, Float64}` and `SMat4d = SMatrix{4, 4, Float64, 16}`. Both the parent and GR `using StaticArrays` separately. The GR module also has `using LinearAlgebra: dot, norm, cross, I, det` while the parent has `using LinearAlgebra: norm, normalize, dot, cross`.
- **Impact**: Minor redundancy. If a future refactoring needs to share 3D/4D vector operations between flat-space and GR rendering, the duplicate imports and separate type aliases will need reconciliation. The GR module's `SVec4d` is exported to users but `SVec3d` comes from the parent -- inconsistent provenance.
- **Recommendation**: Move all StaticArrays type aliases to a shared file (e.g., `VectorTypes.jl`) that both the parent module and GR submodule include. This eliminates the duplicate `using StaticArrays` and makes the type hierarchy explicit.

### [SEVERITY: minor] `_MAX_ROOTS` constant defined in VolumeHDDA.jl but used in VolumeIntegrator.jl

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/VolumeHDDA.jl` (line 212), `/home/tobiasosborne/Projects/Lyr.jl/src/VolumeIntegrator.jl` (lines 68-69, 86, 262-263, 280)
- **Description**: The constant `_MAX_ROOTS = 8` is defined in `VolumeHDDA.jl` and relied upon by `VolumeIntegrator.jl` through the flat module scope. There is no explicit declaration of this dependency -- it works only because VolumeHDDA.jl is included before VolumeIntegrator.jl in `Lyr.jl`.
- **Impact**: Reordering includes in Lyr.jl would break compilation with a mysterious "not defined" error. The implicit dependency between files is invisible to readers of VolumeIntegrator.jl.
- **Recommendation**: Either (a) move `_MAX_ROOTS` to a shared constants file, or (b) redefine it locally in VolumeIntegrator.jl with a comment referencing the canonical definition, or (c) consolidate the HDDA traversal code as recommended above.

### [SEVERITY: minor] NanoVDB buffer layout has hardcoded magic numbers throughout

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/NanoVDB.jl` (entire file, 1094 lines)
- **Description**: The NanoVDB buffer layout uses magic byte offsets computed from constants (`_I1_CMASK_OFF = 12`, `_I2_DATA_OFF = 12308`, etc.) that are derived from mask sizes and prefix array sizes. The header layout uses offsets like `13`, `37 + sizeof(T)`, `65 + sizeof(T)` that are documented in comments but computed ad-hoc. Functions like `nano_background` (line 160) hardcode `13` as the background position.
- **Impact**: Adding a field to the header or changing a node layout requires updating offsets in dozens of locations across NanoVDB.jl, VolumeIntegrator.jl, VolumeHDDA.jl, and GPU.jl. The GPU.jl file (927 lines) has its own parallel set of buffer access functions (`_gpu_buf_load`, `_gpu_buf_mask_is_on`) with the same hardcoded offsets.
- **Recommendation**: Define a `NanoLayout{T}` struct (or module-level constants parametrized on T) that computes all offsets from the type parameter. Access functions would reference `layout.header_size`, `layout.root_section_pos`, etc. rather than inline arithmetic. This is especially important for GPU.jl where the offsets must match exactly.

### [SEVERITY: minor] Deprecated `render_image` still fully implemented in Render.jl

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/Render.jl` (lines 141-239)
- **Description**: `render_image` is marked deprecated via `Base.depwarn` (line 156) but remains a fully functional 100-line method with its own threading, supersampling, and gamma correction. It duplicates functionality now provided by `render_volume_image` / `visualize`. It is not exported from `Lyr.jl` but is still accessible as `Lyr.render_image`.
- **Impact**: The deprecated code must be maintained alongside the production renderer. Users who find it via docs or autocomplete may use it unknowingly. Its existence in Render.jl makes that file's responsibility unclear -- is it the level-set surface renderer, or the volume renderer?
- **Recommendation**: Move `render_image` to a `Deprecated.jl` file and plan removal in the next minor version. Alternatively, keep only a thin wrapper that delegates to `render_volume_image` with appropriate parameter translation.

### [SEVERITY: minor] `write_ppm` defined in Render.jl, `write_png`/`write_exr` in Output.jl

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/Render.jl` (lines 243-274), `/home/tobiasosborne/Projects/Lyr.jl/src/Output.jl` (lines 229-305)
- **Description**: The `write_ppm` function is defined in `Render.jl` alongside the legacy surface renderer, while `write_png` and `write_exr` are defined in `Output.jl` alongside tone mapping operators. All three are exported from the same `Lyr` module and appear in the same export group. The separation is historical -- PPM was the first output format, added with the first renderer.
- **Impact**: A user looking for image output functions must search two files. A developer adding a new output format (e.g., JPEG) must decide which file to put it in. The split suggests `Render.jl` has mixed responsibilities.
- **Recommendation**: Move `write_ppm` to `Output.jl` where it logically belongs alongside the other image writers.

### [SEVERITY: minor] OrdinaryDiffEq is a heavy dependency used only by PointAdvection.jl

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/Project.toml` (line 15), `/home/tobiasosborne/Projects/Lyr.jl/src/PointAdvection.jl` (54 lines)
- **Description**: OrdinaryDiffEq is listed as a required dependency in Project.toml. It is a large package (many transitive dependencies, significant precompilation time). However, it is only used by `PointAdvection.jl`, a 54-line file that implements RK4 advection of particles through vector fields. The file does not actually `using OrdinaryDiffEq` -- it implements its own RK4 loop.
- **Impact**: Every user who loads Lyr pays the precompilation cost of OrdinaryDiffEq even if they never use point advection. Since PointAdvection.jl implements its own RK4 (not using OrdinaryDiffEq at all), the dependency appears vestigial.
- **Recommendation**: Verify whether OrdinaryDiffEq is actually used anywhere. If not, remove it from `[deps]` and move it to `[extras]`. If it is planned for future use, make it a conditional dependency via Julia's package extensions mechanism.

### [SEVERITY: minor] TinyVDB includes parent's VDBConstants.jl via relative path

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/TinyVDB/TinyVDB.jl` (line 39)
- **Description**: TinyVDB includes `VDBConstants.jl` from its parent directory via `include(joinpath(@__DIR__, "..", "VDBConstants.jl"))`. This means TinyVDB, which is documented as a "test oracle" and should be independent, reaches into the parent module's source tree.
- **Impact**: TinyVDB cannot be extracted into its own package without also extracting VDBConstants.jl. The upward directory traversal is fragile if the directory structure changes.
- **Recommendation**: Either (a) duplicate the small constants file (573 bytes) into TinyVDB for true independence, or (b) accept the coupling as intentional and document it. Given TinyVDB is explicitly a test oracle and will never be extracted, option (b) is pragmatic.

### [SEVERITY: minor] GPU.jl duplicates NanoVDB buffer access logic for device compatibility

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/GPU.jl` (lines 58-80), `/home/tobiasosborne/Projects/Lyr.jl/src/NanoVDB.jl` (lines 17-22, 57-64)
- **Description**: GPU.jl defines `_gpu_buf_load`, `_gpu_buf_mask_is_on`, `_gpu_buf_count_on_before` as device-compatible versions of the CPU functions `_buf_load`, `_buf_mask_is_on`, `_buf_count_on_before` in NanoVDB.jl. The logic is identical but the implementation differs (pointer manipulation vs. `reinterpret(@view ...)`).
- **Impact**: Any change to the NanoVDB buffer layout must be mirrored in GPU.jl. Bug fixes to buffer access logic must be duplicated.
- **Recommendation**: Define the buffer access functions in terms of a generic array type rather than `Vector{UInt8}`. The CPU version can specialize on `Vector{UInt8}` with pointer access, while the GPU version dispatches on the device array type. This is a natural fit for Julia's type dispatch system.

### [SEVERITY: nit] Export list mixes levels of abstraction

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/Lyr.jl` (lines 98-186)
- **Description**: The export list mixes high-level user-facing API (`visualize`, `parse_vdb`, `render_volume_image`) with low-level implementation details (`GradStencil`, `BoxStencil`, `move_to!`, `center_value`). Stencil types are exported but `ValueAccessor` (used far more commonly) is not. `evaluate` is exported (covering transfer functions, phase functions, and fields) but `get_value` (the core voxel access function) is also exported despite being primarily internal.
- **Impact**: Users face a large, unstructured export list. The distinction between "things you construct" and "things you call" is unclear from the exports alone.
- **Recommendation**: Organize exports into tiers: Tier 1 (essential user API: `parse_vdb`, `visualize`, `voxelize`, grid construction), Tier 2 (advanced: stencils, differential ops, rendering pipeline), Tier 3 (internal: `get_value`, mask operations). Consider not exporting Tier 3 symbols and letting power users qualify them.

### [SEVERITY: nit] PhaseFunction and TransferFunction are concrete struct names, not abstract types

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/PhaseFunction.jl` (line 15), `/home/tobiasosborne/Projects/Lyr.jl/src/TransferFunction.jl` (line 28)
- **Description**: `PhaseFunction` is an abstract type with concrete subtypes (`IsotropicPhase`, `HenyeyGreensteinPhase`). But `TransferFunction` is a concrete struct (piecewise-linear control points). The naming suggests symmetry that does not exist -- you can define custom phase functions by subtyping `PhaseFunction`, but you cannot define custom transfer functions because `TransferFunction` is concrete and `VolumeMaterial` stores it directly (not abstractly).
- **Impact**: If a user wants a procedural transfer function (e.g., computed from a shader), they cannot plug it in without modifying `VolumeMaterial`. The asymmetry is confusing: `PhaseFunction` follows the Julia abstract type pattern correctly, but `TransferFunction` does not.
- **Recommendation**: Rename the current `TransferFunction` to `PiecewiseLinearTF` and introduce `abstract type TransferFunction end` as the supertype. `VolumeMaterial` should store `TransferFunction` (abstract), and `evaluate` should dispatch on subtypes. This is a breaking change but aligns the two function types.

### [SEVERITY: nit] `BBox` (Int32 Coord) vs `AABB` (Float64 SVec3d) vs `BoxDomain` (Float64 SVec3d) -- three bounding box types

- **Location**: `/home/tobiasosborne/Projects/Lyr.jl/src/Coordinates.jl` (`BBox`), `/home/tobiasosborne/Projects/Lyr.jl/src/Ray.jl` (`AABB`), `/home/tobiasosborne/Projects/Lyr.jl/src/FieldProtocol.jl` (`BoxDomain`)
- **Description**: There are three axis-aligned bounding box types: `BBox` (Int32 Coord min/max, for VDB tree operations), `AABB` (Float64 SVec3d min/max, for ray intersection), and `BoxDomain` (Float64 SVec3d min/max, for field protocol domains). `AABB` and `BoxDomain` have identical storage but different semantic meaning.
- **Impact**: Conversion between them is manual and scattered. `AABB(bbox::BBox)` exists but `BoxDomain` to `AABB` does not. The three types with overlapping responsibilities create confusion about which to use where.
- **Recommendation**: Document the semantic distinction clearly (BBox = discrete index space, AABB = continuous rendering space, BoxDomain = continuous world space for physics). Consider whether AABB and BoxDomain could share a common parametric type `AABox{T}` with `AABB = AABox{SVec3d}` being a type alias.
