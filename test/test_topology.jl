@testset "Topology" begin
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
end
