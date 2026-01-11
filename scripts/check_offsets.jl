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

    grid_data_pos = Int(desc.byte_offset) + 1  # 1-indexed

    println("=== Offset analysis ===")
    println("desc.byte_offset: $(desc.byte_offset)")
    println("desc.block_offset: $(desc.block_offset)")
    println("desc.end_offset: $(desc.end_offset)")
    println()
    println("grid_data_pos (byte_offset + 1): $grid_data_pos")
    println("values_start (grid_data_pos + block_offset): $(grid_data_pos + Int(desc.block_offset))")

    # What if block_offset is relative to something else?
    # Maybe it's from the start of file, not grid data?
    println("\nAlternative: block_offset from file start + 1: $(Int(desc.block_offset) + 1)")

    # Check what's at different interpretations
    println("\n--- Bytes at grid_data_pos ($grid_data_pos) ---")
    for i in 0:19
        print(string(bytes[grid_data_pos + i], base=16, pad=2), " ")
    end
    println()

    # Check what read_tree_v222 does with positions
    # Let me trace through the tree parsing to find actual topology vs values boundary

    # Read grid metadata (should be at grid_data_pos)
    grid_metadata, gm_pos = Lyr.read_grid_metadata(bytes, grid_data_pos)
    println("\nGrid metadata ends at: $gm_pos")

    # Read transform
    transform, tf_pos = Lyr.read_transform(bytes, gm_pos)
    println("Transform ends at: $tf_pos")

    # Read background
    background, bg_pos = Lyr.read_tile_value(Float32, bytes, tf_pos)
    println("Background: $background, ends at: $bg_pos")

    # Level set: no background_active byte
    # Read tile_count, child_count
    tile_count, pos1 = Lyr.read_u32_le(bytes, bg_pos)
    child_count, pos2 = Lyr.read_u32_le(bytes, pos1)
    println("\nRoot: $tile_count tiles, $child_count children")
    println("Position after root header: $pos2")

    # This should be where topology starts
    topology_start = pos2
    values_start_calculated = grid_data_pos + Int(desc.block_offset)

    println("\n=== Summary ===")
    println("Topology starts at: $topology_start")
    println("Values section (from block_offset): $values_start_calculated")
    println("Gap (topology size): $(values_start_calculated - topology_start)")

    # Calculate expected topology size
    # For this tree, need to know how many I2/I1/Leaf nodes

    # Find where valid Float32 values start
    println("\n=== Scanning for Float32 SDF values ===")
    for offset in (values_start_calculated - 100):(values_start_calculated + 100)
        if offset < 1 || offset + 40 > length(bytes)
            continue
        end
        vals = Vector{Float32}(undef, 10)
        valid = true
        for i in 1:10
            v = reinterpret(Float32, bytes[offset + (i-1)*4 : offset + (i-1)*4 + 3])[1]
            vals[i] = v
            if isnan(v) || isinf(v) || abs(v) > 0.5
                valid = false
            end
        end
        if valid
            println("Found valid SDF at position $offset (offset $(offset - values_start_calculated) from values_start)")
            println("  First 5: $(vals[1:5])")
            break
        end
    end
end
main()
