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

    println("\nScanning for 10 consecutive valid SDF Float32 values...")

    for offset in 0:150
        p = values_start + offset
        vals = Vector{Float32}(undef, 10)
        test_p = p
        valid = true
        for i in 1:10
            v = reinterpret(Float32, bytes[test_p:test_p+3])[1]
            test_p += 4
            vals[i] = v
            if isnan(v) || isinf(v) || abs(v) > 3.0
                valid = false
            end
        end

        if valid
            println("\nOffset $offset (position $p): Found valid sequence")
            println("  Values: $vals")
        end
    end
end
main()
