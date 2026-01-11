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

    println("File version: $(header.format_version)")
    println("values_start = $values_start")
    println("File size: $(length(bytes))")
    println()

    # Try different interpretations of where Float32 values might start

    # Theory 1: Values start immediately at values_start (raw Float32)
    println("=== Theory 1: Raw Float32 values from values_start ===")
    pos = values_start
    valid_count = 0
    for i in 1:20
        v = reinterpret(Float32, bytes[pos:pos+3])[1]
        is_valid = abs(v) < 1.0
        if is_valid
            valid_count += 1
        end
        if i <= 10
            label = is_valid ? "(valid SDF)" : ""
            println("  Value $i at $pos: $v $label")
        end
        pos += 4
    end
    println("  Valid SDF values in first 20: $valid_count")

    # Theory 2: There's a global metadata+chunk_size prefix, then raw values
    println("\n=== Theory 2: Global metadata+chunk_size then raw values ===")
    pos = values_start + 1 + 8  # Skip 1 metadata + 8 chunk_size
    valid_count = 0
    for i in 1:20
        v = reinterpret(Float32, bytes[pos:pos+3])[1]
        is_valid = abs(v) < 1.0
        if is_valid
            valid_count += 1
        end
        if i <= 10
            label = is_valid ? "(valid SDF)" : ""
            println("  Value $i at $pos: $v $label")
        end
        pos += 4
    end
    println("  Valid SDF values in first 20: $valid_count")

    # Theory 3: Search for the first sequence of valid SDF values
    println("\n=== Theory 3: Search for first valid SDF sequence ===")
    for offset in 0:200
        pos = values_start + offset
        if pos + 40 > length(bytes)
            break
        end

        # Check if 10 consecutive Float32 values are all valid SDFs
        all_valid = true
        for i in 1:10
            v = reinterpret(Float32, bytes[pos + (i-1)*4:pos + (i-1)*4 + 3])[1]
            if abs(v) > 1.0 || isnan(v) || isinf(v)
                all_valid = false
                break
            end
        end

        if all_valid
            println("Found valid SDF sequence at offset $offset (position $pos)!")
            println("First 10 values:")
            for i in 1:10
                v = reinterpret(Float32, bytes[pos + (i-1)*4:pos + (i-1)*4 + 3])[1]
                println("  Value $i: $v")
            end
            break
        end
    end
end
main()
