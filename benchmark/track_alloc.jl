# Allocation Tracking Script for Lyr.jl
#
# Usage:
#   1. Clear existing .mem files:
#      find src -name "*.mem" -delete
#
#   2. Run with allocation tracking:
#      julia --project --track-allocation=user benchmark/track_alloc.jl [vdb_file]
#
#   3. Results are printed to stdout and .mem files are generated in src/
#
# The script:
#   - Warms up with 2 iterations (compilation allocations excluded)
#   - Runs 5 tracked iterations
#   - Parses .mem files and reports top allocation sites

using Lyr
using Printf
using Profile

const SAMPLE_DIR = joinpath(@__DIR__, "..", "test", "fixtures", "samples")

# Parse command line for VDB file, default to torus.vdb
function get_vdb_file()
    if !isempty(ARGS)
        path = ARGS[1]
        if isfile(path)
            return path
        else
            error("File not found: $path")
        end
    end

    # Try available samples in order of preference (torus.vdb is known to work)
    for name in ["torus.vdb", "bunny_cloud.vdb"]
        path = joinpath(SAMPLE_DIR, name)
        if isfile(path)
            return path
        end
    end

    error("No VDB file found. Provide a path or place files in $SAMPLE_DIR")
end

# Run the workload being tracked
function run_workload(bytes::Vector{UInt8})
    # Parse VDB file
    vdb = parse_vdb(bytes)

    if !isempty(vdb.grids)
        grid = first(vdb.grids)
        tree = grid.tree

        # Exercise hot paths
        # 1. Random access via get_value
        for i in -50:10:50
            for j in -50:10:50
                for k in -50:10:50
                    get_value(tree, coord(i, j, k))
                end
            end
        end

        # 2. Active voxel iteration
        count = 0
        for (c, v) in active_voxels(tree)
            count += 1
            count >= 1000 && break  # Limit for speed
        end

        # 3. Trilinear sampling
        for i in 1:100
            sample_trilinear(tree, (Float64(i) - 50.0, 0.0, 0.0))
        end
    end

    vdb
end

# Parse a .mem file and extract allocation data
function parse_mem_file(filepath::String)
    allocations = Tuple{Int, Int, String}[]  # (bytes, line_number, line_content)

    !isfile(filepath) && return allocations

    lines = readlines(filepath)
    for (line_num, line) in enumerate(lines)
        # Format: "        - code" or "   123456 code" (bytes allocated, then code)
        if length(line) >= 9
            alloc_str = strip(line[1:9])
            if alloc_str != "-" && !isempty(alloc_str)
                try
                    bytes = parse(Int, alloc_str)
                    if bytes > 0
                        code = length(line) > 9 ? strip(line[10:end]) : ""
                        push!(allocations, (bytes, line_num, code))
                    end
                catch
                    # Not a valid allocation line
                end
            end
        end
    end

    allocations
end

# Find and analyze all .mem files in src/
function analyze_allocations()
    src_dir = joinpath(@__DIR__, "..", "src")
    all_allocations = Tuple{Int, String, Int, String}[]  # (bytes, file, line, code)

    for (root, dirs, files) in walkdir(src_dir)
        for file in files
            # Match both "Binary.jl.mem" and "Binary.jl.123456.mem" formats
            if occursin(r"\.jl(\.\d+)?\.mem$", file)
                filepath = joinpath(root, file)
                # Extract source file name (remove .mem and optional .PID suffix)
                source_file = replace(file, r"(\.\d+)?\.mem$" => "")

                for (bytes, line_num, code) in parse_mem_file(filepath)
                    push!(all_allocations, (bytes, source_file, line_num, code))
                end
            end
        end
    end

    # Sort by bytes descending
    sort!(all_allocations, by=x -> -x[1])

    all_allocations
end

# Format bytes in human-readable form
function format_bytes(bytes::Int)
    if bytes >= 1_000_000_000
        return @sprintf("%.2f GB", bytes / 1_000_000_000)
    elseif bytes >= 1_000_000
        return @sprintf("%.2f MB", bytes / 1_000_000)
    elseif bytes >= 1_000
        return @sprintf("%.2f KB", bytes / 1_000)
    else
        return @sprintf("%d B", bytes)
    end
end

function main()
    println("=" ^ 70)
    println("Lyr.jl Allocation Tracking")
    println("=" ^ 70)
    println()

    # Get VDB file
    vdb_path = get_vdb_file()
    println("VDB file: $vdb_path")
    bytes = read(vdb_path)
    println("File size: $(format_bytes(length(bytes)))")
    println()

    # Warm-up phase (compilation allocations)
    println("Warming up (2 iterations)...")
    for i in 1:2
        run_workload(bytes)
    end

    # Clear allocation counters by triggering GC
    GC.gc()

    # Tracked runs
    println("Running tracked workload (5 iterations)...")
    for i in 1:5
        run_workload(bytes)
    end

    # Force profile write
    Profile.clear_malloc_data()  # This triggers writing .mem files

    println()
    println("Analyzing .mem files...")
    println()

    allocations = analyze_allocations()

    # Check if any .mem files exist at all
    src_dir = joinpath(@__DIR__, "..", "src")
    mem_files = filter(f -> occursin(r"\.jl(\.\d+)?\.mem$", f), readdir(src_dir))

    if isempty(mem_files)
        println("No .mem files found in src/.")
        println()
        println("To generate .mem files:")
        println("  1. julia --project --track-allocation=user benchmark/track_alloc.jl")
        println("  2. Wait for Julia to exit (this writes .mem files)")
        println("  3. julia --project benchmark/track_alloc.jl  # Analyze")
        println()
        println("Note: .mem files are written on Julia exit, not during execution.")
        return
    end

    println(@sprintf("Found %d .mem files from previous run.", length(mem_files)))
    println()

    if isempty(allocations)
        println("-" ^ 70)
        println("SUCCESS: No allocations found in tracked code!")
        println("-" ^ 70)
        println()
        println("All hot-path functions are allocation-free. This is the goal.")
        println("The .mem files show execution coverage with 0-byte allocations.")
        println()
        println("To verify, check .mem files directly:")
        println("  grep -E '^ *[1-9]' src/*.mem  # Find non-zero allocations")
        println()
        return
    end

    # Report top allocation sites
    println("-" ^ 70)
    println("Top 20 Allocation Sites (by bytes)")
    println("-" ^ 70)
    println()

    total_bytes = sum(x -> x[1], allocations)

    for (i, (alloc_bytes, file, line, code)) in enumerate(allocations[1:min(20, length(allocations))])
        pct = 100.0 * alloc_bytes / total_bytes
        println(@sprintf("%2d. %10s (%5.1f%%)  %s:%d", i, format_bytes(alloc_bytes), pct, file, line))
        if !isempty(code) && length(code) <= 60
            println("    → $code")
        elseif !isempty(code)
            println("    → $(code[1:57])...")
        end
        println()
    end

    # Summary by file
    println("-" ^ 70)
    println("Allocations by File")
    println("-" ^ 70)
    println()

    by_file = Dict{String, Int}()
    for (alloc_bytes, file, _, _) in allocations
        by_file[file] = get(by_file, file, 0) + alloc_bytes
    end

    sorted_files = sort(collect(by_file), by=x -> -x[2])
    for (file, file_bytes) in sorted_files
        pct = 100.0 * file_bytes / total_bytes
        println(@sprintf("  %10s (%5.1f%%)  %s", format_bytes(file_bytes), pct, file))
    end

    println()
    println("-" ^ 70)
    println(@sprintf("Total tracked allocations: %s", format_bytes(total_bytes)))
    println("-" ^ 70)

    # Key areas to focus on (from issue description)
    println()
    println("=" ^ 70)
    println("Key Areas to Investigate:")
    println("=" ^ 70)
    println()
    println("1. Binary.jl read functions - check for array allocations")
    println("2. Masks.jl operations - iteration should be allocation-free")
    println("3. TreeRead.jl - tree materialization allocations")
    println("4. Accessors.jl - iterator allocations")
    println()
    println("Goal: Zero allocations in hot path (get_value, is_on, count_on)")
    println()
end

main()
