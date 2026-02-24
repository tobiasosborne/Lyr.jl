# weak_field.jl — Weak-field linearised metric (Phase 2 stub)
#
# g_00 = -(1 + 2Φ), g_ij = (1 - 2Φ)δ_ij, g_0i = 0
# where Φ is the gravitational potential from a Poisson solve.
#
# The potential Φ will be stored in a VDB Grid{Float32} and
# queried via trilinear interpolation at each geodesic step.

"""
    WeakField <: MetricSpace{4}

Linearised metric sourced by gravitational potential Φ(x,y,z).
Valid when |Φ| ≪ 1. Phase 2 implementation.
"""
struct WeakField <: MetricSpace{4}
    # Phase 2: will hold Grid{Float32} for Φ
end

metric(::WeakField, x::SVector{4}) = error("WeakField metric not yet implemented (Phase 2)")
metric_inverse(::WeakField, x::SVector{4}) = error("WeakField metric not yet implemented (Phase 2)")
is_singular(::WeakField, x::SVec4d) = false
coordinate_bounds(::WeakField) = (;)
