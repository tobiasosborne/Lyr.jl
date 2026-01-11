#!/usr/bin/env julia
# Trace through parsing to verify positions

using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"  # Use non-HalfFloat file
    bytes = read(path)

    println("=== File: $path ===")
    println("File size: $(length(bytes)) bytes")

    # Parse header
    header, pos = Lyr.read_header(bytes, 1)
    println("\nHeader ends at position: $pos")
    println("Version: $(header.format_version)")
    println("Compression: $(header.compression)")

    # Skip file metadata (for v222+ it's heuristic-based)
    while Lyr.is_metadata_entry(bytes, pos)
        _, pos = Lyr.read_string_with_size(bytes, pos)  # key
        type_name, pos = Lyr.read_string_with_size(bytes, pos)  # type
        pos = Lyr.skip_metadata_value_heuristic(bytes, pos, type_name)  # value
    end
    println("File metadata ends at position: $pos")

    # Grid count
    grid_count, pos = Lyr.read_u32_le(bytes, pos)
    println("Grid count: $grid_count")

    # Read grid descriptor
    desc, pos = Lyr.read_grid_descriptor(bytes, pos, header.has_grid_offsets)
    println("\nGrid descriptor:")
    println("  Name: $(desc.name)")
    println("  Type: $(desc.grid_type)")
    println("  byte_offset: $(desc.byte_offset)")
    println("  block_offset: $(desc.block_offset)")
    println("  end_offset: $(desc.end_offset)")
    println("Grid descriptor ends at position: $pos")

    # Seek to grid data
    grid_data_pos = Int(desc.byte_offset) + 1  # 1-indexed
    println("\nGrid data starts at: $grid_data_pos")

    # Read grid metadata
    grid_metadata, pos = Lyr.read_grid_metadata(bytes, grid_data_pos)
    println("Grid metadata ends at: $pos")

    # Read transform
    transform, pos = Lyr.read_transform(bytes, pos)
    println("Transform ends at: $pos")

    # Read background
    background, pos = Lyr.read_tile_value(Float32, bytes, pos)
    println("Background: $background, position now: $pos")

    # Calculate values_start
    values_start = grid_data_pos + Int(desc.block_offset)
    println("\nCalculated values_start: $values_start")
    println("Distance from current pos to values_start: $(values_start - pos)")

    # Read root node header
    # For level set, no background_active byte
    tile_count, pos = Lyr.read_u32_le(bytes, pos)
    child_count, pos = Lyr.read_u32_le(bytes, pos)
    println("\nRoot node: $tile_count tiles, $child_count children")
    println("Position after root header: $pos")

    # Skip tiles
    for _ in 1:tile_count
        pos += 12  # origin (3 × i32)
        pos += 4   # value (Float32)
        pos += 1   # active byte
    end
    println("Position after tiles: $pos")

    # Read first child origin
    if child_count > 0
        x, pos = Lyr.read_i32_le(bytes, pos)
        y, pos = Lyr.read_i32_le(bytes, pos)
        z, pos = Lyr.read_i32_le(bytes, pos)
        println("First I2 child origin: ($x, $y, $z)")
        println("Position after first origin: $pos")

        # Read I2 masks
        i2_child_mask, pos = Lyr.read_mask(Lyr.Internal2Mask, bytes, pos)
        println("I2 child_mask count_on: $(Lyr.count_on(i2_child_mask))")
        println("Position after I2 child_mask: $pos")

        i2_value_mask, pos = Lyr.read_mask(Lyr.Internal2Mask, bytes, pos)
        println("I2 value_mask count_on: $(Lyr.count_on(i2_value_mask))")
        println("Position after I2 value_mask: $pos")
    end

    # Now estimate where topology ends
    # Topology includes all masks for all I2/I1/Leaf nodes
    # This is complex to trace fully, but we can check the values_start

    println("\n=== Values section analysis ===")
    println("values_start: $values_start")

    # Show bytes at values_start
    println("\nFirst 20 bytes at values_start:")
    for i in 0:19
        print(string(bytes[values_start + i], base=16, pad=2), " ")
    end
    println()

    # First byte should be metadata (0-6)
    meta = bytes[values_start]
    println("\nMetadata byte: $meta")

    if meta <= 6
        println("Valid metadata code!")
        # Try reading as compressed format
        p = values_start + 1

        # Read chunk_size
        chunk_size = reinterpret(Int64, bytes[p:p+7])[1]
        println("Chunk size at position $p: $chunk_size (0x$(string(chunk_size, base=16)))")

        if chunk_size < 0
            println("  Negative = uncompressed, size = $(-chunk_size)")
        elseif chunk_size > 0
            println("  Positive = compressed, size = $chunk_size")
        else
            println("  Zero = empty data")
        end
    else
        println("NOT a valid metadata byte - format assumption is wrong!")
    end
end

main()
