# PhaseFunction.jl - Phase functions for volume scattering

using Random: AbstractRNG, rand

"""
    PhaseFunction

Abstract type for phase functions that describe the angular distribution
of scattered light in a participating medium.

A phase function p(cos_theta) gives the probability density (per steradian)
that light is scattered through angle theta. It must satisfy the
normalization condition: integral over the sphere = 1.
"""
abstract type PhaseFunction end

"""
    IsotropicPhase <: PhaseFunction

Isotropic phase function — equal probability of scattering in all directions.

Evaluates to 1/(4pi) for all scattering angles.
"""
struct IsotropicPhase <: PhaseFunction end

"""
    HenyeyGreensteinPhase <: PhaseFunction

Henyey-Greenstein phase function with asymmetry parameter g in (-1, 1).

The parameter g controls the shape of the scattering lobe:
- g = 0: isotropic scattering
- g > 0: forward-peaked scattering (light continues roughly in its original direction)
- g < 0: backward-peaked scattering (light is reflected back)

# Fields
- `g::Float64` - Asymmetry parameter, must satisfy -1 < g < 1
"""
struct HenyeyGreensteinPhase <: PhaseFunction
    g::Float64

    function HenyeyGreensteinPhase(g::Float64)
        (-1.0 < g < 1.0) || throw(ArgumentError("Asymmetry parameter g must satisfy -1 < g < 1, got $g"))
        new(g)
    end
end

const _INV_FOUR_PI = 1.0 / (4.0 * pi)

"""
    evaluate(pf::IsotropicPhase, cos_theta::Float64) -> Float64

Evaluate the isotropic phase function. Returns 1/(4pi) for any angle.
"""
function evaluate(::IsotropicPhase, cos_theta::Float64)::Float64
    _INV_FOUR_PI
end

"""
    evaluate(pf::HenyeyGreensteinPhase, cos_theta::Float64) -> Float64

Evaluate the Henyey-Greenstein phase function for a given cos(theta).

    p(cos_theta) = (1 - g^2) / (4pi * (1 + g^2 - 2*g*cos_theta)^(3/2))
"""
function evaluate(pf::HenyeyGreensteinPhase, cos_theta::Float64)::Float64
    g = pf.g
    # For g very close to zero, return isotropic value to avoid numerical issues
    abs(g) < 1e-10 && return _INV_FOUR_PI

    denom = 1.0 + g * g - 2.0 * g * cos_theta
    (1.0 - g * g) / (4.0 * pi * denom * sqrt(denom))
end

"""
    sample_phase(pf::IsotropicPhase, incoming::SVec3d, rng::AbstractRNG) -> SVec3d

Sample a uniformly random direction on the unit sphere.

The incoming direction is ignored since isotropic scattering has no preferred
direction, but it is accepted for API consistency.
"""
function sample_phase(::IsotropicPhase, incoming::SVec3d, rng::AbstractRNG)::SVec3d
    # Uniform sphere sampling via Archimedes' theorem
    cos_theta = 1.0 - 2.0 * rand(rng)
    sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta))
    phi = 2.0 * pi * rand(rng)

    SVec3d(sin_theta * cos(phi), sin_theta * sin(phi), cos_theta)
end

"""
    sample_phase(pf::HenyeyGreensteinPhase, incoming::SVec3d, rng::AbstractRNG) -> SVec3d

Sample a scattering direction from the Henyey-Greenstein distribution.

Uses the analytic inverse CDF to sample cos(theta), then constructs a local
coordinate frame from the incoming direction to orient the scattered ray.

For g = 0, falls back to uniform sphere sampling.
"""
function sample_phase(pf::HenyeyGreensteinPhase, incoming::SVec3d, rng::AbstractRNG)::SVec3d
    g = pf.g

    # For g near zero, use isotropic sampling
    if abs(g) < 1e-10
        return sample_phase(IsotropicPhase(), incoming, rng)
    end

    # Analytic inverse CDF for cos(theta)
    xi = rand(rng)
    s = (1.0 - g * g) / (1.0 + g - 2.0 * g * xi)
    cos_theta = (1.0 + g * g - s * s) / (2.0 * g)
    cos_theta = clamp(cos_theta, -1.0, 1.0)

    sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta))
    phi = 2.0 * pi * rand(rng)

    # Build local coordinate frame from incoming direction
    # The scattered direction is expressed relative to the incoming direction
    w = incoming  # already unit vector (assumed normalized)
    t, b = _build_orthonormal_basis(w)

    # Scatter direction in world coordinates
    dir = sin_theta * cos(phi) * t + sin_theta * sin(phi) * b + cos_theta * w

    # Normalize to counteract floating-point drift
    dir / norm(dir)
end

"""
    _build_orthonormal_basis(w::SVec3d) -> Tuple{SVec3d, SVec3d}

Construct two vectors (t, b) orthogonal to w, forming a right-handed
orthonormal basis. Uses Gram-Schmidt with least-aligned axis selection for stability.
"""
function _build_orthonormal_basis(w::SVec3d)::Tuple{SVec3d, SVec3d}
    # Choose the axis with smallest component to avoid catastrophic cancellation
    if abs(w[1]) < abs(w[2])
        if abs(w[1]) < abs(w[3])
            # w[1] is smallest — cross with x-axis
            helper = SVec3d(1.0, 0.0, 0.0)
        else
            helper = SVec3d(0.0, 0.0, 1.0)
        end
    else
        if abs(w[2]) < abs(w[3])
            helper = SVec3d(0.0, 1.0, 0.0)
        else
            helper = SVec3d(0.0, 0.0, 1.0)
        end
    end

    # Gram-Schmidt: t = normalize(helper - (helper . w) * w)
    t_raw = helper - dot(helper, w) * w
    t_len = norm(t_raw)
    t = t_raw / t_len

    # b = w × t (already unit length since w and t are orthonormal)
    b = cross(w, t)

    (t, b)
end
