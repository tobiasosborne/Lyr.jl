# resample_to_match tests
using Test, Lyr

@testset "resample_to_match" begin
    @testset "Resample to same grid: preserves active count" begin
        data = Dict(coord(0,0,0) => 1.0f0, coord(1,0,0) => 2.0f0, coord(0,1,0) => 3.0f0)
        grid = build_grid(data, 0.0f0; name="test")
        resampled = resample_to_match(grid, grid)
        @test active_voxel_count(resampled.tree) == active_voxel_count(grid.tree)
    end

    @testset "Resample to different voxel size" begin
        data = Dict(coord(0,0,0) => 1.0f0, coord(1,0,0) => 1.0f0,
                    coord(0,1,0) => 1.0f0, coord(1,1,0) => 1.0f0)
        grid = build_grid(data, 0.0f0; voxel_size=1.0)
        # Resample to 2x coarser
        resampled = resample_to_match(grid; voxel_size=2.0)
        @test active_voxel_count(resampled.tree) > 0
    end

    @testset "Empty grid resample" begin
        grid = build_grid(Dict{Coord, Float32}(), 0.0f0)
        resampled = resample_to_match(grid; voxel_size=2.0)
        @test active_voxel_count(resampled.tree) == 0
    end
end
