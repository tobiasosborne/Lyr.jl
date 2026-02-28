@testset "Stencils" begin

    # Shared test grid: level set sphere with smooth SDF values
    sphere = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                     voxel_size=1.0, half_width=3.0)
    tree = sphere.tree

    # ========================================================================
    # GradStencil
    # ========================================================================

    @testset "GradStencil construction" begin
        s = GradStencil(tree)
        @test s isa GradStencil{Float32}
    end

    @testset "GradStencil move_to! caches correct values" begin
        s = GradStencil(tree)
        c = coord(10, 0, 0)
        move_to!(s, c)

        @test center_value(s) == get_value(tree, c)
        @test s.v[2] == get_value(tree, coord(11, 0, 0))   # +x
        @test s.v[3] == get_value(tree, coord(9, 0, 0))    # -x
        @test s.v[4] == get_value(tree, coord(10, 1, 0))   # +y
        @test s.v[5] == get_value(tree, coord(10, -1, 0))  # -y
        @test s.v[6] == get_value(tree, coord(10, 0, 1))   # +z
        @test s.v[7] == get_value(tree, coord(10, 0, -1))  # -z
    end

    @testset "GradStencil gradient matches tree gradient" begin
        s = GradStencil(tree)
        test_coords = [
            coord(10, 0, 0), coord(0, 10, 0), coord(0, 0, 10),
            coord(8, 0, 0),  coord(0, 8, 0),  coord(0, 0, 8),
            coord(9, 1, 0),  coord(0, 9, 1),
        ]
        for c in test_coords
            move_to!(s, c)
            g_stencil = gradient(s)
            g_tree = gradient(tree, c)
            @test g_stencil[1] ≈ g_tree[1]
            @test g_stencil[2] ≈ g_tree[2]
            @test g_stencil[3] ≈ g_tree[3]
        end
    end

    @testset "GradStencil laplacian" begin
        s = GradStencil(tree)
        c = coord(10, 0, 0)
        move_to!(s, c)
        lap = laplacian(s)

        # Manual verification: sum of neighbors minus 6*center
        v = s.v
        expected = v[2] + v[3] + v[4] + v[5] + v[6] + v[7] - 6.0f0 * v[1]
        @test lap ≈ expected
    end

    @testset "GradStencil leaf boundary" begin
        # coord(7, 0, 0) is at the edge of an 8³ leaf; +x neighbor is in next leaf
        s = GradStencil(tree)
        c = coord(7, 0, 0)
        move_to!(s, c)
        @test center_value(s) == get_value(tree, c)
        @test s.v[2] == get_value(tree, coord(8, 0, 0))  # cross-leaf +x
        @test s.v[3] == get_value(tree, coord(6, 0, 0))
    end

    @testset "GradStencil background region" begin
        # Far outside narrow band — all values are background
        s = GradStencil(tree)
        c = coord(100, 0, 0)
        move_to!(s, c)
        bg = tree.background
        @test center_value(s) == bg
        for i in 2:7
            @test s.v[i] == bg
        end

        # Constant field → zero gradient and laplacian
        g = gradient(s)
        @test all(x -> x ≈ 0.0f0, g)
        @test laplacian(s) ≈ 0.0f0
    end

    @testset "GradStencil sequential moves" begin
        s = GradStencil(tree)
        # Two adjacent coords — verify each is independent
        move_to!(s, coord(10, 0, 0))
        v1 = center_value(s)
        move_to!(s, coord(10, 0, 1))
        v2 = center_value(s)
        @test v1 == get_value(tree, coord(10, 0, 0))
        @test v2 == get_value(tree, coord(10, 0, 1))
    end

    @testset "GradStencil center_coord tracking" begin
        s = GradStencil(tree)
        c = coord(5, 6, 7)
        move_to!(s, c)
        @test s.center_coord == c
    end

    # ========================================================================
    # BoxStencil
    # ========================================================================

    @testset "BoxStencil construction" begin
        s = BoxStencil(tree)
        @test s isa BoxStencil{Float32}
    end

    @testset "BoxStencil move_to! all 27 values correct" begin
        s = BoxStencil(tree)
        c = coord(10, 0, 0)
        move_to!(s, c)

        @test center_value(s) == get_value(tree, c)

        for dx in -1:1, dy in -1:1, dz in -1:1
            expected = get_value(tree, c + Coord(Int32(dx), Int32(dy), Int32(dz)))
            @test value_at(s, dx, dy, dz) == expected
        end
    end

    @testset "BoxStencil center index is 14" begin
        s = BoxStencil(tree)
        c = coord(10, 0, 0)
        move_to!(s, c)
        @test value_at(s, 0, 0, 0) == center_value(s)
        @test s.v[14] == center_value(s)
    end

    @testset "BoxStencil corners" begin
        s = BoxStencil(tree)
        c = coord(10, 0, 0)
        move_to!(s, c)
        @test value_at(s, -1, -1, -1) == get_value(tree, coord(9, -1, -1))
        @test value_at(s, 1, 1, 1) == get_value(tree, coord(11, 1, 1))
        @test value_at(s, -1, 1, -1) == get_value(tree, coord(9, 1, -1))
        @test value_at(s, 1, -1, 1) == get_value(tree, coord(11, -1, 1))
    end

    @testset "BoxStencil mean_value" begin
        s = BoxStencil(tree)
        c = coord(10, 0, 0)
        move_to!(s, c)

        expected = sum(s.v) / 27.0f0
        @test mean_value(s) ≈ expected
    end

    @testset "BoxStencil leaf boundary" begin
        # coord(7,7,7) — corner of a leaf, all +1 neighbors in different leaves
        s = BoxStencil(tree)
        c = coord(7, 7, 7)
        move_to!(s, c)
        for dx in -1:1, dy in -1:1, dz in -1:1
            expected = get_value(tree, c + Coord(Int32(dx), Int32(dy), Int32(dz)))
            @test value_at(s, dx, dy, dz) == expected
        end
    end

    @testset "BoxStencil background region" begin
        s = BoxStencil(tree)
        c = coord(100, 0, 0)
        move_to!(s, c)
        bg = tree.background
        for i in 1:27
            @test s.v[i] == bg
        end
        @test mean_value(s) ≈ bg
    end

    @testset "BoxStencil sequential moves" begin
        s = BoxStencil(tree)
        move_to!(s, coord(10, 0, 0))
        v1 = center_value(s)
        move_to!(s, coord(10, 0, 1))
        v2 = center_value(s)
        @test v1 == get_value(tree, coord(10, 0, 0))
        @test v2 == get_value(tree, coord(10, 0, 1))
    end

end
