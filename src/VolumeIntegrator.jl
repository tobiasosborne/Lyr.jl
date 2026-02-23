# VolumeIntegrator.jl - Production volume rendering via delta/ratio tracking
#
# Implements:
#   - Delta tracking (free-flight sampling for scattering events)
#   - Ratio tracking (transmittance estimation for shadow rays)
#   - Single-scatter volume renderer (render_volume_image)
#   - Emission-absorption preview renderer (fast, deterministic)

using Random: Xoshiro

# ============================================================================
# Delta tracking — free-flight sampling
# ============================================================================

"""
    delta_tracking_step(ray, nanogrid, t_enter, t_exit, sigma_maj, rng)

Take one delta tracking step along a ray through a volume.

Returns `(t, :scattered)`, `(t, :absorbed)`, or `(t_exit, :escaped)`.

Delta tracking samples free-flight distance `t += -log(rand)/sigma_maj`,
then accepts/rejects based on `sigma_real/sigma_maj`.
"""
function delta_tracking_step(ray::Ray, nanogrid::NanoGrid, t_enter::Float64,
                             t_exit::Float64, sigma_maj::Float64,
                             albedo::Float64, rng)
    t = t_enter
    acc = NanoValueAccessor(nanogrid)

    while true
        # Sample free-flight distance
        t += -log(rand(rng)) / sigma_maj

        if t >= t_exit
            return (t_exit, :escaped)
        end

        # Sample density at current position
        pos = ray.origin + t * ray.direction
        density = Float64(get_value(acc,
            coord(round(Int32, pos[1]), round(Int32, pos[2]), round(Int32, pos[3]))))
        density = max(0.0, density)

        sigma_real = density * sigma_maj
        accept_prob = sigma_real / sigma_maj

        if rand(rng) < accept_prob
            # Real collision — scatter or absorb
            if rand(rng) < albedo
                return (t, :scattered)
            else
                return (t, :absorbed)
            end
        end
        # Null collision — continue
    end
end

# ============================================================================
# Ratio tracking — transmittance estimation
# ============================================================================

"""
    ratio_tracking(ray, nanogrid, t0, t1, sigma_maj, rng) -> Float64

Estimate transmittance along a ray segment [t0, t1] via ratio tracking.

Returns a value in [0, 1]. For shadow rays — no stochastic termination,
just accumulates transmittance weights.
"""
function ratio_tracking(ray::Ray, nanogrid::NanoGrid, t0::Float64, t1::Float64,
                        sigma_maj::Float64, rng)::Float64
    T = 1.0
    t = t0
    acc = NanoValueAccessor(nanogrid)

    while true
        t += -log(rand(rng)) / sigma_maj

        if t >= t1
            return T
        end

        pos = ray.origin + t * ray.direction
        density = Float64(get_value(acc,
            coord(round(Int32, pos[1]), round(Int32, pos[2]), round(Int32, pos[3]))))
        density = max(0.0, density)

        sigma_real = density * sigma_maj
        T *= (1.0 - sigma_real / sigma_maj)

        if T < 1e-10
            return 0.0
        end
    end
end

# ============================================================================
# Volume bounds intersection
# ============================================================================

"""
    _volume_bounds(nanogrid::NanoGrid) -> Tuple{SVec3d, SVec3d}

Get world-space bounding box of a NanoGrid.
"""
function _volume_bounds(nanogrid::NanoGrid)
    bbox = nano_bbox(nanogrid)
    bmin = SVec3d(Float64(bbox.min.x), Float64(bbox.min.y), Float64(bbox.min.z))
    bmax = SVec3d(Float64(bbox.max.x), Float64(bbox.max.y), Float64(bbox.max.z))
    (bmin, bmax)
end

"""
    _ray_box_intersect(ray, bmin, bmax) -> Tuple{Float64, Float64}

Ray-AABB intersection. Returns (t_enter, t_exit). If no hit, t_enter > t_exit.
"""
function _ray_box_intersect(ray::Ray, bmin::SVec3d, bmax::SVec3d)
    t1 = (bmin[1] - ray.origin[1]) * ray.inv_dir[1]
    t2 = (bmax[1] - ray.origin[1]) * ray.inv_dir[1]
    tmin = min(t1, t2)
    tmax = max(t1, t2)

    t1 = (bmin[2] - ray.origin[2]) * ray.inv_dir[2]
    t2 = (bmax[2] - ray.origin[2]) * ray.inv_dir[2]
    tmin = max(tmin, min(t1, t2))
    tmax = min(tmax, max(t1, t2))

    t1 = (bmin[3] - ray.origin[3]) * ray.inv_dir[3]
    t2 = (bmax[3] - ray.origin[3]) * ray.inv_dir[3]
    tmin = max(tmin, min(t1, t2))
    tmax = min(tmax, max(t1, t2))

    (max(tmin, 0.0), tmax)
end

# ============================================================================
# Emission-absorption preview renderer (V7)
# ============================================================================

"""
    render_volume_preview(scene::Scene, width::Int, height::Int;
                          step_size=0.5, max_steps=2000) -> Matrix{NTuple{3, Float64}}

Fast deterministic emission-absorption ray marcher for preview rendering.
No stochastic sampling — fixed-step front-to-back compositing.
"""
function render_volume_preview(scene::Scene, width::Int, height::Int;
                               step_size::Float64=0.5,
                               max_steps::Int=2000)
    aspect = Float64(width) / Float64(height)
    pixels = Matrix{NTuple{3, Float64}}(undef, height, width)

    for y in 1:height
        for x in 1:width
            u = (Float64(x) - 0.5) / Float64(width)
            v = 1.0 - (Float64(y) - 0.5) / Float64(height)
            ray = camera_ray(scene.camera, u, v, aspect)

            color = _march_emission_absorption(ray, scene, step_size, max_steps)
            pixels[y, x] = color
        end
    end

    pixels
end

"""
    _march_emission_absorption(ray, scene, step_size, max_steps) -> NTuple{3, Float64}

Front-to-back emission-absorption compositing along a ray.
"""
function _march_emission_absorption(ray::Ray, scene::Scene,
                                     step_size::Float64, max_steps::Int)
    acc_r = 0.0
    acc_g = 0.0
    acc_b = 0.0
    transmittance = 1.0

    for vol in scene.volumes
        nanogrid = vol.nanogrid
        nanogrid === nothing && throw(ArgumentError(
            "VolumeEntry has no NanoGrid — call build_nanogrid(grid.tree) before rendering"))

        bmin, bmax = _volume_bounds(nanogrid)
        t_enter, t_exit = _ray_box_intersect(ray, bmin, bmax)
        t_enter >= t_exit && continue

        tf = vol.material.transfer_function
        sigma_scale = vol.material.sigma_scale
        emission_scale = vol.material.emission_scale
        nacc = NanoValueAccessor(nanogrid)

        t = t_enter
        for _ in 1:max_steps
            t >= t_exit && break
            transmittance < 1e-4 && break

            pos = ray.origin + t * ray.direction
            density = Float64(get_value(nacc,
                coord(round(Int32, pos[1]), round(Int32, pos[2]), round(Int32, pos[3]))))
            density = max(0.0, density)

            if density > 1e-6
                rgba = evaluate(tf, density)
                r, g, b, a = rgba

                # Extinction for this step
                sigma_t = a * sigma_scale * step_size
                step_transmittance = exp(-sigma_t)

                # Emission contribution
                emit = (1.0 - step_transmittance) * emission_scale
                acc_r += transmittance * r * emit
                acc_g += transmittance * g * emit
                acc_b += transmittance * b * emit

                transmittance *= step_transmittance
            end

            t += step_size
        end
    end

    # Blend with background
    bg = scene.background
    acc_r += transmittance * bg[1]
    acc_g += transmittance * bg[2]
    acc_b += transmittance * bg[3]

    (clamp(acc_r, 0.0, 1.0), clamp(acc_g, 0.0, 1.0), clamp(acc_b, 0.0, 1.0))
end

# ============================================================================
# Single-scatter volume renderer (V6)
# ============================================================================

"""
    render_volume_image(scene::Scene, width::Int, height::Int;
                        spp=1, seed=UInt64(42),
                        max_bounces=1) -> Matrix{NTuple{3, Float64}}

Production single-scatter volume renderer using delta tracking.

For each pixel: intersect volume bounds, delta track to find collision,
shadow ray via ratio tracking toward each light, apply phase function
and transfer function, accumulate. Russian roulette after first bounce.
"""
function render_volume_image(scene::Scene, width::Int, height::Int;
                             spp::Int=1, seed::UInt64=UInt64(42),
                             max_bounces::Int=1)
    aspect = Float64(width) / Float64(height)
    pixels = Matrix{NTuple{3, Float64}}(undef, height, width)
    inv_spp = 1.0 / spp

    for y in 1:height
        rng = Xoshiro(seed + UInt64(y))
        for x in 1:width
            acc_r = 0.0
            acc_g = 0.0
            acc_b = 0.0

            for _ in 1:spp
                # Jittered sub-pixel offset
                u = (Float64(x) - 1.0 + rand(rng)) / Float64(width)
                v = 1.0 - (Float64(y) - 1.0 + rand(rng)) / Float64(height)
                ray = camera_ray(scene.camera, u, v, aspect)

                r, g, b = _trace_volume_ray(ray, scene, rng, max_bounces)
                acc_r += r
                acc_g += g
                acc_b += b
            end

            pixels[y, x] = (clamp(acc_r * inv_spp, 0.0, 1.0),
                            clamp(acc_g * inv_spp, 0.0, 1.0),
                            clamp(acc_b * inv_spp, 0.0, 1.0))
        end
    end

    pixels
end

"""
    _trace_volume_ray(ray, scene, rng, max_bounces) -> NTuple{3, Float64}

Trace a single ray through the scene with delta tracking and single scattering.
"""
function _trace_volume_ray(ray::Ray, scene::Scene, rng,
                           max_bounces::Int)::NTuple{3, Float64}
    acc_r = 0.0
    acc_g = 0.0
    acc_b = 0.0
    throughput = 1.0

    for vol in scene.volumes
        nanogrid = vol.nanogrid
        nanogrid === nothing && throw(ArgumentError(
            "VolumeEntry has no NanoGrid — call build_nanogrid(grid.tree) before rendering"))

        bmin, bmax = _volume_bounds(nanogrid)
        t_enter, t_exit = _ray_box_intersect(ray, bmin, bmax)
        t_enter >= t_exit && continue

        tf = vol.material.transfer_function
        sigma_scale = vol.material.sigma_scale
        emission_scale = vol.material.emission_scale
        albedo = vol.material.scattering_albedo
        pf = vol.material.phase_function

        # Estimate majorant from sigma_scale (conservative bound)
        sigma_maj = sigma_scale

        # Delta tracking step
        t_hit, event = delta_tracking_step(ray, nanogrid, t_enter, t_exit,
                                            sigma_maj, albedo, rng)

        if event == :escaped
            continue
        end

        # Sample density and evaluate transfer function at hit point
        hit_pos = ray.origin + t_hit * ray.direction
        hit_acc = NanoValueAccessor(nanogrid)
        density = Float64(get_value(hit_acc,
            coord(round(Int32, hit_pos[1]), round(Int32, hit_pos[2]),
            round(Int32, hit_pos[3]))))
        density = max(0.0, density)

        rgba = evaluate(tf, density)
        emit_r, emit_g, emit_b, _ = rgba

        # Direct lighting: shadow ray to each light
        for light in scene.lights
            light_dir, light_intensity, light_dist = _light_contribution(light, hit_pos)

            # Shadow ray transmittance via ratio tracking
            shadow_ray = Ray(hit_pos + 0.01 * light_dir, light_dir)
            shadow_t_enter, shadow_t_exit = _ray_box_intersect(shadow_ray, bmin, bmax)
            shadow_t_exit = min(shadow_t_exit, light_dist)

            transmittance = if shadow_t_enter < shadow_t_exit
                ratio_tracking(shadow_ray, nanogrid, shadow_t_enter, shadow_t_exit,
                              sigma_maj, rng)
            else
                1.0
            end

            # Phase function
            cos_theta = -(ray.direction[1] * light_dir[1] +
                         ray.direction[2] * light_dir[2] +
                         ray.direction[3] * light_dir[3])
            phase = evaluate(pf, cos_theta)

            # Accumulate
            scale = throughput * transmittance * phase * emission_scale
            acc_r += emit_r * light_intensity[1] * scale
            acc_g += emit_g * light_intensity[2] * scale
            acc_b += emit_b * light_intensity[3] * scale
        end
    end

    # Blend with background
    bg = scene.background
    acc_r += throughput * bg[1]
    acc_g += throughput * bg[2]
    acc_b += throughput * bg[3]

    (acc_r, acc_g, acc_b)
end

"""
    _light_contribution(light, point) -> Tuple{SVec3d, SVec3d, Float64}

Compute light direction, intensity, and distance for a given light and point.
Returns (direction_to_light, intensity, distance).
"""
function _light_contribution(light::PointLight, point::SVec3d)
    delta = light.position - point
    dist = sqrt(delta[1]^2 + delta[2]^2 + delta[3]^2)
    if dist < 1e-10
        return (SVec3d(0.0, 0.0, 1.0), SVec3d(0.0, 0.0, 0.0), 0.0)
    end
    dir = delta / dist
    # Inverse-square falloff
    intensity = light.intensity / (dist * dist)
    (dir, intensity, dist)
end

function _light_contribution(light::DirectionalLight, point::SVec3d)
    (light.direction, light.intensity, Inf)
end
