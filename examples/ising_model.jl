# ising_model.jl — 3D Ising model visualization
#
# Demonstrates: ScalarField3D (from discrete lattice data) → visualize()
# Physics: Metropolis Monte Carlo on a 3D cubic lattice
#
# Usage: julia --project examples/ising_model.jl

using Lyr
using Random

# Lattice parameters
L = 24           # lattice size (L³ spins)
beta = 0.30      # inverse temperature (T_c ≈ 1/0.2216 for 3D Ising)
n_sweeps = 200   # MC sweeps

println("Running $n_sweeps Metropolis MC sweeps on $(L)^3 lattice (β=$beta)...")

# Initialize random spin configuration
rng = Xoshiro(42)
spins = rand(rng, (-1, 1), L, L, L)

# Periodic boundary helper
@inline wrap(i, L) = mod1(i, L)

# Metropolis Monte Carlo
for sweep in 1:n_sweeps
    for k in 1:L, j in 1:L, i in 1:L
        # Sum of 6 nearest neighbors (periodic)
        nn_sum = spins[wrap(i+1,L), j, k] + spins[wrap(i-1,L), j, k] +
                 spins[i, wrap(j+1,L), k] + spins[i, wrap(j-1,L), k] +
                 spins[i, j, wrap(k+1,L)] + spins[i, j, wrap(k-1,L)]

        # Energy change if we flip spin[i,j,k]
        dE = 2 * spins[i,j,k] * nn_sum

        # Accept flip with Boltzmann probability
        if dE <= 0 || rand(rng) < exp(-beta * dE)
            spins[i,j,k] = -spins[i,j,k]
        end
    end
end

# Magnetization
m = abs(sum(spins)) / L^3
println("Magnetization |m| = $(round(m, digits=3))")

# Convert lattice to a scalar field
# Visualize only spin-up (+1) sites as density
function spin_field(x, y, z)
    i = clamp(round(Int, x) + 1, 1, L)
    j = clamp(round(Int, y) + 1, 1, L)
    k = clamp(round(Int, z) + 1, 1, L)
    spins[i, j, k] > 0 ? 1.0 : 0.0
end

field = ScalarField3D(
    spin_field,
    BoxDomain((0.0, 0.0, 0.0), (Float64(L-1), Float64(L-1), Float64(L-1))),
    1.0  # one lattice spacing
)

println("Rendering Ising configuration...")
pixels = visualize(field;
    voxel_size=1.0,  # one voxel per lattice site
    transfer_function=tf_cool_warm(),
    sigma_scale=1.5,
    emission_scale=3.0,
    width=512, height=512,
    spp=4,
    denoise=true,
    output="ising_model.ppm"
)
println("Done → ising_model.ppm")
