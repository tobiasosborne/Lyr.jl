using Test
using Lyr
using Lyr: SVec3d, BoxDomain, VectorField3D, evaluate, advect_points
using StaticArrays

@testset "Point Advection" begin

    @testset "uniform velocity — exact translation (euler)" begin
        vfield = VectorField3D(
            (x, y, z) -> SVec3d(1.0, 2.0, -0.5),
            BoxDomain(SVec3d(-100, -100, -100), SVec3d(100, 100, 100)),
            1.0
        )
        pos = [(0.0, 0.0, 0.0), (3.0, -1.0, 5.0)]
        dt = 0.25
        result = advect_points(pos, vfield, dt; method=:euler)

        @test result[1] == (0.25, 0.5, -0.125)
        @test result[2] == (3.25, -0.5, 4.875)
    end

    @testset "uniform velocity — exact translation (rk4)" begin
        vfield = VectorField3D(
            (x, y, z) -> SVec3d(1.0, 2.0, -0.5),
            BoxDomain(SVec3d(-100, -100, -100), SVec3d(100, 100, 100)),
            1.0
        )
        pos = [(0.0, 0.0, 0.0), (3.0, -1.0, 5.0)]
        dt = 0.25
        result = advect_points(pos, vfield, dt; method=:rk4)

        # For uniform fields, RK4 gives exact same result as Euler
        @test result[1][1] ≈ 0.25 atol=1e-14
        @test result[1][2] ≈ 0.5 atol=1e-14
        @test result[1][3] ≈ -0.125 atol=1e-14
        @test result[2][1] ≈ 3.25 atol=1e-14
        @test result[2][2] ≈ -0.5 atol=1e-14
        @test result[2][3] ≈ 4.875 atol=1e-14
    end

    @testset "circular orbit — RK4 preserves radius" begin
        # v = (-y, x, 0) gives circular orbits with angular velocity 1
        vfield = VectorField3D(
            (x, y, z) -> SVec3d(-y, x, 0.0),
            BoxDomain(SVec3d(-50, -50, -50), SVec3d(50, 50, 50)),
            1.0
        )
        r0 = 5.0
        pos = [(r0, 0.0, 0.0)]
        dt = 0.01
        nsteps = 1000  # full revolution: 2*pi / (1.0 * dt) ~ 628 steps, so 1000 > full circle

        current = pos
        for _ in 1:nsteps
            current = advect_points(current, vfield, dt; method=:rk4)
        end

        # After many steps, radius should be very well preserved by RK4
        final_r = sqrt(current[1][1]^2 + current[1][2]^2)
        @test abs(final_r - r0) < 1e-6

        # z should remain zero
        @test abs(current[1][3]) < 1e-14
    end

    @testset "Euler vs RK4 accuracy — circular orbit" begin
        vfield = VectorField3D(
            (x, y, z) -> SVec3d(-y, x, 0.0),
            BoxDomain(SVec3d(-50, -50, -50), SVec3d(50, 50, 50)),
            1.0
        )
        r0 = 5.0
        pos = [(r0, 0.0, 0.0)]
        dt = 0.01
        nsteps = 314  # roughly half revolution

        euler_pos = pos
        rk4_pos = pos
        for _ in 1:nsteps
            euler_pos = advect_points(euler_pos, vfield, dt; method=:euler)
            rk4_pos = advect_points(rk4_pos, vfield, dt; method=:rk4)
        end

        euler_r = sqrt(euler_pos[1][1]^2 + euler_pos[1][2]^2)
        rk4_r = sqrt(rk4_pos[1][1]^2 + rk4_pos[1][2]^2)

        euler_err = abs(euler_r - r0)
        rk4_err = abs(rk4_r - r0)

        # RK4 should be orders of magnitude more accurate than Euler
        @test rk4_err < euler_err
        @test rk4_err < 1e-6
        @test euler_err > 1e-3  # Euler drifts significantly
    end

    @testset "empty positions — empty result" begin
        vfield = VectorField3D(
            (x, y, z) -> SVec3d(1.0, 0.0, 0.0),
            BoxDomain(SVec3d(-10, -10, -10), SVec3d(10, 10, 10)),
            1.0
        )
        result = advect_points(NTuple{3,Float64}[], vfield, 0.1)
        @test isempty(result)
        @test result isa Vector{NTuple{3,Float64}}
    end

    @testset "unknown method throws ArgumentError" begin
        vfield = VectorField3D(
            (x, y, z) -> SVec3d(1.0, 0.0, 0.0),
            BoxDomain(SVec3d(-10, -10, -10), SVec3d(10, 10, 10)),
            1.0
        )
        @test_throws Exception advect_points([(0.0, 0.0, 0.0)], vfield, 0.1; method=:midpoint)
    end

    @testset "accepts SVec3d positions" begin
        vfield = VectorField3D(
            (x, y, z) -> SVec3d(1.0, 0.0, 0.0),
            BoxDomain(SVec3d(-10, -10, -10), SVec3d(10, 10, 10)),
            1.0
        )
        pos = [SVec3d(0.0, 0.0, 0.0)]
        result = advect_points(pos, vfield, 1.0; method=:euler)
        @test result[1] == (1.0, 0.0, 0.0)
    end

    @testset "multiple particles advected independently" begin
        # Linear velocity: v = (x, 0, 0) — exponential growth
        vfield = VectorField3D(
            (x, y, z) -> SVec3d(x, 0.0, 0.0),
            BoxDomain(SVec3d(-100, -100, -100), SVec3d(100, 100, 100)),
            1.0
        )
        pos = [(1.0, 0.0, 0.0), (2.0, 0.0, 0.0)]
        dt = 0.001
        nsteps = 100

        current = pos
        for _ in 1:nsteps
            current = advect_points(current, vfield, dt; method=:rk4)
        end

        # Analytical: x(t) = x0 * exp(t), t = 0.1
        t = dt * nsteps
        @test current[1][1] ≈ 1.0 * exp(t) atol=1e-8
        @test current[2][1] ≈ 2.0 * exp(t) atol=1e-8
    end
end
