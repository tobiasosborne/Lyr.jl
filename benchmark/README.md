# Lyr.jl Benchmarks and Profiling

## Quick Start

```bash
# Run benchmarks
timeout 60 julia --project benchmark/benchmarks.jl

# Run profiling
timeout 60 julia --project benchmark/profile.jl
```

## Profiling Workflow

### 1. Basic Profiling (CLI)

```bash
# Full profiling suite (parse_vdb + get_value)
timeout 60 julia --project benchmark/profile.jl

# Profile only parse_vdb
timeout 60 julia --project benchmark/profile.jl --parse-only

# Profile only get_value
timeout 60 julia --project benchmark/profile.jl --access-only
```

### 2. Interactive Visualization (requires GUI)

```julia
using ProfileView
include("benchmark/profile.jl")
run_profiling(; view=true)
```

### 3. Manual Profiling in REPL

```julia
using Lyr
using Profile

# Load test file
bytes = read("path/to/sample.vdb")

# Warmup
parse_vdb(bytes)

# Profile
Profile.clear()
@profile for _ in 1:10
    parse_vdb(bytes)
end

# View results
Profile.print(format=:flat, sortedby=:count, mincount=10)
Profile.print(format=:tree, maxdepth=15)
```

## Identified Hotspots

### parse_vdb

| Location | Function | % Time | Issue |
|----------|----------|--------|-------|
| boot.jl:588 | GenericMemory | ~46% | Array allocation |
| TreeRead.jl:198 | materialize_i2_values_v222 | ~55% | Main parsing loop |
| Masks.jl:202 | read_mask(LeafMask) | ~10% | Mask array creation |
| array.jl | push!/\_growend! | ~12% | Dynamic array growth |

**Optimization opportunities:**
1. Pre-allocate arrays where size is known
2. Use `@inbounds` for hot loops with verified bounds
3. Consider using `SVector` for fixed-size leaf values
4. Pool/reuse mask allocations

### get_value

| Location | Function | % Time | Issue |
|----------|----------|--------|-------|
| Masks.jl:140-148 | on_indices iteration | ~50% | Linear scan for index |
| int.jl | == comparisons | ~20% | Type promotion overhead |

**Key findings:**
- Zero allocations per query (excellent)
- Main cost is mask iteration to find child indices
- Could use `count_on` + direct indexing instead of iteration

## Memory Analysis

From profiling torus.vdb (5.3 MB file):

```
parse_vdb:
  Time: ~250ms
  Allocations: ~100 MB (18x file size)
  GC time: ~150ms (60% of total!)

get_value:
  Time: 0.02ms per 10k queries
  Allocations: 0 bytes per query
```

**Key insight:** GC dominates parse_vdb time. Reducing allocations is the primary optimization target.

## Top 10 Allocation Sites

1. `GenericMemory` (Array creation) - TreeRead.jl value arrays
2. `read_mask` - LeafMask array allocation (512 bits = 64 bytes per leaf)
3. `_totuple` - Tuple construction for leaf values
4. `push!` - Dynamic array growth in tree building
5. `collect` - Iterator materialization
6. `read_f32_le` - Float parsing (likely optimized)
7. String operations in metadata parsing
8. `Dict` operations for root table
9. Node struct construction
10. Compression buffer allocations

## Running Type Stability Checks

```julia
using InteractiveUtils

# Check parse_vdb
@code_warntype parse_vdb(bytes)

# Check get_value
@code_warntype get_value(tree, coord(0,0,0))
```

Red/yellow highlights indicate type instability that can cause allocations.
