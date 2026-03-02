# VolumeIntegrator.jl - Production volume rendering via delta/ratio tracking
#
# Implements:
#   - Delta tracking (free-flight sampling for scattering events)
#   - Ratio tracking (transmittance estimation for shadow rays)
#   - Single-scatter volume renderer (render_volume_image)
#   - Emission-absorption preview renderer (fast, deterministic)
#
# Performance: zero-allocation inner loops via inlined HDDA, accessor reuse,
# and precomputed per-volume constants.

using Random: Xoshiro, randexp

# ============================================================================
# Precomputed per-volume constants — avoid recomputing per-ray
# ============================================================================

struct _PrecomputedVolume{T}
    nanogrid::NanoGrid{T}
    bmin::SVec3d
    bmax::SVec3d
    sigma_maj::Float64
    albedo::Float64
    emission_scale::Float64
    tf::TransferFunction
    pf::PhaseFunction
end

@inline function _precompute_volume(vol::VolumeEntry)
    nano = vol.nanogrid::NanoGrid  # assert non-nothing (already validated)
    bbox = nano_bbox(nano)
    bmin = SVec3d(Float64(bbox.min.x), Float64(bbox.min.y), Float64(bbox.min.z))
    bmax = SVec3d(Float64(bbox.max.x), Float64(bbox.max.y), Float64(bbox.max.z))
    _PrecomputedVolume(nano, bmin, bmax,
                       vol.material.sigma_scale,
                       vol.material.scattering_albedo,
                       vol.material.emission_scale,
                       vol.material.transfer_function,
                       vol.material.phase_function)
end

# ============================================================================
# HDDA-inlined delta tracking — zero closure boxing
# ============================================================================
#
# Instead of using foreach_hdda_span with a closure (which boxes mutable
# captured variables), we inline the HDDA state machine directly into
# delta_tracking_step and ratio_tracking. This keeps ALL state on the stack.

"""
    delta_tracking_step(ray, nanogrid, acc, t_enter, t_exit, sigma_maj, albedo, rng)

Take one delta tracking step along a ray through a volume.

Returns `(t, :scattered)`, `(t, :absorbed)`, or `(t_exit, :escaped)`.
"""
function delta_tracking_step(ray::Ray, nanogrid::NanoGrid{T}, acc::NanoValueAccessor,
                             t_enter::Float64, t_exit::Float64, sigma_maj::Float64,
                             albedo::Float64, rng) where T
    reset!(acc)
    t = t_enter
    buf = nanogrid.buffer
    root_pos = _nano_root_pos(nanogrid)
    root_count = nano_root_count(nanogrid)
    entry_sz = _root_entry_size(T)

    # Collect root hits into stack-allocated buffer
    root_tmins = MVector{_MAX_ROOTS, Float64}(ntuple(_ -> 0.0, Val(_MAX_ROOTS)))
    root_offs  = MVector{_MAX_ROOTS, Int}(ntuple(_ -> 0, Val(_MAX_ROOTS)))
    n_roots = 0

    @inbounds for i in 0:(root_count - 1)
        ep = root_pos + i * entry_sz
        is_child = _buf_load(UInt8, buf, ep + 12)
        is_child == 0x01 || continue
        i2_off = Int(_buf_load(UInt32, buf, ep + 13))
        origin = _buf_load_coord(buf, i2_off)
        aabb = AABB(
            SVec3d(Float64(origin.x), Float64(origin.y), Float64(origin.z)),
            SVec3d(Float64(origin.x) + 4096.0, Float64(origin.y) + 4096.0,
                   Float64(origin.z) + 4096.0)
        )
        hit = intersect_bbox(ray, aabb)
        if hit !== nothing
            n_roots += 1
            n_roots > _MAX_ROOTS && break
            root_tmins[n_roots] = hit[1]
            root_offs[n_roots] = i2_off
        end
    end

    n_roots == 0 && return (t_exit, :escaped)

    # Insertion sort roots by tmin
    @inbounds for i in 2:n_roots
        kt = root_tmins[i]; ko = root_offs[i]; j = i - 1
        while j >= 1 && root_tmins[j] > kt
            root_tmins[j + 1] = root_tmins[j]; root_offs[j + 1] = root_offs[j]; j -= 1
        end
        root_tmins[j + 1] = kt; root_offs[j + 1] = ko
    end

    # HDDA state machine with span merging + delta tracking inner loop
    span_t0 = -1.0
    inv_sigma = 1.0 / sigma_maj

    @inbounds for ri in 1:n_roots
        i2_off = root_offs[ri]
        origin = _buf_load_coord(buf, i2_off)
        i2_ndda = node_dda_init(ray, root_tmins[ri], origin, Int32(32), Int32(128))
        i2_t_entry = root_tmins[ri]

        while node_dda_inside(i2_ndda)
            cidx = node_dda_child_index(i2_ndda)
            has_child = _buf_mask_is_on(buf, i2_off + _I2_CMASK_OFF, cidx)

            if has_child
                tidx = _buf_count_on_before(buf, i2_off + _I2_CMASK_OFF,
                                            i2_off + _I2_CPREFIX_OFF, cidx)
                i1_off = Int(_buf_load(UInt32, buf, i2_off + _I2_DATA_OFF + tidx * 4))
                i1_origin = _buf_load_coord(buf, i1_off)
                i1_aabb = AABB(
                    SVec3d(Float64(i1_origin.x), Float64(i1_origin.y), Float64(i1_origin.z)),
                    SVec3d(Float64(i1_origin.x) + 128.0, Float64(i1_origin.y) + 128.0,
                           Float64(i1_origin.z) + 128.0)
                )
                hit = intersect_bbox(ray, i1_aabb)

                if hit !== nothing
                    tmin, _ = hit
                    i1_ndda = node_dda_init(ray, tmin, i1_origin, Int32(16), Int32(8))
                    i1_t_entry = tmin

                    # Phase 1: DDA through I1 cells
                    while node_dda_inside(i1_ndda)
                        i1_cidx = node_dda_child_index(i1_ndda)
                        i1_active = _buf_mask_is_on(buf, i1_off + _I1_CMASK_OFF, i1_cidx) ||
                                    _buf_mask_is_on(buf, i1_off + _I1_VMASK_OFF, i1_cidx)

                        if i1_active
                            if span_t0 < 0.0
                                span_t0 = i1_t_entry
                            end
                        elseif span_t0 >= 0.0
                            # Span closed — run delta tracking on [span_t0, i1_t_entry]
                            span_end = min(i1_t_entry, t_exit)
                            t = max(t, span_t0)
                            while t < span_end
                                t += randexp(rng) * inv_sigma
                                t >= span_end && break
                                pos = ray.origin + t * ray.direction
                                density = max(0.0, get_value_trilinear(acc, pos))
                                if rand(rng) < clamp(density, 0.0, 1.0)
                                    return rand(rng) < albedo ? (t, :scattered) : (t, :absorbed)
                                end
                            end
                            span_t0 = -1.0
                            t >= t_exit && return (t_exit, :escaped)
                        end

                        i1_t_entry = node_dda_cell_time(i1_ndda)
                        dda_step!(i1_ndda.state)
                    end

                    i2_t_entry = node_dda_cell_time(i2_ndda)
                    dda_step!(i2_ndda.state)
                    continue
                else
                    if span_t0 >= 0.0
                        span_end = min(i2_t_entry, t_exit)
                        t = max(t, span_t0)
                        while t < span_end
                            t += randexp(rng) * inv_sigma
                            t >= span_end && break
                            pos = ray.origin + t * ray.direction
                            density = max(0.0, get_value_trilinear(acc, pos))
                            if rand(rng) < clamp(density, 0.0, 1.0)
                                return rand(rng) < albedo ? (t, :scattered) : (t, :absorbed)
                            end
                        end
                        span_t0 = -1.0
                        t >= t_exit && return (t_exit, :escaped)
                    end
                end
            else
                has_tile = _buf_mask_is_on(buf, i2_off + _I2_VMASK_OFF, cidx)
                if has_tile
                    if span_t0 < 0.0
                        span_t0 = i2_t_entry
                    end
                elseif span_t0 >= 0.0
                    span_end = min(i2_t_entry, t_exit)
                    t = max(t, span_t0)
                    while t < span_end
                        t += randexp(rng) * inv_sigma
                        t >= span_end && break
                        pos = ray.origin + t * ray.direction
                        density = max(0.0, get_value_trilinear(acc, pos))
                        if rand(rng) < clamp(density, 0.0, 1.0)
                            return rand(rng) < albedo ? (t, :scattered) : (t, :absorbed)
                        end
                    end
                    span_t0 = -1.0
                    t >= t_exit && return (t_exit, :escaped)
                end
            end

            i2_t_entry = node_dda_cell_time(i2_ndda)
            dda_step!(i2_ndda.state)
        end

        # Close any open span at I2 boundary
        if span_t0 >= 0.0
            span_end = min(i2_t_entry, t_exit)
            t = max(t, span_t0)
            while t < span_end
                t += randexp(rng) * inv_sigma
                t >= span_end && break
                pos = ray.origin + t * ray.direction
                density = max(0.0, get_value_trilinear(acc, pos))
                if rand(rng) < clamp(density, 0.0, 1.0)
                    return rand(rng) < albedo ? (t, :scattered) : (t, :absorbed)
                end
            end
            span_t0 = -1.0
            t >= t_exit && return (t_exit, :escaped)
        end
    end

    return (t_exit, :escaped)
end

# Legacy: create accessor internally (for backward compat with tests)
function delta_tracking_step(ray::Ray, nanogrid::NanoGrid, t_enter::Float64,
                             t_exit::Float64, sigma_maj::Float64,
                             albedo::Float64, rng)
    acc = NanoValueAccessor(nanogrid)
    delta_tracking_step(ray, nanogrid, acc, t_enter, t_exit, sigma_maj, albedo, rng)
end

# ============================================================================
# Ratio tracking — HDDA-inlined, zero-allocation
# ============================================================================

"""
    ratio_tracking(ray, nanogrid, acc, t0, t1, sigma_maj, rng) -> Float64

Estimate transmittance along a ray segment [t0, t1] via ratio tracking.
"""
function ratio_tracking(ray::Ray, nanogrid::NanoGrid{T}, acc::NanoValueAccessor,
                        t0::Float64, t1::Float64,
                        sigma_maj::Float64, rng)::Float64 where T
    reset!(acc)
    T_acc = 1.0
    t = t0
    buf = nanogrid.buffer
    root_pos = _nano_root_pos(nanogrid)
    root_count = nano_root_count(nanogrid)
    entry_sz = _root_entry_size(T)
    inv_sigma = 1.0 / sigma_maj

    root_tmins = MVector{_MAX_ROOTS, Float64}(ntuple(_ -> 0.0, Val(_MAX_ROOTS)))
    root_offs  = MVector{_MAX_ROOTS, Int}(ntuple(_ -> 0, Val(_MAX_ROOTS)))
    n_roots = 0

    @inbounds for i in 0:(root_count - 1)
        ep = root_pos + i * entry_sz
        is_child = _buf_load(UInt8, buf, ep + 12)
        is_child == 0x01 || continue
        i2_off = Int(_buf_load(UInt32, buf, ep + 13))
        origin = _buf_load_coord(buf, i2_off)
        aabb = AABB(
            SVec3d(Float64(origin.x), Float64(origin.y), Float64(origin.z)),
            SVec3d(Float64(origin.x) + 4096.0, Float64(origin.y) + 4096.0,
                   Float64(origin.z) + 4096.0)
        )
        hit = intersect_bbox(ray, aabb)
        if hit !== nothing
            n_roots += 1
            n_roots > _MAX_ROOTS && break
            root_tmins[n_roots] = hit[1]
            root_offs[n_roots] = i2_off
        end
    end

    n_roots == 0 && return T_acc

    @inbounds for i in 2:n_roots
        kt = root_tmins[i]; ko = root_offs[i]; j = i - 1
        while j >= 1 && root_tmins[j] > kt
            root_tmins[j + 1] = root_tmins[j]; root_offs[j + 1] = root_offs[j]; j -= 1
        end
        root_tmins[j + 1] = kt; root_offs[j + 1] = ko
    end

    span_t0 = -1.0

    @inbounds for ri in 1:n_roots
        i2_off = root_offs[ri]
        origin = _buf_load_coord(buf, i2_off)
        i2_ndda = node_dda_init(ray, root_tmins[ri], origin, Int32(32), Int32(128))
        i2_t_entry = root_tmins[ri]

        while node_dda_inside(i2_ndda)
            cidx = node_dda_child_index(i2_ndda)
            has_child = _buf_mask_is_on(buf, i2_off + _I2_CMASK_OFF, cidx)

            if has_child
                tidx = _buf_count_on_before(buf, i2_off + _I2_CMASK_OFF,
                                            i2_off + _I2_CPREFIX_OFF, cidx)
                i1_off = Int(_buf_load(UInt32, buf, i2_off + _I2_DATA_OFF + tidx * 4))
                i1_origin = _buf_load_coord(buf, i1_off)
                i1_aabb = AABB(
                    SVec3d(Float64(i1_origin.x), Float64(i1_origin.y), Float64(i1_origin.z)),
                    SVec3d(Float64(i1_origin.x) + 128.0, Float64(i1_origin.y) + 128.0,
                           Float64(i1_origin.z) + 128.0)
                )
                hit = intersect_bbox(ray, i1_aabb)

                if hit !== nothing
                    tmin, _ = hit
                    i1_ndda = node_dda_init(ray, tmin, i1_origin, Int32(16), Int32(8))
                    i1_t_entry = tmin

                    while node_dda_inside(i1_ndda)
                        i1_cidx = node_dda_child_index(i1_ndda)
                        i1_active = _buf_mask_is_on(buf, i1_off + _I1_CMASK_OFF, i1_cidx) ||
                                    _buf_mask_is_on(buf, i1_off + _I1_VMASK_OFF, i1_cidx)

                        if i1_active
                            span_t0 < 0.0 && (span_t0 = i1_t_entry)
                        elseif span_t0 >= 0.0
                            span_end = min(i1_t_entry, t1)
                            t = max(t, span_t0)
                            while t < span_end
                                t += randexp(rng) * inv_sigma
                                t >= span_end && break
                                pos = ray.origin + t * ray.direction
                                density = max(0.0, get_value_trilinear(acc, pos))
                                T_acc *= (1.0 - clamp(density, 0.0, 1.0))
                                T_acc < 1e-10 && return 0.0
                            end
                            span_t0 = -1.0
                        end

                        i1_t_entry = node_dda_cell_time(i1_ndda)
                        dda_step!(i1_ndda.state)
                    end

                    i2_t_entry = node_dda_cell_time(i2_ndda)
                    dda_step!(i2_ndda.state)
                    continue
                else
                    if span_t0 >= 0.0
                        span_end = min(i2_t_entry, t1)
                        t = max(t, span_t0)
                        while t < span_end
                            t += randexp(rng) * inv_sigma
                            t >= span_end && break
                            pos = ray.origin + t * ray.direction
                            density = max(0.0, get_value_trilinear(acc, pos))
                            T_acc *= (1.0 - clamp(density, 0.0, 1.0))
                            T_acc < 1e-10 && return 0.0
                        end
                        span_t0 = -1.0
                    end
                end
            else
                has_tile = _buf_mask_is_on(buf, i2_off + _I2_VMASK_OFF, cidx)
                if has_tile
                    span_t0 < 0.0 && (span_t0 = i2_t_entry)
                elseif span_t0 >= 0.0
                    span_end = min(i2_t_entry, t1)
                    t = max(t, span_t0)
                    while t < span_end
                        t += randexp(rng) * inv_sigma
                        t >= span_end && break
                        pos = ray.origin + t * ray.direction
                        density = max(0.0, get_value_trilinear(acc, pos))
                        T_acc *= (1.0 - clamp(density, 0.0, 1.0))
                        T_acc < 1e-10 && return 0.0
                    end
                    span_t0 = -1.0
                end
            end

            i2_t_entry = node_dda_cell_time(i2_ndda)
            dda_step!(i2_ndda.state)
        end

        if span_t0 >= 0.0
            span_end = min(i2_t_entry, t1)
            t = max(t, span_t0)
            while t < span_end
                t += randexp(rng) * inv_sigma
                t >= span_end && break
                pos = ray.origin + t * ray.direction
                density = max(0.0, get_value_trilinear(acc, pos))
                T_acc *= (1.0 - clamp(density, 0.0, 1.0))
                T_acc < 1e-10 && return 0.0
            end
            span_t0 = -1.0
        end
    end

    T_acc
end

# Legacy: create accessor internally
function ratio_tracking(ray::Ray, nanogrid::NanoGrid, t0::Float64, t1::Float64,
                        sigma_maj::Float64, rng)::Float64
    acc = NanoValueAccessor(nanogrid)
    ratio_tracking(ray, nanogrid, acc, t0, t1, sigma_maj, rng)
end

# ============================================================================
# Volume bounds intersection
# ============================================================================

@inline function _volume_bounds(nanogrid::NanoGrid)
    bbox = nano_bbox(nanogrid)
    bmin = SVec3d(Float64(bbox.min.x), Float64(bbox.min.y), Float64(bbox.min.z))
    bmax = SVec3d(Float64(bbox.max.x), Float64(bbox.max.y), Float64(bbox.max.z))
    (bmin, bmax)
end

@inline function _escape_radiance(scene::Scene)::NTuple{3, Float64}
    for light in scene.lights
        if light isa ConstantEnvironmentLight
            return (light.radiance[1], light.radiance[2], light.radiance[3])
        end
    end
    (scene.background[1], scene.background[2], scene.background[3])
end

# ============================================================================
# Emission-absorption preview renderer
# ============================================================================

function render_volume_preview(scene::Scene, width::Int, height::Int;
                               step_size::Float64=0.5, max_steps::Int=2000)
    for vol in scene.volumes
        vol.nanogrid === nothing && throw(ArgumentError(
            "VolumeEntry has no NanoGrid — call build_nanogrid(grid.tree) before rendering"))
    end

    pvols = map(_precompute_volume, scene.volumes)
    bg = _escape_radiance(scene)
    aspect = Float64(width) / Float64(height)
    pixels = Matrix{NTuple{3, Float64}}(undef, height, width)

    Threads.@threads for y in 1:height
        accs = map(pv -> NanoValueAccessor(pv.nanogrid), pvols)
        for x in 1:width
            u = (Float64(x) - 0.5) / Float64(width)
            v = 1.0 - (Float64(y) - 0.5) / Float64(height)
            ray = camera_ray(scene.camera, u, v, aspect)
            pixels[y, x] = _march_ea(ray, pvols, accs, bg, step_size, max_steps)
        end
    end
    pixels
end

function _march_ea(ray::Ray, pvols, accs, bg::NTuple{3,Float64},
                   step_size::Float64, max_steps::Int)
    acc_r = 0.0; acc_g = 0.0; acc_b = 0.0; transmittance = 1.0

    for (vi, pv) in enumerate(pvols)
        nacc = accs[vi]; reset!(nacc)
        tf = pv.tf; sigma_scale = pv.sigma_maj; emission_scale = pv.emission_scale
        steps_remaining = max_steps

        foreach_hdda_span(pv.nanogrid, ray) do span_t0, span_t1
            (transmittance < 1e-4 || steps_remaining <= 0) && return false
            t = span_t0
            @inbounds while t < span_t1 && transmittance > 1e-4 && steps_remaining > 0
                pos = ray.origin + t * ray.direction
                density = max(0.0, get_value_trilinear(nacc, pos))
                if density > 1e-6
                    rgba = evaluate(tf, density)
                    r, g, b, a = rgba
                    sigma_t = a * sigma_scale * step_size
                    step_transmittance = exp(-sigma_t)
                    emit = (1.0 - step_transmittance) * emission_scale
                    acc_r += transmittance * r * emit
                    acc_g += transmittance * g * emit
                    acc_b += transmittance * b * emit
                    transmittance *= step_transmittance
                end
                t += step_size; steps_remaining -= 1
            end
            return true
        end
    end

    acc_r += transmittance * bg[1]; acc_g += transmittance * bg[2]; acc_b += transmittance * bg[3]
    (clamp(acc_r, 0.0, 1.0), clamp(acc_g, 0.0, 1.0), clamp(acc_b, 0.0, 1.0))
end

# ============================================================================
# Single-scatter volume renderer
# ============================================================================

function render_volume_image(scene::Scene, width::Int, height::Int;
                             spp::Int=1, seed::UInt64=UInt64(42),
                             max_bounces::Int=1)
    for vol in scene.volumes
        vol.nanogrid === nothing && throw(ArgumentError(
            "VolumeEntry has no NanoGrid — call build_nanogrid(grid.tree) before rendering"))
    end

    pvols = map(_precompute_volume, scene.volumes)
    bg = _escape_radiance(scene)
    aspect = Float64(width) / Float64(height)
    pixels = Matrix{NTuple{3, Float64}}(undef, height, width)
    inv_spp = 1.0 / spp

    Threads.@threads for y in 1:height
        rng = Xoshiro(seed + UInt64(y))
        accs = map(pv -> NanoValueAccessor(pv.nanogrid), pvols)
        for x in 1:width
            acc_r = 0.0; acc_g = 0.0; acc_b = 0.0
            for _ in 1:spp
                u = (Float64(x) - 1.0 + rand(rng)) / Float64(width)
                v = 1.0 - (Float64(y) - 1.0 + rand(rng)) / Float64(height)
                ray = camera_ray(scene.camera, u, v, aspect)

                r, g, b = _trace_ss(ray, pvols, accs, bg, rng, scene.lights)
                acc_r += r; acc_g += g; acc_b += b
            end
            pixels[y, x] = (clamp(acc_r * inv_spp, 0.0, 1.0),
                            clamp(acc_g * inv_spp, 0.0, 1.0),
                            clamp(acc_b * inv_spp, 0.0, 1.0))
        end
    end
    pixels
end

function _trace_ss(ray::Ray, pvols, accs, bg::NTuple{3,Float64}, rng, lights)::NTuple{3, Float64}
    acc_r = 0.0; acc_g = 0.0; acc_b = 0.0; throughput = 1.0

    for (vi, pv) in enumerate(pvols)
        hit = intersect_bbox(ray, pv.bmin, pv.bmax)
        hit === nothing && continue
        t_enter, t_exit = hit

        t_hit, event = delta_tracking_step(ray, pv.nanogrid, accs[vi],
                                            t_enter, t_exit,
                                            pv.sigma_maj, pv.albedo, rng)
        event == :escaped && continue

        hit_pos = ray.origin + t_hit * ray.direction
        reset!(accs[vi])
        density = max(0.0, get_value_trilinear(accs[vi], hit_pos))
        rgba = evaluate(pv.tf, density)
        emit_r, emit_g, emit_b, _ = rgba

        for light in lights
            light_dir, light_intensity, light_dist = _light_contribution(light, hit_pos)
            shadow_ray = Ray_prenorm(hit_pos + 0.01 * light_dir, light_dir)
            shadow_hit = intersect_bbox(shadow_ray, pv.bmin, pv.bmax)

            transmittance = if shadow_hit !== nothing
                st0, st1 = shadow_hit
                st1 = min(st1, light_dist)
                ratio_tracking(shadow_ray, pv.nanogrid, accs[vi], st0, st1, pv.sigma_maj, rng)
            else
                1.0
            end

            cos_theta = -dot(ray.direction, light_dir)
            phase = evaluate(pv.pf, cos_theta)
            scale = throughput * transmittance * phase * pv.emission_scale
            acc_r += emit_r * light_intensity[1] * scale
            acc_g += emit_g * light_intensity[2] * scale
            acc_b += emit_b * light_intensity[3] * scale
        end
    end

    acc_r += throughput * bg[1]; acc_g += throughput * bg[2]; acc_b += throughput * bg[3]
    (acc_r, acc_g, acc_b)
end

@inline function _light_contribution(light::PointLight, point::SVec3d)
    delta = light.position - point
    dist = norm(delta)
    if dist < 1e-10
        return (SVec3d(0.0, 0.0, 1.0), SVec3d(0.0, 0.0, 0.0), 0.0)
    end
    dir = delta / dist
    intensity = light.intensity / (dist * dist)
    (dir, intensity, dist)
end

@inline function _light_contribution(light::DirectionalLight, point::SVec3d)
    (light.direction, light.intensity, Inf)
end

# ============================================================================
# Multi-scatter path tracer
# ============================================================================

function _delta_tracking_collision(ray::Ray, nanogrid::NanoGrid,
                                   acc::NanoValueAccessor,
                                   t_enter::Float64, t_exit::Float64,
                                   sigma_maj::Float64, rng)
    # Reuse delta_tracking_step with albedo=1.0 (always scatter, never absorb)
    t, event = delta_tracking_step(ray, nanogrid, acc, t_enter, t_exit, sigma_maj, 1.0, rng)
    (t, event == :scattered)
end

# Legacy
function _delta_tracking_collision(ray::Ray, nanogrid::NanoGrid,
                                   t_enter::Float64, t_exit::Float64,
                                   sigma_maj::Float64, rng)
    acc = NanoValueAccessor(nanogrid)
    _delta_tracking_collision(ray, nanogrid, acc, t_enter, t_exit, sigma_maj, rng)
end

function _shadow_transmittance(shadow_ray::Ray, pvols, accs,
                               max_dist::Float64, rng)::Float64
    T = 1.0
    for (vi, pv) in enumerate(pvols)
        hit = intersect_bbox(shadow_ray, pv.bmin, pv.bmax)
        hit === nothing && continue
        t0, t1 = hit
        t1 = min(t1, max_dist)
        t0 >= t1 && continue
        T *= ratio_tracking(shadow_ray, pv.nanogrid, accs[vi], t0, t1, pv.sigma_maj, rng)
        T < 1e-10 && return 0.0
    end
    return T
end

# Legacy: scene-based version
function _shadow_transmittance(shadow_ray::Ray, scene::Scene,
                               max_dist::Float64, rng)::Float64
    T = 1.0
    for vol in scene.volumes
        nanogrid = vol.nanogrid
        nanogrid === nothing && continue
        bmin, bmax = _volume_bounds(nanogrid)
        hit = intersect_bbox(shadow_ray, bmin, bmax)
        hit === nothing && continue
        t0, t1 = hit
        t1 = min(t1, max_dist)
        t0 >= t1 && continue
        sigma_maj = vol.material.sigma_scale
        T *= ratio_tracking(shadow_ray, nanogrid, t0, t1, sigma_maj, rng)
        T < 1e-10 && return 0.0
    end
    return T
end

function _trace_multiscatter(ray::Ray, scene::Scene, rng,
                             max_bounces::Int, rr_start::Int)::NTuple{3, Float64}
    pvols = map(_precompute_volume, scene.volumes)
    accs = map(pv -> NanoValueAccessor(pv.nanogrid), pvols)
    _trace_ms_opt(ray, scene, pvols, accs, rng, max_bounces, rr_start)
end

function _trace_ms_opt(ray::Ray, scene::Scene, pvols, accs,
                       rng, max_bounces::Int, rr_start::Int)::NTuple{3, Float64}
    acc_r = 0.0; acc_g = 0.0; acc_b = 0.0
    throughput = 1.0
    current_ray = ray

    for bounce in 0:max_bounces
        collision = false

        for (vi, pv) in enumerate(pvols)
            hit = intersect_bbox(current_ray, pv.bmin, pv.bmax)
            hit === nothing && continue
            t_enter, t_exit = hit

            t_hit, found = _delta_tracking_collision(current_ray, pv.nanogrid,
                                                      accs[vi], t_enter, t_exit,
                                                      pv.sigma_maj, rng)
            !found && continue

            hit_pos = current_ray.origin + t_hit * current_ray.direction
            reset!(accs[vi])
            density = max(0.0, get_value_trilinear(accs[vi], hit_pos))
            rgba = evaluate(pv.tf, density)
            emit_r, emit_g, emit_b, _ = rgba

            throughput *= pv.albedo

            for light in scene.lights
                light_dir, light_intensity, light_dist = _light_contribution(light, hit_pos)
                shadow_ray = Ray_prenorm(hit_pos + 0.01 * light_dir, light_dir)
                transmittance = _shadow_transmittance(shadow_ray, pvols, accs, light_dist, rng)
                cos_theta = -dot(current_ray.direction, light_dir)
                phase = evaluate(pv.pf, cos_theta)
                scale = throughput * transmittance * phase * pv.emission_scale
                acc_r += emit_r * light_intensity[1] * scale
                acc_g += emit_g * light_intensity[2] * scale
                acc_b += emit_b * light_intensity[3] * scale
            end

            new_dir = sample_phase(pv.pf, current_ray.direction, rng)
            current_ray = Ray(hit_pos + 1e-4 * new_dir, new_dir)
            collision = true
            break
        end

        !collision && break

        if bounce >= rr_start
            rr_prob = clamp(throughput, 0.05, 1.0)
            if rand(rng) > rr_prob
                throughput = 0.0; break
            end
            throughput /= rr_prob
        end

        throughput < 1e-10 && break
    end

    bg = _escape_radiance(scene)
    acc_r += throughput * bg[1]; acc_g += throughput * bg[2]; acc_b += throughput * bg[3]
    (acc_r, acc_g, acc_b)
end

# ============================================================================
# render_volume — unified dispatch
# ============================================================================

function render_volume(scene::Scene, method::ReferencePathTracer,
                       width::Int, height::Int;
                       spp::Int=1, seed::UInt64=UInt64(42))
    for vol in scene.volumes
        vol.nanogrid === nothing && throw(ArgumentError(
            "VolumeEntry has no NanoGrid — call build_nanogrid(grid.tree) before rendering"))
    end

    pvols = map(_precompute_volume, scene.volumes)
    bg = _escape_radiance(scene)
    aspect = Float64(width) / Float64(height)
    pixels = Matrix{NTuple{3, Float64}}(undef, height, width)
    inv_spp = 1.0 / spp

    Threads.@threads for y in 1:height
        rng = Xoshiro(seed + UInt64(y))
        accs = map(pv -> NanoValueAccessor(pv.nanogrid), pvols)
        for x in 1:width
            acc_r = 0.0; acc_g = 0.0; acc_b = 0.0
            for _ in 1:spp
                u = (Float64(x) - 1.0 + rand(rng)) / Float64(width)
                v = 1.0 - (Float64(y) - 1.0 + rand(rng)) / Float64(height)
                ray = camera_ray(scene.camera, u, v, aspect)
                r, g, b = _trace_ms_opt(ray, scene, pvols, accs, rng,
                                         method.max_bounces, method.rr_start)
                acc_r += r; acc_g += g; acc_b += b
            end
            pixels[y, x] = (clamp(acc_r * inv_spp, 0.0, 1.0),
                            clamp(acc_g * inv_spp, 0.0, 1.0),
                            clamp(acc_b * inv_spp, 0.0, 1.0))
        end
    end
    pixels
end

function render_volume(scene::Scene, ::SingleScatterTracer,
                       width::Int, height::Int;
                       spp::Int=1, seed::UInt64=UInt64(42))
    render_volume_image(scene, width, height; spp=spp, seed=seed)
end

function render_volume(scene::Scene, method::EmissionAbsorption,
                       width::Int, height::Int; kwargs...)
    render_volume_preview(scene, width, height;
                          step_size=method.step_size, max_steps=method.max_steps)
end
