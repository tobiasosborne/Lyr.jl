@testset "Accessors" begin
    # Helper to create a simple tree with a single leaf
    function make_simple_tree()
        # Create a leaf with some values
        leaf_mask_words = ntuple(i -> i == 1 ? UInt64(0xff) : UInt64(0), 8)  # First 8 bits active
        leaf_mask = LeafMask(leaf_mask_words)
        values = ntuple(i -> Float32(i), 512)
        leaf = LeafNode{Float32}(coord(0, 0, 0), leaf_mask, values)

        # Create Internal1 containing the leaf
        i1_child_mask = Internal1Mask((UInt64(1), ntuple(_ -> UInt64(0), 63)...))
        i1_value_mask = Internal1Mask()
        i1_table = Union{LeafNode{Float32}, Tile{Float32}}[leaf]
        internal1 = InternalNode1{Float32}(coord(0, 0, 0), i1_child_mask, i1_value_mask, i1_table)

        # Create Internal2 containing Internal1
        i2_child_mask = Internal2Mask((UInt64(1), ntuple(_ -> UInt64(0), 511)...))
        i2_value_mask = Internal2Mask()
        i2_table = Union{InternalNode1{Float32}, Tile{Float32}}[internal1]
        internal2 = InternalNode2{Float32}(coord(0, 0, 0), i2_child_mask, i2_value_mask, i2_table)

        # Create root
        background = -1.0f0
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
            coord(0, 0, 0) => internal2
        )
        RootNode{Float32}(background, table)
    end

    @testset "get_value" begin
        tree = make_simple_tree()

        # Query active voxel
        @test get_value(tree, coord(0, 0, 0)) == 1.0f0
        @test get_value(tree, coord(1, 0, 0)) == 2.0f0

        # Query background (outside any node)
        @test get_value(tree, coord(10000, 0, 0)) == -1.0f0
    end

    @testset "is_active" begin
        tree = make_simple_tree()

        # Active voxels (first 8 in leaf)
        @test is_active(tree, coord(0, 0, 0)) == true
        @test is_active(tree, coord(7, 0, 0)) == true

        # Inactive voxel in leaf
        @test is_active(tree, coord(0, 1, 0)) == false

        # Outside tree
        @test is_active(tree, coord(10000, 0, 0)) == false
    end

    @testset "leaf_count" begin
        tree = make_simple_tree()
        @test leaf_count(tree) == 1

        # Empty tree
        empty_tree = RootNode{Float32}(0.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        @test leaf_count(empty_tree) == 0
    end

    @testset "Empty tree queries" begin
        empty_tree = RootNode{Float32}(5.0f0, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())

        @test get_value(empty_tree, coord(0, 0, 0)) == 5.0f0
        @test is_active(empty_tree, coord(0, 0, 0)) == false
        @test leaf_count(empty_tree) == 0
    end

    @testset "Tile queries" begin
        # Tree with a tile at root level
        tile = Tile{Float32}(42.0f0, true)
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}(
            coord(0, 0, 0) => tile
        )
        tree = RootNode{Float32}(0.0f0, table)

        @test get_value(tree, coord(0, 0, 0)) == 42.0f0
        @test is_active(tree, coord(0, 0, 0)) == true
    end
end
