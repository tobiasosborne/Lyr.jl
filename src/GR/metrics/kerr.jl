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

"""Boyer-Lindquist coordinates (t, r, theta, phi). Standard for analytic work."""
struct BoyerLindquist <: KerrCoords end

"""Kerr-Schild coordinates. Horizon-penetrating (Phase 2)."""
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

"""Kerr metric function Sigma = r^2 + a^2 cos^2(theta). Zero at the ring singularity."""
@inline function _kerr_Σ(r, a, cosθ)
    r * r + a * a * cosθ * cosθ
end

"""Kerr metric function Delta = r^2 - 2Mr + a^2. Zero at the horizons."""
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
    sin2θ = max(sinθ * sinθ, 1e-6)

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
    sin2θ = max(sinθ * sinθ, 1e-6)

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
# Analytic ∂g^{αβ}/∂x^μ for Kerr Boyer-Lindquist
#
# 5 nonzero inverse metric components: gtt, gtφ, grr, gθθ, gφφ.
# Static + axisymmetric ⟹ only ∂/∂r and ∂/∂θ are nonzero.
# ─────────────────────────────────────────────────────────────────────

function metric_inverse_partials(k::Kerr{BoyerLindquist},
                                  x::SVec4d)::NTuple{4, SMat4d}
    M, a = k.M, k.a
    r, θ = x[2], x[3]
    a2 = a * a

    sinθ = sin(θ)
    cosθ = cos(θ)
    sin2θ = max(sinθ * sinθ, 1e-6)
    sinθ_safe = max(abs(sinθ), 1e-3)

    Σ = r * r + a2 * cosθ * cosθ
    Δ = r * r - 2.0 * M * r + a2
    r2a2 = r * r + a2
    A = r2a2 * r2a2 - Δ * a2 * sin2θ
    ΣΔ = Σ * Δ

    inv_ΣΔ2 = 1.0 / (ΣΔ * ΣΔ)
    inv_Σ2 = 1.0 / (Σ * Σ)

    # Intermediate derivatives
    dΣ_dr = 2.0 * r
    dΣ_dθ = -2.0 * a2 * sinθ * cosθ
    dΔ_dr = 2.0 * r - 2.0 * M

    dA_dr = 4.0 * r * r2a2 - dΔ_dr * a2 * sin2θ
    dA_dθ = -Δ * 2.0 * a2 * sinθ * cosθ

    d_ΣΔ_dr = dΣ_dr * Δ + Σ * dΔ_dr
    d_ΣΔ_dθ = dΣ_dθ * Δ

    # gtt = -A / (ΣΔ)
    dgtt_dr = -(dA_dr * ΣΔ - A * d_ΣΔ_dr) * inv_ΣΔ2
    dgtt_dθ = -(dA_dθ * ΣΔ - A * d_ΣΔ_dθ) * inv_ΣΔ2

    # gtφ = -2Mar / (ΣΔ)
    dgtφ_dr = -2.0 * M * a * (ΣΔ - r * d_ΣΔ_dr) * inv_ΣΔ2
    dgtφ_dθ = 2.0 * M * a * r * d_ΣΔ_dθ * inv_ΣΔ2

    # grr = Δ / Σ
    dgrr_dr = (dΔ_dr * Σ - Δ * dΣ_dr) * inv_Σ2
    dgrr_dθ = -Δ * dΣ_dθ * inv_Σ2

    # gθθ = 1 / Σ
    dgθθ_dr = -dΣ_dr * inv_Σ2
    dgθθ_dθ = -dΣ_dθ * inv_Σ2

    # gφφ = (Δ - a²sin²θ) / (ΣΔsin²θ)
    N = Δ - a2 * sin2θ
    D = ΣΔ * sin2θ
    inv_D2 = 1.0 / (D * D)
    dN_dr = dΔ_dr
    dN_dθ = -2.0 * a2 * sinθ * cosθ
    dD_dr = d_ΣΔ_dr * sin2θ
    dD_dθ = d_ΣΔ_dθ * sin2θ + ΣΔ * 2.0 * sinθ * cosθ
    dgφφ_dr = (dN_dr * D - N * dD_dr) * inv_D2
    dgφφ_dθ = (dN_dθ * D - N * dD_dθ) * inv_D2

    zero4 = zeros(SMat4d)

    # Column-major: col1=(row1,row2,row3,row4), col2=..., etc.
    d_dr = SMat4d(
        dgtt_dr, 0.0, 0.0, dgtφ_dr,
        0.0, dgrr_dr, 0.0, 0.0,
        0.0, 0.0, dgθθ_dr, 0.0,
        dgtφ_dr, 0.0, 0.0, dgφφ_dr
    )

    d_dθ = SMat4d(
        dgtt_dθ, 0.0, 0.0, dgtφ_dθ,
        0.0, dgrr_dθ, 0.0, 0.0,
        0.0, 0.0, dgθθ_dθ, 0.0,
        dgtφ_dθ, 0.0, 0.0, dgφφ_dθ
    )

    (zero4, d_dr, d_dθ, zero4)
end

# ─────────────────────────────────────────────────────────────────────
# Analytic Christoffel symbols Γ^μ_{αβ} for Kerr Boyer-Lindquist
#
# Computed from Γ^μ_{αβ} = ½ g^{μσ}(g_{σα,β} + g_{σβ,α} - g_{αβ,σ})
# using analytic metric derivatives. Pure arithmetic, GPU-portable.
# ─────────────────────────────────────────────────────────────────────

"""
    christoffel(k::Kerr{BoyerLindquist}, x) -> NTuple{4, SMatrix{4,4}}

Analytic Christoffel symbols Γ^μ_{αβ} for Kerr spacetime in Boyer-Lindquist
coordinates. Returns 4 symmetric 4×4 matrices, one per upper index μ.

Computed from the standard formula using analytic metric partial derivatives.
All expressions are rational functions of r, θ, M, a — pure arithmetic,
no allocation, fully GPU-portable.
"""
function christoffel(k::Kerr{BoyerLindquist}, x::SVector{4})
    M, a = k.M, k.a
    r, θ = x[2], x[3]
    a2 = a * a

    sinθ = sin(θ)
    cosθ = cos(θ)
    sin2θ = max(sinθ * sinθ, 1e-6)
    sinθ_safe = max(abs(sinθ), 1e-3) * (sinθ >= 0.0 ? 1.0 : -1.0)

    Σ = r * r + a2 * cosθ * cosθ
    Δ = r * r - 2.0 * M * r + a2
    r2a2 = r * r + a2
    Σ2 = Σ * Σ
    Δ2 = Δ * Δ
    inv_Σ2 = 1.0 / Σ2

    # Metric components
    g = metric(k, x)
    ginv = metric_inverse(k, x)

    # ∂Σ/∂r = 2r, ∂Σ/∂θ = -2a²sinθcosθ
    dΣ_dr = 2.0 * r
    dΣ_dθ = -2.0 * a2 * sinθ * cosθ

    # ∂Δ/∂r = 2r - 2M
    dΔ_dr = 2.0 * r - 2.0 * M

    # ∂g_{tt}/∂r = 2M(Σ - 2r²)/Σ²
    dgtt_dr = 2.0 * M * (Σ - 2.0 * r * r) * inv_Σ2
    # ∂g_{tt}/∂θ = 4Mra²sinθcosθ/Σ²
    dgtt_dθ = 4.0 * M * r * a2 * sinθ * cosθ * inv_Σ2

    # ∂g_{tφ}/∂r = -2Ma sin²θ (Σ - 2r²)/Σ²
    dgtφ_dr = -2.0 * M * a * sin2θ * (Σ - 2.0 * r * r) * inv_Σ2
    # ∂g_{tφ}/∂θ = -4Mar sinθcosθ (Σ + a²sin²θ)/Σ²
    dgtφ_dθ = -4.0 * M * a * r * sinθ * cosθ * (Σ + a2 * sin2θ) * inv_Σ2

    # ∂g_{rr}/∂r = (2rΔ - Σ(2r-2M))/Δ²
    dgrr_dr = (dΣ_dr * Δ - Σ * dΔ_dr) / Δ2
    # ∂g_{rr}/∂θ = ∂Σ/∂θ / Δ
    dgrr_dθ = dΣ_dθ / Δ

    # ∂g_{θθ}/∂r = 2r, ∂g_{θθ}/∂θ = -2a²sinθcosθ
    dgθθ_dr = dΣ_dr
    dgθθ_dθ = dΣ_dθ

    # g_{φφ} = A sin²θ/Σ where A = (r²+a²)² - Δa²sin²θ
    A = r2a2 * r2a2 - Δ * a2 * sin2θ
    dA_dr = 4.0 * r * r2a2 - dΔ_dr * a2 * sin2θ
    dA_dθ = -Δ * 2.0 * a2 * sinθ * cosθ

    # ∂g_{φφ}/∂r = sin²θ(∂A/∂r·Σ - A·∂Σ/∂r)/Σ²
    dgφφ_dr = sin2θ * (dA_dr * Σ - A * dΣ_dr) * inv_Σ2
    # ∂g_{φφ}/∂θ = [2sinθcosθ·A·Σ + sin²θ(∂A/∂θ·Σ - A·∂Σ/∂θ)]/Σ²
    dgφφ_dθ = (2.0 * sinθ * cosθ * A * Σ +
                sin2θ * (dA_dθ * Σ - A * dΣ_dθ)) * inv_Σ2

    # Pack metric derivatives: dg[β][σ,α] where β is derivative index
    # Only β=2 (r) and β=3 (θ) are non-zero
    # Using column-major SMatrix: element (row,col) = (σ,α)
    z = 0.0
    dg_dr = @SMatrix [
        dgtt_dr  z        z        dgtφ_dr ;
        z        dgrr_dr  z        z       ;
        z        z        dgθθ_dr  z       ;
        dgtφ_dr  z        z        dgφφ_dr
    ]

    dg_dθ = @SMatrix [
        dgtt_dθ  z        z        dgtφ_dθ ;
        z        dgrr_dθ  z        z       ;
        z        z        dgθθ_dθ  z       ;
        dgtφ_dθ  z        z        dgφφ_dθ
    ]

    # Compute Γ^μ_{αβ} = ½ Σ_σ g^{μσ}(dg[β][σ,α] + dg[α][σ,β] - dg[σ][α,β])
    # where dg[1]=dg[4]=0, dg[2]=dg_dr, dg[3]=dg_dθ
    @inline function _dg(idx, σ, α)
        idx == 2 && return dg_dr[σ, α]
        idx == 3 && return dg_dθ[σ, α]
        return 0.0
    end

    Γ = ntuple(Val(4)) do μ
        SMat4d(ntuple(Val(16)) do k
            β = (k - 1) >> 2 + 1  # column (÷ 4)
            α = (k - 1) & 3 + 1   # row (% 4)
            s = 0.0
            for σ in 1:4
                s += ginv[μ, σ] * (_dg(β, σ, α) + _dg(α, σ, β) - _dg(σ, α, β))
            end
            0.5 * s
        end)
    end
    Γ
end
