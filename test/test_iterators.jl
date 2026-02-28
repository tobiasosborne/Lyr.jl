using Test
using Lyr
using Lyr: Coord, coord, build_grid, active_voxels, leaves,
           inactive_voxels, all_voxels, is_active, get_value,
           active_voxel_count, GRID_FOG_VOLUME

@testset "Inactive and All Voxels Iterators" begin
    # Build a small grid with known pattern
    data = Dict{Coord, Float32}()
    # Put a few voxels in one leaf
    data[coord(0, 0, 0)] = 1.0f0
    data[coord(1, 0, 0)] = 2.0f0
    data[coord(0, 1, 0)] = 3.0f0
    bg = 0.0f0
    grid = build_grid(data, bg)
    tree = grid.tree

    @testset "inactive_voxels" begin
        inactive = collect(inactive_voxels(tree))
        # Should have 512 - 3 = 509 inactive voxels in the one leaf
        @test length(inactive) == 509
        # All inactive values should be background
        @test all(pair -> pair[2] == bg, inactive)
        # Active coords should NOT be in inactive list
        active_coords = Set(c for (c, _) in active_voxels(tree))
        inactive_coords = Set(c for (c, _) in inactive)
        @test isempty(intersect(active_coords, inactive_coords))
    end

    @testset "all_voxels" begin
        all = collect(all_voxels(tree))
        # Should have exactly 512 voxels (one leaf)
        @test length(all) == 512
        # Check that active ones are marked correctly
        active_count = count(t -> t[3], all)
        @test active_count == 3
        # Check values
        for (c, v, active) in all
            if active
                @test v == get_value(tree, c)
            end
        end
    end
end
