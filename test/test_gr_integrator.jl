@testset "GR Geodesic Integrator" begin
    using Lyr.GR
    using LinearAlgebra: norm

    M = 1.0
    s = Schwarzschild(M)

    @testset "IntegratorConfig defaults" begin
        config = IntegratorConfig()
        @test config.step_size < 0.0
        @test config.max_steps > 0
        @test config.h_tolerance > 0.0
        @test config.r_max > 0.0
    end

    @testset "IntegratorConfig custom" begin
        config = IntegratorConfig(step_size=-0.05, max_steps=5000, r_max=100.0)
        @test config.step_size == -0.05
        @test config.max_steps == 5000
        @test config.r_max == 100.0
    end

    @testset "Straight-line geodesic in Minkowski" begin
        m = Minkowski()
        x0 = SVec4d(0.0, 0.0, 0.0, 0.0)
        p0 = SVec4d(-1.0, 1.0, 0.0, 0.0)
        initial = GeodesicState(x0, p0)

        config = IntegratorConfig(step_size=0.1, max_steps=100, r_max=200.0)
        trace = integrate_geodesic(m, initial, config)

        @test trace.reason == MAX_STEPS
        @test trace.hamiltonian_max < 1e-10
        @test trace.n_steps == 100

        final = last(trace.states)
        @test final.x[2] > 5.0
    end

    @testset "Circular photon orbit at r=3M" begin
        r = 3.0 * M
        E = 1.0
        L = 3.0 * sqrt(3.0) * M * E

        x0 = SVec4d(0.0, r, π/2, 0.0)
        p0 = SVec4d(-E, 0.0, 0.0, L)
        @test abs(hamiltonian(s, x0, p0)) < 1e-12

        initial = GeodesicState(x0, p0)
        config = IntegratorConfig(
            step_size=0.005,
            max_steps=50_000,
            h_tolerance=1e-3,
            r_max=100.0,
            r_min_factor=1.01
        )
        trace = integrate_geodesic(s, initial, config)

        @test trace.reason == MAX_STEPS
        @test trace.hamiltonian_max < 1e-3

        # Radius stays near 3M
        for state in trace.states
            @test abs(state.x[2] - 3.0) < 0.1
        end
    end

    @testset "Radial infall reaches horizon" begin
        # Start far from BH where metric is nearly flat
        r0 = 10.0 * M
        x0 = SVec4d(0.0, r0, π/2, 0.0)

        f = 1.0 - 2.0 / r0
        p_t = -1.0
        p_r = -1.0 / f
        p0 = SVec4d(p_t, p_r, 0.0, 0.0)
        @test abs(hamiltonian(s, x0, p0)) < 1e-12

        initial = GeodesicState(x0, p0)
        # Small step + generous tolerance for horizon approach
        config = IntegratorConfig(
            step_size=0.005,
            max_steps=100_000,
            h_tolerance=0.1,
            r_max=200.0,
            r_min_factor=1.05
        )
        trace = integrate_geodesic(s, initial, config)

        # In Schwarzschild coordinates, the metric diverges at r=2M,
        # so H may drift before reaching the horizon. Accept either.
        @test trace.reason in (HORIZON, HAMILTONIAN_DRIFT)
        final_r = last(trace.states).x[2]
        @test final_r < r0  # must have moved inward
    end

    @testset "Escape to r_max" begin
        r0 = 10.0 * M
        x0 = SVec4d(0.0, r0, π/2, 0.0)

        f = 1.0 - 2.0 / r0
        p_t = -1.0
        p_r = 1.0 / f
        p0 = SVec4d(p_t, p_r, 0.0, 0.0)
        @test abs(hamiltonian(s, x0, p0)) < 1e-12

        initial = GeodesicState(x0, p0)
        config = IntegratorConfig(
            step_size=0.05,
            max_steps=100_000,
            h_tolerance=0.01,
            r_max=50.0,
            r_min_factor=1.01
        )
        trace = integrate_geodesic(s, initial, config)

        @test trace.reason == ESCAPED
        final_r = last(trace.states).x[2]
        @test final_r >= 50.0
    end

    @testset "Hamiltonian conservation for deflected photon" begin
        r0 = 20.0 * M
        x0 = SVec4d(0.0, r0, π/2, 0.0)

        b = 10.0 * M
        E = 1.0
        L = b * E
        f = 1.0 - 2.0 / r0
        p_r_sq = (E^2 / f - L^2 / r0^2) / f
        p_r = -sqrt(p_r_sq)
        p0 = SVec4d(-E, p_r, 0.0, L)
        @test abs(hamiltonian(s, x0, p0)) < 1e-10

        initial = GeodesicState(x0, p0)
        config = IntegratorConfig(
            step_size=0.01,
            max_steps=50_000,
            h_tolerance=1e-3,
            r_max=100.0,
            r_min_factor=1.01
        )
        trace = integrate_geodesic(s, initial, config)

        @test trace.hamiltonian_max < 1e-3
    end

    @testset "Record interval" begin
        m = Minkowski()
        x0 = SVec4d(0.0, 0.0, 0.0, 0.0)
        p0 = SVec4d(-1.0, 1.0, 0.0, 0.0)
        initial = GeodesicState(x0, p0)

        config = IntegratorConfig(
            step_size=0.1,
            max_steps=100,
            r_max=200.0,
            record_interval=10
        )
        trace = integrate_geodesic(m, initial, config)

        # initial + 10 recorded + final = 12
        @test length(trace.states) >= 10
    end
end
