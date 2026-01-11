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

    println("=== Values section analysis for torus.vdb ===")
    println("values_start = $values_start")
    println()

    # The values section should contain:
    # 1. I2 tile values (for each I2 node's value_mask set bits)
    # 2. I1 tile values (for each I1 node's value_mask set bits)
    # 3. Leaf values (selection mask + values for each leaf)
    #
    # For level sets, most tiles might be background value

    # Let's look at the structure more carefully
    # The first thing should be I2 tile values, not leaf values!

    # Look at first 300 bytes
    println("First 300 bytes of values section:")
    for row in 0:18
        print("$(values_start + row*16): ")
        for col in 0:15
            idx = values_start + row*16 + col
            if idx <= length(bytes)
                print(string(bytes[idx], base=16, pad=2), " ")
            end
        end
        println()
    end

    # The format might be:
    # [I2 tile values][I1 tile values]...[Leaf values]
    # Or it could be per-I2-subtree

    # Let's see if values_start+27 still gives good Float32
    println("\n\nAt offset +27 (position $(values_start + 27)):")
    p = values_start + 27
    for i in 1:10
        v = reinterpret(Float32, bytes[p:p+3])[1]
        println("  Float32: $v")
        p += 4
    end

    # Try reading metadata byte at values_start
    meta = bytes[values_start]
    println("\n\nMetadata byte at values_start: $meta ($(meta <= 6 ? "valid" : "invalid"))")

    if meta <= 6
        println("Format interpretation:")
        if meta == 0
            println("  NO_MASK_OR_INACTIVE_VALS: All values stored, inactive=background")
        elseif meta == 1
            println("  NO_MASK_AND_MINUS_BG: All values stored, inactive=-background")
        elseif meta == 2
            println("  NO_MASK_AND_ONE_INACTIVE_VAL: One inactive value follows, then all values")
        elseif meta == 3
            println("  MASK_AND_NO_INACTIVE_VALS: Selection mask (64 bytes), then active values only")
        elseif meta == 4
            println("  MASK_AND_ONE_INACTIVE_VAL: One inactive value, selection mask, then active values")
        elseif meta == 5
            println("  MASK_AND_TWO_INACTIVE_VALS: Two inactive values, selection mask, then active values")
        elseif meta == 6
            println("  NO_MASK_AND_ALL_VALS: All 512 values stored densely")
        end
    end
end
main()
