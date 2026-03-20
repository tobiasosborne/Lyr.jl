# Lyr.jl Usage Guide

Lyr.jl is a pure Julia OpenVDB parser, grid construction toolkit, and production
volume renderer. This guide covers every public API surface with copy-pasteable
examples verified against the source code.

---

## Table of Contents

1. [Installation](#1-installation)
2. [Reading VDB Files](#2-reading-vdb-files)
3. [Querying Voxels](#3-querying-voxels)
4. [Grid Construction](#4-grid-construction)
5. [Particles and Meshes](#5-particles-and-meshes)
6. [CSG Operations](#6-csg-operations)
7. [Grid Operations](#7-grid-operations)
8. [Level Set Operations](#8-level-set-operations)
9. [Differential Operators](#9-differential-operators)
10. [Filtering and Morphology](#10-filtering-and-morphology)
11. [Interpolation](#11-interpolation)
12. [Volume Rendering](#12-volume-rendering)
13. [Transfer Functions](#13-transfer-functions)
14. [Post-Processing](#14-post-processing)
15. [Output Formats](#15-output-formats)
16. [Field Protocol](#16-field-protocol)
17. [General Relativity](#17-general-relativity)
18. [Hydrogen Atom](#18-hydrogen-atom)
19. [Animation](#19-animation)
20. [Writing VDB Files](#20-writing-vdb-files)
21. [Tips and Gotchas](#21-tips-and-gotchas)

---

## 1. Installation

```julia
using Pkg
Pkg.add(url="https://github.com/tobiasosborne/Lyr.jl")
```

Then load the module:

```julia
using Lyr
```

Optional dependencies for image output:

```julia
using PNGFiles   # enables write_png (otherwise falls back to PPM)
using OpenEXR    # enables write_exr for HDR output
```

---

## 2. Reading VDB Files

`parse_vdb` takes a `Vector{UInt8}` and returns a `VDBFile` containing a header
and a vector of grids.

```julia
bytes = read("smoke.vdb")
vdb = parse_vdb(bytes)

# Inspect the file
println(vdb)                     # VDBFile(v224, 2 grids, "density", "temperature")
println(vdb.header.format_version)

# Access individual grids
grid = vdb.grids[1]
println(grid.name)               # "density"
println(grid.grid_class)         # GRID_FOG_VOLUME or GRID_LEVEL_SET

# Tree structure
tree = grid.tree
println(tree.background)         # background value (e.g. 0.0f0)
```

---

## 3. Querying Voxels

### Direct tree lookup

```julia
val = get_value(tree, coord(10, 20, 30))
active = is_active(tree, coord(10, 20, 30))
```

### ValueAccessor (cached, 5-8x faster for coherent access)

```julia
acc = ValueAccessor(tree)
v1 = get_value(acc, coord(10, 20, 30))  # full traversal, caches leaf
v2 = get_value(acc, coord(10, 20, 31))  # cache hit -- O(1)
```

### Iterating voxels

```julia
# Active voxels: (coord, value) pairs
for (c, v) in active_voxels(tree)
    println("$(c.x), $(c.y), $(c.z) => $v")
end

# Inactive voxels within leaves
for (c, v) in inactive_voxels(tree)
    # ...
end

# All voxels within leaves (active + inactive)
for (c, v) in all_voxels(tree)
    # ...
end
```

### Counting and traversal

```julia
n = active_voxel_count(tree)
n_leaves = leaf_count(tree)

# Iterate leaf nodes directly
for leaf in leaves(tree)
    println(leaf.origin)
end

# Internal nodes
for node in i1_nodes(tree)
    # InternalNode1 nodes
end
for node in i2_nodes(tree)
    # InternalNode2 nodes
end
```

---

## 4. Grid Construction

### From sparse data (Dict)

```julia
data = Dict(
    coord(0, 0, 0) => 1.0f0,
    coord(1, 0, 0) => 0.5f0,
    coord(0, 1, 0) => 0.3f0,
)
grid = build_grid(data, 0.0f0; name="density", voxel_size=1.0)
```

Parameters:
- `data::Dict{Coord, T}` -- sparse voxel data
- `background::T` -- value for unset voxels
- `name::String` -- grid name (default: `"density"`)
- `grid_class::GridClass` -- `GRID_FOG_VOLUME` (default) or `GRID_LEVEL_SET`
- `voxel_size::Float64` -- uniform voxel size (default: `1.0`)

### From dense 3D array

```julia
array = rand(Float32, 64, 64, 64)
grid = copy_from_dense(array, 0.0f0;
    bbox_min=coord(0, 0, 0),
    name="density",
    voxel_size=1.0
)
```

Only values that differ from the background are stored as active voxels.

### Level set sphere

```julia
sphere = create_level_set_sphere(
    center=(0.0, 0.0, 0.0),
    radius=10.0;
    voxel_size=1.0,
    half_width=3.0,
    name="level_set"
)
```

### Level set box

```julia
box = create_level_set_box(
    min_corner=(-5.0, -5.0, -5.0),
    max_corner=(5.0, 5.0, 5.0);
    voxel_size=1.0,
    half_width=3.0
)
```

---

## 5. Particles and Meshes

### Particles to SDF (level set)

Converts particle positions to a level set via CSG union of sphere SDFs.

```julia
positions = [(0.0, 0.0, 0.0), (5.0, 0.0, 0.0), (2.5, 3.0, 0.0)]
grid = particles_to_sdf(positions, 3.0; voxel_size=0.5, half_width=3.0)

# Per-particle radii
radii = [3.0, 2.0, 1.5]
grid = particles_to_sdf(positions, radii; voxel_size=0.5)
```

### Particle trails to SDF

Generates motion-blurred capsule SDFs from position/velocity pairs.

```julia
positions = [(0.0, 0.0, 0.0), (10.0, 0.0, 0.0)]
velocities = [(1.0, 0.0, 0.0), (-1.0, 0.0, 0.0)]
grid = particle_trails_to_sdf(positions, velocities, 2.0;
    dt=1.0, voxel_size=0.5, half_width=3.0
)
```

### Gaussian splatting (fog density)

Returns a `Dict{Coord, Float32}` for use with `build_grid`.

```julia
positions = [SVec3d(randn(3)...) for _ in 1:1000]
density = gaussian_splat(positions; voxel_size=1.0, sigma=2.0, cutoff_sigma=3.0)
grid = build_grid(density, 0.0f0; name="particles")
```

### Mesh to level set

Converts a closed triangle mesh to a narrow-band SDF via per-triangle
voxelization with angle-weighted pseudonormal sign determination.

```julia
vertices = [SVec3d(0,0,0), SVec3d(1,0,0), SVec3d(0,1,0), SVec3d(0,0,1)]
faces = [(1,2,3), (1,2,4), (1,3,4), (2,3,4)]  # tetrahedron
grid = mesh_to_level_set(vertices, faces; voxel_size=0.1)
```

---

## 6. CSG Operations

CSG operations combine two level set grids. Level set convention: negative =
inside, positive = outside.

```julia
sphere = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0)
box = create_level_set_box(min_corner=(-8.0, -8.0, -8.0), max_corner=(8.0, 8.0, 8.0))

# Union: min(sdf_a, sdf_b)
combined = csg_union(sphere, box)

# Intersection: max(sdf_a, sdf_b)
overlap = csg_intersection(sphere, box)

# Difference: max(sdf_a, -sdf_b) -- sphere minus box
carved = csg_difference(sphere, box)
```

All CSG operations return a new grid. Input grids must have the same value type.

---

## 7. Grid Operations

All operations are non-mutating and return new grids.

### Compositing (element-wise)

```julia
# Maximum at each overlapping voxel
result = comp_max(grid_a, grid_b)

# Minimum
result = comp_min(grid_a, grid_b)

# Sum (additive blending)
result = comp_sum(grid_a, grid_b)

# Multiply
result = comp_mul(grid_a, grid_b)

# Replace (B stamps on top of A)
result = comp_replace(grid_a, grid_b)
```

### Clipping

```julia
using Lyr: BBox

# Clip to bounding box
bbox = BBox(coord(-10, -10, -10), coord(10, 10, 10))
clipped = clip(grid, bbox)

# Clip to mask grid (keep only where mask is active)
clipped = clip(grid, mask_grid)
```

### Background and activation

```julia
# Change background value
grid2 = change_background(grid, 0.5f0)

# Activate voxels matching a value
grid2 = activate(grid, 0.0f0)

# Deactivate voxels matching a value
grid2 = deactivate(grid, 0.0f0)
```

### Pruning

```julia
grid2 = prune(grid)
```

### Dense extraction

```julia
bbox = BBox(coord(0, 0, 0), coord(63, 63, 63))
array = copy_to_dense(grid, bbox)  # returns Array{T, 3}
```

---

## 8. Level Set Operations

### SDF to fog conversion

```julia
# Interior maps to 1.0, exterior to 0.0, narrow band gets linear ramp
fog = sdf_to_fog(sphere)
fog = sdf_to_fog(sphere; cutoff=0.0f0)
```

### Interior mask

```julia
mask = sdf_interior_mask(sphere)  # 1.0 where SDF < 0, else 0.0
```

### Isosurface mask

```julia
shell = extract_isosurface_mask(grid; isovalue=0.0f0)  # thin shell at zero crossing
```

### Area and volume measurement

```julia
area = level_set_area(sphere)      # surface area in world units squared
vol = level_set_volume(sphere)     # enclosed volume in world units cubed
```

### Diagnostic validation

```julia
diag = check_level_set(sphere)
println(diag.valid)            # true/false
println(diag.issues)           # Vector{String} of problems
println(diag.active_count)
println(diag.interior_count)
println(diag.exterior_count)
```

---

## 9. Differential Operators

All operators use central differences in index space and return new grids.

```julia
# Gradient: scalar grid -> vector grid (NTuple{3,T})
grad = gradient_grid(scalar_grid)

# Laplacian: scalar grid -> scalar grid
lap = laplacian(scalar_grid)

# Divergence: vector grid -> scalar grid
div_field = divergence(vector_grid)

# Curl: vector grid -> vector grid
curl_field = curl_grid(vector_grid)

# Mean curvature: scalar grid -> scalar grid
# For a sphere of radius R, kappa = 2/R at the surface
kappa = mean_curvature(level_set_grid)

# Magnitude: vector grid -> scalar grid
mag = magnitude_grid(vector_grid)
```

---

## 10. Filtering and Morphology

### Smoothing filters

```julia
# Mean filter (3x3x3 box blur)
smoothed = filter_mean(grid; iterations=3)

# Gaussian filter (weighted 3x3x3 kernel)
smoothed = filter_gaussian(grid; sigma=1.0f0, iterations=2)
```

Multiple iterations widen the effective kernel (iterated box filter converges
to Gaussian by the central limit theorem).

### Morphological operations

```julia
# Dilate: expand active region by activating face neighbors
expanded = dilate(grid; iterations=2)

# Erode: contract active region by removing boundary voxels
contracted = erode(grid; iterations=1)
```

### SDF reinitialization

```julia
grid2 = reinitialize_sdf(grid)
```

---

## 11. Interpolation

### Trilinear sampling (index space)

```julia
val = sample_trilinear(tree, SVec3d(10.5, 20.3, 30.7))
```

### Quadratic B-spline sampling (27-point stencil, C1 smooth)

```julia
val = sample_quadratic(tree, SVec3d(10.5, 20.3, 30.7))
```

### World-space sampling

```julia
val = sample_world(grid, SVec3d(5.0, 10.0, 15.0))
val = sample_world(grid, SVec3d(5.0, 10.0, 15.0), QuadraticInterpolation())
```

Tuple convenience wrappers also work:

```julia
val = sample_trilinear(tree, (10.5, 20.3, 30.7))
val = sample_world(grid, (5.0, 10.0, 15.0))
```

### Resampling

```julia
# Resample source to match target grid's resolution and topology
resampled = resample_to_match(source_grid, target_grid)
resampled = resample_to_match(source_grid, target_grid; method=QuadraticInterpolation())

# Resample to a specific voxel size
resampled = resample_to_match(source_grid; voxel_size=0.5)
```

---

## 12. Volume Rendering

The rendering pipeline has five components: Camera, Lights, Material, NanoGrid,
and Scene.

### Camera

Camera takes four positional arguments as tuples: position, target, up, fov.

```julia
cam = Camera(
    (50.0, 40.0, 30.0),   # position
    (0.0, 0.0, 0.0),      # target (look-at point)
    (0.0, 1.0, 0.0),      # up direction
    40.0                    # field of view in degrees
)
```

Camera presets:

```julia
cam = camera_orbit((0.0, 0.0, 0.0), 50.0; azimuth=45.0, elevation=30.0, fov=40.0)
cam = camera_front((0.0, 0.0, 0.0), 50.0; fov=40.0)
cam = camera_iso((0.0, 0.0, 0.0), 50.0; fov=40.0)
```

### Lights

```julia
# Directional light: direction (toward light), intensity (RGB)
light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 0.8, 0.6))
light = DirectionalLight((1.0, 1.0, 1.0))  # white

# Point light: position, intensity (RGB)
light = PointLight((50.0, 50.0, 50.0), (2.0, 2.0, 2.0))
light = PointLight((50.0, 50.0, 50.0))  # white

# Constant environment light (for white furnace tests)
light = ConstantEnvironmentLight((1.0, 1.0, 1.0))
```

Light presets:

```julia
lights = light_studio()    # single white directional
lights = light_natural()   # warm key + cool fill
lights = light_dramatic()  # strong key, minimal fill
```

### Volume material

The transfer function is the first positional argument. Everything else is a
keyword argument.

```julia
mat = VolumeMaterial(tf_blackbody();
    sigma_scale=15.0,           # extinction coefficient multiplier
    emission_scale=1.0,         # emission intensity multiplier
    scattering_albedo=0.5       # ratio of scattering to extinction [0, 1]
)
```

Material presets:

```julia
mat = material_emission()   # viridis TF, emission-dominated
mat = material_cloud()      # smoke TF, high-albedo scattering
mat = material_fire()       # blackbody TF, strong emission
```

### NanoGrid (required before rendering)

The NanoGrid is a flat-buffer representation of the VDB tree for fast rendering.
You must build it before creating a VolumeEntry.

```julia
nano = build_nanogrid(grid.tree)  # pass the tree, not the grid
```

### VolumeEntry and Scene

```julia
vol = VolumeEntry(grid, nano, mat)   # positional: grid, nanogrid, material
scene = Scene(cam, light, vol)       # positional: camera, light, volume

# With background color
scene = Scene(cam, light, vol; background=(0.01, 0.01, 0.02))

# Multiple lights and volumes
scene = Scene(cam, [light1, light2], [vol1, vol2])
```

### Rendering

```julia
# Production render (delta tracking, single scatter)
img = render_volume_image(scene, 800, 600; spp=32, max_bounces=1)

# Fast preview (emission-absorption, deterministic)
img = render_volume_preview(scene, 800, 600; step_size=0.5, max_steps=2000)
```

### Complete example

```julia
using Lyr

# Build a sphere
sphere = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0)
fog = sdf_to_fog(sphere)

# Set up rendering
cam = Camera((30.0, 25.0, 30.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 40.0)
light = DirectionalLight((1.0, 1.0, 1.0), (2.0, 2.0, 2.0))
mat = VolumeMaterial(tf_blackbody(); sigma_scale=10.0, emission_scale=3.0)
nano = build_nanogrid(fog.tree)
vol = VolumeEntry(fog, nano, mat)
scene = Scene(cam, light, vol)

img = render_volume_image(scene, 800, 600; spp=16)
write_ppm("sphere.ppm", img)
```

---

## 13. Transfer Functions

Transfer functions map scalar density values to RGBA colors via piecewise-linear
interpolation between control points.

### Built-in presets

```julia
tf = tf_blackbody()    # black -> red -> orange -> yellow -> white (fire)
tf = tf_cool_warm()    # blue -> white -> red (diverging, scientific)
tf = tf_smoke()        # transparent -> gray -> black (absorbing media)
tf = tf_viridis()      # dark purple -> blue -> green -> yellow (perceptual)
```

Quantum visualization presets (from Animation module):

```julia
tf = tf_electron()     # blue-white (probability density)
tf = tf_photon()       # red-orange (EM field energy)
tf = tf_excited()      # purple-magenta (excited states)
```

### Custom transfer functions

```julia
tf = TransferFunction([
    ControlPoint(0.0, (0.0, 0.0, 0.0, 0.0)),   # (R, G, B, A) at density 0
    ControlPoint(0.3, (0.2, 0.0, 0.8, 0.4)),
    ControlPoint(0.7, (0.8, 0.2, 0.0, 0.8)),
    ControlPoint(1.0, (1.0, 1.0, 1.0, 1.0)),
])
```

### Evaluation

```julia
rgba = evaluate(tf, 0.5)  # returns NTuple{4, Float64}
```

---

## 14. Post-Processing

### Tone mapping

```julia
# Reinhard: x / (1 + x)
mapped = tonemap_reinhard(img)

# ACES filmic curve (Narkowicz approximation)
mapped = tonemap_aces(img)

# Exposure: 1 - exp(-x * exposure)
mapped = tonemap_exposure(img, 2.0)

# Auto-exposure based on log-average luminance
exposure = auto_exposure(img)
mapped = tonemap_exposure(img, exposure)
```

### Denoising

```julia
# Bilateral filter (fast, edge-preserving)
denoised = denoise_bilateral(img;
    spatial_sigma=2.0,
    range_sigma=0.1,
    radius=0       # 0 = auto
)

# Non-local means (slower but better for Monte Carlo noise)
denoised = denoise_nlm(img;
    search_radius=7,    # 15x15 search window
    patch_radius=3,     # 7x7 comparison patches
    h=0.1               # filtering strength
)
```

---

## 15. Output Formats

### PPM (always available)

```julia
write_ppm("output.ppm", img)
```

### PNG (requires PNGFiles.jl)

```julia
using PNGFiles  # must be loaded before calling write_png
write_png("output.png", img; gamma=2.2)
```

If PNGFiles is not loaded, `write_png` falls back to PPM with a warning and
writes to `output.ppm` instead.

### EXR (requires OpenEXR.jl)

```julia
using OpenEXR
write_exr("output.exr", img)
write_exr("output.exr", img; depth=depth_buffer)  # optional depth channel
```

### Reading images

```julia
pixels = read_ppm("reference.ppm")

# Image comparison metrics
rmse = image_rmse(img_a, img_b)
psnr = image_psnr(img_a, img_b)
ssim = image_ssim(img_a, img_b)
max_diff = image_max_diff(img_a, img_b)
```

---

## 16. Field Protocol

The Field Protocol bridges physics computation and volumetric rendering. Define
a continuous function, and Lyr handles voxelization and rendering automatically.

### ScalarField3D

```julia
field = ScalarField3D(
    (x, y, z) -> exp(-(x^2 + y^2 + z^2) / 50),
    BoxDomain(SVec3d(-10, -10, -10), SVec3d(10, 10, 10)),
    5.0  # characteristic_scale: feature size in world units
)

# One-call rendering with sensible defaults
img = visualize(field)

# Or step by step
grid = voxelize(field)                   # auto voxel_size = scale / 5
grid = voxelize(field; voxel_size=0.5)   # explicit voxel size
```

BoxDomain also accepts tuples:

```julia
dom = BoxDomain((-10.0, -10.0, -10.0), (10.0, 10.0, 10.0))
```

### VectorField3D

```julia
field = VectorField3D(
    (x, y, z) -> SVec3d(-y, x, 0.0),   # rotation field
    BoxDomain((-5.0, -5.0, -5.0), (5.0, 5.0, 5.0)),
    2.0
)
grid = voxelize(field)  # voxelizes the magnitude |v|
```

### ComplexScalarField3D

For quantum wavefunctions. Voxelization uses probability density |psi|^2.

```julia
a0 = 1.0
field = ComplexScalarField3D(
    (x, y, z) -> exp(-sqrt(x^2 + y^2 + z^2) / a0) + 0im,
    BoxDomain((-10.0, -10.0, -10.0), (10.0, 10.0, 10.0)),
    a0
)
grid = voxelize(field)
```

### ParticleField

```julia
positions = [SVec3d(randn(3)...) for _ in 1:1000]
field = ParticleField(positions)
field = ParticleField(positions;
    velocities=[SVec3d(randn(3)...) for _ in 1:1000],
    properties=Dict{Symbol, Vector}(:mass => rand(1000))
)

# Voxelizes via Gaussian splatting
grid = voxelize(field; voxel_size=0.5, sigma=1.0)
```

### TimeEvolution

Wraps a time-varying field for animation.

```julia
evolving = TimeEvolution{ScalarField3D}(
    t -> ScalarField3D(
        (x, y, z) -> exp(-(x^2 + y^2 + z^2) / 2.0) * cos(t),
        BoxDomain((-5.0, -5.0, -5.0), (5.0, 5.0, 5.0)),
        1.0
    ),
    (0.0, 2pi),   # t_range
    0.1            # dt_hint
)

# Get field at a specific time
field_at_t0 = evolving.eval_fn(0.0)

# Voxelize at a specific time
grid = voxelize(evolving; t=1.0)
```

### Interface functions

```julia
dom = domain(field)                      # BoxDomain
et = field_eltype(field)                 # Float64, SVec3d, ComplexF64
scale = characteristic_scale(field)      # Float64
val = evaluate(field, 0.0, 0.0, 0.0)    # sample at a point
```

### visualize options

```julia
img = visualize(field;
    # Voxelization
    voxel_size=0.5,
    threshold=1e-6,
    # Rendering
    width=800, height=600,
    spp=16,
    # Material
    material=VolumeMaterial(tf_blackbody(); sigma_scale=10.0),
    transfer_function=tf_viridis(),   # ignored if material is given
    sigma_scale=2.0,                  # ignored if material is given
    emission_scale=5.0,               # ignored if material is given
    # Scene
    camera=Camera((30.0, 20.0, 30.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 40.0),
    lights=light_natural(),
    background=(0.01, 0.01, 0.02),
    # Post-processing
    tonemap=tonemap_aces,
    denoise=false,
    # Output
    output="field.ppm"
)
```

---

## 17. General Relativity

The GR submodule provides backward null geodesic ray tracing through curved
spacetimes. All types live under `Lyr.GR`.

```julia
using Lyr.GR
```

### Metrics

```julia
# Schwarzschild black hole (mass M in geometric units G=c=1)
m = Schwarzschild(1.0)
horizon_radius(m)        # 2.0 (= 2M)
photon_sphere_radius(m)  # 3.0 (= 3M)
isco_radius(m)           # 6.0 (= 6M)

# Kerr black hole (mass M, spin a)
m = Kerr{BoyerLindquist}(1.0, 0.9)

# Minkowski (flat spacetime)
m = Minkowski()
```

### Camera

The GR camera uses a local Lorentz frame (tetrad) at a spacetime point.
`static_camera` is the convenience constructor:

```julia
# static_camera(metric, r, theta, phi, fov, (width, height))
cam = static_camera(Schwarzschild(1.0), 30.0, pi/2, 0.0, 60.0, (800, 600))
```

This places a static observer at Boyer-Lindquist coordinates `(r=30, theta=pi/2, phi=0)`.

### Accretion disk (thin)

```julia
disk = ThinDisk(6.0, 30.0)  # inner_radius, outer_radius
```

### Accretion disk (thick / volumetric)

```julia
thick = ThickDisk(6.0, 30.0, 0.15, 10.0)  # r_inner, r_outer, h/r, amplitude
vol = VolumetricMatter(Schwarzschild(1.0), thick, 6.0, 30.0)
```

### Render configuration

```julia
config = GRRenderConfig(
    integrator=IntegratorConfig(
        stepper=RK4(),          # or Verlet()
        step_size=0.1,
        max_steps=50000
    ),
    background=(0.0, 0.0, 0.02),
    use_redshift=true,
    use_threads=true,
    samples_per_pixel=4
)
```

### Rendering

```julia
# Thin disk
img = gr_render_image(cam, config; disk=disk)

# Volumetric disk (emission-absorption integration)
img = gr_render_image(cam, config; volume=vol)

# With celestial sphere background
# sky = CelestialSphere(...)
# img = gr_render_image(cam, config; disk=disk, sky=sky)

write_ppm("blackhole.ppm", img)
```

### Complete example

```julia
using Lyr, Lyr.GR

m = Schwarzschild(1.0)
cam = static_camera(m, 30.0, pi/2, 0.0, 60.0, (800, 600))
disk = ThinDisk(isco_radius(m), 25.0)
config = GRRenderConfig(
    integrator=IntegratorConfig(step_size=0.05, max_steps=100000),
    use_redshift=true,
    samples_per_pixel=4
)
img = gr_render_image(cam, config; disk=disk)
write_ppm("schwarzschild_disk.ppm", img)
```

---

## 18. Hydrogen Atom

Lyr includes analytical hydrogen eigenstates integrated with the Field Protocol.

### Direct wavefunction evaluation

```julia
# hydrogen_psi(n, l, m, x, y, z) -> ComplexF64
psi = hydrogen_psi(2, 1, 0, 1.0, 0.0, 0.0)
prob_density = abs2(psi)
```

### HydrogenOrbitalField (Field Protocol)

```julia
# Creates a ComplexScalarField3D with auto-sized domain
field = HydrogenOrbitalField(3, 2, 0)          # 3d_z^2 orbital
field = HydrogenOrbitalField(2, 1, 1)          # 2p_+1 orbital
field = HydrogenOrbitalField(4, 3, 0; R_max=50.0)  # custom extent

# Render directly
img = visualize(field)
write_ppm("3d_orbital.ppm", img)

# Or voxelize for further processing
grid = voxelize(field)
```

### Molecular orbitals (LCAO)

```julia
# H2 bonding orbital at bond length R = 1.4 Bohr
field = MolecularOrbitalField(
    [1.0, 1.0],                             # coefficients
    [(1, 0, 0), (1, 0, 0)],                 # quantum numbers (n, l, m)
    [(0.0, 0.0, -0.7), (0.0, 0.0, 0.7)]    # nuclear positions
)
img = visualize(field)
```

Convenience functions for H2:

```julia
# Direct evaluation (R = bond length, returns ComplexF64)
psi_bond = h2_bonding(1.4, 0.0, 0.0, 0.0)
psi_anti = h2_antibonding(1.4, 0.0, 0.0, 0.0)
```

---

## 19. Animation

Render time-evolving fields as video via frame-by-frame voxelization and
rendering, stitched to MP4 with ffmpeg.

### Camera modes

```julia
# Fixed camera
cam_mode = FixedCamera((30.0, 20.0, 30.0), (0.0, 0.0, 0.0);
    up=(0.0, 1.0, 0.0), fov=40.0
)

# Orbiting camera
cam_mode = OrbitCamera((0.0, 0.0, 0.0), 50.0;
    elevation=30.0, fov=40.0, revolutions=1.0
)

# Follow a moving target
cam_mode = FollowCamera(t -> (sin(t), 0.0, cos(t)), 20.0;
    elevation=30.0, fov=40.0
)

# Fully custom
cam_mode = FunctionCamera(t -> Camera(
    (30.0 * cos(t), 20.0, 30.0 * sin(t)),
    (0.0, 0.0, 0.0),
    (0.0, 1.0, 0.0),
    40.0
))
```

### render_animation

```julia
# Define a time-evolving field
evolving = TimeEvolution{ScalarField3D}(
    t -> ScalarField3D(
        (x, y, z) -> exp(-(x^2 + y^2 + z^2) / (2 + t)),
        BoxDomain((-5.0, -5.0, -5.0), (5.0, 5.0, 5.0)),
        1.0
    ),
    (0.0, 5.0),
    0.1
)

mat = VolumeMaterial(tf_viridis(); sigma_scale=5.0, emission_scale=3.0)

output = render_animation(evolving, mat,
    OrbitCamera((0.0, 0.0, 0.0), 20.0);
    t_range=(0.0, 5.0),
    nframes=60,
    fps=30,
    width=512, height=512,
    spp=4,
    output="expanding_gaussian.mp4"
)
```

Multi-field animation:

```julia
render_animation([field1, field2], [mat1, mat2], cam_mode;
    t_range=(0.0, 10.0), nframes=120
)
```

### Stitching frames manually

```julia
success = stitch_to_mp4("frames_dir", "output.mp4"; fps=30, pattern="frame_%04d.ppm")
```

---

## 20. Writing VDB Files

Write grids to OpenVDB-compatible `.vdb` files.

```julia
# Write a single grid
write_vdb("output.vdb", grid)

# With compression
write_vdb("output.vdb", grid; codec=NoCompression())

# Half precision (Float32/64 -> Float16)
write_vdb("output.vdb", grid; half_precision=true)

# Write a complete VDBFile (multiple grids)
vdb = VDBFile(header, [grid1, grid2])
write_vdb("multi.vdb", vdb)
```

Round-trip test:

```julia
data = Dict(coord(0,0,0) => 1.0f0, coord(1,0,0) => 0.5f0)
grid = build_grid(data, 0.0f0; name="test")
write_vdb("roundtrip.vdb", grid)

bytes = read("roundtrip.vdb")
vdb2 = parse_vdb(bytes)
grid2 = vdb2.grids[1]
```

---

## 21. Tips and Gotchas

### Camera takes tuples, not SVec3d

```julia
# Correct
cam = Camera((50.0, 40.0, 30.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 40.0)

# Wrong -- will not work
# cam = Camera(SVec3d(50, 40, 30), SVec3d(0, 0, 0), SVec3d(0, 1, 0), 40.0)
```

### build_nanogrid takes the tree, not the grid

```julia
nano = build_nanogrid(grid.tree)  # correct
# nano = build_nanogrid(grid)     # wrong
```

### NanoGrid is required before rendering

If you forget to build the NanoGrid, `render_volume_image` will throw an
`ArgumentError`.

### Level set convention

- **Negative** = inside the surface
- **Zero** = on the surface
- **Positive** = outside the surface
- Background value = `half_width * voxel_size`

### All grid operations return new grids

The VDB tree is immutable. Every operation (CSG, filtering, compositing)
returns a fresh grid. The input is never modified.

### Field Protocol domains vs VDB coordinates

- `BoxDomain` uses `SVec3d` (Float64 world-space coordinates)
- `BBox` uses `Coord` (Int32 index-space coordinates)
- Camera and renderer operate in index space internally
- `voxelize()` handles the world-to-index conversion

### write_png requires PNGFiles

```julia
using PNGFiles   # must be loaded BEFORE calling write_png
write_png("output.png", img)
```

Without PNGFiles loaded, `write_png` silently falls back to PPM format and
writes `output.ppm` instead.

### Float literal gotcha

`1e-5f0` is not valid Julia. Use `Float32(1e-5)` instead.

### Coordinate constructor

Use `coord()` (lowercase) for convenience:

```julia
c = coord(10, 20, 30)  # returns Coord(Int32(10), Int32(20), Int32(30))
```

### Thread safety

Most rendering and voxelization functions use `Threads.@threads` internally.
Run Julia with multiple threads for best performance:

```bash
julia -t auto --project your_script.jl
```

### GR module is namespaced

GR types live in their own module:

```julia
using Lyr.GR
cam = static_camera(Schwarzschild(1.0), 30.0, pi/2, 0.0, 60.0, (800, 600))
```
