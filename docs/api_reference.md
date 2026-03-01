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

## Source File Map

| File | Contents |
|------|----------|
| `src/Lyr.jl` | Module definition, includes, exports |
| `src/Coordinates.jl` | `Coord`, `BBox`, origin/offset functions |
| `src/TreeTypes.jl` | `LeafNode`, `InternalNode1/2`, `RootNode`, `Grid` |
| `src/Masks.jl` | `Mask{N,W}`, bit operations |
| `src/Accessors.jl` | `ValueAccessor`, `get_value`, iterators |
| `src/GridBuilder.jl` | `build_grid` (Dict → immutable tree) |
| `src/GridOps.jl` | `comp_*`, `clip`, `copy_to/from_dense`, `change_background` |
| `src/LevelSetPrimitives.jl` | `create_level_set_sphere/box` |
| `src/Particles.jl` | `gaussian_splat`, `particles_to_sdf` |
| `src/MeshToVolume.jl` | `mesh_to_level_set` |
| `src/CSG.jl` | `csg_union/intersection/difference` |
| `src/LevelSetOps.jl` | `sdf_to_fog`, `check_level_set`, area/volume |
| `src/Stencils.jl` | `GradStencil`, `BoxStencil` |
| `src/DifferentialOps.jl` | `gradient_grid`, `divergence`, `curl_grid`, `mean_curvature` |
| `src/Interpolation.jl` | `sample_trilinear/quadratic`, `resample_to_match` |
| `src/Filtering.jl` | `filter_mean`, `filter_gaussian` |
| `src/Morphology.jl` | `dilate`, `erode` |
| `src/NanoVDB.jl` | `NanoGrid`, `build_nanogrid` |
| `src/TransferFunction.jl` | `TransferFunction`, `tf_*` presets |
| `src/Scene.jl` | `Scene`, `Camera`, lights, `VolumeMaterial`, `VolumeEntry` |
| `src/VolumeIntegrator.jl` | `render_volume_image`, `render_volume_preview` |
| `src/VolumeHDDA.jl` | HDDA span-merging iterator |
| `src/Output.jl` | `write_ppm`, `write_png`, `write_exr` |
| `src/FieldProtocol.jl` | `ScalarField3D`, `BoxDomain`, `evaluate` |
| `src/Voxelize.jl` | `voxelize` |
| `src/Visualize.jl` | `visualize`, camera/material/light presets |
| `src/Surface.jl` | `find_surface`, `SurfaceHit` |
| `src/Pruning.jl` | `prune` |
| `src/Ray.jl` | `Ray` type |
| `src/DDA.jl` | DDA ray marching |
| `src/File.jl` | `parse_vdb` |
| `src/FileWrite.jl` | `write_vdb` |
| `src/GPU.jl` | GPU delta tracking kernel |
