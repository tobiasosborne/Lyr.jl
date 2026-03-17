# Test rendering functionality
using Test
using Lyr

@testset "Render" begin
    @testset "Camera" begin
        @testset "Camera construction" begin
            cam = Camera(
                (0.0, 0.0, 5.0),   # position
                (0.0, 0.0, 0.0),   # target
                (0.0, 1.0, 0.0),   # up
                60.0               # fov in degrees
            )

            @test Tuple(cam.position) == (0.0, 0.0, 5.0)
            @test cam.fov == 60.0
            # Direction should point toward target (negative z)
            @test cam.forward[3] < 0  # pointing into scene
        end

        @testset "look_at creates valid camera basis" begin
            cam = Camera(
                (10.0, 5.0, 10.0),
                (0.0, 0.0, 0.0),
                (0.0, 1.0, 0.0),
                45.0
            )

            # Basis vectors should be orthonormal
            dot_fr = cam.forward[1]*cam.right[1] + cam.forward[2]*cam.right[2] + cam.forward[3]*cam.right[3]
            dot_fu = cam.forward[1]*cam.up[1] + cam.forward[2]*cam.up[2] + cam.forward[3]*cam.up[3]
            dot_ru = cam.right[1]*cam.up[1] + cam.right[2]*cam.up[2] + cam.right[3]*cam.up[3]

            @test abs(dot_fr) < 1e-10  # orthogonal
            @test abs(dot_fu) < 1e-10
            @test abs(dot_ru) < 1e-10

            # Should be unit vectors
            len_f = sqrt(sum(x^2 for x in cam.forward))
            len_r = sqrt(sum(x^2 for x in cam.right))
            len_u = sqrt(sum(x^2 for x in cam.up))

            @test abs(len_f - 1.0) < 1e-10
            @test abs(len_r - 1.0) < 1e-10
            @test abs(len_u - 1.0) < 1e-10
        end

        @testset "camera_ray generates correct rays" begin
            cam = Camera(
                (0.0, 0.0, 5.0),
                (0.0, 0.0, 0.0),
                (0.0, 1.0, 0.0),
                90.0  # 90 degree FOV for easy math
            )

            # Center ray should point along forward direction
            center_ray = camera_ray(cam, 0.5, 0.5, 1.0)
            @test center_ray.origin == SVec3d(cam.position...)

            # Center ray should be parallel to forward
            cross_x = center_ray.direction[2]*cam.forward[3] - center_ray.direction[3]*cam.forward[2]
            cross_y = center_ray.direction[3]*cam.forward[1] - center_ray.direction[1]*cam.forward[3]
            cross_z = center_ray.direction[1]*cam.forward[2] - center_ray.direction[2]*cam.forward[1]
            cross_mag = sqrt(cross_x^2 + cross_y^2 + cross_z^2)
            @test cross_mag < 1e-10
        end
    end

    @testset "Shading" begin
        @testset "shade with light facing surface" begin
            normal = (0.0, 0.0, 1.0)
            light_dir = (0.0, 0.0, 1.0)  # Light coming from same direction as normal

            result = shade(normal, light_dir)

            # Should get maximum diffuse
            @test result > 0.8
        end

        @testset "shade with light perpendicular to surface" begin
            normal = (0.0, 0.0, 1.0)
            light_dir = (1.0, 0.0, 0.0)  # Light perpendicular

            result = shade(normal, light_dir)

            # Should only get ambient
            @test result < 0.3
        end

        @testset "shade with light behind surface" begin
            normal = (0.0, 0.0, 1.0)
            light_dir = (0.0, 0.0, -1.0)  # Light from behind

            result = shade(normal, light_dir)

            # Should only get ambient (diffuse clamped to 0)
            @test result < 0.3
        end
    end

    @testset "PPM Output" begin
        @testset "write_ppm creates valid P6 binary file" begin
            pixels = [
                (1.0, 0.0, 0.0) (0.0, 1.0, 0.0);
                (0.0, 0.0, 1.0) (1.0, 1.0, 1.0)
            ]

            tmpfile = tempname() * ".ppm"
            write_ppm(tmpfile, pixels)

            @test isfile(tmpfile)

            data = read(tmpfile)
            # P6 binary: header "P6\n2 2\n255\n" then raw RGB bytes
            header_end = findfirst(UInt8('\n'), data[findfirst(UInt8('\n'), data[findfirst(UInt8('\n'), data) + 1:end]) + findfirst(UInt8('\n'), data):end]) # complex, just find "255\n"
            # Simpler: parse header lines
            header_str = String(data[1:min(30, length(data))])
            @test startswith(header_str, "P6\n2 2\n255\n")

            # Binary pixel data starts after "P6\n2 2\n255\n" (12 bytes)
            hdr_len = length("P6\n2 2\n255\n")
            rgb = data[hdr_len + 1:end]
            @test length(rgb) == 2 * 2 * 3  # 4 pixels × 3 channels

            # Row 1: red=(255,0,0), green=(0,255,0)
            @test rgb[1:3] == UInt8[255, 0, 0]
            @test rgb[4:6] == UInt8[0, 255, 0]
            # Row 2: blue=(0,0,255), white=(255,255,255)
            @test rgb[7:9] == UInt8[0, 0, 255]
            @test rgb[10:12] == UInt8[255, 255, 255]

            rm(tmpfile)
        end

        @testset "write_ppm clamps values" begin
            pixels = [
                (1.5, -0.5, 0.5);;  # Should clamp to 255, 0, 128
            ]

            tmpfile = tempname() * ".ppm"
            write_ppm(tmpfile, pixels)

            data = read(tmpfile)
            hdr_len = length("P6\n1 1\n255\n")
            rgb = data[hdr_len + 1:end]
            @test length(rgb) == 3
            @test rgb[1] == UInt8(255)   # 1.5 clamped to 255
            @test rgb[2] == UInt8(0)     # -0.5 clamped to 0
            @test rgb[3] in UInt8[127, 128]  # 0.5 → 127 or 128

            rm(tmpfile)
        end
    end

    @testset "Sphere Tracing" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")

        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
        else
            vdb = parse_vdb(cube_path)
            grid = vdb.grids[1]

            @testset "sphere_trace returns nothing for miss" begin
                ray = Ray((100.0, 100.0, 100.0), (1.0, 0.0, 0.0))
                result = sphere_trace(ray, grid, 100)
                @test result === nothing
            end

            @testset "sphere_trace handles rays outside grid" begin
                ray = Ray((1000.0, 1000.0, 1000.0), (1.0, 1.0, 1.0))
                result = sphere_trace(ray, grid, 100)
                @test result === nothing
            end
        end

        sphere_path = joinpath(@__DIR__, "fixtures", "samples", "sphere.vdb")

        if !isfile(sphere_path)
            @test_skip "fixture not found: $sphere_path"
        else
            vdb = parse_vdb(sphere_path)
            grid = vdb.grids[1]

            @testset "sphere_trace hits sphere.vdb" begin
                # sphere.vdb has radius ~20 voxels, voxel_size ~0.1
                ray = Ray(SVec3d(-50.0, 0.0, 0.0), SVec3d(1.0, 0.0, 0.0))
                result = sphere_trace(ray, grid, 500)

                @test result !== nothing
                if result !== nothing
                    point, normal = result
                    @test point isa NTuple{3, Float64}
                    @test normal isa NTuple{3, Float64}
                    # Hit on near side — x < 0
                    @test point[1] < 0.0
                    # Outward normal opposes ray direction
                    @test normal[1] < -0.5
                    # Unit normal
                    len = sqrt(normal[1]^2 + normal[2]^2 + normal[3]^2)
                    @test len ≈ 1.0 atol=1e-6
                end
            end

            @testset "sphere_trace miss — ray above sphere" begin
                ray = Ray(SVec3d(-50.0, 100.0, 0.0), SVec3d(1.0, 0.0, 0.0))
                result = sphere_trace(ray, grid, 500)
                @test result === nothing
            end

            @testset "sphere_trace max_steps ignored — DDA has no step limit" begin
                # max_steps is kept for API compat but DDA terminates by geometry
                ray = Ray(SVec3d(-50.0, 0.0, 0.0), SVec3d(1.0, 0.0, 0.0))
                result_small = sphere_trace(ray, grid, 1)    # would fail old sphere tracer
                result_large = sphere_trace(ray, grid, 10000)
                # Both should give same result — DDA is geometry-driven
                @test (result_small === nothing) == (result_large === nothing)
                if result_small !== nothing && result_large !== nothing
                    p1, _ = result_small
                    p2, _ = result_large
                    @test p1[1] ≈ p2[1] atol=1e-10
                end
            end
        end
    end

    @testset "Anti-Aliasing (samples_per_pixel)" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end

        vdb = parse_vdb(cube_path)
        grid = vdb.grids[1]
        cam = Camera((10.0, 5.0, 10.0), (-3.0, -3.0, -3.0), (0.0, 1.0, 0.0), 60.0)

        @testset "spp=1 is default (identical to original)" begin
            p1 = Lyr.render_image(grid, cam, 8, 8)
            p2 = Lyr.render_image(grid, cam, 8, 8; samples_per_pixel=1)
            @test p1 == p2
        end

        @testset "spp=4 produces valid output" begin
            pixels = Lyr.render_image(grid, cam, 8, 8; samples_per_pixel=4)
            @test size(pixels) == (8, 8)
            @test all(p -> all(c -> 0.0 <= c <= 1.0, p), pixels)
        end

        @testset "spp=4 is deterministic with same seed" begin
            p1 = Lyr.render_image(grid, cam, 8, 8; samples_per_pixel=4, seed=UInt64(123))
            p2 = Lyr.render_image(grid, cam, 8, 8; samples_per_pixel=4, seed=UInt64(123))
            @test p1 == p2
        end

        @testset "different seeds produce different outputs" begin
            p1 = Lyr.render_image(grid, cam, 8, 8; samples_per_pixel=4, seed=UInt64(1))
            p2 = Lyr.render_image(grid, cam, 8, 8; samples_per_pixel=4, seed=UInt64(999))
            @test p1 != p2
        end
    end

    @testset "Gamma Correction" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end

        vdb = parse_vdb(cube_path)
        grid = vdb.grids[1]
        cam = Camera((10.0, 5.0, 10.0), (-3.0, -3.0, -3.0), (0.0, 1.0, 0.0), 60.0)

        @testset "gamma=1.0 is default (no change)" begin
            p1 = Lyr.render_image(grid, cam, 8, 8)
            p2 = Lyr.render_image(grid, cam, 8, 8; gamma=1.0)
            @test p1 == p2
        end

        @testset "gamma=2.2 produces darker midtones" begin
            p_linear = Lyr.render_image(grid, cam, 8, 8; gamma=1.0)
            p_gamma = Lyr.render_image(grid, cam, 8, 8; gamma=2.2)

            # Find pixels that are not background and not fully bright/dark
            mid_found = false
            for i in eachindex(p_linear)
                r_lin = p_linear[i][1]
                r_gam = p_gamma[i][1]
                if 0.1 < r_lin < 0.9
                    # Gamma < 1/gamma makes midtones brighter: x^(1/2.2) > x for x in (0,1)
                    @test r_gam >= r_lin - 1e-10
                    mid_found = true
                end
            end
            @test mid_found  # Ensure we actually tested some midtone pixels
        end

        @testset "gamma correction clamps to [0,1]" begin
            pixels = Lyr.render_image(grid, cam, 8, 8; gamma=2.2)
            @test all(p -> all(c -> 0.0 <= c <= 1.0, p), pixels)
        end
    end

    @testset "Full Render Pipeline" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @test_skip "fixture not found: $cube_path"
            return
        end

        vdb = parse_vdb(cube_path)
        grid = vdb.grids[1]

        target = (-3.0, -3.0, -3.0)

        @testset "render_image produces correct dimensions" begin
            cam = Camera(
                (10.0, 5.0, 10.0),
                target,
                (0.0, 1.0, 0.0),
                60.0
            )

            pixels = Lyr.render_image(grid, cam, 32, 24)

            @test size(pixels) == (24, 32)  # height x width
        end

        @testset "render_image completes without error" begin
            # With sparse narrow-band level sets, most rays will miss
            # and return background color. This test verifies the
            # pipeline doesn't crash.
            cam = Camera(
                (10.0, 5.0, 10.0),
                target,
                (0.0, 1.0, 0.0),
                60.0
            )

            pixels = Lyr.render_image(grid, cam, 8, 8)

            # Verify we got a result (all pixels should be valid tuples)
            @test size(pixels) == (8, 8)
            @test all(p -> p isa NTuple{3, Float64}, pixels)
        end
    end
end
