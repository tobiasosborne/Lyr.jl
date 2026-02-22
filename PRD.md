# Lyr.jl — Product Requirements Document

**Version**: 1.0 draft
**Date**: 2026-02-22
**Status**: Draft for review

---

## Product Thesis

**Minimal cognitive distance from physics to pixels.**

Lyr.jl is a production-quality volumetric renderer for scientific data, designed to be operated primarily by AI agents. It is the visualization layer missing from the Julia scientific computing ecosystem.

The value proposition is not "no GUI." It is that an AI agent, given a physicist's natural-language intent and Lyr's API, can produce publication-quality volume renderings with no intermediate cognitive burden on the user. The user never maps physics concepts to tool-specific operations. The agent handles the mapping. Lyr provides the rendering engine and the protocol that makes the mapping tractable.

---

## Problem Statement

The current landscape forces scientists into one of two bad choices:

1. **Monolithic commercial tools** (COMSOL, ANSYS, Houdini) that bundle solvers, visualization, and GUI into a $50K/year rent-seeking package. The visualization is locked inside the tool. The workflow is non-reproducible (click sequences). The learning curve is months.

2. **Plotting libraries** (Matplotlib, Makie.jl, ParaView) that produce adequate 2D/3D plots but cannot do production-quality volume rendering — Monte Carlo path tracing, proper denoising, HDR output, physical camera models.

Neither option composes with the Julia scientific computing ecosystem. Neither is agent-friendly. Neither produces Houdini-quality volume renders from arbitrary physics computations.

**Lyr fills the gap**: a scriptable, GPU-portable, production-quality volume renderer with an open protocol that any physics computation can render through, designed for agent-mediated interaction.

---

## Strategic Positioning

Lyr does **not** replace COMSOL, Blender, or Houdini alone.

The **agent + Julia ecosystem** replaces COMSOL. Gmsh.jl meshes geometry. Gridap.jl or DifferentialEquations.jl solves PDEs. Lyr visualizes the result. The agent orchestrates the pipeline. The user describes what they want in natural language. No single tool in this chain costs $50K/year. Every step is reproducible code.

Lyr's specific role: **the production-quality volumetric visualization layer that the Julia ecosystem lacks.** Makie.jl handles plots, surfaces, and interactive viewports. Lyr handles path-traced volumes. They compose; they don't compete.

### Competitive Moat

No existing tool combines:

- Production-quality Monte Carlo volume rendering (delta tracking, ratio tracking)
- GPU portability via KernelAbstractions.jl (NVIDIA, AMD, Apple, CPU)
- An open field protocol designed for agent-mediated composition
- Native Julia composability with the entire SciML/GPU/AD ecosystem
- Fully scriptable, reproducible output (no GUI state)

---

## Scope Boundaries

### Lyr IS

- A production-quality **volumetric renderer**
- An **open protocol** (the Field Protocol) for converting physics data to renderable grids
- A set of **example scripts** demonstrating physics visualization workflows
- An API designed to be **navigated by AI agents** via comprehensive docstrings and type signatures

### Lyr is NOT

- A physics solver. Use DifferentialEquations.jl, QuantumOptics.jl, Gridap.jl, etc.
- A general-purpose 3D renderer. No arbitrary mesh import, no polygon rendering, no surface shaders.
- A GUI application. Not now, not ever. (Interactive Makie viewports for visual feedback are a separate composable tool, not part of Lyr's rendering pipeline.)
- A scene graph or USD runtime. Scene descriptions are lightweight Julia structs.

### What NOT to Build

- **A GUI.** The agent is the interface.
- **Physics solvers.** Lyr visualizes fields; it does not compute them.
- **Polygon/mesh rendering.** For surfaces, lines, and glyphs, compose with Makie.
- **A full scene graph (USD, etc.).** Too heavy. Julia structs suffice.
- **OptiX interop.** Closed source, NVIDIA-only, inaccessible from Julia.

---

## The Field Protocol

The Field Protocol is the core product. It is the interface between physics computation and volumetric rendering. It is the contract that makes the agent's job tractable.

### Design Principles

1. **Open, not closed.** The protocol is an abstract interface, not a fixed set of types. Any Julia type that implements the required methods is a Lyr field. The initial types are reference implementations. The community extends without forking.

2. **Idiomatic Julia.** The protocol follows the pattern of `AbstractArray`: a small set of required methods with strong semantic contracts, optional methods with sensible fallbacks, and traits for capabilities. Multiple dispatch handles specialization.

3. **Everything becomes a VDB grid.** Lyr is a volumetric renderer. The Field Protocol's job is to bridge continuous/discrete physics data to voxel grids. The `voxelize` step is the bridge. Fields that cannot be meaningfully voxelized are outside Lyr's scope (compose with Makie instead).

### Required Interface

```julia
abstract type AbstractField end

# --- Required methods ---

# What does evaluation return?
fieldtype(f::AbstractField)::Type
# e.g., Float64, SVec3d, SMatrix{3,3,Float64,9}, ComplexF64

# Where does the field live?
domain(f::AbstractField)::AbstractDomain

# --- Continuous fields: sample at a point ---
abstract type AbstractContinuousField <: AbstractField end
evaluate(f::AbstractContinuousField, x::Float64, y::Float64, z::Float64)

# --- Discrete fields: sample at a site ---
abstract type AbstractDiscreteField <: AbstractField end
evaluate(f::AbstractDiscreteField, index)
sites(f::AbstractDiscreteField)  # iterator over valid indices
```

### Reference Implementations (shipped with Lyr)

These cover the common cases. They are conveniences, not the protocol itself.

```julia
struct ScalarField3D <: AbstractContinuousField
    eval_fn::Function         # (x, y, z) → Float64
    domain::BBox
    characteristic_scale::Float64
end

struct VectorField3D <: AbstractContinuousField
    eval_fn::Function         # (x, y, z) → SVec3d
    domain::BBox
    characteristic_scale::Float64
end

struct TensorField3D <: AbstractContinuousField
    eval_fn::Function         # (x, y, z) → SMatrix{3,3}
    domain::BBox
    characteristic_scale::Float64
end

struct ComplexScalarField3D <: AbstractContinuousField
    eval_fn::Function         # (x, y, z) → ComplexF64
    domain::BBox
    characteristic_scale::Float64
end

struct ParticleData <: AbstractField
    positions::Vector{SVec3d}
    velocities::Vector{SVec3d}
    properties::Dict{Symbol, Vector}
end

struct TimeEvolution{F <: AbstractField}
    eval_fn::Function         # t → F
    t_range::Tuple{Float64, Float64}
    dt_hint::Float64
end
```

### Domain Types

```julia
abstract type AbstractDomain end

struct BBox <: AbstractDomain
    min::SVec3d
    max::SVec3d
end

struct LatticeDomain <: AbstractDomain
    sites::Vector{SVec3d}     # or regular grid specification
    connectivity::Any         # optional
end

struct PeriodicDomain <: AbstractDomain
    unit_cell::BBox
    periods::SVec3{Int}
end
```

### Traits (opt-in capabilities)

```julia
# Traits unlock rendering features or optimizations
HasTimeEvolution(::Type{<:AbstractField}) = false
HasGradient(::Type{<:AbstractField}) = false
HasSymmetry(::Type{<:AbstractField}) = false
IsPeriodic(::Type{<:AbstractField}) = false
IsDifferentiable(::Type{<:AbstractField}) = false
```

### Voxelization: Fields → Grids

The bridge from protocol to renderer. Every field must become a VDB grid.

```julia
# Continuous fields: adaptive sampling
function voxelize(f::AbstractContinuousField;
                  voxel_size::Float64 = auto_from_characteristic_scale(f),
                  threshold::Float64 = 0.0,
                  max_refinement::Int = 3
                 )::Grid{Float32}

# Particle data: Gaussian splatting (already implemented)
function voxelize(p::ParticleData;
                  voxel_size::Float64, sigma::Float64, cutoff::Float64
                 )::Grid{Float32}

# Discrete fields: deposit onto grid
function voxelize(f::AbstractDiscreteField;
                  voxel_size::Float64, kernel=:gaussian
                 )::Grid{Float32}

# Users can define voxelize for custom types
```

### Visualization Dispatch

The user (or agent) selects a rendering strategy. Sensible defaults are provided.

```julia
# Default: voxelize → volume render
visualize(f::AbstractContinuousField; kwargs...)

# The agent can override the strategy
visualize(f::AbstractField, strategy::VolumeRender; kwargs...)
visualize(f::AbstractField, strategy::Isosurface; kwargs...)  # marching cubes → mesh → Makie
visualize(f::VectorField3D, strategy::FieldLines; kwargs...)  # RK4 → LineData → Makie
```

Note: strategies that produce non-volumetric output (isosurfaces, field lines, glyphs) generate data for Makie, not for Lyr's volume renderer. This is by design.

---

## Rendering Engine

### Quality Target

Rendered output should be comparable to Houdini Karma volume renders at equivalent sample counts. This is testable: render the same VDB in both and compare.

### v1.0 Rendering Stack (current state: ~86% complete)

| Component | Status | Description |
|-----------|--------|-------------|
| Delta tracking | Done (CPU + GPU) | Unbiased transmittance estimation |
| Ratio tracking | Done (CPU) | Variance-reduced shadow estimation |
| Transfer functions | Done | Blackbody, viridis, cool-warm, smoke, custom |
| Scene graph | Done | Cameras, lights, materials — lightweight Julia structs |
| Camera models | Done | Perspective, ortho |
| Denoising | Done | NLM + bilateral |
| Tonemapping | Done | HDR → LDR |
| PNG output | Done | Via standard Julia I/O |
| EXR output | Done (basic) | HDR + linear color |
| GPU delta tracking | Done | KernelAbstractions.jl kernel |

### Spatial Data Structures

| Component | Status | Description |
|-----------|--------|-------------|
| VDB read/write | Done | All versions, multi-grid, round-trip |
| NanoVDB | Done | GPU-optimized flat buffer |
| DDA traversal | Done | Hierarchical Amanatides-Woo |
| Grid builder | Done | `Dict{Coord,T}` → full VDB tree |
| Gaussian splatting | Done | Particles → density grid |
| ValueAccessor | Done | Cached tree traversal |

### Architecture Extension Point

The renderer is structured so that future hybrid rendering (volumes + procedural meshes) is possible without rewriting the core:

```julia
abstract type AbstractRenderable end

struct VolumeRenderable <: AbstractRenderable
    grid::NanoGrid
    transfer_function::TransferFunction
    material::VolumeMaterial
end

# Future — not v1.0:
# struct MeshRenderable <: AbstractRenderable ... end
```

The path integrator calls `intersect(ray, scene)` where the scene contains renderables. Today, all renderables are volumes. The interface permits extension.

---

## Agent Contract

The agent is the primary interface. This imposes concrete engineering requirements on Lyr's API:

### 1. Comprehensive Docstrings

Every public function must have a docstring that includes:
- One-line summary
- Argument types and semantics
- Return type
- Example usage
- Default values and their rationale

The docstring is the UI. It must be sufficient for an agent to generate correct code without hallucinating.

### 2. Informative Type Signatures

Type signatures must be specific enough that an agent can infer correct usage from the signature alone. Prefer `voxel_size::Float64` over `voxel_size` untyped.

### 3. Sensible Defaults

Every parameter must have a sensible default. `visualize(my_field)` must produce a reasonable image with zero configuration. The agent refines from defaults; it doesn't configure from scratch.

### 4. Presets Replace Wizards

Named presets for common configurations:
- `tf_blackbody`, `tf_viridis`, `tf_cool_warm` (transfer functions)
- `camera_orbit`, `camera_front`, `camera_iso` (camera positions)
- `material_cloud`, `material_emission`, `material_fire` (volume materials)
- `light_studio`, `light_natural`, `light_dramatic` (lighting setups)

### 5. Example Scripts

A curated `examples/` directory that the agent can reference:
- `hydrogen_orbital.jl` — QM wavefunction → volume render
- `md_particles.jl` — molecular dynamics → Gaussian splat → volume render
- `em_dipole.jl` — EM field → voxelized magnitude → volume render
- `lindblad_decay.jl` — time-dependent density matrix → animation
- `ising_model.jl` — discrete lattice → voxelized → volume render
- `heat_diffusion.jl` — PDE solution (via DifferentialEquations.jl) → volume render

These are scripts, not importable library code. They demonstrate the pattern: external solver → Field Protocol → Lyr render.

### 6. Error Messages

Error messages must be diagnostic. When a field fails to voxelize, the error should say why (e.g., "evaluate returned NaN at (x,y,z)" or "domain has zero volume") rather than surfacing a stack trace from the VDB internals. The agent reads error messages to self-correct.

---

## Compute Backend

Write once, run anywhere via KernelAbstractions.jl.

| Backend | Status | Performance |
|---------|--------|-------------|
| CUDA.jl (NVIDIA) | Production | ~2% overhead vs native CUDA C++ |
| AMDGPU.jl (AMD) | Supported | Via KernelAbstractions.jl |
| Metal.jl (Apple) | Supported | Via KernelAbstractions.jl |
| CPU threads | Fallback | Always works, no GPU required |

Performance-critical types use StaticArrays.jl (SVec3d, SMat3d) for zero-allocation math.

---

## Output Formats

| Format | Status | Use Case |
|--------|--------|----------|
| PNG | Done | Standard image output |
| EXR (basic) | Done | HDR, linear color, professional compositing |
| MP4/ProRes | Via FFMPEG.jl in scripts | Animation (agent writes the ffmpeg call) |
| VDB | Done | Grid interchange with other tools |
| HDF5/JLD2 | Via Julia packages | Data export |

---

## v1.0 Release Criteria

The following must be complete and tested for v1.0 (Julia General registry):

### Must Have

- [ ] VDB read/write (done)
- [ ] Delta tracking volume rendering, CPU + GPU (done)
- [ ] Ratio tracking shadow estimation (done, CPU)
- [ ] Transfer functions: blackbody, viridis, cool-warm, smoke, custom (done)
- [ ] Camera models: perspective, orthographic (done)
- [ ] Scene: cameras, lights, materials (done)
- [ ] NLM + bilateral denoising (done)
- [ ] Tonemapping (done)
- [ ] PNG + basic EXR output (done)
- [ ] Grid builder: `Dict{Coord,T}` → VDB tree (done)
- [ ] Gaussian splatting: particles → density grid (done)
- [ ] GPU delta tracking kernel via KA.jl (done)
- [ ] **Field Protocol**: `AbstractField`, `AbstractContinuousField`, `AbstractDiscreteField`, reference types, `evaluate`, `domain`, `fieldtype` (not started)
- [ ] **`voxelize`**: continuous field → VDB grid with adaptive sampling (not started)
- [ ] **`visualize`**: high-level entry point with sensible defaults (not started)
- [ ] **Example scripts**: ≥4 physics domains demonstrated (partial)
- [ ] **Docstrings**: every public function documented to agent-contract standard (partial)
- [ ] **10,000+ tests passing** (currently 10,410+)

### Not v1.0 (roadmap)

- Multi-scatter (global illumination in volumes)
- Spectral rendering (wavelength-dependent effects)
- Differentiable rendering via Enzyme.jl
- Deep EXR compositing
- Makie interactive viewport integration
- Procedural mesh rendering (isosurfaces, glyphs in Lyr's own renderer)
- Animation pipeline beyond scripted FFMPEG.jl
- ManifoldDomain for GR applications
- GPU ratio tracking kernel

---

## Success Metrics

### Technical

- **Render quality**: Side-by-side comparison with Houdini Karma on standard VDB test scenes (cloud, fire, explosion) produces visually comparable results at matched sample counts
- **Performance**: GPU rendering within 2× of equivalent C++/CUDA implementation on standard benchmarks
- **Correctness**: Field Protocol round-trip test — `voxelize(ScalarField3D(f, bbox, scale))` sampled at grid points matches `f` to floating-point tolerance

### Adoption

- Agent can generate correct Lyr scripts from natural-language physics descriptions without human intervention for the domains covered by example scripts
- Time from "describe physics intent" to "rendered image" is under 2 minutes for single-frame renders on consumer GPU
- Package registers in Julia General with zero vendored dependencies

### Ecosystem

- At least one external physics package produces Lyr-compatible field output (e.g., QuantumOptics.jl state → Lyr `ScalarField3D`)
- Example scripts cover ≥6 physics domains from the vision document

---

## Technical Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Adaptive voxelization performance for complex fields | Medium | Start with uniform sampling + refinement. Profile on real physics fields before optimizing. |
| Agent generates incorrect physics code | High | Not Lyr's problem to solve, but good error messages and example scripts reduce the failure rate. Lyr renders what it's given; correctness is the user's responsibility. |
| KernelAbstractions.jl portability gaps | Low | CPU fallback always works. Test on CUDA (primary), Metal (secondary). |
| Multi-scatter required for quality parity with Karma | Medium | Defer to post-v1.0. Single-scatter + good denoising is sufficient for most scientific visualization. |
| Enzyme.jl AD through GPU kernels is research-grade | High | Defer differentiable rendering to post-v1.0. Do not constrain rendering architecture for AD compatibility until Enzyme matures. |
| Field Protocol too rigid for unforeseen domains | Low | Open protocol + multiple dispatch means the community extends without Lyr's permission. Design for extensibility, not completeness. |

---

## Appendix: The Cognitive Distance Argument

The product thesis — *minimal cognitive distance from physics to pixels* — has three measurable gaps:

1. **Intent → Mathematics.** The user thinks "precessing hydrogen atom in a B-field." The mathematical formulation is the Lindblad master equation with a Zeeman Hamiltonian. This gap is physics knowledge. Lyr does not close it. The user or the agent does.

2. **Mathematics → Code.** The Lindblad equation must become a Julia script that produces field data Lyr can consume. This gap is API surface. The Field Protocol is Lyr's entire leverage on cognitive distance. The narrower and more natural this interface, the smaller this gap — for agents and humans.

3. **Code → Pixels.** The field data must become a production-quality image. This gap is rendering engineering. Sensible defaults, presets, and the agent handle it. The user should never think about transfer functions or sample counts unless they want to.

**Gap 2 is the only one Lyr controls, and it is the Field Protocol.** This is why the Field Protocol is the core product, not the renderer. The renderer is necessary but not differentiating — other tools render volumes. No other tool provides an open, agent-navigable protocol that bridges arbitrary physics computation to production-quality volumetric visualization in a composable, GPU-portable Julia package.

---

*PRD drafted: 2026-02-22*
*Derived from Socratic review of VISION.md*
