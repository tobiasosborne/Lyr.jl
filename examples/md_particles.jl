# md_particles.jl — Molecular dynamics spring system via Field Protocol
#
# Demonstrates: ParticleField → visualize()
# Physics: Harmonic springs + velocity Verlet integration
#
# Usage: julia --project examples/md_particles.jl

using Lyr
using Random

# Simulation parameters
N_side = 8          # particles per side (N_side³ total)
spacing = 2.0       # initial lattice spacing
k_spring = 50.0     # spring constant
r0 = spacing        # rest length
cutoff = 3.5        # interaction cutoff
dt = 0.001          # time step
n_steps = 300       # integration steps
damping = 0.99      # velocity damping (thermostat proxy)

rng = Xoshiro(42)

# Initialize positions on a cubic lattice with small random perturbation
N = N_side^3
positions = Vector{SVec3d}(undef, N)
velocities = Vector{SVec3d}(undef, N)

let idx = 1
    for i in 0:N_side-1, j in 0:N_side-1, k in 0:N_side-1
        positions[idx] = SVec3d(
            i * spacing + 0.2 * (rand(rng) - 0.5),
            j * spacing + 0.2 * (rand(rng) - 0.5),
            k * spacing + 0.2 * (rand(rng) - 0.5)
        )
        velocities[idx] = SVec3d(0.0, 0.0, 0.0)
        idx += 1
    end
end

# Compute forces (harmonic pairwise springs)
function compute_forces!(forces, positions, N, k_spring, r0, cutoff)
    for i in 1:N
        forces[i] = SVec3d(0.0, 0.0, 0.0)
    end
    for i in 1:N, j in (i+1):N
        dx = positions[j] - positions[i]
        r = sqrt(dx[1]^2 + dx[2]^2 + dx[3]^2)
        r > cutoff && continue
        r < 1e-8 && continue
        F_mag = -k_spring * (r - r0) / r
        f = SVec3d(F_mag * dx[1], F_mag * dx[2], F_mag * dx[3])
        forces[i] -= f
        forces[j] += f
    end
end

# Velocity Verlet integration
forces = Vector{SVec3d}(undef, N)
compute_forces!(forces, positions, N, k_spring, r0, cutoff)

println("Running MD: $N particles, $n_steps steps...")
for step in 1:n_steps
    # Half-step velocity + full-step position
    for i in 1:N
        velocities[i] = (velocities[i] + forces[i] * (dt / 2)) * damping
        positions[i] = positions[i] + velocities[i] * dt
    end
    # Recompute forces
    compute_forces!(forces, positions, N, k_spring, r0, cutoff)
    # Half-step velocity
    for i in 1:N
        velocities[i] = velocities[i] + forces[i] * (dt / 2)
    end
end

# Visualize via Field Protocol
field = ParticleField(positions; velocities=velocities)

println("Rendering particle density...")
pixels = visualize(field;
    voxel_size=0.5,
    sigma=1.0,
    cutoff_sigma=3.0,
    transfer_function=tf_cool_warm(),
    sigma_scale=3.0,
    emission_scale=2.0,
    width=512, height=512,
    spp=4,
    denoise=true,
    output="md_particles.ppm"
)
println("Done → md_particles.ppm")
