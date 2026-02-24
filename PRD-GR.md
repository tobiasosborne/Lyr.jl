# PRD: General Relativistic Ray Tracing for Lyr.jl

## Overview

Extension of Lyr.jl to support physically correct ray tracing and path tracing in curved spacetimes. The renderer replaces straight-line ray marching with backward null geodesic integration through arbitrary Lorentzian metrics, enabling visualisation of gravitational lensing, accretion disks, cosmological effects, gravitational wave spacetimes, and multi-scattering radiative transfer around compact objects.

Primary use case: producing GR-correct rendered movies for a university general relativity course. Secondary: research-grade visualisation and general relativistic radiative transfer (GRRT) for exact and numerical spacetimes.

## Design Principles

1. **Physical correctness over visual appeal.** Every rendered pixel must correspond to a well-defined solution of the null geodesic equation. Frequency shifts, intensity transformations, and radiative transfer must respect the invariance of $I_\nu / \nu^3$. No fudge factors.

2. **Metric-agnostic architecture.** The geodesic integrator must be parametric over an abstract metric type. Adding a new spacetime means implementing one interface — not modifying the renderer.

3. **Leverage existing Lyr.jl infrastructure.** The VDB sparse tree, delta tracking, volume materials, tonemapping pipeline, and GPU kernels remain the spatial/rendering backbone. GR extends the ray propagation layer; it does not replace the rendering layer.

4. **Symplectic integration.** Geodesic integration must use structure-preserving (symplectic) methods. The Hamiltonian constraint $H = 0$ for null geodesics provides a runtime accuracy monitor. Drift in $H$ is a bug, not a feature.

5. **Composability with Julia ecosystem.** Use DifferentialEquations.jl, StaticArrays.jl, ForwardDiff.jl where appropriate. No reinventing numerical infrastructure.

## Architecture

### Core Abstraction: MetricSpace

```julia
abstract type MetricSpace{D} end  # D = number of spacetime dimensions (usually 4)

# Required interface
metric(m::MetricSpace, x::SVector{4,Float64})::SMatrix{4,4,Float64,16}
metric_inverse(m::MetricSpace, x::SVector{4,Float64})::SMatrix{4,4,Float64,16}

# Optional (defaults to ForwardDiff or finite differences)
metric_inverse_partials(m::MetricSpace, x::SVector{4,Float64})
    # → SArray or tuple of 4 SMatrix{4,4}, i.e. ∂g^{αβ}/∂x^μ

# Optional: analytic Christoffel symbols (performance optimisation)
christoffels(m::MetricSpace, x::SVector{4,Float64})

# Required: coordinate domain and singularity information
is_singular(m::MetricSpace, x::SVector{4,Float64})::Bool
coordinate_bounds(m::MetricSpace)  # e.g. r > 0 for Schwarzschild
```

### Geodesic Integrator

Hamiltonian formulation. Given a metric $g_{\mu\nu}(x)$, define:

$$H(x, p) = \tfrac{1}{2} g^{\mu\nu}(x) \, p_\mu \, p_\nu$$

Hamilton's equations:

$$\dot{x}^\mu = \frac{\partial H}{\partial p_\mu} = g^{\mu\nu} p_\nu, \qquad \dot{p}_\mu = -\frac{\partial H}{\partial x^\mu} = -\tfrac{1}{2} \frac{\partial g^{\alpha\beta}}{\partial x^\mu} p_\alpha p_\beta$$

This gives an 8-dimensional first-order ODE system for null geodesics ($H = 0$).

```julia
struct GeodesicState
    x::SVector{4,Float64}  # coordinates (t, x¹, x², x³)
    p::SVector{4,Float64}  # conjugate momenta p_μ
end

struct GeodesicIntegrator{M<:MetricSpace, S}
    metric::M
    solver::S               # symplectic integrator from DiffEq
    step_size::Float64
    max_steps::Int
    h_tolerance::Float64    # max allowed |H| drift
end

function integrate_geodesic(
    gi::GeodesicIntegrator,
    initial::GeodesicState;
    callbacks::Vector{<:GeodesicCallback} = []
)::GeodesicTrace
```

**Integration method:** Störmer-Verlet (symplectic 2nd order) as default, with option for higher-order symplectic methods. The key requirement is that $|H|$ remains below `h_tolerance` over the full integration. If it drifts, reduce step size adaptively.

**Callbacks** handle:
- Event detection (horizon crossing, coordinate singularities, escaping to infinity)
- Matter intersection queries (delegates to Lyr.jl spatial structures)
- Redshift accumulation along the ray

### Camera Model

```julia
struct GRCamera{M<:MetricSpace}
    position::SVector{4,Float64}    # spacetime position of camera
    four_velocity::SVector{4,Float64}  # u^μ of camera (timelike, normalised)
    tetrad::SMatrix{4,4,Float64,16} # local orthonormal frame e_a^μ
    fov::Float64
    resolution::Tuple{Int,Int}
end
```

The camera defines a local Lorentz frame via a tetrad. For each pixel $(i, j)$:

1. Compute the spatial direction $\hat{n}^a$ in the local frame from pixel coordinates and FOV.
2. Construct the initial null momentum: $p_\mu = -E(u_\mu + n_\mu)$ where $n_\mu$ is the spatial direction raised to a covector via the tetrad and metric. $E$ is an arbitrary affine scaling (can set $E = 1$).
3. The null condition $g^{\mu\nu} p_\mu p_\nu = 0$ is automatically satisfied by construction.

For standard observers (static, ZAMO, geodesic orbit), provide convenience constructors that build the tetrad automatically.

### Frequency Shift and Radiative Transfer

The redshift factor between emission and observation:

$$1 + z = \frac{(p_\mu u^\mu_{\text{emit}})}{(p_\mu u^\mu_{\text{obs}})}$$

This handles gravitational redshift, Doppler shift, and cosmological redshift simultaneously — they are not separate effects in GR.

For volumetric rendering, the invariant quantity is $I_\nu / \nu^3$ (consequence of Liouville's theorem for the photon distribution function). The covariant radiative transfer equation along the geodesic:

$$\frac{d}{d\lambda}\left(\frac{I_\nu}{\nu^3}\right) = \frac{j_\nu}{\nu^2} - \nu \, \alpha_\nu \frac{I_\nu}{\nu^3}$$

where $j_\nu$ is the emission coefficient and $\alpha_\nu$ the absorption coefficient in the emitter's rest frame, and $\nu$ is the photon frequency measured in that frame.

**Integration with existing Lyr.jl pipeline:** The delta tracking and ratio tracking algorithms operate on the spatial matter distribution at each integration step. At step $n$ of the geodesic, extract spatial coordinates, query the VDB tree for density/emission, apply the local frequency shift, and accumulate along the ray.

### Matter Sources

```julia
abstract type MatterSource end

# Geometric thin disk in equatorial plane
struct ThinDisk{M<:MetricSpace} <: MatterSource
    metric::M
    inner_radius::Float64  # typically ISCO
    outer_radius::Float64
    emissivity::Function   # (r, φ) → specific intensity in rest frame
    four_velocity::Function  # (r, φ) → u^μ of disk element
end

# Volumetric matter (uses existing Lyr.jl VDB infrastructure)
struct VolumetricMatter{M<:MetricSpace} <: MatterSource
    metric::M
    grid::Grid             # Lyr.jl VDB grid
    nanogrid::NanoGrid     # Lyr.jl flat buffer
    material::VolumeMaterial
    coordinate_map::Function  # spacetime coords → grid coords
    four_velocity_field::Function
end

# Point source / distant star field (skybox)
struct CelestialSphere <: MatterSource
    texture::Matrix{NTuple{3,Float64}}  # lat-lon HDR map
end
```

### GR Path Tracing (Multi-Scattering GRRT)

Phases 1–2 use single-scattering radiative transfer: each ray travels from camera to source along a single geodesic, accumulating emission and absorption. This is adequate for optically thin media. GR path tracing extends to the multi-scattering regime by allowing photons to scatter off matter, changing direction via a new geodesic segment at each interaction.

**Core idea:** Between scattering events, the photon follows a null geodesic arc. At each scattering vertex, boost to the local rest frame of the fluid, apply a scattering kernel, sample a new direction, boost back to coordinate frame, and launch a new geodesic segment. This is identical to flat-space Monte Carlo path tracing (which Lyr.jl already implements via delta tracking), with straight-line free flights replaced by geodesic arcs.

**Scattering loop:**

```
launch geodesic from camera (backward)
    │
    ▼
┌─► sample free-flight affine parameter Δλ from majorant
│       │
│       ▼
│   integrate geodesic for Δλ
│       │
│       ▼
│   at interaction point x^μ:
│       ├── query matter: get ρ, T, u^μ (four-velocity of fluid)
│       ├── compute local photon frequency: ν_local = -p_μ u^μ
│       ├── evaluate σ(ν_local): real or null collision?
│       │
│       ├── null collision → continue (delta tracking)
│       ├── absorption → terminate, weight by emissivity
│       └── scattering:
│               ├── boost p^μ into fluid rest frame via tetrad at x^μ
│               ├── sample new direction from phase function
│               │       (Thomson, Klein-Nishina, Henyey-Greenstein, ...)
│               ├── for Compton: also update photon energy
│               ├── boost new p'^μ back to coordinate frame
│               ├── verify null condition: g^μν p'_μ p'_ν = 0
│               └── launch new geodesic segment
│                       │
└───────────────────────┘
    │
    ▼
termination: escape to skybox, cross horizon, or max scattering depth
```

**Relationship to existing Lyr.jl delta tracking:** The modification is surgical. In the current `render_volume_image` pipeline, the inner loop advances the ray by a sampled free-flight distance along a straight line, then queries the VDB tree. The GR version replaces the straight-line advance with a call to `integrate_geodesic` for the corresponding affine parameter interval. The delta tracking logic (null-collision method, ratio tracking for transmittance estimates) is unchanged. Specifically:

- `sample_free_flight(rng, μ_majorant)` → $\Delta\lambda$ — unchanged
- `advance_ray(ray, Δs)` → `integrate_geodesic(gi, state, Δλ)` — **this is the replacement**
- `query_density(tree, position)` → query at new geodesic endpoint — unchanged
- `scatter(rng, phase_fn, direction)` → scatter in local Lorentz frame, boost — **new**

**Local Lorentz frame at scattering vertices.** The camera tetrad machinery generalises: at any spacetime point $x^\mu$ with a timelike observer $u^\mu$, construct an orthonormal tetrad $e_a{}^\mu$ with $e_0{}^\mu = u^\mu$. The photon's spatial direction in this frame is $n^a = p^a / p^0$ where $p^a = e^a{}_\mu p^\mu$. After scattering, the new spatial direction $n'^a$ is sampled from the phase function, and the new coordinate momentum is $p'^\mu = E'(u^\mu + e_i{}^\mu n'^i)$ where $E' = -p'_\mu u^\mu$ is the scattered photon energy.

For Compton scattering, $E' \neq E$ (energy transfer between photon and electron). For Thomson scattering (elastic, low-energy limit), $E' = E$ and only the direction changes. For the initial implementation, Thomson is sufficient and avoids the Compton kinematics.

**Frequency-dependent majorant.** The majorant extinction coefficient $\hat{\mu}$ must satisfy $\hat{\mu} \geq \mu(x, \nu(x))$ along every geodesic segment. The photon frequency varies along the geodesic due to gravitational redshift. For a ray falling toward a black hole, $\nu_{\text{local}}$ increases (blueshift), potentially increasing $\mu$ if the cross section is frequency-dependent. The majorant must be chosen conservatively:

- For frequency-independent scattering (Thomson): $\hat{\mu}$ depends only on density, no frequency issue.
- For frequency-dependent processes: precompute a bound on $\nu_{\text{local}}$ along the segment using the redshift factor, and use $\hat{\mu} = \max_\nu \mu(x, \nu)$ over the relevant frequency range. This is conservative but correct.

**Scattering kernels to implement:**

| Kernel | Physics | Frequency dependence | Priority |
|---|---|---|---|
| Thomson | Elastic e⁻ scattering, $\sigma_T = \text{const}$ | None | Phase 3 |
| Compton (Klein-Nishina) | Inelastic e⁻ scattering, energy transfer | Strong | Phase 5 |
| Thermal synchrotron | Emission + self-absorption by hot electrons in B field | Strong | Phase 5 |
| Henyey-Greenstein | Phenomenological anisotropic scattering | Parametric | Phase 3 |

**Variance reduction.** GR path tracing inherits the variance reduction techniques from flat-space Monte Carlo: next-event estimation (direct lighting at each vertex via a shadow geodesic to the light source, using ratio tracking for transmittance), Russian roulette for path termination, and importance sampling of the phase function. The shadow geodesic is the only new complication — it requires integrating a separate geodesic from the scattering point toward the light source and computing the transmittance along it. This is the GR generalisation of shadow rays.

## Metric Sourcing

The system supports three distinct modes for obtaining the metric tensor, ranging from zero numerical cost to importing full numerical relativity output. The mode determines what (if anything) is stored in VDB trees, what coordinate system is used, and what physics is captured.

### Mode 1: Analytic Exact Solutions

**When:** Schwarzschild, Kerr, FLRW, Morris-Thorne, Alcubierre, linearised GW, and any spacetime where $g_{\mu\nu}(x)$ has a closed-form expression.

**What's stored in VDB trees:** Matter only (emission/absorption coefficients, density). The metric is *not* stored — it is evaluated as a pure function at each geodesic integration step.

**Coordinates:** Whatever is natural for the spacetime. Boyer-Lindquist for Kerr, comoving for FLRW, Schwarzschild coordinates for Schwarzschild (with Eddington-Finkelstein or Kerr-Schild as alternatives when horizon penetration is needed).

**Matter ↔ metric relationship:** The matter distribution in the VDB tree is *test matter* — it does not backreact on the geometry. This is physically correct for optically thin accretion flows, stars in orbit, gas clouds, etc., provided their stress-energy is negligible compared to the central source. This is the standard assumption of every existing GR ray tracer (DNGR, GYOTO, GRay2, RAPTOR).

**Data structure:**
```
VDB Tree: Grid{Float32} or Grid{NTuple{3,Float32}}
    └── stores: emissivity, absorption coefficient, temperature, etc.
    └── coordinates: spatial slice of the analytic coordinate system
Metric: evaluated analytically via metric(m::MetricSpace, x) → SMatrix{4,4}
```

### Mode 2: Weak-Field Self-Consistent (Poisson Solve)

**When:** You want to specify an arbitrary static mass distribution $\rho(\mathbf{x})$ and render the gravitational lensing it produces, without committing to a particular exact solution.

**Physics:** In the linearised regime $g_{\mu\nu} = \eta_{\mu\nu} + h_{\mu\nu}$, $|h| \ll 1$, the time-time and space-space perturbations are determined by the Newtonian potential $\Phi$:

$$\nabla^2 \Phi = 4\pi\rho$$

$$g_{00} = -(1 + 2\Phi), \qquad g_{ij} = (1 - 2\Phi)\delta_{ij}, \qquad g_{0i} = 0$$

The metric is reconstructed analytically from $\Phi$ — only the potential needs to be stored.

**Pipeline:**
```
VDB Tree 1: Grid{Float32}
    └── stores: mass density ρ(x, y, z)
         │
         ▼
    Poisson solve (FFT on uniform grid, or multigrid on adaptive grid)
         │
         ▼
VDB Tree 2: Grid{Float32}
    └── stores: gravitational potential Φ(x, y, z)
         │
         ▼
    Metric reconstruction: g_μν(x) = η_μν + h_μν(Φ(x))
         │
         ▼
VDB Tree 3: Grid{Float32} (optional, can be same as Tree 1)
    └── stores: visible test matter (emission/absorption)
```

**Coordinates:** Cartesian $(t, x, y, z)$ throughout. No coordinate singularities, no patch issues. The weak-field approximation is valid everywhere except near compact objects where $|\Phi| \gtrsim 0.1$.

**Poisson solver options:**
- FFT on a uniform grid (simplest, $O(N \log N)$, requires embedding VDB data into a dense array)
- Multigrid on the VDB tree natively (harder to implement, but respects sparsity)
- Spectral methods for spherically symmetric or axisymmetric distributions (reduce to 1D/2D)

**Pedagogical value:** This is the most useful mode for a GR course, because students can see the full pipeline: "here is a lump of mass → here is how it curves spacetime → here is how light bends around it." They can compare the weak-field result for a point mass to the exact Schwarzschild solution and see where linearisation breaks down (roughly when $r \lesssim 10M$). They can also experiment with non-spherical mass distributions (binary systems, disk-shaped masses, etc.) that have no exact solution.

**Validation:** For a point mass $\rho = M\delta^3(\mathbf{x})$, the Poisson solve gives $\Phi = -M/r$, and the linearised metric reproduces the weak-field limit of Schwarzschild. The deflection angle should match $\Delta\phi \approx 4M/b$ to within linearisation error.

### Mode 3: Numerical Relativity Import (3+1 Decomposition)

**When:** Importing metric data from an external numerical relativity simulation (SpEC, Einstein Toolkit, BAM, etc.) — e.g. binary black hole merger, neutron star collapse.

**What's stored:** The full ADM 3+1 variables on a spatial grid, at each time slice. The line element in the 3+1 decomposition is:

$$ds^2 = -\alpha^2 \, dt^2 + \gamma_{ij}(dx^i + \beta^i \, dt)(dx^j + \beta^j \, dt)$$

Per spatial voxel, store 10 floats:

| Variable | Count | Description |
|---|---|---|
| $\alpha$ | 1 | Lapse function |
| $\beta^i$ | 3 | Shift vector |
| $\gamma_{ij}$ | 6 | Spatial metric (symmetric) |

The full 4D metric is reconstructed from these:

$$g_{00} = -\alpha^2 + \gamma_{ij}\beta^i\beta^j, \qquad g_{0i} = \gamma_{ij}\beta^j, \qquad g_{ij} = \gamma_{ij}$$

**Data structure:**
```
Per time slice t_n:
    VDB Tree: Grid{SVector{10,Float32}}
        └── voxel value = (α, β¹, β², β³, γ₁₁, γ₁₂, γ₁₃, γ₂₂, γ₂₃, γ₃₃)
        └── trilinear interpolation for inter-voxel queries

Time evolution:
    Vector{Tuple{Float64, Grid{SVector{10,Float32}}}}
        └── sequence of (t_n, grid_n) pairs
        └── linear interpolation between adjacent time slices
```

This is *not* a 4D voxel tree. It is a time-indexed sequence of 3D trees with temporal interpolation. The 3D tree respects spatial locality (which the VDB octree is designed for); the temporal interpolation is 1D and handled separately. This is the correct structure because:

1. Spatial locality in the octree sense (nearby voxels likely have similar values) holds for each time slice.
2. Temporal locality is trivial (linear interpolation between two bracketing slices).
3. A true 4D octree would waste memory on spacelike-separated regions with no causal relevance.
4. Numerical relativity codes output data as a sequence of spatial slices — this matches their output format directly.

**Coordinates:** Cartesian Kerr-Schild is the standard choice for stored numerical metrics. It is horizon-penetrating (no coordinate singularity at $r = 2M$), reduces to inertial Cartesian at infinity, and numerical relativity codes commonly output in Cartesian-like coordinates. The VDB tree's spatial coordinates $(x, y, z)$ are directly the Kerr-Schild spatial coordinates.

For Schwarzschild in Kerr-Schild form:

$$g_{\mu\nu} = \eta_{\mu\nu} + \frac{2M}{r} l_\mu l_\nu, \qquad l_\mu = \left(1, \frac{x^i}{r}\right)$$

No coordinate singularity at $r = 2M$. This also serves as a useful test case: store this metric in a VDB tree, ray trace it, and compare to the analytic Schwarzschild implementation.

**Coordinate patching:** For a single VDB tree, use one global Cartesian chart. If importing data from a spectral code like SpEC that uses multiple coordinate patches (spherical shells near the BH, Cartesian far away), **preprocess by interpolating onto a single Cartesian grid** before building the VDB tree. The alternative — maintaining multiple VDB trees with transition maps between patches — is not worth the implementation cost unless there is a compelling accuracy reason.

**Preprocessing pipeline:**
```
NR output (HDF5)
    │
    ├── read ADM variables on source grid
    ├── interpolate onto uniform/adaptive Cartesian grid
    ├── build VDB tree with 10-component voxels
    └── write Lyr.jl-compatible VDB file
```

### Multi-Channel VDB Grids

All three modes require extending Lyr.jl's `Grid{T}` to support multi-component voxel types efficiently. The existing infrastructure already templates on `T`, so:

- Mode 1: `Grid{Float32}` (unchanged)
- Mode 2: `Grid{Float32}` for $\Phi$, separate `Grid{Float32}` for matter
- Mode 3: `Grid{SVector{10,Float32}}` for ADM data

The NanoGrid flat buffer must also support multi-component types for GPU queries. Trilinear interpolation generalises trivially to vector-valued voxels (interpolate component-wise).

## Spacetimes to Implement

### Phase 1 — Vacuum Exact Solutions

| Spacetime | Coordinates | Key Parameters | Teaching Use |
|---|---|---|---|
| Schwarzschild | Schwarzschild $(t, r, \theta, \phi)$ | $M$ | Gravitational lensing, photon sphere, shadows |
| Schwarzschild | Eddington-Finkelstein | $M$ | Horizon penetration, no coordinate singularity at $r = 2M$ |
| Kerr | Boyer-Lindquist | $M, a$ | Frame dragging, ergosphere, accretion disk asymmetry |
| Kerr | Kerr-Schild | $M, a$ | Horizon-penetrating coordinates |

### Phase 2 — Cosmological and Perturbative

| Spacetime | Coordinates | Key Parameters | Teaching Use |
|---|---|---|---|
| FLRW | Comoving $(t, r, \theta, \phi)$ | $a(t)$, $k$ | Cosmological redshift, particle horizons |
| Linearised GW | Cartesian TT gauge | $h_+, h_\times, \omega, \hat{k}$ | Gravitational wave distortion of star fields |
| Schwarzschild–de Sitter | Schwarzschild-like | $M, \Lambda$ | Cosmological horizon + BH horizon interplay |

### Phase 3 — Advanced / Research

| Spacetime | Notes |
|---|---|
| Reissner-Nordström | Charged BH, Cauchy horizon |
| Wormhole (Morris-Thorne) | Traversable wormhole, two asymptotic regions |
| Alcubierre | Warp drive metric — pedagogically fun |
| Numerical 3+1 | Import from SpEC/Einstein Toolkit HDF5 output |

## Rendering Pipeline

Two rendering modes share the same geodesic integrator and matter query infrastructure:

**Mode A: Single-Scattering (Phases 1–4)** — one geodesic per pixel, accumulate emission/absorption along the ray. Adequate for optically thin media.

**Mode B: GR Path Tracing (Phase 5)** — multiple geodesic segments per pixel, with stochastic scattering vertices. Required for optically thick media.

```
                    ┌─────────────────────────────────┐
                    │        Metric Sourcing           │
                    ├─────────────────────────────────┤
                    │ Mode 1: g_μν(x) = f(x)          │  analytic function
                    │ Mode 2: ρ(x) → ∇²Φ=4πρ → g_μν  │  Poisson solve, Φ in VDB
                    │ Mode 3: (α,βⁱ,γᵢⱼ) from VDB    │  3+1 ADM import
                    └──────────────┬──────────────────┘
                                   │
                                   ▼
Pixel (i,j)                  MetricSpace interface
    │                    metric_inverse(m, x) → g^μν
    ▼
Camera tetrad → initial (x^μ, p_μ) on null cone
    │
    ▼
┌───────────────────────────────────────────────────────────┐
│                                                           │
│  Mode A: Single-Scattering          Mode B: Path Tracing  │
│  ─────────────────────────          ─────────────────────  │
│  integrate one geodesic             integrate geodesic arc │
│  accumulate I_ν/ν³                  ├── scatter at vertex  │
│  query matter at each step          │   boost to local     │
│                                     │   frame, sample      │
│                                     │   new direction,     │
│                                     │   boost back         │
│                                     └── repeat until       │
│                                         escape/absorb      │
│                                                           │
│  [shared: geodesic integrator, VDB matter queries,        │
│   frequency shift, delta tracking majorant]               │
│                                                           │
└───────────────────────────────────────────────────────────┘
    │
    ├── at each step: evaluate g^μν and ∂g^μν/∂x^α
    │       ├── Mode 1: analytic evaluation
    │       ├── Mode 2: trilinear interpolation of Φ from VDB, reconstruct g^μν
    │       └── Mode 3: trilinear interpolation of ADM components from VDB
    │
    ├── monitor |H| ≈ 0 (null constraint, per geodesic segment)
    │
    └── termination conditions:
            ├── ray escapes to r > r_max → skybox lookup
            ├── ray crosses horizon → black
            ├── ray hits coordinate singularity → terminate
            ├── max steps / scattering depth exceeded → flag pixel
            └── [Mode B] Russian roulette path termination
    │
    ▼
Apply frequency-dependent colour mapping
    │
    ▼
Existing Lyr.jl post-processing: denoise → tonemap → write
```

## GPU Strategy

Phase 1 is CPU-only, using Julia's threading (`Threads.@threads` over pixels). Each pixel's geodesic integration is independent — embarrassingly parallel.

Phase 2 adapts the existing KernelAbstractions.jl infrastructure from Lyr.jl. The geodesic integrator kernel takes:
- A metric struct (must be GPU-compatible: no heap allocations, no closures over mutable state)
- Camera parameters
- A NanoGrid flat buffer for volumetric matter lookup

The main challenge is that geodesic step counts vary wildly per pixel (rays near the photon sphere spiral many times). This creates warp divergence on GPU. Mitigation: bucket pixels by estimated step count using a coarse pre-pass, or use persistent-thread scheduling.

**Mode 2/3 GPU considerations:** When the metric is stored in a VDB tree (potential $\Phi$ or ADM components), every geodesic step requires a tree lookup for the metric *in addition to* the matter lookup. This doubles the memory bandwidth pressure. For Mode 3 with 10-component voxels, each metric query reads 40 bytes (10 × Float32) per voxel, times 8 voxels for trilinear interpolation = 320 bytes per step. At 1000 steps per ray and $10^6$ rays, this is ~300 GB of reads per frame — GPU memory bandwidth is the bottleneck, not compute. The NanoGrid flat-buffer layout is critical here: it guarantees spatially coherent memory access patterns, which is exactly what the GPU cache hierarchy needs.

## Non-Goals

- **Full numerical relativity evolution.** We do not solve the Einstein evolution equations (BSSN, generalised harmonic, Z4, etc.). We take a metric as input — either analytic, computed from a Poisson solve (Mode 2), or imported from external NR data (Mode 3). The distinction: we solve the *constraint* equation $\nabla^2\Phi = 4\pi\rho$ in Mode 2, but never the *evolution* equations.
- **Strong-field self-consistent matter → metric.** Mode 2 (Poisson solve) is valid only in the weak-field regime $|\Phi| \ll 1$. For strong-field self-consistent solutions (e.g. computing the metric of a neutron star from its equation of state), use an external solver and import via Mode 3, or use the TOV ODE for spherical symmetry (which could be added as a convenience utility).
- **Full Boltzmann transport.** GR path tracing (Phase 5) handles multi-scattering Monte Carlo radiative transfer with Thomson and Compton kernels. We do not implement deterministic Boltzmann solvers ($S_N$, discrete ordinates) or coupled radiation-hydrodynamics. The medium is static during each render — no radiation back-reaction on the fluid.
- **Polarisation.** The parallel transport of the polarisation vector along geodesics is physically important but is deferred. (Would require tracking a second vector along each geodesic, plus Stokes parameter evolution at each scattering vertex. The infrastructure for this — tetrad transport along geodesics — is partially built by the path tracing work, so this becomes feasible as a later extension.)
- **Quantum field theory on curved spacetime.** No Hawking radiation, no Unruh effect in the renderer. We render classical geometric optics.
- **Real-time interactivity.** Target is offline rendering for pre-computed movies, not interactive frame rates (though GPU acceleration should get close for simple scenes).

## Validation

Every spacetime implementation must pass quantitative tests against known analytic results:

1. **Schwarzschild photon sphere:** Circular null geodesic at $r = 3M$. Verify orbital period.
2. **Schwarzschild deflection angle:** For large impact parameter $b$, verify $\Delta\phi \approx 4M/b$ to first order.
3. **Einstein ring radius:** Point source directly behind Schwarzschild BH. Compare ring angular radius to exact formula.
4. **Kerr ISCO:** Verify innermost stable circular orbit radius for prograde/retrograde orbits matches analytic expressions.
5. **Kerr frame dragging:** Static observer sees zero-angular-momentum photons acquire angular displacement. Compare to analytic result.
6. **Redshift of circular orbits:** For Schwarzschild and Kerr, verify $(1 + z)$ for emitter on circular geodesic orbit matches exact expressions.
7. **FLRW cosmological redshift:** Verify $1 + z = a(t_{\text{obs}})/a(t_{\text{emit}})$ for comoving emitter/observer.
8. **Hamiltonian constraint conservation:** For every integration, verify $|H| < \epsilon$ throughout. This is the single most important diagnostic.
9. **Comparison with published renders:** Reproduce figures from James et al. (2015) DNGR paper and GYOTO publications.
10. **Weak-field point mass (Mode 2):** Poisson solve for $\rho = M\delta^3(\mathbf{x})$ yields $\Phi = -M/r$. Deflection angle matches $4M/b$. Rendered image matches Schwarzschild result at large $r/M$, with quantified deviation at small $r/M$.
11. **Weak-field convergence (Mode 2):** Increase VDB resolution; verify deflection angle converges. Decrease mass; verify linearised result approaches exact result.
12. **Numerical round-trip (Mode 3):** Store analytic Kerr-Schild Schwarzschild metric in a 10-component VDB tree. Ray trace using `Numerical3Plus1`. Compare pixel-by-pixel to analytic Schwarzschild render. Difference should be bounded by interpolation error.
13. **ADM reconstruction consistency (Mode 3):** Verify $g_{\mu\nu}$ reconstructed from $(\alpha, \beta^i, \gamma_{ij})$ satisfies the identity $g^{\mu\alpha}g_{\alpha\nu} = \delta^\mu_\nu$ at every sampled point.
14. **GR path tracing flat-space limit:** Set $g_{\mu\nu} = \eta_{\mu\nu}$, render optically thick uniform sphere with Thomson scattering. Result must match flat-space Monte Carlo path tracer to within statistical noise.
15. **GR path tracing energy conservation:** In Thomson scattering (elastic), verify photon energy in the fluid rest frame is unchanged at each scattering vertex: $E'_{\text{local}} = E_{\text{local}}$.
16. **grmonty benchmark:** Thermal synchrotron spectrum from a semi-analytic hot accretion flow (Fishbone-Moncrief torus) in Kerr. Compare spectral energy distribution $\nu L_\nu$ to published grmonty results (Dolence et al. 2009, Fig. 4).
17. **Shadow geodesic consistency:** For single-scattering limit (set max scattering depth = 1), GR path tracer must reproduce the single-scattering covariant RT result from Phase 2 to within Monte Carlo noise.

## Dependencies

| Package | Purpose | Phase |
|---|---|---|
| StaticArrays.jl | Fixed-size vectors/matrices for coordinates and momenta | 1 |
| DifferentialEquations.jl | ODE solvers including symplectic integrators | 1 |
| ForwardDiff.jl | Automatic differentiation of metric for $\partial g^{\mu\nu}/\partial x^\alpha$ | 1 |
| KernelAbstractions.jl | GPU kernels (existing Lyr.jl dependency) | 2 |
| LinearAlgebra (stdlib) | Matrix inverse, eigenvalues for tetrad construction | 1 |
| FFTW.jl | FFT-based Poisson solver for weak-field mode | 2 |
| HDF5.jl | Import numerical relativity spacetime data | 4 |

## Phased Implementation

### Phase 1: Schwarzschild Ray Tracer (MVP)

**Metric sourcing:** Mode 1 (analytic) only.

**Deliverable:** Render a star field gravitationally lensed by a Schwarzschild black hole, with thin accretion disk.

1. `MetricSpace` abstract type and interface
2. `Schwarzschild <: MetricSpace` in Schwarzschild coordinates
3. Hamiltonian geodesic integrator with Störmer-Verlet
4. `GRCamera` with static observer tetrad
5. `CelestialSphere` skybox matter source
6. `ThinDisk` with Keplerian four-velocity and power-law emissivity
7. Frequency shift computation (gravitational + Doppler)
8. CPU multi-threaded pixel loop
9. Integration with existing Lyr.jl tonemapping/PNG output
10. Validation tests 1–3, 6, 8

**Estimated scope:** ~1500 lines of Julia. 1–2 weeks with Claude Code.

### Phase 2: Kerr, Volume Rendering, and Weak-Field Mode

**Metric sourcing:** Mode 1 (analytic) + Mode 2 (Poisson solve).

**Deliverable:** Kerr black hole with volumetric accretion flow; arbitrary weak-field mass distribution → metric → render pipeline; animated movie output.

1. `Kerr <: MetricSpace` in Boyer-Lindquist coordinates
2. ZAMO and geodesic-orbit camera constructors
3. `VolumetricMatter` bridge to existing Lyr.jl VDB/delta-tracking
4. Covariant radiative transfer along geodesics ($I_\nu/\nu^3$ invariant)
5. `WeakField <: MetricSpace` — stores $\Phi$ in VDB tree, reconstructs linearised metric
6. Poisson solver: FFT-based on uniform grid (embed sparse VDB data into dense array, solve, extract back to VDB)
7. Validation: weak-field point mass reproduces $\Delta\phi \approx 4M/b$; compare to exact Schwarzschild at large $r$
8. Multi-channel `Grid{SVector{N,Float32}}` support in VDB trees (needed for Mode 3, useful to prototype here)
9. Animation framework: camera orbits, time evolution of matter
10. Frame sequence → movie pipeline (FFmpeg)
11. Validation tests 4–5, 9
12. GPU kernel for geodesic integration

**Estimated scope:** ~2500 additional lines. 3–4 weeks.

### Phase 3: Cosmological, Gravitational Waves, and Exotic Spacetimes

**Metric sourcing:** Mode 1 (analytic), time-dependent metrics.

**Deliverable:** FLRW cosmological lensing, gravitational wave visualisation, wormholes, warp drives.

1. `FLRW <: MetricSpace` with configurable scale factor $a(t)$
2. `LinearisedGW <: MetricSpace` — Minkowski + TT-gauge perturbation
3. Time-dependent metric support in integrator
4. `MorrisThorne <: MetricSpace` — traversable wormhole with two asymptotic regions
5. `Alcubierre <: MetricSpace` — warp drive metric
6. Validation test 7
7. Pedagogical movies: gravitational wave passing through star field, wormhole traversal

### Phase 4: Numerical Relativity Import

**Metric sourcing:** Mode 3 (3+1 ADM import).

**Deliverable:** Import and ray trace numerical spacetime data from external NR simulations.

1. HDF5 reader for Einstein Toolkit / SpEC / BAM output formats
2. Preprocessing pipeline: interpolate NR grid data onto Cartesian Kerr-Schild VDB tree
3. `Numerical3Plus1 <: MetricSpace` — 10-component ADM voxels with trilinear interpolation
4. Time-slice interpolation for dynamic spacetimes (binary merger movies)
5. Multi-channel NanoGrid flat buffer for GPU queries of vector-valued voxels
6. Validation: store analytic Kerr-Schild Schwarzschild in VDB tree, compare render to Phase 1 analytic result
7. Optional: TOV ODE solver as convenience utility for spherically symmetric self-consistent strong-field metrics

### Phase 5: GR Path Tracing (Multi-Scattering GRRT)

**Deliverable:** Monte Carlo multi-scattering radiative transfer in curved spacetime. Physically correct rendering of optically thick media around compact objects.

**Prerequisites:** Phases 1–2 (geodesic integrator, VDB matter queries, delta tracking bridge).

1. Refactor delta tracking inner loop: replace straight-line advance with geodesic-arc free-flight
2. Local Lorentz frame construction at arbitrary spacetime points (generalise camera tetrad)
3. Coordinate-frame ↔ fluid-frame boost for photon four-momentum at scattering vertices
4. Thomson scattering kernel (elastic, frequency-independent)
5. Henyey-Greenstein phenomenological phase function (reuse from existing Lyr.jl)
6. Shadow geodesics: next-event estimation via geodesic to light source with ratio-tracking transmittance
7. Frequency-dependent majorant estimation for delta tracking with gravitational frequency shifts
8. Compton scattering (Klein-Nishina cross section, photon energy redistribution)
9. Thermal synchrotron emission and self-absorption (for astrophysical applications)
10. Validation: reproduce grmonty benchmark — thermal synchrotron spectrum from analytic hot accretion flow in Kerr
11. Validation: optically thick uniform sphere in flat spacetime — converges to known analytic solution (sanity check that GR path tracer reduces to flat-space path tracer when $g_{\mu\nu} = \eta_{\mu\nu}$)

**Estimated scope:** ~2000 additional lines. 3–4 weeks. The geodesic integrator and matter query infrastructure already exist from Phases 1–2; the new work is the scattering vertex logic and variance reduction.

## File Structure

```
src/
├── gr/
│   ├── GR.jl                    # submodule entry point
│   ├── metric.jl                # MetricSpace abstract type + interface
│   ├── geodesic.jl              # Hamiltonian integrator
│   ├── camera.jl                # GRCamera, tetrad construction
│   ├── tetrad.jl                # local Lorentz frame at arbitrary points
│   ├── redshift.jl              # frequency shift, covariant RT
│   ├── matter.jl                # MatterSource types
│   ├── render.jl                # GR rendering pipeline (single-scattering)
│   ├── pathtracer.jl            # GR path tracing (multi-scattering GRRT)
│   ├── scattering/
│   │   ├── thomson.jl           # Thomson elastic scattering
│   │   ├── compton.jl           # Klein-Nishina cross section + kinematics
│   │   ├── synchrotron.jl       # thermal synchrotron emission/absorption
│   │   └── boost.jl             # coordinate ↔ fluid frame Lorentz boosts
│   ├── metrics/
│   │   ├── schwarzschild.jl
│   │   ├── kerr.jl
│   │   ├── flrw.jl
│   │   ├── linearised_gw.jl
│   │   ├── morris_thorne.jl
│   │   ├── alcubierre.jl
│   │   ├── weak_field.jl       # Mode 2: Poisson-sourced linearised metric
│   │   └── numerical.jl        # Mode 3: 3+1 ADM from VDB tree
│   ├── sourcing/
│   │   ├── poisson.jl          # FFT and multigrid Poisson solvers
│   │   ├── adm_import.jl       # HDF5 → VDB preprocessing pipeline
│   │   └── tov.jl              # TOV ODE for spherical strong-field (optional)
│   └── validation/
│       ├── photon_sphere.jl
│       ├── deflection_angle.jl
│       ├── einstein_ring.jl
│       ├── kerr_isco.jl
│       ├── redshift_circular.jl
│       ├── weak_field_point_mass.jl  # compare to exact Schwarzschild
│       ├── numerical_vs_analytic.jl  # Mode 3 round-trip test
│       ├── pathtracer_flat_limit.jl  # GR PT reduces to flat PT
│       └── grmonty_benchmark.jl      # compare to grmonty spectrum
```

## References

1. James, O., von Tunzelmann, E., Franklin, P., Thorne, K.S. (2015). "Gravitational lensing by spinning black holes in astrophysics, and in the movie Interstellar." *Class. Quantum Grav.* **32**, 065001. arXiv:1502.03808
2. Vincent, F.H., Paumard, T., Gourgoulhon, E., Perrin, G. (2011). "GYOTO: a new general relativistic ray-tracing code." *Class. Quantum Grav.* **28**, 225011. arXiv:1109.4769
3. Kuchelmeister, D., Müller, T., Jourde, S., Wunner, G., Boblest, S. (2012). "GPU-based four-dimensional general-relativistic ray tracing." *Comput. Phys. Commun.* **183**, 2282.
4. Moroz, M. "Visualizing General Relativity." michaelmoroz.github.io/TracingGeodesics/
5. Misner, C.W., Thorne, K.S., Wheeler, J.A. (1973). *Gravitation*. W.H. Freeman. (Chapters 22, 25, 33)
6. Chandrasekhar, S. (1983). *The Mathematical Theory of Black Holes*. Oxford University Press. (Geodesic equations in Kerr)
7. Baumgarte, T.W., Shapiro, S.L. (2010). *Numerical Relativity: Solving Einstein's Equations on the Computer*. Cambridge University Press. (3+1 decomposition, ADM formalism, Chapters 2–4)
8. Arnowitt, R., Deser, S., Misner, C.W. (1962). "The dynamics of general relativity." In *Gravitation: An Introduction to Current Research*, Wiley. arXiv:gr-qc/0405109 (ADM formalism)
9. Löffler, F. et al. (2012). "The Einstein Toolkit: a community computational infrastructure for relativistic astrophysics." *Class. Quantum Grav.* **29**, 115001. (Einstein Toolkit output format reference)
10. Dolence, J.C., Gammie, C.F., Mościbrodzka, M., Leung, P.K. (2009). "grmonty: A Monte Carlo code for relativistic radiative transport." *ApJS* **184**, 387. arXiv:0909.0708 (GR Monte Carlo radiative transfer benchmark)
11. Ryan, B.R., Dolence, J.C., Gammie, C.F. (2015). "bhlight: General relativistic radiation magnetohydrodynamics with Monte Carlo transport." *ApJ* **807**, 31. arXiv:1505.05119 (Coupled GRMHD + MC transport)
12. Bronzwaer, T. et al. (2018). "RAPTOR I: Time-dependent radiative transfer in arbitrary spacetimes." *A&A* **613**, A2. arXiv:1801.10452 (Covariant RT, EHT synthetic images)
13. Mościbrodzka, M., Gammie, C.F. (2018). "ipole — semi-analytic scheme for relativistic polarized radiative transport." *MNRAS* **475**, 43. arXiv:1712.03057 (Polarised GRRT, EHT workhorse)
