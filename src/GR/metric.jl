# metric.jl — MetricSpace abstract type and interface
#
# Every spacetime must implement the MetricSpace interface.
# The Hamiltonian formulation provides the geodesic equations of motion.

"""
    MetricSpace{D}

Abstract type for D-dimensional Lorentzian spacetime metrics.

# Required interface
- `metric(m, x)::SMat4d` — covariant metric gμν at point x
- `metric_inverse(m, x)::SMat4d` — contravariant metric gᵘᵛ at point x
- `is_singular(m, x)::Bool` — true if x is at/inside a coordinate singularity
- `coordinate_bounds(m)` — valid coordinate ranges

# Optional (defaults use ForwardDiff)
- `metric_inverse_partials(m, x)` — ∂gᵘᵛ/∂xᵘ (4 matrices)
"""
abstract type MetricSpace{D} end

# ─────────────────────────────────────────────────────────────────────
# Required interface stubs (subtypes must implement)
# ─────────────────────────────────────────────────────────────────────

"""
    metric(m::MetricSpace{4}, x::SVec4d) -> SMat4d

Return the covariant metric tensor g_mu_nu at spacetime point x.
Must be differentiable (ForwardDiff passes Dual numbers through x).
"""
function metric end

"""
    metric_inverse(m::MetricSpace{4}, x::SVec4d) -> SMat4d

Return the contravariant metric tensor g^mu^nu at spacetime point x.
Must satisfy g^mu^alpha g_alpha_nu = delta^mu_nu.
"""
function metric_inverse end

"""
    is_singular(m::MetricSpace{4}, x::SVec4d) -> Bool

Return true if x is at or inside a coordinate singularity (e.g., r <= 2M
for Schwarzschild coordinates). Used to terminate geodesic integration.
"""
function is_singular end

"""
    coordinate_bounds(m::MetricSpace{4})

Return valid coordinate ranges as a NamedTuple (e.g., `(r_min=2.0, r_max=Inf)`).
"""
function coordinate_bounds end

# ─────────────────────────────────────────────────────────────────────
# Default: ForwardDiff automatic derivatives of the inverse metric
# ─────────────────────────────────────────────────────────────────────

"""
    metric_inverse_partials(m::MetricSpace{4}, x::SVec4d) -> NTuple{4, SMat4d}

Compute ∂gᵅᵝ/∂xᵘ via ForwardDiff. Returns tuple of 4 matrices,
one per coordinate derivative.

Subtypes may override with analytic expressions for performance.
"""
function metric_inverse_partials(m::MetricSpace{4}, x::SVec4d)::NTuple{4, SMat4d}
    # metric_inverse returns SMat4d (16 components).
    # We differentiate the flattened 16-vector w.r.t. 4 coordinates → 16×4 Jacobian.
    f(x_) = SVector{16}(metric_inverse(m, x_))
    J = ForwardDiff.jacobian(f, x)  # 16×4

    # Reshape: column μ of J gives ∂gᵅᵝ/∂xᵘ as a flat 16-vector
    ntuple(μ -> SMat4d(J[:, μ]...), 4)
end

# ─────────────────────────────────────────────────────────────────────
# Hamiltonian and equations of motion
# ─────────────────────────────────────────────────────────────────────

"""
    hamiltonian(m::MetricSpace{4}, x::SVec4d, p::SVec4d) -> Float64

H = ½ gᵘᵛ pμ pν. Should be ≈ 0 for null geodesics.
This is the primary accuracy diagnostic during integration.
"""
function hamiltonian(m::MetricSpace{4}, x::SVec4d, p::SVec4d)::Float64
    ginv = metric_inverse(m, x)
    0.5 * dot(p, ginv * p)
end

"""
    hamiltonian_rhs(m::MetricSpace{4}, x::SVec4d, p::SVec4d)
        -> Tuple{SVec4d, SVec4d}

Hamilton's equations for null geodesics:

    dx^μ/dλ = ∂H/∂pμ = g^{μν} pν
    dpμ/dλ = -∂H/∂x^μ = -½ (∂g^{αβ}/∂x^μ) pα pβ

Returns (dx/dλ, dp/dλ).
"""
function hamiltonian_rhs(m::MetricSpace{4}, x::SVec4d, p::SVec4d)::Tuple{SVec4d, SVec4d}
    ginv = metric_inverse(m, x)
    dxdl = ginv * p

    partials = metric_inverse_partials(m, x)
    dpdl = SVec4d(ntuple(μ -> -0.5 * dot(p, partials[μ] * p), 4))

    (dxdl, dpdl)
end
