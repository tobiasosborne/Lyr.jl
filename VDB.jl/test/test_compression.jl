@testset "Compression" begin
    @testset "NoCompression" begin
        codec = NoCompression()
        data = UInt8[1, 2, 3, 4, 5]

        result = VDB.decompress(codec, data)
        @test result == data

        # Empty data
        @test VDB.decompress(codec, UInt8[]) == UInt8[]
    end

    @testset "BloscCodec" begin
        codec = BloscCodec()

        # Test with known compressible data
        original = repeat(UInt8[1, 2, 3, 4], 100)

        # Compress then decompress using Blosc.jl
        import Blosc
        compressed = Blosc.compress(original)
        decompressed = VDB.decompress(codec, compressed)

        @test decompressed == original

        # Empty data
        @test VDB.decompress(codec, UInt8[]) == UInt8[]
    end

    @testset "ZipCodec" begin
        codec = ZipCodec()

        # Test with known compressible data
        original = repeat(UInt8[1, 2, 3, 4], 100)

        # Compress then decompress
        import CodecZlib: ZlibCompressor, transcode
        compressed = transcode(ZlibCompressor, original)
        decompressed = VDB.decompress(codec, compressed)

        @test decompressed == original

        # Empty data
        @test VDB.decompress(codec, UInt8[]) == UInt8[]
    end

    @testset "Incompressible data" begin
        # Random data is hard to compress
        using Random
        Random.seed!(42)
        original = rand(UInt8, 1000)

        # Blosc
        import Blosc
        compressed = Blosc.compress(original)
        decompressed = VDB.decompress(BloscCodec(), compressed)
        @test decompressed == original

        # Zlib
        import CodecZlib: ZlibCompressor, transcode
        compressed = transcode(ZlibCompressor, original)
        decompressed = VDB.decompress(ZipCodec(), compressed)
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
end
