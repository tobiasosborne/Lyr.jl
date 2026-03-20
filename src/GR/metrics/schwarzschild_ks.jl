# schwarzschild_ks.jl — Schwarzschild spacetime in Cartesian Kerr-Schild coordinates
#
# Metric: g_αβ = η_αβ + f l_α l_β   (Kerr-Schild decomposition)
#   f = 2M/r,  r = √(x² + y² + z²)
#   l_α = (1, x/r, y/r, z/r)         (ingoing null 1-form)
#
# Inverse: g^{αβ} = η^{αβ} - f l^α l^β   (exact via Sherman-Morrison)
#   l^α = η^{αβ} l_β = (-1, x/r, y/r, z/r)
#
# Coordinates: (t, x, y, z) — Cartesian, NO coordinate singularity at poles.
# Reference: Chan et al. 2018, "GRay2", ApJ 867:59 (arXiv:1706.07062)

"""
    SchwarzschildKS <: MetricSpace{4}

Schwarzschild black hole in Cartesian Kerr-Schild coordinates (t, x, y, z).
No coordinate singularity at the poles. Horizon at r = 2M.
"""
struct SchwarzschildKS <: MetricSpace{4}
    M::Float64
end

horizon_radius(s::SchwarzschildKS) = 2.0 * s.M
photon_sphere_radius(s::SchwarzschildKS) = 3.0 * s.M
isco_radius(s::SchwarzschildKS) = 6.0 * s.M

# Helper: compute r and the null 1-form components from position
@inline function _ks_r_and_l(x::SVec4d)
    r = sqrt(x[2]^2 + x[3]^2 + x[4]^2)
    r = max(r, 1e-15)  # avoid division by zero at origin
    inv_r = 1.0 / r
    lx = x[2] * inv_r
    ly = x[3] * inv_r
    lz = x[4] * inv_r
    (r, inv_r, lx, ly, lz)
end

function is_singular(s::SchwarzschildKS, x::SVec4d)::Bool
    r2 = x[2]^2 + x[3]^2 + x[4]^2
    r2 <= (2.0 * s.M + 1e-10)^2
end

function coordinate_bounds(s::SchwarzschildKS)
    (r_min = 2.0 * s.M, r_max = Inf)
end

# ─────────────────────────────────────────────────────────────────────
# Covariant metric: g_αβ = η_αβ + f l_α l_β
# ─────────────────────────────────────────────────────────────────────

function metric(s::SchwarzschildKS, x::SVector{4})
    r, inv_r, lx, ly, lz = _ks_r_and_l(x)
    f = 2.0 * s.M * inv_r

    # l_α = (1, lx, ly, lz)
    # g_αβ = η_αβ + f l_α l_β
    @SMatrix [
        -1.0+f     f*lx       f*ly       f*lz      ;
        f*lx       1.0+f*lx^2 f*lx*ly    f*lx*lz   ;
        f*ly       f*lx*ly    1.0+f*ly^2 f*ly*lz   ;
        f*lz       f*lx*lz    f*ly*lz    1.0+f*lz^2
    ]
end

# ─────────────────────────────────────────────────────────────────────
# Contravariant metric: g^{αβ} = η^{αβ} - f l^α l^β
# l^α = (-1, lx, ly, lz)   [raised with η]
# ─────────────────────────────────────────────────────────────────────

function metric_inverse(s::SchwarzschildKS, x::SVector{4})
    r, inv_r, lx, ly, lz = _ks_r_and_l(x)
    f = 2.0 * s.M * inv_r

    # l^α = (-1, lx, ly, lz)
    # g^{αβ} = η^{αβ} - f l^α l^β
    @SMatrix [
        -1.0-f     f*lx        f*ly        f*lz       ;
        f*lx       1.0-f*lx^2  -f*lx*ly    -f*lx*lz   ;
        f*ly       -f*lx*ly    1.0-f*ly^2  -f*ly*lz   ;
        f*lz       -f*lx*lz    -f*ly*lz    1.0-f*lz^2
    ]
end

# ─────────────────────────────────────────────────────────────────────
# Analytic metric inverse partials: ∂g^{αβ}/∂x^μ
#
# g^{αβ} = η^{αβ} - f l^α l^β
# ∂g^{αβ}/∂x^μ = -∂f/∂x^μ l^α l^β - f (∂l^α/∂x^μ l^β + l^α ∂l^β/∂x^μ)
#
# where:
#   f = 2M/r,  ∂f/∂x^i = -2M x^i / r³
#   l^0 = -1 (constant), l^j = x^j/r
#   ∂l^j/∂x^i = (δ^j_i - l^j l^i) / r
# ─────────────────────────────────────────────────────────────────────

function metric_inverse_partials(s::SchwarzschildKS, x::SVec4d)::NTuple{4, SMat4d}
    r, inv_r, lx, ly, lz = _ks_r_and_l(x)
    f = 2.0 * s.M * inv_r
    inv_r2 = inv_r * inv_r

    # l^α components: l = (-1, lx, ly, lz)
    l = SVec4d(-1.0, lx, ly, lz)

    # ∂f/∂x^i = -f * x^i / r² = -f * l^i * inv_r  (for spatial i)
    # ∂l^j/∂x^i = (δ_ij - l^i l^j) * inv_r  (spatial only; ∂l^0/∂x = 0)

    # ∂/∂t (index 1): everything is static → zero
    d_dt = zeros(SMat4d)

    # Spatial partials (μ = 2, 3, 4 → x, y, z)
    partials = (d_dt, zeros(SMat4d), zeros(SMat4d), zeros(SMat4d))

    for μ in 2:4
        li_mu = l[μ]  # l^μ for the differentiation direction
        df_dxmu = -f * li_mu * inv_r  # ∂f/∂x^μ

        # Build ∂l^α/∂x^μ: zero for α=1 (temporal), (δ_αμ - l^α l^μ)/r for spatial
        dl = MVector{4, Float64}(0.0, 0.0, 0.0, 0.0)
        for α in 2:4
            dl[α] = ((α == μ ? 1.0 : 0.0) - l[α] * li_mu) * inv_r
        end

        # ∂g^{αβ}/∂x^μ = -df l^α l^β - f (dl^α l^β + l^α dl^β)
        mat = MMatrix{4, 4, Float64, 16}(undef)
        for α in 1:4, β in 1:4
            mat[α, β] = -df_dxmu * l[α] * l[β] -
                          f * (dl[α] * l[β] + l[α] * dl[β])
        end
        partials = Base.setindex(partials, SMat4d(mat), μ)
    end

    partials
end

# ─────────────────────────────────────────────────────────────────────
# Camera support: static observer tetrad in Cartesian KS
# ─────────────────────────────────────────────────────────────────────

"""
    static_observer_tetrad(m::SchwarzschildKS, x::SVec4d)

Tetrad for a static observer in Cartesian Kerr-Schild coordinates.
e_0 = time direction (4-velocity), e_1 = radial outward,
e_2 = polar (θ, southward), e_3 = azimuthal (φ, eastward).

Uses analytic spatial legs derived from the spherical coordinate tangent
vectors expressed in Cartesian components, matching the BL tetrad orientation.
Gram-Schmidt orthonormalization against the KS metric corrects for the
off-diagonal g_{ti} terms.
"""
function static_observer_tetrad(m::SchwarzschildKS, x::SVec4d)::Tuple{SVec4d, SMat4d}
    r, inv_r, lx, ly, lz = _ks_r_and_l(x)
    f = 2.0 * m.M * inv_r
    g = metric(m, x)

    # Static observer 4-velocity: g_tt (u^t)² = -1 → u^t = 1/√(1-f)
    gtt = -1.0 + f
    ut = 1.0 / sqrt(abs(gtt))
    u = SVec4d(ut, 0.0, 0.0, 0.0)
    g_uu = _dot_metric(g, u, u)

    # Analytic spatial directions matching BL (r, θ, φ) orientation.
    # These are the spherical basis vectors ê_r, ê_θ, ê_φ written in
    # Cartesian components, which are orthonormal in flat space.
    #   ê_r = (x/r, y/r, z/r)
    #   ê_θ = (xz/(rρ), yz/(rρ), -ρ/r)    "southward"
    #   ê_φ = (-y/ρ, x/ρ, 0)               "eastward"
    # where ρ = √(x² + y²).
    e1_raw = SVec4d(0.0, lx, ly, lz)

    ρ = sqrt(x[2]^2 + x[3]^2)
    if ρ > 1e-10 * r
        # General case: well away from z-axis
        inv_ρ = 1.0 / ρ
        e2_raw = SVec4d(0.0, x[2]*x[4]*inv_r*inv_ρ, x[3]*x[4]*inv_r*inv_ρ, -ρ*inv_r)
        e3_raw = SVec4d(0.0, -x[3]*inv_ρ, x[2]*inv_ρ, 0.0)
    else
        # Pole case (camera on/near z-axis): ê_θ and ê_φ are degenerate.
        # Use x and y directions as tangential legs.
        e2_raw = SVec4d(0.0, 1.0, 0.0, 0.0)
        e3_raw = SVec4d(0.0, 0.0, 1.0, 0.0)
    end

    # Gram-Schmidt orthonormalization against KS metric g_αβ.
    # The KS off-diagonal g_{ti} terms make purely spatial vectors
    # non-orthogonal to u, so this correction is required.

    # e1: orthogonalize against u, then normalize
    e1_orth = e1_raw - (_dot_metric(g, e1_raw, u) / g_uu) * u
    e1 = e1_orth / sqrt(abs(_dot_metric(g, e1_orth, e1_orth)))

    # e2: orthogonalize against u and e1, then normalize
    e2_orth = e2_raw - (_dot_metric(g, e2_raw, u) / g_uu) * u -
              _dot_metric(g, e2_raw, e1) * e1
    e2 = e2_orth / sqrt(abs(_dot_metric(g, e2_orth, e2_orth)))

    # e3: orthogonalize against u, e1, e2, then normalize
    e3_orth = e3_raw - (_dot_metric(g, e3_raw, u) / g_uu) * u -
              _dot_metric(g, e3_raw, e1) * e1 -
              _dot_metric(g, e3_raw, e2) * e2
    e3 = e3_orth / sqrt(abs(_dot_metric(g, e3_orth, e3_orth)))

    # SMat4d constructor is column-major: columns = tetrad legs.
    # Column 1 = u (e0), Column 2 = e1, Column 3 = e2, Column 4 = e3.
    # pixel_to_momentum accesses e[:, a] expecting column a = leg a.
    tetrad = SMat4d(
        u[1],  u[2],  u[3],  u[4],
        e1[1], e1[2], e1[3], e1[4],
        e2[1], e2[2], e2[3], e2[4],
        e3[1], e3[2], e3[3], e3[4]
    )

    (u, tetrad)
end

# Helper: inner product with metric g
@inline function _dot_metric(g::SMat4d, a::SVec4d, b::SVec4d)::Float64
    s = 0.0
    for α in 1:4, β in 1:4
        s += g[α, β] * a[α] * b[β]
    end
    s
end

"""
    static_camera(m::SchwarzschildKS, r, theta, phi, fov, resolution) -> GRCamera

Camera for Schwarzschild KS at Boyer-Lindquist position (r, theta, phi),
automatically converted to Cartesian Kerr-Schild coordinates (x, y, z).
"""
function static_camera(m::SchwarzschildKS, r::Float64, θ::Float64, φ::Float64,
                        fov::Float64, resolution::Tuple{Int, Int})::GRCamera
    x = SVec4d(0.0, r * sin(θ) * cos(φ), r * sin(θ) * sin(φ), r * cos(θ))
    u, tetrad = static_observer_tetrad(m, x)
    GRCamera(m, x, u, tetrad, fov, resolution)
end

# ─────────────────────────────────────────────────────────────────────
# Sky lookup: convert Cartesian (x, y, z) → spherical (θ, φ) for texture
# ─────────────────────────────────────────────────────────────────────

"""
    ks_to_sky_angles(x::SVec4d) -> (θ, φ)

Convert Cartesian KS position to spherical sky angles for texture lookup.
Well-defined everywhere (no pole singularity).
"""
function ks_to_sky_angles(x::SVec4d)::Tuple{Float64, Float64}
    r = sqrt(x[2]^2 + x[3]^2 + x[4]^2)
    r = max(r, 1e-15)
    θ = acos(clamp(x[4] / r, -1.0, 1.0))
    φ = atan(x[3], x[2])
    if φ < 0.0
        φ += 2π
    end
    (θ, φ)
end
