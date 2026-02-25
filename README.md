# Lyr.jl

**Physically correct volume rendering in pure Julia.**

Lyr is a from-scratch implementation of the [OpenVDB](https://www.openvdb.org/) file format and a Monte Carlo volume renderer, written entirely in Julia. No C++ bindings, no external renderers — just Julia, from file parsing to final pixel.

<p align="center">
  <img src="docs/images/smoke_render.png" alt="Smoke volume rendered with Monte Carlo delta tracking" width="720"/>
  <br/>
  <em>Smoke simulation rendered with stochastic delta tracking and ACES tonemapping</em>
</p>

## Gallery

<table>
  <tr>
    <td align="center"><img src="docs/images/1s_orbital.png" width="280"/><br/><em>Hydrogen 1s</em></td>
    <td align="center"><img src="docs/images/2p_z_orbital.png" width="280"/><br/><em>Hydrogen 2p<sub>z</sub></em></td>
    <td align="center"><img src="docs/images/3d_x2y2_orbital.png" width="280"/><br/><em>Hydrogen 3d<sub>x&sup2;-y&sup2;</sub></em></td>
  </tr>
</table>

<p align="center">
  <img src="docs/images/precession.gif" alt="Larmor precession of hydrogen 1s+2p superposition" width="480"/>
  <br/>
  <em>Larmor precession of a hydrogen 1s + 2p<sub>x</sub> superposition in a magnetic field, decaying via spontaneous emission. Lindblad master equation, Tr(&rho;) = 1 exactly.</em>
</p>

The hydrogen orbital visualizations compute analytical wavefunctions (associated Laguerre polynomials, complex spherical harmonics) and render the probability density |&psi;|&sup2; as volumetric fog. The precession animation solves the full Lindblad master equation with jump operators L<sub>m</sub> = |1s&rang;&lang;2p<sub>m</sub>| — probability is exactly conserved at every frame.

### General Relativistic Ray Tracing

<p align="center">
  <img src="showcase/black_hole_flyby.mp4" alt="Schwarzschild black hole with volumetric thick accretion disk" width="480"/>
  <br/>
  <em>Schwarzschild black hole with volumetric thick disk — geodesic ray tracing in Cartesian Kerr-Schild coordinates, emission-absorption with relativistic redshift and Doppler beaming.</em>
</p>

<table>
  <tr>
    <td align="center"><img src="showcase/11_schwarzschild_volumetric.png" width="280"/><br/><em>Oblique view</em></td>
    <td align="center"><img src="showcase/12_schwarzschild_faceon.png" width="280"/><br/><em>Face-on (polar)</em></td>
    <td align="center"><img src="showcase/17_schwarzschild_edgeon.png" width="280"/><br/><em>Edge-on</em></td>
  </tr>
</table>

The GR module traces null geodesics backward from camera to source through curved spacetime. Schwarzschild and Cartesian Kerr-Schild metrics are implemented with analytic Christoffel symbols (no automatic differentiation). Thick disk emission uses the Shakura-Sunyaev temperature profile with bremsstrahlung-inspired emissivity. Frequency shift is computed from the ratio of photon 4-momentum contracted with emitter/observer 4-velocities.

## Why Lyr?

Most scientific visualization tools treat rendering as an afterthought — a black box that turns data into pixels. Lyr takes the opposite approach: the rendering itself is the physics.

- **Physically correct**: Monte Carlo delta tracking with ratio-tracking shadow rays. No shortcuts, no approximations beyond the single-scattering model.
- **Pure Julia**: From binary VDB parsing to GPU kernels, everything is Julia. Full type stability, zero-allocation hot paths, and you can `@code_warntype` the entire pipeline.
- **GPU-ready**: NanoVDB flat-buffer layout with [KernelAbstractions.jl](https://github.com/JuliaGPU/KernelAbstractions.jl) kernels — runs on CPU, CUDA, ROCm, and Metal.
- **The noise is the signal**: Low sample-count Monte Carlo renders have a film-grain quality that reveals the stochastic nature of the physics. This is intentional.

Inspired by [Nils Berglund's](https://www.youtube.com/@NilsBerglund) mathematical physics visualizations — the idea that beautiful mathematics deserves beautiful rendering.

## Features

| Category | What |
|----------|------|
| **VDB I/O** | Full OpenVDB read (v220-v226) and write (v224). Zlib + Blosc compression. Multi-grid files. Half-precision, vec3, Float32/64. |
| **Volume Rendering** | Delta tracking (free-flight sampling), ratio tracking (shadow transmittance), single-scatter lighting, transfer functions, phase functions (isotropic, Henyey-Greenstein). |
| **Post-Processing** | Non-local means denoising, bilateral filtering, tonemapping (ACES filmic, Reinhard, exposure), PNG/EXR output. |
| **GPU** | NanoVDB flat-buffer with KernelAbstractions.jl delta tracking kernel. Progressive accumulation. CPU fallback. |
| **Grid Construction** | `build_grid` from sparse `Dict{Coord, T}`. `gaussian_splat` for particle-to-volume conversion. |
| **Surface Rendering** | DDA hierarchical ray traversal (Amanatides-Woo), level-set sphere tracing, trilinear interpolation. |
| **General Relativity** | Null geodesic ray tracing (RK4 + Verlet). Schwarzschild (Boyer-Lindquist + Cartesian Kerr-Schild). Thin & thick accretion disk models. Gravitational redshift + Doppler beaming. Volumetric emission-absorption through curved spacetime. |
| **Quantum Physics** | Hydrogen atom wavefunctions (any n,l,m). Lindblad master equation for open quantum systems. Larmor precession. |
| **Field Protocol** | `ScalarField3D`, `VectorField3D`, `ComplexScalarField3D`, `ParticleField`, `TimeEvolution` — define physics, get rendered. One-call `visualize()` pipeline. |

## Quick Start

```julia
using Lyr

# Parse a VDB file
vdb = parse_vdb("smoke.vdb")
grid = vdb.grids[1]

# Build GPU-friendly flat buffer
nanogrid = build_nanogrid(grid.tree)

# Set up the scene
camera = Camera((300.0, 200.0, 300.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 40.0)
tf = tf_blackbody()
material = VolumeMaterial(tf; sigma_scale=1.0, emission_scale=2.0, scattering_albedo=0.6)
volume = VolumeEntry(grid, nanogrid, material)
light = DirectionalLight((0.6, 0.8, 1.0), (2.5, 2.5, 2.5))
scene = Scene(camera, light, volume; background=(0.01, 0.01, 0.02))

# Render with Monte Carlo delta tracking
pixels = render_volume_image(scene, 1920, 1080; spp=4)

# Post-process and save
pixels = denoise_bilateral(pixels)
pixels = tonemap_aces(pixels)
write_png("output.png", pixels)
```

See [docs/usage.md](docs/usage.md) for the full guide.

## Architecture

```
VDB File ──parse_vdb──▶ Grid{T} ──build_nanogrid──▶ NanoGrid{T}
                          │                              │
                     Tree structure               Flat GPU buffer
                     (Root→I2→I1→Leaf)            (byte offsets)
                          │                              │
                          └──────── Scene ◀──────────────┘
                                     │
                          render_volume_image (MC delta tracking)
                          render_volume_preview (deterministic)
                          gpu_render_volume (KernelAbstractions.jl)
                                     │
                              Matrix{NTuple{3,T}}
                                     │
                        denoise ──▶ tonemap ──▶ write_png/exr

Field Protocol:
  ScalarField3D / VectorField3D / ComplexScalarField3D / ParticleField
                          │
                     voxelize() ──▶ Grid{Float32} ──▶ visualize()

GR Module:
  MetricSpace (Schwarzschild, SchwarzschildKS)
       │
  GRCamera + IntegratorConfig + MatterSource (ThinDisk, ThickDisk)
       │
  gr_render_image() ── null geodesic integration ──▶ pixels
```

## Project Status

| Phase | Status | Key Components |
|-------|--------|----------------|
| 1. Foundation | **Complete** | VDB read/write, DDA traversal, NanoVDB flat layout |
| 2. Volume Renderer | **Complete** | Delta/ratio tracking, TF, scene, PNG/EXR output, multi-threaded |
| 3. GPU Acceleration | **~80%** | Delta tracking kernel, NLM + bilateral denoising |
| 4. Creation Tools | **Complete** | Grid builder, Gaussian splatting, Field Protocol (5 field types) |
| 5. GR Ray Tracing | **~85%** | Schwarzschild (BL + KS), RK4/Verlet, thin/thick disk, redshift. Missing: Kerr |
| 6. Ecosystem | Active | Hydrogen orbitals, MD demos, Ising model, showcase suite |

29,565 tests passing. See [VISION.md](VISION.md) for the full roadmap.

## Installation

```julia
# From the Julia REPL
] add https://github.com/tobiasosborne/Lyr.jl

# Or clone and develop
git clone https://github.com/tobiasosborne/Lyr.jl
cd Lyr.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
```

## Running Tests

```julia
julia --project -e 'using Pkg; Pkg.test()'
# 29,565 tests, ~3.5 minutes
```

## License

[Apache License 2.0](LICENSE)

## Acknowledgements

- [OpenVDB](https://www.openvdb.org/) by DreamWorks Animation for the file format specification
- [TinyVDBIO](https://github.com/syoyo/tinyvdbio) by Syoyo Fujita for the reference C++ parser
- [Nils Berglund](https://www.youtube.com/@NilsBerglund) for the inspiration that mathematical physics deserves beautiful visualization
- Built with significant assistance from [Claude Code](https://claude.ai/claude-code) (Anthropic)
