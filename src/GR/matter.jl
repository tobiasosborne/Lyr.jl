# matter.jl — Matter sources for GR rendering
#
# Defines geometric objects that emit or absorb light:
# thin accretion disk, background star field.

"""Abstract type for matter sources intersected by geodesics."""
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
end

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
    check_disk_crossing(prev::GeodesicState, curr::GeodesicState, disk::ThinDisk)
        -> Union{Tuple{Float64, Float64}, Nothing}

Check if geodesic crossed the equatorial plane (θ = π/2) between two states.
Returns (r_crossing, interpolation_fraction) or nothing.
"""
function check_disk_crossing(prev::GeodesicState, curr::GeodesicState,
                             disk::ThinDisk)::Union{Tuple{Float64, Float64}, Nothing}
    θ_prev = prev.x[3]
    θ_curr = curr.x[3]
    equator = π / 2.0

    # Check sign change around equator
    if (θ_prev - equator) * (θ_curr - equator) < 0.0
        # Linear interpolation for crossing fraction
        frac = (equator - θ_prev) / (θ_curr - θ_prev)
        r_cross = prev.x[2] + frac * (curr.x[2] - prev.x[2])

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
