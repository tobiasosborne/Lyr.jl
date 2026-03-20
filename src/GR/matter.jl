# matter.jl — Matter sources for GR rendering
#
# Defines geometric objects that emit or absorb light:
# thin accretion disk, background star field.

"""
    MatterSource

Abstract type for matter sources intersected by geodesics. Concrete subtypes:
`ThinDisk` (equatorial plane), `CelestialSphere` (background sky),
`VolumetricMatter` (3D density distribution).
"""
abstract type MatterSource end

"""
    ThinDisk <: MatterSource

Geometrically thin accretion disk in the equatorial plane (θ = π/2).
Emits with power-law emissivity, orbiting material follows Keplerian orbits.

# Fields
- `inner_radius::Float64` — inner edge (typically ISCO = 6M)
- `outer_radius::Float64` — outer edge
"""
struct ThinDisk <: MatterSource
    inner_radius::Float64
    outer_radius::Float64
    r_isco::Float64
    T_inner::Float64  # peak temperature in Kelvin
end

# Backward-compatible 2-arg constructor
ThinDisk(inner_radius::Float64, outer_radius::Float64) =
    ThinDisk(inner_radius, outer_radius, inner_radius, 10000.0)

"""
    disk_emissivity(disk, r) -> Float64

Simplified emissivity profile: I ∝ (r_in/r)³.
Returns 0 outside disk bounds.
"""
function disk_emissivity(disk::ThinDisk, r::Float64)::Float64
    (r < disk.inner_radius || r > disk.outer_radius) && return 0.0
    (disk.inner_radius / r)^3
end

"""
    novikov_thorne_flux(r, M, r_isco) -> Float64

Radiative flux F(r) from Novikov-Thorne accretion (Page & Thorne 1974).
Zeroth-order approximation: F ∝ (1 - √(r_isco/r)) / r³.
Returns 0 below ISCO.
"""
function novikov_thorne_flux(r::Float64, M::Float64, r_isco::Float64)::Float64
    r <= r_isco && return 0.0
    (3.0 * M / (8.0 * π * r^3)) * (1.0 - sqrt(r_isco / r))
end

"""
    disk_temperature_nt(r, M, r_isco; T_inner=10000.0) -> Float64

Novikov-Thorne temperature profile: T(r) = T_inner × (F(r)/F_max)^{1/4}.
Peaks just outside ISCO, falls off at large r.
Returns 0 below ISCO.
"""
function disk_temperature_nt(r::Float64, M::Float64, r_isco::Float64;
                              T_inner::Float64=10000.0)::Float64
    F = novikov_thorne_flux(r, M, r_isco)
    F <= 0.0 && return 0.0
    # F_max occurs at r_peak ≈ (49/36) r_isco for zeroth-order NT
    # Compute it directly for normalization
    r_peak = (49.0 / 36.0) * r_isco
    F_max = novikov_thorne_flux(r_peak, M, r_isco)
    F_max <= 0.0 && return 0.0
    T_inner * (F / F_max)^0.25
end

"""
    keplerian_four_velocity(m::Schwarzschild, r) -> SVec4d

Contravariant 4-velocity u^μ of a circular Keplerian orbit at radius r.

For Schwarzschild: u^t = 1/√(1 - 3M/r), u^φ = √(M/r³) × u^t.
"""
function keplerian_four_velocity(m::Schwarzschild, r::Float64)::SVec4d
    M = m.M
    ut = 1.0 / sqrt(1.0 - 3.0 * M / r)
    uphi = sqrt(M / r^3) * ut
    SVec4d(ut, 0.0, 0.0, uphi)
end

# 3-arg form: BL metrics ignore position (only need r)
keplerian_four_velocity(m::Schwarzschild, r::Float64, ::SVec4d) = keplerian_four_velocity(m, r)

"""
    keplerian_four_velocity(m::Kerr{BoyerLindquist}, r) -> SVec4d

Contravariant 4-velocity u^μ of a prograde circular Keplerian orbit at radius r
in Boyer-Lindquist coordinates (equatorial plane, θ = π/2).

Uses Ω = √M / (r^{3/2} + a√M) and normalizes via g_μν u^μ u^ν = -1.
"""
function keplerian_four_velocity(m::Kerr{BoyerLindquist}, r::Float64)::SVec4d
    M, a = m.M, m.a
    Ω = sqrt(M) / (r^(3/2) + a * sqrt(M))
    # Evaluate metric at equatorial plane
    x = SVec4d(0.0, r, π/2, 0.0)
    g = metric(m, x)
    # g_tt + 2 g_tφ Ω + g_φφ Ω² from normalization with u^r = u^θ = 0
    denom = -(g[1,1] + 2.0 * g[1,4] * Ω + g[4,4] * Ω^2)
    ut = 1.0 / sqrt(max(denom, 1e-15))
    SVec4d(ut, 0.0, 0.0, Ω * ut)
end

# 3-arg form: BL metrics ignore position (only need r)
keplerian_four_velocity(m::Kerr{BoyerLindquist}, r::Float64, ::SVec4d) = keplerian_four_velocity(m, r)

"""
    keplerian_four_velocity(m::SchwarzschildKS, r, x) -> SVec4d

Keplerian 4-velocity in Cartesian KS coordinates.
The orbit has angular velocity Ω = √(M/r³) in the plane containing x.
"""
function keplerian_four_velocity(m::SchwarzschildKS, r::Float64, x::SVec4d)::SVec4d
    M = m.M
    Ω = sqrt(M / r^3)
    ut = 1.0 / sqrt(1.0 - 3.0 * M / r)
    # Orbital velocity: v = Ω × r_vec (cross product with z-axis for equatorial)
    # In the local plane: tangent direction = (-y, x, 0) / r_perp
    r_perp = sqrt(x[2]^2 + x[3]^2)
    r_perp = max(r_perp, 1e-15)
    vx = -x[3] / r_perp * Ω * r_perp  # = -y Ω
    vy =  x[2] / r_perp * Ω * r_perp  # =  x Ω
    SVec4d(ut, ut * vx, ut * vy, 0.0)
end

"""
    check_disk_crossing(m, prev, curr, disk) -> Union{Tuple{Float64, Float64}, Nothing}

Check if geodesic crossed the equatorial plane between two states.
Returns (r_crossing, interpolation_fraction) or nothing.

Dispatches on metric: BL uses θ = π/2, KS uses z = 0.
"""
function check_disk_crossing(::MetricSpace, prev::GeodesicState, curr::GeodesicState,
                             disk::ThinDisk)::Union{Tuple{Float64, Float64}, Nothing}
    θ_prev = prev.x[3]
    θ_curr = curr.x[3]
    equator = π / 2.0

    if (θ_prev - equator) * (θ_curr - equator) < 0.0
        frac = (equator - θ_prev) / (θ_curr - θ_prev)
        r_cross = prev.x[2] + frac * (curr.x[2] - prev.x[2])
        if disk.inner_radius <= r_cross <= disk.outer_radius
            return (r_cross, frac)
        end
    end
    return nothing
end

function check_disk_crossing(::SchwarzschildKS, prev::GeodesicState, curr::GeodesicState,
                             disk::ThinDisk)::Union{Tuple{Float64, Float64}, Nothing}
    z_prev = prev.x[4]
    z_curr = curr.x[4]

    if z_prev * z_curr < 0.0
        frac = -z_prev / (z_curr - z_prev)
        x_cross = prev.x + frac * (curr.x - prev.x)
        r_cross = sqrt(x_cross[2]^2 + x_cross[3]^2 + x_cross[4]^2)
        if disk.inner_radius <= r_cross <= disk.outer_radius
            return (r_cross, frac)
        end
    end
    return nothing
end

"""
    CelestialSphere <: MatterSource

Background star field mapped to a lat-lon texture.

# Fields
- `texture::Matrix{NTuple{3, Float64}}` — HDR lat-lon map (height × width, RGB)
- `radius::Float64` — extraction radius
"""
struct CelestialSphere <: MatterSource
    texture::Matrix{NTuple{3, Float64}}
    radius::Float64
end

"""
    sphere_lookup(sky, θ, φ) -> NTuple{3, Float64}

Look up color from celestial sphere texture at spherical coordinates (θ, φ).
Uses bilinear interpolation for smooth results.
"""
function sphere_lookup(sky::CelestialSphere, θ::Float64, φ::Float64)::NTuple{3, Float64}
    h, w = size(sky.texture)

    # Map to continuous pixel coordinates
    v = clamp(θ / π, 0.0, 1.0) * (h - 1) + 1.0   # [1, h]
    u = mod(φ, 2π) / (2π) * w + 0.5                # [0.5, w+0.5]

    # Bilinear interpolation
    i0 = clamp(floor(Int, v), 1, h)
    i1 = clamp(i0 + 1, 1, h)
    fv = v - i0

    # Horizontal: wrap with mod1 for periodic φ.
    # Keep raw floor for correct interpolation fraction across the wrap boundary.
    j0_raw = floor(Int, u)
    j0 = mod1(j0_raw, w)
    j1 = mod1(j0_raw + 1, w)
    fu = u - j0_raw

    c00 = sky.texture[i0, j0]
    c01 = sky.texture[i0, j1]
    c10 = sky.texture[i1, j0]
    c11 = sky.texture[i1, j1]

    _lerp3(a, b, t) = (a[1] + t * (b[1] - a[1]),
                        a[2] + t * (b[2] - a[2]),
                        a[3] + t * (b[3] - a[3]))

    top = _lerp3(c00, c01, fu)
    bot = _lerp3(c10, c11, fu)
    _lerp3(top, bot, fv)
end

"""
    checkerboard_sphere(θ, φ; n_checks=18) -> NTuple{3, Float64}

Procedural checkerboard pattern on a sphere. White and dark blue checks.
Useful for validation without needing a texture file.
"""
function checkerboard_sphere(θ::Float64, φ::Float64; n_checks::Int=18)::NTuple{3, Float64}
    u = mod(φ, 2π) / (2π)
    v = θ / π
    ci = floor(Int, u * n_checks)
    cj = floor(Int, v * n_checks ÷ 2)
    if (ci + cj) % 2 == 0
        (0.9, 0.9, 0.95)  # white
    else
        (0.05, 0.05, 0.2)  # dark blue
    end
end
