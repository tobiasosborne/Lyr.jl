# types.jl — Core type definitions for GR ray tracing
#
# Spacetime 4-vectors, metric tensors, and geodesic data structures.

using StaticArrays

"""
    SVec4d

4D spacetime vector: (t, x1, x2, x3) in Cartesian or (t, r, theta, phi) in
Boyer-Lindquist coordinates. Stack-allocated via StaticArrays.
"""
const SVec4d = SVector{4, Float64}

"""
    SMat4d

4x4 spacetime matrix for metric tensors g_mu_nu, inverse metrics g^mu^nu,
and tetrad frames. Stack-allocated via StaticArrays.
"""
const SMat4d = SMatrix{4, 4, Float64, 16}

"""
    TerminationReason

Reason a geodesic integration terminated. Values: `ESCAPED` (r > r_max),
`HORIZON` (r < r_horizon), `SINGULARITY`, `MAX_STEPS`, `HAMILTONIAN_DRIFT`
(|H| exceeded tolerance), `DISK_HIT` (intersected thin disk).
"""
@enum TerminationReason begin
    ESCAPED           # r > r_max
    HORIZON           # r < r_horizon × (1 + ε)
    SINGULARITY       # coordinate singularity detected
    MAX_STEPS         # step budget exhausted
    HAMILTONIAN_DRIFT # |H| exceeded tolerance
    DISK_HIT          # intersected thin disk equatorial plane
end

"""
    GeodesicState(x, p)

State of a photon on a null geodesic.

# Fields
- `x::SVec4d` — spacetime coordinates (e.g. t, r, θ, φ)
- `p::SVec4d` — covariant momentum pμ
"""
struct GeodesicState
    x::SVec4d
    p::SVec4d
end

"""
    GeodesicTrace(states, reason, hamiltonian_max, n_steps)

Recorded trace of a geodesic integration.

# Fields
- `states::Vector{GeodesicState}` — sampled states along the geodesic
- `reason::TerminationReason` — why integration stopped
- `hamiltonian_max::Float64` — maximum |H| observed (should be ≈ 0 for null geodesics)
- `n_steps::Int` — total integration steps taken
"""
struct GeodesicTrace
    states::Vector{GeodesicState}
    reason::TerminationReason
    hamiltonian_max::Float64
    n_steps::Int
end
