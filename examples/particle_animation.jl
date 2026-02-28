# particle_animation.jl — Animated particle explosion + gravitational collapse
#
# Architecture: renderer uses Threads.@threads across scanlines internally,
# so frames are rendered SEQUENTIALLY to avoid thread contention.
# SDF construction is fast (<0.1s/frame); rendering dominates (~10s/frame).
#
# Run: julia -t auto --project examples/particle_animation.jl

using PNGFiles
using Lyr
using Lyr: particles_to_sdf, sdf_to_fog, active_voxel_count,
           Camera, DirectionalLight, VolumeMaterial, VolumeEntry, Scene,
           build_nanogrid, render_volume_image, write_png, tf_blackbody

# Force unbuffered output so diagnostics appear in real time
flush(stdout)

mkpath("showcase/particle_frames")

println("=" ^ 70)
println("  Lyr.jl Particle Animation ($(Threads.nthreads()) threads)")
println("=" ^ 70)

# ============================================================================
# Particle physics
# ============================================================================

function init_particles(n::Int; spread=2.0, speed=30.0)
    golden = (1 + sqrt(5)) / 2
    pos = Vector{NTuple{3, Float64}}(undef, n)
    vel = Vector{NTuple{3, Float64}}(undef, n)
    radii = Vector{Float64}(undef, n)
    for i in 1:n
        θ = 2π * i / golden
        φ = acos(1 - 2 * (i - 0.5) / n)
        r = spread * (0.5 + 0.5 * ((i % 7) / 6))
        x, y, z = r * sin(φ) * cos(θ), r * sin(φ) * sin(θ), r * cos(φ)
        nr = sqrt(x^2 + y^2 + z^2)
        s = speed * (0.6 + 0.4 * ((i % 11) / 10))
        vel[i] = nr > 0.01 ? (s * x / nr, s * y / nr, s * z / nr) : (s, 0.0, 0.0)
        pos[i] = (x, y, z)
        radii[i] = 3.0 + 1.0 * ((i % 5) / 4)
    end
    pos, vel, radii
end

function step!(pos, vel, dt; gravity=-7.0, drag=0.008)
    for i in eachindex(pos)
        x, y, z = pos[i]
        vx, vy, vz = vel[i]
        r = sqrt(x^2 + y^2 + z^2)
        if r > 0.5
            g = gravity / r
            vx += g * x * dt; vy += g * y * dt; vz += g * z * dt
        end
        vx *= (1 - drag); vy *= (1 - drag); vz *= (1 - drag)
        pos[i] = (x + vx * dt, y + vy * dt, z + vz * dt)
        vel[i] = (vx, vy, vz)
    end
end

# ============================================================================
# Configuration
# ============================================================================

const N_PARTICLES = 8
const N_FRAMES    = 60
const DT          = 0.05
const VOXEL_SIZE  = 0.8
const WIDTH       = 320
const HEIGHT      = 240
const SPP         = 4
const CAM_DIST    = 50.0

# Fixed lights
const LIGHTS = [DirectionalLight((1.0, 0.9, 0.7), (2.0, 1.5, 1.0)),
                DirectionalLight((0.4, 0.5, 0.9), (-1.0, -1.0, 2.0)),
                DirectionalLight((0.6, 0.3, 0.2), (0.0, 1.0, -0.5))]

# ============================================================================
# Phase 1: Precompute particle trajectories
# ============================================================================

println("\n[Phase 1] Simulating $N_PARTICLES particles × $N_FRAMES frames...")
pos, vel, radii = init_particles(N_PARTICLES; spread=1.5, speed=12.0)
all_positions = Vector{Vector{NTuple{3, Float64}}}(undef, N_FRAMES)
for f in 1:N_FRAMES
    all_positions[f] = copy(pos)
    step!(pos, vel, DT)
end
max_r = maximum(sqrt(sum(p .^ 2)) for fp in all_positions for p in fp)
println("  Max radius: $(round(max_r, digits=1)) units")
println("  Done.\n")
flush(stdout)

# ============================================================================
# Phase 2: Render sequentially (renderer uses all threads per frame)
# ============================================================================

println("[Phase 2] Rendering $(WIDTH)×$(HEIGHT) spp=$(SPP) voxel=$(VOXEL_SIZE)")
println("  Renderer uses $(Threads.nthreads()) threads per frame (scanline parallel)")
println()
flush(stdout)

t_total = time()
let t_sdf_total = 0.0, t_render_total = 0.0

for frame in 1:N_FRAMES
    t_frame = time()
    positions = all_positions[frame]

    # SDF + fog
    t0 = time()
    sdf = particles_to_sdf(positions, radii; voxel_size=VOXEL_SIZE, half_width=3.0)
    fog = sdf_to_fog(sdf)
    n_voxels = active_voxel_count(fog.tree)
    t_sdf = time() - t0
    t_sdf_total += t_sdf

    if n_voxels > 0
        # Render
        t0 = time()
        angle = 2π * (frame - 1) / N_FRAMES * 0.4
        cam = Camera((CAM_DIST * cos(angle), CAM_DIST * sin(angle) * 0.5, CAM_DIST * 0.4),
                     (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 35.0)
        mat = VolumeMaterial(tf_blackbody(); sigma_scale=35.0, emission_scale=8.0)
        nano = build_nanogrid(fog.tree)
        scene = Scene(cam, LIGHTS, VolumeEntry(fog, nano, mat))
        img = render_volume_image(scene, WIDTH, HEIGHT; spp=SPP)
        write_png("showcase/particle_frames/frame_$(lpad(frame, 4, '0')).png", img)
        t_render = time() - t0
        t_render_total += t_render
    else
        t_render = 0.0
    end

    t_elapsed = time() - t_total
    fps = frame / t_elapsed
    eta = round((N_FRAMES - frame) / fps, digits=0)

    if frame <= 3 || frame % 10 == 0 || frame == N_FRAMES
        println("  $(lpad(frame,3))/$(N_FRAMES) | $(lpad(n_voxels,5)) vox | sdf $(lpad(round(t_sdf,digits=2),5))s | render $(lpad(round(t_render,digits=1),5))s | $(round(fps,digits=2)) fps | ETA $(Int(eta))s")
        flush(stdout)
    end
end

t_wall = round(time() - t_total, digits=1)
println("\n  Total: $(t_wall)s (sdf: $(round(t_sdf_total,digits=1))s, render: $(round(t_render_total,digits=1))s)")
end # let

# ============================================================================
# Phase 3: Stitch to MP4
# ============================================================================

println("\n[Phase 3] Stitching $(N_FRAMES) frames to MP4...")
run(`ffmpeg -y -loglevel warning -framerate 30
     -i showcase/particle_frames/frame_%04d.png
     -c:v libx264 -pix_fmt yuv420p -crf 18
     showcase/particle_explosion.mp4`)

fsize = round(filesize("showcase/particle_explosion.mp4") / 1024, digits=0)
println("  → showcase/particle_explosion.mp4 ($(fsize) KB, $(round(N_FRAMES/30, digits=1))s at 30fps)")

rm("showcase/particle_frames"; recursive=true)
println("\nDone!")
