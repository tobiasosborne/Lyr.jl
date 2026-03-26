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
# GPU Backend Selection
# ============================================================================

"""
    _GPU_BACKEND

Global backend reference. Set to `CUDABackend()` by the LyrCUDAExt extension
when CUDA.jl is loaded and a functional GPU is detected. Falls back to
`KernelAbstractions.CPU()` otherwise.

Do not set this directly — use `_default_gpu_backend()` to read it.
"""
const _GPU_BACKEND = Ref{Any}(KernelAbstractions.CPU())

"""
    _default_gpu_backend() -> KernelAbstractions.Backend

Return the default GPU backend. Returns `CUDABackend()` when CUDA.jl is loaded
and a functional GPU is detected, otherwise `CPU()`.
"""
_default_gpu_backend() = _GPU_BACKEND[]

"""
    gpu_available() -> Bool

Return `true` if a CUDA GPU backend is active. Requires both CUDA.jl
to be loaded and a functional GPU device to be present.
"""
gpu_available() = !(_GPU_BACKEND[] isa KernelAbstractions.CPU)

"""
    gpu_info() -> String

Return a description of the active GPU backend.
Dispatches to `_gpu_info(backend)` which the LyrCUDAExt extension
extends with a method for CUDABackend.
"""
gpu_info() = _gpu_info(_GPU_BACKEND[])
_gpu_info(::KernelAbstractions.CPU) = "GPU backend: CPU fallback (load CUDA.jl for GPU acceleration)"
_gpu_info(backend) = "GPU backend: $(typeof(backend))"

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

"""Device-side buffer load — read bytes and reconstruct via bit shifts (little-endian).
Uses scalar reinterpret for float/signed types, which is GPU-safe (register bitcast)."""
@inline function _gpu_buf_load(::Type{UInt8}, buf, pos::Int32)
    @inbounds buf[pos]
end

@inline function _gpu_buf_load(::Type{UInt32}, buf, pos::Int32)
    @inbounds begin
        b0 = UInt32(buf[pos])
        b1 = UInt32(buf[pos + Int32(1)])
        b2 = UInt32(buf[pos + Int32(2)])
        b3 = UInt32(buf[pos + Int32(3)])
    end
    b0 | (b1 << UInt32(8)) | (b2 << UInt32(16)) | (b3 << UInt32(24))
end

@inline function _gpu_buf_load(::Type{Int32}, buf, pos::Int32)
    reinterpret(Int32, _gpu_buf_load(UInt32, buf, pos))
end

@inline function _gpu_buf_load(::Type{Float32}, buf, pos::Int32)
    reinterpret(Float32, _gpu_buf_load(UInt32, buf, pos))
end

@inline function _gpu_buf_load(::Type{UInt64}, buf, pos::Int32)
    @inbounds begin
        lo = UInt64(_gpu_buf_load(UInt32, buf, pos))
        hi = UInt64(_gpu_buf_load(UInt32, buf, pos + Int32(4)))
    end
    lo | (hi << UInt64(32))
end

"""Device-side mask bit test — check if bit bit_idx is on in mask at mask_pos."""
@inline function _gpu_buf_mask_is_on(buf, mask_pos::Int32, bit_idx::Int32)::Bool
    word_idx = bit_idx >> Int32(6)
    bit_in_word = bit_idx & Int32(63)
    word_pos = mask_pos + word_idx * Int32(8)
    word = _gpu_buf_load(UInt64, buf, word_pos)
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
    # Header positions — must match NanoVDB.jl _header_*_pos chain
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
# Device-side trilinear interpolation
# ============================================================================

"""
    _gpu_get_value_trilinear(buf, background, fx, fy, fz, header_T_size) -> Float32

Device-side trilinear interpolation through NanoGrid buffer.
Samples 8 corners of the voxel containing (fx, fy, fz) and
lerps based on fractional position.
"""
@inline function _gpu_get_value_trilinear(buf, background::Float32,
                                           fx::Float32, fy::Float32, fz::Float32,
                                           header_T_size::Int32)::Float32
    # Floor coordinates
    x0 = floor(Int32, fx)
    y0 = floor(Int32, fy)
    z0 = floor(Int32, fz)
    x1 = x0 + Int32(1)
    y1 = y0 + Int32(1)
    z1 = z0 + Int32(1)

    # Fractional part
    tx = fx - Float32(x0)
    ty = fy - Float32(y0)
    tz = fz - Float32(z0)

    # Sample 8 corners
    c000 = _gpu_get_value(buf, background, x0, y0, z0, header_T_size)
    c100 = _gpu_get_value(buf, background, x1, y0, z0, header_T_size)
    c010 = _gpu_get_value(buf, background, x0, y1, z0, header_T_size)
    c110 = _gpu_get_value(buf, background, x1, y1, z0, header_T_size)
    c001 = _gpu_get_value(buf, background, x0, y0, z1, header_T_size)
    c101 = _gpu_get_value(buf, background, x1, y0, z1, header_T_size)
    c011 = _gpu_get_value(buf, background, x0, y1, z1, header_T_size)
    c111 = _gpu_get_value(buf, background, x1, y1, z1, header_T_size)

    # Trilinear interpolation
    c00 = c000 * (1.0f0 - tx) + c100 * tx
    c10 = c010 * (1.0f0 - tx) + c110 * tx
    c01 = c001 * (1.0f0 - tx) + c101 * tx
    c11 = c011 * (1.0f0 - tx) + c111 * tx

    c0 = c00 * (1.0f0 - ty) + c10 * ty
    c1 = c01 * (1.0f0 - ty) + c11 * ty

    c0 * (1.0f0 - tz) + c1 * tz
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

"""Element-wise accumulation kernel: acc[i] += src[i]."""
@kernel function _accumulate_kernel!(acc, src)
    idx = @index(Global, Linear)
    old = @inbounds acc[idx]
    new = @inbounds src[idx]
    @inbounds acc[idx] = (old[1] + new[1], old[2] + new[2], old[3] + new[3])
end

"""
    _gpu_hg_eval(g, cos_theta) -> Float32

Evaluate the Henyey-Greenstein phase function on GPU.
Returns p(cos_theta) = (1-g²) / (4π (1+g²-2g·cos_theta)^(3/2)).
For |g| < 1e-6, returns isotropic 1/(4π).
"""
@inline function _gpu_hg_eval(g::Float32, cos_theta::Float32)::Float32
    inv4pi = 1.0f0 / (4.0f0 * Float32(π))
    abs(g) < 1.0f-6 && return inv4pi
    denom = 1.0f0 + g * g - 2.0f0 * g * cos_theta
    (1.0f0 - g * g) / (4.0f0 * Float32(π) * denom * sqrt(denom))
end

"""Sample cos_theta from HG inverse CDF. For |g|<1e-6, uniform sphere sampling."""
@inline function _gpu_hg_sample_cos_theta(g::Float32, xi::Float32)::Float32
    if abs(g) < 1.0f-6
        return 1.0f0 - 2.0f0 * xi
    end
    s = (1.0f0 - g * g) / (1.0f0 + g - 2.0f0 * g * xi)
    ct = (1.0f0 + g * g - s * s) / (2.0f0 * g)
    clamp(ct, -1.0f0, 1.0f0)
end

"""Build orthonormal basis (tx,ty,tz, bx,by,bz) from direction (wx,wy,wz)."""
@inline function _gpu_build_basis(wx::Float32, wy::Float32, wz::Float32)
    # Choose helper axis with smallest component to avoid cancellation
    ax = abs(wx); ay = abs(wy); az = abs(wz)
    if ax < ay
        hx, hy, hz = ax < az ? (1.0f0, 0.0f0, 0.0f0) : (0.0f0, 0.0f0, 1.0f0)
    else
        hx, hy, hz = ay < az ? (0.0f0, 1.0f0, 0.0f0) : (0.0f0, 0.0f0, 1.0f0)
    end
    # Gram-Schmidt: t = normalize(h - (h·w)*w)
    d = hx * wx + hy * wy + hz * wz
    tx = hx - d * wx; ty = hy - d * wy; tz = hz - d * wz
    tlen = sqrt(tx * tx + ty * ty + tz * tz)
    tlen = max(tlen, 1.0f-10)
    tx /= tlen; ty /= tlen; tz /= tlen
    # b = w × t
    bx = wy * tz - wz * ty
    by = wz * tx - wx * tz
    bz = wx * ty - wy * tx
    (tx, ty, tz, bx, by, bz)
end

"""Sample scatter direction from HG phase function. Returns (new_dx, new_dy, new_dz, rng_state)."""
@inline function _gpu_sample_scatter(dx::Float32, dy::Float32, dz::Float32,
        phase_g::Float32, rng_state::UInt32)
    xi1, rng_state = _gpu_xorshift(rng_state)
    cos_theta = _gpu_hg_sample_cos_theta(phase_g, xi1)
    sin_theta = sqrt(max(0.0f0, 1.0f0 - cos_theta * cos_theta))
    xi2, rng_state = _gpu_xorshift(rng_state)
    phi = 2.0f0 * Float32(π) * xi2
    tx, ty, tz, bx, by, bz = _gpu_build_basis(dx, dy, dz)
    cp = cos(phi); sp = sin(phi)
    new_dx = sin_theta * cp * tx + sin_theta * sp * bx + cos_theta * dx
    new_dy = sin_theta * cp * ty + sin_theta * sp * by + cos_theta * dy
    new_dz = sin_theta * cp * tz + sin_theta * sp * bz + cos_theta * dz
    # Normalize
    dlen = sqrt(new_dx * new_dx + new_dy * new_dy + new_dz * new_dz)
    dlen = max(dlen, 1.0f-10)
    (new_dx / dlen, new_dy / dlen, new_dz / dlen, rng_state)
end

"""Read a packed light from the GPU light buffer. 7 floats per light: [type, x, y, z, r, g, b]."""
@inline function _gpu_read_light(light_buf, li::Int32)
    base = (li - Int32(1)) * Int32(7)
    @inbounds (light_buf[base + Int32(1)], light_buf[base + Int32(2)],
               light_buf[base + Int32(3)], light_buf[base + Int32(4)],
               light_buf[base + Int32(5)], light_buf[base + Int32(6)],
               light_buf[base + Int32(7)])
end

"""Compute light direction and effective intensity at a scatter point.
Returns (dir_x, dir_y, dir_z, eff_r, eff_g, eff_b).
Directional: fixed direction, no falloff. Point: direction from pos, 1/r² falloff."""
@inline function _gpu_light_contribution(light_buf, li::Int32,
        pos_x::Float32, pos_y::Float32, pos_z::Float32)
    ltype, lx, ly, lz, lr, lg, lb = _gpu_read_light(light_buf, li)
    if ltype < 0.5f0
        # Directional light: (lx,ly,lz) = direction toward light
        return (lx, ly, lz, lr, lg, lb, Inf32)
    else
        # Point light: (lx,ly,lz) = position
        ddx = lx - pos_x
        ddy = ly - pos_y
        ddz = lz - pos_z
        dist = sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
        dist = max(dist, 1.0f-10)
        inv_dist = 1.0f0 / dist
        inv_dist2 = inv_dist * inv_dist
        return (ddx * inv_dist, ddy * inv_dist, ddz * inv_dist,
                lr * inv_dist2, lg * inv_dist2, lb * inv_dist2, dist)
    end
end

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
                                         phase_g::Float32,
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
                                         # Lights (packed buffer + count)
                                         light_buf, n_lights::Int32,
                                         # Transfer function density range
                                         tf_dmin::Float32, tf_dmax::Float32,
                                         # Sizeof(T) for NanoGrid
                                         header_T_size::Int32,
                                         # RNG seed
                                         seed::UInt32,
                                         max_bounces::Int32)
    idx = @index(Global, Linear)
    px = ((idx - Int32(1)) % width) + Int32(1)
    py = ((idx - Int32(1)) ÷ width) + Int32(1)

    # Initialize per-pixel RNG — hash pixel and sample separately to prevent
    # cross-correlation (idx+seed collides: pixel 1 sample 2 == pixel 2 sample 1)
    rng_state = _gpu_wang_hash(_gpu_wang_hash(UInt32(idx)) ⊻ seed)

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

    ray_ox = cam_px; ray_oy = cam_py; ray_oz = cam_pz
    acc_r = 0.0f0; acc_g = 0.0f0; acc_b = 0.0f0
    throughput = 1.0f0

    for bounce in Int32(0):max_bounces
        idx_r = dx == 0.0f0 ? copysign(Inf32, dx) : 1.0f0 / dx
        idy_r = dy == 0.0f0 ? copysign(Inf32, dy) : 1.0f0 / dy
        idz_r = dz == 0.0f0 ? copysign(Inf32, dz) : 1.0f0 / dz

        t_enter, t_exit = _gpu_ray_box_intersect(ray_ox, ray_oy, ray_oz,
                                                  idx_r, idy_r, idz_r,
                                                  bmin_x, bmin_y, bmin_z,
                                                  bmax_x, bmax_y, bmax_z)
        t_enter >= t_exit && break

        did_scatter = false
        hit_x = 0.0f0; hit_y = 0.0f0; hit_z = 0.0f0
        t = t_enter
        for _ in Int32(1):Int32(1024)
            xi, rng_state = _gpu_xorshift(rng_state)
            xi = max(xi, 1.0f-10)
            t += -log(xi) / sigma_maj
            t >= t_exit && break

            pos_x = ray_ox + t * dx
            pos_y = ray_oy + t * dy
            pos_z = ray_oz + t * dz
            density = _gpu_get_value_trilinear(buf, background, pos_x, pos_y, pos_z, header_T_size)
            density = max(0.0f0, density)

            accept_prob = density * sigma_maj / sigma_maj
            xi2, rng_state = _gpu_xorshift(rng_state)
            if xi2 < accept_prob
                tf_r, tf_g, tf_b, tf_a = _gpu_tf_lookup(tf_lut, density, tf_dmin, tf_dmax)
                xi3, rng_state = _gpu_xorshift(rng_state)
                if xi3 < albedo
                    did_scatter = true
                    hit_x = pos_x; hit_y = pos_y; hit_z = pos_z
                    for li in Int32(1):n_lights
                        l_dx, l_dy, l_dz, l_r, l_g, l_b, l_dist =
                            _gpu_light_contribution(light_buf, li, pos_x, pos_y, pos_z)
                        shadow_ox = pos_x + 0.01f0 * l_dx
                        shadow_oy = pos_y + 0.01f0 * l_dy
                        shadow_oz = pos_z + 0.01f0 * l_dz
                        s_idx = l_dx == 0.0f0 ? copysign(Inf32, l_dx) : 1.0f0 / l_dx
                        s_idy = l_dy == 0.0f0 ? copysign(Inf32, l_dy) : 1.0f0 / l_dy
                        s_idz = l_dz == 0.0f0 ? copysign(Inf32, l_dz) : 1.0f0 / l_dz
                        st_enter, st_exit = _gpu_ray_box_intersect(
                            shadow_ox, shadow_oy, shadow_oz, s_idx, s_idy, s_idz,
                            bmin_x, bmin_y, bmin_z, bmax_x, bmax_y, bmax_z)
                        st_exit = min(st_exit, l_dist)
                        transmittance = 1.0f0
                        if st_enter < st_exit
                            st = st_enter
                            for _ in Int32(1):Int32(256)
                                xi_s, rng_state = _gpu_xorshift(rng_state)
                                xi_s = max(xi_s, 1.0f-10)
                                st += -log(xi_s) / sigma_maj
                                st >= st_exit && break
                                sp_x = shadow_ox + st * l_dx
                                sp_y = shadow_oy + st * l_dy
                                sp_z = shadow_oz + st * l_dz
                                sd = _gpu_get_value_trilinear(buf, background, sp_x, sp_y, sp_z, header_T_size)
                                sd = max(0.0f0, sd)
                                s_real = sd * sigma_maj
                                transmittance *= (1.0f0 - s_real / sigma_maj)
                                transmittance < 1.0f-10 && break
                            end
                        end
                        cos_theta = dx * l_dx + dy * l_dy + dz * l_dz
                        phase = _gpu_hg_eval(phase_g, cos_theta)
                        scale = throughput * transmittance * phase * emission_scale
                        acc_r += tf_r * l_r * scale
                        acc_g += tf_g * l_g * scale
                        acc_b += tf_b * l_b * scale
                    end
                end
                break  # terminate after first real collision in this bounce
            end
        end

        !did_scatter && break

        # Multi-bounce: sample new scatter direction, update ray
        throughput *= albedo
        dx, dy, dz, rng_state = _gpu_sample_scatter(dx, dy, dz, phase_g, rng_state)
        ray_ox = hit_x + 1.0f-4 * dx
        ray_oy = hit_y + 1.0f-4 * dy
        ray_oz = hit_z + 1.0f-4 * dz

        if bounce >= Int32(3)
            rr_prob = clamp(throughput, 0.05f0, 1.0f0)
            xi_rr, rng_state = _gpu_xorshift(rng_state)
            xi_rr > rr_prob && break
            throughput /= rr_prob
        end
        throughput < 1.0f-10 && break
    end

    @inbounds output[idx] = (clamp(acc_r, 0.0f0, 1.0f0),
                              clamp(acc_g, 0.0f0, 1.0f0),
                              clamp(acc_b, 0.0f0, 1.0f0))
end

# ============================================================================
# Device-side leaf caching for trilinear interpolation
# ============================================================================

"""Read a Float32 value directly from a cached leaf node (no tree traversal)."""
@inline function _gpu_leaf_read(buf, leaf_off::Int32,
                                 cx::Int32, cy::Int32, cz::Int32,
                                 header_T_size::Int32)::Float32
    loff = (cx & Int32(7)) * Int32(64) + (cy & Int32(7)) * Int32(8) + (cz & Int32(7))
    _gpu_buf_load(Float32, buf, leaf_off + Int32(_LEAF_VALUES_OFF) + loff * header_T_size)
end

"""Like _gpu_get_value but also returns the leaf byte offset (0 if tile/background)."""
function _gpu_get_value_with_leaf(buf::B, background::Float32,
                                           cx::Int32, cy::Int32, cz::Int32,
                                           header_T_size::Int32) where B
    root_count = Int32(_gpu_buf_load(UInt32, buf, Int32(37) + header_T_size))
    root_pos = Int32(_gpu_buf_load(UInt32, buf, Int32(53) + header_T_size))
    entry_sz = Int32(13) + header_T_size
    i2_mask = ~Int32(4095)
    i2_ox = cx & i2_mask; i2_oy = cy & i2_mask; i2_oz = cz & i2_mask
    lo = Int32(1); hi = root_count; entry_pos = Int32(0); found = false
    while lo <= hi
        mid = (lo + hi) >> Int32(1)
        mid_pos = root_pos + (mid - Int32(1)) * entry_sz
        mx = _gpu_buf_load(Int32, buf, mid_pos)
        my = _gpu_buf_load(Int32, buf, mid_pos + Int32(4))
        mz = _gpu_buf_load(Int32, buf, mid_pos + Int32(8))
        if mx == i2_ox && my == i2_oy && mz == i2_oz
            entry_pos = mid_pos; found = true; break
        elseif _gpu_coord_less(mx, my, mz, i2_ox, i2_oy, i2_oz)
            lo = mid + Int32(1)
        else
            hi = mid - Int32(1)
        end
    end
    found || return (background, Int32(0))
    is_child = _gpu_buf_load(UInt8, buf, entry_pos + Int32(12))
    is_child == 0x00 && return (_gpu_buf_load(Float32, buf, entry_pos + Int32(13)), Int32(0))
    i2_off = Int32(_gpu_buf_load(UInt32, buf, entry_pos + Int32(13)))
    i2_ix = (cx >> Int32(7)) & Int32(31); i2_iy = (cy >> Int32(7)) & Int32(31); i2_iz = (cz >> Int32(7)) & Int32(31)
    i2_idx = i2_ix * Int32(1024) + i2_iy * Int32(32) + i2_iz
    if !_gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_CMASK_OFF), i2_idx)
        if _gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_VMASK_OFF), i2_idx)
            cc = Int32(_gpu_buf_load(UInt32, buf, i2_off + Int32(_I2_CHILDCOUNT_OFF)))
            ti = _gpu_buf_count_on_before(buf, i2_off + Int32(_I2_VMASK_OFF), i2_off + Int32(_I2_VPREFIX_OFF), i2_idx)
            return (_gpu_buf_load(Float32, buf, i2_off + Int32(_I2_DATA_OFF) + cc * Int32(4) + ti * header_T_size), Int32(0))
        end
        return (background, Int32(0))
    end
    ti = _gpu_buf_count_on_before(buf, i2_off + Int32(_I2_CMASK_OFF), i2_off + Int32(_I2_CPREFIX_OFF), i2_idx)
    i1_off = Int32(_gpu_buf_load(UInt32, buf, i2_off + Int32(_I2_DATA_OFF) + ti * Int32(4)))
    i1_ix = (cx >> Int32(3)) & Int32(15); i1_iy = (cy >> Int32(3)) & Int32(15); i1_iz = (cz >> Int32(3)) & Int32(15)
    i1_idx = i1_ix * Int32(256) + i1_iy * Int32(16) + i1_iz
    if !_gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_CMASK_OFF), i1_idx)
        if _gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_VMASK_OFF), i1_idx)
            cc = Int32(_gpu_buf_load(UInt32, buf, i1_off + Int32(_I1_CHILDCOUNT_OFF)))
            ti = _gpu_buf_count_on_before(buf, i1_off + Int32(_I1_VMASK_OFF), i1_off + Int32(_I1_VPREFIX_OFF), i1_idx)
            return (_gpu_buf_load(Float32, buf, i1_off + Int32(_I1_DATA_OFF) + cc * Int32(4) + ti * header_T_size), Int32(0))
        end
        return (background, Int32(0))
    end
    ti = _gpu_buf_count_on_before(buf, i1_off + Int32(_I1_CMASK_OFF), i1_off + Int32(_I1_CPREFIX_OFF), i1_idx)
    leaf_off = Int32(_gpu_buf_load(UInt32, buf, i1_off + Int32(_I1_DATA_OFF) + ti * Int32(4)))
    val = _gpu_leaf_read(buf, leaf_off, cx, cy, cz, header_T_size)
    (val, leaf_off)
end

"""Cached value lookup. Returns (value, cache_ox, cache_oy, cache_oz, cache_off)."""
function _gpu_get_value_cached(buf::B, background::Float32,
                                        cx::Int32, cy::Int32, cz::Int32,
                                        header_T_size::Int32,
                                        cache_ox::Int32, cache_oy::Int32, cache_oz::Int32,
                                        cache_off::Int32) where B
    ox = cx & Int32(-8); oy = cy & Int32(-8); oz = cz & Int32(-8)
    if cache_off != Int32(0) && ox == cache_ox && oy == cache_oy && oz == cache_oz
        return (_gpu_leaf_read(buf, cache_off, cx, cy, cz, header_T_size),
                cache_ox, cache_oy, cache_oz, cache_off)
    end
    val, leaf_off = _gpu_get_value_with_leaf(buf, background, cx, cy, cz, header_T_size)
    leaf_off == Int32(0) && return (val, Int32(0), Int32(0), Int32(0), Int32(0))
    (val, ox, oy, oz, leaf_off)
end

"""
Trilinear interpolation with leaf caching.
Fast path (~75%): all 8 corners in same leaf → 1 traversal + 8 direct reads.
Returns (value, cache_ox, cache_oy, cache_oz, cache_off).
"""
function _gpu_get_value_trilinear_cached(buf::B, background::Float32,
                                                   fx::Float32, fy::Float32, fz::Float32,
                                                   header_T_size::Int32,
                                                   cache_ox::Int32, cache_oy::Int32,
                                                   cache_oz::Int32, cache_off::Int32) where B
    x0 = floor(Int32, fx); y0 = floor(Int32, fy); z0 = floor(Int32, fz)
    x1 = x0 + Int32(1);    y1 = y0 + Int32(1);    z1 = z0 + Int32(1)
    tx = fx - Float32(x0);  ty = fy - Float32(y0);  tz = fz - Float32(z0)

    # Same-leaf fast path: all 8 corners in one 8³ leaf
    if (x0 & Int32(7)) != Int32(7) && (y0 & Int32(7)) != Int32(7) && (z0 & Int32(7)) != Int32(7)
        leaf_ox = x0 & Int32(-8); leaf_oy = y0 & Int32(-8); leaf_oz = z0 & Int32(-8)
        if cache_off != Int32(0) && leaf_ox == cache_ox && leaf_oy == cache_oy && leaf_oz == cache_oz
            loff = cache_off  # cache hit
        else
            # One traversal to find leaf (discard value — use leaf reads below)
            _, loff = _gpu_get_value_with_leaf(buf, background, x0, y0, z0, header_T_size)
            if loff == Int32(0)
                # Tile/background — uniform value across all 8 corners
                v, _ = _gpu_get_value_with_leaf(buf, background, x0, y0, z0, header_T_size)
                return (v, Int32(0), Int32(0), Int32(0), Int32(0))
            end
            cache_ox = leaf_ox; cache_oy = leaf_oy; cache_oz = leaf_oz; cache_off = loff
        end
        c000 = _gpu_leaf_read(buf, loff, x0, y0, z0, header_T_size)
        c100 = _gpu_leaf_read(buf, loff, x1, y0, z0, header_T_size)
        c010 = _gpu_leaf_read(buf, loff, x0, y1, z0, header_T_size)
        c110 = _gpu_leaf_read(buf, loff, x1, y1, z0, header_T_size)
        c001 = _gpu_leaf_read(buf, loff, x0, y0, z1, header_T_size)
        c101 = _gpu_leaf_read(buf, loff, x1, y0, z1, header_T_size)
        c011 = _gpu_leaf_read(buf, loff, x0, y1, z1, header_T_size)
        c111 = _gpu_leaf_read(buf, loff, x1, y1, z1, header_T_size)
    else
        # Cross-leaf boundary — per-corner cached lookups
        c000, cache_ox, cache_oy, cache_oz, cache_off = _gpu_get_value_cached(buf, background, x0, y0, z0, header_T_size, cache_ox, cache_oy, cache_oz, cache_off)
        c100, cache_ox, cache_oy, cache_oz, cache_off = _gpu_get_value_cached(buf, background, x1, y0, z0, header_T_size, cache_ox, cache_oy, cache_oz, cache_off)
        c010, cache_ox, cache_oy, cache_oz, cache_off = _gpu_get_value_cached(buf, background, x0, y1, z0, header_T_size, cache_ox, cache_oy, cache_oz, cache_off)
        c110, cache_ox, cache_oy, cache_oz, cache_off = _gpu_get_value_cached(buf, background, x1, y1, z0, header_T_size, cache_ox, cache_oy, cache_oz, cache_off)
        c001, cache_ox, cache_oy, cache_oz, cache_off = _gpu_get_value_cached(buf, background, x0, y0, z1, header_T_size, cache_ox, cache_oy, cache_oz, cache_off)
        c101, cache_ox, cache_oy, cache_oz, cache_off = _gpu_get_value_cached(buf, background, x1, y0, z1, header_T_size, cache_ox, cache_oy, cache_oz, cache_off)
        c011, cache_ox, cache_oy, cache_oz, cache_off = _gpu_get_value_cached(buf, background, x0, y1, z1, header_T_size, cache_ox, cache_oy, cache_oz, cache_off)
        c111, cache_ox, cache_oy, cache_oz, cache_off = _gpu_get_value_cached(buf, background, x1, y1, z1, header_T_size, cache_ox, cache_oy, cache_oz, cache_off)
    end
    c00 = c000 * (1.0f0 - tx) + c100 * tx;  c10 = c010 * (1.0f0 - tx) + c110 * tx
    c01 = c001 * (1.0f0 - tx) + c101 * tx;  c11 = c011 * (1.0f0 - tx) + c111 * tx
    c0 = c00 * (1.0f0 - ty) + c10 * ty;     c1 = c01 * (1.0f0 - ty) + c11 * ty
    (c0 * (1.0f0 - tz) + c1 * tz, cache_ox, cache_oy, cache_oz, cache_off)
end

# ============================================================================
# GPU HDDA — hierarchical empty-space skipping for delta tracking
# ============================================================================

# --- DDA helpers (GPU-compatible, all scalar, no structs) ---

"""Safe floor to Int32, clamping to avoid InexactError on extreme values."""
@inline function _gpu_safe_floor_i32(x::Float32)::Int32
    y = floor(x)
    !isfinite(y) && return Int32(0)
    y > 2.0f9 && return typemax(Int32)
    y < -2.0f9 && return typemin(Int32)
    Int32(y)
end

"""Compute initial tmax for one axis of the DDA."""
@inline function _gpu_initial_tmax(origin_i::Float32, inv_dir_i::Float32,
                                    ijk_i::Int32, step_i::Int32, vs::Float32)::Float32
    isinf(inv_dir_i) && return Inf32
    boundary = Float32(step_i > Int32(0) ? ijk_i + Int32(1) : ijk_i) * vs
    (boundary - origin_i) * inv_dir_i
end

"""
Initialize Amanatides-Woo DDA. Returns 12 scalars:
(ijk_x,y,z, step_x,y,z, tmax_x,y,z, tdelta_x,y,z).
"""
@inline function _gpu_dda_init(
    ox::Float32, oy::Float32, oz::Float32,
    dx::Float32, dy::Float32, dz::Float32,
    idx::Float32, idy::Float32, idz::Float32,
    tmin::Float32, voxel_size::Float32)
    inv_vs = 1.0f0 / voxel_size
    # Nudge tmin inward to avoid landing on voxel boundary (floor → wrong cell).
    # Must be relative: at tmin≈178, eps(Float32)≈1.5e-5, so absolute 1e-6 is lost.
    nudge = max(abs(tmin) * 1.0f-5, 1.0f-5)
    px = ox + (tmin + nudge) * dx
    py = oy + (tmin + nudge) * dy
    pz = oz + (tmin + nudge) * dz
    ijk_x = _gpu_safe_floor_i32(px * inv_vs)
    ijk_y = _gpu_safe_floor_i32(py * inv_vs)
    ijk_z = _gpu_safe_floor_i32(pz * inv_vs)
    step_x = dx >= 0.0f0 ? Int32(1) : Int32(-1)
    step_y = dy >= 0.0f0 ? Int32(1) : Int32(-1)
    step_z = dz >= 0.0f0 ? Int32(1) : Int32(-1)
    tdelta_x = voxel_size * abs(idx)
    tdelta_y = voxel_size * abs(idy)
    tdelta_z = voxel_size * abs(idz)
    tmax_x = _gpu_initial_tmax(ox, idx, ijk_x, step_x, voxel_size)
    tmax_y = _gpu_initial_tmax(oy, idy, ijk_y, step_y, voxel_size)
    tmax_z = _gpu_initial_tmax(oz, idz, ijk_z, step_z, voxel_size)
    (ijk_x, ijk_y, ijk_z, step_x, step_y, step_z,
     tmax_x, tmax_y, tmax_z, tdelta_x, tdelta_y, tdelta_z)
end

"""Advance DDA by one cell. Returns (new ijk_x,y,z, new tmax_x,y,z)."""
@inline function _gpu_dda_step(
    ijk_x::Int32, ijk_y::Int32, ijk_z::Int32,
    step_x::Int32, step_y::Int32, step_z::Int32,
    tmax_x::Float32, tmax_y::Float32, tmax_z::Float32,
    tdelta_x::Float32, tdelta_y::Float32, tdelta_z::Float32)
    if tmax_x < tmax_y
        if tmax_x < tmax_z
            return (ijk_x + step_x, ijk_y, ijk_z, tmax_x + tdelta_x, tmax_y, tmax_z)
        else
            return (ijk_x, ijk_y, ijk_z + step_z, tmax_x, tmax_y, tmax_z + tdelta_z)
        end
    else
        if tmax_y < tmax_z
            return (ijk_x, ijk_y + step_y, ijk_z, tmax_x, tmax_y + tdelta_y, tmax_z)
        else
            return (ijk_x, ijk_y, ijk_z + step_z, tmax_x, tmax_y, tmax_z + tdelta_z)
        end
    end
end

"""Bounds check + child index for a DDA cell within a node."""
@inline function _gpu_node_query(ijk_x::Int32, ijk_y::Int32, ijk_z::Int32,
                                  orig_x::Int32, orig_y::Int32, orig_z::Int32,
                                  child_size::Int32, dim::Int32)
    lx = ijk_x - orig_x ÷ child_size
    ly = ijk_y - orig_y ÷ child_size
    lz = ijk_z - orig_z ÷ child_size
    inside = (Int32(0) <= lx) & (lx < dim) &
             (Int32(0) <= ly) & (ly < dim) &
             (Int32(0) <= lz) & (lz < dim)
    child_idx = lx * dim * dim + ly * dim + lz
    (inside, child_idx)
end

"""Cell exit time = min(tmax_x, tmax_y, tmax_z)."""
@inline _gpu_cell_time(tx::Float32, ty::Float32, tz::Float32) = min(tx, min(ty, tz))

# --- Root scanning ---

"""Access root slot by index (unrolled scalar storage)."""
@inline function _gpu_root_get(slot::Int32,
    t1::Float32, t2::Float32, t3::Float32, t4::Float32,
    o1::Int32, o2::Int32, o3::Int32, o4::Int32)
    slot == Int32(1) && return (t1, o1)
    slot == Int32(2) && return (t2, o2)
    slot == Int32(3) && return (t3, o3)
    return (t4, o4)
end

"""Scan root table, intersect ray with each I2 AABB, return sorted hits (max 4)."""
@inline function _gpu_collect_root_hits(buf,
    ox::Float32, oy::Float32, oz::Float32,
    idx::Float32, idy::Float32, idz::Float32,
    header_T_size::Int32)
    root_count = Int32(_gpu_buf_load(UInt32, buf, Int32(37) + header_T_size))
    root_pos   = Int32(_gpu_buf_load(UInt32, buf, Int32(53) + header_T_size))
    entry_sz   = Int32(13) + header_T_size

    # 4 slots (sufficient for nearly all grids — one root covers 4096³ voxels)
    n = Int32(0)
    t1 = Inf32; o1 = Int32(0)
    t2 = Inf32; o2 = Int32(0)
    t3 = Inf32; o3 = Int32(0)
    t4 = Inf32; o4 = Int32(0)

    @inbounds for i in Int32(0):(root_count - Int32(1))
        ep = root_pos + i * entry_sz
        is_child = _gpu_buf_load(UInt8, buf, ep + Int32(12))
        is_child == 0x01 || continue

        i2_off = Int32(_gpu_buf_load(UInt32, buf, ep + Int32(13)))
        orix = Float32(_gpu_buf_load(Int32, buf, i2_off))
        oriy = Float32(_gpu_buf_load(Int32, buf, i2_off + Int32(4)))
        oriz = Float32(_gpu_buf_load(Int32, buf, i2_off + Int32(8)))

        tmin, tmax = _gpu_ray_box_intersect(ox, oy, oz, idx, idy, idz,
            orix, oriy, oriz, orix + 4096.0f0, oriy + 4096.0f0, oriz + 4096.0f0)
        if tmin < tmax
            # Insertion sort into sorted slots
            if tmin < t4
                if tmin < t3
                    t4 = t3; o4 = o3
                    if tmin < t2
                        t3 = t2; o3 = o2
                        if tmin < t1
                            t2 = t1; o2 = o1
                            t1 = tmin; o1 = i2_off
                        else
                            t2 = tmin; o2 = i2_off
                        end
                    else
                        t3 = tmin; o3 = i2_off
                    end
                else
                    t4 = tmin; o4 = i2_off
                end
            end
            n = min(n + Int32(1), Int32(4))
        end
    end
    (n, t1, o1, t2, o2, t3, o3, t4, o4)
end

# --- Delta tracking within a single HDDA span ---

"""Run delta tracking within [t0, t1] with leaf caching. Returns (acc_r,g,b, throughput, rng, terminated, hit_x,y,z, cache_ox,oy,oz,off)."""
@inline function _gpu_integrate_span(
    buf, tf_lut,
    ox::Float32, oy::Float32, oz::Float32,
    dx::Float32, dy::Float32, dz::Float32,
    idx_r::Float32, idy_r::Float32, idz_r::Float32,
    t0::Float32, t1::Float32,
    background::Float32, header_T_size::Int32,
    sigma_maj::Float32, albedo::Float32, emission_scale::Float32, phase_g::Float32,
    tf_dmin::Float32, tf_dmax::Float32,
    light_buf, n_lights::Int32,
    bmin_x::Float32, bmin_y::Float32, bmin_z::Float32,
    bmax_x::Float32, bmax_y::Float32, bmax_z::Float32,
    acc_r::Float32, acc_g::Float32, acc_b::Float32,
    throughput::Float32, rng_state::UInt32,
    cache_ox::Int32, cache_oy::Int32, cache_oz::Int32, cache_off::Int32)

    terminated = false
    scattered = false
    hit_x = 0.0f0; hit_y = 0.0f0; hit_z = 0.0f0
    t = t0
    for _ in Int32(1):Int32(512)
        xi, rng_state = _gpu_xorshift(rng_state)
        xi = max(xi, 1.0f-10)
        t += -log(xi) / sigma_maj
        t >= t1 && break

        pos_x = ox + t * dx
        pos_y = oy + t * dy
        pos_z = oz + t * dz
        density, cache_ox, cache_oy, cache_oz, cache_off =
            _gpu_get_value_trilinear_cached(buf, background, pos_x, pos_y, pos_z,
                header_T_size, cache_ox, cache_oy, cache_oz, cache_off)
        density = max(0.0f0, density)

        accept_prob = density
        xi2, rng_state = _gpu_xorshift(rng_state)
        if xi2 < accept_prob
            tf_r, tf_g, tf_b, tf_a = _gpu_tf_lookup(tf_lut, density, tf_dmin, tf_dmax)
            xi3, rng_state = _gpu_xorshift(rng_state)
            if xi3 < albedo
                scattered = true
                # Scattering event — evaluate all lights with independent cache per light
                for li in Int32(1):n_lights
                    l_dx, l_dy, l_dz, l_r, l_g, l_b, l_dist =
                        _gpu_light_contribution(light_buf, li, pos_x, pos_y, pos_z)
                    shadow_ox = pos_x + 0.01f0 * l_dx
                    shadow_oy = pos_y + 0.01f0 * l_dy
                    shadow_oz = pos_z + 0.01f0 * l_dz
                    s_idx = l_dx == 0.0f0 ? copysign(Inf32, l_dx) : 1.0f0 / l_dx
                    s_idy = l_dy == 0.0f0 ? copysign(Inf32, l_dy) : 1.0f0 / l_dy
                    s_idz = l_dz == 0.0f0 ? copysign(Inf32, l_dz) : 1.0f0 / l_dz
                    st_enter, st_exit = _gpu_ray_box_intersect(
                        shadow_ox, shadow_oy, shadow_oz, s_idx, s_idy, s_idz,
                        bmin_x, bmin_y, bmin_z, bmax_x, bmax_y, bmax_z)
                    st_exit = min(st_exit, l_dist)
                    transmittance = 1.0f0
                    if st_enter < st_exit
                        sc_ox = Int32(0); sc_oy = Int32(0); sc_oz = Int32(0); sc_off = Int32(0)
                        st = st_enter
                        for _ in Int32(1):Int32(256)
                            xi_s, rng_state = _gpu_xorshift(rng_state)
                            xi_s = max(xi_s, 1.0f-10)
                            st += -log(xi_s) / sigma_maj
                            st >= st_exit && break
                            sd, sc_ox, sc_oy, sc_oz, sc_off =
                                _gpu_get_value_trilinear_cached(buf, background,
                                    shadow_ox + st * l_dx, shadow_oy + st * l_dy,
                                    shadow_oz + st * l_dz, header_T_size,
                                    sc_ox, sc_oy, sc_oz, sc_off)
                            sd = max(0.0f0, sd)
                            transmittance *= (1.0f0 - sd)
                            transmittance < 1.0f-10 && break
                        end
                    end
                    cos_theta = dx * l_dx + dy * l_dy + dz * l_dz
                    phase = _gpu_hg_eval(phase_g, cos_theta)
                    scale = throughput * transmittance * phase * emission_scale
                    acc_r += tf_r * l_r * scale
                    acc_g += tf_g * l_g * scale
                    acc_b += tf_b * l_b * scale
                end
            end
            hit_x = pos_x; hit_y = pos_y; hit_z = pos_z
            terminated = true
            break
        end
    end
    (acc_r, acc_g, acc_b, throughput, rng_state, terminated, scattered,
     hit_x, hit_y, hit_z,
     cache_ox, cache_oy, cache_oz, cache_off)
end

# --- Main HDDA traversal ---

"""
    _gpu_hdda_delta_track(...)

Combined HDDA traversal + delta tracking. Walks Root→I2→I1 via DDA,
merges adjacent active cells into spans, runs delta tracking only within
active spans. Skips ~97% of empty space on sparse grids.
"""
@inline function _gpu_hdda_delta_track(
    buf, tf_lut,
    ox::Float32, oy::Float32, oz::Float32,
    dx::Float32, dy::Float32, dz::Float32,
    idx_r::Float32, idy_r::Float32, idz_r::Float32,
    background::Float32, header_T_size::Int32,
    sigma_maj::Float32, albedo::Float32, emission_scale::Float32, phase_g::Float32,
    tf_dmin::Float32, tf_dmax::Float32,
    light_buf, n_lights::Int32,
    bmin_x::Float32, bmin_y::Float32, bmin_z::Float32,
    bmax_x::Float32, bmax_y::Float32, bmax_z::Float32,
    rng_state::UInt32)

    acc_r = 0.0f0; acc_g = 0.0f0; acc_b = 0.0f0
    throughput = 1.0f0
    hit_x = 0.0f0; hit_y = 0.0f0; hit_z = 0.0f0
    # Per-ray leaf cache (persists across spans for spatial coherence)
    cache_ox = Int32(0); cache_oy = Int32(0); cache_oz = Int32(0); cache_off = Int32(0)

    # Phase 0: collect root hits
    n_roots, rt1, ro1, rt2, ro2, rt3, ro3, rt4, ro4 =
        _gpu_collect_root_hits(buf, ox, oy, oz, idx_r, idy_r, idz_r, header_T_size)
    n_roots == Int32(0) && return (acc_r, acc_g, acc_b, rng_state, false, hit_x, hit_y, hit_z)

    span_t0 = -1.0f0  # no open span

    for ri in Int32(1):n_roots
        r_tmin, i2_off = _gpu_root_get(ri, rt1, rt2, rt3, rt4, ro1, ro2, ro3, ro4)
        isinf(r_tmin) && break

        i2_orig_x = _gpu_buf_load(Int32, buf, i2_off)
        i2_orig_y = _gpu_buf_load(Int32, buf, i2_off + Int32(4))
        i2_orig_z = _gpu_buf_load(Int32, buf, i2_off + Int32(8))

        # I2 DDA init (stride 128, dim 32)
        i2_ijk_x, i2_ijk_y, i2_ijk_z, i2_step_x, i2_step_y, i2_step_z,
        i2_tmax_x, i2_tmax_y, i2_tmax_z, i2_td_x, i2_td_y, i2_td_z =
            _gpu_dda_init(ox, oy, oz, dx, dy, dz, idx_r, idy_r, idz_r, r_tmin, 128.0f0)
        i2_t_entry = r_tmin

        for _ in Int32(1):Int32(32768)  # 32³ max
            i2_inside, i2_cidx = _gpu_node_query(i2_ijk_x, i2_ijk_y, i2_ijk_z,
                i2_orig_x, i2_orig_y, i2_orig_z, Int32(128), Int32(32))
            !i2_inside && break

            i2_has_child = _gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_CMASK_OFF), i2_cidx)

            if i2_has_child
                # Descend to I1
                tidx = _gpu_buf_count_on_before(buf,
                    i2_off + Int32(_I2_CMASK_OFF), i2_off + Int32(_I2_CPREFIX_OFF), i2_cidx)
                i1_off = Int32(_gpu_buf_load(UInt32, buf,
                    i2_off + Int32(_I2_DATA_OFF) + tidx * Int32(4)))

                i1_orig_x = _gpu_buf_load(Int32, buf, i1_off)
                i1_orig_y = _gpu_buf_load(Int32, buf, i1_off + Int32(4))
                i1_orig_z = _gpu_buf_load(Int32, buf, i1_off + Int32(8))

                # Ray-AABB test for I1 (128 voxels per axis)
                i1_tmin, i1_tmax = _gpu_ray_box_intersect(ox, oy, oz, idx_r, idy_r, idz_r,
                    Float32(i1_orig_x), Float32(i1_orig_y), Float32(i1_orig_z),
                    Float32(i1_orig_x) + 128.0f0, Float32(i1_orig_y) + 128.0f0,
                    Float32(i1_orig_z) + 128.0f0)

                if i1_tmin < i1_tmax
                    # I1 DDA init (stride 8, dim 16)
                    i1_ijk_x, i1_ijk_y, i1_ijk_z, i1_step_x, i1_step_y, i1_step_z,
                    i1_tmax_x, i1_tmax_y, i1_tmax_z, i1_td_x, i1_td_y, i1_td_z =
                        _gpu_dda_init(ox, oy, oz, dx, dy, dz, idx_r, idy_r, idz_r,
                            i1_tmin, 8.0f0)
                    i1_t_entry = i1_tmin

                    for _ in Int32(1):Int32(4096)  # 16³ max
                        i1_inside, i1_cidx = _gpu_node_query(i1_ijk_x, i1_ijk_y, i1_ijk_z,
                            i1_orig_x, i1_orig_y, i1_orig_z, Int32(8), Int32(16))
                        !i1_inside && break

                        i1_active = _gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_CMASK_OFF), i1_cidx) ||
                                    _gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_VMASK_OFF), i1_cidx)

                        if i1_active
                            # Open or extend span
                            if span_t0 < 0.0f0
                                span_t0 = i1_t_entry
                            end
                        elseif span_t0 >= 0.0f0
                            # Close span and integrate
                            acc_r, acc_g, acc_b, throughput, rng_state, terminated, scattered,
                                    hit_x, hit_y, hit_z,
                                    cache_ox, cache_oy, cache_oz, cache_off =
                                _gpu_integrate_span(buf, tf_lut, ox, oy, oz, dx, dy, dz,
                                    idx_r, idy_r, idz_r, span_t0, i1_t_entry,
                                    background, header_T_size, sigma_maj, albedo, emission_scale, phase_g,
                                    tf_dmin, tf_dmax, light_buf, n_lights,
                                    bmin_x, bmin_y, bmin_z, bmax_x, bmax_y, bmax_z,
                                    acc_r, acc_g, acc_b, throughput, rng_state,
                                    cache_ox, cache_oy, cache_oz, cache_off)
                            span_t0 = -1.0f0
                            terminated && return (acc_r, acc_g, acc_b, rng_state, scattered, hit_x, hit_y, hit_z)
                        end

                        i1_t_entry = _gpu_cell_time(i1_tmax_x, i1_tmax_y, i1_tmax_z)
                        i1_ijk_x, i1_ijk_y, i1_ijk_z, i1_tmax_x, i1_tmax_y, i1_tmax_z =
                            _gpu_dda_step(i1_ijk_x, i1_ijk_y, i1_ijk_z,
                                i1_step_x, i1_step_y, i1_step_z,
                                i1_tmax_x, i1_tmax_y, i1_tmax_z,
                                i1_td_x, i1_td_y, i1_td_z)
                    end
                    # I1 exhausted — span may stay open across I1 boundary
                else
                    # Ray misses I1 AABB — close span if open
                    if span_t0 >= 0.0f0
                        acc_r, acc_g, acc_b, throughput, rng_state, terminated, scattered,
                                hit_x, hit_y, hit_z,
                                cache_ox, cache_oy, cache_oz, cache_off =
                            _gpu_integrate_span(buf, tf_lut, ox, oy, oz, dx, dy, dz,
                                idx_r, idy_r, idz_r, span_t0, i2_t_entry,
                                background, header_T_size, sigma_maj, albedo, emission_scale, phase_g,
                                tf_dmin, tf_dmax, light_buf, n_lights,
                                bmin_x, bmin_y, bmin_z, bmax_x, bmax_y, bmax_z,
                                acc_r, acc_g, acc_b, throughput, rng_state,
                                cache_ox, cache_oy, cache_oz, cache_off)
                        span_t0 = -1.0f0
                        terminated && return (acc_r, acc_g, acc_b, rng_state, scattered, hit_x, hit_y, hit_z)
                    end
                end
            else
                # No child — check I2 tile
                i2_has_tile = _gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_VMASK_OFF), i2_cidx)
                if i2_has_tile
                    if span_t0 < 0.0f0
                        span_t0 = i2_t_entry
                    end
                elseif span_t0 >= 0.0f0
                    acc_r, acc_g, acc_b, throughput, rng_state, terminated, scattered,
                        hit_x, hit_y, hit_z,
                        cache_ox, cache_oy, cache_oz, cache_off =
                        _gpu_integrate_span(buf, tf_lut, ox, oy, oz, dx, dy, dz,
                            idx_r, idy_r, idz_r, span_t0, i2_t_entry,
                            background, header_T_size, sigma_maj, albedo, emission_scale, phase_g,
                            tf_dmin, tf_dmax, light_buf, n_lights,
                            bmin_x, bmin_y, bmin_z, bmax_x, bmax_y, bmax_z,
                            acc_r, acc_g, acc_b, throughput, rng_state,
                            cache_ox, cache_oy, cache_oz, cache_off)
                    span_t0 = -1.0f0
                    terminated && return (acc_r, acc_g, acc_b, rng_state, scattered, hit_x, hit_y, hit_z)
                end
            end

            i2_t_entry = _gpu_cell_time(i2_tmax_x, i2_tmax_y, i2_tmax_z)
            i2_ijk_x, i2_ijk_y, i2_ijk_z, i2_tmax_x, i2_tmax_y, i2_tmax_z =
                _gpu_dda_step(i2_ijk_x, i2_ijk_y, i2_ijk_z,
                    i2_step_x, i2_step_y, i2_step_z,
                    i2_tmax_x, i2_tmax_y, i2_tmax_z,
                    i2_td_x, i2_td_y, i2_td_z)
        end

        # Root entry exhausted — close any open span
        if span_t0 >= 0.0f0
            acc_r, acc_g, acc_b, throughput, rng_state, terminated, scattered,
                hit_x, hit_y, hit_z,
                cache_ox, cache_oy, cache_oz, cache_off =
                _gpu_integrate_span(buf, tf_lut, ox, oy, oz, dx, dy, dz,
                    idx_r, idy_r, idz_r, span_t0, i2_t_entry,
                    background, header_T_size, sigma_maj, albedo, emission_scale, phase_g,
                    tf_dmin, tf_dmax, light_buf, n_lights,
                    bmin_x, bmin_y, bmin_z, bmax_x, bmax_y, bmax_z,
                    acc_r, acc_g, acc_b, throughput, rng_state,
                    cache_ox, cache_oy, cache_oz, cache_off)
            span_t0 = -1.0f0
            terminated && return (acc_r, acc_g, acc_b, rng_state, scattered, hit_x, hit_y, hit_z)
        end
    end

    (acc_r, acc_g, acc_b, rng_state, false, hit_x, hit_y, hit_z)
end

# --- HDDA delta tracking kernel ---

"""GPU kernel with HDDA empty-space skipping. Same interface as delta_tracking_kernel!."""
@kernel function delta_tracking_hdda_kernel!(output, buf, tf_lut,
    background::Float32, sigma_maj::Float32, albedo::Float32, emission_scale::Float32, phase_g::Float32,
    cam_px::Float32, cam_py::Float32, cam_pz::Float32,
    cam_fx::Float32, cam_fy::Float32, cam_fz::Float32,
    cam_rx::Float32, cam_ry::Float32, cam_rz::Float32,
    cam_ux::Float32, cam_uy::Float32, cam_uz::Float32,
    cam_fov::Float32, width::Int32, height::Int32,
    bmin_x::Float32, bmin_y::Float32, bmin_z::Float32,
    bmax_x::Float32, bmax_y::Float32, bmax_z::Float32,
    light_buf, n_lights::Int32,
    tf_dmin::Float32, tf_dmax::Float32,
    header_T_size::Int32, seed::UInt32,
    max_bounces::Int32)

    idx = @index(Global, Linear)
    px = ((idx - Int32(1)) % width) + Int32(1)
    py = ((idx - Int32(1)) ÷ width) + Int32(1)
    rng_state = _gpu_wang_hash(_gpu_wang_hash(UInt32(idx)) ⊻ seed)
    jx, rng_state = _gpu_xorshift(rng_state)
    jy, rng_state = _gpu_xorshift(rng_state)
    u = (Float32(px) - 1.0f0 + jx) / Float32(width)
    v = 1.0f0 - (Float32(py) - 1.0f0 + jy) / Float32(height)
    aspect = Float32(width) / Float32(height)
    half_fov = tan(cam_fov * 0.5f0 * Float32(π) / 180.0f0)
    rpx = (2.0f0 * u - 1.0f0) * aspect * half_fov
    rpy = (2.0f0 * v - 1.0f0) * half_fov
    dx = cam_fx + cam_rx * rpx + cam_ux * rpy
    dy = cam_fy + cam_ry * rpx + cam_uy * rpy
    dz = cam_fz + cam_rz * rpx + cam_uz * rpy
    dlen = sqrt(dx * dx + dy * dy + dz * dz)
    dlen = max(dlen, 1.0f-10)
    dx /= dlen; dy /= dlen; dz /= dlen
    ray_ox = cam_px; ray_oy = cam_py; ray_oz = cam_pz
    acc_r = 0.0f0; acc_g = 0.0f0; acc_b = 0.0f0
    throughput = 1.0f0

    for bounce in Int32(0):max_bounces
        idx_r = dx == 0.0f0 ? copysign(Inf32, dx) : 1.0f0 / dx
        idy_r = dy == 0.0f0 ? copysign(Inf32, dy) : 1.0f0 / dy
        idz_r = dz == 0.0f0 ? copysign(Inf32, dz) : 1.0f0 / dz

        b_acc_r, b_acc_g, b_acc_b, rng_state, did_scatter, hx, hy, hz = _gpu_hdda_delta_track(
            buf, tf_lut, ray_ox, ray_oy, ray_oz, dx, dy, dz, idx_r, idy_r, idz_r,
            background, header_T_size, sigma_maj, albedo, emission_scale, phase_g,
            tf_dmin, tf_dmax, light_buf, n_lights,
            bmin_x, bmin_y, bmin_z, bmax_x, bmax_y, bmax_z, rng_state)

        acc_r += throughput * b_acc_r
        acc_g += throughput * b_acc_g
        acc_b += throughput * b_acc_b
        !did_scatter && break

        # Multi-bounce: sample new scatter direction, update ray
        throughput *= albedo
        dx, dy, dz, rng_state = _gpu_sample_scatter(dx, dy, dz, phase_g, rng_state)
        ray_ox = hx + 1.0f-4 * dx
        ray_oy = hy + 1.0f-4 * dy
        ray_oz = hz + 1.0f-4 * dz

        # Russian roulette after bounce 3
        if bounce >= Int32(3)
            rr_prob = clamp(throughput, 0.05f0, 1.0f0)
            xi_rr, rng_state = _gpu_xorshift(rng_state)
            xi_rr > rr_prob && break
            throughput /= rr_prob
        end
        throughput < 1.0f-10 && break
    end

    @inbounds output[idx] = (clamp(acc_r, 0.0f0, 1.0f0),
                              clamp(acc_g, 0.0f0, 1.0f0),
                              clamp(acc_b, 0.0f0, 1.0f0))
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

    # Scan all 512 values per leaf to find true min/max
    for i in 0:(lf_count - 1)
        base = leaf_pos + i * leaf_sz + _LEAF_VALUES_OFF
        for v in 0:511
            val = Float64(_buf_load(T, buf, base + v * sizeof(T)))
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
                       backend=_default_gpu_backend()) -> Matrix{NTuple{3, Float32}}

Render a volume using delta tracking on a KernelAbstractions backend.

Uses the first volume and first light from the scene. The transfer function
is pre-baked into a 256-entry LUT for device-side evaluation.

# Arguments
- `nanogrid` - NanoGrid to render (must be Float32 values)
- `scene` - Scene with camera, lights, and volume materials
- `width`, `height` - Image dimensions
- `spp` - Samples per pixel (accumulated with progressive averaging)
- `seed` - RNG seed
- `backend` - KernelAbstractions backend (default: auto-detected via `_default_gpu_backend()`)
"""
function gpu_render_volume(nanogrid::NanoGrid{T}, scene::Scene,
                            width::Int, height::Int;
                            spp::Int=1, seed::UInt64=UInt64(42),
                            backend=_default_gpu_backend(),
                            hdda::Bool=true,
                            max_bounces::Int=0) where T
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

    # Pack lights into flat buffer: 7 Float32 per light [type, x, y, z, r, g, b]
    light_data = Float32[]
    for light in scene.lights
        if light isa DirectionalLight
            push!(light_data, 0.0f0)  # type = directional
            push!(light_data, Float32.(light.direction)...)
            push!(light_data, Float32.(light.intensity)...)
        elseif light isa PointLight
            push!(light_data, 1.0f0)  # type = point
            push!(light_data, Float32.(light.position)...)
            push!(light_data, Float32.(light.intensity)...)
        end
        # Skip ConstantEnvironmentLight — contributes via ray escape, not direct lighting
    end
    n_lights = Int32(length(light_data) ÷ 7)
    if n_lights == Int32(0)
        # Fallback: default directional light
        light_data = Float32[0.0, 0.577, 0.577, 0.577, 1.0, 1.0, 1.0]
        n_lights = Int32(1)
    end

    background_f32 = Float32(nano_background(nanogrid))
    sigma_maj = Float32(mat.sigma_scale)
    albedo_f32 = Float32(mat.scattering_albedo)
    emission_f32 = Float32(mat.emission_scale)
    phase_g = mat.phase_function isa HenyeyGreensteinPhase ? Float32(mat.phase_function.g) : 0.0f0
    header_T_size = Int32(sizeof(T))
    w = Int32(width)
    h = Int32(height)

    # Adapt buffers for backend
    dev_buf = Adapt.adapt(backend, nanogrid.buffer)
    dev_tf = Adapt.adapt(backend, tf_lut)
    dev_lights = Adapt.adapt(backend, light_data)

    # Allocate output — use fill + adapt since NTuple has no zero() method
    npixels = width * height
    z3 = (0.0f0, 0.0f0, 0.0f0)
    output = Adapt.adapt(backend, fill(z3, npixels))

    # Progressive accumulation for multi-spp
    acc_buf = Adapt.adapt(backend, fill(z3, npixels))

    kernel! = hdda ? delta_tracking_hdda_kernel!(backend) : delta_tracking_kernel!(backend)

    for s in 1:spp
        kernel!(output, dev_buf, dev_tf,
                background_f32, sigma_maj, albedo_f32, emission_f32, phase_g,
                cam_px, cam_py, cam_pz,
                cam_fx, cam_fy, cam_fz,
                cam_rx, cam_ry, cam_rz,
                cam_ux, cam_uy, cam_uz,
                cam_fov,
                w, h,
                bmin_x, bmin_y, bmin_z,
                bmax_x, bmax_y, bmax_z,
                dev_lights, n_lights,
                Float32(dmin), Float32(dmax),
                header_T_size,
                UInt32(seed + UInt64(s)),
                Int32(max_bounces);
                ndrange=npixels)
        KernelAbstractions.synchronize(backend)

        # Accumulate on device
        acc_kernel! = _accumulate_kernel!(backend)
        acc_kernel!(acc_buf, output; ndrange=npixels)
        KernelAbstractions.synchronize(backend)
    end

    # Copy accumulated results to host, then reshape
    inv_spp = 1.0f0 / Float32(spp)
    host_buf = Array(acc_buf)  # device → host transfer
    result = Matrix{NTuple{3, Float32}}(undef, height, width)
    for i in 1:npixels
        r, g, b = host_buf[i]
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
    light_v = SVec3d(light_dir...)
    light_len = sqrt(light_v[1]^2 + light_v[2]^2 + light_v[3]^2)
    light = light_len > 1e-10 ? Tuple(light_v / light_len) : (0.0, 0.0, 1.0)

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
                          step_size=0.5, sigma_scale=1.0,
                          background=(0.0, 0.0, 0.0))

CPU fallback for GPU volume marching. Fixed-step emission-absorption
through NanoGrid with transfer function lookup.

!!! warning "Preview only"
    Uses biased fixed-step marching, not physically correct delta tracking.
    Use `gpu_render_volume` for production-quality renders.

# Keywords
- `background::NTuple{3,Float64}` — Scene background color blended where rays miss (default: black)
"""
function gpu_volume_march_cpu!(output::Matrix{NTuple{3, Float32}},
                                nanogrid::NanoGrid{T},
                                camera::Camera,
                                tf::Any,  # TransferFunction
                                width::Int, height::Int;
                                step_size::Float64=0.5,
                                sigma_scale::Float64=1.0,
                                background::NTuple{3,Float64}=(0.0, 0.0, 0.0)) where T
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

            hit = intersect_bbox(ray, bmin, bmax)

            acc_r = 0.0
            acc_g = 0.0
            acc_b = 0.0
            transmittance = 1.0

            if hit !== nothing
                t_enter, t_exit = hit
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
            acc_r += transmittance * background[1]
            acc_g += transmittance * background[2]
            acc_b += transmittance * background[3]

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

# ============================================================================
# GPU Geodesic Ray Tracing (General Relativity)
# ============================================================================

# --- Schwarzschild Hamiltonian RHS (scalar Float64) ---

"""Schwarzschild Hamiltonian RHS: returns (dx1..4, dp1..4) given position (x1..4) and momentum (p1..4)."""
@inline function _gpu_schwarzschild_rhs(M::Float64,
        x2::Float64, x3::Float64,  # r, θ (x1=t, x4=φ not needed)
        p1::Float64, p2::Float64, p3::Float64, p4::Float64)
    r = x2; θ = x3
    f = 1.0 - 2.0 * M / r
    r2 = r * r; r3 = r2 * r
    sin2θ = max(sin(θ)^2, 1e-6)
    inv_r2 = 1.0 / r2
    rs = 2.0 * M

    # dx/dλ = g^{μν} p_ν (diagonal metric)
    dx1 = (-1.0 / f) * p1
    dx2 = f * p2
    dx3 = inv_r2 * p3
    dx4 = (inv_r2 / sin2θ) * p4

    # dp_μ/dλ = -½ (∂g^{αβ}/∂x^μ) p_α p_β
    # dp1 = 0 (static), dp4 = 0 (axisymmetric)
    # dp2 = -½ [dgtt_dr p1² + dgrr_dr p2² + dgθθ_dr p3² + dgφφ_dr p4²]
    dgtt_dr = rs / (r2 * f * f)
    dgrr_dr = rs / r2
    dgθθ_dr = -2.0 / r3
    dgφφ_dr = -2.0 / (r3 * sin2θ)
    dp2 = -0.5 * (dgtt_dr * p1^2 + dgrr_dr * p2^2 + dgθθ_dr * p3^2 + dgφφ_dr * p4^2)

    # dp3: only g^{φφ} depends on θ
    sinθ = sin(θ); cosθ = cos(θ)
    sinθ_s = max(abs(sinθ), 1e-3) * (sinθ >= 0.0 ? 1.0 : -1.0)
    dgφφ_dθ = -2.0 * cosθ / (r2 * sinθ_s^3)
    dp3 = -0.5 * dgφφ_dθ * p4^2

    (dx1, dx2, dx3, dx4, 0.0, dp2, dp3, 0.0)
end

"""One RK4 step for Schwarzschild geodesic. Returns updated (x1..4, p1..4)."""
@inline function _gpu_schwarzschild_rk4(M::Float64, dl::Float64,
        x1::Float64, x2::Float64, x3::Float64, x4::Float64,
        p1::Float64, p2::Float64, p3::Float64, p4::Float64)
    # k1
    k1 = _gpu_schwarzschild_rhs(M, x2, x3, p1, p2, p3, p4)
    h = dl * 0.5
    # k2
    k2 = _gpu_schwarzschild_rhs(M, x2 + h*k1[2], x3 + h*k1[3],
        p1 + h*k1[5], p2 + h*k1[6], p3 + h*k1[7], p4 + h*k1[8])
    # k3
    k3 = _gpu_schwarzschild_rhs(M, x2 + h*k2[2], x3 + h*k2[3],
        p1 + h*k2[5], p2 + h*k2[6], p3 + h*k2[7], p4 + h*k2[8])
    # k4
    k4 = _gpu_schwarzschild_rhs(M, x2 + dl*k3[2], x3 + dl*k3[3],
        p1 + dl*k3[5], p2 + dl*k3[6], p3 + dl*k3[7], p4 + dl*k3[8])

    s = dl / 6.0
    (x1 + s*(k1[1] + 2*k2[1] + 2*k3[1] + k4[1]),
     x2 + s*(k1[2] + 2*k2[2] + 2*k3[2] + k4[2]),
     x3 + s*(k1[3] + 2*k2[3] + 2*k3[3] + k4[3]),
     x4 + s*(k1[4] + 2*k2[4] + 2*k3[4] + k4[4]),
     p1 + s*(k1[5] + 2*k2[5] + 2*k3[5] + k4[5]),
     p2 + s*(k1[6] + 2*k2[6] + 2*k3[6] + k4[6]),
     p3 + s*(k1[7] + 2*k2[7] + 2*k3[7] + k4[7]),
     p4 + s*(k1[8] + 2*k2[8] + 2*k3[8] + k4[8]))
end

"""Null cone renormalization for Schwarzschild: solve for p_t from g^{μν}p_μp_ν=0."""
@inline function _gpu_schwarzschild_renorm(M::Float64, r::Float64, θ::Float64,
        p1::Float64, p2::Float64, p3::Float64, p4::Float64)
    f = 1.0 - 2.0 * M / r
    inv_r2 = 1.0 / (r * r)
    sin2θ = max(sin(θ)^2, 1e-10)
    C = f * p2^2 + inv_r2 * p3^2 + (inv_r2 / sin2θ) * p4^2
    pt_mag = sqrt(max(C * f, 0.0))
    p1 < 0.0 ? -pt_mag : pt_mag
end

"""Adaptive step size: smaller near horizon (r=2M), full step in far field."""
@inline function _gpu_adaptive_step(dl_base::Float64, r::Float64, M::Float64)
    rh = 2.0 * M
    scale = clamp(((r - rh) / (6.0 * M))^2, 0.05, 1.0)
    dl_base * scale
end

"""Checkerboard sky pattern for escaped rays."""
@inline function _gpu_checkerboard(θ::Float64, φ::Float64)
    n_θ = floor(Int, θ * 10.0 / π)
    n_φ = floor(Int, φ * 10.0 / (2π))
    if (n_θ + n_φ) % 2 == 0
        (0.9, 0.9, 0.95)
    else
        (0.15, 0.15, 0.2)
    end
end

"""Simple blackbody color ramp for disk emission."""
@inline function _gpu_blackbody_color(T::Float64)
    T <= 0.0 && return (0.0, 0.0, 0.0)
    r = clamp(T / 0.5, 0.0, 1.0)
    g = clamp((T - 0.3) / 0.7, 0.0, 1.0)
    b = clamp((T - 0.7) / 0.5, 0.0, 1.0)
    (r, g, b)
end

# --- GPU Geodesic Kernel ---

"""GPU kernel for Schwarzschild geodesic ray tracing with thin disk."""
@kernel function gr_schwarzschild_kernel!(output,
    M::Float64,
    # Camera position (t, r, θ, φ)
    cam_r::Float64, cam_θ::Float64, cam_φ::Float64,
    cam_fov::Float64,
    # Image dims
    width::Int32, height::Int32,
    # Disk (inner=outer=0 for no disk)
    disk_inner::Float64, disk_outer::Float64,
    # Integration
    dl_base::Float64, max_steps::Int32, r_max::Float64,
    # Background (0=checkerboard, 1=black)
    bg_mode::Int32)

    idx = @index(Global, Linear)
    px = ((idx - Int32(1)) % width) + Int32(1)
    py = ((idx - Int32(1)) ÷ width) + Int32(1)

    aspect = Float64(width) / Float64(height)
    half_fov = tan(cam_fov * 0.5 * π / 180.0)

    u = (Float64(px) - 0.5) / Float64(width)
    v = 1.0 - (Float64(py) - 0.5) / Float64(height)
    rpx = (2.0 * u - 1.0) * aspect * half_fov
    rpy = (2.0 * v - 1.0) * half_fov

    # Camera direction in tetrad frame: forward=e1(radial), up=e2(polar), right=e3(azimuthal)
    n_norm = sqrt(1.0 + rpx^2 + rpy^2)
    nx = 1.0 / n_norm   # forward (toward BH)
    ny = rpy / n_norm    # up
    nz = rpx / n_norm    # right

    # Build Schwarzschild static observer tetrad at camera position
    f = 1.0 - 2.0 * M / cam_r
    sqrtf = sqrt(max(f, 1e-20))
    sinθ = sin(cam_θ)
    sinθ_s = max(abs(sinθ), 1e-3)

    # e0 = (1/√f, 0, 0, 0), e1 = (0, √f, 0, 0), e2 = (0, 0, 1/r, 0), e3 = (0, 0, 0, 1/(r sinθ))
    # k^μ = e0^μ + nx*e1^μ + ny*e2^μ + nz*e3^μ
    kt = 1.0 / sqrtf
    kr = nx * sqrtf
    kθ = ny / cam_r
    kφ = nz / (cam_r * sinθ_s)

    # Lower indices: p_μ = g_{μν} k^ν (diagonal Schwarzschild)
    p1 = -f * kt                    # p_t
    p2 = (1.0 / f) * kr             # p_r
    p3 = cam_r^2 * kθ               # p_θ
    p4 = cam_r^2 * sinθ^2 * kφ      # p_φ

    # Initial position
    x1 = 0.0; x2 = cam_r; x3 = cam_θ; x4 = cam_φ

    rh = 2.0 * M
    equator = π / 2.0
    has_disk = disk_inner > 0.0 && disk_outer > 0.0
    color_r = 0.0; color_g = 0.0; color_b = 0.0
    terminated = false

    for step in Int32(1):max_steps
        r = x2
        dl = _gpu_adaptive_step(dl_base, r, M)

        x2_prev = x2; x3_prev = x3
        x1, x2, x3, x4, p1, p2, p3, p4 =
            _gpu_schwarzschild_rk4(M, dl, x1, x2, x3, x4, p1, p2, p3, p4)

        # Renormalize every 50 steps
        if step % Int32(50) == Int32(0)
            p1 = _gpu_schwarzschild_renorm(M, x2, x3, p1, p2, p3, p4)
        end

        # Check disk crossing (θ crosses π/2)
        if has_disk && (x3_prev - equator) * (x3 - equator) < 0.0
            frac = (equator - x3_prev) / (x3 - x3_prev)
            r_cross = x2_prev + frac * (x2 - x2_prev)
            if disk_inner <= r_cross <= disk_outer
                intensity = (disk_inner / r_cross)^3
                color_r, color_g, color_b = _gpu_blackbody_color(clamp(intensity * 5.0, 0.0, 2.0))
                terminated = true
                break
            end
        end

        # Horizon
        if x2 <= rh * 1.01
            color_r = 0.0; color_g = 0.0; color_b = 0.0
            terminated = true
            break
        end

        # Escape
        if x2 >= r_max
            if bg_mode == Int32(0)
                color_r, color_g, color_b = _gpu_checkerboard(x3, x4)
            end
            terminated = true
            break
        end
    end

    @inbounds output[idx] = (color_r, color_g, color_b)
end

# --- GPU GR Render Dispatch ---

"""
    gpu_gr_render(metric, cam_position, cam_fov, width, height;
                  disk=nothing, max_steps=10000, step_size=-0.5,
                  r_max=200.0, background=:checkerboard,
                  backend=_default_gpu_backend()) -> Matrix{NTuple{3, Float64}}

Render a black hole scene using GPU-accelerated geodesic ray tracing.

Currently supports Schwarzschild metric with optional thin disk.
Uses Float64 precision for accurate geodesic integration.
"""
function gpu_gr_render(M::Float64, cam_r::Float64, cam_θ::Float64, cam_φ::Float64,
                        cam_fov::Float64, width::Int, height::Int;
                        disk_inner::Float64=0.0, disk_outer::Float64=0.0,
                        max_steps::Int=10000, step_size::Float64=-0.5,
                        r_max::Float64=200.0, background::Symbol=:checkerboard,
                        backend=_default_gpu_backend())
    npixels = width * height
    z3 = (0.0, 0.0, 0.0)
    output = Adapt.adapt(backend, fill(z3, npixels))

    bg_mode = background === :checkerboard ? Int32(0) : Int32(1)

    kernel! = gr_schwarzschild_kernel!(backend)
    kernel!(output, M,
            cam_r, cam_θ, cam_φ, cam_fov,
            Int32(width), Int32(height),
            disk_inner, disk_outer,
            step_size, Int32(max_steps), r_max,
            bg_mode;
            ndrange=npixels)
    KernelAbstractions.synchronize(backend)

    host_buf = Array(output)
    result = Matrix{NTuple{3, Float64}}(undef, height, width)
    for i in 1:npixels
        x = ((i - 1) % width) + 1
        y = ((i - 1) ÷ width) + 1
        result[y, x] = host_buf[i]
    end
    result
end
