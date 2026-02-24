@testset "GR Render Pipeline" begin
    using Lyr.GR

    M = 1.0
    s = Schwarzschild(M)

    @testset "GRRenderConfig defaults" begin
        config = GRRenderConfig()
        @test config.use_redshift == true
        @test config.use_threads == true
        @test config.background == (0.0, 0.0, 0.02)
    end

    @testset "Small render: correct dimensions" begin
        cam = static_camera(s, 20.0, π/2, 0.0, 60.0, (8, 8))
        config = GRRenderConfig(
            integrator=IntegratorConfig(step_size=-0.1, max_steps=500, r_max=50.0),
            use_threads=false
        )
        pixels = gr_render_image(cam, config)

        @test size(pixels) == (8, 8)
    end

    @testset "No NaN or Inf in render output" begin
        cam = static_camera(s, 20.0, π/2, 0.0, 60.0, (8, 8))
        config = GRRenderConfig(
            integrator=IntegratorConfig(step_size=-0.1, max_steps=200, r_max=50.0),
            use_threads=false
        )
        pixels = gr_render_image(cam, config)

        for j in 1:8, i in 1:8
            r, g, b = pixels[j, i]
            @test isfinite(r) && isfinite(g) && isfinite(b)
            @test r >= 0.0 && g >= 0.0 && b >= 0.0
        end
    end

    @testset "Render with disk" begin
        cam = static_camera(s, 20.0, π/2, 0.0, 60.0, (8, 8))
        disk = ThinDisk(6.0, 20.0)
        config = GRRenderConfig(
            integrator=IntegratorConfig(step_size=-0.05, max_steps=500, r_max=50.0),
            use_threads=false,
            use_redshift=false
        )
        pixels = gr_render_image(cam, config; disk=disk)

        @test size(pixels) == (8, 8)
        # At least some pixels should be non-black (disk emission)
        has_color = any(p -> p[1] > 0.01 || p[2] > 0.01 || p[3] > 0.01,
                       pixels)
        @test has_color
    end

    @testset "Center pixels are dark (BH shadow)" begin
        # Camera looking straight at BH — center should be black
        cam = static_camera(s, 20.0, π/2, 0.0, 30.0, (16, 16))
        config = GRRenderConfig(
            integrator=IntegratorConfig(step_size=-0.05, max_steps=2000, r_max=50.0),
            use_threads=false
        )
        pixels = gr_render_image(cam, config)

        # Center pixel (8, 8) should be very dark (ray falls into BH)
        center = pixels[8, 8]
        brightness = center[1] + center[2] + center[3]
        @test brightness < 0.5  # dark (shadow or background)
    end
end
