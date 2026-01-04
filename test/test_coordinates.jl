@testset "Coordinates" begin
    @testset "Coord struct properties" begin
        # Coord should be a proper struct, not a type alias
        @test isa(Coord, DataType)
        @test !isa(Coord, UnionAll)  # Not a type alias

        c = coord(1, 2, 3)

        # Named field access
        @test c.x == Int32(1)
        @test c.y == Int32(2)
        @test c.z == Int32(3)

        # Index access for backward compatibility
        @test c[1] == Int32(1)
        @test c[2] == Int32(2)
        @test c[3] == Int32(3)

        # Hashable (for use as Dict key)
        d = Dict{Coord, Int}()
        d[c] = 42
        @test d[c] == 42
        @test d[coord(1, 2, 3)] == 42  # Same values should hash the same

        # Length and iteration
        @test length(c) == 3
        @test collect(c) == [Int32(1), Int32(2), Int32(3)]
    end

    @testset "Construction" begin
        c = coord(1, 2, 3)
        @test c == coord(1, 2, 3)
        @test c.x == Int32(1) && c.y == Int32(2) && c.z == Int32(3)

        # Negative values
        c = coord(-1, -2, -3)
        @test c == coord(-1, -2, -3)
        @test c.x == Int32(-1) && c.y == Int32(-2) && c.z == Int32(-3)
    end

    @testset "Arithmetic" begin
        a = coord(1, 2, 3)
        b = coord(4, 5, 6)

        @test a + b == coord(5, 7, 9)
        @test b - a == coord(3, 3, 3)
        @test min(a, b) == a
        @test max(a, b) == b

        # Mixed signs
        c = coord(-1, 5, -3)
        d = coord(2, -2, 4)
        @test min(c, d) == coord(-1, -2, -3)
        @test max(c, d) == coord(2, 5, 4)
    end

    @testset "leaf_origin" begin
        # Origin at (0,0,0)
        @test leaf_origin(coord(0, 0, 0)) == coord(0, 0, 0)
        @test leaf_origin(coord(7, 7, 7)) == coord(0, 0, 0)
        @test leaf_origin(coord(1, 2, 3)) == coord(0, 0, 0)

        # Origin at (8,0,0)
        @test leaf_origin(coord(8, 0, 0)) == coord(8, 0, 0)
        @test leaf_origin(coord(15, 7, 7)) == coord(8, 0, 0)

        # Negative coordinates
        @test leaf_origin(coord(-1, -1, -1)) == coord(-8, -8, -8)
        @test leaf_origin(coord(-8, -8, -8)) == coord(-8, -8, -8)
        @test leaf_origin(coord(-9, 0, 0)) == coord(-16, 0, 0)
    end

    @testset "internal1_origin" begin
        # 128 = 8 * 16
        @test internal1_origin(coord(0, 0, 0)) == coord(0, 0, 0)
        @test internal1_origin(coord(127, 127, 127)) == coord(0, 0, 0)
        @test internal1_origin(coord(128, 0, 0)) == coord(128, 0, 0)

        # Negative
        @test internal1_origin(coord(-1, -1, -1)) == coord(-128, -128, -128)
    end

    @testset "internal2_origin" begin
        # 4096 = 8 * 16 * 32
        @test internal2_origin(coord(0, 0, 0)) == coord(0, 0, 0)
        @test internal2_origin(coord(4095, 4095, 4095)) == coord(0, 0, 0)
        @test internal2_origin(coord(4096, 0, 0)) == coord(4096, 0, 0)

        # Negative
        @test internal2_origin(coord(-1, -1, -1)) == coord(-4096, -4096, -4096)
    end

    @testset "leaf_offset" begin
        # Corner cases
        @test leaf_offset(coord(0, 0, 0)) == 0
        @test leaf_offset(coord(7, 7, 7)) == 7 + 7*8 + 7*64  # 511

        # x varies fastest
        @test leaf_offset(coord(1, 0, 0)) == 1
        @test leaf_offset(coord(0, 1, 0)) == 8
        @test leaf_offset(coord(0, 0, 1)) == 64

        # Works with any origin
        @test leaf_offset(coord(8, 0, 0)) == 0
        @test leaf_offset(coord(9, 0, 0)) == 1
    end

    @testset "internal1_child_index" begin
        @test internal1_child_index(coord(0, 0, 0)) == 0
        @test internal1_child_index(coord(8, 0, 0)) == 1  # One leaf over
        @test internal1_child_index(coord(0, 8, 0)) == 16
        @test internal1_child_index(coord(0, 0, 8)) == 256

        # Max index
        @test internal1_child_index(coord(120, 120, 120)) == 15 + 15*16 + 15*256  # 4095
    end

    @testset "internal2_child_index" begin
        @test internal2_child_index(coord(0, 0, 0)) == 0
        @test internal2_child_index(coord(128, 0, 0)) == 1  # One Internal1 over
        @test internal2_child_index(coord(0, 128, 0)) == 32
        @test internal2_child_index(coord(0, 0, 128)) == 1024
    end

    @testset "BBox" begin
        bb = BBox(coord(0, 0, 0), coord(10, 10, 10))

        @test Lyr.contains(bb, coord(5, 5, 5))
        @test Lyr.contains(bb, coord(0, 0, 0))
        @test Lyr.contains(bb, coord(10, 10, 10))
        @test !Lyr.contains(bb, coord(-1, 0, 0))
        @test !Lyr.contains(bb, coord(11, 0, 0))
    end

    @testset "BBox intersects" begin
        a = BBox(coord(0, 0, 0), coord(10, 10, 10))
        b = BBox(coord(5, 5, 5), coord(15, 15, 15))
        c = BBox(coord(20, 20, 20), coord(30, 30, 30))

        @test intersects(a, b)
        @test intersects(b, a)
        @test !intersects(a, c)

        # Touch at corner
        d = BBox(coord(10, 10, 10), coord(20, 20, 20))
        @test intersects(a, d)
    end

    @testset "BBox union" begin
        a = BBox(coord(0, 0, 0), coord(10, 10, 10))
        b = BBox(coord(5, 5, 5), coord(15, 15, 15))

        u = union(a, b)
        @test u.min == coord(0, 0, 0)
        @test u.max == coord(15, 15, 15)
    end

    @testset "BBox volume" begin
        bb = BBox(coord(0, 0, 0), coord(9, 9, 9))
        @test volume(bb) == 10 * 10 * 10

        # Single voxel
        bb = BBox(coord(0, 0, 0), coord(0, 0, 0))
        @test volume(bb) == 1
    end

    @testset "Int32 extremes" begin
        max_c = coord(typemax(Int32), typemax(Int32), typemax(Int32))
        min_c = coord(typemin(Int32), typemin(Int32), typemin(Int32))

        # Operations shouldn't overflow
        @test leaf_origin(max_c) isa Coord
        @test leaf_origin(min_c) isa Coord
    end
end
