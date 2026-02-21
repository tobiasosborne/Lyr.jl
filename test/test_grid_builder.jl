@testset "GridBuilder" begin
    @testset "single voxel" begin
        data = Dict(coord(0, 0, 0) => 1.0f0)
        grid = build_grid(data, 0.0f0)

        @test grid.name == "density"
        @test grid.grid_class == GRID_FOG_VOLUME
        @test get_value(grid.tree, coord(0, 0, 0)) == 1.0f0
        @test get_value(grid.tree, coord(1, 0, 0)) == 0.0f0  # background
        @test active_voxel_count(grid.tree) == 1
        @test leaf_count(grid.tree) == 1
    end

    @testset "multiple voxels same leaf" begin
        data = Dict(
            coord(0, 0, 0) => 1.0f0,
            coord(1, 2, 3) => 2.0f0,
            coord(7, 7, 7) => 3.0f0,
        )
        grid = build_grid(data, 0.0f0)

        @test get_value(grid.tree, coord(0, 0, 0)) == 1.0f0
        @test get_value(grid.tree, coord(1, 2, 3)) == 2.0f0
        @test get_value(grid.tree, coord(7, 7, 7)) == 3.0f0
        @test get_value(grid.tree, coord(4, 4, 4)) == 0.0f0
        @test active_voxel_count(grid.tree) == 3
        @test leaf_count(grid.tree) == 1  # all in same 8³ leaf
    end

    @testset "voxels spanning multiple leaves" begin
        data = Dict(
            coord(0, 0, 0) => 1.0f0,
            coord(8, 0, 0) => 2.0f0,   # different leaf
            coord(0, 8, 0) => 3.0f0,   # different leaf
        )
        grid = build_grid(data, 0.0f0)

        @test get_value(grid.tree, coord(0, 0, 0)) == 1.0f0
        @test get_value(grid.tree, coord(8, 0, 0)) == 2.0f0
        @test get_value(grid.tree, coord(0, 8, 0)) == 3.0f0
        @test active_voxel_count(grid.tree) == 3
        @test leaf_count(grid.tree) == 3
    end

    @testset "voxels spanning multiple I1 nodes" begin
        # I1 covers 128³, so coords at 0 and 128 are in different I1 nodes
        data = Dict(
            coord(0, 0, 0) => 1.0f0,
            coord(128, 0, 0) => 2.0f0,
        )
        grid = build_grid(data, 0.0f0)

        @test get_value(grid.tree, coord(0, 0, 0)) == 1.0f0
        @test get_value(grid.tree, coord(128, 0, 0)) == 2.0f0
        @test active_voxel_count(grid.tree) == 2
    end

    @testset "voxels spanning multiple I2 nodes" begin
        # I2 covers 4096³, so coords at 0 and 4096 are in different I2 nodes
        data = Dict(
            coord(0, 0, 0) => 1.0f0,
            coord(4096, 0, 0) => 2.0f0,
        )
        grid = build_grid(data, 0.0f0)

        @test get_value(grid.tree, coord(0, 0, 0)) == 1.0f0
        @test get_value(grid.tree, coord(4096, 0, 0)) == 2.0f0
        @test active_voxel_count(grid.tree) == 2
    end

    @testset "negative coordinates" begin
        data = Dict(
            coord(-1, -1, -1) => 5.0f0,
            coord(-8, 0, 0)   => 6.0f0,
        )
        grid = build_grid(data, 0.0f0)

        @test get_value(grid.tree, coord(-1, -1, -1)) == 5.0f0
        @test get_value(grid.tree, coord(-8, 0, 0)) == 6.0f0
        @test active_voxel_count(grid.tree) == 2
    end

    @testset "empty grid" begin
        data = Dict{Coord, Float32}()
        grid = build_grid(data, 0.0f0)
        @test active_voxel_count(grid.tree) == 0
    end

    @testset "custom name and class" begin
        data = Dict(coord(0, 0, 0) => 1.0f0)
        grid = build_grid(data, 0.0f0; name="temperature", grid_class=GRID_LEVEL_SET)
        @test grid.name == "temperature"
        @test grid.grid_class == GRID_LEVEL_SET
    end

    @testset "round-trip: build → write → parse → get_value" begin
        data = Dict(
            coord(0, 0, 0) => 1.0f0,
            coord(5, 3, 7) => 2.5f0,
            coord(10, 20, 30) => 0.1f0,
            coord(-4, -4, -4) => 9.9f0,
        )
        grid = build_grid(data, 0.0f0; name="test_rt", voxel_size=0.5)

        # Write to buffer and parse back
        buf = write_vdb_to_buffer(grid)
        vdb = parse_vdb(buf)
        @test length(vdb.grids) == 1
        parsed = vdb.grids[1]

        @test parsed.name == "test_rt"
        @test active_voxel_count(parsed.tree) == 4
        for (c, v) in data
            @test get_value(parsed.tree, c) ≈ v
        end
    end

    @testset "Float64 grid" begin
        data = Dict(coord(0, 0, 0) => 1.0, coord(1, 1, 1) => 2.0)
        grid = build_grid(data, 0.0; name="double")
        @test get_value(grid.tree, coord(0, 0, 0)) == 1.0
        @test get_value(grid.tree, coord(1, 1, 1)) == 2.0
    end
end

@testset "gaussian_splat" begin
    @testset "single particle symmetry" begin
        pos = [(0.0, 0.0, 0.0)]
        density = gaussian_splat(pos; voxel_size=1.0, sigma=1.0, cutoff_sigma=2.0)

        # Center should have highest value
        center_val = density[coord(0, 0, 0)]
        @test center_val > 0

        # Symmetric neighbors should have equal values
        @test density[coord(1, 0, 0)] ≈ density[coord(-1, 0, 0)]
        @test density[coord(0, 1, 0)] ≈ density[coord(0, -1, 0)]
        @test density[coord(0, 0, 1)] ≈ density[coord(0, 0, -1)]
        @test density[coord(1, 0, 0)] ≈ density[coord(0, 1, 0)]  # rotational symmetry

        # Center should be greater than neighbors
        @test center_val > density[coord(1, 0, 0)]
    end

    @testset "two particles accumulate" begin
        pos = [(0.0, 0.0, 0.0), (0.0, 0.0, 0.0)]
        d1 = gaussian_splat([(0.0, 0.0, 0.0)]; voxel_size=1.0, sigma=1.0)
        d2 = gaussian_splat(pos; voxel_size=1.0, sigma=1.0)

        # Two particles at same position → double the density
        @test d2[coord(0, 0, 0)] ≈ 2 * d1[coord(0, 0, 0)]
    end

    @testset "total mass conservation" begin
        pos = [(5.0, 5.0, 5.0)]
        density = gaussian_splat(pos; voxel_size=1.0, sigma=2.0, cutoff_sigma=4.0)

        # Total deposited mass should approximate (2π)^(3/2) * σ³
        total = sum(values(density))
        expected = Float32((2π)^1.5 * 2.0^3)
        @test total ≈ expected rtol=0.05
    end

    @testset "splat to build_grid round-trip" begin
        pos = [(5.0, 5.0, 5.0), (10.0, 10.0, 10.0)]
        density = gaussian_splat(pos; voxel_size=1.0, sigma=1.5, cutoff_sigma=3.0)
        grid = build_grid(density, 0.0f0; voxel_size=1.0)

        # Should have voxels and round-trip through get_value
        @test active_voxel_count(grid.tree) > 0
        @test get_value(grid.tree, coord(5, 5, 5)) ≈ density[coord(5, 5, 5)]
        @test get_value(grid.tree, coord(10, 10, 10)) ≈ density[coord(10, 10, 10)]
    end
end
