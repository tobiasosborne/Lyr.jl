# Diagnostic test: CPU emulation of GPU HDDA span collection
# Compares spans from GPU HDDA logic (Float32) against CPU reference (Float64)
# to find the root cause of bug fjo9 (3.5x dimmer HDDA output)

using Test
using Lyr
using Lyr: coord, Coord, SVec3d, Ray, build_nanogrid, build_grid,
           NanoVolumeHDDA, TimeSpan, nano_bbox, nano_background,
           _nano_root_pos, nano_root_count, _root_entry_size,
           _I2_CMASK_OFF, _I2_CPREFIX_OFF, _I2_VMASK_OFF, _I2_DATA_OFF,
           _I1_CMASK_OFF, _I1_VMASK_OFF,
           foreach_hdda_span

# Import GPU helper functions (pure Julia, CPU-callable)
using Lyr: _gpu_safe_floor_i32, _gpu_initial_tmax, _gpu_dda_init, _gpu_dda_step,
           _gpu_node_query, _gpu_cell_time, _gpu_buf_load, _gpu_buf_mask_is_on,
           _gpu_buf_count_on_before, _gpu_collect_root_hits, _gpu_root_get,
           _gpu_ray_box_intersect

# ── CPU emulation of _gpu_hdda_delta_track (span collection only) ──────────

"""
    emulate_gpu_hdda_spans(buf, ox, oy, oz, dx, dy, dz, header_T_size) -> Vector{Tuple{Float32,Float32}}

CPU emulation of the GPU HDDA span collection. Exactly mirrors _gpu_hdda_delta_track
(GPU.jl:977-1152) but records spans instead of integrating them.
Uses Float32 arithmetic throughout, same as the GPU kernel.
"""
function emulate_gpu_hdda_spans(buf::Vector{UInt8},
        ox::Float32, oy::Float32, oz::Float32,
        dx::Float32, dy::Float32, dz::Float32,
        header_T_size::Int32)

    spans = Tuple{Float32, Float32}[]

    idx_r = dx == 0.0f0 ? copysign(Inf32, dx) : 1.0f0 / dx
    idy_r = dy == 0.0f0 ? copysign(Inf32, dy) : 1.0f0 / dy
    idz_r = dz == 0.0f0 ? copysign(Inf32, dz) : 1.0f0 / dz

    # Phase 0: collect root hits
    n_roots, rt1, ro1, rt2, ro2, rt3, ro3, rt4, ro4 =
        _gpu_collect_root_hits(buf, ox, oy, oz, idx_r, idy_r, idz_r, header_T_size)
    n_roots == Int32(0) && return spans

    span_t0 = -1.0f0

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

        for _ in Int32(1):Int32(32768)
            i2_inside, i2_cidx = _gpu_node_query(i2_ijk_x, i2_ijk_y, i2_ijk_z,
                i2_orig_x, i2_orig_y, i2_orig_z, Int32(128), Int32(32))
            !i2_inside && break

            i2_has_child = _gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_CMASK_OFF), i2_cidx)

            if i2_has_child
                tidx = _gpu_buf_count_on_before(buf,
                    i2_off + Int32(_I2_CMASK_OFF), i2_off + Int32(_I2_CPREFIX_OFF), i2_cidx)
                i1_off = Int32(_gpu_buf_load(UInt32, buf,
                    i2_off + Int32(_I2_DATA_OFF) + tidx * Int32(4)))

                i1_orig_x = _gpu_buf_load(Int32, buf, i1_off)
                i1_orig_y = _gpu_buf_load(Int32, buf, i1_off + Int32(4))
                i1_orig_z = _gpu_buf_load(Int32, buf, i1_off + Int32(8))

                i1_tmin, i1_tmax = _gpu_ray_box_intersect(ox, oy, oz, idx_r, idy_r, idz_r,
                    Float32(i1_orig_x), Float32(i1_orig_y), Float32(i1_orig_z),
                    Float32(i1_orig_x) + 128.0f0, Float32(i1_orig_y) + 128.0f0,
                    Float32(i1_orig_z) + 128.0f0)

                if i1_tmin < i1_tmax
                    i1_ijk_x, i1_ijk_y, i1_ijk_z, i1_step_x, i1_step_y, i1_step_z,
                    i1_tmax_x, i1_tmax_y, i1_tmax_z, i1_td_x, i1_td_y, i1_td_z =
                        _gpu_dda_init(ox, oy, oz, dx, dy, dz, idx_r, idy_r, idz_r,
                            i1_tmin, 8.0f0)
                    i1_t_entry = i1_tmin

                    for _ in Int32(1):Int32(4096)
                        i1_inside, i1_cidx = _gpu_node_query(i1_ijk_x, i1_ijk_y, i1_ijk_z,
                            i1_orig_x, i1_orig_y, i1_orig_z, Int32(8), Int32(16))
                        !i1_inside && break

                        i1_active = _gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_CMASK_OFF), i1_cidx) ||
                                    _gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_VMASK_OFF), i1_cidx)

                        if i1_active
                            if span_t0 < 0.0f0
                                span_t0 = i1_t_entry
                            end
                        elseif span_t0 >= 0.0f0
                            push!(spans, (span_t0, i1_t_entry))
                            span_t0 = -1.0f0
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
                    if span_t0 >= 0.0f0
                        push!(spans, (span_t0, i2_t_entry))
                        span_t0 = -1.0f0
                    end
                end
            else
                i2_has_tile = _gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_VMASK_OFF), i2_cidx)
                if i2_has_tile
                    if span_t0 < 0.0f0
                        span_t0 = i2_t_entry
                    end
                elseif span_t0 >= 0.0f0
                    push!(spans, (span_t0, i2_t_entry))
                    span_t0 = -1.0f0
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
            push!(spans, (span_t0, i2_t_entry))
            span_t0 = -1.0f0
        end
    end

    spans
end

# ── Verbose version with per-cell logging ──────────────────────────────────

function emulate_gpu_hdda_spans_verbose(buf::Vector{UInt8},
        ox::Float32, oy::Float32, oz::Float32,
        dx::Float32, dy::Float32, dz::Float32,
        header_T_size::Int32)

    spans = Tuple{Float32, Float32}[]
    log = String[]

    idx_r = dx == 0.0f0 ? copysign(Inf32, dx) : 1.0f0 / dx
    idy_r = dy == 0.0f0 ? copysign(Inf32, dy) : 1.0f0 / dy
    idz_r = dz == 0.0f0 ? copysign(Inf32, dz) : 1.0f0 / dz

    n_roots, rt1, ro1, rt2, ro2, rt3, ro3, rt4, ro4 =
        _gpu_collect_root_hits(buf, ox, oy, oz, idx_r, idy_r, idz_r, header_T_size)
    push!(log, "roots: $n_roots")
    n_roots == Int32(0) && return spans, log

    span_t0 = -1.0f0

    for ri in Int32(1):n_roots
        r_tmin, i2_off = _gpu_root_get(ri, rt1, rt2, rt3, rt4, ro1, ro2, ro3, ro4)
        isinf(r_tmin) && break
        push!(log, "  root[$ri] tmin=$r_tmin off=$i2_off")

        i2_orig_x = _gpu_buf_load(Int32, buf, i2_off)
        i2_orig_y = _gpu_buf_load(Int32, buf, i2_off + Int32(4))
        i2_orig_z = _gpu_buf_load(Int32, buf, i2_off + Int32(8))
        push!(log, "  i2_orig=($i2_orig_x,$i2_orig_y,$i2_orig_z)")

        i2_ijk_x, i2_ijk_y, i2_ijk_z, i2_step_x, i2_step_y, i2_step_z,
        i2_tmax_x, i2_tmax_y, i2_tmax_z, i2_td_x, i2_td_y, i2_td_z =
            _gpu_dda_init(ox, oy, oz, dx, dy, dz, idx_r, idy_r, idz_r, r_tmin, 128.0f0)
        i2_t_entry = r_tmin

        i2_iter = 0
        for _ in Int32(1):Int32(32768)
            i2_iter += 1
            i2_inside, i2_cidx = _gpu_node_query(i2_ijk_x, i2_ijk_y, i2_ijk_z,
                i2_orig_x, i2_orig_y, i2_orig_z, Int32(128), Int32(32))
            if !i2_inside
                push!(log, "    i2[$i2_iter] ijk=($i2_ijk_x,$i2_ijk_y,$i2_ijk_z) OUTSIDE")
                break
            end

            i2_has_child = _gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_CMASK_OFF), i2_cidx)
            push!(log, "    i2[$i2_iter] ijk=($i2_ijk_x,$i2_ijk_y,$i2_ijk_z) cidx=$i2_cidx child=$i2_has_child t_entry=$i2_t_entry")

            if i2_has_child
                tidx = _gpu_buf_count_on_before(buf,
                    i2_off + Int32(_I2_CMASK_OFF), i2_off + Int32(_I2_CPREFIX_OFF), i2_cidx)
                i1_off = Int32(_gpu_buf_load(UInt32, buf,
                    i2_off + Int32(_I2_DATA_OFF) + tidx * Int32(4)))

                i1_orig_x = _gpu_buf_load(Int32, buf, i1_off)
                i1_orig_y = _gpu_buf_load(Int32, buf, i1_off + Int32(4))
                i1_orig_z = _gpu_buf_load(Int32, buf, i1_off + Int32(8))

                i1_tmin, i1_tmax = _gpu_ray_box_intersect(ox, oy, oz, idx_r, idy_r, idz_r,
                    Float32(i1_orig_x), Float32(i1_orig_y), Float32(i1_orig_z),
                    Float32(i1_orig_x) + 128.0f0, Float32(i1_orig_y) + 128.0f0,
                    Float32(i1_orig_z) + 128.0f0)
                push!(log, "      i1_orig=($i1_orig_x,$i1_orig_y,$i1_orig_z) aabb_hit=$(i1_tmin < i1_tmax) tmin=$i1_tmin tmax=$i1_tmax")

                if i1_tmin < i1_tmax
                    i1_ijk_x, i1_ijk_y, i1_ijk_z, i1_step_x, i1_step_y, i1_step_z,
                    i1_tmax_x, i1_tmax_y, i1_tmax_z, i1_td_x, i1_td_y, i1_td_z =
                        _gpu_dda_init(ox, oy, oz, dx, dy, dz, idx_r, idy_r, idz_r,
                            i1_tmin, 8.0f0)
                    i1_t_entry = i1_tmin

                    i1_iter = 0
                    for _ in Int32(1):Int32(4096)
                        i1_iter += 1
                        i1_inside, i1_cidx = _gpu_node_query(i1_ijk_x, i1_ijk_y, i1_ijk_z,
                            i1_orig_x, i1_orig_y, i1_orig_z, Int32(8), Int32(16))
                        if !i1_inside
                            push!(log, "        i1[$i1_iter] OUTSIDE span_open=$(span_t0 >= 0.0f0)")
                            break
                        end

                        i1_active = _gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_CMASK_OFF), i1_cidx) ||
                                    _gpu_buf_mask_is_on(buf, i1_off + Int32(_I1_VMASK_OFF), i1_cidx)
                        push!(log, "        i1[$i1_iter] ijk=($i1_ijk_x,$i1_ijk_y,$i1_ijk_z) cidx=$i1_cidx active=$i1_active t_entry=$i1_t_entry span_open=$(span_t0 >= 0.0f0)")

                        if i1_active
                            if span_t0 < 0.0f0
                                span_t0 = i1_t_entry
                                push!(log, "          SPAN OPEN at $span_t0")
                            end
                        elseif span_t0 >= 0.0f0
                            push!(spans, (span_t0, i1_t_entry))
                            push!(log, "          SPAN CLOSE [$span_t0, $i1_t_entry]")
                            span_t0 = -1.0f0
                        end

                        i1_t_entry = _gpu_cell_time(i1_tmax_x, i1_tmax_y, i1_tmax_z)
                        i1_ijk_x, i1_ijk_y, i1_ijk_z, i1_tmax_x, i1_tmax_y, i1_tmax_z =
                            _gpu_dda_step(i1_ijk_x, i1_ijk_y, i1_ijk_z,
                                i1_step_x, i1_step_y, i1_step_z,
                                i1_tmax_x, i1_tmax_y, i1_tmax_z,
                                i1_td_x, i1_td_y, i1_td_z)
                    end
                else
                    if span_t0 >= 0.0f0
                        push!(spans, (span_t0, i2_t_entry))
                        push!(log, "      SPAN CLOSE (i1 miss) [$span_t0, $i2_t_entry]")
                        span_t0 = -1.0f0
                    end
                end
            else
                i2_has_tile = _gpu_buf_mask_is_on(buf, i2_off + Int32(_I2_VMASK_OFF), i2_cidx)
                if i2_has_tile
                    if span_t0 < 0.0f0
                        span_t0 = i2_t_entry
                        push!(log, "      SPAN OPEN (i2 tile) at $span_t0")
                    end
                elseif span_t0 >= 0.0f0
                    push!(spans, (span_t0, i2_t_entry))
                    push!(log, "      SPAN CLOSE (i2 inactive) [$span_t0, $i2_t_entry]")
                    span_t0 = -1.0f0
                end
            end

            i2_t_entry = _gpu_cell_time(i2_tmax_x, i2_tmax_y, i2_tmax_z)
            i2_ijk_x, i2_ijk_y, i2_ijk_z, i2_tmax_x, i2_tmax_y, i2_tmax_z =
                _gpu_dda_step(i2_ijk_x, i2_ijk_y, i2_ijk_z,
                    i2_step_x, i2_step_y, i2_step_z,
                    i2_tmax_x, i2_tmax_y, i2_tmax_z,
                    i2_td_x, i2_td_y, i2_td_z)
        end

        if span_t0 >= 0.0f0
            push!(spans, (span_t0, i2_t_entry))
            push!(log, "    SPAN CLOSE (root end) [$span_t0, $i2_t_entry]")
            span_t0 = -1.0f0
        end
    end

    spans, log
end

# ── Helper: collect CPU reference spans ────────────────────────────────────

function collect_cpu_spans(nano, ray)
    spans = Tuple{Float64, Float64}[]
    foreach_hdda_span(nano, ray) do t0, t1
        push!(spans, (t0, t1))
        true  # continue
    end
    spans
end

# ── Helper: make a camera ray matching the GPU kernel ──────────────────────

function make_gpu_ray(cam, px::Int, py::Int, width::Int, height::Int)
    u = (Float32(px) - 1.0f0 + 0.5f0) / Float32(width)
    v = 1.0f0 - (Float32(py) - 1.0f0 + 0.5f0) / Float32(height)
    aspect = Float32(width) / Float32(height)
    half_fov = tan(Float32(cam.fov) * 0.5f0 * Float32(π) / 180.0f0)
    rpx = (2.0f0 * u - 1.0f0) * aspect * half_fov
    rpy = (2.0f0 * v - 1.0f0) * half_fov

    fx, fy, fz = Float32.(cam.forward)
    rx, ry, rz = Float32.(cam.right)
    ux, uy, uz = Float32.(cam.up)

    dx = fx + rx * rpx + ux * rpy
    dy = fy + ry * rpx + uy * rpy
    dz = fz + rz * rpx + uz * rpy
    dlen = sqrt(dx*dx + dy*dy + dz*dz)
    dlen = max(dlen, 1.0f-10)
    dx /= dlen; dy /= dlen; dz /= dlen

    ox, oy, oz = Float32.(cam.position)
    (ox, oy, oz, dx, dy, dz)
end

# ════════════════════════════════════════════════════════════════════════════
# TESTS
# ════════════════════════════════════════════════════════════════════════════

@testset "GPU HDDA Diagnostic" begin

    header_T_size = Int32(sizeof(Float32))

    @testset "Step 2: Minimal grids — analytical ground truth" begin

        @testset "Single leaf — 1 span" begin
            data = Dict{Coord, Float32}()
            for iz in 0:7, iy in 0:7, ix in 0:7
                data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
            end
            grid = build_grid(data, 0.0f0)
            nano = build_nanogrid(grid.tree)
            buf = nano.buffer

            ray = Ray(SVec3d(4.0, 4.0, -5.0), SVec3d(0.0, 0.0, 1.0))
            cpu_spans = collect_cpu_spans(nano, ray)
            gpu_spans = emulate_gpu_hdda_spans(buf, 4.0f0, 4.0f0, -5.0f0,
                                                0.0f0, 0.0f0, 1.0f0, header_T_size)

            @test length(cpu_spans) == 1
            @test length(gpu_spans) == length(cpu_spans)
            if !isempty(gpu_spans)
                @test gpu_spans[1][1] ≈ Float32(cpu_spans[1][1]) atol=0.5f0
                @test gpu_spans[1][2] ≈ Float32(cpu_spans[1][2]) atol=0.5f0
            end
            println("  Single leaf: CPU=$(cpu_spans) GPU=$(gpu_spans)")
        end

        @testset "3 adjacent leaves — 1 merged span" begin
            data = Dict{Coord, Float32}()
            for iz in 0:23, iy in 0:7, ix in 0:7
                data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
            end
            grid = build_grid(data, 0.0f0)
            nano = build_nanogrid(grid.tree)
            buf = nano.buffer

            ray = Ray(SVec3d(4.0, 4.0, -5.0), SVec3d(0.0, 0.0, 1.0))
            cpu_spans = collect_cpu_spans(nano, ray)
            gpu_spans = emulate_gpu_hdda_spans(buf, 4.0f0, 4.0f0, -5.0f0,
                                                0.0f0, 0.0f0, 1.0f0, header_T_size)

            @test length(cpu_spans) == 1
            @test length(gpu_spans) == length(cpu_spans)
            if !isempty(gpu_spans)
                @test gpu_spans[1][1] ≈ Float32(cpu_spans[1][1]) atol=0.5f0
                @test gpu_spans[1][2] ≈ Float32(cpu_spans[1][2]) atol=0.5f0
            end
            println("  Adjacent: CPU=$(cpu_spans) GPU=$(gpu_spans)")
        end

        @testset "Gapped leaves — 2 spans" begin
            data = Dict{Coord, Float32}()
            for iz in 0:7, iy in 0:7, ix in 0:7
                data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
            end
            for iz in 16:23, iy in 0:7, ix in 0:7
                data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
            end
            grid = build_grid(data, 0.0f0)
            nano = build_nanogrid(grid.tree)
            buf = nano.buffer

            ray = Ray(SVec3d(4.0, 4.0, -5.0), SVec3d(0.0, 0.0, 1.0))
            cpu_spans = collect_cpu_spans(nano, ray)
            gpu_spans = emulate_gpu_hdda_spans(buf, 4.0f0, 4.0f0, -5.0f0,
                                                0.0f0, 0.0f0, 1.0f0, header_T_size)

            @test length(cpu_spans) == 2
            @test length(gpu_spans) == length(cpu_spans)
            for i in 1:min(length(cpu_spans), length(gpu_spans))
                @test gpu_spans[i][1] ≈ Float32(cpu_spans[i][1]) atol=0.5f0
                @test gpu_spans[i][2] ≈ Float32(cpu_spans[i][2]) atol=0.5f0
            end
            println("  Gapped: CPU=$(cpu_spans) GPU=$(gpu_spans)")
        end

        @testset "Diagonal ray" begin
            data = Dict{Coord, Float32}()
            for iz in 0:7, iy in 0:7, ix in 0:7
                data[coord(Int32(ix), Int32(iy), Int32(iz))] = 1.0f0
            end
            grid = build_grid(data, 0.0f0)
            nano = build_nanogrid(grid.tree)
            buf = nano.buffer

            dir = SVec3d(1.0, 1.0, 1.0) / sqrt(3.0)
            ray = Ray(SVec3d(-5.0, -5.0, -5.0), dir)
            cpu_spans = collect_cpu_spans(nano, ray)

            df = Float32(1.0 / sqrt(3.0))
            gpu_spans = emulate_gpu_hdda_spans(buf, -5.0f0, -5.0f0, -5.0f0,
                                                df, df, df, header_T_size)

            @test length(gpu_spans) == length(cpu_spans)
            println("  Diagonal: CPU=$(cpu_spans) GPU=$(gpu_spans)")
        end
    end

    @testset "Step 3: smoke.vdb — per-pixel span comparison" begin
        smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
        if !isfile(smoke_path)
            @warn "smoke.vdb not found, skipping"
            @test_skip true
        else
            vdb = parse_vdb(smoke_path)
            grid = vdb.grids[1]
            nano = build_nanogrid(grid.tree)
            buf = nano.buffer

            cam = Camera((250.0, -100.0, 120.0), (55.0, 111.0, 59.0), (0.0, 0.0, 1.0), 35.0)

            width, height = 32, 32
            total_cpu_coverage = 0.0
            total_gpu_coverage = 0.0
            span_count_mismatches = 0
            total_rays_with_spans = 0

            for py in 1:height, px in 1:width
                ox, oy, oz, dx, dy, dz = make_gpu_ray(cam, px, py, width, height)

                # CPU reference spans (Float64)
                dir64 = SVec3d(Float64(dx), Float64(dy), Float64(dz))
                dlen = sqrt(sum(dir64 .^ 2))
                dir64 = dir64 ./ dlen
                ray = Ray(SVec3d(Float64(ox), Float64(oy), Float64(oz)), dir64)
                cpu_spans = collect_cpu_spans(nano, ray)

                # GPU emulation spans (Float32)
                gpu_spans = emulate_gpu_hdda_spans(buf, ox, oy, oz, dx, dy, dz, header_T_size)

                cpu_cov = sum(s[2] - s[1] for s in cpu_spans; init=0.0)
                gpu_cov = sum(Float64(s[2] - s[1]) for s in gpu_spans; init=0.0)

                if !isempty(cpu_spans)
                    total_rays_with_spans += 1
                    total_cpu_coverage += cpu_cov
                    total_gpu_coverage += gpu_cov
                    if length(gpu_spans) != length(cpu_spans)
                        span_count_mismatches += 1
                    end
                end
            end

            coverage_ratio = total_gpu_coverage / max(total_cpu_coverage, 1e-10)
            println("\n=== SMOKE.VDB SPAN COMPARISON ($(width)x$(height)) ===")
            println("  Rays with spans: $total_rays_with_spans / $(width*height)")
            println("  Span count mismatches: $span_count_mismatches / $total_rays_with_spans")
            println("  Total CPU coverage: $(round(total_cpu_coverage, digits=1))")
            println("  Total GPU coverage: $(round(total_gpu_coverage, digits=1))")
            println("  Coverage ratio (GPU/CPU): $(round(coverage_ratio, digits=4))")
            println("  Expected ~1.0 if spans correct, ~0.29 if 3.5x bug")

            # If coverage ratio is significantly less than 1.0, spans are being truncated
            if coverage_ratio < 0.9
                println("\n  *** SPANS DIVERGE — GPU covers $(round(coverage_ratio * 100, digits=1))% of CPU ***")
                println("  Running verbose diagnostic on first divergent ray...")

                # Find first ray with span mismatch and log it
                for py in 1:height, px in 1:width
                    ox, oy, oz, dx, dy, dz = make_gpu_ray(cam, px, py, width, height)
                    dir64 = SVec3d(Float64(dx), Float64(dy), Float64(dz))
                    dlen = sqrt(sum(dir64 .^ 2))
                    dir64 = dir64 ./ dlen
                    ray = Ray(SVec3d(Float64(ox), Float64(oy), Float64(oz)), dir64)
                    cpu_spans = collect_cpu_spans(nano, ray)
                    gpu_spans, log = emulate_gpu_hdda_spans_verbose(buf, ox, oy, oz, dx, dy, dz, header_T_size)

                    if length(gpu_spans) != length(cpu_spans)
                        println("\n  Pixel ($px, $py): CPU has $(length(cpu_spans)) spans, GPU has $(length(gpu_spans))")
                        println("  CPU spans: $cpu_spans")
                        println("  GPU spans: $gpu_spans")
                        println("  Ray: o=($ox,$oy,$oz) d=($dx,$dy,$dz)")
                        println("\n  --- Verbose trace ---")
                        for line in log
                            println("  $line")
                        end
                        break
                    end
                end
            end

            # The spans should roughly match (Float32 vs Float64 tolerance)
            @test coverage_ratio > 0.9  # If this fails, spans are being truncated
        end
    end
end
