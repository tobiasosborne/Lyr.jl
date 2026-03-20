# schwarzschild.jl — Schwarzschild black hole spacetime
#
# The Schwarzschild metric in Schwarzschild coordinates (t, r, θ, φ):
#
#   ds² = -(1 - 2M/r) dt² + (1 - 2M/r)⁻¹ dr² + r² dθ² + r² sin²θ dφ²
#
# Coordinate singularity at r = 2M (event horizon).
# Physical singularity at r = 0.

"""Coordinate system selector for Schwarzschild spacetime."""
abstract type SchwarzschildCoords end

"""Standard Schwarzschild coordinates (t, r, θ, φ). Singular at r = 2M."""
struct SchwarzschildCoordinates <: SchwarzschildCoords end

"""Eddington-Finkelstein coordinates. Horizon-penetrating (Phase 2)."""
struct EddingtonFinkelstein <: SchwarzschildCoords end

"""
    Schwarzschild{C<:SchwarzschildCoords} <: MetricSpace{4}

Schwarzschild black hole spacetime of mass M in geometric units (G = c = 1).

# Fields
- `M::Float64` — black hole mass
"""
struct Schwarzschild{C<:SchwarzschildCoords} <: MetricSpace{4}
    M::Float64
end

"""Convenience constructor: default to Schwarzschild coordinates."""
Schwarzschild(M::Float64) = Schwarzschild{SchwarzschildCoordinates}(M)

"""Event horizon radius r_s = 2M. Coordinate singularity in Schwarzschild coordinates."""
horizon_radius(s::Schwarzschild) = 2.0 * s.M

"""Photon sphere radius r_ph = 3M. Unstable circular null orbits -- light can orbit here."""
photon_sphere_radius(s::Schwarzschild) = 3.0 * s.M

"""Innermost stable circular orbit r_ISCO = 6M. Inner edge of thin accretion disks."""
isco_radius(s::Schwarzschild) = 6.0 * s.M

# ─────────────────────────────────────────────────────────────────────
# Schwarzschild coordinates implementation
# ─────────────────────────────────────────────────────────────────────

function metric(s::Schwarzschild{SchwarzschildCoordinates}, x::SVector{4})
    r, θ = x[2], x[3]
    f = 1.0 - 2.0 * s.M / r
    r2 = r * r
    # Clamp sin²θ away from zero to avoid coordinate singularity at poles
    sin2θ = max(sin(θ)^2, 1e-6)
    z = zero(r)

    @SMatrix [
        -f   z    z          z          ;
         z   1/f  z          z          ;
         z   z    r2         z          ;
         z   z    z          r2 * sin2θ
    ]
end

function metric_inverse(s::Schwarzschild{SchwarzschildCoordinates}, x::SVector{4})
    r, θ = x[2], x[3]
    f = 1.0 - 2.0 * s.M / r
    inv_r2 = 1 / (r * r)
    # Clamp sin²θ away from zero to avoid coordinate singularity at poles
    sin2θ = max(sin(θ)^2, 1e-6)
    z = zero(r)

    @SMatrix [
        -1/f  z     z       z              ;
         z    f     z       z              ;
         z    z     inv_r2  z              ;
         z    z     z       inv_r2 / sin2θ
    ]
end

function is_singular(s::Schwarzschild{SchwarzschildCoordinates}, x::SVec4d)::Bool
    r = x[2]
    r <= 2.0 * s.M + 1e-10
end

function coordinate_bounds(s::Schwarzschild{SchwarzschildCoordinates})
    (r_min = 2.0 * s.M, r_max = Inf, θ_min = 0.0, θ_max = π)
end

# ─────────────────────────────────────────────────────────────────────
# Analytic metric inverse partials ∂g^{αβ}/∂x^μ
#
# For a static, diagonal metric, the only nonzero partials are
# w.r.t. r (index 2) and θ (index 3). Partials w.r.t. t and φ vanish.
# ─────────────────────────────────────────────────────────────────────

function metric_inverse_partials(s::Schwarzschild{SchwarzschildCoordinates},
                                  x::SVec4d)::NTuple{4, SMat4d}
    r, θ = x[2], x[3]
    M = s.M
    rs = 2.0 * M
    f = 1.0 - rs / r
    r2 = r * r
    r3 = r2 * r
    sin2θ = max(sin(θ)^2, 1e-6)

    zero4 = zeros(SMat4d)

    # ∂/∂t g^{αβ} = 0 (static)
    d_dt = zero4

    # ∂/∂r g^{αβ}:
    # g^{tt} = -1/f = -(1 - rs/r)^{-1} → d/dr = rs/(r² f²)
    # g^{rr} = f = 1 - rs/r            → d/dr = rs/r²
    # g^{θθ} = 1/r²                    → d/dr = -2/r³
    # g^{φφ} = 1/(r² sin²θ)            → d/dr = -2/(r³ sin²θ)
    d_dr = SMat4d(
        rs / (r2 * f * f), 0.0, 0.0,           0.0,
        0.0,           rs / r2, 0.0,           0.0,
        0.0,           0.0, -2.0 / r3,        0.0,
        0.0,           0.0, 0.0, -2.0 / (r3 * sin2θ)
    )

    # ∂/∂θ g^{αβ}:
    # Only g^{φφ} = 1/(r² sin²θ) depends on θ
    # d/dθ [1/(r² sin²θ)] = -2 cosθ / (r² sin³θ)
    sinθ = sin(θ)
    cosθ = cos(θ)
    sinθ_safe = max(abs(sinθ), 1e-3) * (sinθ >= 0.0 ? 1.0 : -1.0)
    d_dθ = SMat4d(
        0.0, 0.0, 0.0,                        0.0,
        0.0, 0.0, 0.0,                        0.0,
        0.0, 0.0, 0.0,                        0.0,
        0.0, 0.0, 0.0, -2.0 * cosθ / (r2 * sinθ_safe^3)
    )

    # ∂/∂φ g^{αβ} = 0 (axisymmetric)
    d_dφ = zero4

    (d_dt, d_dr, d_dθ, d_dφ)
end
