# Wavepackets.jl — Gaussian wavepackets, potential surfaces, and nuclear dynamics
#
# Infrastructure for scattering visualizations: free-particle wavepackets with
# closed-form time evolution, Morse and Kolos-Wolniewicz potential energy surfaces
# for H₂, and velocity-Verlet nuclear trajectory integration.
#
# All quantities in atomic units (ℏ = m_e = e = a₀ = 1).
# Physics references: docs/scattering_physics.md

# ============================================================================
# I. Gaussian Wavepackets
# ============================================================================

"""
    gaussian_wavepacket(x, y, z, t, p0, r0, d, m) → ComplexF64

3D free-particle Gaussian wavepacket with closed-form time evolution.

# Arguments
- `x, y, z` — evaluation point
- `t` — time
- `p0` — central momentum (px, py, pz)
- `r0` — initial center (x₀, y₀, z₀)
- `d` — initial position-space width (standard deviation)
- `m` — particle mass (1.0 for electron, 1836.15267 for proton)
"""
function gaussian_wavepacket(x::Float64, y::Float64, z::Float64, t::Float64,
                             p0::NTuple{3,Float64}, r0::NTuple{3,Float64},
                             d::Float64, m::Float64)
    # EQ:WAVEPACKET-3D — Schwabl Eq. (2.5), p. 16
    # EQ:GAUSSIAN-PROFILE — Schwabl Eqs. (2.6, 2.13), pp. 16-17
    # EQ:WAVEPACKET-SPREADING — Schwabl Eqs. (2.12, 2.14), p. 17
    #
    # ψ(r,t) = (2πd²)^(-3/4) (1+iΔ)^(-3/2) exp(A + iB)
    # Δ = t/(2md²),  v_g = p₀/m
    # A = -|r - r₀ - v_g t|² / (4d²(1+iΔ))
    # B = p₀·r - |p₀|²t/(2m)

    Δ = t / (2.0 * m * d^2)
    vgx, vgy, vgz = p0[1] / m, p0[2] / m, p0[3] / m

    # Displacement from center
    dx = x - r0[1] - vgx * t
    dy = y - r0[2] - vgy * t
    dz = z - r0[3] - vgz * t
    dr2 = dx^2 + dy^2 + dz^2

    # Complex width factor
    σ2_complex = d^2 * (1.0 + im * Δ)

    # Spatial envelope (complex Gaussian)
    A = -dr2 / (4.0 * σ2_complex)

    # Phase: plane wave + free-particle dispersion
    p2 = p0[1]^2 + p0[2]^2 + p0[3]^2
    B = p0[1] * x + p0[2] * y + p0[3] * z - p2 * t / (2.0 * m)

    # Prefactor: normalization × spreading
    prefactor = (2π * d^2)^(-0.75) * (1.0 + im * Δ)^(-1.5)

    return prefactor * exp(A + im * B)
end

"""
    wavepacket_width(t, d, m) → Float64

Position-space width of a Gaussian wavepacket at time t.
"""
function wavepacket_width(t::Float64, d::Float64, m::Float64)
    # EQ:WAVEPACKET-WIDTH — Schwabl Eq. (2.16), p. 18
    # Δx(t) = d √(1 + (t/(2md²))²)
    Δ = t / (2.0 * m * d^2)
    d * sqrt(1.0 + Δ^2)
end

# ============================================================================
# II. Morse Potential
# ============================================================================

"""
    MorsePotential(De, Re, a)

Morse potential V(R) = De(1 - e^{-a(R-Re)})² for diatomic molecules.

- `De` — dissociation energy (a.u.)
- `Re` — equilibrium bond length (a.u.)
- `a` — steepness parameter (a.u.⁻¹)
"""
struct MorsePotential
    De::Float64
    Re::Float64
    a::Float64
end

"""Standard H₂ ground state Morse parameters."""
const H2_MORSE = MorsePotential(0.1745, 1.401, 1.028)
# EQ:MORSE-POTENTIAL — De = 4.747 eV / 27.2114 eV/a.u. = 0.1745 a.u.
# Re = 1.401 a.u. from [KW1968], a = 1.028 a.u.⁻¹

"""
    morse_potential(V, R) → Float64

Evaluate Morse potential at internuclear separation R.
"""
function morse_potential(V::MorsePotential, R::Float64)
    # EQ:MORSE-POTENTIAL — Schwabl / standard, V(R) = De(1 - e^{-a(R-Re)})²
    exp_term = exp(-V.a * (R - V.Re))
    V.De * (1.0 - exp_term)^2
end

"""
    morse_force(V, R) → Float64

Force F = -dV/dR from the Morse potential at separation R.
"""
function morse_force(V::MorsePotential, R::Float64)
    # F = -dV/dR = -2 De a (1 - e^{-a(R-Re)}) e^{-a(R-Re)}
    exp_term = exp(-V.a * (R - V.Re))
    -2.0 * V.De * V.a * (1.0 - exp_term) * exp_term
end

Base.show(io::IO, V::MorsePotential) =
    print(io, "MorsePotential(De=$(V.De), Re=$(V.Re), a=$(V.a))")

# ============================================================================
# III. Kolos-Wolniewicz PES (Cubic Hermite Spline)
# ============================================================================

# EQ:KW-PES — [KW1968] Table II, pp. 405-406
# Ground state (¹Σ_g⁺) of H₂, 100-term wavefunction
const _KW_R = [1.0, 1.2, 1.4, 1.5, 1.8, 2.0, 2.4, 3.0]
const _KW_E = [-1.12453881, -1.16493435, -1.17447498, -1.17285408,
               -1.15506752, -1.13813155, -1.10242011, -1.05731738]

# Pre-computed derivatives at each knot (finite differences)
const _KW_dE = let
    n = length(_KW_R)
    dE = Vector{Float64}(undef, n)
    # One-sided at boundaries
    dE[1] = (_KW_E[2] - _KW_E[1]) / (_KW_R[2] - _KW_R[1])
    dE[n] = (_KW_E[n] - _KW_E[n-1]) / (_KW_R[n] - _KW_R[n-1])
    # Centered for interior
    for i in 2:(n-1)
        dE[i] = (_KW_E[i+1] - _KW_E[i-1]) / (_KW_R[i+1] - _KW_R[i-1])
    end
    dE
end

"""
    kw_potential(R) → Float64

Kolos-Wolniewicz H₂ ground-state potential energy at separation R (a.u.).
Cubic Hermite spline interpolation of [KW1968] data.
Clamped at boundaries: returns edge values for R outside [1.0, 3.0].
"""
function kw_potential(R::Float64)
    # EQ:KW-PES — Kolos & Wolniewicz (1968) cubic Hermite interpolation
    R ≤ _KW_R[1] && return _KW_E[1]
    R ≥ _KW_R[end] && return _KW_E[end]

    # Find interval (linear scan, only 8 points)
    k = 1
    for i in 1:(length(_KW_R) - 1)
        if R < _KW_R[i+1]
            k = i
            break
        end
    end

    h = _KW_R[k+1] - _KW_R[k]
    s = (R - _KW_R[k]) / h

    # Cubic Hermite basis functions
    h00 = 2s^3 - 3s^2 + 1
    h10 = s^3 - 2s^2 + s
    h01 = -2s^3 + 3s^2
    h11 = s^3 - s^2

    h00 * _KW_E[k] + h10 * h * _KW_dE[k] + h01 * _KW_E[k+1] + h11 * h * _KW_dE[k+1]
end

"""
    kw_force(R) → Float64

Force F = -dV/dR from the Kolos-Wolniewicz PES at separation R.
Returns 0.0 outside the data range [1.0, 3.0] a.u.
"""
function kw_force(R::Float64)
    (R ≤ _KW_R[1] || R ≥ _KW_R[end]) && return 0.0

    k = 1
    for i in 1:(length(_KW_R) - 1)
        if R < _KW_R[i+1]
            k = i
            break
        end
    end

    h = _KW_R[k+1] - _KW_R[k]
    s = (R - _KW_R[k]) / h

    # Derivative of Hermite basis: dp/ds × ds/dR, where ds/dR = 1/h
    dh00 = 6s^2 - 6s
    dh10 = 3s^2 - 4s + 1
    dh01 = -6s^2 + 6s
    dh11 = 3s^2 - 2s

    dV = (dh00 * _KW_E[k] + dh10 * h * _KW_dE[k] +
          dh01 * _KW_E[k+1] + dh11 * h * _KW_dE[k+1]) / h

    return -dV  # F = -dV/dR
end

# ============================================================================
# IV. Nuclear Trajectory (Velocity-Verlet)
# ============================================================================

"""
    nuclear_trajectory(R0, V0, force_fn, mass, dt, nsteps) → (times, positions, velocities)

Integrate a 1D nuclear trajectory using the velocity-Verlet (symplectic) integrator.

- `R0` — initial separation
- `V0` — initial velocity
- `force_fn(R) → Float64` — force at separation R (e.g., `R -> morse_force(H2_MORSE, R)`)
- `mass` — reduced mass (918.076 a.u. for H₂, half proton mass)
- `dt` — time step
- `nsteps` — number of integration steps

Returns three vectors of length `nsteps + 1`.
"""
function nuclear_trajectory(R0::Float64, V0::Float64,
                            force_fn, mass::Float64,
                            dt::Float64, nsteps::Int)
    # Velocity-Verlet (symplectic, energy drift bounded O(dt²))
    times = Vector{Float64}(undef, nsteps + 1)
    positions = Vector{Float64}(undef, nsteps + 1)
    velocities = Vector{Float64}(undef, nsteps + 1)

    R = R0
    V = V0
    F = force_fn(R)

    times[1] = 0.0
    positions[1] = R
    velocities[1] = V

    for i in 1:nsteps
        # Half-step velocity
        V += 0.5 * dt * F / mass
        # Full-step position
        R += dt * V
        # New force
        F_new = force_fn(R)
        # Half-step velocity with new force
        V += 0.5 * dt * F_new / mass
        F = F_new

        times[i+1] = i * dt
        positions[i+1] = R
        velocities[i+1] = V
    end

    return (times, positions, velocities)
end

# ============================================================================
# V. Field Protocol Convenience Constructors
# ============================================================================

"""
    GaussianWavepacketField(p0, r0, d; m=1.0, t_range=(0.0, 100.0), dt=1.0, R_max=auto)

Create a time-evolving Gaussian wavepacket as a `TimeEvolution{ComplexScalarField3D}`.

Domain auto-sizes to contain the wavepacket at all times (center motion + spreading).

# Example
```julia
wp = GaussianWavepacketField((1.0, 0.0, 0.0), (0.0, 0.0, 0.0), 2.0;
                              m=1.0, t_range=(0.0, 50.0), dt=1.0)
visualize(wp; t=25.0, output="wavepacket_t25.ppm")
```
"""
function GaussianWavepacketField(p0::NTuple{3,Float64}, r0::NTuple{3,Float64}, d::Float64;
                                 m::Float64=1.0,
                                 t_range::Tuple{Float64,Float64}=(0.0, 100.0),
                                 dt::Float64=1.0,
                                 R_max::Float64=NaN)
    if isnan(R_max)
        v_g = sqrt(p0[1]^2 + p0[2]^2 + p0[3]^2) / m
        t_max = max(abs(t_range[1]), abs(t_range[2]))
        max_displacement = v_g * t_max
        max_width = wavepacket_width(t_max, d, m)
        R_max = max_displacement + 5.0 * max_width + maximum(abs.(r0))
    end
    TimeEvolution{ComplexScalarField3D}(
        t -> ComplexScalarField3D(
            (x, y, z) -> gaussian_wavepacket(x, y, z, t, p0, r0, d, m),
            BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
            d
        ),
        t_range,
        dt
    )
end

"""
    ScatteringField(positions, times, orbital_fn; R_max=auto)

Create a time-evolving molecular orbital field from a pre-computed nuclear trajectory.

At each time `t`, interpolates `R(t)` from the trajectory and evaluates
`orbital_fn(R, x, y, z)` (e.g., `h2_bonding`) as a `ComplexScalarField3D`.

# Example
```julia
ts, Rs, Vs = nuclear_trajectory(3.0, -0.001, R -> morse_force(H2_MORSE, R), 918.076, 1.0, 500)
field = ScatteringField(Rs, ts, h2_bonding)
visualize(field; t=250.0, output="h2_scatter.ppm")
```
"""
function ScatteringField(positions::Vector{Float64}, times::Vector{Float64},
                         orbital_fn;
                         R_max::Float64=NaN)
    if isnan(R_max)
        R_max = maximum(abs, positions) / 2.0 + 10.0
    end
    t_range = (times[1], times[end])
    dt_hint = length(times) > 1 ? times[2] - times[1] : 1.0

    TimeEvolution{ComplexScalarField3D}(
        t -> begin
            tc = clamp(t, times[1], times[end])
            idx = searchsortedlast(times, tc)
            idx = clamp(idx, 1, length(times) - 1)
            frac = (tc - times[idx]) / (times[idx+1] - times[idx])
            R = positions[idx] + frac * (positions[idx+1] - positions[idx])
            ComplexScalarField3D(
                (x, y, z) -> orbital_fn(R, x, y, z),
                BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
                1.0
            )
        end,
        t_range,
        dt_hint
    )
end
