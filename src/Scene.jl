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
    d = SVec3d(dir...)
    d = norm(d) > 1e-10 ? normalize(d) : SVec3d(0.0, 0.0, 1.0)
    DirectionalLight(d, SVec3d(intensity...))
end

DirectionalLight(dir::NTuple{3,Float64}) =
    DirectionalLight(dir, (1.0, 1.0, 1.0))

"""
    ConstantEnvironmentLight <: AbstractLight

Uniform radiance from all directions (for white furnace tests).
When a ray escapes the volume, it receives this radiance instead of `scene.background`.
"""
struct ConstantEnvironmentLight <: AbstractLight
    radiance::SVec3d
end

ConstantEnvironmentLight(r::NTuple{3,Float64}) =
    ConstantEnvironmentLight(SVec3d(r...))

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
    transfer_function::TransferFunction
    phase_function::PhaseFunction
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
    VolumeEntry{G, N}

A volume in the scene: a grid with its material and optional NanoGrid acceleration.
Parametrized on `G` (grid type) and `N` (nanogrid type: `NanoGrid` or `Nothing`)
for type stability — the compiler eliminates dead `nothing` checks when N=NanoGrid.

# Fields
- `grid::G` - The VDB grid (for accessor-based lookups)
- `nanogrid::N` - NanoGrid for fast lookups, or `nothing` if not yet built
- `material::VolumeMaterial` - Material properties
"""
struct VolumeEntry{G, N}
    grid::G
    nanogrid::N
    material::VolumeMaterial
end

VolumeEntry(grid, material::VolumeMaterial) =
    VolumeEntry(grid, nothing, material)

# ============================================================================
# Scene
# ============================================================================

"""
    Scene{V, L}

A complete scene description for rendering.
Parametrized on `V` (volumes container) and `L` (lights tuple) for type stability.
Lights stored as a Tuple so `for light in scene.lights` unrolls at compile time.

# Fields
- `camera::Camera` - The view camera
- `lights::L` - Scene lights (Tuple of concrete light types)
- `volumes::V` - Volume grids with materials (Tuple or Vector)
- `background::SVec3d` - Background color (RGB)
"""
struct Scene{V, L}
    camera::Camera
    lights::L
    volumes::V
    background::SVec3d
end

# Multi-volume: pass a vector
function Scene(camera::Camera, lights::Vector{<:AbstractLight},
               volumes::Vector{<:VolumeEntry};
               background::NTuple{3,Float64}=(0.0, 0.0, 0.0))
    Scene(camera, Tuple(lights), volumes, SVec3d(background...))
end

# Single volume + light vector: wrap volume in tuple for specialization
function Scene(camera::Camera, lights::Vector{<:AbstractLight},
               volume::VolumeEntry;
               background::NTuple{3,Float64}=(0.0, 0.0, 0.0))
    Scene(camera, Tuple(lights), (volume,), SVec3d(background...))
end

# Convenience: single light, single volume
function Scene(camera::Camera, light::AbstractLight, volume::VolumeEntry;
               background::NTuple{3,Float64}=(0.0, 0.0, 0.0))
    Scene(camera, (light,), (volume,), SVec3d(background...))
end
