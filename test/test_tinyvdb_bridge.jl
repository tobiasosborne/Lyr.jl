using Test
using Lyr
using Lyr.TinyVDB: TinyVDB, NodeMask, set_on!

@testset "TinyVDB Bridge" begin

    @testset "convert_tinyvdb_coord" begin
        tc = TinyVDB.Coord(Int32(1), Int32(-2), Int32(3))
        lc = Lyr.convert_tinyvdb_coord(tc)
        @test lc == Coord(Int32(1), Int32(-2), Int32(3))
        @test lc isa Lyr.Coord
    end

    @testset "convert_tinyvdb_mask" begin
        # Create a TinyVDB mask with known bits
        tiny_mask = NodeMask(Int32(3))
        set_on!(tiny_mask, 0)
        set_on!(tiny_mask, 255)
        set_on!(tiny_mask, 511)

        lyr_mask = Lyr.convert_tinyvdb_mask(tiny_mask, LeafMask)
        @test lyr_mask isa LeafMask
        @test Lyr.is_on(lyr_mask, 0)
        @test Lyr.is_on(lyr_mask, 255)
        @test Lyr.is_on(lyr_mask, 511)
        @test Lyr.count_on(lyr_mask) == 3
    end

    @testset "convert_tinyvdb_leaf" begin
        # Build a leaf with known values
        value_mask = NodeMask(Int32(3))
        set_on!(value_mask, 0)
        set_on!(value_mask, 7)
        leaf = TinyVDB.LeafNodeData(value_mask, collect(Float32, 1.0:512.0))

        origin = Coord(Int32(0), Int32(0), Int32(0))
        lyr_leaf = Lyr.convert_tinyvdb_leaf(leaf, origin)

        @test lyr_leaf isa LeafNode{Float32}
        @test lyr_leaf.origin == origin
        @test lyr_leaf.values[1] == 1.0f0
        @test lyr_leaf.values[512] == 512.0f0
        @test Lyr.is_on(lyr_leaf.value_mask, 0)
        @test Lyr.is_on(lyr_leaf.value_mask, 7)
    end

    @testset "convert_tinyvdb_internal1" begin
        # Build a minimal I1 with one leaf child at position 0
        leaf_value_mask = NodeMask(Int32(3))
        set_on!(leaf_value_mask, 0)
        leaf = TinyVDB.LeafNodeData(leaf_value_mask, collect(Float32, 1.0:512.0))

        child_mask = NodeMask(Int32(4))
        set_on!(child_mask, 0)  # child at position 0
        i1 = TinyVDB.InternalNodeData(Int32(4), child_mask, NodeMask(Int32(4)),
                                       Float32[], [(Int32(0), leaf)])

        origin = Coord(Int32(0), Int32(0), Int32(0))
        lyr_i1 = Lyr.convert_tinyvdb_internal1(i1, origin, 3.0f0)

        @test lyr_i1 isa InternalNode1{Float32}
        @test lyr_i1.origin == origin
        @test Lyr.count_on(lyr_i1.child_mask) == 1
        @test length(lyr_i1.table) == 1  # 1 child, 0 tiles
        @test lyr_i1.table[1] isa LeafNode{Float32}
        # Leaf at I1 position 0 → origin = parent + (0,0,0)*8 = (0,0,0)
        @test lyr_i1.table[1].origin == Coord(Int32(0), Int32(0), Int32(0))
    end

    @testset "convert_tinyvdb_grid - cube.vdb end-to-end" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @warn "cube.vdb not found, skipping integration test"
            return
        end

        # Parse with TinyVDB
        tiny = TinyVDB.parse_tinyvdb(cube_path)
        @test !isempty(tiny.grids)

        # Convert to Lyr types
        tiny_grid = first(values(tiny.grids))
        grid = convert_tinyvdb_grid(tiny_grid)

        @test grid isa Grid{Float32}
        @test grid.tree isa RootNode{Float32}
        @test grid.transform isa UniformScaleTransform

        # Structural tests
        @test leaf_count(grid.tree) > 0
        @test active_voxel_count(grid.tree) > 0

        # Bounding box
        bbox = active_bounding_box(grid.tree)
        @test bbox !== nothing
        @test bbox isa BBox

        # Value access: first 5 active voxels
        count = 0
        for (coord, val) in active_voxels(grid.tree)
            @test get_value(grid.tree, coord) == val
            @test is_active(grid.tree, coord)
            count += 1
            count >= 5 && break
        end
        @test count == 5

        # Background for far-away coordinate
        @test get_value(grid.tree, Coord(Int32(99999), Int32(99999), Int32(99999))) == grid.tree.background
    end

    @testset "render cube.vdb" begin
        cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
        if !isfile(cube_path)
            @warn "cube.vdb not found, skipping render test"
            return
        end

        tiny = TinyVDB.parse_tinyvdb(cube_path)
        grid = convert_tinyvdb_grid(first(values(tiny.grids)))

        cam = Camera((15.0, 10.0, 15.0), (0.0, 0.0, 0.0), (0.0, 1.0, 0.0), 60.0)
        pixels = render_image(grid, cam, 16, 16; max_steps=500)

        @test size(pixels) == (16, 16)

        # At least some pixels should be non-background (hit the cube)
        bg = (0.1, 0.1, 0.15)
        non_bg = count(p -> p != bg, pixels)
        @test non_bg > 0
    end

end
