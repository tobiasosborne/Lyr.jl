# Field Protocol — Architectural Stocktake

_Scope: `src/FieldProtocol.jl`, `src/Voxelize.jl`, `src/Visualize.jl`,
`src/ScalarQED.jl`, `src/Wavepackets.jl`, `src/HydrogenAtom.jl`, `src/Animation.jl`_

---

## 1. File Purposes

| File | Purpose |
|------|---------|
| `FieldProtocol.jl` | Abstract type hierarchy, `BoxDomain`, and four reference field types |
| `Voxelize.jl` | Continuous/particle field → `Grid{Float32}` VDB conversion |
| `Visualize.jl` | One-call `visualize(field)` pipeline; camera/material/light presets |
| `ScalarQED.jl` | Tree-level scalar QED scattering via time-dependent Dyson series (FFT) |
| `Wavepackets.jl` | Analytic Gaussian wavepackets, Morse/KW potentials, nuclear trajectory |
| `HydrogenAtom.jl` | Analytic hydrogen eigenstates ψ_nlm, LCAO molecular orbitals |
| `Animation.jl` | Frame-by-frame `TimeEvolution` rendering → PPM frames → MP4 via ffmpeg |

---

## 2. Field Protocol Interface

### Type hierarchy

```
AbstractField
├── AbstractContinuousField    # f(x,y,z) → value
│   ├── ScalarField3D
│   ├── VectorField3D
│   └── ComplexScalarField3D
├── AbstractDiscreteField      # f(index) → value  (lattice)
└── ParticleField              # direct particle data (not <: AbstractContinuousField)
```

`TimeEvolution{F}` is a wrapper around any `AbstractField` subtype.

### Methods a new `AbstractContinuousField` subtype MUST implement

| Method | Return type | Source |
|--------|-------------|--------|
| `evaluate(f, x::Float64, y::Float64, z::Float64)` | field-dependent | `FieldProtocol.jl:147` |
| `domain(f)` | `BoxDomain` | `FieldProtocol.jl:117` |
| `field_eltype(f)` | `Type` | `FieldProtocol.jl:119` |
| `characteristic_scale(f)` | `Float64` | `FieldProtocol.jl:138` |

A new `AbstractDiscreteField` subtype additionally needs `sites(f)` (iterator over valid indices) and `evaluate(f, index)`.

`ParticleField` implements `domain`, `field_eltype`, and `characteristic_scale` but no `evaluate` — voxelization uses Gaussian splatting directly.

### Key naming note
`field_eltype` (not `fieldtype`) is deliberately chosen to avoid shadowing `Base.fieldtype`
(`FieldProtocol.jl:124`).

---

## 3. Reference Continuous Fields

| Type | `evaluate` returns | Voxelize reduction | Typical use |
|------|-------------------|--------------------|-------------|
| `ScalarField3D{F}` | `Float64` | direct | density, pressure, any scalar |
| `VectorField3D{F}` | `SVec3d` | `\|v\|` (magnitude) | flow, B-field, gradient |
| `ComplexScalarField3D{F}` | `ComplexF64` | `abs2(ψ)` = probability density | QM wavefunctions |

All three are defined at `FieldProtocol.jl:186–281` with identical struct layout:
`eval_fn::F`, `domain::BoxDomain`, `characteristic_scale::Float64`.

`TimeEvolution{F,G}` (`FieldProtocol.jl:368`) wraps `eval_fn::G` (a `t → F` function)
with `t_range`, `dt_hint`, and a cached domain (sampled at `t_range[1]` at construction).

---

## 4. Voxelize / Visualize Entry Points

### `voxelize` (manual grid build)

```julia
voxelize(f::ScalarField3D; voxel_size, threshold, normalize, adaptive, block_tolerance)
voxelize(f::VectorField3D; kwargs...)           # reduces to magnitude first
voxelize(f::ComplexScalarField3D; kwargs...)    # reduces to |ψ|² first
voxelize(f::ParticleField; voxel_size, mode, sigma, cutoff_sigma, half_width, normalize, threshold)
voxelize(te::TimeEvolution; t, kwargs...)       # snapshot at time t
```

All return `Grid{Float32}` (`GRID_FOG_VOLUME`, `name="density"`).
Default `voxel_size = characteristic_scale / 5` (5 samples per feature, `Voxelize.jl:12`).

Adaptive voxelization (`Voxelize.jl:102`) divides the domain into 8³ blocks (matching VDB
leaf size), samples 8 block corners to estimate variation, and skips near-zero near-constant
blocks. This is the default (`adaptive=true`); `adaptive=false` falls back to uniform.

`ParticleField` uses Gaussian splatting (fog) by default; auto-switches to `particles_to_sdf`
(level set) if `f.properties[:radii]` is present (`Voxelize.jl:269`).

### `visualize` (one-call convenience)

```julia
pixels = visualize(field; voxel_size, threshold,
                   width, height, spp,
                   material, transfer_function, sigma_scale, emission_scale,
                   camera, lights, background,
                   tonemap, denoise,
                   output)   → Matrix{NTuple{3,Float64}}
```

Internal pipeline (`Visualize.jl:250`):
1. `voxelize(field; ...)`
2. `build_nanogrid(grid.tree)`
3. `_auto_camera(grid)` unless overridden — derives world-space camera from active BBox
4. `_camera_to_index_space(cam, vs)` — renderer operates in index space
5. Construct `VolumeMaterial`, `Scene`
6. `render_volume_image(scene, width, height; spp=spp, seed=seed)`
7. Optional `denoise_bilateral`
8. `tonemap_aces` (or custom tonemap)
9. Optional file write (PNG/EXR/PPM by extension)

`visualize(::ParticleField)` is a separate method (`Visualize.jl:363`) with extra `sigma`/
`cutoff_sigma` kwargs and `tf_cool_warm()` as the default transfer function instead of viridis.

`visualize(te::TimeEvolution; t=te.t_range[1], kwargs...)` snapshots at time `t`
and delegates to the underlying field's `visualize` (`Visualize.jl:409`).

---

## 5. ScalarQED

**All quantities in atomic units (ℏ = m_e = e = a₀ = 1).** Reference: `docs/scattering_physics.md`.

### MomentumGrid (`ScalarQED.jl:23`)
```julia
MomentumGrid(N::Int, L::Float64; mass=1.0)
```
3D FFT grid: N³ points, position space x ∈ [-L, L]³, `dx = 2L/N`.
Pre-computes `kx, ky, kz, k2, E_k` arrays. Frequency grid uses `fftfreq(N, 2π/dx)`.

### Born iteration (`ScalarQED.jl:185`)
```julia
precompute_born_products(grid, p1, r1, d1, p2, r2, d2, mass, alpha, times) → ScatteringPrecompute
```
For each time step `t_j`: evaluates free wavepackets, solves screened Poisson
(FFT, `mu² = (0.1/L)²` infrared cutoff), stores `P̃(k, t_j) = FFT[V_other(x,t_j) ψ_free(x,t_j)]`
for both particles. Cost: O(N³ log N × nsteps).

### Per-frame evaluation (`ScalarQED.jl:249`)
```julia
evaluate_frame(precomp, frame_idx; exchange_sign=0)
    → (electron_density::Array{Float64,3}, em_cross_energy::Array{Float64,3})
```
Accumulates the Dyson series incrementally up to `frame_idx`:
`S_n(k) = Σ exp(i E_k t_j) P̃(k,t_j)`, then `ψ_scat = -iα dt exp(-iE_k t) S_n`.
Each wavefunction is renormalized after perturbative correction.

### EM cross-energy (`ScalarQED.jl:314`)
`em_cross[i] = E₁·E₂` computed via `electric_field_from_density` (also FFT-based):
`Ê_j(k) = -i k_j Φ̂(k)` where `Φ̂ = 4π ρ̂ / (|k|² + μ²)`. Visualizes virtual photon
exchange as the overlap of the two particles' electric fields.

### Exchange sign semantics
`exchange_sign` (`ScalarQED.jl:247`):
- `0` — distinguishable particles (no exchange term)
- `+1` — bosons: `ρ = |ψ₁|² + |ψ₂|² + 2Re(ψ₁*ψ₂*)`
- `-1` — fermions / Moller scattering: `ρ = |ψ₁|² + |ψ₂|² - 2Re(ψ₁*ψ₂*)`

### Field Protocol wrapper
```julia
ScalarQEDScattering(p1,r1,d1, p2,r2,d2; mass, alpha, N, L, t_range, nsteps, exchange_sign)
    → (electron_field::TimeEvolution{ScalarField3D}, em_field::TimeEvolution{ScalarField3D})
```
Returns two `TimeEvolution` fields that interpolate precomputed frames on demand (lazy
with `frame_cache::Dict{Int,...}`). Trilinear interpolation from grid to world coordinates
(`ScalarQED.jl:389`).

---

## 6. Wavepackets

### Analytic evaluation
`gaussian_wavepacket(x,y,z,t, p0,r0,d,m) → ComplexF64` (`Wavepackets.jl:27`) is a
**closed-form** expression — Schwabl Eq. (2.5). No ODE integration: the complex Gaussian
width `σ² = d²(1 + iΔ)` with `Δ = t/(2md²)` exactly encodes spreading and de Broglie phase.

`wavepacket_width(t,d,m)` (`Wavepackets.jl:69`) returns `d√(1+(t/2md²)²)` — analytic width.

### Numerical
- **Morse potential** (`Wavepackets.jl:89`): `V(R) = De(1 - e^{-a(R-Re)})²` with
  `H2_MORSE` constants from [KW1968]. Analytic force `F = -dV/dR`.
- **Kolos-Wolniewicz PES** (`Wavepackets.jl:130`): tabulated 8-point [KW1968] data
  interpolated by cubic Hermite spline. Valid for R ∈ [1.0, 3.0] a.u.; clamped outside.
- **Nuclear trajectory** (`Wavepackets.jl:232`): velocity-Verlet (symplectic) integrator —
  numerically integrates 1D nuclear motion.

### FFT conventions
Used only in `ScalarQED.jl` (not `Wavepackets.jl`). The wavepacket module is purely
analytic/spectral: no DFT is performed inside `Wavepackets.jl` itself.

### Field Protocol convenience constructors
- `GaussianWavepacketField(p0,r0,d; m, t_range, dt, R_max)` → `TimeEvolution{ComplexScalarField3D}`
  — auto-sizes domain from kinematics (`Wavepackets.jl:285`).
- `ScatteringField(positions, times, orbital_fn; R_max)` → `TimeEvolution{ComplexScalarField3D}`
  — linearly interpolates a pre-computed nuclear trajectory and calls `orbital_fn(R,x,y,z)`
  (`Wavepackets.jl:323`).

---

## 7. HydrogenAtom

### Implemented eigenstates
Any `(n, l, m)` with `n ≥ 1`, `0 ≤ l < n`, `|m| ≤ l`. The math is fully general:
- `laguerre(n, α, x)` — three-term recurrence for L_n^α (`HydrogenAtom.jl:20`)
- `assoc_legendre(l, m, x)` — P_l^m with Condon-Shortley phase (`HydrogenAtom.jl:40`)
- `spherical_harmonic(l, m, θ, φ)` — Y_l^m in C-S convention (`HydrogenAtom.jl:69`)
- `hydrogen_radial(n, l, r)` — R_nl in a.u. (`HydrogenAtom.jl:90`)
- `hydrogen_psi(n, l, m, x, y, z)` — full eigenstate in Cartesian coords (`HydrogenAtom.jl:105`)

Special case at r < 1e-12: only l=0 terms survive (ρ^l → 0 for l > 0).

### MO reconstruction path
```
coeffs + orbitals[(n,l,m)] + centers[(x,y,z)]
    → molecular_orbital(coeffs, orbitals, centers, x, y, z)
    → ComplexF64                                      (HydrogenAtom.jl:137)
```
`h2_bonding(R,x,y,z)` and `h2_antibonding(R,x,y,z)` (`HydrogenAtom.jl:173,187`) are
two-center LCAO with analytic overlap integral `_overlap_1s(R)` (Schwabl Eq. 15.19b).

### Field Protocol convenience constructors
- `HydrogenOrbitalField(n,l,m; R_max)` → `ComplexScalarField3D`; domain auto-scales as
  `n² × a₀ × 2.5`, characteristic scale `n × a₀` (`HydrogenAtom.jl:212`).
- `MolecularOrbitalField(coeffs, orbitals, centers; R_max)` → `ComplexScalarField3D`;
  R_max extends past outermost center (`HydrogenAtom.jl:244`).

---

## 8. Animation

### Scene sweep pipeline (`Animation.jl:191`)
```julia
render_animation(fields::Vector{<:TimeEvolution}, materials::Vector{VolumeMaterial},
                 camera_mode::CameraMode;
                 t_range, nframes, fps, width, height, spp, lights,
                 output_dir, output, voxel_size)
    → output::String   (MP4 path, or frame_dir if ffmpeg absent)
```
Per-frame loop: `voxelize(f; t=t, ...)` → `build_nanogrid` → `VolumeEntry` → `Scene`
→ `render_volume_image` → `write_ppm` → `stitch_to_mp4`. Multiple simultaneous fields
(e.g., electron + EM) are rendered as a multi-volume scene in one pass.

### Camera modes
| Type | Behavior |
|------|----------|
| `FixedCamera` | Static — no motion |
| `OrbitCamera` | Full `revolutions` rotations over the animation |
| `FollowCamera{F}` | Tracks `center_fn(t)` at fixed distance/elevation |
| `FunctionCamera{F}` | Arbitrary `t → Camera` callback |

### Quantum TF presets
`tf_electron()` (blue-white), `tf_photon()` (red-orange), `tf_excited()` (purple-magenta)
— defined in `Animation.jl:122–158` as `TransferFunction` with 5 `ControlPoint`s each.

---

## 9. Known Frictions

**Adding a new `AbstractContinuousField` subtype requires exactly 4 methods**:
`evaluate`, `domain`, `field_eltype`, `characteristic_scale`. The reference types show the
minimal struct layout: store `eval_fn::F` (parametric for zero-overhead dispatch), `domain`,
`characteristic_scale`.

**Common pitfalls**:

1. **`voxelize` dispatch** — new types do not get `voxelize` for free. Either:
   (a) reduce to `ScalarField3D` and delegate (pattern used by `VectorField3D` and
   `ComplexScalarField3D` in `Voxelize.jl:201,218`), or
   (b) write a specialized method. Without this, calling `visualize(my_new_field)` silently
   falls through to `visualize(::AbstractContinuousField)` which calls `voxelize` — and will
   hit a `MethodError` if no matching `voxelize` exists.

2. **World-space vs index-space** — `BoxDomain` is world space; cameras after
   `_camera_to_index_space` are in index space. Do not mix them. (`Visualize.jl:180`)

3. **`characteristic_scale` determines voxel budget** — too large → coarse render;
   too small → enormous grid. Should reflect actual feature size, not bounding box.

4. **`TimeEvolution` domain is cached at `t_range[1]`** — if the domain changes
   significantly over time, `_auto_camera` (which uses the cached domain) will be wrong.
   Use an explicit `camera` override in `visualize`.

5. **`evaluate` return type must be annotated** — all three reference types use `::Float64`,
   `::SVec3d`, `::ComplexF64` assertions in the method body. Missing this can cause
   type instability that silently degrades voxelization performance.

6. **`ParticleField` is not `<: AbstractContinuousField`** — `visualize(::AbstractContinuousField)`
   does not dispatch on it; there is a separate `visualize(::ParticleField)` method.
   Custom particle-like types must either subtype `ParticleField` (not currently supported)
   or get their own `visualize` overload.
