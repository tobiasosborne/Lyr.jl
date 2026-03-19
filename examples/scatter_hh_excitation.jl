# scatter_hh_excitation.jl — H-H inelastic scattering with electronic excitation
#
# Two hydrogen atoms collide at energy above the 1s→2p threshold (10.2 eV).
# At closest approach the electron undergoes a Landau-Zener transition from
# the ground-state bonding orbital (1sσ_g) to the excited 2pσ_u state.
#
# Two-field rendering: ground (blue) + excited (purple) — shows the transition
# as a color change from blue to purple during the collision.
#
# Usage: julia --project -t auto examples/scatter_hh_excitation.jl

using Lyr
import Lyr: hydrogen_psi, _overlap_1s

println("═══ H-H Inelastic Scattering (Electronic Excitation) ═══")
println()

# ============================================================================
# Physics (atomic units)
# ============================================================================

const μ_H2 = 918.076   # reduced mass of two protons (a.u.)

R0 = 60.0              # initial separation (a.u.)
dt_nuc = 5.0           # nuclear time step (a.u.)
b = 1.5                # impact parameter (a.u.)

# --- 2D scattering trajectory (same as elastic) ---

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

# --- Ground-state bonding orbital (1sσ_g) in 2D scattering geometry ---

function glancing_bonding(R, θ, x, y, z)
    cθ, sθ = cos(θ), sin(θ)
    ax, az = -R / 2 * cθ, -R / 2 * sθ
    bx, bz =  R / 2 * cθ,  R / 2 * sθ
    ψA = hydrogen_psi(1, 0, 0, x - ax, y, z - az)
    ψB = hydrogen_psi(1, 0, 0, x - bx, y, z - bz)
    S = _overlap_1s(R)
    (ψA + ψB) / sqrt(2.0 + 2.0 * S)
end

# --- Excited-state 2pσ_u orbital in 2D scattering geometry ---
# EQ:H2-EXCITED-2P-SIGMA — LCAO from 2p₀ orbitals
# Quantization axis aligned with bond axis → rotate eval coords so
# bond direction maps to z-axis before calling hydrogen_psi(2,1,0,...)

function glancing_excited(R, θ, x, y, z)
    cθ, sθ = cos(θ), sin(θ)
    ax, az = -R / 2 * cθ, -R / 2 * sθ
    bx, bz =  R / 2 * cθ,  R / 2 * sθ

    # Shift to atom A center, rotate bond axis → z-axis (rotation by -θ about y)
    dxa, dza = x - ax, z - az
    xrA =  cθ * dxa + sθ * dza
    yrA =  y
    zrA = -sθ * dxa + cθ * dza

    dxb, dzb = x - bx, z - bz
    xrB =  cθ * dxb + sθ * dzb
    yrB =  y
    zrB = -sθ * dxb + cθ * dzb

    ψA = hydrogen_psi(2, 1, 0, xrA, yrA, zrA)
    ψB = hydrogen_psi(2, 1, 0, xrB, yrB, zrB)

    # S₂ₚ ≈ 0 for R > 3 a.u. → normalize by √2
    (ψA - ψB) / sqrt(2.0)
end

# --- Landau-Zener transition probability ---
# EQ:LANDAU-ZENER — Zener (1932)
# P = exp(-2π V₁₂² / (|v_R| · |dΔE/dR|))

const V12 = 0.02           # coupling matrix element (a.u.) — tuned for visual clarity
const ΔE_inf = 0.375       # asymptotic energy gap E(2p)-E(1s) = 10.2 eV in a.u.

function landau_zener_prob(v_radial::Float64)
    # EQ:DIABATIC-CROSSING — gap slope approximated from Morse force at R_min
    # dΔE/dR ≈ |Morse force at R_min| (ground state pulls energy down at short R)
    # For simplicity, use a typical value at the avoided crossing
    dΔE_dR = 0.1  # a.u./a.u. (characteristic slope at crossing region)
    exp(-2π * V12^2 / (abs(v_radial) * dΔE_dR))
end

# --- Smooth excitation coefficients ---
# EQ:SUPERPOSITION-COHERENT — ψ = c_g·ψ_g + c_e·ψ_e, |c_g|² + |c_e|² = 1

function excitation_coefficients(t, t_cross, P_LZ, transition_width)
    # Smooth sigmoid transition centered at t_cross
    s = 1.0 / (1.0 + exp(-(t - t_cross) / transition_width))
    c_e = sqrt(P_LZ) * s
    c_g = sqrt(1.0 - P_LZ * s^2)
    return c_g, c_e
end

# --- Build two TimeEvolution fields (ground + excited) ---

function make_excitation_fields(ts, Rs, θs, t_cross, P_LZ, transition_width;
                                R_max::Float64=45.0)
    # Ground-state field (blue): amplitude c_g(t) × bonding orbital
    field_ground = TimeEvolution{ComplexScalarField3D}(
        t -> begin
            tc = clamp(t, ts[1], ts[end])
            idx = searchsortedlast(ts, tc)
            idx = clamp(idx, 1, length(ts) - 1)
            frac = (tc - ts[idx]) / (ts[idx+1] - ts[idx])
            R = Rs[idx] + frac * (Rs[idx+1] - Rs[idx])
            θ = θs[idx] + frac * (θs[idx+1] - θs[idx])
            c_g, _ = excitation_coefficients(tc, t_cross, P_LZ, transition_width)
            ComplexScalarField3D(
                (x, y, z) -> c_g * glancing_bonding(R, θ, x, y, z),
                BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
                1.0
            )
        end,
        (ts[1], ts[end]),
        ts[2] - ts[1]
    )

    # Excited-state field (purple): amplitude c_e(t) × 2pσ_u orbital
    field_excited = TimeEvolution{ComplexScalarField3D}(
        t -> begin
            tc = clamp(t, ts[1], ts[end])
            idx = searchsortedlast(ts, tc)
            idx = clamp(idx, 1, length(ts) - 1)
            frac = (tc - ts[idx]) / (ts[idx+1] - ts[idx])
            R = Rs[idx] + frac * (Rs[idx+1] - Rs[idx])
            θ = θs[idx] + frac * (θs[idx+1] - θs[idx])
            _, c_e = excitation_coefficients(tc, t_cross, P_LZ, transition_width)
            ComplexScalarField3D(
                (x, y, z) -> c_e * glancing_excited(R, θ, x, y, z),
                BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
                2.0  # 2p orbital has larger characteristic scale
            )
        end,
        (ts[1], ts[end]),
        ts[2] - ts[1]
    )

    return field_ground, field_excited
end

# Camera: near atom A looking at atom B (same as elastic, wider FOV for 2p)
function make_excitation_camera(ts, Rs, θs)
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

        cam_pos = (ax, 15.0, az + 3.0)
        cam_target = (bx, 0.0, bz)
        Camera(cam_pos, cam_target, (0.0, 1.0, 0.0), 60.0)
    end)
end

# ============================================================================
# Trajectory computation
# ============================================================================

v0 = 0.035   # above 10.2 eV threshold in CM frame
nsteps = 2500

println("Computing 2D trajectory (v₀=$v0, b=$b a.u.)...")
E_cm = 0.5 * μ_H2 * v0^2
println("  E_cm = $(round(E_cm, digits=4)) a.u. = $(round(E_cm * 27.2114, digits=2)) eV")
println("  Threshold = $(round(ΔE_inf, digits=4)) a.u. = 10.2 eV")
println("  Above threshold: $(E_cm > ΔE_inf ? "YES" : "NO")")

ts, Rs, θs, Vs = scatter_trajectory(v0, R0, b, μ_H2, dt_nuc, nsteps)

i_min = argmin(Rs)
R_min = Rs[i_min]
t_collision = ts[i_min]
v_rad_at_min = Vs[i_min]
deflection = rad2deg(θs[end] - θs[1])

println("  R_min = $(round(R_min, digits=3)) a.u.")
println("  Deflection angle: $(round(deflection, digits=2))°")
println("  v_radial at R_min: $(round(v_rad_at_min, digits=6)) a.u.")
println()

# Landau-Zener transition
P_LZ = landau_zener_prob(v0)  # use initial velocity as characteristic velocity
println("Landau-Zener transition:")
println("  V₁₂ = $V12 a.u., v₀ = $v0 a.u.")
println("  P_LZ = $(round(P_LZ, digits=4))")
println("  Ground state fraction after: $(round(1.0 - P_LZ, digits=4))")
println("  Excited state fraction after: $(round(P_LZ, digits=4))")
println()

# Verify probability conservation
transition_width = (ts[2] - ts[1]) * 20  # smooth over 20 time steps
let
    for t_check in [ts[1], t_collision, ts[end]]
        c_g, c_e = excitation_coefficients(t_check, t_collision, P_LZ, transition_width)
        norm = c_g^2 + c_e^2
        println("  |c_g|² + |c_e|² at t=$(round(t_check, digits=0)): $(round(norm, digits=8))")
    end
end
println()

# ============================================================================
# Render
# ============================================================================

mat_ground = VolumeMaterial(tf_electron(); sigma_scale=8.0, emission_scale=6.0)
mat_excited = VolumeMaterial(tf_excited(); sigma_scale=6.0, emission_scale=8.0)
nframes = 100
R_max = 45.0

t_start = 0.0
t_end = min(2.0 * t_collision, ts[end])

println("Rendering H-H excitation ($nframes frames)...")
println("  Time range: $t_start → $(round(t_end, digits=0)) a.u.")

field_g, field_e = make_excitation_fields(ts, Rs, θs, t_collision, P_LZ, transition_width; R_max=R_max)
cam = make_excitation_camera(ts, Rs, θs)

render_animation([field_g, field_e], [mat_ground, mat_excited], cam;
    t_range=(t_start, t_end), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/hh_excitation_frames",
    output="showcase/scatter_hh_excitation.mp4")
println()

println("Done — showcase/scatter_hh_excitation.mp4")
