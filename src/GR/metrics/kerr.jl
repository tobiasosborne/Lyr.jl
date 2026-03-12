# kerr.jl — Kerr black hole spacetime
#
# Boyer-Lindquist coordinates (t, r, θ, φ) for a rotating black hole.
#
# The Kerr metric:
#   Σ = r² + a²cos²θ
#   Δ = r² - 2Mr + a²
#
#   ds² = -(1 - 2Mr/Σ) dt² - (4Mar sin²θ/Σ) dt dφ
#         + (Σ/Δ) dr² + Σ dθ²
#         + ((r²+a²)² - Δa²sin²θ) sin²θ/Σ dφ²
#
# Coordinate singularity at Δ = 0 (horizons).
# Ring singularity at Σ = 0 (r = 0, θ = π/2).

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

"""Inner (Cauchy) horizon r₋ = M - √(M² - a²)."""
inner_horizon_radius(k::Kerr) = k.M - sqrt(k.M^2 - k.a^2)

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

"""ISCO radius for retrograde orbit (counter-rotating)."""
function isco_retrograde(k::Kerr)::Float64
    a_star = k.a / k.M
    z1 = 1.0 + (1.0 - a_star^2)^(1/3) * ((1.0 + a_star)^(1/3) + (1.0 - a_star)^(1/3))
    z2 = sqrt(3.0 * a_star^2 + z1^2)
    k.M * (3.0 + z2 + sqrt((3.0 - z1) * (3.0 + z1 + 2.0 * z2)))
end

# ─────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────

@inline function _kerr_Σ(r, a, cosθ)
    r * r + a * a * cosθ * cosθ
end

@inline function _kerr_Δ(r, M, a)
    r * r - 2.0 * M * r + a * a
end

# ─────────────────────────────────────────────────────────────────────
# Boyer-Lindquist coordinates implementation
# ─────────────────────────────────────────────────────────────────────

function metric(k::Kerr{BoyerLindquist}, x::SVector{4})
    M, a = k.M, k.a
    r, θ = x[2], x[3]

    sinθ = sin(θ)
    cosθ = cos(θ)
    sin2θ = max(sinθ * sinθ, 1e-10)

    Σ = _kerr_Σ(r, a, cosθ)
    Δ = _kerr_Δ(r, M, a)
    r2a2 = r * r + a * a

    g_tt = -(1.0 - 2.0 * M * r / Σ)
    g_tφ = -2.0 * M * a * r * sin2θ / Σ
    g_rr = Σ / Δ
    g_θθ = Σ
    g_φφ = (r2a2 * r2a2 - Δ * a * a * sin2θ) * sin2θ / Σ

    z = zero(r)
    @SMatrix [
        g_tt   z     z     g_tφ ;
        z      g_rr  z     z    ;
        z      z     g_θθ  z    ;
        g_tφ   z     z     g_φφ
    ]
end

function metric_inverse(k::Kerr{BoyerLindquist}, x::SVector{4})
    M, a = k.M, k.a
    r, θ = x[2], x[3]

    sinθ = sin(θ)
    cosθ = cos(θ)
    sin2θ = max(sinθ * sinθ, 1e-10)

    Σ = _kerr_Σ(r, a, cosθ)
    Δ = _kerr_Δ(r, M, a)
    r2a2 = r * r + a * a

    # A = (r²+a²)² - Δ a² sin²θ
    A = r2a2 * r2a2 - Δ * a * a * sin2θ

    inv_ΣΔ = 1.0 / (Σ * Δ)

    # Derived from det(t,φ block) = -Δ sin²θ
    gtt = -A * inv_ΣΔ
    gtφ = -2.0 * M * a * r * inv_ΣΔ
    grr = Δ / Σ
    gθθ = 1.0 / Σ
    gφφ = (Δ - a * a * sin2θ) / (Σ * Δ * sin2θ)

    z = zero(r)
    @SMatrix [
        gtt  z    z    gtφ ;
        z    grr  z    z   ;
        z    z    gθθ  z   ;
        gtφ  z    z    gφφ
    ]
end

function is_singular(k::Kerr{BoyerLindquist}, x::SVec4d)::Bool
    r = x[2]
    θ = x[3]
    M, a = k.M, k.a
    r_plus = M + sqrt(M * M - a * a)
    Σ = r * r + a * a * cos(θ)^2
    r <= r_plus + 1e-10 || Σ < 1e-10
end

function coordinate_bounds(k::Kerr{BoyerLindquist})
    r_plus = k.M + sqrt(k.M^2 - k.a^2)
    (r_min = r_plus, r_max = Inf, θ_min = 0.0, θ_max = π)
end

# ─────────────────────────────────────────────────────────────────────
# metric_inverse_partials: uses ForwardDiff default from metric.jl
# (analytic partials for Kerr are very tedious — ForwardDiff is correct
# and fast enough via StaticArrays autodiff)
# ─────────────────────────────────────────────────────────────────────
