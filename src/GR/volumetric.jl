# volumetric.jl — Volumetric matter bridge for GR rendering
#
# VolumetricMatter wraps an analytic density source (or future VDB grid)
# and provides density/emission queries at each geodesic integration step.
# Spatial coordinates are extracted from the geodesic state x^μ = (t, r, θ, φ).

# ─────────────────────────────────────────────────────────────────────
# VolumetricMatter — the bridge struct
# ─────────────────────────────────────────────────────────────────────

"""
    VolumetricMatter{M<:MetricSpace, D} <: MatterSource

Volumetric matter distribution queried at each geodesic step.

# Fields
- `metric::M` — spacetime metric
- `density_source::D` — density evaluator: must support `evaluate_density(d, r, θ, φ)`
- `inner_radius::Float64` — inner cutoff (typically ISCO)
- `outer_radius::Float64` — outer cutoff
"""
struct VolumetricMatter{M<:MetricSpace, D} <: MatterSource
    metric::M
    density_source::D
    inner_radius::Float64
    outer_radius::Float64
end

# ─────────────────────────────────────────────────────────────────────
# ThickDisk — analytic density source
# ─────────────────────────────────────────────────────────────────────

"""
    ThickDisk(r_inner, r_outer, h_over_r, amplitude)

Analytic thick accretion disk with Gaussian vertical profile and
power-law radial density.

Density: ρ(r, θ) = A × (r_in/r)² × exp(-z²/2h(r)²)
where z = r cos(θ), h(r) = h_over_r × r.
"""
struct ThickDisk
    r_inner::Float64
    r_outer::Float64
    h_over_r::Float64
    amplitude::Float64
end

"""
    evaluate_density(disk::ThickDisk, r, θ, φ) -> Float64

Evaluate disk density at Boyer-Lindquist coordinates.
"""
function evaluate_density(disk::ThickDisk, r::Float64, θ::Float64, φ::Float64)::Float64
    (r < disk.r_inner || r > disk.r_outer) && return 0.0
    z = r * cos(θ)
    h = disk.h_over_r * r
    ρ0 = disk.amplitude * (disk.r_inner / r)^2
    ρ0 * exp(-z^2 / (2.0 * h^2))
end

# ─────────────────────────────────────────────────────────────────────
# Emission and absorption coefficients
# ─────────────────────────────────────────────────────────────────────

"""
    disk_temperature(r, r_inner) -> Float64

Shakura-Sunyaev temperature profile: T ∝ (r_in/r)^{3/4}.
Normalized so T(r_inner) = 1.0.
"""
disk_temperature(r::Float64, r_inner::Float64)::Float64 = (r_inner / r)^0.75

"""
    emission_absorption(ρ, T) -> Tuple{Float64, Float64}

Simplified emission and absorption coefficients for visualization.

Returns (j, α) where:
- j: thermal emission ∝ ρ² √T (bremsstrahlung-inspired)
- α: absorption ∝ κ_es × ρ (electron scattering dominated)
"""
function emission_absorption(ρ::Float64, T::Float64)::Tuple{Float64, Float64}
    j = ρ^2 * sqrt(max(T, 0.0))
    α = 0.34 * ρ  # κ_es ≈ 0.34 in code units
    (j, α)
end
