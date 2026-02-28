using Test
using Lyr
using Lyr: Coord, coord, BBox, active_voxels, get_value, is_active,
           active_voxel_count, leaf_count, build_grid, GRID_FOG_VOLUME,
           change_background, activate, deactivate, copy_to_dense, copy_from_dense,
           comp_max, comp_min, comp_sum, comp_mul, comp_replace, clip,
           leaves, off_indices, on_indices, leaf_offset

# ---------------------------------------------------------------------------
# Helper: build a small test grid from a list of (coord, value) pairs
# ---------------------------------------------------------------------------
function make_grid(pairs::Vector{Pair{Coord, T}}, bg::T;
                   name="test", voxel_size=1.0) where T
    data = Dict{Coord, T}(pairs)
    build_grid(data, bg; name=name, grid_class=GRID_FOG_VOLUME, voxel_size=voxel_size)
end

# ---------------------------------------------------------------------------
# Collect active voxels from a grid into a sorted vector for easy comparison
# ---------------------------------------------------------------------------
function collect_active(grid)
    pairs = collect(active_voxels(grid.tree))
    sort!(pairs; by = p -> (p[1].x, p[1].y, p[1].z))
    pairs
end

@testset "GridOps" begin

    # ======================================================================
    # change_background
    # ======================================================================
    @testset "change_background" begin
        bg = 0.0f0
        pairs = [coord(0,0,0) => 1.0f0, coord(1,0,0) => 2.0f0, coord(2,0,0) => 3.0f0]
        g = make_grid(pairs, bg)

        # Change background from 0 to -1
        g2 = change_background(g, -1.0f0)

        # Active voxel count should be the same
        @test active_voxel_count(g2.tree) == 3

        # Active values unchanged
        @test get_value(g2.tree, coord(0,0,0)) == 1.0f0
        @test get_value(g2.tree, coord(1,0,0)) == 2.0f0
        @test get_value(g2.tree, coord(2,0,0)) == 3.0f0

        # New background is -1
        @test g2.tree.background == -1.0f0

        # Metadata preserved
        @test g2.name == "test"
        @test g2.grid_class == GRID_FOG_VOLUME
    end

    # ======================================================================
    # activate
    # ======================================================================
    @testset "activate" begin
        # Build a grid with 3 active voxels; inactive voxels in the same leaf
        # hold the background value (0.0). We want to activate voxels whose
        # stored value matches a target.
        bg = 0.0f0
        pairs = [coord(0,0,0) => 1.0f0, coord(1,0,0) => 2.0f0]
        g = make_grid(pairs, bg)
        @test active_voxel_count(g.tree) == 2

        # Activate voxels with value == 0.0 (the background fill in leaf slots)
        g2 = activate(g, 0.0f0)

        # Should now have more active voxels (the inactive leaf slots that held 0.0)
        @test active_voxel_count(g2.tree) >= active_voxel_count(g.tree)

        # Original active voxels still present
        @test get_value(g2.tree, coord(0,0,0)) == 1.0f0
        @test get_value(g2.tree, coord(1,0,0)) == 2.0f0

        # Activating a value that no voxel holds should not change count
        g3 = activate(g, 99.0f0)
        @test active_voxel_count(g3.tree) == active_voxel_count(g.tree)
    end

    # ======================================================================
    # deactivate
    # ======================================================================
    @testset "deactivate" begin
        bg = 0.0f0
        pairs = [coord(0,0,0) => 1.0f0, coord(1,0,0) => 2.0f0, coord(2,0,0) => 1.0f0]
        g = make_grid(pairs, bg)
        @test active_voxel_count(g.tree) == 3

        # Deactivate all voxels with value 1.0
        g2 = deactivate(g, 1.0f0)
        @test active_voxel_count(g2.tree) == 1
        @test is_active(g2.tree, coord(1,0,0))
        @test get_value(g2.tree, coord(1,0,0)) == 2.0f0
        @test !is_active(g2.tree, coord(0,0,0))
        @test !is_active(g2.tree, coord(2,0,0))

        # Deactivate a value that doesn't exist should keep all
        g3 = deactivate(g, 99.0f0)
        @test active_voxel_count(g3.tree) == 3
    end

    # ======================================================================
    # copy_to_dense
    # ======================================================================
    @testset "copy_to_dense" begin
        bg = 0.0f0
        pairs = [coord(2,3,4) => 5.0f0, coord(3,3,4) => 7.0f0]
        g = make_grid(pairs, bg)

        bbox = BBox(coord(0,0,0), coord(7,7,7))
        arr = copy_to_dense(g, bbox)

        @test size(arr) == (8, 8, 8)
        # Background fill
        @test arr[1, 1, 1] == 0.0f0
        # Known values (array indices = coord - bbox.min + 1)
        @test arr[3, 4, 5] == 5.0f0   # coord(2,3,4) → (2-0+1, 3-0+1, 4-0+1) = (3,4,5)
        @test arr[4, 4, 5] == 7.0f0   # coord(3,3,4)

        # Small bbox that just covers one voxel
        bbox2 = BBox(coord(2,3,4), coord(2,3,4))
        arr2 = copy_to_dense(g, bbox2)
        @test size(arr2) == (1, 1, 1)
        @test arr2[1, 1, 1] == 5.0f0
    end

    # ======================================================================
    # copy_from_dense
    # ======================================================================
    @testset "copy_from_dense" begin
        bg = 0.0f0
        arr = zeros(Float32, 4, 4, 4)
        arr[2, 3, 4] = 10.0f0
        arr[1, 1, 1] = 20.0f0

        g = copy_from_dense(arr, bg; bbox_min=coord(10, 20, 30))

        @test active_voxel_count(g.tree) == 2
        @test get_value(g.tree, coord(11, 22, 33)) == 10.0f0  # (2-1+10, 3-1+20, 4-1+30)
        @test get_value(g.tree, coord(10, 20, 30)) == 20.0f0  # (1-1+10, 1-1+20, 1-1+30)

        # Background coords not stored
        @test !is_active(g.tree, coord(12, 20, 30))
    end

    # ======================================================================
    # Round-trip: copy_to_dense -> copy_from_dense
    # ======================================================================
    @testset "dense round-trip" begin
        bg = 0.0f0
        # Use values != background so round-trip preserves all active voxels
        pairs = [coord(i, 0, 0) => Float32(i + 1) for i in 0:4]
        g = make_grid(pairs, bg)

        bbox = BBox(coord(0, 0, 0), coord(7, 7, 7))
        arr = copy_to_dense(g, bbox)
        g2 = copy_from_dense(arr, bg; bbox_min=coord(0, 0, 0))

        # Same active voxels after round-trip
        @test active_voxel_count(g2.tree) == active_voxel_count(g.tree)
        for (c, v) in active_voxels(g.tree)
            @test get_value(g2.tree, c) == v
        end
    end

    # ======================================================================
    # comp_max
    # ======================================================================
    @testset "comp_max" begin
        bg = 0.0f0
        a = make_grid([coord(0,0,0) => 3.0f0, coord(1,0,0) => 1.0f0], bg)
        b = make_grid([coord(0,0,0) => 2.0f0, coord(2,0,0) => 5.0f0], bg)

        g = comp_max(a, b)
        @test active_voxel_count(g.tree) == 3
        @test get_value(g.tree, coord(0,0,0)) == 3.0f0   # max(3, 2)
        @test get_value(g.tree, coord(1,0,0)) == 1.0f0   # only in a
        @test get_value(g.tree, coord(2,0,0)) == 5.0f0   # only in b
    end

    # ======================================================================
    # comp_min
    # ======================================================================
    @testset "comp_min" begin
        bg = 0.0f0
        a = make_grid([coord(0,0,0) => 3.0f0, coord(1,0,0) => 1.0f0], bg)
        b = make_grid([coord(0,0,0) => 2.0f0, coord(2,0,0) => 5.0f0], bg)

        g = comp_min(a, b)
        @test active_voxel_count(g.tree) == 3
        @test get_value(g.tree, coord(0,0,0)) == 2.0f0   # min(3, 2)
        @test get_value(g.tree, coord(1,0,0)) == 1.0f0   # only in a
        @test get_value(g.tree, coord(2,0,0)) == 5.0f0   # only in b
    end

    # ======================================================================
    # comp_sum
    # ======================================================================
    @testset "comp_sum" begin
        bg = 0.0f0
        a = make_grid([coord(0,0,0) => 3.0f0, coord(1,0,0) => 1.0f0], bg)
        b = make_grid([coord(0,0,0) => 2.0f0, coord(2,0,0) => 5.0f0], bg)

        g = comp_sum(a, b)
        @test active_voxel_count(g.tree) == 3
        @test get_value(g.tree, coord(0,0,0)) == 5.0f0   # 3 + 2
        @test get_value(g.tree, coord(1,0,0)) == 1.0f0   # only in a
        @test get_value(g.tree, coord(2,0,0)) == 5.0f0   # only in b
    end

    # ======================================================================
    # comp_mul
    # ======================================================================
    @testset "comp_mul" begin
        bg = 0.0f0
        a = make_grid([coord(0,0,0) => 3.0f0, coord(1,0,0) => 4.0f0], bg)
        b = make_grid([coord(0,0,0) => 2.0f0, coord(2,0,0) => 5.0f0], bg)

        g = comp_mul(a, b)
        @test active_voxel_count(g.tree) == 3
        @test get_value(g.tree, coord(0,0,0)) == 6.0f0   # 3 * 2
        @test get_value(g.tree, coord(1,0,0)) == 4.0f0   # only in a
        @test get_value(g.tree, coord(2,0,0)) == 5.0f0   # only in b
    end

    # ======================================================================
    # comp_replace
    # ======================================================================
    @testset "comp_replace" begin
        bg = 0.0f0
        a = make_grid([coord(0,0,0) => 3.0f0, coord(1,0,0) => 4.0f0], bg)
        b = make_grid([coord(0,0,0) => 99.0f0, coord(2,0,0) => 5.0f0], bg)

        g = comp_replace(a, b)
        @test active_voxel_count(g.tree) == 3
        @test get_value(g.tree, coord(0,0,0)) == 99.0f0  # b overwrites a
        @test get_value(g.tree, coord(1,0,0)) == 4.0f0   # only in a, kept
        @test get_value(g.tree, coord(2,0,0)) == 5.0f0   # only in b
    end

    # ======================================================================
    # clip (BBox)
    # ======================================================================
    @testset "clip (BBox)" begin
        bg = 0.0f0
        pairs = [coord(i, 0, 0) => Float32(i + 1) for i in 0:5]
        g = make_grid(pairs, bg)
        @test active_voxel_count(g.tree) == 6

        bbox = BBox(coord(1, 0, 0), coord(3, 0, 0))
        g2 = clip(g, bbox)
        @test active_voxel_count(g2.tree) == 3
        @test is_active(g2.tree, coord(1,0,0))
        @test is_active(g2.tree, coord(2,0,0))
        @test is_active(g2.tree, coord(3,0,0))
        @test !is_active(g2.tree, coord(0,0,0))
        @test !is_active(g2.tree, coord(4,0,0))
        @test !is_active(g2.tree, coord(5,0,0))

        # Clip with empty bbox → empty grid
        bbox_empty = BBox(coord(100, 100, 100), coord(101, 101, 101))
        g3 = clip(g, bbox_empty)
        @test active_voxel_count(g3.tree) == 0
    end

    # ======================================================================
    # clip (mask grid)
    # ======================================================================
    @testset "clip (mask grid)" begin
        bg = 0.0f0
        # Source grid with 4 voxels
        src = make_grid([coord(0,0,0) => 1.0f0, coord(1,0,0) => 2.0f0,
                         coord(2,0,0) => 3.0f0, coord(3,0,0) => 4.0f0], bg)

        # Mask grid with 2 active voxels (values don't matter, only activity)
        mask = make_grid([coord(1,0,0) => 99.0f0, coord(3,0,0) => 99.0f0], bg)

        g = clip(src, mask)
        @test active_voxel_count(g.tree) == 2
        @test get_value(g.tree, coord(1,0,0)) == 2.0f0
        @test get_value(g.tree, coord(3,0,0)) == 4.0f0
        @test !is_active(g.tree, coord(0,0,0))
        @test !is_active(g.tree, coord(2,0,0))
    end

    # ======================================================================
    # Edge cases
    # ======================================================================
    @testset "empty grid operations" begin
        bg = 0.0f0
        empty_data = Dict{Coord, Float32}()
        empty_g = build_grid(empty_data, bg)

        # change_background on empty grid
        g2 = change_background(empty_g, -1.0f0)
        @test g2.tree.background == -1.0f0
        @test active_voxel_count(g2.tree) == 0

        # comp_max with empty + non-empty
        pairs = [coord(0,0,0) => 1.0f0]
        non_empty = make_grid(pairs, bg)
        g3 = comp_max(empty_g, non_empty)
        @test active_voxel_count(g3.tree) == 1
        @test get_value(g3.tree, coord(0,0,0)) == 1.0f0

        # clip empty
        g4 = clip(empty_g, BBox(coord(0,0,0), coord(10,10,10)))
        @test active_voxel_count(g4.tree) == 0

        # deactivate on empty
        g5 = deactivate(empty_g, 0.0f0)
        @test active_voxel_count(g5.tree) == 0
    end

    # ======================================================================
    # Compositing with negative values
    # ======================================================================
    @testset "compositing with negative values" begin
        bg = 0.0f0
        a = make_grid([coord(0,0,0) => -3.0f0], bg)
        b = make_grid([coord(0,0,0) => -5.0f0], bg)

        @test get_value(comp_max(a, b).tree, coord(0,0,0)) == -3.0f0
        @test get_value(comp_min(a, b).tree, coord(0,0,0)) == -5.0f0
        @test get_value(comp_sum(a, b).tree, coord(0,0,0)) == -8.0f0
        @test get_value(comp_mul(a, b).tree, coord(0,0,0)) == 15.0f0
    end

    # ======================================================================
    # Multi-leaf compositing (voxels in different leaves)
    # ======================================================================
    @testset "multi-leaf compositing" begin
        bg = 0.0f0
        # coords in different leaves (separated by > 8 in one axis)
        a = make_grid([coord(0,0,0) => 1.0f0, coord(16,0,0) => 2.0f0], bg)
        b = make_grid([coord(0,0,0) => 10.0f0, coord(32,0,0) => 3.0f0], bg)

        g = comp_sum(a, b)
        @test active_voxel_count(g.tree) == 3
        @test get_value(g.tree, coord(0,0,0)) == 11.0f0
        @test get_value(g.tree, coord(16,0,0)) == 2.0f0
        @test get_value(g.tree, coord(32,0,0)) == 3.0f0
    end

end  # @testset "GridOps"
