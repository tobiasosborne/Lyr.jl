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

    @testset "read_tile_value Vec3f (NTuple{3,Float32})" begin
        # Vec3f: (1.0, 2.0, 3.0) as little-endian Float32s
        bytes = UInt8[
            0x00, 0x00, 0x80, 0x3f,  # 1.0f0
            0x00, 0x00, 0x00, 0x40,  # 2.0f0
            0x00, 0x00, 0x40, 0x40   # 3.0f0
        ]
        val, pos = read_tile_value(NTuple{3, Float32}, bytes, 1)
        @test val == (1.0f0, 2.0f0, 3.0f0)
        @test pos == 13
    end

    @testset "read_tile_value Vec3d (NTuple{3,Float64})" begin
        # Vec3d: (1.0, 2.0, 3.0) as little-endian Float64s
        bytes = UInt8[
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f,  # 1.0
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40,  # 2.0
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x40   # 3.0
        ]
        val, pos = read_tile_value(NTuple{3, Float64}, bytes, 1)
        @test val == (1.0, 2.0, 3.0)
        @test pos == 25
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
