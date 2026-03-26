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

    @testset "RK4 step: Minkowski straight line" begin
        m = Minkowski()
        x0 = SVec4d(0.0, 1.0, 0.0, 0.0)
        p0 = SVec4d(-1.0, 1.0, 0.0, 0.0)
        x1, p1 = rk4_step(m, x0, p0, 0.1)
        # In flat space: x_new = x + dl * ginv * p, p unchanged
        @test x1[2] ≈ 1.1 atol=1e-12   # x moves by dl * k^x
        @test p1 ≈ p0 atol=1e-12         # no curvature → p unchanged
    end

    @testset "RK4 vs Verlet: accuracy on deflected photon" begin
        # Deflected photon grazing photon sphere — strong curvature stresses
        # the integrator. Use a coarse step size with NO renormalization to
        # expose the 4th-vs-2nd order accuracy difference.
        r0 = 20.0 * M
        b = 6.0 * M   # impact parameter close to critical (3√3 ≈ 5.196)
        E = 1.0
        L = b * E
        f = 1.0 - 2.0 / r0
        p_r_sq = (E^2 / f - L^2 / r0^2) / f
        p_r = -sqrt(abs(p_r_sq))
        x0 = SVec4d(0.0, r0, π/2, 0.0)
        p0 = SVec4d(-E, p_r, 0.0, L)

        initial = GeodesicState(x0, p0)

        # Coarse step, no renormalization, generous tolerance so neither terminates early
        cfg_rk4 = IntegratorConfig(
            step_size=-0.5, max_steps=2000, h_tolerance=10.0,
            r_max=100.0, r_min_factor=0.5, stepper=RK4(), renorm_interval=0
        )
        cfg_verlet = IntegratorConfig(
            step_size=-0.5, max_steps=2000, h_tolerance=10.0,
            r_max=100.0, r_min_factor=0.5, stepper=Verlet(), renorm_interval=0
        )

        trace_rk4 = integrate_geodesic(s, initial, cfg_rk4)
        trace_verlet = integrate_geodesic(s, initial, cfg_verlet)

        # RK4 should have lower H drift than Verlet at this coarse step size
        @test trace_rk4.hamiltonian_max <= trace_verlet.hamiltonian_max
        # RK4 with dl=0.5 should still be reasonably accurate
        @test trace_rk4.hamiltonian_max < 0.1
    end

    @testset "RK4: deflected photon escapes" begin
        # Same test as Verlet escape, but with RK4
        r0 = 20.0 * M
        x0 = SVec4d(0.0, r0, π/2, 0.0)
        b = 10.0 * M
        E = 1.0
        L = b * E
        f = 1.0 - 2.0 / r0
        p_r_sq = (E^2 / f - L^2 / r0^2) / f
        p_r = -sqrt(p_r_sq)
        p0 = SVec4d(-E, p_r, 0.0, L)

        initial = GeodesicState(x0, p0)
        config = IntegratorConfig(
            step_size=-0.1, max_steps=5000, h_tolerance=1e-6,
            r_max=100.0, r_min_factor=1.01, stepper=RK4()
        )
        trace = integrate_geodesic(s, initial, config)

        @test trace.reason == ESCAPED
        @test trace.hamiltonian_max < 1e-6
    end

    @testset "Stepper config: verlet fallback" begin
        # Verify verlet still works when explicitly requested
        m = Minkowski()
        x0 = SVec4d(0.0, 0.0, 0.0, 0.0)
        p0 = SVec4d(-1.0, 1.0, 0.0, 0.0)
        initial = GeodesicState(x0, p0)
        config = IntegratorConfig(step_size=0.1, max_steps=50, r_max=200.0, stepper=Verlet())
        trace = integrate_geodesic(m, initial, config)
        @test trace.reason == MAX_STEPS
        @test trace.hamiltonian_max < 1e-10
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

    @testset "adaptive_step: near horizon vs far field" begin
        # Near horizon (r=2.5M): step should be small
        dl_near = adaptive_step(-0.5, 2.5, M)
        # Far field (r=50M): step should be near base
        dl_far = adaptive_step(-0.5, 50.0, M)
        @test abs(dl_near) < abs(dl_far)
        @test abs(dl_far) ≈ 0.5 atol=0.05  # nearly full step in far field
        # At r=2M (horizon): step = 0.05 × base (minimum clamp)
        dl_horizon = adaptive_step(-0.5, 2.0 + 1e-6, M)
        @test abs(dl_horizon) ≈ 0.05 * 0.5 atol=0.01
    end

    @testset "renormalize_null: preserves H=0" begin
        # Start with a null geodesic, perturb p_t, renormalize
        x = SVec4d(0.0, 10.0, π/2, 0.0)
        p = SVec4d(-1.0, 0.3, 0.2, 0.5)
        # Renormalize to null
        p_null = renormalize_null(s, x, p)
        H = hamiltonian(s, x, p_null)
        @test abs(H) < 1e-12

        # Test with Kerr
        k = Kerr(1.0, 0.7)
        xk = SVec4d(0.0, 8.0, π/3, 0.0)
        pk = SVec4d(-1.0, 0.4, -0.3, 0.6)
        pk_null = renormalize_null(k, xk, pk)
        Hk = hamiltonian(k, xk, pk_null)
        @test abs(Hk) < 1e-12

        # Sign preservation
        @test sign(pk_null[1]) == sign(pk[1])
    end

    @testset "rk4_step: Minkowski straight line" begin
        # In flat space, geodesics are straight lines
        m_flat = Minkowski()
        x = SVec4d(0.0, 1.0, 2.0, 3.0)
        p = SVec4d(-1.0, 0.5, 0.3, 0.1)  # null in Minkowski: -1² + 0.5² + 0.3² + 0.1² = -0.65 ≠ 0
        # Make null: p_t = √(p_r² + p_θ² + p_φ²)
        pt = -sqrt(p[2]^2 + p[3]^2 + p[4]^2)
        p = SVec4d(pt, p[2], p[3], p[4])

        dl = -0.1
        x_new, p_new = rk4_step(m_flat, x, p, dl)
        # In Minkowski: dx/dλ = g^{μν}p_ν = p^μ (since g = η)
        # With covariant p: g^{μν}p_ν = (-p_t, p_r, p_θ, p_φ)
        expected_v = SVec4d(-pt, p[2], p[3], p[4])
        x_expected = x + dl * expected_v
        @test norm(x_new - x_expected) < 1e-12
        # Momentum unchanged in flat space
        @test norm(p_new - p) < 1e-12
    end

    @testset "verlet_step: Minkowski straight line" begin
        m_flat = Minkowski()
        x = SVec4d(0.0, 1.0, 2.0, 3.0)
        pt = -sqrt(0.5^2 + 0.3^2 + 0.1^2)
        p = SVec4d(pt, 0.5, 0.3, 0.1)
        dl = -0.1
        x_new, p_new = verlet_step(m_flat, x, p, dl)
        expected_v = SVec4d(-pt, p[2], p[3], p[4])
        x_expected = x + dl * expected_v
        @test norm(x_new - x_expected) < 1e-10
        @test norm(p_new - p) < 1e-10
    end

    @testset "WeakField stub throws informative error" begin
        wf = WeakField()
        x = SVec4d(0.0, 0.0, 0.0, 0.0)
        @test_throws ErrorException metric(wf, x)
        @test_throws ErrorException metric_inverse(wf, x)
        @test is_singular(wf, x) == false
    end
end
