# scatter_scalar_qed.jl — Scalar QED tree-level scattering visualization
#
# Two charged scalar particles scatter via virtual photon exchange.
# Computed from the first-order Dyson series (time-dependent Born approximation).
# Electron density |psi|^2 and EM interaction energy E_1.E_2 are rendered as
# quantum expectation values of the perturbatively-evolved state.
#
# The virtual photon is NOT put in by hand — it emerges as enhanced EM energy
# density between the electrons during the interaction window.
#
# Usage: julia --project -t auto examples/scatter_scalar_qed.jl

using Lyr
using PNGFiles

println("=== Scalar QED Tree-Level Scattering ===")
println()

# ============================================================================
# Physics setup
# ============================================================================

# Two scalar "electrons" approaching in the x-z plane
# Offset in z gives a glancing collision (impact parameter)
p1 = (0.15, 0.0, 0.0)      # momentum: rightward (slower for longer interaction)
r1 = (-15.0, 0.0, 2.0)     # start: left, slightly above
d1 = 3.0                    # wavepacket width (a.u.)

p2 = (-0.15, 0.0, 0.0)     # momentum: leftward
r2 = (15.0, 0.0, -2.0)     # start: right, slightly below
d2 = 3.0

# Moderate coupling — must be small enough for first-order Born to converge
# (scattered wave << free wave). Physical alpha = 1/137; we enhance for visibility.
alpha = 0.05

println("Electron 1: p=$p1, r=$r1, d=$d1")
println("Electron 2: p=$p2, r=$r2, d=$d2")
println("Coupling: alpha=$alpha (enhanced for visibility)")
println()

# ============================================================================
# Compute scattering fields from Dyson series
# ============================================================================

e_field, em_field = ScalarQEDScattering(
    p1, r1, d1,
    p2, r2, d2;
    mass=1.0,
    alpha=alpha,
    N=64,
    L=30.0,
    t_range=(-80.0, 80.0),
    nsteps=120
)

println("Time range: $(e_field.t_range)")
println()

# ============================================================================
# Probability conservation check
# ============================================================================

# Check at three time points
grid_N = 64
grid_L = 30.0
dx = 2.0 * grid_L / grid_N
for t_frac in [0.0, 0.5, 1.0]
    t = e_field.t_range[1] + t_frac * (e_field.t_range[2] - e_field.t_range[1])
    f = e_field.eval_fn(t)
    # Sample on a coarse grid for quick integration
    prob = 0.0
    for iz in 1:grid_N, iy in 1:grid_N, ix in 1:grid_N
        x = -grid_L + (ix - 0.5) * dx
        y = -grid_L + (iy - 0.5) * dx
        z = -grid_L + (iz - 0.5) * dx
        prob += evaluate(f, x, y, z) * dx^3
    end
    println("  P(t=$(round(t, digits=1))) = $(round(prob, digits=4))")
end
println()

# ============================================================================
# Render animation
# ============================================================================

mat_electron = VolumeMaterial(tf_electron(); sigma_scale=12.0, emission_scale=8.0)
mat_photon   = VolumeMaterial(tf_photon(); sigma_scale=20.0, emission_scale=15.0)

# Fixed camera above the scattering plane
cam = FixedCamera((0.0, 50.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 50.0)

nframes = 80
println("Rendering $nframes frames (electron density + EM cross-energy)...")
render_animation(
    [e_field, em_field],
    [mat_electron, mat_photon],
    cam;
    t_range=e_field.t_range,
    nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/scalar_qed_frames",
    output="showcase/scatter_scalar_qed.mp4"
)

println()
println("Done — showcase/scatter_scalar_qed.mp4")
println("  Blue: electron density |psi_1|^2 + |psi_2|^2")
println("  Orange: EM interaction energy E_1.E_2 (virtual photon)")
