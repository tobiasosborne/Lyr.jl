# Lyr.jl API Reference

Agent-first API reference for Lyr.jl — a pure-Julia OpenVDB parser and production volume renderer.

**Canonical location**: `docs/api_reference.md`
**Also referenced in**: `CLAUDE.md` (cheat sheet), `HANDOFF.md` (pointer)

---

## Quick Start Workflows

### Read a VDB file and query values
```julia
using Lyr
file = parse_vdb("smoke.vdb")
grid = file.grids[1]                        # Grid{Float32}
val  = get_value(grid.tree, coord(10, 5, 3)) # query one voxel
for (c, v) in active_voxels(grid.tree)       # iterate all active
    # c::Coord, v::Float32
end
```

### Create geometry from scratch
```julia
# Analytic SDF primitives
sphere = create_level_set_sphere(center=(0.0,0.0,0.0), radius=10.0; voxel_size=1.0, half_width=3.0)
box    = create_level_set_box(min_corner=(-5.0,-5.0,-5.0), max_corner=(5.0,5.0,5.0))

# From particles
grid = particles_to_sdf(positions, radii; voxel_size=0.5, half_width=3.0)

# From triangle mesh (closed, manifold)
grid = mesh_to_level_set(vertices, faces; voxel_size=0.5, half_width=3.0)

# From sparse data dictionary
data = Dict(coord(0,0,0) => 1.0f0, coord(1,0,0) => 0.5f0)
grid = build_grid(data, 0.0f0; name="density", voxel_size=1.0)

# From dense 3D array
grid = copy_from_dense(array, 0.0f0; bbox_min=coord(0,0,0))
```

### Render a volume
```julia
# 1. Build NanoGrid (REQUIRED before rendering)
nano = build_nanogrid(grid.tree)

# 2. Set up scene
cam   = Camera((50.0, 40.0, 30.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
mat   = VolumeMaterial(tf_blackbody(); sigma_scale=15.0)
vol   = VolumeEntry(grid, nano, mat)
light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 0.8, 0.6))
scene = Scene(cam, light, vol)

# 3. Render
img = render_volume_image(scene, 800, 600; spp=32)
write_ppm("output.ppm", img)
write_png("output.png", img)  # requires `using PNGFiles`
```

### Field Protocol (physics → visualization in one call)
```julia
field = ScalarField3D(
    (x,y,z) -> exp(-(x^2+y^2+z^2)/50),
    BoxDomain(SVec3d(-10,-10,-10), SVec3d(10,10,10)),
    5.0  # characteristic_scale
)
img = visualize(field)  # auto voxelize + render
```

---

## Core I/O

| Function | Signature | Returns |
|----------|-----------|---------|
| `parse_vdb` | `parse_vdb(path::String; mmap=false)` | `VDBFile` |
| `parse_vdb` | `parse_vdb(bytes::Vector{UInt8})` | `VDBFile` |
| `write_vdb` | `write_vdb(path::String, grid::Grid{T})` | `Nothing` |

```julia
file = parse_vdb("scene.vdb")
file.grids           # Vector of Grid{T}
file.grids[1].name   # "density", "temperature", etc.
write_vdb("out.vdb", grid)
```

---

## Types

| Type | Description | Construction |
|------|-------------|-------------|
| `Grid{T}` | VDB grid with tree, metadata, transform | `build_grid(data, bg; ...)` |
| `Coord` | 3D `Int32` coordinate (index space) | `coord(x, y, z)` or `Coord(Int32(x), ...)` |
| `SVec3f` | `SVector{3, Float32}` | `SVec3f(x, y, z)` |
| `SVec3d` | `SVector{3, Float64}` | `SVec3d(x, y, z)` |
| `Ray` | Origin + direction | `Ray(origin::SVec3d, dir::SVec3d)` |
| `Camera` | Position, target, up, FOV | `Camera(pos, target, up, fov)` — all tuples |

### Grid fields
```julia
grid.name           # String
grid.grid_class     # GRID_LEVEL_SET | GRID_FOG_VOLUME | GRID_STAGGERED | GRID_UNKNOWN
grid.transform      # UniformScaleTransform (has .voxel_size)
grid.tree           # RootNode{T} (alias: Tree{T})
grid.tree.background # T — value for inactive voxels
```

---

## Query API

| Function | Signature | Returns |
|----------|-----------|---------|
| `get_value` | `get_value(tree, c::Coord)` | `T` (background if inactive) |
| `is_active` | `is_active(tree, c::Coord)` | `Bool` |
| `active_voxels` | `active_voxels(tree)` | Iterator of `(Coord, T)` |
| `inactive_voxels` | `inactive_voxels(tree)` | Iterator of `(Coord, T)` |
| `all_voxels` | `all_voxels(tree)` | Iterator of `(Coord, T, Bool)` |
| `leaves` | `leaves(tree)` | Iterator of `LeafNode{T}` |
| `active_voxel_count` | `active_voxel_count(tree)` | `Int` |
| `leaf_count` | `leaf_count(tree)` | `Int` |

All iterators are lazy — no upfront allocation.

Also works with `ValueAccessor{T}` for cached lookups:
```julia
acc = Lyr.ValueAccessor(grid.tree)
val = get_value(acc, coord(10, 5, 3))  # cached leaf/I1/I2 for coherent access
```

---

## Interpolation & Sampling

| Function | Signature | Returns |
|----------|-----------|---------|
| `sample_trilinear` | `sample_trilinear(tree, ijk::SVec3d)` | `T` |
| `sample_quadratic` | `sample_quadratic(tree, ijk::SVec3d)` | `T` (27-point B-spline) |
| `sample_world` | `sample_world(grid, xyz::SVec3d)` | `T` (trilinear in world coords) |
| `gradient` | `gradient(tree, c::Coord)` | `NTuple{3, T}` |
| `resample_to_match` | `resample_to_match(src, target; method)` | `Grid{T}` |
| `resample_to_match` | `resample_to_match(src; voxel_size, method)` | `Grid{T}` |

`method` keyword: omit for trilinear, pass `QuadraticInterpolation()` for quadratic.

---

## Stencils

Reusable cached neighborhood samplers. Create once, `move_to!` repeatedly.

| Function | Signature | Returns |
|----------|-----------|---------|
| `GradStencil` | `GradStencil(tree)` | 7-point stencil (center + 6 face neighbors) |
| `BoxStencil` | `BoxStencil(tree)` | 27-point stencil (3x3x3 cube) |
| `move_to!` | `move_to!(stencil, c::Coord)` | populates cache |
| `center_value` | `center_value(stencil)` | `T` |
| `gradient` | `gradient(gs::GradStencil)` | `NTuple{3, T}` |
| `laplacian` | `laplacian(gs::GradStencil)` | `T` |
| `value_at` | `value_at(bs::BoxStencil, dx, dy, dz)` | `T` |
| `mean_value` | `mean_value(bs::BoxStencil)` | `T` |

```julia
s = GradStencil(grid.tree)
for (c, _) in active_voxels(grid.tree)
    move_to!(s, c)
    g = gradient(s)
    L = laplacian(s)
end
```

---

## Differential Operators

All return new grids. Input grid must have active voxels.

| Function | Input | Output | Formula |
|----------|-------|--------|---------|
| `gradient_grid` | `Grid{T}` | `Grid{NTuple{3,T}}` | ∇f |
| `divergence` | `Grid{NTuple{3,T}}` | `Grid{T}` | ∇·F |
| `curl_grid` | `Grid{NTuple{3,T}}` | `Grid{NTuple{3,T}}` | ∇×F |
| `magnitude_grid` | `Grid{NTuple{3,T}}` | `Grid{T}` | \|v\| |
| `normalize_grid` | `Grid{NTuple{3,T}}` | `Grid{NTuple{3,T}}` | v/\|v\| |
| `mean_curvature` | `Grid{T}` | `Grid{T}` | κ = div(∇f/\|∇f\|) |

---

## Filtering & Morphology

| Function | Signature | Description |
|----------|-----------|-------------|
| `filter_mean` | `filter_mean(grid; iterations=1)` | Box blur (3x3x3 mean) |
| `filter_gaussian` | `filter_gaussian(grid; sigma=1.0, iterations=1)` | Gaussian-weighted 3x3x3 |
| `dilate` | `dilate(grid; iterations=1)` | Expand active region (face neighbors) |
| `erode` | `erode(grid; iterations=1)` | Contract active region |

---

## Grid Building

### From sparse data
```julia
build_grid(data::Dict{Coord,T}, background::T;
           name="density", grid_class=GRID_FOG_VOLUME, voxel_size=1.0) → Grid{T}
```

### From dense array
```julia
copy_from_dense(array::Array{T,3}, background::T;
                bbox_min=coord(0,0,0), name="density",
                grid_class=GRID_FOG_VOLUME, voxel_size=1.0) → Grid{T}
```

### Level set primitives
```julia
create_level_set_sphere(; center, radius, voxel_size=1.0, half_width=3.0, name="level_set") → Grid{Float32}
create_level_set_box(; min_corner, max_corner, voxel_size=1.0, half_width=3.0, name="level_set") → Grid{Float32}
```

### From geometry
```julia
particles_to_sdf(positions, radii; voxel_size=1.0, half_width=3.0) → Grid{Float32}
mesh_to_level_set(vertices, faces; voxel_size=1.0, half_width=3.0, name="mesh_sdf") → Grid{Float32}
```

`mesh_to_level_set` requires a closed, consistently-oriented (manifold) mesh. `vertices` = vector of `(x,y,z)` tuples, `faces` = vector of `(i,j,k)` 1-indexed vertex indices.

---

## Grid Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `change_background` | `(grid, new_bg) → Grid{T}` | New grid with different background |
| `activate` | `(grid, value) → Grid{T}` | Activate voxels matching value |
| `deactivate` | `(grid, value) → Grid{T}` | Deactivate voxels matching value |
| `copy_to_dense` | `(grid, bbox) → Array{T,3}` | Extract to dense array |
| `clip` | `(grid, bbox) → Grid{T}` | Clip to bounding box |
| `clip` | `(grid, mask_grid) → Grid{T}` | Clip using mask active set |
| `prune` | `(grid; tolerance) → Grid{T}` | Collapse uniform leaves to tiles |

### Compositing (element-wise on overlapping voxels)
```julia
comp_max(a, b) → Grid{T}   # max(a, b)
comp_min(a, b) → Grid{T}   # min(a, b)
comp_sum(a, b) → Grid{T}   # a + b
comp_mul(a, b) → Grid{T}   # a * b
comp_replace(a, b) → Grid{T}  # b where b active, else a
```

### CSG (level sets only — operates on SDF values)
```julia
csg_union(a, b)        → Grid{T}   # min(sdf_a, sdf_b)
csg_intersection(a, b) → Grid{T}   # max(sdf_a, sdf_b)
csg_difference(a, b)   → Grid{T}   # max(sdf_a, -sdf_b)
```

---

## Level Set Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `sdf_to_fog` | `(grid; cutoff=zero(T)) → Grid{T}` | SDF → fog density (linear ramp) |
| `sdf_interior_mask` | `(grid) → Grid{Float32}` | Mask where SDF < 0 |
| `extract_isosurface_mask` | `(grid; isovalue=0) → Grid{Float32}` | Mask voxels straddling isosurface |
| `level_set_area` | `(grid) → Float64` | Estimate surface area |
| `level_set_volume` | `(grid) → Float64` | Estimate enclosed volume |
| `check_level_set` | `(grid) → LevelSetDiagnostic` | Validate SDF properties |

### LevelSetDiagnostic fields
```julia
diag.valid           # Bool
diag.issues          # Vector{String}
diag.active_count    # Int
diag.interior_count  # Int (SDF < 0)
diag.exterior_count  # Int (SDF > 0)
diag.surface_count   # Int (SDF ≈ 0)
```

---

## Rendering Pipeline

### Scene components

```julia
# Cameras — arguments are tuples, NOT SVec3d
Camera(position, target, up, fov)
Camera((50.0, 40.0, 30.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)

# Lights
PointLight(position, intensity)            # position and RGB intensity as tuples
DirectionalLight(direction, intensity)     # direction and RGB intensity as tuples

# Materials
VolumeMaterial(tf;                         # TransferFunction (FIRST positional arg)
    phase_function=:isotropic,
    sigma_scale=10.0,
    emission_scale=1.0,
    scattering_albedo=0.5)

# Volume entries (positional args: grid, nanogrid, material)
nano = build_nanogrid(grid.tree)           # REQUIRED
vol  = VolumeEntry(grid, nano, mat)

# Scene (positional: camera, light(s), volume(s))
scene = Scene(cam, light, vol)
scene = Scene(cam, [light1, light2], [vol1, vol2])  # multiple lights/volumes
```

### Renderers
```julia
# Production (delta tracking, physically-based)
img = render_volume_image(scene, width, height; spp=1, seed=nothing, max_bounces=16)

# Preview (emission-absorption, fast)
img = render_volume_preview(scene, width, height; step_size=0.5, max_steps=2000)
```

### Output
```julia
write_ppm(path, img)                       # always works
write_png(path, img; gamma=2.2)            # requires `using PNGFiles`
write_exr(path, img; depth=nothing)        # requires `using OpenEXR`
```

### Transfer function presets
```julia
tf_blackbody()   # fire/heat
tf_cool_warm()   # diverging blue-red
tf_smoke()       # absorption/smoke
tf_viridis()     # perceptually uniform
```

### Visualization presets
```julia
# Cameras
camera_orbit(center, distance; azimuth=45°, elevation=30°, fov=40°)
camera_front(center, distance; fov=40°)
camera_iso(center, distance; fov=40°)

# Materials
material_emission(; tf=tf_blackbody(), sigma_scale=10.0, ...)
material_cloud(; tf=tf_smoke(), sigma_scale=5.0, ...)
material_fire(; tf=tf_blackbody(), sigma_scale=15.0, ...)

# Lights
light_studio()    # single key light
light_natural()   # warm key + cool fill
light_dramatic()  # strong key, minimal fill
```

---

## NanoVDB

Flat-buffer representation for GPU-ready rendering. **Required** before `render_volume_image`.

```julia
nano = build_nanogrid(grid.tree)   # NanoGrid{T} — contiguous byte buffer
vol  = VolumeEntry(grid, nano, material)
```

---

## Field Protocol

Define physics fields, get automatic voxelization and rendering.

### Field types
```julia
# Scalar field: f(x,y,z) → Float64
field = ScalarField3D(
    (x,y,z) -> sin(x) * cos(y) * exp(-z^2/10),
    BoxDomain(SVec3d(-10,-10,-10), SVec3d(10,10,10)),
    2.0  # characteristic_scale (smallest feature size)
)

# Vector field: f(x,y,z) → SVec3d
field = VectorField3D(
    (x,y,z) -> SVec3d(-y, x, 0),
    BoxDomain(SVec3d(-10,-10,-10), SVec3d(10,10,10)),
    5.0
)

# Complex scalar field: f(x,y,z) → ComplexF64
field = ComplexScalarField3D(eval_fn, domain, scale)

# Particle field
field = ParticleField(positions; velocities=nothing, properties=Dict())

# Time evolution
field = TimeEvolution((t) -> ScalarField3D(...), (0.0, 10.0), 0.1)
```

### Field interface
```julia
evaluate(field, x, y, z)         # sample at point
domain(field)                    # BoxDomain
field_eltype(field)              # return type (Float64, SVec3d, etc.)
characteristic_scale(field)      # feature size for auto voxel_size
```

### One-call visualization
```julia
img = visualize(field)                    # auto everything
img = visualize(field; width=1920, height=1080, spp=64)
img = visualize(field; output="render.png")  # save to file
grid = voxelize(field)                    # just voxelize, no render
```

---

## Gotchas & Common Mistakes

1. **Camera takes tuples, not SVec3d**: `Camera((50.0, 40.0, 30.0), ...)` not `Camera(SVec3d(50, 40, 30), ...)`
2. **`build_nanogrid` is required before rendering**: Forgetting it gives a method error
3. **`VolumeMaterial` first arg is transfer function**: `VolumeMaterial(tf; sigma_scale=15.0)` — the TF is positional
4. **Level set convention**: negative = inside, positive = outside, background > 0
5. **`field_eltype` not `fieldtype`**: Avoids shadowing `Base.fieldtype`
6. **`evaluate` has two dispatch families**: `evaluate(tf, density)` for transfer functions, `evaluate(field, x, y, z)` for fields
7. **Camera/renderer operate in index space**: Field Protocol domains are world space. The transform bridges them.
8. **`write_png` requires `using PNGFiles`**: Falls back to PPM silently if not loaded
9. **Immutable trees**: All grid operations return new grids. No in-place mutation.
10. **`contains` is not `Base.contains`**: Lyr exports `contains` for BBox — use `occursin` for string matching in tests

---

## Architecture Quick Reference

```
VDB Tree Structure:
  RootNode{T} (hash table)
    └─ InternalNode2{T} (32³ = 32768 children)
         └─ InternalNode1{T} (16³ = 4096 children)
              └─ LeafNode{T} (8³ = 512 voxels, NTuple{512,T})

Coordinate Hierarchy:
  Coord(x::Int32, y::Int32, z::Int32)
  leaf_origin(c)      → aligned to 8
  internal1_origin(c) → aligned to 128  (8×16)
  internal2_origin(c) → aligned to 4096 (8×16×32)

Grid Construction:
  Dict{Coord, T} → build_grid() → Grid{T}  (immutable, bottom-up)

Rendering Pipeline:
  Grid{T} → build_nanogrid() → NanoGrid{T}
  NanoGrid + Material + Camera + Lights → Scene → render_volume_image()
```

---

## Phase Functions

| Function | Description |
|----------|-------------|
| `IsotropicPhase()` | Uniform scattering in all directions |
| `HenyeyGreensteinPhase(g)` | Anisotropic scattering; `g ∈ (-1, 1)`, positive = forward, negative = backward |

Used in `VolumeMaterial`:
```julia
mat = VolumeMaterial(tf; phase_function=:isotropic)    # default
mat = VolumeMaterial(tf; phase_function=HenyeyGreensteinPhase(0.8))
```

---

## Fast Sweeping (SDF Reinitialization)

```julia
reinitialize_sdf(grid::Grid{T}; iterations=2) → Grid{T}
```

Reinitializes a distorted level set to a proper signed distance field using the Fast Sweeping Method (Zhao 2004). Run after CSG operations, advection, or any transformation that breaks the |∇φ| = 1 property.

```julia
sphere = create_level_set_sphere(center=(0.0,0.0,0.0), radius=10.0)
distorted = csg_union(sphere, box)
fixed = reinitialize_sdf(distorted)
```

---

## Meshing (Marching Cubes)

```julia
volume_to_mesh(grid::Grid{T}; isovalue::T=zero(T)) → (vertices, faces)
```

Extract a triangle mesh at the given isovalue using Marching Cubes (Lorensen & Cline 1987). Returns `vertices::Vector{NTuple{3,Float64}}` and `faces::Vector{NTuple{3,Int}}` (1-indexed).

SDF convention: `val < isovalue` → inside.

```julia
sphere = create_level_set_sphere(center=(0.0,0.0,0.0), radius=10.0)
verts, tris = volume_to_mesh(sphere)
```

---

## Segmentation

```julia
segment_active_voxels(grid::Grid{T}) → (Grid{Int32}, Int)
```

Label connected components of active voxels using 6-face connectivity BFS. Returns a label grid (values 1, 2, 3, ...) and the component count.

```julia
labels, n = segment_active_voxels(grid)
println("Found $n connected components")
```

---

## Point Advection

```julia
advect_points(positions, field::VectorField3D, dt; method=:rk4) → Vector{NTuple{3,Float64}}
```

Advect particles through a velocity field for one time step. Multithreaded over particles.

| `method` | Order | Description |
|----------|-------|-------------|
| `:euler` | 1st | Forward Euler |
| `:rk4` | 4th | Classical Runge-Kutta (default) |

```julia
vfield = VectorField3D((x,y,z) -> SVec3d(-y, x, 0),
                        BoxDomain(SVec3d(-10,-10,-10), SVec3d(10,10,10)), 5.0)
new_pos = advect_points([(1.0, 0.0, 0.0)], vfield, 0.1)
```

---

## Hydrogen Atom

Analytical hydrogen eigenstates and LCAO molecular orbitals as Field Protocol fields.

| Function | Signature | Returns |
|----------|-----------|---------|
| `hydrogen_psi` | `hydrogen_psi(n, l, m, x, y, z)` | `ComplexF64` — ψ\_nlm(r,θ,φ) |
| `HydrogenOrbitalField` | `HydrogenOrbitalField(n, l, m; radius)` | `ComplexScalarField3D` |
| `MolecularOrbitalField` | `MolecularOrbitalField(coeffs, orbitals, centers; radius)` | `ComplexScalarField3D` |
| `h2_bonding` | `h2_bonding(R, x, y, z)` | `ComplexF64` — σg bonding orbital |
| `h2_antibonding` | `h2_antibonding(R, x, y, z)` | `ComplexF64` — σu* antibonding orbital |

```julia
# Visualize the 3d_{z²} orbital
field = HydrogenOrbitalField(3, 2, 0; radius=25.0)
img = visualize(field; width=512, height=512, spp=32)

# H₂ bonding orbital at R = 1.4 a₀
field = MolecularOrbitalField([1.0, 1.0], [(1,0,0), (1,0,0)],
                               [(0.0, 0.0, -0.7), (0.0, 0.0, 0.7)]; radius=8.0)
```

### Building blocks (also exported)

| Function | Description |
|----------|-------------|
| `laguerre(n, α, x)` | Associated Laguerre polynomial L\_n^α(x) |
| `assoc_legendre(l, m, x)` | Associated Legendre P\_l^m(x) with Condon-Shortley phase |
| `spherical_harmonic(l, m, θ, φ)` | Complex spherical harmonic Y\_l^m(θ,φ) |
| `hydrogen_radial(n, l, r)` | Radial wavefunction R\_nl(r) |

---

## Wavepackets

Gaussian wavepackets with closed-form time evolution, potential energy surfaces, and nuclear trajectory integration. All in atomic units.

| Function | Signature | Returns |
|----------|-----------|---------|
| `gaussian_wavepacket` | `(x, y, z, t, p0, r0, d, m)` | `ComplexF64` |
| `wavepacket_width` | `(t, d, m)` | `Float64` |
| `GaussianWavepacketField` | `(p0, r0, d, m; radius, t_range)` | `TimeEvolution` wrapping a field |

```julia
# Free electron wavepacket
ψ = gaussian_wavepacket(0.0, 0.0, 0.0, 1.0, (1.0, 0.0, 0.0), (0.0, 0.0, 0.0), 3.0, 1.0)
```

### Potential surfaces

| Function | Description |
|----------|-------------|
| `MorsePotential(D_e, α, r_e)` | Morse potential V(r) = Dₑ(1 - e^{-α(r-rₑ)})² |
| `H2_MORSE` | Pre-built Morse potential for H₂ ground state |
| `morse_potential(pot, r)` | Evaluate V(r) |
| `morse_force(pot, r)` | Evaluate -dV/dr |
| `kw_potential(r)` | Kolos-Wolniewicz H₂ potential (Σg+ ground state) |
| `kw_force(r)` | KW force -dV/dr |

### Nuclear dynamics

| Function | Signature | Returns |
|----------|-----------|---------|
| `nuclear_trajectory` | `(r0, v0, force_fn, m, dt, nsteps)` | `(positions, velocities)` |
| `ScatteringField` | `(traj1, traj2, p01, p02, ...)` | `TimeEvolution` for scattering visualization |

---

## Scalar QED

Tree-level scalar QED scattering via time-dependent Born approximation. Virtual photon exchange from Dyson series.

| Type | Signature | Description |
|------|-----------|-------------|
| `MomentumGrid` | `MomentumGrid(N, L; mass=1.0)` | 3D FFT grid for spectral computation |
| `ScalarQEDScattering` | `ScalarQEDScattering(grid, config, ...)` | CPU scattering computation |
| `ScalarQEDScatteringGPU` | `ScalarQEDScatteringGPU(...)` | GPU-accelerated variant (KernelAbstractions.jl) |
| `GPUMomentumGrid` | `GPUMomentumGrid(N, L; backend)` | GPU-resident momentum grid |

### Frame evaluation

Each frame is evaluated incrementally: frame f+1 = frame f + 1 Born step. Produces electron density |ψ|² and EM cross-energy E₁·E₂ for rendering.

---

## Animation Pipeline

Renders `TimeEvolution` fields frame-by-frame with automatic voxelization, volume rendering, and MP4 stitching.

### Camera modes

| Type | Signature | Description |
|------|-----------|-------------|
| `FixedCamera` | `FixedCamera(position, target; up, fov)` | Static camera |
| `OrbitCamera` | `OrbitCamera(center, distance; elevation, fov, revolutions)` | Orbiting camera |
| `FollowCamera` | `FollowCamera(center_fn, distance; elevation, fov)` | Tracking camera |
| `FunctionCamera` | `FunctionCamera(camera_fn)` | Fully custom `t → Camera` |

### Transfer function presets (quantum visualization)

| Function | Description |
|----------|-------------|
| `tf_electron()` | Blue-white for electron probability density |
| `tf_photon()` | Red-orange for EM field energy |
| `tf_excited()` | Purple-magenta for excited electronic states |

### Rendering

```julia
render_animation(fields, materials, camera_mode;
                 t_range, nframes, fps=30, width=512, height=512,
                 spp=4, lights=light_studio(), output="animation.mp4") → String
```

Returns the output file path. Calls `stitch_to_mp4(frame_dir, output; fps)` via ffmpeg.

```julia
field = GaussianWavepacketField((1.0,0.0,0.0), (-10.0,0.0,0.0), 3.0, 1.0;
                                 radius=20.0, t_range=(0.0, 20.0))
mat = VolumeMaterial(tf_electron(); sigma_scale=10.0)
render_animation([field], [mat], OrbitCamera((0.0,0.0,0.0), 25.0);
                 t_range=(0.0, 20.0), nframes=60, output="wavepacket.mp4")
```

---

## General Relativity Module (`Lyr.GR`)

Backward null geodesic ray tracing through curved spacetime.

### Metrics

| Type | Description |
|------|-------------|
| `Minkowski` | Flat spacetime (η\_μν) |
| `Schwarzschild(M)` | Schwarzschild in Boyer-Lindquist coordinates |
| `SchwarzschildKS(M)` | Schwarzschild in Cartesian Kerr-Schild (horizon-penetrating) |
| `Kerr(M, a)` | Kerr metric (spinning black hole) with `BoyerLindquist` or `KerrSchild` coords |
| `WeakField(M)` | Linearized gravity stub |

```julia
m = Schwarzschild(1.0)  # M = 1 (geometric units)
horizon_radius(m)       # 2.0
photon_sphere_radius(m) # 3.0
isco_radius(m)          # 6.0
```

### Metric interface

| Function | Signature | Returns |
|----------|-----------|---------|
| `metric` | `(m, x::SVec4d)` | `SMat4d` — g\_μν |
| `metric_inverse` | `(m, x::SVec4d)` | `SMat4d` — g^μν |
| `is_singular` | `(m, x::SVec4d)` | `Bool` |
| `coordinate_bounds` | `(m)` | Coordinate range info |
| `horizon_radius` | `(m)` | `Float64` |

### Camera

```julia
GRCamera{M}(metric, position, four_velocity, tetrad, fov, resolution)

# Convenience: static observer at Boyer-Lindquist position
cam = static_camera(Schwarzschild(1.0), SVec4d(0.0, 30.0, π/4, 0.0),
                     45.0, (800, 600))
```

| Function | Signature | Returns |
|----------|-----------|---------|
| `static_camera` | `(metric, position, fov, resolution)` | `GRCamera` |
| `static_observer_tetrad` | `(metric, position)` | `(u^μ, e\_a^μ)` |
| `pixel_to_momentum` | `(cam, i, j)` | `SVec4d` — initial null p\_μ |

### Matter sources

| Type | Fields | Description |
|------|--------|-------------|
| `ThinDisk(r\_in, r\_out)` | inner/outer radius | Geometrically thin equatorial disk |
| `ThickDisk(r\_in, r\_out, h, ρ0)` | + half-height, density | 3D volumetric accretion disk |
| `CelestialSphere(lookup\_fn)` | angle → color | Background sky |

| Function | Signature | Returns |
|----------|-----------|---------|
| `disk_emissivity` | `(disk, r)` | `Float64` — I ∝ (r\_in/r)³ |
| `novikov_thorne_flux` | `(r, M, r\_isco)` | `Float64` — Page & Thorne 1974 |
| `disk_temperature_nt` | `(r, M, r\_isco; T\_inner)` | `Float64` — NT temperature profile |
| `keplerian_four_velocity` | `(metric, r)` | `SVec4d` — circular orbit u^μ |
| `checkerboard_sphere` | `(θ, φ)` | `NTuple{3,Float64}` — checkered sky |

### Integrator

```julia
IntegratorConfig(; stepper=RK4(), step_size=0.1, max_steps=10000,
                   r_max=200.0, r_min_factor=1.01, renorm_interval=50)
```

| Stepper | Description |
|---------|-------------|
| `RK4()` | 4th-order Runge-Kutta (default, accurate) |
| `Verlet()` | Symplectic Stormer-Verlet (better energy conservation) |

### Rendering

```julia
gr_render_image(cam::GRCamera, config::GRRenderConfig;
                disk=nothing, volume=nothing, sky=nothing) → Matrix{NTuple{3,Float64}}
```

```julia
GRRenderConfig(; integrator=IntegratorConfig(), background=(0.0,0.0,0.02),
                 use_redshift=true, use_threads=true, samples_per_pixel=1)
```

### Redshift & Color

| Function | Description |
|----------|-------------|
| `redshift_factor(p\_emit, u\_emit, p\_obs, u\_obs)` | Frequency ratio ν\_obs/ν\_emit |
| `temperature_shift(T, z)` | T\_obs = T\_emit / (1+z) |
| `blackbody_color(intensity)` | Planck spectrum → sRGB |
| `planck_to_rgb(T)` | Temperature in K → sRGB |

### Example

```julia
using Lyr.GR

m = Schwarzschild(1.0)
cam = static_camera(m, SVec4d(0.0, 30.0, 1.2, 0.0), 45.0, (800, 600))
disk = ThinDisk(6.0, 30.0)
config = GRRenderConfig(use_redshift=true)
img = gr_render_image(cam, config; disk=disk)
```

---

## Image Comparison Utilities

| Function | Signature | Returns |
|----------|-----------|---------|
| `image_rmse` | `(a, b)` | `Float64` — root mean squared error |
| `image_psnr` | `(a, b)` | `Float64` — peak signal-to-noise ratio |
| `image_ssim` | `(a, b)` | `Float64` — structural similarity |
| `image_max_diff` | `(a, b)` | `Float64` — maximum per-pixel difference |
| `save_reference_render` | `(path, img)` | Save golden render |
| `load_reference_render` | `(path)` | Load golden render |

---

## Integration Methods

Volume integrator dispatch types:

| Type | Description |
|------|-------------|
| `ReferencePathTracer()` | Full Monte Carlo delta tracking (default) |
| `SingleScatterTracer()` | Single-scatter with ratio tracking shadows |
| `EmissionAbsorption()` | Deterministic emission-absorption (fast preview) |

Used in `render_volume`:
```julia
render_volume(scene, width, height, EmissionAbsorption(); step_size=0.5)
```

---

## Source File Map

### Core I/O & Types
| File | Contents |
|------|----------|
| `src/Lyr.jl` | Module definition, includes, exports |
| `src/Coordinates.jl` | `Coord`, `BBox`, origin/offset functions |
| `src/TreeTypes.jl` | `LeafNode`, `InternalNode1/2`, `RootNode`, `Grid` |
| `src/Masks.jl` | `Mask{N,W}`, bit operations |
| `src/Accessors.jl` | `ValueAccessor`, `get_value`, iterators |
| `src/Grid.jl` | Grid wrapper combining tree, transform, metadata |
| `src/Ray.jl` | `Ray` type, AABB intersection |
| `src/Binary.jl` | Reading primitive types from byte vectors |
| `src/BinaryWrite.jl` | Writing primitive types to IO streams |
| `src/Compression.jl` | Zlib + Blosc codec abstraction |
| `src/VDBConstants.jl` | Shared format constants and version thresholds |
| `src/Header.jl` | VDB file header parsing |
| `src/Metadata.jl` | File-level and per-grid metadata |
| `src/GridDescriptor.jl` | Grid descriptor parsing, value type detection |
| `src/Transforms.jl` | Index space ↔ world space transforms |
| `src/TreeRead.jl` | Topology + values deserialization |
| `src/Values.jl` | Leaf/internal node value parsing |
| `src/ChildOrigins.jl` | Child origin computation from parent + index |
| `src/Exceptions.jl` | Typed exception hierarchy |
| `src/File.jl` | `parse_vdb` — top-level file parsing |
| `src/FileWrite.jl` | `write_vdb` — VDB file writing (v224) |

### Grid Construction & Operations
| File | Contents |
|------|----------|
| `src/GridBuilder.jl` | `build_grid` (Dict → immutable tree) |
| `src/GridOps.jl` | `comp_*`, `clip`, `copy_to/from_dense`, `change_background` |
| `src/Pruning.jl` | `prune` — collapse uniform leaves to tiles |
| `src/LevelSetPrimitives.jl` | `create_level_set_sphere/box` |
| `src/CSG.jl` | `csg_union/intersection/difference` |
| `src/LevelSetOps.jl` | `sdf_to_fog`, `check_level_set`, area/volume |
| `src/Particles.jl` | `gaussian_splat`, `particles_to_sdf`, `particle_trails_to_sdf` |
| `src/MeshToVolume.jl` | `mesh_to_level_set` |
| `src/FastSweeping.jl` | `reinitialize_sdf` (Eikonal fast sweeping) |
| `src/Meshing.jl` | `volume_to_mesh` (Marching Cubes) |
| `src/Segmentation.jl` | `segment_active_voxels` (connected components) |

### Analysis & Sampling
| File | Contents |
|------|----------|
| `src/Interpolation.jl` | `sample_trilinear/quadratic`, `resample_to_match` |
| `src/Stencils.jl` | `GradStencil`, `BoxStencil` |
| `src/DifferentialOps.jl` | `gradient_grid`, `divergence`, `curl_grid`, `mean_curvature` |
| `src/Filtering.jl` | `filter_mean`, `filter_gaussian` |
| `src/Morphology.jl` | `dilate`, `erode` |
| `src/DDA.jl` | DDA ray marching (Amanatides-Woo) |
| `src/Surface.jl` | `find_surface`, `SurfaceHit` |

### Rendering Pipeline
| File | Contents |
|------|----------|
| `src/NanoVDB.jl` | `NanoGrid`, `build_nanogrid` — flat GPU buffer |
| `src/VolumeHDDA.jl` | HDDA span-merging iterator |
| `src/TransferFunction.jl` | `TransferFunction`, `tf_*` presets |
| `src/PhaseFunction.jl` | `IsotropicPhase`, `HenyeyGreensteinPhase` |
| `src/Scene.jl` | `Scene`, `Camera`, lights, `VolumeMaterial`, `VolumeEntry` |
| `src/IntegrationMethods.jl` | `ReferencePathTracer`, `SingleScatterTracer`, `EmissionAbsorption` |
| `src/VolumeIntegrator.jl` | `render_volume_image`, `render_volume_preview` |
| `src/Render.jl` | Low-level rendering utilities |
| `src/Output.jl` | `write_ppm`, `write_png`, `write_exr` |
| `src/ImageCompare.jl` | `image_rmse`, `image_psnr`, `image_ssim` |
| `src/GPU.jl` | GPU delta tracking kernel (KernelAbstractions.jl) |

### Field Protocol & Visualization
| File | Contents |
|------|----------|
| `src/FieldProtocol.jl` | `ScalarField3D`, `VectorField3D`, `ComplexScalarField3D`, `ParticleField`, `TimeEvolution` |
| `src/Voxelize.jl` | `voxelize` — field → Grid{Float32} |
| `src/Visualize.jl` | `visualize`, camera/material/light presets |
| `src/PointAdvection.jl` | `advect_points` — particle advection through velocity fields |

### Physics Modules
| File | Contents |
|------|----------|
| `src/HydrogenAtom.jl` | `hydrogen_psi`, `HydrogenOrbitalField`, `MolecularOrbitalField`, H₂ LCAO |
| `src/Wavepackets.jl` | `gaussian_wavepacket`, Morse/KW potentials, nuclear dynamics |
| `src/ScalarQED.jl` | `ScalarQEDScattering`, `MomentumGrid` — tree-level Born approximation |
| `src/ScalarQEDGPU.jl` | `ScalarQEDScatteringGPU` — GPU-accelerated variant |
| `src/Animation.jl` | `render_animation`, camera modes, `stitch_to_mp4` |

### General Relativity
| File | Contents |
|------|----------|
| `src/GR/GR.jl` | GR submodule definition, exports |
| `src/GR/types.jl` | `SVec4d`, `SMat4d`, `GeodesicState`, `GeodesicTrace` |
| `src/GR/metric.jl` | `MetricSpace` abstract type + interface |
| `src/GR/metrics/minkowski.jl` | `Minkowski` flat spacetime |
| `src/GR/metrics/schwarzschild.jl` | `Schwarzschild` (Boyer-Lindquist) |
| `src/GR/metrics/schwarzschild_ks.jl` | `SchwarzschildKS` (Cartesian Kerr-Schild) |
| `src/GR/metrics/kerr.jl` | `Kerr` (Boyer-Lindquist + Kerr-Schild coords) |
| `src/GR/camera.jl` | `GRCamera`, `static_camera`, tetrad construction |
| `src/GR/integrator.jl` | `IntegratorConfig`, `RK4`, `Verlet`, geodesic integration |
| `src/GR/matter.jl` | `ThinDisk`, `CelestialSphere`, Keplerian orbits |
| `src/GR/redshift.jl` | `redshift_factor`, Planck spectrum, blackbody color |
| `src/GR/volumetric.jl` | `ThickDisk`, volumetric emission-absorption |
| `src/GR/render.jl` | `gr_render_image`, `GRRenderConfig` |
| `src/GR/stubs/weak_field.jl` | `WeakField` linearized gravity stub |
