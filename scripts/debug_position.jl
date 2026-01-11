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

    println("File size: $(length(bytes))")
    println("values_start = $values_start")
    println("Error position = 496477")
    println("Offset into values section: $(496477 - values_start)")

    # Check what's at position 496477
    error_pos = 496477
    println("\nBytes at error position $error_pos:")
    for i in 0:15
        print(string(bytes[error_pos + i], base=16, pad=2), " ")
    end
    println()

    # If this is a chunk_size, what does it look like?
    chunk_i64 = reinterpret(Int64, bytes[error_pos:error_pos+7])[1]
    println("\nAs Int64: $chunk_i64")

    # How many leaves have we processed by this point?
    # values_start = 490225
    # Each leaf: 1 byte metadata + 8 byte chunk_size + 2048 bytes data = 2057 bytes
    # But if uncompressed with chunk_size=0, it's 1 + 8 + 2048 = 2057 bytes
    bytes_per_leaf = 1 + 8 + 2048
    offset = error_pos - values_start
    leaf_num = offset ÷ bytes_per_leaf
    leaf_offset = offset % bytes_per_leaf
    println("\nAssuming $bytes_per_leaf bytes/leaf:")
    println("  At leaf ~$leaf_num, offset $leaf_offset into leaf data")

    # Actually let's trace the first few leaves
    println("\n=== Tracing first 5 leaves ===")
    pos = values_start
    for i in 1:5
        println("\nLeaf $i at position $pos (offset $(pos - values_start)):")
        meta = bytes[pos]
        println("  Metadata: $meta")
        pos += 1

        chunk = reinterpret(Int64, bytes[pos:pos+7])[1]
        println("  Chunk size: $chunk")
        pos += 8

        if chunk <= 0
            # Uncompressed - read expected_size (2048) bytes
            println("  Uncompressed - reading 2048 bytes of data")
            # Show first 4 Float32 values
            for j in 1:4
                v = reinterpret(Float32, bytes[pos + (j-1)*4:pos + (j-1)*4 + 3])[1]
                print("    Value $j: $v")
                if abs(v) < 1.0
                    println(" (valid SDF)")
                else
                    println(" (NOT valid SDF)")
                end
            end
            pos += 2048
        else
            println("  Compressed - $chunk bytes")
            pos += chunk
        end

        println("  Next position: $pos")
    end
end
main()
