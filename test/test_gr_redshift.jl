@testset "GR Redshift" begin
    using Lyr.GR
    using LinearAlgebra: dot

    M = 1.0
    s = Schwarzschild(M)

    @testset "Static observer gravitational redshift" begin
        # Photon emitted at r_emit by static observer, received at r_obs by static observer
        # 1 + z = √(f_obs / f_emit) where f = 1 - 2M/r

        for (r_emit, r_obs) in [(5.0, 100.0), (10.0, 50.0), (3.0, 20.0)]
            f_emit = 1.0 - 2.0 * M / r_emit
            f_obs = 1.0 - 2.0 * M / r_obs

            # Static observer 4-velocity: u^μ = (1/√f, 0, 0, 0)
            u_emit = SVec4d(1.0 / sqrt(f_emit), 0.0, 0.0, 0.0)
            u_obs = SVec4d(1.0 / sqrt(f_obs), 0.0, 0.0, 0.0)

            # Radial null geodesic: p_t = -E (constant along geodesic)
            # p_μ u^μ = p_t × u^t = -E / √f
            # So (1+z) = √f_obs / √f_emit × 1 = √(f_obs/f_emit)
            #
            # But redshift_factor computes (p·u)_emit / (p·u)_obs
            # = (-E/√f_emit) / (-E/√f_obs) = √f_obs / √f_emit
            expected_z = sqrt(f_obs / f_emit) - 1.0

            p = SVec4d(-1.0, 0.0, 0.0, 0.0)  # constant p_t along radial geodesic
            z_plus_1 = redshift_factor(p, u_emit, p, u_obs)
            @test (z_plus_1 - 1.0) ≈ expected_z atol=1e-10
        end
    end

    @testset "Same-point redshift is unity" begin
        r = 10.0
        f = 1.0 - 2.0 / r
        u = SVec4d(1.0 / sqrt(f), 0.0, 0.0, 0.0)
        p = SVec4d(-1.0, 0.5, 0.0, 0.1)

        z_plus_1 = redshift_factor(p, u, p, u)
        @test z_plus_1 ≈ 1.0 atol=1e-14
    end

    @testset "Temperature shift" begin
        @test temperature_shift(1000.0, 1.0) ≈ 500.0
        @test temperature_shift(1000.0, 0.0) ≈ 1000.0
    end

    @testset "Blackbody color" begin
        c = blackbody_color(0.0)
        @test c == (0.0, 0.0, 0.0)

        c1 = blackbody_color(0.5)
        @test c1[1] == 1.0  # R saturated
        @test c1[2] > 0.0

        c2 = blackbody_color(1.5)
        @test all(x -> x > 0.0, c2)
    end

    @testset "Doppler color" begin
        base = (0.8, 0.6, 0.4)
        # No shift
        @test doppler_color(base, 0.0) == base
        # Blueshift brightens
        blue = doppler_color(base, -0.5)
        @test blue[1] >= base[1]
    end
end
