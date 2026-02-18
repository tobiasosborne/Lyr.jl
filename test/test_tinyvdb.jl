# test_tinyvdb.jl - Tests for TinyVDB module
#
# Following TDD: These tests are written BEFORE the implementation.

using Test

# Include the module directly for testing
include(joinpath(@__DIR__, "..", "src", "TinyVDB", "TinyVDB.jl"))
using .TinyVDB

# Import internal TinyVDB symbols for unit testing
import .TinyVDB:
    # Binary
    read_u8, read_i32, read_u32, read_i64, read_u64, read_f32, read_f64, read_string,
    # Header/constants
    VDB_MAGIC, read_header, NodeType, NODE_ROOT, NODE_INTERNAL, NODE_LEAF,
    # Mask
    is_on, set_on!, count_on, read_mask,
    # Grid descriptor
    strip_suffix, read_grid_descriptor, read_grid_descriptors,
    # Compression
    COMPRESS_NONE, COMPRESS_ZIP, COMPRESS_ACTIVE_MASK, COMPRESS_BLOSC,
    read_grid_compression, read_compressed_data,
    # Topology
    read_leaf_topology, read_internal_topology, read_root_topology,
    # Values
    NO_MASK_OR_INACTIVE_VALS, NO_MASK_AND_MINUS_BG,
    read_leaf_values, read_tree_values,
    # Parser
    read_metadata, read_transform

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
            UInt64(256)       # data_pos
        )
        @test h.file_version == UInt32(222)
        @test h.major_version == UInt32(9)
        @test h.minor_version == UInt32(0)
        @test h.is_compressed == true
        @test h.half_precision == false
        @test h.uuid == "test-uuid"
        @test h.data_pos == UInt64(256)
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

    # VDB magic bytes: " BDV" + 4 null bytes
    magic_bytes = UInt8[0x20, 0x42, 0x44, 0x56, 0x00, 0x00, 0x00, 0x00]

    @testset "read_header - valid v222 header" begin
        # Build a valid VDB v222 header
        file_version = UInt32(222)
        major_version = UInt32(9)
        minor_version = UInt32(0)
        has_offsets = UInt8(1)
        uuid = "12345678-1234-1234-1234-123456789012"  # 36 chars

        bytes = UInt8[]
        # Magic (8 bytes)
        append!(bytes, magic_bytes)
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
        @test header.data_pos == UInt64(pos)
        # 8 (magic) + 4 (file_ver) + 4 (major) + 4 (minor) + 1 (has_offsets) + 36 (uuid) = 57
        # So pos should be 58 (1-indexed, next position after byte 57)
        @test pos == 58
    end

    @testset "read_header - valid v220 header with compression" begin
        # v220 has compression byte after has_grid_offsets
        file_version = UInt32(220)
        major_version = UInt32(8)
        minor_version = UInt32(0)
        has_offsets = UInt8(1)
        is_compressed = UInt8(1)  # compression enabled
        uuid = "12345678-1234-1234-1234-123456789012"

        bytes = UInt8[]
        append!(bytes, magic_bytes)
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
        # Wrong magic bytes
        bytes = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        append!(bytes, zeros(UInt8, 50))  # padding

        @test_throws ErrorException read_header(bytes, 1)
    end

    @testset "read_header - version too old" begin
        # Valid magic but version < 220
        file_version = UInt32(219)  # too old

        bytes = UInt8[]
        append!(bytes, magic_bytes)
        append!(bytes, reinterpret(UInt8, [file_version]))
        append!(bytes, zeros(UInt8, 50))  # padding

        @test_throws ErrorException read_header(bytes, 1)
    end

    @testset "read_header - no grid offsets" begin
        # has_grid_offsets = 0 not supported
        file_version = UInt32(222)
        major_version = UInt32(9)
        minor_version = UInt32(0)
        has_offsets = UInt8(0)  # not supported

        bytes = UInt8[]
        append!(bytes, magic_bytes)
        append!(bytes, reinterpret(UInt8, [file_version]))
        append!(bytes, reinterpret(UInt8, [major_version]))
        append!(bytes, reinterpret(UInt8, [minor_version]))
        push!(bytes, has_offsets)
        append!(bytes, zeros(UInt8, 40))  # padding

        @test_throws ErrorException read_header(bytes, 1)
    end

end

@testset "TinyVDB Grid Descriptor" begin

    @testset "GridDescriptor structure" begin
        # Test basic construction
        gd = GridDescriptor(
            "density",           # grid_name
            "density[0]",        # unique_name
            "Tree_float_5_4_3",  # grid_type
            false,               # half_precision
            "",                  # instance_parent
            Int64(1000),         # grid_pos
            Int64(2000),         # block_pos
            Int64(3000)          # end_pos
        )
        @test gd.grid_name == "density"
        @test gd.unique_name == "density[0]"
        @test gd.grid_type == "Tree_float_5_4_3"
        @test gd.half_precision == false
        @test gd.instance_parent == ""
        @test gd.grid_pos == Int64(1000)
        @test gd.block_pos == Int64(2000)
        @test gd.end_pos == Int64(3000)
    end

    @testset "strip_suffix" begin
        # Basic name with no suffix
        @test strip_suffix("density") == "density"

        # Name with [0] suffix (using SEP character 0x1e)
        @test strip_suffix("density" * Char(0x1e) * "0") == "density"

        # Name with longer suffix
        @test strip_suffix("grid_name" * Char(0x1e) * "123") == "grid_name"

        # Empty string
        @test strip_suffix("") == ""
    end

    @testset "read_grid_descriptor" begin
        # Build a valid grid descriptor
        # Format: unique_name (string), grid_type (string), instance_parent (string),
        #         grid_pos (i64), block_pos (i64), end_pos (i64)

        unique_name = "density"
        grid_type = "Tree_float_5_4_3"
        instance_parent = ""

        bytes = UInt8[]

        # unique_name string: length (4 bytes) + chars
        append!(bytes, reinterpret(UInt8, [UInt32(length(unique_name))]))
        append!(bytes, Vector{UInt8}(unique_name))

        # grid_type string
        append!(bytes, reinterpret(UInt8, [UInt32(length(grid_type))]))
        append!(bytes, Vector{UInt8}(grid_type))

        # instance_parent string (empty)
        append!(bytes, reinterpret(UInt8, [UInt32(0)]))

        # grid_pos (i64)
        append!(bytes, reinterpret(UInt8, [Int64(1000)]))

        # block_pos (i64)
        append!(bytes, reinterpret(UInt8, [Int64(2000)]))

        # end_pos (i64)
        append!(bytes, reinterpret(UInt8, [Int64(3000)]))

        gd, pos = read_grid_descriptor(bytes, 1)

        @test gd.grid_name == "density"
        @test gd.unique_name == "density"
        @test gd.grid_type == "Tree_float_5_4_3"
        @test gd.half_precision == false
        @test gd.instance_parent == ""
        @test gd.grid_pos == Int64(1000)
        @test gd.block_pos == Int64(2000)
        @test gd.end_pos == Int64(3000)
    end

    @testset "read_grid_descriptor with suffix" begin
        # Grid name with [0] suffix
        unique_name = "density" * Char(0x1e) * "0"
        grid_type = "Tree_float_5_4_3"

        bytes = UInt8[]
        append!(bytes, reinterpret(UInt8, [UInt32(length(unique_name))]))
        append!(bytes, Vector{UInt8}(unique_name))
        append!(bytes, reinterpret(UInt8, [UInt32(length(grid_type))]))
        append!(bytes, Vector{UInt8}(grid_type))
        append!(bytes, reinterpret(UInt8, [UInt32(0)]))  # instance_parent
        append!(bytes, reinterpret(UInt8, [Int64(100)]))  # grid_pos
        append!(bytes, reinterpret(UInt8, [Int64(200)]))  # block_pos
        append!(bytes, reinterpret(UInt8, [Int64(300)]))  # end_pos

        gd, _ = read_grid_descriptor(bytes, 1)

        @test gd.grid_name == "density"
        @test gd.unique_name == unique_name
    end

    @testset "read_grid_descriptor with half precision suffix" begin
        # Grid type with _HalfFloat suffix
        unique_name = "density"
        grid_type = "Tree_float_5_4_3_HalfFloat"

        bytes = UInt8[]
        append!(bytes, reinterpret(UInt8, [UInt32(length(unique_name))]))
        append!(bytes, Vector{UInt8}(unique_name))
        append!(bytes, reinterpret(UInt8, [UInt32(length(grid_type))]))
        append!(bytes, Vector{UInt8}(grid_type))
        append!(bytes, reinterpret(UInt8, [UInt32(0)]))  # instance_parent
        append!(bytes, reinterpret(UInt8, [Int64(100)]))
        append!(bytes, reinterpret(UInt8, [Int64(200)]))
        append!(bytes, reinterpret(UInt8, [Int64(300)]))

        gd, _ = read_grid_descriptor(bytes, 1)

        @test gd.grid_type == "Tree_float_5_4_3"  # suffix stripped
        @test gd.half_precision == true
    end

    @testset "read_grid_descriptors (multiple)" begin
        # Build bytes for count + 2 descriptors
        bytes = UInt8[]

        # Grid count (i32)
        append!(bytes, reinterpret(UInt8, [Int32(2)]))

        # First descriptor
        unique_name1 = "density"
        grid_type1 = "Tree_float_5_4_3"
        append!(bytes, reinterpret(UInt8, [UInt32(length(unique_name1))]))
        append!(bytes, Vector{UInt8}(unique_name1))
        append!(bytes, reinterpret(UInt8, [UInt32(length(grid_type1))]))
        append!(bytes, Vector{UInt8}(grid_type1))
        append!(bytes, reinterpret(UInt8, [UInt32(0)]))
        append!(bytes, reinterpret(UInt8, [Int64(100)]))
        append!(bytes, reinterpret(UInt8, [Int64(200)]))
        append!(bytes, reinterpret(UInt8, [Int64(300)]))

        # Second descriptor
        unique_name2 = "temperature"
        grid_type2 = "Tree_float_5_4_3"
        append!(bytes, reinterpret(UInt8, [UInt32(length(unique_name2))]))
        append!(bytes, Vector{UInt8}(unique_name2))
        append!(bytes, reinterpret(UInt8, [UInt32(length(grid_type2))]))
        append!(bytes, Vector{UInt8}(grid_type2))
        append!(bytes, reinterpret(UInt8, [UInt32(0)]))
        append!(bytes, reinterpret(UInt8, [Int64(400)]))
        append!(bytes, reinterpret(UInt8, [Int64(500)]))
        append!(bytes, reinterpret(UInt8, [Int64(600)]))

        descriptors, pos = read_grid_descriptors(bytes, 1)

        @test length(descriptors) == 2
        @test descriptors["density"].grid_name == "density"
        @test descriptors["density"].grid_pos == Int64(100)
        @test descriptors["temperature"].grid_name == "temperature"
        @test descriptors["temperature"].grid_pos == Int64(400)
    end

end

@testset "TinyVDB Compression" begin

    @testset "Compression constants" begin
        @test COMPRESS_NONE == 0x00
        @test COMPRESS_ZIP == 0x01
        @test COMPRESS_ACTIVE_MASK == 0x02
        @test COMPRESS_BLOSC == 0x04
    end

    @testset "read_compressed_data - uncompressed (COMPRESS_NONE)" begin
        # 4 Float32 values uncompressed
        values = Float32[1.0, 2.0, 3.0, 4.0]
        bytes = Vector{UInt8}(reinterpret(UInt8, values))

        result, pos = read_compressed_data(bytes, 1, 4, 4, COMPRESS_NONE)

        @test length(result) == 16  # 4 floats * 4 bytes
        @test reinterpret(Float32, result) == values
        @test pos == 17
    end

    @testset "read_compressed_data - negative zipped bytes (uncompressed zip)" begin
        # When compression_flags has COMPRESS_ZIP but numZippedBytes <= 0,
        # data is stored uncompressed
        values = Float32[1.0, 2.0, 3.0, 4.0]
        raw_bytes = reinterpret(UInt8, values)

        bytes = UInt8[]
        # numZippedBytes = -1 (indicates uncompressed)
        append!(bytes, reinterpret(UInt8, [Int64(-1)]))
        append!(bytes, raw_bytes)

        result, pos = read_compressed_data(bytes, 1, 4, 4, COMPRESS_ZIP)

        @test length(result) == 16
        @test reinterpret(Float32, result) == values
        @test pos == 25  # 8 (i64) + 16 (data)
    end

    @testset "read_compressed_data - zlib compressed" begin
        # Create some test data and compress it with zlib
        using CodecZlib

        values = Float32[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
        raw_bytes = reinterpret(UInt8, values)

        # Compress with zlib
        compressed = transcode(ZlibCompressor, Vector{UInt8}(raw_bytes))

        bytes = UInt8[]
        # numZippedBytes = length of compressed data
        append!(bytes, reinterpret(UInt8, [Int64(length(compressed))]))
        append!(bytes, compressed)

        result, pos = read_compressed_data(bytes, 1, 8, 4, COMPRESS_ZIP)

        @test length(result) == 32  # 8 floats * 4 bytes
        @test reinterpret(Float32, result) == values
    end

    @testset "read_grid_compression" begin
        # v222+ has per-grid compression flags
        bytes = Vector{UInt8}(reinterpret(UInt8, [UInt32(COMPRESS_ZIP | COMPRESS_ACTIVE_MASK)]))

        flags, pos = read_grid_compression(bytes, 1, UInt32(222))

        @test flags == (COMPRESS_ZIP | COMPRESS_ACTIVE_MASK)
        @test pos == 5
    end

    @testset "read_grid_compression - old version" begin
        # v221 and earlier don't have per-grid compression
        bytes = UInt8[0x00, 0x00, 0x00, 0x00]

        flags, pos = read_grid_compression(bytes, 1, UInt32(221))

        @test flags == COMPRESS_NONE
        @test pos == 1  # position unchanged
    end

end

@testset "TinyVDB Topology" begin

    @testset "RootNodeData structure" begin
        root = RootNodeData(
            3.0f0,       # background
            Int32(0),    # num_tiles
            Int32(1),    # num_children
            Tuple{Coord, Float32, Bool}[],  # tiles
            Tuple{Coord, InternalNodeData}[]  # children (empty for now)
        )
        @test root.background == 3.0f0
        @test root.num_tiles == 0
        @test root.num_children == 1
    end

    @testset "InternalNodeData structure" begin
        # Create masks for I2 node (log2dim=5)
        child_mask = NodeMask(Int32(5))
        value_mask = NodeMask(Int32(5))

        internal = InternalNodeData(
            Int32(5),     # log2dim
            child_mask,
            value_mask,
            Float32[],    # values
            Tuple{Int32, Any}[]  # children
        )
        @test internal.log2dim == Int32(5)
        @test internal.child_mask.log2dim == Int32(5)
    end

    @testset "LeafNodeData structure" begin
        value_mask = NodeMask(Int32(3))
        set_on!(value_mask, 0)

        leaf = LeafNodeData(
            value_mask,
            Float32[]  # values (read separately)
        )
        @test is_on(leaf.value_mask, 0) == true
        @test is_on(leaf.value_mask, 1) == false
    end

    @testset "read_root_topology - empty root" begin
        # Root with 0 tiles, 0 children
        bytes = UInt8[]

        # background value (f32)
        append!(bytes, reinterpret(UInt8, [3.0f0]))
        # num_tiles (i32)
        append!(bytes, reinterpret(UInt8, [Int32(0)]))
        # num_children (i32)
        append!(bytes, reinterpret(UInt8, [Int32(0)]))

        bytes = Vector{UInt8}(bytes)
        root, pos = read_root_topology(bytes, 1)

        @test root.background == 3.0f0
        @test root.num_tiles == 0
        @test root.num_children == 0
        @test length(root.tiles) == 0
        @test length(root.children) == 0
        @test pos == 13  # 4 + 4 + 4
    end

    @testset "read_root_topology - with tiles" begin
        bytes = UInt8[]

        # background value
        append!(bytes, reinterpret(UInt8, [0.0f0]))
        # num_tiles = 2
        append!(bytes, reinterpret(UInt8, [Int32(2)]))
        # num_children = 0
        append!(bytes, reinterpret(UInt8, [Int32(0)]))

        # Tile 1: coord (0,0,0), value 1.0, active=true
        append!(bytes, reinterpret(UInt8, [Int32(0), Int32(0), Int32(0)]))
        append!(bytes, reinterpret(UInt8, [1.0f0]))
        push!(bytes, 0x01)  # active = true

        # Tile 2: coord (4096,0,0), value 2.0, active=false
        append!(bytes, reinterpret(UInt8, [Int32(4096), Int32(0), Int32(0)]))
        append!(bytes, reinterpret(UInt8, [2.0f0]))
        push!(bytes, 0x00)  # active = false

        bytes = Vector{UInt8}(bytes)
        root, pos = read_root_topology(bytes, 1)

        @test root.num_tiles == 2
        @test root.tiles[1][1] == Coord(0, 0, 0)
        @test root.tiles[1][2] == 1.0f0
        @test root.tiles[1][3] == true
        @test root.tiles[2][1] == Coord(4096, 0, 0)
        @test root.tiles[2][2] == 2.0f0
        @test root.tiles[2][3] == false
    end

    @testset "read_leaf_topology" begin
        # Leaf mask: 512 bits = 64 bytes
        bytes = zeros(UInt8, 64)
        bytes[1] = 0xFF  # First 8 bits on

        bytes = Vector{UInt8}(bytes)
        leaf, pos = read_leaf_topology(bytes, 1)

        @test count_on(leaf.value_mask) == 8
        @test is_on(leaf.value_mask, 0) == true
        @test is_on(leaf.value_mask, 7) == true
        @test is_on(leaf.value_mask, 8) == false
        @test pos == 65
    end

    @testset "read_internal_topology - no children" begin
        # I1 node (log2dim=4): 4096 bits = 512 bytes per mask
        mask_size = 512

        bytes = UInt8[]
        # child_mask: all zeros (no children)
        append!(bytes, zeros(UInt8, mask_size))
        # value_mask: first 8 bits on
        value_mask_bytes = zeros(UInt8, mask_size)
        value_mask_bytes[1] = 0xFF
        append!(bytes, value_mask_bytes)

        bytes = Vector{UInt8}(bytes)
        # Use v220 to skip ReadMaskValues (v222+ embeds values in topology)
        internal, pos = read_internal_topology(bytes, 1, Int32(4), UInt32(220), COMPRESS_NONE, 0.0f0)

        @test internal.log2dim == Int32(4)
        @test count_on(internal.child_mask) == 0
        @test count_on(internal.value_mask) == 8
        @test pos == 1025  # 512 + 512 = 1024 bytes, so pos = 1025
    end

end

@testset "TinyVDB Values" begin

    @testset "NodeMaskFlag constants" begin
        # Must match tinyvdbio.h enum exactly
        @test NO_MASK_OR_INACTIVE_VALS == 0
        @test NO_MASK_AND_MINUS_BG == 1
        @test NO_MASK_AND_ONE_INACTIVE_VAL == 2
        @test MASK_AND_NO_INACTIVE_VALS == 3
        @test MASK_AND_ONE_INACTIVE_VAL == 4
        @test MASK_AND_TWO_INACTIVE_VALS == 5
        @test NO_MASK_AND_ALL_VALS == 6
    end

    @testset "read_leaf_values - uncompressed, all values (flag 6)" begin
        # Create a leaf with some active voxels
        value_mask = NodeMask(Int32(3))
        set_on!(value_mask, 0)
        set_on!(value_mask, 1)
        set_on!(value_mask, 511)

        leaf = LeafNodeData(value_mask, Float32[])
        background = 3.0f0

        # Build bytes: value_mask (64 bytes) + per_node_flag (1 byte) + 512 float32 values
        bytes = UInt8[]

        # Value mask (64 bytes) - skip over this in buffer reading
        mask_bytes = zeros(UInt8, 64)
        mask_bytes[1] = 0x03  # bits 0 and 1
        mask_bytes[64] = 0x80  # bit 511
        append!(bytes, mask_bytes)

        # per_node_flag = NO_MASK_AND_ALL_VALS
        push!(bytes, UInt8(NO_MASK_AND_ALL_VALS))

        # 512 float values (2048 bytes) - set specific values
        values = zeros(Float32, 512)
        values[1] = 1.0f0
        values[2] = 2.0f0
        values[512] = 512.0f0
        append!(bytes, reinterpret(UInt8, values))

        bytes = Vector{UInt8}(bytes)
        result_leaf, pos = read_leaf_values(bytes, 1, leaf, UInt32(222), COMPRESS_NONE, background)

        @test length(result_leaf.values) == 512
        @test result_leaf.values[1] == 1.0f0
        @test result_leaf.values[2] == 2.0f0
        @test result_leaf.values[512] == 512.0f0
        @test pos == 2114  # 64 + 1 + 2048 + 1
    end

    @testset "read_leaf_values - compressed (flag 6)" begin
        using CodecZlib

        value_mask = NodeMask(Int32(3))
        leaf = LeafNodeData(value_mask, Float32[])

        # Create test values
        values = ones(Float32, 512)  # All 1.0 for good compression
        raw_bytes = Vector{UInt8}(reinterpret(UInt8, values))
        compressed = transcode(ZlibCompressor, raw_bytes)

        bytes = UInt8[]
        # Value mask (64 bytes)
        append!(bytes, zeros(UInt8, 64))
        # per_node_flag
        push!(bytes, UInt8(NO_MASK_AND_ALL_VALS))
        # Compressed size (i64)
        append!(bytes, reinterpret(UInt8, [Int64(length(compressed))]))
        # Compressed data
        append!(bytes, compressed)

        bytes = Vector{UInt8}(bytes)
        result_leaf, pos = read_leaf_values(bytes, 1, leaf, UInt32(222), COMPRESS_ZIP, 0.0f0)

        @test length(result_leaf.values) == 512
        @test all(v -> v == 1.0f0, result_leaf.values)
    end

    @testset "read_leaf_values - flag 0: inactive = +background" begin
        # Flag 0 (NO_MASK_OR_INACTIVE_VALS): inactive voxels get +background
        # With COMPRESS_ACTIVE_MASK, only active values are stored
        background = 3.0f0
        value_mask = NodeMask(Int32(3))
        set_on!(value_mask, 0)    # Only voxel 0 is active
        set_on!(value_mask, 100)  # And voxel 100
        leaf = LeafNodeData(value_mask, Float32[])

        bytes = UInt8[]
        append!(bytes, zeros(UInt8, 64))  # value_mask (skipped)
        push!(bytes, UInt8(NO_MASK_OR_INACTIVE_VALS))  # flag = 0
        # Only 2 active values stored (no compression codec, just ACTIVE_MASK)
        append!(bytes, reinterpret(UInt8, [Float32(1.0)]))  # voxel 0
        append!(bytes, reinterpret(UInt8, [Float32(2.0)]))  # voxel 100

        bytes = Vector{UInt8}(bytes)
        result_leaf, pos = read_leaf_values(bytes, 1, leaf, UInt32(222),
                                            COMPRESS_ACTIVE_MASK, background)

        @test length(result_leaf.values) == 512
        @test result_leaf.values[1] == 1.0f0      # active voxel 0
        @test result_leaf.values[101] == 2.0f0     # active voxel 100 (1-indexed)
        @test result_leaf.values[2] == 3.0f0       # inactive = +background
        @test result_leaf.values[512] == 3.0f0     # inactive = +background
    end

    @testset "read_leaf_values - flag 1: inactive = -background" begin
        background = 3.0f0
        value_mask = NodeMask(Int32(3))
        set_on!(value_mask, 0)
        leaf = LeafNodeData(value_mask, Float32[])

        bytes = UInt8[]
        append!(bytes, zeros(UInt8, 64))  # value_mask
        push!(bytes, UInt8(NO_MASK_AND_MINUS_BG))  # flag = 1
        append!(bytes, reinterpret(UInt8, [Float32(1.0)]))  # 1 active value

        bytes = Vector{UInt8}(bytes)
        result_leaf, _ = read_leaf_values(bytes, 1, leaf, UInt32(222),
                                          COMPRESS_ACTIVE_MASK, background)

        @test length(result_leaf.values) == 512
        @test result_leaf.values[1] == 1.0f0       # active
        @test result_leaf.values[2] == -3.0f0      # inactive = -background
    end

    @testset "read_leaf_values - flag 2: one inactive val read from stream" begin
        background = 3.0f0
        value_mask = NodeMask(Int32(3))
        set_on!(value_mask, 0)
        leaf = LeafNodeData(value_mask, Float32[])

        bytes = UInt8[]
        append!(bytes, zeros(UInt8, 64))  # value_mask
        push!(bytes, UInt8(NO_MASK_AND_ONE_INACTIVE_VAL))  # flag = 2
        append!(bytes, reinterpret(UInt8, [Float32(7.0)]))  # inactiveVal0
        append!(bytes, reinterpret(UInt8, [Float32(1.0)]))  # 1 active value

        bytes = Vector{UInt8}(bytes)
        result_leaf, _ = read_leaf_values(bytes, 1, leaf, UInt32(222),
                                          COMPRESS_ACTIVE_MASK, background)

        @test length(result_leaf.values) == 512
        @test result_leaf.values[1] == 1.0f0       # active
        @test result_leaf.values[2] == 7.0f0       # inactive = inactiveVal0 (read)
    end

    @testset "read_leaf_values - flag 3: selection mask, bg/-bg" begin
        background = 3.0f0
        value_mask = NodeMask(Int32(3))
        set_on!(value_mask, 0)
        leaf = LeafNodeData(value_mask, Float32[])

        # selection_mask: bit 1 ON → inactiveVal1 (+bg), bit 2 OFF → inactiveVal0 (-bg)
        sel_mask = NodeMask(Int32(3))
        set_on!(sel_mask, 1)  # voxel 1 selected → +background

        bytes = UInt8[]
        append!(bytes, zeros(UInt8, 64))  # value_mask (skip)
        push!(bytes, UInt8(MASK_AND_NO_INACTIVE_VALS))  # flag = 3
        # selection_mask (64 bytes)
        for w in sel_mask.words
            append!(bytes, reinterpret(UInt8, [w]))
        end
        # 1 active value
        append!(bytes, reinterpret(UInt8, [Float32(1.0)]))

        bytes = Vector{UInt8}(bytes)
        result_leaf, _ = read_leaf_values(bytes, 1, leaf, UInt32(222),
                                          COMPRESS_ACTIVE_MASK, background)

        @test length(result_leaf.values) == 512
        @test result_leaf.values[1] == 1.0f0       # active
        @test result_leaf.values[2] == 3.0f0       # sel ON → inactiveVal1 = +bg
        @test result_leaf.values[3] == -3.0f0      # sel OFF → inactiveVal0 = -bg
    end

    @testset "read_leaf_values - flag 5: two inactive vals + selection mask" begin
        background = 3.0f0
        value_mask = NodeMask(Int32(3))
        set_on!(value_mask, 0)
        leaf = LeafNodeData(value_mask, Float32[])

        sel_mask = NodeMask(Int32(3))
        set_on!(sel_mask, 1)  # voxel 1 → inactiveVal1

        bytes = UInt8[]
        append!(bytes, zeros(UInt8, 64))  # value_mask
        push!(bytes, UInt8(MASK_AND_TWO_INACTIVE_VALS))  # flag = 5
        append!(bytes, reinterpret(UInt8, [Float32(10.0)]))  # inactiveVal0
        append!(bytes, reinterpret(UInt8, [Float32(20.0)]))  # inactiveVal1
        # selection_mask
        for w in sel_mask.words
            append!(bytes, reinterpret(UInt8, [w]))
        end
        # 1 active value
        append!(bytes, reinterpret(UInt8, [Float32(1.0)]))

        bytes = Vector{UInt8}(bytes)
        result_leaf, _ = read_leaf_values(bytes, 1, leaf, UInt32(222),
                                          COMPRESS_ACTIVE_MASK, background)

        @test length(result_leaf.values) == 512
        @test result_leaf.values[1] == 1.0f0       # active
        @test result_leaf.values[2] == 20.0f0      # sel ON → inactiveVal1
        @test result_leaf.values[3] == 10.0f0      # sel OFF → inactiveVal0
    end

    @testset "read_tree_values" begin
        # Build a minimal tree structure with one leaf
        value_mask = NodeMask(Int32(3))
        set_on!(value_mask, 0)
        leaf = LeafNodeData(value_mask, Float32[])

        # I1 node with one child
        i1_child_mask = NodeMask(Int32(4))
        set_on!(i1_child_mask, 0)  # Child at position 0
        i1_value_mask = NodeMask(Int32(4))
        i1 = InternalNodeData(Int32(4), i1_child_mask, i1_value_mask, Float32[], [(Int32(0), leaf)])

        # I2 node with one child
        i2_child_mask = NodeMask(Int32(5))
        set_on!(i2_child_mask, 0)
        i2_value_mask = NodeMask(Int32(5))
        i2 = InternalNodeData(Int32(5), i2_child_mask, i2_value_mask, Float32[], [(Int32(0), i1)])

        # Root with one child
        root = RootNodeData(0.0f0, Int32(0), Int32(1), [], [(Coord(0, 0, 0), i2)])

        # Build bytes: leaf values only (internal nodes don't store values in our simplified model)
        bytes = UInt8[]
        append!(bytes, zeros(UInt8, 64))  # mask
        push!(bytes, UInt8(NO_MASK_AND_ALL_VALS))
        values = zeros(Float32, 512)
        values[1] = 42.0f0
        append!(bytes, reinterpret(UInt8, values))

        bytes = Vector{UInt8}(bytes)
        result_root, pos = read_tree_values(bytes, 1, root, UInt32(222), COMPRESS_NONE)

        # Navigate to the leaf
        i2_result = result_root.children[1][2]
        i1_result = i2_result.children[1][2]
        leaf_result = i1_result.children[1][2]

        @test leaf_result.values[1] == 42.0f0
    end

end

@testset "TinyVDB Parser" begin

    @testset "TinyGrid structure" begin
        # Create a minimal grid
        value_mask = NodeMask(Int32(3))
        leaf = LeafNodeData(value_mask, Float32[1.0])
        i1_child_mask = NodeMask(Int32(4))
        i1 = InternalNodeData(Int32(4), i1_child_mask, NodeMask(Int32(4)), Float32[], [])
        i2_child_mask = NodeMask(Int32(5))
        i2 = InternalNodeData(Int32(5), i2_child_mask, NodeMask(Int32(5)), Float32[], [])
        root = RootNodeData(0.0f0, Int32(0), Int32(0), [], [])

        grid = TinyGrid("density", root, 1.0, "unknown", (0.0, 0.0, 0.0))

        @test grid.name == "density"
        @test grid.root.background == 0.0f0
        @test grid.voxel_size == 1.0
        @test grid.grid_class == "unknown"
        @test grid.translation == (0.0, 0.0, 0.0)
    end

    @testset "TinyVDBFile structure" begin
        header = VDBHeader(
            UInt32(222),
            UInt32(9),
            UInt32(0),
            false,
            false,
            "test-uuid",
            UInt64(100)
        )

        file = TinyVDBFile(header, Dict{String, TinyGrid}())

        @test file.header.file_version == UInt32(222)
        @test isempty(file.grids)
    end

    @testset "read_metadata - returns dict" begin
        # Build minimal metadata: count = 1, name = "test", type = "string", value = "hello"
        bytes = UInt8[]

        # count = 1
        append!(bytes, reinterpret(UInt8, [Int32(1)]))

        # name = "test"
        append!(bytes, reinterpret(UInt8, [UInt32(4)]))
        append!(bytes, Vector{UInt8}("test"))

        # type = "string"
        append!(bytes, reinterpret(UInt8, [UInt32(6)]))
        append!(bytes, Vector{UInt8}("string"))

        # value = "hello"
        append!(bytes, reinterpret(UInt8, [UInt32(5)]))
        append!(bytes, Vector{UInt8}("hello"))

        bytes = Vector{UInt8}(bytes)
        meta, pos = read_metadata(bytes, 1)

        # Should return dict with the string entry and advance past all metadata
        @test meta isa Dict{String,String}
        @test meta["test"] == "hello"
        @test pos == length(bytes) + 1
    end

    @testset "read_metadata - empty metadata" begin
        # count = 0 → empty dict
        bytes = Vector{UInt8}(reinterpret(UInt8, [Int32(0)]))
        meta, pos = read_metadata(bytes, 1)

        @test meta isa Dict{String,String}
        @test isempty(meta)
        @test pos == 5
    end

    @testset "read_metadata - collects string types only" begin
        # 3 entries: 2 strings + 1 int32 → dict has 2 keys
        bytes = UInt8[]
        append!(bytes, reinterpret(UInt8, [Int32(3)]))

        # Entry 1: name="class", type="string", value="level set"
        append!(bytes, reinterpret(UInt8, [UInt32(5)]))
        append!(bytes, Vector{UInt8}("class"))
        append!(bytes, reinterpret(UInt8, [UInt32(6)]))
        append!(bytes, Vector{UInt8}("string"))
        append!(bytes, reinterpret(UInt8, [UInt32(9)]))
        append!(bytes, Vector{UInt8}("level set"))

        # Entry 2: name="version", type="int32", value=1
        append!(bytes, reinterpret(UInt8, [UInt32(7)]))
        append!(bytes, Vector{UInt8}("version"))
        append!(bytes, reinterpret(UInt8, [UInt32(5)]))
        append!(bytes, Vector{UInt8}("int32"))
        append!(bytes, reinterpret(UInt8, [Int32(4)]))  # size prefix
        append!(bytes, reinterpret(UInt8, [Int32(1)]))   # value

        # Entry 3: name="creator", type="string", value="Houdini"
        append!(bytes, reinterpret(UInt8, [UInt32(7)]))
        append!(bytes, Vector{UInt8}("creator"))
        append!(bytes, reinterpret(UInt8, [UInt32(6)]))
        append!(bytes, Vector{UInt8}("string"))
        append!(bytes, reinterpret(UInt8, [UInt32(7)]))
        append!(bytes, Vector{UInt8}("Houdini"))

        bytes = Vector{UInt8}(bytes)
        meta, pos = read_metadata(bytes, 1)

        @test length(meta) == 2
        @test meta["class"] == "level set"
        @test meta["creator"] == "Houdini"
        @test !haskey(meta, "version")  # int32 not collected
        @test pos == length(bytes) + 1
    end

    @testset "read_transform - extract voxel size" begin
        # Per tinyvdbio.h, UniformScaleMap reads 5 Vec3d = 15 doubles = 120 bytes

        # Build a UniformScaleMap transform
        bytes = UInt8[]

        # Transform type string: "UniformScaleMap" (15 chars)
        append!(bytes, reinterpret(UInt8, [UInt32(15)]))
        append!(bytes, Vector{UInt8}("UniformScaleMap"))

        # 5 Vec3d = 15 doubles: first is scale_x (voxel size)
        append!(bytes, reinterpret(UInt8, [Float64(0.5)]))  # scale_x
        for _ in 2:15
            append!(bytes, reinterpret(UInt8, [Float64(1.0)]))
        end

        bytes = Vector{UInt8}(bytes)
        voxel_size, translation, pos = read_transform(bytes, 1)

        @test voxel_size == 0.5
        @test translation == (0.0, 0.0, 0.0)
        # Should be past the transform data: 4 (len) + 15 (str) + 120 (5 vec3d) + 1 = 140
        @test pos == 140
    end

end

@testset "TinyVDB End-to-End: cube.vdb" begin
    cube_path = joinpath(@__DIR__, "fixtures", "samples", "cube.vdb")
    if isfile(cube_path)
        @testset "parse_tinyvdb succeeds" begin
            vdb = parse_tinyvdb(cube_path)

            @test vdb.header.file_version >= UInt32(222)
            @test !isempty(vdb.grids)
        end

        @testset "grid structure is plausible" begin
            vdb = parse_tinyvdb(cube_path)

            # Should have at least one grid
            @test length(vdb.grids) >= 1

            # Get the first grid
            grid = first(values(vdb.grids))

            # Root should have children
            @test grid.root.num_children > 0

            # Count leaves
            leaf_count = 0
            for (_, i2) in grid.root.children
                for (_, child) in i2.children
                    if child isa InternalNodeData
                        leaf_count += length(child.children)
                    end
                end
            end
            @test leaf_count > 0
        end

        @testset "grid has class metadata" begin
            vdb = parse_tinyvdb(cube_path)
            grid = first(values(vdb.grids))
            @test grid.grid_class == "level set"
        end

        @testset "leaf values are plausible SDF" begin
            vdb = parse_tinyvdb(cube_path)
            grid = first(values(vdb.grids))

            # Collect some leaf values
            all_ok = true
            sample_count = 0
            for (_, i2) in grid.root.children
                for (_, i1_any) in i2.children
                    i1 = i1_any::InternalNodeData
                    for (_, leaf_any) in i1.children
                        leaf = leaf_any::LeafNodeData
                        if !isempty(leaf.values)
                            @test length(leaf.values) == 512
                            # SDF values should be finite, not NaN
                            for v in leaf.values
                                if !isfinite(v)
                                    all_ok = false
                                end
                            end
                            sample_count += 1
                        end
                        sample_count >= 10 && break
                    end
                    sample_count >= 10 && break
                end
                sample_count >= 10 && break
            end

            @test all_ok  # No NaN or Inf values
            @test sample_count >= 1  # We found at least one leaf with values
        end
    else
        @warn "cube.vdb not found at $cube_path, skipping end-to-end test"
    end
end

@testset "TinyVDB Transform: UniformScaleTranslateMap" begin
    # UniformScaleTranslateMap has 3 translation doubles THEN 15 scale doubles (144 bytes total)
    # Build a synthetic transform: type string + 18 doubles
    buf = UInt8[]
    type_str = "UniformScaleTranslateMap"
    append!(buf, reinterpret(UInt8, [Int32(length(type_str))]))
    append!(buf, Vector{UInt8}(type_str))
    # Translation: 3 doubles
    for v in [10.0, 20.0, 30.0]
        append!(buf, reinterpret(UInt8, [v]))
    end
    # scale_values: 3 doubles (voxel_size source)
    for v in [0.5, 0.5, 0.5]
        append!(buf, reinterpret(UInt8, [v]))
    end
    # remaining 12 doubles (voxel_size, inverse, inv_sq, inv_twice)
    for _ in 1:12
        append!(buf, reinterpret(UInt8, [1.0]))
    end

    voxel_size, translation, pos = TinyVDB.read_transform(buf, 1)
    @test voxel_size ≈ 0.5
    @test translation == (10.0, 20.0, 30.0)
    @test pos == length(buf) + 1  # consumed all bytes
end

@testset "TinyVDB End-to-End: smoke.vdb" begin
    smoke_path = joinpath(@__DIR__, "fixtures", "samples", "smoke.vdb")
    if isfile(smoke_path)
        @testset "parse_tinyvdb succeeds" begin
            vdb = parse_tinyvdb(smoke_path)
            @test haskey(vdb.grids, "density")
        end

        @testset "grid structure is plausible" begin
            vdb = parse_tinyvdb(smoke_path)
            grid = vdb.grids["density"]
            @test grid.root.num_children >= 1
            @test grid.voxel_size > 0.0
        end

        @testset "grid has fog volume class" begin
            vdb = parse_tinyvdb(smoke_path)
            grid = vdb.grids["density"]
            @test grid.grid_class == "fog volume"
        end

        @testset "leaf values are valid" begin
            vdb = parse_tinyvdb(smoke_path)
            grid = vdb.grids["density"]
            # Fog volume: density values should be in [0, 1] range mostly
            sample_count = 0
            all_finite = true
            for (_, i2) in grid.root.children
                for (_, i1) in i2.children
                    for (_, leaf) in i1.children
                        if leaf isa TinyVDB.LeafNodeData && !isempty(leaf.values)
                            sample_count += 1
                            if any(!isfinite, leaf.values)
                                all_finite = false
                            end
                            sample_count >= 10 && break
                        end
                    end
                    sample_count >= 10 && break
                end
                sample_count >= 10 && break
            end
            @test all_finite
            @test sample_count >= 1
        end
    else
        @warn "smoke.vdb not found at $smoke_path, skipping end-to-end test"
    end
end

println("All TinyVDB tests completed!")
