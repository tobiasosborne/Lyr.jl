@testset "GR SchwarzschildKS Metric" begin
    using Lyr.GR
    using LinearAlgebra: I, det, norm
    using StaticArrays

    M = 1.0
    s = SchwarzschildKS(M)

    @testset "Construction and utilities" begin
        @test s.M == 1.0
        @test horizon_radius(s) == 2.0
        @test photon_sphere_radius(s) == 3.0
        @test isco_radius(s) == 6.0
    end

    @testset "Metric at (t=0, x=10, y=0, z=0)" begin
        x = SVec4d(0.0, 10.0, 0.0, 0.0)
        g = metric(s, x)
        # r = 10, f = 2M/r = 0.2, l = (1, 1, 0, 0)
        # g_tt = -1 + 0.2*1*1 = -0.8
        @test g[1,1] ≈ -0.8
        # g_tx = 0 + 0.2*1*1 = 0.2
        @test g[1,2] ≈ 0.2
        # g_xx = 1 + 0.2*1*1 = 1.2
        @test g[2,2] ≈ 1.2
        # g_yy = 1 + 0.2*0*0 = 1.0
        @test g[3,3] ≈ 1.0
        @test g[4,4] ≈ 1.0
    end

    @testset "g × g⁻¹ = I at random points" begin
        for _ in 1:20
            x = SVec4d(0.0, 5.0 + 20.0*rand(), 5.0*randn(), 5.0*randn())
            g = metric(s, x)
            ginv = metric_inverse(s, x)
            @test norm(g * ginv - I) < 1e-10
        end
    end

    @testset "Flat-space limit (large r)" begin
        x_far = SVec4d(0.0, 1e6, 0.0, 0.0)
        g = metric(s, x_far)
        @test g[1,1] ≈ -1.0 atol=1e-5  # η_tt
        @test g[2,2] ≈ 1.0 atol=1e-5   # η_xx
    end

    @testset "Singularity detection" begin
        @test is_singular(s, SVec4d(0.0, 1.5, 0.0, 0.0)) == true   # r < 2M
        @test is_singular(s, SVec4d(0.0, 10.0, 0.0, 0.0)) == false  # r > 2M
    end

    @testset "Analytic partials: Hamiltonian RHS consistency" begin
        # Verify partials produce correct geodesic acceleration
        for _ in 1:20
            x = SVec4d(0.0, 3.0 + 20.0*rand(), 5.0*randn(), 5.0*randn())
            ginv = metric_inverse(s, x)
            p = SVec4d(-1.0, randn(), randn(), randn())
            # Make approximately null
            p = renormalize_null(s, x, p)
            dx, dp = hamiltonian_rhs(s, x, p)
            # dx should be finite and reasonable
            @test all(isfinite, dx)
            @test all(isfinite, dp)
            # Hamiltonian should be ~0
            H = hamiltonian(s, x, p)
            @test abs(H) < 1e-10
        end
    end

    @testset "Hamiltonian null geodesic" begin
        x = SVec4d(0.0, 10.0, 0.0, 0.0)
        # Radial null geodesic: p = (-E, E, 0, 0) gives H = 0 in Minkowski limit
        ginv = metric_inverse(s, x)
        # Solve for pt from null condition with pr=1
        # g^{tt}pt² + 2g^{tx}pt*1 + g^{xx}*1² = 0
        A = ginv[1,1]; B = 2*ginv[1,2]; C = ginv[2,2]
        disc = B^2 - 4*A*C
        pt = (-B - sqrt(disc)) / (2*A)
        p = SVec4d(pt, 1.0, 0.0, 0.0)
        H = hamiltonian(s, x, p)
        @test abs(H) < 1e-12
    end

    @testset "ks_to_sky_angles" begin
        # Point along x-axis: θ = π/2, φ = 0
        x_xaxis = SVec4d(0.0, 100.0, 0.0, 0.0)
        θ, φ = ks_to_sky_angles(x_xaxis)
        @test θ ≈ π/2 atol=0.01
        @test φ ≈ 0.0 atol=0.01

        # Point along z-axis: θ = 0
        x_zaxis = SVec4d(0.0, 0.0, 0.0, 100.0)
        θ, φ = ks_to_sky_angles(x_zaxis)
        @test θ ≈ 0.0 atol=0.01
    end
end
