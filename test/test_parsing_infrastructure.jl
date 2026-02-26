# test_parsing_infrastructure.jl — unit tests for parsing infrastructure
#
# Covers: Exceptions (showerror), Binary (boundaries), Transforms (read_transform),
#          GridDescriptor (read_grid_descriptor), Metadata (read_grid_metadata)

# ─── Helpers ──────────────────────────────────────────────────────────────────

"""Build a little-endian byte buffer from typed values."""
function le_bytes(vals...)
    buf = UInt8[]
    for v in vals
        append!(buf, reinterpret(UInt8, [v]))
    end
    buf
end

"""Build a size-prefixed string (u32 LE length + raw bytes)."""
function sized_string(s::String)
    data = Vector{UInt8}(s)
    vcat(le_bytes(UInt32(length(data))), data)
end

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Exception showerror messages
# ═══════════════════════════════════════════════════════════════════════════════

@testset "Exception showerror" begin
    # Test that every exception type produces a non-empty, informative message
    cases = [
        (InvalidMagicError(UInt64(0x56444220), UInt64(0xDEADBEEF)),
            r"InvalidMagicError.*expected.*56444220.*got.*deadbeef"),
        (ChunkSizeMismatchError(100, 512, 256, Int64(-256)),
            r"ChunkSizeMismatchError.*position 100.*expected 512.*got 256"),
        (CompressionBoundsError(50, Int64(1000), 200),
            r"CompressionBoundsError.*position 50.*chunk_size=1000.*file_size=200"),
        (DecompressionSizeError(512, 480),
            r"DecompressionSizeError.*expected 512.*got 480"),
        (ValueCountError(100, 99),
            r"ValueCountError.*expected 100.*got 99"),
        (FormatError("bad magic bytes"),
            r"FormatError.*bad magic bytes"),
        (UnsupportedVersionError(UInt32(210), UInt32(220)),
            r"UnsupportedVersionError.*210.*minimum.*220"),
    ]

    @testset "$(nameof(typeof(exc)))" for (exc, pattern) in cases
        msg = sprint(showerror, exc)
        @test !isempty(msg)
        @test occursin(pattern, msg)
        # Verify exception hierarchy
        @test exc isa LyrError
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Binary readers — boundary and edge cases
# ═══════════════════════════════════════════════════════════════════════════════

@testset "Binary edge cases" begin
    @testset "read at exact last valid position" begin
        # read_u8: last byte is valid
        @test read_u8(UInt8[0xAB], 1) == (0xAB, 2)

        # read_u32_le: exactly 4 bytes
        buf = le_bytes(UInt32(0xCAFEBABE))
        @test read_u32_le(buf, 1)[1] == 0xCAFEBABE

        # read_u64_le: exactly 8 bytes
        buf = le_bytes(UInt64(typemax(UInt64)))
        @test read_u64_le(buf, 1)[1] == typemax(UInt64)
    end

    @testset "read with insufficient bytes" begin
        @test_throws BoundsError read_u32_le(UInt8[0x01, 0x02, 0x03], 1)
        @test_throws BoundsError read_u64_le(UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07], 1)
        @test_throws BoundsError read_f64_le(UInt8[0x00, 0x00, 0x00], 1)
        @test_throws BoundsError read_f16_le(UInt8[0x00], 1)
    end

    @testset "read_cstring without null terminator" begin
        @test_throws BoundsError read_cstring(UInt8[0x41, 0x42], 1)
    end

    @testset "read_le generic" begin
        # Round-trip for all supported types
        for (T, val) in [(UInt32, UInt32(42)), (Int32, Int32(-7)),
                         (UInt64, UInt64(1) << 48), (Int64, Int64(-999)),
                         (Float32, 3.14f0), (Float64, 2.718281828),
                         (Float16, Float16(0.5))]
            buf = le_bytes(val)
            @test read_le(T, buf, 1) == (val, sizeof(T) + 1)
        end
    end

    @testset "Float special values" begin
        for val in [0.0f0, -0.0f0, Inf32, -Inf32, NaN32]
            buf = le_bytes(val)
            result = read_f32_le(buf, 1)[1]
            isnan(val) ? (@test isnan(result)) : (@test result === val)
        end

        for val in [0.0, -0.0, Inf, -Inf, NaN]
            buf = le_bytes(val)
            result = read_f64_le(buf, 1)[1]
            isnan(val) ? (@test isnan(result)) : (@test result === val)
        end
    end

    @testset "read at non-1 offset" begin
        # Embed a u32 at position 3 with padding on both sides
        buf = UInt8[0xFF, 0xFF, 0x2A, 0x00, 0x00, 0x00, 0xFF]
        @test read_u32_le(buf, 3)[1] == UInt32(42)
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# 3. read_transform — all 4 map types
# ═══════════════════════════════════════════════════════════════════════════════

@testset "read_transform" begin
    """Build 15 doubles of scale map data (the reader only uses the first 3)."""
    function scale_map_bytes(sx, sy, sz)
        le_bytes(
            sx, sy, sz,               # Scale
            1.0/sx, 1.0/sy, 1.0/sz,   # InvScale
            1.0/sx^2, 1.0/sy^2, 1.0/sz^2,  # InvScaleSqr
            sx, sy, sz,               # VoxelSize
            sx, sy, sz,               # VoxelSize
        )
    end

    @testset "UniformScaleMap" begin
        buf = vcat(sized_string("UniformScaleMap"), scale_map_bytes(0.5, 0.5, 0.5))
        t, pos = read_transform(buf, 1)
        @test t isa UniformScaleTransform
        @test t.scale ≈ 0.5
        @test pos == length(buf) + 1
    end

    @testset "ScaleMap" begin
        buf = vcat(sized_string("ScaleMap"), scale_map_bytes(0.1, 0.2, 0.3))
        t, pos = read_transform(buf, 1)
        @test t isa LinearTransform
        @test all(voxel_size(t) .≈ (0.1, 0.2, 0.3))
        # No translation
        @test all(t.trans .≈ 0.0)
        @test pos == length(buf) + 1
    end

    @testset "$map_name" for map_name in ["UniformScaleTranslateMap", "ScaleTranslateMap"]
        tx, ty, tz = 10.0, 20.0, 30.0
        sx = map_name == "UniformScaleTranslateMap" ? 0.25 : 0.1
        sy = map_name == "UniformScaleTranslateMap" ? 0.25 : 0.2
        sz = map_name == "UniformScaleTranslateMap" ? 0.25 : 0.3
        scale_data = le_bytes(
            sx, sy, sz,
            1.0/sx, 1.0/sy, 1.0/sz,
            1.0/sx^2, 1.0/sy^2, 1.0/sz^2,
            1.0/(2sx), 1.0/(2sy), 1.0/(2sz),
            sx, sy, sz,
        )
        buf = vcat(sized_string(map_name), le_bytes(tx, ty, tz), scale_data)
        t, pos = read_transform(buf, 1)
        @test t isa LinearTransform
        @test t.trans[1] ≈ tx
        @test t.trans[2] ≈ ty
        @test t.trans[3] ≈ tz
        @test all(voxel_size(t) .≈ (sx, sy, sz))
        @test pos == length(buf) + 1
    end

    @testset "unsupported map type" begin
        buf = sized_string("AffineMap")
        @test_throws ArgumentError read_transform(buf, 1)
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# 4. read_grid_descriptor — with and without offsets
# ═══════════════════════════════════════════════════════════════════════════════

@testset "read_grid_descriptor" begin
    @testset "with offsets" begin
        buf = vcat(
            sized_string("density"),
            sized_string("Tree_float_5_4_3"),
            sized_string(""),   # no instance parent
            le_bytes(Int64(1000), Int64(2000), Int64(3000)),
        )
        gd, pos = read_grid_descriptor(buf, 1, true)
        @test gd.name == "density"
        @test gd.grid_type == "Tree_float_5_4_3"
        @test gd.instance_parent == ""
        @test gd.byte_offset == 1000
        @test gd.block_offset == 2000
        @test gd.end_offset == 3000
        @test pos == length(buf) + 1
    end

    @testset "without offsets" begin
        buf = vcat(
            sized_string("temperature"),
            sized_string("Tree_double_5_4_3"),
            sized_string("parent_grid"),
        )
        gd, pos = read_grid_descriptor(buf, 1, false)
        @test gd.name == "temperature"
        @test gd.grid_type == "Tree_double_5_4_3"
        @test gd.instance_parent == "parent_grid"
        @test gd.byte_offset == 0
        @test gd.block_offset == 0
        @test gd.end_offset == 0
        @test pos == length(buf) + 1
    end

    @testset "HalfFloat suffix detection" begin
        buf = vcat(
            sized_string("vel"),
            sized_string("Tree_float_5_4_3_HalfFloat"),
            sized_string(""),
            le_bytes(Int64(0), Int64(0), Int64(0)),
        )
        gd, _ = read_grid_descriptor(buf, 1, true)
        # grid_type keeps the full string — half detection is in parse_value_type
        @test gd.grid_type == "Tree_float_5_4_3_HalfFloat"
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# 5. read_grid_metadata — all metadata types
# ═══════════════════════════════════════════════════════════════════════════════

@testset "read_grid_metadata" begin
    """Build one metadata entry: key + type + size-prefixed value bytes."""
    function meta_entry(key::String, type_name::String, value_bytes::Vector{UInt8})
        vcat(sized_string(key), sized_string(type_name), le_bytes(UInt32(length(value_bytes))), value_bytes)
    end

    @testset "empty metadata" begin
        buf = le_bytes(UInt32(0))
        meta, pos = read_grid_metadata(buf, 1)
        @test isempty(meta)
        @test pos == 5
    end

    @testset "string value" begin
        buf = vcat(le_bytes(UInt32(1)), meta_entry("class", "string", Vector{UInt8}("fog volume")))
        meta, _ = read_grid_metadata(buf, 1)
        @test meta["class"] == "fog volume"
    end

    @testset "numeric types" begin
        entries = vcat(
            meta_entry("count",  "int32",  le_bytes(Int32(42))),
            meta_entry("big",    "int64",  le_bytes(Int64(-999))),
            meta_entry("scale",  "float",  le_bytes(Float32(3.14))),
            meta_entry("pi",     "double", le_bytes(Float64(3.14159265))),
            meta_entry("active", "bool",   UInt8[0x01]),
        )
        buf = vcat(le_bytes(UInt32(5)), entries)
        meta, _ = read_grid_metadata(buf, 1)

        @test meta["count"]  == Int32(42)
        @test meta["big"]    == Int64(-999)
        @test meta["scale"]  == Float32(3.14)
        @test meta["pi"]     == Float64(3.14159265)
        @test meta["active"] == true
    end

    @testset "vector types" begin
        entries = vcat(
            meta_entry("offset",   "vec3i",  le_bytes(Int32(1), Int32(2), Int32(3))),
            meta_entry("velocity", "vec3s",  le_bytes(Float32(1.0), Float32(2.0), Float32(3.0))),
            meta_entry("center",   "vec3d",  le_bytes(1.0, 2.0, 3.0)),
        )
        buf = vcat(le_bytes(UInt32(3)), entries)
        meta, _ = read_grid_metadata(buf, 1)

        @test meta["offset"]   == (Int32(1), Int32(2), Int32(3))
        @test meta["velocity"] == (Float32(1.0), Float32(2.0), Float32(3.0))
        @test meta["center"]   == (1.0, 2.0, 3.0)
    end

    @testset "unknown type skipped" begin
        entries = vcat(
            meta_entry("mystery", "custom_blob", UInt8[0xDE, 0xAD, 0xBE, 0xEF]),
            meta_entry("class",   "string",      Vector{UInt8}("level set")),
        )
        buf = vcat(le_bytes(UInt32(2)), entries)
        meta, _ = read_grid_metadata(buf, 1)

        @test meta["mystery"] === nothing  # unknown → nothing
        @test meta["class"] == "level set"
    end

    @testset "vec3f alias" begin
        # OpenVDB uses both "vec3f" and "vec3s" for Float32 vectors
        entries = meta_entry("vel", "vec3f", le_bytes(Float32(4.0), Float32(5.0), Float32(6.0)))
        buf = vcat(le_bytes(UInt32(1)), entries)
        meta, _ = read_grid_metadata(buf, 1)
        @test meta["vel"] == (Float32(4.0), Float32(5.0), Float32(6.0))
    end

    @testset "bool false" begin
        buf = vcat(le_bytes(UInt32(1)), meta_entry("flag", "bool", UInt8[0x00]))
        meta, _ = read_grid_metadata(buf, 1)
        @test meta["flag"] == false
    end
end
