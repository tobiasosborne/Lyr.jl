# grid_operations_demo.jl — Showcase of new VDB grid operations
#
# Demonstrates: level set primitives, CSG operations, grid compositing,
# copy_to_dense/copy_from_dense, compression write, pruning, and rendering.
#
# Run: julia --project examples/grid_operations_demo.jl

using Lyr
using Lyr: Coord, coord, BBox, build_grid, active_voxels, active_voxel_count,
           leaf_count, get_value, is_active,
           create_level_set_sphere, create_level_set_box,
           csg_union, csg_intersection, csg_difference,
           comp_max, comp_sum, comp_replace, clip,
           copy_to_dense, copy_from_dense,
           change_background, activate, deactivate, prune,
           inactive_voxels, all_voxels,
           GRID_LEVEL_SET, GRID_FOG_VOLUME,
           NoCompression, ZipCodec, BloscCodec,
           write_vdb, parse_vdb, compress, decompress

println("=" ^ 70)
println("  Lyr.jl Grid Operations Demo")
println("=" ^ 70)

# ============================================================================
# 1. Level Set Primitives — create analytical SDF shapes
# ============================================================================
println("\n--- 1. Level Set Primitives ---")

sphere = create_level_set_sphere(
    center=(0.0, 0.0, 0.0), radius=15.0,
    voxel_size=1.0, half_width=3.0
)
println("  Sphere: $(active_voxel_count(sphere.tree)) active voxels, " *
        "$(leaf_count(sphere.tree)) leaves")

box = create_level_set_box(
    min_corner=(-10.0, -10.0, -10.0),
    max_corner=(10.0, 10.0, 10.0),
    voxel_size=1.0, half_width=3.0
)
println("  Box:    $(active_voxel_count(box.tree)) active voxels, " *
        "$(leaf_count(box.tree)) leaves")

# ============================================================================
# 2. CSG Operations — boolean operations on level sets
# ============================================================================
println("\n--- 2. CSG Operations ---")

# Create two overlapping spheres for CSG demos
s1 = create_level_set_sphere(center=(-5.0, 0.0, 0.0), radius=12.0, voxel_size=1.0, half_width=3.0)
s2 = create_level_set_sphere(center=(5.0, 0.0, 0.0), radius=12.0, voxel_size=1.0, half_width=3.0)

u = csg_union(s1, s2)
println("  Union:        $(active_voxel_count(u.tree)) voxels (peanut shape)")

i = csg_intersection(s1, s2)
println("  Intersection: $(active_voxel_count(i.tree)) voxels (lens shape)")

d = csg_difference(s1, s2)
println("  Difference:   $(active_voxel_count(d.tree)) voxels (bitten sphere)")

# Sphere minus box = rounded sphere with flat sides
sphere_minus_box = csg_difference(sphere, box)
println("  Sphere-Box:   $(active_voxel_count(sphere_minus_box.tree)) voxels (cropped sphere)")

# ============================================================================
# 3. Compositing — combine fog volumes
# ============================================================================
println("\n--- 3. Grid Compositing ---")

# Create two fog volumes with Gaussian-like density patterns
fog_a_data = Dict{Coord, Float32}()
fog_b_data = Dict{Coord, Float32}()
for x in -8:8, y in -8:8, z in -8:8
    r2_a = Float64(x + 4)^2 + Float64(y)^2 + Float64(z)^2
    r2_b = Float64(x - 4)^2 + Float64(y)^2 + Float64(z)^2
    va = Float32(exp(-r2_a / 20.0))
    vb = Float32(exp(-r2_b / 20.0))
    va > 0.01f0 && (fog_a_data[coord(x, y, z)] = va)
    vb > 0.01f0 && (fog_b_data[coord(x, y, z)] = vb)
end
fog_a = build_grid(fog_a_data, 0.0f0; name="fog_a", grid_class=GRID_FOG_VOLUME)
fog_b = build_grid(fog_b_data, 0.0f0; name="fog_b", grid_class=GRID_FOG_VOLUME)

fog_max = comp_max(fog_a, fog_b)
fog_sum = comp_sum(fog_a, fog_b)
fog_replace = comp_replace(fog_a, fog_b)

println("  Fog A:       $(active_voxel_count(fog_a.tree)) voxels")
println("  Fog B:       $(active_voxel_count(fog_b.tree)) voxels")
println("  Max:         $(active_voxel_count(fog_max.tree)) voxels")
println("  Sum:         $(active_voxel_count(fog_sum.tree)) voxels")
println("  Replace A→B: $(active_voxel_count(fog_replace.tree)) voxels")

# ============================================================================
# 4. Clipping — spatial restriction
# ============================================================================
println("\n--- 4. Clipping ---")

# Clip fog to a sub-region
clip_box = BBox(coord(-4, -4, -4), coord(4, 4, 4))
clipped = clip(fog_sum, clip_box)
println("  Fog sum clipped to [-4,4]³: $(active_voxel_count(clipped.tree)) voxels " *
        "(from $(active_voxel_count(fog_sum.tree)))")

# ============================================================================
# 5. Dense ↔ Sparse Conversion
# ============================================================================
println("\n--- 5. Dense ↔ Sparse Conversion ---")

bbox = BBox(coord(-8, -8, -8), coord(8, 8, 8))
dense_arr = copy_to_dense(fog_sum, bbox)
println("  Dense array: $(size(dense_arr)) = $(prod(size(dense_arr))) elements")
println("  Non-zero elements: $(count(x -> x > 0.001f0, dense_arr))")

# Round-trip back to sparse
roundtrip = copy_from_dense(dense_arr, 0.0f0; bbox_min=coord(-8, -8, -8))
println("  Round-trip sparse: $(active_voxel_count(roundtrip.tree)) active voxels")

# ============================================================================
# 6. Inactive/All Voxels Iteration
# ============================================================================
println("\n--- 6. Iterator Demo ---")

small_data = Dict(coord(0,0,0) => 1.0f0, coord(1,0,0) => 2.0f0, coord(2,0,0) => 3.0f0)
small = build_grid(small_data, 0.0f0)

n_active = count(_ -> true, active_voxels(small.tree))
n_inactive = count(_ -> true, inactive_voxels(small.tree))
n_all = count(_ -> true, all_voxels(small.tree))
println("  Small grid: $(n_active) active, $(n_inactive) inactive, $(n_all) total (512 per leaf)")

# ============================================================================
# 7. Change Background / Activate / Deactivate
# ============================================================================
println("\n--- 7. Background & Activity Operations ---")

g = build_grid(Dict(coord(0,0,0) => 1.0f0, coord(1,0,0) => 0.0f0), 0.0f0)
println("  Original: bg=$(g.tree.background), active=$(active_voxel_count(g.tree))")

g2 = change_background(g, -1.0f0)
println("  After change_background(-1): bg=$(g2.tree.background)")

g3 = deactivate(g, 0.0f0)
println("  After deactivate(0.0): active=$(active_voxel_count(g3.tree))")

g4 = activate(g, 0.0f0)
println("  After activate(0.0): active=$(active_voxel_count(g4.tree)) (all bg-valued slots activated)")

# ============================================================================
# 8. Tree Pruning
# ============================================================================
println("\n--- 8. Tree Pruning ---")

# Build a grid with one uniform leaf and one varying leaf
uniform_data = Dict{Coord, Float32}()
varying_data = Dict{Coord, Float32}()
for x in 0:7, y in 0:7, z in 0:7
    uniform_data[coord(x, y, z)] = 5.0f0
    varying_data[coord(x + 8, y, z)] = Float32(x + y + z)
end
merge!(uniform_data, varying_data)
mixed = build_grid(uniform_data, 0.0f0)
println("  Before prune: $(leaf_count(mixed.tree)) leaves")

pruned = prune(mixed)
println("  After prune:  $(leaf_count(pruned.tree)) leaves (uniform leaf → tile)")
println("  Value at (0,0,0) via tile: $(get_value(pruned.tree, coord(0,0,0)))")
println("  Value at (10,3,2) via leaf: $(get_value(pruned.tree, coord(10,3,2)))")

# ============================================================================
# 9. Compressed VDB Write
# ============================================================================
println("\n--- 9. Compressed VDB Write ---")

tmpdir = mktempdir()
path_none = joinpath(tmpdir, "demo_none.vdb")
path_zip  = joinpath(tmpdir, "demo_zip.vdb")
path_blosc = joinpath(tmpdir, "demo_blosc.vdb")

write_vdb(path_none, fog_sum)
write_vdb(path_zip, fog_sum; codec=ZipCodec())
write_vdb(path_blosc, fog_sum; codec=BloscCodec())

sz_none  = filesize(path_none)
sz_zip   = filesize(path_zip)
sz_blosc = filesize(path_blosc)

println("  No compression: $(sz_none) bytes")
println("  Zip:            $(sz_zip) bytes ($(round(100 * sz_zip / sz_none; digits=1))%)")
println("  Blosc:          $(sz_blosc) bytes ($(round(100 * sz_blosc / sz_none; digits=1))%)")

# Verify round-trip
vdb_zip = parse_vdb(path_zip)
parsed = vdb_zip.grids[1]
println("  Zip round-trip: $(active_voxel_count(parsed.tree)) voxels (expected $(active_voxel_count(fog_sum.tree)))")

rm(tmpdir; recursive=true)

# ============================================================================
# 10. Rendering Demo — CSG sculpture
# ============================================================================
println("\n--- 10. Rendering CSG Sculpture ---")

# Create a visually interesting object: sphere with box cutout, converted to fog
sculpture_sdf = csg_difference(
    create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=20.0, voxel_size=1.0, half_width=3.0),
    create_level_set_box(min_corner=(-8.0, -8.0, -25.0), max_corner=(8.0, 8.0, 25.0), voxel_size=1.0, half_width=3.0)
)

# Convert SDF to fog: interior → density, exterior → 0
fog_data = Dict{Coord, Float32}()
for (c, sdf) in active_voxels(sculpture_sdf.tree)
    if sdf < 0
        # Interior: density based on depth
        fog_data[c] = Float32(min(1.0, -sdf / 3.0))
    elseif sdf < 1.0
        # Near surface: thin shell
        fog_data[c] = Float32(1.0 - sdf)
    end
end
sculpture_fog = build_grid(fog_data, 0.0f0; name="sculpture")
println("  Sculpture fog: $(active_voxel_count(sculpture_fog.tree)) voxels")

# Render the sculpture
cam1 = Camera((50.0, 40.0, 30.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
mat1 = VolumeMaterial(tf_cool_warm(); sigma_scale=20.0, emission_scale=2.0)
nano1 = build_nanogrid(sculpture_fog.tree)
lights1 = [DirectionalLight((1.0, 0.8, 0.6), (1.0, 1.0, 0.5)),
           DirectionalLight((0.3, 0.4, 0.8), (-1.0, -0.5, 1.0))]
scene = Scene(cam1, lights1, VolumeEntry(sculpture_fog, nano1, mat1))

img = render_volume_image(scene, 800, 600; spp=32)
write_ppm("sculpture_csg.ppm", img)
println("  Rendered to sculpture_csg.ppm (800×600, 32 spp)")

# Also render the union of two spheres
union_fog_data = Dict{Coord, Float32}()
for (c, sdf) in active_voxels(u.tree)
    if sdf < 0
        union_fog_data[c] = Float32(min(1.0, -sdf / 3.0))
    elseif sdf < 1.0
        union_fog_data[c] = Float32(1.0 - sdf)
    end
end
union_fog = build_grid(union_fog_data, 0.0f0; name="union")

cam2 = Camera((40.0, 30.0, 25.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 45.0)
mat2 = VolumeMaterial(tf_blackbody(); sigma_scale=15.0, emission_scale=3.0)
nano2 = build_nanogrid(union_fog.tree)
scene2 = Scene(cam2, DirectionalLight((1.0, 0.9, 0.7), (1.0, 0.5, 1.0)),
               VolumeEntry(union_fog, nano2, mat2))

img2 = render_volume_image(scene2, 800, 600; spp=32)
write_ppm("csg_union.ppm", img2)
println("  Rendered CSG union to csg_union.ppm")

# Render the intersection (lens shape)
inter_fog_data = Dict{Coord, Float32}()
for (c, sdf) in active_voxels(i.tree)
    if sdf < 0
        inter_fog_data[c] = Float32(min(1.0, -sdf / 2.0))
    elseif sdf < 1.0
        inter_fog_data[c] = Float32(1.0 - sdf)
    end
end
inter_fog = build_grid(inter_fog_data, 0.0f0; name="intersection")

cam3 = Camera((30.0, 25.0, 20.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 45.0)
mat3 = VolumeMaterial(tf_viridis(); sigma_scale=25.0, emission_scale=2.0)
nano3 = build_nanogrid(inter_fog.tree)
scene3 = Scene(cam3, DirectionalLight((1.0, 1.0, 1.0), (1.0, 1.0, 1.0)),
               VolumeEntry(inter_fog, nano3, mat3))

img3 = render_volume_image(scene3, 800, 600; spp=32)
write_ppm("csg_intersection.ppm", img3)
println("  Rendered CSG intersection to csg_intersection.ppm")

println("\n" * "=" ^ 70)
println("  Demo complete! Output files:")
println("    - sculpture_csg.ppm    (sphere with box channel cut)")
println("    - csg_union.ppm        (two merged spheres)")
println("    - csg_intersection.ppm (lens-shaped overlap)")
println("=" ^ 70)
