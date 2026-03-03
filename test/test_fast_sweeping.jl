using Test
using Lyr
using Lyr: Coord, coord, get_value, is_active, active_voxels, active_voxel_count,
           build_grid, GRID_LEVEL_SET, create_level_set_sphere, create_level_set_box,
           csg_union, GradStencil, move_to!, gradient, check_level_set,
           ValueAccessor, reinitialize_sdf

"""Compute gradient magnitude at interior band voxels (all 6 neighbors active)."""
function _gradient_stats(grid)
    tree = grid.tree
    acc = ValueAccessor(tree)
    stencil = GradStencil(tree)
    mags = Float64[]
    for (c, _) in active_voxels(tree)
        # Only test interior voxels (all 6 neighbors active)
        i, j, k = c.x, c.y, c.z
        all_active = is_active(acc, Coord(i+Int32(1),j,k)) &&
                     is_active(acc, Coord(i-Int32(1),j,k)) &&
                     is_active(acc, Coord(i,j+Int32(1),k)) &&
                     is_active(acc, Coord(i,j-Int32(1),k)) &&
                     is_active(acc, Coord(i,j,k+Int32(1))) &&
                     is_active(acc, Coord(i,j,k-Int32(1)))
        all_active || continue
        move_to!(stencil, c)
        g = gradient(stencil)
        push!(mags, sqrt(Float64(g[1])^2 + Float64(g[2])^2 + Float64(g[3])^2))
    end
    mags
end

@testset "FastSweeping" begin
    @testset "sphere identity — perfect SDF survives reinit" begin
        grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                       voxel_size=1.0, half_width=3.0)
        result = reinitialize_sdf(grid)

        # Same structure
        @test result.grid_class == GRID_LEVEL_SET
        @test result.tree.background ≈ grid.tree.background
        @test active_voxel_count(result.tree) == active_voxel_count(grid.tree)

        # Values close to original — O(h) Eikonal error at diagonal voxels
        # is ~0.4 for first-order Godunov on curved surfaces (expected)
        max_diff = 0.0
        for (c, v_in) in active_voxels(grid.tree)
            v_out = get_value(result.tree, c)
            max_diff = max(max_diff, abs(Float64(v_out) - Float64(v_in)))
        end
        @test max_diff < 0.5  # within half a voxel (first-order accuracy)
    end

    @testset "distorted sphere — fixes scaled SDF" begin
        grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                       voxel_size=1.0, half_width=3.0)
        bg = grid.tree.background

        # Distort: scale all SDF values by 1.5 (breaks |∇φ| = 1)
        data = Dict{Coord, Float32}()
        for (c, v) in active_voxels(grid.tree)
            data[c] = v * 1.5f0
        end
        distorted = build_grid(data, bg; name="distorted",
                               grid_class=GRID_LEVEL_SET, voxel_size=1.0)

        result = reinitialize_sdf(distorted)

        # Gradient magnitude should be ≈ 1.0 (voxel_size = 1.0)
        mags = _gradient_stats(result)
        @test length(mags) > 50
        good = count(m -> 0.85 < m < 1.15, mags)
        @test good / length(mags) > 0.85
    end

    @testset "CSG union — reinitializes min-based SDF" begin
        a = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=8.0,
                                    voxel_size=1.0, half_width=3.0)
        b = create_level_set_sphere(center=(10.0, 0.0, 0.0), radius=8.0,
                                    voxel_size=1.0, half_width=3.0)
        merged = csg_union(a, b)
        result = reinitialize_sdf(merged; iterations=3)

        # Gradient magnitude ≈ 1.0
        mags = _gradient_stats(result)
        @test length(mags) > 50
        good = count(m -> 0.80 < m < 1.20, mags)
        @test good / length(mags) > 0.80

        # Level set validation passes
        diag = check_level_set(result)
        @test diag.valid
    end

    @testset "box SDF" begin
        grid = create_level_set_box(min_corner=(-5.0, -5.0, -5.0),
                                    max_corner=(5.0, 5.0, 5.0),
                                    voxel_size=1.0, half_width=3.0)
        result = reinitialize_sdf(grid)

        @test result.grid_class == GRID_LEVEL_SET
        diag = check_level_set(result)
        @test diag.valid

        # Interior point should still be negative
        @test get_value(result.tree, coord(4, 0, 0)) < 0.0f0
        # Exterior point should still be positive
        @test get_value(result.tree, coord(7, 0, 0)) > 0.0f0
    end

    @testset "sign preservation" begin
        grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                       voxel_size=1.0, half_width=3.0)
        result = reinitialize_sdf(grid)

        violations = 0
        total = 0
        for (c, v_in) in active_voxels(grid.tree)
            v_out = get_value(result.tree, c)
            total += 1
            if sign(v_in) != sign(v_out) && abs(v_in) > 0.1f0
                violations += 1
            end
        end
        # Allow tiny fraction near zero-crossing where sign can flip
        @test violations / total < 0.01
    end

    @testset "gradient magnitude — gold standard" begin
        # Wider band (hw=5) gives more interior voxels for gradient measurement
        grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=15.0,
                                       voxel_size=1.0, half_width=5.0)
        result = reinitialize_sdf(grid; iterations=3)

        mags = _gradient_stats(result)
        @test length(mags) > 1000  # hw=5 gives many interior voxels

        # Mean should be close to 1.0
        mean_mag = sum(mags) / length(mags)
        @test 0.95 < mean_mag < 1.05

        # 90%+ should be within [0.85, 1.15]
        good = count(m -> 0.85 < m < 1.15, mags)
        @test good / length(mags) > 0.90
    end

    @testset "empty grid" begin
        data = Dict{Coord, Float32}()
        empty = build_grid(data, 3.0f0; name="empty",
                           grid_class=GRID_LEVEL_SET, voxel_size=1.0)
        result = reinitialize_sdf(empty)
        @test active_voxel_count(result.tree) == 0
    end

    @testset "non-unit voxel size" begin
        grid = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=5.0,
                                       voxel_size=0.5, half_width=3.0)
        result = reinitialize_sdf(grid)

        # Background = half_width × voxel_size = 1.5
        @test result.tree.background ≈ 1.5f0

        # Gradient in index space should be ≈ voxel_size = 0.5
        mags = _gradient_stats(result)
        @test length(mags) > 50
        mean_mag = sum(mags) / length(mags)
        @test 0.40 < mean_mag < 0.60  # ≈ 0.5
    end
end
