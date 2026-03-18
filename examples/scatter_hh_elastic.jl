# scatter_hh_elastic.jl — H-H elastic scattering visualization
#
# Two hydrogen atoms scatter elastically on the Morse potential energy surface.
# Nuclear trajectory via velocity-Verlet, electronic density via LCAO bonding orbital.
# Demonstrates: nuclear_trajectory + ScatteringField + render_animation
#
# Usage: julia --project examples/scatter_hh_elastic.jl

using Lyr
using PNGFiles  # for PNG output

println("═══ H-H Elastic Scattering ═══")
println()

# ============================================================================
# Physics setup
# ============================================================================

# Reduced mass of H₂ (half proton mass in atomic units)
const μ_H2 = 918.076

# --- Low energy regime ---
# Atoms approach slowly, bounce off repulsive wall with minimal orbital distortion
R0_low = 6.0          # initial separation (a.u.)
V0_low = -0.002       # inward velocity (a.u.)
dt_nuc = 5.0          # nuclear time step (a.u.)
nsteps = 600          # integration steps → total time = 3000 a.u. ≈ 73 fs

println("Computing nuclear trajectory (low energy)...")
ts_low, Rs_low, Vs_low = nuclear_trajectory(
    R0_low, V0_low,
    R -> morse_force(H2_MORSE, R), μ_H2,
    dt_nuc, nsteps
)

# Find classical turning point
R_turn_low = minimum(Rs_low)
E_total_low = 0.5 * μ_H2 * V0_low^2 + morse_potential(H2_MORSE, R0_low)
println("  R₀ = $(R0_low) a.u., v₀ = $(V0_low) a.u.")
println("  E_total = $(round(E_total_low, digits=5)) a.u.")
println("  Classical turning point: R_min = $(round(R_turn_low, digits=3)) a.u.")
println("  Re (equilibrium) = $(H2_MORSE.Re) a.u.")
println()

# --- Medium energy regime ---
V0_med = -0.008       # faster approach
println("Computing nuclear trajectory (medium energy)...")
ts_med, Rs_med, Vs_med = nuclear_trajectory(
    R0_low, V0_med,
    R -> morse_force(H2_MORSE, R), μ_H2,
    dt_nuc, nsteps
)
R_turn_med = minimum(Rs_med)
E_total_med = 0.5 * μ_H2 * V0_med^2 + morse_potential(H2_MORSE, R0_low)
println("  v₀ = $(V0_med) a.u.")
println("  E_total = $(round(E_total_med, digits=5)) a.u.")
println("  Classical turning point: R_min = $(round(R_turn_med, digits=3)) a.u.")
println()

# Validation: energy conservation
E_low = [0.5 * μ_H2 * Vs_low[i]^2 + morse_potential(H2_MORSE, Rs_low[i]) for i in eachindex(ts_low)]
E_drift_low = maximum(E_low) - minimum(E_low)
println("Energy conservation (low):    ΔE = $(round(E_drift_low, sigdigits=3)) a.u.")

E_med = [0.5 * μ_H2 * Vs_med[i]^2 + morse_potential(H2_MORSE, Rs_med[i]) for i in eachindex(ts_med)]
E_drift_med = maximum(E_med) - minimum(E_med)
println("Energy conservation (medium): ΔE = $(round(E_drift_med, sigdigits=3)) a.u.")
println()

# ============================================================================
# Rendering: Low energy scattering
# ============================================================================

println("Creating ScatteringField (low energy)...")
field_low = ScatteringField(Rs_low, ts_low, h2_bonding; R_max=12.0)

# Material: blue-white electron density
mat = VolumeMaterial(tf_electron(); sigma_scale=8.0, emission_scale=6.0)

# Camera: orbit around the scattering center
cam = OrbitCamera((0.0, 0.0, 0.0), 25.0;
                  elevation=25.0, fov=40.0, revolutions=0.3)

nframes = 60
t_end = ts_low[end]

println("Rendering low-energy scattering ($nframes frames, 256×256)...")
render_animation(field_low, mat, cam;
    t_range=(0.0, t_end), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/hh_low_frames",
    output="showcase/scatter_hh_low.mp4")
println()

# ============================================================================
# Rendering: Medium energy scattering
# ============================================================================

println("Creating ScatteringField (medium energy)...")
field_med = ScatteringField(Rs_med, ts_med, h2_bonding; R_max=12.0)

println("Rendering medium-energy scattering ($nframes frames, 256×256)...")
render_animation(field_med, mat, cam;
    t_range=(0.0, t_end), nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/hh_med_frames",
    output="showcase/scatter_hh_medium.mp4")
println()

# ============================================================================
# Validation: wavefunction shape at large R
# ============================================================================

println("Validation: wavefunction shape at endpoints")
# At large R, bonding orbital ≈ two separate 1s atoms
R_large = Rs_low[1]  # initial separation
ψ_center = abs2(h2_bonding(R_large, 0.0, 0.0, R_large / 2))  # near nucleus A
ψ_mid = abs2(h2_bonding(R_large, 0.0, 0.0, 0.0))             # midpoint
println("  R=$(round(R_large, digits=1)): |ψ|² at nucleus = $(round(ψ_center, sigdigits=4)), " *
        "at midpoint = $(round(ψ_mid, sigdigits=4))")
println("  (midpoint density should be negligible at large R)")

R_close = R_turn_low
ψ_center_close = abs2(h2_bonding(R_close, 0.0, 0.0, R_close / 2))
ψ_mid_close = abs2(h2_bonding(R_close, 0.0, 0.0, 0.0))
println("  R=$(round(R_close, digits=3)): |ψ|² at nucleus = $(round(ψ_center_close, sigdigits=4)), " *
        "at midpoint = $(round(ψ_mid_close, sigdigits=4))")
println("  (midpoint density should be significant when bonding)")
println()
println("Done.")
