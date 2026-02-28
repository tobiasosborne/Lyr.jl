# particle_animation.jl — Animated particle simulation rendered as level set surfaces
#
# Phase 1: Precompute all particle states (sequential — each frame depends on previous)
# Phase 2: Render all frames in parallel (embarrassingly parallel via Threads)
# Phase 3: Stitch to MP4 via ffmpeg
#
# Run: julia -t auto --project examples/particle_animation.jl

using PNGFiles
using Lyr
using Lyr: particles_to_sdf, sdf_to_fog, active_voxel_count,
           Camera, DirectionalLight, VolumeMaterial, VolumeEntry, Scene,
           build_nanogrid, render_volume_image, write_png,
           tf_blackbody

mkpath("showcase/particle_frames")

println("=" ^ 70)
println("  Lyr.jl Particle Animation Demo ($(Threads.nthreads()) threads)")
println("=" ^ 70)

# ============================================================================
# Particle physics
# ============================================================================

function init_particles(n::Int; spread=1.5, speed=12.0)
    golden = (1 + sqrt(5)) / 2
    positions = Vector{NTuple{3, Float64}}(undef, n)
    velocities = Vector{NTuple{3, Float64}}(undef, n)
    radii = Vector{Float64}(undef, n)
    for i in 1:n
        θ = 2π * i / golden
        φ = acos(1 - 2 * (i - 0.5) / n)
        r = spread * (0.5 + 0.5 * ((i % 7) / 6))
        x, y, z = r * sin(φ) * cos(θ), r * sin(φ) * sin(θ), r * cos(φ)
        nr = sqrt(x^2 + y^2 + z^2)
        s = speed * (0.7 + 0.3 * ((i % 5) / 4))
        positions[i] = (x, y, z)
        velocities[i] = nr > 0.1 ? (s * x / nr, s * y / nr, s * z / nr) : (0.0, 0.0, 0.0)
        radii[i] = 2.5 + 0.5 * ((i % 3) / 2)
    end
    positions, velocities, radii
end

function step!(pos, vel, dt; gravity=-15.0, drag=0.02)
    for i in eachindex(pos)
        x, y, z = pos[i]
        vx, vy, vz = vel[i]
        r = sqrt(x^2 + y^2 + z^2)
        if r > 0.1
            ax, ay, az = gravity * x / r, gravity * y / r, gravity * z / r
        else
            ax = ay = az = 0.0
        end
        vx = vx * (1 - drag) + ax * dt
        vy = vy * (1 - drag) + ay * dt
        vz = vz * (1 - drag) + az * dt
        pos[i] = (x + vx * dt, y + vy * dt, z + vz * dt)
        vel[i] = (vx, vy, vz)
    end
end

# ============================================================================
# Phase 1: Precompute all particle states (sequential)
# ============================================================================

n_particles = 30
n_frames = 90
dt = 0.04

println("\nPhase 1: Precomputing $n_frames frames of particle simulation...")
pos, vel, radii = init_particles(n_particles)

# Store snapshots of positions for each frame
all_positions = Vector{Vector{NTuple{3, Float64}}}(undef, n_frames)
for frame in 1:n_frames
    all_positions[frame] = copy(pos)
    step!(pos, vel, dt)
end
println("  Done. $(n_particles) particles × $(n_frames) frames")

# ============================================================================
# Phase 2: Render all frames in parallel
# ============================================================================

println("\nPhase 2: Rendering $n_frames frames on $(Threads.nthreads()) threads...")
t_start = time()
voxel_size = 0.8
cam_radius = 45.0
cam_height = 20.0
completed = Threads.Atomic{Int}(0)

Threads.@threads for frame in 1:n_frames
    positions = all_positions[frame]

    # Particles → SDF → fog
    sdf = particles_to_sdf(positions, radii; voxel_size=voxel_size, half_width=3.0)
    fog = sdf_to_fog(sdf)

    if active_voxel_count(fog.tree) > 0
        angle = 2π * (frame - 1) / n_frames
        cam = Camera((cam_radius * cos(angle), cam_radius * sin(angle), cam_height),
                     (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
        mat = VolumeMaterial(tf_blackbody(); sigma_scale=20.0, emission_scale=3.0)
        nano = build_nanogrid(fog.tree)
        lights = [DirectionalLight((1.0, 0.8, 0.6), (1.0, 1.0, 0.5)),
                  DirectionalLight((0.3, 0.4, 0.8), (-1.0, -0.5, 1.0))]
        scene = Scene(cam, lights, VolumeEntry(fog, nano, mat))
        img = render_volume_image(scene, 480, 360; spp=16)
        write_png("showcase/particle_frames/frame_$(lpad(frame, 4, '0')).png", img)
    end

    n = Threads.atomic_add!(completed, 1)
    (n + 1) % 15 == 0 && println("  $(n + 1)/$n_frames frames complete")
end

total = round(time() - t_start, digits=1)
println("  All $n_frames frames rendered in $(total)s ($(round(n_frames/total, digits=1)) fps)")

# ============================================================================
# Phase 3: Stitch to video
# ============================================================================

println("\nPhase 3: Stitching to MP4...")
run(`ffmpeg -y -loglevel warning -framerate 30
     -i showcase/particle_frames/frame_%04d.png
     -c:v libx264 -pix_fmt yuv420p -crf 20
     showcase/particle_explosion.mp4`)
println("  → showcase/particle_explosion.mp4")

rm("showcase/particle_frames"; recursive=true)

println("\n" * "=" ^ 70)
println("  Done! Watch: showcase/particle_explosion.mp4")
println("=" ^ 70)
