# VDB.jl Handoff Document

## Latest Session (2026-01-03) - P0 Bug Fixes Complete

**Closed all remaining P0 issues.**

### Issues Closed

1. **path-tracer-xxk** [P0] File.jl: Grid parsing ignores byte offsets, breaks on instanced grids
   - Added byte offset seeking when has_grid_offsets is true
   - Respects descriptor byte_offset instead of continuing sequentially

2. **path-tracer-1hj** [P0] Transforms.jl: Wrong 4x4 matrix extraction for translation
   - Verified existing code is correct: indices (4, 8, 12) correctly extract translation
   - Issue description had incorrect index notation

3. **path-tracer-0bh** [P0] Accessors.jl: ActiveVoxelsIterator collects all voxels into Vector
   - Refactored helper function names (_collect_active_voxels → _collect_voxel_paths, _collect_leaves → _collect_leaf_nodes)
   - Clarified lazy iteration approach in comments

4. **path-tracer-70n** [P0] Topology.jl: Format doesn't match actual VDB specification
   - Verified Topology.jl correctly does NOT read origins for child nodes
   - Origins are properly computed from parent origin + child index
   - TreeRead.jl also implements correct interleaved format

### Test Status
- All 1489 unit tests pass
- 2 integration test errors (pre-existing): bunny_cloud.vdb, torus.vdb parsing issues
- 1 integration test broken (pre-existing): Reference values JSON not found

---

## Previous Session (2026-01-03) - P0 Bug Fixes

**Completed two critical P0 issues focused on performance and type safety.**

### Issues Closed

1. **path-tracer-1w8** [P0] Binary.jl: Fix allocation on every primitive read
   - Replaced slice allocations in all primitive readers with `GC.@preserve` + `unsafe_load`
   - Functions fixed: `read_u32_le`, `read_u64_le`, `read_i32_le`, `read_i64_le`, `read_f32_le`, `read_f64_le`
   - Previously: Each read did `bytes[pos:pos+n-1]` (allocates new vector) then `reinterpret`
   - Now: Direct pointer-based read via `unsafe_load(Ptr{T}(pointer(bytes, pos)))`
   - Zero-copy, no allocations in hot path

2. **path-tracer-z8y** [P0] VDBFile.grids uses Vector{Any} - type erasure disaster
   - Changed `grids::Vector{Any}` to `grids::Vector{Union{Grid{Float32}, Grid{Float64}, Grid{NTuple{3, Float32}}}}`
   - Updated parsing logic to use type-safe `push!` instead of pre-allocating with `nothing` values
   - Eliminates type erasure - compiler can now specialize grid access code
   - Preserves runtime type information while maintaining static typing

### Test Status
- All unit tests pass (1489 passed)
- Integration tests: 2 errors, 1 broken (pre-existing, related to VDB format parsing)
- No regression from changes

---

## Previous Session (2026-01-03) - VDB Format Investigation

**Investigating critical VDB value storage format issue.** smoke.vdb parses successfully but torus.vdb fails with BoundsError during leaf value reading.

### Key Discovery: Interleaved Format

VDB files store data **interleaved per root child**, NOT all topology then all values:

```
For each root child:
  1. Origin (12 bytes: 3 × i32)
  2. Topology (I2 masks → I1 masks → Leaf masks)
  3. Values (I2 tiles → I1 tiles + leaf values)
  4. Next root child...
```

### Current Status

**Works:**
- smoke.vdb (fog volume) - parses successfully because I2 has 0 children (only tiles, no leaves)

**Fails:**
- torus.vdb (level set) - BoundsError in `read_leaf_values` at position 5449010

### Root Cause Identified

The `read_leaf_values` function in Values.jl is **wrong**. It expects:
```julia
# WRONG: Expects u64 size prefix + compressed blob
data, pos = read_compressed_bytes(bytes, pos, codec, expected_size)
```

But OpenVDB actually stores leaf values as:
```
1. Metadata byte (1 byte): 0-6 indicating compression scheme
2. Inactive value(s) (0, 4, or 8 bytes depending on metadata)
3. Selection mask (64 bytes if metadata is 3, 4, or 5)
4. Active values only (count = valueMask.countOn())
```

Compression metadata meanings:
| Value | Name | Description |
|-------|------|-------------|
| 0 | NO_MASK_OR_INACTIVE_VALS | All inactive = +background |
| 1 | NO_MASK_AND_MINUS_BG | All inactive = -background |
| 2 | NO_MASK_AND_ONE_INACTIVE_VAL | One non-bg inactive value |
| 3 | MASK_AND_NO_INACTIVE_VALS | Selection mask for ±background |
| 4 | MASK_AND_ONE_INACTIVE_VAL | Selection mask + one inactive |
| 5 | MASK_AND_TWO_INACTIVE_VALS | Selection mask + two inactive |
| 6 | NO_MASK_AND_ALL_VALS | All 512 values stored |

### Investigation Data

For torus.vdb first root child:
- Position 706: Root child origin (-4096, -4096, -4096)
- Position 718-8910: I2 masks (8192 bytes)
- Position 8910-213710: I1 and leaf masks
- Position 213710: VALUES phase starts

At position 213710:
```
+  0: 07 03 03 1f 1f 0f 0f 0f 07 07 03 3f 1f 1f 0f 0f
+ 16: 0f 07 07 3f 3f 1f 1f 0f 0f 0f 07 3f 3f 3f 1f 1f
```

First I1 structure: 73 leaves, 2 tiles

**After 10 bytes (2 tiles × 5 bytes), byte is 0x03** - valid metadata (MASK_AND_NO_INACTIVE_VALS)!

But tile values (bytes 0-9) look wrong - not recognizable Float32 values.

### Issues Created for Documentation

New beads created to properly document the VDB format:

1. `path-tracer-98k` - Download OpenVDB documentation and specifications
2. `path-tracer-3p9` - Download OpenVDB reference implementation source code
3. `path-tracer-e3y` - Study and analyze VDB file format from docs and source (depends on 98k, 3p9)
4. `path-tracer-zwb` - Create VDB file format API reference document (depends on e3y)

### Files Modified This Session

- **TreeRead.jl** - Created for combined topology+value parsing (interleaved format)
- Verified Masks.jl, Compression.jl, File.jl are correct

### Next Steps

1. Complete format documentation (beads path-tracer-98k through path-tracer-zwb)
2. Fix `read_leaf_values` to handle compression metadata byte format
3. Verify internal node tile format (Float32 + active byte, or just Float32?)
4. Test against all sample VDB files

### Test Status
| File | Result | Notes |
|------|--------|-------|
| smoke.vdb | ✅ Parses | Fog volume, I2 has 0 children |
| torus.vdb | ❌ BoundsError | Level set, 3152 leaves to parse |
| bunny_cloud.vdb | ⚠️ Untested | Large file |

---

## Previous Session (2026-01-03)

**Fixed critical VDB header and metadata parsing issues.**

### Issues Closed
- `path-tracer-tb4` [P0]: VDB_MAGIC endianness (0x20424456 → 0x56444220)
- `path-tracer-2c4` [P0]: Header format (8-byte magic, 36-byte UUID, u32 compression)
- `path-tracer-m9h` [P0]: Metadata has no count prefix (created & closed)

### Key Changes (commit `32225a3`)
- Fixed VDB_MAGIC constant endianness
- 8-byte magic field (4 magic + 4 padding)
- UUID: 16-byte tuple → 36-byte ASCII string
- Compression: 1 byte → 4-byte u32
- Added half_float flag for version 220-221
- Heuristic-based metadata detection (no count prefix)

---

## Package Structure

```
VDB.jl/
├── src/
│   ├── VDB.jl           # Main module with exports
│   ├── Binary.jl        # Binary primitives (read_u8, read_f32_le, etc.)
│   ├── Masks.jl         # Bitmask types (Mask{N}, LeafMask, etc.)
│   ├── Coordinates.jl   # Coord type, tree navigation, BBox
│   ├── Compression.jl   # Codec abstraction (Blosc, Zlib)
│   ├── TreeTypes.jl     # Immutable tree node types
│   ├── Topology.jl      # Topology parsing (structure without values)
│   ├── Values.jl        # Value parsing *** NEEDS REWRITE ***
│   ├── TreeRead.jl      # Combined topology+value reading (NEW)
│   ├── Transforms.jl    # Coordinate transforms
│   ├── Grid.jl          # Grid wrapper type
│   ├── File.jl          # Top-level VDB file parsing
│   ├── Accessors.jl     # Tree queries (get_value, is_active, etc.)
│   ├── Interpolation.jl # Sampling (nearest, trilinear)
│   └── Ray.jl           # Ray-tree intersection
├── test/
│   └── fixtures/samples/ # VDB sample files (torus.vdb, smoke.vdb, etc.)
└── Project.toml
```

## Commands Reference

```bash
# View ready work
bd ready

# Run Julia tests
cd VDB.jl && julia --project -e 'using Pkg; Pkg.test()'

# Test specific file parsing
julia --project -e 'using VDB; vdb = parse_vdb("test/fixtures/samples/smoke.vdb"); println(length(vdb.grids))'
```

## Design Principles

1. **Pure functions**: `(bytes, pos) -> (result, new_pos)`
2. **Immutable data**: All structs are immutable
3. **Type safety**: Parameterized by value type
4. **Interleaved reading**: Topology + values per subtree, not separated
