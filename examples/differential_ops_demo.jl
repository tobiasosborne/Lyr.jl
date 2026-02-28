# differential_ops_demo.jl — Showcase of stencil-based differential operators
#
# Demonstrates: GradStencil, BoxStencil, gradient_grid, laplacian, divergence,
# curl_grid, magnitude_grid, normalize_grid. Each operator produces a rendered
# image saved to showcase/.
#
# Run: julia --project examples/differential_ops_demo.jl

using PNGFiles  # must be loaded before Lyr for write_png support
using Lyr
using Lyr: active_voxels, active_voxel_count, get_value, build_grid, coord, Coord,
           GRID_FOG_VOLUME,
           create_level_set_sphere,
           GradStencil, BoxStencil, move_to!, center_value,
           gradient_grid, laplacian, divergence, curl_grid,
           magnitude_grid, normalize_grid,
           Camera, DirectionalLight, VolumeMaterial, VolumeEntry, Scene,
           build_nanogrid, render_volume_image, write_ppm, write_png,
           tf_blackbody, tf_cool_warm, tf_smoke, tf_viridis

using LinearAlgebra: norm

# Output directory
mkpath("showcase")

println("=" ^ 70)
println("  Lyr.jl Differential Operators Demo")
println("=" ^ 70)

# ============================================================================
# Helper: convert a scalar grid to a fog volume for rendering
# Maps values through a function f(v) → density ≥ 0
# ============================================================================
function _to_fog(grid, f; name="fog")
    data = Dict{Coord, Float32}()
    for (c, v) in active_voxels(grid.tree)
        d = f(v)
        d > Float32(1e-6) && (data[c] = d)
    end
    build_grid(data, 0.0f0; name=name)
end

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
    println("  Rendered to $filename (800x600, $spp spp)")
end

# ============================================================================
# 1. Source: Sphere Level Set
# ============================================================================
println("\n--- 1. Source Grid: Sphere SDF (radius=10) ---")
sphere = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                  voxel_size=1.0, half_width=3.0)
println("  Active voxels: $(active_voxel_count(sphere.tree))")

# Render the sphere as a fog volume (reference image)
sphere_fog = _to_fog(sphere, v -> v < 0 ? Float32(min(1.0, -v / 3.0)) :
                                  v < 1.0 ? Float32(1.0 - v) : 0.0f0;
                      name="sphere_fog")
_render(sphere_fog, "showcase/diff_ops_sphere.png";
        tf=tf_cool_warm(), sigma=15.0, emission=2.0)

# ============================================================================
# 2. Gradient Field (gradient_grid + magnitude_grid)
# ============================================================================
println("\n--- 2. Gradient Field: gradient_grid(sphere) ---")
t0 = time()
grad = gradient_grid(sphere)
dt = time() - t0
println("  Computed gradient in $(round(dt * 1000, digits=1)) ms")
println("  Output voxels: $(active_voxel_count(grad.tree))")

# The gradient of an SDF has magnitude ≈ 1.0 in the narrow band
grad_mag = magnitude_grid(grad)
println("  Gradient |∇f| at (10,0,0): $(get_value(grad_mag.tree, coord(10, 0, 0)))")
println("  Gradient |∇f| at (8,0,0):  $(get_value(grad_mag.tree, coord(8, 0, 0)))")

# Render: gradient magnitude — bright where the narrow band is
grad_fog = _to_fog(grad_mag, v -> v > 0.1f0 ? v : 0.0f0; name="grad_mag")
_render(grad_fog, "showcase/diff_ops_gradient.png";
        tf=tf_viridis(), sigma=30.0, emission=3.0)

# ============================================================================
# 3. Laplacian (Mean Curvature)
# ============================================================================
println("\n--- 3. Laplacian: laplacian(sphere) ---")
t0 = time()
lap = laplacian(sphere)
dt = time() - t0
println("  Computed laplacian in $(round(dt * 1000, digits=1)) ms")

# For a sphere of radius R, laplacian of SDF ≈ 2/R at the surface
lap_at_surface = get_value(lap.tree, coord(10, 0, 0))
println("  ∇²f at surface (10,0,0): $lap_at_surface (expected ≈ $(round(2.0/10.0, digits=2)))")

# Render: absolute laplacian — curvature concentrated at surface
lap_fog = _to_fog(lap, v -> Float32(min(1.0, abs(v) * 3.0)); name="laplacian")
_render(lap_fog, "showcase/diff_ops_laplacian.png";
        tf=tf_blackbody(), sigma=25.0, emission=3.0)

# ============================================================================
# 4. Construct a Velocity Field — Gaussian-modulated vortex
# ============================================================================
println("\n--- 4. Velocity Field: Gaussian Vortex ---")
let
    R = 15
    sigma2 = Float32(200.0)  # decay scale
    data = Dict{Coord, NTuple{3, Float32}}()
    for x in -R:R, y in -R:R, z in -R:R
        r2 = Float32(x^2 + y^2 + z^2)
        decay = exp(-r2 / sigma2)
        # Swirling vortex: (-y, x, 0) * decay + upward plume
        vx = Float32(-y) * decay
        vy = Float32(x) * decay
        vz = Float32(2.0) * exp(-Float32(x^2 + y^2) / Float32(50.0)) * decay
        mag = sqrt(vx^2 + vy^2 + vz^2)
        mag > 0.01f0 && (data[coord(x, y, z)] = (vx, vy, vz))
    end
    global velocity = build_grid(data, (0.0f0, 0.0f0, 0.0f0); name="velocity")
end
println("  Velocity field: $(active_voxel_count(velocity.tree)) voxels")

# Magnitude: shows flow speed distribution
vel_mag = magnitude_grid(velocity)
println("  Peak speed at (0,5,0): $(round(get_value(vel_mag.tree, coord(0, 5, 0)), digits=2))")
println("  Speed at origin:       $(round(get_value(vel_mag.tree, coord(0, 0, 0)), digits=2))")

vel_fog = _to_fog(vel_mag, v -> Float32(min(1.0, v / 10.0)); name="speed")
_render(vel_fog, "showcase/diff_ops_velocity.png";
        cam_dist=60.0, tf=tf_blackbody(), sigma=20.0, emission=3.0)

# ============================================================================
# 5. Divergence of the Velocity Field
# ============================================================================
println("\n--- 5. Divergence: divergence(velocity) ---")
t0 = time()
div_grid = divergence(velocity)
dt = time() - t0
println("  Computed divergence in $(round(dt * 1000, digits=1)) ms")
println("  Divergence at origin:  $(round(get_value(div_grid.tree, coord(0, 0, 0)), digits=3))")
println("  Divergence at (5,0,0): $(round(get_value(div_grid.tree, coord(5, 0, 0)), digits=3))")

# Render: absolute divergence — shows sources (positive) and sinks (negative)
div_fog = _to_fog(div_grid, v -> Float32(min(1.0, abs(v) / 0.5)); name="divergence")
_render(div_fog, "showcase/diff_ops_divergence.png";
        cam_dist=60.0, tf=tf_cool_warm(), sigma=15.0, emission=2.5)

# ============================================================================
# 6. Curl of the Velocity Field (Vorticity)
# ============================================================================
println("\n--- 6. Curl: curl_grid(velocity) → vorticity ---")
t0 = time()
curl = curl_grid(velocity)
dt = time() - t0
println("  Computed curl in $(round(dt * 1000, digits=1)) ms")

curl_mag = magnitude_grid(curl)
println("  Vorticity at origin:  $(round(get_value(curl_mag.tree, coord(0, 0, 0)), digits=3))")
println("  Vorticity at (5,0,0): $(round(get_value(curl_mag.tree, coord(5, 0, 0)), digits=3))")

curl_fog = _to_fog(curl_mag, v -> Float32(min(1.0, v / 2.0)); name="vorticity")
_render(curl_fog, "showcase/diff_ops_curl.png";
        cam_dist=60.0, tf=tf_viridis(), sigma=15.0, emission=2.5)

# ============================================================================
# 7. Normalize — Direction Field Verification
# ============================================================================
println("\n--- 7. Normalize: normalize_grid(velocity) ---")
norm_vel = normalize_grid(velocity)
norm_mag = magnitude_grid(norm_vel)
# Every non-zero vector should normalize to unit length
let
    n_unit = 0
    n_zero = 0
    for (c, v) in active_voxels(norm_mag.tree)
        if v > 0.5f0
            n_unit += 1
        else
            n_zero += 1
        end
    end
    println("  Unit-length vectors: $n_unit")
    println("  Zero vectors:        $n_zero")
    println("  Total:               $(n_unit + n_zero)")
end

# ============================================================================
# 8. Stencil Demo — Direct access pattern
# ============================================================================
println("\n--- 8. Stencil API: GradStencil + BoxStencil ---")
let
    s = GradStencil(sphere.tree)
    b = BoxStencil(sphere.tree)
    c = coord(10, 0, 0)

    move_to!(s, c)
    println("  GradStencil at (10,0,0):")
    println("    center = $(center_value(s))")
    println("    gradient = $(Lyr.gradient(s))")
    println("    laplacian = $(Lyr.laplacian(s))")

    move_to!(b, c)
    println("  BoxStencil at (10,0,0):")
    println("    center = $(center_value(b))")
    println("    mean = $(Lyr.mean_value(b))")
    println("    corner(-1,-1,-1) = $(Lyr.value_at(b, -1, -1, -1))")
end

# ============================================================================
# Summary
# ============================================================================
println("\n" * "=" ^ 70)
println("  Demo complete! Rendered images:")
println("    showcase/diff_ops_sphere.png     — source SDF (reference)")
println("    showcase/diff_ops_gradient.png   — |∇f| gradient magnitude")
println("    showcase/diff_ops_laplacian.png  — |∇²f| curvature")
println("    showcase/diff_ops_velocity.png   — |v| flow speed")
println("    showcase/diff_ops_divergence.png — |∇·v| sources/sinks")
println("    showcase/diff_ops_curl.png       — |∇×v| vorticity")
println("=" ^ 70)
