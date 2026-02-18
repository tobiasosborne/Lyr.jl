# GPU.jl - GPU acceleration via KernelAbstractions.jl
#
# Provides GPU-compatible wrappers around NanoGrid operations
# and rendering kernels for level sets and fog volumes.
#
# Requires: KernelAbstractions.jl, Adapt.jl (optional GPU deps)
#
# Usage:
#   using Lyr, CUDA  # or Metal, AMDGPU, etc.
#   grid = build_nanogrid(vdb.grids[1].tree)
#   gpu_grid = adapt(CuArray, grid)  # transfer to GPU
#   img = gpu_render_sphere(gpu_grid, camera, 512, 512)

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
