@testset "GR Metric Interface" begin
    using Lyr.GR
    using LinearAlgebra: I, det, norm

    @testset "Minkowski metric" begin
        m = Minkowski()
        x = SVec4d(0.0, 1.0, 2.0, 3.0)

        g = metric(m, x)
        @test g[1,1] == -1.0
        @test g[2,2] == 1.0
        @test g[3,3] == 1.0
        @test g[4,4] == 1.0
        # Off-diagonal zero
        @test g[1,2] == 0.0
        @test g[2,3] == 0.0

        ginv = metric_inverse(m, x)
        @test ginv == g  # Minkowski is its own inverse

        @test is_singular(m, x) == false
    end

    @testset "Minkowski: g × g⁻¹ = I" begin
        m = Minkowski()
        x = SVec4d(0.0, 5.0, -3.0, 7.0)
        g = metric(m, x)
        ginv = metric_inverse(m, x)
        @test g * ginv ≈ SMat4d(I)
    end

    @testset "ForwardDiff metric partials: Minkowski (constant → zero)" begin
        m = Minkowski()
        x = SVec4d(1.0, 2.0, 3.0, 4.0)
        partials = metric_inverse_partials(m, x)

        @test length(partials) == 4
        zero_mat = zeros(SMat4d)
        for μ in 1:4
            @test partials[μ] ≈ zero_mat atol=1e-14
        end
    end

    @testset "Hamiltonian: null geodesic in Minkowski" begin
        m = Minkowski()
        x = SVec4d(0.0, 0.0, 0.0, 0.0)

        # Null momentum: p = (-1, 1, 0, 0) satisfies η^μν p_μ p_ν = -(-1)² + 1² = 0
        p_null = SVec4d(-1.0, 1.0, 0.0, 0.0)
        H = hamiltonian(m, x, p_null)
        @test abs(H) < 1e-14

        # Timelike: p = (-2, 1, 0, 0) → H = ½(-4 + 1) = -1.5
        p_time = SVec4d(-2.0, 1.0, 0.0, 0.0)
        H = hamiltonian(m, x, p_time)
        @test H ≈ -1.5

        # General null: p = (-E, px, py, pz) where E² = px² + py² + pz²
        px, py, pz = 0.3, 0.4, 0.0  # E = 0.5
        E = sqrt(px^2 + py^2 + pz^2)
        p_null2 = SVec4d(-E, px, py, pz)
        @test abs(hamiltonian(m, x, p_null2)) < 1e-14
    end

    @testset "Hamilton's equations in Minkowski" begin
        m = Minkowski()
        x = SVec4d(0.0, 1.0, 2.0, 3.0)
        p = SVec4d(-1.0, 0.6, 0.8, 0.0)  # null: 1 = 0.36 + 0.64

        dxdl, dpdl = hamiltonian_rhs(m, x, p)

        # In flat space: dx^μ/dλ = η^μν p_ν = (-p₀, p₁, p₂, p₃) = (1, 0.6, 0.8, 0)
        @test dxdl ≈ SVec4d(1.0, 0.6, 0.8, 0.0)

        # dp_μ/dλ = 0 (flat space, no forces)
        @test norm(dpdl) < 1e-14
    end
end
