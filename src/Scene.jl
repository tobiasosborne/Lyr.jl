# Scene.jl - Scene description for volume and surface rendering
#
# Defines the scene graph: camera, lights, volumes with materials.
# Replaces hardcoded light direction in render_image.

# ============================================================================
# Light types
# ============================================================================

"""
    AbstractLight

Base type for scene lights.
"""
abstract type AbstractLight end

"""
    PointLight

A point light source in world space.

# Fields
- `position::SVec3d` - World-space position
- `intensity::SVec3d` - RGB intensity (can exceed 1.0 for HDR)
"""
struct PointLight <: AbstractLight
    position::SVec3d
    intensity::SVec3d
end

PointLight(pos::NTuple{3,Float64}, intensity::NTuple{3,Float64}) =
    PointLight(SVec3d(pos...), SVec3d(intensity...))

PointLight(pos::NTuple{3,Float64}) =
    PointLight(SVec3d(pos...), SVec3d(1.0, 1.0, 1.0))

"""
    DirectionalLight

An infinitely distant directional light.

# Fields
- `direction::SVec3d` - Direction TO the light (normalized)
- `intensity::SVec3d` - RGB intensity
"""
struct DirectionalLight <: AbstractLight
    direction::SVec3d
    intensity::SVec3d
end

function DirectionalLight(dir::NTuple{3,Float64}, intensity::NTuple{3,Float64})
    len = sqrt(dir[1]^2 + dir[2]^2 + dir[3]^2)
    d = len > 1e-10 ? SVec3d(dir[1]/len, dir[2]/len, dir[3]/len) : SVec3d(0.0, 0.0, 1.0)
    DirectionalLight(d, SVec3d(intensity...))
end

DirectionalLight(dir::NTuple{3,Float64}) =
    DirectionalLight(dir, (1.0, 1.0, 1.0))

# ============================================================================
# Volume material
# ============================================================================

"""
    VolumeMaterial

Material properties for a volume grid.

# Fields
- `transfer_function` - Maps density to RGBA (any TransferFunction)
- `phase_function` - Scattering phase function (any PhaseFunction)
- `sigma_scale::Float64` - Extinction coefficient multiplier
- `emission_scale::Float64` - Emission intensity multiplier
- `scattering_albedo::Float64` - Ratio of scattering to extinction [0,1]
"""
struct VolumeMaterial
    transfer_function::Any  # TransferFunction (uses Any to avoid circular dep)
    phase_function::Any     # PhaseFunction
    sigma_scale::Float64
    emission_scale::Float64
    scattering_albedo::Float64
end

function VolumeMaterial(tf; phase_function=nothing,
                        sigma_scale::Float64=1.0,
                        emission_scale::Float64=1.0,
                        scattering_albedo::Float64=0.5)
    pf = phase_function === nothing ? IsotropicPhase() : phase_function
    VolumeMaterial(tf, pf, sigma_scale, emission_scale, scattering_albedo)
end

# ============================================================================
# Volume entry (grid + optional NanoGrid + material)
# ============================================================================

"""
    VolumeEntry

A volume in the scene: a grid with its material and optional NanoGrid acceleration.

# Fields
- `grid::Grid` - The VDB grid (for accessor-based lookups)
- `nanogrid::Union{NanoGrid, Nothing}` - Optional NanoGrid for fast lookups
- `material::VolumeMaterial` - Material properties
"""
struct VolumeEntry
    grid::Any  # Grid{T}
    nanogrid::Union{NanoGrid, Nothing}
    material::VolumeMaterial
end

VolumeEntry(grid, material::VolumeMaterial) =
    VolumeEntry(grid, nothing, material)

# ============================================================================
# Scene
# ============================================================================

"""
    Scene

A complete scene description for rendering.

# Fields
- `camera::Camera` - The view camera
- `lights::Vector{AbstractLight}` - Scene lights
- `volumes::Vector{VolumeEntry}` - Volume grids with materials
- `background::SVec3d` - Background color (RGB)
"""
struct Scene
    camera::Camera
    lights::Vector{AbstractLight}
    volumes::Vector{VolumeEntry}
    background::SVec3d
end

function Scene(camera::Camera, lights::Vector{<:AbstractLight},
               volumes::Vector{VolumeEntry};
               background::NTuple{3,Float64}=(0.0, 0.0, 0.0))
    Scene(camera, convert(Vector{AbstractLight}, lights),
          volumes, SVec3d(background...))
end

# Convenience: single light, single volume
function Scene(camera::Camera, light::AbstractLight, volume::VolumeEntry;
               background::NTuple{3,Float64}=(0.0, 0.0, 0.0))
    Scene(camera, AbstractLight[light], VolumeEntry[volume];
          background=background)
end
