using Test
using StaticArrays

@testset "Voxelize" begin

    @testset "ScalarField3D — Gaussian blob" begin
        field = ScalarField3D(
            (x, y, z) -> exp(-(x^2 + y^2 + z^2)),
            BoxDomain((-3.0, -3.0, -3.0), (3.0, 3.0, 3.0)),
            1.0
        )

        @testset "basic voxelization" begin
            grid = voxelize(field)
            @test grid isa Grid{Float32}
            @test active_voxel_count(grid.tree) > 0
        end

        @testset "auto voxel_size from characteristic_scale" begin
            # characteristic_scale = 1.0, auto = 1.0 / 5.0 = 0.2
            grid = voxelize(field)
            vs = voxel_size(grid.transform)
            @test vs[1] ≈ 0.2
        end

        @testset "custom voxel_size" begin
            grid = voxelize(field; voxel_size=0.5)
            vs = voxel_size(grid.transform)
            @test vs[1] ≈ 0.5
        end

        @testset "peak at center" begin
            grid = voxelize(field; voxel_size=0.5, normalize=false)
            acc = ValueAccessor(grid.tree)
            center_val = get_value(acc, coord(0, 0, 0))
            # exp(0) = 1.0
            @test center_val > 0.9f0
        end

        @testset "normalized values in [0,1]" begin
            grid = voxelize(field; normalize=true)
            acc = ValueAccessor(grid.tree)
            for (c, v) in active_voxels(grid.tree)
                @test 0.0f0 <= v <= 1.0f0
            end
        end

        @testset "normalize=false preserves raw values" begin
            grid = voxelize(field; normalize=false, threshold=0.0)
            acc = ValueAccessor(grid.tree)
            center_val = get_value(acc, coord(0, 0, 0))
            # Should be close to 1.0 (the raw peak)
            @test center_val ≈ 1.0f0 atol=0.05f0
        end

        @testset "threshold filters small values" begin
            # With high threshold, fewer voxels survive
            grid_low = voxelize(field; threshold=0.01)
            grid_high = voxelize(field; threshold=0.5)
            @test active_voxel_count(grid_high.tree) < active_voxel_count(grid_low.tree)
        end

        @testset "fog volume grid class" begin
            grid = voxelize(field)
            @test grid.grid_class == GRID_FOG_VOLUME
        end
    end

    @testset "ScalarField3D — constant field" begin
        field = ScalarField3D(
            (x, y, z) -> 0.5,
            BoxDomain((0.0, 0.0, 0.0), (2.0, 2.0, 2.0)),
            1.0
        )

        @testset "all voxels have same normalized value" begin
            grid = voxelize(field; voxel_size=1.0, normalize=true)
            for (c, v) in active_voxels(grid.tree)
                @test v ≈ 1.0f0  # all equal → max is 0.5, normalized = 1.0
            end
        end
    end

    @testset "ScalarField3D — zero field" begin
        field = ScalarField3D(
            (x, y, z) -> 0.0,
            BoxDomain((-1.0, -1.0, -1.0), (1.0, 1.0, 1.0)),
            0.5
        )

        @testset "empty grid" begin
            grid = voxelize(field)
            @test active_voxel_count(grid.tree) == 0
        end
    end

    @testset "VectorField3D — magnitude" begin
        field = VectorField3D(
            (x, y, z) -> SVec3d(3.0, 4.0, 0.0),
            BoxDomain((-1.0, -1.0, -1.0), (1.0, 1.0, 1.0)),
            1.0
        )

        @testset "voxelizes magnitude" begin
            grid = voxelize(field; voxel_size=1.0, normalize=false, threshold=0.0)
            acc = ValueAccessor(grid.tree)
            val = get_value(acc, coord(0, 0, 0))
            # magnitude of (3,4,0) = 5.0
            @test val ≈ 5.0f0 atol=0.01f0
        end
    end

    @testset "ComplexScalarField3D — abs2" begin
        field = ComplexScalarField3D(
            (x, y, z) -> complex(3.0, 4.0),
            BoxDomain((-1.0, -1.0, -1.0), (1.0, 1.0, 1.0)),
            1.0
        )

        @testset "voxelizes abs2" begin
            grid = voxelize(field; voxel_size=1.0, normalize=false, threshold=0.0)
            acc = ValueAccessor(grid.tree)
            val = get_value(acc, coord(0, 0, 0))
            # |3+4i|² = 25.0
            @test val ≈ 25.0f0 atol=0.01f0
        end
    end

    @testset "ParticleField — Gaussian splatting" begin
        # 8 particles at cube corners
        positions = [
            SVec3d(0, 0, 0), SVec3d(5, 0, 0),
            SVec3d(0, 5, 0), SVec3d(0, 0, 5),
            SVec3d(5, 5, 0), SVec3d(5, 0, 5),
            SVec3d(0, 5, 5), SVec3d(5, 5, 5)
        ]
        field = ParticleField(positions)

        @testset "produces non-empty grid" begin
            grid = voxelize(field; voxel_size=1.0, sigma=1.5, cutoff_sigma=2.0)
            @test active_voxel_count(grid.tree) > 0
        end

        @testset "normalized values" begin
            grid = voxelize(field; voxel_size=1.0, sigma=1.5, cutoff_sigma=2.0)
            for (c, v) in active_voxels(grid.tree)
                @test 0.0f0 <= v <= 1.0f0
            end
        end

        @testset "empty particles" begin
            field = ParticleField(SVec3d[])
            grid = voxelize(field; voxel_size=1.0)
            @test active_voxel_count(grid.tree) == 0
        end
    end

    @testset "Round-trip: voxelize matches evaluate" begin
        field = ScalarField3D(
            (x, y, z) -> exp(-(x^2 + y^2 + z^2) / 2.0),
            BoxDomain((-2.0, -2.0, -2.0), (2.0, 2.0, 2.0)),
            1.0
        )
        vs = 0.5
        grid = voxelize(field; voxel_size=vs, normalize=false, threshold=0.0)
        acc = ValueAccessor(grid.tree)

        # Sample at a few grid points and compare
        for (ix, iy, iz) in [(0,0,0), (1,0,0), (0,1,1), (2,2,2)]
            x, y, z = ix * vs, iy * vs, iz * vs
            expected = Float32(evaluate(field, x, y, z))
            actual = get_value(acc, coord(ix, iy, iz))
            @test actual ≈ expected atol=Float32(1e-5)
        end
    end
end
