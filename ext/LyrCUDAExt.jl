# ext/LyrCUDAExt.jl — CUDA backend for Lyr.jl
#
# Loaded automatically by Julia's Pkg system when both Lyr and CUDA are
# available. Sets the GPU backend to CUDABackend() and adds a dispatch
# method for gpu_info with CUDA device details.

module LyrCUDAExt

using Lyr
using CUDA
using CUDA: CuTexture, CuTextureArray, LinearInterpolation, ADDRESS_MODE_CLAMP
using KernelAbstractions

# Add dispatch method for CUDABackend (extends, not overwrites)
function Lyr._gpu_info(::CUDABackend)
    try
        dev = CUDA.device()
        return "GPU backend: CUDA ($(CUDA.name(dev)))"
    catch e
        return "GPU backend: CUDA (device query failed: $e)"
    end
end

function __init__()
    if CUDA.functional()
        Lyr._GPU_BACKEND[] = CUDABackend()
        try
            dev = CUDA.device()
            @info "Lyr CUDA extension loaded" device=CUDA.name(dev)
        catch
            @info "Lyr CUDA extension loaded (device query failed)"
        end
    else
        @warn "Lyr CUDA extension: CUDA.jl loaded but no functional GPU detected. Using CPU fallback."
    end
end

# ============================================================================
# CuTexture hardware-trilinear preview (E2 — bead path-tracer-kbhm)
# ============================================================================
#
# Wires `Lyr.gpu_render_volume_preview(..., use_texture=true)` to a fast path
# that replaces NanoVDB software trilinear with one hardware `tex[x,y,z]`
# fetch via CUDA.jl's `CuTexture{Float32,3} + LinearInterpolation`. Dense-
# only — densifies the NanoVDB grid into a CuTextureArray on first call.
# No HDDA: a dense texture has no empty-space skipping to do.
#
# Feasibility + API details: docs/stocktake/10_cutexture_feasibility.md

"Soft ceiling for the dense-volume size we're willing to upload. 512 MB of
Float32 = 512³ voxels. Configurable via ENV[\"LYR_TEXTURE_CEILING_MB\"]."
function _texture_ceiling_bytes()
    mb = get(ENV, "LYR_TEXTURE_CEILING_MB", "512")
    parsed = tryparse(Int, mb)
    (parsed === nothing ? 512 : parsed) * 1024 * 1024
end

# Populate a dense CuArray from NanoVDB via one _gpu_get_value per voxel.
# Reuses the existing NanoVDB byte-buffer traversal (stable device-side API
# `Lyr._gpu_get_value`) so the texture path shares correctness guarantees
# with the NanoVDB path.
@kernel function _dense_fill_kernel!(dense,
                                      buf,
                                      orig_x::Int32, orig_y::Int32, orig_z::Int32,
                                      bg::Float32,
                                      header_T_size::Int32)
    i, j, k = @index(Global, NTuple)
    cx = orig_x + Int32(i) - Int32(1)
    cy = orig_y + Int32(j) - Int32(1)
    cz = orig_z + Int32(k) - Int32(1)
    @inbounds dense[i, j, k] = Lyr._gpu_get_value(buf, bg, cx, cy, cz, header_T_size)
end

# Fixed-step Beer-Lambert EA through a 3D texture. One workitem = one pixel.
# Mirrors `Lyr.fixed_step_ea_kernel!` but swaps the NanoVDB HDDA+trilinear
# for a straight AABB march with a single `tex[x,y,z]` per step. The
# pixel/ray setup and compositing math are identical (deterministic, no
# jitter, so PSNR vs NanoVDB path is bounded only by texture-unit 9-bit
# fraction precision — docs/stocktake/10_cutexture_feasibility.md §9).
@kernel function _fixed_step_ea_texture_kernel!(output,
    tex,
    tf_lut,
    sigma_scale::Float32, emission_scale::Float32, step_size::Float32,
    cam_px::Float32, cam_py::Float32, cam_pz::Float32,
    cam_fx::Float32, cam_fy::Float32, cam_fz::Float32,
    cam_rx::Float32, cam_ry::Float32, cam_rz::Float32,
    cam_ux::Float32, cam_uy::Float32, cam_uz::Float32,
    cam_fov::Float32, width::Int32, height::Int32,
    bmin_x::Float32, bmin_y::Float32, bmin_z::Float32,
    bmax_x::Float32, bmax_y::Float32, bmax_z::Float32,
    bg_r::Float32, bg_g::Float32, bg_b::Float32,
    tf_dmin::Float32, tf_dmax::Float32,
    orig_x::Int32, orig_y::Int32, orig_z::Int32,
    max_steps::Int32)

    idx = @index(Global, Linear)
    px = ((idx - Int32(1)) % width) + Int32(1)
    py = ((idx - Int32(1)) ÷ width) + Int32(1)
    u = (Float32(px) - 0.5f0) / Float32(width)
    v = 1.0f0 - (Float32(py) - 0.5f0) / Float32(height)
    aspect = Float32(width) / Float32(height)
    half_fov = tan(cam_fov * 0.5f0 * Float32(π) / 180.0f0)
    rpx = (2.0f0 * u - 1.0f0) * aspect * half_fov
    rpy = (2.0f0 * v - 1.0f0) * half_fov
    dx = cam_fx + cam_rx * rpx + cam_ux * rpy
    dy = cam_fy + cam_ry * rpx + cam_uy * rpy
    dz = cam_fz + cam_rz * rpx + cam_uz * rpy
    dlen = sqrt(dx*dx + dy*dy + dz*dz)
    dlen = max(dlen, 1.0f-10)
    dx /= dlen; dy /= dlen; dz /= dlen
    idx_r = dx == 0.0f0 ? copysign(Inf32, dx) : 1.0f0 / dx
    idy_r = dy == 0.0f0 ? copysign(Inf32, dy) : 1.0f0 / dy
    idz_r = dz == 0.0f0 ? copysign(Inf32, dz) : 1.0f0 / dz

    t_enter, t_exit = Lyr._gpu_ray_box_intersect(cam_px, cam_py, cam_pz,
        idx_r, idy_r, idz_r, bmin_x, bmin_y, bmin_z, bmax_x, bmax_y, bmax_z)

    acc_r = 0.0f0; acc_g = 0.0f0; acc_b = 0.0f0; transmittance = 1.0f0
    if t_enter < t_exit
        t = t_enter
        steps = max_steps
        @inbounds while t < t_exit && transmittance > 1.0f-4 && steps > Int32(0)
            pos_x = cam_px + t * dx
            pos_y = cam_py + t * dy
            pos_z = cam_pz + t * dz
            # World voxel coord → dense-buffer coord (1-based, voxel-center
            # aligned). Julia device getindex subtracts 0.5 before calling the
            # NVVM tex intrinsic, so `tex[1, 1, 1]` fetches the texel stored
            # at dense[1, 1, 1] = voxel at (orig.x, orig.y, orig.z).
            lx = pos_x - Float32(orig_x) + 1.0f0
            ly = pos_y - Float32(orig_y) + 1.0f0
            lz = pos_z - Float32(orig_z) + 1.0f0
            density = tex[lx, ly, lz]
            density = max(0.0f0, density)
            if density > 1.0f-6
                tf_r, tf_g, tf_b, tf_a = Lyr._gpu_tf_lookup_lerp(
                    tf_lut, density, tf_dmin, tf_dmax)
                sigma_t = tf_a * sigma_scale * step_size
                step_T = exp(-sigma_t)
                emit = (1.0f0 - step_T) * emission_scale
                acc_r += transmittance * tf_r * emit
                acc_g += transmittance * tf_g * emit
                acc_b += transmittance * tf_b * emit
                transmittance *= step_T
            end
            t += step_size
            steps -= Int32(1)
        end
    end

    acc_r += transmittance * bg_r
    acc_g += transmittance * bg_g
    acc_b += transmittance * bg_b

    @inbounds output[idx] = (clamp(acc_r, 0.0f0, 1.0f0),
                              clamp(acc_g, 0.0f0, 1.0f0),
                              clamp(acc_b, 0.0f0, 1.0f0))
end

"""Densify NanoGrid into a CuTextureArray + bind a CuTexture. Caller must
keep the returned `CuTextureArray` alive for the duration of any sample —
dropping it invalidates the texture handle."""
function _build_dense_volume_texture(nanogrid::Lyr.NanoGrid{Float32})
    bbox = Lyr.nano_bbox(nanogrid)
    nx = Int(bbox.max.x - bbox.min.x + 1)
    ny = Int(bbox.max.y - bbox.min.y + 1)
    nz = Int(bbox.max.z - bbox.min.z + 1)

    dev_buf = CuArray(nanogrid.buffer)
    dense = CuArray{Float32, 3}(undef, nx, ny, nz)

    fill_kernel! = _dense_fill_kernel!(CUDABackend())
    fill_kernel!(dense, dev_buf,
                 Int32(bbox.min.x), Int32(bbox.min.y), Int32(bbox.min.z),
                 Float32(Lyr.nano_background(nanogrid)),
                 Int32(sizeof(Float32));
                 ndrange=(nx, ny, nz))
    CUDA.synchronize()

    tex_arr = CuTextureArray(dense)
    CUDA.unsafe_free!(dense)

    tex = CuTexture(tex_arr;
                    address_mode=ADDRESS_MODE_CLAMP,
                    interpolation=LinearInterpolation(),
                    normalized_coordinates=false)
    (tex, tex_arr, (nx, ny, nz),
     (Int32(bbox.min.x), Int32(bbox.min.y), Int32(bbox.min.z)),
     (Float32(bbox.min.x), Float32(bbox.min.y), Float32(bbox.min.z),
      Float32(bbox.max.x + 1), Float32(bbox.max.y + 1), Float32(bbox.max.z + 1)))
end

"""CuTexture-backed GPU preview renderer. Extends the stub in src/GPU.jl;
called from `gpu_render_volume_preview(..., use_texture=:auto|true)` when
CUDA is available. Returns `nothing` when the fast path is unavailable
(wrong backend, or dense size above the ceiling) and the caller should fall
back to NanoVDB — unless `use_texture_mode === :force`, in which case throw
instead."""
function Lyr._gpu_preview_texture_try(nanogrid::Lyr.NanoGrid{Float32},
                                        scene::Lyr.Scene,
                                        width::Int, height::Int;
                                        step_size::Float32,
                                        max_steps::Int,
                                        backend,
                                        use_texture_mode::Symbol)

    if !(backend isa CUDABackend)
        use_texture_mode === :force && error(
            "use_texture=true but backend is $(typeof(backend)); " *
            "the CuTexture path is CUDA-only.")
        return nothing
    end

    bbox = Lyr.nano_bbox(nanogrid)
    nx = Int(bbox.max.x - bbox.min.x + 1)
    ny = Int(bbox.max.y - bbox.min.y + 1)
    nz = Int(bbox.max.z - bbox.min.z + 1)
    dense_bytes = nx * ny * nz * sizeof(Float32)
    ceiling = _texture_ceiling_bytes()
    if dense_bytes > ceiling
        if use_texture_mode === :force
            error("use_texture=true but dense volume is $(round(dense_bytes / 1024^2; digits=1)) MB " *
                  "> ceiling $(ceiling ÷ 1024^2) MB. " *
                  "Raise via ENV[\"LYR_TEXTURE_CEILING_MB\"], or use_texture=false.")
        end
        return nothing
    end

    # Per E1 §5.2, level-set grids need a special border story; for the EA
    # preview path with a fog (non-negative density) volume this isn't a
    # concern, but we still only allow Float32 fog through. The nanogrid
    # eltype is already Float32 by the method signature above.

    tex, tex_arr, _dims, origin, float_bbox =
        _build_dense_volume_texture(nanogrid)

    vol = scene.volumes[1]
    mat = vol.material
    cam = scene.camera

    dmin, dmax = Lyr._estimate_density_range(nanogrid)
    dmin == dmax && (dmax = dmin + 1.0)
    tf_lut_host = Lyr._bake_tf_lut(mat.transfer_function, dmin, dmax)
    tf_lut_dev  = CuArray(tf_lut_host)

    bg = Lyr._escape_radiance(scene)

    cam_px, cam_py, cam_pz = Float32.(cam.position)
    cam_fx, cam_fy, cam_fz = Float32.(cam.forward)
    cam_rx, cam_ry, cam_rz = Float32.(cam.right)
    cam_ux, cam_uy, cam_uz = Float32.(cam.up)

    w = Int32(width); h = Int32(height)
    npixels = width * height
    z3 = (0.0f0, 0.0f0, 0.0f0)
    output = CuArray(fill(z3, npixels))

    # GC.@preserve: CuDeviceTexture holds only `dims` and `handle`, not a
    # reference back to the parent CuTextureArray. Dropping tex_arr
    # finalises the array and invalidates the texture handle, which would
    # corrupt the in-flight kernel. Synchronize before letting either go
    # out of scope.
    GC.@preserve tex tex_arr tf_lut_dev output begin
        kernel! = _fixed_step_ea_texture_kernel!(CUDABackend())
        kernel!(output, tex, tf_lut_dev,
                Float32(mat.sigma_scale), Float32(mat.emission_scale), step_size,
                cam_px, cam_py, cam_pz,
                cam_fx, cam_fy, cam_fz,
                cam_rx, cam_ry, cam_rz,
                cam_ux, cam_uy, cam_uz,
                Float32(cam.fov), w, h,
                float_bbox[1], float_bbox[2], float_bbox[3],
                float_bbox[4], float_bbox[5], float_bbox[6],
                Float32(bg[1]), Float32(bg[2]), Float32(bg[3]),
                Float32(dmin), Float32(dmax),
                origin[1], origin[2], origin[3],
                Int32(max_steps);
                ndrange=npixels)
        CUDA.synchronize()

        host_buf = Array(output)
        result = Matrix{NTuple{3, Float32}}(undef, height, width)
        for i in 1:npixels
            x = ((i - 1) % width) + 1
            y = ((i - 1) ÷ width) + 1
            result[y, x] = host_buf[i]
        end
        return result
    end
end

end # module LyrCUDAExt
