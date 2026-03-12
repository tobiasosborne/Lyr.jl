#!/usr/bin/env julia
# kerr_blackhole_demo.jl — Showcase: Kerr (spinning) black hole with volumetric accretion disk
#
# Demonstrates gravitational lensing, Doppler beaming, and frame dragging
# for a rapidly spinning black hole (a/M = 0.95).
# Novikov-Thorne temperature + Planck spectrum via volumetric thick disk pipeline.
#
# Usage: julia --project --threads=64 examples/kerr_blackhole_demo.jl

# PNGFiles must be loaded before Lyr for PNG output support
try
    @eval using PNGFiles
    @info "PNGFiles loaded — PNG output enabled"
catch
    @warn "PNGFiles not available — will output PPM only"
end

using Lyr
using Lyr.GR

println("=" ^ 60)
println("  Kerr Black Hole Showcase — Volumetric Thick Disk")
println("  Spin a/M = 0.95, Novikov-Thorne + Planck spectrum")
println("  Threads: $(Threads.nthreads())")
println("=" ^ 60)

# ── High-spin Kerr black hole ──
M = 1.0
a = 0.95
kerr = Kerr(M, a)

println("\nBlack hole parameters:")
println("  Mass M = $M")
println("  Spin a = $a  (a/M = $(a/M))")
println("  Outer horizon r+ = $(round(horizon_radius(kerr), digits=4))")
println("  Inner horizon r- = $(round(inner_horizon_radius(kerr), digits=4))")
println("  ISCO prograde  = $(round(isco_prograde(kerr), digits=4))")
println("  ISCO retrograde = $(round(isco_retrograde(kerr), digits=4))")

# ── Camera: inclined view (θ ≈ 75° from pole) ──
width, height = 1920, 1080
cam = static_camera(kerr, 30.0, 1.3, 0.0, 45.0, (width, height))
println("\nCamera: r=30M, theta=74.5 deg, FOV=45 deg, $(width)x$(height)")

# ── Volumetric thick accretion disk with NT physics ──
r_isco = isco_prograde(kerr)
thick = ThickDisk(r_isco, 15.0, 0.15, 5.0)
vol = VolumetricMatter(kerr, thick, r_isco, 15.0, r_isco, 10000.0)
println("Volumetric disk: r_in=$(round(r_isco, digits=3))M to r_out=15M, h/r=0.15, T_inner=10000K")

# ── Render config: high quality, dark background ──
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
img = gr_render_image(cam, config; volume=vol)
elapsed = time() - t0
println("  Done in $(round(elapsed, digits=1))s ($(round(width*height/elapsed/1000, digits=1))k pixels/s)")

# ── Statistics ──
black = count(px -> px[1] + px[2] + px[3] < 0.01, img)
bright = count(px -> px[1] > 0.3, img)
println("  Shadow pixels: $black ($(round(100*black/(width*height), digits=1))%)")
println("  Bright disk pixels: $bright")

# ── Save ──
outpath_ppm = joinpath(@__DIR__, "..", "showcase", "kerr_blackhole.ppm")
mkpath(dirname(outpath_ppm))
write_ppm(outpath_ppm, img)
println("\nSaved: $outpath_ppm")

outpath_png = joinpath(@__DIR__, "..", "showcase", "kerr_blackhole.png")
try
    write_png(outpath_png, img)
    println("Saved: $outpath_png")
catch e
    println("PNG output skipped (PNGFiles not available)")
end

# ── Also render a Schwarzschild comparison (no spin) ──
println("\n" * "=" ^ 60)
println("  Schwarzschild comparison (a=0) — Volumetric Thick Disk")
println("=" ^ 60)

schw = Schwarzschild(M)
cam_s = static_camera(schw, 30.0, 1.3, 0.0, 45.0, (width, height))
r_isco_s = isco_radius(schw)
thick_s = ThickDisk(r_isco_s, 15.0, 0.15, 5.0)
vol_s = VolumetricMatter(schw, thick_s, r_isco_s, 15.0, r_isco_s, 10000.0)

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
img_s = gr_render_image(cam_s, config_s; volume=vol_s)
elapsed = time() - t0
println("  Done in $(round(elapsed, digits=1))s")

outpath_s_ppm = joinpath(@__DIR__, "..", "showcase", "schwarzschild_blackhole.ppm")
write_ppm(outpath_s_ppm, img_s)
println("Saved: $outpath_s_ppm")

outpath_s_png = joinpath(@__DIR__, "..", "showcase", "schwarzschild_blackhole.png")
try
    write_png(outpath_s_png, img_s)
    println("Saved: $outpath_s_png")
catch e
    println("PNG output skipped (PNGFiles not available)")
end

println("\n" * "=" ^ 60)
println("  Compare the two images:")
println("  - Kerr a=0.95: smaller shadow, asymmetric disk (Doppler beaming)")
println("  - Schwarzschild: symmetric shadow & disk")
println("  - Both: white-blue inner disk, orange-red outer disk (Planck spectrum)")
println("  - Volumetric thick disk with visible structure")
println("=" ^ 60)
