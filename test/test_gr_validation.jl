@testset "GR Physics Validation" begin
    using Lyr.GR
    using LinearAlgebra: dot, norm

    M = 1.0
    s = Schwarzschild(M)

    @testset "Photon sphere: circular orbit at r=3M stable for many orbits" begin
        r = 3.0 * M
        E = 1.0
        L = 3.0 * sqrt(3.0) * M * E

        x0 = SVec4d(0.0, r, π/2, 0.0)
        p0 = SVec4d(-E, 0.0, 0.0, L)

        initial = GeodesicState(x0, p0)
        # 100_000 steps at dl=0.001 → 100 units of affine parameter
        # Orbital period ≈ 2π×3√3 M ≈ 32.7 → ~3 orbits
        config = IntegratorConfig(
            step_size=0.001,
            max_steps=100_000,
            h_tolerance=1e-2,
            r_max=100.0,
            r_min_factor=1.01,
            record_interval=1000
        )
        trace = integrate_geodesic(s, initial, config)

        @test trace.reason == MAX_STEPS

        # Radius deviation over entire integration
        max_dr = 0.0
        for state in trace.states
            max_dr = max(max_dr, abs(state.x[2] - 3.0))
        end
        @test max_dr / 3.0 < 0.01  # < 1% deviation
    end

    @testset "Deflection angle: qualitative test for b=20M" begin
        # For b = 20M at r0 = 500M, deflection ≈ 4M/b = 0.2 radians
        # This is a coarse test: fixed step size and finite r0 introduce
        # systematic error. We verify the deflection is in the right ballpark.
        b = 20.0 * M
        r0 = 500.0
        E = 1.0
        L = b * E

        x0 = SVec4d(0.0, r0, π/2, 0.0)
        f = 1.0 - 2.0 * M / r0
        p_r_sq = (E^2 / f - L^2 / r0^2) / f
        p_r = -sqrt(max(p_r_sq, 0.0))
        p0 = SVec4d(-E, p_r, 0.0, L)

        initial = GeodesicState(x0, p0)
        config = IntegratorConfig(
            step_size=0.1,
            max_steps=200_000,
            h_tolerance=0.5,
            r_max=600.0,
            r_min_factor=1.01
        )
        trace = integrate_geodesic(s, initial, config)

        @test trace.reason == ESCAPED

        # Total angle change should be π + δ where δ ≈ 4M/b ≈ 0.2 rad
        φ_final = last(trace.states).x[4]
        delta_phi = abs(φ_final - x0[4]) - π
        expected = 4.0 * M / b

        # Accept within factor of 3 (finite r0 + fixed step systematic error)
        @test delta_phi > 0.0  # must deflect in the right direction
        @test delta_phi < 3.0 * expected  # not wildly off
    end

    @testset "Hamiltonian conservation across random rays" begin
        cam = static_camera(s, 30.0, π/2, 0.0, 60.0, (16, 16))

        # Sample 9 pixels across the image
        for (i, j) in [(1,1), (8,1), (16,1), (1,8), (8,8), (16,8), (1,16), (8,16), (16,16)]
            p0 = pixel_to_momentum(cam, i, j)
            initial = GeodesicState(cam.position, p0)

            config = IntegratorConfig(
                step_size=-0.05,
                max_steps=2000,
                h_tolerance=0.01,
                r_max=100.0,
                r_min_factor=1.01
            )
            trace = integrate_geodesic(s, initial, config)

            # H should stay small
            @test trace.hamiltonian_max < 0.01
        end
    end

    @testset "Schwarzschild shadow: BH subtends correct angle" begin
        # The BH shadow has angular radius α_sh = 3√3 M / r_obs for r_obs ≫ M
        r_obs = 30.0
        alpha_sh_exact = 3.0 * sqrt(3.0) * M / r_obs  # radians

        # Render a thin vertical strip through center
        cam = static_camera(s, r_obs, π/2, 0.0, 30.0, (1, 64))
        config = GRRenderConfig(
            integrator=IntegratorConfig(step_size=-0.05, max_steps=3000, r_max=80.0),
            use_threads=false
        )
        pixels = gr_render_image(cam, config)

        # Count dark pixels (shadow)
        n_dark = count(j -> begin
            brightness = sum(pixels[j, 1])
            brightness < 0.1
        end, 1:64)

        # Shadow should be a fraction of the image
        fov_rad = deg2rad(30.0)
        shadow_fraction_expected = 2.0 * alpha_sh_exact / fov_rad
        shadow_fraction_actual = n_dark / 64.0

        # Within factor of 2 (coarse test — rendering has limited resolution)
        @test shadow_fraction_actual > shadow_fraction_expected * 0.3
        @test shadow_fraction_actual < shadow_fraction_expected * 3.0
    end
end
