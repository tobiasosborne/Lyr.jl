@testset "Tree Types" begin
    @testset "LeafNode construction" begin
        origin = coord(0, 0, 0)
        mask = LeafMask()
        values = ntuple(_ -> 0.0f0, 512)

        leaf = LeafNode{Float32}(origin, mask, values)
        @test leaf.origin == origin
        @test is_empty(leaf.value_mask)
        @test length(leaf.values) == 512
    end

    @testset "Tile construction" begin
        tile = Tile{Float32}(1.5f0, true)
        @test tile.value == 1.5f0
        @test tile.active == true

        tile = Tile{Float32}(0.0f0, false)
        @test tile.active == false
    end

    @testset "InternalNode1 construction" begin
        origin = coord(0, 0, 0)
        child_mask = Internal1Mask()
        value_mask = Internal1Mask()
        table = Union{LeafNode{Float32}, Tile{Float32}}[]

        node = InternalNode1{Float32}(origin, child_mask, value_mask, table)
        @test node.origin == origin
        @test is_empty(node.child_mask)
    end

    @testset "InternalNode2 construction" begin
        origin = coord(0, 0, 0)
        child_mask = Internal2Mask()
        value_mask = Internal2Mask()
        table = Union{InternalNode1{Float32}, Tile{Float32}}[]

        node = InternalNode2{Float32}(origin, child_mask, value_mask, table)
        @test node.origin == origin
    end

    @testset "RootNode construction" begin
        background = 0.0f0
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}()

        root = RootNode{Float32}(background, table)
        @test root.background == 0.0f0
        @test isempty(root.table)
    end

    @testset "Tree type alias" begin
        @test Tree{Float32} == RootNode{Float32}
    end

    @testset "Type stability" begin
        # Create a simple tree structure
        leaf = LeafNode{Float32}(
            coord(0, 0, 0),
            LeafMask(),
            ntuple(_ -> 1.0f0, 512)
        )
        @test leaf isa LeafNode{Float32}

        tile = Tile{Float64}(2.0, true)
        @test tile isa Tile{Float64}
    end

    @testset "Different value types" begin
        # Float64
        leaf64 = LeafNode{Float64}(
            coord(0, 0, 0),
            LeafMask(),
            ntuple(_ -> 1.0, 512)
        )
        @test leaf64 isa LeafNode{Float64}

        # Vec3f
        leaf_vec = LeafNode{NTuple{3, Float32}}(
            coord(0, 0, 0),
            LeafMask(),
            ntuple(_ -> (0.0f0, 0.0f0, 0.0f0), 512)
        )
        @test leaf_vec isa LeafNode{NTuple{3, Float32}}
    end
end
