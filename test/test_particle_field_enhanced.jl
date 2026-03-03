using Test
using Lyr
using Lyr: SVec3d, ParticleField, voxelize, active_voxel_count, check_level_set,
           GRID_LEVEL_SET, GRID_FOG_VOLUME, get_value, coord

@testset "Enhanced ParticleField Voxelization" begin
    @testset "auto mode — with radii → level set" begin
        positions = [SVec3d(0.0, 0.0, 0.0), SVec3d(10.0, 0.0, 0.0)]
        props = Dict{Symbol, Vector}(:radii => [3.0, 3.0])
        pf = ParticleField(positions; properties=props)

        grid = voxelize(pf; voxel_size=1.0)
        @test grid.grid_class == GRID_LEVEL_SET
        @test active_voxel_count(grid.tree) > 50

        diag = check_level_set(grid)
        @test diag.valid
    end

    @testset "auto mode — without radii → fog" begin
        positions = [SVec3d(0.0, 0.0, 0.0), SVec3d(5.0, 0.0, 0.0)]
        pf = ParticleField(positions)

        grid = voxelize(pf; voxel_size=1.0)
        @test grid.grid_class == GRID_FOG_VOLUME
    end

    @testset "explicit mode override — fog with radii" begin
        positions = [SVec3d(0.0, 0.0, 0.0)]
        props = Dict{Symbol, Vector}(:radii => [5.0])
        pf = ParticleField(positions; properties=props)

        grid = voxelize(pf; voxel_size=1.0, mode=:fog)
        @test grid.grid_class == GRID_FOG_VOLUME
    end

    @testset "explicit mode override — levelset without radii uses default radius" begin
        positions = [SVec3d(0.0, 0.0, 0.0)]
        pf = ParticleField(positions)

        grid = voxelize(pf; voxel_size=1.0, mode=:levelset)
        @test grid.grid_class == GRID_LEVEL_SET
        @test get_value(grid.tree, coord(0, 0, 0)) < 0.0f0  # inside sphere of radius 1
    end

    @testset "per-particle radii" begin
        positions = [SVec3d(0.0, 0.0, 0.0), SVec3d(20.0, 0.0, 0.0)]
        props = Dict{Symbol, Vector}(:radii => [2.0, 5.0])
        pf = ParticleField(positions; properties=props)

        grid = voxelize(pf; voxel_size=1.0)
        @test grid.grid_class == GRID_LEVEL_SET

        # Second particle (radius 5) should have larger SDF footprint
        # Point at (20, 4, 0) should be inside second particle (r=5) but outside first (r=2)
        @test get_value(grid.tree, coord(20, 4, 0)) < 0.0f0
    end
end
