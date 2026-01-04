# Lyr.jl Benchmark Suite
# Run with: julia --project benchmark/benchmarks.jl

using Lyr
using BenchmarkTools
using Random

# Configuration
const SAMPLE_DIR = joinpath(@__DIR__, "..", "test", "fixtures", "samples")
const RANDOM_SEED = 42

# Helper to find available sample files that parse successfully
function available_samples()
    files = Tuple{String, String, Vector{UInt8}}[]
    for name in ["torus.vdb", "smoke.vdb", "bunny_cloud.vdb"]
        path = joinpath(SAMPLE_DIR, name)
        if isfile(path)
            bytes = read(path)
            # Test if file parses successfully
            try
                parse_vdb(bytes)
                push!(files, (name, path, bytes))
            catch e
                @warn "Skipping $name (parse failed): $(typeof(e))"
            end
        end
    end
    files
end

# =============================================================================
# Run all benchmarks
# =============================================================================
function run_benchmarks()
    println("=" ^ 70)
    println("Lyr.jl Benchmark Suite")
    println("=" ^ 70)
    println()

    samples = available_samples()
    if isempty(samples)
        println("No parseable VDB files found in: $SAMPLE_DIR")
        return nothing
    end

    println("Available sample files:")
    for (name, _, _) in samples
        println("  - $name")
    end
    println()

    for (name, path, bytes) in samples
        println("-" ^ 70)
        println("Benchmarking: $name")
        println("-" ^ 70)
        println()

        # 1. Parse VDB
        println("1. parse_vdb:")
        display(@benchmark parse_vdb($bytes) samples=5 evals=1)
        println()

        # Load for subsequent tests
        vdb = parse_vdb(bytes)
        if isempty(vdb.grids)
            println("   No grids in file, skipping other benchmarks")
            println()
            continue
        end

        grid = first(vdb.grids)
        tree = grid.tree

        # 2. get_value random access
        Random.seed!(RANDOM_SEED)
        coords = [coord(rand(-100:100), rand(-100:100), rand(-100:100)) for _ in 1:10_000]

        println("2. get_value (10k random queries):")
        display(@benchmark begin
            for c in $coords
                get_value($tree, c)
            end
        end samples=5 evals=1)
        println()

        # 3. active_voxels iteration
        println("3. active_voxels iteration:")
        display(@benchmark begin
            count = 0
            for _ in active_voxels($tree)
                count += 1
            end
            count
        end samples=5 evals=1)
        println()

        # 4. sample_trilinear
        Random.seed!(RANDOM_SEED)
        positions = [(rand() * 200 - 100, rand() * 200 - 100, rand() * 200 - 100) for _ in 1:10_000]

        println("4. sample_trilinear (10k samples):")
        display(@benchmark begin
            for pos in $positions
                sample_trilinear($tree, pos)
            end
        end samples=5 evals=1)
        println()

        # 5. Ray-tree intersection
        Random.seed!(RANDOM_SEED)
        rays = Ray[]
        for _ in 1:1_000
            origin = (randn() * 100 + 200, randn() * 100, randn() * 100)
            dir = (-1.0, randn() * 0.1, randn() * 0.1)
            push!(rays, Ray(origin, dir))
        end

        println("5. Ray-tree intersection (1k rays):")
        display(@benchmark begin
            for ray in $rays
                intersect_leaves(ray, $tree)
            end
        end samples=5 evals=1)
        println()
    end

    println("=" ^ 70)
    println("Benchmark complete")
    println("=" ^ 70)
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    run_benchmarks()
end
