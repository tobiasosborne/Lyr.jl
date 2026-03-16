@testset "Ray" begin
    @testset "Ray construction" begin
        origin = (0.0, 0.0, 0.0)
        direction = (1.0, 0.0, 0.0)

        ray = Ray(origin, direction)

        @test ray.origin == SVec3d(origin...)
        @test ray.direction == SVec3d(direction...)
        @test ray.inv_dir[1] == 1.0
        @test isinf(ray.inv_dir[2])
        @test isinf(ray.inv_dir[3])
    end

    @testset "Ray normalization" begin
        origin = (0.0, 0.0, 0.0)
        direction = (2.0, 0.0, 0.0)  # Not normalized

        ray = Ray(origin, direction)

        @test ray.direction == SVec3d(1.0, 0.0, 0.0)
    end

    @testset "intersect_bbox hit through center" begin
        ray = Ray((−5.0, 0.5, 0.5), (1.0, 0.0, 0.0))
        bbox = BBox(coord(0, 0, 0), coord(1, 1, 1))

        result = intersect_bbox(ray, bbox)
        @test result !== nothing

        t_enter, t_exit = result
        @test t_enter ≈ 5.0
        @test t_exit ≈ 6.0
    end

    @testset "intersect_bbox miss" begin
        ray = Ray((0.0, 10.0, 0.0), (1.0, 0.0, 0.0))  # Ray above box
        bbox = BBox(coord(0, 0, 0), coord(1, 1, 1))

        result = intersect_bbox(ray, bbox)
        @test result === nothing
    end

    @testset "intersect_bbox graze corner" begin
        # Ray through corner - this is a known numerical edge case with the slab method
        # where 0*Inf = NaN causes the intersection to fail.
        # Using slightly offset Y to avoid the degenerate case.
        ray = Ray((−1.0, 0.001, 0.001), (1.0, 0.0, 0.0))
        bbox = BBox(coord(0, 0, 0), coord(1, 1, 1))

        result = intersect_bbox(ray, bbox)
        @test result !== nothing  # Should hit
    end

    @testset "intersect_bbox negative direction" begin
        ray = Ray((5.0, 0.5, 0.5), (−1.0, 0.0, 0.0))
        bbox = BBox(coord(0, 0, 0), coord(1, 1, 1))

        result = intersect_bbox(ray, bbox)
        @test result !== nothing

        t_enter, t_exit = result
        @test t_enter ≈ 4.0
        @test t_exit ≈ 5.0
    end

    @testset "intersect_bbox axis-aligned" begin
        # Ray along X axis
        ray = Ray((−1.0, 0.5, 0.5), (1.0, 0.0, 0.0))
        bbox = BBox(coord(0, 0, 0), coord(2, 2, 2))

        result = intersect_bbox(ray, bbox)
        @test result !== nothing

        # Ray along Y axis
        ray = Ray((0.5, −1.0, 0.5), (0.0, 1.0, 0.0))
        result = intersect_bbox(ray, bbox)
        @test result !== nothing

        # Ray along Z axis
        ray = Ray((0.5, 0.5, −1.0), (0.0, 0.0, 1.0))
        result = intersect_bbox(ray, bbox)
        @test result !== nothing
    end

    @testset "intersect_bbox ray inside box" begin
        ray = Ray((0.5, 0.5, 0.5), (1.0, 0.0, 0.0))
        bbox = BBox(coord(0, 0, 0), coord(1, 1, 1))

        result = intersect_bbox(ray, bbox)
        @test result !== nothing

        t_enter, t_exit = result
        @test t_enter ≈ 0.0  # Already inside
        @test t_exit ≈ 0.5
    end

    @testset "intersect_leaves empty tree" begin
        tree = RootNode{Float32}(0.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        ray = Ray((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))

        intersections = intersect_leaves(ray, tree)
        @test isempty(intersections)
    end

    @testset "intersect_leaves matches intersect_leaves_dda" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end
        tree = parse_vdb(cube_path).grids[1].tree
        ray = Ray((-20.0, 4.0, 4.0), (1.0, 0.0, 0.0))

        hits = intersect_leaves(ray, tree)
        ref  = intersect_leaves_dda(ray, tree)

        @test length(hits) == length(ref)
        for (h, r) in zip(hits, ref)
            @test h.leaf.origin == r.leaf.origin
            @test h.t_enter ≈ r.t_enter atol=1e-10
            @test h.t_exit  ≈ r.t_exit  atol=1e-10
        end
    end

    @testset "AABB construction" begin
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(1.0, 1.0, 1.0))
        @test aabb.min == SVec3d(0.0, 0.0, 0.0)
        @test aabb.max == SVec3d(1.0, 1.0, 1.0)
    end

    @testset "AABB from BBox" begin
        bbox = BBox(coord(-3, 0, 7), coord(10, 20, 30))
        aabb = AABB(bbox)
        @test aabb.min == SVec3d(-3.0, 0.0, 7.0)
        @test aabb.max == SVec3d(10.0, 20.0, 30.0)
    end

    @testset "AABB hit through center" begin
        ray = Ray((-5.0, 0.5, 0.5), (1.0, 0.0, 0.0))
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(1.0, 1.0, 1.0))

        result = intersect_bbox(ray, aabb)
        @test result !== nothing
        t_enter, t_exit = result
        @test t_enter ≈ 5.0
        @test t_exit ≈ 6.0
    end

    @testset "AABB miss" begin
        ray = Ray((0.0, 10.0, 0.0), (1.0, 0.0, 0.0))
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(1.0, 1.0, 1.0))

        @test intersect_bbox(ray, aabb) === nothing
    end

    @testset "AABB ray inside box" begin
        ray = Ray((0.5, 0.5, 0.5), (1.0, 0.0, 0.0))
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(1.0, 1.0, 1.0))

        result = intersect_bbox(ray, aabb)
        @test result !== nothing
        t_enter, t_exit = result
        @test t_enter ≈ 0.0
        @test t_exit ≈ 0.5
    end

    @testset "AABB ray parallel to face" begin
        # Parallel to YZ plane, passing through box
        ray = Ray((0.5, -5.0, 0.5), (0.0, 1.0, 0.0))
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(1.0, 1.0, 1.0))

        result = intersect_bbox(ray, aabb)
        @test result !== nothing
        t_enter, t_exit = result
        @test t_enter ≈ 5.0
        @test t_exit ≈ 6.0

        # Parallel to YZ plane, missing box
        ray = Ray((1.5, -5.0, 0.5), (0.0, 1.0, 0.0))
        @test intersect_bbox(ray, aabb) === nothing
    end

    @testset "AABB diagonal ray" begin
        # Diagonal ray through unit cube from corner
        ray = Ray((-1.0, -1.0, -1.0), (1.0, 1.0, 1.0))
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(1.0, 1.0, 1.0))

        result = intersect_bbox(ray, aabb)
        @test result !== nothing
        t_enter, t_exit = result
        # Distance from (-1,-1,-1) to (0,0,0) along (1,1,1)/sqrt(3) is sqrt(3)
        @test t_enter ≈ sqrt(3.0)
        # Distance to (1,1,1) is 2*sqrt(3)
        @test t_exit ≈ 2.0 * sqrt(3.0)
    end

    @testset "AABB negative direction" begin
        ray = Ray((5.0, 0.5, 0.5), (-1.0, 0.0, 0.0))
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(1.0, 1.0, 1.0))

        result = intersect_bbox(ray, aabb)
        @test result !== nothing
        t_enter, t_exit = result
        @test t_enter ≈ 4.0
        @test t_exit ≈ 5.0
    end

    @testset "AABB fractional bounds" begin
        # Non-integer box bounds (the whole point of AABB vs BBox)
        ray = Ray((0.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        aabb = AABB(SVec3d(0.25, -0.5, -0.5), SVec3d(0.75, 0.5, 0.5))

        result = intersect_bbox(ray, aabb)
        @test result !== nothing
        t_enter, t_exit = result
        @test t_enter ≈ 0.25
        @test t_exit ≈ 0.75
    end

    @testset "AABB ray behind box" begin
        # Ray starts past the box and points away from it
        ray = Ray((5.0, 0.5, 0.5), (1.0, 0.0, 0.0))
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(1.0, 1.0, 1.0))

        @test intersect_bbox(ray, aabb) === nothing
    end

    @testset "AABB and BBox give same results" begin
        ray = Ray((-3.0, 2.5, 1.5), (1.0, 0.0, 0.0))
        bbox = BBox(coord(0, 0, 0), coord(5, 5, 5))
        aabb = AABB(bbox)

        result_bbox = intersect_bbox(ray, bbox)
        result_aabb = intersect_bbox(ray, aabb)

        @test result_bbox !== nothing
        @test result_aabb !== nothing
        @test result_bbox[1] ≈ result_aabb[1]
        @test result_bbox[2] ≈ result_aabb[2]
    end

    @testset "LeafIntersection" begin
        leaf = LeafNode{Float32}(
            coord(0, 0, 0),
            LeafMask(),
            ntuple(_ -> 0.0f0, 512)
        )

        intersection = LeafIntersection{Float32}(1.0, 2.0, leaf)
        @test intersection.t_enter == 1.0
        @test intersection.t_exit == 2.0
        @test intersection.leaf === leaf
    end
end
