@testset "Hierarchical DDA" begin
    @testset "empty tree" begin
        tree = RootNode{Float32}(0.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        ray = Ray((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))

        results = intersect_leaves_dda(ray, tree)
        @test isempty(results)
    end

    @testset "equivalence with brute-force on cube.vdb" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "cube.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        # Test multiple rays from different angles
        rays = [
            Ray((-20.0, 4.0, 4.0), (1.0, 0.0, 0.0)),    # +X axis
            Ray((4.0, -20.0, 4.0), (0.0, 1.0, 0.0)),     # +Y axis
            Ray((4.0, 4.0, -20.0), (0.0, 0.0, 1.0)),     # +Z axis
            Ray((-20.0, -20.0, -20.0), (1.0, 1.0, 1.0)), # diagonal
            Ray((20.0, 4.0, 4.0), (-1.0, 0.0, 0.0)),     # -X axis
        ]

        for ray in rays
            brute = intersect_leaves(ray, tree)
            dda = intersect_leaves_dda(ray, tree)

            # Same number of leaves
            @test length(dda) == length(brute)

            # Same leaves in same order (both sorted by t_enter)
            for (a, b) in zip(brute, dda)
                @test a.leaf.origin == b.leaf.origin
                @test a.t_enter ≈ b.t_enter atol=1e-10
                @test a.t_exit ≈ b.t_exit atol=1e-10
            end
        end
    end

    @testset "equivalence with brute-force on sphere.vdb" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        rays = [
            Ray((-50.0, 0.0, 0.0), (1.0, 0.0, 0.0)),
            Ray((0.0, -50.0, 0.0), (0.0, 1.0, 0.0)),
            Ray((0.0, 0.0, -50.0), (0.0, 0.0, 1.0)),
            Ray((-50.0, -50.0, -50.0), (1.0, 1.0, 1.0)),
        ]

        for ray in rays
            brute = intersect_leaves(ray, tree)
            dda = intersect_leaves_dda(ray, tree)

            @test length(dda) == length(brute)

            for (a, b) in zip(brute, dda)
                @test a.leaf.origin == b.leaf.origin
                @test a.t_enter ≈ b.t_enter atol=1e-10
                @test a.t_exit ≈ b.t_exit atol=1e-10
            end
        end
    end

    @testset "miss ray returns empty" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "cube.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        # Ray far above the grid
        ray = Ray((0.0, 10000.0, 0.0), (1.0, 0.0, 0.0))
        @test isempty(intersect_leaves_dda(ray, tree))
    end

    @testset "results are front-to-back sorted" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        ray = Ray((-50.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        results = intersect_leaves_dda(ray, tree)

        for i in 2:length(results)
            @test results[i].t_enter >= results[i-1].t_enter
        end
    end
end
