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

    @testset "read_tile_value Int32" begin
        bytes = collect(reinterpret(UInt8, Int32[42]))
        val, pos = read_tile_value(Int32, bytes, 1)
        @test val == Int32(42)
        @test pos == 5
    end

    @testset "read_tile_value Int64" begin
        bytes = collect(reinterpret(UInt8, Int64[-1]))
        val, pos = read_tile_value(Int64, bytes, 1)
        @test val == Int64(-1)
        @test pos == 9
    end

    @testset "read_tile_value Bool" begin
        bytes = UInt8[0x01, 0x00]
        val, pos = read_tile_value(Bool, bytes, 1)
        @test val === true
        @test pos == 2
        val, pos = read_tile_value(Bool, bytes, 2)
        @test val === false
        @test pos == 3
    end

    @testset "read_tile_value unsupported type errors" begin
        bytes = zeros(UInt8, 16)
        @test_throws ArgumentError read_tile_value(UInt16, bytes, 1)
    end

    # =========================================================================
    # read_dense_values — unit tests for all 7 metadata flags (0-6)
    #
    # Uses LeafMask (N=512, W=8) with NoCompression for simple byte construction.
    # Each test builds synthetic bytes matching the on-disk format:
    #   [metadata 1B] [inactive vals?] [selection mask 64B?] [raw values...]
    # =========================================================================

    # Helper: build a LeafMask with specific bits on
    function make_leaf_mask(on_bits::Vector{Int})
        words = zeros(UInt64, 8)
        for b in on_bits
            word_idx = (b >> 6) + 1
            bit_idx = b & 63
            words[word_idx] |= UInt64(1) << bit_idx
        end
        Mask{512,8}(NTuple{8,UInt64}(words))
    end

    # Helper: encode Float32 as little-endian bytes
    f32_bytes(x::Float32) = collect(reinterpret(UInt8, [x]))

    @testset "read_dense_values: flag 0 — NO_MASK_OR_INACTIVE_VALS" begin
        # Inactive voxels get background value. Sparse: only active values stored.
        background = 99.0f0
        mask = make_leaf_mask([0, 2, 4])  # 3 active bits
        buf = UInt8[]
        push!(buf, 0x00)  # metadata = 0
        # No inactive values, no selection mask
        # Sparse data: 3 active Float32 values
        append!(buf, f32_bytes(1.0f0))
        append!(buf, f32_bytes(2.0f0))
        append!(buf, f32_bytes(3.0f0))

        vals, new_pos = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), true, mask, background)
        @test length(vals) == 512
        @test vals[1] == 1.0f0   # bit 0 active
        @test vals[2] == 99.0f0  # bit 1 inactive → background
        @test vals[3] == 2.0f0   # bit 2 active
        @test vals[4] == 99.0f0  # bit 3 inactive → background
        @test vals[5] == 3.0f0   # bit 4 active
        @test all(v == 99.0f0 for v in vals[6:512])  # rest inactive → background
    end

    @testset "read_dense_values: flag 1 — NO_MASK_AND_MINUS_BG" begin
        # Inactive voxels get -background.
        background = 5.0f0
        mask = make_leaf_mask([0])  # 1 active bit
        buf = UInt8[]
        push!(buf, 0x01)  # metadata = 1
        # Sparse: 1 active value
        append!(buf, f32_bytes(42.0f0))

        vals, _ = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), true, mask, background)
        @test vals[1] == 42.0f0   # active
        @test vals[2] == -5.0f0   # inactive → -background
        @test vals[512] == -5.0f0
    end

    @testset "read_dense_values: flag 2 — NO_MASK_AND_ONE_INACTIVE_VAL" begin
        # Inactive voxels get an explicitly stored value (not background).
        background = 0.0f0
        mask = make_leaf_mask([1])  # 1 active: bit 1
        buf = UInt8[]
        push!(buf, 0x02)  # metadata = 2
        # One inactive value follows
        append!(buf, f32_bytes(77.0f0))
        # Sparse: 1 active value
        append!(buf, f32_bytes(10.0f0))

        vals, _ = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), true, mask, background)
        @test vals[1] == 77.0f0   # bit 0 inactive → stored inactive val
        @test vals[2] == 10.0f0   # bit 1 active
        @test vals[3] == 77.0f0   # inactive
        @test vals[512] == 77.0f0
    end

    @testset "read_dense_values: flag 3 — MASK_AND_NO_INACTIVE_VALS" begin
        # Two inactive values: background and -background, selected by selection mask.
        # selection_mask on → inactive_val0 (background), off → inactive_val1 (-background)
        background = 3.0f0
        mask = make_leaf_mask([0])  # 1 active: bit 0

        # Build selection mask: bit 1 on, bit 2 off (among inactive bits)
        sel_words = zeros(UInt64, 8)
        sel_words[1] = UInt64(1) << 1  # bit 1 on
        sel_mask_bytes = collect(reinterpret(UInt8, sel_words))

        buf = UInt8[]
        push!(buf, 0x03)  # metadata = 3
        # No inline inactive values (bg and -bg are implied)
        append!(buf, sel_mask_bytes)  # 64 bytes selection mask
        # Sparse: 1 active value
        append!(buf, f32_bytes(50.0f0))

        vals, _ = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), true, mask, background)
        @test vals[1] == 50.0f0   # bit 0 active
        @test vals[2] == 3.0f0    # bit 1 inactive, sel ON → inactive_val0 = background
        @test vals[3] == -3.0f0   # bit 2 inactive, sel OFF → inactive_val1 = -background
    end

    @testset "read_dense_values: flag 4 — MASK_AND_ONE_INACTIVE_VAL" begin
        # inactive_val0 = background, inactive_val1 = explicit value, selected by selection mask.
        background = 1.0f0
        mask = make_leaf_mask([0])  # 1 active: bit 0

        sel_words = zeros(UInt64, 8)
        sel_words[1] = UInt64(1) << 2  # bit 2 on
        sel_mask_bytes = collect(reinterpret(UInt8, sel_words))

        buf = UInt8[]
        push!(buf, 0x04)  # metadata = 4
        # One explicit inactive value (inactive_val1)
        append!(buf, f32_bytes(88.0f0))
        append!(buf, sel_mask_bytes)  # 64 bytes selection mask
        # Sparse: 1 active value
        append!(buf, f32_bytes(20.0f0))

        vals, _ = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), true, mask, background)
        @test vals[1] == 20.0f0   # bit 0 active
        @test vals[2] == 88.0f0   # bit 1 inactive, sel OFF → inactive_val1 = 88.0
        @test vals[3] == 1.0f0    # bit 2 inactive, sel ON  → inactive_val0 = background
    end

    @testset "read_dense_values: flag 5 — MASK_AND_TWO_INACTIVE_VALS" begin
        # Two explicit inactive values, selected by selection mask.
        background = 0.0f0
        mask = make_leaf_mask([0])  # 1 active: bit 0

        sel_words = zeros(UInt64, 8)
        sel_words[1] = UInt64(1) << 1  # bit 1 on
        sel_mask_bytes = collect(reinterpret(UInt8, sel_words))

        buf = UInt8[]
        push!(buf, 0x05)  # metadata = 5
        # Two explicit inactive values
        append!(buf, f32_bytes(11.0f0))  # inactive_val0
        append!(buf, f32_bytes(22.0f0))  # inactive_val1
        append!(buf, sel_mask_bytes)  # 64 bytes selection mask
        # Sparse: 1 active value
        append!(buf, f32_bytes(33.0f0))

        vals, _ = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), true, mask, background)
        @test vals[1] == 33.0f0   # bit 0 active
        @test vals[2] == 11.0f0   # bit 1 inactive, sel ON → inactive_val0
        @test vals[3] == 22.0f0   # bit 2 inactive, sel OFF → inactive_val1
    end

    @testset "read_dense_values: flag 6 — NO_MASK_AND_ALL_VALS" begin
        # All 512 values stored densely (no sparse compression), regardless of mask.
        # mask_compressed is true but metadata==6 forces dense read.
        background = 0.0f0
        mask = make_leaf_mask([0, 1])  # doesn't matter, all vals stored

        buf = UInt8[]
        push!(buf, 0x06)  # metadata = 6
        # Dense: all 512 Float32 values
        for i in 1:512
            append!(buf, f32_bytes(Float32(i)))
        end

        vals, _ = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), true, mask, background)
        @test length(vals) == 512
        @test vals[1] == 1.0f0
        @test vals[256] == 256.0f0
        @test vals[512] == 512.0f0
    end

    @testset "read_dense_values: non-sparse (mask_compressed=false)" begin
        # When mask_compressed is false, all N values are stored (no sparse encoding).
        background = 0.0f0
        mask = make_leaf_mask([0, 1, 2])

        buf = UInt8[]
        push!(buf, 0x00)  # metadata = 0
        # Dense: all 512 values
        for i in 1:512
            append!(buf, f32_bytes(Float32(i)))
        end

        vals, _ = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), false, mask, background)
        @test vals[1] == 1.0f0
        @test vals[512] == 512.0f0
    end

    @testset "read_dense_values: half precision (value_size=2)" begin
        # Half-precision: stored as Float16, returned as Float32
        background = 0.0f0
        mask = make_leaf_mask([0, 1])  # 2 active

        buf = UInt8[]
        push!(buf, 0x00)  # metadata = 0
        # Sparse: 2 half-precision (Float16) values
        append!(buf, collect(reinterpret(UInt8, [Float16(1.0)])))
        append!(buf, collect(reinterpret(UInt8, [Float16(2.0)])))

        vals, _ = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), true, mask, background; value_size=2)
        @test vals[1] == 1.0f0
        @test vals[2] == 2.0f0
        @test vals[3] == 0.0f0  # inactive → background
    end

    @testset "read_dense_values: position tracking" begin
        # Verify returned position is correct (bytes consumed)
        background = 0.0f0
        mask = make_leaf_mask([0])  # 1 active

        buf = UInt8[]
        push!(buf, 0x00)  # 1 byte metadata
        append!(buf, f32_bytes(7.0f0))  # 4 bytes value
        push!(buf, 0xff)  # sentinel byte

        vals, new_pos = Lyr.read_dense_values(Float32, buf, 1, NoCompression(), true, mask, background)
        @test new_pos == 6  # 1 (metadata) + 4 (one Float32) + 1 = pos 6
        @test vals[1] == 7.0f0
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
