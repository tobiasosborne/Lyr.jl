#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    header, pos = Lyr.read_header(bytes, 1)
    while Lyr.is_metadata_entry(bytes, pos)
        _, pos = Lyr.read_string_with_size(bytes, pos)
        type_name, pos = Lyr.read_string_with_size(bytes, pos)
        pos = Lyr.skip_metadata_value_heuristic(bytes, pos, type_name)
    end
    _, pos = Lyr.read_u32_le(bytes, pos)
    desc, pos = Lyr.read_grid_descriptor(bytes, pos, header.has_grid_offsets)

    grid_data_pos = Int(desc.byte_offset) + 1
    values_start = grid_data_pos + Int(desc.block_offset)

    println("values_start = $values_start")
    println("compression = $(header.compression)")
    println("active_mask_compression = $(header.active_mask_compression)")

    # Read per the VDB format
    pos = values_start

    # First leaf's values:
    # 1. Metadata byte
    metadata, pos = Lyr.read_u8(bytes, pos)
    println("\nMetadata byte: $metadata")

    # 2. For metadata=0: no extra inactive values, no selection mask
    # 3. Read chunk_size
    chunk_size, pos = Lyr.read_i64_le(bytes, pos)
    println("Chunk size: $chunk_size")

    # According to tinyvdbio, if chunk_size <= 0, read raw data
    # expected_size depends on COMPRESS_ACTIVE_MASK flag
    # torus.vdb has mask_compressed=false, so all 512 values
    expected_size = 512 * 4  # 2048 bytes

    if chunk_size <= 0
        println("\nchunk_size <= 0: Reading $expected_size raw bytes from position $pos")

        # Read first 10 Float32 values
        println("\nFirst 10 Float32 values:")
        for i in 1:10
            v = reinterpret(Float32, bytes[pos:pos+3])[1]
            println("  $i at $pos: $v")
            pos += 4
        end
    else
        println("chunk_size > 0: Would decompress $chunk_size bytes")
    end
end
main()
