#!/usr/bin/env julia
# Black hole flyby — single worker, renders frames ARGS[1]..ARGS[2]
# Usage: julia --project -t 16 scripts/bh_worker.jl 0 24

using Lyr
using Lyr.GR

const N_FRAMES = 100
const W, H = 512, 512
const OUTDIR = joinpath(@__DIR__, "..", "showcase", "mov4_blackhole")
mkpath(OUTDIR)

first_frame = parse(Int, ARGS[1])
last_frame = parse(Int, ARGS[2])
println("Worker: frames $first_frame..$last_frame ($(Threads.nthreads()) threads)")

M = 1.0
m = SchwarzschildKS(M)
thick = ThickDisk(4.0, 18.0, 0.15, 2.0)
vol = VolumetricMatter(m, thick, 4.0, 18.0)

for frame in first_frame:last_frame
    t0 = time()

    phi = 2pi * frame / N_FRAMES
    theta = pi/2 - 0.2 + 0.15 * sin(2pi * frame / N_FRAMES)
    r_cam = 25.0 + 5.0 * sin(4pi * frame / N_FRAMES)

    cam = static_camera(m, r_cam, theta, phi, 55.0, (W, H))
    config = GRRenderConfig(
        integrator=IntegratorConfig(step_size=-0.05, max_steps=15000, r_max=100.0, stepper=:rk4),
        use_redshift=true, use_threads=true, samples_per_pixel=1)

    pixels = gr_render_image(cam, config; volume=vol)
    write_ppm(joinpath(OUTDIR, "frame_$(lpad(frame, 4, '0')).ppm"), pixels)

    dt = round(time() - t0, digits=1)
    println("  frame $frame ($(dt)s)")
end
