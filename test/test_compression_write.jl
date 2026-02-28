# test_compression_write.jl - Tests for write-side compression (Zip/Blosc)
#
# Tests:
# 1. compress/decompress round-trip for all codecs
# 2. write_vdb with ZipCodec round-trip
# 3. write_vdb with BloscCodec round-trip
# 4. Compressed file is smaller than uncompressed

@testset "Compression Write" begin
    # Build a test grid with enough data to compress
    data = Dict{Coord, Float32}()
    for x in 0:15, y in 0:15, z in 0:15
        data[coord(x, y, z)] = Float32(x + y + z)
    end
    bg = 0.0f0
    grid = build_grid(data, bg)

    @testset "compress/decompress round-trip" begin
        raw = UInt8[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

        @test compress(NoCompression(), raw) == raw
        @test decompress(ZipCodec(), compress(ZipCodec(), raw)) == raw
        @test decompress(BloscCodec(), compress(BloscCodec(), raw)) == raw
    end

    @testset "compress/decompress empty data" begin
        empty = UInt8[]

        @test compress(NoCompression(), empty) == empty
        @test compress(ZipCodec(), empty) == empty
        @test compress(BloscCodec(), empty) == empty
    end

    @testset "write_vdb with ZipCodec round-trip" begin
        path = tempname() * ".vdb"
        try
            write_vdb(path, grid; codec=ZipCodec())
            vdb = parse_vdb(path)
            parsed_grid = vdb.grids[1]

            @test active_voxel_count(parsed_grid.tree) == active_voxel_count(grid.tree)
            for (c, v) in active_voxels(grid.tree)
                @test get_value(parsed_grid.tree, c) ≈ v
            end
        finally
            rm(path; force=true)
        end
    end

    @testset "write_vdb with BloscCodec round-trip" begin
        path = tempname() * ".vdb"
        try
            write_vdb(path, grid; codec=BloscCodec())
            vdb = parse_vdb(path)
            parsed_grid = vdb.grids[1]

            @test active_voxel_count(parsed_grid.tree) == active_voxel_count(grid.tree)
            for (c, v) in active_voxels(grid.tree)
                @test get_value(parsed_grid.tree, c) ≈ v
            end
        finally
            rm(path; force=true)
        end
    end

    @testset "compressed file is smaller" begin
        path_none = tempname() * ".vdb"
        path_zip = tempname() * ".vdb"
        try
            write_vdb(path_none, grid)
            write_vdb(path_zip, grid; codec=ZipCodec())
            @test filesize(path_zip) < filesize(path_none)
        finally
            rm(path_none; force=true)
            rm(path_zip; force=true)
        end
    end
end
