# scatter_hh_elastic.jl — H-H elastic scattering visualization
#
# Two hydrogen atoms scatter elastically on the Morse potential energy surface.
# Nuclear trajectory via velocity-Verlet, electronic density via LCAO bonding orbital.
# Camera: pinned on atom A, always looking at atom B.
#
# Usage: julia --project examples/scatter_hh_elastic.jl

using Lyr
using PNGFiles

println("═══ H-H Elastic Scattering ═══")
println()

# ============================================================================
# Physics setup
# ============================================================================

const μ_H2 = 918.076   # reduced mass of H₂ (half proton mass, a.u.)

# Large initial separation — atoms start well-isolated
R0 = 60.0              # initial separation (a.u.), ~32 Å
dt_nuc = 5.0           # nuclear time step (a.u.)
nsteps = 2000          # enough steps for approach + bounce + separation

# --- Low energy: slow approach, reaches bonding region ---
V0_low = -0.006
println("Computing nuclear trajectory (low energy)...")
ts_low, Rs_low, Vs_low = nuclear_trajectory(
    R0, V0_low, R -> morse_force(H2_MORSE, R), μ_H2, dt_nuc, nsteps)

R_turn_low = minimum(Rs_low)
E_low = 0.5 * μ_H2 * V0_low^2 + morse_potential(H2_MORSE, R0)
println("  R₀ = $R0 a.u., v₀ = $V0_low a.u., E = $(round(E_low, digits=5)) a.u.")
println("  Turning point: R_min = $(round(R_turn_low, digits=3)) a.u.")
println()

# --- Medium energy: deeper penetration, orbital distortion visible ---
V0_med = -0.008
println("Computing nuclear trajectory (medium energy)...")
ts_med, Rs_med, Vs_med = nuclear_trajectory(
    R0, V0_med, R -> morse_force(H2_MORSE, R), μ_H2, dt_nuc, nsteps)

R_turn_med = minimum(Rs_med)
E_med = 0.5 * μ_H2 * V0_med^2 + morse_potential(H2_MORSE, R0)
println("  v₀ = $V0_med a.u., E = $(round(E_med, digits=5)) a.u.")
println("  Turning point: R_min = $(round(R_turn_med, digits=3)) a.u.")
println()

# ============================================================================
# Camera: pinned on atom A, looking at atom B
# ============================================================================

# Atoms are at (0, 0, +R/2) and (0, 0, -R/2) in ScatteringField convention.
# Camera sits slightly above/beside atom A, always aiming at atom B.
function make_atom_camera(positions, times)
    FunctionCamera(t -> begin
        # Interpolate R(t)
        tc = clamp(t, times[1], times[end])
        idx = searchsortedlast(times, tc)
        idx = clamp(idx, 1, length(times) - 1)
        frac = (tc - times[idx]) / (times[idx+1] - times[idx])
        R = positions[idx] + frac * (positions[idx+1] - positions[idx])

        atom_a = (0.0, 0.0, R / 2)
        atom_b = (0.0, 0.0, -R / 2)

        # Camera offset from atom A: slightly above and to the side
        cam_pos = (3.0, 2.0, R / 2 + 2.0)
        Camera(cam_pos, atom_b, (0.0, 1.0, 0.0), 50.0)
    end)
end

# ============================================================================
# Rendering
# ============================================================================

mat = VolumeMaterial(tf_electron(); sigma_scale=8.0, emission_scale=6.0)
nframes = 80

# Low energy
println("Creating ScatteringField (low energy)...")
field_low = ScatteringField(Rs_low, ts_low, h2_bonding; R_max=R0 / 2 + 10.0)
cam_low = make_atom_camera(Rs_low, ts_low)
t_end_low = ts_low[end]

println("Rendering low-energy scattering ($nframes frames, 256×256)...")
render_animation(field_low, mat, cam_low;
    t_range=(0.0, t_end_low), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/hh_low_frames",
    output="showcase/scatter_hh_low.mp4")
println()

# Medium energy
println("Creating ScatteringField (medium energy)...")
field_med = ScatteringField(Rs_med, ts_med, h2_bonding; R_max=R0 / 2 + 10.0)
cam_med = make_atom_camera(Rs_med, ts_med)
t_end_med = ts_med[end]

println("Rendering medium-energy scattering ($nframes frames, 256×256)...")
render_animation(field_med, mat, cam_med;
    t_range=(0.0, t_end_med), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/hh_med_frames",
    output="showcase/scatter_hh_medium.mp4")
println()

# ============================================================================
# Validation
# ============================================================================

println("Validation:")
Elows = [0.5 * μ_H2 * Vs_low[i]^2 + morse_potential(H2_MORSE, Rs_low[i]) for i in eachindex(ts_low)]
println("  Energy conservation (low):  ΔE = $(round(maximum(Elows) - minimum(Elows), sigdigits=3)) a.u.")

ψ_far = abs2(h2_bonding(R0, 0.0, 0.0, 0.0))
ψ_close = abs2(h2_bonding(R_turn_low, 0.0, 0.0, 0.0))
println("  |ψ|² midpoint at R=$R0: $(round(ψ_far, sigdigits=3)) (should be ~0)")
println("  |ψ|² midpoint at R=$(round(R_turn_low, digits=2)): $(round(ψ_close, sigdigits=3)) (bonding)")
println()
println("Done.")
