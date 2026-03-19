# scatter_qed_moller.jl — Tree-level QED Møller scattering (e⁻e⁻ → e⁻e⁻)
#
# Two electrons scatter via virtual photon exchange at tree level.
# Computed from the first-order Dyson series with Fermi antisymmetrization.
#
# Key physics:
# - Electron density: ρ = |ψ₁|² + |ψ₂|² - 2Re(ψ₁*ψ₂)  (Fermi exchange, minus sign)
# - EM interaction energy: E₁·E₂ (virtual photon = Coulomb cross-energy)
# - NR limit of the full Møller amplitude (spinor structure → Coulomb + exchange)
#
# The virtual photon emerges as enhanced EM energy density between the electrons.
# The Fermi exchange suppresses the density where wavefunctions overlap (Pauli exclusion).
#
# Refs: EQ:MOLLER-AMP, EQ:TIME-DEP-BORN, EQ:EM-CROSS-ENERGY
# Usage: julia --project -t auto examples/scatter_qed_moller.jl

using Lyr
using PNGFiles

println("═══ QED Møller Scattering (e⁻e⁻ → e⁻e⁻) ═══")
println()

# ============================================================================
# Physics setup — two electrons, large separation, glancing collision
# ============================================================================

p1 = (0.1, 0.0, 0.0)        # momentum: rightward
r1 = (-80.0, 0.0, 10.0)     # start: far left, above scattering axis
d1 = 8.0                     # wavepacket width

p2 = (-0.1, 0.0, 0.0)       # momentum: leftward
r2 = (80.0, 0.0, -10.0)     # start: far right, below scattering axis
d2 = 8.0

# Coupling: effective = 4π × alpha ≈ 0.13 (physical α_FS = 1/137 ≈ 0.0073)
alpha = 0.01

println("Electron 1: p=$p1, r=$r1, σ=$d1")
println("Electron 2: p=$p2, r=$r2, σ=$d2")
println("Coupling: α=$alpha  (effective 4πα ≈ $(round(4π*alpha, digits=3)))")
println("Exchange: Fermi (−1) — Pauli exclusion active at overlap")
println()

# ============================================================================
# Compute from tree-level Dyson series (exchange_sign = -1 for fermions)
# ============================================================================

e_field, em_field = ScalarQEDScattering(
    p1, r1, d1,
    p2, r2, d2;
    mass=1.0,
    alpha=alpha,
    N=64,
    L=120.0,
    t_range=(-600.0, 600.0),
    nsteps=200,
    exchange_sign=-1  # FERMIONS: ρ = |ψ₁|² + |ψ₂|² - 2Re(ψ₁*ψ₂)
)

println("Time range: $(e_field.t_range)")
println()

# ============================================================================
# Render
# ============================================================================

mat_electron = VolumeMaterial(tf_electron(); sigma_scale=12.0, emission_scale=8.0)
mat_photon   = VolumeMaterial(tf_photon(); sigma_scale=20.0, emission_scale=15.0)

# Camera above scattering plane, sees full trajectories
cam = FixedCamera((0.0, 500.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 30.0)

nframes = 80
println("Rendering $nframes frames...")
render_animation(
    [e_field, em_field],
    [mat_electron, mat_photon],
    cam;
    t_range=e_field.t_range,
    nframes=nframes,
    width=256, height=256, spp=2,
    output_dir="showcase/moller_frames",
    output="showcase/scatter_qed_moller.mp4"
)

println()
println("Done — showcase/scatter_qed_moller.mp4")
println("  Blue: electron density (Fermi antisymmetrized)")
println("  Orange: EM interaction energy E₁·E₂ (virtual photon)")
