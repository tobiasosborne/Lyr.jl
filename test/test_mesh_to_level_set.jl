using LinearAlgebra: normalize, norm

# ── Test mesh generators ──

function _cube_mesh(half_extent::Float64=5.0)
    s = half_extent
    vertices = [
        (-s, -s, -s), ( s, -s, -s), ( s,  s, -s), (-s,  s, -s),  # 1-4: z=-s
        (-s, -s,  s), ( s, -s,  s), ( s,  s,  s), (-s,  s,  s),  # 5-8: z=+s
    ]
    # All faces CCW when viewed from outside (outward normals)
    faces = [
        (1, 3, 2), (1, 4, 3),  # -Z
        (5, 6, 7), (5, 7, 8),  # +Z
        (1, 2, 6), (1, 6, 5),  # -Y
        (3, 4, 8), (3, 8, 7),  # +Y
        (1, 5, 8), (1, 8, 4),  # -X
        (2, 3, 7), (2, 7, 6),  # +X
    ]
    vertices, faces
end

function _icosphere(radius::Float64=10.0, subdivisions::Int=2)
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

    midpoint_cache = Dict{Tuple{Int,Int}, Int}()

    for _ in 1:subdivisions
        new_faces = NTuple{3,Int}[]
        empty!(midpoint_cache)

        for (i, j, k) in faces
            a = _get_midpoint!(vertices, midpoint_cache, i, j, radius)
            b = _get_midpoint!(vertices, midpoint_cache, j, k, radius)
            c = _get_midpoint!(vertices, midpoint_cache, k, i, radius)
            push!(new_faces, (i, a, c))
            push!(new_faces, (a, j, b))
            push!(new_faces, (c, b, k))
            push!(new_faces, (a, b, c))
        end

        faces = new_faces
    end

    [(v[1], v[2], v[3]) for v in vertices], faces
end

function _get_midpoint!(vertices, cache, i, j, radius)
    key = i < j ? (i, j) : (j, i)
    haskey(cache, key) && return cache[key]
    mid = normalize(vertices[i] + vertices[j]) * radius
    push!(vertices, mid)
    idx = length(vertices)
    cache[key] = idx
    return idx
end

# ── Tests ──

@testset "mesh_to_level_set" begin

    @testset "cube mesh SDF accuracy" begin
        verts, faces = _cube_mesh(5.0)
        grid = mesh_to_level_set(verts, faces; voxel_size=1.0, half_width=3.0)

        @test grid isa Grid{Float32}
        @test active_voxel_count(grid.tree) > 0

        # Surface points: SDF ≈ 0
        for c in [coord(5, 0, 0), coord(-5, 0, 0),
                  coord(0, 5, 0), coord(0, -5, 0),
                  coord(0, 0, 5), coord(0, 0, -5)]
            @test abs(get_value(grid.tree, c)) < 0.6f0
        end

        # Just inside (1 voxel from +X face): SDF < 0
        @test get_value(grid.tree, coord(4, 0, 0)) < 0.0f0

        # Just outside (1 voxel from +X face): SDF > 0
        @test get_value(grid.tree, coord(6, 0, 0)) > 0.0f0
    end

    @testset "cube matches create_level_set_box" begin
        verts, faces = _cube_mesh(5.0)
        mesh_grid = mesh_to_level_set(verts, faces; voxel_size=1.0, half_width=3.0)
        box_grid = create_level_set_box(min_corner=(-5.0, -5.0, -5.0),
                                         max_corner=(5.0, 5.0, 5.0);
                                         voxel_size=1.0, half_width=3.0)

        # SDF at face-center axis points should closely match
        for c in [coord(5, 0, 0), coord(0, 5, 0), coord(0, 0, 5),
                  coord(4, 0, 0), coord(6, 0, 0)]
            mesh_val = get_value(mesh_grid.tree, c)
            box_val = get_value(box_grid.tree, c)
            @test mesh_val ≈ box_val atol=0.5f0
        end
    end

    @testset "icosphere matches analytic sphere" begin
        radius = 10.0
        verts, faces = _icosphere(radius, 3)
        grid = mesh_to_level_set(verts, faces; voxel_size=1.0, half_width=3.0)
        ref = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=radius;
                                       voxel_size=1.0, half_width=3.0)

        # Voxel counts should be in the same ballpark
        mesh_count = active_voxel_count(grid.tree)
        ref_count = active_voxel_count(ref.tree)
        @test abs(mesh_count - ref_count) < ref_count * 0.3  # within 30%

        # SDF at axis points (face centers of icosphere are near-exact)
        for c in [coord(10, 0, 0), coord(-10, 0, 0),
                  coord(0, 10, 0), coord(0, 0, 10)]
            @test get_value(grid.tree, c) ≈ get_value(ref.tree, c) atol=0.5f0
        end
    end

    @testset "sign correctness" begin
        verts, faces = _cube_mesh(5.0)
        grid = mesh_to_level_set(verts, faces; voxel_size=1.0, half_width=3.0)

        # Interior points (within narrow band): negative SDF
        for c in [coord(4, 0, 0), coord(0, 4, 0), coord(0, 0, 4),
                  coord(-4, 0, 0), coord(0, -4, 0), coord(0, 0, -4)]
            @test get_value(grid.tree, c) < 0.0f0
        end

        # Exterior points (within narrow band): positive SDF
        for c in [coord(6, 0, 0), coord(0, 6, 0), coord(0, 0, 6),
                  coord(-6, 0, 0), coord(0, -6, 0), coord(0, 0, -6)]
            @test get_value(grid.tree, c) > 0.0f0
        end
    end

    @testset "narrow band consistency" begin
        verts, faces = _cube_mesh(5.0)
        grid = mesh_to_level_set(verts, faces; voxel_size=1.0, half_width=3.0)
        bg = grid.tree.background

        for (_, sdf) in active_voxels(grid.tree)
            @test abs(sdf) <= bg + 0.01f0
        end
    end

    @testset "check_level_set passes" begin
        verts, faces = _cube_mesh(5.0)
        grid = mesh_to_level_set(verts, faces; voxel_size=1.0, half_width=3.0)
        diag = check_level_set(grid)
        @test diag.interior_count > 0
        @test diag.exterior_count > 0
    end

    @testset "grid class is LEVEL_SET" begin
        verts, faces = _cube_mesh(5.0)
        grid = mesh_to_level_set(verts, faces; voxel_size=1.0)
        @test grid.grid_class == Lyr.GRID_LEVEL_SET
    end

    @testset "positive background" begin
        verts, faces = _cube_mesh(5.0)
        grid = mesh_to_level_set(verts, faces; half_width=3.0, voxel_size=1.0)
        @test grid.tree.background > 0.0f0
        @test grid.tree.background ≈ 3.0f0
    end

    @testset "voxel_size scaling" begin
        verts, faces = _cube_mesh(5.0)
        fine   = mesh_to_level_set(verts, faces; voxel_size=0.5)
        coarse = mesh_to_level_set(verts, faces; voxel_size=2.0)
        @test active_voxel_count(fine.tree) > active_voxel_count(coarse.tree)
    end

    @testset "empty mesh" begin
        grid = mesh_to_level_set(NTuple{3,Float64}[], NTuple{3,Int}[])
        @test active_voxel_count(grid.tree) == 0
    end

    @testset "single triangle" begin
        # A single triangle is not a closed mesh, but distance should still work
        verts = [(0.0, 0.0, 0.0), (10.0, 0.0, 0.0), (5.0, 10.0, 0.0)]
        faces = [(1, 2, 3)]
        grid = mesh_to_level_set(verts, faces; voxel_size=1.0, half_width=2.0)
        @test active_voxel_count(grid.tree) > 0
    end

end
