# camera.jl — GR camera with tetrad (local Lorentz frame)
#
# The camera defines a local orthonormal frame at a spacetime point.
# For each pixel, the tetrad maps pixel coordinates to an initial
# null momentum on the light cone.

"""
    GRCamera{M<:MetricSpace}

Camera for general relativistic ray tracing.

# Fields
- `metric::M` — the spacetime metric
- `position::SVec4d` — spacetime position (t, r, θ, φ)
- `four_velocity::SVec4d` — camera 4-velocity u^μ (contravariant, timelike)
- `tetrad::SMat4d` — local orthonormal frame e_a^μ (columns = tetrad legs)
- `fov::Float64` — field of view in degrees
- `resolution::Tuple{Int, Int}` — (width, height)
"""
struct GRCamera{M<:MetricSpace}
    metric::M
    position::SVec4d
    four_velocity::SVec4d
    tetrad::SMat4d
    fov::Float64
    resolution::Tuple{Int, Int}
end

"""
    static_observer_tetrad(m::Schwarzschild, x::SVec4d) -> Tuple{SVec4d, SMat4d}

Construct tetrad for a static observer at position x in Schwarzschild coordinates.

Returns `(u^μ, e_a^μ)` where:
- e_0 = u (time direction)
- e_1 = radial (inward, toward BH)
- e_2 = θ direction
- e_3 = φ direction

The tetrad satisfies g_μν e_a^μ e_b^ν = η_ab (Minkowski).
"""
function static_observer_tetrad(m::Schwarzschild, x::SVec4d)::Tuple{SVec4d, SMat4d}
    r, θ = x[2], x[3]
    f = 1.0 - 2.0 * m.M / r
    sqrtf = sqrt(f)
    sinθ = sin(θ)

    # Static observer: u^μ = (1/√f, 0, 0, 0)
    u = SVec4d(1.0 / sqrtf, 0.0, 0.0, 0.0)

    # Orthonormal spatial legs (from diagonal metric):
    # e_1^r = √f (radial — points inward toward BH for rendering)
    # e_2^θ = 1/r
    # e_3^φ = 1/(r sinθ)
    e0 = u
    e1 = SVec4d(0.0, sqrtf, 0.0, 0.0)       # radial
    e2 = SVec4d(0.0, 0.0, 1.0 / r, 0.0)     # polar
    e3 = SVec4d(0.0, 0.0, 0.0, 1.0 / (r * sinθ))  # azimuthal

    tetrad = SMat4d(
        e0[1], e1[1], e2[1], e3[1],
        e0[2], e1[2], e2[2], e3[2],
        e0[3], e1[3], e2[3], e3[3],
        e0[4], e1[4], e2[4], e3[4]
    )

    (u, tetrad)
end

"""
    static_camera(m, r, θ, φ, fov, resolution) -> GRCamera

Convenience constructor for a static observer camera at (r, θ, φ).
"""
function static_camera(m::MetricSpace{4}, r::Float64, θ::Float64, φ::Float64,
                        fov::Float64, resolution::Tuple{Int, Int})::GRCamera
    x = SVec4d(0.0, r, θ, φ)
    u, tetrad = static_observer_tetrad(m, x)
    GRCamera(m, x, u, tetrad, fov, resolution)
end

"""
    pixel_to_momentum(cam::GRCamera, i::Int, j::Int) -> SVec4d

Convert pixel (i, j) to initial covariant null momentum p_μ.

Maps pixel coordinates to a direction in the camera's local frame,
then transforms to coordinate-basis null momentum via the tetrad.
"""
function pixel_to_momentum(cam::GRCamera, i::Int, j::Int)::SVec4d
    width, height = cam.resolution
    aspect = Float64(width) / Float64(height)
    half_fov = tan(deg2rad(cam.fov / 2.0))

    # Pixel → normalized coordinates (matching Render.jl camera_ray pattern)
    u = (Float64(i) - 0.5) / Float64(width)
    v = 1.0 - (Float64(j) - 0.5) / Float64(height)
    px = (2.0 * u - 1.0) * aspect * half_fov
    py = (2.0 * v - 1.0) * half_fov

    # Spatial direction in local frame: forward=e1, right=e3, up=e2
    # Normalize the spatial part
    n_norm = sqrt(1.0 + px^2 + py^2)
    nx = 1.0 / n_norm   # forward (radial, toward BH)
    ny = py / n_norm     # up (polar)
    nz = px / n_norm     # right (azimuthal)

    # Contravariant null 4-momentum: k^μ = -E(u^μ + nⁱ eᵢ^μ)
    # E is arbitrary for null geodesics; set E = 1
    e = cam.tetrad  # columns: e0, e1, e2, e3
    u_vec = cam.four_velocity

    k_contra = -(u_vec + nx * e[:, 2] + ny * e[:, 3] + nz * e[:, 4])

    # Lower index: p_μ = g_{μν} k^ν
    g = metric(cam.metric, cam.position)
    g * k_contra
end
