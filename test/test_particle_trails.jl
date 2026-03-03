using Test
using Lyr
using Lyr: Coord, coord, get_value, active_voxels, active_voxel_count,
           particle_trails_to_sdf, particles_to_sdf, check_level_set, GRID_LEVEL_SET

@testset "particle_trails_to_sdf" begin

    @testset "single capsule interior is negative" begin
        # Particle at origin moving along +x with radius 3
        pos = [(0.0, 0.0, 0.0)]
        vel = [(10.0, 0.0, 0.0)]
        grid = particle_trails_to_sdf(pos, vel, 3.0; dt=1.0, voxel_size=1.0, half_width=3.0)

        @test grid isa Grid{Float32}
        @test active_voxel_count(grid.tree) > 0

        # Center of capsule (midpoint of trail) should be deep inside
        @test get_value(grid.tree, coord(5, 0, 0)) < 0.0f0

        # On the axis at start and end should be inside
        @test get_value(grid.tree, coord(0, 0, 0)) < 0.0f0
        @test get_value(grid.tree, coord(10, 0, 0)) < 0.0f0
    end

    @testset "single capsule surface near zero" begin
        pos = [(0.0, 0.0, 0.0)]
        vel = [(10.0, 0.0, 0.0)]
        r = 4.0
        grid = particle_trails_to_sdf(pos, vel, r; dt=1.0, voxel_size=1.0, half_width=3.0)

        # Surface perpendicular to axis at midpoint: voxel at (5, 4, 0) should be near zero
        @test abs(get_value(grid.tree, coord(5, 4, 0))) < 0.5f0

        # Surface at hemisphere cap: (14, 0, 0) is dist 4 from endpoint (10,0,0)
        @test abs(get_value(grid.tree, coord(14, 0, 0))) < 0.5f0

        # Surface at start cap: (-4, 0, 0) is dist 4 from start (0,0,0)
        @test abs(get_value(grid.tree, coord(-4, 0, 0))) < 0.5f0
    end

    @testset "zero velocity degenerates to sphere" begin
        pos = [(0.0, 0.0, 0.0)]
        vel = [(0.0, 0.0, 0.0)]
        r = 5.0
        vs = 1.0
        hw = 3.0

        trail_grid = particle_trails_to_sdf(pos, vel, r; dt=1.0, voxel_size=vs, half_width=hw)
        sphere_grid = particles_to_sdf(pos, r; voxel_size=vs, half_width=hw)

        # Should produce approximately the same number of voxels
        trail_count = active_voxel_count(trail_grid.tree)
        sphere_count = active_voxel_count(sphere_grid.tree)
        @test abs(trail_count - sphere_count) < max(trail_count, sphere_count) * 0.05

        # SDF values at surface points should match
        for c in [coord(5, 0, 0), coord(0, 5, 0), coord(0, 0, 5),
                  coord(-5, 0, 0), coord(0, -5, 0), coord(0, 0, -5)]
            @test get_value(trail_grid.tree, c) ≈ get_value(sphere_grid.tree, c) atol=0.1f0
        end
    end

    @testset "two overlapping capsules merge via min" begin
        # Two capsules that overlap in the middle
        pos = [(0.0, 0.0, 0.0), (0.0, 10.0, 0.0)]
        vel = [(0.0, 5.0, 0.0), (0.0, -5.0, 0.0)]  # moving toward each other
        grid = particle_trails_to_sdf(pos, vel, 3.0; dt=1.0, voxel_size=1.0, half_width=3.0)

        # Both capsules cover the y=5 region — the overlap point on the axis should be inside
        @test get_value(grid.tree, coord(0, 5, 0)) < 0.0f0

        # Far outside both capsules
        @test get_value(grid.tree, coord(100, 0, 0)) == grid.tree.background
    end

    @testset "level set diagnostics valid" begin
        pos = [(0.0, 0.0, 0.0)]
        vel = [(8.0, 0.0, 0.0)]
        grid = particle_trails_to_sdf(pos, vel, 4.0; dt=1.0, voxel_size=1.0, half_width=3.0)

        diag = check_level_set(grid)
        @test diag.interior_count > 0
        @test diag.exterior_count > 0
    end

    @testset "grid class is LEVEL_SET" begin
        pos = [(0.0, 0.0, 0.0)]
        vel = [(5.0, 0.0, 0.0)]
        grid = particle_trails_to_sdf(pos, vel, 2.0)
        @test grid.grid_class == GRID_LEVEL_SET
    end

    @testset "positive background" begin
        pos = [(0.0, 0.0, 0.0)]
        vel = [(5.0, 0.0, 0.0)]
        grid = particle_trails_to_sdf(pos, vel, 2.0; half_width=3.0, voxel_size=1.0)
        @test grid.tree.background > 0.0f0
        @test grid.tree.background ≈ 3.0f0
    end

    @testset "narrow band consistency" begin
        pos = [(0.0, 0.0, 0.0)]
        vel = [(6.0, 0.0, 0.0)]
        grid = particle_trails_to_sdf(pos, vel, 3.0; voxel_size=1.0, half_width=3.0)
        bg = grid.tree.background

        # All active voxels should be within narrow band
        for (_, sdf) in active_voxels(grid.tree)
            @test abs(sdf) <= bg + 0.01f0
        end
    end

    @testset "voxel_size scaling" begin
        pos = [(0.0, 0.0, 0.0)]
        vel = [(8.0, 0.0, 0.0)]
        fine = particle_trails_to_sdf(pos, vel, 3.0; voxel_size=0.5)
        coarse = particle_trails_to_sdf(pos, vel, 3.0; voxel_size=2.0)
        # Finer grid should have more voxels
        @test active_voxel_count(fine.tree) > active_voxel_count(coarse.tree)
    end

    @testset "dt scaling" begin
        pos = [(0.0, 0.0, 0.0)]
        vel = [(10.0, 0.0, 0.0)]
        short = particle_trails_to_sdf(pos, vel, 2.0; dt=0.5, voxel_size=1.0)
        long = particle_trails_to_sdf(pos, vel, 2.0; dt=2.0, voxel_size=1.0)
        # Longer trail should produce more voxels
        @test active_voxel_count(long.tree) > active_voxel_count(short.tree)
    end

    @testset "variable radii" begin
        pos = [(0.0, 0.0, 0.0), (20.0, 0.0, 0.0)]
        vel = [(5.0, 0.0, 0.0), (5.0, 0.0, 0.0)]
        radii = [3.0, 6.0]
        grid = particle_trails_to_sdf(pos, vel, radii; dt=1.0, voxel_size=1.0, half_width=3.0)

        # First capsule surface (perpendicular at start): (0, 3, 0)
        @test abs(get_value(grid.tree, coord(0, 3, 0))) < 0.5f0

        # Second capsule surface (perpendicular at start): (20, 6, 0)
        @test abs(get_value(grid.tree, coord(20, 6, 0))) < 0.5f0
    end

    @testset "diagonal velocity" begin
        # Capsule along the (1,1,0) diagonal
        pos = [(0.0, 0.0, 0.0)]
        vel = [(10.0, 10.0, 0.0)]
        grid = particle_trails_to_sdf(pos, vel, 3.0; dt=1.0, voxel_size=1.0, half_width=3.0)

        # Midpoint of trail at (5,5,0) should be inside
        @test get_value(grid.tree, coord(5, 5, 0)) < 0.0f0

        # Endpoint (10,10,0) should be inside
        @test get_value(grid.tree, coord(10, 10, 0)) < 0.0f0
    end

    @testset "many particles" begin
        # 50 deterministic particles with varying velocities
        pos = [((i * 7 + 3) % 20 * 1.0, (i * 13 + 7) % 20 * 1.0, (i * 17 + 11) % 20 * 1.0) for i in 1:50]
        vel = [((i * 3 + 1) % 5 * 1.0, (i * 11 + 2) % 5 * 1.0, (i * 7 + 3) % 5 * 1.0) for i in 1:50]
        grid = particle_trails_to_sdf(pos, vel, 2.0; dt=1.0, voxel_size=1.0, half_width=2.0)
        @test active_voxel_count(grid.tree) > 0
        diag = check_level_set(grid)
        @test diag.interior_count > 0
        @test diag.exterior_count > 0
    end

    @testset "empty particles" begin
        grid = particle_trails_to_sdf(NTuple{3,Float64}[], NTuple{3,Float64}[], 1.0)
        @test active_voxel_count(grid.tree) == 0
    end

    @testset "mismatched positions and velocities throws" begin
        pos = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)]
        vel = [(1.0, 0.0, 0.0)]
        @test_throws ArgumentError particle_trails_to_sdf(pos, vel, 1.0)
    end

end
