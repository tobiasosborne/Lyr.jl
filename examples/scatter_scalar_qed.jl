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
# Large separation so the full trajectory is visible
p1 = (0.1, 0.0, 0.0)       # momentum: rightward
r1 = (-80.0, 0.0, 10.0)    # start: far left, offset above
d1 = 8.0                    # wide wavepacket (visible at this scale)

p2 = (-0.1, 0.0, 0.0)      # momentum: leftward
r2 = (80.0, 0.0, -10.0)    # start: far right, offset below
d2 = 8.0

# Coupling for first-order Born. With 4*pi in Poisson, effective = 4*pi*alpha.
alpha = 0.01

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
    L=120.0,
    t_range=(-600.0, 600.0),
    nsteps=200
)

println("Time range: $(e_field.t_range)")
println()

# ============================================================================
# Probability conservation check
# ============================================================================

# Check at three time points
grid_N = 64
grid_L = 120.0
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

# Camera far above scattering plane — sees full trajectories of both electrons
# At y=500, FOV=30°, visible width ≈ 2*500*tan(15°) ≈ 268 a.u. — covers the L=120 box
cam = FixedCamera((0.0, 500.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 30.0)

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
