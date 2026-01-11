#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    header, pos = Lyr.read_header(bytes, 1)
    println("File version: $(header.format_version)")

    # Skip file metadata
    while Lyr.is_metadata_entry(bytes, pos)
        _, pos = Lyr.read_string_with_size(bytes, pos)
        type_name, pos = Lyr.read_string_with_size(bytes, pos)
        pos = Lyr.skip_metadata_value_heuristic(bytes, pos, type_name)
    end

    # Grid count
    _, pos = Lyr.read_u32_le(bytes, pos)

    # Grid descriptor
    desc, pos = Lyr.read_grid_descriptor(bytes, pos, header.has_grid_offsets)

    println("\nGrid descriptor:")
    println("  name: $(desc.name)")
    println("  grid_type: $(desc.grid_type)")
    println("  byte_offset: $(desc.byte_offset)")
    println("  block_offset: $(desc.block_offset)")
    println("  end_offset: $(desc.end_offset)")

    # The byte_offset is relative to the START of the file (0-indexed)
    # In Julia 1-indexed: grid_data_pos = byte_offset + 1
    grid_data_pos = Int(desc.byte_offset) + 1
    println("\nGrid data starts at position: $grid_data_pos (byte_offset + 1)")

    # The block_offset is relative to the START of the grid data
    # values_start = grid_data_pos + block_offset
    values_start = grid_data_pos + Int(desc.block_offset)
    println("Values section at: $values_start (grid_data_pos + block_offset)")

    # What about end_offset?
    grid_end = Int(desc.end_offset) + 1
    println("Grid ends at: $grid_end (end_offset + 1)")

    # Verify grid data position by reading
    println("\n=== Verifying grid structure ===")
    gpos = grid_data_pos

    # Grid metadata
    grid_meta, gpos = Lyr.read_grid_metadata(bytes, gpos)
    println("After grid metadata: $gpos")

    # Transform
    transform, gpos = Lyr.read_transform(bytes, gpos)
    println("After transform: $gpos")

    # Background
    background, gpos = Lyr.read_tile_value(Float32, bytes, gpos)
    println("Background: $background, after: $gpos")

    # Root node header (level set: no background_active)
    tile_count, gpos = Lyr.read_u32_le(bytes, gpos)
    child_count, gpos = Lyr.read_u32_le(bytes, gpos)
    println("Root: $tile_count tiles, $child_count children, after: $gpos")

    # Skip tiles
    for _ in 1:tile_count
        gpos += 12 + 4 + 1  # origin + value + active
    end
    println("After tiles: $gpos")

    # This is where topology starts (I2 node origins and masks)
    topology_start = gpos
    println("\nTopology starts at: $topology_start")
    println("Values start at: $values_start")
    println("Topology size (block_offset from root header): $(values_start - topology_start + (topology_start - grid_data_pos))")

    # Check if block_offset might be from a different reference point
    println("\n=== Alternative block_offset interpretations ===")
    println("From file start: $((Int(desc.block_offset) + 1))")
    println("From grid_data_pos: $(grid_data_pos + Int(desc.block_offset))")
    println("From topology_start: $(topology_start + Int(desc.block_offset))")

    # Is block_offset actually from the ROOT NODE header (after background)?
    root_start = gpos - 8  # Before tile_count
    println("\n=== If block_offset is from root node start ===")
    println("Root node header at: $(root_start)")
    println("values_start would be: $(root_start + Int(desc.block_offset))")
end
main()
