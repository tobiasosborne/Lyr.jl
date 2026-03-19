# scatter_scalar_qed.jl — Scalar QED tree-level scattering visualization
#
# Two charged scalar particles scatter via virtual photon exchange.
# Computed from the first-order Dyson series (time-dependent Born approximation).
#
# The virtual photon emerges as enhanced EM energy density (E₁·E₂ cross-term)
# between the electrons during the interaction window.
#
# Zooming camera: starts wide (full trajectory), zooms in at collision (virtual
# photon visible), zooms back out.
#
# Usage: julia --project -t auto examples/scatter_scalar_qed.jl

using Lyr

println("=== Scalar QED Tree-Level Scattering ===")
println()

# ============================================================================
# Physics setup
# ============================================================================

# Two scalar electrons in the x-z plane, offset for glancing collision
p1 = (0.1, 0.0, 0.0)
r1 = (-80.0, 0.0, 8.0)
d1 = 6.0

p2 = (-0.1, 0.0, 0.0)
r2 = (80.0, 0.0, -8.0)
d2 = 6.0

alpha = 0.01  # effective coupling = 4π × 0.01 ≈ 0.13

println("Electron 1: p=$p1, r=$r1, σ=$d1")
println("Electron 2: p=$p2, r=$r2, σ=$d2")
println("Coupling: α=$alpha (4πα ≈ $(round(4π*alpha, digits=3)))")
println()

# ============================================================================
# Compute scattering from Dyson series — N=128 for proper resolution
# ============================================================================

e_field, em_field = ScalarQEDScattering(
    p1, r1, d1,
    p2, r2, d2;
    mass=1.0,
    alpha=alpha,
    N=128,
    L=120.0,
    t_range=(-600.0, 600.0),
    nsteps=200
)

println("Time range: $(e_field.t_range)")
println()

# ============================================================================
# Render with zooming camera
# ============================================================================

mat_electron = VolumeMaterial(tf_electron(); sigma_scale=15.0, emission_scale=10.0)
mat_photon   = VolumeMaterial(tf_photon(); sigma_scale=40.0, emission_scale=30.0)

# Zooming camera: wide → close at collision → wide
# Smooth zoom via cosine interpolation
cam = FunctionCamera(t -> begin
    t_range = (-600.0, 600.0)
    # Normalized time: 0 at start, 1 at end
    s = (t - t_range[1]) / (t_range[2] - t_range[1])

    # Zoom profile: cos² peak at s=0.5 (collision time)
    # zoom = 0 at edges (far), 1 at center (close)
    zoom = cos(π * (s - 0.5))^2

    # Camera height: 500 (wide) → 80 (close) → 500 (wide)
    y = 500.0 - 420.0 * zoom

    # FOV: 30° (wide) → 55° (close, to see both electrons at close range)
    fov = 30.0 + 25.0 * zoom

    Camera((0.0, y, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), fov)
end)

nframes = 120
println("Rendering $nframes frames (128³ grid, zooming camera)...")
render_animation(
    [e_field, em_field],
    [mat_electron, mat_photon],
    cam;
    t_range=e_field.t_range,
    nframes=nframes,
    width=512, height=512, spp=4,
    output_dir="showcase/scalar_qed_frames",
    output="showcase/scatter_scalar_qed.mp4"
)

println()
println("Done — showcase/scatter_scalar_qed.mp4")
println("  Blue: electron density |ψ₁|² + |ψ₂|²")
println("  Orange: EM interaction energy E₁·E₂ (virtual photon)")
