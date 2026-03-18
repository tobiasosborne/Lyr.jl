@testset "Wavepackets" begin

# ============================================================================
# Gaussian wavepackets (EQ:WAVEPACKET-3D, EQ:WAVEPACKET-SPREADING)
# ============================================================================

@testset "Gaussian wavepacket" begin
    r0 = (0.0, 0.0, 0.0)
    p0 = (1.0, 0.0, 0.0)
    d = 2.0
    m = 1.0

    # Normalization at t=0: ∫|ψ|² d³x = 1 (3D Gaussian, analytical)
    # Use radial integration since |ψ(r,0)|² = (2πd²)^(-3/2) exp(-r²/(2d²))
    Nr = 500
    r_max = 5.0 * d
    dr = r_max / Nr
    norm_1d = 0.0
    for i in 1:Nr
        r = (i - 0.5) * dr
        ψ = gaussian_wavepacket(r, 0.0, 0.0, 0.0, p0, r0, d, m)
        norm_1d += abs2(ψ) * 4π * r^2 * dr
    end
    @test norm_1d ≈ 1.0 atol=0.01

    # Peak at r₀ at t=0
    ψ_center = abs2(gaussian_wavepacket(0.0, 0.0, 0.0, 0.0, p0, r0, d, m))
    ψ_off = abs2(gaussian_wavepacket(d, 0.0, 0.0, 0.0, p0, r0, d, m))
    @test ψ_center > ψ_off

    # Peak propagates: at t=10, peak at r₀ + v_g*t = (10, 0, 0)
    t = 10.0
    ψ_peak = abs2(gaussian_wavepacket(10.0, 0.0, 0.0, t, p0, r0, d, m))
    ψ_origin = abs2(gaussian_wavepacket(0.0, 0.0, 0.0, t, p0, r0, d, m))
    @test ψ_peak > ψ_origin

    # Width spreading matches EQ:WAVEPACKET-WIDTH
    @test Lyr.wavepacket_width(0.0, d, m) ≈ d atol=1e-14
    t2 = 20.0
    expected_width = d * sqrt(1.0 + (t2 / (2.0 * m * d^2))^2)
    @test Lyr.wavepacket_width(t2, d, m) ≈ expected_width atol=1e-14
    @test Lyr.wavepacket_width(t2, d, m) > d  # width grows

    # Stationary wavepacket (p₀=0): stays at origin
    p0_zero = (0.0, 0.0, 0.0)
    ψ_stat_center = abs2(gaussian_wavepacket(0.0, 0.0, 0.0, 50.0, p0_zero, r0, d, m))
    ψ_stat_off = abs2(gaussian_wavepacket(5.0, 0.0, 0.0, 50.0, p0_zero, r0, d, m))
    @test ψ_stat_center > ψ_stat_off
end

# ============================================================================
# Morse potential (EQ:MORSE-POTENTIAL)
# ============================================================================

@testset "Morse potential" begin
    V = H2_MORSE

    # V(Re) = 0 (minimum of potential)
    @test morse_potential(V, V.Re) ≈ 0.0 atol=1e-14

    # F(Re) = 0 (equilibrium: zero force)
    @test morse_force(V, V.Re) ≈ 0.0 atol=1e-14

    # Dissociation limit: V(∞) → De
    @test morse_potential(V, 100.0) ≈ V.De atol=1e-6

    # Force direction: repulsive for R < Re, attractive for R > Re
    @test morse_force(V, V.Re - 0.5) > 0.0  # pushes apart
    @test morse_force(V, V.Re + 0.5) < 0.0  # pulls together

    # Curvature at minimum: d²V/dR² = 2 De a²
    δ = 1e-5
    d2V = (morse_potential(V, V.Re + δ) - 2morse_potential(V, V.Re) + morse_potential(V, V.Re - δ)) / δ^2
    @test d2V ≈ 2.0 * V.De * V.a^2 atol=1e-3
end

# ============================================================================
# Kolos-Wolniewicz PES (EQ:KW-PES)
# ============================================================================

@testset "KW potential" begin
    # Exact at data points
    for (R, E) in zip(Lyr._KW_R, Lyr._KW_E)
        @test kw_potential(R) ≈ E atol=1e-8
    end

    # Minimum near R = 1.4 a.u.
    R_min = 1.3
    E_min = kw_potential(R_min)
    for R in 1.3:0.01:1.5
        E_min_cand = kw_potential(R)
        if E_min_cand < E_min
            E_min = E_min_cand
            R_min = R
        end
    end
    @test 1.35 < R_min < 1.45

    # Boundary clamping
    @test kw_potential(0.5) == kw_potential(1.0)
    @test kw_potential(5.0) == kw_potential(3.0)
    @test kw_force(0.5) == 0.0
    @test kw_force(5.0) == 0.0

    # Monotonicity: decreasing from 1.0 to 1.4, increasing from 1.4 to 3.0
    @test kw_potential(1.0) > kw_potential(1.2)
    @test kw_potential(1.2) > kw_potential(1.4)
    @test kw_potential(1.4) < kw_potential(1.8)
    @test kw_potential(1.8) < kw_potential(3.0)
end

# ============================================================================
# Velocity-Verlet trajectory
# ============================================================================

@testset "Nuclear trajectory" begin
    # Harmonic oscillator: F = -k(R - Req), exact period T = 2π√(m/k)
    k = 1.0
    Req = 2.0
    m_harm = 1.0
    T = 2π * sqrt(m_harm / k)
    dt = T / 500  # 500 steps per period
    nsteps = 500

    ts, Rs, Vs = nuclear_trajectory(Req + 0.1, 0.0, R -> -k * (R - Req), m_harm, dt, nsteps)
    @test length(ts) == nsteps + 1
    @test Rs[1] ≈ Req + 0.1 atol=1e-14
    @test Rs[end] ≈ Req + 0.1 atol=1e-4  # returns to start after one period
    @test Vs[end] ≈ 0.0 atol=1e-4

    # Energy conservation on Morse potential
    μ = 918.076  # H₂ reduced mass (half proton mass)
    R0_morse = H2_MORSE.Re + 0.05  # small displacement from equilibrium
    ts_m, Rs_m, Vs_m = nuclear_trajectory(
        R0_morse, 0.0,
        R -> morse_force(H2_MORSE, R), μ,
        1.0, 1000
    )
    energies = [0.5 * μ * Vs_m[i]^2 + morse_potential(H2_MORSE, Rs_m[i]) for i in eachindex(ts_m)]
    @test maximum(energies) - minimum(energies) < 1e-6

    # Free particle: R(t) = R₀ + V₀ t
    R0_free = 5.0
    V0_free = 0.01
    ts_f, Rs_f, Vs_f = nuclear_trajectory(R0_free, V0_free, R -> 0.0, 1.0, 1.0, 100)
    for i in eachindex(ts_f)
        @test Rs_f[i] ≈ R0_free + V0_free * ts_f[i] atol=1e-12
        @test Vs_f[i] ≈ V0_free atol=1e-14
    end
end

# ============================================================================
# Field Protocol integration
# ============================================================================

@testset "Field Protocol integration" begin
    # GaussianWavepacketField returns TimeEvolution
    wp = GaussianWavepacketField((1.0, 0.0, 0.0), (0.0, 0.0, 0.0), 2.0;
                                 m=1.0, t_range=(0.0, 50.0), dt=1.0)
    @test isa(wp, TimeEvolution)

    # Evaluate at t=0 matches direct call
    field_t0 = wp.eval_fn(0.0)
    @test evaluate(field_t0, 0.0, 0.0, 0.0) ≈
          gaussian_wavepacket(0.0, 0.0, 0.0, 0.0, (1.0,0.0,0.0), (0.0,0.0,0.0), 2.0, 1.0) atol=1e-14

    # characteristic_scale delegates correctly
    @test characteristic_scale(wp) ≈ 2.0 atol=1e-14

    # voxelize(TimeEvolution; t=...) produces non-empty grid
    grid = voxelize(wp; t=0.0)
    @test active_voxel_count(grid.tree) > 0

    # ScatteringField with constant trajectory matches h2_bonding
    const_R = fill(1.4, 10)
    const_t = collect(range(0.0, 9.0, length=10))
    sf = ScatteringField(const_R, const_t, h2_bonding)
    @test isa(sf, TimeEvolution)

    field_sf = sf.eval_fn(5.0)
    @test evaluate(field_sf, 0.0, 0.0, 0.0) ≈ h2_bonding(1.4, 0.0, 0.0, 0.0) atol=1e-14

    # visualize(TimeEvolution; t=...) works (just check it doesn't error)
    @test isa(domain(wp), BoxDomain)
end

end  # @testset "Wavepackets"
