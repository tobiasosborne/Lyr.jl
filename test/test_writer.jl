# test_writer.jl - Comprehensive tests for the VDB writer
#
# Tests:
# 1. Binary write primitives — round-trip through write then read
# 2. Mask write — round-trip
# 3. Header write — round-trip
# 4. Metadata write — round-trip
# 5. Minimal tree — synthetic construction and round-trip
# 6. Round-trip cube.vdb — parse, write, re-parse, compare
# 7. Round-trip sphere.vdb — same
# 8. Grid descriptor write — round-trip
# 9. Transform write — round-trip
#
# NOTE: This test file includes the writer source files into the Lyr module
# so it can run standalone without modifying src/Lyr.jl.

using Test
using Lyr

# Include writer source files into Lyr module (user will add proper includes later)
Base.include(Lyr, joinpath(@__DIR__, "..", "src", "BinaryWrite.jl"))
Base.include(Lyr, joinpath(@__DIR__, "..", "src", "FileWrite.jl"))

# Access writer functions via Lyr module
const write_u8! = Lyr.write_u8!
const write_u32_le! = Lyr.write_u32_le!
const write_u64_le! = Lyr.write_u64_le!
const write_i32_le! = Lyr.write_i32_le!
const write_i64_le! = Lyr.write_i64_le!
const write_f16_le! = Lyr.write_f16_le!
const write_f32_le! = Lyr.write_f32_le!
const write_f64_le! = Lyr.write_f64_le!
const write_bytes! = Lyr.write_bytes!
const write_cstring! = Lyr.write_cstring!
const write_string_with_size! = Lyr.write_string_with_size!
const write_tile_value! = Lyr.write_tile_value!
const write_header! = Lyr.write_header!
const write_metadata! = Lyr.write_metadata!
const write_mask! = Lyr.write_mask!
const write_transform! = Lyr.write_transform!
const write_grid_descriptor! = Lyr.write_grid_descriptor!
const write_tree! = Lyr.write_tree!
const write_vdb = Lyr.write_vdb
const write_vdb_to_buffer = Lyr.write_vdb_to_buffer
const grid_type_string = Lyr.grid_type_string
const grid_class_string = Lyr.grid_class_string

# Helper: write to buffer and return bytes
function to_bytes(f::Function)
    io = IOBuffer()
    f(io)
    take!(io)
end

# Test fixtures directory
const FIXTURES_DIR = joinpath(@__DIR__, "fixtures", "samples")

@testset "VDB Writer" begin

    # =========================================================================
    # Binary Write Primitives
    # =========================================================================

    @testset "BinaryWrite primitives" begin
        @testset "write_u8! round-trip" begin
            for val in [UInt8(0x00), UInt8(0x42), UInt8(0xff)]
                bytes = to_bytes(io -> write_u8!(io, val))
                @test length(bytes) == 1
                result, _ = read_u8(bytes, 1)
                @test result == val
            end
        end

        @testset "write_u32_le! round-trip" begin
            for val in [UInt32(0), UInt32(1), UInt32(0x04030201), UInt32(0xffffffff)]
                bytes = to_bytes(io -> write_u32_le!(io, val))
                @test length(bytes) == 4
                result, _ = read_u32_le(bytes, 1)
                @test result == val
            end
        end

        @testset "write_u64_le! round-trip" begin
            for val in [UInt64(0), UInt64(0x0807060504030201), typemax(UInt64)]
                bytes = to_bytes(io -> write_u64_le!(io, val))
                @test length(bytes) == 8
                result, _ = read_u64_le(bytes, 1)
                @test result == val
            end
        end

        @testset "write_i32_le! round-trip" begin
            for val in [Int32(0), Int32(1), Int32(-1), typemin(Int32), typemax(Int32)]
                bytes = to_bytes(io -> write_i32_le!(io, val))
                @test length(bytes) == 4
                result, _ = read_i32_le(bytes, 1)
                @test result == val
            end
        end

        @testset "write_i64_le! round-trip" begin
            for val in [Int64(0), Int64(-1), typemin(Int64), typemax(Int64)]
                bytes = to_bytes(io -> write_i64_le!(io, val))
                @test length(bytes) == 8
                result, _ = read_i64_le(bytes, 1)
                @test result == val
            end
        end

        @testset "write_f16_le! round-trip" begin
            for val in [Float16(0.0), Float16(1.0), Float16(-1.0), Float16(0.5), Float16(Inf)]
                bytes = to_bytes(io -> write_f16_le!(io, val))
                @test length(bytes) == 2
                result, _ = read_f16_le(bytes, 1)
                @test result == val
            end
        end

        @testset "write_f32_le! round-trip" begin
            for val in [Float32(0.0), Float32(1.0), Float32(-1.0), Float32(3.14)]
                bytes = to_bytes(io -> write_f32_le!(io, val))
                @test length(bytes) == 4
                result, _ = read_f32_le(bytes, 1)
                @test result == val
            end
        end

        @testset "write_f64_le! round-trip" begin
            for val in [0.0, 1.0, -1.0, 3.141592653589793]
                bytes = to_bytes(io -> write_f64_le!(io, val))
                @test length(bytes) == 8
                result, _ = read_f64_le(bytes, 1)
                @test result == val
            end
        end

        @testset "write_bytes! round-trip" begin
            data = UInt8[0x01, 0x02, 0x03, 0x04, 0x05]
            bytes = to_bytes(io -> write_bytes!(io, data))
            @test bytes == data

            # Empty
            bytes = to_bytes(io -> write_bytes!(io, UInt8[]))
            @test isempty(bytes)
        end

        @testset "write_cstring! round-trip" begin
            for s in ["", "Hello", "VDB"]
                bytes = to_bytes(io -> write_cstring!(io, s))
                result, _ = read_cstring(bytes, 1)
                @test result == s
                @test bytes[end] == 0x00  # null terminated
            end
        end

        @testset "write_string_with_size! round-trip" begin
            for s in ["", "Hello", "Tree_float_5_4_3", "a" ^ 1000]
                bytes = to_bytes(io -> write_string_with_size!(io, s))
                result, pos = read_string_with_size(bytes, 1)
                @test result == s
                @test pos == length(bytes) + 1
            end
        end

        @testset "write_tile_value! round-trip" begin
            # Float32
            bytes = to_bytes(io -> write_tile_value!(io, Float32(3.14)))
            @test read_tile_value(Float32, bytes, 1)[1] == Float32(3.14)

            # Float64
            bytes = to_bytes(io -> write_tile_value!(io, 2.718281828))
            @test read_tile_value(Float64, bytes, 1)[1] == 2.718281828

            # Int32
            bytes = to_bytes(io -> write_tile_value!(io, Int32(42)))
            @test read_tile_value(Int32, bytes, 1)[1] == Int32(42)

            # Int64
            bytes = to_bytes(io -> write_tile_value!(io, Int64(-999)))
            @test read_tile_value(Int64, bytes, 1)[1] == Int64(-999)

            # Bool
            bytes = to_bytes(io -> write_tile_value!(io, true))
            @test read_tile_value(Bool, bytes, 1)[1] == true
            bytes = to_bytes(io -> write_tile_value!(io, false))
            @test read_tile_value(Bool, bytes, 1)[1] == false

            # Vec3f
            v = (Float32(1.0), Float32(2.0), Float32(3.0))
            bytes = to_bytes(io -> write_tile_value!(io, v))
            @test read_tile_value(NTuple{3,Float32}, bytes, 1)[1] == v

            # Vec3d
            v = (1.0, 2.0, 3.0)
            bytes = to_bytes(io -> write_tile_value!(io, v))
            @test read_tile_value(NTuple{3,Float64}, bytes, 1)[1] == v
        end

        @testset "write_tile_value! unsupported type" begin
            @test_throws ArgumentError to_bytes(io -> write_tile_value!(io, "not a number"))
        end

        @testset "sequential write then read" begin
            # Write multiple values sequentially, then read them back
            bytes = to_bytes(io -> begin
                write_u8!(io, UInt8(0xAA))
                write_u32_le!(io, UInt32(12345))
                write_f32_le!(io, Float32(6.28))
                write_string_with_size!(io, "test")
                write_i64_le!(io, Int64(-42))
            end)

            pos = 1
            v1, pos = read_u8(bytes, pos)
            @test v1 == 0xAA
            v2, pos = read_u32_le(bytes, pos)
            @test v2 == UInt32(12345)
            v3, pos = read_f32_le(bytes, pos)
            @test v3 == Float32(6.28)
            v4, pos = read_string_with_size(bytes, pos)
            @test v4 == "test"
            v5, pos = read_i64_le(bytes, pos)
            @test v5 == Int64(-42)
            @test pos == length(bytes) + 1
        end
    end

    # =========================================================================
    # Mask Writing
    # =========================================================================

    @testset "Mask write round-trip" begin
        @testset "empty LeafMask" begin
            mask = LeafMask()
            bytes = to_bytes(io -> write_mask!(io, mask))
            @test length(bytes) == 8 * 8  # 8 words * 8 bytes
            result, _ = read_mask(LeafMask, bytes, 1)
            @test result.words == mask.words
            @test count_on(result) == 0
        end

        @testset "full LeafMask" begin
            mask = LeafMask(Val(:ones))
            bytes = to_bytes(io -> write_mask!(io, mask))
            result, _ = read_mask(LeafMask, bytes, 1)
            @test is_full(result)
            @test count_on(result) == 512
        end

        @testset "partial LeafMask" begin
            # Create a mask with specific bits set
            words = ntuple(i -> i == 1 ? UInt64(0xFF) : UInt64(0), 8)
            mask = LeafMask(words)
            bytes = to_bytes(io -> write_mask!(io, mask))
            result, _ = read_mask(LeafMask, bytes, 1)
            @test result.words == mask.words
            @test count_on(result) == 8
        end

        @testset "Internal1Mask round-trip" begin
            mask = Internal1Mask()
            bytes = to_bytes(io -> write_mask!(io, mask))
            @test length(bytes) == 64 * 8  # 64 words
            result, _ = read_mask(Internal1Mask, bytes, 1)
            @test result.words == mask.words
        end

        @testset "Internal2Mask round-trip" begin
            mask = Internal2Mask()
            bytes = to_bytes(io -> write_mask!(io, mask))
            @test length(bytes) == 512 * 8  # 512 words
            result, _ = read_mask(Internal2Mask, bytes, 1)
            @test result.words == mask.words
        end
    end

    # =========================================================================
    # Header Writing
    # =========================================================================

    @testset "Header write round-trip" begin
        header = VDBHeader(
            UInt32(224),
            UInt32(11),
            UInt32(0),
            true,
            NoCompression(),
            true,
            "a2313abf-7b19-4669-a9ea-f4a83e6bf20d"
        )

        bytes = to_bytes(io -> write_header!(io, header))
        result, pos = read_header(bytes, 1)

        @test result.format_version == 224
        @test result.library_major == 11
        @test result.library_minor == 0
        @test result.has_grid_offsets == true
        @test result.uuid == "a2313abf-7b19-4669-a9ea-f4a83e6bf20d"
        @test pos == length(bytes) + 1
    end

    # =========================================================================
    # Metadata Writing
    # =========================================================================

    @testset "Metadata write round-trip" begin
        @testset "empty metadata" begin
            bytes = to_bytes(io -> write_metadata!(io, Dict{String,Any}()))
            count, pos = read_u32_le(bytes, 1)
            @test count == 0
        end

        @testset "string metadata" begin
            meta = Dict{String,Any}("class" => "level set")
            bytes = to_bytes(io -> write_metadata!(io, meta))
            result, _ = Lyr.read_grid_metadata(bytes, 1)
            @test result["class"] == "level set"
        end

        @testset "mixed metadata types" begin
            meta = Dict{String,Any}(
                "name" => "test",
                "count" => Int32(42),
                "big_count" => Int64(100000),
                "scale" => Float32(1.5),
                "precision" => 3.14,
                "flag" => true,
            )
            bytes = to_bytes(io -> write_metadata!(io, meta))
            result, _ = Lyr.read_grid_metadata(bytes, 1)

            @test result["name"] == "test"
            @test result["count"] == Int32(42)
            @test result["big_count"] == Int64(100000)
            @test result["scale"] == Float32(1.5)
            @test result["precision"] == 3.14
            @test result["flag"] == true
        end

        @testset "vec3 metadata" begin
            meta = Dict{String,Any}(
                "min_vec" => (Int32(1), Int32(2), Int32(3)),
                "color" => (Float32(0.5), Float32(0.6), Float32(0.7)),
                "world_pos" => (1.0, 2.0, 3.0),
            )
            bytes = to_bytes(io -> write_metadata!(io, meta))
            result, _ = Lyr.read_grid_metadata(bytes, 1)

            @test result["min_vec"] == (Int32(1), Int32(2), Int32(3))
            @test result["color"] == (Float32(0.5), Float32(0.6), Float32(0.7))
            @test result["world_pos"] == (1.0, 2.0, 3.0)
        end
    end

    # =========================================================================
    # Grid Type Strings
    # =========================================================================

    @testset "grid_type_string" begin
        @test grid_type_string(Float32) == "Tree_float_5_4_3"
        @test grid_type_string(Float64) == "Tree_double_5_4_3"
        @test grid_type_string(NTuple{3, Float32}) == "Tree_vec3s_5_4_3"
        @test grid_type_string(NTuple{3, Float64}) == "Tree_vec3d_5_4_3"
        @test grid_type_string(Int32) == "Tree_int32_5_4_3"

        # Verify parse_value_type can read back what we write
        for T in [Float32, Float64, NTuple{3,Float32}, NTuple{3,Float64}, Int32, Int64, Bool]
            @test parse_value_type(grid_type_string(T)) == T
        end
    end

    # =========================================================================
    # Transform Writing
    # =========================================================================

    @testset "Transform write round-trip" begin
        @testset "UniformScaleTransform" begin
            transform = UniformScaleTransform(0.05)
            bytes = to_bytes(io -> write_transform!(io, transform))
            result, _ = read_transform(bytes, 1)
            @test result isa UniformScaleTransform
            @test result.scale == 0.05
        end

        @testset "LinearTransform (uniform scale + translate)" begin
            mat = SMat3d(0.1, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 0.1)
            transform = LinearTransform(mat, SVec3d(1.0, 2.0, 3.0))
            bytes = to_bytes(io -> write_transform!(io, transform))
            result, _ = read_transform(bytes, 1)
            @test result isa LinearTransform
            vs = voxel_size(result)
            @test vs[1] ≈ 0.1 atol=1e-10
            @test vs[2] ≈ 0.1 atol=1e-10
            @test vs[3] ≈ 0.1 atol=1e-10
        end

        @testset "LinearTransform (non-uniform scale + translate)" begin
            mat = SMat3d(0.1, 0.0, 0.0, 0.0, 0.2, 0.0, 0.0, 0.0, 0.3)
            transform = LinearTransform(mat, SVec3d(1.0, 2.0, 3.0))
            bytes = to_bytes(io -> write_transform!(io, transform))
            result, _ = read_transform(bytes, 1)
            @test result isa LinearTransform
            vs = voxel_size(result)
            @test vs[1] ≈ 0.1 atol=1e-10
            @test vs[2] ≈ 0.2 atol=1e-10
            @test vs[3] ≈ 0.3 atol=1e-10
        end

        @testset "LinearTransform (ScaleMap, no translate)" begin
            mat = SMat3d(0.5, 0.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0, 0.5)
            transform = LinearTransform(mat, SVec3d(0.0, 0.0, 0.0))
            bytes = to_bytes(io -> write_transform!(io, transform))
            result, _ = read_transform(bytes, 1)
            @test result isa LinearTransform
            vs = voxel_size(result)
            @test vs[1] ≈ 0.5 atol=1e-10
        end
    end

    # =========================================================================
    # Synthetic Tree Construction and Round-Trip
    # =========================================================================

    @testset "Minimal tree round-trip" begin
        @testset "empty tree" begin
            background = Float32(0.0)
            tree = RootNode{Float32}(background, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
            grid = Grid{Float32}("density", GRID_FOG_VOLUME, UniformScaleTransform(1.0), tree)

            bytes = write_vdb_to_buffer(grid)
            vdb = parse_vdb(bytes)

            @test length(vdb.grids) == 1
            g = vdb.grids[1]
            @test g.name == "density"
            @test g.tree.background == Float32(0.0)
            @test isempty(g.tree.table)
        end

        @testset "tree with one root tile" begin
            background = Float32(-1.0)
            table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}()
            table[coord(0, 0, 0)] = Tile{Float32}(Float32(42.0), true)
            tree = RootNode{Float32}(background, table)
            grid = Grid{Float32}("density", GRID_FOG_VOLUME, UniformScaleTransform(1.0), tree)

            bytes = write_vdb_to_buffer(grid)
            vdb = parse_vdb(bytes)

            g = vdb.grids[1]
            @test g.tree.background == Float32(-1.0)
            # The tile should be present
            entry = g.tree.table[coord(0, 0, 0)]
            @test entry isa Tile{Float32}
            @test entry.value == Float32(42.0)
            @test entry.active == true
        end

        @testset "tree with single leaf" begin
            background = Float32(0.0)

            # Create a leaf with some active voxels
            leaf_origin = coord(0, 0, 0)
            words = ntuple(i -> i == 1 ? UInt64(0x07) : UInt64(0), 8)  # bits 0,1,2 on
            leaf_mask = LeafMask(words)
            values = ntuple(i -> Float32(i == 1 ? 1.0 : i == 2 ? 2.0 : i == 3 ? 3.0 : 0.0), 512)
            leaf = LeafNode{Float32}(leaf_origin, leaf_mask, values)

            # Build I1 node containing this leaf
            i1_origin = coord(0, 0, 0)
            i1_child_words = ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 64)  # bit 0 on
            i1_child_mask = Internal1Mask(i1_child_words)
            i1_value_mask = Internal1Mask()  # no tiles
            i1_table = Union{LeafNode{Float32}, Tile{Float32}}[leaf]
            i1 = InternalNode1{Float32}(i1_origin, i1_child_mask, i1_value_mask, i1_table)

            # Build I2 node containing this I1
            i2_origin = coord(0, 0, 0)
            i2_child_words = ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 512)  # bit 0 on
            i2_child_mask = Internal2Mask(i2_child_words)
            i2_value_mask = Internal2Mask()  # no tiles
            i2_table = Union{InternalNode1{Float32}, Tile{Float32}}[i1]
            i2 = InternalNode2{Float32}(i2_origin, i2_child_mask, i2_value_mask, i2_table)

            # Build root
            table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}()
            table[i2_origin] = i2
            tree = RootNode{Float32}(background, table)
            grid = Grid{Float32}("density", GRID_FOG_VOLUME, UniformScaleTransform(1.0), tree)

            bytes = write_vdb_to_buffer(grid)
            vdb = parse_vdb(bytes)

            g = vdb.grids[1]
            @test g.name == "density"
            @test g.tree.background == Float32(0.0)

            # Verify values via accessor
            @test get_value(g.tree, coord(0, 0, 0)) == Float32(1.0)
            @test get_value(g.tree, coord(0, 0, 1)) == Float32(2.0)
            @test get_value(g.tree, coord(0, 0, 2)) == Float32(3.0)
            @test get_value(g.tree, coord(0, 0, 3)) == Float32(0.0)  # inactive but stored
            @test get_value(g.tree, coord(100, 100, 100)) == Float32(0.0)  # background

            # Verify active states
            @test is_active(g.tree, coord(0, 0, 0)) == true
            @test is_active(g.tree, coord(0, 0, 1)) == true
            @test is_active(g.tree, coord(0, 0, 2)) == true
            @test is_active(g.tree, coord(0, 0, 3)) == false
        end

        @testset "tree with multiple leaves" begin
            background = Float32(-1.0)

            # Create two leaves in different I1 slots
            leaf1_origin = coord(0, 0, 0)
            leaf1_mask = LeafMask(Val(:ones))  # all active
            leaf1_values = ntuple(i -> Float32(i * 0.1), 512)
            leaf1 = LeafNode{Float32}(leaf1_origin, leaf1_mask, leaf1_values)

            leaf2_origin = coord(0, 0, 8)
            leaf2_mask = LeafMask(Val(:ones))
            leaf2_values = ntuple(i -> Float32(i * 0.2), 512)
            leaf2 = LeafNode{Float32}(leaf2_origin, leaf2_mask, leaf2_values)

            # I1 with two leaf children (indices 0 and 1)
            i1_origin = coord(0, 0, 0)
            i1_child_words = ntuple(i -> i == 1 ? UInt64(0x03) : UInt64(0), 64)  # bits 0,1 on
            i1_child_mask = Internal1Mask(i1_child_words)
            i1_value_mask = Internal1Mask()
            i1_table = Union{LeafNode{Float32}, Tile{Float32}}[leaf1, leaf2]
            i1 = InternalNode1{Float32}(i1_origin, i1_child_mask, i1_value_mask, i1_table)

            # I2
            i2_origin = coord(0, 0, 0)
            i2_child_words = ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 512)
            i2_child_mask = Internal2Mask(i2_child_words)
            i2_value_mask = Internal2Mask()
            i2_table = Union{InternalNode1{Float32}, Tile{Float32}}[i1]
            i2 = InternalNode2{Float32}(i2_origin, i2_child_mask, i2_value_mask, i2_table)

            table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}()
            table[i2_origin] = i2
            tree = RootNode{Float32}(background, table)
            grid = Grid{Float32}("density", GRID_FOG_VOLUME, UniformScaleTransform(0.5), tree)

            bytes = write_vdb_to_buffer(grid)
            vdb = parse_vdb(bytes)

            g = vdb.grids[1]
            @test g.tree.background == Float32(-1.0)
            @test leaf_count(g.tree) == 2

            # Check leaf1 values (first 3 at origin 0,0,0: offset 0 = value index 1)
            @test get_value(g.tree, coord(0, 0, 0)) == Float32(1 * 0.1)  # offset 0 -> values[1]
            @test get_value(g.tree, coord(0, 0, 1)) == Float32(2 * 0.1)  # offset 1 -> values[2]

            # Check leaf2 values (origin 0,0,8: offset 0 = value index 1)
            @test get_value(g.tree, coord(0, 0, 8)) == Float32(1 * 0.2)
            @test get_value(g.tree, coord(0, 0, 9)) == Float32(2 * 0.2)
        end

        @testset "Float64 tree round-trip" begin
            background = 0.0
            leaf_origin = coord(0, 0, 0)
            leaf_mask = LeafMask(Val(:ones))
            leaf_values = ntuple(i -> Float64(i), 512)
            leaf = LeafNode{Float64}(leaf_origin, leaf_mask, leaf_values)

            i1_origin = coord(0, 0, 0)
            i1_child_words = ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 64)
            i1 = InternalNode1{Float64}(i1_origin, Internal1Mask(i1_child_words), Internal1Mask(), [leaf])

            i2_origin = coord(0, 0, 0)
            i2_child_words = ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 512)
            i2 = InternalNode2{Float64}(i2_origin, Internal2Mask(i2_child_words), Internal2Mask(), [i1])

            table = Dict{Coord, Union{InternalNode2{Float64}, Tile{Float64}}}()
            table[i2_origin] = i2
            tree = RootNode{Float64}(background, table)
            grid = Grid{Float64}("distance", GRID_LEVEL_SET, UniformScaleTransform(1.0), tree)

            bytes = write_vdb_to_buffer(grid)
            vdb = parse_vdb(bytes)

            g = vdb.grids[1]
            @test g isa Grid{Float64}
            @test g.tree.background == 0.0
            @test get_value(g.tree, coord(0, 0, 0)) == 1.0  # values[1]
            @test get_value(g.tree, coord(0, 0, 7)) == 8.0  # values[8]
        end

        @testset "Vec3f tree round-trip" begin
            T = NTuple{3, Float32}
            background = (Float32(0.0), Float32(0.0), Float32(0.0))

            leaf_origin = coord(0, 0, 0)
            leaf_mask = LeafMask(ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 8))  # bit 0
            leaf_values = ntuple(i -> i == 1 ? (Float32(1.0), Float32(2.0), Float32(3.0)) : background, 512)
            leaf = LeafNode{T}(leaf_origin, leaf_mask, leaf_values)

            i1_origin = coord(0, 0, 0)
            i1 = InternalNode1{T}(i1_origin,
                Internal1Mask(ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 64)),
                Internal1Mask(),
                Union{LeafNode{T}, Tile{T}}[leaf])

            i2_origin = coord(0, 0, 0)
            i2 = InternalNode2{T}(i2_origin,
                Internal2Mask(ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 512)),
                Internal2Mask(),
                Union{InternalNode1{T}, Tile{T}}[i1])

            table = Dict{Coord, Union{InternalNode2{T}, Tile{T}}}()
            table[i2_origin] = i2
            tree = RootNode{T}(background, table)
            grid = Grid{T}("velocity", GRID_STAGGERED, UniformScaleTransform(1.0), tree)

            bytes = write_vdb_to_buffer(grid)
            vdb = parse_vdb(bytes)

            g = vdb.grids[1]
            @test g isa Grid{NTuple{3, Float32}}
            val = get_value(g.tree, coord(0, 0, 0))
            @test val == (Float32(1.0), Float32(2.0), Float32(3.0))
        end

        @testset "tree with tiles" begin
            background = Float32(0.0)

            # Create an I1 with a tile (no leaf children)
            i1_origin = coord(0, 0, 0)
            i1_child_mask = Internal1Mask()  # no children
            i1_value_words = ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 64)  # bit 0 = tile
            i1_value_mask = Internal1Mask(i1_value_words)
            i1_table = Union{LeafNode{Float32}, Tile{Float32}}[Tile{Float32}(Float32(99.0), true)]
            i1 = InternalNode1{Float32}(i1_origin, i1_child_mask, i1_value_mask, i1_table)

            # I2
            i2_origin = coord(0, 0, 0)
            i2_child_words = ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 512)
            i2 = InternalNode2{Float32}(i2_origin,
                Internal2Mask(i2_child_words),
                Internal2Mask(),
                Union{InternalNode1{Float32}, Tile{Float32}}[i1])

            table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}()
            table[i2_origin] = i2
            tree = RootNode{Float32}(background, table)
            grid = Grid{Float32}("density", GRID_FOG_VOLUME, UniformScaleTransform(1.0), tree)

            bytes = write_vdb_to_buffer(grid)
            vdb = parse_vdb(bytes)

            g = vdb.grids[1]
            # The tile should be accessible - coordinate (0,0,0) is in I1 child index 0
            # which is a tile with value 99.0
            @test get_value(g.tree, coord(0, 0, 0)) == Float32(99.0)
        end
    end

    # =========================================================================
    # File-level write_vdb round-trip
    # =========================================================================

    @testset "write_vdb to file and re-read" begin
        background = Float32(0.0)
        leaf_origin = coord(0, 0, 0)
        leaf_mask = LeafMask(Val(:ones))
        leaf_values = ntuple(i -> Float32(sin(Float64(i))), 512)
        leaf = LeafNode{Float32}(leaf_origin, leaf_mask, leaf_values)

        i1 = InternalNode1{Float32}(coord(0,0,0),
            Internal1Mask(ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 64)),
            Internal1Mask(),
            Union{LeafNode{Float32}, Tile{Float32}}[leaf])

        i2 = InternalNode2{Float32}(coord(0,0,0),
            Internal2Mask(ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 512)),
            Internal2Mask(),
            Union{InternalNode1{Float32}, Tile{Float32}}[i1])

        table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}()
        table[coord(0,0,0)] = i2
        tree = RootNode{Float32}(background, table)
        grid = Grid{Float32}("test", GRID_FOG_VOLUME, UniformScaleTransform(0.1), tree)

        tmpfile = tempname() * ".vdb"
        try
            write_vdb(tmpfile, grid)
            @test isfile(tmpfile)

            vdb = parse_vdb(tmpfile)
            @test length(vdb.grids) == 1
            g = vdb.grids[1]
            @test g.name == "test"

            # Verify every voxel
            for i in 0:511
                lz = i & 7
                ly = (i >> 3) & 7
                lx = (i >> 6) & 7
                c = coord(lx, ly, lz)
                expected = Float32(sin(Float64(i + 1)))
                @test get_value(g.tree, c) == expected
            end
        finally
            isfile(tmpfile) && rm(tmpfile)
        end
    end

    # =========================================================================
    # Round-trip real VDB files
    # =========================================================================

    @testset "Round-trip cube.vdb" begin
        cube_path = joinpath(FIXTURES_DIR, "cube.vdb")
        if isfile(cube_path)
            # Parse original
            orig = parse_vdb(cube_path)
            @test length(orig.grids) >= 1

            for orig_grid in orig.grids
                # Write to buffer
                buf = write_vdb_to_buffer(orig_grid)

                # Re-parse
                reread = parse_vdb(buf)
                @test length(reread.grids) == 1
                new_grid = reread.grids[1]

                # Compare grid names
                @test new_grid.name == orig_grid.name

                # Compare backgrounds
                @test new_grid.tree.background == orig_grid.tree.background

                # Compare leaf counts
                @test leaf_count(new_grid.tree) == leaf_count(orig_grid.tree)

                # Compare active voxel counts
                @test active_voxel_count(new_grid.tree) == active_voxel_count(orig_grid.tree)

                # Compare actual values at every active voxel
                new_acc = ValueAccessor(new_grid.tree)

                mismatch_count = 0
                for (c, val) in active_voxels(orig_grid.tree)
                    new_val = get_value(new_acc, c)
                    if new_val != val
                        mismatch_count += 1
                    end
                end
                @test mismatch_count == 0
            end
        else
            @warn "cube.vdb not found at $cube_path, skipping round-trip test"
        end
    end

    @testset "Round-trip sphere.vdb" begin
        sphere_path = joinpath(FIXTURES_DIR, "sphere.vdb")
        if isfile(sphere_path)
            # Parse original
            orig = parse_vdb(sphere_path)
            @test length(orig.grids) >= 1

            for orig_grid in orig.grids
                # Write to buffer
                buf = write_vdb_to_buffer(orig_grid)

                # Re-parse
                reread = parse_vdb(buf)
                @test length(reread.grids) == 1
                new_grid = reread.grids[1]

                # Compare grid names
                @test new_grid.name == orig_grid.name

                # Compare backgrounds
                @test new_grid.tree.background == orig_grid.tree.background

                # Compare leaf counts
                @test leaf_count(new_grid.tree) == leaf_count(orig_grid.tree)

                # Compare active voxel counts
                @test active_voxel_count(new_grid.tree) == active_voxel_count(orig_grid.tree)

                # Compare values at every active voxel
                new_acc = ValueAccessor(new_grid.tree)

                mismatch_count = 0
                for (c, val) in active_voxels(orig_grid.tree)
                    new_val = get_value(new_acc, c)
                    if new_val != val
                        mismatch_count += 1
                    end
                end
                @test mismatch_count == 0
            end
        else
            @warn "sphere.vdb not found at $sphere_path, skipping round-trip test"
        end
    end

    @testset "Round-trip torus.vdb" begin
        torus_path = joinpath(FIXTURES_DIR, "torus.vdb")
        if isfile(torus_path)
            orig = parse_vdb(torus_path)
            @test length(orig.grids) >= 1

            for orig_grid in orig.grids
                buf = write_vdb_to_buffer(orig_grid)
                reread = parse_vdb(buf)
                @test length(reread.grids) == 1
                new_grid = reread.grids[1]

                @test new_grid.name == orig_grid.name
                @test new_grid.tree.background == orig_grid.tree.background
                @test leaf_count(new_grid.tree) == leaf_count(orig_grid.tree)
                @test active_voxel_count(new_grid.tree) == active_voxel_count(orig_grid.tree)

                new_acc = ValueAccessor(new_grid.tree)
                mismatch_count = 0
                for (c, val) in active_voxels(orig_grid.tree)
                    if get_value(new_acc, c) != val
                        mismatch_count += 1
                    end
                end
                @test mismatch_count == 0
            end
        else
            @warn "torus.vdb not found at $torus_path, skipping round-trip test"
        end
    end

    # =========================================================================
    # Grid descriptor round-trip
    # =========================================================================

    @testset "GridDescriptor write round-trip" begin
        desc = GridDescriptor(
            "density",
            "Tree_float_5_4_3",
            "",
            Int64(1000),
            Int64(2000),
            Int64(3000)
        )

        bytes = to_bytes(io -> write_grid_descriptor!(io, desc, true))
        result, _ = read_grid_descriptor(bytes, 1, true)

        @test result.name == "density"
        @test result.grid_type == "Tree_float_5_4_3"
        @test result.instance_parent == ""
        @test result.byte_offset == 1000
        @test result.block_offset == 2000
        @test result.end_offset == 3000
    end

    # =========================================================================
    # Edge cases
    # =========================================================================

    @testset "Edge cases" begin
        @testset "write_vdb with VDBFile containing multiple grids" begin
            background = Float32(0.0)
            tree1 = RootNode{Float32}(background, Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
            grid1 = Grid{Float32}("density", GRID_FOG_VOLUME, UniformScaleTransform(1.0), tree1)

            tree2 = RootNode{Float32}(Float32(-3.0), Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}())
            grid2 = Grid{Float32}("temperature", GRID_FOG_VOLUME, UniformScaleTransform(0.5), tree2)

            header = VDBHeader(
                UInt32(224), UInt32(11), UInt32(0), true,
                NoCompression(), true,
                "00000000-0000-0000-0000-000000000000"
            )
            vdb = VDBFile(header, [grid1, grid2])

            bytes = write_vdb_to_buffer(vdb)
            reread = parse_vdb(bytes)

            @test length(reread.grids) == 2
            @test reread.grids[1].name == "density"
            @test reread.grids[2].name == "temperature"
            @test reread.grids[1].tree.background == Float32(0.0)
            @test reread.grids[2].tree.background == Float32(-3.0)
        end

        @testset "header version field preservation" begin
            header = VDBHeader(
                UInt32(224), UInt32(11), UInt32(2), true,
                NoCompression(), true,
                "12345678-1234-1234-1234-123456789abc"
            )
            bytes = to_bytes(io -> write_header!(io, header))
            result, _ = read_header(bytes, 1)
            @test result.format_version == 224
            @test result.library_major == 11
            @test result.library_minor == 2
            @test result.uuid == "12345678-1234-1234-1234-123456789abc"
        end

        @testset "sparse leaf (few active voxels)" begin
            background = Float32(0.0)

            # Only 1 active voxel
            words = ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 8)
            leaf_mask = LeafMask(words)
            values = ntuple(i -> i == 1 ? Float32(42.0) : Float32(0.0), 512)
            leaf = LeafNode{Float32}(coord(0,0,0), leaf_mask, values)

            i1 = InternalNode1{Float32}(coord(0,0,0),
                Internal1Mask(ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 64)),
                Internal1Mask(),
                Union{LeafNode{Float32}, Tile{Float32}}[leaf])
            i2 = InternalNode2{Float32}(coord(0,0,0),
                Internal2Mask(ntuple(i -> i == 1 ? UInt64(0x01) : UInt64(0), 512)),
                Internal2Mask(),
                Union{InternalNode1{Float32}, Tile{Float32}}[i1])

            table = Dict{Coord, Union{InternalNode2{Float32}, Tile{Float32}}}()
            table[coord(0,0,0)] = i2
            tree = RootNode{Float32}(background, table)
            grid = Grid{Float32}("sparse", GRID_FOG_VOLUME, UniformScaleTransform(1.0), tree)

            bytes = write_vdb_to_buffer(grid)
            vdb = parse_vdb(bytes)
            g = vdb.grids[1]

            @test active_voxel_count(g.tree) == 1
            @test get_value(g.tree, coord(0, 0, 0)) == Float32(42.0)
            @test is_active(g.tree, coord(0, 0, 0)) == true
            @test is_active(g.tree, coord(0, 0, 1)) == false
        end
    end

end
