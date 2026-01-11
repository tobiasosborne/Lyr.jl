#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    # Parse header
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
    println("Active mask compression: $(header.active_mask_compression)")

    # What if the format is just [selection_mask 64 bytes][raw values]?
    # No metadata byte, no chunk_size
    pos = values_start

    println("\n=== Try: 64-byte selection mask + raw Float32 values ===")

    # Read 64-byte selection mask
    selection_mask, pos = Lyr.read_mask(Lyr.LeafMask, bytes, pos)
    active_count = Lyr.count_on(selection_mask)
    println("Selection mask active count: $active_count")
    println("Position after mask: $pos")

    # Read raw Float32 values (active_count values)
    println("\nReading first 10 Float32 values after mask:")
    for i in 1:10
        v = reinterpret(Float32, bytes[pos:pos+3])[1]
        println("  Value $i at $pos: $v $(abs(v) < 1.0 ? "(valid SDF)" : "")")
        pos += 4
    end

    # What if there's no selection mask and just ALL values?
    pos2 = values_start
    println("\n\n=== Try: All 512 raw Float32 values, no mask ===")
    println("Reading first 10 Float32 values from values_start:")
    for i in 1:10
        v = reinterpret(Float32, bytes[pos2:pos2+3])[1]
        pos2 += 4
        println("  Value $i: $v $(abs(v) < 1.0 ? "(valid SDF)" : "")")
    end

    # Try finding where the valid Float32 values actually start
    println("\n\n=== Scan for valid SDF values ===")
    for offset in 0:100
        p = values_start + offset
        vals = Float32[]
        valid = true
        for i in 1:10
            v = reinterpret(Float32, bytes[p:p+3])[1]
            p += 4
            push!(vals, v)
            if isnan(v) || isinf(v) || abs(v) > 0.5
                valid = false
            end
        end
        if valid
            println("Found valid SDF sequence at offset $offset (position $(values_start+offset))")
            println("  Values: $vals")
            break
        end
    end
end
main()
