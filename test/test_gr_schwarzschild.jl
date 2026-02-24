@testset "GR Schwarzschild Metric" begin
    using Lyr.GR
    using LinearAlgebra: I, det, norm
    using StaticArrays
    using ForwardDiff

    M = 1.0
    s = Schwarzschild(M)

    @testset "Construction and utilities" begin
        @test s.M == 1.0
        @test horizon_radius(s) == 2.0
        @test photon_sphere_radius(s) == 3.0
        @test isco_radius(s) == 6.0
    end

    @testset "Metric values at r=10, θ=π/2" begin
        x = SVec4d(0.0, 10.0, π/2, 0.0)
        g = metric(s, x)

        f = 1.0 - 2.0/10.0  # 0.8
        @test g[1,1] ≈ -f
        @test g[2,2] ≈ 1.0/f
        @test g[3,3] ≈ 100.0        # r²
        @test g[4,4] ≈ 100.0        # r² sin²θ, θ=π/2
        # Off-diagonal
        @test g[1,2] ≈ 0.0 atol=1e-15
        @test g[1,3] ≈ 0.0 atol=1e-15
        @test g[2,3] ≈ 0.0 atol=1e-15
    end

    @testset "Metric inverse values" begin
        x = SVec4d(0.0, 10.0, π/2, 0.0)
        ginv = metric_inverse(s, x)

        f = 0.8
        @test ginv[1,1] ≈ -1.0/f
        @test ginv[2,2] ≈ f
        @test ginv[3,3] ≈ 1.0/100.0
        @test ginv[4,4] ≈ 1.0/100.0  # 1/(r² sin²θ)
    end

    @testset "g × g⁻¹ = I" begin
        for (r, θ) in [(5.0, π/2), (10.0, π/4), (50.0, π/3), (3.0, 0.1)]
            x = SVec4d(0.0, r, θ, 0.0)
            g = metric(s, x)
            ginv = metric_inverse(s, x)
            @test g * ginv ≈ SMat4d(I) atol=1e-12
        end
    end

    @testset "Determinant: det(g) = -r⁴ sin²θ" begin
        for (r, θ) in [(5.0, π/2), (10.0, π/4), (3.5, π/3)]
            x = SVec4d(0.0, r, θ, 0.0)
            g = metric(s, x)
            expected = -r^4 * sin(θ)^2
            @test det(g) ≈ expected rtol=1e-10
        end
    end

    @testset "Singularity detection" begin
        # Event horizon
        @test is_singular(s, SVec4d(0.0, 2.0, π/2, 0.0))
        # Inside horizon
        @test is_singular(s, SVec4d(0.0, 1.0, π/2, 0.0))
        # Physical singularity
        @test is_singular(s, SVec4d(0.0, 0.0, π/2, 0.0))
        # Outside horizon — not singular
        @test !is_singular(s, SVec4d(0.0, 3.0, π/2, 0.0))
        @test !is_singular(s, SVec4d(0.0, 100.0, π/2, 0.0))
    end

    @testset "Coordinate bounds" begin
        bounds = coordinate_bounds(s)
        @test bounds.r_min == 2.0  # horizon
        @test bounds.r_max == Inf
    end

    @testset "Analytic partials match ForwardDiff" begin
        # Compare analytic metric_inverse_partials to ForwardDiff-computed ones
        for (r, θ) in [(5.0, π/2), (10.0, π/4), (20.0, π/3)]
            x = SVec4d(0.0, r, θ, 0.0)

            # Analytic (provided by Schwarzschild implementation)
            analytic = metric_inverse_partials(s, x)

            # ForwardDiff (generic — must not force Float64 element type)
            f(x_) = SVector{16}(metric_inverse(s, x_))
            J = ForwardDiff.jacobian(f, x)
            forwarddiff = ntuple(μ -> SMat4d(J[:, μ]...), 4)

            for μ in 1:4
                @test analytic[μ] ≈ forwarddiff[μ] atol=1e-10
            end
        end
    end

    @testset "Hamiltonian for known null geodesic" begin
        # Circular photon orbit at r=3M: E and L related by L = 3√3 M E
        # For equatorial orbit (θ=π/2), the momentum components are:
        # p_t = -E, p_r = 0, p_θ = 0, p_φ = L
        # Null condition: g^{tt} E² + g^{φφ} L² = 0
        # At r=3M: g^{tt} = -1/f = -3, g^{φφ} = 1/(r²) = 1/9
        # → 3E² = L²/9 → L = 3√3 E
        r = 3.0 * M
        x = SVec4d(0.0, r, π/2, 0.0)
        E = 1.0
        L = 3.0 * sqrt(3.0) * M * E
        p = SVec4d(-E, 0.0, 0.0, L)

        H = hamiltonian(s, x, p)
        @test abs(H) < 1e-12
    end
end
