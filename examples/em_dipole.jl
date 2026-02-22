# em_dipole.jl — Electric field of a static electric dipole
#
# Demonstrates: ScalarField3D → visualize()
# Physics: Coulomb electric field from two point charges ±q
#
# Usage: julia --project examples/em_dipole.jl

using Lyr

# Dipole: +q at (0, 0, +d/2), -q at (0, 0, -d/2)
d = 2.0   # separation
q = 1.0   # charge magnitude

function dipole_E_magnitude(x, y, z)
    # Position vectors from each charge
    r_plus  = sqrt(x^2 + y^2 + (z - d/2)^2)
    r_minus = sqrt(x^2 + y^2 + (z + d/2)^2)

    # Avoid singularity at charge locations
    r_plus  < 0.3 && return 0.0
    r_minus < 0.3 && return 0.0

    # Electric field from each charge (Coulomb, E ~ q/r²)
    # E_+ points away from +q, E_- points toward -q
    Ex_p = q * x / r_plus^3
    Ey_p = q * y / r_plus^3
    Ez_p = q * (z - d/2) / r_plus^3

    Ex_m = -q * x / r_minus^3
    Ey_m = -q * y / r_minus^3
    Ez_m = -q * (z + d/2) / r_minus^3

    # Total field magnitude
    Ex = Ex_p + Ex_m
    Ey = Ey_p + Ey_m
    Ez = Ez_p + Ez_m
    sqrt(Ex^2 + Ey^2 + Ez^2)
end

field = ScalarField3D(
    dipole_E_magnitude,
    BoxDomain((-5.0, -5.0, -5.0), (5.0, 5.0, 5.0)),
    1.0  # features ~1 unit (charge separation scale)
)

println("Rendering electric dipole field...")
pixels = visualize(field;
    transfer_function=tf_cool_warm(),
    sigma_scale=3.0,
    emission_scale=4.0,
    width=512, height=512,
    spp=4,
    denoise=true,
    output="em_dipole.ppm"
)
println("Done → em_dipole.ppm")
