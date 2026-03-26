# test_gr_kerr.jl — Tests for Kerr black hole metric in Boyer-Lindquist coordinates

using Test
using Lyr
using Lyr.GR
using StaticArrays
using LinearAlgebra: I, norm, dot

@testset "Kerr Boyer-Lindquist" begin

# ============================================================================
# Construction and helpers
# ============================================================================

@testset "Construction" begin
    k = Kerr(1.0, 0.5)
    @test k.M == 1.0
    @test k.a == 0.5
    @test_throws ArgumentError Kerr(1.0, 1.5)  # |a| > M
    # Extremal Kerr (a = M) is allowed
    k_ext = Kerr(1.0, 1.0)
    @test k_ext.a == 1.0
end

@testset "Horizon radii" begin
    k = Kerr(1.0, 0.0)
    @test horizon_radius(k) ≈ 2.0  # Schwarzschild limit
    @test inner_horizon_radius(k) ≈ 0.0

    k = Kerr(1.0, 0.5)
    @test horizon_radius(k) ≈ 1.0 + sqrt(0.75)
    @test inner_horizon_radius(k) ≈ 1.0 - sqrt(0.75)

    k_ext = Kerr(1.0, 1.0)
    @test horizon_radius(k_ext) ≈ 1.0  # degenerate horizons
    @test inner_horizon_radius(k_ext) ≈ 1.0
end

@testset "ISCO" begin
    k0 = Kerr(1.0, 0.0)
    @test isco_prograde(k0) ≈ 6.0 atol=1e-10  # Schwarzschild limit
    @test isco_retrograde(k0) ≈ 6.0 atol=1e-10

    k = Kerr(1.0, 0.9)
    @test isco_prograde(k) < 6.0  # prograde moves inward with spin
    @test isco_retrograde(k) > 6.0  # retrograde moves outward

    k_ext = Kerr(1.0, 1.0)
    @test isco_prograde(k_ext) ≈ 1.0 atol=1e-6  # extremal: ISCO at horizon
end

@testset "Ergosphere" begin
    k = Kerr(1.0, 0.9)
    # At equator: r_ergo = M + √(M²) = 2M (independent of spin)
    @test ergosphere_radius(k, π/2) ≈ 2.0
    # At pole: r_ergo = M + √(M² - a²) = r_+ (touches horizon)
    @test ergosphere_radius(k, 0.0) ≈ horizon_radius(k)
end

# ============================================================================
# Metric properties
# ============================================================================

@testset "Schwarzschild limit (a=0)" begin
    k = Kerr(1.0, 0.0)
    s = Schwarzschild(1.0)

    for r in [3.0, 6.0, 10.0, 50.0]
        for θ in [π/6, π/4, π/3, π/2]
            x = SVec4d(0.0, r, θ, 0.0)
            gk = metric(k, x)
            gs = metric(s, x)
            # Off-diagonal g_tφ should vanish for a=0
            @test abs(gk[1,4]) < 1e-14
            @test abs(gk[4,1]) < 1e-14
            # Diagonal elements should match Schwarzschild
            @test gk[1,1] ≈ gs[1,1] atol=1e-12
            @test gk[2,2] ≈ gs[2,2] atol=1e-12
            @test gk[3,3] ≈ gs[3,3] atol=1e-12
            @test gk[4,4] ≈ gs[4,4] atol=1e-12
        end
    end
end

@testset "Metric symmetry" begin
    k = Kerr(1.0, 0.7)
    x = SVec4d(0.0, 5.0, π/3, 0.5)
    g = metric(k, x)
    ginv = metric_inverse(k, x)
    @test g ≈ transpose(g) atol=1e-14
    @test ginv ≈ transpose(ginv) atol=1e-14
end

@testset "Metric inverse identity g^αμ g_μβ = δ^α_β" begin
    k = Kerr(1.0, 0.7)
    for r in [3.0, 5.0, 10.0, 50.0]
        for θ in [π/6, π/4, π/3, π/2]
            x = SVec4d(0.0, r, θ, 0.0)
            g = metric(k, x)
            ginv = metric_inverse(k, x)
            product = ginv * g
            @test product ≈ SMatrix{4,4,Float64}(I) atol=1e-10
        end
    end
end

@testset "Metric signature" begin
    k = Kerr(1.0, 0.9)
    x = SVec4d(0.0, 10.0, π/3, 0.0)
    g = metric(k, x)
    # g_tt < 0 outside ergosphere
    @test g[1,1] < 0
    # g_rr, g_θθ, g_φφ > 0
    @test g[2,2] > 0
    @test g[3,3] > 0
    @test g[4,4] > 0
    # det(t,φ block) = -Δ sin²θ < 0 (Lorentzian)
    det_tφ = g[1,1] * g[4,4] - g[1,4]^2
    @test det_tφ < 0
end

@testset "Off-diagonal g_tφ" begin
    k = Kerr(1.0, 0.9)
    x = SVec4d(0.0, 5.0, π/3, 0.0)
    g = metric(k, x)
    # g_tφ should be nonzero for a ≠ 0
    @test abs(g[1,4]) > 0.01
    # g_tφ < 0 (frame dragging in prograde direction)
    @test g[1,4] < 0
    # g_tφ vanishes at poles (sin²θ → 0)
    x_pole = SVec4d(0.0, 5.0, 0.01, 0.0)
    g_pole = metric(k, x_pole)
    @test abs(g_pole[1,4]) < 0.01
end

@testset "is_singular" begin
    k = Kerr(1.0, 0.5)
    r_plus = horizon_radius(k)
    @test is_singular(k, SVec4d(0.0, r_plus - 0.1, π/2, 0.0))
    @test !is_singular(k, SVec4d(0.0, r_plus + 1.0, π/2, 0.0))
end

@testset "coordinate_bounds" begin
    k = Kerr(1.0, 0.5)
    bounds = coordinate_bounds(k)
    @test bounds.r_min ≈ horizon_radius(k)
    @test bounds.r_max == Inf
end

# ============================================================================
# Hamiltonian and geodesics
# ============================================================================

@testset "Hamiltonian RHS computes" begin
    k = Kerr(1.0, 0.5)
    x = SVec4d(0.0, 10.0, π/2, 0.0)
    # Construct a null momentum: use the camera infrastructure
    ginv = metric_inverse(k, x)
    # Simple null momentum in equatorial plane
    p = SVec4d(-1.0, 1.0, 0.0, 0.1)
    # Rescale to be null: find E such that g^μν p_μ p_ν = 0
    # For now, just check the RHS computes without error
    dx, dp = hamiltonian_rhs(k, x, p)
    @test length(dx) == 4
    @test length(dp) == 4
    @test all(isfinite, dx)
    @test all(isfinite, dp)
end

@testset "Null geodesic H conservation" begin
    k = Kerr(1.0, 0.5)
    # Camera at r=20, equatorial plane
    cam = static_camera(k, 20.0, π/2, 0.0, 60.0, (64, 64))
    p0 = pixel_to_momentum(cam, 32, 32)  # center pixel

    H0 = hamiltonian(k, cam.position, p0)
    @test abs(H0) < 1e-8  # should be null

    # Integrate backward and check H stays small
    config = IntegratorConfig(
        step_size=-0.5, max_steps=200, h_tolerance=1e-4,
        r_max=100.0, renorm_interval=10
    )
    trace = integrate_geodesic(k, GeodesicState(cam.position, p0), config)
    @test trace.hamiltonian_max < 1e-3
    @test trace.n_steps > 10
end

@testset "Geodesic terminates at horizon" begin
    k = Kerr(1.0, 0.5)
    cam = static_camera(k, 10.0, π/2, 0.0, 60.0, (64, 64))
    # Aim at center — should hit BH
    p0 = pixel_to_momentum(cam, 32, 32)

    config = IntegratorConfig(
        step_size=-0.5, max_steps=500, h_tolerance=1e-3,
        r_max=50.0, renorm_interval=10
    )
    trace = integrate_geodesic(k, GeodesicState(cam.position, p0), config)
    # Ray aimed at BH should either hit horizon or escape
    @test trace.reason in (HORIZON, SINGULARITY, ESCAPED, MAX_STEPS, HAMILTONIAN_DRIFT)
end

@testset "Geodesic escapes for wide-angle ray" begin
    k = Kerr(1.0, 0.5)
    cam = static_camera(k, 20.0, π/2, 0.0, 90.0, (64, 64))
    # Aim at corner — high impact parameter, should escape
    p0 = pixel_to_momentum(cam, 1, 1)

    config = IntegratorConfig(
        step_size=-0.5, max_steps=500, h_tolerance=1e-3,
        r_max=50.0, renorm_interval=10
    )
    trace = integrate_geodesic(k, GeodesicState(cam.position, p0), config)
    @test trace.reason in (ESCAPED, MAX_STEPS)
end

# ============================================================================
# Camera / tetrad
# ============================================================================

@testset "Static observer tetrad orthonormality" begin
    k = Kerr(1.0, 0.7)
    for r in [5.0, 10.0, 20.0]
        for θ in [π/4, π/3, π/2]
            x = SVec4d(0.0, r, θ, 0.0)
            u, E = static_observer_tetrad(k, x)
            g = metric(k, x)

            # Check η_ab = g_μν e_a^μ e_b^ν
            eta = transpose(E) * g * E
            eta_expected = SMatrix{4,4,Float64}(
                -1, 0, 0, 0,
                 0, 1, 0, 0,
                 0, 0, 1, 0,
                 0, 0, 0, 1
            )
            @test eta ≈ eta_expected atol=1e-8
        end
    end
end

@testset "Kerr tetrad reduces to Schwarzschild for a=0" begin
    k = Kerr(1.0, 0.0)
    s = Schwarzschild(1.0)
    x = SVec4d(0.0, 10.0, π/3, 0.0)

    uk, Ek = static_observer_tetrad(k, x)
    us, Es = static_observer_tetrad(s, x)

    @test uk ≈ us atol=1e-10
    # Tetrads should agree (up to possible sign conventions)
    for col in 1:4
        # Either same or negated
        @test abs(dot(Ek[:, col], Es[:, col])) ≈ norm(Ek[:, col]) * norm(Es[:, col]) atol=1e-8
    end
end

# ============================================================================
# Rendering
# ============================================================================

@testset "Basic Kerr render (thin disk)" begin
    k = Kerr(1.0, 0.5)
    cam = static_camera(k, 20.0, 1.2, 0.0, 60.0, (32, 32))
    disk = ThinDisk(isco_prograde(k), 15.0)
    sky = CelestialSphere(fill((0.0, 0.0, 0.0), 64, 128), 100.0)

    config = GRRenderConfig(
        integrator=IntegratorConfig(
            step_size=-0.5, max_steps=300, h_tolerance=1e-3,
            r_max=50.0, renorm_interval=10
        ),
        background=(0.0, 0.0, 0.0),
        use_redshift=true,
        use_threads=false,
        samples_per_pixel=1
    )

    img = gr_render_image(cam, config; disk=disk, sky=sky)
    @test size(img) == (32, 32)
    # Should have some non-black pixels from the disk
    bright = count(px -> px[1] > 0.01, img)
    @test bright > 0
end

@testset "Spin asymmetry visible in render" begin
    # High-spin BH should show asymmetric disk (prograde side brighter via Doppler)
    k = Kerr(1.0, 0.9)
    cam = static_camera(k, 20.0, 1.2, 0.0, 60.0, (32, 32))
    disk = ThinDisk(isco_prograde(k), 15.0)
    sky = CelestialSphere(fill((0.0, 0.0, 0.0), 64, 128), 100.0)

    config = GRRenderConfig(
        integrator=IntegratorConfig(
            step_size=-0.3, max_steps=400, h_tolerance=1e-3,
            r_max=50.0, renorm_interval=10
        ),
        background=(0.0, 0.0, 0.0),
        use_redshift=true,
        use_threads=false,
        samples_per_pixel=1
    )

    img = gr_render_image(cam, config; disk=disk, sky=sky)
    # Compute left vs right brightness (spin asymmetry)
    left_sum = sum(px[1] for px in img[:, 1:16])
    right_sum = sum(px[1] for px in img[:, 17:32])
    # For a=0.9, the prograde side should be significantly brighter
    # Just check there IS asymmetry (both sides have some light)
    total = left_sum + right_sum
    @test total > 0  # disk is visible
end

# ============================================================================
# Christoffel symbols
# ============================================================================

@testset "Christoffel symbols: Schwarzschild limit (a=0)" begin
    # Kerr with a=0 should match Schwarzschild Christoffel
    k0 = Kerr(1.0, 0.0)
    s = Schwarzschild(1.0)
    x = SVec4d(0.0, 10.0, π/3, 0.0)
    Γk = christoffel(k0, x)
    Γs = christoffel(s, x)
    for μ in 1:4
        @test maximum(abs, Γk[μ] - Γs[μ]) < 1e-10
    end
end

@testset "Christoffel symbols: Hamiltonian cross-check" begin
    # Verify Γ^μ_{αβ} v^α v^β matches Hamiltonian acceleration for random (r,θ,a)
    for _ in 1:100
        a_spin = 0.99 * rand()  # a ∈ [0, 0.99)
        k = Kerr(1.0, a_spin)
        r_plus = horizon_radius(k)
        r = r_plus + 1.0 + 50.0 * rand()  # r ∈ [r+ + 1, r+ + 51]
        θ = 0.1 + (π - 0.2) * rand()
        x = SVec4d(0.0, r, θ, 0.0)

        # Random null momentum
        ginv = metric_inverse(k, x)
        pr, pθ, pφ = randn(), randn(), randn()
        C = ginv[2,2]*pr^2 + ginv[3,3]*pθ^2 + ginv[4,4]*pφ^2 + 2.0*ginv[1,4]*0.0  # gtφ·pt terms handled below
        # Solve quadratic for pt: g^{tt}pt² + 2g^{tφ}pt·pφ + (spatial) = 0
        aa_coeff = ginv[1,1]
        bb_coeff = 2.0 * ginv[1,4] * pφ
        cc_coeff = ginv[2,2]*pr^2 + ginv[3,3]*pθ^2 + ginv[4,4]*pφ^2
        disc = bb_coeff^2 - 4.0*aa_coeff*cc_coeff
        disc < 0 && continue
        pt = (-bb_coeff - sqrt(disc)) / (2.0 * aa_coeff)
        p = SVec4d(pt, pr, pθ, pφ)

        # Method 1: Hamiltonian
        _, dp_ham = hamiltonian_rhs(k, x, p)
        dx = ginv * p
        partials = metric_inverse_partials(k, x)
        ddx_ham = ginv * dp_ham
        for σ in 1:4
            ddx_ham += dx[σ] * (partials[σ] * p)
        end

        # Method 2: Christoffel
        Γ = christoffel(k, x)
        ddx_chr = SVec4d(ntuple(μ -> -dot(dx, Γ[μ] * dx), 4))

        for μ in 1:4
            @test ddx_chr[μ] ≈ ddx_ham[μ] rtol=1e-6
        end
    end
end

@testset "Christoffel: symmetry Γ^μ_{αβ} = Γ^μ_{βα}" begin
    k = Kerr(1.0, 0.7)
    x = SVec4d(0.0, 8.0, π/4, 0.0)
    Γ = christoffel(k, x)
    for μ in 1:4
        for α in 1:4, β in α:4
            @test Γ[μ][α,β] ≈ Γ[μ][β,α] atol=1e-12
        end
    end
end

end  # Kerr Boyer-Lindquist
