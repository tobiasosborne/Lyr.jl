@testset "Filtering" begin

    # Helper: build a scalar grid from an analytical function
    function _test_grid(f; R=5)
        data = Dict{Coord, Float32}()
        for x in -R:R, y in -R:R, z in -R:R
            data[coord(x, y, z)] = Float32(f(x, y, z))
        end
        build_grid(data, 0.0f0; name="test")
    end

    # ========================================================================
    # filter_mean
    # ========================================================================

    @testset "filter_mean: constant field unchanged" begin
        grid = _test_grid((x, y, z) -> 5.0)
        filtered = filter_mean(grid)
        # Interior voxels should remain exactly 5.0
        for c in [coord(0, 0, 0), coord(1, 1, 1), coord(-2, 3, 0)]
            @test get_value(filtered.tree, c) ≈ 5.0f0
        end
    end

    @testset "filter_mean: smooths spike" begin
        # Single spike in a flat field
        data = Dict{Coord, Float32}()
        for x in -3:3, y in -3:3, z in -3:3
            data[coord(x, y, z)] = 0.0f0
        end
        data[coord(0, 0, 0)] = 27.0f0  # spike (mean of 27 values = 1.0 if only center is nonzero)
        grid = build_grid(data, 0.0f0; name="spike")

        filtered = filter_mean(grid)
        # Center should drop from 27 toward 1 (mean of 26 zeros + 27)
        @test get_value(filtered.tree, coord(0, 0, 0)) < 27.0f0
        # Neighbors should increase from 0
        @test get_value(filtered.tree, coord(1, 0, 0)) > 0.0f0
    end

    @testset "filter_mean: multiple iterations smooth more" begin
        grid = _test_grid((x, y, z) -> Float64(x == 0 && y == 0 && z == 0) * 100.0)
        f1 = filter_mean(grid; iterations=1)
        f3 = filter_mean(grid; iterations=3)
        # More iterations → center value decreases (more spread)
        @test get_value(f3.tree, coord(0, 0, 0)) < get_value(f1.tree, coord(0, 0, 0))
    end

    @testset "filter_mean: preserves voxel count" begin
        grid = _test_grid((x, y, z) -> x + y + z)
        filtered = filter_mean(grid)
        @test active_voxel_count(filtered.tree) == active_voxel_count(grid.tree)
    end

    # ========================================================================
    # filter_gaussian
    # ========================================================================

    @testset "filter_gaussian: constant field unchanged" begin
        grid = _test_grid((x, y, z) -> 7.0)
        filtered = filter_gaussian(grid; sigma=1.0f0)
        for c in [coord(0, 0, 0), coord(1, 1, 1)]
            @test get_value(filtered.tree, c) ≈ 7.0f0
        end
    end

    @testset "filter_gaussian: smooths spike" begin
        data = Dict{Coord, Float32}()
        for x in -3:3, y in -3:3, z in -3:3
            data[coord(x, y, z)] = 0.0f0
        end
        data[coord(0, 0, 0)] = 100.0f0
        grid = build_grid(data, 0.0f0; name="spike")

        filtered = filter_gaussian(grid; sigma=1.0f0)
        center = get_value(filtered.tree, coord(0, 0, 0))
        face = get_value(filtered.tree, coord(1, 0, 0))
        corner = get_value(filtered.tree, coord(1, 1, 1))
        # Gaussian: center > face > corner (distance-weighted)
        @test center > face
        @test face > corner
        @test center < 100.0f0  # smoothed
    end

    @testset "filter_gaussian: smaller sigma preserves more" begin
        data = Dict{Coord, Float32}()
        for x in -3:3, y in -3:3, z in -3:3
            data[coord(x, y, z)] = 0.0f0
        end
        data[coord(0, 0, 0)] = 100.0f0
        grid = build_grid(data, 0.0f0; name="spike")

        f_narrow = filter_gaussian(grid; sigma=0.5f0)
        f_wide = filter_gaussian(grid; sigma=2.0f0)
        # Narrower sigma → center retains more of original value
        @test get_value(f_narrow.tree, coord(0, 0, 0)) > get_value(f_wide.tree, coord(0, 0, 0))
    end

    @testset "filter_gaussian: weights sum to 1" begin
        # Constant field → weights must sum to 1 for output to equal input
        grid = _test_grid((x, y, z) -> 42.0)
        for sigma in [0.3f0, 0.5f0, 1.0f0, 2.0f0, 5.0f0]
            filtered = filter_gaussian(grid; sigma=sigma)
            @test get_value(filtered.tree, coord(0, 0, 0)) ≈ 42.0f0
        end
    end

    @testset "filter_gaussian: multiple iterations" begin
        grid = _test_grid((x, y, z) -> Float64(x == 0 && y == 0 && z == 0) * 100.0)
        f1 = filter_gaussian(grid; sigma=1.0f0, iterations=1)
        f3 = filter_gaussian(grid; sigma=1.0f0, iterations=3)
        @test get_value(f3.tree, coord(0, 0, 0)) < get_value(f1.tree, coord(0, 0, 0))
    end

    # ========================================================================
    # Edge cases
    # ========================================================================

    @testset "filter_mean: empty grid" begin
        empty = build_grid(Dict{Coord, Float32}(), 0.0f0; name="empty")
        @test active_voxel_count(filter_mean(empty).tree) == 0
    end

    @testset "filter_gaussian: empty grid" begin
        empty = build_grid(Dict{Coord, Float32}(), 0.0f0; name="empty")
        @test active_voxel_count(filter_gaussian(empty; sigma=1.0f0).tree) == 0
    end

end
