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

    background = Float32(0.15)

    println("Testing different format interpretations...")
    println("values_start = $values_start")

    # Format 1: metadata byte + chunk_size + data (current implementation)
    println("\n=== Format 1: metadata + chunk_size + data ===")
    p1 = values_start
    meta1 = bytes[p1]
    p1 += 1
    chunk1 = reinterpret(Int64, bytes[p1:p1+7])[1]
    p1 += 8
    println("Metadata: $meta1, chunk_size: $chunk1")
    println("Values would start at: $p1")
    println("First Float32 at $p1: $(reinterpret(Float32, bytes[p1:p1+3])[1])")

    # Format 2: metadata byte + raw 512 Float32 values (no chunk_size)
    println("\n=== Format 2: metadata + raw 512 values (no chunk_size) ===")
    p2 = values_start + 1  # Skip metadata
    println("Values start at: $p2")
    # Read first 10 values
    for i in 1:10
        v = reinterpret(Float32, bytes[p2:p2+3])[1]
        println("  Value $i at $p2: $v $(abs(v) < 0.5 ? "(valid)" : "")")
        p2 += 4
    end

    # Format 3: NO metadata byte, just raw 512 Float32 values
    println("\n=== Format 3: raw 512 values (no metadata) ===")
    p3 = values_start
    for i in 1:10
        v = reinterpret(Float32, bytes[p3:p3+3])[1]
        println("  Value $i at $p3: $v $(abs(v) < 0.5 ? "(valid)" : "")")
        p3 += 4
    end

    # Format 4: metadata + 64-byte selection mask + raw active values
    println("\n=== Format 4: metadata + 64-byte mask + active values ===")
    p4 = values_start
    meta4 = bytes[p4]
    p4 += 1
    mask4, p4 = Lyr.read_mask(Lyr.LeafMask, bytes, p4)
    active_count4 = Lyr.count_on(mask4)
    println("Metadata: $meta4, mask active: $active_count4")
    println("Values start at: $p4")
    for i in 1:min(10, active_count4)
        v = reinterpret(Float32, bytes[p4:p4+3])[1]
        println("  Active value $i at $p4: $v $(abs(v) < 0.5 ? "(valid)" : "")")
        p4 += 4
    end

    # Format 5: NO metadata, 64-byte selection mask + raw active values
    println("\n=== Format 5: 64-byte mask (no metadata) + active values ===")
    p5 = values_start
    mask5, p5 = Lyr.read_mask(Lyr.LeafMask, bytes, p5)
    active_count5 = Lyr.count_on(mask5)
    println("Mask active: $active_count5")
    println("Values start at: $p5")
    for i in 1:min(10, active_count5)
        v = reinterpret(Float32, bytes[p5:p5+3])[1]
        println("  Active value $i at $p5: $v $(abs(v) < 0.5 ? "(valid)" : "")")
        p5 += 4
    end
end
main()
