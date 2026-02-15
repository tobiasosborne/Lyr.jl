@testset "Masks" begin
    @testset "Construction" begin
        # All zeros (64 bits = 1 word)
        m = Mask{64,1}()
        @test is_empty(m)
        @test count_on(m) == 0
        @test count_off(m) == 64

        # All ones
        m = Mask{64,1}(Val(:ones))
        @test is_full(m)
        @test count_on(m) == 64
        @test count_off(m) == 0

        # Non-64-multiple size (100 bits = 2 words)
        m = Mask{100,2}()
        @test count_off(m) == 100

        m = Mask{100,2}(Val(:ones))
        @test count_on(m) == 100
    end

    @testset "Bit access" begin
        # Create mask with single bit set
        words = (UInt64(1),)
        m = Mask{64,1}(words)
        @test is_on(m, 0)
        @test is_off(m, 1)

        # Bit at position 63
        words = (UInt64(1) << 63,)
        m = Mask{64,1}(words)
        @test is_on(m, 63)
        @test is_off(m, 0)

        # Multi-word: bit at position 64 (128 bits = 2 words)
        words = (UInt64(0), UInt64(1))
        m = Mask{128,2}(words)
        @test is_off(m, 63)
        @test is_on(m, 64)
        @test is_off(m, 65)

        # Bit at position 65
        words = (UInt64(0), UInt64(2))
        m = Mask{128,2}(words)
        @test is_on(m, 65)
    end

    @testset "Counts" begin
        # Alternating bits
        words = (0x5555555555555555,)
        m = Mask{64,1}(words)
        @test count_on(m) == 32
        @test count_off(m) == 32

        # LeafMask (512 bits = 8 words)
        m = LeafMask()
        @test count_on(m) == 0

        m = LeafMask(Val(:ones))
        @test count_on(m) == 512
    end

    @testset "Iteration - on_indices" begin
        # Single bit
        words = (UInt64(1),)
        m = Mask{64,1}(words)
        indices = collect(on_indices(m))
        @test indices == [0]

        # Multiple bits
        words = (UInt64(0b1010),)  # bits 1 and 3
        m = Mask{64,1}(words)
        indices = collect(on_indices(m))
        @test indices == [1, 3]

        # Cross word boundary
        words = (UInt64(1) << 63, UInt64(1))  # bits 63 and 64
        m = Mask{128,2}(words)
        indices = collect(on_indices(m))
        @test indices == [63, 64]

        # Empty mask
        m = Mask{64,1}()
        @test isempty(collect(on_indices(m)))

        # Full mask (8 bits = 1 word)
        m = Mask{8,1}(Val(:ones))
        @test collect(on_indices(m)) == [0, 1, 2, 3, 4, 5, 6, 7]
    end

    @testset "Iteration - off_indices" begin
        words = (UInt64(0b1010),)
        m = Mask{4,1}(words)
        indices = collect(off_indices(m))
        @test indices == [0, 2]
    end

    @testset "Iteration order" begin
        # Verify ascending order using LeafMask (512 bits = 8 words)
        m = Mask{512,8}(Val(:ones))
        indices = collect(on_indices(m))
        @test issorted(indices)
        @test indices == collect(0:511)
    end

    @testset "Count consistency" begin
        # count_on should equal length of on_indices
        # 64 bits = 1 word, 100 bits = 2 words, 512 bits = 8 words
        for (N, W) in [(64, 1), (100, 2), (512, 8)]
            m = Mask{N,W}(Val(:ones))
            @test count_on(m) == length(collect(on_indices(m)))
        end
    end

    @testset "Type aliases" begin
        @test LeafMask == Mask{512, 8}
        @test Internal1Mask == Mask{4096, 64}
        @test Internal2Mask == Mask{32768, 512}
    end

    @testset "Word boundary 127-128" begin
        # Bits at 127 and 128 (crosses second word boundary)
        words = (UInt64(0), UInt64(1) << 63, UInt64(1))  # bits 127 and 128
        m = Mask{192,3}(words)
        @test is_off(m, 126)
        @test is_on(m, 127)
        @test is_on(m, 128)
        @test is_off(m, 129)
    end

    @testset "read_mask" begin
        # Create bytes for a known mask
        bytes = zeros(UInt8, 8)
        bytes[1] = 0x01  # Bit 0 set

        m, pos = read_mask(Mask{64,1}, bytes, 1)
        @test is_on(m, 0)
        @test count_on(m) == 1
        @test pos == 9

        # LeafMask (64 bytes = 8 words)
        bytes = zeros(UInt8, 64)
        bytes[1] = 0xff  # First 8 bits set

        m, pos = read_mask(LeafMask, bytes, 1)
        @test count_on(m) == 8
        @test pos == 65
    end

    @testset "count_on_before" begin
        # Single word mask
        words = (UInt64(0b1010),)  # bits 1 and 3
        m = Mask{64,1}(words)

        # Before bit 0: no bits set
        @test count_on_before(m, 0) == 0
        # Before bit 1: no bits set (bit 1 is at position 1)
        @test count_on_before(m, 1) == 0
        # Before bit 2: bit 1 is set
        @test count_on_before(m, 2) == 1
        # Before bit 3: bit 1 is set
        @test count_on_before(m, 3) == 1
        # Before bit 4: bits 1 and 3 are set
        @test count_on_before(m, 4) == 2

        # Multi-word mask: bits at positions 0, 63, 64, 127
        words = (UInt64(1) | (UInt64(1) << 63), UInt64(1) | (UInt64(1) << 63))
        m = Mask{128,2}(words)

        @test count_on_before(m, 0) == 0    # Nothing before bit 0
        @test count_on_before(m, 1) == 1    # Bit 0 is set
        @test count_on_before(m, 63) == 1   # Only bit 0 before 63
        @test count_on_before(m, 64) == 2   # Bits 0, 63 before 64
        @test count_on_before(m, 65) == 3   # Bits 0, 63, 64 before 65
        @test count_on_before(m, 127) == 3  # Bits 0, 63, 64 before 127

        # Verify consistency: count_on_before(m, i) + 1 == position in on_indices for bit i
        words = (UInt64(0b10110001),)  # bits 0, 4, 5, 7
        m = Mask{64,1}(words)
        indices = collect(on_indices(m))
        for (pos, idx) in enumerate(indices)
            @test count_on_before(m, idx) + 1 == pos
        end

        # Edge case: first bit in second word
        words = (UInt64(0), UInt64(1))  # only bit 64 is set
        m = Mask{128,2}(words)
        @test count_on_before(m, 64) == 0  # No bits before bit 64
    end

    @testset "Round-trip: read what you write" begin
        # Create a mask with known pattern
        original_words = (0xdeadbeefcafebabe, 0x123456789abcdef0)
        original = Mask{128,2}(original_words)

        # Convert to bytes (little-endian)
        bytes = zeros(UInt8, 16)
        for (i, word) in enumerate(original_words)
            for j in 0:7
                bytes[(i-1)*8 + j + 1] = UInt8((word >> (8*j)) & 0xff)
            end
        end

        # Read back
        recovered, pos = read_mask(Mask{128,2}, bytes, 1)
        @test pos == 17
        @test recovered.words == original.words
        @test count_on(recovered) == count_on(original)
    end
end
