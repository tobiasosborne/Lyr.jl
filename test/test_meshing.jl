using Test
using Lyr
using Lyr: Coord, coord, create_level_set_sphere, volume_to_mesh, active_voxel_count

@testset "Meshing" begin
    @testset "sphere mesh" begin
        grid = create_level_set_sphere(center=(0.0,0.0,0.0), radius=10.0,
                                       voxel_size=1.0, half_width=3.0)
        verts, tris = volume_to_mesh(grid)

        @test length(verts) > 100
        @test length(tris) > 100

        # All vertices should be near radius 10
        for v in verts
            r = sqrt(v[1]^2 + v[2]^2 + v[3]^2)
            @test abs(r - 10.0) < 1.5  # within 1.5 world units of surface
        end

        # All triangle indices should be valid
        for tri in tris
            @test 1 <= tri[1] <= length(verts)
            @test 1 <= tri[2] <= length(verts)
            @test 1 <= tri[3] <= length(verts)
        end
    end

    @testset "empty grid" begin
        data = Dict{Coord, Float32}()
        grid = Lyr.build_grid(data, 3.0f0; name="empty", voxel_size=1.0)
        verts, tris = volume_to_mesh(grid)
        @test isempty(verts)
        @test isempty(tris)
    end

    @testset "box mesh" begin
        grid = Lyr.create_level_set_box(min_corner=(-5.0,-5.0,-5.0),
                                         max_corner=(5.0,5.0,5.0),
                                         voxel_size=1.0, half_width=3.0)
        verts, tris = volume_to_mesh(grid)
        @test length(verts) > 50
        @test length(tris) > 50
    end
end
