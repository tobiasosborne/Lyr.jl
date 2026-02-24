# redshift.jl — Frequency shift and color mapping
#
# The invariant redshift factor 1+z = (p_μ u^μ)_emit / (p_μ u^μ)_obs
# handles gravitational, Doppler, and cosmological redshift simultaneously.

"""
    redshift_factor(p_emit, u_emit, p_obs, u_obs) -> Float64

Compute 1 + z = (p_μ u^μ)_emit / (p_μ u^μ)_obs.

Both p and u are in the same coordinate basis. p is covariant (lower index),
u is contravariant (upper index), so the contraction is just `dot(p, u)`.
"""
function redshift_factor(p_emit::SVec4d, u_emit::SVec4d,
                          p_obs::SVec4d, u_obs::SVec4d)::Float64
    dot(p_emit, u_emit) / dot(p_obs, u_obs)
end

"""
    temperature_shift(T_emit, z) -> Float64

Observed temperature: T_obs = T_emit / (1 + z).
"""
temperature_shift(T_emit::Float64, z::Float64)::Float64 = T_emit / (1.0 + z)

"""
    blackbody_color(T) -> NTuple{3, Float64}

Simple blackbody-inspired RGB mapping for visualization.
Maps temperature (arbitrary units) to a warm color ramp:
cold (red) → hot (white-blue).
"""
function blackbody_color(T::Float64)::NTuple{3, Float64}
    T <= 0.0 && return (0.0, 0.0, 0.0)
    # Simple ramp: R saturates first, then G, then B
    r = clamp(T / 0.5, 0.0, 1.0)
    g = clamp((T - 0.3) / 0.7, 0.0, 1.0)
    b = clamp((T - 0.7) / 0.5, 0.0, 1.0)
    (r, g, b)
end

"""
    volumetric_redshift(m::Schwarzschild, x, p, p0, u_obs) -> Float64

Compute 1+z at a geodesic step for Keplerian-orbiting matter.
Extracts r from the geodesic position and uses the local Keplerian 4-velocity.
Returns 1+z (positive = redshift, < 1 = blueshift).
"""
function volumetric_redshift(m::Schwarzschild, x::SVec4d, p::SVec4d,
                              p0::SVec4d, u_obs::SVec4d)::Float64
    r = x[2]
    r <= 3.0 * m.M && return 1.0
    u_emit = keplerian_four_velocity(m, r)
    redshift_factor(p, u_emit, p0, u_obs)
end

function volumetric_redshift(m::SchwarzschildKS, x::SVec4d, p::SVec4d,
                              p0::SVec4d, u_obs::SVec4d)::Float64
    r = sqrt(x[2]^2 + x[3]^2 + x[4]^2)
    r <= 3.0 * m.M && return 1.0
    u_emit = keplerian_four_velocity(m, r, x)
    redshift_factor(p, u_emit, p0, u_obs)
end

"""
    doppler_color(base_color, z) -> NTuple{3, Float64}

Apply redshift/blueshift to a base color.
Blueshift (z < 0) shifts toward blue, redshift (z > 0) toward red.
"""
function doppler_color(base_color::NTuple{3, Float64}, z::Float64)::NTuple{3, Float64}
    # Intensity scales as (1+z)^{-3} (Liouville invariant I_ν/ν³)
    scale = 1.0 / (1.0 + z)^3
    scale = clamp(scale, 0.0, 5.0)  # prevent blowup
    (clamp(base_color[1] * scale, 0.0, 1.0),
     clamp(base_color[2] * scale, 0.0, 1.0),
     clamp(base_color[3] * scale, 0.0, 1.0))
end
