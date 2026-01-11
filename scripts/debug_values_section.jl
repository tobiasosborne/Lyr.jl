#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    # Parse header
    header, pos = Lyr.read_header(bytes, 1)
    println("Version: $(header.format_version)")
    println("Compression: $(header.compression)")
    println("Active mask compression: $(header.active_mask_compression)")

    # Skip metadata
    while Lyr.is_metadata_entry(bytes, pos)
        _, pos = Lyr.read_string_with_size(bytes, pos)
        type_name, pos = Lyr.read_string_with_size(bytes, pos)
        pos = Lyr.skip_metadata_value_heuristic(bytes, pos, type_name)
    end
    _, pos = Lyr.read_u32_le(bytes, pos)
    desc, pos = Lyr.read_grid_descriptor(bytes, pos, header.has_grid_offsets)

    grid_data_pos = Int(desc.byte_offset) + 1
    values_start = grid_data_pos + Int(desc.block_offset)

    println("\nGrid type: $(desc.grid_type)")
    println("values_start = $values_start")

    # Try reading the first leaf manually
    pos = values_start
    println("\n=== Manual read at values_start ===")

    # Read metadata byte
    metadata, pos = Lyr.read_u8(bytes, pos)
    println("1. Metadata: $metadata (pos now $pos)")

    # No inactive values for metadata 0
    # No selection mask for metadata 0

    # For dense storage (mask_compressed=false), read all 512 Float32 values
    expected_size = 512 * 4  # 2048 bytes
    println("2. Expected size: $expected_size bytes")
    println("3. Reading chunk_size at pos $pos...")

    # Read chunk_size
    chunk_size = reinterpret(Int64, bytes[pos:pos+7])[1]
    println("4. Chunk size: $chunk_size")

    if chunk_size < 0
        println("   -> Uncompressed data, $(-chunk_size) bytes")
    elseif chunk_size > 0
        println("   -> Compressed data, $chunk_size bytes")
    else
        println("   -> Empty data (chunk_size = 0)")
    end

    # Show bytes at pos
    println("\n5. Bytes at pos $pos:")
    for i in 0:15
        print(string(bytes[pos + i], base=16, pad=2), " ")
    end
    println()

    # What if metadata byte isn't 0?
    println("\n=== Alternative: Skip metadata, read raw bytes ===")
    pos2 = values_start
    println("Reading 20 Float32 values starting at position $pos2:")
    for i in 1:20
        v = reinterpret(Float32, bytes[pos2:pos2+3])[1]
        println("  Value $i at $pos2: $v $(abs(v) < 1.0 ? "(valid)" : "")")
        pos2 += 4
    end
end
main()
