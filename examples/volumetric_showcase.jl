# volumetric_showcase.jl — Sculpted volumetric scene with multi-scatter
#
# Creates an interesting composition:
#   - A CSG-sculpted "orb" (sphere with spherical cavities carved out)
#   - A flat fog ground plane beneath it
#   - Dramatic backlit multi-scatter rendering
#
# Run: julia -t auto --project examples/volumetric_showcase.jl

using Lyr
using PNGFiles

println("=== Volumetric Showcase: Sculpted Orb on Fog Ground ===")
println("  Threads: $(Threads.nthreads())\n")

# ── 1. Build the sculpted orb via CSG ────────────────────────────────────

println("Building CSG sculpted orb...")
t_orb = @elapsed begin
    # Main sphere
    main_sphere = create_level_set_sphere(center=(0.0, 0.0, 8.0), radius=8.0)

    # Carve spherical cavities to reveal internal structure
    cavity1 = create_level_set_sphere(center=(6.0, 0.0, 10.0), radius=4.5)
    cavity2 = create_level_set_sphere(center=(-3.0, 5.0, 10.0), radius=4.0)
    cavity3 = create_level_set_sphere(center=(0.0, -5.0, 12.0), radius=3.5)
    cavity4 = create_level_set_sphere(center=(0.0, 0.0, 2.0), radius=4.0)

    # Boolean difference: main sphere minus cavities
    sculpted = csg_difference(main_sphere, cavity1)
    sculpted = csg_difference(sculpted, cavity2)
    sculpted = csg_difference(sculpted, cavity3)
    sculpted = csg_difference(sculpted, cavity4)

    orb_fog = sdf_to_fog(sculpted)
end
println("  Orb: $(active_voxel_count(orb_fog.tree)) voxels, $(round(t_orb, digits=2))s")

# ── 2. Build ground plane ────────────────────────────────────────────────

println("Building ground plane...")
t_ground = @elapsed begin
    ground_sdf = create_level_set_box(
        min_corner=(-25.0, -25.0, -2.0),
        max_corner=(25.0, 25.0, 0.0))
    ground_fog = sdf_to_fog(ground_sdf)
end
println("  Ground: $(active_voxel_count(ground_fog.tree)) voxels, $(round(t_ground, digits=2))s")

# ── 3. Build NanoGrids ───────────────────────────────────────────────────

println("Building NanoGrids...")
t_nano = @elapsed begin
    orb_nano = build_nanogrid(orb_fog.tree)
    ground_nano = build_nanogrid(ground_fog.tree)
end
println("  Built in $(round(t_nano, digits=2))s")

# ── 4. Materials ─────────────────────────────────────────────────────────

# Orb: warm emissive blackbody, high albedo for light diffusion
tf_orb = TransferFunction([
    ControlPoint(0.0,  (0.0, 0.0, 0.0, 0.0)),
    ControlPoint(0.1,  (1.0, 0.5, 0.2, 0.4)),
    ControlPoint(0.4,  (1.0, 0.7, 0.35, 0.7)),
    ControlPoint(0.7,  (1.0, 0.85, 0.6, 0.9)),
    ControlPoint(1.0,  (1.0, 0.95, 0.85, 1.0)),
])
mat_orb = VolumeMaterial(tf_orb;
    sigma_scale=6.0,
    emission_scale=10.0,         # strong — phase function divides by 4pi
    scattering_albedo=0.92,
    phase_function=HenyeyGreensteinPhase(0.5))

# Ground: cool-toned, dense, subtle
tf_ground = TransferFunction([
    ControlPoint(0.0,  (0.0, 0.0, 0.0, 0.0)),
    ControlPoint(0.2,  (0.3, 0.25, 0.4, 0.6)),
    ControlPoint(0.5,  (0.35, 0.3, 0.5, 0.8)),
    ControlPoint(1.0,  (0.4, 0.35, 0.55, 1.0)),
])
mat_ground = VolumeMaterial(tf_ground;
    sigma_scale=15.0,
    emission_scale=3.0,
    scattering_albedo=0.4,
    phase_function=IsotropicPhase())

vol_orb = VolumeEntry(orb_fog, orb_nano, mat_orb)
vol_ground = VolumeEntry(ground_fog, ground_nano, mat_ground)

# ── 5. Scene setup ───────────────────────────────────────────────────────

cam = Camera(
    (22.0, -18.0, 16.0),         # elevated 3/4 view
    (0.0, 0.0, 6.0),             # look at orb center
    (0.0, 0.0, 1.0),             # up
    45.0)

# Strong lights to overcome 1/(4pi) phase attenuation
light_back = DirectionalLight((-0.5, 0.3, 0.6), (15.0, 12.0, 8.0))   # warm from above/behind
light_fill = DirectionalLight((0.8, -0.6, 0.2), (3.0, 4.0, 6.0))     # cool fill from front-right
light_rim  = DirectionalLight((-0.3, -0.3, -0.1), (4.0, 3.0, 2.0))   # warm rim from below

bg = (0.03, 0.04, 0.07)

scene = Scene(cam, [light_back, light_fill, light_rim],
              [vol_orb, vol_ground]; background=bg)

# ── 6. Render ────────────────────────────────────────────────────────────

W, H = 800, 600
mkpath("showcase")

println("\nRendering multi-scatter ($(W)x$(H), 32 spp, max_bounces=48)...")
t_render = @elapsed begin
    px = render_volume(scene, ReferencePathTracer(max_bounces=48, rr_start=3),
                       W, H; spp=32, seed=UInt64(2026))
end
println("  Multi-scatter: $(round(t_render, digits=1))s")

println("Denoising (bilateral)...")
t_denoise = @elapsed begin
    px_clean = Lyr.denoise_bilateral(px; spatial_sigma=1.5, range_sigma=0.08)
end
println("  Denoised: $(round(t_denoise, digits=2))s")

write_ppm("showcase/sculpted_orb.ppm", px_clean)
write_png("showcase/sculpted_orb.png", px_clean)
println("Saved: showcase/sculpted_orb.{ppm,png}")

println("\nRendering emission-absorption preview...")
t_preview = @elapsed begin
    px_ea = render_volume(scene, EmissionAbsorption(step_size=0.5, max_steps=3000), W, H)
end
println("  Preview: $(round(t_preview, digits=2))s")
write_ppm("showcase/sculpted_orb_preview.ppm", px_ea)
write_png("showcase/sculpted_orb_preview.png", px_ea)
println("Saved: showcase/sculpted_orb_preview.{ppm,png}")

println("\nRendering single-scatter...")
t_ss = @elapsed begin
    px_ss = render_volume(scene, ReferencePathTracer(max_bounces=1, rr_start=1),
                          W, H; spp=32, seed=UInt64(2026))
end
px_ss_clean = Lyr.denoise_bilateral(px_ss; spatial_sigma=1.5, range_sigma=0.08)
println("  Single-scatter: $(round(t_ss, digits=1))s")
write_ppm("showcase/sculpted_orb_single.ppm", px_ss_clean)
write_png("showcase/sculpted_orb_single.png", px_ss_clean)
println("Saved: showcase/sculpted_orb_single.{ppm,png}")

# ── 7. Summary ───────────────────────────────────────────────────────────

function avg_brightness(pixels)
    total = 0.0
    for p in pixels
        total += (p[1] + p[2] + p[3]) / 3.0
    end
    total / length(pixels)
end

println("\n=== Results ===")
println("  Multi-scatter brightness:  $(round(avg_brightness(px), digits=4))")
println("  Single-scatter brightness: $(round(avg_brightness(px_ss), digits=4))")
println("  Preview brightness:        $(round(avg_brightness(px_ea), digits=4))")
println("\nDone! Check showcase/ for output images.")
