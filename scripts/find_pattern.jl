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

    # First thing at values_start: check if it's a metadata byte + chunk_size + zlib data
    # OR just raw bytes

    # Let's look at the actual byte pattern
    println("\n=== Analysis of values_start structure ===")
    println("First 80 bytes from values_start:")
    for row in 0:4
        print("$(values_start + row*16): ")
        for col in 0:15
            print(string(bytes[values_start + row*16 + col], base=16, pad=2), " ")
        end
        println()
    end

    # The pattern seems to be:
    # - zeros at first
    # - then some mask-like bytes
    # - then Float32 values

    # Maybe the format is:
    # [1 byte metadata][8 byte uncompressed chunk_size][data...]
    # where chunk_size could be negative (meaning uncompressed)

    pos = values_start
    meta = bytes[pos]
    println("\n\nMetadata byte: $meta")

    pos += 1
    chunk_i64 = reinterpret(Int64, bytes[pos:pos+7])[1]
    println("Next 8 bytes as Int64: $chunk_i64")

    if chunk_i64 < 0
        uncompressed_size = -chunk_i64
        println("  -> Uncompressed size: $uncompressed_size bytes")
        println("  -> $( ÷(uncompressed_size, 4)) Float32 values")
    elseif chunk_i64 == 0
        println("  -> Zero (empty data)")
    else
        println("  -> Compressed size: $chunk_i64 bytes")
    end

    # What if chunk_size of 0 means "use raw format" or "use different encoding"?
    # Let's see what bytes follow after the first 9 bytes

    data_start = values_start + 9
    println("\n\nBytes at position $data_start (after metadata + chunk_size):")
    for i in 0:31
        print(string(bytes[data_start + i], base=16, pad=2), " ")
        (i+1) % 16 == 0 && println()
    end

    # Are these Float32 values?
    println("\n\nAs Float32 from position $data_start:")
    for i in 1:8
        v = reinterpret(Float32, bytes[data_start + (i-1)*4:data_start + (i-1)*4 + 3])[1]
        println("  $i: $v $(abs(v) < 1.0 ? "(valid)" : "")")
    end
end
main()
