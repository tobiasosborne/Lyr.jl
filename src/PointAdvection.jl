# PointAdvection.jl — Advect point sets through velocity fields
#
# Euler (1st order) and RK4 (4th order) integration for particle advection
# through VectorField3D. Multithreaded over particles.

"""
    advect_points(positions, field::VectorField3D, dt::Float64;
                  method::Symbol=:rk4) -> Vector{NTuple{3,Float64}}

Advect particle positions through a velocity field for one time step.

# Arguments
- `positions`: vector of positions (anything indexable with [1],[2],[3])
- `field::VectorField3D`: velocity field
- `dt::Float64`: time step
- `method::Symbol`: `:euler` (1st order) or `:rk4` (4th order, default)

# Example
```julia
vfield = VectorField3D((x,y,z) -> SVec3d(1.0, 0.0, 0.0),
                        BoxDomain(SVec3d(-10,-10,-10), SVec3d(10,10,10)), 1.0)
new_pos = advect_points([(0.0, 0.0, 0.0)], vfield, 0.5)
```
"""
function advect_points(positions::AbstractVector, field::VectorField3D, dt::Float64;
                       method::Symbol=:rk4)
    n = length(positions)
    result = Vector{NTuple{3,Float64}}(undef, n)

    Threads.@threads for i in 1:n
        p = positions[i]
        x, y, z = Float64(p[1]), Float64(p[2]), Float64(p[3])

        if method === :euler
            v = evaluate(field, x, y, z)
            result[i] = (x + dt * v[1], y + dt * v[2], z + dt * v[3])
        elseif method === :rk4
            v1 = evaluate(field, x, y, z)
            x1 = x + 0.5*dt*v1[1]; y1 = y + 0.5*dt*v1[2]; z1 = z + 0.5*dt*v1[3]
            v2 = evaluate(field, x1, y1, z1)
            x2 = x + 0.5*dt*v2[1]; y2 = y + 0.5*dt*v2[2]; z2 = z + 0.5*dt*v2[3]
            v3 = evaluate(field, x2, y2, z2)
            x3 = x + dt*v3[1]; y3 = y + dt*v3[2]; z3 = z + dt*v3[3]
            v4 = evaluate(field, x3, y3, z3)
            s = dt / 6.0
            result[i] = (x + s*(v1[1] + 2*v2[1] + 2*v3[1] + v4[1]),
                         y + s*(v1[2] + 2*v2[2] + 2*v3[2] + v4[2]),
                         z + s*(v1[3] + 2*v2[3] + 2*v3[3] + v4[3]))
        else
            throw(ArgumentError("Unknown method: $method. Use :euler or :rk4"))
        end
    end
    result
end
