using Test
using Lyr
using Lyr: Coord, coord, build_grid, get_value, active_voxels, active_voxel_count,
           leaf_count, GRID_FOG_VOLUME, prune

@testset "Tree Pruning" begin
    @testset "Uniform leaf collapses to tile" begin
        # Build a grid where one leaf has all same values
        data = Dict{Coord, Float32}()
        for x in 0:7, y in 0:7, z in 0:7
            data[coord(x, y, z)] = 1.0f0  # All same value
        end
        grid = build_grid(data, 0.0f0)

        @test leaf_count(grid.tree) == 1

        pruned = prune(grid)
        # After pruning, the uniform leaf should become a tile
        @test leaf_count(pruned.tree) == 0
        # Values should still be accessible
        @test get_value(pruned.tree, coord(0, 0, 0)) ≈ 1.0f0
        @test get_value(pruned.tree, coord(7, 7, 7)) ≈ 1.0f0
    end

    @testset "Non-uniform leaf survives pruning" begin
        data = Dict{Coord, Float32}()
        for x in 0:7, y in 0:7, z in 0:7
            data[coord(x, y, z)] = Float32(x + y + z)  # Varying values
        end
        grid = build_grid(data, 0.0f0)

        pruned = prune(grid)
        @test leaf_count(pruned.tree) == 1  # Not pruned
    end

    @testset "Tolerance-based pruning" begin
        data = Dict{Coord, Float32}()
        for x in 0:7, y in 0:7, z in 0:7
            data[coord(x, y, z)] = 1.0f0 + Float32(x + y + z) * 0.001f0  # Small variation
        end
        grid = build_grid(data, 0.0f0)

        # With zero tolerance: not pruned (values vary)
        pruned0 = prune(grid; tolerance=0.0f0)
        @test leaf_count(pruned0.tree) == 1

        # With sufficient tolerance: pruned
        pruned1 = prune(grid; tolerance=1.0f0)
        @test leaf_count(pruned1.tree) == 0
    end

    @testset "Multiple leaves, mixed uniform/non-uniform" begin
        data = Dict{Coord, Float32}()
        # Leaf 1: uniform (at origin)
        for x in 0:7, y in 0:7, z in 0:7
            data[coord(x, y, z)] = 5.0f0
        end
        # Leaf 2: non-uniform (at offset 8)
        for x in 8:15, y in 0:7, z in 0:7
            data[coord(x, y, z)] = Float32(x)
        end
        grid = build_grid(data, 0.0f0)

        @test leaf_count(grid.tree) == 2

        pruned = prune(grid)
        @test leaf_count(pruned.tree) == 1  # Only non-uniform survives
        @test get_value(pruned.tree, coord(0, 0, 0)) ≈ 5.0f0  # Tile value
        @test get_value(pruned.tree, coord(10, 0, 0)) ≈ 10.0f0  # Leaf value
    end

    @testset "Empty grid prunes to empty grid" begin
        data = Dict{Coord, Float32}()
        grid = build_grid(data, 0.0f0)

        pruned = prune(grid)
        @test leaf_count(pruned.tree) == 0
        @test active_voxel_count(pruned.tree) == 0
    end

    @testset "Active flag preserved in pruned tile" begin
        # Build a leaf with all same values but mixed active/inactive
        # build_grid only sets active voxels, so all 512 will be active
        data = Dict{Coord, Float32}()
        for x in 0:7, y in 0:7, z in 0:7
            data[coord(x, y, z)] = 3.0f0
        end
        grid = build_grid(data, 0.0f0)

        pruned = prune(grid)
        @test leaf_count(pruned.tree) == 0
        # The tile should be active (all voxels were active)
        # Access through get_value still works
        @test get_value(pruned.tree, coord(0, 0, 0)) ≈ 3.0f0
    end

    @testset "Grid metadata preserved after pruning" begin
        data = Dict{Coord, Float32}()
        for x in 0:7, y in 0:7, z in 0:7
            data[coord(x, y, z)] = 1.0f0
        end
        grid = build_grid(data, 0.0f0; name="test_grid", grid_class=GRID_FOG_VOLUME, voxel_size=0.5)

        pruned = prune(grid)
        @test pruned.name == "test_grid"
        @test pruned.grid_class == GRID_FOG_VOLUME
        @test pruned.tree.background == 0.0f0
    end
end
