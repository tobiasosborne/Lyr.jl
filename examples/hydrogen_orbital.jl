# hydrogen_orbital.jl — Hydrogen atom probability density via Field Protocol
#
# Demonstrates: ComplexScalarField3D → visualize()
# Physics: Analytical hydrogen wavefunction ψ_nlm → |ψ|² probability density
#
# Usage: julia --project examples/hydrogen_orbital.jl

using Lyr

# Bohr radius (natural units)
const a0 = 1.0

# Associated Laguerre polynomial L_n^α(x) via recurrence
function laguerre(n::Int, α::Float64, x::Float64)
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

# Associated Legendre polynomial P_l^m(x)
function assoc_legendre(l::Int, m::Int, x::Float64)
    am = abs(m)
    # P_am^am via double factorial
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
    # P_{am+1}^am
    pmm1 = x * (2am + 1) * pmm
    (am + 1) == l && return pmm1
    for ll in (am+2):l
        pll = (x * (2ll - 1) * pmm1 - (ll + am - 1) * pmm) / (ll - am)
        pmm = pmm1
        pmm1 = pll
    end
    return pmm1
end

# Real spherical harmonic Y_lm (tesseral)
function real_Ylm(l::Int, m::Int, theta::Float64, phi::Float64)
    am = abs(m)
    norm = sqrt((2l + 1) / (4π) * factorial(l - am) / factorial(l + am))
    P = assoc_legendre(l, am, cos(theta))
    if m > 0
        return norm * P * sqrt(2.0) * cos(m * phi)
    elseif m < 0
        return norm * P * sqrt(2.0) * sin(am * phi)
    else
        return norm * P
    end
end

# Hydrogen radial wavefunction R_nl(r)
function radial_R(n::Int, l::Int, r::Float64)
    rho = 2.0 * r / (n * a0)
    norm = sqrt((2.0 / (n * a0))^3 * factorial(n - l - 1) / (2n * factorial(n + l)))
    norm * exp(-rho / 2) * rho^l * laguerre(n - l - 1, 2l + 1.0, rho)
end

# Full wavefunction (real-valued via real spherical harmonics)
function psi_nlm(n::Int, l::Int, m::Int, x::Float64, y::Float64, z::Float64)
    r = sqrt(x^2 + y^2 + z^2)
    r < 1e-10 && return (l == 0 ? radial_R(n, 0, 0.0) : 0.0) + 0.0im
    theta = acos(clamp(z / r, -1.0, 1.0))
    phi = atan(y, x)
    (radial_R(n, l, r) * real_Ylm(l, m, theta, phi)) + 0.0im
end

# Choose orbital: 3d_z² (n=3, l=2, m=0)
n, l, m = 3, 2, 0
label = "3d_z2"

R_max = n^2 * a0 * 2.5  # outer extent scales as n²

field = ComplexScalarField3D(
    (x, y, z) -> psi_nlm(n, l, m, x, y, z),
    BoxDomain((-R_max, -R_max, -R_max), (R_max, R_max, R_max)),
    n * a0  # characteristic scale ~ n × Bohr radius
)

println("Rendering hydrogen $label orbital...")
pixels = visualize(field;
    transfer_function=tf_viridis(),
    sigma_scale=3.0,
    emission_scale=6.0,
    width=512, height=512,
    spp=4,
    background=(0.005, 0.005, 0.015),
    output="hydrogen_$(label).ppm"
)
println("Done → hydrogen_$(label).ppm")
