# filtering_morphology_demo.jl — Showcase of filtering, morphology, and level set ops
#
# Demonstrates: filter_mean, filter_gaussian, dilate, erode, sdf_to_fog,
# sdf_interior_mask, extract_isosurface_mask, level_set_area/volume,
# check_level_set, sample_quadratic.
#
# Run: julia --project examples/filtering_morphology_demo.jl

using PNGFiles
using Lyr
using Lyr: active_voxels, active_voxel_count, get_value, build_grid, coord, Coord,
           GRID_FOG_VOLUME, GRID_LEVEL_SET,
           create_level_set_sphere, create_level_set_box,
           csg_difference,
           sdf_to_fog, sdf_interior_mask, extract_isosurface_mask,
           level_set_area, level_set_volume, check_level_set,
           filter_mean, filter_gaussian,
           dilate, erode,
           sample_quadratic, QuadraticInterpolation,
           Camera, DirectionalLight, VolumeMaterial, VolumeEntry, Scene,
           build_nanogrid, render_volume_image, write_png,
           tf_blackbody, tf_cool_warm, tf_smoke, tf_viridis

mkpath("showcase")

println("=" ^ 70)
println("  Lyr.jl Filtering, Morphology & Level Set Ops Demo")
println("=" ^ 70)

# Shared render helper
function _render(grid, filename; cam_dist=50.0, tf=tf_viridis(),
                 sigma=20.0, emission=2.0, spp=32)
    nano = build_nanogrid(grid.tree)
    cam = Camera((cam_dist * 0.8, cam_dist * 0.6, cam_dist * 0.5),
                 (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
    mat = VolumeMaterial(tf; sigma_scale=sigma, emission_scale=emission)
    lights = [DirectionalLight((1.0, 0.8, 0.6), (1.0, 1.0, 0.5)),
              DirectionalLight((0.3, 0.4, 0.8), (-1.0, -0.5, 1.0))]
    scene = Scene(cam, lights, VolumeEntry(grid, nano, mat))
    img = render_volume_image(scene, 800, 600; spp=spp)
    write_png(filename, img)
    println("  → $filename")
end

# ============================================================================
# 1. Source: noisy sphere (CSG sculpture)
# ============================================================================
println("\n--- 1. Source: CSG Sculpture ---")
sphere = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                  voxel_size=1.0, half_width=3.0)
box = create_level_set_box(min_corner=(-4.0, -4.0, -15.0), max_corner=(4.0, 4.0, 15.0),
                            voxel_size=1.0, half_width=3.0)
sculpture = csg_difference(sphere, box)
println("  Sculpture: $(active_voxel_count(sculpture.tree)) voxels")

# Convert to fog for rendering
fog = sdf_to_fog(sculpture)
println("  Fog volume: $(active_voxel_count(fog.tree)) voxels")
_render(fog, "showcase/filt_source.png"; tf=tf_cool_warm(), sigma=20.0, emission=2.5)

# ============================================================================
# 2. Mean Filter — progressive smoothing
# ============================================================================
println("\n--- 2. Mean Filter (1, 3, 5 iterations) ---")
for iters in [1, 3, 5]
    smoothed = filter_mean(fog; iterations=iters)
    _render(smoothed, "showcase/filt_mean_$(iters).png";
            tf=tf_cool_warm(), sigma=20.0, emission=2.5)
end

# ============================================================================
# 3. Gaussian Filter — sigma comparison
# ============================================================================
println("\n--- 3. Gaussian Filter (σ=0.5, σ=1.0, σ=2.0) ---")
for s in [0.5f0, 1.0f0, 2.0f0]
    smoothed = filter_gaussian(fog; sigma=s, iterations=2)
    tag = replace(string(s), "." => "p")
    _render(smoothed, "showcase/filt_gauss_$(tag).png";
            tf=tf_viridis(), sigma=20.0, emission=2.5)
end

# ============================================================================
# 4. Morphological Operations — dilate & erode
# ============================================================================
println("\n--- 4. Morphology: dilate & erode ---")
dilated = dilate(sculpture; iterations=2)
eroded = erode(sculpture; iterations=2)
println("  Original:  $(active_voxel_count(sculpture.tree)) voxels")
println("  Dilated+2: $(active_voxel_count(dilated.tree)) voxels")
println("  Eroded-2:  $(active_voxel_count(eroded.tree)) voxels")

fog_dilated = sdf_to_fog(dilated)
fog_eroded = sdf_to_fog(eroded)
_render(fog_dilated, "showcase/filt_dilated.png";
        tf=tf_blackbody(), sigma=15.0, emission=2.0)
_render(fog_eroded, "showcase/filt_eroded.png";
        tf=tf_blackbody(), sigma=15.0, emission=2.0)

# ============================================================================
# 5. Level Set Operations
# ============================================================================
println("\n--- 5. Level Set Analysis ---")
diag = check_level_set(sphere)
println("  check_level_set(sphere): valid=$(diag.valid)")
println("    active=$(diag.active_count), interior=$(diag.interior_count), exterior=$(diag.exterior_count)")

area = level_set_area(sphere)
vol = level_set_volume(sphere)
println("  Surface area: $(round(area, digits=1)) (analytical 4πr² ≈ $(round(4π*100, digits=1)))")
println("  Narrow-band volume: $(round(vol, digits=1))")

# Isosurface mask — thin shell
iso = extract_isosurface_mask(sphere)
println("  Isosurface mask: $(active_voxel_count(iso.tree)) voxels (thin shell)")
_render(iso, "showcase/filt_isosurface.png";
        tf=tf_viridis(), sigma=40.0, emission=4.0)

# Interior mask
interior = sdf_interior_mask(sphere)
println("  Interior mask: $(active_voxel_count(interior.tree)) voxels")
_render(interior, "showcase/filt_interior.png";
        tf=tf_smoke(), sigma=15.0, emission=3.0)

# ============================================================================
# Summary
# ============================================================================
println("\n" * "=" ^ 70)
println("  Demo complete! Rendered images:")
println("    showcase/filt_source.png        — CSG sculpture (reference)")
println("    showcase/filt_mean_1/3/5.png    — mean filter iterations")
println("    showcase/filt_gauss_*.png       — Gaussian σ comparison")
println("    showcase/filt_dilated.png       — morphological dilation")
println("    showcase/filt_eroded.png        — morphological erosion")
println("    showcase/filt_isosurface.png    — isosurface mask (thin shell)")
println("    showcase/filt_interior.png      — interior mask")
println("=" ^ 70)
