#!/usr/bin/env julia
# kerr_blackhole_demo.jl — Showcase: Kerr (spinning) black hole with accretion disk
#
# Demonstrates gravitational lensing, Doppler beaming, and frame dragging
# for a rapidly spinning black hole (a/M = 0.95).
#
# Usage: julia --project --threads=64 examples/kerr_blackhole_demo.jl

using Lyr
using Lyr.GR

println("=" ^ 60)
println("  Kerr Black Hole Showcase")
println("  Spin a/M = 0.95, thin accretion disk + checkerboard sky")
println("  Threads: $(Threads.nthreads())")
println("=" ^ 60)

# ── High-spin Kerr black hole ──
M = 1.0
a = 0.95
kerr = Kerr(M, a)

println("\nBlack hole parameters:")
println("  Mass M = $M")
println("  Spin a = $a  (a/M = $(a/M))")
println("  Outer horizon r₊ = $(round(horizon_radius(kerr), digits=4))")
println("  Inner horizon r₋ = $(round(inner_horizon_radius(kerr), digits=4))")
println("  ISCO prograde  = $(round(isco_prograde(kerr), digits=4))")
println("  ISCO retrograde = $(round(isco_retrograde(kerr), digits=4))")

# ── Camera: inclined view (θ ≈ 75° from pole) ──
width, height = 1920, 1080
cam = static_camera(kerr, 30.0, 1.3, 0.0, 45.0, (width, height))
println("\nCamera: r=30M, θ=74.5°, FOV=45°, $(width)×$(height)")

# ── Accretion disk: from ISCO to 15M ──
r_isco = isco_prograde(kerr)
disk = ThinDisk(r_isco, 15.0)
println("Disk: r_in=$(round(r_isco, digits=3))M (ISCO) to r_out=15M")

# ── Checkerboard celestial sphere (shows lensing) ──
sky_tex = Matrix{NTuple{3, Float64}}(undef, 256, 512)
for j in 1:256, i in 1:512
    θ_s = π * (j - 0.5) / 256
    φ_s = 2π * (i - 0.5) / 512
    c = checkerboard_sphere(θ_s, φ_s; n_checks=18)
    sky_tex[j, i] = c
end
sky = CelestialSphere(sky_tex, 200.0)

# ── Render config: high quality ──
config = GRRenderConfig(
    integrator = IntegratorConfig(
        step_size = -0.15,
        max_steps = 8_000,
        h_tolerance = 1e-6,
        r_max = 250.0,
        renorm_interval = 50,
        stepper = :rk4
    ),
    background = (0.0, 0.0, 0.02),
    use_redshift = true,
    use_threads = true,
    samples_per_pixel = 4   # 2×2 supersampling
)

# ── Render ──
println("\nRendering with $(config.samples_per_pixel) spp, RK4 integrator...")
t0 = time()
img = gr_render_image(cam, config; disk=disk, sky=sky)
elapsed = time() - t0
println("  Done in $(round(elapsed, digits=1))s ($(round(width*height/elapsed/1000, digits=1))k pixels/s)")

# ── Statistics ──
black = count(px -> px[1] + px[2] + px[3] < 0.01, img)
disk_px = count(px -> px[1] > 0.1, img)
println("  Shadow pixels: $black ($(round(100*black/(width*height), digits=1))%)")
println("  Disk pixels: $disk_px")

# ── Save ──
outpath = joinpath(@__DIR__, "..", "showcase", "kerr_blackhole.ppm")
mkpath(dirname(outpath))
write_ppm(outpath, img)
println("\nSaved: $outpath")

# ── Also render a Schwarzschild comparison (no spin) ──
println("\n" * "=" ^ 60)
println("  Schwarzschild comparison (a=0)")
println("=" ^ 60)

schw = Schwarzschild(M)
cam_s = static_camera(schw, 30.0, 1.3, 0.0, 45.0, (width, height))
disk_s = ThinDisk(isco_radius(schw), 15.0)

config_s = GRRenderConfig(
    integrator = IntegratorConfig(
        step_size = -0.15,
        max_steps = 8_000,
        h_tolerance = 1e-6,
        r_max = 250.0,
        renorm_interval = 50,
        stepper = :rk4
    ),
    background = (0.0, 0.0, 0.02),
    use_redshift = true,
    use_threads = true,
    samples_per_pixel = 4
)

println("Rendering Schwarzschild (ISCO = $(isco_radius(schw))M)...")
t0 = time()
img_s = gr_render_image(cam_s, config_s; disk=disk_s, sky=sky)
elapsed = time() - t0
println("  Done in $(round(elapsed, digits=1))s")

outpath_s = joinpath(@__DIR__, "..", "showcase", "schwarzschild_blackhole.ppm")
write_ppm(outpath_s, img_s)
println("Saved: $outpath_s")

println("\n" * "=" ^ 60)
println("  Compare the two images:")
println("  - Kerr a=0.95: smaller shadow, asymmetric disk (Doppler)")
println("  - Schwarzschild: symmetric shadow & disk")
println("=" ^ 60)
