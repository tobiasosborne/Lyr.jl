@testset "Animation" begin

# ============================================================================
# Camera modes
# ============================================================================

@testset "Camera modes" begin
    # FixedCamera produces the same camera every frame
    fc = FixedCamera((10.0, 10.0, 10.0), (0.0, 0.0, 0.0))
    cam1 = Lyr.camera_at_frame(fc, 1, 100, 0.0)
    cam2 = Lyr.camera_at_frame(fc, 50, 100, 5.0)
    @test isa(cam1, Camera)
    @test cam1.position ≈ cam2.position

    # OrbitCamera sweeps azimuth over nframes
    oc = OrbitCamera((0.0, 0.0, 0.0), 20.0; revolutions=1.0)
    cam_start = Lyr.camera_at_frame(oc, 1, 100, 0.0)
    cam_quarter = Lyr.camera_at_frame(oc, 26, 100, 2.5)
    @test isa(cam_start, Camera)
    # After ~1/4 revolution, camera position should differ significantly
    @test norm(cam_start.position - cam_quarter.position) > 5.0

    # FollowCamera tracks center_fn
    center_fn = t -> (t, 0.0, 0.0)  # moves along x-axis
    flc = FollowCamera(center_fn, 15.0)
    cam_t0 = Lyr.camera_at_frame(flc, 1, 10, 0.0)
    cam_t5 = Lyr.camera_at_frame(flc, 6, 10, 5.0)
    @test isa(cam_t0, Camera)
    # Camera should move with the target
    @test cam_t5.position[1] > cam_t0.position[1]
end

# ============================================================================
# Transfer function presets
# ============================================================================

@testset "Transfer function presets" begin
    for tf_fn in [tf_electron, tf_photon, tf_excited]
        tf = tf_fn()
        @test isa(tf, TransferFunction)
        @test length(tf.points) ≥ 3
        # Evaluate at midpoint without error
        rgba = evaluate(tf, 0.5)
        @test length(rgba) == 4
        @test all(0.0 ≤ c ≤ 1.0 for c in rgba)
    end
end

# ============================================================================
# render_animation (integration test with tiny frames)
# ============================================================================

@testset "render_animation" begin
    # Simple Gaussian wavepacket, 2 frames at 32×32
    wp = GaussianWavepacketField((0.5, 0.0, 0.0), (0.0, 0.0, 0.0), 1.5;
                                 m=1.0, t_range=(0.0, 5.0), dt=1.0)
    mat = VolumeMaterial(tf_electron(); sigma_scale=5.0)
    cam = FixedCamera((8.0, 6.0, 5.0), (0.0, 0.0, 0.0))

    frame_dir = mktempdir()
    output_path = joinpath(frame_dir, "test_anim.mp4")

    result = render_animation(wp, mat, cam;
        t_range=(0.0, 2.0), nframes=2,
        width=32, height=32, spp=1,
        output_dir=frame_dir, output=output_path)

    # Frames were created
    @test isfile(joinpath(frame_dir, "frame_0001.ppm"))
    @test isfile(joinpath(frame_dir, "frame_0002.ppm"))

    # Return value is the output path
    @test result == output_path
end

# ============================================================================
# stitch_to_mp4
# ============================================================================

@testset "stitch_to_mp4" begin
    # Test with non-existent directory (should fail gracefully)
    if Sys.which("ffmpeg") !== nothing
        # Create minimal PPM frames for stitching test
        frame_dir = mktempdir()
        for i in 1:3
            img = fill((0.0, 0.0, 0.0), 8, 8)
            write_ppm(joinpath(frame_dir, "frame_$(lpad(i, 4, '0')).ppm"), img)
        end
        out = joinpath(frame_dir, "test.mp4")
        @test stitch_to_mp4(frame_dir, out; fps=10) == true
        @test isfile(out)
    else
        @test stitch_to_mp4("/nonexistent", "/dev/null") == false
    end
end

end  # @testset "Animation"
