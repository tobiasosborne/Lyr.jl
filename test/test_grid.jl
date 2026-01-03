@testset "Grid" begin
    @testset "GridClass enum" begin
        @test GRID_LEVEL_SET isa GridClass
        @test GRID_FOG_VOLUME isa GridClass
        @test GRID_STAGGERED isa GridClass
        @test GRID_UNKNOWN isa GridClass
    end

    @testset "parse_grid_class" begin
        @test parse_grid_class("level set") == GRID_LEVEL_SET
        @test parse_grid_class("Level Set") == GRID_LEVEL_SET
        @test parse_grid_class("levelset") == GRID_LEVEL_SET

        @test parse_grid_class("fog volume") == GRID_FOG_VOLUME
        @test parse_grid_class("fogvolume") == GRID_FOG_VOLUME

        @test parse_grid_class("staggered") == GRID_STAGGERED

        @test parse_grid_class("unknown") == GRID_UNKNOWN
        @test parse_grid_class("something else") == GRID_UNKNOWN
    end

    @testset "Grid construction" begin
        # Create a minimal tree
        background = 0.0f0
        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}()
        tree = RootNode{Float32}(background, table)

        transform = UniformScaleTransform(1.0)

        grid = Grid{Float32}("test_grid", GRID_LEVEL_SET, transform, tree)

        @test grid.name == "test_grid"
        @test grid.grid_class == GRID_LEVEL_SET
        @test grid.transform isa UniformScaleTransform
        @test grid.tree.background == 0.0f0
    end

    @testset "Grid with different types" begin
        # Float64 grid
        tree64 = RootNode{Float64}(0.0, Dict{Coord, Union{InternalNode2{Float64}, Tile{Float64}}}())
        grid64 = Grid{Float64}("density", GRID_FOG_VOLUME, UniformScaleTransform(0.1), tree64)
        @test grid64 isa Grid{Float64}

        # Vec3f grid
        tree_vec = RootNode{NTuple{3, Float32}}(
            (0.0f0, 0.0f0, 0.0f0),
            Dict{Coord, Union{InternalNode2{NTuple{3, Float32}}, Tile{NTuple{3, Float32}}}}()
        )
        grid_vec = Grid{NTuple{3, Float32}}("velocity", GRID_STAGGERED, UniformScaleTransform(0.1), tree_vec)
        @test grid_vec isa Grid{NTuple{3, Float32}}
    end
end
