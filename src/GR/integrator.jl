# integrator.jl — Geodesic integration with adaptive Störmer-Verlet
#
# Hamiltonian formulation: H = ½ g^{μν} p_μ p_ν = 0 for null geodesics.
# The integrator uses adaptive step sizing based on distance from the
# photon sphere, where geodesics curve most sharply.

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
"""
struct IntegratorConfig
    step_size::Float64
    max_steps::Int
    h_tolerance::Float64
    r_max::Float64
    r_min_factor::Float64
    record_interval::Int
end

function IntegratorConfig(;
    step_size::Float64 = -0.1,
    max_steps::Int = 10_000,
    h_tolerance::Float64 = 1e-6,
    r_max::Float64 = 200.0,
    r_min_factor::Float64 = 1.01,
    record_interval::Int = 0
)
    IntegratorConfig(step_size, max_steps, h_tolerance, r_max, r_min_factor, record_interval)
end

# ─────────────────────────────────────────────────────────────────────
# Adaptive step sizing
# ─────────────────────────────────────────────────────────────────────

"""
    adaptive_step(dl_base, r, M) -> Float64

Scale the step size based on distance from the black hole.
Near the photon sphere (r ≈ 3M), steps shrink to maintain accuracy.
Far from the BH (r > 10M), steps grow up to dl_base for speed.
"""
function adaptive_step(dl_base::Float64, r::Float64, M::Float64)::Float64
    rh = 2.0 * M
    # Scale factor: ratio of (r - horizon) to some reference distance
    # Minimum scale 0.1 (near horizon), maximum 1.0 (far field)
    # The floor at 0.1 ensures rays near the photon sphere still make
    # progress through the strong-field region without exhausting step budget.
    scale = clamp((r - rh) / (8.0 * M), 0.1, 1.0)
    dl_base * scale
end

# ─────────────────────────────────────────────────────────────────────
# Störmer-Verlet step (one step, shared by integrator and renderer)
# ─────────────────────────────────────────────────────────────────────

"""
    verlet_step(m, x, p, dl) -> Tuple{SVec4d, SVec4d}

One Störmer-Verlet (leapfrog) step of the Hamiltonian system.
"""
function verlet_step(m::MetricSpace{4}, x::SVec4d, p::SVec4d, dl::Float64)::Tuple{SVec4d, SVec4d}
    # Half-step in momentum
    partials = metric_inverse_partials(m, x)
    dp1 = SVec4d(ntuple(μ -> -0.5 * dot(p, partials[μ] * p), 4))
    p_half = p + (dl / 2.0) * dp1

    # Full step in position
    ginv = metric_inverse(m, x)
    dxdl = ginv * p_half
    x_new = x + dl * dxdl

    # Half-step in momentum at new position
    partials2 = metric_inverse_partials(m, x_new)
    dp2 = SVec4d(ntuple(μ -> -0.5 * dot(p_half, partials2[μ] * p_half), 4))
    p_new = p_half + (dl / 2.0) * dp2

    (x_new, p_new)
end

"""
    renormalize_null(m, x, p) -> SVec4d

Project covariant momentum p_μ back onto the null cone by adjusting p_t.

Solves H = ½ g^{μν} p_μ p_ν = 0 for p_t while preserving spatial components
and the sign of p_t. This eliminates accumulated Hamiltonian drift exactly.
Standard technique in GR ray tracers (GYOTO, GRay2, RAPTOR).

For a general metric, the null condition is quadratic in p_t:
  A p_t² + B p_t + C = 0
where A = g^{tt}, B = 2 Σ_{i>0} g^{ti} p_i, C = Σ_{i,j>0} g^{ij} p_i p_j.
"""
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
    pt_new = (sign(p[1]) == sign(pt1)) ? pt1 : pt2

    SVec4d(pt_new, p[2], p[3], p[4])
end

"""
    integrate_geodesic(m, initial, config) -> GeodesicTrace

Integrate a null geodesic from `initial` state using adaptive Störmer-Verlet.
"""
function integrate_geodesic(m::MetricSpace{4}, initial::GeodesicState,
                            config::IntegratorConfig)::GeodesicTrace
    x = initial.x
    p = initial.p
    dl_base = config.step_size

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
        r = x[2]
        M_val = rh / 2.0  # extract M from horizon radius
        dl = M_val > 0.0 ? adaptive_step(dl_base, r, M_val) : dl_base

        x, p = verlet_step(m, x, p, dl)
        p = renormalize_null(m, x, p)
        r = x[2]

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

        H = abs(hamiltonian(m, x, p))
        h_max = max(h_max, H)
        if H > config.h_tolerance
            reason = HAMILTONIAN_DRIFT
            n_steps = step
            break
        end

        if config.record_interval > 0 && step % config.record_interval == 0
            push!(states, GeodesicState(x, p))
        end
    end

    push!(states, GeodesicState(x, p))
    GeodesicTrace(states, reason, h_max, n_steps)
end

# Fallback: horizon_radius for metrics without one (e.g. Minkowski)
horizon_radius(::MetricSpace) = 0.0
