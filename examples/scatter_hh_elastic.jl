# scatter_hh_elastic.jl — H-H elastic scattering visualization
#
# Two hydrogen atoms scatter with a non-zero impact parameter (glancing collision).
# Nuclear trajectory: 2D scattering on Morse PES with centrifugal barrier.
# Electronic density: LCAO bonding orbital with atoms at R(t), θ(t).
# Camera: pinned on atom A, looking at atom B — swings during deflection.
#
# Usage: julia --project -t auto examples/scatter_hh_elastic.jl

using Lyr
using PNGFiles
import Lyr: hydrogen_psi, _overlap_1s

println("═══ H-H Elastic Scattering (Glancing) ═══")
println()

# ============================================================================
# Physics
# ============================================================================

const μ_H2 = 918.076   # reduced mass (half proton mass, a.u.)

R0 = 60.0              # initial separation (a.u.)
dt_nuc = 5.0           # nuclear time step
b = 1.5                # impact parameter (a.u.)

function scatter_trajectory(v0, R0, b, μ, dt, nsteps)
    # Angular momentum from impact parameter
    L = μ * v0 * b

    # Effective radial force: Morse + centrifugal L²/(μR³)
    force_eff(R) = morse_force(H2_MORSE, R) + L^2 / (μ * R^3)

    # Initial radial velocity (subtract tangential component)
    v_tan = L / (μ * R0)
    v_rad = -sqrt(max(0.0, v0^2 - v_tan^2))

    # Radial trajectory via velocity-Verlet
    ts, Rs, Vs = nuclear_trajectory(R0, v_rad, force_eff, μ, dt, nsteps)

    # Angular trajectory: dθ/dt = L/(μR²)
    θs = zeros(length(ts))
    for i in 2:length(ts)
        θs[i] = θs[i-1] + L / (μ * Rs[i-1]^2) * dt
    end

    return ts, Rs, θs
end

# Bonding orbital with atoms at arbitrary 2D positions (x-z plane)
function glancing_bonding(R, θ, x, y, z)
    # Atom positions in x-z scattering plane
    cθ, sθ = cos(θ), sin(θ)
    ax, az = -R / 2 * cθ, -R / 2 * sθ
    bx, bz =  R / 2 * cθ,  R / 2 * sθ

    ψA = hydrogen_psi(1, 0, 0, x - ax, y, z - az)
    ψB = hydrogen_psi(1, 0, 0, x - bx, y, z - bz)
    S = _overlap_1s(R)
    (ψA + ψB) / sqrt(2.0 + 2.0 * S)
end

# Build TimeEvolution from 2D trajectory
function make_glancing_field(ts, Rs, θs; R_max=40.0)
    TimeEvolution{ComplexScalarField3D}(
        t -> begin
            tc = clamp(t, ts[1], ts[end])
            idx = searchsortedlast(ts, tc)
            idx = clamp(idx, 1, length(ts) - 1)
            frac = (tc - ts[idx]) / (ts[idx+1] - ts[idx])
            R = Rs[idx] + frac * (Rs[idx+1] - Rs[idx])
            θ = θs[idx] + frac * (θs[idx+1] - θs[idx])
            ComplexScalarField3D(
                (x, y, z) -> glancing_bonding(R, θ, x, y, z),
                BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
                1.0
            )
        end,
        (ts[1], ts[end]),
        ts[2] - ts[1]
    )
end

# Camera: near atom A, looking at atom B, wide FOV to see both
function make_glancing_camera(ts, Rs, θs)
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

        # Camera above atom A, looking at atom B
        cam_pos = (ax, 12.0, az + 3.0)
        cam_target = (bx, 0.0, bz)
        Camera(cam_pos, cam_target, (0.0, 1.0, 0.0), 55.0)
    end)
end

# ============================================================================
# Low energy
# ============================================================================

v0_low = 0.006
nsteps = 2000

println("Computing 2D trajectory (low energy, b=$b a.u.)...")
ts_low, Rs_low, θs_low = scatter_trajectory(v0_low, R0, b, μ_H2, dt_nuc, nsteps)

# Find closest approach and make timing symmetric
i_min = argmin(Rs_low)
t_collision = ts_low[i_min]
t_half = t_collision  # time before collision
t_start = 0.0
t_end = min(2.0 * t_collision, ts_low[end])
deflection_low = rad2deg(θs_low[end] - θs_low[1])

println("  R_min = $(round(minimum(Rs_low), digits=3)) a.u.")
println("  Deflection angle: $(round(deflection_low, digits=2))°")
println("  Collision at t = $(round(t_collision, digits=0)) a.u.")
println("  Video: t = $t_start → $(round(t_end, digits=0)) (symmetric)")
println()

# ============================================================================
# Medium energy
# ============================================================================

v0_med = 0.010
println("Computing 2D trajectory (medium energy, b=$b a.u.)...")
ts_med, Rs_med, θs_med = scatter_trajectory(v0_med, R0, b, μ_H2, dt_nuc, nsteps)

i_min_med = argmin(Rs_med)
t_collision_med = ts_med[i_min_med]
t_end_med = min(2.0 * t_collision_med, ts_med[end])
deflection_med = rad2deg(θs_med[end] - θs_med[1])

println("  R_min = $(round(minimum(Rs_med), digits=3)) a.u.")
println("  Deflection angle: $(round(deflection_med, digits=2))°")
println("  Video: t = 0 → $(round(t_end_med, digits=0)) (symmetric)")
println()

# ============================================================================
# Render
# ============================================================================

mat = VolumeMaterial(tf_electron(); sigma_scale=8.0, emission_scale=6.0)
nframes = 80

println("Rendering low-energy glancing collision ($nframes frames)...")
field_low = make_glancing_field(ts_low, Rs_low, θs_low)
cam_low = make_glancing_camera(ts_low, Rs_low, θs_low)
render_animation(field_low, mat, cam_low;
    t_range=(t_start, t_end), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/hh_low_frames",
    output="showcase/scatter_hh_low.mp4")
println()

println("Rendering medium-energy glancing collision ($nframes frames)...")
field_med = make_glancing_field(ts_med, Rs_med, θs_med)
cam_med = make_glancing_camera(ts_med, Rs_med, θs_med)
render_animation(field_med, mat, cam_med;
    t_range=(0.0, t_end_med), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/hh_med_frames",
    output="showcase/scatter_hh_medium.mp4")
println()

println("Done — showcase/scatter_hh_low.mp4, showcase/scatter_hh_medium.mp4")
