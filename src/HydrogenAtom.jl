# HydrogenAtom.jl — Hydrogen eigenstates and molecular orbital construction
#
# Analytical hydrogen wavefunctions ψ_nlm and LCAO molecular orbitals
# as Field Protocol ComplexScalarField3D instances for visualization.
#
# Physics reference: Schwabl, "Quantum Mechanics" (4th ed.)

# Bohr radius in atomic units
const a₀ = 1.0

# ============================================================================
# Mathematical building blocks
# ============================================================================

"""
    laguerre(n, α, x)

Associated Laguerre polynomial L_n^α(x) via the three-term recurrence.
"""
function laguerre(n::Int, α::Float64, x::Float64)
    # EQ:LAGUERRE-RECURRENCE — Abramowitz & Stegun §22.7
    # L_0^α = 1,  L_1^α = 1 + α - x
    # k L_k^α = (2k-1+α-x) L_{k-1}^α - (k-1+α) L_{k-2}^α
    n == 0 && return 1.0
    n == 1 && return 1.0 + α - x
    L0 = 1.0
    L1 = 1.0 + α - x
    for k in 2:n
        L2 = ((2k - 1 + α - x) * L1 - (k - 1 + α) * L0) / k
        L0, L1 = L1, L2
    end
    return L1
end

"""
    assoc_legendre(l, m, x)

Associated Legendre polynomial P_l^m(x) with Condon-Shortley phase included.
"""
function assoc_legendre(l::Int, m::Int, x::Float64)
    # EQ:ASSOC-LEGENDRE — Arfken §12.5, includes (-1)^m Condon-Shortley phase
    am = abs(m)
    # P_am^am via double factorial with CS phase
    pmm = 1.0
    if am > 0
        somx2 = sqrt(max(0.0, 1.0 - x^2))
        fact = 1.0
        for i in 1:am
            pmm *= -fact * somx2
            fact += 2.0
        end
    end
    am == l && return pmm
    pmm1 = x * (2am + 1) * pmm
    (am + 1) == l && return pmm1
    for ll in (am + 2):l
        pll = (x * (2ll - 1) * pmm1 - (ll + am - 1) * pmm) / (ll - am)
        pmm = pmm1
        pmm1 = pll
    end
    return pmm1
end

"""
    spherical_harmonic(l, m, θ, φ) → ComplexF64

Complex spherical harmonic Y_l^m(θ,φ) in the Condon-Shortley convention.
"""
function spherical_harmonic(l::Int, m::Int, θ::Float64, φ::Float64)
    # EQ:SPHERICAL-HARMONICS — Schwabl Eq. (5.15), p. 94
    # Y_l^m = √((2l+1)/(4π) × (l-m)!/(l+m)!) × P̃_l^m(cosθ) × e^{imφ}     (m ≥ 0)
    # Y_l^{-|m|} = (-1)^{|m|} conj(Y_l^{|m|})
    if m < 0
        return (-1)^(-m) * conj(spherical_harmonic(l, -m, θ, φ))
    end
    norm = sqrt((2l + 1) / (4π) * factorial(l - m) / factorial(l + m))
    P = assoc_legendre(l, m, cos(θ))
    return norm * P * exp(im * m * φ)
end

# ============================================================================
# Hydrogen atom wavefunctions
# ============================================================================

"""
    hydrogen_radial(n, l, r)

Hydrogen radial wavefunction R_nl(r) in atomic units (a₀ = 1).
"""
function hydrogen_radial(n::Int, l::Int, r::Float64)
    # EQ:H-RADIAL — Schwabl Eq. (6.37), p. 128
    # R_nl(r) = √((2/na₀)³ (n-l-1)!/(2n(n+l)!)) × e^{-ρ/2} ρ^l L_{n-l-1}^{2l+1}(ρ)
    # where ρ = 2r/(na₀)
    ρ = 2.0 * r / (n * a₀)
    norm = sqrt((2.0 / (n * a₀))^3 * factorial(n - l - 1) / (2n * factorial(n + l)))
    norm * exp(-ρ / 2) * ρ^l * laguerre(n - l - 1, 2l + 1.0, ρ)
end

"""
    hydrogen_psi(n, l, m, x, y, z) → ComplexF64

Full hydrogen eigenstate ψ_nlm(r,θ,φ) = R_nl(r) Y_l^m(θ,φ) evaluated at
Cartesian coordinates (x, y, z) in atomic units.
"""
function hydrogen_psi(n::Int, l::Int, m::Int, x::Float64, y::Float64, z::Float64)
    # EQ:H-EIGENSTATE — Schwabl Eq. (6.39), ψ_nlm = R_nl × Y_l^m
    r = sqrt(x^2 + y^2 + z^2)
    if r < 1e-12
        # At origin: only l=0 survives (ρ^l → 0 for l > 0)
        l == 0 || return ComplexF64(0.0, 0.0)
        return hydrogen_radial(n, 0, 0.0) * spherical_harmonic(0, 0, 0.0, 0.0)
    end
    θ = acos(clamp(z / r, -1.0, 1.0))
    φ = atan(y, x)
    return hydrogen_radial(n, l, r) * spherical_harmonic(l, m, θ, φ)
end

"""
    hydrogen_psi_centered(n, l, m, x, y, z, cx, cy, cz) → ComplexF64

Hydrogen eigenstate centered at (cx, cy, cz) instead of the origin.
"""
function hydrogen_psi_centered(n::Int, l::Int, m::Int,
                               x::Float64, y::Float64, z::Float64,
                               cx::Float64, cy::Float64, cz::Float64)
    hydrogen_psi(n, l, m, x - cx, y - cy, z - cz)
end

# ============================================================================
# Molecular orbitals (LCAO)
# ============================================================================

"""
    molecular_orbital(coeffs, orbitals, centers, x, y, z) → ComplexF64

LCAO molecular orbital: Σ cᵢ ψ_{nᵢlᵢmᵢ}(r - Rᵢ).

- `coeffs` — expansion coefficients (real or complex)
- `orbitals` — vector of (n, l, m) quantum number tuples
- `centers` — vector of (x, y, z) nuclear positions
"""
function molecular_orbital(coeffs::AbstractVector{<:Number},
                           orbitals::AbstractVector{NTuple{3,Int}},
                           centers::AbstractVector{NTuple{3,Float64}},
                           x::Float64, y::Float64, z::Float64)
    result = ComplexF64(0.0, 0.0)
    for i in eachindex(coeffs)
        n, l, m = orbitals[i]
        cx, cy, cz = centers[i]
        result += ComplexF64(coeffs[i]) * hydrogen_psi(n, l, m, x - cx, y - cy, z - cz)
    end
    return result
end

"""
    _overlap_1s(R) → Float64

Overlap integral S(R) = ⟨1s_A|1s_B⟩ for two hydrogen 1s orbitals separated by distance R.
"""
function _overlap_1s(R::Float64)
    # EQ:H2-OVERLAP-1S — Schwabl Eq. (15.19b), exact for 1s orbitals
    # S(R) = (1 + R/a₀ + R²/(3a₀²)) e^{-R/a₀}
    x = R / a₀
    return (1.0 + x + x^2 / 3.0) * exp(-x)
end

"""
    h2_bonding(R, x, y, z) → ComplexF64

σg bonding orbital of H₂: (ψ_A(1s) + ψ_B(1s)) / √(2+2S).
Nuclei placed at (0, 0, ±R/2) along the z-axis.
"""
function h2_bonding(R::Float64, x::Float64, y::Float64, z::Float64)
    # EQ:H2-BONDING — Heitler-London σg, Schwabl §15.1
    S = _overlap_1s(R)
    ψA = hydrogen_psi(1, 0, 0, x, y, z - R / 2)
    ψB = hydrogen_psi(1, 0, 0, x, y, z + R / 2)
    return (ψA + ψB) / sqrt(2.0 + 2.0 * S)
end

"""
    h2_antibonding(R, x, y, z) → ComplexF64

σu antibonding orbital of H₂: (ψ_A(1s) - ψ_B(1s)) / √(2-2S).
Nuclei placed at (0, 0, ±R/2) along the z-axis.
"""
function h2_antibonding(R::Float64, x::Float64, y::Float64, z::Float64)
    # EQ:H2-ANTIBONDING — Heitler-London σu, Schwabl §15.1
    S = _overlap_1s(R)
    ψA = hydrogen_psi(1, 0, 0, x, y, z - R / 2)
    ψB = hydrogen_psi(1, 0, 0, x, y, z + R / 2)
    return (ψA - ψB) / sqrt(2.0 - 2.0 * S)
end

# ============================================================================
# Field Protocol convenience constructors
# ============================================================================

"""
    HydrogenOrbitalField(n, l, m; R_max=auto) → ComplexScalarField3D

Create a Field Protocol field for hydrogen eigenstate ψ_nlm.
Domain and characteristic scale are set automatically from quantum numbers.

# Example
```julia
field = HydrogenOrbitalField(3, 2, 0)     # 3d_z² orbital
visualize(field; output="3d_z2.ppm")       # one-call rendering
grid = voxelize(field)                      # or get a VDB grid
```
"""
function HydrogenOrbitalField(n::Int, l::Int, m::Int; R_max::Float64=NaN)
    if isnan(R_max)
        R_max = n^2 * a₀ * 2.5  # outer extent scales as n²
    end
    ComplexScalarField3D(
        (x, y, z) -> hydrogen_psi(n, l, m, x, y, z),
        BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
        n * a₀  # characteristic scale ~ n × Bohr radius
    )
end

"""
    MolecularOrbitalField(coeffs, orbitals, centers; R_max=auto) → ComplexScalarField3D

Create a Field Protocol field for an LCAO molecular orbital Σ cᵢ ψᵢ(r - Rᵢ).

# Arguments
- `coeffs` — expansion coefficients (real or complex)
- `orbitals` — vector of (n, l, m) quantum number tuples
- `centers` — vector of (x, y, z) nuclear positions

# Example
```julia
# H₂ bonding-like orbital at R = 1.4 a.u.
field = MolecularOrbitalField(
    [1.0, 1.0],
    [(1,0,0), (1,0,0)],
    [(0.0, 0.0, -0.7), (0.0, 0.0, 0.7)]
)
visualize(field)
```
"""
function MolecularOrbitalField(coeffs::AbstractVector{<:Number},
                               orbitals::AbstractVector{NTuple{3,Int}},
                               centers::AbstractVector{NTuple{3,Float64}};
                               R_max::Float64=NaN)
    ccoeffs = ComplexF64.(coeffs)
    corbitals = collect(NTuple{3,Int}, orbitals)
    ccenters = collect(NTuple{3,Float64}, centers)
    if isnan(R_max)
        max_n = maximum(o[1] for o in corbitals)
        max_center = maximum(maximum(abs.(c)) for c in ccenters)
        R_max = max_n^2 * a₀ * 2.5 + max_center
    end
    scale = max(1.0, maximum(o[1] for o in corbitals)) * a₀
    ComplexScalarField3D(
        (x, y, z) -> molecular_orbital(ccoeffs, corbitals, ccenters, x, y, z),
        BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
        scale
    )
end
