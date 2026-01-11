#!/usr/bin/env julia
using Lyr

function main()
    path = "test/fixtures/samples/torus.vdb"
    bytes = read(path)

    # Check version
    header, pos = Lyr.read_header(bytes, 1)
    println("File version: $(header.format_version)")
    println("Compression: $(header.compression)")

    # Parse to get grid info
    while Lyr.is_metadata_entry(bytes, pos)
        _, pos = Lyr.read_string_with_size(bytes, pos)
        type_name, pos = Lyr.read_string_with_size(bytes, pos)
        pos = Lyr.skip_metadata_value_heuristic(bytes, pos, type_name)
    end
    _, pos = Lyr.read_u32_le(bytes, pos)
    desc, pos = Lyr.read_grid_descriptor(bytes, pos, header.has_grid_offsets)

    println("\nGrid type: $(desc.grid_type)")

    grid_data_pos = Int(desc.byte_offset) + 1
    values_start = grid_data_pos + Int(desc.block_offset)

    # Try to read the actual tree using Lyr's parser
    println("\n=== Attempting full parse ===")

    vdb = parse_vdb(path)
    grid = first(values(vdb.grids))

    println("Grid name: $(grid.name)")
    println("Grid class: $(grid.grid_class)")
    println("Background: $(grid.tree.background)")

    # Get first leaf
    leaves = collect(Lyr.leaves(grid.tree))
    println("\nTotal leaves: $(length(leaves))")

    if length(leaves) > 0
        leaf = leaves[1]
        println("\nFirst leaf:")
        println("  Origin: $(leaf.origin)")
        println("  Active count: $(Lyr.count_on(leaf.value_mask))")

        # Analyze values
        bg = grid.tree.background
        nan_count = count(isnan, leaf.values)
        bg_count = count(v -> v == bg, leaf.values)
        neg_bg_count = count(v -> v == -bg, leaf.values)
        valid_sdf = count(v -> !isnan(v) && abs(v) < 0.5 && v != bg && v != -bg, leaf.values)

        println("\n  Value breakdown (512 total):")
        println("    NaN: $nan_count")
        println("    Background ($bg): $bg_count")
        println("    -Background ($(-bg)): $neg_bg_count")
        println("    Valid SDF (|v| < 0.5): $valid_sdf")
        println("    Other: $(512 - nan_count - bg_count - neg_bg_count - valid_sdf)")

        # Sample some values
        println("\n  First 10 values: $(collect(leaf.values[1:10]))")

        # Check active voxels specifically
        active_vals = Float32[]
        for i in 0:511
            if Lyr.is_on(leaf.value_mask, i)
                push!(active_vals, leaf.values[i+1])
            end
            length(active_vals) >= 20 && break
        end
        println("  First 20 active voxel values: $active_vals")
    end
end
main()
