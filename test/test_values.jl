@testset "Values" begin
    @testset "read_tile_value Float32" begin
        bytes = UInt8[0x00, 0x00, 0x80, 0x3f]  # 1.0f0
        val, pos = read_tile_value(Float32, bytes, 1)
        @test val == 1.0f0
        @test pos == 5
    end

    @testset "read_tile_value Float64" begin
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f]  # 1.0
        val, pos = read_tile_value(Float64, bytes, 1)
        @test val == 1.0
        @test pos == 9
    end

    @testset "Value types" begin
        # Float32
        values32 = ntuple(_ -> 0.0f0, 512)
        @test eltype(values32) == Float32

        # Float64
        values64 = ntuple(_ -> 0.0, 512)
        @test eltype(values64) == Float64

        # Vec3f
        values_vec = ntuple(_ -> (0.0f0, 0.0f0, 0.0f0), 512)
        @test eltype(values_vec) == NTuple{3, Float32}
    end
end
