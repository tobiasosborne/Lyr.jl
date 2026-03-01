#!/usr/bin/env julia
# mesh_to_level_set_demo.jl — Demonstrate mesh → SDF → volume render pipeline
#
# Usage: julia --project examples/mesh_to_level_set_demo.jl

using Lyr
using LinearAlgebra: normalize

# ── Generate icosphere mesh ──

function icosphere(radius::Float64, subdivisions::Int)
    R = radius
    vertices = SVec3d[
        SVec3d(R, 0, 0), SVec3d(-R, 0, 0),
        SVec3d(0, R, 0), SVec3d(0, -R, 0),
        SVec3d(0, 0, R), SVec3d(0, 0, -R),
    ]
    faces = NTuple{3,Int}[
        (1, 3, 5), (1, 5, 4), (1, 4, 6), (1, 6, 3),
        (2, 5, 3), (2, 4, 5), (2, 6, 4), (2, 3, 6),
    ]
    cache = Dict{Tuple{Int,Int}, Int}()

    for _ in 1:subdivisions
        new_faces = NTuple{3,Int}[]
        empty!(cache)
        for (i, j, k) in faces
            a = _midvert!(vertices, cache, i, j, R)
            b = _midvert!(vertices, cache, j, k, R)
            c = _midvert!(vertices, cache, k, i, R)
            push!(new_faces, (i, a, c), (a, j, b), (c, b, k), (a, b, c))
        end
        faces = new_faces
    end
    [(v[1], v[2], v[3]) for v in vertices], faces
end

function _midvert!(verts, cache, i, j, R)
    key = i < j ? (i, j) : (j, i)
    haskey(cache, key) && return cache[key]
    push!(verts, normalize(verts[i] + verts[j]) * R)
    cache[key] = length(verts)
end

# ── Main ──

println("=== mesh_to_level_set demo ===\n")

# Generate icosphere (3 subdivisions = 512 faces, 258 vertices)
radius = 15.0
verts, faces = icosphere(radius, 3)
println("Icosphere: $(length(verts)) vertices, $(length(faces)) faces, radius=$radius")

# Convert to SDF
println("\nConverting mesh to level set...")
t0 = time()
grid = mesh_to_level_set(verts, faces; voxel_size=1.0, half_width=3.0)
dt = time() - t0
println("  Voxels: $(active_voxel_count(grid.tree))")
println("  Leaves: $(leaf_count(grid.tree))")
println("  Time:   $(round(dt * 1000, digits=1)) ms")

# Compare against analytic sphere
ref = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=radius;
                               voxel_size=1.0, half_width=3.0)
println("\nComparison with analytic sphere SDF:")
println("  Mesh voxels:     $(active_voxel_count(grid.tree))")
println("  Analytic voxels: $(active_voxel_count(ref.tree))")

# Level set diagnostics
diag = check_level_set(grid)
println("\nLevel set diagnostics:")
println("  Interior: $(diag.interior_count) voxels")
println("  Exterior: $(diag.exterior_count) voxels")
println("  Surface:  $(diag.surface_count) voxels")

# SDF → fog for rendering
println("\nConverting SDF to fog volume...")
fog_data = Dict{Lyr.Coord, Float32}()
let bg = grid.tree.background
    for (c, sdf) in active_voxels(grid.tree)
        if sdf < 0.0f0
            fog_data[c] = Float32(min(1.0, -sdf / bg))
        end
    end
end
fog = build_grid(fog_data, 0.0f0; name="mesh_fog", voxel_size=1.0)
println("  Fog voxels: $(active_voxel_count(fog.tree))")

# Render
println("\nRendering...")
cam = Camera((40.0, 30.0, 25.0), (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), 40.0)
mat = VolumeMaterial(tf_cool_warm(); sigma_scale=20.0)
nano = build_nanogrid(fog.tree)
vol = VolumeEntry(fog, nano, mat)
light = DirectionalLight((1.0, 1.0, 1.0), (1.0, 0.8, 0.6))
scene = Scene(cam, light, vol)
img = render_volume_image(scene, 800, 600; spp=16)

ppm_path = joinpath(@__DIR__, "..", "showcase", "mesh_to_sdf.ppm")
png_path = joinpath(@__DIR__, "..", "showcase", "mesh_to_sdf.png")
write_ppm(ppm_path, img)
println("  Saved: $ppm_path")
write_png(png_path, img)
println("  Saved: $png_path")

println("\nDone!")
