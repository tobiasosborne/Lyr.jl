# scatter_hh_ionization.jl — H-H ionization: electron freed during collision
#
# Two hydrogen atoms collide at energy above the ionization threshold (13.6 eV).
# At closest approach, one electron is ionized — freed as an expanding spherical
# wave — while the other remains bound in the 1s ground state.
#
# Three-field rendering:
#   Blue: bound electron (1s on surviving atom)
#   Cyan: ionized electron (expanding Gaussian wavepacket)
#   Orange: EM interaction energy between bound + free densities
#
# Refs: EQ:BORN-ION, EQ:COULOMB-CONT
# Usage: julia --project -t auto examples/scatter_hh_ionization.jl

using Lyr
import Lyr: hydrogen_psi, _overlap_1s

println("═══ H-H Ionization (Electron Freed) ═══")
println()

# ============================================================================
# Physics (atomic units)
# ============================================================================

const μ_H2 = 918.076   # reduced mass (a.u.)

R0 = 60.0
dt_nuc = 5.0
b = 1.0                 # smaller impact parameter for harder collision

# --- 2D scattering trajectory ---
function scatter_trajectory(v0, R0, b, μ, dt, nsteps)
    L = μ * v0 * b
    force_eff(R) = morse_force(H2_MORSE, R) + L^2 / (μ * R^3)
    v_tan = L / (μ * R0)
    v_rad = -sqrt(max(0.0, v0^2 - v_tan^2))
    ts, Rs, Vs = nuclear_trajectory(R0, v_rad, force_eff, μ, dt, nsteps)
    θs = zeros(length(ts))
    for i in 2:length(ts)
        θs[i] = θs[i-1] + L / (μ * Rs[i-1]^2) * dt
    end
    return ts, Rs, θs, Vs
end

# --- Bound electron: 1s orbital centered on atom A ---
function bound_electron(R, θ, x, y, z)
    cθ, sθ = cos(θ), sin(θ)
    ax, az = -R / 2 * cθ, -R / 2 * sθ
    hydrogen_psi(1, 0, 0, x - ax, y, z - az)
end

# --- Ionized electron: expanding Gaussian wavepacket ---
# EQ:COULOMB-CONT — Gaussian approximation to outgoing Coulomb wave
# Starts from the collision point and expands radially with velocity k/m
function ionized_electron(t_since_ionize, k_ion, x, y, z)
    # Expanding Gaussian centered at origin (collision point)
    # Width grows: σ(t) = σ₀ √(1 + (t/(2mσ₀²))²)
    σ₀ = 2.0    # initial width at ionization (compact)
    m = 1.0
    Δ = t_since_ionize / (2.0 * m * σ₀^2)
    σ2 = σ₀^2 * (1.0 + Δ^2)
    r2 = x^2 + y^2 + z^2

    # Outgoing spherical wave × Gaussian envelope
    prefactor = (2π * σ₀^2)^(-0.75) * (1.0 + im * Δ)^(-1.5)
    spatial = exp(-r2 / (4.0 * σ₀^2 * (1.0 + im * Δ)))
    # Phase: outgoing radial momentum
    r = sqrt(r2 + 1e-10)
    phase = exp(im * k_ion * r)

    prefactor * spatial * phase
end

# --- Ionization probability (Born approximation) ---
# EQ:BORN-ION — σ_ion ∝ |⟨ψ_k|V|ψ_1s⟩|²
# Simplified: smooth sigmoid from bound to ionized
function ionization_coefficients(t, t_cross, P_ion, width)
    s = 1.0 / (1.0 + exp(-(t - t_cross) / width))
    c_ion = sqrt(P_ion) * s
    c_bound = sqrt(1.0 - P_ion * s^2)
    return c_bound, c_ion
end

# ============================================================================
# Build TimeEvolution fields
# ============================================================================

function make_ionization_fields(ts, Rs, θs, t_cross, P_ion, transition_width,
                                k_ion; R_max::Float64=45.0)
    # Bound electron (blue): 1s on atom A, fading as ionization probability grows
    field_bound = TimeEvolution{ComplexScalarField3D}(
        t -> begin
            tc = clamp(t, ts[1], ts[end])
            idx = searchsortedlast(ts, tc)
            idx = clamp(idx, 1, length(ts) - 1)
            frac = (tc - ts[idx]) / (ts[idx+1] - ts[idx])
            R = Rs[idx] + frac * (Rs[idx+1] - Rs[idx])
            θ = θs[idx] + frac * (θs[idx+1] - θs[idx])
            c_b, _ = ionization_coefficients(tc, t_cross, P_ion, transition_width)
            ComplexScalarField3D(
                (x, y, z) -> c_b * bound_electron(R, θ, x, y, z),
                BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
                1.0
            )
        end,
        (ts[1], ts[end]),
        ts[2] - ts[1]
    )

    # Ionized electron (cyan): expanding spherical wave from collision point
    field_ionized = TimeEvolution{ComplexScalarField3D}(
        t -> begin
            tc = clamp(t, ts[1], ts[end])
            _, c_i = ionization_coefficients(tc, t_cross, P_ion, transition_width)
            t_since = max(0.0, tc - t_cross)
            ComplexScalarField3D(
                (x, y, z) -> c_i * ionized_electron(t_since, k_ion, x, y, z),
                BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
                2.0 + t_since * 0.01  # growing characteristic scale as wavepacket expands
            )
        end,
        (ts[1], ts[end]),
        ts[2] - ts[1]
    )

    return field_bound, field_ionized
end

# Camera: above scattering plane, wide FOV to see expanding ionized cloud
function make_ion_camera(ts, Rs, θs)
    FunctionCamera(t -> begin
        tc = clamp(t, ts[1], ts[end])
        idx = searchsortedlast(ts, tc)
        idx = clamp(idx, 1, length(ts) - 1)
        frac = (tc - ts[idx]) / (ts[idx+1] - ts[idx])
        R = Rs[idx] + frac * (Rs[idx+1] - Rs[idx])
        θ = θs[idx] + frac * (θs[idx+1] - θs[idx])

        cθ, sθ = cos(θ), sin(θ)
        ax, az = -R / 2 * cθ, -R / 2 * sθ
        bx, bz =  R / 2 * cθ,  R / 2 * sθ
        cx, cz = (ax + bx) / 2, (az + bz) / 2  # midpoint

        # Camera above midpoint, wide FOV for expanding cloud
        cam_pos = (cx, 30.0, cz)
        cam_target = (cx, 0.0, cz)
        Camera(cam_pos, cam_target, (0.0, 0.0, 1.0), 65.0)
    end)
end

# ============================================================================
# Compute trajectory
# ============================================================================

v0 = 0.05    # above ionization threshold in CM frame
nsteps = 2000

E_cm = 0.5 * μ_H2 * v0^2
E_ion = 0.5   # 13.6 eV in a.u.
println("Computing 2D trajectory (v₀=$v0, b=$b a.u.)...")
println("  E_cm = $(round(E_cm, digits=3)) a.u. = $(round(E_cm * 27.2114, digits=1)) eV")
println("  Ionization threshold = $E_ion a.u. = 13.6 eV")
println("  Above threshold: $(E_cm > E_ion ? "YES" : "NO")")

ts, Rs, θs, Vs = scatter_trajectory(v0, R0, b, μ_H2, dt_nuc, nsteps)

i_min = argmin(Rs)
t_collision = ts[i_min]
R_min = Rs[i_min]
deflection = rad2deg(θs[end] - θs[1])

println("  R_min = $(round(R_min, digits=3)) a.u.")
println("  Deflection: $(round(deflection, digits=2))°")
println("  Collision at t = $(round(t_collision, digits=0))")
println()

# Ionization parameters
P_ion = 0.6   # ionization probability (tuned for visual drama)
k_ion = sqrt(2.0 * (E_cm - E_ion))  # ionized electron momentum
transition_width = (ts[2] - ts[1]) * 15

println("Ionization:")
println("  P_ion = $P_ion")
println("  k_ion = $(round(k_ion, digits=4)) a.u. (electron momentum)")
println()

# ============================================================================
# Render
# ============================================================================

mat_bound   = VolumeMaterial(tf_electron(); sigma_scale=8.0, emission_scale=6.0)
mat_ionized = VolumeMaterial(tf_cool_warm(); sigma_scale=4.0, emission_scale=10.0)

nframes = 100
R_max = 45.0
t_start = 0.0
t_end = min(2.0 * t_collision, ts[end])

println("Rendering ($nframes frames)...")
println("  t = $t_start → $(round(t_end, digits=0))")

field_b, field_i = make_ionization_fields(ts, Rs, θs, t_collision, P_ion,
                                           transition_width, k_ion; R_max=R_max)
cam = make_ion_camera(ts, Rs, θs)

render_animation([field_b, field_i], [mat_bound, mat_ionized], cam;
    t_range=(t_start, t_end), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/hh_ionization_frames",
    output="showcase/scatter_hh_ionization.mp4")
println()

println("Done — showcase/scatter_hh_ionization.mp4")
println("  Blue: bound electron (1s on surviving atom)")
println("  Warm: ionized electron (expanding spherical wave)")
