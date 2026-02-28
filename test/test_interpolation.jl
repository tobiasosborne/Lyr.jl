@testset "Interpolation" begin
    # Create a tree with known values for testing
    function make_test_tree()
        # Fill a 2x2x2 region with values 1-8
        # OpenVDB convention: index = x*64 + y*8 + z (1-based array access: +1)
        values = ntuple(i -> Float32(0), 512)
        values = Base.setindex(values, 1.0f0, 1)    # (0,0,0) → 0+1
        values = Base.setindex(values, 2.0f0, 65)   # (1,0,0) → 64+1
        values = Base.setindex(values, 3.0f0, 9)    # (0,1,0) → 8+1
        values = Base.setindex(values, 4.0f0, 73)   # (1,1,0) → 72+1
        values = Base.setindex(values, 5.0f0, 2)    # (0,0,1) → 1+1
        values = Base.setindex(values, 6.0f0, 66)   # (1,0,1) → 65+1
        values = Base.setindex(values, 7.0f0, 10)   # (0,1,1) → 9+1
        values = Base.setindex(values, 8.0f0, 74)   # (1,1,1) → 73+1

        # Create mask with these 8 positions active
        mask_words = ntuple(_ -> UInt64(0), 8)
        mask = LeafMask(mask_words)
        leaf = LeafNode{Float32}(coord(0, 0, 0), mask, values)

        # Build tree structure
        i1_child_mask = Internal1Mask((UInt64(1), ntuple(_ -> UInt64(0), 63)...))
        i1_value_mask = Internal1Mask()
        internal1 = InternalNode1{Float32}(coord(0, 0, 0), i1_child_mask, i1_value_mask, [leaf], Tile{Float32}[])

        i2_child_mask = Internal2Mask((UInt64(1), ntuple(_ -> UInt64(0), 511)...))
        i2_value_mask = Internal2Mask()
        internal2 = InternalNode2{Float32}(coord(0, 0, 0), i2_child_mask, i2_value_mask, [internal1], Tile{Float32}[])

        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(coord(0, 0, 0) => internal2)
        RootNode{Float32}(0.0f0, table)
    end

    @testset "sample_nearest" begin
        tree = make_test_tree()

        # At integer coords
        @test sample_nearest(tree, (0.0, 0.0, 0.0)) == 1.0f0
        @test sample_nearest(tree, (1.0, 0.0, 0.0)) == 2.0f0

        # Near integer coords (should round)
        @test sample_nearest(tree, (0.4, 0.0, 0.0)) == 1.0f0
        @test sample_nearest(tree, (0.6, 0.0, 0.0)) == 2.0f0
    end

    @testset "sample_trilinear at voxel center" begin
        tree = make_test_tree()

        # At integer coordinates, should equal voxel value
        @test sample_trilinear(tree, (0.0, 0.0, 0.0)) ≈ 1.0f0
        @test sample_trilinear(tree, (1.0, 0.0, 0.0)) ≈ 2.0f0
    end

    @testset "sample_trilinear interpolation" begin
        tree = make_test_tree()

        # At face center (mean of 2)
        # Between (0,0,0)=1 and (1,0,0)=2
        @test sample_trilinear(tree, (0.5, 0.0, 0.0)) ≈ 1.5f0

        # At edge center (mean of 4)
        # Between corners (0,0,0), (1,0,0), (0,1,0), (1,1,0)
        @test sample_trilinear(tree, (0.5, 0.5, 0.0)) ≈ (1 + 2 + 3 + 4) / 4.0f0

        # At cube center (mean of 8)
        @test sample_trilinear(tree, (0.5, 0.5, 0.5)) ≈ (1 + 2 + 3 + 4 + 5 + 6 + 7 + 8) / 8.0f0
    end

    @testset "sample_world" begin
        tree = make_test_tree()
        transform = UniformScaleTransform(2.0)  # Each voxel is 2 world units
        grid = Grid{Float32}("test", GRID_UNKNOWN, transform, tree)

        # World coord (0,0,0) -> index (0,0,0)
        @test sample_world(grid, (0.0, 0.0, 0.0), NearestInterpolation()) == 1.0f0

        # World coord (2,0,0) -> index (1,0,0)
        @test sample_world(grid, (2.0, 0.0, 0.0), NearestInterpolation()) == 2.0f0
    end

    @testset "sample_trilinear boundary fallback" begin
        # When a corner is at ±background, trilinear should fall back to nearest.
        # Build a tree where background = 3.0 and one voxel has value 1.0.
        # Sampling between that voxel and an empty neighbor should return nearest, not interpolated.
        values = ntuple(_ -> Float32(0), 512)
        values = Base.setindex(values, 1.0f0, 1)  # (0,0,0) = 1.0

        mask_words = (UInt64(1), ntuple(_ -> UInt64(0), 7)...)  # bit 0 on
        mask = LeafMask(mask_words)
        leaf = LeafNode{Float32}(coord(0, 0, 0), mask, values)

        i1_child_mask = Internal1Mask((UInt64(1), ntuple(_ -> UInt64(0), 63)...))
        i1_value_mask = Internal1Mask()
        internal1 = InternalNode1{Float32}(coord(0, 0, 0), i1_child_mask, i1_value_mask, [leaf], Tile{Float32}[])

        i2_child_mask = Internal2Mask((UInt64(1), ntuple(_ -> UInt64(0), 511)...))
        i2_value_mask = Internal2Mask()
        internal2 = InternalNode2{Float32}(coord(0, 0, 0), i2_child_mask, i2_value_mask, [internal1], Tile{Float32}[])

        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(coord(0, 0, 0) => internal2)
        tree = RootNode{Float32}(3.0f0, table)  # background = 3.0

        # At (0,0,0): v000=1.0, but neighbor (1,0,0)=0.0 which is not ±bg.
        # At (0.5,0,0): v000=1.0, v100=0.0 — neither is ±bg → normal interpolation
        @test sample_trilinear(tree, (0.5, 0.0, 0.0)) ≈ 0.5f0

        # At (0.5, 0.0, 7.5): samples reach outside leaf into background (3.0).
        # v001 at z=8 is outside leaf → returns background 3.0 → fallback to nearest
        val = sample_trilinear(tree, (0.0, 0.0, 7.5))
        @test val == sample_nearest(tree, (0.0, 0.0, 7.5))
    end

    @testset "sample_quadratic: smooth field" begin
        # Build a grid with a smooth quadratic field f(x,y,z) = x² + y² + z²
        # Quadratic B-spline should approximate this well
        data = Dict{Coord, Float32}()
        for x in -5:5, y in -5:5, z in -5:5
            data[coord(x, y, z)] = Float32(x^2 + y^2 + z^2)
        end
        tree = build_grid(data, 0.0f0; name="quadratic_field").tree

        # At grid points: quadratic B-spline doesn't interpolate exactly
        # (it smooths), but should be close
        @test abs(sample_quadratic(tree, (0.0, 0.0, 0.0)) - 0.0f0) < 1.0f0

        # At half-integer points: should be smooth
        val = sample_quadratic(tree, (0.5, 0.0, 0.0))
        @test val isa Float32
        @test val >= 0.0f0  # squared values are non-negative

        # Symmetry: f(1,0,0) ≈ f(-1,0,0)
        @test sample_quadratic(tree, (1.0, 0.0, 0.0)) ≈
              sample_quadratic(tree, (-1.0, 0.0, 0.0))
    end

    @testset "sample_quadratic: constant field exact" begin
        data = Dict{Coord, Float32}()
        for x in -3:3, y in -3:3, z in -3:3
            data[coord(x, y, z)] = 42.0f0
        end
        tree = build_grid(data, 0.0f0; name="const").tree

        # Constant field: all weights sum to 1, so result = 42 exactly
        @test sample_quadratic(tree, (0.0, 0.0, 0.0)) ≈ 42.0f0
        @test sample_quadratic(tree, (0.3, -0.2, 0.4)) ≈ 42.0f0
        @test sample_quadratic(tree, (1.0, 1.0, 1.0)) ≈ 42.0f0
    end

    @testset "sample_quadratic: smoother than trilinear" begin
        # Spike in a field of 1s (non-zero to avoid background fallback)
        data = Dict{Coord, Float32}()
        for x in -3:3, y in -3:3, z in -3:3
            data[coord(x, y, z)] = 1.0f0
        end
        data[coord(0, 0, 0)] = 100.0f0
        tree = build_grid(data, 999.0f0; name="spike").tree

        # At grid point: trilinear = exact, quadratic = smoothed
        tri_center = sample_trilinear(tree, (0.0, 0.0, 0.0))
        quad_center = sample_quadratic(tree, (0.0, 0.0, 0.0))
        @test tri_center ≈ 100.0f0
        @test quad_center < 100.0f0  # B-spline smooths toward neighbors
        @test quad_center > 1.0f0    # but still above neighbor values
    end

    @testset "sample_quadratic: NTuple convenience" begin
        data = Dict{Coord, Float32}()
        for x in -2:2, y in -2:2, z in -2:2
            data[coord(x, y, z)] = 1.0f0
        end
        tree = build_grid(data, 0.0f0; name="ones").tree

        # NTuple overload should work
        @test sample_quadratic(tree, (0.0, 0.0, 0.0)) ≈ 1.0f0
    end

    @testset "sample_world with QuadraticInterpolation" begin
        data = Dict{Coord, Float32}()
        for x in -3:3, y in -3:3, z in -3:3
            data[coord(x, y, z)] = 5.0f0
        end
        grid = build_grid(data, 0.0f0; name="const", voxel_size=2.0)

        # World coord (0,0,0) -> index (0,0,0)
        @test sample_world(grid, (0.0, 0.0, 0.0), QuadraticInterpolation()) ≈ 5.0f0
    end

    @testset "gradient" begin
        tree = make_test_tree()

        # Gradient at center of our 2x2x2 cube
        # This tests central differences
        grad = gradient(tree, coord(1, 1, 1))

        # Gradient should be defined (may include background values)
        @test grad isa NTuple{3, Float32}
    end
end
