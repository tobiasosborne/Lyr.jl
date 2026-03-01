# multiscatter_demo.jl — Single-scatter vs multi-scatter comparison
#
# Renders the same optically thick fog sphere with:
#   1. Single-scatter (max_bounces=1)
#   2. Multi-scatter  (max_bounces=64, Russian roulette after bounce 3)
#
# Run: julia --project examples/multiscatter_demo.jl

using Lyr

println("=== Multi-scatter vs Single-scatter Volumetric Rendering ===\n")

# ---------- Build scene: optically thick fog sphere ----------
println("Building fog sphere (radius=10, high albedo=0.95)...")
t_build = @elapsed begin
    sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0)
    fog = sdf_to_fog(sdf)

    # Scale to moderate density
    fog_data = Dict{Coord, Float32}()
    for (c, v) in active_voxels(fog.tree)
        fog_data[c] = v * 0.7f0
    end
    grid = build_grid(fog_data, 0.0f0; name="cloud")
    nano = build_nanogrid(grid.tree)
end
println("  Built in $(round(t_build, digits=2))s")
println("  Active voxels: $(active_voxel_count(grid.tree))")

# Material: high albedo cloud with forward scattering
tf = tf_smoke()
mat = VolumeMaterial(tf;
    sigma_scale=8.0,
    emission_scale=1.0,
    scattering_albedo=0.95,
    phase_function=HenyeyGreensteinPhase(0.6))
vol = VolumeEntry(grid, nano, mat)

# Camera on -X side, light from +X (backlit cloud)
cam = Camera((-30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
light = DirectionalLight((1.0, 0.5, 0.2), (1.0, 1.0, 1.0))
scene = Scene(cam, light, vol; background=(0.02, 0.02, 0.05))

# ---------- Render: Single-scatter ----------
W, H, SPP = 200, 150, 16
println("\nRendering single-scatter ($(W)x$(H), $(SPP) spp)...")
t_single = @elapsed begin
    px_single = render_volume(scene, ReferencePathTracer(max_bounces=1, rr_start=1),
                              W, H; spp=SPP, seed=UInt64(42))
end
println("  Single-scatter: $(round(t_single, digits=2))s")

# ---------- Render: Multi-scatter ----------
println("Rendering multi-scatter ($(W)x$(H), $(SPP) spp, max_bounces=64)...")
t_multi = @elapsed begin
    px_multi = render_volume(scene, ReferencePathTracer(max_bounces=64, rr_start=3),
                             W, H; spp=SPP, seed=UInt64(42))
end
println("  Multi-scatter:  $(round(t_multi, digits=2))s")

# ---------- Brightness comparison ----------
function avg_brightness(pixels)
    h, w = size(pixels)
    total = 0.0
    for y in 1:h, x in 1:w
        r, g, b = pixels[y, x]
        total += (r + g + b) / 3.0
    end
    total / (h * w)
end

b_single = avg_brightness(px_single)
b_multi = avg_brightness(px_multi)
println("\n  Avg brightness — single: $(round(b_single, digits=4)), multi: $(round(b_multi, digits=4))")
println("  Multi/single ratio: $(round(b_multi / max(b_single, 1e-10), digits=2))x")

# ---------- Save outputs ----------
mkpath("showcase")
write_ppm("showcase/cloud_single_scatter.ppm", px_single)
write_ppm("showcase/cloud_multi_scatter.ppm", px_multi)
println("\nSaved: showcase/cloud_single_scatter.ppm")
println("Saved: showcase/cloud_multi_scatter.ppm")

# ---------- Also test EmissionAbsorption dispatch ----------
println("\nRendering emission-absorption preview via render_volume dispatch...")
t_preview = @elapsed begin
    px_preview = render_volume(scene, EmissionAbsorption(step_size=0.5, max_steps=2000), W, H)
end
println("  Preview: $(round(t_preview, digits=2))s")
write_ppm("showcase/cloud_emission_absorption.ppm", px_preview)
println("Saved: showcase/cloud_emission_absorption.ppm")

println("\nDone! Compare single vs multi scatter to see light diffusion through the cloud.")
