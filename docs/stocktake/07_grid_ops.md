# Grid Operations Stocktake

## 1. File Purposes

| File | Purpose |
|---|---|
| `src/GridOps.jl` | Element-wise compositing (comp_max/min/sum/mul/replace), activation toggle, dense copy, bounding-box/mask clip |
| `src/CSG.jl` | Constructive solid geometry — union/intersection/difference on level set grids via min/max combinators |
| `src/LevelSetOps.jl` | SDF-specific ops: sdf_to_fog, fog_to_sdf, interior mask, isosurface mask, area/volume estimation, diagnostic validator |
| `src/LevelSetPrimitives.jl` | Analytic SDF generators for sphere and axis-aligned box (narrow-band only) |
| `src/Filtering.jl` | Spatial smoothing: 3x3x3 box (mean) filter and Gaussian-weighted filter, both iterable |
| `src/Morphology.jl` | Binary morphology: dilate (face-neighbor expansion) and erode (boundary peeling) |
| `src/DifferentialOps.jl` | Grid-level differential operators: gradient, Laplacian, divergence, curl, magnitude, normalize, mean curvature |
| `src/Stencils.jl` | Zero-alloc stencil types: GradStencil (7-point) and BoxStencil (27-point), with move_to!/gradient/laplacian/mean_value |
| `src/FastSweeping.jl` | Eikonal solver (Zhao 2004 Fast Sweeping) for SDF reinitialization after distortion |
| `src/Meshing.jl` | Marching Cubes (Lorensen & Cline 1987) isosurface extraction: grid → (vertices, triangles) |
| `src/MeshToVolume.jl` | Triangle mesh → narrow-band SDF (Baerentzen & Aanes 2005 pseudonormals), multithreaded |
| `src/Segmentation.jl` | BFS flood-fill connected component labeling (6-connectivity) |
| `src/IntegrationMethods.jl` | Dispatch types for volume rendering methods: ReferencePathTracer, SingleScatterTracer, EmissionAbsorption |
| `src/ImageCompare.jl` | PPM/P6 reader, render regression metrics: RMSE, PSNR, SSIM, max-diff, save/load reference renders |
| `src/Interpolation.jl` | Nearest / trilinear / quadratic B-spline sampling; world-space sample_world; gradient(tree, coord); resample_to_match |

---

## 2. `Lyr.jl` Include Order

```
VDBConstants.jl          # format constants
Exceptions.jl            # error types
Binary.jl                # binary read primitives
Masks.jl                 # Mask{N,W} type
Coordinates.jl           # Coord, BBox
Compression.jl           # blosc/zip decompression
TreeTypes.jl             # LeafNode, Tree hierarchy
ChildOrigins.jl          # origin decoding
Values.jl                # voxel value parsing
Transforms.jl            # UniformScaleTransform
TreeRead.jl              # tree topology + values pass
Grid.jl                  # Grid struct
Header.jl                # VDB file header
Metadata.jl              # metadata blocks
GridDescriptor.jl        # per-grid descriptor
File.jl                  # top-level parse_vdb
Accessors.jl             # get_value, is_active, active_voxels, ValueAccessor
Interpolation.jl         # sample_world, sample_trilinear, gradient
Stencils.jl              # GradStencil, BoxStencil
DifferentialOps.jl       # gradient_grid, divergence, curl_grid, laplacian, mean_curvature
Ray.jl                   # Ray struct
DDA.jl                   # hierarchical DDA
Render.jl                # single-scatter renderer
Surface.jl               # find_surface, SurfaceHit
NanoVDB.jl               # flat buffer NanoGrid
VolumeHDDA.jl            # span-merging volume HDDA
GR/GR.jl                 # general relativistic raytracing
TinyVDB/TinyVDB.jl       # test oracle parser
GridBuilder.jl           # build_grid
GridOps.jl               # activate/deactivate, comp_*, clip
Pruning.jl               # prune
LevelSetPrimitives.jl    # create_level_set_sphere/box
CSG.jl                   # csg_union/intersection/difference
LevelSetOps.jl           # sdf_to_fog, fog_to_sdf, masks, measurements
Filtering.jl             # filter_mean, filter_gaussian
Morphology.jl            # dilate, erode
FastSweeping.jl          # reinitialize_sdf
Particles.jl             # particles_to_sdf
MeshToVolume.jl          # mesh_to_level_set
Segmentation.jl          # segment_active_voxels
Meshing.jl               # volume_to_mesh
BinaryWrite.jl           # VDB binary serialization
FileWrite.jl             # write_vdb
TransferFunction.jl      # TransferFunction, control points, presets
PhaseFunction.jl         # IsotropicPhase, HenyeyGreensteinPhase
Scene.jl                 # Scene, VolumeEntry, lights, VolumeMaterial
IntegrationMethods.jl    # ReferencePathTracer, SingleScatterTracer, EmissionAbsorption
VolumeIntegrator.jl      # render_volume dispatch
Output.jl                # write_ppm, write_png, write_exr
ImageCompare.jl          # read_ppm, image metrics
GPU.jl                   # GPU render wrappers
FieldProtocol.jl         # AbstractField hierarchy, BoxDomain
Voxelize.jl              # voxelize(field)
Visualize.jl             # visualize(field)
PointAdvection.jl        # advect_points
HydrogenAtom.jl          # hydrogen_psi, orbitals
Wavepackets.jl           # GaussianWavepacketField, nuclear dynamics
ScalarQED.jl             # tree-level scattering
ScalarQEDGPU.jl          # GPU-accelerated scalar QED
Animation.jl             # render_animation, stitch_to_mp4
```

---

## 3. Public Export List

### Core I/O
```julia
parse_vdb, write_vdb
```

### Types
```julia
Grid, Coord, coord, SVec3f, SVec3d, Ray, Camera
```

### Query API
```julia
get_value, is_active, active_voxels, inactive_voxels, all_voxels, leaves
active_voxel_count, leaf_count
i1_nodes, i2_nodes, collect_leaves, foreach_leaf
```

### Interpolation and Gradient
```julia
sample_world, sample_trilinear, sample_quadratic, gradient
QuadraticInterpolation, resample_to_match
```

### Stencils
```julia
GradStencil, BoxStencil, move_to!, center_value, laplacian, value_at, mean_value
```

### Differential Operators
```julia
gradient_grid, divergence, curl_grid, mean_curvature, magnitude_grid, normalize_grid
```

### Filtering
```julia
filter_mean, filter_gaussian
```

### Morphology / Level Set / Meshing (grouped under "Morphology" in Lyr.jl)
```julia
dilate, erode
reinitialize_sdf
advect_points
segment_active_voxels
volume_to_mesh
```

### Surface
```julia
find_surface, SurfaceHit
```

### Rendering Pipeline
```julia
render_volume_image, render_volume_preview, render_volume
```

### Integration Methods
```julia
ReferencePathTracer, SingleScatterTracer, EmissionAbsorption
write_ppm, write_png, write_exr
read_ppm, image_rmse, image_psnr, image_ssim, image_max_diff
save_reference_render, load_reference_render, read_float32_image
```

### Scene Setup
```julia
AbstractLight, PointLight, DirectionalLight, ConstantEnvironmentLight
VolumeMaterial, VolumeEntry, Scene
```

### Phase Functions
```julia
IsotropicPhase, HenyeyGreensteinPhase
```

### Transfer Functions
```julia
TransferFunction, ControlPoint, evaluate
tf_blackbody, tf_cool_warm, tf_smoke, tf_viridis
```

### Grid Building
```julia
build_grid, voxelize, particles_to_sdf, particle_trails_to_sdf, mesh_to_level_set
create_level_set_sphere, create_level_set_box
```

### Grid Operations
```julia
change_background, activate, deactivate
copy_to_dense, copy_from_dense
comp_max, comp_min, comp_sum, comp_mul, comp_replace
clip
prune
csg_union, csg_intersection, csg_difference
```

### Level Set Operations
```julia
sdf_to_fog, fog_to_sdf, sdf_interior_mask, extract_isosurface_mask
level_set_area, level_set_volume
check_level_set, LevelSetDiagnostic
```

### NanoVDB
```julia
NanoGrid, build_nanogrid
gpu_available, gpu_info, gpu_render_volume, gpu_render_multi_volume, gpu_gr_render
```

### Field Protocol
```julia
ScalarField3D, VectorField3D, ComplexScalarField3D
ParticleField, TimeEvolution
BoxDomain, domain, field_eltype, characteristic_scale
visualize
```

### Physics (Hydrogen, Wavepackets, QED)
```julia
hydrogen_psi, HydrogenOrbitalField, MolecularOrbitalField, h2_bonding, h2_antibonding
gaussian_wavepacket, GaussianWavepacketField
MorsePotential, H2_MORSE, morse_potential, morse_force, kw_potential, kw_force
nuclear_trajectory, ScatteringField
ScalarQEDScattering, MomentumGrid, ScalarQEDScatteringGPU, GPUMomentumGrid
```

### Animation
```julia
render_animation, stitch_to_mp4
FixedCamera, OrbitCamera, FollowCamera, FunctionCamera, CameraMode
tf_electron, tf_photon, tf_excited
camera_orbit, camera_front, camera_iso
material_emission, material_cloud, material_fire
light_studio, light_natural, light_dramatic
```

---

## 4. GridOps: Key Operations

**`activate(grid, value)`** — Scans all leaves for inactive voxels whose stored value equals `value`, adds them to the active set. Useful to re-activate voxels that were set to a specific sentinel (e.g., zero) but deactivated.

**`deactivate(grid, value)`** — Removes active voxels whose value equals `value`. The inverse of activate; shrinks the active set without touching the tree topology.

**`comp_max(a, b)`** — Union of active sets; at overlapping coords keeps `max(a, b)`. Equivalent to "brightest" compositing.

**`comp_min(a, b)`** — Union of active sets; at overlapping coords keeps `min(a, b)`.

**`comp_sum(a, b)`** — Union of active sets; at overlapping coords sums values. Additive compositing (e.g., stacking fog layers).

**`comp_mul(a, b)`** — Union of active sets; at overlapping coords multiplies values.

**`comp_replace(a, b)`** — Union of active sets; b "stamps on top of" a (b values win at overlaps).

**`clip(grid, bbox::BBox)`** — Retains only active voxels within the integer bounding box.

**`clip(grid, mask_grid::Grid)`** — Retains active voxels in `grid` only where `mask_grid` is also active. Mask topology acts as a stencil.

All compositing ops start from `active_voxels` only — inactive background values in leaves are ignored.

---

## 5. CSG + LevelSetPrimitives

### Primitives (`LevelSetPrimitives.jl`)

Both functions accept keyword arguments only:

- **`create_level_set_sphere(; center, radius, voxel_size=1.0, half_width=3.0, name)`** — Iterates the index-space bounding box, evaluates the Euclidean SDF `dist - radius`, stores voxels within `half_width * voxel_size` of the surface. Background = `Float32(half_width * voxel_size)`.

- **`create_level_set_box(; min_corner, max_corner, voxel_size=1.0, half_width=3.0, name)`** — Same structure but uses the standard box SDF: `outside_dist = norm(max.(d, 0))`, `inside_dist = min(max(dx, dy, dz), 0)`, where `d = max(lo - p, p - hi)` component-wise. Handles corners and edges with exact Euclidean distance.

### CSG (`CSG.jl`)

All three operations share `_csg_combine`, which:
1. Collects all active coords from both grids.
2. Dilates the union by one face-neighbor layer (fills narrow-band gaps at seams, per Museth ACM TOG 2013 §5.1).
3. Evaluates the combinator at each coord using `get_value` (returns background outside the narrow band).
4. Rebuilds with `GRID_LEVEL_SET` class.

| Operation | Formula |
|---|---|
| `csg_union(a, b)` | `min(sdf_a, sdf_b)` — inside either |
| `csg_intersection(a, b)` | `max(sdf_a, sdf_b)` — inside both |
| `csg_difference(a, b)` | `max(sdf_a, -sdf_b)` — inside a, outside b |

After CSG, `reinitialize_sdf` should be called to restore `|∇φ| = 1`.

---

## 6. Level Set Ops / Morphology / Filtering

**`LevelSetOps.jl`** owns SDF-specific semantics:
- `sdf_to_fog`: maps interior (SDF < 0) → 1.0, linear ramp through narrow band, exterior → 0.
- `fog_to_sdf`: threshold fog, dilate, then call `reinitialize_sdf` to produce a proper SDF.
- `sdf_interior_mask` / `extract_isosurface_mask`: produce Float32 indicator grids.
- `level_set_area` / `level_set_volume`: voxel-counting estimates (face-crossings, interior counts).
- `check_level_set` / `LevelSetDiagnostic`: validates background sign, grid class, narrow-band symmetry, no out-of-band active voxels.

**`Morphology.jl`** is purely topological — adds or removes voxel layers using 6-face connectivity without reference to SDF values:
- `dilate`: adds background-valued voxels at face neighbors of every active voxel.
- `erode`: removes any active voxel that has at least one inactive face neighbor.

**`Filtering.jl`** operates on voxel values (not topology):
- `filter_mean`: replaces each active voxel with the 3x3x3 mean (via BoxStencil).
- `filter_gaussian`: same but with precomputed Gaussian weights parameterized by sigma.
- Both support `iterations` to widen the effective kernel.

No functional overlap exists between the three files: LevelSetOps = SDF semantics, Morphology = active-set topology, Filtering = value smoothing.

---

## 7. DifferentialOps + Stencils

### Stencils (`Stencils.jl`)

Two cached stencil types, both backed by a `ValueAccessor` for inter-call cache reuse:

- **`GradStencil{T}`** — 7-point: center + 6 face neighbors. Layout: `v[1]`=center, `v[2/3]`=±x, `v[4/5]`=±y, `v[6/7]`=±z. Methods: `gradient(s)` → NTuple{3,T} via central differences; `laplacian(s)` → T via 6-neighbor sum minus 6×center.
- **`BoxStencil{T}`** — 27-point (3x3x3). Index formula: `(dx+1)*9 + (dy+1)*3 + (dz+1) + 1`. Center is index 14. Methods: `value_at(s, dx, dy, dz)`, `mean_value(s)`.

Both use `move_to!(s, c)` to repopulate the cache at a new coordinate.

### DifferentialOps (`DifferentialOps.jl`)

All operate on active voxels only; results are new grids.

| Function | Input → Output | Notes |
|---|---|---|
| `gradient_grid` | `Grid{T}` → `Grid{NTuple{3,T}}` | Central differences via GradStencil, index space |
| `laplacian` | `Grid{T}` → `Grid{T}` | 6-point stencil: Σneighbors − 6×center |
| `divergence` | `Grid{NTuple{3,T}}` → `Grid{T}` | ∂Fx/∂x + ∂Fy/∂y + ∂Fz/∂z |
| `curl_grid` | `Grid{NTuple{3,T}}` → `Grid{NTuple{3,T}}` | ∇×F, all central differences |
| `magnitude_grid` | `Grid{NTuple{3,T}}` → `Grid{T}` | Euclidean norm pointwise |
| `normalize_grid` | `Grid{NTuple{3,T}}` → `Grid{NTuple{3,T}}` | Unit vectors; zero vectors stay zero |
| `mean_curvature` | `Grid{T}` → `Grid{T}` | κ = div(∇f/|∇f|) via BoxStencil; full 3x3x3 for cross derivatives |

Mean curvature uses the formula `[fx²(fyy+fzz) + ... − 2(fx·fy·fxy + ...)] / |∇f|³` implemented in a single BoxStencil pass (no intermediate grids).

Note: `gradient(tree, coord)` in `Interpolation.jl` is a point-wise function; `gradient_grid` in `DifferentialOps.jl` maps over all active voxels and returns a new grid.

---

## 8. FastSweeping: Eikonal Solver

**File**: `src/FastSweeping.jl`  
**Public API**: `reinitialize_sdf(grid; iterations=2) → Grid{T}`

**Equation solved**: `|∇φ| = 1` (isotropic Eikonal), with sign preserved from input (positive = outside, negative = inside).

**Algorithm** (Zhao 2004 Fast Sweeping):
1. Extract all active voxels into flat arrays (coords, values).
2. Build a dense coord→index map and precompute 6-neighbor index arrays.
3. Detect interface voxels by checking for sign changes among active neighbors; initialize their distance via linear interpolation to the zero-crossing: `dist = |v| / (|v| + |vn|) * h`. Non-interface voxels get a large sentinel `10 * bg`.
4. Precompute 4 sort orderings (alternating ±x, ±y, ±z signs give 8 sweep directions; 4 orderings × forward/backward = 8 sweeps per iteration).
5. Inner update: Godunov upwind Eikonal in 1D→2D→3D cascade — picks minimum absolute neighbor along each axis, sorts (a≤b≤c), solves `(u−a)²+(u−b)²+(u−c)²=h²`.
6. Clamp final distances to `bg`, reapply original signs, rebuild grid.

**Boundary conditions**: frozen at the interface (zero-crossing voxels are not updated after initialization). Domain boundary = background value (missing neighbors treated as background distance).

---

## 9. Meshing + MeshToVolume

### `Meshing.jl` — Volume to Mesh (Marching Cubes)

`volume_to_mesh(grid; isovalue=0) → (vertices, triangles)`

Classic Lorensen & Cline 1987. Iterates the active bounding box expanded by 1 voxel. For each cell:
- Reads 8 corner values; skips any cell touching `±background` (avoids fake zero-crossings at narrow-band boundary).
- Computes `cube_index` from sign tests (`val < isovalue` → inside → bit set).
- Looks up `MC_EDGE_TABLE[cube_index]` (12-bit edge mask) and `MC_TRI_TABLE[cube_index]` (up to 5 triangles).
- Linearly interpolates edge-crossing vertex positions, deduplicated via `Dict{(Coord,Coord), Int}`.
- Converts index-space positions to world space via voxel_size.

Returns world-space `Vector{NTuple{3,Float64}}` vertices and 1-indexed `Vector{NTuple{3,Int}}` triangles.

**Known gap**: `Meshing.jl` is ~526 lines with proportionally few tests (issue `l9f3`). Edge cases around degenerate configurations and narrow-band boundary skipping have limited test coverage.

### `MeshToVolume.jl` — Mesh to Level Set

`mesh_to_level_set(vertices, faces; voxel_size=1.0, half_width=3.0) → Grid{Float32}`

Implements Baerentzen & Aanes 2005 pseudonormal method for inside/outside sign. Per-triangle pipeline:
1. Precompute face normals, angle-weighted vertex pseudonormals, and edge pseudonormals.
2. Thread-parallel loop over triangles: for each triangle, iterate its AABB expanded by `half_width * voxel_size`. At each voxel, compute closest point on triangle (Ericson 7-region Voronoi), measure distance, determine sign from `dot(p - closest, pseudonormal) >= 0`.
3. Closest-wins merge across threads.

Requires a closed, consistently-oriented manifold mesh for correct sign. Degenerate triangles (zero normal) are skipped.

---

## 10. Supporting Files

### `PointAdvection.jl`

`advect_points(positions, field::VectorField3D, dt; method=:rk4)` — Advances a vector of particle positions through a `VectorField3D` for one time step. Supports Euler (1st order) and RK4 (4th order, default). Parallelized with `Threads.@threads` over particles. Returns `Vector{NTuple{3,Float64}}`. Depends on `FieldProtocol.jl` (`VectorField3D`, `evaluate`).

### `Segmentation.jl`

`segment_active_voxels(grid) → (Grid{Int32}, count)` — BFS flood fill over the active voxel set using 6-face connectivity. Seeds from any unvisited active voxel, assigns incrementing integer labels. Returns a label grid (background = 0) and the total number of connected components. Uses `_FACE_OFFSETS` from `Morphology.jl`. No distance weighting; all 6-connected active voxels belong to the same component.

### `IntegrationMethods.jl`

Defines a thin dispatch hierarchy `VolumeIntegrationMethod` with three concrete types: `ReferencePathTracer` (multi-scatter path tracer with NEE and Russian roulette; fields: `max_bounces`, `rr_start`), `SingleScatterTracer` (wraps existing single-scatter logic), and `EmissionAbsorption` (deterministic ray marcher; fields: `step_size`, `max_steps`). These types are passed as the second argument to `render_volume(scene, method, w, h)`, enabling dispatch-based renderer selection without if/else chains.

### `ImageCompare.jl`

Provides regression testing infrastructure for the render pipeline. `read_ppm` supports both P3 (ASCII) and P6 (binary) formats. Metrics: `image_rmse` (per-channel MSE across all pixels), `image_psnr` (20·log₁₀(1/RMSE)), `image_ssim` (simplified global SSIM on BT.709 luminance — not windowed), `image_max_diff` (worst-case absolute channel error). Also reads Mitsuba-format raw float32 images for ground-truth comparison (`read_float32_image`). `save_reference_render`/`load_reference_render` are thin wrappers for golden-image workflows.
