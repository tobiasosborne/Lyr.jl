# Lyr.jl Profiling Script
# Run with: timeout 60 julia --project benchmark/profile.jl
#
# For flame graph visualization (requires GUI):
#   julia --project benchmark/profile.jl --view
#
# For HTML flame graph output:
#   julia --project benchmark/profile.jl --html
#
# Options:
#   --parse-only    Profile only parse_vdb
#   --access-only   Profile only get_value
#   --view          Open ProfileView visualization (requires display)
#   --html          Generate HTML flame graph

using Lyr
using Profile
using Random

# Configuration
const SAMPLE_PATHS = [
    joinpath(@__DIR__, "..", "test", "fixtures", "samples", "torus.vdb"),
    joinpath(dirname(@__DIR__), "..", "refinery", "test", "fixtures", "samples", "torus.vdb"),
    joinpath(dirname(@__DIR__), "..", "nux", "test", "fixtures", "samples", "torus.vdb"),
]
const RANDOM_SEED = 42
const NUM_QUERIES = 100_000

"""
    find_sample_file() -> String

Find a valid VDB sample file.
"""
function find_sample_file()
    for path in SAMPLE_PATHS
        if isfile(path)
            return path
        end
    end
    error("No sample VDB file found. Tried:\n" * join(SAMPLE_PATHS, "\n"))
end

"""
    warmup_jit(bytes::Vector{UInt8})

Run code once to trigger JIT compilation before profiling.
"""
function warmup_jit(bytes::Vector{UInt8})
    println("Warming up JIT...")
    vdb = parse_vdb(bytes)
    if !isempty(vdb.grids)
        tree = first(vdb.grids).tree
        c = coord(0, 0, 0)
        get_value(tree, c)
    end
    println("  JIT warmup complete")
end

"""
    profile_parse_vdb(bytes::Vector{UInt8}; n_iterations::Int=10)

Profile the parse_vdb function.
"""
function profile_parse_vdb(bytes::Vector{UInt8}; n_iterations::Int=10)
    println("\n" * "="^70)
    println("PROFILING: parse_vdb")
    println("="^70)
    println("  Iterations: $n_iterations")
    println("  File size: $(length(bytes)) bytes")

    Profile.clear()
    @profile for _ in 1:n_iterations
        parse_vdb(bytes)
    end

    println("\n--- Top Functions by CPU Time ---")
    Profile.print(format=:flat, sortedby=:count, mincount=10)

    println("\n--- Call Tree (top 50 lines) ---")
    buf = IOBuffer()
    Profile.print(buf, format=:tree, maxdepth=20)
    tree_output = String(take!(buf))
    lines = split(tree_output, '\n')
    for line in first(lines, 50)
        println(line)
    end
    if length(lines) > 50
        println("... ($(length(lines) - 50) more lines)")
    end
end

"""
    profile_get_value(tree, n_queries::Int)

Profile the get_value function with random coordinate access.
"""
function profile_get_value(tree, n_queries::Int)
    println("\n" * "="^70)
    println("PROFILING: get_value")
    println("="^70)
    println("  Queries: $n_queries")

    # Generate random coordinates
    Random.seed!(RANDOM_SEED)
    coords = [coord(rand(-100:100), rand(-100:100), rand(-100:100)) for _ in 1:n_queries]

    Profile.clear()
    @profile for c in coords
        get_value(tree, c)
    end

    println("\n--- Top Functions by CPU Time ---")
    Profile.print(format=:flat, sortedby=:count, mincount=10)

    println("\n--- Call Tree (top 50 lines) ---")
    buf = IOBuffer()
    Profile.print(buf, format=:tree, maxdepth=20)
    tree_output = String(take!(buf))
    lines = split(tree_output, '\n')
    for line in first(lines, 50)
        println(line)
    end
    if length(lines) > 50
        println("... ($(length(lines) - 50) more lines)")
    end
end

"""
    show_allocation_report(bytes::Vector{UInt8})

Show memory allocation report for key operations.
"""
function show_allocation_report(bytes::Vector{UInt8})
    println("\n" * "="^70)
    println("MEMORY ALLOCATION ANALYSIS")
    println("="^70)

    # Parse allocation
    println("\n--- parse_vdb allocations ---")
    alloc_result = @timed parse_vdb(bytes)
    println("  Time: $(round(alloc_result.time * 1000, digits=2)) ms")
    println("  Allocations: $(alloc_result.bytes ÷ 1024) KB")
    println("  GC time: $(round(alloc_result.gctime * 1000, digits=2)) ms")

    vdb = alloc_result.value
    if !isempty(vdb.grids)
        tree = first(vdb.grids).tree

        # get_value allocations
        Random.seed!(RANDOM_SEED)
        coords = [coord(rand(-100:100), rand(-100:100), rand(-100:100)) for _ in 1:10_000]

        println("\n--- get_value allocations (10k queries) ---")
        alloc_result = @timed begin
            for c in coords
                get_value(tree, c)
            end
        end
        println("  Time: $(round(alloc_result.time * 1000, digits=2)) ms")
        println("  Allocations: $(alloc_result.bytes) bytes ($(alloc_result.bytes ÷ 10_000) bytes/query)")
        println("  GC time: $(round(alloc_result.gctime * 1000, digits=2)) ms")
    end
end

"""
    generate_html_flamegraph(filename::String)

Generate HTML flame graph from current profile data.
Note: Requires PProf package. If not available, prints instructions.
"""
function generate_html_flamegraph(filename::String)
    if isdefined(Main, :PProf)
        Main.PProf.pprof(; web=false, out=filename)
        println("HTML flame graph written to: $filename")
    else
        println("PProf not loaded. To generate HTML flame graphs:")
        println("  1. Install: ] add PProf")
        println("  2. Load before running: using PProf")
        println("Saving text-based profile instead...")
        open(filename * ".txt", "w") do io
            Profile.print(io, format=:flat, sortedby=:count)
        end
        println("Text profile written to: $(filename).txt")
    end
end

"""
    run_profiling(; parse_only::Bool=false, access_only::Bool=false,
                   view::Bool=false, html::Bool=false)

Run profiling suite.
"""
function run_profiling(; parse_only::Bool=false, access_only::Bool=false,
                        view::Bool=false, html::Bool=false)
    println("="^70)
    println("Lyr.jl Profiling Suite")
    println("="^70)

    # Find and load sample file
    sample_path = find_sample_file()
    println("Sample file: $sample_path")
    bytes = read(sample_path)
    println("File size: $(length(bytes) ÷ 1024) KB")

    # JIT warmup
    warmup_jit(bytes)

    # Allocation analysis
    show_allocation_report(bytes)

    # Profile parse_vdb
    if !access_only
        profile_parse_vdb(bytes)
    end

    # Profile get_value
    if !parse_only
        vdb = parse_vdb(bytes)
        if !isempty(vdb.grids)
            tree = first(vdb.grids).tree
            profile_get_value(tree, NUM_QUERIES)
        else
            println("No grids found in VDB file, skipping get_value profiling")
        end
    end

    # HTML output
    if html
        generate_html_flamegraph("profile_flamegraph.html")
    end

    # Interactive view
    if view
        if isdefined(Main, :ProfileView)
            println("\nOpening ProfileView...")
            Main.ProfileView.view()
            println("Press Enter to exit...")
            readline()
        else
            println("\nProfileView not loaded. To use interactive visualization:")
            println("  1. Load before running: using ProfileView")
            println("  2. Then run with --view flag")
        end
    end

    println("\n" * "="^70)
    println("Profiling complete")
    println("="^70)

    println("\n--- HOTSPOT SUMMARY ---")
    println("""
    Based on profiling results, common hotspots in VDB parsing:

    1. parse_vdb:
       - Decompression (Blosc/Zlib) - often 40-60% of time
       - Tree construction - memory allocation for nodes
       - Metadata parsing - string operations

    2. get_value:
       - Hash table lookup (tree.table)
       - Mask operations (is_on, count_on, on_indices)
       - Index calculations (internal2_origin, child_index)

    Optimization targets:
    - Reduce allocations in hot loops
    - Use @inbounds for proven bounds
    - Consider caching frequently accessed data
    """)
end

# Main entry point
if abspath(PROGRAM_FILE) == @__FILE__
    parse_only = "--parse-only" in ARGS
    access_only = "--access-only" in ARGS
    view = "--view" in ARGS
    html = "--html" in ARGS

    run_profiling(; parse_only, access_only, view, html)
end
