@testset "Compression" begin
    @testset "NoCompression" begin
        codec = NoCompression()
        data = UInt8[1, 2, 3, 4, 5]

        result = Lyr.decompress(codec, data)
        @test result == data

        # Empty data
        @test Lyr.decompress(codec, UInt8[]) == UInt8[]
    end

    @testset "BloscCodec" begin
        codec = BloscCodec()

        # Test with known compressible data
        original = repeat(UInt8[1, 2, 3, 4], 100)

        # Compress then decompress using Blosc.jl
        import Blosc
        compressed = Blosc.compress(original)
        decompressed = Lyr.decompress(codec, compressed)

        @test decompressed == original

        # Empty data
        @test Lyr.decompress(codec, UInt8[]) == UInt8[]
    end

    @testset "ZipCodec" begin
        codec = ZipCodec()

        # Test with known compressible data
        original = repeat(UInt8[1, 2, 3, 4], 100)

        # Compress then decompress
        import CodecZlib: ZlibCompressor, transcode
        compressed = transcode(ZlibCompressor, original)
        decompressed = Lyr.decompress(codec, compressed)

        @test decompressed == original

        # Empty data
        @test Lyr.decompress(codec, UInt8[]) == UInt8[]
    end

    @testset "Incompressible data" begin
        # Random data is hard to compress
        using Random
        Random.seed!(42)
        original = rand(UInt8, 1000)

        # Blosc
        import Blosc
        compressed = Blosc.compress(original)
        decompressed = Lyr.decompress(BloscCodec(), compressed)
        @test decompressed == original

        # Zlib
        import CodecZlib: ZlibCompressor, transcode
        compressed = transcode(ZlibCompressor, original)
        decompressed = Lyr.decompress(ZipCodec(), compressed)
        @test decompressed == original
    end

    @testset "read_compressed_bytes" begin
        # NoCompression - just raw data, no size prefix
        original = repeat(UInt8[0xab], 100)

        result, pos = read_compressed_bytes(original, 1, NoCompression(), 100)
        @test result == original
        @test pos == 101  # 100 bytes data + 1

        # Test signed size prefix (negative = uncompressed) with fake codec
        # We'll use BloscCodec but provide uncompressed data indicated by negative size

        # -100 in Int64 LE
        size_val = Int64(-100)
        size_bytes = Vector{UInt8}(undef, 8)
        for i in 0:7
            size_bytes[i+1] = UInt8((size_val >> (8*i)) & 0xff)
        end

        # Data is uncompressed
        bytes = vcat(size_bytes, original)

        # Should read uncompressed data despite codec being Blosc
        result, pos = read_compressed_bytes(bytes, 1, BloscCodec(), 100)
        @test result == original
        @test pos == 109 # 8 bytes size + 100 bytes data + 1

        # Empty block (size 0)
        empty_size_bytes = zeros(UInt8, 8)
        result, pos = read_compressed_bytes(empty_size_bytes, 1, BloscCodec(), 0)
        @test result == UInt8[]
    end

    @testset "read_compressed_bytes with actual compression" begin
        import Blosc
        import CodecZlib: ZlibCompressor, transcode

        # Test with Blosc-compressed data (positive chunk_size)
        original = repeat(UInt8[1, 2, 3, 4], 100)  # 400 bytes
        compressed = Blosc.compress(original)

        # Build size-prefixed block: chunk_size (i64) + compressed data
        chunk_size = Int64(length(compressed))
        size_bytes = reinterpret(UInt8, [chunk_size])
        bytes = vcat(size_bytes, compressed)

        result, pos = read_compressed_bytes(bytes, 1, BloscCodec(), 400)
        @test result == original
        @test pos == 9 + length(compressed)

        # Test with Zlib-compressed data
        compressed_zlib = transcode(ZlibCompressor, original)
        chunk_size_zlib = Int64(length(compressed_zlib))
        size_bytes_zlib = reinterpret(UInt8, [chunk_size_zlib])
        bytes_zlib = vcat(size_bytes_zlib, compressed_zlib)

        result, pos = read_compressed_bytes(bytes_zlib, 1, ZipCodec(), 400)
        @test result == original
        @test pos == 9 + length(compressed_zlib)
    end

    @testset "read_compressed_bytes error handling" begin
        # ChunkSizeMismatchError: uncompressed size doesn't match expected
        original = repeat(UInt8[0xab], 100)
        size_val = Int64(-100)  # Uncompressed, 100 bytes
        size_bytes = reinterpret(UInt8, [size_val])
        bytes = vcat(size_bytes, original)

        # Expect 50 bytes but data says 100
        @test_throws ChunkSizeMismatchError read_compressed_bytes(bytes, 1, BloscCodec(), 50)

        # DecompressionSizeError: decompressed size doesn't match expected
        import Blosc
        original_data = repeat(UInt8[1, 2, 3, 4], 100)  # 400 bytes
        compressed = Blosc.compress(original_data)
        chunk_size = Int64(length(compressed))
        size_bytes = reinterpret(UInt8, [chunk_size])
        bytes = vcat(size_bytes, compressed)

        # Expect 200 bytes but decompression yields 400
        @test_throws DecompressionSizeError read_compressed_bytes(bytes, 1, BloscCodec(), 200)

        # CompressionBoundsError: chunk extends past end of bytes
        # Size says 1000 bytes but we only have 10
        chunk_size = Int64(1000)
        size_bytes = reinterpret(UInt8, [chunk_size])
        short_bytes = vcat(size_bytes, zeros(UInt8, 10))

        @test_throws CompressionBoundsError read_compressed_bytes(short_bytes, 1, BloscCodec(), 1000)
    end

    @testset "read_compressed_bytes at different positions" begin
        # Test reading from middle of byte array
        original = repeat(UInt8[0xcd], 50)
        size_val = Int64(-50)  # Uncompressed
        size_bytes = reinterpret(UInt8, [size_val])

        # Add padding before and after
        padding_before = repeat(UInt8[0x00], 20)
        padding_after = repeat(UInt8[0xff], 30)
        bytes = vcat(padding_before, size_bytes, original, padding_after)

        # Read starting at position 21 (after 20 bytes of padding)
        result, pos = read_compressed_bytes(bytes, 21, BloscCodec(), 50)
        @test result == original
        @test pos == 21 + 8 + 50  # start + size prefix + data
    end
end
