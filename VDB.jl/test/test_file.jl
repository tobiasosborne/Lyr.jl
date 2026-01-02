@testset "File" begin
    @testset "VDB_MAGIC" begin
        @test VDB_MAGIC == 0x20424456  # " BDV" in little-endian
    end

    @testset "read_header invalid magic" begin
        bytes = UInt8[0x00, 0x00, 0x00, 0x00]  # Wrong magic
        @test_throws ErrorException read_header(bytes, 1)
    end

    @testset "read_header valid" begin
        # Construct a minimal valid header
        # Magic + version + lib_major + lib_minor
        bytes = vcat(
            reinterpret(UInt8, [UInt32(VDB_MAGIC)]),      # Magic
            reinterpret(UInt8, [UInt32(222)]),            # Format version
            reinterpret(UInt8, [UInt32(9)]),              # Library major
            reinterpret(UInt8, [UInt32(0)]),              # Library minor
            UInt8[0x01],                                   # Has grid offsets
            UInt8[0x00],                                   # No compression
            zeros(UInt8, 16)                               # UUID
        )

        header, pos = read_header(bytes, 1)

        @test header.format_version == 222
        @test header.library_major == 9
        @test header.library_minor == 0
        @test header.has_grid_offsets == true
        @test header.compression isa NoCompression
    end

    @testset "VDBHeader types" begin
        header = VDBHeader(
            UInt32(222),
            UInt32(9),
            UInt32(0),
            true,
            BloscCodec(),
            ntuple(_ -> UInt8(0), 16)
        )

        @test header isa VDBHeader
        @test header.compression isa BloscCodec
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
            ntuple(_ -> UInt8(0), 16)
        )

        file = VDBFile(header, [])
        @test file.header.format_version == 222
        @test isempty(file.grids)
    end
end
