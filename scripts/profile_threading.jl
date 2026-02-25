#!/usr/bin/env julia
# ============================================================================
# Threading profiling for Lyr.jl
# Usage: julia --project -t 1 scripts/profile_threading.jl   # baseline
#        julia --project -t 32 scripts/profile_threading.jl  # threaded
# ============================================================================

using Lyr
using BenchmarkTools
using Profile
using Random

println("=" ^ 70)
println("Lyr.jl Threading Profile")
println("  Julia threads:    $(Threads.nthreads())")
println("  Max thread ID:    $(Threads.maxthreadid())")
println("  Julia version:    $(VERSION)")
println("=" ^ 70)

# ============================================================================
# Setup: shared scene for all benchmarks
# ============================================================================

print("Setting up scene... ")
field = ScalarField3D(
    (x,y,z) -> exp(-(x^2+y^2+z^2)/2.0),
    BoxDomain((-4.0,-4.0,-4.0),(4.0,4.0,4.0)), 1.0)
grid = voxelize(field; threshold=0.01)
nanogrid = build_nanogrid(grid.tree)
cam = camera_orbit((0.0,0.0,0.0), 40.0; azimuth=30.0, elevation=25.0, fov=45.0)
tf = tf_viridis()
mat = VolumeMaterial(tf; sigma_scale=2.5, emission_scale=5.0, scattering_albedo=0.4)
light = DirectionalLight((0.5, 0.8, 1.0), (2.0, 2.0, 2.0))
vol = VolumeEntry(grid, nanogrid, mat)
scene = Scene(cam, light, vol; background=(0.01, 0.01, 0.02))
println("done.")

# Warmup
render_volume_image(scene, 64, 64; spp=1)
render_volume_preview(scene, 64, 64)

# ============================================================================
# Benchmark 1: render_volume_image (delta tracking, Threads.@threads)
# ============================================================================

println("\n--- render_volume_image (production renderer) ---")
for (w, h, spp) in [(128, 128, 1), (256, 256, 1), (256, 256, 4), (512, 512, 4)]
    t = @belapsed render_volume_image($scene, $w, $h; spp=$spp) samples=3 evals=1
    pixels_per_sec = w * h * spp / t
    println("  $(w)x$(h) spp=$spp: $(round(t, digits=3))s  ($(round(pixels_per_sec/1e6, digits=2))M samples/s)")
end

# ============================================================================
# Benchmark 2: render_volume_preview (emission-absorption, Threads.@threads)
# ============================================================================

println("\n--- render_volume_preview (preview renderer) ---")
for (w, h) in [(128, 128), (256, 256), (512, 512)]
    t = @belapsed render_volume_preview($scene, $w, $h) samples=3 evals=1
    println("  $(w)x$(h): $(round(t, digits=3))s  ($(round(w*h/t/1e6, digits=2))M pixels/s)")
end

# ============================================================================
# Benchmark 3: gaussian_splat (particle splatting, Threads.@threads)
# ============================================================================

println("\n--- gaussian_splat (particle splatting) ---")
for n in [100, 500, 2000]
    positions = [SVec3d(randn(3)...) for _ in 1:n]
    t = @belapsed Lyr.gaussian_splat($positions; sigma=1.0) samples=3 evals=1
    println("  $n particles: $(round(t*1000, digits=1))ms")
end

# ============================================================================
# Benchmark 4: denoise_bilateral (Threads.@threads)
# ============================================================================

println("\n--- denoise_bilateral ---")
noisy = render_volume_image(scene, 256, 256; spp=1)
noisy = tonemap_aces(noisy)
t = @belapsed denoise_bilateral($noisy) samples=3 evals=1
println("  256x256: $(round(t*1000, digits=1))ms")

# ============================================================================
# Benchmark 5: GR render (gr_render_image, internal threading)
# ============================================================================

println("\n--- gr_render_image (GR ray tracing) ---")
using Lyr.GR
M = 1.0
m = SchwarzschildKS(M)
thick = ThickDisk(4.0, 18.0, 0.15, 2.0)
vol_gr = VolumetricMatter(m, thick, 4.0, 18.0)
cam_gr = static_camera(m, 25.0, pi/2 - 0.25, 0.0, 55.0, (128, 128))
config = GRRenderConfig(
    integrator=IntegratorConfig(step_size=-0.05, max_steps=15000, r_max=100.0, stepper=:rk4),
    use_redshift=true, use_threads=true, samples_per_pixel=1)

# Warmup
gr_render_image(cam_gr, config; volume=vol_gr)

t = @belapsed gr_render_image($cam_gr, $config; volume=$vol_gr) samples=2 evals=1
println("  128x128 volumetric: $(round(t, digits=2))s  ($(round(128*128/t, digits=0)) pixels/s)")

cam_gr_256 = static_camera(m, 25.0, pi/2 - 0.25, 0.0, 55.0, (256, 256))
t = @belapsed gr_render_image($cam_gr_256, $config; volume=$vol_gr) samples=2 evals=1
println("  256x256 volumetric: $(round(t, digits=2))s  ($(round(256*256/t, digits=0)) pixels/s)")

# ============================================================================
# Profile: CPU time breakdown via Profile.@profile
# ============================================================================

println("\n--- CPU Profile (render_volume_image 256x256 spp=2) ---")
Profile.clear()
Profile.@profile render_volume_image(scene, 256, 256; spp=2)
Profile.print(IOContext(stdout, :displaysize => (40, 120)); maxdepth=8, mincount=20, noisefloor=2)

println("\n" * "=" ^ 70)
println("Done. Compare results between -t 1 and -t 32 to verify speedup.")
println("=" ^ 70)
