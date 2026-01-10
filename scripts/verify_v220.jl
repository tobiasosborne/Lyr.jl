# verify_v220.jl - Quick verification script for v220 format support
#
# Run with: julia --project scripts/verify_v220.jl
#
# This script tests bunny_cloud.vdb (v220 format) parsing without running
# the full test suite.

using Lyr

function main()
    filepath = joinpath(@__DIR__, "..", "test", "fixtures", "samples", "bunny_cloud.vdb")

    if !isfile(filepath)
        println("ERROR: bunny_cloud.vdb not found at $filepath")
        println("Download from ASWF: https://artifacts.aswf.io/io/aswf/openvdb/models/bunny_cloud.vdb/1.0.0/bunny_cloud.vdb-1.0.0.zip")
        return 1
    end

    println("Testing v220 format support with bunny_cloud.vdb...")
    println("File path: $filepath")
    println()

    try
        # Parse the VDB file
        println("Parsing...")
        vdb = parse_vdb(filepath)

        # Verify header
        println("Header:")
        println("  Format version: $(vdb.header.format_version)")
        @assert vdb.header.format_version == 220 "Expected v220, got $(vdb.header.format_version)"
        println("  Compression: $(typeof(vdb.header.compression))")

        # Verify grids
        println("\nGrids: $(length(vdb.grids))")
        for (i, grid) in enumerate(vdb.grids)
            println("  Grid $i: $(grid.name)")
            println("    Class: $(grid.grid_class)")
            println("    Transform: $(typeof(grid.transform))")
            println("    Leaves: $(leaf_count(grid.tree))")
            println("    Active voxels: $(active_voxel_count(grid.tree))")
            println("    Background: $(grid.tree.background)")

            # Sample some values
            println("\n  Sampling active voxels...")
            sample_count = 0
            min_val = typemax(Float32)
            max_val = typemin(Float32)
            for (coord, val) in active_voxels(grid.tree)
                if !isfinite(val)
                    println("    WARNING: Non-finite value at $coord: $val")
                end
                min_val = min(min_val, val)
                max_val = max(max_val, val)
                sample_count += 1
                sample_count >= 1000 && break
            end
            println("    Sampled $sample_count values")
            println("    Value range: [$min_val, $max_val]")
        end

        println("\n" * "="^50)
        println("SUCCESS: v220 format parsing works correctly!")
        println("="^50)
        return 0

    catch e
        println("\n" * "="^50)
        println("FAILURE: Error parsing bunny_cloud.vdb")
        println("="^50)
        println()
        println("Error: ", e)
        println()
        for (exc, bt) in current_exceptions()
            showerror(stdout, exc, bt)
            println()
        end
        return 1
    end
end

exit(main())
