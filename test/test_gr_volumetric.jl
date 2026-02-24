@testset "GR Volumetric Matter" begin
    using Lyr.GR
    using StaticArrays

    # ── ThickDisk density ──

    @testset "ThickDisk construction" begin
        disk = ThickDisk(6.0, 30.0, 0.05, 1.0)
        @test disk.r_inner == 6.0
        @test disk.r_outer == 30.0
        @test disk.h_over_r == 0.05
        @test disk.amplitude == 1.0
    end

    @testset "ThickDisk density midplane" begin
        disk = ThickDisk(6.0, 30.0, 0.05, 1.0)
        # At midplane (θ = π/2), cos(θ) = 0, so z = 0 → full density
        ρ = evaluate_density(disk, 10.0, π / 2, 0.0)
        @test ρ > 0.0
        @test ρ ≈ 1.0 * (6.0 / 10.0)^2  # amplitude × (r_in/r)²
    end

    @testset "ThickDisk density vertical falloff" begin
        disk = ThickDisk(6.0, 30.0, 0.05, 1.0)
        ρ_mid = evaluate_density(disk, 10.0, π / 2, 0.0)
        ρ_above = evaluate_density(disk, 10.0, π / 4, 0.0)
        # Off-midplane density should be much smaller (Gaussian falloff)
        @test ρ_above < ρ_mid * 1e-10
    end

    @testset "ThickDisk density bounds" begin
        disk = ThickDisk(6.0, 30.0, 0.05, 1.0)
        # Inside inner radius
        @test evaluate_density(disk, 5.0, π / 2, 0.0) == 0.0
        # Outside outer radius
        @test evaluate_density(disk, 31.0, π / 2, 0.0) == 0.0
        # At inner edge
        @test evaluate_density(disk, 6.0, π / 2, 0.0) > 0.0
        # At outer edge
        @test evaluate_density(disk, 30.0, π / 2, 0.0) > 0.0
    end

    @testset "ThickDisk density azimuthal symmetry" begin
        disk = ThickDisk(6.0, 30.0, 0.05, 1.0)
        ρ1 = evaluate_density(disk, 10.0, π / 2, 0.0)
        ρ2 = evaluate_density(disk, 10.0, π / 2, Float64(π))
        ρ3 = evaluate_density(disk, 10.0, π / 2, 3.5)
        @test ρ1 == ρ2
        @test ρ1 == ρ3
    end

    @testset "ThickDisk density radial falloff" begin
        disk = ThickDisk(6.0, 30.0, 0.05, 1.0)
        ρ_near = evaluate_density(disk, 7.0, π / 2, 0.0)
        ρ_far = evaluate_density(disk, 20.0, π / 2, 0.0)
        # r^{-2} falloff: closer is denser
        @test ρ_near > ρ_far
    end

    # ── Emission and absorption ──

    @testset "emission_absorption positive" begin
        j, α = emission_absorption(0.5, 0.8)
        @test j > 0.0
        @test α > 0.0
    end

    @testset "emission_absorption scales with ρ²" begin
        j1, _ = emission_absorption(1.0, 1.0)
        j2, _ = emission_absorption(2.0, 1.0)
        @test j2 ≈ 4.0 * j1  # ρ² scaling
    end

    @testset "emission_absorption zero density" begin
        j, α = emission_absorption(0.0, 1.0)
        @test j == 0.0
        @test α == 0.0
    end

    @testset "disk_temperature profile" begin
        T_isco = disk_temperature(6.0, 6.0)
        @test T_isco ≈ 1.0  # normalized at r_inner

        T_far = disk_temperature(20.0, 6.0)
        @test T_far < T_isco  # temperature drops with r
        @test T_far ≈ (6.0 / 20.0)^0.75
    end

    # ── Volumetric redshift ──

    @testset "volumetric_redshift at large r" begin
        m = Schwarzschild(1.0)
        x = SVec4d(0.0, 100.0, π / 2, 0.0)
        p = SVec4d(-1.0, 0.1, 0.0, 0.01)
        f_obs = 1.0 - 2.0 / 100.0
        u_obs = SVec4d(1.0 / sqrt(f_obs), 0.0, 0.0, 0.0)
        z = volumetric_redshift(m, x, p, p, u_obs)
        # At large r, redshift should be close to 1 (minimal gravitational effect)
        @test 0.5 < z < 2.0
    end

    @testset "volumetric_redshift inside photon sphere" begin
        m = Schwarzschild(1.0)
        x = SVec4d(0.0, 2.5, π / 2, 0.0)  # r < 3M
        p = SVec4d(-1.0, 0.1, 0.0, 0.01)
        u_obs = SVec4d(1.0, 0.0, 0.0, 0.0)
        z = volumetric_redshift(m, x, p, p, u_obs)
        @test z == 1.0  # returns 1.0 inside photon sphere
    end

    # ── VolumetricMatter struct ──

    @testset "VolumetricMatter construction" begin
        m = Schwarzschild(1.0)
        disk = ThickDisk(6.0, 30.0, 0.05, 1.0)
        vol = VolumetricMatter(m, disk, 6.0, 30.0)
        @test vol.metric === m
        @test vol.density_source === disk
        @test vol.inner_radius == 6.0
        @test vol.outer_radius == 30.0
    end

    @testset "VolumetricMatter type parameterization" begin
        m = Schwarzschild(1.0)
        disk = ThickDisk(6.0, 30.0, 0.05, 1.0)
        vol = VolumetricMatter(m, disk, 6.0, 30.0)
        @test vol isa VolumetricMatter{Schwarzschild{SchwarzschildCoordinates}, ThickDisk}
        @test vol isa MatterSource
    end

    # ── Volumetric rendering ──

    @testset "trace_pixel volumetric dispatches" begin
        m = Schwarzschild(1.0)
        cam = static_camera(m, 50.0, π / 2, 0.0, π / 4, (16, 16))
        config = GRRenderConfig(use_threads=false)
        disk = ThickDisk(6.0, 30.0, 0.1, 1.0)
        vol = VolumetricMatter(m, disk, 6.0, 30.0)

        # Should dispatch to volumetric trace_pixel
        color = Lyr.GR.trace_pixel(cam, config, vol, nothing, 8, 8)
        @test length(color) == 3
        @test all(c -> c >= 0.0, color)
    end

    @testset "gr_render_image with volume kwarg" begin
        m = Schwarzschild(1.0)
        cam = static_camera(m, 50.0, π / 2, 0.0, π / 4, (8, 8))
        config = GRRenderConfig(use_threads=false)
        disk = ThickDisk(6.0, 30.0, 0.1, 1.0)
        vol = VolumetricMatter(m, disk, 6.0, 30.0)

        pixels = gr_render_image(cam, config; volume=vol)
        @test size(pixels) == (8, 8)
        @test all(p -> all(c -> c >= 0.0, p), pixels)
    end

    @testset "gr_render_image volume takes precedence over disk" begin
        m = Schwarzschild(1.0)
        cam = static_camera(m, 50.0, π / 2, 0.0, π / 4, (8, 8))
        config = GRRenderConfig(use_threads=false)
        thin = ThinDisk(6.0, 30.0)
        disk = ThickDisk(6.0, 30.0, 0.1, 1.0)
        vol = VolumetricMatter(m, disk, 6.0, 30.0)

        # When both disk and volume provided, volume takes precedence
        pixels_vol = gr_render_image(cam, config; volume=vol)
        pixels_both = gr_render_image(cam, config; disk=thin, volume=vol)
        @test pixels_vol == pixels_both
    end

    @testset "ThinDisk path unchanged (regression)" begin
        m = Schwarzschild(1.0)
        cam = static_camera(m, 50.0, π / 2, 0.0, π / 4, (8, 8))
        config = GRRenderConfig(use_threads=false)
        thin = ThinDisk(6.0, 30.0)

        pixels = gr_render_image(cam, config; disk=thin)
        @test size(pixels) == (8, 8)
        # At least some pixels should show disk emission
        @test any(p -> any(c -> c > 0.01, p), pixels)
    end

    @testset "Volumetric rendering produces emission" begin
        m = Schwarzschild(1.0)
        # Camera closer and wider FOV to see more disk
        cam = static_camera(m, 20.0, π / 2 - 0.3, 0.0, π / 3, (16, 16))
        config = GRRenderConfig(use_threads=false, use_redshift=true)
        disk = ThickDisk(6.0, 30.0, 0.15, 2.0)  # thicker, brighter
        vol = VolumetricMatter(m, disk, 6.0, 30.0)

        pixels = gr_render_image(cam, config; volume=vol)
        # Should have some bright (emission) pixels
        max_intensity = maximum(p -> maximum(p), pixels)
        @test max_intensity > 0.0
    end

    @testset "Volumetric rendering with threads matches single-threaded" begin
        m = Schwarzschild(1.0)
        cam = static_camera(m, 50.0, π / 2, 0.0, π / 4, (8, 8))
        disk = ThickDisk(6.0, 30.0, 0.1, 1.0)
        vol = VolumetricMatter(m, disk, 6.0, 30.0)

        config_st = GRRenderConfig(use_threads=false)
        config_mt = GRRenderConfig(use_threads=true)

        pixels_st = gr_render_image(cam, config_st; volume=vol)
        pixels_mt = gr_render_image(cam, config_mt; volume=vol)
        @test pixels_st == pixels_mt
    end
end
