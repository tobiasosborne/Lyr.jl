using Test
using Lyr
using Lyr: Coord, coord, build_grid, active_voxels, active_voxel_count,
           get_value, segment_active_voxels, create_level_set_sphere

@testset "Segmentation" begin
    @testset "two separate blobs -> 2 components" begin
        data = Dict{Coord, Float32}()
        # Blob 1: small cube at origin
        for x in 0:3, y in 0:3, z in 0:3
            data[coord(x, y, z)] = 1.0f0
        end
        # Blob 2: small cube far away (no face connectivity to blob 1)
        for x in 20:23, y in 20:23, z in 20:23
            data[coord(x, y, z)] = 2.0f0
        end

        grid = build_grid(data, 0.0f0; name="two_blobs", voxel_size=1.0)
        labels, count = segment_active_voxels(grid)

        @test count == 2
        @test active_voxel_count(labels.tree) == active_voxel_count(grid.tree)

        # All voxels in blob 1 should have same label
        label1 = get_value(labels.tree, coord(0, 0, 0))
        @test label1 > 0
        for x in 0:3, y in 0:3, z in 0:3
            @test get_value(labels.tree, coord(x, y, z)) == label1
        end

        # All voxels in blob 2 should have different label
        label2 = get_value(labels.tree, coord(20, 20, 20))
        @test label2 > 0
        @test label2 != label1
    end

    @testset "single connected blob -> 1 component" begin
        data = Dict{Coord, Float32}()
        for x in 0:5, y in 0:5, z in 0:5
            data[coord(x, y, z)] = 1.0f0
        end
        grid = build_grid(data, 0.0f0; name="one_blob", voxel_size=1.0)
        labels, count = segment_active_voxels(grid)

        @test count == 1
    end

    @testset "diagonal only -> 2 components with 6-connectivity" begin
        # Two voxels touching only diagonally (not face-connected)
        data = Dict{Coord, Float32}(
            coord(0, 0, 0) => 1.0f0,
            coord(1, 1, 1) => 1.0f0,
        )
        grid = build_grid(data, 0.0f0; name="diagonal", voxel_size=1.0)
        labels, count = segment_active_voxels(grid)

        @test count == 2
    end

    @testset "L-shaped connected blob -> 1 component" begin
        data = Dict{Coord, Float32}()
        # Horizontal bar
        for x in 0:5
            data[coord(x, 0, 0)] = 1.0f0
        end
        # Vertical bar connected at (5,0,0)
        for y in 0:5
            data[coord(5, y, 0)] = 1.0f0
        end
        grid = build_grid(data, 0.0f0; name="L_shape", voxel_size=1.0)
        labels, count = segment_active_voxels(grid)

        @test count == 1
    end

    @testset "empty grid -> 0 components" begin
        grid = build_grid(Dict{Coord, Float32}(), 0.0f0;
                          name="empty", voxel_size=1.0)
        labels, count = segment_active_voxels(grid)

        @test count == 0
        @test active_voxel_count(labels.tree) == 0
    end

    @testset "sphere level set -> 1 component" begin
        grid = create_level_set_sphere(center=(0.0,0.0,0.0), radius=5.0,
                                       voxel_size=1.0, half_width=3.0)
        labels, count = segment_active_voxels(grid)

        @test count == 1
        @test active_voxel_count(labels.tree) == active_voxel_count(grid.tree)
    end

    @testset "many tiny components" begin
        data = Dict{Coord, Float32}()
        # 10 isolated single voxels
        for i in 0:9
            data[coord(i * 10, 0, 0)] = 1.0f0
        end
        grid = build_grid(data, 0.0f0; name="scattered", voxel_size=1.0)
        labels, count = segment_active_voxels(grid)

        @test count == 10
    end
end
