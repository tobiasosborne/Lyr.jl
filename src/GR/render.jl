# render.jl — GR rendering pipeline
#
# For each pixel: generate initial null momentum from camera tetrad,
# integrate geodesic backward in time, determine color from termination
# condition (horizon → black, escaped → sky/background, disk → emissivity).

# Coordinate-system dispatch: extract r and convert to spherical
@inline _coord_r(::MetricSpace, x::SVec4d) = x[2]  # BL: r = x[2]
@inline _coord_r(::SchwarzschildKS, x::SVec4d) = sqrt(x[2]^2 + x[3]^2 + x[4]^2)

@inline _to_spherical(::MetricSpace, x::SVec4d) = (x[2], x[3], x[4])  # BL: (r, θ, φ)
@inline function _to_spherical(::SchwarzschildKS, x::SVec4d)
    r = sqrt(x[2]^2 + x[3]^2 + x[4]^2)
    r = max(r, 1e-15)
    θ = acos(clamp(x[4] / r, -1.0, 1.0))
    φ = atan(x[3], x[2])
    φ < 0.0 && (φ += 2π)
    (r, θ, φ)
end

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
    samples_per_pixel::Int
end

function GRRenderConfig(;
    integrator::IntegratorConfig = IntegratorConfig(),
    background::NTuple{3, Float64} = (0.0, 0.0, 0.02),
    use_redshift::Bool = true,
    use_threads::Bool = true,
    samples_per_pixel::Int = 1
)
    GRRenderConfig(integrator, background, use_redshift, use_threads, samples_per_pixel)
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
    stepper = cfg.stepper
    renorm_interval = cfg.renorm_interval
    rh = horizon_radius(m)
    M_val = rh / 2.0

    prev_state = initial

    for step in 1:cfg.max_steps
        # Adaptive step
        dl = M_val > 0.0 ? adaptive_step(dl_base, x[2], M_val) : dl_base

        x_new, p_new = _do_step(m, x, p, dl, stepper)

        # Null-cone re-projection
        if renorm_interval > 0 && step % renorm_interval == 0
            p_new = renormalize_null(m, x_new, p_new)
        end

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
    _trace_pixel_with_p0(cam, config, vol, sky, pixel_to_momentum(cam, i, j))
end

"""Internal: volumetric trace with pre-computed initial momentum (for supersampling)."""
function _trace_pixel_with_p0(cam::GRCamera, config::GRRenderConfig,
                               vol::VolumetricMatter,
                               sky::Union{CelestialSphere, Nothing},
                               p0::SVec4d)::NTuple{3, Float64}
    m = cam.metric
    x, p = cam.position, p0
    dl_base = config.integrator.step_size
    cfg = config.integrator
    stepper = cfg.stepper
    renorm_interval = cfg.renorm_interval
    rh = horizon_radius(m)
    M_val = rh / 2.0

    # Observer 4-velocity (static observer at camera position)
    f_obs = 1.0 - 2.0 * m.M / cam.position[2]
    u_obs = SVec4d(1.0 / sqrt(f_obs), 0.0, 0.0, 0.0)

    I_acc = 0.0   # accumulated intensity
    τ_acc = 0.0   # accumulated optical depth
    density_threshold = 1e-12

    for step in 1:cfg.max_steps
        r = _coord_r(m, x)
        dl = M_val > 0.0 ? adaptive_step(dl_base, r, M_val) : dl_base
        x_new, p_new = _do_step(m, x, p, dl, stepper)

        # Null-cone re-projection
        if renorm_interval > 0 && step % renorm_interval == 0
            p_new = renormalize_null(m, x_new, p_new)
        end

        # ── Accumulate emission/absorption ──
        r_new = _coord_r(m, x_new)
        if vol.inner_radius <= r_new <= vol.outer_radius
            r_d, θ_d, φ_d = _to_spherical(m, x_new)
            ρ = evaluate_density(vol.density_source, r_d, θ_d, φ_d)
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

                # Early exit: optically thick — background fully attenuated
                if τ_acc > 8.0
                    return _volumetric_final_color(I_acc, τ_acc, (0.0, 0.0, 0.0))
                end
            end
        end

        x, p = x_new, p_new

        # ── Termination ──
        if r_new <= rh * cfg.r_min_factor
            return _volumetric_final_color(I_acc, τ_acc, (0.0, 0.0, 0.0))
        end

        if r_new >= cfg.r_max
            bg = _sky_color(m, sky, x, config.background)
            return _volumetric_final_color(I_acc, τ_acc, bg)
        end

        if is_singular(m, x)
            return _volumetric_final_color(I_acc, τ_acc, (0.0, 0.0, 0.0))
        end
    end

    bg = _sky_color(m, sky, x, config.background)
    _volumetric_final_color(I_acc, τ_acc, bg)
end

"""Map accumulated intensity + optical depth to final HDR RGB, blending with background."""
function _volumetric_final_color(I_acc::Float64, τ_acc::Float64,
                                  bg::NTuple{3, Float64})::NTuple{3, Float64}
    I_acc <= 0.0 && return bg
    # blackbody_color maps intensity to an RGB color ramp (cold→hot).
    # I_acc already encodes the integrated brightness, so we use it directly
    # as the color — no additional multiplication by I_acc.
    disk_color = blackbody_color(clamp(I_acc, 0.0, 5.0))
    # Beer-Lambert: background attenuated by accumulated optical depth
    transmittance = exp(-τ_acc)
    (disk_color[1] + bg[1] * transmittance,
     disk_color[2] + bg[2] * transmittance,
     disk_color[3] + bg[3] * transmittance)
end

"""Look up sky color from escaped ray position."""
function _sky_color(m::MetricSpace, sky::Union{CelestialSphere, Nothing},
                     x::SVec4d,
                     bg::NTuple{3, Float64}=(NaN, NaN, NaN))::NTuple{3, Float64}
    θ, φ = _sky_angles(m, x)
    sky !== nothing && return sphere_lookup(sky, θ, φ)
    isnan(bg[1]) && return checkerboard_sphere(θ, φ)
    bg
end

# BL coordinates: θ = x[3], φ = x[4]
@inline _sky_angles(::MetricSpace, x::SVec4d) = (x[3], x[4])
# Cartesian KS: convert (x, y, z) → (θ, φ) — no pole singularity
@inline _sky_angles(::SchwarzschildKS, x::SVec4d) = ks_to_sky_angles(x)

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
    spp = config.samples_per_pixel
    matter = volume !== nothing ? volume : disk

    if spp <= 1
        # Single sample per pixel — fast path
        if config.use_threads
            Threads.@threads :dynamic for j in 1:height
                for i in 1:width
                    pixels[j, i] = _trace_one(cam, config, matter, sky, i, j)
                end
            end
        else
            for j in 1:height, i in 1:width
                pixels[j, i] = _trace_one(cam, config, matter, sky, i, j)
            end
        end
    else
        # Stratified supersampling: NxN grid within each pixel
        n = isqrt(spp)  # grid dimension (spp=4 → 2×2, spp=9 → 3×3)
        n = max(n, 2)
        inv_n = 1.0 / n
        inv_total = 1.0 / (n * n)

        if config.use_threads
            Threads.@threads :dynamic for j in 1:height
                for i in 1:width
                    r_acc, g_acc, b_acc = 0.0, 0.0, 0.0
                    for sj in 0:n-1, si in 0:n-1
                        dx = (si + 0.5) * inv_n - 0.5
                        dy = (sj + 0.5) * inv_n - 0.5
                        c = _trace_one_sub(cam, config, matter, sky, i, j, dx, dy)
                        r_acc += c[1]; g_acc += c[2]; b_acc += c[3]
                    end
                    pixels[j, i] = (r_acc * inv_total, g_acc * inv_total, b_acc * inv_total)
                end
            end
        else
            for j in 1:height, i in 1:width
                r_acc, g_acc, b_acc = 0.0, 0.0, 0.0
                for sj in 0:n-1, si in 0:n-1
                    dx = (si + 0.5) * inv_n - 0.5
                    dy = (sj + 0.5) * inv_n - 0.5
                    c = _trace_one_sub(cam, config, matter, sky, i, j, dx, dy)
                    r_acc += c[1]; g_acc += c[2]; b_acc += c[3]
                end
                pixels[j, i] = (r_acc * inv_total, g_acc * inv_total, b_acc * inv_total)
            end
        end
    end

    pixels
end

# Dispatch helpers (avoid Union dispatch in hot loop)
@inline function _trace_one(cam, config, matter::VolumetricMatter, sky, i, j)
    trace_pixel(cam, config, matter, sky, i, j)
end
@inline function _trace_one(cam, config, matter::Union{ThinDisk, Nothing}, sky, i, j)
    trace_pixel(cam, config, matter, sky, i, j)
end

# Sub-pixel variants for supersampling
@inline function _trace_one_sub(cam, config, matter::VolumetricMatter, sky, i, j, dx, dy)
    p0 = pixel_to_momentum(cam, i, j, dx, dy)
    # Inline the volumetric trace with custom initial momentum
    _trace_pixel_with_p0(cam, config, matter, sky, p0)
end
@inline function _trace_one_sub(cam, config, matter::Union{ThinDisk, Nothing}, sky, i, j, dx, dy)
    # ThinDisk path doesn't need sub-pixel (aliasing is less severe)
    trace_pixel(cam, config, matter, sky, i, j)
end
