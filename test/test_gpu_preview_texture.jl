# Test gpu_render_volume_preview with use_texture=true — CuTexture hardware
# trilinear fast path.
#
# Bead: path-tracer-kbhm (E2 of EPIC path-tracer-ooul). Depends on E1
# (CuTexture feasibility research — docs/stocktake/10_cutexture_feasibility.md)
# and P0 (GPU preview port — path-tracer-9kad).
#
# Acceptance criteria (from bead):
#   1) identical-output test  (PSNR >= 40 dB vs NanoVDB path)
#   2) >= 3x speedup on a 128^3 dense grid
#
# Test is gated on CUDA.functional() — skipped cleanly on non-CUDA CI.
# Per E1 §9 precision note, the textures use a 9-bit fraction for
# interpolation weights, so pixel-wise differences beyond Float32 rounding
# are expected and bounded. 40 dB PSNR is the right tolerance.
using Test
using Lyr

@testset "gpu_render_volume_preview use_texture=true (E2)" begin
    # Skip cleanly if CUDA is not loaded or not functional.
    cuda_mod = nothing
    try
        cuda_mod = Base.require(Base.PkgId(Base.UUID("052768ef-5323-5732-b1bb-66c8b64840ba"), "CUDA"))
    catch
    end
    if cuda_mod === nothing || !Base.invokelatest(cuda_mod.functional)
        @test_skip "CUDA.jl not functional — CuTexture tests skipped"
        return
    end

    # ------- Build a 128³ dense fog: a radial Gaussian-ish density -------
    N = 128
    data = Dict{Lyr.Coord, Float32}()
    cx, cy, cz = (N - 1) / 2, (N - 1) / 2, (N - 1) / 2
    rmax = Float32(N / 2)
    for i in 0:(N-1), j in 0:(N-1), k in 0:(N-1)
        r = sqrt((i - cx)^2 + (j - cy)^2 + (k - cz)^2)
        d = Float32(max(0.0, 1.0 - r / rmax))
        d > 0.02f0 && (data[Lyr.coord(i, j, k)] = d)
    end
    grid = build_grid(data, 0.0f0; name="density")
    nano = build_nanogrid(grid.tree)
    bbox = Lyr.active_bounding_box(grid.tree)

    # Camera pointing at volume center from outside
    cam_target = (0.5 * (bbox.min.x + bbox.max.x),
                  0.5 * (bbox.min.y + bbox.max.y),
                  0.5 * (bbox.min.z + bbox.max.z))
    cam_pos = (cam_target[1] + 1.5 * N, cam_target[2] + 0.6 * N, cam_target[3] + 0.4 * N)
    cam = Camera(cam_pos, cam_target, (0.0, 0.0, 1.0), 35.0)
    mat = VolumeMaterial(tf_smoke(); sigma_scale=12.0, emission_scale=1.0)
    vol = VolumeEntry(grid, nano, mat)
    scene = Scene(cam, DirectionalLight((1.0, 1.0, 1.0), (1.0, 1.0, 1.0)), vol)

    W, H = 256, 192
    step = 0.5f0

    # -------------------- Correctness: PSNR >= 40 dB ---------------------
    img_nano = gpu_render_volume_preview(nano, scene, W, H;
                                         step_size=step, use_texture=false)
    img_tex  = gpu_render_volume_preview(nano, scene, W, H;
                                         step_size=step, use_texture=true)

    @test size(img_tex) == (H, W)
    @test eltype(img_tex) == NTuple{3,Float32}

    nano_f64 = [(Float64(p[1]), Float64(p[2]), Float64(p[3])) for p in img_nano]
    tex_f64  = [(Float64(p[1]), Float64(p[2]), Float64(p[3])) for p in img_tex]
    psnr = image_psnr(nano_f64, tex_f64)
    @test psnr >= 40.0

    # ------------------------- Speedup: >= 3x ---------------------------
    # Warm up both kernels — first run includes CUDA kernel compile + densify.
    gpu_render_volume_preview(nano, scene, 32, 32; step_size=step, use_texture=false)
    gpu_render_volume_preview(nano, scene, 32, 32; step_size=step, use_texture=true)

    # Median-of-3 timed runs for each path.
    function time_render(use_texture)
        ts = Float64[]
        for _ in 1:3
            GC.gc()
            t0 = time_ns()
            gpu_render_volume_preview(nano, scene, W, H;
                                      step_size=step, use_texture=use_texture)
            push!(ts, (time_ns() - t0) / 1e6)
        end
        sort!(ts); ts[2]
    end

    t_nano = time_render(false)
    t_tex  = time_render(true)
    speedup = t_nano / t_tex
    @info "E2 speedup" t_nano_ms=t_nano t_tex_ms=t_tex speedup=speedup psnr=psnr
    @test speedup >= 3.0
end
