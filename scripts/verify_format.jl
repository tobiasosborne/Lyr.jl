#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    # Parse file structure
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

    println("=== Format verification ===")
    println("values_start = $values_start")

    # With metadata=0 (NO_MASK_OR_INACTIVE_VALS), format should be:
    # [metadata 1 byte] [chunk_size i64] [compressed/uncompressed values]

    # Read metadata byte
    metadata = bytes[values_start]
    println("\nMetadata byte: $metadata")

    # Read chunk_size (8 bytes, signed int64)
    chunk_size = reinterpret(Int64, bytes[values_start+1:values_start+8])[1]
    println("Chunk size: $chunk_size")

    if chunk_size < 0
        println("  -> Uncompressed data, $(-chunk_size) bytes")
        # Values start at values_start + 1 (metadata) + 8 (chunk_size) = values_start + 9
        data_start = values_start + 9
    elseif chunk_size > 0
        println("  -> Compressed data, $chunk_size bytes")
        data_start = values_start + 9
    else
        println("  -> Empty data (chunk_size = 0)")
        data_start = values_start + 9
    end

    println("\nData should start at position $data_start")
    println("First 20 bytes at data start:")
    for i in 0:19
        print(string(bytes[data_start + i], base=16, pad=2), " ")
    end
    println()

    # Try reading Float32 values from data_start
    println("\nAs Float32 values:")
    p = data_start
    for i in 1:10
        v, p = Lyr.read_f32_le(bytes, p)
        println("  Value $i: $v $(abs(v) < 0.5 ? "(valid SDF)" : "")")
    end

    # Now check the actual format with JUST metadata byte (no chunk_size)
    println("\n\n=== Alternative: No chunk_size prefix ===")
    data_start2 = values_start + 1  # Just skip metadata byte
    println("Data at position $data_start2:")
    p = data_start2
    for i in 1:10
        v, p = Lyr.read_f32_le(bytes, p)
        println("  Value $i: $v $(abs(v) < 0.5 ? "(valid SDF)" : "")")
    end

    # And check raw values without any header
    println("\n\n=== Alternative: Raw values at values_start ===")
    println("If values are stored directly (no metadata):")
    p = values_start
    for i in 1:10
        v, p = Lyr.read_f32_le(bytes, p)
        println("  Value $i: $v $(abs(v) < 0.5 ? "(valid SDF)" : "")")
    end
end
main()
