using Test
using Lyr
using Lyr: Coord, coord, get_value, is_active, active_voxels, leaves,
           active_voxel_count, leaf_count, build_grid, GRID_LEVEL_SET,
           create_level_set_sphere, create_level_set_box

@testset "Level Set Primitives" begin
    @testset "Sphere" begin
        grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0, voxel_size=1.0, half_width=3.0)
        tree = grid.tree

        # Grid class should be level set
        @test grid.grid_class == GRID_LEVEL_SET

        # Background should be half_width * voxel_size
        @test tree.background ≈ 3.0f0

        # Check SDF at known points within the narrow band
        # At (10, 0, 0) — on the surface: SDF ≈ 0
        @test abs(get_value(tree, coord(10, 0, 0))) < 1.0

        # At (8, 0, 0) — 2 voxels inside surface: SDF ≈ -2
        @test get_value(tree, coord(8, 0, 0)) ≈ -2.0f0 atol=0.5

        # At (12, 0, 0) — 2 voxels outside surface: SDF ≈ 2
        @test get_value(tree, coord(12, 0, 0)) ≈ 2.0f0 atol=0.5

        # Deep interior is outside the narrow band — returns background
        @test get_value(tree, coord(0, 0, 0)) ≈ tree.background

        # Far outside should return background
        @test get_value(tree, coord(100, 0, 0)) ≈ tree.background

        # All stored values should be within narrow band
        for (c, v) in active_voxels(tree)
            @test abs(v) <= 3.0f0 + 1.0f0  # half_width * voxel_size + tolerance
        end

        # Should have reasonable number of voxels (narrow band of sphere)
        @test active_voxel_count(tree) > 100
    end

    @testset "Box" begin
        grid = create_level_set_box(min_corner=(-5.0, -5.0, -5.0), max_corner=(5.0, 5.0, 5.0), voxel_size=1.0, half_width=3.0)
        tree = grid.tree

        @test grid.grid_class == GRID_LEVEL_SET
        @test tree.background ≈ 3.0f0

        # At face center (5, 0, 0) — on the surface: SDF ≈ 0
        @test abs(get_value(tree, coord(5, 0, 0))) < 1.5

        # Just inside the face at (4, 0, 0): SDF ≈ -1 (1 voxel inside)
        @test get_value(tree, coord(4, 0, 0)) ≈ -1.0f0 atol=0.5

        # Just outside the face at (7, 0, 0): SDF ≈ 2 (2 voxels outside)
        @test get_value(tree, coord(7, 0, 0)) ≈ 2.0f0 atol=0.5

        # Deep inside (0,0,0) is outside narrow band — returns background
        @test get_value(tree, coord(0, 0, 0)) ≈ tree.background

        # Far outside
        @test get_value(tree, coord(100, 0, 0)) ≈ tree.background

        # Should have reasonable voxel count
        @test active_voxel_count(tree) > 100
    end

    @testset "Sphere with different voxel sizes" begin
        grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=5.0, voxel_size=0.5, half_width=3.0)
        @test grid.grid_class == GRID_LEVEL_SET
        @test grid.tree.background ≈ 1.5f0  # 3.0 * 0.5
        @test active_voxel_count(grid.tree) > 100
    end
end
