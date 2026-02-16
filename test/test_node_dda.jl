@testset "NodeDDA" begin
    @testset "I1 node: ray along +X" begin
        # I1 node at origin (0,0,0), 16³ children, child_size=8
        origin = coord(0, 0, 0)
        ray = Ray((-1.0, 4.5, 4.5), (1.0, 0.0, 0.0))

        # Ray hits node AABB at tmin
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(128.0, 128.0, 128.0))
        result = intersect_bbox(ray, aabb)
        @test result !== nothing
        tmin, tmax = result

        ndda = node_dda_init(ray, tmin, origin, Int32(16), Int32(8))
        @test node_dda_inside(ndda)

        # First child should be at local (0, 0, 0)
        idx = node_dda_child_index(ndda)
        @test idx == 0

        # Step through children along X
        indices = [idx]
        for _ in 1:15
            dda_step!(ndda.state)
            if !node_dda_inside(ndda)
                break
            end
            push!(indices, node_dda_child_index(ndda))
        end

        # Should have visited 16 children (x=0..15, y=0, z=0)
        @test length(indices) == 16
        for i in 0:15
            @test (i * 256) in indices  # x * 16² + y*16 + z = i*256
        end
    end

    @testset "I1 node: ray along +Y" begin
        origin = coord(0, 0, 0)
        ray = Ray((4.5, -1.0, 4.5), (0.0, 1.0, 0.0))

        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(128.0, 128.0, 128.0))
        tmin, _ = intersect_bbox(ray, aabb)

        ndda = node_dda_init(ray, tmin, origin, Int32(16), Int32(8))
        @test node_dda_inside(ndda)

        indices = [node_dda_child_index(ndda)]
        for _ in 1:15
            dda_step!(ndda.state)
            if !node_dda_inside(ndda)
                break
            end
            push!(indices, node_dda_child_index(ndda))
        end

        @test length(indices) == 16
        for i in 0:15
            @test (i * 16) in indices  # x*256 + y*16 + z = i*16
        end
    end

    @testset "I2 node: ray along +X" begin
        # I2 node at origin (0,0,0), 32³ children, child_size=128
        origin = coord(0, 0, 0)
        ray = Ray((-1.0, 64.5, 64.5), (1.0, 0.0, 0.0))

        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(4096.0, 4096.0, 4096.0))
        tmin, _ = intersect_bbox(ray, aabb)

        ndda = node_dda_init(ray, tmin, origin, Int32(32), Int32(128))
        @test node_dda_inside(ndda)
        @test node_dda_child_index(ndda) == 0  # (0,0,0)

        dda_step!(ndda.state)
        @test node_dda_inside(ndda)
        @test node_dda_child_index(ndda) == 1024  # (1,0,0) → 1*32²
    end

    @testset "Leaf node: ray along +X" begin
        # Leaf at origin (0,0,0), 8³ voxels, child_size=1
        origin = coord(0, 0, 0)
        ray = Ray((-0.5, 3.5, 3.5), (1.0, 0.0, 0.0))

        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(8.0, 8.0, 8.0))
        tmin, _ = intersect_bbox(ray, aabb)

        ndda = node_dda_init(ray, tmin, origin, Int32(8), Int32(1))
        @test node_dda_inside(ndda)
        @test node_dda_child_index(ndda) == 0 * 64 + 3 * 8 + 3  # (0,3,3)

        dda_step!(ndda.state)
        @test node_dda_inside(ndda)
        @test node_dda_child_index(ndda) == 1 * 64 + 3 * 8 + 3  # (1,3,3)
    end

    @testset "node_dda_inside exits correctly" begin
        origin = coord(0, 0, 0)
        ray = Ray((-0.5, 0.5, 0.5), (1.0, 0.0, 0.0))

        # Small node: 8 children, child_size=1
        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(8.0, 8.0, 8.0))
        tmin, _ = intersect_bbox(ray, aabb)

        ndda = node_dda_init(ray, tmin, origin, Int32(8), Int32(1))
        @test node_dda_inside(ndda)

        steps = 0
        while node_dda_inside(ndda)
            dda_step!(ndda.state)
            steps += 1
            if steps > 20
                break  # Safety
            end
        end

        @test steps == 8  # Exits after crossing all 8 children
        @test !node_dda_inside(ndda)
    end

    @testset "node_dda_voxel_origin" begin
        origin = coord(0, 0, 0)
        ray = Ray((-1.0, 4.5, 4.5), (1.0, 0.0, 0.0))

        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(128.0, 128.0, 128.0))
        tmin, _ = intersect_bbox(ray, aabb)

        ndda = node_dda_init(ray, tmin, origin, Int32(16), Int32(8))
        vo = node_dda_voxel_origin(ndda)
        @test vo == coord(0, 0, 0)

        dda_step!(ndda.state)
        vo = node_dda_voxel_origin(ndda)
        @test vo == coord(8, 0, 0)
    end

    @testset "non-origin node" begin
        # I1 node at origin (128, 256, 0)
        origin = coord(128, 256, 0)
        ray = Ray((127.0, 260.5, 4.5), (1.0, 0.0, 0.0))

        aabb = AABB(SVec3d(128.0, 256.0, 0.0), SVec3d(256.0, 384.0, 128.0))
        tmin, _ = intersect_bbox(ray, aabb)

        ndda = node_dda_init(ray, tmin, origin, Int32(16), Int32(8))
        @test node_dda_inside(ndda)
        @test node_dda_child_index(ndda) == 0 * 256 + 0 * 16 + 0  # local (0,0,0)

        dda_step!(ndda.state)
        @test node_dda_inside(ndda)
        @test node_dda_child_index(ndda) == 1 * 256  # local (1,0,0)
    end

    @testset "child_index matches internal1_child_index" begin
        origin = coord(0, 0, 0)
        ray = Ray((-0.5, 36.5, 20.5), (1.0, 0.0, 0.0))

        aabb = AABB(SVec3d(0.0, 0.0, 0.0), SVec3d(128.0, 128.0, 128.0))
        tmin, _ = intersect_bbox(ray, aabb)

        ndda = node_dda_init(ray, tmin, origin, Int32(16), Int32(8))

        # At entry, DDA is at child (0, y/8, z/8) = (0, 4, 2)
        # internal1_child_index for coord (0, 36, 20) should give same result
        expected = internal1_child_index(coord(0, 36, 20))
        got = node_dda_child_index(ndda)
        @test got == expected

        # Step forward and check next
        dda_step!(ndda.state)
        expected2 = internal1_child_index(coord(8, 36, 20))
        got2 = node_dda_child_index(ndda)
        @test got2 == expected2
    end
end
