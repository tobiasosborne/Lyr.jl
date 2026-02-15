@testset "TreeRead" begin
    # Helpers for constructing synthetic byte arrays
    f32_bytes(x::Float32) = collect(reinterpret(UInt8, [x]))
    u32_bytes(x::UInt32)  = collect(reinterpret(UInt8, [x]))
    i32_bytes(x::Int32)   = collect(reinterpret(UInt8, [x]))
    u64_bytes(x::UInt64)  = collect(reinterpret(UInt8, [x]))

    # Build a mask from on-bit indices, returning raw bytes
    function mask_bytes(N::Int, on_bits::Vector{Int})
        W = cld(N, 64)
        words = zeros(UInt64, W)
        for b in on_bits
            word_idx = (b >> 6) + 1
            bit_idx = b & 63
            words[word_idx] |= UInt64(1) << bit_idx
        end
        collect(reinterpret(UInt8, words))
    end

    leaf_mask_bytes(bits)   = mask_bytes(512,   bits)
    i1_mask_bytes(bits)     = mask_bytes(4096,  bits)
    i2_mask_bytes(bits)     = mask_bytes(32768, bits)

    # =========================================================================
    # _decode_values
    # =========================================================================

    @testset "_decode_values: full precision Float32" begin
        data = vcat(f32_bytes(1.0f0), f32_bytes(2.0f0), f32_bytes(3.0f0))
        vals = Lyr._decode_values(Float32, data, 3, 4)
        @test vals == [1.0f0, 2.0f0, 3.0f0]
    end

    @testset "_decode_values: half precision Float32" begin
        data = collect(reinterpret(UInt8, Float16[1.0, 2.0, 3.0]))
        vals = Lyr._decode_values(Float32, data, 3, 2)
        @test vals == Float32[1.0, 2.0, 3.0]
    end

    @testset "_decode_values: half precision Float64" begin
        data = collect(reinterpret(UInt8, Float16[1.0, 2.0]))
        vals = Lyr._decode_values(Float64, data, 2, 2)
        @test vals == Float64[1.0, 2.0]
    end

    @testset "_decode_values: half precision Vec3f" begin
        data = collect(reinterpret(UInt8, Float16[1.0, 2.0, 3.0, 4.0, 5.0, 6.0]))
        vals = Lyr._decode_values(NTuple{3,Float32}, data, 2, 6)
        @test vals[1] == (1.0f0, 2.0f0, 3.0f0)
        @test vals[2] == (4.0f0, 5.0f0, 6.0f0)
    end

    @testset "_decode_values: unsupported half type errors" begin
        data = UInt8[0x00, 0x00]
        @test_throws ErrorException Lyr._decode_values(Int32, data, 1, 2)
    end

    # =========================================================================
    # align_to_16
    # =========================================================================

    @testset "align_to_16" begin
        # Position 1 is already 16-byte aligned (byte 0 in 0-indexed)
        @test Lyr.align_to_16(1) == 1
        # Position 2 should align to 17
        @test Lyr.align_to_16(2) == 17
        # Position 16 should align to 17
        @test Lyr.align_to_16(16) == 17
        # Position 17 is aligned (byte 16 in 0-indexed)
        @test Lyr.align_to_16(17) == 17
        # Position 33 is aligned (byte 32 in 0-indexed)
        @test Lyr.align_to_16(33) == 33
    end

    # =========================================================================
    # read_internal_tiles
    # =========================================================================

    @testset "read_internal_tiles: empty mask" begin
        mask = LeafMask()  # all off
        buf = UInt8[]
        vals, pos = Lyr.read_internal_tiles(Float32, buf, 1, mask)
        @test isempty(vals)
        @test pos == 1
    end

    @testset "read_internal_tiles: two tiles" begin
        # Mask with bits 0, 1 on
        mask = Mask{512,8}(ntuple(i -> i == 1 ? UInt64(3) : UInt64(0), 8))
        buf = UInt8[]
        # Tile 1: value 10.0f0 + active byte 1
        append!(buf, f32_bytes(10.0f0))
        push!(buf, 0x01)
        # Tile 2: value 20.0f0 + active byte 0
        append!(buf, f32_bytes(20.0f0))
        push!(buf, 0x00)

        vals, pos = Lyr.read_internal_tiles(Float32, buf, 1, mask)
        @test length(vals) == 2
        @test vals[1] == 10.0f0
        @test vals[2] == 20.0f0
        @test pos == 11  # 2 * (4 + 1) + 1
    end

    # =========================================================================
    # read_leaf_values_v222_raw
    # =========================================================================

    @testset "read_leaf_values_v222_raw: sparse selection" begin
        # Selection mask: only bits 0 and 2 on
        sel_words = ntuple(i -> i == 1 ? UInt64(5) : UInt64(0), 8)  # bits 0, 2
        sel_mask = Mask{512,8}(sel_words)

        buf = UInt8[]
        # Bit 0: stored value
        append!(buf, f32_bytes(100.0f0))
        # Bit 1: not in selection → background
        # Bit 2: stored value
        append!(buf, f32_bytes(200.0f0))
        # Bits 3-511: not in selection → background
        background = -1.0f0

        vals, pos = Lyr.read_leaf_values_v222_raw(Float32, buf, 1, sel_mask, background)
        @test vals[1] == 100.0f0
        @test vals[2] == -1.0f0  # background
        @test vals[3] == 200.0f0
        @test vals[4] == -1.0f0  # background
        @test pos == 9  # 2 * 4 + 1
    end

    # =========================================================================
    # Minimal v222+ single-leaf tree (integration)
    # =========================================================================

    @testset "read_tree_v222: minimal single-leaf tree" begin
        background = 0.0f0
        codec = NoCompression()
        mask_compressed = true
        version = UInt32(224)

        buf = UInt8[]

        # --- Root header ---
        append!(buf, u32_bytes(UInt32(0)))  # tile_count = 0
        append!(buf, u32_bytes(UInt32(1)))  # child_count = 1

        # --- Root child origin (0, 0, 0) ---
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, i32_bytes(Int32(0)))

        # --- I2 topology ---
        # I2 child_mask: bit 0 on (one I1 child)
        append!(buf, i2_mask_bytes([0]))
        # I2 value_mask: all off (no tiles)
        append!(buf, i2_mask_bytes(Int[]))
        # I2 ReadMaskValues: metadata=0, 0 active values (value_mask all off) → just metadata byte
        push!(buf, 0x00)
        # NoCompression, expected_size=0 → read_bytes reads 0 bytes, no data needed

        # --- I1 topology (child of I2 bit 0) ---
        # I1 child_mask: bit 0 on (one leaf child)
        append!(buf, i1_mask_bytes([0]))
        # I1 value_mask: all off (no tiles)
        append!(buf, i1_mask_bytes(Int[]))
        # I1 ReadMaskValues: metadata=0, 0 active values → just metadata byte
        push!(buf, 0x00)

        # --- Leaf topology (child of I1 bit 0) ---
        # Leaf value_mask: bits 0, 1 on (2 active voxels)
        append!(buf, leaf_mask_bytes([0, 1]))

        # === Values section ===

        # --- Leaf values (v222+ format) ---
        # Re-emitted value_mask (64 bytes)
        append!(buf, leaf_mask_bytes([0, 1]))
        # ReadMaskValues: metadata=0, sparse: 2 active Float32 values
        push!(buf, 0x00)
        append!(buf, f32_bytes(42.0f0))
        append!(buf, f32_bytes(43.0f0))

        tree, _ = Lyr.read_tree_v222(Float32, buf, 1, codec, mask_compressed, background, GRID_FOG_VOLUME, version)

        # Verify tree structure
        @test tree.background == 0.0f0
        @test length(tree.table) == 1

        # Get the single I2 node
        i2_node = tree.table[coord(Int32(0), Int32(0), Int32(0))]
        @test i2_node isa InternalNode2{Float32}

        # Check I2 has one child
        @test count_on(i2_node.child_mask) == 1

        # Get I1 node
        i1_node = i2_node.table[1]
        @test i1_node isa InternalNode1{Float32}
        @test count_on(i1_node.child_mask) == 1

        # Get leaf node
        leaf = i1_node.table[1]
        @test leaf isa LeafNode{Float32}
        @test leaf.values[1] == 42.0f0  # bit 0 active
        @test leaf.values[2] == 43.0f0  # bit 1 active
        @test leaf.values[3] == 0.0f0   # inactive → background
    end

    # =========================================================================
    # read_tree dispatch
    # =========================================================================

    @testset "read_tree: dispatches to v222+ for version >= 222" begin
        # Build same minimal tree as above
        background = 0.0f0
        codec = NoCompression()
        buf = UInt8[]

        append!(buf, u32_bytes(UInt32(0)))
        append!(buf, u32_bytes(UInt32(1)))
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, i2_mask_bytes([0]))
        append!(buf, i2_mask_bytes(Int[]))
        push!(buf, 0x00)
        append!(buf, i1_mask_bytes([0]))
        append!(buf, i1_mask_bytes(Int[]))
        push!(buf, 0x00)
        append!(buf, leaf_mask_bytes([0]))
        append!(buf, leaf_mask_bytes([0]))
        push!(buf, 0x00)
        append!(buf, f32_bytes(7.0f0))

        tree, _ = Lyr.read_tree(Float32, buf, 1, codec, true, background, GRID_FOG_VOLUME, UInt32(224))
        i2 = tree.table[coord(Int32(0), Int32(0), Int32(0))]
        leaf = i2.table[1].table[1]
        @test leaf.values[1] == 7.0f0
    end

    # =========================================================================
    # v222+ tree with root tiles
    # =========================================================================

    @testset "read_tree_v222: tree with root tiles only" begin
        background = 0.0f0
        codec = NoCompression()
        buf = UInt8[]

        # 2 root tiles, 0 children
        append!(buf, u32_bytes(UInt32(2)))
        append!(buf, u32_bytes(UInt32(0)))

        # Tile 1: origin (0,0,0), value 5.0, active
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, f32_bytes(5.0f0))
        push!(buf, 0x01)

        # Tile 2: origin (4096,0,0), value 10.0, inactive
        append!(buf, i32_bytes(Int32(4096)))
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, i32_bytes(Int32(0)))
        append!(buf, f32_bytes(10.0f0))
        push!(buf, 0x00)

        tree, _ = Lyr.read_tree_v222(Float32, buf, 1, codec, true, background, GRID_FOG_VOLUME, UInt32(224))
        @test length(tree.table) == 2

        t1 = tree.table[coord(Int32(0), Int32(0), Int32(0))]
        @test t1 isa Tile{Float32}
        @test t1.value == 5.0f0
        @test t1.active == true

        t2 = tree.table[coord(Int32(4096), Int32(0), Int32(0))]
        @test t2 isa Tile{Float32}
        @test t2.value == 10.0f0
        @test t2.active == false
    end
end
