@testset "Topology" begin
    @testset "LeafTopology - origin from parent" begin
        # Leaf topology: only value mask (64 bytes), NO origin in bytes
        bytes = zeros(UInt8, 64)

        # Set first bit of mask
        bytes[1] = 0x01

        # Origin is passed in, not read from bytes
        parent_origin = coord(8, 16, 24)
        topo, pos = read_leaf_topology(bytes, 1, parent_origin)

        @test topo.origin == coord(8, 16, 24)
        @test is_on(topo.value_mask, 0)
        @test count_on(topo.value_mask) == 1
        @test pos == 65  # 64 bytes mask + 1
    end

    @testset "Empty RootTopology - fog volume" begin
        # background_active (1) + tile_count (4) + child_count (4)
        bytes = zeros(UInt8, 9)
        # All zeros = no tiles, no children, background inactive

        topo, pos = read_root_topology(bytes, 1, GRID_FOG_VOLUME)

        @test topo.background_active == false
        @test topo.tile_count == 0
        @test topo.child_count == 0
        @test isempty(topo.entries)
        @test pos == 10
    end

    @testset "Empty RootTopology - level set" begin
        # Level sets have NO background_active byte
        # tile_count (4) + child_count (4) = 8 bytes
        bytes = zeros(UInt8, 8)

        topo, pos = read_root_topology(bytes, 1, GRID_LEVEL_SET)

        @test topo.background_active == false  # Always false for level sets
        @test topo.tile_count == 0
        @test topo.child_count == 0
        @test isempty(topo.entries)
        @test pos == 9  # One less byte consumed
    end

    @testset "RootTopology with tile - fog volume" begin
        # background_active (1) + tile_count (4) + child_count (4)
        # + tile: origin (12) + active (1)
        bytes = zeros(UInt8, 9 + 13)

        # Set tile_count = 1
        bytes[2:5] = reinterpret(UInt8, [UInt32(1)])

        # Tile origin (100, 200, 300)
        bytes[10:13] = reinterpret(UInt8, [Int32(100)])
        bytes[14:17] = reinterpret(UInt8, [Int32(200)])
        bytes[18:21] = reinterpret(UInt8, [Int32(300)])

        # Tile active = true
        bytes[22] = 0x01

        topo, pos = read_root_topology(bytes, 1, GRID_FOG_VOLUME)

        @test topo.tile_count == 1
        @test topo.child_count == 0
        @test length(topo.entries) == 1

        origin, active, child = topo.entries[1]
        @test origin == coord(100, 200, 300)
        @test active == true
        @test child === nothing
    end

    @testset "Child origin computation" begin
        # Test Internal2 -> Internal1 origin computation
        # Internal2 at (0,0,0), child at index 0 should be at (0,0,0)
        @test child_origin_internal2(coord(0, 0, 0), 0) == coord(0, 0, 0)

        # Child at index 1 should be at (128, 0, 0)
        @test child_origin_internal2(coord(0, 0, 0), 1) == coord(128, 0, 0)

        # Child at index 32 should be at (0, 128, 0)
        @test child_origin_internal2(coord(0, 0, 0), 32) == coord(0, 128, 0)

        # Child at index 1024 should be at (0, 0, 128)
        @test child_origin_internal2(coord(0, 0, 0), 1024) == coord(0, 0, 128)

        # Test Internal1 -> Leaf origin computation
        # Internal1 at (0,0,0), child at index 0 should be at (0,0,0)
        @test child_origin_internal1(coord(0, 0, 0), 0) == coord(0, 0, 0)

        # Child at index 1 should be at (8, 0, 0)
        @test child_origin_internal1(coord(0, 0, 0), 1) == coord(8, 0, 0)

        # Child at index 16 should be at (0, 8, 0)
        @test child_origin_internal1(coord(0, 0, 0), 16) == coord(0, 8, 0)

        # Child at index 256 should be at (0, 0, 8)
        @test child_origin_internal1(coord(0, 0, 0), 256) == coord(0, 0, 8)

        # Test with non-zero parent origin
        @test child_origin_internal1(coord(128, 256, 384), 17) == coord(128 + 8, 256 + 8, 384)
    end

    @testset "Topology types" begin
        @test LeafTopology <: Any
        @test Internal1Topology <: Any
        @test Internal2Topology <: Any
        @test RootTopology <: Any
    end
end
