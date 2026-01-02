@testset "Binary Primitives" begin
    @testset "read_u8" begin
        bytes = UInt8[0x42, 0xff, 0x00]
        @test read_u8(bytes, 1) == (0x42, 2)
        @test read_u8(bytes, 2) == (0xff, 3)
        @test read_u8(bytes, 3) == (0x00, 4)
        @test_throws BoundsError read_u8(bytes, 4)
    end

    @testset "read_u32_le" begin
        # Little-endian: least significant byte first
        bytes = UInt8[0x01, 0x02, 0x03, 0x04]
        val, pos = read_u32_le(bytes, 1)
        @test val == 0x04030201
        @test pos == 5

        # Zero
        bytes = UInt8[0x00, 0x00, 0x00, 0x00]
        @test read_u32_le(bytes, 1)[1] == 0x00000000

        # Max value
        bytes = UInt8[0xff, 0xff, 0xff, 0xff]
        @test read_u32_le(bytes, 1)[1] == 0xffffffff

        # Boundary test
        bytes = UInt8[0x00, 0x01, 0x02, 0x03, 0x04]
        @test read_u32_le(bytes, 2)[1] == 0x04030201
    end

    @testset "read_u64_le" begin
        bytes = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        val, pos = read_u64_le(bytes, 1)
        @test val == 0x0807060504030201
        @test pos == 9
    end

    @testset "read_i32_le" begin
        # Positive
        bytes = UInt8[0x01, 0x00, 0x00, 0x00]
        @test read_i32_le(bytes, 1)[1] == Int32(1)

        # Negative (-1)
        bytes = UInt8[0xff, 0xff, 0xff, 0xff]
        @test read_i32_le(bytes, 1)[1] == Int32(-1)

        # Min value
        bytes = UInt8[0x00, 0x00, 0x00, 0x80]
        @test read_i32_le(bytes, 1)[1] == typemin(Int32)
    end

    @testset "read_i64_le" begin
        bytes = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        @test read_i64_le(bytes, 1)[1] == Int64(-1)
    end

    @testset "read_f32_le" begin
        # 1.0f0 in IEEE 754
        bytes = UInt8[0x00, 0x00, 0x80, 0x3f]
        val, pos = read_f32_le(bytes, 1)
        @test val == 1.0f0
        @test pos == 5

        # -1.0f0
        bytes = UInt8[0x00, 0x00, 0x80, 0xbf]
        @test read_f32_le(bytes, 1)[1] == -1.0f0

        # 0.0f0
        bytes = UInt8[0x00, 0x00, 0x00, 0x00]
        @test read_f32_le(bytes, 1)[1] == 0.0f0
    end

    @testset "read_f64_le" begin
        # 1.0 in IEEE 754
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f]
        @test read_f64_le(bytes, 1)[1] == 1.0
    end

    @testset "read_bytes" begin
        bytes = UInt8[0x01, 0x02, 0x03, 0x04, 0x05]
        result, pos = read_bytes(bytes, 2, 3)
        @test result == UInt8[0x02, 0x03, 0x04]
        @test pos == 5

        # Empty read
        result, pos = read_bytes(bytes, 1, 0)
        @test result == UInt8[]
        @test pos == 1
    end

    @testset "read_cstring" begin
        bytes = UInt8[0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00]  # "Hello\0"
        str, pos = read_cstring(bytes, 1)
        @test str == "Hello"
        @test pos == 7

        # Empty string
        bytes = UInt8[0x00]
        @test read_cstring(bytes, 1)[1] == ""

        # String at offset
        bytes = UInt8[0x00, 0x41, 0x42, 0x00]  # "\0AB\0"
        str, pos = read_cstring(bytes, 2)
        @test str == "AB"
        @test pos == 5
    end

    @testset "read_string_with_size" begin
        # Size (5) + "Hello"
        bytes = UInt8[0x05, 0x00, 0x00, 0x00, 0x48, 0x65, 0x6c, 0x6c, 0x6f]
        str, pos = read_string_with_size(bytes, 1)
        @test str == "Hello"
        @test pos == 10

        # Empty string
        bytes = UInt8[0x00, 0x00, 0x00, 0x00]
        @test read_string_with_size(bytes, 1)[1] == ""
    end

    @testset "Insufficient bytes" begin
        bytes = UInt8[0x01, 0x02]
        @test_throws BoundsError read_u32_le(bytes, 1)
        @test_throws BoundsError read_u64_le(bytes, 1)
        @test_throws BoundsError read_f32_le(bytes, 1)
    end
end
