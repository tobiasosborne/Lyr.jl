# IntegrationMethods.jl - Volume integration method type hierarchy
#
# Dispatch types for render_volume: each struct carries method-specific parameters.
# Existing render_volume_image / render_volume_preview remain unchanged.

"""
    VolumeIntegrationMethod

Abstract supertype for volume rendering methods.
Subtypes are dispatched via `render_volume(scene, method, w, h; ...)`.
"""
abstract type VolumeIntegrationMethod end

"""
    ReferencePathTracer <: VolumeIntegrationMethod

Multi-scatter volumetric path tracer — ground-truth reference renderer.

Traces full random walks through the medium with next-event estimation (NEE)
at each scattering vertex. Russian roulette terminates long paths unbiasedly.

# Fields
- `max_bounces::Int` — maximum scattering events per path (default 64)
- `rr_start::Int` — Russian roulette activates after this many bounces (default 3)
"""
struct ReferencePathTracer <: VolumeIntegrationMethod
    max_bounces::Int
    rr_start::Int
end

ReferencePathTracer(; max_bounces::Int=64, rr_start::Int=3) =
    ReferencePathTracer(max_bounces, rr_start)

"""
    SingleScatterTracer <: VolumeIntegrationMethod

Single-scatter volume renderer (wraps existing `render_volume_image` logic).
"""
struct SingleScatterTracer <: VolumeIntegrationMethod end

"""
    EmissionAbsorption <: VolumeIntegrationMethod

Deterministic emission-absorption ray marcher (wraps existing `render_volume_preview` logic).

# Fields
- `step_size::Float64` — ray march step size (default 0.5)
- `max_steps::Int` — maximum steps per ray (default 2000)
"""
struct EmissionAbsorption <: VolumeIntegrationMethod
    step_size::Float64
    max_steps::Int
end

EmissionAbsorption(; step_size::Float64=0.5, max_steps::Int=2000) =
    EmissionAbsorption(step_size, max_steps)
