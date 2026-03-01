# multiscatter_demo.jl — Single-scatter vs multi-scatter comparison
#
# Renders the same optically thick fog sphere with:
#   1. Single-scatter (max_bounces=1)
#   2. Multi-scatter  (max_bounces=64, Russian roulette after bounce 3)
#
# Run: julia -t auto --project examples/multiscatter_demo.jl

using Lyr
using PNGFiles

println("=== Multi-scatter vs Single-scatter Volumetric Rendering ===")
println("  Threads: $(Threads.nthreads())\n")

# ---------- Build scene: optically thick fog sphere ----------
println("Building fog sphere (radius=10, high albedo=0.95)...")
t_build = @elapsed begin
    sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0)
    fog = sdf_to_fog(sdf)

    # Scale to moderate density
    fog_data = Dict{Coord, Float32}()
    for (c, v) in active_voxels(fog.tree)
        fog_data[c] = v * 0.8f0
    end
    grid = build_grid(fog_data, 0.0f0; name="cloud")
    nano = build_nanogrid(grid.tree)
end
println("  Built in $(round(t_build, digits=2))s  ($(active_voxel_count(grid.tree)) voxels)")

# Material: high albedo cloud with forward scattering, blackbody for warm glow
tf = tf_blackbody()
mat = VolumeMaterial(tf;
    sigma_scale=5.0,
    emission_scale=8.0,        # high — phase function divides by 4pi
    scattering_albedo=0.95,
    phase_function=HenyeyGreensteinPhase(0.6))
vol = VolumeEntry(grid, nano, mat)

# Camera on -X side, light from +X (backlit cloud) — strong light
cam = Camera((-30.0, 5.0, 5.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
light_main = DirectionalLight((1.0, 0.3, 0.2), (12.0, 10.0, 8.0))   # strong warm backlight
light_fill = DirectionalLight((-0.5, -0.8, 0.3), (2.0, 3.0, 4.0))   # cool fill
scene = Scene(cam, [light_main, light_fill], vol; background=(0.03, 0.04, 0.08))

# ---------- Render ----------
W, H, SPP = 800, 600, 32

println("\nRendering single-scatter ($(W)x$(H), $(SPP) spp)...")
t_single = @elapsed begin
    px_single = render_volume(scene, ReferencePathTracer(max_bounces=1, rr_start=1),
                              W, H; spp=SPP, seed=UInt64(42))
end
println("  Single-scatter: $(round(t_single, digits=1))s")

println("Rendering multi-scatter ($(W)x$(H), $(SPP) spp, max_bounces=64)...")
t_multi = @elapsed begin
    px_multi = render_volume(scene, ReferencePathTracer(max_bounces=64, rr_start=3),
                             W, H; spp=SPP, seed=UInt64(42))
end
println("  Multi-scatter:  $(round(t_multi, digits=1))s")

println("Rendering emission-absorption preview...")
t_preview = @elapsed begin
    px_preview = render_volume(scene, EmissionAbsorption(step_size=0.5, max_steps=2000), W, H)
end
println("  Preview: $(round(t_preview, digits=2))s")

# ---------- Brightness comparison ----------
function avg_brightness(pixels)
    total = 0.0
    for p in pixels
        r, g, b = p
        total += (r + g + b) / 3.0
    end
    total / length(pixels)
end

b_single = avg_brightness(px_single)
b_multi = avg_brightness(px_multi)
println("\n  Avg brightness — single: $(round(b_single, digits=4)), multi: $(round(b_multi, digits=4))")
if b_single > 1e-6
    println("  Multi/single ratio: $(round(b_multi / b_single, digits=2))x")
end

# ---------- Save outputs ----------
mkpath("showcase")
for (name, px) in [("cloud_single_scatter", px_single),
                    ("cloud_multi_scatter", px_multi),
                    ("cloud_emission_absorption", px_preview)]
    write_ppm("showcase/$name.ppm", px)
    write_png("showcase/$name.png", px)
    println("Saved: showcase/$name.{ppm,png}")
end

println("\nDone!")
