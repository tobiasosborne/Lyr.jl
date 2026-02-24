using Test
using StaticArrays

@testset "Visualize" begin

    # A small field for fast rendering
    test_field() = ScalarField3D(
        (x, y, z) -> exp(-(x^2 + y^2 + z^2)),
        BoxDomain((-2.0, -2.0, -2.0), (2.0, 2.0, 2.0)),
        1.0
    )

    @testset "Camera presets" begin
        @testset "camera_orbit" begin
            cam = camera_orbit((0.0, 0.0, 0.0), 10.0)
            @test cam isa Camera
            # Position should be at distance 10 from origin
            pos = cam.position
            dist = sqrt(pos[1]^2 + pos[2]^2 + pos[3]^2)
            @test dist ≈ 10.0 atol=0.1
        end

        @testset "camera_front" begin
            cam = camera_front((0.0, 0.0, 0.0), 5.0)
            @test cam isa Camera
            @test cam.position[3] ≈ 5.0
        end

        @testset "camera_iso" begin
            cam = camera_iso((1.0, 2.0, 3.0), 10.0)
            @test cam isa Camera
        end
    end

    @testset "Material presets" begin
        @testset "material_emission" begin
            m = material_emission()
            @test m isa VolumeMaterial
            @test m.sigma_scale == 2.0
            @test m.emission_scale == 5.0
        end

        @testset "material_cloud" begin
            m = material_cloud()
            @test m isa VolumeMaterial
            @test m.scattering_albedo == 0.9
        end

        @testset "material_fire" begin
            m = material_fire()
            @test m isa VolumeMaterial
            @test m.emission_scale == 8.0
        end

        @testset "custom TF in preset" begin
            m = material_emission(; tf=tf_blackbody())
            @test m isa VolumeMaterial
        end
    end

    @testset "Light presets" begin
        @testset "light_studio" begin
            ls = light_studio()
            @test length(ls) == 1
            @test ls[1] isa DirectionalLight
        end

        @testset "light_natural" begin
            ls = light_natural()
            @test length(ls) == 2
        end

        @testset "light_dramatic" begin
            ls = light_dramatic()
            @test length(ls) == 2
        end
    end

    @testset "Auto-camera" begin
        field = test_field()
        grid = voxelize(field; voxel_size=1.0)
        cam = Lyr._auto_camera(grid)
        @test cam isa Camera
    end

    @testset "Auto-camera world-to-index round-trip" begin
        field = test_field()
        grid1 = voxelize(field; voxel_size=1.0)
        grid05 = voxelize(field; voxel_size=0.5)
        grid025 = voxelize(field; voxel_size=0.25)

        # Auto-camera returns world-space coords; converting to index space
        # should give the SAME index-space position regardless of voxel_size
        # (index bboxes are identical due to block alignment)
        idx1 = Lyr._camera_to_index_space(Lyr._auto_camera(grid1), 1.0)
        idx05 = Lyr._camera_to_index_space(Lyr._auto_camera(grid05), 0.5)
        idx025 = Lyr._camera_to_index_space(Lyr._auto_camera(grid025), 0.25)

        for i in 1:3
            @test idx1.position[i] ≈ idx05.position[i]
            @test idx1.position[i] ≈ idx025.position[i]
        end
    end

    @testset "Camera world-to-index-space transform" begin
        cam = Camera((10.0, 5.0, 10.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 40.0)

        # voxel_size=1.0: no change
        cam_idx = Lyr._camera_to_index_space(cam, 1.0)
        @test cam_idx.position == cam.position

        # voxel_size=0.5: position scaled by 2x
        cam_idx = Lyr._camera_to_index_space(cam, 0.5)
        @test cam_idx.position[1] ≈ 20.0
        @test cam_idx.position[2] ≈ 10.0
        @test cam_idx.position[3] ≈ 20.0
        @test cam_idx.fov == cam.fov
        # Direction vectors preserved under uniform scaling
        @test cam_idx.forward == cam.forward
    end

    @testset "visualize with non-unit voxel_size and custom camera" begin
        field = test_field()
        # World-space camera: should be outside the domain [-2, 2]
        cam = Camera((5.0, 3.0, 5.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 45.0)
        pixels = visualize(field;
            voxel_size=0.5,
            width=16, height=16,
            spp=1,
            camera=cam)
        @test size(pixels) == (16, 16)
        # Should produce non-black pixels (camera properly outside volume)
        any_nonblack = any(p -> p[1] > 0.01 || p[2] > 0.01 || p[3] > 0.01, pixels)
        @test any_nonblack
    end

    @testset "visualize — smoke test" begin
        field = test_field()
        # Use large voxel_size for speed
        pixels = visualize(field;
            voxel_size=1.0,
            width=32, height=32,
            spp=1)
        @test size(pixels) == (32, 32)
        @test pixels[1,1] isa NTuple{3, Float64}
    end

    @testset "visualize — custom camera" begin
        field = test_field()
        cam = Camera((10.0, 5.0, 10.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 45.0)
        pixels = visualize(field;
            voxel_size=1.0,
            width=16, height=16,
            spp=1,
            camera=cam)
        @test size(pixels) == (16, 16)
    end

    @testset "visualize — custom material" begin
        field = test_field()
        mat = material_fire()
        pixels = visualize(field;
            voxel_size=1.0,
            width=16, height=16,
            spp=1,
            material=mat)
        @test size(pixels) == (16, 16)
    end

    @testset "visualize — output to file" begin
        field = test_field()
        # Use .ppm to avoid PNGFiles dependency in tests
        path = tempname() * ".ppm"
        try
            pixels = visualize(field;
                voxel_size=1.0,
                width=16, height=16,
                spp=1,
                output=path)
            @test isfile(path)
            @test filesize(path) > 0
        finally
            isfile(path) && rm(path)
        end
    end

    @testset "visualize — ParticleField" begin
        positions = [SVec3d(i, j, k) for i in 0:2 for j in 0:2 for k in 0:2]
        field = ParticleField(positions)
        pixels = visualize(field;
            voxel_size=1.0,
            sigma=1.0,
            cutoff_sigma=2.0,
            width=16, height=16,
            spp=1)
        @test size(pixels) == (16, 16)
    end

    @testset "visualize — denoise" begin
        field = test_field()
        pixels = visualize(field;
            voxel_size=1.0,
            width=16, height=16,
            spp=1,
            denoise=true)
        @test size(pixels) == (16, 16)
    end
end
