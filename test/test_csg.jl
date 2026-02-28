using Test
using Lyr
using Lyr: Coord, coord, build_grid, get_value, active_voxels, active_voxel_count,
           GRID_LEVEL_SET, csg_union, csg_intersection, csg_difference,
           create_level_set_sphere

@testset "CSG Operations" begin
    # Create two overlapping spheres
    s1 = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0, voxel_size=1.0, half_width=3.0)
    s2 = create_level_set_sphere(center=(8.0, 0.0, 0.0), radius=10.0, voxel_size=1.0, half_width=3.0)

    @testset "csg_union" begin
        u = csg_union(s1, s2)
        @test u.grid_class == GRID_LEVEL_SET

        # (8,0,0): in s1's narrow band with sdf=-2, s2 returns background=3.
        # Union = min(-2, 3) = -2 (inside)
        @test get_value(u.tree, coord(8, 0, 0)) < 0

        # (0,0,0): in s2's narrow band with sdf=-2, s1 returns background=3.
        # Union = min(3, -2) = -2 (inside)
        @test get_value(u.tree, coord(0, 0, 0)) < 0

        # Near surface of s1 at (10,0,0): sdf ≈ 0
        @test abs(get_value(u.tree, coord(10, 0, 0))) < 1.0

        # Far away: should be background
        @test get_value(u.tree, coord(100, 0, 0)) ≈ u.tree.background

        # Union should have at least as many voxels as either input
        @test active_voxel_count(u.tree) >= active_voxel_count(s1.tree)
        @test active_voxel_count(u.tree) >= active_voxel_count(s2.tree)
    end

    @testset "csg_intersection" begin
        i = csg_intersection(s1, s2)
        @test i.grid_class == GRID_LEVEL_SET

        # (4,7,0): both spheres have narrow-band values ≈ -1.94 (inside both)
        # Intersection = max(-1.94, -1.94) ≈ -1.94 (still inside)
        @test get_value(i.tree, coord(4, 7, 0)) < 0

        # (4,9,0): both spheres have narrow-band values ≈ -0.15 (just inside)
        @test get_value(i.tree, coord(4, 9, 0)) < 0

        # Far away: should be background
        @test get_value(i.tree, coord(100, 0, 0)) ≈ i.tree.background
    end

    @testset "csg_difference" begin
        d = csg_difference(s1, s2)
        @test d.grid_class == GRID_LEVEL_SET

        # (-8,0,0): inside s1 and far from s2 -> should be negative (kept)
        val_at_neg8 = get_value(d.tree, coord(-8, 0, 0))
        @test val_at_neg8 < 0

        # (4,0,0) in overlap: s1 says inside, s2 says inside -> difference removes it
        val_at_4 = get_value(d.tree, coord(4, 0, 0))
        @test val_at_4 > 0

        # Far away: should be background
        @test get_value(d.tree, coord(100, 0, 0)) ≈ d.tree.background
    end

    @testset "identity properties" begin
        # Union with self should approximate self
        u_self = csg_union(s1, s1)
        for (c, v) in active_voxels(s1.tree)
            @test get_value(u_self.tree, c) ≈ v
        end

        # Intersection with self should approximate self
        i_self = csg_intersection(s1, s1)
        for (c, v) in active_voxels(s1.tree)
            @test get_value(i_self.tree, c) ≈ v
        end
    end

    @testset "empty grid" begin
        empty_data = Dict{Coord, Float32}()
        empty_g = build_grid(empty_data, 3.0f0; name="empty", grid_class=GRID_LEVEL_SET)

        # Union with empty grid should preserve the non-empty grid's active voxels
        u = csg_union(s1, empty_g)
        @test active_voxel_count(u.tree) == active_voxel_count(s1.tree)

        # Intersection with empty grid: all coords only in s1 get max(sdf, bg),
        # which clips to background for far-inside voxels
        i = csg_intersection(s1, empty_g)
        # The intersection result at inside voxels should be max(sdf_a, bg=3.0),
        # and since deep inside voxels have sdf < 0, max(negative, 3.0) = 3.0 = bg,
        # so those voxels are pruned. Only voxels near the surface survive.
        @test active_voxel_count(i.tree) <= active_voxel_count(s1.tree)
    end

    @testset "commutativity" begin
        # Union is commutative
        u_ab = csg_union(s1, s2)
        u_ba = csg_union(s2, s1)
        for (c, v) in active_voxels(u_ab.tree)
            @test get_value(u_ba.tree, c) ≈ v
        end

        # Intersection is commutative
        i_ab = csg_intersection(s1, s2)
        i_ba = csg_intersection(s2, s1)
        for (c, v) in active_voxels(i_ab.tree)
            @test get_value(i_ba.tree, c) ≈ v
        end
    end

    @testset "non-overlapping spheres" begin
        # Two spheres far apart (no overlap)
        far1 = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=5.0, voxel_size=1.0, half_width=3.0)
        far2 = create_level_set_sphere(center=(50.0, 0.0, 0.0), radius=5.0, voxel_size=1.0, half_width=3.0)

        # Union should have approximately the sum of active voxels
        u = csg_union(far1, far2)
        @test active_voxel_count(u.tree) >=
              active_voxel_count(far1.tree) + active_voxel_count(far2.tree) - 10

        # Difference: a minus b with no overlap should be approximately a
        d = csg_difference(far1, far2)
        for (c, v) in active_voxels(far1.tree)
            @test get_value(d.tree, c) ≈ v
        end
    end
end
