@testset "GR Types" begin
    using Lyr.GR
    using StaticArrays

    @testset "SVec4d and SMat4d aliases" begin
        v = SVec4d(1.0, 2.0, 3.0, 4.0)
        @test v isa SVector{4, Float64}
        @test v[1] == 1.0
        @test v[4] == 4.0
        @test length(v) == 4

        m = SMat4d(
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0
        )
        @test m isa SMatrix{4, 4, Float64, 16}
        @test m * v == v
    end

    @testset "TerminationReason enum" begin
        @test ESCAPED isa TerminationReason
        @test HORIZON isa TerminationReason
        @test SINGULARITY isa TerminationReason
        @test MAX_STEPS isa TerminationReason
        @test HAMILTONIAN_DRIFT isa TerminationReason
        @test DISK_HIT isa TerminationReason
    end

    @testset "GeodesicState" begin
        x = SVec4d(0.0, 10.0, π/2, 0.0)
        p = SVec4d(-1.0, 0.5, 0.0, 0.1)
        state = GeodesicState(x, p)

        @test state.x === x
        @test state.p === p
        @test state.x[2] == 10.0
        @test state.p[1] == -1.0
    end

    @testset "GeodesicTrace" begin
        x = SVec4d(0.0, 10.0, π/2, 0.0)
        p = SVec4d(-1.0, 0.5, 0.0, 0.1)
        states = [GeodesicState(x, p)]

        trace = GeodesicTrace(states, ESCAPED, 1e-10, 42)
        @test trace.reason == ESCAPED
        @test trace.hamiltonian_max == 1e-10
        @test trace.n_steps == 42
        @test length(trace.states) == 1
    end
end
