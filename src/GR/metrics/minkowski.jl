# minkowski.jl — Flat Minkowski spacetime (test helper)
#
# The Minkowski metric η_μν = diag(-1, 1, 1, 1) in Cartesian coordinates.
# Used as a trivial test case: all Christoffel symbols vanish,
# geodesics are straight lines, and ForwardDiff partials should be zero.

"""
    Minkowski <: MetricSpace{4}

Flat Minkowski spacetime in Cartesian coordinates (t, x, y, z).
"""
struct Minkowski <: MetricSpace{4} end

const _MINKOWSKI_METRIC = SMat4d(
    -1.0, 0.0, 0.0, 0.0,
     0.0, 1.0, 0.0, 0.0,
     0.0, 0.0, 1.0, 0.0,
     0.0, 0.0, 0.0, 1.0
)

# Accept any SVector{4, <:Real} for ForwardDiff compatibility.
# Metric functions must be differentiable — ForwardDiff passes Dual numbers through x.
metric(::Minkowski, x::SVector{4})::SMat4d = _MINKOWSKI_METRIC
metric_inverse(::Minkowski, x::SVector{4})::SMat4d = _MINKOWSKI_METRIC
is_singular(::Minkowski, x::SVec4d)::Bool = false
coordinate_bounds(::Minkowski) = (;)
