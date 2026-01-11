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
    println()

    # According to tinyvdbio, v222+ values section format per leaf:
    # [value_mask 64 bytes][metadata 1 byte][inactive vals?][selection mask?][chunk_size + data]

    println("=== Testing v222+ format with value_mask first ===")
    pos = values_start

    # Read value_mask (64 bytes)
    println("Value mask (64 bytes) at position $pos:")
    value_mask_bytes = bytes[pos:pos+63]
    println("  First 16 bytes: ", join([string(b, base=16, pad=2) for b in value_mask_bytes[1:16]], " "))
    pos += 64

    # Read metadata byte
    metadata = bytes[pos]
    println("\nMetadata byte at position $pos: $metadata")
    pos += 1

    # For metadata 0 (NO_MASK_OR_INACTIVE_VALS): no inactive vals, no selection mask

    # Read chunk_size
    chunk_size = reinterpret(Int64, bytes[pos:pos+7])[1]
    println("Chunk size at position $pos: $chunk_size")
    pos += 8

    println("\nData starts at position: $pos")
    println("Reading first 10 Float32 values:")
    for i in 1:10
        v = reinterpret(Float32, bytes[pos:pos+3])[1]
        is_valid_sdf = abs(v) < 1.0
        label = is_valid_sdf ? "(valid SDF)" : ""
        println("  Value $i at $pos: $v $label")
        pos += 4
    end

    # Also check the value_mask - count how many bits are set
    mask, _ = Lyr.read_mask(Lyr.LeafMask, value_mask_bytes, 1)
    active_count = Lyr.count_on(mask)
    println("\nValue mask analysis:")
    println("  Active voxels: $active_count / 512")
end
main()
