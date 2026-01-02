@testset "Masks" begin
    @testset "Construction" begin
        # All zeros
        m = Mask{64}()
        @test is_empty(m)
        @test count_on(m) == 0
        @test count_off(m) == 64

        # All ones
        m = Mask{64}(Val(:ones))
        @test is_full(m)
        @test count_on(m) == 64
        @test count_off(m) == 0

        # Non-64-multiple size
        m = Mask{100}()
        @test count_off(m) == 100

        m = Mask{100}(Val(:ones))
        @test count_on(m) == 100
    end

    @testset "Bit access" begin
        # Create mask with single bit set
        words = (UInt64(1),)
        m = Mask{64}(words)
        @test is_on(m, 0)
        @test is_off(m, 1)

        # Bit at position 63
        words = (UInt64(1) << 63,)
        m = Mask{64}(words)
        @test is_on(m, 63)
        @test is_off(m, 0)

        # Multi-word: bit at position 64
        words = (UInt64(0), UInt64(1))
        m = Mask{128}(words)
        @test is_off(m, 63)
        @test is_on(m, 64)
        @test is_off(m, 65)

        # Bit at position 65
        words = (UInt64(0), UInt64(2))
        m = Mask{128}(words)
        @test is_on(m, 65)
    end

    @testset "Counts" begin
        # Alternating bits
        words = (0x5555555555555555,)
        m = Mask{64}(words)
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
        m = Mask{64}(words)
        indices = collect(on_indices(m))
        @test indices == [0]

        # Multiple bits
        words = (UInt64(0b1010),)  # bits 1 and 3
        m = Mask{64}(words)
        indices = collect(on_indices(m))
        @test indices == [1, 3]

        # Cross word boundary
        words = (UInt64(1) << 63, UInt64(1))  # bits 63 and 64
        m = Mask{128}(words)
        indices = collect(on_indices(m))
        @test indices == [63, 64]

        # Empty mask
        m = Mask{64}()
        @test isempty(collect(on_indices(m)))

        # Full mask
        m = Mask{8}(Val(:ones))
        @test collect(on_indices(m)) == [0, 1, 2, 3, 4, 5, 6, 7]
    end

    @testset "Iteration - off_indices" begin
        words = (UInt64(0b1010),)
        m = Mask{4}(words)
        indices = collect(off_indices(m))
        @test indices == [0, 2]
    end

    @testset "Iteration order" begin
        # Verify ascending order
        m = Mask{512}(Val(:ones))
        indices = collect(on_indices(m))
        @test issorted(indices)
        @test indices == collect(0:511)
    end

    @testset "Count consistency" begin
        # count_on should equal length of on_indices
        for N in [64, 100, 512]
            m = Mask{N}(Val(:ones))
            @test count_on(m) == length(collect(on_indices(m)))
        end
    end

    @testset "Type aliases" begin
        @test LeafMask == Mask{512}
        @test Internal1Mask == Mask{4096}
        @test Internal2Mask == Mask{32768}
    end

    @testset "read_mask" begin
        # Create bytes for a known mask
        bytes = zeros(UInt8, 8)
        bytes[1] = 0x01  # Bit 0 set

        m, pos = read_mask(Mask{64}, bytes, 1)
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
end
