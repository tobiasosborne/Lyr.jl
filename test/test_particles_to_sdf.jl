@testset "particles_to_sdf" begin

    @testset "single particle matches create_level_set_sphere" begin
        pos = [(0.0, 0.0, 0.0)]
        grid = particles_to_sdf(pos, 10.0; voxel_size=1.0, half_width=3.0)
        ref = create_level_set_sphere(center=(0.0, 0.0, 0.0), radius=10.0,
                                       voxel_size=1.0, half_width=3.0)

        @test grid isa Grid{Float32}
        # Voxel counts approximately equal (different rasterization strategies)
        @test abs(active_voxel_count(grid.tree) - active_voxel_count(ref.tree)) < 200

        # SDF values should match at surface points
        for c in [coord(10, 0, 0), coord(0, 10, 0), coord(0, 0, 10)]
            @test get_value(grid.tree, c) ≈ get_value(ref.tree, c) atol=0.1f0
        end
    end

    @testset "two overlapping spheres merge" begin
        # Two spheres that overlap — CSG union via min
        pos = [(0.0, 0.0, 0.0), (8.0, 0.0, 0.0)]
        grid = particles_to_sdf(pos, 6.0; voxel_size=1.0, half_width=3.0)

        # At the midpoint: dist to each center = 4, radius = 6, SDF = 4-6 = -2
        @test get_value(grid.tree, coord(4, 0, 0)) ≈ -2.0f0 atol=0.1f0

        # Near the surface of first sphere (radius 6): SDF ≈ 0
        @test abs(get_value(grid.tree, coord(6, 0, 0))) < 0.5f0

        # Far outside: background
        @test get_value(grid.tree, coord(100, 0, 0)) == grid.tree.background
    end

    @testset "variable radii" begin
        pos = [(0.0, 0.0, 0.0), (20.0, 0.0, 0.0)]
        radii = [5.0, 10.0]
        grid = particles_to_sdf(pos, radii; voxel_size=1.0, half_width=3.0)

        # First particle: radius 5, surface at (5,0,0)
        @test abs(get_value(grid.tree, coord(5, 0, 0))) < 0.5f0

        # Second particle: radius 10, surface at (30,0,0)
        @test abs(get_value(grid.tree, coord(30, 0, 0))) < 0.5f0
    end

    @testset "narrow band consistency" begin
        pos = [(0.0, 0.0, 0.0)]
        grid = particles_to_sdf(pos, 8.0; voxel_size=1.0, half_width=3.0)
        bg = grid.tree.background

        # All active voxels should be within narrow band
        for (_, sdf) in active_voxels(grid.tree)
            @test abs(sdf) <= bg + 0.01f0
        end
    end

    @testset "grid class is LEVEL_SET" begin
        pos = [(0.0, 0.0, 0.0)]
        grid = particles_to_sdf(pos, 5.0)
        @test grid.grid_class == GRID_LEVEL_SET
    end

    @testset "positive background" begin
        pos = [(0.0, 0.0, 0.0)]
        grid = particles_to_sdf(pos, 5.0; half_width=3.0, voxel_size=1.0)
        @test grid.tree.background > 0.0f0
        @test grid.tree.background ≈ 3.0f0
    end

    @testset "voxel_size scaling" begin
        pos = [(0.0, 0.0, 0.0)]
        fine = particles_to_sdf(pos, 5.0; voxel_size=0.5)
        coarse = particles_to_sdf(pos, 5.0; voxel_size=2.0)
        # Finer grid → more voxels
        @test active_voxel_count(fine.tree) > active_voxel_count(coarse.tree)
    end

    @testset "many particles" begin
        # 100 deterministic particles in a cube
        pos = [((i * 7 + 3) % 20 * 1.0, (i * 13 + 7) % 20 * 1.0, (i * 17 + 11) % 20 * 1.0) for i in 1:100]
        grid = particles_to_sdf(pos, 2.0; voxel_size=1.0, half_width=2.0)
        @test active_voxel_count(grid.tree) > 0
        diag = check_level_set(grid)
        @test diag.interior_count > 0
        @test diag.exterior_count > 0
    end

    @testset "empty particles" begin
        grid = particles_to_sdf(NTuple{3,Float64}[], 1.0)
        @test active_voxel_count(grid.tree) == 0
    end

end
