# render.jl — GR rendering pipeline
#
# For each pixel: generate initial null momentum from camera tetrad,
# integrate geodesic backward in time, determine color from termination
# condition (horizon → black, escaped → sky/background, disk → emissivity).

"""
    GRRenderConfig(; kwargs...)

Configuration for GR rendering.

# Fields
- `integrator::IntegratorConfig` — geodesic integration parameters
- `background::NTuple{3, Float64}` — color for escaped rays with no skybox
- `use_redshift::Bool` — apply frequency shift to disk emission
- `use_threads::Bool` — use `Threads.@threads` over rows
"""
struct GRRenderConfig
    integrator::IntegratorConfig
    background::NTuple{3, Float64}
    use_redshift::Bool
    use_threads::Bool
end

function GRRenderConfig(;
    integrator::IntegratorConfig = IntegratorConfig(),
    background::NTuple{3, Float64} = (0.0, 0.0, 0.02),
    use_redshift::Bool = true,
    use_threads::Bool = true
)
    GRRenderConfig(integrator, background, use_redshift, use_threads)
end

"""
    trace_pixel(cam, config, disk, sky, i, j) -> NTuple{3, Float64}

Trace a single pixel by integrating a geodesic backward from the camera.

Returns an RGB color tuple.
"""
function trace_pixel(cam::GRCamera, config::GRRenderConfig,
                     disk::Union{ThinDisk, Nothing},
                     sky::Union{CelestialSphere, Nothing},
                     i::Int, j::Int)::NTuple{3, Float64}
    p0 = pixel_to_momentum(cam, i, j)
    initial = GeodesicState(cam.position, p0)

    m = cam.metric
    x, p = initial.x, initial.p
    dl_base = config.integrator.step_size
    cfg = config.integrator
    rh = horizon_radius(m)
    M_val = rh / 2.0

    prev_state = initial

    for step in 1:cfg.max_steps
        # Adaptive step
        dl = M_val > 0.0 ? adaptive_step(dl_base, x[2], M_val) : dl_base

        x_new, p_new = verlet_step(m, x, p, dl)
        curr_state = GeodesicState(x_new, p_new)

        # ── Check disk crossing ──
        if disk !== nothing
            crossing = check_disk_crossing(prev_state, curr_state, disk)
            if crossing !== nothing
                r_cross, _ = crossing
                intensity = disk_emissivity(disk, r_cross)

                if config.use_redshift
                    u_emit = keplerian_four_velocity(m, r_cross)
                    f_obs = 1.0 - 2.0 * m.M / cam.position[2]
                    u_obs = SVec4d(1.0 / sqrt(f_obs), 0.0, 0.0, 0.0)
                    z_plus_1 = redshift_factor(p_new, u_emit, p0, u_obs)
                    intensity = intensity / z_plus_1^3
                end

                # Boost by 5× for visibility (emissivity r^{-3} is very faint)
                return blackbody_color(clamp(intensity * 5.0, 0.0, 2.0))
            end
        end

        x, p = x_new, p_new
        prev_state = curr_state
        r = x[2]

        # ── Termination ──
        if r <= horizon_radius(m) * cfg.r_min_factor
            return (0.0, 0.0, 0.0)  # black hole shadow
        end

        if r >= cfg.r_max
            # Escaped — look up sky
            θ, φ = x[3], x[4]
            if sky !== nothing
                return sphere_lookup(sky, θ, φ)
            else
                return checkerboard_sphere(θ, φ)
            end
        end

        if is_singular(m, x)
            return (0.0, 0.0, 0.0)
        end

        # H drift — terminate but still try sky lookup
        H = abs(0.5 * dot(p, metric_inverse(m, x) * p))
        if H > cfg.h_tolerance
            θ_f, φ_f = x[3], x[4]
            if sky !== nothing
                return sphere_lookup(sky, θ_f, φ_f)
            else
                return checkerboard_sphere(θ_f, φ_f)
            end
        end
    end

    # Max steps exhausted — ray didn't clearly resolve. Use sky at final position.
    θ_f, φ_f = x[3], x[4]
    if sky !== nothing
        return sphere_lookup(sky, θ_f, φ_f)
    else
        return checkerboard_sphere(θ_f, φ_f)
    end
end

"""
    gr_render_image(cam, config; disk=nothing, sky=nothing)
        -> Matrix{NTuple{3, Float64}}

Render a GR image. For each pixel, integrate a geodesic backward from
the camera and determine the color.

Returns a `height × width` matrix of RGB tuples, compatible with `Lyr.write_ppm`.
"""
function gr_render_image(cam::GRCamera, config::GRRenderConfig;
                          disk::Union{ThinDisk, Nothing} = nothing,
                          sky::Union{CelestialSphere, Nothing} = nothing
                          )::Matrix{NTuple{3, Float64}}
    width, height = cam.resolution
    pixels = Matrix{NTuple{3, Float64}}(undef, height, width)

    if config.use_threads
        Threads.@threads for j in 1:height
            for i in 1:width
                pixels[j, i] = trace_pixel(cam, config, disk, sky, i, j)
            end
        end
    else
        for j in 1:height
            for i in 1:width
                pixels[j, i] = trace_pixel(cam, config, disk, sky, i, j)
            end
        end
    end

    pixels
end
