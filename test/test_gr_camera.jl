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

    @testset "SchwarzschildKS tetrad orthonormality" begin
        ks = SchwarzschildKS(1.0)
        eta = SMat4d(-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)

        # Test at several positions including different θ and φ
        positions = [
            (50.0, π/2, 0.0),    # equator, φ=0
            (50.0, π/4, π/3),    # mid-latitude
            (10.0, π/2, π),      # close to BH, equator
            (50.0, 0.001, 0.0),  # near north pole (ρ ≈ 0)
            (50.0, π-0.001, 1.5),# near south pole
        ]
        for (r, θ, φ) in positions
            x = SVec4d(0.0, r * sin(θ) * cos(φ), r * sin(θ) * sin(φ), r * cos(θ))
            u, tetrad = static_observer_tetrad(ks, x)
            g = metric(ks, x)

            # 4-velocity normalization
            @test dot(u, g * u) ≈ -1.0 atol=1e-10

            # Tetrad orthonormality: E^T g E = η
            result = tetrad' * g * tetrad
            @test result ≈ eta atol=1e-10
        end
    end

    @testset "SchwarzschildKS tetrad orientation matches BL" begin
        M = 1.0
        bl = Schwarzschild(M)
        ks = SchwarzschildKS(M)

        # At (r=50, θ=π/2, φ=0): compare center-pixel momentum direction
        r, θ, φ = 50.0, π/2, 0.0
        cam_bl = static_camera(bl, r, θ, φ, 60.0, (64, 64))
        cam_ks = static_camera(ks, r, θ, φ, 60.0, (64, 64))

        # Center pixel momentum — both should produce outward radial rays
        p_bl = pixel_to_momentum(cam_bl, 32, 32)
        p_ks = pixel_to_momentum(cam_ks, 32, 32)

        # Raise index to get k^μ in respective coordinates
        ginv_bl = metric_inverse(bl, cam_bl.position)
        ginv_ks = metric_inverse(ks, cam_ks.position)
        k_bl = ginv_bl * p_bl
        k_ks = ginv_ks * p_ks

        # BL: k^r > 0 (outward), KS: k^x > 0 (outward along x at φ=0)
        @test k_bl[2] > 0.0   # BL radial
        @test k_ks[2] > 0.0   # KS x-component (= radial at φ=0, θ=π/2)

        # Both future-directed
        @test k_bl[1] > 0.0
        @test k_ks[1] > 0.0

        # At (r=50, θ=π/4, φ=π/3): off-axis camera
        r2, θ2, φ2 = 50.0, π/4, π/3
        cam_ks2 = static_camera(ks, r2, θ2, φ2, 60.0, (64, 64))
        p_ks2 = pixel_to_momentum(cam_ks2, 32, 32)
        ginv_ks2 = metric_inverse(ks, cam_ks2.position)
        k_ks2 = ginv_ks2 * p_ks2

        # Center pixel should be radially outward: k · r_hat > 0
        x_cam = cam_ks2.position
        r_val = sqrt(x_cam[2]^2 + x_cam[3]^2 + x_cam[4]^2)
        r_hat = SVec4d(0.0, x_cam[2]/r_val, x_cam[3]/r_val, x_cam[4]/r_val)
        # Spatial dot product of k and r_hat (Euclidean, since both are contravariant spatial)
        k_dot_r = k_ks2[2]*r_hat[2] + k_ks2[3]*r_hat[3] + k_ks2[4]*r_hat[4]
        @test k_dot_r > 0.0
    end
end
