# hydrogen_orbital.jl — Hydrogen atom probability density via Field Protocol
#
# Demonstrates: HydrogenOrbitalField → visualize()
# Physics: Analytical hydrogen wavefunction ψ_nlm → |ψ|² probability density
#
# Usage: julia --project examples/hydrogen_orbital.jl

using Lyr

# Choose orbital: 3d_z² (n=3, l=2, m=0)
n, l, m = 3, 2, 0
label = "3d_z2"

field = HydrogenOrbitalField(n, l, m)

println("Rendering hydrogen $label orbital...")
pixels = visualize(field;
    transfer_function=tf_viridis(),
    sigma_scale=3.0,
    emission_scale=6.0,
    width=512, height=512,
    spp=4,
    background=(0.005, 0.005, 0.015),
    output="hydrogen_$(label).ppm"
)
println("Done → hydrogen_$(label).ppm")
