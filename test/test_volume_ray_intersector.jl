@testset "VolumeRayIntersector" begin
    @testset "empty tree" begin
        tree = RootNode{Float32}(0.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        ray = Ray((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))

        results = collect(VolumeRayIntersector(tree, ray))
        @test isempty(results)
    end

    @testset "iterator traits" begin
        tree = RootNode{Float32}(0.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        ray = Ray((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        vri = VolumeRayIntersector(tree, ray)

        @test Base.IteratorSize(typeof(vri)) == Base.SizeUnknown()
        @test eltype(typeof(vri)) == LeafIntersection{Float32}
    end

    @testset "equivalence with intersect_leaves_dda on cube.vdb" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "cube.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        rays = [
            Ray((-20.0, 4.0, 4.0), (1.0, 0.0, 0.0)),
            Ray((4.0, -20.0, 4.0), (0.0, 1.0, 0.0)),
            Ray((4.0, 4.0, -20.0), (0.0, 0.0, 1.0)),
            Ray((-20.0, -20.0, -20.0), (1.0, 1.0, 1.0)),
            Ray((20.0, 4.0, 4.0), (-1.0, 0.0, 0.0)),
        ]

        for ray in rays
            dda = intersect_leaves_dda(ray, tree)
            vri = collect(VolumeRayIntersector(tree, ray))

            @test length(vri) == length(dda)
            for (a, b) in zip(dda, vri)
                @test a.leaf.origin == b.leaf.origin
                @test a.t_enter ≈ b.t_enter atol=1e-10
                @test a.t_exit ≈ b.t_exit atol=1e-10
            end
        end
    end

    @testset "equivalence with intersect_leaves_dda on sphere.vdb" begin
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
            dda = intersect_leaves_dda(ray, tree)
            vri = collect(VolumeRayIntersector(tree, ray))

            @test length(vri) == length(dda)
            for (a, b) in zip(dda, vri)
                @test a.leaf.origin == b.leaf.origin
                @test a.t_enter ≈ b.t_enter atol=1e-10
                @test a.t_exit ≈ b.t_exit atol=1e-10
            end
        end
    end

    @testset "equivalence with brute-force intersect_leaves on cube.vdb" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "cube.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        ray = Ray((-20.0, 4.0, 4.0), (1.0, 0.0, 0.0))
        brute = intersect_leaves(ray, tree)
        vri = collect(VolumeRayIntersector(tree, ray))

        @test length(vri) == length(brute)
        for (a, b) in zip(brute, vri)
            @test a.leaf.origin == b.leaf.origin
            @test a.t_enter ≈ b.t_enter atol=1e-10
            @test a.t_exit ≈ b.t_exit atol=1e-10
        end
    end

    @testset "laziness — first() returns first DDA hit" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "cube.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        ray = Ray((-20.0, 4.0, 4.0), (1.0, 0.0, 0.0))
        dda = intersect_leaves_dda(ray, tree)
        @test !isempty(dda)

        first_vri = first(VolumeRayIntersector(tree, ray))
        @test first_vri.leaf.origin == dda[1].leaf.origin
        @test first_vri.t_enter ≈ dda[1].t_enter atol=1e-10
    end

    @testset "front-to-back ordering" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        ray = Ray((-50.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        results = collect(VolumeRayIntersector(tree, ray))

        for i in 2:length(results)
            @test results[i].t_enter >= results[i-1].t_enter
        end
    end

    @testset "miss ray returns empty" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "cube.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        ray = Ray((0.0, 10000.0, 0.0), (1.0, 0.0, 0.0))
        @test isempty(collect(VolumeRayIntersector(tree, ray)))
    end

    @testset "correct return type" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "cube.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        ray = Ray((-20.0, 4.0, 4.0), (1.0, 0.0, 0.0))
        results = collect(VolumeRayIntersector(tree, ray))
        @test results isa Vector{LeafIntersection{Float32}}
    end

    @testset "for-loop pattern" begin
        vdb = parse_vdb(joinpath(@__DIR__, "fixtures", "samples", "cube.vdb"))
        grid = vdb.grids[1]
        tree = grid.tree

        ray = Ray((-20.0, 4.0, 4.0), (1.0, 0.0, 0.0))
        dda = intersect_leaves_dda(ray, tree)

        count = 0
        for hit in VolumeRayIntersector(tree, ray)
            count += 1
            @test hit.t_enter < hit.t_exit
        end
        @test count == length(dda)
    end
end
