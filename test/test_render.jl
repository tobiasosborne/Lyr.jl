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

            @test cam.position == (0.0, 0.0, 5.0)
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
            @test center_ray.origin == cam.position

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
        @testset "write_ppm creates valid file" begin
            pixels = [
                (1.0, 0.0, 0.0) (0.0, 1.0, 0.0);
                (0.0, 0.0, 1.0) (1.0, 1.0, 1.0)
            ]

            tmpfile = tempname() * ".ppm"
            write_ppm(tmpfile, pixels)

            @test isfile(tmpfile)

            content = read(tmpfile, String)
            lines = split(content, '\n')

            @test lines[1] == "P3"
            @test lines[2] == "2 2"  # width height
            @test lines[3] == "255"

            # First row: red, green
            @test strip(lines[4]) == "255 0 0 0 255 0"
            # Second row: blue, white
            @test strip(lines[5]) == "0 0 255 255 255 255"

            rm(tmpfile)
        end

        @testset "write_ppm clamps values" begin
            pixels = [
                (1.5, -0.5, 0.5);;  # Should clamp to 255, 0, 128
            ]

            tmpfile = tempname() * ".ppm"
            write_ppm(tmpfile, pixels)

            content = read(tmpfile, String)
            lines = split(content, '\n')

            # Clamped values: 1.5->255, -0.5->0, 0.5->128
            @test occursin("255 0 128", lines[4]) || occursin("255 0 127", lines[4])

            rm(tmpfile)
        end
    end

    @testset "Sphere Tracing" begin
        # Note: These sample VDB files are sparse narrow-band level sets
        # that only store values very close to the surface boundary.
        # Sphere tracing requires dense SDF coverage, so we test the
        # infrastructure rather than expecting surface hits on these files.

        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")

        if isfile(cube_path)
            vdb = parse_vdb(cube_path)
            grid = vdb.grids[1]

            @testset "sphere_trace returns nothing for miss" begin
                # Ray pointing away from the grid
                ray = Ray((100.0, 100.0, 100.0), (1.0, 0.0, 0.0))
                result = sphere_trace(ray, grid, 100)
                @test result === nothing
            end

            @testset "sphere_trace handles rays outside grid" begin
                # Ray that doesn't intersect the bounding box at all
                ray = Ray((1000.0, 1000.0, 1000.0), (1.0, 1.0, 1.0))
                result = sphere_trace(ray, grid, 100)
                @test result === nothing
            end
        end
    end

    @testset "Full Render Pipeline" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")

        if isfile(cube_path)
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

                pixels = render_image(grid, cam, 32, 24)

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

                pixels = render_image(grid, cam, 8, 8)

                # Verify we got a result (all pixels should be valid tuples)
                @test size(pixels) == (8, 8)
                @test all(p -> p isa NTuple{3, Float64}, pixels)
            end
        end
    end
end
