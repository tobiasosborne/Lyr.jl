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

    @testset "Christoffel symbols: analytic values at r=10, θ=π/3" begin
        x = SVec4d(0.0, 10.0, π/3, 0.0)
        Γt, Γr, Γθ, Γφ = christoffel(s, x)
        r = 10.0; f = 1.0 - 2.0/r
        sinθ = sin(π/3); cosθ = cos(π/3)

        # Γ^t_{tr} = M/(r²f)
        @test Γt[1,2] ≈ M / (r^2 * f) atol=1e-12
        @test Γt[2,1] ≈ Γt[1,2] atol=1e-15  # symmetric

        # Γ^r_{tt} = Mf/r²
        @test Γr[1,1] ≈ M * f / r^2 atol=1e-12
        # Γ^r_{rr} = -M/(r²f)
        @test Γr[2,2] ≈ -M / (r^2 * f) atol=1e-12
        # Γ^r_{θθ} = -(r-2M)
        @test Γr[3,3] ≈ -(r - 2M) atol=1e-12
        # Γ^r_{φφ} = -(r-2M)sin²θ
        @test Γr[4,4] ≈ -(r - 2M) * sinθ^2 atol=1e-12

        # Γ^θ_{rθ} = 1/r
        @test Γθ[2,3] ≈ 1.0/r atol=1e-12
        @test Γθ[3,2] ≈ Γθ[2,3] atol=1e-15  # symmetric
        # Γ^θ_{φφ} = -sinθ cosθ
        @test Γθ[4,4] ≈ -sinθ * cosθ atol=1e-12

        # Γ^φ_{rφ} = 1/r
        @test Γφ[2,4] ≈ 1.0/r atol=1e-12
        @test Γφ[4,2] ≈ Γφ[2,4] atol=1e-15  # symmetric
        # Γ^φ_{θφ} = cosθ/sinθ
        @test Γφ[3,4] ≈ cosθ / sinθ atol=1e-12
        @test Γφ[4,3] ≈ Γφ[3,4] atol=1e-15
    end

    @testset "Christoffel symbols: verify against numerical metric derivatives" begin
        # Γ^μ_{αβ} = ½ g^{μσ} (∂g_{σα}/∂x^β + ∂g_{σβ}/∂x^α - ∂g_{αβ}/∂x^σ)
        # We verify by checking that the geodesic acceleration from Christoffel
        # matches the Hamiltonian formulation for random (r, θ) points.
        for _ in 1:100
            r = 3.0 + 97.0 * rand()  # r ∈ [3, 100]
            θ = 0.1 + (π - 0.2) * rand()  # θ ∈ [0.1, π-0.1]
            x = SVec4d(0.0, r, θ, 0.0)

            # Random momentum on the null cone
            p_spatial = SVec4d(0.0, randn(), randn(), randn())
            ginv = metric_inverse(s, x)
            # Solve for p_t from null condition: g^{tt}p_t² + g^{rr}p_r² + ... = 0
            C = ginv[2,2]*p_spatial[2]^2 + ginv[3,3]*p_spatial[3]^2 + ginv[4,4]*p_spatial[4]^2
            pt = -sqrt(max(C * (-1.0/ginv[1,1]), 0.0))
            p = SVec4d(pt, p_spatial[2], p_spatial[3], p_spatial[4])

            # Method 1: Hamiltonian RHS
            _, dp_ham = hamiltonian_rhs(s, x, p)
            dx = ginv * p  # velocity = g^{μν} p_ν

            # Method 2: Christoffel → geodesic acceleration
            # d²x^μ/dλ² = -Γ^μ_{αβ} v^α v^β  where v = dx/dλ
            Γt, Γr, Γθ, Γφ = christoffel(s, x)
            ddx_t = -dot(dx, Γt * dx)
            ddx_r = -dot(dx, Γr * dx)
            ddx_θ = -dot(dx, Γθ * dx)
            ddx_φ = -dot(dx, Γφ * dx)

            # Convert Hamiltonian dp/dλ to d²x/dλ² for comparison:
            # d²x^μ/dλ² = (∂g^{μν}/∂x^σ)(dx^σ/dλ) p_ν + g^{μν} dp_ν/dλ
            partials = metric_inverse_partials(s, x)
            ddx_ham = ginv * dp_ham
            for σ in 1:4
                ddx_ham += dx[σ] * (partials[σ] * p)
            end

            @test ddx_t ≈ ddx_ham[1] rtol=1e-8
            @test ddx_r ≈ ddx_ham[2] rtol=1e-8
            @test ddx_θ ≈ ddx_ham[3] rtol=1e-8
            @test ddx_φ ≈ ddx_ham[4] rtol=1e-8
        end
    end

    @testset "Christoffel: gravitational terms vanish at large r" begin
        # At r → ∞, gravity-dependent Γ^t_{tr} ~ M/r² → 0
        x_far = SVec4d(0.0, 1e8, π/2, 0.0)
        Γt, Γr, _, _ = christoffel(s, x_far)
        @test maximum(abs, Γt) < 1e-8   # Γ^t is purely gravitational
        @test abs(Γr[1,1]) < 1e-8       # Γ^r_{tt} ~ M/r² → 0
        @test abs(Γr[2,2]) < 1e-8       # Γ^r_{rr} ~ M/r² → 0
        # Note: Γ^r_{θθ} = -(r-2M) ≈ -r is a coordinate artifact, not gravitational
    end
end
