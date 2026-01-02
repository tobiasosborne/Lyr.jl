@testset "Compression" begin
    @testset "NoCompression" begin
        codec = NoCompression()
        data = UInt8[1, 2, 3, 4, 5]

        result = decompress(codec, data)
        @test result == data
        @test result !== data  # Should be a copy or the same reference is fine

        # Empty data
        @test decompress(codec, UInt8[]) == UInt8[]
    end

    @testset "BloscCodec" begin
        codec = BloscCodec()

        # Test with known compressible data
        original = repeat(UInt8[1, 2, 3, 4], 100)

        # Compress then decompress
        using CodecBlosc
        compressed = transcode(BloscCompressor, original)
        decompressed = decompress(codec, compressed)

        @test decompressed == original

        # Empty data
        @test decompress(codec, UInt8[]) == UInt8[]
    end

    @testset "ZipCodec" begin
        codec = ZipCodec()

        # Test with known compressible data
        original = repeat(UInt8[1, 2, 3, 4], 100)

        # Compress then decompress
        using CodecZlib
        compressed = transcode(ZlibCompressor, original)
        decompressed = decompress(codec, compressed)

        @test decompressed == original

        # Empty data
        @test decompress(codec, UInt8[]) == UInt8[]
    end

    @testset "Incompressible data" begin
        # Random data is hard to compress
        using Random
        Random.seed!(42)
        original = rand(UInt8, 1000)

        # Blosc
        using CodecBlosc
        compressed = transcode(BloscCompressor, original)
        decompressed = decompress(BloscCodec(), compressed)
        @test decompressed == original

        # Zlib
        using CodecZlib
        compressed = transcode(ZlibCompressor, original)
        decompressed = decompress(ZipCodec(), compressed)
        @test decompressed == original
    end

    @testset "read_compressed_bytes" begin
        # Create a compressed block with size prefix
        original = repeat(UInt8[0xab], 100)

        # No compression
        bytes = vcat(
            reinterpret(UInt8, [UInt64(100)]),  # size
            original                             # data
        )

        result, pos = read_compressed_bytes(bytes, 1, NoCompression(), 100)
        @test result == original
        @test pos == 109  # 8 bytes size + 100 bytes data + 1

        # Empty block
        bytes = reinterpret(UInt8, [UInt64(0)])
        result, pos = read_compressed_bytes(bytes, 1, NoCompression(), 0)
        @test result == UInt8[]
    end
end
