@testset "Hydrogen Atom" begin

# ============================================================================
# Spherical harmonics (EQ:SPHERICAL-HARMONICS)
# ============================================================================

@testset "Spherical harmonics" begin
    # Y_0^0 = 1/√(4π)  — EQ:SPHERICAL-HARMONICS low-order check
    Y00 = Lyr.spherical_harmonic(0, 0, 0.0, 0.0)
    @test real(Y00) ≈ 1.0 / sqrt(4π) atol=1e-14
    @test imag(Y00) ≈ 0.0 atol=1e-14

    # Y_1^0(θ,φ) = √(3/4π) cos(θ)
    @test real(Lyr.spherical_harmonic(1, 0, π / 4, 0.0)) ≈ sqrt(3 / (4π)) * cos(π / 4) atol=1e-14
    @test imag(Lyr.spherical_harmonic(1, 0, π / 4, 0.0)) ≈ 0.0 atol=1e-14

    # Y_1^1(π/2, 0) = -√(3/8π) × 1 × 1 = -√(3/8π)
    Y11 = Lyr.spherical_harmonic(1, 1, π / 2, 0.0)
    @test real(Y11) ≈ -sqrt(3 / (8π)) atol=1e-14
    @test imag(Y11) ≈ 0.0 atol=1e-12

    # Conjugation relation: Y_l^{-m} = (-1)^m conj(Y_l^m)
    for (l, m) in [(1, 1), (2, 1), (2, 2), (3, 2)]
        Yp = Lyr.spherical_harmonic(l, m, 1.0, 0.7)
        Yn = Lyr.spherical_harmonic(l, -m, 1.0, 0.7)
        @test Yn ≈ (-1)^m * conj(Yp) atol=1e-14
    end

    # Normalization: ∫|Y_2^1|² dΩ = 1
    Nθ, Nφ = 200, 200
    integral = 0.0
    dθ = π / Nθ
    dφ = 2π / Nφ
    for i in 1:Nθ
        θ = (i - 0.5) * dθ
        for j in 1:Nφ
            φ = (j - 0.5) * dφ
            integral += abs2(Lyr.spherical_harmonic(2, 1, θ, φ)) * sin(θ) * dθ * dφ
        end
    end
    @test integral ≈ 1.0 atol=1e-4
end

# ============================================================================
# Radial wavefunctions (EQ:H-RADIAL)
# ============================================================================

@testset "Radial wavefunctions" begin
    # R_10(0) = 2/a₀^{3/2} = 2  (EQ:H-RADIAL-1S at r=0)
    @test Lyr.hydrogen_radial(1, 0, 0.0) ≈ 2.0 atol=1e-14

    # R_20(0) = 1/√2  (n=2, l=0, L_1^1(0)=2, norm=1/(2√2))
    @test Lyr.hydrogen_radial(2, 0, 0.0) ≈ 1.0 / sqrt(2.0) atol=1e-14

    # R_nl(0) = 0 for l > 0 (ρ^l factor)
    @test Lyr.hydrogen_radial(2, 1, 0.0) ≈ 0.0 atol=1e-14
    @test Lyr.hydrogen_radial(3, 2, 0.0) ≈ 0.0 atol=1e-14

    # Radial normalization: ∫₀∞ |R_10(r)|² r² dr = 1
    Nr = 10000
    r_max = 30.0
    dr = r_max / Nr
    integral = 0.0
    for i in 1:Nr
        r = (i - 0.5) * dr
        integral += abs2(Lyr.hydrogen_radial(1, 0, r)) * r^2 * dr
    end
    @test integral ≈ 1.0 atol=1e-4

    # Radial normalization: ∫₀∞ |R_21(r)|² r² dr = 1
    integral21 = 0.0
    r_max = 60.0
    dr = r_max / Nr
    for i in 1:Nr
        r = (i - 0.5) * dr
        integral21 += abs2(Lyr.hydrogen_radial(2, 1, r)) * r^2 * dr
    end
    @test integral21 ≈ 1.0 atol=1e-3
end

# ============================================================================
# Full eigenstate (EQ:H-EIGENSTATE)
# ============================================================================

@testset "Full eigenstate" begin
    # ψ_100(0,0,0) = R_10(0) × Y_0^0 = 2/√(4π) = 1/√π
    ψ_origin = hydrogen_psi(1, 0, 0, 0.0, 0.0, 0.0)
    @test real(ψ_origin) ≈ 1.0 / sqrt(π) atol=1e-12
    @test imag(ψ_origin) ≈ 0.0 atol=1e-12

    # l > 0 vanishes at origin
    @test abs(hydrogen_psi(2, 1, 0, 0.0, 0.0, 0.0)) < 1e-14
    @test abs(hydrogen_psi(3, 2, 1, 0.0, 0.0, 0.0)) < 1e-14

    # ⟨r⟩_1s = 3a₀/2 = 1.5  (exact analytical value)
    Nr = 5000
    r_max = 25.0
    dr = r_max / Nr
    integral_r = 0.0
    for i in 1:Nr
        r = (i - 0.5) * dr
        integral_r += abs2(Lyr.hydrogen_radial(1, 0, r)) * r^3 * dr
    end
    @test integral_r ≈ 1.5 atol=1e-3

    # Orthogonality: ∫R_10(r) R_20(r) r² dr = 0  (EQ:H-ORTHO)
    Nr = 5000
    r_max = 40.0
    dr = r_max / Nr
    ortho = 0.0
    for i in 1:Nr
        r = (i - 0.5) * dr
        ortho += Lyr.hydrogen_radial(1, 0, r) * Lyr.hydrogen_radial(2, 0, r) * r^2 * dr
    end
    @test abs(ortho) < 0.005

    # 3D normalization: ∫|ψ_100|² d³x = 1  (spherical quadrature)
    Nr, Nθ, Nφ = 150, 40, 40
    r_max_3d = 20.0
    dr3 = r_max_3d / Nr
    dθ = π / Nθ
    dφ = 2π / Nφ
    norm_3d = 0.0
    for i in 1:Nr
        r = (i - 0.5) * dr3
        for j in 1:Nθ
            θ = (j - 0.5) * dθ
            for k in 1:Nφ
                φ = (k - 0.5) * dφ
                x = r * sin(θ) * cos(φ)
                y = r * sin(θ) * sin(φ)
                z = r * cos(θ)
                norm_3d += abs2(hydrogen_psi(1, 0, 0, x, y, z)) * r^2 * sin(θ) * dr3 * dθ * dφ
            end
        end
    end
    @test norm_3d ≈ 1.0 atol=0.01
end

# ============================================================================
# Molecular orbitals (EQ:H2-HEITLER-LONDON)
# ============================================================================

@testset "Molecular orbitals" begin
    # Overlap integral S(R) analytical formula
    R = 1.4  # near equilibrium bond length in a.u.
    S = Lyr._overlap_1s(R)
    @test S ≈ (1.0 + R + R^2 / 3.0) * exp(-R) atol=1e-14

    # S(0) = 1 (complete overlap when nuclei coincide)
    @test Lyr._overlap_1s(0.0) ≈ 1.0 atol=1e-14

    # S → 0 as R → ∞
    @test Lyr._overlap_1s(50.0) < 1e-10

    # Bonding orbital has density at midpoint
    ψ_bond = h2_bonding(1.4, 0.0, 0.0, 0.0)
    @test isa(ψ_bond, ComplexF64)
    @test abs2(ψ_bond) > 0.01

    # Antibonding orbital has node at midpoint (by symmetry)
    ψ_anti = h2_antibonding(1.4, 0.0, 0.0, 0.0)
    @test abs(ψ_anti) < 1e-14

    # Bonding density at midpoint > antibonding density off-midpoint at same r
    # (qualitative check that bonding accumulates charge between nuclei)
    ψ_bond_mid = abs2(h2_bonding(1.4, 0.0, 0.0, 0.0))
    ψ_bond_off = abs2(h2_bonding(1.4, 2.0, 0.0, 0.0))
    @test ψ_bond_mid > ψ_bond_off

    # LCAO molecular_orbital matches h2_bonding
    S14 = Lyr._overlap_1s(1.4)
    norm_bond = 1.0 / sqrt(2.0 + 2.0 * S14)
    ψ_lcao = Lyr.molecular_orbital(
        ComplexF64[norm_bond, norm_bond],
        [(1, 0, 0), (1, 0, 0)],
        [(0.0, 0.0, -0.7), (0.0, 0.0, 0.7)],
        0.0, 0.0, 0.0
    )
    @test ψ_lcao ≈ h2_bonding(1.4, 0.0, 0.0, 0.0) atol=1e-14
end

# ============================================================================
# Field Protocol integration
# ============================================================================

@testset "Field Protocol integration" begin
    # HydrogenOrbitalField returns ComplexScalarField3D
    field = HydrogenOrbitalField(1, 0, 0)
    @test isa(field, ComplexScalarField3D)

    # evaluate matches direct hydrogen_psi
    ψ = evaluate(field, 0.0, 0.0, 0.0)
    @test ψ ≈ 1.0 / sqrt(π) + 0.0im atol=1e-12

    # Domain scales with n²
    field3 = HydrogenOrbitalField(3, 2, 0)
    dom = domain(field3)
    @test dom.max[1] ≈ 9.0 * 2.5 atol=1e-10  # n² × a₀ × 2.5

    # characteristic_scale = n × a₀
    @test characteristic_scale(field3) ≈ 3.0 atol=1e-14

    # Voxelize produces non-empty grid
    grid = voxelize(field)
    @test active_voxel_count(grid.tree) > 0

    # Custom R_max
    field_custom = HydrogenOrbitalField(1, 0, 0; R_max=5.0)
    @test domain(field_custom).max[1] ≈ 5.0 atol=1e-14

    # MolecularOrbitalField
    mf = MolecularOrbitalField(
        [1.0, 1.0],
        [(1, 0, 0), (1, 0, 0)],
        [(0.0, 0.0, -0.7), (0.0, 0.0, 0.7)]
    )
    @test isa(mf, ComplexScalarField3D)
    @test abs2(evaluate(mf, 0.0, 0.0, 0.0)) > 0.0

    # MolecularOrbitalField domain includes center offsets
    dom_m = domain(mf)
    @test dom_m.max[3] ≥ 2.5 + 0.7  # n²×a₀×2.5 + max_center
end

end  # @testset "Hydrogen Atom"
