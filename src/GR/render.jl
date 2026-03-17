# render.jl — GR rendering pipeline
#
# For each pixel: generate initial null momentum from camera tetrad,
# integrate geodesic backward in time, determine color from termination
# condition (horizon → black, escaped → sky/background, disk → emissivity).

# Coordinate-system dispatch: convert to spherical
# Note: _coord_r is defined in integrator.jl (loaded first, shared with matter.jl)

# Bare SVec4d disk crossing (avoids GeodesicState allocation in thin-disk inner loop)
@inline function _check_disk_crossing_bare(m::MetricSpace, x_prev::SVec4d, x_curr::SVec4d,
                                            disk::ThinDisk)
    equator = π / 2.0
    if (x_prev[3] - equator) * (x_curr[3] - equator) < 0.0
        frac = (equator - x_prev[3]) / (x_curr[3] - x_prev[3])
        r_cross = x_prev[2] + frac * (x_curr[2] - x_prev[2])
        if disk.inner_radius <= r_cross <= disk.outer_radius
            return (r_cross, frac)
        end
    end
    nothing
end

@inline function _check_disk_crossing_bare(::SchwarzschildKS, x_prev::SVec4d, x_curr::SVec4d,
                                            disk::ThinDisk)
    if x_prev[4] * x_curr[4] < 0.0
        frac = -x_prev[4] / (x_curr[4] - x_prev[4])
        x_cross = x_prev + frac * (x_curr - x_prev)
        r_cross = sqrt(x_cross[2]^2 + x_cross[3]^2 + x_cross[4]^2)
        if disk.inner_radius <= r_cross <= disk.outer_radius
            return (r_cross, frac)
        end
    end
    nothing
end

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
struct GRRenderConfig{S<:AbstractStepper}
    integrator::IntegratorConfig{S}
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
    _trace_pixel_thin_with_p0(cam, config, disk, sky, pixel_to_momentum(cam, i, j))
end

"""Internal: thin-disk trace with pre-computed initial momentum (for supersampling)."""
@fastmath function _trace_pixel_thin_with_p0(cam::GRCamera, config::GRRenderConfig,
                                    disk::Union{ThinDisk, Nothing},
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

    x_prev = x

    for step in 1:cfg.max_steps
        r = _coord_r(m, x)
        dl = M_val > 0.0 ? adaptive_step(dl_base, r, M_val) : dl_base
        x_new, p_new = _do_step(m, x, p, dl, stepper)

        if renorm_interval > 0 && step % renorm_interval == 0
            p_new = renormalize_null(m, x_new, p_new)
        end

        # ── Check disk crossing ──
        if disk !== nothing
            crossing = _check_disk_crossing_bare(m, x_prev, x_new, disk)
            if crossing !== nothing
                r_cross, frac = crossing
                intensity = disk_emissivity(disk, r_cross)
                if config.use_redshift
                    x_cross = x_prev + frac * (x_new - x_prev)
                    u_emit = keplerian_four_velocity(m, r_cross, x_cross)
                    z_plus_1 = redshift_factor(p_new, u_emit, p0, cam.four_velocity)
                    intensity = intensity / z_plus_1^4
                end
                return blackbody_color(clamp(intensity * 5.0, 0.0, 2.0))
            end
        end

        x_prev = x
        x, p = x_new, p_new
        r = _coord_r(m, x)

        # ── Termination ──
        if r <= rh * cfg.r_min_factor
            return (0.0, 0.0, 0.0)
        end

        if r >= cfg.r_max
            return _sky_color(m, sky, x, config.background)
        end

        if is_singular(m, x)
            return (0.0, 0.0, 0.0)
        end
    end

    return _sky_color(m, sky, x, config.background)
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
@fastmath function _trace_pixel_with_p0(cam::GRCamera, config::GRRenderConfig,
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

    # Observer 4-velocity (from camera tetrad — exact for any metric)
    u_obs = cam.four_velocity

    # RGB accumulation (Planck-colored emission)
    R_acc, G_acc, B_acc = 0.0, 0.0, 0.0
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

        # ── Pole termination: if θ drifts near a BL pole, metric is unreliable ──
        θ_new = x_new[3]
        if θ_new < 1e-3 || θ_new > π - 1e-3
            bg = _sky_color(m, sky, x_new, config.background)
            return _volumetric_final_color(R_acc, G_acc, B_acc, τ_acc, bg)
        end

        # ── Accumulate emission/absorption ──
        r_new = _coord_r(m, x_new)
        if vol.inner_radius <= r_new <= vol.outer_radius
            r_d, θ_d, φ_d = _to_spherical(m, x_new)
            ρ = evaluate_density(vol.density_source, r_d, θ_d, φ_d)
            if ρ > density_threshold
                # NT temperature (Kelvin) for Planck color
                T_emit = disk_temperature_nt(r_d, m.M, vol.r_isco; T_inner=vol.T_inner)
                # Normalized temperature for emission magnitude
                T_norm = disk_temperature(r_d, vol.inner_radius)
                jj, α = emission_absorption(ρ, T_norm)
                # Spatial proper length: sqrt(|g_{ij} dx^i dx^j|)
                dx = x_new - x
                g = metric(m, x_new)
                dl_sq = zero(Float64)
                for i in 2:4, j in 2:4
                    dl_sq += g[i, j] * dx[i] * dx[j]
                end
                dl_proper = sqrt(abs(dl_sq))

                z_plus_1 = 1.0
                if config.use_redshift
                    z_plus_1 = volumetric_redshift(m, x_new, p_new, p0, u_obs)
                    jj = jj / z_plus_1^4
                end

                # Planck color at observed temperature
                T_obs = T_emit / max(z_plus_1, 0.01)
                color = planck_to_rgb_fast(T_obs)

                dτ = α * dl_proper
                dI = jj * dl_proper * exp(-τ_acc)
                τ_acc += dτ
                R_acc += color[1] * dI
                G_acc += color[2] * dI
                B_acc += color[3] * dI

                # Early exit: optically thick — background fully attenuated
                if τ_acc > 8.0
                    return _volumetric_final_color(R_acc, G_acc, B_acc, τ_acc, (0.0, 0.0, 0.0))
                end
            end
        end

        x, p = x_new, p_new

        # ── Termination ──
        if r_new <= rh * cfg.r_min_factor
            return _volumetric_final_color(R_acc, G_acc, B_acc, τ_acc, (0.0, 0.0, 0.0))
        end

        if r_new >= cfg.r_max
            bg = _sky_color(m, sky, x, config.background)
            return _volumetric_final_color(R_acc, G_acc, B_acc, τ_acc, bg)
        end

        if is_singular(m, x)
            return _volumetric_final_color(R_acc, G_acc, B_acc, τ_acc, (0.0, 0.0, 0.0))
        end
    end

    bg = _sky_color(m, sky, x, config.background)
    _volumetric_final_color(R_acc, G_acc, B_acc, τ_acc, bg)
end

"""Map accumulated RGB emission + optical depth to final color, blending with background."""
function _volumetric_final_color(R_acc::Float64, G_acc::Float64, B_acc::Float64,
                                  τ_acc::Float64,
                                  bg::NTuple{3, Float64})::NTuple{3, Float64}
    transmittance = exp(-τ_acc)
    r = R_acc + bg[1] * transmittance
    g = G_acc + bg[2] * transmittance
    b = B_acc + bg[3] * transmittance
    # Reinhard tone mapping for HDR → [0,1]
    (clamp(r / (1.0 + r), 0.0, 1.0),
     clamp(g / (1.0 + g), 0.0, 1.0),
     clamp(b / (1.0 + b), 0.0, 1.0))
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
    _trace_pixel_with_p0(cam, config, matter, sky, p0)
end
@inline function _trace_one_sub(cam, config, matter::Union{ThinDisk, Nothing}, sky, i, j, dx, dy)
    p0 = pixel_to_momentum(cam, i, j, dx, dy)
    _trace_pixel_thin_with_p0(cam, config, matter, sky, p0)
end
