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

function volumetric_redshift(m::Kerr{BoyerLindquist}, x::SVec4d, p::SVec4d,
                              p0::SVec4d, u_obs::SVec4d)::Float64
    r = x[2]
    r_plus = horizon_radius(m)
    r <= r_plus * 1.1 && return 1.0
    u_emit = keplerian_four_velocity(m, r)
    redshift_factor(p, u_emit, p0, u_obs)
end

"""
    doppler_color(base_color, z) -> NTuple{3, Float64}

Apply redshift/blueshift to a base color.
Blueshift (z < 0) shifts toward blue, redshift (z > 0) toward red.
"""
function doppler_color(base_color::NTuple{3, Float64}, z::Float64)::NTuple{3, Float64}
    # Bolometric intensity scales as (1+z)^{-4} for broadband RGB
    # (extra factor of (1+z) from frequency integration: dν_obs = dν_emit/(1+z))
    scale = 1.0 / (1.0 + z)^4
    scale = clamp(scale, 0.0, 5.0)  # prevent blowup
    (clamp(base_color[1] * scale, 0.0, 1.0),
     clamp(base_color[2] * scale, 0.0, 1.0),
     clamp(base_color[3] * scale, 0.0, 1.0))
end

"""
    scale_rgb(c, s) -> NTuple{3, Float64}

Scale an RGB color tuple by a scalar, clamping to [0,1].
"""
@inline function scale_rgb(c::NTuple{3, Float64}, s::Float64)::NTuple{3, Float64}
    (clamp(c[1] * s, 0.0, 1.0),
     clamp(c[2] * s, 0.0, 1.0),
     clamp(c[3] * s, 0.0, 1.0))
end

# ─────────────────────────────────────────────────────────────────────
# Planck spectrum → sRGB conversion
# ─────────────────────────────────────────────────────────────────────

# CIE 1931 2° standard observer color matching functions, 5nm sampling (380–780nm)
# Each entry: (λ_nm, x̄, ȳ, z̄)
const _CIE_XYZ_5NM = (
    (380, 0.001368, 0.000039, 0.006450), (385, 0.002236, 0.000064, 0.010550),
    (390, 0.004243, 0.000120, 0.020050), (395, 0.007650, 0.000217, 0.036210),
    (400, 0.014310, 0.000396, 0.067850), (405, 0.023190, 0.000640, 0.110200),
    (410, 0.043510, 0.001210, 0.207400), (415, 0.077630, 0.002180, 0.371300),
    (420, 0.134380, 0.004000, 0.645600), (425, 0.214770, 0.007300, 1.039050),
    (430, 0.283900, 0.011600, 1.385600), (435, 0.328500, 0.016840, 1.622960),
    (440, 0.348280, 0.023000, 1.747060), (445, 0.348060, 0.029800, 1.782600),
    (450, 0.336200, 0.038000, 1.772110), (455, 0.318700, 0.048000, 1.744100),
    (460, 0.290800, 0.060000, 1.669200), (465, 0.251100, 0.073900, 1.528100),
    (470, 0.195360, 0.090980, 1.287640), (475, 0.142100, 0.112600, 1.041900),
    (480, 0.095640, 0.139020, 0.812950), (485, 0.058010, 0.169300, 0.616200),
    (490, 0.032010, 0.208020, 0.465180), (495, 0.014700, 0.258600, 0.353300),
    (500, 0.004900, 0.323000, 0.272000), (505, 0.002400, 0.407300, 0.212300),
    (510, 0.009300, 0.503000, 0.158200), (515, 0.029100, 0.608200, 0.111700),
    (520, 0.063270, 0.710000, 0.078250), (525, 0.109600, 0.793200, 0.057250),
    (530, 0.165500, 0.862000, 0.042160), (535, 0.225750, 0.914850, 0.029840),
    (540, 0.290400, 0.954000, 0.020300), (545, 0.359700, 0.980300, 0.013400),
    (550, 0.433450, 0.994950, 0.008750), (555, 0.512050, 1.000000, 0.005750),
    (560, 0.594500, 0.995000, 0.003900), (565, 0.678400, 0.978600, 0.002750),
    (570, 0.762100, 0.952000, 0.002100), (575, 0.842500, 0.915400, 0.001800),
    (580, 0.916300, 0.870000, 0.001650), (585, 0.978600, 0.816300, 0.001400),
    (590, 1.026300, 0.757000, 0.001100), (595, 1.056700, 0.694900, 0.001000),
    (600, 1.062200, 0.631000, 0.000800), (605, 1.045600, 0.566800, 0.000600),
    (610, 1.002600, 0.503000, 0.000340), (615, 0.938400, 0.441200, 0.000240),
    (620, 0.854450, 0.381000, 0.000190), (625, 0.751400, 0.321000, 0.000100),
    (630, 0.642400, 0.265000, 0.000050), (635, 0.541900, 0.217000, 0.000030),
    (640, 0.447900, 0.175000, 0.000020), (645, 0.360800, 0.138200, 0.000010),
    (650, 0.283500, 0.107000, 0.000000), (655, 0.218700, 0.081600, 0.000000),
    (660, 0.164900, 0.061000, 0.000000), (665, 0.121200, 0.044580, 0.000000),
    (670, 0.087400, 0.032000, 0.000000), (675, 0.063600, 0.023200, 0.000000),
    (680, 0.046770, 0.017000, 0.000000), (685, 0.032900, 0.011920, 0.000000),
    (690, 0.022700, 0.008210, 0.000000), (695, 0.015840, 0.005723, 0.000000),
    (700, 0.011359, 0.004102, 0.000000), (705, 0.008111, 0.002929, 0.000000),
    (710, 0.005790, 0.002091, 0.000000), (715, 0.004109, 0.001484, 0.000000),
    (720, 0.002899, 0.001047, 0.000000), (725, 0.002049, 0.000740, 0.000000),
    (730, 0.001440, 0.000520, 0.000000), (735, 0.001000, 0.000361, 0.000000),
    (740, 0.000690, 0.000249, 0.000000), (745, 0.000476, 0.000172, 0.000000),
    (750, 0.000332, 0.000120, 0.000000), (755, 0.000235, 0.000085, 0.000000),
    (760, 0.000166, 0.000060, 0.000000), (765, 0.000117, 0.000042, 0.000000),
    (770, 0.000083, 0.000030, 0.000000), (775, 0.000059, 0.000021, 0.000000),
    (780, 0.000042, 0.000015, 0.000000),
)

# Physical constants for Planck's law (SI)
const _PLANCK_H = 6.62607015e-34   # J·s
const _PLANCK_C = 2.99792458e8     # m/s
const _PLANCK_K = 1.380649e-23     # J/K

"""
    planck_spectral_radiance(λ_m, T) -> Float64

Planck's law: spectral radiance B(λ,T) in W·sr⁻¹·m⁻³.
λ_m is wavelength in meters, T is temperature in Kelvin.
"""
@inline function planck_spectral_radiance(λ_m::Float64, T::Float64)::Float64
    T <= 0.0 && return 0.0
    c1 = 2.0 * _PLANCK_H * _PLANCK_C^2
    c2 = _PLANCK_H * _PLANCK_C / _PLANCK_K
    exponent = c2 / (λ_m * T)
    exponent > 500.0 && return 0.0  # prevent overflow
    c1 / (λ_m^5 * (exp(exponent) - 1.0))
end

"""
    planck_to_xyz(T) -> NTuple{3, Float64}

Integrate Planck spectrum × CIE color matching functions over visible range.
Returns unnormalized (X, Y, Z) tristimulus values.
"""
function planck_to_xyz(T::Float64)::NTuple{3, Float64}
    T <= 0.0 && return (0.0, 0.0, 0.0)
    X, Y, Z = 0.0, 0.0, 0.0
    dλ = 5e-9  # 5nm step in meters
    for (λ_nm, xbar, ybar, zbar) in _CIE_XYZ_5NM
        λ_m = λ_nm * 1e-9
        B = planck_spectral_radiance(λ_m, T)
        X += B * xbar * dλ
        Y += B * ybar * dλ
        Z += B * zbar * dλ
    end
    (X, Y, Z)
end

"""
    xyz_to_srgb(X, Y, Z) -> NTuple{3, Float64}

Convert CIE XYZ to linear sRGB using IEC 61966-2-1 matrix.
Returns unclamped linear RGB (may be negative for out-of-gamut colors).
"""
@inline function xyz_to_srgb(X::Float64, Y::Float64, Z::Float64)::NTuple{3, Float64}
    # sRGB D65 matrix (IEC 61966-2-1)
    r =  3.2406 * X - 1.5372 * Y - 0.4986 * Z
    g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z
    b =  0.0557 * X - 0.2040 * Y + 1.0570 * Z
    (r, g, b)
end

"""
    srgb_gamma(c) -> Float64

Apply sRGB gamma correction (IEC 61966-2-1) to a linear channel value.
"""
@inline function srgb_gamma(c::Float64)::Float64
    c <= 0.0031308 ? 12.92 * c : 1.055 * c^(1.0/2.4) - 0.055
end

"""
    planck_to_rgb(T_kelvin) -> NTuple{3, Float64}

Convert blackbody temperature (Kelvin) to sRGB color, normalized and gamma-corrected.
Returns (R, G, B) each in [0, 1].
"""
function planck_to_rgb(T_kelvin::Float64)::NTuple{3, Float64}
    T_kelvin <= 0.0 && return (0.0, 0.0, 0.0)

    X, Y, Z = planck_to_xyz(T_kelvin)
    Y <= 0.0 && return (0.0, 0.0, 0.0)

    # Normalize so max luminance Y = 1
    inv_Y = 1.0 / Y
    r_lin, g_lin, b_lin = xyz_to_srgb(X * inv_Y, 1.0, Z * inv_Y)

    # Clamp negatives (out-of-gamut), apply gamma
    (clamp(srgb_gamma(max(r_lin, 0.0)), 0.0, 1.0),
     clamp(srgb_gamma(max(g_lin, 0.0)), 0.0, 1.0),
     clamp(srgb_gamma(max(b_lin, 0.0)), 0.0, 1.0))
end

# ─────────────────────────────────────────────────────────────────────
# Planck RGB lookup table — replaces 81 exp() calls with lerp
# ─────────────────────────────────────────────────────────────────────

const _PLANCK_LUT_N = 2048
const _PLANCK_LUT_LOG_T_MIN = log(500.0)     # K (cool red)
const _PLANCK_LUT_LOG_T_MAX = log(100000.0)  # K (hot blue-white)
const _PLANCK_LUT_INV_DLT = (_PLANCK_LUT_N - 1) / (_PLANCK_LUT_LOG_T_MAX - _PLANCK_LUT_LOG_T_MIN)

const _PLANCK_LUT = let
    lut = Vector{NTuple{3, Float64}}(undef, _PLANCK_LUT_N)
    for i in 1:_PLANCK_LUT_N
        logT = _PLANCK_LUT_LOG_T_MIN + (i - 1) / (_PLANCK_LUT_N - 1) * (_PLANCK_LUT_LOG_T_MAX - _PLANCK_LUT_LOG_T_MIN)
        lut[i] = planck_to_rgb(exp(logT))
    end
    lut
end

"""
    planck_to_rgb_fast(T_kelvin) -> NTuple{3, Float64}

LUT-accelerated Planck→sRGB for the volumetric inner loop.
Log-spaced 2048-entry table with linear interpolation. Max error < 0.005 per channel.
"""
@inline function planck_to_rgb_fast(T_kelvin::Float64)::NTuple{3, Float64}
    T_kelvin <= 0.0 && return (0.0, 0.0, 0.0)
    logT = log(clamp(T_kelvin, 500.0, 100000.0))
    t = (logT - _PLANCK_LUT_LOG_T_MIN) * _PLANCK_LUT_INV_DLT
    i = unsafe_trunc(Int, t)
    i = clamp(i, 0, _PLANCK_LUT_N - 2)
    f = t - i
    @inbounds begin
        a = _PLANCK_LUT[i + 1]
        b = _PLANCK_LUT[i + 2]
    end
    (a[1] + f * (b[1] - a[1]),
     a[2] + f * (b[2] - a[2]),
     a[3] + f * (b[3] - a[3]))
end
