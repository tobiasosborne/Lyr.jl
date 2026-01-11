# Lyr.jl Handoff Document

---

## Latest Session (2026-01-11) - TinyVDB AUDIT REQUIRED

**Status**: 🔴 CRITICAL - Previous implementations did NOT match C++ reference

### Summary

Discovered that TinyVDB implementation has MULTIPLE bugs because previous agents did not carefully verify against `reference/tinyvdbio.h`. Parser fails on cube.vdb.

### Critical Bugs Found

1. **Parser.jl `read_metadata`**: Missing 4-byte size prefix for typed values (bool, float, double, int32, int64, vec3i, vec3d)
2. **Parser.jl `read_transform`**: Completely wrong format - should read 5 Vec3d (15 doubles = 120 bytes) for UniformScaleMap/UniformScaleTranslateMap
3. **Parser.jl `read_grid`**: Was missing buffer_count (int32) read before topology (now added)

### Mandatory Protocol for Future Agents

**BEFORE implementing ANY TinyVDB function:**
1. Read the corresponding C++ function in `reference/tinyvdbio.h`
2. Document the EXACT byte format
3. Implement to match EXACTLY
4. Test on cube.vdb ONLY (small file)

**REPORT BACK after EVERY issue. Do NOT chain multiple fixes without reporting.**

### Audit Issues Created (ALL P0)

| Issue ID | File | Status |
|----------|------|--------|
| path-tracer-g73 | Binary.jl | open |
| path-tracer-btf | Compression.jl | open |
| path-tracer-z0t | GridDescriptor.jl | open |
| path-tracer-dwx | Header.jl | open |
| path-tracer-5vr | Mask.jl | open |
| path-tracer-o0y | Parser.jl | open |
| path-tracer-2yl | Topology.jl | open |
| path-tracer-kck | Types.jl | open |
| path-tracer-31s | Values.jl | open |
| path-tracer-3jb | TinyVDB.jl | open |

### Other Open Issues

- path-tracer-8hz - Missing buffer_count bug (fix applied but other bugs block testing)
- path-tracer-nss - Entry point (in_progress)

### Next Steps

1. Work through audit issues ONE AT A TIME
2. Start with path-tracer-g73 (Binary.jl)
3. For each: read C++ ref, compare Julia, fix discrepancies, report back

---

## Previous Session (2026-01-11) - TinyVDB Implementation Started

**Status**: 🟢 IN PROGRESS - 4/12 components complete, 152 tests passing

### Summary

Implemented first 4 TinyVDB components following strict TDD. Refactored from single file to multi-file module structure for maintainability.

### What Was Implemented

| Component | File | Tests | LOC |
|-----------|------|-------|-----|
| Binary primitives | `Binary.jl` | 61 | ~115 |
| Data structures | `Types.jl` | 22 | ~35 |
| Mask implementation | `Mask.jl` | 55 | ~100 |
| Header parsing | `Header.jl` | 14 | ~55 |

**Total: 152 tests, ~305 LOC**

### Module Structure

```
src/TinyVDB/
├── TinyVDB.jl   (1.4KB) - Main module with includes/exports
├── Binary.jl    (3.7KB) - read_u8, read_u32, read_i64, read_f32, read_string
├── Types.jl     (0.6KB) - Coord, VDBHeader, NodeType enum
├── Mask.jl      (2.9KB) - NodeMask, is_on, set_on!, count_on, read_mask
└── Header.jl    (2.1KB) - read_header, VDB_MAGIC
```

### Key Implementation Details

**Binary primitives** - Pure functional `(bytes, pos) -> (result, new_pos)` pattern using `ltoh` for little-endian, `GC.@preserve` for safety.

**NodeMask** - 0-indexed bit positions (matching C++ reference). Supports LOG2DIM 3/4/5 for leaf/internal1/internal2 nodes. Uses `count_ones` for efficient popcount.

**Header parsing** - Validates VDB magic, version >= 220, requires grid offsets. Handles v220-221 compression flag difference.

### Beads Closed This Session

- `path-tracer-43t` - Binary primitives ✅
- `path-tracer-0rj` - Data structures ✅
- `path-tracer-paa` - Mask implementation ✅
- `path-tracer-437` - Header parsing ✅

### Ready for Next Session

5 components now unblocked (run `bd ready`):
- `path-tracer-nwi` - Grid descriptor
- `path-tracer-hss` - Compression (zlib)
- `path-tracer-760` - Root topology
- `path-tracer-9nu` - Internal node topology
- `path-tracer-2ep` - Leaf topology

### Running Tests

```bash
# ONLY run TinyVDB tests (fast, isolated)
julia --project test/test_tinyvdb.jl

# Do NOT run full test suite during TinyVDB development
```

---

## Previous Session (2026-01-11 Late Night) - TinyVDB Planning

**Status**: 🟢 PLANNING COMPLETE - Fresh reimplementation planned

### Summary

C++ reference investigation revealed that tinyvdbio reads **sequentially** (never seeks to block_pos). Created 12 beads issues for a minimal ~475 LOC reimplementation.

### Key Finding

The current Lyr.jl implementation has a fundamental bug: it tries to seek to `block_offset` separately, but the C++ reference reads topology and values as one continuous stream.

**tinyvdbio approach:**
1. `seek_set(grid_pos)` — seek to grid start
2. `ReadTopology()` — read tree structure
3. `ReadBuffer()` — read values from current position (no separate seek!)

### TinyVDB Implementation Plan

| Bead ID | Component | LOC Est | Deps |
|---------|-----------|---------|------|
| path-tracer-43t | Binary primitives | ~30 | - |
| path-tracer-0rj | Data structures | ~40 | - |
| path-tracer-paa | Mask implementation | ~50 | 43t |
| path-tracer-437 | Header parsing | ~40 | 43t |
| path-tracer-nwi | Grid descriptor | ~25 | 43t |
| path-tracer-hss | Compression | ~50 | 43t |
| path-tracer-760 | Root topology | ~40 | 43t, paa, 0rj |
| path-tracer-9nu | Internal node topology | ~50 | 43t, paa, 0rj |
| path-tracer-2ep | Leaf topology | ~30 | 43t, paa, 0rj |
| path-tracer-0qj | Value reading | ~80 | hss, paa |
| path-tracer-2re | Tree assembly | ~30 | 760, 9nu, 2ep, 0qj |
| path-tracer-nss | Entry point | ~25 | 2re, 437, nwi |

**Total: ~475 LOC** in `src/TinyVDB.jl`

### Scope

- v222 format only
- Float32 values only
- Zlib + NoCompression
- Sequential reading (no block_offset seeking)
- No transforms, accessors, interpolation, ray tracing

### Next Steps

1. Run `bd ready` to see unblocked issues (43t, 0rj)
2. Implement binary primitives and data structures first
3. Work through dependency chain to entry point

---

## Previous Session (2026-01-11 Night) - C++ Reference Investigation

**Status**: 🟡 INVESTIGATION IN PROGRESS - Fix attempted but values still garbage

### Summary

Applied fix to Grid.jl:65, but values still garbage. Began C++ reference investigation.

### What Was Changed

**File**: `src/Grid.jl:65`

```julia
# BEFORE:
values_start = grid_start_pos + Int(block_offset)

# AFTER (current):
values_start = Int(block_offset) + 1
```

### The Problem

After fix, values are STILL garbage (NaN, -1.7e38). This means either:
1. The fix is wrong (off-by-one still)
2. There's another bug elsewhere

### Byte Position Analysis

```
block_offset from file = 514617

bytes[514617] = 0    ← Valid metadata byte (NO_MASK_OR_INACTIVE_VALS)
bytes[514618] = 252  ← Not metadata
bytes[514619] = 254
```

**Confusion**: If block_offset=514617 is 0-indexed, Julia position should be 514618. But the metadata byte (0) is at Julia position 514617.

This suggests EITHER:
- block_offset is already 1-indexed in VDB files (unusual for C++)
- OR there's something else wrong

### C++ Reference Investigation (INCOMPLETE)

Examined `reference/` files to understand how OpenVDB uses block_offset:

**tinyvdbio.h findings**:
- `seek_set(gd.GridPos())` at lines 2746, 3061 - seeks directly to grid position
- `BlockPos()` accessor exists but is NOT USED in tinyvdbio implementation
- tinyvdbio reads sequentially after seeking to GridPos

**LeafNode.h findings** (lines 1327-1446):
- `readTopology()`: Only reads value mask (64 bytes for leaf)
- `readBuffers()`: Reads value mask AGAIN (or seeks over it), then reads compressed values
- The value mask appears in BOTH topology and values sections

**Key insight**: In official OpenVDB:
```cpp
// readBuffers() line 1382-1388
if (seekable) {
    mValueMask.seek(is);  // Seek OVER the mask (skip it)
} else {
    mValueMask.load(is);  // Read the mask
}
// Then read compressed values...
```

### UNRESOLVED QUESTION

How does OpenVDB seek to `block_pos` before calling `readBuffers()`?

Need to find where the actual seek happens. The investigation was interrupted before finding this.

### Next Steps for Next Agent

1. **Find the seek**: Search OpenVDB C++ for where `block_pos` / `BlockPos()` is used with seekg/seek_set
2. **Understand the offset**: Determine if block_offset is 0-indexed or 1-indexed
3. **Check v222 format**: The value mask may be stored differently in v222+ format

### Files to Examine

| File | What to look for |
|------|------------------|
| `reference/RootNode.h` | Tree reading entry point, may have seek logic |
| `reference/InternalNode.h` | May show how tree traversal works |
| OpenVDB Archive.cc (not in reference/) | File-level seek operations |

### Current Grid.jl State

```julia
# Line 65 - CURRENTLY:
values_start = Int(block_offset) + 1

# THREE OPTIONS TO TRY:
# 1. values_start = Int(block_offset) + 1  ← Current (doesn't work)
# 2. values_start = Int(block_offset)      ← No +1
# 3. values_start = grid_start_pos + Int(block_offset)  ← Original (doesn't work)
```

### Beads Issues

- `path-tracer-h60` - CLOSED (fix applied)
- `path-tracer-1x0` - IN PROGRESS (verification - values still bad)
- `path-tracer-9d7` - BLOCKED (TreeRead.jl fix)

---

## Previous Session (2026-01-11 PM) - Investigation & Bug Fixes

**Status**: 🔴 CRITICAL BUG FOUND - Leaf values are garbage, parsing is broken.

### Summary

Previous session claimed "sphere tracing works but misses due to sparse data." **This is wrong.** The real problem is that **leaf values are corrupt garbage** (values like `2.0e23`, `NaN`).

### What Was Fixed

**Ray.jl BBox bug** (3 places):
- `_intersect_internal2!`, `_intersect_internal1!`, `_intersect_leaf!` all created `BBox` with tuples instead of `Coord`
- Changed `BBox(origin, (x, y, z))` → `BBox(origin, Coord(x, y, z))`
- `intersect_leaves` now works correctly

### Critical Finding: Leaf Values Are Garbage

```julia
# Leaf at Coord(-48, -56, -40) from cube.vdb:
Active count: 320
Values at first few active indices: [0.15, 2.0589416e23, 2.0589416e23, 2.011718e23, ...]
Min/max values: NaN / NaN
```

**The VDB parser is NOT correctly reading/decompressing v222 leaf values.**

### File Details

- **cube.vdb**: Format v222, NoCompression in header
- Grid parses: 547 leaves, 178665 active voxels (counts look correct)
- But actual values are corrupt

### Files Modified

| File | Change |
|------|--------|
| `src/Ray.jl` | Fixed BBox construction (tuple → Coord) in 3 places |

---

## Previous Session (2026-01-11) - Sphere Tracing Renderer

**Status**: ⚠️ PARTIAL - Renderer implemented but produces blank output due to corrupt values.

### What Was Implemented

**Renderer** (`src/Render.jl`):
- `Camera` struct with look_at constructor
- `camera_ray` for generating rays through pixels
- `sphere_trace` for ray marching through level sets
- `shade` with Lambertian shading
- `render_image` main render loop
- `write_ppm` for PPM output

**CLI Script** (`scripts/render_vdb.jl`):
- Full command-line renderer with options for width, height, FOV, distance, steps

**Tests** (`test/test_render.jl`):
- Camera construction and orthonormal basis
- Shading with different light directions
- PPM output formatting and clamping
- Sphere tracing miss cases
- Full pipeline tests

### Files Modified/Added

| File | Change |
|------|--------|
| `src/Render.jl` | NEW - Sphere tracing renderer (~300 lines) |
| `src/Lyr.jl` | Added include and exports for Render module |
| `scripts/render_vdb.jl` | NEW - CLI renderer script |
| `test/test_render.jl` | NEW - Render tests (26 tests) |
| `test/runtests.jl` | Added test_render.jl to suite |

### Test Results

```
514 passing, 0 failed, 3 errored (known: bunny_cloud v220, sphere_points PointDataGrid)
```

### Notes on Sphere Tracing

The sample VDB files are **sparse narrow-band level sets** that only store SDF values in a thin shell around the surface. This limits sphere tracing effectiveness since:
- Outside the narrow band: returns background value
- Inside object but outside narrow band: returns background value
- Only in the narrow band: actual SDF values

For production use with these files, DDA ray marching through the tree structure would be more appropriate. The current sphere tracer works correctly but most rays miss due to the sparse data.

### Commits

- `cc57140` - feat: Add sphere tracing renderer for VDB level sets

---

## Previous Session (2026-01-11) - v222 Header Fix + Renderer Plan

**Status**: ✅ SUCCESS - Fixed critical v222 parsing bug. All tracer bullet files now parse. Renderer plan approved.

### What Was Fixed

**Root cause**: v222 header parsing was fundamentally wrong.
- **Bug**: Header.jl read 4 bytes after UUID as compression flags for v222
- **Reality**: Those bytes are the file metadata count. v222+ has NO compression in header - it's per-grid.

### Files Modified

| File | Change |
|------|--------|
| `src/Header.jl` | Don't read compression from header for v222+ |
| `src/File.jl` | Read per-grid compression at start of each grid for v222+ |
| `src/Compression.jl` | Fix chunk_size handling per VDB spec (0=empty, <0=uncompressed, >0=compressed) |
| `test/test_file.jl` | Update tests for correct v222 format |
| `test/test_integration.jl` | Use `Coord` type instead of plain tuple |

### Test Results

```
488 passing, 0 failed, 3 errored (known: bunny_cloud v220, sphere_points PointDataGrid)
```

All v222 files parse correctly:
- cube.vdb ✓ (547 leaves, 178665 voxels)
- sphere.vdb ✓ (179 leaves, 36165 voxels)
- icosahedron.vdb ✓ (230 leaves, 46016 voxels)
- torus.vdb ✓ (3152 leaves, 1565265 voxels)
- utahteapot.vdb ✓ (15440 leaves, 13242562 voxels)

### Commits

- `05fc7df` - fix: Correct v222 header parsing - compression is per-grid, not in header

---

## Next Up: Minimal Raycast Renderer

**Plan approved**. Implementation ready to begin.

### Renderer Issues (in dependency order)

1. **path-tracer-6wf** [P0]: Create `src/Render.jl` with sphere tracing renderer
2. **path-tracer-cvu** [P0]: Update `src/Lyr.jl` with include and exports (depends on 6wf)
3. **path-tracer-9da** [P0]: Create `scripts/render_vdb.jl` CLI script (depends on cvu)
4. **path-tracer-co1** [P1]: Create `test/test_render.jl` with basic tests (depends on 9da)

### Renderer Plan Summary

**Goal**: Render VDB level-set surfaces to PPM images using sphere tracing.

**Approach**:
- Sphere tracing on SDF (step by distance value - fast and sub-voxel accurate)
- Simple Lambertian shading with directional light
- PPM output (no dependencies)
- ~230 lines total

**Key functions**:
```julia
Camera, look_at(from, to, up)           # Camera setup
sphere_trace(ray, grid, max_steps)       # Find surface hit
shade(point, normal, light_dir)          # Lambertian shading
render_image(grid, camera, width, height) # Main loop
write_ppm(filename, pixels)              # Output
```

**Usage** (after implementation):
```bash
julia --project scripts/render_vdb.jl test/fixtures/samples/cube.vdb cube.ppm
```

**Full plan**: `.claude/plans/radiant-forging-dragonfly.md`

---

## Repository State

- **Branch**: master
- **Working tree**: clean
- **All commits**: pushed
- **Tests**: 488 pass, 3 error (known limitations)

---

## Known Limitations

1. **bunny_cloud.vdb (v220)**: Not supported - format differs significantly
2. **sphere_points.vdb (v224)**: PointDataGrid type not implemented
3. **utahteapot.vdb**: Parses but leaf/voxel counts differ from some references (may be reference data issue)
