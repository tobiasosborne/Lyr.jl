@testset "GR Camera" begin
    using Lyr.GR
    using LinearAlgebra: dot, norm

    M = 1.0
    s = Schwarzschild(M)

    @testset "Static observer tetrad at r=10M" begin
        x = SVec4d(0.0, 10.0, π/2, 0.0)
        u, tetrad = static_observer_tetrad(s, x)

        # 4-velocity normalization: g_μν u^μ u^ν = -1
        g = metric(s, x)
        @test dot(u, g * u) ≈ -1.0 atol=1e-12

        # Tetrad orthonormality: g_μν e_a^μ e_b^ν = η_ab
        eta = SMat4d(
            -1.0, 0.0, 0.0, 0.0,
             0.0, 1.0, 0.0, 0.0,
             0.0, 0.0, 1.0, 0.0,
             0.0, 0.0, 0.0, 1.0
        )
        result = tetrad' * g * tetrad
        @test result ≈ eta atol=1e-12
    end

    @testset "Tetrad at different radii" begin
        for r in [5.0, 20.0, 50.0, 100.0]
            x = SVec4d(0.0, r, π/2, 0.0)
            u, tetrad = static_observer_tetrad(s, x)
            g = metric(s, x)

            # Normalization
            @test dot(u, g * u) ≈ -1.0 atol=1e-10

            # Orthonormality
            eta = SMat4d(-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
            @test tetrad' * g * tetrad ≈ eta atol=1e-10
        end
    end

    @testset "static_camera constructor" begin
        cam = static_camera(s, 20.0, π/2, 0.0, 60.0, (64, 64))
        @test cam.fov == 60.0
        @test cam.resolution == (64, 64)
        @test cam.position[2] == 20.0
    end

    @testset "pixel_to_momentum: null condition" begin
        cam = static_camera(s, 20.0, π/2, 0.0, 60.0, (32, 32))
        ginv = metric_inverse(s, cam.position)

        # Every pixel should produce a null momentum
        for i in [1, 16, 32]
            for j in [1, 16, 32]
                p = pixel_to_momentum(cam, i, j)
                H = 0.5 * dot(p, ginv * p)
                @test abs(H) < 1e-10
            end
        end
    end

    @testset "Center pixel points toward origin" begin
        cam = static_camera(s, 20.0, π/2, 0.0, 60.0, (64, 64))
        p_center = pixel_to_momentum(cam, 32, 32)

        # Future-directed: k^r > 0 (outward — the photon was traveling from BH
        # toward camera). Backward tracing with dl < 0 reverses this.
        ginv = metric_inverse(s, cam.position)
        k_contra = ginv * p_center
        @test k_contra[2] > 0.0  # radial component: outward (future-directed)
        @test k_contra[1] > 0.0  # time component: future-directed
    end
end
