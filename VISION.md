# VISION.md — Lyr.jl: A Julia-Native Volumetric Visualization Pipeline

> *"The purpose of visualization is insight, not pictures."* — Ben Shneiderman

**Goal**: Build a differentiable, GPU-portable VDB volume renderer for scientific computing, inverse problems, and production-quality visualization — entirely in Julia.

---

## The Landscape — What the Best Do

### Production Film Renderers (the gold standard)

| Renderer | Studio | Key Volume Technique |
|----------|--------|---------------------|
| **RenderMan XPU** | Pixar | Hybrid CPU+GPU path-traced volumes, ML denoiser, interior volume aggregates (v27, Nov 2025) |
| **Hyperion** | Disney | Sorted-batch spectral path tracer, full path-traced water volumes, batch-coherent volume marching |
| **Manuka** | Weta FX | Bidirectional spectral path tracer, Hero Spectral Sampling, photon-mapped volumes |
| **MoonRay** | DreamWorks | **Open source** (Apache 2.0), Academy Award-winning MCRT, Arras distributed rendering |
| **Karma XPU** | SideFX/Houdini | Hybrid CPU+GPU, native VDB, MaterialX volume shaders, production-gold since 2024 |
| **Arnold** | Autodesk | Volume step / shadow linking, VDB first-class |

**Common thread**: All use **Monte Carlo path tracing** with **null-collision methods** (delta/ratio/spectral tracking) for unbiased free-flight sampling in heterogeneous media. Output: **OpenEXR deep images** for compositing.

### Open Source Renderers

| Project | Strength | Weakness |
|---------|----------|----------|
| **Blender Cycles** | Full path tracer, VDB via NanoVDB, GPU (OptiX/HIP), null-scattering volumes (4.2+) | Not a library, hard to embed |
| **MoonRay** | Production-proven, open-sourced, USD Hydra delegate | C++ monolith, steep learning curve |
| **OSPRay** (Intel) | CPU ray tracing, scientific viz, OpenImageDenoise | Intel-centric, limited GPU |
| **pbrt-v4** | Reference implementation of PBRT book | Educational, not production-speed |

### Scientific Visualization

- **ParaView** and **VisIt**: distributed rendering for petascale HPC datasets
- **NVIDIA IndeX**: GPU-accelerated volume rendering as ParaView plugin
- **3D Slicer / ITK**: medical volume ray casting with transfer functions
- **Beyond ExaBricks** (CGF 2024): 16 FPS path-traced global illumination of AMR data on a single RTX 4090

### Emerging: Neural & Gaussian Methods

- **3D Gaussian Splatting** (SIGGRAPH 2023): real-time radiance field rendering, complementary to VDB
- **NeuralVDB** (NVIDIA): 100x compression via hierarchical neural networks replacing lower tree nodes
- **fVDB** (NVIDIA, open source): differentiable VDB primitives for PyTorch (convolution, pooling, ray-tracing, meshing)
- **ZibraVDB**: 100x compressed real-time VDB playback in Unreal Engine
- **SVRaster** (CVPR 2025): combining Gaussian splatting efficiency with structured volumetric grids

---

## The Julia Ecosystem — What We Have

### GPU Computing (mature, production-ready)

| Package | Status | Performance |
|---------|--------|-------------|
| **CUDA.jl** | Production-ready | ~2% overhead vs native CUDA C++ (NVIDIA benchmarks) |
| **KernelAbstractions.jl** | Production-ready | Write once, run on CUDA/ROCm/Metal/oneAPI/CPU |
| **AcceleratedKernels.jl** (2025) | Production-ready | GPU-portable sort/reduce/scan; adopted as official AMDGPU backend; 538-855 GB/s sorting on 200 A100s |
| **AMDGPU.jl** | General use | Somewhat behind CUDA.jl |
| **Metal.jl** | Functional | May have bugs, suboptimal perf |
| **oneAPI.jl** | Functional | May have bugs, suboptimal perf |
| **Vulkan.jl** | Experimental (v0.6) | Not production-ready |

### Rendering (early but active)

| Project | Status | Capabilities |
|---------|--------|-------------|
| **Raycore.jl** (Nov 2025) | Active development | BVH ray-triangle intersection, CPU+GPU via KA; 0.01us/hit for 1.9M triangles |
| **Hikari** (upcoming) | Pre-release | Full path tracing framework built on Raycore, for Makie |
| **Makie.jl** | Production (viz) | Volume rendering: absorption, MIP, additive — visualization-quality, not production |
| **RayTracer.jl** | Research | Differentiable ray tracing |

### Performance Reality Check

- **GPU**: Julia matches C++ via CUDA.jl — essentially free abstraction
- **CPU ray tracing**: Julia ~1.5x slower than SIMD-optimized C++ (with optimization room)
- **LoopVectorization.jl**: deprecated (Julia 1.11+); successor LoopModels not yet stable
- **StaticArrays.jl**: zero-alloc Vec3/Color3 — exactly what rendering needs
- **Enzyme.jl**: automatic differentiation of GPU kernels — unique advantage

---

## Strategic Position

**The gap nobody fills:**

| Who | What They Have | What They Lack |
|-----|---------------|----------------|
| Film studios | RenderMan, Hyperion, MoonRay | Differentiability, scriptability, scientific computing |
| Game engines | NanoVDB + OptiX/Vulkan | Scientific computing, AD, composability |
| Scientific viz | ParaView + OSPRay | Production-quality rendering, GPU portability |
| ML research | fVDB (PyTorch) | Not Julia, not composable with DiffEq/Optim |

**Lyr's unique value**: the only tool that does all of this in one language:
- Read/write VDB
- GPU volume path tracing (KernelAbstractions.jl — ~2% overhead vs CUDA C++)
- Differentiable rendering (Enzyme.jl on GPU kernels)
- Plugs into DifferentialEquations.jl, Flux.jl, Optim.jl, Makie.jl

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     User-Facing Layer                       │
│                                                             │
│  Lyr.Studio     Interactive viewer (Makie-based)            │
│  Lyr.CLI        Command-line render tool                    │
│  Lyr.Notebook   Jupyter/Pluto integration                   │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│                    Scene Description                        │
│                                                             │
│  Scene graph, cameras, lights, materials, animation         │
│  Transfer functions (density → color/opacity)               │
│  Phase functions (Henyey-Greenstein, Rayleigh)              │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│                  Rendering Engines                          │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  Preview      │  │  Production  │  │  Interactive │      │
│  │  (Rasterize)  │  │  (Path Trace)│  │  (Hybrid)    │      │
│  │              │  │              │  │              │      │
│  │ Absorption   │  │ Delta track  │  │ Progressive  │      │
│  │ MIP          │  │ Ratio track  │  │ refinement   │      │
│  │ Isosurface   │  │ Multi-scatter│  │ Denoise      │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                             │
│  All engines share: VolumeRayIntersector (DDA traversal)    │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│              Spatial Data Structures                        │
│                                                             │
│  Lyr.jl          VDB read/write (parser complete)           │
│  NanoVDB.jl      GPU-optimized flat VDB (cache-friendly)    │
│  BVH.jl          Bounding volume hierarchy (mesh+volume)    │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│                   VDB Operations                            │
│                                                             │
│  Create    Mesh→SDF, points→density, noise→clouds           │
│  Transform CSG (union/intersect/diff), filter, resample     │
│  Animate   Advect, morph, time-interpolate                  │
│  Write     VDB file output (round-trip)                     │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│                  Compute Backend                            │
│                                                             │
│  KernelAbstractions.jl  (write once, run anywhere)          │
│  ├── CUDA.jl            (NVIDIA)                            │
│  ├── AMDGPU.jl          (AMD)                               │
│  ├── Metal.jl           (Apple)                             │
│  └── CPU threads        (fallback)                          │
│                                                             │
│  StaticArrays.jl        (Vec3, Color3, Mat4)                │
│  AcceleratedKernels.jl  (sort, reduce, scan on GPU)         │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│                    Output Layer                             │
│                                                             │
│  OpenEXR.jl     HDR + deep compositing output               │
│  PNG/TIFF       Standard image formats                      │
│  FFMPEG.jl      Video encoding (MP4, ProRes)                │
│  Makie          Interactive display                          │
└─────────────────────────────────────────────────────────────┘
```

---

## Build Phases

### Phase 1: Foundation (current → next)

Lyr.jl parser is working: 920 tests, all VDB files parse correctly.

| # | Component | What | Why |
|---|-----------|------|-----|
| 1 | **VDB Writer** | Round-trip read/write | Enables VDB creation, closes the loop |
| 2 | **VolumeRayIntersector** | DDA traversal through VDB tree | Fixes node boundary artifacts permanently; the single most impactful piece |
| 3 | **NanoVDB layout** | Flatten VDB tree into GPU-friendly linear memory | Same topology, flat arrays instead of pointers — the key NanoVDB insight |

### Phase 2: Production Volume Renderer

| # | Component | What | Why |
|---|-----------|------|-----|
| 4 | **Delta tracking** | Unbiased free-flight sampling | Modern standard; replaces biased ray marching |
| 5 | **Single-scatter lighting** | Volumetric shadows via ratio tracking | Huge visual quality jump |
| 6 | **Transfer functions** | Density/temperature → color/opacity | Required for scientific viz |
| 7 | **OpenEXR output** | HDR, linear color, deep pixels | Industry-standard output format |

### Phase 3: GPU Acceleration

| # | Component | What | Why |
|---|-----------|------|-----|
| 8 | **NanoVDB GPU kernel** | KernelAbstractions.jl ray marcher on flat VDB | GPU-portable volume rendering |
| 9 | **Progressive rendering** | Render noisy fast, refine over time | Interactive workflow |
| 10 | **Denoising** | OIDN-style or learned denoiser | Usable images from few samples |

### Phase 4: Creation Tools

| # | Component | What | Why |
|---|-----------|------|-----|
| 11 | **Mesh-to-SDF** | Signed distance field from triangle meshes | Level set creation |
| 12 | **Procedural generation** | Noise-based clouds, fractal volumes | Artistic content creation |
| 13 | **CSG operations** | Union, intersection, difference of VDB grids | Composable volume editing |
| 14 | **Point-to-density** | Particle/point cloud voxelization | Scientific data ingestion |

### Phase 5: Ecosystem Integration

| # | Component | What | Why |
|---|-----------|------|-----|
| 15 | **Makie backend** | Interactive 3D volume viewer | Julia ecosystem integration |
| 16 | **Animation** | Time-varying VDB sequences, motion blur | Production workflows |
| 17 | **Multi-scatter** | Full global illumination in volumes | Production quality |
| 18 | **Differentiable rendering** | Enzyme.jl gradients through volume renderer | Inverse problems, optimization |

---

## Key Architectural Decisions

### 1. KernelAbstractions.jl, not raw CUDA

Write kernels once, run on any GPU. CUDA.jl achieves C++ parity, and KA adds <5% overhead for portability across NVIDIA/AMD/Apple/Intel.

### 2. NanoVDB-style flat layout for GPU

The VDB tree (Root→I2→I1→Leaf) is pointer-based and CPU-only. NanoVDB's insight: serialize the same topology into flat arrays with index offsets. Julia can do this with `reinterpret` and structured memory layouts.

### 3. Delta tracking, not ray marching

Ray marching with fixed step size produces banding artifacts and is biased. Delta/ratio/spectral tracking (null-collision methods) are unbiased and converge to ground truth. This is what every production renderer uses. The algorithm:

```
while in_medium:
    t += -log(rand()) / sigma_majorant     # sample free-flight distance
    if rand() < sigma_real(x) / sigma_majorant:
        # real collision: scatter or absorb
    else:
        # null collision: continue
```

### 4. OpenEXR for output

The entire VFX industry pipeline expects EXR. Deep compositing support lets volumes be composited with live-action footage. Non-negotiable for production use.

### 5. Separate preview and production renderers

Interactive preview via GPU rasterization/absorption (like Makie). Production via Monte Carlo path tracing. Same scene description, different engines.

### 6. Multiple dispatch for type specialization

```julia
trace_ray(ray, medium::VDBVolume{Float32})   # scalar density
trace_ray(ray, medium::VDBVolume{Vec3f})     # vector field
trace_ray(ray, medium::VDBVolume{Float16})   # half-precision
```

Specialized code generated at compile time. No boxing, no virtual dispatch.

---

## Key Rendering Techniques

### Null-Collision Methods (SOTA for volumes)

- **Delta tracking**: fills medium with virtual particles to create homogeneous majorant; samples simple exponential distribution. Unbiased.
- **Ratio tracking**: estimates transmittance without termination events. Better variance for shadow rays.
- **Spectral tracking**: minimizes path throughput fluctuation across wavelengths. For spectral renderers.
- **Decomposition tracking**: splits medium into control + residual components. Accelerates free-path construction.
- **Progressive null-tracking** (SIGGRAPH 2023): adapts bounding extinction progressively for procedural media with unknown bounds.

### Multiple Scattering

- **Henyey-Greenstein phase function**: single parameter `g`, covers 90% of production use
- **Single scattering**: one shadow ray per collision — first major quality improvement
- **Diffusion approximation**: cheap fallback deep inside optically thick media
- **Full path tracing**: unbiased multi-scatter for production quality

### Deep Image Compositing

- Multiple depth samples per pixel for correct volume compositing
- OpenEXR 2 is the standard format
- Volumetric deep pixels: piecewise-constant optical density as function of depth
- Adopted by ILM, DreamWorks, Weta FX, Animal Logic

---

## Current Gap Analysis

| Capability | SOTA (Houdini/Blender) | Lyr Today | Gap |
|-----------|----------------------|-----------|-----|
| VDB Read | Full | **Full** | **None** |
| VDB Write | Full | None | Large |
| VDB Operations | Hundreds of tools | Basic accessors | Huge |
| Volume Rendering | Path-traced, GPU | CPU ray march | Large |
| Level Set Rendering | DDA + sphere trace | Sphere trace (buggy) | Medium |
| GPU Acceleration | OptiX/HIP/Metal | None | Large |
| Deep Compositing | EXR native | PPM output only | Large |
| Interactive Preview | Real-time | None | Large |
| Scene Description | USD/MaterialX | None | Large |
| Differentiable | None (fVDB is PyTorch) | None (but ecosystem ready) | **Opportunity** |

The gap is large but the foundation is solid. The parser — the hardest part of VDB — is already built.

---

## What Makes This Competitive

1. **Scriptable end-to-end.** From simulation → VDB creation → rendering → output in one language. No C++ compilation, no Python bindings, no Houdini license.

2. **Differentiable rendering.** Julia's AD ecosystem (Enzyme.jl, Zygote.jl) enables gradient-based optimization of volume parameters — smoke reconstruction from video, medical image reconstruction, inverse scattering. Something production renderers fundamentally cannot do.

3. **Scientific + artistic.** ParaView handles science. Houdini handles art. Nothing handles both well. A Julia pipeline with proper volume rendering bridges the gap.

4. **GPU-portable from day one.** Write once, run on NVIDIA/AMD/Apple/Intel. This is something even Blender struggles with (Cycles has separate CUDA/HIP/OptiX/Metal backends).

5. **Composable with the Julia ecosystem.** DifferentialEquations.jl for fluid sim, Flux.jl for ML-enhanced rendering, Makie.jl for interactive exploration, Optim.jl for parameter optimization — all compose without glue code.

---

## What NOT to Build

- A full production renderer competing with RenderMan/Hyperion (decades of engineering)
- A fluid simulator (Mantaflow, Houdini's solvers are mature)
- A full USD scene graph (enormous scope, diminishing returns)
- OptiX interop (closed source, NVIDIA-only, can't access HW RT cores from Julia)

---

## Collaboration Opportunities

- **Raycore.jl / Hikari**: they handle triangles, we handle volumes. Natural integration point via Makie.
- **AcceleratedKernels.jl**: GPU-portable parallel primitives for BVH construction, sorting rays.
- **OpenEXR.jl**: extend for deep compositing support.
- **Enzyme.jl**: differentiable GPU volume rendering kernels.

---

## References

### Production Renderers
- [Pixar RenderMan](https://renderman.pixar.com/)
- [Disney Hyperion](https://www.disneyanimation.com/technology/hyperion/)
- [Weta FX Manuka](https://www.wetafx.co.nz/research-and-tech/technology/manuka)
- [OpenMoonRay](https://openmoonray.org/)
- [SideFX Karma XPU](https://www.sidefx.com/docs/houdini/solaris/karma_xpu.html)

### Volume Rendering Theory
- [Production Volume Rendering (SIGGRAPH 2017 Course)](https://graphics.pixar.com/library/ProductionVolumeRendering/paper.pdf)
- [Monte Carlo Methods for Volumetric Light Transport (Novak et al. 2018)](https://cs.dartmouth.edu/~wjarosz/publications/novak18monte.pdf)
- [Progressive Null-Tracking (SIGGRAPH 2023)](https://cs.dartmouth.edu/~wjarosz/publications/misso23progressive.html)
- [Spectral and Decomposition Tracking (Kutz et al. 2017)](https://dl.acm.org/doi/10.1145/3072959.3073665)
- [Deep Compositing (Pixar)](https://graphics.pixar.com/library/DeepCompositing/)

### VDB Ecosystem
- [OpenVDB](https://www.openvdb.org/)
- [NanoVDB (NVIDIA)](https://developer.nvidia.com/nanovdb)
- [NeuralVDB (NVIDIA)](https://developer.nvidia.com/rendering-technologies/neuralvdb)
- [fVDB (NVIDIA, open source)](https://developer.nvidia.com/fvdb)
- [GPU Volume Rendering with VDB Compression (April 2025)](https://arxiv.org/abs/2504.04564)
- [ZibraVDB](https://www.zibra.ai/)

### Julia Ecosystem
- [CUDA.jl](https://github.com/JuliaGPU/CUDA.jl) — [NVIDIA benchmark: ~2% overhead](https://developer.nvidia.com/blog/gpu-computing-julia-programming-language/)
- [KernelAbstractions.jl](https://github.com/JuliaGPU/KernelAbstractions.jl)
- [AcceleratedKernels.jl](https://github.com/JuliaGPU/AcceleratedKernels.jl) — [Paper (July 2025)](https://arxiv.org/abs/2507.16710)
- [Raycore.jl](https://makie.org/website/blogposts/raycore/)
- [Makie.jl](https://github.com/MakieOrg/Makie.jl)
- [StaticArrays.jl](https://github.com/JuliaArrays/StaticArrays.jl)

### Scientific Visualization
- [ParaView](https://www.paraview.org/)
- [Beyond ExaBricks: GPU Volume Path Tracing of AMR Data (CGF 2024)](https://onlinelibrary.wiley.com/doi/10.1111/cgf.15095)
- [NVIDIA IndeX for ParaView](https://www.nvidia.com/en-us/data-center/index-paraview-plugin/)

---

*Document created: 2026-02-14*
*Based on research across 60+ sources covering commercial renderers, open-source tools, academic papers, and the Julia ecosystem.*
