# Visualize.jl - High-level field-to-image entry point
#
# The user (or agent) calls visualize(field) and gets a rendered image.
# Sensible defaults for everything. Presets replace GUI wizards.

# ============================================================================
# Camera presets
# ============================================================================

"""
    camera_orbit(center, distance; azimuth=45.0, elevation=30.0, fov=40.0) -> Camera

Create a camera orbiting around `center` at the given distance.

# Arguments
- `center::NTuple{3,Float64}` — Point to look at
- `distance::Float64` — Distance from center
- `azimuth::Float64` — Horizontal angle in degrees (default: 45)
- `elevation::Float64` — Vertical angle in degrees (default: 30)
- `fov::Float64` — Field of view in degrees (default: 40)
"""
function camera_orbit(center::NTuple{3,Float64}, distance::Float64;
                      azimuth::Float64=45.0, elevation::Float64=30.0,
                      fov::Float64=40.0)
    az = deg2rad(azimuth)
    el = deg2rad(elevation)
    x = center[1] + distance * cos(el) * cos(az)
    y = center[2] + distance * sin(el)
    z = center[3] + distance * cos(el) * sin(az)
    Camera((x, y, z), center, (0.0, 1.0, 0.0), fov)
end

"""
    camera_front(center, distance; fov=40.0) -> Camera

Create a camera looking at `center` from the front (+Z direction).
"""
function camera_front(center::NTuple{3,Float64}, distance::Float64;
                      fov::Float64=40.0)
    pos = (center[1], center[2], center[3] + distance)
    Camera(pos, center, (0.0, 1.0, 0.0), fov)
end

"""
    camera_iso(center, distance; fov=40.0) -> Camera

Create a camera at an isometric-style viewpoint (equal angles to all axes).
"""
function camera_iso(center::NTuple{3,Float64}, distance::Float64;
                    fov::Float64=40.0)
    d = distance / sqrt(3.0)
    pos = (center[1] + d, center[2] + d, center[3] + d)
    Camera(pos, center, (0.0, 1.0, 0.0), fov)
end

# ============================================================================
# Material presets
# ============================================================================

"""
    material_emission(; tf, sigma_scale, emission_scale, scattering_albedo) -> VolumeMaterial

Emission-dominated volume material. Good for scientific data visualization.

Default: viridis transfer function, moderate extinction, strong emission.
"""
function material_emission(; tf::TransferFunction=tf_viridis(),
                             sigma_scale::Float64=2.0,
                             emission_scale::Float64=5.0,
                             scattering_albedo::Float64=0.4)
    VolumeMaterial(tf; sigma_scale=sigma_scale,
                   emission_scale=emission_scale,
                   scattering_albedo=scattering_albedo)
end

"""
    material_cloud(; tf, sigma_scale, scattering_albedo) -> VolumeMaterial

Scattering-dominated material for cloud-like volumes.
High albedo means light scatters rather than being absorbed.
"""
function material_cloud(; tf::TransferFunction=tf_smoke(),
                          sigma_scale::Float64=1.0,
                          emission_scale::Float64=0.1,
                          scattering_albedo::Float64=0.9)
    VolumeMaterial(tf; sigma_scale=sigma_scale,
                   emission_scale=emission_scale,
                   scattering_albedo=scattering_albedo)
end

"""
    material_fire(; tf, sigma_scale, emission_scale) -> VolumeMaterial

Hot, emissive material for fire and explosion visualization.
Blackbody transfer function with strong emission.
"""
function material_fire(; tf::TransferFunction=tf_blackbody(),
                         sigma_scale::Float64=3.0,
                         emission_scale::Float64=8.0,
                         scattering_albedo::Float64=0.2)
    VolumeMaterial(tf; sigma_scale=sigma_scale,
                   emission_scale=emission_scale,
                   scattering_albedo=scattering_albedo)
end

# ============================================================================
# Light presets
# ============================================================================

"""
    light_studio() -> Vector{AbstractLight}

Single white directional light from upper-right. Clean, even illumination.
"""
light_studio() = AbstractLight[
    DirectionalLight((1.0, 1.0, 0.8), (2.5, 2.5, 2.5))
]

"""
    light_natural() -> Vector{AbstractLight}

Warm key light + cool fill light. Natural outdoor feel.
"""
light_natural() = AbstractLight[
    DirectionalLight((1.0, 0.8, 0.6), (3.0, 3.0, 3.0)),
    DirectionalLight((-0.5, 0.3, -1.0), (0.3, 0.4, 0.6))
]

"""
    light_dramatic() -> Vector{AbstractLight}

Strong directional key with minimal fill. High contrast.
"""
light_dramatic() = AbstractLight[
    DirectionalLight((1.0, 1.0, 0.5), (5.0, 5.0, 5.0)),
    DirectionalLight((-1.0, -0.5, -0.5), (0.1, 0.1, 0.15))
]

# ============================================================================
# Auto-camera from grid
# ============================================================================

function _auto_camera(grid)
    bbox = active_bounding_box(grid.tree)
    bbox === nothing && error("Cannot auto-camera: grid has no active voxels")

    vs = voxel_size(grid.transform)[1]

    cx = Float64(bbox.min.x + bbox.max.x) / 2.0 * vs
    cy = Float64(bbox.min.y + bbox.max.y) / 2.0 * vs
    cz = Float64(bbox.min.z + bbox.max.z) / 2.0 * vs

    ex = Float64(bbox.max.x - bbox.min.x) * vs
    ey = Float64(bbox.max.y - bbox.min.y) * vs
    ez = Float64(bbox.max.z - bbox.min.z) * vs
    max_ext = max(ex, ey, ez)
    dist = max_ext * 2.0

    Camera(
        (cx + dist * 0.7, cy + dist * 0.4, cz + dist * 0.7),
        (cx, cy, cz),
        (0.0, 1.0, 0.0),
        40.0
    )
end

"""
    _camera_to_index_space(cam::Camera, vs::Float64) -> Camera

Transform a world-space camera to index space by scaling its position by 1/voxel_size.
Direction vectors (forward, right, up) are unchanged under uniform scaling.
"""
function _camera_to_index_space(cam::Camera, vs::Float64)
    vs ≈ 1.0 && return cam
    inv_vs = 1.0 / vs
    Camera(cam.position * inv_vs, cam.forward, cam.right, cam.up, cam.fov)
end

# ============================================================================
# visualize — the main entry point
# ============================================================================

"""
    visualize(field; kwargs...) -> Matrix{NTuple{3, Float64}}

Render a field to an image with sensible defaults. One call produces a complete visualization.

Pipeline: `voxelize → build_nanogrid → auto-camera → Scene → render → tonemap → write`

# Arguments
- `field` — Any `AbstractContinuousField` or `ParticleField`

# Keyword Arguments

**Voxelization:**
- `voxel_size::Float64` — World-space voxel size (default: auto from `characteristic_scale`)
- `threshold::Float64` — Discard values below this after normalization (default: `1e-6`)

**Rendering:**
- `width::Int` — Image width in pixels (default: `512`)
- `height::Int` — Image height in pixels (default: `512`)
- `spp::Int` — Samples per pixel for production render (default: `4`)

**Material:**
- `material::VolumeMaterial` — Override material (default: emission-based viridis)
- `transfer_function::TransferFunction` — Override TF (ignored if `material` given)
- `sigma_scale::Float64` — Extinction scale (ignored if `material` given, default: `2.0`)
- `emission_scale::Float64` — Emission scale (ignored if `material` given, default: `5.0`)

**Scene:**
- `camera::Camera` — Override camera (default: auto from grid bounds)
- `lights::Vector{<:AbstractLight}` — Override lights (default: `light_studio()`)
- `background::NTuple{3,Float64}` — Background color (default: `(0.01, 0.01, 0.02)`)

**Post-processing:**
- `tonemap::Function` — Tonemapping function (default: `tonemap_aces`)
- `denoise::Bool` — Apply bilateral denoising (default: `false`)

**Output:**
- `output::Union{String, Nothing}` — File path to write (PNG or EXR, default: `nothing`)

# Returns
`Matrix{NTuple{3, Float64}}` — Tonemapped pixel data in [0, 1]

# Example
```julia
field = ScalarField3D(
    (x, y, z) -> exp(-(x^2 + y^2 + z^2)),
    BoxDomain((-3.0, -3.0, -3.0), (3.0, 3.0, 3.0)),
    1.0
)
# Minimal: one call, sensible defaults
pixels = visualize(field)

# With options
pixels = visualize(field;
    transfer_function=tf_blackbody(),
    spp=16,
    output="gaussian.png"
)
```
"""
function visualize(field::AbstractContinuousField;
                   # Voxelization
                   voxel_size::Float64=auto_voxel_size(field),
                   threshold::Float64=1e-6,
                   # Rendering
                   width::Int=512,
                   height::Int=512,
                   spp::Int=4,
                   # Material
                   material::Union{VolumeMaterial, Nothing}=nothing,
                   transfer_function::Union{TransferFunction, Nothing}=nothing,
                   sigma_scale::Float64=2.0,
                   emission_scale::Float64=5.0,
                   # Scene
                   camera::Union{Camera, Nothing}=nothing,
                   lights::Union{Vector{<:AbstractLight}, Nothing}=nothing,
                   background::NTuple{3,Float64}=(0.01, 0.01, 0.02),
                   # Post-processing
                   tonemap::Function=tonemap_aces,
                   denoise::Bool=false,
                   # Output
                   output::Union{String, Nothing}=nothing,
                   seed::UInt64=UInt64(42))

    # 1. Voxelize
    grid = voxelize(field; voxel_size=voxel_size, threshold=threshold)
    nanogrid = build_nanogrid(grid.tree)

    # 2-8. Shared render pipeline
    _render_grid(grid, nanogrid;
                 default_tf=tf_viridis(),
                 material=material, transfer_function=transfer_function,
                 sigma_scale=sigma_scale, emission_scale=emission_scale,
                 camera=camera, lights=lights, background=background,
                 width=width, height=height, spp=spp, seed=seed,
                 tonemap=tonemap, denoise=denoise, output=output)
end

function _write_output(path::String, pixels)
    if endswith(path, ".exr")
        write_exr(path, pixels)
    elseif endswith(path, ".ppm")
        write_ppm(path, pixels)
    else
        write_png(path, pixels)
    end
end

# Shared grid→image pipeline used by all visualize methods.
# Separated from voxelization so each field type handles its own grid building.
function _render_grid(grid, nanogrid;
                      default_tf::TransferFunction,
                      # Material
                      material::Union{VolumeMaterial, Nothing},
                      transfer_function::Union{TransferFunction, Nothing},
                      sigma_scale::Float64,
                      emission_scale::Float64,
                      # Scene
                      camera::Union{Camera, Nothing},
                      lights::Union{Vector{<:AbstractLight}, Nothing},
                      background::NTuple{3,Float64},
                      # Rendering
                      width::Int,
                      height::Int,
                      spp::Int,
                      seed::UInt64,
                      # Post-processing
                      tonemap::Function,
                      denoise::Bool,
                      # Output
                      output::Union{String, Nothing})

    cam = camera !== nothing ? camera : _auto_camera(grid)
    # Camera is in world space; renderer operates in index space
    vs = voxel_size(grid.transform)[1]
    cam = _camera_to_index_space(cam, vs)

    mat = if material !== nothing
        material
    else
        tf = transfer_function !== nothing ? transfer_function : default_tf
        VolumeMaterial(tf; sigma_scale=sigma_scale, emission_scale=emission_scale,
                       scattering_albedo=0.4)
    end

    lts = lights !== nothing ? convert(Vector{AbstractLight}, lights) : light_studio()

    volume = VolumeEntry(grid, nanogrid, mat)
    scene = Scene(cam, lts, volume; background=background)

    pixels = render_volume_image(scene, width, height; spp=spp, seed=seed)

    denoise && (pixels = denoise_bilateral(pixels))
    pixels = tonemap(pixels)

    if output !== nothing
        _write_output(output, pixels)
    end

    pixels
end

"""
    visualize(field::ParticleField; voxel_size, sigma, cutoff_sigma, kwargs...) -> Matrix{NTuple{3, Float64}}

Render a particle field via Gaussian splatting + volume rendering.

# Additional keyword arguments (beyond standard `visualize` kwargs):
- `sigma::Float64` — Gaussian kernel width in world units (default: `2.0`)
- `cutoff_sigma::Float64` — Kernel cutoff in sigma units (default: `3.0`)

See `visualize(::AbstractContinuousField)` for all other keyword arguments.
"""
function visualize(field::ParticleField;
                   voxel_size::Float64=1.0,
                   sigma::Float64=2.0,
                   cutoff_sigma::Float64=3.0,
                   threshold::Float64=1e-6,
                   # Rendering
                   width::Int=512,
                   height::Int=512,
                   spp::Int=4,
                   # Material
                   material::Union{VolumeMaterial, Nothing}=nothing,
                   transfer_function::Union{TransferFunction, Nothing}=nothing,
                   sigma_scale::Float64=2.0,
                   emission_scale::Float64=5.0,
                   # Scene
                   camera::Union{Camera, Nothing}=nothing,
                   lights::Union{Vector{<:AbstractLight}, Nothing}=nothing,
                   background::NTuple{3,Float64}=(0.01, 0.01, 0.02),
                   # Post-processing
                   tonemap::Function=tonemap_aces,
                   denoise::Bool=false,
                   # Output
                   output::Union{String, Nothing}=nothing,
                   seed::UInt64=UInt64(42))

    # 1. Voxelize particles
    grid = voxelize(field; voxel_size=voxel_size, sigma=sigma,
                    cutoff_sigma=cutoff_sigma, threshold=threshold)
    nanogrid = build_nanogrid(grid.tree)

    # 2-8. Shared render pipeline
    _render_grid(grid, nanogrid;
                 default_tf=tf_cool_warm(),
                 material=material, transfer_function=transfer_function,
                 sigma_scale=sigma_scale, emission_scale=emission_scale,
                 camera=camera, lights=lights, background=background,
                 width=width, height=height, spp=spp, seed=seed,
                 tonemap=tonemap, denoise=denoise, output=output)
end

"""
    visualize(te::TimeEvolution; t, kwargs...) -> Matrix{NTuple{3,Float64}}

Render a time-evolving field at time `t` (default: start of t_range).
All other keyword arguments are forwarded to the underlying field's `visualize`.
"""
function visualize(te::TimeEvolution;
                   t::Float64=te.t_range[1],
                   kwargs...)
    field = te.eval_fn(t)
    visualize(field; kwargs...)
end
