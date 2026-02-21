# Lyr.jl Usage Guide

## Installation

```julia
# From the Julia package registry
] add Lyr

# Or clone and develop locally
git clone https://github.com/tobiasosborne/Lyr.jl.git
cd Lyr.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
```

## Reading VDB Files

```julia
using Lyr

# Parse an OpenVDB file
vdb = parse_vdb("smoke.vdb")

# Inspect available grids
for grid in vdb.grids
    println(grid.name, " — ", grid.grid_type)
end

# Access a specific grid's tree
tree = vdb.grids[1].tree
```

## Accessing Voxels

### Direct Lookup

```julia
# Single voxel read — returns the stored value or background
val = get_value(tree, coord(10, 20, 30))
```

### Cached Lookup with ValueAccessor

For repeated lookups in the same spatial neighbourhood, `ValueAccessor`
caches internal node pointers and is significantly faster.

```julia
acc = ValueAccessor(tree)
for z in 1:64, y in 1:64, x in 1:64
    v = get_value(acc, coord(x, y, z))
    # ... process v ...
end
```

## Volume Rendering Pipeline

### 1. Build a NanoGrid

Convert the VDB tree into a flat NanoVDB buffer for fast traversal.

```julia
nano = build_nanogrid(tree)
```

### 2. Set Up the Scene

```julia
# Camera
cam = Camera(
    lookfrom = Vec3f(0, 0, -3),
    lookat   = Vec3f(0, 0, 0),
    vup      = Vec3f(0, 1, 0),
    vfov     = 40.0f0,
    aspect   = 16.0f0 / 9.0f0,
)

# Transfer function (maps density → color + opacity)
tf = tf_blackbody()          # see Presets section below

# Material wrapping grid + transfer function
mat = VolumeMaterial(nano, tf;
    density_scale = 100.0f0, # artistic density multiplier
    shadow_steps  = 4,       # shadow-ray march steps
)

# Assemble the scene
scene = Scene(cam, mat)
```

### 3. Render

**Monte Carlo (high quality)**

```julia
img = render_volume_image(scene, 960, 540; spp=64)
```

**Preview (fast, lower quality)**

```julia
img = render_volume_preview(scene, 480, 270)
```

### 4. Post-Process and Save

```julia
img = denoise_bilateral(img)        # edge-preserving denoise
img = tonemap_aces(img)             # filmic tone mapping
write_png("output.png", img)
```

### Full Minimal Example

```julia
using Lyr

vdb   = parse_vdb("smoke.vdb")
nano  = build_nanogrid(vdb.grids[1].tree)
cam   = Camera(lookfrom=Vec3f(0,0,-3), lookat=Vec3f(0,0,0),
               vup=Vec3f(0,1,0), vfov=40f0, aspect=16f0/9f0)
tf    = tf_blackbody()
mat   = VolumeMaterial(nano, tf; density_scale=100f0)
scene = Scene(cam, mat)

img = render_volume_image(scene, 960, 540; spp=32)
img = denoise_bilateral(img)
img = tonemap_aces(img)
write_png("smoke_render.png", img)
```

## Creating VDB from Data

### Gaussian Splatting

Turn a point cloud into a smooth density field, then build a VDB grid.

```julia
positions = [Vec3f(randn(), randn(), randn()) for _ in 1:500]
data = gaussian_splat(positions; radius=0.3f0, resolution=128)
grid = build_grid(data, 0.0f0)          # 0.0 background value
write_vdb("points.vdb", grid)
```

### Manual Grid Construction

```julia
builder = GridBuilder{Float32}(background=0.0f0)
for (i, j, k) in eachindex(my_array)
    v = my_array[i, j, k]
    v != 0.0f0 && set_value!(builder, coord(i, j, k), v)
end
grid = build_grid(builder)
write_vdb("custom.vdb", grid)
```

## Hydrogen Orbital Example

Render the electron probability density of hydrogen-like orbitals.

```julia
using Lyr

# Generate orbital density on a grid (n=3, l=2, m=0)
data = hydrogen_orbital(n=3, l=2, m=0, resolution=128, scale=12.0f0)

# Build VDB
grid = build_grid(data, 0.0f0)
nano = build_nanogrid(grid.tree)

# Render with a cool-warm palette
cam   = Camera(lookfrom=Vec3f(0,0,-25), lookat=Vec3f(0,0,0),
               vup=Vec3f(0,1,0), vfov=35f0, aspect=1f0)
tf    = tf_cool_warm()
mat   = VolumeMaterial(nano, tf; density_scale=50f0)
scene = Scene(cam, mat)

img = render_volume_image(scene, 512, 512; spp=64)
img = denoise_bilateral(img)
img = tonemap_aces(img)
write_png("hydrogen_3d0.png", img)
```

## Transfer Function Presets

| Function          | Description                              |
|-------------------|------------------------------------------|
| `tf_blackbody()`  | Black → red → orange → yellow → white    |
| `tf_viridis()`    | Perceptually uniform blue → green → yellow |
| `tf_cool_warm()`  | Blue (low) → white (mid) → red (high)   |
| `tf_smoke()`      | Transparent grey → opaque white          |

Each returns a `TransferFunction` that maps normalised density `[0,1]`
to RGBA colour. Pass directly to `VolumeMaterial`.

```julia
# Custom transfer function from arrays
colors   = [Vec4f(0,0,0,0), Vec4f(1,0.5,0,0.8), Vec4f(1,1,1,1)]
tf       = TransferFunction(colors)
```

## Tips

- **Performance**: Use `ValueAccessor` for any loop over voxels — it
  caches the last accessed leaf/internal nodes.
- **Memory**: `build_nanogrid` produces a compact flat buffer; prefer
  it over the tree for rendering workloads.
- **SPP tradeoff**: `spp=4` is fine for previews; `spp=64+` for
  production stills. Denoising helps bridge the gap.
- **GPU rendering**: The `gpu_render_volume` path uses
  KernelAbstractions.jl and works on CUDA/ROCm/Metal backends.
