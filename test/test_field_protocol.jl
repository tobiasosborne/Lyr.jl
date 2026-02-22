using Test
using StaticArrays

@testset "Field Protocol" begin

    @testset "BoxDomain" begin
        @testset "construction from SVec3d" begin
            d = BoxDomain(SVec3d(-1, -2, -3), SVec3d(4, 5, 6))
            @test d.min == SVec3d(-1, -2, -3)
            @test d.max == SVec3d(4, 5, 6)
        end

        @testset "construction from tuples" begin
            d = BoxDomain((-1.0, -2.0, -3.0), (4.0, 5.0, 6.0))
            @test d.min == SVec3d(-1, -2, -3)
            @test d.max == SVec3d(4, 5, 6)
        end

        @testset "construction from integer tuples" begin
            d = BoxDomain((-1, -2, -3), (4, 5, 6))
            @test d.min == SVec3d(-1, -2, -3)
        end

        @testset "center" begin
            d = BoxDomain((-2.0, -4.0, -6.0), (2.0, 4.0, 6.0))
            @test center(d) == SVec3d(0, 0, 0)
        end

        @testset "center asymmetric" begin
            d = BoxDomain((0.0, 0.0, 0.0), (10.0, 20.0, 30.0))
            @test center(d) == SVec3d(5, 10, 15)
        end

        @testset "extent" begin
            d = BoxDomain((-2.0, -4.0, -6.0), (2.0, 4.0, 6.0))
            @test extent(d) == SVec3d(4, 8, 12)
        end

        @testset "show" begin
            d = BoxDomain((0.0, 0.0, 0.0), (1.0, 1.0, 1.0))
            s = sprint(show, d)
            @test occursin("BoxDomain", s)
        end

        @testset "zero-volume domain" begin
            d = BoxDomain((5.0, 5.0, 5.0), (5.0, 5.0, 5.0))
            @test extent(d) == SVec3d(0, 0, 0)
            @test center(d) == SVec3d(5, 5, 5)
        end
    end

    @testset "ScalarField3D" begin
        f = ScalarField3D(
            (x, y, z) -> x + y + z,
            BoxDomain((-1.0, -1.0, -1.0), (1.0, 1.0, 1.0)),
            0.5
        )

        @testset "evaluate" begin
            @test evaluate(f, 1.0, 2.0, 3.0) == 6.0
            @test evaluate(f, 0.0, 0.0, 0.0) == 0.0
        end

        @testset "domain" begin
            d = domain(f)
            @test d isa BoxDomain
            @test d.min == SVec3d(-1, -1, -1)
        end

        @testset "field_eltype" begin
            @test field_eltype(f) == Float64
        end

        @testset "characteristic_scale" begin
            @test characteristic_scale(f) == 0.5
        end

        @testset "show" begin
            s = sprint(show, f)
            @test occursin("ScalarField3D", s)
        end
    end

    @testset "VectorField3D" begin
        f = VectorField3D(
            (x, y, z) -> SVec3d(x, y, z),
            BoxDomain((-5.0, -5.0, -5.0), (5.0, 5.0, 5.0)),
            1.0
        )

        @testset "evaluate" begin
            v = evaluate(f, 1.0, 2.0, 3.0)
            @test v == SVec3d(1, 2, 3)
            @test v isa SVec3d
        end

        @testset "field_eltype" begin
            @test field_eltype(f) == SVec3d
        end

        @testset "characteristic_scale" begin
            @test characteristic_scale(f) == 1.0
        end
    end

    @testset "ComplexScalarField3D" begin
        f = ComplexScalarField3D(
            (x, y, z) -> complex(x, y),
            BoxDomain((-1.0, -1.0, -1.0), (1.0, 1.0, 1.0)),
            0.2
        )

        @testset "evaluate" begin
            v = evaluate(f, 3.0, 4.0, 0.0)
            @test v == complex(3.0, 4.0)
            @test v isa ComplexF64
        end

        @testset "field_eltype" begin
            @test field_eltype(f) == ComplexF64
        end

        @testset "abs2 for probability density" begin
            v = evaluate(f, 3.0, 4.0, 0.0)
            @test abs2(v) == 25.0
        end
    end

    @testset "ParticleField" begin
        positions = [SVec3d(1, 2, 3), SVec3d(4, 5, 6), SVec3d(-1, -2, -3)]

        @testset "minimal construction" begin
            pf = ParticleField(positions)
            @test length(pf.positions) == 3
            @test pf.velocities === nothing
            @test isempty(pf.properties)
        end

        @testset "with velocities" begin
            vels = [SVec3d(0.1, 0, 0) for _ in 1:3]
            pf = ParticleField(positions; velocities=vels)
            @test length(pf.velocities) == 3
        end

        @testset "with properties" begin
            props = Dict{Symbol, Vector}(:mass => [1.0, 2.0, 3.0])
            pf = ParticleField(positions; properties=props)
            @test pf.properties[:mass] == [1.0, 2.0, 3.0]
        end

        @testset "domain auto-computed" begin
            pf = ParticleField(positions)
            d = domain(pf)
            @test d isa BoxDomain
            # Domain should contain all particles (with padding)
            @test d.min[1] < -1.0
            @test d.max[1] > 4.0
        end

        @testset "field_eltype" begin
            pf = ParticleField(positions)
            @test field_eltype(pf) == SVec3d
        end

        @testset "empty particles" begin
            pf = ParticleField(SVec3d[])
            d = domain(pf)
            @test d isa BoxDomain  # Should not error
        end

        @testset "show" begin
            pf = ParticleField(positions)
            s = sprint(show, pf)
            @test occursin("3 particles", s)
        end
    end

    @testset "TimeEvolution" begin
        te = TimeEvolution{ScalarField3D}(
            t -> ScalarField3D(
                (x, y, z) -> exp(-(x^2 + y^2 + z^2)) * cos(t),
                BoxDomain((-3.0, -3.0, -3.0), (3.0, 3.0, 3.0)),
                1.0
            ),
            (0.0, 6.28),
            0.1
        )

        @testset "construction" begin
            @test te.t_range == (0.0, 6.28)
            @test te.dt_hint == 0.1
        end

        @testset "eval_fn returns field" begin
            f = te.eval_fn(0.0)
            @test f isa ScalarField3D
            @test evaluate(f, 0.0, 0.0, 0.0) ≈ 1.0
        end

        @testset "eval_fn at t=pi" begin
            f = te.eval_fn(π)
            @test evaluate(f, 0.0, 0.0, 0.0) ≈ -1.0 atol=1e-10
        end

        @testset "domain delegates" begin
            d = domain(te)
            @test d isa BoxDomain
        end

        @testset "show" begin
            s = sprint(show, te)
            @test occursin("TimeEvolution", s)
        end
    end
end
