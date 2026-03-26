# Field Protocol error path / boundary input tests
using Test, Lyr

@testset "Field Protocol error paths" begin
    @testset "ScalarField3D with NaN-producing function" begin
        f_nan = ScalarField3D((x,y,z) -> NaN,
            BoxDomain(SVec3d(-1,-1,-1), SVec3d(1,1,1)), 1.0)
        v = evaluate(f_nan, 0.0, 0.0, 0.0)
        @test isnan(v)
        # Voxelize should still produce a grid (may contain NaN values)
        grid = voxelize(f_nan)
        @test grid isa Grid{Float32}
    end

    @testset "ScalarField3D with Inf-producing function" begin
        f_inf = ScalarField3D((x,y,z) -> x == 0 ? Inf : 1.0/x,
            BoxDomain(SVec3d(-1,-1,-1), SVec3d(1,1,1)), 0.5)
        grid = voxelize(f_inf)
        @test grid isa Grid{Float32}
    end

    @testset "Very small characteristic_scale" begin
        # Tiny scale → many voxels, but voxelize should handle it (capped internally)
        f = ScalarField3D((x,y,z) -> exp(-(x^2+y^2+z^2)),
            BoxDomain(SVec3d(-1,-1,-1), SVec3d(1,1,1)), 0.01)
        @test characteristic_scale(f) == 0.01
        # Don't actually voxelize (would create enormous grid), just verify field works
        @test isfinite(evaluate(f, 0.0, 0.0, 0.0))
    end

    @testset "Very large characteristic_scale" begin
        f = ScalarField3D((x,y,z) -> 1.0,
            BoxDomain(SVec3d(-1,-1,-1), SVec3d(1,1,1)), 1000.0)
        grid = voxelize(f)
        @test grid isa Grid{Float32}
        # Large scale → few voxels
        @test active_voxel_count(grid.tree) > 0
    end

    @testset "VectorField3D basic" begin
        vf = VectorField3D((x,y,z) -> SVec3d(x, y, z),
            BoxDomain(SVec3d(-2,-2,-2), SVec3d(2,2,2)), 1.0)
        val = evaluate(vf, 1.0, 2.0, 3.0)
        @test val == SVec3d(1.0, 2.0, 3.0)
    end

    @testset "visualize produces valid image" begin
        f = ScalarField3D((x,y,z) -> exp(-(x^2+y^2+z^2)/2),
            BoxDomain(SVec3d(-3,-3,-3), SVec3d(3,3,3)), 1.5)
        img = visualize(f)
        @test size(img, 1) > 0
        @test size(img, 2) > 0
        @test all(p -> all(c -> 0.0 <= c <= 1.0, p), img)
    end
end
