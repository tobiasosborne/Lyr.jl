# Lyr.jl Benchmarks

This directory contains benchmarking and profiling tools for Lyr.jl.

## Files

- `benchmarks.jl` - Performance benchmark suite using BenchmarkTools.jl
- `track_alloc.jl` - Allocation tracking script using `--track-allocation`

## Performance Benchmarks

Run the full benchmark suite:

```bash
julia --project benchmark/benchmarks.jl
```

This benchmarks:
1. `parse_vdb` - File parsing throughput
2. `get_value` - Random voxel access (10k queries)
3. `active_voxels` - Iterator performance
4. `sample_trilinear` - Interpolation (10k samples)
5. `intersect_leaves` - Ray-tree intersection (1k rays)

Results are displayed for each available VDB sample file.

## Allocation Tracking

Julia's `--track-allocation` feature generates `.mem` files showing bytes
allocated at each source line. Use this to find allocation hotspots.

### Quick Start

The workflow is two steps because `.mem` files are written when Julia exits:

```bash
# Step 1: Clean previous data and run with tracking
find src -name "*.mem" -delete
julia --project --track-allocation=user benchmark/track_alloc.jl
# Wait for Julia to exit - this writes .mem files

# Step 2: Analyze the generated .mem files
julia --project benchmark/track_alloc.jl

# (Optional) Specify a VDB file
julia --project --track-allocation=user benchmark/track_alloc.jl path/to/file.vdb
```

### Understanding the Output

The script reports:
- **Top 20 Allocation Sites**: Sorted by bytes allocated
- **Allocations by File**: Totals per source file
- **Key Areas**: Specific functions to investigate

Example output:
```
Top 20 Allocation Sites (by bytes)
----------------------------------------------------------------------

 1.   1.25 MB (45.2%)  Binary.jl:104
    → @inbounds val = bytes[pos:pos+n-1]

 2. 512.00 KB (18.5%)  Values.jl:55
    → all_values = Vector{T}(undef, N)
```

### Interpreting .mem Files

After running, `.mem` files appear next to source files:

```
src/Binary.jl      → src/Binary.jl.mem
src/Masks.jl       → src/Masks.jl.mem
```

Each `.mem` file shows allocations per line:
```
        - function read_u8(bytes::Vector{UInt8}, pos::Int)
        0     @boundscheck checkbounds(bytes, pos)
        0     @inbounds val = bytes[pos]
        0     (val, pos + 1)
        - end
```

- `-` = line not executed or no tracking
- `0` = executed, zero allocations (good!)
- `123456` = bytes allocated (investigate)

### Goals

**Hot path functions should have zero allocations:**

| Function | Module | Target |
|----------|--------|--------|
| `get_value` | Accessors.jl | 0 bytes |
| `is_on` | Masks.jl | 0 bytes |
| `count_on` | Masks.jl | 0 bytes |
| `read_u32_le` | Binary.jl | 0 bytes |
| `leaf_offset` | Coordinates.jl | 0 bytes |

**Known allocation sites (acceptable):**

- `parse_vdb` - Must allocate for tree structures
- `Vector{T}(undef, N)` - Value array creation
- String parsing - Metadata handling

### Workflow for Reducing Allocations

1. **Identify**: Run `track_alloc.jl`, find top sites
2. **Understand**: Read the allocating line in context
3. **Fix**: Common patterns:
   - Replace slicing (`bytes[a:b]`) with unsafe_load
   - Use `@inbounds` for bounds-checked hot paths
   - Avoid creating intermediate arrays
   - Use tuples instead of vectors for fixed-size data
4. **Verify**: Re-run tracking, confirm reduction
5. **Benchmark**: Ensure fix doesn't hurt performance

### Advanced Usage

**Track only specific files:**
```bash
# Julia tracks all loaded code, but you can filter analysis
julia --project --track-allocation=user -e '
    using Lyr
    bytes = read("test/fixtures/samples/torus.vdb")
    parse_vdb(bytes)
'
# Then manually inspect src/Binary.jl.mem
```

**Compare before/after:**
```bash
# Before fix
find src -name "*.mem" -delete
julia --project --track-allocation=user benchmark/track_alloc.jl
mv src/Binary.jl.mem /tmp/Binary.jl.mem.before

# After fix (edit code)
find src -name "*.mem" -delete
julia --project --track-allocation=user benchmark/track_alloc.jl

# Compare
diff /tmp/Binary.jl.mem.before src/Binary.jl.mem
```

## Sample VDB Files

Place test files in `test/fixtures/samples/`:
- `torus.vdb` - Level set torus (included)
- `bunny_cloud.vdb` - Fog volume (download from ASWF)
- `smoke.vdb` - Smoke simulation (download from ASWF)

Download from: https://artifacts.aswf.io/io/aswf/openvdb/models/
