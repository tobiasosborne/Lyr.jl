@testset "Topology" begin
    @testset "Child origin computation" begin
        # Test Internal2 -> Internal1 origin computation (OpenVDB: x*1024 + y*32 + z)
        # Internal2 at (0,0,0), child at index 0 should be at (0,0,0)
        @test child_origin_internal2(coord(0, 0, 0), 0) == coord(0, 0, 0)

        # Child at index 1: z=1 → (0, 0, 128)
        @test child_origin_internal2(coord(0, 0, 0), 1) == coord(0, 0, 128)

        # Child at index 32: y=1 → (0, 128, 0)
        @test child_origin_internal2(coord(0, 0, 0), 32) == coord(0, 128, 0)

        # Child at index 1024: x=1 → (128, 0, 0)
        @test child_origin_internal2(coord(0, 0, 0), 1024) == coord(128, 0, 0)

        # Test Internal1 -> Leaf origin computation (OpenVDB: x*256 + y*16 + z)
        # Internal1 at (0,0,0), child at index 0 should be at (0,0,0)
        @test child_origin_internal1(coord(0, 0, 0), 0) == coord(0, 0, 0)

        # Child at index 1: z=1 → (0, 0, 8)
        @test child_origin_internal1(coord(0, 0, 0), 1) == coord(0, 0, 8)

        # Child at index 16: y=1 → (0, 8, 0)
        @test child_origin_internal1(coord(0, 0, 0), 16) == coord(0, 8, 0)

        # Child at index 256: x=1 → (8, 0, 0)
        @test child_origin_internal1(coord(0, 0, 0), 256) == coord(8, 0, 0)

        # Test with non-zero parent origin
        # index 17 = 0*256 + 1*16 + 1 → ix=0, iy=1, iz=1
        @test child_origin_internal1(coord(128, 256, 384), 17) == coord(128, 256 + 8, 384 + 8)
    end
end
