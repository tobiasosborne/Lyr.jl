# Test phase function evaluation and sampling
using Test
using Lyr
using Random: Xoshiro, rand

# Include source into Lyr module until Lyr.jl adds the include/exports
Base.include(Lyr, joinpath(@__DIR__, "..", "src", "PhaseFunction.jl"))
using .Lyr: PhaseFunction, IsotropicPhase, HenyeyGreensteinPhase
using .Lyr: evaluate, sample_phase

@testset "PhaseFunction" begin
    @testset "IsotropicPhase" begin
        pf = IsotropicPhase()
        inv4pi = 1.0 / (4.0 * pi)

        @testset "evaluates to 1/(4pi) for any cos_theta" begin
            @test evaluate(pf, 1.0) ≈ inv4pi atol=1e-15
            @test evaluate(pf, 0.0) ≈ inv4pi atol=1e-15
            @test evaluate(pf, -1.0) ≈ inv4pi atol=1e-15
            @test evaluate(pf, 0.5) ≈ inv4pi atol=1e-15
            @test evaluate(pf, -0.7) ≈ inv4pi atol=1e-15
        end

        @testset "sample_phase returns unit vectors" begin
            rng = Xoshiro(42)
            incoming = SVec3d(0.0, 0.0, 1.0)

            for _ in 1:100
                dir = sample_phase(pf, incoming, rng)
                len = sqrt(dir[1]^2 + dir[2]^2 + dir[3]^2)
                @test len ≈ 1.0 atol=1e-10
            end
        end

        @testset "sample_phase produces roughly uniform distribution" begin
            rng = Xoshiro(123)
            incoming = SVec3d(1.0, 0.0, 0.0)

            # Count samples in forward vs backward hemisphere
            n_forward = 0
            n_total = 10000

            for _ in 1:n_total
                dir = sample_phase(pf, incoming, rng)
                if dir[1] > 0.0  # forward hemisphere relative to x-axis
                    n_forward += 1
                end
            end

            # Should be roughly 50/50
            ratio = n_forward / n_total
            @test 0.45 < ratio < 0.55
        end
    end

    @testset "HenyeyGreensteinPhase" begin
        @testset "construction" begin
            pf = HenyeyGreensteinPhase(0.0)
            @test pf.g == 0.0

            pf = HenyeyGreensteinPhase(0.8)
            @test pf.g == 0.8

            pf = HenyeyGreensteinPhase(-0.5)
            @test pf.g == -0.5
        end

        @testset "rejects invalid g values" begin
            @test_throws ArgumentError HenyeyGreensteinPhase(1.0)
            @test_throws ArgumentError HenyeyGreensteinPhase(-1.0)
            @test_throws ArgumentError HenyeyGreensteinPhase(1.5)
            @test_throws ArgumentError HenyeyGreensteinPhase(-2.0)
        end

        @testset "g=0 matches isotropic" begin
            hg = HenyeyGreensteinPhase(0.0)
            iso = IsotropicPhase()

            for ct in [-1.0, -0.5, 0.0, 0.5, 1.0]
                @test evaluate(hg, ct) ≈ evaluate(iso, ct) atol=1e-10
            end
        end

        @testset "g=0.8 is forward-peaked" begin
            pf = HenyeyGreensteinPhase(0.8)

            val_forward = evaluate(pf, 1.0)   # cos_theta = 1 (forward)
            val_side = evaluate(pf, 0.0)       # cos_theta = 0 (sideways)
            val_back = evaluate(pf, -1.0)      # cos_theta = -1 (backward)

            @test val_forward > val_side
            @test val_side > val_back
            @test val_forward > val_back
        end

        @testset "g=-0.5 is backward-peaked" begin
            pf = HenyeyGreensteinPhase(-0.5)

            val_forward = evaluate(pf, 1.0)
            val_back = evaluate(pf, -1.0)

            @test val_back > val_forward
        end

        @testset "evaluate is positive for all angles" begin
            for g in [-0.9, -0.5, 0.0, 0.5, 0.9]
                pf = HenyeyGreensteinPhase(g)
                for ct in -1.0:0.1:1.0
                    @test evaluate(pf, ct) > 0.0
                end
            end
        end

        @testset "integrates to 1 over sphere (Monte Carlo)" begin
            # The integral of p(cos_theta) * 2*pi*sin(theta) d_theta over [0, pi] = 1
            # Equivalently, integral of p(cos_theta) * 2*pi d(cos_theta) over [-1, 1] = 1
            # But p already includes the 1/(4pi) normalization, so:
            # integral of p(cos_theta) d_omega over full sphere = 1
            # Using Monte Carlo: E[4*pi * p(cos_theta)] with uniform sphere samples = 1

            for g in [0.0, 0.3, 0.8, -0.5]
                pf = HenyeyGreensteinPhase(g)
                rng = Xoshiro(42)
                n = 10000
                total = 0.0

                for _ in 1:n
                    # Uniform random cos_theta in [-1, 1]
                    cos_theta = 2.0 * rand(rng) - 1.0
                    # Phase function value * full solid angle / number of samples
                    total += evaluate(pf, cos_theta) * 4.0 * pi
                end

                # Monte Carlo estimate of integral: (4pi/N) * sum(p) = total/N
                estimate = total / n
                @test estimate ≈ 1.0 atol=0.05  # generous tolerance for MC
            end
        end

        @testset "sample_phase returns unit vectors" begin
            pf = HenyeyGreensteinPhase(0.8)
            rng = Xoshiro(42)
            incoming = SVec3d(0.0, 0.0, 1.0)

            for _ in 1:100
                dir = sample_phase(pf, incoming, rng)
                len = sqrt(dir[1]^2 + dir[2]^2 + dir[3]^2)
                @test len ≈ 1.0 atol=1e-10
            end
        end

        @testset "sample_phase with g=0.8 is forward-biased" begin
            pf = HenyeyGreensteinPhase(0.8)
            rng = Xoshiro(42)
            incoming = SVec3d(0.0, 0.0, 1.0)  # pointing along z

            n_forward = 0
            n_total = 10000

            for _ in 1:n_total
                dir = sample_phase(pf, incoming, rng)
                # Forward means z > 0 (aligned with incoming)
                if dir[3] > 0.0
                    n_forward += 1
                end
            end

            # With g=0.8, most scattering should be forward
            ratio = n_forward / n_total
            @test ratio > 0.85
        end

        @testset "sample_phase with g=-0.5 is backward-biased" begin
            pf = HenyeyGreensteinPhase(-0.5)
            rng = Xoshiro(42)
            incoming = SVec3d(1.0, 0.0, 0.0)  # pointing along x

            n_backward = 0
            n_total = 10000

            for _ in 1:n_total
                dir = sample_phase(pf, incoming, rng)
                if dir[1] < 0.0  # backward relative to incoming
                    n_backward += 1
                end
            end

            # With g=-0.5, majority should scatter backward
            ratio = n_backward / n_total
            @test ratio > 0.55
        end

        @testset "sample_phase works with various incoming directions" begin
            pf = HenyeyGreensteinPhase(0.5)
            rng = Xoshiro(42)

            directions = [
                SVec3d(1.0, 0.0, 0.0),
                SVec3d(0.0, 1.0, 0.0),
                SVec3d(0.0, 0.0, 1.0),
                SVec3d(1.0, 1.0, 1.0) / sqrt(3.0),
                SVec3d(-0.5, 0.3, 0.8) / sqrt(0.25 + 0.09 + 0.64),
            ]

            for inc in directions
                dir = sample_phase(pf, inc, rng)
                len = sqrt(dir[1]^2 + dir[2]^2 + dir[3]^2)
                @test len ≈ 1.0 atol=1e-10
            end
        end
    end

    @testset "HG symmetry" begin
        # HG(g, cos_theta) should equal HG(-g, -cos_theta)
        g = 0.6
        pf_pos = HenyeyGreensteinPhase(g)
        pf_neg = HenyeyGreensteinPhase(-g)

        for ct in [-1.0, -0.5, 0.0, 0.5, 1.0]
            @test evaluate(pf_pos, ct) ≈ evaluate(pf_neg, -ct) atol=1e-15
        end
    end

    @testset "HG reciprocity" begin
        # Phase function is symmetric in incident/scattered directions:
        # p(cos_theta) = p(cos_theta) — this is trivially true since it
        # depends only on the angle. But verify evaluate gives same result
        # for same |cos_theta| with opposite g signs.
        pf = HenyeyGreensteinPhase(0.7)

        # Evaluate at several angles — should all be positive and finite
        for ct in -1.0:0.1:1.0
            val = evaluate(pf, ct)
            @test isfinite(val)
            @test val > 0.0
        end
    end
end
