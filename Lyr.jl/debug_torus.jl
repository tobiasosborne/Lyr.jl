using VDB

function check_metadata()
    bytes = read("test/fixtures/samples/torus.vdb")
    pos = 1

    header, pos = VDB.read_header(bytes, pos)
    while VDB.is_metadata_entry(bytes, pos)
        _, pos = VDB.read_string_with_size(bytes, pos)
        t, pos = VDB.read_string_with_size(bytes, pos)
        pos = VDB.skip_metadata_value_heuristic(bytes, pos, t)
    end
    grid_count, pos = VDB.read_u32_le(bytes, pos)
    desc, pos = VDB.read_grid_descriptor(bytes, pos, header.has_grid_offsets)
    grid_metadata, pos = VDB.read_grid_metadata(bytes, pos)

    println("Grid metadata:")
    for (k, v) in grid_metadata
        println("  $k = $v")
    end

    half_float = get(grid_metadata, "is_saved_as_half_float", false)
    println("\nHalf float: $half_float")
end

function debug_torus()
    bytes = read("test/fixtures/samples/torus.vdb")
    pos = 1
    file_size = length(bytes)
    println("File size: $file_size bytes")

    # Read header
    header, pos = read_header(bytes, pos)
    println("Header: version=$(header.format_version), pos=$pos")

    # Skip file-level metadata
    while VDB.is_metadata_entry(bytes, pos)
        key, pos = VDB.read_string_with_size(bytes, pos)
        type_name, pos = VDB.read_string_with_size(bytes, pos)
        pos = VDB.skip_metadata_value_heuristic(bytes, pos, type_name)
    end
    println("After metadata: pos=$pos")

    # Grid count
    grid_count, pos = read_u32_le(bytes, pos)
    println("Grid count: $grid_count, pos=$pos")

    # Grid descriptor
    desc, pos = VDB.read_grid_descriptor(bytes, pos, header.has_grid_offsets)
    println("Grid: $(desc.name), pos=$pos")

    # Read per-grid metadata
    grid_metadata, pos = VDB.read_grid_metadata(bytes, pos)
    grid_class = parse_grid_class(get(grid_metadata, "class", "unknown"))
    println("Grid class: $grid_class, pos=$pos")

    # Read transform
    transform, pos = read_transform(bytes, pos)
    println("Transform: $(typeof(transform)), pos=$pos")

    # Read background
    background, pos = VDB.read_tile_value(Float32, bytes, pos)
    println("Background: $background, pos=$pos")
    println("Remaining bytes: $(file_size - pos + 1)")

    # Read tile_count and child_count (level set = no bg_active)
    tile_count, pos = read_u32_le(bytes, pos)
    child_count, pos = read_u32_le(bytes, pos)
    println("\nRoot: tiles=$tile_count, children=$child_count, pos=$pos")

    # Track statistics
    total_internal2 = 0
    total_internal1 = 0
    total_leaves = 0

    for i in 1:child_count
        # Read origin
        ox, pos = VDB.read_i32_le(bytes, pos)
        oy, pos = VDB.read_i32_le(bytes, pos)
        oz, pos = VDB.read_i32_le(bytes, pos)

        start_pos = pos

        # Read Internal2 masks
        i2_child_mask, pos = VDB.read_mask(VDB.Internal2Mask, bytes, pos)
        i2_value_mask, pos = VDB.read_mask(VDB.Internal2Mask, bytes, pos)

        i2_children = count_on(i2_child_mask)
        i2_tiles = count_on(i2_value_mask)
        total_internal2 += 1

        println("  Internal2[$i] at ($ox,$oy,$oz): $i2_children children, $i2_tiles tiles, pos=$pos")

        # Read each Internal1 child
        for j in 1:i2_children
            i1_child_mask, pos = VDB.read_mask(VDB.Internal1Mask, bytes, pos)
            i1_value_mask, pos = VDB.read_mask(VDB.Internal1Mask, bytes, pos)

            i1_children = count_on(i1_child_mask)
            i1_tiles = count_on(i1_value_mask)
            total_internal1 += 1

            # Read each Leaf
            for k in 1:i1_children
                leaf_mask, pos = VDB.read_mask(VDB.LeafMask, bytes, pos)
                total_leaves += 1

                if pos > file_size
                    println("ERROR: pos=$pos > file_size=$file_size after leaf $k of Internal1[$j]")
                    return
                end
            end
        end

        println("    After subtree: pos=$pos, consumed=$(pos-start_pos) bytes")
    end

    println("\nTopology stats:")
    println("  Internal2: $total_internal2")
    println("  Internal1: $total_internal1")
    println("  Leaves: $total_leaves")
    println("  Final pos: $pos")
    println("  Remaining for values: $(file_size - pos + 1) bytes")
end

debug_torus()
