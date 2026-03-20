# integrator.jl — Geodesic integration with RK4 and Störmer-Verlet steppers
#
# Hamiltonian formulation: H = ½ g^{μν} p_μ p_ν = 0 for null geodesics.
# RK4 (4th-order, default) or Störmer-Verlet (2nd-order symplectic) stepper,
# with adaptive step sizing based on distance from the photon sphere.

# ─────────────────────────────────────────────────────────────────────
# Stepper types — compile-time dispatch eliminates branch in inner loop
# ─────────────────────────────────────────────────────────────────────
"""Abstract type for geodesic integration steppers. See `RK4` and `Verlet`."""
abstract type AbstractStepper end

"""Classic 4th-order Runge-Kutta stepper. 4 force evaluations per step, non-symplectic."""
struct RK4    <: AbstractStepper end

"""Stormer-Verlet (leapfrog) stepper. 2nd-order symplectic -- bounded energy drift."""
struct Verlet <: AbstractStepper end

"""
    IntegratorConfig(; kwargs...)

Configuration for geodesic integration.

# Fields
- `step_size::Float64` — base affine parameter step
- `max_steps::Int` — maximum integration steps
- `h_tolerance::Float64` — max allowed |H| drift before termination
- `r_max::Float64` — escape radius: terminate when r > r_max
- `r_min_factor::Float64` — terminate when r < r_min_factor × r_horizon
- `record_interval::Int` — record state every N steps (0 = endpoints only)
- `stepper::S` — `RK4()` (default, 4th-order) or `Verlet()` (2nd-order symplectic)
- `renorm_interval::Int` — null-cone re-projection every N steps (default 50 for RK4, 10 for Verlet)
"""
struct IntegratorConfig{S<:AbstractStepper}
    step_size::Float64
    max_steps::Int
    h_tolerance::Float64
    r_max::Float64
    r_min_factor::Float64
    record_interval::Int
    stepper::S
    renorm_interval::Int
end

function IntegratorConfig(;
    step_size::Float64 = -0.1,
    max_steps::Int = 10_000,
    h_tolerance::Float64 = 1e-6,
    r_max::Float64 = 200.0,
    r_min_factor::Float64 = 1.01,
    record_interval::Int = 0,
    stepper::AbstractStepper = RK4(),
    renorm_interval::Int = stepper isa RK4 ? 50 : 10
)
    IntegratorConfig(step_size, max_steps, h_tolerance, r_max, r_min_factor,
                     record_interval, stepper, renorm_interval)
end

# ─────────────────────────────────────────────────────────────────────
# Coordinate dispatch helpers (used by integrator, matter, render)
# ─────────────────────────────────────────────────────────────────────

@inline _coord_r(::MetricSpace, x::SVec4d) = x[2]
@inline _coord_r(::SchwarzschildKS, x::SVec4d) = sqrt(x[2]^2 + x[3]^2 + x[4]^2)

# BL-type coordinates need θ-regularization at poles; Cartesian KS does not
@inline _uses_polar_coords(::MetricSpace) = true
@inline _uses_polar_coords(::SchwarzschildKS) = false

# ─────────────────────────────────────────────────────────────────────
# Adaptive step sizing
# ─────────────────────────────────────────────────────────────────────

"""
    adaptive_step(dl_base, r, M) -> Float64

Scale the step size based on distance from the black hole.
Near the photon sphere (r ≈ 3M), steps shrink to maintain accuracy.
Far from the BH (r > 10M), steps grow up to dl_base for speed.
"""
@fastmath function adaptive_step(dl_base::Float64, r::Float64, M::Float64)::Float64
    rh = 2.0 * M
    # Quadratic refinement near horizon: concentrates steps in the strong-field
    # region (2M < r < 4M) where geodesic curvature is highest.
    # At photon sphere r=3M: scale = ((3M-2M)/(6M))^2 = 1/36 ≈ 0.028 → clamped to 0.05
    # At r=5M: scale = ((5M-2M)/(6M))^2 = 0.25
    # At r=8M: scale = 1.0 (far field)
    scale = clamp(((r - rh) / (6.0 * M))^2, 0.05, 1.0)
    dl_base * scale
end

# ─────────────────────────────────────────────────────────────────────
# RK4 step (classic 4th-order Runge-Kutta)
# ─────────────────────────────────────────────────────────────────────

"""
    rk4_step(m, x, p, dl) -> Tuple{SVec4d, SVec4d}

One classic RK4 step of the Hamiltonian system.
4th-order accurate: 4 evaluations of Hamilton's equations per step.
"""
@fastmath function rk4_step(m::MetricSpace{4}, x::SVec4d, p::SVec4d, dl::Float64)::Tuple{SVec4d, SVec4d}
    # k1
    dx1, dp1 = hamiltonian_rhs(m, x, p)

    # k2 (half-step)
    x2 = x + 0.5 * dl * dx1
    p2 = p + 0.5 * dl * dp1
    dx2, dp2 = hamiltonian_rhs(m, x2, p2)

    # k3 (half-step with k2 slopes)
    x3 = x + 0.5 * dl * dx2
    p3 = p + 0.5 * dl * dp2
    dx3, dp3 = hamiltonian_rhs(m, x3, p3)

    # k4 (full step with k3 slopes)
    x4 = x + dl * dx3
    p4 = p + dl * dp3
    dx4, dp4 = hamiltonian_rhs(m, x4, p4)

    # Weighted average
    x_new = x + (dl / 6.0) * (dx1 + 2.0 * dx2 + 2.0 * dx3 + dx4)
    p_new = p + (dl / 6.0) * (dp1 + 2.0 * dp2 + 2.0 * dp3 + dp4)

    (x_new, p_new)
end

# ─────────────────────────────────────────────────────────────────────
# Störmer-Verlet step (2nd-order symplectic, alternative stepper)
# ─────────────────────────────────────────────────────────────────────

"""
    verlet_step(m, x, p, dl) -> Tuple{SVec4d, SVec4d}

One Störmer-Verlet (leapfrog) step of the Hamiltonian system.
"""
@fastmath function verlet_step(m::MetricSpace{4}, x::SVec4d, p::SVec4d, dl::Float64)::Tuple{SVec4d, SVec4d}
    hdl = dl / 2.0

    # Half-step in momentum (unrolled — no closure, no Core.Box)
    partials = metric_inverse_partials(m, x)
    dp1 = SVec4d(-0.5 * dot(p, partials[1] * p),
                  -0.5 * dot(p, partials[2] * p),
                  -0.5 * dot(p, partials[3] * p),
                  -0.5 * dot(p, partials[4] * p))
    p_half = p + hdl * dp1

    # Full step in position
    ginv = metric_inverse(m, x)
    x_new = x + dl * (ginv * p_half)

    # Polar regularization: reflect θ at 0 and π to avoid coordinate singularity
    # Only for BL-type coordinates — Cartesian KS has no pole singularity
    if _uses_polar_coords(m)
        θ_new = x_new[3]
        if θ_new < 0.0
            x_new = SVec4d(x_new[1], x_new[2], -θ_new, x_new[4] + π)
            p_half = SVec4d(p_half[1], p_half[2], -p_half[3], p_half[4])
        elseif θ_new > π
            x_new = SVec4d(x_new[1], x_new[2], 2π - θ_new, x_new[4] + π)
            p_half = SVec4d(p_half[1], p_half[2], -p_half[3], p_half[4])
        end
    end

    # Half-step in momentum at new position (unrolled)
    partials2 = metric_inverse_partials(m, x_new)
    dp2 = SVec4d(-0.5 * dot(p_half, partials2[1] * p_half),
                  -0.5 * dot(p_half, partials2[2] * p_half),
                  -0.5 * dot(p_half, partials2[3] * p_half),
                  -0.5 * dot(p_half, partials2[4] * p_half))
    p_new = p_half + hdl * dp2

    (x_new, p_new)
end

"""
    renormalize_null(m, x, p) -> SVec4d

Project covariant momentum p_μ back onto the null cone by adjusting p_t.

Solves H = ½ g^{μν} p_μ p_ν = 0 for p_t while preserving spatial components
and the sign of p_t. This eliminates accumulated Hamiltonian drift exactly.
Standard technique in GR ray tracers (GYOTO, GRay2, RAPTOR).
"""

# Fast path for Schwarzschild (diagonal metric — no matrix needed)
function renormalize_null(m::Schwarzschild, x::SVec4d, p::SVec4d)::SVec4d
    r, θ = x[2], x[3]
    f = 1.0 - 2.0 * m.M / r
    inv_r2 = 1.0 / (r * r)
    sin2θ = max(sin(θ)^2, 1e-10)

    # g^{rr}p_r² + g^{θθ}p_θ² + g^{φφ}p_φ²
    C = f * p[2]^2 + inv_r2 * p[3]^2 + inv_r2 / sin2θ * p[4]^2
    # g^{tt} = -1/f, so p_t² = C × f  →  p_t = ±√(C × f)
    pt_mag = sqrt(max(C * f, 0.0))
    pt_new = p[1] < 0.0 ? -pt_mag : pt_mag
    SVec4d(pt_new, p[2], p[3], p[4])
end

# General fallback for non-diagonal metrics (Kerr, etc.)
function renormalize_null(m::MetricSpace{4}, x::SVec4d, p::SVec4d)::SVec4d
    ginv = metric_inverse(m, x)

    # Spatial contribution: C = Σ_{i,j>0} g^{ij} p_i p_j
    C = zero(Float64)
    for i in 2:4, j in 2:4
        C += ginv[i, j] * p[i] * p[j]
    end

    # Cross terms: B = 2 Σ_{i>0} g^{ti} p_i
    B = zero(Float64)
    for i in 2:4
        B += 2.0 * ginv[1, i] * p[i]
    end

    A = ginv[1, 1]  # g^{tt}

    # Solve A p_t² + B p_t + C = 0
    disc = B * B - 4.0 * A * C
    disc = max(disc, 0.0)  # numerical safety
    sqrt_disc = sqrt(disc)

    # Two roots — pick the one with the same sign as the original p_t
    pt1 = (-B + sqrt_disc) / (2.0 * A)
    pt2 = (-B - sqrt_disc) / (2.0 * A)
    pt_new = if p[1] != 0.0
        sign(p[1]) == sign(pt1) ? pt1 : pt2
    else
        # p_t = 0: pick the larger magnitude root (physical branch)
        abs(pt1) > abs(pt2) ? pt1 : pt2
    end

    SVec4d(pt_new, p[2], p[3], p[4])
end

# ─────────────────────────────────────────────────────────────────────
# Stepper dispatch: select RK4 or Verlet based on config
# ─────────────────────────────────────────────────────────────────────

@inline _do_step(m::MetricSpace{4}, x::SVec4d, p::SVec4d, dl::Float64, ::RK4) =
    rk4_step(m, x, p, dl)
@inline _do_step(m::MetricSpace{4}, x::SVec4d, p::SVec4d, dl::Float64, ::Verlet) =
    verlet_step(m, x, p, dl)

"""
    integrate_geodesic(m, initial, config) -> GeodesicTrace

Integrate a null geodesic from `initial` state using adaptive RK4 or Störmer-Verlet.
"""
function integrate_geodesic(m::MetricSpace{4}, initial::GeodesicState,
                            config::IntegratorConfig)::GeodesicTrace
    x = initial.x
    p = initial.p
    dl_base = config.step_size
    stepper = config.stepper
    renorm_interval = config.renorm_interval

    states = GeodesicState[initial]
    if config.record_interval > 0
        sizehint!(states, config.max_steps ÷ config.record_interval + 2)
    end

    h_max = abs(hamiltonian(m, x, p))
    reason = MAX_STEPS
    n_steps = config.max_steps
    rh = horizon_radius(m)

    for step in 1:config.max_steps
        # Adaptive step size based on distance from BH
        r = _coord_r(m, x)
        M_val = rh / 2.0  # extract M from horizon radius
        dl = M_val > 0.0 ? adaptive_step(dl_base, r, M_val) : dl_base

        x, p = _do_step(m, x, p, dl, stepper)
        if renorm_interval > 0 && step % renorm_interval == 0
            p = renormalize_null(m, x, p)
        end
        r = _coord_r(m, x)

        # ── Termination checks ──
        if r <= rh * config.r_min_factor
            reason = HORIZON
            n_steps = step
            break
        end

        if r >= config.r_max
            reason = ESCAPED
            n_steps = step
            break
        end

        if is_singular(m, x)
            reason = SINGULARITY
            n_steps = step
            break
        end

        # Hamiltonian drift check — same interval as renormalization (avoids
        # redundant metric_inverse evaluation on every step)
        if renorm_interval > 0 && step % renorm_interval == 0
            H = abs(hamiltonian(m, x, p))
            h_max = max(h_max, H)
            if H > config.h_tolerance
                reason = HAMILTONIAN_DRIFT
                n_steps = step
                break
            end
        end

        if config.record_interval > 0 && step % config.record_interval == 0
            push!(states, GeodesicState(x, p))
        end
    end

    push!(states, GeodesicState(x, p))
    GeodesicTrace(states, reason, h_max, n_steps)
end

"""
    horizon_radius(m::MetricSpace) -> Float64

Return the event horizon radius. Defaults to 0.0 for flat spacetimes.
Overridden by Schwarzschild (2M), Kerr (M + sqrt(M^2 - a^2)), etc.
"""
horizon_radius(::MetricSpace) = 0.0
