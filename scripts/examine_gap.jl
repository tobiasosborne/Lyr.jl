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

    println("Examining bytes from values_start ($values_start) to values_start+40:")
    println()

    # Show raw bytes with interpretation
    pos = values_start

    println("Position $pos: Metadata byte = $(bytes[pos])")
    pos += 1

    chunk_i64 = reinterpret(Int64, bytes[pos:pos+7])[1]
    println("Position $pos-$(pos+7): Chunk size (Int64) = $chunk_i64")
    pos += 8

    println()
    println("After metadata+chunk_size, position = $pos")
    println("Valid Float32 data appears at position 490252")
    println("Gap = $(490252 - pos) bytes")
    println()

    println("Bytes in the gap (positions $pos to 490251):")
    for i in pos:490251
        print(string(bytes[i], base=16, pad=2), " ")
        if (i - pos + 1) % 16 == 0
            println()
        end
    end
    println()

    # Try interpreting the gap
    println("\nPossible interpretations of the gap:")

    # Could it be another leaf's data before ours?
    println("1. As Float32 values:")
    temp_pos = pos
    for i in 1:4
        if temp_pos + 3 <= 490251
            v = reinterpret(Float32, bytes[temp_pos:temp_pos+3])[1]
            println("   Value $i: $v")
            temp_pos += 4
        end
    end

    # Could it be another metadata byte + chunk_size?
    println("2. As metadata + chunk_size at position $pos:")
    meta2 = bytes[pos]
    println("   Metadata: $meta2")
    if pos + 8 <= length(bytes)
        chunk2 = reinterpret(Int64, bytes[pos+1:pos+8])[1]
        println("   Chunk size: $chunk2")
    end

    # Maybe the selection mask is being read even for metadata=0?
    println("3. If selection mask (64 bytes) is ALWAYS read:")
    after_mask = values_start + 1 + 8 + 64
    println("   Data would start at $after_mask")

    # Or maybe alignment padding?
    println("4. Checking alignment:")
    println("   values_start = $values_start")
    println("   values_start mod 16 = $(values_start % 16)")
    println("   490252 mod 16 = $(490252 % 16)")

    # What if there are I1/I2 tile values before leaf values?
    println("\n5. What if I1/I2 tiles precede leaves in values section?")
    println("   Check check_i2_structure.jl output - there are 2065 I1 tiles")
end
main()
