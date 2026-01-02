@testset "Topology" begin
    @testset "LeafTopology" begin
        # Create bytes for a leaf topology
        # origin (3 x i32) + mask (64 bytes)
        bytes = zeros(UInt8, 12 + 64)

        # Set origin to (8, 16, 24)
        bytes[1:4] = reinterpret(UInt8, [Int32(8)])
        bytes[5:8] = reinterpret(UInt8, [Int32(16)])
        bytes[9:12] = reinterpret(UInt8, [Int32(24)])

        # Set first bit of mask
        bytes[13] = 0x01

        topo, pos = read_leaf_topology(bytes, 1)

        @test topo.origin == coord(8, 16, 24)
        @test is_on(topo.value_mask, 0)
        @test count_on(topo.value_mask) == 1
        @test pos == 77  # 12 + 64 + 1
    end

    @testset "Empty RootTopology" begin
        # background_active (1) + tile_count (4) + child_count (4)
        bytes = zeros(UInt8, 9)
        # All zeros = no tiles, no children, background inactive

        topo, pos = read_root_topology(bytes, 1)

        @test topo.background_active == false
        @test topo.tile_count == 0
        @test topo.child_count == 0
        @test isempty(topo.entries)
        @test pos == 10
    end

    @testset "RootTopology with tile" begin
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

        topo, pos = read_root_topology(bytes, 1)

        @test topo.tile_count == 1
        @test topo.child_count == 0
        @test length(topo.entries) == 1

        origin, active, child = topo.entries[1]
        @test origin == coord(100, 200, 300)
        @test active == true
        @test child === nothing
    end

    @testset "Topology types" begin
        @test LeafTopology <: Any
        @test Internal1Topology <: Any
        @test Internal2Topology <: Any
        @test RootTopology <: Any
    end
end
