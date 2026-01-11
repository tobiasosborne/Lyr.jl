# test_tinyvdb.jl - Tests for TinyVDB module
#
# Following TDD: These tests are written BEFORE the implementation.

using Test

# Include the module directly for testing
include(joinpath(@__DIR__, "..", "src", "TinyVDB", "TinyVDB.jl"))
using .TinyVDB

@testset "TinyVDB Binary Primitives" begin

    @testset "read_u8" begin
        # Basic single byte read
        bytes = UInt8[0x42]
        val, pos = read_u8(bytes, 1)
        @test val == 0x42
        @test pos == 2

        # Read from middle of buffer
        bytes = UInt8[0x00, 0xFF, 0x00]
        val, pos = read_u8(bytes, 2)
        @test val == 0xFF
        @test pos == 3

        # Edge values
        bytes = UInt8[0x00, 0xFF]
        val, _ = read_u8(bytes, 1)
        @test val == 0x00
        val, _ = read_u8(bytes, 2)
        @test val == 0xFF

        # Bounds checking
        bytes = UInt8[0x42]
        @test_throws BoundsError read_u8(bytes, 2)
        @test_throws BoundsError read_u8(bytes, 0)
    end

    @testset "read_u32" begin
        # Little-endian: 0x04030201 stored as [0x01, 0x02, 0x03, 0x04]
        bytes = UInt8[0x01, 0x02, 0x03, 0x04]
        val, pos = read_u32(bytes, 1)
        @test val == 0x04030201
        @test pos == 5

        # Zero value
        bytes = UInt8[0x00, 0x00, 0x00, 0x00]
        val, _ = read_u32(bytes, 1)
        @test val == 0x00000000

        # Max value
        bytes = UInt8[0xFF, 0xFF, 0xFF, 0xFF]
        val, _ = read_u32(bytes, 1)
        @test val == 0xFFFFFFFF

        # Read from offset
        bytes = UInt8[0x00, 0x01, 0x02, 0x03, 0x04]
        val, pos = read_u32(bytes, 2)
        @test val == 0x04030201
        @test pos == 6

        # Bounds checking
        bytes = UInt8[0x01, 0x02, 0x03]
        @test_throws BoundsError read_u32(bytes, 1)
    end

    @testset "read_i32" begin
        # Positive value
        bytes = UInt8[0x01, 0x00, 0x00, 0x00]
        val, pos = read_i32(bytes, 1)
        @test val == Int32(1)
        @test pos == 5

        # Negative value (-1 in two's complement)
        bytes = UInt8[0xFF, 0xFF, 0xFF, 0xFF]
        val, _ = read_i32(bytes, 1)
        @test val == Int32(-1)

        # Negative value (-256)
        bytes = UInt8[0x00, 0xFF, 0xFF, 0xFF]
        val, _ = read_i32(bytes, 1)
        @test val == Int32(-256)

        # Min Int32
        bytes = UInt8[0x00, 0x00, 0x00, 0x80]
        val, _ = read_i32(bytes, 1)
        @test val == typemin(Int32)

        # Max Int32
        bytes = UInt8[0xFF, 0xFF, 0xFF, 0x7F]
        val, _ = read_i32(bytes, 1)
        @test val == typemax(Int32)
    end

    @testset "read_u64" begin
        # Little-endian: 0x0807060504030201
        bytes = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        val, pos = read_u64(bytes, 1)
        @test val == 0x0807060504030201
        @test pos == 9

        # Zero value
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        val, _ = read_u64(bytes, 1)
        @test val == UInt64(0)

        # Max value
        bytes = UInt8[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        val, _ = read_u64(bytes, 1)
        @test val == typemax(UInt64)

        # Bounds checking
        bytes = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
        @test_throws BoundsError read_u64(bytes, 1)
    end

    @testset "read_i64" begin
        # Positive value
        bytes = UInt8[0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        val, pos = read_i64(bytes, 1)
        @test val == Int64(1)
        @test pos == 9

        # Negative value (-1)
        bytes = UInt8[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        val, _ = read_i64(bytes, 1)
        @test val == Int64(-1)

        # Min Int64
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80]
        val, _ = read_i64(bytes, 1)
        @test val == typemin(Int64)

        # Max Int64
        bytes = UInt8[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]
        val, _ = read_i64(bytes, 1)
        @test val == typemax(Int64)
    end

    @testset "read_f32" begin
        # 1.0f0 in IEEE 754: 0x3F800000
        bytes = UInt8[0x00, 0x00, 0x80, 0x3F]
        val, pos = read_f32(bytes, 1)
        @test val == 1.0f0
        @test pos == 5

        # 0.0f0
        bytes = UInt8[0x00, 0x00, 0x00, 0x00]
        val, _ = read_f32(bytes, 1)
        @test val == 0.0f0

        # -1.0f0: 0xBF800000
        bytes = UInt8[0x00, 0x00, 0x80, 0xBF]
        val, _ = read_f32(bytes, 1)
        @test val == -1.0f0

        # Pi approximation: 3.14159274f0 = 0x40490FDB
        bytes = UInt8[0xDB, 0x0F, 0x49, 0x40]
        val, _ = read_f32(bytes, 1)
        @test isapprox(val, Float32(pi), atol=1e-6)

        # Bounds checking
        bytes = UInt8[0x00, 0x00, 0x00]
        @test_throws BoundsError read_f32(bytes, 1)
    end

    @testset "read_f64" begin
        # 1.0 in IEEE 754: 0x3FF0000000000000
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F]
        val, pos = read_f64(bytes, 1)
        @test val == 1.0
        @test pos == 9

        # 0.0
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        val, _ = read_f64(bytes, 1)
        @test val == 0.0

        # -1.0: 0xBFF0000000000000
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0xBF]
        val, _ = read_f64(bytes, 1)
        @test val == -1.0

        # Pi: 0x400921FB54442D18
        bytes = UInt8[0x18, 0x2D, 0x44, 0x54, 0xFB, 0x21, 0x09, 0x40]
        val, _ = read_f64(bytes, 1)
        @test isapprox(val, pi, atol=1e-15)

        # Bounds checking
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        @test_throws BoundsError read_f64(bytes, 1)
    end

    @testset "read_string" begin
        # Empty string: length 0
        bytes = UInt8[0x00, 0x00, 0x00, 0x00]
        val, pos = read_string(bytes, 1)
        @test val == ""
        @test pos == 5

        # "Hello" - length 5 (little-endian) followed by ASCII
        bytes = UInt8[0x05, 0x00, 0x00, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F]
        val, pos = read_string(bytes, 1)
        @test val == "Hello"
        @test pos == 10

        # Single character
        bytes = UInt8[0x01, 0x00, 0x00, 0x00, 0x41]
        val, pos = read_string(bytes, 1)
        @test val == "A"
        @test pos == 6

        # Read from offset
        bytes = UInt8[0xFF, 0x03, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63]
        val, pos = read_string(bytes, 2)
        @test val == "abc"
        @test pos == 9

        # Bounds checking - length prefix incomplete
        bytes = UInt8[0x05, 0x00, 0x00]
        @test_throws BoundsError read_string(bytes, 1)

        # Bounds checking - string data incomplete
        bytes = UInt8[0x05, 0x00, 0x00, 0x00, 0x48, 0x65]
        @test_throws BoundsError read_string(bytes, 1)
    end

    @testset "Sequential reads" begin
        # Test reading multiple values in sequence
        # u8(0x42), u32(0x04030201), f32(1.0), string("Hi")
        bytes = UInt8[
            0x42,                          # u8
            0x01, 0x02, 0x03, 0x04,        # u32
            0x00, 0x00, 0x80, 0x3F,        # f32 (1.0)
            0x02, 0x00, 0x00, 0x00,        # string length
            0x48, 0x69                      # "Hi"
        ]

        pos = 1
        v1, pos = read_u8(bytes, pos)
        @test v1 == 0x42
        @test pos == 2

        v2, pos = read_u32(bytes, pos)
        @test v2 == 0x04030201
        @test pos == 6

        v3, pos = read_f32(bytes, pos)
        @test v3 == 1.0f0
        @test pos == 10

        v4, pos = read_string(bytes, pos)
        @test v4 == "Hi"
        @test pos == 16
    end

end

@testset "TinyVDB NodeMask" begin

    @testset "NodeMask constructor" begin
        # LOG2DIM=3 for leaf (8x8x8=512 bits, 8 words)
        mask = NodeMask(Int32(3))
        @test mask.log2dim == Int32(3)
        @test length(mask.words) == 8  # 512 >> 6 = 8
        @test all(w -> w == UInt64(0), mask.words)

        # LOG2DIM=4 for internal1 (16x16x16=4096 bits, 64 words)
        mask = NodeMask(Int32(4))
        @test mask.log2dim == Int32(4)
        @test length(mask.words) == 64  # 4096 >> 6 = 64
        @test all(w -> w == UInt64(0), mask.words)

        # LOG2DIM=5 for internal2 (32x32x32=32768 bits, 512 words)
        mask = NodeMask(Int32(5))
        @test mask.log2dim == Int32(5)
        @test length(mask.words) == 512  # 32768 >> 6 = 512
        @test all(w -> w == UInt64(0), mask.words)
    end

    @testset "is_on and set_on!" begin
        # Test with leaf mask (log2dim=3, 512 bits)
        mask = NodeMask(Int32(3))

        # Initially all bits are off (0-indexed)
        @test is_on(mask, 0) == false
        @test is_on(mask, 1) == false
        @test is_on(mask, 63) == false
        @test is_on(mask, 64) == false
        @test is_on(mask, 511) == false

        # Set bit 0
        set_on!(mask, 0)
        @test is_on(mask, 0) == true
        @test is_on(mask, 1) == false

        # Set bit 63 (last bit of first word)
        set_on!(mask, 63)
        @test is_on(mask, 63) == true
        @test is_on(mask, 62) == false
        @test is_on(mask, 64) == false

        # Set bit 64 (first bit of second word)
        set_on!(mask, 64)
        @test is_on(mask, 64) == true
        @test is_on(mask, 65) == false

        # Set bit 511 (last bit)
        set_on!(mask, 511)
        @test is_on(mask, 511) == true
        @test is_on(mask, 510) == false

        # Check word values
        @test mask.words[1] == (UInt64(1) << 0) | (UInt64(1) << 63)  # bits 0 and 63
        @test mask.words[2] == UInt64(1) << 0  # bit 64 -> bit 0 of word 2
        @test mask.words[8] == UInt64(1) << 63  # bit 511 -> bit 63 of word 8
    end

    @testset "count_on" begin
        # Empty mask
        mask = NodeMask(Int32(3))
        @test count_on(mask) == 0

        # Set some bits
        set_on!(mask, 0)
        @test count_on(mask) == 1

        set_on!(mask, 63)
        @test count_on(mask) == 2

        set_on!(mask, 64)
        @test count_on(mask) == 3

        set_on!(mask, 511)
        @test count_on(mask) == 4

        # All bits in one word
        mask2 = NodeMask(Int32(3))
        for i in 0:63
            set_on!(mask2, i)
        end
        @test count_on(mask2) == 64

        # All 512 bits
        mask3 = NodeMask(Int32(3))
        for i in 0:511
            set_on!(mask3, i)
        end
        @test count_on(mask3) == 512
    end

    @testset "read_mask" begin
        # Create bytes for a leaf mask (8 words = 64 bytes)
        # Word 0: bit 0 on = 0x0000000000000001
        # Word 7: bit 63 on = 0x8000000000000000
        bytes = zeros(UInt8, 64)

        # Word 0: set bit 0 (little-endian)
        bytes[1] = 0x01

        # Word 7 (bytes 57-64): set bit 63 -> 0x8000000000000000
        bytes[64] = 0x80  # High byte of word 7

        mask, pos = read_mask(bytes, 1, Int32(3))
        @test pos == 65  # 64 bytes read
        @test mask.log2dim == Int32(3)
        @test length(mask.words) == 8
        @test is_on(mask, 0) == true
        @test is_on(mask, 1) == false
        @test is_on(mask, 511) == true  # bit 63 of word 7
        @test is_on(mask, 510) == false
        @test count_on(mask) == 2

        # Test reading from offset
        padded_bytes = vcat(UInt8[0xFF, 0xFF], bytes)
        mask2, pos2 = read_mask(padded_bytes, 3, Int32(3))
        @test pos2 == 67
        @test count_on(mask2) == 2
        @test is_on(mask2, 0) == true
        @test is_on(mask2, 511) == true
    end

    @testset "read_mask internal nodes" begin
        # Test LOG2DIM=4 (64 words = 512 bytes)
        bytes = zeros(UInt8, 512)
        bytes[1] = 0xFF  # First 8 bits on
        mask, pos = read_mask(bytes, 1, Int32(4))
        @test pos == 513
        @test mask.log2dim == Int32(4)
        @test length(mask.words) == 64
        @test count_on(mask) == 8

        # Test LOG2DIM=5 (512 words = 4096 bytes)
        bytes = zeros(UInt8, 4096)
        bytes[1] = 0x01  # bit 0 on
        bytes[4096] = 0x80  # bit 32767 on (last bit)
        mask, pos = read_mask(bytes, 1, Int32(5))
        @test pos == 4097
        @test mask.log2dim == Int32(5)
        @test length(mask.words) == 512
        @test is_on(mask, 0) == true
        @test is_on(mask, 32767) == true
        @test count_on(mask) == 2
    end

end

@testset "TinyVDB Data Structures" begin

    @testset "Coord" begin
        # Basic construction
        c = Coord(1, 2, 3)
        @test c.x == Int32(1)
        @test c.y == Int32(2)
        @test c.z == Int32(3)

        # Negative values
        c = Coord(-100, -200, -300)
        @test c.x == Int32(-100)
        @test c.y == Int32(-200)
        @test c.z == Int32(-300)

        # Type stability
        @test typeof(c.x) == Int32
        @test typeof(c.y) == Int32
        @test typeof(c.z) == Int32
    end

    @testset "VDBHeader" begin
        # Basic construction
        h = VDBHeader(
            UInt32(222),      # file_version
            UInt32(9),        # major_version
            UInt32(0),        # minor_version
            true,             # is_compressed
            false,            # half_precision
            "test-uuid",      # uuid
            UInt64(256)       # offset_to_data
        )
        @test h.file_version == UInt32(222)
        @test h.major_version == UInt32(9)
        @test h.minor_version == UInt32(0)
        @test h.is_compressed == true
        @test h.half_precision == false
        @test h.uuid == "test-uuid"
        @test h.offset_to_data == UInt64(256)
    end

    @testset "NodeType" begin
        # Enum values exist
        @test NODE_ROOT isa NodeType
        @test NODE_INTERNAL isa NodeType
        @test NODE_LEAF isa NodeType

        # Values are distinct
        @test NODE_ROOT != NODE_INTERNAL
        @test NODE_INTERNAL != NODE_LEAF
        @test NODE_ROOT != NODE_LEAF
    end

end

@testset "TinyVDB Header Parsing" begin

    @testset "read_header - valid v222 header" begin
        # Build a valid VDB v222 header
        # Magic: 0x20424456 as Int64 (little-endian)
        # File version: 222
        # Major version: 9
        # Minor version: 0
        # has_grid_offsets: 1
        # UUID: 36 bytes

        magic = UInt64(0x20424456)  # " VDB" as little-endian Int64
        file_version = UInt32(222)
        major_version = UInt32(9)
        minor_version = UInt32(0)
        has_offsets = UInt8(1)
        uuid = "12345678-1234-1234-1234-123456789012"  # 36 chars

        bytes = UInt8[]
        # Magic (8 bytes)
        append!(bytes, reinterpret(UInt8, [magic]))
        # File version (4 bytes)
        append!(bytes, reinterpret(UInt8, [file_version]))
        # Major version (4 bytes)
        append!(bytes, reinterpret(UInt8, [major_version]))
        # Minor version (4 bytes)
        append!(bytes, reinterpret(UInt8, [minor_version]))
        # has_grid_offsets (1 byte)
        push!(bytes, has_offsets)
        # UUID (36 bytes)
        append!(bytes, Vector{UInt8}(uuid))

        header, pos = read_header(bytes, 1)

        @test header.file_version == UInt32(222)
        @test header.major_version == UInt32(9)
        @test header.minor_version == UInt32(0)
        @test header.is_compressed == false  # v222+ doesn't have compression byte
        @test header.uuid == uuid
        @test header.offset_to_data == UInt64(pos)
        @test pos == 58  # 8 + 4 + 4 + 4 + 1 + 36 + 1 = 58 (wait, let me recalculate)
        # Actually: 8 (magic) + 4 (file_ver) + 4 (major) + 4 (minor) + 1 (has_offsets) + 36 (uuid) = 57
        # So pos should be 58 (1-indexed, next position after byte 57)
    end

    @testset "read_header - valid v220 header with compression" begin
        # v220 has compression byte after has_grid_offsets
        magic = UInt64(0x20424456)
        file_version = UInt32(220)
        major_version = UInt32(8)
        minor_version = UInt32(0)
        has_offsets = UInt8(1)
        is_compressed = UInt8(1)  # compression enabled
        uuid = "12345678-1234-1234-1234-123456789012"

        bytes = UInt8[]
        append!(bytes, reinterpret(UInt8, [magic]))
        append!(bytes, reinterpret(UInt8, [file_version]))
        append!(bytes, reinterpret(UInt8, [major_version]))
        append!(bytes, reinterpret(UInt8, [minor_version]))
        push!(bytes, has_offsets)
        push!(bytes, is_compressed)  # v220-221 has this extra byte
        append!(bytes, Vector{UInt8}(uuid))

        header, pos = read_header(bytes, 1)

        @test header.file_version == UInt32(220)
        @test header.is_compressed == true  # compression flag is set
        @test header.uuid == uuid
        # v220: 8 + 4 + 4 + 4 + 1 + 1 + 36 = 58, so pos = 59
        @test pos == 59
    end

    @testset "read_header - invalid magic" begin
        # Wrong magic number
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        append!(bytes, zeros(UInt8, 50))  # padding

        @test_throws ErrorException read_header(bytes, 1)
    end

    @testset "read_header - version too old" begin
        # Valid magic but version < 220
        magic = UInt64(0x20424456)
        file_version = UInt32(219)  # too old

        bytes = UInt8[]
        append!(bytes, reinterpret(UInt8, [magic]))
        append!(bytes, reinterpret(UInt8, [file_version]))
        append!(bytes, zeros(UInt8, 50))  # padding

        @test_throws ErrorException read_header(bytes, 1)
    end

    @testset "read_header - no grid offsets" begin
        # has_grid_offsets = 0 not supported
        magic = UInt64(0x20424456)
        file_version = UInt32(222)
        major_version = UInt32(9)
        minor_version = UInt32(0)
        has_offsets = UInt8(0)  # not supported

        bytes = UInt8[]
        append!(bytes, reinterpret(UInt8, [magic]))
        append!(bytes, reinterpret(UInt8, [file_version]))
        append!(bytes, reinterpret(UInt8, [major_version]))
        append!(bytes, reinterpret(UInt8, [minor_version]))
        push!(bytes, has_offsets)
        append!(bytes, zeros(UInt8, 40))  # padding

        @test_throws ErrorException read_header(bytes, 1)
    end

end

println("All TinyVDB tests completed!")
