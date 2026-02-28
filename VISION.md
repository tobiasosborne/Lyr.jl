# VISION.md — Lyr.jl: Agent-Native Physics Visualization

> *"The purpose of visualization is insight, not pictures."* — Ben Shneiderman
>
> *"The best interface is no interface."* — Golden Krishna

**Goal**: A universal, scriptable physics simulation and visualization platform — covering all of physics, from Newtonian mechanics through GR — where the primary interaction surface is natural language via AI agent, not a GUI.

---

## The Core Thesis: No GUI

### The Insight

Every major visualization tool — Blender, COMSOL, ParaView, Houdini, Fusion 360, ANSYS — invests the majority of its engineering effort in a graphical user interface. The GUI exists because humans need visual affordances (buttons, menus, sliders, node graphs) to navigate complex parameter spaces. This is enormously expensive to build and enormously expensive to learn.

But we discovered something working on hydrogen orbital visualizations: **describing what we wanted to an AI agent was far faster than learning any GUI could ever be.** The agent knows the API. The agent knows the physics. The agent knows the rendering parameters. The human just says what they want.

This inverts the fundamental engineering equation:

| Traditional Tool | Lyr.jl |
|-----------------|--------|
| 80% GUI engineering, 20% engine | 0% GUI, 100% engine + API |
| Months to learn the interface | Zero learning curve |
| Mouse-driven, menu-heavy | Natural language + code |
| Rigid workflow imposed by UI designers | Fully composable, infinitely flexible |
| Non-reproducible (click sequences) | Fully reproducible (scripts) |

### Why This Works Now

1. **AI agents can navigate APIs fluently.** An agent reads documentation, understands type signatures, and writes correct Julia code on the first try. It navigates a 500-function API faster than any human navigates a menu system.

2. **Code-first tools already won.** LaTeX beat Word for technical documents. ggplot beat Excel for data visualization. Terraform beat cloud consoles for infrastructure. The pattern is clear: code-first tools produce better results and are more composable. Their only weakness was the learning curve. Natural language eliminates it.

3. **Julia's composability is the key enabler.** Multiple dispatch means physics modules, rendering engines, and output formats compose without glue code. An agent can mix and match components from across the ecosystem in a single script.

4. **The output is visual, the input is not.** We're not eliminating visual feedback — the rendered images, animations, and interactive Makie viewports are the output. We're eliminating the GUI as the *input* mechanism. The agent writes the script; Lyr renders the result; the human evaluates the image and iterates in natural language.

### The Precedent

This is the same shift that happened in software engineering itself. Professional developers don't use visual programming tools — they write code, mediated increasingly by AI agents. Lyr extends this pattern to physics visualization: the "IDE" is the conversation, the "compiler" is the rendering engine.

---

## Scope: All of Physics

Lyr.jl aims to visualize any physical phenomenon. Not by implementing every simulation — the Julia ecosystem already has extraordinary solvers — but by providing the visualization substrate that any physics computation can render through.

### Domain Coverage

| Domain | What to Visualize | Key Data Types |
|--------|-------------------|----------------|
| **Classical Mechanics** | Trajectories, phase space, rigid body motion, springs, pendulums, orbital mechanics | Particle systems, vector fields |
| **Electromagnetism** | E/B fields, dipole radiation, antenna patterns, waveguides, EM waves, Poynting vectors | Vector fields, scalar potentials |
| **Quantum Mechanics** | Wavefunctions, probability densities, orbitals, tunneling, spin states, entanglement | Complex scalar fields, |psi|^2 |
| **Statistical Mechanics** | Ising models, phase transitions, Monte Carlo configurations, partition function landscapes | Lattice data, order parameters |
| **Thermodynamics** | Heat diffusion, convection cells, entropy fields, phase diagrams | Scalar fields, time series |
| **Fluid Dynamics** | Navier-Stokes solutions, vorticity, turbulence, multiphase flow, boundary layers | Velocity/pressure/vorticity fields |
| **General Relativity** | Spacetime curvature, geodesics, gravitational lensing, black hole shadows, frame dragging | Tensor fields, geodesic paths |
| **Condensed Matter** | Crystal structures, band structure, Fermi surfaces, phonon modes, electron density | Periodic fields, isosurfaces |
| **Optics** | Ray diagrams, interference, diffraction, polarization, photonic crystals, metamaterials | Intensity/phase fields |
| **Plasma Physics** | MHD equilibria, magnetic reconnection, tokamak cross-sections, particle-in-cell | Vector fields, particle data |
| **Astrophysics** | N-body simulations, accretion disks, galaxy formation, cosmic web, CMB anisotropy | Particle systems, large-scale fields |
| **Nuclear/Particle** | Detector event displays, shower development, Feynman diagrams, nuclear wavefunctions | Track/hit data, probability densities |

### What We Already Have

The hydrogen orbital scripts proved the concept end-to-end:
- Analytical quantum wavefunctions (Laguerre polynomials, spherical harmonics)
- Density matrix evolution via Lindblad master equation
- Larmor precession with spontaneous decay
- Gaussian splatting of probability density onto VDB grids
- Monte Carlo delta tracking volume rendering
- 1800-frame animations with proper physics

The MD spring demo proved particle-to-volume:
- 1000 particles with harmonic interactions
- Velocity Verlet integration
- Gaussian splatting to density field
- Full render pipeline to PNG

These are not toy demos. They are the pattern that scales to every domain.

---

## Architecture

### The Stack

```
┌─────────────────────────────────────────────────────────────┐
│                    Agent Interaction Layer                    │
│                                                              │
│  Natural language → Julia script generation                  │
│  The agent IS the UI. No menus, no buttons, no learning curve│
│  Makie viewports for interactive visual feedback             │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│                    Physics Modules                            │
│                                                              │
│  Each module: domain types + solvers + field output           │
│  Modules produce fields that implement the Field Protocol     │
│                                                              │
│  Classical  EM  QM  StatMech  Fluids  GR  CondMat  Optics   │
│  ────────  ──  ──  ────────  ──────  ──  ───────  ──────    │
│  Particles E,B  ψ  Lattice   v,p,ω  g_μν Bands   I,φ       │
│  Forces   Wave  ρ  Spins    Vortex  Γ   Fermi   Rays       │
│  Orbits   Ant.  H  Phase    Turb.   κ   Phonon  Diff.      │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│                    Field Protocol                             │
│                                                              │
│  The universal interface between physics and visualization    │
│                                                              │
│  ScalarField3D    f(x,y,z) → Float64                        │
│  VectorField3D    f(x,y,z) → SVec3d                         │
│  TensorField3D    f(x,y,z) → SMatrix                        │
│  ParticleData     positions + velocities + properties        │
│  LineData         trajectories, field lines, geodesics       │
│  TimeEvolution    t → Field (animation)                      │
│                                                              │
│  + Domain specification (bounding box, resolution, symmetry) │
│  + Adaptive sampling (detect structure, refine where needed) │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│                  Visualization Primitives                     │
│                                                              │
│  Volume Rendering     Scalar fields → density/emission       │
│  Isosurface           Level set extraction (marching cubes)  │
│  Field Lines          Vector field integration (RK4)         │
│  Streamlines          Time-dependent vector field paths       │
│  Glyph Rendering      Arrows, tensors, hedgehog plots        │
│  Particle Rendering   Point clouds, trails, halos            │
│  Surface Rendering    Meshes, implicit surfaces              │
│  Annotation           Axes, colorbars, labels, legends       │
│  Compositing          Multi-layer, multi-field overlay       │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│                  Rendering Engines                            │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │  Preview      │  │  Production  │  │  Interactive │       │
│  │  (Fast)       │  │  (Path Trace)│  │  (Makie)     │       │
│  │               │  │              │  │              │       │
│  │ Absorption    │  │ Delta track  │  │ Progressive  │       │
│  │ MIP           │  │ Ratio track  │  │ refinement   │       │
│  │ Isosurface    │  │ Multi-scatter│  │ Live rotate  │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
│                                                              │
│  Transfer functions, phase functions, materials, lighting    │
│  Denoising (NLM, bilateral)                                  │
│  Camera models (perspective, ortho, panoramic, fisheye)      │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│              Spatial Data Structures                          │
│                                                              │
│  VDB Tree       Hierarchical sparse volumes (read/write)     │
│  NanoVDB        GPU-optimized flat buffer (KA.jl portable)   │
│  Grid Builder   Dict{Coord,T} → full VDB tree               │
│  Particles      Gaussian splatting, point-to-density         │
│  DDA            Amanatides-Woo traversal, hierarchical       │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│                  Compute Backend                              │
│                                                              │
│  KernelAbstractions.jl  (write once, run anywhere)           │
│  ├── CUDA.jl            (NVIDIA — ~2% overhead vs C++)       │
│  ├── AMDGPU.jl          (AMD)                                │
│  ├── Metal.jl           (Apple)                              │
│  └── CPU threads        (fallback, always works)             │
│                                                              │
│  StaticArrays.jl        (SVec3d, SMat3d — zero alloc)        │
│  Enzyme.jl              (AD through GPU kernels)             │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│                    Output Layer                               │
│                                                              │
│  Images     PNG, EXR (HDR + deep compositing), TIFF          │
│  Video      MP4, ProRes via FFMPEG.jl                        │
│  Data       VDB files, HDF5, JLD2                            │
│  Interactive Makie viewports, Pluto notebooks                 │
└──────────────────────────────────────────────────────────────┘
```

### The Field Protocol — The Critical Interface

The Field Protocol is what makes Lyr universal. Any physics module that can produce one of these types can be visualized:

```julia
# The protocol — physics modules implement these
abstract type AbstractField end

struct ScalarField3D <: AbstractField
    evaluate::Function        # (x,y,z) → Float64
    domain::BBox              # Spatial extent
    characteristic_scale::Float64  # Hint for adaptive sampling
end

struct VectorField3D <: AbstractField
    evaluate::Function        # (x,y,z) → SVec3d
    domain::BBox
    characteristic_scale::Float64
end

struct TensorField3D <: AbstractField
    evaluate::Function        # (x,y,z) → SMatrix{3,3}
    domain::BBox
    characteristic_scale::Float64
end

struct ParticleData <: AbstractField
    positions::Vector{SVec3d}
    velocities::Vector{SVec3d}     # optional
    properties::Dict{Symbol, Vector}  # :mass, :charge, :spin, ...
end

struct LineData <: AbstractField
    lines::Vector{Vector{SVec3d}}  # trajectories, field lines
    properties::Dict{Symbol, Vector}  # per-line metadata
end

# Time evolution wraps any field
struct TimeEvolution{F <: AbstractField}
    evaluate::Function        # t → F
    t_range::Tuple{Float64, Float64}
    dt_hint::Float64          # Suggested time step
end
```

**The key insight**: Lyr doesn't need to know about Hamiltonians, Maxwell's equations, or Einstein's field equations. It only needs to know about fields, particles, and lines. The physics module computes the physics; Lyr visualizes the result. This is a clean separation of concerns that scales to every domain.

### Voxelization: Fields to Grids

The bridge between continuous physics and discrete rendering:

```julia
# Adaptive voxelization — sample where the field has structure
function voxelize(field::ScalarField3D;
                  voxel_size::Float64 = auto,
                  threshold::Float64 = 0.0,
                  max_depth::Int = 3       # adaptive refinement levels
                  ) → Grid{Float32}

# Particle splatting — already implemented
function gaussian_splat(particles::ParticleData;
                        voxel_size, sigma, cutoff) → Dict{Coord, Float32}

# Field line tracing — RK4 integration through vector field
function trace_field_lines(field::VectorField3D;
                           seeds::Vector{SVec3d},
                           step_size, max_steps) → LineData
```

---

## The Agent Workflow

### How It Works in Practice

**User**: "Show me the electric field of a dipole antenna at 2.4 GHz, with the radiation pattern visible."

**Agent** (writes and executes):
```julia
using Lyr

# Physics: compute the E-field
antenna = HertzDipole(frequency=2.4e9, current=1.0, orientation=[0,0,1])
E_field = electric_field(antenna)

# Voxelize the field magnitude for volume rendering
E_mag = ScalarField3D(
    (x,y,z) -> norm(E_field.evaluate(x,y,z)),
    BBox((-0.5,-0.5,-0.5), (0.5,0.5,0.5)),
    0.01  # wavelength-scale features
)
grid = voxelize(E_mag, voxel_size=0.002)

# Render with a physics-appropriate transfer function
scene = Scene(
    camera = Camera((1.5, 1.0, 1.5), (0,0,0), (0,0,1), 45.0),
    volumes = [VolumeEntry(grid, material=VolumeMaterial(
        transfer_function = tf_cool_warm,
        sigma_scale = 200.0
    ))],
    lights = [DirectionalLight((1,1,1), (1,1,1))]
)
img = render_volume_image(scene, 1920, 1080, spp=64)
write_png("dipole_2.4GHz.png", tonemap_aces(img))
```

**User**: "Make the field lines visible too, and animate the wave propagation over one period."

**Agent** (extends the script with field line tracing and time evolution).

### Why This Is Faster Than Any GUI

1. **No mode switching.** In Blender/COMSOL, you context-switch between menus, property panels, viewport navigation, and render settings. With an agent, you just *describe* what you want.

2. **No parameter hunting.** "Make the clouds more wispy" in Houdini means finding the right node, the right parameter, and the right value range. The agent knows that means reducing `sigma_scale` and increasing `cutoff_sigma`.

3. **Instant composition.** "Now overlay the magnetic field lines" is one sentence. In a GUI, it's a whole new layer/object/material setup.

4. **Reproducible by construction.** Every visualization is a script. Share it, version it, parameterize it, batch it. GUI workflows produce images; code-first workflows produce *processes*.

5. **Domain expertise built in.** The agent knows that quantum probability densities need log-scale transfer functions, that EM fields need vector visualization, that GR needs embedding diagrams. A generic GUI knows none of this.

---

## What Lyr Competes With

This is not a modest project. Here is the competitive landscape and where Lyr fits:

| Tool | Strength | Lyr's Advantage |
|------|----------|-----------------|
| **COMSOL** | Multi-physics FEA + visualization | No $50K/year license. Scriptable. Open. Composable with Julia ecosystem |
| **ParaView** | HPC-scale scientific visualization | Production-quality rendering. Physics-aware. Agent-mediated |
| **Blender** | Artistic 3D + Cycles path tracer | Physics-native. No GUI learning curve. Scriptable end-to-end |
| **Houdini** | Procedural VFX + VDB native | Open source. Julia-native. Agent-mediated. Scientific computing |
| **ANSYS/Abaqus** | Engineering simulation + viz | Julia composability. Open. Differentiable |
| **Mathematica** | Symbolic computation + plotting | GPU rendering. Volume visualization. Production quality |
| **Makie.jl** | Julia-native plotting | Path-traced volumes. Production rendering. Physics modules |
| **VMD/OVITO** | Molecular visualization | Universal physics. Not limited to molecular dynamics |

**Lyr's unique position**: the only tool that combines production-quality rendering, universal physics coverage, full scriptability, GPU portability, differentiability, and agent-mediated interaction — all in one composable, open-source Julia package.

---

## The Landscape — What the Best Do

### Production Rendering (quality reference)

| Renderer | Key Technique | Relevance to Lyr |
|----------|--------------|-------------------|
| **RenderMan XPU** (Pixar) | Hybrid CPU+GPU path-traced volumes, ML denoiser | Quality target for volume rendering |
| **Karma XPU** (SideFX) | Native VDB, MaterialX volumes | VDB-native workflow model |
| **MoonRay** (DreamWorks) | Open source MCRT, distributed rendering | Architecture reference |
| **Cycles** (Blender) | Null-scattering volumes, NanoVDB | Open source GPU volume rendering |

### Scientific Visualization (feature reference)

| Tool | Strength | Gap Lyr Fills |
|------|----------|---------------|
| **ParaView** | Petascale distributed rendering | No production-quality path tracing |
| **VisIt** | HPC data formats | No GPU portability |
| **3D Slicer** | Medical volumes | Domain-specific, no general physics |
| **Beyond ExaBricks** | 16 FPS path-traced AMR on RTX 4090 | Research prototype, not a platform |

### Emerging Methods

- **3D Gaussian Splatting** (SIGGRAPH 2023): real-time radiance fields, complementary to VDB
- **fVDB** (NVIDIA): differentiable VDB for PyTorch — Lyr does this for Julia
- **NeuralVDB**: 100x compression via neural networks — future integration target
- **SVRaster** (CVPR 2025): Gaussian splatting + structured volumetric grids

---

## The Julia Ecosystem — Why Julia

### GPU Computing (production-ready)

| Package | Status | Performance |
|---------|--------|-------------|
| **CUDA.jl** | Production | ~2% overhead vs native CUDA C++ |
| **KernelAbstractions.jl** | Production | Write once, run on CUDA/ROCm/Metal/oneAPI/CPU |
| **AcceleratedKernels.jl** | Production | GPU-portable sort/reduce/scan |

### Scientific Computing (Lyr's composability advantage)

| Package | What It Gives Lyr |
|---------|-------------------|
| **DifferentialEquations.jl** | ODE/PDE solvers for physics modules |
| **Enzyme.jl** | AD through GPU rendering kernels — inverse problems |
| **Flux.jl / Lux.jl** | ML-enhanced rendering, neural fields |
| **Optim.jl** | Parameter optimization in visualization loops |
| **Makie.jl** | Interactive viewports for live feedback |
| **StaticArrays.jl** | Zero-alloc Vec3/Mat3 — rendering's bread and butter |
| **LinearAlgebra** (stdlib) | Eigenvalues, SVD, matrix ops for physics |
| **SpecialFunctions.jl** | Bessel, Legendre, spherical harmonics |

### Performance Reality

- **GPU**: Julia matches C++ via CUDA.jl — essentially free abstraction
- **CPU**: ~1.5x slower than SIMD-optimized C++ (with optimization room)
- **Composability**: This is the killer advantage. No FFI boundaries, no serialization, no language switching. Physics code, GPU kernels, AD, optimization, and rendering all in one language, all composable via multiple dispatch.

---

## Build Phases

### Phase 1: Foundation — COMPLETE

VDB parser, writer, DDA traversal, NanoVDB flat layout. 29,500+ tests passing.

| Component | Status |
|-----------|--------|
| VDB Read (all versions, multi-grid) | Done |
| VDB Write (round-trip) | Done |
| Hierarchical DDA traversal | Done |
| NanoVDB GPU-ready flat buffer | Done |
| ValueAccessor with caching | Done |
| Coordinate transforms | Done |

### Phase 2: Volume Renderer — COMPLETE

| Component | Status |
|-----------|--------|
| Delta tracking (CPU + GPU) | Done |
| Ratio tracking shadows | Done |
| Transfer functions (blackbody, viridis, cool-warm, smoke) | Done |
| Scene graph (cameras, lights, materials) | Done |
| PNG output | Done |
| EXR output (basic) | Done |
| NLM + bilateral denoising | Done |
| Grid builder (Dict → VDB tree) | Done |
| Gaussian splatting (particles → density) | Done |
| GPU delta tracking kernel (KA.jl) | Done |
| Deep EXR compositing | Not started |
| Multi-scatter | Not started |

### Phase 3: Field Protocol — COMPLETE

The interface between physics and visualization.

| # | Component | Status |
|---|-----------|--------|
| 1 | **Field types** (ScalarField3D, VectorField3D, ComplexScalarField3D, ParticleField, TimeEvolution) | Done |
| 2 | **Adaptive voxelization** (Field → VDB grid with automatic resolution) | Done |
| 3 | **One-call visualization** (`visualize(field)` with sensible defaults) | Done |
| 4 | **Camera/material/light presets** (orbit, front, iso, emission, cloud, fire) | Done |

### Phase 4: Full VDB Operations — IN PROGRESS

Closing the grid-operations gap with OpenVDB while preserving Lyr's idiomatic Julia architecture (immutable trees, functional construction, multiple dispatch). ~43 issues tracked in beads.

| Subphase | Components | Status |
|----------|-----------|--------|
| 4.1 Foundation Utilities | Write w/ compression, half-precision, changeBackground, activate/deactivate, iterators, copyToDense/FromDense, level set primitives, Vec3i | In progress |
| 4.2 Particle Operations | particles_to_sdf, particle_trails_to_sdf, enhanced ParticleField, point advection | Not started |
| 4.3 Grid Combinators | CSG (union/intersection/difference), compositing (max/min/sum/mul/replace), clipping, pruning | In progress |
| 4.4 Differential Operators | Stencils, gradient, divergence, curl, laplacian, mean curvature, magnitude/normalize | Not started |
| 4.5 Level Set Tools | sdf_to_fog, interior mask, isosurface mask, area/volume/genus, dilate/erode, diagnostics | Not started |
| 4.6 Mesh Conversion | Marching cubes (volume_to_mesh) | Not started |
| 4.7 Filtering & Advanced | Mean/Gaussian filter, tricubic interpolation, resampling | Not started |

### Phase 5: Physics Modules — NOT STARTED

Each module is a self-contained package that produces fields Lyr can visualize.

| # | Module | Priority | Key Capabilities |
|---|--------|----------|-----------------|
| 1 | **LyrQuantum** | P1 (proven) | Wavefunctions, orbitals, density matrices, tunneling |
| 2 | **LyrClassical** | P1 (proven) | Particles, springs, orbits, rigid bodies |
| 3 | **LyrEM** | P1 | Coulomb, dipoles, antennas, EM waves, waveguides |
| 4 | **LyrFluids** | P2 | Navier-Stokes viz (via DifferentialEquations.jl), vorticity |
| 5 | **LyrStatMech** | P2 | Ising, lattice gas, phase transitions, MC sampling |
| 6 | **LyrGR** | P2 | Schwarzschild, Kerr, geodesics, lensing, curvature |
| 7 | **LyrCondMat** | P3 | Crystal structures, band structure, Fermi surfaces |
| 8 | **LyrOptics** | P3 | Ray/wave optics, interference, diffraction |
| 9 | **LyrPlasma** | P3 | MHD, magnetic topology, particle-in-cell |
| 10 | **LyrAstro** | P4 | N-body, accretion disks, cosmological structure |

### Phase 6: Production Quality

| # | Component | What | Why |
|---|-----------|------|-----|
| 1 | **Multi-scatter** | Full global illumination in volumes | Production rendering quality |
| 2 | **Spectral rendering** | Wavelength-dependent effects | Dispersion, fluorescence, Cherenkov |
| 3 | **Differentiable rendering** | Enzyme.jl gradients through renderer | Inverse problems, parameter fitting |
| 4 | **Animation pipeline** | FFMPEG.jl video output, motion blur | Publication/presentation output |
| 5 | **Makie integration** | Interactive 3D viewports | Live feedback for agent workflow |
| 6 | **Deep EXR** | Multi-layer compositing | Professional post-production |

---

## Key Architectural Decisions

### 1. No GUI — Agent-Native Design

The interaction surface is natural language + Julia code. The agent writes scripts that call Lyr's API. This means:
- **API design is UI design.** Every function must have sensible defaults, clear naming, and composable interfaces.
- **Documentation is the interface.** Thorough docstrings are more important than any widget.
- **Presets replace wizards.** `tf_blackbody`, `camera_orbit`, `material_cloud` replace configuration dialogs.
- **Scripts replace sessions.** Every visualization is reproducible, versionable, and shareable.

### 2. The Field Protocol, Not the Physics

Lyr does not simulate physics. It visualizes fields. The separation is absolute:
- Physics modules compute fields (wavefunctions, E-fields, fluid velocities, curvature tensors)
- Lyr receives fields via the Field Protocol and renders them
- This means Lyr never becomes a bottleneck for new physics domains — anyone can write a module

### 3. KernelAbstractions.jl for GPU Portability

Write kernels once, run on NVIDIA/AMD/Apple/Intel/CPU. Already proven with the delta tracking kernel.

### 4. Multiple Dispatch for Domain Specialization

```julia
# The visualization layer dispatches on field type
visualize(f::ScalarField3D)   # volume rendering
visualize(f::VectorField3D)   # field lines + glyphs
visualize(f::TensorField3D)   # tensor ellipsoids
visualize(p::ParticleData)    # point cloud + trails
visualize(l::LineData)        # line rendering

# Physics modules dispatch on domain types
electric_field(d::Dipole)     # analytical
electric_field(c::ChargeDistribution)  # numerical
```

### 5. Composability Over Completeness

Lyr should compose naturally with the Julia ecosystem rather than reimplementing functionality:
- Use DifferentialEquations.jl for ODE/PDE solving, not custom solvers
- Use SpecialFunctions.jl for Bessel/Legendre/etc., not custom implementations
- Use Makie.jl for interactive viewports, not a custom windowing system
- Use Enzyme.jl for AD, not custom derivative code

### 6. Production Quality as the Standard

Every rendering technique should aim for SOTA quality. We're competing with Houdini's output quality, not Matplotlib's. This means:
- Monte Carlo path tracing with null-collision methods (not biased ray marching)
- Proper denoising (NLM, bilateral — already implemented)
- HDR output with professional tonemapping
- Physical camera models (depth of field, motion blur)

---

## What NOT to Build

- **A GUI.** Not now, not ever. The agent is the interface.
- **Physics solvers.** Use DifferentialEquations.jl, NBodySimulator.jl, etc. Lyr visualizes; it doesn't simulate.
- **A full USD scene graph.** Too heavy. Keep the scene description lightweight and Julia-native.
- **OptiX interop.** Closed source, NVIDIA-only, can't access HW RT cores from Julia.
- **A package manager.** Julia's Pkg.jl is excellent. Physics modules are regular Julia packages.

---

## What Makes This Unprecedented

No tool in existence combines all of these:

1. **Universal physics coverage** — from QM to GR in one platform
2. **Production-quality rendering** — Monte Carlo path tracing, not toy ray marching
3. **GPU-portable** — same code runs on NVIDIA, AMD, Apple, Intel, CPU
4. **Differentiable** — AD through the entire rendering pipeline
5. **Zero GUI** — natural language interaction via agent
6. **Fully scriptable** — every visualization is reproducible code
7. **Composable** — plugs into Julia's entire scientific computing ecosystem
8. **Open source** — no $50K/year COMSOL license

The insight that killed the GUI is the same insight that makes this possible: when the interface is an intelligent agent that speaks both physics and code, the only thing that matters is the quality of the engine and the elegance of the API.

---

## References

### Rendering
- [Production Volume Rendering (SIGGRAPH 2017)](https://graphics.pixar.com/library/ProductionVolumeRendering/paper.pdf)
- [Monte Carlo Methods for Volumetric Light Transport (Novak et al. 2018)](https://cs.dartmouth.edu/~wjarosz/publications/novak18monte.pdf)
- [Progressive Null-Tracking (SIGGRAPH 2023)](https://cs.dartmouth.edu/~wjarosz/publications/misso23progressive.html)
- [Deep Compositing (Pixar)](https://graphics.pixar.com/library/DeepCompositing/)

### VDB Ecosystem
- [OpenVDB](https://www.openvdb.org/)
- [NanoVDB (NVIDIA)](https://developer.nvidia.com/nanovdb)
- [fVDB (NVIDIA, open source)](https://developer.nvidia.com/fvdb)

### Julia Ecosystem
- [CUDA.jl](https://github.com/JuliaGPU/CUDA.jl) — [~2% overhead vs C++](https://developer.nvidia.com/blog/gpu-computing-julia-programming-language/)
- [KernelAbstractions.jl](https://github.com/JuliaGPU/KernelAbstractions.jl)
- [DifferentialEquations.jl](https://github.com/SciML/DifferentialEquations.jl)
- [Enzyme.jl](https://github.com/EnzymeAD/Enzyme.jl)
- [Makie.jl](https://github.com/MakieOrg/Makie.jl)
- [StaticArrays.jl](https://github.com/JuliaArrays/StaticArrays.jl)
- [Raycore.jl](https://makie.org/website/blogposts/raycore/)

### Scientific Visualization
- [ParaView](https://www.paraview.org/)
- [Beyond ExaBricks: GPU Volume Path Tracing of AMR Data (CGF 2024)](https://onlinelibrary.wiley.com/doi/10.1111/cgf.15095)

---

*Vision revised: 2026-02-28*
*Original document: 2026-02-14*
*The GUI is dead. Long live the agent.*
