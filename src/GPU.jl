# GPU.jl - GPU acceleration via KernelAbstractions.jl
#
# Provides GPU-compatible wrappers around NanoGrid operations
# and rendering kernels for level sets and fog volumes.
#
# Includes:
#   - Device-side NanoGrid value lookup (_gpu_get_value)
#   - Delta tracking kernel (unbiased free-flight sampling)
#   - Ratio tracking for shadow rays
#   - CPU fallback renderers (fixed-step, sphere trace)
#
# Usage:
#   using Lyr
#   grid = build_nanogrid(vdb.grids[1].tree)
#   img = gpu_render_volume(grid, scene, 512, 512)  # KA CPU backend

using KernelAbstractions
using Adapt

# ============================================================================
# GPU NanoGrid wrapper
# ============================================================================

"""
    GPUNanoGrid{T,B}

GPU-resident NanoGrid wrapping a device buffer. Mirrors NanoGrid's buffer layout
but stores data in a GPU-compatible array type B (e.g. CuArray{UInt8}).

# Fields
- `buffer::B` - GPU device buffer
- `background::T` - Background value (scalar, on host)
"""
struct GPUNanoGrid{T, B}
    buffer::B
    background::T
end

"""
    adapt_nanogrid(ArrayType, nanogrid::NanoGrid) -> GPUNanoGrid

Transfer a NanoGrid to GPU memory using the given array type (e.g. CuArray).
"""
function adapt_nanogrid(ArrayType, nanogrid::NanoGrid{T}) where T
    gpu_buf = ArrayType(nanogrid.buffer)
    GPUNanoGrid{T, typeof(gpu_buf)}(gpu_buf, nanogrid.background)
end

# ============================================================================
# Device-side buffer operations
# ============================================================================

# These functions mirror the NanoVDB buffer operations but work on abstract
# array types for GPU compatibility. They are designed to be called inside
# @kernel functions.

"""Device-side buffer load — read a value of type T from position pos."""
@inline function _gpu_buf_load(::Type{T}, buf, pos::Int32) where T
    # For GPU kernels: use unsafe_load pattern that works on device
    @inbounds reinterpret(T, @view buf[pos:pos + Int32(sizeof(T)) - Int32(1)])[1]
end

"""Device-side mask bit test — check if bit bit_idx is on in mask at mask_pos."""
@inline function _gpu_buf_mask_is_on(buf, mask_pos::Int32, bit_idx::Int32)::Bool
    word_idx = bit_idx >> Int32(6)
    bit_in_word = bit_idx & Int32(63)
    word_pos = mask_pos + word_idx * Int32(8)
    @inbounds word = reinterpret(UInt64, @view buf[word_pos:word_pos + Int32(7)])[1]
    (word >> bit_in_word) & UInt64(1) != UInt64(0)
end

"""Device-side count_on_before — count on-bits before bit_idx using prefix sums."""
@inline function _gpu_buf_count_on_before(buf, mask_pos::Int32, prefix_pos::Int32, bit_idx::Int32)::Int32
    bit_idx == Int32(0) && return Int32(0)
    word_idx = bit_idx >> Int32(6)
    bit_in_word = bit_idx & Int32(63)

    count = word_idx > Int32(0) ?
        _gpu_buf_load(UInt32, buf, prefix_pos + (word_idx - Int32(1)) * Int32(4)) :
        UInt32(0)

    if bit_in_word > Int32(0)
        word = _gpu_buf_load(UInt64, buf, mask_pos + word_idx * Int32(8))
        m = (UInt64(1) << bit_in_word) - UInt64(1)
        count += UInt32(count_ones(word & m))
    end

    Int32(count)
end

# ============================================================================
# Device-side NanoGrid value lookup (stateless, no cache — GPU-safe)
# ============================================================================

"""
    _gpu_coord_less(ax, ay, az, bx, by, bz) -> Bool

Lexicographic comparison of coordinates for binary search.
"""
@inline function _gpu_coord_less(ax::Int32, ay::Int32, az::Int32,
                                  bx::Int32, by::Int32, bz::Int32)::Bool
    ax < bx && return true
    ax > bx && return false
    ay < by && return true
    ay > by && return false
    az < bz
end

"""
    _gpu_get_value(buf, background, cx, cy, cz, header_T_size) -> Float32

Device-side NanoGrid value lookup. Traverses Root → I2 → I1 → Leaf
through the flat buffer using byte offsets. Stateless (no mutable cache).

All arithmetic uses Int32 for GPU compatibility.
"""
@inline function _gpu_get_value(buf, background::Float32,
                                 cx::Int32, cy::Int32, cz::Int32,
                                 header_T_size::Int32)::Float32
    # Header positions (Float32 value type → sizeof(T) = 4)
    root_count = Int32(_gpu_buf_load(UInt32, buf, Int32(37) + header_T_size))
    root_pos = Int32(_gpu_buf_load(UInt32, buf, Int32(53) + header_T_size))
    entry_sz = Int32(13) + header_T_size  # _root_entry_size

    # Internal2 origin: mask to 4096-aligned
    i2_mask = ~Int32(4095)
    i2_ox = cx & i2_mask
    i2_oy = cy & i2_mask
    i2_oz = cz & i2_mask

    # Binary search root table
    lo = Int32(1)
    hi = root_count
    entry_pos = Int32(0)
    found = false
    while lo <= hi
        mid = (lo + hi) >> Int32(1)
        mid_pos = root_pos + (mid - Int32(1)) * entry_sz
        mx = _gpu_buf_load(Int32, buf, mid_pos)
        my = _gpu_buf_load(Int32, buf, mid_pos + Int32(4))
        mz = _gpu_buf_load(Int32, buf, mid_pos + Int32(8))
        if mx == i2_ox && my == i2_oy && mz == i2_oz
            entry_pos = mid_pos
            found = true
            break
        elseif _gpu_coord_less(mx, my, mz, i2_ox, i2_oy, i2_oz)
            lo = mid + Int32(1)
        else
            hi = mid - Int32(1)
        end
    end
    found || return background

    # Check child or tile
    is_child = _gpu_buf_load(UInt8, buf, entry_pos + Int32(12))
    if is_child == 0x00
        return _gpu_buf_load(Float32, buf, entry_pos + Int32(13))
    end

    # Follow I2 offset
    i2_off = Int32(_gpu_buf_load(UInt32, buf, entry_pos + Int32(13)))

    # Internal2 child index
    i2_shift = Int32(7)  # INTERNAL1_TOTAL_LOG2
    i2_dim_mask = Int32(31)  # INTERNAL2_DIM - 1
    i2_ix = (cx >> i2_shift) & i2_dim_mask
    i2_iy = (cy >> i2_shift) & i2_dim_mask
    i2_iz = (cz >> i2_shift) & i2_dim_mask
    i2_idx = Int32(i2_ix * Int32(1024) + i2_iy * Int32(32) + i2_iz)

    # Check I2 child_mask
    if !_gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_CMASK_OFF), i2_idx)
        # Check tile
        if _gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_VMASK_OFF), i2_idx)
            cc = Int32(_gpu_buf_load(UInt32, buf, i2_off + Int32(_I2_CHILDCOUNT_OFF)))
            tile_idx = _gpu_buf_count_on_before(buf, i2_off + Int32(_I2_VMASK_OFF),
                                                 i2_off + Int32(_I2_VPREFIX_OFF), i2_idx)
            tile_pos = i2_off + Int32(_I2_DATA_OFF) + cc * Int32(4) + tile_idx * header_T_size
            return _gpu_buf_load(Float32, buf, tile_pos)
        end
        return background
    end

    # Follow to I1
    table_idx = _gpu_buf_count_on_before(buf, i2_off + Int32(_I2_CMASK_OFF),
                                          i2_off + Int32(_I2_CPREFIX_OFF), i2_idx)
    i1_off = Int32(_gpu_buf_load(UInt32, buf, i2_off + Int32(_I2_DATA_OFF) + table_idx * Int32(4)))

    # Internal1 child index
    i1_shift = Int32(3)  # LEAF_LOG2
    i1_dim_mask = Int32(15)  # INTERNAL1_DIM - 1
    i1_ix = (cx >> i1_shift) & i1_dim_mask
    i1_iy = (cy >> i1_shift) & i1_dim_mask
    i1_iz = (cz >> i1_shift) & i1_dim_mask
    i1_idx = Int32(i1_ix * Int32(256) + i1_iy * Int32(16) + i1_iz)

    # Check I1 child_mask
    if !_gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_CMASK_OFF), i1_idx)
        if _gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_VMASK_OFF), i1_idx)
            cc = Int32(_gpu_buf_load(UInt32, buf, i1_off + Int32(_I1_CHILDCOUNT_OFF)))
            tile_idx = _gpu_buf_count_on_before(buf, i1_off + Int32(_I1_VMASK_OFF),
                                                 i1_off + Int32(_I1_VPREFIX_OFF), i1_idx)
            tile_pos = i1_off + Int32(_I1_DATA_OFF) + cc * Int32(4) + tile_idx * header_T_size
            return _gpu_buf_load(Float32, buf, tile_pos)
        end
        return background
    end

    # Follow to Leaf
    table_idx = _gpu_buf_count_on_before(buf, i1_off + Int32(_I1_CMASK_OFF),
                                          i1_off + Int32(_I1_CPREFIX_OFF), i1_idx)
    leaf_off = Int32(_gpu_buf_load(UInt32, buf, i1_off + Int32(_I1_DATA_OFF) + table_idx * Int32(4)))

    # Leaf offset
    lx = cx & Int32(7)
    ly = cy & Int32(7)
    lz = cz & Int32(7)
    loff = lx * Int32(64) + ly * Int32(8) + lz

    _gpu_buf_load(Float32, buf, leaf_off + Int32(_LEAF_VALUES_OFF) + loff * header_T_size)
end

# ============================================================================
# Device-side ray-AABB intersection
# ============================================================================

"""Device-side ray-box intersection. Returns (t_enter, t_exit)."""
@inline function _gpu_ray_box_intersect(ox::Float32, oy::Float32, oz::Float32,
                                         idx::Float32, idy::Float32, idz::Float32,
                                         bmin_x::Float32, bmin_y::Float32, bmin_z::Float32,
                                         bmax_x::Float32, bmax_y::Float32, bmax_z::Float32)
    t1x = (bmin_x - ox) * idx
    t2x = (bmax_x - ox) * idx
    tmin = min(t1x, t2x)
    tmax = max(t1x, t2x)

    t1y = (bmin_y - oy) * idy
    t2y = (bmax_y - oy) * idy
    tmin = max(tmin, min(t1y, t2y))
    tmax = min(tmax, max(t1y, t2y))

    t1z = (bmin_z - oz) * idz
    t2z = (bmax_z - oz) * idz
    tmin = max(tmin, min(t1z, t2z))
    tmax = min(tmax, max(t1z, t2z))

    (max(tmin, 0.0f0), tmax)
end

# ============================================================================
# Device-side xorshift32 RNG
# ============================================================================

"""Xorshift32 PRNG step — returns (random Float32 in [0,1), new_state)."""
@inline function _gpu_xorshift(state::UInt32)::Tuple{Float32, UInt32}
    state = xor(state, state << UInt32(13))
    state = xor(state, state >> UInt32(17))
    state = xor(state, state << UInt32(5))
    # Map to [0, 1) — use upper bits for quality
    (Float32(state) / Float32(4294967296.0), state)
end

"""Hash a UInt32 seed for decorrelation (Wang hash)."""
@inline function _gpu_wang_hash(key::UInt32)::UInt32
    key = xor(key, UInt32(61)) ⊻ (key >> UInt32(16))
    key = key + (key << UInt32(3))
    key = xor(key, key >> UInt32(4))
    key = key * UInt32(0x27d4eb2d)
    key = xor(key, key >> UInt32(15))
    key
end

# ============================================================================
# Device-side transfer function LUT
# ============================================================================

"""Look up RGBA from a pre-baked 256-entry transfer function LUT."""
@inline function _gpu_tf_lookup(tf_lut, density::Float32,
                                 density_min::Float32, density_max::Float32)
    # Normalize density to [0, 1] and map to LUT index
    range = density_max - density_min
    range < 1.0f-10 && return (0.0f0, 0.0f0, 0.0f0, 0.0f0)
    t = clamp((density - density_min) / range, 0.0f0, 1.0f0)
    idx = Int32(1) + min(Int32(255), Int32(floor(t * 256.0f0)))

    base = (idx - Int32(1)) * Int32(4) + Int32(1)
    r = @inbounds tf_lut[base]
    g = @inbounds tf_lut[base + Int32(1)]
    b = @inbounds tf_lut[base + Int32(2)]
    a = @inbounds tf_lut[base + Int32(3)]
    (r, g, b, a)
end

# ============================================================================
# Delta tracking kernel (KernelAbstractions.jl)
# ============================================================================

"""
    delta_tracking_kernel!

GPU kernel implementing unbiased delta tracking volume rendering.
One workitem per pixel. Uses exponential free-flight sampling with
null-collision rejection for correct density estimation.

For shadow rays, uses ratio tracking transmittance estimation.
"""
@kernel function delta_tracking_kernel!(output, buf, tf_lut,
                                         background::Float32,
                                         sigma_maj::Float32,
                                         albedo::Float32,
                                         emission_scale::Float32,
                                         # Camera: position, forward, right, up, fov
                                         cam_px::Float32, cam_py::Float32, cam_pz::Float32,
                                         cam_fx::Float32, cam_fy::Float32, cam_fz::Float32,
                                         cam_rx::Float32, cam_ry::Float32, cam_rz::Float32,
                                         cam_ux::Float32, cam_uy::Float32, cam_uz::Float32,
                                         cam_fov::Float32,
                                         # Image dims
                                         width::Int32, height::Int32,
                                         # Volume bounds
                                         bmin_x::Float32, bmin_y::Float32, bmin_z::Float32,
                                         bmax_x::Float32, bmax_y::Float32, bmax_z::Float32,
                                         # Light direction + intensity
                                         light_dx::Float32, light_dy::Float32, light_dz::Float32,
                                         light_r::Float32, light_g::Float32, light_b::Float32,
                                         # Transfer function density range
                                         tf_dmin::Float32, tf_dmax::Float32,
                                         # Sizeof(T) for NanoGrid
                                         header_T_size::Int32,
                                         # RNG seed
                                         seed::UInt32)
    idx = @index(Global, Linear)
    px = ((idx - Int32(1)) % width) + Int32(1)
    py = ((idx - Int32(1)) ÷ width) + Int32(1)

    # Initialize per-pixel RNG
    rng_state = _gpu_wang_hash(UInt32(idx) + seed)

    # Jittered sub-pixel offset
    jx, rng_state = _gpu_xorshift(rng_state)
    jy, rng_state = _gpu_xorshift(rng_state)

    u = (Float32(px) - 1.0f0 + jx) / Float32(width)
    v = 1.0f0 - (Float32(py) - 1.0f0 + jy) / Float32(height)
    aspect = Float32(width) / Float32(height)

    # Generate camera ray
    half_fov = tan(cam_fov * 0.5f0 * Float32(π) / 180.0f0)
    rpx = (2.0f0 * u - 1.0f0) * aspect * half_fov
    rpy = (2.0f0 * v - 1.0f0) * half_fov

    dx = cam_fx + cam_rx * rpx + cam_ux * rpy
    dy = cam_fy + cam_ry * rpx + cam_uy * rpy
    dz = cam_fz + cam_rz * rpx + cam_uz * rpy
    dlen = sqrt(dx * dx + dy * dy + dz * dz)
    dlen = max(dlen, 1.0f-10)
    dx /= dlen
    dy /= dlen
    dz /= dlen

    # Inverse direction for ray-box
    idx_r = dx == 0.0f0 ? copysign(Inf32, dx) : 1.0f0 / dx
    idy_r = dy == 0.0f0 ? copysign(Inf32, dy) : 1.0f0 / dy
    idz_r = dz == 0.0f0 ? copysign(Inf32, dz) : 1.0f0 / dz

    # Ray-volume intersection
    t_enter, t_exit = _gpu_ray_box_intersect(cam_px, cam_py, cam_pz,
                                              idx_r, idy_r, idz_r,
                                              bmin_x, bmin_y, bmin_z,
                                              bmax_x, bmax_y, bmax_z)

    acc_r = 0.0f0
    acc_g = 0.0f0
    acc_b = 0.0f0
    throughput = 1.0f0

    if t_enter < t_exit
        # Delta tracking loop
        t = t_enter
        max_iter = Int32(1024)
        for _ in Int32(1):max_iter
            # Sample free-flight distance
            xi, rng_state = _gpu_xorshift(rng_state)
            xi = max(xi, 1.0f-10)  # avoid log(0)
            t += -log(xi) / sigma_maj

            t >= t_exit && break

            # Sample density at current position
            pos_x = cam_px + t * dx
            pos_y = cam_py + t * dy
            pos_z = cam_pz + t * dz
            cx = round(Int32, pos_x)
            cy = round(Int32, pos_y)
            cz = round(Int32, pos_z)
            density = _gpu_get_value(buf, background, cx, cy, cz, header_T_size)
            density = max(0.0f0, density)

            sigma_real = density * sigma_maj
            accept_prob = sigma_real / sigma_maj

            xi2, rng_state = _gpu_xorshift(rng_state)
            if xi2 < accept_prob
                # Real collision — evaluate transfer function
                tf_r, tf_g, tf_b, tf_a = _gpu_tf_lookup(tf_lut, density, tf_dmin, tf_dmax)

                xi3, rng_state = _gpu_xorshift(rng_state)
                if xi3 < albedo
                    # Scattering event — shadow ray via ratio tracking
                    shadow_ox = pos_x + 0.01f0 * light_dx
                    shadow_oy = pos_y + 0.01f0 * light_dy
                    shadow_oz = pos_z + 0.01f0 * light_dz
                    s_idx = light_dx == 0.0f0 ? copysign(Inf32, light_dx) : 1.0f0 / light_dx
                    s_idy = light_dy == 0.0f0 ? copysign(Inf32, light_dy) : 1.0f0 / light_dy
                    s_idz = light_dz == 0.0f0 ? copysign(Inf32, light_dz) : 1.0f0 / light_dz

                    st_enter, st_exit = _gpu_ray_box_intersect(
                        shadow_ox, shadow_oy, shadow_oz,
                        s_idx, s_idy, s_idz,
                        bmin_x, bmin_y, bmin_z,
                        bmax_x, bmax_y, bmax_z)

                    transmittance = 1.0f0
                    if st_enter < st_exit
                        st = st_enter
                        for _ in Int32(1):Int32(256)
                            xi_s, rng_state = _gpu_xorshift(rng_state)
                            xi_s = max(xi_s, 1.0f-10)
                            st += -log(xi_s) / sigma_maj
                            st >= st_exit && break

                            sp_x = shadow_ox + st * light_dx
                            sp_y = shadow_oy + st * light_dy
                            sp_z = shadow_oz + st * light_dz
                            scx = round(Int32, sp_x)
                            scy = round(Int32, sp_y)
                            scz = round(Int32, sp_z)
                            sd = _gpu_get_value(buf, background, scx, scy, scz, header_T_size)
                            sd = max(0.0f0, sd)

                            s_real = sd * sigma_maj
                            transmittance *= (1.0f0 - s_real / sigma_maj)
                            transmittance < 1.0f-10 && break
                        end
                    end

                    # Isotropic phase function = 1/(4π)
                    phase = 1.0f0 / (4.0f0 * Float32(π))
                    scale = throughput * transmittance * phase * emission_scale

                    acc_r += tf_r * light_r * scale
                    acc_g += tf_g * light_g * scale
                    acc_b += tf_b * light_b * scale
                end
                break  # single-scatter: terminate after first real collision
            end
            # Null collision — continue
        end
    end

    # Clamp output
    acc_r = clamp(acc_r, 0.0f0, 1.0f0)
    acc_g = clamp(acc_g, 0.0f0, 1.0f0)
    acc_b = clamp(acc_b, 0.0f0, 1.0f0)

    @inbounds output[idx] = (acc_r, acc_g, acc_b)
end

# ============================================================================
# GPU render dispatch
# ============================================================================

"""
    _bake_tf_lut(tf, density_min, density_max) -> Vector{Float32}

Pre-evaluate a transfer function into a 256-entry RGBA LUT (1024 Float32s).
"""
function _bake_tf_lut(tf, density_min::Float64, density_max::Float64)::Vector{Float32}
    lut = Vector{Float32}(undef, 256 * 4)
    range = density_max - density_min
    for i in 0:255
        d = density_min + (Float64(i) / 255.0) * range
        r, g, b, a = evaluate(tf, d)
        lut[i * 4 + 1] = Float32(r)
        lut[i * 4 + 2] = Float32(g)
        lut[i * 4 + 3] = Float32(b)
        lut[i * 4 + 4] = Float32(a)
    end
    lut
end

"""
    _estimate_density_range(nanogrid::NanoGrid{T}) -> Tuple{Float64, Float64}

Estimate the density range by sampling leaf values.
"""
function _estimate_density_range(nanogrid::NanoGrid{T})::Tuple{Float64, Float64} where T
    buf = nanogrid.buffer
    lf_count = nano_leaf_count(nanogrid)
    leaf_pos = _nano_leaf_pos(nanogrid)
    leaf_sz = _leaf_node_size(T)

    dmin = Inf
    dmax = -Inf

    # Sample every leaf, but only a few values per leaf for speed
    for i in 0:(lf_count - 1)
        base = leaf_pos + i * leaf_sz
        for v in [0, 64, 128, 256, 384, 511]
            val = Float64(_buf_load(T, buf, base + _LEAF_VALUES_OFF + v * sizeof(T)))
            val < dmin && (dmin = val)
            val > dmax && (dmax = val)
        end
    end

    dmin = isfinite(dmin) ? dmin : 0.0
    dmax = isfinite(dmax) ? dmax : 1.0
    (dmin, dmax)
end

"""
    gpu_render_volume(nanogrid::NanoGrid{T}, scene::Scene,
                       width::Int, height::Int;
                       spp=1, seed=UInt64(42),
                       backend=KernelAbstractions.CPU()) -> Matrix{NTuple{3, Float32}}

Render a volume using delta tracking on a KernelAbstractions backend.

Uses the first volume and first light from the scene. The transfer function
is pre-baked into a 256-entry LUT for device-side evaluation.

# Arguments
- `nanogrid` - NanoGrid to render (must be Float32 values)
- `scene` - Scene with camera, lights, and volume materials
- `width`, `height` - Image dimensions
- `spp` - Samples per pixel (accumulated with progressive averaging)
- `seed` - RNG seed
- `backend` - KernelAbstractions backend (default: CPU())
"""
function gpu_render_volume(nanogrid::NanoGrid{T}, scene::Scene,
                            width::Int, height::Int;
                            spp::Int=1, seed::UInt64=UInt64(42),
                            backend=KernelAbstractions.CPU()) where T
    vol = scene.volumes[1]
    mat = vol.material
    cam = scene.camera

    # Bake transfer function LUT
    dmin, dmax = _estimate_density_range(nanogrid)
    tf_lut = _bake_tf_lut(mat.transfer_function, dmin, dmax)

    # Get volume bounds
    bbox = nano_bbox(nanogrid)
    bmin_x = Float32(bbox.min.x)
    bmin_y = Float32(bbox.min.y)
    bmin_z = Float32(bbox.min.z)
    bmax_x = Float32(bbox.max.x)
    bmax_y = Float32(bbox.max.y)
    bmax_z = Float32(bbox.max.z)

    # Camera data
    cam_px, cam_py, cam_pz = Float32.(cam.position)
    cam_fx, cam_fy, cam_fz = Float32.(cam.forward)
    cam_rx, cam_ry, cam_rz = Float32.(cam.right)
    cam_ux, cam_uy, cam_uz = Float32.(cam.up)
    cam_fov = Float32(cam.fov)

    # Light data (use first light — directional)
    light = scene.lights[1]
    if light isa DirectionalLight
        light_dx, light_dy, light_dz = Float32.(light.direction)
        light_r, light_g, light_b = Float32.(light.intensity)
    elseif light isa PointLight
        # Use direction from volume center to point light
        cx = (bmin_x + bmax_x) / 2.0f0
        cy = (bmin_y + bmax_y) / 2.0f0
        cz = (bmin_z + bmax_z) / 2.0f0
        lx, ly, lz = Float32.(light.position)
        ddx, ddy, ddz = lx - cx, ly - cy, lz - cz
        dlen = sqrt(ddx^2 + ddy^2 + ddz^2)
        dlen = max(dlen, 1.0f-10)
        light_dx, light_dy, light_dz = ddx / dlen, ddy / dlen, ddz / dlen
        light_r, light_g, light_b = Float32.(light.intensity)
    else
        light_dx, light_dy, light_dz = 0.577f0, 0.577f0, 0.577f0
        light_r, light_g, light_b = 1.0f0, 1.0f0, 1.0f0
    end

    background_f32 = Float32(nano_background(nanogrid))
    sigma_maj = Float32(mat.sigma_scale)
    albedo_f32 = Float32(mat.scattering_albedo)
    emission_f32 = Float32(mat.emission_scale)
    header_T_size = Int32(sizeof(T))
    w = Int32(width)
    h = Int32(height)

    # Adapt buffer for backend
    dev_buf = Adapt.adapt(backend, nanogrid.buffer)
    dev_tf = Adapt.adapt(backend, tf_lut)

    # Allocate output — use fill + adapt since NTuple has no zero() method
    npixels = width * height
    z3 = (0.0f0, 0.0f0, 0.0f0)
    output = Adapt.adapt(backend, fill(z3, npixels))

    # Progressive accumulation for multi-spp
    acc_buf = Adapt.adapt(backend, fill(z3, npixels))

    kernel! = delta_tracking_kernel!(backend)

    for s in 1:spp
        kernel!(output, dev_buf, dev_tf,
                background_f32, sigma_maj, albedo_f32, emission_f32,
                cam_px, cam_py, cam_pz,
                cam_fx, cam_fy, cam_fz,
                cam_rx, cam_ry, cam_rz,
                cam_ux, cam_uy, cam_uz,
                cam_fov,
                w, h,
                bmin_x, bmin_y, bmin_z,
                bmax_x, bmax_y, bmax_z,
                light_dx, light_dy, light_dz,
                light_r, light_g, light_b,
                Float32(dmin), Float32(dmax),
                header_T_size,
                UInt32(seed + UInt64(s));
                ndrange=npixels)
        KernelAbstractions.synchronize(backend)

        # Accumulate
        for i in 1:npixels
            old = acc_buf[i]
            new = output[i]
            acc_buf[i] = (old[1] + new[1], old[2] + new[2], old[3] + new[3])
        end
    end

    # Average and reshape
    inv_spp = 1.0f0 / Float32(spp)
    result = Matrix{NTuple{3, Float32}}(undef, height, width)
    for i in 1:npixels
        r, g, b = acc_buf[i]
        x = ((i - 1) % width) + 1
        y = ((i - 1) ÷ width) + 1
        result[y, x] = (clamp(r * inv_spp, 0.0f0, 1.0f0),
                         clamp(g * inv_spp, 0.0f0, 1.0f0),
                         clamp(b * inv_spp, 0.0f0, 1.0f0))
    end

    result
end

# ============================================================================
# GPU sphere trace kernel (for level sets)
# ============================================================================

"""
    gpu_sphere_trace!(output, gpu_grid, cam_pos, cam_fwd, cam_right, cam_up,
                      fov, width, height, light_dir)

GPU kernel for sphere tracing level sets. One workitem per pixel.
Uses flat DDA through GPUNanoGrid for zero-crossing detection.

This is a placeholder that works on CPU backend. Full GPU implementation
requires KernelAbstractions.jl @kernel macro.
"""
function gpu_sphere_trace_cpu!(output::Matrix{NTuple{3, Float32}},
                                nanogrid::NanoGrid{T},
                                camera::Camera,
                                width::Int, height::Int;
                                light_dir::NTuple{3, Float64}=(0.577, 0.577, 0.577)) where T
    aspect = Float32(width) / Float32(height)
    light = _normalize(light_dir)

    for y in 1:height
        for x in 1:width
            u = (Float32(x) - 0.5f0) / Float32(width)
            v = 1.0f0 - (Float32(y) - 0.5f0) / Float32(height)

            ray = camera_ray(camera, Float64(u), Float64(v), Float64(aspect))

            # Use NanoVolumeRayIntersector for leaf iteration
            acc = NanoValueAccessor(nanogrid)
            bg = Float64(nanogrid.background)
            prev_sdf = Inf
            prev_t = -Inf
            hit = false
            hit_intensity = 0.0f0

            for leaf_hit in NanoVolumeRayIntersector(nanogrid, ray)
                idx_origin = SVec3d(Float64(leaf_hit.bbox_min[1]),
                                    Float64(leaf_hit.bbox_min[2]),
                                    Float64(leaf_hit.bbox_min[3]))

                # Simple fixed-step through leaf
                t = leaf_hit.t_enter
                dt = 0.5
                while t < leaf_hit.t_exit
                    pos = ray.origin + t * ray.direction
                    ix = round(Int32, pos[1])
                    iy = round(Int32, pos[2])
                    iz = round(Int32, pos[3])
                    sdf = Float64(get_value(acc, coord(ix, iy, iz)))

                    if prev_sdf > 0.0 && sdf <= 0.0 && isfinite(prev_sdf)
                        hit = true
                        # Simple normal from central differences
                        h = 1.0
                        dx = Float64(get_value(acc, coord(ix + Int32(1), iy, iz))) -
                             Float64(get_value(acc, coord(ix - Int32(1), iy, iz)))
                        dy = Float64(get_value(acc, coord(ix, iy + Int32(1), iz))) -
                             Float64(get_value(acc, coord(ix, iy - Int32(1), iz)))
                        dz = Float64(get_value(acc, coord(ix, iy, iz + Int32(1)))) -
                             Float64(get_value(acc, coord(ix, iy, iz - Int32(1))))
                        len = sqrt(dx^2 + dy^2 + dz^2)
                        if len > 1e-10
                            normal = (dx / len, dy / len, dz / len)
                        else
                            normal = (0.0, 0.0, 1.0)
                        end
                        hit_intensity = Float32(shade(normal, light))
                        break
                    end

                    prev_sdf = sdf
                    prev_t = t
                    t += dt
                end

                hit && break
            end

            if hit
                output[y, x] = (hit_intensity, hit_intensity, hit_intensity)
            else
                output[y, x] = (0.1f0, 0.1f0, 0.15f0)
            end
        end
    end

    output
end

# ============================================================================
# GPU volume march (for fog volumes)
# ============================================================================

"""
    gpu_volume_march_cpu!(output, nanogrid, camera, tf_points, width, height;
                          step_size=0.5, sigma_scale=1.0)

CPU fallback for GPU volume marching. Fixed-step emission-absorption
through NanoGrid with transfer function lookup.
"""
function gpu_volume_march_cpu!(output::Matrix{NTuple{3, Float32}},
                                nanogrid::NanoGrid{T},
                                camera::Camera,
                                tf::Any,  # TransferFunction
                                width::Int, height::Int;
                                step_size::Float64=0.5,
                                sigma_scale::Float64=1.0) where T
    aspect = Float64(width) / Float64(height)
    acc = NanoValueAccessor(nanogrid)
    bbox = nano_bbox(nanogrid)
    bmin = SVec3d(Float64(bbox.min.x), Float64(bbox.min.y), Float64(bbox.min.z))
    bmax = SVec3d(Float64(bbox.max.x), Float64(bbox.max.y), Float64(bbox.max.z))

    for y in 1:height
        for x in 1:width
            u = (Float64(x) - 0.5) / Float64(width)
            v = 1.0 - (Float64(y) - 0.5) / Float64(height)
            ray = camera_ray(camera, u, v, aspect)

            t_enter, t_exit = _ray_box_intersect(ray, bmin, bmax)

            acc_r = 0.0
            acc_g = 0.0
            acc_b = 0.0
            transmittance = 1.0

            if t_enter < t_exit
                t = t_enter
                while t < t_exit && transmittance > 1e-4
                    pos = ray.origin + t * ray.direction
                    density = Float64(get_value(acc,
                        coord(round(Int32, pos[1]), round(Int32, pos[2]), round(Int32, pos[3]))))
                    density = max(0.0, density)

                    if density > 1e-6
                        rgba = evaluate(tf, density)
                        r, g, b, a = rgba
                        sigma_t = a * sigma_scale * step_size
                        step_T = exp(-sigma_t)
                        emit = 1.0 - step_T
                        acc_r += transmittance * r * emit
                        acc_g += transmittance * g * emit
                        acc_b += transmittance * b * emit
                        transmittance *= step_T
                    end

                    t += step_size
                end
            end

            # Background blend
            acc_r += transmittance * 0.0
            acc_g += transmittance * 0.0
            acc_b += transmittance * 0.0

            output[y, x] = (Float32(clamp(acc_r, 0.0, 1.0)),
                            Float32(clamp(acc_g, 0.0, 1.0)),
                            Float32(clamp(acc_b, 0.0, 1.0)))
        end
    end

    output
end

# ============================================================================
# Progressive rendering accumulator
# ============================================================================

"""
    ProgressiveAccumulator

Accumulator for progressive rendering. Stores running sum and sample count.
"""
mutable struct ProgressiveAccumulator
    buffer::Matrix{NTuple{3, Float64}}  # accumulated sum
    count::Int                           # number of passes
end

function ProgressiveAccumulator(width::Int, height::Int)
    buffer = zeros(NTuple{3, Float64}, height, width)
    ProgressiveAccumulator(buffer, 0)
end

"""
    accumulate!(acc, new_pass)

Add a new render pass to the accumulator.
"""
function accumulate!(acc::ProgressiveAccumulator, new_pass::Matrix{<:NTuple{3}})
    for i in eachindex(acc.buffer, new_pass)
        old = acc.buffer[i]
        r, g, b = new_pass[i]
        acc.buffer[i] = (old[1] + Float64(r), old[2] + Float64(g), old[3] + Float64(b))
    end
    acc.count += 1
end

"""
    resolve(acc) -> Matrix{NTuple{3, Float64}}

Get the averaged image from the accumulator.
"""
function resolve(acc::ProgressiveAccumulator)::Matrix{NTuple{3, Float64}}
    inv_n = 1.0 / max(1, acc.count)
    result = similar(acc.buffer)
    for i in eachindex(acc.buffer)
        r, g, b = acc.buffer[i]
        result[i] = (r * inv_n, g * inv_n, b * inv_n)
    end
    result
end
