# scatter_ee_coulomb.jl — Electron-electron Coulomb scattering visualization
#
# Two electron wavepackets approach with impact parameter b, scatter via
# Coulomb repulsion. Wavepacket centers follow classical Rutherford trajectories;
# each electron is a free-spreading Gaussian centered on its classical path.
#
# Two scenarios: large b (weak deflection) and small b (strong deflection).
# Multi-field rendering: electron 1 (blue) + electron 2 (cyan).
#
# Usage: julia --project -t auto examples/scatter_ee_coulomb.jl

using Lyr

println("═══ Electron-Electron Coulomb Scattering ═══")
println()

# ============================================================================
# Physics (atomic units: ℏ = m_e = e = a₀ = 1)
# ============================================================================

const m_e = 1.0       # electron mass (a.u.)
const m_red = 0.5     # reduced mass for equal-mass particles
const Z1Z2 = 1.0      # charge product (both -e, repulsive: +1 in effective potential)

# EQ:RUTHERFORD-DEFLECTION — Schwabl context Eq. (18.51b)
# θ = 2·arctan(Z₁Z₂/(2·E_cm·b))
function rutherford_angle(E_cm::Float64, b::Float64)
    2.0 * atan(Z1Z2 / (2.0 * E_cm * b))
end

# EQ:COULOMB-TRAJECTORY — Goldstein Ch. 3
# Effective radial potential: V_eff(R) = Z₁Z₂/R + L²/(2μR²)
# Radial force: F = Z₁Z₂/R² + L²/(μR³) (repulsive Coulomb + centrifugal)
function coulomb_trajectory(v0::Float64, R0::Float64, b::Float64,
                            μ::Float64, dt::Float64, nsteps::Int)
    L = μ * v0 * b   # angular momentum

    # Effective radial force (repulsive Coulomb + centrifugal barrier)
    force_eff(R) = Z1Z2 / R^2 + L^2 / (μ * R^3)

    # Initial radial velocity (inward)
    v_tan = L / (μ * R0)
    v_rad = -sqrt(max(0.0, v0^2 - v_tan^2))

    # Radial trajectory via velocity-Verlet
    ts, Rs, Vs = nuclear_trajectory(R0, v_rad, force_eff, μ, dt, nsteps)

    # Angular trajectory: dθ/dt = L/(μR²)
    θs = zeros(length(ts))
    for i in 2:length(ts)
        θs[i] = θs[i-1] + L / (μ * Rs[i-1]^2) * dt
    end

    # Radial velocities for momentum reconstruction
    return ts, Rs, θs, Vs
end

# Lab-frame position of electron (sign=+1 for electron 1, -1 for electron 2)
# relative to center of mass (at origin, stationary in CM frame)
function electron_position(R::Float64, θ::Float64, sign::Int)
    # Electron positions at ±R/2 from CM in scattering plane (x-z)
    x = sign * R / 2 * cos(θ)
    z = sign * R / 2 * sin(θ)
    return (x, 0.0, z)
end

# Lab-frame velocity of electron from radial + angular components
function electron_velocity(R::Float64, θ::Float64, V_rad::Float64,
                           L::Float64, μ::Float64, sign::Int)
    V_θ = L / (μ * R)  # tangential velocity (dθ/dt × R/2 for each electron)
    # Radial direction: along the line connecting the two electrons
    cθ, sθ = cos(θ), sin(θ)
    # Velocity components in lab frame
    vx = sign * (V_rad / 2 * cθ - V_θ / 2 * sθ)
    vz = sign * (V_rad / 2 * sθ + V_θ / 2 * cθ)
    return (vx, 0.0, vz)
end

# Build TimeEvolution field for one electron wavepacket on Coulomb trajectory
function make_electron_field(ts, Rs, θs, Vs, sign::Int, v0::Float64,
                             b::Float64, d::Float64; R_max::Float64=60.0)
    L = m_red * v0 * b

    TimeEvolution{ComplexScalarField3D}(
        t -> begin
            tc = clamp(t, ts[1], ts[end])
            idx = searchsortedlast(ts, tc)
            idx = clamp(idx, 1, length(ts) - 1)
            frac = (tc - ts[idx]) / (ts[idx+1] - ts[idx])

            R = Rs[idx] + frac * (Rs[idx+1] - Rs[idx])
            θ = θs[idx] + frac * (θs[idx+1] - θs[idx])
            Vr = Vs[idx] + frac * (Vs[idx+1] - Vs[idx])

            pos = electron_position(R, θ, sign)
            vel = electron_velocity(R, θ, Vr, L, m_red, sign)
            p0 = (m_e * vel[1], m_e * vel[2], m_e * vel[3])

            ComplexScalarField3D(
                (x, y, z) -> gaussian_wavepacket(x, y, z, tc, p0, pos, d, m_e),
                BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
                d
            )
        end,
        (ts[1], ts[end]),
        ts[2] - ts[1]
    )
end

# Transfer function for electron 2 (cyan-teal, distinct from blue tf_electron)
function tf_electron2()
    TransferFunction([
        ControlPoint(0.0, (0.0, 0.05, 0.1, 0.0)),
        ControlPoint(0.15, (0.0, 0.3, 0.5, 0.3)),
        ControlPoint(0.4, (0.1, 0.6, 0.8, 0.6)),
        ControlPoint(0.7, (0.3, 0.85, 1.0, 0.85)),
        ControlPoint(1.0, (0.7, 1.0, 1.0, 1.0)),
    ])
end

# Energy check: E = ½μv² + Z₁Z₂/R (should be constant)
function check_energy(ts, Rs, Vs, μ, label)
    E0 = 0.5 * μ * Vs[1]^2 + Z1Z2 / Rs[1]
    E_end = 0.5 * μ * Vs[end]^2 + Z1Z2 / Rs[end]
    drift = abs(E_end - E0) / abs(E0) * 100
    println("  [$label] E_initial = $(round(E0, digits=6)), E_final = $(round(E_end, digits=6)), drift = $(round(drift, digits=4))%")
end

# ============================================================================
# Scenario 1: Moderate deflection (b = 3)
# ============================================================================

# Parameters: v0 must be high enough that KE >> V(R0) at initial separation.
# E_cm = ½μv₀² should dominate over V(R0) = Z₁Z₂/R0.
# With v0=1.0: E_cm = 0.25 a.u., V(30) = 0.033 — KE is 7.5× potential. Good.

println("--- Scenario 1: Moderate deflection ---")
v0_mod = 1.0
b_mod = 3.0
R0 = 30.0
dt_ee = 0.2
nsteps = 800

# Asymptotic energy = total energy (KE at R→∞ where V→0)
E_total_mod = 0.5 * m_red * v0_mod^2 + Z1Z2 / R0
θ_ruth_mod = rad2deg(rutherford_angle(E_total_mod, b_mod))
println("  v₀ = $v0_mod a.u., b = $b_mod a.u.")
println("  E_total = $(round(E_total_mod, digits=4)) a.u. (KE=$(round(0.5*m_red*v0_mod^2,digits=4)) + V=$(round(Z1Z2/R0,digits=4)))")
println("  Rutherford angle (analytic): $(round(θ_ruth_mod, digits=2))°")

ts_mod, Rs_mod, θs_mod, Vs_mod = coulomb_trajectory(v0_mod, R0, b_mod, m_red, dt_ee, nsteps)
Δθ_mod = rad2deg(θs_mod[end] - θs_mod[1])
# Scattering angle Θ = π - Δθ (angular sweep of relative position vector)
Θ_mod = 180.0 - Δθ_mod
println("  Scattering angle (numerical): $(round(Θ_mod, digits=2))°  (Δθ = $(round(Δθ_mod, digits=2))°)")
println("  R_min = $(round(minimum(Rs_mod), digits=3)) a.u.")
check_energy(ts_mod, Rs_mod, Vs_mod, m_red, "moderate b")
println()

# ============================================================================
# Scenario 2: Strong deflection (b = 1)
# ============================================================================

println("--- Scenario 2: Strong deflection ---")
v0_str = 1.0
b_str = 1.0
dt_ee2 = 0.2
nsteps2 = 800

E_total_str = 0.5 * m_red * v0_str^2 + Z1Z2 / R0
θ_ruth_str = rad2deg(rutherford_angle(E_total_str, b_str))
println("  v₀ = $v0_str a.u., b = $b_str a.u.")
println("  E_total = $(round(E_total_str, digits=4)) a.u.")
println("  Rutherford angle (analytic): $(round(θ_ruth_str, digits=2))°")

ts_str, Rs_str, θs_str, Vs_str = coulomb_trajectory(v0_str, R0, b_str, m_red, dt_ee2, nsteps2)
Δθ_str = rad2deg(θs_str[end] - θs_str[1])
Θ_str = 180.0 - Δθ_str
println("  Scattering angle (numerical): $(round(Θ_str, digits=2))°  (Δθ = $(round(Δθ_str, digits=2))°)")
println("  R_min = $(round(minimum(Rs_str), digits=3)) a.u.")
check_energy(ts_str, Rs_str, Vs_str, m_red, "strong b")
println()

# ============================================================================
# Render
# ============================================================================

mat1 = VolumeMaterial(tf_electron(); sigma_scale=10.0, emission_scale=8.0)
mat2 = VolumeMaterial(tf_electron2(); sigma_scale=10.0, emission_scale=8.0)
nframes = 80
d_wp = 2.0  # wavepacket width (narrower for faster electrons)
R_max = 40.0

# Top-down camera viewing the scattering plane (x-z)
cam = FixedCamera((0.0, 40.0, 0.0), (0.0, 0.0, 0.0);
                  up=(0.0, 0.0, 1.0), fov=55.0)

# --- Moderate b ---
i_min_mod = argmin(Rs_mod)
t_col_mod = ts_mod[i_min_mod]
t_end_mod = min(2.0 * t_col_mod, ts_mod[end])

println("Rendering moderate deflection ($nframes frames)...")
field1_mod = make_electron_field(ts_mod, Rs_mod, θs_mod, Vs_mod, +1, v0_mod, b_mod, d_wp; R_max=R_max)
field2_mod = make_electron_field(ts_mod, Rs_mod, θs_mod, Vs_mod, -1, v0_mod, b_mod, d_wp; R_max=R_max)
render_animation([field1_mod, field2_mod], [mat1, mat2], cam;
    t_range=(0.0, t_end_mod), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/ee_moderate_frames",
    output="showcase/scatter_ee_moderate.mp4")
println()

# --- Strong b ---
i_min_str = argmin(Rs_str)
t_col_str = ts_str[i_min_str]
t_end_str = min(2.0 * t_col_str, ts_str[end])

println("Rendering strong deflection ($nframes frames)...")
field1_str = make_electron_field(ts_str, Rs_str, θs_str, Vs_str, +1, v0_str, b_str, d_wp; R_max=R_max)
field2_str = make_electron_field(ts_str, Rs_str, θs_str, Vs_str, -1, v0_str, b_str, d_wp; R_max=R_max)
render_animation([field1_str, field2_str], [mat1, mat2], cam;
    t_range=(0.0, t_end_str), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/ee_strong_frames",
    output="showcase/scatter_ee_strong.mp4")
println()

println("Done — showcase/scatter_ee_moderate.mp4, showcase/scatter_ee_strong.mp4")
