@testset "Base.show methods" begin
    SAMPLE_DIR = joinpath(@__DIR__, "fixtures", "samples")

    @testset "Mask show" begin
        # Empty mask
        m = Mask{512,8}(ntuple(_ -> UInt64(0), 8))
        s = sprint(show, m)
        @test occursin("Mask{512}", s)
        @test occursin("0/512 on", s)

        # Full mask
        m = Mask{512,8}(ntuple(_ -> ~UInt64(0), 8))
        s = sprint(show, m)
        @test occursin("512/512 on", s)

        # Partial mask
        m = Mask{512,8}(ntuple(i -> i == 1 ? UInt64(0b1011) : UInt64(0), 8))
        s = sprint(show, m)
        @test occursin("3/512 on", s)
    end

    @testset "LeafNode show" begin
        origin = coord(0, 8, 16)
        mask = Mask{512,8}(ntuple(i -> i == 1 ? UInt64(0b111) : UInt64(0), 8))
        vals = ntuple(_ -> 1.0f0, 512)
        leaf = LeafNode{Float32}(origin, mask, vals)
        s = sprint(show, leaf)
        @test occursin("LeafNode{Float32}", s)
        @test occursin("(0, 8, 16)", s)
        @test occursin("3/512 active", s)
    end

    @testset "Tile show" begin
        t = Tile{Float32}(3.0f0, true)
        s = sprint(show, t)
        @test occursin("Tile{Float32}", s)
        @test occursin("active", s)
        @test occursin("3.0", s)

        t2 = Tile{Float32}(0.0f0, false)
        s2 = sprint(show, t2)
        @test occursin("inactive", s2)
    end

    @testset "Tree/RootNode show" begin
        bg = 3.0f0
        tree = RootNode{Float32}(bg, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        s = sprint(show, tree)
        @test occursin("Tree{Float32}", s)
        @test occursin("background=3.0", s)
        @test occursin("0 root entries", s)
    end

    @testset "Grid show" begin
        bg = 0.0f0
        tree = RootNode{Float32}(bg, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        transform = UniformScaleTransform(0.5)
        grid = Grid{Float32}("density", GRID_FOG_VOLUME, transform, tree)
        s = sprint(show, grid)
        @test occursin("Grid{Float32}", s)
        @test occursin("density", s)
        @test occursin("GRID_FOG_VOLUME", s)
    end

    @testset "VDBFile show" begin
        bg = 0.0f0
        tree = RootNode{Float32}(bg, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
        transform = UniformScaleTransform(0.5)
        grid = Grid{Float32}("density", GRID_FOG_VOLUME, transform, tree)

        header = VDBHeader(UInt32(224), UInt32(11), UInt32(0), true, NoCompression(), false, "test-uuid")
        vdb = VDBFile(header, [grid])
        s = sprint(show, vdb)
        @test occursin("VDBFile", s)
        @test occursin("v224", s)
        @test occursin("1 grid", s)
        @test occursin("density", s)
    end

    @testset "VDBFile show with real file" begin
        cube_path = joinpath(SAMPLE_DIR, "cube.vdb")
        isfile(cube_path) || return
        vdb = parse_vdb(cube_path)
        s = sprint(show, vdb)
        @test occursin("VDBFile", s)
        @test occursin("grid", s)
    end
end
