# kerr.jl — Kerr black hole spacetime (Phase 2 stub)
#
# Boyer-Lindquist coordinates (t, r, θ, φ) for a rotating black hole.
# Interface only — metric functions throw until Phase 2 implementation.

"""Coordinate system selector for Kerr spacetime."""
abstract type KerrCoords end
struct BoyerLindquist <: KerrCoords end
struct KerrSchild <: KerrCoords end

"""
    Kerr{C<:KerrCoords} <: MetricSpace{4}

Kerr black hole spacetime with mass M and spin parameter a.

# Fields
- `M::Float64` — black hole mass
- `a::Float64` — spin parameter (|a| ≤ M)
"""
struct Kerr{C<:KerrCoords} <: MetricSpace{4}
    M::Float64
    a::Float64
    function Kerr{C}(M::Float64, a::Float64) where {C}
        abs(a) <= M || throw(ArgumentError("Spin |a| = $(abs(a)) exceeds M = $M"))
        new{C}(M, a)
    end
end

Kerr(M::Float64, a::Float64) = Kerr{BoyerLindquist}(M, a)

"""Outer event horizon r₊ = M + √(M² - a²)."""
horizon_radius(k::Kerr) = k.M + sqrt(k.M^2 - k.a^2)

"""Ergosphere radius at angle θ: r_e = M + √(M² - a² cos²θ)."""
ergosphere_radius(k::Kerr, θ::Float64) = k.M + sqrt(k.M^2 - k.a^2 * cos(θ)^2)

"""ISCO radius for prograde orbit (co-rotating with BH)."""
function isco_prograde(k::Kerr)::Float64
    # Bardeen et al. (1972) formula
    a_star = k.a / k.M
    z1 = 1.0 + (1.0 - a_star^2)^(1/3) * ((1.0 + a_star)^(1/3) + (1.0 - a_star)^(1/3))
    z2 = sqrt(3.0 * a_star^2 + z1^2)
    k.M * (3.0 + z2 - sqrt((3.0 - z1) * (3.0 + z1 + 2.0 * z2)))
end

# Phase 2: implement metric, metric_inverse, is_singular, coordinate_bounds
metric(k::Kerr, x::SVector{4}) = error("Kerr metric not yet implemented (Phase 2)")
metric_inverse(k::Kerr, x::SVector{4}) = error("Kerr metric not yet implemented (Phase 2)")
is_singular(k::Kerr, x::SVec4d) = error("Kerr singularity check not yet implemented (Phase 2)")
coordinate_bounds(k::Kerr) = error("Kerr coordinate bounds not yet implemented (Phase 2)")
