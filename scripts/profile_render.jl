# Profile and benchmark the volume renderer
# Usage: julia --project -t auto scripts/profile_render.jl

using Lyr
using Profile

println("Threads: ", Threads.nthreads())

# ── Build canonical fog sphere scene ──
println("\n=== Building scene ===")
sdf = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0)
fog = sdf_to_fog(sdf)
nano = build_nanogrid(fog.tree)
mat = VolumeMaterial(tf_smoke(); sigma_scale=5.0, scattering_albedo=0.9)
cam = Camera((30.0, 0.0, 0.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
vol = VolumeEntry(fog, nano, mat)
scene = Scene(cam, DirectionalLight((1.0, 0.5, 0.0), (8.0, 8.0, 8.0)), vol)

# ── Warmup (JIT compilation) ──
println("Warming up...")
render_volume_image(scene, 8, 8; spp=1)
render_volume_preview(scene, 8, 8)
render_volume(scene, ReferencePathTracer(max_bounces=4), 8, 8; spp=1)

# ── Allocation benchmark (small render) ──
println("\n=== Allocation Check (64x48 spp=2) ===")
GC.gc()
allocs = @allocated render_volume_image(scene, 64, 48; spp=2)
println("Single-scatter allocations: ", allocs, " bytes (", round(allocs / 1024^2, digits=2), " MB)")

GC.gc()
allocs2 = @allocated render_volume_preview(scene, 64, 48)
println("Preview allocations:        ", allocs2, " bytes (", round(allocs2 / 1024^2, digits=2), " MB)")

GC.gc()
allocs3 = @allocated render_volume(scene, ReferencePathTracer(max_bounces=4), 64, 48; spp=2)
println("Multi-scatter allocations:  ", allocs3, " bytes (", round(allocs3 / 1024^2, digits=2), " MB)")

# ── Timing benchmark ──
println("\n=== Timing Benchmark ===")

# Small render (for quick iteration)
print("Single-scatter 200x150 spp=4: ")
GC.gc()
t1 = @elapsed render_volume_image(scene, 200, 150; spp=4)
println(round(t1, digits=3), "s")

print("Preview EA 200x150:           ")
GC.gc()
t2 = @elapsed render_volume_preview(scene, 200, 150)
println(round(t2, digits=3), "s")

print("Multi-scatter 200x150 spp=4:  ")
GC.gc()
t3 = @elapsed render_volume(scene, ReferencePathTracer(max_bounces=8), 200, 150; spp=4)
println(round(t3, digits=3), "s")

# Medium render
print("\nSingle-scatter 400x300 spp=8: ")
GC.gc()
t4 = @elapsed render_volume_image(scene, 400, 300; spp=8)
println(round(t4, digits=3), "s")

# ── CPU Profile ──
println("\n=== CPU Profile (200x150 spp=4 single-scatter) ===")
Profile.clear()
GC.gc()
Profile.@profile render_volume_image(scene, 200, 150; spp=4)

# Print flat profile (top 30 by count)
println("\n--- Flat Profile (top 30) ---")
Profile.print(IOContext(stdout, :displaysize => (40, 200)), noisefloor=2.0, maxdepth=20, sortedby=:count)

println("\n=== Done ===")
