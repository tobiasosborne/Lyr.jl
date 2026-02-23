# Test scene description types
using Test
using Lyr

@testset "Scene" begin
    @testset "PointLight construction" begin
        light = PointLight(SVec3d(1.0, 2.0, 3.0), SVec3d(0.5, 0.5, 0.5))
        @test light.position == SVec3d(1.0, 2.0, 3.0)
        @test light.intensity == SVec3d(0.5, 0.5, 0.5)

        # Tuple convenience
        light2 = PointLight((1.0, 2.0, 3.0), (1.0, 1.0, 1.0))
        @test light2.position == SVec3d(1.0, 2.0, 3.0)

        # Default intensity
        light3 = PointLight((1.0, 2.0, 3.0))
        @test light3.intensity == SVec3d(1.0, 1.0, 1.0)
    end

    @testset "DirectionalLight construction" begin
        light = DirectionalLight((0.0, 1.0, 0.0), (1.0, 1.0, 1.0))
        @test light.direction ≈ SVec3d(0.0, 1.0, 0.0) atol=1e-10

        # Auto-normalizes
        light2 = DirectionalLight((0.0, 2.0, 0.0), (1.0, 1.0, 1.0))
        len = sqrt(sum(light2.direction .^ 2))
        @test len ≈ 1.0 atol=1e-10
    end

    @testset "VolumeMaterial construction" begin
        tf = tf_smoke()
        mat = VolumeMaterial(tf)
        @test mat.sigma_scale == 1.0
        @test mat.emission_scale == 1.0
        @test mat.scattering_albedo == 0.5
        @test mat.phase_function isa IsotropicPhase
    end

    @testset "VolumeMaterial with custom phase function" begin
        tf = tf_blackbody()
        pf = HenyeyGreensteinPhase(0.8)
        mat = VolumeMaterial(tf; phase_function=pf, sigma_scale=2.0)
        @test mat.sigma_scale == 2.0
        @test mat.phase_function isa HenyeyGreensteinPhase
    end

    @testset "VolumeEntry construction" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if isfile(cube_path)
            vdb = parse_vdb(cube_path)
            grid = vdb.grids[1]
            tf = tf_smoke()
            mat = VolumeMaterial(tf)
            entry = VolumeEntry(grid, mat)
            @test entry.nanogrid === nothing
            @test entry.grid === grid
        end
    end

    @testset "Scene construction" begin
        cam = Camera((10.0, 5.0, 10.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 60.0)
        light = DirectionalLight((0.577, 0.577, 0.577))

        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if isfile(cube_path)
            vdb = parse_vdb(cube_path)
            grid = vdb.grids[1]
            tf = tf_smoke()
            mat = VolumeMaterial(tf)
            vol = VolumeEntry(grid, mat)

            scene = Scene(cam, light, vol)
            @test length(scene.lights) == 1
            @test length(scene.volumes) == 1
            @test scene.background == SVec3d(0.0, 0.0, 0.0)

            # With custom background
            scene2 = Scene(cam, AbstractLight[light], [vol];
                          background=(0.1, 0.1, 0.15))
            @test scene2.background == SVec3d(0.1, 0.1, 0.15)
        end
    end

    @testset "Scene does not copy grid data" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if isfile(cube_path)
            vdb = parse_vdb(cube_path)
            grid = vdb.grids[1]
            tf = tf_smoke()
            mat = VolumeMaterial(tf)
            vol = VolumeEntry(grid, mat)
            cam = Camera((10.0, 5.0, 10.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 60.0)
            scene = Scene(cam, DirectionalLight((1.0, 1.0, 1.0)), vol)

            # Grid should be the same object (no copy)
            @test scene.volumes[1].grid === grid
        end
    end
end
