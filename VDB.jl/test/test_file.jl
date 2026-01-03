@testset "File" begin
    @testset "VDB_MAGIC" begin
        # Bytes [0x20, 0x42, 0x44, 0x56] = " BDV" read as little-endian u32 = 0x56444220
        @test VDB_MAGIC == 0x56444220
    end

    @testset "read_header invalid magic" begin
        bytes = UInt8[0x00, 0x00, 0x00, 0x00]  # Wrong magic
        @test_throws ErrorException read_header(bytes, 1)
    end

    @testset "read_header valid" begin
        # VDB header format (from torus.vdb analysis):
        # - Magic (4 bytes) + padding (4 bytes) = 8 bytes
        # - Format version (4 bytes u32 LE)
        # - Library major (4 bytes u32 LE)
        # - Library minor (4 bytes u32 LE)
        # - Has grid offsets (1 byte) if version >= 212
        # - UUID (36 bytes ASCII string)
        # - Compression (4 bytes u32 LE) if version >= 222
        uuid_str = "a2313abf-7b19-4669-a9ea-f4a83e6bf20d"
        bytes = vcat(
            reinterpret(UInt8, [UInt32(VDB_MAGIC)]),       # Magic (4 bytes)
            zeros(UInt8, 4),                               # Padding (4 bytes)
            reinterpret(UInt8, [UInt32(222)]),             # Format version
            reinterpret(UInt8, [UInt32(9)]),               # Library major
            reinterpret(UInt8, [UInt32(0)]),               # Library minor
            UInt8[0x01],                                    # Has grid offsets
            Vector{UInt8}(uuid_str),                        # UUID (36 bytes)
            reinterpret(UInt8, [UInt32(0)]),               # No compression (u32)
        )

        header, pos = read_header(bytes, 1)

        @test header.format_version == 222
        @test header.library_major == 9
        @test header.library_minor == 0
        @test header.has_grid_offsets == true
        @test header.compression isa NoCompression
        @test header.uuid == uuid_str
        @test pos == length(bytes) + 1  # Position should be right after header
    end

    @testset "VDBHeader types" begin
        header = VDBHeader(
            UInt32(222),
            UInt32(9),
            UInt32(0),
            true,
            BloscCodec(),
            "a2313abf-7b19-4669-a9ea-f4a83e6bf20d"
        )

        @test header isa VDBHeader
        @test header.compression isa BloscCodec
        @test length(header.uuid) == 36
    end

    @testset "GridDescriptor" begin
        desc = GridDescriptor(
            "density",
            "Tree_float_5_4_3",
            "",
            Int64(1000),
            Int64(0),
            Int64(2000)
        )

        @test desc.name == "density"
        @test desc.grid_type == "Tree_float_5_4_3"
        @test desc.instance_parent == ""
        @test desc.byte_offset == 1000
    end

    @testset "parse_value_type" begin
        @test parse_value_type("Tree_float_5_4_3") == Float32
        @test parse_value_type("Tree_Float_5_4_3") == Float32
        @test parse_value_type("Tree_double_5_4_3") == Float64
        @test parse_value_type("Tree_Vec3f_5_4_3") == NTuple{3, Float32}
        @test parse_value_type("Tree_vec3d_5_4_3") == NTuple{3, Float64}
        @test parse_value_type("Tree_int32_5_4_3") == Int32
        @test parse_value_type("Tree_bool_5_4_3") == Bool
        @test parse_value_type("unknown") == Float32  # Default
    end

    @testset "VDBFile structure" begin
        header = VDBHeader(
            UInt32(222), UInt32(9), UInt32(0),
            true, NoCompression(),
            "00000000-0000-0000-0000-000000000000"
        )

        file = VDBFile(header, [])
        @test file.header.format_version == 222
        @test isempty(file.grids)
    end
end
