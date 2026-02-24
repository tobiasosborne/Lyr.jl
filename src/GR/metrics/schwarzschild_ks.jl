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
e_0 = time direction (4-velocity), e_1 = radial (toward BH),
e_2 and e_3 = tangential (orthogonal to radial).
"""
function static_observer_tetrad(m::SchwarzschildKS, x::SVec4d)::Tuple{SVec4d, SMat4d}
    r, inv_r, lx, ly, lz = _ks_r_and_l(x)
    f = 2.0 * m.M * inv_r
    g = metric(m, x)

    # Static observer 4-velocity: u^α with u^i = 0 in the "lab frame"
    # but we need g_αβ u^α u^β = -1. For KS, u = (u^t, 0, 0, 0):
    # g_tt (u^t)² = -1 → u^t = 1/√(|g_tt|) = 1/√(1-f)
    gtt = -1.0 + f
    ut = 1.0 / sqrt(abs(gtt))  # note: gtt < 0 outside horizon (f < 1)
    u = SVec4d(ut, 0.0, 0.0, 0.0)

    # Radial direction: unit vector AWAY from BH = +(lx, ly, lz)
    # In Cartesian KS, outward radial gives outward coordinate velocity,
    # matching the BL convention where e1 produces dx^r/dλ > 0 (outward).
    # Backward tracing with dl < 0 then sends rays inward.

    # e_1 candidate: purely spatial radial outward
    e1_raw = SVec4d(0.0, lx, ly, lz)
    # Gram-Schmidt: e1 = e1_raw - (g(e1_raw, u)/g(u,u)) u
    g_e1u = _dot_metric(g, e1_raw, u)
    g_uu = _dot_metric(g, u, u)
    e1_orth = e1_raw - (g_e1u / g_uu) * u
    norm_e1 = sqrt(abs(_dot_metric(g, e1_orth, e1_orth)))
    e1 = e1_orth / norm_e1

    # e_2: pick a vector not parallel to radial direction.
    # Use the "z-axis trick": if radial ≈ z, use x as seed.
    if abs(lz) < 0.9
        seed = SVec4d(0.0, 0.0, 0.0, 1.0)  # z direction
    else
        seed = SVec4d(0.0, 1.0, 0.0, 0.0)  # x direction
    end
    # Gram-Schmidt vs u and e1
    e2_raw = seed - (_dot_metric(g, seed, u) / g_uu) * u -
              (_dot_metric(g, seed, e1) / _dot_metric(g, e1, e1)) * e1
    norm_e2 = sqrt(abs(_dot_metric(g, e2_raw, e2_raw)))
    e2 = e2_raw / norm_e2

    # e_3: cross-product-like (complete the tetrad)
    e3_raw = SVec4d(0.0, 0.0, 0.0, 0.0)
    # Use the remaining orthogonal direction
    for seed2_choice in [SVec4d(0.0, 0.0, 1.0, 0.0), SVec4d(0.0, 1.0, 0.0, 0.0), SVec4d(0.0, 0.0, 0.0, 1.0)]
        e3_raw = seed2_choice -
                  (_dot_metric(g, seed2_choice, u) / g_uu) * u -
                  (_dot_metric(g, seed2_choice, e1) / _dot_metric(g, e1, e1)) * e1 -
                  (_dot_metric(g, seed2_choice, e2) / _dot_metric(g, e2, e2)) * e2
        if _dot_metric(g, e3_raw, e3_raw) > 1e-10
            break
        end
    end
    norm_e3 = sqrt(abs(_dot_metric(g, e3_raw, e3_raw)))
    e3 = e3_raw / norm_e3

    tetrad = SMat4d(
        u[1], e1[1], e2[1], e3[1],
        u[2], e1[2], e2[2], e3[2],
        u[3], e1[3], e2[3], e3[3],
        u[4], e1[4], e2[4], e3[4]
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
    static_camera(m::SchwarzschildKS, r, θ, φ, fov, resolution)

Camera for Schwarzschild KS at Boyer-Lindquist position (r, θ, φ),
automatically converted to Cartesian (x, y, z).
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
