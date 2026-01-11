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

    # Read grid structure
    grid_meta, pos = Lyr.read_grid_metadata(bytes, grid_data_pos)
    transform, pos = Lyr.read_transform(bytes, pos)
    background, pos = Lyr.read_tile_value(Float32, bytes, pos)

    tile_count, pos = Lyr.read_u32_le(bytes, pos)
    child_count, pos = Lyr.read_u32_le(bytes, pos)

    println("Root: $tile_count tiles, $child_count children")

    # Read each I2 node
    total_i2_tiles = 0
    total_i1_tiles = 0
    total_leaves = 0

    for i in 1:child_count
        # Read I2 origin
        x, pos = Lyr.read_i32_le(bytes, pos)
        y, pos = Lyr.read_i32_le(bytes, pos)
        z, pos = Lyr.read_i32_le(bytes, pos)

        # Check if valid origin
        if !(x % 4096 == 0 && y % 4096 == 0 && z % 4096 == 0)
            println("I2 $i: Invalid origin ($x, $y, $z)")
            break
        end

        # Read I2 masks (4096 bytes each)
        i2_child_mask, pos = Lyr.read_mask(Lyr.Internal2Mask, bytes, pos)
        i2_value_mask, pos = Lyr.read_mask(Lyr.Internal2Mask, bytes, pos)

        i2_children = Lyr.count_on(i2_child_mask)
        i2_tiles = Lyr.count_on(i2_value_mask)
        total_i2_tiles += i2_tiles

        println("\nI2 node $i at ($x, $y, $z):")
        println("  Children (I1s): $i2_children")
        println("  Tiles: $i2_tiles")

        # Read I1 nodes
        for j in 1:i2_children
            i1_child_mask, pos = Lyr.read_mask(Lyr.Internal1Mask, bytes, pos)
            i1_value_mask, pos = Lyr.read_mask(Lyr.Internal1Mask, bytes, pos)

            i1_children = Lyr.count_on(i1_child_mask)
            i1_tiles = Lyr.count_on(i1_value_mask)
            total_i1_tiles += i1_tiles
            total_leaves += i1_children

            if j <= 3  # Print first 3
                println("    I1 $j: $i1_children leaves, $i1_tiles tiles")
            end

            # Skip leaf value masks
            for k in 1:i1_children
                _, pos = Lyr.read_mask(Lyr.LeafMask, bytes, pos)
            end
        end
    end

    println("\n=== Summary ===")
    println("Total I2 tiles: $total_i2_tiles")
    println("Total I1 tiles: $total_i1_tiles")
    println("Total leaves: $total_leaves")
    println("Topology ends at: $pos")
    println("Values section at: $values_start")
    println("Gap: $(values_start - pos)")

    # If there are I2/I1 tile values, they come BEFORE leaf values
    # Each tile value is 1 Float32 (4 bytes) with metadata format
    println("\n=== Values section breakdown ===")
    println("If I2/I1 tiles use metadata format (1 byte meta + 8 byte size + data):")
    values_pos = values_start

    # For each I2 tile: metadata + chunk_size + 1 Float32
    i2_tile_size = 1 + 8 + 4
    println("I2 tiles would use: $(total_i2_tiles * i2_tile_size) bytes")

    # For each I1 tile: same format
    i1_tile_size = 1 + 8 + 4
    println("I1 tiles would use: $(total_i1_tiles * i1_tile_size) bytes")

    first_leaf_pos = values_start + total_i2_tiles * i2_tile_size + total_i1_tiles * i1_tile_size
    println("\nFirst leaf values would start at: $first_leaf_pos")

    # Check what's at that position
    println("\nBytes at position $first_leaf_pos:")
    for i in 0:15
        print(string(bytes[first_leaf_pos + i], base=16, pad=2), " ")
    end
    println()
end
main()
