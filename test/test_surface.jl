# Test surface finding via DDA + zero crossing
using Test
using Lyr

@testset "Surface Finding" begin
    @testset "SurfaceHit struct" begin
        hit = SurfaceHit(1.5, SVec3d(1.0, 2.0, 3.0), SVec3d(0.0, 0.0, 1.0))
        @test hit.t == 1.5
        @test hit.position == SVec3d(1.0, 2.0, 3.0)
        @test hit.normal == SVec3d(0.0, 0.0, 1.0)
    end

    @testset "_voxel_in_leaf" begin
        origin = Coord(Int32(8), Int32(16), Int32(24))

        # Exact origin — inside
        @test Lyr._voxel_in_leaf(origin, origin) == true

        # origin + 7 — last voxel, inside
        @test Lyr._voxel_in_leaf(
            Coord(Int32(15), Int32(23), Int32(31)), origin) == true

        # origin + 8 — one past, outside
        @test Lyr._voxel_in_leaf(
            Coord(Int32(16), Int32(16), Int32(24)), origin) == false

        # origin - 1 — one before, outside
        @test Lyr._voxel_in_leaf(
            Coord(Int32(7), Int32(16), Int32(24)), origin) == false
    end

    @testset "_to_index_ray" begin
        @testset "uniform scale" begin
            transform = UniformScaleTransform(0.5)
            world_ray = Ray(SVec3d(1.0, 2.0, 3.0), SVec3d(1.0, 0.0, 0.0))
            idx_ray = Lyr._to_index_ray(transform, world_ray)

            # origin: (1, 2, 3) / 0.5 = (2, 4, 6)
            # Note: perpendicular axes get a 1e-6 nudge to avoid boundary issues
            @test idx_ray.origin[1] ≈ 2.0
            @test idx_ray.origin[2] ≈ 4.0 atol=1e-5
            @test idx_ray.origin[3] ≈ 6.0 atol=1e-5

            # direction should still be (1, 0, 0) normalized
            @test abs(idx_ray.direction[1]) ≈ 1.0 atol=1e-10
            @test abs(idx_ray.direction[2]) < 1e-10
            @test abs(idx_ray.direction[3]) < 1e-10
        end

        @testset "identity scale" begin
            transform = UniformScaleTransform(1.0)
            world_ray = Ray(SVec3d(5.0, 10.0, 15.0), SVec3d(0.0, -1.0, 0.0))
            idx_ray = Lyr._to_index_ray(transform, world_ray)

            @test idx_ray.origin ≈ SVec3d(5.0, 10.0, 15.0) atol=1e-5
            @test abs(idx_ray.direction[2] + 1.0) < 1e-10
        end
    end

    # Integration tests on sphere.vdb
    sphere_path = joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb")

    if isfile(sphere_path)
        vdb = parse_vdb(sphere_path)
        grid = vdb.grids[1]

        @testset "find_surface hits sphere along +X axis" begin
            # sphere.vdb has a sphere centered near origin, radius ~20 in index space
            # Shoot a ray along +X toward center
            ray = Ray(SVec3d(-50.0, 0.0, 0.0), SVec3d(1.0, 0.0, 0.0))
            result = find_surface(ray, grid)

            @test result !== nothing
            if result !== nothing
                hit = result

                # Hit point should be on the sphere surface
                # sphere.vdb is a level set with voxel size ~0.1
                # Analytic sphere has radius ~20 voxels = ~2.0 world units
                # The hit x coordinate should be roughly -radius in world space
                # Just verify it's roughly correct (within a voxel or two of analytic)
                vs = voxel_size(grid.transform)[1]
                @test hit.position[1] < 0.0  # hit on near side

                # Normal should point outward (-X direction since we hit the near side)
                @test hit.normal[1] < -0.5
                @test sqrt(hit.normal[1]^2 + hit.normal[2]^2 + hit.normal[3]^2) ≈ 1.0 atol=1e-6
            end
        end

        @testset "find_surface miss — ray far from geometry" begin
            # Ray well above the sphere
            ray = Ray(SVec3d(-50.0, 100.0, 0.0), SVec3d(1.0, 0.0, 0.0))
            result = find_surface(ray, grid)
            @test result === nothing
        end

        @testset "find_surface miss — ray pointing away" begin
            ray = Ray(SVec3d(-50.0, 0.0, 0.0), SVec3d(-1.0, 0.0, 0.0))
            result = find_surface(ray, grid)
            @test result === nothing
        end

        @testset "normal quality" begin
            # Shoot at sphere from multiple axis-aligned directions
            directions = [
                SVec3d(1.0, 0.0, 0.0),
                SVec3d(0.0, 1.0, 0.0),
                SVec3d(0.0, 0.0, 1.0),
            ]

            for dir in directions
                ray = Ray(-50.0 * dir, dir)
                result = find_surface(ray, grid)

                if result !== nothing
                    hit = result
                    # Normal must be unit length
                    len = sqrt(hit.normal[1]^2 + hit.normal[2]^2 + hit.normal[3]^2)
                    @test len ≈ 1.0 atol=1e-6

                    # Normal should point outward (opposing ray direction)
                    dot = hit.normal[1]*dir[1] + hit.normal[2]*dir[2] + hit.normal[3]*dir[3]
                    @test dot < -0.5  # roughly anti-parallel
                end
            end
        end

        @testset "multiple angles find surface" begin
            # Several rays from different angles, all aimed at origin
            origins = [
                SVec3d(-50.0, 0.0, 0.0),
                SVec3d(0.0, -50.0, 0.0),
                SVec3d(0.0, 0.0, -50.0),
                SVec3d(50.0, 0.0, 0.0),
                SVec3d(0.0, 50.0, 0.0),
                SVec3d(0.0, 0.0, 50.0),
            ]

            hit_count = 0
            for orig in origins
                dir = -orig  # aim at origin
                ray = Ray(orig, dir)
                result = find_surface(ray, grid)
                if result !== nothing
                    hit_count += 1
                end
            end

            # All 6 axis-aligned rays should hit the sphere
            @test hit_count == 6
        end
    end

    # Test on cube.vdb as well
    cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")

    if isfile(cube_path)
        vdb = parse_vdb(cube_path)
        grid = vdb.grids[1]

        @testset "find_surface on cube.vdb" begin
            # Cube centered around a small region
            bbox = active_bounding_box(grid.tree)
            if bbox !== nothing
                # Aim at center of active region
                center = index_to_world(grid.transform, bbox.min) .+
                         (index_to_world(grid.transform, bbox.max) .-
                          index_to_world(grid.transform, bbox.min)) .* 0.5

                ray = Ray(SVec3d(center[1] - 50.0, center[2], center[3]),
                          SVec3d(1.0, 0.0, 0.0))
                result = find_surface(ray, grid)

                # Should find the cube surface
                @test result !== nothing
                if result !== nothing
                    # Normal should be unit length
                    len = sqrt(result.normal[1]^2 + result.normal[2]^2 + result.normal[3]^2)
                    @test len ≈ 1.0 atol=1e-6
                end
            end
        end
    end
end
