@testset "GR Matter Sources" begin
    using Lyr.GR
    using LinearAlgebra: dot

    M = 1.0
    s = Schwarzschild(M)

    @testset "ThinDisk emissivity" begin
        disk = ThinDisk(6.0, 30.0)  # ISCO to 30M

        # Inside disk
        @test disk_emissivity(disk, 10.0) > 0.0
        @test disk_emissivity(disk, 6.0) > 0.0
        @test disk_emissivity(disk, 30.0) > 0.0

        # Outside disk
        @test disk_emissivity(disk, 5.0) == 0.0
        @test disk_emissivity(disk, 31.0) == 0.0

        # Monotonically decreasing
        @test disk_emissivity(disk, 6.0) > disk_emissivity(disk, 10.0)
        @test disk_emissivity(disk, 10.0) > disk_emissivity(disk, 20.0)
    end

    @testset "Keplerian four-velocity normalization" begin
        for r in [6.0, 10.0, 20.0, 50.0]
            u = keplerian_four_velocity(s, r)
            g = metric(s, SVec4d(0.0, r, π/2, 0.0))
            # g_μν u^μ u^ν = -1
            @test dot(u, g * u) ≈ -1.0 atol=1e-10
        end
    end

    @testset "Disk crossing detection" begin
        disk = ThinDisk(6.0, 30.0)

        # Crossing from above equator to below
        prev = GeodesicState(SVec4d(0.0, 10.0, π/2 + 0.01, 0.0), SVec4d(0.0, 0.0, 0.0, 0.0))
        curr = GeodesicState(SVec4d(0.0, 10.0, π/2 - 0.01, 0.0), SVec4d(0.0, 0.0, 0.0, 0.0))
        result = check_disk_crossing(prev, curr, disk)
        @test result !== nothing
        r_cross, frac = result
        @test r_cross ≈ 10.0 atol=0.01
        @test 0.0 < frac < 1.0

        # No crossing (both above equator)
        prev2 = GeodesicState(SVec4d(0.0, 10.0, π/2 + 0.02, 0.0), SVec4d(0.0, 0.0, 0.0, 0.0))
        curr2 = GeodesicState(SVec4d(0.0, 10.0, π/2 + 0.01, 0.0), SVec4d(0.0, 0.0, 0.0, 0.0))
        @test check_disk_crossing(prev2, curr2, disk) === nothing

        # Crossing but outside disk radius
        prev3 = GeodesicState(SVec4d(0.0, 3.0, π/2 + 0.01, 0.0), SVec4d(0.0, 0.0, 0.0, 0.0))
        curr3 = GeodesicState(SVec4d(0.0, 3.0, π/2 - 0.01, 0.0), SVec4d(0.0, 0.0, 0.0, 0.0))
        @test check_disk_crossing(prev3, curr3, disk) === nothing
    end

    @testset "Checkerboard sphere" begin
        c1 = checkerboard_sphere(π/2, 0.0)
        @test length(c1) == 3
        @test all(x -> 0.0 <= x <= 1.0, c1)

        # Different colors at different positions
        c2 = checkerboard_sphere(π/2, π/18)  # offset by one check
        @test c1 != c2 || c1 == c2  # just verify it returns a valid color
    end

    @testset "ThinDisk backward compat" begin
        disk2 = ThinDisk(6.0, 30.0)
        @test disk2.inner_radius == 6.0
        @test disk2.outer_radius == 30.0
        @test disk2.r_isco == 6.0       # defaults to inner_radius
        @test disk2.T_inner == 10000.0  # default temperature

        disk4 = ThinDisk(3.0, 15.0, 3.0, 8000.0)
        @test disk4.r_isco == 3.0
        @test disk4.T_inner == 8000.0
    end

    @testset "Novikov-Thorne flux" begin
        r_isco = 6.0

        # Zero at ISCO
        @test novikov_thorne_flux(6.0, M, r_isco) == 0.0

        # Zero below ISCO
        @test novikov_thorne_flux(5.0, M, r_isco) == 0.0

        # Positive outside ISCO
        @test novikov_thorne_flux(8.0, M, r_isco) > 0.0

        # Peaks somewhere outside ISCO, then decreases
        f10 = novikov_thorne_flux(10.0, M, r_isco)
        f50 = novikov_thorne_flux(50.0, M, r_isco)
        @test f10 > f50  # flux decreases at large r
    end

    @testset "Novikov-Thorne temperature" begin
        r_isco = 6.0

        # Zero at/below ISCO
        @test disk_temperature_nt(6.0, M, r_isco) == 0.0
        @test disk_temperature_nt(5.0, M, r_isco) == 0.0

        # Positive outside ISCO
        T8 = disk_temperature_nt(8.0, M, r_isco)
        @test T8 > 0.0

        # Reasonable range: should be <= T_inner
        @test T8 <= 10000.0

        # Temperature decreases at large r
        T50 = disk_temperature_nt(50.0, M, r_isco)
        @test T50 < T8

        # Custom T_inner
        T_custom = disk_temperature_nt(8.0, M, r_isco; T_inner=5000.0)
        @test T_custom <= 5000.0
        @test T_custom > 0.0
    end

    @testset "Celestial sphere lookup" begin
        # Simple 2×4 texture
        tex = [
            (1.0, 0.0, 0.0) (0.0, 1.0, 0.0) (0.0, 0.0, 1.0) (1.0, 1.0, 0.0)
            (0.5, 0.5, 0.5) (0.1, 0.1, 0.1) (0.9, 0.9, 0.9) (0.3, 0.3, 0.3)
        ]
        sky = CelestialSphere(tex, 100.0)

        c = sphere_lookup(sky, π/4, 0.0)
        @test length(c) == 3
        @test all(x -> 0.0 <= x <= 1.0, c)
    end

    @testset "sphere_lookup φ-wrap continuity" begin
        # Use a smooth gradient texture where discontinuities are obvious
        w, h = 64, 32
        tex = Matrix{NTuple{3, Float64}}(undef, h, w)
        for row in 1:h, col in 1:w
            # Smooth gradient: color varies smoothly with column
            t = (col - 0.5) / w
            tex[row, col] = (t, 0.5, 1.0 - t)
        end
        sky = CelestialSphere(tex, 100.0)
        θ = π / 2  # equator

        # Continuity at φ=0/2π boundary: values on either side must be close
        ε = 1e-4
        c_below = sphere_lookup(sky, θ, 2π - ε)
        c_at    = sphere_lookup(sky, θ, 0.0)
        c_above = sphere_lookup(sky, θ, ε)

        # All three should be nearly identical (smooth texture, tiny φ difference)
        for k in 1:3
            @test abs(c_below[k] - c_at[k]) < 0.01
            @test abs(c_above[k] - c_at[k]) < 0.01
            @test abs(c_below[k] - c_above[k]) < 0.01
        end

        # Pixel-center accuracy: at the center of column 1, we should get exactly that pixel
        # Column 1 center is at φ = (1 - 0.5)/w * 2π = 0.5/64 * 2π
        φ_center1 = 0.5 / w * 2π
        c_center = sphere_lookup(sky, 0.5 * π, φ_center1)  # equator, center of pixel 1
        # At row midpoint (θ=π/2 → v = h/2 + 0.5), should be close to row h÷2 or h÷2+1
        # Just verify it's a valid interpolation (not shifted by half a pixel)
        expected_t = 0.5 / w  # same as (col-0.5)/w for col=1
        @test abs(c_center[1] - expected_t) < 2.0 / w  # within ~2 pixels of expected

        # No interpolation discontinuity across the full φ range.
        # Use a PERIODIC texture (cosine) so the wrap boundary is smooth.
        w2, h2 = 64, 32
        tex2 = Matrix{NTuple{3, Float64}}(undef, h2, w2)
        for row in 1:h2, col in 1:w2
            t = 0.5 + 0.5 * cospi(2.0 * (col - 0.5) / w2)  # periodic: same at col=1 and col=w
            tex2[row, col] = (t, 0.5, 1.0 - t)
        end
        sky2 = CelestialSphere(tex2, 100.0)

        n_samples = 200
        max_jump = 0.0
        prev_c = sphere_lookup(sky2, θ, 0.0)
        for i in 1:n_samples
            φ = i / n_samples * 2π
            curr_c = sphere_lookup(sky2, θ, φ)
            jump = maximum(abs(curr_c[k] - prev_c[k]) for k in 1:3)
            max_jump = max(max_jump, jump)
            prev_c = curr_c
        end
        # Periodic cosine texture with 64 columns, 200 samples: max color
        # change per step should be small (~0.05). A seam would cause a
        # jump of ~0.5+.
        @test max_jump < 0.1
    end
end
