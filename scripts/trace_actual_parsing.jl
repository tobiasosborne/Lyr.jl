#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    # Parse up to the tree
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

    println("grid_data_pos = $grid_data_pos")
    println("values_start = $values_start")

    # Read grid metadata, transform, background
    grid_metadata, pos = Lyr.read_grid_metadata(bytes, grid_data_pos)
    transform, pos = Lyr.read_transform(bytes, pos)
    background, pos = Lyr.read_tile_value(Float32, bytes, pos)

    println("\nAfter background, pos = $pos")
    println("Background = $background")

    # Root node header (no background_active for level set)
    tile_count, pos = Lyr.read_u32_le(bytes, pos)
    child_count, pos = Lyr.read_u32_le(bytes, pos)
    println("\nRoot: $tile_count tiles, $child_count children")
    println("After root header, pos = $pos")

    # Read first I2 child origin
    x, pos = Lyr.read_i32_le(bytes, pos)
    y, pos = Lyr.read_i32_le(bytes, pos)
    z, pos = Lyr.read_i32_le(bytes, pos)
    println("\nFirst I2 origin: ($x, $y, $z)")
    println("After origin, pos = $pos")

    # Read I2 masks
    i2_child_mask, pos = Lyr.read_mask(Lyr.Internal2Mask, bytes, pos)
    println("I2 child_mask count_on: $(Lyr.count_on(i2_child_mask))")
    println("After I2 child_mask, pos = $pos")

    i2_value_mask, pos = Lyr.read_mask(Lyr.Internal2Mask, bytes, pos)
    println("I2 value_mask count_on: $(Lyr.count_on(i2_value_mask))")
    println("After I2 value_mask, pos = $pos")

    # For each I1 child in I2
    i1_count = Lyr.count_on(i2_child_mask)
    println("\nI2 has $i1_count I1 children")

    total_leaves = 0
    for i1_idx in 1:min(2, i1_count)  # Just trace first 2 I1 nodes
        println("\n=== I1 node $i1_idx ===")
        # Read I1 masks
        i1_child_mask, pos = Lyr.read_mask(Lyr.Internal1Mask, bytes, pos)
        i1_value_mask, pos = Lyr.read_mask(Lyr.Internal1Mask, bytes, pos)
        println("I1 child_mask count_on: $(Lyr.count_on(i1_child_mask))")
        println("I1 value_mask count_on: $(Lyr.count_on(i1_value_mask))")
        println("After I1 masks, pos = $pos")

        leaf_count = Lyr.count_on(i1_child_mask)
        total_leaves += leaf_count
        println("I1 has $leaf_count leaf children")

        # Read leaf topology (value_mask only in topology section)
        for leaf_idx in 1:min(2, leaf_count)
            leaf_value_mask, pos = Lyr.read_mask(Lyr.LeafMask, bytes, pos)
            println("  Leaf $leaf_idx value_mask count_on: $(Lyr.count_on(leaf_value_mask))")
        end
        # Skip remaining leaves
        for leaf_idx in 3:leaf_count
            _, pos = Lyr.read_mask(Lyr.LeafMask, bytes, pos)
        end
    end

    println("\n\n=== Summary ===")
    println("Topology parsing position: $pos")
    println("Expected values_start: $values_start")
    println("Gap: $(values_start - pos)")

    # Now let's see what the values section looks like
    println("\n=== Values section structure ===")
    println("If metadata format, first byte: $(bytes[values_start])")

    # Try reading with read_dense_values
    println("\nTrying read_dense_values at values_start...")
    # First get a leaf's value_mask (we need it)
    # Re-read topology to get the first leaf's mask
    pos2 = pos - 64  # Back to before last leaf mask
    first_leaf_mask, _ = Lyr.read_mask(Lyr.LeafMask, bytes, pos2 - 63)

    println("Using a leaf value_mask with count_on: $(Lyr.count_on(first_leaf_mask))")

    codec = Lyr.Codec(0x00)  # No compression
    try
        values, new_pos = Lyr.read_dense_values(Float32, bytes, values_start, codec, first_leaf_mask, background)
        println("read_dense_values succeeded!")
        println("  Returned $new_pos (advanced $(new_pos - values_start) bytes)")
        non_bg = count(v -> v != background && v != -background, values)
        println("  Non-background values: $non_bg")
        sample = values[1:min(10, length(values))]
        println("  First 10: $sample")
    catch e
        println("read_dense_values failed: $e")
    end
end
main()
