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

        # Null-cone re-projection: keep photon exactly on the light cone
        p_new = renormalize_null(m, x_new, p_new)

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

# ─────────────────────────────────────────────────────────────────────
# Volumetric trace_pixel — emission-absorption integration along geodesic
# ─────────────────────────────────────────────────────────────────────

"""
    trace_pixel(cam, config, vol::VolumetricMatter, sky, i, j) -> NTuple{3, Float64}

Trace a single pixel through volumetric matter by accumulating emission and
absorption at each geodesic step. Deterministic ray marching (not stochastic).
"""
function trace_pixel(cam::GRCamera, config::GRRenderConfig,
                     vol::VolumetricMatter,
                     sky::Union{CelestialSphere, Nothing},
                     i::Int, j::Int)::NTuple{3, Float64}
    p0 = pixel_to_momentum(cam, i, j)
    m = cam.metric
    x, p = cam.position, p0
    dl_base = config.integrator.step_size
    cfg = config.integrator
    rh = horizon_radius(m)
    M_val = rh / 2.0

    # Observer 4-velocity (static observer at camera position)
    f_obs = 1.0 - 2.0 * m.M / cam.position[2]
    u_obs = SVec4d(1.0 / sqrt(f_obs), 0.0, 0.0, 0.0)

    I_acc = 0.0   # accumulated intensity
    τ_acc = 0.0   # accumulated optical depth
    density_threshold = 1e-12

    for step in 1:cfg.max_steps
        r = x[2]
        dl = M_val > 0.0 ? adaptive_step(dl_base, r, M_val) : dl_base
        x_new, p_new = verlet_step(m, x, p, dl)

        # Null-cone re-projection: keep photon exactly on the light cone
        p_new = renormalize_null(m, x_new, p_new)

        # ── Accumulate emission/absorption ──
        r_new = x_new[2]
        if vol.inner_radius <= r_new <= vol.outer_radius
            ρ = evaluate_density(vol.density_source, r_new, x_new[3], x_new[4])
            if ρ > density_threshold
                T = disk_temperature(r_new, vol.inner_radius)
                j, α = emission_absorption(ρ, T)
                dl_proper = abs(dl)

                if config.use_redshift
                    z_plus_1 = volumetric_redshift(m, x_new, p_new, p0, u_obs)
                    j = j / z_plus_1^3
                end

                dτ = α * dl_proper
                dI = j * dl_proper * exp(-τ_acc)
                τ_acc += dτ
                I_acc += dI
            end
        end

        x, p = x_new, p_new

        # ── Termination ──
        if r_new <= rh * cfg.r_min_factor
            return _volumetric_final_color(I_acc, τ_acc, (0.0, 0.0, 0.0))
        end

        if r_new >= cfg.r_max
            bg = _sky_color(sky, x[3], x[4], config.background)
            return _volumetric_final_color(I_acc, τ_acc, bg)
        end

        if is_singular(m, x)
            return _volumetric_final_color(I_acc, τ_acc, (0.0, 0.0, 0.0))
        end

        H = abs(0.5 * dot(p, metric_inverse(m, x) * p))
        if H > cfg.h_tolerance
            bg = _sky_color(sky, x[3], x[4], config.background)
            return _volumetric_final_color(I_acc, τ_acc, bg)
        end
    end

    bg = _sky_color(sky, x[3], x[4], config.background)
    _volumetric_final_color(I_acc, τ_acc, bg)
end

"""Map accumulated intensity + optical depth to final HDR RGB, blending with background."""
function _volumetric_final_color(I_acc::Float64, τ_acc::Float64,
                                  bg::NTuple{3, Float64})::NTuple{3, Float64}
    I_acc <= 0.0 && return bg
    # HDR blackbody color scaled by accumulated intensity (no clamping — let
    # external tone mapping handle the dynamic range)
    bb = blackbody_color(clamp(I_acc, 0.0, 2.0))
    disk_color = (bb[1] * I_acc, bb[2] * I_acc, bb[3] * I_acc)
    # Beer-Lambert: background attenuated by accumulated optical depth
    transmittance = exp(-τ_acc)
    (disk_color[1] + bg[1] * transmittance,
     disk_color[2] + bg[2] * transmittance,
     disk_color[3] + bg[3] * transmittance)
end

"""Look up sky color, fall back to background color or checkerboard."""
function _sky_color(sky::Union{CelestialSphere, Nothing},
                     θ::Float64, φ::Float64,
                     bg::NTuple{3, Float64}=(NaN, NaN, NaN))::NTuple{3, Float64}
    sky !== nothing && return sphere_lookup(sky, θ, φ)
    isnan(bg[1]) && return checkerboard_sphere(θ, φ)
    bg
end

# ─────────────────────────────────────────────────────────────────────
# gr_render_image — unified rendering entry point
# ─────────────────────────────────────────────────────────────────────

"""
    gr_render_image(cam, config; disk=nothing, volume=nothing, sky=nothing)
        -> Matrix{NTuple{3, Float64}}

Render a GR image. For each pixel, integrate a geodesic backward from
the camera and determine the color.

Accepts either a `ThinDisk` (equatorial plane) or `VolumetricMatter`
(emission-absorption integration). If both are provided, volumetric takes
precedence.

Returns a `height × width` matrix of RGB tuples, compatible with `Lyr.write_ppm`.
"""
function gr_render_image(cam::GRCamera, config::GRRenderConfig;
                          disk::Union{ThinDisk, Nothing} = nothing,
                          volume::Union{VolumetricMatter, Nothing} = nothing,
                          sky::Union{CelestialSphere, Nothing} = nothing
                          )::Matrix{NTuple{3, Float64}}
    width, height = cam.resolution
    pixels = Matrix{NTuple{3, Float64}}(undef, height, width)

    if config.use_threads
        Threads.@threads for j in 1:height
            for i in 1:width
                if volume !== nothing
                    pixels[j, i] = trace_pixel(cam, config, volume, sky, i, j)
                else
                    pixels[j, i] = trace_pixel(cam, config, disk, sky, i, j)
                end
            end
        end
    else
        for j in 1:height
            for i in 1:width
                if volume !== nothing
                    pixels[j, i] = trace_pixel(cam, config, volume, sky, i, j)
                else
                    pixels[j, i] = trace_pixel(cam, config, disk, sky, i, j)
                end
            end
        end
    end

    pixels
end
